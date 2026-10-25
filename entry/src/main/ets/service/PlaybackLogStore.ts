/**
 * 播放日志内存环形缓冲（设置页「日志记录」）。
 *
 * 背景：三方应用无法读取系统 hilog，用户遇到「无法播放」时拿不到
 * `hdc shell hilog -x | grep BiliMusic` 的现场。本 store 在 app 内自留一份
 * 播放内核日志（错误 / 警告 / 用户提示三级），设置页「日志记录」渲染 + 复制。
 *
 * 采集口径（见 player/MusicPlayer.ts 埋点，只挂汇聚函数，不散点埋）：
 *   · plogError  → PLAYBACK_LOG_ERROR（AVPlayer error / prepare failed / 加载失败…）
 *   · plogWarn   → PLAYBACK_LOG_WARN（降档 / 看门狗 / 备用链切换 / 恢复过程…）
 *   · notifyHint → PLAYBACK_LOG_INFO（用户可见的全局 toast 提示）
 *
 * 生命周期（已与用户确认）：**仅内存、重启清空** —— 现场诊断「正在发生的
 * 播放失败」够用，不做落盘（无文件 IO / 容量控制 / 损坏兜底负担）。
 *
 * 线性安全说明：HarmonyOS app 主线程单线程跑 ArkTS（异步任务同样排队到
 * 主线程事件循环），模块级数组无并发写；容量 200 条 × 单行文本峰值 <100KB。
 */

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

/** 环形缓冲容量：超出后淘汰最旧一条（shift），只保最近现场 */
const MAX_PLAYBACK_LOGS: number = 200;

/** 环形缓冲本体（模块级单例，app 进程内共享） */
const logs: PlaybackLogEntry[] = [];

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

/** 追加一条日志；超容量淘汰最旧。函数体保持无抛出（store 故障绝不影响播放主链路）。 */
export function recordPlaybackLog(level: number, message: string): void {
  try {
    // 记录时统一解码 HTML 实体：展示与复制共用同一份干净文本
    const entry: PlaybackLogEntry = { time: Date.now(), level, message: decodeHtmlEntities(message) };
    logs.push(entry);
    if (logs.length > MAX_PLAYBACK_LOGS) {
      logs.shift();
    }
  } catch (e) {
    // 理论不可达（纯内存 push/shift）；兜底静默，绝不让日志记录打断播放
  }
}

/** 当前日志条数。 */
export function getPlaybackLogCount(): number {
  return logs.length;
}

/** 取全部日志（时间倒序，最新在前），返回副本 —— 页面直接 ForEach 渲染。 */
export function getPlaybackLogsNewestFirst(): PlaybackLogEntry[] {
  const copy: PlaybackLogEntry[] = logs.slice(0);
  copy.reverse();
  return copy;
}

/** 清空全部日志（「清空」按钮调用）。 */
export function clearPlaybackLogs(): void {
  logs.length = 0;
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
    return '（暂无播放日志）';
  }
  const lines: string[] = [`BiliMusic 播放日志（共 ${logs.length} 条，重启应用后清空）`];
  for (let i: number = 0; i < logs.length; i++) {
    lines.push(formatPlaybackLogLine(logs[i]));
  }
  return lines.join('\n');
}
