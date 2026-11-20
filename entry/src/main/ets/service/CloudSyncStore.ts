/**
 * 云同步本地状态存储（方案 §8.1 CloudSyncStore）。
 *
 * 持久化两份文件（都在 filesDir，**绝不进 Preferences**）：
 *   · cloud_sync_state.json —— 本机身份与同步状态：
 *     deviceId（**优先系统 ODID：跨重装稳定**，取不到才退回 UUID；
 *     旧版本用纯 UUID 的安装会在首次启动时迁移，并把旧 id 记进
 *     legacyDeviceIds —— 那些目录是同一台设备的历次安装，读轮仍要读，
 *     但不计入「设备数」）、自动读取 / 仅 WiFi 读取开关、上次读取时间、
 *     远端文件 hash 表（差量判定）、本机已写 hash 表（回写跳过未变文件）；
 *   · cloud_sync_base.json —— 三路合并的 base 快照（上次同步成功时各歌单
 *     曲目 id 集合，方案 §5.2 / §14.2：20 歌单 × 100 曲目 id ≈ 40 KB，
 *     远超 Preferences 单值 8192 上限 → 静默截断 → 删除永不传播，必须放文件）。
 *
 * 内存缓存即真源（AppPreferences 同款纪律）：读同步、写先换缓存再异步落盘。
 * 写沿 saveChain 串行，读不需要 await（启动时同步读一次装填）。
 */

import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { deviceInfo } from '@kit.BasicServicesKit';

/** 状态文件名（filesDir 下） */
const STATE_FILE_NAME: string = 'cloud_sync_state.json';
/** base 快照文件名（filesDir 下） */
const BASE_FILE_NAME: string = 'cloud_sync_base.json';
/** 状态结构版本 */
const CLOUD_SYNC_SCHEMA_VERSION: number = 1;
/** deviceId 来源：系统 ODID（跨重装 / 多次安装稳定，恢复出厂才变） */
const DEVICE_ID_SOURCE_ODID: string = 'odid';
/** deviceId 来源：UUID 兜底（设备取不到 ODID 时） */
const DEVICE_ID_SOURCE_RANDOM: string = 'random';

/** 文件 hash 对（key = 相对路径或 '{deviceId}/{relPath}'） */
export interface CloudFileHashPair {
  key: string;
  hash: string;
}

/** 落盘的完整状态（JSON.parse 的一次性收口） */
interface CloudSyncPersistedState {
  schemaVersion: number;
  deviceId: string;
  /** deviceId 来源：'odid' | 'random'（旧版本文件没有这个字段 = 按 random 处理并迁移） */
  deviceIdSource: string;
  /** 本机历史安装用过的 deviceId（那些云端目录也是自己写的：读轮要读，但不计设备数） */
  legacyDeviceIds: string[];
  autoRead: boolean;
  /** 上次成功读取云端的 ms 时间戳（0 = 从未） */
  lastReadAt: number;
  /** 上次完整一轮（含写回）的 ms 时间戳（前台化 >5min 节流用） */
  lastRoundAt: number;
  /** 上一轮整体失败的人话原因（空 = 正常） */
  lastError: string;
  /** 远端文件 hash：key = '{deviceId}/{relPath}'，value = 内容 hash */
  remoteHashes: Record<string, string>;
  /** 本机已写文件 hash：key = relPath，value = 内容 hash（未变跳过重写） */
  ownHashes: Record<string, string>;
  /** 上次写回云端时在同步范围内的歌单 id（下次差集出墓碑） */
  ownPlaylistIds: string[];
  /**
   * 本机「清空最近播放」的时刻（0 = 从未）。
   * 清空要跨设备传播，用一个时间戳表达「比它早的记录都作废」，
   * 比给 200 条逐条写墓碑省一个数量级，且天然幂等。
   */
  recentClearedAt: number;
  /** 本机删过的最近播放条目：曲目 id → 删除时刻（ms，TTL = 最近播放保留窗） */
  recentDeleted: Record<string, number>;
  /**
   * 一次性墓碑豁免是否已执行（true = 已执行）。
   *
   * 旧版本在「本地同步范围恰好为 0」的轮次里，把 ownPlaylistIds 里的每一条都
   * 当成「本机新删除」写进了墓碑表 —— 而这些轮次的 0 只是库刚启动还没加载完 /
   * 只剩收藏夹镜像。那些误墓碑会连带删掉云端仍完好的歌单快照。
   * 首次跑到这里时整表豁免一次，把还能读到的快照救回来；之后正常生效。
   */
  tombstonePurgeV1: boolean;
  /**
   * 上次「重置云同步」的时刻（0 = 从未）。
   *
   * 用户点重置时云端目录会被尽量删掉，但「本地删除是否上行到云端」由系统
   * 决定、应用侧无法保证。这个水位是兜底：读轮遇到 `meta.lastWriteAt`
   * 早于它的设备目录直接整台跳过 —— 即使旧目录被系统重新拉回本机，
   * 也不会再把「重置前的那份数据」当成数据源合并回来。
   */
  resetAt: number;
}

