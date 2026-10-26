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
 * B 站按 UA 分流登录 Cookie 的下发方式：
 *   · web UA（PC Chrome）：poll 成功走 crossDomain ticket 网页流程，登录 Cookie
 *     在 302 重定向中间跳的 Set-Cookie 里（ohos http 自动跟随重定向会把它吞掉）；
 *   · BiliApp UA：登录 Cookie 直接在 poll 响应的 Set-Cookie 里下发，无需跟进跳转。
 * 扫码生成/轮询、短信登录三接口都必须带这个 UA；其余接口（搜索等）仍用 PC UA
 * （搜索接口对「移动端 UA + buvid」组合有静默风控，见 HttpUtil.userAgent 注释）。
 */
export const BILI_APP_UA: string =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 14_0_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 BiliApp/6.66.0';

/**
 * ══════════ B 站 APP 签名域（appkey / appsec）══════════
 *
 * 与 Web 域的 WBI 签名**互不相干**的两套体系（算法见 utils/AppSign.ts）。
 * 当前唯一用途：TV 端取流端点 `/x/tv/playurl` —— 它走 APP 签名，
 * 风控策略与 Web playurl 不同，用作取流链路的最后一级兜底
 * （Web 侧被 -352 拦死时，这条路往往还能拿到流）。
 *
 * ⚠️ 这两个值是公开的客户端固定凭据（所有第三方客户端共用），不是本项目密钥。
 */
export const BILI_APP_KEY: string = 'dfca71928277209b';
export const BILI_APP_SEC: string = 'b5475a8825547a4fc26c7d518eaaa02e';
/**
 * TV 端取流的 UA：必须带 `BiliDroid` 标记。实测去掉它后
 * `/x/tv/playurl` 返回 -400（服务端按 UA 判定客户端身份，签名对了也白搭）。
 */
export const BILI_TV_UA: string =
  'Mozilla/5.0 BiliDroid/7.38.0 (bbcallen@gmail.com) os/android';

/**
 * ══════════ B 站请求全局节流闸门（BiliRequestGate）══════════
 *
 * 登录态下「预取 + 播放 + 页面刷新」同刻并发形成请求尖峰，账号对尖峰
 * 敏感 —— 点歌链（view → playurl）频繁吃 -352/-412/-509/-799 / HTTP 412。
 * 闸门给所有 B 站域请求排全局队：节流 + 并发上限 + 播放链高优先插队 +
 * 风控码全局熔断冷却（阶梯升级、排队顺延不丢弃）。挂在 HttpUtil 三个
 * 请求入口，零调用点改动；歌词 API（OIAPI）等非 B 站域按 URL 放行。
 * 真机手感不佳只调这四个数，不动闸门逻辑。
 */
/** 相邻两次实际发送的最小间隔（ms）：150 ≈ 6-7 req/s 上限，削尖峰够用 */
export const BILI_GATE_MIN_INTERVAL_MS: number = 150;
/** 发送间隔的随机抖动上限（ms）：打散固定节奏，避免被识别为机器节拍 */
export const BILI_GATE_JITTER_MS: number = 80;
/** 同时在途 B 站请求上限：2 = 保住并行收益的同时不挤爆连接池 / 不触发突发判定 */
export const BILI_GATE_MAX_CONCURRENCY: number = 2;
/**
 * 名额占满时的重试退避（ms）：在途请求已满（弱网/后台恢复时单个请求
 * 可挂 15s）而队列还有等待者时，pump 用该间隔轮询而非 0ms 定时器 ——
 * libuv 的 uv__run_timers 会把同一轮里新加的 0ms 定时器无限循环处理，
 * 主线程永远回不到事件循环，直接 THREAD_BLOCK_6S 假死被杀（实测见
 * er/appfreeze-...20261026084545）。名额释放由 release() 主动唤醒，
 * 退避只是兜底，>MIN_INTERVAL 保证不拖慢正常节拍。
 */
export const BILI_GATE_FULL_BACKOFF_MS: number = 200;
/**
 * 风控熔断冷却阶梯（ms）：观测到风控信号（HTTP 412/403/429 或响应体
 * `{"code":-352/-412/-509/-799`）后全局暂停出队，连续命中逐级拉长，
 * 任一干净成功复位到第 0 档。排队请求顺延不丢弃。
 */
export const BILI_GATE_COOLDOWN_STEPS_MS: number[] = [2000, 5000, 12000];
export const OIAPI_QQ_LYRIC: string = 'https://www.oiapi.net/api/QQMusicLyric';

export const DB_NAME: string = 'bilimusic_rdb.db';
export const TABLE_DOWNLOAD: string = 'download_task';

/**
 * 桌面卡片 id 库（表 form_card）：Form 扩展进程与 UIAbility 进程双进程读写，
 * 独立于主库（Form 进程不触碰下载表初始化链路），SQLite 多连接安全。
 */
export const CARD_DB_NAME: string = 'bilimusic_card.db';

/**
 * 新建歌单时的**通用**默认名。
 *
 * 注意：「新建歌单并加入」**不用**它 —— 那种场景的名字取自条目歌名，
 * 规则见 `LibraryStore.nextPlaylistNameForTrack`。这里只服务于
 * 「保存合集时用户把名字清空了」这一种兜底。
 */
export const DEFAULT_PLAYLIST_NAME: string = '我的歌单';

/**
 * 沉浸光感参数（底栏悬浮胶囊用，取值来自 Sumy 的 getBarFloatingStyle）。
 * GLOW_ALPHA 对应 HDS `lightColor` 的主题色光晕 alpha，集中定义避免魔数漂移。
 */
