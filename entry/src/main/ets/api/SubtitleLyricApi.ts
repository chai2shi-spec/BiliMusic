/**
 * B 站字幕歌词源（末位兜底）。
 *
 * 外部歌词源（网易云 / QQ / OIAPI）靠「标题 + 歌手」搜歌，VOCALOID 原创、
 * 二次创作、电台片段这类曲库外的歌永远搜不到 —— 但它们的视频本身往往有
 * CC 字幕（UP 主 / 官方上传）或 AI 字幕（B 站语音识别生成），行级时间戳
 * 与音轨天然对齐，可直接当逐行 LRC 用。
 *
 * 链路（任一步失败 / 超时一律不抛错 —— 歌词是锦上添花）：
 * 结果分级见 `SubtitleOutcome`：结论性失败（definitive=true）才配让调用方
 * 写 24h miss；瞬时失败（超时 / 网络 / 风控）由调用方内存节流后重试。
 *   1. 定位视频：track.bvid + track.cid；cid 缺失时 getVideoDetail(bvid)
 *      补（viewCache 命中近乎零开销）；bvid 缺失时用 aid + cid。
 *   2. 取字幕列表：`/x/player/wbi/v2`（WBI 签名，HttpUtil 自动附
 *      Referer / buvid / SESSDATA）。⚠️ 字幕列表对登录态有强依赖，
 *      匿名请求 `subtitles` 多为空数组 —— 未登录时本源自然失效，
 *      属预期退化（同「未找到歌词」），不发额外请求补救。
 *   3. 选优：人工 CC 的准确率高于 AI 识别；语言中文优先（中文歌、
 *      以及中文字幕对华语用户的价值都最高）。顺序：CC 中文 → CC 其它 →
 *      AI 中文 → AI 其它。
 *   4. 取字幕文件：subtitle_url 是协议相对地址（`//…hdslb.com/…`），
 *      补 `https:` 前缀后拉 JSON（`body: [{ from, to, content }]`，
 *      from/to 单位秒）。跳过空白行；有效行 < 3 视为脏数据丢弃，
 *      避免 AI 字幕偶发的空壳响应进 UI。
 *
 * 结果即时转换成 LyricResult（不缓存裸 URL —— 字幕 CDN 链接短期有效，
 * 落缓存的是转换后的行数据），由 LyricsApi 写入 LyricCacheStore。
 */

import { BILI_API } from '../common/Constants';
import { LyricLine, LyricResult, Track } from '../model/MusicModels';
import { encodeWbi } from './WbiSign';
import { getVideoDetail, RETRYABLE_BIZ_CODES } from './BilibiliApi';
import { HttpUtil } from '../utils/HttpUtil';
import { BiliRequestGate } from '../utils/BiliRequestGate';
import { isLoggedIn } from '../service/LoginStore';
import { gaiaWebParams } from '../utils/RiskShield';

/** CC 字幕源标识（ai_type !== 1，人工上传） */
export const SOURCE_BILI_CC: string = 'bilibili-cc';
/** AI 字幕源标识（ai_type === 1，B 站语音识别生成） */
export const SOURCE_BILI_AI: string = 'bilibili-ai';

/** 字幕取数类型：自动选优（CC 中文 → CC 其它 → AI 中文 → AI 其它） */
export const SUBTITLE_KIND_AUTO: string = 'auto';
/** 字幕取数类型：只要人工 CC 字幕 */
export const SUBTITLE_KIND_CC: string = 'cc';
/** 字幕取数类型：只要 AI 字幕 */
export const SUBTITLE_KIND_AI: string = 'ai';

/** 整条字幕链路的超时（ms）：全链最多两个请求，卡住时不能拖住播放页歌词区 */
const SUBTITLE_TIMEOUT_MS: number = 6000;
/** 手动点选链的超时壳：用户主动等待且有加载反馈，预算放宽到 9s（自动链仍 6s） */
const SUBTITLE_CHOICE_TIMEOUT_MS: number = 9000;
/** 少于该行数的字幕视为脏数据（AI 字幕偶发空壳 / 纯音乐视频的零星杂行） */
const MIN_SUBTITLE_LINES: number = 3;
/**
 * wbi/v2 通道熔断时长（ms）：一次 412 后短时间内直接走 v2 旧通道。
 * 不熔断的代价（实测）：连续点按每次都撞 412 → 上报 BiliRequestGate
 * → 冷却升级把 v2 回退与字幕 CDN 也排队拖过 6s 超时壳 → 「网络繁忙」。
 */
const WBI_CHANNEL_BLOCK_MS: number = 10 * 60 * 1000;

/** wbi/v2 熔断到期时刻（0 = 未熔断）；模块级、不落盘，进程重启自然清零 */
let wbiChannelBlockedUntil: number = 0;

/**
 * 空列表抖动重试的延迟（ms）：实测同参数同通道下 `subtitles` 会空/非空抖动，
 * 稍候换一次 gaia 指纹再拉可消化绝大多数抖动（见 fetchSubtitleMetas）。
 */
const SUBTITLE_EMPTY_RETRY_MS: number = 300;

/**
 * AI 智能字幕惰性生成完整度判定：B 站按需生成 AI 字幕，生成中只返回开头
 * 几句（实测同视频 6 行 ↔ 12 行 ↔ 268 行交替；完成态列表会多出 AI 翻译
 * 语言且 subtitle_url 更新）。末行时间不足视频时长的该比例 → 视为生成中，
 * 触发完整度重试（见 fetchLinesWithCompletenessRetry）。
 */
const SUBTITLE_PARTIAL_RATIO: number = 0.5;
/**
 * 完整度重试基础延迟（ms）：第 n 次重试延迟 = 基础值 × n（400/800/1200 递增）——
 * 首次重试快（生成常在首次请求后几秒内收敛），后续递增覆盖更慢的收敛，
 * 比固定间隔在同等总等待下多覆盖一个数量级的时间窗。
 */
const SUBTITLE_PARTIAL_RETRY_BASE_MS: number = 400;
/** 自动链完整度重试最大尝试次数（含首次取数）：最坏 ~4s，留在 6s 超时壳内 */
const SUBTITLE_PARTIAL_MAX_ATTEMPTS: number = 3;
/** 手动点选链重试上限多一次：等待有明确反馈（获取中 + 加载态），最坏 ~6.5s < 9s 壳 */
const SUBTITLE_PARTIAL_MAX_ATTEMPTS_CHOICE: number = 4;

/**
 * 串台字幕文件判定（F 串台防护·文件层）：实测 B 站会把**其它视频**的 AI 字幕
 * 文件挂进本视频的列表（2026-10-28 抓包实锤：prod/1131917661… 同一文件先后
 * 服务给 214 秒与 771 秒两个视频；214 秒视频连续 6 次点击拿到 177/214/720/
 * 869/159 行的 5 个不同文件）。列表身份校验（requestSubtitleMetas）挡不住
 * 这一层——文件时间轴远超视频时长 / 行数密度物理不可能才是串台特征。
 * 末行时间超过 时长×该比例 + 固定余量 → 串台（别的更长视频的字幕）。
 */
