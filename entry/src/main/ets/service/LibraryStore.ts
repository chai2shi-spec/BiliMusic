/**
 * 媒体库存储（收藏 / 歌单 / 最近播放 / 删除墓碑）。
 * 移植自原 React 版 src/utils/storage.ts，存储后端由 localStorage 改为 Preferences（JSON）。
 */

import { AppPreferences } from '../preferences/AppPreferences';
import { STORE_LIBRARY_REV } from '../common/Constants';
import {
  fitByByteBudget,
  PREF_VALUE_BUDGET_BYTES,
  Playlist,
  slimTrack,
  Tombstone,
  Track,
  utf8Length
} from '../model/MusicModels';

function createId(): string {
  return `pl_${Date.now()}_${Math.floor(Math.random() * 1e9).toString(36)}`;
}

const RECENT_MAX_ITEMS: number = 50;

/**
 * 最近播放内存快照。
 *
 * 两个必须的理由：
 *  1) `AppPreferences.saveRecentTracks` 是异步落盘（put + flush），而读取走同步 `getSync`，
 *     写完立刻读会拿到旧值 —— 表现为「刚播完的歌进「最近播放」看不到」。
 *     与 `playlistCache` 同源问题，处理方式保持一致：缓存即真源，写操作先换缓存再异步落盘。
 *  2) Preferences 单值有 8192 字节上限，50 首带 audioUrl 的曲目序列化后必然超限，
 *     `put()` 抛错 → 记录全部丢失。所以落盘前统一 slimTrack + 按字节预算截断。
 */
let recentCache: Track[] | null = null;

/**
 * 判断一条记录是否可用。
 *
 * 为什么需要：`slimTrack()` 会直接读 `track.id`，列表里只要混进一个 null / 非对象，
 * 整次写入就会抛 TypeError —— 而抛在上面的后果是「一条都存不下来」，
 * 表现是「最近播放永远是空的」。脏数据（旧版本写坏的 Preferences）必须先滤掉。
 */
function isPersistableTrack(t: Track): boolean {
  return t !== null && t !== undefined && typeof t.id === 'string' && t.id.length > 0;
}

function sanitizeTracks(raw: Track[]): Track[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw.filter((t: Track): boolean => isPersistableTrack(t));
}

export function getRecentTracks(): Track[] {
  if (recentCache === null) {
    // 磁盘上的值可能不是数组（旧版本写过别的结构 / 手工改坏），
    // 这里必须归一化：否则 `recentCache.slice()` 会直接抛，页面永远停在空态。
    recentCache = sanitizeTracks(AppPreferences.getRecentTracks<Track>());
  }
  // 返回副本：调用方持有内部数组时，改列表不会触发 @State 刷新
  return recentCache.slice();
}

function persistRecentTracks(list: Track[]): void {
  const capped: Track[] = sanitizeTracks(list).slice(0, RECENT_MAX_ITEMS);

  // ⚠️ 顺序很重要：**先换内存快照，再序列化落盘**。
  // 反过来（先 slimTrack / fitByByteBudget 再更新快照）时，只要序列化那一步抛异常，
  // 快照就保持旧值 —— 界面表现为「播放正常，但最近播放里一条记录都没有」。
  // 内存快照是读取侧的真源，必须无条件先落地。
  recentCache = capped;

  try {
    // Preferences 单值有 8192 字节上限，落盘前统一瘦身 + 按字节预算截断
    const payload: Track[] = fitByByteBudget<Track>(capped.map((t: Track): Track => slimTrack(t)), PREF_VALUE_BUDGET_BYTES);
    if (payload.length < capped.length) {
      console.info(`recent tracks truncated for storage: ${payload.length}/${capped.length}`);
    }
    AppPreferences.saveRecentTracks<Track>(payload).catch((e: Error): void => {
      // 落盘失败只影响「重启后还在不在」，不影响本次会话的展示
      console.error(`saveRecentTracks failed: ${e.message}`);
    });
  } catch (e) {
    const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
    console.error(`build recent payload failed: ${detail}`);
  }
  // 通知「最近播放」页 / 歌单页重新拉取（否则新增记录后切页看不到）
  notifyLibraryChanged();
}

