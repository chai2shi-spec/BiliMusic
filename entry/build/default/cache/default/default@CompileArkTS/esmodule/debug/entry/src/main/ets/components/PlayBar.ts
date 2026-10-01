if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface PlayBar_Params {
    queue?: Track[];
    currentTrack?: Track | null;
    isPlaying?: boolean;
    expanded?: boolean;
    currentBreakpoint?: string;
    rotateAngle?: number;
    miniPlayScale?: number;
    coverAnim?: AnimatorResult | null;
    /** 收起态点击封面请求重新展开（宿主回调 HdsTabsController.applyMiniBarStyle） */
    onExpandRequest?: () => void;
    player?: MusicPlayer;
}
import type { Track } from '../model/MusicModels';
import { MusicPlayer } from "@normalized:N&&&entry/src/main/ets/player/MusicPlayer&";
import { NavStackHolder } from "@normalized:N&&&entry/src/main/ets/service/NavStackHolder&";
import type { AnimatorOptions } from "@ohos:animator";
import type { AnimatorResult } from "@ohos:animator";
import { STORE_CURRENT_TRACK, STORE_IS_PLAYING, STORE_QUEUE, STORE_PLAYER_TRANSITIONING, STORE_MINI_BAR_EXPANDED, GEOMETRY_ID_PLAYER_DISC, PLAYER_TRANSITION_MS } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
import { BreakpointConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/BreakpointConstants&";
/** 展开态封面边长（胶囊内空间有限，比独立底栏小一号） */
const COVER_EXPANDED: number = 32;
const COVER_COLLAPSED: number = 40;
const CTRL_ICON_SIZE: number = 16;
/** 播放 / 暂停图标尺寸（略大作视觉锚点） */
const PLAY_ICON_SIZE: number = 20;
/** 控制键之间间距（收窄，为文字区让宽） */
const CTRL_SPACING: number = 8;
const DISC_ROTATE_DEGREE: number = 360;
const DISC_ROTATE_MS: number = 4000;
export class PlayBar extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__queue = this.createStorageLink(STORE_QUEUE, [], "queue");
        this.__currentTrack = this.createStorageLink(STORE_CURRENT_TRACK, null, "currentTrack");
        this.__isPlaying = this.createStorageLink(STORE_IS_PLAYING, false, "isPlaying");
        this.__expanded = this.createStorageProp(STORE_MINI_BAR_EXPANDED, false, "expanded");
        this.__currentBreakpoint = this.createStorageProp(BreakpointConstants.CURRENT_BREAKPOINT, BreakpointConstants.BREAKPOINT_SM, "currentBreakpoint");
        this.__rotateAngle = new ObservedPropertySimplePU(0, this, "rotateAngle");
        this.__miniPlayScale = new ObservedPropertySimplePU(1, this, "miniPlayScale");
        this.coverAnim = null;
        this.onExpandRequest = undefined;
        this.player = MusicPlayer.getInstance();
        this.setInitiallyProvidedValue(params);
        this.declareWatch("currentTrack", this.onTrackChanged);
        this.declareWatch("isPlaying", this.onPlayingChanged);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: PlayBar_Params) {
        if (params.rotateAngle !== undefined) {
            this.rotateAngle = params.rotateAngle;
        }
        if (params.miniPlayScale !== undefined) {
            this.miniPlayScale = params.miniPlayScale;
        }
        if (params.coverAnim !== undefined) {
            this.coverAnim = params.coverAnim;
        }
        if (params.onExpandRequest !== undefined) {
            this.onExpandRequest = params.onExpandRequest;
        }
        if (params.player !== undefined) {
            this.player = params.player;
        }
    }
    updateStateVars(params: PlayBar_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__queue.purgeDependencyOnElmtId(rmElmtId);
        this.__currentTrack.purgeDependencyOnElmtId(rmElmtId);
        this.__isPlaying.purgeDependencyOnElmtId(rmElmtId);
        this.__expanded.purgeDependencyOnElmtId(rmElmtId);
        this.__currentBreakpoint.purgeDependencyOnElmtId(rmElmtId);
        this.__rotateAngle.purgeDependencyOnElmtId(rmElmtId);
        this.__miniPlayScale.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__queue.aboutToBeDeleted();
        this.__currentTrack.aboutToBeDeleted();
        this.__isPlaying.aboutToBeDeleted();
        this.__expanded.aboutToBeDeleted();
        this.__currentBreakpoint.aboutToBeDeleted();
        this.__rotateAngle.aboutToBeDeleted();
        this.__miniPlayScale.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    /** 播放队列（歌单列表）：为空时内容不渲染 */
    private __queue: ObservedPropertyAbstractPU<Track[]>;
    get queue() {
        return this.__queue.get();
    }
    set queue(newValue: Track[]) {
        this.__queue.set(newValue);
    }
    /** 在播曲目（currentSong）：封面 / 歌名 / 歌手的数据源；@Watch 切歌时重置唱片角度 */
    private __currentTrack: ObservedPropertyAbstractPU<Track | null>;
    get currentTrack() {
        return this.__currentTrack.get();
    }
    set currentTrack(newValue: Track | null) {
        this.__currentTrack.set(newValue);
    }
    /** 播放中标志（isPlaying）：切换播放 / 暂停图标；@Watch 驱动唱片 play / pause */
    private __isPlaying: ObservedPropertyAbstractPU<boolean>;
    get isPlaying() {
        return this.__isPlaying.get();
    }
    set isPlaying(newValue: boolean) {
        this.__isPlaying.set(newValue);
    }
    /** miniBar 展开 / 收起态（Index 的 onBarStyleChange 写入，这里只读；默认折叠） */
    private __expanded: ObservedPropertyAbstractPU<boolean>;
    get expanded() {
        return this.__expanded.get();
    }
    set expanded(newValue: boolean) {
        this.__expanded.set(newValue);
    }
    /**
     * 当前断点：md/lg（HdsTabs 宽度 ≥600vp）下 HDS 强制展开迷你栏，
     * miniBarStyle / applyMiniBarStyle 全部失效（官方文档：仅宽度 <600vp 可设）。
     * 此时若全局展开态仍停在 false，收起内容（小圆盘）会渲染进展开槽位，
     * 点击走 onExpandRequest → applyMiniBarStyle(EXPAND) → 宽屏下无效 → 死胡同
     * —— 这是宽屏下唯一确定会「点了没反应」的路径（折叠屏点 miniBar 不跳转的
     * 头号嫌疑），因此 build() 里宽屏一律按展开态渲染、点击直达播放页。
     */
    private __currentBreakpoint: ObservedPropertyAbstractPU<string>;
    get currentBreakpoint() {
        return this.__currentBreakpoint.get();
    }
    set currentBreakpoint(newValue: string) {
        this.__currentBreakpoint.set(newValue);
    }
    /** 唱片当前旋转角度（°）：animator 每帧回写，暂停时冻结在当前值 */
    private __rotateAngle: ObservedPropertySimplePU<number>;
    get rotateAngle() {
        return this.__rotateAngle.get();
    }
    set rotateAngle(newValue: number) {
        this.__rotateAngle.set(newValue);
    }
    /** 迷你播放/暂停键的点击回弹缩放（独立状态，与唱片旋转互不相干） */
    private __miniPlayScale: ObservedPropertySimplePU<number>;
    get miniPlayScale() {
        return this.__miniPlayScale.get();
    }
    set miniPlayScale(newValue: number) {
        this.__miniPlayScale.set(newValue);
    }
    /** 唱片旋转 animator：play=续转 / pause=冻结 / reset=归零（aboutToAppear 里创建） */
    private coverAnim: AnimatorResult | null;
    /** 收起态点击封面请求重新展开（宿主回调 HdsTabsController.applyMiniBarStyle） */
    private onExpandRequest?: () => void;
    /** 播放内核单例：控制键只调它的现成方法，绝不另写播放器 */
    private player: MusicPlayer;
    /** 唱片旋转动画参数（创建与 reset 复用同一份配置） */
    private discOptions(): AnimatorOptions {
        return {
            duration: DISC_ROTATE_MS,
            easing: 'linear',
            delay: 0,
            fill: 'forwards',
            direction: 'normal',
            iterations: -1,
            begin: 0,
            end: DISC_ROTATE_DEGREE
        };
    }
    aboutToAppear(): void {
        // 诊断日志（折叠屏「点 miniBar 不跳转」排查）：确认挂载时的断点 / 展开态初值
        console.info(`[PlayBar] appear: bp=${this.currentBreakpoint}, expanded=${this.expanded}, playing=${this.isPlaying}`);
        // UIContext 在属性初始化时未就绪，animator 延迟到 here 创建（同 LrcView）
        try {
            this.coverAnim = this.getUIContext().createAnimator(this.discOptions());
            this.coverAnim.onFrame = (value: number): void => {
                this.rotateAngle = value;
            };
            // 挂载时可能已在播放中（isPlaying 初值即 true，@Watch 不会触发，需手动起转）
            if (this.isPlaying) {
                this.coverAnim.play();
            }
        }
        catch (e) {
            // animator 创建失败只影响唱片旋转，不影响播放控制
            const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
            console.error(`[PlayBar] createAnimator failed: ${msg}`);
        }
    }
    aboutToDisappear(): void {
        if (this.coverAnim !== null) {
            this.coverAnim.finish();
            this.coverAnim = null;
        }
    }
    /** 播放/暂停 → 唱片续转/冻结。pause 冻结在当前帧角度，绝不复位到 0 */
    private onPlayingChanged(): void {
        const anim: AnimatorResult | null = this.coverAnim;
        if (anim === null) {
            return;
        }
        if (this.isPlaying) {
            anim.play();
        }
        else {
            anim.pause();
        }
    }
    /** 切歌 → reset 归零角度（等价 Stopped），再按当前播放态决定是否重新起转 */
    private onTrackChanged(): void {
        const anim: AnimatorResult | null = this.coverAnim;
        if (anim === null) {
            return;
        }
        this.rotateAngle = 0;
        try {
            anim.reset(this.discOptions());
        }
        catch (e) {
            // reset 失败只影响切歌归零，不影响播放控制
            const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
            console.error(`[PlayBar] animator reset failed: ${msg}`);
            return;
        }
        if (this.isPlaying) {
            anim.play();
        }
    }
    private coverUrl(): string {
        return this.currentTrack !== null ? this.currentTrack.coverUrl : '';
    }
    /** 迷你播放键点击回弹：一次快速缩小回弹（一次性关键帧，无持续动画无定时器） */
    private bounceMiniPlay(): void {
        this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
            {
                duration: 0,
                event: (): void => {
                    this.miniPlayScale = 1;
                }
            },
            {
                duration: 80,
                curve: Curve.EaseIn,
                event: (): void => {
                    this.miniPlayScale = 0.82;
                }
            },
            {
                duration: 140,
                curve: Curve.EaseOut,
                event: (): void => {
                    this.miniPlayScale = 1.06;
                }
            },
            {
                duration: 80,
                curve: Curve.EaseOut,
                event: (): void => {
                    this.miniPlayScale = 1;
                }
            }
        ]);
    }
    /**
     * 跳转全屏播放页。
     *
     * 标记共享元素转场开始（PlayerPage 依赖该标志把唱片旋转延迟到转场结束），
     * 再在 animateTo 闭包内 pushPath —— 既驱动封面 geometryTransition 一镜到底，
     * 又保留转场动画供 PlayerPage 的 customTransition 升起动效使用。
     */
    private gotoPlayer(): void {
        // 诊断日志（折叠屏「点 miniBar 不跳转」排查）：能打出这行说明点击已送达展开态条目
        console.info(`[PlayBar] gotoPlayer: bp=${this.currentBreakpoint}, expanded=${this.expanded}`);
        AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, true);
        this.getUIContext().animateTo({ duration: PLAYER_TRANSITION_MS, curve: Curve.EaseInOut }, (): void => {
            NavStackHolder.stack.pushPath({ name: 'Player' });
        });
    }
    /** 展开：封面 + 歌名/歌手 + 三键控制，点条目进播放页（按钮点击不会冒泡成跳转） */
    ExpandedContent(parent = null): void {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create({ space: 8 });
            Row.width('100%');
            Row.height('100%');
            Row.alignItems(VerticalAlign.Center);
            Row.padding({ left: 8, right: 8 });
            Row.onClick((): void => {
                this.gotoPlayer();
            });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Image.create(this.coverUrl());
            Image.width(COVER_EXPANDED);
            Image.height(COVER_EXPANDED);
            Image.borderRadius(COVER_EXPANDED / 2);
            Image.objectFit(ImageFit.Cover);
            Image.rotate({ z: 1, angle: this.rotateAngle });
            Image.geometryTransition(GEOMETRY_ID_PLAYER_DISC);
        }, Image);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.alignItems(HorizontalAlign.Start);
            Column.layoutWeight(1);
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.currentTrack !== null ? this.currentTrack.title : '');
            Text.fontSize(12);
            Text.fontWeight(FontWeight.Medium);
            Text.fontColor({ "id": 125830982, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.maxLines(1);
            Text.textOverflow({ overflow: TextOverflow.Ellipsis });
            Text.width('100%');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.currentTrack !== null ? this.currentTrack.artist : '');
            Text.fontSize(10);
            Text.fontColor({ "id": 125830983, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.maxLines(1);
            Text.textOverflow({ overflow: TextOverflow.Ellipsis });
            Text.width('100%');
        }, Text);
        Text.pop();
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create({ space: CTRL_SPACING });
            Row.alignItems(VerticalAlign.Center);
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            SymbolGlyph.create({ "id": 125831829, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            SymbolGlyph.fontSize(CTRL_ICON_SIZE);
            SymbolGlyph.fontColor([{ "id": 125830991, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }]);
            ViewStackProcessor.visualState("pressed");
            SymbolGlyph.opacity(0.55);
            ViewStackProcessor.visualState("normal");
            SymbolGlyph.opacity(1);
            ViewStackProcessor.visualState();
            SymbolGlyph.onClick((): void => {
                this.player.prev();
            });
        }, SymbolGlyph);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            SymbolGlyph.create(this.isPlaying ? { "id": 125833393, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 125833254, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            SymbolGlyph.fontSize(PLAY_ICON_SIZE);
            SymbolGlyph.fontColor([{ "id": 125830991, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }]);
            SymbolGlyph.scale({ x: this.miniPlayScale, y: this.miniPlayScale });
            SymbolGlyph.onClick((): void => {
                this.player.togglePlay();
                this.bounceMiniPlay();
            });
        }, SymbolGlyph);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            SymbolGlyph.create({ "id": 125831830, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            SymbolGlyph.fontSize(CTRL_ICON_SIZE);
            SymbolGlyph.fontColor([{ "id": 125830991, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }]);
            ViewStackProcessor.visualState("pressed");
            SymbolGlyph.opacity(0.55);
            ViewStackProcessor.visualState("normal");
            SymbolGlyph.opacity(1);
            ViewStackProcessor.visualState();
            SymbolGlyph.onClick((): void => {
                this.player.next();
            });
        }, SymbolGlyph);
        Row.pop();
        Row.pop();
    }
    /** 收起：仅封面圆盘，点击经宿主回调重新展开（不直接进播放页，避免误触） */
    CollapsedContent(parent = null): void {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Stack.create();
            Stack.width('100%');
            Stack.height('100%');
            Stack.alignContent(Alignment.Center);
            ViewStackProcessor.visualState("pressed");
            Stack.opacity(0.85);
            ViewStackProcessor.visualState("normal");
            Stack.opacity(1);
            ViewStackProcessor.visualState();
            Stack.onClick((): void => {
                // 诊断日志（折叠屏排查）：走到这里说明收起态圆盘收到了点击（宽屏本不该出现）
                console.info(`[PlayBar] collapsed disc click: bp=${this.currentBreakpoint}, expanded=${this.expanded}`);
                if (this.onExpandRequest !== undefined) {
                    this.onExpandRequest();
                }
            });
        }, Stack);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Image.create(this.coverUrl());
            Image.width(COVER_COLLAPSED);
            Image.height(COVER_COLLAPSED);
            Image.borderRadius(COVER_COLLAPSED / 2);
            Image.objectFit(ImageFit.Cover);
            Image.rotate({ z: 1, angle: this.rotateAngle });
            Image.geometryTransition(GEOMETRY_ID_PLAYER_DISC);
        }, Image);
        Stack.pop();
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            // 边界：队列空 / 无在播曲目 → 不渲染（Index 侧同时会摘除 miniBar 槽位）
            if (this.queue.length > 0 && this.currentTrack !== null) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Row.create();
                        Row.width('100%');
                        Row.height('100%');
                    }, Row);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        If.create();
                        // 宽屏（md/lg）强制按展开态渲染：HDS 已把槽位固定为展开布局，全局状态
                        // 若还停在折叠（收起内容 + onExpandRequest 宽屏死胡同）必然点不动；
                        // 展开态点击直达播放页，与手机上的交互闭环保持一致。
                        if (this.expanded || this.currentBreakpoint !== BreakpointConstants.BREAKPOINT_SM) {
                            this.ifElseBranchUpdateFunction(0, () => {
                                this.ExpandedContent.bind(this)();
                            });
                        }
                        else {
                            this.ifElseBranchUpdateFunction(1, () => {
                                this.CollapsedContent.bind(this)();
                            });
                        }
                    }, If);
                    If.pop();
                    Row.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
