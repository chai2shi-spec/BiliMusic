/**
 * 拾音·收听流水页（循环榜「全部 ›」进入）。
 *
 * 本机全部播放会话的按日流水（最近在前）：日头吸顶 + 会话行（时刻 / 歌名 /
 * 时长 / 听完|切走）。只读展示，行不可点（本轮不做流水行起播，防扩散）。
 *
 * 数据链：aboutToAppear 全量 querySessions（13 个月保留窗，内存月分片
 * 缓存通常已就绪）→ 倒序 → 按自然日分组；分批揭示（初始 14 天，滚动到底
 * +14，RecentPage 揭示模式），避免一次建完全部行。
 *
 * 页面骨架仿 DiaryNewFacesPage（子页标准样板）：HDS 沉浸光感标题栏 +
 * 自绘顶栏渐变模糊层 + 400ms 右滑入转场 + 系统返回拦截；无路由参数。
 */

import {
  CONTENT_END_OFFSET,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP
} from '../common/Constants';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { BarNarrowShell } from '../components/BarNarrowShell';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { MaterialTokens } from '../common/style/MaterialTokens';
import { querySessions, PlaySession } from '../service/PlaySessionStore';

/** 单日分组（会话按 startedAt 归入自然日，倒序揭示的最小单位） */
interface TimelineDayGroup {
  dayStartMs: number;
  sessions: PlaySession[];
}

/** 初始揭示天数（最近 14 个非空日；滚动到底每次 +14） */
const DAYS_PER_REVEAL: number = 14;

/** 星期短名（getDay() 0 = 周日） */
const WEEKDAY_NAMES: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

@Component
export struct DiaryTimelinePage {
  /** 状态栏高度（vp）：HDS 标题栏 avoidLayoutSafeArea 后的占位让位量 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：列表末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 子页转场横移量（相对页面自身宽度） */
  @State navTransX: string = '0%';
  /** 会话加载完成标记（false = 加载中，不渲染列表主体） */
  @State loaded: boolean = false;
  /** 按日分组（最近在前；空数组 = 保留窗内无会话） */
  @State groups: TimelineDayGroup[] = [];
  /** 已揭示天数（初始 DAYS_PER_REVEAL，onReachEnd 递增） */
  @State revealedDays: number = 0;
  /** 列表滚动控制器：滚动模糊与 HDS bindToScrollable 共用 */
  private listScroller: Scroller = new Scroller();
  /** 自绘顶栏渐变模糊层进度更新器（子页标准样板同款命令式驱动） */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.listScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  aboutToAppear(): void {
    this.loadSessions();
    this.syncTopBlurProgress();
  }

  /** 全量会话读回 → 倒序 → 按自然日分组（首条会话变更即开新组） */
  private async loadSessions(): Promise<void> {
    const sessions: PlaySession[] = await querySessions(0, Date.now());
    const desc: PlaySession[] = sessions.slice().reverse();
    const groups: TimelineDayGroup[] = [];
    let currentDay: number = -1;
    for (let i = 0; i < desc.length; i++) {
      const s: PlaySession = desc[i];
      const d: Date = new Date(s.startedAt);
      d.setHours(0, 0, 0, 0);
      const dayMs: number = d.getTime();
      if (dayMs !== currentDay) {
        groups.push({ dayStartMs: dayMs, sessions: [] });
        currentDay = dayMs;
      }
      groups[groups.length - 1].sessions.push(s);
    }
    this.groups = groups;
    this.revealedDays = Math.min(DAYS_PER_REVEAL, groups.length);
    this.loaded = true;
  }

  /** 已揭示的日组切片（revealedDays 递增驱动 ForEach 重渲染） */
  private visibleGroups(): TimelineDayGroup[] {
    return this.groups.slice(0, this.revealedDays);
  }

  /** 滚动到底继续揭示（+DAYS_PER_REVEAL，封顶全量；已到顶幂等） */
  private revealMore(): void {
    if (this.revealedDays < this.groups.length) {
      this.revealedDays = Math.min(this.revealedDays + DAYS_PER_REVEAL, this.groups.length);
    }
  }

  /** 日头文案：`10月25日 周六`（当年省年，跨年补 `2025年` 前缀） */
  private dayLabel(dayStartMs: number): string {
    const d: Date = new Date(dayStartMs);
    const base: string = `${d.getMonth() + 1}月${d.getDate()}日 ${WEEKDAY_NAMES[d.getDay()]}`;
    return d.getFullYear() === new Date().getFullYear() ? base : `${d.getFullYear()}年${base}`;
  }

  /** 会话开始时刻 `HH:mm`（不足两位补零） */
  private timeText(ms: number): string {
    const d: Date = new Date(ms);
    const h: number = d.getHours();
    const m: number = d.getMinutes();
    const hText: string = h < 10 ? `0${h}` : `${h}`;
    const mText: string = m < 10 ? `0${m}` : `${m}`;
    return `${hText}:${mText}`;
  }

