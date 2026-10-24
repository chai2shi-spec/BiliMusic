/**
 * BiliMusic 数据模型（原生 ArkTS 版）
 * 对应原 React 项目的 src/types/index.ts 与 services 中的数据结构。
 */

import util from '@ohos.util';

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
  NONE = 'none',
  ALL = 'all',
  ONE = 'one',
  SHUFFLE = 'shuffle'
}

export enum DownloadStatus {
  PENDING = 'pending',
  DOWNLOADING = 'downloading',
  PAUSED = 'paused',
  COMPLETED = 'completed',
  ERROR = 'error'
}

/** 设置页「仅 WiFi 下载」开关未开启时的默认值（默认不限制，行为与加开关之前一致） */
export const DEFAULT_WIFI_ONLY_DOWNLOAD: boolean = false;

export enum ThemeMode {
  SYSTEM = 'system',
  LIGHT = 'light',
  DARK = 'dark'
}

/**
 * 下载音质档位（设置页「下载音质」的可选值，同时是 AppSettings.downloadQuality 的取值）。
 *
 * 语义是「优先要哪一档」而不是「必须是哪一档」：目标档位在服务端不存在时会按
 * 预定义顺序降级（见 BilibiliApi.audioQualityCandidates），绝不会因为「没有 132K」
 * 就拒绝下载。
 */
