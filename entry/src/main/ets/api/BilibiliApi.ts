/**
 * B 站 API 服务层（原生 ArkTS 版）。
 * 移植自原 React 版 src/services/bilibiliApi.ts，使用 HttpUtil + WBI 签名。
 * 所有请求自动携带 Referer / buvid Cookie（HttpUtil 统一处理）。
 *
 * 注意：登录相关接口（扫码 / 密码 / 短信 / 极验）**已整体移除**，本 App 是纯匿名访问。
 * buvid 能力（设备指纹）与登录无关，已迁至 `service/BiliDevice.ts`，别在这里重新引入。
 */

import { HttpUtil } from '../utils/HttpUtil';
import { toHttpsUrl } from '../utils/TextUtil';
import { encodeWbi } from './WbiSign';
import {
  AUDIO_Q_64K,
  AUDIO_Q_132K,
  AUDIO_Q_192K,
  AUDIO_Q_DOLBY,
  AUDIO_Q_HIRES,
  BILI_API
} from '../common/Constants';
import {
  AudioStream,
  PlayUrlData,
  SearchResultItem,
  Track,
  TrackSource,
  VideoDetail,
  VideoOwner,
  VideoPageInfo,
  VideoStat,
  buildTrack
} from '../model/MusicModels';

export { SearchResultItem };

export class BiliApiError extends Error {
  code: number;
  path: string;

  constructor(code: number, message: string, path: string) {
    super(`BiliBili API Error [${code}]: ${message} (${path})`);
    this.code = code;
    this.path = path;
  }
}

interface BiliEnvelope<T> {
  code: number;
  message: string;
  data: T;
}

async function biliFetch<T>(path: string, params?: Record<string, string | number>): Promise<T> {
  const data: BiliEnvelope<T> = await HttpUtil.requestJson<BiliEnvelope<T>>(`${BILI_API}${path}`, {
    params: params
  });
  if (data.code !== 0) {
    throw new BiliApiError(data.code, data.message, path);
  }
  return data.data;
}

//
// 为什么必须有：`extractAudioFromVideo` 是「view → playurl」**两次串行请求**，
// 任意一次瞬时失败，整首歌就被判定为「无法播放」。
//
// 而线上对照实验证明服务端这条链路 100% 正常：
//   官方 buvid / 本地伪 buvid / 完全不带 Cookie → 全部 code=0 且 dash.audio 有 3 条；
//   并发 8 路（音乐中心 + 推荐 + 热门 + view + playurl×2 + nav + spi）→ 全部成功；
//   同一 buvid 连续 6 次 playurl → 每次都是 code=0，0.15s 返回。
// 所以客户端报「无法播放」只可能来自**瞬态**：连接冷启动、HTTP 连接池被同刻的
// 其它请求挤满、Wi-Fi/蜂窝切换瞬间被拒、或 B 站短时的 -352 / -412 / -509 限流。
//
// 这类失败的特征恰恰是「隔几百毫秒再发一次就好」——用户描述的
// 「点一次失败、点两次有概率、点三次大概率能播」就是它在手动重试。
// 与其让用户点三次，不如在这里自动退避重试。

/** 退避间隔（ms）：最多 3 次重试、合计约 2.45s，足以覆盖绝大多数瞬态抖动 */
const SOURCE_RETRY_DELAYS_MS: number[] = [250, 700, 1500];
/** 值得重试的业务码：B 站瞬时风控 / 限流，隔一会儿往往自行恢复 */
const RETRYABLE_BIZ_CODES: number[] = [-352, -412, -509, -799];

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

/**
 * 判定错误是否值得重试。
 * 确定性缺陷（无音轨 / 数据本身缺失）重试多少次结果都一样，直接放弃，
 * 免得把「这首歌真的没有音频」拖慢成三倍等待。
 */