/** 主题色光晕透明度（HDS 侧对应 `lightColor: withAlpha(themePrimary, 0.12)`） */
export const GLOW_ALPHA: number = 0.12;

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
/** 常用搜索词：JSON 字符串数组，搜索初始页快捷入口的完整列表（默认词 + 用户新增，整体读写） */
export const PREF_COMMON_WORDS: string = 'bilimusic_common_words';
export const PREF_BUVID: string = 'bilimusic_buvid';
/** 持久化后的 buvid Cookie 串（buvid3=...; buvid4=...） */
export const PREF_BUVID_COOKIE: string = 'bilimusic_buvid_cookie';
/**
 * buvid 是否已升级为官方值（finger/spi 下发）：
 * false / 缺省 = 仍是本地 MD5 兜底假值 —— 是登录二维码被风控提前作废与
 * playurl 偶发拦截的共同根因候选，AppContainer 启动后会延迟重试升级
 * （见 service/BiliDevice.ts 的 isBuvidFallback / upgradeBuvidCookie）。
 */
export const PREF_BUVID_OFFICIAL: string = 'bilimusic_buvid_official';
/**
 * 已向风控接口（ExClimbWuzhi）上报过指纹的 buvid 特征串。
 *
 * 值 = 当前 buvid3 的 md5 前 8 位（**不存指纹本体**，与 cookieFingerprint 同一脱敏口径）。
 * 用途：新 buvid 在服务端是「未激活」状态，取流容易被判异常，必须上报一次；但
 * buvid 不变时**不必每次启动都重报**（多报反而是异常行为）。这里存「对哪个 buvid
 * 报过」，buvid3 一旦被升级 / 自愈换掉，特征串随之改变 → 自动触发下一次上报。
 */
export const PREF_BUVID_ACTIVATED_FOR: string = 'bilimusic_buvid_activated_for';
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
 * ⚠️ 目前**存了但从没用过** —— 全仓没有 `getLoginRefreshToken()`
 * 的调用方，也没有续期接口。B 站完整的续期链路是 5 步（含 RSA-OAEP 加密换
 * correspondPath + 解析 HTML 拿 refresh_csrf），工程量约等于一个完整功能，
 * 尚未开工。当前登录态完全依赖 SESSDATA 自然过期。
 * 别把这个键当成「已实现续期」的证据。
 */
export const PREF_LOGIN_REFRESH_TOKEN: string = 'bilimusic_login_refresh_token';
/**
 * 最近一次「登录态被服务端确认有效」的时间戳（ms，字符串存）。
 *
 * 用途：nav 接口返回 -101 时，**不直接清掉登录凭据**，而是把它归零并保留
 * Cookie —— 凭据可能被风控临时拒绝，也可能只是网络抖动。设置页据此显示
 * 「登录已失效 · 点击重新登录」而不是悄悄变回未登录。
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
// 音量恒走系统媒体音量（无独立 volume / isMuted 键）

/** 前后台标志（EntryAbility onForeground/onBackground 发布）：动画门控与后台落盘节流的依据 */
export const STORE_APP_FOREGROUND: string = 'appForeground';

/**
 * 定时停止播放：到点时间戳（ms），0 / 未设置 = 关闭。
 *
 * 只发布**结束时刻**而不是剩余秒数 —— 剩余量由设置页用本地 1s 计时器现算，
 * 这样播放内核不必每秒往 AppStorage 写一次（那是 1 次/秒的重渲染）。
 * 播放内核负责到点暂停并把它清 0。
 */
export const STORE_SLEEP_TIMER_END: string = 'sleepTimerEnd';

/**
 * 桌面卡片拉起播放页：EntryAbility 解析卡片路由 want 后自增发布的序号。
 * 卡片（Form 渲染进程）经 postCardAction router 拉起 UIAbility，onCreate /
 * onNewWant 里 seq++；Index 侧 @StorageProp + @Watch（首次启动 @Watch 不
 * 触发，aboutToAppear 补刀读当前值比对）后复刻 PlayBar.openPlayer 展开播放页。
 */
export const STORE_CARD_OPEN_PLAYER_SEQ: string = 'cardOpenPlayerSeq';

// ===== 播放页共享元素转场（PlayBar ↔ PlayerPage 唱片一镜到底） =====
/** 共享元素 id：底栏小唱片与播放页大唱片必须一致（组件状态切换动画中 geometryTransition 配对） */
export const GEOMETRY_ID_PLAYER_DISC: string = 'player_cover';
/**
 * 共享元素 id：迷你栏「透明锚点」与播放页背景面（全屏沉浸层）。
 *
 * getRectangleById / FrameNode 位置 API（含 WithTransform / ToScreen 变体）
 * 拿不到 HDS 托管内容被合成变换（缩放+平移）后的**真实视觉**矩形 ——
 * 只对得上 HDS 宿主窗口内的逻辑布局值，差出一个 HDS 合成系数
 * （真机 ~1.245×1.41、模拟器 ~1.089，且随设备/模式变化）。
 * geometryTransition 由**系统**做跨窗口坐标换算，因此背景面的
 * 「从迷你栏原位向四周扩大」也交给 geometryTransition：
 *   · 迷你栏侧 —— PlayBar 槽位根 Stack 里一个**透明**锚点节点（不渲染任何像素，
 *     只提供几何），if (!playerOpen) 时在场；
 *   · 播放页侧 —— PlayerInfoComponent 全屏背景面，if (playerOpen) 时在场；
 *   · 两极同帧翻转（STORE_PLAYER_OPEN 在同一条 animateTo 里写）→ 系统在
 *     迷你栏**真实视觉包围盒** ↔ 全屏之间做几何插值，收起自动逆向镜像。
 * 锚点刻意做成透明替身而不是迷你栏根节点本身：唱片配对（GEOMETRY_ID_PLAYER_DISC）
 * 的起点是根节点的子孙，若根节点整树参与本配对，两套 geometryTransition 会嵌套
 * 叠加在同一子树上；替身与唱片是兄弟节点，两套配对完全解耦。
 */
