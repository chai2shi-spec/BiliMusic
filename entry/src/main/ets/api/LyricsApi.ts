/**
 * 歌词服务（多源竞速版）—— 数据层移植自 BBPlayer 的
 * `lib/services/lyricService.ts` + `lib/api/{netease,qqmusic}/api.ts`。
 *
 * 与旧版的区别（旧版只接 OIAPI 一个第三方 QQ 歌词代理）：
 *   1. **三个源并行竞速**：网易云 / QQ 音乐 / OIAPI，谁先给出可用结果用谁。
 *      网易云给「主歌词 + 中文翻译 + 罗马音」，QQ 给「主歌词 + 翻译」，
 *      OIAPI 只兜底（没有翻译轨）。
 *   2. **候选打分**：沿用 `TextUtil.scoreCandidate`（标题包含 / 歌手命中 /
 *      时长分档 / 伴奏·翻唱降权），从三源合并后的候选里挑最优；
 *      自动搜索失败时还有第二轮「换关键词重搜」。
 *   3. **缓存改文件**：见 `service/LyricCacheStore.ts`（Preferences 单值 8192
 *      字节上限，旧实现写两首就静默失败）。
 *   4. **逐字 / 翻译 / 罗马音**：统一解析成 `LyricLine{ translation, romaji, words }`，
 *      显示层直接可用。
 *   5. **用户可控**：手动指定候选（`chooseLyricCandidate`）、跳过（`skipLyricForTrack`）、
 *      整体偏移（`getLyricOffset` / `setLyricOffset`，单位 ms）。
 *
 * 失败语义：整个链路任何一种失败都返回 null（不抛错），由 UI 显示「暂无歌词」。
 * 因为歌词是锦上添花，不能因为它把播放页搞崩。
 */

import { AppPreferences } from '../preferences/AppPreferences';
import {
  artistSegments,
  cleanTitle,
  queryCandidates,
  scoreCandidate,
  ScoreContext
} from '../utils/TextUtil';
import { LyricCandidate, LyricLine, LyricResult, LyricWord, Track } from '../model/MusicModels';
import {
  hasTimeTag,
  LyricSpanItem,
  parseAndMergeLyrics,
  plainTextToSpl,
  SplLyricLine
} from '../lyric/SplLyrics';
import {
  fetchLyricBySource,
  LyricSongCandidate,
  RawLyricData,
  searchSource,
  SOURCE_NETEASE,
  SOURCE_OIAPI,
  SOURCE_QQ
} from './LyricSourceApi';
import {
  deleteLyricCache,
  isMissFresh,
  LyricCacheEntry,
  LYRIC_CACHE_MISS,
  LYRIC_CACHE_OK,
  readLyricCache,
  writeLyricCache
} from '../service/LyricCacheStore';

/** 滚动偏移（ms）存 Preferences：只有曲目 id → 偏移的小映射，不会超 8192 字节 */
const OFFSET_KEY: string = 'bilimusic_lyric_offset_v1';
/** 自动搜索用到的关键词个数（每个关键词 × 3 源；2 个 = 最多 6 次搜索请求） */
const AUTO_QUERY_LIMIT: number = 2;
/** 每源每次搜索取多少候选 */
const SEARCH_LIMIT: number = 10;
/** 并行尝试取歌词的候选个数（先成功者胜，其余结果丢弃） */
const FETCH_RACE_WIDTH: number = 2;
/** 候选打分低于此值且标题互不包含 → 判为「不是同一首歌」 */
const MIN_ACCEPT_SCORE: number = 120;
/** 最后一行歌词的兜底时长（ms）：只用于逐字进度，不影响判行 */
const LAST_LINE_FALLBACK_MS: number = 8000;
/**
 * 单源搜索超时（ms）。
 * 三源是 `Promise.all` 汇合的 —— 任何一个源卡住（OIAPI 这类第三方代理尤其容易
 * 挂到 15s 才超时）都会把整首歌的歌词搜索拖成十几秒。超时即当「该源没结果」。
 */
const SEARCH_TIMEOUT_MS: number = 5000;
/** 单次取歌词超时（ms）：竞速里全卡住时不能无限等 */
const FETCH_TIMEOUT_MS: number = 6000;

