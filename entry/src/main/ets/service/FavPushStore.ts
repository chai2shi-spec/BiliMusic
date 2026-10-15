/**
 * 收藏夹**待推送队列**（本地 → B 站的反向写操作，2026-10-13「真双向」）。
 *
 * 职责：把「用户在本机对镜像歌单做的增删」变成一条条可重放的写意图，落盘持久化，
 * 供 `service/FavSyncManager` 的推送阶段串行发送到 B 站；失败留队列下次重试。
 *
 * ⚠️⚠️ **核心安全不变量（改本文件前必读）**：
 *   1. **队列里的 op 只能由用户显式动作产生**（手动删曲 / 手动加曲 / 手动清空 + 二次确认）。
 *      自动轮次（登录后自动同步、冷启动重试）**只重放历史意图，绝不自行生成删除** ——
 *      这是「真双向」不变成「静默批量删用户 B 站数据」的根本保障。
 *   2. **成功才出队**。`code=0` 之后才 `removeFavOp`；失败（风控/断网）必须留在队列里，
 *      否则本地已删、B 站未删 → 下次拉取会把它「复活」回来。
 *   3. **未推送成功的意图要被「拉取侧」尊重**（防复活 / 防抹除）：见 `favPushGuardsFor`，
 *      它返回的 `pendingDelete` / `pendingAdd` 由 `LibraryStore.applyFavMirror` 作为守卫使用。
 *   4. op 按 `(mediaId, bvid)` **折叠覆盖**：同一首的新动作替换旧动作（del→add / add→del），
 *      保证幂等重放不会自相矛盾。
 *
 * 为什么独立于 `FavSyncStore.ts`：关注点（逐条 op vs 每夹汇总）、生命周期（成功即出清的瞬态
 * vs 长期保留的同步状态）、体量（上百条需分片 vs 单键足够）三者都不同。
 *
 * 存储：分片（`PREF_FAV_PUSH_QUEUE` + 分片号，每片 `FAV_PUSH_CHUNK_ITEMS` 条，探测到 miss 为止），
 * 理由见 `common/Constants.ts` 里 `PREF_FAV_PUSH_QUEUE` 的注释。
 */

import { AppPreferences } from '../preferences/AppPreferences';
import { PREF_FAV_PUSH_QUEUE, STORE_FAV_SYNC_REV } from '../common/Constants';

/** 写操作种类（ArkTS 禁 enum，沿用 FAV_SYNC_OK 的字符串常量风格） */
export const FAV_OP_DEL: string = 'del';
export const FAV_OP_ADD: string = 'add';

/** 每片条数：13 条 ≈ 1.5KB，离 6000 字节预算有余量（同 recent_tracks 的 8 条/560B 思路） */
const FAV_PUSH_CHUNK_ITEMS: number = 16;

/**
 * 队列总条数硬上限。超出后**拒绝新增**（保留既有条目），避免单次离线狂操作把存储撑爆。
 * 500 条 × 120B ≈ 60KB，分 32 片，对 Preferences 是可接受的量级。
 */
const FAV_PUSH_MAX_OPS: number = 500;

/** 探测分片时的最大片数（与上限一致，多探一片用于清理残片） */
const FAV_PUSH_MAX_CHUNKS: number = Math.ceil(FAV_PUSH_MAX_OPS / FAV_PUSH_CHUNK_ITEMS) + 1;

/** 一条待推送的写意图 */
export interface FavPushOp {
  /** 目标收藏夹 id（B 站的 media_id） */
  mediaId: number;
  /** 曲目键（本地稳定键，= bvid）；(mediaId, bvid) 决定折叠去重 */
  bvid: string;
  /** B 站 rid（avid）字符串形式；空串 = 推送前需用 getVideoDetail(bvid) 兜底解析 */
  aid: string;
  /** 'del'（取消收藏）| 'add'（收藏） */
  op: string;
  /** 曲目名，仅供同步页/排查展示 */
  title: string;
  createdAt: number;
  /** 已尝试次数（风控/网络失败累加；-101/-111 不累加） */
  attempts: number;
  /** 上次失败的人话原因（成功时置空） */
  lastError: string;
}

