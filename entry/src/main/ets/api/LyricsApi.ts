/**
 * 歌词服务（原生 ArkTS 版）。
 * 数据源：OIAPI QQ Music Lyric。流程：B 站标题清洗 → 候选评分 → LRC 解析 → 缓存 → 手动纠正。
 * 移植自原 React 版 src/services/lyrics.ts（移除 window/electron 依赖，统一走 HttpUtil）。
 */

import { HttpUtil } from '../utils/HttpUtil';
import { AppPreferences } from '../preferences/AppPreferences';
import {
  parseLrc,
  plainToLines,
  queryCandidates,
  scoreCandidate,
  cleanTitle,
  ScoreContext
} from '../utils/TextUtil';
import { OIAPI_QQ_LYRIC } from '../common/Constants';
import { LyricCandidate, LyricResult, Track } from '../model/MusicModels';

interface OiapiSong {
  name: string;
  singer: string[];
  album: string;
  mid: string;
  id: string | number;
  duration: number;
  image: string;
}

interface OiapiLyricData {
  content?: string;
  conteng?: string;
  base64?: string;
}

type CacheEntry =
  | { status: 'ok'; result: LyricResult }
  | { status: 'miss'; ts: number };

const CACHE_KEY: string = 'bilimusic_lyrics_v2';
const MISS_TTL: number = 24 * 60 * 60 * 1000;

function readCache(): Record<string, CacheEntry> {
  return AppPreferences.getObject<Record<string, CacheEntry>>(CACHE_KEY) ?? {};
}

function writeCache(map: Record<string, CacheEntry>): void {
  AppPreferences.setObject<Record<string, CacheEntry>>(CACHE_KEY, map);
}

function cacheOk(trackId: string, result: LyricResult): void {
  const map: Record<string, CacheEntry> = readCache();
  map[trackId] = { status: 'ok', result: result };
  writeCache(map);
}

function cacheMiss(trackId: string): void {
  const map: Record<string, CacheEntry> = readCache();
  map[trackId] = { status: 'miss', ts: Date.now() };
  writeCache(map);
}

async function oiSearch(keyword: string, limit: number = 10): Promise<LyricCandidate[]> {
  const url: string =
    `${OIAPI_QQ_LYRIC}?keyword=${encodeURIComponent(keyword)}&page=1&limit=${limit}&type=json`;
  try {
    const json = await HttpUtil.requestJson<{ code: number; data?: OiapiSong[] }>(url);
    const list: OiapiSong[] | undefined = json?.data;
    if (!Array.isArray(list)) {
      return [];
    }
    const out: LyricCandidate[] = [];
    for (let i = 0; i < list.length; i++) {
      const item: OiapiSong = list[i];
      if (!item?.name || !item.id) {
        continue;
      }
      out.push({
        id: String(item.id),
        songId: item.id,
        mid: item.mid || '',
        trackName: item.name || '',
        artistName: Array.isArray(item.singer) ? item.singer.join(' / ') : '',
        albumName: item.album || '',
        duration: Number(item.duration) || 0,
        image: item.image || ''
      });
    }
    return out;
  } catch (e) {
    return [];
  }
}

async function oiGetLyric(id: string | number): Promise<string> {
  const url: string = `${OIAPI_QQ_LYRIC}?id=${encodeURIComponent(String(id))}&format=lrc&type=json`;
  try {
    const json = await HttpUtil.requestJson<{ code: number; data?: OiapiLyricData; message?: string }>(url);
    if (!json || json.code !== 1 || !json.data) {
      return '';
    }
    const d: OiapiLyricData = json.data;
    return d.content || d.conteng || '';
  } catch (e) {
    return '';
  }
}

function lyricToResult(candidate: LyricCandidate, content: string): LyricResult | null {
  const syncedLines = parseLrc(content);
  const lines = syncedLines.length > 0 ? syncedLines : plainToLines(content);
  if (lines.length === 0) {
    return null;
  }
  return {
    lines: lines,
    synced: syncedLines.length > 0,
    instrumental: false,
    trackName: candidate.trackName,
    artistName: candidate.artistName,
    sourceId: String(candidate.songId)
  };
}

async function searchBestCandidate(track: Track): Promise<LyricCandidate | null> {
  const queries: string[] = queryCandidates(track.title);
  if (queries.length === 0) {
    return null;
  }

  const seen: Map<string, LyricCandidate> = new Map<string, LyricCandidate>();
  for (let i = 0; i < queries.length; i++) {
    const rows: LyricCandidate[] = await oiSearch(queries[i], 10);
    for (let j = 0; j < rows.length; j++) {
      if (!seen.has(rows[j].id)) {
        seen.set(rows[j].id, rows[j]);
      }
    }
    if (seen.size >= 24) {
      break;
    }
  }

  const ctx: ScoreContext = {
    rawTitle: track.title,
    clean: cleanTitle(track.title),
    duration: track.duration || 0,
    quoted: []
  };

  let best: { candidate: LyricCandidate; score: number } | null = null;
  seen.forEach((candidate: LyricCandidate): void => {
    const sc: number = scoreCandidate(candidate, ctx);
    if (!best || sc > best.score) {
      best = { candidate: candidate, score: sc };
    }
  });

  if (!best) {
    return null;
  }
  if (best.score < 120 && ctx.clean.indexOf(best.candidate.trackName) < 0 && best.candidate.trackName.indexOf(ctx.clean) < 0) {
    return null;
  }
  return best.candidate;
}

export async function getLyricForTrack(track: Track): Promise<LyricResult | null> {
  const map: Record<string, CacheEntry> = readCache();
  const entry: CacheEntry | undefined = map[track.id];
  if (entry?.status === 'ok') {
    return entry.result;
  }
  if (entry?.status === 'miss' && Date.now() - entry.ts < MISS_TTL) {
    return null;
  }

  const candidate: LyricCandidate | null = await searchBestCandidate(track);
  if (!candidate) {
    cacheMiss(track.id);
    return null;
  }

  const content: string = await oiGetLyric(candidate.songId);
  const result: LyricResult | null = lyricToResult(candidate, content);
  if (!result) {
    cacheMiss(track.id);
    return null;
  }

  cacheOk(track.id, result);
  return result;
}

export async function searchLyricCandidates(query: string): Promise<LyricCandidate[]> {
  const q: string = cleanTitle(query.trim());
  if (!q) {
    return [];
  }
  return oiSearch(q, 20);
}

export async function chooseLyricCandidate(
  trackId: string,
  record: LyricCandidate
): Promise<LyricResult | null> {
  const content: string = await oiGetLyric(record.songId);
  const result: LyricResult | null = lyricToResult(record, content);
  if (result) {
    cacheOk(trackId, result);
  }
  return result;
}

export function clearLyricCache(trackId: string): void {
  const map: Record<string, CacheEntry> = readCache();
  delete map[trackId];
  writeCache(map);
}

/** 命名空间导出：供 `import { LyricsApi }` 以对象方式调用。 */
export const LyricsApi = {
  getLyricForTrack,
  searchLyricCandidates,
  chooseLyricCandidate,
  clearLyricCache
};