export enum AudioQuality {
  STANDARD = '标准',
  HIGH = '高品质',
  LOSSLESS = '无损'
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
  /**
   * 投稿者 mid（B 站 UP 主 id），空串 = 未知。
   *
   * 「进 UP 主主页」「订阅该 UP 的投稿」都靠它。来源与覆盖率（2026-10-03 实测）：
   * 搜索结果自带 mid、ranking/v2 与推荐流走 `owner.mid` —— 三处都能直接落；
   * 音乐中心结构里没有 mid、已下载曲目 slimTrack 后只剩 bvid → 这两类走
   * `getVideoDetail(bvid)` 换（有 viewCache，不重复发请求）。
   */
  upMid: string;
  playCount: number;
  /**
   * B 站视频发布时间（unix 秒）。0 = 未知（音乐中心、升级前的存量数据），UI 不显示。
   * 来源：搜索 pubdate / 热门·排行·空间投稿 created；slimTrack 必须保留，
   * 否则最近播放/歌单条目重启后丢失。
   */
  pubdate: number;
  /**
   * 最近一次在本机播放的时间（ms 时间戳）。0 = 未知（旧版本落盘 / 从未播过）。
   * 由 LibraryStore.addRecentTrack 在播放时盖章；最近播放页按它做
   * 「最近 7 天」时间窗过滤（LibraryStore.RECENT_KEEP_MS）。
   * slimTrack 必须保留：丢了它，重启后记录会被整体判成旧数据。
   */
  playedAt: number;
  /**
   * 上次听到的播放位置（秒）。0 / undefined = 无记录（旧版本落盘 / 从未播过 /
   * 已听完由播放内核重置为 0）。由 MusicPlayer.recordRecentProgress 节流写入
   * （LibraryStore.updateRecentProgress）；最近播放页按续播阈值
   * （InteractionConstants.RESUME_MIN_SEC / RESUME_TAIL_SEC）决定
   * 是否从该位置续播、是否显示「上次听到 x:xx」。
   * slimTrack 必须保留：丢了它，重启后续播位置与显示全部归零。
   */
  lastPosSec?: number;
  isLiked: boolean;
  likedAt: string;
  /**
   * 加入歌单时间（ISO 8601 串）。仅「歌单内曲目实例」有意义：由 LibraryStore
   * 四条加歌路径盖章（addTrackToPlaylist / mergeUpTracks / subscribeUpPlaylist /
   * importPlaylists），队列 / 最近播放 / 收藏中的曲目该字段为空。
   * 歌单详情「排序→按加入时间」按它降序（新在前）；无戳存量条目首排时由
   * sortPlaylistTracks 物化补合成戳。slimTrack 必须保留，否则重启后丢失。
   */
  addedAt?: string;
  audioUrl: string;
  audioQuality: number;
  /**
   * 音源实测带宽（bps，来自 playurl 的 `dash.audio[].bandwidth`）。
   *
   * ⚠️ 2026-10-08 补：`audioQuality` 只是「档位 id」（30216/30280/30250…），
   * B 站经常**给低码率内容挂高档位标签**（内容侧本身上传的就是 66k，
   * 却按 192k 的档位下发给客户端）—— 只回显档位标签就是骗用户。
   * 所以 `Constants.ts` 里「界面上必须回显实际拿到的码率」这条要求需要**两个字段**：
   * 档位标签给 `audioQuality`，真实码率给本字段，显示时优先用本字段。
   *
   * `MusicPlayer.mergeTrack` 此前只搬了 `audioQuality` 把本字段丢了，
   * 导致播放页链路拿不到实测码率 —— 已修。
   */
  audioBandwidth: number;
  audioMimeType: string;
  /**
   * B 站下发的备用音频直链（playurl 的 backupUrl，最多 3 条）。
   * 主直链挂死 / 被拒时的快速回退：直接换源重挂，不发 playurl 请求。
   * 仅在线播放链路内存中使用：slimTrack / 落盘**不带**（带签名 token 的
   * 长直链会撑爆 Preferences 字节预算，且过期后无用）。
   * 空数组 = 无备用链（本地文件 / 旧缓存命中的曲目）。
   */
  audioBackupUrls?: string[];
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
    upMid: partial.upMid ?? '',
    playCount: partial.playCount ?? 0,
    pubdate: partial.pubdate ?? 0,
    playedAt: partial.playedAt ?? 0,
    lastPosSec: partial.lastPosSec ?? 0,
    isLiked: partial.isLiked ?? false,
    likedAt: partial.likedAt ?? '',
    audioUrl: partial.audioUrl ?? '',
    audioQuality: partial.audioQuality ?? 0,
    audioBandwidth: partial.audioBandwidth ?? 0,
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
// 因此凡是要落到 Preferences 的曲目列表，都先 slimTrack 去掉当次播放才用的字段。
// 列表层面的对策分两代（2026-10-12）：最近播放与歌单已改**分片存储**
// （每片 8 条独立 key，总量不再受单值上限约束）；**fitByByteBudget 目前仅收藏
// 仍在用**（单键 + 截断），收藏条数同样被截到约 11 条，待后续同模式改造。

/** Preferences 单值上限为 8192 字节，留出余量按 6000 收口 */
export const PREF_VALUE_BUDGET_BYTES: number = 6000;

/** 共享的 UTF-8 编码器（无状态，模块级单例避免每次分配） */
const utf8Encoder: util.TextEncoder = new util.TextEncoder();

/**
 * 精确 UTF-8 字节数。
 * 不能直接用 `str.length`：上限按字节算，中文一字占 3 字节，
 * 用字符数估算会高估剩余容量，写入照样会超限失败。
 * 2026-10-23 性能审查：改用 @ohos.util TextEncoder 精确编码 ——
 * 旧手算版把增补平面字符（emoji 等 >0xFFFF）算成 2×3=6 字节，实际只占 4。
 */
export function utf8Length(s: string): number {
  return utf8Encoder.encodeInto(s).length;
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
    upMid: track.upMid,
    playCount: track.playCount,
    // 发布时间要落盘（约 +22 字节/条）：最近播放/歌单条目重启后仍能显示
    pubdate: track.pubdate,
    // 最近播放时间同样要落盘（约 +15 字节/条）：最近播放页的 7 天时间窗靠它
    playedAt: track.playedAt ?? 0,
    // 上次听到的位置同样要落盘（约 +14 字节/条）：最近播放页的续播与
    // 「上次听到 x:xx」显示靠它
    lastPosSec: track.lastPosSec ?? 0,
    isLiked: track.isLiked,
    likedAt: track.likedAt,
    // 加入歌单时间要落盘（约 +25 字节/条，歌单分片存储无预算压力）：歌单详情
    // 「按加入时间」排序靠它。最近播放条目无此字段（undefined 不参与 JSON
    // 序列化，零字节成本）。
    addedAt: track.addedAt,
    audioUrl: '',
    audioQuality: track.audioQuality,
    // 要落盘：重启后进播放页还能显示上次那首的真实码率（约 6~9 字节/条，
    // 519→~527，对 6000 字节预算的影响可忽略）。
    audioBandwidth: track.audioBandwidth,
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
  /**
   * 订阅来源 UP 主 mid，空串 = 普通歌单（用户手动建的）。
   *
   * 非空的歌单是「UP 订阅」：详情页会出现「拉取新投稿」，
   * 走 BilibiliApi.getUserVideos(mid) 按 id 去重追加（不覆盖用户删掉的条目）。
   */
  upMid: string;
  /** 订阅来源 UP 主昵称（纯展示，避免每次进页面都再发一次资料请求） */
  upName: string;
  /**
   * 来源种类：`'up'` = 订阅 UP 投稿 / `'fav'` = B 站收藏夹镜像 / `''` = 普通歌单。
   *
   * ⚠️ 为什么要单独一个字段，而不是只看 `upMid` 是否非空：
   * `upMid`/`upName` 现在承担「通用来源 id / 来源名」两个角色 —— 订阅 UP 时是真实 mid，
   * 收藏夹镜像时是 `fav_{mediaId}`。但多处 UI 用 `upMid.length > 0` 判定「这是订阅歌单」，
   * 若收藏夹也填 `upMid`，歌单详情会错显「订阅自 XXX」、还会冒出「拉取新投稿」入口
   * （点了会用收藏夹 id 去调 UP 投稿接口）。所以必须有独立标记来区分两种来源。
   *
   * 可选字段（老数据读出来是 undefined）：由 `LibraryStore.toPlaylist` 兜底为
   * 「`upMid` 非空 ? 'up' : ''」—— 因为该字段引入前，唯一来源就是 UP 订阅。
   */
  sourceKind?: string;
  /**
   * 这个歌单是否启用了「按名称排序」规则。
   *
   * 可选字段（老数据读出来是 undefined = false），语义不是「当前看起来有序」而是
   * **「今后新增的条目也按名称插入」**。区分这两者必须有持久化标记：
   * 只看 `tracks` 现状无法判断它是排过的还是碰巧看着整齐，
   * 而用户的要求是「存量数据不管，只对以后排序过的歌单生效」。
   *
   * 由歌单页顶栏「一键排全部」置起，用户可再对单个歌单取消（见 LibraryStore）。
   */
  titleSorted?: boolean;
}

/** 删除墓碑：云同步时区分「此端删除」与「从未有过」 */
export interface Tombstone {
  id: string;
  deletedAt: string;
}

/** 底部导航布局取值（AppSettings.barLayout）：水平融合 —— 播放栏与页签同一行（HdsBarLayoutMode.HORIZONTAL，6.1.1(24)+ 设备生效） */
export const BAR_LAYOUT_HORIZONTAL: string = 'horizontal';
/** 底部导航布局取值（AppSettings.barLayout）：垂直两层 —— 播放栏在上、页签在下（HdsBarLayoutMode.VERTICAL；API 23 设备的默认布局） */
export const BAR_LAYOUT_VERTICAL: string = 'vertical';

/** 播放页进度条样式（AppSettings.progressStyle）：经典 —— 现有系统 Slider（默认，交互零回归） */
export const PROGRESS_STYLE_CLASSIC: string = 'classic';
/** 播放页进度条样式（AppSettings.progressStyle）：流光渐变条 —— 已播段渐变流光扫动 + 拖拽增厚 + 呼吸光晕 */
export const PROGRESS_STYLE_SHIMMER: string = 'shimmer';
/** 播放页进度条样式（AppSettings.progressStyle）：脉冲波点 —— 进度头圆点双层脉冲波纹 + 落位涟漪 + 待机呼吸 */
export const PROGRESS_STYLE_PULSE: string = 'pulse';
/** 播放页进度条样式（AppSettings.progressStyle）：律动频谱条 —— 曲目 id 播种的伪随机竖条 + 头部律动 + 落位亮波 */
export const PROGRESS_STYLE_WAVE: string = 'wave';

/** 播放页收起动画风格（AppSettings.closeAnimStyle）：柔退 —— 内容层反向错峰淡出 + 背景末端渐隐 + 封面 geometryTransition 回飞（打开侧 morph 不变） */
export const PLAYER_CLOSE_STYLE_MORPH: string = 'morph';
/** 播放页收起动画风格（AppSettings.closeAnimStyle）：柔退+手势 —— 柔退基础上，手机 SM 形态非竖滚区域支持竖向下拉跟手收起（松手过阈值下滑淡出，不足回弹） */
export const PLAYER_CLOSE_STYLE_MORPH_SWIPE: string = 'morph_swipe';
/** 播放页收起动画风格（AppSettings.closeAnimStyle）：下滑收起 —— 所有收起入口整页加速下滑淡出（松手/按键同款），放弃封面 morph 飞行 */
export const PLAYER_CLOSE_STYLE_SLIDE: string = 'slide';

/** 播放页封面风格（AppSettings.playerCoverStyle）：唱片 —— 圆形封面 + 20s/圈旋转（现状默认） */
export const PLAYER_COVER_STYLE_DISC: string = 'disc';
/** 播放页封面风格（AppSettings.playerCoverStyle）：方卡极简 —— 方形圆角大封面不旋转 + 主色净底渐变背景（无模糊图无噪点） */
export const PLAYER_COVER_STYLE_SQUARE: string = 'square';
/** 播放页封面风格（AppSettings.playerCoverStyle）：全屏沉浸 —— 封面满屏宽、上沿顶到状态栏（无圆角无投影），封面底部渐变模糊 + 主色溶解过渡到下方主色纵向渐变背景（2026-10-24 改版，替代旧硬切；同日过渡动画改版：特效层随展开飞行渐显、收起先柔退渐隐再回飞，不再瞬间出现/消失） */
export const PLAYER_COVER_STYLE_IMMERSIVE: string = 'immersive';

export interface AppSettings {
  sidebarState: string; // 手机端固定为 'auto'
  playQuality: string;
  downloadQuality: string;
  downloadDir: string;
  autoPlay: boolean;
  /** 启动时自动播放：开启后应用冷启动时从上次播放的曲目/进度继续播放（默认关 —— 无交互不出声） */
  autoPlayOnStart: boolean;
  wifiOnlyDownload: boolean;
  /** 仅 WiFi 播放：开启后移动网络下不播放在线歌曲（本地已下载曲目不受限） */
  wifiOnlyPlay: boolean;
  themeMode: ThemeMode;
  /** 主题色 id（'pink'|'red'|'orange'|'yellow'|'green'|'cyan'|'blue'|'purple'，见 common/ThemeColors.ts） */
  themeColor: string;
  /** 底部导航布局：BAR_LAYOUT_HORIZONTAL（水平融合）/ BAR_LAYOUT_VERTICAL（垂直两层） */
  barLayout: string;
  /** 播放页进度条样式：PROGRESS_STYLE_CLASSIC（经典）/ SHIMMER（流光）/ PULSE（波点）/ WAVE（频谱） */
  progressStyle: string;
  /** 播放页收起动画风格：PLAYER_CLOSE_STYLE_MORPH（柔退）/ MORPH_SWIPE（柔退+手势）/ SLIDE（下滑） */
  closeAnimStyle: string;
  /** 播放页封面风格：PLAYER_COVER_STYLE_DISC（唱片）/ SQUARE（方卡）/ IMMERSIVE（全屏） */
  playerCoverStyle: string;
  /** 迷你播放栏进度指示显示开关（底部直线 + 收起态圆环；设置 → 外观；默认开） */
  miniBarProgress: boolean;
  /**
   * 迷你栏自动展开收起开关（设置 → 外观；默认开）：控制「屏幕上滑展开、
   * 下滑收起迷你栏」的全屏手势（Index 的 parallelGesture）。关闭后仅保留
   * 点按收起圆盘 / onExpandRequest 等显式交互，浏览列表的竖向滑动不再触发收放。
   */
  miniBarAutoExpand: boolean;
  /** 倍速播放总开关（设置 → 播放；默认关）：开启后播放页功能行出现倍速选择入口 */
  speedEnabled: boolean;
  /** 倍速值（档位见 PLAYBACK_SPEED_OPTIONS；开关关闭时由设置页归 1.0） */
  playbackSpeed: number;
  /** 与其他应用同时播放（设置 → 播放；默认关）：开启后激活 AudioSession（CONCURRENCY_MIX_WITH_OTHERS，与其他应用音频双向混音），关闭停用会话恢复默认焦点行为 */
  audioMixEnabled: boolean;
  /** 在 B 站打开原视频（设置 → 播放；默认开）：开启后播放页功能行出现跳转 B 站客户端入口 */
  openInBilibiliEnabled: boolean;
}

export const DEFAULT_APP_SETTINGS: AppSettings = {
  sidebarState: 'auto',
  playQuality: '高品质',
  downloadQuality: '高品质',
  downloadDir: '',
  autoPlay: true,
  autoPlayOnStart: false,
  wifiOnlyDownload: DEFAULT_WIFI_ONLY_DOWNLOAD,
  wifiOnlyPlay: false,
  themeMode: ThemeMode.SYSTEM,
  themeColor: 'pink',
  barLayout: BAR_LAYOUT_HORIZONTAL,
  progressStyle: PROGRESS_STYLE_CLASSIC,
  closeAnimStyle: PLAYER_CLOSE_STYLE_MORPH_SWIPE,
  playerCoverStyle: PLAYER_COVER_STYLE_DISC,
  miniBarProgress: true,
  miniBarAutoExpand: true,
  speedEnabled: false,
  playbackSpeed: 1.0,
  audioMixEnabled: false,
  openInBilibiliEnabled: true
};

/** 播放倍速档位（与 media.PlaybackSpeed 枚举成员一一对应） */
export const PLAYBACK_SPEED_OPTIONS: number[] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0];

