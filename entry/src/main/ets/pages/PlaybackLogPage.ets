/**
 * 播放日志页（设置页「日志记录」进入）。
 *
 * 背景：三方应用读不到系统 hilog，用户遇到「无法播放」时没有可提交的现场。
 * player/MusicPlayer.ts 在 plogError / plogWarn / notifyHint 三个汇聚点把
 * 播放日志写入 service/PlaybackLogStore（内存环形缓冲，最近 200 条，重启清空），
 * 本页渲染 + 复制：
 *   · 按时间倒序（最新在最上），级别着色：错误 state_error / 警告 state_warning
 *     / 提示 text_secondary；
 *   · 操作卡：「复制全部」（全量格式化文本进剪贴板）、「清空」；
 *   · 长按单条 = 复制该条（`[MM-DD HH:mm:ss][级别] message`）；
 *   · 空态：勾选图标 +「暂无播放失败日志」。
 *
 * 页面骨架仿 AboutPage（子页标准样板）：HDS 沉浸光感标题栏（stackBuilder 承载
 * logBarNarrow 收窄容器）+ 自绘顶栏渐变模糊层（TopGradientBlurOverlay，滚动
 * 命令式驱动）+ 400ms 右滑入转场（customTransition 代理）+ 系统返回拦截。
 * 日志列表用 List（复用回收，200 条文本上限 ForEach 即可，无需 LazyForEach）。
 */

import { STORE_SAFE_BOTTOM, STORE_SAFE_TOP } from '../common/Constants';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { InsetCard, CardDivider, SectionFooter } from '../components/InsetCardGroup';
import { copyText } from '../utils/ClipboardUtil';
import { showAppToast } from '../components/AppToast';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';
import {
  PlaybackLogEntry,
  PLAYBACK_LOG_WARN,
  PLAYBACK_LOG_ERROR,
  getPlaybackLogsNewestFirst,
  clearPlaybackLogs,
  formatPlaybackLogLine,
  formatPlaybackLogsAsText,
  playbackLogLevelLabel,
  formatPlaybackLogTime
} from '../service/PlaybackLogStore';

@Component
export struct PlaybackLogPage {
  /** 状态栏高度（vp）：HDS 标题栏 avoidLayoutSafeArea 后栏顶 = safeTop，占位让位量要含它 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：列表末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 日志快照（进入页面时取一次，重进即刷新；不做实时订阅，渲染与采集解耦） */
  @State logs: PlaybackLogEntry[] = [];
  /** 子页转场横移量（相对页面自身宽度）：转场代理里按 push/pop 方向临时改写 */
  @State navTransX: string = '0%';
  /** 列表滚动控制器：滚动模糊（topBlurUpdater）与 HDS bindToScrollable 共用 */
  private logScroller: Scroller = new Scroller();

  /** 自绘顶栏渐变模糊层进度更新器（AboutPage 同款命令式驱动，高频回调零重建） */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.logScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  aboutToAppear(): void {
    // 挂载前先存当前偏移对应的进度（updater 未挂载只存值，挂载时 initializeModifier 补上）
    this.syncTopBlurProgress();
    this.logs = getPlaybackLogsNewestFirst();
  }

  /** 「复制全部」：全量格式化文本进剪贴板，toast 回执（失败也提示，不静默） */
  private copyAllLogs(): void {
    copyText(formatPlaybackLogsAsText()).then((ok: boolean): void => {
      showAppToast(ok ? `已复制 ${this.logs.length} 条日志` : '复制失败，请重试', 1800);
    });
  }

  /** 「清空」：清 store + 清本地快照，toast 回执 */
  private clearAllLogs(): void {
    clearPlaybackLogs();
    this.logs = [];
    showAppToast('已清空', 1500);
  }

  /** 长按单条：复制该条格式化行 */
  private copySingleEntry(entry: PlaybackLogEntry): void {
    copyText(formatPlaybackLogLine(entry)).then((ok: boolean): void => {
      showAppToast(ok ? '已复制该条日志' : '复制失败，请重试', 1500);
    });
  }

