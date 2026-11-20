/**
 * 华为云空间云端目录客户端（方案 §4 读写实现）。
 *
 * 前提：AppScope/app.json5 已开 `"cloudFileSyncEnabled": true`，数据写进
 * `context.cloudFileDir`（即 /data/storage/el2/cloud），由系统负责上传到
 * 用户的华为云空间并在同账号多设备间同步 —— App 零凭证、零请求。
 *
 * 目录布局（方案 §3，每设备只写自己的目录，冲突被结构性消除）：
 * ```
 * {cloudFileDir}/bilimusic/
 *   devices/
 *     {deviceId}/
 *       meta.json                     {deviceName, appVersion, lastWriteAt, ...}
 *       playlist-index.json           {playlistId: {rev, updatedAt, hash, trackCount}}
 *       tombstones.json               {playlistId: deletedAtMs}
 *       playlists/{playlistId}.json   单个歌单完整快照
 *       sessions/{YYYY-MM}.jsonl      月度会话分片（与本地分片同构）
 *       recent.json                  最近播放全量快照 + 删除痕迹
 * ```
 *
 * 硬约束（方案 §4.2 / §14.3，全部来自 SDK d.ts 与官方适配指南）：
 *   1. `CloudFileCache.start` 并发上限 10（超限抛 22400004，官方原话
 *      「超过此限制会导致整机异常」）→ 本模块一律走串行下载队列
 *      （CLOUD_CACHE_CONCURRENCY = 1，最保守值）。
 *   2. `start` 抛 13900002（文件不存在）/ 13900025（空间不足）/
 *      14000002（uri 非法），由调用方分类处理，不当一律失败。
 *   3. 云端占位文件**不能**用 fs.readSync 直接读 —— 必须先
 *      `CloudFileCache.start(uri)`，等它被拉成本机实体后再读。
 *      本模块 readDeviceFile 统一封装：先试直读（本机已缓存 / 自己刚写的
 *      文件都是真实内容，零成本快路径），失败或空内容才走缓存下载；
 *      下载侧**轮询 readText 判就绪**而不是等 progress 事件（理由见
 *      downloadAndWait 注释：只等事件会在事件不派发时白等满超时）。
 */

import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';
import cloudSync from '@ohos.file.cloudSync';
import { BusinessError } from '@kit.BasicServicesKit';

/** 云端根目录名（cloudFileDir 下） */
const CLOUD_ROOT_DIR_NAME: string = 'bilimusic';
/** 设备目录名 */
const CLOUD_DEVICES_DIR_NAME: string = 'devices';
/**
 * 单文件缓存下载超时（ms）。
 *
 * 之所以从 30s 压到 12s：一轮预算只有 60s，而一台设备至少要读 meta /
 * tombstones / playlist-index 三个入口文件。单个文件卡住 30s 时，索引还没拿到
 * 预算就耗尽了 —— 界面表现就是「一点云端数据都读不到」。12s 对几 KB~200KB
 * 的文本文件足够，超时只是「本轮先跳过、下一轮再试」。
 */
export const CLOUD_FILE_DOWNLOAD_TIMEOUT_MS: number = 12000;
/** 等云端占位文件变实体时的轮询间隔（ms） */
const CLOUD_DOWNLOAD_POLL_MS: number = 300;
/** 缓存下载并发上限：官方上限 10，超限整机异常，取最保守值 1（串行） */
export const CLOUD_CACHE_CONCURRENCY: number = 1;

/** 探针文件名（落在云端根目录，验证 el2/cloud 可写） */
const PROBE_FILE_NAME: string = '.probe';

/**
 * 共享的 CloudFileCache 实例（since 11；多实例数据不共享，全局一个即可）。
 *
 * ⚠️ 必须是 `let` 且允许重建：真机实测（SGT-AL10 / API 26）重装后首次全量
 * 下载时，`start(uri)` 会成片抛 `13600001 IPC error` —— 那是应用与云文件服务
 * 之间的 IPC 连接断了（"Failed to load the service"），**实例本身也跟着废了**，
 * 继续用它只会让后面每一个文件都失败。重建实例 + 短暂等待能让后续文件恢复。
 */
let fileCache: cloudSync.CloudFileCache = new cloudSync.CloudFileCache();

/** 云端根路径（{cloudFileDir}/bilimusic）；空串 = 未 init */
let cloudRootPath: string = '';
/** 设备目录路径（{cloudRoot}/devices） */
let devicesRootPath: string = '';
/** el2/cloud 是否可写（探针结果；false = 系统同步开关未开启 / 云空间异常） */
let cloudDirAvailable: boolean = false;

function isInit(): boolean {
  return cloudRootPath.length > 0;
}

/** 设备目录绝对路径：{cloudRoot}/devices/{deviceId} */
export function deviceDirOf(deviceId: string): string {
  return `${devicesRootPath}/${deviceId}`;
}

/** 设备目录下的相对文件绝对路径（relPath 不以 / 开头，如 'meta.json'、'playlists/x.json'） */
export function deviceFileOf(deviceId: string, relPath: string): string {
  return `${deviceDirOf(deviceId)}/${relPath}`;
}

/**
 * 路径在本机是否有**实体**。
 *
 * ⚠️ `accessSync` 的返回值**不是存在性判断**（d.ts 原文：true = 本地文件且有权限；
 * false = 文件不存在**或者在云端**）。重装 / 换机后 el2/cloud 里的目录与文件
 * 全是「云端占位」，accessSync 一律返回 false —— 若把它当存在性判断：
 *   ① 读端会把每一份云端数据当成「不存在」直接跳过（重装后一份都读不回来）；
 *   ② 建目录端会对已存在的云端目录再 mkdir 一次（EEXIST）。
 * 因此本函数只用于「要不要走直读快路径」这类本地性判断。
 */
function isLocalEntry(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (e) {
    return false;
  }
}

/**
 * 递归建目录（已存在不抛）。
 *
 * 13900015（File exists）必须吞掉：目录在云端已存在、本机还没落地时
 * accessSync 返回 false，于是会走 mkdir，而目录其实存在 —— 递归建目录
 * 对已存在目录的返回值不可靠，只能按「已存在即成功」处理。
 */
