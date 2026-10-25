/**
 * 应用首页：**HDS 沉浸光感悬浮胶囊**，播放栏（PlayBar）与页签融合在同一个胶囊里。
 *（底栏布局两种形态，设置 → 外观 → 底部导航布局 可切：水平融合（默认，
 * barLayoutMode: HORIZONTAL，播放栏与页签同一行）/ 垂直两层（VERTICAL，
 * 播放栏在上、页签在下）—— 两种形态同为一个 HdsTabs，仅 miniBar 的
 * barLayoutMode 不同，见 barFloatingStyle。）
 *
 * 底栏实现移植自 Sumy-Music（`@kit.UIDesignKit` 的 HdsTabs + barFloatingStyle）：
 *   HdsTabs 渲染**离底悬浮的胶囊**，施加系统沉浸式材质 + 主题色光晕 + 微透明。
 *
 * ══════════ 融合式播放栏（参考 MusicHome / Sumy 的 miniBar 集成方案）══════════
 *   PlayBar 作为 barFloatingStyle.miniBar 的 builder 内容交给 HDS 渲染，
 *   全局只在首页配置这一次：
 *     · barLayoutMode: HORIZONTAL → miniBar 与页签项排进**同一行**
 *       （播放栏在左、页签在右，一左一右融合成一个胶囊）；
 *       barLayoutMode: VERTICAL   → 迷你播放栏在上、页签栏在下（垂直两行）；
 *     · 液态玻璃材质 / 悬浮定位 / 底部避让全部由 HDS 统一处理，不再重复实现；
 *     · 展开 / 收起：手动控制（miniBarStyle 跟随 STORE_MINI_BAR_EXPANDED，
 *       onBarStyleChange 拦截 NORMAL 系统自动变更，只放行用户点击与控制器调用），
 *       状态写入 AppStorage —— miniBarBuilder 内容会被 HDS 缓存，组件必须靠
 *       全局状态切换「整行 / 圆盘」两态内容（见 components/PlayBar.ets）；
 *     · ⚠️ 折叠屏展开 / 平板（HdsTabs 宽度 ≥600vp）：HDS 强制迷你栏展开态，
 *       miniBarStyle 与 applyMiniBarStyle 均不生效（官方文档：仅宽度 <600vp 可设），
 *       此时全局展开态必须同步为 true，PlayBar 内容才与胶囊槽位一致
 *       （见 currentBreakpoint / onBreakpointChanged）；
 *     · 队列为空时 barFloatingStyle 不带 miniBar → 胶囊退回纯页签，播放栏隐藏。
 *
 * ⚠️ 本工程与 Sumy 的一处**关键差异**：EntryAbility 调了
 * `setWindowLayoutFullScreen(true)`（窗口级全屏，见 EntryAbility.enableFullScreenLayout），
 * 系统**不再自动避让**安全区。HDS 的悬浮栏只认 `barBottomMargin` 这个「离屏幕底边多远」，
 * 由本页按导航模式折算（见 barFloatingStyle）：
 *   手势导航   barBottomMargin = 6 + 指示条避让区 × 0.5（避开指示条一半，贴近底部边框）
 *   三键导航   barBottomMargin = 6 + 三键导航栏避让区  （整条导航栏必须完整避让）
 * ⚠️ 导航模式判据 = **避让区来源**（getWindowAvoidArea 实测 TYPE_NAVIGATION_INDICATOR /
 * TYPE_SYSTEM 底部矩形，avoidAreaChange 动态更新，UIContext.px2vp 换算），不写死高度
 * 阈值 —— 阔折叠 / 阔直板大屏展开态的指示条与导航栏高度和手机不同（形态、密度、
 * 分屏都影响），高度阈值启发式在大屏上会误判分支。
 * 若真机上出现「离底留白翻倍」，那就是 HDS 内部也做了一次避让 → 把间距改成 BAR_BOTTOM_MARGIN。
 *
 * ══════════ 全屏布局与避让的消费点（**不使用 expandSafeArea**） ══════════
 * 底部避让**不放在根容器**：根容器 padding 会把 Tabs 内容区整体截短，
 * 首页（搜索页）的列表就铺不到屏幕最底，与「布局区域延伸到底部手势条下方」相矛盾。
 * 所以底部避让**下移给真正需要它的控件与子页面，各自消费一次、互不重叠**：
 *
 *   各 Tab 固定栏    材质 Row 内部 padding.top = safeTop → 状态栏让位由固定栏自己消化：
 *                                                        材质从 y=0 铺起、覆盖状态栏区域
 *                                                        （真沉浸），HdsTabs 整层不再加
 *                                                        top padding。
 *   悬浮胶囊        barBottomMargin 见 barFloatingStyle  → 下沉贴近底边，避开手势条/导航栏
 *   各 Tab 列表     contentEndOffset = 160 + safeBottom → 末尾能滚到胶囊上方
 *   子页面          目的地链统一 .ignoreLayoutSafeArea([SYSTEM],[TOP,BOTTOM]) 声明沉浸；
 *                    内容层避让由各页 contentStartOffset / plain padding 自理
 *
 * ⚠️ 顶部：Tab 页固定栏的材质 Row 自带 padding({ top: safeTop })——Row 的 padding 在
 * 组件边界内，材质背景覆盖含 padding 的整个区域，因此栏内容落在状态栏下方、材质却
 * 上延覆盖状态栏（与底部胶囊一致的沉浸观感）。各页内容层避让量需含 safeTop
 * （实测高度的页由 onAreaChange 自动含入，常量避让的页显式相加）。
 * NavDestination 子页的标题栏不参与 HdsTabs 布局，由原生栏 + 各子页自己的
 * padding({ top: safeTop }) 处理，不受本页影响。
 *
 * safeTop / safeBottom 的写入路径：
 *   EntryAbility.publishSafeArea() 首帧前同步首发（避免内容先贴边再弹回来），
 *   本页 aboutToAppear 再主动读一次并注册 avoidAreaChange，
 *   旋转屏幕 / 切换三键与手势导航后自动更新。
 *
 * 子页面通过 Navigation + NavPathStack 管理（播放页 / 歌单详情 / 最近播放 / 登录页）。
 * 登录页（'Login' 路由），入口在设置页「账户」分组。
 *
 * ══════════ 平板形态（lg，全形态归一 phoneShell）══════════
 * deviceTypes 加 tablet 后平板可安装。全形态统一走
 * phoneShell()：HdsTabs 沉浸光感悬浮胶囊底栏 + miniBar 融合播放栏
 * （IMMERSIVE 材质 + 主题色光晕，MaterialTokens 单一出处），与 MusicHome
 * 平板横屏同形态（本壳为加强实现）。
 * 附带收益：旋转 / 折叠 / 断点切换全程同壳，不再跨壳整树重挂（HdsTabs 与
 * 四页实例存活、页内瞬时状态保留）。NavStackHolder 单例路由栈与播放内核
 * 全形态共用。tabController / applyMiniBarStyle / 屏幕滑动收放等 HDS 联动
 * 全形态有效（均有宿主 HdsTabs）。
 */