function emptyState(): CloudSyncPersistedState {
  return {
    schemaVersion: CLOUD_SYNC_SCHEMA_VERSION,
    deviceId: '',
    deviceIdSource: DEVICE_ID_SOURCE_RANDOM,
    legacyDeviceIds: [],
    autoRead: true,
    lastReadAt: 0,
    lastRoundAt: 0,
    lastError: '',
    remoteHashes: {},
    ownHashes: {},
    ownPlaylistIds: [],
    recentClearedAt: 0,
    recentDeleted: {},
    tombstonePurgeV1: false,
    resetAt: 0
  };
}

/**
 * 读系统 ODID（Open Device Identifier）：同一设备、同一 developerId 下
 * **卸载重装不变**（只有恢复出厂 / 卸载同签名全部应用才重生成），且无需权限。
 *
 * 这正是「同一台设备多次安装被当成多台设备」的解药 —— 旧实现用
 * `util.generateRandomUUID()`，每次安装都是新身份、新云端目录，
 * 装三次就有三个目录，设备数只增不减，重装后也认不回自己的旧数据。
 *
 * 格式形如 `1234a567-XXXX-XXXX-XXXX-XXXXXXXXXXXX`（36 字符，仅 [0-9a-zA-Z-]）。
 * 取不到（老设备 / 企业机 / 抛异常）返回空串，由调用方退回 UUID。
 */
function readOdid(): string {
  try {
    const odid: string = deviceInfo.ODID ?? '';
    if (odid.length < 8 || odid.length > 64) {
      return '';
    }
    for (let i = 0; i < odid.length; i++) {
      const c: string = odid.charAt(i);
      const ok: boolean = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z')
        || (c >= 'A' && c <= 'Z') || c === '-';
      if (!ok) {
        // 含非法字符（目录名安全阀与 CloudDirClient.isValidDeviceId 对齐）
        return '';
      }
    }
    return odid;
  } catch (e) {
    return '';
  }
}

let state: CloudSyncPersistedState = emptyState();
let stateFilePath: string = '';
let baseFilePath: string = '';
let inited: boolean = false;

/** 串行落盘链（写失败只记日志，内存缓存仍是真源） */
let saveChain: Promise<void> = Promise.resolve();

/** 三路合并 base 快照（playlistId → 曲目 id 集合）；空 Record = 无 base（并集模式） */
let mergeBase: Record<string, string[]> = {};

/** 覆盖写文本文件（fs 无 writeTextFile，统一 open→write→close） */
async function writeTextFile(path: string, content: string): Promise<void> {
  const file: fs.File = await fs.open(path,
    fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    await fs.write(file.fd, content);
  } finally {
    await fs.close(file);
  }
}

function persistState(): void {
  const json: string = JSON.stringify(state);
  const path: string = stateFilePath;
  saveChain = saveChain.then((): Promise<void> => {
    return writeTextFile(path, json);
  }).then((): void => {
  }, (e: Error): void => {
    console.error(`[CloudSyncStore] save state failed: ${e.message}`);
  });
}

/**
 * 初始化（AppContainer.initRest 调用，幂等）：装填状态 + 首跑生成 deviceId。
 */
