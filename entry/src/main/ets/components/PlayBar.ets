/**
 * 全局底部播放栏（PlayBar）—— HDS 悬浮底栏 miniBar 槽位内容（与页签胶囊融合）。
 *
 * 架构（2026-10-14 重构：内容侧全面动画驱动）：
 *   本组件**不再自带定位与背景**，作为 Index.ets 里 barFloatingStyle.miniBar 的
 *   builder 内容渲染 —— HDS 把它和页签项排进**同一个悬浮胶囊**
 *   （barLayoutMode: HdsBarLayoutMode.HORIZONTAL：播放栏在左、页签在右，一行融合），
 *   液态玻璃材质、悬浮离底、底部安全区避让全部由 HDS 统一处理，无需重复实现。
 *
 *   build() = **恒驻唱片（Disc）+ 内容体（Body）交叉淡入淡出**：
 *     · Disc —— 唱片圆盘**永不重挂载**：旋转连续（AnimatorResult 每帧回写角度）、
 *       geometryTransition 全程单节点、位置恒为行首（padding 8 后）——
 *       任何收起/展开动画期间唱片零位移零跳动。尺寸 discSizeVp 由
 *       onMiniBarAnimPhaseChanged / onExpandedChanged 两个 @Watch 用 animateTo
 *       过渡（垂直两层收起/展开 28↔40 平滑跟随槽位高度）。
 *     · Body —— 歌名/歌手 + 播放/暂停键，在隔离 Stack 里按 bodyVisible() 挂载/卸载，
 *       根节点挂 TransitionEffect.OPACITY（CONTENT_FADE_MS=400，EaseInOut）——
 *       收起/展开时与圆环进度交叉淡入淡出，全程无瞬切（替代旧的两套内容体
 *       if/else 硬切 —— 那正是「收起/展开跳动错位」的根源）。
 *     · 直线进度（整行底边 2vp）与圆环进度（水平收起态圆盘边缘）同样挂 OPACITY
 *       transition，随 bodyVisible() 淡入淡出。
 *
 *   bodyVisible()（相位鲁棒 —— onBarStyleChange 相对动画起止的翻转时序不保证）：
 *     · 垂直两层 / 宽屏 → 恒 true（2026-10-13 用户要求：垂直两层收起与展开内容一致）；
 *     · 槽位动画中 → TO_EXPAND 淡入 / TO_COLLAPSE 淡出（相位来自 Index 发布的
 *       STORE_MINI_BAR_ANIM_PHASE，HDS onMiniBarAnimationStart/End 回调写入）；
 *     · 空闲 → 按展开态（STORE_MINI_BAR_EXPANDED）。
 *   圆环进度只在水平融合收起态显示（ringVisible() = !bodyVisible()）。
 *
 * HDS 槽位几何动画为**内建固定时长**（d.ets 确认 applyMiniBarStyle 无时长参数、
 * SDK 不开放配置），本组件只通过已上线的相位回调同步**内容侧**动画的起止，
 * 不试图驱动槽位几何本身。CONTENT_FADE_MS 刻意略长于 HDS 形变（约 250~300ms），
 * 留一点柔和余韵。
 *
 * 点击语义（onEntryTap 统一，两种布局一致）：
 *   收起态（水平圆盘 / 垂直收起行）点按 → 先经 onExpandRequest 展开；
 *   展开态点按 → 打开播放页（openPlayer：挂载 Index 根 Stack 的播放页 overlay，
 *   背景面经槽位内**透明锚点**与播放页全屏面 geometryTransition 配对（起点 =
 *   迷你栏真实视觉包围盒，系统跨 HDS 窗口换算），封面另走 geometryTransition
 *   页内配对一镜到底，连点防护复用 STORE_PLAYER_TRANSITIONING；2026-10-21 起
 *   不再 pushPath 路由跳转）。
 *
 * 封面圆盘尺寸（coverSize → discSizeVp 初值）：**纯常量选择，不做任何测量**。
 *   · 展开态 / 宽屏 / 水平融合 → COVER_SIZE(40)；
 *   · 垂直两层 + 收起 → MINI_DISC_COLLAPSED_VERTICAL(28)（收起行更矮，40 会被裁）。
 *   ⚠️ 曾经用根节点 onAreaChange 实测槽位高来自适应 —— **真机回归：垂直两层下
 *   展开迷你栏直接消失**。教训：别在 HDS 托管的内容里「由布局回调回写 @State」，
 *   状态写入落在 HDS 自己的形变动画过程中，内容会中途重建、槽位挂掉。
 *   恒驻唱片架构下更不能挂 —— 唱片是唯一恒驻节点，重建即旋转/转场断裂。
 *   ⚠️ 常量也不能取太大：enableMiniBarClip 默认 true，超出槽位的部分会被硬裁。
 *
 * 唱片旋转（AnimatorResult 驱动，非 .animation() 属性动画）：
 *   当前 SDK 没有 AnimationState / playControls，属性动画无法暂停保持角度；
 *   用 UIContext.createAnimator（begin 0°→end 360°，linear，iterations -1 无限循环）
 *   每帧回写 @State rotateAngle → Image.rotate({ z: 1, angle }) 跟转：
 *     · isPlaying=true  → play()    —— 等价 Playing，从暂停帧继续；
 *     · isPlaying=false → pause()   —— 等价 Paused，冻结当前角度**不复位**；
 *     · 切歌（track 变化）→ reset() —— 等价 Stopped，角度重置 0°，再按播放态决定是否续转。
 *
 * 播放进度指示（主题色）：
 *   · 圆环 —— 水平融合收起态：与圆盘同尺寸的兄弟节点叠在封面边缘（描边画在
 *     组件边界内侧、不触发 clip；不随唱片旋转、不参与 geometryTransition）；
 *   · 直线 —— 整行内容（展开 / 垂直两层 / 宽屏）：槽位底边 2vp（Stack Bottom
 *     叠加 + 淡主题色底轨 + 左右内缩避开胶囊圆角；只铺播放栏槽位，HDS clip
 *     会把内容裁在槽位内，延伸不到页签段）。
 *   数据源 STORE_PROGRESS / STORE_DURATION（秒，500ms 分桶推送）+ STORE_THEME_PRIMARY；
 *   duration<=0（加载中 / 未解析）不渲染，切歌瞬间随清零短暂隐藏属预期。
 *
 * 状态复用（不新建数据）：@StorageLink / @StorageProp 绑既有播放状态
 *   STORE_QUEUE / STORE_CURRENT_TRACK / STORE_IS_PLAYING；播放控制直调
 *   MusicPlayer 单例 prev / togglePlay / next，「播完自动下一首」留在播放内核。
 *
 * 边界：歌单队列为空 / 无在播曲目时本组件不渲染；Index 侧还会整体摘除
 * miniBar 槽位（barFloatingStyle 不带 miniBar），胶囊退回纯页签形态。
 */