import { UIContext } from '@kit.ArkUI';
import {
  HdsNavigation,
  HdsTabs,
  HdsTabsController,
  HdsTabsFloatingStyle,
  HdsTabsMiniBar,
  HdsBarStyle,
  HdsTabsBarChangeMode,
  HdsBarLayoutMode,
  DividerShowType,
  HdsNavigationTitleMode,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { Track, BAR_LAYOUT_HORIZONTAL, BAR_LAYOUT_VERTICAL } from '../model/MusicModels';
import { HomePage } from './HomePage';
import { PlaylistsPage } from './PlaylistsPage';
import { DownloadsPage } from './DownloadsPage';
import { SettingsPage } from './SettingsPage';
// 以下 10 个导航子页面（PlayerPage / PlaylistDetail / RecentPage /
// FollowsPage / UpSpacePage / WatchHistoryPage / FavSyncPage / PlaylistImportPage /
// AboutPage / LoginPage，短信登录已并入 LoginPage）为懒加载 ——
// 它们只在 pageMap 被路由触达时才需要，静态引用会拖整棵子树（含 lyric/*、
// components/player/*）在冷启动首帧前解析，直接拉长「应用启动加载完成」。
// 现统一走 service/LazyPageRegistry 动态 import，首帧后 1.5s 低优先级预热。
import { LazyDest, preloadAllLazyPages } from '../service/LazyPageRegistry';
import { NavStackHolder } from '../service/NavStackHolder';
import { PlayBar } from '../components/PlayBar';
import { SubPagePlayBar } from '../components/SubPagePlayBar';
import { AppToast, showAppToast } from '../components/AppToast';
import { AppDialogHost } from '../components/AppAlertDialog';
import { MaterialCompat } from '../utils/MaterialCompat';
import { MaterialTokens } from '../common/style/MaterialTokens';
import { watchNetwork } from '../utils/NetworkUtil';
import { BreakpointSystem } from '../common/utils/BreakpointSystem';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
// 根顶栏收窄上限与各页内容列统一走 840 口径
//（TwoColumnLayout.contentMaxWidth，见 immersiveTitleBarNarrow 注释）。
import { TwoColumnLayout } from '../common/utils/TwoColumnList';
import {
  STORE_QUEUE,
  STORE_MINI_BAR_EXPANDED,
  STORE_SAFE_TOP,
  STORE_SAFE_BOTTOM,
  STORE_NAV_BAR_BOTTOM,
  STORE_NAV_INDICATOR_BOTTOM,
  STORE_NET_RETRY_REV,
  STORE_ACTIVE_TAB,
  STORE_TAB_SWITCH_REQUEST,
  STORE_TAB_SWITCH_TARGET,
  STORE_BAR_LAYOUT,
  STORE_DL_BAR_HAS_TASKS,
  STORE_DL_BAR_SELECTING,
  STORE_PL_BAR_SELECTING,
  GLOW_ALPHA,
  STORE_THEME_PRIMARY,
  STORE_MINI_BAR_ANIM_PHASE,
  MINI_BAR_ANIM_IDLE,
  MINI_BAR_ANIM_TO_EXPAND,
  MINI_BAR_ANIM_TO_COLLAPSE,
  STORE_MINI_BAR_AUTO_EXPAND,
  STORE_MAIN_MINI_BAR_WIDTH,
  STORE_PLAYER_OPEN,
  STORE_PLAYER_OVERLAY_MOUNTED,
  STORE_PLAYER_CLOSE_REQUEST,
  STORE_PLAYER_CONTENT_EXIT,
  STORE_PLAYER_TRANSITIONING,
  STORE_PLAYER_CLOSE_ANIM,
  STORE_PLAYER_GT_OFF,
  STORE_PLAYER_SLIDE_OUT,
  STORE_PLAYER_SLIDE_OFFSET,
  STORE_PLAYER_SLIDE_ALPHA,
  STORE_PLAYER_SLIDE_CLOSE_REQUEST,
  STORE_PLAYER_DRAG_ACTIVE,
  STORE_PLAYER_SLIDE_IN,
  PLAYER_TRANSITION_MS,
  STORE_WINDOW_WIDTH_VP,
  STORE_WINDOW_HEIGHT_VP,
  STORE_SAFE_LEFT,
  STORE_SAFE_RIGHT,
  STORE_SUB_PAGE_ACTIVE,
  STORE_HOME_SEARCH_ENTRY_ACTIVE,
  STORE_HOME_CHIPS_ACTIVE,
  STORE_SEARCH_TAB,
  STORE_STARTUP_HINT_MSG,
  STORE_STARTUP_HINT_SEQ,
  STORE_CARD_OPEN_PLAYER_SEQ
} from '../common/Constants';
import { PLAYER_MAIN_CURVE, PLAYER_SLIDE_CURVE, SLIDE_CLOSE_MS } from '../common/constants/InteractionConstants';
import { PLAYER_CLOSE_STYLE_SLIDE } from '../model/MusicModels';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { NAV_TITLE_BAR_HEIGHT, NAV_H_PADDING } from '../utils/NavTitleStyle';
import { DlSelectToggle, DlQueueActions, DlControlBar } from '../components/DownloadsTabBar';
import { PlTitleActions, PlSelectToolbar } from '../components/PlaylistsTabBar';
import { HOME_CATEGORY_CHIPS, CategoryChipUi } from '../components/HomeCategoryChips';

/**
 * 悬浮页签栏完整避开系统底部控件（三键导航栏 / 手势指示条避让区）后的净空隙（vp）。
 * 对齐华为音乐悬浮观感（胶囊底缘离屏约 30vp）。若目测仍需微调，只动此值
 * （每 +1vp = +2.75px）。
 */
const BAR_BOTTOM_MARGIN: number = 2;
/**
 * 阔折叠展开（lg 宽度）且队列非空（带 miniBar）时悬浮栏离屏幕左右边缘的边距
 * （vp）：页签胶囊贴左、迷你栏贴右按同一值对称内收（lg=83，用户定值；
 * md/sm 走 HDS 默认）。
 * ⚠️ barSideMargin 本身就是精确 vp，不存在 HDS 缩放
 * （83vp × 阔折叠实际密度 2.75 = 228px 分毫不差）。
 */
const BAR_SIDE_MARGIN_LG: number = 83;
/**
 * 悬浮页签胶囊**锁定**宽度（vp，4 页签）：barFloatingStyle.barWidth 显设值，
 * 居中公式 sideMargin=(容器宽−本值)/2 的被减数。选 304（= 76×4）与「队列非空
 * lg 双胶囊散开」时 HDS 的实测宽度（S=83 → 304vp）一致，跨状态切换宽度不跳变。
 * ⚠️ 不锁宽时 HDS 宽度随边距漂移（dumpLayout 实测：默认 S→328、S=83→304、
 * S=318→272），公式里的「宽」不可控，必须配 barWidth 一起设。
 * 若 HDS 版本升级导致宽度漂移，用 uitest dumpLayout 重测本校准。
 */
const BAR_FLOATING_BAR_WIDTH: number = 304;

/**
 * 根 HdsNavigation 统一标题栏：
 * 根栏**四页签常显**（titleMode MINI + hideBackButton + divider OFF），
 * stackBuilder 承载整块顶栏内容 —— 行 1（56 标题行 / 搜索行）+ 行 2 溢出渲染
 * （position y=56 + clip(false) + hitTestBehavior Transparent，
 * ImmersiveTitleBarContent 同款手法）。
 */
const TAB_SEARCH: number = 0;
const TAB_PLAYLISTS: number = 1;
const TAB_DOWNLOADS: number = 2;
const TAB_SETTINGS: number = 3;
/**
 * 屏幕竖向滑动（parallelGesture）判定收/放意图的触发阈值（vp）：
 * 上滑超过 → 展开、下滑超过 → 收起；一次手势只触发一次。
 * 并行模式下列表滚动同时进行——正常浏览列表的竖向滑动也会触发，
 * 太灵敏就调大这里（24/32）。
 */
const SCREEN_PAN_TRIGGER_VP: number = 12;
/**
 * 切页内容动画时长：HdsTabs 定长 300ms 滑动，跨 2~3 页时距离翻倍 →
 * 速度 2~3 倍，观感「嗖一下」。改为按跨度缩放：
 * 相邻 300ms（与 Tabs.animationDuration 默认值一致，观感不变），
 * 每多跨一页 +120ms，封顶 540ms —— 速度仍随距离略增（纯匀速的 600/900ms
 * 太拖沓），但远距不再突兀。真机观感可在 STEP/MAX 单点微调。
 * ⚠️ 仅影响**点击页签**切页（Tabs.animationDuration 语义如此）；内容区
 * 滑动翻页走 interpolatingSpring(-1,1,228,30) 弹簧曲线，不受此属性控制。
 */
const TAB_SWITCH_BASE_MS: number = 300;
const TAB_SWITCH_STEP_MS: number = 120;
const TAB_SWITCH_MAX_MS: number = 540;

@Entry
@Component
struct Index {
  /**
   * 状态栏高度（vp）：窗口全屏后系统不再避让，页签层要自己顶下来这么多，否则
   * 搜索框 / 列表首项会被状态栏（时间、电量）压住。
   */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;

  /**
   * 底部避让区高度（vp）：手势导航 = 导航指示条区域，三键导航 = 导航栏。
   * 本页把它加进悬浮页签栏的 barBottomMargin（胶囊抬到手势条上方）。
   * Tabs 内容区自身不避让，所以首页（搜索页）的列表能一直铺到屏幕最底。
   * 全局底部播放栏与 NavDestination 子页各自用这个值避让（见 PlayBar / 各子页）。
   */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;

  /**
   * 三键导航栏避让区高度（vp，TYPE_SYSTEM.bottomRect）：>0 即三键导航。
   * 与 safeBottom（两来源取 max 的通用避让值）分开存 —— 悬浮胶囊要按「导航模式」
   * 选避让策略（三键整条避让 / 手势只避一半指示条）。按避让区来源判模式，
   * 动态实测（高度阈值启发式在阔折叠 / 阔直板大屏展开态会误判 → 胶囊垂直偏移）。
   * 写入：EntryAbility 首发一次 + 本页 avoidAreaChange 监听动态更新。
   */
  @StorageLink(STORE_NAV_BAR_BOTTOM) navBarBottom: number = 0;

  /**
   * 手势指示条避让区高度（vp，TYPE_NAVIGATION_INDICATOR.bottomRect）：
   * 手势导航下 = 指示条区域高度，三键导航下 = 0。悬浮胶囊只避开它的一半。
   */
  @StorageLink(STORE_NAV_INDICATOR_BOTTOM) navIndicatorBottom: number = 0;

  /**
   * 窗口内容区宽度（vp）：悬浮胶囊「居中 sideMargin」公式的输入（Constants 的
   * STORE_WINDOW_WIDTH_VP 注释）。EntryAbility 首帧前首发（冷启动首帧即正确，
   * 不闪「贴左 → 居中」），本页 bindAvoidArea 挂 windowSizeChange 持续回写
   * （applyWindowSize）—— 折叠开合 / 分屏 / 转屏后窗口 rect 变化即触发，
   * 宽度变 → 居中量自动重算。
   */
  @StorageLink(STORE_WINDOW_WIDTH_VP) windowWidthVp: number = 0;

  /**
   * 播放队列（歌单列表）：决定融合播放栏是否挂进悬浮胶囊 ——
   * 队列为空时 barFloatingStyle 不带 miniBar，胶囊退回纯页签形态（播放栏隐藏）。
   */
  @StorageLink(STORE_QUEUE) queue: Track[] = [];

  /**
   * miniBar 展开 / 收起态 —— 手动控制的**唯一事实源**（存 AppStorage；写入口：
   * aboutToAppear 初始值 / onBarStyleChange 上报 / onBreakpointChanged 宽屏对齐）。
   *
   * ⚠️ 这里**刻意不挂 @StorageLink**：挂 @StorageLink 的话，
   * onBarStyleChange 翻转 STORE_MINI_BAR_EXPANDED 时 Index 整页重渲染 →
   * barFloatingStyle() 返回**新对象** → HdsTabs 受控重建 →
   * miniBar 槽位内容（PlayBar）被**销毁重建**—— PlayBar 的 animateTo /
   * 过渡随旧实例被丢弃，新实例 aboutToAppear 直接取终值 → 圆盘 40↔28 瞬跳。
   * 因此用**非响应式读取**（miniBarExpandedNow()）：收放翻转不触发 Index 重渲染，
   * PlayBar 全程存活，过渡由 STORE_MINI_BAR_ANIM_PHASE 相位回调驱动（见
   * barFloatingStyle 里 onMiniBarAnimationStart/End）。
   *
   * ⚠️ 当前 SDK（HDS 6.1.1）没有 barChangeMode() 属性方法；HdsTabsBarChangeMode
   * 只是 onBarStyleChange 回调的上报参数（谁触发了这次变更）。要实现
   * 「展开/折叠只由代码控制 + miniBar 自身点击」，只能：
   *   1. miniBarStyle 受控跟随本状态（barFloatingStyle 按**内容键**缓存烘焙，
   *      展开态真正变化才重建配置对象，见 cachedFloatingStyle 注释）；
   *   2. onBarStyleChange 里拦截 NORMAL（系统自动重排：路由压栈/转屏/折叠开合），
   *      弹回当前手动态；USER_CLICK（点收起圆盘/页签）与 APP_TRIGGER（控制器）放行。
   */
  private miniBarExpandedNow(): boolean {
    return AppStorage.get<boolean>(STORE_MINI_BAR_EXPANDED) ?? false;
  }

  /**
   * 当前断点：决定 miniBar 展开态是否**可控**。
   *
   * ⚠️ HDS 文档（HdsTabsMiniBar.miniBarStyle）：迷你栏样式「仅 HdsTabs 宽度小于
   * 600vp 生效设置」，宽度 ≥600vp（折叠屏展开 md / 平板 lg）时 HDS **强制展开态**，
   * applyMiniBarStyle 同样无效。此时必须把全局展开态同步成 true，否则 PlayBar 按
   * 折叠态渲染内容、胶囊槽位却是展开布局 —— 症状就是「折叠屏上 miniBar 不生效」。
   * 断点切换时重新对齐，见 onBreakpointChanged。
   */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) @Watch('onBreakpointChanged')
  currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;

  /**
   * 当前横竖屏：BreakpointSystem 注册的 orientation 媒体查询写入
   * （IS_LANDSCAPE 键，Index 常驻注册一次全程有效，各列表页同款 @StorageProp 订阅）。
   * Index 内消费：immersiveTitleBarNarrow —— 根顶栏收窄上限与内容列同口径
   * （TwoColumnLayout.contentMaxWidth：两列激活 840，否则 600/720）。
   */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;

  /**
   * miniBar 初始折叠是否已应用过（只补一次的守卫）。
   * 部分版本上 miniBarStyle 初始值不生效，参考 Sumy：挂载后延迟 100ms 由
   * 控制器 applyMiniBarStyle(COLLAPSE) 补一次；用户后续的展开 / 收起不受影响。
   * 同时它也是 onBreakpointChanged 里「控制器是否已可安全调用」的守卫 ——
   * 冷启动在折叠屏展开态时，register 写断点会立刻触发 @Watch，那时 HdsTabs
   * 尚未挂载，不能调 applyMiniBarStyle（只同步全局状态即可）。
   */
  private miniBarApplied: boolean = false;

  /**
   * 主题色主色（运行时值）：页签选中字色与胶囊主题色光晕跟随它；
   * @StorageProp 变化触发本页重渲染，受控样式（barFloatingStyle）重建即生效。
   */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';

  /**
   * 底部导航布局（设置页「外观 → 底部导航布局」可切，AppSettings.barLayout 镜像）：
   * 水平融合（播放栏与页签同一行，HORIZONTAL）/ 垂直两层（播放栏在上、页签在下，
   * VERTICAL）。@StorageProp 变化触发重渲染，miniBar 的 barLayoutMode 即时重排。
   */
  @StorageProp(STORE_BAR_LAYOUT) barLayout: string = BAR_LAYOUT_HORIZONTAL;

  /**
   * 迷你栏自动展开收起开关（设置 → 外观「自动展开收起」，AppSettings.miniBarAutoExpand
   * 的运行时镜像，EntryAbility 首帧前首发真值）：关闭后屏幕上滑/下滑手势不再触发
   * 迷你栏收放（onScreenPanDirection 入口门控），点按圆盘 / onExpandRequest 等
   * 显式交互不受影响。默认开（保持手势上线以来的既有行为）。
   */
  @StorageProp(STORE_MINI_BAR_AUTO_EXPAND) miniBarAutoExpand: boolean = true;

  /**
   * ══════════ 播放页组件状态切换动画 ══════════
   *
   * 迷你栏 → 全屏播放页不走 NavDestination 路由：PlayBar.openPlayer 写
   * STORE_PLAYER_OVERLAY_MOUNTED → 本页根 Stack 条件挂载 LazyDest('Player')
   * （复用懒加载注册 + 1.5s 预热）→ PlayerInfoComponent 单个 animateTo(700ms,
   * fastOutSlowIn) 驱动：容器从迷你栏向四周扩大 + 封面 geometryTransition 页内配对飞行 +
   * 页签图标淡出（playerOpen）+ 内容分层入场（LAYER_DELAY_*）。
   * 收起逆向镜像：TopArea 收起按钮（STORE_PLAYER_CLOSE_REQUEST seq）或
   * onBackPress → closePlayer。
   */
  /**
   * 播放页 overlay 是否挂载（根 Stack 条件渲染，打开置 true / 收起动画结束回 false）。
   * @Watch 挂/卸载双时机驱动播放页横竖屏自动旋转：
   *   · 挂载 → 窗口切 AUTO_ROTATION（跟随传感器四向自动旋转，不受控制中心
   *     旋转开关限制）—— 播放页已备横竖两套版式，随设备姿态随转随切；
   *   · 卸载（收起动画落定后）→ 复原 UNSPECIFIED（跟随系统默认方向），
   *     壳层与各 Tab 页回归系统横竖屏状态。
   */
  @StorageProp(STORE_PLAYER_OVERLAY_MOUNTED) @Watch('onPlayerOverlayMountedChanged') playerOverlayMounted: boolean = false;

  /**
   * 播放页横竖屏自动旋转：overlay 在场期间窗口跟随传感器自动旋转，卸载复原
   * 系统默认。卸载选收起动画落定后的时机：收起瞬间恢复会与收起 morph 动画并行
   * 旋转，geometryTransition 配对按中途框计算必跳变。失败仅记日志不阻断播放。
   */
  private onPlayerOverlayMountedChanged(): void {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    const target: window.Orientation = this.playerOverlayMounted
      ? window.Orientation.AUTO_ROTATION
      : window.Orientation.UNSPECIFIED;
    window.getLastWindow(ctx)
      .then((win: window.Window): Promise<void> => {
        return win.setPreferredOrientation(target);
      })
      .then((): void => {
        console.info(`player window orientation -> ${this.playerOverlayMounted ? 'AUTO_ROTATION' : 'UNSPECIFIED'}`);
      })
      .catch((err: BusinessError): void => {
        console.error(`setPreferredOrientation failed: ${err.code} ${err.message}`);
      });
  }

  /** 播放页展开态：驱动页签图标淡出（tabItem opacity 绑定） */
  @StorageProp(STORE_PLAYER_OPEN) playerOpen: boolean = false;
  /** 收起请求信号（TopArea 收起按钮 seq 递增写入，@Watch 消费 → closePlayer） */
  @StorageProp(STORE_PLAYER_CLOSE_REQUEST) @Watch('onCloseRequest') playerCloseRequest: number = 0;

  /**
   * 桌面卡片拉起播放页 seq（EntryAbility.handleCardRouter 递增写入；
   * 卡片根节点 / FormLink 的 router 请求 → 冷启动 onCreate / 热启动 onNewWant）。
   * @StorageProp 初值同步不触发 @Watch：aboutToAppear 里显式补刀（先写后挂时序）。
   */
  @StorageProp(STORE_CARD_OPEN_PLAYER_SEQ) @Watch('onCardOpenPlayerSeq') cardOpenPlayerSeq: number = 0;
  /** 已消费的卡片拉起 seq（补刀比对用，防重放） */
  private lastCardOpenSeq: number = 0;

  /**
   * 播放页收起动画风格（AppSettings.closeAnimStyle 的运行时镜像，
   * EntryAbility 启动首发 / 设置页切换重发）：closePlayer 据此分流 ——
   *   · morph / morph_swipe：柔退收起（内容反向错峰淡出 + 背景末端渐隐 + 封面回飞）；
   *   · slide：下滑收起（所有入口整页加速下滑淡出）。
   * morph_swipe 的手势部分在 PlayerPage（跟手位移/回弹本地自理，松手过阈值经
   * STORE_PLAYER_SLIDE_CLOSE_REQUEST 请求本页统一收起）。
   */
  @StorageProp(STORE_PLAYER_CLOSE_ANIM) closeAnimStyle: string = '';
  /** 整页下滑收起终态动画位移（vp）：slideOutClose 的 animateTo 闭包内一次写入终值 */
  @StorageProp(STORE_PLAYER_SLIDE_OFFSET) slideOffset: number = 0;
  /** 手势下拉松手过阈值的收起请求（PlayerPage seq 递增写入，@Watch 消费 → slideOutClose） */
  @StorageProp(STORE_PLAYER_SLIDE_CLOSE_REQUEST) @Watch('onSlideCloseRequest') slideCloseRequest: number = 0;
  /**
   * 手势拖拽/回弹进行中（PlayerPage 手势生命周期写入）：closePlayer 的下滑分流
   * 兜底 —— 回弹动画（AppStorage 终值已瞬写归 0/1）进行中的 250ms 窗口内，
   * STORE_PLAYER_SLIDE_OFFSET 兜不住「页面视觉仍位移非 0」，靠本标志强制走下滑
   * 收起（此时 morph 配对目标框按中途值计算必漂移）。
   */
  @StorageProp(STORE_PLAYER_DRAG_ACTIVE) dragActive: boolean = false;
  /** 窗口内容区高度（vp）：EntryAbility 首帧前首发，bindAvoidArea 的
     * windowSizeChange 监听持续回写（applyWindowSize。⚠️ HdsTabs.onAreaChange
     * 转屏后不触发，回写链路必须走窗口级监听）；下滑收起
     * 终点距离 + 播放页横屏分支判定共用 */
  @StorageLink(STORE_WINDOW_HEIGHT_VP) windowHeightVp: number = 0;

  /**
   * 二级页在顶标志（NavStackHolder willShow/didShow 双写）：
   * push 出的 NavDestination 盖住整个壳（含 HDS 悬浮胶囊），
   * 二级页底部播放栏由根 Stack 全局单实例 SubPagePlayBar 接管 —— 本标志 + 队列
   * 非空时挂载；同时 barFloatingStyle 摘除 miniBar（key 变化受控重建）——
   * 全窗口同一时刻只有一套 GEOMETRY_ID_PLAYER_DISC /
   * _SURFACE 锚点（geometryTransition id 全窗口必须唯一，双锚点会互相配对错乱），
   * 摘除与挂载在同一次重渲染内完成。二级页互推（如歌单详情 → UP 主页）标志
   * 恒 true，栏全程在场不闪。
   */
  @StorageProp(STORE_SUB_PAGE_ACTIVE) subPageActive: boolean = false;

  /**
   * 收起播放页：按 STORE_PLAYER_CLOSE_ANIM 分流。
   *
   * ── 下滑分支（slide 风格全部入口 / 页面已被手势拖离原位）→ slideOutClose ──
   * 整页 350ms 加速下滑 + 渐隐，放弃封面 morph 飞行；松手位移 >1vp 时一律走本分支
   * （位移非 0 时 geometryTransition 配对目标框按中途值计算，morph 必漂移）。
   *
   * ── 柔退分支（morph / morph_swipe 的按键与返回收起）两段式 ──
   * ① STORE_PLAYER_CONTENT_EXIT 递增在主动画闭包【外】执行 —— 四个内容层组件
   *   与本页自持内容 @Watch 消费时 seq 不在任何主动画作用域内，各层自建
   *   animateTo 做**反向错峰柔退**（LAYER_EXIT_*，顶栏先、控制区/歌词后，
   *   各 200ms EaseIn）。
   * ② 唯一的主动画（PLAYER_TRANSITION_MS=700ms / PLAYER_MAIN_CURVE）闭包内只写
   *   STORE_PLAYER_OPEN=false —— 同帧驱动：
   *   · 背景面 geometryTransition 收回迷你栏透明锚点矩形，离场透明度由
   *     PlayerInfoComponent 背景面的非对称 transition 接管：PLAYER_BG_EXIT_CURVE
   *     前 ~65% 恒持 1、末端渐隐到 0；
   *   · CoverDisc 内容 if 消失 ↔ PlayBar 迷你唱片 if 出现 → 封面回飞归位；
   *   · 页签图标 opacity 恢复。
   * 动画完成（onFinish）后卸载 overlay 并复位连点防护标志。
   */
  private closePlayer(): void {
    if (!this.playerOpen) {
      return;
    }
    // 上滑展开进行中（slide 风格打开，350ms 窗口）吞掉收起请求：反向打断需处理
    // 「上滑 animateTo 被新动画取代后 onFinish 是否回调」的框架不确定性 —— 若被
    // 早回调会在滑出中途把 GT_OFF 复位，引发迷你唱片斜飞竞态；窗口极短，吞请求
    // 是最稳解（morph 风格的打开中断照旧可反向收起，不受影响）。
    if ((AppStorage.get<boolean>(STORE_PLAYER_TRANSITIONING) ?? false)
      && (AppStorage.get<boolean>(STORE_PLAYER_SLIDE_IN) ?? false)) {
      return;
    }
    if (this.closeAnimStyle === PLAYER_CLOSE_STYLE_SLIDE || this.slideOffset > 1 || this.dragActive) {
      this.slideOutClose();
      return;
    }
    AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, true);
    // ① 内容层柔退信号：seq 递增在主动画闭包外（各层 @Watch 内自建退场 animateTo）。
    const exitSeq: number = (AppStorage.get<number>(STORE_PLAYER_CONTENT_EXIT) ?? 0) + 1;
    AppStorage.setOrCreate(STORE_PLAYER_CONTENT_EXIT, exitSeq);
    // ② 主动画直起（同 tick 起飞）。
    this.startCloseFlight();
  }

  /**
   * 收起主动画：唯一 animateTo（700ms / PLAYER_MAIN_CURVE）闭包内只写
   * STORE_PLAYER_OPEN=false —— 背景面收回 + 封面回飞 + 页签恢复同帧驱动。
   * 卸载挂 onFinish（与打开侧 playEnterTransition 同款）：渲染动画从下一帧
   * 起算、掉帧时被拉长，按墙钟 setTimeout(700ms) 触发会在动画完成前销毁
   * 飞行节点（大封面在 overlay 内），封面末端闪跳落位；onFinish = 渲染动画
   * 真实完成时刻，掉帧不再提前切断飞行。中断安全：收起期间 TRANSITIONING
   * 阻断 openPlayer、打开中被收起打断时收起动画自身的 onFinish 兜底复位。
   */
  private startCloseFlight(): void {
    this.getUIContext().animateTo(
      {
        duration: PLAYER_TRANSITION_MS,
        curve: PLAYER_MAIN_CURVE,
        onFinish: (): void => {
          AppStorage.setOrCreate(STORE_PLAYER_OVERLAY_MOUNTED, false);
          AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, false);
        }
      },
      (): void => {
        AppStorage.setOrCreate(STORE_PLAYER_OPEN, false);
      }
    );
  }

  /**
   * 下滑收起原语（slide 风格全部入口 + 手势过阈值释放共用）：
   * 整页 350ms 加速下滑（PLAYER_SLIDE_CURVE，重力感）+ 渐隐，onFinish 卸载。
   *
   * ① 先摘 geometryTransition（STORE_PLAYER_GT_OFF=true）：必须**渲染一帧**后再
   *   翻转 STORE_PLAYER_OPEN —— 否则被移除/出现的配对节点仍带着旧 id，迷你唱片
   *   会从半滑出的封面位置反向配对飞行（斜飞回栏）。setTimeout(32) ≈ 2 帧，
   *   保证摘除先于状态翻转渲染；期间 TRANSITIONING 已置位，阻断 openPlayer。
   * ② animateTo 闭包一次写入各 AppStorage 终值（渲染层对 PlayerPage 根节点的
   *   translate/opacity 逐帧插值，无逐帧写 AppStorage）：
   *   · STORE_PLAYER_OPEN=false —— 迷你唱片 / 页签图标在滑动页下方复原
   *     （GT 已摘除，无配对飞行）；
   *   · STORE_PLAYER_SLIDE_OFFSET=窗口高 / STORE_PLAYER_SLIDE_ALPHA=0 —— 整页
   *     下滑渐隐；背景面靠 STORE_PLAYER_SLIDE_OUT 守卫保持挂载。
   * ③ onFinish 复位全部标志与终态值（SLIDE_OFFSET/ALPHA 回 0/1，下次打开干净）。
   */
  private slideOutClose(): void {
    // 幂等双闸：未展开不收；GT 已摘除说明一次下滑收起已在途（拖拽中按键收起与
    // 松手 seq 请求可能几乎同时到达），二次进入会重复排程 animateTo 打架。
    if (!this.playerOpen) {
      return;
    }
    if (AppStorage.get<boolean>(STORE_PLAYER_GT_OFF) === true) {
      return;
    }
    AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, true);
    AppStorage.setOrCreate(STORE_PLAYER_GT_OFF, true);
    AppStorage.setOrCreate(STORE_PLAYER_SLIDE_OUT, true);
    setTimeout((): void => {
      // 竞态兜底：32ms 间隙内窗口被卸载等极端情况，animateTo 仍安全（闭包只写
      // AppStorage），onFinish 的复位幂等。
      this.getUIContext().animateTo(
        {
          duration: SLIDE_CLOSE_MS,
          curve: PLAYER_SLIDE_CURVE,
          onFinish: (): void => {
            AppStorage.setOrCreate(STORE_PLAYER_OVERLAY_MOUNTED, false);
            AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, false);
            AppStorage.setOrCreate(STORE_PLAYER_GT_OFF, false);
            AppStorage.setOrCreate(STORE_PLAYER_SLIDE_OUT, false);
            AppStorage.setOrCreate(STORE_PLAYER_DRAG_ACTIVE, false);
            AppStorage.setOrCreate(STORE_PLAYER_SLIDE_OFFSET, 0);
            AppStorage.setOrCreate(STORE_PLAYER_SLIDE_ALPHA, 1);
          }
        },
        (): void => {
          AppStorage.setOrCreate(STORE_PLAYER_OPEN, false);
          AppStorage.setOrCreate(STORE_PLAYER_SLIDE_OFFSET, this.windowHeightVp);
          AppStorage.setOrCreate(STORE_PLAYER_SLIDE_ALPHA, 0);
        }
      );
    }, 32);
  }

  /** TopArea 收起按钮的跨层信号（seq 递增） */
  private onCloseRequest(): void {
    this.closePlayer();
  }

  /** 桌面卡片拉起播放页的跨层信号（seq 递增） */
  private onCardOpenPlayerSeq(): void {
    this.consumeCardOpenSeq();
  }

  /**
   * 消费卡片拉起 seq：@Watch（组件先挂、want 后解析）与 aboutToAppear 补刀
   * （want 先解析、组件后挂）双时序覆盖；seq 无变化（0 或已消费）直接返回。
   */
  private consumeCardOpenSeq(): void {
    if (this.cardOpenPlayerSeq <= 0 || this.cardOpenPlayerSeq === this.lastCardOpenSeq) {
      return;
    }
    this.lastCardOpenSeq = this.cardOpenPlayerSeq;
    this.openPlayerFromCard();
  }

  /**
   * 桌面卡片点按 → 展开全屏播放页（复刻 PlayBar.openPlayer 同款链路：
   * TRANSITIONING 连点防护 + slide 风格起始态预置（预置必须先于 overlay 挂载，
   * 否则以「整页在原位」多渲染一帧）+ 挂载 overlay）。
   */
  private openPlayerFromCard(): void {
    if (this.playerOpen) {
      return;
    }
    if (AppStorage.get<boolean>(STORE_PLAYER_TRANSITIONING) ?? false) {
      console.info('[Index] openPlayerFromCard ignored: transition in progress');
      return;
    }
    AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, true);
    const closeStyle: string = AppStorage.get<string>(STORE_PLAYER_CLOSE_ANIM) ?? '';
    if (closeStyle === PLAYER_CLOSE_STYLE_SLIDE) {
      const h: number = AppStorage.get<number>(STORE_WINDOW_HEIGHT_VP) ?? 0;
      if (h > 0) {
        AppStorage.setOrCreate(STORE_PLAYER_SLIDE_OFFSET, h);
        AppStorage.setOrCreate(STORE_PLAYER_SLIDE_ALPHA, 0);
        AppStorage.setOrCreate(STORE_PLAYER_GT_OFF, true);
        AppStorage.setOrCreate(STORE_PLAYER_SLIDE_IN, true);
      }
    }
    AppStorage.setOrCreate(STORE_PLAYER_OVERLAY_MOUNTED, true);
  }

  /** PlayerPage 手势下拉松手过阈值的跨层信号（seq 递增 → 统一下滑收起） */
  private onSlideCloseRequest(): void {
    this.slideOutClose();
  }

  /**
   * 跨层切页签请求（seq 递增，STORE_TAB_SWITCH_TARGET 携带目标下标）：
   * 播放页 overlay 深层组件（「去歌单页选」菜单项）发出。
   *
   * 手机壳：HdsTabs 是非受控 index（见 onChange 注释），外部写 activeTab 不会
   * 切换可见页签 —— 必须走 tabController.changeIndex，由 HDS 内部状态切页，
   * onChange 再回写 activeTab（驱动标题 / 下载页门控 / 顶栏 stackBuilder）。
   */
  @StorageProp(STORE_TAB_SWITCH_REQUEST) @Watch('onTabSwitchRequest') tabSwitchRequest: number = 0;

  /** 消费跨层切页签请求：HdsTabs 非受控 index，唯一有效通道是 changeIndex（见上方注释） */
  private onTabSwitchRequest(): void {
    const target: number = AppStorage.get<number>(STORE_TAB_SWITCH_TARGET) ?? -1;
    if (target < 0) {
      return;
    }
    this.tabController.changeIndex(target);
  }

  /**
   * 当前页签下标。HdsTabs 用**非受控 index**（受控 index 会致「切页签迷你栏闪烁/
   * 唱片重置」）：切页签由 HDS 内部状态驱动，onChange 只负责回写本字段，
   * 驱动页签标题 / 下载页优化 / 冷启动恢复，**不再回灌进 HdsTabs 属性**。
   *
   * @StorageLink 写穿 AppStorage（STORE_ACTIVE_TAB），下载页据此在非活动页签时
   * 跳过下载快照的全量重算（TabContent 常驻，不看这个的话切走页签后重算照跑，
   * 拖慢全局）。onChange 的回写语句无需任何改动。
   */
  @StorageLink(STORE_ACTIVE_TAB) activeTab: number = 0;

  /**
   * 一次性启动提示消费：MSG + SEQ 双键。
   * @Watch(SEQ) 覆盖「组件先挂、迁移链后写」；aboutToAppear 末尾补播覆盖
   * 「MSG 先写、组件后挂」—— initRest 与 loadContent 并行，两种时序都真实存在。
   * @StorageProp 初值同步不触发 @Watch，故补播必须显式调一次。
   */
  @StorageProp(STORE_STARTUP_HINT_SEQ) @Watch('onStartupHint') startupHintSeq: number = 0;

  /** 消费即清 MSG：只弹一次，防下次启动 / 本页重建时重播 */
  private onStartupHint(): void {
    const msg: string = AppStorage.get<string>(STORE_STARTUP_HINT_MSG) ?? '';
    if (msg.length > 0) {
      showAppToast(msg, 3500);
      AppStorage.setOrCreate(STORE_STARTUP_HINT_MSG, '');
    }
  }

  /**
   * 点击切页的内容动画时长（ms），喂给 HdsTabs.animationDuration
   * （修「远距切页过快」）：HDS 定长 300ms，跨多页时速度翻倍。tabItem
   * onTouch(DOWN) 时按 |目标 - activeTab| 预置缩放时长 —— 按下与点击识别
   * 之间至少隔一帧（人手按压普遍 50ms+），重渲染必然先于 HDS 起播生效。
   * 相邻 = BASE(300) 与默认一致；滑动翻页不受影响（见常量注释）。
   */
  @State tabSwitchDuration: number = TAB_SWITCH_BASE_MS;

  /**
   * 歌单页多选态镜像：驱动根栏 stackBuilder 第二行（PlSelectToolbar）的
   * 条件渲染。写入口在 PlaylistsPage.syncBarState，本组件只读。
   */
  @StorageProp(STORE_PL_BAR_SELECTING) plSelecting: boolean = false;

  /**
   * 下载页多选态镜像（留白整改）：常规态标题行右侧多一组队列控制
   * （DlQueueActions），多选态行 2 渲染多选工具条（DlControlBar）。
   * 写入口在 DownloadsPage，本组件只读。
   */
  @StorageProp(STORE_DL_BAR_SELECTING) dlSelecting: boolean = false;

  /**
   * 下载页顶栏镜像：有无任务 —— 决定标题行「选择」按钮显隐
   * 与 bottomBuilder 工具条的门控。写入口在 DownloadsPage.syncBarState，
   * 本组件只读（@StorageProp 单向）。
   */
  @StorageProp(STORE_DL_BAR_HAS_TASKS) dlBarHasTasks: boolean = false;

  /**
   * 首页搜索入口按钮激活镜像：首页列表停在顶部（搜索框可见）时为 true，
   * 搜索框随内容滚出后为 false —— 标题行右上按钮随之淡入/淡出。
   * 写入口在 HomePage.syncEntryActive，本组件只读（@StorageProp 单向）。
   */
  @StorageProp(STORE_HOME_SEARCH_ENTRY_ACTIVE) homeEntryActive: boolean = true;

  /**
   * 首页 chip 条在场镜像：列表偏移 < HOME_TABS_FLIP_VP（分类 chip 条顶缘
    * 尚未触及导航栏底）时 true；chip 条上移到导航栏后 false —— 三个分类
    * tab 图标（homeTitleRow 内、问候语右侧）淡入，标题与问候语常驻不变。
   * 写入口在 HomePage.syncChipsActive，本组件只读（@StorageProp 单向）。
   */
  @StorageProp(STORE_HOME_CHIPS_ACTIVE) homeChipsActive: boolean = true;

  /**
   * 首页分类 tab（推荐 / 排行榜 / 音乐中心）：chip 条（HomeCategoryChips）
   * 与导航栏三个 tab 图标共享的双向状态（@StorageLink 写穿 —— 图标点击
   * 切 tab 与 chip 点击完全等价，HomePage @Watch 切内容分支）。
   */
  @StorageLink(STORE_SEARCH_TAB) homeTab: string = 'recommend';

  /**
   * 路由栈注入：@Consume('navPathStack') 的子组件可拿到与两壳
   * HdsNavigation 同一份栈实例；当前子页面经 NavStackHolder 静态单例访问
   * （等价同一份），此 @Provide 为标准注入通道预留，避免子组件再依赖
   * service 层单例。
   */
  @Provide('navPathStack') navPathStack: NavPathStack = NavStackHolder.stack;

  private tabController: HdsTabsController = new HdsTabsController();

  /** 本次屏幕滑动是否已消费（一次手势只触发一次收/放） */
  private screenPanConsumed: boolean = false;

  /**
   * 设备是否支持 HDS 的 IMMERSIVE 材质类型。
   *
   * ⚠️ 官方要求：未查询设备材质能力就直接选 EXQUISITE 精美档，在不支持的设备上会卡顿发热。
   * 所以先探测，不支持就用 ADAPTIVE 交给系统自适应。
   * 取值只在 aboutToAppear 里算一次（构造期调系统能力有失败风险），之后不变，
   * 因此用普通成员而非 @State —— 它不参与刷新（render 时读到的一定是探测后的值）。
   */
  private useExquisiteMaterial: boolean = false;

  /** 主窗口句柄，只用于注销 avoidAreaChange 监听 */
  private mainWindow: window.Window | null = null;

  /**
   * 断点监听（sm/md/lg → AppStorage）：**全局唯一**的注册点。
   *
   * 本页是常驻根页面，注册一次全程有效，折叠屏开合 / 平板旋转时所有页面都能跟着变。
   */
  private breakpointSystem: BreakpointSystem = new BreakpointSystem();

  /** 网络监听注销器：aboutToAppear 注册、aboutToDisappear 成对注销（防回调泄漏） */
  private unregisterNetWatch: (() => void) | null = null;
  /**
   * 断网提示是否已弹过。netLost 事件可能连发（Wi-Fi/蜂窝交替），
   * 全局 Toast 只弹一次；netAvailable 恢复时复位。也用它区分
   * 「真恢复」与「注册瞬间的 available」——只有断过才发重试信号。
   */
  private netLostToastShown: boolean = false;

  aboutToAppear(): void {
    // 路由拦截器（登录拦截基础设施 + 同名 push 防抖）：两壳共享同一栈，
    // 只挂一次；先于任何子页 push 挂载，冷启动即生效。
    NavStackHolder.setupInterception();
    // 桌面卡片拉起播放页补刀：卡片 router 冷启动时 want 解析（onCreate）先于
    // 本页挂载，@StorageProp 初值同步不触发 @Watch —— 显式同步当前 seq 再比对消费。
    // @StorageProp 从 AppStorage 的同步可能晚于 aboutToAppear，直接读存储更稳。
    this.cardOpenPlayerSeq = AppStorage.get<number>(STORE_CARD_OPEN_PLAYER_SEQ) ?? 0;
    this.consumeCardOpenSeq();
    // 先探测材质能力：barFloatingStyle() 在首帧 build 时就要用到它
    this.useExquisiteMaterial = MaterialCompat.supportsImmersiveMaterial();
    // 断点要先于子页注册：register 会同步把当前断点写进 AppStorage，
    // 各 Tab 页 aboutToAppear 时的 @StorageProp 初始值就是正确断点，首帧不跳变。
    this.breakpointSystem.register(this.getUIContext());
    this.bindAvoidArea();
    // 全局网络监听：断网 Toast + 恢复重试信号都由根页统一收口（页面级不重复注册）
    this.unregisterNetWatch = watchNetwork({
      onLost: (): void => {
        if (this.netLostToastShown) {
          return;
        }
        this.netLostToastShown = true;
        showAppToast('网络连接已断开，请检查网络设置', 2000);
      },
      onAvailable: (): void => {
        if (!this.netLostToastShown) {
          return;
        }
        this.netLostToastShown = false;
        // 网络恢复重试信号：读-改-写递增（与 Toast seq 同一套写法），搜索页订阅后
        // 在失败/空态下自动重试一次
        const rev: number | undefined = AppStorage.get<number>(STORE_NET_RETRY_REV);
        AppStorage.setOrCreate(STORE_NET_RETRY_REV, (rev ?? 0) + 1);
      }
    });
    // miniBar 初始态：手机（sm，宽度 <600vp）默认折叠；折叠屏展开 / 平板（≥600vp）
    // 时 miniBarStyle 不受控、HDS 固定展开（见 currentBreakpoint 注释），全局状态必须
    // 跟着置 true，PlayBar 才会渲染展开态内容。这里不读 this.currentBreakpoint ——
    // @StorageProp 从 AppStorage 的同步可能晚于 aboutToAppear，直接读存储更稳。
    const initBp: string | undefined = AppStorage.get<string>(BreakpointConstants.CURRENT_BREAKPOINT);
    AppStorage.setOrCreate(STORE_MINI_BAR_EXPANDED,
      initBp !== undefined && initBp !== BreakpointConstants.BREAKPOINT_SM);
    setTimeout((): void => {
      if (!this.miniBarApplied) {
        this.miniBarApplied = true;
        // 补初始样式（部分版本上 miniBarStyle 初始值不生效，
        // 100ms 由控制器按实际态补一次）：仅手机宽度补折叠
        //（≥600vp 时 applyMiniBarStyle 无效——HDS 固定展开，全局状态也在上面置过 true 了）。
        if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_SM) {
          this.tabController.applyMiniBarStyle(HdsBarStyle.COLLAPSE);
        }
        // 非受控 index（见 activeTab 注释）的代价 = 冷启动不再自动落回上次页签，
        // 这里一次性恢复（activeTab 未持久化时恒为 0，守卫跳过；持久化过则恢复）。
        if (this.activeTab !== 0) {
          this.tabController.changeIndex(this.activeTab);
        }
      }
    }, 100);
    // 首帧后 1.5s 低优先级预热懒加载子页面
    //（播放页 / 歌单详情优先，其余串行），正常跳转时模块早已就绪、无感知。
    setTimeout((): void => {
      preloadAllLazyPages();
    }, 1500);
    // 一次性启动提示补播：MSG 已写而本组件后挂的场景；
    // @StorageProp 初值同步不触发 @Watch，见 startupHintSeq 注释
    this.onStartupHint();
  }

  /**
   * 断点切换（折叠屏开合 / 进出平板）：重新对齐 miniBar 的「可控态」与全局展开态。
   *
   * ≥600vp 时 HDS 强制展开、手动控制失效（见 currentBreakpoint 注释），因此：
   *   · 进入宽屏 → 全局展开态同步为 true（PlayBar 渲染展开态内容）；
   *   · 回到手机宽度 → 恢复手动控制，把记录的手动态重放一遍。
   * 冷启动阶段（miniBarApplied 尚未置位）只同步状态、不碰控制器 —— 那时 HdsTabs
   * 还没挂载，applyMiniBarStyle 可能抛异常；初始样式由 barFloatingStyle 提供。
   * 宽屏路径只同步全局展开态（PlayBar 非 SM 下 bodyVisible
   * 恒 true，不依赖 miniBar 槽位语义）。
   */
  private onBreakpointChanged(): void {
    // 诊断日志（折叠屏「点 miniBar 不跳转」排查）：断点切换与状态对齐的完整现场
    console.info(`[Index] breakpoint -> ${this.currentBreakpoint}, miniBarExpanded=${this.miniBarExpandedNow()}, applied=${this.miniBarApplied}`);
    if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_SM) {
      if (this.miniBarApplied) {
        this.tabController.applyMiniBarStyle(
          this.miniBarExpandedNow() ? HdsBarStyle.EXPAND : HdsBarStyle.COLLAPSE);
      }
      return;
    }
    AppStorage.setOrCreate(STORE_MINI_BAR_EXPANDED, true);
  }

  aboutToDisappear(): void {
    // 首页是常驻根页面，正常不会被销毁；这里注销只是规范做法，避免长期持有窗口对象。
    this.breakpointSystem.unregister();
    this.unbindAvoidArea();
    // 网络监听与注册成对：漏注销会让 NetConnection 持有本页回调，页面销毁后仍被系统触发
    if (this.unregisterNetWatch !== null) {
      this.unregisterNetWatch();
      this.unregisterNetWatch = null;
    }
  }

  /**
   * 系统返回拦截：播放页 overlay 开启时返回 = 收起播放页（逆向镜像），
   * 不走路由栈（播放页不是 NavDestination）。
   * 收起进行中（mounted 但未 open）也吞掉返回 —— closePlayer 内部幂等。
   */
  onBackPress(): boolean {
    if (this.playerOpen || this.playerOverlayMounted) {
      this.closePlayer();
      return true;
    }
    return false;
  }

  /**
   * 取主窗口 → 主动读一次避让区 → 注册 avoidAreaChange。
   *
   * 窗口全屏后避让全靠自己算，而横竖屏切换、三键 / 手势导航切换都会改变避让区高度，
   * 必须监听变化动态更新，否则旋转后底栏会一直沿用旧高度（留白过多或控件被压住）。
   */
  private bindAvoidArea(): void {
    try {
      const ctx: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(ctx)
        .then((win: window.Window): void => {
          this.mainWindow = win;
          // 不依赖 EntryAbility 那次同步读写是否读早了，这里再校准一次
          this.applyAvoidArea(win);
          this.applyWindowSize(win);
          win.on('avoidAreaChange', (data: window.AvoidAreaOptions): void => {
            console.info(`avoidAreaChange: type=${data.type}`);
            this.applyAvoidArea(win);
          });
          // 窗口尺寸变化（转屏 / 折叠开合 / 分屏）→ 回写宽高。
          // ⚠️ HdsTabs.onAreaChange 在转屏后**不会**回调，窗口宽高
          // （STORE_WINDOW_WIDTH_VP / _HEIGHT_VP）旋转后会陈旧，
          // 播放页紧凑横屏分支因此永不命中。窗口级 windowSizeChange 与
          // avoidAreaChange 同管线（后者旋转后实测有回调），才是可靠写点。
          win.on('windowSizeChange', (): void => {
            this.applyWindowSize(win);
          });
        })
        .catch((err: BusinessError): void => {
          console.error(`getLastWindow failed: ${err.code} ${err.message}`);
        });
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`bindAvoidArea failed: ${msg}`);
    }
  }

  private unbindAvoidArea(): void {
    const win: window.Window | null = this.mainWindow;
    if (win === null) {
      return;
    }
    try {
      win.off('avoidAreaChange');
      win.off('windowSizeChange');
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`unbindAvoidArea failed: ${msg}`);
    }
    this.mainWindow = null;
  }

  /**
   * 读窗口 windowRect → px 转 vp → 回写 AppStorage 宽高
   * （STORE_WINDOW_WIDTH_VP / STORE_WINDOW_HEIGHT_VP，@StorageLink 直写）。
   *
   * 写点：bindAvoidArea 挂接时校准一次 + windowSizeChange 持续回写
   * （EntryAbility 启动首发兜底冷启动首帧）。取**整窗 rect**而非任何组件
   * area：下滑收起终点 / 播放页横屏分支阈值都按整窗语义消费。
   */
  private applyWindowSize(win: window.Window): void {
    try {
      const ui: UIContext = this.getUIContext();
      const rect: window.Rect = win.getWindowProperties().windowRect;
      const wVp: number = ui.px2vp(rect.width);
      const hVp: number = ui.px2vp(rect.height);
      if (wVp > 0) {
        this.windowWidthVp = wVp;
      }
      if (hVp > 0) {
        this.windowHeightVp = hVp;
      }
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`applyWindowSize failed: ${msg}`);
    }
  }

  /**
   * 读窗口避让区 → px 转 vp → 写 AppStorage。
   *
   * 底部取 TYPE_NAVIGATION_INDICATOR 与 TYPE_SYSTEM 的**较大值**：
   *   手势导航 → 高度在 NAVIGATION_INDICATOR（底部导航指示条）
   *   三键导航 → 高度在 SYSTEM（导航栏）
   * 只读其中一个的话，在另一种导航模式下会拿到 0，底栏就会压到手势条 / 导航栏上。
   *
   * px → vp 用 `UIContext.px2vp()`（页面里拿得到 UIContext，
   * 而 EntryAbility 在非 UI 上下文里只能用 display.densityPixels 手算）。
   */
  private applyAvoidArea(win: window.Window): void {
    try {
      const ui: UIContext = this.getUIContext();
      const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicator: window.AvoidArea =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const topVp: number = ui.px2vp(sys.topRect.height);
      // 两个来源分开发布：悬浮胶囊的避让策略按「来源」选，
      // 不用 max 后的单一值 + 高度阈值猜模式。
      const navBarBottomVp: number = ui.px2vp(sys.bottomRect.height);
      const indicatorBottomVp: number = ui.px2vp(indicator.bottomRect.height);
      const bottomVp: number = Math.max(navBarBottomVp, indicatorBottomVp);
      // 水平安全区：横屏下状态栏侧边条带避让，
      // 与 EntryAbility.writeSafeArea 同口径；竖屏两值通常为 0，纯增量发布。
      const leftVp: number = ui.px2vp(sys.leftRect.width);
      const rightVp: number = ui.px2vp(sys.rightRect.width);
      AppStorage.setOrCreate(STORE_SAFE_TOP, topVp);
      AppStorage.setOrCreate(STORE_SAFE_BOTTOM, bottomVp);
      AppStorage.setOrCreate(STORE_NAV_BAR_BOTTOM, navBarBottomVp);
      AppStorage.setOrCreate(STORE_NAV_INDICATOR_BOTTOM, indicatorBottomVp);
      AppStorage.setOrCreate(STORE_SAFE_LEFT, leftVp);
      AppStorage.setOrCreate(STORE_SAFE_RIGHT, rightVp);
      console.info(`avoidArea: top=${topVp}vp bottom=${bottomVp}vp navBar=${navBarBottomVp}vp indicator=${indicatorBottomVp}vp left=${leftVp}vp right=${rightVp}vp`);
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`applyAvoidArea failed: ${msg}`);
    }
  }

  /**
   * 沉浸光感悬浮胶囊样式（参数逐条移植自 Sumy-Music 的 getBarFloatingStyle）。
   *
   * 三项合起来才是「沉浸光感」：
   *   systemMaterialEffect → 系统**沉浸式材质**（IMMERSIVE）；设备支持时用 EXQUISITE 精美档
   *   lightColor           → **主题色光晕**：品牌粉 12% 透明度，让材质泛一层粉光而不是死灰
    *   barOpacity           → 不设（系统默认 1，不透明，
    *                           由 IMMERSIVE 材质自身呈现光感，不靠透出下层内容）
   *   barBottomMargin      → **悬浮**：净离底 6vp；再按导航方式叠加底部安全区（见文件头说明）
    *   barSideMargin        → **水平锚定**：HDS 底左锚定，队列空大屏时反算居中、
    *                           队列非空 lg 对称内收 83vp（见 barFloatingStyle 内注释）
   *
   * 融合播放栏（miniBar）：队列非空时挂入 —— PlayBar 作为槽位内容与页签排进同一行
   * （HORIZONTAL：播放栏左、页签右），材质背景跟随页签胶囊（enableMiniBarBackground
   * 默认 true），液态玻璃观感由 HDS 统一渲染；队列为空时不带 miniBar，播放栏整体隐藏。
   *
    * ⚠️ navBarBottom / navIndicatorBottom / queue 变化会让本函数返回新对象，HdsTabs 是受控样式，重建即生效。
   */
  /**
   * barFloatingStyle 的**内容键缓存**。
   *
   * HdsTabs 的 barFloatingStyle 参数按对象**引用**判等 —— 每次重渲染
   * 都返回新对象的话，HdsTabs 受控重建，连带销毁重建 miniBar 槽位里的 PlayBar
   * （收放过渡全部丢失，见 miniBarExpandedNow 注释）。
   * barFloatingStyle 的语义输入其实只有六个：安全区 / 材质档 / 主题色 / 布局 /
   * 是否带 miniBar（队列空否）/ 展开态 —— 拼成内容键，键不变就返回**同一个缓存对象**：
   *   · 收放（展开态翻转但 Index 不重渲染）/ 页签切换（activeTab 翻转触发重渲染，
   *     但六个输入没变）→ 同一对象 → HdsTabs 不重建，PlayBar 存活，过渡动画完整；
   *   · 安全区 / 材质档 / 主题色 / 布局 / 队列空实 / 展开态真正变化 → 新键新对象 →
   *     受控重建照旧生效（「重建即生效」机制不回退）。
   */
  private cachedFloatingStyle: HdsTabsFloatingStyle | null = null;
  private cachedFloatingStyleKey: string = '';

  private barFloatingStyle(): HdsTabsFloatingStyle {
    // 内容键：本样式的全部语义输入（见 cachedFloatingStyle 注释）。
    // 展开态用非响应式读（miniBarExpandedNow）—— 收放翻转本身不触发本页重渲染。
    const expandedNow: boolean = this.miniBarExpandedNow();
    // 悬浮栏水平锚定（dumpLayout 实测定论）：HDS 悬浮页签栏是**底左锚定** ——
    // barSideMargin 只是胶囊左缘缩进，不是两侧对称边距；带 miniBar 时 HDS
    // 自动两胶囊对称散开（整体居中），队列空时单胶囊贴左、大屏右侧空出几百 vp
    // → 视觉不居中。故：
    //   · 队列空 且 容器宽 ≥600vp → sideMargin=(宽−胶囊宽)/2 反算居中，并用
    //     barWidth 锁死胶囊宽（显设边距时 HDS 默认宽度会漂移：实测 S=83→304 /
    //     S=318→272，不锁宽度则公式里的「宽」不可控）；
    //   · 队列非空 且 lg（阔折叠展开）→ 保留用户调校的对称内收 83vp（不锁宽，
    //     维持用户按 304 口径调出的双胶囊散开视觉）；
    //   · 其余（手机 / sm 折叠闭合）→ 全不设，HDS sm 默认即居中（实测佐证）。
    const emptyQueue: boolean = this.queue.length === 0;
    const centerSingleBar: boolean = emptyQueue && this.windowWidthVp >= 600;
    let sideMargin: number | undefined = undefined;
    if (centerSingleBar) {
      sideMargin = Math.max(0, (this.windowWidthVp - BAR_FLOATING_BAR_WIDTH) / 2);
    } else if (!emptyQueue && this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG) {
      sideMargin = BAR_SIDE_MARGIN_LG;
    }
    const key: string = `${this.navBarBottom}|${this.navIndicatorBottom}`
      + `|${this.useExquisiteMaterial ? 1 : 0}`
      + `|${this.themePrimary}|${this.barLayout}|${this.queue.length > 0 ? 1 : 0}`
      + `|${expandedNow ? 1 : 0}|${sideMargin ?? 0}`
      + `|${this.subPageActive ? 1 : 0}`;
    if (this.cachedFloatingStyle !== null && this.cachedFloatingStyleKey === key) {
      return this.cachedFloatingStyle;
    }
    const style: HdsTabsFloatingStyle = {
      // 胶囊完整浮在系统底部控件上方、与屏幕底缘留出明显空隙（对齐华为音乐观感）。
      // ⚠️ 避让策略按「避让区来源」选，不写死高度阈值（高度阈值在阔折叠 /
      // 阔直板大屏展开态会误判 → 胶囊垂直偏移）：
      //   三键导航（TYPE_SYSTEM 底部矩形 > 0）→ 整条导航栏是可点击系统控件，
      //     完整避让：barBottomMargin = 6 + navBarBottom；
      //   手势导航（TYPE_NAVIGATION_INDICATOR 底部矩形）→ 同样完整避让指示条
      //     避让区（胶囊底缘离屏 ≈ 6 + 27.85 ≈ 34vp，对齐华为音乐悬浮观感）。
      // 两种导航方式语义统一：完整避开系统控件 + 净空隙 6vp。
      // 两个高度都来自 getWindowAvoidArea + avoidAreaChange 动态实测（px2vp 换算），
      // 转屏 / 折叠开合 / 切导航模式 / 分屏自动跟随（键变化 → 样式受控重建生效）。
      // ⚠️ 双重避让坑：本工程窗口是全屏布局（HdsTabs 底边 = 物理屏幕底边），
      // 这里必须自带避让；若真机出现「离底留白翻倍」说明 HDS 内部又避了一次，
      // 把净距改成 BAR_BOTTOM_MARGIN 即可 —— 切不可在根容器再叠 padding.bottom。
      barBottomMargin: BAR_BOTTOM_MARGIN + (this.navBarBottom > 0
        ? this.navBarBottom
        : this.navIndicatorBottom),
      // 水平锚定（见上面 sideMargin 计算处注释）：队列空大屏反算居中（配 barWidth
      // 锁宽）/ 队列非空 lg 对称内收 83vp / 其余 undefined 走 HDS 分档默认
      barSideMargin: sideMargin,
      // 居中分支锁死胶囊宽度（md/lg 两档同值，覆盖 ≥600vp 全部 HDS 分档）；
      // 其余分支不设（undefined），维持 HDS 默认宽度。
      barWidth: centerSingleBar
        ? {
          mediumWidth: BAR_FLOATING_BAR_WIDTH,
          largeWidth: BAR_FLOATING_BAR_WIDTH
        }
        : undefined,
      systemMaterialEffect: {
        // 材质类型/档位抽入 MaterialTokens 令牌，
        // 与 SubPagePlayBar / HdsTitleBarStyle 同源。
        materialType: MaterialTokens.BAR_MATERIAL_TYPE,
        materialLevel: MaterialTokens.materialLevel()
      },
      lightColor: MaterialCompat.withAlpha(this.themePrimary, GLOW_ALPHA)
    };
    // 互斥：二级页在顶时摘除 miniBar（反正被 push 出的 NavDestination 盖住），
    // 由根 Stack 的 SubPagePlayBar 接管二级页播放栏 —— 全窗口同一时刻只有一套
    // GEOMETRY_ID_PLAYER_DISC / _SURFACE 锚点（geometryTransition id 全窗口
    // 必须唯一）。返回首页 subPageActive 翻 false → key 变化 → 新样式对象 →
    // HdsTabs 受控重建，miniBar 随胶囊恢复。
    if (this.queue.length > 0 && !this.subPageActive) {
      const mini: HdsTabsMiniBar = {
        miniBarBuilder: (): void => {
          this.PlayBarHost();
        },
        // 显式写 true：关成 false 的话 miniBar 段失去材质背景（IMMERSIVE 材质
        // 与 lightColor 光晕均不渲染）。防 SDK 默认值变更或被误关。
        enableMiniBarBackground: true,
        // ⚠️ 受控样式必须跟随手动态，绝不能写死 EXPAND：HdsTabs 受控重建时
        // 重放本配置 —— 写死 EXPAND 等于每次重建都强制展开。
        // 配合内容键缓存：只有展开态真正变化才产生新配置对象触发重建，
        // 平时的收放翻转由 HDS 内部（applyMiniBarStyle / 用户点击）完成，不经配置。
        miniBarStyle: expandedNow ? HdsBarStyle.EXPAND : HdsBarStyle.COLLAPSE,
        // 一左一右 / 上下两层：由设置页「底部导航布局」决定（STORE_BAR_LAYOUT 镜像）。
        // ⚠️ HdsBarLayoutMode 6.1.1(24) 才有：API 23 设备上该导出为 undefined，
        // typeof 守卫后跳过赋值，HdsTabs 按默认布局排（播放栏在页签上方）。
        barLayoutMode: typeof HdsBarLayoutMode !== 'undefined'
          ? (this.barLayout === BAR_LAYOUT_VERTICAL ? HdsBarLayoutMode.VERTICAL : HdsBarLayoutMode.HORIZONTAL)
          : undefined,
        /**
         * 槽位几何动画相位：
         * HDS 对 miniBar 槽位宽高做形变动画期间，PlayBar 的整行内容保持挂载
         * （enableMiniBarClip 裁出自然的收放揭示），动画结束才切回收起圆盘；
         * 垂直两层的圆盘尺寸（28↔40）也按此相位与槽位同步过渡。
         * onBarStyleChange 相对动画起止的时序不确定（可能先于动画翻转），
         * 因此相位由这一对**动画边界回调**单独发布，不依赖样式回调的顺序。
         */
        onMiniBarAnimationStart: (style: HdsBarStyle, _width: number): void => {
          console.info(`[Index] miniBar anim start -> ${style}`);
          // ⚠️ 映射取反（真机日志实锤）：d.ets 里 style 语义是
          // "current style"——**动画开始那一刻的旧样式**：展开动画报 COLLAPSE(0)、
          // 收起动画报 EXPAND(1)。
          // 报 COLLAPSE = 正在展开；报 EXPAND = 正在收起。
          AppStorage.setOrCreate(STORE_MINI_BAR_ANIM_PHASE,
            style === HdsBarStyle.COLLAPSE ? MINI_BAR_ANIM_TO_EXPAND : MINI_BAR_ANIM_TO_COLLAPSE);
        },
        onMiniBarAnimationEnd: (_style: HdsBarStyle): void => {
          console.info('[Index] miniBar anim end');
          AppStorage.setOrCreate(STORE_MINI_BAR_ANIM_PHASE, MINI_BAR_ANIM_IDLE);
        },
        onBarStyleChange: (miniBarStyle: HdsBarStyle, tabBarStyle: HdsBarStyle,
          miniBarWidth: number, tabBarWidth: number, mode: HdsTabsBarChangeMode): void => {
          // 实测回传：HDS 上报的 miniBar 槽位宽发布到全局存储，
          // SubPagePlayBar 直接采用 —— HDS 默认宽不可从源码推导（编译产物 +
          // previewer mock），本回调的 miniBarWidth 实参是真机唯一可靠口径。
          // 真机实测（Mate 80 Pro Max，sm）：收起态上报 miniW=328 与展开态同值
          // （= tabW 全宽胶囊标准宽，非圆盘视觉宽）—— 槽位宽是常量、与展开/收
          // 态无关，两种状态均发布；仅过滤无效值（0 / 负）。
          if (miniBarWidth > 0) {
            AppStorage.setOrCreate(STORE_MAIN_MINI_BAR_WIDTH, miniBarWidth);
          }
          // 诊断日志（折叠屏「点 miniBar 不跳转」排查）：HDS 上报的样式 / 触发模式 / 宽度
          console.info(`[Index] onBarStyleChange: mini=${miniBarStyle}, tab=${tabBarStyle}, mode=${mode}, miniW=${miniBarWidth}, tabW=${tabBarWidth}, bp=${this.currentBreakpoint}`);
          const current: HdsBarStyle = this.miniBarExpandedNow() ? HdsBarStyle.EXPAND : HdsBarStyle.COLLAPSE;
          // 拦截 NORMAL 只在手机宽度（<600vp）下做：宽屏上 miniBarStyle 不受控，
          // NORMAL 上报的正是 HDS 强制的展开态 —— 必须放行并同步全局状态，
          // 否则状态停在「折叠」而胶囊是展开布局，内容与槽位错位（折叠屏旧 bug）。
          if (mode === HdsTabsBarChangeMode.NORMAL && miniBarStyle !== current
            && this.currentBreakpoint === BreakpointConstants.BREAKPOINT_SM) {
            // NORMAL = 系统自动重排（路由压栈引发的宽度重算 / 转屏 / 折叠开合）。
            // 策略：展开/收起只认 USER_CLICK（点收起圆盘/页签条）与 APP_TRIGGER
            // （控制器 applyMiniBarStyle），系统自动变更一律弹回当前手动态。
            this.tabController.applyMiniBarStyle(current);
            return;
          }
          // miniBarBuilder 内容会被 HDS 缓存，展开/收起态必须走全局存储驱动切换
          AppStorage.setOrCreate(STORE_MINI_BAR_EXPANDED, miniBarStyle === HdsBarStyle.EXPAND);
        }
      };
      style.miniBar = mini;
    }
    // 内容键缓存落位（键不变时后续重渲染直接复用本对象，见 cachedFloatingStyle 注释）
    this.cachedFloatingStyle = style;
    this.cachedFloatingStyleKey = key;
    return style;
  }

  /**
   * 屏幕竖向滑动方向判定（parallelGesture 超阈值后调用，一次手势至多一次）：
   * 上滑（offsetY 负）→ 展开；下滑（offsetY 正）→ 收起。
   * 队列空（无 miniBar 槽位）/ 宽屏（非 SM，HDS 强制展开不受控）→ 忽略；
   * 已在目标态为无操作。收放走 applyMiniBarStyle 既有相位链，动画零新增。
   */
  private onScreenPanDirection(up: boolean): void {
    // 设置「自动展开收起」关闭：全屏滑动手势不触发收放（显式交互不受影响）
    if (!this.miniBarAutoExpand) {
      return;
    }
    if (this.queue.length === 0) {
      return;
    }
    if (this.currentBreakpoint !== BreakpointConstants.BREAKPOINT_SM) {
      return;
    }
    if (up) {
      if (!this.miniBarExpandedNow()) {
        console.info(`[Index] screen pan up -> expand: bp=${this.currentBreakpoint}`);
        this.tabController.applyMiniBarStyle(HdsBarStyle.EXPAND);
      }
    } else {
      if (this.miniBarExpandedNow()) {
        console.info(`[Index] screen pan down -> collapse: bp=${this.currentBreakpoint}`);
        this.tabController.applyMiniBarStyle(HdsBarStyle.COLLAPSE);
      }
    }
  }

  /**
   * 融合播放栏槽位内容（宿主侧薄封装）。
   * 独立组件直接订阅 AppStorage，切歌 / 播放态实时刷新，不受 HDS builder 缓存影响。
   */
  @Builder
  PlayBarHost(): void {
    PlayBar({
      onExpandRequest: (): void => {
        // 收起态点封面：重新展开融合播放栏（Sumy 同款交互，不直接进播放页）
        this.tabController.applyMiniBarStyle(HdsBarStyle.EXPAND);
      }
    })
  }

  /**
   * 页签内容：SymbolGlyph 图标 + 文字，选中态品牌粉、未选中次要色。
   *
   * ⚠️ 参数**只传静态字面量**（下标 / 文案 / 图标资源），选中的判断在 Builder 内部现算。
   * 带参 @Builder 是**值传递**，把状态变量当参数传进来时，状态变化不会刷新其内部 UI
   * （典型症状：同一行里一半控件正常、一半失灵）。
   */
  @Builder
  tabItem(index: number, label: string, icon: Resource) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([this.activeTab === index ? this.themePrimary : $r('sys.color.font_secondary')])
      Text(label)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.activeTab === index ? this.themePrimary : $r('sys.color.font_secondary'))
    }
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .height('100%')
     // 播放页展开时页签图标淡出：与容器向四周扩大
     // 同一条 700ms animateTo（playerOpen 在打开/收起主动画闭包内翻转）——
    // HdsTabs 底座不销毁，只是图标逐步衰减。
    .opacity(this.playerOpen ? 0 : 1)
     // 按下即预置切页动画时长（修「远距切页过快」）：DOWN 发生在
    // 点击识别前一帧以上，重渲染先把缩放后的 animationDuration 落到 HdsTabs，
    // HDS 处理点击起播时读到的就是新值。index 是字面量参数，闭包捕获安全。
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.presetTabSwitchDuration(index);
      }
    })
  }

  /**
   * 按点击目标预置切页动画时长：跨度 ≤1 → BASE(300，与默认一致)；
   * 跨度 n → BASE + (n-1)*STEP，封顶 MAX。点当前页签（跨度 0）不切页，
   * 预置 BASE 只是保持基线。快速连点时 activeTab 尚未回写（onChange 在
   * 动画完成后才触发），距离按旧起点算，误差最多一档时长，可接受。
   */
  private presetTabSwitchDuration(target: number): void {
    const distance: number = Math.abs(target - this.activeTab);
    if (distance <= 1) {
      this.tabSwitchDuration = TAB_SWITCH_BASE_MS;
      return;
    }
    this.tabSwitchDuration = Math.min(
      TAB_SWITCH_BASE_MS + (distance - 1) * TAB_SWITCH_STEP_MS,
      TAB_SWITCH_MAX_MS);
  }

  @Builder
  pageMap(name: string, param: Object): void {
    // 11 个子页面统一经 LazyDest 按路由名动态 import 渲染
    //（注册表见 service/LazyPageRegistry；预热后基本无加载等待）。
    LazyDest({ name: name })
  }

  /**
   * 根标题栏样式：统一委托 HdsTitleBarStyle.styleOptions。
   *
     * 顶部导航栏滚动联动渐进模糊：滚动效果类型经 MaterialTokens 令牌
     * （IMMERSIVE_GRADIENT_BLUR 沉浸渐变）+ 起止偏移 0→20vp 线性过渡
     * （走助手默认值），搭配 IMMERSIVE 材质光感（与底部胶囊同源）；
     * 滚动偏移由 HdsNavigation bindToScrollable 绑定链自动监听驱动，
     * 无需手动监听滚动事件。两档决策与简史见 HdsTitleBarStyle 类头。
    */
  private titleBarStyle(): TitleBarStyleOptions {
    // 根栏关 HDS 滚动效果（第三参 false），让位自绘渐变模糊层
    // （TopGradientBlurOverlay），防双重模糊。
    // 自绘层覆盖全部四个页签（搜索 / 歌单 / 下载 / 设置，
    // 各页自挂 overlay + onDidScroll 驱动）；
    // 九个子页仍走 styleOptions() 默认参不动。
    return HdsTitleBarStyle.styleOptions(undefined, undefined, false);
  }

  /**
   * 当前页签的列表 scroller（单绑）。
   *
   * ⚠️ 「四 scroller 多绑」配合「页面 new 后替换 holder 字段」会导致
   * bindToScrollable 求值时拿到未挂载的占位实例——首开顶栏滚动模糊整段失效，
   * 要等 Index 因其它状态变化重渲染才「偶尔恢复」。TabScrollerHolder 静态
   * 字段是唯一真源（四页 List 直挂，身份恒定），本方法按 activeTab 取当前页签的
   * 稳定实例单绑（FAQ faqs-arkui-1095 / Spatialization 参考工程 MainPage 同款）；
   * activeTab 是 @State，切页签触发重渲染 → 属性重设 → 自动换绑新页签的 scroller。
   * 本绑定驱动顶栏滚动渐进模糊。
   */
  private activeTabScroller(): Scroller {
    if (this.activeTab === TAB_SEARCH) {
      return TabScrollerHolder.home;
    }
    if (this.activeTab === TAB_PLAYLISTS) {
      return TabScrollerHolder.playlists;
    }
    if (this.activeTab === TAB_DOWNLOADS) {
      return TabScrollerHolder.downloads;
    }
    return TabScrollerHolder.settings;
  }

  /**
   * 标题行（歌单 / 下载 / 设置三页签共用，行 1）：
   * 视觉与各页原自绘栏逐字一致（20fp Bold + padding left 20/right 16、
   * 行高 NAV_TITLE_BAR_HEIGHT）。下载页右侧「选择 / 完成」（DlSelectToggle）、
   * 歌单页右侧按钮组（PlTitleActions），均读页内状态镜像 + 经持有器回调页面。
   */
  @Builder
  tabTitleRow() {
    Row() {
      Text(this.tabTitleText())
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.activeTab === TAB_DOWNLOADS && this.dlBarHasTasks) {
        DlSelectToggle()
        if (!this.dlSelecting) {
          DlQueueActions()
        }
      }
      if (this.activeTab === TAB_PLAYLISTS) {
        PlTitleActions()
      }
    }
    .width('100%')
    .height(NAV_TITLE_BAR_HEIGHT)
    // 水平基线统一 NAV_H_PADDING(16)：标题行 / 搜索行 / 页签行 / 列表内容共用
    // 同一条左缘（各处左缘不一致的话滚动时竖线互相错位）。
    .padding({ left: NAV_H_PADDING, right: NAV_H_PADDING })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 时间段问候语：首页标题「BiliMusic」后缀，按当前小时分段 ——
   * 早上 [5,11) / 中午 [11,13) / 下午 [13,17) / 晚上 [17,23) /
   * 深夜 [23,24)∪[0,1) / 凌晨 [1,5)。构建时求值：标题行随 homeChipsActive /
   * 切页等状态变化重渲染时刷新，应用长时间停留跨段的边界误差由下一次重渲染自愈。
   */
  private timeGreeting(): string {
    const h: number = new Date().getHours();
    if (h >= 5 && h < 11) {
      return '早上好~';
    }
    if (h >= 11 && h < 13) {
      return '中午好~';
    }
    if (h >= 13 && h < 17) {
      return '下午好~';
    }
    if (h >= 17 && h < 23) {
      return '晚上好~';
    }
    if (h >= 23 || h < 1) {
      return '深夜好~';
    }
    return '凌晨好~';
  }

  /**
   * 首页标题行（TAB_SEARCH，MusicHome HomeTopBar 落地）：
   * 「BiliMusic」标题 + 时间段问候语 + 右上搜索按钮。列表停在顶部时入口式
   * 搜索框可见，按钮隐藏（opacity 0 + 不响应点击）；搜索框随内容滚出后
   * 按钮 200ms 淡入。
   * chip 条上移到导航栏（homeChipsActive 翻转）时标题与问候语常驻显示；
   * 三个分类 tab 图标在问候语右侧 200ms 淡入。图标点击写 homeTab
   * （STORE_SEARCH_TAB 写穿），与 chip 点击切 tab 完全等价。
   */
  @Builder
  homeTitleRow() {
    Row() {
      // 标题 + 时间段问候语：常驻显示
      //（上滑出头部后不随图标淡出）；问候语 flexShrink 兜底窄屏截断，标题保完整。
      Row({ space: 6 }) {
        Text('BiliMusic')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
        Text(this.timeGreeting())
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .flexShrink(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(VerticalAlign.Center)
      Row({ space: 4 }) {
        ForEach(
          HOME_CATEGORY_CHIPS,
          (item: CategoryChipUi): void => {
            this.HomeNavTabIcon(item)
          },
          (item: CategoryChipUi): string => `nav_${item.key}`
        )
      }
      .margin({ left: 8 })
      .opacity(this.homeChipsActive ? 0 : 1)
      .hitTestBehavior(this.homeChipsActive ? HitTestMode.None : HitTestMode.Default)
      .animation({ duration: 200, curve: Curve.EaseOut })
      Blank()
      Button() {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(20)
          .fontColor([$r('app.color.text_primary')])
      }
      .type(ButtonType.Circle)
      .width(40)
      .height(40)
      .backgroundColor(Color.Transparent)
      .opacity(this.homeEntryActive ? 0 : 1)
      .hitTestBehavior(this.homeEntryActive ? HitTestMode.None : HitTestMode.Default)
      .animation({ duration: 200, curve: Curve.EaseOut })
      .onClick((): void => {
        NavStackHolder.push('Search', undefined);
      })
    }
    .width('100%')
    .height(NAV_TITLE_BAR_HEIGHT)
    .padding({ left: NAV_H_PADDING, right: NAV_H_PADDING })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 导航栏单个分类 tab 图标按钮（homeTitleRow 三图标之一）：
   * 与右上搜索按钮同几何语言（40×40 圆按钮 + 20 号 SymbolGlyph），
   * 图标复用 chip 条同款（HOME_CATEGORY_CHIPS 单一来源）；
   * 选中态主题粉、未选中次级文字色，点击写 homeTab 切 tab。
   */
  @Builder
  private HomeNavTabIcon(item: CategoryChipUi) {
    Button() {
      SymbolGlyph(item.icon)
        .fontSize(20)
        .fontColor([this.homeTab === item.key ? this.themePrimary : $r('app.color.text_secondary')])
    }
    .type(ButtonType.Circle)
    .width(40)
    .height(40)
    .backgroundColor(Color.Transparent)
    .onClick((): void => {
      this.homeTab = item.key;
    })
  }

  /**
   * 根栏 stackBuilder 全量内容：
   * 首页 = homeTitleRow（「BiliMusic」+ 右上搜索按钮）；其余页签 = 标题行 /
   * 多选工具条（position(y = NAV_TITLE_BAR_HEIGHT) 溢出渲染到标题栏下方）。
   * ⚠️ stackBuilder 容器原点在状态栏下方（avoidLayoutSafeArea），行 2 的
   * 容器内 y=56 = 屏幕绝对 safeTop + 56 —— 与各页 contentStartOffset 让位公式
   * 逐像素一致（换容器不换几何）。
   * 外层 Stack：clip(false) 让行 2 画出容器边界；hitTestBehavior(Transparent)
   * 让行 2 未覆盖的空白区点击穿透到下方列表。
   */
  @Builder
  immersiveTitleBarContent() {
    if (this.activeTab === TAB_SEARCH) {
      Stack() {
        this.homeTitleRow()
      }
      .width('100%')
      .height('100%')
      .clip(false)
      .hitTestBehavior(HitTestMode.Transparent)
    } else if (this.activeTab === TAB_PLAYLISTS) {
      Stack() {
        this.tabTitleRow()
        if (this.plSelecting) {
          PlSelectToolbar()
            .position({ x: 0, y: NAV_TITLE_BAR_HEIGHT })
        }
      }
      .width('100%')
      .height('100%')
      .clip(false)
      .hitTestBehavior(HitTestMode.Transparent)
    } else if (this.activeTab === TAB_DOWNLOADS) {
      Stack() {
        this.tabTitleRow()
        if (this.dlBarHasTasks && this.dlSelecting) {
          DlControlBar()
            .position({ x: 0, y: NAV_TITLE_BAR_HEIGHT })
        }
      }
      .width('100%')
      .height('100%')
      .clip(false)
      .hitTestBehavior(HitTestMode.Transparent)
    } else {
      Stack() {
        this.tabTitleRow()
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }

  /**
   * 顶栏内容收窄包装：根标题栏横跨整个内容列，而页面内容列实际被
   * contentMaxWidth 约束（Stack 默认居中）—— 顶栏拉满整列会导致搜索框/标题行
   * 与下方内容错位。外层 Row 居中 + 内层 Column constraintSize(contentMaxWidth)，
   * 让顶栏内容与内容列同宽对齐；两侧空白区 hitTestBehavior(Transparent)
   * 穿透点击到下方页面（与内层 Stack 同款行为）。
   * md（phoneShell）顶栏也经本包装（contentMaxWidth(md)=600 与内容列对齐）；
   * 仅 sm 直用 immersiveTitleBarContent（shell 的 stackBuilder 内按断点分流，
   * sm 行为零变化）。
   * 上限走 TwoColumnLayout.contentMaxWidth —— 与各页内容列完全同口径
   * （两列激活 840 / 否则 600/720），平板横屏顶栏与条目列对齐。
   * sm 回退 600（窗口 <600vp，天然无操作）零变化。
   */
  @Builder
  immersiveTitleBarNarrow() {
    Row() {
      Column() {
        this.immersiveTitleBarContent()
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
   * 当前页签的标题文案（歌单 / 下载 / 设置；搜索页签行 1 是搜索行，不取文案）。
   */
  private tabTitleText(): string {
    if (this.activeTab === TAB_DOWNLOADS) {
      return '下载';
    }
    if (this.activeTab === TAB_PLAYLISTS) {
      return '歌单';
    }
    return '设置';
  }

  build() {
    Stack() {
      // 壳形态：sm/md/lg 全形态统一 phoneShell（HdsTabs 沉浸光感浮动底栏）。
      // AppToast / AppDialogHost 全局宿主挂壳外。
      this.phoneShell()

      // 二级页沉浸光感悬浮播放栏（全部推送子页）：二级页在顶且队列
      // 非空时挂载，盖在壳之上、播放页 overlay 之下（overlay 打开时被其盖住）；
      // 同帧互斥摘除 miniBar（见 subPageActive 注释）。栏外空白
      // 区点击穿透（组件外层 Transparent），列表照常可点可滚。
      if (this.queue.length > 0 && this.subPageActive) {
        SubPagePlayBar()
      }

      // 播放页 overlay：PlayBar.openPlayer 挂载、closePlayer 收起动画结束后
      // 卸载。盖住整个壳（胶囊页签在其下，图标已随 playerOpen 淡出），
      // 复用 LazyDest 懒加载注册 + 1.5s 预热（首开即就绪）。
      if (this.playerOverlayMounted) {
        LazyDest({ name: 'Player' })
          .width('100%')
          .height('100%')
      }

      // 全局轻提示宿主：驱动系统标准 toast（openToast / closeToast）
      //（单实例 + 「替换不排队」语义，见 components/AppToast.ets）
      AppToast()

      // 全局弹窗宿主：本身不渲染任何内容，只承载两个 CustomDialogController
      //（controller 必须在 @Component 内定义才有效，见 components/AppAlertDialog.ets）
      AppDialogHost()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    // ⚠️ 根容器**不加** padding-bottom。加了会把 Tabs 内容区整体截短 safeBottom，
    // 首页（搜索页）的列表就铺不到屏幕最底 —— 与「布局区域延伸到底部手势条下方」矛盾。
    // 底部避让改由悬浮页签栏（barBottomMargin）、迷你条（padding-bottom）、
    // NavDestination 子页（safeAreaPadding）各自承担，互不重叠。
  }

  /**
   * 沉浸光感胶囊壳（sm/md/lg 全形态，唯一壳）：
   * HdsTabs 沉浸光感悬浮胶囊底栏 + miniBar 融合播放栏 —— 与 MusicHome 平板
   * 横屏底部导航栏同形态（HdsTabs 浮动底栏 + 系统材质 + miniBar 融合），
   * 本壳为加强实现（IMMERSIVE 材质 + 主题色光晕，见 MaterialTokens）。
   * ≥600vp HDS 强制 miniBar 展开态（全局展开态已在 aboutToAppear /
   * onBreakpointChanged 同步 true），材质 / 主题光晕 / 微透明照常。
   * 非 sm 顶栏走 immersiveTitleBarNarrow 收窄（见本壳 titleBar 注释）。
   */
  @Builder
  phoneShell(): void {
    Column() {
        // 根容器 Navigation → HdsNavigation（同签名平替），
        // 由根 HdsNavigation 统一渲染顶栏。
        HdsNavigation(NavStackHolder.stack) {
          HdsTabs({ controller: this.tabController }) {
            TabContent() {
              HomePage()
            }.tabBar(this.tabItem(0, '首页', $r('sys.symbol.house')))

            TabContent() {
              PlaylistsPage()
            }.tabBar(this.tabItem(1, '歌单', $r('sys.symbol.list_bullet')))

            TabContent() {
              DownloadsPage()
            }.tabBar(this.tabItem(2, '下载', $r('sys.symbol.circle_and_arrow_down')))

            TabContent() {
              SettingsPage()
            }.tabBar(this.tabItem(3, '设置', $r('sys.symbol.gearshape')))
          }
          .vertical(false)
          .barPosition(BarPosition.End)
          .barMode(BarMode.Fixed)
          // 切页动画时长按跨度缩放（修「远距切页过快」）：值由
          // tabItem onTouch(DOWN) 预置（见 tabSwitchDuration 注释），相邻 300ms
          // 与默认一致，远距 420/540ms 封顶；仅管点击切页，滑动翻页走弹簧曲线。
          .animationDuration(this.tabSwitchDuration)
          // 内容延伸到页签栏下方：列表滚动时从悬浮胶囊的材质下透出
          .barOverlap(true)
          // 非受控 index（受控 index 会致「切页签迷你栏闪烁/唱片重置」）：
          // 受控 index（index: this.activeTab）→ 每次切页签 onChange 回写
          // activeTab → Index 重渲染 → HdsTabs 收到新 index 属性 → HDS 重排
          // 整条悬浮栏（含 miniBar 槽位）→ PlayBar 销毁重建（唱片 animator
          // 重建回正 + 胶囊闪动；barFloatingStyle 内容键缓存只挡住了样式对象
          // 重建那条路，挡不住这条）。切页签完全交给 HDS 内部状态，onChange 只
          // 回写 activeTab 驱动页签标题 / 下载页优化，不再回灌属性 → HdsTabs
          // 属性恒定 → 悬浮栏不重排。冷启动恢复上次页签由 aboutToAppear 的
          // 100ms 延迟块一次性 changeIndex()。
          .onChange((index: number): void => {
            this.activeTab = index;
          })
          .barFloatingStyle(this.barFloatingStyle())
          .width('100%')
          .height('100%')
          // 屏幕滑动收/放（全屏手势）：上滑展开、
          // 下滑收起，超过 SCREEN_PAN_TRIGGER_VP 判定一次意图
          // （screenPanConsumed 防连发）。parallelGesture = 与子组件手势**并行
          // 响应**：四个页签页 List 的竖向滚动照常进行，滑动同时触发收放
          // （用户明确选定的取舍——正常浏览列表也会收放，太灵敏调大阈值）。
          // 挂 HdsTabs 而非外层根 Stack：push 出的 NavDestination（播放页等）
          // 不在 HdsTabs 子树内，其滑动手势不会误触迷你栏收放。
          .parallelGesture(PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: SCREEN_PAN_TRIGGER_VP })
            .onActionStart((): void => {
              this.screenPanConsumed = false;
            })
            .onActionUpdate((event: GestureEvent): void => {
              if (this.screenPanConsumed) {
                return;
              }
              if (event.offsetY <= -SCREEN_PAN_TRIGGER_VP) {
                this.screenPanConsumed = true;
                this.onScreenPanDirection(true);
              } else if (event.offsetY >= SCREEN_PAN_TRIGGER_VP) {
                this.screenPanConsumed = true;
                this.onScreenPanDirection(false);
              }
            }))
          // ⚠️ 这里**不再**加 padding({ top: safeTop })：状态栏避让下放到各 Tab 页的
          // 固定栏（材质 Row 内部 padding.top = safeTop），让材质从 y=0 铺起覆盖状态栏。
          // NavDestination 子页不参与 HdsTabs 布局，本来就不受这里的 padding 影响。
        }
        // 根标题栏：stackBuilder 承载整块顶栏内容（行 1 + 行 2
        // 溢出渲染）。
        // avoidLayoutSafeArea 与子页同口径（栏顶 = safeTop，覆盖式渲染）；
        // divider OFF：行 2 自带 0.5vp 底缘线的页面不再由根栏画分割线。
        // 非 sm 顶栏经 immersiveTitleBarNarrow 收窄到与内容列同宽居中；
        // sm 直用 immersiveTitleBarContent，零改动。收窄口径统一为
        // TwoColumnLayout.contentMaxWidth（两列激活 840 / 否则 600/720），
        // 平板竖屏与阔折叠展开横屏的顶栏均与条目列对齐。
        .titleBar({
          avoidLayoutSafeArea: true,
          style: this.titleBarStyle(),
          content: {
            stackBuilder: (): void => {
              // phoneShell 下**非 sm** 一律走收窄顶栏 ——
              // md（折叠展开 / 小平板竖屏）与折叠展开落 lg 宽度（阔折叠大屏）、
              // 平板竖屏落 lg 同待遇，
              // immersiveTitleBarNarrow 的 maxWidth 走 TwoColumnLayout.
              // contentMaxWidth 按断点×横竖屏取值（两列激活 840 / 否则 600/720），
              // 与内容列同宽；sm 直用全宽顶栏，零改动。
              if (this.currentBreakpoint !== BreakpointConstants.BREAKPOINT_SM) {
                this.immersiveTitleBarNarrow();
              } else {
                this.immersiveTitleBarContent();
              }
            },
            divider: {
              showType: DividerShowType.OFF
            }
          }
        })
        // MINI 模式 + 隐藏返回键：根栏常显、无系统返回位（四个页签都是一级页）。
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        .navDestination(this.pageMap)
        .mode(NavigationMode.Stack)
        // 单绑当前页签 scroller（FAQ faqs-arkui-1095 / 参考工程
        // MainPage 同款）：activeTab 变化触发重渲染自动换绑；TabScrollerHolder
        // 静态字段为唯一真源（四页 List 直挂，身份恒定），绑定与挂载先后顺序不再敏感。
        .bindToScrollable([this.activeTabScroller()])
      }
      .width('100%')
      .height('100%')
  }
}
