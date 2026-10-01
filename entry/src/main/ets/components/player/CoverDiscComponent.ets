/**
 * 播放页圆形封面 + 唱片旋转 + 呼吸光晕（独立子组件，SM / LG 布局共用）。
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
 * 光晕：封面同尺寸的光晕层（半透明白 + 大半径白色柔光 shadow），
 * 播放时大小 / 透明度做**缓慢不规则呼吸**（随机时长 1.8~3.4s +
 * 随机目标，scale 1.0~1.07、opacity 0.5~0.9，无固定周期）；
 * 暂停时**定格** —— 只停调度、保留当前值，不归零不复位。
 * 强度刻意压低，不与主播放按钮抢视觉焦点。
 *
 * 性能：呼吸只动 scale / opacity、旋转只动 rotate（均为合成器属性，
 * 不触发重排重绘）；animator 与定时器在 aboutToDisappear 统一清理。
 */

import { AnimatorOptions, AnimatorResult } from '@kit.ArkUI';
import { Track } from '../../model/MusicModels';
import { GEOMETRY_ID_PLAYER_DISC, STORE_CURRENT_TRACK, STORE_IS_PLAYING } from '../../common/Constants';

/** 大封面转速：20s 一圈（小圆盘 PlayBar 是 4s/圈，大封面放缓更克制） */
const COVER_ROTATE_MS: number = 20000;
const COVER_ROTATE_DEGREE: number = 360;
/** discSize 未指定（0）时的钳制哨兵：远大于任何真实列宽，等效不钳制 */
const DISC_CAP_UNLIMITED: number = 100000;

@Component
export struct CoverDiscComponent {
  @StorageLink(STORE_CURRENT_TRACK) @Watch('onTrackChanged') currentTrack: Track | null = null;
  @StorageLink(STORE_IS_PLAYING) @Watch('onPlayingChanged') isPlay: boolean = false;

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
  /** 光晕呼吸状态（本组件独占，不与其他动画共用） */
  @State haloScale: number = 1;
  @State haloOpacity: number = 0.7;

  /** 唱片旋转 animator（aboutToAppear 创建，销毁时 finish） */
  private coverAnim: AnimatorResult | null = null;
  /** 呼吸链代际与定时器句柄 */
  private haloGen: number = 0;
  private haloTimer: number = -1;

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
      if (this.isPlay) {
        this.coverAnim.play();
      }
    } catch (e) {
      // animator 创建失败只影响旋转，不影响光晕与其他内容
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`[CoverDisc] createAnimator failed: ${msg}`);
    }
    if (this.isPlay) {
      this.startHalo();
    }
  }

  aboutToDisappear(): void {
    if (this.coverAnim !== null) {
      this.coverAnim.finish();
      this.coverAnim = null;
    }
    this.stopHalo();
  }

  /** 播放态变化：旋转续转/冻结；光晕续上呼吸链或定格 */
  onPlayingChanged(_propName: string): void {
    const anim: AnimatorResult | null = this.coverAnim;
    if (anim !== null) {
      if (this.isPlay) {
        anim.play();
      } else {
        anim.pause();
      }
    }
    if (this.isPlay) {
      this.startHalo();
    } else {
      this.stopHalo();
    }
  }

  /** 宿主实测预算回填（@Prop 同步）——暂留诊断日志，验证通过后可删 */
  onDiscSizeChanged(_propName: string): void {
    console.info(`[CoverDisc] discSize synced: ${this.discSize}`);
  }

  /** 切歌 → 旋转归零（等价 Stopped），再按播放态决定是否重新起转 */
  onTrackChanged(_propName: string): void {
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
    if (this.isPlay) {
      anim.play();
    }
  }

  private startHalo(): void {
    this.stopHalo();
    const gen: number = ++this.haloGen;
    this.haloStep(gen);
  }

  private haloStep(gen: number): void {
    if (!this.isPlay || gen !== this.haloGen) {
      return;
    }
    const duration: number = 1800 + Math.floor(Math.random() * 1600);
    this.getUIContext().animateTo({ duration: duration, curve: Curve.EaseInOut }, (): void => {
      this.haloScale = 1 + Math.random() * 0.07;
      this.haloOpacity = 0.5 + Math.random() * 0.4;
    });
    this.haloTimer = setTimeout((): void => {
      this.haloTimer = -1;
      this.haloStep(gen);
    }, duration);
  }

  /** 暂停 / 销毁：停调度即可，光晕值留在当前位置（定格） */
  private stopHalo(): void {
    this.haloGen++;
    if (this.haloTimer !== -1) {
      clearTimeout(this.haloTimer);
      this.haloTimer = -1;
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
      // 光晕层：与封面同尺寸，靠 scale 呼吸放大；scale 不参与布局，Stack 尺寸稳定
      Column()
        .width('100%')
        .aspectRatio(1)
        .borderRadius('50%')
        .backgroundColor('rgba(255, 255, 255, 0.05)')
        .shadow({ radius: 36, color: 'rgba(255, 255, 255, 0.30)', offsetX: 0, offsetY: 0 })
        .opacity(this.haloOpacity)
        .scale({ x: this.haloScale, y: this.haloScale })
        .hitTestBehavior(HitTestMode.None)

      if (this.coverUrl().length > 0) {
        Image(this.coverUrl())
          .width('100%')
          .aspectRatio(1)
          .borderRadius('50%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .rotate({ z: 1, angle: this.rotateAngle })
          .shadow({ radius: 28, color: 'rgba(0, 0, 0, 0.45)', offsetX: 0, offsetY: 10 })
          .geometryTransition(GEOMETRY_ID_PLAYER_DISC)
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
    // aspectRatio(1) + constraintSize(maxWidth) 组合：宽度先按 100% 解析、再被
    // 高度预算钳制，高度随钳后宽度同步收缩 —— 圆盘任何情况下都是正方形，
    // 不会出现 maxWidth 钳宽后变椭圆的问题。
    .width('100%')
    .aspectRatio(1)
    .constraintSize({ maxWidth: this.discCap() })
  }
}