export const GEOMETRY_ID_PLAYER_SURFACE: string = 'player_surface_bg';
/**
 * 背景面形变的**起点**圆角半径（vp）：= 迷你栏胶囊半高（布局高 56，实测）。
 * geometryTransition 在**绑定处**同步圆角（官方文档示例注释），配对两端显式
 * 挂 borderRadius 即参与形变 —— 展开过程中背景面四角呈胶囊同款圆角，
 * 而不是直角矩形从迷你栏长出。
 */
export const PLAYER_SURFACE_RADIUS_START_VP: number = 28;
/**
 * 背景面形变的**终点**圆角半径（vp）：全屏态收平 —— 静止时四角若保留圆角，
 * 会露出底层页面底色，像渲染缺陷。系统对两端半径的处理（全程同步起点值 /
 * 按端点插值）均满足「过程圆角、终态收平」。
 */
export const PLAYER_SURFACE_RADIUS_END_VP: number = 0;
/**
 * 播放页展开/收起主动画时长（ms），曲线 PLAYER_MAIN_CURVE（cubicBezier(0.32,0.72,0,1)）——
 * 容器纵向延展、封面飞行、页签图标淡出共用同一 animateTo，必须严格一致；分层入场（LAYER_DELAY_*）以它为基线。
 * 取值参考华为音乐播放页的动效节奏。
 */
export const PLAYER_TRANSITION_MS: number = 700;
/** 转场进行中标志：转场期间两边唱片的旋转动画暂停，结束后恢复（跨组件走 AppStorage） */
export const STORE_PLAYER_TRANSITIONING: string = 'playerTransitioning';

// ===== 播放页组件状态切换动画（Index 根 Stack overlay 挂载） =====
/**
 * 播放页展开态：true = 全屏播放页打开。
 * 打开：PlayerInfoComponent 主动画 animateTo 内写 true（大唱片 if 出现、PlayBar 迷你唱片
 * if 消失 → geometryTransition 页内配对飞行；Index 页签图标 opacity 淡出）。
 * 收起：Index.closePlayer 的 animateTo 内写 false（逆向镜像）；各子组件 @Watch 复位入场状态。
 */
export const STORE_PLAYER_OPEN: string = 'playerOpen';
/**
 * 播放页 overlay 是否挂载：PlayBar.openPlayer 写 true（Index 根 Stack 条件挂载
 * LazyDest('Player')，复用懒加载注册 + 1.5s 预热）；closePlayer 收起动画结束后回 false 卸载。
 */
export const STORE_PLAYER_OVERLAY_MOUNTED: string = 'playerOverlayMounted';

// ===== 二级页悬浮播放条（推送子页底部只保留播放栏，对齐华为音乐） =====
/**
 * 推送的 NavDestination 是否在导航栈顶（首页 navBar 时为 false）。
 * 由 NavStackHolder.setupInterception 的 willShow（随转场同步翻转）与
 * didShow（转场落定后的权威校正，兜 push 防抖在 willShow 内取消的边角）
 * 写入；Index 消费 —— 为 true 且队列
 * 非空时在根 Stack 挂 SubPagePlayBar，同帧互斥摘除首页胶囊 miniBar
 * （barFloatingStyle）与 tabletPlayBar：全窗口同一时刻只有一套
 * GEOMETRY_ID_PLAYER_DISC / _SURFACE 锚点（id 全窗口必须唯一）。
 */
export const STORE_SUB_PAGE_ACTIVE: string = 'subPageActive';
/**
 * 收起播放页请求（seq 递增，与 toast 同款写法）：TopArea 收起按钮写入，
 * Index @Watch 消费 → closePlayer（收起按钮在 overlay 深层组件树里，跨层信号走 AppStorage）。
 */
export const STORE_PLAYER_CLOSE_REQUEST: string = 'playerCloseRequest';
/**
 * 收起时内容层退场信号（seq 递增）：Index.closePlayer 在主动画（700ms /
 * PLAYER_MAIN_CURVE）闭包**外**写入，四个内容层组件与 PlayerInfoComponent 的
 * 自持内容（SM Swiper 指示点 / LG 标题块）@Watch 消费，方式为「分层柔退」：
 * 各层在 @Watch 内自建 animateTo（LAYER_EXIT_* 错峰，见 InteractionConstants），
 * 与 700ms 几何转场重叠；seq 仍在闭包外递增
 * —— 收起被动画作用域合批时依旧能触发。封面 / 背景仍由闭包内的
 * STORE_PLAYER_OPEN=false 驱动 700ms 几何转场。下滑收起路径不递增本键
 * （内容随整页滑走，不单独退场）。
 */
export const STORE_PLAYER_CONTENT_EXIT: string = 'playerContentExit';

/**
 * 播放页收起动画风格（AppSettings.closeAnimStyle 的运行时镜像，取值见
 * MusicModels 的 PLAYER_CLOSE_STYLE_*）：EntryAbility 启动首发、设置页切换时
 * 重发。Index.closePlayer 据此分流收起实现（morph 柔退 / slide 下滑），
 * PlayerPage 据此决定是否挂下拉手势。
 */