function isRetryableFetchError(e: Object): boolean {
  if (e instanceof BiliApiError) {
    return RETRYABLE_BIZ_CODES.indexOf(e.code) >= 0;
  }
  if (e instanceof Error) {
    const msg: string = e.message;
    if (msg.indexOf('No audio stream') >= 0) {
      return false;
    }
    // 网络层错误（超时 / 连接被拒 / DNS 失败 / 响应解析失败）都值得重试
    return true;
  }
  return true;
}

/**
 * 带退避重试的 biliFetch。
 * **只用于「决定这首歌能不能出声」的音源解析链路**，不要拿去包普通列表接口：
 * 列表失败用户会自己下拉刷新，音源失败则完全没有替代路径。
 */
async function biliFetchRetry<T>(
  path: string,
  params: Record<string, string | number>,
  tag: string
): Promise<T> {
  const total: number = SOURCE_RETRY_DELAYS_MS.length;
  for (let attempt = 0; attempt <= total; attempt++) {
    try {
      return await biliFetch<T>(path, params);
    } catch (err) {
      const left: number = total - attempt;
      if (left <= 0 || !isRetryableFetchError(err)) {
        throw err;
      }
      const delay: number = SOURCE_RETRY_DELAYS_MS[attempt];
      console.warn(`${tag} failed (attempt ${attempt + 1}/${total + 1}), retry in ${delay}ms: ${JSON.stringify(err)}`);
      await sleep(delay);
    }
  }
  // 循环内要么 return 要么 throw，这里只是让类型收敛
  throw new Error(`${tag} failed after retry`);
}

export interface SearchResponse {
  seid: string;
  page: number;
  pagesize: number;
  numResults: number;
  numPages: number;
  result: SearchResultItem[];
}

export async function searchVideo(
  keyword: string,
  page: number = 1,
  pageSize: number = 20
): Promise<SearchResponse> {
  const query: string = await encodeWbi({
    search_type: 'video',
    keyword: keyword,
    page: page,
    page_size: pageSize
  });
  const data: BiliEnvelope<SearchResponse> = await HttpUtil.requestJson<BiliEnvelope<SearchResponse>>(
    `${BILI_API}/x/web-interface/wbi/search/type?${query}`
  );
  if (data.code !== 0) {
    throw new BiliApiError(data.code, data.message, '/x/web-interface/wbi/search/type');
  }
  return data.data;
}

export interface UserSearchResult {
  type: string;
  mid: number;
  uname: string;
  usign: string;
  fans: number;
  videos: number;
  upic: string;
  level: number;
}

export interface UserSearchResponse {
  numResults: number;
  numPages: number;
  result: UserSearchResult[];
}

export async function searchUser(
  keyword: string,
  page: number = 1,
  pageSize: number = 20
): Promise<UserSearchResponse> {
  const query: string = await encodeWbi({
    search_type: 'bili_user',
    keyword: keyword,
    page: page,
    page_size: pageSize
  });
  const data: BiliEnvelope<UserSearchResponse> = await HttpUtil.requestJson<BiliEnvelope<UserSearchResponse>>(
    `${BILI_API}/x/web-interface/wbi/search/type?${query}`
  );
  if (data.code !== 0) {
    throw new BiliApiError(data.code, data.message, '/x/web-interface/wbi/search/type');
  }
  return data.data;
}

export interface SpaceVideo {
  bvid: string;
  aid: number;
  title: string;
  pic: string;
  length: string;
  play: number;
  created: number;
  description: string;
  author: string;
}

export interface SpaceArcSearchData {
  list: { vlist: SpaceVideo[] };
  page: { pn: number; ps: number; count: number };
}

export async function getUserVideos(
  mid: number,
  page: number = 1,
  pageSize: number = 30,
  order: string = 'pubdate'
): Promise<SpaceArcSearchData> {
  const query: string = await encodeWbi({
    mid: mid,
    pn: page,
    ps: pageSize,
    order: order,
    platform: 'web'
  });
  const data: BiliEnvelope<SpaceArcSearchData> = await HttpUtil.requestJson<BiliEnvelope<SpaceArcSearchData>>(
    `${BILI_API}/x/space/wbi/arc/search?${query}`
  );
  if (data.code !== 0) {
    throw new BiliApiError(data.code, data.message, '/x/space/wbi/arc/search');
  }
  return data.data;
}

