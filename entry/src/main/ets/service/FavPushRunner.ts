/**
 * 收藏夹双向同步「推送冲刷器」。
 *
 * 两条触发路径，最终都汇到 flushFavPushes()：
 *   1. **实时推送**：LibraryStore 挂钩（双向夹加歌 / 移除）后调
 *      scheduleFavPushFlush() —— 1500ms 去抖合并连续操作（防连点、防批量添加
 *      时的密集请求），到点自动冲刷；
 *   2. **失败补推**：FavSyncManager.run() 开头 await flushFavPushes() ——
 *      「立即同步」先推后拉，把上一轮实时推送失败的意图补上再拉服务端状态。
 *
 * 冲刷策略（防风控）：
 *   · 意图按 bvid 分组，同一视频对多个夹的增 / 删合并为一次
 *     `dealFavResource` 调用（add_media_ids / del_media_ids 列表）；
 *   · 调用间隔 400ms、单轮上限 30 次调用，余量留队列下轮；
 *   · 错误分级：
 *       瞬态（-352/-412/-509/-799 / 网络错）→ 意图保留队列，连续 3 次中止本轮；
 *       -101/-111（登录失效）→ 中止并标记 needLogin；
 *       其它业务码（参数错 / 视频失效 / 收藏数超限等）→ **丢弃意图**并计数，
 *       避免永远推不过去的意图把队列卡死。
 *
 * 并发模型：模块级单例（flushing 标志）。正在冲刷时新的 flushFavPushes 调用
 * 直接返回当前积压数（补推入口 FavSyncManager 与实时路径天然串行，
 * 冲刷中新增的意图由下一次去抖 / 下一轮同步接管，不丢）。
 */

import { BiliApiError, bv2av, dealFavResource, selfTestBv2av } from '../api/BilibiliApi';
import { getLoginCsrf } from './LoginStore';
import { FavPushIntent, pendingFavPushes, removeFavPushes } from './FavPushStore';

/** 一次冲刷的汇总（字段与 FavSyncSummary 写回段同名，便于直接合并） */
export interface FavFlushSummary {
  /** 本轮成功写回的意图条数 */
  pushed: number;
  /** 永久失败被丢弃的意图条数 */
  pushDropped: number;
  /** 仍积压待补推的意图条数 */
  pushPending: number;
  /** 登录已失效（应提示重新登录） */
  needLogin: boolean;
}

/** 实时推送去抖（ms）：连续加 / 删合并成一次冲刷 */
const FLUSH_DEBOUNCE_MS: number = 1500;
/** deal 调用之间的间隔（ms）：收藏写接口对高频敏感 */
const DEAL_GAP_MS: number = 400;
/** 单轮冲刷 deal 调用上限（防风控；余量留队列下轮） */
const DEAL_MAX_PER_ROUND: number = 30;
/** 连续多少次瞬态失败就中止本轮（等冷却 / 下一轮同步再补推） */
const TRANSIENT_ABORT_STREAK: number = 3;
/** 瞬态业务码：B 站风控 / 限流，隔一会儿往往自行恢复 */
const TRANSIENT_BIZ_CODES: number[] = [-352, -412, -509, -799];
/** 登录失效业务码：中止整轮，提示重新登录 */
const LOGIN_INVALID_CODES: number[] = [-101, -111];

let flushing: boolean = false;
let debounceTimer: number = -1;
let selfTested: boolean = false;