/** 拉取守卫：交给 LibraryStore.applyFavMirror，防止未推送的本地意图被服务端状态抹掉 */
export interface FavPushGuards {
  /** 本地已删、待取消收藏的 bvid —— 服务端**还有也不拉回** */
  pendingDelete: string[];
  /** 本地已增、待收藏的 bvid —— 服务端**没有也不移除** */
  pendingAdd: string[];
}

function chunkKey(index: number): string {
  return `${PREF_FAV_PUSH_QUEUE}${index}`;
}

/**
 * 入队后立即触发一次推送的回调。
 *
 * 由 `service/AppContainer` 在启动时装配成 `FavSyncManager.pushOnly(...)`。
 * 做成回调注入而不是在这里直接 import FavSyncManager，是为了避免
 * `FavPushStore → FavSyncManager → LibraryStore → FavPushStore` 的循环依赖，
 * 同时保证**任何**入队点（不止 UI 里那几处）都能即时推送。
 */
let pushKicker: (() => void) | null = null;

/** 装配推送触发器（启动时调用一次即可） */
export function setFavPushKicker(fn: () => void): void {
  pushKicker = fn;
}

function kickPush(): void {
  if (pushKicker !== null) {
    try {
      pushKicker();
    } catch (e) {
      // 触发失败不能让入队本身失败（意图已落盘，下次同步仍会重放）
      console.warn(`fav push kick failed: ${JSON.stringify(e)}`);
    }
  }
}

/** 递增收藏夹同步版本号（复用拉取侧同一信号；相同值不触发 @Watch，故用递增） */
function bumpFavSyncRev(): void {
  const cur: number = AppStorage.get<number>(STORE_FAV_SYNC_REV) ?? 0;
  AppStorage.setOrCreate(STORE_FAV_SYNC_REV, cur + 1);
}

/** 归一化一条落盘记录（脏数据 / 旧版本直接丢弃，不能让一条坏数据炸掉整队列） */
function normalizeOp(raw: FavPushOp): FavPushOp | null {
  if (!raw || typeof raw.mediaId !== 'number' || raw.mediaId <= 0) {
    return null;
  }
  const bvid: string = typeof raw.bvid === 'string' ? raw.bvid : '';
  if (bvid.length === 0) {
    return null;
  }
  const op: string = raw.op === FAV_OP_ADD ? FAV_OP_ADD : FAV_OP_DEL;
  return {
    mediaId: raw.mediaId,
    bvid: bvid,
    aid: typeof raw.aid === 'string' ? raw.aid : '',
    op: op,
    title: typeof raw.title === 'string' ? raw.title : '',
    createdAt: typeof raw.createdAt === 'number' ? raw.createdAt : 0,
    attempts: typeof raw.attempts === 'number' ? raw.attempts : 0,
    lastError: typeof raw.lastError === 'string' ? raw.lastError : ''
  };
}

/** 读取全队列（无数据返回空数组）。分片探测：遇到缺失片即停 */
export function loadFavPushOps(): FavPushOp[] {
  const out: FavPushOp[] = [];
  for (let i = 0; i < FAV_PUSH_MAX_CHUNKS; i++) {
    const part: FavPushOp[] | null = AppPreferences.getObject<FavPushOp[]>(chunkKey(i));
    if (!part || !Array.isArray(part)) {
      break;
    }
    for (let k = 0; k < part.length; k++) {
      const one: FavPushOp | null = normalizeOp(part[k]);
      if (one !== null) {
        out.push(one);
      }
    }
  }
  return out;
}

/** 队列条数（同步页「N 条待同步」用） */
export function countFavPushOps(): number {
  return loadFavPushOps().length;
}

/**
 * 整体重写队列（分片落盘）。**fire-and-forget**，与项目既有落盘风格一致。
 *
 * 收尾会清掉「新片数之外」的残留分片：不清理的话，队列从 100 条缩到 10 条时，
 * 旧的第 1..6 片仍在盘上，下次 `loadFavPushOps` 会把已删的 op 又读回来。
 */
