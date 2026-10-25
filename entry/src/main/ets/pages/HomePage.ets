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
 *   · 卡行下方：分类 chip 条（HomeCategoryChips：推荐 / 排行榜 / 音乐中心）
 *     + 随所选 tab 显示对应数据源的条目列表。
 *
 * 入口搜索框是**入口**不是输入框：真输入在 'Search' 二级页（push 后自动聚焦）。
 *
 * 头部滚动联动：列表偏移跨越 HOME_ENTRY_FLIP_VP 时翻转
 * STORE_HOME_SEARCH_ENTRY_ACTIVE（只在翻转时写），Index 标题栏读它
 * 淡入/淡出右上搜索按钮 —— 头部滚出视口后用户随时有搜索入口。
 *
 * 四个数据源里本页占三个，分页能力各不相同（对照实验结论，细节见
 * api/BilibiliApi.ts 的注释）：
 *   · 推荐     —— 首屏 index/top/rcmd（30 条，重复调用返回同一批）+ popular pn=1；
 *                 翻页必须走 feed/rcmd 的 fresh_idx（每页约 17 条新内容）
 *   · 排行榜   —— ranking/v2 全站榜（rid=0，每日更新）一次返回整榜 100 条、
 *                 pn/ps 无效 → 只能前端分页
 *   · 音乐中心 —— 新歌榜（最新发布，固定 18 条）置顶 + 综合榜（热歌，真分页 pn）随后
 * 把「不能分页的源」硬接成上拉加载，得到的就是「一直加载却永远同一批」，所以分开处理。
 * 「下拉刷新 + 上拉加载更多」机制见 build 内注释（骨架接管）。
 */

import * as BilibiliApi from '../api/BilibiliApi';
import {
  PopularVideo,
  RankingVideoItem,
  MusicCenterItem,
  MusicCenterRelatedArchive
} from '../api/BilibiliApi';
import { Playlist, Track, VideoDetail, VideoOwner, VideoStat, buildTrack, ITEM_DISPLAY_LIST, ITEM_DISPLAY_GRID } from '../model/MusicModels';
import { LibraryStore } from '../service/LibraryStore';
import { TrackItem } from '../components/TrackItem';
import { TrackCard } from '../components/TrackCard';
import { CoverImage } from '../components/CoverImage';
import { SkeletonTrackItem } from '../components/SkeletonTrackItem';
import { MusicPlayer } from '../player/MusicPlayer';
import { toHttpsUrl, stripHtmlTags, toThumbUrl } from '../utils/TextUtil';
import { ComponentContent, CustomContentDialog } from '@kit.ArkUI';
import { NavStackHolder } from '../service/NavStackHolder';
import { UpSpaceRouteParam } from '../service/NavRouteParams';
import {
  DownloadManager,
  DownloadStartResult,
  WIFI_ONLY_BLOCKED
} from '../service/DownloadManager';
import { currentNetworkLabel } from '../utils/NetworkUtil';
import {
  CONTENT_END_OFFSET,
  DEFAULT_PLAYLIST_NAME,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_NET_RETRY_REV,
  STORE_SEARCH_TAB,
  STORE_ITEM_DISPLAY_STYLE,
  STORE_THEME_DEEP,
  STORE_HOME_SEARCH_ENTRY_ACTIVE,
  STORE_HOME_CHIPS_ACTIVE,
  STORE_LIBRARY_REV
} from '../common/Constants';
import { FlingSampler } from '../components/FlingSampler';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';
import { showAppToast } from '../components/AppToast';
import { PLAYBACK_LOG_INFO, PLAYBACK_LOG_ERROR, recordPlaybackLog } from '../service/PlaybackLogStore';
import { showAppAlertDialog } from '../components/AppAlertDialog';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import {
  PairOf,
  PairDataSource,
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
    pubdate: v.pubdate ?? 0
  });
}

