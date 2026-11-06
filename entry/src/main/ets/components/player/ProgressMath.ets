/**
 * 进度条共用数学（PulseDot / Shimmer / WaveBars 三种进度皮肤同源）：
 * 皮肤组件只保留视觉与动画，进度换算统一走这里（行为与各组件原内联实现一致）。
 */

/** 章节分段刻度宽（vp）：四款进度样式统一 */
export const PROGRESS_MARK_WIDTH_VP: number = 2;
/** 章节分段刻度高（vp）：略高于轨道厚度，凸出可辨 */
export const PROGRESS_MARK_HEIGHT_VP: number = 10;
/** 章节分段刻度色（白 60%）：深浅主题与各轨道色上均可辨 */
export const PROGRESS_MARK_COLOR: string = '#99FFFFFF';

export class ProgressMath {
  /** Area 尺寸（Length）→ vp 数值；资源型（理论上不会出现）按 0 兜底 */
  static toVp(v: Length): number {
    if (typeof v === 'number') {
      return v;
    }
    if (typeof v === 'string') {
      return parseFloat(v);
    }
    return 0;
  }

  /** 进度比例（0~1）：时长未知时恒 0（不显示已播段） */
  static pct(value: number, max: number): number {
    if (max <= 0) {
      return 0;
    }
    const p: number = value / max;
    return Math.min(1, Math.max(0, p));
  }

  /** 进度头中心 x（vp）：钳制在轨道内，未测宽时贴左 */
  static headX(trackWidth: number, value: number, max: number): number {
    return Math.min(trackWidth, trackWidth * ProgressMath.pct(value, max));
  }

  /** 章节分段起点（秒）→ 刻度左缘 x（vp）：刻度中线对齐分段起点，不出轨道 */
  static markX(trackWidth: number, markSec: number, max: number): number {
    const center: number = trackWidth * ProgressMath.pct(markSec, max);
    const left: number = center - PROGRESS_MARK_WIDTH_VP / 2;
    return Math.max(0, Math.min(trackWidth - PROGRESS_MARK_WIDTH_VP, left));
  }

  /** 触摸横坐标 → 秒（钳制 0~max） */
  static secAt(x: number, trackWidth: number, max: number): number {
    if (trackWidth <= 0) {
      return 0;
    }
    const ratio: number = Math.min(1, Math.max(0, x / trackWidth));
    return ratio * max;
  }

  /** 已播段宽度（百分比字符串，保留两位小数） */
  static filledWidthStr(value: number, max: number): string {
    return `${(ProgressMath.pct(value, max) * 100).toFixed(2)}%`;
  }
}
