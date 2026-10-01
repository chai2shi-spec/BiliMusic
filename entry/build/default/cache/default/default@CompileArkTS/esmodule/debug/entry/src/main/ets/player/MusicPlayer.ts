import media from "@ohos:multimedia.media";
import avSession from "@ohos:multimedia.avsession";
import type { BusinessError } from "@ohos:base";
import audio from "@ohos:multimedia.audio";
import image from "@ohos:multimedia.image";
import http from "@ohos:net.http";
import fs from "@ohos:file.fs";
import type common from "@ohos:app.ability.common";
import { extractAudioFromVideo, expandVideoParts } from "@normalized:N&&&entry/src/main/ets/api/BilibiliApi&";
import { LibraryStore } from "@normalized:N&&&entry/src/main/ets/service/LibraryStore&";
import { BackgroundPlayback } from "@normalized:N&&&entry/src/main/ets/service/BackgroundPlayback&";
import { AppPreferences } from "@normalized:N&&&entry/src/main/ets/preferences/AppPreferences&";
import { isUnmeteredNetwork } from "@normalized:N&&&entry/src/main/ets/utils/NetworkUtil&";
import { BILI_REFERER } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
import { fitByByteBudget, PREF_VALUE_BUDGET_BYTES, RepeatMode, slimTrack } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
import type { Track, TrackSource } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
import { STORE_CURRENT_TRACK, STORE_IS_PLAYING, STORE_PROGRESS, STORE_DURATION, STORE_QUEUE, STORE_REPEAT_MODE, STORE_SHUFFLE, STORE_LOADING_AUDIO, STORE_VOLUME, STORE_MUTED, STORE_TOAST_MSG, STORE_TOAST_HOLD_MS, STORE_TOAST_SEQ, STORE_SLEEP_TIMER_END } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
/**
 * 进度向 UI 推送的最小间隔。
 * AVPlayer 的 timeUpdate 每 100ms 回调一次，直接透传会让播放页 10 次/秒重渲染，
 * 拖动手势被拖帧；按此间隔分桶后降到 2 次/秒，视觉上进度条依旧连续。
 */
const PROGRESS_PUSH_INTERVAL_MS: number = 500;
/**
 * 「合集展开」延后执行的毫秒数。
 *
 * 点歌瞬间会并发发出三个请求：音源解析的 view + playurl，以及合集展开自己的**又一次 view**。
 * 三者撞在一起容易把 HTTP 连接池挤满，首包被拒就表现成「点了歌却提示无法播放」。
 * 展开只是「顺手把多分 P 铺进队列」的附带功能，晚 1.2s 完全无感，
 * 但换来了音源解析独占连接的窗口 —— 点歌成功率优先。
 */
const EXPAND_PARTS_DELAY_MS: number = 1200;
/**
 * 「预取下一首音源」的延迟毫秒数。
 * 当前曲目刚起播时播放器正在缓冲首包，此刻预取会与音频流抢带宽；
 * 等 2 秒让声音先稳定，再悄悄解析下一首的直链（只拉两个小 JSON），
 * 切歌 / 自动续播时缓存命中，跳过 view + playurl 两次串行请求，近乎秒开。
 */
const PREFETCH_DELAY_MS: number = 2000;
/**
 * 累计听歌时长的落盘阈值（秒）。
 * timeUpdate 每 100ms 累计一次实时增量，攒满这个量才写一次 Preferences，
 * 把写盘频率从 10 次/秒压到约 20 分钟一次量级的读取展示完全够用。
 */
const LISTEN_FLUSH_SECONDS: number = 30;
/**
 * 两次 timeUpdate 之间的最大可信间隔（毫秒）。
 * 正常播放时约 100ms；超过这个值说明中间发生过挂起/恢复（如进程被冻结），
 * 这段空白时间不能计入听歌时长，直接丢弃，宁可少计不可虚计。
 */
const LISTEN_TICK_MAX_GAP_MS: number = 2000;
/**
 * 播放会话快照：用于「重新打开 App 时保留上次播放记录」。
 * 持久化到 PREF_PLAYER_STATE（Preferences JSON），冷启动后由 restoreState() 读回。
 */
interface PlayerStateSnapshot {
    currentTrack: Track | null;
    queue: Track[];
    currentIndex: number;
    progress: number;
    duration: number;
    repeatMode: RepeatMode;
    isShuffled: boolean;
    isPlaying: boolean;
    savedAt: number;
}
/**
 * 安全地把 MediaSource 挂到 AVPlayer 上并兜住异步失败。
 *
 * ⚠️ 不能直接 `player.setMediaSource(src).catch(...)`：SDK 类型虽声明返回 Promise<void>，
 * 但部分系统版本运行时返回 undefined，直接 .catch 会抛
 * 「TypeError: Cannot read property catch of undefined」。
 * 这个异常会顺着 switchSource → loadAndPlay 的 catch 一路冒上去，
 * 把「音源其实已经挂上、歌在正常播」误判成加载失败 —— 副作用之一就是
 * recordRecent 被整段跳过，表现为「歌照常播放，最近播放里永远一条记录都没有」。
 * 用 Promise.resolve 归一化：真 Promise 原样透传（reject 照样进 onFail），
 * undefined 则得到一个已 resolved 的 Promise，不再炸调用链。
 * 运行时返回 undefined 时的挂载失败由既有的 player 'error' 事件兜底。
 */
