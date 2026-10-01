/**
 * 全局 Toast：AppStorage 驱动的**单实例**轻提示（Index 根部挂载一次）。
 *
 * 为什么不用系统 promptAction.showToast：
 *   1. 系统 Toast 无出入场动效可定制（规格：底部 16vp 上移淡入 fast(150ms)，
 *      停留 1200ms，退出 200ms）；
 *   2. 系统 Toast 连续调用会**排队连播** —— 批量删 5 首连弹 5 次；
 *      本组件单实例 + 序号重置停留计时，连续调用只保留最后一条。
 *
 * 通道（任何 .ts/.ets 都能写，播放内核也走这里，见 MusicPlayer.notifyHint）：
 *   STORE_TOAST_MSG      文案
 *   STORE_TOAST_HOLD_MS  停留时长（ms）
 *   STORE_TOAST_SEQ      递增序号 —— 相同文案连续调用也要触发 @Watch（替换而非忽略）；
 *                        ⚠️ 必须读-改-写递增，独立计数器会撞号丢提示（见 Constants）
 * UI 侧统一入口 showAppToast()；组件侧订阅三键，@Watch 接管显隐与隐藏计时。
 *
 * ⚠️ 层级边界：bindSheet / AlertDialog 等弹层渲染在页面之上的弹层系，本组件盖不住
 * （弹层内触发的提示仍走系统 Toast，见 QueueSheet）。
 */

import {
  STORE_SAFE_BOTTOM,
  STORE_TOAST_HOLD_MS,
  STORE_TOAST_MSG,
  STORE_TOAST_SEQ
} from '../common/Constants';
import {
  TOAST_BOTTOM_MARGIN_VP,
  TOAST_ENTER_MS,
  TOAST_ENTER_OFFSET_VP,
  TOAST_EXIT_MS,
  TOAST_HOLD_MS
} from '../common/constants/InteractionConstants';

/**
 * 全局轻提示入口（UI 侧统一走这里）。
 * 连续调用 = 替换：seq 递增让组件重置停留计时并覆盖文案，不排队。
 */
export function showAppToast(message: string, holdMs: number = TOAST_HOLD_MS): void {
  AppStorage.setOrCreate(STORE_TOAST_MSG, message);
  AppStorage.setOrCreate(STORE_TOAST_HOLD_MS, holdMs);
  const seq: number = AppStorage.get<number>(STORE_TOAST_SEQ) ?? -1;
  AppStorage.setOrCreate(STORE_TOAST_SEQ, seq + 1);
}

@Component
export struct AppToast {
  @StorageLink(STORE_TOAST_MSG) toastMsg: string = '';
  @StorageLink(STORE_TOAST_HOLD_MS) toastHoldMs: number = TOAST_HOLD_MS;
  @StorageLink(STORE_TOAST_SEQ) @Watch('onToastRequested') toastSeq: number = -1;
  /** 底部安全区（vp）：气泡停留在悬浮胶囊上方，避让手势条/导航栏 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 气泡显隐：本地状态驱动 transition 出入场，与请求通道解耦 */
  @State toastVisible: boolean = false;
  /** 停留计时器句柄；新请求先清旧计时再重置（替换不排队的核心） */
  private hideTimer: number = -1;

  aboutToDisappear(): void {
    this.clearHideTimer();
  }

  private clearHideTimer(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
  }

  /** 新请求到达：立刻可见（或覆盖文案）、停留计时从零重走 */
  private onToastRequested(): void {
    this.clearHideTimer();
    this.toastVisible = true;
    this.hideTimer = setTimeout((): void => {
      this.hideTimer = -1;
      this.toastVisible = false;
    }, TOAST_ENTER_MS + this.toastHoldMs);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.toastVisible) {
        Text(this.toastMsg)
          .fontSize(14)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 20, right: 20, top: 12, bottom: 12 })
          .borderRadius(20)
          .backgroundColor($r('app.color.toast_bg'))
          .margin({ left: 32, right: 32, bottom: TOAST_BOTTOM_MARGIN_VP + this.safeBottom })
          // 出入场：入场自停留位下方 16vp 上移淡入 fast(150ms)，退出 200ms 反向；
          // combine 子项不带 animation，跟随主项配置。
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.OPACITY
              .animation({ duration: TOAST_ENTER_MS, curve: Curve.EaseOut })
              .combine(TransitionEffect.translate({ y: TOAST_ENTER_OFFSET_VP })),
            TransitionEffect.OPACITY
              .animation({ duration: TOAST_EXIT_MS, curve: Curve.EaseOut })
              .combine(TransitionEffect.translate({ y: TOAST_ENTER_OFFSET_VP }))
          ))
      }
    }
    .width('100%')
    .height('100%')
    // 整层不参与命中测试：Toast 不拦截下层任何触摸（列表滚动、悬浮胶囊页签）
    .hitTestBehavior(HitTestMode.None)
  }
}
