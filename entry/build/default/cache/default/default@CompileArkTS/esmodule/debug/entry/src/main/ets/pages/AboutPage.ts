if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface AboutPage_Params {
    safeTop?: number;
    safeBottom?: number;
    currentBreakpoint?: string;
    appVersion?: string;
    navTransX?: string;
}
import { STORE_SAFE_BOTTOM, STORE_SAFE_TOP } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
import { NAV_TITLE_BAR_HEIGHT } from "@normalized:N&&&entry/src/main/ets/utils/NavTitleStyle&";
import { BreakpointConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/BreakpointConstants&";
import { NAV_TRANSITION_MS } from "@normalized:N&&&entry/src/main/ets/common/constants/InteractionConstants&";
import bundleManager from "@ohos:bundle.bundleManager";
import type { BusinessError } from "@ohos:base";
/** 功能特性条目：一行一条，纯展示 */
interface AboutFeature {
    title: string;
    detail: string;
}
const ABOUT_FEATURES: AboutFeature[] = [
    { title: '在线搜索与播放', detail: '搜索 B 站视频音频流，即点即播，支持自动连播' },
    { title: '歌词显示', detail: '自动匹配歌词，播放页逐行滚动' },
    { title: '歌单管理', detail: '自建歌单收藏喜欢的歌曲' },
    { title: '离线下载', detail: '按音质档位下载到本地，支持仅 WiFi 下载' },
    { title: '最近播放', detail: '记录播放历史，快速回放' },
    { title: '定时停止', detail: '到点自动停止播放' }
];
export class AboutPage extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__safeTop = this.createStorageLink(STORE_SAFE_TOP, 0, "safeTop");
        this.__safeBottom = this.createStorageLink(STORE_SAFE_BOTTOM, 0, "safeBottom");
        this.__currentBreakpoint = this.createStorageProp(BreakpointConstants.CURRENT_BREAKPOINT, BreakpointConstants.BREAKPOINT_SM, "currentBreakpoint");
        this.__appVersion = new ObservedPropertySimplePU('', this, "appVersion");
        this.__navTransX = new ObservedPropertySimplePU('0%', this, "navTransX");
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: AboutPage_Params) {
        if (params.appVersion !== undefined) {
            this.appVersion = params.appVersion;
        }
        if (params.navTransX !== undefined) {
            this.navTransX = params.navTransX;
        }
    }
    updateStateVars(params: AboutPage_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__safeTop.purgeDependencyOnElmtId(rmElmtId);
        this.__safeBottom.purgeDependencyOnElmtId(rmElmtId);
        this.__currentBreakpoint.purgeDependencyOnElmtId(rmElmtId);
        this.__appVersion.purgeDependencyOnElmtId(rmElmtId);
        this.__navTransX.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__safeTop.aboutToBeDeleted();
        this.__safeBottom.aboutToBeDeleted();
        this.__currentBreakpoint.aboutToBeDeleted();
        this.__appVersion.aboutToBeDeleted();
        this.__navTransX.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    /** 状态栏高度（vp）：内容区要整体落在状态栏下方，由本页自己顶下来 */
    private __safeTop: ObservedPropertyAbstractPU<number>;
    get safeTop() {
        return this.__safeTop.get();
    }
    set safeTop(newValue: number) {
        this.__safeTop.set(newValue);
    }
    /** 底部安全区高度（vp）：内容末尾让开手势区 */
    private __safeBottom: ObservedPropertyAbstractPU<number>;
    get safeBottom() {
        return this.__safeBottom.get();
    }
    set safeBottom(newValue: number) {
        this.__safeBottom.set(newValue);
    }
    /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
    private __currentBreakpoint: ObservedPropertyAbstractPU<string>;
    get currentBreakpoint() {
        return this.__currentBreakpoint.get();
    }
    set currentBreakpoint(newValue: string) {
        this.__currentBreakpoint.set(newValue);
    }
    /** 应用版本号（如「版本：1.0.2」）：从 bundleManager 读，跟着 app.json5 走，不在页面里写死 */
    private __appVersion: ObservedPropertySimplePU<string>;
    get appVersion() {
        return this.__appVersion.get();
    }
    set appVersion(newValue: string) {
        this.__appVersion.set(newValue);
    }
    /**
     * 子页转场的横移量（相对页面自身宽度）：常驻 '0%'，
     * 转场代理里按 push/pop 方向临时改写（见 navTransitionDelegate）。
     */
    private __navTransX: ObservedPropertySimplePU<string>;
    get navTransX() {
        return this.__navTransX.get();
    }
    set navTransX(newValue: string) {
        this.__navTransX.set(newValue);
    }
    aboutToAppear(): void {
        bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
            .then((info: bundleManager.BundleInfo): void => {
            this.appVersion = info.versionName.length > 0 ? `版本：${info.versionName}` : '';
        })
            .catch((e: BusinessError): void => {
            // 拿不到就空着，不影响其它内容展示
            console.error(`getBundleInfoForSelf failed: ${e.code} ${e.message}`);
        });
    }
    /**
     * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut。
     * · push 入场：先把页面挪到屏幕右侧外（'100%'），event 闭包内回到 '0%'，
     *   系统按闭包内的状态变化生成 400ms EaseOut 过渡；
     * · pop 出场（含侧滑返回手势触发的返回）：反向滑回右侧，与手势方向一致；
     * · 其余场景（本页被上层页覆盖 / 上层页返回后重新露出）返回 undefined，
     *   走系统默认转场。
     */
    private navTransitionDelegate(op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined {
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
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            NavDestination.create(() => {
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Stack.create();
                    Stack.width('100%');
                    Stack.height('100%');
                    Stack.backgroundColor({ "id": 16777232, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Stack.padding({ top: this.safeTop });
                    Stack.safeAreaPadding({ top: NAV_TITLE_BAR_HEIGHT, bottom: this.safeBottom });
                }, Stack);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Scroll.create();
                    Scroll.width('100%');
                    Scroll.align(Alignment.Top);
                    Scroll.scrollBar(BarState.Off);
                    Scroll.constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) });
                }, Scroll);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Column.create();
                    Column.width('100%');
                }, Column);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('关于');
                    Text.fontSize(20);
                    Text.fontWeight(FontWeight.Bold);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.width('100%');
                    Text.padding({ left: 16, top: 14, bottom: 10 });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    // ── 应用信息卡片 ──
                    Column.create();
                    // ── 应用信息卡片 ──
                    Column.width('100%');
                    // ── 应用信息卡片 ──
                    Column.backgroundColor({ "id": 16777230, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    // ── 应用信息卡片 ──
                    Column.borderRadius(12);
                    // ── 应用信息卡片 ──
                    Column.margin({ left: 12, right: 12 });
                    // ── 应用信息卡片 ──
                    Column.alignItems(HorizontalAlign.Center);
                }, Column);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('♪');
                    Text.fontSize(34);
                    Text.fontColor({ "id": 16777236, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.width(72);
                    Text.height(72);
                    Text.borderRadius(20);
                    Text.backgroundColor({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.textAlign(TextAlign.Center);
                    Text.margin({ top: 22 });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('BiliMusic');
                    Text.fontSize(20);
                    Text.fontWeight(FontWeight.Bold);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.margin({ top: 12 });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create(this.appVersion);
                    Text.fontSize(13);
                    Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.margin({ top: 4 });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('作者：chai');
                    Text.fontSize(13);
                    Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.margin({ top: 4 });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('转译自 github.com/HanversionOvO/BiliMusic');
                    Text.fontSize(13);
                    Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.margin({ top: 4 });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('一款基于 HarmonyOS 的 B 站第三方音乐播放器，以匿名身份访问 B 站音频资源，无需登录。');
                    Text.fontSize(13);
                    Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.lineHeight(18);
                    Text.textAlign(TextAlign.Center);
                    Text.padding({ left: 24, right: 24 });
                    Text.margin({ top: 10, bottom: 22 });
                }, Text);
                Text.pop();
                // ── 应用信息卡片 ──
                Column.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    // ── 功能特性 ──
                    Column.create();
                    // ── 功能特性 ──
                    Column.width('100%');
                    // ── 功能特性 ──
                    Column.backgroundColor({ "id": 16777230, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    // ── 功能特性 ──
                    Column.borderRadius(12);
                    // ── 功能特性 ──
                    Column.margin({ left: 12, right: 12, top: 10 });
                }, Column);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('功能特性');
                    Text.fontSize(16);
                    Text.fontWeight(FontWeight.Medium);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.width('100%');
                    Text.padding({ left: 16, top: 14, bottom: 8 });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    ForEach.create();
                    const forEachItemGenFunction = _item => {
                        const f = _item;
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Row.create();
                            Row.width('100%');
                            Row.padding({ left: 16, right: 16, top: 10, bottom: 10 });
                        }, Row);
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Column.create();
                            Column.alignItems(HorizontalAlign.Start);
                            Column.layoutWeight(1);
                        }, Column);
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Text.create(f.title);
                            Text.fontSize(16);
                            Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        }, Text);
                        Text.pop();
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Text.create(f.detail);
                            Text.fontSize(13);
                            Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                            Text.margin({ top: 4 });
                        }, Text);
                        Text.pop();
                        Column.pop();
                        Row.pop();
                    };
                    this.forEachUpdateFunction(elmtId, ABOUT_FEATURES, forEachItemGenFunction, (f: AboutFeature): string => `feature_${f.title}`, false, false);
                }, ForEach);
                ForEach.pop();
                // ── 功能特性 ──
                Column.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    // ── 项目说明 ──
                    Column.create();
                    // ── 项目说明 ──
                    Column.width('100%');
                    // ── 项目说明 ──
                    Column.backgroundColor({ "id": 16777230, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    // ── 项目说明 ──
                    Column.borderRadius(12);
                    // ── 项目说明 ──
                    Column.margin({ left: 12, right: 12, top: 10, bottom: 20 });
                }, Column);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('项目说明');
                    Text.fontSize(16);
                    Text.fontWeight(FontWeight.Medium);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.width('100%');
                    Text.padding({ left: 16, top: 14, bottom: 8 });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('本项目为开源的学习交流项目，界面与交互针对 HarmonyOS 手机端设计，播放、下载、歌单等数据均保存在设备本地。应用以匿名 + buvid 身份访问 B 站接口，不收集、不上传任何用户数据。');
                    Text.fontSize(13);
                    Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.lineHeight(18);
                    Text.width('100%');
                    Text.padding({ left: 16, right: 16, bottom: 8 });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('本项目与哔哩哔哩官方无关，音频内容版权归原作者所有，请勿将下载内容用于商业用途。');
                    Text.fontSize(13);
                    Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.lineHeight(18);
                    Text.width('100%');
                    Text.padding({ left: 16, right: 16, bottom: 16 });
                }, Text);
                Text.pop();
                // ── 项目说明 ──
                Column.pop();
                Column.pop();
                Scroll.pop();
                Stack.pop();
            }, { moduleName: "entry", pagePath: "entry/src/main/ets/pages/AboutPage" });
            NavDestination.hideTitleBar(true);
            NavDestination.translate({ x: this.navTransX });
            NavDestination.customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
                return this.navTransitionDelegate(op, isEnter);
            });
        }, NavDestination);
        NavDestination.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
