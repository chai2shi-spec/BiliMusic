/**
 * 全局确认弹窗（替代系统 `showAlertDialog`）。
 *
 * 弹窗框架（标题排版 / 按钮分区 / 遮罩圆角）交给官方 `CustomContentDialog`
 * 标准弹窗，本文件只保留三件事：模块级单槽传参、宿主组件持有 controller、
 * 「先关弹窗再执行回调」的顺序保证。
 *
 * ⚠️⚠️ 为什么用 `CustomDialogController` 而不是 `openCustomDialog`（**闪退坑**）
 *
 * `promptAction.openCustomDialog({ builder: 全局 @Builder })` 会直接闪退：
 *     TypeError: Cannot read property observeComponentCreation2 of undefined
 *
 * 根因（华为官方 FAQ faqs-arkui-1159）：`@Builder` 自定义构建函数**只能在所属组件的
 * build 方法和其他自定义构建函数内调用，不允许在组件外调用**。模块级全局
 * `@Builder` 交给 `openCustomDialog`，弹窗渲染时找不到父组件的
 * `observeComponentCreation2` 上下文 → 直接抛 TypeError 崩掉。
 *
 * 改用 `@CustomDialog` + `CustomDialogController`（官方推荐的自定义弹窗方案）：
 * 弹窗的 build 由 controller.open() 触发执行，不存在「组件外调用 @Builder」
 * 的问题，因此可以安全地被任意页面复用。
 *
 * ⚠️ 还有**第二个坑**（比闪退更隐蔽）：官方明确「CustomDialogController 仅在作为
 * @Component struct 的**成员变量**、且**在组件内部定义时赋值才有效**」。模块级
 * `const c = new CustomDialogController({...})` **编译会过、`open()` 也不抛异常，
 * 但弹窗永远不显示** —— 静默失效，连日志都没有。
 * 所以 controller 必须放在 `AppDialogHost` 组件内，模块级 show* 函数经静态引用
 * `dialogHost` 驱动它。
 *
 * 好处：`showAppAlertDialog(uiContext, options)` **导出签名完全不变** → 20+ 处
 * 调用点零改动。
 *
 * ⚠️ controller **每次打开前重建**：CustomDialog 的构造参数在创建时
 * 定格、不支持动态刷新（faqs-arkui-555），而 `CustomContentDialog` 的
 * primaryTitle / buttons 都是构造参数 → 复用同一个 controller 会一直显示第一次
 * 的标题和按钮。所以 `openAlert()` 每次按模块级 `alertOptions` 单槽的当次值重建
 * controller 再 open。「controller 不得重新赋值」针对「旧弹窗还开着就换引用」的
 * 复用场景（会关不掉旧弹窗）；本弹窗是模态单槽，重建前 `closeAlert()` 已确保
 * 旧弹窗关闭，不存在悬空的旧弹窗（与 SettingsPage 音质弹窗同款策略）。
 *
 * 按钮点击：`CustomContentDialog` 的按钮自带关闭，action 里仍走
 * `onAlertButtonClick`（关 + 复位标记 + 执行回调）双保险 —— 回调里的 AppToast
 * 不会被弹层盖住。
 *
 * ⚠️ 部署要求：`AppDialogHost` 必须挂在组件树里（已挂在 `Index.ets` 根部，与
 * AppToast 同级）。否则 `dialogHost` 为 null，弹窗不显示并打一行 error 日志。
 */

import { UIContext, CustomContentDialog } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

/** 弹窗按钮：字段名与系统 AlertDialog 的按钮保持一致，调用点迁移零成本 */
export interface AppAlertButtonOptions {
  value: string;
  action?: () => void;
}

/** 确认弹窗参数：title / message / primaryButton（左）/ secondaryButton（右） */
export interface AppAlertDialogOptions {
  title: string;
  message: string;
  primaryButton: AppAlertButtonOptions;
  secondaryButton: AppAlertButtonOptions;
}

const EMPTY_BUTTON: AppAlertButtonOptions = { value: '' };

/**
 * 弹窗数据槽：模块级单槽，`showAppAlertDialog` 写入后由宿主按当次值重建
 * controller 再 open。同一时刻只可能存在一个弹窗（模态阻塞），单槽不会串内容。
 */
let alertOptions: AppAlertDialogOptions = {
  title: '',
  message: '',
  primaryButton: EMPTY_BUTTON,
  secondaryButton: EMPTY_BUTTON
};

/** 确认弹窗的「是否已打开」标记：用于 open 重入前先关旧弹窗 */
let alertOpened: boolean = false;

/**
 * 弹窗宿主组件：**唯一持有 CustomDialogController 的地方**（原因见文件头注释
 * 「第二个坑」）。宿主不渲染任何东西 —— 它只是 controller 的容器，真正的 UI
 * 由 controller.open() 拉起。挂在 `Index.ets` 根部（与 AppToast 同级）。
 */
@Component
export struct AppDialogHost {
  /**
   * 确认弹窗 controller：每次 `openAlert()` 按当次槽值重建（faqs-arkui-555，
   * 见文件头注释），初始为 null、从未弹过窗时不占资源。
   */
  private alertController: CustomDialogController | null = null;

