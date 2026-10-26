/**
 * 关于页面：项目介绍（从设置页进入）。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar）：
 * 材质与滚动模糊由 HDS 统一渲染（样式见 HdsTitleBarStyle，设备不支持 IMMERSIVE 材质时
 * 自动走玻璃色兜底档），内容用 stackBuilder 承载 aboutBar（标题；返回键为 HDS 默认键）。
 * 侧滑返回是 Navigation 级能力，不受影响。
 */

import { STORE_SAFE_BOTTOM, STORE_SAFE_TOP } from '../common/Constants';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NavStackHolder } from '../service/NavStackHolder';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@ohos.base';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { InsetCard, SectionHeader, SectionFooter } from '../components/InsetCardGroup';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';
import { BarNarrowShell } from '../components/BarNarrowShell';

/** App 图标显示边长（vp）与圆角（vp）：圆角比例对齐系统图标遮罩 */
const APP_ICON_SIZE: number = 88;
const APP_ICON_RADIUS: number = 22;

@Component
export struct AboutPage {
  /** 状态栏高度（vp）：HDS 标题栏 avoidLayoutSafeArea 后栏顶 = safeTop，内容让位量要含它 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：内容末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 应用版本号（如「版本：1.0.2」）：从 bundleManager 读，跟着 app.json5 走，不在页面里写死 */
  @State appVersion: string = '';
  /** 滚动控制器：bindToScrollable 绑给 HDS 标题栏，滚动模糊效果依赖此绑定 */
  private aboutScroller: Scroller = new Scroller();

  /**
   * 自绘顶栏渐变模糊层进度更新器 + 校准（四页签同款）：onDidScroll /
   * onScrollStop 命令式驱动 opacity（不标 @State，滚动高频回调零重建）；
   * yOffset 0 → TITLE_BLUR_END_VP 线性映射 0 → 1（updater 内截断，
   * 边缘回弹负偏移归零 = 死区）。
   */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.aboutScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  /**
   * 子页转场的横移量（相对页面自身宽度）：常驻 '0%'，
   * 转场代理里按 push/pop 方向临时改写（见 navTransitionDelegate）。
   */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    // 挂载前先存当前偏移对应的进度（updater 未挂载只存值，挂载时 initializeModifier
    // 补上），防「已滚过再进页」首帧缺模糊。
    this.syncTopBlurProgress();
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

  /**
   * 标题栏内容（titleBar 的 stackBuilder 承载）：「关于」标题（返回键为 HDS 默认键）。
   * 不放版本等文字 —— 页面主体里已经有大标题。
   */
  @Builder
  aboutBar() {
    NavTitleRow({ title: '关于' })
  }

  /** 标题行收窄容器（BarNarrowShell 共用件，平板模式宽度适配） */
  @Builder
  aboutBarNarrow() {
    BarNarrowShell({ bar: (): void => {
      this.aboutBar()
    } })
  }

