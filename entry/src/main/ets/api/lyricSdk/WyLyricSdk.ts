/**
 * 网易云歌词源（wy）。
 *
 * 移植自 lx-music-mobile `src/utils/musicSdk/wy/lyric.js` 的解析逻辑，
 * 但**不移植 eapi 加密通道** —— 项目一直用免加密端点：
 *   - 搜索 `GET https://music.163.com/api/search/get?s=&type=1&limit=&offset=0`
 *   - 歌词 `GET https://music.163.com/api/song/lyric/v1?id=&lv=-1&tv=-1&rv=-1&yv=-1&ytv=-1&yrv=-1`
 *     （响应含 lrc / tlyric / romalrc / yrc / ytlrc / yromalrc 六块）
 *
 * YRC 逐字解析、翻译/罗马音对齐（fixTimeTag ±100ms）、时间标签冒号修正
 * （fixTimeLabel）均照抄 lx，保证逐字轨与翻译轨的对齐行为一致。
 */

import { HttpUtil } from '../../utils/HttpUtil';
import { decodeHtmlEntities } from '../../utils/TextUtil';
import { emptyLxLyricInfo, LxLyricFetchInput, LxLyricInfo, LxSongCandidate, SOURCE_WY } from './LxLyricTypes';
import { safeJson, thirdPartyOptions } from './utils/LxHttpUtil';

// ───────────────────────────── 响应模型 ─────────────────────────────

interface WyArtist {
  name?: string;
}

interface WyAlbum {
  name?: string;
}

interface WySong {
  id?: number;
  name?: string;
  artists?: WyArtist[];
  album?: WyAlbum;
  /** 毫秒 */
  duration?: number;
}

interface WySearchBody {
  songs?: WySong[];
}

interface WySearchResponse {
  code?: number;
  result?: WySearchBody;
}

interface WyLyricBlock {
  lyric?: string;
}

interface WyLyricResponse {
  code?: number;
  lrc?: WyLyricBlock;
  tlyric?: WyLyricBlock;
  romalrc?: WyLyricBlock;
  yrc?: WyLyricBlock;
  ytlrc?: WyLyricBlock;
  yromalrc?: WyLyricBlock;
}

interface WyJsonLineToken {
  tx?: string;
}

interface WyJsonLine {
  t?: number;
  c?: WyJsonLineToken[];
}

// ───────────────────────────── 解析工具（照抄 lx） ─────────────────────────────

const RX_INFO: RegExp = /^{"/;
const RX_LINE_TIME: RegExp = /^\[(\d+),\d+\]/;
const RX_WORD_TIME: RegExp = /\(\d+,\d+,\d+\)/;
const RX_WORD_TIME_ALL: RegExp = /(\(\d+,\d+,\d+\))/g;
const RX_TIME_MS2: RegExp = /\[\d+:\d+\.\d{2}]/;
const RX_TIME_MS3: RegExp = /\[\d+:\d+\.\d{3}]/;

/** 数字补零到指定宽度 */
function padNum(value: number, width: number): string {
  let s: string = `${value}`;
  while (s.length < width) {
    s = `0${s}`;
  }
  return s;
}

/** 毫秒 → `[mm:ss.mmm]`；pad3=false 时毫秒只保留 2 位（对齐网易云 2 位时间标签） */
function msFormat(timeMs: number, pad3: boolean): string {
  if (Number.isNaN(timeMs)) {
    return '';
  }
  const ms: number = timeMs % 1000;
  let msStr: string = padNum(ms, pad3 ? 3 : 2);
  if (!pad3 && msStr.length > 2) {
    msStr = msStr.substring(0, 2);
  }
  const totalSec: number = Math.trunc(timeMs / 1000);
  const m: number = Math.trunc(totalSec / 60);
  const s: number = totalSec % 60;
  return `[${padNum(m, 2)}:${padNum(s, 2)}.${msStr}]`;
}

/** YRC 逐字行 → { lyric: 行级 LRC, lxlyric: LX 逐字 } */
function parseYrcLines(lines: string[]): LyricAndLx {
  const lxlrcLines: string[] = [];
  const lrcLines: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    const result: RegExpExecArray | null = RX_LINE_TIME.exec(line);
    if (result === null) {
      if (line.startsWith('[offset')) {
        lxlrcLines.push(line);
        lrcLines.push(line);
      }
      continue;
    }
    const startMsTime: number = parseInt(result[1], 10);
    const startTimeStr: string = msFormat(startMsTime, true);
    if (startTimeStr.length === 0) {
      continue;
    }
    const words: string = line.replace(RX_LINE_TIME, '');
    lrcLines.push(`${startTimeStr}${words.replace(RX_WORD_TIME_ALL, '')}`);

    const times: string[] | null = words.match(RX_WORD_TIME_ALL);
    if (times === null) {
      continue;
    }
    const newTimes: string[] = [];
    const wordArr: string[] = words.split(RX_WORD_TIME);
    wordArr.shift();
    for (let k = 0; k < times.length; k++) {
      const m: RegExpExecArray | null = /\((\d+),(\d+),\d+\)/.exec(times[k]);
      if (m === null) {
        newTimes.push('');
        continue;
      }
      const rel: number = Math.max(parseInt(m[1], 10) - startMsTime, 0);
      newTimes.push(`<${rel},${m[2]}>`);
    }
    let newWords: string = '';
    for (let k = 0; k < newTimes.length; k++) {
      newWords += `${newTimes[k]}${wordArr[k] === undefined ? '' : wordArr[k]}`;
    }
    lxlrcLines.push(`${startTimeStr}${newWords}`);
  }
  const out: LyricAndLx = {
    lyric: lrcLines.join('\n'),
    lxlyric: lxlrcLines.join('\n')
  };
  return out;
}