function ensureDir(path: string): void {
  if (isLocalEntry(path)) {
    return;
  }
  try {
    fs.mkdirSync(path, true);
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    if (err.code === 13900015) {
      return;
    }
    throw err;
  }
}

/** 建某文件的父目录（relPath 可能带子目录，如 'playlists/x.json'） */
function ensureParentDirOf(absPath: string): void {
  const slash: number = absPath.lastIndexOf('/');
  if (slash <= 0) {
    return;
  }
  ensureDir(absPath.substring(0, slash));
}

/**
 * 真写一次探针验证 el2/cloud 可写。
 *
 * 为什么不能只看 `cloudFileDir` 非空：`cloudFileSyncEnabled` 关闭时该字段可能
 * 仍返回路径字符串；只有写入才能分辨「开关已开」与「开关没开」。
 * 13900002 再试一次：目录可能刚被系统同步轮清扫 / 还是云端占位，重建后即可写。
 */
function writeProbe(): void {
  ensureDir(cloudRootPath);
  ensureDir(devicesRootPath);
  const probePath: string = `${cloudRootPath}/${PROBE_FILE_NAME}`;
  const attempt = (): void => {
    const file: fs.File = fs.openSync(probePath,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, `${Date.now()}`);
    } finally {
      fs.closeSync(file);
    }
    try {
      fs.unlinkSync(probePath);
    } catch (e) {
      // 探针删不掉不算失败（下次 TRUNC 覆盖），别因此判「不可用」
    }
  };
  try {
    attempt();
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    if (err.code !== 13900002) {
      throw err;
    }
    ensureDir(cloudRootPath);
    attempt();
  }
}

/**
 * 初始化（AppContainer.initRest 调用，幂等）：
 * 建根 / 设备目录 + 写探针验证 el2/cloud 可写。
 *
 * 结果进 cloudDirAvailable，页面据此切换「已连接 / 未开启系统开关」两态
 * （方案 §2 三条产品口径的前提）。
 */
export function initCloudDirClient(context: common.Context): void {
  if (isInit()) {
    return;
  }
  const cloudFileDir: string = context.cloudFileDir ?? '';
  if (cloudFileDir.length === 0) {
    console.warn('[CloudDir] cloudFileDir empty, cloud sync disabled');
    return;
  }
  cloudRootPath = `${cloudFileDir}/${CLOUD_ROOT_DIR_NAME}`;
  devicesRootPath = `${cloudRootPath}/${CLOUD_DEVICES_DIR_NAME}`;
  try {
    writeProbe();
    cloudDirAvailable = true;
    console.info('[CloudDir] cloud dir ready');
  } catch (e) {
    cloudDirAvailable = false;
    console.warn(`[CloudDir] cloud dir not writable (system switch off?): ${
      e instanceof Error ? e.message : JSON.stringify(e)}`);
  }
}

/** el2/cloud 是否可写（探针结果；未 init 一律 false） */
export function isCloudDirAvailable(): boolean {
  return isInit() && cloudDirAvailable;
}

