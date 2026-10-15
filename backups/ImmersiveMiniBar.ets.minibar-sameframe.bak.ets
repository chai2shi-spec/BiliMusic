/**
 * 悬浮沉浸底栏的官方 miniBar 槽位内容（NavBarStyle.IMMERSIVE）。
 *
 * 宿主：Index.floatingImmersiveNav 里的 HdsTabs.barFloatingStyle.miniBar
 * （HdsTabsMiniBar，6.1.0(23) 起）—— 迷你栏与页签栏同高、水平对齐，悬浮离底、
 * 沉浸光感（systemMaterialEffect → hdsMaterial IMMERSIVE）、深浅色自适应全部
 * 由 HDS 统一渲染，本组件只负责迷你栏**内容**，不带定位与背景。
 *
 * ⚠️ HDS 会缓存 miniBarBuilder 内容：本组件必须是独立 @Component 订阅
 * AppStorage（切歌 / 播放态实时刷新），与融合胶囊的 PlayBar 同款架构。
 *
 * 内容（悬浮沉浸形态的播放控件）—— 展开态 / 收起态两套（HDS 缓存 builder，
 * 状态走 AppStorage 切换，PlayBar 同款；本组件订阅的是**视觉态键**
 * STORE_MINI_BAR_VISUAL_COLLAPSED，由 HDS 动画回调方向感知写入：展开方向形变
 * 首拍切、收起方向形变末拍（onMiniBarAnimationEnd）切 —— 收起是展开的时序镜像，
 * 内容体全程跟随槽位「边收起边移动」，与请求态键 STORE_MINI_BAR_COLLAPSED 解耦，
 * 避免「先变小、后再收起」两段式动画）：
 *   · 展开（视觉态 false，默认）：
 *     左 旋转唱片（32vp 封面 + 黑胶中心白点；播放旋转 / 暂停冻结 / 切歌归零，
 *         AnimatorResult 逐帧回写角度，与 PlayBar 同款实现）；
 *     中 歌名 / 歌手（12/10fp，layoutWeight 吃富余宽度，超长省略）；
 *     右 上一首（backward_end_fill）+ 播放/暂停（与播放页同款图标）。
 *     点击整条跳播放详情页（animateTo + pushPath，配合唱片 geometryTransition
 *     一镜到底；转场进行中连点防护复用 STORE_PLAYER_TRANSITIONING）。
 *   · 收起（滚动下滚跨阈值，Index 经 applyMiniBarStyle 收进页签栏）：
 *     紧凑迷你条 —— 32vp 旋转唱片 +「歌名 - 歌手」单行省略 + 播放/暂停键 +
 *     底部 2vp 细进度条（STORE_PROGRESS/DURATION 500ms 分桶推送，细条上
 *     步进不可见，不做插值）。
 *   · 两态切换过渡：HDS 槽位形变动效为内建固定时长（applyMiniBarStyle 无时长
 *     参数，仅 onMiniBarAnimationStart/End 回调，SDK 不开放配置），因此放缓
 *     观感的可控部分在这里 —— 唱片恒驻不重挂载（旋转连续、geometryTransition
 *     同 id 节点任一时刻仅一个），内容体在 Stack 内交叉淡入淡出（CONTENT_FADE_MS）。
 *   · 点条身：收起态经 onExpandRequest 请求宿主重新展开（不直接进播放页，
 *     避免误触，PlayBar 收起态同款交互）；展开态进播放详情页。播放键自有
 *     onClick 不冒泡。
 *
 * 边界：歌单队列为空 / 无在播曲目时本组件不渲染；Index 侧还会整体摘除
 * miniBar 槽位（barFloatingStyle 不带 miniBar），页签栏退回纯页签形态。
 */

