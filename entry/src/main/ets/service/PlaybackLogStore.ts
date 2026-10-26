/**
 * 应用日志存储（设置页「日志记录」）：内存环形缓冲 + 落盘持久化。
 *
 * 背景：三方应用无法读取系统 hilog，用户遇到「无法播放」等故障时拿不到
 * `hdc shell hilog -x | grep BiliMusic` 的现场。本 store 在 app 内自留一份
 * 错误日志，设置页「日志记录」渲染 + 复制。
 *
 * 采集口径（两条，覆盖「使用过程中的任何错误」而不只是播放）：
 *   ① 既有埋点：player/MusicPlayer 的 plogError/plogWarn/notifyHint、
 *      HomePage/SearchPage 的合集加载记录等，经 recordPlaybackLog 写入；
 *   ② 全局兜底：initLogStore 时 hook console.error —— 全应用所有模块
 *      （下载 / 网络 / 数据库 / 设置……）的 catch 分支统一走 console.error，
 *      一处 hook 全量收割，新增代码无需逐点埋。
 *
 * 持久化（跨重启保留）：
 *   · 落盘文件 filesDir/app_error_log.jsonl（每行一条 JSON：
 *     {time, level, message}），启动时 initLogStore 读回内存缓冲；
 *   · 写入走「去抖全量重写」（PERSIST_DEBOUNCE_MS 后把内存缓冲整体落盘）：
 *     内存缓冲即真源、文件是镜像，天然有容量上界、无追加旋转复杂度；
 *   · 退后台 flushLogStoreNow 立即冲刷（onBackground 是划卡杀进程前
 *     最后一个可靠时机，同款手法见 flushPendingLibraryPersist）；
 *   · 「清空」按钮同步清内存 + 重写空文件。
 *
 * 生命周期：日志**跨应用重启保留**（最多 MAX_PLAYBACK_LOGS 条，超出淘汰
 * 最旧），仅用户手动「清空」才会删除。
 *
 * 线性安全说明：HarmonyOS app 主线程单线程跑 ArkTS（异步任务同样排队到
 * 主线程事件循环），模块级数组无并发写；文件写经 writeChain 串行排队。
 */

import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';

/** 日志级别：0=提示(notifyHint) 1=警告(plogWarn) 2=错误(plogError) */
export const PLAYBACK_LOG_INFO: number = 0;
export const PLAYBACK_LOG_WARN: number = 1;
export const PLAYBACK_LOG_ERROR: number = 2;

/** 单条日志（调用方已把错误对象拼成单行文本，store 不再做序列化） */
export interface PlaybackLogEntry {
  /** 记录时刻（Date.now()，展示时格式化为 MM-DD HH:mm:ss） */
  time: number;
  /** 上述三级常量之一 */
  level: number;
  /** 单行文本（MusicPlayer 内已按「Error 不可枚举属性」口径拼好） */
  message: string;
}

/** 环形缓冲容量：超出后淘汰最旧一条（内存与落盘文件共用这一上界） */
const MAX_PLAYBACK_LOGS: number = 500;

/** 落盘文件名（filesDir 下，jsonl = 每行一条 JSON） */
const LOG_FILE_NAME: string = 'app_error_log.jsonl';

/** 落盘去抖间隔（ms）：窗口内的多条记录合并成一次全量重写 */
const PERSIST_DEBOUNCE_MS: number = 2000;

/** 落盘单行的解析目标（JSON.parse 的一次性收口） */
interface PersistedLogLine {
  time: number;
  level: number;
  message: string;
}

/** 环形缓冲本体（模块级单例，app 进程内共享） */
const logs: PlaybackLogEntry[] = [];

/** 落盘文件绝对路径；空串 = 未 init（只走内存，不落盘） */
let logFilePath: string = '';
/** initLogStore 幂等标志 */
let inited: boolean = false;
/** 历史日志读回 Promise：首次落盘必须等它，否则「先 flush 后 load」会把旧日志冲掉 */
let loadPromise: Promise<void> = Promise.resolve();
/** 去抖落盘定时器句柄；-1 = 无待触发落盘 */
let flushTimer: number = -1;
/** 串行写链：文件写重入保护（PlayerStateStore 同款手法） */
let writeChain: Promise<void> = Promise.resolve();

