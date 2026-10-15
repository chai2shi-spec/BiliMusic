/**
 * 迷你播放条滚动吸附控制器（MiniBarSnapController）。
 *
 * 职责：把四个 Tab 页列表 .onDidScroll 逐帧上报的滚动增量（正 = 内容上滚 / 手指上滑，
 * 负 = 内容下滚 / 手指下滑）翻译成一次性的「吸附 / 恢复」翻转信号，滤掉抖动：
 *
 *   · 同方向累计：逐帧增量只有几 vp，单帧跨阈值几乎不可能，必须累计；
 *   · 方向反转清零：手指来回搓动时旧方向的累计量作废，防止两个方向互相「贡献」；
 *   · 阈值防抖：累计量跨过 MINI_BAR_SNAP_THRESHOLD 才翻转，边缘回弹（EdgeEffect.Spring）
 *     的少量反向增量翻不动状态；
 *   · 目标态与当前态比对：翻转目标与 AppStorage 当前值相同时不回调 —— 写相同值
 *     不触发 @Watch，也省一次多余写入。
 *
 * 用法（Tab 页列表；onDidScroll 是 onScroll 的非弃用等价，载荷相同）：
 *   .onDidScroll((scrollOffset: number, scrollState: ScrollState) => {
 *     this.miniBarSnap.onScroll(scrollOffset, (collapsed: boolean): void => {
 *       AppStorage.setOrCreate(STORE_MINI_BAR_COLLAPSED, collapsed);
 *     });
 *   })
 *
 * 动画不在这里做：跨组件写 AppStorage 无法保证 animateTo 的动画作用域，
 * 吸附/悬浮的过渡动画由持有动画属性的 MiniPlayerBar 在 @Watch 回调里本地驱动。
 */

import {
  STORE_MINI_BAR_COLLAPSED,
  MINI_BAR_SNAP_THRESHOLD
} from '../common/Constants';

export class MiniBarSnapController {
  /** 同方向累计滚动量（vp）：跨阈值即翻转目标态并清零重新累计。 */
  private accumulated: number = 0;
  /** 上一帧滚动方向（1 上滚 / -1 下滚 / 0 尚未滚动）：反转时清空累计量。 */
  private lastSign: number = 0;

  /**
   * 逐帧喂入 .onScroll 的滚动增量；跨阈值翻转目标态时回调一次 snap。
   *
   * @param delta 本帧滚动增量（vp）：正 = 内容上滚（→ 吸附），负 = 内容下滚（→ 恢复悬浮）
   * @param snap  目标态与当前态不同时的落库回调（由调用方写 AppStorage）
   */
  onScroll(delta: number, snap: (collapsed: boolean) => void): void {
    const sign: number = delta > 0 ? 1 : (delta < 0 ? -1 : 0);
    if (sign !== 0 && sign !== this.lastSign) {
      this.accumulated = 0;
      this.lastSign = sign;
    }
    this.accumulated += delta;
    if (Math.abs(this.accumulated) < MINI_BAR_SNAP_THRESHOLD) {
      return;
    }
    const targetCollapsed: boolean = this.accumulated > 0;
    this.accumulated = 0;
    const current: boolean = AppStorage.get<boolean>(STORE_MINI_BAR_COLLAPSED) ?? false;
    if (targetCollapsed !== current) {
      snap(targetCollapsed);
    }
  }
}