function attachMediaSourceSafely(player: media.AVPlayer, source: media.MediaSource, onFail: (e: BusinessError) => void): void {
    const task: Promise<void> = Promise.resolve(player.setMediaSource(source));
    task.catch((e: BusinessError): void => {
        onFail(e);
    });
}
export class MusicPlayer {
    private static instance: MusicPlayer | null = null;
    private context: common.Context | null = null;
    private avPlayer: media.AVPlayer | null = null;
    private session: avSession.AVSession | null = null;
    /**
     * 播放本地下载文件时打开的文件句柄（非本地播放时为 null）。
     *
     * 文档明确要求「fd 由调用方负责关闭」，所以换源 / 回收播放器时必须一起关掉，
     * 否则每播一首下载歌曲就漏一个 fd。关闭时机很讲究：**必须在旧播放器 release 之后**
     * （见 ensurePlayer），提前关会让仍在解码的实例读到无效 fd。
     */
    private localFile: fs.File | null = null;
    private queue: Track[] = [];
    private currentIndex: number = -1;
    private shuffledQueue: Track[] = [];
    private repeatMode: RepeatMode = RepeatMode.NONE;
    private isShuffled: boolean = false;
    private volume: number = 80;
    private isMuted: boolean = false;
    private shouldAutoplay: boolean = false;
    private retryCount: number = 0;
    private playerState: string = 'idle';
    private loadToken: number = 0;
    /** 上一次向 AVSession 上报播放状态的时间戳，用于 timeUpdate 节流 */
    private lastSessionSyncAt: number = 0;
    /** timeUpdate 的 500ms 分桶游标，同桶内不重复推送 STORE_PROGRESS */
    private lastProgressBucket: number = -1;
    /** 记录已播放时长（秒），单曲循环 / 顺序播放结束时用来判断是否需要复位 */
    private lastDuration: number = 0;
    /** 已上报到 AVSession 的曲目时长（ms）：durationUpdate 到来时据此去重，避免重复补报 */
    private lastPublishedDurationMs: number = 0;
    /** 上一次上报元数据的曲目 id：换歌时复位 lastPublishedDurationMs（不同曲目时长相同也必须重报） */
    private lastMetadataAssetId: string = '';
    /** 封面 PixelMap 缓存：补报时长 / 信息合并重报时复用，不重复下载封面 */
    private coverCache: image.PixelMap | undefined;
    /** 封面缓存对应的曲目 id（缓存失效判定） */
    private coverCacheAssetId: string = '';
    /** 已展开过的多 P 合集 bvid。避免切歌 / 重播同一合集时反复请求 view 接口。 */
    private expandedBvids: Set<string> = new Set<string>();
    /** 续播定位：loadAndPlay 在 avPlayer 进入 prepared 后跳转到该秒数（>0 表示需要续播） */
    private pendingSeekTo: number = -1;
    /** 续播后是否自动开始播放（配合 pendingSeekTo 使用，避免 prepared 阶段 seek 被丢弃） */
    private pendingAutoPlayAfterSeek: boolean = false;
    /** 冷启动从快照恢复后，用户首次点击播放时定位到的秒数（-1 表示无需定位） */
    private pendingResumePosition: number = -1;
    /** 进度落盘粗节流游标：timeUpdate 每 5s 才持久化一次进度，避免高频写 Preferences */
    private lastStatePersistAt: number = 0;
    /** 累计听歌时长的会话内增量（秒），攒满 LISTEN_FLUSH_SECONDS 落盘一次 */
    private listenAccumSeconds: number = 0;
    /** 上一次 timeUpdate 的时间戳；-1 表示尚未开始计时（暂停/切歌后复位） */
    private lastListenTickAt: number = -1;
    /** seek 进行中标志：seek 真正生效（seekDone）前，抑制 timeUpdate 把滑块拽回旧位置 */
    private seeking: boolean = false;
    /** seek 开始时间戳，用于「长时间收不到 seekDone」的兜底解除抑制 */
    private seekStartedAt: number = 0;
    /** 音频被系统强制打断前是否正在播放，供打断结束（RESUME）时决定自动续播 */
    private wasPlayingBeforeInterrupt: boolean = false;
    /**
     * 最近一次**成功加载出音源**的曲目，用于音源解析失败时把界面回滚回来。
     *
     * 背景：`playTrack` 是乐观更新——先把 STORE_CURRENT_TRACK 写成目标曲目再解析音源。
     * 一旦解析失败（视频已删、cid 错配、区域限制……），界面就停在「这首播不出来的歌」上，
     * 而音频其实还是上一首，用户看到的就是「点了没换歌，除了音乐其他信息都加载了」。
     * 有这份快照才能在失败时把界面拉回真实正在播的那首。
     */
    private lastPlayableTrack: Track | null = null;
    /**
     * 「正在准备新音源」标志：从开始解析音源（view + playurl）、重建播放器，
     * 到新音源挂载完成为止。
     *
     * 为什么必须抑制这期间的进度回传：解析要发两次串行网络请求（数百 ms 到数秒），
     * 这段时间**旧音源仍在出声**，它的 timeUpdate 会按**上一首**的位置回调。
     * 若照常写入 STORE_PROGRESS，刚点的新歌进度条就会乱跳，而 5s 一次的落盘
     * 还会把上一首的位置存成新歌的续播点。
     * 参考实现（BiliMusic-main/service/PlayerController.ets）同样在 isPreparing 时直接 return。
     *
     * 同时 play() / pause() 在此期间只登记播放意图，不直接操作播放器
     * ——此刻 AVPlayer 正在被释放 / 重建，指针可能是空的。
     */
    private isPreparing: boolean = false;
    /**
     * 待上报的会话元数据（延迟到真正出声才上报）。
     *
     * updateSessionMetadata 内部要下载封面并解码成 PixelMap，它与 AVPlayer 的
     * 音频首包缓冲同时发出会抢带宽，拖慢「点歌到出声」。挂到 'playing' 状态
     * 再发：声音先起、封面随后，锁屏信息晚一两秒无感。
     */
    private pendingMetadataTrack: Track | null = null;
    /** 预取下一首音源的定时器句柄（-1 = 无待执行的预取） */
    private prefetchTimer: number = -1;
    /** 本会话已预取过音源的曲目 id，防止对同一首反复解析 */
    private prefetchedIds: Set<string> = new Set<string>();
    static getInstance(): MusicPlayer {
        if (!MusicPlayer.instance) {
            MusicPlayer.instance = new MusicPlayer();
        }
        return MusicPlayer.instance;
    }
    async init(context: common.Context): Promise<void> {
        this.context = context;
        // AVPlayer 不再预先创建，改为**每次换源时「摘监听 → release 旧的 → createAVPlayer 新的」**
        // （见 ensurePlayer / switchSource）。
        // 复用同一个实例做 reset() 的问题是：reset 会让旧音源上报一次 error，而 error 回调
        // 又去重试换源，于是 `reset → error → reload → reset` 正反馈，重试次数瞬间耗尽、
        // 播放器卡在 error/idle —— 表现就是「切哪首歌都没声音」。
        // 参考工程（BiliMusic-main/service/AudioPlayer.ets）正是每次 setSource 都换新实例。
        if (!this.session && context) {
            try {
                this.session = await avSession.createAVSession(context, 'BiliMusic', 'audio');
            }
            catch (e) {
                console.error(`create AVSession failed: ${JSON.stringify(e)}`);
            }
            if (this.session) {
                this.registerSessionEvents(this.session);
                // 后台长时任务的前置条件：AVSession 必须处于激活态。
                // 未激活时系统会以 SYSTEM_SUSPEND_AUDIO_PLAYBACK_NOT_USE_AVSESSION 挂起应用，
                // 表现就是「退到后台音乐就停、应用被回收」。
                try {
                    await this.session.activate();
                    const agent: object | null = await BackgroundPlayback.getInstance().getLaunchAgent(context);
                    if (agent) {
                        await this.session.setLaunchAbility(agent);
                    }
                }
                catch (e) {
                    console.error(`activate AVSession failed: ${JSON.stringify(e)}`);
                }
            }
        }
        // 恢复音量 / 静音态。播放器实例在首次换源时才创建，
        // 这些配置由 ensurePlayer → applyPlayerConfig 统一应用到新实例上
        //（漏了这步会「切歌后音量变回 100%」）。
        this.volume = (AppStorage.get(STORE_VOLUME) as number) ?? 80;
        this.isMuted = (AppStorage.get(STORE_MUTED) as boolean) ?? false;
        this.restoreState();
    }
    /**
     * 把当前播放会话落盘到 PREF_PLAYER_STATE。
     * 调用点：切歌 / 播放 / 暂停 / 跳转 / 队列或模式变化（见各对外方法），
     * 以及 timeUpdate 的 5s 粗节流。写入是 fire-and-forget，失败仅记日志。
     */
    private savePlayerStateNow(): void {
        const cur: Track | null = (AppStorage.get(STORE_CURRENT_TRACK) as Track) ?? null;
        const snapshot: PlayerStateSnapshot = {
            currentTrack: cur ? slimTrack(cur) : null,
            queue: this.fitQueueForStorage(),
            currentIndex: this.currentIndex,
            progress: (AppStorage.get(STORE_PROGRESS) as number) ?? 0,
            duration: (AppStorage.get(STORE_DURATION) as number) ?? 0,
            repeatMode: this.repeatMode,
            isShuffled: this.isShuffled,
            isPlaying: (AppStorage.get(STORE_IS_PLAYING) as boolean) ?? false,
            savedAt: Date.now()
        };
        AppPreferences.savePlayerState<PlayerStateSnapshot>(snapshot).catch((e: Error): void => {
            console.error(`savePlayerState failed: ${e.message}`);
        });
    }
    /**
     * 裁剪落盘的队列快照。
     *
     * Preferences 对单个 string value 有 8192 字节上限，而队列里每首曲目都带 audioUrl
     * （带签名的长直链），50 首序列化后能到 30KB → put() 抛错 → 整份快照写不进去，
     * 表现就是「重新打开 App 没有恢复上次播放记录」。这里统一瘦身 + 按字节预算从尾部截断：
     * 宁可少存几首，也要保证这份快照一定写得进去。
     */
    private fitQueueForStorage(): Track[] {
        const slim: Track[] = this.queue.map((t: Track): Track => slimTrack(t));
        // 留 1KB 给 currentTrack 与其余标量字段
        return fitByByteBudget<Track>(slim, PREF_VALUE_BUDGET_BYTES - 1024);
    }
    /**
     * 冷启动恢复上次播放记录。
     * 仅恢复「记录」（曲目 / 队列 / 进度 / 模式），并挂起为暂停态 + 记一个续播定位，
     * 等用户点播放再真正加载音源并 seek 到原位置——避免无交互冷启动就自动出声。
     * 没有快照或快照无曲目时直接返回，不污染首启体验。
     */
    private restoreState(): void {
        const snapshot: PlayerStateSnapshot | null = AppPreferences.getPlayerState<PlayerStateSnapshot>();
        if (!snapshot || !snapshot.currentTrack) {
            return;
        }
        const track: Track = snapshot.currentTrack;
        this.queue = Array.isArray(snapshot.queue) ? snapshot.queue.slice() : [];
        this.shuffledQueue = this.shuffle(this.queue);
        this.currentIndex = typeof snapshot.currentIndex === 'number' ? snapshot.currentIndex : -1;
        this.repeatMode = snapshot.repeatMode ?? RepeatMode.NONE;
        this.isShuffled = snapshot.isShuffled ?? false;
        this.setStore(STORE_CURRENT_TRACK, track);
        this.syncQueue();
        this.setStore(STORE_REPEAT_MODE, this.repeatMode);
        this.setStore(STORE_SHUFFLE, this.isShuffled);
        const pos: number = snapshot.progress ?? 0;
        this.setStore(STORE_PROGRESS, pos);
        this.setStore(STORE_DURATION, snapshot.duration ?? 0);
        // 暂停态恢复：不自动出声，等待用户点击继续
        this.setStore(STORE_IS_PLAYING, false);
        this.pendingResumePosition = pos > 0 ? pos : -1;
    }
    private setStore(key: string, value: Object | null): void {
        if (value === null) {
            AppStorage.delete(key);
        }
        else {
            AppStorage.setOrCreate(key, value);
        }
    }
    private getQueue(): Track[] {
        return (AppStorage.get(STORE_QUEUE) as Track[]) ?? [];
    }
    private syncQueue(): void {
        this.setStore(STORE_QUEUE, this.queue);
    }
    private displayQueue(): Track[] {
        return this.isShuffled ? this.shuffledQueue : this.queue;
    }
    /**
     * 播放状态与后台长时任务保持同步：播放中申请 AUDIO_PLAYBACK，暂停/结束时释放。
     * 不做这步，退到后台后进程会被系统挂起，音乐停止、应用被回收。
     */
    private syncBackgroundTask(playing: boolean): void {
        if (!this.context) {
            return;
        }
        const bg: BackgroundPlayback = BackgroundPlayback.getInstance();
        if (playing) {
            bg.start(this.context).catch((e: Error): void => {
                console.error(`start continuousTask failed: ${JSON.stringify(e)}`);
            });
        }
        else {
            bg.stop(this.context).catch((e: Error): void => {
                console.error(`stop continuousTask failed: ${JSON.stringify(e)}`);
            });
        }
    }
    private registerAvPlayerEvents(player: media.AVPlayer): void {
        player.on('stateChange', (state: string): void => {
            this.playerState = state;
            if (state === 'initialized') {
                // prepare() 返回 Promise，必须接住：拒绝时若不处理，未处理的 rejection
                // 会让状态机静默停在 initialized，表现为「点了歌一直转圈、永远不出声」。
                player.prepare().catch((e: BusinessError): void => {
                    console.error(`prepare failed: ${e.code} ${e.message}`);
                    this.isPreparing = false;
                    this.setStore(STORE_LOADING_AUDIO, false);
                });
            }
            else if (state === 'prepared') {
                if (this.pendingSeekTo >= 0) {
                    // 续播 / 切歌后定位：必须在 prepared 之后再 seek，否则 seek 会被丢弃
                    const target: number = this.pendingSeekTo;
                    this.pendingSeekTo = -1;
                    const doPlay: boolean = this.pendingAutoPlayAfterSeek;
                    this.pendingAutoPlayAfterSeek = false;
                    try {
                        player.seek(target * 1000);
                    }
                    catch (e) {
                        console.error(`seek on prepared failed: ${JSON.stringify(e)}`);
                    }
                    if (doPlay) {
                        player.play().catch((e: BusinessError): void => {
                            console.error(`play after seek failed: ${e.code} ${e.message}`);
                        });
                    }
                }
                else if (this.shouldAutoplay) {
                    player.play().catch((e: BusinessError): void => {
                        console.error(`autoplay failed: ${e.code} ${e.message}`);
                    });
                }
            }
            else if (state === 'playing') {
                this.setStore(STORE_IS_PLAYING, true);
                // 真正出声了：把延迟的会话元数据（含封面）现在才发，不再与首包缓冲抢带宽
                this.flushPendingMetadata();
                this.updateSessionState();
                this.syncBackgroundTask(true);
            }
            else if (state === 'paused') {
                this.setStore(STORE_IS_PLAYING, false);
                this.updateSessionState();
                this.syncBackgroundTask(false);
                // 停止听歌计时：暂停后到下次恢复之间的空白不计入（由 lastListenTickAt=-1 实现）
                this.lastListenTickAt = -1;
            }
            else if (state === 'completed') {
                this.lastListenTickAt = -1;
                this.handleEnded();
            }
        });
        player.on('timeUpdate', (time: number): void => {
            // ⚠️ 正在准备新音源（解析 + 重建播放器）期间，出声的仍是**上一首**，
            // 它的 timeUpdate 会按旧位置回调。此时若写进度，新歌的进度条会乱跳，
            // 5s 一次的落盘还会把上一首的位置存成新歌的续播点。直接 return 最干净。
            if (this.isPreparing) {
                return;
            }
            // 累计听歌时长：播放中每次 timeUpdate（约 100ms）累加实际流逝的增量
            this.accumulateListenTime();
            // ⚠️ 官方文档：timeUpdate **默认每 100ms 上报一次**（不是 1s）。
            // 若每次原样写进 AppStorage，播放页每秒会重渲染 10 次
            // （旋转唱片动画 + Swiper + 歌词 List 全在被重建），
            // 拖进度条这种跟手手势会被拖帧，表现为「拖不动 / 拖了又跳回去」。
            // 因此按 500ms 分桶，同一桶内不推送（进度文字按秒显示，视觉无损）。
            // 另：seek 是异步的，seek 真正生效（seekDone）前，timeUpdate 仍会按旧位置回调，
            // 若此时把 STORE_PROGRESS 写回去，滑块就会被拽回旧位置——这就是「拖了又跳回去」。
            // 故 seeking 期间抑制进度推送，仅保留会话/落盘同步。
            if (this.seeking) {
                // 兜底：seek 超过 2.5s 仍未收到 seekDone，强制解除抑制，避免进度条卡死
                if (Date.now() - this.seekStartedAt > 2500) {
                    this.seeking = false;
                    this.lastProgressBucket = -1;
                }
            }
            const bucket: number = Math.floor(time / PROGRESS_PUSH_INTERVAL_MS);
            if (!this.seeking && bucket !== this.lastProgressBucket) {
                this.lastProgressBucket = bucket;
                this.setStore(STORE_PROGRESS, time / 1000);
            }
            // 会话位置按 1s 节流上报：既让播控中心进度准确，也避免系统因
            // 「AVSession 长期不更新」判定播放未运行而挂起长时任务。
            const now: number = Date.now();
            if (now - this.lastSessionSyncAt >= 1000) {
                this.lastSessionSyncAt = now;
                this.updateSessionState();
            }
            // 进度落盘粗节流（每 5s）：既保证重启后能恢复到大致位置，又不高频写 Preferences
            if (now - this.lastStatePersistAt >= 5000) {
                this.lastStatePersistAt = now;
                this.savePlayerStateNow();
            }
        });
        player.on('durationUpdate', (duration: number): void => {
            this.lastDuration = duration / 1000;
            this.setStore(STORE_DURATION, this.lastDuration);
            // 列表侧没有时长的曲目，首次 setAVMetadata 不带 duration（横幅画不出进度条 / 时间）。
            // 真实时长解析出来后整体补报一次元数据；已报过相同时长则跳过。
            this.republishSessionDuration();
        });
        player.on('error', (err: object): void => {
            console.error(`AVPlayer error: ${JSON.stringify(err)}`);
            // 换源时旧实例已 detach + release，它的 error 不会再走到这里，
            // 所以这里收到的必定是**当前音源**的真实错误 —— 不再需要「静默窗口」去猜。
            this.isPreparing = false;
            this.setStore(STORE_LOADING_AUDIO, false);
            this.setStore(STORE_IS_PLAYING, false);
            // 播放已中断，及时释放长时任务，避免通知栏残留一条无声音的任务
            this.syncBackgroundTask(false);
            if (this.retryCount < 3 && this.currentTrackSnapshot()) {
                this.retryCount++;
                this.reloadCurrentSource().catch((e: Error): void => {
                    console.error(`reloadCurrentSource failed: ${e.message}`);
                });
            }
            else {
                // 重试耗尽：必须给用户一个明确交代。否则界面只是悄悄停在暂停态，
                // 用户完全不知道发生了什么（表现为「点了没反应」）。
                this.notifyHint('音频加载失败，请稍后重试');
            }
        });
        // seek 真正生效后，解除进度抑制，让 timeUpdate 重新驱动滑块到目标位置
        player.on('seekDone', (seekDoneTime: number): void => {
            this.seeking = false;
            this.lastProgressBucket = -1;
        });
        player.on('audioInterrupt', (event: audio.InterruptEvent): void => {
            this.onAudioInterrupt(event);
        });
    }
    private currentTrackSnapshot(): Track | null {
        return (AppStorage.get(STORE_CURRENT_TRACK) as Track) ?? null;
    }
    private registerSessionEvents(session: avSession.AVSession): void {
        try {
            session.on('play', (): void => {
                this.play();
            });
            session.on('pause', (): void => {
                this.pause();
            });
            session.on('seek', (time: number): void => {
                this.seek(time / 1000);
            });
            session.on('playNext', (): void => {
                this.next();
            });
            session.on('playPrevious', (): void => {
                this.prev();
            });
        }
        catch (e) {
            console.error(`register session events failed: ${JSON.stringify(e)}`);
        }
    }
    private async updateSessionMetadata(track: Track): Promise<void> {
        if (!this.session) {
            return;
        }
        // 换歌时复位「已报时长」：两首歌时长恰好相同时，去重逻辑不能把新歌的补报吞掉
        if (track.id !== this.lastMetadataAssetId) {
            this.lastMetadataAssetId = track.id;
            this.lastPublishedDurationMs = 0;
        }
        // 系统媒体胶囊（灵动胶囊）需要 PixelMap 形式的封面，网络 URL 无法直接识别，
        // 故把封面解码成 PixelMap 再写入 mediaImage；任何环节失败都降级为无封面，不阻断上报。
        // 同一曲目的重复上报（时长补报 / 信息合并后的重报）直接复用缓存的 PixelMap。
        let cover: image.PixelMap | undefined;
        if (track.coverUrl && track.coverUrl.length > 0) {
            if (this.coverCacheAssetId === track.id && this.coverCache !== undefined) {
                cover = this.coverCache;
            }
            else {
                try {
                    const loaded: image.PixelMap | null = await this.loadCoverPixelMap(track.coverUrl);
                    if (loaded !== null) {
                        this.coverCache = loaded;
                        this.coverCacheAssetId = track.id;
                        cover = loaded;
                    }
                }
                catch (e) {
                    console.error(`load cover pixelmap failed: ${JSON.stringify(e)}`);
                }
            }
        }
        // 播控横幅的进度条与时间 = position / duration，缺 duration 就两个都不渲染。
        // duration 单位毫秒；列表侧拿不到时长（duration=0）时回退到播放器已解析出的真实时长。
        const durationSec: number = track.duration > 0 ? track.duration : this.lastDuration;
        const durationMs: number = Math.round(durationSec * 1000);
        if (durationMs > 0) {
            this.lastPublishedDurationMs = durationMs;
        }
        try {
            this.session.setAVMetadata({
                assetId: track.id,
                title: track.title || '未命名歌曲',
                artist: track.artist || 'BiliMusic',
                album: 'BiliMusic',
                duration: durationMs,
                mediaImage: cover
            }).catch((e: BusinessError): void => {
                console.error(`setAVMetadata failed: ${e.code} ${e.message}`);
            });
        }
        catch (e) {
            console.error(`setAVMetadata failed: ${JSON.stringify(e)}`);
        }
    }
    /**
     * 把封面网络地址解码成 PixelMap，供系统媒体胶囊（AVSession mediaImage）显示专辑封面。
     * 网络 URL 不能直接当 ImageSource 的 URI，故走 http 取到字节再 createImageSource。
     * 失败返回 null（封面非必需，绝不能让元数据上报中断）。
     */
    private async loadCoverPixelMap(url: string): Promise<image.PixelMap | null> {
        const httpReq = http.createHttp();
        try {
            const resp: http.HttpResponse = await httpReq.request(url, {
                method: http.RequestMethod.GET,
                header: { Referer: BILI_REFERER },
                connectTimeout: 10000,
                readTimeout: 10000,
                expectDataType: http.HttpDataType.ARRAY_BUFFER
            });
            if (resp.responseCode !== 200 || !resp.result) {
                return null;
            }
            const data: ArrayBuffer = resp.result as ArrayBuffer;
            const src: image.ImageSource = image.createImageSource(data);
            return await src.createPixelMap();
        }
        catch (e) {
            console.error(`loadCoverPixelMap failed: ${JSON.stringify(e)}`);
            return null;
        }
        finally {
            httpReq.destroy();
        }
    }
    /**
     * 真实时长到位后补报一次元数据。
     *
     * 播控横幅要拿 AVMetadata.duration（毫秒）才肯画进度条 / 显示总时间；
     * 「音乐中心」这类列表数据没有时长，首报时只能缺省，等 durationUpdate
     * 事件把真实时长送来后再整体重报一次（封面走缓存，不重复下载）。
     */
    private republishSessionDuration(): void {
        if (!this.session) {
            return;
        }
        // 元数据还挂着待上报（尚未出声）：此刻补报只会把「延迟上报」变回
        // 「边缓冲边下封面」，与优化目标相悖。等 flushPendingMetadata 一并带出——
        // 它会读取此刻已解析好的 lastDuration，时长不会丢。
        if (this.pendingMetadataTrack !== null) {
            return;
        }
        const durationMs: number = Math.round(this.lastDuration * 1000);
        // 时长无效或已上报过相同值：跳过（durationUpdate 对同一音源可能触发多次）
        if (durationMs <= 0 || durationMs === this.lastPublishedDurationMs) {
            return;
        }
        const track: Track | null = this.currentTrackSnapshot();
        if (track === null) {
            return;
        }
        this.updateSessionMetadata(track).catch((e: Error): void => {
            console.error(`republish session duration failed: ${e.message}`);
        });
    }
    /**
     * 把延迟到「真正出声」才上报的会话元数据发出去。
     * 见 pendingMetadataTrack 字段注释：封面下载让路给音频首包，出声更快。
     */
    private flushPendingMetadata(): void {
        const track: Track | null = this.pendingMetadataTrack;
        if (track === null) {
            return;
        }
        this.pendingMetadataTrack = null;
        this.updateSessionMetadata(track).catch((e: Error): void => {
            console.error(`updateSessionMetadata failed: ${e.message}`);
        });
    }
    /**
     * 音源已挂上后，安排一次「下一首直链」的预取。
     * 每次成功加载都会重新调度（旧的定时器被清掉），预取的永远是**当前曲目的下一首**。
     */
    private scheduleNextSourcePrefetch(): void {
        if (this.prefetchTimer !== -1) {
            clearTimeout(this.prefetchTimer);
        }
        this.prefetchTimer = setTimeout((): void => {
            this.prefetchTimer = -1;
            this.prefetchNextSource();
        }, PREFETCH_DELAY_MS);
    }
    /**
     * 预取下一首的音源解析结果（view + playurl 两个小 JSON，不拉音频流）。
     * 解析结果落在 BilibiliApi 的缓存里；真正切到这首时 extractAudioFromVideo
     * 直接命中缓存，省掉两次串行请求 —— 「播放全部」自动续播从此近乎秒开。
     * 失败只留日志：预取是锦上添花，绝不能影响正在进行的播放。
     */
    private prefetchNextSource(): void {
        try {
            // 「仅 WiFi 播放」开着且当前是蜂窝：下一首根本不会被允许播，预取没有意义
            if (AppPreferences.getSettings().wifiOnlyPlay && !isUnmeteredNetwork()) {
                return;
            }
            const dq: Track[] = this.displayQueue();
            if (dq.length === 0 || this.currentIndex < 0) {
                return;
            }
            if (this.repeatMode === RepeatMode.ONE) {
                // 单曲循环没有「下一首」，当前音源早已解析过
                return;
            }
            let idx: number = this.currentIndex + 1;
            if (idx >= dq.length) {
                if (this.repeatMode === RepeatMode.NONE) {
                    // 顺序播放到末尾自然停止，没有下一首
                    return;
                }
                // 列表循环 / 随机：回到开头
                idx = 0;
            }
            const track: Track = dq[idx];
            const localPath: string = track.localFilePath ?? '';
            if (localPath.length > 0) {
                // 本地文件不需要解析音源
                return;
            }
            if (this.prefetchedIds.has(track.id)) {
                return;
            }
            this.prefetchedIds.add(track.id);
            extractAudioFromVideo(track.bvid || track.id, {
                aid: track.aid,
                cid: track.cid
            }).catch((e: Error): void => {
                console.error(`prefetch next source failed: ${e.message}`);
            });
        }
        catch (e) {
            console.error(`prefetch next source threw: ${JSON.stringify(e)}`);
        }
    }
    private updateSessionState(): void {
        if (!this.session) {
            return;
        }
        const playing: boolean = (AppStorage.get(STORE_IS_PLAYING) as boolean) ?? false;
        const state: avSession.PlaybackState = playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
        const position: avSession.PlaybackPosition = {
            // elapsedTime 的单位是毫秒，而 STORE_PROGRESS 存的是秒，必须 ×1000：
            // 早前直接传秒，横幅上的已播时间几乎不动、进度条不走（配合缺失的 duration
            // 表现为「时间和进度条都不显示」）。
            elapsedTime: Math.round(((AppStorage.get(STORE_PROGRESS) as number) ?? 0) * 1000),
            updateTime: Date.now()
        };
        try {
            this.session.setAVPlaybackState({
                state: state,
                position: position
            }).catch((e: BusinessError): void => {
                console.error(`setAVPlaybackState failed: ${e.code} ${e.message}`);
            });
        }
        catch (e) {
            console.error(`setAVPlaybackState failed: ${JSON.stringify(e)}`);
        }
    }
    /**
     * 音频焦点中断处理（被来电 / 闹钟 / 其他应用抢占焦点）。
     * - INTERRUPT_FORCE + PAUSE：系统已把音频暂停，必须同步自身状态到「已暂停」，
     *   并记录「打断前在播放」，待 RESUME 时自动续播；
     * - INTERRUPT_FORCE + STOP：永久失去焦点，同步暂停但不自动恢复（需用户手动触发）；
     * - INTERRUPT_FORCE + DUCK：临时压低音量，无需暂停；
     * - INTERRUPT_SHARE + RESUME：其他应用释放焦点，若打断前在播放则自动 play() 续播。
     * 不自动恢复的情形：打断前本就处于暂停（用户主动暂停），或 STOP（永久失去焦点）。
     */
    private onAudioInterrupt(event: audio.InterruptEvent): void {
        const wasPlaying: boolean = (AppStorage.get(STORE_IS_PLAYING) as boolean) ?? false;
        if (event.forceType === audio.InterruptForceType.INTERRUPT_FORCE) {
            switch (event.hintType) {
                case audio.InterruptHint.INTERRUPT_HINT_PAUSE:
                    // 系统已暂停音频：同步状态，记住「被打断前在播放」以便恢复
                    this.wasPlayingBeforeInterrupt = wasPlaying;
                    this.setStore(STORE_IS_PLAYING, false);
                    this.updateSessionState();
                    this.syncBackgroundTask(false);
                    break;
                case audio.InterruptHint.INTERRUPT_HINT_STOP:
                    // 永久失去焦点：同步暂停，但不自动恢复
                    this.wasPlayingBeforeInterrupt = false;
                    this.setStore(STORE_IS_PLAYING, false);
                    this.updateSessionState();
                    this.syncBackgroundTask(false);
                    break;
                case audio.InterruptHint.INTERRUPT_HINT_DUCK:
                default:
                    // 临时压低音量即可，自身状态不变
                    break;
            }
        }
        else if (event.forceType === audio.InterruptForceType.INTERRUPT_SHARE) {
            switch (event.hintType) {
                case audio.InterruptHint.INTERRUPT_HINT_RESUME:
                    if (this.wasPlayingBeforeInterrupt) {
                        this.wasPlayingBeforeInterrupt = false;
                        this.play();
                    }
                    break;
                case audio.InterruptHint.INTERRUPT_HINT_UNDUCK:
                default:
                    break;
            }
        }
    }
    /**
     * 把「音源解析结果」合并回曲目对象。播放页显示的就是这个合并结果。
     *
     * 合并方向是这里最容易写反、且写反了最难查的一点（症状是「播放页的信息跟
     * 正在放的这首歌对不上 / 干脆是空的」）：
     *
     * - **标题 / 歌手 / 封面：列表侧优先，音源侧兜底。**
     *   列表里的元数据才是「这条目自己的信息」——音乐中心的封面是专辑图、标题是曲名；
     *   而音源侧的 title / pic 来自**承载这段音频的那个视频**。对音乐中心这类
     *   「音频元数据 + 视频承载」的条目，两者根本不是一回事（实测：曲名
     *   《Chopin: Études Op.10 No.12》、歌手「赵成珍」，承载视频却是个
     *   「高一放学回家外录钢琴」的投稿）。无条件采用音源侧，播放页就会变成
     *   另一个视频的封面与标题 —— 列表里看到的和播放页里看到的对不上。
     *   只有列表侧为空串时才拿音源侧补全（例如某些源缺标题）。
     * - **时长：音源侧优先。** `view` 给的是该视频（分 P）的真实时长，seek 依赖它；
     *   列表侧不少源（音乐中心）压根没有时长字段。
     * - **aid / cid：音源侧优先。** 这一对正是本次取流用的编号，天然自洽；
     *   音乐中心的 aid/cid 属于音频体系，与视频分 P 不是同一套（拿它取流会 -404），
     *   写成取流那一对，下次解析失败走 avid+cid 兜底时也不会二次踩坑。
     */
    private mergeTrack(track: Track, source: TrackSource): Track {
        const cover: string = track.coverUrl.length > 0 ? track.coverUrl : source.coverUrl;
        if (track.coverUrl.length > 0 && source.coverUrl.length > 0 && track.coverUrl !== source.coverUrl) {
            // 两侧封面不同是常态（专辑图 vs 视频截图），这里留一行证据：
            // 线上再出现「播放页的图与列表不一致」时，看这行即可确认最终采用了哪一张。
            console.info(`cover=list ${track.coverUrl.slice(0, 80)} | source=${source.coverUrl.slice(0, 80)}`);
        }
        return {
            id: track.id,
            title: track.title.length > 0 ? track.title : source.title,
            artist: track.artist.length > 0 ? track.artist : source.artist,
            coverUrl: cover,
            duration: source.duration > 0 ? source.duration : track.duration,
            videoUrl: track.videoUrl,
            bvid: track.bvid.length > 0 ? track.bvid : source.bvid,
            aid: source.aid > 0 ? String(source.aid) : track.aid,
            cid: source.cid > 0 ? String(source.cid) : track.cid,
            playCount: track.playCount,
            isLiked: track.isLiked,
            likedAt: track.likedAt,
            audioUrl: source.audioUrl,
            audioQuality: source.audioQuality,
            audioMimeType: source.audioMimeType
        };
    }
    private async reloadCurrentSource(): Promise<void> {
        const track: Track | null = this.currentTrackSnapshot();
        if (!track) {
            return;
        }
        // ⚠️ 这里**绝不能**写成 `++this.loadToken` 去抢占 token。
        // 抢占会把正在进行的 `loadAndPlay`（用户刚点的那首歌）直接作废：
        // 它 await 回来时 `token !== this.loadToken`，会静默 return，连音源都不切
        // —— 表现就是「点了新歌，信息都换了，但没声音 / 还是上一首」。
        // reload 的职责只是给**当前曲目**重试一次音源，跟随当前 token 即可。
        const token: number = this.loadToken;
        this.isPreparing = true;
        try {
            // refresh=true：走到重试说明播放器报了 error，最常见的原因就是缓存里的
            // 直链已过期（CDN 签名失效）。必须绕过缓存重新解析，否则会拿同一条过期
            // 链接重试三次、次次失败。新结果会回写缓存。
            const source = await extractAudioFromVideo(track.bvid || track.id, {
                aid: track.aid,
                cid: track.cid
            }, 0, true);
            if (token !== this.loadToken) {
                return;
            }
            const updated: Track = this.mergeTrack(track, source);
            this.setStore(STORE_CURRENT_TRACK, updated);
            this.lastPlayableTrack = updated;
            // 换源统一走「重建播放器」：见 switchSource 注释
            await this.switchSource(updated.audioUrl);
            this.isPreparing = false;
        }
        catch (e) {
            // 失败必须解除准备态，否则 timeUpdate 会被永久抑制、进度条卡死
            this.isPreparing = false;
            console.error(`reload audio failed: ${JSON.stringify(e)}`);
            this.setStore(STORE_LOADING_AUDIO, false);
        }
    }
    /**
     * 换源：**摘掉旧播放器的监听 → release 掉 → 新建一个干净的 AVPlayer**，再挂载新音源。
     *
     * 为什么不用「复用同一个实例 + reset()」：
     * reset() 会让**旧音源**上未完成的请求报一次 error，而 error 回调又会去重试换源，
     * 于是形成 `reset → error → reload → reset` 的正反馈 —— 重试次数瞬间耗尽、
     * 播放器卡在 error/idle，表现就是「切哪首歌都没声音」。
     * 之前是靠一个「静默窗口」去猜哪条 error 是换源副作用，属于用补丁绕架构问题。
     *
     * 参考工程（BiliMusic-main/service/AudioPlayer.ets）的做法更彻底：每次 setSource
     * 前把旧实例的监听 off 掉并 release()，再 createAVPlayer()。这样
     * ①旧实例的错误根本传不出来，②新实例天然处于 idle（setMediaSource 永远合法），
     * 整个「哪条错误属于谁」的歧义就不存在了。这里照做。
     */
    private async switchSource(url: string): Promise<boolean> {
        if (url.length === 0) {
            // 直链为空时 setMediaSource 不会报错但也不会有任何声音，
            // 用户只看到「点了歌、封面歌名都换了，就是没声」。这里明确失败并留日志。
            console.error('switchSource with empty url');
            this.isPreparing = false;
            this.setStore(STORE_LOADING_AUDIO, false);
            this.setStore(STORE_IS_PLAYING, false);
            this.notifyHint('音频地址为空，请稍后重试');
            return false;
        }
        const player: media.AVPlayer | null = await this.ensurePlayer();
        if (!player) {
            // 播放器都建不出来：必须解除准备态，否则 play() 会因 isPreparing 永真而
            // 变成死键（点一下毫无反应），timeUpdate 也会被永久抑制、进度条卡死。
            this.isPreparing = false;
            this.setStore(STORE_LOADING_AUDIO, false);
            this.setStore(STORE_IS_PLAYING, false);
            this.notifyHint('播放器初始化失败，请重开应用后再试');
            return false;
        }
        if (player !== this.avPlayer) {
            // 已被并发的新一次换源取代（它已把这个实例 release 掉），本次结果作废
            return false;
        }
        let mediaSource: media.MediaSource;
        try {
            // @SuppressWarnings syscap
            mediaSource = media.createMediaSourceWithUrl(url, {
                Referer: BILI_REFERER,
                'User-Agent': 'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile'
            });
        }
        catch (e) {
            console.error(`createMediaSourceWithUrl failed: ${JSON.stringify(e)}`);
            this.isPreparing = false;
            this.setStore(STORE_LOADING_AUDIO, false);
            this.setStore(STORE_IS_PLAYING, false);
            return false;
        }
        attachMediaSourceSafely(player, mediaSource, (e: BusinessError): void => {
            console.error(`setMediaSource failed: ${e.code} ${e.message}`);
            this.isPreparing = false;
            this.setStore(STORE_LOADING_AUDIO, false);
            this.setStore(STORE_IS_PLAYING, false);
        });
        // true = 音源已经交给播放器（音频这一侧已经有着落），
        // 调用方据此区分「真的没挂上音源」与「挂上之后收尾环节才出的岔子」。
        return true;
    }
    /**
     * 换源（本地文件版）：把沙箱里下载好的 .m4a 挂到播放器上。
     *
     * 用 `media.createMediaSourceWithFd` 而不是拼一个 `file://` URL：
     * 本地文件没有「可解析的 URL」这个语义，fd 才是官方入口。文档要求 fd 由调用方关闭，
     * 所以句柄存进 `localFile`，由下一次换源（ensurePlayer 开头）统一关掉。
     *
     * 返回值含义与 `switchSource` 严格对齐：true = 音源已交给播放器。
     *
     * ⚠️ 这是「已下载的文件点不动」这条反馈的正解：此前下载页只有删除按钮，
     * 压根没有播放入口；即便有，播放内核也只认 http 直链。
     */
    private async switchSourceLocal(path: string): Promise<boolean> {
        const player: media.AVPlayer | null = await this.ensurePlayer();
        if (!player) {
            this.failLoad('播放器初始化失败，请重开应用后再试');
            return false;
        }
        if (player !== this.avPlayer) {
            // 已被并发的新一次换源取代（它已把这个实例 release 掉），本次结果作废
            return false;
        }
        let size: number = 0;
        try {
            size = fs.statSync(path).size;
        }
        catch (e) {
            console.error(`stat local audio failed: ${JSON.stringify(e)}`);
        }
        if (!(size > 0)) {
            this.failLoad('本地文件不存在，请重新下载');
            return false;
        }
        let file: fs.File | null = null;
        try {
            file = fs.openSync(path, fs.OpenMode.READ_ONLY);
        }
        catch (e) {
            console.error(`open local audio failed: ${JSON.stringify(e)}`);
        }
        if (!file) {
            this.failLoad('本地文件无法打开，请重新下载');
            return false;
        }
        let source: media.MediaSource | undefined = undefined;
        try {
            source = media.createMediaSourceWithFd({ fd: file.fd, offset: 0, length: size });
        }
        catch (e) {
            console.error(`createMediaSourceWithFd failed: ${JSON.stringify(e)}`);
        }
        if (!source) {
            // 建 MediaSource 失败：句柄没交出去，自己关掉，别漏 fd
            try {
                fs.closeSync(file.fd);
            }
            catch (e) {
                console.error(`close unused local fd failed: ${JSON.stringify(e)}`);
            }
            this.failLoad('本地文件无法播放，请重新下载');
            return false;
        }
        // ensurePlayer 已经关掉了上一个本地句柄，这里接手新句柄
        this.localFile = file;
        attachMediaSourceSafely(player, source, (e: BusinessError): void => {
            console.error(`setMediaSource(local) failed: ${e.code} ${e.message}`);
            this.isPreparing = false;
            this.setStore(STORE_LOADING_AUDIO, false);
            this.setStore(STORE_IS_PLAYING, false);
        });
        return true;
    }
    /**
     * 播放本地（已下载）文件。
     *
     * 结构与在线链路刻意保持一致 —— 同样的 token 校验、同样的 `pendingSeekTo` 续播机制、
     * 同样的 `recordRecent` 时点，唯一区别是「不发任何网络请求」。
     * 这样 play / pause / seek / 自动下一首这些既有逻辑一行都不用动。
     */
    private async loadLocalFile(track: Track, path: string, autoplay: boolean, startAt: number, token: number): Promise<void> {
        try {
            this.setStore(STORE_CURRENT_TRACK, track);
            // 与在线链路一致：元数据延迟到出声再上报，避免封面下载抢占缓冲带宽
            this.pendingMetadataTrack = track;
            if (!autoplay) {
                this.flushPendingMetadata();
            }
            if (startAt > 0) {
                this.pendingSeekTo = startAt;
                this.pendingAutoPlayAfterSeek = autoplay;
                this.shouldAutoplay = false;
            }
            else {
                this.pendingSeekTo = -1;
                this.pendingAutoPlayAfterSeek = false;
                this.shouldAutoplay = autoplay;
            }
            const attached: boolean = await this.switchSourceLocal(path);
            if (token !== this.loadToken) {
                return;
            }
            if (!attached) {
                this.recoverAfterLoadFailure(track);
                return;
            }
            this.recordRecent(track);
            this.isPreparing = false;
            this.setStore(STORE_LOADING_AUDIO, false);
            this.lastPlayableTrack = track;
            if (autoplay && startAt <= 0) {
                this.setStore(STORE_IS_PLAYING, true);
            }
            try {
                this.savePlayerStateNow();
            }
            catch (e) {
                console.error(`persist local playback side effects failed: ${JSON.stringify(e)}`);
            }
            // 本地链路同样预取下一首（下一首可能是在线曲目）
            this.scheduleNextSourcePrefetch();
        }
        catch (e) {
            this.isPreparing = false;
            if (token !== this.loadToken) {
                return;
            }
            console.error(`load local audio failed: ${JSON.stringify(e)}`);
            this.setStore(STORE_LOADING_AUDIO, false);
            this.setStore(STORE_IS_PLAYING, false);
            this.recoverAfterLoadFailure(track);
        }
    }
    private failLoad(message: string): void {
        this.isPreparing = false;
        this.setStore(STORE_LOADING_AUDIO, false);
        this.setStore(STORE_IS_PLAYING, false);
        this.notifyHint(message);
    }
    /** 关闭本地播放文件句柄。重复调用安全（换源 / 回收播放器都会走到这里） */
    private closeLocalFile(): void {
        const file: fs.File | null = this.localFile;
        this.localFile = null;
        if (!file) {
            return;
        }
        try {
            fs.closeSync(file.fd);
        }
        catch (e) {
            console.error(`close local audio failed: ${JSON.stringify(e)}`);
        }
    }
    /**
     * 新建一个干净的 AVPlayer。
     * 先把旧实例的监听**全部摘掉**再 release —— 摘监听是关键，否则旧实例在释放过程中
     * 上报的 error 会被当成「新音源加载失败」，弹出一个莫名其妙的提示。
     * 新实例是全新默认值，必须重新应用音量等配置（见 applyPlayerConfig）。
     */
    private async ensurePlayer(): Promise<media.AVPlayer | null> {
        const old: media.AVPlayer | null = this.detachAndClearPlayer();
        if (old) {
            try {
                await old.release();
            }
            catch (e) {
                console.error(`release old avPlayer failed: ${JSON.stringify(e)}`);
            }
        }
        // 旧播放器已释放，它读着的本地文件句柄这时才能安全关闭（顺序不能提前）
        this.closeLocalFile();
        try {
            // @SuppressWarnings syscap
            const player: media.AVPlayer = await media.createAVPlayer();
            this.avPlayer = player;
            this.playerState = 'idle';
            this.applyPlayerConfig(player);
            this.registerAvPlayerEvents(player);
            return player;
        }
        catch (e) {
            console.error(`create avPlayer failed: ${JSON.stringify(e)}`);
            return null;
        }
    }
    /**
     * 新播放器统一配置：音量 + 音频流类型。
     * 不补这步会出现「切一首歌，音量自己变回 100%」——createAVPlayer 返回的是全新默认值。
     */
    private applyPlayerConfig(player: media.AVPlayer): void {
        try {
            player.setVolume(this.isMuted ? 0 : this.volume / 100);
        }
        catch (e) {
            console.error(`setVolume on new player failed: ${JSON.stringify(e)}`);
        }
        try {
            player.audioRendererInfo = {
                content: audio.ContentType.CONTENT_TYPE_MUSIC,
                usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
                rendererFlags: 0
            };
        }
        catch (e) {
            // 配置音频流类型失败不影响播放，系统会退回默认值
            console.error(`set audioRendererInfo failed: ${JSON.stringify(e)}`);
        }
    }
    /** 摘掉某个播放器实例上的全部监听（换源前必做，避免旧实例的错误污染新音源） */
    private detachPlayerEvents(player: media.AVPlayer): void {
        try {
            player.off('stateChange');
            player.off('timeUpdate');
            player.off('durationUpdate');
            player.off('error');
            player.off('seekDone');
            player.off('audioInterrupt');
        }
        catch (e) {
            console.error(`detach player events failed: ${JSON.stringify(e)}`);
        }
    }
    /** 摘监听 + 把实例字段置空，返回被摘下来的旧实例（调用方决定同步/异步 release） */
    private detachAndClearPlayer(): media.AVPlayer | null {
        const old: media.AVPlayer | null = this.avPlayer;
        this.avPlayer = null;
        this.playerState = 'idle';
        if (old) {
            this.detachPlayerEvents(old);
        }
        return old;
    }
    /** 彻底回收播放器实例；下一次播放会在 switchSource 里重新建一个干净的 */
    private dropPlayer(): void {
        const old: media.AVPlayer | null = this.detachAndClearPlayer();
        if (old) {
            try {
                old.release();
            }
            catch (e) {
                console.error(`release avPlayer failed: ${JSON.stringify(e)}`);
            }
        }
        // 走到这里说明用户明确不播了（清空队列），本地句柄一并回收，别漏 fd
        this.closeLocalFile();
    }
    private async loadAndPlay(track: Track, autoplay: boolean, startAt: number = 0): Promise<void> {
        const token: number = ++this.loadToken;
        this.shouldAutoplay = autoplay;
        this.retryCount = 0;
        // 换曲：时长与进度分桶游标必须一起复位，否则新曲会沿用上一首的总时长
        // （拖动进度条按旧时长换算，seek 到的位置完全不对）
        this.lastDuration = 0;
        this.lastProgressBucket = -1;
        this.setStore(STORE_LOADING_AUDIO, true);
        this.setStore(STORE_PROGRESS, 0);
        this.setStore(STORE_DURATION, 0);
        // 进入「准备中」：解析音源 + 重建播放器期间，旧音源还在出声，
        // 它的 timeUpdate 必须被忽略（理由见 isPreparing 字段注释）
        this.isPreparing = true;
        // 上一轮加载若失败，可能残留一个待上报的元数据；先清掉，下面按新曲目重新登记
        this.pendingMetadataTrack = null;
        // 已下载的曲目走本地链路：直接播沙箱文件，不发任何网络请求。
        // 这条判断放在「准备中」之后，是因为 loadLocalFile 同样要维护 isPreparing
        // 语义（它也会重建播放器，期间旧音源仍在出声）。
        const localPath: string = track.localFilePath ?? '';
        if (localPath.length > 0) {
            await this.loadLocalFile(track, localPath, autoplay, startAt, token);
            return;
        }
        // 「音源是否已经交给播放器」。只有它为 false 时，下面的 catch 才认为
        // 这次点歌真的失败了；否则说明音频这一侧已经有着落，catch 到的异常
        // 只是收尾环节的岔子，绝不能据此回滚界面并弹「加载失败」。
        let attached: boolean = false;
        try {
            const source = await extractAudioFromVideo(track.bvid || track.id, {
                aid: track.aid,
                cid: track.cid
            });
            if (token !== this.loadToken) {
                return;
            }
            const updated: Track = this.mergeTrack(track, source);
            this.setStore(STORE_CURRENT_TRACK, updated);
            // 会话元数据延迟到真正出声（'playing'）再上报：它内部的封面下载
            // 会与音频首包缓冲抢带宽，推迟一两秒无感，但出声更快。
            this.pendingMetadataTrack = updated;
            if (!autoplay) {
                this.flushPendingMetadata();
            }
            if (startAt > 0) {
                // 续播：必须在 prepared 之后再 seek，否则 seek 会被丢弃，这里先登记待定位
                this.pendingSeekTo = startAt;
                this.pendingAutoPlayAfterSeek = autoplay;
                this.shouldAutoplay = false;
            }
            else {
                this.pendingSeekTo = -1;
                this.pendingAutoPlayAfterSeek = false;
                this.shouldAutoplay = autoplay;
            }
            attached = await this.switchSource(updated.audioUrl);
            if (!attached) {
                // 换源自身就失败了（空直链 / 播放器建不出来 / createMediaSourceWithUrl 抛错）。
                // 它已经把状态和提示处理过了，这里补一步失败收尾：把界面回滚到真实在播的那首，
                // 避免出现「封面歌名换了、声音还是上一首」的不一致。
                this.recoverAfterLoadFailure(track);
                return;
            }
            if (token !== this.loadToken) {
                return;
            }
            // ⚠️ 记「最近播放」必须紧贴在这里 —— 音源已挂上、且本次加载没有被新的一次取代，
            // 从这一刻起这一首就算「听过了」。放到收尾的最后一步会出事：收尾里任何一次
            // setStore / 会话落盘抛异常，都会被整段跳过，症状正是
            // 「歌照常播放，但最近播放里永远没有一项记录」。
            this.recordRecent(updated);
            this.isPreparing = false;
            if (autoplay && startAt <= 0) {
                this.setStore(STORE_IS_PLAYING, true);
            }
            this.setStore(STORE_LOADING_AUDIO, false);
            this.lastPlayableTrack = updated;
            // 会话落盘只是附带副作用，单独兜底：写不进去也绝不能反过来影响播放
            try {
                this.savePlayerStateNow();
            }
            catch (e) {
                console.error(`persist playback side effects failed: ${JSON.stringify(e)}`);
            }
            // 出声已有着落：悄悄预取下一首的直链，切歌 / 自动续播时直接命中缓存
            this.scheduleNextSourcePrefetch();
        }
        catch (e) {
            this.isPreparing = false;
            if (token !== this.loadToken) {
                return;
            }
            // ⚠️ 不要用 JSON.stringify(e)：Error 实例的 message / stack 都是不可枚举属性，
            // 序列化出来只有 {}，等于把真正的错误信息丢掉（这就是这类问题之前查不动的原因）。
            const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
            console.error(`load audio failed (attached=${attached}): ${detail}`);
            this.setStore(STORE_LOADING_AUDIO, false);
            this.setStore(STORE_IS_PLAYING, false);
            if (!attached) {
                this.recoverAfterLoadFailure(track);
            }
            else {
                // 音源已经交给播放器了（这一首其实已经在出声），异常只发生在收尾环节，
                // 对播放没有任何影响。此时**既不回滚界面、也不弹「加载失败」**
                // —— 否则就会出现「明明在播，却每次点歌都提示加载失败」的误报。
                // 但要**补记一次最近播放**：异常可能发生在 894 行之前，
                // 那条记录就丢了（症状：歌能播，最近播放却一直是空的）。重复记录无害——
                // addRecentTrack 按 id 去重后置顶，天然幂等。
                this.recordRecent(track);
                console.error(`post-attach failure ignored: ${track.id}`);
            }
        }
    }
    /**
     * 记一条「最近播放」。
     *
     * 双重保险：① 调用点必须在音源挂上之后立刻执行（见 loadAndPlay 内注释）；
     * ② 自身吞掉全部异常 —— 记历史失败绝不能影响播放，也不能让调用方以为加载失败。
     */
    private recordRecent(track: Track): void {
        try {
            LibraryStore.addRecentTrack(track);
        }
        catch (e) {
            const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
            console.error(`record recent track failed: ${detail}`);
        }
    }
    /**
     * 音源解析失败后的收尾：把界面回滚到真实在播的那首，并明确告知用户。
     *
     * 为什么必须有这一步：`playTrack` 会**先**把 STORE_CURRENT_TRACK 写成目标曲目再解析音源
     * （为了让界面立刻响应，不等网络）。解析失败时若不回滚，界面就会停在
     * 「封面歌名都换了、声音还是上一首」的不一致状态 —— 用户完全看不出发生了什么。
     * 回滚前要确认界面确实还停在失败的那首：用户可能已经手动切到别的歌，那就不该动。
     */
    private recoverAfterLoadFailure(failed: Track): void {
        // 加载失败：挂着的待上报元数据属于失败的那首，留着只会在下次 'playing'
        // 时把错误曲目的封面 / 标题报给系统，必须清掉。
        this.pendingMetadataTrack = null;
        // ⚠️ 最后一道闸门：状态机是 AVPlayer 亲自上报的，比任何标志位都可信。
        // 只要播放器此刻已经握着可用的音源（prepared 及之后），声音这一侧就是好的，
        // 本次异常必定来自收尾环节 —— 既不能回滚界面，也不能弹「加载失败」。
        // 这就是「明明在播，却每次点歌都提示加载失败」的直接消除点。
        if (this.playerHoldsSource()) {
            console.error(`recover skipped, player already holds a source: ${this.playerState}`);
            return;
        }
        const current: Track | null = (AppStorage.get(STORE_CURRENT_TRACK) as Track) ?? null;
        const stillOnFailed: boolean = current !== null && current.id === failed.id;
        const fallback: Track | null = this.lastPlayableTrack;
        let rolledBack: boolean = false;
        if (stillOnFailed && fallback !== null && fallback.id !== failed.id) {
            this.setStore(STORE_CURRENT_TRACK, fallback);
            this.currentIndex = this.findIndexInDisplay(fallback.id);
            rolledBack = true;
        }
        // 文案必须说清「切回了哪首」。早前只说「已保留当前歌曲」，用户看到界面上的
        // 封面歌名跟他刚点的那首不一样，会以为是「信息加载错了」——实际是回滚。
        const title: string = failed.title.length > 0 ? failed.title : '这首歌';
        if (rolledBack && fallback !== null) {
            const back: string = fallback.title.length > 0 ? fallback.title : '上一首';
            this.notifyHint(`「${title}」无法播放，已切回「${back}」`);
        }
        else {
            // 没有发生界面回滚（界面本来就还停在用户点的那首上），无需打扰用户：
            // 留日志即可。真正播不出来的歌会由 AVPlayer 的 error 链路统一给出提示。
            console.error(`audio unavailable without rollback: ${failed.id}`);
        }
    }
    private playerHoldsSource(): boolean {
        const s: string = this.playerState;
        return s === 'prepared' || s === 'playing' || s === 'paused' || s === 'completed';
    }
    playTrack(track: Track): void {
        // 「仅 WiFi 播放」：在线音源在蜂窝网络下不启动播放（本地已下载曲目不耗流量，放行）。
        // 探测失败一律放行（isUnmeteredNetwork 的约定：拦错了比放行更伤用户）。
        // 拦截点选在 playTrack：playNow / playAll / 自动切下一首全部经由这里，一处拦截全覆盖。
        const localPath: string = track.localFilePath ?? '';
        if (localPath.length === 0
            && AppPreferences.getSettings().wifiOnlyPlay
            && !isUnmeteredNetwork()) {
            this.notifyHint('已开启「仅 WiFi 播放」，当前为移动网络');
            return;
        }
        this.shouldAutoplay = true;
        this.setStore(STORE_CURRENT_TRACK, track);
        this.currentIndex = this.findIndexInDisplay(track.id);
        // 必须接住：loadAndPlay 内部的 catch 还要做回滚与提示，那部分若再抛异常，
        // 未处理的 Promise rejection 会让整条切歌链路静默中断，界面毫无反馈
        this.loadAndPlay(track, true).catch((e: Error): void => {
            console.error(`playTrack failed: ${e.message}`);
        });
    }
    play(): void {
        this.shouldAutoplay = true;
        // 正在解析音源 / 重建播放器：此刻 avPlayer 可能为空、也可能正在被释放。
        // 只登记「要播放」的意图即可 —— 新音源进入 prepared 时会读 shouldAutoplay 自动开播。
        if (this.isPreparing) {
            return;
        }
        const s: string = this.playerState;
        // 需要「重新解析音源 + 重建播放器」的几种情形，统一走 loadAndPlay：
        //   idle     —— 冷启动恢复后尚未加载过音源；
        //   error    —— 上一次播放失败，旧实现不管 error 态，导致播放键彻底变成死键
        //               （点一下毫无反应，也没有任何提示）；
        //   released —— 播放器实例已被回收（清空队列 / 队列清空后）。
        // 播放器指针为空时同理：不能直接 return，否则同样是死键。
        if (!this.avPlayer || s === 'idle' || s === 'error' || s === 'released') {
            const track: Track | null = this.currentTrackSnapshot();
            if (track) {
                const pos: number = this.pendingResumePosition >= 0 ? this.pendingResumePosition : ((AppStorage.get(STORE_PROGRESS) as number) ?? 0);
                this.pendingResumePosition = -1;
                this.loadAndPlay(track, true, pos).catch((e: Error): void => {
                    console.error(`reload and play failed: ${e.message}`);
                });
            }
            return;
        }
        if (s === 'prepared' || s === 'paused' || s === 'completed' || s === 'playing') {
            try {
                // 'completed' 状态下直接 play() 会立刻再次触发结束事件（表现为「点了播放没反应」），
                // 需要先回到起点。但若用户刚把进度拖到中间（进度不在末尾），则保留其位置。
                const dur: number = this.knownDuration();
                const pos: number = (AppStorage.get(STORE_PROGRESS) as number) ?? 0;
                if (s === 'completed' && (dur <= 0 || pos >= dur - 1)) {
                    this.avPlayer.seek(0);
                    this.lastProgressBucket = 0;
                    this.setStore(STORE_PROGRESS, 0);
                }
                // play() 返回 Promise，拒绝必须接住，否则未处理的 rejection 会让
                // 「点了播放但没出声」这件事完全不可见
                this.avPlayer.play().catch((e: BusinessError): void => {
                    console.error(`avPlayer.play failed: ${e.code} ${e.message}`);
                });
            }
            catch (e) {
                console.error(`avPlayer.play threw: ${JSON.stringify(e)}`);
            }
        }
        this.setStore(STORE_IS_PLAYING, true);
        this.updateSessionState();
        this.syncBackgroundTask(true);
        this.savePlayerStateNow();
    }
    pause(): void {
        this.shouldAutoplay = false;
        // 准备中：播放器可能在释放/重建，直接操作有空指针风险。
        // 把播放意图置 false 就够了 —— 音源就绪后 prepared 分支不会再自动播放。
        if (this.isPreparing) {
            this.setStore(STORE_IS_PLAYING, false);
            this.updateSessionState();
            this.syncBackgroundTask(false);
            return;
        }
        if (this.avPlayer) {
            const s: string = this.playerState;
            if (s === 'prepared' || s === 'paused' || s === 'playing' || s === 'completed') {
                try {
                    this.avPlayer.pause().catch((e: BusinessError): void => {
                        console.error(`avPlayer.pause failed: ${e.code} ${e.message}`);
                    });
                }
                catch (e) {
                    console.error(`avPlayer.pause threw: ${JSON.stringify(e)}`);
                }
            }
        }
        this.setStore(STORE_IS_PLAYING, false);
        this.updateSessionState();
        this.syncBackgroundTask(false);
        this.savePlayerStateNow();
    }
    togglePlay(): void {
        const playing: boolean = (AppStorage.get(STORE_IS_PLAYING) as boolean) ?? false;
        if (playing) {
            this.pause();
        }
        else {
            this.play();
        }
    }
    private knownDuration(): number {
        if (this.lastDuration > 0) {
            return this.lastDuration;
        }
        return (AppStorage.get(STORE_DURATION) as number) ?? 0;
    }
    /**
     * 跳转到指定秒数。
     * - 目标值按已知时长裁剪，避免拖到末尾后 AVPlayer 直接判定播放结束；
     * - 同步重置进度分桶游标，否则 seek 后的第一条 timeUpdate 可能因落在同一桶被丢弃，
     *   界面进度会「停在旧位置不动」。
     */
    seek(seconds: number): void {
        const dur: number = this.knownDuration();
        let target: number = seconds;
        if (!(target >= 0)) {
            target = 0;
        }
        if (dur > 0 && target > dur) {
            target = dur;
        }
        if (this.avPlayer) {
            const s: string = this.playerState;
            if (s === 'prepared' || s === 'playing' || s === 'paused' || s === 'completed') {
                // 标记 seeking：seek 异步生效前 timeUpdate 仍按旧位置回调，
                // 抑制其回传防止滑块被拽回（配合 seekDone 解除抑制）。
                this.seeking = true;
                this.seekStartedAt = Date.now();
                try {
                    // 注意：本机 SDK 的 `AVPlayer.seek(timeMs, mode?)` 返回 void（不是 Promise），
                    // 所以只能用 try/catch 拦同步异常，异步结果靠 seekDone / error 事件体现。
                    this.avPlayer.seek(target * 1000);
                }
                catch (e) {
                    this.seeking = false;
                    this.lastProgressBucket = -1;
                    console.error(`avPlayer.seek failed: ${JSON.stringify(e)}`);
                }
            }
            else {
                // 状态机里没有可 seek 的状态：留一条日志，否则问题会完全不可见
                console.error(`seek skipped, unexpected playerState: ${s}`);
            }
        }
        this.lastProgressBucket = Math.floor((target * 1000) / PROGRESS_PUSH_INTERVAL_MS);
        this.setStore(STORE_PROGRESS, target);
        this.updateSessionState();
        // 跳转高频（拖动进度条时连续触发），落盘加 2s 粗节流，避免反复写 Preferences
        const nowSeek: number = Date.now();
        if (nowSeek - this.lastStatePersistAt >= 2000) {
            this.lastStatePersistAt = nowSeek;
            this.savePlayerStateNow();
        }
    }
    next(): void {
        const dq: Track[] = this.displayQueue();
        if (dq.length === 0) {
            return;
        }
        const idx: number = this.currentIndex + 1 >= dq.length ? 0 : this.currentIndex + 1;
        this.currentIndex = idx;
        this.shouldAutoplay = true;
        this.playTrack(dq[idx]);
    }
    prev(): void {
        const dq: Track[] = this.displayQueue();
        if (dq.length === 0) {
            return;
        }
        const idx: number = this.currentIndex - 1 < 0 ? dq.length - 1 : this.currentIndex - 1;
        this.currentIndex = idx;
        this.shouldAutoplay = true;
        this.playTrack(dq[idx]);
    }
    private findIndexInDisplay(id: string): number {
        const dq: Track[] = this.displayQueue();
        for (let i = 0; i < dq.length; i++) {
            if (dq[i].id === id) {
                return i;
            }
        }
        return 0;
    }
    setQueue(tracks: Track[]): void {
        this.queue = tracks.slice();
        this.shuffledQueue = this.shuffle(tracks);
        this.syncQueue();
        this.savePlayerStateNow();
    }
    playAll(tracks: Track[]): void {
        if (tracks.length === 0) {
            return;
        }
        this.setQueue(tracks);
        this.currentIndex = 0;
        this.playTrack(tracks[0]);
        this.savePlayerStateNow();
    }
    playNow(track: Track): void {
        const filtered: Track[] = this.queue.filter((t: Track): boolean => t.id !== track.id);
        this.queue = [track, ...filtered];
        this.shuffledQueue = this.shuffle(this.queue);
        this.syncQueue();
        this.currentIndex = 0;
        this.playTrack(track);
        this.savePlayerStateNow();
        // B 站的音乐「合集」是同一视频的多个分 P，每个分 P 一首歌。
        // 只按 bvid 解析音频的话永远停在第一个分 P，所以顺带把整张合集铺进队列。
        // ⚠️ 必须延后执行：它内部要再发一次 view 请求，与音源解析（view + playurl）
        // 同一刻发出会互相挤占连接，首包被拒就是「点了歌提示无法播放」的成因之一。
        setTimeout((): void => {
            this.expandMultiParts(track).catch((e: Error): void => {
                console.error(`expandMultiParts failed: ${e.message}`);
            });
        }, EXPAND_PARTS_DELAY_MS);
    }
    /**
     * 轻提示（后台任务拿不到 UIContext，写 AppStorage 由全局 AppToast 弹出）。
     * seq 读-改-写递增：与 UI 侧 showAppToast 共用同一计数器，独立计数会撞号丢提示。
     */
    private notifyHint(message: string): void {
        AppStorage.setOrCreate(STORE_TOAST_MSG, message);
        AppStorage.setOrCreate(STORE_TOAST_HOLD_MS, 1800);
        const seq: number = AppStorage.get<number>(STORE_TOAST_SEQ) ?? -1;
        AppStorage.setOrCreate(STORE_TOAST_SEQ, seq + 1);
    }
    /**
     * 累计听歌时长。
     *
     * timeUpdate 只在播放中回调（约 100ms 一次），每次按真实时间差累加；
     * 间隔超过 LISTEN_TICK_MAX_GAP_MS 的视为挂起/恢复产生的空洞，丢弃不计。
     * 攒满 LISTEN_FLUSH_SECONDS 落盘一次，release 时把余量一并写掉。
     */
    private accumulateListenTime(): void {
        const now: number = Date.now();
        if (this.lastListenTickAt > 0) {
            const deltaMs: number = now - this.lastListenTickAt;
            if (deltaMs > 0 && deltaMs <= LISTEN_TICK_MAX_GAP_MS) {
                this.listenAccumSeconds += deltaMs / 1000;
            }
        }
        this.lastListenTickAt = now;
        if (this.listenAccumSeconds >= LISTEN_FLUSH_SECONDS) {
            this.flushListenTime();
        }
    }
    /** 把会话内累计的听歌秒数（整数部分）落盘，失败只留日志不影响播放 */
    private flushListenTime(): void {
        const add: number = Math.floor(this.listenAccumSeconds);
        if (add < 1) {
            return;
        }
        this.listenAccumSeconds -= add;
        AppPreferences.addListenSeconds(add).catch((e: Error): void => {
            console.error(`save listen seconds failed: ${e.message}`);
        });
    }
    /**
     * 展开多 P 合集并追加到当前曲目之后。
     * 只在首次播放该 bvid 时请求一次 view 接口；单 P 视频直接返回，不产生额外开销。
     */
    private async expandMultiParts(track: Track): Promise<void> {
        const bvid: string = track.bvid ? track.bvid : track.id;
        // 音乐中心用的是音乐 id，不是 bvid，展开没有意义
        if (bvid.length === 0 || bvid.indexOf('BV') !== 0) {
            return;
        }
        if (this.expandedBvids.has(bvid)) {
            return;
        }
        this.expandedBvids.add(bvid);
        try {
            const parts: Track[] = await expandVideoParts(bvid, track);
            if (parts.length <= 1) {
                return;
            }
            this.insertAfterCurrent(parts.slice(1));
            this.notifyHint(`已加载合集，共 ${parts.length} 首`);
        }
        catch (e) {
            // 失败时移出缓存，下次播放还可以再试
            this.expandedBvids.delete(bvid);
            console.error(`expand collection failed: ${JSON.stringify(e)}`);
        }
    }
    /**
     * 把曲目插到当前曲目之后：按 id 去重，并保持 currentIndex 仍指向正在播放的那首。
     * 随机播放下 shuffledQueue 会重排，必须按当前曲目 id 重新定位，否则「下一首」会跳错。
     */
    private insertAfterCurrent(tracks: Track[]): void {
        if (tracks.length === 0) {
            return;
        }
        const existing: Set<string> = new Set<string>(this.queue.map((t: Track): string => t.id));
        const fresh: Track[] = tracks.filter((t: Track): boolean => !existing.has(t.id));
        if (fresh.length === 0) {
            return;
        }
        const curId: string = this.currentTrackSnapshot()?.id ?? '';
        let at: number = curId.length > 0 ? this.queue.findIndex((t: Track): boolean => t.id === curId) : -1;
        if (at < 0) {
            at = this.currentIndex >= 0 && this.currentIndex < this.queue.length ? this.currentIndex : this.queue.length - 1;
        }
        const insertAt: number = Math.min(at + 1, this.queue.length);
        this.queue = [...this.queue.slice(0, insertAt), ...fresh, ...this.queue.slice(insertAt)];
        this.shuffledQueue = this.shuffle(this.queue);
        this.syncQueue();
        if (curId.length > 0) {
            const dq: Track[] = this.displayQueue();
            const idx: number = dq.findIndex((t: Track): boolean => t.id === curId);
            if (idx >= 0) {
                this.currentIndex = idx;
            }
        }
    }
    playNext(track: Track): void {
        if (this.queue.length === 0) {
            this.playNow(track);
            return;
        }
        const without: Track[] = this.queue.filter((t: Track): boolean => t.id !== track.id);
        const curIdx: number = without.findIndex((t: Track): boolean => t.id === this.currentTrackSnapshot()?.id);
        const insertAt: number = curIdx >= 0 ? curIdx + 1 : without.length;
        this.queue = [...without.slice(0, insertAt), track, ...without.slice(insertAt)];
        this.shuffledQueue = this.shuffle(this.queue);
        this.syncQueue();
    }
    addToQueue(track: Track): void {
        const exists: boolean = this.queue.some((t: Track): boolean => t.id === track.id);
        if (!exists) {
            this.queue = [...this.queue, track];
            this.shuffledQueue = this.shuffle(this.queue);
            this.syncQueue();
        }
        if (this.currentIndex < 0 && this.queue.length > 0) {
            this.currentIndex = 0;
            this.setStore(STORE_CURRENT_TRACK, this.queue[0]);
        }
    }
    addTracksToQueue(tracks: Track[]): void {
        const existing: Set<string> = new Set<string>(this.queue.map((t: Track): string => t.id));
        const fresh: Track[] = tracks.filter((t: Track): boolean => !existing.has(t.id));
        if (fresh.length > 0) {
            this.queue = [...this.queue, ...fresh];
            this.shuffledQueue = this.shuffle(this.queue);
            this.syncQueue();
        }
    }
    removeFromQueue(trackId: string): void {
        this.queue = this.queue.filter((t: Track): boolean => t.id !== trackId);
        this.shuffledQueue = this.shuffle(this.queue);
        this.syncQueue();
    }
    clearQueue(): void {
        this.queue = [];
        this.shuffledQueue = [];
        this.currentIndex = -1;
        this.syncQueue();
        this.setStore(STORE_CURRENT_TRACK, null);
        this.pause();
        this.savePlayerStateNow();
        // 回收播放器实例而不是原地 reset()：reset 会触发一次旧音源的 error，
        // 而此时 STORE_CURRENT_TRACK 已是 null，error 回调会弹一句莫名其妙的
        // 「音频加载失败」。摘监听后 release 就没有这个副作用。
        this.dropPlayer();
    }
    /**
     * 设置播放模式（顺序 / 列表循环 / 单曲循环 / 随机）。
     *
     * 随机播放并入模式枚举，所以这里要同步维护 `isShuffled` 与洗牌队列：
     * 进入随机时重新洗牌并把 currentIndex 重新对准当前曲目，
     * 否则「下一首」会从洗牌队列的第 0 位开始，跳成另一首歌。
     */
    setRepeatMode(mode: RepeatMode): void {
        this.repeatMode = mode;
        const wantShuffle: boolean = mode === RepeatMode.SHUFFLE;
        if (wantShuffle !== this.isShuffled) {
            this.isShuffled = wantShuffle;
            if (wantShuffle) {
                this.shuffledQueue = this.shuffle(this.queue);
            }
            const cur: Track | null = this.currentTrackSnapshot();
            if (cur) {
                this.currentIndex = this.findIndexInDisplay(cur.id);
            }
        }
        this.setStore(STORE_REPEAT_MODE, mode);
        this.setStore(STORE_SHUFFLE, this.isShuffled);
        this.savePlayerStateNow();
    }
    /** 兼容旧调用：开/关随机等价于在 随机 / 顺序 两个模式间切换。 */
    setShuffle(shuffle: boolean): void {
        this.setRepeatMode(shuffle ? RepeatMode.SHUFFLE : RepeatMode.NONE);
    }
    setVolume(v: number): void {
        this.volume = Math.max(0, Math.min(100, v));
        this.setStore(STORE_VOLUME, this.volume);
        if (this.avPlayer) {
            this.avPlayer.setVolume(this.isMuted ? 0 : this.volume / 100);
        }
    }
    setMuted(muted: boolean): void {
        this.isMuted = muted;
        this.setStore(STORE_MUTED, muted);
        if (this.avPlayer) {
            this.avPlayer.setVolume(muted ? 0 : this.volume / 100);
        }
    }
    /**
     * 定时停止播放的定时器句柄（-1 = 未开启）。
     *
     * 计时器放在播放内核（单例）而不是设置页：到点要停的是**播放**，
     * 跟着播放器走生命周期更合理，页面重建也不会丢定时。
     */
    private sleepTimer: number = -1;
    /**
     * 设置「定时停止播放」。
     * @param minutes 多少分钟后自动暂停；<= 0 表示取消定时
     */
    setSleepTimer(minutes: number): void {
        this.clearSleepTimer();
        if (minutes <= 0) {
            this.setStore(STORE_SLEEP_TIMER_END, 0);
            this.notifyHint('已取消定时停止');
            return;
        }
        const delayMs: number = minutes * 60 * 1000;
        // 只发布**结束时刻**：剩余时间由设置页现算，内核不必每秒写一次 AppStorage
        this.setStore(STORE_SLEEP_TIMER_END, Date.now() + delayMs);
        this.sleepTimer = setTimeout((): void => {
            this.sleepTimer = -1;
            this.setStore(STORE_SLEEP_TIMER_END, 0);
            this.pause();
            this.notifyHint('定时结束，已停止播放');
        }, delayMs);
        const label: string = (minutes >= 60 && minutes % 60 === 0)
            ? `${minutes / 60} 小时`
            : `${minutes} 分钟`;
        this.notifyHint(`已设置 ${label} 后停止播放`);
    }
    private clearSleepTimer(): void {
        if (this.sleepTimer !== -1) {
            clearTimeout(this.sleepTimer);
            this.sleepTimer = -1;
        }
    }
    toggleLike(track: Track): void {
        // 这里只是翻一个布尔位：显式复制一份，不要借道 mergeTrack。
        // mergeTrack 的职责是「把音源解析结果并回来」，用它做这件小事会把列表侧元数据
        // 按音源侧的值重写一遍，反而容易把信息写坏。
        const updated: Track = {
            id: track.id,
            title: track.title,
            artist: track.artist,
            coverUrl: track.coverUrl,
            duration: track.duration,
            videoUrl: track.videoUrl,
            bvid: track.bvid,
            aid: track.aid,
            cid: track.cid,
            playCount: track.playCount,
            isLiked: !track.isLiked,
            likedAt: track.likedAt,
            audioUrl: track.audioUrl,
            audioQuality: track.audioQuality,
            audioMimeType: track.audioMimeType
        };
        this.setStore(STORE_CURRENT_TRACK, updated);
        LibraryStore.toggleFavoriteTrack(updated);
    }
    private shuffle<T>(arr: T[]): T[] {
        const a: T[] = arr.slice();
        for (let i = a.length - 1; i > 0; i--) {
            const j: number = Math.floor(Math.random() * (i + 1));
            const tmp: T = a[i];
            a[i] = a[j];
            a[j] = tmp;
        }
        return a;
    }
    /**
     * 播放结束（AVPlayer 进入 completed）时的走向。播放模式是唯一判据：
     *   单曲循环 → 回到 0 秒重放当前曲
     *   列表循环 → 无条件下一首（末尾回到第一首）
     *   随机播放 → 洗牌队列里下一首（天然无穷）
     *   顺序播放 → 有下一首就继续，到列表末尾就停在本曲
     *
     * 注意：不能再拿 settings.autoPlay 兜底成「永远下一首」，
     * 否则「顺序播放」会退化成「列表循环」，用户永远等不到停止。
     */
    private handleEnded(): void {
        const dq: Track[] = this.displayQueue();
        if (dq.length === 0) {
            this.stopAtCurrent();
            return;
        }
        if (this.repeatMode === RepeatMode.ONE) {
            if (this.avPlayer) {
                try {
                    this.avPlayer.seek(0);
                    this.avPlayer.play().catch((e: BusinessError): void => {
                        console.error(`replay failed: ${e.code} ${e.message}`);
                    });
                }
                catch (e) {
                    console.error(`replay threw: ${JSON.stringify(e)}`);
                }
            }
            this.lastProgressBucket = 0;
            this.setStore(STORE_PROGRESS, 0);
            this.updateSessionState();
            this.syncBackgroundTask(true);
            return;
        }
        // 「自动播放下一首」关闭时，任何模式都停在当前曲（含列表循环，尊重用户的显式设置）
        const autoPlay: boolean = AppPreferences.getSettings().autoPlay;
        if (!autoPlay) {
            this.stopAtCurrent();
            return;
        }
        if (this.repeatMode === RepeatMode.ALL || this.repeatMode === RepeatMode.SHUFFLE) {
            this.next();
            return;
        }
        if (this.currentIndex + 1 < dq.length) {
            this.next();
            return;
        }
        this.stopAtCurrent();
    }
    /**
     * 停在当前曲目末尾（不切歌）。
     * 旧实现会把 STORE_CURRENT_TRACK 换成下一首却不加载音频，
     * 界面上歌名变了、实际音轨还是上一首，点播放也放不出来。
     */
    private stopAtCurrent(): void {
        this.shouldAutoplay = false;
        this.setStore(STORE_IS_PLAYING, false);
        this.updateSessionState();
        this.syncBackgroundTask(false);
    }
    release(): void {
        // 进程即将销毁，把不足落盘阈值的听歌余量补写掉（最多丢不足 1 秒的零头）
        this.flushListenTime();
        if (this.context) {
            BackgroundPlayback.getInstance().stop(this.context).catch((e: Error): void => {
                console.error(`stop continuousTask on release failed: ${JSON.stringify(e)}`);
            });
        }
        this.isPreparing = false;
        this.pendingMetadataTrack = null;
        this.clearSleepTimer();
        if (this.prefetchTimer !== -1) {
            clearTimeout(this.prefetchTimer);
            this.prefetchTimer = -1;
        }
        this.dropPlayer();
        this.playerState = 'released';
        if (this.session) {
            try {
                this.session.destroy();
            }
            catch (e) {
                console.error(`destroy avSession failed: ${JSON.stringify(e)}`);
            }
            this.session = null;
        }
    }
}
