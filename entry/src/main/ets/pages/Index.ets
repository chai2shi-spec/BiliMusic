/**
 * 应用首页：**HDS 沉浸光感悬浮胶囊**，播放栏（PlayBar）与页签融合在同一个胶囊里。
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
 *   页签层(HdsTabs) padding.top = safeTop              → 状态栏让位，只加在页签层上：
 *                                                        NavDestination 子页不参与其布局。
 *   悬浮胶囊        barBottomMargin 见 barFloatingStyle  → 下沉贴近底边，避开手势条/导航栏
 *   各 Tab 列表     contentEndOffset = 160 + safeBottom → 末尾能滚到胶囊上方
 *   子页面          safeAreaPadding(bottom = safeBottom)→ 播放页控制栏等自己躲开手势条
 *
 * ⚠️ 顶部：NavDestination 子页的标题栏要**整体落在状态栏下方**（不被状态栏 / 挖孔遮挡），
 * 由各子页自己 `padding({ top: safeTop })` 顶下来 —— 见 PlayerPage / PlaylistDetail / RecentPage。
 * utils/NavTitleStyle.ets 的材质只让标题栏仍是半透明毛玻璃，不再与状态栏融为一体。
 *
 * safeTop / safeBottom 的写入路径：
 *   EntryAbility.publishSafeArea() 首帧前同步首发（避免内容先贴边再弹回来），
 *   本页 aboutToAppear 再主动读一次并注册 avoidAreaChange，
 *   旋转屏幕 / 切换三键与手势导航后自动更新。
 *
 * 子页面通过 Navigation + NavPathStack 管理（播放页 / 歌单详情 / 最近播放）。
 * 登录页已随登录功能整体移除，不要再加回 'Login' 路由。
 */

import { UIContext } from '@kit.ArkUI';
import {
  HdsTabs,
  HdsTabsController,
  HdsTabsFloatingStyle,
  HdsTabsMiniBar,
  HdsBarStyle,
  HdsTabsBarChangeMode,
  HdsBarLayoutMode,
  hdsMaterial
} from '@kit.UIDesignKit';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { Track } from '../model/MusicModels';
import { SearchPage } from './SearchPage';
import { PlaylistsPage } from './PlaylistsPage';
import { DownloadsPage } from './DownloadsPage';
import { SettingsPage } from './SettingsPage';
import { PlayerPage } from './PlayerPage';
import { PlaylistDetail } from './PlaylistDetail';
import { RecentPage } from './RecentPage';
import { AboutPage } from './AboutPage';
import { NavStackHolder } from '../service/NavStackHolder';
import { PlayBar } from '../components/PlayBar';
import { AppToast } from '../components/AppToast';
import { MaterialCompat } from '../utils/MaterialCompat';
import { BreakpointSystem } from '../common/utils/BreakpointSystem';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import {
  STORE_QUEUE,
  STORE_MINI_BAR_EXPANDED,
  STORE_SAFE_TOP,
  STORE_SAFE_BOTTOM
} from '../common/Constants';

/**
 * 悬浮页签栏离屏幕底边的净间距（vp，不含安全区）。
 * 旧值 20 让胶囊浮得太高；压到 6 使其贴近屏幕底部边框（少量安全区由下方公式叠加）。
 */
const BAR_BOTTOM_MARGIN: number = 6;
/**
 * 手势指示条避让区高度的预估上限（vp）。
 * 手势导航的指示条区域一般在 24~34vp；超过它（约 48vp+）就是三键导航栏 ——
 * 那是一整条可点击的系统控件，必须完整避让，不能像手势条那样只避开一半。
 */
const GESTURE_INDICATOR_MAX_VP: number = 36;
/** 沉浸光感的主题色光晕透明度 —— 移植自 Sumy 的 lightColor: withAlpha(themePrimary, 0.12) */
const GLOW_ALPHA: number = 0.12;
/** 页签栏微透明 —— 移植自 Sumy 的 barOpacity: 0.9 */
const BAR_OPACITY: number = 0.9;
/** 品牌粉（颜色资源里是 #FFFB7299）的 RGB 部分，用来拼带 alpha 的光晕色 */
const BILI_PINK_HEX: string = '#FB7299';

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
   * 当前页签下标。HdsTabs 用**受控 index**：点选 / 侧滑后由 onChange 回写，
   * 不回写的话下一次重渲染会把页签弹回旧值。
   */
  @State activeTab: number = 0;

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

  aboutToAppear(): void {
    // 先探测材质能力：barFloatingStyle() 在首帧 build 时就要用到它
    this.useExquisiteMaterial = MaterialCompat.supportsImmersiveMaterial();
    // 断点要先于子页注册：register 会同步把当前断点写进 AppStorage，
    // 各 Tab 页 aboutToAppear 时的 @StorageProp 初始值就是正确断点，首帧不跳变。
    this.breakpointSystem.register(this.getUIContext());
    this.bindAvoidArea();
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
        // 补初始折叠只在手机宽度下有意义：≥600vp 时 applyMiniBarStyle 无效，
        // HDS 已按展开态创建迷你栏（全局状态也在上面置过 true 了），无需补。
        if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_SM) {
          this.tabController.applyMiniBarStyle(HdsBarStyle.COLLAPSE);
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
   *   barBottomMargin      → **悬浮**：离底 20vp；再叠加底部安全区（见文件头说明）
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

  @Builder
  pageMap(name: string, param: Object): void {
    if (name === 'Player') {
      PlayerPage();
    } else if (name === 'PlaylistDetail') {
      PlaylistDetail();
    } else if (name === 'Recent') {
      RecentPage();
    } else if (name === 'About') {
      AboutPage();
    }
  }

  build() {
    Stack() {
      Column() {
        Navigation(NavStackHolder.stack) {
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
          // 顶部状态栏避让只加在页签层：NavDestination 子页不参与其布局，
          // 它们不受这里影响，由各子页自己 padding({ top: safeTop }) 把标题栏顶到状态栏下方。
          .padding({ top: this.safeTop })
        }
        .navDestination(this.pageMap)
        .hideTitleBar(true)
        .mode(NavigationMode.Stack)
      }
      .width('100%')
      .height('100%')

      // 全局 Toast：盖在页面与 NavDestination 子页之上，整层不拦截触摸
      //（含出入场动效与「替换不排队」语义，见 components/AppToast.ets）
      AppToast()
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
