/**
 * 全局确认弹窗（替代系统 `showAlertDialog`）。
 *
 * 为什么不用系统 AlertDialog：
 *   1. 系统弹窗的标题 / 正文只接受 `ResourceStr`，**无法自定义字体颜色**；
 *   2. 底色不走应用资源限定，深浅色下与页面不一致。
 * 本组件自绘内容：
 *   - 底色 `app.color.bg_card`（浅色 #FFFFFFFF / 深色 #FF1E1E24）→ 随主题深浅色切换；
 *   - 标题 / 正文 / 按钮文字统一主题色主色（STORE_THEME_PRIMARY，默认粉 #FB7299）。
 *
 * 交互与系统弹窗对齐：居中模态、点遮罩可关（autoCancel）、左右按钮（取消 / 确认），
 * 点击按钮先关闭弹窗再执行回调（回调里的 AppToast 不会被弹层盖住）。
 *
 * （阶段 2 迁移，2026-10-11：菜单弹窗 showAppMenuDialog 已删除 —— 菜单类交互
 * 全部迁移到 `AppMenu.ets` 的 bindMenu + Menu/MenuItem 标准菜单；双按钮确认
 * 仍走本文件的 showAppAlertDialog。以下崩溃史注释是重要背景，保留勿删。）
 *
 * ⚠️⚠️ 为什么用 `CustomDialogController` 而不是 `openCustomDialog`（**踩过的闪退坑**）
 *
 * 最初实现是 `promptAction.openCustomDialog({ builder: 全局 @Builder })`，
 * 结果**点任意条目「⋯」必闪退**，日志：
 *     TypeError: Cannot read property observeComponentCreation2 of undefined
 *
 * 根因（华为官方 FAQ faqs-arkui-1159）：`@Builder` 自定义构建函数**只能在所属组件的
 * build 方法和其他自定义构建函数内调用，不允许在组件外调用**。而本文件的两个
 * `@Builder` 是**模块级全局函数**，把它们交给 `openCustomDialog` 在弹窗渲染时
 * 找不到父组件的 `observeComponentCreation2` 上下文 → 直接抛 TypeError 崩掉。
 * 官方给的解法只有一种：把 `@Builder` 挪进 `@Component` 结构体内部，
 * 于是每个调用页面都得各自持有一个 controller —— 20+ 处调用点全部要改，且
 * 「title/message/按钮」这些数据也没法再走模块级单槽传。
 *
 * 改用 `@CustomDialog` + `CustomDialogController`（官方推荐的自定义弹窗方案）：
 * CustomDialog 本身就是**结构体**，它的 `build` 由 controller.open() 触发执行，
 * 不存在「组件外调用 @Builder」的问题，因此可以安全地被任意页面复用。
 *
 * 但换 `@CustomDialog` 后还有**第二个坑**（比闪退更隐蔽）：
 * 官方明确规定「CustomDialogController 仅在作为 @Component struct 的**成员变量**、
 * 且**在组件内部定义时赋值才有效**」。若图省事把 controller 写成模块级
 * `const c = new CustomDialogController({...})`，**编译会过、`open()` 也不抛异常，
 * 但弹窗永远不显示** —— 静默失效，连日志都没有。所以 controller 必须放在
 * `AppDialogHost` 组件内（见下），模块级 show* 函数经静态引用 `dialogHost` 驱动它。
 *
 * 好处：
 *   1. `showAppAlertDialog(uiContext, options)` **导出签名完全不变** → 调用点零改动；
 *   2. controller 持有真正的组件上下文，不会再抛 observeComponentCreation2；
 *   3. `close()` 是同步的，不再需要原来那套「id 未就绪先挂起、Promise 回来再补关」
 *      的竞态兜底（`alertDialogId` / `alertClosePending` 全部删掉）。
 *
 * ⚠️ 部署要求：`AppDialogHost` 必须挂在组件树里（已挂在 `Index.ets` 根部，与 AppToast 同级）。
 * 否则 `dialogHost` 为 null，弹窗不显示并打一行 error 日志。
 *
 * ⚠️ controller 一经创建**绝不能重新赋值**：官方明确「复用场景下给 controller 重新赋值
 * 会导致旧弹窗关不掉」。所以这里只在组件里 new 一次，每次弹窗只改它读取的模块级
 * 数据槽（`alertOptions`）再 `open()`。
 */

import { UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { STORE_THEME_PRIMARY } from '../common/Constants';

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
 * 弹窗数据槽：模块级单槽，写入后再 `controller.open()`。
 *
 * CustomDialog 的 build 只在 open 时执行，读到的就是当次的值；同一时刻只可能存在
 * 一个弹窗（模态阻塞），单槽不会串内容。
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
 * 确认弹窗内容。
 *
 * 宽度写在**自定义组件自己的根节点**上（`CustomDialogControllerOptions` 没有 width
 * 字段，弹窗尺寸由自定义组件决定），86% 与原先 `openCustomDialog` 的观感一致。
 */
@CustomDialog
struct AppAlertDialogRoot {
  /**
   * 编译器硬性要求：`@CustomDialog` 修饰的结构体**必须**声明一个
   * `CustomDialogController` 类型的属性（否则报 10905211）。
   *
   * 这里声明但**不赋值、不使用**：弹窗的实际开关由模块级单例
   * `alertController` 负责（它才是 open/close 的持有者）。
   */
  controller?: CustomDialogController;
  /** 主题色主色：弹窗标题 / 正文 / 按钮文字跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';

  build() {
    Column() {
      // 文本区
      Column() {
        Text(alertOptions.title)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.themePrimary)
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(alertOptions.message)
          .fontSize(13)
          .fontColor(this.themePrimary)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
          .width('100%')
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 24, bottom: 20 })

      Divider()
        .color($r('app.color.bg_divider'))

      // 按钮区：左右等分，中间竖分隔
      Row() {
        Text(alertOptions.primaryButton.value)
          .fontSize(16)
          .fontColor(this.themePrimary)
          .textAlign(TextAlign.Center)
          .height(48)
          .layoutWeight(1)
          .onClick((): void => {
            onAlertButtonClick(alertOptions.primaryButton);
          })
        Divider()
          .vertical(true)
          .height(48)
          .color($r('app.color.bg_divider'))
        Text(alertOptions.secondaryButton.value)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.themePrimary)
          .textAlign(TextAlign.Center)
          .height(48)
          .layoutWeight(1)
          .onClick((): void => {
            onAlertButtonClick(alertOptions.secondaryButton);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('86%')
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(24)
    .clip(true)
  }
}

/**
 * 弹窗宿主组件：**唯一持有 CustomDialogController 的地方**。
 *
 * ⚠️⚠️ 为什么必须有这个组件（第二个踩过的坑）
 * 官方明确规定：「CustomDialogController 仅在作为 @CustomDialog 和 @Component struct 的
 * **成员变量**，且**在 @Component struct 内部定义时赋值才有效**」。
 * 上一版把两个 controller 放在**模块级**（`const alertController = new CustomDialogController(...)`），
 * 编译能过、`open()` 也不抛异常，但**弹窗永远不显示**（静默失效 —— 连报错都没有，
 * 比闪退更难查）。因此 controller 必须挪进组件内。
 *
 * 那「模块级函数怎么拿到组件内的 controller」？用一个静态注册表：
 *   宿主组件 `aboutToAppear` 时把自己 register 进来，模块级 show* 函数再回调它。
 * 这样 `showAppAlertDialog(uiContext, options)` 的**导出签名完全不变**，
 * 8 个页面 20+ 处调用点一行都不用改。
 *
 * 宿主组件本身不渲染任何东西（`build()` 返回空 Column）—— 它只是 controller 的容器，
 * 真正的 UI 由 controller.open() 拉起。挂在 `Index.ets` 根部（与 AppToast 同级）。
 */
@Component
export struct AppDialogHost {
  /**
   * 确认弹窗 controller。
   *
   * ⚠️ `builder` 必须写 `AppAlertDialogRoot()` **不带 `{}`**：struct 的构造签名第一个
   * 形参是 `parent?: LocalStorage`，传 `{}` 会被解析成 LocalStorage 实参而报错
   * （Argument of type '{}' is not assignable to parameter of type 'LocalStorage'）。
   *
   * ⚠️ 也**绝不能重新赋值**（官方明确：全局/复用场景下重新赋值会导致旧弹窗关不掉）。
   * 弹窗内容与按钮靠模块级 `alertOptions` 单槽在 open 前写入。
   *
   * `cancel`：点遮罩关闭时的回调，只复位标记；具体关闭由系统完成。
   * `customStyle: true`：底色 / 圆角 / 宽高都由自定义组件自己声明。
   */
  private alertController: CustomDialogController = new CustomDialogController({
    builder: AppAlertDialogRoot(),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true,
    cancel: (): void => {
      alertOpened = false;
    }
  });

  aboutToAppear(): void {
    // 注册自己，供模块级 show* 函数回调（页面就绪后才会有人调 open）
    dialogHost = this;
  }

  aboutToDisappear(): void {
    dialogHost = null;
  }

  /** 供模块级 showAppAlertDialog 调用（成员方法，才能碰组件内的 controller） */
  openAlert(): void {
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
    try {
      this.alertController.close();
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

/** 按钮点击：先关弹窗，再跑业务回调 */
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