// ===== 音源解析缓存 =====
//
// 「点歌到出声」的链路 = view + playurl 两次串行请求 + 播放器缓冲，全串在一起
// 就是点歌后 1~3 秒的干等。其中两类结果短时间内是稳定的：
//   · view：同一 bvid 的分 P 列表 / 元数据分钟级内不会变；
//   · playurl：解析出的直链带签名 token，有效期远长于一次播放会话。
// 命中缓存时整个解析直接跳过（重播 / 切下一首近乎秒开）；未命中走原链路，行为不变。
// 直链真的过期（AVPlayer 报 error）时，由 MusicPlayer.reloadCurrentSource
// 以 refresh=true 强制刷新兜底 —— 缓存永远不会把「过期链接」变成死胡同。

/** 缓存条目：值 + 写入时间戳 */
interface CacheEntry<T> {
  value: T;
  cachedAt: number;
}

const VIEW_CACHE_TTL_MS: number = 10 * 60 * 1000;
const SOURCE_CACHE_TTL_MS: number = 30 * 60 * 1000;
const VIEW_CACHE_MAX: number = 40;
const SOURCE_CACHE_MAX: number = 120;

const viewCache: Map<string, CacheEntry<VideoDetail>> = new Map<string, CacheEntry<VideoDetail>>();
const sourceCache: Map<string, CacheEntry<TrackSource>> = new Map<string, CacheEntry<TrackSource>>();

function cacheGet<T>(cache: Map<string, CacheEntry<T>>, key: string, ttlMs: number): T | null {
  const hit: CacheEntry<T> | undefined = cache.get(key);
  if (hit === undefined) {
    return null;
  }
  if (Date.now() - hit.cachedAt > ttlMs) {
    cache.delete(key);
    return null;
  }
  return hit.value;
}

function cachePut<T>(cache: Map<string, CacheEntry<T>>, key: string, value: T, maxEntries: number): void {
  // 超限时整体清空而不是逐条淘汰：条目都只有几 KB，简单粗暴既不会内存失控，
  // 也完全避开迭代器语法的兼容性风险。
  if (cache.size >= maxEntries) {
    cache.clear();
  }
  cache.set(key, { value: value, cachedAt: Date.now() });
}

export async function getVideoDetail(bvid: string, refresh: boolean = false): Promise<VideoDetail> {
  if (!refresh) {
    const hit: VideoDetail | null = cacheGet<VideoDetail>(viewCache, bvid, VIEW_CACHE_TTL_MS);
    if (hit !== null) {
      return hit;
    }
  }
  // 走重试版：view 是「这首歌能不能出声」链路的第一个请求，
  // 它抖动一次整首就废，所以必须给它退避重试（理由见 biliFetchRetry 上方注释）。
  const detail: VideoDetail = await biliFetchRetry<VideoDetail>('/x/web-interface/view', { bvid: bvid }, 'view');
  cachePut<VideoDetail>(viewCache, bvid, detail, VIEW_CACHE_MAX);
  return detail;
}

export interface PartTitle {
  title: string;
  artist: string;
}

/** 分 P 标题前缀："001."、"01 -"、"P1 " 等序号 */
const PART_INDEX: RegExp = /^\s*[Pp]?\d{1,3}\s*[.、:：\-_|]*\s*/;
/** "周杰伦-晴天" → 歌手「周杰伦」+ 标题「晴天」 */
const PART_SPLIT: RegExp = /^(.{1,16}?)\s*[-–—]\s*(.+)$/;

export function splitPartTitle(part: string): PartTitle {
  if (!part) {
    return { title: '', artist: '' };
  }
  const s: string = part.trim().replace(PART_INDEX, '');
  const m: RegExpMatchArray | null = s.match(PART_SPLIT);
  if (m) {
    return { artist: m[1].trim(), title: m[2].trim() };
  }
  return { title: s.trim(), artist: '' };
}

