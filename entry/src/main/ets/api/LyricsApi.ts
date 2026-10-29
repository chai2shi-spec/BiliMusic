/**
 * 歌词服务（多源竞速版，lx-music 链路）。
 *
 * 设计：
 *   1. **五个源并行竞速**：wy（网易云）/ tx（QQ）/ kg（酷狗）/ kw（酷我）/ mg（咪咕），
 *      搜索层与取词层整体移植自 lx-music-mobile（`api/lyricSdk/`），
 *      统一输出 LX 四轨（lyric / tlyric / rlyric / lxlyric），
 *      由 `lyric/LxLyricParser` 归一化成 `LyricLine[]`。
 *   2. **候选打分**：沿用 `TextUtil.scoreCandidate`（标题包含 / 歌手命中 /
 *      时长分档 / 伴奏·翻唱降权），从五源合并后的候选里挑最优；
 *      自动搜索失败时还有第二轮「换关键词重搜」。
 *   3. **缓存走文件**：见 `service/LyricCacheStore.ts`（Preferences 单值有
 *      8192 字节上限，超限会静默失败）。
 *   4. **B 站字幕兜底**：外部曲库全链落空时读视频 CC / AI 字幕当逐行 LRC
 *      （自动链路内置）；长按面板可手动指定（`chooseBiliSubtitle`）。
 *   5. **用户可控**：手动指定候选（`chooseLyricCandidate`）、跳过（`skipLyricForTrack`）、
 *      整体偏移（`getLyricOffset` / `setLyricOffset`，单位 ms）。
 *
 * 失败语义：整个链路任何一种失败都返回 null（不抛错），由 UI 显示「暂无歌词」。
 */

import { AppPreferences } from '../preferences/AppPreferences';
import {
  artistSegments,
  cleanTitle,
  queryCandidates,
  scoreCandidate,
  ScoreContext
} from '../utils/TextUtil';
import { LyricCandidate, LyricResult, Track } from '../model/MusicModels';
import { parseLxLyric, ParsedLyricTrack } from '../lyric/LxLyricParser';
import { fetchLxLyric, searchLxSource } from './lyricSdk/LyricSdk';
import {
  LxLyricFetchInput,
  LxLyricInfo,
  LxSongCandidate,
  SOURCE_KG,
  SOURCE_KW,
  SOURCE_MG,
  SOURCE_TX,
  SOURCE_WY
} from './lyricSdk/LxLyricTypes';
import {
  fetchSubtitleOutcome,
  fetchSubtitleChoices,
  fetchSubtitleByChoice,
  probeBiliSubtitleAvailability,
  SOURCE_BILI_AI,
  SOURCE_BILI_CC,
  SUBTITLE_KIND_AUTO,
  SubtitleOutcome,
  SubtitleChoice,
  SubtitleChoicesOutcome
} from './SubtitleLyricApi';
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
/** 自动搜索用到的关键词个数（每个关键词 × 5 源；2 个 = 最多 10 次搜索请求） */
const AUTO_QUERY_LIMIT: number = 2;
/** 每源每次搜索取多少候选 */
const SEARCH_LIMIT: number = 10;
/** 并行尝试取歌词的候选个数（先成功者胜，其余结果丢弃） */
const FETCH_RACE_WIDTH: number = 2;
/** 候选打分低于此值且标题互不包含 → 判为「不是同一首歌」 */
const MIN_ACCEPT_SCORE: number = 120;
/** 单源搜索超时（ms）：任何一个源卡住都不该拖累整首歌的歌词搜索 */
const SEARCH_TIMEOUT_MS: number = 5000;
/** 单次取歌词超时（ms）：竞速里全卡住时不能无限等 */
const FETCH_TIMEOUT_MS: number = 6000;

// ──────────────────── 字幕瞬时失败内存节流（F2b） ────────────────────

/**
 * 字幕链瞬时失败（超时 / 网络 / 风控）后的重试闸门：trackId → 上次尝试时刻。
 * 不进 Preferences、不落盘 —— 进程重启自然清零，瞬时失败重试一次的代价本来就低。
 */
const subtitleRetryGate: Map<string, number> = new Map<string, number>();
/** 瞬时失败后 10 分钟内不再尝试字幕链（期间命中节流时不发任何网络请求） */
const SUBTITLE_RETRY_GATE_MS: number = 10 * 60 * 1000;
/** 节流表条目上限：超过时清掉最早写入的一半，防长会话膨胀 */
const SUBTITLE_GATE_MAX: number = 200;