/**
 * 常见 HTML 实体 → 原字符（服务端错误消息常带 HTML 转义，不解码会显示成
 * 实体串、看不出真实符号）。
 * 只做一轮命名实体解码，&amp; 放最后避免「&amp;lt;」被二次解码成「<」。
 */
function decodeHtmlEntities(text: string): string {
  return text
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, '\'')
    .replace(/&#39;/g, '\'')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&');
}

/** 追加一条到内存缓冲（超容量淘汰最旧）。纯内存操作，无抛出。 */
function appendEntry(entry: PlaybackLogEntry): void {
  entry.message = decodeHtmlEntities(entry.message);
  logs.push(entry);
  if (logs.length > MAX_PLAYBACK_LOGS) {
    logs.shift();
  }
}

/** 读回落盘文件：单行损坏跳过，整体解析失败视为无历史（新文件 / 首次启动） */
async function loadPersistedLogs(): Promise<void> {
  let raw: string = '';
  try {
    raw = await fs.readText(logFilePath);
  } catch (e) {
    return;
  }
  const loaded: PlaybackLogEntry[] = [];
  const lines: string[] = raw.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (line.length === 0) {
      continue;
    }
    try {
      const parsed: PersistedLogLine = JSON.parse(line) as PersistedLogLine;
      if (typeof parsed.time === 'number' && typeof parsed.level === 'number'
        && typeof parsed.message === 'string') {
        loaded.push({ time: parsed.time, level: parsed.level, message: parsed.message });
      }
    } catch (e) {
      // 单行损坏：跳过该行，保留其余
    }
  }
  // 合并：历史在前、init 之后新写入的在后（init 与读文件并发时保序）
  const merged: PlaybackLogEntry[] = loaded.concat(logs);
  logs.length = 0;
  for (let i = 0; i < merged.length; i++) {
    appendEntry(merged[i]);
  }
}

/** 把内存缓冲整体落盘（open → write → close，TRUNC 全量重写） */
async function writeLogFile(payload: string): Promise<void> {
  const file: fs.File = await fs.open(logFilePath,
    fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    await fs.write(file.fd, payload);
  } finally {
    await fs.close(file);
  }
}

/** 立即落盘：等历史读回完成后把内存缓冲全量重写进文件（写链串行，失败吞掉） */
function persistNow(): void {
  if (logFilePath.length === 0) {
    return;
  }
  const parts: string[] = [];
  for (let i = 0; i < logs.length; i++) {
    const e: PlaybackLogEntry = logs[i];
    parts.push(JSON.stringify({ time: e.time, level: e.level, message: e.message }));
  }
  const payload: string = parts.length > 0 ? `${parts.join('\n')}\n` : '';
  const run: Promise<void> = writeChain
    .then((): Promise<void> => loadPromise)
    .then((): Promise<void> => writeLogFile(payload));
  writeChain = run.then((): void => {
  }, (): void => {
    // 单次落盘失败不阻断后续；下次记录触发重写自愈
  });
}

/** 去抖调度落盘：窗口内多条记录合并一次重写，避免逐条 IO */
function schedulePersist(): void {
  if (logFilePath.length === 0 || flushTimer >= 0) {
    return;
  }
  flushTimer = setTimeout((): void => {
    flushTimer = -1;
    persistNow();
  }, PERSIST_DEBOUNCE_MS);
}

/** console.error 单参数 → 单行文本（Error 按不可枚举属性口径拼接） */
function formatConsoleArg(v: Object): string {
  if (v instanceof Error) {
    return `${v.name}: ${v.message}`;
  }
  if (typeof v === 'string') {
    return v as string;
  }
  try {
    return JSON.stringify(v);
  } catch (e) {
    return `${v}`;
  }
}

/**
 * 全局错误收割：覆写 console.error —— 调用原实现保 hilog 输出，同时把
 * 参数拼成单行按 ERROR 级入缓冲。覆写失败（宿主只读）静默降级为仅既有埋点。
 * ⚠️ 本 store 内部任何路径禁止再调 console.error（递归入缓冲）。
 */