/** 倍速显示标签：1 → "1.0x"，0.25 → "0.25x"，1.5 → "1.5x" */
export function speedLabelOf(v: number): string {
  return `${v % 1 === 0 ? v.toFixed(1) : String(v)}x`;
}

/** 播放页进度条样式显示标签（设置页后缀 / toast 用；未知值回落「经典」） */
export function progressStyleLabelOf(style: string): string {
  if (style === PROGRESS_STYLE_SHIMMER) {
    return '流光';
  }
  if (style === PROGRESS_STYLE_PULSE) {
    return '波点';
  }
  if (style === PROGRESS_STYLE_WAVE) {
    return '频谱';
  }
  return '经典';
}

/** 播放页收起动画风格显示标签（设置页后缀 / toast 用；未知值回落「柔退」） */
export function closeStyleLabelOf(style: string): string {
  if (style === PLAYER_CLOSE_STYLE_MORPH_SWIPE) {
    return '柔退+手势';
  }
  if (style === PLAYER_CLOSE_STYLE_SLIDE) {
    return '下滑';
  }
  return '柔退';
}

/** 播放页封面风格显示标签（设置页后缀 / toast 用；未知值回落「唱片」） */
export function coverStyleLabelOf(style: string): string {
  if (style === PLAYER_COVER_STYLE_SQUARE) {
    return '方卡';
  }
  if (style === PLAYER_COVER_STYLE_IMMERSIVE) {
    return '全屏';
  }
  return '唱片';
}

