/**
 * 下载与存储页（设置二级页）。
 *
 * 内容：仅 WiFi 下载 / 下载音质（SelectDialog 弹窗）/ 保存到系统下载目录
 * （DOWNLOAD 模式持久授权 + 单份存储搬移）/ 同步已完成歌曲 /
 * 缓存（占用统计 + 清理）/ 听后缓存（开关 + 清理）。
 *
 * 「仅 WiFi 下载」只写偏好，**拦截逻辑在 DownloadManager.requestDownload 入口**
 * （见 service/DownloadManager.ts）：开关打开且当前是蜂窝网络时，那次下载请求会带着
 * `blockedReason` 返回，由调用页（搜索页）弹框询问后再带 `ignoreWifiLimit` 重试。
 *
 * 缓存统计 / 清理走 TaskPool 异步（防主线程阻塞 6s+），
 * 轮次令牌防「快速进出页时旧轮结果覆盖新轮」。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，AboutPage 同款骨架）。
 */

import common from '@ohos.app.ability.common';
import { taskpool } from '@kit.ArkTS';
import { dirSizeTask, clearDirContentsTask } from '../utils/CacheFsTasks';
import { SelectDialog } from '@kit.ArkUI';
import {
  CONTENT_END_OFFSET,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY
} from '../common/Constants';
import { AppSettings, DEFAULT_APP_SETTINGS } from '../model/MusicModels';
import { AppPreferences } from '../preferences/AppPreferences';
import { showAppToast } from '../components/AppToast';
import { showAppAlertDialog } from '../components/AppAlertDialog';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { TwoColumnLayout } from '../common/utils/TwoColumnList';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { InsetCard, CardDivider } from '../components/InsetCardGroup';
import { HdsListItemCard, SuffixSwitch, SuffixArrowIconText, SuffixText } from '@kit.UIDesignKit';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { QUALITY_OPTIONS, QualityOption, formatBytes } from '../utils/SettingsShared';
import { ensureDirUri, PublicSyncResult } from '../service/PublicDownloadsSaver';
import { DownloadManager } from '../service/DownloadManager';
import { countListenCache, listenCacheUsage, clearListenCache } from '../service/ListenCacheStore';

@Component
export struct DownloadSettingsPage {
  /** 状态栏高度（vp）：HDS 标题栏 avoidLayoutSafeArea 后栏顶 = safeTop，内容让位量要含它 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：内容末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 当前横竖屏（Index 常驻注册写入）：内容列 840 口径取值用 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;
  /**
   * 设置快照。首帧零磁盘读：先默认值占位，aboutToAppear 延后一拍读真值；
   * 开关写入走 AppPreferences.updateSettings（从持久层真值起步，不存在
   * 「默认值被当真值覆盖写盘」的风险）。
   */
  @State settings: AppSettings = DEFAULT_APP_SETTINGS;
  /** 品牌色（开关选中色）：EntryAbility 发布、外观页选色 / 切深浅重发布 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /** 缓存占用文案；已下载音频只做展示，不参与清理 */
  @State cacheText: string = '计算中…';
  /** 存储行副文案：已下载体积说明 + 清理提示（refreshCacheSize 动态组装） */
  @State storageFooterText: string = '';
  /** 清理进行中（防重入 + 文案「清理中…」）：清理改 TaskPool 异步后必要 */
  @State clearing: boolean = false;
  /** 同步已完成歌曲进行中（防重入 + 行标题「同步中…」） */
  @State syncing: boolean = false;
  /** 听后缓存占用：进页统计 + 清理后刷新 */
  @State listenCacheUsageText: string = '0 B';
  /** 听后缓存条数副文案（「已缓存 N 首，点击清理」/「暂无缓存」） */
  @State listenCacheDescText: string = '暂无缓存';
  /** 听后缓存清理进行中（防重入 + 主文案「清理中…」） */
  @State clearingListenCache: boolean = false;
  private cacheDirPath: string = '';
  /** 应用级缓存目录（…/base/cache），与模块级 cacheDirPath 一起统计 */
  private appCacheDirPath: string = '';
  private downloadDirPath: string = '';
  /**
   * 缓存统计轮次令牌：统计是异步的，快速进出设置页会有多轮统计在飞，
   * 旧轮结果不得覆盖新轮（对比 seq 丢弃）。
   */
  private cacheSizeSeq: number = 0;
  /**
   * 下载音质选择弹窗（SelectDialog 单选列表 + 取消）。
   * SelectDialog 的 selectedIndex / radioContent 是构造时定格的（CustomDialog
   * 参数不支持动态刷新，faqs-arkui-555），而音质随时可能被上一次选择改掉 ——
   * 所以每次打开前按当前值重建 controller，保证选中态新鲜。
   */
  private downloadQualityDialog: CustomDialogController | null = null;
  /** 滚动控制器：bindToScrollable 绑给 HDS 标题栏，滚动模糊效果依赖此绑定 */
  private pageScroller: Scroller = new Scroller();

