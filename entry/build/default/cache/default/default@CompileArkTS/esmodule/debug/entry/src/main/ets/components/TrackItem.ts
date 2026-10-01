if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface TrackItem_Params {
    track?: Track;
    showCover?: boolean;
    showIndex?: number;
    onPlay?: (track: Track) => void;
    onMore?: (track: Track) => void;
    pressScale?: number;
    entranceIndex?: number;
    enterOffsetY?: number;
    enterOpacity?: number;
    entranceDone?: boolean;
}
import { buildTrack } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
import type { Track } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
import { PRESS_SCALE, PRESS_ANIM_MS, ENTRANCE_OFFSET_VP, ENTRANCE_DURATION_MS, ENTRANCE_STAGGER_MS, ENTRANCE_MAX_ITEMS } from "@normalized:N&&&entry/src/main/ets/common/constants/InteractionConstants&";
/** 「⋯」命中区边长，也是它占位的宽高（视觉仍是 20px 字号，靠居中留白撑开） */
const MORE_HIT: number = 44;
/**
 * 时长文本（秒 → `m:ss`，超过一小时给 `h:mm:ss`）。
 *
 * 返回**空串**表示「没有时长」而不显示占位：音乐中心的条目普遍没有时长字段
 * （映射出来是 `0`），显示 `0:00` 会像信息错乱。`!(total > 0)` 的写法顺带把
 * `NaN` 也挡掉（`NaN > 0` 为 false）。
 */
