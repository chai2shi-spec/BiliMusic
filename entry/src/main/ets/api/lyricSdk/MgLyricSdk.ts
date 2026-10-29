/**
 * 咪咕歌词源（mg）。
 *
 * 移植自 lx-music-mobile `src/utils/musicSdk/mg/{musicSearch.js,lyric.js,musicInfo.js,utils/mrc.js}`：
 *   1. 搜索 `https://jadeite.migu.cn/music_search/v3/search/searchAll`
 *      —— 签名走 header：sign = md5(keyword + '6cdc72a439cef99a3418d2a78aa28c73'
 *      + 'yyapp2d16148780a1dcc7408e06336b98cfd50' + deviceId + timestamp)，
 *      deviceId = '963B7AA0D21511ED807EE5846EC87D20'；
 *      响应 songResultData.resultList 为二维数组，duration 毫秒；
 *      remoteId = songId（resourceinfo.do 用 songId 查询，非 copyrightId）；
 *   2. 歌词 `https://c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?resourceType=2`
 *      POST form `resourceId=<songId>` → resource[0] 的
 *      mrcUrl（MRC 逐字，XXTEA 解密）/ trcUrl（翻译）/ lrcUrl（兜底 LRC）；
 *   3. MRC 解析（mrcTools.parseLyric）：行 `[start,dur]` + 字 `字(rel,dur)`
 *      → `[mm:ss.mmm]<rel-start,dur>字...`。
 */

import { HttpUtil, HttpRequestOptions } from '../../utils/HttpUtil';
import { md5 } from '../../utils/CryptoUtil';
import { decodeHtmlEntities } from '../../utils/TextUtil';
import { emptyLxLyricInfo, LxLyricFetchInput, LxLyricInfo, LxSongCandidate, SOURCE_MG } from './LxLyricTypes';
import { formPostOptions, safeJson, thirdPartyOptions } from './utils/LxHttpUtil';
import { decryptMrc } from './utils/MrcDecoder';

// ───────────────────────────── 常量 ─────────────────────────────

const SEARCH_SIGN_KEY: string = '6cdc72a439cef99a3418d2a78aa28c73';
const SEARCH_HEADER_KEY: string = 'yyapp2d16148780a1dcc7408e06336b98cfd50';
const DEVICE_ID: string = '963B7AA0D21511ED807EE5846EC87D20';
const RESOURCE_URL: string = 'https://c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?resourceType=2';
const TEXT_REFERER: string = 'https://app.c.nf.migu.cn/';
const CHANNEL: string = '0146921';
const SEARCH_UA: string = 'Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032)'
  + ' AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30';
const TEXT_UA: string = 'Mozilla/5.0 (Linux; Android 5.1.1; Nexus 6 Build/LYZ28E)'
  + ' AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Mobile Safari/537.36';

// ───────────────────────────── 响应模型 ─────────────────────────────

interface MgSinger {
  name?: string;
}

interface MgSearchSong {
  songId?: string;
  copyrightId?: string;
  name?: string;
  singerList?: MgSinger[];
  album?: string;
  albumId?: string;
  /** 毫秒 */
  duration?: number;
}

interface MgSearchResponse {
  code?: string;
  songResultData?: MgSongResultData;
}

interface MgSongResultData {
  resultList?: MgSearchSong[][];
  totalCount?: number;
}

interface MgResourceItem {
  songId?: string;
  songName?: string;
  copyrightId?: string;
  lrcUrl?: string;
  mrcUrl?: string;
  trcUrl?: string;
}

interface MgResourceResponse {
  code?: string;
  resource?: MgResourceItem[];
}

// ───────────────────────────── MRC 解析（照抄 lx mg/lyric.js mrcTools.parseLyric） ─────────────────────────────

const RX_MRC_LINE_TIME: RegExp = /^\s*\[(\d+),\d+\]/;
const RX_MRC_WORD: RegExp = /\((\d+),(\d+)\)/;
const RX_MRC_WORD_ALL: RegExp = /\(\d+,\d+\)/g;
const RX_MRC_WORD_SPLIT: RegExp = /\(\d+,\d+\)/;

