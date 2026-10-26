/**
 * 应用图标页（2026-10-25 桌面图标切换）：
 * 利用 API 26 的 alternateIcons 备用图标机制（app.json5 声明 + bundleManager
 * 运行时切换），让用户在默认图标与 4 套预设设计（design/icon：声波柱 / 耳机 /
 * 音频环 / 黑胶）之间切换桌面图标，立即生效、无需发版。
 *
 *   · 数据模型 AppIconOption：key 对应 app.json5 alternateIcons 的 name
 *     （'' = 恢复默认），bg / fg 为预览分层资源；
 *   · 真值源是系统侧（getAlternateIcons 的 enabled 项），不落偏好 —— 杀进程
 *     重进、覆盖升级后回显仍准确；
 *   · API 守卫：setAlternateIcon / getAlternateIcons 均 26.0.0 起步，
 *     deviceInfo.sdkApiVersion < 26 的设备整页降级为不支持提示；
 *   · 错误码：17700308（name 不匹配）/ 17700309（无启用项）/ 17700310（设置
 *     失败）/ 17700311（查询失败），失败路径 toast 带码，方便反馈定位。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，AppearanceSettingsPage
 * 同款骨架）；平台限制：分身应用不支持备用图标（设置页与桌面分身场景不生效）。
 */

import { bundleManager } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import {
  CONTENT_END_OFFSET,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY
} from '../common/Constants';
import { showAppToast } from '../components/AppToast';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { TwoColumnLayout } from '../common/utils/TwoColumnList';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { InsetCard, CardDivider } from '../components/InsetCardGroup';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { BarNarrowShell } from '../components/BarNarrowShell';

/**
 * 备选图标数据模型：key 为 app.json5 alternateIcons 的 name 字段（'' = 默认，
 * setAlternateIcon 传空串恢复），bg / fg 组成预览分层（与 alt_icon_0X.json 同源）。
 */
class AppIconOption {
  readonly key: string;
  readonly label: string;
  readonly subtitle: string;
  readonly bg: Resource;
  readonly fg: Resource;

  constructor(key: string, label: string, subtitle: string, bg: Resource, fg: Resource) {
    this.key = key;
    this.label = label;
    this.subtitle = subtitle;
    this.bg = bg;
    this.fg = fg;
  }
}

@Component
export struct AppIconSettingsPage {
  /** 状态栏高度（vp）：HDS 标题栏 avoidLayoutSafeArea 后栏顶 = safeTop，内容让位量要含它 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：内容末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 当前横竖屏（Index 常驻注册写入）：内容列 840 口径取值用 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;
  /** 品牌色（选中态对勾颜色）：EntryAbility 发布、外观页选色重发布 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /** 当前启用的备用图标名（'' = 默认）。先按默认占位，aboutToAppear 查询系统真值回显 */
  @State selectedName: string = '';
  /** 切换请求进行中（防连点） */
  @State switching: boolean = false;
  /**
   * API 守卫（非状态、只判定一次）：setAlternateIcon / getAlternateIcons 均
   * 26.0.0 起步，compatibleSdkVersion 6.1.0(23) 设备上两接口不存在 → 整页降级。
   */
  private supported: boolean = deviceInfo.sdkApiVersion >= 26;
  /** 滚动控制器：bindToScrollable 绑给 HDS 标题栏，滚动模糊效果依赖此绑定 */
  private pageScroller: Scroller = new Scroller();

  /** 子页转场的横移量（相对页面自身宽度）：转场代理里按 push/pop 方向临时改写 */
  @State navTransX: string = '0%';

  /**
   * 5 个选项：默认（'' 恢复）+ 4 套预设设计。key 与 AppScope/app.json5
   * alternateIcons 的 name 一一对应；副标题沿用 design/app-icon/README.md
   * 的小尺寸可读性结论（04 黑胶 32px 纹理退化需提示）。
   */
  private readonly options: AppIconOption[] = [
    new AppIconOption('', '默认', '原始粉环图标',
      $r('app.media.app_icon_bg'), $r('app.media.app_icon_fg')),
    new AppIconOption('wave_bars', '声波柱', '推荐 · 全尺寸清晰',
      $r('app.media.alt_icon_bg_pink'), $r('app.media.alt_icon_fg_01')),
    new AppIconOption('headphones', '耳机', '识别最快',
      $r('app.media.alt_icon_bg_pink'), $r('app.media.alt_icon_fg_02')),
    new AppIconOption('audio_ring', '音频环', '延续现有环造型',
      $r('app.media.alt_icon_bg_deep'), $r('app.media.alt_icon_fg_03')),
    new AppIconOption('vinyl', '黑胶', '小尺寸下纹理会简化',
      $r('app.media.alt_icon_bg_deep'), $r('app.media.alt_icon_fg_04'))
  ];

