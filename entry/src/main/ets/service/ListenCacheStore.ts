/**
 * 听后音频缓存。
 *
 * 设计：曲目**自然听完**（播放器 completed 状态）才把整首音频缓存下来 ——
 * 「听完」本身证明了这首歌值得缓存；切歌 / 快进跳过的一律不缓存，不浪费流量与空间。
 *
 * 结构：`{filesDir}/listen_cache/{safeName(trackId)}.{m4a|flac|mp3}`，一首一个文件。
 *   · 与下载管理（`filesDir/downloads` + RDB 任务表）**完全独立**：
 *     不落库、不进下载列表、不受「全部暂停」影响 —— 它是播放行为的副产品，
 *     用户可见面只有播放设置页的开关与「清理听后缓存」。
 *   · 容量 512MB LRU：超限按 mtime（= 最近使用时间，命中播放会 utimes 刷新）
 *     淘汰最旧的，一轮淘汰到 90% 水位线（滞回带，避免每写一首就删一首）。
 *   · 下载串行：听歌场景下一首接一首 completed，队列天然平滑；并发只会把
 *     带宽切碎并挤占正在播的音频首包。
 *   · 直链优先用**刚播的那条**（播放内核传入，免一次 playurl 解析）；
 *     CDN 签名过期 / 下载失败时兜底 `extractAudioFromVideo` 重解析一次再试。
 *   · 流量门控跟随「仅 WiFi 下载」（wifiOnlyDownload）：开着且当前是蜂窝时
 *     出队即放弃（不打扰用户，下次听完自然会再触发）。
 *   · 魔数校验照抄 DownloadManager（B 站 CDN 直链过期会回 HTTP 200 + HTML 错误页，
 *     不校验就会把错误页当缓存存进去，表现为「重播没声音」）。
 *
 * 一切失败静默（只记日志）：缓存是锦上添花，任何异常都不允许影响播放。
 */

import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import common from '@ohos.app.ability.common';
import { extractAudioFromVideo } from '../api/BilibiliApi';
import { AppPreferences } from '../preferences/AppPreferences';
import { isUnmeteredNetwork, hasNetwork } from '../utils/NetworkUtil';
import { HttpUtil } from '../utils/HttpUtil';
import { audioFileExt } from '../utils/TextUtil';
import { BILI_REFERER } from '../common/Constants';
import { Track } from '../model/MusicModels';

/** 缓存区容量上限（512MB）：单曲 m4a 约 3~8MB，约可容纳 60~150 首 */
const LISTEN_CACHE_MAX_BYTES: number = 512 * 1024 * 1024;
/** 淘汰水位线（90%）：超限后删到这条线为止，留出滞回带 */
const LISTEN_CACHE_EVICT_TARGET: number = Math.floor(LISTEN_CACHE_MAX_BYTES * 0.9);
/** 最小有效音频体积：小于它的文件必是错误页残骸 */
const MIN_VALID_AUDIO_BYTES: number = 1024;
/** 流式下载「停滞」判定（连续无数据即失败，固定总超时会误杀大文件） */
const STREAM_IDLE_TIMEOUT_MS: number = 30000;
const STREAM_POLL_INTERVAL_MS: number = 500;
/** 待缓存队列长度上限：超出说明缓存长期追不上（如全程蜂窝被拦），丢弃新请求防膨胀 */
const MAX_QUEUE_LENGTH: number = 64;

/** 队列元素：曲目 + 优先直链（刚播的那条，可能已过期）+ 兜底重解析档位 */
interface ListenCacheJob {
  track: Track;
  audioUrl: string;
  qualityId: number;
}

/** LRU 淘汰用的文件年龄项（key = 去掉扩展名的文件名，即索引键） */
interface ListenCacheFileAge {
  key: string;
  name: string;
  mtime: number;
  size: number;
}

let cacheDir: string = '';
/** 内存索引：trackId → 落盘路径。init 时扫描目录建立，写入 / 淘汰 / 清理同步维护 */
const listenIndex: Map<string, string> = new Map<string, string>();
/** 串行队列（含排队去重）：同一曲目同时最多在队列里一份 */
const queue: ListenCacheJob[] = [];
const queuedIds: Set<string> = new Set<string>();
/** 队列消费者是否在跑（防重入：enqueue 每次都 pump，没有标志会起两个消费者下同一首） */
let pumping: boolean = false;

