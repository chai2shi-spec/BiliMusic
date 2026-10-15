/**
 * 歌单详情页：展示歌单内单曲，支持播放全部 / 单曲播放 / 加入队列 / 从歌单移除。
 * 目标歌单 id 由 NavStackHolder.selectedPlaylistId 传入。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，stackBuilder 承载
 * 返回行 + 头部区，批 1 样板同款）；栏内不放标题文字
 * （歌单名只在头部区 28fp 大标题显示一次），返回行仅一颗返回键。
 * avoidLayoutSafeArea 后栏顶 = safeTop，滚动时曲目从沉浸材质下穿过；
 * 侧滑返回是 Navigation 级能力，不受影响。
 *
 * 钉顶头部区：整个头部区「封面 + 28fp 大标题 + 元信息/简介 + 播放全部/拉取新投稿」
 * 接在返回行下，仅曲目列表滚动并从材质下透出；
 * 重命名 / 删除歌单入口在歌单列表页行内 ⋮ 菜单。
 */

import { Playlist, Track, DownloadTask, DownloadStatus, buildTrack } from '../model/MusicModels';
import { LibraryStore } from '../service/LibraryStore';
import * as BilibiliApi from '../api/BilibiliApi';
import { SpaceVideo } from '../api/BilibiliApi';
import { toHttpsUrl, stripHtmlTags, parseDurationText } from '../utils/TextUtil';
import { MusicPlayer } from '../player/MusicPlayer';
import { TrackItem } from '../components/TrackItem';
import { CoverImage } from '../components/CoverImage';
// 菜单弹层（2026-10-08）：曲目菜单从双按钮 AlertDialog 换成 MenuDialog ——
// 新增「下载」后动作到三个，AlertDialog 只有两颗按钮放不下。
import { showAppAlertDialog } from '../components/AppAlertDialog';
// 下载链（2026-10-08）：与 SearchPage 同一套（requestDownload → 仅 WiFi 拦截询问 → toast 回执）
import { DownloadManager, DownloadStartResult, WIFI_ONLY_BLOCKED } from '../service/DownloadManager';
import { currentNetworkLabel } from '../utils/NetworkUtil';
import { NavStackHolder } from '../service/NavStackHolder';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NAV_TRANSITION_MS, BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import { HdsNavDestination, BottomBuilderShowType } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier
} from '../utils/HeaderBarMaterial';
import { ArrayDataSource } from '../utils/ArrayDataSource';
import {
  STORE_DOWNLOAD_TASKS,
  STORE_LIBRARY_REV,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE,
  STORE_THEME_DEEP
} from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { showAppToast } from '../components/AppToast';
import { enqueueFavOp, FAV_OP_DEL } from '../service/FavPushStore';
import { FavSyncManager } from '../service/FavSyncManager';

/**
 * 「拉取新投稿」每次最多收多少条。
 * ⚠️ 放在 import 之后 —— ArkTS 不允许 import 出现在其它语句之后（arkts-no-misplaced-imports）。
 */
const UP_REFRESH_MAX_ITEMS: number = 60;

/**
 * 歌单头部区（bottomBuilder 承载）实测前的估计高度：封面行 + 元信息 + 简介 + padding。
 * ⚠️ bottomBuilder 高度不自适应（官方约束），由 titleBar 参数显式给定；实测值
 * （headerAreaHeight）回来后覆盖，此值只防首次布局 0 高闪跳。
 */
const PLAYLIST_HEADER_ESTIMATE_HEIGHT: number = 190;

/**
 * 顶栏滚动模糊时机（2026-10-09 用户定档）：
 *  · 内容区滚动 0~30vp：导航栏保持完全透明；
 *  · 30~80vp：沉浸玻璃材质渐变出现；
 *  · 超过 80vp：材质固定满强度。
 * 数值语义 = HDS blurEffectiveStart/EndOffset 的「内容区滚动偏移」（SDK：total scroll offset）。
 */
const PD_BLUR_START_VP: number = 30;
const PD_BLUR_END_VP: number = 80;

