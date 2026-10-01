if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface PlaylistDetail_Params {
    headerMaterial?: uiMaterial.ImmersiveMaterial | undefined;
    headerModifier?: HeaderMaterialModifier;
    playlist?: Playlist | null;
    titleText?: string;
    showRename?: boolean;
    renameName?: string;
    libraryRev?: number;
    safeTop?: number;
    safeBottom?: number;
    currentBreakpoint?: string;
    player?: MusicPlayer;
    navTransX?: string;
}
import type uiMaterial from "@ohos:arkui.uiMaterial";
import type { Playlist, Track } from '../model/MusicModels';
import { LibraryStore } from "@normalized:N&&&entry/src/main/ets/service/LibraryStore&";
import { MusicPlayer } from "@normalized:N&&&entry/src/main/ets/player/MusicPlayer&";
import { TrackItem } from "@normalized:N&&&entry/src/main/ets/components/TrackItem&";
import { NavStackHolder } from "@normalized:N&&&entry/src/main/ets/service/NavStackHolder&";
import { NAV_TITLE_BAR_HEIGHT } from "@normalized:N&&&entry/src/main/ets/utils/NavTitleStyle&";
import { MaterialCompat, MaterialCompatStyle } from "@normalized:N&&&entry/src/main/ets/utils/MaterialCompat&";
import { STORE_LIBRARY_REV, STORE_SAFE_BOTTOM, STORE_SAFE_TOP } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
import { BreakpointConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/BreakpointConstants&";
import { NAV_TRANSITION_MS } from "@normalized:N&&&entry/src/main/ets/common/constants/InteractionConstants&";
import { showAppToast } from "@normalized:N&&&entry/src/main/ets/components/AppToast&";
/**
 * 标题栏沉浸材质的属性修饰器：仅当材质对象存在（API 26+ 且运行时支持）时才调用
 * systemMaterial；API 23/24 上该属性方法不存在，不调用即不崩溃（透明标题栏兜底）。
 */
class HeaderMaterialModifier implements AttributeModifier<RowAttribute> {
    private material: uiMaterial.ImmersiveMaterial | undefined;
    constructor(material: uiMaterial.ImmersiveMaterial | undefined) {
        this.material = material;
    }
    applyNormalAttribute(instance: RowAttribute): void {
        const m: uiMaterial.ImmersiveMaterial | undefined = this.material;
        if (m === undefined) {
            return;
        }
        try {
            instance.systemMaterial(m);
        }
        catch (e) {
            console.error(`apply header systemMaterial failed: ${JSON.stringify(e)}`);
        }
    }
}
export class PlaylistDetail extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.headerMaterial = MaterialCompat.immersiveMaterial(MaterialCompatStyle.THIN, { interactive: true });
        this.headerModifier = new HeaderMaterialModifier(this.headerMaterial);
        this.__playlist = new ObservedPropertyObjectPU(null, this, "playlist");
        this.__titleText = new ObservedPropertySimplePU('歌单', this, "titleText");
        this.__showRename = new ObservedPropertySimplePU(false, this, "showRename");
        this.__renameName = new ObservedPropertySimplePU('', this, "renameName");
        this.__libraryRev = this.createStorageLink(STORE_LIBRARY_REV, 0, "libraryRev");
        this.__safeTop = this.createStorageLink(STORE_SAFE_TOP, 0, "safeTop");
        this.__safeBottom = this.createStorageLink(STORE_SAFE_BOTTOM, 0, "safeBottom");
        this.__currentBreakpoint = this.createStorageProp(BreakpointConstants.CURRENT_BREAKPOINT, BreakpointConstants.BREAKPOINT_SM, "currentBreakpoint");
        this.player = MusicPlayer.getInstance();
        this.__navTransX = new ObservedPropertySimplePU('0%', this, "navTransX");
        this.setInitiallyProvidedValue(params);
        this.declareWatch("libraryRev", this.onLibraryChanged);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: PlaylistDetail_Params) {
        if (params.headerMaterial !== undefined) {
            this.headerMaterial = params.headerMaterial;
        }
        if (params.headerModifier !== undefined) {
            this.headerModifier = params.headerModifier;
        }
        if (params.playlist !== undefined) {
            this.playlist = params.playlist;
        }
        if (params.titleText !== undefined) {
            this.titleText = params.titleText;
        }
        if (params.showRename !== undefined) {
            this.showRename = params.showRename;
        }
        if (params.renameName !== undefined) {
            this.renameName = params.renameName;
        }
        if (params.player !== undefined) {
            this.player = params.player;
        }
        if (params.navTransX !== undefined) {
            this.navTransX = params.navTransX;
        }
    }
    updateStateVars(params: PlaylistDetail_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__playlist.purgeDependencyOnElmtId(rmElmtId);
        this.__titleText.purgeDependencyOnElmtId(rmElmtId);
        this.__showRename.purgeDependencyOnElmtId(rmElmtId);
        this.__renameName.purgeDependencyOnElmtId(rmElmtId);
        this.__libraryRev.purgeDependencyOnElmtId(rmElmtId);
        this.__safeTop.purgeDependencyOnElmtId(rmElmtId);
        this.__safeBottom.purgeDependencyOnElmtId(rmElmtId);
        this.__currentBreakpoint.purgeDependencyOnElmtId(rmElmtId);
        this.__navTransX.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__playlist.aboutToBeDeleted();
        this.__titleText.aboutToBeDeleted();
        this.__showRename.aboutToBeDeleted();
        this.__renameName.aboutToBeDeleted();
        this.__libraryRev.aboutToBeDeleted();
        this.__safeTop.aboutToBeDeleted();
        this.__safeBottom.aboutToBeDeleted();
        this.__currentBreakpoint.aboutToBeDeleted();
        this.__navTransX.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    /** 自绘标题栏的沉浸材质（THIN 毛玻璃）；能力缺失时 undefined，走默认样式 */
    private headerMaterial: uiMaterial.ImmersiveMaterial | undefined;
    /**
     * systemMaterial 属性方法 26.0.0 才有：API 23/24 上直接链式调用会在渲染期抛
     * 「not callable」崩溃。改走 AttributeModifier（API 12 起通用），材质为
     * undefined（低版本 / 能力缺失）时不调用，静默退化为透明标题栏。
     */
    private headerModifier: HeaderMaterialModifier;
    private __playlist: ObservedPropertyObjectPU<Playlist | null>;
    get playlist() {
        return this.__playlist.get();
    }
    set playlist(newValue: Playlist | null) {
        this.__playlist.set(newValue);
    }
    private __titleText: ObservedPropertySimplePU<string>;
    get titleText() {
        return this.__titleText.get();
    }
    set titleText(newValue: string) {
        this.__titleText.set(newValue);
    }
    private __showRename: ObservedPropertySimplePU<boolean>;
    get showRename() {
        return this.__showRename.get();
    }
    set showRename(newValue: boolean) {
        this.__showRename.set(newValue);
    }
    private __renameName: ObservedPropertySimplePU<string>;
    get renameName() {
        return this.__renameName.get();
    }
    set renameName(newValue: string) {
        this.__renameName.set(newValue);
    }
    /** 媒体库变更信号：在别处（如弹层里）改到这个歌单时同步刷新 */
    private __libraryRev: ObservedPropertyAbstractPU<number>;
    get libraryRev() {
        return this.__libraryRev.get();
    }
    set libraryRev(newValue: number) {
        this.__libraryRev.set(newValue);
    }
    /** 状态栏高度（vp）：标题栏要整体落在状态栏下方，由本页自己顶下来 */
    private __safeTop: ObservedPropertyAbstractPU<number>;
    get safeTop() {
        return this.__safeTop.get();
    }
    set safeTop(newValue: number) {
        this.__safeTop.set(newValue);
    }
    /** 底部安全区高度（vp）：NavDestination 默认扩到屏幕底，列表末尾要自己让开手势区 */
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
    private player: MusicPlayer;
    /**
     * 子页转场的横移量（相对页面自身宽度）：常驻 '0%'，
     * 转场代理里按 push/pop 方向临时改写（见 navTransitionDelegate）。
     */
    private __navTransX: ObservedPropertySimplePU<string>;
    get navTransX() {
        return this.__navTransX.get();
    }
    set navTransX(newValue: string) {
        this.__navTransX.set(newValue);
    }
    aboutToAppear(): void {
        this.load();
    }
    /**
     * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut。
     * · push 入场：先把页面挪到屏幕右侧外（'100%'），event 闭包内回到 '0%'，
     *   系统按闭包内的状态变化生成 400ms EaseOut 过渡；
     * · pop 出场（含侧滑返回手势触发的返回）：反向滑回右侧，与手势方向一致；
     * · 其余场景（本页被上层页覆盖 / 上层页返回后重新露出）返回 undefined，
     *   走系统默认转场。
     */
    private navTransitionDelegate(op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined {
        if (op === NavigationOperation.PUSH && isEnter) {
            this.navTransX = '100%';
            const enter: NavDestinationTransition = {
                duration: NAV_TRANSITION_MS,
                curve: Curve.EaseOut,
                event: (): void => {
                    this.navTransX = '0%';
                }
            };
            const transitions: Array<NavDestinationTransition> = [enter];
            return transitions;
        }
        if (op === NavigationOperation.POP && !isEnter) {
            const exit: NavDestinationTransition = {
                duration: NAV_TRANSITION_MS,
                curve: Curve.EaseOut,
                event: (): void => {
                    this.navTransX = '100%';
                }
            };
            const transitions: Array<NavDestinationTransition> = [exit];
            return transitions;
        }
        return undefined;
    }
    onLibraryChanged(): void {
        this.load();
    }
    private load(): void {
        this.playlist = LibraryStore.getPlaylist(NavStackHolder.selectedPlaylistId);
        this.titleText = this.playlist ? this.playlist.name : '歌单';
    }
    private toast(message: string, duration: number): void {
        showAppToast(message, duration);
    }
    private showPlaylistMenu(): void {
        const p: Playlist | null = this.playlist;
        if (!p) {
            return;
        }
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
                this.renameName = p.name;
                this.showRename = true;
            }
            else if (resp.index === 1) {
                this.confirmDelete();
            }
        })
            .catch((e: Error): void => {
            console.error(`showPlaylistMenu failed: ${e.message}`);
        });
    }
    private submitRename(): void {
        const name: string = this.renameName.trim();
        if (name.length === 0) {
            this.toast('请输入歌单名称', 1500);
            return;
        }
        if (this.playlist) {
            LibraryStore.renamePlaylist(this.playlist.id, name);
            this.load();
            this.toast('已重命名', 1500);
        }
        this.showRename = false;
    }
    private confirmDelete(): void {
        const p: Playlist | null = this.playlist;
        if (!p) {
            return;
        }
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
                    this.toast('已删除歌单', 1500);
                    NavStackHolder.stack.pop();
                }
            }
        });
    }
    private showMenu(track: Track): void {
        this.getUIContext().showAlertDialog({
            title: track.title,
            message: '选择操作',
            primaryButton: {
                value: '从歌单移除',
                action: (): void => {
                    LibraryStore.removeTracksFromPlaylist(NavStackHolder.selectedPlaylistId, [track.id]);
                    this.load();
                }
            },
            secondaryButton: {
                value: '加入队列',
                action: (): void => {
                    this.player.addToQueue(track);
                    this.toast('已加入播放队列', 1500);
                }
            }
        });
    }
    HeaderActions(parent = null): void {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create({ space: 8 });
            Row.alignItems(VerticalAlign.Center);
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.playlist && this.playlist.tracks.length > 0) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Button.createWithLabel('播放全部', { type: ButtonType.Capsule });
                        Button.fontSize(13);
                        Button.height(32);
                        Button.backgroundColor({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Button.fontColor({ "id": 16777236, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Button.onClick((): void => {
                            if (this.playlist) {
                                this.player.playAll(this.playlist.tracks);
                            }
                        });
                    }, Button);
                    Button.pop();
                });
            }
            // 触达铁律：视觉是 22px 的字，命中区撑到 44×44
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 触达铁律：视觉是 22px 的字，命中区撑到 44×44
            Text.create('⋮');
            // 触达铁律：视觉是 22px 的字，命中区撑到 44×44
            Text.fontSize(22);
            // 触达铁律：视觉是 22px 的字，命中区撑到 44×44
            Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            // 触达铁律：视觉是 22px 的字，命中区撑到 44×44
            Text.width(44);
            // 触达铁律：视觉是 22px 的字，命中区撑到 44×44
            Text.height(44);
            // 触达铁律：视觉是 22px 的字，命中区撑到 44×44
            Text.borderRadius(22);
            // 触达铁律：视觉是 22px 的字，命中区撑到 44×44
            Text.textAlign(TextAlign.Center);
            ViewStackProcessor.visualState("pressed");
            // 触达铁律：视觉是 22px 的字，命中区撑到 44×44
            Text.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            ViewStackProcessor.visualState("normal");
            // 触达铁律：视觉是 22px 的字，命中区撑到 44×44
            Text.backgroundColor(Color.Transparent);
            ViewStackProcessor.visualState();
            // 触达铁律：视觉是 22px 的字，命中区撑到 44×44
            Text.onClick((): void => {
                this.showPlaylistMenu();
            });
        }, Text);
        // 触达铁律：视觉是 22px 的字，命中区撑到 44×44
        Text.pop();
        Row.pop();
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            NavDestination.create(() => {
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Stack.create();
                }, Stack);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Column.create();
                    Column.width('100%');
                    Column.height('100%');
                    Column.backgroundColor({ "id": 16777232, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Column.padding({ top: this.safeTop });
                    Column.safeAreaPadding({ top: NAV_TITLE_BAR_HEIGHT, bottom: this.safeBottom });
                    Column.constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) });
                }, Column);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    If.create();
                    if (this.playlist && this.playlist.tracks.length > 0) {
                        this.ifElseBranchUpdateFunction(0, () => {
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                List.create();
                                List.layoutWeight(1);
                            }, List);
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                ForEach.create();
                                const forEachItemGenFunction = (_item, index: number) => {
                                    const t = _item;
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
                                            {
                                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                                    if (isInitialRender) {
                                                        let componentCall = new TrackItem(this, {
                                                            track: t,
                                                            entranceIndex: index,
                                                            onPlay: (tr: Track): void => {
                                                                this.player.playNow(tr);
                                                            },
                                                            onMore: (tr: Track): void => {
                                                                this.showMenu(tr);
                                                            }
                                                        }, undefined, elmtId, () => { }, { page: "entry/src/main/ets/pages/PlaylistDetail.ets", line: 265, col: 21 });
                                                        ViewPU.create(componentCall);
                                                        let paramsLambda = () => {
                                                            return {
                                                                track: t,
                                                                entranceIndex: index,
                                                                onPlay: (tr: Track): void => {
                                                                    this.player.playNow(tr);
                                                                },
                                                                onMore: (tr: Track): void => {
                                                                    this.showMenu(tr);
                                                                }
                                                            };
                                                        };
                                                        componentCall.paramsGenerator_ = paramsLambda;
                                                    }
                                                    else {
                                                        this.updateStateVarsOfChildByElmtId(elmtId, {
                                                            track: t,
                                                            entranceIndex: index
                                                        });
                                                    }
                                                }, { name: "TrackItem" });
                                            }
                                            ListItem.pop();
                                        };
                                        this.observeComponentCreation2(itemCreation2, ListItem);
                                        ListItem.pop();
                                    }
                                };
                                this.forEachUpdateFunction(elmtId, this.playlist.tracks, forEachItemGenFunction, (t: Track): string => t.id, true, false);
                            }, ForEach);
                            ForEach.pop();
                            List.pop();
                        });
                    }
                    else {
                        this.ifElseBranchUpdateFunction(1, () => {
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Column.create();
                                Column.layoutWeight(1);
                                Column.justifyContent(FlexAlign.Center);
                            }, Column);
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Text.create('歌单还是空的');
                                Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                Text.fontSize(16);
                            }, Text);
                            Text.pop();
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Text.create('在搜索页点击“⋯”把歌曲加进来吧');
                                Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                Text.fontSize(13);
                                Text.margin({ top: 8 });
                            }, Text);
                            Text.pop();
                            Column.pop();
                        });
                    }
                }, If);
                If.pop();
                Column.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    // 自绘标题栏（去掉返回键，返回走系统侧滑）：position 到状态栏下方，
                    // 不再像系统标题栏那样压到状态栏 / 挖孔区域。
                    // 外面包一层与内容列同宽的宿主：position 相对宿主定位，大屏上标题栏
                    // 才能与收窄后的列表左右对齐（直接挂 Stack 上会贴屏幕左缘）；
                    // hitTestBehavior(None) 让宿主自身不吞点击，标题栏以下的区域照常点得到列表。
                    Column.create();
                    // 自绘标题栏（去掉返回键，返回走系统侧滑）：position 到状态栏下方，
                    // 不再像系统标题栏那样压到状态栏 / 挖孔区域。
                    // 外面包一层与内容列同宽的宿主：position 相对宿主定位，大屏上标题栏
                    // 才能与收窄后的列表左右对齐（直接挂 Stack 上会贴屏幕左缘）；
                    // hitTestBehavior(None) 让宿主自身不吞点击，标题栏以下的区域照常点得到列表。
                    Column.width('100%');
                    // 自绘标题栏（去掉返回键，返回走系统侧滑）：position 到状态栏下方，
                    // 不再像系统标题栏那样压到状态栏 / 挖孔区域。
                    // 外面包一层与内容列同宽的宿主：position 相对宿主定位，大屏上标题栏
                    // 才能与收窄后的列表左右对齐（直接挂 Stack 上会贴屏幕左缘）；
                    // hitTestBehavior(None) 让宿主自身不吞点击，标题栏以下的区域照常点得到列表。
                    Column.height('100%');
                    // 自绘标题栏（去掉返回键，返回走系统侧滑）：position 到状态栏下方，
                    // 不再像系统标题栏那样压到状态栏 / 挖孔区域。
                    // 外面包一层与内容列同宽的宿主：position 相对宿主定位，大屏上标题栏
                    // 才能与收窄后的列表左右对齐（直接挂 Stack 上会贴屏幕左缘）；
                    // hitTestBehavior(None) 让宿主自身不吞点击，标题栏以下的区域照常点得到列表。
                    Column.constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) });
                    // 自绘标题栏（去掉返回键，返回走系统侧滑）：position 到状态栏下方，
                    // 不再像系统标题栏那样压到状态栏 / 挖孔区域。
                    // 外面包一层与内容列同宽的宿主：position 相对宿主定位，大屏上标题栏
                    // 才能与收窄后的列表左右对齐（直接挂 Stack 上会贴屏幕左缘）；
                    // hitTestBehavior(None) 让宿主自身不吞点击，标题栏以下的区域照常点得到列表。
                    Column.hitTestBehavior(HitTestMode.None);
                }, Column);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Row.create();
                    Row.width('100%');
                    Row.height(NAV_TITLE_BAR_HEIGHT);
                    Row.padding({ left: 16, right: 8 });
                    Row.alignItems(VerticalAlign.Center);
                    Row.position({ x: 0, y: this.safeTop });
                    Row.backgroundColor(Color.Transparent);
                    Row.attributeModifier.bind(this)(this.headerModifier);
                }, Row);
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Text.create(this.titleText);
                    Text.fontSize(20);
                    Text.fontWeight(FontWeight.Bold);
                    Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                    Text.maxLines(1);
                    Text.textOverflow({ overflow: TextOverflow.Ellipsis });
                    Text.layoutWeight(1);
                }, Text);
                Text.pop();
                this.HeaderActions.bind(this)();
                Row.pop();
                // 自绘标题栏（去掉返回键，返回走系统侧滑）：position 到状态栏下方，
                // 不再像系统标题栏那样压到状态栏 / 挖孔区域。
                // 外面包一层与内容列同宽的宿主：position 相对宿主定位，大屏上标题栏
                // 才能与收窄后的列表左右对齐（直接挂 Stack 上会贴屏幕左缘）；
                // hitTestBehavior(None) 让宿主自身不吞点击，标题栏以下的区域照常点得到列表。
                Column.pop();
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    If.create();
                    if (this.showRename) {
                        this.ifElseBranchUpdateFunction(0, () => {
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Column.create();
                                Column.width('100%');
                                Column.height('100%');
                                Column.backgroundColor({ "id": 16777242, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                Column.onClick((): void => {
                                    this.showRename = false;
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
                                Text.create('重命名歌单');
                                Text.fontSize(18);
                                Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                Text.margin({ bottom: 14 });
                            }, Text);
                            Text.pop();
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                TextInput.create({ placeholder: '歌单名称', text: this.renameName });
                                TextInput.width('100%');
                                TextInput.onChange((v: string): void => {
                                    this.renameName = v;
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
                                    this.showRename = false;
                                });
                            }, Button);
                            Button.pop();
                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                Button.createWithLabel('保存', { type: ButtonType.Normal });
                                Button.layoutWeight(1);
                                Button.height(44);
                                Button.backgroundColor({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                Button.fontColor({ "id": 16777236, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                Button.margin({ left: 12 });
                                Button.onClick((): void => {
                                    this.submitRename();
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
            }, { moduleName: "entry", pagePath: "entry/src/main/ets/pages/PlaylistDetail" });
            NavDestination.hideTitleBar(true);
            NavDestination.translate({ x: this.navTransX });
            NavDestination.customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
                return this.navTransitionDelegate(op, isEnter);
            });
        }, NavDestination);
        NavDestination.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
