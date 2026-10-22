/**
 * UP 主主页（站内）：显示 UP 的资料 + 投稿列表，并可把投稿**订阅成持续更新的歌单**。
 *
 * 为什么是站内页而不是跳 B 站：订阅要在 App 内落成可维护的歌单，
 * 跳出去就没法「拉取新投稿」，也就没有 C 方案的意义。
 *
 * 数据来源（2026-10-03 匿名态实测，均可用）：
 *  · 资料 `getUserCard`（x/web-interface/card）—— **不要用 space/wbi/acc/info**，
 *    那个匿名只回 v_voucher，字段全空；
 *  · 投稿 `getUserVideos`（x/space/wbi/arc/search，30 条/页，真分页）。
 *
 * 入参走路由参数 UpSpaceRouteParam（pushPathByName 入栈，upMid 必填、
 * upName 兜底、upFace 首帧占位），与 PlaylistDetail 同套约定。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，stackBuilder 承载
 * 返回行 + UP 资料头部区，批 1 样板同款）；侧滑返回是 Navigation 级能力，不受影响。
 *
 * 布局与 **PlaylistDetail 完全同款**（2026-10-06 对齐）：
 *  · 头部区「96vp 头像 + 28fp 大标题 + 元信息 + 播放全部/订阅按钮」整体在栏内，
 *    UP 昵称只在头部区显示一次，返回行仅一颗返回键；
 *  · 列表走「首个空白占位 ListItem」**穿透模式**（下载页同款）——视口铺满全屏，
 *    首项从标题栏底部起排，滚动时条目从沉浸材质下穿过，滚动模糊由 HDS scrollEffectOpts 接管；
 *  · 非列表分支（骨架 / 失败 / 空态）没有占位条目，各自补 padding top。
 *
 * 缓存策略（2026-10-09）：进页**不自动联网刷新**——命中 UpSpaceCacheStore 落盘缓存
 * 就直接恢复列表 + 资料 + 分页游标（重启 App 仍生效）；只有两个显式动作才联网：
 *  · 头部「拉取新投稿」：取最新投稿 → 并入订阅歌单 + 本页列表同步换新 + 重写缓存；
 *  · 列表下拉刷新（Refresh 包 List）：强制重拉第一页与资料。
 * 无缓存（首次进入）仍走 loadCard + loadPage(1) 联网加载，成功后落盘。
 *
 * 投稿搜索（2026-10-23，A+B 混合）：头部搜索框输入即**本地过滤**已加载列表
 * （标题/歌手匹配，离线可用）；Enter /「搜索」按钮走 `searchUpVideosByKeyword`
 * （B 站全站搜关键词 → 按 mid 过滤回该 UP 的投稿，可覆盖未加载页，3 页上限）。
 * 渲染源三态切换见 displayTracks()；搜索态不落缓存、不参与翻页。
 */

import * as BilibiliApi from '../api/BilibiliApi';
import { SpaceVideo } from '../api/BilibiliApi';
import { Track, buildTrack } from '../model/MusicModels';
import { LibraryStore, UpSubscribeResult } from '../service/LibraryStore';
import { UpSpaceCacheEntry, getUpSpaceCache, saveUpSpaceCache } from '../service/UpSpaceCacheStore';
import { DownloadManager, DownloadStartResult, WIFI_ONLY_BLOCKED } from '../service/DownloadManager';
import { currentNetworkLabel } from '../utils/NetworkUtil';
import { NavStackHolder } from '../service/NavStackHolder';
import { UpSpaceRouteParam, NavRouteParamReader } from '../service/NavRouteParams';
import { MusicPlayer } from '../player/MusicPlayer';
import { TrackItem } from '../components/TrackItem';
import { SkeletonTrackItem } from '../components/SkeletonTrackItem';
import { CoverImage } from '../components/CoverImage';
import { toHttpsUrl, toThumbUrl, stripHtmlTags, parseDurationText } from '../utils/TextUtil';
import { HttpUtil } from '../utils/HttpUtil';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { HdsNavDestination, BottomBuilderShowType } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier
} from '../utils/HeaderBarMaterial';
import { common } from '@kit.AbilityKit';
import { CONTENT_END_OFFSET, STORE_SAFE_BOTTOM, STORE_SAFE_TOP, STORE_THEME_PRIMARY, STORE_THEME_SURFACE, STORE_THEME_DEEP, STORE_THEME_ON } from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import {
  NAV_TRANSITION_MS,
  BUTTON_RADIUS_VP,
  LIST_FOOTER_HEIGHT_VP
} from '../common/constants/InteractionConstants';
import { showAppToast } from '../components/AppToast';
import { showAppAlertDialog } from '../components/AppAlertDialog';
import { NavTitleRow } from '../components/NavTitleRow';

/** 每页投稿数：匿名 30；登录态走空间接口可吃满 50（该接口 ps 上限） */
const PAGE_SIZE_ANON: number = 30;
const PAGE_SIZE_LOGGED_IN: number = 50;
/** 失败后「重试」的冷却（ms）：B 站这类接口按 IP 限流，连点只会继续被拒 */
const RETRY_COOLDOWN_MS: number = 4000;

/**
 * 顶栏滚动模糊时机（基准口径 = 关于页）：
 * 首条内容自静止位上移 30vp 起雾 → 80vp 满显影。
 * ⚠️ −C 补偿路径已验证失败（2026-10-09 真机签名②：负值被 HDS 钳制，起雾仍在条目出屏后），
 * 第三参已回退；待 RecentPage 的 padding 让位迁移（回退 B）真机通过后同法迁移本页。
 */
const UP_BLUR_START_VP: number = 30;
const UP_BLUR_END_VP: number = 80;

/**
 * UP 资料头部区（bottomBuilder 承载）实测前的估计高度：头像行 + 元信息行 + padding。
 * ⚠️ bottomBuilder 高度不自适应（官方约束），由 titleBar 参数显式给定；实测值
 * （headerAreaHeight）回来后覆盖，此值只防首次布局 0 高闪跳。
 * 2026-10-22 头部区间距 top 12→4、bottom 16→8 后同步 -16。
 * 2026-10-23 搜索框行加入（40 高 + 12 上边距）：154 → 206。
 */
const UP_HEADER_ESTIMATE_HEIGHT: number = 206;

/** `mm:ss` / `hh:mm:ss` → 秒（SpaceVideo.length 是字符串；榜单是秒数，两种都认） */
function spaceDuration(raw: string): number {
  return parseDurationText(raw);
}

/** UP 投稿 → 曲目。upMid / upName 由列表所在 UP 决定（投稿条目自身不带 mid） */
function mapSpaceVideo(v: SpaceVideo, upMid: string, upName: string): Track {
  return buildTrack({
    id: v.bvid,
    bvid: v.bvid,
    aid: String(v.aid ?? 0),
    title: stripHtmlTags(v.title),
    artist: v.author || upName,
    upMid: upMid,
    coverUrl: toHttpsUrl(v.pic),
    duration: spaceDuration(v.length),
    playCount: v.play ?? 0,
    pubdate: v.created || 0
  });
}

/** 粉丝数：超过 1 万折成「x.x 万」，过亿折成「x.x 亿」（避免 8 位数字撑破布局） */
function formatFans(fans: number): string {
  if (fans >= 100000000) {
    return `${(fans / 100000000).toFixed(1)} 亿`;
  }
  if (fans >= 10000) {
    return `${(fans / 10000).toFixed(1)} 万`;
  }
  return `${fans}`;
}

