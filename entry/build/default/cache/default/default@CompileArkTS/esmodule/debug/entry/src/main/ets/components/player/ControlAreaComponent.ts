if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface ControlAreaComponent_Params {
    currentBreakpoint?: string;
    progress?: number;
    duration?: number;
    repeatMode?: RepeatMode;
    currentTrack?: Track | null;
    showQueueSheet?: boolean;
    dragging?: boolean;
    dragValue?: number;
    sliderValue?: number;
    trackScale?: number;
    player?: MusicPlayer;
}
import { RepeatMode } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
import type { Track } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
import { MusicPlayer } from "@normalized:N&&&entry/src/main/ets/player/MusicPlayer&";
import { QueueSheet, repeatLabelOf, modeIconOf, nextRepeatMode } from "@normalized:N&&&entry/src/main/ets/components/QueueSheet&";
import { StyleConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/StyleConstants&";
import { showAppToast } from "@normalized:N&&&entry/src/main/ets/components/AppToast&";
import { BreakpointConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/BreakpointConstants&";
import { PlayerConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/PlayerConstants&";
import { BreakpointType } from "@normalized:N&&&entry/src/main/ets/common/utils/BreakpointSystem&";
import { PlayButtonComponent } from "@normalized:N&&&entry/src/main/ets/components/player/PlayButtonComponent&";
import { BounceIconButton } from "@normalized:N&&&entry/src/main/ets/components/player/BounceIconButton&";
import { STORE_CURRENT_TRACK, STORE_PROGRESS, STORE_DURATION, STORE_REPEAT_MODE } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
function formatTime(totalSeconds: number): string {
    const s: number = Math.max(0, Math.floor(totalSeconds));
    const m: number = Math.floor(s / 60);
    const r: number = s % 60;
    return `${m}:${r < 10 ? '0' : ''}${r}`;
}
/** 切歌键（上一曲 / 下一曲）图标与圆底尺寸 */
const PREVNEXT_ICON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 26, md: 26, lg: 30 });
const PREVNEXT_BUTTON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 52, md: 52, lg: 60 });
/** 功能键（播放模式 / 播放列表）图标与圆底尺寸 */
const FUNC_ICON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 22, md: 22, lg: 26 });
const FUNC_BUTTON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 40, md: 40, lg: 46 });
/** 进度插值时长（ms）：STORE_PROGRESS 按 500ms 分桶推送，插值略长避免步进感 */
const PROGRESS_TWEEN_MS: number = 520;
/** 判定「大跳」的阈值（秒）：超过视为 seek / 切歌，直接落位不做扫动 */
const PROGRESS_JUMP_SEC: number = 2;
export class ControlAreaComponent extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__currentBreakpoint = this.createStorageProp(BreakpointConstants.CURRENT_BREAKPOINT, BreakpointConstants.BREAKPOINT_SM, "currentBreakpoint");
        this.__progress = this.createStorageLink(STORE_PROGRESS, 0, "progress");
        this.__duration = this.createStorageLink(STORE_DURATION, 0, "duration");
        this.__repeatMode = this.createStorageLink(STORE_REPEAT_MODE, RepeatMode.NONE, "repeatMode");
        this.__currentTrack = this.createStorageLink(STORE_CURRENT_TRACK, null, "currentTrack");
        this.__showQueueSheet = new ObservedPropertySimplePU(false, this, "showQueueSheet");
        this.__dragging = new ObservedPropertySimplePU(false, this, "dragging");
        this.__dragValue = new ObservedPropertySimplePU(0, this, "dragValue");
        this.__sliderValue = new ObservedPropertySimplePU(0, this, "sliderValue");
        this.__trackScale = new ObservedPropertySimplePU(1, this, "trackScale");
        this.player = MusicPlayer.getInstance();
        this.setInitiallyProvidedValue(params);
        this.declareWatch("progress", this.onProgressTick);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: ControlAreaComponent_Params) {
        if (params.showQueueSheet !== undefined) {
            this.showQueueSheet = params.showQueueSheet;
        }
        if (params.dragging !== undefined) {
            this.dragging = params.dragging;
        }
        if (params.dragValue !== undefined) {
            this.dragValue = params.dragValue;
        }
        if (params.sliderValue !== undefined) {
            this.sliderValue = params.sliderValue;
        }
        if (params.trackScale !== undefined) {
            this.trackScale = params.trackScale;
        }
        if (params.player !== undefined) {
            this.player = params.player;
        }
    }
    updateStateVars(params: ControlAreaComponent_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__currentBreakpoint.purgeDependencyOnElmtId(rmElmtId);
        this.__progress.purgeDependencyOnElmtId(rmElmtId);
        this.__duration.purgeDependencyOnElmtId(rmElmtId);
        this.__repeatMode.purgeDependencyOnElmtId(rmElmtId);
        this.__currentTrack.purgeDependencyOnElmtId(rmElmtId);
        this.__showQueueSheet.purgeDependencyOnElmtId(rmElmtId);
        this.__dragging.purgeDependencyOnElmtId(rmElmtId);
        this.__dragValue.purgeDependencyOnElmtId(rmElmtId);
        this.__sliderValue.purgeDependencyOnElmtId(rmElmtId);
        this.__trackScale.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__currentBreakpoint.aboutToBeDeleted();
        this.__progress.aboutToBeDeleted();
        this.__duration.aboutToBeDeleted();
        this.__repeatMode.aboutToBeDeleted();
        this.__currentTrack.aboutToBeDeleted();
        this.__showQueueSheet.aboutToBeDeleted();
        this.__dragging.aboutToBeDeleted();
        this.__dragValue.aboutToBeDeleted();
        this.__sliderValue.aboutToBeDeleted();
        this.__trackScale.aboutToBeDeleted();
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
    private __progress: ObservedPropertyAbstractPU<number>;
    get progress() {
        return this.__progress.get();
    }
    set progress(newValue: number) {
        this.__progress.set(newValue);
    }
    private __duration: ObservedPropertyAbstractPU<number>;
    get duration() {
        return this.__duration.get();
    }
    set duration(newValue: number) {
        this.__duration.set(newValue);
    }
    private __repeatMode: ObservedPropertyAbstractPU<RepeatMode>;
    get repeatMode() {
        return this.__repeatMode.get();
    }
    set repeatMode(newValue: RepeatMode) {
        this.__repeatMode.set(newValue);
    }
    private __currentTrack: ObservedPropertyAbstractPU<Track | null>;
    get currentTrack() {
        return this.__currentTrack.get();
    }
    set currentTrack(newValue: Track | null) {
        this.__currentTrack.set(newValue);
    }
    /** 队列弹层开关（本组件自持，bindSheet 挂在播放列表按钮上） */
    private __showQueueSheet: ObservedPropertySimplePU<boolean>;
    get showQueueSheet() {
        return this.__showQueueSheet.get();
    }
    set showQueueSheet(newValue: boolean) {
        this.__showQueueSheet.set(newValue);
    }
    /** 拖动隔离：拖动中滑块显示 dragValue，松手恢复跟随插值进度 */
    private __dragging: ObservedPropertySimplePU<boolean>;
    get dragging() {
        return this.__dragging.get();
    }
    set dragging(newValue: boolean) {
        this.__dragging.set(newValue);
    }
    private __dragValue: ObservedPropertySimplePU<number>;
    get dragValue() {
        return this.__dragValue.get();
    }
    set dragValue(newValue: number) {
        this.__dragValue.set(newValue);
    }
    /** 进度条平滑显示值（本动画独占）：播放中由 onProgressTick 插值驱动 */
    private __sliderValue: ObservedPropertySimplePU<number>;
    get sliderValue() {
        return this.__sliderValue.get();
    }
    set sliderValue(newValue: number) {
        this.__sliderValue.set(newValue);
    }
    /** 进度条拖拽反馈缩放（本动画独占） */
    private __trackScale: ObservedPropertySimplePU<number>;
    get trackScale() {
        return this.__trackScale.get();
    }
    set trackScale(newValue: number) {
        this.__trackScale.set(newValue);
    }
    private player: MusicPlayer;
    aboutToAppear(): void {
        this.sliderValue = this.progress;
    }
    /**
     * 进度写入（500ms 一次）→ 520ms 线性插值：animateTo 反复重定目标，
     * 滑块匀速连续推进而非半秒一跳；拖动中不插值（滑块跟手指）；
     * 大跳（seek / 切歌）duration 0 直接落位。
     */
    private onProgressTick(): void {
        if (this.dragging) {
            return;
        }
        const target: number = this.progress;
        const jump: number = Math.abs(target - this.sliderValue);
        const duration: number = jump > PROGRESS_JUMP_SEC ? 0 : PROGRESS_TWEEN_MS;
        this.getUIContext().animateTo({ duration: duration, curve: Curve.Linear }, (): void => {
            this.sliderValue = target;
        });
    }
    /** 拖拽开始：进度条轻微放大（独立 animateTo，不与插值共用通道） */
    private scaleUpTrack(): void {
        this.getUIContext().animateTo({ duration: 160, curve: Curve.EaseOut }, (): void => {
            this.trackScale = 1.04;
        });
    }
    /** 松手：先落位显示值，再关键帧回弹（轻微下探 → 回 1） */
    private bounceBackTrack(value: number): void {
        this.getUIContext().animateTo({ duration: 0 }, (): void => {
            this.sliderValue = value;
        });
        this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
            {
                duration: 0,
                event: (): void => {
                    this.trackScale = 1.04;
                }
            },
            {
                duration: 150,
                curve: Curve.EaseOut,
                event: (): void => {
                    this.trackScale = 0.99;
                }
            },
            {
                duration: 130,
                curve: Curve.EaseOut,
                event: (): void => {
                    this.trackScale = 1;
                }
            }
        ]);
    }
    /**
     * 生效总时长：AVPlayer 的 durationUpdate 在部分流上拿不到值，
     * 回退曲目自带时长，否则 max=0 时拖动手势按 0 换算、seek 永远是 0 秒。
     */
    private effectiveDuration(): number {
        if (this.duration > 0) {
            return this.duration;
        }
        return this.currentTrack !== null ? this.currentTrack.duration : 0;
    }
    /** 短提示：模式这种「图标变化不明显」的切换给一次文字反馈 */
    private toast(message: string): void {
        showAppToast(message);
    }
    private cycleRepeat(): void {
        const next: RepeatMode = nextRepeatMode(this.repeatMode);
        this.player.setRepeatMode(next);
        this.toast(`播放模式：${repeatLabelOf(next)}`);
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.width(StyleConstants.FULL_WIDTH);
            Row.justifyContent(FlexAlign.SpaceBetween);
        }, Row);
        {
            this.observeComponentCreation2((elmtId, isInitialRender) => {
                if (isInitialRender) {
                    let componentCall = new BounceIconButton(this, {
                        icon: modeIconOf(this.repeatMode),
                        iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
                        buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
                        onTap: (): void => {
                            this.cycleRepeat();
                        }
                    }, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/ControlAreaComponent.ets", line: 154, col: 9 });
                    ViewPU.create(componentCall);
                    let paramsLambda = () => {
                        return {
                            icon: modeIconOf(this.repeatMode),
                            iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
                            buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
                            onTap: (): void => {
                                this.cycleRepeat();
                            }
                        };
                    };
                    componentCall.paramsGenerator_ = paramsLambda;
                }
                else {
                    this.updateStateVarsOfChildByElmtId(elmtId, {
                        icon: modeIconOf(this.repeatMode)
                    });
                }
            }, { name: "BounceIconButton" });
        }
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            __Common__.create();
            __Common__.bindSheet({ value: this.showQueueSheet, changeEvent: newValue => { this.showQueueSheet = newValue; } }, { builder: () => {
                    this.QueueSheetHost.call(this);
                } }, {
                height: SheetSize.MEDIUM,
                dragBar: true,
                showClose: false
            });
        }, __Common__);
        {
            this.observeComponentCreation2((elmtId, isInitialRender) => {
                if (isInitialRender) {
                    let componentCall = new BounceIconButton(this, {
                        icon: { "id": 125831650, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                        iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
                        buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
                        onTap: (): void => {
                            this.showQueueSheet = true;
                        }
                    }, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/ControlAreaComponent.ets", line: 163, col: 9 });
                    ViewPU.create(componentCall);
                    let paramsLambda = () => {
                        return {
                            icon: { "id": 125831650, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
                            buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
                            onTap: (): void => {
                                this.showQueueSheet = true;
                            }
                        };
                    };
                    componentCall.paramsGenerator_ = paramsLambda;
                }
                else {
                    this.updateStateVarsOfChildByElmtId(elmtId, {
                        icon: { "id": 125831650, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                    });
                }
            }, { name: "BounceIconButton" });
        }
        __Common__.pop();
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.margin({
                top: { "id": 16777303, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                bottom: this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG ? { "id": 16777299, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 16777298, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
            });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Slider.create({
                min: 0,
                max: Math.max(1, this.effectiveDuration()),
                step: 1,
                style: SliderStyle.OutSet,
                value: this.dragging ? this.dragValue : this.sliderValue
            });
            Slider.selectedColor({ "id": 16777247, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Slider.trackColor({ "id": 16777248, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Slider.scale({ x: this.trackScale, y: this.trackScale });
            Slider.onChange((value: number, mode: SliderChangeMode): void => {
                if (mode === SliderChangeMode.Begin) {
                    // 按下：只动本地滑块并轻微放大，不写播放进度
                    this.dragging = true;
                    this.dragValue = value;
                    this.scaleUpTrack();
                    return;
                }
                if (mode === SliderChangeMode.Moving) {
                    this.dragValue = value;
                    return;
                }
                // 松手 / 点击定位：交给播放内核，进度条回弹
                this.dragging = false;
                if (this.effectiveDuration() > 0) {
                    this.player.seek(value);
                }
                this.bounceBackTrack(value);
            });
            Slider.height({ "id": 16777297, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Slider.margin({
                left: new BreakpointType<Resource>({
                    sm: { "id": 16777302, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                    md: { "id": 16777301, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                    lg: { "id": 16777300, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                }).getValue(this.currentBreakpoint),
                right: new BreakpointType<Resource>({
                    sm: { "id": 16777302, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                    md: { "id": 16777301, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                    lg: { "id": 16777300, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                }).getValue(this.currentBreakpoint)
            });
        }, Slider);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.width(StyleConstants.FULL_WIDTH);
            Row.justifyContent(FlexAlign.SpaceBetween);
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(formatTime(this.dragging ? this.dragValue : this.sliderValue));
            Text.fontColor({ "id": 16777238, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.fontSize({ "id": 16777296, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.fontFamily(PlayerConstants.FONT_FAMILY_BLACK);
            Text.lineHeight('14vp');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(formatTime(this.effectiveDuration()));
            Text.fontColor({ "id": 16777238, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.fontSize({ "id": 16777296, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.fontFamily(PlayerConstants.FONT_FAMILY_BLACK);
            Text.lineHeight('14vp');
        }, Text);
        Text.pop();
        Row.pop();
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.width(StyleConstants.FULL_WIDTH);
            Row.justifyContent(FlexAlign.SpaceBetween);
            Row.alignItems(VerticalAlign.Center);
            Row.padding({
                left: { "id": 16777262, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                right: { "id": 16777262, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
            });
        }, Row);
        {
            this.observeComponentCreation2((elmtId, isInitialRender) => {
                if (isInitialRender) {
                    let componentCall = new BounceIconButton(this, {
                        icon: { "id": 125831829, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                        iconSize: PREVNEXT_ICON_SIZE.getValue(this.currentBreakpoint),
                        buttonSize: PREVNEXT_BUTTON_SIZE.getValue(this.currentBreakpoint),
                        onTap: (): void => {
                            this.player.prev();
                        }
                    }, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/ControlAreaComponent.ets", line: 245, col: 9 });
                    ViewPU.create(componentCall);
                    let paramsLambda = () => {
                        return {
                            icon: { "id": 125831829, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            iconSize: PREVNEXT_ICON_SIZE.getValue(this.currentBreakpoint),
                            buttonSize: PREVNEXT_BUTTON_SIZE.getValue(this.currentBreakpoint),
                            onTap: (): void => {
                                this.player.prev();
                            }
                        };
                    };
                    componentCall.paramsGenerator_ = paramsLambda;
                }
                else {
                    this.updateStateVarsOfChildByElmtId(elmtId, {
                        icon: { "id": 125831829, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                    });
                }
            }, { name: "BounceIconButton" });
        }
        {
            this.observeComponentCreation2((elmtId, isInitialRender) => {
                if (isInitialRender) {
                    let componentCall = new PlayButtonComponent(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/ControlAreaComponent.ets", line: 254, col: 9 });
                    ViewPU.create(componentCall);
                    let paramsLambda = () => {
                        return {};
                    };
                    componentCall.paramsGenerator_ = paramsLambda;
                }
                else {
                    this.updateStateVarsOfChildByElmtId(elmtId, {});
                }
            }, { name: "PlayButtonComponent" });
        }
        {
            this.observeComponentCreation2((elmtId, isInitialRender) => {
                if (isInitialRender) {
                    let componentCall = new BounceIconButton(this, {
                        icon: { "id": 125831830, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                        iconSize: PREVNEXT_ICON_SIZE.getValue(this.currentBreakpoint),
                        buttonSize: PREVNEXT_BUTTON_SIZE.getValue(this.currentBreakpoint),
                        onTap: (): void => {
                            this.player.next();
                        }
                    }, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/ControlAreaComponent.ets", line: 256, col: 9 });
                    ViewPU.create(componentCall);
                    let paramsLambda = () => {
                        return {
                            icon: { "id": 125831830, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            iconSize: PREVNEXT_ICON_SIZE.getValue(this.currentBreakpoint),
                            buttonSize: PREVNEXT_BUTTON_SIZE.getValue(this.currentBreakpoint),
                            onTap: (): void => {
                                this.player.next();
                            }
                        };
                    };
                    componentCall.paramsGenerator_ = paramsLambda;
                }
                else {
                    this.updateStateVarsOfChildByElmtId(elmtId, {
                        icon: { "id": 125831830, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                    });
                }
            }, { name: "BounceIconButton" });
        }
        Row.pop();
        Column.pop();
    }
    /** 队列弹层宿主：bindSheet 只收 CustomBuilder，包一层共享 QueueSheet */
    QueueSheetHost(parent = null): void {
        {
            this.observeComponentCreation2((elmtId, isInitialRender) => {
                if (isInitialRender) {
                    let componentCall = new QueueSheet(this, { showSheet: this.__showQueueSheet }, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/ControlAreaComponent.ets", line: 278, col: 5 });
                    ViewPU.create(componentCall);
                    let paramsLambda = () => {
                        return {
                            showSheet: this.showQueueSheet
                        };
                    };
                    componentCall.paramsGenerator_ = paramsLambda;
                }
                else {
                    this.updateStateVarsOfChildByElmtId(elmtId, {});
                }
            }, { name: "QueueSheet" });
        }
    }
    rerender() {
        this.updateDirtyElements();
    }
}
