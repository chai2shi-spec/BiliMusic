/**
 * 单曲列表项。网络封面直接由 Image 加载（需 INTERNET 权限）。
 * 通过函数属性 onPlay / moreMenuItems 把交互交回父页面。
 *
 * 标题双行显示：maxLines(2) + 第二行省略号，长标题更完整；
 * 封面 64vp，配显式 lineHeight（标题 21 ×2 + 间距 4 + 副行 17 = 63 ≤ 64）
 * 硬保证「信息高度不超过封面高度」；短标题单行时行高不变（封面固定高驱动行高）。
 *
 * ⚠️ 条目内**不放播放图标**：整行本身就是 `onPlay` 的点击区，条目右侧再挂
 * 一个播放三角是重复入口，也和右侧「⋯」挤在一起。播放靠「点整行」，不要加。
 *
 * 第二行＝「歌手 + 发布时间 + 时长」：发布时间、时长依次排在歌手后（右侧对齐），
 * 歌手过长先省略，右侧元信息始终可见；发布时间无数据时整块不渲染。
 *
 * ⚠️ 触达尺寸（易用性审计结论）：
 * 整行是 `onPlay`，「⋯」挂 bindMenu 标准菜单（菜单项由父页面 moreMenuItems 提供），
 * 两个热区原本**紧贴**且「⋯」只有文字宽度
 * （约 20×28）→ 想点「⋯」会误触发播放。修法是保持「⋯」的**视觉**不变，
 * 但用 `width(44).height(44)` 把它的**命中区**撑到 44vp 最小标准，
 * 并在行内容与它之间留出 `MORE_HIT / 2` 的缓冲，两个热区不再相互覆盖。
 * 44vp 是手指可靠触达的下限（约 7mm），低于它就会频繁点错。
 *
 * 按压反馈＝纯缩放形变（0.9 / 150ms EaseOut，见 pressScale）：
 * 不改底色、不加蒙层、不引额外层级，动画状态本条目独占（详见 struct 内注释）。
 */

import { Chip, ChipSize } from '@kit.ArkUI';
import { Track, buildTrack } from '../model/MusicModels';
import { toThumbUrl, formatDurationText } from '../utils/TextUtil';
import { CoverImage } from './CoverImage';
import {
  STORE_CURRENT_TRACK,
  STORE_THEME_DEEP,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE
} from '../common/Constants';
import { MaterialCompat } from '../utils/MaterialCompat';
import {
  PRESS_SCALE,
  PRESS_ANIM_MS,
  ENTRANCE_OFFSET_VP,
  ENTRANCE_DURATION_MS,
  ENTRANCE_STAGGER_MS,
  ENTRANCE_DELAY_CAP_MS,
  ENTRANCE_WINDOW_MS,
  SELECT_SLOT_VP,
  SELECT_TOGGLE_MS
} from '../common/constants/InteractionConstants';

/** 「⋯」命中区边长，也是它占位的宽高（视觉仍是 20px 字号，靠居中留白撑开） */
const MORE_HIT: number = 44;

/** 「正在播放」整行高亮底色的透明度（淡主题色蒙层，10% 与淡主题强调档一致） */
const PLAYING_TINT_ALPHA: number = 0.10;

/**
 * 发布时间文本（unix 秒 → B 站式混合格式）。
 *
 * 返回**空串**表示「没有发布时间」而不显示占位：`!(seconds > 0)` 的写法把
 * undefined / NaN / 0 全挡掉（音乐中心条目、升级前的存量数据都没有这个字段）。
 * 规则：1 小时内「刚刚」、当天「x 小时前」、7 天内「x 天前」；
 * 更早：同年「10-01」、跨年「2025-10-01」。时钟漂移（未来时间）落绝对日期分支。
 */
