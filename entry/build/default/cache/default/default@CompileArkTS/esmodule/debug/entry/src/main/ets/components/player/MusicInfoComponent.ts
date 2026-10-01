if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface MusicInfoComponent_Params {
    currentBreakpoint?: string;
    isFoldFull?: boolean;
    currentTrack?: Track | null;
    discSize?: number;
    colW?: number;
    colH?: number;
    titleH?: number;
    ctrlH?: number;
}
import type { Track } from '../../model/MusicModels';
import { StyleConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/StyleConstants&";
import { BreakpointConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/BreakpointConstants&";
import { PlayerConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/PlayerConstants&";
import { ControlAreaComponent } from "@normalized:N&&&entry/src/main/ets/components/player/ControlAreaComponent&";
import { CoverDiscComponent } from "@normalized:N&&&entry/src/main/ets/components/player/CoverDiscComponent&";
import { STORE_CURRENT_TRACK, STORE_PLAYER_FOLD_FULL } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
export class MusicInfoComponent extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__currentBreakpoint = this.createStorageProp(BreakpointConstants.CURRENT_BREAKPOINT, BreakpointConstants.BREAKPOINT_SM, "currentBreakpoint");
        this.__isFoldFull = this.createStorageLink(STORE_PLAYER_FOLD_FULL, false, "isFoldFull");
        this.__currentTrack = this.createStorageLink(STORE_CURRENT_TRACK, null, "currentTrack");
        this.__discSize = new ObservedPropertySimplePU(0, this, "discSize");
        this.colW = 0;
        this.colH = 0;
        this.titleH = 0;
        this.ctrlH = 0;
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: MusicInfoComponent_Params) {
        if (params.discSize !== undefined) {
            this.discSize = params.discSize;
        }
        if (params.colW !== undefined) {
            this.colW = params.colW;
        }
        if (params.colH !== undefined) {
            this.colH = params.colH;
        }
        if (params.titleH !== undefined) {
            this.titleH = params.titleH;
        }
        if (params.ctrlH !== undefined) {
            this.ctrlH = params.ctrlH;
        }
    }
    updateStateVars(params: MusicInfoComponent_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__currentBreakpoint.purgeDependencyOnElmtId(rmElmtId);
        this.__isFoldFull.purgeDependencyOnElmtId(rmElmtId);
        this.__currentTrack.purgeDependencyOnElmtId(rmElmtId);
        this.__discSize.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__currentBreakpoint.aboutToBeDeleted();
        this.__isFoldFull.aboutToBeDeleted();
        this.__currentTrack.aboutToBeDeleted();
        this.__discSize.aboutToBeDeleted();
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
    private __isFoldFull: ObservedPropertyAbstractPU<boolean>;
    get isFoldFull() {
        return this.__isFoldFull.get();
    }
    set isFoldFull(newValue: boolean) {
        this.__isFoldFull.set(newValue);
    }
    private __currentTrack: ObservedPropertyAbstractPU<Track | null>;
    get currentTrack() {
        return this.__currentTrack.get();
    }
    set currentTrack(newValue: Track | null) {
        this.__currentTrack.set(newValue);
    }
    /**
     * 圆盘边长上限（vp）：0 = 首帧尚未实测（先按旧的宽度驱动渲染，实测后收敛）。
     * 圆盘本身 aspectRatio(1) 宽变高，列宽接近列高的形态（宽折叠展开 / 折起外屏）
     * 会把控制区挤出屏幕；这里按「列高 − 标题块 − 控制区」的实测预算钳住它。
     */
    private __discSize: ObservedPropertySimplePU<number>;
    get discSize() {
        return this.__discSize.get();
    }
    set discSize(newValue: number) {
        this.__discSize.set(newValue);
    }
    /** 内容列实测宽 / 高（onAreaChange 回写） */
    private colW: number;
    private colH: number;
    /** 标题块 / 控制区实测高（圆盘的高度预算要减掉这两块） */
    private titleH: number;
    private ctrlH: number;
    /** Area 尺寸（Length）→ vp 数值；资源型（理论上不会出现）按 0 兜底 */
    private toVp(v: Length): number {
        if (typeof v === 'number') {
            return v;
        }
        if (typeof v === 'string') {
            return parseFloat(v);
        }
        return 0;
    }
    /**
     * 圆盘边长 = min(列宽, 列高 − 标题块 − 控制区)。
     * 四项实测就位前不动（保持 0 = 宽度驱动）；预算为负时同样退回宽度驱动。
     * 瘦长屏（普通手机）预算大于列宽，min 取列宽 —— 与旧行为完全一致，
     * 只有空间不足的形态才会收缩圆盘。
     */
    private recomputeDisc(): void {
        if (this.colW <= 0 || this.colH <= 0 || this.titleH <= 0 || this.ctrlH <= 0) {
            // 暂留诊断日志，验证通过后可删
            console.info(`[MusicInfo] recompute skip: colW=${this.colW}, colH=${this.colH}, titleH=${this.titleH}, ctrlH=${this.ctrlH}`);
            return;
        }
        this.discSize = Math.min(this.colW, this.colH - this.titleH - this.ctrlH);
        console.info(`[MusicInfo] discSize=${this.discSize} (colW=${this.colW}, colH=${this.colH}, titleH=${this.titleH}, ctrlH=${this.ctrlH})`);
    }
    private titleText(): string {
        const t: Track | null = this.currentTrack;
        if (t === null) {
            return '暂无播放内容';
        }
        return t.title.length > 0 ? t.title : '未知歌曲';
    }
    private artistText(): string {
        const t: Track | null = this.currentTrack;
        if (t === null) {
            return '—';
        }
        return t.artist.length > 0 ? t.artist : '未知歌手';
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            GridRow.create({
                columns: {
                    xs: BreakpointConstants.COLUMN_SM,
                    sm: BreakpointConstants.COLUMN_SM,
                    md: BreakpointConstants.COLUMN_MD
                },
                gutter: BreakpointConstants.GUTTER_MUSIC_X,
                breakpoints: { reference: BreakpointsReference.ComponentSize }
            });
        }, GridRow);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            GridCol.create({
                span: {
                    xs: BreakpointConstants.SPAN_SM,
                    sm: BreakpointConstants.SPAN_SM,
                    md: BreakpointConstants.SPAN_MD
                },
                offset: { md: BreakpointConstants.OFFSET_MD }
            });
        }, GridCol);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.height(StyleConstants.FULL_HEIGHT);
            Column.width(StyleConstants.FULL_WIDTH);
            Column.clip(false);
            Column.onAreaChange((_old: Area, n: Area): void => {
                this.colW = this.toVp(n.width);
                this.colH = this.toVp(n.height);
                this.recomputeDisc();
            });
        }, Column);
        this.CoverInfo.bind(this)();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 标题块包一层测高容器：@Builder 调用不能链属性，onAreaChange 挂在包装上
            Column.create();
            // 标题块包一层测高容器：@Builder 调用不能链属性，onAreaChange 挂在包装上
            Column.onAreaChange((_old: Area, n: Area): void => {
                this.titleH = this.toVp(n.height);
                this.recomputeDisc();
            });
        }, Column);
        this.MusicInfo.bind(this)();
        // 标题块包一层测高容器：@Builder 调用不能链属性，onAreaChange 挂在包装上
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 控制区同样包一层测高容器，实测高度参与圆盘预算
            Column.create();
            // 控制区同样包一层测高容器，实测高度参与圆盘预算
            Column.onAreaChange((_old: Area, n: Area): void => {
                this.ctrlH = this.toVp(n.height);
                this.recomputeDisc();
            });
        }, Column);
        {
            this.observeComponentCreation2((elmtId, isInitialRender) => {
                if (isInitialRender) {
                    let componentCall = new ControlAreaComponent(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/MusicInfoComponent.ets", line: 113, col: 13 });
                    ViewPU.create(componentCall);
                    let paramsLambda = () => {
                        return {};
                    };
                    componentCall.paramsGenerator_ = paramsLambda;
                }
                else {
                    this.updateStateVarsOfChildByElmtId(elmtId, {});
                }
            }, { name: "ControlAreaComponent" });
        }
        // 控制区同样包一层测高容器，实测高度参与圆盘预算
        Column.pop();
        Column.pop();
        GridCol.pop();
        GridRow.pop();
    }
    /** 大封面：圆形裁切 + 呼吸光晕 + 柔和投影（含空封面占位，见 CoverDiscComponent） */
    CoverInfo(parent = null): void {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.width(StyleConstants.FULL_WIDTH);
            Row.justifyContent(FlexAlign.Center);
        }, Row);
        {
            this.observeComponentCreation2((elmtId, isInitialRender) => {
                if (isInitialRender) {
                    let componentCall = new CoverDiscComponent(this, { discSize: this.discSize }, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/MusicInfoComponent.ets", line: 136, col: 7 });
                    ViewPU.create(componentCall);
                    let paramsLambda = () => {
                        return {
                            discSize: this.discSize
                        };
                    };
                    componentCall.paramsGenerator_ = paramsLambda;
                }
                else {
                    this.updateStateVarsOfChildByElmtId(elmtId, {
                        discSize: this.discSize
                    });
                }
            }, { name: "CoverDiscComponent" });
        }
        Row.pop();
    }
    MusicInfo(parent = null): void {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.margin({ top: { "id": 16777288, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } });
            Column.alignItems(HorizontalAlign.Start);
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.titleText());
            Text.fontSize(this.currentBreakpoint === BreakpointConstants.BREAKPOINT_MD && !this.isFoldFull ? { "id": 16777307, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 16777306, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.fontColor(Color.White);
            Text.opacity(0.95);
            Text.fontWeight(FontWeight.Bold);
            Text.fontFamily(PlayerConstants.FONT_FAMILY_BOLD);
            Text.maxLines(1);
            Text.textOverflow({ overflow: TextOverflow.Ellipsis });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.artistText());
            Text.textAlign(TextAlign.Start);
            Text.fontSize(this.currentBreakpoint === BreakpointConstants.BREAKPOINT_MD && !this.isFoldFull ? { "id": 16777306, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 16777268, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.fontColor('rgba(255, 255, 255, 0.55)');
            Text.fontFamily(PlayerConstants.FONT_FAMILY_BLACK);
            Text.margin({ top: { "id": 16777289, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } });
            Text.width(StyleConstants.FULL_WIDTH);
            Text.fontWeight(FontWeight.Regular);
            Text.maxLines(1);
            Text.textOverflow({ overflow: TextOverflow.Ellipsis });
        }, Text);
        Text.pop();
        Column.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
