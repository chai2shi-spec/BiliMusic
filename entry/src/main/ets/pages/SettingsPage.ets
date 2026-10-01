/**
 * 设置页：自动播放 / 显示歌词 / 仅 WiFi 下载 / 主题、定时停止播放、缓存占用与清理。
 *
 * 「仅 WiFi 下载」只写偏好，**拦截逻辑在 DownloadManager.requestDownload 入口**
 * （见 service/DownloadManager.ts）：开关打开且当前是蜂窝网络时，那次下载请求会带着
 * `blockedReason` 返回，由调用页（搜索页）弹框询问后再带 `ignoreWifiLimit` 重试。
 *
 * ⚠️ 登录功能已**整体移除**（登录页、登录接口、登录态存储一并删除），本页不再有
 * 「登录状态 / 登录 / 退出」这一行，也不要把 LoginPage 或 Login 路由加回来。
 * 应用现在只以匿名 + buvid 身份访问 B 站。
 */

import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@ohos.base';
import { promptAction } from '@kit.ArkUI';
import { AudioQuality, AppSettings, ThemeMode } from '../model/MusicModels';
import { AppPreferences } from '../preferences/AppPreferences';
import { MusicPlayer } from '../player/MusicPlayer';
import { NavStackHolder } from '../service/NavStackHolder';
import { CONTENT_END_OFFSET, STORE_SAFE_BOTTOM, STORE_SLEEP_TIMER_END } from '../common/Constants';
import { showAppToast } from '../components/AppToast';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';

const SLEEP_OPTIONS: number[] = [10, 20, 30, 60, 120];

/**
 * 下载音质档位。
 *
 * `value` 必须与 `AudioQuality` 枚举值逐字一致 —— 它同时就是 AppSettings.downloadQuality
 * 的存储值，DownloadManager 每次下载都拿它去映射成 B 站音频流 id（见 downloadQualityId）。
 * `hint` 里如实写码率：B 站只提供它已有的档位，个别投稿最高只有 64 kbps，
 * 不写清楚的话用户会以为「选了高音质却还是小文件」是 App 的问题。
 */
interface QualityOption {
  value: string;
  hint: string;
}

