if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface SettingsPage_Params {
    settings?: AppSettings;
    safeBottom?: number;
    currentBreakpoint?: string;
    sleepTimerEnd?: number;
    sleepRemainText?: string;
    sheetKind?: string;
    showSheet?: boolean;
    sleepTicker?: number;
    cacheText?: string;
    downloadText?: string;
    listenText?: string;
    cacheDirPath?: string;
    appCacheDirPath?: string;
    downloadDirPath?: string;
    appVersion?: string;
}
import fs from "@ohos:file.fs";
import type common from "@ohos:app.ability.common";
import bundleManager from "@ohos:bundle.bundleManager";
import type { BusinessError } from "@ohos:base";
import type promptAction from "@ohos:promptAction";
import { AudioQuality, ThemeMode } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
import type { AppSettings } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
import { AppPreferences } from "@normalized:N&&&entry/src/main/ets/preferences/AppPreferences&";
import { MusicPlayer } from "@normalized:N&&&entry/src/main/ets/player/MusicPlayer&";
import { NavStackHolder } from "@normalized:N&&&entry/src/main/ets/service/NavStackHolder&";
import { CONTENT_END_OFFSET, STORE_SAFE_BOTTOM, STORE_SLEEP_TIMER_END } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
import { showAppToast } from "@normalized:N&&&entry/src/main/ets/components/AppToast&";
import { BreakpointConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/BreakpointConstants&";
const SLEEP_OPTIONS: number[] = [10, 20, 30, 60, 120];
/**
 * 下载音质档位。
 *
 * `value` 必须与 `AudioQuality` 枚举值逐字一致 —— 它同时就是 AppSettings.downloadQuality
 * 的存储值，DownloadManager 每次下载都拿它去映射成 B 站音频流 id（见 downloadQualityId）。
 * `hint` 里如实写码率：B 站只提供它已有的档位，个别投稿最高只有 64 kbps，
 * 不写清楚的话用户会以为「选了高音质却还是小文件」是 App 的问题。
 */
interface QualityOption {
    value: string;
    hint: string;
}
const QUALITY_OPTIONS: QualityOption[] = [
    { value: AudioQuality.STANDARD, hint: '约 64 kbps，最省流量' },
    { value: AudioQuality.HIGH, hint: '约 192 kbps，默认' },
    { value: AudioQuality.LOSSLESS, hint: '优先 Hi-Res / 杜比，没有则取最高可用' }
];
function formatSleepMinutes(minutes: number): string {
    if (minutes >= 60 && minutes % 60 === 0) {
        return `${minutes / 60} 小时`;
    }
    return `${minutes} 分钟`;
}
function formatRemain(totalSeconds: number): string {
    const sec: number = Math.max(0, totalSeconds);
    const h: number = Math.floor(sec / 3600);
    const m: number = Math.floor((sec % 3600) / 60);
    const s: number = sec % 60;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = s < 10 ? `0${s}` : `${s}`;
    if (h > 0) {
        return `${h}:${mm}:${ss}`;
    }
    return `${mm}:${ss}`;
}
function formatBytes(bytes: number): string {
    if (bytes < 1024) {
        return `${bytes} B`;
    }
    const kb: number = bytes / 1024;
    if (kb < 1024) {
        return `${kb.toFixed(1)} KB`;
    }
    const mb: number = kb / 1024;
    if (mb < 1024) {
        return `${mb.toFixed(1)} MB`;
    }
    return `${(mb / 1024).toFixed(2)} GB`;
}
/**
 * 累计听歌时长的展示文案：满 1 小时按「X 小时 Y 分钟」，不足 1 小时按「X 分钟」，
 * 一分钟都没有（全新安装）显示「暂无记录」。
 */
function formatListenDuration(totalSeconds: number): string {
    const sec: number = Math.max(0, Math.floor(totalSeconds));
    const h: number = Math.floor(sec / 3600);
    const m: number = Math.floor((sec % 3600) / 60);
    if (h > 0) {
        return `${h} 小时 ${m} 分钟`;
    }
    if (m > 0) {
        return `${m} 分钟`;
    }
    return '暂无记录';
}
/**
 * 递归统计目录占用（字节）。目录不存在 / 单项读不动时按 0 计，绝不抛。
 * 统计是**同步 IO**，调用方负责放到 setTimeout 里跑，别阻塞首屏。
 */
function dirSize(path: string): number {
    if (path.length === 0) {
        return 0;
    }
    let total: number = 0;
    try {
        const names: string[] = fs.listFileSync(path);
        for (let i = 0; i < names.length; i++) {
            const child: string = `${path}/${names[i]}`;
            try {
                const st: fs.Stat = fs.statSync(child);
                total += st.isDirectory() ? dirSize(child) : st.size;
            }
            catch (e) {
                // 单个条目统计失败（被占用 / 刚被删）跳过
            }
        }
    }
    catch (e) {
        // 目录不存在
    }
    return total;
}
/**
 * 清空目录内容，**保留目录自身**（cacheDir 是系统目录，不能删）。
 * @returns 删除的文件个数
 */
function clearDirContents(path: string): number {
    if (path.length === 0) {
        return 0;
    }
    let removed: number = 0;
    try {
        const names: string[] = fs.listFileSync(path);
        for (let i = 0; i < names.length; i++) {
            const child: string = `${path}/${names[i]}`;
            try {
                const st: fs.Stat = fs.statSync(child);
                if (st.isDirectory()) {
                    removed += clearDirContents(child);
                    fs.rmdirSync(child);
                }
                else {
                    fs.unlinkSync(child);
                    removed += 1;
                }
            }
            catch (e) {
                // 被占用的文件删不掉，跳过；不要因为一个文件中断整次清理
            }
        }
    }
    catch (e) {
        // 目录不存在
    }
    return removed;
}
export class SettingsPage extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__settings = new ObservedPropertyObjectPU(AppPreferences.getSettings(), this, "settings");
        this.__safeBottom = this.createStorageLink(STORE_SAFE_BOTTOM, 0, "safeBottom");
        this.__currentBreakpoint = this.createStorageProp(BreakpointConstants.CURRENT_BREAKPOINT, BreakpointConstants.BREAKPOINT_SM, "currentBreakpoint");
        this.__sleepTimerEnd = this.createStorageLink(STORE_SLEEP_TIMER_END, 0, "sleepTimerEnd");
        this.__sleepRemainText = new ObservedPropertySimplePU('未开启', this, "sleepRemainText");
        this.__sheetKind = new ObservedPropertySimplePU('sleep', this, "sheetKind");
        this.__showSheet = new ObservedPropertySimplePU(false, this, "showSheet");
        this.sleepTicker = -1;
        this.__cacheText = new ObservedPropertySimplePU('计算中…', this, "cacheText");
        this.__downloadText = new ObservedPropertySimplePU('', this, "downloadText");
        this.__listenText = new ObservedPropertySimplePU('', this, "listenText");
        this.cacheDirPath = '';
        this.appCacheDirPath = '';
        this.downloadDirPath = '';
        this.__appVersion = new ObservedPropertySimplePU('', this, "appVersion");
        this.setInitiallyProvidedValue(params);
        this.declareWatch("sleepTimerEnd", this.onSleepTimerChanged);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: SettingsPage_Params) {
        if (params.settings !== undefined) {
            this.settings = params.settings;
        }
        if (params.sleepRemainText !== undefined) {
            this.sleepRemainText = params.sleepRemainText;
        }
        if (params.sheetKind !== undefined) {
            this.sheetKind = params.sheetKind;
        }
        if (params.showSheet !== undefined) {
            this.showSheet = params.showSheet;
        }
        if (params.sleepTicker !== undefined) {
            this.sleepTicker = params.sleepTicker;
        }
        if (params.cacheText !== undefined) {
            this.cacheText = params.cacheText;
        }
        if (params.downloadText !== undefined) {
            this.downloadText = params.downloadText;
        }
        if (params.listenText !== undefined) {
            this.listenText = params.listenText;
        }
        if (params.cacheDirPath !== undefined) {
            this.cacheDirPath = params.cacheDirPath;
        }
        if (params.appCacheDirPath !== undefined) {
            this.appCacheDirPath = params.appCacheDirPath;
        }
        if (params.downloadDirPath !== undefined) {
            this.downloadDirPath = params.downloadDirPath;
        }
        if (params.appVersion !== undefined) {
            this.appVersion = params.appVersion;
        }
    }
    updateStateVars(params: SettingsPage_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__settings.purgeDependencyOnElmtId(rmElmtId);
        this.__safeBottom.purgeDependencyOnElmtId(rmElmtId);
        this.__currentBreakpoint.purgeDependencyOnElmtId(rmElmtId);
        this.__sleepTimerEnd.purgeDependencyOnElmtId(rmElmtId);
        this.__sleepRemainText.purgeDependencyOnElmtId(rmElmtId);
        this.__sheetKind.purgeDependencyOnElmtId(rmElmtId);
        this.__showSheet.purgeDependencyOnElmtId(rmElmtId);
        this.__cacheText.purgeDependencyOnElmtId(rmElmtId);
        this.__downloadText.purgeDependencyOnElmtId(rmElmtId);
        this.__listenText.purgeDependencyOnElmtId(rmElmtId);
        this.__appVersion.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__settings.aboutToBeDeleted();
        this.__safeBottom.aboutToBeDeleted();
        this.__currentBreakpoint.aboutToBeDeleted();
        this.__sleepTimerEnd.aboutToBeDeleted();
        this.__sleepRemainText.aboutToBeDeleted();
        this.__sheetKind.aboutToBeDeleted();
        this.__showSheet.aboutToBeDeleted();
        this.__cacheText.aboutToBeDeleted();
        this.__downloadText.aboutToBeDeleted();
        this.__listenText.aboutToBeDeleted();
        this.__appVersion.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private __settings: ObservedPropertyObjectPU<AppSettings>;
    get settings() {
        return this.__settings.get();
    }
    set settings(newValue: AppSettings) {
        this.__settings.set(newValue);
    }
    /** 底部安全区高度（vp）：根容器不再统一避让，列表末尾让位要自己叠上这一份 */
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
    /**
     * 定时停止的到点时间戳（ms），0 = 未开启。
     * 播放内核只发布这个**结束时刻**，剩余量由本页本地 1s 现算，避免每秒写一次 AppStorage。
     */
    private __sleepTimerEnd: ObservedPropertyAbstractPU<number>;
    get sleepTimerEnd() {
        return this.__sleepTimerEnd.get();
    }
    set sleepTimerEnd(newValue: number) {
        this.__sleepTimerEnd.set(newValue);
    }
    private __sleepRemainText: ObservedPropertySimplePU<string>;
    get sleepRemainText() {
        return this.__sleepRemainText.get();
    }
    set sleepRemainText(newValue: string) {
        this.__sleepRemainText.set(newValue);
    }
    /**
     * 弹出的选择面板：'sleep'（定时停止）| 'quality'（下载音质）。
     *
     * 两者**共用同一个 bindSheet**：同一个组件上重复调用 bindSheet 只会保留最后一个，
     * 所以用一个开关 + 一个 kind 来切换内容，而不是绑两个 sheet。
     */
    private __sheetKind: ObservedPropertySimplePU<string>;
    get sheetKind() {
        return this.__sheetKind.get();
    }
    set sheetKind(newValue: string) {
        this.__sheetKind.set(newValue);
    }
    private __showSheet: ObservedPropertySimplePU<boolean>;
    get showSheet() {
        return this.__showSheet.get();
    }
    set showSheet(newValue: boolean) {
        this.__showSheet.set(newValue);
    }
    private sleepTicker: number;
    /** 缓存占用文案；已下载音频只做展示，不参与清理 */
    private __cacheText: ObservedPropertySimplePU<string>;
    get cacheText() {
        return this.__cacheText.get();
    }
    set cacheText(newValue: string) {
        this.__cacheText.set(newValue);
    }
    private __downloadText: ObservedPropertySimplePU<string>;
    get downloadText() {
        return this.__downloadText.get();
    }
    set downloadText(newValue: string) {
        this.__downloadText.set(newValue);
    }
    /** 累计听歌时长文案：进页时读一次偏好（计时在 MusicPlayer，播放中不实时刷新） */
    private __listenText: ObservedPropertySimplePU<string>;
    get listenText() {
        return this.__listenText.get();
    }
    set listenText(newValue: string) {
        this.__listenText.set(newValue);
    }
    private cacheDirPath: string;
    /** 应用级缓存目录（…/base/cache），与模块级 cacheDirPath 一起统计 */
    private appCacheDirPath: string;
    private downloadDirPath: string;
    /** 应用版本号（如「v1.0.2」）：从 bundleManager 读，跟着 app.json5 走，不在页面里写死 */
    private __appVersion: ObservedPropertySimplePU<string>;
    get appVersion() {
        return this.__appVersion.get();
    }
    set appVersion(newValue: string) {
        this.__appVersion.set(newValue);
    }
    aboutToAppear(): void {
        this.refreshSleepText();
        this.refreshCacheSize();
        this.listenText = formatListenDuration(AppPreferences.getTotalListenSeconds());
        this.loadAppVersion();
    }
    /** 读自身包信息取 versionName（即 app.json5 的 versionName，升级后自动同步） */
    private loadAppVersion(): void {
        bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
            .then((info: bundleManager.BundleInfo): void => {
            this.appVersion = info.versionName.length > 0 ? `v${info.versionName}` : '';
        })
            .catch((e: BusinessError): void => {
            // 拿不到就空着，不影响其它设置项
            console.error(`getBundleInfoForSelf failed: ${e.code} ${e.message}`);
        });
    }
    /**
     * 解析沙箱目录（只做一次）。
     *
     * 刻意不放在 aboutToAppear 里取 `getUIContext()`：那时 UIContext 未必已就绪。
     * 改在 refreshCacheSize 的 setTimeout 回调里获取，拿不到就下次再试（显示「不可用」，不崩）。
     */
    private resolveDirs(): boolean {
        if (this.cacheDirPath.length > 0) {
            return true;
        }
        try {
            const ctx = this.getUIContext().getHostContext() as common.Context;
            if (ctx) {
                // 模块级 cacheDir（…/haps/entry/cache）：本应用自己的缓存（含 Image 组件的 image_file_cache）
                this.cacheDirPath = ctx.cacheDir;
                // 应用级 cacheDir（…/base/cache）：ArkUI 框架的 preload_caches / blobShader / rawheap 等。
                // ⚠️ 实测这一层才是占用大头（可达上百 MB），只扫模块级会把缓存显示成 0 B。
                const appCtx = ctx.getApplicationContext();
                if (appCtx && appCtx.cacheDir !== this.cacheDirPath) {
                    this.appCacheDirPath = appCtx.cacheDir;
                }
                this.downloadDirPath = `${ctx.filesDir}/downloads`;
                return true;
            }
        }
        catch (e) {
            console.error('settings: resolve sandbox context failed');
        }
        return false;
    }
    aboutToDisappear(): void {
        this.stopSleepTicker();
    }
    private copySettings(s: AppSettings): AppSettings {
        return {
            sidebarState: s.sidebarState,
            playQuality: s.playQuality,
            downloadQuality: s.downloadQuality,
            downloadDir: s.downloadDir,
            autoPlay: s.autoPlay,
            showLyrics: s.showLyrics,
            wifiOnlyDownload: s.wifiOnlyDownload,
            wifiOnlyPlay: s.wifiOnlyPlay,
            themeMode: s.themeMode
        };
    }
    private update(mut: (s: AppSettings) => void): void {
        const next: AppSettings = this.copySettings(this.settings);
        mut(next);
        this.settings = next;
        AppPreferences.saveSettings(next);
    }
    private themeLabel(): string {
        if (this.settings.themeMode === ThemeMode.DARK) {
            return '深色';
        }
        if (this.settings.themeMode === ThemeMode.LIGHT) {
            return '浅色';
        }
        return '跟随系统';
    }
    private cycleTheme(): void {
        const order: ThemeMode[] = [ThemeMode.SYSTEM, ThemeMode.LIGHT, ThemeMode.DARK];
        const idx: number = order.indexOf(this.settings.themeMode);
        const next: ThemeMode = order[(idx + 1) % order.length];
        this.update((s: AppSettings): void => {
            s.themeMode = next;
        });
        // 只写偏好不生效：必须同步调 setColorMode 把模式真正应用到应用
        // （启动时的恢复逻辑在 EntryAbility，loadContent 首帧前）。
        const ctx = this.getUIContext().getHostContext();
        if (ctx) {
            AppPreferences.applyThemeMode(ctx, next);
        }
        this.toast(`主题：${this.themeLabel()}`, 1500);
    }
    onSleepTimerChanged(): void {
        this.refreshSleepText();
    }
    private refreshSleepText(): void {
        if (this.sleepTimerEnd <= 0) {
            this.sleepRemainText = '未开启';
            this.stopSleepTicker();
            return;
        }
        const remainMs: number = this.sleepTimerEnd - Date.now();
        if (remainMs <= 0) {
            this.sleepRemainText = '未开启';
            this.stopSleepTicker();
            return;
        }
        this.sleepRemainText = `剩余 ${formatRemain(Math.ceil(remainMs / 1000))}`;
        this.startSleepTicker();
    }
    private startSleepTicker(): void {
        if (this.sleepTicker !== -1) {
            return;
        }
        this.sleepTicker = setInterval((): void => {
            this.refreshSleepText();
        }, 1000);
    }
    private stopSleepTicker(): void {
        if (this.sleepTicker !== -1) {
            clearInterval(this.sleepTicker);
            this.sleepTicker = -1;
        }
    }
    private pickSleep(minutes: number): void {
        this.showSheet = false;
        // 计时器归播放内核单例持有：换页 / 重建本组件都不会丢定时
        MusicPlayer.getInstance().setSleepTimer(minutes);
        // 兜底刷新：取消定时时写入的 0 可能与旧值相同，@Watch 不会触发
        setTimeout((): void => {
            this.refreshSleepText();
        }, 0);
    }
    /**
     * 选中下载音质。只写偏好 —— 真正的取流档位由 DownloadManager 在每次任务开始时读取，
     * 所以**已在下载中的任务不会中途换档**（换档需要重新解析音源），要生效得重新下载。
     */
    private pickQuality(value: string): void {
        this.showSheet = false;
        this.update((s: AppSettings): void => {
            s.downloadQuality = value;
        });
        this.toast(`下载音质：${value}`, 1500);
    }
    private refreshCacheSize(): void {
        this.cacheText = '计算中…';
        // 递归统计是同步 IO，延后一拍再跑，避免拖住页签切换
        setTimeout((): void => {
            if (!this.resolveDirs()) {
                this.cacheText = '不可用';
                return;
            }
            // 两层缓存目录都统计：模块级（应用自己的）+ 应用级（ArkUI 框架的 shader / preload 等）
            const cacheBytes: number = dirSize(this.cacheDirPath) + dirSize(this.appCacheDirPath);
            const downloadBytes: number = dirSize(this.downloadDirPath);
            this.cacheText = formatBytes(cacheBytes);
            this.downloadText = downloadBytes > 0
                ? `已下载歌曲 ${formatBytes(downloadBytes)}（不受清理影响）`
                : '';
        }, 30);
    }
    private confirmClearCache(): void {
        try {
            this.getUIContext().getPromptAction().showDialog({
                title: '清理缓存',
                message: '将删除应用临时缓存文件。已下载的歌曲、歌单与播放记录不受影响。',
                buttons: [
                    { text: '取消', color: { "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } },
                    { text: '清理', color: { "id": 16777235, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } }
                ]
            }).then((result: promptAction.ShowDialogSuccessResponse): void => {
                if (result.index === 1) {
                    this.doClearCache();
                }
            }).catch((e: Error): void => {
                console.error(`clear cache dialog failed: ${e.message}`);
            });
        }
        catch (e) {
            console.error('show clear-cache dialog threw');
        }
    }
    private doClearCache(): void {
        // 两层缓存目录都清（只清内容、保留目录本身），清理后再刷新占用展示
        const removed: number = clearDirContents(this.cacheDirPath) + clearDirContents(this.appCacheDirPath);
        this.toast(removed > 0 ? `已清理 ${removed} 个缓存文件` : '没有需要清理的缓存', 1800);
        this.refreshCacheSize();
    }
    private toast(message: string, duration: number): void {
        showAppToast(message, duration);
    }
    /**
     * 底部面板入口：按 sheetKind 分发内容。
     * 必须走一层「无参 Builder」而不是给 bindSheet 传两个不同的 builder ——
     * 下面这层保持无参，也就顺带避开了「带参 @Builder 参数不随状态刷新」那个坑。
     */
    SheetContent(parent = null): void {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.sheetKind === 'quality') {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.QualitySheetContent.bind(this)();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                    this.SleepSheetContent.bind(this)();
                });
            }
        }, If);
        If.pop();
    }
    QualitySheetContent(parent = null): void {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.width('100%');
            Column.padding({ top: 16, bottom: 12 });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('下载音质');
            Text.fontSize(16);
            Text.fontWeight(FontWeight.Medium);
            Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('B 站只提供它已有的档位，个别视频最高只有 64 kbps');
            Text.fontSize(11);
            Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.margin({ top: 4 });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.width('100%');
            Column.margin({ top: 10 });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            ForEach.create();
            const forEachItemGenFunction = _item => {
                const opt = _item;
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Row.create();
                    Row.width('100%');
                    Row.padding({ left: 20, right: 20, top: 12, bottom: 12 });
                    ViewStackProcessor.visualState("pressed");
                    Row.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    ViewStackProcessor.visualState("normal");
                    Row.backgroundColor(Color.Transparent);
                    ViewStackProcessor.visualState();
                    Row.onClick((): void => {
                        this.pickQuality(opt.value);
                    });
                }, Row);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Column.create();
                    Column.alignItems(HorizontalAlign.Start);
                }, Column);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create(opt.value);
                    Text.fontSize(16);
                    Text.fontColor(this.settings.downloadQuality === opt.value ? { "id": 16777235, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create(opt.hint);
                    Text.fontSize(11);
                    Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.margin({ top: 3 });
                }, Text);
                Text.pop();
                Column.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Blank.create();
                    Blank.layoutWeight(1);
                }, Blank);
                Blank.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    If.create();
                    if (this.settings.downloadQuality === opt.value) {
                        this.ifElseBranchUpdateFunction(0, () => {
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Text.create('✓');
                                Text.fontSize(16);
                                Text.fontColor({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                            }, Text);
                            Text.pop();
                        });
                    }
                    else {
                        this.ifElseBranchUpdateFunction(1, () => {
                        });
                    }
                }, If);
                If.pop();
                Row.pop();
            };
            this.forEachUpdateFunction(elmtId, QUALITY_OPTIONS, forEachItemGenFunction, (opt: QualityOption): string => `quality_${opt.value}`, false, false);
        }, ForEach);
        ForEach.pop();
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Divider.create();
            Divider.color({ "id": 16777231, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Divider);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('已在下载中的任务不会中途换档，需重新下载才会生效');
            Text.fontSize(11);
            Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.margin({ top: 10, bottom: 4 });
        }, Text);
        Text.pop();
        Column.pop();
    }
    SleepSheetContent(parent = null): void {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.width('100%');
            Column.padding({ top: 16, bottom: 12 });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('定时停止播放');
            Text.fontSize(16);
            Text.fontWeight(FontWeight.Medium);
            Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.sleepTimerEnd > 0 ? `当前：${this.sleepRemainText}` : '当前未开启定时');
            Text.fontSize(13);
            Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.margin({ top: 4 });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.width('100%');
            Column.margin({ top: 10 });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            ForEach.create();
            const forEachItemGenFunction = _item => {
                const minutes = _item;
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Row.create();
                    Row.width('100%');
                    Row.padding({ left: 20, right: 20, top: 14, bottom: 14 });
                    Row.onClick((): void => {
                        this.pickSleep(minutes);
                    });
                }, Row);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create(formatSleepMinutes(minutes));
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                Row.pop();
            };
            this.forEachUpdateFunction(elmtId, SLEEP_OPTIONS, forEachItemGenFunction, (minutes: number): string => `sleep_${minutes}`, false, false);
        }, ForEach);
        ForEach.pop();
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Divider.create();
            Divider.color({ "id": 16777231, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Divider);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.width('100%');
            Row.padding({ left: 20, right: 20, top: 14, bottom: 14 });
            ViewStackProcessor.visualState("pressed");
            Row.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            ViewStackProcessor.visualState("normal");
            Row.backgroundColor(Color.Transparent);
            ViewStackProcessor.visualState();
            Row.onClick((): void => {
                if (this.sleepTimerEnd > 0) {
                    this.pickSleep(0);
                }
            });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('关闭定时');
            Text.fontSize(16);
            Text.fontColor(this.sleepTimerEnd > 0 ? { "id": 16777235, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 16777252, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Text);
        Text.pop();
        Row.pop();
        Column.pop();
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.width('100%');
            Column.height('100%');
            Column.backgroundColor({ "id": 16777232, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Column.bindSheet({ value: this.showSheet, changeEvent: newValue => { this.showSheet = newValue; } }, { builder: () => {
                    this.SheetContent.call(this);
                } }, {
                height: SheetSize.FIT_CONTENT,
                dragBar: true,
                showClose: false
            });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
            // 根 Column 默认水平居中对齐，包一层挂上限即可。
            Column.create();
            // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
            // 根 Column 默认水平居中对齐，包一层挂上限即可。
            Column.width('100%');
            // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
            // 根 Column 默认水平居中对齐，包一层挂上限即可。
            Column.height('100%');
            // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
            // 根 Column 默认水平居中对齐，包一层挂上限即可。
            Column.constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('设置');
            Text.fontSize(20);
            Text.fontWeight(FontWeight.Bold);
            Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.padding({ left: 16, top: 14, bottom: 10 });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            List.create();
            List.layoutWeight(1);
            List.contentEndOffset(CONTENT_END_OFFSET + this.safeBottom);
        }, List);
        {
            const itemCreation = (elmtId, isInitialRender) => {
                ViewStackProcessor.StartGetAccessRecordingFor(elmtId);
                ListItem.create(deepRenderFunction, true);
                if (!isInitialRender) {
                    ListItem.pop();
                }
                ViewStackProcessor.StopGetAccessRecording();
            };
            const itemCreation2 = (elmtId, isInitialRender) => {
                ListItem.create(deepRenderFunction, true);
            };
            const deepRenderFunction = (elmtId, isInitialRender) => {
                itemCreation(elmtId, isInitialRender);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Row.create();
                    Row.padding({ left: 16, right: 16, top: 14, bottom: 14 });
                }, Row);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('自动播放下一首');
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Blank.create();
                    Blank.layoutWeight(1);
                }, Blank);
                Blank.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Toggle.create({ type: ToggleType.Switch, isOn: this.settings.autoPlay });
                    Toggle.selectedColor({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Toggle.onChange((v: boolean): void => {
                        this.update((s: AppSettings): void => {
                            s.autoPlay = v;
                        });
                    });
                }, Toggle);
                Toggle.pop();
                Row.pop();
                ListItem.pop();
            };
            this.observeComponentCreation2(itemCreation2, ListItem);
            ListItem.pop();
        }
        {
            const itemCreation = (elmtId, isInitialRender) => {
                ViewStackProcessor.StartGetAccessRecordingFor(elmtId);
                ListItem.create(deepRenderFunction, true);
                if (!isInitialRender) {
                    ListItem.pop();
                }
                ViewStackProcessor.StopGetAccessRecording();
            };
            const itemCreation2 = (elmtId, isInitialRender) => {
                ListItem.create(deepRenderFunction, true);
            };
            const deepRenderFunction = (elmtId, isInitialRender) => {
                itemCreation(elmtId, isInitialRender);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Row.create();
                    Row.padding({ left: 16, right: 16, top: 14, bottom: 14 });
                }, Row);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('显示歌词');
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Blank.create();
                    Blank.layoutWeight(1);
                }, Blank);
                Blank.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Toggle.create({ type: ToggleType.Switch, isOn: this.settings.showLyrics });
                    Toggle.selectedColor({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Toggle.onChange((v: boolean): void => {
                        this.update((s: AppSettings): void => {
                            s.showLyrics = v;
                        });
                    });
                }, Toggle);
                Toggle.pop();
                Row.pop();
                ListItem.pop();
            };
            this.observeComponentCreation2(itemCreation2, ListItem);
            ListItem.pop();
        }
        {
            const itemCreation = (elmtId, isInitialRender) => {
                ViewStackProcessor.StartGetAccessRecordingFor(elmtId);
                ListItem.create(deepRenderFunction, true);
                if (!isInitialRender) {
                    ListItem.pop();
                }
                ViewStackProcessor.StopGetAccessRecording();
            };
            const itemCreation2 = (elmtId, isInitialRender) => {
                ListItem.create(deepRenderFunction, true);
            };
            const deepRenderFunction = (elmtId, isInitialRender) => {
                itemCreation(elmtId, isInitialRender);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Row.create();
                    Row.padding({ left: 16, right: 16, top: 14, bottom: 14 });
                }, Row);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Column.create();
                    Column.alignItems(HorizontalAlign.Start);
                }, Column);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('仅 WiFi 下载');
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('移动网络下先询问，避免消耗流量');
                    Text.fontSize(11);
                    Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.margin({ top: 3 });
                }, Text);
                Text.pop();
                Column.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Blank.create();
                    Blank.layoutWeight(1);
                }, Blank);
                Blank.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Toggle.create({ type: ToggleType.Switch, isOn: this.settings.wifiOnlyDownload });
                    Toggle.selectedColor({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Toggle.onChange((v: boolean): void => {
                        this.update((s: AppSettings): void => {
                            s.wifiOnlyDownload = v;
                        });
                        if (v) {
                            this.toast('已开启：移动网络下下载前会先询问', 1800);
                        }
                    });
                }, Toggle);
                Toggle.pop();
                Row.pop();
                ListItem.pop();
            };
            this.observeComponentCreation2(itemCreation2, ListItem);
            ListItem.pop();
        }
        {
            const itemCreation = (elmtId, isInitialRender) => {
                ViewStackProcessor.StartGetAccessRecordingFor(elmtId);
                ListItem.create(deepRenderFunction, true);
                if (!isInitialRender) {
                    ListItem.pop();
                }
                ViewStackProcessor.StopGetAccessRecording();
            };
            const itemCreation2 = (elmtId, isInitialRender) => {
                ListItem.create(deepRenderFunction, true);
            };
            const deepRenderFunction = (elmtId, isInitialRender) => {
                itemCreation(elmtId, isInitialRender);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Row.create();
                    Row.padding({ left: 16, right: 16, top: 14, bottom: 14 });
                }, Row);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Column.create();
                    Column.alignItems(HorizontalAlign.Start);
                }, Column);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('仅 WiFi 播放');
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('移动网络下不播放在线歌曲，本地已下载不受限');
                    Text.fontSize(11);
                    Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.margin({ top: 3 });
                }, Text);
                Text.pop();
                Column.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Blank.create();
                    Blank.layoutWeight(1);
                }, Blank);
                Blank.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Toggle.create({ type: ToggleType.Switch, isOn: this.settings.wifiOnlyPlay });
                    Toggle.selectedColor({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Toggle.onChange((v: boolean): void => {
                        this.update((s: AppSettings): void => {
                            s.wifiOnlyPlay = v;
                        });
                        if (v) {
                            this.toast('已开启：移动网络下将不播放在线歌曲', 1800);
                        }
                    });
                }, Toggle);
                Toggle.pop();
                Row.pop();
                ListItem.pop();
            };
            this.observeComponentCreation2(itemCreation2, ListItem);
            ListItem.pop();
        }
        {
            const itemCreation = (elmtId, isInitialRender) => {
                ViewStackProcessor.StartGetAccessRecordingFor(elmtId);
                ListItem.create(deepRenderFunction, true);
                if (!isInitialRender) {
                    ListItem.pop();
                }
                ViewStackProcessor.StopGetAccessRecording();
            };
            const itemCreation2 = (elmtId, isInitialRender) => {
                ListItem.create(deepRenderFunction, true);
            };
            const deepRenderFunction = (elmtId, isInitialRender) => {
                itemCreation(elmtId, isInitialRender);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Row.create();
                    Row.padding({ left: 16, right: 16, top: 14, bottom: 14 });
                    ViewStackProcessor.visualState("pressed");
                    Row.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    ViewStackProcessor.visualState("normal");
                    Row.backgroundColor(Color.Transparent);
                    ViewStackProcessor.visualState();
                    Row.onClick((): void => {
                        this.sheetKind = 'quality';
                        this.showSheet = true;
                    });
                }, Row);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Column.create();
                    Column.alignItems(HorizontalAlign.Start);
                }, Column);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('下载音质');
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('对已开始的任务不生效，重新下载才会换档');
                    Text.fontSize(11);
                    Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.margin({ top: 3 });
                }, Text);
                Text.pop();
                Column.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Blank.create();
                    Blank.layoutWeight(1);
                }, Blank);
                Blank.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create(this.settings.downloadQuality);
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                Row.pop();
                ListItem.pop();
            };
            this.observeComponentCreation2(itemCreation2, ListItem);
            ListItem.pop();
        }
        {
            const itemCreation = (elmtId, isInitialRender) => {
                ViewStackProcessor.StartGetAccessRecordingFor(elmtId);
                ListItem.create(deepRenderFunction, true);
                if (!isInitialRender) {
                    ListItem.pop();
                }
                ViewStackProcessor.StopGetAccessRecording();
            };
            const itemCreation2 = (elmtId, isInitialRender) => {
                ListItem.create(deepRenderFunction, true);
            };
            const deepRenderFunction = (elmtId, isInitialRender) => {
                itemCreation(elmtId, isInitialRender);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Row.create();
                    Row.padding({ left: 16, right: 16, top: 14, bottom: 14 });
                    ViewStackProcessor.visualState("pressed");
                    Row.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    ViewStackProcessor.visualState("normal");
                    Row.backgroundColor(Color.Transparent);
                    ViewStackProcessor.visualState();
                    Row.onClick((): void => {
                        this.cycleTheme();
                    });
                }, Row);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('主题');
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Blank.create();
                    Blank.layoutWeight(1);
                }, Blank);
                Blank.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create(this.themeLabel());
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                Row.pop();
                ListItem.pop();
            };
            this.observeComponentCreation2(itemCreation2, ListItem);
            ListItem.pop();
        }
        {
            const itemCreation = (elmtId, isInitialRender) => {
                ViewStackProcessor.StartGetAccessRecordingFor(elmtId);
                ListItem.create(deepRenderFunction, true);
                if (!isInitialRender) {
                    ListItem.pop();
                }
                ViewStackProcessor.StopGetAccessRecording();
            };
            const itemCreation2 = (elmtId, isInitialRender) => {
                ListItem.create(deepRenderFunction, true);
            };
            const deepRenderFunction = (elmtId, isInitialRender) => {
                itemCreation(elmtId, isInitialRender);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Row.create();
                    Row.padding({ left: 16, right: 16, top: 14, bottom: 14 });
                }, Row);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Column.create();
                    Column.alignItems(HorizontalAlign.Start);
                }, Column);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('累计听歌');
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('仅统计实际播放中的时间，暂停不计入');
                    Text.fontSize(11);
                    Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.margin({ top: 3 });
                }, Text);
                Text.pop();
                Column.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Blank.create();
                    Blank.layoutWeight(1);
                }, Blank);
                Blank.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create(this.listenText);
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                Row.pop();
                ListItem.pop();
            };
            this.observeComponentCreation2(itemCreation2, ListItem);
            ListItem.pop();
        }
        {
            const itemCreation = (elmtId, isInitialRender) => {
                ViewStackProcessor.StartGetAccessRecordingFor(elmtId);
                ListItem.create(deepRenderFunction, true);
                if (!isInitialRender) {
                    ListItem.pop();
                }
                ViewStackProcessor.StopGetAccessRecording();
            };
            const itemCreation2 = (elmtId, isInitialRender) => {
                ListItem.create(deepRenderFunction, true);
            };
            const deepRenderFunction = (elmtId, isInitialRender) => {
                itemCreation(elmtId, isInitialRender);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Row.create();
                    Row.padding({ left: 16, right: 16, top: 14, bottom: 14 });
                    ViewStackProcessor.visualState("pressed");
                    Row.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    ViewStackProcessor.visualState("normal");
                    Row.backgroundColor(Color.Transparent);
                    ViewStackProcessor.visualState();
                    Row.onClick((): void => {
                        this.sheetKind = 'sleep';
                        this.showSheet = true;
                    });
                }, Row);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('定时停止播放');
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Blank.create();
                    Blank.layoutWeight(1);
                }, Blank);
                Blank.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create(this.sleepRemainText);
                    Text.fontSize(16);
                    Text.fontColor(this.sleepTimerEnd > 0 ? { "id": 16777235, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                Row.pop();
                ListItem.pop();
            };
            this.observeComponentCreation2(itemCreation2, ListItem);
            ListItem.pop();
        }
        {
            const itemCreation = (elmtId, isInitialRender) => {
                ViewStackProcessor.StartGetAccessRecordingFor(elmtId);
                ListItem.create(deepRenderFunction, true);
                if (!isInitialRender) {
                    ListItem.pop();
                }
                ViewStackProcessor.StopGetAccessRecording();
            };
            const itemCreation2 = (elmtId, isInitialRender) => {
                ListItem.create(deepRenderFunction, true);
            };
            const deepRenderFunction = (elmtId, isInitialRender) => {
                itemCreation(elmtId, isInitialRender);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Column.create();
                    Column.width('100%');
                    Column.padding({ left: 16, right: 16, top: 14, bottom: 14 });
                    ViewStackProcessor.visualState("pressed");
                    Column.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    ViewStackProcessor.visualState("normal");
                    Column.backgroundColor(Color.Transparent);
                    ViewStackProcessor.visualState();
                    Column.onClick((): void => {
                        this.confirmClearCache();
                    });
                }, Column);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Row.create();
                    Row.width('100%');
                }, Row);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('缓存');
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Blank.create();
                    Blank.layoutWeight(1);
                }, Blank);
                Blank.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create(this.cacheText);
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                Row.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    If.create();
                    if (this.downloadText.length > 0) {
                        this.ifElseBranchUpdateFunction(0, () => {
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Text.create(this.downloadText);
                                Text.fontSize(11);
                                Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                Text.width('100%');
                                Text.margin({ top: 3 });
                            }, Text);
                            Text.pop();
                        });
                    }
                    else {
                        this.ifElseBranchUpdateFunction(1, () => {
                        });
                    }
                }, If);
                If.pop();
                Column.pop();
                ListItem.pop();
            };
            this.observeComponentCreation2(itemCreation2, ListItem);
            ListItem.pop();
        }
        {
            const itemCreation = (elmtId, isInitialRender) => {
                ViewStackProcessor.StartGetAccessRecordingFor(elmtId);
                ListItem.create(deepRenderFunction, true);
                if (!isInitialRender) {
                    ListItem.pop();
                }
                ViewStackProcessor.StopGetAccessRecording();
            };
            const itemCreation2 = (elmtId, isInitialRender) => {
                ListItem.create(deepRenderFunction, true);
            };
            const deepRenderFunction = (elmtId, isInitialRender) => {
                itemCreation(elmtId, isInitialRender);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('点击「缓存」一行即可清理临时缓存');
                    Text.fontSize(11);
                    Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.padding({ left: 16, right: 16, top: 6, bottom: 14 });
                }, Text);
                Text.pop();
                ListItem.pop();
            };
            this.observeComponentCreation2(itemCreation2, ListItem);
            ListItem.pop();
        }
        {
            const itemCreation = (elmtId, isInitialRender) => {
                ViewStackProcessor.StartGetAccessRecordingFor(elmtId);
                ListItem.create(deepRenderFunction, true);
                if (!isInitialRender) {
                    ListItem.pop();
                }
                ViewStackProcessor.StopGetAccessRecording();
            };
            const itemCreation2 = (elmtId, isInitialRender) => {
                ListItem.create(deepRenderFunction, true);
            };
            const deepRenderFunction = (elmtId, isInitialRender) => {
                itemCreation(elmtId, isInitialRender);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Row.create();
                    Row.padding({ left: 16, right: 16, top: 14, bottom: 14 });
                    ViewStackProcessor.visualState("pressed");
                    Row.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    ViewStackProcessor.visualState("normal");
                    Row.backgroundColor(Color.Transparent);
                    ViewStackProcessor.visualState();
                    Row.onClick((): void => {
                        NavStackHolder.stack.pushPath({ name: 'About' });
                    });
                }, Row);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('关于本项目');
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Blank.create();
                    Blank.layoutWeight(1);
                }, Blank);
                Blank.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create(this.appVersion);
                    Text.fontSize(16);
                    Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create('›');
                    Text.fontSize(18);
                    Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                }, Text);
                Text.pop();
                Row.pop();
                ListItem.pop();
            };
            this.observeComponentCreation2(itemCreation2, ListItem);
            ListItem.pop();
        }
        List.pop();
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
        // 根 Column 默认水平居中对齐，包一层挂上限即可。
        Column.pop();
        Column.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
