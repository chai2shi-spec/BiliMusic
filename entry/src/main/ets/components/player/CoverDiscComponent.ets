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
 * 性能（2026-10-23 转动卡顿修复）：rotate 虽是合成器属性（不触发重排重绘），
 * 但 onFrame → @State → build() 的逐帧重执行是 JS 层真实开销（120Hz 尤甚）。
 * 两道削减：① playerOpen=false（内容未渲染）时 animator 一律 pause，杜绝
 * overlay 预热期空转；② onFrame 隔帧回写（≈60fps），重建开销减半。
 * animator 在 aboutToDisappear 统一清理。
 *
 * 封面风格（2026-10-24，AppSettings.playerCoverStyle /
 * STORE_PLAYER_COVER_STYLE 镜像，设置页循环切换即时生效）：
 *   disc 唱片（默认，现状：圆形+旋转）/ square 方卡极简（方形圆角不旋转）/
 *   immersive 全屏沉浸（封面满屏宽顶状态栏，底部渐变模糊 + 主色溶解衔接
 *   下方主色渐变 —— 2026-10-24 改版，旧版封面与背景硬切；同日过渡动画改版：
 *   特效层（模糊+溶解）走 opacity 过渡 —— 展开随飞行渐显、收起先柔退再回飞，
 *   不再瞬间出现/消失，详见 ImmersiveCover）。
 * build() 按风格分流 @Builder 形态（挂载守卫/兜底/切歌复位共用）；
 * 旋转仅 disc 启用 —— square/immersive 静止，
 * syncDiscAnim 门控杜绝 120Hz 空转重建（同 2026-10-23 卡顿修复口径）。
 * GT 全风格恒用 GEOMETRY_ID_PLAYER_DISC：迷你唱片(圆) ↔ 方卡(圆角)
 * 由系统插值 borderRadius 形变飞行；迷你栏小唱片恒圆形不改（底部栏身份标识）。
 */

import { AnimatorOptions, AnimatorResult } from '@kit.ArkUI';
import { Track } from '../../model/MusicModels';
import {
  PLAYER_COVER_STYLE_DISC,
  PLAYER_COVER_STYLE_SQUARE,
  PLAYER_COVER_STYLE_IMMERSIVE
} from '../../model/MusicModels';
import { toThumbUrl } from '../../utils/TextUtil';
import { PLAYER_MAIN_CURVE, IMMERSIVE_FX_EXIT_MS } from '../../common/constants/InteractionConstants';
import {
  GEOMETRY_ID_PLAYER_DISC,
  PLAYER_TRANSITION_MS,
  STORE_CURRENT_TRACK,
  STORE_IS_PLAYING,
  STORE_PLAYER_OPEN,
  STORE_PLAYER_CONTENT_EXIT,
  STORE_PLAYER_COVER_STYLE,
  STORE_PLAYER_GT_OFF,
  STORE_PLAYER_IMAGE_COLOR,
  STORE_PLAYER_SLIDE_OUT,
  STORE_PLAYER_SLIDE_IN,
  STORE_APP_FOREGROUND
} from '../../common/Constants';

/** 大封面转速：20s 一圈（小圆盘 PlayBar 是 4s/圈，大封面放缓更克制） */
const COVER_ROTATE_MS: number = 20000;
const COVER_ROTATE_DEGREE: number = 360;
/** onFrame 回写节流（ms）：120Hz 屏隔帧回写（≈60fps），逐帧重建开销减半 */
const FRAME_WRITE_MIN_MS: number = 16;
/** discSize 未指定（0）时的钳制哨兵：远大于任何真实列宽，等效不钳制 */
const DISC_CAP_UNLIMITED: number = 100000;
/** 全屏档封面底部渐变模糊最大半径（vp，linearGradientBlur，底部全模糊） */
const IMMERSIVE_BLUR_RADIUS: number = 40;
/** 全屏档封面渐变模糊 / 主色溶解起始位置（封面高度占比）：上方保持锐利 */
const IMMERSIVE_FADE_START: number = 0.72;
/** 渐变模糊空间分布（FractionStop[模糊程度 0-1, 位置 0-1]，方向 Bottom）：
 *  0→72% 锐利 → 底边全模糊，渐变带随封面尺寸等比缩放 */
