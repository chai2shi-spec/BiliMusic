/**
 * 设置页：账户（含登录后能力）/ 播放（自动播放、仅 WiFi 播放、播放音质、累计听歌、
 * 最近播放、定时停止播放）/ 下载（仅 WiFi 下载、下载音质、缓存占用与清理）/ 外观 / 歌单备份 / 关于。
 * 2026-10-08 分区整理：登录后能力改为分组卡片样式与其它模块统一，孤儿「定时」「存储」
 * 小节分别并入播放 / 下载卡，错位在下载卡里的播放音质行移回播放卡。
 * 2026-10-14 合并整理：「登录后能力」独立小节并入「账户」—— 未登录只有账户行，
 * 登录后收藏夹同步 / 观看历史与稍后再看 / 我的关注三行在账户行下连着出现。
 *
 * 简约 iOS 风格：设置项按语义分成七组白底圆角卡片（iOS 设置 App 风格，
 * 组件见 components/InsetCardGroup.ets）；固定栏（THIN 毛玻璃，低版本实底
 * 兜底）「设置」小标题常显 —— 与 Playlists / Downloads 同套交互。
 *
 * 「仅 WiFi 下载」只写偏好，**拦截逻辑在 DownloadManager.requestDownload 入口**
 * （见 service/DownloadManager.ts）：开关打开且当前是蜂窝网络时，那次下载请求会带着
 * `blockedReason` 返回，由调用页（搜索页）弹框询问后再带 `ignoreWifiLimit` 重试。
 *
 * 「账户」分组：扫码登录（2026-10 恢复）——未登录点击进登录页（'Login' 路由），
 * 已登录显示头像 / 昵称 / 大会员徽标，点击弹菜单退出登录；账户行下连着三行登录后
 * 能力入口（收藏夹同步 / 观看历史与稍后再看 / 我的关注），未登录不渲染。
 * 本页是 Tabs 常驻页，登录态变化靠 STORE_LOGIN_REV 版本号 + @Watch 驱动刷新
 * （aboutToAppear 只触发一次）。
 */

import common from '@ohos.app.ability.common';
import { bundleManager, ConfigurationConstant } from '@kit.AbilityKit';
import { taskpool } from '@kit.ArkTS';
import { dirSizeTask, clearDirContentsTask } from '../utils/CacheFsTasks';
import { SelectDialog, Chip, ChipSize } from '@kit.ArkUI';
import { BusinessError } from '@ohos.base';
import { AudioQuality, AppSettings, ThemeMode, DEFAULT_APP_SETTINGS, BAR_LAYOUT_HORIZONTAL, BAR_LAYOUT_VERTICAL } from '../model/MusicModels';
import { Playlist } from '../model/MusicModels';
import { AppPreferences } from '../preferences/AppPreferences';
import { MusicPlayer } from '../player/MusicPlayer';
import { NavStackHolder } from '../service/NavStackHolder';
import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { LibraryStore, PlaylistImportResult } from '../service/LibraryStore';
import { copyText, readText } from '../utils/ClipboardUtil';
import {
  CONTENT_END_OFFSET,
  STORE_LIBRARY_REV,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_SLEEP_TIMER_END,
  STORE_LOGIN_REV,
  STORE_THEME_PRIMARY,
  STORE_THEME_DEEP,
  STORE_THEME_SURFACE,
  STORE_THEME_ON,
  STORE_BAR_LAYOUT,
  STORE_MINI_BAR_PROGRESS
} from '../common/Constants';
import {
  THEME_PALETTES,
  ThemePalette,
  publishThemeColors,
  isAppDark,
  themeColorLabel
} from '../common/ThemeColors';
import { getLoginUser, isLoggedIn, isLoginStale, refreshLoginUser, logout, LoginUser } from '../service/LoginStore';
import { showAppToast } from '../components/AppToast';
import { showAppAlertDialog } from '../components/AppAlertDialog';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { InsetCard, CardDivider, SectionHeader, SectionFooter } from '../components/InsetCardGroup';
import {
  HdsListItemCard,
  SuffixArrowIconText,
  SuffixSwitch,
  SuffixText
} from '@kit.UIDesignKit';

const SLEEP_OPTIONS: number[] = [10, 20, 30, 60, 120];

/**
 * 底部半屏面板的种类（bindSheet 单实例复用：打开前先设 kind、再置 showSheet）。
 * 用 enum 而不是字符串联合：ArkTS 严格模式下游离字符串字面量类型不稳。
 */
enum SettingsSheetKind {
  SLEEP = 0,
  THEME_COLOR = 1
}

/**
 * 音质档位（播放 / 下载共用）。
 *
 * `value` 必须与 `AudioQuality` 枚举值逐字一致 —— 它同时就是 AppSettings.playQuality /
 * downloadQuality 的存储值，播放 / 下载内核每次取流都拿它去映射 B 站音频流 id。
 * `short` 是拼进 SelectDialog 单选行标题的短说明（SheetInfo 只有单行 title，
 * 原半屏面板的两行 hint 与脚注折进行标题和弹窗 content，信息不丢）：
 * B 站只提供它已有的档位，个别投稿最高只有 64 kbps，
 * 不写清楚的话用户会以为「选了高音质却还是小文件」是 App 的问题。
 */
interface QualityOption {
  value: string;
  short: string;
}

const QUALITY_OPTIONS: QualityOption[] = [
  { value: AudioQuality.STANDARD, short: '约 64 kbps，最省流量' },
  { value: AudioQuality.HIGH, short: '约 192 kbps，默认' },
  { value: AudioQuality.LOSSLESS, short: '优先 Hi-Res / 杜比' }
];

function formatSleepMinutes(minutes: number): string {
  if (minutes >= 60 && minutes % 60 === 0) {
    return `${minutes / 60} 小时`;
  }
  return `${minutes} 分钟`;
}

