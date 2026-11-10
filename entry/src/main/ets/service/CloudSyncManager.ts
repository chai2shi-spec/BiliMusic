/**
 * 华为云空间同步管理器（方案 §5.5 调度 / §6 读轮 / §7 写轮）。
 *
 * 职责边界：
 *   · CloudDirClient  —— 云端目录 IO（哪台设备、哪个文件、怎么下载）；
 *   · CloudSyncStore  —— 本机状态（我是谁、上次读到哪、hash 表、base 快照）；
 *   · PlaylistCloudMerge —— 纯合并算法（不碰 IO）；
 *   · 本模块          —— **什么时候**跑一轮、一轮里**按什么顺序**做什么。
 *
 * 触发时机（方案 §5.5）：
 *   ① 启动后 8s（避开启动网络高峰）；
 *   ② 数据变更去抖 20s（LibraryStore.persistPlaylists /
 *      PlaySessionStore.appendSession 经 CloudSyncHooks 广播到这里）；
 *   ③ 回前台且距上轮 >5min；
 *   ④ 退后台时若有未写回的本地变更（write-only 轮，最后一个可靠时机）；
 *   ⑤ 页面「立即同步」手动触发。
 *
 * 一轮（60s 预算）= 读取（autoRead 开时）→ 合并应用 → 写回。
 * 串行化：running / pendingFull 保证任何时刻最多一轮在跑，重叠请求合并。
 *
 * 安全纪律（与 FavSyncManager 同源）：
 *   · 应用远端数据期间 applying 置位 —— 数据变更通知被忽略，绝不自我循环；
 *   · 单文件 / 单设备失败只跳过该单元，绝不放大成整轮失败；
 *   · 「删除」只能来自墓碑表（明确记录过删除的），读取失败 / 数据为空
 *     永远不是删除依据。
 */

import common from '@ohos.app.ability.common';
import { bundleManager } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { STORE_CLOUD_SYNC_REV } from '../common/Constants';
import { Playlist, slimTrack, Track } from '../model/MusicModels';
import { batchUpsertFromCloud, countPlaylistsWithUnloadedChunks, dedupPlaylistsByName, getPlaylistsForSync, LibraryStore, PlaylistNameDedupResult, RECENT_KEEP_MS, RECENT_MAX_ITEMS } from './LibraryStore';
import { mergeBackupSessions, listMonthKeys, readMonthRaw, querySessions, PlaySession, SessionMergeResult } from './PlaySessionStore';
import { setCloudSyncDataListener } from './CloudSyncHooks';
import {
  initCloudDirClient,
  isCloudDirAvailable,
  ensureDeviceDirs,
  writeOwnFile,
  listCloudDeviceIds,
  listDeviceFileNames,
  purgeAllDeviceDirs,
  CloudPurgeResult,
  readDeviceFile,
  readOwnFileDirect,
  deleteDeviceFile,
  triggerSystemSync
} from './CloudDirClient';
import {
  CloudFileHashPair,
  initCloudSyncStore,
  getCloudDeviceId,
  isAutoRead,
  setLastReadAt,
  getLastRoundAt,
  setLastRoundAt,
  setLastCloudSyncError,
  getRemoteFileHash,
  putRemoteFileHashes,
  forgetRemotePlaylist,
  getOwnFileHash,
  putOwnFileHashes,
  getOwnPlaylistIds,
  setOwnPlaylistIds,
  isTombstonePurgeDone,
  markTombstonePurgeDone,
  listKnownRemoteFiles,
  getCloudResetAt,
  resetCloudSyncState,
  getRecentClearedAt,
  getRecentDeleted,
  putRecentTraces,
  loadMergeBase,
  saveMergeBase
} from './CloudSyncStore';
import {
  CloudDeviceMeta,
  CloudPlaylistIndexEntry,
  CloudRecentPayload,
  mergePlaylist,
  mergeRecentTracks,
  mergeTombstones,
  parseCloudIndex,
  parseCloudMeta,
  parseCloudPlaylist,
  parseCloudRecent,
  parseCloudTombstones,
  RecentMergeResult
} from './PlaylistCloudMerge';
import { PLAYBACK_LOG_ERROR, recordPlaybackLog } from './PlaybackLogStore';


/** 启动后首轮延迟（ms）：避开启动网络高峰 */
const CLOUD_SYNC_BOOT_DELAY_MS: number = 8000;
/** 数据变更去抖窗口（ms） */
const CLOUD_SYNC_DATA_DEBOUNCE_MS: number = 20000;
/** 回前台触发轮的最小间隔（ms） */
const CLOUD_SYNC_FOREGROUND_GAP_MS: number = 5 * 60 * 1000;
/** 单轮总预算（ms）：超预算剩余单元留到下一轮（部分成功，不算失败） */
const CLOUD_SYNC_ROUND_BUDGET_MS: number = 60000;
/** 墓碑保留期（ms）：过期条目不再传播，也阻止「删→过60天→复活」的陈旧合并 */
const CLOUD_TOMBSTONE_TTL_MS: number = 60 * 24 * 60 * 60 * 1000;
/** 读前触发系统同步的等待预算（ms）：拿到 COMPLETED 就继续读，超时先读本机快照 */
const CLOUD_SYNC_TRIGGER_WAIT_MS: number = 10000;
/** 两次主动触发的间隔（ms）：见 CloudDirClient 的系统同步触发注释 */
const CLOUD_SYNC_TRIGGER_GAP_MS: number = 5 * 60 * 1000;
/**
 * 触发失败 / 超时后的重试间隔（ms）。
 *
 * ⚠️ 为什么不能和成功共用 5 分钟：重装 / 换机后首轮的系统同步经常需要十几秒
 * （目录与元数据要下行），10s 预算内拿不到 COMPLETED 很正常。若把「超时」也
 * 记进 5 分钟闸门，接下来 5 分钟内每轮都会跳过触发 → 本机看不到任何远端设备
 * 目录 → 「云端数据一份都读不到」，而这期间用户点「立即读取云端」也没有用。
 */
const CLOUD_SYNC_TRIGGER_RETRY_MS: number = 30 * 1000;
/**
 * 预算耗尽后的自动接力延迟（ms）与最多连续接力次数。
 *
 * 一轮 60s 预算里，重装 / 换机后的首轮常常只够下十几个文件（每个云端文件
 * 都要走一次缓存下载）。没有接力的话，剩下的歌单要等下一次触发（启动 8s、
 * 回前台 >5min、或用户手点）才继续 —— 用户看到的就是「只同步回来几个歌单，
 * 剩下的不来了」。接力 3 次 + 每轮 60s 足够覆盖几百条记录的首次全量。
 */
const CLOUD_SYNC_CONTINUE_DELAY_MS: number = 3000;
const CLOUD_SYNC_MAX_AUTO_CONTINUE: number = 3;
/**
 * 系统同步「迟到」后的补读延迟（ms）与最多次数。
 *
 * 实测（真机 SGT-AL10 / API 26）：冷启后系统那一轮端云同步要 20~30s 才
 * COMPLETED，而读轮的等待预算是 10s —— 于是「读」总是发生在「系统把远端
 * 文件下行到本机」之前，读到的自然是空的。上一轮的日志就是证据：
 * 首轮 `playlists=0`，同一台机器重启后再读变成 `playlists=2`。
 *
 * 不把等待预算拉到 25s 是因为那会让首屏数据晚 25s 才出现（有本地缓存的
 * 情况下，先读一次照样能立刻出数据）。折中：先读一次，若系统同步没等到
 * 且本轮远端读到的确实为空，15s 后再读一轮（那时系统同步基本已完成）。
 */
const CLOUD_SYNC_LATE_READ_DELAY_MS: number = 15000;
const CLOUD_SYNC_LATE_READ_MAX: number = 3;

let inited: boolean = false;
/** 一轮进行中（串行化标志） */
let running: boolean = false;
/** running 期间又来了 full 轮请求：本轮结束后补跑 */
let pendingFull: boolean = false;
/** 补跑那一轮是否含手动意图（见 requestCloudSyncRound） */
let pendingManual: boolean = false;
/** 应用远端数据窗口：期间数据变更通知一律忽略（防自我循环） */
let applying: boolean = false;
/** 上次写回后本地是否又有变更（退后台 write-only 轮的依据） */
let dirtySinceWrite: boolean = false;
/** 数据变更去抖定时器 */
let debounceTimer: number = -1;
/** 上次主动触发系统端云同步的时刻（限频用，0 = 本次进程还没触发过） */
let lastSyncTriggerAt: number = 0;
/** 系统同步迟到导致的补读已连续排了几次（拿满数据即归零，防死循环） */
let lateReadCount: number = 0;