function formatPubdate(seconds: number): string {
  if (!(seconds > 0)) {
    return '';
  }
  const now: number = Math.floor(Date.now() / 1000);
  const diff: number = now - seconds;
  if (diff >= 0 && diff < 3600) {
    return '刚刚';
  }
  if (diff >= 0 && diff < 86400) {
    return `${Math.floor(diff / 3600)} 小时前`;
  }
  if (diff >= 0 && diff < 7 * 86400) {
    return `${Math.floor(diff / 86400)} 天前`;
  }
  const d: Date = new Date(seconds * 1000);
  const nowDate: Date = new Date();
  const month: number = d.getMonth() + 1;
  const day: number = d.getDate();
  const mm: string = month < 10 ? `0${month}` : `${month}`;
  const dd: string = day < 10 ? `0${day}` : `${day}`;
  if (d.getFullYear() === nowDate.getFullYear()) {
    return `${mm}-${dd}`;
  }
  return `${d.getFullYear()}-${mm}-${dd}`;
}

/**
 * 入场时间窗 + 排队登记（模块级共享）：列表首条（entranceIndex === 0）挂载时
 * 开窗，窗内创建的条目才算「首屏批次」参与错峰；窗外创建（滚动中 LazyForEach
 * 懒加载）的条目 0 延迟速入 —— 同样入场动画，只是不排队，拖动跟手。
 *
 * ⚠️ 错峰延迟不烘焙进 animateTo 的 delay（已排程无法撤销），改为**定时器
 * 到点起播 + 排队登记**：LazyForEach + @Reusable 下，滚动途中**复用节点绕过
 * aboutToAppear 整行直出**、**窗外懒建节点 0 延迟速入**，都先于仍在等待
 * 下标 × 35ms 延迟的上层排队条目亮起（下层先亮断层）—— 任一条目以
 * 「窗外速入 / 复用直出」方式出现时立即**冲刷队列**，排队条目全部转为
 * 立即入场，无论用户何时开始滚动，条目亮起顺序都不会倒挂。
 */
class TrackEntranceQueue {
  /** 开窗时刻（Date.now()）；0 = 从未开窗，按首屏批次对待（不依赖创建顺序） */
  static openedAt: number = 0;
  /** 已冲刷：true 后起播的排队条目一律 0 延迟（断层既已出现，排队不再有意义） */
  static flushed: boolean = false;
  /** 排队条目的「立即入场」回调登记（冲刷时全部立即执行） */
  static pending: Array<() => void> = [];

  /** 冲刷：排队中的条目全部立即入场（各自回调内部回收定时器与登记项） */
  static flushPending(): void {
    const cbs: Array<() => void> = TrackEntranceQueue.pending;
    TrackEntranceQueue.pending = [];
    TrackEntranceQueue.flushed = true;
    for (let i = 0; i < cbs.length; i++) {
      cbs[i]();
    }
  }

  static removePending(starter: () => void): void {
    const idx: number = TrackEntranceQueue.pending.indexOf(starter);
    if (idx >= 0) {
      TrackEntranceQueue.pending.splice(idx, 1);
    }
  }
}

/**
 * @Reusable：列表页 LazyForEach 启用节点复用 —— 滚动时滑出的行进复用池、
 * 滑入的行直接换数据，省掉整棵子树销毁重建。
 * 复用安全性：所有外部数据经 @Prop 进来（复用时框架重赋值即刷新），
 * 入场动画只在 aboutToAppear 预置；复用节点绕过 aboutToAppear 整行直出
 * （错峰只播一次的语义由 aboutToReuse 复位保证，含排队中途回收的节点
 * 复用后不渲染成空白行），且直出时冲刷首屏错峰排队
 * （见 TrackEntranceQueue 注释）；按压缩放是瞬时交互态、复用残留会被下一次触摸覆盖。
 */
@Reusable
@Component
export struct TrackItem {
  @Prop track: Track = buildTrack({});
  @Prop showCover: boolean = true;
  @Prop showIndex: number = -1;
  /** 主题色运行时值：「正在播放」徽标的浅底与深字跟随切色刷新 */
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  /** 当前播放曲目（AppStorage 订阅）：正在播放的条目整行高亮 + 标题主题色，切歌自动跟随 */
  @StorageProp(STORE_CURRENT_TRACK) currentTrack: Track | null = null;
  /** 主题色运行时值：正在播放条目的高亮底色与标题颜色跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  onPlay: (track: Track) => void = (): void => {};
  /**
   * 「⋯」的标准菜单项：bindMenu 的 MenuElement 数组由父页面提供，
   * 点「⋯」弹出系统标准菜单。
   */
  moreMenuItems: (track: Track) => MenuElement[] = (_track: Track): MenuElement[] => [];