// ───────────────────────────── 偏移 ─────────────────────────────

type OffsetMap = Record<string, number>;

function readOffsets(): OffsetMap {
  return AppPreferences.getObject<OffsetMap>(OFFSET_KEY) ?? {};
}

/** 读取某曲目的歌词偏移（ms，正数 = 歌词延后显示） */
export function getLyricOffset(trackId: string): number {
  const map: OffsetMap = readOffsets();
  const v: number | undefined = map[trackId];
  return v === undefined || Number.isNaN(v) ? 0 : v;
}

/** 设置歌词偏移（ms），夹在 ±30s 内防止误操作把歌词甩出可视区 */
export function setLyricOffset(trackId: string, offsetMs: number): void {
  const clamped: number = Math.max(-30000, Math.min(30000, Math.round(offsetMs)));
  const map: OffsetMap = readOffsets();
  // 不用 `delete map[key]`（ArkTS 对索引 delete 支持不完整），重建一份
  const next: OffsetMap = {};
  const keys: string[] = Object.keys(map);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i] !== trackId) {
      next[keys[i]] = map[keys[i]];
    }
  }
  if (clamped !== 0) {
    next[trackId] = clamped;
  }
  AppPreferences.setObject<OffsetMap>(OFFSET_KEY, next);
}

// ───────────────────────────── 候选搜索 ─────────────────────────────

/** 带超时的单源搜索：超时 / 抛错一律当「该源没结果」，绝不拖累其它源 */
function searchSafely(source: string, keyword: string): Promise<LyricSongCandidate[]> {
  return new Promise<LyricSongCandidate[]>((resolve: (v: LyricSongCandidate[]) => void): void => {
    let settled: boolean = false;
    const timer: number = setTimeout((): void => {
      if (settled) {
        return;
      }
      settled = true;
      resolve([]);
    }, SEARCH_TIMEOUT_MS);
    searchSource(source, keyword, SEARCH_LIMIT)
      .then((rows: LyricSongCandidate[]): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(rows);
      })
      .catch((): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve([]);
      });
  });
}

function toCandidate(raw: LyricSongCandidate): LyricCandidate {
  const cand: LyricCandidate = {
    id: `${raw.source}:${raw.remoteId}`,
    songId: raw.remoteId,
    mid: '',
    trackName: raw.title,
    artistName: raw.artist,
    albumName: raw.album,
    duration: normalizeDuration(raw.duration),
    image: '',
    source: raw.source,
    remoteId: raw.remoteId
  };
  return cand;
}

/**
 * 时长归一化成「秒」。
 * 三源单位不一致（网易云已转秒，QQ 是秒，OIAPI 有时给毫秒）：
 * 落在 3600~3600000 区间的按毫秒处理（1 小时~1000 小时，歌曲不可能这么长）。
 */
function normalizeDuration(d: number): number {
  if (!Number.isFinite(d) || d <= 0) {
    return 0;
  }
  if (d > 3600 && d < 3600000) {
    return Math.round(d / 1000);
  }
  return Math.round(d);
}

/** 三源并行搜索指定关键词，合并去重 */
async function searchAllSources(keyword: string): Promise<LyricCandidate[]> {
  const sources: string[] = [SOURCE_NETEASE, SOURCE_QQ, SOURCE_OIAPI];
  const tasks: Promise<LyricSongCandidate[]>[] = [];
  for (let i = 0; i < sources.length; i++) {
    tasks.push(searchSafely(sources[i], keyword));
  }
  const results: LyricSongCandidate[][] = await Promise.all(tasks);
  const out: LyricCandidate[] = [];
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < results.length; i++) {
    const rows: LyricSongCandidate[] = results[i];
    for (let k = 0; k < rows.length; k++) {
      const cand: LyricCandidate = toCandidate(rows[k]);
      if (seen.has(cand.id)) {
        continue;
      }
      seen.add(cand.id);
      out.push(cand);
    }
  }
  return out;
}

