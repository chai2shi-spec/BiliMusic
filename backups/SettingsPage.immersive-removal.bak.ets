/**
 * 设置页：账户 / 登录后能力 / 播放（自动播放、歌词、仅 WiFi 播放、播放音质、累计听歌、
 * 最近播放、定时停止播放）/ 下载（仅 WiFi 下载、下载音质、缓存占用与清理）/ 外观 / 歌单备份 / 关于。
 * 2026-10-08 分区整理：登录后能力改为分组卡片样式与其它模块统一，孤儿「定时」「存储」
 * 小节分别并入播放 / 下载卡，错位在下载卡里的播放音质行移回播放卡。
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
 * 已登录显示头像 / 昵称 / 大会员徽标，点击弹菜单退出登录。本页是 Tabs 常驻页，
 * 登录态变化靠 STORE_LOGIN_REV 版本号 + @Watch 驱动刷新（aboutToAppear 只触发一次）。
 */

import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { bundleManager } from '@kit.AbilityKit';
import { SelectDialog, Chip, ChipSize } from '@kit.ArkUI';
import { BusinessError } from '@ohos.base';
import { AudioQuality, AppSettings, ThemeMode, NavBarStyle, DEFAULT_APP_SETTINGS } from '../model/MusicModels';
import { Playlist } from '../model/MusicModels';
import { AppPreferences } from '../preferences/AppPreferences';
import { MusicPlayer } from '../player/MusicPlayer';
import { NavStackHolder } from '../service/NavStackHolder';
import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { MiniBarSnapController } from '../utils/MiniBarSnapController';
import { LibraryStore, PlaylistImportResult } from '../service/LibraryStore';
import { copyText, readText } from '../utils/ClipboardUtil';
import {
  CONTENT_END_OFFSET,
  STORE_LIBRARY_REV,
  STORE_MINI_BAR_COLLAPSED,
  STORE_NAV_BAR_STYLE,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_SLEEP_TIMER_END,
  STORE_LOGIN_REV
} from '../common/Constants';
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
 * 递归统计目录占用（字节）。目录不存在 / 单项读不动时按 0 计，绝不抛。
 * 统计是**同步 IO**，调用方负责放到 setTimeout 里跑，别阻塞首屏。
 */
function dirSize(path: string): number {
  if (path.length === 0) {
    return 0;
  }
  let total: number = 0;
  try {
    const names: string[] = fs.listFileSync(path);
    for (let i = 0; i < names.length; i++) {
      const child: string = `${path}/${names[i]}`;
      try {
        const st: fs.Stat = fs.statSync(child);
        total += st.isDirectory() ? dirSize(child) : st.size;
      } catch (e) {
        // 单个条目统计失败（被占用 / 刚被删）跳过
      }
    }
  } catch (e) {
    // 目录不存在
  }
  return total;
}

/**
 * 清空目录内容，**保留目录自身**（cacheDir 是系统目录，不能删）。
 * @returns 删除的文件个数
 */
function clearDirContents(path: string): number {
  if (path.length === 0) {
    return 0;
  }
  let removed: number = 0;
  try {
    const names: string[] = fs.listFileSync(path);
    for (let i = 0; i < names.length; i++) {
      const child: string = `${path}/${names[i]}`;
      try {
        const st: fs.Stat = fs.statSync(child);
        if (st.isDirectory()) {
          removed += clearDirContents(child);
          fs.rmdirSync(child);
        } else {
          fs.unlinkSync(child);
          removed += 1;
        }
      } catch (e) {
        // 被占用的文件删不掉，跳过；不要因为一个文件中断整次清理
      }
    }
  } catch (e) {
    // 目录不存在
  }
  return removed;
}

@Component
export struct SettingsPage {
  // 首帧不读磁盘：字段初始化在 build 前同步执行，getSettings 的 getSync 会拖住首屏。
  // 先用默认值占位，aboutToAppear 里延后一拍再读真值（做法同 refreshCacheSize 的缓存统计）。
  // 一帧的默认值闪变可接受；被覆盖写盘的风险由 settingsLoaded + update() 兜底。
  @State settings: AppSettings = DEFAULT_APP_SETTINGS;
  /** 真值是否已从偏好载入：update() 据此防止「默认值被当真值覆盖写盘」 */
  private settingsLoaded: boolean = false;