const SUBTITLE_SPAN_OVERFLOW_RATIO: number = 1.2;
/** 串台跨度判定的固定余量（秒）：AI 字幕末行偶发略超视频结尾，留足防误杀 */
const SUBTITLE_SPAN_OVERFLOW_SLACK_S: number = 10;
/** 串台密度判定：行数 > max(40, 时长秒×该值) → 串台（214 秒 869 行 = 4 行/秒，真实字幕实测 0.28~1.0 行/秒） */
const SUBTITLE_DENSITY_MAX_PER_SEC: number = 2.5;

/** setTimeout 的 Promise 壳（空列表抖动重试用） */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

/** `/x/player/wbi/v2` 响应壳（只声明本源用到的字段，脏数据防御靠逐层可选） */
interface SubtitlePlayerEnvelope {
  code?: number;
  message?: string;
  data?: SubtitlePlayerData;
}

interface SubtitlePlayerData {
  subtitle?: SubtitleList;
  /** 响应回显的视频身份（身份校验用；缺失 = 无法校验，放行） */
  bvid?: string;
  aid?: number;
  cid?: number;
}

interface SubtitleList {
  subtitles?: SubtitleMeta[];
}

interface SubtitleMeta {
  /** 语言代码：zh-CN / zh-Hans / ai-zh / en … */
  lan?: string;
  /** 字幕文件 JSON 地址，协议相对（`//…`）或 http(s) */
  subtitle_url?: string;
  /** 1 = AI 字幕；0 / 缺省 = CC 字幕 */
  ai_type?: number;
}

/** 字幕文件 JSON：`{ body: [{ from, to, content }, …] }`（from/to 单位秒） */
interface SubtitleFileBody {
  body?: SubtitleBodyLine[];
}

interface SubtitleBodyLine {
  from?: number;
  to?: number;
  content?: string;
}

/** 解析出的视频定位（wbi/v2 的请求参数） */
interface SubtitleTarget {
  bvid: string;
  aid: string;
  cid: string;
}

/**
 * 字幕链路结果分级（F2）：「这次没试成」与「确实没有」必须分开 ——
 * 前者不配写 24h miss，后者才配。
 */
export interface SubtitleOutcome {
  /** 命中时的结果；null = 未取到 */
  result: LyricResult | null;
  /** true = 结论性失败（值得写 miss）；false = 瞬时失败（不该写 miss） */
  definitive: boolean;
  /** 机器可读原因：denied / empty / no-candidate / dirty / timeout / network / risk / no-target；命中为空串 */
  reason: string;
  /** true = 命中但内容疑似生成中的半截（末行时间不足时长一半）—— UI 可先展示并安排后台补全 */
  partial?: boolean;
}

/** resolveSubtitleTarget 的输出：失败时带机器可读原因，供 outcome 分级 */
interface SubtitleTargetResolve {
  target: SubtitleTarget | null;
  reason: string;
}

/** fetchBestSubtitleMeta 的输出：失败时带机器可读原因，供 outcome 分级 */
interface SubtitleMetaOutcome {
  meta: SubtitleMeta | null;
  reason: string;
  definitive: boolean;
}

/** 列表级失败分级（fetchSubtitleMetas 的输出）：metas null = 没拿到列表 */
interface SubtitleMetasOutcome {
  metas: SubtitleMeta[] | null;
  reason: string;
  definitive: boolean;
}

/**
 * 字幕语言是否中文（zh-CN / zh-Hans / ai-zh …统一按包含 zh 判定）。
 * ⚠️ 不能只看前缀：AI 中文字幕的语言码是 `ai-zh`（不以 zh 开头），
 * 前缀判定会把 AI 中文误归「其它语言」，排到 CC 任意语言之后。
 */
function isZhLan(lan: string): boolean {
  return lan.indexOf('zh') >= 0;
}

/**
 * AI 字幕判定（CC/AI 按钮各司其职的关键）。
 * ⚠️ ai_type 不可靠：B 站 AI 智能字幕常以 `lan=ai-zh, ai_type=0` 返回
 * （实测两个端点都如此），只认 ai_type===1 会把 AI 字幕当 CC 抓走 ——
 * 智能字幕内容不稳定（同 URL 每次拉取行数乱跳），这正是
 * 「多次点击才切换到正确字幕」的根因之一。lan 恒为 ai- 前缀，两者任一命中即 AI。
 */
function isAiSubtitle(meta: SubtitleMeta): boolean {
  return meta.ai_type === 1 || (meta.lan ?? '').startsWith('ai-');
}

/**
 * 定位视频：bvid + cid 优先；bvid 缺失时退 aid + cid；cid 缺失时
 * getVideoDetail(bvid) 补（viewCache 命中近乎零开销）。全空 → target null。
 * 失败原因：补 cid 失败（网络/接口异常，瞬时）与 bvid/aid 全空（无法定位视频，结论性）。
 */
async function resolveSubtitleTarget(track: Track): Promise<SubtitleTargetResolve> {
  let bvid: string = track.bvid;
  let aid: string = track.aid;
  // cid 优先级：id 的 `BV…#cid` 后缀 > track.cid > getVideoDetail(bvid)。
  // 分 P 曲目的 id 后缀是队列 / 下载链路共用的权威身份（见 BilibiliApi
  // expandVideoParts 的 `${bvid}#${p.cid}` 构造与 DownloadManager 的解析）；
  // 部分快照 / 精简路径 track.cid 会缺失，此时若直接回退 getVideoDetail(bvid)
  // 会拿到 **P1 的 cid** —— 多歌合集里 P1 是另一首歌，字幕随之串台。
  let cid: string = track.cid;
  const hashIdx: number = track.id.indexOf('#');
  if (hashIdx >= 0) {
    const tail: string = track.id.substring(hashIdx + 1);
    if (tail.length > 0 && /^\d+$/.test(tail)) {
      cid = tail;
    }
  }
  if (cid.length === 0 && bvid.length > 0) {
    try {
      const detail = await getVideoDetail(bvid);
      cid = String(detail.cid);
      if (aid.length === 0) {
        aid = String(detail.aid);
      }
    } catch (e) {
      console.info(`[Lyric] subtitle detail fetch failed track=${track.title}`
        + ` err=${e instanceof Error ? e.message : JSON.stringify(e)}`);
      return { target: null, reason: 'network' };
    }
  }
  if (cid.length === 0 || (bvid.length === 0 && aid.length === 0)) {
    console.info(`[Lyric] subtitle no bvid/aid track=${track.title}`);
    return { target: null, reason: 'no-target' };
  }
  return { target: { bvid: bvid, aid: aid, cid: cid }, reason: '' };
}