/**
 * 把多 P 视频（B 站音乐的「50 首精选合集」这类）展开成曲目列表；单 P 视频返回空数组。
 *
 * 首个分 P 刻意复用 base.id：播放首个分 P 时用的就是原 track，
 * 这样展开后当前曲目在队列里的位置不变，currentIndex 不会错位、播放在展开瞬间不会打断。
 * 其余分 P 用 `bvid#cid` 作 id——cid 唯一，切歌时能正确取到对应分 P 的音频流。
 */
export async function expandVideoParts(bvid: string, base?: Track): Promise<Track[]> {
  if (!bvid) {
    return [];
  }
  const detail: VideoDetail = await getVideoDetail(bvid);
  const pages: VideoPageInfo[] = detail.pages ? detail.pages : [];
  if (pages.length <= 1) {
    return [];
  }
  const fallbackArtist: string = base && base.artist ? base.artist : (detail.owner ? detail.owner.name : '');
  const cover: string = base && base.coverUrl ? base.coverUrl : toHttpsUrl(detail.pic);
  const aid: string = base && base.aid ? base.aid : String(detail.aid);
  const out: Track[] = [];
  for (let i = 0; i < pages.length; i++) {
    const p: VideoPageInfo = pages[i];
    const parsed: PartTitle = splitPartTitle(p.part);
    let title: string = parsed.title;
    if (title.length === 0) {
      title = detail.title;
    }
    // 首个分 P 复用调用方传入的原始条目（id 已如此），标题也优先用它的：
    // 从搜索 / 榜单进来时这就是**合集标题**，下载页据此把整个合集显示成单个条目
    //（见 DownloadsPage 的分组渲染）。base.id 带 # 说明 base 本身是某个分 P，
    // 此时保持解析出的分 P 标题不变。
    if (i === 0 && base && base.title.length > 0 && base.id.indexOf('#') < 0) {
      title = base.title;
    }
    out.push(buildTrack({
      id: i === 0 ? (base ? base.id : bvid) : `${bvid}#${p.cid}`,
      bvid: bvid,
      aid: aid,
      cid: String(p.cid),
      title: title,
      artist: parsed.artist.length > 0 ? parsed.artist : fallbackArtist,
      coverUrl: cover,
      duration: p.duration
    }));
  }
  return out;
}

export async function getPlayUrl(bvid: string, cid: number): Promise<PlayUrlData> {
  // 同 view：这是决定「能不能出声」的最后一跳，必须退避重试
  return biliFetchRetry<PlayUrlData>('/x/player/playurl', {
    bvid: bvid,
    cid: cid,
    qn: 0,
    fnver: 0,
    fnval: 16,
    fourk: 1
  }, 'playurl');
}

/**
 * 音质偏好 → 「候选 quality id」序列（按偏好度从高到低）。
 *
 * 为什么要给一个序列而不是一个 id：服务端给哪几档是它说了算，用户选的档常常不存在。
 * 例如只有 64K / 192K 的投稿，用户选「高品质(132K)」时应当退到 192K 而不是 64K。
 * 三个序列的最后几项互为兜底，保证只要有一条音轨就一定能选出东西。
 */
export function audioQualityCandidates(preferredId: number): number[] {
  if (preferredId === AUDIO_Q_64K) {
    // 「省流量」：越小越好，逐级放大只在没有更小的档时发生
    return [AUDIO_Q_64K, AUDIO_Q_132K, AUDIO_Q_192K, AUDIO_Q_DOLBY, AUDIO_Q_HIRES];
  }
  if (preferredId === AUDIO_Q_HIRES) {
    // 「无损」：优先 Hi-Res / 杜比，没有就退到能拿到的最高档
    return [AUDIO_Q_HIRES, AUDIO_Q_DOLBY, AUDIO_Q_192K, AUDIO_Q_132K, AUDIO_Q_64K];
  }
  // 「高品质」(192K) 及未知取值：优先 192K → 132K → 无损（更大也不亏）→ 最后才 64K
  return [AUDIO_Q_192K, AUDIO_Q_132K, AUDIO_Q_HIRES, AUDIO_Q_DOLBY, AUDIO_Q_64K];
}

