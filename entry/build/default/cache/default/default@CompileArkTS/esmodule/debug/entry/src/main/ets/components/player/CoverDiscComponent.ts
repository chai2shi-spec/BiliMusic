if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface CoverDiscComponent_Params {
    currentTrack?: Track | null;
    isPlay?: boolean;
    discSize?: number;
    rotateAngle?: number;
    haloScale?: number;
    haloOpacity?: number;
    coverAnim?: AnimatorResult | null;
    haloGen?: number;
    haloTimer?: number;
}
import type { AnimatorOptions } from "@ohos:animator";
import type { AnimatorResult } from "@ohos:animator";
import type { Track } from '../../model/MusicModels';
import { GEOMETRY_ID_PLAYER_DISC, STORE_CURRENT_TRACK, STORE_IS_PLAYING } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
/** 大封面转速：20s 一圈（小圆盘 PlayBar 是 4s/圈，大封面放缓更克制） */
const COVER_ROTATE_MS: number = 20000;
const COVER_ROTATE_DEGREE: number = 360;
/** discSize 未指定（0）时的钳制哨兵：远大于任何真实列宽，等效不钳制 */
const DISC_CAP_UNLIMITED: number = 100000;
export class CoverDiscComponent extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__currentTrack = this.createStorageLink(STORE_CURRENT_TRACK, null, "currentTrack");
        this.__isPlay = this.createStorageLink(STORE_IS_PLAYING, false, "isPlay");
        this.__discSize = new SynchedPropertySimpleOneWayPU(params.discSize, this, "discSize");
        this.__rotateAngle = new ObservedPropertySimplePU(0, this, "rotateAngle");
        this.__haloScale = new ObservedPropertySimplePU(1, this, "haloScale");
        this.__haloOpacity = new ObservedPropertySimplePU(0.7, this, "haloOpacity");
        this.coverAnim = null;
        this.haloGen = 0;
        this.haloTimer = -1;
        this.setInitiallyProvidedValue(params);
        this.declareWatch("currentTrack", this.onTrackChanged);
        this.declareWatch("isPlay", this.onPlayingChanged);
        this.declareWatch("discSize", this.onDiscSizeChanged);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: CoverDiscComponent_Params) {
        if (params.discSize === undefined) {
            this.__discSize.set(0);
        }
        if (params.rotateAngle !== undefined) {
            this.rotateAngle = params.rotateAngle;
        }
        if (params.haloScale !== undefined) {
            this.haloScale = params.haloScale;
        }
        if (params.haloOpacity !== undefined) {
            this.haloOpacity = params.haloOpacity;
        }
        if (params.coverAnim !== undefined) {
            this.coverAnim = params.coverAnim;
        }
        if (params.haloGen !== undefined) {
            this.haloGen = params.haloGen;
        }
        if (params.haloTimer !== undefined) {
            this.haloTimer = params.haloTimer;
        }
    }
    updateStateVars(params: CoverDiscComponent_Params) {
        this.__discSize.reset(params.discSize);
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__currentTrack.purgeDependencyOnElmtId(rmElmtId);
        this.__isPlay.purgeDependencyOnElmtId(rmElmtId);
        this.__discSize.purgeDependencyOnElmtId(rmElmtId);
        this.__rotateAngle.purgeDependencyOnElmtId(rmElmtId);
        this.__haloScale.purgeDependencyOnElmtId(rmElmtId);
        this.__haloOpacity.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__currentTrack.aboutToBeDeleted();
        this.__isPlay.aboutToBeDeleted();
        this.__discSize.aboutToBeDeleted();
        this.__rotateAngle.aboutToBeDeleted();
        this.__haloScale.aboutToBeDeleted();
        this.__haloOpacity.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private __currentTrack: ObservedPropertyAbstractPU<Track | null>;
    get currentTrack() {
        return this.__currentTrack.get();
    }
    set currentTrack(newValue: Track | null) {
        this.__currentTrack.set(newValue);
    }
    private __isPlay: ObservedPropertyAbstractPU<boolean>;
    get isPlay() {
        return this.__isPlay.get();
    }
    set isPlay(newValue: boolean) {
        this.__isPlay.set(newValue);
    }
    /**
     * 圆盘边长上限（vp），由宿主按「内容列高 − 标题块 − 控制区」实测预算后传入；
     * 0 = 不钳制，纯宽度驱动（旧行为，仅瘦长屏成立）。
     * 宽折叠（展开 1292×914vp / 折起 632×924vp）列宽接近列高，宽度驱动的圆盘
     * 会把进度条与三键控制整块挤出屏幕底部 —— 必须按高度预算钳。
     * 必须 @Prop：宿主在 onAreaChange 实测后才回填预算，普通成员变量只在
     * 创建时赋值一次、后续父组件更新不同步也不触发本组件重渲染。
     */
    private __discSize: SynchedPropertySimpleOneWayPU<number>;
    get discSize() {
        return this.__discSize.get();
    }
    set discSize(newValue: number) {
        this.__discSize.set(newValue);
    }
    /** 唱片当前旋转角度（°）：animator 每帧回写，暂停时冻结在当前值 */
    private __rotateAngle: ObservedPropertySimplePU<number>;
    get rotateAngle() {
        return this.__rotateAngle.get();
    }
    set rotateAngle(newValue: number) {
        this.__rotateAngle.set(newValue);
    }
    /** 光晕呼吸状态（本组件独占，不与其他动画共用） */
    private __haloScale: ObservedPropertySimplePU<number>;
    get haloScale() {
        return this.__haloScale.get();
    }
    set haloScale(newValue: number) {
        this.__haloScale.set(newValue);
    }
    private __haloOpacity: ObservedPropertySimplePU<number>;
    get haloOpacity() {
        return this.__haloOpacity.get();
    }
    set haloOpacity(newValue: number) {
        this.__haloOpacity.set(newValue);
    }
    /** 唱片旋转 animator（aboutToAppear 创建，销毁时 finish） */
    private coverAnim: AnimatorResult | null;
    /** 呼吸链代际与定时器句柄 */
    private haloGen: number;
    private haloTimer: number;
    /** 旋转动画参数（创建与 reset 复用同一份配置） */
    private discOptions(): AnimatorOptions {
        return {
            duration: COVER_ROTATE_MS,
            easing: 'linear',
            delay: 0,
            fill: 'forwards',
            direction: 'normal',
            iterations: -1,
            begin: 0,
            end: COVER_ROTATE_DEGREE
        };
    }
    aboutToAppear(): void {
        // UIContext 在属性初始化时未就绪，animator 延迟到这里创建（同 PlayBar / LrcView）
        try {
            this.coverAnim = this.getUIContext().createAnimator(this.discOptions());
            this.coverAnim.onFrame = (value: number): void => {
                this.rotateAngle = value;
            };
            // 挂载时可能已在播放中（@Watch 不会触发，需手动起转）
            if (this.isPlay) {
                this.coverAnim.play();
            }
        }
        catch (e) {
            // animator 创建失败只影响旋转，不影响光晕与其他内容
            const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
            console.error(`[CoverDisc] createAnimator failed: ${msg}`);
        }
        if (this.isPlay) {
            this.startHalo();
        }
    }
    aboutToDisappear(): void {
        if (this.coverAnim !== null) {
            this.coverAnim.finish();
            this.coverAnim = null;
        }
        this.stopHalo();
    }
    /** 播放态变化：旋转续转/冻结；光晕续上呼吸链或定格 */
    onPlayingChanged(_propName: string): void {
        const anim: AnimatorResult | null = this.coverAnim;
        if (anim !== null) {
            if (this.isPlay) {
                anim.play();
            }
            else {
                anim.pause();
            }
        }
        if (this.isPlay) {
            this.startHalo();
        }
        else {
            this.stopHalo();
        }
    }
    /** 宿主实测预算回填（@Prop 同步）——暂留诊断日志，验证通过后可删 */
    onDiscSizeChanged(_propName: string): void {
        console.info(`[CoverDisc] discSize synced: ${this.discSize}`);
    }
    /** 切歌 → 旋转归零（等价 Stopped），再按播放态决定是否重新起转 */
    onTrackChanged(_propName: string): void {
        const anim: AnimatorResult | null = this.coverAnim;
        if (anim === null) {
            return;
        }
        this.rotateAngle = 0;
        try {
            anim.reset(this.discOptions());
        }
        catch (e) {
            const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
            console.error(`[CoverDisc] animator reset failed: ${msg}`);
            return;
        }
        if (this.isPlay) {
            anim.play();
        }
    }
    private startHalo(): void {
        this.stopHalo();
        const gen: number = ++this.haloGen;
        this.haloStep(gen);
    }
    private haloStep(gen: number): void {
        if (!this.isPlay || gen !== this.haloGen) {
            return;
        }
        const duration: number = 1800 + Math.floor(Math.random() * 1600);
        this.getUIContext().animateTo({ duration: duration, curve: Curve.EaseInOut }, (): void => {
            this.haloScale = 1 + Math.random() * 0.07;
            this.haloOpacity = 0.5 + Math.random() * 0.4;
        });
        this.haloTimer = setTimeout((): void => {
            this.haloTimer = -1;
            this.haloStep(gen);
        }, duration);
    }
    /** 暂停 / 销毁：停调度即可，光晕值留在当前位置（定格） */
    private stopHalo(): void {
        this.haloGen++;
        if (this.haloTimer !== -1) {
            clearTimeout(this.haloTimer);
            this.haloTimer = -1;
        }
    }
    private coverUrl(): string {
        return this.currentTrack !== null ? this.currentTrack.coverUrl : '';
    }
    /** 钳制上限：discSize 有效取值，否则哨兵值（等效不钳制） */
    private discCap(): number {
        return this.discSize !== undefined && this.discSize > 0 ? this.discSize : DISC_CAP_UNLIMITED;
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Stack.create();
            Stack.width('100%');
            Stack.aspectRatio(1);
            Stack.constraintSize({ maxWidth: this.discCap() });
        }, Stack);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 光晕层：与封面同尺寸，靠 scale 呼吸放大；scale 不参与布局，Stack 尺寸稳定
            Column.create();
            // 光晕层：与封面同尺寸，靠 scale 呼吸放大；scale 不参与布局，Stack 尺寸稳定
            Column.width('100%');
            // 光晕层：与封面同尺寸，靠 scale 呼吸放大；scale 不参与布局，Stack 尺寸稳定
            Column.aspectRatio(1);
            // 光晕层：与封面同尺寸，靠 scale 呼吸放大；scale 不参与布局，Stack 尺寸稳定
            Column.borderRadius('50%');
            // 光晕层：与封面同尺寸，靠 scale 呼吸放大；scale 不参与布局，Stack 尺寸稳定
            Column.backgroundColor('rgba(255, 255, 255, 0.05)');
            // 光晕层：与封面同尺寸，靠 scale 呼吸放大；scale 不参与布局，Stack 尺寸稳定
            Column.shadow({ radius: 36, color: 'rgba(255, 255, 255, 0.30)', offsetX: 0, offsetY: 0 });
            // 光晕层：与封面同尺寸，靠 scale 呼吸放大；scale 不参与布局，Stack 尺寸稳定
            Column.opacity(this.haloOpacity);
            // 光晕层：与封面同尺寸，靠 scale 呼吸放大；scale 不参与布局，Stack 尺寸稳定
            Column.scale({ x: this.haloScale, y: this.haloScale });
            // 光晕层：与封面同尺寸，靠 scale 呼吸放大；scale 不参与布局，Stack 尺寸稳定
            Column.hitTestBehavior(HitTestMode.None);
        }, Column);
        // 光晕层：与封面同尺寸，靠 scale 呼吸放大；scale 不参与布局，Stack 尺寸稳定
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.coverUrl().length > 0) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Image.create(this.coverUrl());
                        Image.width('100%');
                        Image.aspectRatio(1);
                        Image.borderRadius('50%');
                        Image.objectFit(ImageFit.Cover);
                        Image.draggable(false);
                        Image.rotate({ z: 1, angle: this.rotateAngle });
                        Image.shadow({ radius: 28, color: 'rgba(0, 0, 0, 0.45)', offsetX: 0, offsetY: 10 });
                        Image.geometryTransition(GEOMETRY_ID_PLAYER_DISC);
                    }, Image);
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.width('100%');
                        Column.aspectRatio(1);
                        Column.borderRadius('50%');
                        Column.backgroundColor('rgba(255, 255, 255, 0.12)');
                        Column.justifyContent(FlexAlign.Center);
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('♪');
                        Text.fontSize(64);
                        Text.fontColor(Color.White);
                        Text.opacity(0.6);
                    }, Text);
                    Text.pop();
                    Column.pop();
                });
            }
        }, If);
        If.pop();
        Stack.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