/** 重新探针（引导页「我已开启，重新检测」用）：清除标记后重跑探针 */
export function reprobeCloudDir(): boolean {
  if (!isInit()) {
    return false;
  }
  cloudDirAvailable = false;
  try {
    writeProbe();
    cloudDirAvailable = true;
  } catch (e) {
    console.warn(`[CloudDir] reprobe failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
  }
  return cloudDirAvailable;
}

/** deviceId 合法性（UUID / 自造 id 只含安全字符，拦住目录穿越类脏数据） */
function isValidDeviceId(deviceId: string): boolean {
  if (deviceId.length < 8 || deviceId.length > 64) {
    return false;
  }
  for (let i = 0; i < deviceId.length; i++) {
    const c: string = deviceId.charAt(i);
    const ok: boolean = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9') || c === '-' || c === '_';
    if (!ok) {
      return false;
    }
  }
  return true;
}

/**
 * 建好某设备的目录骨架（只对自己设备用；别的设备目录由它自己建）。
 * 返回 ownDir 绝对路径，失败抛出（调用方记异常态）。
 */
export function ensureDeviceDirs(deviceId: string): string {
  if (!isInit()) {
    throw new Error('CloudDirClient not initialized');
  }
  if (!isValidDeviceId(deviceId)) {
    throw new Error(`invalid device id: ${deviceId}`);
  }
  const ownDir: string = deviceDirOf(deviceId);
  ensureDir(ownDir);
  ensureDir(`${ownDir}/playlists`);
  ensureDir(`${ownDir}/sessions`);
  return ownDir;
}

/**
 * 覆盖写文本（fs 无 writeTextFile，统一 open→write→close）。
 *
 * ⚠️ **必须用同步 API**。真机实测（SGT-AL10 / API 26，重装后）对 `el2/cloud`
 * 下的路径调用**异步** `fs.open` 会直接失败：`file_api: Failed to open file for
 * libuv error -2`（ENOENT），而同一路径用 `fs.openSync` 写得好好的 ——
 * 分层探针四层全是 `exists=true write=ok`。异步 file_api 走 libuv 线程池，
 * 云端目录的占位实体化不是在那条链上做的，所以异步 open 看不到实体。
 *
 * 症状极具误导性：`mkdirSync` 认为目录存在、`openSync` 能写，只有异步 open 报
 * 「文件不存在」，于是写入轮直接抛异常、整轮悬挂（`running` 永远 true，后续
 * 所有同步请求被吞），页面表现为「一直显示待上传但数字不动」。
 * 云端目录的对象都是几 KB~110KB 的文本，同步写没有性能顾虑。
 */
function writeTextAt(path: string, content: string): void {
  const file: fs.File = fs.openSync(path,
    fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, content);
  } finally {
    fs.closeSync(file);
  }
}

/**
 * 写自己设备目录下的文本文件（覆盖写，TRUNC 幂等）。
 * 写入完成即视为「已交给系统」—— 何时上云归系统调度（方案 §4.1）。
 *
 * ⚠️ 每次写前都补建父目录，不能假设「一轮开始时建过就一直在」：
 * 系统端云同步轮会清扫本机空的云目录（重装后实测 devices/ 直接被删），
 * 而本轮中途还会主动触发一次系统同步（pullBeforeRead）—— 目录在一次
 * 同步轮之后消失，随后 open 就是 13900002「No such file or directory」。
 */
/**
 * 分层写探测（诊断用）：对 cloud 根 / devices / 设备目录 / playlists 四层
 * 各写一个临时文件，报告「是否存在 + 能否写入」。
 *
 * 重装后实测 `fs.open` 报 ENOENT（libuv -2）而 `mkdirSync` 认为目录已存在，
 * 这是「目录只存在于云端、本机没有实体 inode」的典型症状。靠这行日志能一眼
 * 看出是哪一层卡住，而不是靠猜。
 */
export function diagnoseWriteLayers(deviceId: string): string {
  if (!isInit()) {
    return 'not-init';
  }
  const devDir: string = deviceDirOf(deviceId);
  const layers: string[] = [cloudRootPath, devicesRootPath, devDir, `${devDir}/playlists`];
  const labels: string[] = ['/', '/devices', '/devices/<id>', '/devices/<id>/playlists'];
  const out: string[] = [];
  for (let i = 0; i < layers.length; i++) {
    const dir: string = layers[i];
    let exists: boolean = false;
    try {
      exists = fs.accessSync(dir);
    } catch (e) {
      exists = false;
    }
    const probe: string = `${dir}/.wprobe`;
    let write: string = 'ok';
    try {
      const f: fs.File = fs.openSync(probe,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, 'x');
      } finally {
        fs.closeSync(f);
      }
      try {
        fs.unlinkSync(probe);
      } catch (e) {
        // 删除失败不影响判据
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      write = `${err.code}`;
    }
    out.push(`${labels[i]} exists=${exists} write=${write}`);
  }
  return out.join(' | ');
}

export async function writeOwnFile(deviceId: string, relPath: string, content: string): Promise<void> {
  const dir: string = deviceDirOf(deviceId);
  const path: string = deviceFileOf(deviceId, relPath);
  ensureDir(dir);
  ensureParentDirOf(path);
  try {
    writeTextAt(path, content);
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    if (err.code !== 13900002) {
      throw new Error(`写入云端文件失败（${relPath}）：${err.message}`);
    }
    // 目录在两次 fs 调用之间被回收 / 当前只是云端占位：重建骨架后再试一次
    ensureDir(dir);
    ensureDir(`${dir}/playlists`);
    ensureDir(`${dir}/sessions`);
    ensureParentDirOf(path);
    try {
      writeTextAt(path, content);
    } catch (e2) {
      const err2: BusinessError = e2 as BusinessError;
      // 第三种可能：**本地是「孤儿占位」** —— 云端早已没有这个文件的记录
      // （系统侧 `GetDownloadAsset: get cloud id failed, errno 2` /
      // `truncate failed, err: 2`），于是既下载不了也覆盖不了。
      // 删掉本地占位再重建，等于让这个路径变成一个全新文件。
      try {
        fs.unlinkSync(path);
      } catch (e3) {
        // 删不掉就认命：交给调用方跳过（写轮不能因为一个文件整轮失败）
      }
      try {
        writeTextAt(path, content);
        return;
      } catch (e3) {
        const err3: BusinessError = e3 as BusinessError;
        console.warn(`[CloudDir] write layers << ${diagnoseWriteLayers(deviceId)}`);
        throw new Error(`写入云端文件失败（${relPath}，删占位重建仍失败）：${err3.message}`);
      }
    }
  }
}

/**
 * 删掉自己目录下的一个文件（歌单被删时清云端快照 —— 删除传播的正主）。
 *
 * 为什么用「删文件」而不是「墓碑表」表达删除：墓碑能不能成立取决于读取端
 * 有没有正确读懂它，而读取端无法区分「云端没有」与「这次没读到」（占位 /
 * 冷却 / hash 差量跳过），判错的代价是删掉用户还在的歌单。文件消失是唯一
 * 没有歧义的信号：下一轮列举/下载时它就是不在了。
 *
 * 返回是否真的删掉；失败静默（占位 / 云端已无该文件都属于「已经是目标状态」）。
 */
export function deleteDeviceFile(deviceId: string, relPath: string): boolean {
  if (!isInit() || !isValidDeviceId(deviceId)) {
    return false;
  }
  const path: string = deviceFileOf(deviceId, relPath);
  try {
    fs.unlinkSync(path);
    return true;
  } catch (e) {
    return false;
  }
}

/**
 * 列出云端设备目录下的全部 deviceId（别的设备写的目录会以占位形式出现，
 * 系统同步到后 listFileSync 自然可见 —— 方案 §5.2 第 ① 步）。
 * 云端目录不可用 / 不存在时返回空数组。
 */
export function listCloudDeviceIds(): string[] {
  if (!isInit() || !cloudDirAvailable) {
    return [];
  }
  try {
    // 自愈：系统同步轮可能清扫掉空的本地目录（重装后实测 devices 目录被删，
    // listFileSync 直接 ENOENT），列举前补建一次，别把「目录没了」当「没设备」。
    ensureDir(devicesRootPath);
  } catch (e) {
    // 建不出来就交给下面的 listFileSync 兜底
  }
  try {
    const entries: string[] = fs.listFileSync(devicesRootPath);
    const ids: string[] = [];
    for (let i = 0; i < entries.length; i++) {
      const entry: string = entries[i];
      const slash: number = Math.max(entry.lastIndexOf('/'), entry.lastIndexOf('\\'));
      const name: string = slash >= 0 ? entry.substring(slash + 1) : entry;
      if (isValidDeviceId(name)) {
        ids.push(name);
      }
    }
    return ids;
  } catch (e) {
    console.warn(`[CloudDir] list devices failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    return [];
  }
}

/**
 * 设备目录分类结果（页面「N 台设备」的口径来源）。
 */
export interface DeviceDirStats {
  /** 现代身份目录：本机 ODID 目录 + 其他设备（ODID 时代）目录 */
  active: string[];
  /** 旧版本用随机 UUID 留下的一次性目录（同一台手机反复重装会攒一堆） */
  legacy: string[];
}

/**
 * 判断一个目录名是否是「旧版本随机 UUID 目录」。
 *
 * 判据是 **UUID 版本位**（第 15 个字符，index 14）：
 *   · `util.generateRandomUUID(true)` 生成的是 **v4**（该位恒为 '4'）
 *   · 系统 ODID 是 **v6/v7**（该位是 '6' 或 '7'，真机实测 `94e8e193-1557-6eb0-…`）
 * 两者不会混淆，所以不必依赖任何本地状态 —— 这一点很关键：**重装后本地
 * state 全丢**，靠 state 记录 legacyDeviceIds 根本救不了「已存在的旧目录」。
 *
 * 本机自己的目录永远算 active（万一某台设备的 ODID 恰好是 v4 格式，
 * 也只影响「本机被误标成旧目录」，不会影响其他判定）。
 */
function isLegacyRandomUuidDir(name: string, ownDeviceId: string): boolean {
  if (name === ownDeviceId) {
    return false;
  }
  return name.length === 36 && name.charAt(14) === '4';
}

/**
 * 把云端设备目录分成「在同步的设备」与「旧版本遗留目录」。
 *
 * 为什么必须分开：真机实测一台手机反复装 5 次，云端留下 4 个 v4 目录，
 * 页面「5 台设备在同步」直接把用户吓到（他只有一台手机）。旧目录里的数据
 * **仍然要读**（可能存着他想恢复的老歌单），但绝不能算进设备数。
 */
export function classifyDeviceDirs(ownDeviceId: string): DeviceDirStats {
  const all: string[] = listCloudDeviceIds();
  const active: string[] = [];
  const legacy: string[] = [];
  for (let i = 0; i < all.length; i++) {
    const id: string = all[i];
    if (isLegacyRandomUuidDir(id, ownDeviceId)) {
      legacy.push(id);
    } else {
      active.push(id);
    }
  }
  return { active: active, legacy: legacy };
}

/**
 * 列某设备目录下子目录里的文件名（不含路径，如 'YYYY-MM.jsonl'）。
 * 目录不存在（该设备没写过这类数据）返回空数组。
 */
export function listDeviceFileNames(deviceId: string, relDir: string): string[] {
  if (!isInit() || !isValidDeviceId(deviceId)) {
    return [];
  }
  const dir: string = relDir.length > 0 ? `${deviceDirOf(deviceId)}/${relDir}` : deviceDirOf(deviceId);
  try {
    const entries: string[] = fs.listFileSync(dir);
    const names: string[] = [];
    for (let i = 0; i < entries.length; i++) {
      const entry: string = entries[i];
      const slash: number = Math.max(entry.lastIndexOf('/'), entry.lastIndexOf('\\'));
      names.push(slash >= 0 ? entry.substring(slash + 1) : entry);
    }
    return names;
  } catch (e) {
    return [];
  }
}

/** 单文件缓存下载是否仍在串行链上（链尾吞错保 settled） */
let downloadChain: Promise<void> = Promise.resolve();

/**
 * 串行缓存下载队列（并发 = CLOUD_CACHE_CONCURRENCY = 1）。
 * 并发上限是官方红线（22400004 + 整机异常），队列化而非分批：
 * 本项目对象数本来就少（几台设备 × 十几个文件），串行足够且最安全。
 */
function enqueueDownload<T>(task: () => Promise<T>): Promise<T> {
  const run: Promise<T> = downloadChain.then(task);
  downloadChain = run.then((): void => {
  }, (): void => {
  });
  return run;
}

/** 简易延时（等系统把云端占位文件拉成实体） */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

/**
 * 拉一个云端文件在本机的实体副本，并读回文本（方案 §4.2）。
 * 返回 null = 该文件在云端不存在（13900002）/ 超时未就绪；抛出 = 本轮拿不到。
 *
 * ⚠️⚠️ 为什么是「start 后轮询 readText」而不是「等 progress 的 COMPLETED」：
 *
 * 旧实现只挂 `on('progress')` 等 COMPLETED，一旦事件没来（uri 归一化差异 /
 * 文件本机已有实体 / 系统认为无需下载），就要**白等满 30s 才超时返回 null**。
 * 一台设备光是 meta + tombstones + index 三个文件就吃掉 90s，而一轮预算只有
 * 60s —— 索引永远读不到，界面上就是「云端数据一份都读不下来」，且日志里全是
 * 每条 30s 的超时。轮询的判据是「文件能不能读出非空内容」，与事件是否派发
 * 无关，因此对「已缓存 / 正在下载 / 刚下完」三种状态都成立。
 *
 * progress 只保留一个作用：本轮下载**明确失败**（FAILED / STOPPED）时提前
 * 结束，不必空转到超时。
 */
/**
 * 触发一次缓存下载，**IPC 层失败时重建实例重试一次**。
 *
 * @returns true = 已开始下载；false = 云端确实没有这个文件（13900002，不是异常）
 */
async function startCacheDownload(uri: string,
  onProgress: (p: cloudSync.DownloadProgress) => void): Promise<boolean> {
  try {
    await fileCache.start(uri);
    return true;
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    if (err.code === 13900002) {
      return false;
    }
    if (err.code !== 13600001) {
      throw new Error(`cloud download start failed: ${err.code} ${err.message}`);
    }
    // IPC 连接已坏（"Failed to load the service"）：旧实例的代理失效，
    // 换新实例 + 短暂等待再试。真机上这一条能把「成片失败」救回来。
    console.info('[CloudDir] cloud ipc error, recreate file cache and retry');
    try {
      fileCache.off('progress', onProgress);
    } catch (e2) {
      // 旧实例已释放：忽略
    }
    fileCache = new cloudSync.CloudFileCache();
    try {
      fileCache.on('progress', onProgress);
    } catch (e2) {
      // 订阅失败不阻断：还有轮询兜底
    }
    await delay(400);
    try {
      await fileCache.start(uri);
      return true;
    } catch (e2) {
      const err2: BusinessError = e2 as BusinessError;
      if (err2.code === 13900002) {
        return false;
      }
      throw new Error(`cloud download start failed: ${err2.code} ${err2.message}`);
    }
  }
}

async function downloadAndWait(absPath: string, timeoutMs: number): Promise<string | null> {
  const uri: string = fileUri.getUriFromPath(absPath);
  let failText: string = '';
  const onProgress = (p: cloudSync.DownloadProgress): void => {
    if (p.uri !== uri) {
      return;
    }
    if (p.state === cloudSync.State.FAILED) {
      failText = `cloud download failed, err=${p.error}`;
    } else if (p.state === cloudSync.State.STOPPED) {
      failText = 'cloud download stopped';
    }
  };
  let listening: boolean = false;
  try {
    fileCache.on('progress', onProgress);
    listening = true;
  } catch (e) {
    // 订阅失败不阻断：下面有轮询兜底
  }
  try {
    const exists: boolean = await startCacheDownload(uri, onProgress);
    if (!exists) {
      return null;
    }
    const deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (failText.length > 0) {
        throw new Error(failText);
      }
      try {
        // 同步读：与 writeTextAt 同理，云端目录上异步 file_api 走不到实体
        const text: string = fs.readTextSync(absPath);
        if (text.length > 0) {
          return text;
        }
      } catch (e) {
        // 仍是云端占位（不可直读）：继续等
      }
      await delay(CLOUD_DOWNLOAD_POLL_MS);
    }
    return null;
  } finally {
    if (listening) {
      try {
        fileCache.off('progress', onProgress);
      } catch (e) {
        // 实例已释放：忽略
      }
    }
  }
}

