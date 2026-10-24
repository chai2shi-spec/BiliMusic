/**
 * 收藏夹同步管理器（B 站收藏夹 → 本地歌单镜像）。
 *
 * （2026-10-23 单向同步改造：删除「本地 → B 站」推送阶段 —— 同步只有
 * B 站 → 本地一个方向。本地对镜像歌单的改动**不会写回 B 站**，并会在下一轮
 * 同步时被服务端状态覆盖；原 FavPushStore 待推送队列、写意图重放与
 * 「N 条待同步」重试整体下线，相关提示已改为「单向同步」说明。）
 *
 * 职责：串行编排一轮同步 —— 拉收藏夹列表 → 逐夹拉全内容 → 应用镜像
 * （建/合并/双向删）→ 清理 B 站已删除的收藏夹镜像 → 落状态 + 广播。
 *
 * 串行队列照抄 service/DownloadManager.ts 的 running/pending/pump 思路：
 * 并发触发会被合并为「跑完再补一轮」，避免同一次登录的多个信号重复处理。
 *
 * ⚠️⚠️ 核心安全不变量（改本文件前必读）：
 *   1. 「删除本地曲目」只在**本轮确认服务端数据完整**时才允许（allowDelete），
 *      判据三者全真：
 *        foldersOk（收藏夹列表拉到） && res.complete（该夹分页全部成功走完）
 *        && folder.mediaCount <= PLAYLIST_MAX_ITEMS
 *      任一条不满足 → 只增不减。**绝不能因为「返回 0 条」就删**：
 *      0 条 ≠ 用户清空了收藏夹，也可能只是风控把响应拦成空。判据必须是 complete 标志。
 *   2. 收藏夹**列表**都拉不到时（foldersOk=false）→ 整轮不碰本地，一条都不动，
 *      更不做「清理已删除收藏夹」（否则会把「没拉到」误判成「收藏夹没了」而删整个镜像）。
 *   3. 单夹失败不中断其它夹（标 partial），保证「能同步多少算多少」。
 */

import {
  BiliApiError,
  FavAllResult,
  FavoriteFolder,
  FavoriteFoldersResult,
  FavResourceItem,
  getAllFavResources,
  getFavoriteFolders,
  mapFavItem
} from '../api/BilibiliApi';
import { LibraryStore, PLAYLIST_MAX_ITEMS } from './LibraryStore';
import { getLoginUser, LoginUser } from './LoginStore';
import { deselectedFolderIds } from './FavSelectionStore';
import {
  FAV_SYNC_FAILED,
  FAV_SYNC_OK,
  FAV_SYNC_PARTIAL,
  FavFolderSyncState,
  getFavSyncState,
  removeFavSyncState,
  upsertFavSyncState
} from './FavSyncStore';
import { STORE_FAV_SYNC_REV } from '../common/Constants';
import { Playlist, Track } from '../model/MusicModels';

/**
 * 双向删除总开关（拉取侧：B 站取消收藏 → 本地移除，`applyFavMirror` 的
 * allowDelete 分支）。置回 `false` 即**一键回滚到「只增不减」**。
 *
 * 前置验收（方案批次 3）：B 站取消收藏一首 → 本地移除；断网/风控那一轮 → 本地一条不删；
 * 已下载曲目的 localFilePath 不脱链。
 */
const FAV_SYNC_DELETE_ENABLED: boolean = true;

/** 夹与夹之间的间隔（ms）：收藏夹接口对高频请求敏感，串行 + 间隔降风控 */
const FOLDER_GAP_MS: number = 500;
/** 页与页之间的间隔（ms） */
const PAGE_GAP_MS: number = 350;
/**
 * 连续多少个收藏夹「没能完整同步」就中止本轮（ms 无关）。
 * 收藏夹多 + 每个夹多页时请求量很大，中途开始被风控后再硬推只会让后面全部失败；
 * 3 个足够区分「单个大夹抖动」与「整体被拦」。
 */
const FAV_RISK_ABORT_STREAK: number = 3;

/** 一轮同步的汇总（供同步页展示与日志） */
export interface FavSyncSummary {
  /** 未登录（本地一条不动） */
  needLogin: boolean;
  /** 收藏夹列表是否拉到（false = 整轮未碰本地） */
  foldersOk: boolean;
  /** 本轮处理的收藏夹数 */
  total: number;
  okCount: number;
  partialCount: number;
  failedCount: number;
  /** 累计新增条目 */
  added: number;
  /** 累计移除条目（只增模式下恒 0） */
  removed: number;
  /** 因 B 站已删除而被清掉的本地镜像数 */
  deletedFolders: number;
  /** 整体失败/中止的人话原因；正常为空串 */
  reason: string;
}