const QUALITY_OPTIONS: QualityOption[] = [
  { value: AudioQuality.STANDARD, hint: '约 64 kbps，最省流量' },
  { value: AudioQuality.HIGH, hint: '约 192 kbps，默认' },
  { value: AudioQuality.LOSSLESS, hint: '优先 Hi-Res / 杜比，没有则取最高可用' }
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
  @State settings: AppSettings = AppPreferences.getSettings();
  /** 底部安全区高度（vp）：根容器不再统一避让，列表末尾让位要自己叠上这一份 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /**
   * 定时停止的到点时间戳（ms），0 = 未开启。
   * 播放内核只发布这个**结束时刻**，剩余量由本页本地 1s 现算，避免每秒写一次 AppStorage。
   */
  @StorageLink(STORE_SLEEP_TIMER_END) @Watch('onSleepTimerChanged') sleepTimerEnd: number = 0;
  @State sleepRemainText: string = '未开启';
  /**
   * 弹出的选择面板：'sleep'（定时停止）| 'quality'（下载音质）。
   *
   * 两者**共用同一个 bindSheet**：同一个组件上重复调用 bindSheet 只会保留最后一个，
   * 所以用一个开关 + 一个 kind 来切换内容，而不是绑两个 sheet。
   */
  @State sheetKind: string = 'sleep';
  @State showSheet: boolean = false;
  private sleepTicker: number = -1;

  /** 缓存占用文案；已下载音频只做展示，不参与清理 */
  @State cacheText: string = '计算中…';
  @State downloadText: string = '';
  /** 累计听歌时长文案：进页时读一次偏好（计时在 MusicPlayer，播放中不实时刷新） */
  @State listenText: string = '';
  private cacheDirPath: string = '';
  /** 应用级缓存目录（…/base/cache），与模块级 cacheDirPath 一起统计 */
  private appCacheDirPath: string = '';
  private downloadDirPath: string = '';

  /** 应用版本号（如「v1.0.2」）：从 bundleManager 读，跟着 app.json5 走，不在页面里写死 */
  @State appVersion: string = '';

  aboutToAppear(): void {
    this.refreshSleepText();
    this.refreshCacheSize();
    this.listenText = formatListenDuration(AppPreferences.getTotalListenSeconds());
    this.loadAppVersion();
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
      themeMode: s.themeMode
    };
  }

  private update(mut: (s: AppSettings) => void): void {
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
   * 选中下载音质。只写偏好 —— 真正的取流档位由 DownloadManager 在每次任务开始时读取，
   * 所以**已在下载中的任务不会中途换档**（换档需要重新解析音源），要生效得重新下载。
   */
  private pickQuality(value: string): void {
    this.showSheet = false;
    this.update((s: AppSettings): void => {
      s.downloadQuality = value;
    });
    this.toast(`下载音质：${value}`, 1500);
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
      this.downloadText = downloadBytes > 0
        ? `已下载歌曲 ${formatBytes(downloadBytes)}（不受清理影响）`
        : '';
    }, 30);
  }

  private confirmClearCache(): void {
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '清理缓存',
        message: '将删除应用临时缓存文件。已下载的歌曲、歌单与播放记录不受影响。',
        buttons: [
          { text: '取消', color: $r('app.color.text_secondary') },
          { text: '清理', color: $r('app.color.brand_deep') }
        ]
      }).then((result: promptAction.ShowDialogSuccessResponse): void => {
        if (result.index === 1) {
          this.doClearCache();
        }
      }).catch((e: Error): void => {
        console.error(`clear cache dialog failed: ${e.message}`);
      });
    } catch (e) {
      console.error('show clear-cache dialog threw');
    }
  }

  private doClearCache(): void {
    // 两层缓存目录都清（只清内容、保留目录本身），清理后再刷新占用展示
    const removed: number = clearDirContents(this.cacheDirPath) + clearDirContents(this.appCacheDirPath);
    this.toast(removed > 0 ? `已清理 ${removed} 个缓存文件` : '没有需要清理的缓存', 1800);
    this.refreshCacheSize();
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /**
   * 底部面板入口：按 sheetKind 分发内容。
   * 必须走一层「无参 Builder」而不是给 bindSheet 传两个不同的 builder ——
   * 下面这层保持无参，也就顺带避开了「带参 @Builder 参数不随状态刷新」那个坑。
   */
  @Builder
  SheetContent(): void {
    if (this.sheetKind === 'quality') {
      this.QualitySheetContent()
    } else {
      this.SleepSheetContent()
    }
  }

  @Builder
  QualitySheetContent(): void {
    Column() {
      Text('下载音质')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text('B 站只提供它已有的档位，个别视频最高只有 64 kbps')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 4 })

      Column() {
        ForEach(QUALITY_OPTIONS, (opt: QualityOption): void => {
          Row() {
            Column() {
              Text(opt.value)
                .fontSize(16)
                .fontColor(this.settings.downloadQuality === opt.value ? $r('app.color.brand_deep') : $r('app.color.text_primary'))
              Text(opt.hint)
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ top: 3 })
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
              .layoutWeight(1)
            if (this.settings.downloadQuality === opt.value) {
              Text('✓')
                .fontSize(16)
                .fontColor($r('app.color.bili_pink'))
            }
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 12, bottom: 12 })
          .stateStyles({
            pressed: { .backgroundColor($r('app.color.press_overlay')) },
            normal: { .backgroundColor(Color.Transparent) }
          })
          .onClick((): void => {
            this.pickQuality(opt.value);
          })
        }, (opt: QualityOption): string => `quality_${opt.value}`)
      }
      .width('100%')
      .margin({ top: 10 })

      Divider()
        .color($r('app.color.bg_divider'))

      Text('已在下载中的任务不会中途换档，需重新下载才会生效')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ top: 10, bottom: 4 })
    }
    .width('100%')
    .padding({ top: 16, bottom: 12 })
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

  build() {
    Column() {
      // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
      // 根 Column 默认水平居中对齐，包一层挂上限即可。
      Column() {
        Text('设置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .padding({ left: 16, top: 14, bottom: 10 })

        List() {
          ListItem() {
            Row() {
              Text('自动播放下一首')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Blank()
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.autoPlay })
                .selectedColor($r('app.color.bili_pink'))
                .onChange((v: boolean): void => {
                  this.update((s: AppSettings): void => {
                    s.autoPlay = v;
                  });
                })
            }
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          }

          ListItem() {
            Row() {
              Text('显示歌词')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Blank()
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.showLyrics })
                .selectedColor($r('app.color.bili_pink'))
                .onChange((v: boolean): void => {
                  this.update((s: AppSettings): void => {
                    s.showLyrics = v;
                  });
                })
            }
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          }

          ListItem() {
            Row() {
              Column() {
                Text('仅 WiFi 下载')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Text('移动网络下先询问，避免消耗流量')
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: 3 })
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.wifiOnlyDownload })
                .selectedColor($r('app.color.bili_pink'))
                .onChange((v: boolean): void => {
                  this.update((s: AppSettings): void => {
                    s.wifiOnlyDownload = v;
                  });
                  if (v) {
                    this.toast('已开启：移动网络下下载前会先询问', 1800);
                  }
                })
            }
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          }

          ListItem() {
            Row() {
              Column() {
                Text('仅 WiFi 播放')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Text('移动网络下不播放在线歌曲，本地已下载不受限')
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: 3 })
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.wifiOnlyPlay })
                .selectedColor($r('app.color.bili_pink'))
                .onChange((v: boolean): void => {
                  this.update((s: AppSettings): void => {
                    s.wifiOnlyPlay = v;
                  });
                  if (v) {
                    this.toast('已开启：移动网络下将不播放在线歌曲', 1800);
                  }
                })
            }
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          }

          ListItem() {
            Row() {
              Column() {
                Text('下载音质')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Text('对已开始的任务不生效，重新下载才会换档')
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: 3 })
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
                .layoutWeight(1)
              Text(this.settings.downloadQuality)
                .fontSize(16)
                .fontColor($r('app.color.text_secondary'))
            }
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .stateStyles({
              pressed: { .backgroundColor($r('app.color.press_overlay')) },
              normal: { .backgroundColor(Color.Transparent) }
            })
            .onClick((): void => {
              this.sheetKind = 'quality';
              this.showSheet = true;
            })
          }

          ListItem() {
            Row() {
              Text('主题')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Blank()
                .layoutWeight(1)
              Text(this.themeLabel())
                .fontSize(16)
                .fontColor($r('app.color.text_secondary'))
            }
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .stateStyles({
              pressed: { .backgroundColor($r('app.color.press_overlay')) },
              normal: { .backgroundColor(Color.Transparent) }
            })
            .onClick((): void => {
              this.cycleTheme();
            })
          }

          ListItem() {
            Row() {
              Column() {
                Text('累计听歌')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Text('仅统计实际播放中的时间，暂停不计入')
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: 3 })
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
                .layoutWeight(1)
              Text(this.listenText)
                .fontSize(16)
                .fontColor($r('app.color.text_secondary'))
            }
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          }

          ListItem() {
            Row() {
              Text('定时停止播放')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Blank()
                .layoutWeight(1)
              Text(this.sleepRemainText)
                .fontSize(16)
                .fontColor(this.sleepTimerEnd > 0 ? $r('app.color.brand_deep') : $r('app.color.text_secondary'))
            }
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .stateStyles({
              pressed: { .backgroundColor($r('app.color.press_overlay')) },
              normal: { .backgroundColor(Color.Transparent) }
            })
            .onClick((): void => {
              this.sheetKind = 'sleep';
              this.showSheet = true;
            })
          }

          ListItem() {
            Column() {
              Row() {
                Text('缓存')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Blank()
                  .layoutWeight(1)
                Text(this.cacheText)
                  .fontSize(16)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')

              if (this.downloadText.length > 0) {
                Text(this.downloadText)
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .margin({ top: 3 })
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .stateStyles({
              pressed: { .backgroundColor($r('app.color.press_overlay')) },
              normal: { .backgroundColor(Color.Transparent) }
            })
            .onClick((): void => {
              this.confirmClearCache();
            })
          }

          ListItem() {
            Text('点击「缓存」一行即可清理临时缓存')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .padding({ left: 16, right: 16, top: 6, bottom: 14 })
          }

          ListItem() {
            Row() {
              Text('关于本项目')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Blank()
                .layoutWeight(1)
              Text(this.appVersion)
                .fontSize(16)
                .fontColor($r('app.color.text_secondary'))
              Text('›')
                .fontSize(18)
                .fontColor($r('app.color.text_tertiary'))
            }
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .stateStyles({
              pressed: { .backgroundColor($r('app.color.press_overlay')) },
              normal: { .backgroundColor(Color.Transparent) }
            })
            .onClick((): void => {
              NavStackHolder.stack.pushPath({ name: 'About' });
            })
          }
        }
        .layoutWeight(1)
        // 底部悬浮页签让位：列表末尾可滚动至悬浮条上方，不被遮挡
        // 页签栏自己抬高了 safeBottom（见 Index.ets），列表末尾要跟着多让这么多
        .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
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
