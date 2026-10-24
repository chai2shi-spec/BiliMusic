/**
 * 播放详情页（2026-10-21 组件状态切换动画改版：不再是 NavDestination，无路由）。
 *
 * 本页现在是 Index 根 Stack 上的 overlay 薄壳：PlayBar.openPlayer 写
 * STORE_PLAYER_OVERLAY_MOUNTED=true → Index 条件挂载 LazyDest('Player')（复用
 * 懒加载注册 + 1.5s 预热，冷启动优化不回退）→ 本组件 → PlayerInfoComponent。
 *
 * 打开/收起的主动画全部由组件状态驱动（无 pushPath / pop / customTransition）：
 *   · 打开：PlayerInfoComponent.playEnterTransition —— 单个 animateTo(700ms,
 *     PLAYER_MAIN_CURVE) 写 STORE_PLAYER_OPEN=true，同帧驱动两套 geometryTransition
 *     配对（背景面从迷你栏真实视觉包围盒长到全屏 + 唱片页内配对飞行）与
 *     Index 页签图标 opacity 淡出。三种收起风格下打开侧均不变（morph 一镜到底）。
 *   · 收起（2026-10-24 三风格改版，Index.closePlayer 按 STORE_PLAYER_CLOSE_ANIM
 *     分流）：柔退（morph / morph_swipe 按键收起）仍是 700ms 逆向镜像；
 *     下滑（slide 全入口 / 手势松手过阈值）由 Index.slideOutClose 写
 *     STORE_PLAYER_SLIDE_OFFSET / _ALPHA 终值，本壳根节点绑定做整页下滑渐隐。
 *
 * 下拉手势（morph_swipe 风格 + 直板机版式形态挂载 —— sm 断点 / 阔折叠展开竖屏
 * （isWideFoldFull，2026-10-24 阔折叠展开改版扩展），其余条件见 dragDismissEnabled）：
 *   · 跟手：PanGesture onActionUpdate 逐帧直写 AppStorage（SLIDE_OFFSET/_ALPHA
 *     与下滑收起共用同一对键 —— 松手过阈值时 Index.slideOutClose 的终态动画从
 *     当前位移自然续滑，无「先归零本地量再滑」的视觉跳变；手势期间逐帧写
 *     AppStorage 的开销 = @StorageProp 通知两次/帧，仅拖拽期间存在，可接受）；
 *   · 松手不足阈值（SLIDE_DISMISS_THRESHOLD_VP=120vp）：本页自建 250ms EaseOut
 *     回弹（TRANSITIONING 期间阻断 openPlayer），onFinish 复位拖拽标志；
 *   · 松手过阈值：STORE_PLAYER_SLIDE_CLOSE_REQUEST seq 递增 → Index 统一
 *     slideOutClose（GT 摘除 → 整页 350ms 加速下滑渐隐）；
 *   · 拖拽/回弹全程 STORE_PLAYER_DRAG_ACTIVE 置位：Index.closePlayer 据此把
 *     按键/返回收起也分流到下滑路径（页面位移非 0 时 morph 配对必漂移）。
 *   · 歌词页手势天然被 Scroller 消费不触发；封面页竖拉与 SM Swiper 的横滑
 *     靠方向判定互不抢占。
 *
 * 保留的原有机制：
 *   - 全屏布局避让（safeTop / safeBottom 在 PlayerInfoComponent 内部消费）；
 *   - 离开时把状态栏内容色复原为黑（首页是浅色背景）。
 */

import { PlayerInfoComponent } from '../components/player/PlayerInfoComponent';
import { ColorConversion } from '../common/utils/ColorConversion';
import { common } from '@kit.AbilityKit';
import {
  STORE_PLAYER_OPEN,
  STORE_PLAYER_CLOSE_ANIM,
  STORE_PLAYER_TRANSITIONING,
  STORE_PLAYER_SLIDE_OFFSET,
  STORE_PLAYER_SLIDE_ALPHA,
  STORE_PLAYER_SLIDE_CLOSE_REQUEST,
  STORE_PLAYER_DRAG_ACTIVE,
  STORE_WINDOW_HEIGHT_VP,
  STORE_FOLD_EXPANDED
} from '../common/Constants';
import {
  SLIDE_DISMISS_THRESHOLD_VP,
  SLIDE_DIM_MAX,
  SLIDE_BACK_MS
} from '../common/constants/InteractionConstants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { PLAYER_CLOSE_STYLE_MORPH_SWIPE } from '../model/MusicModels';