export const STORE_PLAYER_CLOSE_ANIM: string = 'playerCloseAnimStyle';
/**
 * 播放页封面风格（AppSettings.playerCoverStyle 的运行时镜像，取值见
 * MusicModels 的 PLAYER_COVER_STYLE_*）：EntryAbility 启动首发、设置页
 * 切换时重发。CoverDiscComponent 据此分流封面形态与旋转启停，
 * PlayerInfoComponent 的 SurfaceLayers 据此分流背景分层。
 */
export const STORE_PLAYER_COVER_STYLE: string = 'playerCoverStyle';
/**
 * 条目展示（AppSettings.itemDisplayStyle 的运行时镜像，取值见 MusicModels 的
 * ITEM_DISPLAY_LIST / ITEM_DISPLAY_GRID）：EntryAbility 启动首发、外观设置页
 * 切换时重发。歌单页签 / 最近播放 / UP 主页 / 首页三页签 / 歌单详情（不可排序）/
 * 搜索视频结果的 @StorageProp 订阅它，长条 ⇄ 大封面双列即时切换。
 */
export const STORE_ITEM_DISPLAY_STYLE: string = 'itemDisplayStyle';
/**
 * geometryTransition 摘除标志：下滑收起（slide 风格 / 手势过阈值释放）开始时
 * 置 true、结束后复位。CoverDisc / PlayBar 迷你唱片 / 透明锚点等全部
 * GEOMETRY_ID_* 挂载点据此把 id 换成空串 —— 必须先渲染一帧再翻转
 * STORE_PLAYER_OPEN，否则被移除节点仍带旧 id 触发迷你唱片反向配对飞行
 * （封面从半滑出位置斜飞回栏）。空串 = 无转场；摘除期间配对两端从不共存。
 */
export const STORE_PLAYER_GT_OFF: string = 'playerGeometryOff';
/**
 * 下滑收起进行中：背景面挂载条件 if (playerOpen || slideOut) 的守卫项 ——
 * 下滑开始帧即翻转 STORE_PLAYER_OPEN=false，没有本守卫背景面会被立即拆除。
 * Index.slideOutClose 置 true，动画 onFinish 复位。
 */
export const STORE_PLAYER_SLIDE_OUT: string = 'playerSlideOutActive';
/** 下滑收起终态动画位移（vp）：Index.slideOutClose 的 animateTo 闭包内一次写入终值（窗口高），渲染层逐帧插值 */
export const STORE_PLAYER_SLIDE_OFFSET: string = 'playerSlideOffsetY';
/** 下滑收起终态透明度（0~1）：与 STORE_PLAYER_SLIDE_OFFSET 同批写入（1→0 渐隐） */
export const STORE_PLAYER_SLIDE_ALPHA: string = 'playerSlideAlpha';
/**
 * 手势下拉松手过阈值的收起请求（seq 递增，与 STORE_PLAYER_CLOSE_REQUEST 同款）：
 * PlayerPage 手势 onActionEnd 写入，Index @Watch 消费 → slideOutClose。
 */
export const STORE_PLAYER_SLIDE_CLOSE_REQUEST: string = 'playerSlideCloseRequest';
/**
 * 播放页拖拽/回弹进行中（PlayerPage 手势生命周期写入）：下拉开始置 true，
 * 松手过阈值由 slideOutClose 的 onFinish 复位、松手不足由回弹 onFinish 复位。
 * Index.closePlayer 据此分流 —— 拖拽中/回弹未归零时收起一律走下滑收起
 * （页面视觉位移非 0 时 morph 配对目标框按中途值计算必漂移；回弹动画的
 * AppStorage 终值已归 0，光看 STORE_PLAYER_SLIDE_OFFSET 兜不住这 250ms 窗口）。
 */
export const STORE_PLAYER_DRAG_ACTIVE: string = 'playerDragActive';
/**
 * 上滑展开进行中（仅 slide 风格打开路径）：
 * PlayBar.openPlayer 在挂载 overlay **前**预置（与 SLIDE_OFFSET=窗高 / SLIDE_ALPHA=0
 * / GT_OFF=true 同批），使首帧渲染即处于屏下隐形位；PlayerInfoComponent
 * .slideInTransition 的 animateTo onFinish 复位（迷你唱片守卫 `!playerOpen ||
 * slideIn` 据此「盖住再隐藏」，背景面/封面挂载守卫 `playerOpen || slideOut ||
 * slideIn` 据此在 playerOpen 翻转前保持挂载）。Index.closePlayer 据本标志吞掉
 * 上滑 350ms 窗口内的收起请求（反向打断存在双 animateTo 的 onFinish 竞态）。
 */
export const STORE_PLAYER_SLIDE_IN: string = 'playerSlideIn';

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
 * 一级页 HDS 悬浮底栏 miniBar 槽位实测宽（vp，0 = 尚未测量）。
 * Index 的 onBarStyleChange 回写（miniBarWidth 实参；真机实测收起 / 展开
 * 两态上报同值 328 = sm 全宽胶囊标准宽 —— 槽位宽是常量、与展开收起无关，
 * 两种状态均发布，仅过滤 0 / 负无效值），SubPagePlayBar 只读订阅 ——
 * 二级页悬浮播放栏宽度直接采用一级页实测值，两级底栏恒同宽 ——
 * HDS 默认宽在编译产物里不可推导（previewer abc 为 mock 实现），
 * 实测回传是唯一可靠口径。
 * ⚠️ 只走 onBarStyleChange 通道：别在 HDS 托管的 miniBarBuilder 内容里挂
 * onAreaChange 回写（PlayBar 根节点注释有真机翻车存档）。
 */
export const STORE_MAIN_MINI_BAR_WIDTH: string = 'mainMiniBarWidth';