/** 按打分排序，返回 Top N */
function rankCandidates(
  candidates: LyricCandidate[],
  track: Track
): LyricCandidate[] {
  const ctx: ScoreContext = {
    rawTitle: track.title,
    clean: cleanTitle(track.title),
    duration: track.duration > 0 ? track.duration : 0,
    quoted: [],
    artist: track.artist
  };
  interface Scored {
    cand: LyricCandidate;
    score: number;
  }
  const scored: Scored[] = [];
  for (let i = 0; i < candidates.length; i++) {
    scored.push({ cand: candidates[i], score: scoreCandidate(candidates[i], ctx) });
  }
  scored.sort((a: Scored, b: Scored): number => b.score - a.score);
  const out: LyricCandidate[] = [];
  const limit: number = Math.min(scored.length, FETCH_RACE_WIDTH + 1);
  for (let i = 0; i < limit; i++) {
    out.push(scored[i].cand);
  }
  return out;
}

/** 候选是否「像同一首歌」：分数够高，或标题互相包含 */
function isPlausible(cand: LyricCandidate, track: Track): boolean {
  const ctx: ScoreContext = {
    rawTitle: track.title,
    clean: cleanTitle(track.title),
    duration: track.duration > 0 ? track.duration : 0,
    quoted: [],
    artist: track.artist
  };
  const score: number = scoreCandidate(cand, ctx);
  if (score >= MIN_ACCEPT_SCORE) {
    return true;
  }
  const a: string = ctx.clean;
  const b: string = cand.trackName;
  return a.length > 0 && b.length > 0 && (a.indexOf(b) >= 0 || b.indexOf(a) >= 0);
}

// ───────────────────────────── 原始歌词 → 结果 ─────────────────────────────

function toLyricResult(candidate: LyricCandidate, raw: RawLyricData): LyricResult | null {
  const synced: boolean = hasTimeTag(raw.lrc);
  // 没有任何时间标签：按 4s 均匀排布，让 LrcView 有东西可画（synced=false 供 UI 提示）
  const lrc: string = synced ? raw.lrc : plainTextToSpl(raw.lrc);
  if (lrc.length === 0) {
    return null;
  }
  const merged: SplLyricLine[] = parseAndMergeLyrics({
    lrc: lrc,
    tlyric: raw.tlyric,
    romalrc: raw.romalrc
  });
  if (merged.length === 0) {
    return null;
  }

  const lines: LyricLine[] = [];
  let hasTranslation: boolean = false;
  let dynamic: boolean = false;
  for (let i = 0; i < merged.length; i++) {
    const src: SplLyricLine = merged[i];
    const startSec: number = src.startTime / 1000;
    const lineDurationMs: number = i < merged.length - 1
      ? Math.max(1, merged[i + 1].startTime - src.startTime)
      : LAST_LINE_FALLBACK_MS;

    const words: LyricWord[] = [];
    if (src.isDynamic && src.spans.length > 0) {
      dynamic = true;
      for (let k = 0; k < src.spans.length; k++) {
        const span: LyricSpanItem = src.spans[k];
        const offset: number = Math.max(0, span.startTime - src.startTime);
        // 末段常被兜底成「行结束=很远」，夹到本行时长内，否则逐字渐变永远走不完
        const dur: number = Math.max(1, Math.min(span.duration, lineDurationMs - offset));
        const word: LyricWord = {
          text: span.text,
          offset: offset,
          duration: dur
        };
        words.push(word);
      }
    }
    if (src.translation.length > 0) {
      hasTranslation = true;
    }
    const line: LyricLine = {
      time: startSec,
      text: src.content,
      translation: src.translation,
      romaji: src.romaji,
      words: words
    };
    lines.push(line);
  }
  if (lines.length === 0) {
    return null;
  }

  const result: LyricResult = {
    lines: lines,
    synced: synced,
    instrumental: false,
    trackName: candidate.trackName,
    artistName: candidate.artistName,
    sourceId: candidate.remoteId === undefined ? String(candidate.songId) : candidate.remoteId,
    source: candidate.source,
    hasTranslation: hasTranslation,
    dynamic: dynamic
  };
  return result;
}

