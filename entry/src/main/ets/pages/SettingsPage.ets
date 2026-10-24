/**
 * 设置页（主页面，2026-10-24 二级菜单化改造）：
 * 原本 6 个分组、最多 28 行的长列表按语义拆分，本页只保留两块内容：
 *   1. 「账户」卡：扫码登录行（未登录点击进登录页 'Login' 路由；已登录显示
 *      头像 / 昵称 / 大会员徽标，点击弹菜单退出登录），登录后下方连着三行
 *      登录后能力入口（收藏夹同步 / 观看历史与稍后再看 / 我的关注）；
 *   2. 设置入口卡（iOS 设置风格彩色圆角图标行）：播放设置 / 下载与存储 /
 *      外观设置 / 歌单备份 / 关于本项目，点击分别推入对应二级页。
 *
 * 二级页（各自独立文件，懒加载注册见 service/LazyPageRegistry.ets）：
 *   · PlaybackSettingsPage（'PlaybackSettings'）—— 原「播放」卡 10 行；
 *   · DownloadSettingsPage（'DownloadSettings'）—— 原「下载」卡 3 行；
 *   · AppearanceSettingsPage（'AppearanceSettings'）—— 原「外观」卡 8 行；
 *   · PlaylistBackupPage（'PlaylistBackup'）—— 原「歌单备份」卡 3 行；
 *   · AboutPage（'About'，原有）—— 关于页。
 * 拆分后本页不再持有 AppSettings 状态：所有开关 / 值展示都在二级页里，
 * 主题色运行时值经 AppStorage（STORE_THEME_*）订阅刷新，跨页无同步负担。
 *
 * 「账户」分组：本页是 Tabs 常驻页，登录态变化靠 STORE_LOGIN_REV 版本号 +
 * @Watch 驱动刷新（aboutToAppear 只触发一次）。
 *
 * 简约 iOS 风格：组件见 components/InsetCardGroup.ets；固定栏（THIN 毛玻璃，
 * 低版本实底兜底）「设置」小标题常显 —— 与 Playlists / Downloads 同套交互。
 */

import { bundleManager } from '@kit.AbilityKit';
import { Chip, ChipSize } from '@kit.ArkUI';
import { BusinessError } from '@ohos.base';
import {
  CONTENT_END_OFFSET,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_LOGIN_REV,
  STORE_THEME_PRIMARY,
  STORE_THEME_ON
} from '../common/Constants';
import { getLoginUser, isLoggedIn, isLoginStale, refreshLoginUser, logout, LoginUser } from '../service/LoginStore';
import { NavStackHolder } from '../service/NavStackHolder';
import { LoginRouteParam } from '../service/NavRouteParams';
import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { showAppToast } from '../components/AppToast';
import { showAppAlertDialog } from '../components/AppAlertDialog';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
// 2026-10-23 平板模式宽度适配：设置页签内容列上限与根顶栏（immersiveTitleBarNarrow）
// 及其他页签统一走 840 口径（TwoColumnLayout.contentMaxWidth）。
import { TwoColumnLayout } from '../common/utils/TwoColumnList';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { InsetCard, CardDivider, SectionHeader } from '../components/InsetCardGroup';

/**
 * 设置入口行的图标底色（iOS 设置风格：每行固定异色，深浅色模式通用；
 * 图标字形为白色 SymbolGlyph，对比度充分）。
 */
const ICON_BG_PINK: string = '#FB7299';
const ICON_BG_BLUE: string = '#3478F6';
const ICON_BG_PURPLE: string = '#AF52DE';
const ICON_BG_GREEN: string = '#34C759';
const ICON_BG_GRAY: string = '#8E8E93';
/** 登录后能力三行专用异色（iOS 系统色板：橙 / 青 / 靛） */
const ICON_BG_ORANGE: string = '#FF9500';
const ICON_BG_TEAL: string = '#30B0C7';
const ICON_BG_INDIGO: string = '#5E5CE6';

/** 入口行图标容器边长与圆角（vp）：约 iOS 设置图标的视觉比例 */
const ENTRY_ICON_SIZE: number = 28;
const ENTRY_ICON_RADIUS: number = 7;