function emptyFlushSummary(): FavFlushSummary {
  return { pushed: 0, pushDropped: 0, pushPending: 0, needLogin: false };
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

/**
 * 实时推送入口（LibraryStore 挂钩调用）：去抖后自动冲刷。
 * 多次连续调用会互相合并（重置计时器），只冲刷一次。
 */
export function scheduleFavPushFlush(): void {
  if (debounceTimer >= 0) {
    clearTimeout(debounceTimer);
  }
  debounceTimer = setTimeout((): void => {
    debounceTimer = -1;
    flushFavPushes().catch((e: Error): void => {
      console.error(`[FavPushRunner] debounced flush failed: ${e.message}`);
    });
  }, FLUSH_DEBOUNCE_MS);
}

/**
 * 冲刷一轮待推送队列（幂等，可随时调用；空队列立即返回）。
 * FavSyncManager 在每轮同步开头 await 本方法补推。
 */
export async function flushFavPushes(): Promise<FavFlushSummary> {
  const summary: FavFlushSummary = emptyFlushSummary();
  const queue: FavPushIntent[] = pendingFavPushes();
  if (queue.length === 0) {
    return summary;
  }
  if (flushing) {
    // 已在冲刷：返回当前积压，新增意图由进行中的冲刷尾部重读或下轮接管
    summary.pushPending = queue.length;
    return summary;
  }
  flushing = true;
  try {
    await doFlush(queue, summary);
  } finally {
    flushing = false;
  }
  summary.pushPending = pendingFavPushes().length;
  return summary;
}

/** 冲刷主体（调用方已保证 flushing 互斥） */
async function doFlush(queue: FavPushIntent[], summary: FavFlushSummary): Promise<void> {
  // bv2av 自检（一次）：解码公式错误时绝不能带着错误 rid 打写接口，整轮放弃
  if (!selfTested) {
    selfTested = true;
    if (!selfTestBv2av()) {
      console.error('[FavPushRunner] bv2av self-test failed, skip flush this round');
      return;
    }
  }

  const csrf: string = getLoginCsrf();
  if (!csrf) {
    summary.needLogin = true;
    return;
  }

  // 按 bvid 分组（同视频多夹增 / 删合并为一次 deal 调用）
  const groups: Map<string, FavPushIntent[]> = new Map<string, FavPushIntent[]>();
  for (let i = 0; i < queue.length; i++) {
    const it: FavPushIntent = queue[i];
    const g: FavPushIntent[] | undefined = groups.get(it.bvid);
    if (g !== undefined) {
      g.push(it);
    } else {
      groups.set(it.bvid, [it]);
    }
  }

  const bvids: string[] = Array.from(groups.keys());
  let callsMade: number = 0;
  let consecutiveTransient: number = 0;
  for (let i = 0; i < bvids.length; i++) {
    if (callsMade >= DEAL_MAX_PER_ROUND) {
      console.warn(`[FavPushRunner] round cap ${DEAL_MAX_PER_ROUND} reached, `
        + `${bvids.length - i} groups left for next round`);
      break;
    }
    const bvid: string = bvids[i];
    const group: FavPushIntent[] = groups.get(bvid) as FavPushIntent[];
    const rid: number = bv2av(bvid);
    if (!(rid > 0)) {
      // 非法 bvid 永远推不过去 → 丢弃，防止卡死队列
      removeFavPushes(group);
      summary.pushDropped = summary.pushDropped + group.length;
      console.warn(`[FavPushRunner] invalid bvid ${bvid}, dropped ${group.length} intents`);
      continue;
    }
    const addIds: number[] = [];
    const delIds: number[] = [];
    for (let j = 0; j < group.length; j++) {
      if (group[j].op === 'add') {
        addIds.push(group[j].mediaId);
      } else {
        delIds.push(group[j].mediaId);
      }
    }
    if (callsMade > 0) {
      await sleep(DEAL_GAP_MS);
    }
    callsMade = callsMade + 1;
    try {
      await dealFavResource(rid, addIds, delIds, csrf);
      removeFavPushes(group);
      summary.pushed = summary.pushed + group.length;
      consecutiveTransient = 0;
      console.info(`[FavPushRunner] deal ok: bvid=${bvid} rid=${rid} `
        + `add=${addIds.length} del=${delIds.length}`);
    } catch (e) {
      const err: BiliApiError | null = e instanceof BiliApiError ? e : null;
      const code: number = err !== null ? err.code : 0;
      if (err !== null && LOGIN_INVALID_CODES.indexOf(code) >= 0) {
        summary.needLogin = true;
        console.warn(`[FavPushRunner] login invalid (${code}), abort flush`);
        return;
      }
      const transient: boolean =
        (err !== null && TRANSIENT_BIZ_CODES.indexOf(code) >= 0) || err === null;
      if (transient) {
        consecutiveTransient = consecutiveTransient + 1;
        console.warn(`[FavPushRunner] transient failure #${consecutiveTransient} `
          + `on ${bvid}: ${err !== null ? `${err.code} ${err.message}` : String(e)}`);
        if (consecutiveTransient >= TRANSIENT_ABORT_STREAK) {
          console.warn('[FavPushRunner] too many transient failures, abort flush this round');
          return;
        }
        continue;
      }
      // 永久业务错误（-400 / 视频失效 / 收藏数超限等）→ 丢弃，防队列卡死
      removeFavPushes(group);
      summary.pushDropped = summary.pushDropped + group.length;
      consecutiveTransient = 0;
      console.warn(`[FavPushRunner] deal failed permanently on ${bvid}: `
        + `${err !== null ? `${err.code} ${err.message}` : String(e)}, `
        + `dropped ${group.length} intents`);
    }
  }
}