/**
 * 选最优字幕：CC（人工）优先于 AI（机器识别），中文优先于其它语言。
 * kind 过滤：`cc` 只从人工字幕选（CC中文 → CC其它）、`ai` 只从 AI 字幕选
 * （AI中文 → AI其它）、`auto` 四级全序。空列表 / 过滤后无候选 → null。
 */
function pickBestSubtitle(metas: SubtitleMeta[], kind: string): SubtitleMeta | null {
  let ccZh: SubtitleMeta | null = null;
  let ccAny: SubtitleMeta | null = null;
  let aiZh: SubtitleMeta | null = null;
  let aiAny: SubtitleMeta | null = null;
  for (let i = 0; i < metas.length; i++) {
    const meta: SubtitleMeta = metas[i];
    if (meta.subtitle_url === undefined || meta.subtitle_url.length === 0) {
      continue;
    }
    const isAi: boolean = isAiSubtitle(meta);
    const isZh: boolean = isZhLan(meta.lan ?? '');
    if (!isAi) {
      if (kind === SUBTITLE_KIND_AI) {
        continue;
      }
      if (isZh && ccZh === null) {
        ccZh = meta;
      } else if (!isZh && ccAny === null) {
        ccAny = meta;
      }
    } else {
      if (kind === SUBTITLE_KIND_CC) {
        continue;
      }
      if (isZh && aiZh === null) {
        aiZh = meta;
      } else if (!isZh && aiAny === null) {
        aiAny = meta;
      }
    }
  }
  if (ccZh !== null) {
    return ccZh;
  }
  if (ccAny !== null) {
    return ccAny;
  }
  if (aiZh !== null) {
    return aiZh;
  }
  return aiAny;
}

/** 协议相对地址补协议头：`//a.b/c` → `https://a.b/c`；其余原样返回 */
function normalizeSubtitleUrl(url: string): string {
  if (url.startsWith('//')) {
    return `https:${url}`;
  }
  return url;
}

/**
 * kind 口径下是否存在条目（不看 subtitle_url）：AI 惰性生成初期列表会先
 * 出现无 URL 的 ai-zh 条目 —— 这种「有字幕但还没生成好」是瞬时态，
 * 与「该 kind 下真没有字幕」（结论性）必须区分，否则会被写成 24h miss。
 */
function hasKindCandidate(metas: SubtitleMeta[], kind: string): boolean {
  for (let i = 0; i < metas.length; i++) {
    const isAi: boolean = isAiSubtitle(metas[i]);
    if (kind === SUBTITLE_KIND_CC && isAi) {
      continue;
    }
    if (kind === SUBTITLE_KIND_AI && !isAi) {
      continue;
    }
    return true;
  }
  return false;
}

/**
 * 取字幕列表并按 kind 选优。
 * `x/player/wbi/v2` 与 playurl 同域同签名体系；响应里 `subtitles`
 * 为空数组即「无可用字幕」（未登录 / 无字幕视频都长这样）。
 * 失败可见化（F1）：code≠0 与空列表分别打日志 —— 登录失效（-101）与
 * 「真没字幕」在日志里必须可区分，不再一起静默落 null。
 * 失败分级（F2）：风控码（沿用 BilibiliApi 的 RETRYABLE_BIZ_CODES 口径）
 * 属瞬时失败不写 miss；其余 code≠0 / 空列表 / 选优无候选属结论性失败。
 *
 * ⚠️ 风控与换道（实测教训）：
 *   · 本接口即使带 gaia/dm_img 浏览器同款指纹，也可能被 HTTP 412 定点
 *     拦截（同刻 playurl 同指纹恒 200）—— gaia 风控按端点独立评分；
 *   · 重试策略沿用 playurl 的「换通道」而非「同一通道再打一次」：
 *     wbi/v2 失败 → `x/player/v2` 旧端点（web 播放器前身接口，无需 WBI
 *     签名，风控策略独立），整链仍被 6s 超时壳罩住；
 *   · 通道熔断：wbi/v2 一旦失败即熔断 WBI_CHANNEL_BLOCK_MS，期间直接走
 *     v2 —— 否则连续点按每次都先撞一次 412 → 反复上报 BiliRequestGate
 *     → 冷却升级把 v2 回退与字幕 CDN 一起拖过 6s 超时壳（实测超时来源）。
 */
async function fetchBestSubtitleMeta(target: SubtitleTarget, kind: string): Promise<SubtitleMetaOutcome> {
  const list: SubtitleMetasOutcome = await fetchSubtitleMetas(target);
  if (list.metas === null) {
    return { meta: null, reason: list.reason, definitive: list.definitive };
  }
  const picked: SubtitleMeta | null = pickBestSubtitle(list.metas, kind);
  if (picked === null) {
    // 全部条目无 URL（生成中）是瞬时 dirty，走 10 分钟节流而非 24h miss
    const pending: boolean = hasKindCandidate(list.metas, kind);
    return { meta: null, reason: pending ? 'dirty' : 'no-candidate', definitive: !pending };
  }
  return { meta: picked, reason: '', definitive: false };
}

/**
 * 取完整字幕列表（自动选优与手动选择列表共用的列表级入口），
 * 带空列表抖动 / 串台重试：实测同参数同通道下 `subtitles` 会在 空/非空 间抖动
 * （服务端风控指纹评分或缓存不一致所致），空结果会误报「没有可用字幕」；
 * 偶发还会直接返回**其它视频**的响应（identity mismatch，见 requestSubtitleMetas
 * 的身份校验）—— 两种脏结果都延迟 SUBTITLE_EMPTY_RETRY_MS 后同通道再拉一次
 * （换一次 gaia 指纹），消化绝大多数抖动 / 串台。仍失败才按各 reason 原样返回。
 * 两次列表请求 + 一次字幕文件全链最坏 ~2s，仍在 6s 超时壳内。
 */
async function fetchSubtitleMetas(target: SubtitleTarget): Promise<SubtitleMetasOutcome> {
  const first: SubtitleMetasOutcome = await fetchSubtitleMetasOnce(target);
  if (first.metas !== null || (first.reason !== 'empty' && first.reason !== 'mismatch')) {
    return first;
  }
  await delay(SUBTITLE_EMPTY_RETRY_MS);
  console.info(`[Lyric] subtitle list ${first.reason}, retry once cid=${target.cid}`);
  return await fetchSubtitleMetasOnce(target);
}

/** fetchSubtitleMetas 的单次尝试（空列表抖动重试的内层） */
async function fetchSubtitleMetasOnce(target: SubtitleTarget): Promise<SubtitleMetasOutcome> {
  const useWbi: boolean = Date.now() >= wbiChannelBlockedUntil;
  if (!useWbi) {
    return await requestSubtitleMetas(target, false);
  }
  try {
    return await requestSubtitleMetas(target, true);
  } catch (e) {
    const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
    wbiChannelBlockedUntil = Date.now() + WBI_CHANNEL_BLOCK_MS;
    console.info(`[Lyric] subtitle meta via wbi failed, fallback to v2`
      + ` (wbi blocked ${Math.round(WBI_CHANNEL_BLOCK_MS / 60000)}min): ${detail}`);
    return await requestSubtitleMetas(target, false);
  }
}

