/**
 * 华为云空间同步页（design/华为云空间同步-方案.md §9 / 原型「已连接」+
 * 「未开启系统开关」两屏合并的单页三态；路由名 'HuaweiCloudSync' ——
 * 'CloudSync' 已被 B 站收藏夹同步页占用）。
 *
 * 两态切换的唯一依据是探针结果 isCloudDirAvailable()：
 *   · 未开启（系统同步开关没开）：步骤引导 + 「打开系统设置」深链 +
 *     「我已开启，重新检测」—— 系统开关 App 无法代开，页面只承担
 *     「指路 + 复检」，不画输入框、不做假按钮；
 *   · 已连接：状态卡（读取相对时间 + 上传三档「排队 / 失败 / 暂停」+ 异常信息 +
 *     四格指标）+ 自动读取开关 + 数据行（云端设备 / 同步内容）+
 *     「立即读取云端」按钮；一轮结束按结果弹「同步完成」提示。
 *
 * 状态刷新走 STORE_CLOUD_SYNC_REV（CloudSyncManager 每轮结束 bump）：
 * 页面 @StorageLink + @Watch 全量重读本地状态，不引入第二个通知通道 ——
 * 同一处顺带取走本轮的 CloudSyncRoundReport 做结果反馈（见 presentRoundReport）。
 *
 * 用词纪律（方案 §2）：本机改动何时上传由系统调度，App 只能保证「读取」——
 * 按钮叫「立即读取云端」而不是「立即同步」，状态卡同时呈现读
 * （App 可控，相对时间）与写（系统调度，报「还有几个没传」）两个维度。
 * 上传侧的「立即上传」只作**受阻时的手动催办**（powermanage 会押后上传），
 * 不代表 App 接管了上传时机，所以三档文案要区分「排队」与「失败」。
 */

import common from '@ohos.app.ability.common';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  CONTENT_END_OFFSET,
  STORE_CLOUD_SYNC_REV,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_ON,
  STORE_THEME_PRIMARY
} from '../common/Constants';
import { Playlist } from '../model/MusicModels';
import { getPlaylistsForSync, LibraryStore } from '../service/LibraryStore';
import { listMonthKeys } from '../service/PlaySessionStore';
import {
  CloudResetResult,
  CloudSyncRoundReport,
  consumeCloudRoundReport,
  requestCloudSyncRound,
  resetCloudSync,
  setCloudSyncPageVisible
} from '../service/CloudSyncManager';
import {
  classifyDeviceDirs,
  DeviceDirStats,
  getOwnDirSizeBytes,
  getUploadStatsAsync,
  initCloudDirClient,
  isCloudDirAvailable,
  reprobeCloudDir,
  triggerUpload,
  UploadStats,
  UploadTriggerOutcome,
  UploadTriggerResult
} from '../service/CloudDirClient';
import {
  getCloudDeviceId,
  getLastCloudSyncError,
  getLastReadAt,
  isAutoRead,
  setAutoRead
} from '../service/CloudSyncStore';
import { formatRelativeTime } from '../utils/TextUtil';
import { formatBytes } from '../utils/SettingsShared';
import { showAppToast } from '../components/AppToast';
import { showAppInfoDialog, showConfirm } from '../components/AppAlertDialog';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { TwoColumnLayout } from '../common/utils/TwoColumnList';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NAV_TRANSITION_MS, BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import { InsetCard, CardDivider, SectionHeader, SectionFooter } from '../components/InsetCardGroup';
import { HdsListItemCard, SuffixSwitch, HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { BarNarrowShell } from '../components/BarNarrowShell';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier
} from '../utils/HeaderBarMaterial';

/**
 * 上传统计 / 目录占用的最小重算间隔。
 * 这两个数每次都要扫一遍云目录（stat + IPC），自动轮次会在几秒内连着 bump
 * 好几次 rev —— 不限频就是把一次卡顿重复成连续卡顿。手动操作（立即上传 /
 * 重新检测）走 force=true 立刻重算。
 */
const CLOUD_STATS_REFRESH_MS: number = 8000;

@Component
export struct CloudSyncPage {
  /** 状态栏高度（vp）：HDS 标题栏 avoidLayoutSafeArea 后栏顶 = safeTop，内容让位量要含它 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：内容末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 当前横竖屏（Index 常驻注册写入）：内容列 840 口径取值用 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;
  /** 主题色运行时值：开关 / 按钮跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /** 云同步页刷新信号：CloudSyncManager 每轮结束 bump，@Watch 全量重读展示态 */
  @StorageLink(STORE_CLOUD_SYNC_REV) @Watch('onCloudSyncRevChanged') cloudSyncRev: number = 0;