  aboutToAppear(): void {
    // 注册自己，供模块级 show* 函数回调（页面就绪后才会有人调 open）
    dialogHost = this;
  }

  aboutToDisappear(): void {
    dialogHost = null;
  }

  /** 弹窗正文（CustomContentDialog 的 contentBuilder 槽） */
  @Builder
  AlertBody() {
    Text(alertOptions.message)
      .fontSize(14)
      .fontColor($r('app.color.text_secondary'))
      .textAlign(TextAlign.Center)
      .width('100%')
  }

  /** 供模块级 showAppAlertDialog 调用（成员方法，才能碰组件内的 controller） */
  openAlert(): void {
    // faqs-arkui-555：构造参数定格 → 每次按当次槽值重建（见文件头注释）
    this.alertController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: alertOptions.title,
        contentBuilder: (): void => {
          this.AlertBody();
        },
        buttons: [
          {
            value: alertOptions.primaryButton.value,
            buttonStyle: ButtonStyleMode.TEXTUAL,
            action: (): void => {
              onAlertButtonClick(alertOptions.primaryButton);
            }
          },
          {
            value: alertOptions.secondaryButton.value,
            buttonStyle: ButtonStyleMode.EMPHASIZED,
            action: (): void => {
              onAlertButtonClick(alertOptions.secondaryButton);
            }
          }
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      cancel: (): void => {
        alertOpened = false;
      }
    });
    alertOpened = true;
    try {
      this.alertController.open();
    } catch (e) {
      alertOpened = false;
      const err = e as BusinessError;
      console.error(`showAppAlertDialog failed: ${err.code} ${err.message}`);
    }
  }

  /** 关闭确认弹窗（幂等：没开时直接返回） */
  closeAlert(): void {
    if (!alertOpened) {
      return;
    }
    alertOpened = false;
    const controller: CustomDialogController | null = this.alertController;
    if (controller === null) {
      return;
    }
    try {
      controller.close();
    } catch (e) {
      const err = e as BusinessError;
      console.error(`close alert dialog failed: ${err.code} ${err.message}`);
    }
  }

  /** 宿主不渲染任何内容，仅承载 controller */
  build() {
    Column() {
    }
    // ⚠️ **刻意不设 width/height**：空 Column 默认 0×0，在父 Stack 里不占位、
    // 不可能遮住下层任何东西。再叠一层 hitTestBehavior(None) 双保险 ——
    // 宿主存在的唯一意义是让 controller 有个合法的组件上下文，绝不能参与布局或命中。
    .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 弹窗宿主静态引用：`AppDialogHost.aboutToAppear` 写入，模块级 show* 函数读取。
 * 为 null 说明宿主还没挂载（极少见），此时调弹窗会安全地什么都不做并打日志。
 */
let dialogHost: AppDialogHost | null = null;

/** 按钮点击：先确保弹窗关闭（官方按钮已自动关，这里双保险并复位标记），再跑业务回调 */
function onAlertButtonClick(button: AppAlertButtonOptions): void {
  const host: AppDialogHost | null = dialogHost;
  if (host !== null) {
    host.closeAlert();
  }
  const act: (() => void) | undefined = button.action;
  if (act !== undefined) {
    act();
  }
}

/**
 * 显示确认弹窗（系统 showAlertDialog 的替代入口）。
 *
 * @param uiContext 调用方页面的 UIContext（`this.getUIContext()`）。当前实现经宿主组件
 *                  的 controller 定位弹窗，不需要它；**保留该参数只为导出签名不变**，
 *                  让 20+ 处调用点零改动。
 * @param options   与系统 AlertDialog 同构的参数
 */
export function showAppAlertDialog(uiContext: UIContext, options: AppAlertDialogOptions): void {
  alertOptions = options;
  const host: AppDialogHost | null = dialogHost;
  if (host === null) {
    console.error('showAppAlertDialog: 弹窗宿主未挂载，弹窗未显示');
    return;
  }
  // 重入（上一个还没关就又调一次）：先关旧再开，避免两个确认框叠在一起
  host.closeAlert();
  host.openAlert();
}

/** 确认弹窗简化参数：标准「取消 / 确认」两键问句 */
export interface AppConfirmOptions {
  title: string;
  message: string;
  /** 左侧取消键文案，默认「取消」 */
  cancelText?: string;
  /** 右侧确认键文案 */
  confirmText: string;
  /** 点确认后的回调（点取消只关弹窗、不做事） */
  onConfirm: () => void;
}

/**
 * 标准确认问句（showAppAlertDialog 的薄封装）：左「取消」右「确认」，
 * 点取消只关弹窗。取消键需要额外动作（如提示语）的场合仍走 showAppAlertDialog。
 */
export function showConfirm(uiContext: UIContext, options: AppConfirmOptions): void {
  showAppAlertDialog(uiContext, {
    title: options.title,
    message: options.message,
    primaryButton: { value: options.cancelText ?? '取消' },
    secondaryButton: { value: options.confirmText, action: options.onConfirm }
  });
}