function formatDuration(seconds: number): string {
    const total: number = Math.floor(seconds);
    if (!(total > 0)) {
        return '';
    }
    const h: number = Math.floor(total / 3600);
    const m: number = Math.floor((total % 3600) / 60);
    const s: number = total % 60;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = s < 10 ? `0${s}` : `${s}`;
    if (h > 0) {
        return `${h}:${mm}:${ss}`;
    }
    return `${m}:${ss}`;
}
export class TrackItem extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__track = new SynchedPropertyObjectOneWayPU(params.track, this, "track");
        this.__showCover = new SynchedPropertySimpleOneWayPU(params.showCover, this, "showCover");
        this.__showIndex = new SynchedPropertySimpleOneWayPU(params.showIndex, this, "showIndex");
        this.onPlay = (): void => { };
        this.onMore = (): void => { };
        this.__pressScale = new ObservedPropertySimplePU(1, this, "pressScale");
        this.__entranceIndex = new SynchedPropertySimpleOneWayPU(params.entranceIndex, this, "entranceIndex");
        this.__enterOffsetY = new ObservedPropertySimplePU(0, this, "enterOffsetY");
        this.__enterOpacity = new ObservedPropertySimplePU(1, this, "enterOpacity");
        this.entranceDone = false;
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: TrackItem_Params) {
        if (params.track === undefined) {
            this.__track.set(buildTrack({}));
        }
        if (params.showCover === undefined) {
            this.__showCover.set(true);
        }
        if (params.showIndex === undefined) {
            this.__showIndex.set(-1);
        }
        if (params.onPlay !== undefined) {
            this.onPlay = params.onPlay;
        }
        if (params.onMore !== undefined) {
            this.onMore = params.onMore;
        }
        if (params.pressScale !== undefined) {
            this.pressScale = params.pressScale;
        }
        if (params.entranceIndex === undefined) {
            this.__entranceIndex.set(-1);
        }
        if (params.enterOffsetY !== undefined) {
            this.enterOffsetY = params.enterOffsetY;
        }
        if (params.enterOpacity !== undefined) {
            this.enterOpacity = params.enterOpacity;
        }
        if (params.entranceDone !== undefined) {
            this.entranceDone = params.entranceDone;
        }
    }
    updateStateVars(params: TrackItem_Params) {
        this.__track.reset(params.track);
        this.__showCover.reset(params.showCover);
        this.__showIndex.reset(params.showIndex);
        this.__entranceIndex.reset(params.entranceIndex);
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__track.purgeDependencyOnElmtId(rmElmtId);
        this.__showCover.purgeDependencyOnElmtId(rmElmtId);
        this.__showIndex.purgeDependencyOnElmtId(rmElmtId);
        this.__pressScale.purgeDependencyOnElmtId(rmElmtId);
        this.__entranceIndex.purgeDependencyOnElmtId(rmElmtId);
        this.__enterOffsetY.purgeDependencyOnElmtId(rmElmtId);
        this.__enterOpacity.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__track.aboutToBeDeleted();
        this.__showCover.aboutToBeDeleted();
        this.__showIndex.aboutToBeDeleted();
        this.__pressScale.aboutToBeDeleted();
        this.__entranceIndex.aboutToBeDeleted();
        this.__enterOffsetY.aboutToBeDeleted();
        this.__enterOpacity.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private __track: SynchedPropertySimpleOneWayPU<Track>;
    get track() {
        return this.__track.get();
    }
    set track(newValue: Track) {
        this.__track.set(newValue);
    }
    private __showCover: SynchedPropertySimpleOneWayPU<boolean>;
    get showCover() {
        return this.__showCover.get();
    }
    set showCover(newValue: boolean) {
        this.__showCover.set(newValue);
    }
    private __showIndex: SynchedPropertySimpleOneWayPU<number>;
    get showIndex() {
        return this.__showIndex.get();
    }
    set showIndex(newValue: number) {
        this.__showIndex.set(newValue);
    }
    private onPlay: (track: Track) => void;
    private onMore: (track: Track) => void;
    /**
     * 按压缩放（独立动画状态，本条目独占）：按下 0.9，抬起/取消回 1.0。
     *
     * 设计约束（按压反馈改版结论）：
     * - **只做形变**：不碰 backgroundColor、不加按压蒙层/底色/高亮 —— 上一版
     *   stateStyles 的 press_overlay 底色方案已按新规范移除（资源本身其他页面
     *   仍在用，保留）。
     * - **独立隔离**：专用 @State + 紧跟 .scale() 的独立 .animation()，
     *   不与任何其他组件的动画状态（HdsTabs、miniBar 唱片旋转、播放按钮形变、
     *   搜索框动画）共用变量，互不干扰。
     * - **零额外层级**：scale 直接挂在根 Row 上，不引入包装容器，保持原布局。
     * - 属性动画无循环无定时器，组件销毁无需清理（无内存泄漏风险）。
     */
    private __pressScale: ObservedPropertySimplePU<number>;
    get pressScale() {
        return this.__pressScale.get();
    }
    set pressScale(newValue: number) {
        this.__pressScale.set(newValue);
    }
    /**
     * 入场错峰（可选）：父列表把它在 ForEach 里的**下标**传进来，前 ENTRANCE_MAX_ITEMS 条
     * （首屏可见范围）做「下移 10vp + 淡入」的错峰入场，其余条目直接出现。
     * 默认 -1 = 不启用（未传下标的页面行为完全不变）。
     */
    private __entranceIndex: SynchedPropertySimpleOneWayPU<number>;
    get entranceIndex() {
        return this.__entranceIndex.get();
    }
    set entranceIndex(newValue: number) {
        this.__entranceIndex.set(newValue);
    }
    /** 入场位移（vp）：10 → 0；仅错峰条目在挂载时被置为起始值 */
    private __enterOffsetY: ObservedPropertySimplePU<number>;
    get enterOffsetY() {
        return this.__enterOffsetY.get();
    }
    set enterOffsetY(newValue: number) {
        this.__enterOffsetY.set(newValue);
    }
    /** 入场透明度：0 → 1 */
    private __enterOpacity: ObservedPropertySimplePU<number>;
    get enterOpacity() {
        return this.__enterOpacity.get();
    }
    set enterOpacity(newValue: number) {
        this.__enterOpacity.set(newValue);
    }
    /** 错峰只播一次：@Prop 下标变化（增删条目导致索引位移）不重播 */
    private entranceDone: boolean;
    aboutToAppear(): void {
        if (this.entranceIndex >= 0 && this.entranceIndex < ENTRANCE_MAX_ITEMS) {
            this.enterOffsetY = ENTRANCE_OFFSET_VP;
            this.enterOpacity = 0;
        }
    }
    /** 本条目要显示的时长文本；返回空串＝该条目没有时长信息，整块不渲染 */
    private durationText(): string {
        return formatDuration(this.track.duration);
    }
    /**
     * 错峰入场：挂载后一次性触发（entranceDone 防重播）。
     * 单条 normal(250ms) EaseOut，相邻条目延迟 35ms；非首屏条目（下标 ≥ 8）不进入，
     * 直接随列表出现——否则长列表滚到底部时新条目还在逐条错峰。
     */
    private playEntrance(): void {
        if (this.entranceDone) {
            return;
        }
        if (this.entranceIndex < 0 || this.entranceIndex >= ENTRANCE_MAX_ITEMS) {
            return;
        }
        this.entranceDone = true;
        this.getUIContext().animateTo({
            duration: ENTRANCE_DURATION_MS,
            curve: Curve.EaseOut,
            delay: this.entranceIndex * ENTRANCE_STAGGER_MS
        }, (): void => {
            this.enterOffsetY = 0;
            this.enterOpacity = 1;
        });
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            globalThis.Context.animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut });
            Row.width('100%');
            Row.padding({ left: 16, right: 4, top: 10, bottom: 10 });
            Row.scale({ x: this.pressScale, y: this.pressScale });
            globalThis.Context.animation(null);
            Row.translate({ y: this.enterOffsetY });
            Row.opacity(this.enterOpacity);
            Row.onAppear((): void => {
                this.playEntrance();
            });
            Row.onTouch((event: TouchEvent): void => {
                if (event.type === TouchType.Down) {
                    this.pressScale = PRESS_SCALE;
                }
                else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                    this.pressScale = 1;
                }
            });
            Row.onClick((): void => {
                this.onPlay(ObservedObject.GetRawObject(this.track));
            });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.showCover) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Image.create(this.track.coverUrl);
                        Image.width(48);
                        Image.height(48);
                        Image.borderRadius(8);
                        Image.objectFit(ImageFit.Cover);
                    }, Image);
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.layoutWeight(1);
            Column.alignItems(HorizontalAlign.Start);
            Column.margin({ left: 12 });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.track.title);
            Text.fontSize(16);
            Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.maxLines(1);
            Text.textOverflow({ overflow: TextOverflow.Ellipsis });
            Text.width('100%');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.width('100%');
            Row.margin({ top: 4 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.track.artist);
            Text.fontSize(13);
            Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.maxLines(1);
            Text.textOverflow({ overflow: TextOverflow.Ellipsis });
            Text.layoutWeight(1);
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            // 时长跟在歌手后面。歌手用 layoutWeight(1) 吃掉剩余宽度，
            // 于是时长被推到行尾（歌手过长时先省略歌手，时长不被挤掉）。
            if (this.durationText().length > 0) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.durationText());
                        Text.fontSize(13);
                        Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.maxLines(1);
                        Text.margin({ left: 8 });
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
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 「⋯」：视觉 20px 文字不变，但命中区撑到 44×44（居中留白），
            // 并把原来 left:14 的 margin 收进自身宽度，避免热区与整行 onPlay 重叠。
            Row.create();
            // 「⋯」：视觉 20px 文字不变，但命中区撑到 44×44（居中留白），
            // 并把原来 left:14 的 margin 收进自身宽度，避免热区与整行 onPlay 重叠。
            Row.width(MORE_HIT);
            // 「⋯」：视觉 20px 文字不变，但命中区撑到 44×44（居中留白），
            // 并把原来 left:14 的 margin 收进自身宽度，避免热区与整行 onPlay 重叠。
            Row.height(MORE_HIT);
            // 「⋯」：视觉 20px 文字不变，但命中区撑到 44×44（居中留白），
            // 并把原来 left:14 的 margin 收进自身宽度，避免热区与整行 onPlay 重叠。
            Row.justifyContent(FlexAlign.Center);
            // 「⋯」：视觉 20px 文字不变，但命中区撑到 44×44（居中留白），
            // 并把原来 left:14 的 margin 收进自身宽度，避免热区与整行 onPlay 重叠。
            Row.onClick((): void => {
                this.onMore(ObservedObject.GetRawObject(this.track));
            });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('⋯');
            Text.fontSize(20);
            Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Text);
        Text.pop();
        // 「⋯」：视觉 20px 文字不变，但命中区撑到 44×44（居中留白），
        // 并把原来 left:14 的 margin 收进自身宽度，避免热区与整行 onPlay 重叠。
        Row.pop();
        Row.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
