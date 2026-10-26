/**
 * 播放页主体。
 *
 * 沉浸式背景：网络封面下载为 PixelMap → effectKit 取主色调暗
 * （dealColor）做页面底色 + 模糊封面图打底；主色明度写入
 * STORE_PLAYER_BG_DARK，供顶栏投播按钮与状态栏内容色切换。
 *
 * 布局五分支：
 *   · 紧凑横屏（直板机：isLandscape 且窗口高 < LANDSCAPE_COMPACT_MAX_WINDOW_H_VP，
 *     ~844×391vp；折叠屏展开横屏：isFoldFull && isLandscape，Pura X 展开横屏
 *     ~721vp / Mate X 类）→ 左列 45%（封面 + 歌名 +
 *     歌手 + 三键，居中）+ 右列纯歌词（封面预算挂弹性壳实测）；
 *   · 折叠屏展开竖屏（isFoldFull 且非 isWideFoldFull，STORE_FOLD_EXPANDED）→
 *     封面 / 歌词左右分栏（md/lg 宽度均 8 列 4+4）—— 只留常规折叠展开竖屏
 *     （md，Mate X 类），展开横屏已上移紧凑横屏分支；
 *   · 阔折叠外屏（deviceFoldable && !isFoldFull && 竖屏 && md，如 Pura X 折起
 *     632×924vp）→ 封面右上出血裁切 + 左下信息/三键 + 滑动歌词页
 *     （横屏排除：外屏横屏高度充足，走下方栅格分栏）；
 *   · MD/LG 断点（真平板 / 大窗口 / 阔折叠外屏横屏；!isFoldFull 守卫）→
 *     栅格分栏（封面 + 标题块 + 控制区 | 歌词）；
 *   · SM 断点 / 阔折叠展开竖屏（isWideFoldFull：isFoldFull && lg && 竖屏，
 *     Pura X 展开 ≥840vp；用户拍板去分栏、全宽铺满、仅阔折叠）→
 *     Swiper 双页（封面页 | 歌词页）+ 顶栏叠加，版式与直板机一致。
 *
 * 安全区：STORE_SAFE_TOP / STORE_SAFE_BOTTOM（全屏布局方案，见 Constants.ts 注释）。
 *
 * 收起：
 *   · 背景面离场末端渐隐 —— 非对称 transition 离场侧 opacity(0) 配
 *     PLAYER_BG_EXIT_CURVE（前 ~65% 近似恒持、临落位快速衰减；
 *     用户拍板，不走「背景直到落位才消失」）；
 *   · 下滑收起（slide 风格 / 手势过阈值）时背景面靠 STORE_PLAYER_SLIDE_OUT
 *     守卫保持挂载（随整页滑走，不参与配对），geometryTransition 由
 *     STORE_PLAYER_GT_OFF 摘除（下滑路径不做配对飞行，防迷你唱片斜飞）；
 *   · 自持内容（LG/MD 标题块、阔折叠信息块）随 STORE_PLAYER_CONTENT_EXIT
 *     柔退淡出（contentFade），指示点走 contentHidden 结构性单帧消失。
 */

import { effectKit } from '@kit.ArkGraphics2D';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { taskpool } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Track } from '../../model/MusicModels';
import {
  PLAYER_COVER_STYLE_DISC,
  PLAYER_COVER_STYLE_SQUARE
} from '../../model/MusicModels';
import { PlayerConstants } from '../../common/constants/PlayerConstants';
import { ColorConversion } from '../../common/utils/ColorConversion';
import { CoverPaletteResult, buildRgba, extractCoverPaletteTask } from '../../common/utils/CoverPalette';
import { StyleConstants } from '../../common/constants/StyleConstants';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { LyricsComponent } from './LyricsComponent';
import { TopAreaComponent } from './TopAreaComponent';
import { MusicInfoComponent } from './MusicInfoComponent';
import { ControlAreaComponent } from './ControlAreaComponent';
import { CoverDiscComponent } from './CoverDiscComponent';
import {
  STORE_CURRENT_TRACK,
  STORE_SAFE_TOP,
  STORE_SAFE_BOTTOM,
  STORE_PLAYER_BG_DARK,
  STORE_PLAYER_IMAGE_COLOR,
  STORE_FOLD_EXPANDED,
  STORE_LOGIN_REV,
  BILI_REFERER,
  PLAYER_TRANSITION_MS,
  STORE_PLAYER_OPEN,
  STORE_PLAYER_CONTENT_EXIT,
  STORE_PLAYER_TRANSITIONING,
  STORE_PLAYER_GT_OFF,
  STORE_PLAYER_SLIDE_OUT,
  STORE_PLAYER_SLIDE_IN,
  STORE_PLAYER_SLIDE_OFFSET,
  STORE_PLAYER_SLIDE_ALPHA,
  STORE_DEVICE_FOLDABLE,
  STORE_WINDOW_HEIGHT_VP,
  STORE_SAFE_LEFT,
  STORE_SAFE_RIGHT,
  STORE_PLAYER_COVER_STYLE,
  AUDIO_Q_DOLBY,
  AUDIO_Q_HIRES,
  GEOMETRY_ID_PLAYER_SURFACE,
  PLAYER_SURFACE_RADIUS_END_VP,
  formatTrackQuality
} from '../../common/Constants';
import { HttpUtil } from '../../utils/HttpUtil';
import { getLoginUser, LoginUser } from '../../service/LoginStore';
import { PLAYER_MAIN_CURVE, PLAYER_BG_EXIT_CURVE, LAYER_EXIT_DURATION_MS, LAYER_EXIT_DELAY_INFO, SLIDE_OPEN_MS, PLAYER_SLIDE_IN_CURVE } from '../../common/constants/InteractionConstants';

/** blur 偶发失败的单次重试延迟（ms） */
const BLUR_RETRY_DELAY_MS: number = 300;
/** 取色主色 600ms 颜色过渡时长（切歌时 animateTo 平滑插值） */
const PALETTE_COLOR_ANIM_MS: number = 600;
/** 取色降采样源边长（px）：48×48 RGBA ≈ 9KB，TaskPool 直方图聚类的输入规模 */
const PALETTE_SOURCE_PX: number = 48;

/** 封面双尺寸解码结果（loadCoverPair 一次下载一次建源、双档输出） */
interface CoverPixelPair {
  full: image.PixelMap;
  small: image.PixelMap;
}
/** 阔折叠外屏（Pura X 折起 632×924vp → md 断点）封面圆盘宽度预算比例 */
const COMPACT_DISC_W_RATIO: number = 0.63;
/** 阔折叠外屏圆盘高度预算比例（矮屏兜底，防宽度驱动的圆盘纵向溢出） */
const COMPACT_DISC_H_RATIO: number = 0.62;
/** 阔折叠外屏封面右出血比例（占圆盘边长）：约 1/4 出屏，可见约 3/4 */
const COMPACT_DISC_BLEED_RATIO: number = 0.25;
/** 阔折叠外屏封面出血位距内容域顶部的间距（vp） */
const COMPACT_DISC_TOP_VP: number = 12;
/** 阔折叠外屏翻页时封面淡出/淡入时长（ms） */
const COMPACT_COVER_FADE_MS: number = 200;
// ⚠️ 这里**不要**定义整块内容层的延迟淡入常量（如 CONTENT_FADE_IN_DELAY_MS /
// CONTENT_FADE_IN_MS）：整块淡入会把封面（CoverDisc，geometryTransition 一镜到底）
// 一起压成透明 —— 转场头 60ms 封面完全不可见，观感变成「一块背景矩形从迷你栏长开、
// 内容随后浮现」，而不是「迷你栏那块玻璃整块变大、封面飞出来」。
// 「避免内容浮在没长开的背景之外」的职责由各层自带的分层入场承担
// （随背景面覆盖进度空间序淡入，与飞行尾部重叠）：
//   · 控制区 ControlAreaComponent    → LAYER_DELAY_CONTROL(400) + 250ms 淡入 + 10vp 上移（底部最先被盖住）
//   · 标题块 MusicInfoComponent      → LAYER_DELAY_INFO(470)   + 250ms 淡入 + 10vp 上移（中部）
//   · 顶栏   TopAreaComponent        → LAYER_DELAY_TOP(530)    + 250ms 淡入（顶部最后被盖住）
//   · 封面   CoverDiscComponent      → 刻意**不动**（形变由 geometryTransition 独占）
// 封面因此全程不透明：它以迷你栏唱片为起点飞行，本来就不会「浮在首页上」。

