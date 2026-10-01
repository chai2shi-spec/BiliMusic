/**
 * 应用入口（Stage 模型）。替代原 Android Application / MainActivity 与 PC 版 Electron 容器。
 * 负责初始化全局依赖、申请必要权限、加载首页。
 */

import { UIAbility, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import window from '@ohos.window';
import display from '@ohos.display';
import { BusinessError } from '@ohos.base';
import { AppContainer } from '../service/AppContainer';
import { AppPreferences } from '../preferences/AppPreferences';
import { MusicPlayer } from '../player/MusicPlayer';
import { STORE_SAFE_TOP, STORE_SAFE_BOTTOM } from '../common/Constants';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    // 深色模式已适配：不再强制浅色，应用跟随系统颜色模式。
    // 页面用色全部走 $r('app.color.*') 语义 token，深色值在 resources/dark/element/color.json
    // 中覆盖（未覆盖的品牌色 / 播放页白色系自动回落 base）；$r('sys.color.*') 系统资源
    // 本身随系统深浅切换，无需代码干预。
  }

  onDestroy(): void {
    MusicPlayer.getInstance().release();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.requestNeededPermissions();
    // ① 窗口级全屏布局：把页面的布局范围从「安全区」扩展为「整个窗口」（含状态栏 / 导航栏），
    //    这是「内容能绘制到底部手势条下方」的前提。开启后系统不再帮忙避让，
    //    避让改由 Index 的根容器 / 页签层按避让区高度手动补 padding。
    this.enableFullScreenLayout(windowStage);
    // ② 必须在 loadContent 之前把避让区尺寸写进 AppStorage：首页 build 的首帧就要用它
    //    算「根容器底部让位 / 页签层顶部让位」，晚一拍会看到内容先贴边再弹回来。
    this.publishSafeArea(windowStage);
    // 必须在页面加载前完成全局依赖（Preferences / RDB / 播放器）初始化，
    // 否则页面 aboutToAppear 时读取偏好或数据库会抛 “未初始化”。
      AppContainer.init(this.context)
      .then((): void => {
        // 偏好就绪后、首帧加载前恢复持久化的主题模式（浅色 / 深色 / 跟随系统）。
        // setColorMode 是运行时设置不落盘，每次启动都要重放，否则会退回跟随系统；
        // 放在 loadContent 之前是为了首页首帧就用对的颜色模式渲染，避免先深后浅跳变。
        AppPreferences.applyThemeMode(this.context, AppPreferences.getSettings().themeMode);
        windowStage.loadContent('pages/Index', (err: BusinessError): void => {
          if (err.code) {
            console.error(`Failed to load content. code: ${err.code}, message: ${err.message}`);
          }
        });
      })
      .catch((e: Error): void => {
        console.error(`AppContainer init failed: ${JSON.stringify(e)}`);
        windowStage.loadContent('pages/Index', (err: BusinessError): void => {
          if (err.code) {
            console.error(`Failed to load content. code: ${err.code}, message: ${err.message}`);
          }
        });
      });
  }

  /**
   * 开启窗口级全屏（沉浸式）布局。
   *
   * setWindowLayoutFullScreen(true) 之后，窗口内容区 = 整块屏幕，
   * **页面的所有组件布局范围从「安全区」扩展为「整个窗口」**（含状态栏与导航栏区域），
   * 随之而来的代价是：系统不再替应用避让系统栏 —— 状态栏会压住顶部内容、
   * 底部手势条 / 三键导航栏会压住底部控件，必须由页面自己按避让区高度补 padding
   * （本项目统一在 pages/Index.ets 的根容器与页签层上补）。
   *
   * 与 expandSafeArea 的区别（官方「沉浸式页面开发实践」方案一 vs 方案二）：
   *   expandSafeArea —— 只把**当前组件**延伸到系统栏，其它组件仍在安全区布局，无需避让；
   *   本方法        —— 把**整个窗口**的布局范围铺满全屏，所有页面都要自己避让。
   * 两者不要混用：本项目走窗口全屏方案，页面里**不再出现 expandSafeArea**。
   */
  private enableFullScreenLayout(windowStage: window.WindowStage): void {
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true)
        .then((): void => {
          // 全屏生效后避让区数值才最终稳定，补读一次覆盖掉可能读早了的旧值
          this.writeSafeArea(win);
          console.info('setWindowLayoutFullScreen(true) done');
        })
        .catch((err: BusinessError): void => {
          console.error(`setWindowLayoutFullScreen failed: ${err.code} ${err.message}`);
        });
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`enableFullScreenLayout failed: ${msg}`);
    }
  }

  /**
   * 读取系统避让区尺寸并发布到 AppStorage（单位 vp）。
   *
   * 为什么必须自己读：窗口开了全屏布局之后内容不再自动避让，根容器与页签层的留白尺寸
   * 只能从窗口避让区取。
   *   bottom = max(TYPE_SYSTEM.bottomRect,               （三键导航时 = 导航栏高度）
   *                TYPE_NAVIGATION_INDICATOR.bottomRect) （手势导航时 = 指示条区域高度）
   * 取两者较大值，三键 / 手势两种导航模式都能拿到正确高度。
   *
   * top（状态栏高度）由页签层消费，用来把 Tabs 内容顶到状态栏下方。
   *
   * 换算用 densityPixels 手算而不用 px2vp()：本文件在 Ability（非 UI 上下文）里执行，
   * px2vp 依赖 UIContext，这里拿不到（页面侧用 UIContext.px2vp，见 Index.ets）。
   *
   * 注意：这里只做**一次同步首发**，avoidAreaChange 监听的注册在 pages/Index.ets
   * （页面侧能拿到 UIContext，且首页是常驻根页面），避免两处重复监听、重复写同一个 key。
   */
  private publishSafeArea(windowStage: window.WindowStage): void {
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      this.writeSafeArea(win);
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`publishSafeArea failed: ${msg}`);
    }
  }

  private writeSafeArea(win: window.Window): void {
    try {
      const density: number = display.getDefaultDisplaySync().densityPixels;
      const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicator: window.AvoidArea =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const topVp: number = sys.topRect.height / density;
      const bottomVp: number = Math.max(sys.bottomRect.height, indicator.bottomRect.height) / density;
      AppStorage.setOrCreate(STORE_SAFE_TOP, topVp);
      AppStorage.setOrCreate(STORE_SAFE_BOTTOM, bottomVp);
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`writeSafeArea failed: ${msg}`);
    }
  }


  private requestNeededPermissions(): void {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const permissions: Array<Permissions> = [
        'ohos.permission.KEEP_BACKGROUND_RUNNING'
      ];
      atManager.requestPermissionsFromUser(this.context, permissions, (err: BusinessError, data: object): void => {
        if (err) {
          console.error(`requestPermissionsFromUser failed: ${err.code} ${err.message}`);
        } else {
          console.info(`permissions result: ${JSON.stringify(data)}`);
        }
      });
    } catch (e) {
      console.error(`requestNeededPermissions exception: ${JSON.stringify(e)}`);
    }
  }
}
