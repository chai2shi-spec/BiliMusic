/**
 * B 站 API 服务层（原生 ArkTS 版）。
 * 移植自原 React 版 src/services/bilibiliApi.ts，使用 HttpUtil + WBI 签名。
 * 所有请求自动携带 Referer / buvid Cookie（HttpUtil 统一处理），登录后追加 SESSDATA。
 *
 * 扫码登录（passport web 接口）已恢复（2026-10）：生成 / 轮询 / nav / 登出见文件末尾
 * 「扫码登录」一节。密码 / 短信登录依赖极验验证码，第三方客户端无法内置，不做。
 * buvid 能力（设备指纹）与登录无关，在 `service/BiliDevice.ts`。
 */

import { HttpUtil, HttpTextResult } from '../utils/HttpUtil';
import { toHttpsUrl, stripHtmlTags, decodeHtmlEntities } from '../utils/TextUtil';
import { encodeWbi } from './WbiSign';
import http from '@ohos.net.http';
import {
  AUDIO_Q_64K,
  AUDIO_Q_132K,
  AUDIO_Q_192K,
  AUDIO_Q_DOLBY,
  AUDIO_Q_HIRES,
  BILI_API,
  BILI_APP_UA,
  BILI_PASSPORT
} from '../common/Constants';
import {
  AudioStream,
  DashData,
  DolbyData,
  DurlItem,
  FlacStream,
  PlayUrlData,
  SeasonEpisode,
  SearchResultItem,
  Track,
  TrackSource,
  UgcSeason,
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
  // ⚠️ 2026-10-20 真机/平板实测：走 `params`（ohos 的 queryParams）时，
  // `/x/web-interface/view` 拿到的仍是「没有 bvid」的空请求 → `-400 请求错误`
  //（同一 bvid 用 curl 直连是 code=0）。工程里本来能用的 GET（搜索 / 推荐）
  // 全是把 query 直接拼进 URL 的，这里统一成同一口径：
  // **参数内联到 URL**，不再依赖 queryParams。
  let url: string = `${BILI_API}${path}`;
  if (params) {
    const parts: string[] = [];
    const keys: string[] = Object.keys(params);
    for (let i = 0; i < keys.length; i++) {
      parts.push(`${encodeURIComponent(keys[i])}=${encodeURIComponent(String(params[keys[i]]))}`);
    }
    if (parts.length > 0) {
      url = `${url}?${parts.join('&')}`;
    }
  }
  const data: BiliEnvelope<T> = await HttpUtil.requestJson<BiliEnvelope<T>>(url);
  if (data.code !== 0) {
    throw new BiliApiError(data.code, data.message, path);
  }
  return data.data;
}

/**
 * B 站**表单 POST**（`application/x-www-form-urlencoded`），与 `biliFetch` 同口径：
 * `code !== 0` 抛 `BiliApiError`。
 *
 * 为什么必须另写一个：`biliFetch` 只能发 GET（参数走 queryParams），而 B 站的
 * 收藏写接口（收藏 / 取消收藏）要求 `csrf`（bili_jct）走**表单体**，发到 query 上会被拒。
 * 表单体格式对齐已有的 `revokeLogin`（见文件末尾「扫码登录」一节）。
 */
