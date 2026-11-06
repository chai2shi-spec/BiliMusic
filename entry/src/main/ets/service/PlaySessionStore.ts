/**
 * 播放会话日志（听歌日记页数据底座）。
 *
 * 背景：现有 Track 只有 playedAt（最近一次播放）与 lastPosSec（续播位置），
 * 无法还原「一周内听了几次、听了多久」。本 store 以「一次连续出声」为粒度
 * 记录 PlaySession，供听歌日记页按日/周/月/年聚合（ListenDiaryStats）。
 *
 * 写入时机（MusicPlayer 四个结算点，均经 finalizeListenSegment 收尾）：
 * 暂停 / 切歌 / 播放完成（含片尾限定触发）/ 播放出错与进程释放。
 *
 * 持久化：
 *   · 文件 filesDir/listen_log/YYYY-MM.jsonl（按月分片，每行一条 JSON）；
 *   · 按 startedAt 归属分片 —— 跨零点 / 跨月的会话归开始时刻所在月，不拆分；
 *   · **绝不进 Preferences**：会话条数无上界，8192 字节单值上限必炸
 *     （MusicModels 的 PREF_VALUE_BUDGET_BYTES 教训同源）；
 *   · 追加写（APPEND），无去抖窗口 —— 会话结算频率天然低（切歌/暂停一条），
 *     writeChain Promise 链串行防重入（PlaybackLogStore 同款手法）；
 *   · 只落 ms ≥ 1000 的会话，「点开就切」的噪音不进日志。
 *
 * 保留期：13 个月（年视图要跨年对比）。initPlaySessionStore 时清理保留期外
 * 的旧分片；内存 monthCache 同步作废。
 *
 * 线性安全说明：主线程单线程跑 ArkTS，模块级状态无并发写；文件写经
 * writeChain 串行排队。querySessions 先 await writeChain 再读盘，
 * 「追加在途」与「查询读盘」不会交错出半行。
 */

import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import { PLAYBACK_LOG_WARN, recordPlaybackLog } from './PlaybackLogStore';
import { STORE_SESSION_REV } from '../common/Constants';

/** 单次播放会话（听歌日记的最小统计粒度） */
export interface PlaySession {
  /** 曲目 id（= Track.id；B 站视频为 bvid，音乐中心为音乐 id） */
  trackId: string;
  /** 歌名（结算落库用快照，榜单展示不依赖曲库仍在） */
  title: string;
  /** UP 主名（Track.artist 同源；upMid 为空时也作为聚合回落键） */
  artist: string;
  /** UP 主 mid；空串 = 未知来源（音乐中心 / 已下载） */
  upMid: string;
  /** 封面（B 站 16:9 视频缩略图） */
  coverUrl: string;
  /** BV 号（榜单点播重走播放链路需要，参考 slimTrack 必留字段） */
  bvid: string;
  /** 曲目总时长 ms；0 = 未知（「有效收听 ≥ 时长 50%」口径需要） */
  durationMs: number;
  /** 会话开始 ms 时间戳（跨零点会话的归属依据，不拆分） */
  startedAt: number;
  /** 本次有效收听毫秒（不含暂停空白；截断上限见 MusicPlayer 的 LISTEN_TICK_MAX_GAP_MS） */
  ms: number;
  /** 是否自然播完（AVPlayer completed / 片尾限定触发） */
  completed: boolean;
}

/** 会话日志目录名（filesDir 下） */
const LISTEN_LOG_DIR_NAME: string = 'listen_log';

/** 保留月数：当前月 + 往前 12 个月 = 13 个月窗（年视图跨年对比够用） */
const RETENTION_MONTHS: number = 13;

/** 最小落库会话时长：不足 1s 的「点开就切」噪音直接丢弃 */
const MIN_SESSION_MS: number = 1000;

/** 落盘单行的解析目标（JSON.parse 的一次性收口） */
interface PersistedSessionLine {
  trackId: string;
  title: string;
  artist: string;
  upMid: string;
  coverUrl: string;
  bvid: string;
  durationMs: number;
  startedAt: number;
  ms: number;
  completed: boolean;
}

/** 会话日志目录绝对路径；空串 = 未 init（appendSession 静默 no-op） */
let logDirPath: string = '';

/** initPlaySessionStore 幂等标志 */
let inited: boolean = false;

/** 串行写链：文件追加写重入保护（PlaybackLogStore / PlayerStateStore 同款手法） */
let writeChain: Promise<void> = Promise.resolve();

/** 已读月分片的内存缓存：key = 'YYYY-MM'，页面四周期来回切不重复读盘 */
const monthCache: Map<string, PlaySession[]> = new Map<string, PlaySession[]>();