import { Track, BAR_LAYOUT_HORIZONTAL, BAR_LAYOUT_VERTICAL } from '../model/MusicModels';
import { MusicPlayer } from '../player/MusicPlayer';
import { AnimatorOptions, AnimatorResult } from '@kit.ArkUI';
import { toThumbUrl } from '../utils/TextUtil';
import { CoverImage } from './CoverImage';
import {
  STORE_CURRENT_TRACK,
  STORE_IS_PLAYING,
  STORE_QUEUE,
  STORE_PLAYER_TRANSITIONING,
  STORE_PLAYER_OPEN,
  STORE_PLAYER_OVERLAY_MOUNTED,
  STORE_MINI_BAR_EXPANDED,
  STORE_MINI_BAR_ANIM_PHASE,
  MINI_BAR_ANIM_IDLE,
  MINI_BAR_ANIM_TO_EXPAND,
  MINI_BAR_ANIM_TO_COLLAPSE,
  STORE_BAR_LAYOUT,
  STORE_MINI_BAR_PROGRESS,
  STORE_PROGRESS,
  STORE_DURATION,
  STORE_APP_FOREGROUND,
  STORE_THEME_PRIMARY,
  GEOMETRY_ID_PLAYER_DISC,
  GEOMETRY_ID_PLAYER_SURFACE,
  PLAYER_SURFACE_RADIUS_START_VP
} from '../common/Constants';
import { MaterialCompat } from '../utils/MaterialCompat';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';