const IMMERSIVE_BLUR_STOPS: FractionStop[] = [[0, 0], [0, IMMERSIVE_FADE_START], [1, 1]];

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
   * @Watch（2026-10-23 卡顿修复）：展开才起转（内容渲染期），收起即 pause ——
   * 内容不渲染时转 animator 只会让本组件以 120Hz 空转重建（overlay 预热期同理）。
   */
  @StorageProp(STORE_PLAYER_OPEN) @Watch('onPlayerOpenChanged') playerOpen: boolean = false;

  /**
   * geometryTransition 摘除开关（2026-10-24 下滑收起，Index.slideOutClose 置位）：
   * true 时 id 换空串（无转场）—— 下滑路径不做配对飞行，防迷你唱片反向配对
   * （封面斜飞回栏）。
   */
  @StorageProp(STORE_PLAYER_GT_OFF) gtOff: boolean = false;
  /**
   * 下滑收起进行中（Index.slideOutClose 置位，onFinish 复位）：内容挂载守卫放宽
   * 为 playerOpen || slideOut —— 下滑途中 playerOpen 已翻 false，靠本标志封面
   * 不瞬间消失、随整页滑走渐隐；GT 已摘除，迷你唱片侧 if 翻转不触发配对。
   */
  @StorageProp(STORE_PLAYER_SLIDE_OUT) slideOut: boolean = false;
  /**
   * 上滑展开进行中（2026-10-24 展开动画三风格区分）：封面挂载守卫第三项 ——
   * 上滑展开时 playerOpen 在 slideInTransition 闭包内才翻 true，靠本标志封面
   * 在挂载首帧（屏下隐形位）即渲染、随整页上滑浮现；GT 已摘除（GT_OFF 预置），
   * PlayBar 迷你唱片侧同步保持可见（slideIn 守卫），无配对。
   */
  @StorageProp(STORE_PLAYER_SLIDE_IN) slideIn: boolean = false;

  /**
   * 圆盘边长上限（vp），由宿主按「内容列高 − 标题块 − 控制区」实测预算后传入；
   * 0 = 不钳制，纯宽度驱动（旧行为，仅瘦长屏成立）。
   * 宽折叠（展开 1292×914vp / 折起 632×924vp）列宽接近列高，宽度驱动的圆盘
   * 会把进度条与三键控制整块挤出屏幕底部 —— 必须按高度预算钳。
   * 必须 @Prop：宿主在 onAreaChange 实测后才回填预算，普通成员变量只在
   * 创建时赋值一次、后续父组件更新不同步也不触发本组件重渲染。
   */
  @Prop @Watch('onDiscSizeChanged') discSize: number = 0;

  /** 封面风格（三档：唱片/方卡/全屏；EntryAbility 启动首发、设置页切换重发） */
  @StorageProp(STORE_PLAYER_COVER_STYLE) coverStyle: string = PLAYER_COVER_STYLE_DISC;

  /**
   * 沉浸背景主色（rgba 字符串，2026-10-24 全屏档渐变模糊改版）：PlayerInfoComponent
   * 取色后经 STORE_PLAYER_IMAGE_COLOR 发布，本组件只读订阅 —— 全屏档封面底部
   * 溶解层（透明→主色）的目标色，与 SurfaceLayers 沉浸渐变同源同色。
   */
  @StorageProp(STORE_PLAYER_IMAGE_COLOR) imageColor: string = 'rgba(0, 0, 2, 1)';

  /**
   * 全屏档特效层（底部渐变模糊+主色溶解）透明度（2026-10-24 过渡动画改版）：
   * 展开随 GT 飞行 0→1 渐显（onAppear 起 700ms PLAYER_MAIN_CURVE，与飞行同锁）；
   * 收起随 CONTENT_EXIT 柔退 1→0（IMMERSIVE_FX_EXIT_MS=300ms EaseInOut）。
   * 特效层在 GT 节点内部，opacity 过渡不依赖 linearGradientBlur 半径可动画性。
   */
  @State fxOpacity: number = 0;

  /**
   * 收起柔退信号（seq 递增，写在 Index.closePlayer 主动画闭包**外**，
   * 仅 morph 路径递增）：全屏档特效层 300ms EaseInOut 渐隐（时长独立于
   * 内容层柔退，见 IMMERSIVE_FX_EXIT_MS）。
   */
  @StorageProp(STORE_PLAYER_CONTENT_EXIT) @Watch('onContentExit') contentExitSeq: number = 0;

  /** 唱片当前旋转角度（°）：animator 每帧回写，暂停时冻结在当前值 */
  @State rotateAngle: number = 0;
  /** 封面加载失败标记：切歌复位；失败时回落到下方 ♪ 兜底块，不留白 */
  @State coverFailed: boolean = false;
  /** 唱片旋转 animator（aboutToAppear 创建，销毁时 finish） */
  private coverAnim: AnimatorResult | null = null;
  /** onFrame 节流基准（ms）：与 FRAME_WRITE_MIN_MS 配合做隔帧回写 */
  private lastFrameMs: number = 0;

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
        // 隔帧回写（≈60fps）：20s/圈每步 0.06°，视觉零差，逐帧重建开销减半
        const now: number = Date.now();
        if (now - this.lastFrameMs < FRAME_WRITE_MIN_MS) {
          return;
        }
        this.lastFrameMs = now;
        this.rotateAngle = value;
      };
      // 挂载时可能已在播放中（@Watch 不会触发，需手动起转）
      this.syncDiscAnim();
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

  /** 播放页展开 → 内容渲染期，起转（@Watch playerOpen 统一走这里） */
  onPlayerOpenChanged(_propName: string): void {
    this.syncDiscAnim();
    // 幂等复位（morph 收起柔退已归零；slide 收起 slideOut=true 特效随整页
    // 滑走，不归零 —— 中途归零会在滑出途中瞬隐）
    if (!this.playerOpen && !this.slideOut
      && this.coverStyle === PLAYER_COVER_STYLE_IMMERSIVE) {
      this.fxOpacity = 0;
    }
  }

  /**
   * 收起柔退：全屏档特效层（模糊+溶解）300ms EaseInOut 渐隐（IMMERSIVE_FX_EXIT_MS；
   * 初版 150ms EaseIn 用户反馈「消失太快」，2026-10-24 调优定稿 300ms ——
   * EaseInOut 全程匀速可见，静态页面上淡出更从容，不用末段加速骤消的 EaseIn）。
   * Index.closePlayer 的预熔窗口等满同长后才翻 playerOpen 触发回飞 ——
   * 保证渐隐渲染在封面卸载之前可见。
   */
  private onContentExit(): void {
    if (this.coverStyle !== PLAYER_COVER_STYLE_IMMERSIVE || this.fxOpacity <= 0) {
      return;
    }
    this.getUIContext().animateTo(
      { duration: IMMERSIVE_FX_EXIT_MS, curve: Curve.EaseInOut },
      (): void => { this.fxOpacity = 0; });
  }

  /**
   * 旋转统一入口：前台、在播、播放页展开（内容渲染期）且当前风格带旋转件
   * （disc 唱片）才续转，否则冻结在当前角度
   * （绝不复位到 0）—— square/immersive 无旋转件，转 animator 只是 120Hz
   * 空转重建（playerOpen=false 内容不渲染时同理）。
   */
  private syncDiscAnim(): void {
    const anim: AnimatorResult | null = this.coverAnim;
    if (anim === null) {
      return;
    }
    const spins: boolean = this.coverStyle === PLAYER_COVER_STYLE_DISC;
    const spin: boolean = this.isPlay && this.appForeground && this.playerOpen && spins;
    // 低频门控日志（仅状态翻转时打，绝不逐帧）
    console.info(`[CoverDisc] spin=${spin} open=${this.playerOpen} play=${this.isPlay} fg=${this.appForeground}`);
    if (spin) {
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
    // 后台切歌不起转：回前台时 onForegroundChanged 会按播放态补起转；
    // 播放页未展开（内容未渲染）同样不起转，onPlayerOpenChanged 展开时补
    this.syncDiscAnim();
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
      // 下滑收起（slideOut）时内容保持挂载随整页滑走；上滑展开（slideIn）时
      // 内容在屏下隐形位即渲染、随整页上滑浮现（两条路径 GT 均已摘除，无配对）。
      if (this.playerOpen || this.slideOut || this.slideIn) {
        if (this.coverStyle === PLAYER_COVER_STYLE_SQUARE) {
          this.SquareCover()
        } else if (this.coverStyle === PLAYER_COVER_STYLE_IMMERSIVE) {
          this.ImmersiveCover()
        } else {
          this.DiscCover()
        }
      }
    }
    // aspectRatio(1) + constraintSize(maxWidth) 组合：宽度先按 100% 解析、再被
    // 高度预算钳制，高度随钳后宽度同步收缩 —— 外层占位任何风格下都是正方形，
    // 不会出现 maxWidth 钳宽后变形的问题（方卡在占位内自定形态）。
    .width('100%')
    .aspectRatio(1)
    .constraintSize({ maxWidth: this.discCap() })
  }

  /** 唱片（默认档，现状）：圆形封面 + 20s/圈旋转 + 深色柔和投影 */
  @Builder
  DiscCover(): void {
    if (this.coverUrl().length > 0 && !this.coverFailed) {
      // 720px 缩略图：播放页圆盘按 3x 屏密度最多 ~1000px，720 已足够锐利，
      // 避免直接拉原图（B 站原图常见 2000px+，解码与流量都翻倍）
      Image(toThumbUrl(this.coverUrl(), 720))
        .width('100%')
        .aspectRatio(1)
        .borderRadius('50%')
        .objectFit(ImageFit.Cover)
        .draggable(false)
        .rotate({ z: 1, angle: this.rotateAngle })
        .shadow({ radius: 28, color: 'rgba(0, 0, 0, 0.45)', offsetX: 0, offsetY: 10 })
        // GT 门控（2026-10-24 下滑收起）：gtOff=true 时 id 换空串（无转场），
        // 下滑路径不配对飞行；柔退路径 gtOff 恒 false，配对行为不变。
        .geometryTransition(this.gtOff ? '' : GEOMETRY_ID_PLAYER_DISC)
        // 加载失败回落到 ♪ 兜底块，不留白
        .onError((err: ImageError): void => {
          this.coverFailed = true;
        })
    } else {
      Column() {
        SymbolGlyph($r('sys.symbol.waveform'))
          .fontSize(64)
          .fontColor([Color.White])
          .opacity(0.6)
      }
      .width('100%')
      .aspectRatio(1)
      .borderRadius('50%')
      .backgroundColor('rgba(255, 255, 255, 0.12)')
      .justifyContent(FlexAlign.Center)
    }
  }

  /** 方卡极简：方形圆角大封面（radius 12），不旋转；柔和投影。圆→方角由 GT 插值形变 */
  @Builder
  SquareCover(): void {
    if (this.coverUrl().length > 0 && !this.coverFailed) {
      Image(toThumbUrl(this.coverUrl(), 720))
        .width('100%')
        .aspectRatio(1)
        .borderRadius(12)
        .objectFit(ImageFit.Cover)
        .draggable(false)
        .shadow({ radius: 20, color: 'rgba(0, 0, 0, 0.3)', offsetX: 0, offsetY: 8 })
        .geometryTransition(this.gtOff ? '' : GEOMETRY_ID_PLAYER_DISC)
        .onError((err: ImageError): void => {
          this.coverFailed = true;
        })
    } else {
      Column() {
        SymbolGlyph($r('sys.symbol.waveform'))
          .fontSize(64)
          .fontColor([Color.White])
          .opacity(0.6)
      }
      .width('100%')
      .aspectRatio(1)
      .borderRadius(12)
      .backgroundColor('rgba(255, 255, 255, 0.12)')
      .justifyContent(FlexAlign.Center)
    }
  }

  /**
   * 全屏沉浸：封面无缝铺满上方（无圆角无投影），不旋转；SM 版式由 PlayerInfoComponent
   * 调用点（-safeTop 负边距 + 零左右内边距）实现满屏宽、上沿顶到状态栏。
   *
   * 底部渐变模糊 + 主色溶解（2026-10-24 改版，替代旧「封面与背景硬切」直接过渡）：
   *   · 锐利底图（GT 飞行载体）之上叠特效层：同源副本图挂 linearGradientBlur
   *     （0→72% 锐利 → 底边全模糊 40vp）+ 主色溶解层（透明→imageColor），底边与
   *     SurfaceLayers 沉浸渐变同色无缝衔接 —— 观感为封面「融化」进背景；
   *   · 特效层在 GT 节点内部随飞行节点一起飞，整层 opacity 由 fxOpacity 过渡
   *     （2026-10-24 过渡动画改版，规避 linearGradientBlur 半径可动画性未证实）：
   *     展开随飞行 700ms 渐显、收起 150ms 柔退渐隐（Index 预熔窗口保证可见）。
   * 特效层 hitTestBehavior None 不吞手势；GT 挂在根 Stack（按 id 配对，容器
   * 节点与节点类型无关，飞行几何边界不变）；兜底分支不配对 GT（与旧行为一致）。
   */
  @Builder
  ImmersiveCover(): void {
    Stack() {
      if (this.coverUrl().length > 0 && !this.coverFailed) {
        // 锐利底图（GT 飞行载体），不挂模糊
        Image(toThumbUrl(this.coverUrl(), 720))
          .width('100%')
          .aspectRatio(1)
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .onError((err: ImageError): void => {
            this.coverFailed = true;
          })
        // ── 特效层（模糊+溶解，opacity 过渡，随 GT Stack 一起飞）──
        Stack() {
          Image(toThumbUrl(this.coverUrl(), 720))
            .width('100%')
            .aspectRatio(1)
            .objectFit(ImageFit.Cover)
            .draggable(false)
            // 底部渐进模糊（本 SDK 唯一官方渐变模糊通路，GradientBlurDemoPage 同款）
            .linearGradientBlur(IMMERSIVE_BLUR_RADIUS, {
              fractionStops: IMMERSIVE_BLUR_STOPS,
              direction: GradientDirection.Bottom
            })
            .onError((err: ImageError): void => {
              this.coverFailed = true;
            })
          // 主色溶解层：透明 → imageColor（格式由 PlayerInfoComponent 取色管线保证）
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 180,
              colors: [
                [this.imageColorTransparent(), IMMERSIVE_FADE_START],
                [this.imageColor, 1.0]
              ]
            })
        }
        .opacity(this.fxOpacity)
        .hitTestBehavior(HitTestMode.None)
        // 首挂载即淡入：与 GT 飞行同帧起跑（morph 展开锁飞行 700ms；风格切换
        // 在播放页内挂载时同样平滑渐显）；onAppear 在渲染帧外回调，避免在
        // Index 主动画闭包内嵌套 animateTo
        .onAppear((): void => {
          this.getUIContext().animateTo(
            { duration: PLAYER_TRANSITION_MS, curve: PLAYER_MAIN_CURVE },
            (): void => { this.fxOpacity = 1; });
        })
      } else {
        Column() {
          SymbolGlyph($r('sys.symbol.waveform'))
            .fontSize(64)
            .fontColor([Color.White])
            .opacity(0.6)
        }
        .width('100%')
        .aspectRatio(1)
        .backgroundColor('rgba(255, 255, 255, 0.12)')
        .justifyContent(FlexAlign.Center)
      }
    }
    .geometryTransition(this.gtOff || this.coverUrl().length === 0 || this.coverFailed
      ? '' : GEOMETRY_ID_PLAYER_DISC)
  }

  /**
   * imageColor 的全透明变体（溶解层渐变起点）：格式由取色管线钉死为
   * 'rgba(R, G, B, 1)'（dealColor），仅替换不透明度；意外格式回落全透明黑。
   */
  private imageColorTransparent(): string {
    const transparent: string = this.imageColor.replace(', 1)', ', 0)');
    return transparent === this.imageColor ? 'rgba(0, 0, 0, 0)' : transparent;
  }
}