  /**
   * 按压缩放（独立动画状态，本条目独占）：按下 0.9，抬起/取消回 1.0。
   *
    * 设计约束：
    * - **只做形变**：不碰 backgroundColor、不加按压蒙层/底色/高亮
    *   （press_overlay 资源本身其他页面仍在用，保留）。
   * - **独立隔离**：专用 @State + 紧跟 .scale() 的独立 .animation()，
   *   不与任何其他组件的动画状态（HdsTabs、miniBar 唱片旋转、播放按钮形变、
   *   搜索框动画）共用变量，互不干扰。
   * - **零额外层级**：scale 直接挂在根 Row 上，不引入包装容器，保持原布局。
   * - 属性动画无循环无定时器，组件销毁无需清理（无内存泄漏风险）。
   */
  @State pressScale: number = 1;

  /**
   * 入场错峰（可选）：父列表把它在 ForEach 里的**下标**传进来，条目统一
   * 「下移 10vp + 淡入」入场：首屏批次（窗内创建）按下标 × 35ms 的延迟
   * （封顶 ENTRANCE_DELAY_CAP_MS）依次错峰，窗外（滚动中懒加载）条目
   * 0 延迟速入。**没有直接显示的条目** —— 任何条目都入场动画，
   * 不存在动画条目与直出条目之间的可见断层。
   * 默认 -1 = 不启用（未传下标的页面行为完全不变）。
   */
  @Prop entranceIndex: number = -1;
  /**
   * 已下载徽标：true = 副行行尾显示「已下载」小字。
   * 默认 false —— 本组件被搜索 / 最近播放 / UP 主页 / 歌单详情四页共用，
   * 只有歌单详情（订阅了下载快照）会传 true，其余页面零改动零影响。
   * 与下载页「正在播放」徽标同一套视觉（11 号 brand_deep 小字），保持全局一致。
   */
  @Prop downloaded: boolean = false;
  /**
   * 「上次听到 x:xx」（可选，位置记忆）：最近播放页传入的续播位置
   * 提示，空串整块不渲染。显示条件（≥ RESUME_MIN_SEC 且距结尾 ≥
   * RESUME_TAIL_SEC）由调用方判定，本组件只负责展示 ——
   * 搜索 / 歌单 / 下载 / UP 主页等共用页面不传该参，零改动零影响。
   */
  @Prop heardText: string = '';
  /**
   * 多选模式开关（可选）：true = 点条目切换选中而非播放、隐藏「⋯」、
   * 左侧勾选槽位展开。默认 false —— 共用页面（搜索 / 最近播放）
   * 不传时槽位宽 0 且路由不变，布局与交互零改动零影响。
   */
  @Prop selecting: boolean = false;
  /** 本条目是否选中：父页面 selectedIds 驱动，勾选框只读回显（装饰性） */
  @Prop selected: boolean = false;
  /** 选择模式下点条目 / 点勾选槽位的切换回调 */
  onToggleSelect: (track: Track) => void = (_track: Track): void => {};
  /** 入场位移（vp）：10 → 0；所有参与入场的条目在挂载时被置为起始值 */
  @State enterOffsetY: number = 0;
  /** 入场透明度：0 → 1 */
  @State enterOpacity: number = 1;
  /** 错峰只播一次：@Prop 下标变化（增删条目导致索引位移）不重播 */
  private entranceDone: boolean = false;
  /** 是否属于首屏批次（窗内创建）：true = 按下标错峰；false = 窗外懒建，0 延迟速入 */
  private entranceInWindow: boolean = false;

  /** 错峰排队定时器句柄：到点起播；冲刷 / 复用 / 销毁时回收 */
  private entranceTimer: number = -1;
  /** 本条目在排队登记表里的起播回调（销毁 / 起播后注销，防冲刷打到已卸载条目） */
  private entranceStarter: (() => void) | null = null;

