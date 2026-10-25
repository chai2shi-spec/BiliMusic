import { curves } from '@kit.ArkUI';

/**
 * 按压缩放交互参数（各列表条目共用）。
 *
 * 按下收到 0.9 的收缩确认，抬起/取消回弹 1.0：只做形变，
 * 不改底色、不加按压蒙层/高亮。150ms + EaseOut 落在 120~180ms
 * 手感区间，收尾轻快不拖沓。
 *
 * 集中放一处的原因：各页面各写一份 0.9 / 150 迟早漂移不一致，
 * 按压手感应当全局统一。
 */
export const PRESS_SCALE: number = 0.9;

/** 按压/回弹动画时长（ms） */
export const PRESS_ANIM_MS: number = 150;

/**
 * ══════════ 统一按钮圆角 ══════════
 * 所有按钮（含弹层 44 高大按钮）与搜索页滑块选段统一 8vp 圆角：
 * 保留圆润又不至于全圆药丸感。
 */
export const BUTTON_RADIUS_VP: number = 8;

/**
 * ══════════ 播放页分层入场（点迷你条 → 播放页）══════════
 *
 * 主动画总时长 700ms（= `PLAYER_TRANSITION_MS`，必须与驱动封面 geometryTransition 的时长一致，
 * 否则会出现「封面已停住、整页还在飘」的错位）。
 *
 * 内容层**随背景面覆盖进度空间序淡入** —— 背景面自底向上生长：底部区域最先被盖住、
 * 中部 ~210ms、顶部 ~530ms（按 PLAYER_MAIN_CURVE @700ms 推算），各层延迟对齐
 * 其所在区域被盖住的时刻，淡入与飞行尾部重叠，读感为「页面边生长边显内容」，
 * 总落定 ~780ms。
 * 收起时 closePlayer 在主动画闭包**外**递增 STORE_PLAYER_CONTENT_EXIT，各内容层
 * @Watch 复位落在隐式动画作用域外 → 单帧直接消失；封面 / 背景仍走 700ms 几何转场。
 *
 * ⚠️ **封面（CoverDiscComponent）刻意不参与分层**：它的形变由 `geometryTransition` 独占
 * （那个 `Image` 节点上还挂着 `rotate`）。若给它的父容器再叠 scale/translate，
 * 转场目标框会按「动画中途的缩放值」计算 → 封面落位后还会再弹一下。
 *
 * 位移与单层时长复用下面的 `ENTRANCE_OFFSET_VP` / `ENTRANCE_DURATION_MS`；
 * 只有「各层延迟」是这里特有的，集中定义便于真机微调（某层抢戏就把它的延迟调 0 或摘掉）。
 */
/** 顶栏（收起键 / 投播）：所在区域最后被背景面盖住（顶部），故最后淡入，只淡入不位移（顶栏上下动会像「掉下来」） */
export const LAYER_DELAY_TOP: number = 530;
/** 歌名 / 歌手 / 进度条：中部区域 ~210ms 已覆盖，470ms 起淡入留足余量 */
export const LAYER_DELAY_INFO: number = 470;
/** 控制区（含歌词，同批）：底部区域最先被背景面盖住，最早淡入 */
export const LAYER_DELAY_CONTROL: number = 400;

/**
 * ══════════ 收起分层柔退 ══════════
 *
 * morph 风格收起时内容层不再单帧瞬隐，改为**反向错峰柔和退场**（镜像入场节奏）：
 * 背景收缩自顶部揭起 → 顶栏先退、标题块次之、控制区/歌词最后；各层 200ms
 * EaseIn 加速淡出 + 复位位移（与 700ms 几何转场重叠，总退场 ~340ms）。
 * seq（STORE_PLAYER_CONTENT_EXIT）仍在主动画闭包外递增，各层 @Watch 内
 * **自建** animateTo 驱动退场；下滑收起路径不触发本组常量。
 */
/** 柔退单层时长（ms，EaseIn 加速离场） */
export const LAYER_EXIT_DURATION_MS: number = 200;
/** 顶栏柔退延迟（ms）：背景收缩自顶揭起，顶栏最先退 */
export const LAYER_EXIT_DELAY_TOP: number = 0;
/** 标题块柔退延迟（ms） */
export const LAYER_EXIT_DELAY_INFO: number = 70;
/** 控制区 / 歌词柔退延迟（ms）：与入场 LAYER_DELAY_CONTROL 同批语义 */
export const LAYER_EXIT_DELAY_CONTROL: number = 140;
/**
 * 背景面收起末端渐隐曲线：透明度 1→0 但曲线前 ~65% 恒持 ≈1、末端加速衰减 ——
 * 背景面收缩接近迷你栏时融入下层页面，替代落位瞬间硬切。调早调晚改 x1。
 */
export const PLAYER_BG_EXIT_CURVE = curves.cubicBezierCurve(0.65, 0, 1, 1);
/**
 * 下滑收起（slide 风格 / 手势过阈值释放）：起步慢、越滑越快的重力感。
 */
