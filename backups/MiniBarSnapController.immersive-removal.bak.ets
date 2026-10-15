/**
 * 迷你播放条滚动吸附控制器（MiniBarSnapController）。
 *
   * 职责：把四个 Tab 页列表 .onDidScroll 逐帧上报的滚动增量（真机实测：正 = 内容
   * 下移 / 手指下滑，负 = 内容上移 / 手指上滑）翻译成一次性的「收起 / 展开」翻转
   * 信号，滤掉抖动：
 *
 *   · 同方向累计：逐帧增量只有几 vp，单帧跨阈值几乎不可能，必须累计；
 *   · 方向反转清零：手指来回搓动时旧方向的累计量作废，防止两个方向互相「贡献」；
 *   · 阈值防抖：累计量跨过 MINI_BAR_SNAP_THRESHOLD 才翻转，边缘回弹（EdgeEffect.Spring）
 *     的少量反向增量翻不动状态；
  *   · 只认拖动帧：ScrollState 非 Scroll（松手惯性 / 边缘回弹）不累计 ——
  *     列表顶部回弹的正增量曾误触发收起（真机 2026-10-12）；
  *   · 目标态与当前态比对：翻转目标与 AppStorage 当前值相同时不回调 —— 写相同值
  *     不触发 @Watch，也省一次多余写入。
  *
  * 用法（Tab 页列表；onDidScroll 是 onScroll 的非弃用等价，载荷相同）：
  *   .onDidScroll((scrollOffset: number, scrollState: ScrollState) => {
  *     this.miniBarSnap.onScroll(scrollOffset, scrollState, (collapsed: boolean): void => {
  *       AppStorage.setOrCreate(STORE_MINI_BAR_COLLAPSED, collapsed);
  *     });
  *   })
 *
 * 动画不在这里做：落库 AppStorage 后由 Index @Watch 经
 * HdsTabsController.applyMiniBarStyle 应用（官方动效：更新迷你栏样式并伴随动效）。
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
    * 逐帧喂入 .onDidScroll 的滚动增量；跨阈值翻转目标态时回调一次 snap。
    *
   * @param delta 本帧滚动增量（vp）：真机实测正 = 内容下移（手指下滑 → 展开恢复），
   *              负 = 内容上移（手指上滑 → 收进页签栏）
    * @param state 本帧滚动状态：只认 ScrollState.Scroll（手指直接拖动）——
    *              Inertial（松手惯性 / 边缘回弹 / 滚动条甩动）帧不累计，
    *              列表顶部回弹的正增量曾把收起误触发
    *              （真机「下滑松手后迷你栏跳出屏幕」，2026-10-12）
    * @param snap  目标态与当前态不同时的落库回调（由调用方写 AppStorage）
    */
  onScroll(delta: number, state: ScrollState, snap: (collapsed: boolean) => void): void {
    if (state !== ScrollState.Scroll) {
      return;
    }
    const sign: number = delta > 0 ? 1 : (delta < 0 ? -1 : 0);
    if (sign !== 0 && sign !== this.lastSign) {
      this.accumulated = 0;
      this.lastSign = sign;
    }
    this.accumulated += delta;
    if (Math.abs(this.accumulated) < MINI_BAR_SNAP_THRESHOLD) {
      return;
    }
    // 极性（真机 2026-10-12 实测校准）：设备 onDidScroll 增量正 = 内容下移（手指
    // 下滑），负 = 内容上移（手指上滑）——与旧注释的假设正好相反，用户实测
    // 「下滑收起 / 上滑展开」即为旧极性的镜像。目标 UX：手指上滑（负累计，翻看
    // 更多内容）→ 收进页签栏让路；手指下滑（正累计，回顶部方向）→ 展开恢复。
    const targetCollapsed: boolean = this.accumulated < 0;
    this.accumulated = 0;
    const current: boolean = AppStorage.get<boolean>(STORE_MINI_BAR_COLLAPSED) ?? false;
    if (targetCollapsed !== current) {
      snap(targetCollapsed);
    }
  }
}
