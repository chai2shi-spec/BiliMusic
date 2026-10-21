/**
 * 播放页圆形封面 + 唱片旋转（独立子组件，SM / LG 布局共用）。
 *
 * 封面：圆形裁切（50%）+ 深色柔和投影；与 miniBar 唱片同 id 的
 * geometryTransition 一镜到底（圆 ↔ 圆，形态完全一致）。
 *
 * 唱片旋转（与 PlayBar 同一套 AnimatorResult 方案，本组件自持一份实例）：
 *   UIContext.createAnimator（0°→360°，linear，无限循环）每帧回写 rotateAngle
 *   → Image.rotate 跟转。播放 play() 续转、暂停 pause() 冻结当前角度、
 *   切歌 reset() 归零后再按播放态决定是否续转。大封面转速放缓到 20s/圈，
 *   与 miniBar 小圆盘的 4s/圈区分开，保持整页动效柔和克制。
 *
 * 性能：旋转只动 rotate（合成器属性，不触发重排重绘）；
 * animator 在 aboutToDisappear 统一清理。
 */

import { AnimatorOptions, AnimatorResult } from '@kit.ArkUI';
import { Track } from '../../model/MusicModels';
import {
  GEOMETRY_ID_PLAYER_DISC,
  STORE_CURRENT_TRACK,
  STORE_IS_PLAYING,
  STORE_PLAYER_OPEN,
  STORE_APP_FOREGROUND
} from '../../common/Constants';

/** 大封面转速：20s 一圈（小圆盘 PlayBar 是 4s/圈，大封面放缓更克制） */
const COVER_ROTATE_MS: number = 20000;
const COVER_ROTATE_DEGREE: number = 360;
/** discSize 未指定（0）时的钳制哨兵：远大于任何真实列宽，等效不钳制 */
const DISC_CAP_UNLIMITED: number = 100000;

@Component
export struct CoverDiscComponent {
  @StorageLink(STORE_CURRENT_TRACK) @Watch('onTrackChanged') currentTrack: Track | null = null;
  @StorageLink(STORE_IS_PLAYING) @Watch('onPlayingChanged') isPlay: boolean = false;
  /** 前后台标志（2026-10-21 后台耗电优化）：退后台冻结旋转，回前台在播时续转 */
  @StorageProp(STORE_APP_FOREGROUND) @Watch('onForegroundChanged') appForeground: boolean = true;
  /**
   * 播放页展开态（2026-10-21 组件状态切换动画改版）：大唱片内容**只在展开态渲染**。
   * 打开主动画（PlayerInfoComponent.playEnterTransition 的单个 animateTo）里
   * STORE_PLAYER_OPEN 翻 true → 本组件内容 if 出现，与 PlayBar 迷你唱片 if 消失
   **同帧配对* → geometryTransition 页内飞行（圆→圆，独立于容器延展）。
   * 收起（Index.closePlayer 的 animateTo 写 false）时逆向回飞。未展开时 Stack
   * 空挂（尺寸恒定，布局零跳动）。
   */
  @StorageProp(STORE_PLAYER_OPEN) playerOpen: boolean = false;

  /**
   * 圆盘边长上限（vp），由宿主按「内容列高 − 标题块 − 控制区」实测预算后传入；
   * 0 = 不钳制，纯宽度驱动（旧行为，仅瘦长屏成立）。
   * 宽折叠（展开 1292×914vp / 折起 632×924vp）列宽接近列高，宽度驱动的圆盘
   * 会把进度条与三键控制整块挤出屏幕底部 —— 必须按高度预算钳。
   * 必须 @Prop：宿主在 onAreaChange 实测后才回填预算，普通成员变量只在
   * 创建时赋值一次、后续父组件更新不同步也不触发本组件重渲染。
   */
  @Prop @Watch('onDiscSizeChanged') discSize: number = 0;

  /** 唱片当前旋转角度（°）：animator 每帧回写，暂停时冻结在当前值 */
  @State rotateAngle: number = 0;
  /** 封面加载失败标记：切歌复位；失败时回落到下方 ♪ 兜底块，不留白 */
  @State coverFailed: boolean = false;
  /** 唱片旋转 animator（aboutToAppear 创建，销毁时 finish） */
  private coverAnim: AnimatorResult | null = null;

  /** 旋转动画参数（创建与 reset 复用同一份配置） */
  private discOptions(): AnimatorOptions {
    return {
      duration: COVER_ROTATE_MS,
      easing: 'linear',
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: -1,
      begin: 0,
      end: COVER_ROTATE_DEGREE
    };
  }