  aboutToAppear(): void {
    this.refreshEnabledState();
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /**
   * 查询系统侧当前启用态回显选中（真值源）：enabled=true 的项即当前桌面图标；
   * 全否 / 查询失败保持「默认」占位。切换成功后本地直接赋值，不重复查询。
   */
  private refreshEnabledState(): void {
    if (!this.supported) {
      return;
    }
    bundleManager.getAlternateIcons()
      .then((icons: Array<bundleManager.AlternateIconInfo>) => {
        let enabledName: string = '';
        for (let i = 0; i < icons.length; i++) {
          if (icons[i].enabled) {
            enabledName = icons[i].iconName;
            break;
          }
        }
        this.selectedName = enabledName;
      })
      .catch((e: BusinessError) => {
        console.error(`[AppIcon] getAlternateIcons failed: ${e.code} ${e.message}`);
      });
  }

  /**
   * 选择图标：默认走恢复（setAlternateIcon('')），其余传 alternateIcons 的
   * name。同值不重复切换；inflight 守卫防连点；同步 throw 与 Promise reject
   * 双层兜底（17700308/09/10 见文件头注释）。
   */
  private choose(option: AppIconOption): void {
    if (!this.supported || this.switching || option.key === this.selectedName) {
      return;
    }
    this.switching = true;
    try {
      bundleManager.setAlternateIcon(option.key)
        .then(() => {
          this.switching = false;
          this.selectedName = option.key;
          this.toast(`桌面图标已切换：${option.label}`, 1500);
        })
        .catch((e: BusinessError) => {
          this.switching = false;
          this.toast(`切换失败（${e.code}）：${e.message}`, 2000);
        });
    } catch (e) {
      this.switching = false;
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      this.toast(`切换失败：${msg}`, 2000);
    }
  }

  /**
   * 选项行：48vp 分层预览（bg + fg 叠放、圆角遮罩）+ 名称/副标题 + 官方
   * Radio 单选指示器（主题色）。点击调 choose（同值 / unsupported / 切换中被拦）。
   */
  @Builder
  optionRow(option: AppIconOption) {
    Row({ space: 14 }) {
      Stack() {
        Image(option.bg)
          .width(48)
          .height(48)
        Image(option.fg)
          .width(48)
          .height(48)
      }
      .width(48)
      .height(48)
      .borderRadius(12)
      .clip(true)

      Column({ space: 2 }) {
        Text(option.label)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
        Text(option.subtitle)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 官方单选指示器：checked 表选中，主题色圆点；
      // HitTestMode.None 让点击穿透到行 onClick，交互路径保持唯一
      //（行点击 → choose → selectedName 写 → Radio checked 跟随）。
      Radio({ value: option.key, group: 'appIconGroup' })
        .checked(this.selectedName === option.key)
        .radioStyle({ checkedBackgroundColor: this.themePrimary })
        .width(22)
        .height(22)
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .onClick(() => {
      this.choose(option);
    })
  }

  /** 不支持态整页内容（API < 26）：居中两行文案，不渲染选项。 */
  @Builder
  unsupportedBody() {
    Column({ space: 8 }) {
      Text('当前系统版本不支持更换桌面图标')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text('需 HarmonyOS 26 及以上版本')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ top: 96, left: 24, right: 24 })
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut
   * （AppearanceSettingsPage 同款）。
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

  /** 标题栏内容（titleBar 的 stackBuilder 承载）：「应用图标」标题（返回键为 HDS 默认键） */
  @Builder
  appIconBar() {
    NavTitleRow({ title: '应用图标' })
  }

  /** 标题行收窄容器（BarNarrowShell 共用件，平板模式宽度适配） */
  @Builder
  appIconBarNarrow() {
    BarNarrowShell({ bar: (): void => {
      this.appIconBar()
    } })
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

        if (!this.supported) {
          ListItem() {
            this.unsupportedBody()
          }
        } else {
          // 说明文案：切换语义 + 分身限制（平台约束，提前告知）
          ListItem() {
            Text('选择桌面图标，切换后立即生效。分身应用不支持更换。')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 8 })
          }

          ListItem() {
            InsetCard() {
              this.optionRow(this.options[0])

              CardDivider()

              this.optionRow(this.options[1])

              CardDivider()

              this.optionRow(this.options[2])

              CardDivider()

              this.optionRow(this.options[3])

              CardDivider()

              this.optionRow(this.options[4])
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
          this.appIconBarNarrow();
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
    // 系统返回拦截（与 AppearanceSettingsPage 同款，无 overlay 时走默认 pop）
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让（官方组件级沉浸口径，AboutPage 同款）；内容层避让由 plain padding 自理
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 经动态 import 后用 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function AppIconSettingsPageBuilder(): void {
  AppIconSettingsPage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接 @Builder 引用（编译期校验）。 */
export const AppIconSettingsPageWrapped: WrappedBuilder<[]> = wrapBuilder(AppIconSettingsPageBuilder);