  aboutToAppear(): void {
    if (this.entranceIndex < 0) {
      return;
    }
    // 列表首条（重新）开窗：每个列表挂载 / 数据刷新时首条最先创建
    if (this.entranceIndex === 0) {
      TrackEntranceQueue.openedAt = Date.now();
      TrackEntranceQueue.flushed = false;
    }
    // 窗内＝首屏批次（错峰排队）；窗外＝滚动中懒加载（0 延迟速入，跟手）。
    // 两者都预隐藏入场 —— 不存在直接显示的条目，也就没有断层。
    this.entranceInWindow = TrackEntranceQueue.openedAt !== 0 &&
      Date.now() - TrackEntranceQueue.openedAt <= ENTRANCE_WINDOW_MS;
    if (!this.entranceInWindow) {
      // 窗外速入条目先冲刷排队批次：它自己 0 延迟起播，
      // 若不冲刷会先于上层仍在等待错峰延迟的排队条目亮起（下层先亮断层）。
      TrackEntranceQueue.flushPending();
    }
    this.enterOffsetY = ENTRANCE_OFFSET_VP;
    this.enterOpacity = 0;
  }

  /**
   * 复用直出（@Reusable）：复用节点绕过
   * aboutToAppear / onAppear 直接整行可见 —— 若首屏错峰批次还在排队，
   * 本条会先于上层排队条目亮起，必须立即冲刷；同时把入场状态复位为
   * 「已入场」：排队中途被回收进池的节点 enterOpacity 还停在 0
   * （定时器未到点），不复位会在复用后渲染成空白行。
   */
  aboutToReuse(params: Record<string, Object>): void {
    if (this.entranceTimer >= 0) {
      clearTimeout(this.entranceTimer);
      this.entranceTimer = -1;
    }
    if (this.entranceStarter !== null) {
      TrackEntranceQueue.removePending(this.entranceStarter);
      this.entranceStarter = null;
    }
    TrackEntranceQueue.flushPending();
    this.entranceDone = true;
    this.enterOffsetY = 0;
    this.enterOpacity = 1;
  }

  aboutToDisappear(): void {
    if (this.entranceTimer >= 0) {
      clearTimeout(this.entranceTimer);
      this.entranceTimer = -1;
    }
    if (this.entranceStarter !== null) {
      TrackEntranceQueue.removePending(this.entranceStarter);
      this.entranceStarter = null;
    }
  }

  /** 本条目要显示的时长文本；返回空串＝该条目没有时长信息，整块不渲染 */
  private durationText(): string {
    return formatDurationText(this.track.duration);
  }

  /** 本条目要显示的发布时间文本；返回空串＝该条目没有发布时间，整块不渲染 */
  private pubdateText(): string {
    return formatPubdate(this.track.pubdate);
  }

  /** 本条目是否正在播放：id 精确匹配（QueueSheet / DownloadsPage 同一语义，多 P 条目 id 唯一） */
  private isPlayingTrack(): boolean {
    const cur: Track | null = this.currentTrack;
    return cur !== null && cur.id === this.track.id;
  }

  /** 行背景：正在播放 = 淡主题色高亮；否则透明 */
  private rowBackground(): ResourceColor {
    return this.isPlayingTrack()
      ? MaterialCompat.withAlpha(this.themePrimary, PLAYING_TINT_ALPHA)
      : Color.Transparent;
  }

