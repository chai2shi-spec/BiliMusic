if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface PlayerPage_Params {
    playerTransitioning?: boolean;
    enterShift?: number;
    enterOpacity?: number;
    transitionEndTimer?: number;
}
import { PlayerInfoComponent } from "@normalized:N&&&entry/src/main/ets/components/player/PlayerInfoComponent&";
import { ColorConversion } from "@normalized:N&&&entry/src/main/ets/common/utils/ColorConversion&";
import type common from "@ohos:app.ability.common";
import { NavStackHolder } from "@normalized:N&&&entry/src/main/ets/service/NavStackHolder&";
import { STORE_PLAYER_TRANSITIONING, PLAYER_TRANSITION_MS } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
/**
 * 进场起始位移（vp）：点击迷你播放条进入本页时，整页自下方升起 + 淡入。
 * 取「悬浮胶囊底边 + 胶囊高度」的量级，页面起点落在迷你条附近，
 * 视觉上是「从迷你条那里长出来」。
 */
const ENTER_RISE: number = 128;
/** 进场动效时长（ms）。Friction：起步快、落位慢，升起有「落定」感 */
const ENTER_DURATION: number = 360;
export class PlayerPage extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__playerTransitioning = this.createStorageLink(STORE_PLAYER_TRANSITIONING, false, "playerTransitioning");
        this.__enterShift = new ObservedPropertySimplePU(ENTER_RISE, this, "enterShift");
        this.__enterOpacity = new ObservedPropertySimplePU(0, this, "enterOpacity");
        this.transitionEndTimer = -1;
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: PlayerPage_Params) {
        if (params.enterShift !== undefined) {
            this.enterShift = params.enterShift;
        }
        if (params.enterOpacity !== undefined) {
            this.enterOpacity = params.enterOpacity;
        }
        if (params.transitionEndTimer !== undefined) {
            this.transitionEndTimer = params.transitionEndTimer;
        }
    }
    updateStateVars(params: PlayerPage_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__playerTransitioning.purgeDependencyOnElmtId(rmElmtId);
        this.__enterShift.purgeDependencyOnElmtId(rmElmtId);
        this.__enterOpacity.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__playerTransitioning.aboutToBeDeleted();
        this.__enterShift.aboutToBeDeleted();
        this.__enterOpacity.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    /** 共享元素转场进行中：进入时由本页在转场结束后复位（PlayBar 置位） */
    private __playerTransitioning: ObservedPropertyAbstractPU<boolean>;
    get playerTransitioning() {
        return this.__playerTransitioning.get();
    }
    set playerTransitioning(newValue: boolean) {
        this.__playerTransitioning.set(newValue);
    }
    /** 进场动效：整页起始位移与透明度（初始为「下方 + 透明」），由 customTransition 改到终态 */
    private __enterShift: ObservedPropertySimplePU<number>;
    get enterShift() {
        return this.__enterShift.get();
    }
    set enterShift(newValue: number) {
        this.__enterShift.set(newValue);
    }
    private __enterOpacity: ObservedPropertySimplePU<number>;
    get enterOpacity() {
        return this.__enterOpacity.get();
    }
    set enterOpacity(newValue: number) {
        this.__enterOpacity.set(newValue);
    }
    private transitionEndTimer: number;
    aboutToAppear(): void {
        if (this.playerTransitioning) {
            this.scheduleTransitionEnd();
        }
    }
    aboutToDisappear(): void {
        if (this.transitionEndTimer !== -1) {
            clearTimeout(this.transitionEndTimer);
            this.transitionEndTimer = -1;
        }
        // 状态栏内容色复原为黑图标：沉浸页里按背景明暗切换过，首页是浅色背景
        const ctx: common.Context | undefined = this.getUIContext().getHostContext();
        if (ctx !== undefined) {
            ColorConversion.setStatusBarContentColor(ctx, false);
        }
    }
    /** 转场结束回调：复位全局转场标志（PlayBar 侧据此恢复） */
    private scheduleTransitionEnd(): void {
        if (this.transitionEndTimer !== -1) {
            clearTimeout(this.transitionEndTimer);
        }
        this.transitionEndTimer = setTimeout((): void => {
            this.transitionEndTimer = -1;
            AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, false);
        }, PLAYER_TRANSITION_MS);
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            NavDestination.create(() => {
                {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        if (isInitialRender) {
                            let componentCall = new PlayerInfoComponent(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/pages/PlayerPage.ets", line: 78, col: 7 });
                            ViewPU.create(componentCall);
                            let paramsLambda = () => {
                                return {};
                            };
                            componentCall.paramsGenerator_ = paramsLambda;
                        }
                        else {
                            this.updateStateVarsOfChildByElmtId(elmtId, {});
                        }
                    }, { name: "PlayerInfoComponent" });
                }
            }, { moduleName: "entry", pagePath: "entry/src/main/ets/pages/PlayerPage" });
            NavDestination.hideTitleBar(true);
            NavDestination.translate({ y: this.enterShift });
            NavDestination.opacity(this.enterOpacity);
            NavDestination.customTransition((operation: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
                if (!isEnter || operation !== NavigationOperation.PUSH) {
                    return undefined;
                }
                this.enterShift = ENTER_RISE;
                this.enterOpacity = 0;
                const riseIn: NavDestinationTransition = {
                    duration: ENTER_DURATION,
                    delay: 0,
                    curve: Curve.Friction,
                    event: (): void => {
                        this.enterShift = 0;
                        this.enterOpacity = 1;
                    }
                };
                return [riseIn];
            });
            NavDestination.onBackPressed((): boolean => {
                AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, true);
                this.getUIContext().animateTo({ duration: PLAYER_TRANSITION_MS, curve: Curve.EaseInOut }, (): void => {
                    NavStackHolder.stack.pop(false);
                });
                // 转场结束后复位标志（本页可能已销毁，回调只碰全局状态）
                setTimeout((): void => {
                    AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, false);
                }, PLAYER_TRANSITION_MS);
                return true;
            });
        }, NavDestination);
        NavDestination.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