/** 月份键：'YYYY-MM'（本地时区，与分片文件名一致） */
function monthKeyOf(ms: number): string {
  const d: Date = new Date(ms);
  const month: string = d.getMonth() + 1 < 10 ? `0${d.getMonth() + 1}` : `${d.getMonth() + 1}`;
  return `${d.getFullYear()}-${month}`;
}

/** 保留窗下限 ms（当前月往前推 RETENTION_MONTHS-1 个月的月首）；翻页下限 / 超窗判定共用 */
export function getRetentionFloorMs(): number {
  const now: Date = new Date();
  return new Date(
    now.getFullYear(), now.getMonth() - (RETENTION_MONTHS - 1), 1, 0, 0, 0, 0).getTime();
}

/** 追加一行到月分片文件（open → write → close） */
async function appendLine(monthKey: string, line: string): Promise<void> {
  // ⚠️ APPEND(0o2000) 只对应 O_APPEND 定位语义，不含写权限位 —— 不叠加
  // READ_WRITE 时 fd 实为只读，fs.write 全部 EBADF 失败（会话只进内存缓存，
  // 重启后丢数据，真机踩坑）。READ_WRITE 给写权限，APPEND 保证写到文件尾。
  const file: fs.File = await fs.open(`${logDirPath}/${monthKey}.jsonl`,
    fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
  try {
    await fs.write(file.fd, line);
  } finally {
    await fs.close(file);
  }
}

/**
 * 追加一条播放会话（MusicPlayer 结算点调用）。
 *
 * · ms < 1000 直接丢弃（噪音不入日志）；
 * · 未 init（EntryAbility.onCreate 之前，理论不可达）静默 no-op；
 * · 当月分片已在内存缓存时同步补入，保证 querySessions 读缓存不漏最新一条；
 *   未缓存则只排队落盘 —— querySessions 读盘前会先 await writeChain，同样不漏。
 * · 函数体保持无抛出：会话日志故障绝不影响播放主链路。
 */
export function appendSession(session: PlaySession): void {
  if (!inited || session.ms < MIN_SESSION_MS) {
    return;
  }
  // 会话确实计入 → 递增 rev：拾音页 @Watch 它判断快照过期后重查刷新
  //（AppStorage 为全局，无需 import —— FavSyncManager 同款手法）。
  const rev: number = AppStorage.get<number>(STORE_SESSION_REV) ?? 0;
  AppStorage.setOrCreate(STORE_SESSION_REV, rev + 1);
  const monthKey: string = monthKeyOf(session.startedAt);
  const cached: PlaySession[] | undefined = monthCache.get(monthKey);
  if (cached !== undefined) {
    cached.push(session);
  }
  const line: string = `${JSON.stringify(session)}\n`;
  const run: Promise<void> = writeChain
    .then((): Promise<void> => appendLine(monthKey, line));
  writeChain = run.then((): void => {
  }, (e: Error): void => {
    recordPlaybackLog(PLAYBACK_LOG_WARN, `听歌会话落盘失败: ${e.message}`);
  });
}

/** 读月分片：缓存命中直接返回；未读过的分片读盘 + 逐行消毒 + 入缓存 */
async function loadMonth(monthKey: string): Promise<PlaySession[]> {
  const cached: PlaySession[] | undefined = monthCache.get(monthKey);
  if (cached !== undefined) {
    return cached;
  }
  let raw: string = '';
  try {
    raw = await fs.readText(`${logDirPath}/${monthKey}.jsonl`);
  } catch (e) {
    // 文件不存在（该月无记录）或首读失败：按空月缓存，避免反复重试读盘
    monthCache.set(monthKey, []);
    return [];
  }
  const loaded: PlaySession[] = [];
  const lines: string[] = raw.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (line.length === 0) {
      continue;
    }
    try {
      const parsed: PersistedSessionLine = JSON.parse(line) as PersistedSessionLine;
      if (typeof parsed.trackId === 'string' && typeof parsed.startedAt === 'number'
        && typeof parsed.ms === 'number') {
        loaded.push({
          trackId: parsed.trackId,
          title: typeof parsed.title === 'string' ? parsed.title : '',
          artist: typeof parsed.artist === 'string' ? parsed.artist : '',
          upMid: typeof parsed.upMid === 'string' ? parsed.upMid : '',
          coverUrl: typeof parsed.coverUrl === 'string' ? parsed.coverUrl : '',
          bvid: typeof parsed.bvid === 'string' ? parsed.bvid : '',
          durationMs: typeof parsed.durationMs === 'number' ? parsed.durationMs : 0,
          startedAt: parsed.startedAt,
          ms: parsed.ms,
          completed: parsed.completed === true
        });
      }
    } catch (e) {
      // 单行损坏：跳过该行，保留其余
    }
  }
  monthCache.set(monthKey, loaded);
  return loaded;
}

