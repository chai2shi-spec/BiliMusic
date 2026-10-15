/**
 * 全局常量：API 端点、数据库、偏好键、AppStorage 键。
 */

export const BILI_API: string = 'https://api.bilibili.com';
export const BILI_REFERER: string = 'https://www.bilibili.com';
/** B 站账号体系（passport）：扫码登录的生成 / 轮询 / 登出接口都在这个域 */
export const BILI_PASSPORT: string = 'https://passport.bilibili.com';
/**
 * B 站 App（iPhone 版）UA —— passport 登录链路专用（对齐 BBPlayer 的 PASSPORT_UA）。
 *
 * B 站按 UA 分流登录 Cookie 的下发方式（2026-10-07 日志确证）：
 *   · web UA（PC Chrome）：poll 成功走 crossDomain ticket 网页流程，登录 Cookie
 *     在 302 重定向中间跳的 Set-Cookie 里（ohos http 自动跟随重定向会把它吞掉）；
 *   · BiliApp UA：登录 Cookie 直接在 poll 响应的 Set-Cookie 里下发，无需跟进跳转。
 * 扫码生成/轮询、短信登录三接口都必须带这个 UA；其余接口（搜索等）仍用 PC UA
 * （搜索接口对「移动端 UA + buvid」组合有静默风控，见 HttpUtil.userAgent 注释）。
 */
export const BILI_APP_UA: string =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 14_0_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 BiliApp/6.66.0';
export const OIAPI_QQ_LYRIC: string = 'https://www.oiapi.net/api/QQMusicLyric';

export const DB_NAME: string = 'bilimusic_rdb.db';/**
 * ⚠️ 这个版本号**目前不生效**，别指望它触发迁移。
 *
 * 鸿蒙 RDB 的 `StoreConfig` 没有 version 字段、`RdbStore.version` 是只读属性
 * （SDK `relationalStore.d.ts:3813`），没有版本升级钩子；而且
 * `CREATE TABLE IF NOT EXISTS` 对已存在的表什么都不会做。
 * 所以表结构变化一律走 `RdbHelper.ensureColumns()` 的幂等补列
 * （`PRAGMA table_info` 查列 → 缺则 `ALTER TABLE ADD COLUMN`）。
 * 加列时**同步把这个数字 +1**，留个「结构到哪一版了」的可读标记。
 */
export const DB_VERSION: number = 2;
export const TABLE_DOWNLOAD: string = 'download_task';

/**
 * 新建歌单时的**通用**默认名。
 *
 * 注意：「新建歌单并加入」**不用**它 —— 那种场景的名字取自条目歌名，
 * 规则见 `LibraryStore.nextPlaylistNameForTrack`。这里只服务于
 * 「保存合集时用户把名字清空了」这一种兜底。
 */
export const DEFAULT_PLAYLIST_NAME: string = '我的歌单';

/**
 * 沉浸光感参数（底栏胶囊与顶栏共用，取值来自 Sumy 的 getBarFloatingStyle）。
 *
 * 提到这里是因为**两处必须同源**：底栏胶囊走 HDS 的 `lightColor`，顶栏走
 * `GlassTopBar` 的光晕层。两边各写一份魔数的话，改一次强度只改一处，
 * 就会出现「底栏泛粉、顶栏泛灰」的不一致。
 */
/** 主题色光晕透明度（HDS 侧对应 `lightColor: withAlpha(themePrimary, 0.12)`） */
export const GLOW_ALPHA: number = 0.12;
/** 品牌粉的 RGB 部分（颜色资源里是 #FFFB7299），用来拼带 alpha 的光晕色 */
export const BILI_PINK_HEX: string = '#FB7299';

/**
 * 主题色（8 色切换，调色板与发布入口见 common/ThemeColors.ts）。
 * 鸿蒙颜色资源不支持运行时替换，走 AppStorage 发布 hex 字符串 +
 * 组件 @StorageProp 订阅。STORE_THEME_COLOR 存主题 id（设置页回显当前色名），
 * 其余四个存**已按深浅解析**的最终 hex —— 消费组件不需要再关心深浅。
 */
export const STORE_THEME_COLOR: string = 'themeColor';
export const STORE_THEME_PRIMARY: string = 'themePrimary';
export const STORE_THEME_DEEP: string = 'themeDeep';
export const STORE_THEME_SURFACE: string = 'themeSurface';
export const STORE_THEME_ON: string = 'themeOn';

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
/**
 * 扫码登录 Cookie 串（SESSDATA=...; bili_jct=...; DedeUserID=...; DedeUserID__ckMd5=...）。
 * 由 LoginStore 在扫码成功时解析写入，启动时重新装填进 HttpUtil。
 */