/** 串行缓存下载的薄封装（并发红线见 enqueueDownload） */
async function cacheAndReadText(absPath: string, timeoutMs: number): Promise<string | null> {
  return enqueueDownload<string | null>((): Promise<string | null> => {
    return downloadAndWait(absPath, timeoutMs);
  });
}

/**
 * 读某设备目录下的文本文件（缓存前置统一封装）：
 *   · 本地已有实体 → 直读快路径（自己刚写的 / 上轮已下载的，零成本）；
 *   · 本地无实体（云端占位，`accessSync` 返回 false）→ 直接走
 *     CloudFileCache 串行下载，COMPLETED 后再读 —— **绝不能因为
 *     accessSync=false 就当成「文件不存在」直接返回 null**，那会让重装 /
 *     换机后一份云端数据都读不回来。
 * 文件不存在（该设备没写过）返回 null；单文件失败也返回 null（下一轮重试），
 * 绝不把单个文件的问题放大成整轮失败。
 */
/**
 * 读失败冷却表（absPath → 允许重试的时刻）。
 *
 * 真机上「旧版目录残留的孤儿占位」会让同一个 `recent.json` **每一轮**都走一遍
 * `start → 13600001 IPC error → 重建实例 → delay(400) → 再失败`：5 个目录累计
 * 每次同步多花 1.5~2s，期间整条云 IPC 通道被打满，界面明显卡顿，而结果永远是
 * 同一个 null。失败一次就冷却，下一轮直接跳过 —— 文件真出现了会在下一轮
 * `meta` / 索引 hash 变化时被重新发现（冷却只作用于「读不出内容」这一种情况）。
 */
