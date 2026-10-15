/**
 * 应用首页：**HDS 沉浸光感悬浮胶囊**，播放栏（PlayBar）与页签融合在同一个胶囊里。
 *（这是**默认**底栏样式；设置 → 外观 → 底部导航栏 可切「悬浮沉浸」—— 同样是
 * HdsTabs，但走独立悬浮样式：hdsMaterial IMMERSIVE 沉浸材质 + **官方 miniBar**
 * 迷你播放栏（components/ImmersiveMiniBar.ets），见 floatingImmersiveNav 与
 * immersiveFloatingStyle。本文件头其余说明针对融合胶囊形态，
 * 悬浮沉浸的差异点见对应方法处的注释。）
 *
 * 底栏实现移植自 Sumy-Music（`@kit.UIDesignKit` 的 HdsTabs + barFloatingStyle）：
 *   HdsTabs 取代原来的原生 Tabs，页签栏由 HDS 渲染成**离底悬浮的胶囊**，
 *   并施加系统沉浸式材质 + 主题色光晕 + 微透明（参数见 barFloatingStyle）。
 *
 * ══════════ 融合式播放栏（参考 MusicHome / Sumy 的 miniBar 集成方案）══════════
 *   播放栏**不再作为独立层叠加**：旧「Stack 双层（HdsTabs + 播放条 overlay）」
 *   已合并为单层 —— PlayBar 作为 barFloatingStyle.miniBar 的 builder 内容交给
 *   HDS 渲染，全局只在首页配置这一次：
 *     · barLayoutMode: HORIZONTAL → miniBar 与页签项排进**同一行**
 *       （播放栏在左、页签在右，一左一右融合成一个胶囊）；
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
 *   手势导航   barBottomMargin = 6 + safeBottom × 0.5（避开指示条一半，贴近底部边框）
 *   三键导航   barBottomMargin = 6 + safeBottom      （整条导航栏必须完整避让）
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
 *   子页面          safeAreaPadding(bottom = safeBottom)→ 播放页控制栏等自己躲开手势条
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
 * 登录页（'Login' 路由）随扫码登录功能恢复重建（2026-10），入口在设置页「账户」分组。
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
  TitleBarStyleOptions,
  hdsMaterial
} from '@kit.UIDesignKit';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { Track, NavBarStyle } from '../model/MusicModels';
import { SearchPage } from './SearchPage';
import { PlaylistsPage } from './PlaylistsPage';
import { DownloadsPage } from './DownloadsPage';
import { SettingsPage } from './SettingsPage';
import { PlayerPage } from './PlayerPage';
import { PlaylistDetail } from './PlaylistDetail';
import { RecentPage } from './RecentPage';
import { FollowsPage } from './FollowsPage';
import { UpSpacePage } from './UpSpacePage';
import { WatchHistoryPage } from './WatchHistoryPage';
import { AboutPage } from './AboutPage';
import { LoginPage } from './LoginPage';
import { SmsLoginPage } from './SmsLoginPage';
import { NavStackHolder } from '../service/NavStackHolder';
import { PlayBar } from '../components/PlayBar';
import { ImmersiveMiniBar } from '../components/ImmersiveMiniBar';
import { AppToast, showAppToast } from '../components/AppToast';
import { AppDialogHost } from '../components/AppAlertDialog';
import { MaterialCompat } from '../utils/MaterialCompat';
import { watchNetwork } from '../utils/NetworkUtil';
import { BreakpointSystem } from '../common/utils/BreakpointSystem';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import {
  STORE_QUEUE,
  STORE_MINI_BAR_EXPANDED,
  STORE_MINI_BAR_COLLAPSED,
  STORE_MINI_BAR_VISUAL_COLLAPSED,
  STORE_SAFE_TOP,
  STORE_SAFE_BOTTOM,
  STORE_NET_RETRY_REV,
  STORE_ACTIVE_TAB,
  STORE_NAV_BAR_STYLE,
  GESTURE_INDICATOR_MAX_VP,
  floatingBarBottomMargin,
  STORE_DL_BAR_HAS_TASKS,
  STORE_DL_BAR_SELECTING,
  STORE_PL_BAR_SELECTING,
  GLOW_ALPHA,
  BILI_PINK_HEX
} from '../common/Constants';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { DlSelectToggle, DlQueueActions, DlControlBar } from '../components/DownloadsTabBar';
import { PlTitleActions, PlSelectToolbar } from '../components/PlaylistsTabBar';
import { SearchInputBar, SearchTabsBar } from '../components/SearchTabBar';

/**
 * 悬浮页签栏离屏幕底边的净间距（vp，不含安全区）。
 * 旧值 20 让胶囊浮得太高；压到 6 使其贴近屏幕底部边框（少量安全区由下方公式叠加）。
 */
const BAR_BOTTOM_MARGIN: number = 6;
/** 页签栏微透明 —— 移植自 Sumy 的 barOpacity: 0.9 */
const BAR_OPACITY: number = 0.9;

/**
 * 根 HdsNavigation 统一标题栏（HarmonyX 移植，2026-10-10）：
 * 根栏**四页签常显**（titleMode MINI + hideBackButton + divider OFF），
 * stackBuilder 承载整块顶栏内容 —— 行 1（56 标题行 / 搜索行）+ 行 2 溢出渲染
 * （position y=56 + clip(false) + hitTestBehavior Transparent，HarmonyX
 * ImmersiveTitleBarContent 同款手法），bottomBuilder 槽整体退役。
 */
const TAB_SEARCH: number = 0;
const TAB_PLAYLISTS: number = 1;
const TAB_DOWNLOADS: number = 2;
const TAB_SETTINGS: number = 3;
/**
 * 顶栏滚动模糊时机（渐进模糊指南口径 0→20）：根栏常显后起糊即触发，
 * 起点透明 / 终点 bg_page 的样式插值在 20vp 内完成。
 */