  /** 会话收听时长 `m:ss`（秒补零；不含暂停空白，PlaySessionStore 口径） */
  private durationText(ms: number): string {
    const totalSec: number = Math.floor(ms / 1000);
    const min: number = Math.floor(totalSec / 60);
    const sec: number = totalSec % 60;
    const secText: string = sec < 10 ? `0${sec}` : `${sec}`;
    return `${min}:${secText}`;
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut。
   */
  private navTransitionDelegate(op: NavigationOperation,
    isEnter: boolean): Array<NavDestinationTransition> | undefined {
    if (op === NavigationOperation.PUSH && isEnter) {
      this.navTransX = '100%';
      const enter: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '0%';
        }
      };
      const transitions: Array<NavDestinationTransition> = [enter];
      return transitions;
    }
    if (op === NavigationOperation.POP && !isEnter) {
      const exit: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '100%';
        }
      };
      const transitions: Array<NavDestinationTransition> = [exit];
      return transitions;
    }
    return undefined;
  }

  /** 标题栏内容 */
  @Builder
  pageBar() {
    NavTitleRow({ title: '收听流水' })
  }

  /** 标题行收窄容器（BarNarrowShell 共用件，平板模式宽度适配） */
  @Builder
  pageBarNarrow() {
    BarNarrowShell({ bar: (): void => {
      this.pageBar()
    } })
  }

  /** 日头行（sticky 吸顶）：日期 + 星期（13/secondary） */
  @Builder
  dayHeader(g: TimelineDayGroup) {
    Text(this.dayLabel(g.dayStartMs))
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .height(32)
      .padding({ left: 4 })
      .maxLines(1)
  }

  /** 会话行（高 56，不可点）：时刻 / 歌名 / 时长 + 听完|切走 */
  @Builder
  sessionRow(s: PlaySession) {
    Row() {
      Text(this.timeText(s.startedAt))
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
        .width(44)

      Text(s.title)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 12 })

      Text(this.durationText(s.ms))
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .margin({ left: 12 })

      Text(s.completed ? '听完' : '切走')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ left: 6 })
    }
    .width('100%')
    .height(56)
    .alignItems(VerticalAlign.Center)
    .accessibilityText(
      `${this.timeText(s.startedAt)}，${s.title}，${this.durationText(s.ms)}，${s.completed ? '听完' : '切走'}`)
    .accessibilityLevel('yes')
  }

  build() {
    HdsNavDestination() {
      Stack() {
        if (!this.loaded) {
          // 加载中：只渲染让位占位，不闪列表主体（月分片缓存命中时毫秒级过渡）
          Column() {
            Row()
              .width('100%')
              .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)
          }
          .width('100%')
          .height('100%')
        } else if (this.groups.length === 0) {
          Column() {
            Row()
              .width('100%')
              .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)
            Text('这段时间还没有听歌记录')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 48 })
          }
          .width('100%')
          .height('100%')
        } else {
          List({ scroller: this.listScroller }) {
            // 顶部空白占位条目（RecentPage 同款）：列表视口铺满全屏，
            // 首个日头从标题栏材质下方起排，滚动时内容从沉浸材质下穿过
            ListItem() {
              Row()
                .width('100%')
                .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)
            }

            ForEach(this.visibleGroups(), (g: TimelineDayGroup): void => {
              ListItemGroup({ header: this.dayHeader(g) }) {
                ForEach(g.sessions, (s: PlaySession): void => {
                  ListItem() {
                    this.sessionRow(s)
                  }
                }, (s: PlaySession): string => `${s.trackId}_${s.startedAt}_${s.ms}`)
              }
            }, (g: TimelineDayGroup): string => `d${g.dayStartMs}_${g.sessions.length}`)
          }
          .width('100%')
          .height('100%')
          .padding({ left: 16, right: 16 })
          .edgeEffect(EdgeEffect.Spring)
          .sticky(StickyStyle.Header)
          .cachedCount(8)
          // 列表末端让位：悬浮播放条 + 手势区（与其他子页同口径）
          .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
          .onReachEnd((): void => {
            this.revealMore();
          })
          .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
            this.syncTopBlurProgress();
          })
          .onScrollStop((): void => {
            this.syncTopBlurProgress();
          })
          // 大屏适配：内容列收窄居中
          .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      // 顶栏渐变模糊层：盖内容之上（z 序低于 HDS titleBar）
      TopGradientBlurOverlay({
        barHeightVp: this.safeTop + NAV_TITLE_BAR_HEIGHT,
        updater: this.topBlurUpdater
      })
    }
    // HDS 沉浸光感标题栏：材质 / 滚动模糊 / 温控统一由 HdsTitleBarStyle 决策
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        stackBuilder: (): void => {
          this.pageBarNarrow();
        }
      }
    })
    // 滚动模糊依赖 scroller 绑定：把本页列表交给 HDS 联动
    .bindToScrollable([this.listScroller])
    // 子页转场：横移量由转场代理驱动
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让（官方组件级沉浸口径）
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function DiaryTimelinePageBuilder(): void {
  DiaryTimelinePage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接 @Builder 引用（编译期校验）。 */
export const DiaryTimelinePageWrapped: WrappedBuilder<[]> = wrapBuilder(DiaryTimelinePageBuilder);