/** 单夹同步结果（内部） */
interface FavFolderOutcome {
  result: string;
  added: number;
  removed: number;
}

function emptySummary(): FavSyncSummary {
  return {
    needLogin: false,
    foldersOk: false,
    total: 0,
    okCount: 0,
    partialCount: 0,
    failedCount: 0,
    added: 0,
    removed: 0,
    deletedFolders: 0,
    reason: ''
  };
}

/** 把异常转成人话（含 code，便于用户判断该等还是该换网） */
function humanError(e: ESObject): string {
  if (e instanceof BiliApiError) {
    return `接口返回 ${e.code}${e.message ? `（${e.message}）` : ''}`;
  }
  if (e instanceof Error) {
    return e.message;
  }
  return JSON.stringify(e);
}

/** -101 = 未登录 / SESSDATA 失效：确定性错误，应中止整轮并提示去重登 */
function isLoginInvalid(e: ESObject): boolean {
  return e instanceof BiliApiError && e.code === -101;
}

export class FavSyncManager {
  private static instance: FavSyncManager | null = null;
  private running: boolean = false;
  private pending: string = '';
  private last: FavSyncSummary | null = null;

  static getInstance(): FavSyncManager {
    if (FavSyncManager.instance === null) {
      FavSyncManager.instance = new FavSyncManager();
    }
    return FavSyncManager.instance;
  }

  /** 是否正在同步（同步页据此显示进度态） */
  isRunning(): boolean {
    return this.running;
  }

  /** 上一轮完整同步的汇总（未跑过返回 null） */
  getLastSummary(): FavSyncSummary | null {
    return this.last;
  }

  /**
   * 触发一轮同步（fire-and-forget）。
   * 重入：正在跑时记成 pending，跑完自动补一轮 —— 避免同一次登录的多次信号重复处理。
   */
  syncAll(reason: string): void {
    if (this.running) {
      this.pending = reason;
      return;
    }
    this.running = true;
    this.bump();
    this.runAndCleanup(reason);
  }

  private runAndCleanup(reason: string): void {
    this.run(reason)
      .then((s: FavSyncSummary): void => {
        this.last = s;
      })
      .catch((e: ESObject): void => {
        console.error(`fav sync crashed: ${humanError(e)}`);
      })
      .then((): void => {
        this.running = false;
        this.bump();
        const next: string = this.pending;
        this.pending = '';
        if (next.length > 0) {
          this.syncAll(next);
        }
      });
  }

  private bump(): void {
    const cur: number = AppStorage.get<number>(STORE_FAV_SYNC_REV) ?? 0;
    AppStorage.setOrCreate(STORE_FAV_SYNC_REV, cur + 1);
  }

