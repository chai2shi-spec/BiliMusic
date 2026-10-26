/**
 * 打赏作者页（从设置页进入）：页面正中展示打赏二维码（zsm.jpg）+ 一句说明。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar）：
 * 材质由 HDS 统一渲染（样式见 HdsTitleBarStyle，设备不支持 IMMERSIVE 材质时
 * 自动走玻璃色兜底档），内容用 stackBuilder 承载 rewardBar（标题；返回键为 HDS 默认键）。
 * 侧滑返回是 Navigation 级能力，不受影响。
 *
 * 本页内容固定一屏（二维码 + 一行说明），无滚动容器：
 * 二维码水平 + 垂直居中（居中区上缘让开标题栏、下缘让开底部手势区）。
 */

import { STORE_SAFE_BOTTOM, STORE_SAFE_TOP } from '../common/Constants';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { BarNarrowShell } from '../components/BarNarrowShell';

/** 打赏二维码显示宽度（vp）：主流 360vp 屏宽下两侧各余 40vp；高度按原图宽高比自适应 */
const REWARD_IMG_WIDTH: number = 280;

@Component
export struct RewardPage {
  /** 状态栏高度（vp）：垂直居中区上缘让开标题栏（safeTop + 56） */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：居中区下缘让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;

  /**
   * 子页转场的横移量（相对页面自身宽度）：常驻 '0%'，
   * 转场代理里按 push/pop 方向临时改写（见 navTransitionDelegate）。
   */
  @State navTransX: string = '0%';

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
   * 标题栏内容（titleBar 的 stackBuilder 承载）：「打赏作者」标题（返回键为 HDS 默认键）。
   */
  @Builder
  rewardBar() {
    NavTitleRow({ title: '打赏作者' })
  }

  /** 标题行收窄容器（BarNarrowShell 共用件，平板模式宽度适配） */
  @Builder
  rewardBarNarrow() {
    BarNarrowShell({ bar: (): void => {
      this.rewardBar()
    } })
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Column() {
          // 打赏二维码（页面核心内容）：只设宽度（280vp）、高度按原图宽高比
          // 自适应；圆角裁切 + 柔和阴影（关于页 App 图标同款）让它「浮」在页面上。
          Image($r('app.media.zsm'))
            .width(REWARD_IMG_WIDTH)
            .objectFit(ImageFit.Contain)
            .borderRadius(12)
            .clip(true)
            .shadow({ radius: 18, color: $r('app.color.shadow_color'), offsetX: 0, offsetY: 6 })
            .accessibilityText('打赏二维码')

          // 一句话说明：居中灰字，不抢二维码视觉焦点
          Text('扫码打赏，支持作者继续开发')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ top: 16 })
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        // 垂直居中区上缘让开标题栏（safeTop + 56）、下缘让开底部手势区，
        // 二维码恰落在可视区正中。
        .padding({ top: this.safeTop + NAV_TITLE_BAR_HEIGHT, bottom: this.safeBottom })
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
        // 根 Stack 默认居中对齐，直接给 Column 挂上限即可。
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    // HDS 沉浸光感标题栏：材质 / 温控统一由 HdsTitleBarStyle 决策
    //（设备不支持 IMMERSIVE 时自动走玻璃色兜底档，见该文件注释）。
    // 内容用 stackBuilder 承载 rewardBarNarrow（收窄容器内标题与内容列同宽对齐）。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        // 箭头包裹保证 builder 内 this 指向本组件（裸引用会丢失 this）
        stackBuilder: (): void => {
          this.rewardBarNarrow();
        }
      }
    })
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 系统返回拦截：播放页 overlay 打开时吞掉返回并发收起请求（留在本页），
    // 否则走默认 pop —— 详见 utils/SubPageBackPress。
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让：目的地级声明布局扩展进系统安全区（官方组件级沉浸口径，
    // 与关于页同款）；内容层避让由居中区 padding 自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function RewardPageBuilder(): void {
  RewardPage()
}


/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const RewardPageWrapped: WrappedBuilder<[]> = wrapBuilder(RewardPageBuilder);