  /**
   * 入场：挂载后一次性触发（entranceDone 防重播）。
   * 只动画 aboutToAppear 里**被预隐藏**的条目（enterOpacity === 0）——
   * 未预隐藏（未启用入场）的直接显示；这样任何被预隐藏的条目
   * 必然会被自己的 onAppear 动画回可见，不存在「卡在透明」的状态。
   * 延迟策略：首屏批次 = 定时器延迟下标 × 35ms
   * （封顶 ENTRANCE_DELAY_CAP_MS）到点起播 —— **不烘焙进 animateTo 的
   * delay**，那样一旦排程就无法在复用 / 窗外条目出现时撤销；同时登记
   * 立即起播回调，队列被冲刷时提前起播。窗外懒建 / 已冲刷 = 0 延迟速入。
   * 单条动画 normal(250ms) EaseOut。
   */
  private playEntrance(): void {
    if (this.entranceDone) {
      return;
    }
    if (this.entranceIndex < 0) {
      return;
    }
    this.entranceDone = true;
    if (this.enterOpacity === 1) {
      return;
    }
    const delay: number = this.entranceInWindow && !TrackEntranceQueue.flushed
      ? Math.min(this.entranceIndex * ENTRANCE_STAGGER_MS, ENTRANCE_DELAY_CAP_MS)
      : 0;
    if (delay <= 0) {
      this.startEntranceNow();
      return;
    }
    // 排队：定时器到点起播；登记回调，任一窗外速入 / 复用直出条目
    // 出现时冲 flushPending 提前起播（见 TrackEntranceQueue 注释）。
    const starter: () => void = (): void => {
      this.startEntranceNow();
    };
    this.entranceStarter = starter;
    TrackEntranceQueue.pending.push(starter);
    this.entranceTimer = setTimeout((): void => {
      TrackEntranceQueue.removePending(starter);
      this.startEntranceNow();
    }, delay);
  }

  /** 立即入场（250ms 淡入落位）：排队到点 / 冲刷 / 速入共用同一动画 */
  private startEntranceNow(): void {
    if (this.entranceTimer >= 0) {
      clearTimeout(this.entranceTimer);
      this.entranceTimer = -1;
    }
    this.entranceStarter = null;
    this.getUIContext().animateTo({
      duration: ENTRANCE_DURATION_MS,
      curve: Curve.EaseOut
    }, (): void => {
      this.enterOffsetY = 0;
      this.enterOpacity = 1;
    });
  }

