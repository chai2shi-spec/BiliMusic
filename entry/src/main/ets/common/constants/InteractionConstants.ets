/**
 * 按压缩放交互参数（TrackItem 首创，各列表条目推广共用）。
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
 * 所有按钮（含弹层 44 高大按钮）与搜索页滑块选段统一 8vp 圆角（用户指定）：
 * 原 Capsule 全圆（32 高 = 16）药丸感过强，收小到 8 保留圆润又不至于全圆。
 */
export const BUTTON_RADIUS_VP: number = 8;

/**
 * ══════════ 播放页分层入场（点迷你条 → 播放页）══════════
 *
 * 主动画总时长 450ms（= `PLAYER_TRANSITION_MS`，必须与驱动封面 geometryTransition 的时长一致，
 * 否则会出现「封面已停住、整页还在飘」的错位）。各层按信息优先级依次浮现：
 * 顶栏 → 歌名/进度 → 控制区 —— 全部排在**主动画基线（450ms）之后**：
 * 封面落位、容器铺满后内容才分层淡入 + 轻微上移（2026-10-21 用户动效规格第 3 点）。
 *
 * ⚠️ **封面（CoverDiscComponent）刻意不参与分层**：它的形变由 `geometryTransition` 独占
 * （那个 `Image` 节点上还挂着 `rotate`）。若给它的父容器再叠 scale/translate，
 * 转场目标框会按「动画中途的缩放值」计算 → 封面落位后还会再弹一下。
 *
 * 位移与单层时长复用下面的 `ENTRANCE_OFFSET_VP` / `ENTRANCE_DURATION_MS`；
 * 只有「各层延迟」是这里特有的，集中定义便于真机微调（某层抢戏就把它的延迟调 0 或摘掉）。
 */
/** 顶栏（收起键 / 投播）：主动画落位后第一批淡入，只淡入不位移（顶栏上下动会像「掉下来」） */
export const LAYER_DELAY_TOP: number = 450;
/** 歌名 / 歌手 / 进度条：封面落位后再留一拍，「先看封面、再看歌名」的顺序 */
export const LAYER_DELAY_INFO: number = 540;
/** 控制区：最后落位，也是离封面最远的一层 */
export const LAYER_DELAY_CONTROL: number = 660;

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
 * 2026-10-14 两轮实测结论：原下标闸门（ENTRANCE_INDEX_MAX=12 → 20）都会在
 * 「首屏预建批次（可视区 + 缓存区，约 16 条）」与「直出条目」之间露出断层
 * （第 13 条、抬闸后第 17 条先于上层出现）。取消闸门改为全员入场后，
 * 本封顶同时承担「批尾与窗外速入条目几乎同帧落定、不出现下层先亮」的职责，
 * 故从 420 收紧到 280（= 8 × 35）：批尾与速入的最大时间差被压到一个动画窗内。
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
 * 2026-10-08 卡顿优化：150 → 250。快照节流从 200ms 放宽到 300ms 后
 * （见 DownloadManager.UI_NOTIFY_INTERVAL），150ms 的动画窗口只覆盖两份
 * 快照间隔的一半，进度条会「滑一段、停一拍」；250ms 覆盖 83%，
 * 观感连续且动画总开销反而更低（重定目标频率降了 40%）。
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
 * 数据落地帧尾部 extent 只增不减（新条目追加），底部弹簧过滚动不被收缩强制解析
 * —— 修「加载第二页完成时列表整体跳一下」（2026-10-19，四页统一）。
 */
export const LIST_FOOTER_HEIGHT_VP: number = 48;

/**
 * ══════════ 搜索页下拉刷新（方案三 · 骨架接管）══════════
 *
 * 刷新指示器复用 SkeletonTrackItem，不新增任何视觉元素：下拉时骨架行从
 * 上方 12vp 落位 + 按下拉进度淡入（onOffsetChange 跟手映射，不套 animateTo）；
 * 松手触发后骨架停在原位保持纯静态（扫光带已全局删除）；Done 后 250ms 淡出上移退场。
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