@Component
export struct PlayerPage {
  /** 播放页展开态：手势挂载条件之一 */
  @StorageProp(STORE_PLAYER_OPEN) playerOpen: boolean = false;
  /** 收起动画风格：仅 morph_swipe 挂下拉手势（slide 已有全入口下滑、morph 纯按键） */
  @StorageProp(STORE_PLAYER_CLOSE_ANIM) closeAnimStyle: string = '';
  /** 主动画/回弹进行中：手势与主动画互斥（回弹中再拉会与 250ms 补间打架） */
  @StorageProp(STORE_PLAYER_TRANSITIONING) transitioning: boolean = false;
  /** 当前断点：手势挂载判定用（sm 直板机 / 阔折叠展开竖屏 lg） */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = 'sm';
  /**
   * 折叠屏展开态 + 横竖屏（2026-10-24 阔折叠展开改版）：下拉手势从「仅 sm」
   * 扩展到阔折叠展开竖屏（isWideFoldFull 同口径双份实现 —— 播放页该形态走
   * 直板机 Swiper 版式，交互随之对齐；见 PlayerInfoComponent.isWideFoldFull）。
   */
  @StorageProp(STORE_FOLD_EXPANDED) isFoldFull: boolean = false;
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;
  /** 整页位移（vp）：手势逐帧写 + Index.slideOutClose 终态动画写，根节点 translate 绑定 */
  @StorageProp(STORE_PLAYER_SLIDE_OFFSET) slideOffset: number = 0;
  /** 整页透明度：跟手渐隐（SLIDE_DIM_MAX 封顶）/ 终态归零，根节点 opacity 绑定 */
  @StorageProp(STORE_PLAYER_SLIDE_ALPHA) slideAlpha: number = 1;
  /** 窗口内容区高度（vp）：跟手渐隐公式的分母兜底 1280 */
  @StorageProp(STORE_WINDOW_HEIGHT_VP) windowHeightVp: number = 0;
  /** 本次手势会话是否有效挂载（onActionBegin 判定，End/Cancel 消费；构建函数不能读方法外的可变量） */
  @State dragSessionActive: boolean = false;