  aboutToAppear(): void {
    // UIContext 在属性初始化时未就绪，animator 延迟到这里创建（同 PlayBar / LrcView）
    try {
      this.coverAnim = this.getUIContext().createAnimator(this.discOptions());
      this.coverAnim.onFrame = (value: number): void => {
        this.rotateAngle = value;
      };
      // 挂载时可能已在播放中（@Watch 不会触发，需手动起转）
      if (this.isPlay && this.appForeground) {
        this.coverAnim.play();
      }
    } catch (e) {
      // animator 创建失败只影响旋转，不影响其他内容
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`[CoverDisc] createAnimator failed: ${msg}`);
    }
  }

  aboutToDisappear(): void {
    if (this.coverAnim !== null) {
      this.coverAnim.finish();
      this.coverAnim = null;
    }
  }

  /** 播放态变化：旋转续转/冻结（统一走 syncDiscAnim） */
  onPlayingChanged(_propName: string): void {
    this.syncDiscAnim();
  }

  /** 退后台冻结 / 回前台续转（在播时），统一走 syncDiscAnim */
  onForegroundChanged(_propName: string): void {
    this.syncDiscAnim();
  }

  /** 旋转统一入口：前台且在播才续转，否则冻结在当前角度（绝不复位到 0） */
  private syncDiscAnim(): void {
    const anim: AnimatorResult | null = this.coverAnim;
    if (anim === null) {
      return;
    }
    if (this.isPlay && this.appForeground) {
      anim.play();
    } else {
      anim.pause();
    }
  }

  /** 宿主实测预算回填（@Prop 同步）——暂留诊断日志，验证通过后可删 */
  onDiscSizeChanged(_propName: string): void {
    console.info(`[CoverDisc] discSize synced: ${this.discSize}`);
  }

  /** 切歌 → 旋转归零（等价 Stopped），再按播放态决定是否重新起转 */
  onTrackChanged(_propName: string): void {
    // 新曲目新封面：失败标记必须最先复位（下方 animator 未就绪时会提前 return）
    this.coverFailed = false;
    const anim: AnimatorResult | null = this.coverAnim;
    if (anim === null) {
      return;
    }
    this.rotateAngle = 0;
    try {
      anim.reset(this.discOptions());
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`[CoverDisc] animator reset failed: ${msg}`);
      return;
    }
    // 后台切歌不起转：回前台时 onForegroundChanged 会按播放态补起转
    if (this.isPlay && this.appForeground) {
      anim.play();
    }
  }

  private coverUrl(): string {
    return this.currentTrack !== null ? this.currentTrack.coverUrl : '';
  }

  /** 钳制上限：discSize 有效取值，否则哨兵值（等效不钳制） */
  private discCap(): number {
    return this.discSize !== undefined && this.discSize > 0 ? this.discSize : DISC_CAP_UNLIMITED;
  }

  build() {
    Stack() {
      // 展开态才渲染内容（见 playerOpen 注释）：与 PlayBar 迷你唱片的 if 翻转
      // 落在同一个 animateTo 内 → geometryTransition 页内配对飞行。
      if (this.playerOpen) {
        if (this.coverUrl().length > 0 && !this.coverFailed) {
          Image(this.coverUrl())
            .width('100%')
            .aspectRatio(1)
            .borderRadius('50%')
            .objectFit(ImageFit.Cover)
            .draggable(false)
            .rotate({ z: 1, angle: this.rotateAngle })
            .shadow({ radius: 28, color: 'rgba(0, 0, 0, 0.45)', offsetX: 0, offsetY: 10 })
            .geometryTransition(GEOMETRY_ID_PLAYER_DISC)
            // 加载失败回落到 ♪ 兜底块，不留白
            .onError((err: ImageError): void => {
              this.coverFailed = true;
            })
        } else {
          Column() {
            Text('♪')
              .fontSize(64)
              .fontColor(Color.White)
              .opacity(0.6)
          }
          .width('100%')
          .aspectRatio(1)
          .borderRadius('50%')
          .backgroundColor('rgba(255, 255, 255, 0.12)')
          .justifyContent(FlexAlign.Center)
        }
      }
    }
    // aspectRatio(1) + constraintSize(maxWidth) 组合：宽度先按 100% 解析、再被
    // 高度预算钳制，高度随钳后宽度同步收缩 —— 圆盘任何情况下都是正方形，
    // 不会出现 maxWidth 钳宽后变椭圆的问题。
    .width('100%')
    .aspectRatio(1)
    .constraintSize({ maxWidth: this.discCap() })
  }
}