  /** el2/cloud 探针结果：false = 系统同步开关未开 → 渲染引导态 */
  @State cloudReady: boolean = false;
  /** 最近一轮失败信息（空串 = 无异常）：状态卡标题与错误行依据 */
  @State lastError: string = '';
  /** 上次读取云端的时刻（ms；0 = 从未读取过） */
  @State lastReadAtMs: number = 0;
  /** 排队中 / 正在上传的文件数（系统会自己传，只能等） */
  @State uploadPending: number = 0;
  /** 上传失败的文件数（需要「重试」；与 pending 分开统计，否则失败时数字永远不降看不出原因） */
  @State uploadFailed: number = 0;
  /** 系统已暂停的文件数（断网 / 低电 / 温控，条件恢复后自动继续） */
  @State uploadStalled: number = 0;
  /** 「立即上传」进行中：文案改「上传中…」并拦重复点击 */
  @State uploadBusy: boolean = false;
  /** 上传按钮按压态（UI 铁律：必给按压态） */
  @State uploadPressed: boolean = false;
  /** 本机设备目录占用文案（formatBytes 结果） */
  @State cloudSizeText: string = '—';
  /** 云端设备目录数（已排除本机历史安装目录） */
  @State deviceCount: number = 0;
  /** 云端残留的本机历史安装目录数（重装产生，不计入设备数） */
  @State legacyDirCount: number = 0;
  /** 同步范围歌单数（不含 B 站收藏夹镜像） */
  @State playlistCount: number = 0;
  /** 本地被排除在同步范围外的收藏夹镜像数（0 歌单时用来解释「为什么是 0」） */
  @State favMirrorCount: number = 0;
  /** 其中订阅 UP 投稿歌单数 */
  @State upCount: number = 0;
  /** 同步范围曲目总数 */
  @State trackCount: number = 0;
  /** 拾音会话月份数（13 个月保留窗内的分片数） */
  @State sessionMonths: number = 0;
  /** 最近播放条数（7 天窗口内的条目数，同步范围之一） */
  @State recentCount: number = 0;
  /** 自动读取开关（打开 App 时拉取云端最新数据） */
  @State autoRead: boolean = true;
  /** 危险行按压态（UI 铁律：必给按压态） */
  @State resetPressed: boolean = false;

  /** 滚动控制器：bindToScrollable 绑给 HDS 标题栏，滚动模糊效果依赖此绑定 */
  private pageScroller: Scroller = new Scroller();
  /** 自绘顶栏渐变模糊层进度更新器（命令式驱动，高频回调零重建） */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();
  /** 按钮沉浸光感材质（与全站主按钮同源） */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 慢统计（上传统计 / 目录占用）是否正在跑：并发保护，避免 rev 连发时叠多层扫描 */
  private statsBusy: boolean = false;
  /** 上次完成慢统计的时刻（ms）：限频用，见 CLOUD_STATS_REFRESH_MS */
  private lastStatsAtMs: number = 0;
  /** 「重置云同步」进行中：拦重复点击（重置最多要等 8s 当前轮收工） */
  private resetBusy: boolean = false;

  /** 子页转场的横移量（相对页面自身宽度）：转场代理里按 push/pop 方向临时改写 */
  @State navTransX: string = '0%';

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.pageScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  aboutToAppear(): void {
    this.syncTopBlurProgress();
    // 告诉 Manager「页面在前台」：只有在前台才攒本轮结果报告，
    // 否则用户下次进页面会被一个过期结果糊一脸
    setCloudSyncPageVisible(true);
    this.refreshState();
  }

  aboutToDisappear(): void {
    setCloudSyncPageVisible(false);
  }

  /** rev 变化（一轮结束 / 状态变化）：全量重读展示态 + 反馈本轮结果 */
  private onCloudSyncRevChanged(): void {
    this.refreshState();
    const report: CloudSyncRoundReport | null = consumeCloudRoundReport();
    if (report !== null) {
      this.presentRoundReport(report);
    }
  }

