/**
 * 歌词缓存（文件型落盘）。
 *
 * 为什么不用 Preferences：`@ohos.data.preferences` 单值 **8192 字节硬上限**，
 * 而一首带翻译 + 罗马音 + 逐字的歌词序列化后 5~25KB，写两首就超限。
 *
 * 结构：一个曲目一个文件，按「用户是否手选」物理隔离——
 *   - 自动缓存：`{filesDir}/lyrics/{sanitizedTrackId}.json`
 *   - 手选缓存：`{filesDir}/lyrics/manual/{sanitizedTrackId}.json`
 *   - `status='ok'`：直接返回；
 *   - `status='miss'`：24h 内不再联网（避免每次进播放页都白搜一遍）；
 *   - `manual=true`：用户手动选过候选，落 manual 子目录 —— 容量淘汰（prune）
 *     永远不碰它，只有用户显式操作（面板「重新获取」/ 设置页「清理缓存」）
 *     才会清除；读路径永远先看 manual 目录（手选 > 算法）；
 *   - `skipped=true`：用户主动跳过，永久不再自动搜（等价 BBPlayer 的 manualSkip）。
 *
 * 兼容：旧版本 manual 条目写在自动目录里 —— 读到后自愈迁移进 manual 目录
 * （写新位置 + 删旧文件），无需迁移脚本。
 *
 * 损坏即弃：读失败 / JSON 解析失败 / 字段不合法一律当无缓存，绝不把脏数据甩进 UI。
 * 容量：自动目录超 MAX_CACHED_LYRICS、manual 目录超 MAX_MANUAL_LYRICS 时，
 * 各自按文件 mtime 淘汰最旧的一半（只在写入后检查，异步执行，不阻塞播放页）。
 */

import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { LyricResult } from '../model/MusicModels';

export const LYRIC_CACHE_OK: string = 'ok';
export const LYRIC_CACHE_MISS: string = 'miss';

/** miss 结论有效期（24h）：过了就允许重搜（换了音源 / 时长补全后可能就有了） */
const MISS_TTL_MS: number = 24 * 60 * 60 * 1000;
/** 最多缓存多少首自动歌词（单文件 5~25KB，300 首 ≈ 3~7MB） */
const MAX_CACHED_LYRICS: number = 300;
/** manual（用户手选）目录独立上限：与自动目录互不挤占，仅按各自上限淘汰 */
const MAX_MANUAL_LYRICS: number = 200;

export interface LyricCacheEntry {
  trackId: string;
  /** 信息键（id + 标题 + 歌手 + 时长是否已知）：变了就允许重搜 */
  cacheKey: string;
  status: string;
  updatedAt: number;
  manual: boolean;
  skipped: boolean;
  /** manual=true 时记录用户选的候选，重进时直接取它 */
  candidateSource: string;
  candidateRemoteId: string;
  result: LyricResult | null;
}

let cacheDir: string = '';
let cacheDirManual: string = '';

/** 初始化缓存目录。AppContainer.initRest 调用，同步建目录（毫秒级）。 */
export function initLyricCache(context: common.Context): void {
  try {
    cacheDir = `${context.filesDir}/lyrics`;
    cacheDirManual = `${cacheDir}/manual`;
    if (!fs.accessSync(cacheDir)) {
      fs.mkdirSync(cacheDir, true);
    }
    if (!fs.accessSync(cacheDirManual)) {
      fs.mkdirSync(cacheDirManual, true);
    }
  } catch (e) {
    console.error(`initLyricCache failed: ${JSON.stringify(e)}`);
    cacheDir = '';
    cacheDirManual = '';
  }
}

/** trackId 可能含 `:` `/` 等路径字符（bvid::cid），统一转安全文件名 */
function fileNameOf(trackId: string): string {
  let safe: string = '';
  for (let i = 0; i < trackId.length; i++) {
    const ch: string = trackId[i];
    const code: number = trackId.charCodeAt(i);
    const isDigit: boolean = code >= 48 && code <= 57;
    const isUpper: boolean = code >= 65 && code <= 90;
    const isLower: boolean = code >= 97 && code <= 122;
    safe += (isDigit || isUpper || isLower || ch === '_' || ch === '-') ? ch : '_';
  }
  return safe.length > 0 ? safe : 'unknown';
}

