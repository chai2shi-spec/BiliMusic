/**
 * 设备形态统一判定源（Pura X 外屏布局适配）。
 *
 * ══════════ 为什么需要本文件 ══════════
 * Pura X 折叠态外屏（326×326vp，1:1）与 Pura X Max 折叠态（459×672vp）
 * 的窗口断点完全相同（sm×md），任何仅凭断点的形态判断都必然把小方屏
 * 吞进阔折叠外屏分支；Pura X 内屏（440×707）横向断点同样是 sm，「以 sm
 * 代表外屏」也会让内屏走错分支。因此形态判定必须由「折叠态 + 宽高比 +
 * 尺寸区间」承担，且全仓只从本函数取值 —— 断点（sm/md/lg）只允许驱动
 * 结构参数（栏数 / 字号 / 间距），禁止再与机型形态绑定。
 *
 * ══════════ 四形态实测基准（vp，px 与 vp 换算与密度无关的部分只有比例） ══════════
 *   · Pura X 外屏（折叠态）  326×326  比例 1.000  px 980×980    → SmallSquare
 *   · Pura X 内屏（展开态）  440×707  比例 0.622  px 1320×2120  → PuraXInner
 *   · Pura X Max 折叠态      459×672  比例 0.683  px 1264×1848  → WideFoldCover
 *   · Pura X Max 展开态      939×664  比例 0.707  px 2584×1828  → WideExpand
 *
 * 尺寸输入统一取**整窗 windowRect**（EntryAbility 首发 + Index 的
 * windowSizeChange 节流回写，STORE_WINDOW_WIDTH_VP / _HEIGHT_VP），
 * 禁止用安全区或 availableArea —— 326vp 距 xs 阈值（320vp）仅 6vp，
 * 状态栏、导航条、圆角避让都会让断点抖动。折叠态输入由
 * service/FormFactorHolder 的 STORE_DEVICE_FOLDABLE / STORE_FOLD_EXPANDED
 * 派生（折叠屏设备且非展开态）。
 */

/** 设备形态（resolveForm 的判定结果，全仓唯一判定源） */
export enum DeviceForm {
  /** Pura X 折叠态外屏：326×326，1:1 小方屏 */
  SmallSquare,
  /** Pura X Max 折叠态外屏：459×672，≈14:10 阔折叠外屏 */
  WideFoldCover,
  /** Pura X 展开态内屏：440×707，16:10 长屏 */
  PuraXInner,
  /** Pura X Max 展开态：939×664，横置阔屏 */
  WideExpand,
  /** 其余形态（直板机 / 平板 / 常规折叠 / 分屏悬浮窗等），走既有通用分支 */
  Normal
}

/** 小方屏判定：宽高比下限（326×326 = 1.000，留裕量收到 0.93） */
const SMALL_SQUARE_ASPECT_MIN: number = 0.93;
/** 小方屏判定：短边上限（vp，326 + 少量机型浮动，挡住 420+ 的阔折叠外屏） */
const SMALL_SQUARE_SHORT_MAX: number = 360;
/** 阔折叠外屏判定：宽高比区间（459/672 ≈ 0.683，常规折叠外屏 ≈0.49 不命中） */
const WIDE_COVER_ASPECT_MIN: number = 0.66;
const WIDE_COVER_ASPECT_MAX: number = 0.76;
/** 阔折叠外屏判定：短边区间（vp，459 落 [420,500]，326 的小方屏不命中） */
const WIDE_COVER_SHORT_MIN: number = 420;
const WIDE_COVER_SHORT_MAX: number = 500;
/** Pura X 内屏判定：宽高比区间（440/707 ≈ 0.622 的 16:10 长屏） */
const INNER_ASPECT_MIN: number = 0.58;
const INNER_ASPECT_MAX: number = 0.66;
/** 阔折叠展开判定：短边下限（vp，Max 展开 939×664 的短边 664 不误入） */
const WIDE_EXPAND_SHORT_MIN: number = 900;