export function addRecentTrack(track: Track): void {
  if (!isPersistableTrack(track)) {
    console.error('addRecentTrack ignored: invalid track');
    return;
  }
  const recent: Track[] = getRecentTracks().filter((t: Track): boolean => t.id !== track.id);
  // 与参考实现一致：按 id 去重后插到最前（最近听的在最上面）
  recent.unshift(track);
  persistRecentTracks(recent);
  console.info(`recent track added: ${track.id} (total ${getRecentTracks().length})`);
}

export function removeRecentTrack(id: string): Track[] {
  const next: Track[] = getRecentTracks().filter((t: Track): boolean => t.id !== id);
  persistRecentTracks(next);
  return getRecentTracks();
}

export function clearRecentTracks(): void {
  persistRecentTracks([]);
}

export function getFavoriteTracks(): Track[] {
  return AppPreferences.getFavoriteTracks<Track>();
}

export function toggleFavoriteTrack(track: Track): Track[] {
  const favs: Track[] = getFavoriteTracks();
  const idx: number = favs.findIndex((t: Track): boolean => t.id === track.id);
  if (idx >= 0) {
    favs.splice(idx, 1);
    addFavoriteTombstone(track.id);
  } else {
    favs.unshift(Object.assign({}, track, { isLiked: true, likedAt: new Date().toISOString() }));
    removeFavoriteTombstone(track.id);
  }
  AppPreferences.saveFavoriteTracks<Track>(favs);
  return favs;
}

export function removeFavoriteTrack(id: string): Track[] {
  const favs: Track[] = getFavoriteTracks().filter((t: Track): boolean => t.id !== id);
  addFavoriteTombstone(id);
  AppPreferences.saveFavoriteTracks<Track>(favs);
  return favs;
}

/**
 * 歌单内存快照。
 * `AppPreferences.savePlaylists` 是异步落盘（put + flush），而读取走的是同步 `getSync`。
 * 删除 / 重命名后紧接着刷新列表，会存在「异步写还没完成、同步读拿到旧值」的竞态，
 * 表现为点了删除歌单还在。这里把内存缓存作为唯一真源：写操作先换掉缓存再异步落盘。
 */
let playlistCache: Playlist[] | null = null;

export function getPlaylists(): Playlist[] {
  if (playlistCache === null) {
    playlistCache = AppPreferences.getPlaylists<Playlist>();
  }
  // 返回副本：避免调用方持有内部数组导致改列表不触发 @State 刷新
  return playlistCache.slice();
}

function persistPlaylists(list: Playlist[]): void {
  // 曲目一律瘦身落盘（audioUrl 不入库，理由见 slimTrack 注释）。
  // 歌单曲目不能像「最近播放」那样截断——截断等于悄悄丢用户的歌，只做体积告警。
  const slim: Playlist[] = list.map((p: Playlist): Playlist => {
    return {
      id: p.id,
      name: p.name,
      description: p.description,
      coverUrl: p.coverUrl,
      createdAt: p.createdAt,
      updatedAt: p.updatedAt,
      tracks: p.tracks.map((t: Track): Track => slimTrack(t))
    };
  });
  playlistCache = slim;
  const bytes: number = utf8Length(JSON.stringify(slim));
  if (bytes > PREF_VALUE_BUDGET_BYTES) {
    // Preferences 单值超过 8192 字节时 put() 会直接抛错，写不进去
    console.error(`playlists payload too large: ${bytes} bytes (budget ${PREF_VALUE_BUDGET_BYTES})`);
  }
  AppPreferences.savePlaylists<Playlist>(slim).catch((e: Error): void => {
    console.error(`savePlaylists failed: ${e.message}`);
  });
  notifyLibraryChanged();
}

