/**
 * 全局底部播放栏（PlayBar）—— HDS 悬浮底栏 miniBar 槽位内容（与页签胶囊融合）。
 *
 * 架构（参考 MusicHome / Sumy-Music 的 HdsTabs miniBar 集成方案）：
 *   本组件**不再自带定位与背景**，作为 Index.ets 里 barFloatingStyle.miniBar 的
 *   builder 内容渲染 —— HDS 把它和页签项排进**同一个悬浮胶囊**
 *   （barLayoutMode: HdsBarLayoutMode.HORIZONTAL：播放栏在左、页签在右，一行融合），
 *   液态玻璃材质、悬浮离底、底部安全区避让全部由 HDS 统一处理，无需重复实现。
 *
 * 展开 / 收起两态（HdsBarStyle，手动控制：Index 拦截系统 NORMAL 自动变更，
 * 只认用户点击与控制器调用）—— **内容怎么放由 barLayout 决定，不是由展开态决定**：
 *   · 水平融合（barLayoutMode.HORIZONTAL：播放栏在左、页签在右，同一行）
 *       - EXPAND   ：封面 + 歌名/歌手 + 播放/暂停，点条目进全屏播放页；
 *       - COLLAPSE ：槽位被 HDS 缩到圆盘大小 → **仅封面圆盘**（多了会被裁掉），
 *                    点它经 onExpandRequest 通知宿主重新展开（Sumy 同款交互）。
 *   · 垂直两层（barLayoutMode.VERTICAL：播放栏独占上一行、页签在下）
 *       - **收起与展开内容一致**：共用同一个 `ExpandedContent`
 *         （封面 + 歌名/歌手 + 播放/暂停，点条目进播放页）。
 *         2026-10-13 按用户要求「垂直两层时收起和展开的迷你栏内容应该一样」。
 *         收起态下 HDS 只改槽位几何，不改我们能放的内容；既然内容一模一样，
 *         就不存在「先展开才能操作」，点击语义也与展开态同构（直接进播放页），
 *         避免「点了一下什么都没发生」的假死感；
 *       - ⚠️ 但几何**确实变了**：收起行比展开态矮，封面圆盘改用**固定小值**
 *         `MINI_DISC_COLLAPSED_VERTICAL`(28) 渲染 —— 用户第二条件：
 *         「封面大小适应收起迷你栏的高度，而不是跟展开时一样大」。
 *   两态切换由 Index 的 onBarStyleChange 写入 AppStorage（STORE_MINI_BAR_EXPANDED），
 *   本组件只读订阅 —— miniBarBuilder 内容会被 HDS 缓存，状态必须走全局存储。
 *
 * 封面圆盘尺寸（coverSize）：**纯常量选择，不做任何测量、不写任何状态**。
 *   · 展开态 / 宽屏 / 水平融合 → COVER_SIZE(40)；
 *   · 垂直两层 + 收起 → MINI_DISC_COLLAPSED_VERTICAL(28)。
 *   ⚠️ 曾经用根 Row 的 `onAreaChange` 实测槽位高来自适应（因为 HDS 不暴露 miniBar 高度：
 *   `barWidth`/`barHeight` 是整条页签栏的）。**真机回归：垂直两层下展开迷你栏直接消失**
 *   —— 教训是别在 HDS 托管的内容里「由布局回调回写 @State」：状态写入落在 HDS 自己的
 *   布局 / 形变动画过程中，内容会在动画中途重建，槽位最终落定成空。故改回常量：
 *   宁可尺寸是估的，也不能让 HDS 的槽位挂载失败。
 *   ⚠️ 常量也不能取太大：`enableMiniBarClip` 默认 true，超出槽位的部分会被硬裁。
 *
 * 唱片旋转（AnimatorResult 驱动，非 .animation() 属性动画）：
 *   当前 SDK 没有 AnimationState / playControls，属性动画无法暂停保持角度；
 *   用 UIContext.createAnimator（begin 0°→end 360°，linear，iterations -1 无限循环）
 *   每帧回写 @State rotateAngle → Image.rotate({ z: 1, angle }) 跟转：
 *     · isPlaying=true  → play()    —— 等价 Playing，从暂停帧继续；
 *     · isPlaying=false → pause()   —— 等价 Paused，冻结当前角度**不复位**；
 *     · 切歌（track 变化）→ reset() —— 等价 Stopped，角度重置 0°，再按播放态决定是否续转。
 *
 * 状态复用（不新建数据）：@StorageLink / @StorageProp 绑既有播放状态
 *   STORE_QUEUE / STORE_CURRENT_TRACK / STORE_IS_PLAYING；播放控制直调
 *   MusicPlayer 单例 prev / togglePlay / next，「播完自动下一首」留在播放内核。
 *
 * 多端自适应：文字区 layoutWeight(1) 吃掉富余宽度；展开/收起由 HDS 按断点宽度
 * 自动调度（小屏收起成圆盘、大屏展开整行），组件内容随全局状态自适应，
 * 封面圆盘在「垂直两层 + 收起」这一格改用较小的固定常量（见上「封面圆盘尺寸」）。
 *
 * 边界：歌单队列为空 / 无在播曲目时本组件不渲染；Index 侧还会整体摘除
 * miniBar 槽位（barFloatingStyle 不带 miniBar），胶囊退回纯页签形态。
 */