  /**
   * 一轮结束的结果反馈。
   *
   * 两类语气分开：
   *   · 手动点「立即读取云端」→ **弹窗**（用户主动点了按钮，必须有明确回音，
   *     且要告诉他到底拿回了什么，而不是一句「成功」）；
   *   · 自动轮次（启动 / 回前台 / 变更去抖）→ 轻提示，且**只在真有变化时提示**，
   *     否则每次开 App 都弹一次没人受得了。
   */
  private presentRoundReport(report: CloudSyncRoundReport): void {
    if (!report.ok) {
      if (report.manual) {
        showAppInfoDialog(this.getUIContext(), {
          title: '同步未完成',
          message: report.error,
          confirmText: '知道了'
        });
        return;
      }
      // 自动轮次失败不弹窗：状态卡已经红字写着「同步异常」，再叠一个弹窗
      // 只会在用户没做任何操作时反复打断（去抖 20s 一轮，能连着弹好几次）
      showAppToast(`自动同步失败：${report.error}`, 2600);
      return;
    }
    const detail: string = `从云端读取：歌单 ${report.playlists} 个 · 拾音 ${report.sessions} 条 · 最近播放 ${report.recent} 条\n本机写回：${report.written} 个文件`;
    if (report.manual) {
      showAppInfoDialog(this.getUIContext(), {
        title: '同步完成',
        message: detail,
        confirmText: '知道了'
      });
      return;
    }
    if (report.playlists > 0 || report.sessions > 0) {
      showAppToast(`云端有新数据：歌单 ${report.playlists} · 拾音 ${report.sessions} 条`, 2200);
    }
  }

  /** 全量重读本地状态（快段：全部走内存 / Preferences，毫秒级）。
   *
   *  为什么拆两段：`getUploadStats` 要对设备目录里**每个文件**做一次
   *  `statSync` + 一次 `getCoreFileSyncState`（跨进程 IPC），`getOwnDirSizeBytes`
   *  要递归 `listFileSync` —— 这些都同步压在渲染路径上，一轮就是几百毫秒到
   *  一两秒的整段主线程阻塞，用户感知就是「同步过程中卡顿明显」。
   *  这里只算便宜的数，慢的统计交给 refreshCloudStats 异步补。 */
  private refreshState(force: boolean = false): void {
    this.cloudReady = isCloudDirAvailable();
    this.lastError = getLastCloudSyncError();
    this.lastReadAtMs = getLastReadAt();
    this.autoRead = isAutoRead();
    const scope: Playlist[] = getPlaylistsForSync();
    this.playlistCount = scope.length;
    // 收藏夹镜像是「本地有、但不在同步范围」的唯一来源：页面在歌单 0 时
    // 必须把它讲出来，否则用户看到「0 歌单 0 曲目」只会以为云端/同步坏了
    this.favMirrorCount = Math.max(0, LibraryStore.getPlaylists().length - scope.length);
    console.info(`[CloudSyncPage] refresh: all=${LibraryStore.getPlaylists().length} `
      + `scope=${scope.length} fav=${this.favMirrorCount} tracks=${this.trackCount} `
      + `months=${this.sessionMonths} recent=${this.recentCount}`);
    let ups: number = 0;
    let tracks: number = 0;
    for (let i = 0; i < scope.length; i++) {
      if (scope[i].sourceKind === 'up') {
        ups++;
      }
      tracks += scope[i].tracks.length;
    }
    this.upCount = ups;
    this.trackCount = tracks;
    this.sessionMonths = listMonthKeys().length;
    this.recentCount = LibraryStore.getRecentTracks().length;
    if (!this.cloudReady) {
      return;
    }
    this.refreshCloudStats(force);
  }

  /** 慢段（上传统计 / 目录占用）：异步 + 限频，绝不阻塞渲染 */
  private refreshCloudStats(force: boolean): void {
    if (this.statsBusy) {
      return;
    }
    // 8 秒内不重复扫：自动轮次可能连着 bump 几次 rev，每次都全量扫一遍
    // 等于把「一次卡顿」变成「连续卡顿」
    if (!force && Date.now() - this.lastStatsAtMs < CLOUD_STATS_REFRESH_MS) {
      return;
    }
    this.statsBusy = true;
    const deviceId: string = getCloudDeviceId();
    // 设备目录分类只扫一层 devices/，同步做也无妨（结果立即用于渲染）
    const dirStats: DeviceDirStats = classifyDeviceDirs(deviceId);
    this.legacyDirCount = dirStats.legacy.length;
    this.deviceCount = Math.max(1, dirStats.active.length);
    this.runCloudStats(deviceId);
  }