/** 节流表裁剪用的临时记录 */
interface GateRecord {
  key: string;
  at: number;
}

/** 节流表超限时清掉最早写入的一半（按尝试时刻排序） */
function trimSubtitleGate(): void {
  const records: GateRecord[] = [];
  subtitleRetryGate.forEach((at: number, key: string): void => {
    records.push({ key: key, at: at });
  });
  records.sort((a: GateRecord, b: GateRecord): number => a.at - b.at);
  const dropCount: number = Math.floor(records.length / 2);
  for (let i = 0; i < dropCount; i++) {
    subtitleRetryGate.delete(records[i].key);
  }
}

/** 字幕链是否被瞬时失败节流闸住（闸住 = 本次直接跳过字幕环，不写 miss） */
function isSubtitleGated(trackId: string): boolean {
  const lastTry: number | undefined = subtitleRetryGate.get(trackId);
  if (lastTry === undefined) {
    return false;
  }
  return Date.now() - lastTry < SUBTITLE_RETRY_GATE_MS;
}

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
function setLyricOffset(trackId: string, offsetMs: number): void {
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
function searchSafely(source: string, keyword: string): Promise<LxSongCandidate[]> {
  return new Promise<LxSongCandidate[]>((resolve: (v: LxSongCandidate[]) => void): void => {
    let settled: boolean = false;
    const timer: number = setTimeout((): void => {
      if (settled) {
        return;
      }
      settled = true;
      resolve([]);
    }, SEARCH_TIMEOUT_MS);
    searchLxSource(source, keyword, SEARCH_LIMIT)
      .then((rows: LxSongCandidate[]): void => {
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

function toCandidate(raw: LxSongCandidate): LyricCandidate {
  const cand: LyricCandidate = {
    id: `${raw.source}:${raw.remoteId}`,
    songId: raw.remoteId,
    mid: '',
    trackName: raw.title,
    artistName: raw.artist,
    albumName: raw.album,
    duration: raw.duration,
    image: '',
    source: raw.source,
    remoteId: raw.remoteId
  };
  return cand;
}

/** 五源并行搜索指定关键词，合并去重 */
async function searchAllSources(keyword: string): Promise<LyricCandidate[]> {
  const sources: string[] = [SOURCE_WY, SOURCE_TX, SOURCE_KG, SOURCE_KW, SOURCE_MG];
  const tasks: Promise<LxSongCandidate[]>[] = [];
  for (let i = 0; i < sources.length; i++) {
    tasks.push(searchSafely(sources[i], keyword));
  }
  const results: LxSongCandidate[][] = await Promise.all(tasks);
  const out: LyricCandidate[] = [];
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < results.length; i++) {
    const rows: LxSongCandidate[] = results[i];
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

function toLyricResult(candidate: LyricCandidate, info: LxLyricInfo): LyricResult | null {
  const parsed: ParsedLyricTrack | null = parseLxLyric(info);
  if (parsed === null || parsed.lines.length === 0) {
    return null;
  }
  const result: LyricResult = {
    lines: parsed.lines,
    synced: parsed.synced,
    instrumental: false,
    trackName: candidate.trackName,
    artistName: candidate.artistName,
    sourceId: candidate.remoteId === undefined ? String(candidate.songId) : candidate.remoteId,
    source: candidate.source,
    hasTranslation: parsed.hasTranslation,
    dynamic: parsed.dynamic
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
    const input: LxLyricFetchInput = {
      remoteId: remoteId,
      title: candidate.trackName,
      artist: candidate.artistName,
      duration: candidate.duration
    };
    fetchLxLyric(source, input)
      .then((info: LxLyricInfo | null): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        if (info === null) {
          resolve(null);
          return;
        }
        resolve(toLyricResult(candidate, info));
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
  // 键带 v2 版本前缀（歌手参与搜索与打分、Top1 优先取词）：键格式变化
  // 会让存量自动缓存整体重搜一次；manual 缓存永远优先不受影响，
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
 * 只用标题搜词时同名曲 / 翻唱 / 伴奏极易误中，所以第一优先级是
 * 「标题关键词 + track.artist 首段」的组合词 —— artist 可能是 UP 主名
 * （不是真实歌手），所以组合词排前面、仅歌名关键词跟在后面：
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
 * 第一轮用前 2 个关键词 × 5 源（优先「歌名+歌手」组合）；全空时第二轮换后面的关键词再试。
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

    // Top1 优先取词：分数最高的候选先取，失败才竞速其余 ——
    // 全员竞速「先成功者胜」会让排名第 2/3 的错误候选靠响应更快抢走最优解；
    // 代价是 Top1 挂掉时多等一轮（有 FETCH_TIMEOUT_MS 兜底），正确率优先。
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

/** 实际取词链路（被 getLyricForTrack 的在途去重壳包住） */
async function getLyricForTrackInner(track: Track): Promise<LyricResult | null> {
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

  // B 站字幕兜底：外部曲库全链落空（VOCALOID 原创 / 二次创作 / 电台片段这类
  // 搜不到的歌）时，读视频 CC / AI 字幕当逐行 LRC —— 时间轴与音轨天然对齐。
  // 失败分级（F2b）：只有结论性失败（definitive，视频确实没字幕）才写 24h miss；
  // 瞬时失败（超时 / 网络 / 风控）不写 miss —— 那些被钉 24h 是错误的 ——
  // 改走 10 分钟内存节流，期间跳过字幕环但不产生任何缓存。
  if (isSubtitleGated(track.id)) {
    return null;
  }
  const subtitle: SubtitleOutcome = await fetchSubtitleOutcome(track, SUBTITLE_KIND_AUTO);
  if (subtitle.result !== null) {
    void writeLyricCache(toEntry(track, key, subtitle.result, false, null));
    return subtitle.result;
  }
  if (subtitle.definitive) {
    void writeLyricCache(toEntry(track, key, null, false, null));
    console.info(`[Lyric] miss track=${track.title} artist=${track.artist} reason=${subtitle.reason}`);
    return null;
  }
  subtitleRetryGate.set(track.id, Date.now());
  if (subtitleRetryGate.size > SUBTITLE_GATE_MAX) {
    trimSubtitleGate();
  }
  console.info(`[Lyric] subtitle transient skip miss reason=${subtitle.reason} track=${track.title}`);
  return null;
}

/**
 * 在途请求去重表：播放页（LyricsComponent）/ 桌面卡片 / AVSession 歌词补报
 * 同刻调用同一曲目时共享一次网络链（track.id 为键），避免五源搜索被并发
 * 重复触发、多倍请求抢占音频首包带宽。
 */
const inflightLyricFetches: Map<string, Promise<LyricResult | null>> = new Map();

/**
 * 取某曲目的歌词（缓存优先）。
 * 返回 null 表示「确实没有」—— 会写一条 miss 缓存，24h 内不再联网。
 * 并发去重：同曲目在途请求未完成时，后到调用方直接复用同一次请求结果
 * （首个调用者的曲目信息决定本次搜索口径，实践上是信息最全的播放链）。
 */
export function getLyricForTrack(track: Track): Promise<LyricResult | null> {
  const existing: Promise<LyricResult | null> | undefined = inflightLyricFetches.get(track.id);
  if (existing !== undefined) {
    return existing;
  }
  const task: Promise<LyricResult | null> = getLyricForTrackInner(track).finally((): void => {
    inflightLyricFetches.delete(track.id);
  });
  inflightLyricFetches.set(track.id, task);
  return task;
}

/** 手动搜索候选（五源合并，最多 20 条） */
async function searchLyricCandidates(query: string): Promise<LyricCandidate[]> {
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
async function chooseLyricCandidate(
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

/**
 * 手动改用 B 站字幕（长按面板入口），带失败分级。
 * kind：`SUBTITLE_KIND_CC`（人工字幕）/ `SUBTITLE_KIND_AI`（AI 字幕）——
 * 用户可强制指定用哪种；与自动链路的字幕兜底同一取数（`fetchSubtitleOutcome`），
 * 但命中后写 **manual** 缓存 —— 用户的选择优先于自动搜索，直到再次手动选择或清缓存。
 * 失败时返回 SubtitleOutcome（不写缓存），由 UI 按 reason / 登录态分型提示。
 */
async function chooseBiliSubtitleOutcome(track: Track, kind: string): Promise<SubtitleOutcome> {
  const outcome: SubtitleOutcome = await fetchSubtitleOutcome(track, kind);
  if (outcome.result !== null) {
    await writeLyricCache(toEntry(track, cacheKeyOf(track), outcome.result, true, null));
  }
  return outcome;
}

/** 旧签名兼容入口：只取 result（命中写 manual 缓存的语义不变），避免动其它调用点 */
async function chooseBiliSubtitle(track: Track, kind: string): Promise<LyricResult | null> {
  const outcome: SubtitleOutcome = await chooseBiliSubtitleOutcome(track, kind);
  return outcome.result;
}

/**
 * 列出某曲目可手动选择的 B 站字幕（长按面板 CC / AI 按钮的取列表入口）。
 * 单候选时 UI 直接应用（保持一步到位）；多候选时展示列表让用户挑 ——
 * 多字幕视频上自动选优不确定（智能字幕内容不稳定），明确选择才确定。
 * 失败时返回带 reason 的空列表，由 UI 按登录态 / definitive / 瞬时分型提示。
 */
async function listBiliSubtitleChoices(
  track: Track,
  kind: string
): Promise<SubtitleChoicesOutcome> {
  return await fetchSubtitleChoices(track, kind);
}

/**
 * 手动选定某个 B 站字幕条目 → 取字幕、写 manual 缓存。
 * manual 缓存语义同 chooseBiliSubtitleOutcome：用户的选择优先于自动搜索，
 * 直到再次手动选择或清缓存。
 */
async function chooseBiliSubtitleItem(
  track: Track,
  choice: SubtitleChoice
): Promise<SubtitleOutcome> {
  const outcome: SubtitleOutcome = await fetchSubtitleByChoice(track, choice);
  if (outcome.result !== null) {
    await writeLyricCache(toEntry(track, cacheKeyOf(track), outcome.result, true, null));
  }
  return outcome;
}

/**
 * 后台补全用：只把（已确认更优的）B 站字幕结果落 manual 缓存，不带网络取数。
 * 与 chooseBiliSubtitleItem 的区别：补全流程先纯取数比对（fetchSubtitleByChoice），
 * 行数增长才写缓存 —— 生成中的内容每次行数乱跳，无条件写会把缓存反复覆盖成
 * 更差的半截快照。
 */
async function saveBiliSubtitleChoice(track: Track, result: LyricResult): Promise<void> {
  await writeLyricCache(toEntry(track, cacheKeyOf(track), result, true, null));
}

/** 用户主动跳过这首歌的歌词（不再自动搜；手动选择 / 清缓存可解除） */
async function skipLyricForTrack(track: Track): Promise<void> {
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
function clearLyricCache(trackId: string): void {
  deleteLyricCache(trackId);
}

/** 命名空间导出：供 `import { LyricsApi }` 以对象方式调用。 */
export const LyricsApi = {
  getLyricForTrack,
  searchLyricCandidates,
  chooseLyricCandidate,
  chooseBiliSubtitle,
  chooseBiliSubtitleOutcome,
  listBiliSubtitleChoices,
  chooseBiliSubtitleItem,
  fetchSubtitleByChoice,
  saveBiliSubtitleChoice,
  skipLyricForTrack,
  clearLyricCache,
  getLyricOffset,
  setLyricOffset,
  probeBiliSubtitleAvailability
};

/** 供 UI 显示用的源名称 */
export function sourceLabel(source: string | undefined): string {
  if (source === undefined || source.length === 0) {
    return '';
  }
  // lx 五源
  if (source === SOURCE_WY) {
    return '网易云';
  }
  if (source === SOURCE_TX) {
    return 'QQ音乐';
  }
  if (source === SOURCE_KG) {
    return '酷狗';
  }
  if (source === SOURCE_KW) {
    return '酷我';
  }
  if (source === SOURCE_MG) {
    return '咪咕';
  }
  // 旧缓存里的历史源标识
  if (source === 'netease') {
    return '网易云';
  }
  if (source === 'qq') {
    return 'QQ音乐';
  }
  if (source === 'oiapi') {
    return 'QQ音乐（代理）';
  }
  // B 站字幕
  if (source === SOURCE_BILI_CC) {
    return 'B站字幕';
  }
  if (source === SOURCE_BILI_AI) {
    return 'B站AI字幕';
  }
  return '';
}
