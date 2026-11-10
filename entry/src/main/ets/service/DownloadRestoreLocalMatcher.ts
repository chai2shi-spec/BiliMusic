/**
 * 下载恢复的「本地身份索引」——联网补全之前的离线匹配层（**纯只读**）。
 *
 * 用户口径的优先级：
 *   ① 随行 sidecar（DownloadRestoreScanner 里处理，含 bvid#cid，最精确）
 *   ② **已下载的歌曲 / 本机曲库**：现有 download_task、歌单、最近播放、收藏
 *      —— Track.id 就是 musicId 口径（分 P 为 bvid#cid），能补回 cid；
 *   ③ **拾音（听歌日记）会话**：PlaySession 带 bvid / 标题 / 歌手 / 封面，
 *      但没有 cid；重装后只要云同步下发过 listen_log 分片就离线可用；
 *   ④ 联网按标题搜索（最慢、会被风控、且会把歌名换成 B 站视频标题）。
 *
 * 为什么单独一层：上一版 25 首旧音频全部走联网，标题被换成视频标题、
 * 分 P 的 cid 全丢，还要吃 412 退避。本机已有的身份信息必须先用完。
 *
 * ⚠️ 只读：不写 Preferences、不写 RDB、不写公共目录、不发任何网络请求。
 *    读歌单元信息一律用现成的 getPlaylists()/LibraryStore getter（内存缓存真源），
 *    读不到分片时只是候选变少，绝不能因此触发任何写回。
 */

import { DownloadTask, Playlist, Track } from '../model/MusicModels';
import { PlaySession, querySessions } from './PlaySessionStore';
import { LibraryStore, getPlaylists } from './LibraryStore';
import { cleanTitle } from '../utils/TextUtil';

/** 身份来源（预览页 reason 会用中文展示） */
export enum LocalIdentityOrigin {
  /** 现有 download_task 记录 */
  DOWNLOAD = 'download',
  /** 歌单 / 最近播放 / 收藏 */
  LIBRARY = 'library',
  /** 拾音（听歌会话日志） */
  SESSION = 'session'
}

/** 一条可用于还原下载记录的本地身份 */
export interface LocalIdentity {
  /** bvid 或 bvid#cid，写回 download_task 的主键口径 */
  musicId: string;
  bvid: string;
  cid: string;
  title: string;
  artist: string;
  coverUrl: string;
  /** 秒 */
  duration: number;
  audioQuality: number;
  collectionTitle: string;
  partNo: number;
  partTotal: number;
  completedAt: number;
  origin: LocalIdentityOrigin;
  /** 3 = 已下载/曲库，2 = 拾音；同分时高优先级胜出 */
  priority: number;
}

/** exact 索引 + 全量数组（模糊匹配兜底） */
export interface LocalIdentityIndex {
  all: LocalIdentity[];
  byTitle: Map<string, LocalIdentity[]>;
}

export interface LocalMatchResult {
  identity: LocalIdentity;
  score: number;
  /** 已认领的归一化标题键：同一首歌只认领一次，避免同曲不同 id 被多个文件重复占用 */
  titleKey: string;
}