async function biliPost<T>(path: string, form: Record<string, string | number>): Promise<T> {
  const parts: string[] = [];
  const keys: string[] = Object.keys(form);
  for (let i = 0; i < keys.length; i++) {
    parts.push(`${encodeURIComponent(keys[i])}=${encodeURIComponent(String(form[keys[i]]))}`);
  }
  const data: BiliEnvelope<T> = await HttpUtil.requestJson<BiliEnvelope<T>>(`${BILI_API}${path}`, {
    method: http.RequestMethod.POST,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: parts.join('&')
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

/**
 * 搜索结果标题清洗。
 *
 * **API 通道返回的是未解码的原始标题**（2026-10-22 真机实测）：带引号的稿件，
 * `/x/web-interface/wbi/search/type` 给的是 `&quot;虚妄堆起了虚妄山…&quot; DOUDOU《…》`。
 * 不解码会造成两个后果，而且第二个很隐蔽：
 *   ① 歌单里存成 `&quot;…&quot;`，用户可见的脏字符；
 *   ② 拿它当关键词去搜歌词时，query 里真的带着 `&quot`（hilog 里可见
 *      `s=%E5%AE%9D%E8%88%B9%20%26quot%20…`），命中率直接归零。
 * HTML 兜底通道早就解过（`parseSearchCardHtml`），只有 API 通道漏了，这里补齐。
 *
 * 顺序与 HTML 通道保持一致：先解实体、再剥标签（`&lt;em&gt;` 解出来才剥得掉）。
 */
function sanitizeSearchResponse(resp: SearchResponse): SearchResponse {
  if (!Array.isArray(resp.result)) {
    return resp;
  }
  const list: SearchResultItem[] = resp.result;
  for (let i: number = 0; i < list.length; i++) {
    const raw: string = list[i].title ?? '';
    list[i].title = stripHtmlTags(decodeHtmlEntities(raw));
  }
  return resp;
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
  return sanitizeSearchResponse(data.data);
}

//
// ────────── HTML 搜索页兜底通道（2026-10-22）──────────
//
/**
 * API 搜索是**按 IP 计量**的硬配额，长歌单必然撞墙，撞墙后整批「未找到」。
 *
 * 实测（本机，PC UA + buvid）：
 *   · `/x/web-interface/wbi/search/type` 干净起步第 **48** 次请求 → HTTP 412；
 *   · 撞墙后换全新 buvid / 不带任何 Cookie / 换 iPhone UA → **全部仍然 412**
 *     （所以限流跟设备指纹无关，是 IP 维度）；封禁持续 **9 分钟以上**未恢复；
 *   · 同一时刻 `search.bilibili.com/all?keyword=` 的 **HTML 页仍返回 200**，
 *     且压测 40/40 次全部正常，每页 41~42 张卡片。
 *
 * 所以走 HTML 页兜底：SSR 卡片里 bvid / 标题 / UP 主 / mid / 时长 / 封面都在，够打分。
 * 拿不到的三项（aid / 播放量 / 发布时间）填空值 —— 它们只影响「同分时按播放量排序」，
 * 播放本身走 bvid，不受影响。
 *
 * ⚠️ 解析依赖 B 站前端的 class 名（`bili-video-card__wrap` / `info--tit` / `stats__duration`），
 * B 站改版会失效。它只是兜底：解析不到就返回空数组，上层按「没搜到」处理，主通道不受影响。
 */
const CARD_SPLIT: string = 'bili-video-card__wrap';
const RE_CARD_BVID: RegExp = /\/video\/(BV[0-9A-Za-z]{10})/;
const RE_CARD_TITLE: RegExp = /bili-video-card__info--tit"\s+title="([^"]*)"/;
const RE_CARD_MID: RegExp = /space\.bilibili\.com\/(\d+)/;
const RE_CARD_AUTHOR: RegExp = /bili-video-card__info--author"[^>]*>([^<]*)</;
const RE_CARD_DURATION: RegExp = /stats__duration"[^>]*>([0-9:]+)</;
const RE_CARD_COVER: RegExp = /src="(\/\/[a-z0-9.]*hdslb\.com\/bfs\/archive\/[^"]+)"/;

function parseSearchCardHtml(block: string): SearchResultItem | null {
  const mBvid: RegExpMatchArray | null = block.match(RE_CARD_BVID);
  const mTitle: RegExpMatchArray | null = block.match(RE_CARD_TITLE);
  if (mBvid === null || mTitle === null) {
    return null;
  }
  const mMid: RegExpMatchArray | null = block.match(RE_CARD_MID);
  const mAuthor: RegExpMatchArray | null = block.match(RE_CARD_AUTHOR);
  const mDur: RegExpMatchArray | null = block.match(RE_CARD_DURATION);
  const mCover: RegExpMatchArray | null = block.match(RE_CARD_COVER);
  const item: SearchResultItem = {
    bvid: mBvid[1],
    // HTML 卡片不含 aid；播放走 bvid，这里填 0（`mapSearchResultToTrack` 会给成 '0'）
    aid: 0,
    title: stripHtmlTags(decodeHtmlEntities(mTitle[1])),
    author: mAuthor !== null ? decodeHtmlEntities(mAuthor[1]).trim() : '',
    mid: mMid !== null ? Number.parseInt(mMid[1], 10) : undefined,
    // 卡片不显示播放量（B 站已隐藏），只用于同分排序，填 0
    play: 0,
    videoReview: 0,
    duration: mDur !== null ? mDur[1] : '',
    pubdate: 0,
    pic: mCover !== null ? toHttpsUrl(mCover[1]) : '',
    description: ''
  };
  return item;
}

/**
 * 走 HTML 搜索页取候选（兜底通道，见上）。
 *
 * ⚠️ 若 HTML 页本身也返回 >= 400，`HttpUtil.requestText` 会抛 `HTTP <code>` 普通 Error，
 * 上层 `ImportTaskManager.isRiskError` 能识别 412/429 并走退避。
 */
export async function searchVideoByHtml(keyword: string): Promise<SearchResultItem[]> {
  const url: string = `https://search.bilibili.com/all?keyword=${encodeURIComponent(keyword)}`;
  const html: string = await HttpUtil.requestText(url);
  const out: SearchResultItem[] = [];
  if (html.length === 0) {
    return out;
  }
  // 按卡片容器切块：一张卡一块（block[0] 是首卡之前的页面骨架，丢掉）
  const blocks: string[] = html.split(CARD_SPLIT);
  for (let i: number = 1; i < blocks.length; i++) {
    const item: SearchResultItem | null = parseSearchCardHtml(blocks[i]);
    if (item !== null) {
      out.push(item);
    }
  }
  return out;
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
  /**
   * 头像（另一尺寸）。匿名实测返回里有它，与 `upic` 同为 `//i0.hdslb.com/...` 头图。
   * 保留是因为 `upic` 偶尔为空、这个不为空时可以兜底。
   */
  face_nft?: string;
  /**
   * 认证信息：`{ type: 0|1, desc: "…" }`（type=0 个人认证 / 1 企业认证）。
   * 音乐类 UP 多是企业认证（索尼音乐中国、环球音乐等），显示出来能有效区分
   * 「官方号」和「同名搬运号」—— 这在匿名搜 UP 时是最需要的信息。
   */
  verify_info?: { type: number; desc: string };
  /** 性别（1 男 / 2 女），UI 不用，留着是因为接口给全了、以后可能做筛选 */
  gender?: number;
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

/**
 * 空间投稿接口 `ps`（每页条数）上限。
 *
 * 2026-10-08 实测（`x/space/arc/search` 匿名直打）：ps=50 只受常规风控（412 抖动），
 * **ps=60 恒返回 `code:-400 请求错误`**（ps=100 则 -799）—— 超上限是**确定性**失败。
 * 这曾实打实坑过「登录态歌单拉新」：PlaylistDetail 传 maxItems=60 当 ps 用，
 * 空间接口每次必 -400，登录态优先路径形同虚设（反而比匿名态更差）。
 * 所以在这里统一钳制：调用方要再多也只给 50，要更多自己翻页（pn）。
 */
const SPACE_PS_MAX: number = 50;

/**
 * UP 主投稿列表（老接口）。
 *
 * 2026-10-03 实测更正：**带不带 `jsonp=jsonp` 与成败无关**（同一 URL 一带一不带各测过，
 * 成功和失败都出现过）→ 之前「必须带 jsonp 才能过」的结论是**把限流抖动误当成了参数规律**。
 * 现在保留这个参数只是无害冗余，真正起作用的是调用时机（别密集请求）。
 *
 * 它不需要 wbi 签名 → 在 wbi 版被限的轮次里作为替补。
 */
export async function getUserVideosLegacy(
  mid: number,
  page: number = 1,
  pageSize: number = 30,
  order: string = 'pubdate'
): Promise<SpaceArcSearchData> {
  lastArcSearchUsedLegacy = false;
  // ps 超上限 = 确定性 -400，钳到 50（见 SPACE_PS_MAX 注释）
  const ps: number = Math.min(pageSize, SPACE_PS_MAX);
  const query: string = `mid=${mid}&pn=${page}&ps=${ps}&order=${order}&jsonp=jsonp`;
  const data: BiliEnvelope<SpaceArcSearchData> = await HttpUtil.requestJson<BiliEnvelope<SpaceArcSearchData>>(
    `${BILI_API}/x/space/arc/search?${query}`
  );
  if (data.code !== 0) {
    throw new BiliApiError(data.code, data.message, '/x/space/arc/search');
  }
  return data.data;
}

/** 搜索反查的结果：必须区分「搜到了 0 条」和「搜索请求本身失败」 */
export interface UpVideosSearchResult {
  list: SpaceVideo[];
  /**
   * 搜索请求是否**成功**（`code=0`）。
   * true + list 为空 = B 站搜索里确实没有该 UP 的投稿（昵称可能不出现在视频标题里）；
   * false = 搜索接口自己被限 / 出错 → 该提示「稍后重试」，不该让用户以为是「没投稿」。
   */
  searchOk: boolean;
}

/**
 * UP 主投稿列表（**首选路径**：用搜索接口反查）。
 *
 * 为什么不用空间接口当首选（2026-10-03 实测）：
 *   · `x/space/wbi/arc/search` 与 `x/space/arc/search` 对匿名访问风控极强，
 *     同一 URL 连打 8 次 **0/8 成功**（失败形态在 HTTP 412 与 -799 之间随机跳），
 *     冷却 45s / 间隔 8s / 间隔 20s 各试一次，**没有可用规律**；
 *   · 而搜索接口稳定 `code=0`（wbi 版与非 wbi 老版各 4/4 成功），**结果里带 mid** →
 *     能按 mid 精确过滤出该 UP 的投稿。实测「索尼音乐中国」第 1 页 20 条里 19 条命中。
 *
 * 局限（要有预期）：
 *   1. 搜索是按**视频内容**匹配的 —— UP 的视频标题里没出现它的昵称时就搜不到，
 *      所以会出现「搜索成功但 0 命中」（`searchOk=true` + `list` 为空）；
 *   2. 最多翻 `maxSearchPages` 页；
 *   3. 排序用 `order=pubdate`（按发布时间）而不是默认的相关性 —— 对「找最近的投稿」更贴。
 */
export async function getUserVideosViaSearch(
  targetMid: string,
  nickname: string,
  maxItems: number,
  maxSearchPages: number = 3
): Promise<UpVideosSearchResult> {
  const keyword: string = nickname.trim();
  if (keyword.length === 0 || targetMid.length === 0) {
    return { list: [], searchOk: false };
  }
  const out: SpaceVideo[] = [];
  const seen: Set<string> = new Set<string>();
  for (let pn = 1; pn <= maxSearchPages; pn++) {
    let resp: SearchResponse;
    try {
      resp = await searchVideoByDate(keyword, pn, 20);
    } catch (e) {
      // 第一页就失败才算「搜索不可用」；翻页途中失败保留已拿到的
      console.warn(`search by up name failed at page ${pn}: ${JSON.stringify(e)}`);
      return { list: out, searchOk: pn === 1 ? false : true };
    }
    const list: SearchResultItem[] = resp.result || [];
    if (list.length === 0) {
      break;
    }
    for (let i = 0; i < list.length; i++) {
      const item: SearchResultItem = list[i];
      // 三个条件缺一不可：mid 相同、bvid 有效、没重复（搜索会返回同一视频的多条命中）
      if (String(item.mid ?? '') !== targetMid || !item.bvid || seen.has(item.bvid)) {
        continue;
      }
      seen.add(item.bvid);
      out.push({
        bvid: item.bvid,
        aid: item.aid,
        title: item.title,
        pic: item.pic,
        length: item.duration,
        play: item.play,
        created: item.pubdate,
        description: item.description,
        author: item.author
      });
      if (out.length >= maxItems) {
        break;
      }
    }
    if (out.length >= maxItems) {
      break;
    }
  }
  return { list: out, searchOk: true };
}

/**
 * `searchUpVideosByKeyword` 的单轮搜索：按 term 相关性搜索 + mid 过滤 + 去重，
 * 命中追加进 out / seen。返回该轮搜索请求是否成功（false = 第一页就被拒）。
 */
async function collectKeywordMatches(
  targetMid: string,
  term: string,
  maxSearchPages: number,
  out: SpaceVideo[],
  seen: Set<string>
): Promise<boolean> {
  for (let pn = 1; pn <= maxSearchPages; pn++) {
    let resp: SearchResponse;
    try {
      // 相关性排序（totalrank，不带 order 参数）：带 mid 过滤的搜索里，
      // 「UP名 + 关键词」的相关性结果天然把该 UP 的稿件排在最前；
      // pubdate 会把 TA 的视频埋进全站最新匹配里，小 UP 基本捞不到。
      resp = await searchVideo(term, pn, 20);
    } catch (e) {
      // 第一页就失败才算「搜索不可用」；翻页途中失败保留已拿到的
      console.warn(`search up videos by keyword failed at page ${pn}: ${JSON.stringify(e)}`);
      return pn === 1 ? false : true;
    }
    const list: SearchResultItem[] = resp.result || [];
    if (list.length === 0) {
      break;
    }
    for (let i = 0; i < list.length; i++) {
      const item: SearchResultItem = list[i];
      // 与 getUserVideosViaSearch 同款三条件：mid 相同、bvid 有效、去重
      if (String(item.mid ?? '') !== targetMid || !item.bvid || seen.has(item.bvid)) {
        continue;
      }
      seen.add(item.bvid);
      out.push({
        bvid: item.bvid,
        aid: item.aid,
        title: item.title,
        pic: item.pic,
        length: item.duration,
        play: item.play,
        created: item.pubdate,
        description: item.description,
        author: item.author
      });
    }
  }
  return true;
}

/**
 * 按**任意关键词**搜索某个 UP 的投稿（UP 主页站内搜索，2026-10-23）。
 *
 * 两轮策略（2026-10-23 真机修「点搜索反而 0 命中」）：
 *  · 第一轮拿「UP名 + 关键词」做**相关性**搜索 —— 昵称反查（getUserVideosViaSearch）
 *    能用搜索+mid 过滤走通，正是因为搜索词就是 UP 名；拼上关键词后结果仍集中在
 *    该 UP 的稿件上，mid 过滤即得「TA 的投稿里匹配关键词的」。
 *    旧实现用 pubdate 排序搜裸关键词：全站按时间排，该 UP 的视频被埋进全局
 *    最新匹配里，3 页 60 条捞不到 → 必然 0 命中（真机复现）。
 *  · 第一轮 0 命中时用裸关键词再兜底一轮：捞回「标题/简介只含关键词、
 *    作者恰好是 TA」的投稿（搜索把昵称当硬条件时第一轮会漏掉这类）。
 *
 * 边界预期（写在这里防止后来者误判为 bug）：
 *  · 泛关键词下该 UP 的视频仍可能挤不进前几页 → **0 命中 ≠ 接口失败**
 *    （`searchOk` 字段已区分两者）；
 *  · 结果一律按 `mid === targetMid` 过滤，其它 UP 的同词视频不会混进来；
 *  · 两轮各自最多 `maxSearchPages` 页（每页 20），命中全收不设上限。
 */
export async function searchUpVideosByKeyword(
  targetMid: string,
  upName: string,
  keyword: string,
  maxSearchPages: number = 3
): Promise<UpVideosSearchResult> {
  const kw: string = keyword.trim();
  const name: string = upName.trim();
  if (kw.length === 0 || targetMid.length === 0) {
    return { list: [], searchOk: false };
  }
  const out: SpaceVideo[] = [];
  const seen: Set<string> = new Set<string>();
  // 第一轮：昵称可得时拼「UP名 + 关键词」；昵称缺失（理论少见）退化为裸关键词
  let searchOk: boolean = await collectKeywordMatches(
    targetMid, name.length > 0 ? `${name} ${kw}` : kw, maxSearchPages, out, seen
  );
  // 第二轮兜底：仅在第一轮请求成功但 0 命中时才发起（避免重复打限流配额）
  if (searchOk && out.length === 0 && name.length > 0) {
    searchOk = await collectKeywordMatches(targetMid, kw, maxSearchPages, out, seen);
  }
  return { list: out, searchOk };
}

/**
 * 搜索视频（`order=pubdate`：按发布时间排序）。
 *
 * 与 `searchVideo` 的区别只在这个参数，但对「找某个 UP 最近的投稿」影响很大：
 * 默认 `totalrank`（相关性）会把最相关的排在前面，热门旧稿容易挤掉新稿。
 */
export async function searchVideoByDate(
  keyword: string,
  page: number = 1,
  pageSize: number = 20
): Promise<SearchResponse> {
  const query: string = await encodeWbi({
    search_type: 'video',
    keyword: keyword,
    order: 'pubdate',
    page: page,
    page_size: pageSize
  });
  const data: BiliEnvelope<SearchResponse> = await HttpUtil.requestJson<BiliEnvelope<SearchResponse>>(
    `${BILI_API}/x/web-interface/wbi/search/type?${query}`
  );
  if (data.code !== 0) {
    throw new BiliApiError(data.code, data.message, '/x/web-interface/wbi/search/type');
  }
  return sanitizeSearchResponse(data.data);
}

/**
 * 空间接口的有限重试包装。
 *
 * 该接口单次成功率实测约 20%（失败形态随机），但**并非完全不可用**：
 * 隔开时间重试有一定命中率。所以给它 3 次机会、每次间隔 2.5 秒 ——
 * 理论累计成功率约 1-0.8³ ≈ 49%，比只试一次强得多。
 *
 * ⚠️ 间隔必须给够：实测「连打 8 次间隔 1.5s」是 0/8，密集请求会自己撞满限流阈值。
 * ⚠️ `getUserVideos` 内部会在 wbi ↔ 老接口之间自动交替，所以重试天然在换接口试。
 * ⚠️ **确定性业务错误不重试**（2026-10-08）：-400（参数错误，如 ps 超限）、
 *   -101（登录失效）重试多少次结果都一样 —— 立即抛出让上层走兜底，
 *   否则用户对着「正在拉取…」白等 3×2.5s 才见到失败（复用 isRetryableFetchError 的判定）。
 *
 * ⚠️ **页码必须透传**（2026-10-11 修）：本包装层旧签名没有 page 参数、内部恒取第 1 页，
 *   UpSpacePage 上拉翻页传了 pn 也没用 —— 同一批条目被反复追加，缓存里全是重复。
 *   现在签名与 `getUserVideos` 参数序对齐（mid, page, pageSize, order, attempts），
 *   翻页调用方务必把 pn 传进来；只取首页的调用点显式传 1。
 */
export async function getUserVideosWithRetry(
  mid: number,
  page: number = 1,
  pageSize: number = 30,
  order: string = 'pubdate',
  attempts: number = 3
): Promise<SpaceVideo[]> {
  let lastError: string = '';
  for (let i = 0; i < attempts; i++) {
    if (i > 0) {
      await delay(SPACE_RETRY_GAP_MS);
    }
    try {
      const data: SpaceArcSearchData = await getUserVideos(mid, page, pageSize, order);
      const vlist: SpaceVideo[] = data && data.list ? data.list.vlist : [];
      if (vlist.length > 0) {
        return vlist;
      }
      lastError = '空列表';
    } catch (e) {
      // -400 / -101 这类确定性错误：重试无意义，立即上抛（网络错 / 风控码照常重试）
      if (!isRetryableFetchError(e)) {
        throw e;
      }
      lastError = e instanceof Error ? e.message : JSON.stringify(e);
      console.warn(`getUserVideos attempt ${i + 1}/${attempts} failed: ${lastError}`);
    }
  }
  throw new BiliApiError(-1, `空间接口重试 ${attempts} 次仍失败：${lastError}`, '/x/space/arc/search');
}

/** 空间接口重试间隔（ms）：实测密集请求（1.5s 间隔）必然被拒 */
const SPACE_RETRY_GAP_MS: number = 2500;

/** setTimeout 的 Promise 化（ArkTS 里没有原生 sleep） */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}

/**
 * 上一次「投稿列表」请求走的是哪个接口。
 *
 * 2026-10-03 重复实验（同一 URL 连打 8 次、间隔 1.5s）：**0/8 成功**，
 * 失败形态在 `HTTP 412` 与 `code=-799 请求过于频繁` 之间随机切换；
 * 而隔开一段时间再打，同一个 URL 又能拿到 30 条。
 * 结论：**该接口是按 IP 限流的，密集请求必被拒，且失败形态随机**。
 *
 * 所以这里不做「同一次调用里 wbi 失败立刻降级」——那会在一次进入里连发两个请求，
 * 正好把限流阈值撞满。改成**跨轮次交替**：这次走 wbi，下次（用户点重试）走老接口。
 */
let lastArcSearchUsedLegacy: boolean = false;

/**
 * UP 主投稿列表（wbi 签名版，优先）。
 *
 * 失败时**不在同一次调用里降级**（会连发两枪），只把错误抛给界面；
 * 下一次调用（用户点「重试」）会自动换用老接口，见 `getUserVideosLegacy`。
 */
export async function getUserVideos(
  mid: number,
  page: number = 1,
  pageSize: number = 30,
  order: string = 'pubdate'
): Promise<SpaceArcSearchData> {
  if (lastArcSearchUsedLegacy) {
    return getUserVideosLegacy(mid, page, pageSize, order);
  }
  lastArcSearchUsedLegacy = true;
  // ps 超上限 = 确定性 -400，钳到 50（见 SPACE_PS_MAX 注释）
  const ps: number = Math.min(pageSize, SPACE_PS_MAX);
  const query: string = await encodeWbi({
    mid: mid,
    pn: page,
    ps: ps,
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

// ===== 投稿获取：多源兜底 =====
//
// 「拉取新投稿」曾经只能靠空间接口（`x/space/wbi/arc/search`），而它对匿名访问风控极强
// （间隔 20s 打 4 次也只成功 2 次，1.5s 连打 8 次是 0/8）。2026-10-06 补了一次对照实验：
//   · 搜索接口 `wbi/search/type` 连打 8 次 **8/8 成功** —— 它根本没被限流；
//   · `x/web-interface/archive/related`（相关推荐）连打 3 次 **3/3 code=0**，
//     40 条里同 UP 的占 11~20 条（随种子变化）—— 这是一条**全新的独立数据源**，
//     且它不依赖「UP 昵称出现在视频标题里」（搜索反查的致命弱点）；
//   · App 端 `app.bilibili.com/x/v2/space/archive/cursor` 恒 -400（要 appkey 签名），走不通；
//   · 动态流 `x/polymer/web-dynamic/v1/feed/space` 恒 -352，走不通。
//
// 所以策略是**三级兜底**，前两级都是匿名稳定接口，空间接口只在两者都没货时才动：
//   ① 搜索反查（结果带 pubdate，天然是「最近的投稿」，最贴「拉新」语义）
//   ② related 扩散（用歌单里已有的该 UP 视频当种子，捞出同 UP 的其它投稿）
//   ③ 空间接口（老路，成功率不稳定，仅兜底）
//
// ⚠️ 登录态（2026-10 登录功能修复后新增）：SESSDATA 会由 HttpUtil 自动附到所有请求上，
// 空间接口的匿名风控（412/-799/-352）大幅缓解 → collectUpVideos 在登录时把空间接口
// **提到最前**（⓪）：它是唯一全量、按 pubdate 排序、支持真分页的准确数据源，
// 搜索反查的「UP 昵称必须在视频内容里」与 related 的「相关≠最新」局限它都没有。
// 失败仍落回匿名态同款 ①→②→③ 顺序，行为无回归。

/** 相关推荐条目（`x/web-interface/archive/related`） */
export interface RelatedVideo {
  bvid: string;
  aid: number;
  title: string;
  pic: string;
  ownerMid: number;
  ownerName: string;
  /** 时长（秒）—— 与 `SpaceVideo.length`("3:45") 不同源，别混用 */
  duration: number;
  pubdate: number;
  play: number;
}

interface RelatedRawItem {
  bvid?: string;
  aid?: number;
  title?: string;
  pic?: string;
  duration?: number;
  pubdate?: number;
  owner?: { mid?: number; name?: string };
  stat?: { view?: number };
}

/**
 * 相关推荐。
 *
 * 实测（2026-10-06）：匿名 `code=0` 稳定返回 **40 条**，连打 3 次全成功；
 * 条目带 `owner.mid` → 能过滤出同一 UP 的投稿。
 * 局限：它是「相关」不是「最新」，所以只作兜底，不拿来替代搜索反查。
 */
export async function getRelatedVideos(bvid: string): Promise<RelatedVideo[]> {
  if (bvid.length === 0) {
    return [];
  }
  const data: BiliEnvelope<RelatedRawItem[]> = await HttpUtil.requestJson<BiliEnvelope<RelatedRawItem[]>>(
    `${BILI_API}/x/web-interface/archive/related?bvid=${bvid}`
  );
  if (data.code !== 0) {
    throw new BiliApiError(data.code, data.message, '/x/web-interface/archive/related');
  }
  const raw: RelatedRawItem[] = data.data || [];
  const out: RelatedVideo[] = [];
  for (let i = 0; i < raw.length; i++) {
    const it: RelatedRawItem = raw[i];
    if (!it.bvid) {
      continue;
    }
    out.push({
      bvid: it.bvid,
      aid: it.aid ?? 0,
      title: it.title ?? '',
      pic: it.pic ?? '',
      ownerMid: it.owner?.mid ?? 0,
      ownerName: it.owner?.name ?? '',
      duration: it.duration ?? 0,
      pubdate: it.pubdate ?? 0,
      play: it.stat?.view ?? 0
    });
  }
  return out;
}

/** 秒 → "M:SS"（与 `SpaceVideo.length` 同格式，喂给 `parseDurationText` 解析） */
function secondsToLength(seconds: number): string {
  const total: number = seconds > 0 ? Math.floor(seconds) : 0;
  const mm: number = Math.floor(total / 60);
  const ss: number = total % 60;
  return `${mm}:${ss < 10 ? '0' : ''}${ss}`;
}

/**
 * 用「歌单里已有的该 UP 视频」当种子，从相关推荐里捞出同 UP 的其它投稿。
 *
 * 为什么它能救搜索反查救不了的场：搜索是按**视频内容**匹配的，UP 昵称不出现在标题里时
 * 命中就是 0；related 是 B 站自己的推荐关系，**不需要任何关键词**。
 *
 * ⚠️ 种子来自调用方（已订阅歌单 / 当前列表），首次订阅时歌单是空的 → 无种子 → 返回空，
 * 由调用方继续退到空间接口。
 */
export async function getUserVideosViaRelated(
  targetMid: string,
  seedBvids: string[],
  maxItems: number,
  maxSeeds: number = 2
): Promise<UpVideosSearchResult> {
  if (targetMid.length === 0 || seedBvids.length === 0) {
    return { list: [], searchOk: true };
  }
  const out: SpaceVideo[] = [];
  const seen: Set<string> = new Set<string>();
  let usedSeeds: number = 0;
  for (let i = 0; i < seedBvids.length && usedSeeds < maxSeeds; i++) {
    const seed: string = seedBvids[i];
    if (!seed || seen.has(seed)) {
      continue;
    }
    seen.add(seed);
    let rel: RelatedVideo[] = [];
    try {
      rel = await getRelatedVideos(seed);
    } catch (e) {
      console.warn(`related failed for seed ${seed}: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
      continue;
    }
    usedSeeds++;
    for (let j = 0; j < rel.length; j++) {
      const v: RelatedVideo = rel[j];
      if (String(v.ownerMid) !== targetMid || !v.bvid || seen.has(v.bvid)) {
        continue;
      }
      seen.add(v.bvid);
      out.push({
        bvid: v.bvid,
        aid: v.aid,
        title: v.title,
        pic: v.pic,
        length: secondsToLength(v.duration),
        play: v.play,
        created: v.pubdate,
        description: '',
        author: v.ownerName
      });
      if (out.length >= maxItems) {
        break;
      }
    }
    if (out.length >= maxItems) {
      break;
    }
  }
  // 种子全挂（接口被限）才算「这条路不可用」；种子有效但 0 命中是正常结果
  return { list: out, searchOk: usedSeeds > 0 };
}

/** `collectUpVideos` 的数据来源（ArkTS 不用 enum，用数字常量） */
export const UP_VIA_NONE: number = 0;
export const UP_VIA_SEARCH: number = 1;
export const UP_VIA_RELATED: number = 2;
export const UP_VIA_SPACE: number = 3;

/** 多源兜底的统一结果 */
export interface UpVideosCollectResult {
  list: SpaceVideo[];
  /** 数据来自哪条路（UP_VIA_*）：决定提示文案该说「已是最新」还是「被限流」 */
  via: number;
  /** via=UP_VIA_NONE 时的真实原因（人话），其余情况为空串 */
  reason: string;
}

/**
 * 取某 UP 的投稿（**多源兜底统一入口**）。
 *
 * ⚠️ 两个页面（PlaylistDetail 的「拉取新投稿」、UpSpacePage 的订阅 / 拉取）**都必须调这里**，
 * 不要各自拼链路 —— 历史上就是因为各写一份，`getUserVideosViaSearch` 改签名时漏改了
 * PlaylistDetail，报错却指向别处。策略只在这里维护一份。
 *
 * 三级兜底见本小节顶部注释。返回 `via` 是为了让 UI 能区分：
 *   · 拿到了数据但全被去重 → 「已经是最新」（不是故障，别让用户以为 App 坏了）；
 *   · 三条路都没货 → 「B 站暂时不给，稍后再试」。
 */
export async function collectUpVideos(
  mid: string,
  nickname: string,
  seedBvids: string[],
  maxItems: number,
  spaceAttempts: number = 3
): Promise<UpVideosCollectResult> {
  // ⓪ 登录态优先空间接口：全量、pubdate 排序、真分页（UpSpacePage hasMore 的前提）。
  //    失败（SESSDATA 失效 / 瞬态风控）→ 落回下面的匿名态同款顺序，行为无回归。
  //    ps 由 getUserVideos* 内部钳到 50（超上限恒 -400，见 SPACE_PS_MAX）。
  if (HttpUtil.getLoginCookie().length > 0) {
    try {
      const vlist: SpaceVideo[] = await getUserVideosWithRetry(Number(mid), 1, maxItems, 'pubdate', spaceAttempts);
      if (vlist.length > 0) {
        console.info(`collectUpVideos: via=space(logged-in) mid=${mid} n=${vlist.length}`);
        return { list: vlist, via: UP_VIA_SPACE, reason: '' };
      }
    } catch (e) {
      console.warn(`collectUpVideos: space(logged-in) failed: ${
        e instanceof Error ? e.message : JSON.stringify(e)}`);
    }
  }

  // ① 搜索反查
  try {
    const r: UpVideosSearchResult = await getUserVideosViaSearch(mid, nickname, maxItems);
    if (r.list.length > 0) {
      console.info(`collectUpVideos: via=search mid=${mid} n=${r.list.length}`);
      return { list: r.list, via: UP_VIA_SEARCH, reason: '' };
    }
  } catch (e) {
    console.warn(`collectUpVideos: search failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
  }

  // ② related 扩散
  try {
    const r: UpVideosSearchResult = await getUserVideosViaRelated(mid, seedBvids, maxItems);
    if (r.list.length > 0) {
      console.info(`collectUpVideos: via=related mid=${mid} n=${r.list.length}`);
      return { list: r.list, via: UP_VIA_RELATED, reason: '' };
    }
  } catch (e) {
    console.warn(`collectUpVideos: related failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
  }

  // ③ 空间接口（老路，不稳定，仅兜底）
  try {
    const vlist: SpaceVideo[] = await getUserVideosWithRetry(Number(mid), 1, maxItems, 'pubdate', spaceAttempts);
    if (vlist.length > 0) {
      console.info(`collectUpVideos: via=space(fallback) mid=${mid} n=${vlist.length}`);
      return { list: vlist, via: UP_VIA_SPACE, reason: '' };
    }
    console.warn(`collectUpVideos: all sources empty (space returned empty list) mid=${mid}`);
    return { list: [], via: UP_VIA_NONE, reason: '' };
  } catch (e) {
    console.warn(`collectUpVideos: all sources failed mid=${mid}: ${
      e instanceof Error ? e.message : JSON.stringify(e)}`);
    return {
      list: [],
      via: UP_VIA_NONE,
      reason: e instanceof Error ? e.message : JSON.stringify(e)
    };
  }
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
 * 把多 P 视频（B 站音乐的「50 首精选合集」这类）或 B 站「合集」（ugc_season，
 * 多个独立视频的集合）展开成曲目列表；两者皆无的单视频返回空数组。
 *
 * 首个分 P 刻意复用 base.id：播放首个分 P 时用的就是原 track，
 * 这样展开后当前曲目在队列里的位置不变，currentIndex 不会错位、播放在展开瞬间不会打断。
 * 其余分 P 用 `bvid#cid` 作 id——cid 唯一，切歌时能正确取到对应分 P 的音频流。
 *
 * ⚠️ expandSeason 默认 false：合集里每个条目的 view 响应**同样**带 ugc_season，
 * 播放（MusicPlayer）/ 下载（DownloadManager）链路若也展开，下载合集里任意一集
 * 都会被扩成整季（递归翻倍）。只有「保存合集为歌单」这种用户显式要整季的入口才传 true。
 */
export async function expandVideoParts(bvid: string, base?: Track, expandSeason: boolean = false): Promise<Track[]> {
  if (!bvid) {
    return [];
  }
  const detail: VideoDetail = await getVideoDetail(bvid);
  const pages: VideoPageInfo[] = detail.pages ? detail.pages : [];
  if (pages.length <= 1) {
    // 多 P 不存在；用户显式要求时再看合集（ugc_season）
    return expandSeason ? expandSeasonEpisodes(bvid, detail, base) : [];
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

/**
 * 展开 B 站「合集」（ugc_season）。与多 P（同一视频的 pages）不同，合集的每个
 * 条目是**独立投稿**：自带 bvid/cid，各自解析音源 —— id 直接用其 bvid。
 * 命中用户点开的那个视频（bvid 相同）时复用 base 条目，保持搜索结果的
 * id / 标题 / 封面不变；其余条目用 episode 数据构建（标题过 splitPartTitle
 * 剥掉 "01." 类序号并拆 "歌手-歌名"，与多 P 展开的命名口径一致）。
 * 条目 bvid 异常（下架 / 付费，返回空串）直接跳过。
 */
function expandSeasonEpisodes(bvid: string, detail: VideoDetail, base?: Track): Track[] {
  const season: UgcSeason | undefined = detail.ugc_season;
  if (!season || !season.sections) {
    return [];
  }
  // 跨 section 汇总（多数合集只有一个 section）
  const eps: SeasonEpisode[] = [];
  for (let i = 0; i < season.sections.length; i++) {
    const list: SeasonEpisode[] = season.sections[i].episodes ? season.sections[i].episodes : [];
    for (let j = 0; j < list.length; j++) {
      eps.push(list[j]);
    }
  }
  if (eps.length <= 1) {
    return [];
  }
  const fallbackArtist: string = base && base.artist ? base.artist : (detail.owner ? detail.owner.name : '');
  const seasonCover: string = season.cover ? toHttpsUrl(season.cover)
    : (base && base.coverUrl ? base.coverUrl : toHttpsUrl(detail.pic));
  const baseBvid: string = base && base.bvid ? base.bvid : bvid;
  const out: Track[] = [];
  for (let i = 0; i < eps.length; i++) {
    const ep: SeasonEpisode = eps[i];
    if (!ep.bvid || ep.bvid.indexOf('BV') !== 0) {
      continue;
    }
    // 用户点开的视频：复用原条目（含 id），位置仍在合集的原顺序处
    if (base && ep.bvid === baseBvid) {
      out.push(base);
      continue;
    }
    const partTitle: string = ep.page && ep.page.part && ep.page.part.length > 0 ? ep.page.part : ep.title;
    const parsed: PartTitle = splitPartTitle(partTitle);
    out.push(buildTrack({
      id: ep.bvid,
      bvid: ep.bvid,
      aid: String(ep.aid),
      cid: String(ep.cid),
      title: parsed.title.length > 0 ? parsed.title : ep.title,
      artist: parsed.artist.length > 0 ? parsed.artist : (ep.author ? ep.author.name : fallbackArtist),
      coverUrl: ep.pic ? toHttpsUrl(ep.pic) : seasonCover,
      duration: ep.duration ?? (ep.page ? ep.page.duration : 0),
      upMid: ep.author ? String(ep.author.mid) : '',
      pubdate: 0
    }));
  }
  return out;
}

/**
 * playurl 公共参数。
 *
 * ⚠️ fnval=4048（2026-10-08 从 16 改）：16 只拿基础 DASH 三档（64K/132K/192K），
 * 杜比全景声需要 fnval 含 256 位（4048 已覆盖）**且请求带登录 Cookie（大会员）** 服务端
 * 才会下发（杜比在 dash.dolby.audio、Hi-Res 在 dash.flac.audio，见 collectAudioStreams）。
 * 匿名状态下 4048 与 16 返回完全一致（2026-09-28 实测），无回归。
 */
const PLAYURL_BASE_PARAMS: Record<string, string | number> = {
  qn: 0,
  fnver: 0,
  fnval: 4048,
  fourk: 1
};

/**
 * 取流统一入口：按场景选端点。
 *
 * · 旧端点 `/x/player/playurl`（无签名）：全场景兜底，匿名 / 标准档 / 高品质档全走它
 *   （长期线上验证过的稳定通道，不动它 = 点歌链路零回归）。
 * · 新端点 `/x/player/wbi/playurl`（WBI 签名，官方 web 播放器现用，旧端点已标记废弃）：
 *   **仅在「无损偏好 + 已登录」时作为主通道** —— 这是唯一需要服务端下发 flac/dolby
 *   高档位的场景；wbi key 拉取失败 / 网络抖动 / 风控限流时自动落回旧端点。
 *   确定性业务错误（-404 等）不回退：旧端点只会给同样的答案，白多一次请求。
 *
 * @param idParams 视频标识：{ bvid, cid } 或 { avid, cid }
 * @param preferredQuality 首选音频档位 id（0 = 无偏好）
 */
async function fetchPlayUrlData(
  idParams: Record<string, string | number>,
  preferredQuality: number
): Promise<PlayUrlData> {
  const params: Record<string, string | number> = Object.assign({}, idParams, PLAYURL_BASE_PARAMS);
  const wantHiRes: boolean =
    preferredQuality === AUDIO_Q_HIRES && HttpUtil.getLoginCookie().length > 0;
  if (wantHiRes) {
    try {
      const query: string = await encodeWbi(params);
      const data: BiliEnvelope<PlayUrlData> = await HttpUtil.requestJson<BiliEnvelope<PlayUrlData>>(
        `${BILI_API}/x/player/wbi/playurl?${query}`
      );
      if (data.code !== 0) {
        throw new BiliApiError(data.code, data.message, '/x/player/wbi/playurl');
      }
      return data.data;
    } catch (e) {
      if (e instanceof BiliApiError && !isRetryableFetchError(e)) {
        throw e;
      }
      console.warn(`wbi playurl failed, fallback to legacy: ${
        e instanceof Error ? e.message : JSON.stringify(e)}`);
    }
  }
  return biliFetch<PlayUrlData>('/x/player/playurl', params);
}

export async function getPlayUrl(bvid: string, cid: number, preferredQuality: number = 0): Promise<PlayUrlData> {
  // 同 view：这是决定「能不能出声」的最后一跳，必须退避重试
  // （fetchPlayUrlData 内部已带「wbi→旧端点」双通道，这里再叠一层瞬态退避）
  const total: number = SOURCE_RETRY_DELAYS_MS.length;
  for (let attempt = 0; attempt <= total; attempt++) {
    try {
      return await fetchPlayUrlData({ bvid: bvid, cid: cid }, preferredQuality);
    } catch (err) {
      const left: number = total - attempt;
      if (left <= 0 || !isRetryableFetchError(err)) {
        throw err;
      }
      const delay: number = SOURCE_RETRY_DELAYS_MS[attempt];
      console.warn(`playurl failed (attempt ${attempt + 1}/${total + 1}), retry in ${delay}ms: ${JSON.stringify(err)}`);
      await sleep(delay);
    }
  }
  // 循环内要么 return 要么 throw，这里只是让类型收敛
  throw new Error('playurl failed after retry');
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

/**
 * 归一化单条音轨：把档位补进 `quality` 字段。
 *
 * ⚠️ 2026-10-08 关键修正：B 站 playurl 响应的 dash 音轨对象**只有 `id` 没有 `quality`**
 * （bilibili-API-collect 两个响应示例一致：id=30280/30232/30216…）。而档位选择
 * （pickAudioStream）按 `quality` 匹配 —— 不归一化的话所有偏好选择都因
 * `undefined === 30216` 永远匹配不上，全部落到「带宽最大」兜底，
 * 表现即「登录与否、选标准还是无损，拿到的都是 192K」。
 */
function normalizeAudioStream(raw: AudioStream): AudioStream {
  if (raw.quality > 0) {
    return raw;
  }
  return {
    id: raw.id,
    quality: raw.id,
    bandwidth: raw.bandwidth,
    mimeType: raw.mimeType,
    codecid: raw.codecid,
    baseUrl: raw.baseUrl,
    backupUrl: raw.backupUrl ?? []
  };
}

/**
 * 把响应里**所有**音轨归一化进一个候选列表：dash.audio（基础三档）+
 * dash.flac.audio（Hi-Res，**单对象**）+ dash.dolby.audio（杜比，数组）。
 *
 * 为什么必须合并（2026-10-08 修「登录后音质选项不生效」）：B 站协议里高档位
 * 音轨**不放在 dash.audio**——杜比在 dash.dolby.audio、Hi-Res 在 dash.flac.audio。
 * 此前只读 dash.audio，导致 audioQualityCandidates 里 30250/30251 永远匹配不上，
 * 「无损」选项最终按带宽最大兜底拿 192K，登录了也看不出区别。
 * 无对应音轨时 flac 整体为 null、dolby.audio 为 null —— 一律真值判断。
 */
function collectAudioStreams(playData: PlayUrlData): AudioStream[] {
  const out: AudioStream[] = [];
  const dash: DashData | undefined = playData.dash;
  if (!dash) {
    return out;
  }
  // ⚠️ 这里**不能**在 dash.audio 为空时直接 return：服务端存在「只有 flac / dolby」的
  // 极端响应，早退会让下面的合并逻辑整段失效（旧实现的空洞）。
  const base: AudioStream[] = dash.audio ? dash.audio : [];
  for (let i = 0; i < base.length; i++) {
    pushIfPlayable(out, base[i]);
  }
  const flac: FlacStream | undefined = dash.flac;
  const flacAudio: AudioStream | undefined = flac ? flac.audio : undefined;
  if (flacAudio) {
    pushIfPlayable(out, flacAudio);
  }
  const dolby: DolbyData | undefined = dash.dolby;
  const dolbyAudio: AudioStream[] | null = dolby ? (dolby.audio ?? null) : null;
  if (dolbyAudio) {
    for (let i = 0; i < dolbyAudio.length; i++) {
      pushIfPlayable(out, dolbyAudio[i]);
    }
  }
  // 诊断日志：档位 id + 实测带宽（不含 URL / 凭据），用于核对「无损是否真的取到 30251」
  const ids: string[] = [];
  for (let i = 0; i < out.length; i++) {
    ids.push(`${out[i].quality}@${out[i].bandwidth}`);
  }
  console.info(`playurl audio streams: n=${out.length} [${ids.join(', ')}]` +
    ` flac=${flacAudio ? 'yes' : 'no'} dolby=${dolbyAudio && dolbyAudio.length > 0 ? String(dolbyAudio.length) : 'no'}`);
  return out;
}

/**
 * 只有「带真实地址」的音轨才算候选。
 *
 * 服务端偶尔会给出一条 baseUrl 为空串的占位音轨（多见于版权受限的稿件）；
 * 若把它选成主音轨，switchSource 会因为空 URL 直接失败 —— 表现为「这首歌永远播不了」，
 * 而同一响应里其实还有别的可用音轨。在这里滤掉，等于把兜底提前到选择阶段。
 */
function pushIfPlayable(out: AudioStream[], raw: AudioStream): void {
  if (!raw) {
    return;
  }
  const normalized: AudioStream = normalizeAudioStream(raw);
  if (!normalized.baseUrl || normalized.baseUrl.length === 0) {
    return;
  }
  out.push(normalized);
}

/**
 * 按偏好挑一条 dash 音轨。
 *
 * ⚠️ **不要用它来组装可播地址**（2026-10-22）：它只认 dash，遇到 durl 老视频必抛
 * `No audio stream available`。组装音源请走 `resolveAudioSelection`
 * （内部会先 dash、再 durl 兜底）。本函数保留给「只想知道 dash 里挑了哪一档」的场景。
 */
export function getBestAudioStream(playData: PlayUrlData, preferredQuality: number = 0): AudioStream {
  // 不能直接写 playData.dash.audio：dash 缺失时（服务端偶发把 fnval 降级成 durl 老格式）
  // 会抛 TypeError「Cannot read property 'audio' of undefined」，
  // 被上层当成「这首歌播不了」而不是「响应格式异常」。显式判空，给出可识别的错误。
  const audioStreams: AudioStream[] = collectAudioStreams(playData);
  if (audioStreams.length === 0) {
    throw new Error('No audio stream available');
  }
  return pickAudioStream(audioStreams, preferredQuality);
}

/**
 * 「降档阶梯」：解析/播放失败时逐级向下换档位用的候选序列（2026-10-22）。
 *
 * 为什么要它：`audioQualityCandidates` 回答的是「用户想要的那一档不存在时退到哪」，
 * 而且它的序列里**混着更大的档**（高品质 → 无损 → 杜比），语义是「不亏」。
 * 这里要的是完全相反的语义 —— **只降不升**，专治「某一档音轨本身播不了」
 * （flac 解码失败 / 该档 CDN 全部拒绝 / 该档 URL 被风控），
 * 一路降到 64K 只要能出声就比「点了没反应」强。
 *
 * 首个元素恒为用户偏好档本身：第 1 次重试仍按原档重解析（最常见原因是直链过期，
 * 换档反而把音质白白降掉），第 2 次起才开始降档。
 */
export function qualityDowngradePlan(preferredId: number): number[] {
  if (preferredId === AUDIO_Q_HIRES) {
    return [AUDIO_Q_HIRES, AUDIO_Q_DOLBY, AUDIO_Q_192K, AUDIO_Q_132K, AUDIO_Q_64K];
  }
  if (preferredId === AUDIO_Q_DOLBY) {
    return [AUDIO_Q_DOLBY, AUDIO_Q_192K, AUDIO_Q_132K, AUDIO_Q_64K];
  }
  if (preferredId === AUDIO_Q_64K) {
    // 省流量用户已经是地板档，再降无处可降
    return [AUDIO_Q_64K];
  }
  if (preferredId === AUDIO_Q_132K) {
    return [AUDIO_Q_132K, AUDIO_Q_64K];
  }
  // 192K 及未知取值（含 0 = 「无所谓」）：按品质从高到低给完整阶梯
  return [AUDIO_Q_192K, AUDIO_Q_132K, AUDIO_Q_64K];
}

/**
 * 统一音源选择结果：把 dash 音轨与 durl 分段流收敛成同一个形状，
 * 让 buildTrackSource / extractAudioByAvidCid 两条组装路径不再各写一遍。
 */
interface AudioSelection {
  url: string;
  backupUrls: string[];
  quality: number;
  mimeType: string;
  bandwidth: number;
  /** 'dash' | 'durl'，仅用于日志与排查 */
  container: string;
}

/**
 * durl 兜底：老视频 / 服务端把 fnval 降级成 durl 时，响应里**一条 dash 音轨都没有**，
 * 只有整段 mp4 的分段地址。旧实现到这一步直接抛 `No audio stream available`，
 * 表现就是「这个视频怎么点都播不出来」—— 而它其实是能出声的。
 *
 * 取舍：
 *  · 只取第一段。多段视频（超长投稿）意味着后面的分段不播，但**比整首不能播强**，
 *    且音乐场景几乎不会命中多段；
 *  · 码率用 size/length 反算，比留 0 更有用（播放页会显示真实码率而不是空白）。
 */
function durlToAudioSelection(playData: PlayUrlData): AudioSelection | null {
  const durl: DurlItem[] | undefined = playData.durl;
  if (!durl || durl.length === 0) {
    return null;
  }
  const first: DurlItem = durl[0];
  if (!first || !first.url || first.url.length === 0) {
    return null;
  }
  // 逐条真值判断而不是 Array.isArray：backup_url 是可缺属性，
  // ArkTS 对「可选属性 + Array.isArray 收窄」的处理不如显式判空稳
  const backups: string[] = [];
  const rawBackups: string[] | undefined = first.backup_url;
  if (rawBackups) {
    for (let i = 0; i < rawBackups.length && backups.length < 3; i++) {
      const u: string = rawBackups[i];
      if (u && u.length > 0) {
        backups.push(u);
      }
    }
  }
  let bandwidth: number = 0;
  if (first.size > 0 && first.length > 0) {
    // ⚠️ durl.length 是**毫秒**（实测 212394 对应 3 分 32 秒），
    // 直接 size*8/length 会算出 396bps 这种荒谬值，播放页码率显示就全错了
    const seconds: number = first.length / 1000;
    bandwidth = Math.round((first.size * 8) / seconds);
  }
  console.warn(`no dash audio, fallback to durl (segments=${durl.length}, ` +
    `bandwidth=${bandwidth})`);
  return {
    url: first.url,
    backupUrls: backups,
    // 档位 id 留 0 = 无档位概念：formatTrackQuality 会据此只显示实测码率
    quality: 0,
    mimeType: 'video/mp4',
    bandwidth: bandwidth,
    container: 'durl'
  };
}

function resolveAudioSelection(playData: PlayUrlData, preferredQuality: number): AudioSelection {
  const streams: AudioStream[] = collectAudioStreams(playData);
  if (streams.length > 0) {
    const best: AudioStream = pickAudioStream(streams, preferredQuality);
    return {
      url: best.baseUrl,
      // 备用直链只取前 3 条：主直链挂死 / 被拒时的快速回退用不了那么多，
      // 多了只是白占 sourceCache 的内存。normalizeAudioStream 在 quality>0 的
      // 早退分支里不补 backupUrl，这里必须真值判断，否则 slice 直接抛 undefined。
      backupUrls: Array.isArray(best.backupUrl) ? best.backupUrl.slice(0, 3) : [],
      quality: best.quality,
      mimeType: best.mimeType,
      bandwidth: best.bandwidth,
      container: 'dash'
    };
  }
  const byDurl: AudioSelection | null = durlToAudioSelection(playData);
  if (byDurl !== null) {
    return byDurl;
  }
  throw new Error('No audio stream available');
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
  // dash 音轨优先，没有则退 durl（老视频）；两者都空才抛错，见 resolveAudioSelection
  const best: AudioSelection = resolveAudioSelection(playData, preferredQuality);
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
    audioUrl: best.url,
    audioBackupUrls: best.backupUrls,
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
  /** 视频发布时间（unix 秒）。原始响应带、旧声明漏了；可缺 —— 缺则 UI 不显示发布时间 */
  pubdate?: number;
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
  /** 视频发布时间（unix 秒），可缺 —— 缺则 UI 不显示 */
  pubdate?: number;
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
      duration: it.duration ?? 0,
      pubdate: it.pubdate
    });
  }
  return out;
}

//
// 数据源变迁（本机实测对照结论）：
//   · `ranking/region?rid=3&day=3`（音乐区旧榜）只返回 **11 条**，且 pn/ps 完全无效，
//     字段是 author(str) / duration("0:15") / 无 cid / 无 owner —— 既不能分页，信息也不全；
//   · `ranking/v2?rid=3&type=all`（音乐区 v2 榜）一次返回 96 条，但 B 站已下线 web 分区
//     排行榜，该接口**停更于 2025-03-31**（榜内 pubdate 全部冻结在那周）—— 成了死数据源
//     （2026-10 用户反馈「排行榜日期都是很久」即此因）；
//   · `ranking/v2?rid=0&type=all`（**全站排行榜**）仍在**每日更新**（2026-10 复测：100 条，
//     最新一条发布于复测前一日）—— 现行数据源。匿名 web API 中已无仍在更新的音乐专属排行榜。
//
// v2 **不支持 pn/ps**（传 pn=2 仍返回同一批），「上拉加载更多」只能前端分页：
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
  /** 视频发布时间（unix 秒）。原始响应带、旧声明漏了；可缺 */
  pubdate?: number;
}

/** 全站排行榜（ranking/v2?rid=0，每日更新）。字段与"视频详情"一致：有 owner 对象、有 cid */
export async function getGlobalRankingV2(): Promise<RankingVideoItem[]> {
  const data: { list: RankingVideoItem[] } = await biliFetch<{ list: RankingVideoItem[] }>(
    '/x/web-interface/ranking/v2',
    { rid: 0, type: 'all' }
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
 * 音乐中心「新歌榜」（最新发布）。
 * 只有固定 18 条，`pn`/`ps` 传了也无效（返回同一批），所以只置顶音乐中心首屏、
 * 不参与翻页（翻页走综合榜，见 SearchPage 的 loadMoreCenter）。
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

/**
 * `folder/created/list-all` 的原始条目。
 *
 * ⚠️⚠️ **字段名是 snake_case**（`media_count`），而 `FavoriteFolder` 用 camelCase。
 * 曾直接把原始响应当 `FavoriteFolder` 返回（零归一化）→ `mediaCount` **恒为 undefined**，
 * 下游 `folder.mediaCount <= PLAYLIST_MAX_ITEMS` 恒为 `false`，于是：
 *   · 双向同步的删除分支**从未生效**（永远只增不减，与文档宣称的行为不一致）；
 *   · 「单夹 >500 首只镜像最新 500 首」的判定同样失效；
 *   · 「服务端自报非空却拿到 0 条」的风控识别也失效（undefined > 0 = false）。
 * 2026-10-22 真机日志实证：`mediaCount=undefined sizeOk=false`。两个名字都声明为可选，
 * 归一化时下划线优先、驼峰兜底，防止 B 站哪天改回驼峰。
 */
interface FavoriteFolderRaw {
  id?: number;
  fid?: number;
  mid?: number;
  attr?: number;
  title?: string;
  media_count?: number;
  mediaCount?: number;
}

/** 收藏夹列表结果（命名接口：内联对象类型违反 arkts-no-obj-literals-as-types） */
export interface FavoriteFoldersResult {
  count: number;
  list: FavoriteFolder[];
}

/** 收藏夹列表（归一化成 camelCase；⚠️ 不能直接把原始响应返回给上层） */
export async function getFavoriteFolders(mid: number): Promise<FavoriteFoldersResult> {
  const raw: { count?: number; list?: FavoriteFolderRaw[] } =
    await biliFetch<{ count?: number; list?: FavoriteFolderRaw[] }>('/x/v3/fav/folder/created/list-all', {
      up_mid: mid
    });
  const src: FavoriteFolderRaw[] = (raw && raw.list) ? raw.list : [];
  const list: FavoriteFolder[] = [];
  for (let i = 0; i < src.length; i++) {
    const r: FavoriteFolderRaw = src[i];
    const cnt: number = r.media_count ?? r.mediaCount ?? 0;
    list.push({
      id: r.id ?? 0,
      title: r.title ?? '',
      mediaCount: Number.isFinite(cnt) ? cnt : 0
    });
  }
  return { count: (raw && typeof raw.count === 'number') ? raw.count : list.length, list: list };
}

// ===== 收藏夹内容（把收藏夹镜像成本地歌单，2026-10-13）=====
//
// ⚠️ 本节全部为**未实测**实现：`x/v3/fav/resource/list` 在本工程此前零实现、
// 零调用（grep `fav/resource` = 0）。首次真机运行必须打印 raw 响应核对：
// 字段名（medias / info.media_count / has_more）、`ps` 上限、`attr` 位语义、
// `duration` 单位（秒 or 毫秒）、是否需要 wbi 签名。详见方案文档第 10 节。

/** 收藏夹接口风控兜底码表：与 FOLLOWINGS_RISK_CODES 同一套口径 */
const FAV_RISK_CODES: number[] = [-352, -412, -509, -799];

/**
 * 收藏夹分页大小。
 * 2026-10-22 实测（匿名直连 `fav/resource/list`）：`ps=40` 正常返回 40 条，
 * `has_more` / `info.media_count` 均正常 → 同样条数下请求数减半（对齐 BBPlayer 的口径）。
 */
const FAV_RESOURCE_PS: number = 40;

/** 收藏夹条目内嵌的 UP 主信息 */
interface FavUpper {
  mid?: number;
  name?: string;
}

/** 收藏夹条目的计数信息（只取播放量） */
interface FavCntInfo {
  play?: number;
}

/** fav/resource/list 的原始条目：字段可能全缺 → 必须归一化后才进 UI */
interface FavResourceRawItem {
  /** 收藏条目 id（**不是** aid） */
  id?: number;
  /** 2 = 视频 / 12 = 音频 / 21 = 合集……本功能只保留视频类（bvid 非空者） */
  type?: number;
  bvid?: string;
  aid?: number;
  title?: string;
  cover?: string;
  /** ⚠️ 待实测单位（秒 or 毫秒） */
  duration?: number;
  /** 发布时间（unix 秒） */
  pubtime?: number;
  upper?: FavUpper | null;
  cnt_info?: FavCntInfo | null;
  /** 失效/私密标记：非 0 → 该条目已不可播，同步时应过滤 */
  attr?: number;
  intro?: string;
}

/** 收藏夹元信息（fav/resource/list 里回带的 info） */
interface FavFolderInfo {
  id?: number;
  title?: string;
  media_count?: number;
}

interface FavResourceRawData {
  info?: FavFolderInfo | null;
  medias?: FavResourceRawItem[] | null;
  has_more?: boolean;
}

/** 归一化后的收藏夹条目（不含可选/any 字段，可直接进 UI 与落库） */
export interface FavResourceItem {
  bvid: string;
  aid: number;
  title: string;
  cover: string;
  /** 秒（已按 normalizeFavDuration 归一） */
  duration: number;
  pubdate: number;
  upMid: string;
  upName: string;
  playCount: number;
  /** true = `attr` 非 0（失效/私密）或 bvid 缺失 —— 同步时应过滤掉 */
  invalid: boolean;
}

/** 收藏夹单页结果 */
export interface FavResourcePage {
  items: FavResourceItem[];
  hasMore: boolean;
  /** 服务端 info.media_count；0 = 未知 */
  mediaCount: number;
}

/** 收藏夹全量拉取结果 */
export interface FavAllResult {
  /**
   * 全部分页成功走完（每页 code=0 且 has_more 走到 false）= true。
   * ⚠️ **只有 true 才允许执行「删除本地曲目」**（见 FavSyncManager 的删除安全门控）：
   * 任一分页失败/风控 → false，此时必须只增不减，否则会把「没拉到」误判成「已取消收藏」。
   */
  complete: boolean;
  items: FavResourceItem[];
  /** 首个失败的人话原因；complete=true 时为空串 */
  failReason: string;
  /**
   * 实际成功拉取的页数（诊断用）。
   * 「首页 info.media_count=44 却只拉了 1 页」= has_more 判定异常 / 被拦，一眼可辨。
   */
  pages: number;
  /** 首页 `info.media_count`（服务端自报总条目数；0 = 未知/未取到） */
  reportedTotal: number;
  /**
   * ids 两段式通道拿到的**完整收藏顺序**（bvid，已剔除失效/隐藏条目）。
   * 空数组 = 本轮走的是「全量分页」兜底通道。
   *
   * 调用方拿到非空 `orderedBvids` 时，应按它重建歌单顺序：
   * `items` 里有该 bvid 就用它（新详情），否则用本地已有的 Track 补。
   */
  orderedBvids: string[];
  /** ids 里有、但详情分页拉不到的 bvid（被 UP 隐藏 / 已删除），不会进入 `orderedBvids` */
  hiddenBvids: string[];
  /**
   * true = 走了 ids 两段式通道 —— 此时 **`items` 只包含「本轮新拉到的详情」**，
   * 不等于收藏夹全量（本地已有的不重复拉）。需要全量时不要看 `items`，看 `orderedBvids`。
   */
  usedIdsChannel: boolean;
}

/**
 * duration 归一：⚠️ 待真机验证单位。B 站多数接口给「秒」，若给的是毫秒会出现
 * 荒谬的大值（> 24h）→ 这里按 > 86400 视为毫秒换算回秒，作为防御性兜底。
 */
function normalizeFavDuration(raw: number): number {
  if (!Number.isFinite(raw) || raw <= 0) {
    return 0;
  }
  return raw > 86400 ? Math.round(raw / 1000) : raw;
}

/** 原始条目 → 归一化条目（服务端缺字段防御：宁可空值也不要 undefined 进 UI） */
function normalizeFavItem(raw: FavResourceRawItem): FavResourceItem {
  const bvid: string = raw.bvid ?? '';
  const attr: number = raw.attr ?? 0;
  const upper: FavUpper | null = raw.upper ?? null;
  const cnt: FavCntInfo | null = raw.cnt_info ?? null;
  return {
    bvid: bvid,
    aid: raw.aid ?? 0,
    title: stripHtmlTags(raw.title ?? ''),
    cover: raw.cover ?? '',
    duration: normalizeFavDuration(raw.duration ?? 0),
    pubdate: raw.pubtime ?? 0,
    upMid: upper && upper.mid ? String(upper.mid) : '',
    upName: upper && upper.name ? upper.name : '',
    playCount: cnt && cnt.play ? cnt.play : 0,
    invalid: attr !== 0 || bvid.length === 0
  };
}

/**
 * 拉取某个收藏夹的一页内容。
 *
 * 风控兜底与 getFollowings 同思路：先走明文 biliFetch，吃到风控码
 * （FAV_RISK_CODES）再用 encodeWbi 签名重试**一次**；仍是风控码就原样抛
 * —— 由同步管理器展示 code 让用户判断该等还是该换网。-101（未登录）属
 * 确定性错误，直接抛不重试。
 *
 * ⚠️ 必须带 SESSDATA（HttpUtil 登录后自动附加）；匿名调用会返回 -101 或空。
 */
export async function getFavResources(mediaId: number, pn: number = 1): Promise<FavResourcePage> {
  const path: string = '/x/v3/fav/resource/list';
  const params: Record<string, string | number> = {
    media_id: mediaId,
    pn: pn,
    ps: FAV_RESOURCE_PS,
    platform: 'web',
    order: 'mtime'
  };
  let raw: FavResourceRawData | undefined;
  try {
    raw = await biliFetch<FavResourceRawData>(path, params);
  } catch (err) {
    if (!(err instanceof BiliApiError) || FAV_RISK_CODES.indexOf(err.code) < 0) {
      throw err;
    }
    const query: string = await encodeWbi(params);
    const env: BiliEnvelope<FavResourceRawData> =
      await HttpUtil.requestJson<BiliEnvelope<FavResourceRawData>>(`${BILI_API}${path}?${query}`);
    if (env.code !== 0) {
      throw new BiliApiError(env.code, env.message, path);
    }
    raw = env.data;
  }
  // ⚠️⚠️ **空壳响应必须当风控，绝不能当「这个收藏夹空了」**（2026-10-22 实测确认）：
  // 被风控时接口仍然回 `code=0`，但 `data` 里只有 `v_voucher`（既无 `info` 也无 `medias`）。
  // 若按「0 条 + has_more 缺省 false」处理，就会被判定成「已完整拉取、夹子确实空了」，
  // 上层 `allowDelete` 随即把本地镜像**整单清空** —— 用户看到的现象就是「收藏夹突然变空」。
  // 判据用「info 与 medias 两个字段全缺」：正常空收藏夹仍带 `info`（media_count=0），不会误伤。
  if (!raw || (raw.info === undefined && raw.medias === undefined)) {
    throw new BiliApiError(-412, '收藏夹接口返回空壳（疑似风控验证）', path);
  }
  const src: FavResourceRawItem[] = raw.medias ? raw.medias : [];
  const items: FavResourceItem[] = [];
  for (let i = 0; i < src.length; i++) {
    items.push(normalizeFavItem(src[i]));
  }
  const info: FavFolderInfo | null = (raw && raw.info) ? raw.info : null;
  return {
    items: items,
    hasMore: raw !== undefined && raw.has_more === true,
    mediaCount: (info && info.media_count) ? info.media_count : 0
  };
}

/** `fav/resource/ids` 的原始条目（一次返回整个收藏夹，不翻页） */
interface FavIdRawItem {
  /** ⚠️ 这个 id 是 **aid**（不是收藏条目 id）—— 推送 `deal` / `batch-del` 时直接可用 */
  id?: number;
  bvid?: string;
  /** 2 = 视频稿件；12 = 音频；21 = 合集。本功能只保留 2（音频没有 bvid） */
  type?: number;
}

/** ids 通道的一行（已过滤非视频） */
export interface FavIdEntry {
  bvid: string;
  aid: number;
}

/**
 * 拉取收藏夹**全部**视频的 bvid / aid（`/x/v3/fav/resource/ids`）。
 *
 * 移植自 BBPlayer `lib/facades/syncBilibiliPlaylist/favorite.ts` 的两段式同步：
 * 先用 ids **一个请求拿到全集与收藏顺序**，再只为「本地还没有的」补详情 ——
 * 几百首的收藏夹从「25 页 × 350ms」降到「1 次 ids + 通常 1 页详情」，这才是风控的根本解法。
 *
 * 2026-10-22 实测（匿名）：307 首的夹一次返回 307 条（303 视频 + 4 音频），
 * 字段 `{id(aid), bvid, type}`，顺序 = 收藏顺序（最新在前）。
 *
 * ⚠️ 风控时 `data` 会变成对象（`{v_voucher}`）而不是数组 → 必须判 `Array.isArray`，
 * 否则会拿到空数组被误判成「这个收藏夹空了」。
 */
export async function getFavResourceIds(mediaId: number): Promise<FavIdEntry[]> {
  const path: string = '/x/v3/fav/resource/ids';
  const raw: FavIdRawItem[] = await biliFetch<FavIdRawItem[]>(path, { media_id: mediaId });
  if (!Array.isArray(raw)) {
    throw new BiliApiError(-412, '收藏夹 ids 返回非数组（疑似风控验证）', path);
  }
  const out: FavIdEntry[] = [];
  for (let i = 0; i < raw.length; i++) {
    const r: FavIdRawItem = raw[i];
    const type: number = r.type ?? 0;
    const bvid: string = r.bvid ?? '';
    if (type === 2 && bvid.length > 0) {
      out.push({ bvid: bvid, aid: r.id ?? 0 });
    }
  }
  return out;
}

/** ids 通道失败时返回 null（让全量分页通道兜底），不向上抛 */
async function tryGetFavResourceIds(mediaId: number): Promise<FavIdEntry[] | null> {
  try {
    return await getFavResourceIds(mediaId);
  } catch (e) {
    const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
    console.warn(`fav ids channel failed: ${msg}`);
    return null;
  }
}

/**
 * 收藏夹全量拉取（**两段式**，移植自 BBPlayer `syncBilibiliPlaylist/favorite.ts`）。
 *
 * ① `fav/resource/ids` 一次拿全集 + 收藏顺序（1 个请求，不翻页）；
 * ② 只为「本地还没有的 bvid」补详情（从 pn=1 顺序翻页，命中够即停，`ps=40`）。
 *
 * ids 通道失败 → 自动回落到旧的「全量分页」通道（保持鲁棒）。
 *
 * `knownBvids` 是**本地镜像里已有的 bvid**：传了它，通道②只拉新增条目 ——
 * 稳态一次同步通常只用 2 个请求（ids + 1 页详情），几百首的夹不必再打 20+ 页。
 * 不传（默认空）等价于「全量拉详情」，此时 `items` 就是完整列表（`PlaylistsPage` 的用法）。
 *
 * **complete 的判定是安全核心**：只有「确认拿到全集」才为 true，调用方才允许删本地条目。
 */
export async function getAllFavResources(
  mediaId: number,
  expectedMax: number,
  pageDelayMs: number = 0,
  knownBvids: string[] = []
): Promise<FavAllResult> {
  const ids: FavIdEntry[] | null = await tryGetFavResourceIds(mediaId);
  if (ids !== null && ids.length > 0) {
    return await collectFavByOrderedIds(mediaId, ids, expectedMax, pageDelayMs, knownBvids);
  }
  return await collectFavByFullPages(mediaId, expectedMax, pageDelayMs);
}

/**
 * 通道 A：ids 全集 + 按需补详情（BBPlayer 两段式）。
 *
 * 顺序取 ids 的返回顺序（= 收藏顺序，最新在前）；`items` 只含**本轮新拉到的详情**，
 * 本地已有的条目由调用方用本地 Track 补字段（`orderedBvids` 给出了完整顺序）。
 */
async function collectFavByOrderedIds(
  mediaId: number,
  ids: FavIdEntry[],
  expectedMax: number,
  pageDelayMs: number,
  knownBvids: string[]
): Promise<FavAllResult> {
  const idsTotal: number = ids.length;
  /** 超过单歌单上限 → 只镜像最新的前 expectedMax 条，且禁止删除（与旧口径一致） */
  const capped: boolean = idsTotal > expectedMax;
  const order: FavIdEntry[] = capped ? ids.slice(0, expectedMax) : ids;
  const known: Set<string> = new Set<string>(knownBvids);

  // 需要详情的 bvid = 本地没有的
  const needIds: string[] = [];
  const needSet: Set<string> = new Set<string>();
  for (let i = 0; i < order.length; i++) {
    const bvid: string = order[i].bvid;
    if (!known.has(bvid) && !needSet.has(bvid)) {
      needSet.add(bvid);
      needIds.push(bvid);
    }
  }

  const detailMap: Map<string, FavResourceItem> = new Map<string, FavResourceItem>();
  let pages: number = 0;
  let pending: number = needIds.length;
  let detailFailed: boolean = false;
  let failReason: string = '';
  if (pending > 0) {
    const maxPages: number = Math.ceil(expectedMax / FAV_RESOURCE_PS) + 1;
    let pn: number = 1;
    while (pn <= maxPages && pending > 0) {
      let page: FavResourcePage;
      try {
        page = await getFavResources(mediaId, pn);
      } catch (e) {
        if (e instanceof BiliApiError) {
          failReason = `接口返回 ${e.code}${e.message ? `（${e.message}）` : ''}`;
        } else {
          failReason = e instanceof Error ? e.message : JSON.stringify(e);
        }
        detailFailed = true;
        break;
      }
      pages = pages + 1;
      for (let i = 0; i < page.items.length; i++) {
        const it: FavResourceItem = page.items[i];
        if (needSet.has(it.bvid) && !detailMap.has(it.bvid)) {
          detailMap.set(it.bvid, it);
          pending = pending - 1;
        }
      }
      // 空页 + has_more=true = 被拦或解析失效，继续翻只会重复空请求
      if (page.items.length === 0) {
        break;
      }
      if (!page.hasMore) {
        break;
      }
      pn = pn + 1;
      if (pageDelayMs > 0) {
        await sleep(pageDelayMs);
      }
    }
  }

  const items: FavResourceItem[] = [];
  const orderedBvids: string[] = [];
  const hiddenBvids: string[] = [];
  for (let i = 0; i < order.length; i++) {
    const bvid: string = order[i].bvid;
    const d: FavResourceItem | undefined = detailMap.get(bvid);
    if (d !== undefined) {
      if (d.invalid) {
        // 失效 / 私密：与旧行为一致，不进镜像
        hiddenBvids.push(bvid);
      } else {
        items.push(d);
        orderedBvids.push(bvid);
      }
      continue;
    }
    if (known.has(bvid)) {
      // 本地已有该曲目：不重复拉详情，顺序保留（字段由调用方用本地 Track 补）
      orderedBvids.push(bvid);
      continue;
    }
    // 既没详情、本地也没有 → 被 UP 隐藏 / 已删除 / 详情拉取中断
    hiddenBvids.push(bvid);
  }

  if (detailFailed && failReason.length === 0) {
    failReason = '详情分页失败，本轮按「没拉全」处理';
  }
  return {
    complete: !capped && !detailFailed,
    items: items,
    failReason: capped ? `收藏夹超过 ${expectedMax} 首，只镜像最新 ${expectedMax} 首` : failReason,
    pages: pages,
    reportedTotal: idsTotal,
    orderedBvids: orderedBvids,
    hiddenBvids: hiddenBvids,
    usedIdsChannel: true
  };
}

/** 通道 B（兜底）：全量分页拉详情（ids 接口不可用时）。 */
async function collectFavByFullPages(
  mediaId: number,
  expectedMax: number,
  pageDelayMs: number
): Promise<FavAllResult> {
  const collected: FavResourceItem[] = [];
  let fn: number = 1;
  let complete: boolean = false;
  let failReason: string = '';
  /** 成功拉到的页数（诊断用） */
  let pages: number = 0;
  /** 第 1 页 info.media_count（服务端自报的条目数；pn>1 时该值为 0，只有首页可信） */
  let reportedTotal: number = 0;
  // 页数硬上限：单夹最多 expectedMax 首 ÷ 每页 FAV_RESOURCE_PS，再留 1 页余量，
  // 防止服务端 has_more 恒 true 时死循环
  const maxPages: number = Math.ceil(expectedMax / FAV_RESOURCE_PS) + 1;
  while (fn <= maxPages) {
    let page: FavResourcePage;
    try {
      page = await getFavResources(mediaId, fn);
    } catch (e) {
      // 失败即停：保留已收集的条目（调用方只会用它们做「只增」合并）
      if (e instanceof BiliApiError) {
        failReason = `接口返回 ${e.code}${e.message ? `（${e.message}）` : ''}`;
      } else {
        failReason = e instanceof Error ? e.message : JSON.stringify(e);
      }
      break;
    }
    for (let i = 0; i < page.items.length; i++) {
      collected.push(page.items[i]);
    }
    pages = pages + 1;
    if (fn === 1) {
      reportedTotal = page.mediaCount;
    }
    if (!page.hasMore) {
      complete = true;
      /**
       * 防御「首页满不了却标记无更多」：服务端自报 media_count 比首页条数多，
       * 说明 `has_more` 缺省/异常（多见于收藏夹条目被分批下发或响应被裁剪）。
       * 只判「仅拉到 1 页」这一种，避免把「最后一页恰好满页」误判成没拉全。
       */
      if (pages <= 1 && reportedTotal > page.items.length) {
        complete = false;
        failReason = `服务端报告 ${reportedTotal} 条，首页只返回 ${page.items.length} 条且标记无更多`;
      }
      break;
    }
    if (collected.length >= expectedMax) {
      // 达到安全上限但服务端仍说还有 → 无法确认追平，禁止删
      complete = false;
      failReason = `收藏夹超过 ${expectedMax} 首，未完整拉取`;
      break;
    }
    fn = fn + 1;
    // 页间间隔（降风控）：收藏夹接口对高频分页敏感，调用方按需传 300~500ms
    if (pageDelayMs > 0) {
      await sleep(pageDelayMs);
    }
  }
  // 安全上限截断（只影响返回结果，不改 collected 本身）
  const items: FavResourceItem[] = collected.length > expectedMax
    ? collected.slice(0, expectedMax)
    : collected;
  // ⚠️ 第二道防线（2026-10-22）：首页自报 N 条却一条没拿到 → 一定是被拦/解析失效，
  // 绝不能算「完整拉取成功」，否则上层会按「用户清空了收藏夹」把本地镜像删光。
  if (complete && collected.length === 0 && reportedTotal > 0) {
    complete = false;
    failReason = `服务端报告 ${reportedTotal} 条，实际一条都没拿到（疑似风控），本轮按「没拉全」处理`;
  }
  return {
    complete: complete,
    items: items,
    failReason: failReason,
    pages: pages,
    reportedTotal: reportedTotal,
    orderedBvids: [],
    hiddenBvids: [],
    usedIdsChannel: false
  };
}

/**
 * 收藏夹条目 → Track。
 *
 * `id` 取 `bvid`（与订阅流 / 搜索流的稳定去重键一致）；artist 优先用投稿者昵称、
 * 缺失时回落到收藏夹名（保证列表不至于空着）。
 */
export function mapFavItem(item: FavResourceItem, favName: string): Track {
  return buildTrack({
    id: item.bvid,
    bvid: item.bvid,
    aid: String(item.aid),
    title: item.title,
    artist: item.upName.length > 0 ? item.upName : favName,
    upMid: item.upMid,
    coverUrl: toHttpsUrl(item.cover),
    duration: item.duration,
    playCount: item.playCount,
    pubdate: item.pubdate
  });
}

// ===== 收藏夹写接口（本地 → B 站，2026-10-13「真双向」）=====
//
// ⚠️⚠️ 这几个接口对 B 站是**破坏性写操作**（真删用户账号里的收藏），调用方必须：
//   1) 只重放「用户显式动作」产生的意图（见 service/FavPushStore.ts + FavSyncManager）；
//   2) 绝不静默批量执行；
//   3) `aid <= 0` 时拒绝发送 —— 参数错会取消到**别的视频**，比不删更糟。
//
// ⚠️ 全部**待真机验证**：参数名（add_media_ids / del_media_ids / resources 格式）、
// 是否需要 wbi 签名、重复收藏 / 未收藏时取消 是否返回 code=0（幂等性）见方案 §11。

/** 写接口的风控/限流码：撞上即停本轮，留待下次（不当作失败烧重试次数） */
const FAV_WRITE_RISK_CODES: number[] = [-352, -412, -509, -799];

/** 判断一个错误是否属于「可重试」的写接口失败（风控 / 网络瞬态），供推送编排器分档 */
export function isFavWriteRetryable(e: ESObject): boolean {
  if (e instanceof BiliApiError) {
    return FAV_WRITE_RISK_CODES.indexOf(e.code) >= 0;
  }
  // 非 BiliApiError（HTTP 4xx/5xx、超时、断网）→ 可重试
  return true;
}

/**
 * 收藏一个视频到指定收藏夹。
 *
 * `POST /x/v3/fav/resource/deal`，表单：`rid={aid}&type=2&add_media_ids={mediaId}&csrf={csrf}`。
 * `type=2` = 视频。⚠️ 待真机验证参数名与幂等性。
 */
export async function favoriteResource(aid: number, mediaId: number, csrf: string): Promise<void> {
  if (aid <= 0) {
    throw new Error('favoriteResource: aid 无效（拒绝发送，避免误操作到错误视频）');
  }
  await biliPost<object>('/x/v3/fav/resource/deal', {
    rid: aid,
    type: 2,
    add_media_ids: mediaId,
    csrf: csrf
  });
}

/**
 * 取消收藏一个视频（从指定收藏夹里删掉）。
 *
 * `POST /x/v3/fav/resource/deal`，表单：`rid={aid}&type=2&del_media_ids={mediaId}&csrf={csrf}`。
 * ⚠️ 待真机验证：未收藏时取消是否 code=0；`-111` = csrf 失效。
 */
export async function unfavoriteResource(aid: number, mediaId: number, csrf: string): Promise<void> {
  if (aid <= 0) {
    throw new Error('unfavoriteResource: aid 无效（拒绝发送，避免误删到错误视频）');
  }
  await biliPost<object>('/x/v3/fav/resource/deal', {
    rid: aid,
    type: 2,
    del_media_ids: mediaId,
    csrf: csrf
  });
}

/**
 * 批量取消收藏（「清空收藏夹」用）。
 *
 * `POST /x/v3/fav/resource/batch-del`，表单：
 * `media_id={mediaId}&resources={aid}:2,{aid2}:2&csrf={csrf}`。
 *
 * ⚠️ B 站**没有**「一键清空收藏夹」接口（`/x/v3/fav/resource/clean` 只清「失效」条目），
 * 所以清空只能逐条来。待真机验证：`resources` 分隔符与单项格式（`{aid}:2`）、单次条数上限。
 */
export async function batchDelFavResources(mediaId: number, aids: number[], csrf: string): Promise<void> {
  const valid: number[] = aids.filter((a: number): boolean => a > 0);
  if (valid.length === 0) {
    throw new Error('batchDelFavResources: aids 全为空（拒绝发送，避免误删到错误视频）');
  }
  const resources: string = valid.map((a: number): string => `${a}:2`).join(',');
  await biliPost<object>('/x/v3/fav/resource/batch-del', {
    media_id: mediaId,
    resources: resources,
    // `platform=web` 对齐 BBPlayer 的可用参数（缺它时部分账号会判 -400，见其 batch-del 实现）
    platform: 'web',
    csrf: csrf
  });
}

/** UP 主资料卡（头像 / 昵称 / 粉丝数 / 签名 / 投稿总数） */
export interface UserCard {
  mid: number;
  name: string;
  face: string;
  fans: number;
  sign: string;
  /** UP 的投稿总数（响应顶层 data.archive_count，2026-10-23 实测确认存在）；0 = 接口未返回 */
  archiveCount: number;
}

/**
 * UP 主资料。
 *
 * ⚠️ **必须用这个接口，不要用 `x/space/wbi/acc/info`**（2026-10-03 匿名态实测）：
 * 后者返回 `code = 0` 看着正常，实际 data 里**只有 `v_voucher` 一个字段**，
 * name / face / fans 全 undefined —— 只看 code 会误判成「可用」。
 * 老接口 `x/web-interface/card` 匿名正常返回 name / fans / face。
 */
export async function getUserCard(mid: number): Promise<UserCard | null> {
  if (mid <= 0) {
    return null;
  }
  const data: { card?: UserCard; archive_count?: number } =
    await biliFetch<{ card?: UserCard; archive_count?: number }>('/x/web-interface/card', {
      mid: mid
    });
  const card: UserCard | undefined = data ? data.card : undefined;
  if (!card) {
    return null;
  }
  return {
    mid: card.mid ?? mid,
    name: card.name ?? '',
    face: card.face ?? '',
    fans: card.fans ?? 0,
    sign: card.sign ?? '',
    archiveCount: data && typeof data.archive_count === 'number' ? data.archive_count : 0
  };
}

export async function extractAudioFromSearch(keyword: string, index: number = 0): Promise<TrackSource> {
  const searchResult: SearchResponse = await searchVideo(keyword, 1, 10);
  if (!searchResult.result || searchResult.result.length === 0) {
    throw new Error(`未找到相关视频: ${keyword}`);
  }
  const video: SearchResultItem = searchResult.result[index];
  return extractAudioFromVideo(video.bvid);
}

// ===== 我的关注（登录用户的关注列表，FollowsPage 用） =====

/** 关注列表条目（/x/relation/followings 的 data.list[] 元素，只取页面要用的字段） */
export interface FollowedUp {
  mid: number;
  uname: string;
  face: string;
  sign: string;
}

/** 关注列表分页数据：total = 关注总数（页面靠它判断还有没有下一页） */
export interface FollowingsData {
  list: FollowedUp[];
  total: number;
}

/**
 * followings 风控兜底判定用：与音源链路（RETRYABLE_BIZ_CODES）同一套风控码口径。
 * 只把「隔一会儿可能恢复」的风控码留给 wbi 重试；-101 未登录这类确定性错误直接抛，
 * 重试只会得到同样的答案、白等一轮。
 */
const FOLLOWINGS_RISK_CODES: number[] = [-352, -412, -509, -799];

/**
 * 登录用户的关注列表（「设置 → 我的关注」页数据源）。
 *
 * 端点 `/x/relation/followings`：查**自己的**关注必须带 SESSDATA（HttpUtil 登录后
 * 自动附加，这里不用额外传）；`order=desc` = 最新关注在前，符合订阅流的直觉。
 *
 * 风控兜底（2026-10）：该接口与空间接口同属风控重灾区，明文参数可能吃到
 * -352/-799。处理方式与 playurl 双通道同思路——先走明文 biliFetch，吃到风控码
 * 再用 encodeWbi 签名重试**一次**；仍是风控码就原样抛，由页面展示 code 让用户
 * 自己判断该等还是该换网。
 */
export async function getFollowings(vmid: number, pn: number = 1): Promise<FollowingsData> {
  const path: string = '/x/relation/followings';
  const params: Record<string, string | number> = {
    vmid: vmid,
    order: 'desc',
    pn: pn,
    ps: 50
  };
  let raw: FollowingsData | undefined;
  try {
    raw = await biliFetch<FollowingsData>(path, params);
  } catch (err) {
    // 只对风控码做 wbi 签名重试；网络层错误 / 确定性业务错误原样抛给调用方
    if (!(err instanceof BiliApiError) || FOLLOWINGS_RISK_CODES.indexOf(err.code) < 0) {
      throw err;
    }
    const query: string = await encodeWbi(params);
    const env: BiliEnvelope<FollowingsData> =
      await HttpUtil.requestJson<BiliEnvelope<FollowingsData>>(`${BILI_API}${path}?${query}`);
    if (env.code !== 0) {
      throw new BiliApiError(env.code, env.message, path);
    }
    raw = env.data;
  }
  // 服务端缺字段防御（学 getUserCard 的归一化写法）：宁可空值也不要 undefined 进 UI
  const src: FollowedUp[] = raw && raw.list ? raw.list : [];
  const list: FollowedUp[] = src.map((u: FollowedUp): FollowedUp => {
    return {
      mid: u.mid ?? 0,
      uname: u.uname ?? '',
      face: u.face ?? '',
      sign: u.sign ?? ''
    };
  });
  return {
    list: list,
    total: raw && raw.total ? raw.total : list.length
  };
}

// ===== 观看历史与稍后再看（「设置 → 登录后能力」数据源，2026-10）=====

/**
 * 历史接口风控兜底码表：与 FOLLOWINGS_RISK_CODES 同一套口径 ——
 * 只把「隔一会儿可能恢复」的风控码留给 wbi 重试；-101 这类确定性错误直接抛。
 */
const HISTORY_RISK_CODES: number[] = [-352, -412, -509, -799];

/** 历史条目内嵌的 history 对象：标识具体视频与看过的分 P */
export interface BiliHistoryEntry {
  /** 视频 aid */
  oid: number;
  bvid: string;
  /** 看到的分 P 序号（从 1 起） */
  page: number;
  cid: number;
  /** 业务类型：archive = 普通视频（本页只保留这类，直播 / 专栏不是音源） */
  business: string;
}

/** 一条观看历史（getWatchHistory 归一化后的严格模型） */
export interface BiliHistoryItem {
  title: string;
  cover: string;
  author_name: string;
  author_face: string;
  author_mid: number;
  /** 观看时间（秒级时间戳，列表按它倒序） */
  view_at: number;
  /** 已看秒数；-1 = 已看完 */
  progress: number;
  /** 总时长（秒） */
  duration: number;
  /** 分 P 名（非分 P 为空串） */
  show_title: string;
  /** 分 P 总数 */
  videos: number;
  is_finish: boolean;
  history: BiliHistoryEntry;
}

/** 历史分页数据：cursorMax = 下一页游标（0 = 没有更多） */
export interface BiliHistoryData {
  list: BiliHistoryItem[];
  cursorMax: number;
}

/** 服务端历史条目的原始结构（字段全部可缺，归一化后绝不进 UI） */
interface HistoryRawEntry {
  oid?: number;
  bvid?: string;
  page?: number;
  cid?: number;
  business?: string;
}

interface HistoryRawItem {
  title?: string;
  cover?: string;
  author_name?: string;
  author_face?: string;
  author_mid?: number;
  view_at?: number;
  progress?: number;
  duration?: number;
  show_title?: string;
  videos?: number;
  is_finish?: boolean;
  history?: HistoryRawEntry;
}

interface HistoryRawCursor {
  max?: number;
}

interface HistoryRawData {
  cursor?: HistoryRawCursor;
  list?: HistoryRawItem[];
}

/**
 * 登录用户的观看历史（游标分页）。
 *
 * 端点 `/x/web-interface/history/cursor`：必须带 SESSDATA（HttpUtil 登录后自动附加）；
 * `business=archive` 只取普通视频；`max` 是上一页返回的 cursor.max（首页传 0），
 * `ps` 固定 20（服务端上限 30，留余量）。风控兜底与 getFollowings 同款：
 * 明文请求吃到风控码再用 encodeWbi 重试一次。
 */
export async function getWatchHistory(max: number, ps: number = 20): Promise<BiliHistoryData> {
  const path: string = '/x/web-interface/history/cursor';
  const params: Record<string, string | number> = {
    max: max,
    business: 'archive',
    ps: ps
  };
  let raw: HistoryRawData | undefined;
  try {
    raw = await biliFetch<HistoryRawData>(path, params);
  } catch (err) {
    // 只对风控码做 wbi 签名重试；网络层错误 / 确定性业务错误原样抛给调用方
    if (!(err instanceof BiliApiError) || HISTORY_RISK_CODES.indexOf(err.code) < 0) {
      throw err;
    }
    const query: string = await encodeWbi(params);
    const env: BiliEnvelope<HistoryRawData> =
      await HttpUtil.requestJson<BiliEnvelope<HistoryRawData>>(`${BILI_API}${path}?${query}`);
    if (env.code !== 0) {
      throw new BiliApiError(env.code, env.message, path);
    }
    raw = env.data;
  }
  const src: HistoryRawItem[] = raw && raw.list ? raw.list : [];
  const list: BiliHistoryItem[] = [];
  for (let i = 0; i < src.length; i++) {
    const it: HistoryRawItem = src[i];
    const h: HistoryRawEntry | undefined = it.history;
    const bvid: string = h && h.bvid ? h.bvid : '';
    // 无 bvid 的条目构不成音源（防御服务端脏数据），直接跳过
    if (bvid.length === 0) {
      continue;
    }
    const item: BiliHistoryItem = {
      title: it.title ?? '',
      cover: it.cover ?? '',
      author_name: it.author_name ?? '',
      author_face: it.author_face ?? '',
      author_mid: it.author_mid ?? 0,
      view_at: it.view_at ?? 0,
      progress: it.progress ?? 0,
      duration: it.duration ?? 0,
      show_title: it.show_title ?? '',
      videos: it.videos ?? 0,
      is_finish: it.is_finish ?? false,
      history: {
        oid: h && h.oid ? h.oid : 0,
        bvid: bvid,
        page: h && h.page ? h.page : 1,
        cid: h && h.cid ? h.cid : 0,
        business: h && h.business ? h.business : 'archive'
      }
    };
    list.push(item);
  }
  const cursorMax: number = raw && raw.cursor && raw.cursor.max ? raw.cursor.max : 0;
  return {
    list: list,
    // 空页强制游标归零：列表没数据时「还有没有下一页」没有讨论意义
    cursorMax: list.length === 0 ? 0 : cursorMax
  };
}

/** 稍后再看条目的 UP 主信息 */
export interface BiliToViewOwner {
  mid: number;
  name: string;
  face: string;
}

/** 一条稍后再看（getToView 归一化后的严格模型） */
export interface BiliToViewItem {
  bvid: string;
  aid: number;
  title: string;
  pic: string;
  owner: BiliToViewOwner;
  /** 总时长（秒） */
  duration: number;
  /** 加入时间（秒级时间戳） */
  add_at: number;
  /** 分 P 数 */
  count: number;
}

interface ToViewRawOwner {
  mid?: number;
  name?: string;
  face?: string;
}

interface ToViewRawItem {
  aid?: number;
  bvid?: string;
  title?: string;
  pic?: string;
  owner?: ToViewRawOwner;
  duration?: number;
  add_at?: number;
  count?: number;
}

interface ToViewRawData {
  list?: ToViewRawItem[];
}

/**
 * 登录用户的「稍后再看」列表（一次性返回，无分页）。
 *
 * 端点 `/x/v2/history/toview/web`：必须带 SESSDATA。条目量级很小（B 站上限
 * 也就几十条），不做 wbi 重试 —— 失败由页面失败态兜底，用户点重试即可。
 */
export async function getToView(): Promise<BiliToViewItem[]> {
  const raw: ToViewRawData = await biliFetch<ToViewRawData>('/x/v2/history/toview/web');
  const src: ToViewRawItem[] = raw && raw.list ? raw.list : [];
  const list: BiliToViewItem[] = [];
  for (let i = 0; i < src.length; i++) {
    const it: ToViewRawItem = src[i];
    const bvid: string = it.bvid ?? '';
    if (bvid.length === 0) {
      continue;
    }
    const o: ToViewRawOwner | undefined = it.owner;
    list.push({
      bvid: bvid,
      aid: it.aid ?? 0,
      title: it.title ?? '',
      pic: it.pic ?? '',
      owner: {
        mid: o && o.mid ? o.mid : 0,
        name: o && o.name ? o.name : '',
        face: o && o.face ? o.face : ''
      },
      duration: it.duration ?? 0,
      add_at: it.add_at ?? 0,
      count: it.count ?? 0
    });
  }
  return list;
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
    const playData: PlayUrlData = await getPlayUrl(bvid, useCid, preferredQuality);
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
  // 统一走 fetchPlayUrlData：参数（fnval=4048 等）与端点策略（无损+登录走 wbi）只有一份
  const playData: PlayUrlData = await fetchPlayUrlData({ avid: aid, cid: cid }, preferredQuality);
  // 与 buildTrackSource 共用同一条选择链：dash 优先 → durl 兜底 → 都没有才抛错
  const best: AudioSelection = resolveAudioSelection(playData, preferredQuality);
  return {
    bvid: bvid,
    aid: Number(aid) || 0,
    cid: Number(cid) || 0,
    title: '',
    artist: '',
    coverUrl: '',
    duration: 0,
    audioUrl: best.url,
    audioBackupUrls: best.backupUrls,
    audioQuality: best.quality,
    audioMimeType: best.mimeType,
    audioBandwidth: best.bandwidth
  };
}

// ════════════════════════════════════════════════════════════════════════
// 扫码登录（passport web 接口，无需 WBI 签名）
//
// 流程（对齐 BBPlayer / B 站 App 客户端行为）：
//   1. generateQrLogin()  拿二维码内容 url + qrcode_key（二维码有效期约 180s）；
//   2. pollQrLogin()      每 2s 轮询扫码状态。
//
// 登录 Cookie 的下发取决于 UA（2026-10-07 日志确证，B 站按 UA 分流）：
//   · web UA（PC Chrome）：成功时 data.url 是 crossDomain?ticket=... 跳转地址，
//     登录 Cookie 在 302 重定向中间跳的 Set-Cookie 里（ohos 自动跟随重定向会吞掉）；
//   · BiliApp UA（本实现，BBPlayer 同款 PASSPORT_UA）：登录 Cookie 直接在
//     poll 响应的 Set-Cookie 里下发，无需跟进任何跳转。
// 因此 generate / poll 全链路统一 BILI_APP_UA 且**均为裸请求**（skipCookie +
// skipReferer）。crossDomain 跟进保留为条件兜底：仅当 poll 响应 Cookie 里没有
// SESSDATA 时才走。
//
// ⚠️ 2026-10-22 复盘：「平板二维码 3 秒即 86038」的真根因**不是**服务端风控提前
// 作废（此前的 buvid/指纹假设），而是 poll 的 GET + queryParams 在本机引擎上
// 发空参请求——服务端查无 key 一律答 86038（详见 pollQrLogin 注释的对照实验）。
// generate 裸化与 buvid 升级链路保留：它们对「新装机假 buvid 引发 -352 风控」
// 的防御仍然成立。
//
// 成功帧登录 Cookie 的两种形态都要接（LoginStore.applyQrSuccess 双通道）：
//   a) data.url 的 query 参数直接带 Cookie（老格式，值需 URL 解码）；
//   b) 响应 Set-Cookie（k=v; k=v 串）—— 现行主通道。
// 状态码语义（poll 返回的 data.code）：
//   86101 未扫码 / 86090 已扫码待确认 / 86038 二维码已过期 / 0 登录成功
// ════════════════════════════════════════════════════════════════════════

/** 二维码凭据：qrUrl 是二维码内容（App 内用 QRCode 组件渲染），qrcodeKey 供轮询 */
export interface QrLoginTicket {
  qrUrl: string;
  qrcodeKey: string;
}

/** 轮询结果：status 即 B 站的 data.code（86101/86090/86038/0） */
export interface QrPollResult {
  status: number;
  /** 仅成功时有值：回调 url（老格式下 query 里带 Cookie 参数），由 LoginStore 解析 */
  callbackUrl: string;
  /**
   * 仅成功时有意义：poll 响应（必要时含 crossDomain 跳转）的 Set-Cookie value 串
   * （k=v; k=v，crossDomain 在前、同名键以先出现者为准）。
   * BiliApp UA 下登录 Cookie 直接在 poll 响应 Set-Cookie 里，这是主通道。
   */
  responseCookies: string;
  refreshToken: string;
}

interface QrGenerateEnvelope {
  code: number;
  message: string;
  data: QrGenerateData;
}

interface QrGenerateData {
  url: string;
  qrcode_key: string;
}

interface QrPollEnvelope {
  code: number;
  message: string;
  data: QrPollData;
}

interface QrPollData {
  url: string;
  refresh_token: string;
  code: number;
  message: string;
}

/**
 * 生成扫码登录二维码（BiliApp UA，对齐 BBPlayer：其 client 默认头即 BiliApp UA）。
 *
 * 2026-10-22 平板登录修复：改为**裸请求**（skipCookie + skipReferer，与 pollQrLogin
 * 完全对齐）。旧实现经 HttpUtil.buildHeader 默认附带 buvid / 旧登录态 Cookie 与
 * Referer —— generate 带 Cookie、poll 裸请求，同一 key 的两次请求客户端指纹不一致；
 * 且新装机（典型：平板）的 buvid 是本地 MD5 兜底假值（BiliDevice.getBuvid），
 * 带着假指纹请求 generate 易触发 passport 风控**提前作废二维码**（真机表现：
 * 生成后约 3s 即 86038、aliveMs<30s 且从未出现 86090，「二维码 3 秒就刷新、
 * 来不及扫码」）。裸化后登录链路全程仅 BiliApp UA，与 BBPlayer 的
 * credentials:'omit' 口径一致；失败路径由 LoginPage.startQrLogin 的
 * expired 蒙层重试兜底，行为安全。
 */
export async function generateQrLogin(): Promise<QrLoginTicket> {
  const path: string = '/x/passport-login/web/qrcode/generate';
  const resp: QrGenerateEnvelope =
    await HttpUtil.requestJson<QrGenerateEnvelope>(`${BILI_PASSPORT}${path}`, {
      headers: { 'User-Agent': BILI_APP_UA },
      skipCookie: true,
      skipReferer: true
    });
  if (resp.code !== 0) {
    throw new BiliApiError(resp.code, resp.message, path);
  }
  return { qrUrl: resp.data.url, qrcodeKey: resp.data.qrcode_key };
}

/**
 * 轮询扫码状态（调用方每 2s 一次，过期后停止轮询等待用户刷新）。
 *
 * 裸请求（对齐 BBPlayer）：仅 BiliApp UA，不带 Cookie（skipCookie，等价
 * credentials:'omit'）与 Referer —— BiliApp UA 下登录 Cookie 直接在本响应的
 * Set-Cookie 里下发。走 requestTextWithCookies：普通 requestJson 会丢掉 Set-Cookie。
 * crossDomain 跟进仅为兜底：poll 响应 Cookie 缺 SESSDATA 时才 GET data.url。
 * **成功帧（data.code===0）绝不向上抛**：登录 Cookie 一次性下发，后处理任何异常只降级。
 *
 * ⚠️ qrcode_key 必须内联进 URL，**绝不能走 queryParams**（2026-10-22 根因定位）：
 * 本机引擎 GET + queryParams 发出的是空参请求（同 biliFetch 头注释里 view 接口
 * -400 事故，工程内能用的 GET 全是 query 内联）——服务端查无此 key，一律回
 * 86038「二维码已失效」。真机日志表现：每张码的**第一次** poll（+2s）即 86038
 * （aliveMs≈2.1s），曾被误判为「风控提前作废二维码」；开发机 curl 对照实验确证
 * 「无 key」与「错 key」的 poll 返回与 App 收到的逐字节同形，而同 key 内联 URL
 * 可正常存活 180s。此前的指纹/风控假设不成立，真根因即参数丢失。
 */
export async function pollQrLogin(qrcodeKey: string): Promise<QrPollResult> {
  const path: string = '/x/passport-login/web/qrcode/poll';
  const url: string = `${BILI_PASSPORT}${path}?qrcode_key=${encodeURIComponent(qrcodeKey)}`;
  const raw: HttpTextResult = await HttpUtil.requestTextWithCookies(url, {
    headers: { 'User-Agent': BILI_APP_UA },
    skipCookie: true,
    skipReferer: true
  });
  const resp: QrPollEnvelope = JSON.parse(raw.text) as QrPollEnvelope;
  if (resp.code !== 0) {
    throw new BiliApiError(resp.code, resp.message, path);
  }
  let responseCookies: string = raw.responseCookies;
  if (resp.data.code === 0) {
    // 成功帧是「一次性」的：B 站只在成功那一帧下发登录 Cookie，处理中任何异常都会让它
    // 永久丢失（2026-10-07 实测教训：ArkTS 运行时缺 Array.includes，守卫代码在成功帧抛
    // "undefined is not callable"，下一帧即 86038、Cookie 无法找回）。因此成功分支整体
    // try/catch 降级，**绝不向上抛**；诊断日志走 console（JSAPP 缓冲区实测比 hilog 可靠）。
    try {
      console.info(`poll success frame: cookiesLen=${raw.responseCookies.length}` +
        `, cookieKeys=[${HttpUtil.cookieKeys(raw.responseCookies).join(', ')}]` +
        `, urlLen=${resp.data.url.length}` +
        `, hasSessdata=${HttpUtil.cookieHasKey(raw.responseCookies, 'SESSDATA')}`);
      if (resp.data.url.length > 0 && !HttpUtil.cookieHasKey(raw.responseCookies, 'SESSDATA')) {
        // 兜底：登录 Cookie 未随成功帧直接下发、data.url 是 crossDomain?ticket=... 跳转
        // （web UA 形态）。BiliApp UA 下不该走到这里；走到了说明提取仍有问题，
        // 保留跟进可多一次机会，上面的成功帧诊断日志负责暴露根因。
        try {
          const cross: HttpTextResult = await HttpUtil.requestTextWithCookies(resp.data.url, {
            headers: { 'User-Agent': BILI_APP_UA },
            skipCookie: true,
            skipReferer: true
          });
          console.info(`crossDomain fallback cookies: [${HttpUtil.cookieKeys(cross.responseCookies).join(', ')}]`);
          if (cross.responseCookies.length > 0) {
            // crossDomain 在前：与 poll 响应重名时，解析以先出现者为准
            responseCookies = raw.responseCookies.length > 0
              ? `${cross.responseCookies}; ${raw.responseCookies}`
              : cross.responseCookies;
          }
        } catch (e) {
          // 跟进失败（网络瞬态等）：保留 poll 响应 cookie 继续走，由上层诊断日志给出细节
          console.warn(`crossDomain fallback failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
        }
      }
    } catch (e) {
      // 成功帧后处理失败：带着已拿到的数据返回，由 finishLogin 的双通道解析与日志兜底
      console.warn(`poll success post-process failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    }
  }
  return {
    status: resp.data.code,
    callbackUrl: resp.data.url,
    responseCookies: responseCookies,
    refreshToken: resp.data.refresh_token
  };
}

// ════════════════════════════════════════════════════════════════════════
// 短信验证码登录（2026-10 新增，对齐 BBPlayer api.ts L1426 / L1477 / L1569）
//
// 三步链路（每步都是独立接口，第二步前必须先过极验滑块）：
//   1. fetchSmsCaptchaToken()  拿图形验证 token + 极验 gt/challenge；
//   2. 用户在 WebView 里完成极验滑块 → sendSmsLoginCode() 发送短信，
//      返回 captcha_key（86211 / -105 = 图形验证已过期，需回到第 1 步重来）；
//   3. loginWithSmsCode()      用短信验证码换登录 Cookie（响应 Set-Cookie）。
// 三接口全部 BiliApp UA + 裸 Cookie（skipCookie，对齐 BBPlayer 的
// credentials:'omit'）；2/3 为 POST 且**参数内联 query**（2026-10-22 修复：
// 本引擎 queryParams 发空参 → 平板短信登录滑块通过后必 -400 退回手机号输入；
// 表单体也会被吞，query 内联是唯一可靠通道），Referer / Origin 同 BBPlayer。
// ════════════════════════════════════════════════════════════════════════

/** 第 1 步产物：图形验证 token + 极验参数（WebView 里 initGeetest 用） */
export interface SmsCaptchaInfo {
  token: string;
  gt: string;
  challenge: string;
}

/** 第 2 步产物：captcha_key，第 3 步登录必带（一次性凭据） */
export interface SmsSendResult {
  captchaKey: string;
}

/** 第 3 步产物：登录 Cookie（Set-Cookie 串）+ refresh_token */
export interface SmsLoginResult {
  responseCookies: string;
  refreshToken: string;
}

interface SmsCaptchaEnvelope {
  code: number;
  message: string;
  data: SmsCaptchaData;
}

interface SmsCaptchaData {
  token: string;
  geetest: GeetestConfig;
}

interface GeetestConfig {
  gt: string;
  challenge: string;
}

interface SmsSendEnvelope {
  code: number;
  message: string;
  data: SmsSendData;
}

interface SmsSendData {
  captcha_key: string;
}

interface SmsLoginEnvelope {
  code: number;
  message: string;
  data: SmsLoginData;
}

interface SmsLoginData {
  refresh_token: string;
}

/** 获取手机登录图形验证信息（GET /x/passport-login/captcha，source=main_web） */
export async function fetchSmsCaptchaToken(): Promise<SmsCaptchaInfo> {
  const path: string = '/x/passport-login/captcha';
  const resp: SmsCaptchaEnvelope = await HttpUtil.requestJson<SmsCaptchaEnvelope>(
    `${BILI_PASSPORT}${path}?source=main_web&t=${Date.now()}`, {
      headers: { 'User-Agent': BILI_APP_UA },
      skipCookie: true
    });
  if (resp.code !== 0) {
    throw new BiliApiError(resp.code, resp.message, path);
  }
  return { token: resp.data.token, gt: resp.data.geetest.gt, challenge: resp.data.geetest.challenge };
}

/**
 * 发送短信验证码（POST /x/passport-login/web/sms/send，参数内联 query）。
 * challenge 用**极验回传值**（而非第 1 步下发的原值——滑块通过后服务端会换发）。
 * @throws BiliApiError：code 86211 / -105 = 图形验证已过期
 */
export async function sendSmsLoginCode(tel: string, cid: string, token: string,
  challenge: string, validate: string, seccode: string): Promise<SmsSendResult> {
  const path: string = '/x/passport-login/web/sms/send';
  if (tel.length === 0 || cid.length === 0) {
    // 服务端对空 tel / 空 cid 只回一句「-400 请求错误」，看不出是哪个字段，
    // 这里先本地拦下给一句能看懂的（2026-10-20 实测：-400 等价于「表单为空/缺字段」）
    throw new BiliApiError(-400, '手机号缺失，请返回上一步重新输入', path);
  }
  // ⚠️ 2026-10-22 根因修复：参数必须**内联进 URL**，绝不能走 `params`（ohos 的
  // queryParams）。本引擎 queryParams 会静默发出空参请求（2026-10-20 view 接口
  // -400、2026-10-22 QR poll 86038 两次实锤），短信登录在平板上同款翻车：
  // 滑块通过后 send 发空参 → 服务端 -400 → 页面退回手机号输入、短信没发出去。
  // POST + query B 站接受（2026-10-20 实测：同字段走 query → code=0 + captcha_key）。
  const url: string = `${BILI_PASSPORT}${path}` +
    `?cid=${encodeURIComponent(cid)}&tel=${encodeURIComponent(tel)}` +
    `&source=main_mini_login&token=${encodeURIComponent(token)}` +
    `&challenge=${encodeURIComponent(challenge)}&validate=${encodeURIComponent(validate)}` +
    `&seccode=${encodeURIComponent(seccode)}`;
  const resp: SmsSendEnvelope = await HttpUtil.requestJson<SmsSendEnvelope>(url, {
    method: http.RequestMethod.POST,
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': BILI_APP_UA,
      Origin: 'https://www.bilibili.com'
    },
    skipCookie: true
  });
  console.info(`sms send: code=${resp.code}, telLen=${tel.length}, ` +
    `tokenLen=${token.length}, vLen=${validate.length}`);
  if (resp.code !== 0) {
    throw new BiliApiError(resp.code, resp.message, path);
  }
  return { captchaKey: resp.data.captcha_key };
}

/**
 * 短信验证码登录（POST /x/passport-login/web/login/sms，参数内联 query）。
 * 走 requestTextWithCookies：登录 Cookie 在本响应的 Set-Cookie 里下发
 * （与扫码 poll 同形态，由 LoginStore.applySmsLoginCookies 解析）。
 */
export async function loginWithSmsCode(tel: string, cid: string, code: string,
  captchaKey: string): Promise<SmsLoginResult> {
  const path: string = '/x/passport-login/web/login/sms';
  // 同 sendSmsLoginCode（2026-10-22 根因修复）：参数内联进 URL。
  // 本引擎 queryParams 发空参（QR poll 86038 同款缺陷）、字符串表单体也会被吞
  // （2026-10-20 实测 -400），query 内联是唯一在所有引擎上都可靠的通道。
  const url: string = `${BILI_PASSPORT}${path}` +
    `?cid=${encodeURIComponent(cid)}&tel=${encodeURIComponent(tel)}` +
    `&code=${encodeURIComponent(code)}&source=main_mini_login` +
    `&captcha_key=${encodeURIComponent(captchaKey)}&keep=1`;
  const headers: Record<string, string> = {
    'Content-Type': 'application/x-www-form-urlencoded',
    'User-Agent': BILI_APP_UA,
    Origin: 'https://www.bilibili.com'
  };
  let raw: HttpTextResult = await HttpUtil.requestTextWithCookies(url, {
    method: http.RequestMethod.POST,
    headers: headers,
    skipCookie: true
  });
  let resp: SmsLoginEnvelope = JSON.parse(raw.text) as SmsLoginEnvelope;
  if (resp.code === -400) {
    // 兜底：个别引擎只认表单体（与主路径二选一，正常只走一条）
    raw = await HttpUtil.requestTextWithCookies(`${BILI_PASSPORT}${path}`, {
      method: http.RequestMethod.POST,
      headers: headers,
      skipCookie: true,
      body: `cid=${encodeURIComponent(cid)}&tel=${encodeURIComponent(tel)}` +
        `&code=${encodeURIComponent(code)}&source=main_mini_login` +
        `&captcha_key=${encodeURIComponent(captchaKey)}&keep=1`
    });
    resp = JSON.parse(raw.text) as SmsLoginEnvelope;
    console.warn(`sms login: body fallback -> code=${resp.code}`);
  }
  console.info(`sms login: code=${resp.code}, cookiesLen=${raw.responseCookies.length}`);
  if (resp.code !== 0) {
    throw new BiliApiError(resp.code, resp.message, path);
  }
  return { responseCookies: raw.responseCookies, refreshToken: resp.data.refresh_token };
}

/** 登录用户信息（nav 接口归一化后的形态） */
export interface NavUserInfo {
  isLogin: boolean;
  mid: number;
  uname: string;
  face: string;
  vipStatus: number;
  /** 会籍种类：0 无 / 1 月度大会员 / 2 年度大会员（nav 的 vipType，2026-10-11 新增） */
  vipType: number;
}

interface NavEnvelope {
  code: number;
  message: string;
  data: NavDataRaw;
}

interface NavDataRaw {
  isLogin?: boolean;
  mid?: number;
  uname?: string;
  face?: string;
  vipStatus?: number;
  vipType?: number;
}

const NOT_LOGGED_IN_USER: NavUserInfo = {
  isLogin: false,
  mid: 0,
  uname: '',
  face: '',
  vipStatus: 0,
  vipType: 0
};

/**
 * 拉取当前登录用户信息（/x/web-interface/nav）。
 *
 * ⚠️ 未登录 / Cookie 失效时该接口返回 code -101 —— 这不是异常，是「未登录」的正常答案，
 * 返回 isLogin=false 的占位对象；其余非 0 业务码才抛 BiliApiError。
 * WbiSign 对同一接口的 -101 已有同样的容忍先例（wbi_img 照常可用）。
 */
export async function fetchNavUser(): Promise<NavUserInfo> {
  const path: string = '/x/web-interface/nav';
  const resp: NavEnvelope = await HttpUtil.requestJson<NavEnvelope>(`${BILI_API}${path}`);
  if (resp.code === -101) {
    return NOT_LOGGED_IN_USER;
  }
  if (resp.code !== 0) {
    throw new BiliApiError(resp.code, resp.message, path);
  }
  const d: NavDataRaw = resp.data;
  return {
    isLogin: d.isLogin === true,
    mid: d.mid ?? 0,
    uname: d.uname ?? '',
    face: d.face ?? '',
    vipStatus: d.vipStatus ?? 0,
    vipType: d.vipType ?? 0
  };
}

/**
 * 撤销服务器端登录会话（POST /login/exit/v2，表单带 bili_jct 作 CSRF）。
 * best-effort：调用方（LoginStore.logout）失败也继续本地清理，不会因此卡住退出。
 */
export async function revokeLogin(biliJct: string): Promise<void> {
  await HttpUtil.requestText(`${BILI_PASSPORT}/login/exit/v2`, {
    method: http.RequestMethod.POST,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `bili_jct=${encodeURIComponent(biliJct)}&csrf=${encodeURIComponent(biliJct)}`
  });
}

