/**
 * 播放页圆形封面（独立子组件，SM / LG 布局共用）。
 *
 * 封面：圆形裁切（50%）+ 深色柔和投影；与 miniBar 唱片同 id 的
 * geometryTransition 一镜到底（圆 ↔ 圆，形态完全一致）。
 *
 * 封面不旋转（用户指定）：与 PlayBar 迷你唱片一并静止，
 * 无逐帧 @State 回写开销。
 *
 * 封面风格（AppSettings.playerCoverStyle /
 * STORE_PLAYER_COVER_STYLE 镜像，设置页循环切换即时生效）：
 *   disc 唱片（默认，现状：圆形）/ square 方卡极简（方形圆角不旋转）。
 * build() 按风格分流 @Builder 形态（挂载守卫/兜底/切歌复位共用）；
 * 两风格封面均静止。
 * GT 全风格恒用 GEOMETRY_ID_PLAYER_DISC：迷你唱片(圆) ↔ 方卡(圆角)
 * 由系统插值 borderRadius 形变飞行；迷你栏小唱片恒圆形不改（底部栏身份标识）。
 */

import { Track } from '../../model/MusicModels';
import {
  PLAYER_COVER_STYLE_DISC,
  PLAYER_COVER_STYLE_SQUARE
} from '../../model/MusicModels';
import { toThumbUrl } from '../../utils/TextUtil';
import {
  GEOMETRY_ID_PLAYER_DISC,
  STORE_CURRENT_TRACK,
  STORE_PLAYER_OPEN,
  STORE_PLAYER_COVER_STYLE,
  STORE_PLAYER_GT_OFF,
  STORE_PLAYER_SLIDE_OUT,
  STORE_PLAYER_SLIDE_IN
} from '../../common/Constants';

/** discSize 未指定（0）时的钳制哨兵：远大于任何真实列宽，等效不钳制 */
const DISC_CAP_UNLIMITED: number = 100000;

@Component
export struct CoverDiscComponent {
  @StorageLink(STORE_CURRENT_TRACK) @Watch('onTrackChanged') currentTrack: Track | null = null;
  /**
   * 播放页展开态：大唱片内容**只在展开态渲染**。
   * 打开主动画（PlayerInfoComponent.playEnterTransition 的单个 animateTo）里
   * STORE_PLAYER_OPEN 翻 true → 本组件内容 if 出现，与 PlayBar 迷你唱片 if 消失
   **同帧配对* → geometryTransition 页内飞行（圆→圆，独立于容器延展）。
   * 收起（Index.closePlayer 的 animateTo 写 false）时逆向回飞。未展开时 Stack
   * 空挂（尺寸恒定，布局零跳动）。
   */
  @StorageProp(STORE_PLAYER_OPEN) playerOpen: boolean = false;

  /**
   * geometryTransition 摘除开关（Index.slideOutClose 置位）：
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
   * 上滑展开进行中：封面挂载守卫第三项 ——
   * 上滑展开时 playerOpen 在 slideInTransition 闭包内才翻 true，靠本标志封面
   * 在挂载首帧（屏下隐形位）即渲染、随整页上滑浮现；GT 已摘除（GT_OFF 预置），
   * PlayBar 迷你唱片侧同步保持可见（slideIn 守卫），无配对。
   */
  @StorageProp(STORE_PLAYER_SLIDE_IN) slideIn: boolean = false;

  /**
   * 圆盘边长上限（vp），由宿主按「内容列高 − 标题块 − 控制区」实测预算后传入；
   * 0 = 不钳制，纯宽度驱动（仅瘦长屏成立）。
   * 宽折叠（展开 1292×914vp / 折起 632×924vp）列宽接近列高，宽度驱动的圆盘
   * 会把进度条与三键控制整块挤出屏幕底部 —— 必须按高度预算钳。
   * 必须 @Prop：宿主在 onAreaChange 实测后才回填预算，普通成员变量只在
   * 创建时赋值一次、后续父组件更新不同步也不触发本组件重渲染。
   */
  @Prop @Watch('onDiscSizeChanged') discSize: number = 0;

  /** 封面风格（两档：唱片/方卡；EntryAbility 启动首发、设置页切换重发） */
  @StorageProp(STORE_PLAYER_COVER_STYLE) coverStyle: string = PLAYER_COVER_STYLE_DISC;

  /** 封面加载失败标记：切歌复位；失败时回落到下方 ♪ 兜底块，不留白 */
  @State coverFailed: boolean = false;

  /** 宿主实测预算回填（@Prop 同步）——暂留诊断日志，验证通过后可删 */
  onDiscSizeChanged(_propName: string): void {
    console.info(`[CoverDisc] discSize synced: ${this.discSize}`);
  }

  /** 切歌 → 复位封面加载失败标记（新曲目新封面，失败回落 ♪ 兜底块） */
  onTrackChanged(_propName: string): void {
    this.coverFailed = false;
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

  /** 唱片（默认档）：圆形封面（静止）+ 深色柔和投影 */
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
        .shadow({ radius: 28, color: 'rgba(0, 0, 0, 0.45)', offsetX: 0, offsetY: 10 })
        // GT 门控：gtOff=true 时 id 换空串（无转场），
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
}