@Component
export struct SettingsPage {
  /** 底部安全区高度（vp）：根容器不再统一避让，列表末尾让位要自己叠上这一份 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /**
   * 状态栏高度（vp）：固定栏材质 Row 内部 padding 用它让材质从 y=0 铺起覆盖状态栏；
   * 本页内容避让是常量（无 onAreaChange 实测），内容层 padding 需显式 +safeTop。
   */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 当前横竖屏（Index 常驻注册写入）：内容列 840 口径取值用（2026-10-23） */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;
  /**
   * 主题色运行时值（EntryAbility 启动发布、外观设置页选色 / 切深浅模式重发布）。
   * 本页消费点（账户占位头像底色 / 会籍徽标）跟随刷新。
   */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /**
   * 登录态版本号（LoginStore 写入）：本页 Tabs 常驻、aboutToAppear 只触发一次，
   * 扫码登录返回后的「账户」分组刷新全靠这个信号。
   */
  @StorageProp(STORE_LOGIN_REV) @Watch('onLoginRevChanged') loginRev: number = 0;
  /** 当前登录用户（null = 未登录）；由 LoginStore 的缓存提供 */
  @State loginUser: LoginUser | null = null;
  /**
   * 登录已失效（2026-10-08）：本地有 Cookie 但被服务端拒绝过一次（nav -101）。
   *
   * 与 `loginUser === null`（从未登录）**必须分开**：前者凭据还在、点一下重新登录即可，
   * 后者是根本没登录过。见 LoginStore.refreshLoginUser / isLoginStale。
   */
  @State loginStale: boolean = false;

  /** 应用版本号（如「v1.0.2」）：从 bundleManager 读，跟着 app.json5 走，不在页面里写死 */
  @State appVersion: string = '';

  /**
   * 列表滚动控制器：批 3 起交给**根 HdsNavigation 的统一标题栏**联动。
   * 2026-10-11 起 List 直接挂 TabScrollerHolder.settings（唯一真源，身份恒定），
   * 不再 new 私有实例后注册替换——替换会让根栏绑定在注册前求值拿到未挂载的占位实例。
   */

  aboutToAppear(): void {
    // 登录态：同步读缓存渲染首帧；已登录则顺带做一次懒校验（nav 拉最新昵称/头像，
    // Cookie 被服务端拒绝时**不再清凭据**，只标 loginStale）。fire-and-forget。
    this.refreshLoginUi();
    setTimeout((): void => {
      if (isLoggedIn()) {
        refreshLoginUser();
      }
    }, 0);
    this.loadAppVersion();
  }

  /** 登录/退出/用户信息更新（LoginStore 广播版本号）：重读缓存刷新「账户」分组 */
  onLoginRevChanged(): void {
    this.refreshLoginUi();
  }

  /** 一次性刷新「账户」分组的两个状态字段（用户信息 + 是否已失效） */
  private refreshLoginUi(): void {
    this.loginUser = getLoginUser();
    this.loginStale = isLoginStale();
  }