/**
 * 形态判定（唯一入口，纯函数无副作用）。
 *
 * @param winWvp  整窗宽（vp，windowRect 口径，禁止安全区）
 * @param winHvp  整窗高（vp，同上）
 * @param folded  是否处于折叠态（折叠屏设备 && 非展开态）
 * @returns DeviceForm；窗口尺寸未就位（≤0）一律 Normal，
 *          任何正阈值判定均不误命中（与旧 windowAspect 的挡零口径一致）。
 * 判定顺序即优先级：先折叠态两档（小方屏 / 阔折叠外屏，比例 + 尺寸区间
 * 双约束，断点无关），再展开态两档（Pura X 内屏比例带 / 阔折叠展开短边带）。
 */
export function resolveForm(winWvp: number, winHvp: number, folded: boolean): DeviceForm {
  if (winWvp <= 0 || winHvp <= 0) {
    return DeviceForm.Normal;
  }
  const short: number = Math.min(winWvp, winHvp);
  const long: number = Math.max(winWvp, winHvp);
  const ratio: number = short / long;

  if (folded && ratio >= SMALL_SQUARE_ASPECT_MIN && short <= SMALL_SQUARE_SHORT_MAX) {
    return DeviceForm.SmallSquare;
  }
  if (folded && ratio >= WIDE_COVER_ASPECT_MIN && ratio < WIDE_COVER_ASPECT_MAX
    && short >= WIDE_COVER_SHORT_MIN && short <= WIDE_COVER_SHORT_MAX) {
    return DeviceForm.WideFoldCover;
  }
  if (ratio >= INNER_ASPECT_MIN && ratio < INNER_ASPECT_MAX) {
    return DeviceForm.PuraXInner;
  }
  if (!folded && ratio >= WIDE_COVER_ASPECT_MIN && ratio < WIDE_COVER_ASPECT_MAX
    && short >= WIDE_EXPAND_SHORT_MIN) {
    return DeviceForm.WideExpand;
  }
  return DeviceForm.Normal;
}

/** 弹窗 / 半模态正文高度上限的窗口占比（窗口高 × 90%，见 dialogBodyMaxHeightVp） */
const DIALOG_BODY_WINDOW_RATIO: number = 0.9;
/** 弹窗标题 / 输入行 / 按钮等固定装饰的高度预算（vp），正文上限先扣掉它 */
const DIALOG_BODY_CHROME_VP: number = 150;
/** 弹窗正文上限下限（vp）：极矮窗口下保住列表基本可用高度，宁短勿裁 */
const DIALOG_BODY_MIN_VP: number = 120;

/**
 * 弹窗 / 半模态正文滚动区的窗口相对高度上限（小方屏防截断，方案硬性约束：
 * 「弹窗外层 constraintSize({ maxHeight: '90%' })」）。
 *
 * Pura X 折叠外屏（326×326）窗口高远小于常规手机：AlertDialog /
 * FIT_CONTENT 面板正文既有固定上限（260~360vp）加标题、输入行、按钮
 * 会超出窗口高，尾部条目被裁不可达。这里统一按「窗口高 × 90% − 装饰
 * 预算」收口，只在结果**小于**调用方默认上限时生效 —— 常规手机 / 平板
 * 窗口（高 ≥570vp）结果恒大于默认值，行为零变化；窗口高未就位（≤0，
 * 冷启动首帧）回落默认值。列表内部本就可滚，收口后只是滚动区变短。
 */
export function dialogBodyMaxHeightVp(windowHeightVp: number, defaultMaxVp: number): number {
  if (windowHeightVp <= 0) {
    return defaultMaxVp;
  }
  const cap: number = Math.round(windowHeightVp * DIALOG_BODY_WINDOW_RATIO) - DIALOG_BODY_CHROME_VP;
  if (cap >= defaultMaxVp) {
    return defaultMaxVp;
  }
  return cap < DIALOG_BODY_MIN_VP ? DIALOG_BODY_MIN_VP : cap;
}

/** 形态名（诊断日志用，enum 直接拼接只输出序号） */
export function deviceFormName(form: DeviceForm): string {
  switch (form) {
    case DeviceForm.SmallSquare:
      return 'SmallSquare';
    case DeviceForm.WideFoldCover:
      return 'WideFoldCover';
    case DeviceForm.PuraXInner:
      return 'PuraXInner';
    case DeviceForm.WideExpand:
      return 'WideExpand';
    default:
      return 'Normal';
  }
}
