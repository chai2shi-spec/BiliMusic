if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface DownloadsPage_Params {
    tasks?: DownloadTask[];
    currentBreakpoint?: string;
    queuePaused?: boolean;
    safeBottom?: number;
    currentTrack?: Track | null;
    selecting?: boolean;
    selectedIds?: string[];
    expandedGroups?: string[];
    pressedKey?: string;
    animTaskId?: string;
    animPercent?: number;
    animSpeed?: number;
    animBytes?: number;
    animGroupKey?: string;
    animGroupPercent?: number;
    animGroupSpeed?: number;
}
import { DownloadStatus, buildTrack } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
import type { DownloadTask, Track } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
import { DownloadManager } from "@normalized:N&&&entry/src/main/ets/service/DownloadManager&";
import { MusicPlayer } from "@normalized:N&&&entry/src/main/ets/player/MusicPlayer&";
import { AUDIO_QUALITY_LABEL, CONTENT_END_OFFSET, STORE_CURRENT_TRACK, STORE_DOWNLOAD_PAUSED, STORE_DOWNLOAD_TASKS, STORE_SAFE_BOTTOM, formatAudioBitrate } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
import { BreakpointConstants } from "@normalized:N&&&entry/src/main/ets/common/constants/BreakpointConstants&";
import { PRESS_SCALE, PRESS_ANIM_MS, SELECT_SLOT_VP, SELECT_TOGGLE_MS, DOWNLOAD_SMOOTH_MS } from "@normalized:N&&&entry/src/main/ets/common/constants/InteractionConstants&";
import { showAppToast } from "@normalized:N&&&entry/src/main/ets/components/AppToast&";
import fs from "@ohos:file.fs";
/**
 * 行内图标按钮的命中区边长。
 *
 * 视觉上图标只有 18px，但手指可靠触达的下限是 44vp（约 7mm）——
 * 直接把图标做到 44px 会破坏版面，正确做法是**视觉不变、命中区撑开**
 * （外层容器 44×44 + 图标居中）。列表行右侧的删除按钮即用此值。
 */
const ROW_ACTION_HIT: number = 44;
function mbText(bytes: number): string {
    return `${(bytes / (1024 * 1024)).toFixed(1)}MB`;
}
function speedText(bytesPerSecond: number): string {
    if (bytesPerSecond < 1024) {
        return `${bytesPerSecond} B/s`;
    }
    const kb: number = bytesPerSecond / 1024;
    if (kb < 1024) {
        return `${kb.toFixed(1)} KB/s`;
    }
    return `${(kb / 1024).toFixed(2)} MB/s`;
}
/**
 * 下载列表的分组视图模型：多 P 合集展开出的 N 个分 P 任务归成**一个**条目显示，
 * 点开才看到每个分 P 各自的进度（分组的推导见 groupKeyOf）。
 */
