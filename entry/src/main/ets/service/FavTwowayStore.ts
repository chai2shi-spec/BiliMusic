/**
 * 收藏夹同步方向模式持久化（收藏夹同步按夹可选单向/双向）。
 *
 * 职责单一：记住「哪些收藏夹开启了双向同步」，
 * 供同步页渲染每行滑块、LibraryStore 挂钩判断本地增删是否写回 B 站。
 *
 * 正向存储（存「双向」而非「单向」）的理由：
 *   · 默认单向 —— 磁盘上没有任何记录 = 从未开启过 = 全部单向，
 *     老版本升级**零迁移**（单向即现状行为，语义安全）；
 *   · 双向是显式开启的少数派，集合通常很小。
 *
 * 存储：单 key（PREF_FAV_TWOWAY_IDS，`number[]` JSON），体量极小，无需分片。
 */

import { AppPreferences } from '../preferences/AppPreferences';
import { PREF_FAV_TWOWAY_IDS } from '../common/Constants';

/** 读「双向」集合原始数组（坏数据 / 老版本缺 key 容错为空数组） */
function loadTwowayIds(): number[] {
  const stored: number[] | null = AppPreferences.getObject<number[]>(PREF_FAV_TWOWAY_IDS);
  if (!stored || !Array.isArray(stored)) {
    return [];
  }
  const out: number[] = [];
  for (let i = 0; i < stored.length; i++) {
    const v: number = stored[i];
    if (typeof v === 'number' && v > 0) {
      out.push(v);
    }
  }
  return out;
}

/** 整体覆盖写入（fire-and-forget，与 FavSelectionStore 落盘风格一致） */
function saveTwowayIds(ids: number[]): void {
  AppPreferences.setObject<number[]>(PREF_FAV_TWOWAY_IDS, ids)
    .catch((e: Error): void => {
      console.error(`saveTwowayIds failed: ${e.message}`);
    });
}

/**
 * 该收藏夹是否开启双向同步（默认单向：未记录 = 单向）。
 * 非法 id（<=0）按单向处理，绝不让坏数据触发写回。
 */
export function isFolderTwoway(mediaId: number): boolean {
  if (!(mediaId > 0)) {
    return false;
  }
  return loadTwowayIds().indexOf(mediaId) >= 0;
}

/**
 * 设置方向模式并持久化：
 * 双向 = 加入集合（若不在）；单向 = 从集合移除（若在）。
 * 幂等：状态没变化时不写盘。
 */
export function setFolderTwoway(mediaId: number, twoway: boolean): void {
  if (!(mediaId > 0)) {
    return;
  }
  const cur: number[] = loadTwowayIds();
  const idx: number = cur.indexOf(mediaId);
  if (twoway) {
    if (idx < 0) {
      cur.push(mediaId);
      saveTwowayIds(cur);
    }
    return;
  }
  if (idx >= 0) {
    cur.splice(idx, 1);
    saveTwowayIds(cur);
  }
}

/** 双向集合整体读出（一轮只读一次，避免逐夹反复读盘） */
export function twowayFolderIds(): Set<number> {
  return new Set<number>(loadTwowayIds());
}
