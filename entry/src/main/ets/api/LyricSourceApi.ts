/**
 * 歌词源适配层 —— 移植自 BBPlayer `apps/mobile/src/lib/api/{netease,qqmusic}/api.ts`。
 *
 * 三个源，全部走「搜索候选 → 取歌词」两步：
 *   1. **网易云**（`netease`）：**免加密**老通道
 *      - 搜索 `GET https://music.163.com/api/search/get?s=&type=1&limit=&offset=`
 *      - 歌词 `GET https://music.163.com/api/song/lyric/v1?id=&lv=-1&tv=-1&rv=-1&yv=-1`
 *        同时给出 **主歌词 + 中文翻译(tlyric) + 罗马音(romalrc)**，
 *        `lrc.lyric` 还可能是逐字（YRC）文本 —— 这是本次移植的核心收益。
 *   2. **QQ 音乐**（`qq`）：官方 `musicu.fcg` 搜索 + `fcg_query_lyric_new.fcg` 歌词，
 *      带 `trans` 翻译轨；只要 Referer，不需要签名。
 *   3. **OIAPI**（`oiapi`）：本工程原有的第三方 QQ 歌词代理，保留作兜底
 *      （前两个源都拿不到时才会用；它没有翻译轨）。
 *
 * 三者对上层暴露同一套 `LyricSongCandidate` / `RawLyricData`，
 * 歌词统一转成 **SPL 文本**（含逐字标签），由 `lyric/SplLyrics.ets` 解析。
 */

import http from '@ohos.net.http';
import { HttpUtil, HttpRequestOptions } from '../utils/HttpUtil';
import { yrcToSpl } from '../lyric/SplLyrics';
import { OIAPI_QQ_LYRIC } from '../common/Constants';

/** 歌词源标识 */
export const SOURCE_NETEASE: string = 'netease';
export const SOURCE_QQ: string = 'qq';
export const SOURCE_OIAPI: string = 'oiapi';

/** 一个搜索到的歌曲候选（duration 单位：秒，与 Track.duration 一致） */
export interface LyricSongCandidate {
  source: string;
  /** 源内唯一 id：网易云数字 id / QQ songmid / OIAPI id */
  remoteId: string;
  title: string;
  artist: string;
  album: string;
  /** 时长（秒），0 = 未知 */
  duration: number;
}

/** 某个源取回的原始歌词（已转 SPL 文本） */
export interface RawLyricData {
  lrc: string;
  tlyric: string;
  romalrc: string;
  /** 是否带逐字标签（用于 UI 选择卡拉 OK 效果） */
  dynamic: boolean;
}

const UA_DESKTOP: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const UA_NETEASE_PC: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/** 第三方源的请求头：不带 B 站 Cookie / Referer，自己给源的 Referer */
function thirdPartyOptions(referer: string, extra?: Record<string, string>): HttpRequestOptions {
  const headers: Record<string, string> = {
    'User-Agent': UA_DESKTOP,
    Referer: referer
  };
  if (extra !== undefined) {
    const keys: string[] = Object.keys(extra);
    for (let i = 0; i < keys.length; i++) {
      headers[keys[i]] = extra[keys[i]];
    }
  }
  const options: HttpRequestOptions = {
    headers: headers,
    skipCookie: true,
    skipReferer: true
  };
  return options;
}

function safeJson<T>(text: string): T | null {
  if (!text || text.length === 0) {
    return null;
  }
  // JSONP 剥壳：`MusicJsonCallback({...})`
  let body: string = text.trim();
  const lparen: number = body.indexOf('(');
  if (!body.startsWith('{') && !body.startsWith('[') && lparen > 0 && body.endsWith(')')) {
    body = body.substring(lparen + 1, body.length - 1);
  }
  try {
    return JSON.parse(body) as T;
  } catch (e) {
    return null;
  }
}

// ───────────────────────────── 网易云 ─────────────────────────────

interface NsArtist {
  name?: string;
}

interface NsAlbum {
  name?: string;
}

interface NsSong {
  id?: number;
  name?: string;
  artists?: NsArtist[];
  album?: NsAlbum;
  /** 毫秒 */
  duration?: number;
}

interface NsSearchResponse {
  code?: number;
  result?: NsSearchBody;
}

interface NsSearchBody {
  songs?: NsSong[];
}

interface NsLyricBlock {
  lyric?: string;
}

interface NsLyricResponse {
  code?: number;
  lrc?: NsLyricBlock;
  tlyric?: NsLyricBlock;
  romalrc?: NsLyricBlock;
}