  /** 一轮同步主体：拉收藏夹列表 → 逐夹同步 → 清理已删除夹 */
  private async run(reason: string): Promise<FavSyncSummary> {
    const summary: FavSyncSummary = emptySummary();

    const user: LoginUser | null = getLoginUser();
    if (user === null || !(user.mid > 0)) {
      // 有 Cookie 但用户信息还没拉到（nav 未回）→ 不碰本地，等下次
      summary.needLogin = true;
      summary.reason = '用户信息未就绪';
      return summary;
    }

    // ① 拉收藏夹列表。失败 → 整轮不碰本地（含不做「清理已删除收藏夹」）
    let folders: FavoriteFolder[] = [];
    try {
      const r: FavoriteFoldersResult = await getFavoriteFolders(user.mid);
      folders = r && r.list ? r.list : [];
      summary.foldersOk = true;
    } catch (e) {
      summary.reason = humanError(e);
      console.warn(`fav sync: getFavoriteFolders failed: ${summary.reason}`);
      return summary;
    }

    /**
     * ①-b 按勾选过滤（2026-10-23 手动选择性同步）：未勾选的收藏夹不参与本轮同步。
     *
     * ⚠️ 过滤只影响「逐夹同步」；下方 pruneDeletedFolders 仍传**全量** folders ——
     *    「未勾选」≠「B 站已删除」，未勾选夹的本地镜像必须原样保留
     *    （否则一取消勾选，镜像连同里面的歌就被「清理」了）。
     */
    const deselected: Set<number> = deselectedFolderIds();
    const enabled: FavoriteFolder[] =
      folders.filter((f: FavoriteFolder): boolean => !deselected.has(f.id));
    summary.total = enabled.length;
    console.info(`fav sync(${reason}): folders=${folders.length} selected=${enabled.length}`);

    if (enabled.length === 0) {
      // 一个夹都没勾：整轮 no-op（不跑「清理已删除夹」—— 全不勾选的语义就是「什么都不做」）
      summary.reason = '没有勾选任何收藏夹，到「收藏夹同步」页勾选后再同步';
      return summary;
    }

    // ② 逐夹串行处理
    let loginLost: boolean = false;
    /**
     * 连续「没能完整同步」的夹数 —— 达上限即**主动中止本轮**（2026-10-22）。
     *
     * 场景：账号收藏夹很多（20+）且每个夹多页时，一轮下来请求数可达上百，
     * 很容易在中间某个夹开始被风控（空壳 / 412）。若继续硬推，后面的夹会**全部**失败，
     * 用户看到的就是「一排 0 首」。停下来让风控冷却，比把每个夹都打一遍更有价值
     * —— 已同步的夹结果保留，下一次「立即同步」从剩下的继续（失败夹不写状态、不删本地）。
     */
    let consecutiveBad: number = 0;
    let abortedByRisk: boolean = false;
    for (let i = 0; i < enabled.length; i++) {
      const folder: FavoriteFolder = enabled[i];
      try {
        const outcome: FavFolderOutcome = await this.syncFolder(folder, summary.foldersOk);
        summary.added = summary.added + outcome.added;
        summary.removed = summary.removed + outcome.removed;
        if (outcome.result === FAV_SYNC_OK) {
          summary.okCount = summary.okCount + 1;
          consecutiveBad = 0;
        } else if (outcome.result === FAV_SYNC_PARTIAL) {
          summary.partialCount = summary.partialCount + 1;
          consecutiveBad = consecutiveBad + 1;
        } else {
          summary.failedCount = summary.failedCount + 1;
          consecutiveBad = consecutiveBad + 1;
        }
      } catch (e) {
        summary.failedCount = summary.failedCount + 1;
        consecutiveBad = consecutiveBad + 1;
        console.warn(`fav sync: folder ${folder.id} failed: ${humanError(e)}`);
        upsertFavSyncState({
          mediaId: folder.id,
          title: folder.title,
          playlistId: this.existingPlaylistId(folder.id),
          lastSyncAt: Date.now(),
          lastResult: FAV_SYNC_FAILED,
          lastReason: humanError(e),
          lastItemCount: this.existingItemCount(folder.id)
        });
        if (isLoginInvalid(e)) {
          loginLost = true;
          break;
        }
      }
      if (consecutiveBad >= FAV_RISK_ABORT_STREAK) {
        abortedByRisk = true;
        console.warn(`fav sync: 连续 ${consecutiveBad} 个收藏夹未能完整同步，本轮提前结束（已处理 ${i + 1}/${enabled.length}）`);
        break;
      }
      // 夹间间隔（降风控）
      if (i < enabled.length - 1) {
        await this.sleep(FOLDER_GAP_MS);
      }
    }

    if (loginLost) {
      summary.reason = '登录已失效，请重新登录后再同步';
      return summary;
    }
    if (abortedByRisk) {
      summary.reason = `连续 ${FAV_RISK_ABORT_STREAK} 个收藏夹未能完整同步（疑似风控），本轮提前结束；`
        + '已同步的收藏夹已保留，请等几分钟后再点「立即同步」继续';
    }

    // ③ 清理 B 站已删除的收藏夹镜像（⚠️ 只在收藏夹列表成功拉到时做）。
    //    ⚠️ 传**全量** folders 而非勾选过滤后的 enabled：清理的判据是
    //    「B 站侧已不存在」，与「用户是否勾选同步」无关（见 ①-b 注释）。
    summary.deletedFolders = this.pruneDeletedFolders(folders);
    return summary;
  }