  /** 迷你播放条滚动吸附（悬浮沉浸底栏）：防抖判定在控制器，本页只喂增量并落库目标态 */
  private miniBarSnap: MiniBarSnapController = new MiniBarSnapController();

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
   * 底部半屏面板开关（定时停止播放）。
   * 音质选择已迁 SelectDialog 标准弹窗（2026-10-11，见 openQualityDialog），
   * 本 bindSheet 只剩睡眠定时一个内容。
   */
  @State showSheet: boolean = false;
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
   * 改在 refreshCacheSize 的 setTimeout 回调里获取，拿不到就下次再试（显示「不可用」，不崩）。
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
      showLyrics: s.showLyrics,
      wifiOnlyDownload: s.wifiOnlyDownload,
      wifiOnlyPlay: s.wifiOnlyPlay,
      themeMode: s.themeMode,
      navBarStyle: s.navBarStyle
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
    this.toast(`主题：${this.themeLabel()}`, 1500);
  }

  /** 底部导航栏样式的展示文案（外观卡「底部导航栏」行的副文案） */
  private navStyleLabel(): string {
    return this.settings.navBarStyle === NavBarStyle.IMMERSIVE ? '悬浮沉浸' : '融合胶囊';
  }

  /**
   * 切换底部导航栏样式（融合胶囊 ↔ 悬浮沉浸，点击循环）。
   * 仿 cycleTheme 三段式：偏好落盘（update）→ AppStorage 通道即时生效
   * （Index @StorageProp @Watch 订阅 STORE_NAV_BAR_STYLE，底栏整体换树）→ toast 反馈。
   * 启动恢复在 EntryAbility（loadContent 前发布同键，首帧即正确样式）。
   */
  private cycleNavBarStyle(): void {
    const next: NavBarStyle = this.settings.navBarStyle === NavBarStyle.CAPSULE
      ? NavBarStyle.IMMERSIVE : NavBarStyle.CAPSULE;
    this.update((s: AppSettings): void => {
      s.navBarStyle = next;
    });
    AppStorage.setOrCreate(STORE_NAV_BAR_STYLE, next);
    this.toast(`底部导航栏：${this.navStyleLabel()}`, 1500);
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
    // 递归统计是同步 IO，延后一拍再跑，避免拖住页签切换
    setTimeout((): void => {
      if (!this.resolveDirs()) {
        this.cacheText = '不可用';
        return;
      }
      // 两层缓存目录都统计：模块级（应用自己的）+ 应用级（ArkUI 框架的 shader / preload 等）
      const cacheBytes: number = dirSize(this.cacheDirPath) + dirSize(this.appCacheDirPath);
      const downloadBytes: number = dirSize(this.downloadDirPath);
      this.cacheText = formatBytes(cacheBytes);
      // 存储脚注：已下载体积说明（有才带）+ 清理提示，两段合成一条
      const storageParts: string[] = [];
      if (downloadBytes > 0) {
        storageParts.push(`已下载歌曲 ${formatBytes(downloadBytes)}（不受清理影响）`);
      }
      storageParts.push('点击「缓存」一行即可清理临时缓存');
      this.storageFooterText = storageParts.join('\n');
    }, 30);
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
    // 两层缓存目录都清（只清内容、保留目录本身），清理后再刷新占用展示
    const removed: number = clearDirContents(this.cacheDirPath) + clearDirContents(this.appCacheDirPath);
    this.toast(removed > 0 ? `已清理 ${removed} 个缓存文件` : '没有需要清理的缓存', 1800);
    this.refreshCacheSize();
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
   * 「登录后能力」一行。
   *
   * @param title 主标题 16fp
   * @param route 点击后跳转的目标 route；未登录时不跳转，改弹去登录引导
   *
   * 2026-10-11：行内说明副标题全删（设置页提示词精简）——「需要登录」由小节脚注统一说明；
   * 未登录态的视觉降级（50% 透明）与点击引导逻辑保持不变。
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
        // 云端歌单同步尚未实现（2026-10-08）：'CloudSync' 路由不存在，
        // push 会渲染空白 NavDestination —— 先拦截弹提示，避免「点进去一片空白」
        if (route === 'CloudSync') {
          this.toast('云端歌单同步开发中，敬请期待', 2000);
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
   * 底部面板入口（睡眠定时专用）。
   * 保持无参这层是为了避开「带参 @Builder 参数不随状态刷新」的坑；
   * 音质选择已迁 SelectDialog 弹窗（见 openQualityDialog），不再走 bindSheet。
   */
  @Builder
  SheetContent(): void {
    this.SleepSheetContent()
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
          .fontColor(this.sleepTimerEnd > 0 ? $r('app.color.brand_deep') : $r('app.color.text_disabled'))
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
        .fontColor($r('app.color.brand_on'))
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor($r('app.color.bili_pink'))
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
                            fontColor: $r('app.color.brand_on')
                          },
                          size: ChipSize.SMALL,
                          allowClose: false,
                          backgroundColor: $r('app.color.bili_pink')
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
            }
          }
          ListItem() {
            SectionFooter({ noteText: '登录凭据只保存在本机，不上传任何服务器；不登录也能正常使用全部匿名功能' })
          }

          // ── 登录后能力（2026-10-08）──
          // 三行入口分别对应「云端歌单同步 / 观看历史与稍后再看 / 我的关注」三个方向。
          // 未登录时行内容压到 50% 透明、副标题带「（需登录）」，点击弹去登录引导 ——
          // **不渲染空态**，免得把「没登录」说成「没数据」。
          // 2026-10-08 分区整理：三行收进一个 InsetCard + CardDivider —— 此前各自
          // 裸放在独立 ListItem 里（无卡片无分隔线），与其它模块的分组卡片样式不一致。
          ListItem() {
            SectionHeader({ headerText: '登录后能力' })
          }
          ListItem() {
            InsetCard() {
              this.CapabilityRow('云端歌单同步', 'CloudSync')
              CardDivider()
              this.CapabilityRow('观看历史与稍后再看', 'WatchHistory')
              CardDivider()
              this.CapabilityRow('我的关注', 'Follows')
            }
          }
          ListItem() {
            SectionFooter({
              noteText: this.loginUser === null
                ? '这些能力需要登录 B 站账号，点击任意一项可前往登录'
                : '与 B 站网页版共用同一份登录态，退出登录不影响本地歌单与下载'
            })
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
                  selectColor: $r('app.color.bili_pink'),
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

              HdsListItemCard({
                textItem: { primaryText: { text: '显示歌词' } },
                suffixItem: new SuffixSwitch({
                  isCheck: this.settings.showLyrics,
                  selectColor: $r('app.color.bili_pink'),
                  onChange: (v: boolean): void => {
                    this.update((s: AppSettings): void => {
                      s.showLyrics = v;
                    });
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
                  selectColor: $r('app.color.bili_pink'),
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
                  selectColor: $r('app.color.bili_pink'),
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
              // 单行小节观感零碎；点击行为与提示脚注原样保留）
              HdsListItemCard({
                textItem: { primaryText: { text: '缓存' } },
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
          // 原「存储」小节的脚注随缓存行并入本节：已下载体积说明 + 清理提示
          ListItem() {
            SectionFooter({ noteText: this.storageFooterText })
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

              // 底部导航栏样式切换（2026-10）：融合胶囊（默认，HDS 悬浮胶囊融合播放栏）
              // ↔ 悬浮沉浸（原生 Tabs 沉浸材质页签栏 + 常驻迷你播放条叠加，切 Tab 不消失）
              HdsListItemCard({
                textItem: { primaryText: { text: '底部导航栏' } },
                suffixItem: new SuffixText({ text: this.navStyleLabel() }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0,
                onClick: (): void => {
                  this.cycleNavBarStyle();
                }
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
              this.SettingsRow('从剪贴板导入歌单', (): void => {
                this.confirmImportPlaylists();
              })
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
        // 顶部固定栏让位（Sumy 式穿透）：列表视口铺满全屏，首项从栏底起排，
        // 滚动时条目从模糊板下方穿过。让位量直接用常量计算（2026-10-08，与
        // DownloadsPage 同款）：本栏只有一行 NAV_TITLE_BAR_HEIGHT 标题，无需实测；
        // 且 contentStartOffset 只在内容首次布局时生效，测量回写来不及，常量即正确值。
        .contentStartOffset(this.safeTop + NAV_TITLE_BAR_HEIGHT)
        // 底部悬浮页签让位：列表末尾可滚动至悬浮条上方，不被遮挡
        // 页签栏自己抬高了 safeBottom（见 Index.ets），列表末尾要跟着多让这么多
        .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
        // 迷你播放条滚动吸附（悬浮沉浸底栏）：手指上滑累计跨阈值 → 收进页签栏；
        // 手指下滑 → 展开恢复。防抖/方向清零/只认拖动帧在 MiniBarSnapController，
        // 过渡动效由 Index 经 applyMiniBarStyle 携带（HDS 内建）。
        // onDidScroll 是 onScroll 的非弃用等价（ScrollableCommonMethod，API 12+），载荷相同。
        .onDidScroll((scrollOffset: number, scrollState: ScrollState) => {
          this.miniBarSnap.onScroll(scrollOffset, scrollState, (collapsed: boolean): void => {
            AppStorage.setOrCreate(STORE_MINI_BAR_COLLAPSED, collapsed);
          });
        })
      }
      .width('100%')
      .height('100%')
      // ⚠️ 不再整体 padding top：列表视口要铺满全屏（contentStartOffset 负责让出栏高），
      // 否则条目在栏底被裁掉、滑不进模糊板下方。
      // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp）
      .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
      // ⚠️ 自绘钉顶整栏（GlassTopBar + reveal 机制）已于批 3 移除：
      // 顶栏改由根 HdsNavigation 的统一 titleBar 承担（见 Index.tabTitleRow），
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