  aboutToDisappear(): void {
    // 状态栏内容色复原为黑图标：沉浸页里按背景明暗切换过，首页是浅色背景。
    // 壳被卸载只发生在主动画 onFinish（柔退 700ms / 下滑 350ms），此时各标志
    // 已由对应 onFinish 复位，无需在此重复清理 AppStorage。
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      ColorConversion.setStatusBarContentColor(ctx, false);
    }
  }

  /**
   * 下拉手势挂载条件：morph_swipe 风格 + 直板机版式形态（sm / 阔折叠展开竖屏
   * isWideFoldFull）+ 页面展开 + 无主动画/回弹在途。跟手/回弹/续滑机制断点无关
   * （SLIDE_OFFSET/_ALPHA 与 slideOutClose 共用、GT 摘除守卫齐全），风险面与
   * sm 完全一致。
   * 回调内判定（而非条件挂 .gesture —— 链式属性无法按态增删）：不满足时
   * onActionBegin 置 dragSessionActive=false，后续回调早退，手势空识别无副作用。
   */
  private dragDismissEnabled(): boolean {
    return this.closeAnimStyle === PLAYER_CLOSE_STYLE_MORPH_SWIPE
      && (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_SM
        || (this.isFoldFull && !this.isLandscape
          && this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG))
      && this.playerOpen
      && !this.transitioning;
  }

  /** 跟手：位移取正（只允许下拉），透明度按位移/窗高线性衰减（SLIDE_DIM_MAX 封顶） */
  private onDragUpdate(offsetY: number): void {
    const h: number = this.windowHeightVp > 0 ? this.windowHeightVp : 1280;
    const off: number = Math.max(0, offsetY);
    AppStorage.setOrCreate(STORE_PLAYER_SLIDE_OFFSET, off);
    AppStorage.setOrCreate(STORE_PLAYER_SLIDE_ALPHA, 1 - Math.min(off / h, 1) * SLIDE_DIM_MAX);
  }

  /**
   * 松手分流：≥ 阈值（SLIDE_DISMISS_THRESHOLD_VP）→ seq 请求 Index.slideOutClose
   * 统一收起（位移/透明度保持当前值，终态动画从当前位置续滑）；不足 → 本页
   * 250ms EaseOut 回弹，TRANSITIONING 置位阻断 openPlayer（回弹中点开迷你栏
   * 会以中途帧起算 morph 配对），onFinish 复位。onActionCancel 同走回弹。
   * ⚠️ 方法名不能叫 onDragEnd —— 与组件内建属性方法（通用拖拽事件）重名，
   * ArkTS 按基类签名校验直接编译失败。
   */
  private finishDragGesture(): void {
    if (!this.dragSessionActive) {
      return;
    }
    this.dragSessionActive = false;
    if (this.slideOffset >= SLIDE_DISMISS_THRESHOLD_VP) {
      const seq: number = (AppStorage.get<number>(STORE_PLAYER_SLIDE_CLOSE_REQUEST) ?? 0) + 1;
      AppStorage.setOrCreate(STORE_PLAYER_SLIDE_CLOSE_REQUEST, seq);
      return;
    }
    AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, true);
    this.getUIContext().animateTo(
      {
        duration: SLIDE_BACK_MS,
        curve: Curve.EaseOut,
        onFinish: (): void => {
          AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, false);
          AppStorage.setOrCreate(STORE_PLAYER_DRAG_ACTIVE, false);
        }
      },
      (): void => {
        AppStorage.setOrCreate(STORE_PLAYER_SLIDE_OFFSET, 0);
        AppStorage.setOrCreate(STORE_PLAYER_SLIDE_ALPHA, 1);
      }
    );
  }

  build() {
    Stack() {
      PlayerInfoComponent()
    }
    .width('100%')
    .height('100%')
    // 整页下滑/渐隐的合成出口：手势逐帧值与 Index.slideOutClose 终态动画共用
    // 同一对 AppStorage 键，两条路径在渲染层无缝衔接。柔退路径两键恒为 0/1，
    // 不参与 morph 配对（translate 挂在封面 GT 祖先上的已知风险仅在位移非 0
    // 且发生配对时成立 —— 分流守卫已保证位移非 0 必走 GT 摘除的下滑路径）。
    .translate({ y: this.slideOffset })
    .opacity(this.slideAlpha)
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 8 })
        // ⚠️ 本 SDK 的 PanGesture 无 onActionBegin，会话挂载判定用 onActionStart
        .onActionStart(() => {
          this.dragSessionActive = this.dragDismissEnabled();
          if (this.dragSessionActive) {
            AppStorage.setOrCreate(STORE_PLAYER_DRAG_ACTIVE, true);
          }
        })
        .onActionUpdate((event: GestureEvent) => {
          if (!this.dragSessionActive) {
            return;
          }
          this.onDragUpdate(event.offsetY);
        })
        .onActionEnd(() => {
          this.finishDragGesture();
        })
        .onActionCancel(() => {
          this.finishDragGesture();
        })
    )
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets，2026-10-17 启动优化）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染
 *（路由 pageMap 与播放页 overlay 共用同一份注册与预热）。
 */
@Builder
export function PlayerPageBuilder(): void {
  PlayerPage()
}


/** 懒加载注册表预包装（2026-10-17）：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const PlayerPageWrapped: WrappedBuilder<[]> = wrapBuilder(PlayerPageBuilder);