/**
 * 一轮的量化结果：只用于「同步完成」弹窗的文案，不参与任何合并判断。
 * 计数在 readRound / applyRemote / writeRound 里就地累加，runRound 收口。
 */
interface RoundCounters {
  /** 本轮扫描到的云端设备目录数（含本机与历史安装目录） */
  devices: number;
  /** 歌单新增 / 更新数（与本地逐字段比对后真有差异的才计） */
  playlists: number;
  /** 本轮并入的拾音会话条数（含重复条目，去重由 mergeBackupSessions 做） */
  sessions: number;
  /** 合并后本机最近播放条数 */
  recent: number;
  /** 本轮写回云端的文件数（hash 未变被跳过的不计） */
  written: number;
}

/** 本轮计数（每轮开头重置；单飞保证同一时刻只有一轮在用） */
let counters: RoundCounters = { devices: 0, playlists: 0, sessions: 0, recent: 0, written: 0 };
/** 本轮是否因 60s 预算耗尽而中途收工（决定要不要自动接力下一轮） */
let budgetExhausted: boolean = false;
/** 连续自动接力次数（无进展时封顶，避免无限自触发） */
let autoContinueCount: number = 0;

function resetCounters(): void {
  counters = { devices: 0, playlists: 0, sessions: 0, recent: 0, written: 0 };
  budgetExhausted = false;
}

/**
 * 一轮结束的结果报告（云同步页「同步完成」弹窗的数据源）。
 *
 * 为什么在 Manager 侧攒、页面侧取：页面可能不在前台（后台轮次），
 * 攒在页面里会丢；攒在 Manager 里则只要页面在，就能在下一次 rev 变化时消费。
 */
export interface CloudSyncRoundReport {
  /** 用户手动点「立即读取云端」触发的轮次（决定弹窗还是轻提示） */
  manual: boolean;
  /** 本轮是否整体成功（false 时 error 一定有内容） */
  ok: boolean;
  /** 失败原因（人话，可直接展示） */
  error: string;
  devices: number;
  playlists: number;
  sessions: number;
  recent: number;
  written: number;
  /** 完成时刻（ms） */
  at: number;
}

/** 待页面消费的报告（页面不在前台时不攒，避免下次进页面弹出一个过期结果） */
let pendingReport: CloudSyncRoundReport | null = null;
/** 云同步页是否在前台（页面 aboutToAppear / aboutToDisappear 维护） */
let pageVisible: boolean = false;

/** 页面生命周期上报：决定报告要不要攒（见 pendingReport 注释） */
export function setCloudSyncPageVisible(visible: boolean): void {
  pageVisible = visible;
  if (!visible) {
    pendingReport = null;
  }
}

/** 取走本轮报告（取即清空；无报告返回 null） */
export function consumeCloudRoundReport(): CloudSyncRoundReport | null {
  const r: CloudSyncRoundReport | null = pendingReport;
  pendingReport = null;
  return r;
}

let ownDeviceId: string = '';
let deviceName: string = '';
let appVersion: string = '';

/**
 * 内容 hash：FNV-1a 32 位 + 字符长度。
 * 用途是「变没变」的判定（差量下载 / 跳过重写），不是密码学摘要 ——
 * 32 位 + 长度的碰撞概率对本场景足够（碰撞最坏后果 = 多下载一次）。
 * 不引入 crypto / hash 模块：省依赖，且 charCodeAt 循环对 MB 级文本也是 ms 级。
 */
function contentHash(s: string): string {
  let h: number = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return `${h >>> 0}_${s.length}`;
}

/**
 * 从会话分片名取月份键，兼容 '2026-11' 与 '2026-11.jsonl'。
 * 读轮三源并集（meta / 目录列举 / 历史 hash key）与写轮 meta 共用这一份判定：
 * 以前 listMonthKeys 与 pruneOldMonths 各内联一份导致拾音整条链路失效，别再漂移。
 */
function monthKeyOf(name: string): string {
  const dot: number = name.indexOf('.');
  const key: string = dot > 0 ? name.substring(0, dot) : name;
  return key.length === 7 ? key : '';
}

/** 分片里的非空行数：用来判断本机分片是否已经包含这份远端分片 */
function countJsonlLines(raw: string): number {
  const lines: string[] = raw.split('\n');
  let n: number = 0;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim().length > 0) {
      n++;
    }
  }
  return n;
}

/** 云端歌单快照 JSON（曲目统一 slimTrack + 清 localFilePath，跨设备无效） */
function playlistCloudJson(p: Playlist): string {
  const tracks: Track[] = p.tracks.map((t: Track): Track => {
    const slim: Track = slimTrack(t);
    slim.localFilePath = '';
    return slim;
  });
  return JSON.stringify({
    id: p.id,
    name: p.name,
    description: p.description,
    coverUrl: p.coverUrl,
    createdAt: p.createdAt,
    updatedAt: p.updatedAt,
    upMid: p.upMid,
    upName: p.upName,
    sourceKind: p.sourceKind ?? '',
    titleSorted: p.titleSorted === true,
    tracks: tracks
  });
}

/** 歌单 updatedAt 的 ms（降序排序比较键） */
function updatedMsOf(p: Playlist): number {
  const t: number = Date.parse(p.updatedAt);
  return Number.isFinite(t) ? t : 0;
}

/** 云同步页 @Watch 信号递增（一轮结束 / 状态变化都 bump，幂等无害） */
function bumpCloudSyncRev(): void {
  const rev: number = AppStorage.get<number>(STORE_CLOUD_SYNC_REV) ?? 0;
  AppStorage.setOrCreate(STORE_CLOUD_SYNC_REV, rev + 1);
}

/**
 * 初始化（AppContainer.initRest 调用，幂等）。
 * 注册数据变更监听 + 8s 后首轮；云端目录不可用（系统开关未开）时
 * 监听照常注册 —— 用户中途打开系统开关后无需重启，下一轮探针自然通过。
 */