import { Track } from '../model/MusicModels';
import { MusicPlayer } from '../player/MusicPlayer';
import { NavStackHolder } from '../service/NavStackHolder';
import { toThumbUrl } from '../utils/TextUtil';
import { CoverImage } from './CoverImage';
import { AnimatorOptions, AnimatorResult } from '@kit.ArkUI';
import {
  STORE_CURRENT_TRACK,
  STORE_IS_PLAYING,
  STORE_QUEUE,
  STORE_MINI_BAR_VISUAL_COLLAPSED,
  STORE_PLAYER_TRANSITIONING,
  STORE_PROGRESS,
  STORE_DURATION,
  GEOMETRY_ID_PLAYER_DISC,
  PLAYER_TRANSITION_MS
} from '../common/Constants';

/** 展开态唱片封面边长（vp）：迷你栏与页签栏同高，32vp 圆盘 + 文字 + 双键刚好铺满 */
const COVER_SIZE: number = 32;
/** 收起态「歌名 - 歌手」字号（fp）：单行省略，比展开态歌名小一档更收敛 */
const COLLAPSED_TEXT_SIZE: number = 11;
/** 收起态播放/暂停图标字号（vp）：无上一首键，比展开态播放键小一档 */
const COLLAPSED_PLAY_ICON_SIZE: number = 24;
/**
 * 收起/展开内容体交叉淡入淡出时长（ms）：与 HDS 槽位形变（内建约 300ms 量级）
 * 对齐 —— 视觉态方向感知翻转（见 STORE_MINI_BAR_VISUAL_COLLAPSED）：展开方向在
 * HDS 动画首拍翻转（内容体淡入与槽位生长同帧起跑）；收起方向在形变落定
 * （onMiniBarAnimationEnd）翻转 —— 内容体全程保持展开态「边收起边移动」，
 * 落定后 300ms 内淡入紧凑体收尾。旧值 400 为请求态早切时代的「余韵」补偿。
 */
const CONTENT_FADE_MS: number = 300;
/** 黑胶中心白点直径（vp，纯装饰，不参与几何转场） */
const DISC_HUB_SIZE: number = 6;
/** 上一首图标字号（vp） */
const PREV_ICON_SIZE: number = 22;
/** 播放/暂停图标字号（vp，视觉锚点比上一首大一档） */
const PLAY_ICON_SIZE: number = 28;
const DISC_ROTATE_DEGREE: number = 360;
const DISC_ROTATE_MS: number = 4000;

@Component
export struct ImmersiveMiniBar {
  /** 播放队列（歌单列表）：为空时内容不渲染 */
  @StorageLink(STORE_QUEUE) queue: Track[] = [];
  /** 在播曲目：封面 / 歌名 / 歌手的数据源；@Watch 切歌时重置唱片角度 */
  @StorageLink(STORE_CURRENT_TRACK) @Watch('onTrackChanged') currentTrack: Track | null = null;
  /** 播放中标志：切换播放 / 暂停图标；@Watch 驱动唱片 play / pause */
  @StorageLink(STORE_IS_PLAYING) @Watch('onPlayingChanged') isPlaying: boolean = false;

  /** 唱片当前旋转角度（°）：animator 每帧回写，暂停时冻结在当前值 */
  @State rotateAngle: number = 0;
  /** 播放/暂停键的点击回弹缩放（独立状态，与唱片旋转互不相干） */
  @State playScale: number = 1;

  /**
   * 收起进页签栏的**视觉态**（HDS 形变当前时序上的样式）：true 时仅渲染收起体。
   * ⚠️ 订阅的是视觉态键（STORE_MINI_BAR_VISUAL_COLLAPSED，由 Index 的 HDS 动画回调
   * 方向感知写入：展开首拍切 / 收起末拍 onMiniBarAnimationEnd 切），不是请求态键
   * （STORE_MINI_BAR_COLLAPSED，滚动吸附 / onExpandRequest 写）—— 内容体跟请求态
   * 切换会在 HDS 形变开始前就变紧凑，视觉上「先完整收起、之后再移动」
   * 两段式（2026-10-13 镜像修复：收起 = 展开的反向路径）。展开请求经
   * onExpandRequest 由宿主调 applyMiniBarStyle，不在本组件直接改键
   * （单向数据流，PlayBar 同款）。
   */
  @StorageProp(STORE_MINI_BAR_VISUAL_COLLAPSED) collapsed: boolean = false;