const TAB_BLUR_START_VP: number = 0;
const TAB_BLUR_END_VP: number = 20;
/**
 * 兜底档（GRADIENT_BLUR）模糊蒙层额外高度：罩住溢出渲染的第二行
 * （44 工具条 + 余量）。沉浸档（IMMERSIVE_GRADIENT_BLUR）忽略此值。
 */
const FALLBACK_MASK_EXTRA_VP: number = 52;

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
   * 播放队列（歌单列表）：决定融合播放栏是否挂进悬浮胶囊 ——
   * 队列为空时 barFloatingStyle 不带 miniBar，胶囊退回纯页签形态（播放栏隐藏）。
   */
  @StorageLink(STORE_QUEUE) queue: Track[] = [];

  /**
   * miniBar 展开 / 收起态 —— 手动控制的**唯一事实源**（@StorageLink 双向）。
   *
   * ⚠️ 当前 SDK（HDS 6.1.1）没有 barChangeMode() 属性方法；HdsTabsBarChangeMode
   * 只是 onBarStyleChange 回调的上报参数（谁触发了这次变更）。要实现
   * 「展开/折叠只由代码控制 + miniBar 自身点击」，只能：
   *   1. miniBarStyle 受控跟随本状态（不再写死，见 barFloatingStyle）；
   *   2. onBarStyleChange 里拦截 NORMAL（系统自动重排：路由压栈/转屏/折叠开合），
   *      弹回当前手动态；USER_CLICK（点收起圆盘/页签）与 APP_TRIGGER（控制器）放行。
   */
  @StorageLink(STORE_MINI_BAR_EXPANDED) miniBarExpanded: boolean = false;

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
   * miniBar 初始折叠是否已应用过（只补一次的守卫）。
   * 部分版本上 miniBarStyle 初始值不生效，参考 Sumy：挂载后延迟 100ms 由
   * 控制器 applyMiniBarStyle(COLLAPSE) 补一次；用户后续的展开 / 收起不受影响。
   * 同时它也是 onBreakpointChanged 里「控制器是否已可安全调用」的守卫 ——
   * 冷启动在折叠屏展开态时，register 写断点会立刻触发 @Watch，那时 HdsTabs
   * 尚未挂载，不能调 applyMiniBarStyle（只同步全局状态即可）。
   */
  private miniBarApplied: boolean = false;

  /**
   * 悬浮沉浸 miniBar 最近一次已应用的 HdsBarStyle（去重标记）。
   * 滚动吸附 @Watch（onImmersiveMiniSnap）与 onBarStyleChange 回写都可能触发
   * 应用请求，与最近已应用态相同则跳过 —— 防止同值 apply 重播 HDS 过渡动效。
   */
  private lastSnapApplied: HdsBarStyle = HdsBarStyle.EXPAND;

  /**
   * 悬浮沉浸悬浮样式配置缓存（突变修复，2026-10-12）。
   *
   * HdsTabs 受控样式按**对象引用**判断是否重新应用：barFloatingStyle 返回新对象
   * → miniBar 被重建并**瞬间**重置到配置值（无动画；初始值再碰上「部分版本不生效」
   * 就落回默认折叠样式 —— 旧「切页签自动回到页签栏」bug 正是这一机制）。
   * 滚动收起/展开是 applyMiniBarStyle 的**带形变动效**应用，若伴随的收起键翻转
   * 让 Index 重渲染重建配置，HDS 形变会被重建瞬间取消 —— 表现为「没有形变的突变」。
   * 华为音乐等官方样例的架构正是：不设 miniBarStyle，运行时变更只走控制器（动效）
   * 与 USER_CLICK，状态经 onBarStyleChange 从系统回写。
   *
   * 因此：缓存配置对象，key 只含决定配置内容的字段（safeBottom / 材质探测 /
   * 队列非空 / 导航样式）；**收起态不参与 key** —— 翻转时重渲染拿到同一引用，
   * HdsTabs 跳过应用，形变动画完整播放。收起态也不进配置（miniBarStyle 移出：
   * 烘焙值会被 HDS 在 NORMAL 重算时反复重申把收起弹回，2026-10-12 真机日志
   * 实锤），重建后的初始态由重同步定时器按收起键恢复。
   */
   private immersiveStyleCache: HdsTabsFloatingStyle | null = null;
  /** immersiveStyleCache 的缓存 key（组成见其文档注释） */
  private immersiveStyleCacheKey: string = '';
  /** 沉浸样式首次构建是否完成：首次初始态由 aboutToAppear 补射恢复，后续重建走重同步定时器 */
  private immersiveFirstBuild: boolean = false;

  /**
   * 当前页签下标。HdsTabs 用**受控 index**：点选 / 侧滑后由 onChange 回写，
   * 不回写的话下一次重渲染会把页签弹回旧值。
   *
   * 2026-10-08 卡顿优化：@State → @StorageLink 写穿 AppStorage（STORE_ACTIVE_TAB），
   * 下载页据此在非活动页签时跳过下载快照的全量重算（TabContent 常驻，不看这个
   * 的话切走页签后重算照跑，拖慢全局）。onChange 的回写语句无需任何改动。
   */
  @StorageLink(STORE_ACTIVE_TAB) activeTab: number = 0;

  /**
   * 底部导航栏当前样式（STORE_NAV_BAR_STYLE 通道：EntryAbility 启动发布 /
   * 设置页「外观 → 底部导航栏」切换时写入）。只读订阅（@StorageProp），
   * 声明为 string 与 NavBarStyle 枚举字符串值比较，避免 AppStorage 枚举类型
   * 同步隐患。切换时 build 重渲染，HdsNavigation 子内容在两种底栏间整体换树：
   *   融合胶囊（默认）→ HdsTabs + HDS miniBar（PlayBar 融进页签胶囊，现有形态，行为不变）；
   *   悬浮沉浸        → HdsTabs 独立悬浮样式（hdsMaterial IMMERSIVE 沉浸材质 +
   *                      官方 miniBar 迷你播放栏 ImmersiveMiniBar，floatingImmersiveNav）。
   * 两种样式共用 activeTab / 队列 / 播放状态（全在 AppStorage），切换不丢状态。
   */
  @StorageProp(STORE_NAV_BAR_STYLE)
  navBarStyle: string = NavBarStyle.CAPSULE;

  /**
   * 悬浮沉浸底栏官方 miniBar 是否收起（收进页签栏，HdsBarStyle.COLLAPSE）：
   * 四个 Tab 页列表滚动经 MiniBarSnapController 防抖翻转本键（滚动驱动收起/展开），
   * Index @Watch 经 HdsTabsController.applyMiniBarStyle 应用（HDS 内建形变动效）；
   * onBarStyleChange（跳过 APP_TRIGGER 回声，只同步 USER_CLICK/NORMAL）与
   * onMiniBarAnimationEnd（动效终态）回写本键。
   * ⚠️ 本键翻转**不重建**悬浮样式配置（收起态不在 immersiveStyleCache 的 key 里）——
   * 重渲染拿到同一引用，HdsTabs 跳过重新应用，形变动画完整播放，不突变。
   * ⚠️ ImmersiveMiniBar 内容体**不直接消费本键**（2026-10-13 解耦）：跟随请求态切换
   * 会让内容体在 HDS 形变开始前就变紧凑 —— 「先变小、后再收起」两段式动画的根因。
   * 内容体改读视觉态键（STORE_MINI_BAR_VISUAL_COLLAPSED）：由 onMiniBarAnimationStart
   * 与容器动效**同帧**写入（双向）、onMiniBarAnimationEnd 兜底终态。
   * 融合胶囊样式下无消费者（走 STORE_MINI_BAR_EXPANDED），写入无害。
   */
  @StorageProp(STORE_MINI_BAR_COLLAPSED) @Watch('onImmersiveMiniSnap')
  miniBarCollapsed: boolean = false;

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
   * 下载页顶栏镜像（批 4）：有无任务 —— 决定标题行「选择」按钮显隐
   * 与 bottomBuilder 工具条的门控。写入口在 DownloadsPage.syncBarState，
   * 本组件只读（@StorageProp 单向）。
   */
  @StorageProp(STORE_DL_BAR_HAS_TASKS) dlBarHasTasks: boolean = false;

  private tabController: HdsTabsController = new HdsTabsController();

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
   * 早期只有播放页需要断点（组件树来自折叠屏样例），注册在 PlayerPage 里；
   * 现在列表页也要做大屏适配（内容列收窄居中），注册点必须上移到本页 ——
   * 本页是常驻根页面，注册一次全程有效，折叠屏开合 / 平板旋转时所有页面都能跟着变。
   * PlayerPage 里的那份注册已删除（两份注册 = 双份 mediaquery 监听，纯浪费）。
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
    // 悬浮沉浸视觉态初始装配：内容体（ImmersiveMiniBar）首帧必须与逻辑态一致，
    // 否则首帧内容体与 HDS 槽位样式错位。视觉态运行期只由 HDS 动画回调写入
    // （见 immersiveFloatingStyle 的 mini 配置），装配点是唯一例外。
    AppStorage.setOrCreate(STORE_MINI_BAR_VISUAL_COLLAPSED,
      AppStorage.get<boolean>(STORE_MINI_BAR_COLLAPSED) ?? false);
    setTimeout((): void => {
      if (!this.miniBarApplied) {
        this.miniBarApplied = true;
        // 补初始样式（配置已不烘焙 miniBarStyle —— HDS 按「默认折叠样式」创建
        // 迷你栏，挂载后 100ms 经控制器按实际态补一次）：
        //   融合胶囊 → 仅手机宽度补折叠（≥600vp 时 applyMiniBarStyle 无效——HDS 固定
        //             展开，全局状态也在上面置过 true 了）；
        //   悬浮沉浸 → 按滚动吸附键的当前态补（默认 EXPAND），并同步去重标记。
        if (this.navBarStyle === NavBarStyle.CAPSULE) {
          if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_SM) {
            this.tabController.applyMiniBarStyle(HdsBarStyle.COLLAPSE);
          }
        } else {
          const initial: HdsBarStyle = this.miniBarCollapsed ? HdsBarStyle.COLLAPSE : HdsBarStyle.EXPAND;
          this.lastSnapApplied = initial;
          this.tabController.applyMiniBarStyle(initial);
          // 补射是「无动画的初始装配」：内容体视觉态直接对齐逻辑态，不等动画回调。
          AppStorage.setOrCreate(STORE_MINI_BAR_VISUAL_COLLAPSED, this.miniBarCollapsed);
        }
      }
    }, 100);
  }

  /**
   * 断点切换（折叠屏开合 / 进出平板）：重新对齐 miniBar 的「可控态」与全局展开态。
   *
   * ≥600vp 时 HDS 强制展开、手动控制失效（见 currentBreakpoint 注释），因此：
   *   · 进入宽屏 → 全局展开态同步为 true（PlayBar 渲染展开态内容），控制器补一次
   *     EXPAND（宽屏下等效无动效，只为让 onBarStyleChange 的上报与状态一致）；
   *   · 回到手机宽度 → 恢复手动控制，把记录的手动态重放一遍。
   * 冷启动阶段（miniBarApplied 尚未置位）只同步状态、不碰控制器 —— 那时 HdsTabs
   * 还没挂载，applyMiniBarStyle 可能抛异常；初始样式由 barFloatingStyle 提供。
   */
  private onBreakpointChanged(): void {
    // 诊断日志（折叠屏「点 miniBar 不跳转」排查）：断点切换与状态对齐的完整现场
    console.info(`[Index] breakpoint -> ${this.currentBreakpoint}, miniBarExpanded=${this.miniBarExpanded}, applied=${this.miniBarApplied}`);
    // 悬浮沉浸样式：官方 miniBar 恒 EXPAND（≥600vp 本就被 HDS 强制展开），
    // 没有可控态需要对齐，直接返回，不碰控制器。
    if (this.navBarStyle !== NavBarStyle.CAPSULE) {
      return;
    }
    if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_SM) {
      if (this.miniBarApplied) {
        this.tabController.applyMiniBarStyle(
          this.miniBarExpanded ? HdsBarStyle.EXPAND : HdsBarStyle.COLLAPSE);
      }
      return;
    }
    AppStorage.setOrCreate(STORE_MINI_BAR_EXPANDED, true);
    if (this.miniBarApplied) {
      this.tabController.applyMiniBarStyle(HdsBarStyle.EXPAND);
    }
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
          win.on('avoidAreaChange', (data: window.AvoidAreaOptions): void => {
            console.info(`avoidAreaChange: type=${data.type}`);
            this.applyAvoidArea(win);
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
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`unbindAvoidArea failed: ${msg}`);
    }
    this.mainWindow = null;
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
      const bottomPx: number = Math.max(sys.bottomRect.height, indicator.bottomRect.height);
      const bottomVp: number = ui.px2vp(bottomPx);
      AppStorage.setOrCreate(STORE_SAFE_TOP, topVp);
      AppStorage.setOrCreate(STORE_SAFE_BOTTOM, bottomVp);
      console.info(`avoidArea: top=${topVp}vp bottom=${bottomVp}vp`);
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`applyAvoidArea failed: ${msg}`);
    }
  }

  /**
   * 沉浸光感悬浮胶囊样式（参数逐条移植自 Sumy-Music 的 getBarFloatingStyle）。
   *
   * 四项合起来才是「沉浸光感」：
   *   systemMaterialEffect → 系统**沉浸式材质**（IMMERSIVE）；设备支持时用 EXQUISITE 精美档
   *   lightColor           → **主题色光晕**：品牌粉 12% 透明度，让材质泛一层粉光而不是死灰
   *   barOpacity           → **微透明** 0.9，下层的封面 / 列表能透上来一点
   *   barBottomMargin      → **悬浮**：净离底 6vp；再按导航方式叠加底部安全区（见文件头说明）
   *
   * 融合播放栏（miniBar）：队列非空时挂入 —— PlayBar 作为槽位内容与页签排进同一行
   * （HORIZONTAL：播放栏左、页签右），材质背景跟随页签胶囊（enableMiniBarBackground
   * 默认 true），液态玻璃观感由 HDS 统一渲染；队列为空时不带 miniBar，播放栏整体隐藏。
   *
   * ⚠️ safeBottom / queue 变化会让本函数返回新对象，HdsTabs 是受控样式，重建即生效。
   */
  private barFloatingStyle(): HdsTabsFloatingStyle {
    const style: HdsTabsFloatingStyle = {
      // 整体下沉贴近屏幕底部边框，但**不完全压住**系统底部手势条：
      //   手势导航 → 只避开指示条区域的一半（safeBottom/2）：胶囊下沉进避让区的上半段，
      //              可见的手势指示条仍完整露在胶囊下方（实测 27.85vp 避让区 → 离底约 20vp）；
      //   三键导航 → 整条导航栏是可点击系统控件，必须完整避让（barBottomMargin = 6 + safeBottom）。
      // safeBottom 变化（转屏 / 切导航模式）会重建样式，位置自动跟随。
      barBottomMargin: this.safeBottom > GESTURE_INDICATOR_MAX_VP
        ? BAR_BOTTOM_MARGIN + this.safeBottom
        : BAR_BOTTOM_MARGIN + this.safeBottom * 0.5,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: this.useExquisiteMaterial
          ? hdsMaterial.MaterialLevel.EXQUISITE
          : hdsMaterial.MaterialLevel.ADAPTIVE
      },
      lightColor: MaterialCompat.withAlpha(BILI_PINK_HEX, GLOW_ALPHA),
      barOpacity: BAR_OPACITY
    };
    if (this.queue.length > 0) {
      const mini: HdsTabsMiniBar = {
        miniBarBuilder: (): void => {
          this.PlayBarHost();
        },
        // ⚠️ 受控样式必须跟随手动态，绝不能写死 EXPAND：本函数每次 Index 重渲染
        // （路由压栈 / safeBottom / queue 变化）都返回新对象，HdsTabs 受控重建即
        // 重放 miniBarStyle —— 写死 EXPAND 等于每次重渲染都强制展开（旧 bug 根源）。
        miniBarStyle: this.miniBarExpanded ? HdsBarStyle.EXPAND : HdsBarStyle.COLLAPSE,
        // 一左一右：播放栏与页签排进同一行，而非上下两行。
        // ⚠️ HdsBarLayoutMode 6.1.1(24) 才有：API 23 设备上该导出为 undefined，
        // typeof 守卫后跳过赋值，HdsTabs 按默认布局排（播放栏在页签上方）。
        barLayoutMode: typeof HdsBarLayoutMode !== 'undefined' ? HdsBarLayoutMode.HORIZONTAL : undefined,
        onBarStyleChange: (miniBarStyle: HdsBarStyle, tabBarStyle: HdsBarStyle,
          miniBarWidth: number, tabBarWidth: number, mode: HdsTabsBarChangeMode): void => {
          // 诊断日志（折叠屏「点 miniBar 不跳转」排查）：HDS 上报的样式 / 触发模式 / 宽度
          console.info(`[Index] onBarStyleChange: mini=${miniBarStyle}, tab=${tabBarStyle}, mode=${mode}, miniW=${miniBarWidth}, tabW=${tabBarWidth}, bp=${this.currentBreakpoint}`);
          const current: HdsBarStyle = this.miniBarExpanded ? HdsBarStyle.EXPAND : HdsBarStyle.COLLAPSE;
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
    return style;
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
        .fontColor([this.activeTab === index ? $r('app.color.bili_pink') : $r('sys.color.font_secondary')])
      Text(label)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.activeTab === index ? $r('app.color.bili_pink') : $r('sys.color.font_secondary'))
    }
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .height('100%')
  }

  /**
   * 悬浮沉浸样式的 HdsTabs 悬浮样式（NavBarStyle.IMMERSIVE）—— **双层底栏**：
   * miniBar（迷你播放栏）在上、页签栏（TabBar）在下，垂直两行排布
   * （barLayoutMode: VERTICAL），整体一个悬浮样式统一渲染。
   *
   * 与融合胶囊（barFloatingStyle）同思路，按官方锚点只保留核心配置：
   *   barBottomMargin      → 悬浮离底：基准 8 + 按导航方式叠加 safeBottom
   *                           （common/Constants.floatingBarBottomMargin）；
   *   systemMaterialEffect → **沉浸光感**（hdsMaterial IMMERSIVE / ADAPTIVE），
   *                           深浅色与下层内容自适应由系统统一渲染，不自绘背景；
    *   miniBar              → **官方迷你播放栏**（6.1.0(23) 起）：队列非空时挂入 ——
    *                           ImmersiveMiniBar 作为槽位内容（唱片 + 歌名 + 上一首 /
    *                           播放暂停，点击整条进播放页），**VERTICAL 双层布局**
    *                           （迷你栏在上、页签在下）、材质背景跟随页签栏
    *                           （enableMiniBarBackground）；收起/展开由控制器与收起键
    *                           驱动（配置不烘焙 miniBarStyle，见下方 mini 配置）；
    *                           队列为空时不带 miniBar，底栏退回纯页签形态（单层）。
   *
   * ⚠️ 配置对象已缓存（immersiveStyleCache）：key 变化（safeBottom / 材质探测 /
   *    队列非空 / 导航样式）才重建；其余变化（含收起态翻转）返回同一引用，
   *    HdsTabs 不重新应用 —— 控制器驱动的 HDS 形变动效不被重渲染打断（突变修复）。
   */
  private immersiveFloatingStyle(): HdsTabsFloatingStyle {
    // 缓存 key：只含决定配置「内容」的字段 —— 底部离底（safeBottom 决定 margin）、
    // 材质探测档位、队列是否非空（挂不挂 miniBar）、导航样式（切回沉浸样式重挂载
    // HdsTabs 时强制重建，保证按当前收起态烘焙初始样式）。
    // ⚠️ 收起态不参与 key：滚动翻转收起键时若重建配置，HdsTabs 引用变化即重新
    // 应用，HDS 形变动效被重建瞬间取消 —— 突变根因（见 immersiveStyleCache 文档）。
    const key: string = `${this.safeBottom}|${this.useExquisiteMaterial ? 1 : 0}` +
      `|${this.queue.length > 0 ? 1 : 0}|${this.navBarStyle}`;
    if (this.immersiveStyleCache !== null && this.immersiveStyleCacheKey === key) {
      return this.immersiveStyleCache;
    }
    // 诊断（真机排查 VERTICAL 是否生效）：运行时枚举存在性 —— object 即守卫通过、
    // VERTICAL 已下发（真机 API 26 仍单行时据此定位布局根因）。
    console.info(`[Index] immersive style build: HdsBarLayoutMode=${typeof HdsBarLayoutMode}, collapsed=${this.miniBarCollapsed}, first=${this.immersiveFirstBuild}`);
    const style: HdsTabsFloatingStyle = {
      barBottomMargin: floatingBarBottomMargin(this.safeBottom),
      // 页签栏展开宽度（<440vp 档 smallWidth）。官方默认 4 页签 = 80*4+8 = 328vp，
      // 但单行混排组合「迷你栏 56 + 页签栏 328 + 左右边距 16*2」= 416vp 超出 sm 档
      // 屏宽（真机 391vp / 主流 360vp）→ HDS 装不下整单回滚（NORMAL 弹回）。
      // 压到 264vp：56+264+32 = 352 ≤ 360，最窄 sm 机型也稳定可渲染。
      // ⚠️ 限宽只是必要条件（防溢出回滚）：真机日志实锤 264 下收起仍被 NORMAL
      // 弹回 —— 主回滚源是配置烘焙的 miniBarStyle 被重算重申，已随其移出配置
      // 根治（见下方 mini 配置）；VERTICAL 双行下本限宽无害，留作单行混排兜底。
      barWidth: { smallWidth: 264 },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    };
    if (this.queue.length > 0) {
      const mini: HdsTabsMiniBar = {
        miniBarBuilder: (): void => {
          this.ImmersiveMiniBarHost();
        },
        // ⚠️ 不设 miniBarStyle（官方示例同款，2026-10-12 Design B）：配置对象被
        // 缓存后，烘焙进去的 miniBarStyle 会被 HDS 在每次 NORMAL 重算（点页签 /
        // 滚动重排 / 转屏）时重新断言 —— 收起被弹回展开，滚动期间 apply↔回滚
        // ~10Hz 拉锯（真机日志实锤：USER_CLICK mini=0 后 6ms 即 NORMAL mini=1
        // 弹回；限宽 264 装得下仍回滚，证明回滚源是配置重申而非宽度溢出）。
        // 移出后：初始/重建按 HDS 默认折叠样式创建，由补射与重同步定时器按收起键
        // 恢复；运行时收起/展开只走 applyMiniBarStyle（带 HDS 形变动效）。
        // 双层底栏：迷你播放栏在上、页签栏在下（垂直两行）。
        // ⚠️ HdsBarLayoutMode 6.1.1(24) 才有：低版本设备上该导出为 undefined，
        // typeof 守卫后跳过赋值，HdsTabs 按默认布局排（同为迷你栏在上、页签在下）。
        barLayoutMode: typeof HdsBarLayoutMode !== 'undefined' ? HdsBarLayoutMode.VERTICAL : undefined,
        enableMiniBarBackground: true,
        onBarStyleChange: (miniBarStyle: HdsBarStyle, tabBarStyle: HdsBarStyle,
          miniBarWidth: number, tabBarWidth: number, mode: HdsTabsBarChangeMode): void => {
          // 诊断日志（真机排查用）：HDS 上报的样式 / 触发模式
          console.info(`[Index] immersive onBarStyleChange: mini=${miniBarStyle}, tab=${tabBarStyle}, mode=${mode}, miniW=${miniBarWidth}, tabW=${tabBarWidth}, bp=${this.currentBreakpoint}`);
          // ⚠️ APP_TRIGGER：本侧 applyMiniBarStyle 的回声上报（官方文档：APP_TRIGGER =
          // 调用控制器接口触发）。逻辑态（收起键）不回写 —— 样式与本侧调用方刚写入的
          // 键一致，回写是纯冗余。视觉态也不在此切 —— 统一交给 onMiniBarAnimationStart
          // 与容器动效同帧切换（2026-10-13 同帧修复，见该回调注释），任何位置的
          // 提前/滞后切都会把系统「宽度收缩 + 位置移动」一段动效拆成两段式观感。
          if (mode === HdsTabsBarChangeMode.APP_TRIGGER) {
            return;
          }
          // NORMAL 且与收起键不一致：HDS 自主重排把样式重置了（重建重置 / 转屏 /
          // 残留重申）—— 以收起键为准拉回，防止重置污染持久态。去重标记同
          // onImmersiveMiniSnap，避免与重同步定时器重复 apply 重播动效。
          // ⚠️ 视觉态不随这份「即将被拉回的瞬态上报」切换：reapply 的动画回调
          // （onMiniBarAnimationStart/End）会按正确目标驱动内容体，避免一帧错位闪烁。
          if (mode === HdsTabsBarChangeMode.NORMAL) {
            const current: HdsBarStyle = this.miniBarCollapsed ? HdsBarStyle.COLLAPSE : HdsBarStyle.EXPAND;
            if (miniBarStyle !== current) {
              console.info(`[Index] immersive NORMAL mismatch -> reapply ${current}`);
              this.lastSnapApplied = current;
              this.tabController.applyMiniBarStyle(current);
              return;
            }
          }
          // USER_CLICK（点折叠迷你栏/页签栏的内建展开）与一致的 NORMAL：
          // 回写收起键 + 去重标记。视觉态不在此切 —— USER_CLICK 触发的容器动效
          // 同样走 onMiniBarAnimationStart，内容与容器同帧切换，
          // onMiniBarAnimationEnd 兜底终态（避免同一次动效内容先行/滞后错拍）。
          this.lastSnapApplied = miniBarStyle;
          AppStorage.setOrCreate(STORE_MINI_BAR_COLLAPSED, miniBarStyle === HdsBarStyle.COLLAPSE);
        },
        // 迷你栏折叠/展开形变启动回调（含目标样式与最终宽度）—— 内容状态切换的
        // **唯一主动点**（2026-10-13 同帧修复）：本回调在动效开始时触发并携带动效
        // 结束时的迷你栏宽度，在此切换视觉态（双向，不再区分方向延迟），展开/收起
        // 内容体与容器的「宽度收缩 + 位置移动」系统动效同帧启动 —— 恢复 HdsTabs
        // 默认「边收起边移动」一段连续动效。旧版收起方向推迟到 onMiniBarAnimationEnd
        // 才切紧凑体：容器动效全程内容体停在展开态、落定后才换装，等于把系统一段
        // 动效在观感上拆成「先收起、再移动/换内容」两段。
        // 诊断日志带 width（动效结束时的迷你栏宽），真机核对回调时序用。
        onMiniBarAnimationStart: (style: HdsBarStyle, width: number): void => {
          console.info(`[Index] immersive onMiniBarAnimationStart: style=${style}, width=${width}`);
          AppStorage.setOrCreate(STORE_MINI_BAR_VISUAL_COLLAPSED, style === HdsBarStyle.COLLAPSE);
        },
        // 迷你栏折叠/展开形变结束回调：**兜底**同步最终状态（覆盖 Start 回调未触发 /
        // 动效被中断的路径）—— 统一回写收起键 + 去重标记 + 视觉态。
        onMiniBarAnimationEnd: (style: HdsBarStyle): void => {
          console.info(`[Index] immersive onMiniBarAnimationEnd: style=${style}`);
          this.lastSnapApplied = style;
          AppStorage.setOrCreate(STORE_MINI_BAR_COLLAPSED, style === HdsBarStyle.COLLAPSE);
          AppStorage.setOrCreate(STORE_MINI_BAR_VISUAL_COLLAPSED, style === HdsBarStyle.COLLAPSE);
        }
      };
      style.miniBar = mini;
    }
    this.immersiveStyleCache = style;
    this.immersiveStyleCacheKey = key;
    if (!this.immersiveFirstBuild) {
      // 首次构建：初始态由 aboutToAppear 的 100ms 补射恢复，不走定时器。
      this.immersiveFirstBuild = true;
    } else if (this.queue.length > 0) {
      // 重建重同步：配置已不烘焙 miniBarStyle，HDS 重建 miniBar 会按默认折叠
      // 样式重置 —— 100ms 后按收起键恢复实际态（与补射同一套去重标记；
      // onBarStyleChange 的 NORMAL 拦截兜底覆盖不触发回调的重置路径）。
      setTimeout((): void => {
        if (this.navBarStyle !== NavBarStyle.IMMERSIVE) {
          return;
        }
        const target: HdsBarStyle = this.miniBarCollapsed ? HdsBarStyle.COLLAPSE : HdsBarStyle.EXPAND;
        if (target === this.lastSnapApplied) {
          return;
        }
        this.lastSnapApplied = target;
        this.tabController.applyMiniBarStyle(target);
        // 视觉态自愈对齐：重建重置若绕过了全部回调（视觉态漂移），此处随 apply
        // 对齐目标；同值写入是 no-op，动画回调照常接管正常路径。
        AppStorage.setOrCreate(STORE_MINI_BAR_VISUAL_COLLAPSED, target === HdsBarStyle.COLLAPSE);
      }, 100);
    }
    return style;
  }

  /**
   * 滚动吸附翻转（STORE_MINI_BAR_COLLAPSED 变化）：悬浮沉浸样式下经控制器把官方
   * miniBar 收进页签栏 / 展开恢复 —— applyMiniBarStyle 官方语义「更新迷你栏样式
   * 并伴随动效」，过渡动效由 HDS 内建。融合胶囊样式无消费者，直接返回
   * （其收起/展开走 STORE_MINI_BAR_EXPANDED，与本键互不相干）。
   */
  private onImmersiveMiniSnap(): void {
    if (this.navBarStyle !== NavBarStyle.IMMERSIVE || !this.miniBarApplied) {
      return;
    }
    const target: HdsBarStyle = this.miniBarCollapsed ? HdsBarStyle.COLLAPSE : HdsBarStyle.EXPAND;
    // 去重：目标态与最近一次已应用态相同时跳过 —— onBarStyleChange 回写同值
    // 可能再触发本 @Watch，重复 apply 会重播动效（等于切页签旧 bug 换个入口复活）。
    if (target === this.lastSnapApplied) {
      return;
    }
    this.lastSnapApplied = target;
    this.tabController.applyMiniBarStyle(target);
  }

  /**
   * 官方迷你播放栏槽位内容（宿主侧薄封装）。
   * 独立组件直接订阅 AppStorage，切歌 / 播放态实时刷新，不受 HDS builder 缓存影响。
   * 收起态点圆盘请求重新展开（宿主回调控制器 applyMiniBarStyle，PlayBar 同款交互）。
   */
  @Builder
  ImmersiveMiniBarHost(): void {
    ImmersiveMiniBar({
      onExpandRequest: (): void => {
        // 先写收起键再 apply（APP_TRIGGER 回声不回写逻辑键，见 onBarStyleChange）：
        // 键落库驱动 @Watch 去重与持久态；内容体（ImmersiveMiniBar）不再随键早切 ——
        // 由 onMiniBarAnimationStart 回调在 HDS 形变首拍同帧同步视觉态，
        // 展开体淡入与槽位展开同拍。lastSnapApplied 去重，保证只 apply 一次、不重播动效。
        AppStorage.setOrCreate(STORE_MINI_BAR_COLLAPSED, false);
        if (this.lastSnapApplied !== HdsBarStyle.EXPAND) {
          this.lastSnapApplied = HdsBarStyle.EXPAND;
          this.tabController.applyMiniBarStyle(HdsBarStyle.EXPAND);
        }
      }
    })
  }

  /**
   * 悬浮沉浸底栏（设置 → 外观 → 底部导航栏 → 悬浮沉浸）—— 单层 HdsTabs、
   * **双层底栏**：官方 miniBar（ImmersiveMiniBar，迷你播放栏）在上、页签栏在下
   * （barLayoutMode: VERTICAL），布局 / 材质 / 离底全部交给 HDS
   * （immersiveFloatingStyle），**不自绘 Stack 叠加层**。
   * 四个 Tab 页面与融合胶囊完全共用（搜索 / 歌单 / 下载 / 设置）；选中态品牌粉 /
   * 未选中次要色复用 tabItem（同一 @Builder，两种底栏视觉零差异）。
   * 受控 index 沿用 STORE_ACTIVE_TAB 写穿：与融合胶囊共享同一状态，样式来回切
   * 页签停留位置不丢；controller 复用 this.tabController（两种底栏互斥挂载，
   * 同一时刻只有一个 HdsTabs 绑定控制器，不会争抢）。
   */
  @Builder
  floatingImmersiveNav() {
    HdsTabs({ controller: this.tabController, index: this.activeTab }) {
      TabContent() {
        SearchPage()
      }.tabBar(this.tabItem(0, '搜索', $r('sys.symbol.magnifyingglass')))

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
    // 内容延伸到悬浮页签栏下方：列表滚动时从沉浸材质下透出
    .barOverlap(true)
    // 实验（2026-10-13）：HDS 6.1.1 实测 applyMiniBarStyle 动画仅 ~30ms 瞬切
    //（Start→End 回调间隔 27-36ms，真机日志实锤），SDK 无迷你栏动效时长参数；
    // 本属性文档口径是「页签切换动画时长」，试设 300ms 验证其是否也管
    // 迷你栏折叠/展开形变 —— 无效则走自绘胶囊接管（宿主架构方案）。
    .animationDuration(300)
    // 官方 miniBar（队列非空时挂入）+ 沉浸光感材质 + 悬浮离底，见 immersiveFloatingStyle
    .barFloatingStyle(this.immersiveFloatingStyle())
    // 受控 index 必须回写，否则下一次重渲染会把页签弹回旧值
    .onChange((index: number): void => {
      this.activeTab = index;
    })
    .width('100%')
    .height('100%')
  }

  @Builder
  pageMap(name: string, param: Object): void {
    if (name === 'Player') {
      PlayerPage();
    } else if (name === 'PlaylistDetail') {
      PlaylistDetail();
    } else if (name === 'Recent') {
      RecentPage();
    } else if (name === 'Follows') {
      // 「设置 → 登录后能力 → 我的关注」：登录用户的关注列表（行点击进 UP 主页订阅）
      FollowsPage();
    } else if (name === 'UpSpace') {
      UpSpacePage();
    } else if (name === 'WatchHistory') {
      // 「设置 → 登录后能力 → 观看历史与稍后再看」：B 站真实观看记录与稍后再看
      WatchHistoryPage();
    } else if (name === 'About') {
      AboutPage();
    } else if (name === 'Login') {
      LoginPage();
    } else if (name === 'SmsLogin') {
      SmsLoginPage();
    }
  }

  /**
   * 根标题栏样式：统一委托 HdsTitleBarStyle.styleOptions（2026-10-12 收敛）。
   *
   * 两档决策与样式细节全部收在助手一处，与其余 HdsNavDestination 子页同源：
   * - **沉浸档**：GRADIENT_BLUR（0→20vp 线性插值）+ blurStrategy: ENABLE
   *   + ADAPTIVE/ADAPTIVE 材质 + 显式样式端点（originalStyle 透明背景 →
   *   scrollEffectStyle bg_page 不透明背景，渐进模糊指南四步法）。
   * - **兜底档**：GRADIENT_BLUR 玻璃色端点 + maskExtra 罩住溢出渲染的第二行。
   *
   * （历史：2026-10-11 沉浸档曾内联在本方法，与助手两份配置反复人工对齐易
   * 漂移；2026-10-12 补样式端点后两路完全等价，收敛为单行委托。ENABLE 的
   * 来历：FAQ faqs-arkui-1095 末问答，部分设备 blurStrategy 默认 ADAPTIVE
   * 下动态模糊不渲染，ENABLE 强制开启。）
   */
  private titleBarStyle(): TitleBarStyleOptions {
    return HdsTitleBarStyle.styleOptions(TAB_BLUR_START_VP, TAB_BLUR_END_VP, FALLBACK_MASK_EXTRA_VP);
  }

  /**
   * 当前页签的列表 scroller（单绑，2026-10-11 回归）。
   *
   * ⚠️ 历史教训：曾经「四 scroller 多绑」配合「页面 new 后替换 holder 字段」导致
   * bindToScrollable 求值时拿到未挂载的占位实例——首开顶栏滚动模糊整段失效，
   * 要等 Index 因其它状态变化重渲染才「偶尔恢复」。现在 TabScrollerHolder 静态
   * 字段是唯一真源（四页 List 直挂，身份恒定），本方法按 activeTab 取当前页签的
   * 稳定实例单绑（FAQ faqs-arkui-1095 / Spatialization 参考工程 MainPage 同款）；
   * activeTab 是 @State，切页签触发重渲染 → 属性重设 → 自动换绑新页签的 scroller。
   */
  private activeTabScroller(): Scroller {
    if (this.activeTab === TAB_SEARCH) {
      return TabScrollerHolder.search;
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
    .padding({ left: 20, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 根栏 stackBuilder 全量内容（HarmonyX ImmersiveTitleBarContent 移植）：
   * 行 1 = 标题行 / 搜索行（SearchInputBar，56 锁高）；行 2 = 页签行 / 工具条，
   * position(y = NAV_TITLE_BAR_HEIGHT) 溢出渲染到标题栏下方。
   * ⚠️ stackBuilder 容器原点在状态栏下方（avoidLayoutSafeArea），行 2 的
   * 容器内 y=56 = 屏幕绝对 safeTop + 56 —— 与各页 contentStartOffset 让位公式
   * 逐像素一致（换容器不换几何）。
   * 外层 Stack：clip(false) 让行 2 画出容器边界；hitTestBehavior(Transparent)
   * 让行 2 未覆盖的空白区点击穿透到下方列表（HarmonyX 同款行为）。
   */
  @Builder
  immersiveTitleBarContent() {
    if (this.activeTab === TAB_SEARCH) {
      Stack() {
        Row() {
          SearchInputBar()
        }
        .width('100%')
        .height(NAV_TITLE_BAR_HEIGHT)
        .alignItems(VerticalAlign.Center)
        SearchTabsBar()
          .position({ x: 0, y: NAV_TITLE_BAR_HEIGHT })
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
      Column() {
        // 批 3：根容器 Navigation → HdsNavigation（同签名平替），Tab 页顶栏改为
        // Navigation 级统一 titleBar（任务书问题 1 方案 B）——只有设置页签显示，
        // 其余页签由 hideTitleBar 门控继续用各自自绘顶栏。
        HdsNavigation(NavStackHolder.stack) {
          // 底部导航栏样式二选一（设置 → 外观 → 底部导航栏，STORE_NAV_BAR_STYLE）：
          //   悬浮沉浸 → floatingImmersiveNav（HdsTabs 独立悬浮样式：沉浸光感材质 +
          //             官方 miniBar 迷你播放栏 ImmersiveMiniBar）；
          //   融合胶囊 → 现有 HdsTabs 形态（默认，整块原样保留，行为不变）。
          // 两种样式共用根标题栏 / 路由（HdsNavigation 上的属性链）与
          // activeTab / 队列状态（全在 AppStorage），切换不丢状态。
          if (this.navBarStyle === NavBarStyle.IMMERSIVE) {
            this.floatingImmersiveNav()
          } else {
            HdsTabs({ controller: this.tabController, index: this.activeTab }) {
              TabContent() {
                SearchPage()
              }.tabBar(this.tabItem(0, '搜索', $r('sys.symbol.magnifyingglass')))

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
            // 内容延伸到页签栏下方：列表滚动时从悬浮胶囊的材质下透出
            .barOverlap(true)
            // 受控 index 必须回写，否则下一次重渲染会把页签弹回旧值
            .onChange((index: number): void => {
              this.activeTab = index;
            })
            .barFloatingStyle(this.barFloatingStyle())
            .width('100%')
            .height('100%')
            // ⚠️ 这里**不再**加 padding({ top: safeTop })：状态栏避让下放到各 Tab 页的
            // 固定栏（材质 Row 内部 padding.top = safeTop），让材质从 y=0 铺起覆盖状态栏。
            // NavDestination 子页不参与 HdsTabs 布局，本来就不受这里的 padding 影响。
          }
        }
        // 根标题栏（HarmonyX 移植）：stackBuilder 承载整块顶栏内容（行 1 + 行 2
        // 溢出渲染），bottomBuilder 槽整体退役 —— 其「随滚动跳动」根因
        // （bindToScrollable 隐式显隐管线位移）从物理上消除。
        // avoidLayoutSafeArea 与子页同口径（栏顶 = safeTop，覆盖式渲染）；
        // divider OFF：行 2 自带 0.5vp 底缘线的页面不再由根栏画分割线。
        .titleBar({
          avoidLayoutSafeArea: true,
          style: this.titleBarStyle(),
          content: {
            stackBuilder: (): void => {
              this.immersiveTitleBarContent();
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
        // 单绑当前页签 scroller（2026-10-11 回归，FAQ faqs-arkui-1095 / 参考工程
        // MainPage 同款）：activeTab 变化触发重渲染自动换绑；TabScrollerHolder
        // 静态字段为唯一真源（四页 List 直挂，身份恒定），绑定与挂载先后顺序不再敏感。
        .bindToScrollable([this.activeTabScroller()])
      }
      .width('100%')
      .height('100%')

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
}