/**
 * 排行榜（ranking/v2）映射。
 * 与旧的 ranking/region 不同：这条接口有 owner 对象、有 cid、duration 是**秒**。
 * owner / stat 仍按可空读取——字段缺失时映射函数抛异常会让整块列表被 catch 成空，
 * 这是本项目踩过的坑，宁可退化成空字符串也不要整块丢。
 */
function mapRankingV2(v: RankingVideoItem): Track {
  const owner: VideoOwner | null = v.owner;
  const stat: VideoStat | null = v.stat;
  return buildTrack({
    id: v.bvid,
    bvid: v.bvid,
    aid: String(v.aid),
    cid: v.cid ? String(v.cid) : '',
    title: stripHtmlTags(v.title),
    artist: owner ? owner.name : '',
    upMid: owner && owner.mid ? String(owner.mid) : '',
    coverUrl: toHttpsUrl(v.pic),
    duration: v.duration,
    playCount: stat ? stat.view : 0,
    pubdate: v.pubdate ?? 0
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
/** 推荐流每页条数：实测 ps=20 时约 17 条有效（其余是登录引导/广告卡片） */
const RECOMMEND_FEED_PS: number = 20;
/** 排行榜一次拿全（实测 100 条）后前端分页，每次多放这么多条 */
const RANKING_PAGE_SIZE: number = 20;
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
  /** 内容 tab（'recommend'/'ranking'/'center'）：HomeCategoryChips 写、本页读；非法值兜底为 recommend（见 normalizeTab） */
  @StorageLink(STORE_SEARCH_TAB) tab: string = 'recommend';
  /** 主题色深色运行时值：歌单选择弹层的「新建歌单并加入」跟随切色刷新 */
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  @State @Watch('onListSourceChanged') recommend: Track[] = [];
  @State @Watch('onListSourceChanged') ranking: Track[] = [];
  @State @Watch('onListSourceChanged') center: Track[] = [];
  // ===== 列表数据源（LazyForEach 渲染）=====
  // 三 tab 数组都挂 @Watch('onListSourceChanged')：整表替换与 push 追加都会触发
  // （V1 数组代理拦截 push），对应 ArrayDataSource 整表 reload + 两列 PairDataSource
  // sync。reload 语义与 tab 数据流天然匹配：刷新必是整表换源；翻页 push 时
  // LazyForEach 只重建可视区，代价可控。
  private recommendSource: ArrayDataSource<Track> = new ArrayDataSource<Track>([]);
  private recommendPairs: PairDataSource<Track> = new PairDataSource<Track>(this.recommendSource);
  private rankingSource: ArrayDataSource<Track> = new ArrayDataSource<Track>([]);
  private rankingPairs: PairDataSource<Track> = new PairDataSource<Track>(this.rankingSource);
  private centerSource: ArrayDataSource<Track> = new ArrayDataSource<Track>([]);
  private centerPairs: PairDataSource<Track> = new PairDataSource<Track>(this.centerSource);
  /** 诊断用实例号（aboutToAppear 分配） */
  private pageId: number = 0;
  /** 推荐位待完成的数据源数量（热门 + 推荐两个源并行，互不影响） */
  @State recommendPending: number = 0;
  @State loadingRanking: boolean = false;
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
   * 「+」卡选择器（快捷卡行末尾添加卡）：官方 CustomContentDialog 标准
   * 弹窗（addCardPickerController）。候选 = 未加入首页的歌单（与歌单页
   * getPlaylists 同口径，含订阅歌单）。
   */
  @State addCandidates: Playlist[] = [];
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
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中，见 build 里的 constraintSize */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 横竖屏（Index 常驻注册写入）：横屏宽屏时条目两列显示 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;

  /** 横屏宽屏（窗口 ≥600vp 的横屏）时条目两列显示；竖屏 / 窄窗口单列不变 */
  private isTwoCol(): boolean {
    return TwoColumnLayout.isActive(this.currentBreakpoint, this.isLandscape);
  }

  /** 条目展示（外观设置「条目展示」）：长条（默认）/ 大封面双列网格 */
  @StorageProp(STORE_ITEM_DISPLAY_STYLE) itemDisplay: string = ITEM_DISPLAY_LIST;

  /**
   * 大封面模式：三页签（推荐 / 排行榜 / 音乐中心）的封面类视频条目配对成
   * 双列网格卡（TrackCard），竖屏 / 横屏均双列；交互契约与行内版一致
   * （整卡点击播/暂停、「⋯」菜单）。配对数据源（recommendPairs 等）在
   * onListSourceChanged 无条件 sync，网格竖屏也是热的。
   */
  private isGrid(): boolean {
    return this.itemDisplay === ITEM_DISPLAY_GRID;
  }

  /** Refresh 组件的转圈状态（$$ 双向绑定，干完活必须落回 false 才会收起） */
  @State refreshing: boolean = false;
  /** 加载更多进行中（同一时刻只允许一个 tab 在加载） */
  @State loadingMore: boolean = false;
  /** 推荐流还有没有下一页（feed 返回 0 条或整页重复即到底） */
  @State recommendHasMore: boolean = true;
  /** 音乐中心还有没有下一页（综合榜某页返回 0 条即到底） */
  @State centerHasMore: boolean = true;

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
  /** 排行榜全量（接口一次给全，展示侧按 RANKING_PAGE_SIZE 切片） */
  private rankingAll: Track[] = [];

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

  /**
   * 列表数组变化（@Watch 携带属性名）：同步对应数据源。
   * 初始赋值不触发 @Watch，会话恢复场景由 syncAllListSources（aboutToAppear）兜底。
   */
  private onListSourceChanged(propName: string): void {
    if (propName === 'recommend') {
      this.recommendSource.reload(this.recommend);
      this.recommendPairs.sync();
    } else if (propName === 'ranking') {
      this.rankingSource.reload(this.ranking);
      this.rankingPairs.sync();
    } else if (propName === 'center') {
      this.centerSource.reload(this.center);
      this.centerPairs.sync();
    }
  }

  /** 初值同步（@Watch 不触发初始赋值）：挂载时补一次 */
  private syncAllListSources(): void {
    this.recommendSource.reload(this.recommend);
    this.recommendPairs.sync();
    this.rankingSource.reload(this.ranking);
    this.rankingPairs.sync();
    this.centerSource.reload(this.center);
    this.centerPairs.sync();
  }

  /**
   * tab 值兜底：旧版升级用户的 AppStorage 里 STORE_SEARCH_TAB 可能残留
   * 'search'（旧搜索页签）—— 本页三分支都不命中会渲染空列表，这里归一到
   * 'recommend'。
   */
  private normalizeTab(): void {
    if (this.tab !== 'recommend' && this.tab !== 'ranking' && this.tab !== 'center') {
      this.tab = 'recommend';
    }
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

  aboutToAppear(): void {
    // 列表数据源初值同步（见 syncAllListSources 注释）
    this.syncAllListSources();
    this.normalizeTab();
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
    this.loadHomeData();
    // 快捷卡行首灌：LibraryStore 冷启动是同步磁盘读（getSync + JSON.parse），
    // 延后一拍防卡首帧（PlaylistsPage 首次 refresh 同款取舍）
    setTimeout((): void => {
      this.refreshQuickCards();
    }, 0);
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
   */
  private loadHomeData(): void {
    this.loadHomeRecommend();
    this.loadRanking();
    this.loadCenter();
  }

  private resetRecommend(): void {
    this.recommend = [];
    this.recommendFreshIdx = 1;
    this.recommendHasMore = true;
    // 先预置为 2（热门 + 推荐），避免首帧渲染时因计数为 0 闪一下"暂无数据"
    this.recommendPending = 2;
  }

  private loadHomeRecommend(): void {
    this.resetRecommend();
    this.loadPopular();
    this.loadRecommended();
  }

  private appendRecommend(list: Track[]): void {
    this.recommend = mergeTracks(this.recommend, list);
  }

  private async loadPopular(): Promise<void> {
    try {
      const pop: PopularVideo[] = await BilibiliApi.getPopularVideos(10, 1);
      this.appendRecommend(pop.map(mapPopular));
    } catch (e) {
      console.error(`loadPopular failed: ${JSON.stringify(e)}`);
    } finally {
      this.recommendPending = this.recommendPending - 1;
    }
  }

  private async loadRecommended(): Promise<void> {
    try {
      const rec: PopularVideo[] = await BilibiliApi.getRecommendedVideos(10);
      this.appendRecommend(rec.map(mapPopular));
    } catch (e) {
      // 该接口在缺少 buvid Cookie 时会返回 HTTP 412；此处失败不影响同行热门数据
      console.error(`loadRecommended failed: ${JSON.stringify(e)}`);
    } finally {
      this.recommendPending = this.recommendPending - 1;
    }
  }

  private async loadRanking(): Promise<void> {
    this.loadingRanking = true;
    try {
      const list: RankingVideoItem[] = await BilibiliApi.getGlobalRankingV2();
      this.rankingAll = list.map(mapRankingV2);
      this.ranking = this.rankingAll.slice(0, RANKING_PAGE_SIZE);
    } catch (e) {
      console.error(`loadRanking failed: ${JSON.stringify(e)}`);
    } finally {
      this.loadingRanking = false;
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
  private loadCenter(): void {
    this.resetCenter();
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
    this.center = mergeTracks(this.centerNewTracks, this.centerHotTracks);
  }

  private async loadCenterRank(): Promise<void> {
    try {
      const hot: MusicCenterItem[] = await BilibiliApi.getMusicComprehensiveRank(CENTER_PAGE_SIZE, 1);
      this.centerHotTracks = mapMusicCenterList(hot);
    } catch (e) {
      console.error(`loadCenterRank failed: ${JSON.stringify(e)}`);
    } finally {
      this.centerPending = this.centerPending - 1;
      this.settleCenter();
    }
  }

  private async loadCenterNew(): Promise<void> {
    try {
      const fresh: MusicCenterItem[] = await BilibiliApi.getNewMusic();
      this.centerNewTracks = mapMusicCenterList(fresh);
    } catch (e) {
      console.error(`loadCenterNew failed: ${JSON.stringify(e)}`);
    } finally {
      this.centerPending = this.centerPending - 1;
      this.settleCenter();
    }
  }

  private currentListLength(): number {
    if (this.tab === 'recommend') {
      return this.recommend.length;
    }
    if (this.tab === 'ranking') {
      return this.ranking.length;
    }
    return this.center.length;
  }

  private homeLoading(): boolean {
    if (this.tab === 'recommend') {
      return this.recommendPending > 0;
    }
    if (this.tab === 'ranking') {
      return this.loadingRanking;
    }
    if (this.tab === 'center') {
      return this.centerPending > 0;
    }
    return false;
  }

  /**
   * 当前 tab 还有没有下一页。
   * 三个源的分页能力不同，所以判据也不同（详见文件头的说明）。
   */
  private hasMore(): boolean {
    if (this.tab === 'recommend') {
      return this.recommend.length > 0 && this.recommendHasMore;
    }
    if (this.tab === 'ranking') {
      // 全量已经在内存里，没放完就还有
      return this.ranking.length > 0 && this.ranking.length < this.rankingAll.length;
    }
    if (this.tab === 'center') {
      return this.center.length > 0 && this.centerHasMore;
    }
    return false;
  }

  /** 空态里的「点击重试」：只重载当前 tab，不要把三个源都刷一遍 */
  private reloadCurrentTab(): void {
    if (this.tab === 'recommend') {
      this.loadHomeRecommend();
    } else if (this.tab === 'ranking') {
      this.loadRanking();
    } else {
      this.loadCenter();
    }
  }

  /**
   * 网络恢复自动重试（Index 发信号）：只救「tab 加载失败后停在空态」的场景 ——
   * 失败态的判据与空态 UI 一致（非加载中 + 列表为空，见 HomeStateArea）。
   */
  private onNetRetry(): void {
    if (!this.homeLoading() && this.currentListLength() === 0) {
      this.reloadCurrentTab();
    }
  }

  private handleRefresh(): void {
    if (this.tab === 'recommend') {
      this.refreshRecommend();
    } else if (this.tab === 'ranking') {
      this.refreshRanking();
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

  private async refreshRanking(): Promise<void> {
    try {
      await this.loadRanking();
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
   *     「顶部一条 + 下面一整屏」；ranking 不清列表，骨架是唯一指示，
   *     停在原位保持纯静态即可（骨架纯静态，不另加旋转/脉冲/进度环）。
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
      if (this.tab === 'recommend' || this.tab === 'center') {
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
      this.revealMoreRanking();
    } else {
      this.loadMoreCenter();
    }
  }

  private async loadMoreRecommend(): Promise<void> {
    this.loadingMore = true;
    try {
      const idx: number = this.recommendFreshIdx + 1;
      const feed: PopularVideo[] = await BilibiliApi.getRecommendedFeed(idx, RECOMMEND_FEED_PS);
      this.recommendFreshIdx = idx;
      const before: number = this.recommend.length;
      // 按 id 去重后增量 push：推荐流翻页常回捞已出现过的视频。
      const seen: Set<string> = new Set<string>();
      for (let i = 0; i < this.recommend.length; i++) {
        seen.add(this.recommend[i].id);
      }
      for (let i = 0; i < feed.length; i++) {
        const t: Track = mapPopular(feed[i]);
        if (!seen.has(t.id)) {
          seen.add(t.id);
          this.recommend.push(t);
        }
      }
      if (feed.length === 0) {
        this.recommendHasMore = false;
      } else if (this.recommend.length === before) {
        // 整整一页都是已看过的内容：继续翻只会原地打转，直接收口
        this.recommendHasMore = false;
      }
    } catch (e) {
      console.error(`loadMoreRecommend failed: ${JSON.stringify(e)}`);
      this.toast('加载更多失败，请稍后重试', 1800);
    } finally {
      this.loadingMore = false;
    }
  }

  /** 排行榜：接口已经一次给全，这里只是多放一屏，不发请求 */
  private revealMoreRanking(): void {
    const from: number = this.ranking.length;
    const next: number = Math.min(from + RANKING_PAGE_SIZE, this.rankingAll.length);
    for (let i = from; i < next; i++) {
      this.ranking.push(this.rankingAll[i]);
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

  /**
   * 加载中 / 空数据的统一展示区。
   * 加载中：骨架屏（形状贴合 TrackItem 的 40 圆头像 + 两条文字条，纯静态占位），
   * 占位形状对齐内容布局，加载完成内容「落位」不跳。
   */
  @Builder
  HomeStateArea(): void {
    if (this.homeLoading() && this.currentListLength() === 0) {
      this.SkeletonArea()
    } else if (!this.homeLoading() && this.currentListLength() === 0) {
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
      }
    ];
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
   * 配对条目行（两列 / 大封面网格共用骨架）：
   * 长条（TrackItem）路径：first + second / Blank 布局。
   * 大封面路径渲染双列 TrackCard（无入场错峰）。
   * 几何：网格路径两卡均 layoutWeight(1) 零 margin、中间
   * 固定宽间隔条（layoutWeight 份额含 margin，margin 挂 weighted 卡会让右卡
   * 窄 12vp）→ 左右封面严格等宽；Row 页边距只在网格模式生效（长条路径零页
   * 边距，防横屏两列长条行整体外移）。pIndex 供长条模式入场错峰
   * （first = pIndex*2，second = pIndex*2+1）。
   */
  @Builder
  TrackPairRow(pair: PairOf<Track>, pIndex: number): void {
    Row() {
      if (this.isGrid()) {
        TrackCard({
          track: pair.first,
          onPlay: (tr: Track): void => this.player.playOrToggle(tr),
          moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
        }).layoutWeight(1)
        Blank().width(TWO_COL_GAP_VP)
        if (pair.second !== null) {
          TrackCard({
            track: pair.second,
            onPlay: (tr: Track): void => this.player.playOrToggle(tr),
            moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
          }).layoutWeight(1)
        } else {
          Blank().layoutWeight(1)
        }
      } else {
        TrackItem({
          track: pair.first,
          entranceIndex: pIndex * 2,
          onPlay: (tr: Track): void => this.player.playOrToggle(tr),
          moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
        }).layoutWeight(1)
        if (pair.second !== null) {
          TrackItem({
            track: pair.second,
            entranceIndex: pIndex * 2 + 1,
            onPlay: (tr: Track): void => this.player.playOrToggle(tr),
            moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
          }).layoutWeight(1).margin({ left: TWO_COL_GAP_VP })
        } else {
          Blank().layoutWeight(1)
        }
      }
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
                onAddClick: (): void => {
                  this.onAddCardClick();
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
              // 大封面模式（外观设置「条目展示」）竖屏也走双列网格；
              // 与横屏两列共用 TrackPairRow（长条 / 网格卡在其内部分支）
              if (this.isTwoCol() || this.isGrid()) {
                LazyForEach(
                  this.recommendPairs,
                  (pair: PairOf<Track>, pIndex: number): void => {
                    ListItem() {
                      this.TrackPairRow(pair, pIndex)
                    }
                  },
                  (pair: PairOf<Track>): string =>
                    `${pair.first.id}|${pair.second !== null ? pair.second.id : 'x'}`
                )
              } else {
                LazyForEach(
                  this.recommendSource,
                  (t: Track, index: number): void => {
                    ListItem() {
                      TrackItem({
                        track: t,
                        entranceIndex: index,
                        onPlay: (tr: Track): void => this.player.playOrToggle(tr),
                        moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
                      })
                    }
                  },
                  (t: Track): string => t.id
                )
              }
            } else if (this.tab === 'ranking') {
              // 大封面模式：同推荐页签（TrackPairRow 内部分支）
              if (this.isTwoCol() || this.isGrid()) {
                LazyForEach(
                  this.rankingPairs,
                  (pair: PairOf<Track>, pIndex: number): void => {
                    ListItem() {
                      this.TrackPairRow(pair, pIndex)
                    }
                  },
                  (pair: PairOf<Track>): string =>
                    `${pair.first.id}|${pair.second !== null ? pair.second.id : 'x'}`
                )
              } else {
                LazyForEach(
                  this.rankingSource,
                  (t: Track, index: number): void => {
                    ListItem() {
                      TrackItem({
                        track: t,
                        entranceIndex: index,
                        onPlay: (tr: Track): void => this.player.playOrToggle(tr),
                        moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
                      })
                    }
                  },
                  (t: Track): string => t.id
                )
              }
            } else {
              // 音乐中心页签：同上（TrackPairRow 内部分支）
              if (this.isTwoCol() || this.isGrid()) {
                LazyForEach(
                  this.centerPairs,
                  (pair: PairOf<Track>, pIndex: number): void => {
                    ListItem() {
                      this.TrackPairRow(pair, pIndex)
                    }
                  },
                  (pair: PairOf<Track>): string =>
                    `${pair.first.id}|${pair.second !== null ? pair.second.id : 'x'}`
                )
              } else {
                LazyForEach(
                  this.centerSource,
                  (t: Track, index: number): void => {
                    ListItem() {
                      TrackItem({
                        track: t,
                        entranceIndex: index,
                        onPlay: (tr: Track): void => this.player.playOrToggle(tr),
                        moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
                      })
                    }
                  },
                  (t: Track): string => t.id
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
      // 横屏宽屏：上限放宽到 840vp，两列每列行宽约 400vp+。
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })

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
