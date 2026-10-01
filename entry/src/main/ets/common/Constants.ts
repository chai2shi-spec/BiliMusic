/**
 * 全局常量：API 端点、数据库、偏好键、AppStorage 键。
 */

export const BILI_API: string = 'https://api.bilibili.com';
export const BILI_REFERER: string = 'https://www.bilibili.com';
export const OIAPI_QQ_LYRIC: string = 'https://www.oiapi.net/api/QQMusicLyric';

/** 应用包名：必须与 AppScope/app.json5 的 bundleName 保持一致（改包名时两处一起改） */
export const APP_BUNDLE: string = 'com.chai.bilimusic';
export const APP_NAME: string = 'BiliMusic';

export const DB_NAME: string = 'bilimusic_rdb.db';
export const DB_VERSION: number = 1;
export const TABLE_DOWNLOAD: string = 'download_task';

export const PREF_SETTINGS: string = 'bilimusic_settings';
export const PREF_RECENT: string = 'bilimusic_recent';
export const PREF_FAVORITES: string = 'bilimusic_favorites';
export const PREF_PLAYLISTS: string = 'bilimusic_playlists';
export const PREF_PLAYLIST_TOMBSTONES: string = 'bilimusic_playlists_deleted';
export const PREF_FAVORITE_TOMBSTONES: string = 'bilimusic_favorites_deleted';
export const PREF_PLAYER_STATE: string = 'bilimusic_player_state';
export const PREF_TOTAL_LISTEN_SECONDS: string = 'bilimusic_total_listen_seconds';
/** 搜索历史：JSON 字符串数组，最近搜索的在前，最多 20 条（见 service/SearchHistoryStore.ts） */
export const PREF_SEARCH_HISTORY: string = 'bilimusic_search_history';
export const PREF_BUVID: string = 'bilimusic_buvid';
/** 持久化后的 buvid Cookie 串（buvid3=...; buvid4=...） */
export const PREF_BUVID_COOKIE: string = 'bilimusic_buvid_cookie';

export const STORE_CURRENT_TRACK: string = 'currentTrack';
export const STORE_IS_PLAYING: string = 'isPlaying';
export const STORE_PROGRESS: string = 'progress';
export const STORE_DURATION: string = 'duration';
export const STORE_QUEUE: string = 'queue';
export const STORE_REPEAT_MODE: string = 'repeatMode';
export const STORE_SHUFFLE: string = 'isShuffled';
export const STORE_LOADING_AUDIO: string = 'loadingAudio';
export const STORE_VOLUME: string = 'volume';
export const STORE_MUTED: string = 'isMuted';

/**
 * 定时停止播放：到点时间戳（ms），0 / 未设置 = 关闭。
 *
 * 只发布**结束时刻**而不是剩余秒数 —— 剩余量由设置页用本地 1s 计时器现算，
 * 这样播放内核不必每秒往 AppStorage 写一次（那是 1 次/秒的重渲染）。
 * 播放内核负责到点暂停并把它清 0。
 */
export const STORE_SLEEP_TIMER_END: string = 'sleepTimerEnd';

// ===== 播放页共享元素转场（PlayBar ↔ PlayerPage 唱片一镜到底） =====
/** 共享元素 id：底栏小唱片与播放页大唱片必须一致（Navigation 场景用 geometryTransition） */
export const GEOMETRY_ID_PLAYER_DISC: string = 'player_cover';
/** 转场时长（ms），EaseInOut */
export const PLAYER_TRANSITION_MS: number = 300;
/** 转场进行中标志：转场期间两边唱片的旋转动画暂停，结束后恢复（跨组件走 AppStorage） */
export const STORE_PLAYER_TRANSITIONING: string = 'playerTransitioning';

/**
 * HDS 悬浮底栏融合播放栏（miniBar）当前是否展开（HdsBarStyle.EXPAND / COLLAPSE）。
 * 由 Index 的 onBarStyleChange 写入，PlayBar 只读订阅 —— HDS 会缓存 miniBarBuilder
 * 内容，展开 / 收起状态必须走全局存储才能驱动内容切换。
 */
export const STORE_MINI_BAR_EXPANDED: string = 'miniBarExpanded';

/**
 * 播放页沉浸背景是否偏暗（封面主色明度判断）。
 * 由 PlayerInfoComponent 取色后写入；TopAreaComponent（投播按钮图标黑白）、
 * 状态栏内容色按它切换。离开播放页时由 PlayerPage 复位为浅色状态栏。
 */
export const STORE_PLAYER_BG_DARK: string = 'playerBgDark';

/** 播放页折叠屏展开态（display.FoldDisplayMode.FOLD_DISPLAY_MODE_FULL），供左右分栏布局消费。 */
export const STORE_PLAYER_FOLD_FULL: string = 'playerFoldFull';

/** 下载任务快照（DownloadTask[]）。由 DownloadManager 推送，下载页 @StorageLink 订阅。 */
export const STORE_DOWNLOAD_TASKS: string = 'downloadTasks';

/**
 * 下载队列是否处于「全部暂停」（boolean）。
 * 单个任务的 PAUSED 状态只描述「它自己停下了」，而队列级暂停还包含
 * 「一大批任务仍是 PENDING 但不会被消费」这个信息，页面需要它来显示「已暂停」提示。
 */
export const STORE_DOWNLOAD_PAUSED: string = 'downloadPaused';

