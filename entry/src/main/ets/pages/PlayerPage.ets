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
 *   - 进场动效（2026-10-20 改版）：点击迷你播放条进入时，**背景面从迷你栏那一小块
 *     矩形长到全屏**（PlayerInfoComponent 的 surfaceProgress），内容层错峰淡入，
 *     封面 geometryTransition 同时一镜到底。本页的 customTransition 只负责
 *     顶替系统默认 push 转场（等时长空转场）；没有起点矩形时退回整页淡入。
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
 * 进场起始位移（vp）：**0**（2026-10-03 方案 B 之后）。
 *
 * 演进链：128 → 48（方案 A）→ 0（方案 B）。
 * 原因：**整页位移会把共享元素的目标框一起搬走** —— 页面初始 `translate y = N` 时，
 * 封面的目标框也跟着在下方 Nvp，于是「迷你条封面 → 大圆盘」这条直线轨迹被弯成
 * **先下后上的弧线**。48 只是把弧度压小，0 才让轨迹回到真正的直线；
 * 「从下往上」的方向感改由各子层的 10vp 位移分层提供（见 InteractionConstants.LAYER_DELAY_*）。
 */
const ENTER_RISE: number = 0;
/**
 * 进场动效时长（ms）：**必须与 `PLAYER_TRANSITION_MS`（300）一致**。
 *
 * 原本这里是 360ms，而封面 geometryTransition 走的是 300ms → 有 **60ms「封面已停住、
 * 整页还在往上飘」**的错位窗口，两个动画看起来没对齐。现在时长与曲线都统一。
 */
const ENTER_DURATION: number = 300;
/**
 * 退场位移（vp）与时长（ms）：返回时页面的镜像下沉。
 * 比进场**快**（240 < 300）—— 返回是用户明确要离开的动作，拖沓比缺动画更难受。
 */
const EXIT_RISE: number = 32;
const EXIT_DURATION: number = 240;

@Component
export struct PlayerPage {
  /** 共享元素转场进行中：进入时由本页在转场结束后复位（PlayBar 置位） */
  @StorageLink(STORE_PLAYER_TRANSITIONING) playerTransitioning: boolean = false;

  /**
   * 进场动效：整页起始位移与透明度。
   *
   * 默认值改为「不位移 + 全不透明」：进场视觉已交给 PlayerInfoComponent 的
   * 「迷你栏 → 全屏」生长动画（背景面长大 + 内容层错峰淡入）。
   * 只有**没有起点矩形**的兜底路径才会在这里把它改成「透明 → 不透明」的整页淡入。
   */
  @State enterShift: number = ENTER_RISE;
  @State enterOpacity: number = 1;

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
    // 转场起点矩形的一次性语义由本页收尾（PlayerInfoComponent 只读不清，
    // 因为两边读取顺序无保证）：页面销毁即作废，下次点击迷你栏会重新实测。
    NavStackHolder.playerEntranceRect = null;
    // 状态栏内容色复原为黑图标：沉浸页里按背景明暗切换过，首页是浅色背景
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      ColorConversion.setStatusBarContentColor(ctx, false);
    }
  }

  /**
   * 转场结束回调：复位全局转场标志（PlayBar 侧据此恢复）。
   *
   * ⚠️ 时长必须与**实际进场时长**一致（`ENTER_DURATION`）。原先这里写的是
   * `PLAYER_TRANSITION_MS`（300）而进场是 360ms → 标志早复位 60ms，
   * 封面的旋转会在到达之前就起转（观感是「还在飞就开始转」）。
   */
  private scheduleTransitionEnd(): void {
    if (this.transitionEndTimer !== -1) {
      clearTimeout(this.transitionEndTimer);
    }
    this.transitionEndTimer = setTimeout((): void => {
      this.transitionEndTimer = -1;
      AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, false);
    }, ENTER_DURATION);
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
      if (!isEnter) {
        // 退场（POP）：页面轻微下沉 + 淡出，镜像进场。
        // ⚠️ 返回时**不再用 onBackPressed 里的 animateTo 改状态**——`pop()` 之后页面立刻被销毁，
        // 手写的退场动画根本来不及显示（`animateTo` 又没有 finish 回调可用）。
        // 所以退场必须交给这里的自定义转场，由系统在页面存活期间驱动。
        const sinkOut: NavDestinationTransition = {
          duration: EXIT_DURATION,
          delay: 0,
          curve: Curve.EaseInOut,
          event: (): void => {
            this.enterShift = EXIT_RISE;
            this.enterOpacity = 0;
          }
        };
        return [sinkOut];
      }
      if (operation !== NavigationOperation.PUSH) {
        return undefined;
      }
      // 进场（PUSH）分两条路：
      //
      // ① 从迷你栏进来（PlayBar 已在点击时实测写入起点矩形）→ 视觉全部交给
      //    PlayerInfoComponent 的「容器长大」（背景面从迷你栏矩形长到全屏 +
      //    内容层错峰淡入）。这里只返回一个**等时长的空转场**，作用是顶替
      //    系统默认的 push 转场 —— 返回 undefined 会走默认右滑，和生长动画打架。
      //
      // ② 兜底（没有起点矩形：测量失败 / 将来出现别的入口）→ 保留原来的
      //    「整页升起 + 淡入」。
      if (NavStackHolder.playerEntranceRect !== null) {
        const holdOpen: NavDestinationTransition = {
          duration: ENTER_DURATION,
          delay: 0,
          curve: Curve.EaseInOut,
          event: (): void => {
          }
        };
        return [holdOpen];
      }
      this.enterShift = ENTER_RISE;
      this.enterOpacity = 0;
      // 曲线与封面 geometryTransition 统一为 EaseInOut：原先这里用 Friction（起步快、落位慢）
      // 而 pushPath 外层是 EaseInOut，两条曲线叠加导致起步与收尾的加速度对不上。
      const riseIn: NavDestinationTransition = {
        duration: ENTER_DURATION,
        delay: 0,
        curve: Curve.EaseInOut,
        event: (): void => {
          this.enterShift = 0;
          this.enterOpacity = 1;
        }
      };
      return [riseIn];
    })
    // 内容避让（2026-10-14）：目的地级声明布局扩展进系统安全区（官方组件级沉浸
    // 口径，与全部子页统一）；窗口全屏下页面级为既成事实，此处显式化。本页内容
    // 避让全部在 PlayerInfoComponent 内部（plain padding top/bottom，不受声明接管）。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    // 返回（系统侧滑）拦截：大封面经共享元素转场缩小回迷你条。
    // 保持在 animateTo 闭包内 pop：geometryTransition 在转场上下文里才可靠地被驱动。
    // ⚠️ `pop(false)` → `pop()`：`false` 会连**页面自己的 customTransition 一起关掉**
    //（它顶替的就是系统默认转场），于是返回时整页无动画、只有封面在缩 → 观感是「突然消失」。
    // 改成默认的 pop() 后，退场由上面的 POP 分支接管（240ms 下沉淡出），封面照旧缩小。
    .onBackPressed((): boolean => {
      AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, true);
      this.getUIContext().animateTo(
        { duration: PLAYER_TRANSITION_MS, curve: Curve.EaseInOut },
        (): void => {
          NavStackHolder.stack.pop();
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

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets，2026-10-17 启动优化）：
 * Index 已不再静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function PlayerPageBuilder(): void {
  PlayerPage()
}


/** 懒加载注册表预包装（2026-10-17）：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const PlayerPageWrapped: WrappedBuilder<[]> = wrapBuilder(PlayerPageBuilder);

