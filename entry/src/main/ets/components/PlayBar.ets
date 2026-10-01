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
 * 只认用户点击与控制器调用）：
 *   · EXPAND   ：封面 + 歌名/歌手 + 上一首/播放暂停/下一首，点条目进全屏播放页；
 *   · COLLAPSE ：仅封面圆盘（默认折叠态），点它经 onExpandRequest
 *                通知宿主 applyMiniBarStyle(EXPAND) 重新展开（Sumy 同款交互）。
 *   两态切换由 Index 的 onBarStyleChange 写入 AppStorage（STORE_MINI_BAR_EXPANDED），
 *   本组件只读订阅 —— miniBarBuilder 内容会被 HDS 缓存，状态必须走全局存储。
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
 * 自动调度（小屏收起成圆盘、大屏展开整行），组件内容随全局状态自适应。
 *
 * 边界：歌单队列为空 / 无在播曲目时本组件不渲染；Index 侧还会整体摘除
 * miniBar 槽位（barFloatingStyle 不带 miniBar），胶囊退回纯页签形态。
 */

import { Track } from '../model/MusicModels';
import { MusicPlayer } from '../player/MusicPlayer';
import { NavStackHolder } from '../service/NavStackHolder';
import { AnimatorOptions, AnimatorResult } from '@kit.ArkUI';
import {
  STORE_CURRENT_TRACK,
  STORE_IS_PLAYING,
  STORE_QUEUE,
  STORE_PLAYER_TRANSITIONING,
  STORE_MINI_BAR_EXPANDED,
  GEOMETRY_ID_PLAYER_DISC,
  PLAYER_TRANSITION_MS
} from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';

/** 展开态封面边长（胶囊内空间有限，比独立底栏小一号） */
const COVER_EXPANDED: number = 32;
const COVER_COLLAPSED: number = 40;
const CTRL_ICON_SIZE: number = 16;
/** 播放 / 暂停图标尺寸（略大作视觉锚点） */
const PLAY_ICON_SIZE: number = 20;
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
  /** miniBar 展开 / 收起态（Index 的 onBarStyleChange 写入，这里只读；默认折叠） */
  @StorageProp(STORE_MINI_BAR_EXPANDED) expanded: boolean = false;
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
    AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, true);
    this.getUIContext().animateTo(
      { duration: PLAYER_TRANSITION_MS, curve: Curve.EaseInOut },
      (): void => {
        NavStackHolder.stack.pushPath({ name: 'Player' });
      }
    );
  }

  /** 展开：封面 + 歌名/歌手 + 三键控制，点条目进播放页（按钮点击不会冒泡成跳转） */
  @Builder
  ExpandedContent(): void {
    Row({ space: 8 }) {
      Image(this.coverUrl())
        .width(COVER_EXPANDED)
        .height(COVER_EXPANDED)
        .borderRadius(COVER_EXPANDED / 2)
        .objectFit(ImageFit.Cover)
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
        SymbolGlyph($r('sys.symbol.backward_end_fill'))
          .fontSize(CTRL_ICON_SIZE)
          .fontColor([$r('sys.color.icon_primary')])
          .stateStyles({
            pressed: { .opacity(0.55) },
            normal: { .opacity(1) }
          })
          .onClick((): void => {
            this.player.prev();
          })

        SymbolGlyph(this.isPlaying ? $r('sys.symbol.pause_round_triangle_fill') : $r('sys.symbol.play_round_triangle_fill'))
          .fontSize(PLAY_ICON_SIZE)
          .fontColor([$r('sys.color.icon_primary')])
          .scale({ x: this.miniPlayScale, y: this.miniPlayScale })
          .onClick((): void => {
            this.player.togglePlay();
            this.bounceMiniPlay();
          })

        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(CTRL_ICON_SIZE)
          .fontColor([$r('sys.color.icon_primary')])
          .stateStyles({
            pressed: { .opacity(0.55) },
            normal: { .opacity(1) }
          })
          .onClick((): void => {
            this.player.next();
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

  /** 收起：仅封面圆盘，点击经宿主回调重新展开（不直接进播放页，避免误触） */
  @Builder
  CollapsedContent(): void {
    Stack() {
      Image(this.coverUrl())
        .width(COVER_COLLAPSED)
        .height(COVER_COLLAPSED)
        .borderRadius(COVER_COLLAPSED / 2)
        .objectFit(ImageFit.Cover)
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
        // 宽屏（md/lg）强制按展开态渲染：HDS 已把槽位固定为展开布局，全局状态
        // 若还停在折叠（收起内容 + onExpandRequest 宽屏死胡同）必然点不动；
        // 展开态点击直达播放页，与手机上的交互闭环保持一致。
        if (this.expanded || this.currentBreakpoint !== BreakpointConstants.BREAKPOINT_SM) {
          this.ExpandedContent()
        } else {
          this.CollapsedContent()
        }
      }
      .width('100%')
      .height('100%')
    }
  }
}
