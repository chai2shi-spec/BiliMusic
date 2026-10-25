/**
 * 外观设置页：
 * 内容：主题（深浅循环）/ 主题色（bindSheet 半屏 8 色面板）/ 播放页进度条样式（四档循环）/
 * 播放页收起动画（三档循环）/ 播放页封面风格（三档循环）/ 条目展示（两档循环：长条 / 大封面）/
 * 底部导航布局（SM 断点才渲染）/ 迷你栏进度条 / 自动展开收起（SM 断点才渲染）。
 *
 * 主题深浅 / 主题色经 publishThemeColors 写 AppStorage，全局组件 @StorageProp 订阅
 * 即时刷新，无需重启；样式类设置（进度条 / 收起动画 / 封面风格 / 底部导航布局 /
 * 迷你栏两项）写偏好 + AppStorage 镜像，对应消费组件即时重渲染。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，AboutPage 同款骨架）。
 */

import common from '@ohos.app.ability.common';
import { ConfigurationConstant } from '@kit.AbilityKit';
import {
  CONTENT_END_OFFSET,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY,
  STORE_THEME_DEEP,
  STORE_THEME_SURFACE,
  STORE_THEME_ON,
  STORE_BAR_LAYOUT,
  STORE_PROGRESS_STYLE,
  STORE_PLAYER_CLOSE_ANIM,
  STORE_PLAYER_COVER_STYLE,
  STORE_ITEM_DISPLAY_STYLE,
  STORE_MINI_BAR_PROGRESS,
  STORE_MINI_BAR_AUTO_EXPAND
} from '../common/Constants';
import {
  AppSettings,
  DEFAULT_APP_SETTINGS,
  ThemeMode,
  BAR_LAYOUT_HORIZONTAL,
  BAR_LAYOUT_VERTICAL,
  PROGRESS_STYLE_CLASSIC,
  PROGRESS_STYLE_SHIMMER,
  PROGRESS_STYLE_PULSE,
  PROGRESS_STYLE_WAVE,
  progressStyleLabelOf,
  PLAYER_CLOSE_STYLE_MORPH,
  PLAYER_CLOSE_STYLE_MORPH_SWIPE,
  PLAYER_CLOSE_STYLE_SLIDE,
  closeStyleLabelOf,
  PLAYER_COVER_STYLE_DISC,
  PLAYER_COVER_STYLE_SQUARE,
  coverStyleLabelOf,
  ITEM_DISPLAY_LIST,
  ITEM_DISPLAY_GRID,
  itemDisplayLabelOf
} from '../model/MusicModels';
import { AppPreferences } from '../preferences/AppPreferences';
import {
  THEME_PALETTES,
  ThemePalette,
  publishThemeColors,
  isAppDark,
  themeColorLabel
} from '../common/ThemeColors';
import { showAppToast } from '../components/AppToast';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { TwoColumnLayout } from '../common/utils/TwoColumnList';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { InsetCard, CardDivider } from '../components/InsetCardGroup';
import { HdsListItemCard, SuffixSwitch, SuffixText } from '@kit.UIDesignKit';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';

@Component
export struct AppearanceSettingsPage {
  /** 状态栏高度（vp）：HDS 标题栏 avoidLayoutSafeArea 后栏顶 = safeTop，内容让位量要含它 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：内容末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中；SM 专属行的显隐判定也用它 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 当前横竖屏（Index 常驻注册写入）：内容列 840 口径取值用 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;
  /**
   * 设置快照。首帧零磁盘读：先默认值占位，aboutToAppear 延后一拍读真值；
   * 开关写入走 AppPreferences.updateSettings（从持久层真值起步，不存在
   * 「默认值被当真值覆盖写盘」的风险）。
   */
  @State settings: AppSettings = DEFAULT_APP_SETTINGS;
  /**
   * 主题色运行时值（EntryAbility 启动发布、本页选色 / 切深浅模式重发布）。
   * 本页自己的品牌色消费点（开关选中色 / 选色面板选中态描边）跟随它们刷新。
   */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /** 底部半屏面板开关（本页只有主题色一种面板） */
  @State showSheet: boolean = false;
  /** 滚动控制器：bindToScrollable 绑给 HDS 标题栏，滚动模糊效果依赖此绑定 */
  private pageScroller: Scroller = new Scroller();