/** 归一化：去空白/全角空格/标点、去 cleanTitle 噪音词、小写（Scanner 打分同源） */
export function normalizeIdentity(s: string): string {
  return cleanTitle(s)
    .replace(/[\s\u3000]/g, '')
    .replace(/[·•_—\-—|｜\[\]【】()（）<>《》"'`]/g, '')
    .toLowerCase();
}

/** 0~1 相似度：相等 1 / 互相包含按短长比 / 否则 bigram Jaccard */
export function identitySimilarity(a: string, b: string): number {
  const x: string = normalizeIdentity(a);
  const y: string = normalizeIdentity(b);
  if (x.length === 0 || y.length === 0) {
    return 0;
  }
  if (x === y) {
    return 1;
  }
  const shortLen: number = Math.min(x.length, y.length);
  const longLen: number = Math.max(x.length, y.length);
  if (x.indexOf(y) >= 0 || y.indexOf(x) >= 0) {
    return 0.8 + 0.2 * (shortLen / longLen);
  }
  // 用数组 + indexOf 去重，避免在 Map/Set.forEach 闭包里改外部标量（ArkTS 严格）
  const grams: string[] = [];
  for (let i = 0; i + 1 < x.length; i++) {
    const g: string = x.substring(i, i + 2);
    if (grams.indexOf(g) < 0) {
      grams.push(g);
    }
  }
  if (grams.length === 0) {
    return 0;
  }
  const other: string[] = [];
  for (let i = 0; i + 1 < y.length; i++) {
    const g: string = y.substring(i, i + 2);
    if (other.indexOf(g) < 0) {
      other.push(g);
    }
  }
  let hit: number = 0;
  for (let i = 0; i < other.length; i++) {
    if (grams.indexOf(other[i]) >= 0) {
      hit++;
    }
  }
  return hit / Math.max(grams.length, other.length);
}

/** musicId → bvid / cid（与 DownloadIndex.splitMusicId 同口径） */
function splitMusicId(musicId: string): string[] {
  const sharp: number = musicId.indexOf('#');
  if (sharp > 0) {
    return [musicId.substring(0, sharp), musicId.substring(sharp + 1)];
  }
  return [musicId, ''];
}

function isUsableId(id: string): boolean {
  return id.length > 0 && id.indexOf('local_') !== 0;
}

function fromTask(t: DownloadTask): LocalIdentity | null {
  if (!isUsableId(t.musicId) || t.title.length === 0) {
    return null;
  }
  const parts: string[] = splitMusicId(t.musicId);
  return {
    musicId: t.musicId,
    bvid: parts[0],
    cid: parts[1],
    title: t.title,
    artist: t.artist,
    coverUrl: t.coverUrl,
    duration: 0,
    audioQuality: t.audioQuality,
    collectionTitle: t.collectionTitle,
    partNo: t.partNo,
    partTotal: t.partTotal,
    completedAt: t.completedAt,
    origin: LocalIdentityOrigin.DOWNLOAD,
    priority: 3
  };
}

function fromTrack(t: Track, origin: LocalIdentityOrigin): LocalIdentity | null {
  const id: string = t.id.length > 0 ? t.id : t.bvid;
  if (!isUsableId(id) || t.title.length === 0) {
    return null;
  }
  const parts: string[] = splitMusicId(id);
  return {
    musicId: id,
    bvid: parts[0],
    cid: parts[1].length > 0 ? parts[1] : t.cid,
    title: t.title,
    artist: t.artist,
    coverUrl: t.coverUrl,
    duration: t.duration,
    audioQuality: 0,
    collectionTitle: '',
    partNo: 0,
    partTotal: 0,
    completedAt: t.playedAt > 0 ? t.playedAt : 0,
    origin: origin,
    priority: 3
  };
}

/**
 * 拾音会话 → 身份。trackId 是 Track.id（分 P 可能含 #cid），比 bvid 更精确，
 * 所以优先用 trackId；纯 bvid 时才退回 s.bvid。
 */
function fromSession(s: PlaySession): LocalIdentity | null {
  const id: string = isUsableId(s.trackId) && s.trackId.indexOf('#') > 0
    ? s.trackId : s.bvid;
  if (!isUsableId(id) || s.title.length === 0) {
    return null;
  }
  const parts: string[] = splitMusicId(id);
  return {
    musicId: id,
    bvid: parts[0],
    cid: parts[1],
    title: s.title,
    artist: s.artist,
    coverUrl: s.coverUrl,
    duration: s.durationMs > 0 ? Math.round(s.durationMs / 1000) : 0,
    audioQuality: 0,
    collectionTitle: '',
    partNo: 0,
    partTotal: 0,
    completedAt: s.startedAt,
    origin: LocalIdentityOrigin.SESSION,
    priority: 2
  };
}

/**
 * 建索引：按 musicId 去重，同源重复（一首歌听 30 次）只留一条，
 * 且「已下载/曲库」优先级高于「拾音」。同优先级保留信息更全的那条。
 */
export async function buildLocalIdentityIndex(
  existing: DownloadTask[]
): Promise<LocalIdentityIndex> {
  const byId: Map<string, LocalIdentity> = new Map<string, LocalIdentity>();
  const add = (candidate: LocalIdentity | null): void => {
    if (candidate === null) {
      return;
    }
    const prev: LocalIdentity | undefined = byId.get(candidate.musicId);
    if (prev === undefined || candidate.priority > prev.priority) {
      byId.set(candidate.musicId, candidate);
      return;
    }
    if (candidate.priority === prev.priority
      && candidate.cid.length > prev.cid.length && prev.cid.length === 0) {
      byId.set(candidate.musicId, candidate);
    }
  };

  // ① 已下载的歌曲（现有下载任务）
  for (let i = 0; i < existing.length; i++) {
    add(fromTask(existing[i]));
  }
  // ② 本机曲库：歌单 / 最近播放 / 收藏。分片未装载时 tracks 为空 → 只是少候选，不写回。
  try {
    const playlists: Playlist[] = getPlaylists();
    for (let p = 0; p < playlists.length; p++) {
      const tracks: Track[] = playlists[p].tracks;
      for (let t = 0; t < tracks.length; t++) {
        add(fromTrack(tracks[t], LocalIdentityOrigin.LIBRARY));
      }
    }
    const recent: Track[] = LibraryStore.getRecentTracks();
    for (let t = 0; t < recent.length; t++) {
      add(fromTrack(recent[t], LocalIdentityOrigin.LIBRARY));
    }
    const favorites: Track[] = LibraryStore.getFavoriteTracks();
    for (let t = 0; t < favorites.length; t++) {
      add(fromTrack(favorites[t], LocalIdentityOrigin.LIBRARY));
    }
  } catch (e) {
    // 曲库读取失败不允许中断恢复：后面还有拾音与联网两层
    console.warn(`[RestoreLocal] library read failed: ${e instanceof Error ? e.message : ''}`);
  }
  // ③ 拾音会话（13 个月保留窗；querySessions 内部钳位，未 init 返回空）
  try {
    const sessions: PlaySession[] = await querySessions(0, Date.now());
    for (let i = 0; i < sessions.length; i++) {
      add(fromSession(sessions[i]));
    }
  } catch (e) {
    console.warn(`[RestoreLocal] session read failed: ${e instanceof Error ? e.message : ''}`);
  }

  const all: LocalIdentity[] = [];
  const byTitle: Map<string, LocalIdentity[]> = new Map<string, LocalIdentity[]>();
  byId.forEach((identity: LocalIdentity): void => {
    all.push(identity);
    const key: string = normalizeIdentity(identity.title);
    if (key.length === 0) {
      return;
    }
    const bucket: LocalIdentity[] | undefined = byTitle.get(key);
    if (bucket === undefined) {
      byTitle.set(key, [identity]);
    } else {
      bucket.push(identity);
    }
  });
  return { all: all, byTitle: byTitle };
}

/**
 * 候选打分：标题为主、歌手为辅；来源优先级与 cid 完整度做小幅加成。
 * -1 = 已被别的文件认领 / 歌手明显不符，调用方直接跳过。
 * 刻意写成纯函数：不在闭包里改外部标量（ArkTS 严格模式踩过坑）。
 */
function scoreOf(
  artist: string,
  candidate: LocalIdentity,
  titleScore: number,
  claimedIds: Set<string>,
  claimedTitles: Set<string>
): number {
  if (claimedIds.has(candidate.musicId)
    || claimedTitles.has(normalizeIdentity(candidate.title))) {
    return -1;
  }
  let artistScore: number = 0.5;
  if (artist.length > 0 && candidate.artist.length > 0) {
    artistScore = identitySimilarity(artist, candidate.artist);
    // 双方都有歌手却明显不符 → 直接否决，避免「同名不同唱」张冠李戴
    if (artistScore < 0.4) {
      return -1;
    }
  }
  return titleScore * 0.8 + artistScore * 0.2
    + (candidate.priority >= 3 ? 0.12 : 0.06)
    + (candidate.cid.length > 0 ? 0.02 : 0);
}

/**
 * 为一个文件名找本地身份：先归一化标题精确查表（O(1)，绝大多数命中），
 * 查不到再对全量做严格相似度兜底（≥ 0.82，比联网的 0.6 严得多 ——
 * 本机身份一旦认错，写进 download_task 就是错的 musicId）。
 */
export function findLocalMatch(
  index: LocalIdentityIndex,
  title: string,
  artist: string,
  claimedIds: Set<string>,
  claimedTitles: Set<string>
): LocalMatchResult | null {
  const key: string = normalizeIdentity(title);
  if (key.length === 0) {
    return null;
  }
  let best: LocalIdentity | null = null;
  let bestScore: number = 0;
  const exact: LocalIdentity[] | undefined = index.byTitle.get(key);
  if (exact !== undefined) {
    for (let i = 0; i < exact.length; i++) {
      const candidate: LocalIdentity = exact[i];
      const score: number = scoreOf(artist, candidate, 1, claimedIds, claimedTitles);
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
  }
  if (best === null) {
    for (let i = 0; i < index.all.length; i++) {
      const candidate: LocalIdentity = index.all[i];
      const titleScore: number = identitySimilarity(title, candidate.title);
      if (titleScore < 0.82) {
        continue;
      }
      const score: number = scoreOf(artist, candidate, titleScore, claimedIds, claimedTitles);
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
  }
  if (best === null) {
    return null;
  }
  const found: LocalIdentity = best;
  return {
    identity: found,
    score: bestScore,
    titleKey: normalizeIdentity(found.title)
  };
}
