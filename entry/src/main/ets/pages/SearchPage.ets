/**
 * 搜索二级页（路由名 'Search'）。
 *
 * 承载全部搜索逻辑：关键词合并搜索（一次搜索并发返回视频 + UP 主两类
 * 结果）、搜索历史、视频结果分页、下拉刷新。会话关键词与结果存于
 * SearchStateHolder（页面 / 标题栏行同源）；每次进入本页都从全新状态开始
 * （aboutToAppear 清 holder，不恢复上次搜索的关键词与结果）。
 *
 * 结果形态（一次搜索并发返回两类，结果区分「视频 | UP主」页签独立展示）：
 *   · 视频 —— 默认页签，原列表形态（TrackItem 长条 / 大封面网格 / 宽屏
 *     两列），分页 / 上拉加载 / 下拉刷新围绕它；
 *   · UP 主 —— 竖排列表行（圆形头像 + 昵称 + 认证小标 + 粉丝/投稿，
 *     点行进 UP 主页），searchUser 真分页（page / page_size=20，numPages
 *     判到底）。两页签共用一个 List（滚动 / 下拉刷新 / 顶栏模糊联动全
 *     复用），条目区按 resultTab 条件渲染，新搜索重置回「视频」页签。
 *
 * 结构（RecentPage 二级页样板同款）：
 *   · HdsNavDestination + HDS 沉浸光感标题栏（titleBar.stackBuilder 承载
 *     SearchInputBar 搜索行，56 锁高；返回键为 HDS 默认键）；
 *   · TopGradientBlurOverlay 自绘渐变模糊层 + 私有 scroller 命令式驱动
 *     （HDS 滚动效果经 styleOptions 第三参关闭，防双重模糊）；
 *   · 「最近搜索 / B 站热搜」页签区直接在页面内容区显示。
 *
 * 分页说明（对照实验结论，细节见 api/BilibiliApi.ts 的注释）：
 *   · 搜索 —— /wbi/search/type 真分页：page / page_size，响应带 numPages；
 *     UP 主搜（search_type=bili_user）匿名完全可用，同款真分页（本页只取第一页）。
 *   · 空页 ≠ 到底：风控时接口同样返回空列表（HTTP 200 / code 0），遇到空页
 *     只提示可重试，真到底由服务端 numPages 判定。
 */

import * as BilibiliApi from '../api/BilibiliApi';
import { UserSearchResult, SearchResultItem } from '../api/BilibiliApi';
import { Playlist, Track, VideoDetail, buildTrack, ITEM_DISPLAY_LIST, ITEM_DISPLAY_GRID } from '../model/MusicModels';
import { LibraryStore } from '../service/LibraryStore';
import { TrackItem } from '../components/TrackItem';
import { TrackCard } from '../components/TrackCard';
import { SkeletonTrackItem } from '../components/SkeletonTrackItem';
import { MusicPlayer } from '../player/MusicPlayer';
import { toHttpsUrl, toThumbUrl, stripHtmlTags, parseDurationText } from '../utils/TextUtil';
import { openCollectionOrPlay } from '../utils/CollectionNavigator';
import {
  ComponentContent,
  CustomContentDialog,
  CapsuleSegmentButtonV2,
  LengthMetrics,
  SegmentButtonV2Items
} from '@kit.ArkUI';
import { SearchStateHolder } from '../service/SearchStateHolder';
import { NavStackHolder } from '../service/NavStackHolder';
import { UpSpaceRouteParam } from '../service/NavRouteParams';
import { SearchHistoryStore } from '../service/SearchHistoryStore';
import { PLAYBACK_LOG_INFO, PLAYBACK_LOG_ERROR, recordPlaybackLog } from '../service/PlaybackLogStore';
import { AppPreferences } from '../preferences/AppPreferences';
import {
  CONTENT_END_OFFSET,
  DEFAULT_PLAYLIST_NAME,
  PREF_COMMON_WORDS,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_ITEM_DISPLAY_STYLE,
  STORE_THEME_DEEP,
  STORE_THEME_ON,
  STORE_THEME_PRIMARY,
  STORE_SEARCH_KEYWORD
} from '../common/Constants';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';
import { showAppToast } from '../components/AppToast';
import { showConfirm } from '../components/AppAlertDialog';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import {
  PairOf,
  PairDataSource,
  TWO_COL_GAP_VP,
  GRID_EDGE_PADDING_VP,
  TwoColumnLayout
} from '../common/utils/TwoColumnList';
import { ArrayDataSource } from '../utils/ArrayDataSource';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { CoverImage } from '../components/CoverImage';
import { SearchInputBar } from '../components/SearchTabBar';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { SegmentColors, makeBiliSegmentColors } from '../utils/HeaderBarMaterial';
import {
  DownloadManager,
  DownloadStartResult,
  WIFI_ONLY_BLOCKED
} from '../service/DownloadManager';
import { currentNetworkLabel } from '../utils/NetworkUtil';
import {
  PULL_REFRESH_OFFSET_VP,
  PULL_REFRESH_RATIO,
  PULL_MAX_DISTANCE_VP,
  PULL_SKELETON_SETTLE_VP,
  PULL_SKELETON_EXIT_VP,
  PULL_SKELETON_FADE_MS,
  BUTTON_RADIUS_VP,
  LIST_FOOTER_HEIGHT_VP,
  NAV_TRANSITION_MS
} from '../common/constants/InteractionConstants';

/** 搜索结果的标题里有 <em class="keyword"> 高亮标签，必须剥掉（统一用 TextUtil.stripHtmlTags）。 */

function mapSearch(item: SearchResultItem): Track {
  return buildTrack({
    id: item.bvid,
    bvid: item.bvid,
    aid: String(item.aid),
    title: stripHtmlTags(item.title),
    artist: item.author,
    // 搜索结果自带 mid（实测一直有）：「进 UP 主主页」全靠它
    upMid: item.mid !== undefined ? String(item.mid) : '',
    coverUrl: toHttpsUrl(item.pic),
    // B 站搜索接口时长三形态（"mm:ss" / "hh:mm:ss" / 纯秒数）与 parseDurationText 逐值等价
    duration: parseDurationText(String(item.duration ?? '')),
    playCount: item.play,
    pubdate: item.pubdate ?? 0
  });
}

/**
 * 下拉刷新区的静态空占位（骨架接管）：唯一作用是顶掉系统默认的
 * 刷新头（转圈/竖条），0.1vp 高度 = 视觉上不存在。刷新指示完全由 List
 * 首行的骨架行承担（见 build 里 List 的下拉骨架条目）。
 *
 * 刻意用 refreshingContent 而非 builder：占位不需要跟手，而 builder 会被
 * 状态变化重建，下拉时状态每帧都在变，用它纯属白白重建。
 * ⚠️ ComponentContent 的内容**不随页面 @State 刷新**（要变只能显式调
 * content.update(args)），所以这里必须是**静态**内容 —— 凡是「随下拉
 * 每帧变化」的视觉一律放 List 的普通组件树里，绝不放这里。
 */
@Builder
function PullRefreshPlaceholder(): void {
  Column()
    .width('100%')
    .height(0.1)
}

/** 搜索每页条数（跟着接口的 page_size） */
const SEARCH_PAGE_SIZE: number = 30;
/**
 * 常用搜索词出厂默认表：首次进入（无 PREF_COMMON_WORDS 存档）时的种子列表；
 * 此后列表整体持久化（「+」新建 / 长按 ✕ 删除即时落盘），本表不再参与。
 */
const COMMON_SEARCH_WORDS: string[] = [
  'playlist', '原创音乐', '翻唱音乐', '二创音乐', 'ai创造', '相声评书', '有声书', '脱口秀'
];
/** 热搜榜前三名的序号用主题色高亮（B 站热搜榜惯例） */
const HOT_TOP_RANK_COUNT: number = 3;
/**
 * 列表首条独立让位定值（vp）：标题行 56 + 此值 = List 首个空白占位条目高度
 * （不含 safeTop）。搜索二级页无 chip 行，只留呼吸间距。
 */
const SEARCH_LIST_START_EXTRA_VP: number = 12;
/**
 * 骨架屏占位行：首屏整页用 8 行（贴合首屏可见条数），上拉加载更多用 3 行。
 * 只作 ForEach 的数据源，渲染时忽略内容。
 */
const SKELETON_ROW_INDEXES: number[] = [0, 1, 2, 3, 4, 5, 6, 7];
/**
 * push 进页后延迟聚焦的兜底等待（ms）：NavDestination 动态挂载时
 * Search 的 defaultFocus 偶发不触发，转场落定后按 id 再补一次 requestFocus。
 */
const SEARCH_FOCUS_FALLBACK_MS: number = 400;
// ── UP 主结果行（结果页签「UP主」竖排列表）──
/** 行头像边长（vp）：圆形头像，imgRadius 传一半 */
const UP_ROW_AVATAR_VP: number = 48;
/** 头像缩略图请求宽（px）：48vp 头像下约 2x 余量 */
const UP_ROW_AVATAR_THUMB_PX: number = 128;
/** UP 主搜索每页条数（searchUser 官方默认 page_size；视频仍用 SEARCH_PAGE_SIZE） */
const USER_PAGE_SIZE: number = 20;

/** 诊断：SearchPage 实例号（排查「平板下 searchSubmit 绑到旧实例」） */
let searchPageInstanceSeq: number = 0;

@Component
export struct SearchPage {
  /**
   * 搜索关键词（页面 / 标题栏行共享的双向状态）：
   * SearchInputBar 的输入框 onChange 直改它，页面点历史词条也改它，
   * 两侧经 AppStorage 即时互见。初值取 holder 的会话词（与栏组件同源）。
   */
  @StorageLink(STORE_SEARCH_KEYWORD) keyword: string = SearchStateHolder.keyword;
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  /** 新建常用搜索词弹窗「添加」自绘按钮的实底/文字色（见 AddWordBody） */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  @State @Watch('onListSourceChanged') results: Track[] = SearchStateHolder.results;
  // ===== 列表数据源（LazyForEach 渲染）=====
  // 结果数组 + UP 搜索结果都挂 @Watch('onListSourceChanged')：整表替换与 push
  // 追加都会触发（V1 数组代理拦截 push），对应 ArrayDataSource 整表 reload +
  // 两列 PairDataSource sync。reload 语义与搜索数据流天然匹配：新搜索必是
  // 整表换源；翻页 push 时 LazyForEach 只重建可视区，代价可控。
  private resultSource: ArrayDataSource<Track> = new ArrayDataSource<Track>([]);
  private resultPairs: PairDataSource<Track> = new PairDataSource<Track>(this.resultSource);
  @State loading: boolean = false;
  /** 是否已执行过一次搜索：用于区分「还没搜」和「搜了但没结果」，避免空态文案误导。 */
  @State searched: boolean = false;
  /** 诊断用实例号（aboutToAppear 分配） */
  private pageId: number = 0;
  /** 底部安全区高度（vp）：列表末尾让位要自己叠上这一份（含二级页悬浮播放条避让） */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /**
   * 状态栏高度（vp）：历史面板 / 遮罩按标题栏下沿定位，定位公式含它。
   */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /**
   * 顶栏渐变模糊层进度更新器：onDidScroll / onScrollStop
   * 命令式驱动（不标 @State，滚动高频回调零重建），见 syncTopBlurProgress。
   */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中，见 build 里的 constraintSize */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 横竖屏（Index 常驻注册写入）：横屏宽屏时结果条目两列显示 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;

  /** 横屏宽屏（窗口 ≥600vp 的横屏）时条目两列显示；竖屏 / 窄窗口单列不变 */
  private isTwoCol(): boolean {
    return TwoColumnLayout.isActive(this.currentBreakpoint, this.isLandscape);
  }