const readFailCooldown: Map<string, number> = new Map<string, number>();
/** 读失败冷却时长：5 分钟（既要止住每轮重试，又不能长时间漏掉真数据） */
const READ_FAIL_COOLDOWN_MS: number = 5 * 60 * 1000;

export async function readDeviceFile(deviceId: string, relPath: string,
  timeoutMs: number = CLOUD_FILE_DOWNLOAD_TIMEOUT_MS): Promise<string | null> {
  if (!isInit() || !isValidDeviceId(deviceId)) {
    return null;
  }
  const path: string = deviceFileOf(deviceId, relPath);
  if (isLocalEntry(path)) {
    try {
      const direct: string = fs.readTextSync(path);
      if (direct.length > 0) {
        readFailCooldown.delete(path);
        return direct;
      }
    } catch (e) {
      // 占位文件直读抛错：落到缓存下载路径
    }
  }
  const until: number | undefined = readFailCooldown.get(path);
  if (until !== undefined && Date.now() < until) {
    // 冷却中：不打印日志（每轮都打会把排查日志淹掉）
    return null;
  }
  try {
    const text: string | null = await cacheAndReadText(path, timeoutMs);
    if (text !== null) {
      readFailCooldown.delete(path);
    } else {
      readFailCooldown.set(path, Date.now() + READ_FAIL_COOLDOWN_MS);
    }
    return text;
  } catch (e) {
    readFailCooldown.set(path, Date.now() + READ_FAIL_COOLDOWN_MS);
    console.warn(`[CloudDir] read ${deviceId}/${relPath} failed: ${
      e instanceof Error ? e.message : JSON.stringify(e)}`);
    return null;
  }
}

/**
 * 自己设备文件的直读（meta / index 等自产文件，本机必有真实内容）。
 * 与 readDeviceFile 的区别：不走缓存下载兜底 —— 自产文件不存在就是没有，
 * 下载兜底只会掩盖写入失败。
 */
export async function readOwnFileDirect(deviceId: string, relPath: string): Promise<string | null> {
  const path: string = deviceFileOf(deviceId, relPath);
  // 本机无实体（重装后仍是云端占位）就当没有：自产文件走缓存下载的话，
  // 只会把「写入失败」伪装成「读到了旧内容」，掩盖真正的问题。
  if (!isLocalEntry(path)) {
    return null;
  }
  try {
    return fs.readTextSync(path);
  } catch (e) {
    console.warn(`[CloudDir] read own file failed: ${relPath}`);
    return null;
  }
}

/**
 * 自己设备目录的上传状态分档（状态卡三个数字的唯一来源）。
 *
 * 为什么不是一个「pending 数」：`UPLOAD_FAILURE` / `STOPPED` 与 `TO_BE_UPLOADED`
 * 对用户的意义完全不同 —— 前者要处理（重试 / 恢复条件），后者只能等系统排到。
 * 混成一个数时，**真上传失败时数字永远不降、文案永远不变**，界面上和「正在
 * 排队」长得一模一样，用户与排查者都无法区分。
 */
export interface UploadStats {
  /** 排队中 / 正在上传（TO_BE_UPLOADED / UPLOADING）：系统会自己传，只能等 */
  pending: number;
  /** 上传失败（UPLOAD_FAILURE）：需要「重试上传」 */
  failed: number;
  /** 系统已暂停（STOPPED：断网 / 低电 / 温控）：条件恢复后自动继续 */
  stalled: number;
  /** 真正查过状态的文件数（0 = 目录里还没有文件） */
  probed: number;
  /** 设备是否支持 getCoreFileSyncState（false = 页面隐藏整行） */
  supported: boolean;
}