/** 字幕列表单次请求（useWbi=true 走 wbi/v2 签名通道；false 走 v2 旧通道） */
async function requestSubtitleMetas(
  target: SubtitleTarget,
  useWbi: boolean
): Promise<SubtitleMetasOutcome> {
  const params: Record<string, string | number> = Object.assign(
    { cid: target.cid },
    gaiaWebParams()
  );
  if (target.bvid.length > 0) {
    params['bvid'] = target.bvid;
  } else {
    params['aid'] = target.aid;
  }
  let envelope: SubtitlePlayerEnvelope;
  if (useWbi) {
    const query: string = await encodeWbi(params);
    envelope = await HttpUtil.requestJson<SubtitlePlayerEnvelope>(
      `${BILI_API}/x/player/wbi/v2?${query}`
    );
  } else {
    envelope = await HttpUtil.requestJson<SubtitlePlayerEnvelope>(
      `${BILI_API}/x/player/v2`,
      { params: params }
    );
  }
  if (envelope.code !== 0) {
    const code: number = envelope.code ?? -1;
    const isRisk: boolean = RETRYABLE_BIZ_CODES.indexOf(code) >= 0;
    console.info(`[Lyric] subtitle denied code=${code} msg=${envelope.message ?? ''}`
      + ` cookie=${isLoggedIn() ? 1 : 0} risk=${isRisk ? 1 : 0}`);
    if (isRisk) {
      return { metas: null, reason: 'risk', definitive: false };
    }
    return { metas: null, reason: 'denied', definitive: true };
  }
  // 身份校验（F3 串台防护）：实测该接口偶发返回**其它视频**的响应（与同参数下
  // subtitles 空/非空抖动同源，服务端缓存不一致）—— 拿到别人的字幕列表就是
  // 「AI 字幕是别的视频的字幕」+「探测显示有但实际没有」的根因。响应 data 回显
  // 请求的视频身份，逐项比对（回显缺失 = 无法校验 = 放行，防接口形态变化误杀）；
  // 不一致 → 串台，按瞬时失败返回（不 throw：throw 会触发 wbi 通道 10 分钟熔断，
  // 串台是服务端数据问题不是通道风控），由 fetchSubtitleMetas 换指纹重试。
  const echoedCid: number | undefined = envelope.data?.cid;
  const echoedBvid: string | undefined = envelope.data?.bvid;
  const echoedAid: number | undefined = envelope.data?.aid;
  const cidMismatch: boolean = echoedCid !== undefined && String(echoedCid) !== target.cid;
  const bvidMismatch: boolean = target.bvid.length > 0
    && (echoedBvid ?? '').length > 0 && echoedBvid !== target.bvid;
  const aidMismatch: boolean = target.bvid.length === 0 && target.aid.length > 0
    && echoedAid !== undefined && String(echoedAid) !== target.aid;
  if (cidMismatch || bvidMismatch || aidMismatch) {
    console.info(`[Lyric] subtitle list identity mismatch req cid=${target.cid}`
      + ` bvid=${target.bvid} aid=${target.aid} resp cid=${echoedCid ?? ''}`
      + ` bvid=${echoedBvid ?? ''} aid=${echoedAid ?? ''}`);
    return { metas: null, reason: 'mismatch', definitive: false };
  }
  const metas: SubtitleMeta[] | undefined = envelope.data?.subtitle?.subtitles;
  if (metas === undefined || !Array.isArray(metas) || metas.length === 0) {
    console.info(`[Lyric] subtitle list empty cookie=${isLoggedIn() ? 1 : 0} cid=${target.cid}`);
    return { metas: null, reason: 'empty', definitive: true };
  }
  return { metas: metas, reason: '', definitive: false };
}

/** 字幕文件 body[] → LyricLine[]；空白行跳过，有效行不足 → null */
function toLyricLines(body: SubtitleBodyLine[]): LyricLine[] | null {
  const lines: LyricLine[] = [];
  for (let i = 0; i < body.length; i++) {
    const item: SubtitleBodyLine = body[i];
    const text: string = (item.content ?? '').trim();
    const from: number = item.from ?? Number.NaN;
    if (text.length === 0 || !Number.isFinite(from) || from < 0) {
      continue;
    }
    lines.push({
      time: from,
      text: text,
      translation: '',
      romaji: '',
      words: []
    });
  }
  return lines.length >= MIN_SUBTITLE_LINES ? lines : null;
}

/**
 * 拉字幕文件 → 行数据（两条链路共用）。
 * 脏数据（body 缺失 / 有效行不足）→ null；网络错误原样抛出，
 * 由超时壳外层按 network 分级。
 */
async function fetchSubtitleLines(url: string): Promise<LyricLine[] | null> {
  const body: SubtitleFileBody = await HttpUtil.requestJson<SubtitleFileBody>(url);
  const rows: SubtitleBodyLine[] | undefined = body.body;
  if (rows === undefined || !Array.isArray(rows) || rows.length === 0) {
    return null;
  }
  return toLyricLines(rows);
}

/** 行数据的最大时间戳（秒）：扫全量取 max，防 body 乱序；空数组 → -1 */
function lastLineTime(lines: LyricLine[]): number {
  let max: number = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].time > max) {
      max = lines[i].time;
    }
  }
  return max;
}

/**
 * 字幕内容完整度判定：AI 智能字幕惰性生成，生成中只返回开头几句 ——
 * 半截歌词直接进 UI / manual 缓存正是「要多次点击才对」的根因。
 * 视频时长已知且末行时间不足一半 → 生成中；时长未知无从校验，不判。
 */
function isPartialSubtitle(track: Track, lines: LyricLine[]): boolean {
  if (track.duration <= 0 || lines.length === 0) {
    return false;
  }
  return lastLineTime(lines) < track.duration * SUBTITLE_PARTIAL_RATIO;
}

/**
 * 串台字幕文件判定（文件层，列表身份校验的补充）：跨度溢出（末行时间远超
 * 视频时长 = 别的更长视频的字幕）或密度溢出（行数/秒物理不可能）→ 串台。
 * 串台文件必须整体丢弃（不进 best、不返回、不落缓存），由完整度重试经
 * 列表换新 URL 重取 —— refetch 重新走列表，每次都能拿到新的 subtitle_url。
 * 时长未知无从校验，不判（与 isPartialSubtitle 同口径）。
 */
