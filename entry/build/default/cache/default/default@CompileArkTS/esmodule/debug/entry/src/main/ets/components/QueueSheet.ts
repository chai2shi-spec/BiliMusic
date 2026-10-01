if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface QueueSheet_Params {
    queue?: Track[];
    currentTrack?: Track | null;
    repeatMode?: RepeatMode;
    showSheet?: boolean;
    player?: MusicPlayer;
}
import { RepeatMode } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
import type { Track } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
import { MusicPlayer } from "@normalized:N&&&entry/src/main/ets/player/MusicPlayer&";
import { STORE_CURRENT_TRACK, STORE_QUEUE, STORE_REPEAT_MODE } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
const REPEAT_CYCLE: RepeatMode[] = [
    RepeatMode.NONE,
    RepeatMode.ALL,
    RepeatMode.ONE,
    RepeatMode.SHUFFLE
];
/** 模式 → 中文名。模块级纯函数：轮换时要在 setRepeatMode 前后都能取到名字。 */
export function repeatLabelOf(mode: RepeatMode): string {
    if (mode === RepeatMode.SHUFFLE) {
        return '随机播放';
    }
    if (mode === RepeatMode.ONE) {
        return '单曲循环';
    }
    if (mode === RepeatMode.ALL) {
        return '列表循环';
    }
    return '顺序播放';
}
/** 模式 → 图标。供播放页模式按钮与队列弹层顶部的模式药丸共用。 */
export function modeIconOf(mode: RepeatMode): Resource {
    if (mode === RepeatMode.SHUFFLE) {
        return { "id": 125831837, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" };
    }
    if (mode === RepeatMode.ONE) {
        return { "id": 125831132, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" };
    }
    if (mode === RepeatMode.ALL) {
        return { "id": 125831838, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" };
    }
    return { "id": 125832680, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" };
}
export function nextRepeatMode(mode: RepeatMode): RepeatMode {
    let idx: number = REPEAT_CYCLE.indexOf(mode);
    if (idx < 0) {
        idx = 0;
    }
    return REPEAT_CYCLE[(idx + 1) % REPEAT_CYCLE.length];
}
export class QueueSheet extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__queue = this.createStorageLink(STORE_QUEUE, [], "queue");
        this.__currentTrack = this.createStorageLink(STORE_CURRENT_TRACK, null, "currentTrack");
        this.__repeatMode = this.createStorageLink(STORE_REPEAT_MODE, RepeatMode.NONE, "repeatMode");
        this.__showSheet = new SynchedPropertySimpleTwoWayPU(params.showSheet, this, "showSheet");
        this.player = MusicPlayer.getInstance();
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: QueueSheet_Params) {
        if (params.player !== undefined) {
            this.player = params.player;
        }
    }
    updateStateVars(params: QueueSheet_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__queue.purgeDependencyOnElmtId(rmElmtId);
        this.__currentTrack.purgeDependencyOnElmtId(rmElmtId);
        this.__repeatMode.purgeDependencyOnElmtId(rmElmtId);
        this.__showSheet.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__queue.aboutToBeDeleted();
        this.__currentTrack.aboutToBeDeleted();
        this.__repeatMode.aboutToBeDeleted();
        this.__showSheet.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private __queue: ObservedPropertyAbstractPU<Track[]>;
    get queue() {
        return this.__queue.get();
    }
    set queue(newValue: Track[]) {
        this.__queue.set(newValue);
    }
    private __currentTrack: ObservedPropertyAbstractPU<Track | null>;
    get currentTrack() {
        return this.__currentTrack.get();
    }
    set currentTrack(newValue: Track | null) {
        this.__currentTrack.set(newValue);
    }
    private __repeatMode: ObservedPropertyAbstractPU<RepeatMode>;
    get repeatMode() {
        return this.__repeatMode.get();
    }
    set repeatMode(newValue: RepeatMode) {
        this.__repeatMode.set(newValue);
    }
    /** 宿主的弹层开关：点条目 / 清空后由本组件置 false 关闭 */
    private __showSheet: SynchedPropertySimpleTwoWayPU<boolean>;
    get showSheet() {
        return this.__showSheet.get();
    }
    set showSheet(newValue: boolean) {
        this.__showSheet.set(newValue);
    }
    private player: MusicPlayer;
    private currentTrackId(): string {
        return this.currentTrack !== null ? this.currentTrack.id : '';
    }
    /**
     * 刻意保留系统 Toast 而不走全局 AppToast：本组件由 bindSheet 挂载，
     * 弹层渲染在页面内容之上的弹层系，页面级的 AppToast 会被整个盖住；
     * 系统提示层在一切之上，弹层内触发的反馈只有它能露出来。
     */
    private toast(message: string): void {
        try {
            this.getUIContext().getPromptAction().showToast({ message: message, duration: 1200 });
        }
        catch (e) {
            // 提示失败不影响主流程
        }
    }
    private cycleRepeat(): void {
        const next: RepeatMode = nextRepeatMode(this.repeatMode);
        this.player.setRepeatMode(next);
        this.toast(`播放模式：${repeatLabelOf(next)}`);
    }
    /**
     * 「清除列表」二次确认。
     *
     * 清空队列会**连当前正在播的那首一起清掉并停播**（clearQueue 内部会 pause + 回收播放器），
     * 属于不可撤销的破坏性操作，所以必须先问一句，不能点一下就直接清。
     */
    private confirmClearQueue(): void {
        const count: number = this.queue.length;
        if (count === 0) {
            return;
        }
        this.getUIContext()
            .getPromptAction()
            .showDialog({
            title: '清除播放列表',
            message: `将清空 ${count} 首歌曲并停止播放。已加入歌单的歌曲不受影响。`,
            buttons: [
                { text: '取消', color: { "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } },
                { text: '清除', color: { "id": 16777235, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } }
            ]
        })
            .then((resp): void => {
            if (resp.index !== 1) {
                return;
            }
            this.player.clearQueue();
            this.showSheet = false;
            this.toast('播放列表已清除');
        })
            .catch((e: Error): void => {
            console.error(`clear queue dialog failed: ${e.message}`);
        });
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.width('100%');
            Column.height('100%');
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.width('100%');
            Row.padding({ left: 24, right: 24, top: 16, bottom: 12 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(`播放列表(${this.queue.length})`);
            Text.fontSize(18);
            Text.fontWeight(FontWeight.Bold);
            Text.fontColor({ "id": 125830982, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
            Blank.layoutWeight(1);
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 模式药丸：点一次切一个模式，比在播放页按图标更直观
            Row.create({ space: 4 });
            // 模式药丸：点一次切一个模式，比在播放页按图标更直观
            Row.padding({ left: 12, right: 12, top: 4, bottom: 4 });
            // 模式药丸：点一次切一个模式，比在播放页按图标更直观
            Row.borderRadius(12);
            // 模式药丸：点一次切一个模式，比在播放页按图标更直观
            Row.backgroundColor({ "id": 125831062, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            // 模式药丸：点一次切一个模式，比在播放页按图标更直观
            Row.onClick((): void => {
                this.cycleRepeat();
            });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            SymbolGlyph.create(modeIconOf(this.repeatMode));
            SymbolGlyph.fontSize(14);
            SymbolGlyph.fontColor([{ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }]);
        }, SymbolGlyph);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(repeatLabelOf(this.repeatMode));
            Text.fontSize(12);
            Text.fontColor({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Text);
        Text.pop();
        // 模式药丸：点一次切一个模式，比在播放页按图标更直观
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            // 清除列表：放在标题行最右侧（原关闭按钮的位置）。
            // 队列为空时不渲染 —— 没有东西可清，留一个能点的按钮只会让人以为坏了。
            if (this.queue.length > 0) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('清除列表');
                        Text.fontSize(13);
                        Text.fontColor({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.padding({ left: 10, right: 2, top: 4, bottom: 4 });
                        Text.onClick((): void => {
                            this.confirmClearQueue();
                        });
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
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.queue.length === 0) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.width('100%');
                        Column.height(120);
                        Column.justifyContent(FlexAlign.Center);
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('暂无歌曲');
                        Text.fontSize(14);
                        Text.fontColor({ "id": 125830983, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    }, Text);
                    Text.pop();
                    Column.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        List.create();
                        List.width('100%');
                        List.layoutWeight(1);
                        List.scrollBar(BarState.Auto);
                        List.edgeEffect(EdgeEffect.Spring);
                    }, List);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        ForEach.create();
                        const forEachItemGenFunction = (_item, index: number) => {
                            const track = _item;
                            {
                                const itemCreation = (elmtId, isInitialRender) => {
                                    ViewStackProcessor.StartGetAccessRecordingFor(elmtId);
                                    ListItem.create(deepRenderFunction, true);
                                    if (!isInitialRender) {
                                        ListItem.pop();
                                    }
                                    ViewStackProcessor.StopGetAccessRecording();
                                };
                                const itemCreation2 = (elmtId, isInitialRender) => {
                                    ListItem.create(deepRenderFunction, true);
                                    ListItem.onClick((): void => {
                                        this.player.playTrack(track);
                                        this.showSheet = false;
                                    });
                                };
                                const deepRenderFunction = (elmtId, isInitialRender) => {
                                    itemCreation(elmtId, isInitialRender);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Row.create({ space: 10 });
                                        Row.width('100%');
                                        Row.padding({ left: 24, right: 12, top: 8, bottom: 8 });
                                    }, Row);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        If.create();
                                        if (track.id === this.currentTrackId()) {
                                            this.ifElseBranchUpdateFunction(0, () => {
                                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                                    SymbolGlyph.create({ "id": 125831677, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                                    SymbolGlyph.fontSize(16);
                                                    SymbolGlyph.fontColor([{ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }]);
                                                    SymbolGlyph.width(24);
                                                }, SymbolGlyph);
                                            });
                                        }
                                        else {
                                            this.ifElseBranchUpdateFunction(1, () => {
                                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                                    Text.create(`${index + 1}`);
                                                    Text.fontSize(13);
                                                    Text.fontColor({ "id": 125830983, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                                    Text.width(24);
                                                    Text.textAlign(TextAlign.Center);
                                                }, Text);
                                                Text.pop();
                                            });
                                        }
                                    }, If);
                                    If.pop();
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Image.create(track.coverUrl);
                                        Image.width(40);
                                        Image.height(40);
                                        Image.borderRadius(6);
                                        Image.objectFit(ImageFit.Cover);
                                    }, Image);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Column.create({ space: 2 });
                                        Column.layoutWeight(1);
                                        Column.alignItems(HorizontalAlign.Start);
                                    }, Column);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Text.create(track.title);
                                        Text.fontSize(14);
                                        Text.fontColor({ "id": 125830982, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                        Text.maxLines(1);
                                        Text.textOverflow({ overflow: TextOverflow.Ellipsis });
                                    }, Text);
                                    Text.pop();
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Text.create(track.artist);
                                        Text.fontSize(11);
                                        Text.fontColor({ "id": 125830983, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                        Text.maxLines(1);
                                        Text.textOverflow({ overflow: TextOverflow.Ellipsis });
                                    }, Text);
                                    Text.pop();
                                    Column.pop();
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Row.create();
                                        Row.width(28);
                                        Row.height(28);
                                        Row.justifyContent(FlexAlign.Center);
                                        Row.onClick((): void => {
                                            this.player.removeFromQueue(track.id);
                                        });
                                    }, Row);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        SymbolGlyph.create({ "id": 125831487, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                        SymbolGlyph.fontSize(14);
                                        SymbolGlyph.fontColor([{ "id": 125830983, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }]);
                                    }, SymbolGlyph);
                                    Row.pop();
                                    Row.pop();
                                    ListItem.pop();
                                };
                                this.observeComponentCreation2(itemCreation2, ListItem);
                                ListItem.pop();
                            }
                        };
                        this.forEachUpdateFunction(elmtId, this.queue, forEachItemGenFunction, (track: Track): string => track.id, true, false);
                    }, ForEach);
                    ForEach.pop();
                    List.pop();
                });
            }
        }, If);
        If.pop();
        Column.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
