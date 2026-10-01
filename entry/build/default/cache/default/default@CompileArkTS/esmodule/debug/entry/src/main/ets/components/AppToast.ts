if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface AppToast_Params {
    toastMsg?: string;
    toastHoldMs?: number;
    toastSeq?: number;
    safeBottom?: number;
    toastVisible?: boolean;
    hideTimer?: number;
}
import { STORE_SAFE_BOTTOM, STORE_TOAST_HOLD_MS, STORE_TOAST_MSG, STORE_TOAST_SEQ } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
import { TOAST_BOTTOM_MARGIN_VP, TOAST_ENTER_MS, TOAST_ENTER_OFFSET_VP, TOAST_EXIT_MS, TOAST_HOLD_MS } from "@normalized:N&&&entry/src/main/ets/common/constants/InteractionConstants&";
/**
 * 全局轻提示入口（UI 侧统一走这里）。
 * 连续调用 = 替换：seq 递增让组件重置停留计时并覆盖文案，不排队。
 */
export function showAppToast(message: string, holdMs: number = TOAST_HOLD_MS): void {
    AppStorage.setOrCreate(STORE_TOAST_MSG, message);
    AppStorage.setOrCreate(STORE_TOAST_HOLD_MS, holdMs);
    const seq: number = AppStorage.get<number>(STORE_TOAST_SEQ) ?? -1;
    AppStorage.setOrCreate(STORE_TOAST_SEQ, seq + 1);
}
export class AppToast extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__toastMsg = this.createStorageLink(STORE_TOAST_MSG, '', "toastMsg");
        this.__toastHoldMs = this.createStorageLink(STORE_TOAST_HOLD_MS, TOAST_HOLD_MS, "toastHoldMs");
        this.__toastSeq = this.createStorageLink(STORE_TOAST_SEQ, -1, "toastSeq");
        this.__safeBottom = this.createStorageLink(STORE_SAFE_BOTTOM, 0, "safeBottom");
        this.__toastVisible = new ObservedPropertySimplePU(false, this, "toastVisible");
        this.hideTimer = -1;
        this.setInitiallyProvidedValue(params);
        this.declareWatch("toastSeq", this.onToastRequested);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: AppToast_Params) {
        if (params.toastVisible !== undefined) {
            this.toastVisible = params.toastVisible;
        }
        if (params.hideTimer !== undefined) {
            this.hideTimer = params.hideTimer;
        }
    }
    updateStateVars(params: AppToast_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__toastMsg.purgeDependencyOnElmtId(rmElmtId);
        this.__toastHoldMs.purgeDependencyOnElmtId(rmElmtId);
        this.__toastSeq.purgeDependencyOnElmtId(rmElmtId);
        this.__safeBottom.purgeDependencyOnElmtId(rmElmtId);
        this.__toastVisible.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__toastMsg.aboutToBeDeleted();
        this.__toastHoldMs.aboutToBeDeleted();
        this.__toastSeq.aboutToBeDeleted();
        this.__safeBottom.aboutToBeDeleted();
        this.__toastVisible.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private __toastMsg: ObservedPropertyAbstractPU<string>;
    get toastMsg() {
        return this.__toastMsg.get();
    }
    set toastMsg(newValue: string) {
        this.__toastMsg.set(newValue);
    }
    private __toastHoldMs: ObservedPropertyAbstractPU<number>;
    get toastHoldMs() {
        return this.__toastHoldMs.get();
    }
    set toastHoldMs(newValue: number) {
        this.__toastHoldMs.set(newValue);
    }
    private __toastSeq: ObservedPropertyAbstractPU<number>;
    get toastSeq() {
        return this.__toastSeq.get();
    }
    set toastSeq(newValue: number) {
        this.__toastSeq.set(newValue);
    }
    /** 底部安全区（vp）：气泡停留在悬浮胶囊上方，避让手势条/导航栏 */
    private __safeBottom: ObservedPropertyAbstractPU<number>;
    get safeBottom() {
        return this.__safeBottom.get();
    }
    set safeBottom(newValue: number) {
        this.__safeBottom.set(newValue);
    }
    /** 气泡显隐：本地状态驱动 transition 出入场，与请求通道解耦 */
    private __toastVisible: ObservedPropertySimplePU<boolean>;
    get toastVisible() {
        return this.__toastVisible.get();
    }
    set toastVisible(newValue: boolean) {
        this.__toastVisible.set(newValue);
    }
    /** 停留计时器句柄；新请求先清旧计时再重置（替换不排队的核心） */
    private hideTimer: number;
    aboutToDisappear(): void {
        this.clearHideTimer();
    }
    private clearHideTimer(): void {
        if (this.hideTimer >= 0) {
            clearTimeout(this.hideTimer);
            this.hideTimer = -1;
        }
    }
    /** 新请求到达：立刻可见（或覆盖文案）、停留计时从零重走 */
    private onToastRequested(): void {
        this.clearHideTimer();
        this.toastVisible = true;
        this.hideTimer = setTimeout((): void => {
            this.hideTimer = -1;
            this.toastVisible = false;
        }, TOAST_ENTER_MS + this.toastHoldMs);
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Stack.create({ alignContent: Alignment.Bottom });
            Stack.width('100%');
            Stack.height('100%');
            Stack.hitTestBehavior(HitTestMode.None);
        }, Stack);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.toastVisible) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.toastMsg);
                        Text.fontSize(14);
                        Text.fontColor(Color.White);
                        Text.textAlign(TextAlign.Center);
                        Text.maxLines(2);
                        Text.textOverflow({ overflow: TextOverflow.Ellipsis });
                        Text.padding({ left: 20, right: 20, top: 12, bottom: 12 });
                        Text.borderRadius(20);
                        Text.backgroundColor({ "id": 16777256, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.margin({ left: 32, right: 32, bottom: TOAST_BOTTOM_MARGIN_VP + this.safeBottom });
                        Text.transition(TransitionEffect.asymmetric(TransitionEffect.OPACITY
                            .animation({ duration: TOAST_ENTER_MS, curve: Curve.EaseOut })
                            .combine(TransitionEffect.translate({ y: TOAST_ENTER_OFFSET_VP })), TransitionEffect.OPACITY
                            .animation({ duration: TOAST_EXIT_MS, curve: Curve.EaseOut })
                            .combine(TransitionEffect.translate({ y: TOAST_ENTER_OFFSET_VP }))));
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
        Stack.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