function isForeignSubtitle(track: Track, lines: LyricLine[]): boolean {
  if (track.duration <= 0 || lines.length === 0) {
    return false;
  }
  const spanOverflow: boolean = lastLineTime(lines)
    > track.duration * SUBTITLE_SPAN_OVERFLOW_RATIO + SUBTITLE_SPAN_OVERFLOW_SLACK_S;
  const densityMax: number = Math.max(40, track.duration * SUBTITLE_DENSITY_MAX_PER_SEC);
  const densityOverflow: boolean = lines.length > densityMax;
  return spanOverflow || densityOverflow;
}

/** fetchLinesWithCompletenessRetry 的返回：lines 为 null 时 foreignOnly 区分「全为串台文件」与「全脏（生成中）」 */
interface CompletenessRetryResult {
  lines: LyricLine[] | null;
  /** true = 曾取到内容但全部为串台文件（调用方映射 reason='mismatch'，区别于生成中的 'dirty'） */
  foreignOnly: boolean;
}

/**
 * 字幕行取数 + 完整度重试：首次结果脏（null，生成初期 body 空 / 有效行
 * 不足）、半截（末行时间不足时长一半）或**串台文件**（isForeignSubtitle，
 * B 站把别的视频的字幕文件挂进本视频列表）时延迟后由 refetch 重拉
 * （refetch 必须重新走列表 —— 生成完成态的 subtitle_url 会更新，串台文件
 * 换列表才能换到新 URL，只重拉原 URL 会一直拿到同一个串台文件），保留
 * 行数最多的一次；**串台文件整体丢弃，绝不进 best / 返回 / 落缓存** ——
 * 否则「拿到别的视频的字幕」直达 UI（F 串台教训）。refetch 期间的单次网络
 * 失败吞掉继续重试（已有部分结果时不能被一次抖动废掉整链）。
 * 延迟递增（400×n），连续两次重取行数不增 → 内容已稳定（纯音乐尾奏等
 * 合法早结束），早停省请求。maxAttempts 由调用方给（自动链 3 / 手动链 4）。
 * 返回 CompletenessRetryResult：lines 为 null 时 foreignOnly=true 表示
 * 全部尝试都拿到串台文件（调用方映射 'mismatch'），false 表示纯生成中
 * （映射 'dirty'）。
 */
async function fetchLinesWithCompletenessRetry(
  track: Track,
  firstLines: LyricLine[] | null,
  refetch: () => Promise<LyricLine[] | null>,
  maxAttempts: number
): Promise<CompletenessRetryResult> {
  let sawForeign: boolean = false;
  // 入口净化：首个结果就是串台文件 → 丢弃，不能作为 best 保留
  if (firstLines !== null && isForeignSubtitle(track, firstLines)) {
    console.info(`[Lyric] subtitle foreign discard lines=${firstLines.length}`
      + ` last=${lastLineTime(firstLines)}s dur=${track.duration}s track=${track.title}`);
    sawForeign = true;
  }
  let best: LyricLine[] | null
    = firstLines !== null && !isForeignSubtitle(track, firstLines) ? firstLines : null;
  let current: LyricLine[] | null = best;
  let noGrowth: number = 0;
  for (let attempt: number = 1; attempt < maxAttempts; attempt++) {
    if (current !== null && !isPartialSubtitle(track, current)) {
      break;
    }
    if (current === null) {
      console.info(`[Lyric] subtitle dirty, retry attempt=${attempt} track=${track.title}`);
    } else {
      console.info(`[Lyric] subtitle partial lines=${current.length} attempt=${attempt} track=${track.title}`);
    }
    await delay(SUBTITLE_PARTIAL_RETRY_BASE_MS * attempt);
    try {
      current = await refetch();
    } catch (e) {
      console.info(`[Lyric] subtitle refetch failed attempt=${attempt} track=${track.title}`
        + ` err=${e instanceof Error ? e.message : JSON.stringify(e)}`);
      current = null;
    }
    if (current === null) {
      continue;
    }
    // 串台文件整体丢弃：不进 best、不参与 noGrowth 计数，继续换 URL 重取
    if (isForeignSubtitle(track, current)) {
      console.info(`[Lyric] subtitle foreign discard lines=${current.length}`
        + ` last=${lastLineTime(current)}s dur=${track.duration}s track=${track.title}`);
      sawForeign = true;
      current = null;
      continue;
    }
    if (best === null || current.length > best.length) {
      best = current;
      noGrowth = 0;
    } else {
      noGrowth++;
      if (noGrowth >= 2) {
        break;
      }
    }
  }
  return { lines: best, foreignOnly: best === null && sawForeign };
}

/**
 * 取某曲目的 B 站字幕歌词（CC / AI 兜底源），带失败分级。
 * kind：`auto`（默认，自动选优）/ `cc`（只要人工字幕）/ `ai`（只要 AI 字幕）。
 * 超时壳：整条链被 SUBTITLE_TIMEOUT_MS 墙钟罩住，超时 → timeout（瞬时）。
 * 绝不抛错 —— 歌词是锦上添花，outcome 的 reason 只是数据不是异常。
 */
export function fetchSubtitleOutcome(
  track: Track,
  kind: string = SUBTITLE_KIND_AUTO
): Promise<SubtitleOutcome> {
  return new Promise<SubtitleOutcome>((resolve: (v: SubtitleOutcome) => void): void => {
    let settled: boolean = false;
    const timer: number = setTimeout((): void => {
      if (settled) {
        return;
      }
      settled = true;
      console.warn(`[Lyric] subtitle timeout ${SUBTITLE_TIMEOUT_MS}ms track=${track.title}`);
      resolve({ result: null, definitive: false, reason: 'timeout' });
    }, SUBTITLE_TIMEOUT_MS);
    function finish(value: SubtitleOutcome): void {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve(value);
    }
    runSubtitleChain(track, kind)
      .then((outcome: SubtitleOutcome): void => {
        finish(outcome);
      })
      .catch((e: Object): void => {
        // ⚠️ 不能 JSON.stringify：Error 的属性不可枚举，序列化只剩 {}，
        // 把「HTTP 412 for …」这类关键信息全吞了（F1 失败可见化的教训）。
        const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
        console.info(`[Lyric] subtitle chain failed: ${detail}`);
        finish({ result: null, definitive: false, reason: 'network' });
      });
  });
}

/**
 * 可选字幕条目（手动选择列表用）。
 * id 必须稳定：既是 ForEach 的 key，也是取数防重复点选的标记。
 */
export interface SubtitleChoice {
  /** `${isAi?'ai':'cc'}-${lan}-${序号}`，同 lan 多条靠序号区分 */
  id: string;
  /** 语言代码：zh-Hans / ai-zh / en … */
  lan: string;
  /** isAiSubtitle() 的判定结果（lan 前缀 + ai_type 双口径） */
  isAi: boolean;
  /** normalizeSubtitleUrl() 后的绝对地址 */
  subtitleUrl: string;
}