  /** 异步统计收尾：切碎 await，主线程只被占用毫秒级 */
  private async runCloudStats(deviceId: string): Promise<void> {
    // 目录大小先算：只扫自己目录的十几个文件，同步 stat 是毫秒级，
    // 比异步版可靠 —— 异步 `fs.listFile` 在云端占位目录上有不返回的情况，
    // 一旦卡住整个 runCloudStats 都停在这里，「云空间」永远是「—」。
    const sizeBytes: number = getOwnDirSizeBytes(deviceId);
    this.cloudSizeText = sizeBytes >= 0 ? formatBytes(sizeBytes) : '—';
    try {
      const stats: UploadStats = await getUploadStatsAsync(deviceId);
      // 设备不支持逐文件查询（13900031）时三个数一律归零 → 整行隐藏
      this.uploadPending = stats.supported ? stats.pending : 0;
      this.uploadFailed = stats.supported ? stats.failed : 0;
      this.uploadStalled = stats.supported ? stats.stalled : 0;
      this.lastStatsAtMs = Date.now();
    } catch (e) {
      console.warn(`[CloudSyncPage] stats refresh failed: ${
        e instanceof Error ? e.message : JSON.stringify(e)}`);
    } finally {
      this.statsBusy = false;
    }
  }

  /** 歌单数 0 时的解释行：区分「本地只有收藏夹镜像」与「确实还没有歌单」 */
  private zeroPlaylistHint(): string {
    if (this.favMirrorCount > 0) {
      return `本地只有 ${this.favMirrorCount} 个收藏夹镜像，它由 B 站侧维护、不参与云同步；新建的歌单会自动计入`;
    }
    return '同步范围内还没有歌单：新建歌单后会自动写入云端';
  }

  /** 状态卡副题：上次读取云端的相对时间（formatRelativeTime 口径：30 天外给兜底文案） */
  private readWhenText(): string {
    if (!(this.lastReadAtMs > 0)) {
      return '尚未读取过云端';
    }
    const rel: string = formatRelativeTime(new Date(this.lastReadAtMs).toISOString());
    if (rel.length === 0) {
      return '超过 30 天前读取过云端';
    }
    return `${rel}读取云端`;
  }

  /** 「云端设备」副文案：旧版遗留目录单列 —— 别让重装次数看起来像多台手机 */
  private deviceSummary(): string {
    const base: string = `${this.deviceCount} 台设备在同步，各写各的目录，读取时合并`;
    if (this.legacyDirCount > 0) {
      // 措辞用「旧版应用留下的目录」而不是「本机历史安装」：新版本按 ODID
      // 建目录，旧目录是随机 UUID，重装后无法证明它一定是本机写的。
      return `${base}；另有 ${this.legacyDirCount} 个旧版应用留下的目录（多为重装产生，已不计入设备数，其中数据仍会被读回）`;
    }
    return base;
  }

  /**
   * 「立即读取云端」：手动轮无视「自动读取」开关（用户点击就是意图本身）。
   * 结果由 onCloudSyncRevChanged 取报告后弹窗呈现，这里只给一个「正在进行」的
   * 轻提示 —— 不再做任何网络类型预检（「仅 WiFi 读取」已移除）。
   */
  private syncNow(): void {
    requestCloudSyncRound(true, true);
    showAppToast('正在读取云端数据…', 1600);
  }

  /**
   * 「重置云同步」两级确认（2026-11-10 用户要求：清空云端数据需要二次确认）。
   *
   * 这个动作会删云端**所有设备**的数据，原来只有一级确认、且右侧是 EMPHASIZED
   * 强调按钮，顺手一点就执行了。现在拆成两步：
   *   ① 后果说明 →「我已了解，继续」，正文明确预告「下一步还会再确认一次」；
   *   ② 最后确认 →「确认清空」，**只有这一步才真正调 resetCloudSync()**。
   * 两级都保留「本机数据不动」的说明，用户最怕的是「重置把本地歌单也清了」。
   *
   * ⚠️ 两级都走模块级单槽 showConfirm：第二个弹窗在第一个的 onConfirm 里打开，
   * 此时旧弹窗已被 onAlertButtonClick 关闭，openAlert() 按新槽值重建 controller
   *（AppAlertDialog 文件头「每次重建」口径），不会串内容。
   */
  private resetCloud(): void {
    if (this.resetBusy) {
      return;
    }
    showConfirm(this.getUIContext(), {
      title: '清空云端数据？',
      message: '将删除云端所有设备目录里的同步数据，再用本机当前内容重新上传。\n\n'
        + '执行前会先合并本机同名的重复歌单（曲目按 id 并入，不丢任何一首）。\n'
        + '本机的歌单、拾音、最近播放都不会被删除；多余的同名空壳会被移除。\n'
        + '如果还有别的设备在同步，它们的云端数据也会一并清空。\n\n'
        + '下一步还会再确认一次，才会真正执行。',
      cancelText: '取消',
      confirmText: '我已了解，继续',
      onConfirm: (): void => {
        this.confirmResetCloudFinally();
      }
    });
  }

