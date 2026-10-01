/**
 * 歌词常量（移植自 audio-interaction-master）。
 */

export enum LyricScrollEffect {
  /** 整行滚动 */
  Line,
  /** 逐字渐变 */
  LetterGradient,
  /** 逐字缩放渐变 */
  LetterScaleGradient,
  /** 星星滚动 */
  LetterStar
}

export enum LyricTopPosition {
  Top,
  Middle
}

/** 矩形区域（歌词更新区域记录用） */
export class Rectangle {
  left: number;
  top: number;
  right: number;
  bottom: number;

  constructor(left: number, top: number, right: number, bottom: number) {
    this.left = left;
    this.top = top;
    this.right = right;
    this.bottom = bottom;
  }

  public isIn(x: number, y: number): boolean {
    return x >= this.left && x <= this.right && y >= this.top && y <= this.bottom;
  }
}
