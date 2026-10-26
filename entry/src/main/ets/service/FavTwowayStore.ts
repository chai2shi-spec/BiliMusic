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
 * 存取委托 PrefStringSetStore（成员=真极性）；
 * 存储：单 key（PREF_FAV_TWOWAY_IDS，`number[]` JSON）。
 */

import { PREF_FAV_TWOWAY_IDS } from '../common/Constants';
import { PrefStringSetStore } from './PrefStringSetStore';

/** 共享存取器：集合成员 ⇔「双向」为真（正向存储） */
const store: PrefStringSetStore = new PrefStringSetStore(PREF_FAV_TWOWAY_IDS, true);

/**
 * 该收藏夹是否开启双向同步（默认单向：未记录 = 单向）。
 * 非法 id（<=0）按单向处理，绝不让坏数据触发写回。
 */
export function isFolderTwoway(mediaId: number): boolean {
  return store.is(mediaId);
}

/**
 * 设置方向模式并持久化：
 * 双向 = 加入集合（若不在）；单向 = 从集合移除（若在）。
 * 幂等：状态没变化时不写盘。
 */
export function setFolderTwoway(mediaId: number, twoway: boolean): void {
  store.set(mediaId, twoway);
}