/** 初始化缓存目录。AppContainer.initRest 调用：同步建目录 + 扫描索引（文件数百级，毫秒级） */
export function initListenCache(context: common.Context): void {
  try {
    cacheDir = `${context.filesDir}/listen_cache`;
    if (!fs.accessSync(cacheDir)) {
      fs.mkdirSync(cacheDir, true);
    }
    rebuildIndex();
  } catch (e) {
    console.error(`initListenCache failed: ${JSON.stringify(e)}`);
    cacheDir = '';
  }
}

/** trackId 可能含 `:` `/` `#` 等路径字符（bvid::cid / bvid#cid），统一转安全文件名 */
function safeName(name: string): string {
  const cleaned: string = name.replace(/[^\w\-]+/g, '_');
  return cleaned.length > 0 ? cleaned : 'track';
}

function isAudioFileName(name: string): boolean {
  return name.endsWith('.m4a') || name.endsWith('.flac') || name.endsWith('.mp3');
}

/** 扫描目录重建内存索引（init 与全量清理后调用） */
function rebuildIndex(): void {
  listenIndex.clear();
  if (cacheDir.length === 0) {
    return;
  }
  try {
    const names: string[] = fs.listFileSync(cacheDir);
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      if (!isAudioFileName(name)) {
        continue;
      }
      const dot: number = name.lastIndexOf('.');
      if (dot <= 0) {
        continue;
      }
      listenIndex.set(name.substring(0, dot), `${cacheDir}/${name}`);
    }
  } catch (e) {
    console.error(`rebuild listen cache index failed: ${JSON.stringify(e)}`);
  }
}

/** 是否已有该曲目的听后缓存（prefetch 跳过 / 幂等判定用） */
export function hasListenCache(trackId: string): boolean {
  return trackId.length > 0 && listenIndex.has(trackId);
}

/** 缓存命中路径（MusicPlayer.loadAndPlay 本地优先链查询用），未命中返回空串 */
export function cachedListenPath(trackId: string): string {
  if (trackId.length === 0) {
    return '';
  }
  const path: string | undefined = listenIndex.get(trackId);
  return path !== undefined ? path : '';
}

/**
 * 命中播放时刷新文件 mtime（LRU 的「最近使用」时间）。
 * fs.utimes 是同步接口但只改一条文件元数据（亚毫秒），切歌路径上开销可忽略。
 * 失败静默：touch 不成只影响淘汰顺序，不影响播放。
 */
export function touchListenCache(trackId: string): void {
  const path: string | undefined = listenIndex.get(trackId);
  if (path === undefined) {
    return;
  }
  try {
    fs.utimes(path, Math.floor(Date.now() / 1000));
  } catch (e) {
    // 元数据更新失败不影响命中播放
  }
}

/**
 * 删除单首听后缓存：
 * MusicPlayer 本地优先链播缓存文件挂载失败（badFile）回退在线成功后顺手清理，
 * 这首不再反复撞坏文件。先摘内存索引（后续 cachedListenPath 立即未命中），
 * 再异步删文件；删失败只返回 false，不影响已回退的在线播放。
 */
export async function removeListenCacheFile(trackId: string): Promise<boolean> {
  if (trackId.length === 0) {
    return false;
  }
  const path: string | undefined = listenIndex.get(trackId);
  if (path === undefined) {
    return false;
  }
  listenIndex.delete(trackId);
  try {
    await fs.unlink(path);
    return true;
  } catch (e) {
    console.error(`remove listen cache file failed: ${JSON.stringify(e)}`);
    return false;
  }
}

/**
 * 入队一首「刚听完」的曲目（fire-and-forget，MusicPlayer completed 钩子调用）。
 * 幂等：已缓存 / 已在队列的直接返回（单曲循环每轮 completed 都会触发，靠这里去重）。
 */
export function enqueueListenCache(track: Track, audioUrl: string, qualityId: number): void {
  if (cacheDir.length === 0 || track.id.length === 0) {
    return;
  }
  if (listenIndex.has(track.id) || queuedIds.has(track.id)) {
    return;
  }
  if (queue.length >= MAX_QUEUE_LENGTH) {
    return;
  }
  queuedIds.add(track.id);
  queue.push({ track: track, audioUrl: audioUrl, qualityId: qualityId });
  pump();
}