/**
 * 悬浮底栏布局模式（AppSettings.barLayout 的运行时镜像，取值见 MusicModels 的
 * BAR_LAYOUT_* 常量）：EntryAbility 启动首发、设置页切换时重发，Index @StorageProp
 * 订阅 → barFloatingStyle 受控重建 → HdsTabs.barLayoutMode 即时切换。
 */
export const STORE_BAR_LAYOUT: string = 'barLayoutMode';

/**
 * 播放页进度条样式镜像（AppSettings.progressStyle 的运行时镜像，取值见
 * MusicModels 的 PROGRESS_STYLE_* 常量）：EntryAbility 启动首发、设置页切换时
 * 重发，ControlAreaComponent @StorageProp 订阅 → 经典 Slider / 流光 / 波点 /
 * 频谱四分支渲染即时切换。
 */
export const STORE_PROGRESS_STYLE: string = 'playerProgressStyle';

/**
 * 迷你栏进度指示开关镜像（AppSettings.miniBarProgress 的运行时镜像）：
 * EntryAbility 启动首发、设置页切换时重发，PlayBar @StorageProp 订阅 ——
 * 控制迷你栏底部 2vp 直线进度条与水平收起态圆环进度是否渲染（默认开）。
 */
export const STORE_MINI_BAR_PROGRESS: string = 'miniBarProgressShown';

/**
 * 迷你栏自动展开收起开关镜像（AppSettings.miniBarAutoExpand 的运行时镜像）：
 * EntryAbility 启动首发、设置页切换时重发，Index @StorageProp 订阅 ——
 * 控制「屏幕上滑展开、下滑收起迷你栏」的全屏手势是否生效（默认开；
 * 关闭后浏览列表的竖向滑动不再触发迷你栏收放）。
 */
export const STORE_MINI_BAR_AUTO_EXPAND: string = 'miniBarAutoExpandOn';

/**
 * 倍速播放总开关镜像（AppSettings.speedEnabled 的运行时镜像）：
 * EntryAbility 启动首发、设置页切换时重发，播放页 ControlAreaComponent
 * @StorageProp 订阅 —— 控制功能行倍速入口是否渲染（默认关）。
 */
export const STORE_PLAYBACK_SPEED_ENABLED: string = 'playbackSpeedEnabled';

/**
 * 响度均衡开关镜像（AppSettings.loudnessNormalizationEnabled 的运行时镜像）：
 * EntryAbility 启动首发、设置页切换时重发，MusicPlayer prepared 挂点读取 ——
 * 开启后按 LoudnessStore 记录把偏响的歌衰减到目标响度（只衰减不放大，默认关）。
 */
export const STORE_LOUDNESS_NORM_ENABLED: string = 'loudnessNormalizationEnabled';

/**
 * 「在 B 站打开原视频」开关镜像（AppSettings.openInBilibiliEnabled 的运行时镜像）：
 * EntryAbility 启动首发、设置页切换时重发，播放页 ControlAreaComponent
 * @StorageProp 订阅 —— 控制功能行跳转 B 站入口是否渲染（默认开）。
 */
export const STORE_OPEN_IN_BILI_ENABLED: string = 'openInBilibiliEnabled';

/**
 * 当前倍速值镜像（AppSettings.playbackSpeed 的运行时镜像，档位见
 * MusicModels.PLAYBACK_SPEED_OPTIONS）：MusicPlayer.setPlaybackSpeed 写入，
 * ControlAreaComponent @StorageProp 订阅驱动倍速片标签与菜单 ✓ 刷新。
 */
export const STORE_PLAYBACK_SPEED: string = 'playbackSpeed';

/**
 * 「与其他应用同时播放」开关镜像（AppSettings.audioMixEnabled 的运行时镜像）：
 * EntryAbility 启动首发、设置页切换时重发，MusicPlayer 每次 loadAndPlay 前消费 ——
 * 开启后激活 AudioSession 并声明 CONCURRENCY_MIX_WITH_OTHERS（本应用与其他应用的
 * 音频双向混音，不抢也不被抢），关闭则停用会话、恢复系统默认焦点行为（默认关）。
 */
export const STORE_AUDIO_MIX_ENABLED: string = 'audioMixEnabled';

/**
 * 播放页沉浸背景是否偏暗（封面主色明度判断）。
 * 由 PlayerInfoComponent 取色后写入；TopAreaComponent（投播按钮图标黑白）、
 * 状态栏内容色按它切换。离开播放页时由 PlayerPage 复位为浅色状态栏。
 */
export const STORE_PLAYER_BG_DARK: string = 'playerBgDark';

/**
 * 播放页沉浸背景主色（rgba 字符串，封面取色 dealColor 产物）。
 * PlayerInfoComponent 取色后写入（@StorageLink 双向发布）；
 * 封面底部溶解层（透明→主色渐变叠加）的目标色，与 SurfaceLayers 沉浸渐变
 * 同源同色，保证封面下沿与背景无缝衔接。
 */
export const STORE_PLAYER_IMAGE_COLOR: string = 'playerImageColor';

/**
 * 折叠屏展开态全局唯一真源（display.FoldDisplayMode.FOLD_DISPLAY_MODE_FULL）。
 * 由 service/FormFactorHolder（App 生命周期常驻，EntryAbility.onCreate 初始化）
 * **唯一写入**：冷启动同步读一次 getFoldDisplayMode，之后 foldDisplayModeChange
 * 持续跟进开合。消费端（播放页分栏、歌词/标题字号）一律
 * @StorageProp 只读订阅。
 */
export const STORE_FOLD_EXPANDED: string = 'foldExpanded';

