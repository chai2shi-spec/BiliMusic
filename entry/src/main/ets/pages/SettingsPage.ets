/**
 * 设置页（一级入口页）—— 2026-11-09 重设计实施版。
 *
 * 四张卡（2026-11-19 各标题统一为四个字）：
 *   A「账户同步」：账户三态行（未登录 / 已登录 / 登录已失效）+ **云端同步
 *     直达**（无条件渲染，未登录也可见，→ 'HuaweiCloudSync'）+ 登录后才有的
 *     「更多功能」折叠（收藏同步 / 观看历史 / 我的关注 / 收听直播）；
 *   C「常用设置」：播放 / 下载 / 外观 / 首页筛选，行尾回显当前值；
 *   D「数据工具」：歌单备份 / 应用图标 / 报错记录，行尾回显当前值；
 *   E「关于帮助」：5 行常驻卡片（用户 2026-11-09 23:35 定稿：不做折叠）。
 *
 * ⚠️ 两个「同步」是不同功能、不同路由，别合并（design/设置页-重新设计-方案.md §0.1）：
 *   · 云端同步 → 'HuaweiCloudSync' → CloudSyncPage（华为云空间，与登录无关）
 *   · 收藏同步 → 'CloudSync' → FavSyncPage（收藏夹镜像，登录后才渲染）
 *
 * 动作用尾部符号区分：进页 › / 弹窗 ⓘ / 外链 ↗ / 复制 ⧉ / 折叠 ⌄。
 * 图标色不再用 9 个硬编码 iOS 色；全部 18 个入口行**统一**使用
 * STORE_THEME_SURFACE 底 + STORE_THEME_DEEP 字这一对主题色（用户 2026-11-09 23:40
 * 要求颜色一致），随 8 套主题色与深浅模式联动。
 *
 * 值回显：本页不持有 AppSettings 常驻订阅，只在 aboutToAppear / 切页签 / 二级页
 * 返回时一次性读 getter 填 @State 字符串（方案 A）。**动态值不进带参 @Builder 的
 * 参数** —— Builder 只收静态字面量，值在 Builder 体内经 this.entryValueOf(key) 现算。
 *
 * 登录态靠 STORE_LOGIN_REV 的 @Watch 刷新（本页是 Tabs 常驻页，aboutToAppear
 * 只触发一次）；顶栏副行文本经 AppStorage 交给 Index.tabTitleRow 订阅。
 */

import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@ohos.base';
import {
  CONTENT_END_OFFSET,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_LOGIN_REV,
  STORE_ACTIVE_TAB,
  STORE_SUB_PAGE_ACTIVE,
  STORE_SETTINGS_SUBTITLE,
  STORE_THEME_PRIMARY,
  STORE_THEME_DEEP,
  STORE_THEME_SURFACE,
  STORE_THEME_ON,
  STORE_ASR_ENGINE_ID
} from '../common/Constants';
import { AppSettings, ThemeMode } from '../model/MusicModels';
import { AppPreferences } from '../preferences/AppPreferences';
import { themeColorLabel } from '../common/ThemeColors';
import { FeedFilterConfig } from '../model/FeedFilterModels';
import { getFeedFilterConfig } from '../service/HomeFeedFilterStore';
import { getPlaybackLogsNewestFirst } from '../service/PlaybackLogStore';
import { getLastReadAt } from '../service/CloudSyncStore';
import { isCloudDirAvailable } from '../service/CloudDirClient';
import { getLoginUser, isLoggedIn, isLoginStale, refreshLoginUser, logout, LoginUser } from '../service/LoginStore';
import { NavStackHolder } from '../service/NavStackHolder';
import { LoginRouteParam } from '../service/NavRouteParams';
import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { showAppToast } from '../components/AppToast';
import { showConfirm } from '../components/AppAlertDialog';
import { copyText } from '../utils/ClipboardUtil';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { TwoColumnLayout } from '../common/utils/TwoColumnList';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { InsetCard, CardDivider, SectionHeader } from '../components/InsetCardGroup';
import { showFullChangelog } from '../components/WhatsNewDialog';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';

/** 入口行图标容器边长与圆角（vp）：圆角 8 = 规范 sm 档 */
const ENTRY_ICON_SIZE: number = 28;
const ENTRY_ICON_RADIUS: number = 8;