export function initCloudSyncStore(context: common.Context): void {
  if (inited) {
    return;
  }
  inited = true;
  stateFilePath = `${context.filesDir}/${STATE_FILE_NAME}`;
  baseFilePath = `${context.filesDir}/${BASE_FILE_NAME}`;
  try {
    const raw: string = fs.readTextSync(stateFilePath);
    const parsed: CloudSyncPersistedState = JSON.parse(raw) as CloudSyncPersistedState;
    state = {
      schemaVersion: CLOUD_SYNC_SCHEMA_VERSION,
      deviceId: typeof parsed.deviceId === 'string' ? parsed.deviceId : '',
      deviceIdSource: typeof parsed.deviceIdSource === 'string'
        ? parsed.deviceIdSource : DEVICE_ID_SOURCE_RANDOM,
      legacyDeviceIds: Array.isArray(parsed.legacyDeviceIds)
        ? parsed.legacyDeviceIds.filter((s: string): boolean => typeof s === 'string') : [],
      autoRead: parsed.autoRead !== false,
      lastReadAt: typeof parsed.lastReadAt === 'number' ? parsed.lastReadAt : 0,
      lastRoundAt: typeof parsed.lastRoundAt === 'number' ? parsed.lastRoundAt : 0,
      lastError: typeof parsed.lastError === 'string' ? parsed.lastError : '',
      remoteHashes: parsed.remoteHashes !== undefined && parsed.remoteHashes !== null ? parsed.remoteHashes : {},
      ownHashes: parsed.ownHashes !== undefined && parsed.ownHashes !== null ? parsed.ownHashes : {},
      ownPlaylistIds: Array.isArray(parsed.ownPlaylistIds) ? parsed.ownPlaylistIds : [],
      recentClearedAt: typeof parsed.recentClearedAt === 'number' && Number.isFinite(parsed.recentClearedAt)
        ? parsed.recentClearedAt : 0,
      recentDeleted: parsed.recentDeleted !== undefined && parsed.recentDeleted !== null
        && typeof parsed.recentDeleted === 'object' ? parsed.recentDeleted : {},
      // 旧文件没有这个字段 = 尚未豁免过（注意用 === true，缺字段即 false）
      tombstonePurgeV1: parsed.tombstonePurgeV1 === true,
      resetAt: typeof parsed.resetAt === 'number' && Number.isFinite(parsed.resetAt)
        ? parsed.resetAt : 0
    };
  } catch (e) {
    // 首跑 / 文件损坏：空状态起步（base 同理走并集安全阀，绝不误删）
    state = emptyState();
  }
  const odid: string = readOdid();
  if (state.deviceId.length === 0) {
    state.deviceId = odid.length > 0 ? odid : util.generateRandomUUID(true);
    state.deviceIdSource = odid.length > 0 ? DEVICE_ID_SOURCE_ODID : DEVICE_ID_SOURCE_RANDOM;
    persistState();
  } else if (odid.length > 0 && state.deviceId !== odid) {
    // 迁移到稳定身份：旧 id 的云端目录**仍是本机写的**（里面可能留着上次安装
    // 之前的数据），记进 legacyDeviceIds —— 读轮照读、设备计数排除。
    if (state.legacyDeviceIds.indexOf(state.deviceId) < 0) {
      state.legacyDeviceIds.push(state.deviceId);
    }
    state.deviceId = odid;
    state.deviceIdSource = DEVICE_ID_SOURCE_ODID;
    // ⚠️ 必须清空 ownHashes：它的 key 是相对路径、与新目录无关，留着会让
    // 写轮误判「这些文件已经写过了」→ 新目录永远是空的、数据再也传不上去。
    state.ownHashes = {};
    persistState();
    console.info(`[CloudSyncStore] device id migrated to ODID, legacy=${state.legacyDeviceIds.length}`);
  }
  // 身份来源必须进日志：「同一台设备多次安装算多台」只有一个根因 ——
  // deviceId 不是稳定标识（ODID 取不到 → 退回随机 UUID → 每次安装都换目录）。
  // 只打 id 前 8 位够定位，不必把完整标识写进日志。
  console.info(`[CloudSyncStore] deviceId source=${state.deviceIdSource} `
    + `id=${state.deviceId.substring(0, 8)} legacy=${state.legacyDeviceIds.length}`);
  try {
    const rawBase: string = fs.readTextSync(baseFilePath);
    const parsedBase: Record<string, string[]> = JSON.parse(rawBase) as Record<string, string[]>;
    if (parsedBase !== null && parsedBase !== undefined) {
      mergeBase = parsedBase;
    }
  } catch (e) {
    mergeBase = {};
  }
}

