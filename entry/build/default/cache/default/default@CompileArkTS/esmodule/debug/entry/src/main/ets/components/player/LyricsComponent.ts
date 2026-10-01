if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface LyricsComponent_Params {
    currentBreakpoint?: string;
    time?: number;
    isFoldFull?: boolean;
    isPlay?: boolean;
    currentTrack?: Track | null;
    /** 是否随歌词渲染底部控制区（SM 歌词页 true；LG/折叠分栏布局 false，控制区在封面侧） */
    isShowControl?: boolean;
    lyricScrollEffect?: LyricScrollEffect;
    mLrcEntryList?: Array<LrcEntry>;
    lastTrackKey?: string;
    lastLyricKey?: string;
    lastLyricHadDuration?: boolean;
    lyricToken?: number;
}
import type { Track, LyricLine } from '../../model/MusicModels';
import { LyricsApi } from "@normalized:N&&&entry/src/main/ets/api/LyricsApi&";
import { StyleConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/StyleConstants&";
import { BreakpointConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/BreakpointConstants&";
import { PlayerConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/PlayerConstants&";
import { BreakpointType } from "@normalized:N&&&entry/src/main/ets/common/utils/BreakpointSystem&";
import { LrcView } from "@normalized:N&&&entry/src/main/ets/lyric/LrcView&";
import type { LrcEntry } from '../../lyric/LrcEntry';
import { LyricScrollEffect, LyricTopPosition } from "@normalized:N&&&entry/src/main/ets/lyric/LyricConst&";
import { ControlAreaComponent } from "@normalized:N&&&entry/src/main/ets/components/player/ControlAreaComponent&";
import { STORE_CURRENT_TRACK, STORE_IS_PLAYING, STORE_PROGRESS, STORE_PLAYER_FOLD_FULL } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
export class LyricsComponent extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__currentBreakpoint = this.createStorageProp(BreakpointConstants.CURRENT_BREAKPOINT, BreakpointConstants.BREAKPOINT_SM, "currentBreakpoint");
        this.__time = this.createStorageLink(STORE_PROGRESS, 0, "time");
        this.__isFoldFull = this.createStorageLink(STORE_PLAYER_FOLD_FULL, false, "isFoldFull");
        this.__isPlay = this.createStorageLink(STORE_IS_PLAYING, false, "isPlay");
        this.__currentTrack = this.createStorageLink(STORE_CURRENT_TRACK, null, "currentTrack");
        this.isShowControl = true;
        this.lyricScrollEffect = LyricScrollEffect.Line;
        this.__mLrcEntryList = new ObservedPropertyObjectPU([], this, "mLrcEntryList");
        this.lastTrackKey = '';
        this.lastLyricKey = '';
        this.lastLyricHadDuration = false;
        this.lyricToken = 0;
        this.setInitiallyProvidedValue(params);
        this.declareWatch("currentTrack", this.onTrackChanged);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: LyricsComponent_Params) {
        if (params.isShowControl !== undefined) {
            this.isShowControl = params.isShowControl;
        }
        if (params.lyricScrollEffect !== undefined) {
            this.lyricScrollEffect = params.lyricScrollEffect;
        }
        if (params.mLrcEntryList !== undefined) {
            this.mLrcEntryList = params.mLrcEntryList;
        }
        if (params.lastTrackKey !== undefined) {
            this.lastTrackKey = params.lastTrackKey;
        }
        if (params.lastLyricKey !== undefined) {
            this.lastLyricKey = params.lastLyricKey;
        }
        if (params.lastLyricHadDuration !== undefined) {
            this.lastLyricHadDuration = params.lastLyricHadDuration;
        }
        if (params.lyricToken !== undefined) {
            this.lyricToken = params.lyricToken;
        }
    }
    updateStateVars(params: LyricsComponent_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__currentBreakpoint.purgeDependencyOnElmtId(rmElmtId);
        this.__time.purgeDependencyOnElmtId(rmElmtId);
        this.__isFoldFull.purgeDependencyOnElmtId(rmElmtId);
        this.__isPlay.purgeDependencyOnElmtId(rmElmtId);
        this.__currentTrack.purgeDependencyOnElmtId(rmElmtId);
        this.__mLrcEntryList.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__currentBreakpoint.aboutToBeDeleted();
        this.__time.aboutToBeDeleted();
        this.__isFoldFull.aboutToBeDeleted();
        this.__isPlay.aboutToBeDeleted();
        this.__currentTrack.aboutToBeDeleted();
        this.__mLrcEntryList.aboutToBeDeleted();
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
    /** 播放进度（秒）：LrcView 要毫秒，传入时 ×1000 */
    private __time: ObservedPropertyAbstractPU<number>;
    get time() {
        return this.__time.get();
    }
    set time(newValue: number) {
        this.__time.set(newValue);
    }
    private __isFoldFull: ObservedPropertyAbstractPU<boolean>;
    get isFoldFull() {
        return this.__isFoldFull.get();
    }
    set isFoldFull(newValue: boolean) {
        this.__isFoldFull.set(newValue);
    }
    private __isPlay: ObservedPropertyAbstractPU<boolean>;
    get isPlay() {
        return this.__isPlay.get();
    }
    set isPlay(newValue: boolean) {
        this.__isPlay.set(newValue);
    }
    private __currentTrack: ObservedPropertyAbstractPU<Track | null>;
    get currentTrack() {
        return this.__currentTrack.get();
    }
    set currentTrack(newValue: Track | null) {
        this.__currentTrack.set(newValue);
    }
    /** 是否随歌词渲染底部控制区（SM 歌词页 true；LG/折叠分栏布局 false，控制区在封面侧） */
    private isShowControl: boolean;
    /** 歌词滚动效果（行级时间轴只支持 Line） */
    private lyricScrollEffect: LyricScrollEffect;
    private __mLrcEntryList: ObservedPropertyObjectPU<Array<LrcEntry>>;
    get mLrcEntryList() {
        return this.__mLrcEntryList.get();
    }
    set mLrcEntryList(newValue: Array<LrcEntry>) {
        this.__mLrcEntryList.set(newValue);
    }
    /** 同曲守卫：封面等字段异步补全不应重置歌词 */
    private lastTrackKey: string;
    /** 上一次真正发起歌词请求时的「信息键」（id + 标题 + 歌手 + 时长是否已知） */
    private lastLyricKey: string;
    /** 上一次发起歌词请求时是否已有时长（缺时长搜出来的「没有歌词」结论不可信） */
    private lastLyricHadDuration: boolean;
    /** 歌词请求令牌：切歌 / 信息补全后，在途的旧请求结果必须丢弃 */
    private lyricToken: number;
    aboutToAppear(): void {
        this.onTrackChanged();
    }
    /**
     * 当前曲目的「信息键」：不能只拿 id 去重 —— 列表数据可能缺时长 / 标题，
     * 而歌词候选打分拿它们做加分项；音源解析补全后必须允许重搜。
     */
    private lyricKeyOf(track: Track): string {
        return `${track.id}|${track.title}|${track.artist}|${track.duration > 0 ? 'd' : 'n'}`;
    }
    onTrackChanged(): void {
        const track: Track | null = this.currentTrack;
        if (track === null) {
            this.lastTrackKey = '';
            this.lastLyricKey = '';
            this.lastLyricHadDuration = false;
            this.lyricToken++;
            this.mLrcEntryList = [];
            return;
        }
        const key: string = this.lyricKeyOf(track);
        if (key === this.lastLyricKey) {
            // 同一首、关键信息没变（例如只是封面被异步补全）→ 不重复请求
            return;
        }
        const hadDuration: boolean = this.lastLyricHadDuration;
        if (track.id !== this.lastTrackKey) {
            this.lastTrackKey = track.id;
            // 换歌立刻清空上一首的歌词，避免新歌词到达前显示错位内容
            this.mLrcEntryList = [];
        }
        this.lastLyricKey = key;
        this.lastLyricHadDuration = track.duration > 0;
        if (track.duration > 0 && !hadDuration) {
            // 上一次是拿「缺时长」的信息搜的，那次「查不到」的结论（miss 缓存）不可信
            LyricsApi.clearLyricCache(track.id);
        }
        this.loadLyrics();
    }
    private async loadLyrics(): Promise<void> {
        const track: Track | null = this.currentTrack;
        if (track === null) {
            this.mLrcEntryList = [];
            return;
        }
        // 歌词要经多轮网络往返，期间可能已切歌；令牌保证只采纳最后一次请求
        const token: number = ++this.lyricToken;
        try {
            const result = await LyricsApi.getLyricForTrack(track);
            if (token !== this.lyricToken) {
                return;
            }
            this.mLrcEntryList = result !== null ? this.toLrcEntries(result.lines) : [];
        }
        catch (err) {
            if (token !== this.lyricToken) {
                return;
            }
            const msg: string = err instanceof Error ? err.message : String(err);
            console.error(`Failed to load lyric: ${msg}`);
            this.mLrcEntryList = [];
        }
    }
    /** 行级时间轴（秒）→ LrcEntry（毫秒）；最后一行时长无限，唱完仍保持高亮 */
    private toLrcEntries(lines: LyricLine[]): LrcEntry[] {
        const out: LrcEntry[] = [];
        for (let i = 0; i < lines.length; i++) {
            const startMs: number = lines[i].time * 1000;
            const durMs: number = i < lines.length - 1
                ? lines[i + 1].time * 1000 - startMs
                : Number.MAX_VALUE;
            out.push({
                lineStartTime: startMs,
                lineDuration: durMs,
                lineWords: lines[i].text,
                words: []
            });
        }
        return out;
    }
    private coverUrl(): string {
        return this.currentTrack !== null ? this.currentTrack.coverUrl : '';
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
            Column.create();
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_SM) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Row.create();
                        Row.width(StyleConstants.FULL_WIDTH);
                        Row.justifyContent(FlexAlign.Start);
                        Row.margin({
                            top: new BreakpointType<Resource>({
                                sm: { "id": 16777272, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                                md: { "id": 16777311, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                                lg: { "id": 16777311, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                            }).getValue(this.currentBreakpoint),
                            bottom: { "id": 16777271, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        });
                    }, Row);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        If.create();
                        if (this.coverUrl().length > 0) {
                            this.ifElseBranchUpdateFunction(0, () => {
                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                    Image.create(this.coverUrl());
                                    Image.width({ "id": 16777276, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                    Image.height({ "id": 16777276, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                    Image.borderRadius({ "id": 16777273, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                    Image.margin({ right: { "id": 16777274, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } });
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
                        Column.alignItems(HorizontalAlign.Start);
                        Column.layoutWeight(1);
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.titleText());
                        Text.fontSize(new BreakpointType<Resource>({
                            sm: { "id": 16777308, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            md: { "id": 16777305, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            lg: { "id": 16777304, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        }).getValue(this.currentBreakpoint));
                        Text.fontColor(Color.White);
                        Text.fontWeight(PlayerConstants.FONT_WEIGHT_700);
                        Text.fontFamily(PlayerConstants.FONT_FAMILY_BOLD);
                        Text.maxLines(1);
                        Text.textOverflow({ overflow: TextOverflow.Ellipsis });
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.artistText());
                        Text.fontSize(new BreakpointType<Resource>({
                            sm: { "id": 16777294, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            md: { "id": 16777293, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            lg: { "id": 16777292, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        }).getValue(this.currentBreakpoint));
                        Text.fontColor({ "id": 16777238, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.fontWeight(PlayerConstants.FONT_WEIGHT_500);
                        Text.fontFamily(PlayerConstants.FONT_FAMILY_MEDIUM);
                        Text.margin({ top: { "id": 16777295, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } });
                        Text.maxLines(1);
                        Text.textOverflow({ overflow: TextOverflow.Ellipsis });
                    }, Text);
                    Text.pop();
                    Column.pop();
                    Row.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Row.create();
                        Row.layoutWeight(1);
                    }, Row);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        GridRow.create({
                            columns: { lg: BreakpointConstants.COLUMN_LYRIC_LG }
                        });
                    }, GridRow);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        GridCol.create({
                            span: { lg: BreakpointConstants.SPAN_LYRIC_LG },
                            offset: BreakpointConstants.OFFSET_MD
                        });
                    }, GridCol);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        __Common__.create();
                        __Common__.layoutWeight(1);
                    }, __Common__);
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new LrcView(this, {
                                    lyricMilliSecondsTime: this.time * 1000,
                                    mLrcEntryList: this.mLrcEntryList,
                                    lyricScrollEffect: this.lyricScrollEffect,
                                    isPlay: this.isPlay,
                                    lyricTopPosition: LyricTopPosition.Middle
                                }, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/LyricsComponent.ets", line: 219, col: 17 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {
                                        lyricMilliSecondsTime: this.time * 1000,
                                        mLrcEntryList: this.mLrcEntryList,
                                        lyricScrollEffect: this.lyricScrollEffect,
                                        isPlay: this.isPlay,
                                        lyricTopPosition: LyricTopPosition.Middle
                                    };
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {
                                    lyricMilliSecondsTime: this.time * 1000,
                                    mLrcEntryList: this.mLrcEntryList,
                                    lyricScrollEffect: this.lyricScrollEffect,
                                    isPlay: this.isPlay
                                });
                            }
                        }, { name: "LrcView" });
                    }
                    __Common__.pop();
                    Column.pop();
                    GridCol.pop();
                    GridRow.pop();
                    Row.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        __Common__.create();
                        __Common__.layoutWeight(1);
                    }, __Common__);
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new LrcView(this, {
                                    lyricMilliSecondsTime: this.time * 1000,
                                    mLrcEntryList: this.mLrcEntryList,
                                    lyricScrollEffect: this.lyricScrollEffect,
                                    isPlay: this.isPlay,
                                    lyricTopPosition: LyricTopPosition.Middle
                                }, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/LyricsComponent.ets", line: 233, col: 9 });
                                ViewPU.create(componentCall);
                                let paramsLambda = () => {
                                    return {
                                        lyricMilliSecondsTime: this.time * 1000,
                                        mLrcEntryList: this.mLrcEntryList,
                                        lyricScrollEffect: this.lyricScrollEffect,
                                        isPlay: this.isPlay,
                                        lyricTopPosition: LyricTopPosition.Middle
                                    };
                                };
                                componentCall.paramsGenerator_ = paramsLambda;
                            }
                            else {
                                this.updateStateVarsOfChildByElmtId(elmtId, {
                                    lyricMilliSecondsTime: this.time * 1000,
                                    mLrcEntryList: this.mLrcEntryList,
                                    lyricScrollEffect: this.lyricScrollEffect,
                                    isPlay: this.isPlay
                                });
                            }
                        }, { name: "LrcView" });
                    }
                    __Common__.pop();
                });
            }
        }, If);
        If.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.isShowControl) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        __Common__.create();
                        __Common__.margin({
                            top: { "id": 16777261, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                            bottom: { "id": 16777286, "type": 10002, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
                        });
                    }, __Common__);
                    {
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            if (isInitialRender) {
                                let componentCall = new ControlAreaComponent(this, {}, undefined, elmtId, () => { }, { page: "entry/src/main/ets/components/player/LyricsComponent.ets", line: 244, col: 9 });
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
                    __Common__.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
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