  /** 第二级：最后确认。只有这里的确认键触发清空，取消 / 返回不产生任何写操作 */
  private confirmResetCloudFinally(): void {
    showConfirm(this.getUIContext(), {
      title: '最后确认',
      message: '云端所有设备目录里的同步数据将被删除，且无法撤销。\n\n'
        + '确定用本机当前内容重新上传吗？本机的歌单、拾音、最近播放不受影响。',
      cancelText: '返回',
      confirmText: '确认清空',
      onConfirm: (): void => {
        this.doResetCloud();
      }
    });
  }

  /** 真正执行重置：只由第二级确认回调进入，结果一律以弹窗 / toast 收口 */
  private doResetCloud(): void {
    if (this.resetBusy) {
      return;
    }
    this.resetBusy = true;
    showAppToast('正在清空云端数据…', 2000);
    resetCloudSync()
      .then((r: CloudResetResult): void => {
        this.resetBusy = false;
        showAppInfoDialog(this.getUIContext(), {
          title: r.ok ? '已开始重新上传' : '未能重置',
          message: r.message,
          confirmText: '知道了'
        });
        this.refreshState(true);
      })
      .catch((e: BusinessError): void => {
        this.resetBusy = false;
        console.warn(`[CloudSyncPage] resetCloudSync failed: ${e.code} ${e.message}`);
        showAppToast('重置失败，请稍后再试', 2600);
        this.refreshState(true);
      });
  }

  /**
   * 「立即上传 / 重试」：主动触发一次云同步。
   *
   * 为什么需要它：系统在文件写完后会自动上传，但**功耗管控**（无网 / 低电 /
   * 高温）会把上传无限期押后。没有这个入口，用户只能盯着「N 个文件等待系统
   * 上传」干等，也分不清是排队还是卡死 —— 点一下能立刻区分。
   * 结果一律按 outcome 给 toast，不向 UI 抛异常。
   */
  private uploadNow(): void {
    if (this.uploadBusy) {
      return;
    }
    this.uploadBusy = true;
    triggerUpload()
      .then((r: UploadTriggerResult): void => {
        this.uploadBusy = false;
        showAppToast(r.message, r.outcome === UploadTriggerOutcome.FAILED ? 2800 : 2000);
        // force：用户刚点了按钮，必须立刻看到数字变化（不受 8s 限频约束）
        this.refreshState(true);
      })
      .catch((e: BusinessError): void => {
        this.uploadBusy = false;
        console.warn(`[CloudSyncPage] triggerUpload failed: ${e.code} ${e.message}`);
        this.refreshState(true);
      });
  }

  /** 上传行文案：失败 > 暂停 > 排队（按「需不需要人处理」排优先级） */
  private uploadRowText(): string {
    if (this.uploadFailed > 0) {
      return `${this.uploadFailed} 个文件上传失败`;
    }
    if (this.uploadStalled > 0) {
      return `${this.uploadStalled} 个文件同步已暂停`;
    }
    return `${this.uploadPending} 个文件等待系统上传`;
  }

  /** 上传行颜色：失败红 / 暂停灰 / 排队黄（状态点与文字同色） */
  private uploadStateColor(): ResourceColor {
    if (this.uploadFailed > 0) {
      return $r('app.color.state_error');
    }
    if (this.uploadStalled > 0) {
      return $r('app.color.text_tertiary');
    }
    return $r('app.color.state_warning');
  }

  /** 上传动作按钮文案：失败或暂停 → 重试；纯排队 → 立即上传 */
  private uploadActionLabel(): string {
    if (this.uploadBusy) {
      return '上传中…';
    }
    return this.uploadFailed > 0 || this.uploadStalled > 0 ? '重试' : '立即上传';
  }