/** 逐字片段（卡拉 OK 高亮用） */
export interface LyricWord {
  text: string;
  /** 相对该行起始的偏移（ms） */
  offset: number;
  /** 持续时长（ms） */
  duration: number;
}

export interface LyricLine {
  /** 行起始时刻（秒）。静态歌词（无时间轴）也按 4s 均匀排布 */
  time: number;
  text: string;
  /** 翻译（无则空串；网易云 tlyric / QQ trans） */
  translation?: string;
  /** 罗马音（无则空串；只有网易云提供） */
  romaji?: string;
  /** 逐字时间轴（无则空数组） */
  words?: LyricWord[];
}

export interface LyricResult {
  lines: LyricLine[];
  synced: boolean;
  instrumental: boolean;
  trackName: string;
  artistName: string;
  sourceId: string;
  /** 命中的歌词源（LyricSourceApi.SOURCE_*；旧缓存无此字段） */
  source?: string;
  /** 是否带翻译轨 */
  hasTranslation?: boolean;
  /** 是否带逐字轨 */
  dynamic?: boolean;
}

export interface LyricCandidate {
  id: string;
  songId: string | number;
  mid: string;
  trackName: string;
  artistName: string;
  albumName: string;
  /** 时长（秒） */
  duration: number;
  image: string;
  /** 歌词源（netease / qq / oiapi） */
  source?: string;
  /** 源内 id（取歌词用；与 songId 同义但统一成字符串） */
  remoteId?: string;
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
  /**
   * 来源歌单 id / 歌单名（空串 = 不是从歌单整单下载来的）。
   *
   * 为什么要落库：整单下载的一堆任务在下载管理里必须**聚成一张歌单卡片**、
   * 展开才看到单曲（用户 2026-10-04 要求）。若只放内存，重启 App 后分组就没了。
   *
   * ⚠️ 这两列是本项目**第一次给 download_task 表加列**，所以 `RdbHelper` 里补了
   * 幂等迁移（`PRAGMA table_info` 查列 → 缺则 `ALTER TABLE ADD COLUMN`）——
   * 鸿蒙 RDB 的 `StoreConfig` 没有 version 字段、`RdbStore.version` 只读，
   * 指望不上自动升级，`CREATE TABLE IF NOT EXISTS` 对已存在的表也**不会补列**。
   */
  playlistId: string;
  playlistName: string;
  /**
   * 合集归属三件套（2026-10-08，多 P 视频下载的显式标记）：
   * - collectionTitle：展开前的原视频标题（用户视角的「合集名」）；
   * - partNo / partTotal：分 P 序号（1 起）与总 P 数。
   *
   * 为什么要落库：此前合集信息只隐式存活在「首个分P复用 base 标题」这一约定里，
   * 下载页分组靠 musicId 的 bvid 前缀反推——首 P 被删后组标题退化成分P名、
   * 单 P 视频与「删剩 1 条的多 P 合集」无法区分、分 P 序号更是无从展示（用户 2026-10-08
   * 要求合集条目与单视频条目做区分）。与 playlistId/playlistName 同一套「归属标记」范式，
   * RdbHelper 幂等迁移补列。单视频：collectionTitle 为空串、partNo/partTotal 为 0。
   */
  collectionTitle: string;
  partNo: number;
  partTotal: number;
}