export const PREF_LOGIN_COOKIE: string = 'bilimusic_login_cookie';
/** 登录用户信息 JSON（mid / uname / face / vipStatus，见 service/LoginStore.ts 的 LoginUser） */
export const PREF_LOGIN_USER: string = 'bilimusic_login_user';
/**
 * 登录撤销令牌（refresh_token）：passport 轮询成功时随 Cookie 一并下发。
 *
 * ⚠️ 2026-10-08 记录：目前**存了但从没用过** —— 全仓没有 `getLoginRefreshToken()`
 * 的调用方，也没有续期接口。B 站完整的续期链路是 5 步（含 RSA-OAEP 加密换
 * correspondPath + 解析 HTML 拿 refresh_csrf），工程量约等于一个完整功能，
 * 尚未开工。当前登录态完全依赖 SESSDATA 自然过期。
 * 别把这个键当成「已实现续期」的证据。
 */
export const PREF_LOGIN_REFRESH_TOKEN: string = 'bilimusic_login_refresh_token';
/**
 * 最近一次「登录态被服务端确认有效」的时间戳（ms，字符串存）。
 *
 * 用途（2026-10-08 配合消除静默降级）：nav 接口返回 -101 时，**不再直接清掉
 * 登录凭据**，而是把它归零并保留 Cookie ——凭据可能被风控临时拒绝，也可能只是
 * 网络抖动。设置页据此显示「登录已失效 · 点击重新登录」而不是悄悄变回未登录
 * （原实现直接 clearLoginState，用户完全不知情，refresh_token 也一并丢了）。
 *
 * 0 = 从未被确认过，或已被服务端拒绝过一次（即「待重新验证」态）。
 * 注意：`PREF_VALUE_BUDGET_BYTES` 与 8192 上限只约束 value 大小，这里存十位数毫秒，无风险。
 */
export const PREF_LOGIN_VERIFIED_AT: string = 'bilimusic_login_verified_at';

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
 * miniBar 槽位几何动画相位（收起 / 展开时 HDS 对槽位宽高的形变动画进度）。
 * 由 Index 的 onMiniBarAnimationStart / onMiniBarAnimationEnd 写入，PlayBar 只读订阅：
 * 动画期间整行内容保持挂载（enableMiniBarClip 裁出自然的收放揭示），圆盘尺寸
 * 与槽位同步过渡 —— 消除「内容在动画中途瞬切」的跳动错位。
 */
export const STORE_MINI_BAR_ANIM_PHASE: string = 'miniBarAnimPhase';
/** 空闲（无槽位动画，或动画刚结束）：内容按展开态正常切换 */
export const MINI_BAR_ANIM_IDLE: number = 0;
/** 槽位动画中，目标 = 展开（圆盘 → 整行） */
export const MINI_BAR_ANIM_TO_EXPAND: number = 1;
/** 槽位动画中，目标 = 收起（整行 → 圆盘） */
export const MINI_BAR_ANIM_TO_COLLAPSE: number = 2;

/**
 * 悬浮底栏布局模式（AppSettings.barLayout 的运行时镜像，取值见 MusicModels 的
 * BAR_LAYOUT_* 常量）：EntryAbility 启动首发、设置页切换时重发，Index @StorageProp
 * 订阅 → barFloatingStyle 受控重建 → HdsTabs.barLayoutMode 即时切换。
 */
export const STORE_BAR_LAYOUT: string = 'barLayoutMode';

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
 * 下载页顶栏状态镜像键（HdsNavigation 迁移批 4，顶栏迁根容器后的状态通道）。
 * 下载页顶栏内容（选择按钮 + 工具条）依赖页内状态，迁到根 HdsNavigation
 * titleBar 后无法直接读页面 @State —— 由 DownloadsPage 把派生状态推到
 * AppStorage，根栏侧组件（components/DownloadsTabBar.ets）@StorageProp 订阅。
 * 页面侧唯一写入口：DownloadsPage.syncBarState / refreshQueueFlags。
 */
export const STORE_DL_BAR_SELECTING: string = 'dlBarSelecting';
export const STORE_DL_BAR_HAS_TASKS: string = 'dlBarHasTasks';
export const STORE_DL_BAR_SELECTED_COUNT: string = 'dlBarSelectedCount';
export const STORE_DL_BAR_ALL_SELECTED: string = 'dlBarAllSelected';
export const STORE_DL_BAR_CAN_RETRY: string = 'dlBarCanRetry';
export const STORE_DL_BAR_QUEUE_ACTIVE: string = 'dlBarQueueHasActive';
export const STORE_DL_BAR_QUEUE_PAUSED: string = 'dlBarQueueHasPaused';