interface DownloadGroup {
    /** 分组键：合集的 bvid；非合集条目为任务 id（永不与 bvid 撞车） */
    key: string;
    /** 组头标题：取组内最早创建任务的标题（下载入口保证首个分 P 带的是合集标题） */
    title: string;
    coverUrl: string;
    /** 组内任务（按创建时间升序 = 分 P 的排队顺序） */
    tasks: DownloadTask[];
}
/** 合组的各状态计数，供组头文案与 ForEach key 共用 */
interface GroupCounts {
    done: number;
    downloading: number;
    pending: number;
    paused: number;
    failed: number;
}
export class DownloadsPage extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__tasks = this.createStorageLink(STORE_DOWNLOAD_TASKS, [], "tasks");
        this.__currentBreakpoint = this.createStorageProp(BreakpointConstants.CURRENT_BREAKPOINT, BreakpointConstants.BREAKPOINT_SM, "currentBreakpoint");
        this.__queuePaused = this.createStorageLink(STORE_DOWNLOAD_PAUSED, false, "queuePaused");
        this.__safeBottom = this.createStorageLink(STORE_SAFE_BOTTOM, 0, "safeBottom");
        this.__currentTrack = this.createStorageLink(STORE_CURRENT_TRACK, null, "currentTrack");
        this.__selecting = new ObservedPropertySimplePU(false, this, "selecting");
        this.__selectedIds = new ObservedPropertyObjectPU([], this, "selectedIds");
        this.__expandedGroups = new ObservedPropertyObjectPU([], this, "expandedGroups");
        this.__pressedKey = new ObservedPropertySimplePU('', this, "pressedKey");
        this.__animTaskId = new ObservedPropertySimplePU('', this, "animTaskId");
        this.__animPercent = new ObservedPropertySimplePU(0, this, "animPercent");
        this.__animSpeed = new ObservedPropertySimplePU(0, this, "animSpeed");
        this.__animBytes = new ObservedPropertySimplePU(0, this, "animBytes");
        this.__animGroupKey = new ObservedPropertySimplePU('', this, "animGroupKey");
        this.__animGroupPercent = new ObservedPropertySimplePU(-1, this, "animGroupPercent");
        this.__animGroupSpeed = new ObservedPropertySimplePU(0, this, "animGroupSpeed");
        this.setInitiallyProvidedValue(params);
        this.declareWatch("tasks", this.onTasksSnapshot);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: DownloadsPage_Params) {
        if (params.selecting !== undefined) {
            this.selecting = params.selecting;
        }
        if (params.selectedIds !== undefined) {
            this.selectedIds = params.selectedIds;
        }
        if (params.expandedGroups !== undefined) {
            this.expandedGroups = params.expandedGroups;
        }
        if (params.pressedKey !== undefined) {
            this.pressedKey = params.pressedKey;
        }
        if (params.animTaskId !== undefined) {
            this.animTaskId = params.animTaskId;
        }
        if (params.animPercent !== undefined) {
            this.animPercent = params.animPercent;
        }
        if (params.animSpeed !== undefined) {
            this.animSpeed = params.animSpeed;
        }
        if (params.animBytes !== undefined) {
            this.animBytes = params.animBytes;
        }
        if (params.animGroupKey !== undefined) {
            this.animGroupKey = params.animGroupKey;
        }
        if (params.animGroupPercent !== undefined) {
            this.animGroupPercent = params.animGroupPercent;
        }
        if (params.animGroupSpeed !== undefined) {
            this.animGroupSpeed = params.animGroupSpeed;
        }
    }
    updateStateVars(params: DownloadsPage_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__tasks.purgeDependencyOnElmtId(rmElmtId);
        this.__currentBreakpoint.purgeDependencyOnElmtId(rmElmtId);
        this.__queuePaused.purgeDependencyOnElmtId(rmElmtId);
        this.__safeBottom.purgeDependencyOnElmtId(rmElmtId);
        this.__currentTrack.purgeDependencyOnElmtId(rmElmtId);
        this.__selecting.purgeDependencyOnElmtId(rmElmtId);
        this.__selectedIds.purgeDependencyOnElmtId(rmElmtId);
        this.__expandedGroups.purgeDependencyOnElmtId(rmElmtId);
        this.__pressedKey.purgeDependencyOnElmtId(rmElmtId);
        this.__animTaskId.purgeDependencyOnElmtId(rmElmtId);
        this.__animPercent.purgeDependencyOnElmtId(rmElmtId);
        this.__animSpeed.purgeDependencyOnElmtId(rmElmtId);
        this.__animBytes.purgeDependencyOnElmtId(rmElmtId);
        this.__animGroupKey.purgeDependencyOnElmtId(rmElmtId);
        this.__animGroupPercent.purgeDependencyOnElmtId(rmElmtId);
        this.__animGroupSpeed.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__tasks.aboutToBeDeleted();
        this.__currentBreakpoint.aboutToBeDeleted();
        this.__queuePaused.aboutToBeDeleted();
        this.__safeBottom.aboutToBeDeleted();
        this.__currentTrack.aboutToBeDeleted();
        this.__selecting.aboutToBeDeleted();
        this.__selectedIds.aboutToBeDeleted();
        this.__expandedGroups.aboutToBeDeleted();
        this.__pressedKey.aboutToBeDeleted();
        this.__animTaskId.aboutToBeDeleted();
        this.__animPercent.aboutToBeDeleted();
        this.__animSpeed.aboutToBeDeleted();
        this.__animBytes.aboutToBeDeleted();
        this.__animGroupKey.aboutToBeDeleted();
        this.__animGroupPercent.aboutToBeDeleted();
        this.__animGroupSpeed.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private __tasks: ObservedPropertyAbstractPU<DownloadTask[]>;
    get tasks() {
        return this.__tasks.get();
    }
    set tasks(newValue: DownloadTask[]) {
        this.__tasks.set(newValue);
    }
    /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
    private __currentBreakpoint: ObservedPropertyAbstractPU<string>;
    get currentBreakpoint() {
        return this.__currentBreakpoint.get();
    }
    set currentBreakpoint(newValue: string) {
        this.__currentBreakpoint.set(newValue);
    }
    /** 队列级暂停状态：单条任务的 PAUSED 只说明它自己停了，这里表示整条队列都不动了 */
    private __queuePaused: ObservedPropertyAbstractPU<boolean>;
    get queuePaused() {
        return this.__queuePaused.get();
    }
    set queuePaused(newValue: boolean) {
        this.__queuePaused.set(newValue);
    }
    /** 底部安全区高度（vp）：根容器不再统一避让，列表末尾让位要自己叠上这一份 */
    private __safeBottom: ObservedPropertyAbstractPU<number>;
    get safeBottom() {
        return this.__safeBottom.get();
    }
    set safeBottom(newValue: number) {
        this.__safeBottom.set(newValue);
    }
    /** 正在播放的曲目：给对应的下载行打「正在播放」标记 */
    private __currentTrack: ObservedPropertyAbstractPU<Track | null>;
    get currentTrack() {
        return this.__currentTrack.get();
    }
    set currentTrack(newValue: Track | null) {
        this.__currentTrack.set(newValue);
    }
    private __selecting: ObservedPropertySimplePU<boolean>;
    get selecting() {
        return this.__selecting.get();
    }
    set selecting(newValue: boolean) {
        this.__selecting.set(newValue);
    }
    /** 已选中的任务 id。刻意用数组而不是 Set —— @State 感知不到 Set 的内容变化 */
    private __selectedIds: ObservedPropertyObjectPU<string[]>;
    get selectedIds() {
        return this.__selectedIds.get();
    }
    set selectedIds(newValue: string[]) {
        this.__selectedIds.set(newValue);
    }
    /** 已展开的合集分组键（bvid）。默认收起：列表里一个合集只占一行，点开才铺开分 P */
    private __expandedGroups: ObservedPropertyObjectPU<string[]>;
    get expandedGroups() {
        return this.__expandedGroups.get();
    }
    set expandedGroups(newValue: string[]) {
        this.__expandedGroups.set(newValue);
    }
    /**
     * 按压缩放（TrackItem 模式推广）：当前被按下行的稳定标识，空串＝无按压。
     * 单指操作同一时刻只有一行被按下，一个变量即可驱动任意行缩放，
     * 不必给每个 @Builder 行配独立组件/独立状态。
     * 刻意用稳定 id（任务 id / 合集 bvid）而不是 rowKey —— rowKey 编入了
     * 进度档位，下载中每秒都在变，按住期间 key 漂移会让缩放中途弹回 1.0。
     */
    private __pressedKey: ObservedPropertySimplePU<string>;
    get pressedKey() {
        return this.__pressedKey.get();
    }
    set pressedKey(newValue: string) {
        this.__pressedKey.set(newValue);
    }
    /** 按压状态回写：Down 记录、Up/Cancel 清除；只清自己，避免误清别的行的按压 */
    private setPressed(type: TouchType, key: string): void {
        if (type === TouchType.Down) {
            this.pressedKey = key;
        }
        else if ((type === TouchType.Up || type === TouchType.Cancel) && this.pressedKey === key) {
            this.pressedKey = '';
        }
    }
    /**
     * ══════════ 下载中数值的动画镜像 ══════════
     *
     * 快照里的数字是瞬时值，直接渲染会让进度条按 5% 分桶跳档、速度/体积长时间冻结后
     * 突跳。快照到达时（onTasksSnapshot）用 animateTo 把镜像平滑推到新值；下载中的行
     * 读镜像而非冻结的 t（见 percent / statusText / groupPercent），进度条因此连续滑动。
     * 串行下载队列同时最多一条在传，单任务镜像 + 单分组镜像即可覆盖。
     */
    /** 镜像接管的在传任务 id（空串 = 无在传任务，全部行回落到冻结快照渲染） */
    private __animTaskId: ObservedPropertySimplePU<string>;
    get animTaskId() {
        return this.__animTaskId.get();
    }
    set animTaskId(newValue: string) {
        this.__animTaskId.set(newValue);
    }
    /** 0~100 连续浮点（不取整：进度条交给 animateTo 插值，文案展示处再取整） */
    private __animPercent: ObservedPropertySimplePU<number>;
    get animPercent() {
        return this.__animPercent.get();
    }
    set animPercent(newValue: number) {
        this.__animPercent.set(newValue);
    }
    private __animSpeed: ObservedPropertySimplePU<number>;
    get animSpeed() {
        return this.__animSpeed.get();
    }
    set animSpeed(newValue: number) {
        this.__animSpeed.set(newValue);
    }
    private __animBytes: ObservedPropertySimplePU<number>;
    get animBytes() {
        return this.__animBytes.get();
    }
    set animBytes(newValue: number) {
        this.__animBytes.set(newValue);
    }
    /** 镜像接管的分组键（bvid）；分组聚合进度/速度同理 */
    private __animGroupKey: ObservedPropertySimplePU<string>;
    get animGroupKey() {
        return this.__animGroupKey.get();
    }
    set animGroupKey(newValue: string) {
        this.__animGroupKey.set(newValue);
    }
    /** -1 = 分组总大小未知（界面据此显示不确定进度环） */
    private __animGroupPercent: ObservedPropertySimplePU<number>;
    get animGroupPercent() {
        return this.__animGroupPercent.get();
    }
    set animGroupPercent(newValue: number) {
        this.__animGroupPercent.set(newValue);
    }
    private __animGroupSpeed: ObservedPropertySimplePU<number>;
    get animGroupSpeed() {
        return this.__animGroupSpeed.get();
    }
    set animGroupSpeed(newValue: number) {
        this.__animGroupSpeed.set(newValue);
    }
    /**
     * 快照到达：把在传任务（及其所在分组）的目标值用 fast(150ms) Linear animateTo
     * 推给镜像。animateTo 重定目标时从**当前视觉值**起算，快照连发时进度条连续滑动
     * 不回跳（与播放页进度条同一套手法，见 ControlAreaComponent）。
     * 文本数字不吃插值（Text 内容非动画属性），但镜像每份快照都更新，数字从
     * 「每 5% 一档」细化到「每份快照一小步」，配合进度条已足够平滑。
     */
    private onTasksSnapshot(): void {
        const active: DownloadTask | undefined = this.tasks.find((t: DownloadTask): boolean => t.status === DownloadStatus.DOWNLOADING);
        if (active === undefined) {
            // 无在传任务：清掉镜像归属即可；刚停下的行会因 status 变化走重建渲染最终文案
            this.animTaskId = '';
            this.animGroupKey = '';
            return;
        }
        const gk: string = this.groupKeyOf(active);
        let doneBytes: number = 0;
        let totalBytes: number = 0;
        let groupSpeed: number = 0;
        for (let i = 0; i < this.tasks.length; i++) {
            if (this.groupKeyOf(this.tasks[i]) === gk) {
                doneBytes += this.tasks[i].downloadedBytes;
                totalBytes += this.tasks[i].totalBytes;
                groupSpeed += this.tasks[i].speed;
            }
        }
        // 下载字节数可能略超 Content-Length，夹住避免出现 100.x%
        const rawPercent: number = active.totalBytes > 0
            ? (active.downloadedBytes / active.totalBytes) * 100 : 0;
        const targetPercent: number = rawPercent > 100 ? 100 : rawPercent;
        const targetGroupPercent: number = totalBytes > 0 ? (doneBytes / totalBytes) * 100 : -1;
        this.getUIContext().animateTo({ duration: DOWNLOAD_SMOOTH_MS, curve: Curve.Linear }, (): void => {
            this.animTaskId = active.id;
            this.animPercent = targetPercent;
            this.animSpeed = active.speed;
            this.animBytes = active.downloadedBytes;
            this.animGroupKey = gk;
            this.animGroupPercent = targetGroupPercent;
            this.animGroupSpeed = groupSpeed;
        });
    }
    aboutToAppear(): void {
        // 载入历史任务；后续所有进度/状态变化由 DownloadManager 推送到同一个 AppStorage 键
        DownloadManager.getInstance().ensureLoaded().catch((e: Error): void => {
            console.error(`load downloads failed: ${JSON.stringify(e)}`);
        });
    }
    private percent(t: DownloadTask): number {
        if (t.status === DownloadStatus.COMPLETED) {
            return 100;
        }
        // 镜像接管的在传任务：返回连续浮点，进度条由 animateTo 插值平滑推进；
        // 文案展示处再取整（见 statusText）。
        if (this.animTaskId === t.id && t.status === DownloadStatus.DOWNLOADING) {
            return this.animPercent;
        }
        if (t.totalBytes <= 0) {
            return 0;
        }
        const p: number = Math.floor((t.downloadedBytes / t.totalBytes) * 100);
        return p > 100 ? 100 : p;
    }
    /**
     * 实际码率文案。**优先实测带宽**：低码率源会给 30280 这个「192K」标签
     * 配上只有 66k 的实测带宽（B 站侧只有一份低码率音源时三个档位指向同一份数据），
     * 直接显示档位标签就是在骗用户。
     */
    private qualityText(t: DownloadTask): string {
        if (t.audioBandwidth > 0) {
            return formatAudioBitrate(t.audioBandwidth);
        }
        if (t.audioQuality > 0) {
            return AUDIO_QUALITY_LABEL[t.audioQuality] || '';
        }
        return '';
    }
    /**
     * 状态行文案。
     *
     * 下载中拼成「下载中 42%  ·  1.2 MB/s  ·  3.4MB/8.0MB」：
     * 百分比给整体感，速度给「是不是卡住了」的判断依据，两个体积给精确进度。
     * 速度缺失（刚开始的 1s 内 / 已断流归零）时该段自动省略，不留空占位。
     */
    private statusText(t: DownloadTask): string {
        switch (t.status) {
            case DownloadStatus.DOWNLOADING: {
                // 速度/体积同样读镜像：每份快照都刷新，不再随 5% 分桶冻结后突跳
                const tracked: boolean = this.animTaskId === t.id;
                const speed: number = tracked ? this.animSpeed : t.speed;
                const bytes: number = tracked ? this.animBytes : t.downloadedBytes;
                const parts: string[] = [];
                parts.push(t.totalBytes > 0 ? `下载中 ${Math.floor(this.percent(t))}%` : '下载中');
                if (speed > 0) {
                    parts.push(speedText(speed));
                }
                if (t.totalBytes > 0) {
                    parts.push(`${mbText(bytes)}/${mbText(t.totalBytes)}`);
                }
                else if (bytes > 0) {
                    parts.push(`已下载 ${mbText(bytes)}`);
                }
                return parts.join('  ·  ');
            }
            case DownloadStatus.COMPLETED: {
                const parts: string[] = ['已完成'];
                const q: string = this.qualityText(t);
                if (q.length > 0) {
                    parts.push(q);
                }
                if (t.totalBytes > 0) {
                    parts.push(mbText(t.totalBytes));
                }
                return parts.join('  ·  ');
            }
            case DownloadStatus.ERROR:
                return t.errorMessage.length > 0 ? t.errorMessage : '下载失败';
            case DownloadStatus.PENDING:
                return this.queuePaused ? '排队中…（已暂停）' : '排队中…';
            case DownloadStatus.PAUSED:
                // 暂停时把已下到哪儿也说出来，用户才知道「继续」是从这儿接着走的
                return t.totalBytes > 0
                    ? `已暂停  ${this.percent(t)}%  ·  ${mbText(t.downloadedBytes)}/${mbText(t.totalBytes)}`
                    : '已暂停';
            default:
                return '';
        }
    }
    private isCurrent(t: DownloadTask): boolean {
        const cur: Track | null = this.currentTrack;
        if (!cur) {
            return false;
        }
        return cur.id === (t.musicId.length > 0 ? t.musicId : t.id);
    }
    private isSelected(id: string): boolean {
        return this.selectedIds.indexOf(id) >= 0;
    }
    /**
     * ForEach 的 key。**只编入不靠镜像/局部状态刷新的变化** —— 理由见文件头注释。
     *   · status：任何状态迁移都要重建（文案/结构全变）；
     *   · hasTotal：totalBytes 未知→已知切换「不确定进度环 ↔ 进度条」结构分支；
     *   · bucket：**仅未被镜像接管的下载行**编入 5% 分桶兜底；镜像行若也编入，
     *     每 5% 一次的重建会把进度条打回目标值，animateTo 就断了。
     * 选择模式（selecting / 选中态）刻意不进 key：多选进出要对保留节点做
     * 槽位展开动画（见 TaskRow），选中 ✓ 由保留节点读 @State selectedIds 局部刷新。
     */
    private rowKey(t: DownloadTask): string {
        const tracked: boolean = this.animTaskId === t.id && t.status === DownloadStatus.DOWNLOADING;
        const bucket: number = !tracked && t.status === DownloadStatus.DOWNLOADING
            ? Math.floor(this.percent(t) / 5) : 0;
        const hasTotal: number = t.totalBytes > 0 ? 1 : 0;
        return `${t.id}|${t.status}|${hasTotal}${bucket}`;
    }
    // ===== 合集（多 P）分组 =====
    /**
     * 推导一条任务所属的分组键。
     *
     * 分 P 任务由 expandVideoParts 展开，musicId 形如 `BV1xx…#cid`（首个分 P 复用
     * 原条目 id，即纯 bvid）。因此：BV 开头的 musicId 取 `#` 前的 bvid 归组；
     * 音乐中心那类音乐 id 一条任务自成一组，用任务 id 保证绝不与别人合并。
     * 单 P 视频的组里只有它自己，渲染上与普通行完全一致（见 buildGroups 后的分支）。
     */
    private groupKeyOf(t: DownloadTask): string {
        const mid: string = t.musicId.length > 0 ? t.musicId : t.id;
        if (mid.indexOf('BV') === 0) {
            const hash: number = mid.indexOf('#');
            return hash > 0 ? mid.substring(0, hash) : mid;
        }
        return t.id;
    }
    /**
     * 把扁平任务表归成分组视图。
     * 组内按创建时间升序（= 分 P 排队顺序）；组间按组内最新任务的创建时间降序，
     * 与原列表「新在前」的观感保持一致。
     */
    private buildGroups(): DownloadGroup[] {
        const map: Map<string, DownloadGroup> = new Map<string, DownloadGroup>();
        for (let i = 0; i < this.tasks.length; i++) {
            const t: DownloadTask = this.tasks[i];
            const key: string = this.groupKeyOf(t);
            let g: DownloadGroup | undefined = map.get(key);
            if (g === undefined) {
                const created: DownloadGroup = { key: key, title: '', coverUrl: '', tasks: [] };
                map.set(key, created);
                g = created;
            }
            g.tasks.push(t);
        }
        const groups: DownloadGroup[] = [];
        map.forEach((g: DownloadGroup): void => {
            g.tasks.sort((a: DownloadTask, b: DownloadTask): number => a.createdAt - b.createdAt);
            const head: DownloadTask = g.tasks[0];
            g.title = head.title;
            g.coverUrl = head.coverUrl;
            groups.push(g);
        });
        groups.sort((a: DownloadGroup, b: DownloadGroup): number => {
            const la: number = a.tasks[a.tasks.length - 1].createdAt;
            const lb: number = b.tasks[b.tasks.length - 1].createdAt;
            return lb - la;
        });
        return groups;
    }
    private countGroup(g: DownloadGroup): GroupCounts {
        const c: GroupCounts = { done: 0, downloading: 0, pending: 0, paused: 0, failed: 0 };
        for (let i = 0; i < g.tasks.length; i++) {
            switch (g.tasks[i].status) {
                case DownloadStatus.COMPLETED:
                    c.done += 1;
                    break;
                case DownloadStatus.DOWNLOADING:
                    c.downloading += 1;
                    break;
                case DownloadStatus.PENDING:
                    c.pending += 1;
                    break;
                case DownloadStatus.PAUSED:
                    c.paused += 1;
                    break;
                case DownloadStatus.ERROR:
                    c.failed += 1;
                    break;
                default:
                    break;
            }
        }
        return c;
    }
    /** 整组进度（0~100）。任何一条的总大小未知时返回 -1（界面据此显示不确定态） */
    private groupPercent(g: DownloadGroup): number {
        // 镜像接管的在传分组：返回连续浮点，进度条由 animateTo 插值平滑推进
        if (this.animGroupKey === g.key) {
            return this.animGroupPercent;
        }
        let doneBytes: number = 0;
        let totalBytes: number = 0;
        for (let i = 0; i < g.tasks.length; i++) {
            doneBytes += g.tasks[i].downloadedBytes;
            totalBytes += g.tasks[i].totalBytes;
        }
        if (totalBytes <= 0) {
            return -1;
        }
        const p: number = Math.floor((doneBytes / totalBytes) * 100);
        return p > 100 ? 100 : p;
    }
    /** 整组实时速度 = 各分 P 速度之和（串行队列里同时最多一条在传，求和即为兼容并发而写） */
    private groupSpeed(g: DownloadGroup): number {
        if (this.animGroupKey === g.key) {
            return this.animGroupSpeed;
        }
        let sum: number = 0;
        for (let i = 0; i < g.tasks.length; i++) {
            sum += g.tasks[i].speed;
        }
        return sum;
    }
    private groupHasActive(g: DownloadGroup): boolean {
        return g.tasks.some((t: DownloadTask): boolean => t.status === DownloadStatus.DOWNLOADING || t.status === DownloadStatus.PENDING);
    }
    private groupStatusText(g: DownloadGroup): string {
        const c: GroupCounts = this.countGroup(g);
        const total: number = g.tasks.length;
        if (c.done === total) {
            return `已完成 · 共 ${total} 首`;
        }
        const parts: string[] = [];
        if (c.downloading > 0) {
            // 镜像接管时为连续浮点，展示取整
            const p: number = this.groupPercent(g);
            parts.push(p >= 0 ? `下载中 ${Math.floor(p)}%` : '下载中');
            const sp: number = this.groupSpeed(g);
            if (sp > 0) {
                parts.push(speedText(sp));
            }
        }
        else if (c.pending > 0) {
            parts.push(this.queuePaused ? '排队中…（已暂停）' : '排队中…');
        }
        else if (c.paused > 0) {
            const p: number = this.groupPercent(g);
            parts.push(p >= 0 ? `已暂停 ${p}%` : '已暂停');
        }
        parts.push(`已下载 ${c.done}/${total}`);
        if (c.failed > 0) {
            parts.push(`${c.failed} 首失败`);
        }
        return parts.join('  ·  ');
    }
    /**
     * 分组行的 ForEach key。与 rowKey 同理（见文件头注释）：只编入不靠镜像/局部状态
     * 刷新的变化 —— 状态计数、任务数、总大小未知→已知、展开态。
     * bucket 仅未接管的分组编入；选择模式刻意不进 key（见 rowKey）。
     */
    private groupRowKey(g: DownloadGroup): string {
        const c: GroupCounts = this.countGroup(g);
        const tracked: boolean = this.animGroupKey === g.key && c.downloading > 0;
        const pct: number = this.groupPercent(g);
        const hasTotal: number = pct >= 0 ? 1 : 0;
        const bucket: number = tracked ? 0 : (hasTotal ? Math.floor(pct / 5) : 0);
        const expanded: number = this.isExpanded(g.key) ? 1 : 0;
        return `${g.key}|${g.tasks.length}|${c.done},${c.downloading},${c.pending},${c.paused},${c.failed}|${hasTotal}${bucket}|${expanded}`;
    }
    private isExpanded(key: string): boolean {
        return this.expandedGroups.indexOf(key) >= 0;
    }
    private toggleGroup(key: string): void {
        if (this.isExpanded(key)) {
            this.expandedGroups = this.expandedGroups.filter((k: string): boolean => k !== key);
        }
        else {
            this.expandedGroups = [...this.expandedGroups, key];
        }
    }
    private groupTaskIds(g: DownloadGroup): string[] {
        return g.tasks.map((t: DownloadTask): string => t.id);
    }
    private isGroupSelected(g: DownloadGroup): boolean {
        return g.tasks.every((t: DownloadTask): boolean => this.isSelected(t.id));
    }
    /** 选择模式下点组头：整组全选 / 整组取消，子行仍可单独微调 */
    private toggleSelectGroup(g: DownloadGroup): void {
        const ids: string[] = this.groupTaskIds(g);
        if (this.isGroupSelected(g)) {
            this.selectedIds = this.selectedIds.filter((id: string): boolean => ids.indexOf(id) < 0);
            return;
        }
        const merged: string[] = [...this.selectedIds];
        for (let i = 0; i < ids.length; i++) {
            if (merged.indexOf(ids[i]) < 0) {
                merged.push(ids[i]);
            }
        }
        this.selectedIds = merged;
    }
    /**
     * 把一条已下载任务转成可播放曲目。
     *
     * 关键是带上 `localFilePath` —— 播放内核看到它就完全跳过音源解析，直接播沙箱文件
     * （断网也能放）。id 用 musicId 而不是任务 id，这样行上的「正在播放」标记、
     * 以及播放页显示的曲目都和下载条目的音乐身份对得上。
     */
    private toLocalTrack(t: DownloadTask): Track {
        return buildTrack({
            id: t.musicId.length > 0 ? t.musicId : t.id,
            title: t.title,
            artist: t.artist,
            coverUrl: t.coverUrl,
            localFilePath: t.localFilePath
        });
    }
    /** 点击已完成的条目：以「这首打头、其余已下载的跟在后面」组成队列播放 */
    private play(t: DownloadTask): void {
        const done: DownloadTask[] = this.tasks.filter((x: DownloadTask): boolean => x.status === DownloadStatus.COMPLETED && x.localFilePath.length > 0);
        if (done.length === 0) {
            return;
        }
        const list: Track[] = [this.toLocalTrack(t)];
        for (let i = 0; i < done.length; i++) {
            if (done[i].id !== t.id) {
                list.push(this.toLocalTrack(done[i]));
            }
        }
        MusicPlayer.getInstance().playAll(list);
    }
    private deleteFile(t: DownloadTask): void {
        if (t.localFilePath && t.localFilePath.length > 0) {
            try {
                fs.unlinkSync(t.localFilePath);
            }
            catch (e) {
                // 文件可能已不存在，忽略
            }
        }
    }
    private remove(t: DownloadTask): void {
        DownloadManager.getInstance().removeTask(t.id).catch((e: Error): void => {
            console.error(`remove download failed: ${JSON.stringify(e)}`);
        });
        this.deleteFile(t);
        this.toast(`已删除「${t.title}」`, 1200);
    }
    /** 删除前二次确认（整组）：一次删掉合集下的全部分 P 任务与文件 */
    private confirmRemoveGroup(g: DownloadGroup): void {
        this.getUIContext().showAlertDialog({
            title: '删除合集下载',
            message: `确定删除「${g.title}」下的 ${g.tasks.length} 个分 P 任务吗？已下载的音频文件也会一并移除。`,
            primaryButton: {
                value: '取消',
                action: (): void => { }
            },
            secondaryButton: {
                value: '删除',
                fontColor: { "id": 16777250, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                action: (): void => {
                    this.removeGroup(g);
                }
            }
        });
    }
    private removeGroup(g: DownloadGroup): void {
        const ids: string[] = this.groupTaskIds(g);
        // 先删文件：任务快照里有 localFilePath，删完库记录就拿不到了
        for (let i = 0; i < g.tasks.length; i++) {
            this.deleteFile(g.tasks[i]);
        }
        DownloadManager.getInstance().removeTasks(ids).catch((e: Error): void => {
            console.error(`remove downloads failed: ${JSON.stringify(e)}`);
        });
        // 收起该组的展开态，避免残留一个指向空组的记录
        this.expandedGroups = this.expandedGroups.filter((k: string): boolean => k !== g.key);
        this.toast(`已删除「${g.title}」的 ${ids.length} 个任务`, 1200);
    }
    /** 统一 Toast 封装：与设置 / 搜索等页保持同一套回执通道（规范 5.2）。 */
    private toast(message: string, duration: number): void {
        showAppToast(message, duration);
    }
    /** 删除前二次确认：避免误触把已下载的音频一并删掉。 */
    private confirmRemove(t: DownloadTask): void {
        this.getUIContext().showAlertDialog({
            title: '删除下载',
            message: `确定删除「${t.title}」吗？已下载的音频文件也会一并移除。`,
            primaryButton: {
                value: '取消',
                action: (): void => { }
            },
            secondaryButton: {
                value: '删除',
                fontColor: { "id": 16777250, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                action: (): void => {
                    this.remove(t);
                }
            }
        });
    }
    private confirmRemoveSelected(): void {
        const count: number = this.selectedIds.length;
        if (count === 0) {
            return;
        }
        this.getUIContext().showAlertDialog({
            title: '删除下载',
            message: `确定删除选中的 ${count} 个任务吗？已下载的音频文件也会一并移除。`,
            primaryButton: {
                value: '取消',
                action: (): void => { }
            },
            secondaryButton: {
                value: '删除',
                fontColor: { "id": 16777250, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" },
                action: (): void => {
                    this.removeSelected();
                }
            }
        });
    }
    private removeSelected(): void {
        const ids: string[] = this.selectedIds.slice();
        // 先删文件：任务快照里有 localFilePath，删完库记录就拿不到了
        for (let i = 0; i < this.tasks.length; i++) {
            if (ids.indexOf(this.tasks[i].id) >= 0) {
                this.deleteFile(this.tasks[i]);
            }
        }
        DownloadManager.getInstance().removeTasks(ids).catch((e: Error): void => {
            console.error(`remove downloads failed: ${JSON.stringify(e)}`);
        });
        this.selectedIds = [];
        this.selecting = false;
        this.toast(`已删除 ${ids.length} 个任务`, 1200);
    }
    private toggleSelecting(): void {
        this.selecting = !this.selecting;
        this.selectedIds = [];
    }
    private toggleSelect(id: string): void {
        if (this.isSelected(id)) {
            this.selectedIds = this.selectedIds.filter((x: string): boolean => x !== id);
        }
        else {
            this.selectedIds = [...this.selectedIds, id];
        }
    }
    private allSelected(): boolean {
        return this.tasks.length > 0 && this.selectedIds.length >= this.tasks.length;
    }
    private toggleSelectAll(): void {
        if (this.allSelected()) {
            this.selectedIds = [];
            return;
        }
        const all: string[] = [];
        for (let i = 0; i < this.tasks.length; i++) {
            all.push(this.tasks[i].id);
        }
        this.selectedIds = all;
    }
    private hasActive(): boolean {
        return this.tasks.some((t: DownloadTask): boolean => t.status === DownloadStatus.PENDING || t.status === DownloadStatus.DOWNLOADING);
    }
    private canResume(): boolean {
        return this.queuePaused
            || this.tasks.some((t: DownloadTask): boolean => t.status === DownloadStatus.PAUSED);
    }
    private pauseAll(): void {
        DownloadManager.getInstance().pauseAll().catch((e: Error): void => {
            console.error(`pause downloads failed: ${JSON.stringify(e)}`);
        });
    }
    private resumeAll(): void {
        DownloadManager.getInstance().resumeAll().catch((e: Error): void => {
            console.error(`resume downloads failed: ${JSON.stringify(e)}`);
        });
    }
    SelectToggle(parent = null): void {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel(this.selecting ? '完成' : '选择');
            Button.height(44);
            Button.backgroundColor({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Button.fontColor({ "id": 16777236, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Button.margin({ right: 12 });
            Button.onClick((): void => {
                this.toggleSelecting();
            });
        }, Button);
        Button.pop();
    }
    /**
     * 操作行。刻意**放在顶部而不是贴底** —— 底部被悬浮页签栏（高 56 + 安全区）
     * 与迷你播放条占着，贴底的工具条会被完全遮住；顶部这一行不涉及任何避让。
     */
    ControlBar(parent = null): void {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.width('100%');
            Row.alignItems(VerticalAlign.Center);
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.selecting) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.allSelected() ? '取消全选' : '全选');
                        Text.fontSize(13);
                        Text.fontColor({ "id": 16777235, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.height(44);
                        Text.padding({ left: 16, right: 12 });
                        Text.borderRadius(8);
                        ViewStackProcessor.visualState("pressed");
                        Text.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        ViewStackProcessor.visualState("normal");
                        Text.backgroundColor(Color.Transparent);
                        ViewStackProcessor.visualState();
                        Text.onClick((): void => {
                            this.toggleSelectAll();
                        });
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Blank.create();
                    }, Blank);
                    Blank.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.selectedIds.length > 0 ? `删除选中(${this.selectedIds.length})` : '删除选中');
                        Text.fontSize(13);
                        Text.fontColor(this.selectedIds.length > 0 ? { "id": 16777250, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 16777252, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.height(44);
                        Text.padding({ left: 12, right: 16 });
                        Text.borderRadius(8);
                        ViewStackProcessor.visualState("pressed");
                        Text.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        ViewStackProcessor.visualState("normal");
                        Text.backgroundColor(Color.Transparent);
                        ViewStackProcessor.visualState();
                        Text.onClick((): void => {
                            this.confirmRemoveSelected();
                        });
                    }, Text);
                    Text.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('全部开始');
                        Text.fontSize(13);
                        Text.fontColor(this.canResume() ? { "id": 16777235, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 16777252, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.height(44);
                        Text.padding({ left: 16, right: 12 });
                        Text.borderRadius(8);
                        ViewStackProcessor.visualState("pressed");
                        Text.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        ViewStackProcessor.visualState("normal");
                        Text.backgroundColor(Color.Transparent);
                        ViewStackProcessor.visualState();
                        Text.onClick((): void => {
                            if (this.canResume()) {
                                this.resumeAll();
                            }
                        });
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('全部暂停');
                        Text.fontSize(13);
                        Text.fontColor(this.hasActive() ? { "id": 16777235, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 16777252, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.height(44);
                        Text.padding({ left: 12, right: 12 });
                        Text.borderRadius(8);
                        ViewStackProcessor.visualState("pressed");
                        Text.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        ViewStackProcessor.visualState("normal");
                        Text.backgroundColor(Color.Transparent);
                        ViewStackProcessor.visualState();
                        Text.onClick((): void => {
                            if (this.hasActive()) {
                                this.pauseAll();
                            }
                        });
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Blank.create();
                    }, Blank);
                    Blank.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        If.create();
                        if (this.queuePaused) {
                            this.ifElseBranchUpdateFunction(0, () => {
                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                    Text.create('已暂停');
                                    Text.fontSize(13);
                                    Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                    Text.padding({ right: 16 });
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
                });
            }
        }, If);
        If.pop();
        Row.pop();
    }
    /**
     * 单条任务行。
     * @param nested true = 合集展开后的分 P 子行：左侧缩进一级，与组头形成从属关系
     */
    TaskRow(t: DownloadTask, nested: boolean, parent = null): void {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            globalThis.Context.animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut });
            Row.width('100%');
            Row.padding({ left: nested ? 44 : 16, right: 4, top: 10, bottom: 10 });
            Row.scale({ x: this.pressedKey === t.id ? PRESS_SCALE : 1, y: this.pressedKey === t.id ? PRESS_SCALE : 1 });
            globalThis.Context.animation(null);
            Row.onTouch((event: TouchEvent): void => {
                this.setPressed(event.type, t.id);
            });
            Row.onClick((): void => {
                if (this.selecting) {
                    this.toggleSelect(t.id);
                    return;
                }
                // 只有「真的下载完且文件还在」的条目才可播：ERROR / 半截文件点了必然是失败，
                // 不如什么都不做（宁可无反应，也不要弹一个「无法播放」让人困惑）
                if (t.status === DownloadStatus.COMPLETED && t.localFilePath.length > 0) {
                    this.play(t);
                }
            });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 常驻复选框槽位：进出多选的动画位。绝不能用 if(selecting) 条件挂载 ——
            // 节点增删没有过渡；改为槽位 width 0↔44 的布局动画（行内容随之右移/回位），
            // 复选框本体叠 translate 从右侧滑入，clip 保证槽位收拢时内容不外溢。
            Row.create();
            globalThis.Context.animation({ duration: SELECT_TOGGLE_MS, curve: Curve.EaseOut });
            // 常驻复选框槽位：进出多选的动画位。绝不能用 if(selecting) 条件挂载 ——
            // 节点增删没有过渡；改为槽位 width 0↔44 的布局动画（行内容随之右移/回位），
            // 复选框本体叠 translate 从右侧滑入，clip 保证槽位收拢时内容不外溢。
            Row.width(this.selecting ? SELECT_SLOT_VP : 0);
            // 常驻复选框槽位：进出多选的动画位。绝不能用 if(selecting) 条件挂载 ——
            // 节点增删没有过渡；改为槽位 width 0↔44 的布局动画（行内容随之右移/回位），
            // 复选框本体叠 translate 从右侧滑入，clip 保证槽位收拢时内容不外溢。
            Row.height(20);
            // 常驻复选框槽位：进出多选的动画位。绝不能用 if(selecting) 条件挂载 ——
            // 节点增删没有过渡；改为槽位 width 0↔44 的布局动画（行内容随之右移/回位），
            // 复选框本体叠 translate 从右侧滑入，clip 保证槽位收拢时内容不外溢。
            Row.clip(true);
            // 常驻复选框槽位：进出多选的动画位。绝不能用 if(selecting) 条件挂载 ——
            // 节点增删没有过渡；改为槽位 width 0↔44 的布局动画（行内容随之右移/回位），
            // 复选框本体叠 translate 从右侧滑入，clip 保证槽位收拢时内容不外溢。
            Row.justifyContent(FlexAlign.Center);
            globalThis.Context.animation(null);
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.isSelected(t.id) ? '✓' : '');
            globalThis.Context.animation({ duration: SELECT_TOGGLE_MS, curve: Curve.EaseOut });
            Text.width(20);
            Text.height(20);
            Text.borderRadius(10);
            Text.textAlign(TextAlign.Center);
            Text.fontSize(13);
            Text.fontColor(Color.White);
            Text.backgroundColor(this.isSelected(t.id) ? { "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : Color.Transparent);
            Text.border({
                width: 1.5,
                color: this.isSelected(t.id) ? { "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 16777252, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
            });
            Text.translate({ x: this.selecting ? 0 : SELECT_SLOT_VP });
            globalThis.Context.animation(null);
        }, Text);
        Text.pop();
        // 常驻复选框槽位：进出多选的动画位。绝不能用 if(selecting) 条件挂载 ——
        // 节点增删没有过渡；改为槽位 width 0↔44 的布局动画（行内容随之右移/回位），
        // 复选框本体叠 translate 从右侧滑入，clip 保证槽位收拢时内容不外溢。
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Image.create(t.coverUrl && t.coverUrl.length > 0 ? t.coverUrl : '');
            Image.width(48);
            Image.height(48);
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
            Row.create();
            Row.width('100%');
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(t.title);
            Text.fontSize(16);
            Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.maxLines(1);
            Text.textOverflow({ overflow: TextOverflow.Ellipsis });
            Text.layoutWeight(1);
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.isCurrent(t)) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('正在播放');
                        Text.fontSize(11);
                        Text.fontColor({ "id": 16777235, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.margin({ left: 6 });
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
            Text.create(this.statusText(t));
            Text.fontSize(13);
            Text.fontColor(t.status === DownloadStatus.ERROR ? { "id": 16777250, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.maxLines(1);
            Text.textOverflow({ overflow: TextOverflow.Ellipsis });
            Text.margin({ top: 4 });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (t.status === DownloadStatus.DOWNLOADING || t.status === DownloadStatus.PENDING) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        If.create();
                        if (t.totalBytes > 0) {
                            this.ifElseBranchUpdateFunction(0, () => {
                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                    Progress.create({ value: this.percent(t), total: 100, type: ProgressType.Linear });
                                    Progress.width('100%');
                                    Progress.height(3);
                                    Progress.color({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                    Progress.backgroundColor({ "id": 16777241, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                    Progress.margin({ top: 6 });
                                }, Progress);
                            });
                        }
                        else {
                            this.ifElseBranchUpdateFunction(1, () => {
                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                    // 大小未知（服务器没给 Content-Length）：用不确定进度环表达「下载中」，
                                    // 比画一条永远停在 0% 的空进度条诚实
                                    LoadingProgress.create();
                                    // 大小未知（服务器没给 Content-Length）：用不确定进度环表达「下载中」，
                                    // 比画一条永远停在 0% 的空进度条诚实
                                    LoadingProgress.width(18);
                                    // 大小未知（服务器没给 Content-Length）：用不确定进度环表达「下载中」，
                                    // 比画一条永远停在 0% 的空进度条诚实
                                    LoadingProgress.height(18);
                                    // 大小未知（服务器没给 Content-Length）：用不确定进度环表达「下载中」，
                                    // 比画一条永远停在 0% 的空进度条诚实
                                    LoadingProgress.color({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                    // 大小未知（服务器没给 Content-Length）：用不确定进度环表达「下载中」，
                                    // 比画一条永远停在 0% 的空进度条诚实
                                    LoadingProgress.margin({ top: 6 });
                                }, LoadingProgress);
                            });
                        }
                    }, If);
                    If.pop();
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
            if (t.status === DownloadStatus.PAUSED && t.totalBytes > 0) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Progress.create({ value: this.percent(t), total: 100, type: ProgressType.Linear });
                        Progress.width('100%');
                        Progress.height(3);
                        Progress.color({ "id": 16777240, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Progress.backgroundColor({ "id": 16777241, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Progress.margin({ top: 6 });
                    }, Progress);
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (t.status === DownloadStatus.COMPLETED) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('✓');
                        Text.fontSize(18);
                        Text.fontColor({ "id": 16777251, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.margin({ right: 12 });
                    }, Text);
                    Text.pop();
                });
            }
            // 删除按钮：原来是 `Text('🗑')`（emoji，跨设备字形不一致且不可控），
            // 换成系统符号；同时把命中区从图标本身撑到 44×44（原来只有 18×18）。
            // 多选时用 visibility 摘出布局 —— 不用 if(selecting)：属性驱动的显隐
            // 在保留节点上稳定局部刷新，也让槽位动画期间的行结构保持稳定。
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 删除按钮：原来是 `Text('🗑')`（emoji，跨设备字形不一致且不可控），
            // 换成系统符号；同时把命中区从图标本身撑到 44×44（原来只有 18×18）。
            // 多选时用 visibility 摘出布局 —— 不用 if(selecting)：属性驱动的显隐
            // 在保留节点上稳定局部刷新，也让槽位动画期间的行结构保持稳定。
            Row.create();
            // 删除按钮：原来是 `Text('🗑')`（emoji，跨设备字形不一致且不可控），
            // 换成系统符号；同时把命中区从图标本身撑到 44×44（原来只有 18×18）。
            // 多选时用 visibility 摘出布局 —— 不用 if(selecting)：属性驱动的显隐
            // 在保留节点上稳定局部刷新，也让槽位动画期间的行结构保持稳定。
            Row.width(ROW_ACTION_HIT);
            // 删除按钮：原来是 `Text('🗑')`（emoji，跨设备字形不一致且不可控），
            // 换成系统符号；同时把命中区从图标本身撑到 44×44（原来只有 18×18）。
            // 多选时用 visibility 摘出布局 —— 不用 if(selecting)：属性驱动的显隐
            // 在保留节点上稳定局部刷新，也让槽位动画期间的行结构保持稳定。
            Row.height(ROW_ACTION_HIT);
            // 删除按钮：原来是 `Text('🗑')`（emoji，跨设备字形不一致且不可控），
            // 换成系统符号；同时把命中区从图标本身撑到 44×44（原来只有 18×18）。
            // 多选时用 visibility 摘出布局 —— 不用 if(selecting)：属性驱动的显隐
            // 在保留节点上稳定局部刷新，也让槽位动画期间的行结构保持稳定。
            Row.justifyContent(FlexAlign.Center);
            // 删除按钮：原来是 `Text('🗑')`（emoji，跨设备字形不一致且不可控），
            // 换成系统符号；同时把命中区从图标本身撑到 44×44（原来只有 18×18）。
            // 多选时用 visibility 摘出布局 —— 不用 if(selecting)：属性驱动的显隐
            // 在保留节点上稳定局部刷新，也让槽位动画期间的行结构保持稳定。
            Row.margin({ right: 4 });
            // 删除按钮：原来是 `Text('🗑')`（emoji，跨设备字形不一致且不可控），
            // 换成系统符号；同时把命中区从图标本身撑到 44×44（原来只有 18×18）。
            // 多选时用 visibility 摘出布局 —— 不用 if(selecting)：属性驱动的显隐
            // 在保留节点上稳定局部刷新，也让槽位动画期间的行结构保持稳定。
            Row.borderRadius(22);
            ViewStackProcessor.visualState("pressed");
            // 删除按钮：原来是 `Text('🗑')`（emoji，跨设备字形不一致且不可控），
            // 换成系统符号；同时把命中区从图标本身撑到 44×44（原来只有 18×18）。
            // 多选时用 visibility 摘出布局 —— 不用 if(selecting)：属性驱动的显隐
            // 在保留节点上稳定局部刷新，也让槽位动画期间的行结构保持稳定。
            Row.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            ViewStackProcessor.visualState("normal");
            // 删除按钮：原来是 `Text('🗑')`（emoji，跨设备字形不一致且不可控），
            // 换成系统符号；同时把命中区从图标本身撑到 44×44（原来只有 18×18）。
            // 多选时用 visibility 摘出布局 —— 不用 if(selecting)：属性驱动的显隐
            // 在保留节点上稳定局部刷新，也让槽位动画期间的行结构保持稳定。
            Row.backgroundColor(Color.Transparent);
            ViewStackProcessor.visualState();
            // 删除按钮：原来是 `Text('🗑')`（emoji，跨设备字形不一致且不可控），
            // 换成系统符号；同时把命中区从图标本身撑到 44×44（原来只有 18×18）。
            // 多选时用 visibility 摘出布局 —— 不用 if(selecting)：属性驱动的显隐
            // 在保留节点上稳定局部刷新，也让槽位动画期间的行结构保持稳定。
            Row.visibility(this.selecting ? Visibility.None : Visibility.Visible);
            // 删除按钮：原来是 `Text('🗑')`（emoji，跨设备字形不一致且不可控），
            // 换成系统符号；同时把命中区从图标本身撑到 44×44（原来只有 18×18）。
            // 多选时用 visibility 摘出布局 —— 不用 if(selecting)：属性驱动的显隐
            // 在保留节点上稳定局部刷新，也让槽位动画期间的行结构保持稳定。
            Row.onClick((): void => {
                this.confirmRemove(t);
            });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            SymbolGlyph.create({ "id": 125831542, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            SymbolGlyph.fontSize(18);
            SymbolGlyph.fontColor([{ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }]);
        }, SymbolGlyph);
        // 删除按钮：原来是 `Text('🗑')`（emoji，跨设备字形不一致且不可控），
        // 换成系统符号；同时把命中区从图标本身撑到 44×44（原来只有 18×18）。
        // 多选时用 visibility 摘出布局 —— 不用 if(selecting)：属性驱动的显隐
        // 在保留节点上稳定局部刷新，也让槽位动画期间的行结构保持稳定。
        Row.pop();
        Row.pop();
    }
    /**
     * 合集组头行：整组一个条目（封面 + 合集标题 + 聚合状态/进度），
     * 点击展开/收起分 P 子行；选择模式下点击 = 整组全选/取消。
     */
    GroupHeader(g: DownloadGroup, parent = null): void {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            globalThis.Context.animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut });
            Row.width('100%');
            Row.padding({ left: 16, right: 4, top: 10, bottom: 10 });
            Row.scale({ x: this.pressedKey === g.key ? PRESS_SCALE : 1, y: this.pressedKey === g.key ? PRESS_SCALE : 1 });
            globalThis.Context.animation(null);
            Row.onTouch((event: TouchEvent): void => {
                this.setPressed(event.type, g.key);
            });
            Row.onClick((): void => {
                if (this.selecting) {
                    this.toggleSelectGroup(g);
                    return;
                }
                this.toggleGroup(g.key);
            });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 常驻复选框槽位（与 TaskRow 同款动画：槽位展开 + 复选框右滑入）
            Row.create();
            globalThis.Context.animation({ duration: SELECT_TOGGLE_MS, curve: Curve.EaseOut });
            // 常驻复选框槽位（与 TaskRow 同款动画：槽位展开 + 复选框右滑入）
            Row.width(this.selecting ? SELECT_SLOT_VP : 0);
            // 常驻复选框槽位（与 TaskRow 同款动画：槽位展开 + 复选框右滑入）
            Row.height(20);
            // 常驻复选框槽位（与 TaskRow 同款动画：槽位展开 + 复选框右滑入）
            Row.clip(true);
            // 常驻复选框槽位（与 TaskRow 同款动画：槽位展开 + 复选框右滑入）
            Row.justifyContent(FlexAlign.Center);
            globalThis.Context.animation(null);
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.isGroupSelected(g) ? '✓' : '');
            globalThis.Context.animation({ duration: SELECT_TOGGLE_MS, curve: Curve.EaseOut });
            Text.width(20);
            Text.height(20);
            Text.borderRadius(10);
            Text.textAlign(TextAlign.Center);
            Text.fontSize(13);
            Text.fontColor(Color.White);
            Text.backgroundColor(this.isGroupSelected(g) ? { "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : Color.Transparent);
            Text.border({
                width: 1.5,
                color: this.isGroupSelected(g) ? { "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" } : { "id": 16777252, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }
            });
            Text.translate({ x: this.selecting ? 0 : SELECT_SLOT_VP });
            globalThis.Context.animation(null);
        }, Text);
        Text.pop();
        // 常驻复选框槽位（与 TaskRow 同款动画：槽位展开 + 复选框右滑入）
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Image.create(g.coverUrl && g.coverUrl.length > 0 ? g.coverUrl : '');
            Image.width(48);
            Image.height(48);
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
            Text.create(g.title);
            Text.fontSize(16);
            Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.maxLines(1);
            Text.textOverflow({ overflow: TextOverflow.Ellipsis });
            Text.width('100%');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.groupStatusText(g));
            Text.fontSize(13);
            Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.maxLines(1);
            Text.textOverflow({ overflow: TextOverflow.Ellipsis });
            Text.margin({ top: 4 });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.groupHasActive(g)) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        If.create();
                        if (this.groupPercent(g) >= 0) {
                            this.ifElseBranchUpdateFunction(0, () => {
                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                    Progress.create({ value: this.groupPercent(g), total: 100, type: ProgressType.Linear });
                                    Progress.width('100%');
                                    Progress.height(3);
                                    Progress.color({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                    Progress.backgroundColor({ "id": 16777241, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                    Progress.margin({ top: 6 });
                                }, Progress);
                            });
                        }
                        else {
                            this.ifElseBranchUpdateFunction(1, () => {
                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                    // 总大小未知（分块传输）：用不确定进度表达「在动」，不画停在 0% 的假进度
                                    LoadingProgress.create();
                                    // 总大小未知（分块传输）：用不确定进度表达「在动」，不画停在 0% 的假进度
                                    LoadingProgress.width(18);
                                    // 总大小未知（分块传输）：用不确定进度表达「在动」，不画停在 0% 的假进度
                                    LoadingProgress.height(18);
                                    // 总大小未知（分块传输）：用不确定进度表达「在动」，不画停在 0% 的假进度
                                    LoadingProgress.color({ "id": 16777234, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                                    // 总大小未知（分块传输）：用不确定进度表达「在动」，不画停在 0% 的假进度
                                    LoadingProgress.margin({ top: 6 });
                                }, LoadingProgress);
                            });
                        }
                    }, If);
                    If.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 整组删除：与子行的单条删除同一套确认流程，只是范围是全部分 P；
            // 多选时 visibility 摘出布局（同 TaskRow 的处理）
            Row.create();
            // 整组删除：与子行的单条删除同一套确认流程，只是范围是全部分 P；
            // 多选时 visibility 摘出布局（同 TaskRow 的处理）
            Row.width(ROW_ACTION_HIT);
            // 整组删除：与子行的单条删除同一套确认流程，只是范围是全部分 P；
            // 多选时 visibility 摘出布局（同 TaskRow 的处理）
            Row.height(ROW_ACTION_HIT);
            // 整组删除：与子行的单条删除同一套确认流程，只是范围是全部分 P；
            // 多选时 visibility 摘出布局（同 TaskRow 的处理）
            Row.justifyContent(FlexAlign.Center);
            // 整组删除：与子行的单条删除同一套确认流程，只是范围是全部分 P；
            // 多选时 visibility 摘出布局（同 TaskRow 的处理）
            Row.margin({ right: 4 });
            // 整组删除：与子行的单条删除同一套确认流程，只是范围是全部分 P；
            // 多选时 visibility 摘出布局（同 TaskRow 的处理）
            Row.borderRadius(22);
            ViewStackProcessor.visualState("pressed");
            // 整组删除：与子行的单条删除同一套确认流程，只是范围是全部分 P；
            // 多选时 visibility 摘出布局（同 TaskRow 的处理）
            Row.backgroundColor({ "id": 16777239, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            ViewStackProcessor.visualState("normal");
            // 整组删除：与子行的单条删除同一套确认流程，只是范围是全部分 P；
            // 多选时 visibility 摘出布局（同 TaskRow 的处理）
            Row.backgroundColor(Color.Transparent);
            ViewStackProcessor.visualState();
            // 整组删除：与子行的单条删除同一套确认流程，只是范围是全部分 P；
            // 多选时 visibility 摘出布局（同 TaskRow 的处理）
            Row.visibility(this.selecting ? Visibility.None : Visibility.Visible);
            // 整组删除：与子行的单条删除同一套确认流程，只是范围是全部分 P；
            // 多选时 visibility 摘出布局（同 TaskRow 的处理）
            Row.onClick((): void => {
                this.confirmRemoveGroup(g);
            });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            SymbolGlyph.create({ "id": 125831542, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            SymbolGlyph.fontSize(18);
            SymbolGlyph.fontColor([{ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }]);
        }, SymbolGlyph);
        // 整组删除：与子行的单条删除同一套确认流程，只是范围是全部分 P；
        // 多选时 visibility 摘出布局（同 TaskRow 的处理）
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 展开指示：复用 arrow_right，展开时旋转 90° 朝下（不引入未验证的新符号名）
            SymbolGlyph.create({ "id": 125832680, "type": 40000, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            // 展开指示：复用 arrow_right，展开时旋转 90° 朝下（不引入未验证的新符号名）
            SymbolGlyph.fontSize(14);
            // 展开指示：复用 arrow_right，展开时旋转 90° 朝下（不引入未验证的新符号名）
            SymbolGlyph.fontColor([{ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" }]);
            // 展开指示：复用 arrow_right，展开时旋转 90° 朝下（不引入未验证的新符号名）
            SymbolGlyph.rotate({ angle: this.isExpanded(g.key) ? 90 : 0 });
            // 展开指示：复用 arrow_right，展开时旋转 90° 朝下（不引入未验证的新符号名）
            SymbolGlyph.margin({ right: 14 });
        }, SymbolGlyph);
        Row.pop();
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.width('100%');
            Column.height('100%');
            Column.backgroundColor({ "id": 16777232, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
            // 根 Column 默认水平居中对齐，包一层挂上限即可。
            Column.create();
            // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
            // 根 Column 默认水平居中对齐，包一层挂上限即可。
            Column.width('100%');
            // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
            // 根 Column 默认水平居中对齐，包一层挂上限即可。
            Column.height('100%');
            // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
            // 根 Column 默认水平居中对齐，包一层挂上限即可。
            Column.constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.width('100%');
            Row.alignItems(VerticalAlign.Center);
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('下载管理');
            Text.fontSize(20);
            Text.fontWeight(FontWeight.Bold);
            Text.fontColor({ "id": 16777253, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
            Text.layoutWeight(1);
            Text.padding({ left: 16, top: 14, bottom: 6 });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.tasks.length > 0) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.SelectToggle.bind(this)();
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
            if (this.tasks.length > 0) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.ControlBar.bind(this)();
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
            if (this.tasks.length === 0) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create();
                        Column.layoutWeight(1);
                        Column.justifyContent(FlexAlign.Center);
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('还没有下载任务');
                        Text.fontColor({ "id": 16777254, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.fontSize(16);
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('在搜索页点击“⋯”→“下载”即可保存歌曲');
                        Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.fontSize(13);
                        Text.margin({ top: 8 });
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('多 P 合集会作为一个整体下载，点开合集可查看每个分 P 的进度');
                        Text.fontColor({ "id": 16777255, "type": 10001, params: [], "bundleName": "com.chai.bilimusic", "moduleName": "entry" });
                        Text.fontSize(13);
                        Text.margin({ top: 4 });
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
                            const g = _item;
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
                                        Column.create();
                                    }, Column);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        If.create();
                                        if (g.tasks.length > 1) {
                                            this.ifElseBranchUpdateFunction(0, () => {
                                                // 多 P 合集：整组显示为一个条目，点开才铺出各分 P 子行
                                                this.GroupHeader.bind(this)(g);
                                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                                    If.create();
                                                    if (this.isExpanded(g.key)) {
                                                        this.ifElseBranchUpdateFunction(0, () => {
                                                            this.observeComponentCreation2((elmtId, isInitialRender) => {
                                                                ForEach.create();
                                                                const forEachItemGenFunction = _item => {
                                                                    const t = _item;
                                                                    this.TaskRow.bind(this)(t, true);
                                                                };
                                                                this.forEachUpdateFunction(elmtId, g.tasks, forEachItemGenFunction, (t: DownloadTask): string => this.rowKey(t), false, false);
                                                            }, ForEach);
                                                            ForEach.pop();
                                                        });
                                                    }
                                                    else {
                                                        this.ifElseBranchUpdateFunction(1, () => {
                                                        });
                                                    }
                                                }, If);
                                                If.pop();
                                            });
                                        }
                                        else {
                                            this.ifElseBranchUpdateFunction(1, () => {
                                                // 单曲 / 单 P：与旧版完全一致的普通行
                                                this.TaskRow.bind(this)(g.tasks[0], false);
                                            });
                                        }
                                    }, If);
                                    If.pop();
                                    Column.pop();
                                    ListItem.pop();
                                };
                                this.observeComponentCreation2(itemCreation2, ListItem);
                                ListItem.pop();
                            }
                        };
                        this.forEachUpdateFunction(elmtId, this.buildGroups(), forEachItemGenFunction, (g: DownloadGroup): string => this.groupRowKey(g), false, false);
                    }, ForEach);
                    ForEach.pop();
                    List.pop();
                });
            }
        }, If);
        If.pop();
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
        // 根 Column 默认水平居中对齐，包一层挂上限即可。
        Column.pop();
        Column.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
