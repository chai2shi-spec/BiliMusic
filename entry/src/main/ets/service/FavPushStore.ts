/**
 * 收藏夹双向同步「待推送意图队列」持久化。
 *
 * 职责单一：双向夹的本地增删（add / del 意图）实时写回失败后进入此队列，
 * 由 FavPushRunner 去抖冲刷；FavSyncManager 每轮同步开头先补推（先推后拉）。
 *
 * 意图只存 { mediaId, bvid, op }，avid 由冲刷时 bv2av(bvid) 现算 ——
 * bvid→avid 是确定性映射，无需缓存，单条意图约 55 字节。
 *
 * 容量上限 FAV_PUSH_QUEUE_CAP = 120 条：Preferences 单值 8192 字节预算内
 * （120 × ~55B ≈ 6.6KB），超限 FIFO 丢最旧并告警（正常用户远达不到）。
 *
 * 入队去重规则（同 mediaId + bvid）：
 *   · 同 op  → 幂等跳过（防连点）；
 *   · 反 op  → 互相对冲抵消（未冲刷的 add 与 del 相消 = 净变化为零，双双不入队）。
 *     已冲刷出队的意图不参与对冲 —— 那时 B 站状态已改变，重删/重加按新意图入队。
 *
 * 存储：单 key（PREF_FAV_TWOWAY_PUSH_QUEUE，`FavPushIntent[]` JSON）。
 */

import { AppPreferences } from '../preferences/AppPreferences';
import { PREF_FAV_TWOWAY_PUSH_QUEUE } from '../common/Constants';

/** 待推送意图：op 取值 'add'（加入收藏）| 'del'（取消收藏） */
export interface FavPushIntent {
  /** 目标收藏夹 media_id */
  mediaId: number;
  /** 视频 bvid（== 镜像曲目 track.id） */
  bvid: string;
  /** 'add' | 'del' */
  op: string;
}

/** 队列容量上限（8192 字节 pref 预算内的安全条数） */
export const FAV_PUSH_QUEUE_CAP: number = 120;

/** 读队列原始数组（坏数据 / 老版本缺 key 容错为空数组，逐条校验字段） */
function loadQueue(): FavPushIntent[] {
  const stored: FavPushIntent[] | null = AppPreferences.getObject<FavPushIntent[]>(PREF_FAV_TWOWAY_PUSH_QUEUE);
  if (!stored || !Array.isArray(stored)) {
    return [];
  }
  const out: FavPushIntent[] = [];
  for (let i = 0; i < stored.length; i++) {
    const it: FavPushIntent = stored[i];
    if (it && typeof it.mediaId === 'number' && it.mediaId > 0
      && typeof it.bvid === 'string' && it.bvid.length > 0
      && (it.op === 'add' || it.op === 'del')) {
      out.push({ mediaId: it.mediaId, bvid: it.bvid, op: it.op });
    }
  }
  return out;
}

/** 整体覆盖写入（fire-and-forget，与 FavSelectionStore 落盘风格一致） */
function saveQueue(queue: FavPushIntent[]): void {
  AppPreferences.setObject<FavPushIntent[]>(PREF_FAV_TWOWAY_PUSH_QUEUE, queue)
    .catch((e: Error): void => {
      console.error(`saveFavPushQueue failed: ${e.message}`);
    });
}

/**
 * 意图批量入队（去重 + 对冲 + 容量截断），返回实际入队条数。
 * 调用方：LibraryStore 挂钩（add / remove）、FavPushRunner 冲刷失败保留。
 */
export function enqueueFavPushes(intents: FavPushIntent[]): number {
  if (!intents || intents.length === 0) {
    return 0;
  }
  const queue: FavPushIntent[] = loadQueue();
  let enqueued: number = 0;
  let dirty: boolean = false;
  for (let i = 0; i < intents.length; i++) {
    const next: FavPushIntent = intents[i];
    if (!next || !(next.mediaId > 0) || !next.bvid
      || (next.op !== 'add' && next.op !== 'del')) {
      continue;
    }
    let cancelledIdx: number = -1;
    let dupIdx: number = -1;
    for (let j = 0; j < queue.length; j++) {
      const cur: FavPushIntent = queue[j];
      if (cur.mediaId === next.mediaId && cur.bvid === next.bvid) {
        if (cur.op === next.op) {
          dupIdx = j;
        } else {
          cancelledIdx = j;
        }
        break;
      }
    }
    if (dupIdx >= 0) {
      continue;
    }
    if (cancelledIdx >= 0) {
      queue.splice(cancelledIdx, 1);
      dirty = true;
      continue;
    }
    queue.push({ mediaId: next.mediaId, bvid: next.bvid, op: next.op });
    enqueued++;
    dirty = true;
  }
  if (queue.length > FAV_PUSH_QUEUE_CAP) {
    const dropped: number = queue.length - FAV_PUSH_QUEUE_CAP;
    queue.splice(0, dropped);
    dirty = true;
    console.warn(`[FavPushStore] queue overflow, dropped ${dropped} oldest intents`);
  }
  if (dirty) {
    saveQueue(queue);
  }
  return enqueued;
}

/** 队列整体读出（冲刷器一轮取一次；返回浅拷贝，改写请走 remove/ purge） */
export function pendingFavPushes(): FavPushIntent[] {
  return loadQueue();
}

/** 冲刷成功后按 (mediaId, bvid, op) 精确移除已推送意图 */
export function removeFavPushes(done: FavPushIntent[]): void {
  if (!done || done.length === 0) {
    return;
  }
  const queue: FavPushIntent[] = loadQueue();
  const rest: FavPushIntent[] = [];
  for (let i = 0; i < queue.length; i++) {
    const cur: FavPushIntent = queue[i];
    let matched: boolean = false;
    for (let j = 0; j < done.length; j++) {
      const d: FavPushIntent = done[j];
      if (d && cur.mediaId === d.mediaId && cur.bvid === d.bvid && cur.op === d.op) {
        matched = true;
        break;
      }
    }
    if (!matched) {
      rest.push(cur);
    }
  }
  if (rest.length !== queue.length) {
    saveQueue(rest);
  }
}

/** 该收藏夹是否仍有未冲刷的推送意图（同步门控：有积压则本轮只增不减） */
export function hasPendingForFolder(mediaId: number): boolean {
  if (!(mediaId > 0)) {
    return false;
  }
  const queue: FavPushIntent[] = loadQueue();
  for (let i = 0; i < queue.length; i++) {
    if (queue[i].mediaId === mediaId) {
      return true;
    }
  }
  return false;
}

/** 清空某收藏夹的全部待推送意图（删除本地镜像时调用：停止镜像 = 放弃未冲刷意图） */
export function purgeFavPushesForFolder(mediaId: number): void {
  if (!(mediaId > 0)) {
    return;
  }
  const queue: FavPushIntent[] = loadQueue();
  const rest: FavPushIntent[] = queue.filter((it: FavPushIntent): boolean => it.mediaId !== mediaId);
  if (rest.length !== queue.length) {
    saveQueue(rest);
  }
}
