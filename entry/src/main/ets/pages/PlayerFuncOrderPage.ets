/**
 * 自定义功能栏页（播放设置 → 播放页入口 → 自定义功能栏）。
 *
 * 播放页功能行共 9 个功能项（核心 4 + 开关入口 5），顺序持久化在
 * AppSettings.funcItemOrder：前 4 位 = 播放页默认页图标，其余经左右滑动
 * 分页切换查看（ControlAreaComponent 的 Swiper 分页）。本页负责整体排序：
 *   · 长按拖动（ForEach.onMove 官方拖拽路线，系统自带浮起/让位动画）；
 *   · 前 4 位行尾标「默认显示」主题色描边徽标；
 *   · 5 个开关入口项受各自入口开关控制：未开启时降透明 + 副文案提示，
 *     仍可拖动（占位顺序保留，开启后按当前顺序出现在功能行）；
 *   · 拖动落手即写穿：AppPreferences.updateSettings（持久层）+
 *     AppStorage.setOrCreate(STORE_FUNC_ITEM_ORDER)（运行时镜像）。
 *
 * ⚠️ ForEach 键 = `${id}_${是否默认区}`：onMove 后 ForEach 对已有键只移动
 * 组件不重跑 itemGenerator，纯 id 键会让跨「前 4 位」边界拖动的行徽标滞留
 * 在旧值；键含分区标记后，跨界行的键变化强制重建、徽标必然正确
 * （未跨界行键不变不重建，内容本就无需变）。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，PlaybackSettingsPage
 * 同款骨架）：材质与滚动模糊由 HDS 统一渲染，内容用 stackBuilder 承载标题；
 * 侧滑返回是 Navigation 级能力，不受影响。
 */

import {
  CONTENT_END_OFFSET,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_REPEAT_MODE,
  STORE_PLAYBACK_SPEED,
  STORE_PLAYBACK_SPEED_ENABLED,
  STORE_OPEN_IN_BILI_ENABLED,
  STORE_SLEEP_TIMER_ENTRY_ENABLED,
  STORE_SKIP_INTRO_ENTRY_ENABLED,
  STORE_UP_SPACE_ENTRY_ENABLED,
  STORE_THEME_PRIMARY,
  STORE_FUNC_ITEM_ORDER
} from '../common/Constants';
import {
  AppSettings,
  RepeatMode,
  PLAYER_FUNC_REPEAT,
  PLAYER_FUNC_DOWNLOAD,
  PLAYER_FUNC_ADD_PLAYLIST,
  PLAYER_FUNC_QUEUE,
  PLAYER_FUNC_SPEED,
  PLAYER_FUNC_SKIP,
  PLAYER_FUNC_SLEEP,
  PLAYER_FUNC_BILI,
  PLAYER_FUNC_UP_SPACE,
  DEFAULT_FUNC_ITEM_ORDER,
  speedLabelOf
} from '../model/MusicModels';
import { AppPreferences } from '../preferences/AppPreferences';
import { BarNarrowShell } from '../components/BarNarrowShell';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { TwoColumnLayout } from '../common/utils/TwoColumnList';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { modeIconOf } from '../components/QueueSheet';