/** 手写「先成功者胜」竞速（不依赖 Promise.any：ArkTS 标准库覆盖不全） */
function raceFirstResult(tasks: Promise<LyricResult | null>[]): Promise<LyricResult | null> {
  return new Promise<LyricResult | null>((resolve: (v: LyricResult | null) => void): void => {
    const total: number = tasks.length;
    if (total === 0) {
      resolve(null);
      return;
    }
    let pending: number = total;
    let settled: boolean = false;
    function finish(value: LyricResult | null): void {
      if (settled) {
        return;
      }
      settled = true;
      resolve(value);
    }
    for (let i = 0; i < total; i++) {
      tasks[i]
        .then((r: LyricResult | null): void => {
          if (r !== null) {
            finish(r);
            return;
          }
          pending--;
          if (pending === 0) {
            finish(null);
          }
        })
        .catch((): void => {
          pending--;
          if (pending === 0) {
            finish(null);
          }
        });
    }
  });
}

/** 取某个候选的歌词并转成结果；任何失败 / 超时都返回 null */
function fetchCandidateResult(candidate: LyricCandidate): Promise<LyricResult | null> {
  return new Promise<LyricResult | null>((resolve: (v: LyricResult | null) => void): void => {
    const source: string = candidate.source === undefined ? '' : candidate.source;
    const remoteId: string = candidate.remoteId === undefined
      ? String(candidate.songId)
      : candidate.remoteId;
    if (source.length === 0 || remoteId.length === 0) {
      resolve(null);
      return;
    }
    let settled: boolean = false;
    const timer: number = setTimeout((): void => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(null);
    }, FETCH_TIMEOUT_MS);
    fetchLyricBySource(source, remoteId)
      .then((raw: RawLyricData | null): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        if (raw === null) {
          resolve(null);
          return;
        }
        resolve(toLyricResult(candidate, raw));
      })
      .catch((): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(null);
      });
  });
}

// ───────────────────────────── 主入口 ─────────────────────────────

/** 缓存用的「信息键」：标题 / 歌手 / 时长是否已知变化都要允许重搜 */
function cacheKeyOf(track: Track): string {
  // v2（2026-10-23 歌词匹配修复：歌手参与搜索与打分、Top1 优先取词）。
  // 旧 v1 键不再相等 → 存量自动缓存整体自动重搜一次；manual 缓存永远优先不受影响，
  // 旧自动结果仍作重搜失败时的兜底（见 getLyricForTrack）。
  return `v2|${track.id}|${track.title}|${track.artist}|${track.duration > 0 ? 'd' : 'n'}`;
}

function toEntry(
  track: Track,
  key: string,
  result: LyricResult | null,
  manual: boolean,
  candidate: LyricCandidate | null
): LyricCacheEntry {
  const entry: LyricCacheEntry = {
    trackId: track.id,
    cacheKey: key,
    status: result === null ? LYRIC_CACHE_MISS : LYRIC_CACHE_OK,
    updatedAt: Date.now(),
    manual: manual,
    skipped: false,
    candidateSource: candidate === null || candidate.source === undefined ? '' : candidate.source,
    candidateRemoteId: candidate === null || candidate.remoteId === undefined ? '' : candidate.remoteId,
    result: result
  };
  return entry;
}

/**
 * 组装自动搜索关键词（歌名 + 歌手优先，仅歌名兜底）。
 *
 * 2026-10-23 修匹配：此前只用标题搜词，同名曲 / 翻唱 / 伴奏极易误中。
 * 现在第一优先级是「标题关键词 + track.artist 首段」的组合词 ——
 * artist 可能是 UP 主名（不是真实歌手），所以组合词排前面、仅歌名关键词跟在后面：
 * 轮次机制天然形成「先试组合词、搜不到再回退仅歌名」的两级策略。
 */