/**
 * 封面圆盘边长（vp）：**展开态 / 宽屏 / 水平融合**的固定值。
 * ⚠️ 垂直两层的**收起态**不用它 —— 那边收起行更矮，用
 * `MINI_DISC_COLLAPSED_VERTICAL`(28)，否则 40vp 会被 `enableMiniBarClip` 裁掉一圈。
 */
const COVER_SIZE: number = 40;
/**
 * 垂直两层**收起态**的封面圆盘边长（vp）。
 *
 * ⚠️ 为什么是常量、而不是按槽位实测自适应：HDS 不暴露 miniBar 高度（`barWidth`/
 * `barHeight` 是整条页签栏的），唯一能「自适应」的办法是在内容里挂 `onAreaChange`
 * 回写 @State —— **真机回归：垂直两层下展开迷你栏直接消失**。**别再用测量换自适应**：
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
/** 收起态圆环进度描边宽（vp）：同尺寸叠在圆盘边缘、盖在封面上 */
const RING_STROKE_VP: number = 2.5;
/** 整行内容底边直线进度条厚度（vp） */
const LINE_HEIGHT_VP: number = 2;
/** 直线进度底轨的主题色透明度（淡显，不与文字抢焦点） */
const LINE_TRACK_ALPHA: number = 0.18;
/** 直线进度左右内缩（vp）：避开胶囊圆角（只铺播放栏槽位，HDS 会裁槽位外内容） */
const LINE_INSET_VP: number = 8;
/**
 * 垂直两层收起/展开时圆盘尺寸（28↔40）的过渡时长（ms）。
 * 与 HDS 槽位形变动画近似同步（HDS 不暴露时长，取常规动效档 300）；
 * 起止由 onMiniBarAnimationStart/End 对齐，微小时长差在 clip 裁剪下不可见。
 */
const MINI_BAR_DISC_ANIM_MS: number = 300;
/**
 * 内容体（Body）/ 直线进度 与 圆环进度 交叉淡入淡出的时长（ms）。
 * 刻意略长于 HDS 槽位形变（内建约 250~300ms，不可配）—— 收放结束后留一点
 * 柔和余韵；观感拖沓只调这一处。
 */
const CONTENT_FADE_MS: number = 400;

@Component
export struct PlayBar {
  /** 播放队列（歌单列表）：为空时内容不渲染 */
  @StorageLink(STORE_QUEUE) queue: Track[] = [];
  /** 在播曲目（currentSong）：封面 / 歌名 / 歌手的数据源；@Watch 切歌时重置唱片角度 */
  @StorageLink(STORE_CURRENT_TRACK) @Watch('onTrackChanged') currentTrack: Track | null = null;
  /** 播放中标志（isPlaying）：切换播放 / 暂停图标；@Watch 驱动唱片 play / pause */
  @StorageLink(STORE_IS_PLAYING) @Watch('onPlayingChanged') isPlaying: boolean = false;