/**
 * 逐文件查上传状态（cloudSync.getCoreFileSyncState，since 20）。
 * 13900031（未实现）/ 任何非预期异常 → supported = false，页面降级为不显示，
 * **不要返回半真半假的数字**（会出现「一半文件有一半没有」的怪数）。
 */
export function getUploadStats(deviceId: string): UploadStats {
  const stats: UploadStats = {
    pending: 0, failed: 0, stalled: 0, probed: 0, supported: true
  };
  if (!isInit() || !isValidDeviceId(deviceId)) {
    stats.supported = false;
    return stats;
  }
  let bail: boolean = false;
  const probe = (dir: string): void => {
    if (bail) {
      return;
    }
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (e) {
      return;
    }
    for (let i = 0; i < names.length; i++) {
      if (bail) {
        return;
      }
      const entry: string = names[i];
      const slash: number = Math.max(entry.lastIndexOf('/'), entry.lastIndexOf('\\'));
      const name: string = slash >= 0 ? entry.substring(slash + 1) : entry;
      if (name === PROBE_FILE_NAME) {
        continue;
      }
      const abs: string = `${dir}/${name}`;
      let isDir: boolean = false;
      try {
        isDir = fs.statSync(abs).isDirectory();
      } catch (e) {
        continue;
      }
      if (isDir) {
        probe(abs);
        continue;
      }
      try {
        const state: cloudSync.FileState = cloudSync.getCoreFileSyncState(fileUri.getUriFromPath(abs));
        stats.probed++;
        if (state === cloudSync.FileState.UPLOADING || state === cloudSync.FileState.TO_BE_UPLOADED) {
          stats.pending++;
        } else if (state === cloudSync.FileState.UPLOAD_FAILURE) {
          stats.failed++;
        } else if (state === cloudSync.FileState.STOPPED) {
          stats.stalled++;
        }
        // INITIAL_AFTER_DOWNLOAD / UPLOAD_SUCCESS：已上云，不计数
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        if (err.code === 13900031) {
          bail = true;
          stats.supported = false;
          return;
        }
        // 其它错误（单文件被删 / 正在重命名）：跳过该文件，别污染整体判断
      }
    }
  };
  probe(deviceDirOf(deviceId));
  return stats;
}

/**
 * `getUploadStats` 的异步版（页面渲染路径专用）。
 *
 * 同步版在目录里每个文件上一次 `statSync` + 一次 `getCoreFileSyncState`（跨进程
 * IPC），几十个文件叠起来是**一整段**主线程阻塞 —— 状态卡刷新时界面直接卡住，
 * 用户能明显感觉到「同步过程中卡顿」。这里把枚举与 stat 换成 Promise 版，
 * 每次 await 都把主线程还回去；`getCoreFileSyncState` 没有异步 API，但被切碎后
 * 单次阻塞只有几毫秒。
 */
export async function getUploadStatsAsync(deviceId: string): Promise<UploadStats> {
  const stats: UploadStats = {
    pending: 0, failed: 0, stalled: 0, probed: 0, supported: true
  };
  if (!isInit() || !isValidDeviceId(deviceId)) {
    stats.supported = false;
    return stats;
  }
  let bail: boolean = false;
  const probe = async (dir: string): Promise<void> => {
    if (bail) {
      return;
    }
    let names: string[] = [];
    try {
      names = await fs.listFile(dir);
    } catch (e) {
      return;
    }
    for (let i = 0; i < names.length; i++) {
      if (bail) {
        return;
      }
      const entry: string = names[i];
      const slash: number = Math.max(entry.lastIndexOf('/'), entry.lastIndexOf('\\'));
      const name: string = slash >= 0 ? entry.substring(slash + 1) : entry;
      if (name === PROBE_FILE_NAME) {
        continue;
      }
      const abs: string = `${dir}/${name}`;
      let isDir: boolean = false;
      try {
        isDir = (await fs.stat(abs)).isDirectory();
      } catch (e) {
        continue;
      }
      if (isDir) {
        await probe(abs);
        continue;
      }
      try {
        const state: cloudSync.FileState = cloudSync.getCoreFileSyncState(fileUri.getUriFromPath(abs));
        stats.probed++;
        if (state === cloudSync.FileState.UPLOADING || state === cloudSync.FileState.TO_BE_UPLOADED) {
          stats.pending++;
        } else if (state === cloudSync.FileState.UPLOAD_FAILURE) {
          stats.failed++;
        } else if (state === cloudSync.FileState.STOPPED) {
          stats.stalled++;
        }
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        if (err.code === 13900031) {
          bail = true;
          stats.supported = false;
          return;
        }
      }
    }
  };
  await probe(deviceDirOf(deviceId));
  return stats;
}

/** 主动上传的结果（不抛异常，页面直接按 outcome 给提示） */
export enum UploadTriggerOutcome {
  /** 系统报告本轮同步已完成 */
  COMPLETED = 0,
  /** 已提交，超时前系统没报完成 —— 仍在后台上传，属正常 */
  PENDING = 1,
  /** 触发失败（无网络 / 低电 / 云空间未就绪 / IPC 异常） */
  FAILED = 2,
  /** 云目录未就绪（系统同步开关没开） */
  UNAVAILABLE = 3
}

export interface UploadTriggerResult {
  outcome: UploadTriggerOutcome;
  /** 可直接 toast 的文案（三种 outcome 都带） */
  message: string;
}

/**
 * 触发上传专用实例：官方明确要求「添加监听的对象和触发同步的对象保持一致」，
 * 因此**不能复用** `fileCache`（那是下载用的 CloudFileCache，混用会收到对方
 * 的进度事件，还会把下载状态误判成上传状态）。
 */
let uploadSync: cloudSync.FileSync | null = null;
/** 单飞：并发触发只会互相打断 IPC，并让页面弹两条 toast */
let uploadInFlight: Promise<UploadTriggerResult> | null = null;