export const PLAYER_SLIDE_CURVE = curves.cubicBezierCurve(0.4, 0, 1, 1);
/** 下滑收起动画时长（ms） */
export const SLIDE_CLOSE_MS: number = 350;
/** 手势下拉松手收起判定阈值（vp，仅位移判定，不做速度判定） */
export const SLIDE_DISMISS_THRESHOLD_VP: number = 120;
/** 手势跟手最大压暗（0~1）：下拉进度映射透明度衰减的封顶 */
export const SLIDE_DIM_MAX: number = 0.4;
/** 手势不足阈值回弹时长（ms，EaseOut） */
export const SLIDE_BACK_MS: number = 250;
/**
 * 上滑展开（仅 slide 风格打开路径）：
 * 整页从屏幕底部减速上滑 + 渐显，与下滑收起的「加速下滑」镜像 ——
 * easeOutCubic（起步果断、到位时柔和收住），重力感对称。
 */
export const PLAYER_SLIDE_IN_CURVE = curves.cubicBezierCurve(0.33, 1, 0.68, 1);
/** 上滑展开动画时长（ms），与 SLIDE_CLOSE_MS 对称 */
export const SLIDE_OPEN_MS: number = 350;
/**
 * 播放页主动画曲线（打开 / 收起共用）：果断起步 + 长尾柔和收住（iOS 全屏展开
 * 同款手感）。GT 配对（背景面 / 唱片）、页签图标淡出均由该曲线驱动。
 * 注：cubicBezierCurve 的返回类型 ICurve 在 SDK 声明里未导出、无法显式标注，
 * 此处靠类型推断（消费方只把它塞进 animateTo 的 curve 参数，无需命名该类型）。
 */
export const PLAYER_MAIN_CURVE = curves.cubicBezierCurve(0.32, 0.72, 0, 1);

/**
 * ══════════ 列表入场错峰（位移 + 淡入）══════════
 *
 * 单条：下移 10vp + 透明度 0 → 1，normal(250ms) EaseOut；
 * **所有**条目都参与入场动画：首屏批次（窗内创建）按「下标 × 35ms」错峰，
 * 窗外（滚动中懒加载）条目 0 延迟速入 —— 不存在「直接显示」的条目，
 * 也就不存在动画条目与直出条目之间的可见断层。
 * 集中放此处的原因与按压参数相同：入场节奏应当全局统一，各页面各写一份迟早漂移。
 */
/** 入场起始位移（vp，动效规格 8~12） */
export const ENTRANCE_OFFSET_VP: number = 10;
/** 单条入场动画时长（ms，normal 档） */
export const ENTRANCE_DURATION_MS: number = 250;
/** 相邻条目入场延迟（ms，规格 30~40，首屏批次按自身下标叠加） */
export const ENTRANCE_STAGGER_MS: number = 35;
/**
 * 首屏批次入场延迟封顶（ms）：下标 × 35ms 超过它就不再累加，批尾条目共享
 * 同一延迟一起入场 —— 总入场时长有界（≤ 封顶 + 250ms 动画 ≈ 0.53s），
 * 批尾不会越靠下等越久。
 * 「批尾与窗外速入条目不倒挂（下层先亮）」由 TrackItem 内的排队冲刷机制
 * （TrackEntranceQueue.flushPending）硬保证，本封顶只负责无人滚动时
 * 错峰总时长有界。
 */
export const ENTRANCE_DELAY_CAP_MS: number = 280;
/**
 * 入场时间窗（ms）：列表首条挂载时开窗。窗内创建＝首屏批次（含 LazyForEach
 * 预建的缓存条目），按下标 × 35ms（封顶 ENTRANCE_DELAY_CAP_MS）错峰入场；
 * 窗外创建＝滚动中懒加载的条目，0 延迟速入（同样 250ms 淡入落位，只是不排队）
 * —— 拖动始终跟手，且速入与批尾封顶延迟天然衔接。
 * 取 250ms：挂载批次在同一帧内创建，余量足够；人从看到页面到发起首拖远超此值。
 */
export const ENTRANCE_WINDOW_MS: number = 250;

/**
 * ══════════ 子页转场（push / pop）══════════
 *
 * PlaylistDetail / Recent / About 的 pushPath 转场：从右滑入 slow(400ms) EaseOut，
 * 返回时反向滑出，与侧滑返回手势自然衔接（见各页 NavDestination.customTransition）。
 */
export const NAV_TRANSITION_MS: number = 400;

/**
 * ══════════ 全局轻提示（AppToast → 系统 toast）══════════
 *
 * 视觉/动效/避让全部由平台 toast 提供（见 AppToast.ets），本处只保留业务参数：
 * 停留时长与「抬到悬浮迷你条之上」的上抬量。连续调用**替换**当前提示（先 close 再 open），
 * 绝不排队连播 —— 批量删 5 首只弹最后一条。
 */
