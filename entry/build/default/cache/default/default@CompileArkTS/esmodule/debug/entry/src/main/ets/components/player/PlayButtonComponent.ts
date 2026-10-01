if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface PlayButtonComponent_Params {
    currentBreakpoint?: string;
    isPlay?: boolean;
    playScaleX?: number;
    playScaleY?: number;
    breathGen?: number;
    breathTimer?: number;
    player?: MusicPlayer;
}
import { MusicPlayer } from "@normalized:N&&&entry/src/main/ets/player/MusicPlayer&";
import { BreakpointConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/BreakpointConstants&";
import { BreakpointType } from "@normalized:N&&&entry/src/main/ets/common/utils/BreakpointSystem&";
import { STORE_IS_PLAYING } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
/** 图标字号（沿用原控制区规格） */
const PLAY_ICON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 44, md: 44, lg: 52 });
/** 透明命中区直径（vp），不渲染底板 */
const PLAY_BUTTON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 64, md: 64, lg: 76 });
export class PlayButtonComponent extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__currentBreakpoint = this.createStorageProp(BreakpointConstants.CURRENT_BREAKPOINT, BreakpointConstants.BREAKPOINT_SM, "currentBreakpoint");
        this.__isPlay = this.createStorageLink(STORE_IS_PLAYING, false, "isPlay");
        this.__playScaleX = new ObservedPropertySimplePU(1, this, "playScaleX");
        this.__playScaleY = new ObservedPropertySimplePU(1, this, "playScaleY");
        this.breathGen = 0;
        this.breathTimer = -1;
        this.player = MusicPlayer.getInstance();
        this.setInitiallyProvidedValue(params);
        this.declareWatch("isPlay", this.onPlayingChanged);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: PlayButtonComponent_Params) {
        if (params.playScaleX !== undefined) {
            this.playScaleX = params.playScaleX;
        }
        if (params.playScaleY !== undefined) {
            this.playScaleY = params.playScaleY;
        }
        if (params.breathGen !== undefined) {
            this.breathGen = params.breathGen;
        }
        if (params.breathTimer !== undefined) {
            this.breathTimer = params.breathTimer;
        }
        if (params.player !== undefined) {
            this.player = params.player;
        }
    }
    updateStateVars(params: PlayButtonComponent_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__currentBreakpoint.purgeDependencyOnElmtId(rmElmtId);
        this.__isPlay.purgeDependencyOnElmtId(rmElmtId);
        this.__playScaleX.purgeDependencyOnElmtId(rmElmtId);
        this.__playScaleY.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__currentBreakpoint.aboutToBeDeleted();
        this.__isPlay.aboutToBeDeleted();
        this.__playScaleX.aboutToBeDeleted();
        this.__playScaleY.aboutToBeDeleted();
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
    private __isPlay: ObservedPropertyAbstractPU<boolean>;
    get isPlay() {
        return this.__isPlay.get();
    }
    set isPlay(newValue: boolean) {
        this.__isPlay.set(newValue);
    }
    /** 呼吸微形变：x/y 独立缩放 */
    private __playScaleX: ObservedPropertySimplePU<number>;
    get playScaleX() {
        return this.__playScaleX.get();
    }
    set playScaleX(newValue: number) {
        this.__playScaleX.set(newValue);
    }
    private __playScaleY: ObservedPropertySimplePU<number>;
    get playScaleY() {
        return this.__playScaleY.get();
    }
    set playScaleY(newValue: number) {
        this.__playScaleY.set(newValue);
    }
    /** 呼吸链调度代际与定时器句柄（销毁时清理） */
    private breathGen: number;
    private breathTimer: number;
    private player: MusicPlayer;
    aboutToAppear(): void {
        if (this.isPlay) {
            this.startBreathing();
        }
    }
    aboutToDisappear(): void {
        this.stopBreathing(false);
    }
    /** 播放态变化：播放开启呼吸；暂停立刻停形变并恢复标准尺寸 */
    onPlayingChanged(_propName: string): void {
        if (this.isPlay) {
            this.startBreathing();
        }
        else {
            this.stopBreathing(true);
        }
    }
    private startBreathing(): void {
        this.stopBreathing(false);
        const gen: number = ++this.breathGen;
        this.breathStep(gen);
    }
    private breathStep(gen: number): void {
        if (!this.isPlay || gen !== this.breathGen) {
            return;
        }
        const duration: number = 1600 + Math.floor(Math.random() * 1400);
        this.getUIContext().animateTo({ duration: duration, curve: Curve.EaseInOut }, (): void => {
            this.playScaleX = 0.97 + Math.random() * 0.06;
            this.playScaleY = 0.97 + Math.random() * 0.06;
        });
        this.breathTimer = setTimeout((): void => {
            this.breathTimer = -1;
            this.breathStep(gen);
        }, duration);
    }
    /**
     * 停止微形变。reset=true（暂停）：duration 0 动画**顶掉在途动画**，
     * 立刻恢复标准尺寸；reset=false 仅清链（重启前内部调度 / 销毁清理）。
     */
    private stopBreathing(reset: boolean): void {
        this.breathGen++;
        if (this.breathTimer !== -1) {
            clearTimeout(this.breathTimer);
            this.breathTimer = -1;
        }
        if (reset) {
            this.getUIContext().animateTo({ duration: 0 }, (): void => {
                this.playScaleX = 1;
                this.playScaleY = 1;
            });
        }
    }
    /** 点击反馈：一次快速缩小回弹 */
    private playTapBounce(): void {
        this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
            {
                duration: 0,
                event: (): void => {
                    this.playScaleX = 1;
                    this.playScaleY = 1;
                }
            },
            {
                duration: 120,
                curve: Curve.EaseIn,
                event: (): void => {
                    this.playScaleX = 0.88;
                    this.playScaleY = 0.88;
                }
            },
            {
                duration: 180,
                curve: Curve.EaseOut,
                event: (): void => {
                    this.playScaleX = 1.02;
                    this.playScaleY = 1.02;
                }
            },
            {
                duration: 100,
                curve: Curve.EaseOut,
                event: (): void => {
                    this.playScaleX = 1;
                    this.playScaleY = 1;
                }
            }
        ]);
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.width(PLAY_BUTTON_SIZE.getValue(this.currentBreakpoint));
            Column.height(PLAY_BUTTON_SIZE.getValue(this.currentBreakpoint));
            Column.scale({ x: this.playScaleX, y: this.playScaleY });
            Column.onClick((): void => {
                // 先翻转播放态（@Watch 停下/重启呼吸），再补一次点击回弹
                this.player.togglePlay();
                this.playTapBounce();
            });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            SymbolGlyph.create(this.isPlay ? { "id": 125833393, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 125833254, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            SymbolGlyph.fontSize(PLAY_ICON_SIZE.getValue(this.currentBreakpoint));
            SymbolGlyph.fontColor([Color.White]);
        }, SymbolGlyph);
        Column.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