  /** 子页转场的横移量（相对页面自身宽度）：转场代理里按 push/pop 方向临时改写 */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    // 偏好读取延后一拍，首帧 build 全程零磁盘读。
    setTimeout((): void => {
      this.settings = AppPreferences.getSettings();
    }, 0);
  }

  /**
   * 统一写偏好（读持久层真值 → 改 → 写 → 返回新快照）：
   * this.settings 直接接住返回值，UI 即时刷新。
   */
  private update(mut: (s: AppSettings) => void): void {
    this.settings = AppPreferences.updateSettings(mut);
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  private themeLabel(): string {
    if (this.settings.themeMode === ThemeMode.DARK) {
      return '深色';
    }
    if (this.settings.themeMode === ThemeMode.LIGHT) {
      return '浅色';
    }
    return '跟随系统';
  }

  private cycleTheme(): void {
    const order: ThemeMode[] = [ThemeMode.SYSTEM, ThemeMode.LIGHT, ThemeMode.DARK];
    const idx: number = order.indexOf(this.settings.themeMode);
    const next: ThemeMode = order[(idx + 1) % order.length];
    this.update((s: AppSettings): void => {
      s.themeMode = next;
    });
    // 只写偏好不生效：必须同步调 setColorMode 把模式真正应用到应用
    // （启动时的恢复逻辑在 EntryAbility，loadContent 首帧前）。
    const ctx = this.getUIContext().getHostContext();
    if (ctx) {
      AppPreferences.applyThemeMode(ctx, next);
    }
    // 深浅模式影响主题色 deep / surface 的浅深变体选择，随批重发布
    //（只切模式不重发布的话，封面占位 / 深色徽标会滞留旧变体）。
    this.publishThemeNow();
    this.toast(`主题：${this.themeLabel()}`, 1500);
  }

  private barLayoutLabel(): string {
    return this.settings.barLayout === BAR_LAYOUT_VERTICAL ? '垂直两层' : '水平融合';
  }

  /**
   * 切换底部导航布局（点击循环）：水平融合（播放栏与页签同一行）⇄ 垂直两层
   * （播放栏在上、页签在下）。写偏好 + 写 AppStorage 镜像 —— Index 的
   * @StorageProp 订阅触发受控样式重建，即时生效无需重启。
   * ⚠️ HdsBarLayoutMode 6.1.1(24) 才有：API 23 设备布局恒为默认垂直两层，
   * 本开关无视觉效果（Index 的 typeof 守卫跳过赋值）。
   */
  private cycleBarLayout(): void {
    const next: string = this.settings.barLayout === BAR_LAYOUT_VERTICAL
      ? BAR_LAYOUT_HORIZONTAL : BAR_LAYOUT_VERTICAL;
    this.update((s: AppSettings): void => {
      s.barLayout = next;
    });
    AppStorage.setOrCreate(STORE_BAR_LAYOUT, next);
    this.toast(`底部导航布局：${this.barLayoutLabel()}`, 1500);
  }

  /**
   * 切换播放页进度条样式（点击四档循环）：经典（系统 Slider）→ 流光渐变条 →
   * 脉冲波点 → 律动频谱条。写偏好 + 写 AppStorage 镜像（STORE_PROGRESS_STYLE）
   * —— ControlAreaComponent 的 @StorageProp 订阅触发四分支重渲染，即时生效
   * 无需重启；交互契约（拖动跟随 / 松手 seek / 插值推进）四档完全一致。
   */
  private cycleProgressStyle(): void {
    const order: string[] =
      [PROGRESS_STYLE_CLASSIC, PROGRESS_STYLE_SHIMMER, PROGRESS_STYLE_PULSE, PROGRESS_STYLE_WAVE];
    const idx: number = order.indexOf(this.settings.progressStyle);
    // 未知存量值（旧版本数据异常）从经典档重新开始循环
    const next: string = order[((idx < 0 ? 0 : idx) + 1) % order.length];
    this.update((s: AppSettings): void => {
      s.progressStyle = next;
    });
    AppStorage.setOrCreate(STORE_PROGRESS_STYLE, next);
    this.toast(`进度条样式：${progressStyleLabelOf(next)}`, 1500);
  }

  /**
   * 切换播放页收起动画风格（点击三档循环）：柔退（内容反向错峰淡出 + 封面
   * 回飞）/ 柔退+手势（柔退 + 手机端下拉跟手收起，默认）/ 下滑（整页下滑
   * 淡出）。写偏好 + 写 AppStorage 镜像（STORE_PLAYER_CLOSE_ANIM）——
   * Index.closePlayer 据此分流收起实现、PlayerPage 据此挂/摘下拉手势，
   * 即时生效无需重启。打开侧动画三档均保持 morph 一镜到底不变。
   */
  private cycleCloseAnimStyle(): void {
    const order: string[] =
      [PLAYER_CLOSE_STYLE_MORPH, PLAYER_CLOSE_STYLE_MORPH_SWIPE, PLAYER_CLOSE_STYLE_SLIDE];
    const idx: number = order.indexOf(this.settings.closeAnimStyle);
    // 未知存量值（旧版本数据异常）从柔退档重新开始循环
    const next: string = order[((idx < 0 ? 0 : idx) + 1) % order.length];
    this.update((s: AppSettings): void => {
      s.closeAnimStyle = next;
    });
    AppStorage.setOrCreate(STORE_PLAYER_CLOSE_ANIM, next);
    this.toast(`收起动画：${closeStyleLabelOf(next)}`, 1500);
  }

  /**
   * 切换播放页封面风格（点击两档循环）：唱片（圆形，默认）/ 方卡（方形
   * 圆角极简）。写偏好 + 写 AppStorage 镜像（STORE_PLAYER_COVER_STYLE）——
   * CoverDiscComponent 的封面形态与 PlayerInfoComponent 的 SurfaceLayers
    * 背景分层据此分流，即时生效无需重启。不设全屏档（linearGradientBlur
    * 逐帧实时模糊为播放页最贵开销），存量偏好由 normalizeCoverStyle
    * 白名单归一化回落唱片档。
   */
  private cyclePlayerCoverStyle(): void {
    const order: string[] =
      [PLAYER_COVER_STYLE_DISC, PLAYER_COVER_STYLE_SQUARE];
    const idx: number = order.indexOf(this.settings.playerCoverStyle);
    // 未知存量值（旧版本数据异常）从唱片档重新开始循环
    const next: string = order[((idx < 0 ? 0 : idx) + 1) % order.length];
    this.update((s: AppSettings): void => {
      s.playerCoverStyle = next;
    });
    AppStorage.setOrCreate(STORE_PLAYER_COVER_STYLE, next);
    this.toast(`封面风格：${coverStyleLabelOf(next)}`, 1500);
  }

  /**
   * 切换条目展示（点击两档循环）：长条（小封面 + 长标题行，默认）/ 大封面
   * （双列网格、大封面 + 小字标题）。写偏好 + 写 AppStorage 镜像
   * （STORE_ITEM_DISPLAY_STYLE）—— 歌单页签 / 最近播放 / UP 主页 / 首页
   * 三页签 / 歌单详情（不可排序）/ 搜索视频结果的 @StorageProp 订阅即时
   * 重渲染，无需重启。可排序歌单详情恒为长条（保 onMove 拖动排序）。
   */
  private cycleItemDisplayStyle(): void {
    const next: string = this.settings.itemDisplayStyle === ITEM_DISPLAY_LIST
      ? ITEM_DISPLAY_GRID : ITEM_DISPLAY_LIST;
    this.update((s: AppSettings): void => {
      s.itemDisplayStyle = next;
    });
    AppStorage.setOrCreate(STORE_ITEM_DISPLAY_STYLE, next);
    this.toast(`条目展示：${itemDisplayLabelOf(next)}`, 1500);
  }

  /**
   * 选择主题色：写偏好 → 重发布 AppStorage 主题色键（全局订阅组件即时变色）
   * → toast → 关面板。同一色再点只关面板不重发布。
   */
  private chooseThemeColor(id: string): void {
    this.showSheet = false;
    if (this.settings.themeColor === id) {
      return;
    }
    this.update((s: AppSettings): void => {
      s.themeColor = id;
    });
    this.publishThemeNow();
    this.toast(`主题色：${themeColorLabel(id)}`, 1500);
  }

  /** 把当前偏好里的主题色按当前生效深浅重新发布（选色 / 切深浅模式后调用） */
  private publishThemeNow(): void {
    publishThemeColors(
      this.settings.themeColor,
      isAppDark(this.settings.themeMode, this.currentSysDark())
    );
  }

  /** 系统当前深浅（跟随系统模式的判定依据）：读宿主 UIAbilityContext.config */
  private currentSysDark(): boolean {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      return ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (e) {
      return false;
    }
  }

  /**
   * 主题色选择面板（半屏）：8 色块 4×2 网格，点选即生效
   * （chooseThemeColor：写偏好 + 发布 AppStorage + toast + 关面板）。
   * 选中态：色块外同色描边圈 + 块内白色对勾；未选中只渲染色块与色名。
   */
  @Builder
  ThemeColorSheetContent(): void {
    Column() {
      Text('主题色')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text('选择后立即应用于全局品牌色')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 4 })

      Grid() {
        ForEach(THEME_PALETTES, (p: ThemePalette): void => {
          GridItem() {
            Column() {
              Stack() {
                Circle({ width: 40, height: 40 })
                  .fill(p.primary)
                if (this.settings.themeColor === p.id) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(18)
                    .fontColor([Color.White])
                }
              }
              .width(48)
              .height(48)
              .borderRadius(24)
              .border({
                width: 2,
                color: this.settings.themeColor === p.id ? p.primary : Color.Transparent
              })
              .padding(2)

              Text(p.label)
                .fontSize(12)
                .fontColor(this.settings.themeColor === p.id
                  ? $r('app.color.text_primary')
                  : $r('app.color.text_secondary'))
                .margin({ top: 6 })
            }
            .width('100%')
            .padding({ top: 4, bottom: 4 })
            .onClick((): void => {
              this.chooseThemeColor(p.id);
            })
          }
        }, (p: ThemePalette): string => `palette_${p.id}`)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .rowsTemplate('1fr 1fr')
      .height(176)
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .padding({ top: 16, bottom: 16 })
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut（AboutPage 同款）。
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

  /** 标题栏内容（titleBar 的 stackBuilder 承载）：「外观设置」标题（返回键为 HDS 默认键） */
  @Builder
  appearanceBar() {
    NavTitleRow({ title: '外观设置' })
  }

  /**
   * 标题行收窄容器（AboutPage 同款）：外层 Row 居中 + 内层 Column constraintSize
   * （上限与本页内容列同口径），大屏上标题行与内容列同宽对齐；
   * 两侧空白区 hitTestBehavior(Transparent) 穿透点击。
   */
  @Builder
  appearanceBarNarrow() {
    Row() {
      Column() {
        this.appearanceBar()
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
          InsetCard() {
            HdsListItemCard({
              textItem: { primaryText: { text: '主题' } },
              suffixItem: new SuffixText({ text: this.themeLabel() }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.cycleTheme();
              }
            })

            CardDivider()

            // 主题色（8 色切换）：后缀显示当前色名，点击弹半屏色块面板
            HdsListItemCard({
              textItem: { primaryText: { text: '主题色' } },
              suffixItem: new SuffixText({ text: themeColorLabel(this.settings.themeColor) }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.showSheet = true;
              }
            })

            CardDivider()

            // 播放页进度条样式（四档循环）：经典（系统 Slider）/ 流光渐变条 /
            // 脉冲波点 / 律动频谱条。写偏好 + AppStorage 镜像
            // （STORE_PROGRESS_STYLE），ControlAreaComponent 四分支即时重渲染。
            // 播放页 sm/md/lg 全形态存在 → 本行不做断点隐藏。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '播放页进度条样式' },
                secondaryText: { text: '经典 / 流光 / 波点 / 频谱' }
              },
              suffixItem: new SuffixText({ text: progressStyleLabelOf(this.settings.progressStyle) }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.cycleProgressStyle();
              }
            })

            CardDivider()

            // 播放页收起动画（三档循环）：
            // 柔退（内容反向错峰淡出 + 背景末端渐隐 + 封面回飞）/ 柔退+手势
            // （柔退 + 手机端封面页下拉跟手收起，默认）/ 下滑（所有入口整页
            // 下滑淡出）。写偏好 + AppStorage 镜像（STORE_PLAYER_CLOSE_ANIM），
            // Index.closePlayer 分流收起实现、PlayerPage 挂/摘下拉手势，
            // 即时生效；打开侧动画三档均为 morph 不变。播放页全形态存在 →
            // 本行不做断点隐藏。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '播放页收起动画' },
                secondaryText: { text: '柔退 / 柔退+手势 / 下滑' }
              },
              suffixItem: new SuffixText({ text: closeStyleLabelOf(this.settings.closeAnimStyle) }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.cycleCloseAnimStyle();
              }
            })

            CardDivider()

            // 播放页封面风格（两档循环）：唱片（圆形封面，默认）/ 方卡（方形圆角极简 + 主色
            // 净底）。写偏好 + AppStorage 镜像（STORE_PLAYER_COVER_STYLE），
            // CoverDiscComponent 封面形态与 SurfaceLayers 背景分层据此分流，
            // 即时生效。播放页全形态存在 → 本行不做断点隐藏。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '播放页封面风格' },
                secondaryText: { text: '唱片 / 方卡' }
              },
              suffixItem: new SuffixText({ text: coverStyleLabelOf(this.settings.playerCoverStyle) }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.cyclePlayerCoverStyle();
              }
            })

            CardDivider()

            // 条目展示（两档循环）：长条（小封面 +
            // 长标题行，默认）/ 大封面（双列网格、大封面 + 小字标题）。写偏好 +
            // AppStorage 镜像（STORE_ITEM_DISPLAY_STYLE），各封面类列表页的
            // @StorageProp 订阅即时重渲染。各形态（手机 / 平板）均有列表页 →
            // 本行不做断点隐藏。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '条目展示' },
                secondaryText: { text: '长条 / 大封面' }
              },
              suffixItem: new SuffixText({ text: itemDisplayLabelOf(this.settings.itemDisplayStyle) }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.cycleItemDisplayStyle();
              }
            })

            CardDivider()

            // 底部导航布局：水平融合（播放栏与页签同一行）/ 垂直两层（播放栏上、页签下）。
            // 点击循环切换，写偏好 + AppStorage 镜像即时生效（Index 受控样式重建）。
            // HDS 底部页签栏只在手机形态（SM）渲染，md/lg 是 NavRail + 浮岛，
            // 本项在平板上点了没有任何可见效果 → 非 SM 整卡隐藏。
            if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_SM) {
              HdsListItemCard({
                textItem: { primaryText: { text: '底部导航布局' } },
                suffixItem: new SuffixText({ text: this.barLayoutLabel() }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0,
                onClick: (): void => {
                  this.cycleBarLayout();
                }
              })

              CardDivider()
            }

            // 迷你栏进度条：底部 2vp 直线进度条与水平收起态圆环进度的总开关。
            // 关闭后两处进度指示均不再渲染（纯 UI 层，不影响播放页进度条）；
            // 写偏好 + AppStorage 镜像（STORE_MINI_BAR_PROGRESS）即时生效。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '迷你栏进度条' },
                secondaryText: { text: '迷你栏底边直线与收起态圆环进度' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.miniBarProgress,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  this.update((s: AppSettings): void => {
                    s.miniBarProgress = v;
                  });
                  AppStorage.setOrCreate(STORE_MINI_BAR_PROGRESS, v);
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            // 迷你栏自动展开收起：全屏滑动手势（上滑展开、下滑收起）的总开关。
            // 关闭后浏览列表的竖向滑动不再触发迷你栏收放，仅保留点按圆盘等
            // 显式交互；写偏好 + AppStorage 镜像（STORE_MINI_BAR_AUTO_EXPAND），
            // Index 的 @StorageProp 订阅即时生效，无需重启。
            // 屏幕滑动收放只在手机形态（SM）接线，md/lg 浮岛不参与手势展开 → 非 SM 整卡隐藏。
            if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_SM) {
              CardDivider()

              HdsListItemCard({
                textItem: {
                  primaryText: { text: '自动展开收起' },
                  secondaryText: { text: '屏幕上滑展开、下滑收起迷你栏' }
                },
                suffixItem: new SuffixSwitch({
                  isCheck: this.settings.miniBarAutoExpand,
                  selectColor: this.themePrimary,
                  onChange: (v: boolean): void => {
                    // 进页不弹提示：settings 延后一拍读真值时
                    // isCheck 翻转会让 SuffixSwitch 误触发 onChange —— 用翻转
                    // 前值守卫，只有值真的从关翻到开才提醒；误触发时 v 与持久值
                    // 一致被拦下。
                    const turningOn: boolean = v && !this.settings.miniBarAutoExpand;
                    this.update((s: AppSettings): void => {
                      s.miniBarAutoExpand = v;
                    });
                    AppStorage.setOrCreate(STORE_MINI_BAR_AUTO_EXPAND, v);
                    if (turningOn) {
                      this.toast('滑动收放已开启', 1500);
                    }
                  }
                }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0
              })
            }
          }
        }
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
          this.appearanceBarNarrow();
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
    // 内容避让（官方组件级沉浸口径，AboutPage 同款）；内容层避让由 plain padding 自理
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindSheet($$this.showSheet, this.ThemeColorSheetContent(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false
    })
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 经动态 import 后用 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function AppearanceSettingsPageBuilder(): void {
  AppearanceSettingsPage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接 @Builder 引用（编译期校验）。 */
export const AppearanceSettingsPageWrapped: WrappedBuilder<[]> = wrapBuilder(AppearanceSettingsPageBuilder);