/**
 * 在服务端返回的音频流里按偏好挑一条。
 *
 * @param preferredQuality 首选档位 id；<= 0 表示「无所谓，取最高带宽」（播放侧的默认行为）
 */
export function pickAudioStream(streams: AudioStream[], preferredQuality: number = 0): AudioStream {
  if (preferredQuality > 0) {
    const order: number[] = audioQualityCandidates(preferredQuality);
    for (let i = 0; i < order.length; i++) {
      for (let j = 0; j < streams.length; j++) {
        if (streams[j].quality === order[i]) {
          return streams[j];
        }
      }
    }
    // 走到这里说明服务端给的是未知档位 id（B 站会不打招呼地加新档），
    // 不猜了，直接按带宽取最大 —— 至少不会比之前差。
  }
  let best: AudioStream = streams[0];
  for (let i = 1; i < streams.length; i++) {
    if (streams[i].bandwidth > best.bandwidth) {
      best = streams[i];
    }
  }
  return best;
}

export function getBestAudioStream(playData: PlayUrlData, preferredQuality: number = 0): AudioStream {
  // 不能直接写 playData.dash.audio：dash 缺失时（服务端偶发把 fnval=16 降级成 durl 老格式）
  // 会抛 TypeError「Cannot read property 'audio' of undefined」，
  // 被上层当成「这首歌播不了」而不是「响应格式异常」。显式判空，给出可识别的错误。
  const audioStreams: AudioStream[] | undefined = playData.dash ? playData.dash.audio : undefined;
  if (!audioStreams || audioStreams.length === 0) {
    throw new Error('No audio stream available');
  }
  return pickAudioStream(audioStreams, preferredQuality);
}

/**
 * 按实际播放的 cid 组装音源。
 * 多 P 合集里每个分 P 是一首歌：标题 / 时长必须取自该分 P（pages[i]），
 * 否则播第二首时显示的还是合集的标题和总时长。
 */
function buildTrackSource(
  detail: VideoDetail,
  playData: PlayUrlData,
  cid: number,
  preferredQuality: number = 0
): TrackSource {
  const best: AudioStream = getBestAudioStream(playData, preferredQuality);
  const pages: VideoPageInfo[] = detail.pages ? detail.pages : [];
  let title: string = detail.title;
  let artist: string = detail.owner ? detail.owner.name : '';
  let duration: number = detail.duration;
  for (let i = 0; i < pages.length; i++) {
    if (pages[i].cid === cid) {
      const parsed: PartTitle = splitPartTitle(pages[i].part);
      if (parsed.title.length > 0) {
        title = parsed.title;
      }
      if (parsed.artist.length > 0) {
        artist = parsed.artist;
      }
      if (pages[i].duration > 0) {
        duration = pages[i].duration;
      }
      break;
    }
  }
  return {
    bvid: detail.bvid,
    aid: detail.aid,
    cid: cid,
    title: title,
    artist: artist,
    coverUrl: toHttpsUrl(detail.pic),
    duration: duration,
    audioUrl: best.baseUrl,
    audioQuality: best.quality,
    audioMimeType: best.mimeType,
    audioBandwidth: best.bandwidth
  };
}

export interface PopularVideo {
  bvid: string;
  aid: number;
  title: string;
  pic: string;
  owner: { mid: number; name: string; face: string };
  stat: { view: number; danmaku: number; like: number; coin: number; favorite: number; share: number };
  duration: number;
}

export async function getPopularVideos(ps: number = 10, pn: number = 1): Promise<PopularVideo[]> {
  const data: { list: PopularVideo[] } = await biliFetch<{ list: PopularVideo[] }>(
    '/x/web-interface/popular',
    { ps: ps, pn: pn }
  );
  return data.list || [];
}