function padNum(value: number, width: number): string {
  let s: string = `${Math.trunc(value)}`;
  while (s.length < width) {
    s = `0${s}`;
  }
  return s;
}

function formatMrcTime(ms: number): string {
  const totalSec: number = Math.floor(ms / 1000);
  const msPart: number = ms % 1000;
  const min: number = Math.floor(totalSec / 60);
  const sec: number = totalSec % 60;
  return `${padNum(min, 2)}:${padNum(sec, 2)}.${padNum(msPart, 3)}`;
}

function parseMrc(str: string): { lyric: string; lxlyric: string } {
  const text: string = str.replace(/\r/g, '');
  const lines: string[] = text.split('\n');
  const lrcLines: string[] = [];
  const lxLines: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i];
    if (line.length < 6) {
      continue;
    }
    const result: RegExpExecArray | null = RX_MRC_LINE_TIME.exec(line);
    if (result === null) {
      continue;
    }
    const startTime: number = parseInt(result[1], 10);
    const time: string = formatMrcTime(startTime);
    const words: string = line.replace(RX_MRC_LINE_TIME, '');
    lrcLines.push(`[${time}]${words.replace(RX_MRC_WORD_ALL, '')}`);
    const times: string[] | null = words.match(RX_MRC_WORD_ALL);
    if (times === null) {
      continue;
    }
    const wordArr: string[] = words.split(RX_MRC_WORD_SPLIT);
    let newWords: string = '';
    for (let j = 0; j < times.length; j++) {
      const m: RegExpExecArray | null = RX_MRC_WORD.exec(times[j]);
      if (m === null) {
        continue;
      }
      const rel: number = Math.trunc(parseInt(m[1], 10) - startTime);
      const tag: string = `<${rel},${m[2]}>`;
      const wordText: string = wordArr[j] === undefined ? '' : wordArr[j];
      newWords += `${tag}${wordText}`;
    }
    lxLines.push(`[${time}]${newWords}`);
  }
  const out: { lyric: string; lxlyric: string } = { lyric: '', lxlyric: '' };
  out.lyric = lrcLines.join('\n');
  out.lxlyric = lxLines.join('\n');
  return out;
}

// ───────────────────────────── 文本获取 ─────────────────────────────

async function getMiguText(url: string): Promise<string> {
  if (url.length === 0) {
    return '';
  }
  const options: HttpRequestOptions = thirdPartyOptions(TEXT_REFERER, {
    'channel': CHANNEL,
    'User-Agent': TEXT_UA
  });
  return HttpUtil.requestText(url, options);
}

// ───────────────────────────── 搜索 ─────────────────────────────