/** manual=true 走 manual 子目录（手选结果的家），否则走自动缓存目录 */
function pathOf(trackId: string, manual: boolean): string {
  return `${manual ? cacheDirManual : cacheDir}/${fileNameOf(trackId)}.json`;
}

/** 读文件文本：任何失败（不存在 / IO 错误）一律空串 */
async function readTextSafe(path: string): Promise<string> {
  try {
    return await fs.readText(path);
  } catch (e) {
    return '';
  }
}

/** 解析缓存 JSON：损坏 / 字段不合法 / ok 却没有行 一律 null（绝不把脏数据甩进 UI） */
function parseEntry(raw: string, trackId: string): LyricCacheEntry | null {
  if (raw.length === 0) {
    return null;
  }
  try {
    const parsed = JSON.parse(raw) as LyricCacheEntry;
    if (parsed === null || parsed.trackId !== trackId) {
      return null;
    }
    const entry: LyricCacheEntry = {
      trackId: trackId,
      cacheKey: typeof parsed.cacheKey === 'string' ? parsed.cacheKey : '',
      status: typeof parsed.status === 'string' ? parsed.status : LYRIC_CACHE_MISS,
      updatedAt: typeof parsed.updatedAt === 'number' ? parsed.updatedAt : 0,
      manual: parsed.manual === true,
      skipped: parsed.skipped === true,
      candidateSource: typeof parsed.candidateSource === 'string' ? parsed.candidateSource : '',
      candidateRemoteId: typeof parsed.candidateRemoteId === 'string' ? parsed.candidateRemoteId : '',
      result: parsed.status === LYRIC_CACHE_OK ? parsed.result : null
    };
    if (entry.status === LYRIC_CACHE_OK
      && (entry.result === null || !Array.isArray(entry.result.lines) || entry.result.lines.length === 0)) {
      // 标了 ok 却没有行：脏数据，当无缓存
      return null;
    }
    return entry;
  } catch (e) {
    return null;
  }
}

/** 读缓存：manual 目录优先（手选 > 算法），未命中回落自动目录（含旧版 manual 自愈迁移） */
export async function readLyricCache(trackId: string): Promise<LyricCacheEntry | null> {
  if (cacheDir.length === 0 || trackId.length === 0) {
    return null;
  }
  const manualEntry: LyricCacheEntry | null =
    parseEntry(await readTextSafe(pathOf(trackId, true)), trackId);
  if (manualEntry !== null) {
    return manualEntry;
  }
  const autoEntry: LyricCacheEntry | null =
    parseEntry(await readTextSafe(pathOf(trackId, false)), trackId);
  if (autoEntry !== null && autoEntry.manual && autoEntry.status === LYRIC_CACHE_OK) {
    // 旧版把 manual 条目写进了自动目录：自愈迁移（写进 manual 目录 + 删旧文件），
    // 之后读路径直接命中 manual 目录，自动目录的容量淘汰也碰不到它。
    await writeLyricCache(autoEntry);
    try {
      fs.unlinkSync(pathOf(trackId, false));
    } catch (e) {
      // 删不掉也无碍：读路径永远先看 manual 目录
    }
  }
  return autoEntry;
}

/** 写缓存（异步，失败只记日志 —— 缓存不可用不能影响歌词显示）。manual 条目落 manual 目录 */
export async function writeLyricCache(entry: LyricCacheEntry): Promise<void> {
  if (cacheDir.length === 0) {
    return;
  }
  const payload: LyricCacheEntry = {
    trackId: entry.trackId,
    cacheKey: entry.cacheKey,
    status: entry.status,
    updatedAt: Date.now(),
    manual: entry.manual,
    skipped: entry.skipped,
    candidateSource: entry.candidateSource,
    candidateRemoteId: entry.candidateRemoteId,
    result: entry.result
  };
  try {
    const json: string = JSON.stringify(payload);
    const manual: boolean = payload.manual === true;
    // 鸿蒙 fileIo 没有 writeText：必须 open → write → close（异步版，避免主线程阻塞）
    const file: fs.File = await fs.open(pathOf(entry.trackId, manual),
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      await fs.write(file.fd, json);
    } finally {
      await fs.close(file);
    }
  } catch (e) {
    console.error(`writeLyricCache failed: ${JSON.stringify(e)}`);
    return;
  }
  void pruneIfNeeded();
}