  /**
   * App 图标：分层图标 = 背景层 + 前景层，按系统同款圆角比例裁切
   * （clip 到圆角内），再补一层柔和阴影让它「浮」在卡片上。
   */
  @Builder
  appIcon() {
    Stack() {
      Image($r('app.media.app_icon_bg'))
        .width(APP_ICON_SIZE)
        .height(APP_ICON_SIZE)
        .objectFit(ImageFit.Cover)
      Image($r('app.media.app_icon_fg'))
        .width(APP_ICON_SIZE)
        .height(APP_ICON_SIZE)
        .objectFit(ImageFit.Cover)
    }
    .width(APP_ICON_SIZE)
    .height(APP_ICON_SIZE)
    .borderRadius(APP_ICON_RADIUS)
    .clip(true)
    .shadow({ radius: 18, color: $r('app.color.shadow_color'), offsetX: 0, offsetY: 6 })
    // 图标是装饰：读屏念下面的应用名即可，别让它单独占一个焦点
    .accessibilityLevel('no')
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Scroll(this.aboutScroller) {
          Column() {
            // 顶部占位（官方沉浸口径）：开启沉浸后内容向上穿透进标题栏区域，
            // 让位不能加在滚动容器外层（否则内容被裁在栏底缘之下、材质无内容可采样），
            // 必须在页面内容内部做占位。高度 = safeTop + 56（MINI 标题栏）。
            Blank()
              .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)
              .width('100%')

            // ── 应用信息（图标 + 名称 + 版本 + 作者 / 来源 + 一句话简介）──
            // 让位结构与 InsetCard 同款（外层 Row padding 16、内层 Column layoutWeight
            // 承底色）：不能用 width('100%') + margin —— 百分比宽不含外边距，底色会
            // 向右溢出 16vp，与下方 InsetCard 宽窄不一致。
            Row() {
              Column() {
                this.appIcon()
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
                Text('github.com/bbplayer-app/BBPlayer')
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .margin({ top: 4 })
                Text('一款基于 HarmonyOS 的 B 站第三方音乐播放器，默认匿名访问 B 站音频资源，也可扫码登录解锁更高音质。')
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .lineHeight(18)
                  .textAlign(TextAlign.Center)
                  .padding({ left: 24, right: 24 })
                  .margin({ top: 12, bottom: 24 })
              }
              .layoutWeight(1)
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(12)
              .padding({ left: 16, right: 16, top: 24 })
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .padding({ left: 16, right: 16 })

            // ── 项目说明 ──
            SectionHeader({ headerText: '项目说明' })
            InsetCard() {
              Text('本项目为开源的学习交流项目，界面与交互针对 HarmonyOS 手机端设计，播放、下载、歌单等数据均保存在设备本地。应用默认以匿名 + buvid 身份访问 B 站接口（可选扫码登录，凭据仅保存在本机），不收集、不上传任何用户数据。')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .lineHeight(18)
                .width('100%')
                .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            }
            SectionFooter({ noteText: '本项目与哔哩哔哩官方无关，音频内容版权归原作者所有，请勿将下载内容用于商业用途。' })
          }
          .width('100%')
          // 内容末尾让开底部手势区（本页内容到底即结束，不再整屏避让）
          .padding({ bottom: this.safeBottom + 16 })
        }
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        // 边界回弹：内容超屏可滚时，到顶/到底的反馈动效
        .edgeEffect(EdgeEffect.Spring)
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
        // 根 Stack 默认居中对齐，直接给 Scroll 挂上限即可。
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
        // 标题栏让位已内移为内容首部占位（见 Column 首子），不在滚动容器上加 padding。
        // 逐帧驱动自绘渐变模糊层（Scroll 版 onDidScroll 三参签名
        // (xOffset, yOffset, state)；onDidScroll 在偏移已应用后回调）。
        .onDidScroll((xOffset: number, yOffset: number, scrollState: ScrollState): void => {
          this.syncTopBlurProgress();
        })
        .onScrollStop((): void => {
          // Idle 校准终态：兜住 Fling 期丢帧 / 死区过滤累计的偏差。
          this.syncTopBlurProgress();
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      // 顶栏渐变模糊层：盖 Scroll 内容之上（z 序低于 HDS
      // titleBar），进度由 onDidScroll/onScrollStop 经 topBlurUpdater 命令式驱动；
      // 本页内容不足一屏时 Scroll 不可滚、进度恒 0（透明无副作用）。
      TopGradientBlurOverlay({
        barHeightVp: this.safeTop + NAV_TITLE_BAR_HEIGHT,
        updater: this.topBlurUpdater
      })
    }
    // HDS 沉浸光感标题栏：材质 / 滚动模糊 / 温控统一由 HdsTitleBarStyle 决策
    // （设备不支持 IMMERSIVE 时自动走玻璃色兜底档，见该文件注释）。
    // 内容用 stackBuilder 承载 aboutBarNarrow（收窄容器内标题与内容列同宽对齐）。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        // 箭头包裹保证 builder 内 this 指向本组件（裸引用会丢失 this）
        stackBuilder: (): void => {
          this.aboutBarNarrow();
        }
      }
    })
    // 返回键：使用 HDS 默认返回键（"<" 系统样式，位置由 HDS 管理以避开状态栏）。
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页滚动容器交给 HDS 联动
    .bindToScrollable([this.aboutScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 系统返回拦截：播放页 overlay 打开时吞掉返回并发收起请求（留在本页），
    // 否则走默认 pop —— 详见 utils/SubPageBackPress。
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让：目的地级声明布局扩展进系统安全区（官方组件级沉浸口径，
    // faqs-arkui-1095 场景三同款）；窗口全屏下页面级为既成事实，此处显式化
    // 并接管组件级 safeAreaPadding。内容层避让由 plain padding 自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function AboutPageBuilder(): void {
  AboutPage()
}


/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const AboutPageWrapped: WrappedBuilder<[]> = wrapBuilder(AboutPageBuilder);