/** SyncProgress.error → 人话（官方定义见 ErrorType，低电/温控/空间是主要三类） */
function progressErrorText(err: cloudSync.ErrorType): string {
  if (err === cloudSync.ErrorType.NETWORK_UNAVAILABLE) {
    return '没有可用网络';
  }
  if (err === cloudSync.ErrorType.WIFI_UNAVAILABLE) {
    return 'WiFi 不可用';
  }
  if (err === cloudSync.ErrorType.BATTERY_LEVEL_LOW || err === cloudSync.ErrorType.BATTERY_LEVEL_WARNING) {
    return '电量过低';
  }
  if (err === cloudSync.ErrorType.CLOUD_STORAGE_FULL) {
    return '云空间已满';
  }
  if (err === cloudSync.ErrorType.LOCAL_STORAGE_FULL) {
    return '本机存储空间不足';
  }
  if (err === cloudSync.ErrorType.DEVICE_TEMPERATURE_TOO_HIGH) {
    return '设备温度过高';
  }
  if (err === cloudSync.ErrorType.REMOTE_SERVER_ABNORMAL) {
    return '云端服务异常';
  }
  return '未知原因';
}

/** start() 抛出的 BusinessError → 人话（三个 2240000x 是官方定义的失败入口） */
function triggerErrorText(e: BusinessError): string {
  if (e.code === 22400001) {
    return '云空间未就绪，请确认已登录华为账号、并在设置里打开本应用同步开关';
  }
  if (e.code === 22400002) {
    return '网络不可用，连上 WiFi 后重试';
  }
  if (e.code === 22400003) {
    return '电量低于 10%，系统暂不允许上传';
  }
  if (e.code === 13600001) {
    return '云空间服务无响应，稍后再试';
  }
  return `触发上传失败（${e.code}）`;
}

function runUploadTrigger(timeoutMs: number): Promise<UploadTriggerResult> {
  if (uploadSync === null) {
    uploadSync = new cloudSync.FileSync();
  }
  const sync: cloudSync.FileSync = uploadSync;
  return new Promise<UploadTriggerResult>((resolve: (r: UploadTriggerResult) => void) => {
    let settled: boolean = false;
    let timer: number = -1;
    const finish = (r: UploadTriggerResult): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (timer >= 0) {
        clearTimeout(timer);
      }
      try {
        sync.off('progress', onProgress);
      } catch (e) {
        // 监听已随实例释放：忽略
      }
      resolve(r);
    };
    const onProgress = (p: cloudSync.SyncProgress): void => {
      if (settled) {
        return;
      }
      if (p.state === cloudSync.SyncState.COMPLETED) {
        finish({ outcome: UploadTriggerOutcome.COMPLETED, message: '已上传到云空间' });
      } else if (p.state === cloudSync.SyncState.UPLOAD_FAILED) {
        finish({
          outcome: UploadTriggerOutcome.FAILED,
          message: `上传失败：${progressErrorText(p.error)}`
        });
      } else if (p.state === cloudSync.SyncState.STOPPED) {
        finish({ outcome: UploadTriggerOutcome.FAILED, message: '系统暂停了本轮上传，稍后会自动继续' });
      }
      // DOWNLOADING / DOWNLOAD_FAILED：本轮同时可能在下别的设备的文件，与上传无关，继续等 COMPLETED
    };
    timer = setTimeout((): void => {
      finish({ outcome: UploadTriggerOutcome.PENDING, message: '已提交给系统，仍在后台上传' });
    }, timeoutMs);
    try {
      sync.on('progress', onProgress);
    } catch (e) {
      finish({ outcome: UploadTriggerOutcome.FAILED, message: '无法订阅云同步状态，稍后再试' });
      return;
    }
    // start() 的 resolve 只代表「同步已启动」，真正结果看 progress 回调
    sync.start().catch((e: BusinessError): void => {
      finish({ outcome: UploadTriggerOutcome.FAILED, message: triggerErrorText(e) });
    });
  });
}

/**
 * 主动触发一次上传（页面「立即上传 / 重试上传」）。
 *
 * 为什么必须有这个口子：系统正常情况下写完自动传，但**功耗管控**（无网 /
 * 低电 / 高温）会把上传无限期押后 —— 官方适配指南的原话是「此时开发者可以
 * 通过 cloudSync.FileSync 订阅同步状态，并根据状态完成对同步的管理」。
 * 没有它，App 对「N 个文件待上传」只能干等，用户也分不清是排队还是卡死。
 *
 * @param timeoutMs 等待系统报告完成的预算；超时不代表失败，返回 PENDING
 */
export function triggerUpload(timeoutMs: number = 20000): Promise<UploadTriggerResult> {
  if (!isInit() || !cloudDirAvailable) {
    return Promise.resolve({
      outcome: UploadTriggerOutcome.UNAVAILABLE,
      message: '云空间同步未开启，请先在设置 → 云空间里打开本应用的同步开关'
    });
  }
  if (uploadInFlight !== null) {
    return uploadInFlight;
  }
  const task: Promise<UploadTriggerResult> = runUploadTrigger(timeoutMs);
  uploadInFlight = task;
  const clear = (): void => {
    uploadInFlight = null;
  };
  task.then(clear, clear);
  return task;
}

/**
 * 端云同步主动触发（读前拉取）专用实例：与上传实例分开 —— 官方要求
 * 「添加监听的对象和触发同步的对象保持一致」，混用会串进度事件。
 */
let pullSync: cloudSync.FileSync | null = null;
/** 单飞：并发 start 只会互相打断 IPC，且官方明确「调用频率过高会导致整机异常」 */
let pullInFlight: Promise<boolean> | null = null;

/**
 * 主动触发一轮系统端云同步，并等它跑到 COMPLETED（或超时）。
 *
 * 为什么读之前必须先触发：重装 / 换机后本机 `el2/cloud` 是空的，云端旧设备
 * 目录只是云侧记录 —— 必须先由系统同步把**目录与文件元数据**下行到本机，
 * `fs.listFileSync` 才看得见（实测重装后不加这一步，系统自动同步漏掉，
 * 读轮永远扫到 0 台远端设备，云端数据一份都下发不下来）。
 *
 * @param timeoutMs 等待预算；超时不等于失败 —— 系统会继续在后台同步，下一轮再读
 * @returns true = 本轮同步已完成；false = 超时 / 暂停 / 触发失败（不抛异常）
 */