/** 未 init（EntryAbility.onCreate 之前的理论不可达）一律安全默认 */
export function getCloudDeviceId(): string {
  return state.deviceId;
}

/** 自动读取（打开 App 时拉取云端最新数据），默认开 */
export function isAutoRead(): boolean {
  return state.autoRead;
}

export function setAutoRead(v: boolean): void {
  state.autoRead = v;
  persistState();
}

export function getLastReadAt(): number {
  return state.lastReadAt;
}

export function setLastReadAt(ts: number): void {
  state.lastReadAt = ts;
  persistState();
}

export function getLastRoundAt(): number {
  return state.lastRoundAt;
}

export function setLastRoundAt(ts: number): void {
  state.lastRoundAt = ts;
  persistState();
}

export function getLastCloudSyncError(): string {
  return state.lastError;
}

export function setLastCloudSyncError(msg: string): void {
  state.lastError = msg;
  persistState();
}

/** 远端文件已知 hash（差量判定：远端 hash ≠ 已知 → 待下载集合） */
export function getRemoteFileHash(deviceId: string, relPath: string): string {
  const key: string = `${deviceId}/${relPath}`;
  const h: string | undefined = state.remoteHashes[key];
  return h !== undefined ? h : '';
}

/** 批量落远端 hash（一轮读成功后一次写盘，避免逐 key 落盘） */
export function putRemoteFileHashes(pairs: CloudFileHashPair[]): void {
  for (let i = 0; i < pairs.length; i++) {
    state.remoteHashes[pairs[i].key] = pairs[i].hash;
  }
  persistState();
}

/**
 * 本地已合并/删除某歌单后，把它在所有设备上的「已知远端文件」记忆一并抹掉。
 *
 * 读轮在索引为空 / 目录列举不到时会用 remoteHashes 的历史 key 兜底恢复
 * （listKnownRemoteFiles）。不抹掉的话，刚删掉的同名空壳会在下一轮被这份
 * 历史记录重新下载、又作为「远端独有歌单」加回本地 —— 去重永远做不干净。
 */
export function forgetRemotePlaylist(playlistId: string): number {
  const needle: string = `/playlists/${playlistId}.json`;
  const next: Record<string, string> = {};
  const keys: string[] = Object.keys(state.remoteHashes);
  let removed: number = 0;
  for (let i = 0; i < keys.length; i++) {
    const k: string = keys[i];
    if (k.indexOf(needle) >= 0 || k === `playlists/${playlistId}.json`) {
      removed++;
      continue;
    }
    next[k] = state.remoteHashes[k];
  }
  if (removed > 0) {
    state.remoteHashes = next;
    persistState();
  }
  return removed;
}

/** 本机已写文件 hash（回写时未变跳过，省掉重复写 + 重复上传） */
export function getOwnFileHash(relPath: string): string {
  const h: string | undefined = state.ownHashes[relPath];
  return h !== undefined ? h : '';
}

/** 批量落本机 hash（一轮写回后一次写盘） */
export function putOwnFileHashes(pairs: CloudFileHashPair[]): void {
  for (let i = 0; i < pairs.length; i++) {
    state.ownHashes[pairs[i].key] = pairs[i].hash;
  }
  persistState();
}

/** 上次写回时同步范围内的歌单 id 列表（墓碑差集的基准） */
export function getOwnPlaylistIds(): string[] {
  return state.ownPlaylistIds.slice();
}

export function setOwnPlaylistIds(ids: string[]): void {
  state.ownPlaylistIds = ids.slice();
  persistState();
}

/**
 * 本机历史上「读到过」的远端文件相对路径（按前缀筛，返回去掉 `{deviceId}/` 之后的相对路径）。
 *
 * 用途：云端索引被清空 / 目录列举失败时的恢复入口。`remoteHashes` 是持久化的，
 * 只要读过一次就在，比 `fs.listFileSync` 在云端占位目录上可靠得多
 * （真机实测：同一目录有时列得出、有时返回空，取决于系统有没有把目录实体化）。
 */
export function listKnownRemoteFiles(deviceId: string, relPrefix: string): string[] {
  const key: string = `${deviceId}/${relPrefix}`;
  const out: string[] = [];
  const names: string[] = Object.keys(state.remoteHashes);
  for (let i = 0; i < names.length; i++) {
    const k: string = names[i];
    if (k.length > key.length && k.substring(0, key.length) === key) {
      out.push(k.substring(key.length));
    }
  }
  return out;
}

