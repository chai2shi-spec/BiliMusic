if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface PlayerInfoComponent_Params {
    currentBreakpoint?: string;
    currentTrack?: Track | null;
    safeTop?: number;
    safeBottom?: number;
    imageColor?: string;
    bgCover?: PixelMap | string;
    isFoldFull?: boolean;
    lgDiscSize?: number;
    lgColW?: number;
    lgColH?: number;
    lgCtrlH?: number;
    coverCache?: image.PixelMap | undefined;
    coverCacheId?: string;
    colorToken?: number;
    foldCallback?: Callback<display.FoldDisplayMode>;
}
import effectKit from "@ohos:effectKit";
import image from "@ohos:multimedia.image";
import http from "@ohos:net.http";
import display from "@ohos:display";
import type common from "@ohos:app.ability.common";
import type { BusinessError } from "@ohos:base";
import type { Track } from '../../model/MusicModels';
import { PlayerConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/PlayerConstants&";
import { ColorConversion } from "@normalized:N&&&entry/src/main/ets/common/utils/ColorConversion&";
import { StyleConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/StyleConstants&";
import { BreakpointConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/BreakpointConstants&";
import { LyricsComponent } from "@normalized:N&&&entry/src/main/ets/components/player/LyricsComponent&";
import { TopAreaComponent } from "@normalized:N&&&entry/src/main/ets/components/player/TopAreaComponent&";
import { MusicInfoComponent } from "@normalized:N&&&entry/src/main/ets/components/player/MusicInfoComponent&";
import { ControlAreaComponent } from "@normalized:N&&&entry/src/main/ets/components/player/ControlAreaComponent&";
import { CoverDiscComponent } from "@normalized:N&&&entry/src/main/ets/components/player/CoverDiscComponent&";
import { STORE_CURRENT_TRACK, STORE_SAFE_TOP, STORE_SAFE_BOTTOM, STORE_PLAYER_BG_DARK, STORE_PLAYER_FOLD_FULL, BILI_REFERER } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
export class PlayerInfoComponent extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__currentBreakpoint = this.createStorageProp(BreakpointConstants.CURRENT_BREAKPOINT, BreakpointConstants.BREAKPOINT_SM, "currentBreakpoint");
        this.__currentTrack = this.createStorageLink(STORE_CURRENT_TRACK, null, "currentTrack");
        this.__safeTop = this.createStorageLink(STORE_SAFE_TOP, 0, "safeTop");
        this.__safeBottom = this.createStorageLink(STORE_SAFE_BOTTOM, 0, "safeBottom");
        this.__imageColor = new ObservedPropertySimplePU('rgba(0, 0, 2, 1.00)', this, "imageColor");
        this.__bgCover = new ObservedPropertyObjectPU('', this, "bgCover");
        this.__isFoldFull = new ObservedPropertySimplePU(false, this, "isFoldFull");
        this.__lgDiscSize = new ObservedPropertySimplePU(0, this, "lgDiscSize");
        this.lgColW = 0;
        this.lgColH = 0;
        this.lgCtrlH = 0;
        this.coverCache = undefined;
        this.coverCacheId = '';
        this.colorToken = 0;
        this.foldCallback = (data: display.FoldDisplayMode): void => {
            this.isFoldFull = data === display.FoldDisplayMode.FOLD_DISPLAY_MODE_FULL;
            AppStorage.setOrCreate(STORE_PLAYER_FOLD_FULL, this.isFoldFull);
        };
        this.setInitiallyProvidedValue(params);
        this.declareWatch("currentTrack", this.onTrackChanged);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: PlayerInfoComponent_Params) {
        if (params.imageColor !== undefined) {
            this.imageColor = params.imageColor;
        }
        if (params.bgCover !== undefined) {
            this.bgCover = params.bgCover;
        }
        if (params.isFoldFull !== undefined) {
            this.isFoldFull = params.isFoldFull;
        }
        if (params.lgDiscSize !== undefined) {
            this.lgDiscSize = params.lgDiscSize;
        }
        if (params.lgColW !== undefined) {
            this.lgColW = params.lgColW;
        }
        if (params.lgColH !== undefined) {
            this.lgColH = params.lgColH;
        }
        if (params.lgCtrlH !== undefined) {
            this.lgCtrlH = params.lgCtrlH;
        }
        if (params.coverCache !== undefined) {
            this.coverCache = params.coverCache;
        }
        if (params.coverCacheId !== undefined) {
            this.coverCacheId = params.coverCacheId;
        }
        if (params.colorToken !== undefined) {
            this.colorToken = params.colorToken;
        }
        if (params.foldCallback !== undefined) {
            this.foldCallback = params.foldCallback;
        }
    }
    updateStateVars(params: PlayerInfoComponent_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__currentBreakpoint.purgeDependencyOnElmtId(rmElmtId);
        this.__currentTrack.purgeDependencyOnElmtId(rmElmtId);
        this.__safeTop.purgeDependencyOnElmtId(rmElmtId);
        this.__safeBottom.purgeDependencyOnElmtId(rmElmtId);
        this.__imageColor.purgeDependencyOnElmtId(rmElmtId);
        this.__bgCover.purgeDependencyOnElmtId(rmElmtId);
        this.__isFoldFull.purgeDependencyOnElmtId(rmElmtId);
        this.__lgDiscSize.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__currentBreakpoint.aboutToBeDeleted();
        this.__currentTrack.aboutToBeDeleted();
        this.__safeTop.aboutToBeDeleted();
        this.__safeBottom.aboutToBeDeleted();
        this.__imageColor.aboutToBeDeleted();
        this.__bgCover.aboutToBeDeleted();
        this.__isFoldFull.aboutToBeDeleted();
        this.__lgDiscSize.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private __currentBreakpoint: ObservedPropertyAbstractPU<string>;
    get currentBreakpoint() {
        return this.__currentBreakpoint.get();
    }
    set currentBreakpoint(newValue: string) {
        this.__currentBreakpoint.set(newValue);
    }
    private __currentTrack: ObservedPropertyAbstractPU<Track | null>;
    get currentTrack() {
        return this.__currentTrack.get();
    }
    set currentTrack(newValue: Track | null) {
        this.__currentTrack.set(newValue);
    }
    private __safeTop: ObservedPropertyAbstractPU<number>;
    get safeTop() {
        return this.__safeTop.get();
    }
    set safeTop(newValue: number) {
        this.__safeTop.set(newValue);
    }
    private __safeBottom: ObservedPropertyAbstractPU<number>;
    get safeBottom() {
        return this.__safeBottom.get();
    }
    set safeBottom(newValue: number) {
        this.__safeBottom.set(newValue);
    }
    /** 沉浸背景主色（取自封面，取色失败保持默认深色） */
    private __imageColor: ObservedPropertySimplePU<string>;
    get imageColor() {
        return this.__imageColor.get();
    }
    set imageColor(newValue: string) {
        this.__imageColor.set(newValue);
    }
    /** 背景图：取色成功前显示原图，成功后换模糊图 */
    private __bgCover: ObservedPropertyObjectPU<PixelMap | string>;
    get bgCover() {
        return this.__bgCover.get();
    }
    set bgCover(newValue: PixelMap | string) {
        this.__bgCover.set(newValue);
    }
    private __isFoldFull: ObservedPropertySimplePU<boolean>;
    get isFoldFull() {
        return this.__isFoldFull.get();
    }
    set isFoldFull(newValue: boolean) {
        this.__isFoldFull.set(newValue);
    }
    /**
     * LG 分栏左列圆盘边长上限（vp）：0 = 首帧未实测（宽度驱动，实测后收敛）。
     * 与 MusicInfoComponent 同一套「高度预算」思路，防止矮屏（横屏平板）上
     * 宽度驱动的圆盘把控制区挤出屏幕底部。
     */
    private __lgDiscSize: ObservedPropertySimplePU<number>;
    get lgDiscSize() {
        return this.__lgDiscSize.get();
    }
    set lgDiscSize(newValue: number) {
        this.__lgDiscSize.set(newValue);
    }
    /** LG 左列 / 控制区实测尺寸（onAreaChange 回写） */
    private lgColW: number;
    private lgColH: number;
    private lgCtrlH: number;
    /** Area 尺寸（Length）→ vp 数值（资源型按 0 兜底） */
    private toVp(v: Length): number {
        if (typeof v === 'number') {
            return v;
        }
        if (typeof v === 'string') {
            return parseFloat(v);
        }
        return 0;
    }
    /** 圆盘边长 = min(左列宽, 左列高 − 控制区)；预算为负退回宽度驱动 */
    private recomputeLgDisc(): void {
        if (this.lgColW <= 0 || this.lgColH <= 0 || this.lgCtrlH <= 0) {
            return;
        }
        this.lgDiscSize = Math.min(this.lgColW, this.lgColH - this.lgCtrlH);
    }
    /** 封面 PixelMap 缓存（同曲复用，不重复下载） */
    private coverCache: image.PixelMap | undefined;
    private coverCacheId: string;
    /** 取色令牌：切歌后，在途的旧取色结果必须丢弃 */
    private colorToken: number;
    private foldCallback: Callback<display.FoldDisplayMode>;
    aboutToAppear(): void {
        this.onTrackChanged();
        try {
            if (canIUse('SystemCapability.Window.SessionManager')) {
                const mode: display.FoldDisplayMode = display.getFoldDisplayMode();
                this.isFoldFull = mode === display.FoldDisplayMode.FOLD_DISPLAY_MODE_FULL;
                AppStorage.setOrCreate(STORE_PLAYER_FOLD_FULL, this.isFoldFull);
                display.on('foldDisplayModeChange', this.foldCallback);
            }
        }
        catch (e) {
            console.error(`Failed to register fold callback: ${JSON.stringify(e)}`);
        }
    }
    aboutToDisappear(): void {
        try {
            if (canIUse('SystemCapability.Window.SessionManager')) {
                display.off('foldDisplayModeChange', this.foldCallback);
            }
        }
        catch (e) {
            console.error(`Failed to unregister fold callback: ${JSON.stringify(e)}`);
        }
    }
    onTrackChanged(): void {
        const track: Track | null = this.currentTrack;
        if (track === null || track.coverUrl.length === 0) {
            this.colorToken++;
            this.bgCover = '';
            this.imageColor = 'rgba(0, 0, 2, 1.00)';
            AppStorage.setOrCreate(STORE_PLAYER_BG_DARK, true);
            this.applyStatusBar(true);
            return;
        }
        // 先立刻铺原图，取色完成后再换成「主色底 + 模糊图」
        this.bgCover = track.coverUrl;
        this.applyTheme(track);
    }
    /** 取主色 + 生成模糊背景（异步，令牌防串台） */
    private async applyTheme(track: Track): Promise<void> {
        const token: number = ++this.colorToken;
        let pixel: image.PixelMap | undefined = undefined;
        if (this.coverCacheId === track.id && this.coverCache !== undefined) {
            pixel = this.coverCache;
        }
        else {
            const loaded: image.PixelMap | null = await this.loadCoverPixelMap(track.coverUrl);
            if (loaded === null) {
                return;
            }
            this.coverCache = loaded;
            this.coverCacheId = track.id;
            pixel = loaded;
        }
        if (token !== this.colorToken) {
            return;
        }
        // 主色 → 调暗做底色；明度写入全局（顶栏图标 / 状态栏内容色消费）
        effectKit.createColorPicker(pixel)
            .then((picker: effectKit.ColorPicker): void => {
            if (token !== this.colorToken) {
                return;
            }
            const color: effectKit.Color = picker.getLargestProportionColor();
            const arr: number[] = ColorConversion.dealColor(color.red, color.green, color.blue);
            this.imageColor = `rgba(${arr[0]}, ${arr[1]}, ${arr[2]}, 1)`;
            const luminance: number = (0.299 * arr[0] + 0.587 * arr[1] + 0.114 * arr[2]) / 255;
            const isDark: boolean = luminance < 0.5;
            AppStorage.setOrCreate(STORE_PLAYER_BG_DARK, isDark);
            this.applyStatusBar(isDark);
        })
            .catch((e: BusinessError): void => {
            console.error(`createColorPicker failed: ${e.code} ${e.message}`);
        });
        const headFilter: effectKit.Filter | null = effectKit.createEffect(pixel);
        if (headFilter !== null) {
            headFilter.blur(PlayerConstants.IMAGE_BLUR);
            headFilter.getEffectPixelMap()
                .then((blurred: image.PixelMap): void => {
                if (token !== this.colorToken) {
                    return;
                }
                this.bgCover = blurred;
            })
                .catch((e: BusinessError): void => {
                console.error(`blur cover failed: ${e.code} ${e.message}`);
            });
        }
    }
    /** 网络封面 → PixelMap（B 站图床要带 Referer，同 MusicPlayer 的实现） */
    private async loadCoverPixelMap(url: string): Promise<image.PixelMap | null> {
        const httpReq: http.HttpRequest = http.createHttp();
        try {
            const resp: http.HttpResponse = await httpReq.request(url, {
                method: http.RequestMethod.GET,
                header: { Referer: BILI_REFERER },
                connectTimeout: 10000,
                readTimeout: 10000,
                expectDataType: http.HttpDataType.ARRAY_BUFFER
            });
            if (resp.responseCode !== 200 || !resp.result) {
                return null;
            }
            if (!(resp.result instanceof ArrayBuffer)) {
                return null;
            }
            const src: image.ImageSource = image.createImageSource(resp.result);
            return await src.createPixelMap();
        }
        catch (e) {
            console.error(`loadCoverPixelMap failed: ${JSON.stringify(e)}`);
            return null;
        }
        finally {
            httpReq.destroy();
        }
    }
    /** 状态栏内容色随背景明暗切换（全屏布局下状态栏叠在背景上） */
    private applyStatusBar(isDarkBackground: boolean): void {
        const ctx: common.Context | undefined = this.getUIContext().getHostContext();
        if (ctx === undefined) {
            return;
        }
        ColorConversion.setStatusBarContentColor(ctx, isDarkBackground);
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Stack.create();
            Stack.height(StyleConstants.FULL_HEIGHT);
            Stack.width(StyleConstants.FULL_WIDTH);
            Stack.backgroundColor(this.imageColor);
        }, Stack);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.bgCover !== '') {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Image.create(this.bgCover);
                        Image.width(StyleConstants.FULL_WIDTH);
                        Image.height(StyleConstants.FULL_HEIGHT);
                        Image.objectFit(ImageFit.Cover);
                        Image.opacity(0.5);
                    }, Image);
                });
            }
            // 缓慢渐变底色：主色底上自上而下压深，底部最暗 —— 静态渐变不产生每帧开销
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 缓慢渐变底色：主色底上自上而下压深，底部最暗 —— 静态渐变不产生每帧开销
            Column.create();
            // 缓慢渐变底色：主色底上自上而下压深，底部最暗 —— 静态渐变不产生每帧开销
            Column.width(StyleConstants.FULL_WIDTH);
            // 缓慢渐变底色：主色底上自上而下压深，底部最暗 —— 静态渐变不产生每帧开销
            Column.height(StyleConstants.FULL_HEIGHT);
            // 缓慢渐变底色：主色底上自上而下压深，底部最暗 —— 静态渐变不产生每帧开销
            Column.linearGradient({
                angle: 180,
                colors: [
                    ['rgba(0, 0, 0, 0.05)', 0.0],
                    ['rgba(0, 0, 0, 0.22)', 0.45],
                    ['rgba(0, 0, 0, 0.45)', 1.0]
                ]
            });
        }, Column);
        // 缓慢渐变底色：主色底上自上而下压深，底部最暗 —— 静态渐变不产生每帧开销
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 微弱噪点纹理：打破纯色渐变的塑料感，低透明度平铺，无逐帧成本
            Column.create();
            // 微弱噪点纹理：打破纯色渐变的塑料感，低透明度平铺，无逐帧成本
            Column.width(StyleConstants.FULL_WIDTH);
            // 微弱噪点纹理：打破纯色渐变的塑料感，低透明度平铺，无逐帧成本
            Column.height(StyleConstants.FULL_HEIGHT);
            // 微弱噪点纹理：打破纯色渐变的塑料感，低透明度平铺，无逐帧成本
            Column.backgroundImage({ "id": 16777312, "type": 20000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }, ImageRepeat.XY);
            // 微弱噪点纹理：打破纯色渐变的塑料感，低透明度平铺，无逐帧成本
            Column.backgroundImageSize({ width: 128, height: 128 });
            // 微弱噪点纹理：打破纯色渐变的塑料感，低透明度平铺，无逐帧成本
            Column.opacity(0.05);
        }, Column);
        // 微弱噪点纹理：打破纯色渐变的塑料感，低透明度平铺，无逐帧成本
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.padding({
                top: this.safeTop,
                bottom: this.safeBottom
            });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.isFoldFull) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.layoutWeight(1);
                        Column.padding({
                            left: { "id": 16777259, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            right: { "id": 16777259, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        });
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        __Common__.create();
                        __Common__.margin({
                            bottom: { "id": 16777288, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            left: { "id": 16777309, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        });
                    }, __Common__);
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new TopAreaComponent(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/PlayerInfoComponent.ets", line: 252, col: 13 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {};
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {});
                            }
                        }, { name: "TopAreaComponent" });
                    }
                    __Common__.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        GridRow.create({
                            columns: { md: BreakpointConstants.COLUMN_MD },
                            gutter: BreakpointConstants.GUTTER_MUSIC_X
                        });
                        GridRow.layoutWeight(1);
                        GridRow.margin({
                            bottom: { "id": 16777267, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        });
                    }, GridRow);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        GridCol.create({
                            span: { md: BreakpointConstants.SPAN_SM }
                        });
                        GridCol.margin({
                            left: { "id": 16777285, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            right: { "id": 16777285, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        });
                    }, GridCol);
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new MusicInfoComponent(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/PlayerInfoComponent.ets", line: 264, col: 17 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {};
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {});
                            }
                        }, { name: "MusicInfoComponent" });
                    }
                    GridCol.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        GridCol.create({
                            span: { md: BreakpointConstants.SPAN_SM }
                        });
                        GridCol.padding({
                            left: { "id": 16777310, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        });
                    }, GridCol);
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new LyricsComponent(this, { isShowControl: false }, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/PlayerInfoComponent.ets", line: 274, col: 17 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {
                                        isShowControl: false
                                    };
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {});
                            }
                        }, { name: "LyricsComponent" });
                    }
                    GridCol.pop();
                    GridRow.pop();
                    Column.pop();
                });
            }
            else if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG) {
                this.ifElseBranchUpdateFunction(1, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        __Common__.create();
                        __Common__.padding({
                            left: { "id": 16777259, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            right: { "id": 16777259, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        });
                    }, __Common__);
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new TopAreaComponent(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/PlayerInfoComponent.ets", line: 292, col: 13 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {};
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {});
                            }
                        }, { name: "TopAreaComponent" });
                    }
                    __Common__.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        GridRow.create({
                            columns: { md: BreakpointConstants.COLUMN_MD, lg: BreakpointConstants.COLUMN_LG },
                            gutter: BreakpointConstants.GUTTER_MUSIC_X
                        });
                        GridRow.layoutWeight(1);
                        GridRow.padding({
                            left: { "id": 16777259, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            right: { "id": 16777259, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            top: { "id": 16777278, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            bottom: { "id": 16777277, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        });
                    }, GridRow);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        GridCol.create({
                            span: { md: BreakpointConstants.SPAN_SM, lg: BreakpointConstants.SPAN_SM },
                            offset: { lg: BreakpointConstants.OFFSET_MD }
                        });
                    }, GridCol);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.height(StyleConstants.FULL_HEIGHT);
                        Column.justifyContent(FlexAlign.SpaceBetween);
                        Column.margin({
                            bottom: { "id": 16777258, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        });
                        Column.onAreaChange((_old: Area, n: Area): void => {
                            this.lgColW = this.toVp(n.width);
                            this.lgColH = this.toVp(n.height);
                            this.recomputeLgDisc();
                        });
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Row.create();
                        Row.width(StyleConstants.FULL_WIDTH);
                        Row.justifyContent(FlexAlign.Center);
                    }, Row);
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new CoverDiscComponent(this, { discSize: this.lgDiscSize }, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/PlayerInfoComponent.ets", line: 307, col: 21 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {
                                        discSize: this.lgDiscSize
                                    };
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {
                                    discSize: this.lgDiscSize
                                });
                            }
                        }, { name: "CoverDiscComponent" });
                    }
                    Row.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.onAreaChange((_old: Area, n: Area): void => {
                            this.lgCtrlH = this.toVp(n.height);
                            this.recomputeLgDisc();
                        });
                    }, Column);
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new ControlAreaComponent(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/PlayerInfoComponent.ets", line: 313, col: 21 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {};
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {});
                            }
                        }, { name: "ControlAreaComponent" });
                    }
                    Column.pop();
                    Column.pop();
                    GridCol.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        GridCol.create({
                            span: { md: BreakpointConstants.SPAN_SM, lg: BreakpointConstants.SPAN_MD },
                            offset: { lg: BreakpointConstants.OFFSET_MD }
                        });
                    }, GridCol);
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new LyricsComponent(this, { isShowControl: false }, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/PlayerInfoComponent.ets", line: 336, col: 17 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {
                                        isShowControl: false
                                    };
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {});
                            }
                        }, { name: "LyricsComponent" });
                    }
                    GridCol.pop();
                    GridRow.pop();
                    Column.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(2, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Stack.create({ alignContent: Alignment.TopStart });
                        Stack.height(StyleConstants.FULL_HEIGHT);
                    }, Stack);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Swiper.create();
                        Swiper.height(StyleConstants.FULL_HEIGHT);
                        Swiper.indicator(new DotIndicator()
                            .top({ "id": 16777290, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" })
                            .selectedColor({ "id": 16777244, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" })
                            .color({ "id": 16777248, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }));
                        Swiper.clip(false);
                        Swiper.loop(false);
                    }, Swiper);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        __Common__.create();
                        __Common__.margin({
                            top: { "id": 16777287, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            bottom: { "id": 16777286, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        });
                        __Common__.padding({
                            left: { "id": 16777259, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            right: { "id": 16777259, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        });
                    }, __Common__);
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new MusicInfoComponent(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/PlayerInfoComponent.ets", line: 350, col: 15 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {};
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {});
                            }
                        }, { name: "MusicInfoComponent" });
                    }
                    __Common__.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        __Common__.create();
                        __Common__.margin({
                            top: { "id": 16777284, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        });
                        __Common__.padding({
                            left: { "id": 16777259, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            right: { "id": 16777259, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        });
                    }, __Common__);
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new LyricsComponent(this, { isShowControl: true }, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/PlayerInfoComponent.ets", line: 359, col: 15 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {
                                        isShowControl: true
                                    };
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {});
                            }
                        }, { name: "LyricsComponent" });
                    }
                    __Common__.pop();
                    Swiper.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        __Common__.create();
                        __Common__.padding({
                            left: { "id": 16777259, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            right: { "id": 16777259, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        });
                    }, __Common__);
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new TopAreaComponent(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/PlayerInfoComponent.ets", line: 378, col: 13 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {};
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {});
                            }
                        }, { name: "TopAreaComponent" });
                    }
                    __Common__.pop();
                    Stack.pop();
                });
            }
        }, If);
        If.pop();
        Row.pop();
        Stack.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
