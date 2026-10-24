/**
 * 单曲列表项。网络封面直接由 Image 加载（需 INTERNET 权限）。
 * 通过函数属性 onPlay / moreMenuItems 把交互交回父页面。
 *
 * 标题双行显示（2026-10-21 用户要求）：maxLines(2) + 第二行省略号，长标题更完整；
 * 封面随之 56→64vp，配显式 lineHeight（标题 21 ×2 + 间距 4 + 副行 17 = 63 ≤ 64）
 * 硬保证「信息高度不超过封面高度」；短标题单行时行高不变（封面固定高驱动行高）。
 *
 * ⚠️ 条目内**不放播放图标**（曾有一个粉色的 `Text('▶')`）：
 * 整行本身就是 `onPlay` 的点击区，条目右侧再挂一个播放三角是重复入口，
 * 也和右侧「⋯」挤在一起。播放靠「点整行」，不要加回来。
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
import { STORE_THEME_DEEP, STORE_THEME_SURFACE } from '../common/Constants';
import {
  PRESS_SCALE,
  PRESS_ANIM_MS,
  ENTRANCE_OFFSET_VP,
  ENTRANCE_DURATION_MS,
  ENTRANCE_STAGGER_MS,
  ENTRANCE_DELAY_CAP_MS,
  ENTRANCE_WINDOW_MS
} from '../common/constants/InteractionConstants';

/** 「⋯」命中区边长，也是它占位的宽高（视觉仍是 20px 字号，靠居中留白撑开） */
const MORE_HIT: number = 44;

/**
 * 时长文本已收敛到 TextUtil.formatDurationText（2026-10-23 性能审查：
 * 4 份本地实现统一，消除 round/floor 边界漂移）。
 */

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
 * 2026-10-24 回归修复（用户复现「上滑后第 21 条已出现、前面还有没显示的」）：
 * 2026-10-14 的断层修复成立前提是「所有条目同一批挂载、同批错峰」（ForEach 时代）。
 * 2026-10-23 列表迁 LazyForEach + @Reusable 后前提被打破 —— 首屏错峰批次还在
 * 预隐藏排队（等待下标 × 35ms 延迟）时，滚动途中 **复用节点绕过 aboutToAppear
 * 整行直出**、**窗外懒建节点 0 延迟速入**，都先于上层排队条目亮起（下层先亮）。
 * 修法：错峰延迟不再烘焙进 animateTo 的 delay（已排程无法撤销），改为**定时器
 * 到点起播 + 排队登记**；任一条目以「窗外速入 / 复用直出」方式出现时立即
 * **冲刷队列**，排队条目全部转为立即入场 —— 无论用户何时开始滚动，
 * 条目亮起顺序都不会倒挂。
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
 * @Reusable（2026-10-23 性能审查）：列表页迁 LazyForEach 后启用节点复用 ——
 * 滚动时滑出的行进复用池、滑入的行直接换数据，省掉整棵子树销毁重建。
 * 复用安全性：所有外部数据经 @Prop 进来（复用时框架重赋值即刷新），
 * 入场动画只在 aboutToAppear 预置；复用节点绕过 aboutToAppear 整行直出
 * （错峰只播一次的语义由 aboutToReuse 复位保证，含排队中途回收的节点
 * 复用后不渲染成空白行），且直出时冲刷首屏错峰排队（2026-10-24 回归修复，
 * 见 TrackEntranceQueue 注释）；按压缩放是瞬时交互态、复用残留会被下一次触摸覆盖。
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
  onPlay: (track: Track) => void = (): void => {};
  /**
   * 「⋯」的标准菜单项（阶段 2 迁移，2026-10-11）：bindMenu 的 MenuElement 数组
   * 由父页面提供，点「⋯」弹出系统标准菜单。
   */
  moreMenuItems: (track: Track) => MenuElement[] = (_track: Track): MenuElement[] => [];

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
   * 入场错峰（可选）：父列表把它在 ForEach 里的**下标**传进来，条目统一
   * 「下移 10vp + 淡入」入场：首屏批次（窗内创建）按下标 × 35ms 的延迟
   * （封顶 ENTRANCE_DELAY_CAP_MS）依次错峰，窗外（滚动中懒加载）条目
   * 0 延迟速入。**没有直接显示的条目** —— 任何条目都入场动画，
   * 不存在动画条目与直出条目之间的可见断层。
   * 默认 -1 = 不启用（未传下标的页面行为完全不变）。
   */
  @Prop entranceIndex: number = -1;
  /**
   * 已下载徽标（2026-10-08）：true = 歌手行最右显示「已下载」小字
   * （2026-10-23 用户要求：从标题行右侧移到副行行尾）。
   * 默认 false —— 本组件被搜索 / 最近播放 / UP 主页 / 歌单详情四页共用，
   * 只有歌单详情（订阅了下载快照）会传 true，其余页面零改动零影响。
   * 与下载页「正在播放」徽标同一套视觉（11 号 brand_deep 小字），保持全局一致。
   */
  @Prop downloaded: boolean = false;
  /**
   * 「上次听到 x:xx」（可选，2026-10-12 位置记忆）：最近播放页传入的续播位置
   * 提示，空串整块不渲染。显示条件（≥ RESUME_MIN_SEC 且距结尾 ≥
   * RESUME_TAIL_SEC）由调用方判定，本组件只负责展示 ——
   * 搜索 / 歌单 / 下载 / UP 主页等共用页面不传该参，零改动零影响。
   */
  @Prop heardText: string = '';
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
      // 窗外速入条目先冲刷排队批次（2026-10-24 回归修复）：它自己 0 延迟起播，
      // 若不冲刷会先于上层仍在等待错峰延迟的排队条目亮起（下层先亮断层）。
      TrackEntranceQueue.flushPending();
    }
    this.enterOffsetY = ENTRANCE_OFFSET_VP;
    this.enterOpacity = 0;
  }

  /**
   * 复用直出（@Reusable，2026-10-24 回归修复补充）：复用节点绕过
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

  /**
   * 入场：挂载后一次性触发（entranceDone 防重播）。
   * 只动画 aboutToAppear 里**被预隐藏**的条目（enterOpacity === 0）——
   * 未预隐藏（未启用入场）的直接显示；这样任何被预隐藏的条目
   * 必然会被自己的 onAppear 动画回可见，不存在「卡在透明」的状态。
   * 延迟策略（2026-10-24 回归修复）：首屏批次 = 定时器延迟下标 × 35ms
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
      if (this.showCover) {
        // 64vp 显示位按 2x 请求图床缩略图（双行标题改版 2026-10-21：封面 56→64，
        // 高度预算 = 标题两行 lineHeight(21)×2 + 间距 4 + 副行 lineHeight(17) = 63 ≤ 64）；
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
          // 标题双行显示（2026-10-21 用户要求）：maxLines(2) + 第二行省略号，
          // 长标题更完整。
          Text(this.track.title)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
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
          // 「已下载」徽标（2026-10-08，2026-10-23 用户要求移到歌手行最右）：
          // 与下载页「正在播放」同款视觉，告诉用户这首已存到本地（播放走本地
          // 文件，不耗流量）。阶段 5（2026-10-11）：小字徽标统一改用系统标准 Chip。
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
      // 无障碍：图形字符读屏念不出来，必须补描述动作的文字
      Row() {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(20)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(MORE_HIT)
      .height(MORE_HIT)
      .justifyContent(FlexAlign.Center)
      .accessibilityText('更多操作')
      .accessibilityLevel('yes')
      .bindMenu(this.moreMenuItems(this.track))
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