/**
 * 本机是否为折叠屏设备（display.isFoldable()）。FormFactorHolder 唯一写入，
 * 目前仅作诊断 / 预留（非折叠设备恒 false，恒不触发壳层切换）。
 */
export const STORE_DEVICE_FOLDABLE: string = 'deviceFoldable';

/** 下载任务快照（DownloadTask[]）。由 DownloadManager 推送，下载页 @StorageLink 订阅。 */
export const STORE_DOWNLOAD_TASKS: string = 'downloadTasks';

/**
 * 下载队列是否处于「全部暂停」（boolean）。
 * 单个任务的 PAUSED 状态只描述「它自己停下了」，而队列级暂停还包含
 * 「一大批任务仍是 PENDING 但不会被消费」这个信息，页面需要它来显示「已暂停」提示。
 */
export const STORE_DOWNLOAD_PAUSED: string = 'downloadPaused';

/**
 * 下载页顶栏状态镜像键（顶栏在根 HdsNavigation titleBar，无法直接读页面
 * @State 的状态通道）。下载页顶栏内容（选择按钮 + 工具条）依赖页内状态，
 * 由 DownloadsPage 把派生状态推到 AppStorage，根栏侧组件
 * （components/DownloadsTabBar.ets）@StorageProp 订阅。
 * 页面侧唯一写入口：DownloadsPage.syncBarState / refreshQueueFlags。
 */
export const STORE_DL_BAR_SELECTING: string = 'dlBarSelecting';
export const STORE_DL_BAR_HAS_TASKS: string = 'dlBarHasTasks';
export const STORE_DL_BAR_ALL_SELECTED: string = 'dlBarAllSelected';
export const STORE_DL_BAR_QUEUE_ACTIVE: string = 'dlBarQueueHasActive';
export const STORE_DL_BAR_QUEUE_PAUSED: string = 'dlBarQueueHasPaused';

/**
  * 歌单页顶栏状态镜像键（机制同 STORE_DL_BAR_*：顶栏在根 HdsNavigation
  * titleBar 的状态通道）。页面侧唯一写入口：PlaylistsPage.syncBarState；
  * 栏内组件 components/PlaylistsTabBar.ets（PlTitleActions）
  * @StorageProp 订阅。
  */
export const STORE_PL_BAR_SELECTING: string = 'plBarSelecting';
export const STORE_PL_BAR_CAN_SELECT: string = 'plBarCanSelect';
export const STORE_PL_BAR_ALL_SELECTED: string = 'plBarAllSelected';

/**
  * 搜索状态键（搜索独立成 'Search' 二级页，首页三 chip 化）。
  * keyword 是搜索二级页（SearchPage）与其标题栏行（SearchInputBar，
  * components/SearchTabBar.ets）共享的**双向**状态（两侧都 @StorageLink，
  * 任一侧写入另一侧即见）；tab 是首页分类 chip（HomeCategoryChips）与
  * HomePage 内容分支的共享通道。
  */
export const STORE_SEARCH_KEYWORD: string = 'searchKeyword';
export const STORE_SEARCH_TAB: string = 'searchTab';

/**
 * 首页头部在场状态（boolean，HomePage 写、Index 标题栏读）：
 * 列表偏移 < HomePage 的 HOME_ENTRY_FLIP_VP（入口搜索框还在视口内）时 true，
 * 滚出后 false —— Index 标题栏据此淡入/淡出右上角搜索按钮（200ms）。
 * HomePage 只在状态翻转时写（onDidScroll 每帧回调，不翻转零开销）。
 */
export const STORE_HOME_SEARCH_ENTRY_ACTIVE: string = 'homeSearchEntryActive';

/**
 * 首页 chip 条在场状态（boolean，HomePage 写、Index 标题栏读）：
 * 列表偏移 < HomePage 的 HOME_TABS_FLIP_VP（分类 chip 条顶缘尚未触及导航栏底）
 * 时 true —— Index 标题栏显示「BiliMusic」标题；滚到/越过阈值（chip 条上移到
 * 导航栏）后 false —— 标题 200ms 淡出、三个分类 tab 图标淡入固定在导航栏
 * （与 STORE_HOME_SEARCH_ENTRY_ACTIVE 同一套滚动翻转镜像机制）。
 * HomePage 只在状态翻转时写（onDidScroll 每帧回调，不翻转零开销）。
 */
export const STORE_HOME_CHIPS_ACTIVE: string = 'homeChipsActive';

/**
 * 当前活动页签下标（number，写入方 Index 的受控 HdsTabs）。
 * Tabs 的 TabContent 是常驻的，下载页在非活动页签时依然接收下载快照、
 * 全量重分组 —— 切到别的 Tab 下载中照样拖慢整个 UI。
 * Index 把 activeTab 挂到 AppStorage（@StorageLink 写穿），下载页据此门控：
 * 非本 Tab 跳过重算只置脏标记，切回时补算一次（见 DownloadsPage.onTabChanged）。
 */
export const STORE_ACTIVE_TAB: string = 'activeTab';

/**
 * 跨层切页签请求（seq 递增）：播放页 overlay 深层组件（如「去歌单页选」菜单项）
 * 不持有 HdsTabsController，也无法穿透写 Index 的私有成员 —— 与收起请求
 * （STORE_PLAYER_CLOSE_REQUEST）同一套 seq 信号写法，Index @Watch 消费。
 * 目标下标先写 STORE_TAB_SWITCH_TARGET，再递增本键；先写目标后发信号，
 * 消费端读到的目标必然是本次请求的。
 */
export const STORE_TAB_SWITCH_REQUEST: string = 'tabSwitchRequest';