/** 手动选择链路的列表级 outcome：choices 空数组 = 该 kind 下无候选 */
export interface SubtitleChoicesOutcome {
  choices: SubtitleChoice[];
  /** true = 结论性失败（no-candidate / empty / denied / no-target）；false = 瞬时 */
  definitive: boolean;
  /** 机器可读原因：命中为空串 */
  reason: string;
}

/**
 * 列出某曲目可手动选择的 B 站字幕（长按面板 CC / AI 按钮的取列表入口）。
 * 与自动选优共用列表取数（fetchSubtitleMetas，通道回退 + 熔断 + 6s 超时壳），
 * 但不做选优 —— 单候选 UI 直接应用，多候选展示列表让用户挑：
 * 多字幕视频上自动选优不确定（智能字幕内容不稳定），明确选择才确定。
 * kind 过滤口径与 pickBestSubtitle 一致（isAiSubtitle 判 CC/AI）。
 */
export function fetchSubtitleChoices(
  track: Track,
  kind: string
): Promise<SubtitleChoicesOutcome> {
  return new Promise<SubtitleChoicesOutcome>((resolve: (v: SubtitleChoicesOutcome) => void): void => {
    let settled: boolean = false;
    const timer: number = setTimeout((): void => {
      if (settled) {
        return;
      }
      settled = true;
      console.warn(`[Lyric] subtitle list timeout ${SUBTITLE_TIMEOUT_MS}ms track=${track.title}`);
      resolve({ choices: [], definitive: false, reason: 'timeout' });
    }, SUBTITLE_TIMEOUT_MS);
    function finish(value: SubtitleChoicesOutcome): void {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve(value);
    }
    runChoicesChain(track, kind)
      .then((outcome: SubtitleChoicesOutcome): void => {
        finish(outcome);
      })
      .catch((e: Object): void => {
        const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
        console.info(`[Lyric] subtitle choices chain failed: ${detail}`);
        finish({ choices: [], definitive: false, reason: 'network' });
      });
  });
}

/** fetchSubtitleChoices 的实际链路（被 6s 超时壳包住） */
async function runChoicesChain(track: Track, kind: string): Promise<SubtitleChoicesOutcome> {
  const resolved: SubtitleTargetResolve = await resolveSubtitleTarget(track);
  if (resolved.target === null) {
    const definitive: boolean = resolved.reason === 'no-target';
    return { choices: [], definitive: definitive, reason: resolved.reason };
  }
  const list: SubtitleMetasOutcome = await fetchSubtitleMetas(resolved.target);
  if (list.metas === null) {
    // 点击链结论回填探测缓存（empty/denied 结论性才写；risk/timeout 瞬时不写）：
    // 用户点过按钮 = 列表数据比探测新，重开面板免二次探测
    if (list.definitive) {
      probeCache.set(track.id, {
        availability: {
          ccCount: 0, aiCount: 0, aiPending: false,
          definitive: true, reason: list.reason
        },
        cachedAt: Date.now()
      });
    }
    return { choices: [], definitive: list.definitive, reason: list.reason };
  }
  const metas: SubtitleMeta[] = list.metas;
  // 点击链结论回填探测缓存（非 dirty 结论才写）：同上，点击即最新列表
  const probed: SubtitleAvailability = countAvailability(metas);
  if (probed.definitive) {
    probeCache.set(track.id, { availability: probed, cachedAt: Date.now() });
  }
  // F1 诊断日志：完整列表打出来 —— AI/CC 归类、候选数一眼可辨
  const tags: string[] = metas.map((m: SubtitleMeta): string => `${m.lan ?? ''}:${isAiSubtitle(m) ? 'ai' : 'cc'}`);
  console.info(`[Lyric] subtitle list n=${metas.length} kinds=[${tags.join(', ')}] track=${track.title}`);
  const choices: SubtitleChoice[] = [];
  for (let i = 0; i < metas.length; i++) {
    const meta: SubtitleMeta = metas[i];
    const url: string = normalizeSubtitleUrl(meta.subtitle_url ?? '');
    if (url.length === 0) {
      continue;
    }
    const isAi: boolean = isAiSubtitle(meta);
    if (kind === SUBTITLE_KIND_CC && isAi) {
      continue;
    }
    if (kind === SUBTITLE_KIND_AI && !isAi) {
      continue;
    }
    choices.push({
      id: `${isAi ? 'ai' : 'cc'}-${meta.lan ?? ''}-${choices.length}`,
      lan: meta.lan ?? '',
      isAi: isAi,
      subtitleUrl: url
    });
  }
  if (choices.length === 0) {
    // kind 匹配的条目存在但全无 URL（生成中）→ 瞬时 dirty，提示稍后再试
    const pending: boolean = hasKindCandidate(metas, kind);
    return { choices: [], definitive: !pending, reason: pending ? 'dirty' : 'no-candidate' };
  }
  return { choices: choices, definitive: false, reason: '' };
}

/**
 * 字幕可用性探测结果（长按面板按钮门控用，一次列表请求同时回答 CC/AI 两问）。
 * 探测本身即预热：B 站 AI 字幕惰性生成由首次播放器请求触发 —— 面板打开时
 * 探测、用户点按钮时生成已提前进行（「要多次点击才成功」的根因之一就是
 * 首次点击才触发生成）。
 */
export interface SubtitleAvailability {
  /** 有 subtitle_url 的 CC 条目数 */
  ccCount: number;
  /** 有 subtitle_url 的 AI 条目数 */
  aiCount: number;
  /** AI 条目存在但暂无 URL（B 站惰性生成中）—— 按钮显示「生成中」且保持可点 */
  aiPending: boolean;
  /** true = 列表结论性拿到（含空列表）；false = 瞬时失败（risk/timeout/network/dirty），按钮不得禁用 */
  definitive: boolean;
  /** 机器可读原因：'' / no-target / denied / empty / risk / timeout / network / dirty / blocked */
  reason: string;
}

/** 探测结论缓存时长（ms）：同曲目该窗内重复开面板直接用缓存，零请求 */
const PROBE_CACHE_TTL_MS: number = 5 * 60 * 1000;
/**
 * 探测风控熔断时长（ms）：risk 信号（业务码 -352/-412/-509/-799 或
 * HTTP 412/403/429）后暂停自动探测。不熔断的代价：探测反复撞 412 →
 * 反复上报 BiliRequestGate.noteRisk() → 全局冷却阶梯升级（2s→5s→12s），
 * 冷却期连高优先播放链也排队 —— 探测这种锦上添花绝不能拖慢点歌出声。
 */
const PROBE_BLOCK_MS: number = 5 * 60 * 1000;

/** 探测结论缓存条目（track.id → 结果 + 写入时刻） */
interface ProbeCacheEntry {
  availability: SubtitleAvailability;
  cachedAt: number;
}