  /** 读自身包信息取 versionName（即 app.json5 的 versionName，升级后自动同步） */
  private loadAppVersion(): void {
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info: bundleManager.BundleInfo): void => {
        this.appVersion = info.versionName.length > 0 ? `v${info.versionName}` : '';
      })
      .catch((e: BusinessError): void => {
        // 拿不到就空着，不影响其它设置项
        console.error(`getBundleInfoForSelf failed: ${e.code} ${e.message}`);
      });
  }

  /** 已登录时点击账户行：确认退出（本地凭据 + B 站服务端会话一并撤销） */
  private confirmLogout(): void {
    showAppAlertDialog(this.getUIContext(), {
      title: '退出登录',
      message: '将清除本机保存的登录凭据，并撤销 B 站服务端会话。',
      primaryButton: {
        value: '取消'
      },
      secondaryButton: {
        value: '退出登录',
        action: (): void => {
          this.doLogout();
        }
      }
    });
  }

  private doLogout(): void {
    this.toast('已退出登录', 1500);
    // fire-and-forget：logout 内含撤销会话的网络请求（最长 15s），
    // 本地清理在响应后完成并广播版本号，UI 由 @Watch 自动回落到未登录态
    logout();
  }

  /**
   * 推登录页并挂 onPop 返回回调（2026-10-22 Navigation 差距收敛）：
   * 登录页无论登录成功与否返回，都幂等重读一次登录态刷新「账户」分组
   * （refreshLoginUi 只重读缓存，无副作用，重复调用安全）。正常路径
   * STORE_LOGIN_REV 的 @Watch 已刷新，这里是双保险；用户没登录直接
   * 返回时 @Watch 不触发，靠这里兜住。
   */
  private pushLoginWithRefresh(): void {
    NavStackHolder.stack.pushPathByName('Login', new LoginRouteParam(),
      (info: PopInfo): void => {
        this.refreshLoginUi();
      });
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /**
   * 设置入口行（iOS 设置风格）：左侧固定异色圆角小图标（白色 SymbolGlyph 字形）+
   * 标题 + 右侧灰色箭头。手写行而非 HdsListItemCard —— 该组件 B 区只支持
   * 「文本 + Symbol」，放不下彩色图标前缀（账户行同款教训，观感参数对齐
   * HDS 行：16/13 内边距 + press_overlay 按压反馈）。
   *
   * @param title 入口标题
   * @param glyph 图标字形（sys.symbol 资源）
   * @param iconColor 图标底色（固定异色常量）
   * @param onTap 点击回调（推入对应二级页）
   */
  @Builder
  IconEntryRow(title: string, glyph: Resource, iconColor: string, onTap: () => void) {
    Row() {
      Row() {
        SymbolGlyph(glyph)
          .fontSize(17)
          .fontColor([Color.White])
      }
      .width(ENTRY_ICON_SIZE)
      .height(ENTRY_ICON_SIZE)
      .borderRadius(ENTRY_ICON_RADIUS)
      .backgroundColor(iconColor)
      .justifyContent(FlexAlign.Center)

      Text(title)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 12 })
        .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('app.color.text_tertiary')])
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .accessibilityText(title)
    .accessibilityLevel('yes')
    .onClick((): void => {
      onTap();
    })
  }

  /**
   * 「关于本项目」入口行：IconEntryRow 的带值变体 —— 箭头前显示版本号
   * （@State appVersion 动态值，成员直读保证 loadAppVersion 完成后刷新；
   * 不走 @Builder 按值传参，值参数不会触发刷新）。
   */
  @Builder
  AboutEntryRow() {
    Row() {
      Row() {
        SymbolGlyph($r('sys.symbol.info_circle_fill'))
          .fontSize(17)
          .fontColor([Color.White])
      }
      .width(ENTRY_ICON_SIZE)
      .height(ENTRY_ICON_SIZE)
      .borderRadius(ENTRY_ICON_RADIUS)
      .backgroundColor(ICON_BG_GRAY)
      .justifyContent(FlexAlign.Center)

      Text('关于本项目')
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 12 })
        .layoutWeight(1)

      if (this.appVersion.length > 0) {
        Text(this.appVersion)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .margin({ right: 4 })
      }

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('app.color.text_tertiary')])
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .accessibilityText(`关于本项目 ${this.appVersion}`)
    .accessibilityLevel('yes')
    .onClick((): void => {
      NavStackHolder.stack.pushPath({ name: 'About' });
    })
  }

  /**
   * 账户行头像（手写行的左侧）：已登录 → 真实头像；
   * 未登录 → 品牌粉圆形 + 音符占位（与关于页 App 图标同款）。
   */
  @Builder
  accountAvatar(): void {
    if (this.loginUser !== null) {
      Image(this.loginUser.face)
        .width(44)
        .height(44)
        .borderRadius(22)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('app.color.bg_page'))
        .alt($r('app.media.app_icon'))
    } else {
      Row() {
        SymbolGlyph($r('sys.symbol.waveform'))
          .fontSize(20)
          .fontColor([this.themeOn])
      }
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor(this.themePrimary)
        .justifyContent(FlexAlign.Center)
    }
  }

  /**
   * 会籍徽标文案：'' = 不显示徽标。
   * nav 的 vipType 区分月度（1）/ 年度（2）；老版本落盘数据没有该字段时按「大会员」显示，
   * 下一次 refreshLoginUser 补上真实值（见 LoginUser.vipType 注释）。
   */
  private memberLabel(): string {
    const u: LoginUser | null = this.loginUser;
    if (u === null || u.vipStatus !== 1) {
      return '';
    }
    return u.vipType >= 2 ? '年度大会员' : '大会员';
  }

  /**
   * 账户行第二行＝动作提示：
   *   未登录 → 登录引导；已登录 → 「退出登录」；
   *   待重验 → 「重新登录」（凭据失效时用户要的是重新登录，不是清凭据）。
   */
  private accountHint(): string {
    if (this.loginUser === null) {
      return '扫码登录，可解锁更高音质档位';
    }
    return this.loginStale ? '登录已失效 · 重新登录' : '退出登录';
  }

  build() {
    Stack() {
      // 内容层：账户卡 + 设置入口卡（标题常驻固定栏，内容滚动即可）
      Column() {
        List({ scroller: TabScrollerHolder.settings }) {
          // 顶部空白占位条目（下载页同款）：列表视口铺满全屏，条目起始位置在屏幕
          // 顶端（y=0）。占位高度 = 根标题栏（safeTop + 56），首个真实条目恰从栏底
          // 起排（静置位与旧 contentStartOffset 等值），滚动时占位与条目一起从
          // 模糊板下方穿过。
          ListItem() {
            // Blank 只能嵌在 Row/Column/Flex 内（编译器 10905201），ListItem 直下用定高 Row。
            Row()
              .width('100%')
              .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)
          }
          // ── 账户（扫码登录）──
          ListItem() {
            SectionHeader({ headerText: '账户' })
          }
          ListItem() {
            InsetCard() {
              // 账户行（2026-10-11 手写行）：
              //   为什么不用 HdsListItemCard —— 该组件 B 区只支持「文本 + Symbol」，
              //   放不下「昵称 + 会籍徽标」；用 TextItemOptions.customBuilder 时 HDS 会把
              //   自定义内容渲染到标准文本区之外（昵称/徽标落到头像下面一行，且 C 区的
              //   SuffixButton 也不渲染）。所以这一行回到手写，只沿用 HDS 行的观感参数
              //  （16/13 内边距 + press_overlay 按压反馈），与上下其它行视觉一致。
              // 版式：头像 | 第一行「昵称 + 会籍徽标」、第二行「退出登录」（未登录＝登录引导）。
              Row() {
                this.accountAvatar()

                Column() {
                  Row() {
                    Text(this.loginUser !== null ? this.loginUser.uname : '登录 B 站账号')
                      .fontSize(16)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    // 会籍徽标（Chip 复用）：月度「大会员」/ 年度「年度大会员」
                    if (this.memberLabel().length > 0) {
                      Row() {
                        Chip({
                          label: {
                            text: this.memberLabel(),
                            fontSize: 11,
                            fontColor: this.themeOn
                          },
                          size: ChipSize.SMALL,
                          allowClose: false,
                          backgroundColor: this.themePrimary
                        })
                      }
                      .margin({ left: 6 })
                      .hitTestBehavior(HitTestMode.None)
                    }
                  }
                  .alignItems(VerticalAlign.Center)

                  // 第二行＝动作提示：未登录「扫码登录…」/ 已登录「退出登录」/ 待重验「重新登录」
                  Text(this.accountHint())
                    .fontSize(11)
                    .fontColor($r('app.color.text_tertiary'))
                    .margin({ top: 3 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .margin({ left: 12 })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 13, bottom: 13 })
              .stateStyles({
                pressed: { .backgroundColor($r('app.color.press_overlay')) },
                normal: { .backgroundColor(Color.Transparent) }
              })
              .accessibilityText(this.loginUser === null
                ? '登录 B 站账号'
                : (this.loginStale
                  ? `登录已失效，点击重新登录 ${this.loginUser.uname}`
                  : `已登录 ${this.loginUser.uname}，点击退出登录`))
              .accessibilityLevel('yes')
              .onClick((): void => {
                if (this.loginUser === null) {
                  this.pushLoginWithRefresh();
                  return;
                }
                // 待重验态优先去**重新登录**：此时退出登录只会把凭据清掉，
                // 而用户的目标是「让登录重新能用」，不是「我要退出」。
                if (this.loginStale) {
                  this.pushLoginWithRefresh();
                  return;
                }
                this.confirmLogout();
              })

              // 登录后能力三行：未登录不渲染，登录后在账户行下连着出现。
              // 2026-10-24 样式统一：改用与下方设置入口同款 IconEntryRow
              //（彩色圆角图标 + 标题 + 箭头），替换原 HdsListItemCard 纯文字行。
              if (this.loginUser !== null) {
                CardDivider()
                this.IconEntryRow('收藏夹同步', $r('sys.symbol.arrow_clockwise'), ICON_BG_ORANGE, (): void => {
                  NavStackHolder.stack.pushPath({ name: 'CloudSync' });
                })
                CardDivider()
                this.IconEntryRow('观看历史与稍后再看', $r('sys.symbol.clock_fill'), ICON_BG_TEAL, (): void => {
                  NavStackHolder.stack.pushPath({ name: 'WatchHistory' });
                })
                CardDivider()
                this.IconEntryRow('我的关注', $r('sys.symbol.person_2_fill'), ICON_BG_INDIGO, (): void => {
                  NavStackHolder.stack.pushPath({ name: 'Follows' });
                })
              }
            }
          }

          // 卡片间距占位（原 SectionHeader 的节奏位）：入口卡不加分组标题
          //（根固定栏已常显「设置」，再标一次冗余），只保留卡片间距。
          ListItem() {
            Row()
              .width('100%')
              .height(20)
          }

          // ── 设置入口（iOS 风格彩色图标行，点击进二级页）──
          ListItem() {
            InsetCard() {
              this.IconEntryRow('播放设置', $r('sys.symbol.play_fill'), ICON_BG_PINK, (): void => {
                NavStackHolder.stack.pushPath({ name: 'PlaybackSettings' });
              })

              CardDivider()

              this.IconEntryRow('下载与存储', $r('sys.symbol.arrow_down_to_line'), ICON_BG_BLUE, (): void => {
                NavStackHolder.stack.pushPath({ name: 'DownloadSettings' });
              })

              CardDivider()

              this.IconEntryRow('外观设置', $r('sys.symbol.paintpalette_fill'), ICON_BG_PURPLE, (): void => {
                NavStackHolder.stack.pushPath({ name: 'AppearanceSettings' });
              })

              CardDivider()

              this.IconEntryRow('歌单导入', $r('sys.symbol.doc_filled_on_doc'), ICON_BG_GREEN, (): void => {
                NavStackHolder.stack.pushPath({ name: 'PlaylistBackup' });
              })

              CardDivider()

              this.AboutEntryRow()
            }
          }
        }
        .width('100%')
        .layoutWeight(1)
        // 边界回弹（2026-10-08）：到顶/到底的反馈动效
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(10)
        // 顶部根标题栏让位（Sumy 式穿透）：由 List 首个空白占位 ListItem 负责
        //（见上方占位注释，下载页同款），不再使用 contentStartOffset。
        // 底部悬浮页签让位：列表末尾可滚动至悬浮条上方，不被遮挡
        // 页签栏自己抬高了 safeBottom（见 Index.ets），列表末尾要跟着多让这么多
        .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
      }
      .width('100%')
      .height('100%')
      // ⚠️ 不再整体 padding top：列表视口要铺满全屏（List 首个空白占位 ListItem
      // 负责让出标题栏 safeTop + 56），否则条目在栏底被裁掉、滑不进模糊板下方。
      // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp）；
      // 2026-10-23 平板模式宽度适配：上限统一走 TwoColumnLayout.contentMaxWidth
      //（两列激活 840 / 否则 600/720），平板横屏下与根顶栏及其他页签条目列同宽对齐。
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
      // 顶栏由根 HdsNavigation 的统一 titleBar 承担（见 Index.tabTitleRow），
      // 本页只负责把 listScroller 注册给根容器驱动滚动模糊。
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
