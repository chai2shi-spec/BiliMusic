/**
 * BiliMusic 数据模型（原生 ArkTS 版）
 * 对应原 React 项目的 src/types/index.ts 与 services 中的数据结构。
 */
/**
 * 播放模式。
 *
 * 「随机播放」在华为音乐 / 网易云等主流播放器里是播放模式的一种（与顺序/循环同级，
 * 而不是一个独立开关），因此并入本枚举，UI 上统一由同一个按钮轮换。
 * 语义：
 *   NONE    顺序播放 —— 放到列表末尾即停
 *   ALL     列表循环 —— 放到末尾回到第一首
 *   ONE     单曲循环 —— 单曲播完从头重放
 *   SHUFFLE 随机播放 —— 走洗牌后的队列，永不「放到末尾」
 */
export enum RepeatMode {
    NONE = "none",
    ALL = "all",
    ONE = "one",
    SHUFFLE = "shuffle"
}
export enum DownloadStatus {
    PENDING = "pending",
    DOWNLOADING = "downloading",
    PAUSED = "paused",
    COMPLETED = "completed",
    ERROR = "error"
}
/** 设置页「仅 WiFi 下载」开关未开启时的默认值（默认不限制，行为与加开关之前一致） */
export const DEFAULT_WIFI_ONLY_DOWNLOAD: boolean = false;
export enum ThemeMode {
    SYSTEM = "system",
    LIGHT = "light",
    DARK = "dark"
}
/**
 * 下载音质档位（设置页「下载音质」的可选值，同时是 AppSettings.downloadQuality 的取值）。
 *
 * 语义是「优先要哪一档」而不是「必须是哪一档」：目标档位在服务端不存在时会按
 * 预定义顺序降级（见 BilibiliApi.audioQualityCandidates），绝不会因为「没有 132K」
 * 就拒绝下载。
 */
export enum AudioQuality {
    STANDARD = "\u6807\u51C6",
    HIGH = "\u9AD8\u54C1\u8D28",
    LOSSLESS = "\u65E0\u635F"
}
/**
 * 下载音质档位 → B 站音频流 quality id（用户选择的「首选档」）。
 *
 * 映射到 30280(192K) 而不是 30232(132K) 作为「高品质」，是为了**不改变加这个功能之前的默认行为**：
 * 老实现按 bandwidth 取最大，实际拿到的就是 30280；若把「高品质」映射到 132K，
 * 老用户升级后会发现下载的音频反而变差了。
 * 未知取值一律按 192K 处理（与 DEFAULT_APP_SETTINGS.downloadQuality 保持一致）。
 */
export function downloadQualityId(quality: string): number {
    if (quality === AudioQuality.STANDARD) {
        return 30216;
    }
    if (quality === AudioQuality.LOSSLESS) {
        return 30251;
    }
    return 30280;
}
/**
 * 可播放曲目。B 站音频需要从 bvid(+cid) 实时解析出 audioUrl。
 * 为兼容音乐中心伪 id，aid/cid 作为 view 接口 -404 时的回退。
 */
