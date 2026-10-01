/**
 * 播放详情页（整体替换为 audio-interaction-master 的播放页方案）。
 *
 * 页面本体只是薄壳：挂 PlayerInfoComponent（沉浸背景 / 封面 Swiper / Canvas 歌词 /
 * 控制区都在组件树里，见 components/player/）。断点系统（BreakpointSystem）已上移到
 * Index 常驻注册 —— 本页组件照常订阅 AppStorage 的 currentBreakpoint，不再自己注册。
 *
 * 保留的原有机制：
 *   - 'Player' 路由（Index 的 pageMap）与 geometryTransition 封面一镜到底
 *     （大封面在 MusicInfoComponent 里，与 PlayBar 迷你封面同 id）；
 *   - 进场动效：点击迷你播放条进入时，整页自迷你条所在高度（ENTER_RISE）升起并淡入
 *     （NavDestination.customTransition 驱动）；
 *   - 返回拦截：onBackPressed 里 animateTo + pop(false)，只做封面一镜到底形变；
 *   - 全屏布局避让（safeTop / safeBottom 在 PlayerInfoComponent 内部消费）；
 *   - 离开页面时把状态栏内容色复原为黑（首页是浅色背景）。
 */

import { PlayerInfoComponent } from '../components/player/PlayerInfoComponent';
import { ColorConversion } from '../common/utils/ColorConversion';
import { common } from '@kit.AbilityKit';
import { NavStackHolder } from '../service/NavStackHolder';
import {
  STORE_PLAYER_TRANSITIONING,
  PLAYER_TRANSITION_MS
} from '../common/Constants';

/**
 * 进场起始位移（vp）：点击迷你播放条进入本页时，整页自下方升起 + 淡入。
 * 取「悬浮胶囊底边 + 胶囊高度」的量级，页面起点落在迷你条附近，
 * 视觉上是「从迷你条那里长出来」。
 */
const ENTER_RISE: number = 128;
/** 进场动效时长（ms）。Friction：起步快、落位慢，升起有「落定」感 */
const ENTER_DURATION: number = 360;

@Component
export struct PlayerPage {
  /** 共享元素转场进行中：进入时由本页在转场结束后复位（PlayBar 置位） */
  @StorageLink(STORE_PLAYER_TRANSITIONING) playerTransitioning: boolean = false;

  /** 进场动效：整页起始位移与透明度（初始为「下方 + 透明」），由 customTransition 改到终态 */
  @State enterShift: number = ENTER_RISE;
  @State enterOpacity: number = 0;

  private transitionEndTimer: number = -1;

  aboutToAppear(): void {
    if (this.playerTransitioning) {
      this.scheduleTransitionEnd();
    }
  }

  aboutToDisappear(): void {
    if (this.transitionEndTimer !== -1) {
      clearTimeout(this.transitionEndTimer);
      this.transitionEndTimer = -1;
    }
    // 状态栏内容色复原为黑图标：沉浸页里按背景明暗切换过，首页是浅色背景
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      ColorConversion.setStatusBarContentColor(ctx, false);
    }
  }

  /** 转场结束回调：复位全局转场标志（PlayBar 侧据此恢复） */
  private scheduleTransitionEnd(): void {
    if (this.transitionEndTimer !== -1) {
      clearTimeout(this.transitionEndTimer);
    }
    this.transitionEndTimer = setTimeout((): void => {
      this.transitionEndTimer = -1;
      AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, false);
    }, PLAYER_TRANSITION_MS);
  }

  build() {
    NavDestination() {
      PlayerInfoComponent()
    }
    .hideTitleBar(true)
    // 进场动效：整页自下方升起 + 淡入（点击迷你播放条进入时）。
    // translate 只做绘制位移、不参与布局，因此不会影响封面 geometryTransition 取到的目标位置。
    .translate({ y: this.enterShift })
    .opacity(this.enterOpacity)
    // 单页自定义转场（NavDestination.customTransition，API 15+）：
    // 只接管「PUSH 且本页为进入方」，其余情况返回 undefined 交回系统默认
    // （返回路径仍走 onBackPressed 里的 animateTo + pop(false)，只做封面一镜到底形变）。
    .customTransition((operation: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      if (!isEnter || operation !== NavigationOperation.PUSH) {
        return undefined;
      }
      this.enterShift = ENTER_RISE;
      this.enterOpacity = 0;
      const riseIn: NavDestinationTransition = {
        duration: ENTER_DURATION,
        delay: 0,
        curve: Curve.Friction,
        event: (): void => {
          this.enterShift = 0;
          this.enterOpacity = 1;
        }
      };
      return [riseIn];
    })
    // 返回（系统侧滑）拦截：大封面经共享元素转场缩小回迷你条。
    // 必须在 animateTo 闭包内 pop(false)：既驱动 geometryTransition，
    // 又关闭系统默认转场，避免两种动画叠加。
    .onBackPressed((): boolean => {
      AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, true);
      this.getUIContext().animateTo(
        { duration: PLAYER_TRANSITION_MS, curve: Curve.EaseInOut },
        (): void => {
          NavStackHolder.stack.pop(false);
        }
      );
      // 转场结束后复位标志（本页可能已销毁，回调只碰全局状态）
      setTimeout((): void => {
        AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, false);
      }, PLAYER_TRANSITION_MS);
      return true;
    })
  }
}