@Component
export struct PlayerInfoComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageLink(STORE_CURRENT_TRACK) @Watch('onTrackChanged') currentTrack: Track | null = null;
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /**
   * 沉浸背景主色（取自封面，取色失败保持默认深色）。@StorageLink 发布到
   * STORE_PLAYER_IMAGE_COLOR：背景面 Stack 底色与各处主色消费点同源。
   */
  @StorageLink(STORE_PLAYER_IMAGE_COLOR) imageColor: string = 'rgba(0, 0, 2, 1)';
  /**
   * 深辅色 RGB：muted 深色簇，与主色同色系恒更暗，驱动 SurfaceLayers 双色渐变
   * （disc 压深渐变着色 / square 对角渐变终点）。组件内部状态、无外部消费方，
   * 不进 AppStorage。
   */
  @State deepRgb: number[] = [0, 0, 1];
  /** 背景图：取色成功前显示原图，成功后换模糊图 */
  @State bgCover: PixelMap | string = '';
  /**
   * 折叠屏展开态：订阅全局唯一真源 service/FormFactorHolder 的
   * STORE_FOLD_EXPANDED（EntryAbility 常驻首发）—— 播放页是懒加载 overlay，
   * 本组件不私有注册 display 监听（不挂载就没有折叠态）。
   */
  @StorageProp(STORE_FOLD_EXPANDED) isFoldFull: boolean = false;
  /** 背景明暗（本组件取色写入 STORE_PLAYER_BG_DARK 后回读）：标题块码率文案压深/提亮用 */
  @StorageProp(STORE_PLAYER_BG_DARK) isBgDark: boolean = true;
  /** 封面风格（两档，设置页可切）：SurfaceLayers 背景分层据此分流，取色/模糊管线全风格共用不变 */
  @StorageProp(STORE_PLAYER_COVER_STYLE) coverStyle: string = PLAYER_COVER_STYLE_DISC;
  /** 登录态版本号（音质文案随登录/退出刷新，见 qualityText 的注释） */
  @StorageLink(STORE_LOGIN_REV) loginRev: number = 0;

  /**
   * 播放页展开态（打开主动画里写 true / Index.closePlayer 里写 false）：
   * 驱动背景面的 geometryTransition 配对 —— true 时本组件的全屏背景面出现、
   * PlayBar 迷你栏里的透明锚点消失，系统在「迷你栏真实视觉包围盒 ↔ 全屏」之间
   * 做几何插值（见 GEOMETRY_ID_PLAYER_SURFACE 注释）。
   */
  @StorageProp(STORE_PLAYER_OPEN) playerOpen: boolean = false;

  /**
   * 收起时内容层柔退信号（seq 递增，写在 Index.closePlayer 的主动画闭包**外**，
   * 仅柔退路径递增 —— 下滑收起内容随整页滑走，不触发）：本组件自持内容
   * （SM/阔折叠 Swiper 指示点、LG/MD 标题块、阔折叠信息块）与四个子内容层
   * （顶栏 / 标题 / 控制区 / 歌词）各自订阅同一信号自理（柔退淡出，
   * 各层按 LAYER_EXIT_DELAY_* 错峰）。
   */
  @StorageProp(STORE_PLAYER_CONTENT_EXIT) @Watch('onContentExit') contentExitSeq: number = 0;
  /**
   * 收起中标志（结构性开关）：指示点走本布尔单帧消失（Swiper indicator 接受
   * boolean，挂不了数值 opacity）；自持文字块改走 contentFade 柔退。
   * 重开时组件重挂载复位。
   */
  @State contentHidden: boolean = false;
  /** 自持内容柔退透明度（LG/MD 标题块、阔折叠信息块）：onContentExit 内 200ms EaseIn 淡出 */
  @State contentFade: number = 1;
  /**
   * geometryTransition 全窗摘除开关（Index.slideOutClose 置位）：
   * true 时背景面 / 封面 / 迷你唱片 / 透明锚点的 GT id 全部换空串 —— 下滑收起
   * 翻转 playerOpen 前必须先摘除（渲染一帧），否则被移除节点仍带旧 id 触发
   * 迷你唱片反向配对飞行（封面斜飞回栏）。
   */
  @StorageProp(STORE_PLAYER_GT_OFF) gtOff: boolean = false;
  /**
   * 下滑收起进行中（Index.slideOutClose 置位，onFinish 复位）：背景面挂载守卫从
   * 「playerOpen」放宽为「playerOpen || slideOut」—— 下滑途中 playerOpen 已翻
   * false，靠本标志背景面不析构、随整页滑走；GT 已摘除，无配对副作用。
   */
  @StorageProp(STORE_PLAYER_SLIDE_OUT) slideOut: boolean = false;
  /**
   * 上滑展开进行中（PlayBar.openPlayer 的 slide 分支在挂载前预置）：① 背景面/封面挂载守卫的第三项 —— playerOpen 在
   * slideInTransition 闭包内才翻 true，靠本标志背景面/封面在挂载首帧（屏下
   * 隐形位）即已渲染；② onAppear 分流依据 —— true 走上滑主动画、false 走
   * morph 打开。slideInTransition 的 onFinish 复位（连同 TRANSITIONING / GT_OFF）。
   */
  @StorageProp(STORE_PLAYER_SLIDE_IN) slideIn: boolean = false;

  /**
   * SM Swiper 当前页下标（受控）：收起开始
   *（onContentExit）时以 duration 0 瞬间回跳封面页（第 0 页）—— 右滑到歌词页
   * 后封面页被平移出屏但 CoverDisc 节点仍挂载（Swiper 缓存相邻页），geometryTransition
   * 配对按真实视觉包围盒取起点，不回跳则封面从屏幕左侧外斜飞入迷你栏。回跳后
   * 起点回到屏幕中央。手势滑动经 onChange 回写，翻页行为不变。
   */
  @State smIndex: number = 0;
  /** SM Swiper 页切换动画时长（ms）：默认 400（系统默认档），收起回跳时置 0 */
  @State smAnimDuration: number = 400;

  /** 柔退复位：自持内容淡出 + 指示点单帧隐藏 + SM Swiper 无动画回跳封面页（见 smIndex 注释） */
  private onContentExit(): void {
    this.contentHidden = true;
    // 收起开始信号在 closePlayer 主动画闭包**外**递增 → 回跳与收起飞行同帧提交；
    // 从封面页收起时 0→0 为 no-op；overlay 卸载即组件销毁，下次打开全新挂载回
    // 默认值（400ms / 第 0 页），无需复位逻辑。
    this.smAnimDuration = 0;
    this.smIndex = 0;
    // 自持内容柔退：LG/MD 标题块与阔折叠信息块
    // 200ms EaseIn 淡出，延迟与 MusicInfoComponent 同档（LAYER_EXIT_DELAY_INFO）
    // —— 跨组件错峰口径一致。SM Swiper 回跳**不**包进本动画（瞬跳保持不动画）。
    this.getUIContext().animateTo(
      {
        duration: LAYER_EXIT_DURATION_MS,
        curve: Curve.EaseIn,
        delay: LAYER_EXIT_DELAY_INFO
      },
      (): void => {
        this.contentFade = 0;
      }
    );
  }

  /**
   * LG 分栏左列圆盘边长上限（vp）：0 = 首帧未实测（宽度驱动，实测后收敛）。
   * 与 MusicInfoComponent 同一套「高度预算」思路，防止矮屏（横屏平板）上
   * 宽度驱动的圆盘把控制区挤出屏幕底部。
   */
  @State lgDiscSize: number = 0;
  /** LG 左列 / 控制区实测尺寸（onAreaChange 回写） */
  private lgColW: number = 0;
  private lgColH: number = 0;
  private lgCtrlH: number = 0;
  /** LG 左列标题块实测高（圆盘预算要一并减掉） */
  private lgTitleH: number = 0;

  /** Area 尺寸（Length）→ vp 数值（资源型按 0 兜底） */
  private toVp(v: Length): number {
    if (typeof v === 'number') {
      return v;
    }
    if (typeof v === 'string') {
      return parseFloat(v);
    }
    return 0;
  }

  /** 圆盘边长 = min(左列宽, 左列高 − 标题块 − 控制区)；预算为负退回宽度驱动 */
  private recomputeLgDisc(): void {
    if (this.lgColW <= 0 || this.lgColH <= 0 || this.lgCtrlH <= 0) {
      return;
    }
    const budget: number = this.lgColH - this.lgCtrlH - this.lgTitleH;
    this.lgDiscSize = budget > 0 ? Math.min(this.lgColW, budget) : this.lgColW;
  }

  /**
   * 阔折叠外屏判定：折叠屏设备 && 非展开态 &&
   * md 断点 —— 精准锁定阔折叠外屏（折起 632×924vp 落 md）。普通手机（sm）、
   * 平板（非折叠设备）、折叠展开（isFoldFull 分支优先）均不命中。
   */
  @StorageProp(STORE_DEVICE_FOLDABLE) deviceFoldable: boolean = false;

  /** 外屏内容域实测尺寸（onAreaChange 回写，驱动封面圆盘预算） */
  private compactAreaW: number = 0;
  private compactAreaH: number = 0;
  /** 外屏封面圆盘边长（vp）：0 = 首帧未实测（与 lgDiscSize 同一套实测回填思路） */
  @State compactDiscSize: number = 0;
  /** 外屏 Swiper 当前页下标（0 封面页 / 1 歌词页）：封面随翻页淡出/淡入 */
  @State compactPageIndex: number = 0;

  private isCompactFold(): boolean {
    // 横屏排除：外屏横屏（924×632vp）误入本竖屏
    // 出血版式会破版 —— 横屏高度充足，落下方 md/lg 栅格分栏。
    return this.deviceFoldable && !this.isFoldFull && !this.isLandscape
      && this.currentBreakpoint === BreakpointConstants.BREAKPOINT_MD;
  }

  /**
   * 阔折叠展开判定（用户拍板「去分栏、全宽铺满、仅阔折叠」）：折叠屏展开（isFoldFull）且宽度落 lg（≥840vp，
    * 阔折叠 Pura X 类展开落 lg，常规折叠
   * Mate X 类展开落 md 仍走分栏）且竖屏。命中时 build() 的 isFoldFull 分栏
   * 分支放行，穿透到 SM Swiper 双页分支（直板机版式）。横屏排除：直板机
   * Swiper 版式不处理横屏，展开横屏命中 isCompactLandscape（isFoldFull &&
   * isLandscape）。PlayerPage.dragDismissEnabled
   * 为同口径双份实现（morph_swipe 下拉手势扩展），改判定口径时两处同步。
   */
  private isWideFoldFull(): boolean {
    return this.isFoldFull && !this.isLandscape
      && this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG;
  }

  /** 外屏圆盘预算：min(内容域宽×0.63, 高×0.62) —— 宽度驱动为主，矮屏高度兜底 */
  private recomputeCompactDisc(): void {
    if (this.compactAreaW <= 0 || this.compactAreaH <= 0) {
      return;
    }
    this.compactDiscSize = Math.floor(Math.min(
      this.compactAreaW * COMPACT_DISC_W_RATIO,
      this.compactAreaH * COMPACT_DISC_H_RATIO));
  }

  /** 外屏封面右出血量（vp）：负 margin 参与布局，geometryTransition 飞行终点即出血位 */
  private compactBleed(): number {
    return this.compactDiscSize * COMPACT_DISC_BLEED_RATIO;
  }

  /**
   * 横竖屏：BreakpointSystem 常驻监听
   * （orientation: landscape 媒体查询，Index 注册）写入 IS_LANDSCAPE，
   * 本组件只读订阅。
   */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;
  /** 窗口内容区高度（vp）：EntryAbility 首发 + Index HdsTabs.onAreaChange 持续回写（旋转后新鲜） */
  @StorageProp(STORE_WINDOW_HEIGHT_VP) windowHeightVp: number = 0;
  /** 水平安全区（vp）：横屏下状态栏侧边条带避让；竖屏两值为 0，padding 不生效 */
  @StorageProp(STORE_SAFE_LEFT) safeLeft: number = 0;
  @StorageProp(STORE_SAFE_RIGHT) safeRight: number = 0;

  /**
   * 紧凑横屏判定：横屏且窗口高低于
   * LANDSCAPE_COMPACT_MAX_WINDOW_H_VP 才命中 —— 阔折叠外屏横屏 632vp /
   * 平板横屏 ≥600vp 均不命中，维持既有分支。
   * 折叠屏展开横屏（Pura X 展开横屏 ~721vp 高，用户拍板）复用本版式 ——
   * isFoldFull && isLandscape 直进，不卡高度阈值；常规折叠 Mate X 类展开
   * 横屏一并纳入（折叠展开横屏统一口径）。
   * 版式全实测驱动（封面弹性壳 onAreaChange + layoutWeight），大窗仅等比
   * 放大，结构零改动；平板恒非折叠（isFoldFull=false）不受影响。
   */
  private isCompactLandscape(): boolean {
    if (this.isFoldFull && this.isLandscape) {
      return true;
    }
    return this.isLandscape
      && this.windowHeightVp > 0
      && this.windowHeightVp < PlayerConstants.LANDSCAPE_COMPACT_MAX_WINDOW_H_VP;
  }

  /** 紧凑横屏封面壳实测尺寸（onAreaChange 回写，壳高已天然扣除歌名/歌手/三键块高） */
  private landscapeAreaW: number = 0;
  private landscapeAreaH: number = 0;
  /** 紧凑横屏封面边长（vp）：0 = 首帧未实测（与 lgDiscSize 同一套实测回填思路） */
  @State landscapeDiscSize: number = 0;

  /**
   * 紧凑横屏封面预算：min(封面壳宽, 壳高 − 呼吸间隙)。
   * 实测点挂「封面弹性壳」（layoutWeight(1)，高度 = 左列高 − 歌名/歌手/三键
   * 实测块高），壳高即封面可用高，随 lg 档按钮 76vp / 字号缩放自适应 ——
   * 不能按「内容行宽 × 0.42」估：矮屏上会算出 ≈ 全高，封面吞满左列、
   * 下部元素全部溢出。
   */
  private recomputeLandscapeDisc(): void {
    if (this.landscapeAreaW <= 0 || this.landscapeAreaH <= 0) {
      return;
    }
    this.landscapeDiscSize = Math.floor(Math.min(
      this.landscapeAreaW,
      this.landscapeAreaH - PlayerConstants.LANDSCAPE_COVER_GAP_VP));
  }

  /**
   * LG/MD 左列标题块取数：与 MusicInfoComponent
   * 同口径复制，不抽共享组件 —— Swiper 页那套带分层入场动画（titleOpacity/
   * titleOffsetY）和自己的圆盘预算字段，抽公共层要把动画状态一起搬过来，
   * 得不偿失。数据源仍是 STORE_CURRENT_TRACK，不引入新数据。
   */
  private titleText(): string {
    const t: Track | null = this.currentTrack;
    if (t === null) {
      return '暂无播放内容';
    }
    return t.title.length > 0 ? t.title : '未知歌曲';
  }

  private artistText(): string {
    const t: Track | null = this.currentTrack;
    if (t === null) {
      return '—';
    }
    return t.artist.length > 0 ? t.artist : '未知歌手';
  }

  /** 音质回显文案（分档逻辑与 MusicInfoComponent.qualityText 完全一致） */
  private qualityText(): string {
    const t: Track | null = this.currentTrack;
    // 类型保护：@StorageLink 的 Track | null 在运行时可能被写入 undefined，
    // `=== null` 拦不住，必须一并判掉再读 localFilePath
    if (t === null || t === undefined) {
      return '';
    }
    // 本地文件：没有经过 playurl 解析，码率字段是 0。只标来源，不假装有码率。
    if ((t.localFilePath ?? '').length > 0) {
      return '本地文件';
    }
    const base: string = formatTrackQuality(t.audioQuality, t.audioBandwidth);
    if (base.length === 0) {
      return '';
    }
    // 高档位标签只在**非杜比/非 Hi-Res** 时补（那两档 label 本身就是音质名，再加会重复）
    const hiLabel: string = t.audioQuality === AUDIO_Q_HIRES ? ' · Hi-Res 无损'
      : (t.audioQuality === AUDIO_Q_DOLBY ? ' · 杜比全景声' : '');
    if (hiLabel.length > 0) {
      return `${base}${hiLabel}`;
    }
    // 会员状态在方法体内现算：loginRev（@StorageLink）随登录/退出递增触发重渲染，
    // 方法体随之重读（普通成员只在创建时初始化一次的经典坑，详见 MusicInfoComponent）。
    const loginUser: LoginUser | null = getLoginUser();
    const vip: number = loginUser !== null ? loginUser.vipStatus : 0;
    if (vip === 1) {
      return base;
    }
    return HttpUtil.getLoginCookie().length > 0
      ? `${base} · 大会员可听杜比 / 无损`
      : `${base} · 登录可解锁更高音质`;
  }

  /**
   * 打开主动画 —— morph 路径（仅 morph / morph_swipe 风格走这里，
   * slide 风格走 slideInTransition 的上滑展开）：**唯一**的 animateTo，
   * 闭包内写 STORE_PLAYER_OPEN=true，同帧驱动两套 geometryTransition 配对 ——
   *   · 背景面：PlayBar 迷你栏透明锚点 if 消失 ↔ 本组件全屏背景面 if 出现 →
   *     系统在「迷你栏**真实视觉包围盒** ↔ 全屏」间几何插值（起点偏左下根治，
   *     跨 HDS 窗口坐标换算由系统完成，见 GEOMETRY_ID_PLAYER_SURFACE）；
   *   · 封面：PlayBar 迷你唱片 if 消失 ↔ CoverDisc 大唱片 if 出现 →
   *     页内配对飞行（圆→圆，独立于背景面）；
   *   · Index 页签图标 opacity 同步淡出（@StorageProp/@Watch 同帧翻转）。
   * 时长与曲线（PLAYER_TRANSITION_MS / PLAYER_MAIN_CURVE，iOS 风格贝塞尔——起手果断、长尾柔和）即两套配对飞行时长。
   * onFinish 复位连点防护标志（PlayBar.openPlayer 置位）。
   *
   * ⚠️ 只在 onAppear 启动 —— 首帧已经按 playerOpen=false 画过（背景面未挂载），
   * 若改在 aboutToAppear 里 animateTo，配对出现会被同帧状态合批吃掉。
   *
   * 内容层的显现**不在这里**：顶栏 / 标题块 / 控制区各自由分层入场
   * （LAYER_DELAY_*，随背景面覆盖进度空间序淡入，与飞行尾部重叠），封面刻意不动。
   */
  private playEnterTransition(): void {
    this.getUIContext().animateTo(
      {
        duration: PLAYER_TRANSITION_MS,
        curve: PLAYER_MAIN_CURVE,
        onFinish: (): void => {
          AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, false);
        }
      },
      (): void => {
        AppStorage.setOrCreate(STORE_PLAYER_OPEN, true);
      }
    );
  }

  /**
   * 上滑展开主动画（仅 slide 风格打开路径；
   * openPlayer 已预置 SLIDE_OFFSET=窗高 / SLIDE_ALPHA=0 / GT_OFF / SLIDE_IN，
   * 首帧整页渲染在屏下隐形位）：SLIDE_OPEN_MS(350ms) 减速上滑 + 渐显
   * （PLAYER_SLIDE_IN_CURVE，与下滑收起的加速下滑镜像），闭包内写 ——
   *   · STORE_PLAYER_OPEN=true：页签图标随绑淡出、封面起转；迷你唱片靠
   *     PlayBar 的 slideIn 守卫保持可见（「盖住再隐藏」），透明锚点摘除
   *     （GT id 已空串，无配对）；
   *   · STORE_PLAYER_SLIDE_OFFSET=0 / STORE_PLAYER_SLIDE_ALPHA=1：整页
   *     （PlayerPage 根节点 translate/opacity 绑定）滑入落位。
   * onFinish 复位三项标志：TRANSITIONING（解锁连点防护）、SLIDE_IN（迷你唱片
   * 摘除 —— 此刻整页已全屏盖住迷你栏）、GT_OFF（常驻节点 GT id 恢复，同帧
   * 无挂载/卸载不触发配对）。内容层入场不变（LAYER_DELAY_* 400~530ms），
   * 上滑 350ms 落位后紧接错峰淡入，天然衔接。
   */
  private slideInTransition(): void {
    this.getUIContext().animateTo(
      {
        duration: SLIDE_OPEN_MS,
        curve: PLAYER_SLIDE_IN_CURVE,
        onFinish: (): void => {
          AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, false);
          AppStorage.setOrCreate(STORE_PLAYER_SLIDE_IN, false);
          AppStorage.setOrCreate(STORE_PLAYER_GT_OFF, false);
        }
      },
      (): void => {
        AppStorage.setOrCreate(STORE_PLAYER_OPEN, true);
        AppStorage.setOrCreate(STORE_PLAYER_SLIDE_OFFSET, 0);
        AppStorage.setOrCreate(STORE_PLAYER_SLIDE_ALPHA, 1);
      }
    );
  }

  /** 封面 PixelMap 缓存（同曲复用，不重复下载） */
  private coverCache: image.PixelMap | undefined = undefined;
  /** 取色降采样源缓存（与 coverCache 同源同时效，换曲/销毁一并释放） */
  private smallCache: image.PixelMap | undefined = undefined;
  private coverCacheId: string = '';  /** 取色令牌：切歌后，在途的旧取色结果必须丢弃 */
  private colorToken: number = 0;
  /** 当前背景/配色已应用（或正在应用）的曲目 id；'' = 无。
   *  同曲对象重建（merge/点赞/重试/暂停→播放重载/单曲环绕）据此跳过重铺 */
  private themedId: string = '';

  /** 安全释放 PixelMap：重复释放 / 释放失败只留日志，不打断调用方 */
  private releasePixelMapSafe(p: image.PixelMap): void {
    p.release().catch((e: BusinessError): void => {
      console.error(`release pixelMap failed: ${e.code} ${e.message}`);
    });
  }

  /** 换背景源前先释放旧模糊图：PixelMap 是 Native 内存、不归 GC 管，
   *  覆盖引用不 release 就一直泄到进程退出 */
  private replaceBgCover(next: PixelMap | string): void {
    if (typeof this.bgCover !== 'string') {
      this.releasePixelMapSafe(this.bgCover);
    }
    this.bgCover = next;
  }

  aboutToDisappear(): void {
    // 组件销毁时释放持有的两块 PixelMap
    //（bgCover 模糊图 + coverCache 原图缓存），不释放则 Native 内存泄到进程退出
    if (this.coverCache !== undefined) {
      this.releasePixelMapSafe(this.coverCache);
      this.coverCache = undefined;
      this.coverCacheId = '';
    }
    if (this.smallCache !== undefined) {
      this.releasePixelMapSafe(this.smallCache);
      this.smallCache = undefined;
    }
    if (typeof this.bgCover !== 'string') {
      const blurred: PixelMap = this.bgCover;
      this.bgCover = '';
      this.releasePixelMapSafe(blurred);
    }
  }

  // 折叠态检测不在这里注册 display 监听 —— 播放页是懒加载 overlay，
  // 不挂载就没有折叠态，壳层冷启动读不到。
  // 由 service/FormFactorHolder 在 EntryAbility.onCreate 统一初始化，
  // 本组件 @StorageProp(STORE_FOLD_EXPANDED) 只读订阅。

  aboutToAppear(): void {
    // 背景面转场起点不再手动实测：geometryTransition 配对由系统换算
    // 迷你栏锚点的真实视觉包围盒（见 GEOMETRY_ID_PLAYER_SURFACE）。
    this.onTrackChanged();
  }

  onTrackChanged(): void {
    const track: Track | null = this.currentTrack;
    if (track === null || track.coverUrl.length === 0) {
      this.colorToken++;
      this.themedId = '';
      this.replaceBgCover('');
      this.imageColor = 'rgba(0, 0, 2, 1)';
      this.deepRgb = [0, 0, 1];
      AppStorage.setOrCreate(STORE_PLAYER_BG_DARK, true);
      this.applyStatusBar(true);
      return;
    }
    // 同曲对象重建（merge/点赞/重试/暂停→播放重载/单曲环绕）：
    // 背景已就绪，直接跳过 —— 不重铺原图、不重跑取色+blur，
    // 消除「闪未模糊」窗口和 blur 偶发失败导致的持久消失。
    if (track.id === this.themedId && this.bgCover !== '') {
      return;
    }
    this.themedId = track.id;
    // 切歌时保持旧模糊背景，待新歌 blur PixelMap 就绪后一次性换装
    //（模糊 → 模糊，无闪变窗口）—— bgCover 换成网络 URL 后 Image 在加载期间
    // 渲染空白，加载完又先显清晰原图、blur 完成后再跳一次模糊，会形成
    //「模糊 → 空白 → 清晰 → 模糊」的连环闪变；
    // 下载 / blur 彻底失败时才把原图 URL 铺上去兜底
    //（见 applyTheme / tryBlur 的失败分支，宁可清晰不可挂错图）。
    this.applyTheme(track);
  }

  /** 取主色 + 生成模糊背景（异步，令牌防串台） */
  private async applyTheme(track: Track): Promise<void> {
    const token: number = ++this.colorToken;
    let pixel: image.PixelMap | undefined = undefined;
    let small: image.PixelMap | undefined = undefined;
    if (this.coverCacheId === track.id && this.coverCache !== undefined) {
      pixel = this.coverCache;
      small = this.smallCache;
    } else {
      const loaded: CoverPixelPair | null = await this.loadCoverPair(track.coverUrl);
      if (loaded === null) {
        // 下载失败兜底：此时背景上还没有任何新歌素材，铺原图 URL
        //（Image 自己的加载重试还在），避免长期挂着上一首的模糊背景
        if (token === this.colorToken) {
          this.replaceBgCover(track.coverUrl);
        }
        return;
      }
      // 旧曲的原图缓存先释放再换新（Native 内存，不释放即泄漏）
      if (this.coverCache !== undefined) {
        this.releasePixelMapSafe(this.coverCache);
      }
      if (this.smallCache !== undefined) {
        this.releasePixelMapSafe(this.smallCache);
      }
      this.coverCache = loaded.full;
      this.smallCache = loaded.small;
      this.coverCacheId = track.id;
      pixel = loaded.full;
      small = loaded.small;
    }
    if (token !== this.colorToken) {
      return;
    }

    this.applyPalette(small, pixel, token);
    this.tryBlur(pixel, token, false, track.coverUrl);
  }

  /**
   * 取色：降采样源 readPixelsToBuffer → TaskPool
   * 量化直方图聚类（vibrant 主色 + muted 深辅色）→ animateTo 600ms 平滑换色。
   * 降采样源缺失 / 尺寸字节校验不过 / readPixels / taskpool 异常 / ok:false →
   * 全部回落 effectKit 单色路径（applyLegacyPalette）。
   */
  private applyPalette(small: image.PixelMap | undefined, pixel: image.PixelMap, token: number): void {
    if (small === undefined) {
      this.applyLegacyPalette(pixel, token);
      return;
    }
    small.getImageInfo()
      .then((info: image.ImageInfo): void => {
        if (token !== this.colorToken) {
          return;
        }
        const w: number = info.size.width;
        const h: number = info.size.height;
        const byteCount: number = small.getPixelBytesNumber();
        // 前提校验：解码档位非 RGBA_8888（字节 ≠ w×h×4）即走兜底
        if (w <= 0 || h <= 0 || byteCount !== w * h * 4) {
          this.applyLegacyPalette(pixel, token);
          return;
        }
        const ab: ArrayBuffer = new ArrayBuffer(byteCount);
        small.readPixelsToBuffer(ab)
          .then((): void => {
            if (token !== this.colorToken) {
              return;
            }
            // ArrayBuffer 随任务转移（主线程引用 detach），一次性分配不复用
            const task: Promise<CoverPaletteResult> =
              taskpool.execute(extractCoverPaletteTask, ab, w, h) as Promise<CoverPaletteResult>;
            task
              .then((res: CoverPaletteResult): void => {
                if (token !== this.colorToken) {
                  return;
                }
                if (!res.ok) {
                  this.applyLegacyPalette(pixel, token);
                  return;
                }
                this.publishPalette(res);
              })
              .catch((e: BusinessError): void => {
                console.error(`extractCoverPalette failed: ${e.code} ${e.message}`);
                if (token === this.colorToken) {
                  this.applyLegacyPalette(pixel, token);
                }
              });
          })
          .catch((e: BusinessError): void => {
            console.error(`readPixelsToBuffer failed: ${e.code} ${e.message}`);
            if (token === this.colorToken) {
              this.applyLegacyPalette(pixel, token);
            }
          });
      })
      .catch((e: BusinessError): void => {
        console.error(`getImageInfo failed: ${e.code} ${e.message}`);
        if (token === this.colorToken) {
          this.applyLegacyPalette(pixel, token);
        }
      });
  }

  /**
   * 取色结果发布：主色在 animateTo 600ms 闭包内换（backgroundColor 支持
   * animateTo 颜色插值，切歌瞬跳消除，曲线 Friction 起手快长尾柔）；深辅色与
   * 明暗信号同帧落位 —— linearGradient / 状态栏不参与颜色动画，静态切换无跳变
   *（双色同源同色系，观感连续性由底色动画承接）。
   */
  private publishPalette(res: CoverPaletteResult): void {
    this.getUIContext().animateTo(
      { duration: PALETTE_COLOR_ANIM_MS, curve: Curve.Friction },
      (): void => {
        this.imageColor = buildRgba(res.main, 1);
      }
    );
    this.deepRgb = res.deep;
    AppStorage.setOrCreate(STORE_PLAYER_BG_DARK, res.dark);
    this.applyStatusBar(res.dark);
  }

  /**
   * effectKit 单色取色兜底路径：主色 = 最大占比色
   * dealColor 压亮；深辅色由主色 ×0.5 派生。
   */
  private applyLegacyPalette(pixel: image.PixelMap, token: number): void {
    effectKit.createColorPicker(pixel)
      .then((picker: effectKit.ColorPicker): void => {
        if (token !== this.colorToken) {
          return;
        }
        const color: effectKit.Color = picker.getLargestProportionColor();
        const arr: number[] = ColorConversion.dealColor(color.red, color.green, color.blue);
        this.getUIContext().animateTo(
          { duration: PALETTE_COLOR_ANIM_MS, curve: Curve.Friction },
          (): void => {
            this.imageColor = buildRgba(arr, 1);
          }
        );
        this.deepRgb = [Math.round(arr[0] * 0.5), Math.round(arr[1] * 0.5), Math.round(arr[2] * 0.5)];
        const luminance: number = (0.299 * arr[0] + 0.587 * arr[1] + 0.114 * arr[2]) / 255;
        const isDark: boolean = luminance < 0.5;
        AppStorage.setOrCreate(STORE_PLAYER_BG_DARK, isDark);
        this.applyStatusBar(isDark);
      })
      .catch((e: BusinessError): void => {
        console.error(`createColorPicker failed: ${e.code} ${e.message}`);
      });
  }

  /**
   * 生成模糊背景并换上。blur 链路（createEffect/getEffectPixelMap）偶发失败
   * （GPU 繁忙/内存压力）：首次失败延迟重试一次（令牌校验防跨歌串台）；
   * 重试仍失败铺 fallbackUrl 原图兜底 —— 保证屏幕上至少是新歌封面
   *（清晰但正确，好过一直挂着上一首的模糊图）。
   */
  private tryBlur(pixel: image.PixelMap, token: number, isRetry: boolean, fallbackUrl: string): void {
    const headFilter: effectKit.Filter | null = effectKit.createEffect(pixel);
    if (headFilter !== null) {
      headFilter.blur(PlayerConstants.IMAGE_BLUR);
      headFilter.getEffectPixelMap()
        .then((blurred: image.PixelMap): void => {
          if (token !== this.colorToken) {
            return;
          }
          this.replaceBgCover(blurred);
        })
        .catch((e: BusinessError): void => {
          console.error(`blur cover failed: ${e.code} ${e.message}`);
          if (!isRetry) {
            this.delayBlurRetry(pixel, token, fallbackUrl);
          } else if (token === this.colorToken) {
            this.replaceBgCover(fallbackUrl);
          }
        });
      return;
    }
    console.error('blur cover failed: createEffect returned null');
    if (!isRetry) {
      this.delayBlurRetry(pixel, token, fallbackUrl);
    } else if (token === this.colorToken) {
      this.replaceBgCover(fallbackUrl);
    }
  }

  /** blur 失败后的单次延迟重试（令牌失效即放弃） */
  private delayBlurRetry(pixel: image.PixelMap, token: number, fallbackUrl: string): void {
    setTimeout((): void => {
      if (token === this.colorToken) {
        this.tryBlur(pixel, token, true, fallbackUrl);
      }
    }, BLUR_RETRY_DELAY_MS);
  }

  /** 网络封面 → 双尺寸 PixelMap（B 站图床要带 Referer，同 MusicPlayer 的实现）：
   *  full=512px 模糊背景源，small=48×48 取色降采样源 */
  private async loadCoverPair(url: string): Promise<CoverPixelPair | null> {
    const httpReq: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await httpReq.request(url, {
        method: http.RequestMethod.GET,
        header: { Referer: BILI_REFERER },
        connectTimeout: 10000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      if (resp.responseCode !== 200 || !resp.result) {
        return null;
      }
      if (!(resp.result instanceof ArrayBuffer)) {
        return null;
      }
      const src: image.ImageSource = image.createImageSource(resp.result);
      // 降采样解码：同一 ImageSource 双档输出（512 模糊源 + 48 取色源），
      // 避免整张原图解码占内存，也避免二次下载/二次建源
      const fullOpts: image.DecodingOptions = { desiredSize: { width: 512, height: 512 } };
      const full: image.PixelMap = await src.createPixelMap(fullOpts);
      const smallOpts: image.DecodingOptions =
        { desiredSize: { width: PALETTE_SOURCE_PX, height: PALETTE_SOURCE_PX } };
      const small: image.PixelMap = await src.createPixelMap(smallOpts);
      const pair: CoverPixelPair = { full: full, small: small };
      return pair;
    } catch (e) {
      console.error(`loadCoverPair failed: ${JSON.stringify(e)}`);
      return null;
    } finally {
      httpReq.destroy();
    }
  }

  /** 状态栏内容色随背景明暗切换（全屏布局下状态栏叠在背景上） */
  private applyStatusBar(isDarkBackground: boolean): void {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    ColorConversion.setStatusBarContentColor(ctx, isDarkBackground);
  }

  build() {
      Stack() {
        // ── 背景面：全屏沉浸层，经 geometryTransition
        // 与 PlayBar 迷你栏里的**透明锚点**配对 —— playerOpen 翻转（本组件
        // playEnterTransition / Index.closePlayer 的同一条 animateTo）时，系统在
        // 「迷你栏真实视觉包围盒 ↔ 全屏」间做几何插值，跨 HDS 窗口坐标换算由
        // 系统完成（getRectangleById 等应用侧 API 拿不到合成变换后的视觉几何）。
        // 内容层**不在这里**（它不跟着缩放，靠各层分层入场）。
        // 挂载守卫：playerOpen || slideOut ||
        // slideIn —— 下滑途中 playerOpen 已翻 false，靠 slideOut 背景面不析构、
        // 随整页滑走渐隐；上滑展开时 playerOpen 在 slideInTransition 闭包内才翻
        // true，靠 slideIn 背景面在挂载首帧（屏下隐形位）即渲染、随整页上滑。
        // 柔退路径两标志恒 false，行为与原 playerOpen 单条件完全一致。
        if (this.playerOpen || this.slideOut || this.slideIn) {
          Stack() {
            this.SurfaceLayers()
          }
          .width(StyleConstants.FULL_WIDTH)
          .height(StyleConstants.FULL_HEIGHT)
          .backgroundColor(this.imageColor)
          // 终点圆角：配对两端显式挂 borderRadius
          // 即参与 geometryTransition 形变 —— 飞行途中四角呈胶囊同款圆角（起点
          // 28vp，见 PlayBar 锚点），全屏静止态收平（0），不露底层页面底色。
          // SurfaceLayers 三层均 100% 有界，clip 不裁静止态内容。
          .borderRadius(PLAYER_SURFACE_RADIUS_END_VP)
          .clip(true)
          // GT 门控：gtOff=true 时 id 换空串（无转场）——
          // Index.slideOutClose 先摘全窗 GT 再翻 playerOpen，下滑路径不配对飞行。
          .geometryTransition(this.gtOff ? '' : GEOMETRY_ID_PLAYER_SURFACE)
          // 离场末端渐隐：
          // 官方《共享元素转场（一镜到底）》指南明确 —— geometryTransition 配对时
          // 「系统将调整绑定两组件的宽高及位置至相同值，并切换二者的透明度」，默认
          // 交叉淡化从头淡起、背景面中途就透出首页。这里挂非对称 transition 显式
          // 接管离场透明度：离场侧 opacity(0) 配 PLAYER_BG_EXIT_CURVE
          // （cubicBezier(0.65,0,1,1)）—— 曲线前 ~65% 进度极慢、近似恒持 1
          // （飞行主体全程不透明），末端快速衰减到 0（收缩临落位时背景渐隐、
          // 首页透出），700ms 与几何飞行严格同步。入场侧维持 OPACITY 淡入不变，
          // 打开方向观感与现状一致。
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.OPACITY,
            TransitionEffect.opacity(0)
              .animation({ duration: PLAYER_TRANSITION_MS, curve: PLAYER_BG_EXIT_CURVE })
          ))
        }

      Row() {
        if (this.isCompactLandscape()) {
          // 紧凑横屏（用户拍板「精简元素 + 封面再大一点」）：
          // 左列 45%（封面 + 歌名 + 歌手 + 三键，整列居中）+ 右列纯歌词。
          // 封面预算挂弹性壳实测（min(壳宽, 壳高 − 间隙)），壳高由 layoutWeight(1)
          // 天然扣除下部元素实测高 —— 封面尽可能大且歌名/歌手/三键完整在屏
          //（不能按整行宽 × 0.42 估：矮屏上会算出 ≈ 全高，封面吞满左列、
          // 其余元素全部溢出屏外）；控制区随封面进左列，右列歌词即使异常也不
          // 影响三键可见（结构性兜底）。
          // 外层左右叠加水平安全区：横屏状态栏以侧边条带上报时避让（竖屏为 0）。
          Column() {
            TopAreaComponent()
              .padding({
                left: $r('app.float.common_padding'),
                right: $r('app.float.common_padding')
              })

            Row() {
              // 左列：封面 + 歌名 + 歌手 + 三键，整列居中
              Column() {
                // 封面弹性壳：吃掉歌名/歌手/三键之外的剩余高，封面垂直居中；
                // 壳实测即封面可用空间（onAreaChange → recomputeLandscapeDisc）
                Column() {
                  CoverDiscComponent({ discSize: this.landscapeDiscSize })
                }
                .width(StyleConstants.FULL_WIDTH)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .onAreaChange((_old: Area, n: Area): void => {
                  this.landscapeAreaW = this.toVp(n.width);
                  this.landscapeAreaH = this.toVp(n.height);
                  this.recomputeLandscapeDisc();
                  console.info(`[PlayerInfo] landscape cover-shell ${this.landscapeAreaW}x${this.landscapeAreaH} disc=${this.landscapeDiscSize}`);
                })

                // 歌名 + 歌手（收起柔退 contentFade，同 LG 标题块口径）
                Column() {
                  Text(this.titleText())
                    .fontSize($r('app.float.title_font_play'))
                    .fontColor(Color.White)
                    .opacity(0.95)
                    .fontWeight(FontWeight.Bold)
                    .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width(StyleConstants.FULL_WIDTH)
                    .textAlign(TextAlign.Center)

                  Text(this.artistText())
                    .fontSize($r('app.float.font_fourteen'))
                    .fontColor('rgba(255, 255, 255, 0.55)')
                    .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
                    .margin({ top: $r('app.float.music_text_margin_top') })
                    .fontWeight(FontWeight.Regular)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width(StyleConstants.FULL_WIDTH)
                    .textAlign(TextAlign.Center)
                }
                .width(StyleConstants.FULL_WIDTH)
                .opacity(this.contentFade)

                ControlAreaComponent({ compactMode: true, centerMode: true })
                  .width(StyleConstants.FULL_WIDTH)
                  .margin({ top: $r('app.float.margin_small') })
              }
              .width('45%')
              .height(StyleConstants.FULL_HEIGHT)
              .alignItems(HorizontalAlign.Center)
              .padding({ right: $r('app.float.common_padding') })

              // 右列：纯歌词。双约束缺一不可：layoutWeight(1) 限宽（Row 上下文作用于主轴），补
              // .height(FULL_HEIGHT) 限高 —— 仅宽度权重时内部 LrcView 按歌词
              // 全长测量（无界高），列内容 ~900vp 被 Row 垂直居中上下溢出屏外。
              LyricsComponent({ isShowControl: false })
                .layoutWeight(1)
                .height(StyleConstants.FULL_HEIGHT)
            }
            .layoutWeight(1)
            .padding({
              left: $r('app.float.common_padding'),
              right: $r('app.float.common_padding'),
              bottom: $r('app.float.margin_small')
            })
          }
          .height(StyleConstants.FULL_HEIGHT)
          .padding({
            left: this.safeLeft,
            right: this.safeRight
          })
        } else if (this.isFoldFull && !this.isWideFoldFull()) {
          // isWideFoldFull（展开落 lg + 竖屏，Pura X 类）
          // 命中时放行本分支、穿透到下方 SM Swiper 双页（直板机版式，用户拍板
          // 全宽铺满）—— 本分栏只留常规折叠展开竖屏（md，Mate X 类）；折叠展开
          // 横屏（isFoldFull && isLandscape）命中上方紧凑横屏分支。
          Column() {
            TopAreaComponent()
              .margin({
                bottom: $r('app.float.music_info_margin_top'),
                left: $r('app.float.top_margin_left')
              })
            // 显式补 lg 档列定义 —— 折叠展开横屏
            // 宽度落 lg（≥840vp），只写 md 会让 GridRow/GridCol 在 lg 下回落默认
            // 列数/跨度（12 列默认跨度），4+4 分栏破版。md/lg 均按 8 列 4+4。
            GridRow({
              columns: {
                md: BreakpointConstants.COLUMN_MD,
                lg: BreakpointConstants.COLUMN_MD
              },
              gutter: BreakpointConstants.GUTTER_MUSIC_X
            }) {
              GridCol({
                span: {
                  md: BreakpointConstants.SPAN_SM,
                  lg: BreakpointConstants.SPAN_SM
                }
              }) {
                MusicInfoComponent()
              }
              .margin({
                left: $r('app.float.margin_small'),
                right: $r('app.float.margin_small')
              })

              GridCol({
                span: {
                  md: BreakpointConstants.SPAN_SM,
                  lg: BreakpointConstants.SPAN_SM
                }
              }) {
                LyricsComponent({ isShowControl: false })
              }
              .padding({
                left: $r('app.float.twenty_four')
              })
            }
            .layoutWeight(1)
            .margin({
              bottom: $r('app.float.fold_margin_bottom')
            })
          }
          .layoutWeight(1)
          .padding({
            left: $r('app.float.common_padding'),
            right: $r('app.float.common_padding')
          })
        } else if (this.isCompactFold()) {
          // 阔折叠外屏（Pura X 折起 632×924vp → md）专属版式（用户拍板）：
          // 封面右上角出血裁切（约 1/4 出屏，可见 3/4）；无进度条无时间；
          // 歌名/歌手 + 三键收缩左下；保留左右滑歌词页（歌词占中部）。
          Column() {
            TopAreaComponent()
              .padding({
                left: $r('app.float.common_padding'),
                right: $r('app.float.common_padding')
              })

            // 内容域：Swiper 双页（封面页 | 歌词页）+ 封面出血叠加层。
            Stack({ alignContent: Alignment.TopEnd }) {
              Swiper() {
                // 页1 封面页：视觉由下方叠加的出血封面层负责，本页留白
                //（指示点保留，用户才知道能左滑翻页）。
                Column()
                  .width(StyleConstants.FULL_WIDTH)
                  .height(StyleConstants.FULL_HEIGHT)

                // 页2 歌词页：占内容域主体（用户决策「歌词占中部」）。
                LyricsComponent({ isShowControl: false })
                  .margin({ top: $r('app.float.margin_lyric') })
                  .padding({
                    left: $r('app.float.common_padding'),
                    right: $r('app.float.common_padding')
                  })
              }
              .width(StyleConstants.FULL_WIDTH)
              .height(StyleConstants.FULL_HEIGHT)
              // 指示点顶部居中：圆盘出血位左缘 ≈ 内容域宽 − 可见 3/4 宽，
              // 632vp 外屏上指示点（居中 ±10vp）落在圆盘左侧空档，无遮挡。
              .indicator(this.contentHidden ? false : new DotIndicator()
                .top($r('app.float.options_padding'))
                .selectedColor($r('app.color.select_swiper'))
                .color($r('app.color.slider_track')))
              .loop(false)
              .onChange((index: number): void => {
                this.compactPageIndex = index;
              })
              .onAreaChange((_old: Area, n: Area): void => {
                this.compactAreaW = this.toVp(n.width);
                this.compactAreaH = this.toVp(n.height);
                this.recomputeCompactDisc();
                console.info(`[PlayerInfo] compact area ${this.compactAreaW}x${this.compactAreaH} disc=${this.compactDiscSize}`);
              })

              // 封面出血层（叠加在 Swiper 之外）：封面若留在 Swiper 页内，翻页时
              // 会被带走、且 Swiper 可能裁切横向溢出 —— 叠加层用页下标驱动
              // opacity 200ms 淡出/淡入，行为完全可控。
              // 出血用**负 margin**而非 translate：translate 是纯视觉偏移，
              // geometryTransition 配对框不含偏移量、开合飞行末端会跳变；负
              // margin 参与布局，飞行终点即出血位。hitTestBehavior(None)：
              // 圆盘占右上大块区域，不穿透会挡住其下方的 Swiper 翻页手势。
              CoverDiscComponent({ discSize: this.compactDiscSize })
                .margin({
                  top: COMPACT_DISC_TOP_VP,
                  right: -this.compactBleed()
                })
                .opacity(this.compactPageIndex === 0 ? 1 : 0)
                .animation({ duration: COMPACT_COVER_FADE_MS })
                .hitTestBehavior(HitTestMode.None)
            }
            .layoutWeight(1)

            // 左下信息 + 控制块（用户决策「信息和控制收缩至左下方」）：
            // 标题/歌手 inline（与 LG 左列标题块同源取数、同字号口径）；
            // 三键行由 ControlAreaComponent 紧凑模式渲染（无功能行/进度条/时间）。
            Column() {
              Text(this.titleText())
                .fontSize($r('app.float.title_font_play'))
                .fontColor(Color.White)
                .opacity(0.95)
                .fontWeight(FontWeight.Bold)
                .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })

              Text(this.artistText())
                .textAlign(TextAlign.Start)
                .fontSize($r('app.float.font_fourteen'))
                .fontColor('rgba(255, 255, 255, 0.55)')
                .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
                .margin({ top: $r('app.float.music_text_margin_top') })
                .width(StyleConstants.FULL_WIDTH)
                .fontWeight(FontWeight.Regular)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })

              ControlAreaComponent({ compactMode: true })
                .margin({ top: $r('app.float.margin_small') })
            }
            .alignItems(HorizontalAlign.Start)
            .padding({
              left: $r('app.float.common_padding'),
              right: $r('app.float.common_padding'),
              bottom: $r('app.float.music_component_bottom')
            })
            // 收起柔退：信息块 200ms EaseIn 淡出（contentFade，
            // onContentExit 驱动），与四个子内容层同批错峰退场（封面/背景不在此列）
            .opacity(this.contentFade)
          }
          .height(StyleConstants.FULL_HEIGHT)
        } else if (!this.isFoldFull
          && (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG
          || this.currentBreakpoint === BreakpointConstants.BREAKPOINT_MD)) {
          // !isFoldFull 守卫放行 isWideFoldFull（展开
          // 落 lg + 竖屏）穿透到下方 SM Swiper 双页，不得落平板分栏；真平板 /
          // 直板横屏 / 阔折叠外屏横屏（非展开态）不受影响。
          // MD 不落手机 Swiper —— LG 栅格分栏
          // 的 GridRow 本就定义了 md 的列数/跨度（左列 span 4 | 歌词 span 4），
          // 600~840vp 窗口直接进分栏，与 LG 同一套布局逻辑。
          Column() {
            TopAreaComponent()
              .padding({
                left: $r('app.float.common_padding'),
                right: $r('app.float.common_padding')
              })
            GridRow({
              columns: { md: BreakpointConstants.COLUMN_MD, lg: BreakpointConstants.COLUMN_LG },
              gutter: BreakpointConstants.GUTTER_MUSIC_X
            }) {
              GridCol({
                span: { md: BreakpointConstants.SPAN_SM, lg: BreakpointConstants.SPAN_SM },
                offset: { lg: BreakpointConstants.OFFSET_MD }
              }) {
                Column() {
                  Row() {
                    CoverDiscComponent({ discSize: this.lgDiscSize })
                  }
                  .width(StyleConstants.FULL_WIDTH)
                  .justifyContent(FlexAlign.Center)

                  // 左列标题块（歌名 / 歌手 / 音质回显）：
                  // 歌词列的头部被 LyricsComponent 按 SM 门控关掉，
                  // 正在播什么必须在此可见，对齐手机端播放页信息密度。
                  // 文案与字号和 MusicInfoComponent.MusicInfo 同口径；左列是
                  // SpaceBetween 布局，圆盘预算（recomputeLgDisc）已减掉本块高度。
                  Column() {
                    Text(this.titleText())
                      .fontSize(this.currentBreakpoint === BreakpointConstants.BREAKPOINT_MD
                        ? $r('app.float.title_font_play_md') : $r('app.float.title_font_play'))
                      .fontColor(Color.White)
                      .opacity(0.95)
                      .fontWeight(FontWeight.Bold)
                      .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })

                    Text(this.artistText())
                      .textAlign(TextAlign.Start)
                      .fontSize($r('app.float.font_fourteen'))
                      .fontColor('rgba(255, 255, 255, 0.55)')
                      .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
                      .margin({ top: $r('app.float.music_text_margin_top') })
                      .width(StyleConstants.FULL_WIDTH)
                      .fontWeight(FontWeight.Regular)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })

                    // 音质回显：空串 = 整行不渲染（正在解析音源 / 本地文件 / 无数据），
                    // 不占位不留空隙；rgba 配色随背景明暗压深/提亮（见 isBgDark）。
                    if (this.qualityText().length > 0) {
                      Text(this.qualityText())
                        .fontSize(11)
                        .fontColor(this.isBgDark ? 'rgba(255, 255, 255, 0.55)' : 'rgba(0, 0, 0, 0.55)')
                        .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width(StyleConstants.FULL_WIDTH)
                        .margin({ top: 6 })
                    }
                  }
                  .width(StyleConstants.FULL_WIDTH)
                  .margin({ top: $r('app.float.music_info_margin_top') })
                  .alignItems(HorizontalAlign.Start)
                  // 收起柔退：标题块 200ms EaseIn 淡出（contentFade，
                  // onContentExit 驱动，延迟与 MusicInfoComponent 同档），封面/背景不在此列
                  .opacity(this.contentFade)
                  .onAreaChange((_old: Area, n: Area): void => {
                    this.lgTitleH = this.toVp(n.height);
                    this.recomputeLgDisc();
                  })

                  Column() {
                    ControlAreaComponent()
                  }
                  .onAreaChange((_old: Area, n: Area): void => {
                    this.lgCtrlH = this.toVp(n.height);
                    this.recomputeLgDisc();
                  })
                }
                .height(StyleConstants.FULL_HEIGHT)
                .justifyContent(FlexAlign.SpaceBetween)
                .margin({
                  bottom: $r('app.float.common_margin')
                })
                .onAreaChange((_old: Area, n: Area): void => {
                  this.lgColW = this.toVp(n.width);
                  this.lgColH = this.toVp(n.height);
                  this.recomputeLgDisc();
                })
              }

              GridCol({
                span: { md: BreakpointConstants.SPAN_SM, lg: BreakpointConstants.SPAN_MD },
                offset: { lg: BreakpointConstants.OFFSET_MD }
              }) {
                LyricsComponent({ isShowControl: false })
              }
            }
            .layoutWeight(1)
            .padding({
              left: $r('app.float.common_padding'),
              right: $r('app.float.common_padding'),
              top: $r('app.float.lg_music_top'),
              bottom: $r('app.float.lg_music_margin_bottom')
            })
          }
        } else {
          // 本分支除直板机（sm）外，亦承接阔折叠展开
          // 竖屏（isWideFoldFull 穿透至此）—— 版式与直板机一致、全宽铺满（用户
          // 拍板）：子组件守卫已就位（MusicInfo/Lyrics 的 !isFoldFull 字号与栅格
          // 门控 → 直板机口径；MusicInfo 内 ComponentSize 栅格在 ≥840vp 落
          // component-lg 回落默认 12 列满跨度 = 全宽列），尺寸随断点放大，不居中限宽。
          Stack({ alignContent: Alignment.TopStart }) {
            // SM 固定控制区：控制区移出 Swiper 固定在底部 ——
            // 右滑切歌词页时只有封面区↔歌词区滑动，控制区静止（不能两页
            // 各内嵌一份，滑动中会看到两份控制区在移动）。两页均传
            // isShowControl:false；底部间距沿用页内 margin（music_component_bottom），
            // 左右沿用 common_padding。
            Column() {
              Swiper() {
                MusicInfoComponent({ isShowControl: false })
                  .margin({
                    top: $r('app.float.music_component_top')
                  })
                  .padding({
                    left: $r('app.float.common_padding'),
                    right: $r('app.float.common_padding')
                  })
                LyricsComponent({ isShowControl: false })
                  .margin({
                    top: $r('app.float.margin_lyric')
                  })
                  .padding({
                    left: $r('app.float.common_padding'),
                    right: $r('app.float.common_padding')
                  })
              }
              .layoutWeight(1)
              // 受控页下标 + 切换时长：收起开始
              // 时 onContentExit 置 duration 0 并回跳第 0 页，封面配对起点回屏幕
              // 中央；手势滑动经 onChange 回写 smIndex，翻页行为不变。
              .index(this.smIndex)
              .duration(this.smAnimDuration)
              .onChange((index: number): void => {
                this.smIndex = index;
              })
              // 收起瞬隐：指示点随 contentHidden 单帧消失（indicator 接受 boolean，
              // false = 不渲染指示点，见 Swiper indicator 重载）
              .indicator(this.contentHidden ? false : new DotIndicator()
                .top($r('app.float.options_padding'))
                .selectedColor($r('app.color.select_swiper'))
                .color($r('app.color.slider_track')))
              .clip(false)
              .loop(false)
              // 边界回弹：Swiper 在当前 SDK 无 .edgeEffect 属性，
              // 但 loop(false) 模式下默认即 Spring 回弹，无需显式声明。

              // 固定控制区（Swiper 外）：入场动画 / 收起瞬隐由 ControlAreaComponent
              // 内部自理（LAYER_DELAY_CONTROL 分层入场 + STORE_PLAYER_CONTENT_EXIT），不额外包动画层。
              ControlAreaComponent()
                .padding({
                  left: $r('app.float.common_padding'),
                  right: $r('app.float.common_padding')
                })
                .margin({
                  bottom: $r('app.float.music_component_bottom')
                })
            }
            .height(StyleConstants.FULL_HEIGHT)

            TopAreaComponent()
              .padding({
                left: $r('app.float.common_padding'),
                right: $r('app.float.common_padding')
              })
          }
          .height(StyleConstants.FULL_HEIGHT)
        }
      }
      .padding({
        top: this.safeTop,
        bottom: this.safeBottom
      })
      // ⚠️ 这里**不能挂整块 opacity**：
      // 它会连封面一起淡掉，把「迷你栏变大 + 封面飞出」压成「背景块长开 + 内容浮现」。
      // 内容显现交给各层的分层入场；且本层一旦挂 translate/scale，
      // 共享元素（封面）的目标框还会被搬走 —— 只允许纯布局，不许 transform。
    }
    .height(StyleConstants.FULL_HEIGHT)
    .width(StyleConstants.FULL_WIDTH)
    // 主动画只能在 onAppear 启动（首帧已按起始态画过：morph 路径背景面未挂载 /
    // 上滑路径整页在屏下隐形位），见 playEnterTransition / slideInTransition。
    // 分流依据 slideIn（openPlayer 的 slide 分支挂载前预置，仅上滑展开为 true）。
    .onAppear((): void => {
      if (this.slideIn) {
        this.slideInTransition();
      } else {
        this.playEnterTransition();
      }
    })
  }

  /**
   * 背景三层：模糊封面 / 渐变压深 / 噪点。
   *
   * 它们原来直接挂在页面根 Stack 上，现在收进「生长面」容器 —— 尺寸写 100%，
   * 随生长面一起被拉伸/裁剪。三者都是可拉伸的无文本图元，逐帧重排代价可忽略。
   *
   * 背景按封面风格（coverStyle）分流；底色恒由背景面 Stack
   * 的 backgroundColor(imageColor) 提供（600ms animateTo 颜色动画承接观感
   * 连续性），取色/模糊管线（applyTheme/tryBlur）全风格共用零改动 ——
   * square 不消费模糊图但保持计算，运行时切风格无重触发：
   *   · disc：三层（模糊 0.5 + 深辅色着色的纵向压深渐变 + 噪点 0.05）；
   *   · square：主色 → 深辅色对角双色渐变。
   * 渐变停靠点用深辅色（deepRgb）变体，双色
   * 同源同色系 —— linearGradient 不参与 animateTo，静态切换无跳变感。
   */
  @Builder
  SurfaceLayers(): void {
    // ── 方卡极简：主色 → 深辅色对角双色渐变（底色 Stack 仍为 imageColor 动画层）
    if (this.coverStyle === PLAYER_COVER_STYLE_SQUARE) {
      Column()
        .width(StyleConstants.FULL_WIDTH)
        .height(StyleConstants.FULL_HEIGHT)
        .linearGradient({
          angle: 160,
          colors: [
            [this.imageColor, 0.0],
            [buildRgba(this.deepRgb, 1), 1.0]
          ]
        })
    } else {
      // ── 唱片（默认）：现状三层
      if (this.bgCover !== '') {
        Image(this.bgCover)
          .width(StyleConstants.FULL_WIDTH)
          .height(StyleConstants.FULL_HEIGHT)
          .objectFit(ImageFit.Cover)
          .opacity(0.5)
          // 背景图加载失败：摘掉自己，露出主题色底 + 渐变 + 噪点，不留白块。
          // 只在当前源仍是 URL 时清：blur 已就绪（bgCover 为 PixelMap）后，
          // 迟到的旧 URL 加载失败不允许把模糊背景整体抹掉（偶发消失的竞态面）。
          .onError((err: ImageError): void => {
            if (typeof this.bgCover === 'string') {
              this.bgCover = '';
              this.themedId = '';
            }
          })
      }
      // 缓慢渐变底色：深辅色着色的自上而下压深（deepRgb 变体，
      // 压深层携带封面 muted 色相），底部最暗 ——
      // 静态渐变不产生每帧开销
      Column()
        .width(StyleConstants.FULL_WIDTH)
        .height(StyleConstants.FULL_HEIGHT)
        .linearGradient({
          angle: 180,
          colors: [
            [buildRgba(this.deepRgb, 0.05), 0.0],
            [buildRgba(this.deepRgb, 0.22), 0.45],
            [buildRgba(this.deepRgb, 0.45), 1.0]
          ]
        })
      // 微弱噪点纹理：打破纯色渐变的塑料感，低透明度平铺，无逐帧成本
      Column()
        .width(StyleConstants.FULL_WIDTH)
        .height(StyleConstants.FULL_HEIGHT)
        .backgroundImage($r('app.media.noise_texture'), ImageRepeat.XY)
        .backgroundImageSize({ width: 128, height: 128 })
        .opacity(0.05)
    }
  }
}