// ===== B 站 API 原始结构（仅用于解析，字段按需保留） =====

export interface SearchResultItem {
  bvid: string;
  aid: number;
  title: string;
  author: string;
  /**
   * 投稿者 mid。**接口一直有返回**（2026-10-03 实测），只是旧类型声明漏了它，
   * 导致「进 UP 主主页」拿不到人。声明成可选：字段缺失时退化成空串，不影响整块列表。
   */
  mid?: number;
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
  /**
   * B 站「合集」（ugc_season，2026-10-22 补）：多个**独立视频**的集合。
   * 与多 P（pages，同一视频的分页）是两种形态：合集条目自带 bvid/cid，
   * 各自独立解析音源。无合集的视频该字段缺省（view 响应里无此键）。
   */
  ugc_season?: UgcSeason;
}

/** 合集条目的分 P 信息（episode.page，结构与 VideoPageInfo 同源的精简版） */
export interface SeasonEpisodePage {
  cid: number;
  part: string;
  duration: number;
}

/** 合集条目：一个独立投稿视频（arc 里的字段摊平，只取构建 Track 需要的） */
export interface SeasonEpisode {
  bvid: string;
  aid: number;
  cid: number;
  title: string;
  /** 视频封面（arc.pic，可能是 http，使用前转 https） */
  pic?: string;
  /** 视频时长（秒，arc.duration） */
  duration?: number;
  author?: VideoOwner;
  page?: SeasonEpisodePage;
}

