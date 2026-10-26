/**
 * UP 主主页（站内）：显示 UP 的资料 + 投稿列表，并可把投稿**订阅成持续更新的歌单**。
 *
 * 为什么是站内页而不是跳 B 站：订阅要在 App 内落成可维护的歌单，
 * 跳出去就没法持续更新订阅，也就没有 C 方案的意义。
 *
 * 数据来源（匿名态实测，均可用）：
 *  · 资料 `getUserCard`（x/web-interface/card）—— **不要用 space/wbi/acc/info**，
 *    那个匿名只回 v_voucher，字段全空；
 *  · 投稿 `getUserVideos`（x/space/wbi/arc/search，30 条/页，真分页）。
 *
 * 入参走路由参数 UpSpaceRouteParam（pushPathByName 入栈，upMid 必填、
 * upName 兜底、upFace 首帧占位），与 PlaylistDetail 同套约定。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，stackBuilder 承载
 * 标题行 + UP 资料头部区；返回键为 HDS 默认键）；侧滑返回是 Navigation 级能力，不受影响。
 *
 * 布局与 **PlaylistDetail 完全同款**：
 *  · 头部区「96vp 头像 + 28fp 大标题 + 元信息 + 播放全部/订阅按钮」整体在栏内，
 *    UP 昵称只在头部区显示一次，标题行为空占位（返回键为 HDS 默认键）；
 *  · 列表走「首个空白占位 ListItem」**穿透模式**（下载页同款）——视口铺满全屏，
 *    首项从标题栏底部起排，滚动时条目从沉浸材质下穿过，滚动模糊由 HDS scrollEffectOpts 接管；
 *  · 非列表分支（骨架 / 失败 / 空态）没有占位条目，各自补 padding top。
 *
 * 缓存策略：进页**不自动联网刷新**——命中 UpSpaceCacheStore 落盘缓存
 * 就直接恢复列表 + 资料 + 分页游标（重启 App 仍生效）；只有显式动作才联网：
 *  · 列表下拉刷新（Refresh 包 List）：强制重拉第一页与资料；
 *  · 头部「订阅」（仅未订阅时）：取投稿建歌单，成功后本页列表与缓存一并换新。
 * 本页不提供「拉取新投稿」：订阅歌单的更新入口在歌单详情页
 * （PlaylistDetail 的「拉取新投稿」按钮）。
 * 无缓存（首次进入）仍走 loadCard + loadPage(1) 联网加载，成功后落盘。
 *
 * 投稿搜索（A+B 混合阶梯）：头部搜索框输入即**本地过滤**
 * 已加载列表（标题/歌手匹配，离线可用）；Enter /「搜索」按钮走远程搜索阶梯：
 * 空间接口 keyword 服务端搜索为主（`searchSpaceVideosByKeyword`，结果 = TA 的
 * 投稿里匹配关键词的全部），被风控 / 0 命中时落回 `searchUpVideosByKeyword`
 * （B 站全站搜关键词 → 按 mid 过滤回该 UP 的投稿）。
 * 渲染源三态切换见 displayTracks()；搜索态不落缓存、不参与翻页。
 */

import * as BilibiliApi from '../api/BilibiliApi';
import { SpaceVideo } from '../api/BilibiliApi';
import { Playlist, Track, buildTrack, ITEM_DISPLAY_LIST, ITEM_DISPLAY_GRID } from '../model/MusicModels';
import { LibraryStore, UpSubscribeResult, PLAYLIST_MAX_ITEMS } from '../service/LibraryStore';
import { UpSpaceCacheEntry, getUpSpaceCache, saveUpSpaceCache } from '../service/UpSpaceCacheStore';
import { DownloadManager, DownloadStartResult, WIFI_ONLY_BLOCKED } from '../service/DownloadManager';
import { currentNetworkLabel } from '../utils/NetworkUtil';
import { NavStackHolder } from '../service/NavStackHolder';
import { ArrayDataSource } from '../utils/ArrayDataSource';
import { UpSpaceRouteParam, SeasonSeriesDetailRouteParam, NavRouteParamReader } from '../service/NavRouteParams';
import { MusicPlayer } from '../player/MusicPlayer';
import { TrackItem } from '../components/TrackItem';
import { TrackCard } from '../components/TrackCard';
import { SkeletonTrackItem } from '../components/SkeletonTrackItem';
import { CoverImage } from '../components/CoverImage';
import { toHttpsUrl, toThumbUrl, stripHtmlTags, parseDurationText } from '../utils/TextUtil';
import { HttpUtil } from '../utils/HttpUtil';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { HdsNavDestination, BottomBuilderShowType } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier,
  TextInputMaterialModifier,
  makeTextInputMaterialModifier
} from '../utils/HeaderBarMaterial';
import { MaterialCompat } from '../utils/MaterialCompat';
import { common } from '@kit.AbilityKit';
import { CustomContentDialog } from '@kit.ArkUI';
import { CONTENT_END_OFFSET, STORE_SAFE_BOTTOM, STORE_SAFE_TOP, STORE_ITEM_DISPLAY_STYLE, STORE_THEME_PRIMARY, STORE_THEME_SURFACE, STORE_THEME_DEEP, STORE_THEME_ON } from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import {
  PairOf,
  PairDataSource,
  makePairs,
  TWO_COL_GAP_VP,
  GRID_EDGE_PADDING_VP,
  TwoColumnLayout
} from '../common/utils/TwoColumnList';
import {
  NAV_TRANSITION_MS,
  BUTTON_RADIUS_VP,
  LIST_FOOTER_HEIGHT_VP
} from '../common/constants/InteractionConstants';
import { showAppToast } from '../components/AppToast';
import { showConfirm } from '../components/AppAlertDialog';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';

/** 每页投稿数：匿名 30；登录态走空间接口可吃满 50（该接口 ps 上限） */
const PAGE_SIZE_ANON: number = 30;
const PAGE_SIZE_LOGGED_IN: number = 50;
/** 失败后「重试」的冷却（ms）：B 站这类接口按 IP 限流，连点只会继续被拒 */
const RETRY_COOLDOWN_MS: number = 4000;

/**
 * UP 资料头部区（bottomBuilder 承载）实测前的估计高度：头像行 + 元信息行 + padding。
 * ⚠️ bottomBuilder 高度不自适应（官方约束），由 titleBar 参数显式给定；实测值
 * （headerAreaHeight）回来后覆盖，此值只防首次布局 0 高闪跳。
 */
const UP_HEADER_ESTIMATE_HEIGHT: number = 206;

/**
 * 头部操作行搜索区 ↔ 多选动作区的交叉淡化时长（ms）：两层同槽位叠放，
 * 一层淡出另一层淡入，布局稳定不跳。
 */
const SELECT_FADE_MS: number = 250;

/**
 * 多选批量下载的串行入队间隔（ms）：requestDownload 内部每首都会调
 * expandVideoParts（一次 view 请求），密集连发会被 B 站匿名限流
 * （PlaylistsPage 整单下载同一条经验），串行 + 留间隔。
 */
const SELECT_ENQUEUE_GAP_MS: number = 350;

/** ArkTS 没有原生 sleep，用 setTimeout 包一个 Promise（批量下载串行节流用） */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}

/** UP 投稿 → 曲目。upMid / upName 由列表所在 UP 决定（投稿条目自身不带 mid）。
 * 时长走 parseDurationText（`mm:ss` / `hh:mm:ss` 两种都认，SpaceVideo.length 是字符串） */