@Component
export struct UpSpacePage {
  /** UP 主 id（进入本页的必填入参） */
  @State upMid: string = '';
  @State upName: string = '';
  @State upFace: string = '';
  @State fans: number = 0;
  /** UP 投稿总数（card 的 archive_count，缓存持久化）；0 = 未知（旧缓存 / 卡片失败） */
  @State archiveCount: number = 0;
  @State tracks: Track[] = [];
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State page: number = 1;
  @State hasMore: boolean = true;
  /** 资料 / 列表是否都失败了（空态区分「没有投稿」与「拉不到」） */
  @State loadFailed: boolean = false;
  /**
   * 失败原因（人话）。
   *
   * 之前这里只有一句「检查网络后再试一次」，但真机失败的原因完全不是网络：
   * B 站的空间接口对匿名访问风控很严（-352 风控校验失败 / -799 请求过于频繁 / HTTP 412），
   * 把 code 显示出来才知道该等风控过去还是该换网络。
   */
  @State failReason: string = '';
  /** 是否已订阅（进页面时按 upMid 查一次本地库） */
  @State subscribed: boolean = false;
  @State subscribedCount: number = 0;
  /** 订阅 / 拉新进行中：按钮禁用并显示「处理中…」 */
  @State subBusy: boolean = false;
  /** 重试冷却中：按钮禁用（真正的门在 retryLocked 成员，状态只是给用户看的） */
  @State retryCooling: boolean = false;
  /** 下拉刷新进行中（Refresh 双向绑定 $$refreshing，forceRefresh 复位） */
  @State refreshing: boolean = false;
  // ===== 投稿搜索（2026-10-23：本地过滤 + B 站按 mid 过滤搜索，A+B 混合）=====
  /** 搜索框文本：输入即本地过滤已加载列表（onChange 重算）；Enter/「搜索」触发 B 站搜索 */
  @State searchKeyword: string = '';
  /** 本地过滤结果（keyword 变化即时重算；keyword 为空 = 不过滤，此数组为空占位） */
  @State filteredTracks: Track[] = [];
  /** B 站搜索在途（footer 显示「正在 B 站搜索…」） */
  @State remoteSearching: boolean = false;
  /**
   * B 站搜索结果（**null = 不在远程搜索态**，这是态开关本体；
   * 非 null 时空数组也有效 = 「B 站确实没搜到该 UP 的相关投稿」）。
   */
  @State remoteResults: Track[] | null = null;
  /** B 站搜索失败原因（人话，describeError 翻译；空串 = 没失败） */
  @State remoteFailReason: string = '';
  /** 搜索竞态令牌：只认最新一次搜索/清除（照 SearchPage.searchToken 纪律，旧响应丢弃） */
  private searchToken: number = 0;
  private retryLocked: boolean = false;
  private retryTimer: number = -1;
  /**
   * 最近一次取投稿走的是哪条路（`BilibiliApi.UP_VIA_*`）。
   *
   * 决定失败文案：「某条路通了但没命中」≠「三条路全被拒」，两者给用户的话完全不同
   * （前者该换 UP，后者该等一会儿再来）。
   */
  private sourceVia: number = BilibiliApi.UP_VIA_NONE;
  /**
   * `collectTracks()` 最后一次的失败原因（空串 = 没失败）。
   * 普通成员即可（不驱动 UI，只在提示文案里被读一次）。
   */
  private lastCollectError: string = '';

  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;