/** miss 结论是否还在有效期内 */
export function isMissFresh(entry: LyricCacheEntry): boolean {
  if (entry.status !== LYRIC_CACHE_MISS) {
    return false;
  }
  return Date.now() - entry.updatedAt < MISS_TTL_MS;
}

/**
 * 删除某个曲目的缓存（面板「重新获取」等显式路径调用）。
 * **同步**：调用方紧接着就会重新读缓存（`clearLyricCache` → `getLyricForTrack`），
 * 异步删除会形成「删还没完成就先读到旧值」的竞态。
 * manual / 自动两个路径都删 —— 用户显式要求重搜时允许清掉手选结果。
 */
export function deleteLyricCache(trackId: string): void {
  if (cacheDir.length === 0) {
    return;
  }
  try {
    fs.unlinkSync(pathOf(trackId, false));
  } catch (e) {
    // 文件不存在属常态
  }
  try {
    fs.unlinkSync(pathOf(trackId, true));
  } catch (e) {
    // 文件不存在属常态
  }
}

/** 清空单个目录内全部 .json */
function clearDir(dir: string): void {
  if (dir.length === 0) {
    return;
  }
  try {
    const names: string[] = fs.listFileSync(dir);
    for (let i = 0; i < names.length; i++) {
      if (!names[i].endsWith('.json')) {
        continue;
      }
      try {
        fs.unlinkSync(`${dir}/${names[i]}`);
      } catch (e) {
        // 单个失败不影响其它
      }
    }
  } catch (e) {
    console.error(`clearDir failed: ${JSON.stringify(e)}`);
  }
}

/** 清空全部歌词缓存（设置页「清理缓存」用）：manual + 自动两目录都清（用户显式操作） */
export function clearAllLyricCache(): void {
  clearDir(cacheDir);
  clearDir(cacheDirManual);
}

/** 数一个目录里的 .json 文件数 */
function countDir(dir: string): number {
  if (dir.length === 0) {
    return 0;
  }
  try {
    const names: string[] = fs.listFileSync(dir);
    let n: number = 0;
    for (let i = 0; i < names.length; i++) {
      if (names[i].endsWith('.json')) {
        n++;
      }
    }
    return n;
  } catch (e) {
    return 0;
  }
}

/** 缓存条数（「清理缓存」显示用）：manual + 自动两目录合计 */
export function countLyricCache(): number {
  return countDir(cacheDir) + countDir(cacheDirManual);
}

/** 淘汰用的文件年龄项 */
interface LyricFileAge {
  name: string;
  mtime: number;
}

/**
 * 单目录超容量时淘汰最旧的一半。
 * 用 mtime 排序而不是读文件内容里的 updatedAt —— 后者要逐个解析 JSON，
 * 300 个文件读一遍会明显卡主线程。
 */
async function pruneDir(dir: string, maxCount: number): Promise<void> {
  if (dir.length === 0) {
    return;
  }
  let names: string[] = [];
  try {
    names = await fs.listFile(dir);
  } catch (e) {
    return;
  }
  const files: string[] = [];
  for (let i = 0; i < names.length; i++) {
    if (names[i].endsWith('.json')) {
      files.push(names[i]);
    }
  }
  if (files.length <= maxCount) {
    return;
  }
  const ages: LyricFileAge[] = [];
  for (let i = 0; i < files.length; i++) {
    try {
      const stat: fs.Stat = await fs.stat(`${dir}/${files[i]}`);
      ages.push({ name: files[i], mtime: stat.mtime * 1000 });
    } catch (e) {
      // 读不到就跳过
    }
  }
  ages.sort((a: LyricFileAge, b: LyricFileAge): number => a.mtime - b.mtime);
  const dropCount: number = Math.floor(ages.length / 2);
  for (let i = 0; i < dropCount; i++) {
    try {
      await fs.unlink(`${dir}/${ages[i].name}`);
    } catch (e) {
      // 单个失败不影响
    }
  }
}

/** 写入后检查容量：自动目录与 manual 目录各自按独立上限淘汰（互不挤占） */
async function pruneIfNeeded(): Promise<void> {
  await pruneDir(cacheDir, MAX_CACHED_LYRICS);
  await pruneDir(cacheDirManual, MAX_MANUAL_LYRICS);
}