interface LyricAndLx {
  lyric: string;
  lxlyric: string;
}

/**
 * 头信息解析：支持普通 LRC 行与网易云 JSON 行（`{"t":ms,"c":[{"tx":".."}]}`）。
 * 空串返回 null。
 */
function parseHeaderInfo(str: string): string[] | null {
  const trimmed: string = str.trim().replace(/\r/g, '');
  if (trimmed.length === 0) {
    return null;
  }
  const isPad3: boolean = RX_TIME_MS3.test(trimmed) || !RX_TIME_MS2.test(trimmed);
  const lines: string[] = trimmed.split('\n');
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i];
    if (!RX_INFO.test(line)) {
      out.push(line);
      continue;
    }
    let parsed: WyJsonLine | null = null;
    try {
      parsed = JSON.parse(line) as WyJsonLine;
    } catch (e) {
      parsed = null;
    }
    if (parsed === null || parsed.t === undefined || parsed.c === undefined) {
      out.push('');
      continue;
    }
    const timeTag: string = msFormat(parsed.t, isPad3);
    if (timeTag.length === 0) {
      out.push('');
      continue;
    }
    let text: string = '';
    for (let k = 0; k < parsed.c.length; k++) {
      text += parsed.c[k].tx === undefined ? '' : parsed.c[k].tx;
    }
    out.push(`${timeTag}${text}`);
  }
  return out;
}

/** `mm:ss.xx` / `mm:ss` → 毫秒（照抄 lx 系数，仅用于 ±100ms 邻近比较） */
function getIntv(interval: string): number {
  if (!interval || interval.length === 0) {
    return 0;
  }
  let timeStr: string = interval;
  if (timeStr.indexOf('.') < 0) {
    timeStr += '.0';
  }
  const arr: string[] = timeStr.split(/:|\./);
  while (arr.length < 3) {
    arr.unshift('0');
  }
  const m: number = parseInt(arr[0], 10);
  const s: number = parseInt(arr[1], 10);
  const ms: number = parseInt(arr[2], 10);
  if (Number.isNaN(m) || Number.isNaN(s) || Number.isNaN(ms)) {
    return 0;
  }
  return m * 3600000 + s * 1000 + ms;
}

/**
 * 把副轨（翻译/罗马音）的时间标签对齐到主轨（±100ms 内就近替换）。
 * 照抄 lx `fixTimeTag`：主轨行被顺序消费，未匹配行回填重试。
 */
