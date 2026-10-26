/**
 * 进度条共用数学（PulseDot / Shimmer / WaveBars 三种进度皮肤同源）：
 * 皮肤组件只保留视觉与动画，进度换算统一走这里（行为与各组件原内联实现一致）。
 */
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