  /** 主题色运行时值：操作按钮与订阅按钮跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /**
   * UP 资料头部区实测高（vp，bottomBuilder 内层根节点 onAreaChange 回写，随元信息行数浮动）。
   * ⚠️ 初值必须为 0（2026-10-08 同款教训）：列表带着初值一起挂载会让占位条目先按
   * 不含头部区的让位量排布、实测回来再整体下移（内容跳变）——列表挂载门控直接判
   * headerAreaHeight > 0（barTotalHeight() 恒 > 0 不能当门控），即头部区首次实测
   * 完成后才挂载列表，保证让位量含头部实测高。
   */
  @State headerAreaHeight: number = 0;
  /** 投稿列表滚动控制器：bindToScrollable 绑给 HDS 标题栏驱动滚动模糊 */
  private listScroller: Scroller = new Scroller();
  /** 头部按钮（播放全部 / 订阅·拉取新投稿）沉浸光感材质修饰器：26+ 生效，低版本 no-op 显实色兜底 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();

  /**
   * HDS 标题栏整体让位量（vp）= safeTop + 标题行 56 + 头部区实测高。
   * 头部区高度随元信息行数浮动，无法定值，沿用「实测 + 挂载门控」机制。
   */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT + this.headerAreaHeight;
  }

  private player: MusicPlayer = MusicPlayer.getInstance();
  /** 子页转场横移量：常驻 '0%'，转场代理按 push/pop 临时改写 */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    // 路由入参（2026-10-22 传参改造）：显式参数类随 pushPathByName 入栈，
    // 读取器内部 getParamByName 取回 + instanceof 判型（返回已判型对象或 null）。
    const routeParam: UpSpaceRouteParam | null =
      NavRouteParamReader.readUpSpaceParam(NavStackHolder.stack);
    const mid: string = routeParam !== null ? routeParam.upMid : '';
    this.upMid = mid;
    this.upName = routeParam !== null ? routeParam.upName : '';
    // 入口方若已拿到头像（搜 UP 主结果）就先垫上，loadCard 拿到真图后会覆盖
    this.upFace = routeParam !== null ? routeParam.upFace : '';
    if (mid.length === 0) {
      this.loadFailed = true;
      this.failReason = '没有拿到 UP 主信息，请从列表里重新进入';
      return;
    }
    this.refreshSubscriptionState();
    // （2026-10-16 AppFreeze 加固）缓存读取改异步（getUpSpaceCache 返回 Promise）：
    // 恢复逻辑挪进 async 方法，aboutToAppear 不再同步读文件，页面挂载零阻塞。
    this.restoreFromCache().catch((): void => {
      // 读缓存异常按无缓存兜底：直接联网拉取
      this.loadCard();
      this.loadPage(1);
    });
  }

  /**
   * 缓存命中（2026-10-09）：直接恢复，不打任何接口 —— loadCard / loadPage 都跳过，
   * 刷新只留两个显式出口：头部「拉取新投稿」按钮、列表下拉刷新（forceRefresh）。
   * 头像用缓存真图（歌单入口传的是空串占位）；上拉翻页从缓存 page+1 续拉。
   * （2026-10-16 AppFreeze 加固）readText 移到异步任务里执行，读完再决定恢复 / 联网。
   */
  private async restoreFromCache(): Promise<void> {
    const cached: UpSpaceCacheEntry | null = await getUpSpaceCache(this.upMid);
    if (cached !== null) {
      if (cached.upName.length > 0) {
        this.upName = cached.upName;
      }
      if (cached.upFace.length > 0) {
        this.upFace = cached.upFace;
      }
      this.fans = cached.fans;
      if (cached.archiveCount > 0) {
        this.archiveCount = cached.archiveCount;
      }
      this.tracks = cached.tracks;
      this.page = cached.page;
      this.hasMore = cached.hasMore;
      this.sourceVia = cached.sourceVia;
      this.loadFailed = false;
      this.failReason = '';
      return;
    }
    this.loadCard();
    this.loadPage(1);
  }

  aboutToDisappear(): void {
    // 定时器必须清：否则离开页面后回调仍会写状态
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  /** 本地是否已有该 UP 的订阅歌单（决定按钮显示「订阅」还是「拉取新投稿」） */
  private refreshSubscriptionState(): void {
    const existing = LibraryStore.getPlaylistByUpMid(this.upMid);
    this.subscribed = existing !== null;
    this.subscribedCount = existing ? existing.tracks.length : 0;
  }

  // ===== 数据加载 =====

  /**
   * 写缓存：当前列表 + 资料 + 分页游标整表落盘。
   * tracks / upMid 为空时 no-op（loadCard 先于列表返回时不够一格完整缓存，
   * 等列表成功后由 loadFirstMultiSource 写全量）。
   * （2026-10-16 AppFreeze 加固）落盘已改异步，失败在 saveUpSpaceCache 内部记日志，
   * 调用方不等待、不受影响。
   */
  private saveToCache(): void {
    if (this.upMid.length === 0 || this.tracks.length === 0) {
      return;
    }
    saveUpSpaceCache({
      upMid: this.upMid,
      upName: this.upName,
      upFace: this.upFace,
      fans: this.fans,
      archiveCount: this.archiveCount,
      tracks: this.tracks,
      page: this.page,
      hasMore: this.hasMore,
      sourceVia: this.sourceVia,
      cachedAtMs: Date.now()
    }).catch((): void => {
      // 内部已记日志，这里只兜住 rejection 防止未处理异常
    });
  }

  /**
   * 每页条数（登录感知）：登录态空间接口风控缓解、ps 上限 50，吃满大页；
   * 匿名态维持 30（现状）。页面生命周期内登录态可能变化，按调用时取值。
   */
  private pageSize(): number {
    return HttpUtil.getLoginCookie().length > 0 ? PAGE_SIZE_LOGGED_IN : PAGE_SIZE_ANON;
  }

  /**
   * UP 资料。**失败不阻塞列表**：昵称缺失只影响头部那几行字，
   * 投稿列表是本页主体，所以 card 失败只记日志（并保留 NavStackHolder 传进来的兜底昵称）。
   */
  private loadCard(): void {
    BilibiliApi.getUserCard(Number(this.upMid))
      .then((card: BilibiliApi.UserCard | null): void => {
        if (!card) {
          console.warn('up card empty');
          return;
        }
        this.upName = card.name.length > 0 ? card.name : this.upName;
        this.upFace = card.face;
        this.fans = card.fans;
        // 投稿总数（2026-10-23 用户需求：订阅态元信息行显示 UP 的投稿数而非订阅歌单曲目数）
        if (card.archiveCount > 0) {
          this.archiveCount = card.archiveCount;
        }
        // 资料补全后同步进缓存（列表已加载时更新缓存内 profile；列表为空时 no-op）
        this.saveToCache();
      })
      .catch((e: Error): void => {
        // 匿名态被风控时这张卡会失败，属预期内：头部退回「只有昵称」的简版
        console.error(`getUserCard failed: ${e.message}`);
      });
  }

  /**
   * 拉一页投稿。
   *
   * ⚠️ 与 SearchPage 的 onReachEnd 同款纪律：**三重闸门**（loading / loadingMore / 无更多）
   * 少一个，短列表在首帧布局时就会连环触发，一口气把后面几页全拉下来。
   *
   * 加载策略（第一页与后续页走不同路子）：
   *   · 第一页走 `collectUpVideos`（登录态：空间接口优先，失败落回 搜索反查 → related；
   *     匿名态：搜索反查 → related → 空间接口），策略只在 `BilibiliApi` 里维护一份；
   *   · 只有**空间接口**支持真分页，所以数据来自搜索 / related 时不支持上拉翻页
   *     （`hasMore` 直接置 false），底部提示改成「仅显示最近投稿 · 订阅可持续获取新投稿」。
   */
  private async loadPage(pn: number): Promise<void> {
    if (this.loading || this.loadingMore) {
      return;
    }
    if (pn === 1) {
      this.loading = true;
      await this.loadFirstMultiSource();
      this.loading = false;
      return;
    }
    this.loadingMore = true;
    await this.loadPageViaSpace(pn);
    this.loadingMore = false;
  }

  /**
   * 从已有曲目里取出 bvid 当 related 扩散的种子（最多 4 个，实际只用前 2 个）。
   *
   * 首次进页面时 `tracks` 为空 → 没有种子 → related 这条路自动跳过，由搜索 / 空间接口兜住。
   */
  private seedBvids(tracks: Track[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < tracks.length && out.length < 4; i++) {
      const bvid: string = tracks[i].bvid;
      if (bvid.length > 0 && out.indexOf(bvid) < 0) {
        out.push(bvid);
      }
    }
    return out;
  }

  /**
   * 第一页：三级兜底取投稿。
   *
   * 为什么不再用旧的「搜索空 → 空间接口」两级：搜索是按**视频内容**匹配的，
   * UP 昵称不出现在标题里时命中就是 0，旧代码这时会直接掉进风控最强的空间接口
   * （实测间隔 20s 打 4 次也只成功 2 次）。related 扩散不需要任何关键词，
   * 且匿名稳定（连打 3 次 3/3 code=0，40 条里同 UP 的占 11~20 条），正好补上这一格。
   */
  private async loadFirstMultiSource(): Promise<void> {
    const res: BilibiliApi.UpVideosCollectResult =
      await BilibiliApi.collectUpVideos(this.upMid, this.upName, this.seedBvids(this.tracks), this.pageSize());
    this.sourceVia = res.via;
    console.info(`up space: via=${res.via}, got ${res.list.length} videos`);
    if (res.list.length === 0) {
      this.loadFailed = true;
      this.failReason = res.reason.length > 0
        ? `B 站暂时没返回投稿：${res.reason}`
        : 'B 站暂时没返回该 UP 的投稿';
      return;
    }
    this.tracks = this.mapAll(res.list);
    // 搜索态下的刷新也要让过滤视图跟上新列表（keyword 为空时是 no-op）
    this.applyLocalFilter();
    this.page = 1;
    // 只有空间接口能真分页；搜索 / related 拿到的就是这一批
    this.hasMore = res.via === BilibiliApi.UP_VIA_SPACE && res.list.length >= this.pageSize();
    this.loadFailed = false;
    this.failReason = '';
    this.saveToCache();
  }

  /**
   * 翻页路径：空间接口（带 3 次重试）。
   *
   * 只有空间接口支持真分页，所以 pn>1 只能走这里（`loadFirstMultiSource` 里
   * 数据来自搜索 / related 时会把 `hasMore` 置 false，根本不会走到这）。
   * pn 必须一路透传到 `getUserVideosWithRetry` → `getUserVideos`（2026-10-11 修：
   * 旧代码包装层丢页码、恒取第 1 页，上拉翻页把同一批条目反复追加，缓存里全是重复）。
   */
  private async loadPageViaSpace(pn: number): Promise<void> {
    try {
      const vlist: SpaceVideo[] = await BilibiliApi.getUserVideosWithRetry(
        Number(this.upMid), pn, this.pageSize(), 'pubdate', 3
      );
      if (vlist.length === 0) {
        this.hasMore = false;
        return;
      }
      const mapped: Track[] = [];
      for (let i = 0; i < vlist.length; i++) {
        mapped.push(mapSpaceVideo(vlist[i], this.upMid, this.upName));
      }
      // 翻页边界漂移兜底：拉页期间 UP 发新稿会把后续页整体前移，页 N 尾条可能与
      // 页 N+1 首条相同 —— 追加前按 id 去重，已有条目保留原位置，不重复追加。
      const seen: Set<string> = new Set(this.tracks.map((t: Track): string => t.id));
      const fresh: Track[] = mapped.filter((t: Track): boolean => t.id.length > 0 && !seen.has(t.id));
      this.page = pn;
      // hasMore 按原始返回长度判定：去重后变短只说明页界有重叠，不代表没有下一页；
      // page 即使本页全被去重也要推进，否则会在同一页上死循环。
      this.hasMore = vlist.length >= this.pageSize();
      // 增量追加（2026-10-19 修「加载第二页列表整体跳一下」）：翻页不再整表
      // 重新赋值，fresh 逐条 push，ForEach 只 diff 新增 key，既有行零重渲染。
      if (pn === 1) {
        this.tracks = mapped;
      } else {
        for (let i = 0; i < fresh.length; i++) {
          this.tracks.push(fresh[i]);
        }
      }
      // 翻页追加后重跑本地过滤：新进来的条目才能出现在过滤视图里
      this.applyLocalFilter();
      this.loadFailed = false;
      this.failReason = '';
      // 翻页追加后整表落盘：再次进页能带着已翻页内容恢复，并从 page+1 续拉
      this.saveToCache();
    } catch (e) {
      const reason: string = this.describeError(e instanceof Error ? e : new Error(JSON.stringify(e)));
      console.error(`getUserVideos(space) failed: ${reason}`);
      if (this.tracks.length === 0) {
        this.loadFailed = true;
        this.failReason = this.sourceVia === BilibiliApi.UP_VIA_NONE
          ? reason
          : `B 站暂时没返回该 UP 的投稿（${reason}）`;
      }
    }
  }

  private onReachEnd(): void {
    // 远程搜索结果是一次性的（不分页），搜索态上拉到底不再触发翻页
    if (this.remoteResults !== null || this.remoteSearching) {
      return;
    }
    if (this.loading || this.loadingMore || !this.hasMore) {
      return;
    }
    this.loadPage(this.page + 1);
  }

  /**
   * 把异常翻译成一句能直接决定动作的话。
   *
   * `BiliApiError.message` 形如 `BiliBili API Error [-352]: 风控校验失败 (/x/space/arc/search)`，
   * 从中抠出 code 与服务端 message；HTTP 层异常（`HTTP 412 for …`）则直接用原文。
   * 分不清时退回通用文案，**不要**把 `[object Object]` 之类甩给用户。
   */
  private describeError(e: Error): string {
    const raw: string = e && e.message ? e.message : '';
    if (raw.length === 0) {
      return '投稿加载失败';
    }
    const matched: RegExpMatchArray | null = raw.match(/\[(-?\d+)\]\s*([^(\/]*)/);
    if (matched) {
      const code: string = matched[1];
      const msg: string = (matched[2] || '').trim();
      if (code === '-352' || code === '-509' || code === '-799') {
        return `B 站限制了当前访问（${code}${msg.length > 0 ? ' ' + msg : ''}），过一会儿再试`;
      }
      if (code === '-403') {
        return `请求被 B 站拒绝（${code}），签名或身份校验未通过`;
      }
      return `加载失败（${code}${msg.length > 0 ? ' ' + msg : ''}）`;
    }
    if (raw.indexOf('HTTP 412') >= 0) {
      return 'B 站拒绝了匿名访问（412），检查网络环境后重试';
    }
    if (raw.indexOf('HTTP') >= 0) {
      return raw;
    }
    return `加载失败：${raw.slice(0, 40)}`;
  }

  /**
   * 失败后的重试：清干净状态重新拉第一页。
   *
   * 带 4 秒冷却：B 站这类接口按 IP 限流，用户连点只会继续被拒（而且每次重试都会
   * 打两个接口，等于自己把限流阈值撞满）。
   */
  private retry(): void {
    if (this.retryLocked) {
      return;
    }
    this.retryLocked = true;
    this.retryCooling = true;
    this.retryTimer = setTimeout((): void => {
      this.retryLocked = false;
      this.retryCooling = false;
    }, RETRY_COOLDOWN_MS);
    // 重试是完整重置：搜索态一并清掉（刷新的是完整列表，过滤态残留会语义错乱）
    this.clearSearch();
    this.loadFailed = false;
    this.failReason = '';
    this.hasMore = true;
    this.page = 1;
    this.tracks = [];
    this.loadCard();
    this.loadPage(1);
  }

  /**
   * 下拉刷新：强制联网重拉第一页 + 资料（2026-10-09 缓存策略下进页不联网，
   * 这是两个显式刷新出口之一；另一个是头部「拉取新投稿」按钮）。
   *
   * 有请求在途（loading / loadingMore）时直接收起刷新头，不叠加请求。
   * catch 兜住后 then 必达：loading / refreshing 一定能复位（refreshSubscription
   * 同款纪律 —— 缺了 catch 时链上任何一步抛异常，刷新头会永远转圈）。
   */
  private forceRefresh(): void {
    if (this.loading || this.loadingMore) {
      this.refreshing = false;
      return;
    }
    // 下拉刷新 = 显式要求看完整最新列表：先退出搜索态再拉（过滤/远程结果不对新列表负责）
    this.clearSearch();
    this.loading = true;
    this.loadCard();
    this.loadFirstMultiSource()
      .catch((e: Error): void => {
        console.error(`up space forceRefresh failed: ${e.message}`);
      })
      .then((): void => {
        this.loading = false;
        this.refreshing = false;
      });
  }

  // ===== 投稿搜索（2026-10-23）=====

  /**
   * 列表渲染源（三态切换）：远程搜索态 → B 站搜索结果；本地过滤态 → 过滤结果；
   * 默认 → 全量已加载列表。ForEach 数据源统一走这里，条目渲染 / 菜单零改动复用。
   */
  private displayTracks(): Track[] {
    if (this.remoteResults !== null) {
      return this.remoteResults;
    }
    if (this.searchKeyword.trim().length > 0) {
      return this.filteredTracks;
    }
    return this.tracks;
  }

  /**
   * 本地过滤（方案 A）：标题 / 歌手包含关键词（小写化匹配），输入即生效、离线可用。
   * keyword 为空 → 空数组（displayTracks 会退回全量列表）。
   * tracks 换新 / 追加的三处（loadFirstMultiSource / loadPageViaSpace / refreshSubscription）
   * 之后都要重跑一次，保证翻页新进来的条目也能出现在过滤视图里。
   */
  private applyLocalFilter(): void {
    const kw: string = this.searchKeyword.trim().toLowerCase();
    if (kw.length === 0) {
      this.filteredTracks = [];
      return;
    }
    this.filteredTracks = this.tracks.filter((t: Track): boolean => {
      return t.title.toLowerCase().indexOf(kw) >= 0
        || t.artist.toLowerCase().indexOf(kw) >= 0;
    });
  }

  /**
   * 搜索框输入变化：即时重算本地过滤；若正处于远程结果态则一并退出 ——
   * 远程结果只对「发起搜索时的关键词」有效，输入已变，旧结果不能继续顶着显示。
   */
  private onKeywordChanged(): void {
    this.applyLocalFilter();
    if (this.remoteResults !== null || this.remoteSearching) {
      this.searchToken++; // 在途请求回来一律作废
      this.remoteResults = null;
      this.remoteSearching = false;
      this.remoteFailReason = '';
    }
  }

  /**
   * B 站全量搜索（方案 B）：按关键词搜全站 → 按 `mid === upMid` 过滤出该 UP
   * **全部历史投稿**中匹配的部分（不限已加载页；3 页 × 20 条上限）。
   *
   * 竞态纪律（照 SearchPage）：token 只认最新；`clearSearch` / 再次输入都会令旧响应作废。
   * `searchOk=false`（搜索接口自己被拒）与 0 命中分开提示，别让用户把限流当成「没搜到」。
   */
  private runRemoteSearch(): void {
    const kw: string = this.searchKeyword.trim();
    if (kw.length === 0 || this.upMid.length === 0 || this.remoteSearching) {
      return;
    }
    this.searchToken++;
    const token: number = this.searchToken;
    this.remoteSearching = true;
    this.remoteFailReason = '';
    BilibiliApi.searchUpVideosByKeyword(this.upMid, this.upName, kw)
      .then((res: BilibiliApi.UpVideosSearchResult): void => {
        if (token !== this.searchToken) {
          return;
        }
        this.remoteSearching = false;
        if (!res.searchOk) {
          this.remoteFailReason = '搜索被 B 站拒绝，过一会儿再试';
          return;
        }
        this.remoteResults = this.mapAll(res.list);
      })
      .catch((e: Error): void => {
        if (token !== this.searchToken) {
          return;
        }
        this.remoteSearching = false;
        this.remoteFailReason = this.describeError(
          e instanceof Error ? e : new Error(JSON.stringify(e))
        );
      });
  }

  /** 清除搜索：回完整列表（清关键词 + 退出远程搜索态，在途响应一律作废）。 */
  private clearSearch(): void {
    this.searchToken++;
    this.searchKeyword = '';
    this.filteredTracks = [];
    this.remoteResults = null;
    this.remoteSearching = false;
    this.remoteFailReason = '';
  }

  /**
   * 兜底：把该 UP 的投稿页交给 B 站自己打开。
   *
   * 站内接口被风控时这是**唯一 100% 可用**的路 —— openLink 对 https 链接会交给系统
   * 浏览器（没装 B 站 App 也能看），装了 App 则可能直接跳 App。
   */
  private async openInBilibili(): Promise<void> {
    if (this.upMid.length === 0) {
      return;
    }
    const url: string = `https://space.bilibili.com/${this.upMid}/video`;
    try {
      // openLink 挂在 UIAbilityContext 上（不是基类 Context），所以要转一下
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await ctx.openLink(url);
    } catch (e) {
      console.error(`openLink failed: ${JSON.stringify(e)}`);
      showAppToast('无法打开 B 站页面', 1800);
    }
  }

  // ===== 订阅 =====

  /**
   * 首次订阅：取该 UP 的投稿 → 建成订阅歌单。
   *
   * 刻意**先取数据再建歌单**：直接建一个空歌单的话，接口失败就会留下一个永远空着的壳。
   * 取数据走 `collectUpVideos`（三级兜底，与列表页同一份策略），理由见 `loadPage` 注释。
   */
  private subscribe(): void {
    if (this.subBusy) {
      return;
    }
    this.subBusy = true;
    showAppToast('正在订阅…', 1200);
    // 首次订阅歌单还没建，种子只能取自列表页已加载的曲目
    this.collectTracks(this.seedBvids(this.tracks))
      .then((mapped: Track[]): void => {
        if (mapped.length === 0) {
          showAppToast(this.lastCollectError.length > 0
            ? this.lastCollectError
            : '没取到该 UP 的投稿，稍后再试', 2200);
          return;
        }
        const r: UpSubscribeResult = LibraryStore.subscribeUpPlaylist(
          this.upMid, this.upName, mapped, this.upFace
        );
        this.subscribed = true;
        this.subscribedCount = r.playlist.tracks.length;
        this.showSubscribeResult(r);
        // 订阅取回的就是该 UP 的最新投稿页（2026-10-23）：与「拉取新投稿」同样把
        // 页面列表和缓存一并换新 —— 否则缓存命中进入 + 订阅的场景下，缓存里还是
        // 进页时的旧列表，重进页面看不到刚拉到的条目，又得手动再拉一次。
        this.tracks = mapped;
        this.applyLocalFilter();
        this.page = 1;
        this.hasMore = this.sourceVia === BilibiliApi.UP_VIA_SPACE
          && mapped.length >= this.pageSize();
        this.loadFailed = false;
        this.failReason = '';
        this.saveToCache();
      })
      // 与 refreshSubscription 同理：缺这个 catch 时，订阅失败会让 subBusy 永久卡死，
      // 按钮再也点不动（见 refreshSubscription 里的注释）。
      .catch((e: Error): void => {
        console.error(`subscribe failed: ${e.message}`);
        showAppToast(`订阅失败：${e.message}`, 2000);
      })
      .then((): void => {
        this.subBusy = false;
      });
  }

  /**
   * 取该 UP 的投稿（三级兜底），返回已映射成 Track 的列表。
   *
   * `seeds` 是 related 扩散用的种子 bvid：首次订阅时歌单还没建，用**当前列表页已加载的**
   * tracks；拉取新投稿时用**已订阅歌单**里的 tracks。没有种子时那一级自动跳过。
   *
   * 失败时**不抛**，而是把人话原因写进 `lastCollectError` 并返回空数组 ——
   * 调用方（订阅 / 拉取新投稿）据此给用户一句能判断「该等还是该换网络」的提示，
   * 而不是笼统的「稍后再试」（用户看到后者只会以为 App 坏了）。
   */
  private async collectTracks(seeds: string[]): Promise<Track[]> {
    this.lastCollectError = '';
    const res: BilibiliApi.UpVideosCollectResult =
      await BilibiliApi.collectUpVideos(this.upMid, this.upName, seeds, this.pageSize());
    this.sourceVia = res.via;
    if (res.list.length > 0) {
      return this.mapAll(res.list);
    }
    this.lastCollectError = res.reason.length > 0
      ? `B 站暂时没返回投稿：${this.describeError(new Error(res.reason))}`
      : 'B 站暂时没返回该 UP 的投稿，稍后再试';
    return [];
  }

  private mapAll(list: SpaceVideo[]): Track[] {
    const mapped: Track[] = [];
    for (let i = 0; i < list.length; i++) {
      mapped.push(mapSpaceVideo(list[i], this.upMid, this.upName));
    }
    return mapped;
  }

  /**
   * 拉取新投稿：并入订阅歌单。
   *
   * 走 `collectTracks()`（三级兜底）而不是顺序翻空间接口 ——「找新投稿」这件事
   * 搜索反查反而更合适：结果按 `pubdate` 重排后天然就是「最近的投稿」，
   * 而空间接口要翻好几页、每页都要赌一次限流。
   *
   * ⚠️ 关于「只成功一次」：这不是限流。实测搜索接口连打 8 次 8/8 成功，流程每次都跑通了；
   * 真实原因是**去重**——拉回来的还是同一批，`mergeUpTracks` 全去重掉 → added=0。
   * 所以 added=0 的提示必须是「已是最新」，否则用户会当成故障。
   */
  private refreshSubscription(): void {
    if (this.subBusy) {
      return;
    }
    const existing = LibraryStore.getPlaylistByUpMid(this.upMid);
    if (!existing) {
      this.subscribe();
      return;
    }
    this.subBusy = true;
    showAppToast('正在拉取新投稿…', 1200);
    // 已订阅 → 种子取自订阅歌单里的曲目
    this.collectTracks(this.seedBvids(existing.tracks))
      .then((collected: Track[]): void => {
        if (collected.length === 0) {
          // 有具体原因就说具体原因（多半是 B 站风控 -352 / -799 / 412），
          // 让用户知道「等一会儿再来」而不是以为 App 坏了
          showAppToast(this.lastCollectError.length > 0
            ? this.lastCollectError
            : '没有拿到新投稿，稍后再试', 2200);
          return;
        }
        const r = LibraryStore.mergeUpTracks(existing.id, collected);
        this.subscribedCount = r.playlist ? r.playlist.tracks.length : this.subscribedCount;
        if (r.added === 0) {
          // 拿到了数据但全是已有的 = 确实没有新投稿，不是故障
          showAppToast('已是最新 · 该 UP 还没有新投稿', 1800);
        } else {
          this.showSubscribeResult({
            playlist: r.playlist ?? existing,
            added: r.added,
            dropped: r.dropped,
            reused: true
          });
        }
        // 拉新是用户显式刷新动作（2026-10-09）：本页列表同步换成刚取回的最新一页
        // ——「已是最新」分支同样执行，列表与缓存都换成本次真实返回；
        // collectTracks 内已写 sourceVia，据此恢复 hasMore（与 loadFirstMultiSource 同式）
        this.tracks = collected;
        // 本页列表同步换新后重跑本地过滤（keyword 为空时是 no-op）
        this.applyLocalFilter();
        this.page = 1;
        this.hasMore = this.sourceVia === BilibiliApi.UP_VIA_SPACE
          && collected.length >= this.pageSize();
        this.loadFailed = false;
        this.failReason = '';
        this.saveToCache();
      })
      // ⚠️ 这个 catch 不能省：本页原来只有 `.then().then()`，链上任何一步抛异常
      // （mapAll / mergeUpTracks / getPlaylistByUpMid）都会让两个 then 一起被跳过，
      // `subBusy` 永久停在 true —— 按钮从此一直显示「处理中…」且 disabled，
      // 表现就是「点了拉取新投稿，之后再点完全没反应」。
      // 写法照 PlaylistDetail.refreshUpTracks：catch 兜住异常（返回 resolved），
      // 后面的 then 必定执行，忙标记一定能复位。
      .catch((e: Error): void => {
        console.error(`refreshSubscription failed: ${e.message}`);
        showAppToast(`拉取失败：${e.message}`, 2000);
      })
      .then((): void => {
        this.subBusy = false;
      });
  }

  private showSubscribeResult(r: UpSubscribeResult): void {
    const parts: string[] = [];
    parts.push(r.added === 1 ? '新增 1 首' : `新增 ${r.added} 首`);
    if (r.dropped > 0) {
      parts.push(`已满 ${r.playlist.tracks.length} 首，更早的未收`);
    }
    const prefix: string = r.reused ? '已更新订阅' : '已订阅';
    showAppToast(`${prefix}，${parts.join('，')}`, 2000);
  }

  // ===== 曲目菜单（本页只给两项：播放队列 / 下载） =====

  /** 「⋯」标准菜单项（阶段 2 迁移：双按钮 AlertDialog → bindMenu + MenuElement 数组） */
  private trackMenuItems(track: Track): MenuElement[] {
    return [
      {
        value: '加入队列',
        action: (): void => {
          this.player.addToQueue(track);
          showAppToast('已加入播放队列', 1500);
        }
      },
      {
        value: '下载',
        action: (): void => {
          this.requestDownload(track);
        }
      }
    ];
  }

  private requestDownload(track: Track): void {
    // 与 SearchPage.startDownload 同一条链：DownloadManager 内部按「仅 WiFi 下载」设置
    // 返回 blockedReason，这里把它翻译成一次询问，用户确认后带 ignoreWifiLimit 重试。
    DownloadManager.getInstance().requestDownload(track, false)
      .then((r: DownloadStartResult): void => {
        if (r.blockedReason.length > 0) {
          this.confirmDownloadOnCellular(track);
          return;
        }
        const head: string = r.queued === 1 ? '已开始下载 1 首' : `已开始下载 ${r.queued} 首`;
        const tail: string = r.skipped > 0 ? `（另有 ${r.skipped} 首已在列表中）` : '';
        showAppToast(`${head}${tail}，可在「下载」页查看进度`, 2000);
      })
      .catch((e: Error): void => {
        console.error(`requestDownload failed: ${e.message}`);
        showAppToast('下载启动失败', 1800);
      });
  }

  /**
   * 「仅 WiFi 下载」被触发：先问一句，而不是直接拒绝 ——
   * 开这个开关的人多半是「不想偷跑流量」，不是「绝对不许用流量」。
   * 措辞与 SearchPage.confirmDownloadOnCellular 保持一致。
   */
  private confirmDownloadOnCellular(track: Track): void {
    showAppAlertDialog(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: `${WIFI_ONLY_BLOCKED}\n当前网络：${currentNetworkLabel()}`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '继续下载',
        action: (): void => {
          DownloadManager.getInstance().requestDownload(track, true)
            .then((r: DownloadStartResult): void => {
              showAppToast(r.queued > 0 ? `已开始下载 ${r.queued} 首` : '没有可下载的曲目', 1800);
            })
            .catch((e: Error): void => {
              console.error(`requestDownload(ignoreWifiLimit) failed: ${e.message}`);
              showAppToast('下载启动失败', 1800);
            });
        }
      }
    });
  }

  /**
   * 子页转场：从右滑入 slow(400ms) EaseOut，pop 反向（照 RecentPage / PlaylistDetail 同款）。
   */
  private navTransitionDelegate(op: NavigationOperation,
    isEnter: boolean): Array<NavDestinationTransition> | undefined {
    if (op === NavigationOperation.PUSH && isEnter) {
      this.navTransX = '100%';
      const enter: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '0%';
        }
      };
      return [enter];
    }
    if (op === NavigationOperation.POP && !isEnter) {
      const exit: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '100%';
        }
      };
      return [exit];
    }
    return undefined;
  }

  /**
   * 头部区元信息行：粉丝数 + 投稿数 / 订阅状态。
   *
   * 用方法而不是预计算的 @State 字段（与 PlaylistDetail 的做法不同，是刻意的）：
   * 本页的粉丝数 / 投稿数 / 订阅状态在 loadCard、loadPage、subscribe、
   * refreshSubscription 四处各自变化，预计算要在每个点都记得刷新一次，漏一处就显示旧值。
   * 这里是纯字符串拼接，直接调方法永远拿到最新值。
   * ⚠️ @Builder 体内**不声明局部变量**，所以走方法调用而不是在 build 里拼。
   */
  private upMetaText(): string {
    const parts: string[] = [];
    if (this.fans > 0) {
      parts.push(`粉丝 ${formatFans(this.fans)}`);
    }
    if (this.subscribed) {
      // 2026-10-23 用户需求：订阅态显示 UP 的投稿总数（card 的 archive_count），
      // 不再显示订阅歌单的曲目数 —— 两者经常不相等（订阅时只装了当时加载到的投稿），
      // 后者会让用户误以为 UP 的投稿就这么多。未知时（旧缓存 / 卡片被风控）
      // 退回已加载条数做近似，口径仍与未订阅分支一致。
      const submissionCount: number =
        this.archiveCount > 0 ? this.archiveCount : this.tracks.length;
      if (submissionCount > 0) {
        parts.push(`${submissionCount} 个投稿`);
      }
    } else if (this.tracks.length > 0) {
      parts.push(`${this.tracks.length} 个投稿`);
    }
    return parts.join(' · ');
  }

  /**
   * 头部区（整体钉在悬浮固定栏内，不随列表滚动）—— 与 PlaylistDetail.PlaylistHeader 同款：
   * 左侧 96vp 圆角头像 + 右侧 28fp 大标题 + 元信息行；头像行下方是操作按钮行
   * （播放全部 / 订阅·拉取新投稿）。
   *
   * 头像尺寸与圆角对齐歌单封面（96 / 12）：两个详情页的头部视觉语言一致，
   * 进哪个页都是同一套「大图 + 大标题」。
   */
  @Builder
  UpHeader(): void {
    Column() {
      Row() {
        CoverImage({
          url: toThumbUrl(this.upFace, 96),
          imgWidth: 96,
          imgHeight: 96,
          imgRadius: 12,
          altText: this.upName
        })
        Column() {
          Text(this.upName.length > 0 ? this.upName : 'UP 主主页')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.upMetaText().length > 0) {
            Text(this.upMetaText())
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 6 })
          }
        }
        .layoutWeight(1)
        .margin({ left: 16 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 操作按钮行：与 PlaylistDetail 同款（主按钮粉、次按钮 brand_surface）。
      // 播放全部：有投稿才显示；订阅入口常驻 —— 它是本页的核心动作，
      // 放在头部区比挤在返回行右侧更显眼（返回行只留返回键，与歌单详情一致）。
      Row({ space: 8 }) {
        if (this.tracks.length > 0) {
          Button('播放全部', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            // 真机要求：与 RecentPage 播放全部逐字一致（浅粉底 + 粉字 + 沉浸光感）
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .onClick((): void => {
              this.player.playAll(this.tracks);
            })
        }
        if (this.upMid.length > 0) {
          Button(this.subBusy ? '处理中…' : (this.subscribed ? '拉取新投稿' : '订阅投稿'),
            { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .backgroundColor(this.themeSurface)
            .fontColor(this.themeDeep)
            .attributeModifier(this.buttonMaterial)
            .enabled(!this.subBusy)
            .onClick((): void => {
              if (this.subscribed) {
                this.refreshSubscription();
              } else {
                this.subscribe();
              }
            })
        }
      }
      .width('100%')
      .margin({ top: 12 })
      .alignItems(VerticalAlign.Center)

      // 搜索框行（2026-10-23）：输入即过滤**已加载**的投稿（本地，离线可用）；
      // Enter / 「搜索」按钮发起 B 站全站搜索（按 mid 过滤回该 UP 的投稿，
      // 能覆盖未加载页）。「清除」只在有关键词或处于远程结果态时出现。
      // 行高恒定（40 + 上边距 12），头部区实测高度自适配，无需特殊处理。
      Row({ space: 8 }) {
        TextInput({ placeholder: '搜索 TA 的投稿', text: this.searchKeyword })
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .placeholderFont({ size: 14 })
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(BUTTON_RADIUS_VP)
          .padding({ left: 14, right: 14 })
          .onChange((v: string): void => {
            this.searchKeyword = v;
            this.onKeywordChanged();
          })
          .onSubmit((): void => {
            this.runRemoteSearch();
          })
        Button(this.remoteSearching ? '搜索中' : '搜索', { type: ButtonType.Normal })
          .fontSize(13)
          .height(40)
          .borderRadius(BUTTON_RADIUS_VP)
          .padding({ left: 16, right: 16 })
          .backgroundColor(this.themeSurface)
          .fontColor(this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          // 不用 .enabled(false) 表达「空词 / 搜索中不可点」：禁用态会用系统灰字
          // 覆盖 themePrimary 字色（用户要求按钮字色恒为主题色）；点击兜底在
          // runRemoteSearch 里（空词 / 在途一律 no-op）。
          .onClick((): void => {
            this.runRemoteSearch();
          })
        if (this.searchKeyword.trim().length > 0 || this.remoteResults !== null) {
          Button('清除', { type: ButtonType.Normal })
            .fontSize(13)
            .height(40)
            .borderRadius(BUTTON_RADIUS_VP)
            .padding({ left: 16, right: 16 })
            .backgroundColor($r('app.color.bg_divider'))
            .fontColor($r('app.color.text_secondary'))
            .onClick((): void => {
              this.clearSearch();
            })
        }
      }
      .width('100%')
      .margin({ top: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 头部区间距（2026-10-22 用户要求上移）：top 12→4 紧贴标题行下沿，
    // bottom 16→8 让首个投稿条目同步上移（列表占位随 headerAreaHeight 实测自动跟随）。
    .padding({ left: 20, right: 20, top: 4, bottom: 8 })
  }

  /**
   * 标题行内容（titleBar 的 stackBuilder 承载，可用空间仅 56vp，不得超出——
   * 官方约束「不要超出标题栏的可用空间」，超出会溢出与内容区重叠）：
   * 仅返回键 —— UP 昵称只在头部区 28fp 大标题显示一次，与歌单详情同约定。
   * 材质与滚动模糊由 HDS titleBar 负责。
   */
  @Builder
  upSpaceBar() {
    NavTitleRow({ title: '' })
  }

  /**
   * 标题行下方自定义区（titleBar 的 bottomBuilder 承载）：UP 资料头部区。
   * ⚠️ bottomBuilder 高度不自适应（官方约束），内层 Column 是天然高的实测载体——
   * onAreaChange 挂内层根节点，回写 headerAreaHeight（随元信息行数浮动）；
   * 实测前用估计高度垫底防 0 高闪跳。
   */
  @Builder
  upSpaceHeaderArea() {
    Column() {
      Column() {
        this.UpHeader()
      }
      .width('100%')
      .onAreaChange((_old: Area, cur: Area): void => {
        const h: number = cur.height as number;
        if (h > 0) {
          this.headerAreaHeight = h;
        }
      })
    }
    .width('100%')
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Column() {
          // UP 资料头已移进钉顶固定栏（UpHeader），这里直接是列表内容 ——
          // 与 PlaylistDetail 同结构：列表视口铺满全屏，首项从整栏底部起排，
          // 滚动时条目从毛玻璃下穿过（顶部占位条目负责让位）。
          if (this.loading && this.tracks.length === 0) {
            // 首屏骨架：同款条目占位，不用「转圈 + 加载中」
            Column() {
              ForEach([0, 1, 2, 3, 4], (_i: number): void => {
                SkeletonTrackItem({ index: _i })
              }, (_i: number): string => `up_skel_${_i}`)
            }
            .width('100%')
            // 非列表分支没有占位条目，自己补让位（标题栏总让位量）
            .padding({ top: this.barTotalHeight() })
          } else if (this.loadFailed && this.tracks.length === 0) {
            Column() {
              Text('投稿加载失败')
                .fontColor($r('app.color.text_secondary'))
                .fontSize(16)
              Text(this.failReason.length > 0 ? this.failReason : '检查网络后再试一次')
                .fontColor($r('app.color.text_tertiary'))
                .fontSize(13)
                .textAlign(TextAlign.Center)
                .padding({ left: 24, right: 24 })
                .margin({ top: 8 })
              Row() {
                // 同上：32vp 视觉 + 44vp 命中区（外层 Row 撑 44 居中）
                Row() {
                  Button(this.retryCooling ? '稍等 4 秒' : '重试', { type: ButtonType.Normal })
                    .fontSize(13)
                    .height(32)
                    .borderRadius(BUTTON_RADIUS_VP)
                    .padding({ left: 18, right: 18 })
                    .backgroundColor(this.themePrimary)
                    .fontColor(this.themeOn)
                    .enabled(!this.retryCooling && !this.loading)
                    .onClick((): void => {
                      this.retry();
                    })
                }
                .height(44)
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)

                // 站内接口被风控时，这是唯一 100% 能看到内容的路
                Row() {
                  Button('在 B 站打开', { type: ButtonType.Normal })
                    .fontSize(13)
                    .height(32)
                    .borderRadius(BUTTON_RADIUS_VP)
                    .padding({ left: 18, right: 18 })
                    .backgroundColor(this.themeSurface)
                    .fontColor(this.themeDeep)
                    .onClick((): void => {
                      this.openInBilibili();
                    })
                }
                .height(44)
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
                .margin({ left: 4 })
              }
              .margin({ top: 12 })
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
            // 非列表分支没有占位条目，自己补让位（标题栏总让位量）
            .padding({ top: this.barTotalHeight() })
          } else if (this.tracks.length === 0) {
            Column() {
              Text('该 UP 还没有投稿')
                .fontColor($r('app.color.text_secondary'))
                .fontSize(16)
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
            // 同上：空态自己补让位
            .padding({ top: this.barTotalHeight() })
          // 列表挂载门控（见 headerAreaHeight 注释）：等头部区首次实测完成再挂载。
          // ⚠️ 不能用 barTotalHeight() > 0 当门控 —— safeTop + 56 恒 > 0，门控形同虚设，
          // 列表会在 headerAreaHeight 实测前挂载并固化 safeTop + 56 的错误让位量
          // （首项被封面压住，真机复现）；必须直接判 headerAreaHeight > 0。
          } else if (this.headerAreaHeight > 0) {
            // 下拉刷新（2026-10-09）：缓存策略下进页不联网，这里与「拉取新投稿」
            // 并列为仅有的两个显式刷新出口。Refresh 只包列表（SearchPage 同款），
            // 系统默认刷新头即可；layoutWeight 移交 Refresh，内层 List 补 height('100%')。
            Refresh({ refreshing: $$this.refreshing }) {
              List({ scroller: this.listScroller }) {
                // 顶部空白占位条目（下载页同款）：列表视口铺满全屏，条目起始位置在
                // 屏幕顶端（y=0）。占位高度 = 标题栏总让位量（barTotalHeight：
                // safeTop + 56 + 头部区实测高，随元信息行数浮动），首个真实条目恰
                // 从栏底起排（静置位与旧 contentStartOffset 等值），滚动时占位与
                // 条目一起从沉浸材质下方穿过。
                ListItem() {
                  // Blank 只能嵌在 Row/Column/Flex 内（编译器 10905201），ListItem 直下用定高 Row。
                  Row()
                    .width('100%')
                    .height(this.barTotalHeight())
                }
                // 条目渲染（SearchPage 同款）：渲染源走 displayTracks() 三态切换
                // （远程搜索结果 / 本地过滤结果 / 全量已加载），@State 数组直接驱动
                // ForEach，追加 / 整表替换靠数组赋值，不再经 ArrayDataSource 双份拷贝。
                ForEach(
                  this.displayTracks(),
                  (t: Track, index: number): void => {
                    ListItem() {
                      TrackItem({
                        track: t,
                        entranceIndex: index,
                        onPlay: (tr: Track): void => {
                          this.player.playOrToggle(tr);
                        },
                        moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
                      })
                    }
                  },
                  (t: Track): string => t.id
                )
                // 加载更多状态条（2026-10-19 常驻 + 固定高度）：只换内容不插拔条目，
                // 数据落地帧尾部 extent 只增不减，底部弹簧过滚动不被收缩强制解析。
                // 加载态从 3 行骨架收成单行转圈：为固定高度做的取舍，首屏骨架不动。
                // 2026-10-23 搜索分支排在最前：搜索态的计数 / 失败 / 在途提示
                // 优先于常规加载文案（搜索态下不翻页，旧三分支不会再被走到）。
                ListItem() {
                  Row() {
                    if (this.remoteSearching) {
                      LoadingProgress()
                        .width(18)
                        .height(18)
                        .color($r('app.color.text_tertiary'))
                      Text('正在 B 站搜索…')
                        .fontSize(12)
                        .fontColor($r('app.color.text_tertiary'))
                        .margin({ left: 8 })
                    } else if (this.remoteFailReason.length > 0) {
                      Text(this.remoteFailReason)
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                    } else if (this.remoteResults !== null) {
                      Text(this.remoteResults.length > 0
                        ? `B 站搜到该 UP 的 ${this.remoteResults.length} 条投稿`
                        : 'B 站没搜到该 UP 的相关投稿，试试更短的关键词')
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                    } else if (this.searchKeyword.trim().length > 0) {
                      Text(this.filteredTracks.length > 0
                        ? `已加载投稿中命中 ${this.filteredTracks.length} 条，「搜索」可找全部`
                        : '已加载的投稿里没有匹配，「搜索」可去 B 站找全部投稿')
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                    } else if (this.loadingMore) {
                      LoadingProgress()
                        .width(18)
                        .height(18)
                        .color($r('app.color.text_tertiary'))
                      Text('加载中…')
                        .fontSize(12)
                        .fontColor($r('app.color.text_tertiary'))
                        .margin({ left: 8 })
                    } else if (!this.hasMore) {
                      Text(this.subscribed ? '订阅已开启，可随时拉取新投稿' : '订阅该 UP 可持续获取新投稿')
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                    } else {
                      Text('上拉加载更多')
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                    }
                  }
                  .width('100%')
                  .height(LIST_FOOTER_HEIGHT_VP)
                  .justifyContent(FlexAlign.Center)
                }
              }
              .width('100%')
              .height('100%')
              // 裁剪放开（官方博客：「clip 是 true，内容到标题栏底部就截断，看不到模糊效果」；
              // 列表内容要能画进标题栏区域，HDS 的材质/模糊才有可采样的源）
              .clip(false)
              // 边界回弹（2026-10-08）：到顶/到底的反馈动效；顶部下拉由 Refresh 刷新动画接管
              .edgeEffect(EdgeEffect.Spring)
              // 顶部 HDS 标题栏让位（Sumy 式穿透，与 PlaylistDetail 同款）：由 List
              // 首个空白占位 ListItem 负责（见上方占位注释，下载页同款），不再使用
              // contentStartOffset。
              // 列表末端常规留白（2026-10-09：不再叠加 safeBottom —— 底部不做避让，
              // 视口直接扩展进安全区，末行可滚到手势条下）
              .contentEndOffset(CONTENT_END_OFFSET)
              .onReachEnd((): void => {
                this.onReachEnd();
              })
            }
            .layoutWeight(1)
            .width('100%')
            .onRefreshing((): void => {
              this.forceRefresh();
            })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
        // ⚠️ 不再整体 padding top / safeAreaPadding bottom：列表视口铺满全屏并直接
        // 扩展进底部安全区（2026-10-09：不做底部避让，沉浸到底）；
        // 非列表分支（骨架 / 失败 / 空态）各自补 padding top。
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
      }
    }
    // HDS 沉浸光感标题栏（批 1 样板同款，真机结论见 AboutPage 注释）：
    // avoidLayoutSafeArea 挡状态栏重叠；enableComponentSafeArea 会杀材质，禁用。
    // 标题栏宽度跟随本页内容列，大屏上与收窄后的列表左右对齐。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(UP_BLUR_START_VP, UP_BLUR_END_VP),
      content: {
        // 标题行（stackBuilder，可用空间 56vp）：仅返回键
        stackBuilder: (): void => {
          this.upSpaceBar();
        },
        // 标题行下方自定义区：UP 资料头部区（封面 / 昵称 / 订阅 / 拉新等）。
        // ⚠️ 头部区不能塞进 stackBuilder（会溢出 56vp 标题行、与列表内容重叠，
        // 真机复现），必须走 bottomBuilder；高度用实测值（未实测时估计值垫底）。
        bottomBuilder: {
          builder: (): void => {
            this.upSpaceHeaderArea();
          },
          height: this.headerAreaHeight > 0 ? this.headerAreaHeight : UP_HEADER_ESTIMATE_HEIGHT,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        }
      }
    })
    // 双返回键修复（2026-10-22）：隐藏 HDS 默认返回键，只保留 stackBuilder 自绘键
    // （默认键与自绘键在标题栏左上角重叠，两个 chevron 重影、按压效果错乱）
    .hideBackButton(true)
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页列表交给 HDS 联动
    .bindToScrollable([this.listScroller])
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 内容避让（2026-10-14）：目的地级声明布局扩展进系统安全区（官方组件级沉浸
    // 口径，faqs-arkui-1095 场景三同款）；窗口全屏下页面级为既成事实，此处显式化
    // 并接管组件级 safeAreaPadding。内容层避让由顶部占位条目 / plain padding 自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets，2026-10-17 启动优化）：
 * Index 已不再静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function UpSpacePageBuilder(): void {
  UpSpacePage()
}


/** 懒加载注册表预包装（2026-10-17）：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const UpSpacePageWrapped: WrappedBuilder<[]> = wrapBuilder(UpSpacePageBuilder);

