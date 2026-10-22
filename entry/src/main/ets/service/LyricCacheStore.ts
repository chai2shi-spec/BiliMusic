/**
 * 歌词缓存（文件型落盘）。
 *
 * 为什么不用 Preferences：`@ohos.data.preferences` 单值 **8192 字节硬上限**，
 * 而一首带翻译 + 罗马音 + 逐字的歌词序列化后 5~25KB —— 旧实现
 * （`LyricsApi` 把**全部歌曲**的歌词塞进 `bilimusic_lyrics_v2` 一个 key）
 * 实际上写两首就超限，`put()` 抛错被吞掉，表现为「歌词缓存从来没生效、每次都联网搜」。
 *
 * 结构：`{filesDir}/lyrics/{sanitizedTrackId}.json`，一个曲目一个文件。
 *   - `status='ok'`：直接返回；
 *   - `status='miss'`：24h 内不再联网（避免每次进播放页都白搜一遍）；
 *   - `manual=true`：用户手动选过候选，自动搜索不再覆盖（只认用户的选择）；
 *   - `skipped=true`：用户主动跳过，永久不再自动搜（等价 BBPlayer 的 manualSkip）。
 *
 * 损坏即弃：读失败 / JSON 解析失败 / 字段不合法一律当无缓存，绝不把脏数据甩进 UI。
 * 容量：单曲一个文件，超过 MAX_CACHED_LYRICS 个时按文件 mtime 淘汰最旧的一批
 * （只在写入后检查，异步执行，不阻塞播放页）。
 */

import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { LyricResult } from '../model/MusicModels';

export const LYRIC_CACHE_OK: string = 'ok';
export const LYRIC_CACHE_MISS: string = 'miss';

/** miss 结论有效期（24h）：过了就允许重搜（换了音源 / 时长补全后可能就有了） */
const MISS_TTL_MS: number = 24 * 60 * 60 * 1000;
/** 最多缓存多少首歌词（单文件 5~25KB，300 首 ≈ 3~7MB） */
const MAX_CACHED_LYRICS: number = 300;

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

/** 初始化缓存目录。AppContainer.initRest 调用，同步建目录（毫秒级）。 */
export function initLyricCache(context: common.Context): void {
  try {
    cacheDir = `${context.filesDir}/lyrics`;
    if (!fs.accessSync(cacheDir)) {
      fs.mkdirSync(cacheDir, true);
    }
  } catch (e) {
    console.error(`initLyricCache failed: ${JSON.stringify(e)}`);
    cacheDir = '';
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

function pathOf(trackId: string): string {
  return `${cacheDir}/${fileNameOf(trackId)}.json`;
}

/** 读缓存：无缓存 / 损坏 / 未初始化一律 null */
export async function readLyricCache(trackId: string): Promise<LyricCacheEntry | null> {
  if (cacheDir.length === 0 || trackId.length === 0) {
    return null;
  }
  let raw: string = '';
  try {
    raw = await fs.readText(pathOf(trackId));
  } catch (e) {
    return null;
  }
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

/** 写缓存（异步，失败只记日志 —— 缓存不可用不能影响歌词显示） */
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
    // 鸿蒙 fileIo 没有 writeText：必须 open → write → close（异步版，避免主线程阻塞）
    const file: fs.File = await fs.open(pathOf(entry.trackId),
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
 * 删除某个曲目的缓存（时长补全 / 手动重搜时调用）。
 * **同步**：调用方紧接着就会重新读缓存（`clearLyricCache` → `getLyricForTrack`），
 * 异步删除会形成「删还没完成就先读到旧值」的竞态。
 */
export function deleteLyricCache(trackId: string): void {
  if (cacheDir.length === 0) {
    return;
  }
  try {
    fs.unlinkSync(pathOf(trackId));
  } catch (e) {
    // 文件不存在属常态
  }
}

/** 清空全部歌词缓存（设置页「清理缓存」用） */
export function clearAllLyricCache(): void {
  if (cacheDir.length === 0) {
    return;
  }
  try {
    const names: string[] = fs.listFileSync(cacheDir);
    for (let i = 0; i < names.length; i++) {
      if (!names[i].endsWith('.json')) {
        continue;
      }
      try {
        fs.unlinkSync(`${cacheDir}/${names[i]}`);
      } catch (e) {
        // 单个失败不影响其它
      }
    }
  } catch (e) {
    console.error(`clearAllLyricCache failed: ${JSON.stringify(e)}`);
  }
}

/** 缓存条数（「清理缓存」显示用） */
export function countLyricCache(): number {
  if (cacheDir.length === 0) {
    return 0;
  }
  try {
    const names: string[] = fs.listFileSync(cacheDir);
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

/** 淘汰用的文件年龄项 */
interface LyricFileAge {
  name: string;
  mtime: number;
}

/**
 * 超容量时淘汰最旧的一半。
 * 用 mtime 排序而不是读文件内容里的 updatedAt —— 后者要逐个解析 JSON，
 * 300 个文件读一遍会明显卡主线程。
 */
async function pruneIfNeeded(): Promise<void> {
  let names: string[] = [];
  try {
    names = await fs.listFile(cacheDir);
  } catch (e) {
    return;
  }
  const files: string[] = [];
  for (let i = 0; i < names.length; i++) {
    if (names[i].endsWith('.json')) {
      files.push(names[i]);
    }
  }
  if (files.length <= MAX_CACHED_LYRICS) {
    return;
  }
  const ages: LyricFileAge[] = [];
  for (let i = 0; i < files.length; i++) {
    try {
      const stat: fs.Stat = await fs.stat(`${cacheDir}/${files[i]}`);
      ages.push({ name: files[i], mtime: stat.mtime * 1000 });
    } catch (e) {
      // 读不到就跳过
    }
  }
  ages.sort((a: LyricFileAge, b: LyricFileAge): number => a.mtime - b.mtime);
  const dropCount: number = Math.floor(ages.length / 2);
  for (let i = 0; i < dropCount; i++) {
    try {
      await fs.unlink(`${cacheDir}/${ages[i].name}`);
    } catch (e) {
      // 单个失败不影响
    }
  }
}