export async function neteaseSearch(keyword: string, limit: number): Promise<LyricSongCandidate[]> {
  const url: string = `https://music.163.com/api/search/get?s=${encodeURIComponent(keyword)}`
    + `&type=1&limit=${limit}&offset=0`;
  const options: HttpRequestOptions = thirdPartyOptions('https://music.163.com/', {
    'User-Agent': UA_NETEASE_PC
  });
  const text: string = await HttpUtil.requestText(url, options);
  const json: NsSearchResponse | null = safeJson<NsSearchResponse>(text);
  if (json === null || json.result === undefined || json.result.songs === undefined) {
    return [];
  }
  const songs: NsSong[] = json.result.songs;
  const out: LyricSongCandidate[] = [];
  for (let i = 0; i < songs.length; i++) {
    const s: NsSong = songs[i];
    if (s.id === undefined || !s.name) {
      continue;
    }
    let artist: string = '';
    if (s.artists !== undefined && s.artists.length > 0) {
      const names: string[] = [];
      for (let k = 0; k < s.artists.length; k++) {
        const n: string | undefined = s.artists[k].name;
        if (n !== undefined && n.length > 0) {
          names.push(n);
        }
      }
      artist = names.join(' / ');
    }
    const cand: LyricSongCandidate = {
      source: SOURCE_NETEASE,
      remoteId: String(s.id),
      title: s.name,
      artist: artist,
      album: s.album !== undefined && s.album.name !== undefined ? s.album.name : '',
      // 网易云搜索接口的 duration 是毫秒
      duration: s.duration === undefined ? 0 : Math.round(s.duration / 1000)
    };
    out.push(cand);
  }
  return out;
}

export async function neteaseLyric(remoteId: string): Promise<RawLyricData | null> {
  const url: string = `https://music.163.com/api/song/lyric/v1?id=${encodeURIComponent(remoteId)}`
    + '&lv=-1&tv=-1&rv=-1&yv=-1&ytv=-1&yrv=-1';
  const options: HttpRequestOptions = thirdPartyOptions('https://music.163.com/', {
    'User-Agent': UA_NETEASE_PC
  });
  const text: string = await HttpUtil.requestText(url, options);
  const json: NsLyricResponse | null = safeJson<NsLyricResponse>(text);
  if (json === null) {
    return null;
  }
  const rawLrc: string = json.lrc !== undefined && json.lrc.lyric !== undefined ? json.lrc.lyric : '';
  if (rawLrc.length === 0) {
    return null;
  }
  // `yv=-1` 时 lrc 可能是 YRC（逐字 / JSON 行），转成 SPL；普通 LRC 原样交给解析层
  const isYrc: boolean = rawLrc.indexOf('{"t":') >= 0 || new RegExp('^\\[\\d+,\\d+\\]', 'm').test(rawLrc);
  const lrc: string = isYrc ? yrcToSpl(rawLrc) : rawLrc;
  const data: RawLyricData = {
    lrc: lrc,
    tlyric: json.tlyric !== undefined && json.tlyric.lyric !== undefined ? json.tlyric.lyric : '',
    romalrc: json.romalrc !== undefined && json.romalrc.lyric !== undefined ? json.romalrc.lyric : '',
    dynamic: isYrc
  };
  return data;
}

// ───────────────────────────── QQ 音乐 ─────────────────────────────

interface QqSinger {
  name?: string;
}

interface QqAlbum {
  name?: string;
}

interface QqSong {
  mid?: string;
  name?: string;
  /** 秒 */
  interval?: number;
  singer?: QqSinger[];
  album?: QqAlbum;
}

interface QqSongList {
  list?: QqSong[];
}

interface QqBody {
  song?: QqSongList;
}

interface QqReqData {
  body?: QqBody;
}

interface QqReq {
  data?: QqReqData;
}

interface QqSearchResponse {
  code?: number;
  req?: QqReq;
}

interface QqLyricResponse {
  code?: number;
  retcode?: number;
  lyric?: string;
  trans?: string;
}

export async function qqSearch(keyword: string, limit: number): Promise<LyricSongCandidate[]> {
  const bodyObj: string = JSON.stringify({
    comm: { ct: '19', cv: '1859', uin: '0' },
    req: {
      method: 'DoSearchForQQMusicDesktop',
      module: 'music.search.SearchCgiService',
      param: {
        grp: 1,
        num_per_page: limit,
        page_num: 1,
        query: keyword,
        search_type: 0
      }
    }
  });
  const options: HttpRequestOptions = thirdPartyOptions('https://y.qq.com/', {
    'Content-Type': 'application/json;charset=utf-8'
  });
  options.method = http.RequestMethod.POST;
  options.body = bodyObj;
  const text: string = await HttpUtil.requestText('https://u.y.qq.com/cgi-bin/musicu.fcg', options);
  const json: QqSearchResponse | null = safeJson<QqSearchResponse>(text);
  if (json === null || json.req === undefined || json.req.data === undefined
    || json.req.data.body === undefined || json.req.data.body.song === undefined
    || json.req.data.body.song.list === undefined) {
    return [];
  }
  const songs: QqSong[] = json.req.data.body.song.list;
  const out: LyricSongCandidate[] = [];
  for (let i = 0; i < songs.length; i++) {
    const s: QqSong = songs[i];
    if (!s.mid || !s.name) {
      continue;
    }
    let artist: string = '';
    if (s.singer !== undefined && s.singer.length > 0 && s.singer[0].name !== undefined) {
      artist = s.singer[0].name;
    }
    const cand: LyricSongCandidate = {
      source: SOURCE_QQ,
      remoteId: s.mid,
      title: s.name,
      artist: artist,
      album: s.album !== undefined && s.album.name !== undefined ? s.album.name : '',
      duration: s.interval === undefined ? 0 : s.interval
    };
    out.push(cand);
  }
  return out;
}

