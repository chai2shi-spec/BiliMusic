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
 * ══════════ 列表入场错峰（位移 + 淡入）══════════
 *
 * 单条：下移 10vp + 透明度 0 → 1，normal(250ms) EaseOut；
 * 相邻条目延迟 35ms 依次入场，形成「错峰」的节奏感。
 *
 * ⚠️ 只错峰**首屏可见的前 8 条**（ENTRANCE_MAX_ITEMS）：之后的条目直接同批出现，
 * 否则长列表滚动到底部时新出现的条目还在逐条错峰，越滚越累赘。
 * 集中放此处的原因与按压参数相同：入场节奏应当全局统一，各页面各写一份迟早漂移。
 */
/** 入场起始位移（vp，动效规格 8~12） */
export const ENTRANCE_OFFSET_VP: number = 10;
/** 单条入场动画时长（ms，normal 档） */
export const ENTRANCE_DURATION_MS: number = 250;
/** 相邻条目入场延迟（ms，规格 30~40） */
export const ENTRANCE_STAGGER_MS: number = 35;
/** 参与错峰的条数上限（首屏可见 ≤8 条，其后同批出现） */
export const ENTRANCE_MAX_ITEMS: number = 8;

/**
 * ══════════ 子页转场（push / pop）══════════
 *
 * PlaylistDetail / Recent / About 的 pushPath 转场：从右滑入 slow(400ms) EaseOut，
 * 返回时反向滑出，与侧滑返回手势自然衔接（见各页 NavDestination.customTransition）。
 */
export const NAV_TRANSITION_MS: number = 400;

/**
 * ══════════ 全局 Toast（AppToast）══════════
 *
 * 入场：从停留位下方 16vp 淡入上移 fast(150ms)；停留 hold（默认 1200ms）后
 * 200ms 反向退出。连续调用**替换**当前气泡并重置停留计时（见 AppToast.showAppToast），
 * 绝不排队连播 —— 批量删 5 首只弹最后一条。
 */
/** Toast 入场位移（vp）：从停留位下方上移淡入 */
export const TOAST_ENTER_OFFSET_VP: number = 16;
/** 入场动画时长（ms，fast 档） */
export const TOAST_ENTER_MS: number = 150;
/** 退出动画时长（ms） */
export const TOAST_EXIT_MS: number = 200;
/** 默认停留时长（ms） */
export const TOAST_HOLD_MS: number = 1200;
/** 离屏幕底边的净间距（vp，再叠加 safeBottom，落在悬浮胶囊上方） */
export const TOAST_BOTTOM_MARGIN_VP: number = 72;

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
 * 快照到达时用 animateTo fast(150ms) Linear 把进度条平滑推到新值；
 * 重定目标从当前视觉值起算，快照连发时进度条连续滑动不跳变。
 */
export const DOWNLOAD_SMOOTH_MS: number = 150;