function formatRemain(totalSeconds: number): string {
  const sec: number = Math.max(0, totalSeconds);
  const h: number = Math.floor(sec / 3600);
  const m: number = Math.floor((sec % 3600) / 60);
  const s: number = sec % 60;
  const mm: string = m < 10 ? `0${m}` : `${m}`;
  const ss: string = s < 10 ? `0${s}` : `${s}`;
  if (h > 0) {
    return `${h}:${mm}:${ss}`;
  }
  return `${mm}:${ss}`;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  const kb: number = bytes / 1024;
  if (kb < 1024) {
    return `${kb.toFixed(1)} KB`;
  }
  const mb: number = kb / 1024;
  if (mb < 1024) {
    return `${mb.toFixed(1)} MB`;
  }
  return `${(mb / 1024).toFixed(2)} GB`;
}

/**
 * 累计听歌时长的展示文案：满 1 小时按「X 小时 Y 分钟」，不足 1 小时按「X 分钟」，
 * 一分钟都没有（全新安装）显示「暂无记录」。
 */
function formatListenDuration(totalSeconds: number): string {
  const sec: number = Math.max(0, Math.floor(totalSeconds));
  const h: number = Math.floor(sec / 3600);
  const m: number = Math.floor((sec % 3600) / 60);
  if (h > 0) {
    return `${h} 小时 ${m} 分钟`;
  }
  if (m > 0) {
    return `${m} 分钟`;
  }
  return '暂无记录';
}

/**
 * 剪贴板导入授权弹窗（2026-10-16，用户选择的折中方案）。
 *
 * 为什么需要：真机两次复现 —— 普通行点击后静默读剪贴板被系统拦截（getData 只
 * 拿到空串），HarmonyOS 要求读取剪贴板内容必须经系统安全控件 PasteButton 显式
 * 授权，普通 onClick 绕不过去。同时要保留「点击『从剪贴板导入歌单』条目触发」
 * 的入口习惯，于是折中：行点击弹本窗，窗内放系统粘贴按钮，点它完成授权 + 读取。
 *
 * 为什么不塞进 AppAlertDialog：那是「纯文本 + 双按钮」的固定版式（20+ 调用点
 * 共用），安全控件需要专属回调与样式约束，混入会把公共组件改得面目全非。
 * controller 声明与注入遵循 AppAlertDialog.ets 注释里的官方口径
 * （@CustomDialog 结构体必须声明 controller? 属性；真正开关由宿主页的
 * CustomDialogController 成员持有 —— 在 @Component 内部定义时赋值才有效）。
 *
 * 视觉与 AppAlertDialogRoot 同语言：bg_card 底 + 24 圆角 + 主题色文字。
 */
@CustomDialog
struct PasteImportDialog {
  /** 编译器硬性要求（10905211）：@CustomDialog 结构体必须声明 controller 属性；实际开关走宿主页的 controller */
  controller?: CustomDialogController;
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /** 授权成功回调：宿主页注入（关弹窗 → confirmImportPlaylists 读剪贴板） */
  onPasteGranted: () => void = (): void => {};

  build() {
    Column() {
      Column() {
        Text('从剪贴板导入歌单')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.themePrimary)
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text('系统要求先授权才能读取剪贴板，点击下方「粘贴」继续')
          .fontSize(13)
          .fontColor(this.themePrimary)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
          .width('100%')
        // 系统粘贴按钮（安全控件，全局组件无需 import）：
        // ⚠️ 不能对安全控件挂 .margin()，用包装 Row 承载间距；
        // 授权校验红线：文字必须完整显示、前景与背景对比度不能过低
        // （themePrimary 底 + themeOn 字 ≈ 6.4:1，满足）。
        Row() {
          PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
            .fontSize(14)
            .iconSize(16)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .backgroundColor(this.themePrimary)
            .fontColor(this.themeOn)
            .iconColor(this.themeOn)
            .onClick((event: ClickEvent, result: PasteButtonOnClickResult): void => {
              // 先关弹窗再走业务：confirmImportPlaylists 里的确认弹窗 / toast
              // 不会被本弹层盖住。授权令牌不受弹窗关闭影响（授权在点击瞬间生效）。
              this.controller?.close();
              if (result === PasteButtonOnClickResult.SUCCESS) {
                this.onPasteGranted();
              } else {
                showAppToast('剪贴板授权失败，请重试', 1800);
              }
            })
        }
        .width('100%')
        .margin({ top: 24 })
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 24, bottom: 20 })

      Divider()
        .color($r('app.color.bg_divider'))

      Text('取消')
        .fontSize(16)
        .fontColor(this.themePrimary)
        .textAlign(TextAlign.Center)
        .height(48)
        .width('100%')
        .onClick((): void => {
          this.controller?.close();
        })
    }
    .width('86%')
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(24)
    .clip(true)
  }
}

@Component
export struct SettingsPage {
  // 首帧不读磁盘：字段初始化在 build 前同步执行，getSettings 的 getSync 会拖住首屏。
  // 先用默认值占位，aboutToAppear 里延后一拍再读真值（做法同 refreshCacheSize 的缓存统计）。
  // 一帧的默认值闪变可接受；被覆盖写盘的风险由 settingsLoaded + update() 兜底。
  @State settings: AppSettings = DEFAULT_APP_SETTINGS;
  /** 真值是否已从偏好载入：update() 据此防止「默认值被当真值覆盖写盘」 */
  private settingsLoaded: boolean = false;

