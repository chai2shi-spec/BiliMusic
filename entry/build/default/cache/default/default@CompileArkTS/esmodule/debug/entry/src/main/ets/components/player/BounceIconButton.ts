if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface BounceIconButton_Params {
    icon?: Resource;
    /** 图标字号（vp） */
    iconSize?: number;
    /** 透明命中区直径（vp），不渲染底板 */
    buttonSize?: number;
    /** 点击回调（回弹动效由本组件自理，回调只管业务） */
    onTap?: () => void;
    bounceScale?: number;
}
export class BounceIconButton extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__icon = new SynchedPropertyObjectOneWayPU(params.icon, this, "icon");
        this.iconSize = 24;
        this.buttonSize = 44;
        this.onTap = undefined;
        this.__bounceScale = new ObservedPropertySimplePU(1, this, "bounceScale");
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: BounceIconButton_Params) {
        if (params.icon === undefined) {
            this.__icon.set({ "id": 125831825, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }
        if (params.iconSize !== undefined) {
            this.iconSize = params.iconSize;
        }
        if (params.buttonSize !== undefined) {
            this.buttonSize = params.buttonSize;
        }
        if (params.onTap !== undefined) {
            this.onTap = params.onTap;
        }
        if (params.bounceScale !== undefined) {
            this.bounceScale = params.bounceScale;
        }
    }
    updateStateVars(params: BounceIconButton_Params) {
        this.__icon.reset(params.icon);
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__icon.purgeDependencyOnElmtId(rmElmtId);
        this.__bounceScale.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__icon.aboutToBeDeleted();
        this.__bounceScale.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    /** SymbolGlyph 图标资源（@Prop：播放模式等图标会随父组件状态变化刷新） */
    private __icon: SynchedPropertySimpleOneWayPU<Resource>;
    get icon() {
        return this.__icon.get();
    }
    set icon(newValue: Resource) {
        this.__icon.set(newValue);
    }
    /** 图标字号（vp） */
    private iconSize: number;
    /** 透明命中区直径（vp），不渲染底板 */
    private buttonSize: number;
    /** 点击回调（回弹动效由本组件自理，回调只管业务） */
    private onTap?: () => void;
    /** 本按钮独占的回弹缩放（不与任何其他动画共用状态） */
    private __bounceScale: ObservedPropertySimplePU<number>;
    get bounceScale() {
        return this.__bounceScale.get();
    }
    set bounceScale(newValue: number) {
        this.__bounceScale.set(newValue);
    }
    /** 点击：一次快速缩小回弹（关键帧驱动，末帧钉回 1） */
    private playBounce(): void {
        this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
            {
                duration: 0,
                event: (): void => {
                    this.bounceScale = 1;
                }
            },
            {
                duration: 90,
                curve: Curve.EaseIn,
                event: (): void => {
                    this.bounceScale = 0.86;
                }
            },
            {
                duration: 170,
                curve: Curve.EaseOut,
                event: (): void => {
                    this.bounceScale = 1.04;
                }
            },
            {
                duration: 100,
                curve: Curve.EaseOut,
                event: (): void => {
                    this.bounceScale = 1;
                }
            }
        ]);
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.width(this.buttonSize);
            Column.height(this.buttonSize);
            Column.scale({ x: this.bounceScale, y: this.bounceScale });
            Column.onClick((): void => {
                this.playBounce();
                if (this.onTap !== undefined) {
                    this.onTap();
                }
            });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            SymbolGlyph.create(this.icon);
            SymbolGlyph.fontSize(this.iconSize);
            SymbolGlyph.fontColor([Color.White]);
            SymbolGlyph.opacity(0.86);
        }, SymbolGlyph);
        Column.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