export function triggerSystemSync(timeoutMs: number = 10000): Promise<boolean> {
  if (!isInit() || !cloudDirAvailable) {
    return Promise.resolve(false);
  }
  if (pullInFlight !== null) {
    return pullInFlight;
  }
  if (pullSync === null) {
    pullSync = new cloudSync.FileSync();
  }
  const sync: cloudSync.FileSync = pullSync;
  const task: Promise<boolean> = new Promise<boolean>((resolve: (ok: boolean) => void) => {
    let settled: boolean = false;
    let timer: number = -1;
    const finish = (ok: boolean): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (timer >= 0) {
        clearTimeout(timer);
      }
      try {
        sync.off('progress', onProgress);
      } catch (e) {
        // 监听已随实例释放：忽略
      }
      resolve(ok);
    };
    const onProgress = (p: cloudSync.SyncProgress): void => {
      if (p.state === cloudSync.SyncState.COMPLETED) {
        finish(true);
      } else if (p.state === cloudSync.SyncState.UPLOAD_FAILED || p.state === cloudSync.SyncState.STOPPED) {
        finish(false);
      }
      // DOWNLOADING / DOWNLOAD_FAILED：本轮可能同时在下载，等 COMPLETED 再落定
    };
    timer = setTimeout((): void => {
      finish(false);
    }, timeoutMs);
    try {
      sync.on('progress', onProgress);
    } catch (e) {
      finish(false);
      return;
    }
    sync.start().catch((e: BusinessError): void => {
      console.warn(`[CloudDir] trigger sync failed: ${e.code} ${e.message}`);
      finish(false);
    });
  });
  pullInFlight = task;
  const clear = (): void => {
    pullInFlight = null;
  };
  task.then(clear, clear);
  return task;
}

/**
 * 自己设备目录的磁盘占用（字节，含已上传的本机副本）。
 * 页面「云空间 X MB」指标；失败返回 -1。
 */export function getOwnDirSizeBytes(deviceId: string): number {
  if (!isInit() || !isValidDeviceId(deviceId)) {
    return -1;
  }
  let total: number = 0;
  const walk = (dir: string): void => {
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (e) {
      return;
    }
    for (let i = 0; i < names.length; i++) {
      const entry: string = names[i];
      const slash: number = Math.max(entry.lastIndexOf('/'), entry.lastIndexOf('\\'));
      const name: string = slash >= 0 ? entry.substring(slash + 1) : entry;
      const abs: string = `${dir}/${name}`;
      try {
        const stat: fs.Stat = fs.statSync(abs);
        if (stat.isDirectory()) {
          walk(abs);
        } else {
          total += stat.size;
        }
      } catch (e) {
        // 单文件统计失败跳过
      }
    }
  };
  walk(deviceDirOf(deviceId));
  return total;
}

/* ------------------------------------------------------------------ *
 * 「重置云同步」的云端半边：把 devices/ 下每个设备目录整个删掉
 * ------------------------------------------------------------------ */

/** 云端清空结果（诊断用，不是上传统计） */
export interface CloudPurgeResult {
  /** 扫到的设备目录数 */
  dirs: number;
  /** 删掉的文件数（含本机副本与占位） */
  files: number;
  /** 删完仍残留的目录数（多为删不掉的云端占位） */
  leftovers: number;
  /** 目录列举失败 / 目录非空无法 rmdir 的次数 */
  stuck: number;
}

/**
 * 递归删除单个路径，返回删掉的文件数。
 *
 * 只用同步 API —— 与 writeTextAt 同一条纪律：异步 fs 走 libuv 线程池，
 * 而 `el2/cloud` 的占位实体化不在那条链上，异步调用会拿到 ENOENT。
 *
 * 任何一步失败都只返回 0 而不抛：删除是尽力而为，调用方靠「重置水位」
 * 兜底（见 purgeAllDeviceDirs 注释）。
 */
function removeTreeLocked(path: string): number {
  let isDir: boolean = false;
  try {
    isDir = fs.statSync(path).isDirectory();
  } catch (e) {
    // 不存在 / 占位不可 stat：视为已删
    return 0;
  }
  if (!isDir) {
    try {
      fs.unlinkSync(path);
      return 1;
    } catch (e) {
      return 0;
    }
  }
  let removed: number = 0;
  let names: string[] = [];
  try {
    names = fs.listFileSync(path);
  } catch (e) {
    names = [];
  }
  for (let i = 0; i < names.length; i++) {
    const entry: string = names[i];
    const slash: number = Math.max(entry.lastIndexOf('/'), entry.lastIndexOf('\\'));
    const name: string = slash >= 0 ? entry.substring(slash + 1) : entry;
    if (name.length === 0) {
      continue;
    }
    removed += removeTreeLocked(`${path}/${name}`);
  }
  try {
    fs.rmdirSync(path);
  } catch (e) {
    // 非空（列举漏了文件）或云端占位不让删：留下面，由调用方记 stuck
  }
  return removed;
}

/**
 * 清空本应用在云端的**全部**设备目录（含本机自己的）。
 *
 * 为什么连自己的一起删：用户要的是「从零开始」。只删别人的话，本机目录里
 * 残留的旧索引 / 旧墓碑会被下一轮继续读回来传播。
 *
 * ⚠️ 「本地删了」是否等于「云端删了」取决于系统端云同步会不会把本地删除
 * 上行 —— 这条没法在应用侧保证。所以本函数**不抛异常、不承诺结果**，
 * 调用方（CloudSyncManager.resetCloudSync）必须同时把读轮水位 resetAt
 * 抬到当前时刻：删不掉时旧目录即使被系统拉回来也不会再被当成数据源。
 */
export function purgeAllDeviceDirs(): CloudPurgeResult {
  const result: CloudPurgeResult = { dirs: 0, files: 0, leftovers: 0, stuck: 0 };
  if (!isInit() || !cloudDirAvailable) {
    return result;
  }
  const ids: string[] = listCloudDeviceIds();
  result.dirs = ids.length;
  for (let i = 0; i < ids.length; i++) {
    const dir: string = deviceDirOf(ids[i]);
    // 两遍：云端占位目录第一遍常列不全（实测同一目录这轮列得出、下轮返回空），
    // 第二遍往往能把第一遍漏下的空壳补掉。
    for (let pass = 0; pass < 2; pass++) {
      result.files += removeTreeLocked(dir);
      if (!isLocalEntry(dir)) {
        break;
      }
      result.stuck++;
    }
    if (isLocalEntry(dir)) {
      result.leftovers++;
    }
  }
  console.info(`[CloudDir] purge: dirs=${result.dirs} files=${result.files} `
    + `leftovers=${result.leftovers} stuck=${result.stuck}`);
  return result;
}