/** 默认停留时长（ms，即 toast 的 duration） */
export const TOAST_HOLD_MS: number = 1200;
/** 系统 toast 上抬量（vp）：抬到悬浮迷你条上方（迷你条 ~64vp + 16vp 呼吸位） */
export const TOAST_LIFT_VP: number = 80;

/**
 * ══════════ 下载页多选模式切换 ══════════
 *
 * 进出多选：复选框槽位 0 ↔ 44vp 展开/收起（行内容随之右移/回位），
 * 复选框本体叠 translate 从右侧滑入，normal(250ms) EaseOut。
 */
/** 复选框槽位宽度（vp）＝ 行内容右移量，与最小触达边长对齐 */
export const SELECT_SLOT_VP: number = 44;
/** 多选进出动画时长（ms） */
export const SELECT_TOGGLE_MS: number = 250;

/**
 * ══════════ 下载页数值平滑 ══════════
 *
 * 快照到达时用 animateTo fast Linear 把进度条平滑推到新值；
 * 重定目标从当前视觉值起算，快照连发时进度条连续滑动不跳变。
 *
 * 取 250ms：快照节流为 300ms（见 DownloadManager.UI_NOTIFY_INTERVAL），
 * 250ms 覆盖 83% 的快照间隔，观感连续且重定目标频率更低。
 */
export const DOWNLOAD_SMOOTH_MS: number = 250;

/**
 * ══════════ iOS 式大标题收拢 ══════════
 *
 * PlaylistDetail / Playlists / Downloads / Settings 的列表头部大标题随内容滚出，
 * 固定栏小标题在下方距离内随滚动淡入（collapseProgress 0→1），
 * 滚回顶部再淡出。集中定义避免各页各写一份 72 迟早漂移不一致。
 */
/** 大标题收拢动画距离（vp）：列表滚过该距离时固定栏小标题完全显现 */
export const LARGE_TITLE_COLLAPSE_DIST: number = 72;

/**
 * ══════════ 列表尾部加载状态条 ══════════
 * 常驻 + 固定高度：列表有内容时尾部条不插拔，只换内容（转圈 / 到底文案 / 上拉提示）。
 * 数据落地帧尾部 extent 只增不减（新条目追加），底部弹簧过滚动不被收缩强制解析。
 */
export const LIST_FOOTER_HEIGHT_VP: number = 48;

/**
 * ══════════ 搜索页下拉刷新（骨架接管）══════════
 *
 * 刷新指示器复用 SkeletonTrackItem，不新增任何视觉元素：下拉时骨架行从
 * 上方 12vp 落位 + 按下拉进度淡入（onOffsetChange 跟手映射，不套 animateTo）；
 * 松手触发后骨架停在原位保持纯静态；Done 后 250ms 淡出上移退场。
 * 触发阈值 72vp 同时是淡入进度的分母：拉满 = 不透明 = 「松手即刷」。
 */
/** 触发刷新的下拉偏移量（vp）＝ 骨架淡入进度的分母 */
export const PULL_REFRESH_OFFSET_VP: number = 72;
/** 下拉跟手系数（0 不跟手，1 完全跟手；55% = 跟手但带阻尼） */
export const PULL_REFRESH_RATIO: number = 0.55;
/** 最大下拉距离（vp）：封顶，防大力下拉把页面拽出半屏 */
export const PULL_MAX_DISTANCE_VP: number = 120;
/** 骨架跟手落位起始位移（vp）：进度 0 时停在上方 12vp 处 */
export const PULL_SKELETON_SETTLE_VP: number = 12;
/** Done 后骨架退场上移量（vp，负值向上） */
export const PULL_SKELETON_EXIT_VP: number = -6;
/** Done 后骨架淡出时长（ms，normal 档） */
export const PULL_SKELETON_FADE_MS: number = 250;

/**
 * ══════════ 装饰动画 LTPO 期望帧率 ══════════
 *
 * 唱片旋转 / 进度条流光脉冲 / 歌词滚动等装饰性动画以 vsync 满帧（最高 120fps）
 * 驱动渲染管线，形成持续 GPU/CPU 高负载 —— 官方 LTPO 低功耗文档点名反模式
 * （「无限循环转盘动画长时间保持高帧率导致手机发热」「应用以 120fps 响应 vsync」），
 * 整机被判重载后系统自动进入「性能模式」。
 *
 * 声明 `setExpectedFrameRateRange`（API 12+）后渲染管线按期望帧率分频，
 * LTPO 屏自适应降刷新率，持续负载显著下降。官方建议小区域微动效取 15~30Hz，
 * 缓慢旋转/呼吸/流光取上沿 30 无肉眼差异；歌词 400ms 换行补间 @30fps 亦够顺。
 */
export const DECORATIVE_ANIM_FRAME_RATE: ExpectedFrameRateRange = {
  min: 0,
  max: 120,
  expected: 30
};