/** 动作类型：决定尾部符号与无障碍播报，点击前即可预判结果 */
const ENTRY_ACTION_PAGE: number = 0;
const ENTRY_ACTION_DIALOG: number = 1;
const ENTRY_ACTION_LINK: number = 2;
const ENTRY_ACTION_COPY: number = 3;
const ENTRY_ACTION_FOLD_ACCOUNT: number = 4;

/**
 * 会籍徽标渐变色对（B 站风格、不随主题）：会籍是身份标识而非 UI 主题色，
 * 用 B 站官方会员色系最易辨识。
 */
const VIP_BADGE_PINK_FROM: string = '#FB7299';
const VIP_BADGE_PINK_TO: string = '#FF9EB8';
const VIP_BADGE_GOLD_FROM: string = '#F7C862';
const VIP_BADGE_GOLD_TO: string = '#E29B2D';

/** 反馈 Q 群号：入口行点按即复制到剪贴板 */
const FEEDBACK_QQ_GROUP: string = '1129926978';

/** PiLink 邀测链接（应用市场邀测页）：确认后经 openLink 跳转，不推二级页 */
const PILINK_INVITE_URL: string =
  'https://appgallery.huawei.com/link/invite-test-wap?taskId=373050494dc80164b4a906ef1cd1544c&invitationCode=XMFbRSukNQ';

function themeModeLabel(mode: ThemeMode): string {
  if (mode === ThemeMode.DARK) {
    return '深色';
  }
  if (mode === ThemeMode.LIGHT) {
    return '浅色';
  }
  return '跟随系统';
}

/** 首页筛选「规则数」口径：名单条数 + 生效的数值阈值 + 激活方案 */
function countFeedRules(cfg: FeedFilterConfig): number {
  let n: number = 0;
  n += cfg.blockUps.length;
  n += cfg.allowUps.length;
  n += cfg.blockTitleKeywords.length;
  n += cfg.allowTitleKeywords.length;
  n += cfg.blockCategories.length;
  n += cfg.allowCategories.length;
  if (cfg.viewMin > 0) {
    n++;
  }
  if (cfg.likeRateMin > 0) {
    n++;
  }
  if (cfg.durationMinSec > 0 || cfg.durationMaxSec > 0) {
    n++;
  }
  if (cfg.pubdateWithinDays > 0) {
    n++;
  }
  if (cfg.activeSchemeId.length > 0) {
    n++;
  }
  return n;
}

/** 相对时间：云同步「上次读取」用，避免显示绝对时间戳 */
function relativeTime(ts: number): string {
  const delta: number = Date.now() - ts;
  if (delta < 60 * 1000) {
    return '刚刚';
  }
  if (delta < 60 * 60 * 1000) {
    return `${Math.floor(delta / (60 * 1000))} 分钟前`;
  }
  if (delta < 24 * 60 * 60 * 1000) {
    return `${Math.floor(delta / (60 * 60 * 1000))} 小时前`;
  }
  return `${Math.floor(delta / (24 * 60 * 60 * 1000))} 天前`;
}

@Component
export struct SettingsPage {
  /** 底部安全区高度（vp）：列表末尾让位要自己叠上这一份 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 状态栏高度（vp）：自绘顶栏材质从 y=0 铺起 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 当前断点 / 横竖屏：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;
  /** 主题色运行时值：图标成对 token 随 8 套主题色 + 深浅模式刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /** 登录态版本号：扫码登录 / 退出 / 失效广播后刷新账户区 */
  @StorageProp(STORE_LOGIN_REV) @Watch('onLoginRevChanged') loginRev: number = 0;
  /** 页签切换：切回设置页时补刷一次值回显（二级页改动可能发生在别的页签） */
  @StorageProp(STORE_ACTIVE_TAB) @Watch('onActiveTabChanged') activeTab: number = 0;
  /**
   * 二级页出栈信号（NavStackHolder.setInterception 发布，Index 同款订阅）。
   * ⚠️ 值回显「实时刷新」的主通道：pushPathByName 的 onPop 只覆盖自己 push 的页，
   * 系统返回键 / NavStackHolder.pop() / replace 路径都靠这个信号兜住。
   */
  @StorageProp(STORE_SUB_PAGE_ACTIVE) @Watch('onSubPageActiveChanged') subPageActive: boolean = false;

