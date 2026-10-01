if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface Index_Params {
    safeTop?: number;
    safeBottom?: number;
    queue?: Track[];
    miniBarExpanded?: boolean;
    currentBreakpoint?: string;
    miniBarApplied?: boolean;
    activeTab?: number;
    tabController?: HdsTabsController;
    useExquisiteMaterial?: boolean;
    mainWindow?: window.Window | null;
    breakpointSystem?: BreakpointSystem;
}
import type { UIContext } from "@ohos:arkui.UIContext";
import { HdsTabs } from "@hms:hds.hdsBaseComponent";
import { HdsTabsController } from "@hms:hds.hdsBaseComponent";
import type { HdsTabsFloatingStyle } from "@hms:hds.hdsBaseComponent";
import type { HdsTabsMiniBar } from "@hms:hds.hdsBaseComponent";
import { HdsBarStyle } from "@hms:hds.hdsBaseComponent";
import { HdsTabsBarChangeMode } from "@hms:hds.hdsBaseComponent";
import { HdsBarLayoutMode } from "@hms:hds.hdsBaseComponent";
import { hdsMaterial } from "@hms:hds.hdsMaterial";
import type { HdsTabsAttribute } from "@hms:hds.hdsBaseComponent";
import window from "@ohos:window";
import type common from "@ohos:app.ability.common";
import type { BusinessError } from "@ohos:base";
import type { Track } from '../model/MusicModels';
import { SearchPage } from "@normalized:N&&&entry/src/main/ets/pages/SearchPage&";
import { PlaylistsPage } from "@normalized:N&&&entry/src/main/ets/pages/PlaylistsPage&";
import { DownloadsPage } from "@normalized:N&&&entry/src/main/ets/pages/DownloadsPage&";
import { SettingsPage } from "@normalized:N&&&entry/src/main/ets/pages/SettingsPage&";
import { PlayerPage } from "@normalized:N&&&entry/src/main/ets/pages/PlayerPage&";
import { PlaylistDetail } from "@normalized:N&&&entry/src/main/ets/pages/PlaylistDetail&";
import { RecentPage } from "@normalized:N&&&entry/src/main/ets/pages/RecentPage&";
import { AboutPage } from "@normalized:N&&&entry/src/main/ets/pages/AboutPage&";
import { NavStackHolder } from "@normalized:N&&&entry/src/main/ets/service/NavStackHolder&";
import { PlayBar } from "@normalized:N&&&entry/src/main/ets/components/PlayBar&";
import { AppToast } from "@normalized:N&&&entry/src/main/ets/components/AppToast&";
import { MaterialCompat } from "@normalized:N&&&entry/src/main/ets/utils/MaterialCompat&";
import { BreakpointSystem } from "@normalized:N&&&entry/src/main/ets/common/utils/BreakpointSystem&";
import { BreakpointConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/BreakpointConstants&";
import { STORE_QUEUE, STORE_MINI_BAR_EXPANDED, STORE_SAFE_TOP, STORE_SAFE_BOTTOM } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
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
class Index extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__safeTop = this.createStorageLink(STORE_SAFE_TOP, 0, "safeTop");
        this.__safeBottom = this.createStorageLink(STORE_SAFE_BOTTOM, 0, "safeBottom");
        this.__queue = this.createStorageLink(STORE_QUEUE, [], "queue");
        this.__miniBarExpanded = this.createStorageLink(STORE_MINI_BAR_EXPANDED, false, "miniBarExpanded");
        this.__currentBreakpoint = this.createStorageProp(BreakpointConstants.CURRENT_BREAKPOINT, BreakpointConstants.BREAKPOINT_SM, "currentBreakpoint");
        this.miniBarApplied = false;
        this.__activeTab = new ObservedPropertySimplePU(0, this, "activeTab");
        this.tabController = new HdsTabsController();
        this.useExquisiteMaterial = false;
        this.mainWindow = null;
        this.breakpointSystem = new BreakpointSystem();
        this.setInitiallyProvidedValue(params);
        this.declareWatch("currentBreakpoint", this.onBreakpointChanged);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: Index_Params) {
        if (params.miniBarApplied !== undefined) {
            this.miniBarApplied = params.miniBarApplied;
        }
        if (params.activeTab !== undefined) {
            this.activeTab = params.activeTab;
        }
        if (params.tabController !== undefined) {
            this.tabController = params.tabController;
        }
        if (params.useExquisiteMaterial !== undefined) {
            this.useExquisiteMaterial = params.useExquisiteMaterial;
        }
        if (params.mainWindow !== undefined) {
            this.mainWindow = params.mainWindow;
        }
        if (params.breakpointSystem !== undefined) {
            this.breakpointSystem = params.breakpointSystem;
        }
    }
    updateStateVars(params: Index_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__safeTop.purgeDependencyOnElmtId(rmElmtId);
        this.__safeBottom.purgeDependencyOnElmtId(rmElmtId);
        this.__queue.purgeDependencyOnElmtId(rmElmtId);
        this.__miniBarExpanded.purgeDependencyOnElmtId(rmElmtId);
        this.__currentBreakpoint.purgeDependencyOnElmtId(rmElmtId);
        this.__activeTab.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__safeTop.aboutToBeDeleted();
        this.__safeBottom.aboutToBeDeleted();
        this.__queue.aboutToBeDeleted();
        this.__miniBarExpanded.aboutToBeDeleted();
        this.__currentBreakpoint.aboutToBeDeleted();
        this.__activeTab.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    /**
     * 状态栏高度（vp）：窗口全屏后系统不再避让，页签层要自己顶下来这么多，否则
     * 搜索框 / 列表首项会被状态栏（时间、电量）压住。
     */
    private __safeTop: ObservedPropertyAbstractPU<number>;
    get safeTop() {
        return this.__safeTop.get();
    }
    set safeTop(newValue: number) {
        this.__safeTop.set(newValue);
    }
    /**
     * 底部避让区高度（vp）：手势导航 = 导航指示条区域，三键导航 = 导航栏。
     * 本页把它加进悬浮页签栏的 barBottomMargin（胶囊抬到手势条上方）。
     * Tabs 内容区自身不避让，所以首页（搜索页）的列表能一直铺到屏幕最底。
     * 全局底部播放栏与 NavDestination 子页各自用这个值避让（见 PlayBar / 各子页）。
     */
    private __safeBottom: ObservedPropertyAbstractPU<number>;
    get safeBottom() {
        return this.__safeBottom.get();
    }
    set safeBottom(newValue: number) {
        this.__safeBottom.set(newValue);
    }
    /**
     * 播放队列（歌单列表）：决定融合播放栏是否挂进悬浮胶囊 ——
     * 队列为空时 barFloatingStyle 不带 miniBar，胶囊退回纯页签形态（播放栏隐藏）。
     */
    private __queue: ObservedPropertyAbstractPU<Track[]>;
    get queue() {
        return this.__queue.get();
    }
    set queue(newValue: Track[]) {
        this.__queue.set(newValue);
    }
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
    private __miniBarExpanded: ObservedPropertyAbstractPU<boolean>;
    get miniBarExpanded() {
        return this.__miniBarExpanded.get();
    }
    set miniBarExpanded(newValue: boolean) {
        this.__miniBarExpanded.set(newValue);
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
    private __currentBreakpoint: ObservedPropertyAbstractPU<string>;
    get currentBreakpoint() {
        return this.__currentBreakpoint.get();
    }
    set currentBreakpoint(newValue: string) {
        this.__currentBreakpoint.set(newValue);
    }
    /**
     * miniBar 初始折叠是否已应用过（只补一次的守卫）。
     * 部分版本上 miniBarStyle 初始值不生效，参考 Sumy：挂载后延迟 100ms 由
     * 控制器 applyMiniBarStyle(COLLAPSE) 补一次；用户后续的展开 / 收起不受影响。
     * 同时它也是 onBreakpointChanged 里「控制器是否已可安全调用」的守卫 ——
     * 冷启动在折叠屏展开态时，register 写断点会立刻触发 @Watch，那时 HdsTabs
     * 尚未挂载，不能调 applyMiniBarStyle（只同步全局状态即可）。
     */
    private miniBarApplied: boolean;
    /**
     * 当前页签下标。HdsTabs 用**受控 index**：点选 / 侧滑后由 onChange 回写，
     * 不回写的话下一次重渲染会把页签弹回旧值。
     */
    private __activeTab: ObservedPropertySimplePU<number>;
    get activeTab() {
        return this.__activeTab.get();
    }
    set activeTab(newValue: number) {
        this.__activeTab.set(newValue);
    }
    private tabController: HdsTabsController;
    /**
     * 设备是否支持 HDS 的 IMMERSIVE 材质类型。
     *
     * ⚠️ 官方要求：未查询设备材质能力就直接选 EXQUISITE 精美档，在不支持的设备上会卡顿发热。
     * 所以先探测，不支持就用 ADAPTIVE 交给系统自适应。
     * 取值只在 aboutToAppear 里算一次（构造期调系统能力有失败风险），之后不变，
     * 因此用普通成员而非 @State —— 它不参与刷新（render 时读到的一定是探测后的值）。
     */
    private useExquisiteMaterial: boolean;
    /** 主窗口句柄，只用于注销 avoidAreaChange 监听 */
    private mainWindow: window.Window | null;
    /**
     * 断点监听（sm/md/lg → AppStorage）：**全局唯一**的注册点。
     *
     * 早期只有播放页需要断点（组件树来自折叠屏样例），注册在 PlayerPage 里；
     * 现在列表页也要做大屏适配（内容列收窄居中），注册点必须上移到本页 ——
     * 本页是常驻根页面，注册一次全程有效，折叠屏开合 / 平板旋转时所有页面都能跟着变。
     * PlayerPage 里的那份注册已删除（两份注册 = 双份 mediaquery 监听，纯浪费）。
     */
    private breakpointSystem: BreakpointSystem;
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
        AppStorage.setOrCreate(STORE_MINI_BAR_EXPANDED, initBp !== undefined && initBp !== BreakpointConstants.BREAKPOINT_SM);
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
                this.tabController.applyMiniBarStyle(this.miniBarExpanded ? HdsBarStyle.EXPAND : HdsBarStyle.COLLAPSE);
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
            const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
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
        }
        catch (e) {
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
        }
        catch (e) {
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
            const indicator: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
            const topVp: number = ui.px2vp(sys.topRect.height);
            const bottomPx: number = Math.max(sys.bottomRect.height, indicator.bottomRect.height);
            const bottomVp: number = ui.px2vp(bottomPx);
            AppStorage.setOrCreate(STORE_SAFE_TOP, topVp);
            AppStorage.setOrCreate(STORE_SAFE_BOTTOM, bottomVp);
            console.info(`avoidArea: top=${topVp}vp bottom=${bottomVp}vp`);
        }
        catch (e) {
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
                onBarStyleChange: (miniBarStyle: HdsBarStyle, tabBarStyle: HdsBarStyle, miniBarWidth: number, tabBarWidth: number, mode: HdsTabsBarChangeMode): void => {
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
    PlayBarHost(parent = null): void {
        {
            this.observeComponentCreation2((elmtId, isInitialRender) => {
                if (isInitialRender) {
                    let componentCall = new PlayBar(this, {
                        onExpandRequest: (): void => {
                            // 收起态点封面：重新展开融合播放栏（Sumy 同款交互，不直接进播放页）
                            this.tabController.applyMiniBarStyle(HdsBarStyle.EXPAND);
                        }
                    }, undefined, elmtId, () => { }, { page: "entry/src/main/ets/pages/Index.ets", line: 407, col: 5 });
                    ViewPU.create(componentCall);
                    let paramsLambda = () => {
                        return {
                            onExpandRequest: (): void => {
                                // 收起态点封面：重新展开融合播放栏（Sumy 同款交互，不直接进播放页）
                                this.tabController.applyMiniBarStyle(HdsBarStyle.EXPAND);
                            }
                        };
                    };
                    componentCall.paramsGenerator_ = paramsLambda;
                }
                else {
                    this.updateStateVarsOfChildByElmtId(elmtId, {});
                }
            }, { name: "PlayBar" });
        }
    }
    /**
     * 页签内容：SymbolGlyph 图标 + 文字，选中态品牌粉、未选中次要色。
     *
     * ⚠️ 参数**只传静态字面量**（下标 / 文案 / 图标资源），选中的判断在 Builder 内部现算。
     * 带参 @Builder 是**值传递**，把状态变量当参数传进来时，状态变化不会刷新其内部 UI
     * （典型症状：同一行里一半控件正常、一半失灵）。
     */
    tabItem(index: number, label: string, icon: Resource, parent = null) {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create({ space: 2 });
            Column.alignItems(HorizontalAlign.Center);
            Column.justifyContent(FlexAlign.Center);
            Column.height('100%');
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            SymbolGlyph.create(icon);
            SymbolGlyph.fontSize(22);
            SymbolGlyph.fontColor([this.activeTab === index ? { "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 125830983, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }]);
        }, SymbolGlyph);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(label);
            Text.fontSize(11);
            Text.fontWeight(FontWeight.Medium);
            Text.fontColor(this.activeTab === index ? { "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 125830983, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Text);
        Text.pop();
        Column.pop();
    }
    pageMap(name: string, param: Object, parent = null): void {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (name === 'Player') {
                this.ifElseBranchUpdateFunction(0, () => {
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new PlayerPage(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/pages/Index.ets", line: 441, col: 7 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {};
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {});
                            }
                        }, { name: "PlayerPage" });
                    }
                });
            }
            else if (name === 'PlaylistDetail') {
                this.ifElseBranchUpdateFunction(1, () => {
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new PlaylistDetail(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/pages/Index.ets", line: 443, col: 7 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {};
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {});
                            }
                        }, { name: "PlaylistDetail" });
                    }
                });
            }
            else if (name === 'Recent') {
                this.ifElseBranchUpdateFunction(2, () => {
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new RecentPage(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/pages/Index.ets", line: 445, col: 7 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {};
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {});
                            }
                        }, { name: "RecentPage" });
                    }
                });
            }
            else if (name === 'About') {
                this.ifElseBranchUpdateFunction(3, () => {
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new AboutPage(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/pages/Index.ets", line: 447, col: 7 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {};
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {});
                            }
                        }, { name: "AboutPage" });
                    }
                });
            }
            else {
                this.ifElseBranchUpdateFunction(4, () => {
                });
            }
        }, If);
        If.pop();
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Stack.create();
            Stack.width('100%');
            Stack.height('100%');
            Stack.backgroundColor({ "id": 16777232, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Stack);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.width('100%');
            Column.height('100%');
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Navigation.create(NavStackHolder.stack, { moduleName: "entry", pagePath: "entry/src/main/ets/pages/Index", isUserCreateStack: true });
            Navigation.navDestination({ builder: this.pageMap.bind(this) });
            Navigation.hideTitleBar(true);
            Navigation.mode(NavigationMode.Stack);
        }, Navigation);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            HdsTabs.create({ controller: this.tabController, index: this.activeTab });
            HdsTabs.vertical(false);
            HdsTabs.barPosition(BarPosition.End);
            HdsTabs.barMode(BarMode.Fixed);
            HdsTabs.barOverlap(true);
            HdsTabs.onChange((index: number): void => {
                this.activeTab = index;
            });
            HdsTabs.barFloatingStyle(this.barFloatingStyle());
            HdsTabs.width('100%');
            HdsTabs.height('100%');
            HdsTabs.padding({ top: this.safeTop });
        }, HdsTabs);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            TabContent.create(() => {
                {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        if (isInitialRender) {
                            let componentCall = new SearchPage(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/pages/Index.ets", line: 457, col: 15 });
                            ViewPU.create(componentCall);
                            let paramsLambda = () => {
                                return {};
                            };
                            componentCall.paramsGenerator_ = paramsLambda;
                        }
                        else {
                            this.updateStateVarsOfChildByElmtId(elmtId, {});
                        }
                    }, { name: "SearchPage" });
                }
            });
            TabContent.tabBar({ builder: () => {
                    this.tabItem.call(this, 0, '搜索', { "id": 125831500, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                } });
        }, TabContent);
        TabContent.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            TabContent.create(() => {
                {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        if (isInitialRender) {
                            let componentCall = new PlaylistsPage(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/pages/Index.ets", line: 461, col: 15 });
                            ViewPU.create(componentCall);
                            let paramsLambda = () => {
                                return {};
                            };
                            componentCall.paramsGenerator_ = paramsLambda;
                        }
                        else {
                            this.updateStateVarsOfChildByElmtId(elmtId, {});
                        }
                    }, { name: "PlaylistsPage" });
                }
            });
            TabContent.tabBar({ builder: () => {
                    this.tabItem.call(this, 1, '歌单', { "id": 125831650, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                } });
        }, TabContent);
        TabContent.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            TabContent.create(() => {
                {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        if (isInitialRender) {
                            let componentCall = new DownloadsPage(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/pages/Index.ets", line: 465, col: 15 });
                            ViewPU.create(componentCall);
                            let paramsLambda = () => {
                                return {};
                            };
                            componentCall.paramsGenerator_ = paramsLambda;
                        }
                        else {
                            this.updateStateVarsOfChildByElmtId(elmtId, {});
                        }
                    }, { name: "DownloadsPage" });
                }
            });
            TabContent.tabBar({ builder: () => {
                    this.tabItem.call(this, 2, '下载', { "id": 125831263, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                } });
        }, TabContent);
        TabContent.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            TabContent.create(() => {
                {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        if (isInitialRender) {
                            let componentCall = new SettingsPage(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/pages/Index.ets", line: 469, col: 15 });
                            ViewPU.create(componentCall);
                            let paramsLambda = () => {
                                return {};
                            };
                            componentCall.paramsGenerator_ = paramsLambda;
                        }
                        else {
                            this.updateStateVarsOfChildByElmtId(elmtId, {});
                        }
                    }, { name: "SettingsPage" });
                }
            });
            TabContent.tabBar({ builder: () => {
                    this.tabItem.call(this, 3, '设置', { "id": 125831493, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                } });
        }, TabContent);
        TabContent.pop();
        HdsTabs.pop();
        Navigation.pop();
        Column.pop();
        {
            this.observeComponentCreation2((elmtId, isInitialRender) => {
                if (isInitialRender) {
                    let componentCall = new 
                    // 全局 Toast：盖在页面与 NavDestination 子页之上，整层不拦截触摸
                    //（含出入场动效与「替换不排队」语义，见 components/AppToast.ets）
                    AppToast(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/pages/Index.ets", line: 497, col: 7 });
                    ViewPU.create(componentCall);
                    let paramsLambda = () => {
                        return {};
                    };
                    componentCall.paramsGenerator_ = paramsLambda;
                }
                else {
                    this.updateStateVarsOfChildByElmtId(elmtId, {});
                }
            }, { name: "AppToast" });
        }
        Stack.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
    static getEntryName(): string {
        return "Index";
    }
}
registerNamedRoute(() => new Index(undefined, {}), "", { bundleName: "com.chai.bilimusic", moduleName: "entry", pagePath: "pages/Index", pageFullPath: "entry/src/main/ets/pages/Index", integratedHsp: "false", moduleType: "followWithHap" });
