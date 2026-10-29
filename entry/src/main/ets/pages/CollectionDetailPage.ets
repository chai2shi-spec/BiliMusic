/**
 * 合集详情页（路由名 CollectionDetail）：多 P 合集（同一视频的多个分 P，
 * B 站音乐「N 首精选」这类）的分 P 列表页。
 *
 * 入口（都经 CollectionDetailRouteParam 携 bvid + 首帧兜底值进来）：
 *  · 下载页「合集」组卡片点击（原地展开保留给右侧箭头）；
 *  · utils/CollectionNavigator 分流（搜索 / 首页 / UP 主页在线条目点击
 *    「先查后分流」：videos > 1 跳本页，否则回落直接播放）。
 *
 * 功能（PlaylistDetail 同款口径）：
 *  · 分 P 列表（expandVideoParts 数据源，揭示切片 20/批）+ 已下载徽标
 *   （musicId 精确匹配，P1 与 `bvid#cid` 各自独立判定）；
 *  · 播放全部 / 随机播放（页内洗牌副本 + playAll，不动播放内核）；
 *  · 多选批量：加入歌单 / 串行下载（每首间隔节流）；
 *  · 页内搜索（标题 / 歌手本地过滤）；「⋯」菜单（加入队列 / 下载 / 进 UP 主页）；
 *  · 保存为歌单；头部 UP 主可跳转。
 *
 * 页面结构照抄 PlaylistDetail：HDS 沉浸标题栏（stackBuilder 空占位 +
 * bottomBuilder 头部区实测高度），列表视口铺满全屏 + 首个空白占位条目让位，
 * 滚动模糊由 TopGradientBlurOverlay 命令式驱动。
 * 与 PlaylistDetail 的差异（有意）：
 *  · 数据源是远端 view（一次性拉全量分 P），不是本地歌单 —— 失败态 + 重试；
 *  · 条目不可移除 / 拖动排序（分 P 顺序由服务端决定）；
 *  · 批量下载不标记 playlistId —— 任务按 musicId 的 bvid 归组，
 *    下载页仍聚成本合集的组卡（点组卡即回到本页）。
 */

import { Track, VideoDetail, DownloadTask, DownloadStatus, Playlist } from '../model/MusicModels';
import * as BilibiliApi from '../api/BilibiliApi';
import { expandVideoParts } from '../api/BilibiliApi';
import { formatDurationText, toHttpsUrl } from '../utils/TextUtil';
import { LibraryStore } from '../service/LibraryStore';
import { MusicPlayer } from '../player/MusicPlayer';
import { TrackItem } from '../components/TrackItem';
import { SkeletonTrackItem } from '../components/SkeletonTrackItem';
import { CoverImage } from '../components/CoverImage';
import { showConfirm } from '../components/AppAlertDialog';
import { DownloadManager, DownloadStartResult, WIFI_ONLY_BLOCKED } from '../service/DownloadManager';
import { currentNetworkLabel } from '../utils/NetworkUtil';
import { NavStackHolder } from '../service/NavStackHolder';
import { CollectionDetailRouteParam, NavRouteParamReader, UpSpaceRouteParam } from '../service/NavRouteParams';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NAV_TRANSITION_MS, BUTTON_RADIUS_VP, SEARCH_FILTER_DEBOUNCE_MS } from '../common/constants/InteractionConstants';
import { HdsNavDestination, BottomBuilderShowType } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { CustomContentDialog } from '@kit.ArkUI';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier
} from '../utils/HeaderBarMaterial';
import { SearchBox } from '../components/SearchBox';
import { filterTracksByKeyword } from '../utils/TrackFilter';
import {
  CONTENT_END_OFFSET,
  STORE_DOWNLOAD_TASKS,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE,
  STORE_THEME_DEEP
} from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { TwoColumnLayout } from '../common/utils/TwoColumnList';
import { showAppToast } from '../components/AppToast';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';

/**
 * 分 P 列表揭示切片的每批条数（PlaylistDetail PD_REVEAL_PAGE_SIZE 同款）：
 * 分 P 数据经 expandVideoParts 一次性全量拉回（本地持有，不发分页请求），
 * onReachEnd 每次多放一批，首屏只建第一批的行。
 */
const CD_REVEAL_PAGE_SIZE: number = 20;

/**
 * 多选批量下载串行入队的每首间隔：requestDownload 内部每首选一次 view 请求，
 * 密集连发会被 B 站匿名限流（PlaylistDetail / PlaylistsPage 同一条经验）。
 */
const CD_ENQUEUE_GAP_MS: number = 350;

/** 多选态搜索区 / 动作区交叉淡化时长（PlaylistDetail PD_SELECT_FADE_MS 同款） */
const CD_SELECT_FADE_MS: number = 250;

/** 头部区（bottomBuilder 承载）实测前的估计高度：封面行 + 按钮两行 + padding */
const COLLECTION_HEADER_ESTIMATE_HEIGHT: number = 220;

/** ArkTS 没有原生 sleep，用 setTimeout 包一个 Promise（批量下载串行节流用） */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}

/**
 * 页内洗牌副本（Fisher-Yates）：随机播放只洗「本页拿到的分 P 列表」，
 * 不改 MusicPlayer 内核（其 shuffle 为私有）。
 */
function shuffleTracks(list: Track[]): Track[] {
  const out: Track[] = list.slice();
  for (let i = out.length - 1; i > 0; i--) {
    const j: number = Math.floor(Math.random() * (i + 1));
    const tmp: Track = out[i];
    out[i] = out[j];
    out[j] = tmp;
  }
  return out;
}

/** 播放量人话化：1.2万 / 3.4亿（PlaylistImportPage 同款口径） */
function formatPlayCount(n: number): string {
  if (n >= 100000000) {
    return `${(n / 100000000).toFixed(1)}亿`;
  }
  if (n >= 10000) {
    return `${(n / 10000).toFixed(1)}万`;
  }
  return `${n}`;
}

