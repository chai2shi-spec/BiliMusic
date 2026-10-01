/**
 * 单曲列表项。网络封面直接由 Image 加载（需 INTERNET 权限）。
 * 通过函数属性 onPlay / onMore 把交互交回父页面。
 *
 * ⚠️ 条目内**不放播放图标**（曾有一个粉色的 `Text('▶')`）：
 * 整行本身就是 `onPlay` 的点击区，条目右侧再挂一个播放三角是重复入口，
 * 也和右侧「⋯」挤在一起。播放靠「点整行」，不要加回来。
 *
 * 第二行＝「歌手 + 时长」：时长紧跟在歌手文本之后（右侧对齐），歌手过长先省略，时长始终可见。
 *
 * ⚠️ 触达尺寸（易用性审计结论）：
 * 整行是 `onPlay`，「⋯」是 `onMore`，两个热区原本**紧贴**且「⋯」只有文字宽度
 * （约 20×28）→ 想点「⋯」会误触发播放。修法是保持「⋯」的**视觉**不变，
 * 但用 `width(44).height(44)` 把它的**命中区**撑到 44vp 最小标准，
 * 并在行内容与它之间留出 `MORE_HIT / 2` 的缓冲，两个热区不再相互覆盖。
 * 44vp 是手指可靠触达的下限（约 7mm），低于它就会频繁点错。
 *
 * 按压反馈＝纯缩放形变（0.9 / 150ms EaseOut，见 pressScale）：
 * 不改底色、不加蒙层、不引额外层级，动画状态本条目独占（详见 struct 内注释）。
 */

import { Track, buildTrack } from '../model/MusicModels';
import {
  PRESS_SCALE,
  PRESS_ANIM_MS,
  ENTRANCE_OFFSET_VP,
  ENTRANCE_DURATION_MS,
  ENTRANCE_STAGGER_MS,
  ENTRANCE_MAX_ITEMS
} from '../common/constants/InteractionConstants';

/** 「⋯」命中区边长，也是它占位的宽高（视觉仍是 20px 字号，靠居中留白撑开） */
const MORE_HIT: number = 44;

/**
 * 时长文本（秒 → `m:ss`，超过一小时给 `h:mm:ss`）。
 *
 * 返回**空串**表示「没有时长」而不显示占位：音乐中心的条目普遍没有时长字段
 * （映射出来是 `0`），显示 `0:00` 会像信息错乱。`!(total > 0)` 的写法顺带把
 * `NaN` 也挡掉（`NaN > 0` 为 false）。
 */
function formatDuration(seconds: number): string {
  const total: number = Math.floor(seconds);
  if (!(total > 0)) {
    return '';
  }
  const h: number = Math.floor(total / 3600);
  const m: number = Math.floor((total % 3600) / 60);
  const s: number = total % 60;
  const mm: string = m < 10 ? `0${m}` : `${m}`;
  const ss: string = s < 10 ? `0${s}` : `${s}`;
  if (h > 0) {
    return `${h}:${mm}:${ss}`;
  }
  return `${m}:${ss}`;
}

@Component
export struct TrackItem {
  @Prop track: Track = buildTrack({});
  @Prop showCover: boolean = true;
  @Prop showIndex: number = -1;
  onPlay: (track: Track) => void = (): void => {};
  onMore: (track: Track) => void = (): void => {};

  /**
   * 按压缩放（独立动画状态，本条目独占）：按下 0.9，抬起/取消回 1.0。
   *
   * 设计约束（按压反馈改版结论）：
   * - **只做形变**：不碰 backgroundColor、不加按压蒙层/底色/高亮 —— 上一版
   *   stateStyles 的 press_overlay 底色方案已按新规范移除（资源本身其他页面
   *   仍在用，保留）。
   * - **独立隔离**：专用 @State + 紧跟 .scale() 的独立 .animation()，
   *   不与任何其他组件的动画状态（HdsTabs、miniBar 唱片旋转、播放按钮形变、
   *   搜索框动画）共用变量，互不干扰。
   * - **零额外层级**：scale 直接挂在根 Row 上，不引入包装容器，保持原布局。
   * - 属性动画无循环无定时器，组件销毁无需清理（无内存泄漏风险）。
   */
  @State pressScale: number = 1;

