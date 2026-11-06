/**
 * 首页（底部第 0 页签）。
 *
 * 结构：
 *   · 固定标题栏（根 HdsNavigation titleBar，Index 承载）：
 *     左「BiliMusic」大标题 + 右上 HDS 搜索按钮（滚动出头部后浮现）。
 *   · 滚动内容头部（本页 List 的头部条目，随内容滚出视口）：
 *     入口式搜索框（点击 push 搜索二级页）。
 *   · 搜索框下方：快捷卡行（HomeQuickCards）—— 最近播放卡（点播放 = 播放全部最近、点卡进最近播放页）+
 *     收藏歌单卡（歌单 ⋯ 菜单「加入首页」自选，点播放 = 整单起播、点卡进
 *     歌单），最多 5 卡横滑；数据经 STORE_LIBRARY_REV 驱动重灌。
 *   · 卡行下方：分类 chip 条（HomeCategoryChips：推荐 / 热歌榜 / 音乐中心 /
 *     热门歌单）+ 随所选 tab 显示对应数据源的条目列表。
 *
 * 入口搜索框是**入口**不是输入框：真输入在 'Search' 二级页（push 后自动聚焦）。
 *
 * 头部滚动联动：列表偏移跨越 HOME_ENTRY_FLIP_VP 时翻转
 * STORE_HOME_SEARCH_ENTRY_ACTIVE（只在翻转时写），Index 标题栏读它
 * 淡入/淡出右上搜索按钮 —— 头部滚出视口后用户随时有搜索入口。
 *
 * B 站数据源里本页占两个，分页能力各不相同（对照实验结论，细节见
 * api/BilibiliApi.ts 的注释）：
 *   · 推荐     —— 首屏 index/top/rcmd（30 条，重复调用返回同一批）+ popular pn=1；
 *                 翻页必须走 feed/rcmd 的 fresh_idx（每页约 17 条新内容）
 *   · 音乐中心 —— 新歌榜（最新发布，固定 18 条）置顶 + 综合榜（热歌，真分页 pn）随后
 * 把「不能分页的源」硬接成上拉加载，得到的就是「一直加载却永远同一批」，所以分开处理。
 * 「下拉刷新 + 上拉加载更多」机制见 build 内注释（骨架接管）。
 *
 * 第三、四个数据源「热歌榜」（ranking tab）与「热门歌单」（netease tab）是
 * 网易云第三方源（api/NeteaseApi）：
 *   · 热歌榜 —— 云音乐热歌榜（固定歌单 3778678，v6 trackIds + v3 分批详情），
 *     一次拿全后前端切片展示（HOT_CHART_PAGE_SIZE）；单曲无 B 站 bvid，
 *     点行实时 matchSongForPlayback 匹配 B 站音源播放（仅单曲点播）。
 *   · 热门歌单 —— api/playlist/list 热门歌单网格，点卡进 NeteasePlaylist 预览页。
 * 两个 tab 都不进启动轮、不落 HomeFeedCacheStore（ExternalSong 系模型不适配
 * Track 缓存），首次切到 tab 时懒加载（onTabChanged → maybeLoadHotChart /
 * maybeLoadNetease），骨架/空态在列表内原位渲染（防搜索框/快捷卡/chips 顶飞闪屏）。
 */

import * as BilibiliApi from '../api/BilibiliApi';
import {
  PopularVideo,
  MusicCenterItem,
  MusicCenterRelatedArchive
} from '../api/BilibiliApi';
import { Playlist, Track, VideoDetail, buildTrack, ITEM_DISPLAY_LIST, ITEM_DISPLAY_GRID } from '../model/MusicModels';
import { LibraryStore } from '../service/LibraryStore';
import { TrackItem } from '../components/TrackItem';
import { TrackCard } from '../components/TrackCard';
import { CoverImage } from '../components/CoverImage';
import { SkeletonTrackItem } from '../components/SkeletonTrackItem';
import { MusicPlayer } from '../player/MusicPlayer';
import { toHttpsUrl, stripHtmlTags, toThumbUrl, formatDurationText } from '../utils/TextUtil';
import { openCollectionOrPlay } from '../utils/CollectionNavigator';
import { ComponentContent, CustomContentDialog } from '@kit.ArkUI';
import { NavStackHolder } from '../service/NavStackHolder';
import { UpSpaceRouteParam } from '../service/NavRouteParams';
import { NeteasePlaylistRow, NeteasePlaylistCard } from '../components/NeteasePlaylistItem';
import {
  NeteasePlaylistSummary,
  NeteaseHotSong,
  NeteaseHotChart,
  NeteaseHotPlaylistsResult,
  fetchNeteaseHotPlaylists,
  fetchNeteaseHotChart
} from '../api/NeteaseApi';
import { ExternalSong, matchSongForPlayback } from '../service/PlaylistImporter';
import { ensureLazyPageLoaded } from '../service/LazyPageRegistry';
import {
  DownloadManager,
  DownloadStartResult,
  WIFI_ONLY_BLOCKED
} from '../service/DownloadManager';
import { UpSpaceCacheEntry, getUpSpaceCache } from '../service/UpSpaceCacheStore';
import { currentNetworkLabel, hasNetwork } from '../utils/NetworkUtil';
import {
  CONTENT_END_OFFSET,
  DEFAULT_PLAYLIST_NAME,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_NET_RETRY_REV,
  STORE_FEED_FILTER_REV,
  STORE_SEARCH_TAB,
  STORE_ITEM_DISPLAY_STYLE,
  STORE_THEME_DEEP,
  STORE_HOME_SEARCH_ENTRY_ACTIVE,
  STORE_HOME_CHIPS_ACTIVE,
  STORE_LIBRARY_REV,
  STORE_WINDOW_WIDTH_VP
} from '../common/Constants';
import { FlingSampler } from '../components/FlingSampler';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';
import { showAppToast } from '../components/AppToast';
import { PLAYBACK_LOG_INFO, PLAYBACK_LOG_ERROR, recordPlaybackLog } from '../service/PlaybackLogStore';
import { showConfirm } from '../components/AppAlertDialog';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import {
  RowOf,
  RowDataSource,
  TWO_COL_GAP_VP,
  GRID_EDGE_PADDING_VP,
  TwoColumnLayout
} from '../common/utils/TwoColumnList';
import { ArrayDataSource } from '../utils/ArrayDataSource';
import { NAV_TITLE_BAR_HEIGHT, NAV_H_PADDING } from '../utils/NavTitleStyle';
import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { HomeCategoryChips } from '../components/HomeCategoryChips';
import { HomeQuickCards } from '../components/HomeQuickCards';
import { HomeCardStore } from '../service/HomeCardStore';
import {
  HomeFeedCacheEntry,
  getHomeFeedCache,
  saveHomeFeedCache
} from '../service/HomeFeedCacheStore';
import { FeedFilterConfig, FeedUpEntry } from '../model/FeedFilterModels';
import {
  CompiledFeedFilter,
  applyFeedFilter,
  compileFeedFilter,
  isTrackUpBlocked,
  normalizeFilterText
} from '../utils/FeedFilterEngine';
import { getFeedFilterConfig, updateFeedFilterConfig } from '../service/HomeFeedFilterStore';
import {
  PULL_REFRESH_OFFSET_VP,
  PULL_REFRESH_RATIO,
  PULL_MAX_DISTANCE_VP,
  PULL_SKELETON_SETTLE_VP,
  PULL_SKELETON_EXIT_VP,
  PULL_SKELETON_FADE_MS,
  BUTTON_RADIUS_VP,
  LIST_FOOTER_HEIGHT_VP
} from '../common/constants/InteractionConstants';

function mapPopular(v: PopularVideo): Track {
  return buildTrack({
    id: v.bvid,
    bvid: v.bvid,
    aid: String(v.aid),
    title: stripHtmlTags(v.title),
    artist: v.owner?.name ?? '',
    // owner 在 API 层就已解析出 mid（getRecommendedFeed 里 owner 为 null 的条目已被剔除）
    upMid: v.owner && v.owner.mid ? String(v.owner.mid) : '',
    coverUrl: toHttpsUrl(v.pic),
    duration: v.duration,
    pubdate: v.pubdate ?? 0,
    // 首页筛选元数据：分区名 / 推荐理由 / 点赞数（feed 通道 like 缺省为 0 = 未知）
    category: v.tname ?? '',
    rcmdReason: v.rcmdReason ?? '',
    likeCount: v.stat ? v.stat.like : 0
  });
}

/**
 * 音乐中心：线上是下划线字段（music_title / music_id / related_archive），驼峰仅作兜底。
 *
 * ⚠️ **不要把 cid 传下去**：音乐中心的 `related_archive.cid` 是**音频 cid**，
 * 不属于该 bvid 的视频分 P（实测：BV1kQhz6fEMZ 的 pages[0].cid=42091416602，
 * 但 related_archive.cid=117309800781135 → playurl 返回 -404「啥都木有」）。
 * 传这个 cid 会让音乐中心所有条目解析不出音源 —— 用户看到的就是
 * 「点了歌，封面歌名都换了，放出来的还是上一首」。播放侧会用 view 返回的真实 cid。
 */
function mapMusicCenter(x: MusicCenterItem): Track {
  const related: MusicCenterRelatedArchive | undefined = x.related_archive ?? x.relatedArchive;
  const playable: string = related?.bvid || x.bvid;
  let title: string = (x.music_title ?? x.musicTitle ?? '').trim();
  if (title.length === 0) {
    title = related?.title ?? x.album ?? '';
  }
  const coverUrl: string = pickMusicCenterCover(x, related);
  return buildTrack({
    id: (x.music_id ?? x.musicId ?? '') || playable,
    bvid: playable,
    aid: x.aid,
    title: title,
    artist: x.author,
    // 音乐中心结构里**没有 mid**（只有 author 字符串）→ 这里留空，
    // 「进 UP 主主页」会退回用 bvid 走 getVideoDetail 换 owner.mid（带 viewCache）。
    upMid: '',
    coverUrl: coverUrl,
    // 音乐中心**自带时长**（在 `related_archive.duration`，单位秒，实测 140）。
    // 缺了它列表条目 duration=0，连带歌词匹配的「时长加分」也拿不到
    // （见 PlayerPage 的信息键注释）。
    duration: related?.duration ?? 0
  });
}

/**
 * 音乐中心的封面取值链：**专辑图优先，视频截图兜底**。
 *
 * 实测同一个条目会带**两张完全不同的图**（这不是异常，是接口设计）：
 *   · `cover`            → 专辑封面 `…/bfs/station_src/music_metadata/xxx.jpg`（约 33KB）
 *   · `related_archive.cover` → 承载视频的截图 `…/bfs/archive/xxx.jpg`（约 574KB）
 * 播放侧的合并规则是「列表侧优先」，所以这里选哪张，播放页就会显示哪张。
 * 一旦这里和播放侧不一致，用户看到的就是「播放页的图和列表里不是同一张」。
 * 因此两处必须走同一条链：专辑图 → 视频图。
 */
function pickMusicCenterCover(x: MusicCenterItem, related: MusicCenterRelatedArchive | undefined): string {
  const album: string = x.cover ?? '';
  if (album.length > 0) {
    return toHttpsUrl(album);
  }
  const video: string = related ? (related.cover ?? '') : '';
  return toHttpsUrl(video);
}

/**
 * 音乐中心列表映射 + 可播性过滤。
 * 没有 bvid 的条目（纯音频卡片）在播放侧必然解析失败，放进来就是一行
 * 「点了没反应 / 信息换了歌没换」的坏条目，这里直接拦掉并记账。
 */
function mapMusicCenterList(list: MusicCenterItem[]): Track[] {
  const out: Track[] = [];
  for (let i = 0; i < list.length; i++) {
    const t: Track = mapMusicCenter(list[i]);
    if (t.bvid.length > 0 && t.bvid.indexOf('BV') === 0) {
      out.push(t);
    } else {
      console.error(`music center item without playable bvid: ${t.id} / ${t.title}`);
    }
  }
  return out;
}

/**
 * 追加合并并去重（首屏双源合成仍在用，如 settleCenter）。
 *
 * 必须去重：ForEach 的 keyGenerator 用的是 track.id，重复 id 会让 ArkUI 复用错节点
 * （表现为滚动时条目跳动 / 部分行空白）。推荐位尤其明显——首屏两个源
 * （popular 与 rcmd）实测重叠约 8/10。
 */
function mergeTracks(base: Track[], add: Track[]): Track[] {
  const seen: Set<string> = new Set<string>();
  const out: Track[] = [];
  for (let i = 0; i < base.length; i++) {
    const t: Track = base[i];
    if (!seen.has(t.id)) {
      seen.add(t.id);
      out.push(t);
    }
  }
  for (let i = 0; i < add.length; i++) {
    const t: Track = add[i];
    if (!seen.has(t.id)) {
      seen.add(t.id);
      out.push(t);
    }
  }
  return out;
}

/**
 * 下拉刷新区的静态空占位（骨架接管）：唯一作用是顶掉系统默认的
 * 刷新头（转圈/竖条），0.1vp 高度 = 视觉上不存在。刷新指示完全由 List
 * 首行的骨架行承担（见 build 里 List 的下拉骨架条目）。
 *
 * 刻意用 refreshingContent 而非 builder：占位不需要跟手，而 builder 会被
 * 状态变化重建，下拉时状态每帧都在变，用它纯属白白重建。
 * ⚠️ ComponentContent 的内容**不随页面 @State 刷新**（要变只能显式调
 * content.update(args)），所以这里必须是**静态**内容 —— 凡是「随下拉
 * 每帧变化」的视觉一律放 List 的普通组件树里，绝不放这里。
 */
@Builder
function PullRefreshPlaceholder(): void {
  Column()
    .width('100%')
    .height(0.1)
}

const CENTER_PAGE_SIZE: number = 20;
/** 网易云热门歌单每页条数（api/playlist/list 的 limit，offset 游标分页） */
const NETEASE_PAGE_SIZE: number = 30;
/**
 * 下拉刷新「换一批」的随机页池大小：榜单前 N 页内随机跳（不含第 0 页）。
 * 服务端 order=hot 是按天级更新的固定榜，同参数永远同一页 —— 想让下拉
 * 刷新有感知就换页取数；池子取前 10 页是热度与新鲜度的折中（越靠后越冷）。
 */
const NETEASE_REFRESH_RANDOM_PAGES: number = 10;
/** 推荐流每页条数：实测 ps=20 时约 17 条有效（其余是登录引导/广告卡片） */
const RECOMMEND_FEED_PS: number = 20;
/** 过滤后首屏目标条数：筛选开启且不足时自动补拉推荐流翻页 */
const RECOMMEND_TOPUP_TARGET: number = 15;
/** 单次补页最多拉几轮（防极端筛选下请求风暴；每轮约 17 条有效内容） */
const RECOMMEND_TOPUP_MAX_ROUNDS: number = 3;
/** 热歌榜一次拿全（v6+v3）后前端切片，每次多放这么多条 */
const HOT_CHART_PAGE_SIZE: number = 20;
/**
 * 列表首条独立让位定值（vp）：固定标题行 56 + 此值 = List 首个空白占位
 * 条目高度（不含 safeTop）。取 8：搜索框与栏底只留常规呼吸间距，
 * 骨架 / 空态共用 listStartOffset 一并跟随。
 */
const HOME_LIST_START_EXTRA_VP: number = 8;
/**
 * 头部滚出判定阈值（vp）：列表偏移 ≥ 此值时入口搜索框已完全滚入根栏
 * 遮挡区（入口行高 44 + 下距 12 ≈ 56），翻转 STORE_HOME_SEARCH_ENTRY_ACTIVE
 * 让 Index 标题栏淡入右上搜索按钮。
 */