  /** 底部安全区高度（vp）：根容器不再统一避让，列表末尾让位要自己叠上这一份 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /**
   * 状态栏高度（vp）：固定栏材质 Row 内部 padding 用它让材质从 y=0 铺起覆盖状态栏；
   * 本页内容避让是常量（无 onAreaChange 实测），内容层 padding 需显式 +safeTop。
   */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /**
   * 定时停止的到点时间戳（ms），0 = 未开启。
   * 播放内核只发布这个**结束时刻**，剩余量由本页本地 1s 现算，避免每秒写一次 AppStorage。
   */
  @StorageLink(STORE_SLEEP_TIMER_END) @Watch('onSleepTimerChanged') sleepTimerEnd: number = 0;
  @State sleepRemainText: string = '未开启';
  /**
   * 底部半屏面板开关。
   * 面板内容按 sheetKind 分支（睡眠定时 / 主题色）；音质选择已迁 SelectDialog
   * 标准弹窗（2026-10-11，见 openQualityDialog），不走 bindSheet。
   */
  @State showSheet: boolean = false;
  /** 当前半屏面板内容（bindSheet 单实例复用，打开前设置） */
  @State sheetKind: SettingsSheetKind = SettingsSheetKind.SLEEP;
  /**
   * 主题色运行时值（EntryAbility 启动发布、本页选色 / 切深浅模式重发布）。
   * 本页自己的品牌色消费点（开关选中色 / 徽标 / 账户占位头像）跟随它们刷新。
   */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /**
   * 音质选择弹窗（阶段 3：bindSheet 半屏自绘面板 → SelectDialog 单选弹窗）。
   *
   * SelectDialog 的 selectedIndex / radioContent 是构造时定格的（CustomDialog
   * 参数不支持动态刷新，faqs-arkui-555），而音质随时可能被上一次选择改掉 ——
   * 所以每次打开前按当前值重建 controller，保证选中态新鲜。
   * 「controller 不得重新赋值」针对「旧弹窗还开着就换引用」的复用场景（会关
   * 不掉旧弹窗，见 AppAlertDialog.ets 头注释）；这两个弹窗都是模态的，重新
   * 赋值只发生在行点击时 —— 那一刻弹窗必然已关，不存在悬空的旧弹窗。
   */
  private playQualityDialog: CustomDialogController | null = null;
  private downloadQualityDialog: CustomDialogController | null = null;
  private sleepTicker: number = -1;

  /** 缓存占用文案；已下载音频只做展示，不参与清理 */
  @State cacheText: string = '计算中…';
  /** 存储区块脚注：已下载体积说明 + 清理提示（refreshCacheSize 动态组装） */
  @State storageFooterText: string = '';
  /** 累计听歌时长文案：进页时读一次偏好（计时在 MusicPlayer，播放中不实时刷新） */
  @State listenText: string = '';
  /** 最近播放条数（2026-10-10 从歌单页根栏卡片迁入本组）：@Watch(onLibraryChanged) 刷新 */
  @State recentCount: number = 0;
  private cacheDirPath: string = '';
  /** 应用级缓存目录（…/base/cache），与模块级 cacheDirPath 一起统计 */
  private appCacheDirPath: string = '';
  private downloadDirPath: string = '';
  /**
   * 缓存统计轮次令牌（2026-10-16 AppFreeze 加固）：统计改异步后，
   * 快速进出设置页会有多轮统计在飞，旧轮结果不得覆盖新轮（对比 seq 丢弃）。
   */
  private cacheSizeSeq: number = 0;
  /** 清理进行中（防重入 + 文案「清理中…」）：清理改 TaskPool 异步后必要 */
  @State clearing: boolean = false;

  /** 应用版本号（如「v1.0.2」）：从 bundleManager 读，跟着 app.json5 走，不在页面里写死 */
  @State appVersion: string = '';

  /**
   * 登录态版本号（LoginStore 写入）：本页 Tabs 常驻、aboutToAppear 只触发一次，
   * 扫码登录返回后的「账户」分组刷新全靠这个信号（与歌单页的 STORE_LIBRARY_REV 同模式）。
   */
  @StorageProp(STORE_LOGIN_REV) @Watch('onLoginRevChanged') loginRev: number = 0;
  /**
   * 媒体库版本号（LibraryStore 写入）：播放一首歌 / 清空历史都会 bump——
   * 「最近播放」行的条数副文案靠它刷新（本页 Tabs 常驻，aboutToAppear 只触发一次，
   * 与歌单页订阅同模式）。
   */
  @StorageLink(STORE_LIBRARY_REV) @Watch('onLibraryChanged') libraryRev: number = 0;
  /** 当前登录用户（null = 未登录）；由 LoginStore 的缓存提供 */
  @State loginUser: LoginUser | null = null;
  /**
   * 登录已失效（2026-10-08）：本地有 Cookie 但被服务端拒绝过一次（nav -101）。
   *
   * 与 `loginUser === null`（从未登录）**必须分开**：前者凭据还在、点一下重新登录即可，
   * 后者是根本没登录过。原实现里这两种情况都被 `clearLoginState()` 抹成同一个态，
   * 用户看到的是「莫名其妙变回未登录」，凭据与 refresh_token 也一并丢了。
   * 见 LoginStore.refreshLoginUser / isLoginStale。
   */
  @State loginStale: boolean = false;

  /**
   * 列表滚动控制器：批 3 起交给**根 HdsNavigation 的统一标题栏**联动
   * （内容侧不再自绘模糊板，reveal / onDidScroll 机制已删除）。
   * 2026-10-11 起 List 直接挂 TabScrollerHolder.settings（唯一真源，身份恒定），
   * 不再 new 私有实例后注册替换——替换会让根栏绑定在注册前求值拿到未挂载的占位实例。
   */

