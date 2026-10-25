/**
 * 全局轻提示：AppStorage 驱动的**单实例**系统 toast（Index 根部挂载一次）。
 *
 * 为什么用系统标准 toast（`promptAction.openToast`）而不是 HdsSnackBar：
 *   HdsSnackBar 是「左图标 / 中文本 / 右操作」三区横幅形态，纯短文案（本 App
 *   全部提示都是一行短句）时三区各自留白，横竖都空 —— 版式不匹配。
 *   系统 toast 的气泡**自身贴合文案**，无留白，且是平台标准形式。
 *
 * 为什么不用 `promptAction.showToast`：
 *   · `showToast` 没有句柄，连续调用只会**排队连播**（批量删 5 首连弹 5 次）；
 *   · `openToast` 返回 toastId，配 `closeToast(id)` 先关旧再开新，
 *     天然满足「替换不排队」。
 *
 * 通道（任何 .ts/.ets 都能写，播放内核也走这里，见 MusicPlayer.notifyHint）：
 *   STORE_TOAST_MSG      文案
 *   STORE_TOAST_HOLD_MS  停留时长（ms，即 toast 的 duration）
 *   STORE_TOAST_SEQ      递增序号 —— 相同文案连续调用也要触发 @Watch（替换而非忽略）；
 *                        ⚠️ 必须读-改-写递增，独立计数器会撞号丢提示（见 Constants）
 * UI 侧统一入口 showAppToast()；组件侧订阅三键，@Watch 直接透传给系统 toast。
 *
 * ⚠️ 层级边界：bindSheet / AlertDialog 等弹层渲染在页面之上的弹层系，
 * 弹层内触发的提示仍走系统 Toast（见 QueueSheet）—— 系统 toast 自己就是窗口级浮层，
 * 与它们同级，不受本组件影响。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import {
  STORE_TOAST_HOLD_MS,
  STORE_TOAST_MSG,
  STORE_TOAST_SEQ
} from '../common/Constants';
import { TOAST_HOLD_MS, TOAST_LIFT_VP } from '../common/constants/InteractionConstants';

/**
 * 全局轻提示入口（UI 侧统一走这里）。
 * 连续调用 = 替换：seq 递增让组件先关旧 toast 再开新的，不排队。
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
  /** 正在显示的 toast 句柄（-1 = 无）。新请求先关旧的，保证「替换不排队」 */
  private toastId: number = -1;
  /**
   * 本地请求代次：openToast 是异步的（Promise 回句柄），期间又来的新请求会让
   * 这条**陈旧**结果自行关闭 —— 否则「关不掉的那条」会盖住新提示。
   */
  private reqGen: number = 0;

  aboutToDisappear(): void {
    this.closeCurrent();
  }

  /** 关掉当前 toast（幂等：句柄已被系统回收时 closeToast 抛错，内部吞掉） */
  private closeCurrent(): void {
    if (this.toastId >= 0) {
      const id: number = this.toastId;
      this.toastId = -1;
      this.closeToastById(id);
    }
  }

  private closeToastById(id: number): void {
    try {
      this.getUIContext().getPromptAction().closeToast(id);
    } catch (e) {
      // toast 到点自动消失后句柄即失效，closeToast 会抛 —— 属正常路径，不报错
      console.warn(`closeToast(${id}) failed: ${e instanceof Error ? e.message : 'unknown'}`);
    }
  }

  /** 新请求到达：先关旧、再开新（替换语义），并在异步回柄时处理「已被更新的请求取代」 */
  private onToastRequested(): void {
    const gen: number = ++this.reqGen;
    this.closeCurrent();
    this.getUIContext().getPromptAction().openToast({
      message: this.toastMsg,
      duration: this.toastHoldMs,
      // 系统 toast 默认贴在底部（胶囊页签栏上）；上抬到悬浮迷你条之上
      offset: { dx: 0, dy: -TOAST_LIFT_VP }
    }).then((id: number): void => {
      if (gen !== this.reqGen) {
        // 期间又来了新请求：本条已被取代，立刻关掉，避免两条叠显
        this.closeToastById(id);
        return;
      }
      this.toastId = id;
    }).catch((err: BusinessError): void => {
      console.error(`openToast failed: ${err.message}`);
    });
  }

  build() {
    // 系统 toast 由窗口层渲染，宿主本身不占位、不拦截触摸
    Stack() {
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }
}