/**
 * 探测结论缓存：只缓存 definitive 结论（有/无字幕是稳定事实）；
 * pending（AI 生成中）与瞬时失败不缓存 —— 前者由用户手动重检拿新态，
 * 后者不该挡重试。内存级、不落盘，进程重启自然清零。
 */
const probeCache: Map<string, ProbeCacheEntry> = new Map();

/** 探测熔断截止时刻（0 = 未熔断）；模块级、不落盘，进程重启自然清零 */
let probeBlockedUntil: number = 0;

/**
 * 探测某曲目 B 站字幕可用性（长按面板打开时的按钮门控入口）。
 * 与 fetchSubtitleChoices 共用列表取数（fetchSubtitleMetas：wbi→v2 通道
 * 回退 + 412 熔断 + 空列表抖动重试），但不过滤 kind —— 一次列表同时统计
 * CC/AI 两类条目。6s 超时壳同 fetchSubtitleChoices。
 *
 * 风控规避（判定次序：探测熔断 → 闸门冷却 → 结论缓存 → 网络）：
 *   · 探测熔断（probeBlockedUntil，risk 信号后 PROBE_BLOCK_MS）期间一律
 *     返回 blocked 合成结果，force 也不放行 —— 手动重试同样会撞风控；
 *   · 闸门冷却期（2~12s 短窗）跳过：此时发请求必然排队白耗 6s 超时壳；
 *   · 结论缓存（PROBE_CACHE_TTL_MS）：同曲目窗内重复探测零请求，
 *     force=true（面板「重新检测」）跳过缓存拿新数据；
 *   · 结论性结果写缓存、点击链（runChoicesChain）同步回填 —— 用户点过
 *     按钮后重开面板直接用缓存结论。
 */
export function probeBiliSubtitleAvailability(
  track: Track,
  force: boolean = false
): Promise<SubtitleAvailability> {
  return new Promise<SubtitleAvailability>((resolve: (v: SubtitleAvailability) => void): void => {
    const blocked: SubtitleAvailability = {
      ccCount: 0, aiCount: 0, aiPending: false, definitive: false, reason: 'blocked'
    };
    if (Date.now() < probeBlockedUntil || BiliRequestGate.isCoolingDown()) {
      resolve(blocked);
      return;
    }
    if (!force) {
      const cached: ProbeCacheEntry | undefined = probeCache.get(track.id);
      if (cached !== undefined && cached.availability.definitive
        && Date.now() - cached.cachedAt < PROBE_CACHE_TTL_MS) {
        resolve(cached.availability);
        return;
      }
    }
    let settled: boolean = false;
    const timer: number = setTimeout((): void => {
      if (settled) {
        return;
      }
      settled = true;
      console.warn(`[Lyric] subtitle probe timeout ${SUBTITLE_TIMEOUT_MS}ms track=${track.title}`);
      resolve({ ccCount: 0, aiCount: 0, aiPending: false, definitive: false, reason: 'timeout' });
    }, SUBTITLE_TIMEOUT_MS);
    function finish(value: SubtitleAvailability): void {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve(value);
    }
    runProbeChain(track)
      .then((availability: SubtitleAvailability): void => {
        // 业务码风控 → 探测级熔断（防止后续开面板继续撞、升级全局冷却）
        if (availability.reason === 'risk') {
          probeBlockedUntil = Date.now() + PROBE_BLOCK_MS;
        }
        // 结论性结果写缓存（pending / 瞬时失败不写）
        if (availability.definitive) {
          probeCache.set(track.id, { availability: availability, cachedAt: Date.now() });
        }
        finish(availability);
      })
      .catch((e: Object): void => {
        const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
        console.info(`[Lyric] subtitle probe chain failed: ${detail}`);
        // HTTP 层风控（412/403/429 上浮为 Error）→ 探测级熔断
        if (detail.indexOf('HTTP 412') >= 0 || detail.indexOf('HTTP 403') >= 0
          || detail.indexOf('HTTP 429') >= 0) {
          probeBlockedUntil = Date.now() + PROBE_BLOCK_MS;
          finish({ ccCount: 0, aiCount: 0, aiPending: false, definitive: false, reason: 'risk' });
          return;
        }
        finish({ ccCount: 0, aiCount: 0, aiPending: false, definitive: false, reason: 'network' });
      });
  });
}

/**
 * metas → 可用性计数（CC/AI 有 URL 计数、AI 无 URL 置 pending）。
 * 探测链与点击链回填共用；列表非空但全无 URL（AI 生成初期）按瞬时
 * dirty 处理（definitive=false），按钮显示「生成中」不得禁用。
 */
function countAvailability(metas: SubtitleMeta[]): SubtitleAvailability {
  let ccCount: number = 0;
  let aiCount: number = 0;
  let aiPending: boolean = false;
  for (let i: number = 0; i < metas.length; i++) {
    const meta: SubtitleMeta = metas[i];
    const hasUrl: boolean = (meta.subtitle_url ?? '').length > 0;
    if (isAiSubtitle(meta)) {
      if (hasUrl) {
        aiCount++;
      } else {
        aiPending = true;
      }
    } else if (hasUrl) {
      ccCount++;
    }
  }
  const dirty: boolean = ccCount === 0 && aiCount === 0 && metas.length > 0;
  return {
    ccCount: ccCount,
    aiCount: aiCount,
    aiPending: aiPending,
    definitive: !dirty,
    reason: dirty ? 'dirty' : ''
  };
}

/** probeBiliSubtitleAvailability 的实际链路（被 6s 超时壳包住） */
async function runProbeChain(track: Track): Promise<SubtitleAvailability> {
  const resolved: SubtitleTargetResolve = await resolveSubtitleTarget(track);
  if (resolved.target === null) {
    const definitive: boolean = resolved.reason === 'no-target';
    return { ccCount: 0, aiCount: 0, aiPending: false, definitive: definitive, reason: resolved.reason };
  }
  const list: SubtitleMetasOutcome = await fetchSubtitleMetas(resolved.target);
  if (list.metas === null) {
    // empty（登录态下列表真空）/ denied 是结论性；risk 是瞬时 —— definitive 原样透传
    return {
      ccCount: 0,
      aiCount: 0,
      aiPending: false,
      definitive: list.definitive,
      reason: list.reason
    };
  }
  const availability: SubtitleAvailability = countAvailability(list.metas);
  console.info(`[Lyric] subtitle probe cc=${availability.ccCount} ai=${availability.aiCount}`
    + ` aiPending=${availability.aiPending ? 1 : 0} n=${list.metas.length} track=${track.title}`);
  return availability;
}

/**
 * 按用户明确选择的条目取字幕（多候选列表点选后的取数入口）。
 * 与 fetchSubtitleOutcome 同款 6s 超时壳；source 按 choice.isAi 落
 * SOURCE_BILI_AI / SOURCE_BILI_CC（面板副标题与缓存源标识据此显示）。
 */