/** 切页签请求的目标页签下标（与 STORE_TAB_SWITCH_REQUEST 配对使用，见其注释） */
export const STORE_TAB_SWITCH_TARGET: string = 'tabSwitchTarget';

/**
 * 「去歌单页选」点选加入请求（seq 递增）：播放页 ControlArea 的菜单项在收起
 * 播放页 + 切到歌单页签的同时递增本键；PlaylistsPage @Watch 消费 —— 快照
 * STORE_CURRENT_TRACK 后进入「点选加入」模式（整行点击 = 加入该歌单，单次
 * 点选即退出，顶部占位条目内嵌提示条）。与 STORE_TAB_SWITCH_REQUEST 同款 seq 写法。
 */
export const STORE_PICK_PLAYLIST_ADD: string = 'pickPlaylistAdd';

/**
 * 三键导航栏避让区高度（vp）：getWindowAvoidArea(TYPE_SYSTEM).bottomRect.height
 * 经 px2vp 换算。三键导航模式下非 0（整条可点击系统控件），手势导航模式下为 0 ——
 * **以它是否 > 0 区分导航模式**（判据 = 避让区来源，不按高度猜）。
 *
 * 不能用固定高度阈值猜「超过即三键」：大屏展开态的手势指示条 / 避让区高度
 * 与手机不同（不同形态、不同密度、分屏都会变），按阈值猜会误判分支 →
 * barBottomMargin 折算错 → 胶囊垂直偏移。写入：EntryAbility.writeSafeArea
 * 首帧前同步首发一次 +
 * pages/Index.ets 注册 avoidAreaChange 动态更新（转屏 / 折叠开合 / 切导航模式
 * 自动重算）。消费：Index.barFloatingStyle 的 barBottomMargin（三键 → 完整
 * 避让）、tabletPlayBar 底部 padding。
 */
export const STORE_NAV_BAR_BOTTOM: string = 'navBarBottomVp';

/**
 * 手势指示条避让区高度（vp）：getWindowAvoidArea(TYPE_NAVIGATION_INDICATOR)
 * .bottomRect.height 经 px2vp 换算。手势导航模式下非 0，三键导航模式下为 0。
 * 悬浮胶囊只需避开它的一半（下沉进避让区上半段，可见指示条仍完整露出，
 * 贴近底部边框的悬浮观感）；三键导航栏则必须完整避让（走 STORE_NAV_BAR_BOTTOM）。
 * 写入 / 消费方与 STORE_NAV_BAR_BOTTOM 相同。
 */
export const STORE_NAV_INDICATOR_BOTTOM: string = 'navIndicatorBottomVp';

/**
 * 水平安全区（vp）：getWindowAvoidArea(TYPE_SYSTEM).leftRect / rightRect 宽度
 * 经 vp 换算。竖屏通常为 0；横屏下状态栏若以侧边条带上报，避让值落在这里。
 * 写入：EntryAbility.writeSafeArea 首发一次 + Index.applyAvoidArea（avoidAreaChange
 * 动态更新），与 STORE_SAFE_TOP / STORE_SAFE_BOTTOM 同批同源。
 * 消费：播放页紧凑横屏分支的左侧避让。
 */
export const STORE_SAFE_LEFT: string = 'safeLeftVp';
export const STORE_SAFE_RIGHT: string = 'safeRightVp';

/**
 * 窗口内容区宽度（vp）：EntryAbility.writeSafeArea 首帧前用 windowRect.width ÷
 * densityPixels 首发一次，pages/Index.ets 再挂 HdsTabs.onAreaChange 持续回写
 * （折叠开合 / 分屏 / 转屏后组件重排即触发）。
 *
 * 用途：HDS 悬浮页签栏是**底左锚定**（barSideMargin = 胶囊左缘缩进，实测见
 * Index.ets BAR_FLOATING_BAR_WIDTH 注释），队列空时大屏上单胶囊贴左不居中；
 * 队列空且宽度 ≥600vp 时用 (宽度 − 胶囊宽) ÷ 2 反算 barSideMargin 才能居中。
 * 不用 currentBreakpoint 判宽度：断点只给区间，居中公式要的是精确值。
 */
export const STORE_WINDOW_WIDTH_VP: string = 'windowWidthVp';

/**
 * 窗口内容区高度（vp）：与 STORE_WINDOW_WIDTH_VP 同一批写入（EntryAbility
 * 首帧前首发 windowRect.height ÷ densityPixels；Index 的 HdsTabs.onAreaChange
 * 回写宽度时一并回写高度）。用途：整页下滑的终点距离与手势跟手压暗的进度分母。
 */
export const STORE_WINDOW_HEIGHT_VP: string = 'windowHeightVp';

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
 * 一次性启动提示通道：AppContainer 迁移链路写、
 * Index（aboutToAppear 补播 + @Watch SEQ 双覆盖）消费后清空 MSG。
 * 走独立双键而不复用 Toast 通道的原因：initRest 与 loadContent 并行启动，
 * Index 挂载可能早于提示写入 —— MSG 常驻 + SEQ 递增让晚到的 Index 也能补播；
 * Toast 通道的 MSG 是即写即消，错过就丢。消费即清 MSG，防止下次启动重播。
 */
export const STORE_STARTUP_HINT_MSG: string = 'startupHintMsg';
export const STORE_STARTUP_HINT_SEQ: string = 'startupHintSeq';

/**
 * 蓝牙权限申请信号（seq 读-改-写递增）：播放内核（MusicPlayer，拿不到
 * UIContext）在首次真实播放场景写入；Index 根页 @Watch 消费 —— 先弹
 * 应用内弹窗**告知权限使用目的**，用户点「去授权」后才调
 * requestPermissionsFromUser 弹系统授权框（应用市场合规：申请权限必须
 * 告知使用目的、不得直接弹系统框、禁止诱导欺骗授权）。
 * 信号不含消息体：弹窗文案固定，seq 只承担「跨层通知 UI」的职责。
 */
