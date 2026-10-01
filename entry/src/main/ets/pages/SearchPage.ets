/**
 * 搜索页：搜索 / 推荐 / 排行榜 / 音乐中心。
 * 搜索结果在本页签内展示；关键词与结果存于 SearchStateHolder，
 * 切换底部页签后返回不丢失。
 *
 * 四个页签都支持「下拉刷新 + 上拉加载更多」，但四个数据源的分页能力**完全不同**
 * （都是对线上接口做对照实验后的结论，细节见 api/BilibiliApi.ts 的注释）：
 *   · 搜索     —— /wbi/search/type 真分页：page / page_size，响应带 numPages
 *   · 推荐     —— 首屏 index/top/rcmd（30 条，重复调用返回同一批）+ popular pn=1；
 *                 翻页必须走 feed/rcmd 的 fresh_idx（每页约 17 条新内容）
 *   · 排行榜   —— ranking/v2 一次返回整榜 96 条、pn/ps 无效 → 只能前端分页
 *   · 音乐中心 —— comprehensive/web/rank 真分页（pn）；新歌榜固定 18 条只补首屏
 * 把「不能分页的源」硬接成上拉加载，得到的就是「一直加载却永远同一批」，所以这里分开处理。
 */

import * as BilibiliApi from '../api/BilibiliApi';
import {
  SearchResultItem,
  PopularVideo,
  RankingVideoItem,
  MusicCenterItem,
  MusicCenterRelatedArchive
} from '../api/BilibiliApi';
import { Playlist, Track, VideoOwner, VideoStat, buildTrack } from '../model/MusicModels';
import { LibraryStore } from '../service/LibraryStore';
import { TrackItem } from '../components/TrackItem';
import { SkeletonTrackItem } from '../components/SkeletonTrackItem';
import { MusicPlayer } from '../player/MusicPlayer';import { toHttpsUrl } from '../utils/TextUtil';
import {
  DownloadManager,
  DownloadStartResult,
  WIFI_ONLY_BLOCKED
} from '../service/DownloadManager';
import { currentNetworkLabel } from '../utils/NetworkUtil';
import { promptAction } from '@kit.ArkUI';
import { SearchStateHolder } from '../service/SearchStateHolder';
import { SearchHistoryStore } from '../service/SearchHistoryStore';
import { CONTENT_END_OFFSET, STORE_SAFE_BOTTOM } from '../common/Constants';
import { showAppToast } from '../components/AppToast';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';

function parseDur(s: string | number | undefined): number {
  if (!s) {
    return 0;
  }
  if (typeof s === 'number') {
    return s;
  }
  const parts: number[] = s.split(':').map(Number);
  if (parts.length === 2) {
    return parts[0] * 60 + parts[1];
  }
  if (parts.length === 3) {
    return parts[0] * 3600 + parts[1] * 60 + parts[2];
  }
  return 0;
}

/** 搜索结果的标题里带 <em class="keyword"> 高亮标签，必须剥掉。 */
function stripHtml(s: string): string {
  if (!s) {
    return '';
  }
  return s.replace(/<[^>]+>/g, '');
}

function mapSearch(item: SearchResultItem): Track {
  return buildTrack({
    id: item.bvid,
    bvid: item.bvid,
    aid: String(item.aid),
    title: stripHtml(item.title),
    artist: item.author,
    coverUrl: toHttpsUrl(item.pic),
    duration: parseDur(item.duration),
    playCount: item.play
  });
}

function mapPopular(v: PopularVideo): Track {
  return buildTrack({
    id: v.bvid,
    bvid: v.bvid,
    aid: String(v.aid),
    title: stripHtml(v.title),
    artist: v.owner?.name ?? '',
    coverUrl: toHttpsUrl(v.pic),
    duration: v.duration
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
    title: stripHtml(v.title),
    artist: owner ? owner.name : '',
    coverUrl: toHttpsUrl(v.pic),
    duration: v.duration,
    playCount: stat ? stat.view : 0
  });
}

/**
 * 音乐中心：线上是下划线字段（music_title / music_id / related_archive），驼峰仅作兜底。
 *
 * ⚠️ **不要把 cid 传下去**：音乐中心的 `related_archive.cid` 是**音频 cid**，
 * 不属于该 bvid 的视频分 P（实测：BV1kQhz6fEMZ 的 pages[0].cid=42091416602，
 * 但 related_archive.cid=117309800781135 → playurl 返回 -404「啥都木有」）。
 * 传这个 cid 会让音乐中心所有条目都解析不出音源 —— 用户看到的就是
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
    coverUrl: coverUrl,
    // 音乐中心**自带时长**（在 `related_archive.duration`，单位秒，实测 140）。
    // 早先漏了这一步 → 列表里这一页签的条目全都没有时长（duration=0），
    // 连带歌词匹配的「时长加分」也拿不到（见 PlayerPage 的信息键注释）。
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
 * 追加合并并去重。
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

type SearchTab = 'search' | 'recommend' | 'ranking' | 'center';

/** 自动建歌单时使用的默认名（用户一个歌单都没有时） */
const DEFAULT_PLAYLIST_NAME: string = '我的歌单';