  aboutToAppear(): void {
    this.refreshSleepText();
    this.refreshCacheSize();
    // 偏好读取（getSettings / getTotalListenSeconds 都是 getSync 同步 IO）延后一拍，
    // 与字段初始化只放默认值配套：首帧 build 全程零磁盘读。
    setTimeout((): void => {
      this.settings = AppPreferences.getSettings();
      this.settingsLoaded = true;
      this.listenText = formatListenDuration(AppPreferences.getTotalListenSeconds());
      this.recentCount = LibraryStore.getRecentTracks().length;
      // 登录态：同步读缓存渲染首帧；已登录则顺带做一次懒校验（nav 拉最新昵称/头像，
      // Cookie 被服务端拒绝时**不再清凭据**，只标 loginStale）。
      // fire-and-forget，不阻塞页面。
      this.refreshLoginUi();
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

  /** 媒体库变化（LibraryStore 广播版本号）：刷新「最近播放」行的条数副文案 */
  onLibraryChanged(): void {
    this.recentCount = LibraryStore.getRecentTracks().length;
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

  /**
   * 解析沙箱目录（只做一次）。
   *
   * 刻意不放在 aboutToAppear 里取 `getUIContext()`：那时 UIContext 未必已就绪。
   * 改在 refreshCacheSize 里获取，拿不到就下次再试（显示「不可用」，不崩）。
   */
  private resolveDirs(): boolean {
    if (this.cacheDirPath.length > 0) {
      return true;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.Context;
      if (ctx) {
        // 模块级 cacheDir（…/haps/entry/cache）：本应用自己的缓存（含 Image 组件的 image_file_cache）
        this.cacheDirPath = ctx.cacheDir;
        // 应用级 cacheDir（…/base/cache）：ArkUI 框架的 preload_caches / blobShader / rawheap 等。
        // ⚠️ 实测这一层才是占用大头（可达上百 MB），只扫模块级会把缓存显示成 0 B。
        const appCtx = ctx.getApplicationContext();
        if (appCtx && appCtx.cacheDir !== this.cacheDirPath) {
          this.appCacheDirPath = appCtx.cacheDir;
        }
        this.downloadDirPath = `${ctx.filesDir}/downloads`;
        return true;
      }
    } catch (e) {
      console.error('settings: resolve sandbox context failed');
    }
    return false;
  }

  aboutToDisappear(): void {
    this.stopSleepTicker();
  }

  private copySettings(s: AppSettings): AppSettings {
    return {
      sidebarState: s.sidebarState,
      playQuality: s.playQuality,
      downloadQuality: s.downloadQuality,
      downloadDir: s.downloadDir,
      autoPlay: s.autoPlay,
      autoPlayOnStart: s.autoPlayOnStart,
      wifiOnlyDownload: s.wifiOnlyDownload,
      wifiOnlyPlay: s.wifiOnlyPlay,
      themeMode: s.themeMode,
      themeColor: s.themeColor,
      barLayout: s.barLayout,
      miniBarProgress: s.miniBarProgress
    };
  }

  private update(mut: (s: AppSettings) => void): void {
    // 延迟载入尚未完成（用户在首帧内就点了开关）：先同步补读真值。
    // 否则 copy 出去的是默认占位值，saveSettings 会把存量设置整个覆盖掉。
    if (!this.settingsLoaded) {
      this.settings = AppPreferences.getSettings();
      this.settingsLoaded = true;
    }
    const next: AppSettings = this.copySettings(this.settings);
    mut(next);
    this.settings = next;
    AppPreferences.saveSettings(next);
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

  onSleepTimerChanged(): void {
    this.refreshSleepText();
  }

  private refreshSleepText(): void {
    if (this.sleepTimerEnd <= 0) {
      this.sleepRemainText = '未开启';
      this.stopSleepTicker();
      return;
    }
    const remainMs: number = this.sleepTimerEnd - Date.now();
    if (remainMs <= 0) {
      this.sleepRemainText = '未开启';
      this.stopSleepTicker();
      return;
    }
    this.sleepRemainText = `剩余 ${formatRemain(Math.ceil(remainMs / 1000))}`;
    this.startSleepTicker();
  }

  private startSleepTicker(): void {
    if (this.sleepTicker !== -1) {
      return;
    }
    this.sleepTicker = setInterval((): void => {
      this.refreshSleepText();
    }, 1000);
  }

  private stopSleepTicker(): void {
    if (this.sleepTicker !== -1) {
      clearInterval(this.sleepTicker);
      this.sleepTicker = -1;
    }
  }

  private pickSleep(minutes: number): void {
    this.showSheet = false;
    // 计时器归播放内核单例持有：换页 / 重建本组件都不会丢定时
    MusicPlayer.getInstance().setSleepTimer(minutes);
    // 兜底刷新：取消定时时写入的 0 可能与旧值相同，@Watch 不会触发
    setTimeout((): void => {
      this.refreshSleepText();
    }, 0);
  }

  /**
   * 选中音质（播放 / 下载由 isPlay 区分）。只写偏好 —— 真正的取流档位由
   * 播放 / 下载内核在每次任务开始时读取，所以**已在进行中的任务不会中途换档**
   * （换档需要重新解析音源），要生效得重新播放 / 重新下载。
   */
  private pickQuality(value: string, isPlay: boolean): void {
    this.update((s: AppSettings): void => {
      if (isPlay) {
        s.playQuality = value;
      } else {
        s.downloadQuality = value;
      }
    });
    this.toast(`${isPlay ? '播放' : '下载'}音质：${value}`, 1500);
  }

  /**
   * 打开音质选择弹窗（SelectDialog，单选列表 + 取消）。
   * 选中态按当前偏好预选；点选项即生效（写偏好 + toast）并关闭弹窗，
   * 取消按钮 / 点遮罩只关闭不改动。
   */
  private openQualityDialog(isPlay: boolean): void {
    const current: string = isPlay ? this.settings.playQuality : this.settings.downloadQuality;
    const items: SheetInfo[] = [];
    let selectedIndex: number = -1;
    for (let i = 0; i < QUALITY_OPTIONS.length; i++) {
      const opt: QualityOption = QUALITY_OPTIONS[i];
      if (opt.value === current) {
        selectedIndex = i;
      }
      items.push({
        title: `${opt.value} · ${opt.short}`,
        action: (): void => {
          this.pickQuality(opt.value, isPlay);
          if (isPlay) {
            this.playQualityDialog?.close();
          } else {
            this.downloadQualityDialog?.close();
          }
        }
      });
    }
    const dialog: CustomDialogController = new CustomDialogController({
      builder: SelectDialog({
        title: isPlay ? '播放音质' : '下载音质',
        content: isPlay
          ? '在线播放时优先选哪一档；服务端没有该档会自动降级，播放中的歌曲下一首生效。Hi-Res / 杜比需登录（大会员）'
          : 'B 站只提供它已有的档位，个别视频最高只有 64 kbps；已在下载中的任务不会中途换档，重新下载才会生效。Hi-Res / 杜比需登录（大会员）',
        selectedIndex: selectedIndex,
        confirm: {
          value: '取消',
          // ⚠️ 显式 close，不依赖组件内部关闭：真机实测（2026-10-11 阶段 3 验收）
          // confirm 提供空 action 时点击无效果（弹窗不关）——SelectDialog 的
          // confirm.action 会替换而非追加默认关闭行为。radio 行同款显式
          // close 已验证可用；close 幂等，框架若也关一次不会重复。
          action: (): void => {
            if (isPlay) {
              this.playQualityDialog?.close();
            } else {
              this.downloadQualityDialog?.close();
            }
          }
        },
        radioContent: items
      }),
      autoCancel: true
    });
    if (isPlay) {
      this.playQualityDialog = dialog;
    } else {
      this.downloadQualityDialog = dialog;
    }
    dialog.open();
  }

  private refreshCacheSize(): void {
    this.cacheText = '计算中…';
    // 目录解析失败（UIContext 未就绪等）：显示不可用，下次进页再试
    if (!this.resolveDirs()) {
      this.cacheText = '不可用';
      return;
    }
    // 递归统计已迁 TaskPool（2026-10-16 AppFreeze 加固，修审核 THREAD_BLOCK_6S）：
    // 原实现在主线程跑 listFileSync/statSync 递归，image_file_cache 等目录文件数
    // 无上界，主线程可被阻塞 6s+。现主线程只拿最终字节数。
    const seq: number = ++this.cacheSizeSeq;
    const cacheP: Promise<number> = taskpool.execute(dirSizeTask, this.cacheDirPath) as Promise<number>;
    const appCacheP: Promise<number> = taskpool.execute(dirSizeTask, this.appCacheDirPath) as Promise<number>;
    const downloadP: Promise<number> = taskpool.execute(dirSizeTask, this.downloadDirPath) as Promise<number>;
    Promise.all([cacheP, appCacheP, downloadP])
      .then((sizes: number[]): void => {
        if (seq !== this.cacheSizeSeq) {
          // 已被更新一轮统计取代：丢弃过期结果，防止旧值覆盖新值
          return;
        }
        // 两层缓存目录都统计：模块级（应用自己的）+ 应用级（ArkUI 框架的 shader / preload 等）
        const cacheBytes: number = sizes[0] + sizes[1];
        this.cacheText = formatBytes(cacheBytes);
        // 存储提示词（2026-10-14 作「缓存」行副标题，与标题同行展示，精简到一行）：
        // 点击本行清理临时缓存；有已下载歌曲时前置「不受影响」说明
        this.storageFooterText = sizes[2] > 0
          ? '已下载歌曲不受影响，点击清理临时缓存'
          : '点击清理临时缓存';
      })
      .catch((e: Error): void => {
        if (seq !== this.cacheSizeSeq) {
          return;
        }
        console.error(`refresh cache size failed: ${e.message}`);
        this.cacheText = '不可用';
      });
  }

  private confirmClearCache(): void {
    showAppAlertDialog(this.getUIContext(), {
      title: '清理缓存',
      message: '将删除应用临时缓存文件。已下载的歌曲、歌单与播放记录不受影响。',
      primaryButton: {
        value: '取消'
      },
      secondaryButton: {
        value: '清理',
        action: (): void => {
          this.doClearCache();
        }
      }
    });
  }

  private doClearCache(): void {
    // 防重入：上一轮清理还在 TaskPool 里跑时，重复点击直接忽略
    if (this.clearing) {
      return;
    }
    if (!this.resolveDirs()) {
      this.toast('存储信息不可用，请稍后重试', 1800);
      return;
    }
    this.clearing = true;
    this.cacheText = '清理中…';
    // 递归删除已迁 TaskPool（2026-10-16 AppFreeze 加固）：原实现在主线程同步
    // unlinkSync 整个缓存目录，文件多时阻塞 6s+（审核 THREAD_BLOCK_6S 根因候选）。
    const cacheClearP: Promise<number> =
      taskpool.execute(clearDirContentsTask, this.cacheDirPath) as Promise<number>;
    const appCacheClearP: Promise<number> =
      taskpool.execute(clearDirContentsTask, this.appCacheDirPath) as Promise<number>;
    Promise.all([cacheClearP, appCacheClearP])
      .then((removedArr: number[]): void => {
        this.clearing = false;
        // 两层缓存目录都清（只清内容、保留目录本身），清理后再刷新占用展示
        const removed: number = removedArr[0] + removedArr[1];
        this.toast(removed > 0 ? `已清理 ${removed} 个缓存文件` : '没有需要清理的缓存', 1800);
        this.refreshCacheSize();
      })
      .catch((e: Error): void => {
        this.clearing = false;
        console.error(`clear cache failed: ${e.message}`);
        this.toast('清理失败，请稍后重试', 1800);
        this.refreshCacheSize();
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
   * 「登录后能力」一行（2026-10-14 并入账户卡后**只在登录态渲染**：
   * build() 里 `if (this.loginUser !== null)` 控制显隐，未登录整行不出现）。
   *
   * @param title 主标题 16fp
   * @param route 点击后跳转的目标 route
   *
   * 2026-10-11：行内说明副标题全删（设置页提示词精简）——「需要登录」由小节脚注统一说明。
   * 行内未登录分支（promptLogin 引导 / 50% 透明）保留作防御，正常不可达。
   */
  @Builder
  CapabilityRow(title: string, route: string) {
    HdsListItemCard({
      textItem: { primaryText: { text: title } },
      suffixItem: new SuffixArrowIconText({ endArrow: {} }),
      cardBackgroundColor: Color.Transparent,
      cardPrefixMargin: 0,
      cardSuffixMargin: 0,
      onClick: (): void => {
        if (this.loginUser === null) {
          this.promptLogin();
          return;
        }
        NavStackHolder.stack.pushPath({ name: route });
      }
    })
      .opacity(this.loginUser === null ? 0.5 : 1)
      .accessibilityText(`${title}，${this.loginUser === null ? '需登录' : ''}`)
      .accessibilityLevel('yes')
  }

  /** 未登录时点能力入口的引导弹窗（与 confirmLogout 同款双按钮确认弹窗） */
  private promptLogin(): void {
    showAppAlertDialog(this.getUIContext(), {
      title: '需要登录',
      message: '登录 B 站账号后即可使用该功能，登录凭据只保存在本机。',
      primaryButton: {
        value: '取消'
      },
      secondaryButton: {
        value: '去登录',
        action: (): void => {
          NavStackHolder.stack.pushPath({ name: 'Login' });
        }
      }
    });
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /**
   * 底部半屏面板内容：按 sheetKind 分支（睡眠定时 / 主题色）。
   * 保持无参这层是为了避开「带参 @Builder 参数不随状态刷新」的坑；
   * 音质选择已迁 SelectDialog 弹窗（见 openQualityDialog），不再走 bindSheet。
   */
  @Builder
  SheetContent(): void {
    if (this.sheetKind === SettingsSheetKind.THEME_COLOR) {
      this.ThemeColorSheetContent()
    } else {
      this.SleepSheetContent()
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
                  Text('✓')
                    .fontSize(18)
                    .fontColor(Color.White)
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

  @Builder
  SleepSheetContent(): void {
    Column() {
      Text('定时停止播放')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text(this.sleepTimerEnd > 0 ? `当前：${this.sleepRemainText}` : '当前未开启定时')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 4 })

      Column() {
        ForEach(SLEEP_OPTIONS, (minutes: number): void => {
          Row() {
            Text(formatSleepMinutes(minutes))
              .fontSize(16)
              .fontColor($r('app.color.text_primary'))
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 14, bottom: 14 })
          .onClick((): void => {
            this.pickSleep(minutes);
          })
        }, (minutes: number): string => `sleep_${minutes}`)
      }
      .width('100%')
      .margin({ top: 10 })

      Divider()
        .color($r('app.color.bg_divider'))

      Row() {
        Text('关闭定时')
          .fontSize(16)
          .fontColor(this.sleepTimerEnd > 0 ? this.themeDeep : $r('app.color.text_disabled'))
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 14, bottom: 14 })
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.press_overlay')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .onClick((): void => {
        if (this.sleepTimerEnd > 0) {
          this.pickSleep(0);
        }
      })
    }
    .width('100%')
    .padding({ top: 16, bottom: 12 })
  }

  /**
   * 「标题 + 箭头」行（导入 / 导出两行共用）。
   * 2026-10-11：行内提示词全删（设置页只留标题 + 值/开关），语义靠标题本身与小节脚注。
   */
  @Builder
  SettingsRow(title: string, onTap: () => void): void {
    HdsListItemCard({
      textItem: { primaryText: { text: title } },
      suffixItem: new SuffixArrowIconText({ endArrow: {} }),
      cardBackgroundColor: Color.Transparent,
      cardPrefixMargin: 0,
      cardSuffixMargin: 0,
      onClick: (): void => {
        onTap();
      }
    })
      .accessibilityText(title)
      .accessibilityLevel('yes')
  }

  /** 导出：把全部歌单序列化后写进剪贴板 */
  private async exportPlaylists(): Promise<void> {
    const playlists: Playlist[] = LibraryStore.getPlaylists();
    if (playlists.length === 0) {
      this.toast('还没有歌单可以导出', 1800);
      return;
    }
    const text: string = JSON.stringify(LibraryStore.createPlaylistsExport());
    const ok: boolean = await copyText(text);
    if (!ok) {
      this.toast('写入剪贴板失败，请重试', 1800);
      return;
    }
    const tracks: number = playlists.reduce((sum: number, p: Playlist): number => sum + p.tracks.length, 0);
    this.toast(`已复制 ${playlists.length} 个歌单（${tracks} 首）到剪贴板`, 2200);
  }

  /**
   * 剪贴板授权弹窗 controller（2026-10-16）：⚠️ 必须在 @Component 内部定义时
   * 赋值才有效（官方约束，模块级定义会「编译过、open 不显示」的静默失效），
   * 且一经创建不能重新赋值（会导致旧弹窗关不掉）。
   * 授权成功回调链：PasteButton SUCCESS → 关弹窗 → confirmImportPlaylists。
   */
  private pasteDialogCtrl: CustomDialogController = new CustomDialogController({
    builder: PasteImportDialog({
      onPasteGranted: (): void => {
        this.confirmImportPlaylists();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  /**
   * 导入：先读剪贴板看有没有像歌单数据，有则二次确认再落库。
   *
   * 为什么要确认：剪贴板里可能**完全不是**歌单数据（用户刚复制了段文字），
   * 直接 import 会抛 JSON 解析错、用户一头雾水。先看内容再决定。
   */
  private async confirmImportPlaylists(): Promise<void> {
    const text: string = await readText();
    if (text.trim().length === 0) {
      this.toast('剪贴板是空的', 1800);
      return;
    }
    // 只做「像不像」的判断，不真解析：真解析留给 importPlaylistsFromText（它才有完整的
    // 容错与跳过统计）。这里解析失败 → 不是歌单数据，别让用户点完才报错。
    // ⚠️ `JSON.parse` 返回 any，ArkTS 禁止隐式 any（arkts-no-any-unknown）→
    // 必须显式收成 `ESObject`，再 `Array.isArray` 收窄。
    let count: number = -1;
    try {
      const parsed: ESObject = JSON.parse(text);
      const list: ESObject = Array.isArray(parsed) ? parsed : parsed?.playlists;
      if (Array.isArray(list)) {
        count = list.length;
      }
    } catch (e) {
      console.warn(`import clipboard is not json: ${e instanceof Error ? e.message : 'unknown'}`);
    }
    if (count < 0) {
      this.toast('剪贴板里不是歌单数据（需要先「导出歌单」）', 2200);
      return;
    }
    showAppAlertDialog(this.getUIContext(), {
      title: '导入歌单',
      message: `剪贴板里解析到 ${count} 个歌单，将追加到现有歌单列表（重名自动加「导入」后缀）。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '导入',
        action: (): void => {
          this.doImportPlaylists(text);
        }
      }
    });
  }

  private doImportPlaylists(text: string): void {
    try {
      const r: PlaylistImportResult = LibraryStore.importPlaylistsFromText(text);
      if (r.imported === 0 && r.skipped === 0) {
        this.toast('没有可导入的歌单', 1800);
        return;
      }
      const tail: string = r.skipped > 0 ? `，跳过 ${r.skipped} 个无效条目` : '';
      this.toast(`已导入 ${r.imported} 个歌单${tail}`, 2400);
    } catch (e) {
      const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.error(`import playlists failed: ${detail}`);
      this.toast('导入失败：数据格式不正确', 2000);
    }
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
      Text('♪')
        .fontSize(20)
        .fontColor(this.themeOn)
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor(this.themePrimary)
        .textAlign(TextAlign.Center)
    }
  }

  /**
   * 会籍徽标文案（2026-10-11）：'' = 不显示徽标。
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
   * 账户行第二行＝动作提示（2026-10-11）：
   *   未登录 → 登录引导；已登录 → 「退出登录」（替换原「已登录，点击可退出」）；
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
      // 内容层：设置分组列表（标题常驻固定栏，内容滚动即可）
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
              // 账户行（阶段 6，2026-10-11）：整行改由系统标准 HdsListItemCard 承载
              //（A 区头像 / B 区两行文本 / C 区箭头），按压与 hover 反馈由 HDS 统一处理。
              // ⚠️ 昵称后的「大会员」小徽标在 HdsListItemCard 里没有插槽（B 区只支持
              // 文本 + Symbol），徽标语义并入副标题文案，信息不丢。
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
                    // 会籍徽标（阶段 5 的 Chip 复用）：月度「大会员」/ 年度「年度大会员」
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
                  NavStackHolder.stack.pushPath({ name: 'Login' });
                  return;
                }
                // 待重验态优先去**重新登录**：此时退出登录只会把凭据清掉，
                // 而用户的目标是「让登录重新能用」，不是「我要退出」。
                if (this.loginStale) {
                  NavStackHolder.stack.pushPath({ name: 'Login' });
                  return;
                }
                this.confirmLogout();
              })

              // 登录后能力三行（2026-10-14 并入账户卡）：未登录不渲染，登录后在
              // 账户行下连着出现。CapabilityRow 行内的未登录分支（promptLogin /
              // 50% 透明）保留作防御，正常不可达 —— 显隐由这里的 if 统一控制。
              if (this.loginUser !== null) {
                CardDivider()
                this.CapabilityRow('收藏夹同步', 'CloudSync')
                CardDivider()
                this.CapabilityRow('观看历史与稍后再看', 'WatchHistory')
                CardDivider()
                this.CapabilityRow('我的关注', 'Follows')
              }
            }
          }

          // ── 播放 ──
          ListItem() {
            SectionHeader({ headerText: '播放' })
          }
          ListItem() {
            InsetCard() {
              HdsListItemCard({
                textItem: { primaryText: { text: '自动播放下一首' } },
                 suffixItem: new SuffixSwitch({
                   isCheck: this.settings.autoPlay,
                   selectColor: this.themePrimary,
                  onChange: (v: boolean): void => {
                    this.update((s: AppSettings): void => {
                      s.autoPlay = v;
                    });
                  }
                }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0
              })

              CardDivider()

              // 启动时自动播放：冷启动从上次播放的曲目/进度续播（走 MusicPlayer.play()
              // 消费 restoreState 登记的 pendingResumePosition）。默认关 —— 无交互不出声。
              HdsListItemCard({
                textItem: { primaryText: { text: '启动时自动播放' } },
                 suffixItem: new SuffixSwitch({
                   isCheck: this.settings.autoPlayOnStart,
                   selectColor: this.themePrimary,
                  onChange: (v: boolean): void => {
                    this.update((s: AppSettings): void => {
                      s.autoPlayOnStart = v;
                    });
                    if (v) {
                      this.toast('已开启：启动应用时将从上次播放的曲目继续', 1800);
                    }
                  }
                }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0
              })

              CardDivider()

              HdsListItemCard({
                textItem: { primaryText: { text: '仅 WiFi 播放' } },
                 suffixItem: new SuffixSwitch({
                   isCheck: this.settings.wifiOnlyPlay,
                   selectColor: this.themePrimary,
                  onChange: (v: boolean): void => {
                    this.update((s: AppSettings): void => {
                      s.wifiOnlyPlay = v;
                    });
                    if (v) {
                      this.toast('已开启：移动网络下将不播放在线歌曲', 1800);
                    }
                  }
                }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0
              })

              CardDivider()

              HdsListItemCard({
                textItem: { primaryText: { text: '累计听歌' } },
                suffixItem: new SuffixText({ text: this.listenText }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0
              })

              CardDivider()

              // 最近播放（2026-10-10 从歌单页根栏卡片迁入设置：歌单页 bottomBuilder
              // 第二行随 HDS 适配整体退役，入口归位「播放」组——播放历史本就是播放行为）
              // 2026-10-11：条数从副标题挪到右侧值位（行内提示词精简，信息不丢）
              HdsListItemCard({
                textItem: { primaryText: { text: '最近播放' } },
                suffixItem: new SuffixArrowIconText({
                  text: { text: this.recentCount > 0 ? `${this.recentCount} 首` : '' },
                  endArrow: {}
                }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0,
                onClick: (): void => {
                  NavStackHolder.stack.pushPath({ name: 'Recent' });
                }
              })

              CardDivider()

              // 播放音质（2026-10-08 从「下载」卡移入本卡，语义归位：
              // 它控制的是在线播放的音源档位，与下载无关）
              HdsListItemCard({
                textItem: { primaryText: { text: '播放音质' } },
                suffixItem: new SuffixArrowIconText({
                  text: { text: this.settings.playQuality },
                  endArrow: {}
                }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0,
                onClick: (): void => {
                  this.openQualityDialog(true);
                }
              })

              CardDivider()

              // 定时停止播放（2026-10-08 从孤儿「定时」小节并入：单行小节观感零碎，
              // 且该功能本质是播放行为，归入播放卡语义更顺）
              HdsListItemCard({
                textItem: { primaryText: { text: '定时停止播放' } },
                suffixItem: new SuffixText({ text: this.sleepRemainText }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0,
                onClick: (): void => {
                  this.sheetKind = SettingsSheetKind.SLEEP;
                  this.showSheet = true;
                }
              })
            }
          }

          // ── 下载 ──
          ListItem() {
            SectionHeader({ headerText: '下载' })
          }
          ListItem() {
            InsetCard() {
              HdsListItemCard({
                textItem: { primaryText: { text: '仅 WiFi 下载' } },
                 suffixItem: new SuffixSwitch({
                   isCheck: this.settings.wifiOnlyDownload,
                   selectColor: this.themePrimary,
                  onChange: (v: boolean): void => {
                    this.update((s: AppSettings): void => {
                      s.wifiOnlyDownload = v;
                    });
                    if (v) {
                      this.toast('已开启：移动网络下下载前会先询问', 1800);
                    }
                  }
                }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0
              })

              CardDivider()

              HdsListItemCard({
                textItem: { primaryText: { text: '下载音质' } },
                suffixItem: new SuffixArrowIconText({
                  text: { text: this.settings.downloadQuality },
                  endArrow: {}
                }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0,
                onClick: (): void => {
                  this.openQualityDialog(false);
                }
              })

              CardDivider()

              // 缓存（2026-10-08 从孤儿「存储」小节并入：与下载同属空间/流量话题，
              // 单行小节观感零碎；点击行为原样保留）。
              // 提示词并入本行副标题（2026-10-14 与「缓存」同在一行，精简为一行）：
              // 点击本行清理临时缓存；有已下载歌曲时前置「不受影响」说明。
              HdsListItemCard({
                textItem: {
                  primaryText: { text: '缓存' },
                  secondaryText: { text: this.storageFooterText }
                },
                suffixItem: new SuffixText({ text: this.cacheText }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0,
                onClick: (): void => {
                  this.confirmClearCache();
                }
              })
            }
          }

          // ── 外观 ──
          ListItem() {
            SectionHeader({ headerText: '外观' })
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
                  this.sheetKind = SettingsSheetKind.THEME_COLOR;
                  this.showSheet = true;
                }
              })

              CardDivider()

              // 底部导航布局：水平融合（播放栏与页签同一行）/ 垂直两层（播放栏上、页签下）。
              // 点击循环切换，写偏好 + AppStorage 镜像即时生效（Index 受控样式重建）。
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
            }
          }

          // ── 歌单备份（走剪贴板，见 utils/ClipboardUtil.ets）──
          // 解决的真实痛点：歌单只存在 Preferences 里，**清数据 / 换机即丢**。
          // 导出剥掉 localFilePath、导入逐首 slimTrack（见 LibraryStore 的注释）。
          ListItem() {
            SectionHeader({ headerText: '歌单备份' })
          }
          ListItem() {
            InsetCard() {
              this.SettingsRow('导出歌单到剪贴板', (): void => {
                this.exportPlaylists();
              })
              CardDivider()
              // 2026-10-16（真机两次复现）：普通行点击后静默读剪贴板被系统拦截
              // （getData 只拿到空串），HarmonyOS 强制要求经安全控件 PasteButton
              // 授权。改为：点击本行 → 弹 PasteImportDialog（窗内系统粘贴按钮）→
              // 点「粘贴」授权 → confirmImportPlaylists 读剪贴板并二次确认落库。
              this.SettingsRow('从剪贴板导入歌单', (): void => {
                this.pasteDialogCtrl.open();
              })
              CardDivider()
              // 跨平台导入（网易云 / QQ 音乐）：本 App 自产自销的 JSON 备份管不了
              // 「歌在别的平台」的场景，这条链路负责搜 B 站音源并建单（方案见 design/
              // 歌单导入方案-网易云与QQ音乐.md）。
              HdsListItemCard({
                textItem: {
                  primaryText: { text: '从网易云 / QQ 音乐导入' },
                  secondaryText: { text: '粘贴歌单链接或歌曲列表' }
                },
                suffixItem: new SuffixArrowIconText({ endArrow: {} }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0,
                onClick: (): void => {
                  NavStackHolder.stack.pushPath({ name: 'PlaylistImport' });
                }
              })
                .accessibilityText('从网易云 / QQ 音乐导入')
                .accessibilityLevel('yes')
            }
          }
          ListItem() {
            SectionFooter({ noteText: '导出的文本里不含音频直链与本机路径，导入后首次播放需要重新联网解析' })
          }

          // ── 关于 ──
          ListItem() {
            SectionHeader({ headerText: '关于' })
          }
          ListItem() {
            InsetCard() {
              HdsListItemCard({
                textItem: { primaryText: { text: '关于本项目' } },
                suffixItem: new SuffixArrowIconText({
                  text: { text: this.appVersion },
                  endArrow: {}
                }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0,
                onClick: (): void => {
                  NavStackHolder.stack.pushPath({ name: 'About' });
                }
              })
            }
          }
        }
        .width('100%')
        .layoutWeight(1)
        // 边界回弹（2026-10-08）：到顶/到底的反馈动效
        .edgeEffect(EdgeEffect.Spring)
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
      // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp）
      .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
      // 顶栏由根 HdsNavigation 的统一 titleBar 承担（见 Index.tabTitleRow），
      // 本页只负责把 listScroller 注册给根容器驱动滚动模糊。
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .bindSheet($$this.showSheet, this.SheetContent(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false
    })
  }
}