/**
 * 首页首屏推荐。
 *
 * ⚠️ 两个实测约束，别拿它做「加载更多」：
 *   1. **重复调用返回完全相同的一批**（按 buvid 缓存），一直翻只会看见同一批内容；
 *   2. `ps` 只能给到 10 左右，给 20/30/50 一律返回 **0 条**（HTTP 200 + code 0，
 *      看起来就像"真的没数据"）。
 * 要翻页请用下面的 `getRecommendedFeed`。
 */
export async function getRecommendedVideos(ps: number = 10): Promise<PopularVideo[]> {
  const data: { item: PopularVideo[] } = await biliFetch<{ item: PopularVideo[] }>(
    '/x/web-interface/index/top/rcmd',
    { ps: ps }
  );
  return data.item || [];
}

/**
 * feed/rcmd 的原始条目。该接口会按位置夹带 `login_card` / `ad` 卡片：
 * 这类条目 `bvid` 为空、`owner` 为 null，所以 owner 必须声明为可空。
 */
interface RcmdFeedItem {
  goto?: string;
  bvid: string;
  aid?: number;
  cid?: number;
  title: string;
  pic: string;
  owner: { mid: number; name: string; face: string } | null;
  duration: number;
  stat?: { view: number };
}

/**
 * 可翻页的推荐流。
 *
 * `/x/web-interface/index/top/feed/rcmd` 每换一个 `fresh_idx` 就下发一批新内容
 * （实测 fresh_idx=1/2/3 三批之间几乎零重叠），这才是能支撑「上拉加载更多」的推荐源。
 * `ps=20` 时约 17 条有效内容（其余是登录引导与广告卡片）。
 */
export async function getRecommendedFeed(freshIdx: number, ps: number = 20): Promise<PopularVideo[]> {
  const data: { item: RcmdFeedItem[] } = await biliFetch<{ item: RcmdFeedItem[] }>(
    '/x/web-interface/index/top/feed/rcmd',
    {
      ps: ps,
      fresh_type: 3,
      fresh_idx: freshIdx,
      fresh_idx_1h: freshIdx,
      feed_version: 'V8',
      homepage_ver: 1
    }
  );
  const list: RcmdFeedItem[] = data.item || [];
  const out: PopularVideo[] = [];
  for (let i = 0; i < list.length; i++) {
    const it: RcmdFeedItem = list[i];
    // 登录引导 / 广告卡片：没有 bvid、没有 owner，映射出来就是一行空白
    if (!it.bvid || it.bvid.length === 0) {
      continue;
    }
    const owner: { mid: number; name: string; face: string } | null = it.owner;
    if (owner === null) {
      continue;
    }
    out.push({
      bvid: it.bvid,
      aid: it.aid ?? 0,
      title: it.title ?? '',
      pic: it.pic ?? '',
      owner: { mid: owner.mid, name: owner.name, face: owner.face },
      stat: {
        view: it.stat ? it.stat.view : 0,
        danmaku: 0,
        like: 0,
        coin: 0,
        favorite: 0,
        share: 0
      },
      duration: it.duration ?? 0
    });
  }
  return out;
}

//
// 数据源从 `ranking/region` 换成 `ranking/v2`（本机实测对照结论）：
//   · `ranking/region?rid=3&day=3` 只返回 **11 条**，且 pn/ps 完全无效（传了还是同一批 11 条），
//     字段是 author(str) / duration("0:15") / 无 cid / 无 owner —— 既不能分页，信息也不全；
//   · `ranking/v2?rid=3&type=all` 一次返回 **96 条**，字段与"视频详情"一致
//     （有 owner 对象、有 cid、duration 是秒），播放时还能少发一次 view 请求。
//
// 但 v2 **同样不支持 pn/ps**（传 pn=2 仍返回同一批），所以「上拉加载更多」只能前端分页：
// 一次把整榜拿回内存，界面每次多放一屏（见 SearchPage 的 RANKING_PAGE_SIZE）。
//
// 另外注意：这里的 duration 是**秒**，跟旧 region 接口的 "0:15" 字符串不是一回事，
// 两套映射函数不能混用（历史上就是照抄 detail 字段导致整榜被 catch 成空）。