function buildAutoQueries(track: Track): string[] {
  const titleQueries: string[] = queryCandidates(track.title);
  if (titleQueries.length === 0) {
    const fallback: string = cleanTitle(track.title);
    return fallback.length > 0 ? [fallback] : [];
  }
  const segs: string[] = artistSegments(track.artist);
  if (segs.length === 0) {
    return titleQueries;
  }
  const firstArtist: string = segs[0];
  const out: string[] = [];
  for (let i = 0; i < titleQueries.length && out.length < AUTO_QUERY_LIMIT; i++) {
    // 关键词里已含歌手（如标题本身是「周杰伦 晴天」）→ 不重复拼
    if (titleQueries[i].indexOf(firstArtist) >= 0) {
      continue;
    }
    out.push(`${titleQueries[i]} ${firstArtist}`);
  }
  for (let i = 0; i < titleQueries.length; i++) {
    if (out.indexOf(titleQueries[i]) < 0) {
      out.push(titleQueries[i]);
    }
  }
  return out;
}

/**
 * 自动搜索最优歌词。
 * 第一轮用前 2 个关键词 × 3 源（优先「歌名+歌手」组合）；全空时第二轮换后面的关键词再试。
 */
async function autoSearch(track: Track): Promise<LyricResult | null> {
  const queries: string[] = buildAutoQueries(track);
  if (queries.length === 0) {
    return null;
  }

  const tried: Set<string> = new Set<string>();
  const rounds: number = 2;
  for (let round = 0; round < rounds; round++) {
    // 每轮取未试过的若干关键词，并行搜索
    const batch: string[] = [];
    for (let i = 0; i < queries.length && batch.length < AUTO_QUERY_LIMIT; i++) {
      if (tried.has(queries[i])) {
        continue;
      }
      tried.add(queries[i]);
      batch.push(queries[i]);
    }
    if (batch.length === 0) {
      break;
    }

    const perQuery: Promise<LyricCandidate[]>[] = [];
    for (let i = 0; i < batch.length; i++) {
      perQuery.push(searchAllSources(batch[i]));
    }
    const groups: LyricCandidate[][] = await Promise.all(perQuery);
    const merged: LyricCandidate[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < groups.length; i++) {
      for (let k = 0; k < groups[i].length; k++) {
        const c: LyricCandidate = groups[i][k];
        if (seen.has(c.id)) {
          continue;
        }
        seen.add(c.id);
        merged.push(c);
      }
    }
    if (merged.length === 0) {
      continue;
    }

    const ranked: LyricCandidate[] = rankCandidates(merged, track);
    const plausible: LyricCandidate[] = ranked.filter((c: LyricCandidate): boolean => isPlausible(c, track));
    if (plausible.length === 0) {
      continue;
    }

    // Top1 优先取词（2026-10-23 修匹配）：旧实现所有候选一起竞速「先成功者胜」，
    // 排名第 2/3 的错误候选只要响应更快就会抢走最优解。现在分数最高的候选先取，
    // 失败才竞速其余 —— 代价是 Top1 挂掉时多等一轮（有 FETCH_TIMEOUT_MS 兜底），正确率优先。
    let result: LyricResult | null = plausible.length > 0
      ? await fetchCandidateResult(plausible[0])
      : null;
    if (result === null && plausible.length > 1) {
      const restTasks: Promise<LyricResult | null>[] = [];
      for (let i = 1; i < plausible.length; i++) {
        restTasks.push(fetchCandidateResult(plausible[i]));
      }
      result = await raceFirstResult(restTasks);
    }
    if (result !== null) {
      void writeLyricCache(toEntry(track, cacheKeyOf(track), result, false, null));
      console.info(`[Lyric] hit source=${result.source} lines=${result.lines.length}`
        + ` trans=${result.hasTranslation} dynamic=${result.dynamic} track=${track.title}`);
      return result;
    }
  }
  return null;
}

/**
 * 取某曲目的歌词（缓存优先）。
 * 返回 null 表示「确实没有」—— 会写一条 miss 缓存，24h 内不再联网。
 */