@Component
export struct PlayerFuncOrderPage {
  /** 状态栏高度（vp）：HDS 标题栏 avoidLayoutSafeArea 后栏顶 = safeTop，内容让位量要含它 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：内容末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 当前横竖屏（Index 常驻注册写入）：内容列 840 口径取值用 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;
  /** 品牌色（「默认显示」徽标描边与文字色）：EntryAbility 发布、外观页选色 / 切深浅重发布 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /** 当前播放模式（repeat 项图标实时跟随）：播放内核发布 */
  @StorageProp(STORE_REPEAT_MODE) repeatMode: RepeatMode = RepeatMode.NONE;
  /** 当前倍速（speed 项视觉 = 倍速片文案，实时跟随） */
  @StorageProp(STORE_PLAYBACK_SPEED) playbackSpeed: number = 1.0;
  /** 五个开关入口项的入口开关镜像（未开启 → 行降透明 + 副文案提示） */
  @StorageProp(STORE_PLAYBACK_SPEED_ENABLED) speedEnabled: boolean = false;
  @StorageProp(STORE_SKIP_INTRO_ENTRY_ENABLED) skipEntryEnabled: boolean = false;
  @StorageProp(STORE_SLEEP_TIMER_ENTRY_ENABLED) sleepEntryEnabled: boolean = false;
  @StorageProp(STORE_OPEN_IN_BILI_ENABLED) openInBiliEnabled: boolean = true;
  @StorageProp(STORE_UP_SPACE_ENTRY_ENABLED) upSpaceEntryEnabled: boolean = false;
  /**
   * 功能项顺序（本页唯一数据源）。aboutToAppear 从持久层读
   * （AppPreferences 内存缓存启动即热，getSettings 同步零磁盘读）；
   * 拖动落手整体重赋值（@State 数组引用替换才触发重渲染）。
   */
  @State order: string[] = DEFAULT_FUNC_ITEM_ORDER;
  /** 滚动控制器：bindToScrollable 绑给 HDS 标题栏，滚动模糊效果依赖此绑定 */
  private pageScroller: Scroller = new Scroller();
  /** 子页转场的横移量（相对页面自身宽度）：转场代理里按 push/pop 方向临时改写 */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    // 持久层真值起步：AppPreferences.getSettings 走内存缓存（EntryAbility 启动
    // 已读 → 必热），同步调用零磁盘读；normalizeFuncItemOrder 保证合法 9 项序。
    this.order = AppPreferences.getSettings().funcItemOrder;
  }

  /**
   * 长按拖动重排（ForEach.onMove 回调）。
   *
   * onMove 由系统在拖拽**松手后**触发一次（from = 拖起下标，to = 落点下标），
   * 下标限定在 ForEach 数据（this.order）内。本地序对齐（与系统已完成的视觉
   * 移动一致）后写穿两处 —— 持久层（updateSettings：读缓存真值 → 改 → 写盘）
   * 与运行时镜像（STORE_FUNC_ITEM_ORDER：播放页 ControlAreaComponent
   * @StorageProp 订阅即时生效）。三处数组互不共享引用（slice 隔离）。
   */
  private onItemMove(from: number, to: number): void {
    if (from < 0 || from >= this.order.length) {
      return;
    }
    const moved: string = this.order[from];
    const next: string[] = [...this.order];
    next.splice(from, 1);
    const target: number = Math.max(0, Math.min(to, next.length));
    next.splice(target, 0, moved);
    this.order = next;
    AppPreferences.updateSettings((s: AppSettings): void => {
      s.funcItemOrder = next.slice();
    });
    AppStorage.setOrCreate(STORE_FUNC_ITEM_ORDER, next.slice());
  }

  /** 功能项标签（行主文案） */
  private itemLabelOf(id: string): string {
    if (id === PLAYER_FUNC_REPEAT) {
      return '播放模式';
    }
    if (id === PLAYER_FUNC_DOWNLOAD) {
      return '下载';
    }
    if (id === PLAYER_FUNC_ADD_PLAYLIST) {
      return '加入歌单';
    }
    if (id === PLAYER_FUNC_QUEUE) {
      return '播放列表';
    }
    if (id === PLAYER_FUNC_SPEED) {
      return '倍速';
    }
    if (id === PLAYER_FUNC_SKIP) {
      return '限定播放进度';
    }
    if (id === PLAYER_FUNC_SLEEP) {
      return '定时停止';
    }
    if (id === PLAYER_FUNC_BILI) {
      return '在 B 站打开';
    }
    return '进入 UP 主页';
  }

  /** 开关入口项的入口开关是否开启（核心 4 项恒开） */
  private entryEnabledOf(id: string): boolean {
    if (id === PLAYER_FUNC_SPEED) {
      return this.speedEnabled;
    }
    if (id === PLAYER_FUNC_SKIP) {
      return this.skipEntryEnabled;
    }
    if (id === PLAYER_FUNC_SLEEP) {
      return this.sleepEntryEnabled;
    }
    if (id === PLAYER_FUNC_BILI) {
      return this.openInBiliEnabled;
    }
    if (id === PLAYER_FUNC_UP_SPACE) {
      return this.upSpaceEntryEnabled;
    }
    return true;
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut
   * （PlaybackSettingsPage 同款）。
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

  /** 标题栏内容（titleBar 的 stackBuilder 承载）：「自定义功能栏」标题（返回键为 HDS 默认键） */
  @Builder
  orderBar() {
    NavTitleRow({ title: '自定义功能栏' })
  }

  /** 标题行收窄容器（BarNarrowShell 共用件，平板模式宽度适配） */
  @Builder
  orderBarNarrow() {
    BarNarrowShell({ bar: (): void => {
      this.orderBar()
    } })
  }

  /**
   * 功能项视觉槽（行首 36×36 居中）：照抄播放页功能行同款形态 ——
   * repeat 用实时模式图标、speed 用倍速片文案、skip 用播放页同款
   * arrow_left_arrow_right 区间箭头，其余用功能行同款 sys.symbol 图标；浅色卡底上用正文主色。
   */
  @Builder
  private ItemVisual(id: string) {
    if (id === PLAYER_FUNC_REPEAT) {
      SymbolGlyph(modeIconOf(this.repeatMode))
        .fontSize(22)
        .fontColor([$r('app.color.text_primary')])
    } else if (id === PLAYER_FUNC_DOWNLOAD) {
      SymbolGlyph($r('sys.symbol.arrow_down_to_line'))
        .fontSize(22)
        .fontColor([$r('app.color.text_primary')])
    } else if (id === PLAYER_FUNC_ADD_PLAYLIST) {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(22)
        .fontColor([$r('app.color.text_primary')])
    } else if (id === PLAYER_FUNC_QUEUE) {
      SymbolGlyph($r('sys.symbol.list_bullet'))
        .fontSize(22)
        .fontColor([$r('app.color.text_primary')])
    } else if (id === PLAYER_FUNC_SPEED) {
      Text(speedLabelOf(this.playbackSpeed))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
    } else if (id === PLAYER_FUNC_SKIP) {
      SymbolGlyph($r('sys.symbol.arrow_left_arrow_right'))
        .fontSize(22)
        .fontColor([$r('app.color.text_primary')])
    } else if (id === PLAYER_FUNC_SLEEP) {
      SymbolGlyph($r('sys.symbol.clock'))
        .fontSize(22)
        .fontColor([$r('app.color.text_primary')])
    } else if (id === PLAYER_FUNC_BILI) {
      SymbolGlyph($r('sys.symbol.arrow_up_right'))
        .fontSize(22)
        .fontColor([$r('app.color.text_primary')])
    } else {
      SymbolGlyph($r('sys.symbol.person'))
        .fontSize(22)
        .fontColor([$r('app.color.text_primary')])
    }
  }

  /** 单个功能项行（图标 + 标签 / 未开启提示 + 「默认显示」徽标） */
  @Builder
  private OrderRow(id: string, index: number) {
    Row() {
      Row() {
        this.ItemVisual(id)
      }
      .width(36)
      .height(36)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .opacity(this.entryEnabledOf(id) ? 1 : 0.4)

      Column({ space: 2 }) {
        Text(this.itemLabelOf(id))
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (!this.entryEnabledOf(id)) {
          Text('入口开关未开启，开启后显示在播放页功能行')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })

      if (index < 4) {
        Text('默认显示')
          .fontSize(11)
          .lineHeight(14)
          .fontColor(this.themePrimary)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(10)
          .border({ width: 1, color: this.themePrimary })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .alignItems(VerticalAlign.Center)
    .accessibilityText(`${this.itemLabelOf(id)}${index < 4 ? '，默认显示' : ''}`)
  }

  build() {
    HdsNavDestination() {
      List({ scroller: this.pageScroller }) {
        // 顶部空白占位条目（官方沉浸口径）：高度 = safeTop + 56（MINI 标题栏），
        // 静止位首个真实条目恰从栏底起排，滚动时从材质下方穿过。
        ListItem() {
          Row()
            .width('100%')
            .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)
        }

        ListItem() {
          Text('前 4 位为播放页默认显示的功能，其余通过左右滑动分页查看；长按拖动调整顺序。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ left: 20, right: 20, top: 6, bottom: 10 })
        }

        ForEach(
          this.order,
          (id: string, index: number): void => {
            ListItem() {
              Row() {
                Column() {
                  this.OrderRow(id, index)
                }
                .layoutWeight(1)
                .backgroundColor($r('app.color.bg_card'))
                .borderRadius(12)
                .clip(true)
              }
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 6 })
            }
          },
          // 键含「默认区」标记（见文件头注释）：跨前 4 位边界拖动时键变化
          // 强制重建该行，徽标必然正确；未跨界行键不变、组件仅被系统移动。
          (id: string, index: number): string => `${id}_${index < 4 ? 'd' : 's'}`
        )
          // 长按拖动重排：ForEach.onMove 官方拖拽路线（系统自带浮起/让位
          // 动画 + 拖到边缘自动滚动），松手后触发一次，见 onItemMove。
          .onMove((from: number, to: number): void => {
            this.onItemMove(from, to);
          })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
      // 边界回弹：到顶/到底的反馈动效
      .edgeEffect(EdgeEffect.Spring)
      .cachedCount(10)
      // 底部让位：列表末尾可滚动至手势区上方，不被遮挡
      .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
      // 大屏适配：内容列收窄居中（走 TwoColumnLayout.contentMaxWidth）
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
    }
    // HDS 沉浸光感标题栏：材质 / 滚动模糊 / 温控统一由 HdsTitleBarStyle 决策
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(),
      content: {
        // 箭头包裹保证 builder 内 this 指向本组件（裸引用会丢失 this）
        stackBuilder: (): void => {
          this.orderBarNarrow();
        }
      }
    })
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页滚动容器交给 HDS 联动
    .bindToScrollable([this.pageScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 系统返回拦截（播放页 overlay 打开时吞掉返回，否则走默认 pop）
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让（官方组件级沉浸口径，PlaybackSettingsPage 同款）
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 经动态 import 后用 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function PlayerFuncOrderPageBuilder(): void {
  PlayerFuncOrderPage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接 @Builder 引用（编译期校验）。 */
export const PlayerFuncOrderPageWrapped: WrappedBuilder<[]> = wrapBuilder(PlayerFuncOrderPageBuilder);