@Component
export struct CollectionDetailPage {
  /** 列表滚动控制器：bindToScrollable 绑给 HDS 标题栏驱动滚动模糊 */
  private listScroller: Scroller = new Scroller();
  /** 头部按钮（播放全部等）沉浸光感材质修饰器：26+ 生效，低版本 no-op 显实色兜底 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /**
   * 搜索本地过滤防抖定时器 id：按键路径的过滤重算延迟 200ms（分 P 列表可长，
   * 每键同步全量过滤 + 列表 diff 有卡顿风险）；clearSearch / load() 数据刷新
   * 路径直调 applyLocalFilter 不防抖。aboutToDisappear 清理，防回调打进
   * 已销毁实例。
   */
  private filterDebounceTimer: number = -1;
  /** 顶栏渐变模糊层进度更新器（命令式驱动，不标 @State） */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();
  private player: MusicPlayer = MusicPlayer.getInstance();

  /** 目标合集 bvid（路由参数带入，aboutToAppear 取参一次；空 = 失败态） */
  private bvid: string = '';

  @State loading: boolean = false;
  @State loadFailed: boolean = false;
  @State failReason: string = '';
  /** 分 P 全量（expandVideoParts 一次拉回，本地持有） */
  @State parts: Track[] = [];
  /** 已揭示切片（渲染数据源，onReachEnd 增量放行） */
  @State tracks: Track[] = [];
  /** 头部区展示字段（load() 预计算，@Builder 体内不做拼接 / 判空） */
  @State headerTitle: string = '';
  @State coverUrl: string = '';
  @State metaText: string = '';
  @State ownerName: string = '';
  @State ownerMid: string = '';
  /** 「保存为歌单」对话框里的歌单名（打开时预填视频标题） */
  @State collectionName: string = '';
  /** 头部区实测高（bottomBuilder 内层根节点 onAreaChange 回写；0 = 未实测，列表挂载门控） */
  @State headerAreaHeight: number = 0;

  /** 页内搜索：输入即本地过滤分 P（标题 / 歌手，小写化匹配） */
  @State searchKeyword: string = '';
  /** 本地过滤全量匹配；空数组 = 无关键词或 0 命中 */
  @State filteredTracks: Track[] = [];

  // ===== 多选（PlaylistDetail 同款口径） =====
  @State selecting: boolean = false;
  @State selectedIds: string[] = [];
  @State downloadingSelected: boolean = false;
  /** 「加入歌单」弹窗曲目（多选批量入口专用） */
  private pickerTracks: Track[] = [];
  /** 弹窗打开时的可加歌单快照（「新建歌单并加入」的重名检查基于它即可） */
  private playlistOptions: Playlist[] = [];
  private playlistPickerController: CustomDialogController | undefined = undefined;
  /** 「保存为歌单」对话框 */
  private collectionSaverController: CustomDialogController | undefined = undefined;

  /** 子页转场横移量：常驻 '0%'，转场代理按 push/pop 临时改写 */
  @State navTransX: string = '0%';

  /** 状态栏高度（vp）：标题栏整体落在状态栏下方 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 下载任务快照：派生「哪些分 P 已下载完成」（徽标即时出现 / 消失） */
  @StorageLink(STORE_DOWNLOAD_TASKS) @Watch('onDownloadTasks') downloadTasks: DownloadTask[] = [];
  /** 已下载完成的分 P id 集合（数组而非 Set —— @State 感知不到 Set 内容变化） */
  @State downloadedIds: string[] = [];
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;