export async function getLyricForTrack(track: Track): Promise<LyricResult | null> {
  if (track.id.length === 0) {
    return null;
  }
  const key: string = cacheKeyOf(track);
  const cached: LyricCacheEntry | null = await readLyricCache(track.id);

  if (cached !== null) {
    if (cached.skipped) {
      return null;
    }
    if (cached.status === LYRIC_CACHE_OK && cached.result !== null) {
      // 手动指定过的缓存永远优先（用户的选择 > 算法）
      if (cached.manual || cached.cacheKey === key) {
        return cached.result;
      }
      // 信息变了（时长补全 / 标题修正）：允许重搜，但先保留旧结果作为兜底
    }
    if (cached.manual && cached.candidateSource.length > 0 && cached.candidateRemoteId.length > 0) {
      const manualCand: LyricCandidate = {
        id: `${cached.candidateSource}:${cached.candidateRemoteId}`,
        songId: cached.candidateRemoteId,
        mid: '',
        trackName: track.title,
        artistName: track.artist,
        albumName: '',
        duration: track.duration,
        image: '',
        source: cached.candidateSource,
        remoteId: cached.candidateRemoteId
      };
      const manualResult: LyricResult | null = await fetchCandidateResult(manualCand);
      if (manualResult !== null) {
        void writeLyricCache(toEntry(track, key, manualResult, true, manualCand));
        return manualResult;
      }
    }
    if (cached.cacheKey === key && isMissFresh(cached)) {
      return null;
    }
  }

  const result: LyricResult | null = await autoSearch(track);
  if (result !== null) {
    return result;
  }

  // 旧结果兜底：这次没搜到，但之前搜到过且信息没变太多 → 继续用旧的，别让歌词突然消失
  if (cached !== null && cached.status === LYRIC_CACHE_OK && cached.result !== null) {
    return cached.result;
  }
  void writeLyricCache(toEntry(track, key, null, false, null));
  console.info(`[Lyric] miss track=${track.title} artist=${track.artist}`);
  return null;
}

/** 手动搜索候选（三源合并，最多 20 条） */
export async function searchLyricCandidates(query: string): Promise<LyricCandidate[]> {
  const q: string = cleanTitle(query.trim());
  const keyword: string = q.length > 0 ? q : query.trim();
  if (keyword.length === 0) {
    return [];
  }
  const merged: LyricCandidate[] = await searchAllSources(keyword);
  if (merged.length <= 20) {
    return merged;
  }
  return merged.slice(0, 20);
}

/**
 * 用户手动选定某个候选 → 取歌词、写 manual 缓存。
 * manual 缓存的语义：以后**自动搜索不会覆盖它**（只认用户的选择），
 * 直到用户再次手动选择或清理缓存。
 */
export async function chooseLyricCandidate(
  track: Track,
  record: LyricCandidate
): Promise<LyricResult | null> {
  const result: LyricResult | null = await fetchCandidateResult(record);
  if (result === null) {
    return null;
  }
  await writeLyricCache(toEntry(track, cacheKeyOf(track), result, true, record));
  return result;
}

/** 用户主动跳过这首歌的歌词（不再自动搜；手动选择 / 清缓存可解除） */
export async function skipLyricForTrack(track: Track): Promise<void> {
  const entry: LyricCacheEntry = {
    trackId: track.id,
    cacheKey: cacheKeyOf(track),
    status: LYRIC_CACHE_MISS,
    updatedAt: Date.now(),
    manual: false,
    skipped: true,
    candidateSource: '',
    candidateRemoteId: '',
    result: null
  };
  await writeLyricCache(entry);
}

/** 清掉某曲目的缓存（下次进播放页会重新搜）。同步删除，避免「删完立刻读还读到旧值」 */
export function clearLyricCache(trackId: string): void {
  deleteLyricCache(trackId);
}

/** 命名空间导出：供 `import { LyricsApi }` 以对象方式调用。 */
export const LyricsApi = {
  getLyricForTrack,
  searchLyricCandidates,
  chooseLyricCandidate,
  skipLyricForTrack,
  clearLyricCache,
  getLyricOffset,
  setLyricOffset
};

/** 供 UI 显示用的源名称 */
export function sourceLabel(source: string | undefined): string {
  if (source === SOURCE_NETEASE) {
    return '网易云';
  }
  if (source === SOURCE_QQ) {
    return 'QQ 音乐';
  }
  if (source === SOURCE_OIAPI) {
    return 'QQ 音乐（代理）';
  }
  return '';
}