  /** 收起态点击圆盘的宿主回调（Index 回调 applyMiniBarStyle(EXPAND)），可不传 */
  onExpandRequest?: () => void = undefined;

  /** 播放进度（秒，500ms 分桶推送）：收起态底部细进度条 */
  @StorageLink(STORE_PROGRESS) progressSec: number = 0;
  /** 曲目总时长（秒）：收起态底部细进度条的分母；0（音源未就绪）时不渲染进度条 */
  @StorageLink(STORE_DURATION) durationSec: number = 0;

  /** 唱片旋转 animator：play=续转 / pause=冻结 / reset=归零（aboutToAppear 里创建） */
  private coverAnim: AnimatorResult | null = null;

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
    // UIContext 在属性初始化时未就绪，animator 延迟到 here 创建（同 PlayBar）
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
      console.error(`[ImmersiveMiniBar] createAnimator failed: ${msg}`);
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
      console.error(`[ImmersiveMiniBar] animator reset failed: ${msg}`);
      return;
    }
    if (this.isPlaying) {
      anim.play();
    }
  }

  private coverUrl(): string {
    return this.currentTrack !== null ? this.currentTrack.coverUrl : '';
  }

  /** 收起态文案：「歌名 - 歌手」拼接（无在播曲目兜空串） */
  private trackText(): string {
    return this.currentTrack !== null ? `${this.currentTrack.title} - ${this.currentTrack.artist}` : '';
  }

  /** 播放/暂停键点击回弹：一次快速缩小回弹（一次性关键帧，无持续动画无定时器） */
  private bouncePlay(): void {
    this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
      {
        duration: 0,
        event: (): void => {
          this.playScale = 1;
        }
      },
      {
        duration: 80,
        curve: Curve.EaseIn,
        event: (): void => {
          this.playScale = 0.82;
        }
      },
      {
        duration: 140,
        curve: Curve.EaseOut,
        event: (): void => {
          this.playScale = 1.06;
        }
      },
      {
        duration: 80,
        curve: Curve.EaseOut,
        event: (): void => {
          this.playScale = 1;
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
   * 连点防护复用转场标志：进出播放页全程为真，双 push 会叠两层播放页。
   */
  private gotoPlayer(): void {
    if (AppStorage.get<boolean>(STORE_PLAYER_TRANSITIONING) ?? false) {
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
   * 恒驻旋转唱片：装在两态 if/else 之外，收起/展开切换不重挂载 ——
   * 旋转角度连续（animator 不中断），geometryTransition 同 id 节点
   * 任一时刻仅一个（避免过渡期间双节点竞争转场）。
   */
  @Builder
  Disc(): void {
    // rotate / geometryTransition 挂在 CoverImage 根节点上，与播放页大圆盘
    // （CoverDiscComponent）同 id 配对，一镜到底不受影响；
    // 32vp 圆盘按 96px 请求缩略图（3x 屏仍清晰），占位由 CoverImage 兜。
    Stack() {
      CoverImage({
        url: toThumbUrl(this.coverUrl(), 96),
        imgWidth: COVER_SIZE,
        imgHeight: COVER_SIZE,
        imgRadius: COVER_SIZE / 2
      })
        .rotate({ z: 1, angle: this.rotateAngle })
        .geometryTransition(GEOMETRY_ID_PLAYER_DISC)
      // 黑胶中心白点：纯装饰层，叠在封面上、不参与旋转与几何转场
      //（不用 Circle：其 fill 属性 SDK 26 才有类型，borderRadius 圆角 div 无版本顾虑）
      Column()
        .width(DISC_HUB_SIZE)
        .height(DISC_HUB_SIZE)
        .borderRadius(DISC_HUB_SIZE / 2)
        .backgroundColor(Color.White)
        .opacity(0.85)
    }
    .width(COVER_SIZE)
    .height(COVER_SIZE)
  }

  /** 展开内容体：歌名/歌手 + 上一首 + 播放/暂停（唱片在外层恒驻），切换时淡入淡出 */
  @Builder
  ExpandedBody(): void {
    Row({ space: 8 }) {
      // 歌名 / 歌手，超长省略
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

      // 上一首（图标与播放页 ControlAreaComponent 同款 backward_end_fill）
      SymbolGlyph($r('sys.symbol.backward_end_fill'))
        .fontSize(PREV_ICON_SIZE)
        .fontColor([$r('sys.color.icon_primary')])
        .onClick((): void => {
          this.player.prev();
        })

      // 播放/暂停（图标与 PlayBar / 播放页同款，点击回弹）
      SymbolGlyph(this.isPlaying ? $r('sys.symbol.pause_round_triangle_fill') : $r('sys.symbol.play_round_triangle_fill'))
        .fontSize(PLAY_ICON_SIZE)
        .fontColor([$r('sys.color.icon_primary')])
        .scale({ x: this.playScale, y: this.playScale })
        .onClick((): void => {
          this.player.togglePlay();
          this.bouncePlay();
        })
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .transition(TransitionEffect.OPACITY.animation({ duration: CONTENT_FADE_MS, curve: Curve.EaseInOut }))
  }

  /** 收起内容体：「歌名 - 歌手」+ 播放/暂停（进度条在外层全宽贴底），切换时淡入淡出 */
  @Builder
  CollapsedBody(): void {
    Row({ space: 8 }) {
      // 「歌名 - 歌手」单行省略
      Text(this.trackText())
        .fontSize(COLLAPSED_TEXT_SIZE)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      // 播放/暂停（图标与展开态同款，点击回弹；无上一首键，保持收起态克制）
      SymbolGlyph(this.isPlaying ? $r('sys.symbol.pause_round_triangle_fill') : $r('sys.symbol.play_round_triangle_fill'))
        .fontSize(COLLAPSED_PLAY_ICON_SIZE)
        .fontColor([$r('sys.color.icon_primary')])
        .scale({ x: this.playScale, y: this.playScale })
        .onClick((): void => {
          this.player.togglePlay();
          this.bouncePlay();
        })
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .transition(TransitionEffect.OPACITY.animation({ duration: CONTENT_FADE_MS, curve: Curve.EaseInOut }))
  }

  build() {
    // 边界：队列空 / 无在播曲目 → 不渲染（Index 侧同时会摘除 miniBar 槽位）
    if (this.queue.length > 0 && this.currentTrack !== null) {
      Stack({ alignContent: Alignment.Bottom }) {
        // 主行：恒驻唱片 + 内容体。内容体装在内层 Stack 里交叉淡入淡出 ——
        // 出场节点不再参与外层布局，避免 400ms 过渡期间两个 layoutWeight
        // 内容体互相挤压分宽。
        Row({ space: 8 }) {
          this.Disc()
          Stack() {
            if (this.collapsed) {
              this.CollapsedBody()
            } else {
              this.ExpandedBody()
            }
          }
          .layoutWeight(1)
          .height('100%')
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 10, right: 10 })

        // 收起态底部细进度条：全宽贴底（不受主行 padding 影响）；时长未知
        // （0，音源未就绪）不渲染，value 夹取防瞬时越界。
        if (this.collapsed && this.durationSec > 0) {
          Progress({
            value: Math.max(0, Math.min(this.progressSec, this.durationSec)),
            total: this.durationSec,
            type: ProgressType.Linear
          })
            .width('100%')
            .height(2)
            .color($r('app.color.bili_pink'))
            .backgroundColor($r('app.color.progress_track'))
            .transition(TransitionEffect.OPACITY.animation({ duration: CONTENT_FADE_MS, curve: Curve.EaseInOut }))
        }
      }
      .width('100%')
      .height('100%')
      .stateStyles({
        pressed: { .opacity(0.85) },
        normal: { .opacity(1) }
      })
      // 点条身：收起态请求宿主重新展开（不直接进播放页，避免误触）；
      // 展开态进播放详情页。子控件（播放/暂停、上一首）自有 onClick 不冒泡。
      .onClick((): void => {
        if (this.collapsed) {
          if (this.onExpandRequest !== undefined) {
            this.onExpandRequest();
          }
        } else {
          this.gotoPlayer();
        }
      })
    }
  }
}