/**
 * 查询区间会话（听歌日记页调用）：[fromMs, toMs) 按 startedAt 过滤，升序返回。
 *
 * 覆盖的月分片 = 区间跨到的每个自然月（首月从 fromMs 所在月 1 日起对齐，
 * 逐月推进到 toMs）；读盘前先 await writeChain —— 在途追加全部落定，
 * 「刚播完就进日记页」也能看到最后一条。
 */
export async function querySessions(fromMs: number, toMs: number): Promise<PlaySession[]> {
  const result: PlaySession[] = [];
  if (!inited || toMs <= fromMs) {
    return result;
  }
  await writeChain;
  // 钳到保留窗下限：更早的分片已被/将被 prune，逐月加载只会白扫一串
  // 不存在的月文件（调用方传 0 时会从 1970-01 空转 ~670 次 fs miss）。
  const retentionFloor: number = getRetentionFloorMs();
  if (fromMs < retentionFloor) {
    fromMs = retentionFloor;
  }
  const cursor: Date = new Date(fromMs);
  cursor.setDate(1);
  cursor.setHours(0, 0, 0, 0);
  while (cursor.getTime() < toMs) {
    const month: PlaySession[] = await loadMonth(monthKeyOf(cursor.getTime()));
    for (let i = 0; i < month.length; i++) {
      const s: PlaySession = month[i];
      if (s.startedAt >= fromMs && s.startedAt < toMs) {
        result.push(s);
      }
    }
    cursor.setMonth(cursor.getMonth() + 1);
  }
  result.sort((a: PlaySession, b: PlaySession): number => a.startedAt - b.startedAt);
  return result;
}

/** 恢复合并结果（本地备份恢复链路的回执） */
export interface SessionMergeResult {
  /** 实际合并落盘的会话条数 */
  merged: number;
  /** 被跳过的条数（非法条目 / 保留窗外 / 与现有记录重复） */
  skipped: number;
}

/**
 * 从备份文件合并收听会话（本地备份恢复链路，LocalBackup.restoreBackup 调用）。
 *
 * · 入参是备份 JSON 里解析出的 sessions 数组（未消毒），逐条按 loadMonth 同款
 *   typeof 规则校验，非法 / ms < 1000 / startedAt 在保留窗外或超前于当前时刻
 *   的一律跳过计数；
 * · 先 await writeChain（querySessions 同口径），再按 startedAt 归属月分桶；
 *   逐月 loadMonth 读现存会话，以 `trackId|startedAt|ms` 为去重键，仅追加
 *   缺失条目 —— 重复恢复同一份备份不会把统计翻倍；
 * · 新增行沿 writeChain 串行追加（与 appendSession 不交叉），monthCache
 *   同步补入（缓存即真源，读侧立即可见）；
 * · merged > 0 时把 STORE_SESSION_REV 递增一次 → 拾音页 @Watch 判快照
 *   过期自动重查，恢复后免重启即可见；
 * · 单条落盘失败只降级为 warn 日志（appendSession 同纪律），不抛出、
 *   不打断恢复链路。
 */
