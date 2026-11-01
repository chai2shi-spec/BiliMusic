/**
 * 听歌日记·新面孔清单页（听歌日记页「本周新面孔」卡进入）。
 *
 * 纯展示页：路由参数带听歌日记页已派生好的报告快照（标题 + 副标题 +
 * 新面孔列表），本页不重算统计 —— 重算需全量会话扫描（querySessions），
 * 为一张静态清单重复扫一遍不划算。行点击进 UP 主主页（upMid 空 =
 * 本地/无 UP 信息来源，行不响应）。
 *
 * 页面骨架仿 ListenDiaryPage（子页标准样板）：HDS 沉浸光感标题栏 +
 * 自绘顶栏渐变模糊层 + 400ms 右滑入转场 + 系统返回拦截。
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
import { CoverImage } from '../components/CoverImage';
import { NavStackHolder } from '../service/NavStackHolder';
import { UpSpaceRouteParam, DiaryNewFacesRouteParam, NavRouteParamReader } from '../service/NavRouteParams';
import {
  DiaryTopUp,
  DiaryKpiCell,
  formatDiaryDuration
} from '../service/ListenDiaryStats';

@Component
export struct DiaryNewFacesPage {
  /** 状态栏高度（vp）：HDS 标题栏 avoidLayoutSafeArea 后的占位让位量 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：内容末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 子页转场横移量（相对页面自身宽度） */
  @State navTransX: string = '0%';
  /** 页面标题（本周新面孔 / 今日新面孔 …，随周期与往期前缀变化） */
  @State pageTitle: string = '新面孔';
  /** 副标题（N 位 UP 主 · 第一次出现在你的列表） */
  @State pageSubtitle: string = '';
  /** 新面孔清单（时长降序；aboutToAppear 从路由参数定格） */
  @State faces: DiaryTopUp[] = [];
  /** 内容滚动控制器：滚动模糊与 HDS bindToScrollable 共用 */
  private pageScroller: Scroller = new Scroller();
  /** 自绘顶栏渐变模糊层进度更新器（子页标准样板同款命令式驱动） */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.pageScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  aboutToAppear(): void {
    const routeParam: DiaryNewFacesRouteParam | null =
      NavRouteParamReader.readDiaryNewFacesParam(NavStackHolder.stack);
    if (routeParam !== null) {
      this.pageTitle = routeParam.title;
      this.pageSubtitle = routeParam.subtitle;
      this.faces = routeParam.faces;
    }
    this.syncTopBlurProgress();
  }

  /** 收听时长文案（3.2 小时 / 45 分钟） */
  private durationText(u: DiaryTopUp): string {
    const cell: DiaryKpiCell = formatDiaryDuration(u.totalMs);
    return `${cell.value} ${cell.unit}`;
  }

  /** 行副文案：听了 N 次 · 时长 */
  private faceSubText(u: DiaryTopUp): string {
    return `听了 ${u.plays} 次 · ${this.durationText(u)}`;
  }

  /** 行点击 → UP 主主页（upMid 空 = 本地/无 UP 信息来源，不响应） */
  private openUpSpace(u: DiaryTopUp): void {
    if (u.upMid.length === 0) {
      return;
    }
    NavStackHolder.push('UpSpace', new UpSpaceRouteParam(u.upMid, u.name, u.avatarUrl));
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

  /** 标题栏内容：动态标题（随周期前缀变化） */
  @Builder
  pageBar() {
    NavTitleRow({ title: this.pageTitle })
  }

  /** 标题行收窄容器（BarNarrowShell 共用件，平板模式宽度适配） */
  @Builder
  pageBarNarrow() {
    BarNarrowShell({ bar: (): void => {
      this.pageBar()
    } })
  }

  /** 单个新面孔行（头像 + 名字 + 次数时长 + 进主页箭头） */
  @Builder
  faceRow(u: DiaryTopUp) {
    Row() {
      CoverImage({
        url: u.avatarUrl,
        imgWidth: 44,
        imgHeight: 44,
        imgRadius: 22,
        altText: u.name
      })

      Column() {
        Text(u.name)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.faceSubText(u))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .margin({ left: 12 })
      .alignItems(HorizontalAlign.Start)

      if (u.upMid.length > 0) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([$r('app.color.text_tertiary')])
          .margin({ left: 8 })
      }
    }
    .width('100%')
    .height(60)
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .borderRadius(8)
    .accessibilityText(`${u.name}，${this.faceSubText(u)}`)
    .accessibilityLevel('yes')
    .onClick((): void => {
      this.openUpSpace(u);
    })
  }

  /** 内容主体 */
  @Builder
  mainContent() {
    Column() {
      if (this.pageSubtitle.length > 0) {
        Text(this.pageSubtitle)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: 4, bottom: 8 })
      }

      if (this.faces.length === 0) {
        Text('本期没有新面孔')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 48 })
      } else {
        ForEach(this.faces, (u: DiaryTopUp, idx: number): void => {
          Column() {
            this.faceRow(u)
            // 行间分隔线从 56px 处起画（不贯穿头像列，循环榜同款）
            if (idx < this.faces.length - 1) {
              Row() {
                Row()
                  .width(56)
                Divider()
                  .color($r('app.color.bg_divider'))
                  .layoutWeight(1)
              }
              .width('100%')
            }
          }
          .width('100%')
        }, (u: DiaryTopUp): string => `${u.key}_${u.plays}_${u.totalMs}`)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Scroll(this.pageScroller) {
          Column() {
            // 顶部占位：沉浸口径下内容从标题栏材质下方穿过
            Row()
              .width('100%')
              .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)

            this.mainContent()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          // Scroll 无 contentEndOffset（List 专属），底部避让用内层 padding：
          // 二级页悬浮播放条 + 手势区（与其他子页同口径）
          .padding({ left: 16, right: 16, bottom: CONTENT_END_OFFSET + this.safeBottom })
        }
        .width('100%')
        .height('100%')
        .edgeEffect(EdgeEffect.Spring)
        // 大屏适配：内容列收窄居中
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
        .onDidScroll((xOffset: number, yOffset: number): void => {
          this.syncTopBlurProgress();
        })
        .onScrollStop((): void => {
          this.syncTopBlurProgress();
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      // 顶栏渐变模糊层：盖 Scroll 内容之上（z 序低于 HDS titleBar）
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
    // 滚动模糊依赖 scroller 绑定：把本页滚动容器交给 HDS 联动
    .bindToScrollable([this.pageScroller])
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
export function DiaryNewFacesPageBuilder(): void {
  DiaryNewFacesPage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接 @Builder 引用（编译期校验）。 */
export const DiaryNewFacesPageWrapped: WrappedBuilder<[]> = wrapBuilder(DiaryNewFacesPageBuilder);