/**
 * 歌单页顶栏状态镜像键（批 4，机制同 STORE_DL_BAR_*：顶栏迁根容器后的状态通道）。
 * 页面侧唯一写入口：PlaylistsPage.syncBarState；
 * 栏内组件 components/PlaylistsTabBar.ets（PlTitleActions / PlSelectToolbar）
 * @StorageProp 订阅。
 * 2026-10-10 歌单页 HDS 适配：bottomBuilder 第二行退役（多选工具条迁页面层、
 * 最近播放入口迁设置页），RECENT_COUNT / BOTTOM_HEIGHT 两键随之删除。
 */
export const STORE_PL_BAR_SELECTING: string = 'plBarSelecting';
export const STORE_PL_BAR_CAN_SELECT: string = 'plBarCanSelect';
export const STORE_PL_BAR_SELECTED_COUNT: string = 'plBarSelectedCount';
export const STORE_PL_BAR_ALL_SELECTED: string = 'plBarAllSelected';

/**
 * 搜索页顶栏状态键（批 4，机制同 STORE_DL_BAR_* / STORE_PL_BAR_*）。
 * 与前两页不同：搜索框 / 类型滑块 / 内容页签行**本身就在根栏里**，所以
 * keyword / searchKind / tab 是页面与根栏组件共享的**双向**状态
 * （两侧都 @StorageLink，任一侧写入另一侧即见）；页签行高度键由根栏组件
 * onAreaChange 实测回写，页面读它组让位量（safeTop + 56 + 实测值）
 * 与历史面板定位。
 */
export const STORE_SEARCH_KEYWORD: string = 'searchKeyword';
export const STORE_SEARCH_KIND: string = 'searchKind';
export const STORE_SEARCH_TAB: string = 'searchTab';
export const STORE_SEARCH_TABS_HEIGHT: string = 'searchTabsHeight';

/**
 * 当前活动页签下标（number，写入方 Index 的受控 HdsTabs）。
 * 2026-10-08 卡顿优化：Tabs 的 TabContent 是常驻的，下载页在非活动页签时
 * 依然接收下载快照、全量重分组 —— 切到别的 Tab 下载中照样拖慢整个 UI。
 * Index 把 activeTab 挂到 AppStorage（@StorageLink 写穿），下载页据此门控：
 * 非本 Tab 跳过重算只置脏标记，切回时补算一次（见 DownloadsPage.onTabChanged）。
 */
export const STORE_ACTIVE_TAB: string = 'activeTab';

/**
 * 手势指示条避让区高度的预估上限（vp）。
 * 手势导航的指示条区域一般在 24~34vp；超过它（约 48vp+）就是三键导航栏 ——
 * 那是一整条可点击的系统控件，必须完整避让，不能像手势条那样只避开一半。
 * 融合胶囊底栏（Index.barFloatingStyle 的 barBottomMargin 折算公式）消费。
 */
export const GESTURE_INDICATOR_MAX_VP: number = 36;

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
 * 登录态版本号：登录 / 退出 / 用户信息更新时递增（写入方：service/LoginStore.ts）。
 * 设置页是 Tabs 常驻页，aboutToAppear 只触发一次，扫码登录返回后必须靠这个信号
 * 刷新「账户」分组 —— 与 STORE_LIBRARY_REV 同一套版本号驱动 @Watch 的模式。
 */
export const STORE_LOGIN_REV: string = 'loginRev';

/**
 * 「一次显式登录动作刚刚成功」的一次性事件信号（值形如 `{ mid, ts }`）。
 *
 * ⚠️ 为什么不复用 STORE_LOGIN_REV：登录成功时它会被递增**多次**
 * （persistLoginCookie 一次 + refreshLoginUser 的用户信息变化再一次），
 * 拿它当「登录完成」触发器会重复触发；且冷启动时 refreshLoginUser 的变更
 * 也会递增它 —— 那属于「恢复会话」，不该触发自动同步。
 *
 * 写入（唯一）：service/LoginStore.ts 的 persistLoginCookie（扫码 / 短信登录成功共用）。
 * 消费：pages/Index.ets 的 @Watch → 触发收藏夹自动同步一次。
 */
export const STORE_LOGIN_EVENT: string = 'loginEvent';

/**
 * 收藏夹同步版本号：每轮同步结束（成功/部分成功/失败）递增。
 * 写入：service/FavSyncManager.ts；消费：同步页 @StorageLink + @Watch 刷新状态。
 */
export const STORE_FAV_SYNC_REV: string = 'favSyncRev';

/**
 * 收藏夹同步状态（`FavFolderSyncState[]`，见 service/FavSyncStore.ts）。
 * 体量很小（每夹约 150 字节），直接走单 key，无需分片。
 */
export const PREF_FAV_SYNC_STATE: string = 'bilimusic_fav_sync_state';

