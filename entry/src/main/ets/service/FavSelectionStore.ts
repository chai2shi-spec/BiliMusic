/**
 * 收藏夹同步勾选状态持久化（2026-10-23，登录自动同步改为手动选择性同步）。
 *
 * 职责单一：记住「用户在收藏夹同步页取消了哪些收藏夹的勾选」，
 * 供同步页渲染勾选态、FavSyncManager 过滤本轮参与同步的收藏夹。
 *
 * 倒置存储（存「未勾选」而非「已勾选」）的理由：
 *   · 默认全选 —— 磁盘上没有任何记录 = 从未取消过 = 全部勾选，
 *     老版本升级**零迁移**；
 *   · 新建收藏夹自动入选 —— 不需要任何「记录新夹」的动作；
 *   · B 站侧改名 / 新增夹都不影响判断（只按 mediaId）。
 *
 * ⚠️ 语义边界：「未勾选」≠「B 站已删除」—— 管理器按勾选过滤同步集合时，
 *    清理已删除夹镜像（pruneDeletedFolders）仍必须拿**全量**收藏夹列表，
 *    否则未勾选夹的本地镜像会被误判删除。
 *
 * 存储：单 key（PREF_FAV_SELECTION，`number[]` JSON），体量极小，无需分片。
 */

import { AppPreferences } from '../preferences/AppPreferences';
import { PREF_FAV_SELECTION } from '../common/Constants';

/** 读「未勾选」集合原始数组（坏数据 / 老版本缺 key 容错为空数组） */
function loadDeselectedIds(): number[] {
  const stored: number[] | null = AppPreferences.getObject<number[]>(PREF_FAV_SELECTION);
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

/** 整体覆盖写入（fire-and-forget，与 FavSyncStore 落盘风格一致） */
function saveDeselectedIds(ids: number[]): void {
  AppPreferences.setObject<number[]>(PREF_FAV_SELECTION, ids)
    .catch((e: Error): void => {
      console.error(`saveDeselectedIds failed: ${e.message}`);
    });
}

/**
 * 该收藏夹是否勾选参与同步（默认勾选：未记录 = 勾选）。
 * 非法 id（<=0）按勾选处理，绝不让坏数据挡住同步。
 */
export function isFolderSelected(mediaId: number): boolean {
  if (!(mediaId > 0)) {
    return true;
  }
  return loadDeselectedIds().indexOf(mediaId) < 0;
}

/**
 * 设置勾选态并持久化：
 * 勾选 = 从「未勾选」集合移除（若在）；取消 = 加入（若不在）。
 * 幂等：状态没变化时不写盘。
 */
export function setFolderSelected(mediaId: number, selected: boolean): void {
  if (!(mediaId > 0)) {
    return;
  }
  const cur: number[] = loadDeselectedIds();
  const idx: number = cur.indexOf(mediaId);
  if (selected) {
    if (idx >= 0) {
      cur.splice(idx, 1);
      saveDeselectedIds(cur);
    }
    return;
  }
  if (idx < 0) {
    cur.push(mediaId);
    saveDeselectedIds(cur);
  }
}

/** 未勾选集合整体读出（FavSyncManager 一轮只读一次，避免逐夹反复读盘） */
export function deselectedFolderIds(): Set<number> {
  return new Set<number>(loadDeselectedIds());
}