import { Track, BAR_LAYOUT_HORIZONTAL, BAR_LAYOUT_VERTICAL } from '../model/MusicModels';
import { MusicPlayer } from '../player/MusicPlayer';
import { NavStackHolder } from '../service/NavStackHolder';
import { toThumbUrl } from '../utils/TextUtil';
import { CoverImage } from './CoverImage';
import { AnimatorOptions, AnimatorResult } from '@kit.ArkUI';
import {
  STORE_CURRENT_TRACK,
  STORE_IS_PLAYING,
  STORE_QUEUE,
  STORE_PLAYER_TRANSITIONING,
  STORE_MINI_BAR_EXPANDED,
  STORE_BAR_LAYOUT,
  GEOMETRY_ID_PLAYER_DISC,
  PLAYER_TRANSITION_MS
} from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';

/**
 * 封面圆盘边长（vp）：**展开态 / 宽屏 / 水平融合**的固定值。
 * ⚠️ 垂直两层的**收起态**不用它 —— 那边收起行更矮，用
 * `MINI_DISC_COLLAPSED_VERTICAL`(28)，否则 40vp 会被 `enableMiniBarClip` 裁掉一圈。
 * （历史：原先展开 32 / 收起 40，两态切换大小跳变，统一为 40 后又被「收起行更矮」推翻。）
 */
const COVER_SIZE: number = 40;
/**
 * 垂直两层**收起态**的封面圆盘边长（vp）。
 *
 * ⚠️ 为什么是常量、而不是按槽位实测自适应：HDS 不暴露 miniBar 高度（`barWidth`/
 * `barHeight` 是整条页签栏的），唯一能「自适应」的办法是在内容里挂 `onAreaChange`
 * 回写 @State —— **真机回归：垂直两层下展开迷你栏直接消失**（状态写入落在 HDS 自己的
 * 布局 / 形变动画过程中，内容途中重建，槽位最终落定成空）。**别再用测量换自适应**：
 * 宁可尺寸是估的，也不能让 HDS 的槽位挂载失败。
 * 取 28：明显小于展开态 40（收起行确实更矮），又不至于小到突兀；真机观感偏差直接改这里。
 */
const MINI_DISC_COLLAPSED_VERTICAL: number = 28;
/** 播放 / 暂停图标尺寸（与封面转盘同大，作视觉锚点） */
const PLAY_ICON_SIZE: number = 32;
/** 控制键之间间距（收窄，为文字区让宽） */
const CTRL_SPACING: number = 8;
const DISC_ROTATE_DEGREE: number = 360;
const DISC_ROTATE_MS: number = 4000;

