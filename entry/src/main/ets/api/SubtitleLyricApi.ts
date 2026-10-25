/**
 * B 站字幕歌词源（末位兜底）。
 *
 * 外部歌词源（网易云 / QQ / OIAPI）靠「标题 + 歌手」搜歌，VOCALOID 原创、
 * 二次创作、电台片段这类曲库外的歌永远搜不到 —— 但它们的视频本身往往有
 * CC 字幕（UP 主 / 官方上传）或 AI 字幕（B 站语音识别生成），行级时间戳
 * 与音轨天然对齐，可直接当逐行 LRC 用。
 *
 * 链路（任一步失败 / 超时一律返回 null，绝不抛错 —— 歌词是锦上添花）：
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
import { getVideoDetail } from './BilibiliApi';
import { HttpUtil } from '../utils/HttpUtil';

/** CC 字幕源标识（ai_type !== 1，人工上传） */
export const SOURCE_BILI_CC: string = 'bilibili-cc';
/** AI 字幕源标识（ai_type === 1，B 站语音识别生成） */
export const SOURCE_BILI_AI: string = 'bilibili-ai';

/** 整条字幕链路的超时（ms）：全链最多两个请求，卡住时不能拖住播放页歌词区 */
const SUBTITLE_TIMEOUT_MS: number = 6000;
/** 少于该行数的字幕视为脏数据（AI 字幕偶发空壳 / 纯音乐视频的零星杂行） */
const MIN_SUBTITLE_LINES: number = 3;

/** `/x/player/wbi/v2` 响应壳（只声明本源用到的字段，脏数据防御靠逐层可选） */
interface SubtitlePlayerEnvelope {
  code?: number;
  message?: string;
  data?: SubtitlePlayerData;
}

interface SubtitlePlayerData {
  subtitle?: SubtitleList;
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

/** 字幕语言是否中文（zh-CN / zh-Hans / ai-zh …统一按前缀 zh 判定） */
function isZhLan(lan: string): boolean {
  return lan.indexOf('zh') === 0;
}

/**
 * 定位视频：bvid + cid 优先；bvid 缺失时退 aid + cid；cid 缺失时
 * getVideoDetail(bvid) 补（viewCache 命中近乎零开销）。全空 → null。
 */
async function resolveSubtitleTarget(track: Track): Promise<SubtitleTarget | null> {
  let bvid: string = track.bvid;
  let aid: string = track.aid;
  let cid: string = track.cid;
  if (cid.length === 0 && bvid.length > 0) {
    try {
      const detail = await getVideoDetail(bvid);
      cid = String(detail.cid);
      if (aid.length === 0) {
        aid = String(detail.aid);
      }
    } catch (e) {
      return null;
    }
  }
  if (cid.length === 0 || (bvid.length === 0 && aid.length === 0)) {
    return null;
  }
  return { bvid: bvid, aid: aid, cid: cid };
}

/**
 * 选最优字幕：CC（人工）优先于 AI（机器识别），中文优先于其它语言。
 * 空列表 → null。
 */
function pickBestSubtitle(metas: SubtitleMeta[]): SubtitleMeta | null {
  let ccZh: SubtitleMeta | null = null;
  let ccAny: SubtitleMeta | null = null;
  let aiZh: SubtitleMeta | null = null;
  let aiAny: SubtitleMeta | null = null;
  for (let i = 0; i < metas.length; i++) {
    const meta: SubtitleMeta = metas[i];
    if (meta.subtitle_url === undefined || meta.subtitle_url.length === 0) {
      continue;
    }
    const isAi: boolean = meta.ai_type === 1;
    const isZh: boolean = isZhLan(meta.lan ?? '');
    if (!isAi) {
      if (isZh && ccZh === null) {
        ccZh = meta;
      } else if (!isZh && ccAny === null) {
        ccAny = meta;
      }
    } else {
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
 * 取字幕列表并选优。
 * `x/player/wbi/v2` 与 playurl 同域同签名体系；响应里 `subtitles`
 * 为空数组即「无可用字幕」（未登录 / 无字幕视频都长这样），落 null。
 */
async function fetchBestSubtitleMeta(target: SubtitleTarget): Promise<SubtitleMeta | null> {
  const params: Record<string, string | number> = { cid: target.cid };
  if (target.bvid.length > 0) {
    params['bvid'] = target.bvid;
  } else {
    params['aid'] = target.aid;
  }
  const query: string = await encodeWbi(params);
  const envelope: SubtitlePlayerEnvelope = await HttpUtil.requestJson<SubtitlePlayerEnvelope>(
    `${BILI_API}/x/player/wbi/v2?${query}`
  );
  if (envelope.code !== 0) {
    return null;
  }
  const metas: SubtitleMeta[] | undefined = envelope.data?.subtitle?.subtitles;
  if (metas === undefined || !Array.isArray(metas) || metas.length === 0) {
    return null;
  }
  return pickBestSubtitle(metas);
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
 * 取某曲目的 B 站字幕歌词（CC / AI 兜底源）。
 * 返回 null = 无可用字幕（未登录、无字幕视频、接口失败、超时均属此类）。
 */
export async function fetchSubtitleLyric(track: Track): Promise<LyricResult | null> {
  return new Promise<LyricResult | null>((resolve: (v: LyricResult | null) => void): void => {
    let settled: boolean = false;
    const timer: number = setTimeout((): void => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(null);
    }, SUBTITLE_TIMEOUT_MS);
    function finish(value: LyricResult | null): void {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve(value);
    }
    runSubtitleChain(track)
      .then((result: LyricResult | null): void => {
        finish(result);
      })
      .catch((e: Object): void => {
        console.info(`[Lyric] subtitle chain failed: ${JSON.stringify(e)}`);
        finish(null);
      });
  });
}

/** 实际链路（被 fetchSubtitleLyric 的超时壳包住） */
async function runSubtitleChain(track: Track): Promise<LyricResult | null> {
  const target: SubtitleTarget | null = await resolveSubtitleTarget(track);
  if (target === null) {
    return null;
  }
  const meta: SubtitleMeta | null = await fetchBestSubtitleMeta(target);
  if (meta === null) {
    return null;
  }
  const body: SubtitleFileBody = await HttpUtil.requestJson<SubtitleFileBody>(
    normalizeSubtitleUrl(meta.subtitle_url ?? '')
  );
  const rows: SubtitleBodyLine[] | undefined = body.body;
  if (rows === undefined || !Array.isArray(rows) || rows.length === 0) {
    return null;
  }
  const lines: LyricLine[] | null = toLyricLines(rows);
  if (lines === null) {
    return null;
  }
  const result: LyricResult = {
    lines: lines,
    synced: true,
    instrumental: false,
    trackName: track.title,
    artistName: track.artist,
    sourceId: target.cid,
    source: meta.ai_type === 1 ? SOURCE_BILI_AI : SOURCE_BILI_CC,
    hasTranslation: false,
    dynamic: false
  };
  console.info(`[Lyric] subtitle hit lang=${meta.lan ?? ''} ai=${meta.ai_type ?? 0}`
    + ` lines=${lines.length} track=${track.title}`);
  return result;
}
