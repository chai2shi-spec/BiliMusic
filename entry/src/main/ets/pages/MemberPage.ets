/**
 * 会员中心页（设置 → 账户与同步 → 会员中心）。
 *
 * 现阶段只落地「会员身份识别码」：登录 B 站后取 nav 用户信息的 `mid`（UID）
 * 作为后续会员体系的唯一识别码 —— 可查看、可复制，换设备 / 重装后重新登录
 * 仍是同一个 UID，会员状态可以据此还原。
 *
 * 会员开通、权益、校验全部留占位（第三张卡「会员权益」），后续版本接入时
 * 只替换占位行、不动本页结构；识别码读取链路已就绪，不需要改调用方。
 *
 * ⚠️ 当前**不挂任何入口**（2026-11-17 用户要求：「会员中心不显示，暂不留入口」）：
 * 路由 'Member' 已在 LazyPageRegistry 注册、页面可正常工作，只是设置页没有入口行，
 * 也不进预热序列。后续要露出时，在 SettingsPage 账户卡加一行即可：
 *   this.SettingEntryRow('会员中心', $r('sys.symbol.crown_fill'), '',
 *     ENTRY_ACTION_PAGE, (): void => { this.pushPage('Member'); })
 * 并把 'Member' 加回 LazyPageRegistry 的 PRELOAD_ORDER。
 *
 * 顶栏 = HDS 沉浸光感标题栏（与关于 / 打赏页同款）：内容避让用内容首部占位，
 * 滚动驱动自绘渐变模糊层（内容不足一屏时进度恒 0，透明无副作用）。
 */

import {
  STORE_LOGIN_REV,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_DEEP,
  STORE_THEME_SURFACE
} from '../common/Constants';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { BarNarrowShell } from '../components/BarNarrowShell';
import { InsetCard, CardDivider, SectionHeader, SectionFooter } from '../components/InsetCardGroup';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';
import { showAppToast } from '../components/AppToast';
import { copyText } from '../utils/ClipboardUtil';
import { getLoginUser, isLoggedIn, isLoginStale, refreshLoginUser, LoginUser } from '../service/LoginStore';
import { NavStackHolder } from '../service/NavStackHolder';
import { LoginRouteParam } from '../service/NavRouteParams';

/** 头像边长（vp）：比设置页账户行的 44 大一档，让本页身份区成为视觉焦点 */
const MEMBER_AVATAR_SIZE: number = 56;
/** 权益占位图标圆底边长（vp） */
const RIGHT_ICON_SIZE: number = 36;

@Component
export struct MemberPage {
  /** 状态栏高度（vp）：内容首部让开标题栏（safeTop + 56） */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：内容末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;

  /** 入口图标 / 强调文字统一走主题色对（与设置页一致：surface 底 + deep 字） */
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';

  /**
   * 登录态：登录 / 退出 / 失效都会 bump 这个版本号。
   * 本页可能被「点去登录」推到登录页之上，返回时靠它刷新 UID。
   */
  @StorageProp(STORE_LOGIN_REV) @Watch('onLoginRevChanged') loginRev: number = 0;

  @State loginUser: LoginUser | null = null;
  @State loginStale: boolean = false;

  /**
   * 子页转场的横移量（相对页面自身宽度）：常驻 '0%'，
   * 转场代理里按 push/pop 方向临时改写（见 navTransitionDelegate）。
   */
  @State navTransX: string = '0%';

  private memberScroller: Scroller = new Scroller();
  /** 自绘顶栏模糊层进度更新器（滚动高频回调命令式驱动，不标 @State） */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.memberScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  aboutToAppear(): void {
    this.refreshLoginUi();
    this.syncTopBlurProgress();
    // mid / uname / 头像以本地落盘为准，先渲染；联网补一次最新 nav（失败不影响展示）
    setTimeout((): void => {
      if (isLoggedIn()) {
        refreshLoginUser();
      }
    }, 0);
  }

  onLoginRevChanged(): void {
    this.refreshLoginUi();
  }

  private refreshLoginUi(): void {
    this.loginUser = getLoginUser();
    this.loginStale = isLoginStale();
  }

  /** 识别码：登录且有 mid 才有效，其余情况一律「—」（不用 0 冒充 UID） */
  private uidText(): string {
    const u: LoginUser | null = this.loginUser;
    if (u === null || u.mid <= 0) {
      return '—';
    }
    return `${u.mid}`;
  }

  private hasUid(): boolean {
    const u: LoginUser | null = this.loginUser;
    return u !== null && u.mid > 0;
  }

  /** 身份卡副行：已登录显示 UID，未登录 / 失效给出下一步提示 */
  private accountLine(): string {
    if (this.loginUser === null) {
      return '登录 B 站账号后即可获取会员识别码';
    }
    if (this.loginStale) {
      return '登录已失效，重新登录后识别码自动恢复';
    }
    return `UID ${this.uidText()}`;
  }

