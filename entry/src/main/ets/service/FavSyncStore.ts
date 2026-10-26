/**
 * 收藏夹同步状态持久化（B 站收藏夹 → 本地歌单镜像）。
 *
 * 职责单一：把「每个收藏夹上次同步到哪、结果如何」落到 Preferences，供
 * 同步页展示与同步管理器做「失败可区分」（失败 vs 真的空收藏夹）。
 *
 * 为什么需要它（而不是只看本地歌单现状）：
 *   · 「本轮拉取失败」与「收藏夹真的被清空」都是「本地镜像没有曲目」，
 *     只有落一个 lastResult 才能区分，否则 UI 无法说清发生了什么；
 *   · lastItemCount 记录上次**完整成功**拉到的条数，是「是否可能未拉全」的旁证。
 *
 * 存储：单 key（PREF_FAV_SYNC_STATE），体量极小（每夹约 150 字节），无需分片。
 */

import { AppPreferences } from '../preferences/AppPreferences';
import { PREF_FAV_SYNC_STATE } from '../common/Constants';

/** 同步结果档位（ArkTS 禁 enum，用字符串常量） */
export const FAV_SYNC_OK: string = 'ok';
export const FAV_SYNC_PARTIAL: string = 'partial';
export const FAV_SYNC_FAILED: string = 'failed';

/** 单个收藏夹的同步状态 */
export interface FavFolderSyncState {
  /** 收藏夹 id（B 站的 media_id） */
  mediaId: number;
  /** 收藏夹名（B 站侧，可能随时改名） */
  title: string;
  /** 本地镜像歌单 id；'' = 尚未建成（例如空收藏夹被跳过） */
  playlistId: string;
  /** 上次同步完成时间（ms 时间戳）；0 = 从未同步过 */
  lastSyncAt: number;
  /** 上次结果：'ok' | 'partial' | 'failed' */
  lastResult: string;
  /** 失败/部分失败的人话原因；成功时为空串 */
  lastReason: string;
  /** 上次**完整成功**拉取到的条目数（用于区分「失败」与「真空」） */
  lastItemCount: number;
}

/** 读取全部状态（无数据返回空数组） */
export function loadFavSyncStates(): FavFolderSyncState[] {
  const stored: FavFolderSyncState[] | null =
    AppPreferences.getObject<FavFolderSyncState[]>(PREF_FAV_SYNC_STATE);
  if (!stored || !Array.isArray(stored)) {
    return [];
  }
  const out: FavFolderSyncState[] = [];
  for (let i = 0; i < stored.length; i++) {
    const s: FavFolderSyncState = stored[i];
    if (!s || typeof s.mediaId !== 'number') {
      continue;
    }
    out.push({
      mediaId: s.mediaId,
      title: s.title ?? '',
      playlistId: s.playlistId ?? '',
      lastSyncAt: s.lastSyncAt ?? 0,
      lastResult: s.lastResult ?? FAV_SYNC_OK,
      lastReason: s.lastReason ?? '',
      lastItemCount: s.lastItemCount ?? 0
    });
  }
  return out;
}

/** 整体覆盖写入（fire-and-forget，与项目既有落盘风格一致） */
export function saveFavSyncStates(list: FavFolderSyncState[]): void {
  AppPreferences.setObject<FavFolderSyncState[]>(PREF_FAV_SYNC_STATE, list)
    .catch((e: Error): void => {
      console.error(`saveFavSyncStates failed: ${e.message}`);
    });
}

/** 按 mediaId 查单个状态；没有返回 null */
export function getFavSyncState(mediaId: number): FavFolderSyncState | null {
  const list: FavFolderSyncState[] = loadFavSyncStates();
  for (let i = 0; i < list.length; i++) {
    if (list[i].mediaId === mediaId) {
      return list[i];
    }
  }
  return null;
}

/** 新增或更新一条状态（其余保持不变） */
export function upsertFavSyncState(state: FavFolderSyncState): void {
  const list: FavFolderSyncState[] = loadFavSyncStates();
  let replaced: boolean = false;
  for (let i = 0; i < list.length; i++) {
    if (list[i].mediaId === state.mediaId) {
      list[i] = state;
      replaced = true;
      break;
    }
  }
  if (!replaced) {
    list.push(state);
  }
  saveFavSyncStates(list);
}

/** 删除一条状态（该收藏夹在 B 站已被删除时用） */
export function removeFavSyncState(mediaId: number): void {
  const list: FavFolderSyncState[] = loadFavSyncStates()
    .filter((s: FavFolderSyncState): boolean => s.mediaId !== mediaId);
  saveFavSyncStates(list);
}