const HOME_ENTRY_FLIP_VP: number = 56;
/**
 * chip 条触及栏底判定阈值（vp）：列表偏移 ≥ 此值时分类 chip 条（推荐 /
 * 排行榜 / 音乐中心）顶缘刚上移到导航栏底，翻转 STORE_HOME_CHIPS_ACTIVE
 * 让 Index 标题栏在问候语右侧淡入三个分类 tab 图标（标题与问候语常驻，
 * 与 HOME_ENTRY_FLIP_VP 同一套滚动翻转镜像）。
 * 距顶距离 = 起始让位 8 + 搜索行 56 + 快捷卡行 184（卡行高度计入本阈值）。
 */
const HOME_TABS_FLIP_VP: number = 248;

/**
 * 骨架屏占位行：首屏整页用 8 行（贴合首屏可见条数），上拉加载更多用 3 行。
 * 只作 ForEach 的数据源，渲染时忽略内容。
 */
const SKELETON_ROW_INDEXES: number[] = [0, 1, 2, 3, 4, 5, 6, 7];

/** 诊断：HomePage 实例号（排查多壳 / 折叠开合的挂载顺序） */
let homePageInstanceSeq: number = 0;

@Component
export struct HomePage {
  /** 内容 tab（'recommend'/'ranking'/'center'/'netease'）：HomeCategoryChips 写、本页读；非法值兜底为 recommend（见 normalizeTab） */
  @StorageLink(STORE_SEARCH_TAB) @Watch('onTabChanged') tab: string = 'recommend';
  /** 主题色深色运行时值：歌单选择弹层的「新建歌单并加入」跟随切色刷新 */
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  @State @Watch('onListSourceChanged') recommend: Track[] = [];
  /** 网易云热歌榜歌曲（ranking tab）：@Watch → ArrayDataSource reload */
  @State @Watch('onListSourceChanged') hotSongs: NeteaseHotSong[] = [];
  @State @Watch('onListSourceChanged') center: Track[] = [];
  /** 网易云热门歌单（netease tab 网格）：同款 @Watch → ArrayDataSource reload */
  @State @Watch('onListSourceChanged') neteasePlaylists: NeteasePlaylistSummary[] = [];
  // ===== 列表数据源（LazyForEach 渲染）=====
  // 三 tab 数组都挂 @Watch('onListSourceChanged')：整表替换与 push 追加都会触发
  // （V1 数组代理拦截 push），对应 ArrayDataSource 整表 reload + 行数据源
  // sync。reload 语义与 tab 数据流天然匹配：刷新必是整表换源；翻页 push 时
  // LazyForEach 只重建可视区，代价可控。
  // 行数据源（RowOf N 槽）：列数随窗口宽动态（onColumnsChanged setColumns+sync，
  // 平板横屏 3~4 列铺满，手机/折叠屏落回 2 列现值）。
  private recommendSource: ArrayDataSource<Track> = new ArrayDataSource<Track>([]);
  private recommendRows: RowDataSource<Track> = new RowDataSource<Track>(this.recommendSource, 2);
  /** 热歌榜单曲数据源（ranking tab，单列行渲染） */
  private hotSongSource: ArrayDataSource<NeteaseHotSong> = new ArrayDataSource<NeteaseHotSong>([]);
  private centerSource: ArrayDataSource<Track> = new ArrayDataSource<Track>([]);
  private centerRows: RowDataSource<Track> = new RowDataSource<Track>(this.centerSource, 2);
  /** 网易云热门歌单数据源（行/列口径与三个 track 源完全同构：onColumnsChanged 联动） */
  private neteaseSource: ArrayDataSource<NeteasePlaylistSummary> = new ArrayDataSource<NeteasePlaylistSummary>([]);
  private neteaseRows: RowDataSource<NeteasePlaylistSummary> = new RowDataSource<NeteasePlaylistSummary>(this.neteaseSource, 2);
  /** 诊断用实例号（aboutToAppear 分配） */
  private pageId: number = 0;
  /** 推荐位待完成的数据源数量（热门 + 推荐两个源并行，互不影响） */
  @State recommendPending: number = 0;
  /** 热歌榜首屏加载中（首次切 tab / 下拉刷新 / 空态重试） */
  @State loadingHotChart: boolean = false;
  /** 音乐中心待完成的数据源数量（综合榜 + 新歌榜并行，互不影响） */
  @State centerPending: number = 0;
  /**
   * 快捷卡行数据（见 HomeQuickCards）：
   * 最近播放全量（点播放按钮 = playAll 整表）+ 已加入首页的歌单卡（加入顺序）。
   * 刷新走 STORE_LIBRARY_REV（Tabs 常驻铁律）：播放新歌 / 歌单增删 / ⋯ 菜单
   * 「加入首页 / 移出首页」都会 bump 它。
   */
  @StorageLink(STORE_LIBRARY_REV) @Watch('onLibraryRevChanged') libraryRev: number = 0;
  @State recentTracks: Track[] = [];
  @State cardPlaylists: Playlist[] = [];
  /**
   * 快捷卡 UP 订阅投稿数缓存（upMid → archiveCount，0 = 未知）：
   * 订阅卡副题「N 个投稿」的 N 优先取它，未知回退歌单已落库曲目数
   * （口径与歌单页 subLineOf 一致）。getUpSpaceCache 只读本地缓存，不联网。
   */
  @State upArchiveCounts: Map<string, number> = new Map();
  /**
   * 「+」卡选择器（快捷卡行末尾添加卡）：官方 CustomContentDialog 标准
   * 弹窗（addCardPickerController）。候选 = 未加入首页的歌单（与歌单页
   * getPlaylists 同口径，含订阅歌单）。
   */
  @State addCandidates: Playlist[] = [];
  /**
   * 「更换首页歌单」选择器（歌单卡长按菜单「更换歌单」入口）：候选同
   * 「+」卡口径（未加入首页的歌单），选中走 HomeCardStore.replaceHomePlaylist
   * 原位替换（卡片位置不变）。
   */
  @State replaceCandidates: Playlist[] = [];
  /** 被更换的原歌单（打开选择器时定格；null = 不在选择流程中） */
  @State replaceFromPlaylist: Playlist | null = null;
  /** 底部安全区高度（vp）：根容器不再统一避让，列表末尾让位要自己叠上这一份 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /**
   * 状态栏高度（vp）：顶部占位 / 骨架 / 空态让位公式都用它，
   * 材质从 y=0 铺起覆盖状态栏。
   */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /**
   * 顶栏渐变模糊层进度更新器：onDidScroll / onScrollStop
   * 命令式驱动（不标 @State，滚动高频回调零重建），见 syncTopBlurProgress。
   */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();
  /**
   * 网络恢复重试信号（Index 的 watchNetwork 在「断过又恢复」时递增）。
   * @StorageProp 单向只读 —— 页面不改它，只借 @Watch 收通知。
   */
  @StorageProp(STORE_NET_RETRY_REV) @Watch('onNetRetry') netRetryRev: number = 0;
  /**
   * 首页筛选规则版本号（HomeFeedFilterStore 写入）。@StorageProp 单向只读：
   * 设置页保存 / 快捷屏蔽后 bump，本页 @Watch 从 recommendRaw 重滤推荐列表
   * （纯客户端过滤，不发网络请求）。
   */
  @StorageProp(STORE_FEED_FILTER_REV) @Watch('onFeedFilterRevChanged') feedFilterRev: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中，见 build 里的 constraintSize */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) @Watch('onColumnsChanged') currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 横竖屏（Index 常驻注册写入）：横屏宽屏时条目多列显示 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) @Watch('onColumnsChanged') isLandscape: boolean = false;
  /**
   * 窗口宽（vp，Index 常驻回写）：平板横屏按它反推行数（2~4 列长条 / 2~6 卡网格）
   * 与铺满上限；@StorageProp 初值同步不触发 @Watch，aboutToAppear 显式补一次。
   */
  @StorageProp(STORE_WINDOW_WIDTH_VP) @Watch('onColumnsChanged') windowWidthVp: number = 0;

  /** 条目展示（外观设置「条目展示」）：长条（默认）/ 大封面双列网格 */
  @StorageProp(STORE_ITEM_DISPLAY_STYLE) @Watch('onColumnsChanged') itemDisplay: string = ITEM_DISPLAY_LIST;

  /**
   * 大封面模式：三页签（推荐 / 排行榜 / 音乐中心）的封面类视频条目配对成
   * 双列网格卡（TrackCard），竖屏 / 横屏均双列；交互契约与行内版一致
   * （整卡点击播/暂停、「⋯」菜单）。配对数据源（recommendRows 等）在
   * onListSourceChanged 无条件 sync，网格竖屏也是热的。
   */
  private isGrid(): boolean {
    return this.itemDisplay === ITEM_DISPLAY_GRID;
  }

  // ── 动态列数状态（平板横屏铺满改造）──
  /** 长条行列数（TwoColumnLayout.listColumns 反推，非两列态 1） */
  @State listCols: number = 1;
  /** 网格卡列数（TwoColumnLayout.gridColumns 反推，非两列态仍 2——竖屏网格本就双列） */
  @State gridCols: number = 2;
  /** 行数据源当前生效列数缓存：与重算值不同才 setColumns+sync（防 @Watch 抖动重载） */
  private activeCols: number = 2;

  /** 当前行渲染列数：网格模式取 gridCols、长条模式取 listCols（@State 驱动 build 分支） */
  private rowColumns(): number {
    return this.isGrid() ? this.gridCols : this.listCols;
  }

  /**
   * 列数联动（@Watch：断点 / 横竖屏 / 窗口宽 / 展示样式变化）：
   * 重算长条与网格列数，行数据源列数变化时 setColumns + sync
   * （漏 sync 会出现 totalCount 与渲染数不一致的空白/重叠）。
   * aboutToAppear 显式补一次（@StorageProp 初值同步不触发 @Watch）。
   */
  private onColumnsChanged(): void {
    this.listCols = TwoColumnLayout.listColumns(this.currentBreakpoint, this.isLandscape, this.windowWidthVp);
    this.gridCols = TwoColumnLayout.gridColumns(this.currentBreakpoint, this.isLandscape, this.windowWidthVp);
    const active: number = this.rowColumns();
    if (active === this.activeCols) {
      return;
    }
    this.activeCols = active;
    this.recommendRows.setColumns(active);
    this.recommendRows.sync();
    this.centerRows.setColumns(active);
    this.centerRows.sync();
    // 热门歌单行数据源同口径联动（长条=listCols、大封面=gridCols）：
    // 双模式渲染与上面三个数据源完全同构。
    this.neteaseRows.setColumns(active);
    this.neteaseRows.sync();
  }

  /** Refresh 组件的转圈状态（$$ 双向绑定，干完活必须落回 false 才会收起） */
  @State refreshing: boolean = false;
  /** 加载更多进行中（同一时刻只允许一个 tab 在加载） */
  @State loadingMore: boolean = false;
  /** 推荐流还有没有下一页（feed 返回 0 条或整页重复即到底） */
  @State recommendHasMore: boolean = true;
  /** 音乐中心还有没有下一页（综合榜某页返回 0 条即到底） */
  @State centerHasMore: boolean = true;
  // ===== 网易云热门歌单（netease tab）=====
  /** 首屏加载中（首次切 tab / 下拉刷新 / 空态重试） */
  @State loadingNetease: boolean = false;
  /** 热门歌单还有没有下一页（接口 more 字段 + 整页去重后无新增即到底） */
  @State neteaseHasMore: boolean = true;
  /** 分页游标（0 起，下一页 += 本页原始条数） */
  private neteaseOffset: number = 0;
  /** 首次加载已成功过（幂等闸门：切走再切回不重拉，空态重试 / 下拉刷新除外） */
  private neteaseLoadedOnce: boolean = false;

  /**
   * ── 下拉刷新头（骨架接管）──
   * 刷新指示器复用 SkeletonTrackItem 骨架行，不新增任何视觉元素：
   *   · 跟手 —— onOffsetChange 每帧把下拉进度映射成骨架的淡入 + 落位；
   *   · 触发 —— 骨架停在原位保持纯静态；
   *   · 收尾 —— Done 后 250ms 淡出，动画放完再摘节点（句柄兜底回收）。
   */
  /** 刷新头骨架是否渲染（双骨架闸门：整屏骨架在场时必须为 false） */
  @State showPullSkeleton: boolean = false;
  /** 当前下拉偏移（vp）：onOffsetChange 每帧回写，只写状态、无副作用 */
  @State pullOffset: number = 0;
  /** 刷新头骨架透明度 ＝ 下拉进度（0..1，跟手不套 animateTo） */
  @State pullSkelOpacity: number = 0;
  /** 刷新头骨架纵移（vp）：下拉时从上方 12vp 落位 */
  @State pullSkelOffsetY: number = PULL_SKELETON_SETTLE_VP;
  /** Done 后骨架淡出的收尾句柄（照 PlayButtonComponent 的定时器回收模式） */
  private pullFadeTimer: number = -1;
  /** 下拉刷新区占位：ComponentContent 构造依赖 UIContext，属性初始化时未就绪，aboutToAppear 里建 */
  private refreshPlaceholder: ComponentContent<Object> | null = null;

  private player: MusicPlayer = MusicPlayer.getInstance();
  /** 推荐流游标：每加载一页 +1（feed/rcmd 靠 fresh_idx 换内容） */
  private recommendFreshIdx: number = 1;
  private centerPage: number = 1;
  /** 音乐中心首屏缓冲：新歌榜与热歌榜各自落定后再按固定顺序合成（见 settleCenter） */
  private centerNewTracks: Track[] = [];
  private centerHotTracks: Track[] = [];
  // ===== 网易云热歌榜（ranking tab）：第三方源，独立于启动轮 =====
  /** 热歌榜全量（v6+v3 一次拿全，展示侧按 HOT_CHART_PAGE_SIZE 前端切片） */
  private hotChartAll: NeteaseHotSong[] = [];
  /** 首次加载已成功过（幂等闸门：切走再切回不重拉，空态重试 / 下拉刷新除外） */
  private hotChartLoadedOnce: boolean = false;
  /** 正在匹配播放的行下标（-1 = 空闲；单飞互斥防 B 站搜索风控，行尾转圈反馈） */
  @State matchingIndex: number = -1;
  /**
   * 推荐位首屏双源暂存（热门 / 推荐流）：与 centerNewTracks/centerHotTracks 同款
   * staging 模式 —— 各自落定后由 settleRecommend 按固定顺序合成整表替换，
   * 支撑「启动缓存在场时静默校验、成功才替换」的语义（见 initHomeFeed）。
   */
  private recommendHotTracks: Track[] = [];
  private recommendFeedTracks: Track[] = [];
  /**
   * 推荐位未过滤全量（raw）。数据责任：去重 / hasMore / 缓存落盘全基于它；
   * this.recommend 只承担渲染责任（refilterRecommend 从 raw 过滤派生）——
   * 放宽规则时被滤条目可从 raw 即时救回，不必重新拉网。
   * 刻意不标 @State：改写点必伴随 this.recommend 整体重赋值，由后者驱动刷新。
   */
  private recommendRaw: Track[] = [];
  /** 已编译筛选产物缓存（rev 变更时置空重编译；引擎另有 JSON 签名缓存兜底） */
  private feedFilterCompiled: CompiledFeedFilter | null = null;
  /** 快捷「屏蔽标题关键词」对话框：预填关键词（用户可改短 / 改成正则） */
  @State quickBlockKeyword: string = '';
  /** 快捷「屏蔽标题关键词」目标曲目（打开对话框时定格，null = 不在流程中） */
  private quickTitleBlockTrack: Track | null = null;
  /**
   * 快捷「屏蔽标题关键词」对话框 controller（每次打开重建）。
   * CustomContentDialog buttons 槽的内置自动关闭对方法内局部创建的
   * controller 不生效（真机/模拟器实测），必须持有引用显式 close。
   */
  private quickTitleBlockDialog: CustomDialogController | null = null;
  // ===== 启动缓存兜底（网络不佳时先出缓存内容，见 initHomeFeed）=====
  /** 本次会话任一 tab 恢复过启动缓存（决定静默校验与恢复提示的分支） */
  private cacheAppliedAny: boolean = false;
  /** 「网络不佳」类 toast 只弹一次（启动轮 4 个请求的失败提示共享去重） */
  private netPoorToastShown: boolean = false;
  /** 启动即离线、跳过了联网加载（等 STORE_NET_RETRY_REV 恢复信号补拉） */
  private offlineStartupSkipped: boolean = false;
  /** initHomeFeed 已跑完（收尾前忽略 onNetRetry，防「注册瞬间的 available」抢跑双拉） */
  private homeFeedInitDone: boolean = false;
  /** 启动轮统计窗口：只覆盖 initHomeFeed 发起的第一轮 4 个请求 */
  private startupRoundActive: boolean = false;
  private startupDone: number = 0;
  private startupFail: number = 0;

  /**
   * 头部在场状态镜像（vp 偏移 < HOME_ENTRY_FLIP_VP）：只在翻转时写
   * STORE_HOME_SEARCH_ENTRY_ACTIVE，Index 标题栏读它淡入/淡出右上搜索按钮。
   * 不标 @State —— 翻转本身不驱动本页任何 UI，写 AppStorage 即可。
   */
  private entryActive: boolean = true;

  /**
   * chip 条在场状态镜像（vp 偏移 < HOME_TABS_FLIP_VP，chip 条尚未触及导航栏）：
    * 只在翻转时写 STORE_HOME_CHIPS_ACTIVE，Index 标题栏读它在问候语右侧
    * 淡入/淡出三个分类 tab 图标（标题与问候语常驻）。不标 @State —— 翻转
    * 本身不驱动本页任何 UI，写 AppStorage 即可。
   */
  private chipsActive: boolean = true;

  @State playlistOptions: Playlist[] = [];
  @State pickerTrack: Track | null = null;

  /** 「保存合集为歌单」：展开成功后让用户确认歌单名（默认取音频标题） */
  @State collectionName: string = '';
  @State pendingCollectionTracks: Track[] = [];
  /**
   * 「保存合集为歌单」对话框：CustomContentDialog 标准对话框，走
   * CustomDialogController，绝不走 promptAction —— 崩溃史见
   * AppAlertDialog.ets 头注释。aboutToAppear 创建一次，绝不重新赋值。
   */
  private collectionSaverController: CustomDialogController | undefined = undefined;
  /**
   * 「加入歌单」弹窗：官方 CustomContentDialog 标准对话框（默认遮罩 +
   * 官方按钮槽，替代原根 Stack 内自绘弹层）。标题/按钮为常量 →
   * controller 建一次永不重建（faqs-arkui-555 只定格构造参数，动态内容
   * 经 contentBuilder 闭包在 open() 时读当次状态）。
   */
  private playlistPickerController: CustomDialogController | undefined = undefined;
  /** 「添加歌单到首页」弹窗：同上，官方 CustomContentDialog 标准对话框 */
  private addCardPickerController: CustomDialogController | undefined = undefined;
  /** 「更换首页歌单」弹窗：同上，官方 CustomContentDialog 标准对话框 */
  private replaceCardPickerController: CustomDialogController | undefined = undefined;

  /**
   * 列表数组变化（@Watch 携带属性名）：同步对应数据源。
   * 初始赋值不触发 @Watch，会话恢复场景由 syncAllListSources（aboutToAppear）兜底。
   */
  private onListSourceChanged(propName: string): void {
    if (propName === 'recommend') {
      this.recommendSource.reload(this.recommend);
      this.recommendRows.sync();
    } else if (propName === 'hotSongs') {
      this.hotSongSource.reload(this.hotSongs);
    } else if (propName === 'center') {
      this.centerSource.reload(this.center);
      this.centerRows.sync();
    } else if (propName === 'neteasePlaylists') {
      this.neteaseSource.reload(this.neteasePlaylists);
      this.neteaseRows.sync();
    }
  }

  /** 初值同步（@Watch 不触发初始赋值）：挂载时补一次 */
  private syncAllListSources(): void {
    this.recommendSource.reload(this.recommend);
    this.recommendRows.sync();
    this.hotSongSource.reload(this.hotSongs);
    this.centerSource.reload(this.center);
    this.centerRows.sync();
    this.neteaseSource.reload(this.neteasePlaylists);
    this.neteaseRows.sync();
  }

  /**
   * tab 值兜底：旧版升级用户的 AppStorage 里 STORE_SEARCH_TAB 可能残留
   * 'search'（旧搜索页签）—— 本页分支都不命中会渲染空列表，这里归一到
   * 'recommend'。
   */
  private normalizeTab(): void {
    if (this.tab !== 'recommend' && this.tab !== 'ranking' && this.tab !== 'center' && this.tab !== 'netease') {
      this.tab = 'recommend';
    }
  }

  /** tab 切换（chip 点击写 STORE_SEARCH_TAB → @Watch）：热歌榜 / 热门歌单懒加载触发点 */
  private onTabChanged(): void {
    this.maybeLoadHotChart();
    this.maybeLoadNetease();
  }

  /**
   * 热歌榜懒加载：首次切到 ranking tab 时拉全量榜单。
   * 幂等闸门：已成功过 / 加载中 / 非本 tab 直接返回 —— 切走再切回不重拉
   * （内容还在内存里）；失败后切走再切回会自动重试（hotChartLoadedOnce 未置位）。
   */
  private maybeLoadHotChart(): void {
    if (this.tab !== 'ranking' || this.hotChartLoadedOnce || this.loadingHotChart) {
      return;
    }
    this.loadHotChart();
  }

  /**
   * 热门歌单懒加载：首次切到 netease tab 时拉第一页。
   * 幂等闸门：已成功过 / 加载中 / 非本 tab 直接返回 —— 切走再切回不重拉
   * （内容还在内存里）；失败后切走再切回会自动重试（neteaseLoadedOnce 未置位）。
   */
  private maybeLoadNetease(): void {
    if (this.tab !== 'netease' || this.neteaseLoadedOnce || this.loadingNetease) {
      return;
    }
    // 预取预览页模块：用户停在 netease tab 浏览期间后台加载完成，点击歌单
    // 不落 LazyDest 转圈兜底（首启预热序列串行，排位靠后快点会撞上 → 闪屏）。
    ensureLazyPageLoaded('NeteasePlaylist');
    this.loadNeteaseFirstPage();
  }

  /**
   * 快捷卡行数据重灌：最近播放整表 + 首页歌单卡。已删歌单 getPlaylist 返
   * null 自动跳过（卡片自愈消失，HomeCardStore 残留 id 不影响 —— 歌单 id
   * 全局唯一，下次加入新歌单不会错位复用）。
   */
  private refreshQuickCards(): void {
    this.recentTracks = LibraryStore.getRecentTracks();
    const ids: string[] = HomeCardStore.getHomePlaylistIds();
    const out: Playlist[] = [];
    for (let i = 0; i < ids.length; i++) {
      const p: Playlist | null = LibraryStore.getPlaylist(ids[i]);
      if (p !== null) {
        out.push(p);
      }
    }
    this.cardPlaylists = out;
    this.loadUpArchiveCounts();
  }

  /**
   * 快捷卡 UP 订阅投稿数重灌（PlaylistsPage.loadUpArchiveCounts 同款）：
   * 读 UpSpaceCache 本地缓存（15~50KB/UP，订阅卡最多 9 张），不联网。
   * 到货后顺手浅拷 cardPlaylists 一次 —— 新数组引用触发子组件 ForEach
   * 重跑键值 diff，订阅卡键含投稿数（见 HomeQuickCards），数字到位即重建该卡。
   */
  private loadUpArchiveCounts(): void {
    const mids: string[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < this.cardPlaylists.length; i++) {
      const p: Playlist = this.cardPlaylists[i];
      if (!LibraryStore.isUpSubscription(p) || seen.has(p.upMid)) {
        continue;
      }
      seen.add(p.upMid);
      mids.push(p.upMid);
    }
    if (mids.length === 0) {
      this.upArchiveCounts = new Map();
      return;
    }
    const loads: Promise<UpSpaceCacheEntry | null>[] = [];
    for (let i = 0; i < mids.length; i++) {
      loads.push(getUpSpaceCache(mids[i]));
    }
    Promise.all<UpSpaceCacheEntry | null>(loads)
      .then((entries: Array<UpSpaceCacheEntry | null>): void => {
        const next: Map<string, number> = new Map<string, number>();
        for (let i = 0; i < mids.length; i++) {
          const entry: UpSpaceCacheEntry | null = entries[i];
          next.set(mids[i], entry !== null ? entry.archiveCount : 0);
        }
        this.upArchiveCounts = next;
        this.cardPlaylists = [...this.cardPlaylists];
      })
      .catch((e: Error): void => {
        console.error(`load up archive counts failed: ${e.message}`);
      });
  }

  /** 媒体库 / 首页歌单卡变更信号：快捷卡行重灌（幂等内存快照读，无 IO） */
  onLibraryRevChanged(): void {
    this.refreshQuickCards();
  }

  /**
   * 「+」卡点击：刷新候选（未加入首页的歌单）后弹选择器。
   * 无候选给口令提示：有歌单但全在架 vs 一个歌单都没有，指路不同。
   */
  private onAddCardClick(): void {
    const all: Playlist[] = LibraryStore.getPlaylists();
    const candidates: Playlist[] = [];
    for (let i = 0; i < all.length; i++) {
      if (!HomeCardStore.isHomePlaylist(all[i].id)) {
        candidates.push(all[i]);
      }
    }
    if (candidates.length === 0) {
      this.toast(all.length > 0 ? '所有歌单都已加入首页' : '还没有歌单，先去歌单页创建或订阅 UP 投稿吧', 2000);
      return;
    }
    this.addCandidates = candidates;
    this.addCardPickerController?.open();
  }

  /** 选择器选中歌单：等效歌单页 ⋯ 菜单「加入首页」（HomeCardStore bump → 卡行重灌） */
  private addPlaylistToHome(p: Playlist): void {
    if (HomeCardStore.addHomePlaylist(p.id)) {
      this.toast('已加入首页', 1500);
    } else {
      this.toast('首页卡片已满', 1500);
    }
    this.addCardPickerController?.close();
  }

  /** 长按菜单「移出首页」（HomeQuickCards onRemoveCard 回调）：
   *  HomeCardStore 内部 bump STORE_LIBRARY_REV → 卡行自动重灌 */
  private removeHomeCard(p: Playlist): void {
    HomeCardStore.removeHomePlaylist(p.id);
    this.toast('已从首页移出', 1500);
  }

  /**
   * 长按菜单「更换歌单」：候选 = 未加入首页的歌单（onAddCardClick 同口径，
   * 含订阅歌单）。无候选给口令提示：有歌单但全在架 vs 一个歌单都没有，
   * 指路不同 —— 与「+」卡的提示语风一致。
   */
  private openReplaceCardPicker(p: Playlist): void {
    const all: Playlist[] = LibraryStore.getPlaylists();
    const candidates: Playlist[] = [];
    for (let i = 0; i < all.length; i++) {
      if (!HomeCardStore.isHomePlaylist(all[i].id)) {
        candidates.push(all[i]);
      }
    }
    if (candidates.length === 0) {
      this.toast(all.length > 0 ? '其他歌单都已加入首页'
        : '还没有可更换的歌单，先去歌单页创建或订阅吧', 2000);
      return;
    }
    this.replaceFromPlaylist = p;
    this.replaceCandidates = candidates;
    this.replaceCardPickerController?.open();
  }

  /** 更换选择器选中歌单：原位替换（卡片位置不变），HomeCardStore bump → 卡行重灌 */
  private replaceHomeCardWith(p: Playlist): void {
    const from: Playlist | null = this.replaceFromPlaylist;
    this.replaceCardPickerController?.close();
    if (from === null) {
      return;
    }
    if (HomeCardStore.replaceHomePlaylist(from.id, p.id)) {
      this.toast(`已更换为「${p.name}」`, 1600);
    } else {
      this.toast('更换失败，该歌单已在首页', 1600);
    }
  }

  aboutToAppear(): void {
    // 列表数据源初值同步（见 syncAllListSources 注释）
    this.syncAllListSources();
    // 列数初算（@StorageProp 初值同步不触发 @Watch）：窗口宽已在 AppStorage 时
    // 首帧即正确列数，不等首个变化事件。
    this.onColumnsChanged();
    this.normalizeTab();
    // 挂载即在网易云懒加载 tab（如进程重建后 STORE_SEARCH_TAB 仍为 netease /
    // ranking）：补拉
    this.maybeLoadHotChart();
    this.maybeLoadNetease();
    // 挂载前先存当前偏移对应的进度（updater 未挂载只存值，
    // 挂载时 initializeModifier 补上），防「已滚过再进页签」首帧缺模糊。
    this.syncTopBlurProgress();
    // 头部在场状态初始化：壳重挂（折叠开合）后列表必在顶部，直接置顶态
    this.entryActive = true;
    AppStorage.setOrCreate(STORE_HOME_SEARCH_ENTRY_ACTIVE, true);
    this.chipsActive = true;
    AppStorage.setOrCreate(STORE_HOME_CHIPS_ACTIVE, true);
    // 「保存合集为歌单」对话框：按钮走 buttons 槽（无校验失败需保持
    // 打开的路径，可用自动关闭），点遮罩关闭时只清暂存数据，关闭由系统完成。
    this.collectionSaverController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: '保存合集为歌单',
        contentBuilder: (): void => {
          this.SaverBody();
        },
        buttons: [
          {
            value: '取消',
            buttonStyle: ButtonStyleMode.TEXTUAL,
            action: (): void => {
              this.cancelSaveCollection();
            }
          },
          {
            value: '保存',
            buttonStyle: ButtonStyleMode.EMPHASIZED,
            action: (): void => {
              this.confirmSaveCollection();
            }
          }
        ]
      }),
      autoCancel: true,
      cancel: (): void => {
        this.cancelSaveCollection();
      }
    });
    // 「加入歌单」：官方标准对话框，标题/按钮常量（见成员声明处注释）。
    // 关闭路径（取消按钮 / 点遮罩 / 返回键）刻意不清暂存曲目：关闭有退场
    // 动画，清了会让副标题在淡出途中先变空；pickerTrack 每次打开前都会
    // 重写，残留值无消费方。
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
            }
          }
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    // 「添加歌单到首页」：同款官方标准对话框（候选列表 addCandidates
    // 在 onAddCardClick 里先定格再 open，无关闭时需要清理的暂存态）。
    this.addCardPickerController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: '添加歌单到首页',
        contentBuilder: (): void => {
          this.AddCardPickerBody();
        },
        buttons: [
          {
            value: '取消',
            buttonStyle: ButtonStyleMode.TEXTUAL,
            action: (): void => {
            }
          }
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    // 「更换首页歌单」：同款官方标准对话框（歌单卡长按菜单「更换歌单」入口，
    // 候选 / 原歌单在 openReplaceCardPicker 里先定格再 open）。
    this.replaceCardPickerController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: '更换首页歌单',
        contentBuilder: (): void => {
          this.ReplaceCardPickerBody();
        },
        buttons: [
          {
            value: '取消',
            buttonStyle: ButtonStyleMode.TEXTUAL,
            action: (): void => {
            }
          }
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.initHomeFeed();
    // 快捷卡行首灌：歌单冷启动读走预热（分片加载、每 N 片让出主线程一拍，
    // 防 THREAD_BLOCK_6S —— 主线程停摆时 3/6S 堆栈落在 libtimer.z.so 即此因），
    // 完成后本处 then 与 STORE_LIBRARY_REV bump 双路触发重灌（PlaylistsPage 首次 refresh 同款）
    LibraryStore.prewarmPlaylists().then((): void => {
      this.refreshQuickCards();
    });
    this.pageId = ++homePageInstanceSeq;
    console.info(`[Home] appear id=${this.pageId} bp=${this.currentBreakpoint}`);
    // 下拉刷新占位：ComponentContent 构造依赖 UIContext，属性初始化时还没就绪，
    // 只能在生命周期里建（工程内先例：PlayBar / CoverDiscComponent / LrcView 的 animator）。
    this.refreshPlaceholder =
      new ComponentContent<Object>(this.getUIContext(), wrapBuilder(PullRefreshPlaceholder));
  }

  /**
   * 按当前列表偏移校准自绘渐变模糊层进度：
   * yOffset 0 → TITLE_BLUR_END_VP 线性映射 0 → 1（updater 内截断，
   * 边缘回弹负偏移归零 = 死区）。onDidScroll 逐帧 + onScrollStop
   * Idle 校准终态都走这里（Fling 期只命令式写 opacity 不写 @State）。
   */
  private syncTopBlurProgress(): void {
    // currentOffset() 在 Scroller 尚未挂到 List（冷启动 aboutToAppear 早于 build）
    // 时运行时返回 undefined，空防护防启动崩溃（jscrash 实锤），未挂载按偏移 0。
    this.topBlurUpdater.setProgress(
      (TabScrollerHolder.home.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  /**
   * 头部在场状态同步：列表偏移跨越 HOME_ENTRY_FLIP_VP 时翻转
   * STORE_HOME_SEARCH_ENTRY_ACTIVE。只在翻转时写 AppStorage ——
   * onDidScroll 每帧回调，不翻转零开销。
   */
  private syncEntryActive(): void {
    const y: number = TabScrollerHolder.home.currentOffset()?.yOffset ?? 0;
    const active: boolean = y < HOME_ENTRY_FLIP_VP;
    if (active !== this.entryActive) {
      this.entryActive = active;
      AppStorage.setOrCreate(STORE_HOME_SEARCH_ENTRY_ACTIVE, active);
    }
  }

  /**
   * chip 条在场状态同步：列表偏移跨越 HOME_TABS_FLIP_VP（chip 条顶缘触及
   * 导航栏底）时翻转 STORE_HOME_CHIPS_ACTIVE。与 syncEntryActive 同构 ——
   * 只在翻转时写 AppStorage，onDidScroll 每帧回调不翻转零开销。
   */
  private syncChipsActive(): void {
    const y: number = TabScrollerHolder.home.currentOffset()?.yOffset ?? 0;
    const active: boolean = y < HOME_TABS_FLIP_VP;
    if (active !== this.chipsActive) {
      this.chipsActive = active;
      AppStorage.setOrCreate(STORE_HOME_CHIPS_ACTIVE, active);
    }
  }

  /**
   * 列表内容起始让位量（vp）：safeTop + 标题行 56 + 独立定值
   * （HOME_LIST_START_EXTRA_VP）。List 首个空白占位 / 骨架 / 空态读它 ——
   * 条目位置与根栏解耦，各自单独调。
   */
  private listStartOffset(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT + HOME_LIST_START_EXTRA_VP;
  }

  aboutToDisappear(): void {
    console.info(`[Home] disappear id=${this.pageId}`);
    if (this.pullFadeTimer !== -1) {
      clearTimeout(this.pullFadeTimer);
      this.pullFadeTimer = -1;
    }
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /**
   * 首屏数据。刻意拆成各自独立的任务：串行 await 后合并的话，任一源失败
   * （如缺 buvid 导致 rcmd 返回 412）会把另一个源已拿到的数据一起丢掉，
   * 表现为"首页一片空白"。
   *
   * revalidate=true（静默校验，启动缓存在场 / 网络恢复补拉时用）：
   * 不清现有列表 —— 用户继续看得到缓存内容，双源落定后 settleRecommend /
   * settleCenter 整表替换；全部失败时保留现有内容不动。
   * revalidate=false（默认）维持原行为：reset 清列表 → 骨架接管 → 成功替换。
   */
  private loadHomeData(revalidate: boolean = false): void {
    this.loadHomeRecommend(revalidate);
    this.loadCenter(revalidate);
  }

  /**
    * 启动数据入口（aboutToAppear 调，fire-and-forget）：
    *   1) 先读推荐 / 音乐中心启动缓存（本地 IO 毫秒级）——命中立即出内容、不闪骨架，
    *      网络不佳时用户看到的不再是 15 秒骨架屏；
    *   2) 完全离线：跳过 4 个注定各挂 15s 超时的请求，toast 提示后直接返回，
    *      等网络恢复信号（STORE_NET_RETRY_REV → onNetRetry）补拉；
    *   3) 在线：正常联网校验（缓存在场时静默校验、成功才替换并更新缓存）。
    * 两个 tab 顺序 await 即可 —— 单文件毫秒级，先于任何网络回调完成，无竞态。
    * 热歌榜 / 热门歌单是网易云第三方源，不进启动轮（懒加载见 maybeLoadHotChart /
    * maybeLoadNetease）。
    */
  private async initHomeFeed(): Promise<void> {
    const offline: boolean = !hasNetwork();
    const rec: HomeFeedCacheEntry | null = await getHomeFeedCache('recommend');
    const ctr: HomeFeedCacheEntry | null = await getHomeFeedCache('center');
    // 恢复：整体赋值 @State → onListSourceChanged 自动 reload 数据源；
    // 不碰 pending 标志 → homeLoading() 保持 false → 直接出内容、不闪骨架
    if (rec !== null) {
      // 恢复先归 raw 再按当前规则过滤：规则收紧时缓存条目正确滤除，
      // 放宽时原被滤条目即时回来（旧缓存本就未过滤，直接当 raw 用）
      this.recommendRaw = rec.tracks;
      this.refilterRecommend();
      this.cacheAppliedAny = true;
    }
    if (ctr !== null) {
      this.center = ctr.tracks;
      this.cacheAppliedAny = true;
    }
    this.homeFeedInitDone = true;
    if (offline) {
      this.offlineStartupSkipped = true;
      this.netPoorToastShown = true;
      this.toast(this.cacheAppliedAny ? '网络未连接，已为你展示缓存内容'
        : '网络未连接，请检查网络后重试', 2000);
      return;
    }
    this.startupRoundActive = true;
    this.startupDone = 0;
    this.startupFail = 0;
    // 无缓存时走原路径（reset → 骨架）；有缓存时静默校验（不清缓存内容）
    this.loadHomeData(this.cacheAppliedAny);
  }

  private resetRecommend(): void {
    this.recommend = [];
    this.recommendRaw = [];
    this.recommendFreshIdx = 1;
    this.recommendHasMore = true;
    // 先预置为 2（热门 + 推荐），避免首帧渲染时因计数为 0 闪一下"暂无数据"
    this.recommendPending = 2;
    this.recommendHotTracks = [];
    this.recommendFeedTracks = [];
  }

  private loadHomeRecommend(revalidate: boolean = false): void {
    if (revalidate) {
      // 静默校验：不清缓存内容（用户继续看得到），只重置分页状态与双源暂存
      this.recommendFreshIdx = 1;
      this.recommendHasMore = true;
      this.recommendPending = 2;
      this.recommendHotTracks = [];
      this.recommendFeedTracks = [];
    } else {
      this.resetRecommend();
    }
    this.loadPopular();
    this.loadRecommended();
  }

  private async loadPopular(): Promise<void> {
    try {
      const pop: PopularVideo[] = await BilibiliApi.getPopularVideos(10, 1);
      this.recommendHotTracks = pop.map(mapPopular);
    } catch (e) {
      console.error(`loadPopular failed: ${JSON.stringify(e)}`);
      this.noteStartupLoadFail();
    } finally {
      this.recommendPending = this.recommendPending - 1;
      this.settleRecommend();
      this.noteStartupSettled();
    }
  }

  private async loadRecommended(): Promise<void> {
    try {
      const rec: PopularVideo[] = await BilibiliApi.getRecommendedVideos(10);
      this.recommendFeedTracks = rec.map(mapPopular);
    } catch (e) {
      // 该接口在缺少 buvid Cookie 时会返回 HTTP 412；此处失败不影响同行热门数据
      console.error(`loadRecommended failed: ${JSON.stringify(e)}`);
      this.noteStartupLoadFail();
    } finally {
      this.recommendPending = this.recommendPending - 1;
      this.settleRecommend();
      this.noteStartupSettled();
    }
  }

  /**
   * 推荐位双源落定（settleCenter 同款）：pending 归零后按固定顺序合成整表替换。
   * 双源皆空 = 全部失败：保留现有内容（启动缓存 / 上一轮数据），不清不写 ——
   * 这是「网络不佳时缓存兜底」的关键守卫，防止联网失败把已恢复的缓存清掉。
   */
  private settleRecommend(): void {
    if (this.recommendPending > 0) {
      return;
    }
    if (this.recommendHotTracks.length === 0 && this.recommendFeedTracks.length === 0) {
      return;
    }
    this.recommendRaw = mergeTracks(this.recommendHotTracks, this.recommendFeedTracks);
    // 缓存落盘存 raw 全量（未过滤）：下次启动先归 raw 再按当前规则过滤，
    // 放宽规则时缓存里的条目能被重新救回，旧缓存本就未过滤、无需迁移。
    this.persistHomeFeedCache('recommend', this.recommendRaw);
    this.refilterRecommend();
    // 筛选开启且过滤后条目不足：静默自动补页（fire-and-forget）
    this.topUpRecommendIfNeeded();
  }

  /** 取编译产物：首次或 rev 变更后重编译（compileFeedFilter 带签名缓存） */
  private ensureFilterCompiled(): CompiledFeedFilter {
    if (this.feedFilterCompiled === null) {
      this.feedFilterCompiled = compileFeedFilter(getFeedFilterConfig());
    }
    return this.feedFilterCompiled;
  }

  /** 从 recommendRaw 重滤推荐展示列表（整表重赋值 → onListSourceChanged reload） */
  private refilterRecommend(): void {
    this.recommend = applyFeedFilter(this.recommendRaw, this.ensureFilterCompiled());
  }

  /** 筛选规则版本号变化（设置页保存 / 快捷屏蔽 / store 装载补发）：丢缓存重滤 */
  private onFeedFilterRevChanged(): void {
    this.feedFilterCompiled = null;
    this.refilterRecommend();
    // 规则收紧后列表可能骤减：筛选开启且不足时静默补页（规则全关时守卫自动短路）
    this.topUpRecommendIfNeeded();
  }

  /** 筛选当前是否生效（推荐位过滤空态的判定用） */
  private feedFilterActive(): boolean {
    return this.ensureFilterCompiled().active;
  }

  //
  // ── 网易云热歌榜（ranking tab）：第三方源，独立于启动轮 ──
  //

  /**
   * 拉取热歌榜全量并展示首页切片（首切 tab / 空态重试 / 下拉刷新共用）。
   * 开始即清展示列表 —— 原位骨架接管（列表内 chips 下方渲染，不清顶飞布局）；
   * 失败保留空列表 → 原位「暂无数据 + 点击重试」；hotChartLoadedOnce 只在
   * 成功时置位（失败后切走再切回自动重试）。
   */
  private async loadHotChart(): Promise<void> {
    if (this.loadingHotChart) {
      return;
    }
    this.loadingHotChart = true;
    this.hotSongs = [];
    try {
      const chart: NeteaseHotChart = await fetchNeteaseHotChart();
      this.hotChartAll = chart.songs;
      this.hotSongs = this.hotChartAll.slice(0, HOT_CHART_PAGE_SIZE);
      this.hotChartLoadedOnce = true;
    } catch (e) {
      console.error(`loadHotChart failed: ${JSON.stringify(e)}`);
    } finally {
      this.loadingHotChart = false;
    }
  }

  /** 下拉刷新：重拉全量榜单，从榜位 1 重新展示 */
  private async refreshHotChart(): Promise<void> {
    try {
      await this.loadHotChart();
    } finally {
      this.refreshing = false;
    }
  }

  /** 热歌榜上拉加载更多：全量已在内存，前端切片多放一屏，不发请求 */
  private revealMoreHotSongs(): void {
    const from: number = this.hotSongs.length;
    const next: number = Math.min(from + HOT_CHART_PAGE_SIZE, this.hotChartAll.length);
    for (let i = from; i < next; i++) {
      this.hotSongs.push(this.hotChartAll[i]);
    }
  }

  /**
   * 点榜单曲即播（NeteasePlaylistPage.playSongAt 同款，无连播链）：
   * 实时 B 站搜索匹配 → playNow（Track 带 bvid = BiliMusic 音源）。
   * 单飞互斥：匹配中再点直接忽略（防 B 站搜索风控）；行尾转圈反馈。
   */
  private async playHotSongAt(index: number): Promise<void> {
    if (this.matchingIndex >= 0 || this.loadingHotChart) {
      return;
    }
    if (index < 0 || index >= this.hotSongs.length) {
      return;
    }
    const song: NeteaseHotSong = this.hotSongs[index];
    const target: ExternalSong = {
      title: song.title,
      artist: song.artist,
      durationSec: song.durationSec
    };
    this.matchingIndex = index;
    try {
      const track = await matchSongForPlayback(target);
      if (track === null) {
        this.toast('没找到可播放的 B 站音源，可去搜索页手动找', 2600);
      } else {
        this.player.playNow(track);
      }
    } catch (e) {
      const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.error(`hot chart play match failed: ${detail}`);
      this.toast('匹配失败，请稍后再试', 2200);
    } finally {
      this.matchingIndex = -1;
    }
  }

  private resetCenter(): void {
    this.center = [];
    this.centerPage = 1;
    this.centerHasMore = true;
    this.centerPending = 2;
    this.centerNewTracks = [];
    this.centerHotTracks = [];
  }

  /** 两个数据源各自独立：串行 await 后合并会把已成功那份一起丢掉。 */
  private loadCenter(revalidate: boolean = false): void {
    if (revalidate) {
      // 静默校验：不清缓存内容（用户继续看得到），只重置分页状态与双源暂存
      this.centerPage = 1;
      this.centerHasMore = true;
      this.centerPending = 2;
      this.centerNewTracks = [];
      this.centerHotTracks = [];
    } else {
      this.resetCenter();
    }
    this.loadCenterRank();
    this.loadCenterNew();
  }

  /**
   * 双源落定（成功或失败都算）后按**固定顺序**合成首屏：新歌榜（最新发布）在前、
   * 热歌榜随后。竞速合并（各自到达即追加）会让热歌榜一页 20 条先返回，
   * 最新发布的歌被压到中后段 —— 用户看到的就是「音乐中心都是老歌，不是最新的」；
   * 缓冲到双双落定再一次性合成，展示顺序不受网络先后影响。上拉加载更多追加在
   * 合成结果的尾部（见 loadMoreCenter），新歌置顶的顺序不被破坏。
   */
  private settleCenter(): void {
    if (this.centerPending > 0) {
      return;
    }
    // 双源皆空 = 全部失败：保留现有内容（启动缓存 / 上一轮数据），不清不写 ——
    // 防止联网失败把已恢复的缓存清掉（缓存兜底的关键守卫，settleRecommend 同款）
    if (this.centerNewTracks.length === 0 && this.centerHotTracks.length === 0) {
      return;
    }
    this.center = mergeTracks(this.centerNewTracks, this.centerHotTracks);
    this.persistHomeFeedCache('center', this.center);
  }

  private async loadCenterRank(): Promise<void> {
    try {
      const hot: MusicCenterItem[] = await BilibiliApi.getMusicComprehensiveRank(CENTER_PAGE_SIZE, 1);
      this.centerHotTracks = mapMusicCenterList(hot);
    } catch (e) {
      console.error(`loadCenterRank failed: ${JSON.stringify(e)}`);
      this.noteStartupLoadFail();
    } finally {
      this.centerPending = this.centerPending - 1;
      this.settleCenter();
      this.noteStartupSettled();
    }
  }

  private async loadCenterNew(): Promise<void> {
    try {
      const fresh: MusicCenterItem[] = await BilibiliApi.getNewMusic();
      this.centerNewTracks = mapMusicCenterList(fresh);
    } catch (e) {
      console.error(`loadCenterNew failed: ${JSON.stringify(e)}`);
      this.noteStartupLoadFail();
    } finally {
      this.centerPending = this.centerPending - 1;
      this.settleCenter();
      this.noteStartupSettled();
    }
  }

  private currentListLength(): number {
    if (this.tab === 'recommend') {
      return this.recommend.length;
    }
    if (this.tab === 'ranking') {
      return this.hotSongs.length;
    }
    if (this.tab === 'netease') {
      return this.neteasePlaylists.length;
    }
    return this.center.length;
  }

  private homeLoading(): boolean {
    if (this.tab === 'recommend') {
      return this.recommendPending > 0;
    }
    if (this.tab === 'ranking') {
      return this.loadingHotChart;
    }
    if (this.tab === 'center') {
      return this.centerPending > 0;
    }
    if (this.tab === 'netease') {
      return this.loadingNetease;
    }
    return false;
  }

  /**
    * 当前 tab 还有没有下一页。
    * 各源分页能力不同，所以判据也不同（详见文件头的说明）。
    */
  private hasMore(): boolean {
    if (this.tab === 'recommend') {
      return this.recommend.length > 0 && this.recommendHasMore;
    }
    if (this.tab === 'ranking') {
      // 热歌榜全量已经在内存里，没放完就还有
      return this.hotSongs.length > 0 && this.hotSongs.length < this.hotChartAll.length;
    }
    if (this.tab === 'center') {
      return this.center.length > 0 && this.centerHasMore;
    }
    if (this.tab === 'netease') {
      return this.neteasePlaylists.length > 0 && this.neteaseHasMore;
    }
    return false;
  }

  /** 空态里的「点击重试」：只重载当前 tab，不要把几个源都刷一遍 */
  private reloadCurrentTab(): void {
    if (this.tab === 'recommend') {
      this.loadHomeRecommend();
    } else if (this.tab === 'ranking') {
      this.loadHotChart();
    } else if (this.tab === 'netease') {
      this.loadNeteaseFirstPage();
    } else {
      this.loadCenter();
    }
  }

  /**
   * 网络恢复自动重试（Index 发信号）：
   *   · 空态场景（原行为）：tab 加载失败后停在「暂无数据」—— 只重载当前 tab；
   *   · 缓存兜底场景（新增）：缓存在场 / 启动时离线跳过了联网 —— 静默校验
   *     三源（loadHomeData(true)，成功即替换并更新缓存），覆盖「启动即离线，
   *     netLost 从未触发，恢复后必须有人补拉」的盲区。
   */
  private onNetRetry(): void {
    // initHomeFeed 未跑完时信号先到（如「注册瞬间的 available」）：缓存还在读，
    // 不抢跑 —— 否则会和 initHomeFeed 的联网分支双拉同一批请求。
    if (!this.homeFeedInitDone) {
      return;
    }
    if (this.homeLoading()) {
      return;
    }
    if (this.currentListLength() === 0) {
      this.reloadCurrentTab();
      return;
    }
    if (this.cacheAppliedAny || this.offlineStartupSkipped) {
      this.loadHomeData(true);
    }
  }

  /**
   * 启动缓存落盘（fire-and-forget）：失败只打日志 —— 落盘失败只影响
   * 「下次启动有没有缓存」，本次会话的展示不受影响（HomeCardStore 同款取舍）。
   */
  private persistHomeFeedCache(tab: string, tracks: Track[]): void {
    if (tracks.length === 0) {
      return;
    }
    saveHomeFeedCache(tab, tracks).catch((e: Error): void => {
      console.error(`save home feed cache failed (${tab}): ${e.message}`);
    });
  }

  /**
    * 启动轮单个请求失败上报（4 个首屏请求的 catch 各调一次）：
    * 已恢复缓存 + 首个失败 → 立即 toast「网络不佳」（比等 4 个请求全部落定
    * 快得多，弱网下用户能尽早知道内容是缓存兜底的）；toast 只弹一次。
    */
  private noteStartupLoadFail(): void {
    if (this.cacheAppliedAny && !this.netPoorToastShown) {
      this.netPoorToastShown = true;
      this.toast('网络不佳，已为你展示缓存内容', 2000);
    }
    if (this.startupRoundActive) {
      this.startupFail++;
    }
  }

  /**
    * 启动轮单个请求落定（成功 / 失败都算，4 个首屏请求的 finally 各调一次）。
    * 4 个全部落定后收口：无缓存且全部失败 → 补一条弱网提示
    * （原先是静默空态，用户毫无感知，正是「像卡死一样」的来源之一）。
    * 下拉刷新 / 重试复用同一批加载函数时 startupRoundActive 已为 false，自动跳过。
    */
  private noteStartupSettled(): void {
    if (!this.startupRoundActive) {
      return;
    }
    this.startupDone++;
    if (this.startupDone >= 4) {
      this.startupRoundActive = false;
      if (this.startupFail >= 4 && !this.cacheAppliedAny && !this.netPoorToastShown) {
        this.netPoorToastShown = true;
        this.toast('网络不佳，请检查网络后重试', 2000);
      }
    }
  }

  private handleRefresh(): void {
    if (this.tab === 'recommend') {
      this.refreshRecommend();
    } else if (this.tab === 'ranking') {
      this.refreshHotChart();
    } else if (this.tab === 'netease') {
      this.refreshNetease();
    } else {
      this.refreshCenter();
    }
  }

  private async refreshRecommend(): Promise<void> {
    this.resetRecommend();
    try {
      await this.loadPopular();
      await this.loadRecommended();
    } finally {
      this.refreshing = false;
    }
  }

  private async refreshCenter(): Promise<void> {
    this.resetCenter();
    try {
      await this.loadCenterRank();
      await this.loadCenterNew();
    } finally {
      this.refreshing = false;
    }
  }

  /**
   * 下拉刷新头状态机（骨架接管），RefreshStatus 五态收口：
   *   · Drag / OverDrag —— 双骨架闸门：列表非空才挂刷新头骨架；recommend/center
   *     首屏加载中（整屏骨架在场、列表为空）时不再叠一条。若上一次 Done 的淡出
   *     还没跑完（快速连拉），先掐掉定时器并用 0 时长动画顶掉在途淡出 ——
   *     否则旧动画继续接管 opacity/translate，跟手映射全部失效。
    *   · Refresh —— recommend/center 的刷新会先清空列表（resetRecommend /
    *     resetCenter），整屏骨架随即接管，刷新头骨架必须在这里先撤，否则
    *     「顶部一条 + 下面一整屏」；netease/ranking 懒加载页签的刷新同样
    *     清列表（骨架在列表内原位渲染），刷新头骨架也一并撤掉
    *     （骨架纯静态，不另加旋转/脉冲/进度环）。
   *   · Done —— 250ms 淡出上移；淡出**结束后**再摘节点（直接摘节点淡出
   *     根本看不到），句柄由 aboutToDisappear 兜底回收。
   *   · Inactive —— 未触发刷新的回弹复位；Done 淡出在途时交给定时器收尾。
   */
  private onRefreshStateChange(status: RefreshStatus): void {
    if (status === RefreshStatus.Drag || status === RefreshStatus.OverDrag) {
      if (this.pullFadeTimer !== -1) {
        clearTimeout(this.pullFadeTimer);
        this.pullFadeTimer = -1;
        this.getUIContext().animateTo({ duration: 0 }, (): void => {
          this.pullSkelOpacity = 0;
          this.pullSkelOffsetY = PULL_SKELETON_SETTLE_VP;
        });
      }
      this.showPullSkeleton = this.currentListLength() > 0;
    } else if (status === RefreshStatus.Refresh) {
      if (this.tab === 'recommend' || this.tab === 'center' || this.tab === 'netease' || this.tab === 'ranking') {
        this.showPullSkeleton = false;
      }
    } else if (status === RefreshStatus.Done) {
      this.dismissPullSkeleton();
    } else if (status === RefreshStatus.Inactive) {
      if (this.pullFadeTimer === -1) {
        this.showPullSkeleton = false;
        this.pullSkelOpacity = 0;
        this.pullSkelOffsetY = PULL_SKELETON_SETTLE_VP;
      }
    }
  }

  /** Done 收尾：骨架淡出上移，动画放完再摘节点（句柄回收照 PlayButtonComponent 模式） */
  private dismissPullSkeleton(): void {
    if (!this.showPullSkeleton) {
      return;
    }
    this.getUIContext().animateTo(
      { duration: PULL_SKELETON_FADE_MS, curve: Curve.EaseOut },
      (): void => {
        this.pullSkelOpacity = 0;
        this.pullSkelOffsetY = PULL_SKELETON_EXIT_VP;
      }
    );
    if (this.pullFadeTimer !== -1) {
      clearTimeout(this.pullFadeTimer);
    }
    this.pullFadeTimer = setTimeout((): void => {
      this.pullFadeTimer = -1;
      this.showPullSkeleton = false;
    }, PULL_SKELETON_FADE_MS);
  }

  /**
   * List 的 onReachEnd。
   * 三重闸门：正在刷新 / 正在加载更多 / 首屏加载中，任一命中都直接返回，
   * 否则短列表在首帧布局时就会连环触发，一口气把后面几页全拉下来。
   */
  private onReachEnd(): void {
    if (this.refreshing || this.loadingMore) {
      return;
    }
    if (this.homeLoading()) {
      return;
    }
    if (!this.hasMore()) {
      return;
    }
    this.loadMore();
  }

  private loadMore(): void {
    if (this.tab === 'recommend') {
      this.loadMoreRecommend();
    } else if (this.tab === 'ranking') {
      this.revealMoreHotSongs();
    } else if (this.tab === 'netease') {
      this.loadNeteaseMore();
    } else {
      this.loadMoreCenter();
    }
  }

  private async loadMoreRecommend(silent: boolean = false): Promise<void> {
    this.loadingMore = true;
    try {
      const idx: number = this.recommendFreshIdx + 1;
      const feed: PopularVideo[] = await BilibiliApi.getRecommendedFeed(idx, RECOMMEND_FEED_PS);
      this.recommendFreshIdx = idx;
      const rawBefore: number = this.recommendRaw.length;
      // 按 id 去重后增量 push 进 raw（去重 / hasMore 都基于 raw 而非展示数组，
      // 否则整页被筛选滤光会被误判成「到底」）：推荐流翻页常回捞已出现过的视频。
      const seen: Set<string> = new Set<string>();
      for (let i = 0; i < this.recommendRaw.length; i++) {
        seen.add(this.recommendRaw[i].id);
      }
      for (let i = 0; i < feed.length; i++) {
        const t: Track = mapPopular(feed[i]);
        if (!seen.has(t.id)) {
          seen.add(t.id);
          this.recommendRaw.push(t);
        }
      }
      this.refilterRecommend();
      if (feed.length === 0) {
        this.recommendHasMore = false;
      } else if (this.recommendRaw.length === rawBefore) {
        // 整整一页都是已看过的内容：继续翻只会原地打转，直接收口
        this.recommendHasMore = false;
      }
    } catch (e) {
      console.error(`loadMoreRecommend failed: ${JSON.stringify(e)}`);
      // silent=true（自动补页）静默失败，不打扰用户；手动上拉才 toast
      if (!silent) {
        this.toast('加载更多失败，请稍后重试', 1800);
      }
    } finally {
      this.loadingMore = false;
    }
  }

  /** 自动补页在途标志（非 @State：纯逻辑防重入，不驱动 UI） */
  private recommendTopUpActive: boolean = false;

  /**
   * 自动补页（仅首页筛选开启时触发）：推荐列表落定后过滤展示 < 目标条数时，
   * 静默续拉推荐流翻页（fresh_idx 顺延，与手动上拉同一通道）直到达标 /
   * 无更多页 / 轮数上限。失败静默退出（用户可手动上拉重试）；
   * 筛选关闭时不做任何补页，行为与无此机制时完全一致。
   */
  private async topUpRecommendIfNeeded(): Promise<void> {
    // 第一道守卫：仅首页筛选开启时才自动补页
    if (!this.feedFilterActive()) {
      return;
    }
    if (this.recommendTopUpActive || this.recommendPending > 0) {
      return;
    }
    if (this.recommend.length >= RECOMMEND_TOPUP_TARGET || !this.recommendHasMore) {
      return;
    }
    this.recommendTopUpActive = true;
    try {
      for (let round: number = 0; round < RECOMMEND_TOPUP_MAX_ROUNDS; round++) {
        if (this.recommend.length >= RECOMMEND_TOPUP_TARGET || !this.recommendHasMore) {
          break;
        }
        // 新一轮加载已开跑（下拉刷新 / 重载会同步置 pending=2 并清 raw）：
        // raw 即将被整表替换并重置 freshIdx，停止续拉（JS 单线程下 await
        // 恢复点必能观察到 pending 变化，无需另查 refreshing —— 刷新落定时
        // settle 先于 refreshing 复位发生，查它反而会误杀刷新后的补页）
        if (this.recommendPending > 0) {
          break;
        }
        if (!hasNetwork()) {
          break;
        }
        await this.loadMoreRecommend(true);
      }
      // 补页追加进了 raw：落盘让下次启动缓存更充足（fire-and-forget，同 settle 口径）
      this.persistHomeFeedCache('recommend', this.recommendRaw);
    } finally {
      this.recommendTopUpActive = false;
    }
  }

  private async loadMoreCenter(): Promise<void> {
    this.loadingMore = true;
    try {
      const next: number = this.centerPage + 1;
      const list: MusicCenterItem[] =
        await BilibiliApi.getMusicComprehensiveRank(CENTER_PAGE_SIZE, next);
      const before: number = this.center.length;
      // 按 id 去重后增量 push（分页可能跨页重复）。
      const fresh: Track[] = mapMusicCenterList(list);
      const seen: Set<string> = new Set<string>();
      for (let i = 0; i < this.center.length; i++) {
        seen.add(this.center[i].id);
      }
      for (let i = 0; i < fresh.length; i++) {
        const t: Track = fresh[i];
        if (!seen.has(t.id)) {
          seen.add(t.id);
          this.center.push(t);
        }
      }
      this.centerPage = next;
      if (list.length === 0 || this.center.length === before) {
        this.centerHasMore = false;
      }
    } catch (e) {
      console.error(`loadMoreCenter failed: ${JSON.stringify(e)}`);
      this.toast('加载更多失败，请稍后重试', 1800);
    } finally {
      this.loadingMore = false;
    }
  }

  // ── 网易云热门歌单（netease tab）：第三方源，独立于启动三源轮 ──

  private async refreshNetease(): Promise<void> {
    // 换一批：榜单前 NETEASE_REFRESH_RANDOM_PAGES 页内随机跳一页（排除第 0 页，
    // 保证每次下拉都是新一批）。游标从该页继续，上拉加载往后翻。
    const page: number = 1 + Math.floor(Math.random() * (NETEASE_REFRESH_RANDOM_PAGES - 1));
    try {
      await this.loadNeteaseFirstPage(page * NETEASE_PAGE_SIZE);
    } finally {
      this.refreshing = false;
    }
  }

  private resetNetease(): void {
    this.neteasePlaylists = [];
    this.neteaseOffset = 0;
    this.neteaseHasMore = true;
  }

  /**
   * 热门歌单首页（首次切 tab / 下拉刷新 / 空态重试共用）。
   * @param startOffset 起始游标：0 = 榜单第一页（首切/重试）；
   *   下拉刷新传随机页游标实现「换一批」，随机页越界返回空时兜底回第一页。
   * 失败清空列表 → 列表内原位「暂无数据 + 点击重试」（见 netease 分支）；
   * neteaseLoadedOnce 只在成功时置位（失败后切走再切回自动重试）。
   */
  private async loadNeteaseFirstPage(startOffset: number = 0): Promise<void> {
    if (this.loadingNetease) {
      return;
    }
    this.loadingNetease = true;
    this.resetNetease();
    try {
      let usedOffset: number = startOffset;
      let result: NeteaseHotPlaylistsResult =
        await fetchNeteaseHotPlaylists(NETEASE_PAGE_SIZE, usedOffset);
      if (startOffset > 0 && result.playlists.length === 0) {
        // 随机页越界/空：兜底回第一页，别让用户刷出空列表
        usedOffset = 0;
        result = await fetchNeteaseHotPlaylists(NETEASE_PAGE_SIZE, 0);
      }
      this.neteasePlaylists = result.playlists;
      this.neteaseOffset = usedOffset + result.playlists.length;
      this.neteaseHasMore = result.hasMore;
      this.neteaseLoadedOnce = true;
    } catch (e) {
      console.error(`loadNeteaseFirstPage failed: ${JSON.stringify(e)}`);
    } finally {
      this.loadingNetease = false;
    }
  }

  /** 热门歌单上拉加载更多（offset 游标翻页；整页去重后无新增即收口） */
  private async loadNeteaseMore(): Promise<void> {
    this.loadingMore = true;
    try {
      const result: NeteaseHotPlaylistsResult =
        await fetchNeteaseHotPlaylists(NETEASE_PAGE_SIZE, this.neteaseOffset);
      // 按 id 去重后增量合并（接口翻页偶发跨页重复，loadMoreCenter 同款防御）
      const seen: Set<string> = new Set<string>();
      for (let i = 0; i < this.neteasePlaylists.length; i++) {
        seen.add(this.neteasePlaylists[i].id);
      }
      const fresh: NeteasePlaylistSummary[] = [];
      for (let i = 0; i < result.playlists.length; i++) {
        const p: NeteasePlaylistSummary = result.playlists[i];
        if (!seen.has(p.id)) {
          seen.add(p.id);
          fresh.push(p);
        }
      }
      if (fresh.length > 0) {
        this.neteasePlaylists = this.neteasePlaylists.concat(fresh);
        // 游标按接口原始条数推进（去重是客户端口径，不能吃掉游标步长）
        this.neteaseOffset += result.playlists.length;
        this.neteaseHasMore = result.hasMore;
      } else {
        this.neteaseHasMore = false;
      }
    } catch (e) {
      console.error(`loadNeteaseMore failed: ${JSON.stringify(e)}`);
      this.toast('加载更多失败，请稍后重试', 1800);
    } finally {
      this.loadingMore = false;
    }
  }

  /**
    * 加载中 / 空数据的统一展示区（B 站两个页签的冷启动专用）。
    * 加载中：骨架屏（形状贴合 TrackItem 的 40 圆头像 + 两条文字条，纯静态占位），
    * 占位形状对齐内容布局，加载完成内容「落位」不跳。
    * 网易云页签（netease / ranking）不走这里：本区位于 Refresh 之前（列表上方），
    * 会话中切入懒加载页签时若在此插入整屏骨架，会把搜索框/快捷卡/chips 整体
    * 顶出屏幕、数据落地再弹回（用户感知「闪屏」）；其骨架/空态改为列表内
    * chips 下方原位渲染。
    */
  @Builder
  HomeStateArea(): void {
    if (this.tab !== 'netease' && this.tab !== 'ranking' && this.homeLoading() && this.currentListLength() === 0) {
      this.SkeletonArea()
    } else if (this.tab !== 'netease' && this.tab !== 'ranking' && !this.homeLoading() && this.currentListLength() === 0) {
      // 推荐位被筛选滤成空（raw 有内容、展示为 0）：提示 + 直达「首页筛选」设置页
      if (this.tab === 'recommend' && this.recommendRaw.length > 0 && this.feedFilterActive()) {
        Column() {
          Text('当前筛选条件过滤了全部内容')
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
          Button('调整筛选', { type: ButtonType.Normal })
            .fontSize(13)
            .borderRadius(BUTTON_RADIUS_VP)
            .margin({ top: 12 })
            .onClick((): void => {
              NavStackHolder.push('HomeFeedFilter', undefined);
            })
        }
        .margin({ top: this.listStartOffset() + 48 })
      } else {
        Column() {
          Text('暂无数据')
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
          Button('点击重试', { type: ButtonType.Normal })
            .fontSize(13)
            .borderRadius(BUTTON_RADIUS_VP)
            .margin({ top: 12 })
            .onClick((): void => {
              this.reloadCurrentTab();
            })
        }
        .margin({ top: this.listStartOffset() + 48 })
      }
    }
  }

  /**
    * 骨架屏区（首屏加载）：8 行贴内容形状的占位。
    * 行数取首屏可见量即可——多出来的行用户看不见，纯浪费渲染（每行自带 shimmer 动画）。
    */
  @Builder
  SkeletonArea(): void {
    Column() {
      ForEach(SKELETON_ROW_INDEXES, (_i: number): void => {
        SkeletonTrackItem({ index: _i })
      }, (_i: number): string => `sk_${_i}`)
    }
    .width('100%')
    // 内容列不再整体 padding top（列表穿透需要），骨架区自己补内容起始让位
    .padding({ top: this.listStartOffset() })
  }

  /**
    * 热歌榜单曲行（ranking tab）：榜位序号 + 封面 + 歌名 /「歌手 · 时长」副行，
    * 整行点按即播（playHotSongAt 实时匹配 B 站音源）；匹配中的行行尾转圈。
    * 版式参照 NeteasePlaylistPage 曲目行，加封面与前三名高亮。
    */
  @Builder
  HotSongRow(song: NeteaseHotSong, index: number): void {
    Row({ space: 12 }) {
      Text(`${index + 1}`)
        .fontSize(13)
        .fontColor(index < 3 ? this.themeDeep : $r('app.color.text_tertiary'))
        .width(24)
        .textAlign(TextAlign.Center)
      CoverImage({
        url: toThumbUrl(song.coverUrl, 96),
        imgWidth: 48,
        imgHeight: 48,
        imgRadius: 8,
        altText: song.title
      })
      Column() {
        Text(song.title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${song.artist} · ${formatDurationText(song.durationSec)}`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 行尾不放常驻播放键（整行点按即播）：仅匹配中的行在行尾给转圈反馈
      if (this.matchingIndex === index) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color(this.themeDeep)
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .onClick((): void => {
      this.playHotSongAt(index);
    })
  }

  /**
   * 入口式搜索框：只承载「点进去搜」的意图 —— 真实输入 / 历史 / 结果全在 'Search' 二级页
   * （push 后输入框自动聚焦）。样式与二级页 Search 输入框同语言
   * （放大镜 + 占位文案 + 圆角胶囊），用户不会感知这是两个组件。
   */
  @Builder
  SearchEntryRow(): void {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(18)
        .height(18)
        .fontColor([$r('app.color.text_secondary')])
      Text('搜索歌曲、歌单、UP主')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .layoutWeight(1)
    }
    .width('100%')
    .height(44)
    .padding({ left: 16, right: 16 })
    .borderRadius(22)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 0.5, color: $r('app.color.bg_divider') })
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 12 })
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor($r('app.color.bg_card')) }
    })
    .onClick((): void => {
      NavStackHolder.push('Search', undefined);
    })
  }

  /** 「⋯」标准菜单项（bindMenu + MenuElement 数组） */
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
        value: '加入歌单',
        action: (): void => {
          this.openPlaylistPicker(track);
        }
      },
      {
        value: '保存合集为歌单',
        action: (): void => {
          this.loadCollection(track);
        }
      },
      {
        value: '下载',
        action: (): void => {
          this.startDownload(track);
        }
      },
      {
        value: '进入 UP 主主页',
        action: (): void => {
          this.openUpSpace(track);
        }
      },
      {
        value: isTrackUpBlocked(track, this.ensureFilterCompiled()) ? '取消屏蔽此 UP' : '屏蔽此 UP',
        action: (): void => {
          this.toggleQuickBlockUp(track);
        }
      },
      {
        value: '屏蔽标题关键词',
        action: (): void => {
          this.openQuickTitleBlock(track);
        }
      }
    ];
  }

  /**
   * 「⋯」菜单快捷屏蔽 / 取消屏蔽 UP：写规则 → bump rev → 本页 @Watch 重滤，
   * 全程纯客户端操作。三个 tab 的菜单都带此入口（排行榜 / 音乐中心里看到
   * 不想再刷到的 UP 顺手屏蔽），生效范围是推荐 tab。
   */
  private toggleQuickBlockUp(track: Track): void {
    const compiled: CompiledFeedFilter = this.ensureFilterCompiled();
    if (isTrackUpBlocked(track, compiled)) {
      const mid: string = track.upMid ?? '';
      const nameNorm: string = normalizeFilterText(track.artist ?? '');
      const cfg: FeedFilterConfig = getFeedFilterConfig();
      const rest: FeedUpEntry[] = [];
      for (let i = 0; i < cfg.blockUps.length; i++) {
        const e: FeedUpEntry = cfg.blockUps[i];
        const hit: boolean = (mid.length > 0 && e.mid === mid)
          || (nameNorm.length > 0 && normalizeFilterText(e.name) === nameNorm);
        if (!hit) {
          rest.push(e);
        }
      }
      cfg.blockUps = rest;
      updateFeedFilterConfig(cfg);
      this.toast('已取消屏蔽，推荐页将重新出现该 UP', 1800);
      return;
    }
    const mid: string = track.upMid ?? '';
    const name: string = track.artist ?? '';
    if (mid.length === 0 && name.length === 0) {
      this.toast('这条没有 UP 主信息', 1500);
      return;
    }
    const cfg: FeedFilterConfig = getFeedFilterConfig();
    cfg.blockUps.push({ mid: mid, name: name });
    cfg.enabled = true;
    updateFeedFilterConfig(cfg);
    this.toast(`已在首页推荐中屏蔽「${name.length > 0 ? name : mid}」`, 1800);
  }

  /**
   * 快捷「屏蔽标题关键词」：弹输入对话框，预填完整标题（用户改短成关键词）。
   * 确认写 blockTitleKeywords → bump rev 重滤；支持 /正则/ 形式（引擎分流）。
   * controller 每次打开重建（播放音质弹窗同款：CustomDialog 参数不支持动态刷新）。
   */
  private openQuickTitleBlock(track: Track): void {
    this.quickTitleBlockTrack = track;
    this.quickBlockKeyword = track.title;
    const dialog: CustomDialogController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: '屏蔽标题关键词',
        secondaryTitle: '含该关键词的标题将从首页推荐中滤除；也可改成 /正则/ 形式',
        contentBuilder: (): void => {
          this.QuickTitleBlockBody();
        },
        buttons: [
          {
            value: '取消',
            buttonStyle: ButtonStyleMode.TEXTUAL,
            action: (): void => {
              this.quickTitleBlockDialog?.close();
            }
          },
          {
            value: '屏蔽',
            buttonStyle: ButtonStyleMode.EMPHASIZED,
            action: (): void => {
              this.confirmQuickTitleBlock();
            }
          }
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.quickTitleBlockDialog = dialog;
    dialog.open();
  }

  /** 对话框「屏蔽」：写入标题屏蔽词（至少 2 字符防单字误杀过宽；重复词幂等） */
  private confirmQuickTitleBlock(): void {
    if (this.quickTitleBlockTrack === null) {
      return;
    }
    const kw: string = this.quickBlockKeyword.trim();
    if (kw.length < 2) {
      this.toast('关键词至少 2 个字符，避免过滤范围过宽', 1800);
      return;
    }
    this.quickTitleBlockDialog?.close();
    const cfg: FeedFilterConfig = getFeedFilterConfig();
    if (cfg.blockTitleKeywords.indexOf(kw) < 0) {
      cfg.blockTitleKeywords.push(kw);
    }
    cfg.enabled = true;
    updateFeedFilterConfig(cfg);
    this.toast('已在首页推荐中屏蔽该标题关键词', 1800);
  }

  /** 「屏蔽标题关键词」对话框内容区：说明文案走 secondaryTitle，正文只留预填输入 */
  @Builder
  QuickTitleBlockBody(): void {
    TextInput({ placeholder: '输入标题关键词', text: this.quickBlockKeyword })
      .width('100%')
      .height(40)
      .fontSize(16)
      .onChange((v: string): void => {
        this.quickBlockKeyword = v;
      })
  }

  /**
   * 「进入 UP 主主页」→ 站内页（UpSpacePage）。
   *
   * mid 有两条来源：
   *  1. 列表映射时已落下来的（排行榜 / 推荐流都有 owner.mid）—— 直接用，零请求；
   *  2. 音乐中心、已下载曲目这类结构里没有 mid 的 → 用 bvid 走 `getVideoDetail` 换
   *     `owner.mid`。该接口带 viewCache（TTL 内），同一首反复点不会重复发请求。
   */
  private async openUpSpace(track: Track): Promise<void> {
    // ⚠️ `?? ''` 不能省：旧版本落盘的曲目（已下载 / 收藏 / 最近播放）没有 upMid 字段，
    // 运行时读出来是 undefined，直接读 `.length` 会崩。
    let mid: string = track.upMid ?? '';
    if (mid.length === 0) {
      const bvid: string = track.bvid.length > 0 ? track.bvid : track.id;
      if (bvid.indexOf('BV') !== 0) {
        this.toast('这条没有 UP 主信息', 1500);
        return;
      }
      this.toast('正在获取投稿作者…', 1200);
      try {
        const detail: VideoDetail = await BilibiliApi.getVideoDetail(bvid);
        mid = detail.owner ? String(detail.owner.mid) : '';
      } catch (e) {
        console.error(`openUpSpace resolve mid failed: ${JSON.stringify(e)}`);
        mid = '';
      }
      if (mid.length === 0) {
        this.toast('获取 UP 主失败', 1500);
        return;
      }
    }
    // 头像没有现成数据可传（曲目行不带 UP 头像）：传空串占位，
    // UpSpacePage 用 CoverImage 兜占位图，loadCard 拿到真图后覆盖
    NavStackHolder.stack.pushPathByName('UpSpace', new UpSpaceRouteParam(mid, track.artist, ''));
  }

  private startDownload(track: Track): void {
    this.requestDownload(track, false);
  }

  /**
   * 发起下载。
   *
   * 分 P 合集会在内核里被展开成多条任务（见 DownloadManager.requestDownload），
   * 所以这里不能再用「true/false」表达结果 —— 得把「排上几首 / 跳过几首」都告诉用户。
   *
   * @param ignoreWifiLimit 用户在「仅 WiFi 下载」的询问里选了「继续下载」时为 true
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

  /**
   * 「仅 WiFi 下载」被触发：先问一句，而不是直接拒绝。
   *
   * 开这个开关的人多半是「不想偷跑流量」，不是「绝对不许用流量」。一律拦死的话，
   * 用户在外面想下一首歌就得先去设置里关开关 —— 多加一步，还未必想得起来。
   */
  private confirmDownloadOnCellular(track: Track): void {
    showConfirm(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: `${WIFI_ONLY_BLOCKED}\n当前网络：${currentNetworkLabel()}`,
      confirmText: '继续下载',
      onConfirm: (): void => {
        this.requestDownload(track, true);
      }
    });
  }

  /**
   * 把歌曲加入指定歌单。
   *
   * 一个歌单都没有时**自动建一个再放进去**：让用户先跳页建单、再回来重新找到
   * 这首是纯粹的摩擦，行为是「点加入歌单 → 自动创建歌单并加入」。
   */
  private openPlaylistPicker(track: Track): void {
    const options: Playlist[] = LibraryStore.getAddablePlaylists();
    if (options.length === 0) {
      // 复用本次已读到的列表（此处为空），不再让下游二次读库
      this.createPlaylistAndAdd(track, options);
      return;
    }
    this.playlistOptions = options;
    this.pickerTrack = track;
    this.playlistPickerController?.open();
  }

  /** 没有任何歌单时的兜底：新建歌单并直接把这首放进去（名字取自歌名） */
  private createPlaylistAndAdd(track: Track, existing: Playlist[]): void {
    const name: string = LibraryStore.nextPlaylistNameForTrack(track, existing);
    const created: Playlist = LibraryStore.createPlaylist({ name: name });
    const updated: Playlist | null = LibraryStore.addTrackToPlaylist(created.id, track);
    this.toast(updated ? `已新建歌单「${name}」并加入` : '加入歌单失败', 1800);
  }

  /** 弹层里的「新建歌单并加入」：同样省掉一次跳转 */
  private createPlaylistFromPicker(): void {
    const track: Track | null = this.pickerTrack;
    this.playlistPickerController?.close();
    if (!track) {
      return;
    }
    // 弹层打开时的快照（playlistOptions）就是用户看到的列表，重名检查基于它即可
    this.createPlaylistAndAdd(track, this.playlistOptions);
  }

  /**
   * 「保存合集」时用户把名字清空了才用到的兜底：**通用默认名**，不取歌名。
   *
   * 与 `LibraryStore.nextPlaylistNameForTrack` 分开是刻意的 —— 合集是多首曲目，
   * 而且 `collectionName` 已经预填成合集标题了；用户主动清空意味着「不要这个标题」，
   * 这时再把歌名塞回去等于无视他的操作。
   */
  private fallbackPlaylistName(existing: Playlist[]): string {
    const names: Set<string> = new Set<string>(
      existing.map((p: Playlist): string => p.name.trim())
    );
    if (!names.has(DEFAULT_PLAYLIST_NAME)) {
      return DEFAULT_PLAYLIST_NAME;
    }
    for (let i = 2; i < 1000; i++) {
      const candidate: string = `${DEFAULT_PLAYLIST_NAME} ${i}`;
      if (!names.has(candidate)) {
        return candidate;
      }
    }
    return `${DEFAULT_PLAYLIST_NAME} ${Date.now()}`;
  }

  private addToPlaylist(p: Playlist): void {
    const track: Track | null = this.pickerTrack;
    this.playlistPickerController?.close();
    if (!track) {
      return;
    }
    const updated: Playlist | null = LibraryStore.addTrackToPlaylist(p.id, track);
    // 双向收藏夹拦截提示：非 B 站曲目被 store 过滤时明确告知，
    // 不再说「已加入」（被滤时 addTrackToPlaylist 仍返回歌单对象）
    const skipped: number = LibraryStore.consumeFavMirrorSkippedCount();
    if (updated !== null && skipped > 0) {
      this.toast(`「${p.name}」是双向同步收藏夹，仅支持添加 B 站曲目`, 2200);
      return;
    }
    this.toast(updated ? `已加入「${p.name}」` : '加入歌单失败', 1600);
  }

  /**
   * 把多 P 合集（单视频分 P）或 B 站合集（ugc_season，多个独立视频）整个保存为歌单。
   * 先展开条目，成功后弹层让用户确认歌单名（默认取音频标题），再一次性建单入库。
   */
  private loadCollection(track: Track): void {
    const bvid: string = track.bvid ? track.bvid : track.id;
    if (bvid.length === 0 || bvid.indexOf('BV') !== 0) {
      this.toast('该条目不是视频合集', 1500);
      return;
    }
    this.toast('正在获取合集…', 1200);
    // 第三参 expandSeason=true：多 P 不存在时继续展开 ugc_season
    //（播放 / 下载链路不传，防止下载单集被扩成整季）。此入口是用户显式要整季的唯一路径。
    BilibiliApi.expandVideoParts(bvid, track, true)
      .then((list: Track[]): void => {
        if (list.length <= 1) {
          this.toast('该视频只有一个分 P', 1500);
          console.info(`[Collection] 合集仅展开 ${list.length} 条：${bvid}`);
          recordPlaybackLog(PLAYBACK_LOG_INFO,
            `合集「${track.title.slice(0, 30)}」仅展开 ${list.length} 条（该视频可能只有一个分P）`);
          return;
        }
        this.pendingCollectionTracks = list;
        this.collectionName = track.title;
        this.collectionSaverController?.open();
        console.info(`[Collection] 合集加载成功：${list.length} 首（${bvid}）`);
        recordPlaybackLog(PLAYBACK_LOG_INFO, `合集「${track.title.slice(0, 30)}」加载成功：${list.length} 首`);
      })
      .catch((e: Error): void => {
        console.error(`loadCollection failed: ${JSON.stringify(e)}`);
        this.toast('合集加载失败', 1800);
        recordPlaybackLog(PLAYBACK_LOG_ERROR, `合集「${track.title.slice(0, 30)}」加载失败：${e.message}`);
      });
  }

  /** 对话框「保存」：按用户输入的名字建歌单（空名回退默认名），把合集全部曲目一次写入（弹窗由按钮自动关闭） */
  private confirmSaveCollection(): void {
    const list: Track[] = this.pendingCollectionTracks;
    this.pendingCollectionTracks = [];
    if (list.length === 0) {
      return;
    }
    const input: string = this.collectionName.trim();
    // 该流程没有预读歌单列表，这里才需要读一次库来做默认名去重
    const name: string = input.length > 0 ? input : this.fallbackPlaylistName(LibraryStore.getPlaylists());
    const created: Playlist = LibraryStore.createPlaylist({
      name: name,
      coverUrl: list[0].coverUrl
    });
    created.tracks = list;
    LibraryStore.updatePlaylist(created);
    this.toast(`已保存歌单「${name}」，共 ${list.length} 首`, 2000);
  }

  private cancelSaveCollection(): void {
    this.pendingCollectionTracks = [];
  }

  /**
   * 「保存合集为歌单」对话框内容区：曲目数说明 + 名称输入。
   * 标题在 CustomContentDialog 的 primaryTitle；按钮在 buttons 槽（点击自动关闭）。
   */
  @Builder
  SaverBody(): void {
    Column() {
      Text(`共 ${this.pendingCollectionTracks.length} 首`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      TextInput({ placeholder: '输入歌单名称', text: this.collectionName })
        .width('100%')
        .height(44)
        // 字阶只用六档（24/20/18/16/13/11），15 属于禁用档（与相邻 13/16 差异不可辨）
        .fontSize(16)
        .onChange((v: string): void => {
          this.collectionName = v;
        })
    }
    .width('100%')
  }

  /**
   * 「加入歌单」弹窗正文：副标题（曲名）+「新建歌单并加入」+ 歌单列表。
   * 标题在 CustomContentDialog 的 primaryTitle；取消在 buttons 槽（自动关闭）。
   */
  @Builder
  PlaylistPickerBody(): void {
    Column() {
      Text(this.pickerTrack ? this.pickerTrack.title : '')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ bottom: 12 })
      // 第一项就是「新建歌单并加入」：想单独存一首歌时不必再跑到歌单页
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
                this.addToPlaylist(p);
              })
            }
          },
          // key 含渲染字段（与 PlaylistsPage 同因）：改名/数量变化后行才会重渲染
          (p: Playlist): string => `${p.id}_${p.name}_${p.tracks.length}`
        )
      }
      .width('100%')
      // 边界回弹：歌单多到可滚时，到边界的反馈动效
      .edgeEffect(EdgeEffect.Spring)
      .constraintSize({ maxHeight: 260 })
    }
    .width('100%')
  }

  /**
   * 「添加歌单到首页」弹窗正文：说明 + 候选歌单列表（封面 + 订阅徽标）。
   * 标题在 primaryTitle；取消在 buttons 槽（自动关闭）。
   */
  @Builder
  AddCardPickerBody(): void {
    Column() {
      Text('选中的歌单将以卡片加入首页，订阅歌单点卡直达 UP 主页')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ bottom: 12 })
      List() {
        ForEach(
          this.addCandidates,
          (p: Playlist): void => {
            ListItem() {
              Row({ space: 12 }) {
                CoverImage({
                  url: toThumbUrl(p.coverUrl, 88),
                  imgWidth: 44,
                  imgHeight: 44,
                  imgRadius: 8,
                  altText: p.name
                })
                Column({ space: 2 }) {
                  Row({ space: 6 }) {
                    Text(p.name)
                      .fontSize(16)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    // 订阅歌单徽标：这种卡点开直达 UP 主页，提前告知
                    if (LibraryStore.isUpSubscription(p)) {
                      Text('订阅')
                        .fontSize(10)
                        .fontColor(Color.White)
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .borderRadius(4)
                        .backgroundColor(this.themeDeep)
                    }
                  }
                  .width('100%')
                  Text(`${p.tracks.length} 首`)
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
              .stateStyles({
                pressed: { .backgroundColor($r('app.color.press_overlay')) },
                normal: { .backgroundColor(Color.Transparent) }
              })
              .onClick((): void => {
                this.addPlaylistToHome(p);
              })
            }
          },
          // key 含渲染字段（与「加入歌单」弹窗同因）：改名/数量变化后行才重渲染
          (p: Playlist): string => `${p.id}_${p.name}_${p.tracks.length}`
        )
      }
      .width('100%')
      // 边界回弹：歌单多到可滚时，到边界的反馈动效（「加入歌单」弹窗同款）
      .edgeEffect(EdgeEffect.Spring)
      .constraintSize({ maxHeight: 320 })
    }
    .width('100%')
  }

  /**
   * 「更换首页歌单」弹窗正文：被替换的原歌单说明 + 候选歌单列表
   * （封面 + 订阅徽标，AddCardPickerBody 同款版式）。标题在 primaryTitle；
   * 取消在 buttons 槽（自动关闭）。
   */
  @Builder
  ReplaceCardPickerBody(): void {
    Column() {
      Text(`将替换首页的「${this.replaceFromPlaylist?.name ?? ''}」`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ bottom: 12 })
      List() {
        ForEach(
          this.replaceCandidates,
          (p: Playlist): void => {
            ListItem() {
              Row({ space: 12 }) {
                CoverImage({
                  url: toThumbUrl(p.coverUrl, 88),
                  imgWidth: 44,
                  imgHeight: 44,
                  imgRadius: 8,
                  altText: p.name
                })
                Column({ space: 2 }) {
                  Row({ space: 6 }) {
                    Text(p.name)
                      .fontSize(16)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    // 订阅歌单徽标：这种卡点开直达 UP 主页，提前告知
                    if (LibraryStore.isUpSubscription(p)) {
                      Text('订阅')
                        .fontSize(10)
                        .fontColor(Color.White)
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .borderRadius(4)
                        .backgroundColor(this.themeDeep)
                    }
                  }
                  .width('100%')
                  Text(`${p.tracks.length} 首`)
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
              .stateStyles({
                pressed: { .backgroundColor($r('app.color.press_overlay')) },
                normal: { .backgroundColor(Color.Transparent) }
              })
              .onClick((): void => {
                this.replaceHomeCardWith(p);
              })
            }
          },
          // key 含渲染字段（与「添加歌单到首页」弹窗同因）：改名/数量变化后行才重渲染
          (p: Playlist): string => `${p.id}_${p.name}_${p.tracks.length}`
        )
      }
      .width('100%')
      // 边界回弹：歌单多到可滚时，到边界的反馈动效（「加入歌单」弹窗同款）
      .edgeEffect(EdgeEffect.Spring)
      .constraintSize({ maxHeight: 320 })
    }
    .width('100%')
  }

  /**
   * 多列行渲染（RowOf N 槽，平板横屏铺满改造）：行内 ForEach 展开 N 槽，
   * 槽间 Blank 间隔（网格）/ 槽 left margin（长条，TrackItem 自带内边距不加
   * 额外页边距）；空槽（奇数末行尾部）Blank 占位保持满行列宽。
   * 网格路径卡均 layoutWeight(1) 零 margin + 固定宽间隔条 → 左右封面严格等宽；
   * 长条路径槽 margin(TWO_COL_GAP_VP)（与配对时代二槽口径一致）。
   * rowIndex 供长条模式入场错峰（entranceIndex = rowIndex*cols + slotIndex）。
   */
  @Builder
  TrackColumnsRow(row: RowOf<Track>, rowIndex: number): void {
    Row() {
      ForEach(row.slots, (slot: Track | null, slotIndex: number): void => {
        if (this.isGrid()) {
          if (slotIndex > 0) {
            Blank().width(TWO_COL_GAP_VP)
          }
          if (slot !== null) {
            TrackCard({
               track: slot,
               onPlay: (tr: Track): void => {
                 // 先查后分流：多 P 合集跳合集详情页，单曲回落直接播放
                 openCollectionOrPlay(tr, this.player);
               },
               moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
             }).layoutWeight(1)
          } else {
            Blank().layoutWeight(1)
          }
        } else {
          if (slot !== null) {
            TrackItem({
               track: slot,
               entranceIndex: rowIndex * this.rowColumns() + slotIndex,
               onPlay: (tr: Track): void => {
                 // 先查后分流：多 P 合集跳合集详情页，单曲回落直接播放
                 openCollectionOrPlay(tr, this.player);
               },
               moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
             })
              .layoutWeight(1)
              .margin({ left: slotIndex > 0 ? TWO_COL_GAP_VP : 0 })
          } else {
            Blank().layoutWeight(1)
          }
        }
      }, (slot: Track | null, slotIndex: number): string => `${slotIndex}_${slot !== null ? slot.id : 'x'}`)
    }
    .width('100%')
    .padding({
      left: this.isGrid() ? GRID_EDGE_PADDING_VP : 0,
      right: this.isGrid() ? GRID_EDGE_PADDING_VP : 0
    })
    // Top 对齐：网格路径卡高随标题行数浮动，
    // Row 默认 Center 会把矮卡垂直居中 → 左右封面错位；网格 Top 让封面严格
    // 同高起步。两列长条路径保持默认 Center。
    .alignItems(this.isGrid() ? VerticalAlign.Top : VerticalAlign.Center)
  }

  /**
   * 行 key（LazyForEach keyGenerator 共用）：模式前缀（g/l）+ 槽 id 以 | join。
   * 模式前缀保证「网格↔长条同列数切换」时 key 变化强制重建行内组件
   * （TrackCard ↔ TrackItem），防 LazyForEach 缓存行内容陈旧。
   */
  private rowKeyOf(row: RowOf<Track>): string {
    let key: string = this.isGrid() ? 'g' : 'l';
    for (let i = 0; i < row.slots.length; i++) {
      const s: Track | null = row.slots[i];
      key += `|${s !== null ? s.id : 'x'}`;
    }
    return key;
  }

  /**
   * 热门歌单行 key（LazyForEach）：模式前缀（npg/npl）+ 槽位歌单 id 以 |
   * join（rowKeyOf 同款口径；前缀保证「网格↔长条同列数切换」时 key 变化
   * 强制重建行内组件，防 LazyForEach 缓存行内容陈旧）。
   */
  private neteaseRowKeyOf(row: RowOf<NeteasePlaylistSummary>): string {
    let key: string = this.isGrid() ? 'npg' : 'npl';
    for (let i = 0; i < row.slots.length; i++) {
      const s: NeteasePlaylistSummary | null = row.slots[i];
      key += `|${s !== null ? s.id : 'x'}`;
    }
    return key;
  }

  /**
   * 热门歌单多列行渲染（RowOf N 槽）：行内 ForEach 展开 N 槽，镜像
   * TrackColumnsRow 的网格/长条双分支 —— 网格：槽间固定宽间隔条 + 卡
   * layoutWeight(1) 零 margin（左右封面严格等宽）；长条（平板横屏多列）：
   * 槽 left margin 间隔（NeteasePlaylistRow 自带内边距，不加页边距）。
   * 空槽（奇数末行尾部）Blank 占位保持满行列宽。无入场错峰，不需要 rowIndex。
   */
  @Builder
  NeteasePlaylistColumnsRow(row: RowOf<NeteasePlaylistSummary>): void {
    Row() {
      ForEach(row.slots, (slot: NeteasePlaylistSummary | null, slotIndex: number): void => {
        if (this.isGrid()) {
          if (slotIndex > 0) {
            Blank().width(TWO_COL_GAP_VP)
          }
          if (slot !== null) {
            NeteasePlaylistCard({ summary: slot }).layoutWeight(1)
          } else {
            Blank().layoutWeight(1)
          }
        } else {
          if (slot !== null) {
            NeteasePlaylistRow({ summary: slot })
              .layoutWeight(1)
              .margin({ left: slotIndex > 0 ? TWO_COL_GAP_VP : 0 })
          } else {
            Blank().layoutWeight(1)
          }
        }
      }, (slot: NeteasePlaylistSummary | null, slotIndex: number): string => `${slotIndex}_${slot !== null ? slot.id : 'x'}`)
    }
    .width('100%')
    .padding({
      left: this.isGrid() ? GRID_EDGE_PADDING_VP : 0,
      right: this.isGrid() ? GRID_EDGE_PADDING_VP : 0
    })
    // Top 对齐口径同 TrackColumnsRow：网格卡高随标题行数浮动，Top 让封面
    // 严格同高起步；长条多列保持默认 Center。
    .alignItems(this.isGrid() ? VerticalAlign.Top : VerticalAlign.Center)
  }

  build() {
    Stack() {
      Column() {
        this.HomeStateArea()

        // 下拉刷新 + 上拉加载更多都挂在 List 上：
        // Refresh 只包住列表（入口搜索框 / chips 随内容滚动、不参与下拉独立手势）。
        Refresh({
          refreshing: $$this.refreshing,
          refreshingContent: this.refreshPlaceholder !== null ? this.refreshPlaceholder : undefined
        }) {
          List({ scroller: TabScrollerHolder.home }) {
            // 顶部空白占位条目（下载页同款）：列表视口铺满全屏，条目起始位置在
            // 屏幕顶端（y=0）。占位高度 = 列表内容起始让位量（listStartOffset：
            // safeTop + 56 + 独立定值），滚动时占位与条目一起从模糊板下方穿过。
            ListItem() {
              // 下拉刷新头（骨架接管）：刷新指示复用骨架行本身，不新增视觉元素。
              // 刻意不用 refreshingContent：ComponentContent 的内容不随页面
              // @State 刷新（要变只能显式 update），逐帧跟手做不到；普通组件树里才能被
              // onOffsetChange 的映射即时驱动。index 传 -1：SkeletonTrackItem 的入场错峰
              // 只认 0..5，-1 即不播入场（骨架本就纯静态），
              // 显隐节奏由刷新状态机（onRefreshStateChange）自己管。
              // 闸门第二条件：整屏骨架在场（列表为空，HomeStateArea 已接管）时绝不渲染，
              // 否则「顶部一条 + 下面一整屏」。
              // 骨架挂在占位条目内的 Stack 里做零布局覆盖：条件挂载若增删普通
              // ListItem，Drag/Inactive 翻转时会对下方内容产生
              // ±92vp（64 封面 + 上下 padding 28）布局位移；Stack 定高，
              // 挂载翻转只增删被定位的覆盖子节点，布局零影响。
              Stack({ alignContent: Alignment.BottomStart }) {
                if (this.showPullSkeleton && this.currentListLength() > 0) {
                  SkeletonTrackItem({ index: -1 })
                    .opacity(this.pullSkelOpacity)
                    .translate({ y: this.pullSkelOffsetY })
                    // 纯装饰：骨架永不交互；透明期也不吞占位带的触摸（透明节点
                    // 默认仍参与命中测试，会阻断列表滚动手势起手）。
                    .hitTestBehavior(HitTestMode.None)
                }
              }
              .width('100%')
              .height(this.listStartOffset())
            }

            // 头部条目 1：入口式搜索框（点击 push 'Search' 二级页；随内容滚出视口，
            // 滚出后 Index 标题栏右上淡入搜索按钮，见 syncEntryActive）。
            ListItem() {
              this.SearchEntryRow()
            }
            .width('100%')
            .padding({ left: NAV_H_PADDING, right: NAV_H_PADDING })

            // 头部条目 2：快捷卡行（搜索框之下 / 分类 chips 之上）：最近播放卡
            // + 收藏歌单卡（歌单 ⋯ 菜单「加入首页」自选），最多 5 卡横滑；点播放
            // 按钮起播 / 点卡跳转（见 HomeQuickCards）。卡行高度计入
            // HOME_TABS_FLIP_VP（chips 触栏判定阈值同步加高，见该常量注释）。
            ListItem() {
              HomeQuickCards({
                recentTracks: this.recentTracks,
                cardPlaylists: this.cardPlaylists,
                upArchiveCounts: this.upArchiveCounts,
                onAddClick: (): void => {
                  this.onAddCardClick();
                },
                onRemoveCard: (p: Playlist): void => {
                  this.removeHomeCard(p);
                },
                onReplaceCard: (p: Playlist): void => {
                  this.openReplaceCardPicker(p);
                }
              })
            }
            .width('100%')

            // 头部条目 3：分类 chip 条（推荐 / 排行榜 / 音乐中心，MusicHome
            // CategoryChipsSection 同款；点击写 STORE_SEARCH_TAB 切换下方内容）。
            ListItem() {
              HomeCategoryChips()
            }
            .width('100%')

            if (this.tab === 'recommend') {
              // 多列行（平板横屏 3~4 列铺满 / 大封面竖屏双列网格）：
              // 行数据源列数由 onColumnsChanged 联动；单列走原 TrackItem 路径。
              if (this.rowColumns() > 1) {
                LazyForEach(
                  this.recommendRows,
                  (row: RowOf<Track>, rowIndex: number): void => {
                    ListItem() {
                      this.TrackColumnsRow(row, rowIndex)
                    }
                  },
                  (row: RowOf<Track>): string => this.rowKeyOf(row)
                )
              } else {
                LazyForEach(
                  this.recommendSource,
                  (t: Track, index: number): void => {
                    ListItem() {
                      TrackItem({
                         track: t,
                         entranceIndex: index,
                         onPlay: (tr: Track): void => {
                           // 先查后分流：多 P 合集跳合集详情页，单曲回落直接播放
                           openCollectionOrPlay(tr, this.player);
                         },
                         moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
                       })
                    }
                  },
                  (t: Track): string => t.id
                )
              }
            } else if (this.tab === 'ranking') {
              // 热歌榜页签：网易云热歌榜单曲行（HotSongRow），点击实时搜
              // B 站匹配播放（playHotSongAt），无连播链。首次切入懒加载：
              // 骨架/空态在列表内原位渲染（chips 下方），不走 HomeStateArea
              // 顶部占位 —— 那会把搜索框/快捷卡/chips 顶飞再弹回（闪屏）。
              // 骨架 index 传 -1：不播入场错峰，纯静态。单曲行单列渲染，
              // 不做多列 / 大封面网格。
              if (this.loadingHotChart && this.hotSongs.length === 0) {
                ForEach(SKELETON_ROW_INDEXES, (_i: number): void => {
                  ListItem() {
                    SkeletonTrackItem({ index: -1 })
                  }
                }, (_i: number): string => `hs_${_i}`)
              } else if (this.hotSongs.length === 0) {
                // 首拉失败：原位空态 + 重试（不顶飞布局）
                ListItem() {
                  Column() {
                    Text('暂无数据')
                      .fontSize(16)
                      .fontColor($r('app.color.text_secondary'))
                    Button('点击重试', { type: ButtonType.Normal })
                      .fontSize(13)
                      .borderRadius(BUTTON_RADIUS_VP)
                      .margin({ top: 12 })
                      .onClick((): void => {
                        this.reloadCurrentTab();
                      })
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Center)
                  .padding({ top: 48, bottom: 24 })
                }
              } else {
                LazyForEach(
                  this.hotSongSource,
                  (s: NeteaseHotSong, index: number): void => {
                    ListItem() {
                      this.HotSongRow(s, index)
                    }
                  },
                  (s: NeteaseHotSong, index: number): string => `${index}_${s.title}`
                )
              }
            } else if (this.tab === 'center') {
              // 音乐中心页签：同上（TrackColumnsRow 内部分支）
              if (this.rowColumns() > 1) {
                LazyForEach(
                  this.centerRows,
                  (row: RowOf<Track>, rowIndex: number): void => {
                    ListItem() {
                      this.TrackColumnsRow(row, rowIndex)
                    }
                  },
                  (row: RowOf<Track>): string => this.rowKeyOf(row)
                )
              } else {
                LazyForEach(
                  this.centerSource,
                  (t: Track, index: number): void => {
                    ListItem() {
                      TrackItem({
                         track: t,
                         entranceIndex: index,
                         onPlay: (tr: Track): void => {
                           // 先查后分流：多 P 合集跳合集详情页，单曲回落直接播放
                           openCollectionOrPlay(tr, this.player);
                         },
                         moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
                       })
                    }
                  },
                  (t: Track): string => t.id
                )
              }
            } else if (this.tab === 'netease') {
              // 热门歌单页签：双模式镜像上面三个页签 —— 长条模式
              // NeteasePlaylistRow（TrackItem 版式小封面行）、大封面模式
              // NeteasePlaylistCard（TrackCard 版式网格卡），点击均进
              // NeteasePlaylist 预览页（点歌实时搜 B 站匹配 / 导入本地歌单）。
              // 首次切入懒加载：骨架/空态在列表内原位渲染（chips 下方），
              // 不走 HomeStateArea 顶部占位 —— 那会把搜索框/快捷卡/chips
              // 顶飞再弹回（闪屏）。骨架 index 传 -1：不播入场错峰，纯静态。
              if (this.loadingNetease && this.neteasePlaylists.length === 0) {
                ForEach(SKELETON_ROW_INDEXES, (_i: number): void => {
                  ListItem() {
                    SkeletonTrackItem({ index: -1 })
                  }
                }, (_i: number): string => `ns_${_i}`)
              } else if (this.neteasePlaylists.length === 0) {
                // 首拉失败：原位空态 + 重试（不顶飞布局）
                ListItem() {
                  Column() {
                    Text('暂无数据')
                      .fontSize(16)
                      .fontColor($r('app.color.text_secondary'))
                    Button('点击重试', { type: ButtonType.Normal })
                      .fontSize(13)
                      .borderRadius(BUTTON_RADIUS_VP)
                      .margin({ top: 12 })
                      .onClick((): void => {
                        this.reloadCurrentTab();
                      })
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Center)
                  .padding({ top: 48, bottom: 24 })
                }
              } else if (this.rowColumns() > 1) {
                LazyForEach(
                  this.neteaseRows,
                  (row: RowOf<NeteasePlaylistSummary>): void => {
                    ListItem() {
                      this.NeteasePlaylistColumnsRow(row)
                    }
                  },
                  (row: RowOf<NeteasePlaylistSummary>): string => this.neteaseRowKeyOf(row)
                )
              } else {
                LazyForEach(
                  this.neteaseSource,
                  (p: NeteasePlaylistSummary, index: number): void => {
                    ListItem() {
                      NeteasePlaylistRow({ summary: p })
                    }
                  },
                  (p: NeteasePlaylistSummary): string => p.id
                )
              }
            }

            // 加载更多状态条（常驻 + 固定高度）：只在这一屏有内容时出现；
            // 只换内容不插拔、高度恒定，数据落地帧尾部 extent 只增不减，底部弹簧
            // 过滚动不被收缩强制解析（防加载下一页时列表整体跳动）。
            // 加载态是单行转圈：为固定高度做的取舍，首屏/下拉刷新骨架不动。
            if (this.currentListLength() > 0) {
              ListItem() {
                Row() {
                  if (this.loadingMore) {
                    LoadingProgress()
                      .width(18)
                      .height(18)
                      .color($r('app.color.text_tertiary'))
                    Text('加载中…')
                      .fontSize(12)
                      .fontColor($r('app.color.text_tertiary'))
                      .margin({ left: 8 })
                  } else if (!this.hasMore()) {
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
                .height(LIST_FOOTER_HEIGHT_VP)
                .justifyContent(FlexAlign.Center)
              }
            }
          }
          .width('100%')
          .height('100%')
          // 边界回弹：到底的反馈动效；顶部下拉由 Refresh 刷新动画接管。
          .edgeEffect(EdgeEffect.Spring)
          .cachedCount(8)
          // Sumy 式穿透：顶部根栏让位由 List 首个空白占位 ListItem 负责（见上方
          // 占位注释，下载页同款），不用 contentStartOffset —— 材质层有
          // 内容可模糊（浮出效果才可见）。
          // 底部悬浮页签让位：列表末尾可滚动至悬浮条上方，不被遮挡。
          // 页签栏自己抬高了 safeBottom（见 Index.ets），列表末尾要跟着多让这么多，
          // 否则最后一项会被页签栏 / 迷你条压住。
          .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
          .onReachEnd((): void => {
            this.onReachEnd();
          })
          // [Fling·F1] 边界采样（规格 §F1）：只在状态翻转时打一次 [Fling] 日志；
          // 回调 void 返回，绝不返回 ScrollResult（禁止的 F4a 吃帧）。
          .onWillScroll((offset: number, state: ScrollState, source: ScrollSource): void => {
            if (FlingSampler.note(state)) {
              console.info(`[Fling] state=${FlingSampler.stateName(state)} src=${source} off=${offset}`);
            }
          })
          // 逐帧驱动自绘渐变模糊层（onDidScroll 在偏移已应用
          // 后回调，onWillScroll 是应用前，快滑时差一帧会让模糊层滞后一跳）。
          // 同帧顺带同步头部在场状态（翻转才写，见 syncEntryActive）。
          .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
            this.syncTopBlurProgress();
            this.syncEntryActive();
            this.syncChipsActive();
          })
          .onScrollStop((): void => {
            FlingSampler.note(ScrollState.Idle);
            // Idle 校准终态：停点即精确值，
            // 兜住 Fling 期任何丢帧 / 死区过滤累计的偏差。
            this.syncTopBlurProgress();
            this.syncEntryActive();
            this.syncChipsActive();
            console.info('[Fling] stop');
          })
        }
        .layoutWeight(1)
        .width('100%')
        .onRefreshing((): void => {
          this.handleRefresh();
        })
        // ── 下拉刷新参数底座 ──
        // 触发阈值 72vp（同时是骨架淡入进度的分母：拉满 = 不透明 = 「松手即刷」）；
        // 跟手 55%（跟手但带阻尼）；最大下拉 120vp 封顶，防大力下拉把页面拽出半屏。
        .refreshOffset(PULL_REFRESH_OFFSET_VP)
        .pullDownRatio(PULL_REFRESH_RATIO)
        .maxPullDownDistance(PULL_MAX_DISTANCE_VP)
        // 五态状态机：跟手闸门 / 整屏骨架让位 / Done 淡出（见 onRefreshStateChange）
        .onStateChange((status: RefreshStatus): void => {
          this.onRefreshStateChange(status);
        })
        // 每帧回写下拉进度 → 骨架淡入 + 落位映射（跟手要即时，不套 animateTo）；
        // 只写状态变量：不发请求 / 改数组 / 打日志。Done 淡出在途时让位给退场动画。
        .onOffsetChange((offset: number): void => {
          this.pullOffset = offset;
          if (this.pullFadeTimer !== -1) {
            return;
          }
          const p: number = Math.min(this.pullOffset / PULL_REFRESH_OFFSET_VP, 1);
          this.pullSkelOpacity = p;
          this.pullSkelOffsetY = (1 - p) * PULL_SKELETON_SETTLE_VP;
        })
      }
      .width('100%')
      .height('100%')
      // ⚠️ 不再整体 padding top：列表视口要铺满全屏（占位条目负责让出栏高），
      // 否则条目在栏底被裁掉、永远滑不进模糊板下方。骨架/空态区各自补 listStartOffset()。
      // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp，见 BreakpointConstants）。
      // 根 Stack 默认居中对齐，直接给内容列挂上限即可，不需要额外包一层。
      // 横屏宽屏 / 平板：铺满口径（fillContentMaxWidth）——平板横屏 min(窗口宽,1660)
      // 铺满不留白，列数由 listColumns/gridColumns 按同窗口宽反推保持行宽密度。
      .constraintSize({ maxWidth: TwoColumnLayout.fillContentMaxWidth(this.currentBreakpoint, this.isLandscape, this.windowWidthVp) })

      // 顶栏渐变模糊层：盖主内容列之上（低于 HDS titleBar；弹窗类已全部
      // 迁移到官方 CustomContentDialog，不再挂根 Stack），进度由列表
      // onDidScroll/onScrollStop 经 topBlurUpdater 命令式驱动。根栏 HDS 滚动效果已由 Index.titleBarStyle
      // 关闭（防双重模糊），本层承担全部渐变模糊观感。
      TopGradientBlurOverlay({
        barHeightVp: this.safeTop + NAV_TITLE_BAR_HEIGHT,
        updater: this.topBlurUpdater
      })

    }
    .width('100%')
    .height('100%')
  }
}