function mapSpaceVideo(v: SpaceVideo, upMid: string, upName: string): Track {
  return buildTrack({
    id: v.bvid,
    bvid: v.bvid,
    aid: String(v.aid ?? 0),
    title: stripHtmlTags(v.title),
    artist: v.author || upName,
    upMid: upMid,
    coverUrl: toHttpsUrl(v.pic),
    duration: parseDurationText(v.length),
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

/** 配对行 LazyForEach/ForEach 的 key：两列 id 拼接（缺右列用 'x' 占位） */
function pairKeyOf(pair: PairOf<Track>): string {
  return `${pair.first.id}|${pair.second !== null ? pair.second.id : 'x'}`;
}

/**
 * 「合集 / 系列」页签卡片模型：合集（UpSeasonSummary）与系列（UpSeriesSummary）
 * 字段同源但类型不同，页签列表渲染与详情页跳转共用本收口模型。
 * kind：'season'（B 站合集 ugc_season）/ 'series'（UP 主手动系列）。
 */
class UpSpaceCollectionCard {
  kind: string;
  itemId: number;
  title: string;
  cover: string;

  constructor(kind: string, itemId: number, title: string, cover: string) {
    this.kind = kind;
    this.itemId = itemId;
    this.title = title;
    this.cover = cover;
  }
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
  /** @Watch 驱动列表数据源同步（见 reloadListSource）：三态渲染源任一变化都整表重载 */
  @State @Watch('onListSourceChanged') tracks: Track[] = [];
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State page: number = 1;
  @State hasMore: boolean = true;
  /** 资料 / 列表是否都失败了（空态区分「没有投稿」与「拉不到」） */
  @State loadFailed: boolean = false;
  /**
   * 失败原因（人话）。
   *
   * B 站的空间接口对匿名访问风控很严（-352 风控校验失败 / -799 请求过于频繁 / HTTP 412），
   * 把 code 显示出来才知道该等风控过去还是该换网络。
   */
  @State failReason: string = '';
  /** 是否已订阅（进页面时按 upMid 查一次本地库） */
  @State subscribed: boolean = false;
  /** 订阅 / 拉新进行中：按钮禁用并显示「处理中…」 */
  @State subBusy: boolean = false;
  /** 重试冷却中：按钮禁用（真正的门在 retryLocked 成员，状态只是给用户看的） */
  @State retryCooling: boolean = false;
  /** 下拉刷新进行中（Refresh 双向绑定 $$refreshing，forceRefresh 复位） */
  @State refreshing: boolean = false;
  // ===== 投稿搜索（本地过滤 + B 站按 mid 过滤搜索，A+B 混合）=====
  /** 搜索框文本：输入即本地过滤已加载列表（onChange 重算）；Enter/「搜索」触发 B 站搜索 */
  @State @Watch('onListSourceChanged') searchKeyword: string = '';
  /** 本地过滤结果（keyword 变化即时重算；keyword 为空 = 不过滤，此数组为空占位） */
  @State @Watch('onListSourceChanged') filteredTracks: Track[] = [];
  /** B 站搜索在途（footer 显示「正在 B 站搜索…」） */
  @State remoteSearching: boolean = false;
  /**
   * B 站搜索结果（**null = 不在远程搜索态**，这是态开关本体；
   * 非 null 时空数组也有效 = 「B 站确实没搜到该 UP 的相关投稿」）。
   */
  @State @Watch('onListSourceChanged') remoteResults: Track[] | null = null;
  /** B 站搜索失败原因（人话，describeError 翻译；空串 = 没失败） */
  @State remoteFailReason: string = '';
  /** 搜索竞态令牌：只认最新一次搜索/清除（照 SearchPage.searchToken 纪律，旧响应丢弃） */
  private searchToken: number = 0;
  private retryLocked: boolean = false;
  private retryTimer: number = -1;

  // ===== 「投稿 / 合集 / 系列」页签（合集/系列 = web-space 聚合物接口） =====
  /** 当前页签：'videos'（投稿，默认）/ 'seasons'（合集）/ 'series'（系列） */
  @State spaceTab: string = 'videos';
  /** 页签行可见（点封面切换）：true = 「投稿/合集/系列」替换「播放全部」操作行 */
  @State tabRowVisible: boolean = false;
  /** 合集卡片（getUpSeasonsSeriesList 一次请求双列表，首次切页签懒加载） */
  @State seasonCards: UpSpaceCollectionCard[] = [];
  /** 系列卡片（与合集同源一次请求） */
  @State seriesCards: UpSpaceCollectionCard[] = [];
  /** 合集/系列列表在途（页签骨架） */
  @State seasonsLoading: boolean = false;
  /** 合集/系列已成功加载（成功后不再重复请求；失败重试走 retrySeasonsSeries） */
  @State seasonsLoaded: boolean = false;
  @State seasonsFailed: boolean = false;
  @State seasonsFailReason: string = '';
  /** 合集/系列重试冷却中（与投稿重试同款 4s 冷却） */
  @State seasonsRetryCooling: boolean = false;
  private seasonsRetryLocked: boolean = false;
  private seasonsRetryTimer: number = -1;
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
  /**
   * `collectTracks()` 全量翻页是否中途失败、只拿到部分（订阅提示用）。
   * false = 拉齐了，或走的是单页兜底链（没有「一半」态）。
   */
  private lastCollectPartial: boolean = false;

  // ===== 投稿多选（头部「选择」按钮进入，批量加入歌单 / 下载） =====
  /** 多选模式：true = 头部「选择」已进入，点投稿切换选中、搜索区淡出为动作区、「⋯」隐藏 */
  @State selecting: boolean = false;
  /**
   * 选中投稿 id 集（track.id = bvid）。切换一律**整表重赋值**（不用 push/splice
   * 原地改）：@State 对数组重赋值的观测路径最稳，配合 TrackItem/TrackCard 的
   * selected @Prop 逐条驱动勾选回显。
   */
  @State selectedIds: string[] = [];
  /** 多选批量下载串行入队进行中（防重复点击：再点「下载」提示稍候） */
  @State downloadingSelected: boolean = false;
  /** 「加入歌单」弹窗曲目（「⋯」单曲 / 多选批量共用一个弹窗） */
  private pickerTracks: Track[] = [];
  /** 弹窗打开时的可加歌单快照（「新建歌单并加入」的重名检查基于它即可） */
  private playlistOptions: Playlist[] = [];
  /**
   * 「加入歌单」弹窗 controller：官方 CustomContentDialog 标准对话框
   * （默认遮罩 + 官方按钮槽，替代原根 Stack 内自绘弹层）。标题/按钮为
   * 常量 → 建一次永不重建（faqs-arkui-555 只定格构造参数，动态内容经
   * contentBuilder 闭包在 open() 时读当次状态）。
   */
  private playlistPickerController: CustomDialogController | undefined = undefined;

  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;

  /** 主题色运行时值：操作按钮与订阅按钮跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 横竖屏（Index 常驻注册写入）：横屏宽屏时投稿条目两列显示 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;

  /** 横屏宽屏（窗口 ≥600vp 的横屏）时条目两列显示；竖屏 / 窄窗口单列不变 */
  private isTwoCol(): boolean {
    return TwoColumnLayout.isActive(this.currentBreakpoint, this.isLandscape);
  }

  /** 条目展示（外观设置「条目展示」）：长条（默认）/ 大封面双列网格 */
  @StorageProp(STORE_ITEM_DISPLAY_STYLE) itemDisplay: string = ITEM_DISPLAY_LIST;

  /** 大封面模式：投稿以双列网格卡（TrackCard）渲染，竖屏 / 横屏均双列 */
  private isGrid(): boolean {
    return this.itemDisplay === ITEM_DISPLAY_GRID;
  }
  /**
   * UP 资料头部区实测高（vp，bottomBuilder 内层根节点 onAreaChange 回写，随元信息行数浮动）。
   * ⚠️ 初值必须为 0：列表带着初值一起挂载会让占位条目先按
   * 不含头部区的让位量排布、实测回来再整体下移（内容跳变）——列表挂载门控直接判
   * headerAreaHeight > 0（barTotalHeight() 恒 > 0 不能当门控），即头部区首次实测
   * 完成后才挂载列表，保证让位量含头部实测高。
   */
  @State headerAreaHeight: number = 0;
  /** 投稿列表滚动控制器：bindToScrollable 绑给 HDS 标题栏驱动滚动模糊 */
  private listScroller: Scroller = new Scroller();
  /** 合集/系列卡片列表滚动控制器：非投稿页签时接管滚动模糊联动与顶部渐变校准 */
  private seasonsScroller: Scroller = new Scroller();
  /**
   * 列表数据源：LazyForEach 驱动源，与 displayTracks()
   * 三态保持同步 —— 三态 @State（tracks / filteredTracks / remoteResults /
   * searchKeyword）都挂 @Watch，任一变化走 reloadListSource 整表重载
   * （reload 语义与三态切换天然匹配：切态必是整表换源）。
   */
  private trackSource: ArrayDataSource<Track> = new ArrayDataSource<Track>([]);
  /** 两列视图数据源（无状态视图，FollowsPage.upPairs 同款）：trackSource 变化处显式 sync() */
  private trackPairs: PairDataSource<Track> = new PairDataSource<Track>(this.trackSource);
  /** 头部按钮（播放全部 / 订阅投稿 / 搜索）与搜索框沉浸光感材质修饰器：26+ 生效，低版本 no-op 显实色兜底 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 搜索框（TextInput）沉浸光感材质修饰器：与 buttonMaterial 同档（THIN + interactive + lightEffect） */
  private searchInputMaterial: TextInputMaterialModifier = makeTextInputMaterialModifier();
  /**
   * 搜索框底色：材质可用（26+）时**透明**——官方 FAQ「背景色遮挡材质效果」：
   * 不透明 backgroundColor 画在材质层之上，玻璃完全被盖住（TextInput 通用背景层
   * 在材质层上方；Button 内部把底色并入材质渲染所以按钮天生透明）。低版本材质
   * 不可用时回落实色 bg_card 兜底，搜索框不至于变成隐形框。
   */
  private searchBoxBg(): ResourceColor {
    return MaterialCompat.hasImmersiveMaterial() ? Color.Transparent : $r('app.color.bg_card');
  }

  /**
   * HDS 标题栏整体让位量（vp）= safeTop + 标题行 56 + 头部区实测高。
   * 头部区高度随元信息行数浮动，无法定值，沿用「实测 + 挂载门控」机制。
   */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT + this.headerAreaHeight;
  }

  /**
   * 自绘顶栏渐变模糊层进度更新器 + 校准（四页签同款）：onDidScroll / onScrollStop
   * 命令式驱动 opacity（不标 @State，滚动高频回调零重建）；yOffset 0 →
   * TITLE_BLUR_END_VP 线性映射 0 → 1（updater 内截断，边缘回弹负偏移归零）。
   */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    // 页签感知：投稿页签走投稿列表，合集/系列页签走卡片列表（未挂载时 offset 恒 0）
    const sc: Scroller = this.spaceTab === 'videos' ? this.listScroller : this.seasonsScroller;
    this.topBlurUpdater.setProgress(
      (sc.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  private player: MusicPlayer = MusicPlayer.getInstance();
  /** 子页转场横移量：常驻 '0%'，转场代理按 push/pop 临时改写 */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    // 挂载前先存当前偏移对应的进度（updater 未挂载只存值，
    // 挂载时 initializeModifier 补上），防「已滚过再进页」首帧缺模糊。
    this.syncTopBlurProgress();
    // 「加入歌单」弹窗：官方标准对话框，标题/按钮常量（见成员声明处注释）。
    // 关闭路径刻意不清暂存数据：关闭有退场动画，清了会让正文在淡出途中
    // 先变空；pickerTracks / playlistOptions 每次打开前都会重写，残留值
    // 无消费方。
    this.playlistPickerController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: '加入歌单',
        contentBuilder: (): void => {
          this.PlaylistPickerBody();
        },
        buttons: [
          {
            value: '取消',
            buttonStyle: ButtonStyleMode.TEXTUAL,
            action: (): void => {
              this.playlistPickerController?.close();
            }
          }
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    // 路由入参：显式参数类随 pushPathByName 入栈，
    // 读取器内部 getParamByName 取回 + instanceof 判型（返回已判型对象或 null）。
    const routeParam: UpSpaceRouteParam | null =
      NavRouteParamReader.readUpSpaceParam(NavStackHolder.stack);
    if (routeParam === null || routeParam.upMid.length === 0) {
      this.loadFailed = true;
      this.failReason = '没有拿到 UP 主信息，请从列表里重新进入';
      return;
    }
    this.upMid = routeParam.upMid;
    this.upName = routeParam.upName;
    // 入口方若已拿到头像（搜 UP 主结果）就先垫上，loadCard 拿到真图后会覆盖
    this.upFace = routeParam.upFace;
    this.refreshSubscriptionState();
    // 缓存读取为异步（getUpSpaceCache 返回 Promise）：恢复逻辑在 async 方法里，
    // aboutToAppear 不同步读文件，页面挂载零阻塞；读缓存异常也在其内部按无缓存兜底。
    this.restoreFromCache();
  }

  /**
   * 缓存命中：直接恢复，不打任何接口 —— loadCard / loadPage 都跳过，
   * 刷新只留显式出口：列表下拉刷新（forceRefresh）与「订阅投稿」成功后的换新。
   * 头像用缓存真图（歌单入口传的是空串占位）；上拉翻页从缓存 page+1 续拉。
   * readText 在异步任务里执行，读完再决定恢复 / 联网。
   */
  private async restoreFromCache(): Promise<void> {
    let cached: UpSpaceCacheEntry | null = null;
    try {
      cached = await getUpSpaceCache(this.upMid);
    } catch (e) {
      // 读缓存异常按无缓存兜底：直接联网拉取
      cached = null;
    }
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
    if (this.seasonsRetryTimer !== -1) {
      clearTimeout(this.seasonsRetryTimer);
      this.seasonsRetryTimer = -1;
    }
  }

  /** 本地是否已有该 UP 的订阅歌单（决定头部是否继续显示「订阅」按钮：已订阅则隐藏） */
  private refreshSubscriptionState(): void {
    const existing = LibraryStore.getPlaylistByUpMid(this.upMid);
    this.subscribed = existing !== null;
  }

  // ===== 数据加载 =====

  /**
   * 写缓存：当前列表 + 资料 + 分页游标整表落盘。
   * tracks / upMid 为空时 no-op（loadCard 先于列表返回时不够一格完整缓存，
   * 等列表成功后由 loadFirstMultiSource 写全量）。
   * 落盘为异步，失败在 saveUpSpaceCache 内部记日志，调用方不等待、不受影响。
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
        // 投稿总数（订阅态元信息行显示 UP 的投稿数而非订阅歌单曲目数）
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
   *     （`hasMore` 直接置 false），底部提示为「仅显示最近投稿 · 订阅可持续获取新投稿」。
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
   * 不用「搜索空 → 空间接口」两级：搜索是按**视频内容**匹配的，
   * UP 昵称不出现在标题里时命中就是 0，会直接掉进风控最强的空间接口
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
   * pn 必须一路透传到 `getUserVideosWithRetry` → `getUserVideos`：
   * 包装层丢页码会恒取第 1 页，上拉翻页反复追加同一批条目，缓存里全是重复。
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
      const mapped: Track[] = this.mapAll(vlist);
      // 翻页边界漂移兜底：拉页期间 UP 发新稿会把后续页整体前移，页 N 尾条可能与
      // 页 N+1 首条相同 —— 追加前按 id 去重，已有条目保留原位置，不重复追加。
      const seen: Set<string> = new Set(this.tracks.map((t: Track): string => t.id));
      const fresh: Track[] = mapped.filter((t: Track): boolean => t.id.length > 0 && !seen.has(t.id));
      this.page = pn;
      // hasMore 按原始返回长度判定：去重后变短只说明页界有重叠，不代表没有下一页；
      // page 即使本页全被去重也要推进，否则会在同一页上死循环。
      this.hasMore = vlist.length >= this.pageSize();
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
    // 远程搜索结果是一次性的（不分页），搜索态上拉到底不触发翻页
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
  private describeError(e: Error, fallback: string = '投稿加载失败'): string {
    const raw: string = e && e.message ? e.message : '';
    if (raw.length === 0) {
      return fallback;
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
   * 下拉刷新：强制联网重拉第一页 + 资料（缓存策略下进页不联网，
   * 这是本页仅存的显式刷新出口）。
   *
   * 有请求在途（loading / loadingMore）时直接收起刷新头，不叠加请求。
   * catch 兜住后 then 必达：loading / refreshing 一定能复位（subscribe
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

  // ===== 合集 / 系列（「投稿 / 合集 / 系列」页签行懒加载） =====

  /** 当前页签的卡片列表（合集 / 系列，视频页签不消费） */
  private currentCards(): UpSpaceCollectionCard[] {
    return this.spaceTab === 'series' ? this.seriesCards : this.seasonCards;
  }

  /**
   * 拉取 UP 的合集 + 系列列表（一次请求双列表，`getUpSeasonsSeriesList`）。
   * 首次切到「合集 / 系列」页签时懒加载；成功后 `seasonsLoaded` 置位不再重复请求
   * （合集/系列低频变化，一次会话拉一次足够）。失败保持未加载态，由失败分支的
   * 「重试」（`retrySeasonsSeries`）重新发起。
   */
  private loadSeasonsSeries(): void {
    if (this.seasonsLoading || this.seasonsLoaded || this.upMid.length === 0) {
      return;
    }
    this.seasonsLoading = true;
    this.seasonsFailed = false;
    this.seasonsFailReason = '';
    BilibiliApi.getUpSeasonsSeriesList(Number(this.upMid))
      .then((res: BilibiliApi.UpSeasonsSeriesResult): void => {
        const seasonCards: UpSpaceCollectionCard[] = [];
        for (let i = 0; i < res.seasons.length; i++) {
          const s: BilibiliApi.UpSeasonSummary = res.seasons[i];
          seasonCards.push(new UpSpaceCollectionCard('season', s.seasonId, s.title, s.cover));
        }
        const seriesCards: UpSpaceCollectionCard[] = [];
        for (let i = 0; i < res.series.length; i++) {
          const s: BilibiliApi.UpSeriesSummary = res.series[i];
          seriesCards.push(new UpSpaceCollectionCard('series', s.seriesId, s.title, s.cover));
        }
        this.seasonCards = seasonCards;
        this.seriesCards = seriesCards;
        this.seasonsLoaded = true;
      })
      .catch((e: Error): void => {
        this.seasonsFailed = true;
        this.seasonsFailReason = this.describeError(
          e instanceof Error ? e : new Error(JSON.stringify(e)), '合集加载失败');
      })
      .then((): void => {
        this.seasonsLoading = false;
      });
  }

  /** 合集/系列加载失败的「重试」（与投稿重试同款 4s 冷却：连点只会继续被风控拒） */
  private retrySeasonsSeries(): void {
    if (this.seasonsRetryLocked) {
      return;
    }
    this.seasonsRetryLocked = true;
    this.seasonsRetryCooling = true;
    this.seasonsRetryTimer = setTimeout((): void => {
      this.seasonsRetryLocked = false;
      this.seasonsRetryCooling = false;
    }, RETRY_COOLDOWN_MS);
    this.loadSeasonsSeries();
  }

  /** 切页签：点「投稿」恢复播放全部操作行；合集/系列保持页签行，按需懒加载合集/系列 */
  private switchSpaceTab(tab: string): void {
    if (this.selecting) {
      this.exitSelecting();
    }
    this.spaceTab = tab;
    // 投稿 = 收起页签行恢复操作行；合集/系列 = 页签行保持可见（否则无法切回）。
    // 幂等赋值：点已激活页签无副作用（loadSeasonsSeries 内部有闸门），
    // 「投稿页签行可见时再点投稿」也能借此恢复操作行。
    this.tabRowVisible = tab !== 'videos';
    // 失败态不自动重发（保留冷却纪律），只有「重试」按钮能再发起
    if (tab !== 'videos' && !this.seasonsLoaded && !this.seasonsFailed) {
      this.loadSeasonsSeries();
    }
    // 页签切换后可见滚动容器换人（投稿列表 ↔ 卡片列表），按新容器偏移重新校准
    this.syncTopBlurProgress();
  }

  /**
   * 封面（UP 头像）点击：操作行 ↔ 页签行切换。
   * 投稿页签下是开关（再点收起页签行、恢复操作行）；合集/系列页签下页签行
   * 本就可见且是唯一导航，no-op（点「投稿」才恢复操作行）。
   */
  private onCoverTapped(): void {
    if (this.spaceTab !== 'videos') {
      return;
    }
    // 展示页签行前退出多选：选区动作按钮随操作行一起消失，选区挂着会卡死
    if (this.selecting && !this.tabRowVisible) {
      this.exitSelecting();
    }
    this.tabRowVisible = !this.tabRowVisible;
  }

  /** 打开合集/系列详情页（kind 决定详情页走哪个条目分页接口） */
  private openCollectionDetail(card: UpSpaceCollectionCard): void {
    NavStackHolder.stack.pushPathByName('SeasonSeriesDetail', new SeasonSeriesDetailRouteParam(
      card.kind, this.upMid, String(card.itemId), card.title, card.cover, this.upName, this.upMid
    ));
  }

  // ===== 投稿搜索 =====

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

  /** 三态渲染源任一变化（@Watch）：同步列表数据源（整表重载 + 两列视图 sync） */
  private onListSourceChanged(): void {
    // 渲染源整表换源时退出多选：选区引用的是旧源条目（过滤词变了 / 远程结果
    // 到了 / 刷新换列表），跨态保留选区会把用户看不见的条目悄悄加进歌单。
    if (this.selecting) {
      this.exitSelecting();
    }
    this.trackSource.reload(this.displayTracks());
    this.trackPairs.sync();
  }

  /**
   * 本地过滤（方案 A）：标题 / 歌手包含关键词（小写化匹配），输入即生效、离线可用。
   * keyword 为空 → 空数组（displayTracks 会退回全量列表）。
   * tracks 换新 / 追加的三处（loadFirstMultiSource / loadPageViaSpace / subscribe）
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
   * 远程搜索（点「搜索」/ Enter）：空间内服务端搜索为主 → 全站搜索兜底的阶梯。
   *
   * ① 空间接口 keyword 搜索（`searchSpaceVideosByKeyword`，B 站空间页「搜索
   *   TA 的投稿」同款）—— 结果 = TA 的投稿里匹配关键词的**全部**（按
   *   page.count 精确翻页），不受全站搜索前 60 条截断的限制；
   * ② ①被风控（searchOk=false）或 0 命中时，落回全站搜索 + mid 过滤
   *   （`fallbackToSitewideSearch`）—— 0 命中也再捞
   *   一轮，防空间索引口径与全站不同导致误报「没搜到」。
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
    BilibiliApi.searchSpaceVideosByKeyword(this.upMid, kw)
      .then((res: BilibiliApi.UpVideosSearchResult): void => {
        if (token !== this.searchToken) {
          return;
        }
        if (res.searchOk && res.list.length > 0) {
          this.remoteSearching = false;
          this.remoteResults = this.mapAll(res.list);
          console.info(`[UpSearch] via=space n=${this.remoteResults.length}`);
          return;
        }
        // 空间被风控（searchOk=false）或 0 命中 → 全站兜底
        this.fallbackToSitewideSearch(kw, token);
      })
      .catch((): void => {
        if (token !== this.searchToken) {
          return;
        }
        this.fallbackToSitewideSearch(kw, token);
      });
  }

  /**
   * 阶梯第②步：全站搜索兜底（`searchUpVideosByKeyword`）。
   */
  private fallbackToSitewideSearch(kw: string, token: number): void {
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
        console.info(`[UpSearch] via=sitewide n=${this.remoteResults.length}`);
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
   * 首次订阅：取该 UP 的**全部**投稿（封顶 PLAYLIST_MAX_ITEMS）→ 建成订阅歌单。
   *
   * 刻意**先取数据再建歌单**：直接建一个空歌单的话，接口失败就会留下一个永远空着的壳。
   * 取数据走 `collectUpVideosAll`（count 精确翻页 + 单页多源兜底），见 `collectTracks` 注释。
   */
  private subscribe(): void {
    if (this.subBusy) {
      return;
    }
    this.subBusy = true;
    showAppToast('正在订阅，拉取全部投稿…', 1600);
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
        this.showSubscribeResult(r);
        // 订阅取回的就是该 UP 的最新投稿页：与「拉取新投稿」同样把
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
      // 与 forceRefresh 同理：缺这个 catch 时，订阅失败会让 subBusy 永久卡死，
      // 按钮再也点不动。
      .catch((e: Error): void => {
        console.error(`subscribe failed: ${e.message}`);
        showAppToast(`订阅失败：${e.message}`, 2000);
      })
      .then((): void => {
        this.subBusy = false;
      });
  }

  /**
   * 取该 UP 的**全部**投稿（订阅用，封顶 `PLAYLIST_MAX_ITEMS`），返回已映射成 Track 的列表。
   *
   * 走 `collectUpVideosAll`：空间接口按响应里的 `page.count` 精确翻页；第 1 页失败
   * 落回单页多源兜底（搜索反查 → related 扩散 → 空间老路）；
   * 中途翻页失败**保留已拉到的部分**（`lastCollectPartial` 置 true，提示文案据此
   * 告诉用户「稍后再订阅可补齐」——歌单按 id 去重幂等，重复订阅不会灌重复条目）。
   *
   * `seeds` 是 related 扩散用的种子 bvid：首次订阅时歌单还没建，用**当前列表页已加载的**
   * tracks。没有种子时那一级自动跳过。
   *
   * 失败时**不抛**，而是把人话原因写进 `lastCollectError` 并返回空数组 ——
   * 调用方据此给用户一句能判断「该等还是该换网络」的提示。
   */
  private async collectTracks(seeds: string[]): Promise<Track[]> {
    this.lastCollectError = '';
    this.lastCollectPartial = false;
    const res: BilibiliApi.UpVideosCollectResult =
      await BilibiliApi.collectUpVideosAll(
        this.upMid,
        this.upName,
        seeds,
        PLAYLIST_MAX_ITEMS,
        (fetched: number): void => {
          // 每成功一页刷一次进度（替换式 toast，不堆积）；全量翻页可能要几秒到几十秒
          showAppToast(`已拉取 ${fetched} 条…`, 1000);
        }
      );
    this.sourceVia = res.via;
    if (res.list.length > 0) {
      this.lastCollectPartial = res.partial;
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

  private showSubscribeResult(r: UpSubscribeResult): void {
    const parts: string[] = [];
    parts.push(r.added === 1 ? '新增 1 首' : `新增 ${r.added} 首`);
    if (r.dropped > 0) {
      parts.push(`已满 ${r.playlist.tracks.length} 首，更早的未收`);
    }
    if (this.lastCollectPartial) {
      // 全量翻页中途有页失败：已收部分先入库，再点一次订阅即可补齐（mergeUpTracks 按 id 去重幂等）
      parts.push('网络不稳只拉到部分，稍后再订阅可补齐');
    }
    const prefix: string = r.reused ? '已更新订阅' : '已订阅';
    showAppToast(`${prefix}，${parts.join('，')}`, this.lastCollectPartial ? 3000 : 2000);
  }

  // ===== 投稿多选（头部「选择」按钮进入，批量加入歌单 / 下载） =====

  /** 进入多选（头部「选择」按钮）：选区从空起步，条目点击切换选中 */
  private enterSelecting(): void {
    this.selecting = true;
    this.selectedIds = [];
  }

  /** 切换选中（多选态点投稿 / 点勾选槽位） */
  private toggleSelected(track: Track): void {
    if (this.selectedIds.indexOf(track.id) >= 0) {
      this.selectedIds = this.selectedIds.filter((id: string): boolean => id !== track.id);
      return;
    }
    const next: string[] = this.selectedIds.slice(0);
    next.push(track.id);
    this.selectedIds = next;
  }

  /** 全选判定：与当前渲染源（三态）比对，全选的是「正在看的那份列表」 */
  private isAllSelected(): boolean {
    const shown: Track[] = this.displayTracks();
    if (shown.length === 0) {
      return false;
    }
    for (let i = 0; i < shown.length; i++) {
      if (this.selectedIds.indexOf(shown[i].id) < 0) {
        return false;
      }
    }
    return true;
  }

  /** 全选 / 取消全选（工具条按钮） */
  private toggleSelectAll(): void {
    if (this.isAllSelected()) {
      this.selectedIds = [];
      return;
    }
    const shown: Track[] = this.displayTracks();
    const ids: string[] = [];
    for (let i = 0; i < shown.length; i++) {
      ids.push(shown[i].id);
    }
    this.selectedIds = ids;
  }

  /** 退出多选（「完成」/ 返回键 / 渲染源切换） */
  private exitSelecting(): void {
    this.selecting = false;
    this.selectedIds = [];
  }

  /** 选中的投稿（按渲染源收口：渲染源里已不存在的 id 自动略过，不盲信选区） */
  private selectedTracks(): Track[] {
    const shown: Track[] = this.displayTracks();
    return shown.filter((t: Track): boolean => this.selectedIds.indexOf(t.id) >= 0);
  }

  // ===== 加入歌单（DownloadsPage 同款：无歌单自动建单兜底 + 选择弹层；多曲批量走 addTracksToPlaylist） =====

  /** 没有任何可加歌单时的兜底：新建歌单并直接加入（名字取自第一首） */
  private createPlaylistAndAdd(tracks: Track[], existing: Playlist[]): void {
    const name: string = LibraryStore.nextPlaylistNameForTrack(tracks[0], existing);
    const created: Playlist = LibraryStore.createPlaylist({ name: name });
    const updated: Playlist | null = LibraryStore.addTracksToPlaylist(created.id, tracks);
    showAppToast(updated ? `已新建歌单「${name}」并加入` : '加入歌单失败', 1800);
  }

  /**
   * 打开「加入歌单」选择弹层；可加歌单为空时跳过弹层直接自动建单。
   * 歌单列表走 getAddablePlaylists（过滤 UP 订阅歌单：订阅歌单由订阅机制
   * 维护曲目，手动加歌会被「拉取新投稿」合并逻辑搅乱）。
   */
  private openPickerFor(tracks: Track[]): void {
    if (tracks.length === 0) {
      return;
    }
    const options: Playlist[] = LibraryStore.getAddablePlaylists();
    if (options.length === 0) {
      this.createPlaylistAndAdd(tracks, options);
      return;
    }
    this.playlistOptions = options;
    this.pickerTracks = tracks;
    this.playlistPickerController?.open();
  }

  /** 弹层里的「新建歌单并加入」（省一次跳转；快照沿用弹层打开时的列表，重名检查基于它即可） */
  private createPlaylistFromPicker(): void {
    const tracks: Track[] = this.pickerTracks;
    const options: Playlist[] = this.playlistOptions;
    this.playlistPickerController?.close();
    if (tracks.length > 0) {
      this.createPlaylistAndAdd(tracks, options);
    }
  }

  private addToPlaylistFromPicker(p: Playlist): void {
    const tracks: Track[] = this.pickerTracks;
    this.playlistPickerController?.close();
    if (tracks.length === 0) {
      return;
    }
    const updated: Playlist | null = LibraryStore.addTracksToPlaylist(p.id, tracks);
    showAppToast(updated ? `已加入「${p.name}」` : '加入歌单失败', 1600);
  }

  /**
   * 多选动作区「加入歌单」：选区投稿开弹层。
   * 加入成功后**保持多选态与选区**（DownloadsPage 口径）：用户可再选一个歌单
   * 连着加，不必从头重选。选区清空出口只有「完成」/ 返回键 / 渲染源切换。
   */
  private addSelectedToPlaylist(): void {
    const tracks: Track[] = this.selectedTracks();
    if (tracks.length === 0) {
      showAppToast('还没有选中投稿', 1500);
      return;
    }
    this.openPickerFor(tracks);
  }

  /**
   * 多选动作区「下载」：先确认，再串行入队（间隔见 SELECT_ENQUEUE_GAP_MS）。
   * 入队后保持多选态与选区（与「加入歌单」同口径，用户可继续操作选区）。
   */
  private confirmDownloadSelected(): void {
    const tracks: Track[] = this.selectedTracks();
    if (tracks.length === 0) {
      showAppToast('还没有选中投稿', 1500);
      return;
    }
    showConfirm(this.getUIContext(), {
      title: '下载选中投稿',
      message: `将把选中的 ${tracks.length} 首投稿加入下载队列。\n已下载的会自动跳过。`,
      confirmText: '开始下载',
      onConfirm: (): void => {
        this.enqueueSelectedSerial(tracks);
      }
    });
  }

  /**
   * 串行入队核心：ignoreWifiLimit=true 时跳过「仅 WiFi」闸门（用户已在弹窗确认）。
   * 每首间隔节流（B 站匿名密集请求直接限流，见 SELECT_ENQUEUE_GAP_MS）。
   * 「仅 WiFi 下载」闸门在 requestDownload 入口，只会在**首条**返回 blockedReason ——
   * 用它探测一次，被拦则询问，用户确认后整批以 ignoreWifiLimit 重跑（已入队的
   * 自动跳过计数，PlaylistsPage 整单下载同一套逻辑）。
   */
  private async enqueueBatch(tracks: Track[], ignoreWifiLimit: boolean): Promise<void> {
    let queued: number = 0;
    let skipped: number = 0;
    for (let i = 0; i < tracks.length; i++) {
      const r: DownloadStartResult = await DownloadManager.getInstance().requestDownload(tracks[i], ignoreWifiLimit);
      if (!ignoreWifiLimit && r.blockedReason.length > 0) {
        // 首条就被「仅 WiFi 下载」拦下：收尾状态交给确认弹窗的两条分支
        this.downloadingSelected = false;
        this.confirmCellularSelected(tracks);
        return;
      }
      queued += r.queued;
      skipped += r.skipped;
      if (!ignoreWifiLimit && (i + 1) % 5 === 0) {
        showAppToast(`正在加入下载队列（${i + 1}/${tracks.length}）`, 800);
      }
      if (i < tracks.length - 1) {
        await delay(SELECT_ENQUEUE_GAP_MS);
      }
    }
    this.downloadingSelected = false;
    showAppToast(this.selectedDownloadResultText(queued, skipped), 2500);
  }

  private async enqueueSelectedSerial(tracks: Track[]): Promise<void> {
    if (this.downloadingSelected) {
      showAppToast('正在加入下载队列，请稍候', 1500);
      return;
    }
    this.downloadingSelected = true;
    await this.enqueueBatch(tracks, false);
  }

  /** 「仅 WiFi 下载」拦下批量下载：问一次（措辞与单曲 confirmDownloadOnCellular 一致） */
  private confirmCellularSelected(tracks: Track[]): void {
    showConfirm(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: `${WIFI_ONLY_BLOCKED}\n当前网络：${currentNetworkLabel()}`,
      confirmText: '继续下载',
      onConfirm: (): void => {
        this.enqueueSelectedWithWifiOverride(tracks);
      }
    });
  }

  /** 用户确认用流量后：整批 ignoreWifiLimit=true 重跑（已入队/已下载的自动跳过） */
  private async enqueueSelectedWithWifiOverride(tracks: Track[]): Promise<void> {
    if (this.downloadingSelected) {
      return;
    }
    this.downloadingSelected = true;
    await this.enqueueBatch(tracks, true);
  }

  /** 批量入队结果文案：排上 / 跳过 分开说，用户才知道有多少真进了队列 */
  private selectedDownloadResultText(queued: number, skipped: number): string {
    if (queued === 0 && skipped === 0) {
      return '没有可下载的投稿';
    }
    if (queued === 0) {
      return `全部已在下载队列中（${skipped} 首）`;
    }
    const tail: string = skipped > 0 ? `，跳过 ${skipped} 首已在队列/已下载` : '';
    return `已加入下载队列 ${queued} 首${tail}`;
  }

  // ===== 曲目菜单（加入队列 / 加入歌单 / 下载） =====

  /** 「⋯」标准菜单项（bindMenu + MenuElement 数组） */
  private trackMenuItems(track: Track): MenuElement[] {
    return [
      {
        value: '加入队列',
        action: (): void => {
          this.player.addToQueue(track);
          showAppToast('已加入播放队列', 1500);
        }
      },
      // 加入歌单（对齐 SearchPage 菜单顺序惯例：加入队列 → 加入歌单 → 下载）
      {
        value: '加入歌单',
        action: (): void => {
          this.openPickerFor([track]);
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
    showConfirm(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: `${WIFI_ONLY_BLOCKED}\n当前网络：${currentNetworkLabel()}`,
      confirmText: '继续下载',
      onConfirm: (): void => {
        DownloadManager.getInstance().requestDownload(track, true)
          .then((r: DownloadStartResult): void => {
            showAppToast(r.queued > 0 ? `已开始下载 ${r.queued} 首` : '没有可下载的曲目', 1800);
          })
          .catch((e: Error): void => {
            console.error(`requestDownload(ignoreWifiLimit) failed: ${e.message}`);
            showAppToast('下载启动失败', 1800);
          });
      }
    });
  }

  /**
   * 「加入歌单」弹窗正文（官方 CustomContentDialog，DownloadsPage 同款；
   * 多曲时曲名行带「等 N 首」）。标题在 primaryTitle；取消在 buttons 槽
   * （自动关闭）。
   */
  @Builder
  PlaylistPickerBody(): void {
    Column() {
      // 曲名行：单曲（「⋯」菜单入口）显示曲名；多选批量显示「曲名 等 N 首」
      Text(this.pickerTracks.length > 1
        ? `${this.pickerTracks[0].title} 等 ${this.pickerTracks.length} 首`
        : (this.pickerTracks.length > 0 ? this.pickerTracks[0].title : ''))
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ bottom: 12 })
      // 第一项就是「新建歌单并加入」：想单独存一首歌时不必再跑到歌单页
      Row() {
        Text('＋ 新建歌单并加入')
          .fontSize(16)
          .fontColor(this.themeDeep)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.press_overlay')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .onClick((): void => {
        this.createPlaylistFromPicker();
      })
      Divider()
        .color($r('app.color.bg_divider'))
      List() {
        ForEach(
          this.playlistOptions,
          (p: Playlist): void => {
            ListItem() {
              Row() {
                Text(p.name)
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(`${p.tracks.length} 首`)
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              .padding({ top: 12, bottom: 12 })
              .stateStyles({
                pressed: { .backgroundColor($r('app.color.press_overlay')) },
                normal: { .backgroundColor(Color.Transparent) }
              })
              .onClick((): void => {
                this.addToPlaylistFromPicker(p);
              })
            }
          },
          // key 含渲染字段（与 PlaylistsPage 同因）：改名/数量变化后行才会重渲染
          (p: Playlist): string => `${p.id}_${p.name}_${p.tracks.length}`
        )
      }
      .width('100%')
      .edgeEffect(EdgeEffect.Spring)
      .constraintSize({ maxHeight: 260 })
    }
    .width('100%')
  }

  /**
   * 大封面网格配对行（ListItem 内容）：LazyForEach / ForEach 双渲染路径共用。
   * 选择态在这读取（DownloadsPage.GroupContent 同款）：ForEach 路径随页面
   * @State 重跑 builder 就地更新勾选；LazyForEach 路径仅在非多选态挂载，
   * 选择态恒为关。
   */
  @Builder
  GridPairRow(pair: PairOf<Track>): void {
    Row() {
      TrackCard({
        track: pair.first,
        onPlay: (tr: Track): void => {
          this.player.playOrToggle(tr);
        },
        moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr),
        selecting: this.selecting,
        selected: this.selectedIds.indexOf(pair.first.id) >= 0,
        onToggleSelect: (tr: Track): void => {
          this.toggleSelected(tr);
        }
      }).layoutWeight(1)
      // 固定宽间隔条（非 weighted）：两卡均 layoutWeight(1) 且零
      // margin → 左右封面严格等宽（layoutWeight 份额含 margin，
      // margin 挂 weighted 卡会让该卡窄 12vp）；奇数末行也保留
      // 间隔条，末卡与满行卡等宽。
      Blank().width(TWO_COL_GAP_VP)
      if (pair.second !== null) {
        TrackCard({
          track: pair.second,
          onPlay: (tr: Track): void => {
            this.player.playOrToggle(tr);
          },
          moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr),
          selecting: this.selecting,
          selected: this.selectedIds.indexOf(pair.second.id) >= 0,
          onToggleSelect: (tr: Track): void => {
            this.toggleSelected(tr);
          }
        }).layoutWeight(1)
      } else {
        // 奇数末尾：右侧槽留空占位，左列卡宽与前面各行一致
        Blank().layoutWeight(1)
      }
    }
    .width('100%')
    // 网格行页边距：两边留白 + 封面整体
    // 缩小约 15%，见 GRID_EDGE_PADDING_VP 注释。
    .padding({ left: GRID_EDGE_PADDING_VP, right: GRID_EDGE_PADDING_VP })
    // Top 对齐：卡高随标题行数浮动，
    // Row 默认 Center 会把矮卡垂直居中 → 左右封面错位；
    // Top 让左右封面严格同高起步。
    .alignItems(VerticalAlign.Top)
  }

  /**
   * 横屏宽屏配对行（ListItem 内容）：双渲染路径共用，选择态读取见 GridPairRow。
   */
  @Builder
  TwoColPairRow(pair: PairOf<Track>, pIndex: number): void {
    Row() {
      TrackItem({
        track: pair.first,
        entranceIndex: pIndex * 2,
        onPlay: (tr: Track): void => {
          this.player.playOrToggle(tr);
        },
        moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr),
        selecting: this.selecting,
        selected: this.selectedIds.indexOf(pair.first.id) >= 0,
        onToggleSelect: (tr: Track): void => {
          this.toggleSelected(tr);
        }
      }).layoutWeight(1)
      if (pair.second !== null) {
        TrackItem({
          track: pair.second,
          entranceIndex: pIndex * 2 + 1,
          onPlay: (tr: Track): void => {
            this.player.playOrToggle(tr);
          },
          moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr),
          selecting: this.selecting,
          selected: this.selectedIds.indexOf(pair.second.id) >= 0,
          onToggleSelect: (tr: Track): void => {
            this.toggleSelected(tr);
          }
        }).layoutWeight(1).margin({ left: TWO_COL_GAP_VP })
      } else {
        // 奇数末尾：右侧槽留空占位，左列行宽与前面各行一致
        Blank().layoutWeight(1)
      }
    }
    .width('100%')
  }

  /**
   * 单列行（ListItem 内容）：双渲染路径共用，选择态读取见 GridPairRow。
   */
  @Builder
  SingleTrackRow(t: Track, index: number): void {
    TrackItem({
      track: t,
      entranceIndex: index,
      onPlay: (tr: Track): void => {
        this.player.playOrToggle(tr);
      },
      moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr),
      selecting: this.selecting,
      selected: this.selectedIds.indexOf(t.id) >= 0,
      onToggleSelect: (tr: Track): void => {
        this.toggleSelected(tr);
      }
    })
  }

  /**
   * 大封面网格列表条目区（build() 抽出）。条目渲染的非多选 / 多选双路径纪律
   * （三个 *TrackItems 共用）：非多选走 LazyForEach，多选走 ForEach ——
   * LazyForEach 只认数据源通知，@Prop 选择态不随页面 @State 同步
   * （勾选不亮、「⋯」不隐、点击仍走 onPlay），多选必须 ForEach ——
   * 随页面 @State 重跑 itemGenerator 就地更新（DownloadsPage 多选同因）；
   * 进出多选切换渲染控件的一次性整表重建视为模式转场。
   * 渲染源走 displayTracks() 三态切换（远程搜索结果 / 本地过滤结果 / 全量已加载），
   * @Watch（onListSourceChanged）把三态 @State 的变化同步进
   * trackSource / trackPairs，按需建行、翻页不全量重建。
   */
  @Builder
  GridTrackItems(): void {
    if (this.selecting) {
      ForEach(
        makePairs<Track>(this.displayTracks()),
        (pair: PairOf<Track>): void => {
          ListItem() {
            this.GridPairRow(pair)
          }
        },
        pairKeyOf
      )
    } else {
      LazyForEach(
        this.trackPairs,
        (pair: PairOf<Track>): void => {
          ListItem() {
            this.GridPairRow(pair)
          }
        },
        pairKeyOf
      )
    }
  }

  /** 横屏宽屏两列列表条目区（双路径口径见 GridTrackItems） */
  @Builder
  TwoColTrackItems(): void {
    if (this.selecting) {
      ForEach(
        makePairs<Track>(this.displayTracks()),
        (pair: PairOf<Track>, pIndex: number): void => {
          ListItem() {
            this.TwoColPairRow(pair, pIndex)
          }
        },
        pairKeyOf
      )
    } else {
      LazyForEach(
        this.trackPairs,
        (pair: PairOf<Track>, pIndex: number): void => {
          ListItem() {
            this.TwoColPairRow(pair, pIndex)
          }
        },
        pairKeyOf
      )
    }
  }

  /** 单列列表条目区（双路径口径见 GridTrackItems） */
  @Builder
  SingleTrackItems(): void {
    if (this.selecting) {
      ForEach(
        this.displayTracks(),
        (t: Track, index: number): void => {
          ListItem() {
            this.SingleTrackRow(t, index)
          }
        },
        (t: Track): string => t.id
      )
    } else {
      LazyForEach(
        this.trackSource,
        (t: Track, index: number): void => {
          ListItem() {
            this.SingleTrackRow(t, index)
          }
        },
        (t: Track): string => t.id
      )
    }
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
    * 本页的粉丝数 / 投稿数 / 订阅状态在 loadCard、loadPage、subscribe 三处各自变化，
    * 预计算要在每个点都记得刷新一次，漏一处就显示旧值。
   * 这里是纯字符串拼接，直接调方法永远拿到最新值。
   * ⚠️ @Builder 体内**不声明局部变量**，所以走方法调用而不是在 build 里拼。
   */
  private upMetaText(): string {
    const parts: string[] = [];
    if (this.fans > 0) {
      parts.push(`粉丝 ${formatFans(this.fans)}`);
    }
    if (this.subscribed) {
      // 订阅态显示 UP 的投稿总数（card 的 archive_count），不显示订阅歌单的
      // 曲目数 —— 两者经常不相等（订阅时只装了当时加载到的投稿），后者会让
      // 用户误以为 UP 的投稿就这么多。未知时（旧缓存 / 卡片被风控）退回已加载
      // 条数做近似，口径仍与未订阅分支一致。
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
   * 左侧 96vp 圆角头像 + 右侧 28fp 大标题 + 元信息行；头像行下方是操作行
   * （单行：播放全部 + 订阅（仅未订阅）+ 搜索框（框内 × 清除）+ 搜索）。
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
        .onClick((): void => {
          this.onCoverTapped();
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

      // 操作行：播放全部 + 选择 + 订阅（仅未订阅）+ 搜索框（含框内 ×
      // 清除）+ 搜索按钮，单行排布（新增按钮后搜索框靠 layoutWeight 收窄适应）。
      // 订阅处理中（subBusy）：搜索框与搜索按钮暂离（尾部槽位留空），
      // 处理结束后淡入回归，见下方尾部槽位条件渲染。
      // · 播放全部：有投稿才显示；样式与 RecentPage 逐字一致（真机约束，勿动）。
      // · 选择：多选入口（播放全部右边）；多选态变身「完成」退出，同一颗按钮
      //   承担进出，位置恒定不跳。播放全部 / 订阅投稿在多选态用 visibility
      //   摘出布局让位（opacity 不摘布局会留空洞，不能用；属性摘出无过渡，
      //   DownloadsPage 同款可接受）。
      // · 订阅：本页核心动作（未订阅时显示，订阅后消失）——
      //   按钮文案只留「订阅」两字：四字版会挤压同行搜索框。
      //   （本页没有「拉取新投稿」，订阅歌单的更新入口在歌单详情页）。
      // · 清除不用独立按钮：搜索框内右侧 × 承接（点击调 clearSearch，
      //   有关键词或处于远程结果态时才出现）。
      Row({ space: 8 }) {
        if (this.tracks.length > 0) {
          // 真机要求：与 RecentPage 播放全部逐字一致（浅粉底 + 粉字 + 沉浸光感）
          Button('播放全部', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .visibility(this.selecting ? Visibility.None : Visibility.Visible)
            .onClick((): void => {
              this.player.playAll(this.tracks);
            })
        }
        if (this.tracks.length > 0) {
          Button(this.selecting ? '完成' : '选择', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .onClick((): void => {
              if (this.selecting) {
                this.exitSelecting();
              } else {
                this.enterSelecting();
              }
            })
        }
        if (this.upMid.length > 0 && !this.subscribed) {
          Button(this.subBusy ? '处理中…' : '订阅', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .enabled(!this.subBusy)
            .visibility(this.selecting ? Visibility.None : Visibility.Visible)
            .onClick((): void => {
              this.subscribe();
            })
        }
        // 尾部槽位（layoutWeight 1）条件换层：常态 = 搜索框 + 搜索按钮，
        // 多选态 = 全选 / 加入歌单 / 下载；订阅处理中（subBusy）常态层也
        // 不挂载、槽位留空，搜索区随 subBusy 复位经既有 transition 淡入回归。
        // ⚠️ 隐藏层必须用条件渲染（不挂载），不能双层叠放 + 透明层：
        // HitTestMode.None 只豁免容器自身，子按钮仍响应点击（真机复现：
        // 常态点搜索框位置误触透明的「加入歌单」/「下载」，搜索框要点多次）。
        // 条件渲染让隐藏层根本不存在，从源头杜绝；淡入淡出走 transition
        //（插入/移除动画，换层时旧层淡出新层淡入）。
        // 动作按钮不带计数（窄屏放不下，空选区由各动作方法 toast 兜底）。
        Stack() {
          if (!this.selecting && !this.subBusy) {
          // 常态层：搜索框 + 搜索按钮
          Row({ space: 8 }) {
            // 搜索框：输入即过滤**已加载**的投稿（本地，离线可用）；
            // Enter / 「搜索」按钮发起远程搜索（空间接口 keyword 服务端搜索为主，
            // 被风控 / 0 命中时全站搜索 + mid 过滤兜底，见 runRemoteSearch 阶梯）。
            // 框内右侧 × = 清除。
            Stack({ alignContent: Alignment.End }) {
              TextInput({ placeholder: '搜索 TA 的投稿', text: this.searchKeyword })
                .height(32)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_tertiary'))
                .placeholderFont({ size: 14 })
                // 底色走 searchBoxBg()：26+ 材质可用时透明（不透明底会盖住材质层玻璃，
                // 官方 FAQ 同款结论），低版本回落 bg_card 实色兜底。
                .backgroundColor(this.searchBoxBg())
                .borderRadius(BUTTON_RADIUS_VP)
                // 沉浸光感材质：26+ 渲染 systemMaterial 玻璃底
                //（与同行按钮同档），低版本 no-op 走上方链式 bg_card 实色兜底。
                .attributeModifier(this.searchInputMaterial)
                // 右侧让位给框内 ×：文字滚动到最右时不被图标盖住
                .padding({ left: 14, right: 34 })
                .onChange((v: string): void => {
                  this.searchKeyword = v;
                  this.onKeywordChanged();
                })
                .onSubmit((): void => {
                  this.runRemoteSearch();
                })
              if (this.searchKeyword.trim().length > 0 || this.remoteResults !== null) {
                Stack() {
                  SymbolGlyph($r('sys.symbol.xmark'))
                    .fontSize(14)
                    // SymbolGlyph.fontColor 按图层接收颜色数组，单色也传单元素数组
                    .fontColor([$r('app.color.text_tertiary')])
                }
                .width(24)
                .height(24)
                .margin({ right: 8 })
                .onClick((): void => {
                  this.clearSearch();
                })
              }
            }
            .layoutWeight(1)
            Button(this.remoteSearching ? '搜索中' : '搜索', { type: ButtonType.Normal })
              .fontSize(13)
              .height(32)
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
          }
          .width('100%')
          .transition(TransitionEffect.OPACITY
            .animation({ duration: SELECT_FADE_MS, curve: Curve.EaseInOut }))
          } else if (this.selecting) {
          // 多选态层：全选 / 加入歌单 / 下载（淡入替换搜索区）
          Row({ space: 8 }) {
            Button(this.isAllSelected() ? '取消全选' : '全选', { type: ButtonType.Normal })
              .fontSize(13)
              .height(32)
              .borderRadius(BUTTON_RADIUS_VP)
              .backgroundColor(this.themeSurface)
              .fontColor(this.themePrimary)
              .attributeModifier(this.buttonMaterial)
              .onClick((): void => {
                this.toggleSelectAll();
              })
            Button('加入歌单', { type: ButtonType.Normal })
              .fontSize(13)
              .height(32)
              .borderRadius(BUTTON_RADIUS_VP)
              .backgroundColor(this.themeSurface)
              .fontColor(this.themePrimary)
              .attributeModifier(this.buttonMaterial)
              .onClick((): void => {
                this.addSelectedToPlaylist();
              })
            Button('下载', { type: ButtonType.Normal })
              .fontSize(13)
              .height(32)
              .borderRadius(BUTTON_RADIUS_VP)
              .backgroundColor(this.themeSurface)
              .fontColor(this.themePrimary)
              .attributeModifier(this.buttonMaterial)
              .onClick((): void => {
                this.confirmDownloadSelected();
              })
          }
          .width('100%')
          .transition(TransitionEffect.OPACITY
            .animation({ duration: SELECT_FADE_MS, curve: Curve.EaseInOut }))
          }
          // 其余情形（非多选 && subBusy）：订阅处理中，槽位不渲染任何层（留空），
          // 处理结束（成功 / 失败都复位 subBusy）后常态层淡入回归。
        }
        .layoutWeight(1)
        // ⚠️ 固定高度：消失转场期间退场节点脱离布局，Stack 无固定高度会塌缩
        // 到 0、退场动画节点被按塌缩位置渲染（真机表现：订阅处理中搜索区
        // 「向下移走」而非原位淡出）。固定 32 = 同行按钮高度，槽位空置 / 换层
        // 时框架恒定，淡入淡出始终原位播放（官方 FAQ faqs-arkui-384 同款结论：
        // 固定内层容器宽高）。
        .height(32)
      }
      .width('100%')
      .margin({ top: 12 })
      .alignItems(VerticalAlign.Center)
      // 操作行两隐藏场景：合集/系列页签（播放全部/搜索都是投稿语义）与封面点击
      // 展开的页签行占用本槽位（tabRowVisible；与页签行同尺寸互斥换层，
      // headerAreaHeight 实测不受影响）。
      .visibility(this.spaceTab === 'videos' && !this.tabRowVisible ? Visibility.Visible : Visibility.None)

      // 「投稿 / 合集 / 系列」页签行（默认隐藏：点封面展开，点「投稿」收起）：
      // 与操作行同槽位互斥换层（两行同高：32vp 按钮 + margin 12，替换无布局跳变）；
      // 合集/系列首次触达才拉取（switchSpaceTab 内懒加载）；当前页签实底高亮。
      // 三枚等宽（layoutWeight 1）。
      Row({ space: 8 }) {
        Button('投稿', { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .layoutWeight(1)
          .backgroundColor(this.spaceTab === 'videos' ? this.themePrimary : this.themeSurface)
          .fontColor(this.spaceTab === 'videos' ? this.themeOn : this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          .onClick((): void => {
            this.switchSpaceTab('videos');
          })
        Button('合集', { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .layoutWeight(1)
          .backgroundColor(this.spaceTab === 'seasons' ? this.themePrimary : this.themeSurface)
          .fontColor(this.spaceTab === 'seasons' ? this.themeOn : this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          .onClick((): void => {
            this.switchSpaceTab('seasons');
          })
        Button('系列', { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .layoutWeight(1)
          .backgroundColor(this.spaceTab === 'series' ? this.themePrimary : this.themeSurface)
          .fontColor(this.spaceTab === 'series' ? this.themeOn : this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          .onClick((): void => {
            this.switchSpaceTab('series');
          })
      }
      .width('100%')
      .margin({ top: 12 })
      .alignItems(VerticalAlign.Center)
      .visibility(this.tabRowVisible ? Visibility.Visible : Visibility.None)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 头部区间距：top 4 紧贴标题行下沿，bottom 8 让首个投稿条目同步上移
    //（列表占位随 headerAreaHeight 实测自动跟随）。
    .padding({ left: 20, right: 20, top: 4, bottom: 8 })
  }

  /**
   * 合集 / 系列卡片（页签列表条目）：封面 + 标题 + 形态角标，
   * 整行点击进「合集·系列详情」（SeasonSeriesDetail）。
   */
  @Builder
  CollectionCard(card: UpSpaceCollectionCard): void {
    Row({ space: 12 }) {
      CoverImage({
        url: toThumbUrl(card.cover, 128),
        imgWidth: 64,
        imgHeight: 64,
        imgRadius: 10,
        altText: card.title
      })
      Column() {
        Text(card.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(card.kind === 'season' ? '合集' : '系列')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .onClick((): void => {
      this.openCollectionDetail(card);
    })
  }

  /**
   * 「合集 / 系列」页签内容：骨架 / 失败 / 空态 / 卡片列表四分支。
   * 让位口径与投稿分支完全同款：非列表分支自补 padding top（barTotalHeight），
   * 列表走「首个空白占位 ListItem」穿透模式，滚动时卡片从沉浸材质下穿过。
   */
  @Builder
  SeasonsSeriesContent(): void {
    if (!this.seasonsLoaded && this.seasonsLoading) {
      // 首次拉取骨架：与投稿骨架同款条目占位
      Column() {
        ForEach([0, 1, 2, 3, 4], (_i: number): void => {
          SkeletonTrackItem({ index: _i })
        }, (_i: number): string => `up_season_skel_${_i}`)
      }
      .width('100%')
      .padding({ top: this.barTotalHeight() })
    } else if (this.seasonsFailed) {
      Column() {
        Text('合集加载失败')
          .fontColor($r('app.color.text_secondary'))
          .fontSize(16)
        Text(this.seasonsFailReason.length > 0 ? this.seasonsFailReason : '检查网络后再试一次')
          .fontColor($r('app.color.text_tertiary'))
          .fontSize(13)
          .textAlign(TextAlign.Center)
          .padding({ left: 24, right: 24 })
          .margin({ top: 8 })
        Row() {
          Button(this.seasonsRetryCooling ? '稍等 4 秒' : '重试', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .padding({ left: 18, right: 18 })
            .backgroundColor(this.themePrimary)
            .fontColor(this.themeOn)
            .enabled(!this.seasonsRetryCooling)
            .onClick((): void => {
              this.retrySeasonsSeries();
            })
        }
        .height(44)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .margin({ top: 12 })
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: this.barTotalHeight() })
    } else if (this.currentCards().length === 0) {
      // 已加载但该形态为空：区分「UP 没建过」与「拉不到」（后者在失败分支）
      Column() {
        Text(this.spaceTab === 'series' ? '该 UP 暂无系列' : '该 UP 暂无合集')
          .fontColor($r('app.color.text_secondary'))
          .fontSize(16)
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: this.barTotalHeight() })
    } else {
      List({ scroller: this.seasonsScroller }) {
        // 顶部空白占位条目（投稿列表同款）：首个卡片恰从标题栏底部起排
        ListItem() {
          Row()
            .width('100%')
            .height(this.barTotalHeight())
        }
        ForEach(
          this.currentCards(),
          (card: UpSpaceCollectionCard): void => {
            ListItem() {
              this.CollectionCard(card)
            }
          },
          (card: UpSpaceCollectionCard): string => `${card.kind}_${card.itemId}`
        )
      }
      .width('100%')
      .height('100%')
      // 裁剪放开：卡片内容要能画进标题栏区域供材质/模糊采样（投稿列表同款）
      .clip(false)
      .edgeEffect(EdgeEffect.Spring)
      .cachedCount(8)
      .contentEndOffset(CONTENT_END_OFFSET)
      .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
        this.syncTopBlurProgress();
      })
      .onScrollStop((): void => {
        // Idle 校准终态（与投稿列表同款）
        this.syncTopBlurProgress();
      })
    }
  }

  /**
   * 标题行内容（titleBar 的 stackBuilder 承载，可用空间仅 56vp，不得超出——
   * 官方约束「不要超出标题栏的可用空间」，超出会溢出与内容区重叠）：
   * 空占位 —— UP 昵称只在头部区 28fp 大标题显示一次，与歌单详情同约定（返回键为 HDS 默认键）。
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

  /**
   * 标题行收窄容器（平板模式宽度适配）：HDS titleBar 的 stackBuilder
   * 横跨目的地整列全宽，而本页条目内容列被 constraintSize 收窄居中 —— 大屏上
   * 标题行会贴到整列左缘、与居中条目错位。外层 Row 居中 + 内层 Column
   * constraintSize（上限与本页内容列完全同口径），标题行与条目列同宽对齐；
   * 两侧空白区 hitTestBehavior(Transparent) 穿透点击。
   * sm 回退 600（窗口 <600vp）天然无操作，手机零变化。
   */
  @Builder
  upSpaceBarNarrow() {
    Row() {
      Column() {
        this.upSpaceBar()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * UP 资料头部区收窄容器：同 upSpaceBarNarrow
   * 口径 —— bottomBuilder 也横跨整列全宽，收窄后头部区与本页条目列同宽对齐；
   * bottomBuilder 显式高度（实测 headerAreaHeight / 估计值垫底）不动，
   * 内层 onAreaChange 实测载体原样保留（高度不受收窄影响）。
   */
  @Builder
  upSpaceHeaderAreaNarrow() {
    Row() {
      Column() {
        this.upSpaceHeaderArea()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Column() {
          // UP 资料头在钉顶固定栏（UpHeader）里，这里直接是列表内容 ——
          // 与 PlaylistDetail 同结构：列表视口铺满全屏，首项从整栏底部起排，
          // 滚动时条目从毛玻璃下穿过（顶部占位条目负责让位）。
          // 合集 / 系列页签内容（骨架 / 失败 / 空态 / 卡片列表，四分支见 SeasonsSeriesContent）
          if (this.spaceTab !== 'videos') {
            this.SeasonsSeriesContent()
          } else if (this.loading && this.tracks.length === 0) {
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
                    .fontColor(this.themePrimary)
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
             // 下拉刷新：缓存策略下进页不联网，这里是本页仅存的
             // 显式刷新出口。Refresh 只包列表（SearchPage 同款），
             // 系统默认刷新头即可；layoutWeight 移交 Refresh，内层 List 补 height('100%')。
            Refresh({ refreshing: $$this.refreshing }) {
              List({ scroller: this.listScroller }) {
                // 顶部空白占位条目（下载页同款）：列表视口铺满全屏，条目起始位置在
                // 屏幕顶端（y=0）。占位高度 = 标题栏总让位量（barTotalHeight：
                // safeTop + 56 + 头部区实测高，随元信息行数浮动），首个真实条目恰
                // 从栏底起排，滚动时占位与
                // 条目一起从沉浸材质下方穿过。
                ListItem() {
                  // Blank 只能嵌在 Row/Column/Flex 内（编译器 10905201），ListItem 直下用定高 Row。
                  Row()
                    .width('100%')
                    .height(this.barTotalHeight())
                }
                // 条目渲染按展示形态三分支：大封面网格（外观设置「条目展示」，
                // 投稿配对成双列网格卡 TrackCard，竖屏 / 横屏均双列，交互契约与
                // 行内版一致——整卡点击播/暂停、「⋯」菜单；配对数据源复用 trackPairs）
                // / 横屏宽屏（条目配对，每个 ListItem 左右两列）/ 单列。
                // 各分支内部的多选 ForEach / 非多选 LazyForEach 双路径见对应 @Builder。
                if (this.isGrid()) {
                  this.GridTrackItems()
                } else if (this.isTwoCol()) {
                  this.TwoColTrackItems()
                } else {
                  this.SingleTrackItems()
                }
                // 加载更多状态条（常驻 + 固定高度）：只换内容不插拔条目，
                // 数据落地帧尾部 extent 只增不减，底部弹簧过滚动不被收缩强制解析。
                // 加载态为单行转圈：为固定高度做的取舍，首屏骨架不动。
                // 搜索分支排在最前：搜索态的计数 / 失败 / 在途提示
                // 优先于常规加载文案（搜索态下不翻页）。
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
                      Text(this.subscribed ? '订阅已开启，可在歌单详情页拉取新投稿' : '订阅该 UP 可持续获取新投稿')
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
              // 边界回弹：到顶/到底的反馈动效；顶部下拉由 Refresh 刷新动画接管
              .edgeEffect(EdgeEffect.Spring)
              .cachedCount(8)
                // 顶部 HDS 标题栏让位（Sumy 式穿透，与 PlaylistDetail 同款）：由 List
                 // 首个空白占位 ListItem 负责（见上方占位注释，下载页同款），不使用
                 // contentStartOffset。
                 // 列表末端常规留白（不叠加 safeBottom —— 底部不做避让，
                 // 视口直接扩展进安全区，末行可滚到手势条下）。
                .contentEndOffset(CONTENT_END_OFFSET)
              .onReachEnd((): void => {
                this.onReachEnd();
              })
              // 逐帧驱动自绘渐变模糊层（onDidScroll 在偏移已
              // 应用后回调，onWillScroll 是应用前，快滑时差一帧会让模糊层滞后一跳）。
              .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
                this.syncTopBlurProgress();
              })
              .onScrollStop((): void => {
                // Idle 校准终态：兜住 Fling 期丢帧 / 死区过滤累计的偏差。
                this.syncTopBlurProgress();
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
        // ⚠️ 不整体 padding top / safeAreaPadding bottom：列表视口铺满全屏并直接
        // 扩展进底部安全区（不做底部避让，沉浸到底）；
        // 非列表分支（骨架 / 失败 / 空态）各自补 padding top。
        .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })

        // 顶栏渐变模糊层：盖内容列之上（z 序低于 HDS
        // titleBar，UP 头部区属标题栏 bottomBuilder、随整栏一起盖），进度由
        // 列表 onDidScroll/onScrollStop 经 topBlurUpdater 命令式驱动。
        TopGradientBlurOverlay({
          barHeightVp: this.barTotalHeight(),
          updater: this.topBlurUpdater
        })
      }
    }
    // HDS 沉浸光感标题栏（真机结论见 AboutPage 注释）：
    // avoidLayoutSafeArea 挡状态栏重叠；enableComponentSafeArea 会杀材质，禁用。
    // 平板模式宽度适配：stackBuilder / bottomBuilder 均走收窄容器
    //（upSpaceBarNarrow / upSpaceHeaderAreaNarrow），标题行与 UP 头部区和
    // 条目列同宽对齐。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        // 标题行（stackBuilder，可用空间 56vp）：空占位（返回键为 HDS 默认键；收窄容器内）
        stackBuilder: (): void => {
          this.upSpaceBarNarrow();
        },
        // 标题行下方自定义区：UP 资料头部区（封面 / 昵称 / 订阅 / 搜索等，
        // 收窄容器内与条目列对齐）。
        // ⚠️ 头部区不能塞进 stackBuilder（会溢出 56vp 标题行、与列表内容重叠，
        // 真机复现），必须走 bottomBuilder；高度用实测值（未实测时估计值垫底）。
        bottomBuilder: {
          builder: (): void => {
            this.upSpaceHeaderAreaNarrow();
          },
          height: this.headerAreaHeight > 0 ? this.headerAreaHeight : UP_HEADER_ESTIMATE_HEIGHT,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        }
      }
    })
    // 返回键：用 HDS 默认返回键（"<" 系统样式，位置由 HDS 管理以避开状态栏）。
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页两个列表（投稿 / 合集系列卡片）
    // 都交给 HDS 联动，页签切换后模糊随可见列表滚动。
    .bindToScrollable([this.listScroller, this.seasonsScroller])
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 系统返回拦截（优先级从高到低）：
    //   · 多选态：先退选择模式（选区丢弃），留在本页；
    //   · 播放页 overlay 打开时吞掉返回并发收起请求（留在本页），
    //     否则走默认 pop —— 详见 utils/SubPageBackPress。
    .onBackPressed((): boolean => {
      if (this.selecting) {
        this.exitSelecting();
        return true;
      }
      return handleSubPageBackPress();
    })
    // 内容避让：目的地级声明布局扩展进系统安全区（官方组件级沉浸
    // 口径，faqs-arkui-1095 场景三同款）；窗口全屏下页面级为既成事实，此处显式化
    // 并接管组件级 safeAreaPadding。内容层避让由顶部占位条目 / plain padding 自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function UpSpacePageBuilder(): void {
  UpSpacePage()
}


/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const UpSpacePageWrapped: WrappedBuilder<[]> = wrapBuilder(UpSpacePageBuilder);