/**
 * 全局轻提示通道（AppToast）。任何代码（含拿不到 UIContext 的播放内核）
 * 写这三个键即可弹 Toast；Index 根部挂载的 AppToast 组件订阅并接管显隐与计时。
 * seq 必须读-改-写递增（统一从 AppStorage 取当前值），两处写入方各持独立计数器
 * 会撞号 —— 相同值不触发 @Watch，提示就丢了。
 */
export const STORE_TOAST_MSG: string = 'toastMsg';
export const STORE_TOAST_HOLD_MS: string = 'toastHoldMs';
export const STORE_TOAST_SEQ: string = 'toastSeq';

/**
 * 媒体库（歌单 / 收藏 / 最近）版本号，每次写操作递增。
 * 歌单页在 Tabs 里是常驻的、aboutToAppear 只在首次触发，
 * 「搜索页加入歌单后切回歌单页」「详情页改完返回列表页」都读不到新数据，
 * 必须靠这个信号驱动刷新。
 */
export const STORE_LIBRARY_REV: string = 'libraryRev';

/**
 * 系统避让区尺寸（vp）。窗口开启全屏布局（EntryAbility 里 setWindowLayoutFullScreen(true)）后，
 * 页面不再自动避让系统栏，这两个值就是**唯一的避让依据**：
 *   写入：EntryAbility 首帧前同步首发一次（避免内容先贴边再弹回来），
 *         pages/Index.ets 的 aboutToAppear 再主动读一次并注册 avoidAreaChange 动态更新。
 *   消费：**分散给真正需要避让的控件与页面**，各消费一次、互不重叠 ——
 *         STORE_SAFE_BOTTOM → HdsTabs 悬浮页签栏的 barBottomMargin（20 + 安全区）、
 *                             迷你播放条 padding-bottom、各 Tab 列表 contentEndOffset、
 *                             NavDestination 子页 safeAreaPadding(bottom)；
 *         STORE_SAFE_TOP    → 页签层 Stack 的 padding-top、各 NavDestination 子页的
 *                             `padding({ top })`（标题栏整体落在状态栏下方）。
 *
 * ⚠️ 底部避让**不能加在首页根容器上**：根容器 padding 会把 Tabs 内容区整体截短，
 * 首页（搜索页）的列表就铺不到屏幕最底，与「布局区域延伸到底部手势条下方」矛盾。
 * 页面里也不要用 expandSafeArea（与窗口全屏方案互斥）。
 */
export const STORE_SAFE_TOP: string = 'safeAreaTop';
export const STORE_SAFE_BOTTOM: string = 'safeAreaBottom';

/**
 * 各 Tab 列表末尾的固定让位高度（vp）：避开**悬浮**页签栏与全局底部播放栏。
 * 底栏换成 HdsTabs 沉浸光感悬浮胶囊后，胶囊自己还带 20vp 的离底间距，
 * 所以让位从原来的 140 抬到 160：
 *   离底 20 + 胶囊高 56 + 与底栏间距 8 + 底栏高 56 = 140，再留 20 余量。
 *
 * 实际使用时还要加上 STORE_SAFE_BOTTOM：Tabs 内容区铺满整屏（不避让）之后，
 * 页签栏 / 底栏各自抬高了「底部安全区高度」，列表末尾不多让这么多，
 * 最后一项就会被它们压住。
 */
export const CONTENT_END_OFFSET: number = 160;

//
// 音频档位由服务端决定，客户端只能「在已有档位里挑」。线上实测（2026-09-28，匿名 + PC UA）：
//   热门投稿 8/8 都真实给出三档，30280 的 bandwidth 实测 176k~216k，是真的 192K；
//   但**部分投稿（如音乐中心的承载视频）三个档位的 bandwidth 全在 66k 上下**
//   —— 那是 B 站侧只有一份低码率音源，三个 id 指向同一份数据，选哪档文件都一样大。
//   同时对照过 fnval=16 与 fnval=4048：返回的档位完全一致，**提高 fnval 拿不到更多档**。
// 所以「下载音质」能控制的是「选哪一档」，控制不了「服务端有没有那一档」；
// 界面上必须回显**实际拿到的码率**，否则用户会把内容侧的低码率误判成 App 的 bug。
export const AUDIO_Q_64K: number = 30216;
export const AUDIO_Q_132K: number = 30232;
export const AUDIO_Q_192K: number = 30280;
export const AUDIO_Q_DOLBY: number = 30250;
export const AUDIO_Q_HIRES: number = 30251;

/** 音频档位 id → 展示文案（带宽字段不可信时用它做兜底落回） */
export const AUDIO_QUALITY_LABEL: Record<number, string> = {
  30216: '64kbps',
  30232: '132kbps',
  30280: '192kbps',
  30250: '杜比全景声',
  30251: 'Hi-Res 无损'
};

/**
 * 实测码率（bps）→ 展示文案。
 *
 * ⚠️ 优先用 `bandwidth` 而不是档位标签：低码率源会给 30280 这个「192K」标签配上
 * 只有 66k 的实测带宽，直接显示标签就是在骗用户。实测值与标称值差太多时以实测为准。
 */
export function formatAudioBitrate(bandwidth: number): string {
  if (!(bandwidth > 0)) {
    return '';
  }
  const kbps: number = bandwidth / 1000;
  return kbps >= 1000 ? `${(kbps / 1000).toFixed(1)} Mbps` : `${Math.round(kbps)} kbps`;
}