export async function qqLyric(remoteId: string): Promise<RawLyricData | null> {
  const url: string = `https://i.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=${encodeURIComponent(remoteId)}`
    + '&g_tk=5381&format=json&inCharset=utf8&outCharset=utf-8&nobase64=1';
  const options: HttpRequestOptions = thirdPartyOptions('https://y.qq.com/');
  const text: string = await HttpUtil.requestText(url, options);
  const json: QqLyricResponse | null = safeJson<QqLyricResponse>(text);
  if (json === null) {
    return null;
  }
  const lrc: string = json.lyric !== undefined ? json.lyric : '';
  if (lrc.length === 0) {
    return null;
  }
  const data: RawLyricData = {
    lrc: lrc,
    tlyric: json.trans !== undefined ? json.trans : '',
    romalrc: '',
    dynamic: false
  };
  return data;
}

// ───────────────────────────── OIAPI（兜底） ─────────────────────────────

interface OiapiSong {
  name?: string;
  singer?: string[];
  album?: string;
  mid?: string;
  id?: number;
  duration?: number;
}

interface OiapiSearchResponse {
  code?: number;
  data?: OiapiSong[];
}

interface OiapiLyricPayload {
  content?: string;
  conteng?: string;
}

interface OiapiLyricResponse {
  code?: number;
  data?: OiapiLyricPayload;
}

export async function oiapiSearch(keyword: string, limit: number): Promise<LyricSongCandidate[]> {
  const url: string = `${OIAPI_QQ_LYRIC}?keyword=${encodeURIComponent(keyword)}&page=1&limit=${limit}&type=json`;
  const options: HttpRequestOptions = thirdPartyOptions('https://www.oiapi.net/');
  const text: string = await HttpUtil.requestText(url, options);
  const json: OiapiSearchResponse | null = safeJson<OiapiSearchResponse>(text);
  if (json === null || json.data === undefined || !Array.isArray(json.data)) {
    return [];
  }
  const out: LyricSongCandidate[] = [];
  for (let i = 0; i < json.data.length; i++) {
    const s: OiapiSong = json.data[i];
    if (!s.name || s.id === undefined) {
      continue;
    }
    const cand: LyricSongCandidate = {
      source: SOURCE_OIAPI,
      remoteId: String(s.id),
      title: s.name,
      artist: Array.isArray(s.singer) ? s.singer.join(' / ') : '',
      album: s.album !== undefined ? s.album : '',
      duration: s.duration === undefined ? 0 : Number(s.duration)
    };
    out.push(cand);
  }
  return out;
}

export async function oiapiLyric(remoteId: string): Promise<RawLyricData | null> {
  const url: string = `${OIAPI_QQ_LYRIC}?id=${encodeURIComponent(remoteId)}&format=lrc&type=json`;
  const options: HttpRequestOptions = thirdPartyOptions('https://www.oiapi.net/');
  const text: string = await HttpUtil.requestText(url, options);
  const json: OiapiLyricResponse | null = safeJson<OiapiLyricResponse>(text);
  if (json === null || json.data === undefined) {
    return null;
  }
  const lrc: string = json.data.content !== undefined && json.data.content.length > 0
    ? json.data.content
    : (json.data.conteng !== undefined ? json.data.conteng : '');
  if (lrc.length === 0) {
    return null;
  }
  const data: RawLyricData = {
    lrc: lrc,
    tlyric: '',
    romalrc: '',
    dynamic: false
  };
  return data;
}

// ───────────────────────────── 统一入口 ─────────────────────────────

/**
 * 统一搜索入口。
 * 单源失败不抛错（返回空数组），由上层决定「全空 = 没找到」。
 */
export async function searchSource(source: string, keyword: string, limit: number): Promise<LyricSongCandidate[]> {
  if (source === SOURCE_NETEASE) {
    return neteaseSearch(keyword, limit);
  }
  if (source === SOURCE_QQ) {
    return qqSearch(keyword, limit);
  }
  if (source === SOURCE_OIAPI) {
    return oiapiSearch(keyword, limit);
  }
  return [];
}

/** 统一取歌词入口 */
export async function fetchLyricBySource(source: string, remoteId: string): Promise<RawLyricData | null> {
  if (source === SOURCE_NETEASE) {
    return neteaseLyric(remoteId);
  }
  if (source === SOURCE_QQ) {
    return qqLyric(remoteId);
  }
  if (source === SOURCE_OIAPI) {
    return oiapiLyric(remoteId);
  }
  return null;
}