  /** 子页转场的横移量（相对页面自身宽度）：转场代理里按 push/pop 方向临时改写 */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    // 偏好读取延后一拍，首帧 build 全程零磁盘读。
    setTimeout((): void => {
      this.settings = AppPreferences.getSettings();
      this.refreshListenCacheUsage();
    }, 0);
    this.refreshCacheSize();
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

  private refreshCacheSize(): void {
    this.cacheText = '计算中…';
    // 目录解析失败（UIContext 未就绪等）：显示不可用，下次进页再试
    if (!this.resolveDirs()) {
      this.cacheText = '不可用';
      return;
    }
    // 递归统计走 TaskPool（防审核 THREAD_BLOCK_6S）：image_file_cache 等目录
    // 文件数无上界，主线程同步递归会被阻塞 6s+；主线程只拿最终字节数。
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
        // 存储提示词（与「缓存」同在一行，精简为一行）：
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
    // 递归删除走 TaskPool：主线程同步 unlinkSync 整个缓存目录，
    // 文件多时阻塞 6s+（审核 THREAD_BLOCK_6S 风险）。
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

  /**
   * 刷新听后缓存占用与条数。
   * 占用统计是异步 stat 循环（缓存目录有 512MB 上限、文件数百级），不阻塞 UI。
   */
  private refreshListenCacheUsage(): void {
    listenCacheUsage()
      .then((bytes: number): void => {
        this.listenCacheUsageText = formatBytes(bytes);
        const count: number = countListenCache();
        this.listenCacheDescText = count > 0 ? `已缓存 ${count} 首，点击清理` : '暂无缓存';
      })
      .catch((e: Error): void => {
        console.error(`refresh listen cache usage failed: ${e.message}`);
        this.listenCacheUsageText = '不可用';
      });
  }

  /** 清理听后缓存前确认：明确「已下载歌曲与播放记录不受影响」 */
  private confirmClearListenCache(): void {
    showAppAlertDialog(this.getUIContext(), {
      title: '清理听后缓存',
      message: '将删除全部听后缓存音频。已下载的歌曲、歌单与播放记录不受影响。',
      primaryButton: {
        value: '取消'
      },
      secondaryButton: {
        value: '清理',
        action: (): void => {
          this.doClearListenCache();
        }
      }
    });
  }

  private doClearListenCache(): void {
    // 防重入：清理还在跑时重复点击直接忽略
    if (this.clearingListenCache) {
      return;
    }
    this.clearingListenCache = true;
    clearListenCache()
      .then((removed: number): void => {
        this.clearingListenCache = false;
        this.toast(removed > 0 ? `已清理 ${removed} 首缓存` : '没有需要清理的缓存', 1800);
        this.refreshListenCacheUsage();
      })
      .catch((e: Error): void => {
        this.clearingListenCache = false;
        console.error(`clear listen cache failed: ${e.message}`);
        this.toast('清理失败，请稍后重试', 1800);
        this.refreshListenCacheUsage();
      });
  }

  /**
   * 选中下载音质。只写偏好 —— 真正的取流档位由下载内核在每次任务开始时读取，
   * 所以**已在下载中的任务不会中途换档**（换档需要重新解析音源），
   * 要生效得重新下载。
   */
  private pickQuality(value: string): void {
    this.update((s: AppSettings): void => {
      s.downloadQuality = value;
    });
    this.toast(`下载音质：${value}`, 1500);
  }

  /**
   * 打开下载音质弹窗（SelectDialog，单选列表 + 取消）。
   * 选中态按当前偏好预选；点选项即生效（写偏好 + toast）并关闭弹窗，
   * 取消按钮 / 点遮罩只关闭不改动。
   */
  private openDownloadQualityDialog(): void {
    const current: string = this.settings.downloadQuality;
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
          this.pickQuality(opt.value);
          this.downloadQualityDialog?.close();
        }
      });
    }
    const dialog: CustomDialogController = new CustomDialogController({
      builder: SelectDialog({
        title: '下载音质',
        content: 'B 站只提供它已有的档位，个别视频最高只有 64 kbps；已在下载中的任务不会中途换档，重新下载才会生效。Hi-Res / 杜比需登录（大会员）',
        selectedIndex: selectedIndex,
        confirm: {
          value: '取消',
          // ⚠️ 显式 close，不依赖组件内部关闭（SelectDialog 的 confirm.action
          // 会替换而非追加默认关闭行为，真机实测点击无效果）。
          action: (): void => {
            this.downloadQualityDialog?.close();
          }
        },
        radioContent: items
      }),
      autoCancel: true
    });
    this.downloadQualityDialog = dialog;
    dialog.open();
  }

  /**
   * 「保存到系统下载目录」开关翻转。
   *
   * 打开：先走 DOWNLOAD 模式 Picker 取「下载/BiliMusic」目录 URI（持久授权、
   * 免选择界面；须在本次点击手势内拉起）—— 拿到才写偏好开开关；拿不到
   * （用户取消 / 异常）保持关闭，并强制重读快照把 SuffixSwitch 的本地翻转
   * 态刷回「关」（同值新对象引用即可触发重渲染）。
   * 关闭：只写偏好；已授权 URI 与已搬移文件都保留（重新打开直接复用 URI）。
   */
  private onPublicDownloadsToggle(v: boolean): void {
    if (!v) {
      this.update((s: AppSettings): void => {
        s.saveToPublicDownloads = false;
      });
      this.toast('已关闭：新下载只存应用沙箱', 1600);
      return;
    }
    // 误触发守卫（wifiOnlyDownload 同款）：已是开态的重复回调不重复授权
    if (this.settings.saveToPublicDownloads) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ensureDirUri(ctx).then((uri: string): void => {
      if (uri.length === 0) {
        this.toast('未获得目录授权，开关未开启', 2000);
        this.settings = AppPreferences.getSettings();
        return;
      }
      this.update((s: AppSettings): void => {
        s.saveToPublicDownloads = true;
      });
      this.toast('已开启：下载完成后自动保存到「下载/BiliMusic」', 2400);
    });
  }

  /**
   * 「同步已完成歌曲」：把已完成且文件仍在沙箱的任务批量搬入「下载/BiliMusic」
   * （DownloadManager.syncCompletedToPublicDir，批内去重命名 + 失败计数）。
   * 防重入（syncing）；结果 toast 三态：无待同步 / 全成功 / 部分失败。
   */
  private syncCompletedToPublic(): void {
    if (this.syncing) {
      return;
    }
    if (!this.settings.saveToPublicDownloads) {
      this.toast('请先开启「保存到系统下载目录」', 1800);
      return;
    }
    this.syncing = true;
    DownloadManager.getInstance().syncCompletedToPublicDir()
      .then((r: PublicSyncResult): void => {
        this.syncing = false;
        if (r.total === 0) {
          this.toast('没有需要同步的歌曲', 1800);
          return;
        }
        if (r.failed === 0) {
          this.toast(`已同步 ${r.ok} 首到「下载/BiliMusic」`, 2200);
          return;
        }
        this.toast(`已同步 ${r.ok} 首，${r.failed} 首失败（可重试）`, 2400);
      })
      .catch((e: Error): void => {
        this.syncing = false;
        console.error(`sync to public dir failed: ${e.message}`);
        this.toast('同步失败，请稍后重试', 1800);
      });
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

  /** 标题栏内容（titleBar 的 stackBuilder 承载）：「下载与存储」标题（返回键为 HDS 默认键） */
  @Builder
  downloadBar() {
    NavTitleRow({ title: '下载与存储' })
  }

  /**
   * 标题行收窄容器（AboutPage 同款）：外层 Row 居中 + 内层 Column constraintSize
   * （上限与本页内容列同口径），大屏上标题行与内容列同宽对齐；
   * 两侧空白区 hitTestBehavior(Transparent) 穿透点击。
   */
  @Builder
  downloadBarNarrow() {
    Row() {
      Column() {
        this.downloadBar()
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
              textItem: { primaryText: { text: '仅 WiFi 下载' } },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.wifiOnlyDownload,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  // settings 延后一拍读真值时，isCheck 翻转会让 SuffixSwitch
                  // 误触发 onChange —— 用翻转前值守卫，只有值真的从关翻到开才提醒；
                  // 误触发时 v 与持久值一致被拦下。
                  const turningOn: boolean = v && !this.settings.wifiOnlyDownload;
                  this.update((s: AppSettings): void => {
                    s.wifiOnlyDownload = v;
                  });
                  if (turningOn) {
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
                this.openDownloadQualityDialog();
              }
            })

            CardDivider()

            // 保存到系统下载目录：开启后每首下载
            // 完成自动搬入「下载/BiliMusic」（单份存储，系统文件管理可见）；
            // 打开瞬间走 DOWNLOAD 模式 Picker 持久授权（免选择界面）。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '保存到系统下载目录' },
                secondaryText: { text: '下载完成后自动移入「下载/BiliMusic」，文件管理可见' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.saveToPublicDownloads,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  this.onPublicDownloadsToggle(v);
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 同步已完成歌曲：开关开启前 / 授权前的存量任务批量搬移入口。
            HdsListItemCard({
              textItem: {
                primaryText: { text: this.syncing ? '同步中…' : '同步已完成歌曲' },
                secondaryText: { text: '把开关开启前已下载的歌曲移入「下载/BiliMusic」' }
              },
              suffixItem: new SuffixText({ text: '同步' }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.syncCompletedToPublic();
              }
            })

            CardDivider()

            // 缓存：占用统计 + 点击清理。提示词并入本行副标题（精简为一行）：
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

            CardDivider()

            // 听后缓存：自然听完的歌曲后台缓存整首到
            // 独立 listen_cache 目录（512MB LRU），重播免解析、不耗流量、离线可播；
            // 流量策略跟随本页「仅 WiFi 下载」，不混入下载管理列表。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '听后缓存' },
                secondaryText: { text: '自然听完的歌曲自动缓存，重播不耗流量' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.listenCacheEnabled,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  // 翻转前值守卫，防进页误触发弹提示（见「仅 WiFi 下载」注释）
                  const turningOn: boolean = v && !this.settings.listenCacheEnabled;
                  this.update((s: AppSettings): void => {
                    s.listenCacheEnabled = v;
                  });
                  if (turningOn) {
                    this.toast('已开启：听完的歌曲将自动缓存', 1800);
                  }
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 清理听后缓存：占用统计 + 条数副文案，点击弹确认框（已下载歌曲不受影响）。
            HdsListItemCard({
              textItem: {
                primaryText: { text: this.clearingListenCache ? '清理中…' : '清理听后缓存' },
                secondaryText: { text: this.listenCacheDescText }
              },
              suffixItem: new SuffixText({ text: this.listenCacheUsageText }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.confirmClearListenCache();
              }
            })
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
          this.downloadBarNarrow();
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
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 经动态 import 后用 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function DownloadSettingsPageBuilder(): void {
  DownloadSettingsPage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接 @Builder 引用（编译期校验）。 */
export const DownloadSettingsPageWrapped: WrappedBuilder<[]> = wrapBuilder(DownloadSettingsPageBuilder);