/** 启动串行消费者（幂等，见 pumping 注释） */
function pump(): void {
  if (pumping) {
    return;
  }
  pumping = true;
  runQueue()
    .then((): void => {
      pumping = false;
      drainIfPending();
    })
    .catch((e: Error): void => {
      console.error(`listen cache queue crashed: ${e.message}`);
      pumping = false;
      drainIfPending();
    });
}

/** 消费者退出后若队列又进了新活（最后一条 await 落地与 enqueue 的竞态窗口），再拉起 */
function drainIfPending(): void {
  if (queue.length > 0) {
    pump();
  }
}

async function runQueue(): Promise<void> {
  while (queue.length > 0) {
    const job: ListenCacheJob | undefined = queue.shift();
    if (job === undefined) {
      continue;
    }
    try {
      await cacheOne(job);
    } catch (e) {
      console.error(`listen cache job failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    } finally {
      queuedIds.delete(job.track.id);
    }
  }
}

/** 处理一首：门控复查 → 优先直链下载 → 失败兜底重解析 → 入索引 → LRU 淘汰 */
async function cacheOne(job: ListenCacheJob): Promise<void> {
  const track: Track = job.track;
  // 出队复查（排队期间设置 / 网络可能已变）：
  // 开关被关 / 已缓存（重复入队被索引拦下）→ 直接放弃
  if (!AppPreferences.getSettings().listenCacheEnabled || listenIndex.has(track.id)) {
    return;
  }
  // 流量门控跟随「仅 WiFi 下载」；无网 / 探测失败不拦（NetworkUtil 失误放行是安全方向）
  if (AppPreferences.getSettings().wifiOnlyDownload && !isUnmeteredNetwork()) {
    return;
  }
  if (!hasNetwork()) {
    return;
  }
  const ext: string = audioFileExt(track.audioQuality, track.audioMimeType);
  const destPath: string = `${cacheDir}/${safeName(track.id)}.${ext.length > 0 ? ext : 'm4a'}`;
  let storedPath: string = '';
  let ok: boolean = false;
  if (job.audioUrl.length > 0) {
    ok = await downloadTo(job.audioUrl, destPath);
    if (ok) {
      storedPath = destPath;
    }
  }
  if (!ok) {
    // 刚播的直链过期 / 下载失败：重解析一次拿新直链（档位沿用播放档，缓存的就是听到的品质）
    try {
      const source = await extractAudioFromVideo(track.bvid || track.id, {
        aid: track.aid,
        cid: track.cid
      }, job.qualityId);
      const reExt: string = audioFileExt(source.audioQuality, source.audioMimeType);
      const rePath: string = `${cacheDir}/${safeName(track.id)}.${reExt.length > 0 ? reExt : 'm4a'}`;
      ok = await downloadTo(source.audioUrl, rePath);
      if (ok) {
        storedPath = rePath;
      }
    } catch (e) {
      console.error(`listen cache re-resolve failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    }
  }
  if (!ok || storedPath.length === 0) {
    return;
  }
  const dot: number = storedPath.lastIndexOf('/');
  const fileName: string = dot >= 0 ? storedPath.substring(dot + 1) : storedPath;
  const keyEnd: number = fileName.lastIndexOf('.');
  if (keyEnd > 0) {
    listenIndex.set(fileName.substring(0, keyEnd), storedPath);
  }
  console.info(`listen cache stored: ${track.id} -> ${storedPath}`);
  await pruneIfNeeded();
}

/**
 * 校验落盘文件是不是真的音频（照抄 DownloadManager.isValidAudioFile）。
 * B 站音频 CDN 直链过期 / 被限流时会回 **HTTP 200 + HTML/JSON 错误页**，
 * 不校验就会把错误页缓存下来，表现为「重播没声音」。
 * 四类魔数：fMP4(ftyp) / 裸 FLAC(fLaC) / ID3v2 MP3 / 帧同步裸 MP3。
 */
async function isValidAudioFile(path: string): Promise<boolean> {
  let probe: fs.File | null = null;
  try {
    const stat: fs.Stat = await fs.stat(path);
    if (stat.size < MIN_VALID_AUDIO_BYTES) {
      return false;
    }
    probe = await fs.open(path, fs.OpenMode.READ_ONLY);
    const buf: ArrayBuffer = new ArrayBuffer(12);
    await fs.read(probe.fd, buf);
    const bytes: Uint8Array = new Uint8Array(buf);
    const tag: string = String.fromCharCode(bytes[4], bytes[5], bytes[6], bytes[7]);
    if (tag === 'ftyp') {
      return true;
    }
    const magic: string = String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]);
    if (magic === 'fLaC') {
      return true;
    }
    if (magic.substring(0, 3) === 'ID3') {
      return true;
    }
    return bytes[0] === 0xFF && (bytes[1] & 0xE0) === 0xE0;
  } catch (e) {
    return false;
  } finally {
    if (probe !== null) {
      try {
        await fs.close(probe.fd);
      } catch (e) {
        // 关闭失败不影响校验结果
      }
    }
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: (value: void) => void): void => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}