function fixTimeTag(lrc: string, targetlrc: string): string {
  let lrcLines: string[] = lrc.split('\n');
  const targetlrcLines: string[] = targetlrc.split('\n');
  const timeRxp: RegExp = /^\[([\d:.]+)\]/;
  const temp: string[] = [];
  const newLrc: string[] = [];
  for (let i = 0; i < targetlrcLines.length; i++) {
    const line: string = targetlrcLines[i];
    const result: RegExpExecArray | null = timeRxp.exec(line);
    if (result === null) {
      continue;
    }
    const words: string = line.replace(timeRxp, '');
    if (words.trim().length === 0) {
      continue;
    }
    const t1: number = getIntv(result[1]);
    while (lrcLines.length > 0) {
      const lrcLine: string = lrcLines.shift() ?? '';
      const lrcLineResult: RegExpExecArray | null = timeRxp.exec(lrcLine);
      if (lrcLineResult === null) {
        continue;
      }
      const t2: number = getIntv(lrcLineResult[1]);
      if (Math.abs(t1 - t2) < 100) {
        const fixed: string = line.replace(timeRxp, lrcLineResult[0]).trim();
        if (fixed.length === 0) {
          continue;
        }
        newLrc.push(fixed);
        break;
      }
      temp.push(lrcLine);
    }
    lrcLines = temp.concat(lrcLines);
    temp.length = 0;
  }
  return newLrc.join('\n');
}

interface FixedTimeLabel {
  lrc: string;
  tlrc: string;
  romalrc: string;
}

/** 网易云历史时间标签修正：`[mm:ss:xx]` → `[mm:ss.xx]`（lx issue #370） */
function fixTimeLabel(lrc: string, tlrc: string, romalrc: string): FixedTimeLabel {
  let outLrc: string = lrc;
  let outTlrc: string = tlrc;
  let outRoma: string = romalrc;
  if (lrc.length > 0) {
    const newLrc: string = lrc.replace(/\[(\d{2}:\d{2}):(\d{2})]/g, '[$1.$2]');
    const newTlrc: string = tlrc.length > 0 ? tlrc.replace(/\[(\d{2}:\d{2}):(\d{2})]/g, '[$1.$2]') : tlrc;
    if (newLrc !== lrc || newTlrc !== tlrc) {
      outLrc = newLrc;
      outTlrc = newTlrc;
      if (romalrc.length > 0) {
        outRoma = romalrc
          .replace(/\[(\d{2}:\d{2}):(\d{2,3})]/g, '[$1.$2]')
          .replace(/\[(\d{2}:\d{2}\.\d{2})0]/g, '[$1]');
      }
    }
  }
  const out: FixedTimeLabel = {
    lrc: outLrc,
    tlrc: outTlrc,
    romalrc: outRoma
  };
  return out;
}

/** wy 六块 → LX 四字段（照抄 lx parseTools.parse） */
function parseWyLyric(
  ylrc: string,
  ytlrc: string,
  yrlrc: string,
  lrc: string,
  tlrc: string,
  rlrc: string
): LxLyricInfo {
  const info: LxLyricInfo = emptyLxLyricInfo();
  if (ylrc.length > 0) {
    const lines: string[] | null = parseHeaderInfo(ylrc);
    if (lines !== null) {
      const result: LyricAndLx = parseYrcLines(lines);
      if (ytlrc.length > 0) {
        const tlLines: string[] | null = parseHeaderInfo(ytlrc);
        if (tlLines !== null) {
          info.tlyric = fixTimeTag(result.lyric, tlLines.join('\n'));
        }
      }
      if (yrlrc.length > 0) {
        const rlLines: string[] | null = parseHeaderInfo(yrlrc);
        if (rlLines !== null) {
          info.rlyric = fixTimeTag(result.lyric, rlLines.join('\n'));
        }
      }
      const timeRxp: RegExp = /^\[[\d:.]+\]/;
      const headers: string[] = [];
      for (let i = 0; i < lines.length; i++) {
        if (timeRxp.test(lines[i])) {
          headers.push(lines[i]);
        }
      }
      info.lyric = `${headers.join('\n')}\n${result.lyric}`;
      info.lxlyric = result.lxlyric;
      return info;
    }
  }
  if (lrc.length > 0) {
    const lines: string[] | null = parseHeaderInfo(lrc);
    if (lines !== null) {
      info.lyric = lines.join('\n');
    }
  }
  if (tlrc.length > 0) {
    const lines: string[] | null = parseHeaderInfo(tlrc);
    if (lines !== null) {
      info.tlyric = lines.join('\n');
    }
  }
  if (rlrc.length > 0) {
    const lines: string[] | null = parseHeaderInfo(rlrc);
    if (lines !== null) {
      info.rlyric = lines.join('\n');
    }
  }
  return info;
}