export interface RankingVideoItem {
  aid: number;
  bvid: string;
  cid: number;
  title: string;
  pic: string;
  owner: VideoOwner;
  stat: VideoStat;
  /** 秒 */
  duration: number;
}

export async function getMusicRankingV2(): Promise<RankingVideoItem[]> {
  const data: { list: RankingVideoItem[] } = await biliFetch<{ list: RankingVideoItem[] }>(
    '/x/web-interface/ranking/v2',
    { rid: 3, type: 'all' }
  );
  return data.list || [];
}

// ===== 音乐中心（music.bilibili.com 同源） =====

export interface MusicCenterRelatedArchive {
  aid: string;
  bvid: string;
  cid: string;
  cover: string;
  title: string;
  duration?: number;
}

/**
 * 音乐中心（/x/centralization/interface/...）返回的是**下划线风格**字段名：
 *   music_id / music_title / author / cover / bvid / aid / cid / album / related_archive
 * 早期按驼峰写（musicId / musicTitle / relatedArchive）→ 标题全是 undefined，
 * 只有 author（该字段名两边一致）能显示 —— 就是"只能显示歌手名字，歌名没有"。
 * 这里两个名字都声明为可选，取的时候下划线优先、驼峰兜底，防止 B 站改回去。
 */
export interface MusicCenterItem {
  music_id?: string;
  musicId?: string;
  music_title?: string;
  musicTitle?: string;
  author: string;
  bvid: string;
  aid: string;
  cid: string;
  cover: string;
  album?: string;
  score?: number;
  publish_time?: string;
  publishTime?: string;
  related_archive?: MusicCenterRelatedArchive;
  relatedArchive?: MusicCenterRelatedArchive;
}

/**
 * 音乐中心「综合榜」。
 *
 * 实测这个接口的 `pn` 是**真分页**：pn=1/2/3 各 20 条互不重叠（pn 一直翻到 20 都还有数据），
 * 因此「上拉加载更多」就是在这里递增 pn。
 */
export async function getMusicComprehensiveRank(ps: number = 30, pn: number = 1): Promise<MusicCenterItem[]> {
  const data: { list: MusicCenterItem[] } = await biliFetch<{ list: MusicCenterItem[] }>(
    '/x/centralization/interface/music/comprehensive/web/rank',
    { pn: pn, ps: ps }
  );
  return data.list || [];
}

/**
 * 音乐中心「新歌榜」。
 * 只有固定 18 条，`pn`/`ps` 传了也无效（返回同一批），所以只用于首屏补充，不参与翻页。
 */
export async function getNewMusic(): Promise<MusicCenterItem[]> {
  const data: { list: MusicCenterItem[] } = await biliFetch<{ list: MusicCenterItem[] }>(
    '/x/centralization/interface/new/music'
  );
  return data.list || [];
}

export interface FavoriteFolder {
  id: number;
  title: string;
  mediaCount: number;
}

export async function getFavoriteFolders(mid: number): Promise<{ count: number; list: FavoriteFolder[] }> {
  return biliFetch<{ count: number; list: FavoriteFolder[] }>('/x/v3/fav/folder/created/list-all', {
    up_mid: mid
  });
}

export async function extractAudioFromSearch(keyword: string, index: number = 0): Promise<TrackSource> {
  const searchResult: SearchResponse = await searchVideo(keyword, 1, 10);
  if (!searchResult.result || searchResult.result.length === 0) {
    throw new Error(`未找到相关视频: ${keyword}`);
  }
  const video: SearchResultItem = searchResult.result[index];
  return extractAudioFromVideo(video.bvid);
}

/**
 * 解析一条视频的音频直链。
 *
 * @param preferredQuality 首选音频档位 id（见 model/MusicModels.downloadQualityId）。
 *        默认 0 = 取最高带宽，即**播放侧的历史行为**；只有「下载」会传具体档位。
 *        播放不跟着下载音质走是刻意的：试听要给最好的，下载才需要省流量。
 * @param refresh true = 绕过缓存强制重新解析（直链过期重试时用），并回写新结果。
 */