export const STORE_BT_PERM_REQ_SEQ: string = 'btPermReqSeq';

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
 * 收藏夹同步版本号：每轮同步结束（成功/部分成功/失败）递增。
 * 写入：service/FavSyncManager.ts；消费：同步页 @StorageLink + @Watch 刷新状态。
 */
export const STORE_FAV_SYNC_REV: string = 'favSyncRev';

/**
 * 歌单导入任务状态（`ImportState`，见 service/PlaylistImporter.ts）。
 * 写入：ImportTaskManager 单例（每处理一首广播一次新快照对象）；
 * 消费：导入向导页 @StorageLink + @Watch 刷新进度与阶段流转。
 */
export const STORE_IMPORT_STATE: string = 'playlistImportState';

/**
 * 收藏夹同步状态（`FavFolderSyncState[]`，见 service/FavSyncStore.ts）。
 * 体量很小（每夹约 150 字节），直接走单 key，无需分片。
 */
export const PREF_FAV_SYNC_STATE: string = 'bilimusic_fav_sync_state';

/**
 * 收藏夹同步**勾选状态**（`number[]`，见 service/FavSelectionStore.ts）。
 * 只存「未勾选」的收藏夹 id（倒置存储）：默认全选、新建夹自动入选，
 * 老版本升级零迁移（没有数据 = 从未取消过勾选）。
 * 写入 / 读取：service/FavSelectionStore.ts（同步页勾选交互 + 管理器过滤）。
 */
export const PREF_FAV_SELECTION: string = 'bilimusic_fav_selection';

/**
 * 收藏夹同步**方向模式**（`number[]`，见 service/FavTwowayStore.ts）。
 * 正向存储：在集合内 = 双向同步（本地增删实时写回 B 站），不在 = 单向（默认，
 * 仅 B 站 → 本地，老版本升级零迁移）。只按 mediaId 判断，B 站侧改名不受影响。
 * 写入 / 读取：service/FavTwowayStore.ts（同步页每行「单向/双向」滑块）。
 */
export const PREF_FAV_TWOWAY_IDS: string = 'bilimusic_fav_twoway_ids';

/**
 * 收藏夹双向同步**待推送意图队列**（`FavPushIntent[]`，见 service/FavPushStore.ts）。
 * 双向夹本地增删实时写回失败后进入此队列，下次同步先补推再拉取；
 * 上限 150 条（Preferences 单值 8192 字节预算），超限 FIFO 丢最旧。
 * 注意：与已下线的老分片前缀 `bilimusic_fav_push_queue_` 无关，勿混淆。
 */
export const PREF_FAV_TWOWAY_PUSH_QUEUE: string = 'bilimusic_fav_twoway_push_queue';

/**
 * 首页快捷卡行「歌单卡」的持久化 id 列表（`string[]`，见 service/HomeCardStore.ts）。
 * 存加入首页的歌单 id（加入顺序即卡行显示顺序），上限 9 个
 * （快捷卡行共 10 卡 = 最近播放 1 + 歌单 9）。
 * 写入 / 读取：service/HomeCardStore.ts（歌单列表 ⋯ 菜单「加入首页 / 移出首页」）；
 * 消费：HomePage 快捷卡行（HomeQuickCards）。
 */
export const PREF_HOME_PLAYLIST_CARDS: string = 'bilimusic_home_playlist_cards';

/**
 * 收藏夹「待推送队列」分片前缀 —— **已下线**。常量保留仅供 AppContainer
 * 启动时清理老版本残留的分片数据（key 形如 `bilimusic_fav_push_queue_0 / _1 / …`，
 * 上限 0..32）。
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
 *         STORE_SAFE_BOTTOM → HdsTabs 悬浮页签栏的 barBottomMargin（净离底 +
 *                             按导航模式叠加避让区，见 STORE_NAV_BAR_BOTTOM /
 *                             STORE_NAV_INDICATOR_BOTTOM）、
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
 * 悬浮胶囊自带 20vp 离底间距：
 *   离底 20 + 胶囊高 56 + 与底栏间距 8 + 底栏高 56 = 140，再留 20 余量 = 160。
 *
 * 实际使用时还要加上 STORE_SAFE_BOTTOM：Tabs 内容区铺满整屏（不避让）之后，
 * 页签栏 / 底栏各自抬高了「底部安全区高度」，列表末尾不多让这么多，
 * 最后一项就会被它们压住。
 */
export const CONTENT_END_OFFSET: number = 160;

//
// 音频档位由服务端决定，客户端只能「在已有档位里挑」。线上实测（匿名 + PC UA）：
//   热门投稿 8/8 都真实给出三档，30280 的 bandwidth 实测 176k~216k，是真的 192K；
//   但**部分投稿（如音乐中心的承载视频）三个档位的 bandwidth 全在 66k 上下**
//   —— 那是 B 站侧只有一份低码率音源，三个 id 指向同一份数据，选哪档文件都一样大。
//   匿名状态下 fnval=16 与 fnval=4048 返回的档位完全一致，**提高 fnval 拿不到更多档**
//   —— 该结论**仅限匿名**：登录（大会员）后 fnval=4048 才会额外下发杜比全景声
//   （dash.dolby.audio）与 Hi-Res 无损（dash.flac），这两个字段不在 dash.audio 里，
//   需由 BilibiliApi.collectAudioStreams 合并进候选。
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
 * 「档位 + 实测码率」合成一行展示文案。
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