export function initCloudSync(context: common.UIAbilityContext): void {
  if (inited) {
    return;
  }
  inited = true;
  initCloudDirClient(context);
  initCloudSyncStore(context);
  ownDeviceId = getCloudDeviceId();
  deviceName = deviceInfo.productModel ?? '';
  // 应用版本号（AboutPage 同款来源）：fire-and-forget，首轮 8s 后才跑，早已就位
  bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
    .then((info: bundleManager.BundleInfo): void => {
      appVersion = info.versionName ?? '';
    })
    .catch((): void => {
      appVersion = '';
    });
  setCloudSyncDataListener(onDataChanged);
  if (isCloudDirAvailable()) {
    try {
      ensureDeviceDirs(ownDeviceId);
    } catch (e) {
      console.warn(`[CloudSync] ensure own dirs failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    }
  }
  setTimeout((): void => {
    requestCloudSyncRound(true);
  }, CLOUD_SYNC_BOOT_DELAY_MS);
  bumpCloudSyncRev();
}

/** 数据变更监听（CloudSyncHooks 转发）：20s 去抖后触发一轮 */
function onDataChanged(): void {
  if (!inited || applying) {
    return;
  }
  dirtySinceWrite = true;
  if (debounceTimer !== -1) {
    clearTimeout(debounceTimer);
  }
  debounceTimer = setTimeout((): void => {
    debounceTimer = -1;
    requestCloudSyncRound(true);
  }, CLOUD_SYNC_DATA_DEBOUNCE_MS);
}

/** 回前台（EntryAbility.onForeground 调用）：距上轮 >5min 补一轮 */
export function onCloudSyncForeground(): void {
  if (!inited) {
    return;
  }
  if (Date.now() - getLastRoundAt() > CLOUD_SYNC_FOREGROUND_GAP_MS) {
    requestCloudSyncRound(true);
  }
}

/** 退后台（EntryAbility.onBackground 调用）：有未写回变更时补一轮写回 */
export function onCloudSyncBackground(): void {
  if (!inited || !dirtySinceWrite) {
    return;
  }
  requestCloudSyncRound(false);
}

/**
 * 同步失败统一上报：lastError 进云同步页状态卡，同时按 ERROR 级写入
 * 「设置 → 报错记录」（PlaybackLogStore）—— 云同步故障用户在报错记录里
 * 无现场可查，这里补齐采集口径。
 */
function reportSyncFailure(msg: string): void {
  setLastCloudSyncError(msg);
  recordPlaybackLog(PLAYBACK_LOG_ERROR, `云同步失败: ${msg}`);
}

/**
 * 请求一轮同步。
 * @param full true = 读取 + 写回；false = 仅写回（退后台兜底）
 * @param manual true = 页面「立即读取云端」手动触发：无视「自动读取」
 *   开关强制读（用户点击就是意图本身）
 */
export function requestCloudSyncRound(full: boolean, manual: boolean = false): void {
  if (!inited) {
    return;
  }
  if (running) {
    if (full) {
      pendingFull = true;
      // 手动意图要跨过「本轮已在跑」这次合并：否则用户点了「立即读取云端」
      // 只会并进一个自动轮次，结束时按自动轮次的语气给提示（没有结果弹窗）。
      pendingManual = pendingManual || manual;
    }
    return;
  }
  running = true;
  resetCounters();
  runRound(full, manual)
    .catch((e: Error): void => {
      reportSyncFailure(`同步轮异常退出: ${e.message}`);
    })
    .then((): void => {
      running = false;
      if (pendingFull) {
        pendingFull = false;
        const nextManual: boolean = pendingManual;
        pendingManual = false;
        requestCloudSyncRound(true, nextManual);
      }
    });
}

/* ---------------- 「重置云同步」（云端推倒重来） ---------------- */

/** 重置结果（页面弹窗文案的数据源） */
export interface CloudResetResult {
  /** 重置动作是否成功发起（false 时 message 说明原因） */
  ok: boolean;
  /** 人话结果，可直接展示 */
  message: string;
  /** 清掉的设备目录数 */
  dirs: number;
  /** 清掉的文件数 */
  files: number;
  /** 删完仍残留的目录数（云端占位删不掉，靠 resetAt 水位兜底） */
  leftovers: number;
}

/** 等当前轮收工（running 转 false）；超时返回 false，由调用方决定是否继续 */
async function waitRoundIdle(timeoutMs: number): Promise<boolean> {
  const start: number = Date.now();
  while (running) {
    if (Date.now() - start > timeoutMs) {
      return false;
    }
    await new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, 200);
    });
  }
  return true;
}

/**
 * 重置云同步：**删掉云端所有设备目录 + 清空本机同步状态**，然后立刻全量重传。
 *
 * 与「立即读取云端」的区别：那个是从云端往下拉，这个是把云端推倒重来 ——
 * 只用于「云端数据被搞乱了 / 想彻底断干净重来」，因此放在页面的危险操作区。
 *
 * 本地业务数据（歌单 / 拾音 / 最近播放）**一律不动**：本机是数据源头，重置
 * 只是把「同步关系的记忆」清空，让下一轮像第一次同步那样全量写上去。
 *
 * 顺序：先等本轮收工 → 删云端 → 再清状态（含 resetAt 水位）→ 最后触发全量轮。
 * 不能反着清状态：删到一半时 20s 去抖的自动轮可能抢跑，那一轮会把刚从云端
 * 读到的旧数据再写回去。
 */
export async function resetCloudSync(): Promise<CloudResetResult> {
  if (!inited) {
    return { ok: false, message: '云同步还没初始化，请稍后再试', dirs: 0, files: 0, leftovers: 0 };
  }
  if (!isCloudDirAvailable()) {
    return {
      ok: false,
      message: '云端目录不可用，请先在系统设置里打开本应用的云同步',
      dirs: 0, files: 0, leftovers: 0
    };
  }
  // 正在跑的一轮里可能有半截数据要写回：等它收工再删，避免边删边写。
  // 一轮最长 60s，正常 1~2s；等不到也继续 —— 删除幂等，水位兜底。
  const idle: boolean = await waitRoundIdle(8000);
  if (!idle) {
    console.info('[CloudSync] reset: previous round still running, proceed anyway');
  }
  // 重建云端前先把本地同名歌单规整掉：否则刚清空的云端会被
  // 「一份有曲目 + 一份空壳」原样重新写上去，去重永远做不干净。
  // dedupPlaylistsByName 自带分片装载闸门，库没就绪时宁可不动手。
  const dedup: PlaylistNameDedupResult = dedupPlaylistsByName();
  if (dedup.applied && dedup.removed.length > 0) {
    console.info(`[CloudSync] reset: dedup merged ${dedup.groups} group(s), `
      + `removed ${dedup.removed.length} duplicate playlist(s)`);
  } else if (dedup.reason.length > 0) {
    console.info(`[CloudSync] reset: dedup skipped (${dedup.reason})`);
  }
  const purge: CloudPurgeResult = purgeAllDeviceDirs();
  resetCloudSyncState();
  // 立刻全量重传：本地数据是源头，云端刚被清空
  requestCloudSyncRound(true, true);
  bumpCloudSyncRev();
  const tail: string = purge.leftovers > 0
    ? `（其中 ${purge.leftovers} 个目录暂留在系统缓存，下次同步会以本机数据覆盖）`
    : '';
  const dedupTail: string = dedup.applied
    ? `；已合并 ${dedup.groups} 组同名歌单、移除 ${dedup.removed.length} 个重复项`
    : (dedup.reason.length > 0 ? `；本地去重未执行（${dedup.reason}）` : '');
  return {
    ok: true,
    message: `已清空云端 ${purge.dirs} 个设备目录、${purge.files} 个文件${tail}${dedupTail}，正在重新上传`,
    dirs: purge.dirs,
    files: purge.files,
    leftovers: purge.leftovers
  };
}

/** 每次进程启动只做一次本地去重（去重函数本身幂等，重复跑也没有副作用） */
let dedupCheckedThisLaunch: boolean = false;

/**
 * 启动首轮前规整本地重复歌单，并精确清掉云端对应的空壳快照。
 *
 * 为什么不等用户点按钮：读轮会用 remoteHashes 的历史 key 兜底恢复歌单 id，
 * 只要云端那份空壳快照还在，下一轮就会把它当「远端独有歌单」重新加回本地，
 * 用户侧看到的永远是「删了又长回来」。
 *
 * dedupPlaylistsByName 自带分片装载闸门：库没就绪时这轮什么都不动，
 * 也不置标记之外的影响（下一轮同一个进程内不会再试，但重装 / 重启会再试）。
 */
function dedupLocalAndPruneCloud(): void {
  if (dedupCheckedThisLaunch) {
    return;
  }
  dedupCheckedThisLaunch = true;
  const r: PlaylistNameDedupResult = dedupPlaylistsByName();
  if (!r.applied || r.removed.length === 0) {
    if (r.reason.length > 0) {
      console.info(`[CloudSync] dedup skipped: ${r.reason}`);
    }
    return;
  }
  const devices: string[] = listCloudDeviceIds();
  for (let i = 0; i < r.removed.length; i++) {
    const id: string = r.removed[i];
    const relPath: string = `playlists/${id}.json`;
    for (let d = 0; d < devices.length; d++) {
      deleteDeviceFile(devices[d], relPath);
    }
    const forgotten: number = forgetRemotePlaylist(id);
    console.info(`[CloudSync] dedup removed=${id} cloudHashes=${forgotten}`);
  }
  console.info(`[CloudSync] dedup: groups=${r.groups} merged=${r.tracksMerged} `
    + `dupTracks=${r.duplicatesRemoved} removed=${r.removed.length}`);
}

/** 一轮同步主体（60s 预算；失败记 lastError，部分完成不算失败） */
async function runRound(full: boolean, manual: boolean): Promise<void> {
  // 云端目录不可用 = 系统同步开关没开：不是错误，静默跳过（页面显示未开启态）
  if (!isCloudDirAvailable()) {
    return;
  }
  try {
    ensureDeviceDirs(ownDeviceId);
  } catch (e) {
    const msg: string = `云端目录不可用: ${e instanceof Error ? e.message : JSON.stringify(e)}`;
    reportSyncFailure(msg);
    publishReport(manual, false, msg);
    bumpCloudSyncRev();
    return;
  }
  // 读轮之前先去重：否则本轮又会把云端那份空壳快照当作「远端独有歌单」
  // 合并回本地，与刚做完的去重相互抵消。
  dedupLocalAndPruneCloud();
  const deadline: number = Date.now() + CLOUD_SYNC_ROUND_BUDGET_MS;
  /** 系统那一轮端云同步在本轮内完成了吗（false = 读的是「还没下行完」的快照） */
  let syncInPlace: boolean = true;
  try {
    if (full && (manual || isAutoRead())) {
      syncInPlace = await pullBeforeRead(deadline);
      await readRound(deadline);
    }
    await writeRound(deadline);
    setLastRoundAt(Date.now());
    setLastCloudSyncError('');
    dirtySinceWrite = false;
    publishReport(manual, true, '');
  } catch (e) {
    const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
    reportSyncFailure(msg);
    publishReport(manual, false, msg);
  } finally {
    // 系统同步迟到（本轮 10s 没等到 COMPLETED）且远端确实什么都没读到：
    // 15s 后再读一轮 —— 那时系统基本已把远端文件下行到本机（真机实测 20~30s）。
    // 只在「读到的为空」时补，读到过数据就说明快照够用，不必再打扰系统。
    const remoteEmpty: boolean = counters.playlists === 0 && counters.sessions === 0;
    const needLateRead: boolean = full && !syncInPlace && remoteEmpty
      && lateReadCount < CLOUD_SYNC_LATE_READ_MAX;
    if (syncInPlace || !remoteEmpty) {
      lateReadCount = 0;
    }
    // 预算耗尽 = 还有活没干完：3s 后自动接力一轮（首轮全量下载靠它收敛）
    if (budgetExhausted && full && autoContinueCount < CLOUD_SYNC_MAX_AUTO_CONTINUE) {
      autoContinueCount++;
      console.info(`[CloudSync] round budget exhausted, continue in ${CLOUD_SYNC_CONTINUE_DELAY_MS}ms `
        + `(${autoContinueCount}/${CLOUD_SYNC_MAX_AUTO_CONTINUE})`);
      setTimeout((): void => {
        requestCloudSyncRound(true);
      }, CLOUD_SYNC_CONTINUE_DELAY_MS);
    } else if (needLateRead) {
      lateReadCount++;
      console.info(`[CloudSync] system sync late, re-read in ${CLOUD_SYNC_LATE_READ_DELAY_MS}ms `
        + `(${lateReadCount}/${CLOUD_SYNC_LATE_READ_MAX})`);
      setTimeout((): void => {
        requestCloudSyncRound(true, manual);
      }, CLOUD_SYNC_LATE_READ_DELAY_MS);
    } else if (!budgetExhausted) {
      autoContinueCount = 0;
    }
    bumpCloudSyncRev();
  }
}

/**
 * 把本轮结果交给页面（页面不在前台就不攒，避免下次进页面弹出过期结果）。
 * 手动轮无论成功失败都要出结果 —— 用户点了按钮就必须有回音。
 */
function publishReport(manual: boolean, ok: boolean, error: string): void {
  if (!pageVisible) {
    return;
  }
  pendingReport = {
    manual: manual,
    ok: ok,
    error: error,
    devices: counters.devices,
    playlists: counters.playlists,
    sessions: counters.sessions,
    recent: counters.recent,
    written: counters.written,
    at: Date.now()
  };
}

/**
 * 读前先触发一轮系统端云同步（限频）：本机 `el2/cloud` 为空时（重装 / 换机），
 * 远端设备目录只是云侧记录，必须先由系统把元数据下行到本机，`listCloudDeviceIds`
 * 才扫得到 —— 只在启动首轮 + 手动读取 + 距上次触发 >5min 时做，避开官方
 * 「触发频率过高会导致整机异常」的红线。
 *
 * ⚠️ 闸门只在**成功**时按 5 分钟计；超时 / 失败只缓 30s 就允许再试（见
 * CLOUD_SYNC_TRIGGER_RETRY_MS 注释：把超时也记 5 分钟，会让重装后的前 5 分钟
 * 里每轮都跳过触发，本机永远看不到远端目录 = 一份数据都读不到）。
 */
async function pullBeforeRead(deadline: number): Promise<boolean> {
  const now: number = Date.now();
  if (now - lastSyncTriggerAt < CLOUD_SYNC_TRIGGER_GAP_MS) {
    // 近期已经触发过：视为「同步早已就绪」，不必再排补读
    return true;
  }
  const budget: number = Math.min(CLOUD_SYNC_TRIGGER_WAIT_MS, deadline - now);
  if (budget <= 0) {
    return false;
  }
  const done: boolean = await triggerSystemSync(budget);
  const stamp: number = Date.now();
  // 成功后按完整间隔限频；没跑完只按「重试间隔」限频（下一轮会再试）
  lastSyncTriggerAt = done ? stamp : stamp - (CLOUD_SYNC_TRIGGER_GAP_MS - CLOUD_SYNC_TRIGGER_RETRY_MS);
  if (!done) {
    console.info('[CloudSync] system sync not completed before read, read local snapshot');
  }
  return done;
}

/**
 * 读取轮（方案 §6）：遍历其他设备目录 → 差量下载 → 合并 → 应用。
 * 单设备 / 单文件失败跳过；预算耗尽剩余设备留到下一轮。
 */
async function readRound(deadline: number): Promise<void> {
  // **自己的目录也要读**：重装 / 换机后本机 el2/cloud 是空的，而数据就在
  // 「自己」那个云端目录里（deviceId 已改稳定 ODID，它就是上次安装写的那份）。
  // 排除自己 = 重装后永远读不到任何数据 —— 这正是「重装后不下发」的第二个原因。
  // 未变文件的 hash 比对会跳过下载，重复读的成本可忽略。
  const deviceIds: string[] = listCloudDeviceIds();
  console.info(`[CloudSync] read round: ${deviceIds.length} device dir(s) (own included)`);
  /** playlistId → 各设备版本 */
  const remotePlaylists: Map<string, Playlist[]> = new Map<string, Playlist[]>();
  const tombstoneMaps: Array<Record<string, number>> = [];
  const remoteSessions: PlaySession[] = [];
  /** 各设备的最近播放快照（逐条 LWW 合并的输入） */
  const recentPayloads: CloudRecentPayload[] = [];
  const hashUpdates: CloudFileHashPair[] = [];

  for (let d = 0; d < deviceIds.length; d++) {
    const devId: string = deviceIds[d];
    if (Date.now() > deadline) {
      budgetExhausted = true;
      console.info('[CloudSync] read round budget exhausted at devices scan');
      break;
    }
    // 设备元信息（设备名 / 版本 / 会话月份清单；坏了当 null 走默认）
    let meta: CloudDeviceMeta | null = null;
    const metaRaw: string | null = await readDeviceFile(devId, 'meta.json');
    if (metaRaw !== null) {
      meta = parseCloudMeta(metaRaw);
      hashUpdates.push({ key: `${devId}/meta.json`, hash: contentHash(metaRaw) });
    }
    // 「重置云同步」水位：早于它的设备目录整台跳过。
    // 删云端时应用侧只能删本地视图，能不能上行到云端由系统决定；这条水位保证
    // 即使旧目录又被系统拉回本机，也不会把「重置前那份数据」合并回来。
    // meta 读不到（null）时不跳：可能是从没写过 meta 的新目录，也可能是偶发读失败。
    const resetAt: number = getCloudResetAt();
    if (resetAt > 0 && meta !== null && meta.lastWriteAt < resetAt) {
      console.info(`[CloudSync] ${devId}: skipped (written ${meta.lastWriteAt} < reset ${resetAt})`);
      continue;
    }
    // 墓碑表
    const tbRaw: string | null = await readDeviceFile(devId, 'tombstones.json');
    if (tbRaw !== null) {
      const tb: Record<string, number> | null = parseCloudTombstones(tbRaw);
      if (tb !== null) {
        tombstoneMaps.push(tb);
      }
      hashUpdates.push({ key: `${devId}/tombstones.json`, hash: contentHash(tbRaw) });
    }
    // 歌单索引（提交点）：hash 对不上的条目才下载快照。
    // ⚠️ 索引拿不到时**只跳过歌单**，绝不能 `continue` 掉整台设备 —— 那样
    // 一台设备的索引下载失败，会连带它的拾音分片与最近播放一起读不回来，
    // 而这两类数据完全不需要索引。
    const idxRaw: string | null = await readDeviceFile(devId, 'playlist-index.json');
    let index: Record<string, CloudPlaylistIndexEntry> | null = null;
    if (idxRaw !== null) {
      index = parseCloudIndex(idxRaw);
      if (index !== null) {
        hashUpdates.push({ key: `${devId}/playlist-index.json`, hash: contentHash(idxRaw) });
      }
    }
    // 索引可用性：索引本身读不到（null）→ 只是没有差量信息；索引读到了但残缺
    // （历史版本用空索引覆盖过、或某轮只写了部分 id）→ 也只能靠兜底补。
    // 两个兜底来源都与索引**取并集**，不是仅在索引为空时才用：
    //  ① 目录列举 —— 只有目录已实体化才列得出（云端占位目录时有时无，不可靠）
    //  ② 历史读到过的路径（remoteHashes 持久化）—— 重装后为空，但读过一次就一直在
    // 不存在的 id 会在读取时失败并进入冷却（5 分钟），不会每轮都去打网络。
    let playlistIds: string[] = [];
    if (index !== null) {
      playlistIds = Object.keys(index);
    }
    const seenIds: Set<string> = new Set<string>(playlistIds);
    const extraIds: string[] = [];
    const dirNames: string[] = listDeviceFileNames(devId, 'playlists');
    for (let f = 0; f < dirNames.length; f++) {
      const nm: string = dirNames[f];
      if (nm.length > 5 && nm.substring(nm.length - 5) === '.json') {
        const id: string = nm.substring(0, nm.length - 5);
        if (!seenIds.has(id)) {
          seenIds.add(id);
          extraIds.push(id);
        }
      }
    }
    const knownNames: string[] = listKnownRemoteFiles(devId, 'playlists/');
    for (let f = 0; f < knownNames.length; f++) {
      const nm: string = knownNames[f];
      if (nm.length > 5 && nm.substring(nm.length - 5) === '.json') {
        const id: string = nm.substring(0, nm.length - 5);
        if (!seenIds.has(id)) {
          seenIds.add(id);
          extraIds.push(id);
        }
      }
    }
    if (extraIds.length > 0) {
      console.info(`[CloudSync] ${devId}: index has ${playlistIds.length}, `
        + `recover ${extraIds.length} more from dir/history`);
      playlistIds = playlistIds.concat(extraIds);
    } else if (playlistIds.length === 0 && index === null) {
      console.info(`[CloudSync] ${devId}: playlist index unavailable, skip playlists only`);
    }
    for (let i = 0; i < playlistIds.length; i++) {
      const plId: string = playlistIds[i];
      if (Date.now() > deadline) {
        budgetExhausted = true;
        break;
      }
      const relPath: string = `playlists/${plId}.json`;
      const entry: CloudPlaylistIndexEntry | undefined = index !== null ? index[plId] : undefined;
      // 差量跳过要同时满足三个条件，缺一个就会「每轮重下全部快照」：
      //  ① 本地已经有这个歌单（哈希说读过、本地其实没有 = 假跳过，数据回不来）；
      //  ② 记过已知 hash；
      //  ③ 有索引条目时索引 hash 也得一致。
      // 旧版目录 / 兜底恢复出来的 id 没有索引条目，只能靠 ① + ② —— 否则
      // 每轮同步都要把这几个快照重新下载一遍（真机实测一轮多花 4~5 秒）。
      const knownHash: string = getRemoteFileHash(devId, relPath);
      const entryHash: string = entry !== undefined ? entry.hash : '';
      if (LibraryStore.getPlaylist(plId) !== null && knownHash.length > 0
        && (entryHash.length === 0 || knownHash === entryHash)) {
        continue;
      }
      const raw: string | null = await readDeviceFile(devId, relPath);
      if (raw === null) {
        continue;
      }
      const parsed: Playlist | null = parseCloudPlaylist(raw);
      if (parsed === null) {
        // 坏快照：不更新已知 hash，下一轮重试
        continue;
      }
      const versions: Playlist[] | undefined = remotePlaylists.get(plId);
      if (versions !== undefined) {
        versions.push(parsed);
      } else {
        remotePlaylists.set(plId, [parsed]);
      }
      // 没有索引条目时只能按内容 hash 记（下次仍可比对）
      const h: string = entry !== undefined ? entry.hash : contentHash(raw);
      hashUpdates.push({ key: `${devId}/${relPath}`, hash: h });
    }
    // 会话月份分片：清单**三源并集**（meta ∪ 目录列举 ∪ 历史 hash key）。
    // 只信 meta 会在两种情况下把云端拾音永久锁死：
    //  ① 重装后本机还没有分片，写轮把 meta.sessionMonths 写成 [] 覆盖了云端清单；
    //  ② meta 下载失败 / 旧版本残缺少记了月份。
    // 与歌单 playlistIds 的兜底纪律一致：云端占位目录的列举时有时无，
    // 所以要并上 remoteHashes 里「这条路径确实读到过」的历史记录。
    const months: string[] = [];
    const addMonth = (name: string): void => {
      const key: string = monthKeyOf(name);
      if (key.length > 0 && months.indexOf(key) < 0) {
        months.push(key);
      }
    };
    if (meta !== null) {
      for (let i = 0; i < meta.sessionMonths.length; i++) {
        addMonth(meta.sessionMonths[i]);
      }
    }
    const dirMonthNames: string[] = listDeviceFileNames(devId, 'sessions');
    for (let i = 0; i < dirMonthNames.length; i++) {
      addMonth(dirMonthNames[i]);
    }
    const knownMonthNames: string[] = listKnownRemoteFiles(devId, 'sessions/');
    for (let i = 0; i < knownMonthNames.length; i++) {
      addMonth(knownMonthNames[i]);
    }
    /** 诊断计数：区分「没有月份清单 / 文件拿不到 / 已读过跳过」三种 0 条 */
    let sUnavailable: number = 0;
    let sUnchanged: number = 0;
    let sLines: number = 0;
    for (let m = 0; m < months.length; m++) {
      if (Date.now() > deadline) {
        budgetExhausted = true;
        break;
      }
      const month: string = months[m];
      const relPath: string = `sessions/${month}.jsonl`;
      const raw: string | null = await readDeviceFile(devId, relPath);
      if (raw === null || raw.length === 0) {
        sUnavailable++;
        continue;
      }
      const h: string = contentHash(raw);
      hashUpdates.push({ key: `${devId}/${relPath}`, hash: h });
      // ⚠️ 绝不能只比 remoteHashes：state 里那句「这份读过了」在本地数据被清空
      // 或卸载重装后仍然成立，于是云端分片每轮都被判 unchanged → sessionLines=0
      // → mergeBackupSessions 一次都不跑 → 拾音永远回不来。歌单那边早已修成
      // 「本地存在 + hash 命中」双条件，这里补上同一条纪律：
      //   hash 命中 **且** 本机该月分片非空、行数不少于远端（说明确实已合并过）。
      // 多设备合并后本机行数只会更多，所以每台都能正常跳过，不会每轮重解析。
      const knownHash: string = getRemoteFileHash(devId, relPath);
      if (knownHash === h) {
        const localRaw: string | null = await readMonthRaw(month);
        if (localRaw !== null && countJsonlLines(localRaw) >= countJsonlLines(raw)) {
          sUnchanged++;
          continue;
        }
      }
      const lines: string[] = raw.split('\n');
      for (let l = 0; l < lines.length; l++) {
        const line: string = lines[l].trim();
        if (line.length === 0) {
          continue;
        }
        try {
          // 逐行解析交给 mergeBackupSessions 的消毒规则收口（typeof 校验 + 保留窗过滤）
          remoteSessions.push(JSON.parse(line) as PlaySession);
          sLines++;
        } catch (e) {
          // 单行损坏：跳过该行，保留其余
        }
      }
    }
    // 拾音「一条都没读到」有三种完全不同的原因，日志里必须能分开：
    //   months=0        → 三源并集后仍没有月份（云端确实没分片）
    //   unavailable=N   → 云端文件拿不到（下载失败 / 占位读不出）
    //   unchanged=N     → 本机分片已包含这份远端数据（正常，不是故障）
    if (months.length > 0 || sUnavailable > 0 || sUnchanged > 0) {
      console.info(`[CloudSync] ${devId}: sessions months=${months.length} `
        + `unavailable=${sUnavailable} unchanged=${sUnchanged} newLines=${sLines} `
        + `meta=${meta !== null ? 'ok' : 'missing'}`);
    }
    // 最近播放（每设备一份 recent.json；逐条 LWW，见 mergeRecentTracks）
    if (Date.now() <= deadline) {
      const recentRaw: string | null = await readDeviceFile(devId, 'recent.json');
      if (recentRaw !== null) {
        const payload: CloudRecentPayload | null = parseCloudRecent(recentRaw);
        if (payload !== null) {
          recentPayloads.push(payload);
        }
        hashUpdates.push({ key: `${devId}/recent.json`, hash: contentHash(recentRaw) });
      }
    }
    counters.devices++;
  }
  putRemoteFileHashes(hashUpdates);
  // 一行看清本轮到底读到了什么：字段全为 0 = 远端目录不可见 / 全被跳过，
  // 与「读到了但内容没变」能在日志里直接区分开（真机排查唯一可用的现场）。
  console.info(`[CloudSync] read scanned ${counters.devices}/${deviceIds.length} dir(s): `
    + `playlists=${remotePlaylists.size} sessionLines=${remoteSessions.length} `
    + `recentPayloads=${recentPayloads.length}`);
  await applyRemote(remotePlaylists, tombstoneMaps, remoteSessions, recentPayloads);
}

/**
 * 应用远端数据（读取轮第二段）：墓碑删除 → 歌单合并 → 会话合并 → base 快照落盘。
 * 全程 applying 置位：由此触发的数据变更通知被忽略，不自我循环。
 */
async function applyRemote(remotePlaylists: Map<string, Playlist[]>,
  tombstoneMaps: Array<Record<string, number>>, remoteSessions: PlaySession[],
  recentPayloads: CloudRecentPayload[]): Promise<void> {
  let mergedTombstones: Record<string, number> = mergeTombstones(tombstoneMaps,
    CLOUD_TOMBSTONE_TTL_MS, Date.now());
  // 一次性豁免（见 CloudSyncStore.tombstonePurgeV1）：旧版本在「本地范围恰好为 0」
  // 的轮次里把整库记成了删除，那些误墓碑会删掉云端仍在的歌单快照。先豁免一次
  // 把数据救回来，之后墓碑恢复正常生效（误墓碑的产卵路径已在写轮堵死）。
  if (!isTombstonePurgeDone()) {
    const n: number = Object.keys(mergedTombstones).length;
    if (n > 0) {
      console.info(`[CloudSync] tombstone purge v1: skip ${n} stale tombstone(s) once`);
    }
    mergedTombstones = {};
    markTombstonePurgeDone();
  }
  const tombstoneIds: string[] = Object.keys(mergedTombstones);
  const localScope: Playlist[] = getPlaylistsForSync();
  const base: Record<string, string[]> = loadMergeBase();

  applying = true;
  try {
    // ① 墓碑：只做「判死标记」，**绝不删本地**。
    //
    // ⚠️ 这里原先真的调 `LibraryStore.deletePlaylist(id)`，真机实测后果是灾难性的：
    // `el2/cloud` 下「读不到」既可能是「云端确实没有」，也可能是「占位没实体化 /
    // 下载失败 / 读失败冷却期内被跳过」，两者**无法区分**。旧版本在「本地范围恰好
    // 为 0」的轮次里误写过一批墓碑，于是每轮都把「本轮没读到的快照」对应的本地
    // 歌单删掉 —— 用户侧就是歌单一轮一轮消失（实测一轮丢 4 个，且写轮随后把
    // 删除差集又记成新墓碑，越删越确定）。
    //
    // 取舍（与方案 §6「删除只能来自墓碑」的偏差必须写明）：墓碑只用来挡住
    // 「远端旧版本把已删歌单复活」，不再作为删本地的依据。代价是一端删歌单、
    // 另一端不会跟着删（漏一次删除传播），换来的是绝不误删一库 —— 在「读不到
    // ≠ 不存在」的环境里，这是唯一安全的等价物。
    let aliveConflicts: number = 0;
    for (let i = 0; i < tombstoneIds.length; i++) {
      if (remotePlaylists.has(tombstoneIds[i])) {
        aliveConflicts++;
      }
    }
    if (aliveConflicts > 0) {
      console.info(`[CloudSync] tombstone alive-conflict (local kept): ${aliveConflicts}`);
    }
    // ② 本地歌单与远端版本合并（有变的才进 upsert 批，省一次全量 persist）
    const mergedList: Playlist[] = [];
    const seenIds: Set<string> = new Set<string>();
    let shrunk: number = 0;
    // 「判死」集合**恒为空**：墓碑完全退出读取端。
    //
    // 真机实测两次误删都出在这里：`el2/cloud` 下「本轮没读到快照」有四种成因
    // —— ①云端确实没有 ②占位没实体化 ③读失败冷却期内被跳过 ④hash 命中被
    // 差量跳过（这个最阴：上一轮读过、记了 hash，这一轮就不再 parse，于是该
    // 歌单**根本不进 remotePlaylists**，看上去就像「远端没有它」）。四者无法
    // 区分。只要墓碑能把 id 判死，就会在「快照这次恰好没读到」时把用户手里
    // 还在的歌单删掉，或者挡住它从云端恢复 —— 两种都是数据消失。
    //
    // 删除传播在读取端**不做**（写轮也不 unlink 云端快照，见 writeRound ③ 的
    // 说明）。代价明确：一端删歌单、另一端不会跟着删，删除也不会阻止远端旧
    // 版本把已删歌单带回来；换来的是任何情况下都不会删掉用户还在的数据。
    const liveIds: Set<string> = new Set<string>();
    for (let i = 0; i < localScope.length; i++) {
      const local: Playlist = localScope[i];
      seenIds.add(local.id);
      if (liveIds.has(local.id)) {
        continue;
      }
      const versions: Playlist[] | undefined = remotePlaylists.get(local.id);
      const remotes: Playlist[] = versions !== undefined ? versions : [];
      // ⚠️ 远端一份「带曲目的有效快照」都没读到时，绝不能拿 base 做三路删除判定。
      // base 记着 N 个曲目 id、remotes 为空 → 三路会把每个 id 判成「远端删了」，
      // 结果是把本地整份曲目清空（真机每轮 merge shrank 就是这么来的）。
      // 读轮差量跳过 / 占位没实体化 / 下载失败都会造成 remotes 为空，这三种
      // 都不是删除信号。只有远端确实给出了带曲目的版本，才允许按 base 判删。
      let remoteHasTracks: boolean = false;
      for (let v = 0; v < remotes.length; v++) {
        if (remotes[v].tracks.length > 0) {
          remoteHasTracks = true;
          break;
        }
      }
      const baseIds: Set<string> | null = remoteHasTracks && base[local.id] !== undefined
        ? new Set<string>(base[local.id]) : null;
      const merged: Playlist = mergePlaylist(local, remotes, baseIds);
      if (JSON.stringify(merged) !== JSON.stringify(local)) {
        // 同步只增不减：远端快照残缺（空 tracks / 旧版本 / 下载半截）时，
        // 三路合并的 base 可能把本地曲目判成「被删过」。删曲目是本地行为，
        // 不该由云端触发 —— 只要这次合并会让本地曲目变少，就不写回。
        if (merged.tracks.length < local.tracks.length) {
          shrunk++;
          continue;
        }
        mergedList.push(merged);
      }
    }
    // ③ 远端独有歌单（本机没有的）：跨设备版本间并集（无本地视角，base 不可信 → 并集安全阀）
    const remoteIds: string[] = Array.from(remotePlaylists.keys());
    for (let r = 0; r < remoteIds.length; r++) {
      const plId: string = remoteIds[r];
      if (seenIds.has(plId) || liveIds.has(plId)) {
        continue;
      }
      const versions: Playlist[] = remotePlaylists.get(plId) ?? [];
      if (versions.length === 0) {
        continue;
      }
      const sorted: Playlist[] = versions.slice().sort(
        (a: Playlist, b: Playlist): number => updatedMsOf(b) - updatedMsOf(a));
      mergedList.push(mergePlaylist(sorted[0], sorted.slice(1), null));
    }
    if (shrunk > 0) {
      console.warn(`[CloudSync] merge shrank ${shrunk} playlist(s), kept local tracks`);
    }
    if (mergedList.length > 0) {
      batchUpsertFromCloud(mergedList);
    }
    counters.playlists = mergedList.length;
    // ④ 会话合并（mergeBackupSessions 自带去重：trackId|startedAt|ms）
    if (remoteSessions.length > 0) {
      const mergeResult: SessionMergeResult = await mergeBackupSessions(remoteSessions);
      // 「云端解析到 579 行、拾音页还是 0」必须能一眼分清是消毒全跳过、
      // 还是落盘后查不到：把合并结果与合并后真实可查询条数一起打出来。
      const queryable: PlaySession[] = await querySessions(0, Date.now());
      console.info(`[CloudSync] sessions merge: input=${remoteSessions.length} `
        + `merged=${mergeResult.merged} skipped=${mergeResult.skipped} `
        + `queryable=${queryable.length} months=${listMonthKeys().length}`);
      counters.sessions = mergeResult.merged;
    }
    // counters.sessions 记的是「真正合并进本机的条数」（见 ④）。报解析量会把
    // 「全部被消毒跳过」伪装成「同步了 579 条」，用户看到的正是这种假成功。
    // 一条都没解析到时由 resetCounters() 保证它是 0。
    // ⑤ 最近播放（逐条 LWW：同 id 取 playedAt 更大的那份）
    //    ⚠️ 单独兜一层：最近播放是后加的同步项，它出问题**不能**把整轮读取
    //    拖成失败 —— 那样连歌单 / 拾音的「已读取」时间都不会更新，用户看到
    //    的是「同步异常、什么都读不到」，而实际上前四步已经成功了。
    if (recentPayloads.length > 0) {
      try {
        const recentResult: RecentMergeResult = mergeRecentTracks(
          LibraryStore.getRecentTracks(), recentPayloads,
          getRecentClearedAt(), getRecentDeleted(),
          RECENT_KEEP_MS, RECENT_MAX_ITEMS, Date.now());
        LibraryStore.replaceRecentFromCloud(recentResult.tracks);
        // 远端的删除痕迹也记在本机：否则本机下一轮写回会把它「复活」成有效记录
        putRecentTraces(recentResult.deleted, recentResult.clearedAt);
      } catch (e) {
        console.warn(`[CloudSync] recent merge failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
      }
    }
    counters.recent = LibraryStore.getRecentTracks().length;
  } finally {
    applying = false;
  }
  // ⑤ base 快照更新为「合并完成后的同步范围」：下一轮三路合并的公共祖先。
  //    放在 applying 复位之后无妨 —— saveMergeBase 不触数据变更通知。
  const newBase: Record<string, string[]> = {};
  const scopeNow: Playlist[] = getPlaylistsForSync();
  for (let i = 0; i < scopeNow.length; i++) {
    newBase[scopeNow[i].id] = scopeNow[i].tracks.map((t: Track): string => t.id);
  }
  saveMergeBase(newBase);
  setLastReadAt(Date.now());
}