  /** 级别 → 徽标颜色（错误红 / 警告橙 / 提示灰；色板 base + dark 均有定义） */
  private levelColor(level: number): ResourceColor {
    if (level === PLAYBACK_LOG_ERROR) {
      return $r('app.color.state_error');
    }
    if (level === PLAYBACK_LOG_WARN) {
      return $r('app.color.state_warning');
    }
    return $r('app.color.text_secondary');
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut（AboutPage 同款）。
   * push 入场先挪到屏幕右外侧再回到 0%；pop 出场反向滑回，与侧滑手势方向一致。
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

  /** 标题栏内容：「日志记录」标题（返回键为 HDS 默认键） */
  @Builder
  logBar() {
    NavTitleRow({ title: '日志记录' })
  }

  /**
   * 标题行收窄容器（AboutPage aboutBarNarrow 同款）：HDS titleBar 的 stackBuilder
   * 横跨目的地整列全宽，大屏上外层 Row 居中 + 内层 Column constraintSize 让标题行
   * 与收窄的内容列同宽对齐；两侧空白区 Transparent 穿透点击。
   */
  @Builder
  logBarNarrow() {
    Row() {
      Column() {
        this.logBar()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 操作行（「复制全部」/「清空」共用版式：左侧图标 + 标题 + press_overlay 按压反馈） */
  @Builder
  actionRow(labelText: string, glyph: Resource, onTap: () => void) {
    Row() {
      SymbolGlyph(glyph)
        .fontSize(16)
        .fontColor([$r('app.color.text_secondary')])

      Text(labelText)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 10 })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .accessibilityText(labelText)
    .accessibilityLevel('yes')
    .onClick((): void => {
      onTap();
    })
  }

  /** 空态：无日志时的居中提示（勾选图标 = 当前一切正常） */
  @Builder
  emptyState() {
    Column() {
      SymbolGlyph($r('sys.symbol.checkmark'))
        .fontSize(44)
        .fontColor([$r('app.color.text_tertiary')])

      Text('暂无播放失败日志')
        .fontSize(15)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 12 })

      Text('播放出错时会自动记录在这里，重启应用后清空')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .margin({ top: 120, bottom: 40 })
  }

  build() {
    HdsNavDestination() {
      Stack() {
        List({ scroller: this.logScroller }) {
          // 顶部占位：沉浸口径下内容从标题栏材质下方穿过（AboutPage Blank 占位
          // 的 List 版：Blank 不能直嵌 ListItem，用定高 Row）
          ListItem() {
            Row()
              .width('100%')
              .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)
          }

          // ── 操作卡：复制全部 / 清空 ──
          ListItem() {
            InsetCard() {
              Row() {
                Text('复制全部')
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                Text(`共 ${this.logs.length} 条`)
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .margin({ right: 6 })
                SymbolGlyph($r('sys.symbol.doc_filled_on_doc'))
                  .fontSize(16)
                  .fontColor([$r('app.color.text_secondary')])
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 13, bottom: 13 })
              .alignItems(VerticalAlign.Center)
              .stateStyles({
                pressed: { .backgroundColor($r('app.color.press_overlay')) },
                normal: { .backgroundColor(Color.Transparent) }
              })
              .accessibilityText(`复制全部日志，共 ${this.logs.length} 条`)
              .accessibilityLevel('yes')
              .onClick((): void => {
                this.copyAllLogs();
              })

              CardDivider()

              this.actionRow('清空', $r('sys.symbol.xmark'), (): void => {
                this.clearAllLogs();
              })
            }
          }

          ListItem() {
            SectionFooter({ noteText: '播放出错时会自动记录（错误 / 警告 / 提示），重启应用后清空。长按单条可复制。' })
          }

          // ── 日志列表（空态 / 条目二选一）──
          if (this.logs.length === 0) {
            ListItem() {
              this.emptyState()
            }
          } else {
            ForEach(this.logs, (entry: PlaybackLogEntry): void => {
              // 单条日志卡：外层 Row padding 让位（百分比宽 + margin 会右溢出 16vp，
              // InsetCard 同款教训），内层 Column layoutWeight 承底色圆角
              ListItem() {
                Row() {
                  Column() {
                    Row() {
                      Text(formatPlaybackLogTime(entry.time))
                        .fontSize(11)
                        .fontColor($r('app.color.text_tertiary'))

                      Blank()

                      Text(playbackLogLevelLabel(entry.level))
                        .fontSize(11)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.levelColor(entry.level))
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center)

                    Text(entry.message)
                      .fontSize(13)
                      .fontColor($r('app.color.text_primary'))
                      .lineHeight(18)
                      .width('100%')
                      .margin({ top: 4 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                }
                .width('100%')
                .padding({ left: 16, right: 16, bottom: 10 })
                .gesture(
                  LongPressGesture()
                    .onAction((): void => {
                      this.copySingleEntry(entry);
                    })
                )
              }
            }, (entry: PlaybackLogEntry): string => `${entry.time}_${entry.message}`)
          }
        }
        .width('100%')
        .height('100%')
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(10)
        // 大屏适配：内容列收窄居中（Stack 默认居中对齐，与 AboutPage 同口径）
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
        // 底部安全区让位：列表末尾可滚至手势区上方不被遮挡（SettingsPage 同款）
        .contentEndOffset(this.safeBottom + 16)
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

      // 顶栏渐变模糊层：盖 List 内容之上（z 序低于 HDS titleBar），进度命令式驱动
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
          this.logBarNarrow();
        }
      }
    })
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页滚动容器交给 HDS 联动
    .bindToScrollable([this.logScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让（官方组件级沉浸口径）：目的地级声明布局扩展进系统安全区
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function PlaybackLogPageBuilder(): void {
  PlaybackLogPage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接 @Builder 引用（编译期校验）。 */
export const PlaybackLogPageWrapped: WrappedBuilder<[]> = wrapBuilder(PlaybackLogPageBuilder);