  @State loginUser: LoginUser | null = null;
  /** 本地有 Cookie 但被服务端拒过一次：与「从未登录」必须分开 */
  @State loginStale: boolean = false;
  @State appVersion: string = '';
  @State accountExpanded: boolean = false;

  /** 值回显快照（只在 refreshValues 里写，Builder 体内直读） */
  @State valueCloudSync: string = '';
  @State valuePlayback: string = '';
  @State valueDownload: string = '';
  @State valueAppearance: string = '';
  @State valueFilter: string = '';
  @State valuePlaylists: string = '';
  @State valueLogs: string = '';
  /** 值版本号：每轮 refreshValues 递增，供带参 @Builder 体内的方法建立状态依赖 */
  @State valuesRev: number = 0;

  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (TabScrollerHolder.settings.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  aboutToAppear(): void {
    this.refreshLoginUi();
    this.refreshValues();
    this.syncTopBlurProgress();
    setTimeout((): void => {
      if (isLoggedIn()) {
        refreshLoginUser();
      }
    }, 0);
    this.loadAppVersion();
  }

  onLoginRevChanged(): void {
    this.refreshLoginUi();
  }

  /** 切页签一律补刷：全是内存态 getter，无 IO，多刷几次无副作用 */
  onActiveTabChanged(): void {
    this.refreshValues();
  }

  /** 二级页关闭（true → false）时重读全部 getter —— 值回显实时刷新的主通道 */
  onSubPageActiveChanged(): void {
    if (!this.subPageActive) {
      this.refreshValues();
    }
  }

  private refreshLoginUi(): void {
    this.loginUser = getLoginUser();
    this.loginStale = isLoginStale();
    this.updateSettingsSubtitle();
  }

  /** 顶栏副行：版本号 + 登录三态，交给 Index.tabTitleRow 订阅显示 */
  private updateSettingsSubtitle(): void {
    const version: string = this.appVersion.length > 0 ? this.appVersion : 'BiliMusic';
    let state: string = '未登录';
    if (this.loginUser !== null) {
      state = this.loginStale ? '登录已失效' : '已登录';
    }
    AppStorage.setOrCreate<string>(STORE_SETTINGS_SUBTITLE, `${version} · ${state}`);
  }

  private loadAppVersion(): void {
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info: bundleManager.BundleInfo): void => {
        this.appVersion = info.versionName.length > 0 ? `v${info.versionName}` : '';
        this.updateSettingsSubtitle();
      })
      .catch((e: BusinessError): void => {
        console.error(`getBundleInfoForSelf failed: ${e.code} ${e.message}`);
      });
  }

  /** 一次性刷新全部值回显（方案 A：不常驻订阅 AppSettings，跨页零同步负担） */
  private refreshValues(): void {
    const s: AppSettings = AppPreferences.getSettings();
    this.valuePlayback = `${s.playQuality} · ${s.autoPlay ? '自动连播' : '手动切歌'}`;
    this.valueDownload = `${s.downloadQuality} · ${s.wifiOnlyDownload ? '仅 WiFi' : '任意网络'}`;
    this.valueAppearance = `${themeModeLabel(s.themeMode)} · ${themeColorLabel(s.themeColor)}`;
    const cfg: FeedFilterConfig = getFeedFilterConfig();
    this.valueFilter = cfg.enabled ? `${countFeedRules(cfg)} 条规则` : '未开启';
    const playlists: object[] = AppPreferences.getPlaylists<object>();
    this.valuePlaylists = `${playlists.length} 个歌单`;
    this.valueLogs = `${getPlaybackLogsNewestFirst().length} 条`;
    const lastRead: number = getLastReadAt();
    if (!isCloudDirAvailable()) {
      this.valueCloudSync = '未开启 · 三步开启';
    } else if (lastRead > 0) {
      this.valueCloudSync = `上次同步 ${relativeTime(lastRead)}`;
    } else {
      this.valueCloudSync = '等待首次同步';
    }
    // 递增版本号：带参 @Builder 体内只调用 entryValueOf()，靠它读 @State
    // 建立依赖，避免「值写进去了但行 UI 不重渲染」。
    this.valuesRev++;
  }

  /** Builder 体内现算当前值：key 是静态字面量，状态依赖落在 this 上 */
  private entryValueOf(key: string): string {
    // 读一次 valuesRev，确保本方法在 Builder 渲染链上订阅状态变化
    const rev: number = this.valuesRev;
    if (rev < 0) {
      return '';
    }
    if (key === 'cloud') {
      return this.valueCloudSync;
    }
    if (key === 'playback') {
      return this.valuePlayback;
    }
    if (key === 'download') {
      return this.valueDownload;
    }
    if (key === 'appearance') {
      return this.valueAppearance;
    }
    if (key === 'filter') {
      return this.valueFilter;
    }
    if (key === 'playlists') {
      return this.valuePlaylists;
    }
    if (key === 'logs') {
      return this.valueLogs;
    }
    if (key === 'asr') {
      // 当前引擎随 STORE_ASR_ENGINE_ID 变化；这里现算短标签，不进带参 Builder
      const id: string = AppStorage.get<string>(STORE_ASR_ENGINE_ID) ?? 'system';
      return id === 'system' ? '系统识别' : '第三方模型';
    }
    if (key === 'version') {
      return this.appVersion;
    }
    if (key === 'qq') {
      return FEEDBACK_QQ_GROUP;
    }
    return '';
  }

  /** 消歧副标题：两个「同步」靠它区分，其余行为空 */
  private subtitleOf(title: string): string {
    if (title === '云端同步') {
      return '华为云空间 · 自动备份';
    }
    if (title === '收藏同步') {
      return '收藏夹 → 本地歌单';
    }
    return '';
  }

  private actionText(action: number): string {
    if (action === ENTRY_ACTION_PAGE) {
      return '进入下一页';
    }
    if (action === ENTRY_ACTION_DIALOG) {
      return '弹窗';
    }
    if (action === ENTRY_ACTION_LINK) {
      return '将在浏览器打开';
    }
    if (action === ENTRY_ACTION_COPY) {
      return '复制到剪贴板';
    }
    return '展开或收起';
  }

  /** 全部入口图标统一：主题 surface 底 + 主题 deep 字（成对 token，深浅两套值已在 ThemeColors.ts 配好） */
  private iconBackground(): ResourceColor {
    return this.themeSurface;
  }

  private iconForeground(): ResourceColor {
    return this.themeDeep;
  }

  /** 统一推二级页，并在返回时补刷一次值回显 */
  private pushPage(name: string): void {
    NavStackHolder.stack.pushPathByName(name, undefined, (info: PopInfo): void => {
      this.refreshValues();
    });
  }

  private confirmLogout(): void {
    showConfirm(this.getUIContext(), {
      title: '退出登录',
      message: '将清除本机保存的登录凭据，并撤销 B 站服务端会话。',
      confirmText: '退出登录',
      onConfirm: (): void => {
        this.doLogout();
      }
    });
  }

  private doLogout(): void {
    showAppToast('已退出登录', 1500);
    logout();
  }

  /** 推登录页并挂 onPop 兜底刷新（正常路径由 STORE_LOGIN_REV 的 @Watch 刷新） */
  private pushLoginWithRefresh(): void {
    NavStackHolder.stack.pushPathByName('Login', new LoginRouteParam(),
      (info: PopInfo): void => {
        this.refreshLoginUi();
      });
  }

  private confirmPiLinkJump(): void {
    showConfirm(this.getUIContext(), {
      title: '前往 PiLink 邀测',
      message: 'PiLink 是原生鸿蒙精简版 B 站。是否跳转应用市场参与邀测？',
      confirmText: '前往',
      onConfirm: (): void => {
        this.openPiLinkInvite();
      }
    });
  }

  private async openPiLinkInvite(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await ctx.openLink(PILINK_INVITE_URL);
    } catch (e) {
      console.error(`open PiLink invite failed: ${JSON.stringify(e)}`);
      showAppToast('无法打开链接', 1800);
    }
  }

  private copyFeedbackGroup(): void {
    copyText(FEEDBACK_QQ_GROUP).then((ok: boolean): void => {
      showAppToast(ok ? `群号已复制：${FEEDBACK_QQ_GROUP}` : '复制失败，请重试', 1800);
    });
  }

  private memberLabel(): string {
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
    const from: string = this.isAnnualVip() ? VIP_BADGE_GOLD_FROM : VIP_BADGE_PINK_FROM;
    const to: string = this.isAnnualVip() ? VIP_BADGE_GOLD_TO : VIP_BADGE_PINK_TO;
    const stops: Array<[ResourceColor, number]> = [[from, 0], [to, 1]];
    return stops;
  }

  private accountHint(): string {
    return this.loginUser === null ? '扫码登录，可解锁更高音质档位' : '';
  }

  /** 账户行头像：已登录用真实头像，未登录用品牌色圆形 + 音符占位 */
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
   * 统一入口行。⚠️ 参数全部是静态字面量（title / glyph / valueKey /
   * action / 点击回调），动态值一律在 Builder 体内经 this.entryValueOf / this.xxx 现算 ——
   * 带参 @Builder 按值传递，把状态当参数传进来不会刷新。
   */
  @Builder
  SettingEntryRow(title: string, glyph: Resource, valueKey: string,
    action: number, onTap: () => void) {
    Row() {
      Row() {
        SymbolGlyph(glyph)
          .fontSize(17)
          .fontColor([this.iconForeground()])
      }
        .width(ENTRY_ICON_SIZE)
        .height(ENTRY_ICON_SIZE)
        .borderRadius(ENTRY_ICON_RADIUS)
        .backgroundColor(this.iconBackground())
        .justifyContent(FlexAlign.Center)

      Column() {
        Text(title)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.subtitleOf(title).length > 0) {
          Text(this.subtitleOf(title))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
        }
      }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 12 })

      if (this.entryValueOf(valueKey).length > 0) {
        Text(this.entryValueOf(valueKey))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 160 })
          .margin({ right: 4 })
      }

      if (action === ENTRY_ACTION_PAGE) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([$r('app.color.text_secondary')])
      } else if (action === ENTRY_ACTION_DIALOG) {
        SymbolGlyph($r('sys.symbol.info_circle'))
          .fontSize(16)
          .fontColor([$r('app.color.text_secondary')])
      } else if (action === ENTRY_ACTION_LINK) {
        SymbolGlyph($r('sys.symbol.arrow_up_right'))
          .fontSize(16)
          .fontColor([$r('app.color.text_secondary')])
      } else if (action === ENTRY_ACTION_COPY) {
        SymbolGlyph($r('sys.symbol.doc_filled_on_doc'))
          .fontSize(16)
          .fontColor([$r('app.color.text_secondary')])
      } else if (action === ENTRY_ACTION_FOLD_ACCOUNT) {
        // 折叠态是状态变量 → 必须在 Builder 体内现算，不能当参数传
        SymbolGlyph(this.accountExpanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(16)
          .fontColor([$r('app.color.text_secondary')])
      }
    }
      .width('100%')
      // 52vp：真机首屏实测 56vp 会把「关于帮助」折叠卡压到悬浮胶囊下方，
      // 收到 52vp（图标 28 + 上下 12）仍 ≥44vp 命中区，静止态第 4 张卡完整可见。
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.press_overlay')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .accessibilityText(`${title} ${this.entryValueOf(valueKey)} ${this.actionText(action)}`)
      .accessibilityLevel('yes')
      .onClick((): void => {
        onTap();
      })
  }

  build() {
    Stack() {
      Column() {
        List({ scroller: TabScrollerHolder.settings }) {
          // 顶部空白占位：列表视口铺满全屏，首个真实条目恰从根标题栏底起排
          ListItem() {
            Row()
              .width('100%')
              .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)
          }

          // ── A 账户同步 ──
          ListItem() {
            SectionHeader({ headerText: '账户同步' })
          }
          ListItem() {
            InsetCard() {
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
                    if (this.memberLabel().length > 0) {
                      Text(this.memberLabel())
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
                    // 登录已失效：凭据还在，只标 stale，不清空（SETTINGS.md）
                    if (this.loginStale) {
                      Text('登录已失效')
                        .fontSize(11)
                        .fontColor($r('app.color.text_secondary'))
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .borderRadius(8)
                        .backgroundColor($r('app.color.bg_page'))
                        .margin({ left: 6 })
                        .maxLines(1)
                        .hitTestBehavior(HitTestMode.None)
                    }
                  }
                    .alignItems(VerticalAlign.Center)

                  if (this.accountHint().length > 0) {
                    Text(this.accountHint())
                      .fontSize(11)
                      .fontColor($r('app.color.text_secondary'))
                      .margin({ top: 3 })
                  }
                }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  .margin({ left: 12 })

                // 已登录 / 待重验的显式动作：视觉胶囊不变，外层 Row 撑 44vp 高命中区。
                // ⚠️ 宽度**不能固定 44vp**：4 个汉字 13fp + 左右 padding 各 10 ≈ 72vp，
                // 塞进 44vp 会被挤成竖排（用户 2026-11-09 23:51 反馈）。改成 80vp 定宽，
                // 既容得下「退出登录 / 重新登录」横向一行，又 ≥44vp 命中区。
                // 整行右侧 padding 收到 8 让两个热区之间留出缓冲。
                if (this.loginUser !== null) {
                  Row() {
                    Text(this.loginStale ? '重新登录' : '退出登录')
                      .fontSize(13)
                      .fontColor($r('app.color.text_secondary'))
                      .maxLines(1)
                      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                      .borderRadius(14)
                      .backgroundColor($r('app.color.bg_page'))
                      .stateStyles({
                        pressed: { .opacity(0.5) },
                        normal: { .opacity(1) }
                      })
                      .accessibilityText(this.loginStale ? '重新登录' : '退出登录')
                      .accessibilityLevel('yes')
                  }
                    .width(80)
                    .height(44)
                    .justifyContent(FlexAlign.Center)
                    .onClick((): void => {
                      if (this.loginStale) {
                        this.pushLoginWithRefresh();
                        return;
                      }
                      this.confirmLogout();
                    })
                }
              }
                .width('100%')
                .padding({ left: 16, right: 8, top: 13, bottom: 13 })
                .stateStyles({
                  pressed: { .backgroundColor($r('app.color.press_overlay')) },
                  normal: { .backgroundColor(Color.Transparent) }
                })
                .accessibilityText(this.loginUser === null
                  ? '登录 B 站账号'
                  : (this.loginStale
                    ? `登录已失效，点击重新登录 ${this.loginUser.uname}`
                    : `已登录 ${this.loginUser.uname}`))
                .accessibilityLevel('yes')
                .onClick((): void => {
                  if (this.loginUser === null || this.loginStale) {
                    this.pushLoginWithRefresh();
                    return;
                  }
                  this.confirmLogout();
                })

              CardDivider()

              // 决策 1：无条件渲染，未登录也可见可进。与折叠内的收藏同步
              // 是两个独立功能/路由（§0.1 勘误），副标题负责消歧。
              this.SettingEntryRow('云端同步', $r('sys.symbol.icloud'),
                'cloud', ENTRY_ACTION_PAGE, (): void => {
                  this.pushPage('HuaweiCloudSync');
                })

              // 登录后能力收进折叠，避免首屏随登录态跳变（原 4 行等权重铺开）
              if (this.loginUser !== null) {
                CardDivider()
                this.SettingEntryRow('更多功能', $r('sys.symbol.ellipsis_circle'),
                  '', ENTRY_ACTION_FOLD_ACCOUNT, (): void => {
                    this.accountExpanded = !this.accountExpanded;
                  })
                if (this.accountExpanded) {
                  CardDivider()
                  this.SettingEntryRow('收藏同步', $r('sys.symbol.arrow_clockwise'),
                    '', ENTRY_ACTION_PAGE, (): void => {
                      this.pushPage('CloudSync');
                    })
                  CardDivider()
                  this.SettingEntryRow('观看历史', $r('sys.symbol.clock_fill'),
                    '', ENTRY_ACTION_PAGE, (): void => {
                      this.pushPage('WatchHistory');
                    })
                  CardDivider()
                  this.SettingEntryRow('我的关注', $r('sys.symbol.person_2_fill'),
                    '', ENTRY_ACTION_PAGE, (): void => {
                      this.pushPage('Follows');
                    })
                  CardDivider()
                  this.SettingEntryRow('收听直播', $r('sys.symbol.dot_radiowaves_left_and_right'),
                    '', ENTRY_ACTION_PAGE, (): void => {
                      this.pushPage('Live');
                    })
                }
              }
            }
          }

          // ── C 常用设置（4 行值回显）──
          ListItem() {
            SectionHeader({ headerText: '常用设置' })
          }
          ListItem() {
            InsetCard() {
              this.SettingEntryRow('播放设置', $r('sys.symbol.play_fill'),
                'playback', ENTRY_ACTION_PAGE, (): void => {
                  this.pushPage('PlaybackSettings');
                })
              CardDivider()
              this.SettingEntryRow('下载存储', $r('sys.symbol.arrow_down_to_line'),
                'download', ENTRY_ACTION_PAGE, (): void => {
                  this.pushPage('DownloadSettings');
                })
              CardDivider()
              this.SettingEntryRow('外观设置', $r('sys.symbol.paintpalette_fill'),
                'appearance', ENTRY_ACTION_PAGE, (): void => {
                  this.pushPage('AppearanceSettings');
                })
              CardDivider()
              this.SettingEntryRow('首页筛选', $r('sys.symbol.funnel'),
                'filter', ENTRY_ACTION_PAGE, (): void => {
                  this.pushPage('HomeFeedFilter');
                })
            }
          }

          // ── D 数据工具 ──
          ListItem() {
            SectionHeader({ headerText: '数据工具' })
          }
          ListItem() {
            InsetCard() {
              this.SettingEntryRow('歌单备份', $r('sys.symbol.doc_filled_on_doc'),
                'playlists', ENTRY_ACTION_PAGE, (): void => {
                  this.pushPage('PlaylistBackup');
                })
              CardDivider()
              this.SettingEntryRow('应用图标', $r('sys.symbol.waveform'),
                '', ENTRY_ACTION_PAGE, (): void => {
                  this.pushPage('AppIconSettings');
                })
              CardDivider()
              this.SettingEntryRow('报错记录', $r('sys.symbol.doc_text_fill'),
                'logs', ENTRY_ACTION_PAGE, (): void => {
                  this.pushPage('PlaybackLog');
                })
              CardDivider()
              this.SettingEntryRow('转写模型', $r('sys.symbol.waveform'),
                'asr', ENTRY_ACTION_PAGE, (): void => {
                  this.pushPage('AsrModels');
                })
            }
          }

          // ── E 关于帮助（用户 2026-11-09 23:35 定稿：不做折叠，5 行常驻）──
          // 分组标题 + 常驻卡片，与其它三区同构；没有展开/收起状态。
          // 代价：首屏放不下 5 行，靠列表滚动（contentEndOffset 已为胶囊让位）。
          ListItem() {
            SectionHeader({ headerText: '关于帮助' })
          }
          ListItem() {
            InsetCard() {
              this.SettingEntryRow('更新日志', $r('sys.symbol.list_bullet'),
                '', ENTRY_ACTION_DIALOG, (): void => {
                  showFullChangelog();
                })
              CardDivider()
              this.SettingEntryRow('打赏作者', $r('sys.symbol.heart_fill'),
                '', ENTRY_ACTION_PAGE, (): void => {
                  this.pushPage('Reward');
                })
              CardDivider()
              this.SettingEntryRow('应用邀测', $r('sys.symbol.TV_tv'),
                '', ENTRY_ACTION_LINK, (): void => {
                  this.confirmPiLinkJump();
                })
              CardDivider()
              this.SettingEntryRow('关于项目', $r('sys.symbol.info_circle_fill'),
                'version', ENTRY_ACTION_PAGE, (): void => {
                  this.pushPage('About');
                })
              CardDivider()
              this.SettingEntryRow('反馈Q群', $r('sys.symbol.person_2_fill'),
                'qq', ENTRY_ACTION_COPY, (): void => {
                  this.copyFeedbackGroup();
                })
            }
          }
          // 末尾留白：滚到底时最后一行完整露在悬浮胶囊上方
          ListItem() {
            Row()
              .width('100%')
              .height(12)
          }
        }
          .width('100%')
          .layoutWeight(1)
          .edgeEffect(EdgeEffect.Spring)
          .cachedCount(10)
          .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
          .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
            this.syncTopBlurProgress();
          })
          .onScrollStop((): void => {
            this.syncTopBlurProgress();
          })
      }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })

      TopGradientBlurOverlay({
        barHeightVp: this.safeTop + NAV_TITLE_BAR_HEIGHT,
        updater: this.topBlurUpdater
      })
    }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
  }
}