@Component
export struct PlayBar {
  /** 播放队列（歌单列表）：为空时内容不渲染 */
  @StorageLink(STORE_QUEUE) queue: Track[] = [];
  /** 在播曲目（currentSong）：封面 / 歌名 / 歌手的数据源；@Watch 切歌时重置唱片角度 */
  @StorageLink(STORE_CURRENT_TRACK) @Watch('onTrackChanged') currentTrack: Track | null = null;
  /** 播放中标志（isPlaying）：切换播放 / 暂停图标；@Watch 驱动唱片 play / pause */
  @StorageLink(STORE_IS_PLAYING) @Watch('onPlayingChanged') isPlaying: boolean = false;
  /**
   * miniBar 展开 / 收起态（Index 的 onBarStyleChange 写入，这里只读；默认折叠）。
   * ⚠️ 只有在**水平融合**布局下它才决定内容（收起 = 仅封面圆盘）；
   * 垂直两层布局下收起与展开内容完全相同，本状态对渲染没有影响（见 build()）。
   */
  @StorageProp(STORE_MINI_BAR_EXPANDED) expanded: boolean = false;
  /**
   * 底部导航布局（设置页「外观 → 底部导航布局」的运行时镜像，与 Index.barFloatingStyle
   * 同源；取值 BAR_LAYOUT_HORIZONTAL / BAR_LAYOUT_VERTICAL，见 model/MusicModels）。
   *
   * 决定**收起态**能放多少内容：
   *   · HORIZONTAL 水平融合 —— 播放栏与页签同一行，收起时 HDS 把槽位缩到圆盘大小，
   *     再多内容也会被裁（`enableMiniBarClip` 默认 true）→ 仅封面圆盘；
   *   · VERTICAL 垂直两层 —— 播放栏独占上面一整行，收起态仍是一整行宽度
   *     → 收起与展开**共用同一套内容**（封面 + 歌名/歌手 + 播放键，见 build()）。
   * @StorageProp 变化触发本组件重渲染，切布局即时换内容。
   */
  @StorageProp(STORE_BAR_LAYOUT) barLayout: string = BAR_LAYOUT_HORIZONTAL;
  /**
   * 当前断点：md/lg（HdsTabs 宽度 ≥600vp）下 HDS 强制展开迷你栏，
   * miniBarStyle / applyMiniBarStyle 全部失效（官方文档：仅宽度 <600vp 可设）。
   * 此时若全局展开态仍停在 false，收起内容（小圆盘）会渲染进展开槽位，
   * 点击走 onExpandRequest → applyMiniBarStyle(EXPAND) → 宽屏下无效 → 死胡同
   * —— 这是宽屏下唯一确定会「点了没反应」的路径（折叠屏点 miniBar 不跳转的
   * 头号嫌疑），因此 build() 里宽屏一律按展开态渲染、点击直达播放页。
   */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string =
    BreakpointConstants.BREAKPOINT_SM;

  /** 唱片当前旋转角度（°）：animator 每帧回写，暂停时冻结在当前值 */
  @State rotateAngle: number = 0;
  /** 迷你播放/暂停键的点击回弹缩放（独立状态，与唱片旋转互不相干） */
  @State miniPlayScale: number = 1;

  /** 唱片旋转 animator：play=续转 / pause=冻结 / reset=归零（aboutToAppear 里创建） */
  private coverAnim: AnimatorResult | null = null;

  /** 收起态点击封面请求重新展开（宿主回调 HdsTabsController.applyMiniBarStyle） */
  onExpandRequest?: () => void = undefined;

  /** 播放内核单例：控制键只调它的现成方法，绝不另写播放器 */
  private player: MusicPlayer = MusicPlayer.getInstance();

  /** 唱片旋转动画参数（创建与 reset 复用同一份配置） */
  private discOptions(): AnimatorOptions {
    return {
      duration: DISC_ROTATE_MS,
      easing: 'linear',
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: -1,
      begin: 0,
      end: DISC_ROTATE_DEGREE
    };
  }