/**
 * 写回轮（方案 §7）：同步范围歌单 / 会话分片 / 墓碑 / 索引 / 元信息
 * 逐项 hash 比对，未变跳过。每设备只写自己目录（冲突被结构性消除）。
 */
/**
 * 写一个云端文件：**失败只记日志、绝不向外抛**。
 *
 * 一条纪律：写轮是「尽量多写成功」的批处理，不是事务。真机上出现过
 * 单个 `recent.json` 是「云端已无记录的孤儿占位」→ 写入抛异常 → 整轮中断 →
 * 歌单和拾音明明能写也没写，页面还卡在「同步中」永远不结束。
 * 返回 true 才允许记 hash：没写成功的文件下一轮必须重试，不能假装写过。
 */
async function writeOne(relPath: string, content: string): Promise<boolean> {
  try {
    await writeOwnFile(ownDeviceId, relPath, content);
    return true;
  } catch (e) {
    console.warn(`[CloudSync] write skipped ${relPath}: ${
      e instanceof Error ? e.message : JSON.stringify(e)}`);
    return false;
  }
}

async function writeRound(deadline: number): Promise<void> {
  // 真机排查用：这一行与函数末尾的 `write round:` 成对出现。
  // 只有 begin 没有末尾 = 卡在某次 writeOwnFile（fs.open/write 的 Promise 不返回），
  // 那种情况下整轮永远悬挂、running 一直是 true，后续所有同步请求都会被吞掉。
  console.info('[CloudSync] write round begin');
  // 读前的系统同步轮 / 读取轮的缓存下载都可能清扫本机空的云目录（实测
  // devices/ 会被删），而 runRound 开头那次 ensure 早已过去 —— 写之前重来一次。
  // writeOwnFile 内部还会逐文件补建，这里是提前失败、给出一句能看懂的错误。
  try {
    ensureDeviceDirs(ownDeviceId);
  } catch (e) {
    reportSyncFailure(`云端目录不可用: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    return;
  }
  let scope: Playlist[] = getPlaylistsForSync();
  // ⚠️ 空快照闸门：磁盘元信息说这个歌单有 N 个分片、内存里却是 0 首曲目时，
  // 说明分片还没装载完 / 预热中间态 / 上一次合并把缓存写空了。此刻把「空歌单」
  // 上传，云端唯一副本会被换成 300 字节的空壳；下一轮读回来再合并，runPersist
  // 会把 chunkCount 写成 0 并删掉所有分片 —— 用户曲目一次性消失。
  // 处理：本轮把歌单范围整体视为不可信（置空 → 快照 / 索引 / 墓碑全部跳过），
  // 拾音与最近播放不依赖歌单，照常写。用户真把歌单清空时 runPersist 会同步
  // 把 chunkCount 写成 0，两边一致，不会误伤。
  const unloaded: number = countPlaylistsWithUnloadedChunks();
  if (unloaded > 0) {
    console.warn(`[CloudSync] write round: ${unloaded} playlist(s) have chunks on disk `
      + `but empty tracks in memory, skip playlist writes this round`);
    scope = [];
  }
  const hashUpdates: CloudFileHashPair[] = [];
  const indexEntries: Record<string, CloudPlaylistIndexEntry> = {};
  // 诊断：本轮真正序列化进快照的曲目数 / 字节数。云端快照常年只有 300B 时，
  // 一眼就能分清是「本地 tracks 为空」还是「序列化漏了 tracks 字段」。
  let scopeTracks: number = 0;
  let scopeBytes: number = 0;

  // ① 歌单快照（hash 未变跳过重写 = 跳过一次系统上传）
  for (let i = 0; i < scope.length; i++) {
    if (Date.now() > deadline) {
      budgetExhausted = true;
      console.info('[CloudSync] write round budget exhausted at playlists');
      break;
    }
    const p: Playlist = scope[i];
    const relPath: string = `playlists/${p.id}.json`;
    const json: string = playlistCloudJson(p);
    scopeTracks += p.tracks.length;
    scopeBytes += json.length;
    const h: string = contentHash(json);
    indexEntries[p.id] = {
      rev: `${h}_${p.tracks.length}`,
      updatedAt: p.updatedAt,
      hash: h,
      trackCount: p.tracks.length
    };
    if (getOwnFileHash(relPath) === h) {
      continue;
    }
    if (await writeOne(relPath, json)) {
      hashUpdates.push({ key: relPath, hash: h });
    }
  }
  // ② 索引（提交点）：读取端先看它，才知道哪些快照值得下载
  //    ⚠️ **scope 为空时绝不写索引**。本地读到 0 个歌单有三种完全不同的原因：
  //    库还没加载完、只有收藏夹镜像（按口径不参与同步）、用户真删光了。
  //    前两种都不可信，而写一个 `{}` 会**覆盖云端原有索引** —— 其他设备下一轮
  //    就看到「云端一个歌单都没有」，重装更是直接不下发。索引只增不减：
  //    删歌单由墓碑传播，不靠把索引清空。这条曾经把用户的云端歌单抹成 0。
  if (scope.length > 0) {
    const idxJson: string = JSON.stringify(indexEntries);
    const idxHash: string = contentHash(idxJson);
    if (getOwnFileHash('playlist-index.json') !== idxHash) {
      if (await writeOne('playlist-index.json', idxJson)) {
        hashUpdates.push({ key: 'playlist-index.json', hash: idxHash });
      }
    }
  }
  // ③ 墓碑：上次写回时的范围 id 与本次差集 = 本机新删除；合并进自己墓碑表
  const prevIds: string[] = getOwnPlaylistIds();
  const currentIds: string[] = scope.map((p: Playlist): string => p.id);
  const currentSet: Set<string> = new Set<string>(currentIds);
  const nowMs: number = Date.now();
  let ownTombstones: Record<string, number> = {};
  const tbRaw: string | null = await readOwnFileDirect(ownDeviceId, 'tombstones.json');
  if (tbRaw !== null) {
    const parsed: Record<string, number> | null = parseCloudTombstones(tbRaw);
    if (parsed !== null) {
      ownTombstones = parsed;
    }
  }
  // ⚠️ 差集只在「本轮范围非空」时才算：scope 为 0 可能是库还没加载完 /
  //    只有收藏夹镜像，此时 prevIds 里的每一条都会被当成「本机新删除」写进
  //    墓碑表，其他设备读到就把歌单全删了 —— 比索引被清空更狠的误删路径。
  //    真删光所有歌单属于极罕见场景，宁可漏一次传播，也不能误删云端歌单。
  if (scope.length > 0) {
    for (let i = 0; i < prevIds.length; i++) {
      const id: string = prevIds[i];
      if (!currentSet.has(id) && ownTombstones[id] === undefined) {
        ownTombstones[id] = nowMs;
        console.info(`[CloudSync] tombstone recorded: ${id}`);
      }
    }
  }
  // ⚠️ 这里**故意不删云端快照**（曾经想过用 unlink 表达删除传播，已放弃）：
  // 差集 `prevIds - currentIds` 分不清「用户删了这个歌单」和「本地这一轮把歌单
  // 弄丢了」（库没加载完 / 被误删 / 迁移中间态）。误删后第一次写轮如果去
  // unlink，删掉的正是云端唯一副本 —— 那是把「本地丢失」升级成「永久丢失」。
  // 结论：删除不跨设备传播（漏一次传播），换取任何情况下都不删数据。
  // TTL 过期条目出表（60 天前的删除不再传播，也阻止陈旧复活）
  const liveTombstones: Record<string, number> = {};
  const tbIds: string[] = Object.keys(ownTombstones);
  for (let i = 0; i < tbIds.length; i++) {
    const t: number = ownTombstones[tbIds[i]];
    if (typeof t === 'number' && Number.isFinite(t) && nowMs - t <= CLOUD_TOMBSTONE_TTL_MS) {
      liveTombstones[tbIds[i]] = t;
    }
  }
  const tbJson: string = JSON.stringify(liveTombstones);
  const tbHash: string = contentHash(tbJson);
  if (getOwnFileHash('tombstones.json') !== tbHash) {
    if (await writeOne('tombstones.json', tbJson)) {
      hashUpdates.push({ key: 'tombstones.json', hash: tbHash });
    }
  }
  // ④ 会话月份分片（与本地分片同构，逐月 hash 比对）
  const monthKeys: string[] = listMonthKeys();
  const writtenMonths: string[] = [];
  for (let m = 0; m < monthKeys.length; m++) {
    if (Date.now() > deadline) {
      budgetExhausted = true;
      break;
    }
    const month: string = monthKeys[m];
    const raw: string | null = await readMonthRaw(month);
    if (raw === null || raw.length === 0) {
      continue;
    }
    writtenMonths.push(month);
    const relPath: string = `sessions/${month}.jsonl`;
    const h: string = contentHash(raw);
    if (getOwnFileHash(relPath) === h) {
      continue;
    }
    if (await writeOne(relPath, raw)) {
      hashUpdates.push({ key: relPath, hash: h });
    }
  }
  // ⑤ 最近播放（全量快照 + 本机删除痕迹；单文件，hash 未变跳过）
  //    为什么整表重写而不是增量：读取端只认「一个设备一份完整视图」，
  //    增量文件需要压缩与排序，出错就是「某些记录永远缺一块」。
  //    体积上限 200 条 × 约 560B ≈ 110KB，hash 去重后一轮最多写一次。
  const recentSlim: Track[] = LibraryStore.getRecentTracks().map((t: Track): Track => {
    const slim: Track = slimTrack(t);
    // 来源设备的本机路径在别的设备上无效，且会误导「已下载」判断
    slim.localFilePath = '';
    return slim;
  });
  const rawDeleted: Record<string, number> = getRecentDeleted();
  const liveRecentDeleted: Record<string, number> = {};
  const rdIds: string[] = Object.keys(rawDeleted);
  for (let i = 0; i < rdIds.length; i++) {
    const ts: number = rawDeleted[rdIds[i]];
    // TTL 与保留窗同长：记录本身 7 天后就消失了，墓碑再留着没有意义
    if (typeof ts === 'number' && Number.isFinite(ts) && nowMs - ts <= RECENT_KEEP_MS) {
      liveRecentDeleted[rdIds[i]] = ts;
    }
  }
  const recentJson: string = JSON.stringify({
    clearedAt: getRecentClearedAt(),
    tracks: recentSlim,
    deleted: liveRecentDeleted
  });
  const recentHash: string = contentHash(recentJson);
  if (getOwnFileHash('recent.json') !== recentHash) {
    if (await writeOne('recent.json', recentJson)) {
      hashUpdates.push({ key: 'recent.json', hash: recentHash });
    }
  }
  // ⑥ 设备元信息（设备名 / 版本 / 月份清单 / 最后写回时间）
  //
  // ⚠️ hash 只算「会变但真正重要」的字段（设备名 / 版本 / 月份清单），**不含
  // lastWriteAt**：它每轮都是新时间戳，算进 hash 就等于「每轮必写一个文件」，
  // 于是页面上的「N 个文件等待系统上传」永远不归零 —— 用户看到的就是「同步
  // 好像一直没完成」，而我们又没法用这个数字判断到底有没有卡住。
  // cloud meta 里的 lastWriteAt 只是给「云端设备」列表看的展示字段，陈旧一轮
  // 没有影响；本页显示的「上次读取」用的是本地 state.lastReadAt。
  // ⚠️ 重装后本机还没有任何分片（monthKeys=[]）时，绝不能用空清单覆盖云端 meta：
  // 读端按 meta.sessionMonths 枚举分片，写空 = 把云端唯一的月份索引抹掉，
  // 下一轮开始谁都不知道云端还有拾音数据。与「scope=0 不写 playlist-index」
  // 同一条纪律 —— 写轮不能凭「本机暂时没有」就去删上游记录。
  const sessionMonths: string[] = [];
  for (let i = 0; i < writtenMonths.length; i++) {
    sessionMonths.push(writtenMonths[i]);
  }
  let prevMeta: CloudDeviceMeta | null = null;
  if (sessionMonths.length === 0) {
    // ① 自己云端目录的旧 meta（读轮刚下载过，通常是本地缓存命中）
    try {
      const ownMetaRaw: string | null = await readDeviceFile(getCloudDeviceId(), 'meta.json');
      prevMeta = ownMetaRaw !== null ? parseCloudMeta(ownMetaRaw) : null;
    } catch (e) {
      prevMeta = null;
    }
    if (prevMeta !== null) {
      for (let i = 0; i < prevMeta.sessionMonths.length; i++) {
        const k: string = monthKeyOf(prevMeta.sessionMonths[i]);
        if (k.length > 0 && sessionMonths.indexOf(k) < 0) {
          sessionMonths.push(k);
        }
      }
    }
    // ② 历史读到过的 sessions 路径（纯内存；meta 下载失败时兜底）
    const known: string[] = listKnownRemoteFiles(getCloudDeviceId(), 'sessions/');
    for (let i = 0; i < known.length; i++) {
      const k: string = monthKeyOf(known[i]);
      if (k.length > 0 && sessionMonths.indexOf(k) < 0) {
        sessionMonths.push(k);
      }
    }
  }
  const meta: CloudDeviceMeta = {
    deviceName: deviceName,
    appVersion: appVersion,
    lastWriteAt: nowMs,
    sessionMonths: sessionMonths
  };
  const metaJson: string = JSON.stringify(meta);
  const metaHash: string = contentHash(JSON.stringify({
    deviceName: deviceName,
    appVersion: appVersion,
    sessionMonths: sessionMonths
  }));
  // 本机没分片且连旧 meta 都拿不到时，本轮干脆不写：宁可少一次元信息更新，
  // 也不能冒险把云端清单覆盖成空（首次安装时云端本来也没有 meta，无损失）。
  const canWriteMeta: boolean = writtenMonths.length > 0 || prevMeta !== null;
  if (canWriteMeta && getOwnFileHash('meta.json') !== metaHash) {
    if (await writeOne('meta.json', metaJson)) {
      hashUpdates.push({ key: 'meta.json', hash: metaHash });
    }
  }
  putOwnFileHashes(hashUpdates);
  // 范围为空时不更新「上次写回的范围 id」：写成空数组会让下一轮失去差集基准，
  // 用户之后真删掉的歌单永远检测不出来（漏删一次，比误删一库好）
  if (scope.length > 0) {
    setOwnPlaylistIds(currentIds);
  }
  // hash 未变被跳过的不计数：这个数字要回答「本轮真的往云端写了几个文件」
  counters.written = hashUpdates.length;
  // 这行是「拾音传不上去」的第一判据：months=0 说明本机根本没有可写的月份
  // 分片（listMonthKeys 空 / 本地没听过歌），而不是写入或上传失败。
  console.info(`[CloudSync] write round: playlists=${scope.length} tracks=${scopeTracks} `
    + `snapshotBytes=${scopeBytes} months=${monthKeys.length} `
    + `monthsWritten=${writtenMonths.length} metaMonths=${sessionMonths.length} `
    + `recent=${recentSlim.length} written=${counters.written}`);
}
