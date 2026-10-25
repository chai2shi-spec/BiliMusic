/**
 * 首页快捷卡行「歌单卡」存储（加入首页的歌单 id 列表，最多
 * HOME_PLAYLIST_CARDS_MAX 个；快捷卡行 = 最近播放 1 卡 + 歌单卡 ≤9，共 10 卡）。
 *
 * 与 `SearchHistoryStore` 同一套写法：**内存快照即真源**（AppPreferences 读是
 * 同步 getSync、写是异步 put + flush，先换快照再落盘，写完立刻读必得新值）。
 * id 列表几十字节，碰不到 Preferences 的 8192 字节单值上限，无需分片。
 *
 * 变更通知复用 STORE_LIBRARY_REV（library 版本号通道）：HomePage（快捷卡行）、
 * PlaylistsPage（⋯ 菜单文案）都 @StorageLink + @Watch 它，bump 一次即时刷新；
 * 对 RecentPage / FollowsPage 等其他订阅页多触发一次幂等 refresh，无害。
 */

import { PREF_HOME_PLAYLIST_CARDS, STORE_LIBRARY_REV } from '../common/Constants';
import { AppPreferences } from '../preferences/AppPreferences';

/** 首页歌单卡上限（快捷卡行共 10 卡 = 最近播放 1 + 歌单 9） */
export const HOME_PLAYLIST_CARDS_MAX: number = 9;

let idsCache: string[] | null = null;

/** 归一化磁盘数据：丢「非字符串 / 空白 / 重复」，并截到上限（写坏的旧数据也要能读） */
function sanitize(raw: string[]): string[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  const out: string[] = [];
  for (let i = 0; i < raw.length; i++) {
    const item: string = raw[i];
    if (typeof item !== 'string') {
      continue;
    }
    const id: string = item.trim();
    if (id.length === 0 || out.indexOf(id) >= 0) {
      continue;
    }
    out.push(id);
    if (out.length >= HOME_PLAYLIST_CARDS_MAX) {
      break;
    }
  }
  return out;
}

/** 读取加入首页的歌单 id 列表（返回副本：调用方改它不影响内部真源） */
export function getHomePlaylistIds(): string[] {
  if (idsCache === null) {
    const stored: string[] | null = AppPreferences.getObject<string[]>(PREF_HOME_PLAYLIST_CARDS);
    idsCache = sanitize(stored !== null ? stored : []);
  }
  return idsCache.slice();
}

/** 该歌单是否已加入首页（歌单 ⋯ 菜单「加入首页 / 移出首页」文案切换依据） */
export function isHomePlaylist(id: string): boolean {
  return getHomePlaylistIds().indexOf(id) >= 0;
}

function persistIds(): void {
  AppPreferences.setObject<string[]>(PREF_HOME_PLAYLIST_CARDS, idsCache ?? []).catch((e: Error): void => {
    // 落盘失败只影响「重启后还在不在」，本次会话的展示不受影响
    console.error(`persist home playlist cards failed: ${e.message}`);
  });
}

function bumpLibraryRev(): void {
  const rev: number = (AppStorage.get(STORE_LIBRARY_REV) as number) ?? 0;
  AppStorage.setOrCreate(STORE_LIBRARY_REV, rev + 1);
}

/**
 * 加入首页（追加到列表尾 = 卡行最右）。
 * @returns false = 已在首页 或 已满上限（调用方按 isHomePlaylist 先行分支自行区分提示）
 */
export function addHomePlaylist(id: string): boolean {
  const cur: string[] = getHomePlaylistIds();
  if (cur.indexOf(id) >= 0 || cur.length >= HOME_PLAYLIST_CARDS_MAX) {
    return false;
  }
  const next: string[] = cur.slice();
  next.push(id);
  idsCache = next;
  persistIds();
  bumpLibraryRev();
  return true;
}

/** 从首页移出（不在首页则无操作） */
export function removeHomePlaylist(id: string): void {
  const cur: string[] = getHomePlaylistIds();
  if (cur.indexOf(id) < 0) {
    return;
  }
  const next: string[] = [];
  for (let i = 0; i < cur.length; i++) {
    if (cur[i] !== id) {
      next.push(cur[i]);
    }
  }
  idsCache = next;
  persistIds();
  bumpLibraryRev();
}

/** 命名空间导出：与 `SearchHistoryStore` / `LibraryStore` 保持一致的调用风格 */
export const HomeCardStore = {
  getHomePlaylistIds,
  isHomePlaylist,
  addHomePlaylist,
  removeHomePlaylist
};