function installConsoleErrorHook(): void {
  try {
    const original: (...data: Object[]) => void = console.error;
    console.error = (...args: Object[]): void => {
      original(...args);
      try {
        const parts: string[] = [];
        for (let i = 0; i < args.length; i++) {
          parts.push(formatConsoleArg(args[i]));
        }
        const text: string = parts.join(' ');
        if (text.length > 0) {
          appendEntry({ time: Date.now(), level: PLAYBACK_LOG_ERROR, message: text });
          schedulePersist();
        }
      } catch (e) {
        // 收割失败不影响原生日志输出
      }
    };
  } catch (e) {
    // console 不可覆写：仅保留 recordPlaybackLog 埋点链路
  }
}

/**
 * 初始化（EntryAbility.onCreate 调用，幂等）：登记落盘路径、读回历史日志、
 * 安装 console.error 全局收割。须尽早调用 —— 之后的错误才进入收割口径。
 */
export function initLogStore(context: common.Context): void {
  if (inited) {
    return;
  }
  inited = true;
  logFilePath = `${context.filesDir}/${LOG_FILE_NAME}`;
  loadPromise = loadPersistedLogs();
  installConsoleErrorHook();
}

/** 立即冲刷待落盘日志（onBackground 调用：划卡杀进程前最后可靠时机） */
export function flushLogStoreNow(): void {
  if (flushTimer >= 0) {
    clearTimeout(flushTimer);
    flushTimer = -1;
  }
  persistNow();
}

/** 追加一条日志；超容量淘汰最旧。函数体保持无抛出（store 故障绝不影响主链路）。 */
export function recordPlaybackLog(level: number, message: string): void {
  try {
    appendEntry({ time: Date.now(), level, message });
    schedulePersist();
  } catch (e) {
    // 理论不可达（纯内存 push/shift）；兜底静默，绝不让日志记录打断主链路
  }
}

/** 取全部日志（时间倒序，最新在前），返回副本 —— 页面直接 ForEach 渲染。 */
export function getPlaybackLogsNewestFirst(): PlaybackLogEntry[] {
  const copy: PlaybackLogEntry[] = logs.slice(0);
  copy.reverse();
  return copy;
}

/** 清空全部日志（「清空」按钮调用）：清内存缓冲 + 同步重写空文件。 */
export function clearPlaybackLogs(): void {
  logs.length = 0;
  persistNow();
}

/** 级别 → 中文标签（页面徽标 / 复制文本共用）。未知级别按「提示」显示。 */
export function playbackLogLevelLabel(level: number): string {
  if (level === PLAYBACK_LOG_ERROR) {
    return '错误';
  }
  if (level === PLAYBACK_LOG_WARN) {
    return '警告';
  }
  return '提示';
}

/** 时间戳 → `MM-DD HH:mm:ss`（手动 pad，不引 Intl）。 */
export function formatPlaybackLogTime(time: number): string {
  const d: Date = new Date(time);
  const two: (v: number) => string = (v: number): string => {
    return v < 10 ? `0${v}` : `${v}`;
  };
  return `${two(d.getMonth() + 1)}-${two(d.getDate())} ` +
    `${two(d.getHours())}:${two(d.getMinutes())}:${two(d.getSeconds())}`;
}

/** 单条 → `[MM-DD HH:mm:ss][级别] message`（长按复制单条用）。 */
export function formatPlaybackLogLine(entry: PlaybackLogEntry): string {
  return `[${formatPlaybackLogTime(entry.time)}][${playbackLogLevelLabel(entry.level)}] ${entry.message}`;
}

/**
 * 全量 → 多行文本（「复制全部」用，旧→新按发生顺序排列，便于按时间线阅读）。
 * 头部带 app 名与条数说明；空日志返回占位提示（复制空串没有回执意义）。
 */
export function formatPlaybackLogsAsText(): string {
  if (logs.length === 0) {
    return '（暂无应用日志）';
  }
  const lines: string[] = [`BiliMusic 应用日志（共 ${logs.length} 条，重启应用后保留）`];
  for (let i = 0; i < logs.length; i++) {
    lines.push(formatPlaybackLogLine(logs[i]));
  }
  return lines.join('\n');
}
