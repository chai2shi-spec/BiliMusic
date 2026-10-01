if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface TopAreaComponent_Params {
    currentBreakpoint?: string;
    isDark?: boolean;
}
import AVCastPicker from "@ohos:multimedia.avCastPicker";
import { StyleConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/StyleConstants&";
import { BreakpointConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/BreakpointConstants&";
import { BreakpointType } from "@normalized:N&&&entry/src/main/ets/common/utils/BreakpointSystem&";
import { STORE_PLAYER_BG_DARK } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
export class TopAreaComponent extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__currentBreakpoint = this.createStorageProp(BreakpointConstants.CURRENT_BREAKPOINT, BreakpointConstants.BREAKPOINT_SM, "currentBreakpoint");
        this.__isDark = this.createStorageProp(STORE_PLAYER_BG_DARK, true, "isDark");
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: TopAreaComponent_Params) {
    }
    updateStateVars(params: TopAreaComponent_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__currentBreakpoint.purgeDependencyOnElmtId(rmElmtId);
        this.__isDark.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__currentBreakpoint.aboutToBeDeleted();
        this.__isDark.aboutToBeDeleted();
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
    private __isDark: ObservedPropertyAbstractPU<boolean>;
    get isDark() {
        return this.__isDark.get();
    }
    set isDark(newValue: boolean) {
        this.__isDark.set(newValue);
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.height({ "id": 16777272, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Row.width(StyleConstants.FULL_WIDTH);
            Row.justifyContent(FlexAlign.End);
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            __Common__.create();
            __Common__.width(new BreakpointType<Resource>({
                sm: { "id": 16777257, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                md: { "id": 16777257, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                lg: { "id": 16777260, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
            }).getValue(this.currentBreakpoint));
            __Common__.height(new BreakpointType<Resource>({
                sm: { "id": 16777257, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                md: { "id": 16777257, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                lg: { "id": 16777260, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
            }).getValue(this.currentBreakpoint));
        }, __Common__);
        {
            this.observeComponentCreation2((elmtId, isInitialRender) => {
                if (isInitialRender) {
                    let componentCall = new AVCastPicker(this, {
                        normalColor: this.isDark ? Color.White : Color.Black,
                        activeColor: this.isDark ? Color.White : Color.Black
                    }, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/TopAreaComponent.ets", line: 21, col: 7 });
                    ViewPU.create(componentCall);
                    let paramsLambda = () => {
                        return {
                            normalColor: this.isDark ? Color.White : Color.Black,
                            activeColor: this.isDark ? Color.White : Color.Black
                        };
                    };
                    componentCall.paramsGenerator_ = paramsLambda;
                }
                else {
                    this.updateStateVarsOfChildByElmtId(elmtId, {
                        normalColor: this.isDark ? Color.White : Color.Black,
                        activeColor: this.isDark ? Color.White : Color.Black
                    });
                }
            }, { name: "AVCastPicker" });
        }
        __Common__.pop();
        Row.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