  /**
   * 状态卡上传行（三种状态共用一行，切换时状态卡不跳高）。
   *
   * 动作文字走项目既有文字按钮口径（13fp + themePrimary + height 44，
   * FavSyncPage「全选」同款）：44vp 保证命中区，onTouch 给按压态。
   */
  @Builder
  UploadStatusRow() {
    Row({ space: 6 }) {
      Row()
        .width(7)
        .height(7)
        .borderRadius(3.5)
        .backgroundColor(this.uploadStateColor())
      Text(this.uploadRowText())
        .fontSize(12)
        .fontColor(this.uploadStateColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(this.uploadActionLabel())
        .fontSize(13)
        .fontColor(this.themePrimary)
        .height(44)
        .padding({ left: 12 })
        .opacity(this.uploadPressed ? 0.55 : 1)
        .onTouch((e: TouchEvent): void => {
          if (e.type === TouchType.Down) {
            this.uploadPressed = true;
          } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
            this.uploadPressed = false;
          }
        })
        .onClick((): void => {
          this.uploadNow();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ top: 6 })
  }

  /** 打开系统设置（系统同步开关的唯一入口）：深链失败给兜底提示 */
  private openSystemSettings(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ctx.startAbility({
      bundleName: 'com.huawei.hmos.settings',
      abilityName: 'MainAbility'
    })
      .then((): void => {
        showAppToast('请在 设置 → 云空间 中打开本应用的同步开关', 2600);
      })
      .catch((e: BusinessError): void => {
        console.error(`[CloudSyncPage] open settings failed: ${e.code} ${e.message}`);
        showAppToast('打开系统设置失败，请手动前往 设置 → 云空间', 2400);
      });
  }

  /** 「我已开启，重新检测」：重跑探针 + 刷新两态；探针通过即触发首轮读取 */
  private recheck(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // cloudFileDir 为空导致 init 未完成的场合补一次 init（已 init 时为 no-op）
    initCloudDirClient(ctx);
    reprobeCloudDir();
    this.refreshState(true);
    if (this.cloudReady) {
      showAppToast('云空间已连接，开始读取云端数据', 2200);
      requestCloudSyncRound(true, true);
    } else {
      showAppToast('暂未检测到云空间，请确认开关已打开', 2400);
    }
  }

  /** 自动读取开关：值没变直接忽略（SuffixSwitch isCheck 翻转误触发守卫） */
  private onAutoReadToggle(v: boolean): void {
    if (v === this.autoRead) {
      return;
    }
    setAutoRead(v);
    this.autoRead = v;
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

  /** 标题栏内容（titleBar 的 stackBuilder 承载）：「云空间同步」标题（返回键为 HDS 默认键） */
  @Builder
  cloudBar() {
    NavTitleRow({ title: '云空间同步' })
  }

  /** 标题行收窄容器（BarNarrowShell 共用件，平板模式宽度适配） */
  @Builder
  cloudBarNarrow() {
    BarNarrowShell({ bar: (): void => {
      this.cloudBar()
    } })
  }

  /** 指标格：数值 + 标签（状态卡四格共用） */
  @Builder
  MeterCell(value: string, label: string) {
    Column() {
      Text(value)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /** 状态卡（已连接态首卡）：状态点 + 读时间 + 待上传 + 异常信息 + 四格指标。
   *  外层 Row 16vp 让位 + 内层 Column 承载底色圆角（InsetCard 同款口径，
   *  圆角放大到 16 与行卡 12 区分层级）。 */
  @Builder
  StatusCard() {
    Row() {
      Column() {
        Row({ space: 7 }) {
          // 状态点：圆形用 borderRadius 实现（Circle.fill 是 26.0.0 API，
          // 本项目 compatibleSdkVersion 6.1.0(23)，避免引入版本门槛）
          Row()
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(this.lastError.length > 0
              ? $r('app.color.state_error') : $r('app.color.state_success'))
          Text(this.lastError.length > 0 ? '同步异常' : '已同步')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
        }
        .alignItems(VerticalAlign.Center)

        Text(this.readWhenText())
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 6 })

        if (this.uploadFailed > 0 || this.uploadPending > 0 || this.uploadStalled > 0) {
          this.UploadStatusRow()
        }

        if (this.lastError.length > 0) {
          Text(this.lastError)
            .fontSize(12)
            .fontColor($r('app.color.state_error'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 6 })
        }

        Row() {
          this.MeterCell(`${this.playlistCount}`, '歌单')
          this.MeterCell(`${this.trackCount}`, '曲目')
          this.MeterCell(`${this.sessionMonths}`, '拾音月份')
          this.MeterCell(this.cloudSizeText, '云空间')
        }
        .width('100%')
        .margin({ top: 14 })

        if (this.playlistCount === 0) {
          Text(this.zeroPlaylistHint())
            .fontSize(11)
            .lineHeight(16)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .margin({ top: 10 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding(16)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(16)
      .clip(true)
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  /** 引导态提示条（原型 .note）：系统开关 App 无法代开，指路 + 宽心 */
  @Builder
  GuideNote() {
    Row({ space: 8 }) {
      Text('!')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.themePrimary)
      Text('这是系统开关，App 不能代你打开。只需设置一次，之后自动生效。')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
        .lineHeight(18)
    }
    .alignItems(VerticalAlign.Top)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(10)
    .backgroundColor($r('app.color.brand_surface'))
    .margin({ left: 16, right: 16 })
  }

  /** 引导步骤行：序号圆点 + 三段文案（中段加粗，原型 .step 口径） */
  @Builder
  StepRow(no: number, beforeText: string, boldText: string, afterText: string) {
    Row({ space: 10 }) {
      Text(`${no}`)
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.themePrimary)
        .width(20)
        .height(20)
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.brand_surface'))
        .borderRadius(10)
      Text() {
        Span(beforeText)
          .fontColor($r('app.color.text_secondary'))
        Span(boldText)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Span(afterText)
          .fontColor($r('app.color.text_secondary'))
      }
      .fontSize(13)
      .lineHeight(20)
      .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
    .padding({ top: 7, bottom: 7 })
  }

  /** 主操作按钮（打开系统设置 / 立即读取云端）：
   *  外层 Row 16vp 让位 + 内部 100% 宽（百分比宽不含外边距，会向右溢出） */
  @Builder
  PrimaryButton(label: string, onTap: () => void) {
    Row() {
      Button(label, { type: ButtonType.Normal })
        .width('100%')
        .height(44)
        .borderRadius(BUTTON_RADIUS_VP)
        .backgroundColor(this.themePrimary)
        .fontColor(this.themeOn)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .attributeModifier(this.buttonMaterial)
        .onClick((): void => {
          onTap();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .margin({ top: 14 })
  }

  /** 次操作按钮（我已开启，重新检测）：灰底弱化层级 */
  @Builder
  GhostButton(label: string, onTap: () => void) {
    Row() {
      Button(label, { type: ButtonType.Normal })
        .width('100%')
        .height(44)
        .borderRadius(BUTTON_RADIUS_VP)
        .backgroundColor($r('app.color.bg_divider'))
        .fontColor($r('app.color.text_primary'))
        .fontSize(15)
        .attributeModifier(this.buttonMaterial)
        .onClick((): void => {
          onTap();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .margin({ top: 10 })
  }

  /**
   * 「清空云端数据」危险行：整行可点，主标题用错误色。
   *
   * 不复用 HdsListItemCard —— 它的文字颜色只能经 TextModifier 改，而这里需要
   * 的就是「红字 + 整行可点」。水平缩进 16 与相邻列表行对齐（CardDivider 的左
   * 缩进同口径），手写一行更好控。
   */
  @Builder
  ResetCloudRow() {
    Column() {
      Text('清空云端数据')
        .fontSize(15)
        .fontColor($r('app.color.state_error'))
        .width('100%')
      Text('合并同名歌单后清空云端并按本机重传 · 需两次确认')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: 3 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .opacity(this.resetPressed ? 0.5 : 1)
    .onTouch((e: TouchEvent): void => {
      if (e.type === TouchType.Down) {
        this.resetPressed = true;
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.resetPressed = false;
      }
    })
    .onClick((): void => {
      this.resetCloud();
    })
  }

  build() {
    HdsNavDestination() {
      Stack() {
      List({ scroller: this.pageScroller }) {
        // 顶部空白占位条目（官方沉浸口径）：高度 = safeTop + 56（MINI 标题栏），
        // 静止位首个真实条目恰从栏底起排，滚动时从材质下方穿过。
        ListItem() {
          Row()
            .width('100%')
            .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)
        }

        if (!this.cloudReady) {
          // ── 未开启系统开关：指路 + 复检（方案 §2「无法代劳」口径） ──
          ListItem() {
            this.GuideNote()
          }
          ListItem() {
            SectionHeader({ headerText: '三步开启' })
          }
          ListItem() {
            InsetCard() {
              Column() {
                this.StepRow(1, '确认已登录', '华为账号', '（设置 → 顶部账号）')
                this.StepRow(2, '进入 ', '设置 → 云空间 → 本应用', '，打开同步开关')
                this.StepRow(3, '回到这里点', '「重新检测」', '')
              }
              .padding({ top: 8, bottom: 8 })
            }
          }
          ListItem() {
            this.PrimaryButton('打开系统设置', (): void => {
              this.openSystemSettings();
            })
          }
          ListItem() {
            this.GhostButton('我已开启，重新检测', (): void => {
              this.recheck();
            })
          }
          ListItem() {
            SectionFooter({
              noteText: '开启后数据写入系统云端目录，由系统负责上传与多设备同步，不经过任何第三方服务器。'
            })
          }
        } else {
          // ── 已连接：状态卡 + 开关 + 数据行 + 手动读取 ──
          ListItem() {
            this.StatusCard()
          }

          ListItem() {
            SectionHeader({ headerText: '同步' })
          }

          ListItem() {
            InsetCard() {
              HdsListItemCard({
                textItem: {
                  primaryText: { text: '自动读取' },
                  secondaryText: { text: '打开 App 时拉取云端最新数据' }
                },
                suffixItem: new SuffixSwitch({
                  isCheck: this.autoRead,
                  selectColor: this.themePrimary,
                  onChange: (v: boolean): void => {
                    this.onAutoReadToggle(v);
                  }
                }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0
              })
            }
          }

          ListItem() {
            SectionFooter({ noteText: '关闭「自动读取」后打开 App 不再拉取云端，仍可点下方按钮手动读取' })
          }

          ListItem() {
            SectionHeader({ headerText: '数据' })
          }

          ListItem() {
            InsetCard() {
              HdsListItemCard({
                textItem: {
                  primaryText: { text: '云端设备' },
                  secondaryText: {
                    text: this.deviceSummary()
                  }
                },
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0
              })

              CardDivider()

              HdsListItemCard({
                textItem: {
                  primaryText: { text: '同步内容' },
                  secondaryText: {
                    text: `歌单 ${this.playlistCount}（含 ${this.upCount} 个订阅）· 拾音 ${this.sessionMonths} 个月 · 最近播放 ${this.recentCount} 条`
                  }
                },
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0
              })
            }
          }

          ListItem() {
            this.PrimaryButton('立即读取云端', (): void => {
              this.syncNow();
            })
          }

          ListItem() {
            SectionFooter({
              noteText: '上传默认由系统在充电和 WiFi 下完成，通常几分钟到几小时；急用可点状态卡里的「立即上传」手动催一次。已自动排除 B 站收藏夹 —— 它跟随你的 B 站账号，不需要上云。'
            })
          }

          ListItem() {
            SectionHeader({ headerText: '重置' })
          }

          ListItem() {
            InsetCard() {
              this.ResetCloudRow()
            }
          }

          ListItem() {
            SectionFooter({
              noteText: '云端数据被搞乱、或想彻底断干净重来时用。本机的歌单、拾音、最近播放都不会被删除，重置后会按本机内容重新上传；若还有别的设备在同步，它们留在云端的数据也会一起清空。'
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
      // 大屏适配：内容列收窄居中（与原设置页同口径走 TwoColumnLayout.contentMaxWidth）
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
      // 自绘渐变模糊层驱动：逐帧更新 + 停止校准终态（渐变软边由 overlay 承担）
      .onDidScroll((xOffset: number, yOffset: number): void => {
        this.syncTopBlurProgress();
      })
      .onScrollStop((): void => {
        this.syncTopBlurProgress();
      })

      // 顶栏渐变模糊层：盖 List 内容之上（z 序低于 HDS titleBar），进度命令式驱动
      TopGradientBlurOverlay({
        barHeightVp: this.safeTop + NAV_TITLE_BAR_HEIGHT,
        updater: this.topBlurUpdater
      })
      }
    }
    // HDS 沉浸光感标题栏：材质 / 滚动模糊 / 温控统一由 HdsTitleBarStyle 决策
    //（HDS 内置滚动效果关闭：渐变模糊由自绘 TopGradientBlurOverlay 承担，防双重模糊）
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        // 箭头包裹保证 builder 内 this 指向本组件（裸引用会丢失 this）
        stackBuilder: (): void => {
          this.cloudBarNarrow();
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
    // 系统返回拦截（与 AppIconSettingsPage 同款，无 overlay 时走默认 pop）
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
export function CloudSyncPageBuilder(): void {
  CloudSyncPage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接 @Builder 引用（编译期校验）。 */
export const CloudSyncPageWrapped: WrappedBuilder<[]> = wrapBuilder(CloudSyncPageBuilder);