  /** HDS 标题栏整体让位量（vp）= safeTop + 标题行 56 + 头部区实测高 */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT + this.headerAreaHeight;
  }

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.listScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  aboutToAppear(): void {
    // 挂载前先存当前偏移对应的进度，防「已滚过再进页」首帧缺模糊
    this.syncTopBlurProgress();
    const routeParam: CollectionDetailRouteParam | null =
      NavRouteParamReader.readCollectionDetailParam(NavStackHolder.stack);
    if (routeParam === null || routeParam.bvid.length === 0) {
      this.loadFailed = true;
      this.failReason = '没有拿到合集信息，请返回重新进入';
      return;
    }
    this.bvid = routeParam.bvid;
    // 首帧兜底值：入口条目已有数据（拉取回来后被 view 真值覆盖）
    this.headerTitle = routeParam.title;
    this.coverUrl = routeParam.cover;
    this.ownerName = routeParam.artist;
    this.ownerMid = routeParam.upMid;
    // @Watch 不为初始同步触发（工程内已踩过两次的坑）：补一次已下载集合初算
    this.rebuildDownloadedIds();
    DownloadManager.getInstance().ensureLoaded().catch((e: Error): void => {
      console.error(`load downloads failed: ${JSON.stringify(e)}`);
    });
    this.playlistPickerController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: '加入歌单',
        contentBuilder: (): void => {
          this.PlaylistPickerBody();
        },
        buttons: [
          {
            value: '取消',
            buttonStyle: ButtonStyleMode.TEXTUAL,
            action: (): void => {
              this.playlistPickerController?.close();
            }
          }
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.collectionSaverController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: '保存为歌单',
        contentBuilder: (): void => {
          this.SaverBody();
        },
        buttons: [
          {
            value: '取消',
            buttonStyle: ButtonStyleMode.TEXTUAL,
            action: (): void => {
              this.cancelSave();
            }
          },
          {
            value: '保存',
            buttonStyle: ButtonStyleMode.EMPHASIZED,
            action: (): void => {
              this.confirmSave();
            }
          }
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.load();
  }

  aboutToDisappear(): void {
    // 搜索过滤防抖定时器：销毁前清理，防回调打进已销毁实例。
    if (this.filterDebounceTimer >= 0) {
      clearTimeout(this.filterDebounceTimer);
      this.filterDebounceTimer = -1;
    }
  }

  // ===== 数据加载 =====

  /**
   * 拉取分 P 列表 + 头部资料。expandVideoParts 内部走 getVideoDetail
   * （viewCache 命中不重复发请求），头部资料再取一次 detail 也是缓存命中，
   * 全程只发一次 view 请求（分 P 不完整时多一次 pagelist 补全）。
   */
  private async load(): Promise<void> {
    if (this.loading || this.bvid.length === 0) {
      return;
    }
    this.loading = true;
    try {
      const parts: Track[] = await expandVideoParts(this.bvid);
      const detail: VideoDetail = await BilibiliApi.getVideoDetail(this.bvid);
      // 头部真值（入口兜底值仅在此前显示）
      if (detail.title.length > 0) {
        this.headerTitle = detail.title;
      }
      this.coverUrl = toHttpsUrl(detail.pic);
      if (detail.owner) {
        this.ownerName = detail.owner.name;
        this.ownerMid = String(detail.owner.mid);
      }
      let totalSec: number = 0;
      for (let i = 0; i < parts.length; i++) {
        totalSec += parts[i].duration;
      }
      const durationText: string = formatDurationText(totalSec);
      const playText: string = formatPlayCount(detail.stat ? detail.stat.view : 0);
      this.metaText = `${parts.length} 个分P · 总时长 ${durationText.length > 0 ? durationText : '未知'} · ${playText} 播放`;
      this.parts = parts;
      this.applyLocalFilter();
      this.tracks = this.activeSource().slice(0, CD_REVEAL_PAGE_SIZE);
      this.loadFailed = false;
      this.failReason = '';
    } catch (e) {
      const err: Error = e as Error;
      this.loadFailed = true;
      this.failReason = this.describeError(err);
    }
    this.loading = false;
  }

  /** 把异常翻译成一句能直接决定动作的话（SeasonSeriesDetailPage 同款，仅默认文案随本页语境换词） */
  private describeError(e: Error): string {
    const raw: string = e && e.message ? e.message : '';
    if (raw.length === 0) {
      return '合集加载失败';
    }
    const matched: RegExpMatchArray | null = raw.match(/\[(-?\d+)\]\s*([^(\/]*)/);
    if (matched) {
      const code: string = matched[1];
      const msg: string = (matched[2] || '').trim();
      if (code === '-404') {
        return '视频不存在或已下架';
      }
      if (code === '-352' || code === '-509' || code === '-799') {
        return `B 站限制了当前访问（${code}${msg.length > 0 ? ' ' + msg : ''}），过一会儿再试`;
      }
      if (code === '-403') {
        return `请求被 B 站拒绝（${code}），签名或身份校验未通过`;
      }
      return `加载失败（${code}${msg.length > 0 ? ' ' + msg : ''}）`;
    }
    if (raw.indexOf('HTTP 412') >= 0) {
      return 'B 站拒绝了匿名访问（412），登录后重试通常可解';
    }
    if (raw.indexOf('HTTP') >= 0) {
      return raw;
    }
    return `加载失败：${raw.slice(0, 40)}`;
  }

  /** 失败后的重试：清干净状态重新拉。view 走 biliFetchRetry（自带退避），无需风控冷却。 */
  private retry(): void {
    if (this.loading) {
      return;
    }
    this.loadFailed = false;
    this.failReason = '';
    this.parts = [];
    this.tracks = [];
    this.exitSelecting();
    this.load();
  }

  /** 当前切片源：有关键词 → 全量匹配数组；否则 → 分 P 全量 */
  private activeSource(): Track[] {
    if (this.searchKeyword.trim().length > 0) {
      return this.filteredTracks;
    }
    return this.parts;
  }

  /** 是否还有未揭示的分 P（底部状态行与 onReachEnd 闸门共用） */
  private hasMoreTracks(): boolean {
    return this.tracks.length < this.activeSource().length;
  }

  /** List 的 onReachEnd：每次多放一批（增量 push，不整表重赋值） */
  private onReachEnd(): void {
    const all: Track[] = this.activeSource();
    if (this.tracks.length >= all.length) {
      return;
    }
    const from: number = this.tracks.length;
    const next: number = Math.min(from + CD_REVEAL_PAGE_SIZE, all.length);
    for (let i = from; i < next; i++) {
      this.tracks.push(all[i]);
    }
  }

  // ===== 页内搜索（纯本地过滤） =====

  /**
   * 本地过滤：标题 / 歌手包含关键词（小写化匹配），输入即生效。
   * 过滤谓词收口在 filterTracksByKeyword（与 PlaylistDetail / UpSpacePage
   * 三页共用同一份实现）。空关键词 → 清空匹配。
   */
  private applyLocalFilter(): void {
    this.filteredTracks = filterTracksByKeyword(this.parts, this.searchKeyword);
  }

  /**
   * 输入变化（按键路径）：过滤重算 + 切片重置走 200ms 防抖 —— 分 P 列表可长，
   * 每键同步全量过滤 + 列表 diff 有卡顿风险；新关键词 = 新列表，防抖回调里
   * 从头揭示第一批。回调读当刻 this.searchKeyword（不捕获旧词），幂等。
   */
  private onKeywordChanged(): void {
    this.exitSelecting();
    if (this.filterDebounceTimer >= 0) {
      clearTimeout(this.filterDebounceTimer);
    }
    this.filterDebounceTimer = setTimeout((): void => {
      this.filterDebounceTimer = -1;
      this.applyLocalFilter();
      this.tracks = this.activeSource().slice(0, CD_REVEAL_PAGE_SIZE);
    }, SEARCH_FILTER_DEBOUNCE_MS);
  }

  /**
   * 框内 × 清除：关键词置空 + 退回全量第一批。取消在途防抖后立即执行 ——
   * 防抖回调若不清，清态后 200ms 会拿旧词把过滤结果复活回来。
   */
  private clearSearch(): void {
    if (this.filterDebounceTimer >= 0) {
      clearTimeout(this.filterDebounceTimer);
      this.filterDebounceTimer = -1;
    }
    this.searchKeyword = '';
    this.applyLocalFilter();
    this.tracks = this.activeSource().slice(0, CD_REVEAL_PAGE_SIZE);
  }

  // ===== 已下载徽标 =====

  /** 下载快照变化（新增完成 / 删除任务）：即时重建已下载集合，徽标跟着出现 / 消失 */
  private onDownloadTasks(): void {
    this.rebuildDownloadedIds();
  }

  /** 下载快照到达：重建「已下载完成」分 P id 集合（COMPLETED 且文件还在才算数） */
  private rebuildDownloadedIds(): void {
    const ids: string[] = [];
    for (let i = 0; i < this.downloadTasks.length; i++) {
      const t: DownloadTask = this.downloadTasks[i];
      if (t.status === DownloadStatus.COMPLETED && t.localFilePath.length > 0
        && ids.indexOf(t.musicId) < 0) {
        ids.push(t.musicId);
      }
    }
    this.downloadedIds = ids;
  }

  /** 这首分 P 是否已下载完成：musicId 精确匹配（P1 纯 bvid 与 `bvid#cid` 各自独立判定） */
  private isDownloaded(t: Track): boolean {
    return this.downloadedIds.indexOf(t.id) >= 0;
  }

  // ===== 播放 =====

  /** 播放全部：整份分 P 列表铺队列（playAll 内部对 P1 的 id 去重无副作用） */
  private playAllParts(): void {
    if (this.parts.length === 0) {
      this.toast('该合集还没有可播放的分 P', 1500);
      return;
    }
    this.player.playAll(this.parts);
  }

  /** 随机播放：页内洗牌副本铺队列（播放内核的洗牌不对外，这里只洗本页列表） */
  private shuffleAndPlay(): void {
    if (this.parts.length === 0) {
      this.toast('该合集还没有可播放的分 P', 1500);
      return;
    }
    this.player.playAll(shuffleTracks(this.parts));
  }

  // ===== 曲目菜单（加入队列 / 下载 / 进 UP 主页） =====

  private trackMenuItems(track: Track): MenuElement[] {
    return [
      {
        value: '加入队列',
        action: (): void => {
          this.player.addToQueue(track);
          this.toast('已加入播放队列', 1500);
        }
      },
      {
        value: '下载',
        action: (): void => {
          this.requestDownload(track);
        }
      },
      {
        value: '进入 UP 主页',
        action: (): void => {
          this.openUpSpace();
        }
      }
    ];
  }

  private requestDownload(track: Track): void {
    DownloadManager.getInstance().requestDownload(track, false)
      .then((r: DownloadStartResult): void => {
        if (r.blockedReason.length > 0) {
          this.confirmDownloadOnCellular(track);
          return;
        }
        this.toast(this.downloadResultText(r), 2000);
      })
      .catch((e: Error): void => {
        console.error(`requestDownload failed: ${e.message}`);
        this.toast('下载启动失败', 1800);
      });
  }

  /** 下载请求结果文案：0 条 / 1 条 / N 条要分开说（分 P 在内核按 cid 单曲入队，不会整合集展开） */
  private downloadResultText(r: DownloadStartResult): string {
    if (r.queued === 0) {
      return r.skipped > 0 ? '该分 P 已在下载列表中' : '没有可下载的分 P';
    }
    const head: string = '已开始下载';
    const tail: string = r.skipped > 0 ? `（另有 ${r.skipped} 条已在列表中）` : '';
    return `${head}，可在「下载」页查看进度${tail}`;
  }

  /** 「仅 WiFi 下载」被触发：先问一句（开关的本意是防偷跑，不是绝对禁用） */
  private confirmDownloadOnCellular(track: Track): void {
    showConfirm(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: `${WIFI_ONLY_BLOCKED}\n当前网络：${currentNetworkLabel()}`,
      confirmText: '继续下载',
      onConfirm: (): void => {
        DownloadManager.getInstance().requestDownload(track, true)
          .then((r: DownloadStartResult): void => {
            this.toast(r.queued > 0 ? '已开始下载' : '没有可下载的分 P', 1800);
          })
          .catch((e: Error): void => {
            console.error(`requestDownload(ignoreWifiLimit) failed: ${e.message}`);
            this.toast('下载启动失败', 1800);
          });
      }
    });
  }

  // ===== UP 主页跳转 =====

  /**
   * 头部 UP 名 / 条目「进入 UP 主页」共用：用页级 ownerMid / ownerName
   * （expandVideoParts 不填分 P 的 upMid，分 P 级跳转只能靠页级资料）。
   * ownerMid 未知时用 bvid 走 getVideoDetail 换（viewCache 命中零开销）。
   */
  private async openUpSpace(): Promise<void> {
    let mid: string = this.ownerMid;
    if (mid.length === 0) {
      this.toast('正在获取投稿作者…', 1200);
      try {
        const detail: VideoDetail = await BilibiliApi.getVideoDetail(this.bvid);
        mid = detail.owner ? String(detail.owner.mid) : '';
        if (detail.owner) {
          this.ownerName = detail.owner.name;
          this.ownerMid = mid;
        }
      } catch (e) {
        console.error(`openUpSpace resolve mid failed: ${JSON.stringify(e)}`);
        mid = '';
      }
      if (mid.length === 0) {
        this.toast('获取 UP 主失败', 1500);
        return;
      }
    }
    NavStackHolder.stack.pushPathByName('UpSpace', new UpSpaceRouteParam(mid, this.ownerName, ''));
  }

  // ===== 多选核心（PlaylistDetail 同款口径） =====

  private enterSelecting(): void {
    this.selecting = true;
    this.selectedIds = [];
  }

  private toggleSelected(track: Track): void {
    if (this.selectedIds.indexOf(track.id) >= 0) {
      this.selectedIds = this.selectedIds.filter((id: string): boolean => id !== track.id);
      return;
    }
    const next: string[] = this.selectedIds.slice(0);
    next.push(track.id);
    this.selectedIds = next;
  }

  /** 全选判定：与已揭示切片比对，全选的是「正在看的那份列表」 */
  private isAllSelected(): boolean {
    if (this.tracks.length === 0) {
      return false;
    }
    for (let i = 0; i < this.tracks.length; i++) {
      if (this.selectedIds.indexOf(this.tracks[i].id) < 0) {
        return false;
      }
    }
    return true;
  }

  private toggleSelectAll(): void {
    if (this.isAllSelected()) {
      this.selectedIds = [];
      return;
    }
    const ids: string[] = [];
    for (let i = 0; i < this.tracks.length; i++) {
      ids.push(this.tracks[i].id);
    }
    this.selectedIds = ids;
  }

  private exitSelecting(): void {
    this.selecting = false;
    this.selectedIds = [];
  }

  /** 选中的分 P（按已揭示切片收口：切片里已不存在的 id 自动略过，不盲信选区） */
  private selectedTracks(): Track[] {
    return this.tracks.filter((t: Track): boolean => this.selectedIds.indexOf(t.id) >= 0);
  }

  // ===== 加入歌单（PlaylistDetail 同款：无歌单自动建单兜底 + 选择弹层） =====

  /** 没有任何可加歌单时的兜底：新建歌单并直接加入（名字取自第一首） */
  private createPlaylistAndAdd(tracks: Track[], existing: Playlist[]): void {
    const name: string = LibraryStore.nextPlaylistNameForTrack(tracks[0], existing);
    const created: Playlist = LibraryStore.createPlaylist({ name: name });
    const updated: Playlist | null = LibraryStore.addTracksToPlaylist(created.id, tracks);
    this.toast(updated ? `已新建歌单「${name}」并加入` : '加入歌单失败', 1800);
  }

  /** 打开「加入歌单」选择弹层；可加歌单为空时跳过弹层直接自动建单 */
  private openPickerFor(tracks: Track[]): void {
    if (tracks.length === 0) {
      return;
    }
    const options: Playlist[] = LibraryStore.getAddablePlaylists();
    if (options.length === 0) {
      this.createPlaylistAndAdd(tracks, options);
      return;
    }
    this.playlistOptions = options;
    this.pickerTracks = tracks;
    this.playlistPickerController?.open();
  }

  /** 弹层里的「新建歌单并加入」（快照沿用弹层打开时的列表，重名检查基于它即可） */
  private createPlaylistFromPicker(): void {
    const tracks: Track[] = this.pickerTracks;
    const options: Playlist[] = this.playlistOptions;
    this.playlistPickerController?.close();
    if (tracks.length > 0) {
      this.createPlaylistAndAdd(tracks, options);
    }
  }

  private addToPlaylistFromPicker(p: Playlist): void {
    const tracks: Track[] = this.pickerTracks;
    this.playlistPickerController?.close();
    if (tracks.length === 0) {
      return;
    }
    const updated: Playlist | null = LibraryStore.addTracksToPlaylist(p.id, tracks);
    this.toast(updated ? `已加入「${p.name}」` : '加入歌单失败', 1600);
  }

  /** 多选动作区「加入歌单」：选区分 P 开弹层；成功后保持多选态与选区（用户可连着加） */
  private addSelectedToPlaylist(): void {
    const tracks: Track[] = this.selectedTracks();
    if (tracks.length === 0) {
      this.toast('先选择分 P', 1500);
      return;
    }
    this.openPickerFor(tracks);
  }

  // ===== 多选批量下载（串行入队 + 节流；不标记 playlistId —— 任务按 bvid 归组成合集组卡） =====

  /** 多选动作区「下载」：先确认，再串行入队（间隔见 CD_ENQUEUE_GAP_MS） */
  private confirmDownloadSelected(): void {
    const tracks: Track[] = this.selectedTracks();
    if (tracks.length === 0) {
      this.toast('先选择分 P', 1500);
      return;
    }
    showConfirm(this.getUIContext(), {
      title: '下载选中分 P',
      message: `将把选中的 ${tracks.length} 个分 P 加入下载队列。\n已下载的会自动跳过。`,
      confirmText: '开始下载',
      onConfirm: (): void => {
        this.enqueueSelectedSerial(tracks);
      }
    });
  }

  /**
   * 串行入队 + 每首间隔节流（B 站匿名密集请求直接限流）。「仅 WiFi 下载」
   * 闸门在 requestDownload 入口，只会在**首条**返回 blockedReason —— 用它探测
   * 一次，被拦则询问，用户确认后整批以 ignoreWifiLimit 重跑（PlaylistDetail 同一套逻辑）。
   */
  private async enqueueSelectedSerial(tracks: Track[]): Promise<void> {
    if (this.downloadingSelected) {
      this.toast('正在加入下载队列，请稍候', 1500);
      return;
    }
    this.downloadingSelected = true;
    let queued: number = 0;
    let skipped: number = 0;
    for (let i = 0; i < tracks.length; i++) {
      const r: DownloadStartResult = await DownloadManager.getInstance().requestDownload(tracks[i], false);
      if (r.blockedReason.length > 0) {
        this.downloadingSelected = false;
        this.confirmCellularSelected(tracks);
        return;
      }
      queued += r.queued;
      skipped += r.skipped;
      if ((i + 1) % 5 === 0) {
        this.toast(`正在加入下载队列（${i + 1}/${tracks.length}）`, 800);
      }
      if (i < tracks.length - 1) {
        await delay(CD_ENQUEUE_GAP_MS);
      }
    }
    this.downloadingSelected = false;
    this.toast(this.selectedDownloadResultText(queued, skipped), 2500);
  }

  /** 「仅 WiFi 下载」拦下批量下载：问一次（措辞与单曲 confirmDownloadOnCellular 一致） */
  private confirmCellularSelected(tracks: Track[]): void {
    showConfirm(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: `${WIFI_ONLY_BLOCKED}\n当前网络：${currentNetworkLabel()}`,
      confirmText: '继续下载',
      onConfirm: (): void => {
        this.enqueueSelectedWithWifiOverride(tracks);
      }
    });
  }

  /** 用户确认用流量后：整批 ignoreWifiLimit=true 重跑（已入队/已下载的自动跳过） */
  private async enqueueSelectedWithWifiOverride(tracks: Track[]): Promise<void> {
    if (this.downloadingSelected) {
      return;
    }
    this.downloadingSelected = true;
    let queued: number = 0;
    let skipped: number = 0;
    for (let i = 0; i < tracks.length; i++) {
      const r: DownloadStartResult = await DownloadManager.getInstance().requestDownload(tracks[i], true);
      queued += r.queued;
      skipped += r.skipped;
      if (i < tracks.length - 1) {
        await delay(CD_ENQUEUE_GAP_MS);
      }
    }
    this.downloadingSelected = false;
    this.toast(this.selectedDownloadResultText(queued, skipped), 2500);
  }

  /** 批量入队结果文案：排上 / 跳过 分开说 */
  private selectedDownloadResultText(queued: number, skipped: number): string {
    if (queued === 0 && skipped === 0) {
      return '没有可下载的分 P';
    }
    if (queued === 0) {
      return `全部已在下载队列中（${skipped} 个）`;
    }
    const tail: string = skipped > 0 ? `，跳过 ${skipped} 个已在队列/已下载` : '';
    return `已加入下载队列 ${queued} 个${tail}`;
  }

  // ===== 保存为歌单 =====

  /** 打开「保存为歌单」对话框：把整份分 P 列表存成歌单（名称预填视频标题） */
  private openSaveDialog(): void {
    if (this.parts.length === 0) {
      this.toast('该合集还没有可保存的分 P', 1500);
      return;
    }
    this.collectionName = this.headerTitle;
    this.collectionSaverController?.open();
  }

  /** 对话框「保存」：按用户输入的名字建歌单（空名回退「UP 名 + 的合集」） */
  private confirmSave(): void {
    const list: Track[] = this.parts;
    if (list.length === 0) {
      return;
    }
    const input: string = this.collectionName.trim();
    const fallback: string = this.ownerName.length > 0 ? `${this.ownerName} 的合集` : '合集歌单';
    const name: string = input.length > 0 ? input : fallback;
    const created: Playlist = LibraryStore.createPlaylist({
      name: name,
      coverUrl: list[0].coverUrl
    });
    created.tracks = list;
    LibraryStore.updatePlaylist(created);
    this.toast(`已保存歌单「${name}」，共 ${list.length} 首`, 2000);
  }

  private cancelSave(): void {
    // collectionName 打开时会重写，无需清暂存
  }

  /** 「保存为歌单」对话框内容区：分 P 数说明 + 名称输入 */
  @Builder
  SaverBody(): void {
    Column() {
      Text(`共 ${this.parts.length} 个分 P`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      TextInput({ placeholder: '输入歌单名称', text: this.collectionName })
        .width('100%')
        .height(44)
        // 字阶只用六档（24/20/18/16/13/11），15 属于禁用档
        .fontSize(16)
        .onChange((v: string): void => {
          this.collectionName = v;
        })
    }
    .width('100%')
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  // ===== 转场与标题栏 =====

  /**
   * 子页转场：从右滑入 slow(400ms) EaseOut，pop 反向（PlaylistDetail /
   * SeasonSeriesDetailPage 同款）。
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
      return [enter];
    }
    if (op === NavigationOperation.POP && !isEnter) {
      const exit: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '100%';
        }
      };
      return [exit];
    }
    return undefined;
  }

  /** 标题行（titleBar 的 stackBuilder 承载）：空占位（合集名只在头部区大标题显示一次） */
  @Builder
  collectionBar(): void {
    NavTitleRow({ title: '' })
  }

  /** 标题行收窄容器（平板模式宽度适配，PlaylistDetail playlistBarNarrow 同款） */
  @Builder
  collectionBarNarrow(): void {
    Row() {
      Column() {
        this.collectionBar()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * 头部区（titleBar 的 bottomBuilder 承载）：
   *  · 封面行：96vp 圆角封面 + 28fp 大标题 + 元信息行（N 个分P · 总时长 · 播放量）
   *    + UP 名行（可点跳 UP 主页）；
   *  · 按钮行 A：播放全部 / 随机播放 / 选择（多选态变身「完成」）/ 保存为歌单；
   *  · 槽位行 B：常态 = 搜索框（页内过滤），多选态 = 全选 / 加入歌单 / 下载。
   *  ⚠️ 隐藏层必须用条件渲染（不挂载），不能双层叠放 + 透明层：
   *  HitTestMode.None 只豁免容器自身，子按钮仍响应点击（PlaylistDetail 真机踩过）。
   */
  @Builder
  CollectionHeader(): void {
    Column() {
      Row() {
        CoverImage({
          url: this.coverUrl,
          imgWidth: 96,
          imgHeight: 96,
          imgRadius: 12,
          altText: this.headerTitle
        })
        Column() {
          Text(this.headerTitle)
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.metaText.length > 0) {
            Text(this.metaText)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 6 })
          }
          if (this.ownerName.length > 0) {
            Text(`UP · ${this.ownerName}`)
              .fontSize(13)
              .fontColor(this.themePrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 6 })
              .onClick((): void => {
                this.openUpSpace();
              })
          }
        }
        .layoutWeight(1)
        .margin({ left: 16 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 按钮行 A：多选态只留「完成」（其余摘出布局，visibility 摘出无过渡可接受）
      Row({ space: 8 }) {
        Button('播放全部', { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .backgroundColor(this.themeSurface)
          .fontColor(this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          .visibility(this.selecting ? Visibility.None : Visibility.Visible)
          .onClick((): void => {
            this.playAllParts();
          })
        Button('随机播放', { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .backgroundColor(this.themeSurface)
          .fontColor(this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          .visibility(this.selecting ? Visibility.None : Visibility.Visible)
          .onClick((): void => {
            this.shuffleAndPlay();
          })
        // 选择 / 完成：同一颗按钮承担多选进出（位置恒定不跳）
        Button(this.selecting ? '完成' : '选择', { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .backgroundColor(this.themeSurface)
          .fontColor(this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          .onClick((): void => {
            if (this.selecting) {
              this.exitSelecting();
            } else {
              this.enterSelecting();
            }
          })
        Button('保存为歌单', { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .backgroundColor(this.themeSurface)
          .fontColor(this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          .visibility(this.selecting ? Visibility.None : Visibility.Visible)
          .onClick((): void => {
            this.openSaveDialog();
          })
      }
      .width('100%')
      .margin({ top: 12 })
      .alignItems(VerticalAlign.Center)

      // 槽位行 B：常态 = 搜索框；多选态 = 全选 / 加入歌单 / 下载（条件渲染换层 + 淡入淡出）
      if (!this.selecting) {
        SearchBox({
          placeholder: '搜索分 P',
          keyword: this.searchKeyword,
          clearVisible: this.searchKeyword.trim().length > 0,
          onKeywordChange: (v: string): void => {
            this.searchKeyword = v;
            this.onKeywordChanged();
          },
          onClear: (): void => {
            this.clearSearch();
          }
        })
        .width('100%')
        // 与按钮行 A 之间留 8vp 呼吸间距（换层淡入淡出时两态几何一致）
        .margin({ top: 8 })
        .transition(TransitionEffect.OPACITY
          .animation({ duration: CD_SELECT_FADE_MS, curve: Curve.EaseInOut }))
      } else {
        Row({ space: 8 }) {
          Button(this.isAllSelected() ? '取消全选' : '全选', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .padding({ left: 10, right: 10 })
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .onClick((): void => {
              this.toggleSelectAll();
            })
          Button('加入歌单', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .padding({ left: 10, right: 10 })
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .onClick((): void => {
              this.addSelectedToPlaylist();
            })
          Button('下载', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .padding({ left: 10, right: 10 })
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .enabled(!this.downloadingSelected)
            .onClick((): void => {
              this.confirmDownloadSelected();
            })
        }
        .width('100%')
        // 与搜索框常态层同几何（margin top 8），换层时按钮位置不跳
        .margin({ top: 8 })
        .transition(TransitionEffect.OPACITY
          .animation({ duration: CD_SELECT_FADE_MS, curve: Curve.EaseInOut }))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: 4, bottom: 8 })
  }

  /** 头部区实测载体（bottomBuilder 高度不自适应，onAreaChange 回写 headerAreaHeight） */
  @Builder
  collectionHeaderArea(): void {
    Column() {
      Column() {
        this.CollectionHeader()
      }
      .width('100%')
      .onAreaChange((_old: Area, cur: Area): void => {
        const h: number = cur.height as number;
        if (h > 0) {
          this.headerAreaHeight = h;
        }
      })
    }
    .width('100%')
  }

  /** 头部区收窄容器（collectionBarNarrow 同口径） */
  @Builder
  collectionHeaderAreaNarrow(): void {
    Row() {
      Column() {
        this.collectionHeaderArea()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 「加入歌单」弹窗正文（PlaylistDetail 同款；多曲时曲名行带「等 N 首」） */
  @Builder
  PlaylistPickerBody(): void {
    Column() {
      Text(this.pickerTracks.length > 1
        ? `${this.pickerTracks[0].title} 等 ${this.pickerTracks.length} 首`
        : (this.pickerTracks.length > 0 ? this.pickerTracks[0].title : ''))
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ bottom: 12 })
      Row() {
        Text('＋ 新建歌单并加入')
          .fontSize(16)
          .fontColor(this.themeDeep)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.press_overlay')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .onClick((): void => {
        this.createPlaylistFromPicker();
      })
      Divider()
        .color($r('app.color.bg_divider'))
      List() {
        ForEach(
          this.playlistOptions,
          (p: Playlist): void => {
            ListItem() {
              Row() {
                Text(p.name)
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(`${p.tracks.length} 首`)
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              .padding({ top: 12, bottom: 12 })
              .stateStyles({
                pressed: { .backgroundColor($r('app.color.press_overlay')) },
                normal: { .backgroundColor(Color.Transparent) }
              })
              .onClick((): void => {
                this.addToPlaylistFromPicker(p);
              })
            }
          },
          (p: Playlist): string => `${p.id}_${p.name}_${p.tracks.length}`
        )
      }
      .width('100%')
      .edgeEffect(EdgeEffect.Spring)
      .constraintSize({ maxHeight: 260 })
    }
    .width('100%')
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Column() {
          // 列表挂载门控（PlaylistDetail 同款）：等头部区首次实测完成再挂载，
          // 防止列表固化不含头部区的错误让位量（首项被封面压住）。
          if (this.parts.length > 0 && this.headerAreaHeight > 0) {
            List({ scroller: this.listScroller }) {
              // 顶部空白占位条目：列表视口铺满全屏，占位高度 = 标题栏总让位量，
              // 首个真实条目恰从栏底起排，滚动时条目从沉浸材质下穿过。
              ListItem() {
                Row()
                  .width('100%')
                  .height(this.barTotalHeight())
              }
              ForEach(
                this.tracks,
                (t: Track, index: number): void => {
                  ListItem() {
                    TrackItem({
                      track: t,
                      entranceIndex: index,
                      downloaded: this.isDownloaded(t),
                      onPlay: (tr: Track): void => {
                        this.player.playOrToggle(tr);
                      },
                      moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr),
                      selecting: this.selecting,
                      selected: this.selectedIds.indexOf(t.id) >= 0,
                      onToggleSelect: (tr: Track): void => {
                        this.toggleSelected(tr);
                      }
                    })
                  }
                },
                (t: Track): string => t.id
              )
              // 搜索状态行（关键词激活时常驻，UpSpacePage footer 口径对齐）：
              // 命中 N 个给计数，0 命中给人话提示。
              //（底部状态行门控 tracks.length > 0，0 命中时不与「没有匹配」同现。）
              if (this.searchKeyword.trim().length > 0) {
                ListItem() {
                  Text(this.filteredTracks.length > 0
                    ? `命中 ${this.filteredTracks.length} 个分 P`
                    : '没有匹配的分 P')
                    .fontSize(13)
                    .fontColor($r('app.color.text_tertiary'))
                }
              }
              // 加载更多状态条：本地切片即时揭示，只区分「上拉」与「到底」
              if (this.tracks.length > 0) {
                ListItem() {
                  Column() {
                    if (!this.hasMoreTracks()) {
                      Text('已经到底啦')
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                    } else {
                      Text('上拉加载更多')
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                    }
                  }
                  .width('100%')
                  .padding({ top: 14, bottom: 14 })
                  .justifyContent(FlexAlign.Center)
                }
              }
            }
            .layoutWeight(1)
            .edgeEffect(EdgeEffect.Spring)
            .cachedCount(8)
            .contentEndOffset(CONTENT_END_OFFSET)
            .onReachEnd((): void => {
              this.onReachEnd();
            })
            .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
              this.syncTopBlurProgress();
            })
            .onScrollStop((): void => {
              this.syncTopBlurProgress();
            })
          } else if (this.loading && this.parts.length === 0) {
            // 首屏骨架：同款条目占位，不用「转圈 + 加载中」
            Column() {
              ForEach([0, 1, 2, 3, 4], (_i: number): void => {
                SkeletonTrackItem({ index: _i })
              }, (_i: number): string => `cd_skel_${_i}`)
            }
            .width('100%')
            .layoutWeight(1)
            .padding({ top: this.barTotalHeight() })
          } else if (this.loadFailed && this.parts.length === 0) {
            Column() {
              Text('合集加载失败')
                .fontColor($r('app.color.text_secondary'))
                .fontSize(16)
              Text(this.failReason.length > 0 ? this.failReason : '检查网络后再试一次')
                .fontColor($r('app.color.text_tertiary'))
                .fontSize(13)
                .textAlign(TextAlign.Center)
                .padding({ left: 24, right: 24 })
                .margin({ top: 8 })
              Row() {
                Row() {
                  Button('重试', { type: ButtonType.Normal })
                    .fontSize(13)
                    .height(32)
                    .borderRadius(BUTTON_RADIUS_VP)
                    .padding({ left: 18, right: 18 })
                    .backgroundColor(this.themePrimary)
                    .fontColor(Color.White)
                    .enabled(!this.loading)
                    .onClick((): void => {
                      this.retry();
                    })
                }
                .height(44)
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
              }
              .margin({ top: 12 })
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: this.barTotalHeight() })
          } else if (this.parts.length === 0) {
            // 拉取成功但不是多 P（入口数据过期 / 单 P 视频误入）：给人话不进失败态
            Column() {
              Text('该视频没有多个分 P')
                .fontColor($r('app.color.text_secondary'))
                .fontSize(16)
              Text('可能视频已更新，返回后重新进入试试')
                .fontColor($r('app.color.text_tertiary'))
                .fontSize(13)
                .margin({ top: 8 })
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: this.barTotalHeight() })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
        .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })

        // 顶栏渐变模糊层：盖内容列之上（z 序低于 HDS titleBar），进度由列表
        // onDidScroll/onScrollStop 经 topBlurUpdater 命令式驱动。
        TopGradientBlurOverlay({
          barHeightVp: this.barTotalHeight(),
          updater: this.topBlurUpdater
        })
      }
    }
    // HDS 沉浸光感标题栏：stackBuilder 空占位标题行 + bottomBuilder 头部区
    //（实测高度，未实测时估计值垫底防 0 高闪跳）。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        stackBuilder: (): void => {
          this.collectionBarNarrow();
        },
        bottomBuilder: {
          builder: (): void => {
            this.collectionHeaderAreaNarrow();
          },
          height: this.headerAreaHeight > 0 ? this.headerAreaHeight : COLLECTION_HEADER_ESTIMATE_HEIGHT,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        }
      }
    })
    .bindToScrollable([this.listScroller])
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 系统返回拦截：多选态先退出多选（选区清空，留在本页）；否则播放页 overlay
    // 打开时吞掉返回并发收起请求，再否则走默认 pop（utils/SubPageBackPress）。
    .onBackPressed((): boolean => {
      if (this.selecting) {
        this.exitSelecting();
        return true;
      }
      return handleSubPageBackPress();
    })
    // 内容避让：目的地级声明布局扩展进系统安全区（PlaylistDetail 同口径）
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function CollectionDetailPageBuilder(): void {
  CollectionDetailPage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接 @Builder 引用（编译期校验）。 */
export const CollectionDetailPageWrapped: WrappedBuilder<[]> = wrapBuilder(CollectionDetailPageBuilder);