  /** B 站大会员徽标（与设置页账户行同义：0 普通 / 1 大会员 / 2 年度大会员） */
  private memberBadge(): string {
    const u: LoginUser | null = this.loginUser;
    if (u === null || u.vipStatus !== 1) {
      return '';
    }
    return u.vipType >= 2 ? '年度大会员' : '大会员';
  }

  private isAnnualVip(): boolean {
    const u: LoginUser | null = this.loginUser;
    return u !== null && u.vipType >= 2;
  }

  private vipBadgeColors(): Array<[ResourceColor, number]> {
    const from: string = this.isAnnualVip() ? '#FFE7B15A' : '#FFFF7FA8';
    const to: string = this.isAnnualVip() ? '#FFC98A1E' : '#FFF05C8C';
    const stops: Array<[ResourceColor, number]> = [[from, 0], [to, 1]];
    return stops;
  }

  private copyUid(): void {
    if (!this.hasUid()) {
      showAppToast('登录后可获取会员识别码', 1800);
      return;
    }
    copyText(this.uidText()).then((ok: boolean): void => {
      showAppToast(ok ? `UID 已复制：${this.uidText()}` : '复制失败，请重试', 1800);
    });
  }

  /** 推登录页（登录成功后 STORE_LOGIN_REV 的 @Watch 自动刷新本页） */
  private pushLogin(): void {
    NavStackHolder.stack.pushPathByName('Login', new LoginRouteParam(), (info: PopInfo): void => {
      this.refreshLoginUi();
    });
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut，
   * pop 反向滑出；其余场景（被上层覆盖 / 重新露出）返回 undefined 走系统默认。
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

  /** 标题栏内容（titleBar 的 stackBuilder 承载）：「会员中心」标题（返回键为 HDS 默认键） */
  @Builder
  memberBar() {
    NavTitleRow({ title: '会员中心' })
  }

  /** 标题行收窄容器（BarNarrowShell 共用件，平板模式宽度适配） */
  @Builder
  memberBarNarrow() {
    BarNarrowShell({ bar: (): void => {
      this.memberBar()
    } })
  }

  /** 头像：已登录用真实头像（取不到走本地图标兜底），未登录用主题色圆形 + 音符 */
  @Builder
  memberAvatar() {
    if (this.loginUser !== null && this.loginUser.face.length > 0) {
      Image(this.loginUser.face)
        .width(MEMBER_AVATAR_SIZE)
        .height(MEMBER_AVATAR_SIZE)
        .borderRadius(MEMBER_AVATAR_SIZE / 2)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('app.color.bg_page'))
        .alt($r('app.media.app_icon'))
        .accessibilityLevel('no')
    } else {
      Row() {
        SymbolGlyph($r('sys.symbol.waveform'))
          .fontSize(24)
          .fontColor([this.themeDeep])
      }
      .width(MEMBER_AVATAR_SIZE)
      .height(MEMBER_AVATAR_SIZE)
      .borderRadius(MEMBER_AVATAR_SIZE / 2)
      .backgroundColor(this.themeSurface)
      .justifyContent(FlexAlign.Center)
      .accessibilityLevel('no')
    }
  }