let libraryRev: number = 0;

/** 通知各页面媒体库已变更（歌单页常驻在 Tabs 里，不刷新会一直显示旧数据） */
function notifyLibraryChanged(): void {
  libraryRev = libraryRev + 1;
  AppStorage.setOrCreate(STORE_LIBRARY_REV, libraryRev);
}

export function createPlaylist(input: { name: string; description?: string; coverUrl?: string }): Playlist {
  const now: string = new Date().toISOString();
  const playlist: Playlist = {
    id: createId(),
    name: input.name.trim(),
    description: input.description?.trim() || '',
    coverUrl: input.coverUrl?.trim() || '',
    tracks: [],
    createdAt: now,
    updatedAt: now
  };
  persistPlaylists([playlist, ...getPlaylists()]);
  return playlist;
}

export function getPlaylist(id: string): Playlist | null {
  return getPlaylists().find((p: Playlist): boolean => p.id === id) ?? null;
}

export function updatePlaylist(updated: Playlist): void {
  const playlists: Playlist[] = getPlaylists().map((p: Playlist): Playlist => {
    return p.id === updated.id ? Object.assign({}, updated, { updatedAt: new Date().toISOString() }) : p;
  });
  persistPlaylists(playlists);
}

export function deletePlaylist(id: string): void {
  addPlaylistTombstone(id);
  persistPlaylists(getPlaylists().filter((p: Playlist): boolean => p.id !== id));
}

/**
 * 重命名歌单。只改名字，其余字段（tracks / 封面 / 创建时间）原样保留，
 * 不能拿一个只有 name 的新对象去 updatePlaylist，否则曲目会被清空。
 */
export function renamePlaylist(id: string, name: string): Playlist | null {
  const current: Playlist | null = getPlaylist(id);
  if (!current) {
    return null;
  }
  const renamed: Playlist = Object.assign({}, current, { name: name.trim(), updatedAt: new Date().toISOString() });
  updatePlaylist(renamed);
  return renamed;
}

export function addTrackToPlaylist(playlistId: string, track: Track): Playlist | null {
  const playlists: Playlist[] = getPlaylists();
  let updatedPlaylist: Playlist | null = null;
  const next: Playlist[] = playlists.map((playlist: Playlist): Playlist => {
    if (playlist.id !== playlistId) {
      return playlist;
    }
    const exists: boolean = playlist.tracks.some((t: Track): boolean => t.id === track.id);
    updatedPlaylist = {
      id: playlist.id,
      name: playlist.name,
      description: playlist.description,
      coverUrl: playlist.coverUrl || track.coverUrl,
      tracks: exists ? playlist.tracks : [...playlist.tracks, track],
      createdAt: playlist.createdAt,
      updatedAt: new Date().toISOString()
    };
    return updatedPlaylist;
  });
  if (updatedPlaylist) {
    persistPlaylists(next);
  }
  return updatedPlaylist;
}

export function removeTracksFromPlaylist(playlistId: string, trackIds: string[]): Playlist | null {
  const ids: Set<string> = new Set<string>(trackIds);
  if (ids.size === 0) {
    return getPlaylist(playlistId);
  }
  const playlists: Playlist[] = getPlaylists();
  let updatedPlaylist: Playlist | null = null;
  const next: Playlist[] = playlists.map((playlist: Playlist): Playlist => {
    if (playlist.id !== playlistId) {
      return playlist;
    }
    updatedPlaylist = {
      id: playlist.id,
      name: playlist.name,
      description: playlist.description,
      coverUrl: playlist.coverUrl,
      tracks: playlist.tracks.filter((t: Track): boolean => !ids.has(t.id)),
      createdAt: playlist.createdAt,
      updatedAt: new Date().toISOString()
    };
    return updatedPlaylist;
  });
  if (updatedPlaylist) {
    persistPlaylists(next);
  }
  return updatedPlaylist;
}