/** 搜索每页条数（跟着接口的 page_size） */
const SEARCH_PAGE_SIZE: number = 30;
const CENTER_PAGE_SIZE: number = 20;
/** 推荐流每页条数：实测 ps=20 时约 17 条有效（其余是登录引导/广告卡片） */
const RECOMMEND_FEED_PS: number = 20;
/** 排行榜一次拿全（实测 96 条）后前端分页，每次多放这么多条 */
const RANKING_PAGE_SIZE: number = 20;
/** 搜索历史面板最大高度（vp）：20 条一屏放不下，超出部分在面板内滚动 */
const HISTORY_PANEL_MAX_HEIGHT: number = 320;
const HISTORY_PANEL_GAP: number = 4;

/**
 * 骨架屏占位行：首屏整页用 8 行（贴合首屏可见条数），上拉加载更多用 3 行。
 * 只作 ForEach 的数据源，渲染时忽略内容。
 */
const SKELETON_ROW_INDEXES: number[] = [0, 1, 2, 3, 4, 5, 6, 7];
const SKELETON_MORE_INDEXES: number[] = [0, 1, 2];

@Component
export struct SearchPage {
  @State keyword: string = SearchStateHolder.keyword;
  @State tab: SearchTab = 'search';
  @State results: Track[] = SearchStateHolder.results;
  @State recommend: Track[] = [];
  @State ranking: Track[] = [];
  @State center: Track[] = [];
  @State loading: boolean = false;
  /** 是否已执行过一次搜索：用于区分「还没搜」和「搜了但没结果」，避免空态文案误导。 */
  @State searched: boolean = false;
  /** 推荐位待完成的数据源数量（热门 + 推荐两个源并行，互不影响） */
  @State recommendPending: number = 0;
  @State loadingRanking: boolean = false;
  /** 音乐中心待完成的数据源数量（综合榜 + 新歌榜并行，互不影响） */
  @State centerPending: number = 0;
  /** 底部安全区高度（vp）：根容器不再统一避让，列表末尾让位要自己叠上这一份 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中，见 build 里的 constraintSize */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;

  /** 最近搜索词（最新在前，最多 SEARCH_HISTORY_MAX 条）。持久化在 service/SearchHistoryStore.ts */
  @State history: string[] = [];
  /** 历史下拉是否展开：点搜索框展开，点遮罩 / 点词条 / 开始输入都收起 */
  @State showHistory: boolean = false;
  /**
   * 搜索框的实测高度（vp）：历史面板要贴着搜索框下沿弹出。
   * 不写死数字 —— TextInput 的高度随字体缩放变，用 `.onAreaChange` 量真实值。
   */
  @State searchBarHeight: number = 56;

  /** Refresh 组件的转圈状态（$$ 双向绑定，干完活必须落回 false 才会收起） */
  @State refreshing: boolean = false;
  /** 加载更多进行中（同一时刻只允许一个页签在加载） */
  @State loadingMore: boolean = false;
  /** 推荐流还有没有下一页（feed 返回 0 条或整页重复即到底） */
  @State recommendHasMore: boolean = true;
  /** 音乐中心还有没有下一页（综合榜某页返回 0 条即到底） */
  @State centerHasMore: boolean = true;

  private player: MusicPlayer = MusicPlayer.getInstance();
  /** 当前结果集对应的关键词：用户可能已经改了输入框，翻页必须用产生这批结果的那个词 */
  private searchKeyword: string = SearchStateHolder.keyword;
  /** 搜索结果已加载到第几页 / 共几页（0 表示未知，允许先试一页） */
  private searchPage: number = 1;
  private searchTotalPages: number = 0;
  /** 推荐流游标：每加载一页 +1（feed/rcmd 靠 fresh_idx 换内容） */
  private recommendFreshIdx: number = 1;
  private centerPage: number = 1;
  /** 排行榜全量（接口一次给全，展示侧按 RANKING_PAGE_SIZE 切片） */
  private rankingAll: Track[] = [];

  @State showPlaylistPicker: boolean = false;
  @State playlistOptions: Playlist[] = [];
  @State pickerTrack: Track | null = null;