/** 一次性墓碑豁免是否已执行（逐行读取，兼容旧文件缺字段） */
export function isTombstonePurgeDone(): boolean {
  return state.tombstonePurgeV1 === true;
}

export function markTombstonePurgeDone(): void {
  state.tombstonePurgeV1 = true;
  persistState();
}

/** 上次「重置云同步」的时刻（0 = 从未）；读轮据此跳过早于它的设备目录 */
export function getCloudResetAt(): number {
  return state.resetAt;
}

/**
 * 「重置云同步」的本地半边：把同步状态清成「这台设备从没同步过」，
 * 但**保留身份**（deviceId / deviceIdSource / autoRead）—— 身份一变就又是
 * 一个新的云端目录，那正是「同一台手机被算成多台设备」的老病根。
 *
 * 必须清 ownHashes：云端目录已被删空，而它的 key 是相对路径、与目录存不存在
 * 无关，留着会让写轮误判「这些文件已经写过了」→ 新目录永远空、数据再也传不
 * 上去（deviceId 迁移到 ODID 时踩过同一个坑，见 initCloudSyncStore 注释）。
 *
 * 必须设 resetAt：见字段注释 —— 删云端做不到「一定生效」，读轮要靠它兜底。
 */
export function resetCloudSyncState(): void {
  state.remoteHashes = {};
  state.ownHashes = {};
  state.ownPlaylistIds = [];
  state.recentClearedAt = 0;
  state.recentDeleted = {};
  state.lastReadAt = 0;
  state.lastRoundAt = 0;
  state.lastError = '';
  // 墓碑已随云端一起清空，不需要再跑一次历史豁免
  state.tombstonePurgeV1 = true;
  state.resetAt = Date.now();
  mergeBase = {};
  saveMergeBase({});
  persistState();
  console.info(`[CloudSyncStore] sync state reset, resetAt=${state.resetAt}`);
}

/**
 * 三路合并 base 快照读取（playlistId → 曲目 id 集合）。
 * 空 Record = 首次同步 / base 丢失 → 合并自动进「并集永不删除」安全阀。
 */
export function loadMergeBase(): Record<string, string[]> {
  return mergeBase;
}

/** base 快照写入（一轮同步成功应用后调用；文件小，直接覆盖） */
export function saveMergeBase(base: Record<string, string[]>): void {
  mergeBase = base;
  const json: string = JSON.stringify(base);
  const path: string = baseFilePath;
  saveChain = saveChain.then((): Promise<void> => {
    return writeTextFile(path, json);
  }).then((): void => {
  }, (e: Error): void => {
    console.error(`[CloudSyncStore] save merge base failed: ${e.message}`);
  });
}

/* ---------------- 最近播放的删除痕迹（跨设备传播用） ---------------- */

/** 本机清空最近播放的时刻（0 = 从未） */
export function getRecentClearedAt(): number {
  return state.recentClearedAt;
}

/** 记一次「清空最近播放」：此后 playedAt 早于该时刻的记录不再复活 */
export function markRecentCleared(ts: number): void {
  state.recentClearedAt = ts;
  // 清空已覆盖全量，逐条墓碑失去意义（留着只会让文件变大）
  state.recentDeleted = {};
  persistState();
}

/** 本机删过的条目（副本；调用方改动不影响内部状态） */
export function getRecentDeleted(): Record<string, number> {
  const out: Record<string, number> = {};
  const ids: string[] = Object.keys(state.recentDeleted);
  for (let i = 0; i < ids.length; i++) {
    out[ids[i]] = state.recentDeleted[ids[i]];
  }
  return out;
}

/** 记一条删除（最近播放页的单条移除） */
export function markRecentDeleted(id: string, ts: number): void {
  if (typeof id !== 'string' || id.length === 0) {
    return;
  }
  state.recentDeleted[id] = ts;
  persistState();
}

/** 用合并结果覆盖墓碑表与清空时刻（读取轮末尾调用：让远端删除也记在本机） */
export function putRecentTraces(deleted: Record<string, number>, clearedAt: number): void {
  state.recentDeleted = deleted;
  if (clearedAt > state.recentClearedAt) {
    state.recentClearedAt = clearedAt;
  }
  persistState();
}