@Component
export struct PlaylistDetail {
  /** 曲目列表滚动控制器：bindToScrollable 绑给 HDS 标题栏驱动滚动模糊 */
  private listScroller: Scroller = new Scroller();
  /** 头部按钮（播放全部 / 拉取新投稿）沉浸光感材质修饰器：26+ 生效，低版本 no-op 显实色兜底 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  @State playlist: Playlist | null = null;
  @State titleText: string = '歌单';
  /** 「拉取新投稿」进行中：防止连点重复发请求 */
  @State upRefreshing: boolean = false;
  /**
   * 歌单头部区实测高（vp，bottomBuilder 内层根节点 onAreaChange 回写，随简介行数浮动）。
   * ⚠️ 初值必须为 0（2026-10-08 修复首项被钉顶栏遮挡）：contentStartOffset 只在
   * 列表内容首次布局时生效，更新不会重排已有内容——歌单数据来自本地缓存，
   * 列表带着条目与初值一起挂载会固化不含 safeTop 的估计值。列表挂载门控直接判
   * headerAreaHeight > 0（见 build 里的 if）——barTotalHeight() 恒 > 0 不能当门控。
   */
  @State headerAreaHeight: number = 0;

  /**
   * HDS 标题栏整体让位量（vp）= safeTop + 标题行 56 + 头部区实测高。
   * 头部区高度随简介行数浮动，无法定值，沿用「实测 + 挂载门控」机制。
   */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT + this.headerAreaHeight;
  }
  /** 媒体库变更信号：在别处（如弹层里）改到这个歌单时同步刷新 */
  @StorageLink(STORE_LIBRARY_REV) @Watch('onLibraryChanged') libraryRev: number = 0;
  /** 状态栏高度（vp）：标题栏要整体落在状态栏下方，由本页自己顶下来 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;

  /** 主题色运行时值：头部按钮浅底 / 主色 / 深字跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  private player: MusicPlayer = MusicPlayer.getInstance();

  /**
   * 下载任务快照（2026-10-08）：订阅它只为派生「哪些曲目已下载完成」
   * （下载完成 / 删除时徽标要即时出现 / 消失），本页不做下载管理。
   */
  @StorageLink(STORE_DOWNLOAD_TASKS) @Watch('onDownloadTasks') downloadTasks: DownloadTask[] = [];
  /**
   * 已下载完成的曲目 id 集合（2026-10-08）。刻意用数组而不是 Set ——
   * @State 感知不到 Set 的内容变化（与 DownloadsPage.selectedIds 同一坑）。
   * 曲目行读它显示「已下载」徽标；精确匹配（见 isDownloaded 注释）。
   */
  @State downloadedIds: string[] = [];

  /**
   * 列表数据源：歌单可能积累上百首，LazyForEach 只构建可视区 + 缓存区节点，
   * 首屏不再一次性建全部行。整表替换走 reload()（load() 内）。
   */
  private trackSource: ArrayDataSource<Track> = new ArrayDataSource<Track>([]);

  /**
   * 子页转场的横移量（相对页面自身宽度）：常驻 '0%'，
   * 转场代理里按 push/pop 方向临时改写（见 navTransitionDelegate）。
   */
  @State navTransX: string = '0%';

  /**
   * 头部区展示用的派生字段（load() 时重算）：@Builder 体内不放局部声明、
   * 也不便反复对 playlist 判空，元信息 / 封面 / 简介统一在 load() 算好成串。
   */
  @State coverUrl: string = '';
  @State metaText: string = '';
  @State descText: string = '';

  aboutToAppear(): void {
    this.load();
    // @Watch 不为 @StorageLink 的初始同步触发（工程内已踩过两次的坑），
    // 这里必须补一次已下载集合的初算；ensureLoaded 幂等 —— AppContainer 启动链
    // 已装填过的话这是空操作，冷启动直接进本页时它负责推第一份快照。
    this.rebuildDownloadedIds();
    DownloadManager.getInstance().ensureLoaded().catch((e: Error): void => {
      console.error(`load downloads failed: ${JSON.stringify(e)}`);
    });
  }

  /** 下载快照到达：重建「已下载完成」曲目 id 集合（COMPLETED 且文件还在才算数） */
  private onDownloadTasks(): void {
    this.rebuildDownloadedIds();
  }

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

  /**
   * 这首曲目是否已下载完成：**musicId 精确匹配**，与 DownloadManager 去重键
   * （getDownloadByMusicId）同一语义 —— 多 P 首 P 条目 id = 纯 bvid、其余 =
   * `bvid#cid`，各自独立判定，不会「整合集下过就把所有分 P 都标成已下载」。
   */
  private isDownloaded(t: Track): boolean {
    return this.downloadedIds.indexOf(t.id) >= 0;
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut。
   * · push 入场：先把页面挪到屏幕右侧外（'100%'），event 闭包内回到 '0%'，
   *   系统按闭包内的状态变化生成 400ms EaseOut 过渡；
   * · pop 出场（含侧滑返回手势触发的返回）：反向滑回右侧，与手势方向一致；
   * · 其余场景（本页被上层页覆盖 / 上层页返回后重新露出）返回 undefined，
   *   走系统默认转场。
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

  onLibraryChanged(): void {
    this.load();
  }

  private load(): void {
    const p: Playlist | null = LibraryStore.getPlaylist(NavStackHolder.selectedPlaylistId);
    this.playlist = p;
    this.titleText = p ? p.name : '歌单';
    this.coverUrl = p ? p.coverUrl : '';
    this.descText = p && p.description.length > 0 ? p.description : '';
    this.metaText = this.buildMetaText(p);
    this.trackSource.reload(p ? p.tracks : []);
  }

  /**
   * 头部区元信息行：歌曲数 + 来源。
   * 收藏夹镜像显示「同步自 收藏夹名」；
   * 订阅歌单优先显示 UP 昵称（订阅关系的核心信息）；
   * 普通歌单显示创建日期（取 ISO 串前 10 位，零格式化风险）。
   */
  private buildMetaText(p: Playlist | null): string {
    if (!p) {
      return '';
    }
    const countText: string = `${p.tracks.length} 首`;
    if (LibraryStore.isFavMirror(p)) {
      return p.upName.length > 0 ? `${countText} · 同步自 ${p.upName}` : `${countText} · B 站收藏夹`;
    }
    if (LibraryStore.isUpSubscription(p)) {
      return p.upName.length > 0 ? `${countText} · 订阅自 ${p.upName}` : countText;
    }
    return p.createdAt.length >= 10 ? `${countText} · 创建于 ${p.createdAt.slice(0, 10)}` : countText;
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /**
   * 从已有曲目里取出「同一个 UP 的 bvid」当作 related 扩散的种子。
   *
   * 只取前几个：`getUserVideosViaRelated` 默认最多用 2 个种子（每个种子一次请求），
   * 取多了既没收益又会增加被限流的机会。
   */
  private seedBvids(tracks: Track[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < tracks.length && out.length < 4; i++) {
      const bvid: string = tracks[i].bvid;
      if (bvid.length > 0 && out.indexOf(bvid) < 0) {
        out.push(bvid);
      }
    }
    return out;
  }

  /**
   * 拉取该订阅 UP 的新投稿并入歌单（按 id 去重，新的排前面）。
   *
   * 走 `collectUpVideos`（三级兜底：搜索反查 → related 扩散 → 空间接口），策略只在
   * `BilibiliApi` 里维护一份，这里不再自己拼链路。
   *
   * ⚠️ 关于「只成功一次」：这不是接口被限流 —— 实测搜索接口连打 8 次 8/8 成功。
   * 真实原因是**去重**：搜索反查固定按 pubdate 返回最近那几十条，第一次拉进歌单后，
   * 之后再拉回来的还是同一批，`mergeUpTracks` 全去重掉 → added=0。
   * 所以 `added === 0` 时提示必须说「已是最新」，否则用户会以为是故障。
   */
  private refreshUpTracks(): void {
    const p: Playlist | null = this.playlist;
    // 只有「订阅 UP 投稿」歌单才有这条链路；收藏夹镜像（upMid='fav_x'）不能走，
    // 否则会用收藏夹 id 去调 UP 投稿接口 → 必然失败
    if (!p || !LibraryStore.isUpSubscription(p) || this.upRefreshing) {
      return;
    }
    this.upRefreshing = true;
    this.toast('正在拉取新投稿…', 1200);
    const name: string = p.upName;
    BilibiliApi.collectUpVideos(p.upMid, name, this.seedBvids(p.tracks), UP_REFRESH_MAX_ITEMS)
      .then((res: BilibiliApi.UpVideosCollectResult): void => {
        const collected: SpaceVideo[] = res.list;
        if (collected.length === 0) {
          // 三条路都没货：有具体原因就说原因，否则说清「是 B 站没给，不是 App 坏了」
          this.toast(res.reason.length > 0
            ? `B 站暂时没返回投稿：${res.reason}`
            : 'B 站暂时没返回投稿，稍后再试', 2200);
          return;
        }
        const tracks: Track[] = collected.map((v: SpaceVideo): Track => {
          return buildTrack({
            id: v.bvid,
            bvid: v.bvid,
            aid: String(v.aid ?? 0),
            title: stripHtmlTags(v.title),
            artist: v.author || name,
            upMid: p.upMid,
            coverUrl: toHttpsUrl(v.pic),
            duration: parseDurationText(v.length),
            playCount: v.play ?? 0,
            pubdate: v.created || 0
          });
        });
        const r = LibraryStore.mergeUpTracks(p.id, tracks);
        this.load();
        if (r.added === 0) {
          // 拿到了数据但全是已有的 = 确实没有新投稿，不是故障
          this.toast('已是最新 · 该 UP 还没有新投稿', 1800);
        } else if (r.dropped > 0) {
          this.toast(`新增 ${r.added} 首，已满 ${r.playlist ? r.playlist.tracks.length : 0} 首`, 2000);
        } else {
          this.toast(`新增 ${r.added} 首`, 1800);
        }
      })
      .catch((e: Error): void => {
        console.error(`refreshUpTracks failed: ${e.message}`);
        this.toast('拉取失败，B 站可能限制了访问', 2000);
      })
      .then((): void => {
        this.upRefreshing = false;
      });
  }

  /**
   * 曲目「⋯」菜单（2026-10-08，阶段 2 迁移为 bindMenu + MenuElement 数组）。
   *
   * 顺序刻意为「加入队列 / 下载 / 从歌单移除」：破坏性的移除放**最后**，
   * 用户扫一眼就能把安全操作与不可逆操作分开，减少误触。
   */
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
          this.startDownload(track);
        }
      },
      {
        value: '从歌单移除',
        action: (): void => {
          this.confirmRemoveTrack(track);
        }
      }
    ];
  }

  /**
   * 「从歌单移除」的真实入口（2026-10-13 真双向）。
   * 普通歌单：保持原行为（本地删，零影响）。
   * 收藏夹镜像：**会真删 B 站账号里的收藏** → 必须先弹确认，确认后
   *   ① 本地移除（立刻生效，UI 不等网络）
   *   ② 入队一条「取消收藏」写意图（持久化，失败可重试）
   *   ③ 立即尝试推送；失败就留队列，下次同步/冷启动自动重放
   * 入队而非直接发请求，是因为：失败要能重试，且要阻止该曲目被下一轮拉取「复活」。
   */
  private confirmRemoveTrack(track: Track): void {
    const p: Playlist | null = this.playlist;
    if (p === null || !LibraryStore.isFavMirror(p)) {
      // 普通歌单：原行为，不打扰用户
      LibraryStore.removeTracksFromPlaylist(NavStackHolder.selectedPlaylistId, [track.id]);
      this.load();
      return;
    }
    showAppAlertDialog(this.getUIContext(), {
      title: '从收藏夹移除',
      message: `「${p.name}」是 B 站收藏夹的镜像。移除后会同时取消 B 站收藏，该操作将同步到你的 B 站账号，且无法在 App 内撤销。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
          // 取消：不做任何事
        }
      },
      secondaryButton: {
        value: '移除并取消收藏',
        action: (): void => {
          // ① 本地移除（立刻生效，UI 不等网络）
          LibraryStore.removeTracksFromPlaylist(NavStackHolder.selectedPlaylistId, [track.id]);
          this.load();
          // ② 入队一条「取消收藏」写意图（持久化，失败可重试）
          const mediaId: number = LibraryStore.favMediaIdOf(p);
          enqueueFavOp({
            mediaId: mediaId,
            bvid: track.id,
            aid: track.aid,
            op: FAV_OP_DEL,
            title: track.title,
            createdAt: Date.now(),
            attempts: 0,
            lastError: ''
          });
          // ③ 立即尝试推送；失败就留队列，下次同步/冷启动自动重放
          FavSyncManager.getInstance().pushOnly('ui-delete');
          this.toast('已从本地移除，正在同步到 B 站…', 2000);
        }
      }
    });
  }

  private startDownload(track: Track): void {
    this.requestDownload(track, false);
  }

  /**
   * 发起下载（与 SearchPage 同一套链路，2026-10-08）。
   *
   * 分 P 合集会在内核里被展开成多条任务（见 DownloadManager.requestDownload），
   * 所以结果不是布尔而是「排上几首 / 跳过几首」；「仅 WiFi 下载」被拦时
   * 弹一次询问，用户确认后以 override 重入。
   */
  private requestDownload(track: Track, ignoreWifiLimit: boolean): void {
    DownloadManager.getInstance().requestDownload(track, ignoreWifiLimit)
      .then((r: DownloadStartResult): void => {
        if (r.blockedReason.length > 0) {
          this.confirmDownloadOnCellular(track);
          return;
        }
        this.toast(this.downloadResultText(r), 2000);
      })
      .catch((e: Error): void => {
        console.error(`requestDownload failed: ${JSON.stringify(e)}`);
        this.toast('下载启动失败', 1800);
      });
  }

  /** 把下载请求结果翻译成人话：0 条 / 1 条 / N 条要分开说，否则用户不知道合集是不是都排上了 */
  private downloadResultText(r: DownloadStartResult): string {
    if (r.queued === 0) {
      return r.skipped > 0 ? '该歌曲已在下载列表中' : '没有可下载的曲目';
    }
    const head: string = r.queued > 1 ? `已开始下载 ${r.queued} 首` : '已开始下载';
    const tail: string = r.skipped > 0 ? `（另有 ${r.skipped} 首已在列表中）` : '';
    return `${head}，可在「下载」页查看进度${tail}`;
  }

  /** 「仅 WiFi 下载」被触发：先问一句而不是直接拒绝（开关的本意是防偷跑，不是绝对禁用） */
  private confirmDownloadOnCellular(track: Track): void {
    showAppAlertDialog(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: `${WIFI_ONLY_BLOCKED}\n当前网络：${currentNetworkLabel()}`,
      primaryButton: {
        value: '取消'
      },
      secondaryButton: {
        value: '继续下载',
        action: (): void => {
          this.requestDownload(track, true);
        }
      }
    });
  }

  /**
   * 头部区（整体钉在悬浮固定栏内，不随列表滚动）：
   * 左侧 96vp 圆角封面（CoverImage 自带空图 / 失败占位），
   * 右侧 28fp 大标题 + 元信息行 + 可选简介；封面行下方是操作按钮行
   * （播放全部 / 拉取新投稿）。
   * 数据全部来自 load() 预计算的派生字段（coverUrl / metaText / descText），
   * @Builder 体内不声明局部变量、不对 playlist 判空。
   */
  @Builder
  PlaylistHeader(): void {
    Column() {
      Row() {
        CoverImage({
          url: this.coverUrl,
          imgWidth: 96,
          imgHeight: 96,
          imgRadius: 12,
          altText: this.titleText
        })
        Column() {
          Text(this.titleText)
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.metaText.length > 0) {
            Text(this.metaText)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 6 })
          }
          if (this.descText.length > 0) {
            Text(this.descText)
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 6 })
          }
        }
        .layoutWeight(1)
        .margin({ left: 16 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 操作按钮行：随头部区一起滚动（用户明确不要钉在顶部固定栏）。
      // 播放全部：有曲目才显示；拉取新投稿：订阅歌单（upMid 非空）才显示，
      // 空的订阅歌单也保留它 —— 正好是一键填歌单的入口。
      Row({ space: 8 }) {
        if (this.playlist && this.playlist.tracks.length > 0) {
          Button('播放全部', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            // 真机要求：与 RecentPage 播放全部逐字一致（浅粉底 + 粉字 + 沉浸光感）
            .backgroundColor(this.themeSurface)
            .fontColor(this.themePrimary)
            .attributeModifier(this.buttonMaterial)
            .onClick((): void => {
              if (this.playlist) {
                this.player.playAll(this.playlist.tracks);
              }
            })
        }
        // 「拉取新投稿」只对订阅 UP 歌单开放；收藏夹镜像走同步页的「立即同步」，
        // 不能出现在这里（会把 fav_ id 当 UP mid 去请求）
        if (this.playlist && LibraryStore.isUpSubscription(this.playlist)) {
          Button(this.upRefreshing ? '正在拉取…' : '拉取新投稿', { type: ButtonType.Normal })
            .fontSize(13)
            .height(32)
            .borderRadius(BUTTON_RADIUS_VP)
            .backgroundColor(this.themeSurface)
            .fontColor(this.themeDeep)
            .attributeModifier(this.buttonMaterial)
            .enabled(!this.upRefreshing)
            .onClick((): void => {
              this.refreshUpTracks();
            })
        }
      }
      .width('100%')
      .margin({ top: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: 12, bottom: 16 })
  }

  /**
   * 标题行内容（titleBar 的 stackBuilder 承载，可用空间仅 56vp，不得超出——
   * 官方约束「不要超出标题栏的可用空间」，超出会溢出与内容区重叠）：
   * 仅返回键，无标题 —— 歌单名只在头部区大标题显示一次。
   * 材质与滚动模糊由 HDS titleBar 负责。
   */
  @Builder
  playlistBar() {
    Row() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(26)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .borderRadius(22)
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.press_overlay')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .accessibilityText('返回')
      .accessibilityLevel('yes')
      .onClick((): void => {
        NavStackHolder.stack.pop();
      })
    }
    .width('100%')
    .height(NAV_TITLE_BAR_HEIGHT)
    // 行内边距与 AboutPage.aboutBar 完全一致（真机要求：返回键样式对齐关于页）
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 标题行下方自定义区（titleBar 的 bottomBuilder 承载）：歌单头部区
   * （封面 / 歌单名 / 元信息 / 简介 / 操作按钮）。
   * ⚠️ bottomBuilder 高度不自适应（官方约束），内层 Column 是天然高的实测载体——
   * onAreaChange 挂内层根节点，回写 headerAreaHeight（随简介行数浮动）；
   * 实测前用估计高度垫底防 0 高闪跳。
   */
  @Builder
  playlistHeaderArea() {
    Column() {
      Column() {
        this.PlaylistHeader()
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

  build() {
    HdsNavDestination() {
      Stack() {
        Column() {
          // 列表挂载门控（见 headerAreaHeight 注释）：等头部区首次实测完成再挂载。
          // ⚠️ 不能用 barTotalHeight() > 0 当门控 —— safeTop + 56 恒 > 0，门控形同虚设，
          // 列表会在 headerAreaHeight 实测前挂载并固化 safeTop + 56 的错误让位量
          // （首项被封面压住，真机复现）；必须直接判 headerAreaHeight > 0。
          if (this.playlist && this.playlist.tracks.length > 0 && this.headerAreaHeight > 0) {
            List({ scroller: this.listScroller }) {
              // 头部区已钉顶（固定栏），列表只装曲目行：LazyForEach 的 index 是
              // 数据源内下标（0 起，对应第一首曲目），TrackItem.entranceIndex 不受影响。
              LazyForEach(
                this.trackSource,
                (t: Track, index: number): void => {
                  ListItem() {
                    TrackItem({
                      track: t,
                      entranceIndex: index,
                      // 已下载徽标（2026-10-08）：读 @State downloadedIds，
                      // 下载完成的快照到达时可见行局部刷新出徽标（保留节点读
                      // @State 是活的，与下载页「正在播放」同一机制）
                      downloaded: this.isDownloaded(t),
                      onPlay: (tr: Track): void => {
                        this.player.playOrToggle(tr);
                      },
                      moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
                    })
                  }
                },
                (t: Track): string => t.id
              )
            }
            .layoutWeight(1)
            // 边界回弹（2026-10-08）：到顶/到底的反馈动效
            .edgeEffect(EdgeEffect.Spring)
            // 顶部让位（Sumy 式穿透）：列表视口铺满全屏，首项从 HDS 标题栏底部起排，
            // 滚动时曲目从沉浸材质下穿过；
            // 让位量 = safeTop + 56 + 头部区实测高（随简介行数浮动）
            .contentStartOffset(this.barTotalHeight())
          } else if (!this.playlist || this.playlist.tracks.length === 0) {
            Column() {
              Text('歌单还是空的')
                .fontColor($r('app.color.text_secondary'))
                .fontSize(16)
              Text('在搜索页点击“⋯”把歌曲加进来吧')
                .fontColor($r('app.color.text_tertiary'))
                .fontSize(13)
                .margin({ top: 8 })
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
            // 内容列不再整体 padding top（列表穿透需要），空态自己补让位（标题栏总让位量）
            .padding({ top: this.barTotalHeight() })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
        // ⚠️ 不再整体 padding top / safeAreaPadding top：列表视口要铺满全屏
        // （contentStartOffset 负责让出「状态栏+原生栏+头部条带」），滚动时曲目
        // 从头部材质下穿过；底部不做避让，沉浸到底（2026-10-14 与关注/最近页
        // 同口径，见目的地链上的 ignoreLayoutSafeArea 声明）。
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
        // 根 Stack 默认居中对齐，直接给内容列挂上限即可。
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
      }
    }
    // HDS 沉浸光感标题栏（批 1 样板同款，真机结论见 AboutPage 注释）：
    // avoidLayoutSafeArea 挡状态栏重叠；enableComponentSafeArea 会杀材质，禁用。
    // 标题栏宽度跟随本页内容列，大屏上与收窄后的列表左右对齐。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(PD_BLUR_START_VP, PD_BLUR_END_VP),
      content: {
        // 标题行（stackBuilder，可用空间 56vp）：仅返回键
        stackBuilder: (): void => {
          this.playlistBar();
        },
        // 标题行下方自定义区：歌单头部区（封面 / 歌单名 / 简介 / 操作按钮）。
        // ⚠️ 头部区不能塞进 stackBuilder（会溢出 56vp 标题行、与列表内容重叠，
        // 真机复现），必须走 bottomBuilder；高度用实测值（未实测时估计值垫底）。
        bottomBuilder: {
          builder: (): void => {
            this.playlistHeaderArea();
          },
          height: this.headerAreaHeight > 0 ? this.headerAreaHeight : PLAYLIST_HEADER_ESTIMATE_HEIGHT,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        }
      }
    })
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页列表交给 HDS 联动
    .bindToScrollable([this.listScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 内容避让（2026-10-14）：目的地级声明布局扩展进系统安全区（官方组件级沉浸
    // 口径，faqs-arkui-1095 场景三同款）；窗口全屏下页面级为既成事实，此处显式化
    // 并接管组件级 safeAreaPadding。内容层避让由 contentStartOffset / plain padding 自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}