  /** 「保存合集为歌单」弹层：展开成功后让用户确认歌单名（默认取音频标题） */
  @State showCollectionSaver: boolean = false;
  @State collectionName: string = '';
  @State pendingCollectionTracks: Track[] = [];

  aboutToAppear(): void {
    if (this.tab === 'search' && this.results.length === 0) {
      this.tab = 'recommend';
    }
    // 结果是从 holder 恢复的：页码未知（0），先允许通过「上拉」去探一页，
    // 探到空页自然停下——否则切回页签后永远加载不出更多。
    this.searchPage = 1;
    this.searchTotalPages = 0;
    // 搜索历史从 Preferences 读一次（SearchHistoryStore 内部有内存快照，读是同步的）
    this.history = SearchHistoryStore.getSearchHistory();
    this.loadHomeData();
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /**
   * 首屏数据。刻意拆成各自独立的任务：
   * 早期把两个源串行 await 后合并，任一源失败（如缺 buvid 导致 rcmd 返回 412）
   * 会把另一个源已拿到的数据一起丢掉，表现为"首页一片空白"。
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
      const list: RankingVideoItem[] = await BilibiliApi.getMusicRankingV2();
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
  }

  /** 两个数据源各自独立：串行 await 后合并会把已成功那份一起丢掉。 */
  private loadCenter(): void {
    this.resetCenter();
    this.loadCenterRank();
    this.loadCenterNew();
  }

  private appendCenter(list: Track[]): void {
    this.center = mergeTracks(this.center, list);
  }

  private async loadCenterRank(): Promise<void> {
    try {
      const hot: MusicCenterItem[] = await BilibiliApi.getMusicComprehensiveRank(CENTER_PAGE_SIZE, 1);
      this.appendCenter(mapMusicCenterList(hot));
    } catch (e) {
      console.error(`loadCenterRank failed: ${JSON.stringify(e)}`);
    } finally {
      this.centerPending = this.centerPending - 1;
    }
  }

  private async loadCenterNew(): Promise<void> {
    try {
      const fresh: MusicCenterItem[] = await BilibiliApi.getNewMusic();
      this.appendCenter(mapMusicCenterList(fresh));
    } catch (e) {
      console.error(`loadCenterNew failed: ${JSON.stringify(e)}`);
    } finally {
      this.centerPending = this.centerPending - 1;
    }
  }

  private currentListLength(): number {
    if (this.tab === 'recommend') {
      return this.recommend.length;
    }
    if (this.tab === 'ranking') {
      return this.ranking.length;
    }
    if (this.tab === 'center') {
      return this.center.length;
    }
    return this.results.length;
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
   * 当前页签还有没有下一页。
   * 四个源的分页能力不同，所以判据也不同（详见文件头的说明）。
   */
  private hasMore(): boolean {
    if (this.tab === 'search') {
      if (this.results.length === 0) {
        return false;
      }
      // 页数未知（0，如从 holder 恢复）时先允许试一页，返回空页会自动停
      if (this.searchTotalPages <= 0) {
        return true;
      }
      return this.searchPage < this.searchTotalPages;
    }
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

  /** 空态里的「点击重试」：只重载当前页签，不要把四个源都刷一遍 */
  private reloadCurrentTab(): void {
    if (this.tab === 'search') {
      this.doSearch();
    } else if (this.tab === 'recommend') {
      this.loadHomeRecommend();
    } else if (this.tab === 'ranking') {
      this.loadRanking();
    } else {
      this.loadCenter();
    }
  }

  private handleRefresh(): void {
    if (this.tab === 'search') {
      this.refreshSearch();
    } else if (this.tab === 'recommend') {
      this.refreshRecommend();
    } else if (this.tab === 'ranking') {
      this.refreshRanking();
    } else {
      this.refreshCenter();
    }
  }

  private async refreshSearch(): Promise<void> {
    const kw: string = this.searchKeyword.trim();
    if (kw.length === 0) {
      this.refreshing = false;
      this.toast('还没有搜索内容', 1200);
      return;
    }
    try {
      const resp: BilibiliApi.SearchResponse = await BilibiliApi.searchVideo(kw, 1, SEARCH_PAGE_SIZE);
      const list: Track[] = (resp.result || []).map(mapSearch);
      this.results = list;
      this.searchPage = 1;
      this.searchTotalPages = resp.numPages > 0 ? resp.numPages : 0;
      this.searched = true;
      SearchStateHolder.save(kw, list);
    } catch (e) {
      console.error(`refreshSearch failed: ${JSON.stringify(e)}`);
      this.toast('刷新失败，请稍后重试', 1800);
    } finally {
      this.refreshing = false;
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
   * List 的 onReachEnd。
   * 三重闸门：正在刷新 / 正在加载更多 / 已经没有下一页，任一命中都直接返回，
   * 否则短列表在首帧布局时就会连环触发，一口气把后面几页全拉下来。
   */
  private onReachEnd(): void {
    if (this.refreshing || this.loadingMore || this.loading) {
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
    if (this.tab === 'search') {
      this.loadMoreSearch();
    } else if (this.tab === 'recommend') {
      this.loadMoreRecommend();
    } else if (this.tab === 'ranking') {
      this.revealMoreRanking();
    } else {
      this.loadMoreCenter();
    }
  }

  private async loadMoreSearch(): Promise<void> {
    const kw: string = this.searchKeyword.trim();
    if (kw.length === 0) {
      return;
    }
    this.loadingMore = true;
    try {
      const next: number = this.searchPage + 1;
      const resp: BilibiliApi.SearchResponse = await BilibiliApi.searchVideo(kw, next, SEARCH_PAGE_SIZE);
      const list: Track[] = (resp.result || []).map(mapSearch);
      this.searchPage = next;
      this.results = mergeTracks(this.results, list);
      SearchStateHolder.save(kw, this.results);
      if (list.length === 0) {
        // 空页 = 到底：把总页数对齐到当前页，hasMore() 自然返回 false
        this.searchTotalPages = next;
      } else if (resp.numPages > 0) {
        this.searchTotalPages = resp.numPages;
      }
    } catch (e) {
      console.error(`loadMoreSearch failed: ${JSON.stringify(e)}`);
      this.toast('加载更多失败，请稍后重试', 1800);
    } finally {
      this.loadingMore = false;
    }
  }

  private async loadMoreRecommend(): Promise<void> {
    this.loadingMore = true;
    try {
      const idx: number = this.recommendFreshIdx + 1;
      const feed: PopularVideo[] = await BilibiliApi.getRecommendedFeed(idx, RECOMMEND_FEED_PS);
      this.recommendFreshIdx = idx;
      const before: number = this.recommend.length;
      this.recommend = mergeTracks(this.recommend, feed.map(mapPopular));
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
    const next: number = Math.min(this.ranking.length + RANKING_PAGE_SIZE, this.rankingAll.length);
    this.ranking = this.rankingAll.slice(0, next);
  }

  private async loadMoreCenter(): Promise<void> {
    this.loadingMore = true;
    try {
      const next: number = this.centerPage + 1;
      const list: MusicCenterItem[] =
        await BilibiliApi.getMusicComprehensiveRank(CENTER_PAGE_SIZE, next);
      const before: number = this.center.length;
      this.center = mergeTracks(this.center, mapMusicCenterList(list));
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
   * 加载中 / 空数据 / 搜索空态的统一展示区。
   * 加载中：骨架屏（形状贴合 TrackItem 的 40 圆头像 + 两条文字条，shimmer 扫光），
   * 替换原先的 LoadingProgress 转圈——占位形状对齐内容布局，加载完成内容「落位」不跳。
   */
  @Builder
  HomeStateArea(): void {
    if (this.homeLoading() && this.currentListLength() === 0) {
      this.SkeletonArea()
    } else if (!this.homeLoading() && this.currentListLength() === 0) {
      Column() {
        if (this.tab === 'search') {
          Text(this.searched ? '没有找到相关内容，换个关键词试试' : '输入关键词开始搜索')
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
        } else {
          Text('暂无数据')
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
          Button('点击重试')
            .fontSize(13)
            .margin({ top: 12 })
            .onClick((): void => {
              this.reloadCurrentTab();
            })
        }
      }
      .margin({ top: 48 })
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
        SkeletonTrackItem()
      }, (_i: number): string => `sk_${_i}`)
    }
    .width('100%')
  }

  private async doSearch(): Promise<void> {
    const kw: string = this.keyword.trim();
    if (!kw) {
      this.toast('请输入搜索关键词', 1500);
      return;
    }
    this.loading = true;
    this.tab = 'search';
    this.showHistory = false;
    // 先记历史再发请求：被风控 / 断网导致搜不出结果时，这次搜索同样算「搜过」，
    // 否则用户会遇到「明明搜过却不在历史里」。
    this.history = SearchHistoryStore.addSearchHistory(kw);
    try {
      const resp: BilibiliApi.SearchResponse = await BilibiliApi.searchVideo(kw, 1, SEARCH_PAGE_SIZE);
      this.results = (resp.result || []).map(mapSearch);
      this.searchKeyword = kw;
      this.searchPage = 1;
      this.searchTotalPages = resp.numPages > 0 ? resp.numPages : 0;
      this.searched = true;
      SearchStateHolder.save(kw, this.results);
      if (this.results.length === 0) {
        // 搜索接口被风控时也是返回 0 条（HTTP 200 / code 0），明确提示，别让人以为没搜
        this.toast('没有搜索到结果，请换个关键词或稍后再试', 2000);
      }
    } catch (e) {
      this.searched = true;
      console.error(`doSearch failed: ${JSON.stringify(e)}`);
      this.toast('搜索失败，请检查网络或登录态', 2000);
    } finally {
      this.loading = false;
    }
  }

  private showTrackMenu(track: Track): void {
    this.getUIContext()
      .getPromptAction()
      .showDialog({
        title: track.title,
        message: '选择操作',
        buttons: [
          { text: '加入队列', color: $r('app.color.text_secondary') },
          { text: '加入歌单', color: $r('app.color.text_secondary') },
          { text: '保存合集为歌单', color: $r('app.color.text_secondary') },
          { text: '下载', color: $r('app.color.text_secondary') }
        ]
      })
      .then((resp): void => {
        if (resp.index === 0) {
          this.player.addToQueue(track);
          this.toast('已加入播放队列', 1500);
        } else if (resp.index === 1) {
          this.openPlaylistPicker(track);
        } else if (resp.index === 2) {
          this.loadCollection(track);
        } else if (resp.index === 3) {
          this.startDownload(track);
        }
      })
      .catch((e: Error): void => {
        console.error(`showTrackMenu failed: ${e.message}`);
      });
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
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '仅 WiFi 下载',
        message: `${WIFI_ONLY_BLOCKED}\n当前网络：${currentNetworkLabel()}`,
        buttons: [
          { text: '取消', color: $r('app.color.text_secondary') },
          { text: '继续下载', color: $r('app.color.brand_deep') }
        ]
      }).then((resp: promptAction.ShowDialogSuccessResponse): void => {
        if (resp.index === 1) {
          this.requestDownload(track, true);
        }
      }).catch((e: Error): void => {
        console.error(`cellular download dialog failed: ${e.message}`);
      });
    } catch (e) {
      console.error('show cellular-download dialog threw');
    }
  }

  /**
   * 把歌曲加入指定歌单。
   *
   * 一个歌单都没有时**自动建一个再放进去**：早期实现是弹一句「还没有歌单，先去歌单页新建一个」
   * 把用户挡回去，等于让用户为了收藏一首歌先跳页建单、再回来重新找到这首——
   * 纯粹的摩擦。现在的行为是「点加入歌单 → 自动创建歌单并加入」。
   */
  private openPlaylistPicker(track: Track): void {
    const options: Playlist[] = LibraryStore.getPlaylists();
    if (options.length === 0) {
      this.createPlaylistAndAdd(track);
      return;
    }
    this.playlistOptions = options;
    this.pickerTrack = track;
    this.showPlaylistPicker = true;
  }

  /** 没有任何歌单时的兜底：新建默认歌单并直接把这首放进去 */
  private createPlaylistAndAdd(track: Track): void {
    const name: string = this.nextPlaylistName();
    const created: Playlist = LibraryStore.createPlaylist({ name: name });
    const updated: Playlist | null = LibraryStore.addTrackToPlaylist(created.id, track);
    this.toast(updated ? `已新建歌单「${name}」并加入` : '加入歌单失败', 1800);
  }

  /** 弹层里的「新建歌单并加入」：同样省掉一次跳转 */
  private createPlaylistFromPicker(): void {
    const track: Track | null = this.pickerTrack;
    this.showPlaylistPicker = false;
    this.pickerTrack = null;
    if (!track) {
      return;
    }
    this.createPlaylistAndAdd(track);
  }

  /** 生成不与现有歌单重名的默认名：我的歌单 / 我的歌单 2 / 我的歌单 3 … */
  private nextPlaylistName(): string {
    const names: Set<string> = new Set<string>(
      LibraryStore.getPlaylists().map((p: Playlist): string => p.name)
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
    this.showPlaylistPicker = false;
    this.pickerTrack = null;
    if (!track) {
      return;
    }
    const updated: Playlist | null = LibraryStore.addTrackToPlaylist(p.id, track);
    this.toast(updated ? `已加入「${p.name}」` : '加入歌单失败', 1600);
  }

  /**
   * 把多 P 合集整个保存为歌单。
   * 先展开分 P，成功后弹层让用户确认歌单名（默认取音频标题），再一次性建单入库。
   */
  private loadCollection(track: Track): void {
    const bvid: string = track.bvid ? track.bvid : track.id;
    if (bvid.length === 0 || bvid.indexOf('BV') !== 0) {
      this.toast('该条目不是视频合集', 1500);
      return;
    }
    this.toast('正在获取合集…', 1200);
    BilibiliApi.expandVideoParts(bvid, track)
      .then((list: Track[]): void => {
        if (list.length <= 1) {
          this.toast('该视频只有一个分 P', 1500);
          return;
        }
        this.pendingCollectionTracks = list;
        this.collectionName = track.title;
        this.showCollectionSaver = true;
      })
      .catch((e: Error): void => {
        console.error(`loadCollection failed: ${JSON.stringify(e)}`);
        this.toast('合集加载失败', 1800);
      });
  }

  /** 弹层「保存」：按用户输入的名字建歌单（空名回退默认名），把合集全部曲目一次写入 */
  private confirmSaveCollection(): void {
    const list: Track[] = this.pendingCollectionTracks;
    this.showCollectionSaver = false;
    this.pendingCollectionTracks = [];
    if (list.length === 0) {
      return;
    }
    const input: string = this.collectionName.trim();
    const name: string = input.length > 0 ? input : this.nextPlaylistName();
    const created: Playlist = LibraryStore.createPlaylist({
      name: name,
      coverUrl: list[0].coverUrl
    });
    created.tracks = list;
    LibraryStore.updatePlaylist(created);
    this.toast(`已保存歌单「${name}」，共 ${list.length} 首`, 2000);
  }

  private cancelSaveCollection(): void {
    this.showCollectionSaver = false;
    this.pendingCollectionTracks = [];
  }

  build() {
    Stack() {
      Column() {
        Row() {
          // text 用 $$ 双向绑定：点历史词条是**代码改 this.keyword**，
          // 单向绑定时输入框不一定跟着刷新（用户输入侧有 onChange 手动同步，但外部改值没有回写路径）
          TextInput({ placeholder: '搜索歌曲、UP主、歌单', text: $$this.keyword })
            .layoutWeight(1)
            .onSubmit((): void => {
              this.doSearch();
            })
            // 点击 / 获焦都展开历史：已获焦时再点一次不会触发 onFocus，只靠 onClick 补
            .onClick((): void => {
              this.openHistory();
            })
            .onFocus((): void => {
              this.openHistory();
            })
            .onChange((v: string): void => {
              this.keyword = v;
              // 开始输入就收起历史，别让面板盖着结果
              this.showHistory = false;
            })
          Button('搜索')
            .height(44)
            .backgroundColor($r('app.color.bili_pink'))
            .fontColor($r('app.color.brand_on'))
            .onClick((): void => {
              this.doSearch();
            })
            .margin({ left: 8 })
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        // 量出搜索框真实高度：历史面板用它定位到正下方
        .onAreaChange((_old: Area, cur: Area): void => {
          const h: number = cur.height as number;
          if (h > 0) {
            this.searchBarHeight = h;
          }
        })

        Row() {
          this.TabButton('搜索', 'search')
          this.TabButton('推荐', 'recommend')
          this.TabButton('排行榜', 'ranking')
          this.TabButton('音乐中心', 'center')
        }
        .padding({ left: 12, right: 12 })

        if (this.loading) {
          // 搜索加载中：同款骨架屏（搜索页签没有 homeLoading 状态，单独挂）
          this.SkeletonArea()
        }

        this.HomeStateArea()

        // 下拉刷新 + 上拉加载更多都挂在 List 上：
        // Refresh 只包住列表（搜索框/页签不参与下拉），否则在输入框上往下拉也会触发刷新。
        Refresh({ refreshing: $$this.refreshing }) {
          List() {
            if (this.tab === 'search') {
              ForEach(
                this.results,
                (t: Track, index: number): void => {
                  ListItem() {
                    TrackItem({
                      track: t,
                      entranceIndex: index,
                      onPlay: (tr: Track): void => this.player.playNow(tr),
                      onMore: (tr: Track): void => this.showTrackMenu(tr)
                    })
                  }
                },
                (t: Track): string => t.id
              )
            } else if (this.tab === 'recommend') {
              ForEach(
                this.recommend,
                (t: Track, index: number): void => {
                  ListItem() {
                    TrackItem({
                      track: t,
                      entranceIndex: index,
                      onPlay: (tr: Track): void => this.player.playNow(tr),
                      onMore: (tr: Track): void => this.showTrackMenu(tr)
                    })
                  }
                },
                (t: Track): string => t.id
              )
            } else if (this.tab === 'ranking') {
              ForEach(
                this.ranking,
                (t: Track, index: number): void => {
                  ListItem() {
                    TrackItem({
                      track: t,
                      entranceIndex: index,
                      onPlay: (tr: Track): void => this.player.playNow(tr),
                      onMore: (tr: Track): void => this.showTrackMenu(tr)
                    })
                  }
                },
                (t: Track): string => t.id
              )
            } else {
              ForEach(
                this.center,
                (t: Track, index: number): void => {
                  ListItem() {
                    TrackItem({
                      track: t,
                      entranceIndex: index,
                      onPlay: (tr: Track): void => this.player.playNow(tr),
                      onMore: (tr: Track): void => this.showTrackMenu(tr)
                    })
                  }
                },
                (t: Track): string => t.id
              )
            }

            // 加载更多状态条：只在这一屏有内容时出现，避免空列表底部多出一条空白
            if (this.currentListLength() > 0) {
              ListItem() {
                Column() {
                  if (this.loadingMore) {
                    // 加载更多：3 行同构骨架占位替代「转圈 + 加载中…」，
                    // 与首屏骨架同一套视觉语言；新内容到达后骨架被真实条目顶替。
                    ForEach(SKELETON_MORE_INDEXES, (_i: number): void => {
                      SkeletonTrackItem()
                    }, (_i: number): string => `more_sk_${_i}`)
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
                .padding({ top: 14, bottom: 14 })
                .justifyContent(FlexAlign.Center)
              }
            }
          }
          .width('100%')
          .height('100%')
          // 底部悬浮页签让位：列表末尾可滚动至悬浮条上方，不被遮挡。
          // 页签栏自己抬高了 safeBottom（见 Index.ets），列表末尾要跟着多让这么多，
          // 否则最后一项会被页签栏 / 迷你条压住。
          .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
          .onReachEnd((): void => {
            this.onReachEnd();
          })        }
        .layoutWeight(1)
        .width('100%')
        .onRefreshing((): void => {
          this.handleRefresh();
        })
      }
      .width('100%')
      .height('100%')
      // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp，见 BreakpointConstants）。
      // 根 Stack 默认居中对齐，直接给内容列挂上限即可，不需要额外包一层。
      .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })

      // 搜索历史下拉：遮罩 + 紧贴搜索框正下方的面板。
      // 遮罩从搜索框下沿开始铺满 → 点任意空白处收起，而搜索框自身保持可点；
      // 面板声明在遮罩之后 ＝ 叠在遮罩上层，不然点词条会先被遮罩吃掉。
      if (this.showHistory) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.scrim_light'))
          // 只盖搜索框**下方**：搜索框始终可点（点它不收起面板，方便直接改词，
          // 一开始输入 onChange 就会收起）。若铺满整页，「再点一次搜索框」会变成收起，别扭。
          .position({ x: 0, y: this.searchBarHeight })
          .onClick((): void => {
            this.closeHistory();
          })

        // 面板宿主：与内容列同宽收窄居中，HistoryPanel 在其内部 position 定位，
        // 左右才能与收窄后的搜索框对齐（直接挂 Stack 上会贴到屏幕左缘）。
        // hitTestBehavior(None)：宿主自身不参与命中测试，面板以外的点击
        // 穿透到下层全屏遮罩，照常收起历史。
        Column() {
          this.HistoryPanel()
        }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.showPlaylistPicker) {
        Column() {
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.scrim'))
        .onClick((): void => {
          this.showPlaylistPicker = false;
          this.pickerTrack = null;
        })
        .justifyContent(FlexAlign.Center)

        Column() {
          Text('加入歌单')
            .fontSize(18)
            .fontColor($r('app.color.text_primary'))
            .margin({ bottom: 8 })
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
              .fontColor($r('app.color.brand_deep'))
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
              (p: Playlist): string => p.id
            )
          }
          .width('100%')
          .constraintSize({ maxHeight: 260 })
          Button('取消', { type: ButtonType.Normal })
            .width('100%')
            .height(44)
            .backgroundColor($r('app.color.bg_divider'))
            .fontColor($r('app.color.text_primary'))
            .margin({ top: 12 })
            .onClick((): void => {
              this.showPlaylistPicker = false;
              this.pickerTrack = null;
            })
        }
        .padding(20)
        .width('80%')
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(12)
      }

      // 「保存合集为歌单」弹层：遮罩 + 名称确认框，歌单名默认取音频标题
      if (this.showCollectionSaver) {
        Column() {
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.scrim'))
        .onClick((): void => {
          this.cancelSaveCollection();
        })
        .justifyContent(FlexAlign.Center)

        Column() {
          Text('保存合集为歌单')
            .fontSize(18)
            .fontColor($r('app.color.text_primary'))
            .margin({ bottom: 8 })
          Text(`共 ${this.pendingCollectionTracks.length} 首`)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ bottom: 12 })
          TextInput({ placeholder: '输入歌单名称', text: $$this.collectionName })
            .width('100%')
            .height(44)
            .fontSize(15)
            .onChange((v: string): void => {
              this.collectionName = v;
            })
          Row({ space: 12 }) {
            Button('取消', { type: ButtonType.Normal })
              .layoutWeight(1)
              .height(44)
              .backgroundColor($r('app.color.bg_divider'))
              .fontColor($r('app.color.text_primary'))
              .onClick((): void => {
                this.cancelSaveCollection();
              })
            Button('保存', { type: ButtonType.Normal })
              .layoutWeight(1)
              .height(44)
              .backgroundColor($r('app.color.bili_pink'))
              .fontColor($r('app.color.brand_on'))
              .onClick((): void => {
                this.confirmSaveCollection();
              })
          }
          .width('100%')
          .margin({ top: 16 })
        }
        .padding(20)
        .width('80%')
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(12)
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 点搜索框：有历史才展开（没有历史弹一个空面板没意义） */
  private openHistory(): void {
    this.history = SearchHistoryStore.getSearchHistory();
    this.showHistory = this.history.length > 0;
  }

  private closeHistory(): void {
    this.showHistory = false;
  }

  private useHistoryWord(word: string): void {
    this.keyword = word;
    this.closeHistory();
    this.doSearch();
  }

  private clearHistory(): void {
    SearchHistoryStore.clearSearchHistory();
    this.history = SearchHistoryStore.getSearchHistory();
    this.showHistory = false;
    this.toast('已删除搜索记录', 1500);
  }

  /**
   * 搜索历史下拉面板。
   *
   * 不接收任何参数：带参 @Builder 是「按值传递」，参数取自状态变量时状态变化不会刷新其内部 UI
   * （本项目在页签按钮上踩过），所以这里直接读 `this.history` / `this.showHistory`。
   *
   * 位置用 `.position()` 绝对定位贴到搜索框正下方：`position` 脱离父容器布局流，
   * 因此面板展开不会把下面的页签栏和列表推走（面板最大高度另由约束限制，内部滚动）。
   */
  @Builder
  HistoryPanel(): void {
    Column() {
      Column() {
        Text('最近搜索')
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 4 })

        List() {
          ForEach(this.history, (word: string): void => {
            ListItem() {
              Text(word)
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .stateStyles({
                  pressed: { .backgroundColor($r('app.color.press_overlay')) },
                  normal: { .backgroundColor(Color.Transparent) }
                })
                .onClick((): void => {
                  this.useHistoryWord(word);
                })
            }
          }, (word: string): string => word)

          ListItem() {
            Text('删除搜索记录')
              .fontSize(16)
              .fontColor($r('app.color.brand_deep'))
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .border({ width: { top: 0.5 }, color: $r('app.color.bg_divider') })
              .stateStyles({
                pressed: { .backgroundColor($r('app.color.press_overlay')) },
                normal: { .backgroundColor(Color.Transparent) }
              })
              .onClick((): void => {
                this.clearHistory();
              })
          }
        }
        .width('100%')
        .constraintSize({ maxHeight: HISTORY_PANEL_MAX_HEIGHT })
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(12)
      .border({ width: 0.5, color: $r('app.color.bg_divider') })
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
    .position({ x: 0, y: this.searchBarHeight + HISTORY_PANEL_GAP })
  }

  /**
   * 页签按钮。
   *
   * 只接收**静态字面量**参数，选中态 `this.tab === target` 在 Builder 内部现算：
   * 带参 @Builder 是「按值传递」，参数取自状态变量/状态派生值时状态变化不会刷新其内部 UI
   * （本项目踩过：同一个 Row 里一半控件正常一半失灵）。参数静态、状态在内部读就没这个问题。
   */
  @Builder
  TabButton(label: string, target: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.tab === target ? $r('app.color.brand_deep') : $r('app.color.text_secondary'))
      // 触达铁律：视觉是小 chip，命中区撑到 44 高（13 号字行高 18 + 上下各 13 padding）
      .padding({ left: 14, right: 14, top: 13, bottom: 13 })
      .borderRadius(22)
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.press_overlay')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .onClick((): void => {
        this.switchTab(target);
      })
  }

  private switchTab(target: string): void {
    // 切页签时收起历史面板（页签行在遮罩上层仍可点，不收起会一直盖着结果）
    this.showHistory = false;
    if (target === 'search') {
      // 已搜过（哪怕 0 条）就别再自动重搜，否则每次切回来都空转一次
      if (this.results.length === 0 && this.keyword.trim() && !this.searched) {
        this.doSearch();
      } else {
        this.tab = 'search';
      }
    } else if (target === 'recommend') {
      this.tab = 'recommend';
    } else if (target === 'ranking') {
      this.tab = 'ranking';
    } else if (target === 'center') {
      this.tab = 'center';
    }
  }
}