export async function mergeBackupSessions(rawSessions: PlaySession[]): Promise<SessionMergeResult> {
  const result: SessionMergeResult = { merged: 0, skipped: 0 };
  if (!inited || !Array.isArray(rawSessions) || rawSessions.length === 0) {
    return result;
  }
  await writeChain;
  const retentionFloor: number = getRetentionFloorMs();
  const nowMs: number = Date.now();
  // 消毒 + 保留窗过滤（备份文件可能被手工改坏 / 跨设备带出保留窗外的旧数据）
  const valid: PlaySession[] = [];
  for (let i = 0; i < rawSessions.length; i++) {
    const raw: PlaySession = rawSessions[i];
    if (raw === null || raw === undefined || typeof raw !== 'object'
      || typeof raw.trackId !== 'string' || raw.trackId.length === 0
      || typeof raw.startedAt !== 'number' || !Number.isFinite(raw.startedAt)
      || typeof raw.ms !== 'number' || !Number.isFinite(raw.ms)) {
      result.skipped++;
      continue;
    }
    if (raw.ms < MIN_SESSION_MS || raw.startedAt < retentionFloor || raw.startedAt > nowMs) {
      result.skipped++;
      continue;
    }
    valid.push({
      trackId: raw.trackId,
      title: typeof raw.title === 'string' ? raw.title : '',
      artist: typeof raw.artist === 'string' ? raw.artist : '',
      upMid: typeof raw.upMid === 'string' ? raw.upMid : '',
      coverUrl: typeof raw.coverUrl === 'string' ? raw.coverUrl : '',
      bvid: typeof raw.bvid === 'string' ? raw.bvid : '',
      durationMs: typeof raw.durationMs === 'number' ? raw.durationMs : 0,
      startedAt: raw.startedAt,
      ms: raw.ms,
      completed: raw.completed === true
    });
  }
  valid.sort((a: PlaySession, b: PlaySession): number => a.startedAt - b.startedAt);
  // 顺序保证同月相邻：一次线性扫描即可完成「逐月去重 + 追加」
  let idx: number = 0;
  while (idx < valid.length) {
    const monthKey: string = monthKeyOf(valid[idx].startedAt);
    const existingMonth: PlaySession[] = await loadMonth(monthKey);
    const seen: Set<string> = new Set<string>();
    for (let k = 0; k < existingMonth.length; k++) {
      const s: PlaySession = existingMonth[k];
      seen.add(`${s.trackId}|${s.startedAt}|${s.ms}`);
    }
    // 当月新增行先攒齐再一次追加（单次 fs 写，月级 I/O 而非条级）
    const lines: string[] = [];
    while (idx < valid.length && monthKeyOf(valid[idx].startedAt) === monthKey) {
      const s: PlaySession = valid[idx];
      idx++;
      const dedupKey: string = `${s.trackId}|${s.startedAt}|${s.ms}`;
      if (seen.has(dedupKey)) {
        result.skipped++;
        continue;
      }
      seen.add(dedupKey);
      existingMonth.push(s);
      lines.push(`${JSON.stringify(s)}\n`);
      result.merged++;
    }
    if (lines.length > 0) {
      const block: string = lines.join('');
      writeChain = writeChain.then((): Promise<void> => appendLine(monthKey, block))
        .then((): void => {
        }, (e: Error): void => {
          recordPlaybackLog(PLAYBACK_LOG_WARN, `备份会话合并落盘失败: ${e.message}`);
        });
    }
  }
  if (result.merged > 0) {
    // 拾音页 @Watch 本信号判断快照过期（appendSession 同款手法）
    const rev: number = AppStorage.get<number>(STORE_SESSION_REV) ?? 0;
    AppStorage.setOrCreate(STORE_SESSION_REV, rev + 1);
  }
  return result;
}

/** 清理保留期外的旧月分片（init 时一次）：文件名 YYYY-MM 解析失败的不动 */
function pruneOldMonths(): void {
  try {
    const names: string[] = fs.listFileSync(logDirPath);
    const now: Date = new Date();
    const currentIdx: number = now.getFullYear() * 12 + now.getMonth();
    for (let i = 0; i < names.length; i++) {
      const entry: string = names[i];
      const slash: number = Math.max(entry.lastIndexOf('/'), entry.lastIndexOf('\\'));
      const name: string = slash >= 0 ? entry.substring(slash + 1) : entry;
      // 'YYYY-MM.jsonl' 固定 13 字符，前缀不匹配的杂散文件跳过
      if (name.length !== 13 || name.indexOf('.jsonl') !== 7) {
        continue;
      }
      const year: number = Number(name.substring(0, 4));
      const month: number = Number(name.substring(5, 7));
      if (!Number.isInteger(year) || !Number.isInteger(month)
        || year < 2000 || month < 1 || month > 12) {
        continue;
      }
      const fileIdx: number = year * 12 + (month - 1);
      if (fileIdx < currentIdx - (RETENTION_MONTHS - 1)) {
        fs.unlinkSync(`${logDirPath}/${name}`);
        monthCache.delete(`${name.substring(0, 7)}`);
      }
    }
  } catch (e) {
    // 清理失败不影响功能：旧分片多留只是多占一点存储
  }
}

/**
 * 初始化（EntryAbility.onCreate 调用，幂等）：建目录 + 清理保留期外旧分片。
 * 须在 MusicPlayer 首次播放前完成 —— appendSession 未 init 时静默丢弃。
 */
export function initPlaySessionStore(context: common.Context): void {
  if (inited) {
    return;
  }
  inited = true;
  logDirPath = `${context.filesDir}/${LISTEN_LOG_DIR_NAME}`;
  try {
    if (!fs.accessSync(logDirPath)) {
      fs.mkdirSync(logDirPath, true);
    }
  } catch (e) {
    console.error(`init listen log dir failed: ${JSON.stringify(e)}`);
  }
  pruneOldMonths();
}

/**
 * 立即冲刷（onBackground / onDestroy 调用）：会话写入为即时追加、无去抖窗口，
 * 这里接管链尾保证失败被吞掉、链条进入 settled 态 —— 进程退出前事件循环
 * 有机会把在途 fs 写跑完（flushLogStoreNow 的同位钩子）。
 */
export function flushPlaySessionsNow(): void {
  writeChain = writeChain.then((): void => {
  }, (): void => {
  });
}