  build() {
    Row() {
      // 多选勾选槽位（可选）：宽 0 ↔ SELECT_SLOT_VP + clip 收展 —— 绝不能用
      // if 条件挂载（节点增删没有过渡，还会顶动布局）；勾选框叠 translate
      // 从右侧滑入，clip 保证槽位收拢时内容不外溢（下载页任务行同款）。
      // 勾选框只读回显 selected、装饰性（hitTestBehavior None）：切换入口是
      // 整行点击（selecting 态 onClick 路由到 onToggleSelect）。
      // name 用 track.id 保证组内唯一，group 'upSelect' 与父页面多选组一致。
      Row() {
        Checkbox({ name: this.track.id, group: 'upSelect' })
          .select(this.selected)
          .selectedColor(this.themeDeep)
          .unselectedColor($r('app.color.text_disabled'))
          .shape(CheckBoxShape.CIRCLE)
          .width(20)
          .height(20)
          .translate({ x: this.selecting ? 0 : SELECT_SLOT_VP })
          .animation({ duration: SELECT_TOGGLE_MS, curve: Curve.EaseOut })
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no')
      }
      .width(this.selecting ? SELECT_SLOT_VP : 0)
      .height(20)
      .clip(true)
      .justifyContent(FlexAlign.Center)
      .animation({ duration: SELECT_TOGGLE_MS, curve: Curve.EaseOut })

      if (this.showCover) {
        // 64vp 显示位按 2x 请求图床缩略图
        // （高度预算 = 标题两行 lineHeight(21)×2 + 间距 4 + 副行 lineHeight(17) = 63 ≤ 64）；
        // 加载中 / 失败由 CoverImage 兜浅粉占位
        // altText 让读屏把这行念成「歌名」，而不是跳过封面或念一串 URL
        CoverImage({
          url: toThumbUrl(this.track.coverUrl, 128),
          imgWidth: 64,
          imgHeight: 64,
          imgRadius: 8,
          altText: this.track.title
        })
      }

      Column() {
        // 标题行：标题用 layoutWeight(1) 吃满剩余宽度。
        // 显式 lineHeight(21) 锁行高（默认行高随字体浮动，会破坏
        // 「信息高度 ≤ 封面高度」的硬预算，见封面注释）。
        Row() {
          // 标题双行显示：maxLines(2) + 第二行省略号，长标题更完整。
          // 正在播放的条目标题用主题色（配合整行高亮底，一眼定位当前曲）。
          Text(this.track.title)
            .fontSize(16)
            .fontColor(this.isPlayingTrack() ? this.themePrimary : $r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(21)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        Row() {
          // 副行行高锁 17（13sp）：与标题 lineHeight(21) 一起构成高度预算
          //（2×21 + 4 + 17 = 63 ≤ 封面 64），见封面注释。
          Text(this.track.artist)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(17)
            .layoutWeight(1)
          // 「上次听到 x:xx」跟在歌手后（最近播放页续播提示，
          // 其余页面不传 heardText，空串整块不渲染，布局与原先完全一致）。
          if (this.heardText.length > 0) {
            Text(this.heardText)
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .margin({ left: 8 })
          }
          // 发布时间跟在歌手后、时长前（右侧元信息）。无数据（音乐中心、
          // 升级前存量）返回空串整块不渲染，布局与原先完全一致。
          if (this.pubdateText().length > 0) {
            Text(this.pubdateText())
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .margin({ left: 8 })
          }
          // 时长跟在发布时间后面。歌手用 layoutWeight(1) 吃掉剩余宽度，
          // 于是发布时间、时长被推向行尾（歌手过长时先省略歌手，元信息不被挤掉）。
          if (this.durationText().length > 0) {
            Text(this.durationText())
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .margin({ left: 8 })
          }
          // 「已下载」徽标：与下载页「正在播放」同款视觉（系统标准 Chip），告诉
          // 用户这首已存到本地（播放走本地文件，不耗流量）。
          // ⚠️ Chip 是 @Builder 组件，**不能链式挂属性** → 外边距 / 命中策略挂在外层 Row。
          // 装饰徽标：不参与命中测试，点它等同点整行（播放）。
          if (this.downloaded) {
            Row() {
              Chip({
                label: {
                  text: '已下载',
                  fontSize: 11,
                  fontColor: this.themeDeep
                },
                size: ChipSize.SMALL,
                allowClose: false,
                backgroundColor: this.themeSurface
              })
            }
            .margin({ left: 8 })
            .hitTestBehavior(HitTestMode.None)
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
      // 多选模式下隐藏（Visibility.None 不占布局）：更多入口让位给选择交互，
      // 防误弹菜单。
      // 无障碍：图形字符读屏念不出来，必须补描述动作的文字
      Row() {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(20)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(MORE_HIT)
      .height(MORE_HIT)
      .justifyContent(FlexAlign.Center)
      .visibility(this.selecting ? Visibility.None : Visibility.Visible)
      .accessibilityText('更多操作')
      .accessibilityLevel('yes')
      .bindMenu(this.moreMenuItems(this.track))
    }
    .width('100%')
    .padding({ left: 16, right: 4, top: 10, bottom: 10 })
    // 「正在播放」整行高亮：淡主题色底 + 12 圆角（与卡片圆角同档）。
    // 声明在 .animation() 之前 → 切歌时高亮随 150ms EaseOut 淡出/淡入
    //（隐式动画接管，无需额外代码）。
    .backgroundColor(this.rowBackground())
    .borderRadius(12)
    // 按压态：整行可点但原先**零反馈**，用户点下去不知道是否命中。
    // 反馈方式＝纯缩放形变（见 pressScale 注释）：按下收到 0.9 的收缩确认，
    // 抬起/取消回弹到 1.0 —— 按压不改底色、不加蒙层（高亮底是「正在播放」
    // 状态色，与按压反馈互不掺和），scale 直接挂根 Row 不加层。
    // .animation() 紧跟 .scale() 且位于链尾：接管 scale（按压）与在它之前
    // 声明的 backgroundColor（高亮切换）两个可变属性 —— 两者都走 150ms
    // EaseOut 是有意为之；width/padding 在其之前但从不变化，不会被卷进动画。
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
      // 多选态：整行是「切换选中」的命中区而非播放（与「⋯」隐藏配套）
      if (this.selecting) {
        this.onToggleSelect(this.track);
        return;
      }
      this.onPlay(this.track);
    })
  }
}