export async function mgSearch(keyword: string, limit: number): Promise<LxSongCandidate[]> {
  const timestamp: string = `${Date.now()}`;
  const sign: string = md5(`${keyword}${SEARCH_SIGN_KEY}${SEARCH_HEADER_KEY}${DEVICE_ID}${timestamp}`);
  const searchSwitch: string = JSON.stringify({
    song: 1, album: 0, singer: 0, tagSong: 1, mvSong: 0, bestShow: 1, songlist: 0, lyricSong: 0
  });
  const url: string = 'https://jadeite.migu.cn/music_search/v3/search/searchAll'
    + `?isCorrect=0&isCopyright=1&searchSwitch=${encodeURIComponent(searchSwitch)}`
    + `&pageSize=${limit}&text=${encodeURIComponent(keyword)}&pageNo=1&sort=0&sid=USS`;
  const options: HttpRequestOptions = thirdPartyOptions(TEXT_REFERER, {
    'uiVersion': 'A_music_3.6.1',
    'deviceId': DEVICE_ID,
    'timestamp': timestamp,
    'sign': sign,
    'channel': CHANNEL,
    'User-Agent': SEARCH_UA
  });
  const respText: string = await HttpUtil.requestText(url, options);
  const json: MgSearchResponse | null = safeJson<MgSearchResponse>(respText);
  if (json === null || json.code !== '000000'
    || json.songResultData === undefined || json.songResultData.resultList === undefined) {
    return [];
  }
  const flat: MgSearchSong[] = [];
  for (let i = 0; i < json.songResultData.resultList.length; i++) {
    const inner: MgSearchSong[] = json.songResultData.resultList[i];
    if (Array.isArray(inner)) {
      for (let j = 0; j < inner.length; j++) {
        flat.push(inner[j]);
      }
    }
  }
  const out: LxSongCandidate[] = [];
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < flat.length; i++) {
    const item: MgSearchSong = flat[i];
    const songId: string = item.songId === undefined || item.songId === null ? '' : `${item.songId}`;
    const copyrightId: string = item.copyrightId === undefined || item.copyrightId === null ? '' : `${item.copyrightId}`;
    if (songId.length === 0 || copyrightId.length === 0 || seen.has(copyrightId)) {
      continue;
    }
    seen.add(copyrightId);
    const singerParts: string[] = [];
    if (item.singerList !== undefined && Array.isArray(item.singerList)) {
      for (let j = 0; j < item.singerList.length; j++) {
        const singer: MgSinger = item.singerList[j];
        const name: string = singer === undefined || singer.name === undefined || singer.name === null ? '' : `${singer.name}`;
        if (name.length > 0) {
          singerParts.push(name);
        }
      }
    }
    const durationMs: number = item.duration === undefined || item.duration === null ? 0 : Number(item.duration);
    const cand: LxSongCandidate = {
      source: SOURCE_MG,
      remoteId: songId,
      title: decodeHtmlEntities(item.name === undefined || item.name === null ? '' : `${item.name}`),
      artist: decodeHtmlEntities(singerParts.join('、')),
      album: decodeHtmlEntities(item.album === undefined || item.album === null ? '' : `${item.album}`),
      duration: Number.isNaN(durationMs) ? 0 : Math.trunc(durationMs / 1000)
    };
    out.push(cand);
  }
  return out;
}

// ───────────────────────────── 取歌词 ─────────────────────────────

export async function mgGetLyric(input: LxLyricFetchInput): Promise<LxLyricInfo | null> {
  const postOptions = formPostOptions(RESOURCE_URL, `resourceId=${encodeURIComponent(input.remoteId)}`);
  const respText: string = await HttpUtil.requestText(RESOURCE_URL, postOptions);
  const json: MgResourceResponse | null = safeJson<MgResourceResponse>(respText);
  if (json === null || json.resource === undefined || !Array.isArray(json.resource) || json.resource.length === 0) {
    return null;
  }
  const item: MgResourceItem = json.resource[0];
  const mrcUrl: string = item.mrcUrl === undefined || item.mrcUrl === null ? '' : `${item.mrcUrl}`;
  const lrcUrl: string = item.lrcUrl === undefined || item.lrcUrl === null ? '' : `${item.lrcUrl}`;
  const trcUrl: string = item.trcUrl === undefined || item.trcUrl === null ? '' : `${item.trcUrl}`;
  if (mrcUrl.length === 0 && lrcUrl.length === 0) {
    return null;
  }
  const info: LxLyricInfo = emptyLxLyricInfo();
  if (mrcUrl.length > 0) {
    const mrcText: string = await getMiguText(mrcUrl);
    if (mrcText.length > 0) {
      const decrypted: string = decryptMrc(mrcText);
      if (decrypted.length > 0) {
        const parsed = parseMrc(decrypted);
        info.lxlyric = parsed.lxlyric;
        info.lyric = parsed.lyric;
      }
    }
  }
  if (info.lyric.length === 0 && lrcUrl.length > 0) {
    const lrcText: string = await getMiguText(lrcUrl);
    if (lrcText.length > 0) {
      info.lyric = lrcText;
    }
  }
  if (info.lyric.length === 0) {
    return null;
  }
  if (trcUrl.length > 0) {
    const trcText: string = await getMiguText(trcUrl);
    if (trcText.length > 0) {
      info.tlyric = trcText;
    }
  }
  return info;
}