  /**
   * 权益占位行：图标（主题色圆底）+ 标题 + 说明 + 右侧「即将上线」标签。
   * 参数全是静态字面量（见各调用点），满足带参 @Builder 的约束。
   * 当前不可点：占位只表达「以后在这里」，不给按压态避免误以为能进。
   */
  @Builder
  rightPlaceholderRow(glyph: Resource, title: string, desc: string) {
    Row() {
      Row() {
        SymbolGlyph(glyph)
          .fontSize(18)
          .fontColor([this.themeDeep])
      }
      .width(RIGHT_ICON_SIZE)
      .height(RIGHT_ICON_SIZE)
      .borderRadius(RIGHT_ICON_SIZE / 2)
      .backgroundColor(this.themeSurface)
      .justifyContent(FlexAlign.Center)

      Column() {
        Text(title)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(desc)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 3 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12, right: 8 })

      Text('即将上线')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(8)
        .backgroundColor($r('app.color.bg_page'))
        .maxLines(1)
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Scroll(this.memberScroller) {
          Column() {
            // 顶部占位：沉浸后内容穿透进标题栏区域，让位放在内容首部
            // （加在滚动容器外层会把内容裁在栏底缘之下，材质无内容可采样）
            Blank()
              .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)
              .width('100%')

            // ── A 会员身份 ──
            SectionHeader({ headerText: '会员身份' })
            InsetCard() {
              Row() {
                this.memberAvatar()

                Column() {
                  Row() {
                    Text(this.loginUser !== null ? this.loginUser.uname : '未登录')
                      .fontSize(18)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (this.memberBadge().length > 0) {
                      Text(this.memberBadge())
                        .fontSize(11)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(Color.White)
                        .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                        .borderRadius(9)
                        .linearGradient({ angle: 90, colors: this.vipBadgeColors() })
                        .margin({ left: 6 })
                        .maxLines(1)
                        .hitTestBehavior(HitTestMode.None)
                    }
                  }
                  .alignItems(VerticalAlign.Center)

                  Text(this.accountLine())
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                    .margin({ top: 4 })
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 12 })

                // 登录动作：视觉胶囊 44vp 高（无障碍铁律），未登录 / 失效才出现
                if (this.loginUser === null || this.loginStale) {
                  Row() {
                    Text(this.loginStale ? '重新登录' : '去登录')
                      .fontSize(13)
                      .fontColor(this.themeDeep)
                      .maxLines(1)
                  }
                  .height(44)
                  .padding({ left: 16, right: 16 })
                  .borderRadius(22)
                  .backgroundColor(this.themeSurface)
                  .justifyContent(FlexAlign.Center)
                  .stateStyles({
                    pressed: { .opacity(0.6) },
                    normal: { .opacity(1) }
                  })
                  .accessibilityText(this.loginStale ? '重新登录' : '去登录')
                  .accessibilityLevel('yes')
                  .onClick((): void => {
                    this.pushLogin();
                  })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 16, bottom: 16 })
              .alignItems(VerticalAlign.Center)
            }
            SectionFooter({ noteText: '识别码跟着 B 站账号走：换机或重装后重新登录，会员状态可凭同一个 UID 还原。' })

            // ── B 会员识别码 ──
            SectionHeader({ headerText: '会员识别码' })
            InsetCard() {
              Row() {
                Column() {
                  Text('B 站 UID')
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                  Text(this.uidText())
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: 4 })
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Row() {
                  Text('复制')
                    .fontSize(13)
                    .fontColor(this.hasUid() ? this.themeDeep : $r('app.color.text_disabled'))
                    .maxLines(1)
                }
                .height(44)
                .padding({ left: 18, right: 18 })
                .borderRadius(22)
                .backgroundColor(this.hasUid() ? this.themeSurface : $r('app.color.bg_page'))
                .justifyContent(FlexAlign.Center)
                .stateStyles({
                  pressed: { .opacity(0.6) },
                  normal: { .opacity(1) }
                })
                .accessibilityText(this.hasUid() ? '复制会员识别码' : '登录后可复制会员识别码')
                .accessibilityLevel('yes')
                .onClick((): void => {
                  this.copyUid();
                })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .alignItems(VerticalAlign.Center)
            }
            SectionFooter({ noteText: '后续会员开通与校验都以此 UID 为准，请勿公开分享。' })

            // ── C 会员权益（占位，等后续版本接入）──
            SectionHeader({ headerText: '会员权益' })
            InsetCard() {
              this.rightPlaceholderRow($r('sys.symbol.crown_fill'), '无损音质', '更高码率与 FLAC 音源')
              CardDivider()
              this.rightPlaceholderRow($r('sys.symbol.gift_fill'), '专属标识', '头像徽章与会员主题')
              CardDivider()
              this.rightPlaceholderRow($r('sys.symbol.ticket_fill'), '更多权益', '离线下载 / 批量导入等')
            }
            SectionFooter({ noteText: '会员功能正在开发中，当前页面仅展示识别码，权益入口后续开放。' })
          }
          .width('100%')
          // 内容末尾让开底部手势区（到底即结束，不整屏避让）
          .padding({ bottom: this.safeBottom + 16 })
        }
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp）
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
        // 逐帧驱动自绘渐变模糊层（Scroll 版 onDidScroll 三参签名）
        .onDidScroll((xOffset: number, yOffset: number, scrollState: ScrollState): void => {
          this.syncTopBlurProgress();
        })
        .onScrollStop((): void => {
          this.syncTopBlurProgress();
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      // 顶栏渐变模糊层：盖内容之上（z 序低于 HDS titleBar），
      // 进度由滚动回调命令式驱动；内容不足一屏时进度恒 0。
      TopGradientBlurOverlay({
        barHeightVp: this.safeTop + NAV_TITLE_BAR_HEIGHT,
        updater: this.topBlurUpdater
      })
    }
    // HDS 沉浸光感标题栏：材质 / 滚动模糊 / 温控由 HdsTitleBarStyle 决策
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        // 箭头包裹保证 builder 内 this 指向本组件（裸引用会丢失 this）
        stackBuilder: (): void => {
          this.memberBarNarrow();
        }
      }
    })
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定
    .bindToScrollable([this.memberScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 系统返回拦截：播放页 overlay 打开时吞掉返回并发收起请求（留在本页）
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让：目的地级声明布局扩展进系统安全区（官方组件级沉浸口径）
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function MemberPageBuilder(): void {
  MemberPage()
}


/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const MemberPageWrapped: WrappedBuilder<[]> = wrapBuilder(MemberPageBuilder);