  /**
   * 入场错峰（可选）：父列表把它在 ForEach 里的**下标**传进来，前 ENTRANCE_MAX_ITEMS 条
   * （首屏可见范围）做「下移 10vp + 淡入」的错峰入场，其余条目直接出现。
   * 默认 -1 = 不启用（未传下标的页面行为完全不变）。
   */
  @Prop entranceIndex: number = -1;
  /** 入场位移（vp）：10 → 0；仅错峰条目在挂载时被置为起始值 */
  @State enterOffsetY: number = 0;
  /** 入场透明度：0 → 1 */
  @State enterOpacity: number = 1;
  /** 错峰只播一次：@Prop 下标变化（增删条目导致索引位移）不重播 */
  private entranceDone: boolean = false;

  aboutToAppear(): void {
    if (this.entranceIndex >= 0 && this.entranceIndex < ENTRANCE_MAX_ITEMS) {
      this.enterOffsetY = ENTRANCE_OFFSET_VP;
      this.enterOpacity = 0;
    }
  }

  /** 本条目要显示的时长文本；返回空串＝该条目没有时长信息，整块不渲染 */
  private durationText(): string {
    return formatDuration(this.track.duration);
  }

  /**
   * 错峰入场：挂载后一次性触发（entranceDone 防重播）。
   * 单条 normal(250ms) EaseOut，相邻条目延迟 35ms；非首屏条目（下标 ≥ 8）不进入，
   * 直接随列表出现——否则长列表滚到底部时新条目还在逐条错峰。
   */
  private playEntrance(): void {
    if (this.entranceDone) {
      return;
    }
    if (this.entranceIndex < 0 || this.entranceIndex >= ENTRANCE_MAX_ITEMS) {
      return;
    }
    this.entranceDone = true;
    this.getUIContext().animateTo({
      duration: ENTRANCE_DURATION_MS,
      curve: Curve.EaseOut,
      delay: this.entranceIndex * ENTRANCE_STAGGER_MS
    }, (): void => {
      this.enterOffsetY = 0;
      this.enterOpacity = 1;
    });
  }

  build() {
    Row() {
      if (this.showCover) {
        Image(this.track.coverUrl)
          .width(48)
          .height(48)
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
      }

      Column() {
        Text(this.track.title)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row() {
          Text(this.track.artist)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          // 时长跟在歌手后面。歌手用 layoutWeight(1) 吃掉剩余宽度，
          // 于是时长被推到行尾（歌手过长时先省略歌手，时长不被挤掉）。
          if (this.durationText().length > 0) {
            Text(this.durationText())
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .margin({ left: 8 })
          }
        }
        .width('100%')
        .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })

      // 「⋯」：视觉 20px 文字不变，但命中区撑到 44×44（居中留白），
      // 并把原来 left:14 的 margin 收进自身宽度，避免热区与整行 onPlay 重叠。
      Row() {
        Text('⋯')
          .fontSize(20)
          .fontColor($r('app.color.text_secondary'))
      }
      .width(MORE_HIT)
      .height(MORE_HIT)
      .justifyContent(FlexAlign.Center)
      .onClick((): void => {
        this.onMore(this.track);
      })
    }
    .width('100%')
    .padding({ left: 16, right: 4, top: 10, bottom: 10 })
    // 按压态：整行可点但原先**零反馈**，用户点下去不知道是否命中。
    // 反馈方式＝纯缩放形变（见 pressScale 注释）：按下收到 0.9 的收缩确认，
    // 抬起/取消回弹到 1.0 —— 不改底色、不加蒙层，scale 直接挂根 Row 不加层。
    // .animation() 紧跟 .scale() 且位于链尾：只对 scale 这一个可变属性生效，
    // width/padding 在其之前但从不变化，不会被卷进动画。
    .scale({ x: this.pressScale, y: this.pressScale })
    .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
    // 入场错峰：translate/opacity 必须声明在 .animation() **之后** ——
    // 隐式 .animation() 只接管声明在它之前的可动画属性，放前面会让入场位移
    // 被按压动画的 150ms 配置接管（错峰延迟丢失、时长错乱）。由 onAppear 里
    // 的显式 animateTo 单独驱动，与 pressScale 互不干扰。
    .translate({ y: this.enterOffsetY })
    .opacity(this.enterOpacity)
    .onAppear((): void => {
      this.playEntrance();
    })
    // onTouch 只回写缩放状态、不消费事件：onClick 照常在抬起时触发，
    // 缩放动画不会拦截点击；列表滚动抢占手势时系统派发 Cancel，条目自动回弹。
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressScale = PRESS_SCALE;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressScale = 1;
      }
    })
    .onClick((): void => {
      this.onPlay(this.track);
    })
  }
}