// ───────────────────────────── 搜索 ─────────────────────────────

export async function wySearch(keyword: string, limit: number): Promise<LxSongCandidate[]> {
  const url: string = `https://music.163.com/api/search/get?s=${encodeURIComponent(keyword)}`
    + `&type=1&limit=${limit}&offset=0`;
  const options = thirdPartyOptions('https://music.163.com/');
  const text: string = await HttpUtil.requestText(url, options);
  const json: WySearchResponse | null = safeJson<WySearchResponse>(text);
  if (json === null || json.result === undefined || json.result.songs === undefined) {
    return [];
  }
  const songs: WySong[] = json.result.songs;
  const out: LxSongCandidate[] = [];
  for (let i = 0; i < songs.length; i++) {
    const s: WySong = songs[i];
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
    const cand: LxSongCandidate = {
      source: SOURCE_WY,
      remoteId: String(s.id),
      title: decodeHtmlEntities(s.name),
      artist: decodeHtmlEntities(artist),
      album: s.album !== undefined && s.album.name !== undefined ? decodeHtmlEntities(s.album.name) : '',
      // 网易云搜索接口的 duration 是毫秒
      duration: s.duration === undefined ? 0 : Math.round(s.duration / 1000)
    };
    out.push(cand);
  }
  return out;
}

// ───────────────────────────── 取歌词 ─────────────────────────────

export async function wyGetLyric(input: LxLyricFetchInput): Promise<LxLyricInfo | null> {
  const remoteId: string = input.remoteId;
  const url: string = `https://music.163.com/api/song/lyric/v1?id=${encodeURIComponent(remoteId)}`
    + '&lv=-1&tv=-1&rv=-1&yv=-1&ytv=-1&yrv=-1';
  const options = thirdPartyOptions('https://music.163.com/');
  const text: string = await HttpUtil.requestText(url, options);
  const json: WyLyricResponse | null = safeJson<WyLyricResponse>(text);
  if (json === null) {
    return null;
  }
  const lrcMain: string = json.lrc !== undefined && json.lrc.lyric !== undefined ? json.lrc.lyric : '';
  const yrcLyric: string = json.yrc !== undefined && json.yrc.lyric !== undefined ? json.yrc.lyric : '';
  const ytlrc: string = json.ytlrc !== undefined && json.ytlrc.lyric !== undefined ? json.ytlrc.lyric : '';
  const yrlrc: string = json.yromalrc !== undefined && json.yromalrc.lyric !== undefined ? json.yromalrc.lyric : '';
  const tlrc: string = json.tlyric !== undefined && json.tlyric.lyric !== undefined ? json.tlyric.lyric : '';
  const rlrc: string = json.romalrc !== undefined && json.romalrc.lyric !== undefined ? json.romalrc.lyric : '';

  // 兼容旧链路观察到的形态：`yv=-1` 时 YRC 偶尔被塞进 lrc.lyric
  let ylrc: string = yrcLyric;
  let plainLrc: string = lrcMain;
  if (ylrc.length === 0 && lrcMain.length > 0) {
    const lrcIsYrc: boolean = lrcMain.indexOf('{"t":') >= 0 || new RegExp('^\\[\\d+,\\d+\\]', 'm').test(lrcMain);
    if (lrcIsYrc) {
      ylrc = lrcMain;
      plainLrc = '';
    }
  }

  const fixed: FixedTimeLabel = fixTimeLabel(plainLrc, tlrc, rlrc);
  const info: LxLyricInfo = parseWyLyric(ylrc, ytlrc, yrlrc, fixed.lrc, fixed.tlrc, fixed.romalrc);
  if (info.lyric.trim().length === 0 && info.lxlyric.trim().length === 0) {
    return null;
  }
  return info;
}