export interface Track {
    id: string;
    title: string;
    artist: string;
    coverUrl: string;
    duration: number;
    videoUrl: string;
    bvid: string;
    aid: string;
    cid: string;
    playCount: number;
    isLiked: boolean;
    likedAt: string;
    audioUrl: string;
    audioQuality: number;
    audioMimeType: string;
    /**
     * 已下载到沙箱的本地文件路径（可选）。
     *
     * 非空即代表「这一首不用联网解析音源，直接播本地文件」—— 播放内核据此走
     * `switchSourceLocal`，不再发 view/playurl 请求（离线也能放）。
     * 只在「从下载管理页播放」这条链路上写入；线上下发的曲目永远为空。
     */
    localFilePath?: string;
}
export function buildTrack(partial: Partial<Track>): Track {
    return {
        id: partial.id ?? '',
        title: partial.title ?? '',
        artist: partial.artist ?? '',
        coverUrl: partial.coverUrl ?? '',
        duration: partial.duration ?? 0,
        videoUrl: partial.videoUrl ?? '',
        bvid: partial.bvid ?? '',
        aid: partial.aid ?? '',
        cid: partial.cid ?? '',
        playCount: partial.playCount ?? 0,
        isLiked: partial.isLiked ?? false,
        likedAt: partial.likedAt ?? '',
        audioUrl: partial.audioUrl ?? '',
        audioQuality: partial.audioQuality ?? 0,
        audioMimeType: partial.audioMimeType ?? '',
        // 空串表示「这条曲目没有本地文件」（播放在线源）；非空即播放内核直接读本地文件
        localFilePath: partial.localFilePath ?? ''
    };
}
// 背景（踩过的坑）：`@ohos.data.preferences` 对 **string 类型的 value 有 8192 字节硬上限**，
// 超限时 `put()` 直接抛错。而 Track 里最大的字段 audioUrl 是带签名 token 的 B 站音频直链
// （动辄 400~600 字符），把「最近播放 50 首」整体 JSON.stringify 后能到 20KB 以上
// → 写入失败，且调用侧 fire-and-forget 没有 catch → 整块数据静默丢失
// （表现就是「最近播放页面永远没有记录」「歌单加了歌不生效」）。
//
// 因此凡是要落到 Preferences 的曲目列表，都先 slimTrack 去掉当次播放才用的字段，
// 再用 fitByByteBudget 按真实 UTF-8 字节数截断。
/** Preferences 单值上限为 8192 字节，留出余量按 6000 收口 */
export const PREF_VALUE_BUDGET_BYTES: number = 6000;
/**
 * 估算 UTF-8 字节数。
 * 不能直接用 `str.length`：上限按字节算，中文一字占 3 字节，
 * 用字符数估算会高估剩余容量，写入照样会超限失败。
 */
export function utf8Length(s: string): number {
    let bytes: number = 0;
    for (let i = 0; i < s.length; i++) {
        const c: number = s.charCodeAt(i);
        if (c < 128) {
            bytes += 1;
        }
        else if (c < 2048) {
            bytes += 2;
        }
        else {
            bytes += 3;
        }
    }
    return bytes;
}
/**
 * 构造「可持久化」的精简曲目：丢弃只在当次播放过程中有用的字段。
 *
 * 关键点：`audioUrl` 不需要落盘——它在播放链路上并没有被复用
 * （`MusicPlayer.loadAndPlay` 每次都会重新走 playurl 解析出带新签名的直链），
 * 而且直链带时效性 token，存下来过一会儿也是失效的。
 */
export function slimTrack(track: Track): Track {
    return {
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
        isLiked: track.isLiked,
        likedAt: track.likedAt,
        audioUrl: '',
        audioQuality: track.audioQuality,
        audioMimeType: track.audioMimeType,
        // 本地路径要保留：否则「播着下载好的歌 → 关 App → 重开」之后，
        // 恢复出来的队列会退回线上解析（离线时直接播不出来）。
        // 它只有几十字节，对 8192 字节的 Preferences 上限没有实质影响。
        localFilePath: track.localFilePath
    };
}
/**
 * 按字节预算截断列表：从头保留，直到再加一条就超出预算为止。
 * 宁可少存几条，也不能让整次写入失败（失败等于一条不剩）。
 */