export interface UgcSeasonSection {
  episodes: SeasonEpisode[];
}

/** B 站「合集」（ugc_season）：标题 / 封面 / 分 section 的条目列表（多数只有一个 section） */
export interface UgcSeason {
  id: number;
  title: string;
  cover?: string;
  sections?: UgcSeasonSection[];
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

/** 杜比音轨容器：B 站把杜比全景声放在 dash.dolby.audio，不混入 dash.audio */
export interface DolbyData {
  audio: AudioStream[];
}

/**
 * Hi-Res FLAC 容器（2026-10-08 对照 bilibili-API-collect 修正）：`dash.flac = { display, audio }`。
 * 音轨本体在 **flac.audio（单对象，不是数组、也不直接挂在 flac 上）**；无无损音轨或账号
 * 无权限时整个 flac 为 null（audio 亦可为 null）—— 使用处一律真值判断。
 * audio 对象结构与 dash.audio 条目相同（id=30251、baseUrl、bandwidth…）。
 */
export interface FlacStream {
  /** 是否在播放器显示「Hi-Res 无损」切换按钮 */
  display: boolean;
  /** Hi-Res 音轨本体；缺失 / 无权限时为 null */
  audio?: AudioStream;
}

export interface DashData {
  audio: AudioStream[];
  video: AudioStream[];
  /** 杜比全景声档（30250）。仅 fnval 含对应位且登录态下服务端才下发，可为空。 */
  dolby?: DolbyData;
  /** Hi-Res 无损 FLAC 档（30251）。仅 fnval 含对应位且登录态下服务端才下发，可为空。 */
  flac?: FlacStream;
}

/**
 * durl 形态的播放流条目（老视频 / 服务端把 fnval 降级时的**唯一的**兜底）。
 *
 * 这一类响应**完全没有 dash 字段**：整段 mp4（音视频合一）以分段地址给出。
 * 对只看音轨的播放器来说它照样能出声 —— 视频轨白白解码，但没有更好选择：
 * 不接这条兜底，这类视频的表现就是「点哪首都播不出来」（2026-10-22 补，对齐 BBPlayer）。
 */
export interface DurlItem {
  /** 分段序号，从 1 开始 */
  order: number;
  /**
   * 该分段时长，**单位毫秒**（2026-10-22 实测：BV1GJ411x7h7 返回 212394，
   * 对应 3 分 32 秒的视频里的一段）。用它算码率必须先 /1000。
   */
  length: number;
  /** 该分段字节数 */
  size: number;
  url: string;
  backup_url?: string[];
}

export interface PlayUrlData {
  quality: number;
  format: string;
  /** 正常响应必有；**降级到 durl 形态时整体缺失**，使用处必须判空 */
  dash?: DashData;
  /** 老视频 / 降级响应的分段流；与 dash 互斥（dash 缺失时才有值） */
  durl?: DurlItem[];
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
  /** 备用直链（dash.audio[].backupUrl 取前 3 条）：主直链挂死/被拒时的快速回退。 */
  audioBackupUrls: string[];
  audioQuality: number;
  audioMimeType: string;
  /** 所选音轨的实测带宽（bps）。见 DownloadTask.audioBandwidth 的说明。 */
  audioBandwidth: number;
}