export function fetchSubtitleByChoice(
  track: Track,
  choice: SubtitleChoice
): Promise<SubtitleOutcome> {
  return new Promise<SubtitleOutcome>((resolve: (v: SubtitleOutcome) => void): void => {
    let settled: boolean = false;
    const timer: number = setTimeout((): void => {
      if (settled) {
        return;
      }
      settled = true;
      console.warn(`[Lyric] subtitle timeout ${SUBTITLE_CHOICE_TIMEOUT_MS}ms track=${track.title}`);
      resolve({ result: null, definitive: false, reason: 'timeout' });
    }, SUBTITLE_CHOICE_TIMEOUT_MS);
    function finish(value: SubtitleOutcome): void {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve(value);
    }
    runChoiceChain(track, choice)
      .then((outcome: SubtitleOutcome): void => {
        finish(outcome);
      })
      .catch((e: Object): void => {
        // 同 fetchSubtitleOutcome 的教训：Error 不能 JSON.stringify（信息会全吞）
        const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
        console.info(`[Lyric] subtitle choice chain failed: ${detail}`);
        finish({ result: null, definitive: false, reason: 'network' });
      });
  });
}

/** fetchSubtitleByChoice 的实际链路（被 6s 超时壳包住） */
async function runChoiceChain(track: Track, choice: SubtitleChoice): Promise<SubtitleOutcome> {
  const resolved: SubtitleTargetResolve = await resolveSubtitleTarget(track);
  if (resolved.target === null) {
    const definitive: boolean = resolved.reason === 'no-target';
    return { result: null, definitive: definitive, reason: resolved.reason };
  }
  const target: SubtitleTarget = resolved.target;
  const firstLines: LyricLine[] | null = await fetchSubtitleLines(choice.subtitleUrl);
  const retried: CompletenessRetryResult = await fetchLinesWithCompletenessRetry(
    track,
    firstLines,
    (): Promise<LyricLine[] | null> => refetchChoiceLines(target, choice),
    SUBTITLE_PARTIAL_MAX_ATTEMPTS_CHOICE
  );
  const lines: LyricLine[] | null = retried.lines;
  if (lines === null) {
    // 重试穷尽仍脏：dirty=生成慢 / mismatch=全为串台文件，都是瞬时态不写 24h miss
    return { result: null, definitive: false, reason: retried.foreignOnly ? 'mismatch' : 'dirty' };
  }
  const result: LyricResult = {
    lines: lines,
    synced: true,
    instrumental: false,
    trackName: track.title,
    artistName: track.artist,
    sourceId: target.cid,
    source: choice.isAi ? SOURCE_BILI_AI : SOURCE_BILI_CC,
    hasTranslation: false,
    dynamic: false
  };
  console.info(`[Lyric] subtitle hit lang=${choice.lan} ai=${choice.isAi ? 1 : 0}`
    + ` lines=${lines.length} track=${track.title}`);
  return { result: result, definitive: false, reason: '', partial: isPartialSubtitle(track, lines) };
}

/**
 * 完整度重试的重取（手动链路）：重新走列表 —— 生成完成态会多出 AI 翻译
 * 语言且 subtitle_url 更新（只重拉原 URL 会一直拿到旧的半截快照）——
 * 按 lan + isAi 匹回同一字幕再拉文件。列表失败 / 匹配不到 → null（重试停）。
 */
async function refetchChoiceLines(target: SubtitleTarget, choice: SubtitleChoice): Promise<LyricLine[] | null> {
  const list: SubtitleMetasOutcome = await fetchSubtitleMetas(target);
  if (list.metas === null) {
    return null;
  }
  for (let i: number = 0; i < list.metas.length; i++) {
    const meta: SubtitleMeta = list.metas[i];
    if (meta.lan === choice.lan && isAiSubtitle(meta) === choice.isAi) {
      const url: string = normalizeSubtitleUrl(meta.subtitle_url ?? '');
      if (url.length === 0) {
        continue;
      }
      return await fetchSubtitleLines(url);
    }
  }
  return null;
}

/** 实际链路（被 fetchSubtitleOutcome 的超时壳包住），产 SubtitleOutcome */
async function runSubtitleChain(track: Track, kind: string): Promise<SubtitleOutcome> {
  const resolved: SubtitleTargetResolve = await resolveSubtitleTarget(track);
  if (resolved.target === null) {
    // no-target（bvid/aid 全空）是曲目数据的结论性状态；补 cid 失败是瞬时网络问题
    const definitive: boolean = resolved.reason === 'no-target';
    return { result: null, definitive: definitive, reason: resolved.reason };
  }
  const target: SubtitleTarget = resolved.target;
  const metaOutcome: SubtitleMetaOutcome = await fetchBestSubtitleMeta(target, kind);
  if (metaOutcome.meta === null) {
    return { result: null, definitive: metaOutcome.definitive, reason: metaOutcome.reason };
  }
  const meta: SubtitleMeta = metaOutcome.meta;
  const firstLines: LyricLine[] | null = await fetchSubtitleLines(
    normalizeSubtitleUrl(meta.subtitle_url ?? '')
  );
  const retried: CompletenessRetryResult = await fetchLinesWithCompletenessRetry(
    track,
    firstLines,
    (): Promise<LyricLine[] | null> => refetchBestLines(target, kind),
    SUBTITLE_PARTIAL_MAX_ATTEMPTS
  );
  const lines: LyricLine[] | null = retried.lines;
  if (lines === null) {
    // 重试穷尽仍脏：dirty=生成慢 / mismatch=全为串台文件，都是瞬时态不写 24h miss
    return { result: null, definitive: false, reason: retried.foreignOnly ? 'mismatch' : 'dirty' };
  }
  const result: LyricResult = {
    lines: lines,
    synced: true,
    instrumental: false,
    trackName: track.title,
    artistName: track.artist,
    sourceId: target.cid,
    source: isAiSubtitle(meta) ? SOURCE_BILI_AI : SOURCE_BILI_CC,
    hasTranslation: false,
    dynamic: false
  };
  console.info(`[Lyric] subtitle hit lang=${meta.lan ?? ''} ai=${isAiSubtitle(meta) ? 1 : 0}`
    + ` lines=${lines.length} track=${track.title}`);
  return { result: result, definitive: false, reason: '', partial: isPartialSubtitle(track, lines) };
}

/** 自动链路的完整度重试重取：重新列表选优后拉文件；链路失败 → null（重试停） */
async function refetchBestLines(target: SubtitleTarget, kind: string): Promise<LyricLine[] | null> {
  const metaOutcome: SubtitleMetaOutcome = await fetchBestSubtitleMeta(target, kind);
  if (metaOutcome.meta === null) {
    return null;
  }
  const url: string = normalizeSubtitleUrl(metaOutcome.meta.subtitle_url ?? '');
  if (url.length === 0) {
    return null;
  }
  return await fetchSubtitleLines(url);
}