  /**
   * 前后台标志（2026-10-21 后台耗电优化）：退后台冻结唱片动画，避免
   * animator 帧回调 / @State 回写在 UI 冻结后空转；回前台在播时续转。
   */
  @StorageProp(STORE_APP_FOREGROUND) @Watch('onForegroundChanged') appForeground: boolean = true;
  /**
   * miniBar 展开 / 收起态（Index 的 onBarStyleChange 写入，这里只读；默认折叠）。
   * 空闲时决定 Body 挂载与否（bodyVisible 的兜底分支）；动画进行中不介入
   * （相位驱动淡入淡出）。@Watch 兜底：onBarStyleChange 晚于动画结束翻转时
   * （时序不保证），由这里把圆盘尺寸对齐到最终态。
   */
  @StorageProp(STORE_MINI_BAR_EXPANDED) @Watch('onExpandedChanged') expanded: boolean = false;
  /**
   * miniBar 槽位几何动画相位（Index 的 onMiniBarAnimationStart/End 写入）：
   * HDS 收起/展开的槽位形变动画期间保持非 IDLE。作用（内容侧动画驱动的同步锚）：
   *   · bodyVisible()：TO_EXPAND 期间 Body 淡入、TO_COLLAPSE 期间淡出
   *     —— 内容过渡与 HDS 槽位形变同起止，不再依赖 clip 揭示、不再瞬切；
   *   · 垂直两层：圆盘尺寸（28↔40）按相位起止与槽位高度同步过渡（animateTo）。
   */
  @StorageProp(STORE_MINI_BAR_ANIM_PHASE) @Watch('onMiniBarAnimPhaseChanged')
  animPhase: number = MINI_BAR_ANIM_IDLE;
  /**
   * 底部导航布局（设置页「外观 → 底部导航布局」的运行时镜像，与 Index.barFloatingStyle
   * 同源；取值 BAR_LAYOUT_HORIZONTAL / BAR_LAYOUT_VERTICAL，见 model/MusicModels）。
   *
   * 决定**收起态**能放多少内容（bodyVisible 的第一分支）：
   *   · HORIZONTAL 水平融合 —— 收起时 HDS 把槽位缩到圆盘大小，Body 淡出只剩
   *     圆盘 + 圆环进度（恒驻 Disc 不动，零位移零重挂载）；
   *   · VERTICAL 垂直两层 —— 播放栏独占上面一整行，收起态仍是一整行宽度
   *     → 收起与展开**共用同一套内容**（Body 恒显，仅行高与 discSizeVp 过渡）。
   */
  @StorageProp(STORE_BAR_LAYOUT) barLayout: string = BAR_LAYOUT_HORIZONTAL;
  /**
   * 当前断点：md/lg（HdsTabs 宽度 ≥600vp）下 HDS 强制展开迷你栏，
   * miniBarStyle / applyMiniBarStyle 全部失效（官方文档：仅宽度 <600vp 可设）。
   * 此时 Body 恒显（bodyVisible 对非 SM 恒 true）、点击直达播放页，
   * 收起分支天然走不到（无「点了没反应」死胡同）。
   */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string =
    BreakpointConstants.BREAKPOINT_SM;

  /** 播放进度（秒，MusicPlayer 500ms 分桶推送）：驱动圆环 / 直线进度指示 */
  @StorageProp(STORE_PROGRESS) progressSec: number = 0;
  /** 曲目总时长（秒）：<=0（加载中 / 未解析）时不渲染进度指示 */
  @StorageProp(STORE_DURATION) durationSec: number = 0;
  /** 主题色主色（hex 字符串，ThemeColors 发布）：进度指示用色，切主题即时跟随 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /**
   * 迷你栏进度指示开关（设置 → 外观「迷你栏进度条」，AppSettings.miniBarProgress
   * 的运行时镜像，EntryAbility 首帧前首发真值）：关闭后底部直线进度条与水平
   * 收起态圆环进度均不渲染（两处渲染条件都挂它）。纯显示层开关，不影响播放状态。
   */
  @StorageProp(STORE_MINI_BAR_PROGRESS) miniBarProgress: boolean = true;

  /**
   * 播放页展开态（Index overlay 挂载后由 PlayerInfoComponent 主动画写 true）：
   * true 期间迷你唱片摘除（大唱片端 geometryTransition 配对飞行，圆→圆 morph）、
   * 槽位保留恒定占位（外包 Stack 定宽高，Body 布局零跳动）。
   */
  @StorageProp(STORE_PLAYER_OPEN) playerOpen: boolean = false;

  /** 唱片当前旋转角度（°）：animator 每帧回写，暂停时冻结在当前值 */
  @State rotateAngle: number = 0;
  /** 迷你播放/暂停键的点击回弹缩放（独立状态，与唱片旋转互不相干） */
  @State miniPlayScale: number = 1;
  /**
   * 封面圆盘边长的运行时值（vp）：挂载时按 coverSize() 初始化，之后只在
   * 槽位动画起止（animPhase）与展开态翻转（expanded）时过渡 ——
   * 恒驻 Disc 用它渲染（垂直两层 28↔40 平滑跟随槽位高度）。
   */
  @State discSizeVp: number = COVER_SIZE;

  /** 唱片旋转 animator：play=续转 / pause=冻结 / reset=归零（aboutToAppear 里创建） */
  private coverAnim: AnimatorResult | null = null;