/**
 * 收藏夹**待推送队列**分片前缀（`FavPushOp[]`，见 service/FavPushStore.ts）。
 *
 * 与 `PREF_FAV_SYNC_STATE` 不同，这份是「逐条待执行的写操作」，体量随用户离线操作增长
 * （一条约 120 字节，离线狂删上百条即 >12KB，超 Preferences 单值 8192 字节硬上限）
 * → **必须分片**，key 形如 `bilimusic_fav_push_queue_0 / _1 / …`。
 */
export const PREF_FAV_PUSH_QUEUE: string = 'bilimusic_fav_push_queue_';

/**
 * 网络恢复重试信号（版本号，每次真正「断过又恢复」时递增）。
 * 写入：Index 根页的网络监听（watchNetwork）在 netAvailable 且此前断过网时 +1；
 * 消费：搜索页 @StorageProp + @Watch，收到信号且当前页签处于失败/空态时自动重试。
 * 刻意做成版本号而不是布尔：相同值不触发 @Watch，翻转布尔可能丢信号。
 */
export const STORE_NET_RETRY_REV: string = 'netRetryRev';

/**
 * 系统避让区尺寸（vp）。窗口开启全屏布局（EntryAbility 里 setWindowLayoutFullScreen(true)）后，
 * 页面不再自动避让系统栏，这两个值就是**唯一的避让依据**：
 *   写入：EntryAbility 首帧前同步首发一次（避免内容先贴边再弹回来），
 *         pages/Index.ets 的 aboutToAppear 再主动读一次并注册 avoidAreaChange 动态更新。
 *   消费：**分散给真正需要避让的控件与页面**，各消费一次、互不重叠 ——
 *         STORE_SAFE_BOTTOM → HdsTabs 悬浮页签栏的 barBottomMargin（20 + 安全区）、
 *                             迷你播放条 padding-bottom、各 Tab 列表 contentEndOffset、
 *                             子页内容层 plain padding（AboutPage 末尾留白等；子页沉浸
 *                             由目的地链 .ignoreLayoutSafeArea 声明，见各页注释）；
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
//   匿名状态下对照 fnval=16 与 fnval=4048：返回的档位完全一致，**提高 fnval 拿不到更多档**
//   —— 该结论**仅限匿名**（2026-10-08 修正）：登录（大会员）后 fnval=4048 才会额外下发
//   杜比全景声（dash.dolby.audio）与 Hi-Res 无损（dash.flac），这两个字段不在 dash.audio 里，
//   需由 BilibiliApi.collectAudioStreams 合并进候选（修「登录后音质选项不生效」的根因之一）。
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

/**
 * 「档位 + 实测码率」合成一行展示文案（2026-10-08）。
 *
 * 抽成公共函数的原因：下载页（`DownloadsPage.qualityText`）与播放页
 * （`MusicInfoComponent.qualityText`）要显示同一首歌时**必须给出一致的文案**，
 * 两处各写一遍迟早漂移。
 *
 * 规则（优先级从高到低）：
 *  1. 有实测带宽 → 只显示实测码率。这是**唯一可信**的数值：低码率源会被 B 站
 *     挂上 30280「192K」的档位标签，只显示标签就是在骗用户（见 AUDIO_QUALITY_LABEL 注释）。
 *  2. 无实测但有档位 → 落回档位标签（此时没有更好的信息）。
 *  3. 都没有 → 空串，调用方应整行不渲染。
 *
 * @param quality 档位 id（Track.audioQuality / DownloadTask.audioQuality），0 = 无
 * @param bandwidth 实测带宽 bps（*.audioBandwidth），0 = 无
 */
export function formatTrackQuality(quality: number, bandwidth: number): string {
  if (bandwidth > 0) {
    return formatAudioBitrate(bandwidth);
  }
  if (quality > 0) {
    return AUDIO_QUALITY_LABEL[quality] || '';
  }
  return '';
}

// ===== 最近播放续播阈值（位置记忆）=====
//
// ⚠️ 必须放本文件（.ts）而不是 InteractionConstants.ets（.ets）：
// 消费方 MusicPlayer.ts 是 .ts 文件，而 .ts 禁止 import .ets（会编译失败）；
// RecentPage.ets 反方向 import .ts 则完全合法。两端共享、各写一份迟早漂移。
/**
 * 最近播放条目记忆上次播放位置（Track.lastPosSec），点击单条时按这两个阈值
 * 决定是否续播（MusicPlayer.playRecentFromHistory）与是否显示
 * 「上次听到 x:xx」（RecentPage.heardTextOf）—— 判定逻辑必须两端一致。
 */
/** 续播的最小已听位置（秒）：低于它视为没听过，从头播 */
export const RESUME_MIN_SEC: number = 5;
/** 续播的距结尾安全距离（秒）：距结尾小于它视为已听完，从头播 */
export const RESUME_TAIL_SEC: number = 10;