  aboutToAppear(): void {
    // 诊断日志（折叠屏「点 miniBar 不跳转」排查）：确认挂载时的断点 / 展开态初值
    console.info(`[PlayBar] appear: bp=${this.currentBreakpoint}, expanded=${this.expanded}, playing=${this.isPlaying}`);
    // UIContext 在属性初始化时未就绪，animator 延迟到 here 创建（同 LrcView）
    try {
      this.coverAnim = this.getUIContext().createAnimator(this.discOptions());
      this.coverAnim.onFrame = (value: number): void => {
        this.rotateAngle = value;
      };
      // 挂载时可能已在播放中（isPlaying 初值即 true，@Watch 不会触发，需手动起转）
      if (this.isPlaying) {
        this.coverAnim.play();
      }
    } catch (e) {
      // animator 创建失败只影响唱片旋转，不影响播放控制
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`[PlayBar] createAnimator failed: ${msg}`);
    }
  }

  aboutToDisappear(): void {
    if (this.coverAnim !== null) {
      this.coverAnim.finish();
      this.coverAnim = null;
    }
  }

  /** 播放/暂停 → 唱片续转/冻结。pause 冻结在当前帧角度，绝不复位到 0 */
  private onPlayingChanged(): void {
    const anim: AnimatorResult | null = this.coverAnim;
    if (anim === null) {
      return;
    }
    if (this.isPlaying) {
      anim.play();
    } else {
      anim.pause();
    }
  }

  /** 切歌 → reset 归零角度（等价 Stopped），再按当前播放态决定是否重新起转 */
  private onTrackChanged(): void {
    const anim: AnimatorResult | null = this.coverAnim;
    if (anim === null) {
      return;
    }
    this.rotateAngle = 0;
    try {
      anim.reset(this.discOptions());
    } catch (e) {
      // reset 失败只影响切歌归零，不影响播放控制
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`[PlayBar] animator reset failed: ${msg}`);
      return;
    }
    if (this.isPlaying) {
      anim.play();
    }
  }

  private coverUrl(): string {
    return this.currentTrack !== null ? this.currentTrack.coverUrl : '';
  }

  /** 迷你播放键点击回弹：一次快速缩小回弹（一次性关键帧，无持续动画无定时器） */
  private bounceMiniPlay(): void {
    this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
      {
        duration: 0,
        event: (): void => {
          this.miniPlayScale = 1;
        }
      },
      {
        duration: 80,
        curve: Curve.EaseIn,
        event: (): void => {
          this.miniPlayScale = 0.82;
        }
      },
      {
        duration: 140,
        curve: Curve.EaseOut,
        event: (): void => {
          this.miniPlayScale = 1.06;
        }
      },
      {
        duration: 80,
        curve: Curve.EaseOut,
        event: (): void => {
          this.miniPlayScale = 1;
        }
      }
    ]);
  }

  /**
   * 跳转全屏播放页。
   *
   * 标记共享元素转场开始（PlayerPage 依赖该标志把唱片旋转延迟到转场结束），
   * 再在 animateTo 闭包内 pushPath —— 既驱动封面 geometryTransition 一镜到底，
   * 又保留转场动画供 PlayerPage 的 customTransition 升起动效使用。
   */
  private gotoPlayer(): void {
    // 诊断日志（折叠屏「点 miniBar 不跳转」排查）：能打出这行说明点击已送达展开态条目
    console.info(`[PlayBar] gotoPlayer: bp=${this.currentBreakpoint}, expanded=${this.expanded}`);
    // 连点防护：转场进行中再 push 一次会叠出两层播放页（返回要按两次才回得来）。
    // 复用转场标志即可 —— 它在整个进出过程中都为真（进场的 aboutToAppear 置位、
    // 返回的 onBackPressed 也会置位），不需要额外的状态。
    if (AppStorage.get<boolean>(STORE_PLAYER_TRANSITIONING) ?? false) {
      console.info('[PlayBar] gotoPlayer ignored: transition in progress');
      return;
    }
    AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, true);
    this.getUIContext().animateTo(
      { duration: PLAYER_TRANSITION_MS, curve: Curve.EaseInOut },
      (): void => {
        NavStackHolder.stack.pushPath({ name: 'Player' });
      }
    );
  }

  /**
   * 封面圆盘边长（vp）—— **纯常量选择**，不测量、不写状态
   * （为什么不用实测自适应见 `MINI_DISC_COLLAPSED_VERTICAL` 的注释）。
   *
   *   · 展开态 / 宽屏（≥600vp 时 HDS 强制展开）/ 水平融合 → `COVER_SIZE`(40)；
   *   · 垂直两层 + 收起 → `MINI_DISC_COLLAPSED_VERTICAL`(28)：
   *     收起行比展开矮，40vp 会被 `enableMiniBarClip`（默认 true）裁掉一圈（真机反馈）。
   */
  private coverSize(): number {
    if (this.expanded || this.currentBreakpoint !== BreakpointConstants.BREAKPOINT_SM) {
      return COVER_SIZE;
    }
    return this.barLayout === BAR_LAYOUT_VERTICAL ? MINI_DISC_COLLAPSED_VERTICAL : COVER_SIZE;
  }

  /**
   * 整行内容：封面 + 歌名/歌手 + 播放/暂停键，点条目进播放页（按钮点击不会冒泡成跳转）。
   * 用于「展开态」以及「垂直两层布局的收起态」（两者内容完全一致，见文件头）。
   */
  @Builder
  ExpandedContent(): void {
    Row({ space: 8 }) {
      // 圆盘边长 = coverSize()（常量选择，见该方法）：展开态 / 水平融合固定 40vp，
      // 垂直两层收起态用 28vp。
      // 缩略图仍按 96px 请求（3x 屏下即使 40vp 也够清晰，且尺寸变化不换 url → 不重新下载）。
      // rotate / geometryTransition 挂在 CoverImage 根节点上：几何转场取的是节点框，
      // 与播放页大圆盘（CoverDiscComponent）同 id 配对，一镜到底不受影响。
      CoverImage({ url: toThumbUrl(this.coverUrl(), 96), imgWidth: this.coverSize(), imgHeight: this.coverSize(), imgRadius: this.coverSize() / 2 })
        .rotate({ z: 1, angle: this.rotateAngle })
        .geometryTransition(GEOMETRY_ID_PLAYER_DISC)

      Column() {
        Text(this.currentTrack !== null ? this.currentTrack.title : '')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.currentTrack !== null ? this.currentTrack.artist : '')
          .fontSize(10)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: CTRL_SPACING }) {
        SymbolGlyph(this.isPlaying ? $r('sys.symbol.pause_round_triangle_fill') : $r('sys.symbol.play_round_triangle_fill'))
          .fontSize(PLAY_ICON_SIZE)
          .fontColor([$r('sys.color.icon_primary')])
          .scale({ x: this.miniPlayScale, y: this.miniPlayScale })
          .onClick((): void => {
            this.player.togglePlay();
            this.bounceMiniPlay();
          })
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 8, right: 8 })
    .onClick((): void => {
      this.gotoPlayer();
    })
  }

  /**
   * 收起（**水平融合**布局）：槽位被 HDS 缩到圆盘大小，只装得下封面 → 仅封面圆盘。
   * 点它经宿主回调重新展开（不直接进播放页，避免误触）。
   * ⚠️ 别往这里加内容：`enableMiniBarClip` 默认 true，多出来的会被裁掉一半，
   * 观感比「只有圆盘」更差 —— 想放歌名 / 歌手请把布局切到「垂直两层」，
   * 那边收起态直接复用整行内容（`ExpandedContent`），不在这里加。
   */
  @Builder
  CollapsedContent(): void {
    Stack() {
      // 圆盘边长 = coverSize()：这一格槽位本身就是「圆盘大小」，恒 40vp（原观感保持不变）。
      // ⚠️ 这里**不能**挂 onAreaChange 之类的布局回调去改尺寸状态 —— 详见
      // MINI_DISC_COLLAPSED_VERTICAL 的注释（真机上会把 HDS 的槽位搞塌）。
      CoverImage({ url: toThumbUrl(this.coverUrl(), 96), imgWidth: this.coverSize(), imgHeight: this.coverSize(), imgRadius: this.coverSize() / 2 })
        .rotate({ z: 1, angle: this.rotateAngle })
        .geometryTransition(GEOMETRY_ID_PLAYER_DISC)
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
    .stateStyles({
      pressed: { .opacity(0.85) },
      normal: { .opacity(1) }
    })
    .onClick((): void => {
      // 诊断日志（折叠屏排查）：走到这里说明收起态圆盘收到了点击（宽屏本不该出现）
      console.info(`[PlayBar] collapsed disc click: bp=${this.currentBreakpoint}, expanded=${this.expanded}`);
      if (this.onExpandRequest !== undefined) {
        this.onExpandRequest();
      }
    })
  }

  build() {
    // 边界：队列空 / 无在播曲目 → 不渲染（Index 侧同时会摘除 miniBar 槽位）
    if (this.queue.length > 0 && this.currentTrack !== null) {
      Row() {
        // 三种「按整行内容渲染」的情形，内容与点击语义完全一致：
        //   ① expanded —— 真展开；
        //   ② barLayout === VERTICAL —— 垂直两层下收起 / 展开内容必须一样
        //      （用户要求，2026-10-13）。内容一模一样就不存在「先展开才能操作」，
        //      点击直接进播放页，与展开态同构，避免「点了一下什么都没发生」的假死感；
        //   ③ 非 SM 断点 —— 宽屏 HDS 强制展开槽位；此时若渲染收起内容，既与槽位不符，
        //      点击还会走 onExpandRequest（宽屏下 applyMiniBarStyle 无效）→ 点不动的死胡同。
        if (this.expanded || this.barLayout === BAR_LAYOUT_VERTICAL
          || this.currentBreakpoint !== BreakpointConstants.BREAKPOINT_SM) {
          this.ExpandedContent()
        } else {
          // 水平融合 + 收起：HDS 把槽位缩到圆盘大小，只装得下封面
          this.CollapsedContent()
        }
      }
      .width('100%')
      .height('100%')
      // ⚠️ 这里**不要**挂 `onAreaChange`（曾用它实测槽位高来自适应圆盘尺寸）：
      // 在 HDS 托管的内容里由布局回调回写 @State，会让内容在 HDS 的形变动画中途重建，
      // 真机症状 = 垂直两层下展开迷你栏直接消失。圆盘尺寸改用常量（见 coverSize）。
    }
  }
}