export async function extractAudioFromVideo(
  bvid: string,
  fallback?: { aid?: string | number; cid?: string | number },
  preferredQuality: number = 0,
  refresh: boolean = false
): Promise<TrackSource> {
  // 缓存键用「调用时的入参」而不是解析出的 cid：解析前无法预知服务端最终采用哪个 cid，
  // 但同一组入参的解析结果是确定的，重复调用（预取后播放、重播）直接复用即可。
  const cacheKey: string = `${bvid}|${fallback && fallback.cid ? fallback.cid : 0}|${preferredQuality}`;
  if (!refresh) {
    const hit: TrackSource | null = cacheGet<TrackSource>(sourceCache, cacheKey, SOURCE_CACHE_TTL_MS);
    if (hit !== null) {
      return hit;
    }
  }
  try {
    const detail: VideoDetail = await getVideoDetail(bvid, refresh);
    // 用 Array.isArray 而不是真值判断：pages 万一是对象而不是数组，
    // 下面的 pages.some 会抛 TypeError，整首歌就白解析了
    const pages: VideoPageInfo[] = Array.isArray(detail.pages) ? detail.pages : [];
    // 曲目带 cid 时（多 P 合集的非首个分 P）必须用该 cid 取流；
    // 早期这里一直用 detail.cid（默认第一个分 P），导致合集永远只能播第一首。
    //
    // ⚠️ 但**必须先校验这个 cid 真的属于该 bvid 的分 P**：
    // 音乐中心（/x/centralization/interface/**）的 `related_archive.cid` 是**音频 cid**，
    // 与视频分 P 的 cid 不是同一套编号体系。实测（线上对照实验）：
    //   playurl?bvid=BV1kQhz6fEMZ&cid=117309800781135 → code=-404「啥都木有」
    //   playurl?bvid=BV1kQhz6fEMZ&cid=42091416602  （pages[0]）→ code=0，dash.audio 有 3 条
    // 不做校验就会用错配 cid 取流 → 抛异常 → 整条音乐中心列表点哪首都播不出来。
    const wanted: number = fallback && fallback.cid ? Number(fallback.cid) : 0;
    const belongs: boolean =
      wanted > 0 && pages.some((p: VideoPageInfo): boolean => p.cid === wanted);
    let useCid: number = belongs ? wanted : detail.cid;
    if (!(useCid > 0) && pages.length > 0) {
      useCid = pages[0].cid;
    }
    const playData: PlayUrlData = await getPlayUrl(bvid, useCid);
    const source: TrackSource = buildTrackSource(detail, playData, useCid, preferredQuality);
    cachePut<TrackSource>(sourceCache, cacheKey, source, SOURCE_CACHE_MAX);
    return source;
  } catch (e) {
    if (fallback && fallback.aid && fallback.cid) {
      const source: TrackSource = await extractAudioByAvidCid(fallback.aid, fallback.cid, bvid, preferredQuality);
      cachePut<TrackSource>(sourceCache, cacheKey, source, SOURCE_CACHE_MAX);
      return source;
    }
    throw e;
  }
}

async function extractAudioByAvidCid(
  aid: string | number,
  cid: string | number,
  bvid: string = '',
  preferredQuality: number = 0
): Promise<TrackSource> {
  const playData: PlayUrlData = await biliFetch<PlayUrlData>('/x/player/playurl', {
    avid: aid,
    cid: cid,
    qn: 0,
    fnver: 0,
    fnval: 16,
    fourk: 1
  });
  const audioStreams: AudioStream[] = playData.dash?.audio;
  if (!audioStreams || audioStreams.length === 0) {
    throw new Error('No audio stream available');
  }
  const best: AudioStream = getBestAudioStream(playData, preferredQuality);
  return {
    bvid: bvid,
    aid: Number(aid) || 0,
    cid: Number(cid) || 0,
    title: '',
    artist: '',
    coverUrl: '',
    duration: 0,
    audioUrl: best.baseUrl,
    audioQuality: best.quality,
    audioMimeType: best.mimeType,
    audioBandwidth: best.bandwidth
  };
}

