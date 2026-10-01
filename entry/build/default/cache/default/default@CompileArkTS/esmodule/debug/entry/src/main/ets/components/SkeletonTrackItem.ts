if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface SkeletonTrackItem_Params {
    shimmerX?: number;
    hostWidthVp?: number;
    shimmerStarted?: boolean;
}
/**
 * 骨架屏条目（单曲列表占位）：形状贴合真实内容 —— 40 圆头像 + 两条文字条，
 * 占位色 brand_surface（浅粉，贴合品牌基调；深色模式自动切换深梅色）。
 *
 * 替换掉原先「加载中…」/ LoadingProgress 的文字级反馈：骨架形状对齐内容布局，
 * 加载完成后内容「落位」不跳动（shimmer 扫光 + 同构占位是骨架屏的两件套）。
 *
 * 扫光实现：一条 64vp 宽的品牌粉渐变高光带，从容器左缘外扫到右缘外，
 * 1200ms Linear 无限循环。挂在每行自己的 Stack 上并 clip(true)：
 *   · 动画生命周期跟随组件，页面卸载自动回收，无泄漏；
 *   · translate 声明在 .animation() 之前，只有 shimmerX 这一个可变属性
 *     会被循环动画接管，占位块等静态属性不受影响。
 * 起跑时机放在 onAreaChange（首次量到真实宽度）：translate 用 vp 数值驱动，
 * 必须先知道容器宽度才能确定终点，避免用百分比 translate 在部分版本不可动画。
 */
/** 扫光高光带宽度（vp） */
const SHIMMER_BAND_VP: number = 64;
/** 扫光单程时长（ms）：1200ms Linear 循环 */
const SHIMMER_DURATION_MS: number = 1200;
/**
 * 扫光渐变：品牌粉 25% 峰值透明度。刻意不用白色——浅色模式下 brand_surface
 * 是近白的浅粉（#FFF1F5），白光扫过几乎不可见；粉光在浅 / 深两种模式下都清晰。
 */
const SHIMMER_GRADIENT: [
    ResourceColor,
    number
][] = [
    ['#00FB7299', 0],
    ['#40FB7299', 0.5],
    ['#00FB7299', 1]
];
export class SkeletonTrackItem extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__shimmerX = new ObservedPropertySimplePU(-SHIMMER_BAND_VP, this, "shimmerX");
        this.hostWidthVp = 0;
        this.shimmerStarted = false;
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: SkeletonTrackItem_Params) {
        if (params.shimmerX !== undefined) {
            this.shimmerX = params.shimmerX;
        }
        if (params.hostWidthVp !== undefined) {
            this.hostWidthVp = params.hostWidthVp;
        }
        if (params.shimmerStarted !== undefined) {
            this.shimmerStarted = params.shimmerStarted;
        }
    }
    updateStateVars(params: SkeletonTrackItem_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__shimmerX.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__shimmerX.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    /** 扫光带当前横移（vp）：初始停在容器左缘外，量到宽度后向右扫出 */
    private __shimmerX: ObservedPropertySimplePU<number>;
    get shimmerX() {
        return this.__shimmerX.get();
    }
    set shimmerX(newValue: number) {
        this.__shimmerX.set(newValue);
    }
    /** 容器实测宽度（vp）：扫光终点 = 宽度 + 带宽 */
    private hostWidthVp: number;
    private shimmerStarted: boolean;
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Stack.create();
            Stack.width('100%');
            Stack.clip(true);
            Stack.onAreaChange((_old: Area, cur: Area): void => {
                const w: number = cur.width as number;
                if (w > 0) {
                    this.hostWidthVp = w;
                    if (!this.shimmerStarted) {
                        this.shimmerStarted = true;
                        // 触发一次状态变化即可：.animation(iterations: -1) 接管后自动无限循环
                        this.shimmerX = this.hostWidthVp + SHIMMER_BAND_VP;
                    }
                }
            });
        }, Stack);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 占位形状：40 圆头像 + 标题条 + 副标题条（贴合 TrackItem 的两行文字）
            Row.create();
            // 占位形状：40 圆头像 + 标题条 + 副标题条（贴合 TrackItem 的两行文字）
            Row.width('100%');
            // 占位形状：40 圆头像 + 标题条 + 副标题条（贴合 TrackItem 的两行文字）
            Row.padding({ left: 16, right: 16, top: 14, bottom: 14 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.width(40);
            Row.height(40);
            Row.borderRadius(20);
            Row.backgroundColor({ "id": 16777237, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Row);
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create({ space: 8 });
            Column.layoutWeight(1);
            Column.alignItems(HorizontalAlign.Start);
            Column.margin({ left: 12 });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.width('62%');
            Row.height(14);
            Row.borderRadius(7);
            Row.backgroundColor({ "id": 16777237, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Row);
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.width('38%');
            Row.height(10);
            Row.borderRadius(5);
            Row.backgroundColor({ "id": 16777237, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Row);
        Row.pop();
        Column.pop();
        // 占位形状：40 圆头像 + 标题条 + 副标题条（贴合 TrackItem 的两行文字）
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 扫光高光带：clip 在本行范围内横扫
            Row.create();
            globalThis.Context.animation({
                duration: SHIMMER_DURATION_MS,
                curve: Curve.Linear,
                iterations: -1,
                playMode: PlayMode.Normal
            });
            // 扫光高光带：clip 在本行范围内横扫
            Row.width(SHIMMER_BAND_VP);
            // 扫光高光带：clip 在本行范围内横扫
            Row.height('100%');
            // 扫光高光带：clip 在本行范围内横扫
            Row.linearGradient({ angle: 90, colors: SHIMMER_GRADIENT });
            // 扫光高光带：clip 在本行范围内横扫
            Row.translate({ x: this.shimmerX });
            globalThis.Context.animation(null);
        }, Row);
        // 扫光高光带：clip 在本行范围内横扫
        Row.pop();
        Stack.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