export function saveFavPushOps(list: FavPushOp[]): void {
  const capped: FavPushOp[] = list.length > FAV_PUSH_MAX_OPS
    ? list.slice(0, FAV_PUSH_MAX_OPS)
    : list;
  const chunkCount: number = Math.ceil(capped.length / FAV_PUSH_CHUNK_ITEMS);

  let seq: Promise<void> = Promise.resolve();
  for (let i = 0; i < chunkCount; i++) {
    const slice: FavPushOp[] = capped.slice(i * FAV_PUSH_CHUNK_ITEMS, (i + 1) * FAV_PUSH_CHUNK_ITEMS);
    seq = seq.then((): Promise<void> => AppPreferences.setObject<FavPushOp[]>(chunkKey(i), slice));
  }
  // 顺序清理可能存在的残片（片数变少时）
  for (let i = chunkCount; i < FAV_PUSH_MAX_CHUNKS; i++) {
    seq = seq.then((): Promise<void> => AppPreferences.remove(chunkKey(i)));
  }
  seq.catch((e: Error): void => {
    console.error(`saveFavPushOps failed: ${e.message}`);
  });
  bumpFavSyncRev();
}

/**
 * 入队一条写意图（按 `(mediaId, bvid)` 折叠覆盖 + 立即落盘 + 广播 + 触发推送）。
 *
 * 折叠语义：同一首已有 op 时**用新 op 整体替换**（含重置 attempts），
 * 于是 `add → del` 或 `del → add` 都是「最后一次用户意图说了算」，重放不会打架。
 */
export function enqueueFavOp(op: FavPushOp): void {
  const one: FavPushOp | null = normalizeOp(op);
  if (one === null) {
    return;
  }
  const list: FavPushOp[] = loadFavPushOps();
  let replaced: boolean = false;
  for (let i = 0; i < list.length; i++) {
    if (list[i].mediaId === one.mediaId && list[i].bvid === one.bvid) {
      list[i] = one;
      replaced = true;
      break;
    }
  }
  if (!replaced) {
    if (list.length >= FAV_PUSH_MAX_OPS) {
      console.warn(`fav push queue full (${FAV_PUSH_MAX_OPS}), drop new op ${one.mediaId}/${one.bvid}`);
      return;
    }
    list.push(one);
  }
  saveFavPushOps(list);
  // 落盘后再触发推送：即使推送失败，意图也已持久化，下次同步/冷启动会重放
  kickPush();
}

/** 出队（推送成功后调用）。找不到也安全（幂等） */
export function removeFavOp(mediaId: number, bvid: string): void {
  const list: FavPushOp[] = loadFavPushOps()
    .filter((o: FavPushOp): boolean => !(o.mediaId === mediaId && o.bvid === bvid));
  saveFavPushOps(list);
}

/**
 * 用最新队列整体覆盖（推送阶段更新 `attempts` / `lastError` 后回写用）。
 * 与 `saveFavPushOps` 等价，单独命名以便调用点表达「这是重试计数回写」。
 */
export function updateFavPushOps(list: FavPushOp[]): void {
  saveFavPushOps(list);
}

/**
 * 清掉某个收藏夹的全部待推送 op。
 * 用于「用户选择只删本地（B 站保留）」与「合并/删除镜像源」—— 此时用户的意图
 * 已不再是「把这些歌从 B 站取消收藏」，残留的 del 会在下次推送时误删，必须清掉。
 */
export function clearFavOpsForMedia(mediaId: number): void {
  const list: FavPushOp[] = loadFavPushOps()
    .filter((o: FavPushOp): boolean => o.mediaId !== mediaId);
  saveFavPushOps(list);
}

/** 该收藏夹是否还有待推送（同步页展示用） */
export function hasPendingForMedia(mediaId: number): boolean {
  const list: FavPushOp[] = loadFavPushOps();
  for (let i = 0; i < list.length; i++) {
    if (list[i].mediaId === mediaId) {
      return true;
    }
  }
  return false;
}

/**
 * 取某收藏夹的拉取守卫（防复活 / 防抹除）。
 *
 * ⚠️ 只回传**未推送成功**的意图：op 一旦推送成功即出队，守卫自然失效，
 * 下一轮拉取就完全以服务端为准。
 */
export function favPushGuardsFor(mediaId: number): FavPushGuards {
  const pendingDelete: string[] = [];
  const pendingAdd: string[] = [];
  const list: FavPushOp[] = loadFavPushOps();
  for (let i = 0; i < list.length; i++) {
    const o: FavPushOp = list[i];
    if (o.mediaId !== mediaId) {
      continue;
    }
    if (o.op === FAV_OP_DEL) {
      pendingDelete.push(o.bvid);
    } else {
      pendingAdd.push(o.bvid);
    }
  }
  return { pendingDelete: pendingDelete, pendingAdd: pendingAdd };
}