// ===== 删除墓碑（云同步用，避免被对端复活） =====

function loadPlaylistTombstones(): Tombstone[] {
  return AppPreferences.getPlaylistTombstones<Tombstone>();
}

function savePlaylistTombstones(list: Tombstone[]): void {
  AppPreferences.savePlaylistTombstones<Tombstone>(list);
}

function addPlaylistTombstone(id: string): void {
  const list: Tombstone[] = loadPlaylistTombstones().filter((t: Tombstone): boolean => t.id !== id);
  list.push({ id: id, deletedAt: new Date().toISOString() });
  savePlaylistTombstones(list);
}

function loadFavoriteTombstones(): Tombstone[] {
  return AppPreferences.getFavoriteTombstones<Tombstone>();
}

function saveFavoriteTombstones(list: Tombstone[]): void {
  AppPreferences.saveFavoriteTombstones<Tombstone>(list);
}

function addFavoriteTombstone(id: string): void {
  const list: Tombstone[] = loadFavoriteTombstones().filter((t: Tombstone): boolean => t.id !== id);
  list.push({ id: id, deletedAt: new Date().toISOString() });
  saveFavoriteTombstones(list);
}

function removeFavoriteTombstone(id: string): void {
  saveFavoriteTombstones(loadFavoriteTombstones().filter((t: Tombstone): boolean => t.id !== id));
}

export function createPlaylistsExport(): object {
  return {
    app: 'biliMusic',
    type: 'playlists',
    version: 1,
    exportedAt: new Date().toISOString(),
    playlists: getPlaylists()
  };
}

export function importPlaylistsFromText(text: string): { imported: number; skipped: number } {
  const parsed = JSON.parse(text);
  const incoming: Playlist[] = Array.isArray(parsed) ? parsed : parsed?.playlists;
  if (!Array.isArray(incoming)) {
    throw new Error('文件中没有找到歌单列表');
  }

  const now: string = new Date().toISOString();
  const existing: Playlist[] = getPlaylists();
  const existingIds: Set<string> = new Set<string>(existing.map((p: Playlist): string => p.id));
  const existingNames: Set<string> = new Set<string>(existing.map((p: Playlist): string => p.name.trim()));
  const imported: Playlist[] = [];
  let skipped: number = 0;

  for (let i = 0; i < incoming.length; i++) {
    const item: Playlist = incoming[i];
    if (!item || typeof item.name !== 'string' || !Array.isArray(item.tracks)) {
      skipped++;
      continue;
    }
    const name: string = item.name.trim();
    if (!name) {
      skipped++;
      continue;
    }
    const id: string = item.id && !existingIds.has(item.id) ? item.id : createId();
    existingIds.add(id);
    const finalName: string = existingNames.has(name) ? `${name} 导入` : name;
    existingNames.add(finalName);
    imported.push({
      id: id,
      name: finalName,
      description: item.description || '',
      coverUrl: item.coverUrl || item.tracks[0]?.coverUrl || '',
      tracks: item.tracks,
      createdAt: item.createdAt || now,
      updatedAt: now
    });
  }

  if (imported.length > 0) {
    // 必须走 persistPlaylists：直接写 Preferences 不会更新内存快照，导入后读到的还是旧列表
    persistPlaylists([...imported, ...getPlaylists()]);
  }
  return { imported: imported.length, skipped: skipped };
}

/** 命名空间导出：供 `import { LibraryStore }` 以对象方式调用。 */
export const LibraryStore = {
  getRecentTracks,
  addRecentTrack,
  removeRecentTrack,
  clearRecentTracks,
  getFavoriteTracks,
  toggleFavoriteTrack,
  removeFavoriteTrack,
  getPlaylists,
  createPlaylist,
  getPlaylist,
  updatePlaylist,
  renamePlaylist,
  deletePlaylist,
  addTrackToPlaylist,
  removeTracksFromPlaylist,
  createPlaylistsExport,
  importPlaylistsFromText
};