  /** 收起态点击请求重新展开（宿主回调 HdsTabsController.applyMiniBarStyle） */
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
    // 圆盘尺寸初值按当前布局 / 展开态取（垂直两层收起 = 28，其余 = 40）
    this.discSizeVp = this.coverSize();
    // UIContext 在属性初始化时未就绪，animator 延迟到 here 创建（同 LrcView）
    try {
      this.coverAnim = this.getUIContext().createAnimator(this.discOptions());
      this.coverAnim.onFrame = (value: number): void => {
        this.rotateAngle = value;
      };
      // 挂载时可能已在播放中（isPlaying 初值即 true，@Watch 不会触发，需手动起转）
      if (this.isPlaying && this.appForeground) {
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
    this.syncDiscAnim();
  }

  /** 退后台冻结 / 回前台续转（在播时），统一走 syncDiscAnim */
  private onForegroundChanged(): void {
    this.syncDiscAnim();
  }

  /** 唱片旋转统一入口：前台且在播才续转，否则冻结在当前帧角度（绝不复位到 0） */
  private syncDiscAnim(): void {
    const anim: AnimatorResult | null = this.coverAnim;
    if (anim === null) {
      return;
    }
    if (this.isPlaying && this.appForeground) {
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
    // 后台切歌不起转：回前台时 onForegroundChanged 会按播放态补起转
    if (this.isPlaying && this.appForeground) {
      anim.play();
    }
  }

  /**
   * 槽位动画起止（相位变化，内容侧动画的同步锚）：
   * 动画开始 → 垂直两层的圆盘尺寸（28↔40）与 HDS 槽位形变同步过渡；
   * 回 IDLE 不做事 —— 尺寸在开始时已过渡到位，终值对齐交给 onExpandedChanged
   * （onBarStyleChange 相对动画起止的翻转时序不保证）。
   * 只有「垂直两层 + 手机宽度」的圆盘尺寸随槽位过渡；水平融合 / 宽屏两态恒 40。
   */
  private onMiniBarAnimPhaseChanged(): void {
    if (this.animPhase === MINI_BAR_ANIM_IDLE) {
      return;
    }
    if (this.barLayout !== BAR_LAYOUT_VERTICAL
      || this.currentBreakpoint !== BreakpointConstants.BREAKPOINT_SM) {
      return;
    }
    // 走到这里 animPhase 只会是 TO_EXPAND / TO_COLLAPSE（IDLE 已提前返回）
    const target: number = this.animPhase === MINI_BAR_ANIM_TO_EXPAND
      ? COVER_SIZE : MINI_DISC_COLLAPSED_VERTICAL;
    this.getUIContext().animateTo(
      { duration: MINI_BAR_DISC_ANIM_MS, curve: Curve.EaseInOut },
      (): void => {
        this.discSizeVp = target;
      }
    );
  }

  /**
   * 展开态翻转（onBarStyleChange）：动画进行中不介入（相位驱动尺寸过渡）；
   * 空闲时把圆盘尺寸对齐到当前态 —— 兜住「onBarStyleChange 晚于动画结束翻转」
   * 与「无动画路径直接翻态」（断点切换等），值相同则不动。
   */
  private onExpandedChanged(): void {
    if (this.animPhase !== MINI_BAR_ANIM_IDLE) {
      return;
    }
    const target: number = this.coverSize();
    if (this.discSizeVp === target) {
      return;
    }
    this.getUIContext().animateTo(
      { duration: MINI_BAR_DISC_ANIM_MS, curve: Curve.EaseInOut },
      (): void => {
        this.discSizeVp = target;
      }
    );
  }
  private coverUrl(): string {
    return this.currentTrack !== null ? this.currentTrack.coverUrl : '';
  }

  /** 播放进度比例（0~1，钳制）：duration<=0 返回 0（该情形下进度指示根本不渲染） */
  private progressPct(): number {
    if (this.durationSec <= 0) {
      return 0;
    }
    return Math.min(1, Math.max(0, this.progressSec / this.durationSec));
  }

  /**
   * 内容体（Body / 直线进度）是否挂载 —— 替代旧的两套内容体 if/else 硬切网关，
   * 保留相位鲁棒性（onBarStyleChange 相对动画起止的翻转时序不保证）：
   *   · 垂直两层 / 宽屏 → 恒 true（2026-10-13 用户要求：收起与展开内容一致）；
   *   · TO_EXPAND → true（Body 随槽位展开淡入）；
   *   · TO_COLLAPSE → false（Body 随槽位收缩淡出）；
   *   · 空闲 → 按展开态。
   */
  private bodyVisible(): boolean {
    if (this.barLayout === BAR_LAYOUT_VERTICAL
      || this.currentBreakpoint !== BreakpointConstants.BREAKPOINT_SM) {
      return true;
    }
    if (this.animPhase === MINI_BAR_ANIM_TO_EXPAND) {
      return true;
    }
    if (this.animPhase === MINI_BAR_ANIM_TO_COLLAPSE) {
      return false;
    }
    return this.expanded;
  }

  /** 圆环进度是否显示：只在水平融合收起态（Body 隐去时）叠在恒驻唱片边缘 */
  private ringVisible(): boolean {
    return !this.bodyVisible();
  }
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
   * 打开全屏播放页（2026-10-21 改版：**组件状态切换动画，不再 pushPath 路由**）。
   *
   * 只做两件事：连点防护 → 挂载 Index 根 Stack 上的播放页 overlay。
   * 主动画（背景面从迷你栏**真实视觉包围盒**向四周扩大 + 封面 geometryTransition
   * 飞行 + 页签图标淡出）全部由 PlayerInfoComponent 在 overlay 挂载后的**单个
   * animateTo** 驱动（见其 playEnterTransition）。
   * 收起为逆向镜像（Index.closePlayer），返回不走路由栈 —— 播放页不再是 NavDestination。
   */
  private openPlayer(): void {
    // 诊断日志（折叠屏「点 miniBar 不跳转」排查）：能打出这行说明点击已送达展开态条目
    console.info(`[PlayBar] openPlayer: bp=${this.currentBreakpoint}, expanded=${this.expanded}`);
    // 连点防护：转场进行中再开一次会叠出两层主动画（收起要按两次才回得来）。
    // 复用转场标志即可 —— 它在整个进出过程中都为真（打开时置位、主动画 onFinish /
    // closePlayer 收尾复位），不需要额外的状态。
    if (AppStorage.get<boolean>(STORE_PLAYER_TRANSITIONING) ?? false) {
      console.info('[PlayBar] openPlayer ignored: transition in progress');
      return;
    }
    AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, true);
    // 挂载 overlay（Index 根 Stack 条件渲染 LazyDest('Player')，懒加载 + 预热复用）
    AppStorage.setOrCreate(STORE_PLAYER_OVERLAY_MOUNTED, true);
  }

  /**
   * 整条 miniBar 的统一点击语义（2026-10-14 与内容侧动画驱动重构同步统一）：
   *   水平融合收起态（SM 圆盘）→ 先经 onExpandRequest 展开；
   *   其余（展开态 / 垂直两层任意态 / 宽屏）→ 进播放页。
   *
   * 垂直两层收起态直接跳播放页（2026-10-19 用户要求）：该布局下收起与展开
   * 内容一致（同为整行，见 bodyVisible），点按无「看全内容」诉求；主动展开
   * 走全屏上滑手势（Index 的 parallelGesture），不依赖点按。水平融合保持
   * 「先展开」旧语义 —— HDS 收起时槽位缩成圆盘，点按是唯一主动展开入口。
   * 宽屏（非 SM）HDS 强制展开、全局展开态已被 Index 同步为 true → 收起分支
   * 走不到，直接进播放页（无「点了没反应」死胡同）。
   */
  private onEntryTap(): void {
    if (!this.expanded && this.barLayout === BAR_LAYOUT_HORIZONTAL
      && this.currentBreakpoint === BreakpointConstants.BREAKPOINT_SM
      && this.onExpandRequest !== undefined) {
      // 诊断日志：确认水平融合收起态点击走了「先展开」分支
      console.info(`[PlayBar] collapsed tap -> expand: layout=${this.barLayout}, bp=${this.currentBreakpoint}`);
      this.onExpandRequest();
      return;
    }
    this.openPlayer();
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
   * 恒驻唱片：封面圆盘 + 收起态圆环进度。
   *
   * **永不重挂载**（两态切换只动 Body / 圆环的挂载，Disc 本体常在）：
   *   · 旋转连续（rotate 挂 CoverImage，animator 每帧回写）；
   *   · geometryTransition 全程单节点（与播放页大圆盘同 id 配对，一镜到底）；
   *   · 位置恒为行首（外层 Row padding 8 后）—— 收起/展开动画期间零位移。
   * 尺寸 = discSizeVp（运行时值，相位 / 展开态 @Watch 驱动 animateTo 过渡）。
   * 缩略图仍按 96px 请求（3x 屏下即使 40vp 也够清晰，且尺寸变化不换 url → 不重新下载）。
   * ⚠️ 这里**不能**挂 onAreaChange 之类的布局回调去改尺寸状态 —— 详见
   * MINI_DISC_COLLAPSED_VERTICAL 的注释（真机上会把 HDS 的槽位搞塌）。
   */
  @Builder
  Disc(): void {
    Stack() {
      CoverImage({ url: toThumbUrl(this.coverUrl(), 96), imgWidth: this.discSizeVp, imgHeight: this.discSizeVp, imgRadius: this.discSizeVp / 2 })
        .rotate({ z: 1, angle: this.rotateAngle })
        .geometryTransition(GEOMETRY_ID_PLAYER_DISC)

      // 圆环进度：只在水平融合收起态显示（ringVisible），与圆盘同尺寸的兄弟节点
      // → 描边画在组件边界内侧、贴圆盘边缘，不触发 enableMiniBarClip 裁剪；
      // 不随唱片旋转（rotate 只挂在 CoverImage 上），也不参与 geometryTransition
      // （转场时环留在槽位内，无跳变）。挂 OPACITY transition 与 Body 交叉淡入淡出。
      // 底轨透明：封面不被灰圈压住，只显示主题色弧线。duration<=0（加载中）不渲染；
      // 迷你栏进度条开关（miniBarProgress）关闭时同样不渲染。
      if (this.ringVisible() && this.miniBarProgress && this.durationSec > 0) {
        Progress({ value: Math.min(this.progressSec, this.durationSec), total: this.durationSec, type: ProgressType.Ring })
          .width(this.discSizeVp)
          .height(this.discSizeVp)
          .style({ strokeWidth: RING_STROKE_VP })
          .color(this.themePrimary)
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.Transparent)
          .transition(TransitionEffect.OPACITY.animation({ duration: CONTENT_FADE_MS, curve: Curve.EaseInOut }))
      }
    }
  }

  /**
   * 内容体：歌名/歌手 + 播放/暂停键（按钮点击不会冒泡成跳转）。
   *
   * 水平融合展开态与垂直两层两态共用（内容一致，2026-10-13 用户要求）；
   * 在隔离 Stack 里按 bodyVisible() 挂载/卸载，根节点挂 OPACITY transition ——
   * 收起/展开时与圆环进度交叉淡入淡出（CONTENT_FADE_MS），无瞬切。
   */
  @Builder
  Body(): void {
    Row({ space: CTRL_SPACING }) {
      // 歌名 / 歌手同规则：播放中超长文本跑马灯滚动（TextOverflow.Marquee），
      // 暂停 / 未播放回省略号截断（Ellipsis 静态显示开头）。
      Column() {
        Text(this.currentTrack !== null ? this.currentTrack.title : '')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: this.isPlaying ? TextOverflow.MARQUEE : TextOverflow.Ellipsis })
          .width('100%')
        Text(this.currentTrack !== null ? this.currentTrack.artist : '')
          .fontSize(10)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: this.isPlaying ? TextOverflow.MARQUEE : TextOverflow.Ellipsis })
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
    .transition(TransitionEffect.OPACITY.animation({ duration: CONTENT_FADE_MS, curve: Curve.EaseInOut }))
  }

  build() {
    // 边界：队列空 / 无在播曲目 → 不渲染（Index 侧同时会摘除 miniBar 槽位）
    if (this.queue.length > 0 && this.currentTrack !== null) {
      // Stack Bottom 叠加：主行（恒驻唱片 + 隔离的内容体）铺满，
      // 底边多出一条 2vp 直线进度（随 bodyVisible 淡入淡出，见下）。
      Stack({ alignContent: Alignment.Bottom }) {
        // 透明锚点（2026-10-21 起点偏左下根治）：播放页背景面 geometryTransition
        // 的迷你栏侧配对极。不渲染任何像素、只提供几何 —— 系统在配对插值时用
        // 它被 HDS 合成变换后的**真实视觉包围盒**做起点（跨窗口坐标换算由系统
        // 完成，唱片配对同机制已验证）。刻意做成兄弟替身而不是把本 Stack 整树
        // 拿去配对：唱片（GEOMETRY_ID_PLAYER_DISC）配对的起点在子树里，整树配对
        // 会让两套 geometryTransition 嵌套叠加。playerOpen 翻转（播放页侧
        // playEnterTransition / Index.closePlayer 的同一条 animateTo）驱动配对。
        if (!this.playerOpen) {
          Column()
            .width('100%')
            .height('100%')
            .hitTestBehavior(HitTestMode.None)
            // 起点圆角（2026-10-21 展开过程四角圆角）：geometryTransition 在绑定处
            // 同步圆角 —— 透明节点不渲染像素，borderRadius + clip 只向配对提供
            // 「胶囊同款圆角」的几何，展开/收起飞行途中背景面四角即呈 28vp 圆角。
            .borderRadius(PLAYER_SURFACE_RADIUS_START_VP)
            .clip(true)
            .geometryTransition(GEOMETRY_ID_PLAYER_SURFACE)
        }

        Row({ space: 8 }) {
          // 恒驻唱片槽位（2026-10-21 组件状态切换动画改版）：外包 Stack 定宽高
          // （discSizeVp）—— 播放页打开（playerOpen=true）时唱片摘除参与
          // geometryTransition 页内配对（飞向播放页大圆盘），槽位占位恒定，
          // Body 布局零跳动；收起时唱片随 Index.closePlayer 的 animateTo 回飞归位。
          Stack() {
            if (!this.playerOpen) {
              this.Disc()
            }
          }
          .width(this.discSizeVp)
          .height(this.discSizeVp)

          // 内容体隔离容器：Body 的挂载/卸载（出场节点不占布局）只影响这个
          // Stack 内部，恒驻唱片的布局位置不受任何影响。
          Stack() {
            if (this.bodyVisible()) {
              this.Body()
            }
          }
          .layoutWeight(1)
          .height('100%')
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 8, right: 8 })
        // 整条 miniBar 点击：收起态先展开、展开态进播放页（见 onEntryTap）
        .onClick((): void => {
          this.onEntryTap();
        })

        // 直线进度：贴槽位底边（= 胶囊底边的播放栏段），随 bodyVisible 淡入淡出。
        // 只铺播放栏槽位 —— HDS enableMiniBarClip 把 miniBar 内容裁在槽位内，
        // 延伸不到右侧页签段。底轨 = 淡主题色，进度 = 实主题色，左右内缩避开
        // 胶囊圆角；hitTest 透传：2vp 细条不截胡整行的「点击进播放页」。
        // duration<=0（加载中）不渲染；迷你栏进度条开关（miniBarProgress）
        // 关闭时同样不渲染。
        if (this.bodyVisible() && this.miniBarProgress && this.durationSec > 0) {
          Row() {
            Row()
              .width(`${(this.progressPct() * 100).toFixed(1)}%`)
              .height('100%')
              .backgroundColor(this.themePrimary)
          }
          .width('100%')
          .height(LINE_HEIGHT_VP)
          .padding({ left: LINE_INSET_VP, right: LINE_INSET_VP })
          .backgroundColor(MaterialCompat.withAlpha(this.themePrimary, LINE_TRACK_ALPHA))
          .hitTestBehavior(HitTestMode.Transparent)
          .transition(TransitionEffect.OPACITY.animation({ duration: CONTENT_FADE_MS, curve: Curve.EaseInOut }))
        }
      }
      .width('100%')
      .height('100%')
      // 按压反馈（原收起态专属，升级为两态通用）：整条按下轻微降透明度
      .stateStyles({
        pressed: { .opacity(0.85) },
        normal: { .opacity(1) }
      })
      // ⚠️ 这里**不要**挂 `onAreaChange`（曾用它实测槽位高来自适应圆盘尺寸）：
      // 在 HDS 托管的内容里由布局回调回写 @State，会让内容在 HDS 的形变动画中途重建，
      // 真机症状 = 垂直两层下展开迷你栏直接消失。圆盘尺寸改用常量（见 coverSize）。
    }
  }
}