  /** 处理单个收藏夹：拉全 → 映射 → 应用镜像 → 落状态 */
  private async syncFolder(folder: FavoriteFolder, foldersOk: boolean): Promise<FavFolderOutcome> {
    const mediaId: number = folder.id;
    // media_id 缺失时绝不去请求 `media_id=0`（会拿到空响应 → 误判「收藏夹空了」/ 建出空镜像）
    if (!(mediaId > 0)) {
      console.warn(`fav sync: folder skipped, invalid id=${mediaId} title=${folder.title}`);
      upsertFavSyncState({
        mediaId: 0,
        title: folder.title,
        playlistId: '',
        lastSyncAt: Date.now(),
        lastResult: FAV_SYNC_FAILED,
        lastReason: '收藏夹 id 缺失（接口字段异常），本轮跳过',
        lastItemCount: 0
      });
      return { result: FAV_SYNC_FAILED, added: 0, removed: 0 };
    }
    // 本地已有镜像 → 把已有 bvid 喂给两段式通道，只补「新增条目」的详情（不再整夹重拉）
    const mirror: Playlist | null = LibraryStore.getFavMirrorByMediaId(mediaId);
    const knownBvids: string[] = [];
    const localById: Map<string, Track> = new Map<string, Track>();
    if (mirror !== null) {
      for (let i = 0; i < mirror.tracks.length; i++) {
        const lt: Track = mirror.tracks[i];
        knownBvids.push(lt.id);
        localById.set(lt.id, lt);
      }
    }

    const res: FavAllResult =
      await getAllFavResources(mediaId, PLAYLIST_MAX_ITEMS, PAGE_GAP_MS, knownBvids);

    // 映射成 Track
    const tracks: Track[] = [];
    let invalidCount: number = 0;
    if (res.usedIdsChannel) {
      /**
       * 两段式通道（移植自 BBPlayer）：`items` 只含**本轮新拉到的详情**，
       * 完整顺序与全集在 `orderedBvids` 里；本地已有的条目直接用本地 Track 补字段，
       * 从而在不重拉整夹的前提下拿到与服务端一致的顺序。
       */
      const detailMap: Map<string, FavResourceItem> = new Map<string, FavResourceItem>();
      for (let i = 0; i < res.items.length; i++) {
        detailMap.set(res.items[i].bvid, res.items[i]);
      }
      for (let i = 0; i < res.orderedBvids.length; i++) {
        const bvid: string = res.orderedBvids[i];
        const d: FavResourceItem | undefined = detailMap.get(bvid);
        if (d !== undefined) {
          tracks.push(mapFavItem(d, folder.title));
          continue;
        }
        const lt: Track | undefined = localById.get(bvid);
        if (lt !== undefined) {
          tracks.push(lt);
        }
      }
      invalidCount = res.hiddenBvids.length;
    } else {
      // 兜底通道：`items` 即全量
      for (let i = 0; i < res.items.length; i++) {
        const it: FavResourceItem = res.items[i];
        if (!it.invalid) {
          tracks.push(mapFavItem(it, folder.title));
        } else {
          invalidCount = invalidCount + 1;
        }
      }
    }

    // 删除安全门控（见文件头核心不变量）
    const sizeOk: boolean = folder.mediaCount <= PLAYLIST_MAX_ITEMS;
    /** 本地已有条数（镜像实际条数优先，原因见 existingItemCount 注释） */
    const localCount: number = this.existingItemCount(mediaId);
    /**
     * 「上游 0 条」永不作为删除依据（2026-10-22 再放宽）。
     * 只要**本地还有内容**，服务端回 0 条就一律可疑（风控空壳 / 解析失效 / media_count 缺失）。
     * 旧判据只认 `folder.mediaCount > 0`：一旦 list-all 把 `media_count` 给成 0 或缺失，
     * 这道门控就整体失效 —— 这是「收藏夹镜像突然变空」的另一条路径。
     */
    const emptySuspect: boolean = tracks.length === 0 && (folder.mediaCount > 0 || localCount > 0);
    const allowDelete: boolean =
      FAV_SYNC_DELETE_ENABLED && foldersOk && res.complete && sizeOk && !emptySuspect;
    console.info(`fav sync: folder ${mediaId}(${folder.title}) mediaCount=${folder.mediaCount}`
      + ` channel=${res.usedIdsChannel ? 'ids' : 'pages'} pages=${res.pages} reported=${res.reportedTotal}`
      + ` ordered=${res.orderedBvids.length} hidden=${res.hiddenBvids.length} raw=${res.items.length}`
      + ` invalid=${invalidCount} tracks=${tracks.length} local=${localCount}`
      + ` complete=${res.complete} sizeOk=${sizeOk} emptySuspect=${emptySuspect} allowDelete=${allowDelete}`);

    // 空收藏夹且本地还没有镜像 → 跳过建单（不建永远空着的壳），只记状态
    const hasMirror: boolean = mirror !== null;
    if (tracks.length === 0 && !hasMirror) {
      // ⚠️ 没拉全却一条也没有 → 不能记「已同步（空收藏夹）」，要让用户看到黄标 + 原因
      const emptyOk: boolean = res.complete && !emptySuspect;
      upsertFavSyncState({
        mediaId: mediaId,
        title: folder.title,
        playlistId: '',
        lastSyncAt: Date.now(),
        lastResult: emptyOk ? FAV_SYNC_OK : FAV_SYNC_PARTIAL,
        lastReason: emptyOk ? '' : (res.failReason.length > 0 ? res.failReason : '本轮一条都没拿到'),
        lastItemCount: 0
      });
      return { result: emptyOk ? FAV_SYNC_OK : FAV_SYNC_PARTIAL, added: 0, removed: 0 };
    }

    const r = LibraryStore.applyFavMirror(folder.title, mediaId, tracks, allowDelete);

    // res.complete=false 只代表「没拉全」，不算失败（本地已按只增合并）→ 标 partial
    const result: string = (res.complete && !emptySuspect) ? FAV_SYNC_OK : FAV_SYNC_PARTIAL;
    const reasonText: string = emptySuspect
      ? `服务端报告 ${folder.mediaCount} 首，本轮一条也没拿到（疑似风控），本地未做删除`
      : (res.complete ? '' : res.failReason);
    upsertFavSyncState({
      mediaId: mediaId,
      title: folder.title,
      playlistId: r.playlist ? r.playlist.id : '',
      lastSyncAt: Date.now(),
      lastResult: result,
      lastReason: reasonText,
      // 未拉全时不更新 lastItemCount（保留上次完整值，避免把「没拉到」写成「变少了」）
      lastItemCount: (res.complete && !emptySuspect) ? tracks.length : this.existingItemCount(mediaId)
    });
    return { result: result, added: r.added, removed: r.removed };
  }

