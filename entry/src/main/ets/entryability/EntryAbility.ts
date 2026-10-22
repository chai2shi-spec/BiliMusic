/**
 * 应用入口（Stage 模型）。替代原 Android Application / MainActivity 与 PC 版 Electron 容器。
 * 负责初始化全局依赖、申请必要权限、加载首页。
 */

import {
  UIAbility,
  Configuration,
  ConfigurationConstant
} from '@kit.AbilityKit';
import window from '@ohos.window';
import display from '@ohos.display';
import hiAppEvent from '@ohos.hiviewdfx.hiAppEvent';
import { BusinessError } from '@ohos.base';
import { AppContainer } from '../service/AppContainer';
import { AppPreferences } from '../preferences/AppPreferences';
import { AppSettings } from '../model/MusicModels';
import { publishThemeColors, isAppDark } from '../common/ThemeColors';
import { MusicPlayer } from '../player/MusicPlayer';
import { FormFactorHolder } from '../service/FormFactorHolder';
import { STORE_SAFE_TOP, STORE_SAFE_BOTTOM, STORE_NAV_BAR_BOTTOM, STORE_NAV_INDICATOR_BOTTOM, STORE_WINDOW_WIDTH_VP, STORE_BAR_LAYOUT, STORE_PROGRESS_STYLE, STORE_MINI_BAR_PROGRESS, STORE_MINI_BAR_AUTO_EXPAND, STORE_PLAYBACK_SPEED_ENABLED, STORE_PLAYBACK_SPEED, STORE_APP_FOREGROUND, STORE_AUDIO_MIX_ENABLED } from '../common/Constants';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    // 深色模式已适配：不再强制浅色，应用跟随系统颜色模式。
    // 页面用色全部走 $r('app.color.*') 语义 token，深色值在 resources/dark/element/color.json
    // 中覆盖（未覆盖的品牌色 / 播放页白色系自动回落 base）；$r('sys.color.*') 系统资源
    // 本身随系统深浅切换，无需代码干预。
    this.registerAppFreezeWatcher();
    // 折叠态适配层（2026-10-22 重写）：App 生命周期常驻的折叠开合唯一真源，
    // 必须在首帧前 init —— Index 的壳选择（折叠屏展开一律手机壳）与播放页
    // 分栏都读 STORE_FOLD_EXPANDED，晚了会先渲染错壳再跳变。display API
    // 不依赖窗口，onCreate 即可调用。失败内部兜底为「非折叠」。
    FormFactorHolder.init();
  }

  /**
   * （2026-10-16 AppFreeze 加固）订阅系统 APP_FREEZE 事件。
   *
   * 背景：应用市场审核驳回的 THREAD_BLOCK_6S 在送审真机上没有留下可拉取的 faultlog，
   * 只能靠应用侧 watcher 兜底 —— 下次冻结真正发生时把事件参数打进 error 日志，
   * 复测 / 回归时用 hdc 日志即可反推卡顿点（主线程当时卡在哪个调用栈）。
   * 注册失败不影响应用运行。
   */
  private registerAppFreezeWatcher(): void {
    try {
      const filter: hiAppEvent.AppEventFilter = {
        domain: hiAppEvent.domain.OS,
        names: [hiAppEvent.event.APP_FREEZE]
      };
      const watcher: hiAppEvent.Watcher = {
        name: 'appFreezeWatcher',
        appEventFilters: [filter],
        onReceive: (domain: string, appEventGroups: Array<hiAppEvent.AppEventGroup>): void => {
          console.error(`[AppFreeze] domain=${domain} events=${JSON.stringify(appEventGroups)}`);
        }
      };
      hiAppEvent.addWatcher(watcher);
    } catch (e) {
      console.error(`register appFreezeWatcher failed: ${JSON.stringify(e)}`);
    }
  }

  onDestroy(): void {
    MusicPlayer.getInstance().release();
  }

  /**
   * 2026-10-08（B4 记忆播放兜底）：应用退后台时立即把播放快照落盘。
   *
   * 为什么必须有这个钩子：播放中的进度落盘走 timeUpdate 的 5s 粗节流，
   * 「正在播放 → 直接划卡杀进程」会丢最后一拍；且 onDestroy 在划卡时
   * **不保证被调**（进程可能直接被杀），onBackground 是最后一个可靠时机。
   * savePlayerStateNow 内部 fire-and-forget，偶发失败只记日志不阻塞退后台。
   */
  onForeground(): void {
    // 前后台标志（2026-10-21 后台耗电优化）：PlayBar/CoverDisc/PlayButton 动画门控
    // 与 MusicPlayer 落盘节流（5s/30s）的依据。启动时系统也会回调本钩子，
    // 组件 @StorageProp 默认 true 与之双保险；标志缺失一律按前台处理。
    AppStorage.setOrCreate(STORE_APP_FOREGROUND, true);
  }

  onBackground(): void {
    // 退后台：动画门控关闭（animator/呼吸链冻结，回前台续转）
    AppStorage.setOrCreate(STORE_APP_FOREGROUND, false);
    try {
      MusicPlayer.getInstance().savePlayerStateNow();
    } catch (e) {
      console.error(`save player state on background failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 系统配置变化（最常见：系统深浅模式切换）。主题色的衍生色变体
   * （deep / surface 各配浅深两套值）要按新深浅重发布 —— 跟随系统模式下
   * 系统切深色而 App 不重发布的话，封面占位 / 深色徽标会滞留浅色变体；
   * 强制浅 / 深模式下解析结果与系统深浅无关，重发布无害。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    try {
      const settings: AppSettings = AppPreferences.getSettings();
      const sysDark: boolean =
        newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      publishThemeColors(settings.themeColor, isAppDark(settings.themeMode, sysDark));
    } catch (e) {
      console.error(`re-publish theme colors on config change failed: ${JSON.stringify(e)}`);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // ① 窗口级全屏布局：把页面的布局范围从「安全区」扩展为「整个窗口」（含状态栏 / 导航栏），
    //    这是「内容能绘制到底部手势条下方」的前提。开启后系统不再帮忙避让，
    //    避让改由 Index 的根容器 / 页签层按避让区高度手动补 padding。
    this.enableFullScreenLayout(windowStage);
    // ② 必须在 loadContent 之前把避让区尺寸写进 AppStorage：首页 build 的首帧就要用它
    //    算「根容器底部让位 / 页签层顶部让位」，晚一拍会看到内容先贴边再弹回来。
    this.publishSafeArea(windowStage);
    // ③ 2026-10-17 启动优化：只等 Preferences（首帧必须就位的主题模式 / 主题色 /
    //    底栏布局都只依赖它），RDB / 下载表 / AVSession 等重初始化与页面加载并行。
    //    原实现把 AppContainer 全量 init 串在 loadContent 之前，是启动超时的主因。
    AppPreferences.initPreferences(this.context)
      .then((): void => {
        // 偏好就绪后、首帧加载前恢复持久化的主题模式（浅色 / 深色 / 跟随系统）。
        // setColorMode 是运行时设置不落盘，每次启动都要重放，否则会退回跟随系统；
        // 放在 loadContent 之前是为了首页首帧就用对的颜色模式渲染，避免先深后浅跳变。
        const settings: AppSettings = AppPreferences.getSettings();
        AppPreferences.applyThemeMode(this.context, settings.themeMode);
        // 主题色同批发布（loadContent 前）：组件 @StorageProp 初始值只是占位，
        // 真值必须在首帧 build 前就位，否则先渲染粉再跳变到所选主题色。
        // deep / surface 按当前生效深浅取变体，判定与主题模式三态一致。
        const sysDark: boolean =
          this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
        publishThemeColors(settings.themeColor, isAppDark(settings.themeMode, sysDark));
        // 底部导航布局（设置页可切）：首帧前首发 AppStorage 镜像，
        // Index 的 @StorageProp 初值只是占位，真值必须首帧 build 前就位。
        AppStorage.setOrCreate(STORE_BAR_LAYOUT, settings.barLayout);
        // 播放页进度条样式（设置页可切）同批首发：ControlAreaComponent 的
        // @StorageProp 初值只是占位，真值必须首帧 build 前就位。
        AppStorage.setOrCreate(STORE_PROGRESS_STYLE, settings.progressStyle);
        // 迷你栏进度指示开关（设置页可切）同批首发：PlayBar 的 @StorageProp
        // 初值只是占位，真值必须首帧 build 前就位，否则关开关的用户启动时
        // 会先看到进度条再消失。
        AppStorage.setOrCreate(STORE_MINI_BAR_PROGRESS, settings.miniBarProgress);
        // 迷你栏自动展开收起开关同批首发：Index 的 @StorageProp 初值只是占位，
        // 真值必须首帧 build 前就位，否则关掉开关的用户启动后第一下滑动仍会触发收放。
        AppStorage.setOrCreate(STORE_MINI_BAR_AUTO_EXPAND, settings.miniBarAutoExpand);
        // 倍速播放开关 + 倍速值（设置页可改）：播放页 ControlAreaComponent 的
        // @StorageProp 初值只是占位，真值必须首帧 build 前就位；倍速值同时是
        // MusicPlayer.init 恢复 playbackSpeed 字段的数据源。
        AppStorage.setOrCreate(STORE_PLAYBACK_SPEED_ENABLED, settings.speedEnabled);
        AppStorage.setOrCreate(STORE_PLAYBACK_SPEED, settings.playbackSpeed);
        // 「与其他应用同时播放」开关同批首发：MusicPlayer 在 AVPlayer prepared 时
        // 读它决定 audioInterruptMode（INDEPENDENT/SHARE），首播前必须就位。
        AppStorage.setOrCreate(STORE_AUDIO_MIX_ENABLED, settings.audioMixEnabled);
        // ④ 全量初始化与页面加载并行（fire-and-forget，不阻塞 loadContent）。
        //    时序保障：initRest 只依赖上面已就位的 Preferences，且权限请求已并入其链首。
        AppContainer.initRest(this.context)
          .then((): void => {
            // 启动时自动播放（设置页开关，默认关）：播放器恢复完成后才触发，
            // 无播放快照时 play() 内部静默 no-op，
            // 初始化失败的 catch 分支不经过这里，天然不触发。
            if (settings.autoPlayOnStart) {
              MusicPlayer.getInstance().play();
            }
          })
          .catch((e: Error): void => {
            console.error(`AppContainer initRest failed: ${JSON.stringify(e)}`);
          });
        // ⑤ 立即加载首页（不再等 initRest）
        windowStage.loadContent('pages/Index', (err: BusinessError): void => {
          if (err.code) {
            console.error(`Failed to load content. code: ${err.code}, message: ${err.message}`);
          }
        });
      })
      .catch((e: Error): void => {
        console.error(`initPreferences failed: ${JSON.stringify(e)}`);
        // Preferences 初始化失败也要让应用可进入（页面内读偏好有各自兜底）
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
    * 同时**分开**发布两个来源（2026-10-22 修「大屏展开底部导航不居中」）：
    *   STORE_NAV_BAR_BOTTOM       = TYPE_SYSTEM 底部矩形（>0 即三键导航）
    *   STORE_NAV_INDICATOR_BOTTOM = TYPE_NAVIGATION_INDICATOR 底部矩形（手势指示条）
    * 悬浮胶囊按「避让区来源」判导航模式选避让策略，不再按固定高度阈值猜 ——
    * 阔折叠 / 阔直板大屏展开态的高度与手机不同，按阈值猜必错。
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
      const navBarBottomVp: number = sys.bottomRect.height / density;
      const indicatorBottomVp: number = indicator.bottomRect.height / density;
      const bottomVp: number = Math.max(navBarBottomVp, indicatorBottomVp);
      AppStorage.setOrCreate(STORE_SAFE_TOP, topVp);
      AppStorage.setOrCreate(STORE_SAFE_BOTTOM, bottomVp);
      AppStorage.setOrCreate(STORE_NAV_BAR_BOTTOM, navBarBottomVp);
      AppStorage.setOrCreate(STORE_NAV_INDICATOR_BOTTOM, indicatorBottomVp);
      // 窗口内容区宽度（vp）：悬浮胶囊「居中 sideMargin」公式的输入（见 Constants
      // 的 STORE_WINDOW_WIDTH_VP 注释）。窗口全屏布局 → windowRect 宽 = HdsTabs 宽。
      // 后续折叠开合 / 分屏 / 转屏由 Index 的 HdsTabs.onAreaChange 持续回写。
      const windowWidthVp: number = win.getWindowProperties().windowRect.width / density;
      AppStorage.setOrCreate(STORE_WINDOW_WIDTH_VP, windowWidthVp);
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`writeSafeArea failed: ${msg}`);
    }
  }
}