/**
 * 流式下载一首到目标路径（requestInStream 三铁律简版，见 DownloadManager.downloadFile）：
 *  1. requestInStream 的 Promise 只代表响应头已到，必须轮询等 dataEnd；
 *  2. 事件回调里绝不抛异常（跑在事件分发路径上，没人接得住）；
 *  3. 关文件 / 销毁请求前先等写链落定。
 * 听后缓存无需断点续传 / 暂停：失败一律删半截文件返回 false（下次听完自然重试）。
 */
async function downloadTo(url: string, destPath: string): Promise<boolean> {
  const request: http.HttpRequest = http.createHttp();
  let fd: number = -1;
  let dataEnded: boolean = false;
  let lastActivityAt: number = Date.now();
  let writeOffset: number = 0;
  let writeChain: Promise<void> = Promise.resolve();
  let writeFailed: boolean = false;
  try {
    const file: fs.File = await fs.open(destPath,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fd = file.fd;
  } catch (e) {
    console.error(`listen cache open dest failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    request.destroy();
    return false;
  }
  request.on('dataReceive', (data: ArrayBuffer): void => {
    try {
      lastActivityAt = Date.now();
      if (fd < 0) {
        return;
      }
      // 显式 offset + 异步写：主线程只记账、不落盘（同 DownloadManager）
      const offset: number = writeOffset;
      writeOffset += data.byteLength;
      writeChain = writeChain
        .then((): Promise<number> => fs.write(fd, data, { offset: offset }))
        .then((_: number): void => {})
        .catch((e: Error): void => {
          writeFailed = true;
          console.error(`listen cache write chunk failed: ${e.message}`);
        });
    } catch (e) {
      console.error(`listen cache queue chunk failed: ${JSON.stringify(e)}`);
    }
  });
  request.on('dataEnd', (): void => {
    dataEnded = true;
  });
  try {
    const header: Record<string, string> = {
      Referer: BILI_REFERER,
      'User-Agent': 'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile',
      Accept: '*/*'
    };
    const baseCookie: string = HttpUtil.getBaseCookie();
    if (baseCookie.length > 0) {
      header['Cookie'] = baseCookie;
    }
    const code: number = await request.requestInStream(url, {
      method: http.RequestMethod.GET,
      header: header,
      usingCache: false,
      connectTimeout: 15000,
      readTimeout: 60000
    });
    // 状态码必须校验：直链过期时 CDN 会回 200 + 错误页（魔数校验兜底，这里先拦最明显的）
    if (code !== 200 && code !== 206) {
      throw new Error(`listen cache HTTP ${code}`);
    }
    while (!dataEnded) {
      if (Date.now() - lastActivityAt > STREAM_IDLE_TIMEOUT_MS) {
        throw new Error('listen cache stalled');
      }
      await sleep(STREAM_POLL_INTERVAL_MS);
    }
    await writeChain;
    if (writeFailed) {
      throw new Error('listen cache write chunk failed');
    }
    if (!await isValidAudioFile(destPath)) {
      throw new Error('listen cache file is not valid audio');
    }
    return true;
  } catch (e) {
    console.error(`listen cache download failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    try {
      await writeChain;
    } catch (e1) {
      // 链内失败已记 writeFailed，这里只保证时序
    }
    try {
      await fs.unlink(destPath);
    } catch (e2) {
      // 文件可能尚未创建
    }
    return false;
  } finally {
    // 顺序不能变：摘监听 → 等写链 → 关文件 → 销毁请求（反序是 native 崩溃路径）
    try {
      request.off('dataReceive');
      request.off('dataEnd');
    } catch (e) {
      console.error(`listen cache detach events failed: ${JSON.stringify(e)}`);
    }
    try {
      await writeChain;
    } catch (e1) {
      // 只保证时序
    }
    try {
      if (fd >= 0) {
        await fs.close(fd);
      }
    } catch (e) {
      console.error(`listen cache close dest failed: ${JSON.stringify(e)}`);
    }
    try {
      request.destroy();
    } catch (e) {
      console.error(`listen cache destroy request failed: ${JSON.stringify(e)}`);
    }
  }
}

/** 超容量时按 mtime 淘汰最旧的（只在写入后异步执行，不阻塞任何路径） */
async function pruneIfNeeded(): Promise<void> {
  if (cacheDir.length === 0) {
    return;
  }
  let names: string[] = [];
  try {
    names = await fs.listFile(cacheDir);
  } catch (e) {
    return;
  }
  const files: ListenCacheFileAge[] = [];
  let total: number = 0;
  for (let i = 0; i < names.length; i++) {
    const name: string = names[i];
    if (!isAudioFileName(name)) {
      continue;
    }
    try {
      const st: fs.Stat = await fs.stat(`${cacheDir}/${name}`);
      const dot: number = name.lastIndexOf('.');
      files.push({
        key: dot > 0 ? name.substring(0, dot) : name,
        name: name,
        mtime: st.mtime,
        size: st.size
      });
      total += st.size;
    } catch (e) {
      // 单个读不到跳过
    }
  }
  if (total <= LISTEN_CACHE_MAX_BYTES) {
    return;
  }
  files.sort((a: ListenCacheFileAge, b: ListenCacheFileAge): number => a.mtime - b.mtime);
  for (let i = 0; i < files.length && total > LISTEN_CACHE_EVICT_TARGET; i++) {
    try {
      await fs.unlink(`${cacheDir}/${files[i].name}`);
      total -= files[i].size;
      listenIndex.delete(files[i].key);
      console.info(`listen cache evicted: ${files[i].name}`);
    } catch (e) {
      // 单个删不掉不影响其余淘汰
    }
  }
}

/** 缓存曲目数（设置页展示用） */
export function countListenCache(): number {
  return listenIndex.size;
}

/** 缓存区总占用（字节，设置页展示用；异步 stat 循环，文件数百级不阻塞主线程） */
export async function listenCacheUsage(): Promise<number> {
  if (cacheDir.length === 0) {
    return 0;
  }
  let names: string[] = [];
  try {
    names = await fs.listFile(cacheDir);
  } catch (e) {
    return 0;
  }
  let total: number = 0;
  for (let i = 0; i < names.length; i++) {
    if (!isAudioFileName(names[i])) {
      continue;
    }
    try {
      const st: fs.Stat = await fs.stat(`${cacheDir}/${names[i]}`);
      total += st.size;
    } catch (e) {
      // 单个读不到跳过
    }
  }
  return total;
}

/**
 * 清空全部听后缓存（设置页「清理听后缓存」用）。
 * @returns 删除的文件个数
 */
export async function clearListenCache(): Promise<number> {
  if (cacheDir.length === 0) {
    return 0;
  }
  let names: string[] = [];
  try {
    names = await fs.listFile(cacheDir);
  } catch (e) {
    return 0;
  }
  let removed: number = 0;
  for (let i = 0; i < names.length; i++) {
    if (!isAudioFileName(names[i])) {
      continue;
    }
    try {
      await fs.unlink(`${cacheDir}/${names[i]}`);
      removed += 1;
    } catch (e) {
      // 正被播放占用的文件删不掉，跳过（清不掉的那首下次清理即可）
    }
  }
  rebuildIndex();
  return removed;
}
