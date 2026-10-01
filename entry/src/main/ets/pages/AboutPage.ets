/**
 * 关于页面：项目介绍（从设置页进入）。
 *
 * 内容为静态展示：应用信息（名称 / 版本）、功能特性、项目说明与免责声明。
 * 返回走系统侧滑（与 RecentPage 一致，标题栏整体隐藏）。
 */

import { STORE_SAFE_BOTTOM, STORE_SAFE_TOP } from '../common/Constants';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@ohos.base';

/** 功能特性条目：一行一条，纯展示 */
interface AboutFeature {
  title: string;
  detail: string;
}

const ABOUT_FEATURES: AboutFeature[] = [
  { title: '在线搜索与播放', detail: '搜索 B 站视频音频流，即点即播，支持自动连播' },
  { title: '歌词显示', detail: '自动匹配歌词，播放页逐行滚动' },
  { title: '歌单管理', detail: '自建歌单收藏喜欢的歌曲' },
  { title: '离线下载', detail: '按音质档位下载到本地，支持仅 WiFi 下载' },
  { title: '最近播放', detail: '记录播放历史，快速回放' },
  { title: '定时停止', detail: '到点自动停止播放' }
];

@Component
export struct AboutPage {
  /** 状态栏高度（vp）：内容区要整体落在状态栏下方，由本页自己顶下来 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：内容末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 应用版本号（如「版本：1.0.2」）：从 bundleManager 读，跟着 app.json5 走，不在页面里写死 */
  @State appVersion: string = '';

  /**
   * 子页转场的横移量（相对页面自身宽度）：常驻 '0%'，
   * 转场代理里按 push/pop 方向临时改写（见 navTransitionDelegate）。
   */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info: bundleManager.BundleInfo): void => {
        this.appVersion = info.versionName.length > 0 ? `版本：${info.versionName}` : '';
      })
      .catch((e: BusinessError): void => {
        // 拿不到就空着，不影响其它内容展示
        console.error(`getBundleInfoForSelf failed: ${e.code} ${e.message}`);
      });
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut。
   * · push 入场：先把页面挪到屏幕右侧外（'100%'），event 闭包内回到 '0%'，
   *   系统按闭包内的状态变化生成 400ms EaseOut 过渡；
   * · pop 出场（含侧滑返回手势触发的返回）：反向滑回右侧，与手势方向一致；
   * · 其余场景（本页被上层页覆盖 / 上层页返回后重新露出）返回 undefined，
   *   走系统默认转场。
   */
  private navTransitionDelegate(op: NavigationOperation,
    isEnter: boolean): Array<NavDestinationTransition> | undefined {
    if (op === NavigationOperation.PUSH && isEnter) {
      this.navTransX = '100%';
      const enter: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '0%';
        }
      };
      const transitions: Array<NavDestinationTransition> = [enter];
      return transitions;
    }
    if (op === NavigationOperation.POP && !isEnter) {
      const exit: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '100%';
        }
      };
      const transitions: Array<NavDestinationTransition> = [exit];
      return transitions;
    }
    return undefined;
  }

  build() {
    NavDestination() {
      Stack() {
        Scroll() {
          Column() {
            Text('关于')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .padding({ left: 16, top: 14, bottom: 10 })

            // ── 应用信息卡片 ──
            Column() {
              Text('♪')
                .fontSize(34)
                .fontColor($r('app.color.brand_on'))
                .width(72)
                .height(72)
                .borderRadius(20)
                .backgroundColor($r('app.color.bili_pink'))
                .textAlign(TextAlign.Center)
                .margin({ top: 22 })
              Text('BiliMusic')
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .margin({ top: 12 })
              Text(this.appVersion)
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 4 })
              Text('作者：chai')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 4 })
              Text('转译自 github.com/HanversionOvO/BiliMusic')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 4 })
              Text('一款基于 HarmonyOS 的 B 站第三方音乐播放器，以匿名身份访问 B 站音频资源，无需登录。')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .lineHeight(18)
                .textAlign(TextAlign.Center)
                .padding({ left: 24, right: 24 })
                .margin({ top: 10, bottom: 22 })
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)
            .margin({ left: 12, right: 12 })
            .alignItems(HorizontalAlign.Center)

            // ── 功能特性 ──
            Column() {
              Text('功能特性')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .padding({ left: 16, top: 14, bottom: 8 })
              ForEach(ABOUT_FEATURES, (f: AboutFeature): void => {
                Row() {
                  Column() {
                    Text(f.title)
                      .fontSize(16)
                      .fontColor($r('app.color.text_primary'))
                    Text(f.detail)
                      .fontSize(13)
                      .fontColor($r('app.color.text_tertiary'))
                      .margin({ top: 4 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              }, (f: AboutFeature): string => `feature_${f.title}`)
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)
            .margin({ left: 12, right: 12, top: 10 })

            // ── 项目说明 ──
            Column() {
              Text('项目说明')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .padding({ left: 16, top: 14, bottom: 8 })
              Text('本项目为开源的学习交流项目，界面与交互针对 HarmonyOS 手机端设计，播放、下载、歌单等数据均保存在设备本地。应用以匿名 + buvid 身份访问 B 站接口，不收集、不上传任何用户数据。')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .lineHeight(18)
                .width('100%')
                .padding({ left: 16, right: 16, bottom: 8 })
              Text('本项目与哔哩哔哩官方无关，音频内容版权归原作者所有，请勿将下载内容用于商业用途。')
                .fontSize(13)
                .fontColor($r('app.color.text_tertiary'))
                .lineHeight(18)
                .width('100%')
                .padding({ left: 16, right: 16, bottom: 16 })
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)
            .margin({ left: 12, right: 12, top: 10, bottom: 20 })
          }
          .width('100%')
        }
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
        // 根 Stack 默认居中对齐，直接给 Scroll 挂上限即可。
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
      // 与 RecentPage 一致：标题栏隐藏，返回走系统侧滑；
      // 顶部留出状态栏高度的呼吸间距。
      .padding({ top: this.safeTop })
      .safeAreaPadding({ top: NAV_TITLE_BAR_HEIGHT, bottom: this.safeBottom })
    }
    .hideTitleBar(true)
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
  }
}