export function fitByByteBudget<T>(list: T[], budget: number): T[] {
    const out: T[] = [];
    for (let i = 0; i < list.length; i++) {
        out.push(list[i]);
        if (utf8Length(JSON.stringify(out)) > budget) {
            out.pop();
            break;
        }
    }
    return out;
}
export interface Playlist {
    id: string;
    name: string;
    description: string;
    coverUrl: string;
    createdAt: string;
    updatedAt: string;
    tracks: Track[];
}
/** 删除墓碑：云同步时区分「此端删除」与「从未有过」 */
export interface Tombstone {
    id: string;
    deletedAt: string;
}
export interface AppSettings {
    sidebarState: string; // 手机端固定为 'auto'
    playQuality: string;
    downloadQuality: string;
    downloadDir: string;
    autoPlay: boolean;
    showLyrics: boolean;
    /** 仅 WiFi 下载：开启后移动网络下下载前先询问，避免偷跑流量 */
    wifiOnlyDownload: boolean;
    /** 仅 WiFi 播放：开启后移动网络下不播放在线歌曲（本地已下载曲目不受限） */
    wifiOnlyPlay: boolean;
    themeMode: ThemeMode;
}
export const DEFAULT_APP_SETTINGS: AppSettings = {
    sidebarState: 'auto',
    playQuality: '高品质',
    downloadQuality: '高品质',
    downloadDir: '',
    autoPlay: true,
    showLyrics: true,
    wifiOnlyDownload: DEFAULT_WIFI_ONLY_DOWNLOAD,
    wifiOnlyPlay: false,
    themeMode: ThemeMode.SYSTEM
};
export interface LyricLine {
    time: number;
    text: string;
}
export interface LyricResult {
    lines: LyricLine[];
    synced: boolean;
    instrumental: boolean;
    trackName: string;
    artistName: string;
    sourceId: string;
}
export interface LyricCandidate {
    id: string;
    songId: string | number;
    mid: string;
    trackName: string;
    artistName: string;
    albumName: string;
    duration: number;
    image: string;
}
export type LyricStatus = 'idle' | 'loading' | 'ok' | 'unsynced' | 'empty';
export interface DownloadTask {
    id: string;
    musicId: string;
    title: string;
    artist: string;
    coverUrl: string;
    url: string;
    totalBytes: number;
    downloadedBytes: number;
    /**
     * 实时下载速度（字节/秒）。
     *
     * ⚠️ **只在内存里流转、不落库**（download_task 表没有这一列，也不该有：
     * 速度是瞬时量，重启后残留一个旧读数比显示 0 更误导）。字段为 0 时界面不显示速度。
     */
    speed: number;
    /**
     * 本条实际采用的音频档位 id（30216 / 30232 / 30280 …）与实测带宽（bps）。
     *
     * ⚠️ 同样**不落库**（download_task 表没有这两列，本项目刻意不为它做 DB 迁移）。
     * 用途是让用户看见「到底下到了什么音质」——尤其是遇到服务端只有低码率源的投稿时，
     * 界面上那句「192kbps」如果来自档位标签就是在骗人，必须用实测 bandwidth 说话。
     */
    audioQuality: number;
    audioBandwidth: number;
    status: DownloadStatus;
    errorMessage: string;
    createdAt: number;
    completedAt: number;
    localFilePath: string;
}
// ===== B 站 API 原始结构（仅用于解析，字段按需保留） =====
export interface SearchResultItem {
    bvid: string;
    aid: number;
    title: string;
    author: string;
    play: number;
    videoReview: number;
    duration: string;
    pubdate: number;
    pic: string;
    description: string;
}
export interface VideoOwner {
    mid: number;
    name: string;
    face: string;
}
export interface VideoStat {
    view: number;
    danmaku: number;
    like: number;
    coin: number;
    favorite: number;
    share: number;
}
export interface VideoPageInfo {
    cid: number;
    /** 分 P 序号（从 1 开始）。部分响应不携带，仅用于生成稳定 id。 */
    page?: number;
    part: string;
    duration: number;
}
export interface VideoDetail {
    bvid: string;
    aid: number;
    title: string;
    desc: string;
    pic: string;
    owner: VideoOwner;
    stat: VideoStat;
    duration: number;
    cid: number;
    videos: number;
    pages: VideoPageInfo[];
    pubdate: number;
}
export interface AudioStream {
    id: number;
    quality: number;
    bandwidth: number;
    mimeType: string;
    codecid: number;
    baseUrl: string;
    backupUrl: string[];
}
export interface DashData {
    audio: AudioStream[];
    video: AudioStream[];
}
export interface PlayUrlData {
    quality: number;
    format: string;
    dash: DashData;
}
export interface MusicCenterItem {
    musicId: string;
    musicTitle: string;
    author: string;
    bvid: string;
    aid: string;
    cid: string;
    cover: string;
    album?: string;
    score?: number;
    publishTime?: string;
    relatedArchive?: {
        aid: string;
        bvid: string;
        cid: string;
        cover: string;
        title: string;
        duration?: number;
    };
}
export interface TrackSource {
    bvid: string;
    aid: number;
    cid: number;
    title: string;
    artist: string;
    coverUrl: string;
    duration: number;
    audioUrl: string;
    audioQuality: number;
    audioMimeType: string;
    /** 所选音轨的实测带宽（bps）。见 DownloadTask.audioBandwidth 的说明。 */
    audioBandwidth: number;
}