  /**
   * 清理「B 站已删除」的收藏夹镜像。
   * ⚠️ 调用前置条件：folders 是本轮成功拉到的完整列表。调用方已保证。
   */
  private pruneDeletedFolders(folders: FavoriteFolder[]): number {
    const live: Set<number> = new Set<number>();
    for (let i = 0; i < folders.length; i++) {
      live.add(folders[i].id);
    }
    const mirrors: Playlist[] = LibraryStore.getPlaylists()
      .filter((p: Playlist): boolean => LibraryStore.isFavMirror(p));
    /**
     * ⚠️ 列表完整性自检（2026-10-22）：服务端返回的收藏夹数**少于本地镜像数**时，
     * 更可能是「列表被截断 / 只回了公开夹」而不是「用户把夹子都删了」。
     * 此时若照常清理，会把没出现在列表里的镜像歌单**连同其中的歌一起删掉** ——
     * 用户看到的现象就是「收藏夹突然空了」。宁可这轮不清理（下次同步再对齐）。
     */
    if (folders.length < mirrors.length) {
      console.warn(`fav sync: prune skipped, folders=${folders.length} < mirrors=${mirrors.length}（列表疑似不完整）`);
      return 0;
    }
    let deleted: number = 0;
    for (let i = 0; i < mirrors.length; i++) {
      const mediaId: number = LibraryStore.favMediaIdOf(mirrors[i]);
      if (mediaId > 0 && !live.has(mediaId)) {
        LibraryStore.deletePlaylist(mirrors[i].id);
        removeFavSyncState(mediaId);
        deleted = deleted + 1;
        console.info(`fav sync: pruned mirror for deleted folder ${mediaId}`);
      }
    }
    return deleted;
  }

  /** 已有镜像歌单的 id（失败时写状态用，拿不到给空串） */
  private existingPlaylistId(mediaId: number): string {
    const p: Playlist | null = LibraryStore.getFavMirrorByMediaId(mediaId);
    return p ? p.id : '';
  }

  /**
   * 「本地已有多少首」——用于「没拉全时不覆盖计数」。
   *
   * ⚠️ 必须同时看**镜像歌单的实际条数**（2026-10-22 修「同步页显示 0 首」）：
   * 旧实现只读 `FavFolderSyncState.lastItemCount`，而首次同步时该状态还不存在 → 恒 0。
   * 于是一旦首轮没拉全（多页收藏夹 + 风控 / 网络抖动，`complete=false`），
   * 就会把「已经建好、里面有 20 首」的镜像状态写成 `lastItemCount=0`，
   * 同步页显示「0 首」——用户以为收藏夹空了，其实歌全在。
   */
  private existingItemCount(mediaId: number): number {
    const s: FavFolderSyncState | null = getFavSyncState(mediaId);
    const recorded: number = s ? s.lastItemCount : 0;
    const mirror: Playlist | null = LibraryStore.getFavMirrorByMediaId(mediaId);
    const actual: number = mirror ? mirror.tracks.length : 0;
    return recorded > actual ? recorded : actual;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }
}
