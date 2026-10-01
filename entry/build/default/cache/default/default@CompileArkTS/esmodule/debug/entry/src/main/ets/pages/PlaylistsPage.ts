if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface PlaylistsPage_Params {
    playlists?: Playlist[];
    recentCount?: number;
    showEditor?: boolean;
    editingId?: string;
    editorName?: string;
    libraryRev?: number;
    safeBottom?: number;
    currentBreakpoint?: string;
}
import { LibraryStore } from "@normalized:N&&&entry/src/main/ets/service/LibraryStore&";
import type { Playlist } from '../model/MusicModels';
import { NavStackHolder } from "@normalized:N&&&entry/src/main/ets/service/NavStackHolder&";
import { CONTENT_END_OFFSET, STORE_LIBRARY_REV, STORE_SAFE_BOTTOM } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
import { showAppToast } from "@normalized:N&&&entry/src/main/ets/components/AppToast&";
import { BreakpointConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/BreakpointConstants&";
export class PlaylistsPage extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__playlists = new ObservedPropertyObjectPU([], this, "playlists");
        this.__recentCount = new ObservedPropertySimplePU(0, this, "recentCount");
        this.__showEditor = new ObservedPropertySimplePU(false, this, "showEditor");
        this.__editingId = new ObservedPropertySimplePU('', this, "editingId");
        this.__editorName = new ObservedPropertySimplePU('', this, "editorName");
        this.__libraryRev = this.createStorageLink(STORE_LIBRARY_REV, 0, "libraryRev");
        this.__safeBottom = this.createStorageLink(STORE_SAFE_BOTTOM, 0, "safeBottom");
        this.__currentBreakpoint = this.createStorageProp(BreakpointConstants.CURRENT_BREAKPOINT, BreakpointConstants.BREAKPOINT_SM, "currentBreakpoint");
        this.setInitiallyProvidedValue(params);
        this.declareWatch("libraryRev", this.onLibraryChanged);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: PlaylistsPage_Params) {
        if (params.playlists !== undefined) {
            this.playlists = params.playlists;
        }
        if (params.recentCount !== undefined) {
            this.recentCount = params.recentCount;
        }
        if (params.showEditor !== undefined) {
            this.showEditor = params.showEditor;
        }
        if (params.editingId !== undefined) {
            this.editingId = params.editingId;
        }
        if (params.editorName !== undefined) {
            this.editorName = params.editorName;
        }
    }
    updateStateVars(params: PlaylistsPage_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__playlists.purgeDependencyOnElmtId(rmElmtId);
        this.__recentCount.purgeDependencyOnElmtId(rmElmtId);
        this.__showEditor.purgeDependencyOnElmtId(rmElmtId);
        this.__editingId.purgeDependencyOnElmtId(rmElmtId);
        this.__editorName.purgeDependencyOnElmtId(rmElmtId);
        this.__libraryRev.purgeDependencyOnElmtId(rmElmtId);
        this.__safeBottom.purgeDependencyOnElmtId(rmElmtId);
        this.__currentBreakpoint.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__playlists.aboutToBeDeleted();
        this.__recentCount.aboutToBeDeleted();
        this.__showEditor.aboutToBeDeleted();
        this.__editingId.aboutToBeDeleted();
        this.__editorName.aboutToBeDeleted();
        this.__libraryRev.aboutToBeDeleted();
        this.__safeBottom.aboutToBeDeleted();
        this.__currentBreakpoint.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private __playlists: ObservedPropertyObjectPU<Playlist[]>;
    get playlists() {
        return this.__playlists.get();
    }
    set playlists(newValue: Playlist[]) {
        this.__playlists.set(newValue);
    }
    /** 最近播放条数，用于入口卡片展示（切回本页 / 返回时刷新） */
    private __recentCount: ObservedPropertySimplePU<number>;
    get recentCount() {
        return this.__recentCount.get();
    }
    set recentCount(newValue: number) {
        this.__recentCount.set(newValue);
    }
    /** 名称编辑弹窗：editingId 为空表示新建，非空表示重命名 */
    private __showEditor: ObservedPropertySimplePU<boolean>;
    get showEditor() {
        return this.__showEditor.get();
    }
    set showEditor(newValue: boolean) {
        this.__showEditor.set(newValue);
    }
    private __editingId: ObservedPropertySimplePU<string>;
    get editingId() {
        return this.__editingId.get();
    }
    set editingId(newValue: string) {
        this.__editingId.set(newValue);
    }
    private __editorName: ObservedPropertySimplePU<string>;
    get editorName() {
        return this.__editorName.get();
    }
    set editorName(newValue: string) {
        this.__editorName.set(newValue);
    }
    /**
     * 媒体库变更信号。Tabs 的 TabContent 是常驻的，aboutToAppear 只在首次触发：
     * 搜索页加完歌单切回来、详情页改完返回，都必须靠它重新读数据。
     */
    private __libraryRev: ObservedPropertyAbstractPU<number>;
    get libraryRev() {
        return this.__libraryRev.get();
    }
    set libraryRev(newValue: number) {
        this.__libraryRev.set(newValue);
    }
    /** 底部安全区高度（vp）：根容器不再统一避让，列表末尾让位要自己叠上这一份 */
    private __safeBottom: ObservedPropertyAbstractPU<number>;
    get safeBottom() {
        return this.__safeBottom.get();
    }
    set safeBottom(newValue: number) {
        this.__safeBottom.set(newValue);
    }
    /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
    private __currentBreakpoint: ObservedPropertyAbstractPU<string>;
    get currentBreakpoint() {
        return this.__currentBreakpoint.get();
    }
    set currentBreakpoint(newValue: string) {
        this.__currentBreakpoint.set(newValue);
    }
    aboutToAppear(): void {
        this.refresh();
    }
    /** 切回本 Tab / 从子页返回时刷新（Tabs 的 TabContent 常驻，aboutToAppear 只触发一次） */
    onPageShow(): void {
        this.refresh();
    }
    onLibraryChanged(): void {
        this.refresh();
    }
    private refresh(): void {
        this.playlists = LibraryStore.getPlaylists();
        this.recentCount = LibraryStore.getRecentTracks().length;
    }
    private toast(message: string, duration: number): void {
        showAppToast(message, duration);
    }
    private openCreate(): void {
        this.editingId = '';
        this.editorName = '';
        this.showEditor = true;
    }
    private openRename(p: Playlist): void {
        this.editingId = p.id;
        this.editorName = p.name;
        this.showEditor = true;
    }
    private submitEditor(): void {
        const name: string = this.editorName.trim();
        if (name.length === 0) {
            this.toast('请输入歌单名称', 1500);
            return;
        }
        if (this.editingId.length === 0) {
            LibraryStore.createPlaylist({ name: name });
            this.toast('歌单已创建', 1500);
        }
        else {
            LibraryStore.renamePlaylist(this.editingId, name);
            this.toast('已重命名', 1500);
        }
        this.showEditor = false;
        this.refresh();
    }
    private showPlaylistMenu(p: Playlist): void {
        this.getUIContext()
            .getPromptAction()
            .showDialog({
            title: p.name,
            message: `${p.tracks.length} 首`,
            buttons: [
                { text: '重命名', color: { "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } },
                { text: '删除歌单', color: { "id": 16777250, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } }
            ]
        })
            .then((resp): void => {
            if (resp.index === 0) {
                this.openRename(p);
            }
            else if (resp.index === 1) {
                this.confirmDelete(p);
            }
        })
            .catch((e: Error): void => {
            console.error(`showPlaylistMenu failed: ${e.message}`);
        });
    }
    private confirmDelete(p: Playlist): void {
        this.getUIContext().showAlertDialog({
            title: '删除歌单',
            message: `确定删除「${p.name}」？删除后不可恢复。`,
            primaryButton: {
                value: '取消',
                action: (): void => {
                    // 取消：不做任何事
                }
            },
            secondaryButton: {
                value: '删除',
                action: (): void => {
                    LibraryStore.deletePlaylist(p.id);
                    this.refresh();
                    this.toast('已删除歌单', 1500);
                }
            }
        });
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Stack.create();
        }, Stack);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.width('100%');
            Column.height('100%');
            Column.constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 最近播放入口：点击进入历史列表（记录由播放内核自动写入）
            Row.create();
            // 最近播放入口：点击进入历史列表（记录由播放内核自动写入）
            Row.width('100%');
            // 最近播放入口：点击进入历史列表（记录由播放内核自动写入）
            Row.padding({ left: 16, right: 12, top: 12, bottom: 12 });
            // 最近播放入口：点击进入历史列表（记录由播放内核自动写入）
            Row.onClick((): void => {
                NavStackHolder.stack.pushPath({ name: 'Recent' });
            });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('🕘');
            Text.fontSize(20);
            Text.fontColor({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.width(44);
            Text.height(44);
            Text.borderRadius(22);
            Text.backgroundColor({ "id": 16777237, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.textAlign(TextAlign.Center);
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.layoutWeight(1);
            Column.alignItems(HorizontalAlign.Start);
            Column.margin({ left: 12 });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('最近播放');
            Text.fontSize(16);
            Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.recentCount > 0 ? `${this.recentCount} 首` : '暂无播放记录');
            Text.fontSize(13);
            Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.margin({ top: 4 });
        }, Text);
        Text.pop();
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('›');
            Text.fontSize(20);
            Text.fontColor({ "id": 16777252, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.margin({ right: 8 });
        }, Text);
        Text.pop();
        // 最近播放入口：点击进入历史列表（记录由播放内核自动写入）
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.padding({ left: 16, right: 16, top: 12, bottom: 12 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('我的歌单');
            Text.fontSize(20);
            Text.fontWeight(FontWeight.Bold);
            Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
            Blank.layoutWeight(1);
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel('新建', { type: ButtonType.Capsule });
            Button.fontSize(13);
            Button.backgroundColor({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Button.fontColor({ "id": 16777236, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Button.onClick((): void => {
                this.openCreate();
            });
        }, Button);
        Button.pop();
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.playlists.length === 0) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.layoutWeight(1);
                        Column.justifyContent(FlexAlign.Center);
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('还没有歌单');
                        Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.fontSize(16);
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('点击右上角“新建”创建');
                        Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.fontSize(13);
                        Text.margin({ top: 8 });
                    }, Text);
                    Text.pop();
                    Column.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        List.create();
                        List.layoutWeight(1);
                        List.contentEndOffset(CONTENT_END_OFFSET + this.safeBottom);
                    }, List);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        ForEach.create();
                        const forEachItemGenFunction = _item => {
                            const p = _item;
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
                                };
                                const deepRenderFunction = (elmtId, isInitialRender) => {
                                    itemCreation(elmtId, isInitialRender);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Row.create();
                                        Row.width('100%');
                                        Row.padding({ left: 16, right: 4, top: 10, bottom: 10 });
                                        ViewStackProcessor.visualState("pressed");
                                        Row.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                        ViewStackProcessor.visualState("normal");
                                        Row.backgroundColor(Color.Transparent);
                                        ViewStackProcessor.visualState();
                                        Row.onClick((): void => {
                                            NavStackHolder.selectedPlaylistId = p.id;
                                            NavStackHolder.stack.pushPath({ name: 'PlaylistDetail' });
                                        });
                                    }, Row);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Image.create(p.coverUrl && p.coverUrl.length > 0 ? p.coverUrl : '');
                                        Image.width(56);
                                        Image.height(56);
                                        Image.borderRadius(8);
                                        Image.objectFit(ImageFit.Cover);
                                        Image.backgroundColor({ "id": 16777231, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                    }, Image);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Column.create();
                                        Column.layoutWeight(1);
                                        Column.alignItems(HorizontalAlign.Start);
                                        Column.margin({ left: 12 });
                                    }, Column);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Text.create(p.name);
                                        Text.fontSize(16);
                                        Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                        Text.maxLines(1);
                                    }, Text);
                                    Text.pop();
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Text.create(`${p.tracks.length} 首`);
                                        Text.fontSize(13);
                                        Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                        Text.margin({ top: 4 });
                                    }, Text);
                                    Text.pop();
                                    Column.pop();
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        // 更多操作：重命名 / 删除（父 Row 的 onClick 进详情，这里单独拦截）
                                        // 触达铁律：视觉是 22px 的字，命中区必须撑到 44×44；
                                        // 父 Row 的 onClick 会进详情，热区不够时极易误触。
                                        Text.create('⋮');
                                        // 更多操作：重命名 / 删除（父 Row 的 onClick 进详情，这里单独拦截）
                                        // 触达铁律：视觉是 22px 的字，命中区必须撑到 44×44；
                                        // 父 Row 的 onClick 会进详情，热区不够时极易误触。
                                        Text.fontSize(22);
                                        // 更多操作：重命名 / 删除（父 Row 的 onClick 进详情，这里单独拦截）
                                        // 触达铁律：视觉是 22px 的字，命中区必须撑到 44×44；
                                        // 父 Row 的 onClick 会进详情，热区不够时极易误触。
                                        Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                        // 更多操作：重命名 / 删除（父 Row 的 onClick 进详情，这里单独拦截）
                                        // 触达铁律：视觉是 22px 的字，命中区必须撑到 44×44；
                                        // 父 Row 的 onClick 会进详情，热区不够时极易误触。
                                        Text.width(44);
                                        // 更多操作：重命名 / 删除（父 Row 的 onClick 进详情，这里单独拦截）
                                        // 触达铁律：视觉是 22px 的字，命中区必须撑到 44×44；
                                        // 父 Row 的 onClick 会进详情，热区不够时极易误触。
                                        Text.height(44);
                                        // 更多操作：重命名 / 删除（父 Row 的 onClick 进详情，这里单独拦截）
                                        // 触达铁律：视觉是 22px 的字，命中区必须撑到 44×44；
                                        // 父 Row 的 onClick 会进详情，热区不够时极易误触。
                                        Text.borderRadius(22);
                                        // 更多操作：重命名 / 删除（父 Row 的 onClick 进详情，这里单独拦截）
                                        // 触达铁律：视觉是 22px 的字，命中区必须撑到 44×44；
                                        // 父 Row 的 onClick 会进详情，热区不够时极易误触。
                                        Text.textAlign(TextAlign.Center);
                                        ViewStackProcessor.visualState("pressed");
                                        // 更多操作：重命名 / 删除（父 Row 的 onClick 进详情，这里单独拦截）
                                        // 触达铁律：视觉是 22px 的字，命中区必须撑到 44×44；
                                        // 父 Row 的 onClick 会进详情，热区不够时极易误触。
                                        Text.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                        ViewStackProcessor.visualState("normal");
                                        // 更多操作：重命名 / 删除（父 Row 的 onClick 进详情，这里单独拦截）
                                        // 触达铁律：视觉是 22px 的字，命中区必须撑到 44×44；
                                        // 父 Row 的 onClick 会进详情，热区不够时极易误触。
                                        Text.backgroundColor(Color.Transparent);
                                        ViewStackProcessor.visualState();
                                        // 更多操作：重命名 / 删除（父 Row 的 onClick 进详情，这里单独拦截）
                                        // 触达铁律：视觉是 22px 的字，命中区必须撑到 44×44；
                                        // 父 Row 的 onClick 会进详情，热区不够时极易误触。
                                        Text.onClick((): void => {
                                            this.showPlaylistMenu(p);
                                        });
                                    }, Text);
                                    // 更多操作：重命名 / 删除（父 Row 的 onClick 进详情，这里单独拦截）
                                    // 触达铁律：视觉是 22px 的字，命中区必须撑到 44×44；
                                    // 父 Row 的 onClick 会进详情，热区不够时极易误触。
                                    Text.pop();
                                    Row.pop();
                                    ListItem.pop();
                                };
                                this.observeComponentCreation2(itemCreation2, ListItem);
                                ListItem.pop();
                            }
                        };
                        this.forEachUpdateFunction(elmtId, this.playlists, forEachItemGenFunction, (p: Playlist): string => p.id, false, false);
                    }, ForEach);
                    ForEach.pop();
                    List.pop();
                });
            }
        }, If);
        If.pop();
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.showEditor) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.width('100%');
                        Column.height('100%');
                        Column.backgroundColor({ "id": 16777242, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Column.onClick((): void => {
                            this.showEditor = false;
                        });
                        Column.justifyContent(FlexAlign.Center);
                    }, Column);
                    Column.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.padding(20);
                        Column.width('80%');
                        Column.backgroundColor({ "id": 16777230, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Column.borderRadius(12);
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.editingId.length > 0 ? '重命名歌单' : '新建歌单');
                        Text.fontSize(18);
                        Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.margin({ bottom: 14 });
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        TextInput.create({ placeholder: '歌单名称', text: this.editorName });
                        TextInput.width('100%');
                        TextInput.onChange((v: string): void => {
                            this.editorName = v;
                        });
                    }, TextInput);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Row.create();
                        Row.margin({ top: 16 });
                    }, Row);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Button.createWithLabel('取消', { type: ButtonType.Normal });
                        Button.layoutWeight(1);
                        Button.height(44);
                        Button.backgroundColor({ "id": 16777231, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Button.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Button.onClick((): void => {
                            this.showEditor = false;
                        });
                    }, Button);
                    Button.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Button.createWithLabel(this.editingId.length > 0 ? '保存' : '创建', { type: ButtonType.Normal });
                        Button.layoutWeight(1);
                        Button.height(44);
                        Button.backgroundColor({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Button.fontColor({ "id": 16777236, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Button.margin({ left: 12 });
                        Button.onClick((): void => {
                            this.submitEditor();
                        });
                    }, Button);
                    Button.pop();
                    Row.pop();
                    Column.pop();
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