  /** 条目展示（外观设置「条目展示」）：长条（默认）/ 大封面双列网格 */
  @StorageProp(STORE_ITEM_DISPLAY_STYLE) itemDisplay: string = ITEM_DISPLAY_LIST;

  /**
   * 大封面模式：**视频结果**以双列网格卡（TrackCard）渲染，竖屏 / 横屏均双列；
   * UP 主结果 / 历史词 / 热搜词保持原样（大封面只作用于封面类视频条目，
   * UP 行是圆形头像非封面，网格化收益低）。
   */
  private isGrid(): boolean {
    return this.itemDisplay === ITEM_DISPLAY_GRID;
  }

  /** 最近搜索词（最新在前，最多 SEARCH_HISTORY_MAX 条）。持久化在 service/SearchHistoryStore.ts */
  @State history: string[] = [];
  /** 页签区当前页签：'history' 最近搜索 / 'hot' B 站热搜 */
  @State searchSectionTab: string = 'history';
  /** 「最近搜索 / 热搜」官方分段按钮条目：静态一次构造 */
  private historySegItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: '最近搜索' },
    { text: '热搜' }
  ]);
  /** 分段按钮主题色配色组：每次渲染现取（读 AppStorage），缓存成字段切色不刷新 */
  private segColors(): SegmentColors {
    return makeBiliSegmentColors();
  }
  /** B 站热搜词（点「热搜」页签拉取，榜单顺序，页面存活期内缓存） */
  @State hotWords: string[] = [];
  /** 热搜拉取中（右角「刷新」按钮与加载态共用） */
  @State hotLoading: boolean = false;
  /** 热搜是否已拉取过（避免每次切页签都打接口；「刷新」按钮重置它强制重拉） */
  private hotLoaded: boolean = false;
  /** 常用搜索词（初始页快捷入口）：aboutToAppear 从偏好读完整列表，无存档回落默认表；增删即时落盘 */
  @State commonWords: string[] = [];
  /** 常用搜索词编辑态：长按任一词进入 —— 词旁显示 ✕（点击删除），点词体退出 */
  @State wordsEditing: boolean = false;
  /** 「新建常用搜索词」弹窗输入草稿 */
  @State newWordDraft: string = '';

  /** Refresh 组件的转圈状态（$$ 双向绑定，干完活必须落回 false 才会收起） */
  @State refreshing: boolean = false;
  /** 加载更多进行中 */
  @State loadingMore: boolean = false;

  /**
   * ── 下拉刷新头（骨架接管）──
   * 刷新指示器复用 SkeletonTrackItem 骨架行，不新增任何视觉元素：
   *   · 跟手 —— onOffsetChange 每帧把下拉进度映射成骨架的淡入 + 落位；
   *   · 触发 —— 骨架停在原位保持纯静态（见 SkeletonTrackItem 注释）；
   *   · 收尾 —— Done 后 250ms 淡出，动画放完再摘节点（句柄兜底回收）。
   */
  /** 刷新头骨架是否渲染（双骨架闸门：整屏骨架在场时必须为 false） */
  @State showPullSkeleton: boolean = false;
  /** 当前下拉偏移（vp）：onOffsetChange 每帧回写，只写状态、无副作用 */
  @State pullOffset: number = 0;
  /** 刷新头骨架透明度 ＝ 下拉进度（0..1，跟手不套 animateTo） */
  @State pullSkelOpacity: number = 0;
  /** 刷新头骨架纵移（vp）：下拉时从上方 12vp 落位 */
  @State pullSkelOffsetY: number = PULL_SKELETON_SETTLE_VP;
  /** Done 后骨架淡出的收尾句柄（照 PlayButtonComponent 的定时器回收模式） */
  private pullFadeTimer: number = -1;
  /** 下拉刷新区占位：ComponentContent 构造依赖 UIContext，属性初始化时未就绪，aboutToAppear 里建 */
  private refreshPlaceholder: ComponentContent<Object> | null = null;
  /** push 后延迟聚焦兜底句柄（aboutToDisappear 回收） */
  private focusFallbackTimer: number = -1;

  private player: MusicPlayer = MusicPlayer.getInstance();
  /** 当前结果集对应的关键词：用户可能已经改了输入框，翻页必须用产生这批结果的那个词 */
  private searchKeyword: string = SearchStateHolder.keyword;
  /** 搜索结果已加载到第几页 / 共几页（0 表示未知，允许先试一页） */
  private searchPage: number = 1;
  private searchTotalPages: number = 0;

  @State playlistOptions: Playlist[] = [];
  @State pickerTrack: Track | null = null;

  /** 「保存合集为歌单」：展开成功后让用户确认歌单名（默认取音频标题） */
  @State collectionName: string = '';
  @State pendingCollectionTracks: Track[] = [];
  /**
   * 「保存合集为歌单」对话框：CustomContentDialog 标准对话框，走
   * CustomDialogController，绝不走 promptAction —— 崩溃史见
   * AppAlertDialog.ets 头注释。aboutToAppear 创建一次，绝不重新赋值。
   */
   private collectionSaverController: CustomDialogController | undefined = undefined;

  /** 「新建常用搜索词」对话框（按钮自绘版）：aboutToAppear 创建一次，绝不重新赋值 */
  private addWordController: CustomDialogController | undefined = undefined;

  /**
   * 「加入歌单」弹窗：官方 CustomContentDialog 标准对话框（默认遮罩 +
   * 官方按钮槽，替代原根 Stack 内自绘弹层）。标题/按钮为常量 →
   * controller 建一次永不重建（faqs-arkui-555 只定格构造参数，动态内容
   * 经 contentBuilder 闭包在 open() 时读当次状态）。
   */
  private playlistPickerController: CustomDialogController | undefined = undefined;

  /**
   * 结果列表滚动控制器：本页私有实例（二级页不进 TabScrollerHolder 的
   * Tab 页静态槽位），bindToScrollable 绑它驱动 HDS 标题栏。
   */
  private listScroller: Scroller = new Scroller();

  /**
   * 子页转场的横移量（相对页面自身宽度）：常驻 '0%'，
   * 转场代理里按 push/pop 方向临时改写（见 navTransitionDelegate）。
   */
  @State navTransX: string = '0%';

  /**
   * UP 主搜索结果：与视频结果**同一次搜索并发返回**（doSearch 同时发
   * `searchVideo` + `searchUser`），渲染在结果页签「UP主」的竖排列表里，
   * 支持真分页（userPage / userTotalPages / loadMoreUsers）。
   */
  @State @Watch('onListSourceChanged') userResults: UserSearchResult[] = [];
  /**
   * UP 页签列表数据源（LazyForEach 渲染）：userResults 整表替换与 push 追加
   * 都经 @Watch 触发 reload（V1 数组代理拦截 push），与视频 resultSource 同口径。
   */
  private userSource: ArrayDataSource<UserSearchResult> = new ArrayDataSource<UserSearchResult>([]);
  /**
   * 结果页签：'video' 视频（默认）/ 'up' UP主。一次搜索两类结果并发返回，
   * 分页签独立展示独立分页；新搜索与清空回初始页都重置回 'video'。
   */
  @State resultTab: string = 'video';
  /** UP 结果已加载到第几页 / 共几页（0 表示未知，允许先试一页，与视频同口径） */
  private userPage: number = 1;
  private userTotalPages: number = 0;
  /** UP 页签上拉加载更多进行中（onReachEnd 闸门与 footer 状态共用） */
  @State userLoadingMore: boolean = false;
  /** 结果页签分段按钮条目：静态一次构造 */
  private resultSegItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: '视频' },
    { text: 'UP主' }
  ]);

  /**
   * 请求序号（竞态保护）：快速连搜两次时，先发的那次可能后返回，
   * 不判序号会把新结果覆盖成旧结果。进入时自增取号，await 返回后
   * 号对不上就整体丢弃（结果、失败提示、loading 复位都不能写）。
   */
  private searchSeq: number = 0;

  /**
   * 列表数组变化（@Watch 携带属性名）：同步对应数据源。
   * 初始赋值不触发 @Watch，会话恢复场景由 syncAllListSources（aboutToAppear）兜底。
   */
  private onListSourceChanged(propName: string): void {
    if (propName === 'results') {
      this.resultSource.reload(this.results);
      this.resultPairs.sync();
    } else if (propName === 'userResults') {
      this.userSource.reload(this.userResults);
    }
  }

  /** 初值同步（@Watch 不触发初始赋值）：会话恢复的搜索结果等在挂载时补一次 */
  private syncAllListSources(): void {
    this.resultSource.reload(this.results);
    this.resultPairs.sync();
    this.userSource.reload(this.userResults);
  }

  /**
   * 重置回搜索初始页（清空输入框即回初始页）：
   * 清空输入框（✕ / 退格删到空）或进页初始化时整体清掉结果态 ——
   * 「常用搜索 + 最近搜索/热搜」初始页回来，键盘不收可直接输入下一个词。
   * 历史记录 / 页签选择 / 热搜缓存不在清理范围（页面存活期内一直有效）。
   */
  private resetToLanding(): void {
    // 作废所有在途请求：doSearch / refreshSearch / loadMoreSearch 共用 searchSeq
    // 竞态守卫（seq !== searchSeq 即整体丢弃），且 loadMoreSearch 只读不自增 ——
    // 这里的自增能同时作废三条路径，防止清空后旧响应把结果回填回来。
    ++this.searchSeq;
    SearchStateHolder.clear();
    this.keyword = '';
    this.results = [];
    this.userResults = [];
    this.searchKeyword = '';
    this.searched = false;
    // 骨架屏在场时清空必须一并复位，否则 SearchStateArea 永远走 loading 分支
    this.loading = false;
    this.refreshing = false;
    this.loadingMore = false;
    this.searchPage = 1;
    this.searchTotalPages = 0;
    // 结果页签与 UP 翻页状态一并归零（userResults 清空在上面，
    // userSource 由下方 syncAllListSources 兜底）
    this.resultTab = 'video';
    this.userPage = 1;
    this.userTotalPages = 0;
    this.userLoadingMore = false;
    // @Watch 触发的数据源同步与这里显式同步双保险（aboutToAppear 同款口径）
    this.syncAllListSources();
    // 列表归位 + 顺带校准自绘顶栏模糊层进度
    this.resetResultScroll();
  }

  aboutToAppear(): void {
    // 每次进入都从头开始：不恢复上次的关键词与结果。
    // 重置逻辑与「清空输入框回初始页」共用 resetToLanding（见其注释）。
    this.resetToLanding();
    // 挂载前先存当前偏移对应的进度（updater 未挂载只存值，
    // 挂载时 initializeModifier 补上），防「已滚过再进页」首帧缺模糊。
    this.syncTopBlurProgress();
    // 「保存合集为歌单」对话框：按钮走 buttons 槽（无校验失败需保持
    // 打开的路径，可用自动关闭），点遮罩关闭时只清暂存数据，关闭由系统完成。
    this.collectionSaverController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: '保存合集为歌单',
        contentBuilder: (): void => {
          this.SaverBody();
        },
        buttons: [
          {
            value: '取消',
            buttonStyle: ButtonStyleMode.TEXTUAL,
            action: (): void => {
              this.cancelSaveCollection();
            }
          },
          {
            value: '保存',
            buttonStyle: ButtonStyleMode.EMPHASIZED,
            action: (): void => {
              this.confirmSaveCollection();
            }
          }
        ]
      }),
      autoCancel: true,
      cancel: (): void => {
        this.cancelSaveCollection();
      }
    });
    // 「新建常用搜索词」对话框：确认键自绘在 contentBuilder —— 空名/重名校验
    // 失败要保持弹窗打开，buttons 槽点击即自动关闭（faqs-arkui-986）。
    this.addWordController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: '新建常用搜索词',
        contentBuilder: (): void => {
          this.AddWordBody();
        }
      }),
      autoCancel: true,
      cancel: (): void => {
        this.cancelAddWord();
      }
    });
    // 「加入歌单」：官方标准对话框，标题/按钮常量（见成员声明处注释）。
    // 关闭路径（取消按钮 / 点遮罩 / 返回键）刻意不清暂存曲目：关闭有退场
    // 动画，清了会让副标题在淡出途中先变空；pickerTrack 每次打开前都会
    // 重写，残留值无消费方。
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
            }
          }
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    // 常用搜索词：完整列表整体读（用户增删后的持久真值）；null = 首次进入播种默认表
    const storedWords: string[] | null = AppPreferences.getObject<string[]>(PREF_COMMON_WORDS);
    this.commonWords = storedWords !== null ? storedWords : COMMON_SEARCH_WORDS.slice();
    // 搜索历史从 Preferences 读一次（SearchHistoryStore 内部有内存快照，读是同步的）
    this.history = SearchHistoryStore.getSearchHistory();
    // 无历史时直接落在「热搜」页签：空的「最近搜索」列表没有可看的
    if (this.history.length === 0) {
      this.searchSectionTab = 'hot';
      this.loadHotWords();
    }
    // 栏内动作（提交搜索 / 清空历史）经持有器转回本页私有方法
    this.pageId = ++searchPageInstanceSeq;
    console.info(`[Search] appear id=${this.pageId} bp=${this.currentBreakpoint}`);
    // 下拉刷新占位：ComponentContent 构造依赖 UIContext，属性初始化时还没就绪，
    // 只能在生命周期里建（工程内先例：PlayBar / CoverDiscComponent / LrcView 的 animator）。
    this.refreshPlaceholder =
      new ComponentContent<Object>(this.getUIContext(), wrapBuilder(PullRefreshPlaceholder));
    // 延迟聚焦兜底：NavDestination 动态挂载时 Search 的 defaultFocus 偶发不触发，
    // 转场落定后按 id 再补一次 requestFocus（入口式搜索框的「进页即搜」承接）。
    this.focusFallbackTimer = setTimeout((): void => {
      this.focusFallbackTimer = -1;
      this.getUIContext().getFocusController().requestFocus('searchSubPageInput');
    }, SEARCH_FOCUS_FALLBACK_MS);
  }

  aboutToDisappear(): void {
    console.info(`[Search] disappear id=${this.pageId}`);
    if (this.pullFadeTimer !== -1) {
      clearTimeout(this.pullFadeTimer);
      this.pullFadeTimer = -1;
    }
    if (this.focusFallbackTimer !== -1) {
      clearTimeout(this.focusFallbackTimer);
      this.focusFallbackTimer = -1;
    }
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut。
   * · push 入场：先把页面挪到屏幕右侧外（'100%'），event 闭包内回到 '0%'，
   *   系统按闭包内的状态变化生成 400ms EaseOut 过渡；
   * · pop 出场（含侧滑返回手势触发的返回）：反向滑回右侧，与手势方向一致；
   * · 其余场景（本页被上层页覆盖 / 上层页返回后重新露出）返回 undefined，
   *   走系统默认转场。
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
      const transitions: Array<NavDestinationTransition> = [enter];
      return transitions;
    }
    if (op === NavigationOperation.POP && !isEnter) {
      const exit: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '100%';
        }
      };
      const transitions: Array<NavDestinationTransition> = [exit];
      return transitions;
    }
    return undefined;
  }

  /**
   * 按当前列表偏移校准自绘渐变模糊层进度：
   * yOffset 0 → TITLE_BLUR_END_VP 线性映射 0 → 1（updater 内截断，
   * 边缘回弹负偏移归零 = 死区）。onDidScroll 逐帧 + onScrollStop
   * Idle 校准终态都走这里（Fling 期只命令式写 opacity 不写 @State）。
   */
  private syncTopBlurProgress(): void {
    // currentOffset() 在 Scroller 尚未挂到 List（冷启动 aboutToAppear 早于 build）
    // 时运行时返回 undefined，空防护防启动崩溃（jscrash 实锤），未挂载按偏移 0。
    this.topBlurUpdater.setProgress(
      (this.listScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  /**
   * 列表内容起始让位量（vp）：safeTop + 标题行 56 + 独立定值
   * （SEARCH_LIST_START_EXTRA_VP）。List 首个空白占位 / 骨架 / 空态读它。
   */
  private listStartOffset(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT + SEARCH_LIST_START_EXTRA_VP;
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /**
   * 搜索结果归位：新结果若沿用旧滚动偏移，首项会被 TitleBar 裁掉上半截
   * （「第一首压在顶栏下面」）。
   *
   * 为什么用 scrollEdge(Edge.Top) 而不是 scrollToIndex(0)：
   *   · Edge.Top 回到**内容起点**，即占位条目让位后的静止位（首项在栏下方）；
   *   · scrollToIndex(0) 会把第 0 项顶到视口物理顶端 —— 正是要避免的「压顶栏」。
   *
   * setTimeout(0)：等新结果完成这一帧布局再滚，否则滚的是上一批内容。
   */
  private resetResultScroll(): void {
    setTimeout((): void => {
      this.listScroller.scrollEdge(Edge.Top);
    }, 0);
  }

  /** 当前视频结果条数：分页（hasMore / loadMoreSearch）与底部状态条都围绕视频列表。 */
  private currentListLength(): number {
    return this.results.length;
  }

  /** 结果区是否有可见内容（视频或 UP 主任一非空）：空态判定与下拉骨架闸门用。 */
  private hasAnyResult(): boolean {
    return this.results.length > 0 || this.userResults.length > 0;
  }

  /**
   * 视频结果还有没有下一页（UP 主只取第一页，不参与分页）。
   * 页数未知（0，如从 holder 恢复）时先允许试一页，返回空页会自动停；
   * 真到底由服务端 numPages 判定（空页可能是风控，见 loadMoreSearch）。
   */
  private hasMore(): boolean {
    if (this.currentListLength() === 0) {
      return false;
    }
    if (this.searchTotalPages <= 0) {
      return true;
    }
    return this.searchPage < this.searchTotalPages;
  }

  /**
   * 合并搜索：同一关键词并发发起视频搜索（searchVideo）与 UP 主搜索
   * （searchUser），各取第一页；视频落「视频」页签（分页 / 会话保持围绕
   * 它），UP 主落「UP主」页签（翻页状态在此重置，后续上拉走 loadMoreUsers）。
   *
   * 竞态保护：searchSeq 作废制对两条请求**各自独立**生效 —— 任一响应返回
   * 时号对不上（用户已清空 / 重新搜索 / 下拉刷新）就整体丢弃。
   * `loading` 等两部分**都落定**才复位（pending 计数归零）：骨架屏盖住整个
   * 合并搜索过程，不闪「视频先到、UP 后到」的中间态。
   * UP 部分失败只记日志不打断：视频结果仍然可用，UP 缺席不该以
   * 「搜索失败」的姿态打断用户（风控对两类接口的宽严程度不同）。
   */
  private doSearch(): void {
    const kw: string = this.keyword.trim();
    if (!kw) {
      this.toast('请输入搜索关键词', 1500);
      return;
    }
    const seq: number = ++this.searchSeq;
    console.info(`[Search] doSearch id=${this.pageId} kw=${kw} seq=${seq}`);
    // 新搜索回「视频」页签（B 站官方同款：新搜索回默认结果页）
    this.resultTab = 'video';
    this.loading = true;
    // 先记历史再发请求：被风控 / 断网导致搜不出结果时，这次搜索同样算「搜过」，
    // 否则用户会遇到「明明搜过却不在历史里」。
    this.history = SearchHistoryStore.addSearchHistory(kw);
    let pending: number = 2;
    let videoFailed: boolean = false;
    const settlePart = (): void => {
      pending--;
      if (pending === 0 && seq === this.searchSeq) {
        this.loading = false;
        // 两类都空且视频没失败才提示「没搜到」：视频失败有自己的报错 toast，
        // UP 单独缺席不构成「没搜到」。
        if (this.results.length === 0 && this.userResults.length === 0 && !videoFailed) {
          this.toast('没有搜索到结果，请换个关键词或稍后再试', 2000);
        }
      }
    };
    // ── 视频部分：主结果（Track 列表，分页 / 网格 / 两列都渲染它）──
    BilibiliApi.searchVideo(kw, 1, SEARCH_PAGE_SIZE)
      .then((resp: BilibiliApi.SearchResponse): void => {
        // 已有更新的搜索在途（或已完成）：旧响应整体丢弃，不覆盖新结果
        if (seq !== this.searchSeq) {
          return;
        }
        this.results = (resp.result || []).map(mapSearch);
        this.searchKeyword = kw;
        this.searchPage = 1;
        this.searchTotalPages = resp.numPages > 0 ? resp.numPages : 0;
        this.searched = true;
        this.resetResultScroll();
        SearchStateHolder.save(kw, this.results);
        console.info(`[Search] video done id=${this.pageId} n=${this.results.length} searched=${this.searched}`);
      })
      .catch((e: Error): void => {
        // 失败的旧请求不提示、不碰状态：新请求还在飞，别让用户看到「先成功后报错」
        if (seq !== this.searchSeq) {
          return;
        }
        videoFailed = true;
        this.searched = true;
        console.error(`doSearch video failed: ${JSON.stringify(e)}`);
        this.toast('搜索失败，请检查网络或登录态', 2000);
      })
      .then((): void => {
        settlePart();
      });
    // ── UP 主部分：「UP主」页签数据（第一页，翻页状态在此重置）──
    BilibiliApi.searchUser(kw, 1, USER_PAGE_SIZE)
      .then((resp: BilibiliApi.UserSearchResponse): void => {
        if (seq !== this.searchSeq) {
          return;
        }
        this.userResults = resp.result || [];
        this.userPage = 1;
        this.userTotalPages = resp.numPages > 0 ? resp.numPages : 0;
        console.info(`[Search] user done id=${this.pageId} n=${this.userResults.length}`);
      })
      .catch((e: Error): void => {
        if (seq !== this.searchSeq) {
          return;
        }
        console.error(`doSearch user failed: ${JSON.stringify(e)}`);
      })
      .then((): void => {
        settlePart();
      });
  }

  /**
   * 下拉刷新：与 doSearch 同款两路并发（视频 + UP 主各刷新第一页），
   * 不重记历史（刷新不算新搜索）。`refreshing` 等两部分都落定才复位
   * （Refresh 的 $$ 双向绑定，不落回 false 刷新头不收起）。
   * seq 竞态保护：刷新在途时提交新搜索（doSearch 会 ++searchSeq）或
   * 再次刷新，旧响应必须整体丢弃；同时使同关键词在途的上拉翻页作废
   * （刷新会整体置换结果集，翻页的增量 push 已无意义）。
   */
  private refreshSearch(): void {
    const kw: string = this.searchKeyword.trim();
    if (kw.length === 0) {
      this.refreshing = false;
      this.toast('还没有搜索内容', 1200);
      return;
    }
    const seq: number = ++this.searchSeq;
    let pending: number = 2;
    const settlePart = (): void => {
      pending--;
      if (pending === 0) {
        this.refreshing = false;
      }
    };
    BilibiliApi.searchVideo(kw, 1, SEARCH_PAGE_SIZE)
      .then((resp: BilibiliApi.SearchResponse): void => {
        if (seq !== this.searchSeq) {
          return;
        }
        const list: Track[] = (resp.result || []).map(mapSearch);
        this.results = list;
        this.searchPage = 1;
        this.searchTotalPages = resp.numPages > 0 ? resp.numPages : 0;
        this.searched = true;
        SearchStateHolder.save(kw, list);
      })
      .catch((e: Error): void => {
        if (seq !== this.searchSeq) {
          return;
        }
        console.error(`refreshSearch failed: ${JSON.stringify(e)}`);
        this.toast('刷新失败，请稍后重试', 1800);
      })
      .then((): void => {
        settlePart();
      });
    BilibiliApi.searchUser(kw, 1, USER_PAGE_SIZE)
      .then((resp: BilibiliApi.UserSearchResponse): void => {
        if (seq !== this.searchSeq) {
          return;
        }
        // 刷新整表换源：UP 翻页状态回到第一页
        this.userResults = resp.result || [];
        this.userPage = 1;
        this.userTotalPages = resp.numPages > 0 ? resp.numPages : 0;
      })
      .catch((e: Error): void => {
        if (seq !== this.searchSeq) {
          return;
        }
        console.error(`refreshSearch user failed: ${JSON.stringify(e)}`);
      })
      .then((): void => {
        settlePart();
      });
  }

  /**
   * 下拉刷新头状态机（骨架接管），RefreshStatus 五态收口：
   *   · Drag / OverDrag —— 双骨架闸门：列表非空才挂刷新头骨架；整屏骨架在场
   *     （加载中、列表为空）时不再叠一条。若上一次 Done 的淡出还没跑完
   *     （快速连拉），先掐掉定时器并用 0 时长动画顶掉在途淡出 ——
   *     否则旧动画继续接管 opacity/translate，跟手映射全部失效。
   *   · Refresh —— 搜索刷新不清列表，骨架是唯一指示，停在原位保持纯静态
   *     即可（骨架纯静态，不另加旋转/脉冲/进度环）。
   *   · Done —— 250ms 淡出上移；淡出**结束后**再摘节点（直接摘节点淡出
   *     根本看不到），句柄由 aboutToDisappear 兜底回收。
   *   · Inactive —— 未触发刷新的回弹复位；Done 淡出在途时交给定时器收尾。
   */
  private onRefreshStateChange(status: RefreshStatus): void {
    if (status === RefreshStatus.Drag || status === RefreshStatus.OverDrag) {
      if (this.pullFadeTimer !== -1) {
        clearTimeout(this.pullFadeTimer);
        this.pullFadeTimer = -1;
        this.getUIContext().animateTo({ duration: 0 }, (): void => {
          this.pullSkelOpacity = 0;
          this.pullSkelOffsetY = PULL_SKELETON_SETTLE_VP;
        });
      }
      this.showPullSkeleton = this.hasAnyResult();
    } else if (status === RefreshStatus.Done) {
      this.dismissPullSkeleton();
    } else if (status === RefreshStatus.Inactive) {
      if (this.pullFadeTimer === -1) {
        this.showPullSkeleton = false;
        this.pullSkelOpacity = 0;
        this.pullSkelOffsetY = PULL_SKELETON_SETTLE_VP;
      }
    }
  }

  /** Done 收尾：骨架淡出上移，动画放完再摘节点（句柄回收照 PlayButtonComponent 模式） */
  private dismissPullSkeleton(): void {
    if (!this.showPullSkeleton) {
      return;
    }
    this.getUIContext().animateTo(
      { duration: PULL_SKELETON_FADE_MS, curve: Curve.EaseOut },
      (): void => {
        this.pullSkelOpacity = 0;
        this.pullSkelOffsetY = PULL_SKELETON_EXIT_VP;
      }
    );
    if (this.pullFadeTimer !== -1) {
      clearTimeout(this.pullFadeTimer);
    }
    this.pullFadeTimer = setTimeout((): void => {
      this.pullFadeTimer = -1;
      this.showPullSkeleton = false;
    }, PULL_SKELETON_FADE_MS);
  }

  /**
   * List 的 onReachEnd。
   * 三重闸门：正在刷新 / 正在加载更多 / 正在搜索，任一命中都直接返回，
   * 否则短列表在首帧布局时就会连环触发，一口气把后面几页全拉下来。
   */
  private onReachEnd(): void {
    if (this.refreshing || this.loadingMore || this.loading || this.userLoadingMore) {
      return;
    }
    // UP 页签：自己的翻页链路（空页 ≠ 到底、seq 竞态见 loadMoreUsers）
    if (this.resultTab === 'up') {
      if (this.userHasMore()) {
        this.loadMoreUsers();
      }
      return;
    }
    if (!this.hasMore()) {
      return;
    }
    this.loadMoreSearch();
  }

  private async loadMoreSearch(): Promise<void> {
    const kw: string = this.searchKeyword.trim();
    if (kw.length === 0) {
      return;
    }
    this.loadingMore = true;
    // seq 竞态保护：翻页在途时提交新搜索（doSearch 会
    // ++searchSeq）或下拉刷新，旧响应必须整体丢弃 —— 否则旧关键词的下一页会被
    // push 进新结果数组、并被 SearchStateHolder.save 持久化成「混页」数据。
    const seq: number = this.searchSeq;
    try {
      const next: number = this.searchPage + 1;
      const resp: BilibiliApi.SearchResponse = await BilibiliApi.searchVideo(kw, next, SEARCH_PAGE_SIZE);
      if (seq !== this.searchSeq) {
        return;
      }
      const list: Track[] = (resp.result || []).map(mapSearch);
      // 空页 ≠ 到底：风控时接口同样返回空列表（HTTP 200 / code 0，见 doSearch
      // 注释）。遇到空页只提示可重试，不推进 searchPage、不锁定 searchTotalPages；
      // 真到底由服务端 numPages 判定。
      if (list.length === 0) {
        this.toast('这页没有加载出来，可能被限流，稍后再试', 2000);
        return;
      }
      this.searchPage = next;
      // 按 id 去重后增量 push：翻页时 B 站可能把同一条挪位置，不去重会重复。
      const seen: Set<string> = new Set<string>();
      for (let i = 0; i < this.results.length; i++) {
        seen.add(this.results[i].id);
      }
      for (let i = 0; i < list.length; i++) {
        const t: Track = list[i];
        if (!seen.has(t.id)) {
          seen.add(t.id);
          this.results.push(t);
        }
      }
      SearchStateHolder.save(kw, this.results);
      if (resp.numPages > 0) {
        this.searchTotalPages = resp.numPages;
      }
    } catch (e) {
      if (seq !== this.searchSeq) {
        return;
      }
      console.error(`loadMoreSearch failed: ${JSON.stringify(e)}`);
      this.toast('加载更多失败，请稍后再试', 1800);
    } finally {
      this.loadingMore = false;
    }
  }

  /**
   * UP 页签还有没有下一页。页数未知（0，如接口没带 numPages）时先允许试
   * 一页，返回空页会自动停；真到底由服务端 numPages 判定（与视频 hasMore
   * 同口径）。
   */
  private userHasMore(): boolean {
    if (this.userResults.length === 0) {
      return false;
    }
    if (this.userTotalPages <= 0) {
      return true;
    }
    return this.userPage < this.userTotalPages;
  }

  /**
   * UP 页签上拉加载更多（searchUser 真分页：page / page_size）。
   * seq 竞态保护：翻页在途时提交新搜索（doSearch 会 ++searchSeq）或下拉
   * 刷新，旧响应必须整体丢弃 —— 否则旧关键词的下一页会被 push 进新结果
   * 数组（与 loadMoreSearch 同口径，loadMoreUsers 只读 seq 不自增）。
   * 空页 ≠ 到底：风控时接口同样返回空列表（HTTP 200 / code 0），遇到空页
   * 只提示可重试，不推进 userPage、不锁定 userTotalPages。
   */
  private async loadMoreUsers(): Promise<void> {
    const kw: string = this.searchKeyword.trim();
    if (kw.length === 0) {
      return;
    }
    this.userLoadingMore = true;
    const seq: number = this.searchSeq;
    try {
      const next: number = this.userPage + 1;
      const resp: BilibiliApi.UserSearchResponse = await BilibiliApi.searchUser(kw, next, USER_PAGE_SIZE);
      if (seq !== this.searchSeq) {
        return;
      }
      const list: UserSearchResult[] = resp.result || [];
      if (list.length === 0) {
        this.toast('这页没有加载出来，可能被限流，稍后再试', 2000);
        return;
      }
      this.userPage = next;
      // 按 mid 去重后增量 push：翻页时 B 站可能把同一条挪位置，不去重会重复
      // （push 触发 @Watch → userSource 整表 reload，LazyForEach 只重建可视区）。
      const seen: Set<string> = new Set<string>();
      for (let i = 0; i < this.userResults.length; i++) {
        seen.add(String(this.userResults[i].mid));
      }
      for (let i = 0; i < list.length; i++) {
        const u: UserSearchResult = list[i];
        const key: string = String(u.mid);
        if (!seen.has(key)) {
          seen.add(key);
          this.userResults.push(u);
        }
      }
      if (resp.numPages > 0) {
        this.userTotalPages = resp.numPages;
      }
    } catch (e) {
      if (seq !== this.searchSeq) {
        return;
      }
      console.error(`loadMoreUsers failed: ${JSON.stringify(e)}`);
      this.toast('加载更多失败，请稍后重试', 1800);
    } finally {
      this.userLoadingMore = false;
    }
  }

  /**
   * 加载中 / 空态的统一展示区。
   * 加载中：骨架屏（形状贴合 TrackItem 的 40 圆头像 + 两条文字条，纯静态占位），
   * 占位形状对齐内容布局，加载完成内容「落位」不跳。
   * 空态：区分「还没搜」和「搜了但没结果」（视频与 UP 主都空才算没结果，
   * 换词建议）。
   * 还没搜：常用搜索词区（CommonWordsSection）常驻初始页，其下方叠
   * 页签区（HistorySection：最近搜索 / B 站热搜；无历史时只剩热搜页签，
   * 所以不以历史非空作渲染闸门）。
   */
  @Builder
  SearchStateArea(): void {
    if (this.loading) {
      this.SkeletonArea()
    } else if (!this.hasAnyResult()) {
      if (!this.searched) {
        // height('100%')：外层 Column 高度确定（整屏），本列占满整高 →
        // 兄弟 Refresh(layoutWeight) 分到剩余 0 高。初始态结果列表为空、
        // 下拉骨架闸门要求 hasAnyResult()，Refresh 塌缩无功能损失；
        // 换来下方 HistorySection 能经 layoutWeight 链铺满到屏幕底部
        // （最近搜索/热搜需延伸到安全区）。
        Column() {
          this.CommonWordsSection()
          this.HistorySection()
        }
        .height('100%')
      } else {
        Column() {
          Text('没有找到相关内容，换个关键词试试')
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
        }
        .margin({ top: this.listStartOffset() + 48 })
      }
    }
  }

  /**
   * 骨架屏区（首屏加载）：8 行贴内容形状的占位。
   * 行数取首屏可见量即可——多出来的行用户看不见，纯浪费渲染（每行自带 shimmer 动画）。
   */
  @Builder
  SkeletonArea(): void {
    Column() {
      ForEach(SKELETON_ROW_INDEXES, (_i: number): void => {
        SkeletonTrackItem({ index: _i })
      }, (_i: number): string => `sk_${_i}`)
    }
    .width('100%')
    // 内容列不再整体 padding top（列表穿透需要），骨架区自己补内容起始让位
    .padding({ top: this.listStartOffset() })
  }

  /**
   * 结果页签分段行：「视频 | UP主」官方分段按钮（CapsuleSegmentButtonV2，
   * B 站粉经 itemSelectedBackgroundColor 覆写，HistorySection 同一套语言）
   * + 右侧当前页签结果计数。只在搜出内容后渲染（build 内闸门）。
   * ⚠️ V2 分段按钮给多大渲染多大（均摊到各段），必须显式宽度。
   */
  @Builder
  ResultTabBar(): void {
    Row() {
      CapsuleSegmentButtonV2({
        items: this.resultSegItems,
        selectedIndex: this.resultTab === 'up' ? 1 : 0,
        onItemClicked: (index: number): void => {
          this.switchResultTab(index === 1 ? 'up' : 'video');
        },
        itemSelectedBackgroundColor: this.segColors().selectedBg,
        itemSelectedFontColor: this.segColors().selectedFont,
        itemSelectedFontWeight: FontWeight.Medium,
        itemFontColor: this.segColors().unselectedFont,
        itemFontWeight: FontWeight.Normal,
        itemFontSize: LengthMetrics.vp(13),
        itemSelectedFontSize: LengthMetrics.vp(13),
        buttonBackgroundColor: this.segColors().grooveBg,
        buttonBorderRadius: LengthMetrics.vp(8),
        itemBorderRadius: LengthMetrics.vp(6),
        // 内部背板最小高度对齐 32（HistorySection 同款结论，否则约 36 盖过 .height(32)）
        buttonMinHeight: LengthMetrics.vp(32),
        // 紧凑内边距（系统默认 16vp 空气感过强，HistorySection 真机验收同款收到 8vp）
        itemPadding: { start: LengthMetrics.vp(8), end: LengthMetrics.vp(8) }
      })
        .height(32)
        // 显式宽度：背板 4×2 + 「视频」(≈26+16) + 「UP主」(≈28+16)
        .width(100)
      Blank()
        .layoutWeight(1)
      // 当前页签结果数：翻页后增长，直观反馈「还能翻」
      Text(this.resultTab === 'video'
        ? `${this.results.length} 个`
        : `${this.userResults.length} 个`)
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .margin({ top: 4, bottom: 4 })
  }

  /** 切换结果页签：相同直接返回；换页签后列表归位（两页签共用一个滚动容器） */
  private switchResultTab(tab: string): void {
    if (this.resultTab === tab) {
      return;
    }
    this.resultTab = tab;
    this.resetResultScroll();
  }

  /** 卡片小标：有官方/企业认证取认证文案（匿名搜 UP 时区分「官方号」与「同名搬运号」最需要的信息），否则「UP主」 */
  private upBadgeText(u: UserSearchResult): string {
    if (u.verify_info && u.verify_info.desc.length > 0) {
      return u.verify_info.desc;
    }
    return 'UP主';
  }

  /**
   * UP 主结果行（「UP主」页签竖排列表）：圆形头像 + 昵称 + 认证小标 +
   * 粉丝/投稿 + 「进入主页」chevron，点行进主页。
   * 为什么不给 UP 加「加入队列 / 下载 / 播放」：这些动作的对象是**曲目**不是 UP，
   * 行上唯一有意义的动作是**进他的主页**（那边能订阅，之后新歌自动进订阅歌单）。
   * 匿名态拿不到他的投稿列表（`arc/search` 被风控，站内页会退化成「搜索反查」路径），
   * 所以这一步是「搜 UP → 进主页 → 订阅」三段式的中间一环。
   */
  @Builder
  UpResultRow(u: UserSearchResult): void {
    Row({ space: 12 }) {
      CoverImage({
        // face_nft 优先：实测它比 upic 更常不为空
        url: toThumbUrl((u.face_nft && u.face_nft.length > 0) ? u.face_nft : u.upic, UP_ROW_AVATAR_THUMB_PX),
        imgWidth: UP_ROW_AVATAR_VP,
        imgHeight: UP_ROW_AVATAR_VP,
        imgRadius: UP_ROW_AVATAR_VP / 2,
        altText: u.uname
      })
      Column({ space: 2 }) {
        Text(u.uname)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.upBadgeText(u))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
        Text(this.userMetaText(u))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([$r('app.color.text_tertiary')])
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .accessibilityText(`${u.uname}，${this.userMetaText(u)}，进入主页`)
    .accessibilityLevel('yes')
    .onClick((): void => {
      this.openUpSpaceByUser(u);
    })
  }

  /**
   * 视频页签条目区：三种条目形态（外观设置「条目展示」决定）+ 加载更多
   * 状态条。整段自 build 内 List 迁入（逻辑未动，仅挪位）。
   */
  @Builder
  VideoTabContent(): void {
    // 大封面模式（外观设置「条目展示」）：视频结果配对成
    // 双列网格卡（TrackCard），竖屏 / 横屏均双列，交互契约与行内版一致
    // （整卡点击播/暂停、「⋯」菜单）；配对数据源复用 resultPairs
    // （onListSourceChanged 无条件 sync，网格竖屏也是热的）。
    if (this.isGrid()) {
      LazyForEach(
        this.resultPairs,
        (pair: PairOf<Track>): void => {
          ListItem() {
            Row() {
              TrackCard({
                track: pair.first,
                onPlay: (tr: Track): void => {
                  // 先查后分流：多 P 合集跳合集详情页，单曲回落直接播放
                  //（utils/CollectionNavigator，viewCache 命中零开销）
                  openCollectionOrPlay(tr, this.player);
                },
                moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
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
                  // 先查后分流：多 P 合集跳合集详情页，单曲回落直接播放
                  //（utils/CollectionNavigator，viewCache 命中零开销）
                  openCollectionOrPlay(tr, this.player);
                },
                  moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
                }).layoutWeight(1)
              } else {
                Blank().layoutWeight(1)
              }
            }
            .width('100%')
            // 网格行页边距：两边留白 + 封面整体缩小约 15%，
            // 见 GRID_EDGE_PADDING_VP 注释。
            .padding({ left: GRID_EDGE_PADDING_VP, right: GRID_EDGE_PADDING_VP })
            // Top 对齐：卡高随标题行数浮动，Row 默认 Center 会把矮卡
            // 垂直居中 → 左右封面错位；Top 让左右封面严格同高起步。
            .alignItems(VerticalAlign.Top)
          }
        },
        (pair: PairOf<Track>): string =>
          `${pair.first.id}|${pair.second !== null ? pair.second.id : 'x'}`
      )
    } else if (this.isTwoCol()) {
      LazyForEach(
        this.resultPairs,
        (pair: PairOf<Track>, pIndex: number): void => {
          ListItem() {
            Row() {
              TrackItem({
                track: pair.first,
                entranceIndex: pIndex * 2,
                onPlay: (tr: Track): void => {
                  // 先查后分流：多 P 合集跳合集详情页，单曲回落直接播放
                  //（utils/CollectionNavigator，viewCache 命中零开销）
                  openCollectionOrPlay(tr, this.player);
                },
                moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
              }).layoutWeight(1)
              if (pair.second !== null) {
                TrackItem({
                  track: pair.second,
                  entranceIndex: pIndex * 2 + 1,
                  onPlay: (tr: Track): void => {
                  // 先查后分流：多 P 合集跳合集详情页，单曲回落直接播放
                  //（utils/CollectionNavigator，viewCache 命中零开销）
                  openCollectionOrPlay(tr, this.player);
                },
                  moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
                }).layoutWeight(1).margin({ left: TWO_COL_GAP_VP })
              } else {
                Blank().layoutWeight(1)
              }
            }
            .width('100%')
          }
        },
        (pair: PairOf<Track>): string =>
          `${pair.first.id}|${pair.second !== null ? pair.second.id : 'x'}`
      )
    } else {
      LazyForEach(
        this.resultSource,
        (t: Track, index: number): void => {
          ListItem() {
            TrackItem({
              track: t,
              entranceIndex: index,
                onPlay: (tr: Track): void => {
                  // 先查后分流：多 P 合集跳合集详情页，单曲回落直接播放
                  openCollectionOrPlay(tr, this.player);
                },
              moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
            })
          }
        },
        (t: Track): string => t.id
      )
    }

    // 加载更多状态条（常驻 + 固定高度）：只在这一屏有内容时出现；
    // 只换内容不插拔、高度恒定，数据落地帧尾部 extent 只增不减，底部弹簧
    // 过滚动不被收缩强制解析（防加载下一页时列表整体跳动）。
    // 加载态是单行转圈：为固定高度做的取舍，首屏/下拉刷新骨架不动。
    if (this.currentListLength() > 0) {
      ListItem() {
        Row() {
          if (this.loadingMore) {
            LoadingProgress()
              .width(18)
              .height(18)
              .color($r('app.color.text_tertiary'))
            Text('加载中…')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ left: 8 })
          } else if (!this.hasMore()) {
            Text('已经到底啦')
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
  }

  /**
   * UP 主页签条目区：竖排列表行（真分页）+ 加载更多状态条；
   * 空态（另一页签有内容时）占位说明，两类都空由 SearchStateArea 整页空态接管。
   */
  @Builder
  UpTabContent(): void {
    if (this.userResults.length === 0) {
      ListItem() {
        Text('没有找到相关UP主')
          .fontSize(16)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .margin({ top: 48 })
    } else {
      LazyForEach(
        this.userSource,
        (u: UserSearchResult): void => {
          ListItem() {
            this.UpResultRow(u)
          }
        },
        (u: UserSearchResult): string => `up_${u.mid}`
      )
      // 加载更多状态条（与视频页签同款：常驻 + 固定高度，防 extent 抖动）
      ListItem() {
        Row() {
          if (this.userLoadingMore) {
            LoadingProgress()
              .width(18)
              .height(18)
              .color($r('app.color.text_tertiary'))
            Text('加载中…')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ left: 8 })
          } else if (!this.userHasMore()) {
            Text('已经到底啦')
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
  }

  /** 「95.1 万粉丝 · 258 个投稿」这类副信息；空值不拼出孤零零的分隔符 */
  private userMetaText(u: UserSearchResult): string {
    const parts: string[] = [];
    const fans: string = this.formatFans(u.fans);
    if (fans.length > 0) {
      parts.push(fans);
    }
    if (u.videos > 0) {
      parts.push(`${u.videos} 个投稿`);
    }
    return parts.join(' · ');
  }

  /** 数字友好化：950682 → 「95.1 万」，避免搜索结果里出现一长串数字 */
  private formatFans(fans: number): string {
    if (!Number.isFinite(fans) || fans <= 0) {
      return '';
    }
    if (fans < 10000) {
      return `${fans} 粉丝`;
    }
    if (fans < 100000000) {
      return `${(fans / 10000).toFixed(1)} 万粉丝`;
    }
    return `${(fans / 100000000).toFixed(1)} 亿粉丝`;
  }

  /** 从搜索结果直接进 UP 主页（`openUpSpace` 是给「曲目」用的，这里是 UP 本身） */
  private openUpSpaceByUser(u: UserSearchResult): void {
    const mid: string = String(u.mid ?? '');
    if (mid.length === 0) {
      this.toast('这个 UP 缺少 mid，无法打开主页', 1800);
      return;
    }
    // 头像一并带过去，UP 主页首帧就有图（否则要等主页自己再拉一次 card）
    const face: string = u.face_nft && u.face_nft.length > 0 ? u.face_nft : u.upic;
    NavStackHolder.stack.pushPathByName('UpSpace', new UpSpaceRouteParam(mid, u.uname, face));
  }

  /** 「⋯」标准菜单项（bindMenu + MenuElement 数组） */
  private trackMenuItems(track: Track): MenuElement[] {
    return [
      {
        value: '加入队列',
        action: (): void => {
          this.player.addToQueue(track);
          this.toast('已加入播放队列', 1500);
        }
      },
      {
        value: '加入歌单',
        action: (): void => {
          this.openPlaylistPicker(track);
        }
      },
      {
        value: '保存合集为歌单',
        action: (): void => {
          this.loadCollection(track);
        }
      },
      {
        value: '下载',
        action: (): void => {
          this.startDownload(track);
        }
      },
      {
        value: '进入 UP 主主页',
        action: (): void => {
          this.openUpSpace(track);
        }
      }
    ];
  }

  /**
   * 「进入 UP 主主页」→ 站内页（UpSpacePage）。
   *
   * mid 有两条来源：
   *  1. 列表映射时已落下来的（搜索结果有 mid）—— 直接用，零请求；
   *  2. 已下载曲目这类结构里没有 mid 的 → 用 bvid 走 `getVideoDetail` 换
   *     `owner.mid`。该接口带 viewCache（TTL 内），同一首反复点不会重复发请求。
   */
  private async openUpSpace(track: Track): Promise<void> {
    // ⚠️ `?? ''` 不能省：旧版本落盘的曲目（已下载 / 收藏 / 最近播放）没有 upMid 字段，
    // 运行时读出来是 undefined，直接读 `.length` 会崩。
    let mid: string = track.upMid ?? '';
    if (mid.length === 0) {
      const bvid: string = track.bvid.length > 0 ? track.bvid : track.id;
      if (bvid.indexOf('BV') !== 0) {
        this.toast('这条没有 UP 主信息', 1500);
        return;
      }
      this.toast('正在获取投稿作者…', 1200);
      try {
        const detail: VideoDetail = await BilibiliApi.getVideoDetail(bvid);
        mid = detail.owner ? String(detail.owner.mid) : '';
      } catch (e) {
        console.error(`openUpSpace resolve mid failed: ${JSON.stringify(e)}`);
        mid = '';
      }
      if (mid.length === 0) {
        this.toast('获取 UP 主失败', 1500);
        return;
      }
    }
    // 头像没有现成数据可传（曲目行不带 UP 头像）：传空串占位，
    // UpSpacePage 用 CoverImage 兜占位图，loadCard 拿到真图后覆盖
    NavStackHolder.stack.pushPathByName('UpSpace', new UpSpaceRouteParam(mid, track.artist, ''));
  }

  private startDownload(track: Track): void {
    this.requestDownload(track, false);
  }

  /**
   * 发起下载。
   *
   * 分 P 合集会在内核里被展开成多条任务（见 DownloadManager.requestDownload），
   * 所以这里不能再用「true/false」表达结果 —— 得把「排上几首 / 跳过几首」都告诉用户。
   *
   * @param ignoreWifiLimit 用户在「仅 WiFi 下载」的询问里选了「继续下载」时为 true
   */
  private requestDownload(track: Track, ignoreWifiLimit: boolean): void {
    DownloadManager.getInstance().requestDownload(track, ignoreWifiLimit)
      .then((r: DownloadStartResult): void => {
        if (r.blockedReason.length > 0) {
          this.confirmDownloadOnCellular(track);
          return;
        }
        this.toast(this.downloadResultText(r), 2000);
      })
      .catch((e: Error): void => {
        console.error(`requestDownload failed: ${JSON.stringify(e)}`);
        this.toast('下载启动失败', 1800);
      });
  }

  /** 把下载请求结果翻译成人话：0 条 / 1 条 / N 条要分开说，否则用户不知道合集是不是都排上了 */
  private downloadResultText(r: DownloadStartResult): string {
    if (r.queued === 0) {
      return r.skipped > 0 ? '该歌曲已在下载列表中' : '没有可下载的曲目';
    }
    const head: string = r.queued > 1 ? `已开始下载 ${r.queued} 首` : '已开始下载';
    const tail: string = r.skipped > 0 ? `（另有 ${r.skipped} 首已在列表中）` : '';
    return `${head}，可在「下载」页查看进度${tail}`;
  }

  /**
   * 「仅 WiFi 下载」被触发：先问一句，而不是直接拒绝。
   *
   * 开这个开关的人多半是「不想偷跑流量」，不是「绝对不许用流量」。一律拦死的话，
   * 用户在外面想下一首歌就得先去设置里关开关 —— 多加一步，还未必想得起来。
   */
  private confirmDownloadOnCellular(track: Track): void {
    showConfirm(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: `${WIFI_ONLY_BLOCKED}\n当前网络：${currentNetworkLabel()}`,
      confirmText: '继续下载',
      onConfirm: (): void => {
        this.requestDownload(track, true);
      }
    });
  }

  /**
   * 把歌曲加入指定歌单。
   *
   * 一个歌单都没有时**自动建一个再放进去**：让用户先跳页建单、再回来重新找到
   * 这首是纯粹的摩擦，行为是「点加入歌单 → 自动创建歌单并加入」。
   */
  private openPlaylistPicker(track: Track): void {
    const options: Playlist[] = LibraryStore.getAddablePlaylists();
    if (options.length === 0) {
      // 复用本次已读到的列表（此处为空），不再让下游二次读库
      this.createPlaylistAndAdd(track, options);
      return;
    }
    this.playlistOptions = options;
    this.pickerTrack = track;
    this.playlistPickerController?.open();
  }

  /** 没有任何歌单时的兜底：新建歌单并直接把这首放进去（名字取自歌名） */
  private createPlaylistAndAdd(track: Track, existing: Playlist[]): void {
    const name: string = LibraryStore.nextPlaylistNameForTrack(track, existing);
    const created: Playlist = LibraryStore.createPlaylist({ name: name });
    const updated: Playlist | null = LibraryStore.addTrackToPlaylist(created.id, track);
    this.toast(updated ? `已新建歌单「${name}」并加入` : '加入歌单失败', 1800);
  }

  /** 弹层里的「新建歌单并加入」：同样省掉一次跳转 */
  private createPlaylistFromPicker(): void {
    const track: Track | null = this.pickerTrack;
    this.playlistPickerController?.close();
    if (!track) {
      return;
    }
    // 弹层打开时的快照（playlistOptions）就是用户看到的列表，重名检查基于它即可
    this.createPlaylistAndAdd(track, this.playlistOptions);
  }

  /**
   * 「保存合集」时用户把名字清空了才用到的兜底：**通用默认名**，不取歌名。
   *
   * 与 `LibraryStore.nextPlaylistNameForTrack` 分开是刻意的 —— 合集是多首曲目，
   * 而且 `collectionName` 已经预填成合集标题了；用户主动清空意味着「不要这个标题」，
   * 这时再把歌名塞回去等于无视他的操作。
   */
  private fallbackPlaylistName(existing: Playlist[]): string {
    const names: Set<string> = new Set<string>(
      existing.map((p: Playlist): string => p.name.trim())
    );
    if (!names.has(DEFAULT_PLAYLIST_NAME)) {
      return DEFAULT_PLAYLIST_NAME;
    }
    for (let i = 2; i < 1000; i++) {
      const candidate: string = `${DEFAULT_PLAYLIST_NAME} ${i}`;
      if (!names.has(candidate)) {
        return candidate;
      }
    }
    return `${DEFAULT_PLAYLIST_NAME} ${Date.now()}`;
  }

  private addToPlaylist(p: Playlist): void {
    const track: Track | null = this.pickerTrack;
    this.playlistPickerController?.close();
    if (!track) {
      return;
    }
    const updated: Playlist | null = LibraryStore.addTrackToPlaylist(p.id, track);
    // 双向收藏夹拦截提示：非 B 站曲目被 store 过滤时明确告知，
    // 不再说「已加入」（被滤时 addTrackToPlaylist 仍返回歌单对象）
    const skipped: number = LibraryStore.consumeFavMirrorSkippedCount();
    if (updated !== null && skipped > 0) {
      this.toast(`「${p.name}」是双向同步收藏夹，仅支持添加 B 站曲目`, 2200);
      return;
    }
    this.toast(updated ? `已加入「${p.name}」` : '加入歌单失败', 1600);
  }

  /**
   * 把多 P 合集（单视频分 P）或 B 站合集（ugc_season，多个独立视频）整个保存为歌单。
   * 先展开条目，成功后弹层让用户确认歌单名（默认取音频标题），再一次性建单入库。
   */
  private loadCollection(track: Track): void {
    const bvid: string = track.bvid ? track.bvid : track.id;
    if (bvid.length === 0 || bvid.indexOf('BV') !== 0) {
      this.toast('该条目不是视频合集', 1500);
      return;
    }
    this.toast('正在获取合集…', 1200);
    // 第三参 expandSeason=true：多 P 不存在时继续展开 ugc_season
    //（播放 / 下载链路不传，防止下载单集被扩成整季）。此入口是用户显式要整季的唯一路径。
    BilibiliApi.expandVideoParts(bvid, track, true)
      .then((list: Track[]): void => {
        if (list.length <= 1) {
          this.toast('该视频只有一个分 P', 1500);
          console.info(`[Collection] 合集仅展开 ${list.length} 条：${bvid}`);
          recordPlaybackLog(PLAYBACK_LOG_INFO,
            `合集「${track.title.slice(0, 30)}」仅展开 ${list.length} 条（该视频可能只有一个分P）`);
          return;
        }
        this.pendingCollectionTracks = list;
        this.collectionName = track.title;
        this.collectionSaverController?.open();
        console.info(`[Collection] 合集加载成功：${list.length} 首（${bvid}）`);
        recordPlaybackLog(PLAYBACK_LOG_INFO, `合集「${track.title.slice(0, 30)}」加载成功：${list.length} 首`);
      })
      .catch((e: Error): void => {
        console.error(`loadCollection failed: ${JSON.stringify(e)}`);
        this.toast('合集加载失败', 1800);
        recordPlaybackLog(PLAYBACK_LOG_ERROR, `合集「${track.title.slice(0, 30)}」加载失败：${e.message}`);
      });
  }

  /** 对话框「保存」：按用户输入的名字建歌单（空名回退默认名），把合集全部曲目一次写入（弹窗由按钮自动关闭） */
  private confirmSaveCollection(): void {
    const list: Track[] = this.pendingCollectionTracks;
    this.pendingCollectionTracks = [];
    if (list.length === 0) {
      return;
    }
    const input: string = this.collectionName.trim();
    // 该流程没有预读歌单列表，这里才需要读一次库来做默认名去重
    const name: string = input.length > 0 ? input : this.fallbackPlaylistName(LibraryStore.getPlaylists());
    const created: Playlist = LibraryStore.createPlaylist({
      name: name,
      coverUrl: list[0].coverUrl
    });
    created.tracks = list;
    LibraryStore.updatePlaylist(created);
    this.toast(`已保存歌单「${name}」，共 ${list.length} 首`, 2000);
  }

  private cancelSaveCollection(): void {
    this.pendingCollectionTracks = [];
  }

  /**
   * 「保存合集为歌单」对话框内容区：曲目数说明 + 名称输入。
   * 标题在 CustomContentDialog 的 primaryTitle；按钮在 buttons 槽（点击自动关闭）。
   */
  @Builder
  SaverBody(): void {
    Column() {
      Text(`共 ${this.pendingCollectionTracks.length} 首`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      TextInput({ placeholder: '输入歌单名称', text: this.collectionName })
        .width('100%')
        .height(44)
        // 字阶只用六档（24/20/18/16/13/11），15 属于禁用档（与相邻 13/16 差异不可辨）
        .fontSize(16)
        .onChange((v: string): void => {
          this.collectionName = v;
        })
    }
    .width('100%')
  }

  /**
   * 搜索行收窄容器（RecentPage recentBarNarrow 同款）：HDS titleBar 的
   * stackBuilder 横跨目的地整列全宽，而本页内容列被 constraintSize 收窄居中 ——
   * 大屏上搜索行会贴到整列左缘、与居中条目错位。外层 Row 居中 + 内层 Column
   * constraintSize（上限与本页内容列同口径），让搜索行与条目列同宽对齐；
   * 两侧空白区 hitTestBehavior(Transparent) 穿透点击。
   * sm 回退 600（窗口 <600vp）天然无操作，手机零变化。
   */
  @Builder
  searchBarNarrow(): void {
    Row() {
      Column() {
        SearchInputBar()
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

  private useHistoryWord(word: string): void {
    this.keyword = word;
    this.doSearch();
  }

  private clearHistory(): void {
    SearchHistoryStore.clearSearchHistory();
    this.history = SearchHistoryStore.getSearchHistory();
    // 历史清空后「最近搜索」页签不再显示，切到「热搜」兜住内容
    this.searchSectionTab = 'hot';
    this.loadHotWords();
    this.toast('已删除搜索记录', 1500);
  }

  /** 切页签：第一次切到「热搜」时拉取（页面存活期内缓存，「刷新」强制重拉） */
  private switchSectionTab(tab: string): void {
    if (this.searchSectionTab === tab) {
      return;
    }
    this.searchSectionTab = tab;
    if (tab === 'hot') {
      this.loadHotWords();
    }
  }

  /** 拉取 B 站热搜：在途 / 已缓存直接跳过；失败只提示，不动已缓存的旧榜单 */
  private loadHotWords(): void {
    if (this.hotLoading || this.hotLoaded) {
      return;
    }
    this.hotLoading = true;
    BilibiliApi.getHotSearchKeywords(10)
      .then((words: string[]): void => {
        this.hotWords = words;
        this.hotLoaded = true;
        if (words.length === 0) {
          this.toast('没有获取到热搜', 1500);
        }
      })
      .catch((e: Error): void => {
        console.error(`loadHotWords failed: ${JSON.stringify(e)}`);
        this.toast('热搜加载失败，点「刷新」重试', 1800);
      })
      .then((): void => {
        this.hotLoading = false;
      });
  }

  /** 「刷新」：重置缓存强制重拉（旧榜单保留可点，新数据到了整体替换） */
  private refreshHotWords(): void {
    this.hotLoaded = false;
    this.loadHotWords();
  }

  /**
   * 常用搜索词区（搜索初始页、最近搜索上方）：出厂默认词 + 用户新增词做快捷
   * 入口 —— 点词直接以该词搜索（useHistoryWord → doSearch 统一记录进最近
   * 搜索）。胶囊样式与首页分类 chip / 入口搜索框同语言（bg_card 底 +
   * bg_divider 描边 + press_overlay 按压反馈）。
   * 末尾「+」胶囊新建词（CustomContentDialog 弹窗）；
   * 长按任一词进入编辑态 —— 词旁显示红色 ✕（点击删除该词、即时落盘），
   * 点词体退出编辑态恢复点词搜索。
   */
  @Builder
  CommonWordsSection(): void {
    Column() {
      Text('常用搜索')
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ bottom: 8 })
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.commonWords, (word: string): void => {
          Row({ space: 5 }) {
            Text(word)
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
            if (this.wordsEditing) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(12)
                .fontColor([$r('app.color.state_error')])
                .onClick((): void => {
                  this.deleteCommonWord(word);
                })
            }
          }
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(14)
          .backgroundColor($r('app.color.bg_card'))
          .border({ width: 0.5, color: $r('app.color.bg_divider') })
          .margin({ right: 8, bottom: 8 })
          .alignItems(VerticalAlign.Center)
          .stateStyles({
            pressed: { .backgroundColor($r('app.color.press_overlay')) },
            normal: { .backgroundColor($r('app.color.bg_card')) }
          })
          .onClick((): void => {
            if (this.wordsEditing) {
              this.wordsEditing = false;
            } else {
              this.useHistoryWord(word);
            }
          })
          .gesture(
            LongPressGesture({ duration: 400 })
              .onAction((): void => {
                if (!this.wordsEditing) {
                  this.wordsEditing = true;
                  this.toast('点击 ✕ 删除，点击词完成', 1600);
                }
              })
          )
        }, (word: string): string => `cw_${word}`)
        // 「+」新建常用搜索词：与词胶囊同语言（同底同描边），点击开弹窗
        Row() {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(14)
            .fontColor([$r('app.color.text_secondary')])
        }
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .borderRadius(14)
        .backgroundColor($r('app.color.bg_card'))
        .border({ width: 0.5, color: $r('app.color.bg_divider') })
        .margin({ right: 8, bottom: 8 })
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.press_overlay')) },
          normal: { .backgroundColor($r('app.color.bg_card')) }
        })
        .onClick((): void => {
          this.openAddWord();
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .margin({ top: this.listStartOffset() })
  }

  /** 打开「新建常用搜索词」弹窗：先退出编辑态，草稿清零再开 */
  private openAddWord(): void {
    this.wordsEditing = false;
    this.newWordDraft = '';
    this.addWordController?.open();
  }

  /** 弹窗取消 / 点遮罩关闭：只清草稿（关闭由系统 / 自绘取消键完成） */
  private cancelAddWord(): void {
    this.newWordDraft = '';
  }

  /** 弹窗「添加」：空名 / 与现有词重复时 toast 提示且弹窗保持打开 */
  private confirmAddWord(): void {
    const word: string = this.newWordDraft.trim();
    if (word.length === 0) {
      this.toast('请输入搜索词', 1500);
      return;
    }
    if (this.commonWords.indexOf(word) >= 0) {
      this.toast('该搜索词已存在', 1500);
      return;
    }
    this.commonWords.push(word);
    this.saveCommonWords();
    this.addWordController?.close();
    this.newWordDraft = '';
    this.toast(`已添加「${word}」`, 1400);
  }

  /** 删除常用搜索词（编辑态点 ✕）：@State 数组 splice 即时刷新，落盘 fire-and-forget */
  private deleteCommonWord(word: string): void {
    const idx: number = this.commonWords.indexOf(word);
    if (idx < 0) {
      return;
    }
    this.commonWords.splice(idx, 1);
    this.saveCommonWords();
  }

  /** 常用搜索词完整列表落盘（与设置页写偏好同口径：不等待、失败静默） */
  private saveCommonWords(): void {
    AppPreferences.setObject<string[]>(PREF_COMMON_WORDS, this.commonWords);
  }

  /**
   * 「新建常用搜索词」对话框内容区：输入框 + 自绘按钮行（取消 / 添加）。
   * 按钮刻意不走 CustomContentDialog 的 buttons 槽 —— 空名 / 重名校验失败
   * 要保持弹窗打开，buttons 槽点击即自动关闭（faqs-arkui-986），只能自管关闭时机。
   */
  @Builder
  AddWordBody(): void {
    Column() {
      TextInput({ placeholder: '搜索词，如「民谣」', text: this.newWordDraft })
        .width('100%')
        .height(44)
        // 字阶只用六档（24/20/18/16/13/11），与 SaverBody 的输入框同款 16
        .fontSize(16)
        .onChange((v: string): void => {
          this.newWordDraft = v;
        })
      Row() {
        Button('取消', { type: ButtonType.Normal })
          .layoutWeight(1)
          .height(44)
          .borderRadius(BUTTON_RADIUS_VP)
          .backgroundColor($r('app.color.bg_divider'))
          .fontColor($r('app.color.text_primary'))
          .onClick((): void => {
            this.addWordController?.close();
            this.cancelAddWord();
          })
        Button('添加', { type: ButtonType.Normal })
          .layoutWeight(1)
          .height(44)
          .borderRadius(BUTTON_RADIUS_VP)
          .backgroundColor(this.themePrimary)
          .fontColor(this.themeOn)
          .margin({ left: 12 })
          .onClick((): void => {
            this.confirmAddWord();
          })
      }
      .margin({ top: 16 })
    }
    .width('100%')
  }

  /**
   * 「加入歌单」弹窗正文：副标题（曲名）+「新建歌单并加入」+ 歌单列表。
   * 标题在 CustomContentDialog 的 primaryTitle；取消在 buttons 槽（自动关闭）。
   */
  @Builder
  PlaylistPickerBody(): void {
    Column() {
      Text(this.pickerTrack ? this.pickerTrack.title : '')
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
                this.addToPlaylist(p);
              })
            }
          },
          // key 含渲染字段（与 PlaylistsPage 同因）：改名/数量变化后行才会重渲染
          (p: Playlist): string => `${p.id}_${p.name}_${p.tracks.length}`
        )
      }
      .width('100%')
      // 边界回弹：歌单多到可滚时，到边界的反馈动效
      .edgeEffect(EdgeEffect.Spring)
      .constraintSize({ maxHeight: 260 })
    }
    .width('100%')
  }

  /**
   * 页内「最近搜索 / B 站热搜」页签区。
   *
   * 渲染条件见 SearchStateArea：还没搜过。两个页签：
   *   · 最近搜索 —— 有历史才显示该页签；「删除搜索记录」清空后自动切到热搜；
   *   · 热搜 —— B 站当前热搜词（getHotSearchKeywords，页面存活期内缓存，
   *     右角「刷新」强制重拉；榜单顺序，前三名序号主题色高亮）。
   * 点任一词条立即以该词搜索（useHistoryWord → doSearch，统一记进最近搜索）。
   * 区列 layoutWeight 铺满到屏幕底部安全区沿，
   * 列表超出部分内部滚动，contentEndOffset 让末条可滚出悬浮播放条上方。
   */
  @Builder
  HistorySection(): void {
    Column() {
      Row() {
        if (this.history.length > 0) {
          // 「最近搜索 / 热搜」官方分段按钮（CapsuleSegmentButtonV2，B 站粉经
          // itemSelectedBackgroundColor 覆写，与结果页签「视频/UP主」同一套语言）。
          // ⚠️ V2 分段按钮给多大渲染多大（均摊到各段），必须显式宽度。
          CapsuleSegmentButtonV2({
            items: this.historySegItems,
            selectedIndex: this.searchSectionTab === 'hot' ? 1 : 0,
            onItemClicked: (index: number): void => {
              this.switchSectionTab(index === 1 ? 'hot' : 'history');
            },
            itemSelectedBackgroundColor: this.segColors().selectedBg,
            itemSelectedFontColor: this.segColors().selectedFont,
            itemSelectedFontWeight: FontWeight.Medium,
            itemFontColor: this.segColors().unselectedFont,
            itemFontWeight: FontWeight.Normal,
            itemFontSize: LengthMetrics.vp(13),
            itemSelectedFontSize: LengthMetrics.vp(13),
            buttonBackgroundColor: this.segColors().grooveBg,
            buttonBorderRadius: LengthMetrics.vp(8),
            itemBorderRadius: LengthMetrics.vp(6),
            // 内部背板最小高度对齐 32（默认约 36 会盖过 .height(32)，SearchTabBar 同款结论）
            buttonMinHeight: LengthMetrics.vp(32),
            // 紧凑内边距（系统默认 16vp 空气感过强，SearchTabBar 真机验收同款收到 8vp）
            itemPadding: { start: LengthMetrics.vp(8), end: LengthMetrics.vp(8) }
          })
            .height(32)
            // 显式宽度：V2 分段按钮把总宽「均摊」到各段（非按内容自适应），
            // 每段须容纳最长文案「最近搜索」（13fp ≈52vp + 16vp 内边距 ≈68），
            // 152/2 = 76 ≥ 68 才不截断（「热搜」只需 ≈42，天然富余）。
            .width(152)
        } else {
          // 没有历史时不显示「最近搜索」页签，热搜独占
          Text('热搜')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
        }
        Blank()
          .layoutWeight(1)
        if (this.searchSectionTab === 'hot') {
          Text(this.hotLoading ? '加载中…' : '刷新')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .padding({ left: 8, top: 4, bottom: 4 })
            .stateStyles({
              pressed: { .backgroundColor($r('app.color.press_overlay')) },
              normal: { .backgroundColor(Color.Transparent) }
            })
            .onClick((): void => {
              this.refreshHotWords();
            })
        } else {
          Text('删除搜索记录')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .padding({ left: 8, top: 4, bottom: 4 })
            .stateStyles({
              pressed: { .backgroundColor($r('app.color.press_overlay')) },
              normal: { .backgroundColor(Color.Transparent) }
            })
            .onClick((): void => {
              this.clearHistory();
            })
        }
      }
      .width('100%')
      .margin({ bottom: 4 })

      if (this.searchSectionTab === 'hot') {
        this.HotWordList()
      } else {
        List() {
          ForEach(this.history, (word: string): void => {
            ListItem() {
              Text(word)
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .padding({ top: 12, bottom: 12 })
                .stateStyles({
                  pressed: { .backgroundColor($r('app.color.press_overlay')) },
                  normal: { .backgroundColor(Color.Transparent) }
                })
                .onClick((): void => {
                  this.useHistoryWord(word);
                })
            }
          }, (word: string): string => word)
        }
        .width('100%')
        // 铺满页签区剩余高度（父列高度确定）；超出部分列表内滚，
        // contentEndOffset 让末条能滚出底部悬浮播放条上方（与结果列表同口径避让）。
        .layoutWeight(1)
        .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
        // 边界回弹：历史多到可滚时，到顶/到底的反馈动效
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    // 顶距不再用 listStartOffset（让位由上方 CommonWordsSection 承担），
    // 这里只做区段间距
    .margin({ top: 24 })
    // 父列（SearchStateArea 初始态 Column）高度已定，本列吃掉
    // CommonWordsSection 以下全部剩余高度，直达屏幕底部安全区沿。
    .layoutWeight(1)
  }

  /**
   * 热搜页签列表：榜单顺序（首位最热）、前三名序号主题色高亮；
   * 空态区分「正在拉取」与「拉取失败/为空」，后者引导点「刷新」。
   */
  @Builder
  HotWordList(): void {
    if (this.hotWords.length === 0) {
      Row() {
        if (this.hotLoading) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color($r('app.color.text_tertiary'))
          Text('正在加载热搜…')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ left: 8 })
        } else {
          Text('没有获取到热搜，点「刷新」重试')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')
      .padding({ top: 20, bottom: 20 })
      .justifyContent(FlexAlign.Center)
    } else {
      List() {
        ForEach(this.hotWords, (word: string, index: number): void => {
          ListItem() {
            Row() {
              Text(`${index + 1}`)
                .fontSize(13)
                .fontColor(index < HOT_TOP_RANK_COUNT
                  ? this.themeDeep : $r('app.color.text_tertiary'))
                .width(24)
              Text(word)
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .stateStyles({
              pressed: { .backgroundColor($r('app.color.press_overlay')) },
              normal: { .backgroundColor(Color.Transparent) }
            })
            .onClick((): void => {
              this.useHistoryWord(word);
            })
          }
        }, (word: string): string => word)
      }
      .width('100%')
      // 铺满页签区剩余高度；末尾避让与结果列表同口径（悬浮播放条 + 安全区），
      // 末条可滚出条上方。
      .layoutWeight(1)
      .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
    }
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Column() {
          this.SearchStateArea()

          // 下拉刷新 + 上拉加载更多都挂在 List 上：
          // Refresh 只包住列表（搜索行在 HDS titleBar 内，不参与下拉手势）。
          //
          // 骨架接管：refreshingContent 只放 0.1vp 静态空占位
          // （见 PullRefreshPlaceholder），唯一作用是顶掉系统默认刷新头；
          // 刷新指示完全由 List 首行的骨架行承担。占位在 aboutToAppear 里创建
          // （ComponentContent 构造依赖 UIContext）。
          Refresh({
            refreshing: $$this.refreshing,
            refreshingContent: this.refreshPlaceholder !== null ? this.refreshPlaceholder : undefined
          }) {
            List({ scroller: this.listScroller }) {
              // 顶部空白占位条目（下载页同款）：列表视口铺满全屏，条目起始位置在
              // 屏幕顶端（y=0）。占位高度 = 列表内容起始让位量（listStartOffset：
              // safeTop + 56 + 独立定值），滚动时占位与条目一起从模糊板下方穿过。
              ListItem() {
                // 下拉刷新头（骨架接管）：刷新指示复用骨架行本身，不新增视觉元素。
                // 刻意不用 refreshingContent：ComponentContent 的内容不随页面
                // @State 刷新（要变只能显式 update），逐帧跟手做不到；普通组件树里才能被
                // onOffsetChange 的映射即时驱动。index 传 -1：SkeletonTrackItem 的入场错峰
                // 只认 0..5，-1 即不播入场（骨架本就纯静态），
                // 显隐节奏由刷新状态机（onRefreshStateChange）自己管。
                // 闸门第二条件：整屏骨架在场（列表为空，SearchStateArea 已接管）时绝不渲染，
                // 否则「顶部一条 + 下面一整屏」。
                // 骨架挂在占位条目内的 Stack 里做零布局覆盖：条件挂载若增删普通
                // ListItem，Drag/Inactive 翻转时会对下方内容产生
                // ±92vp（64 封面 + 上下 padding 28）布局位移；Stack 定高，
                // 挂载翻转只增删被定位的覆盖子节点，布局零影响。
                Stack({ alignContent: Alignment.BottomStart }) {
                  if (this.showPullSkeleton && this.hasAnyResult()) {
                    SkeletonTrackItem({ index: -1 })
                      .opacity(this.pullSkelOpacity)
                      .translate({ y: this.pullSkelOffsetY })
                      // 纯装饰：骨架永不交互；透明期也不吞占位带的触摸（透明节点
                      // 默认仍参与命中测试，会阻断列表滚动手势起手）。
                      .hitTestBehavior(HitTestMode.None)
                  }
                }
                .width('100%')
                .height(this.listStartOffset())
              }

              // 结果页签分段行（「视频 | UP主」+ 当前页签计数）：搜出内容
              // （视频或 UP 主任一非空）才出现；整屏骨架（loading）与整页
              // 空态由 SearchStateArea 接管，不与本行叠出。
              if (!this.loading && this.searched && this.hasAnyResult()) {
                ListItem() {
                  this.ResultTabBar()
                }
              }

              // 两页签共用一个 List（滚动容器 / 下拉刷新 / 顶栏模糊联动全部
              // 复用），条目区按 resultTab 条件渲染；切换即换源并归位
              // （switchResultTab）。空页签在页签内占位说明，两类都空由
              // SearchStateArea 整页空态接管。
              if (this.resultTab === 'video') {
                if (this.results.length === 0) {
                  // 视频页签空态：另一页签有内容时才有本占位
                  ListItem() {
                    Text('没有找到相关视频')
                      .fontSize(16)
                      .fontColor($r('app.color.text_secondary'))
                  }
                  .width('100%')
                  .margin({ top: 48 })
                } else {
                  this.VideoTabContent()
                }
              } else {
                this.UpTabContent()
              }
            }
            .width('100%')
            .height('100%')
            // 边界回弹：到底的反馈动效；顶部下拉由 Refresh 刷新动画接管。
            .edgeEffect(EdgeEffect.Spring)
            .cachedCount(8)
            // Sumy 式穿透：顶部 HDS 标题栏让位由 List 首个空白占位 ListItem 负责
            // （见上方占位注释，下载页同款），不用 contentStartOffset ——
            // 材质层有内容可模糊（浮出效果才可见）。
            // 末尾让位叠加 safeBottom：二级页悬浮播放条（SubPagePlayBar）盖在
            // 底部安全区上沿，列表末尾多让这一份避免最后一行被压住。
            .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
            .onReachEnd((): void => {
              this.onReachEnd();
            })
            // 逐帧驱动自绘渐变模糊层（onDidScroll 在偏移已应用
            // 后回调，onWillScroll 是应用前，快滑时差一帧会让模糊层滞后一跳）。
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
            this.refreshSearch();
          })
          // ── 下拉刷新参数底座 ──
          // 触发阈值 72vp（同时是骨架淡入进度的分母：拉满 = 不透明 = 「松手即刷」）；
          // 跟手 55%（跟手但带阻尼）；最大下拉 120vp 封顶，防大力下拉把页面拽出半屏。
          .refreshOffset(PULL_REFRESH_OFFSET_VP)
          .pullDownRatio(PULL_REFRESH_RATIO)
          .maxPullDownDistance(PULL_MAX_DISTANCE_VP)
          // 五态状态机：跟手闸门 / Done 淡出（见 onRefreshStateChange）
          .onStateChange((status: RefreshStatus): void => {
            this.onRefreshStateChange(status);
          })
          // 每帧回写下拉进度 → 骨架淡入 + 落位映射（跟手要即时，不套 animateTo）；
          // 只写状态变量：不发请求 / 改数组 / 打日志。Done 淡出在途时让位给退场动画。
          .onOffsetChange((offset: number): void => {
            this.pullOffset = offset;
            if (this.pullFadeTimer !== -1) {
              return;
            }
            const p: number = Math.min(this.pullOffset / PULL_REFRESH_OFFSET_VP, 1);
            this.pullSkelOpacity = p;
            this.pullSkelOffsetY = (1 - p) * PULL_SKELETON_SETTLE_VP;
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
        // ⚠️ 不再整体 padding top：列表视口要铺满全屏（占位条目负责让出栏高），
        // 否则条目在栏底被裁掉、永远滑不进模糊板下方。骨架/空态区各自补 listStartOffset()。
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp，见 BreakpointConstants）。
        // 根 Stack 默认居中对齐，直接给内容列挂上限即可，不需要额外包一层。
        // 横屏宽屏：上限放宽到 840vp，两列每列行宽约 400vp+。
        .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })

        // 顶栏渐变模糊层：盖主内容列之上（z 序低于历史面板，低于 HDS
        // titleBar；弹窗类已全部走官方 CustomContentDialog，不挂根 Stack），
        // 进度由列表 onDidScroll/onScrollStop 经 topBlurUpdater 命令式驱动。
        // HDS 滚动效果已由 titleBar styleOptions 第三参关闭（防双重模糊），
        // 本层承担全部渐变模糊观感。
        TopGradientBlurOverlay({
          barHeightVp: this.safeTop + NAV_TITLE_BAR_HEIGHT,
          updater: this.topBlurUpdater
        })
      }
      .width('100%')
      .height('100%')
      // ⚠️ 栏内动作必须在 **onAppear**（真正挂载）里接管，不能放 aboutToAppear：
      // HdsNavigation 会先创建一个**临时实例**再销毁它（实测
      // appear id=1 → appear id=2 → disappear id=2），若在 aboutToAppear 里绑静态
      // 回调，就会被这个已销毁的临时实例抢走 —— 表现是「搜索请求发出去了、界面不动」。
      .onAppear((): void => {
        TabScrollerHolder.searchSubmitOwner = this.pageId;
        TabScrollerHolder.searchSubmit = (): void => {
          this.doSearch();
        };
        // 清空输入框 → 回初始页（与 searchSubmit 同生命周期，归属校验共用 owner）
        TabScrollerHolder.searchReset = (): void => {
          this.resetToLanding();
        };
        console.info(`[Search] bind id=${this.pageId}`);
      })
      .onDisAppear((): void => {
        // 只清自己的绑定：否则临时实例销毁时会把可见实例的绑定一起清掉
        if (TabScrollerHolder.searchSubmitOwner === this.pageId) {
          TabScrollerHolder.searchSubmitOwner = -1;
          TabScrollerHolder.searchSubmit = (): void => {
          };
          TabScrollerHolder.searchReset = (): void => {
          };
          console.info(`[Search] unbind id=${this.pageId}`);
        }
      })
    }
    // HDS 沉浸光感标题栏（RecentPage 样板同款）：
    // avoidLayoutSafeArea 挡状态栏重叠；HDS 滚动效果关闭（styleOptions 第三参
    // false），让位自绘渐变模糊层（TopGradientBlurOverlay），防双重模糊。
    // stackBuilder 承载搜索行（SearchInputBar，收窄容器内与条目列对齐）。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        stackBuilder: (): void => {
          this.searchBarNarrow();
        }
      }
    })
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页列表交给 HDS 联动
    .bindToScrollable([this.listScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 系统返回拦截：播放页 overlay 打开时吞掉返回并发收起请求
    //（utils/SubPageBackPress）；否则走默认 pop。
    .onBackPressed((): boolean => {
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
export function SearchPageBuilder(): void {
  SearchPage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const SearchPageWrapped: WrappedBuilder<[]> = wrapBuilder(SearchPageBuilder);
