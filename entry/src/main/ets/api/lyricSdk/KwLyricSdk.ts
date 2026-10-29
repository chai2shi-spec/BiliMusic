/**
 * 酷我歌词源（kw）。
 *
 * 移植自 lx-music-mobile `src/utils/musicSdk/kw/{musicSearch.js,lyric.js,util.js}`：
 *   1. 搜索 `http://search.kuwo.cn/r.s?client=kt&...&rformat=json`（JSON 响应，
 *      MUSICRID 去 `MUSIC_` 前缀为 rid，DURATION 秒）；
 *   2. 歌词 `http://mlyric.kuwo.cn/mobi.s?f=web&type=lyric&lrcx=1&rid=` ——
 *      **二进制响应**（gzip 的 tp=content 数据），此处用独立 http 请求拉
 *      ARRAY_BUFFER（共享 HttpUtil 只出文本，不动它）；
 *   3. decodeKwLyric（tp=content 校验 → inflate → Base64 + `yeelion` XOR）
 *      → parseKwLrc（重复时间戳分离主/译轨 + 30% 启发式）
 *      → lrcTools.parse（kuwo `<a,b,c>` 逐字 → LX `<start,dur>`，`[kuwo:八进制]`
 *      头给偏移系数）→ 行内 wordTime 标签剥离。
 */

import http from '@ohos.net.http';
import { HttpUtil } from '../../utils/HttpUtil';
import { decodeHtmlEntities } from '../../utils/TextUtil';
import { emptyLxLyricInfo, LxLyricFetchInput, LxLyricInfo, LxSongCandidate, SOURCE_KW } from './LxLyricTypes';
import { safeJson, thirdPartyOptions, UA_DESKTOP } from './utils/LxHttpUtil';
import { decodeKwLyric } from './utils/KwDecoder';

// ───────────────────────────── 响应模型 ─────────────────────────────

interface KwSearchItem {
  MUSICRID?: string;
  SONGNAME?: string;
  ARTIST?: string;
  ALBUM?: string;
  ALBUMID?: string;
  /** 秒 */
  DURATION?: string;
}

interface KwSearchResponse {
  abslist?: KwSearchItem[];
}

// ───────────────────────────── lrcTools（照抄 lx kw/util.js） ─────────────────────────────

const RX_WORD_LINE: RegExp = /^(\[\d{1,2}:.*\d{1,4}\])\s*(\S+(?:\s+\S+)*)?\s*/;
const RX_TAG_LINE: RegExp = /\[(ver|ti|ar|al|offset|by|kuwo):\s*(\S+(?:\s+\S+)*)\s*\]/;
const RX_WORD_TIME_ALL: RegExp = /<(-?\d+),(-?\d+)(?:,-?\d+)?>/g;
const RX_WORD_TIME: RegExp = /<(-?\d+),(-?\d+)(?:,-?\d+)?>/;
const RX_EXIST_TIME: RegExp = /\[\d{1,2}:.*\d{1,4}]/;
const RX_LYRICX_TAG: RegExp = /^<-?\d+,-?\d+>/;

interface KwWordInfo {
  startTime: number;
  endTime: number;
  timeStr: string;
  newTimeStr: string;
}

/** kuwo lrcx 逐字转换器（每次 parse 用独立实例，避免共享状态） */
class KwLrcTool {
  offset: number = 1;
  offset2: number = 1;
  isOk: boolean = true;
  lines: string[] = [];
  tags: string[] = [];

  getWordInfo(str: string, str2: string, prevWord: KwWordInfo | null): KwWordInfo {
    const a: number = parseInt(str, 10);
    const b: number = parseInt(str2, 10);
    const startTime: number = Math.trunc(Math.abs((a + b) / (this.offset * 2)));
    const endTime: number = Math.trunc(Math.abs((a - b) / (this.offset2 * 2)) + startTime);
    if (prevWord !== null && startTime < prevWord.endTime) {
      prevWord.endTime = startTime;
      if (prevWord.startTime > prevWord.endTime) {
        prevWord.startTime = prevWord.endTime;
      }
      prevWord.newTimeStr = `<${prevWord.startTime},${Math.trunc(prevWord.endTime - prevWord.startTime)}>`;
    }
    const info: KwWordInfo = {
      startTime: startTime,
      endTime: endTime,
      timeStr: `<${startTime},${Math.trunc(endTime - startTime)}>`,
      newTimeStr: ''
    };
    return info;
  }

  parseLine(line: string): void {
    if (line.length < 6) {
      return;
    }
    let result: RegExpExecArray | null = RX_WORD_LINE.exec(line);
    if (result !== null) {
      const time: string = result[1];
      let words: string = result[2] === undefined || result[2] === null ? '' : result[2];
      const wordTimes: string[] | null = words.match(RX_WORD_TIME_ALL);
      if (wordTimes === null) {
        return;
      }
      let preTimeInfo: KwWordInfo | null = null;
      for (let i = 0; i < wordTimes.length; i++) {
        const timeStr: string = wordTimes[i];
        const m: RegExpExecArray | null = RX_WORD_TIME.exec(timeStr);
        if (m === null) {
          continue;
        }
        const wordInfo: KwWordInfo = this.getWordInfo(m[1], m[2], preTimeInfo);
        words = words.replace(timeStr, wordInfo.timeStr);
        if (preTimeInfo !== null && preTimeInfo.newTimeStr.length > 0) {
          words = words.replace(preTimeInfo.timeStr, preTimeInfo.newTimeStr);
        }
        preTimeInfo = wordInfo;
      }
      this.lines.push(time + words);
      return;
    }
    result = RX_TAG_LINE.exec(line);
    if (result === null) {
      return;
    }
    if (result[1] === 'kuwo') {
      let content: string = result[2] === undefined ? '' : result[2];
      if (content.length > 0 && content.indexOf('][') >= 0) {
        content = content.substring(0, content.indexOf(']['));
      }
      const valueOf: number = parseInt(content, 8);
      this.offset = Math.trunc(valueOf / 10);
      this.offset2 = Math.trunc(valueOf % 10);
      if (this.offset === 0 || Number.isNaN(this.offset) || this.offset2 === 0 || Number.isNaN(this.offset2)) {
        this.isOk = false;
      }
    } else {
      this.tags.push(line);
    }
  }

  parse(lrc: string): string {
    const lines: string[] = lrc.split(/\r\n|\r|\n/);
    this.offset = 1;
    this.offset2 = 1;
    this.isOk = true;
    this.lines = [];
    this.tags = [];
    for (let i = 0; i < lines.length; i++) {
      if (!this.isOk) {
        return '';
      }
      this.parseLine(lines[i]);
    }
    if (this.lines.length === 0) {
      return '';
    }
    let lrcs: string = this.lines.join('\n');
    if (this.tags.length > 0) {
      lrcs = `${this.tags.join('\n')}\n${lrcs}`;
    }
    return lrcs;
  }
}

// ───────────────────────────── parseLrc（照抄 lx kw/lyric.js） ─────────────────────────────

interface KwLrcItem {
  time: string;
  text: string;
}

interface KwSortedLrc {
  lrc: KwLrcItem[];
  lrcT: KwLrcItem[];
}

/**
 * 重复时间戳分离：同时间戳的第二条挪到翻译轨。
 * 照抄 lx `sortLrcArr`：非 lyricx 且翻译占比过高（>30% 且差 >6 行）时判定
 * 「大概率没有翻译，重复行其实是多行主歌词」→ 抛错（调用方按取词失败处理）。
 */
function sortLrcArr(arr: KwLrcItem[]): KwSortedLrc {
  const lrcSet: Set<string> = new Set<string>();
  const lrc: KwLrcItem[] = [];
  const lrcT: KwLrcItem[] = [];
  let isLyricx: boolean = false;
  for (let i = 0; i < arr.length; i++) {
    const item: KwLrcItem = arr[i];
    if (lrcSet.has(item.time)) {
      if (lrc.length < 2) {
        continue;
      }
      const tItem: KwLrcItem = lrc.length > 0 ? lrc[lrc.length - 1] : item;
      lrc.pop();
      if (lrc.length > 0) {
        tItem.time = lrc[lrc.length - 1].time;
      }
      lrcT.push(tItem);
      lrc.push(item);
    } else {
      lrc.push(item);
      lrcSet.add(item.time);
    }
    if (!isLyricx && RX_LYRICX_TAG.test(item.text)) {
      isLyricx = true;
    }
  }
  if (!isLyricx && lrcT.length > lrc.length * 0.3 && lrc.length - lrcT.length > 6) {
    throw new Error('kw lyric sort failed');
  }
  const out: KwSortedLrc = { lrc: lrc, lrcT: lrcT };
  return out;
}

function transformLrc(tags: string[], lrclist: KwLrcItem[]): string {
  let body: string = '';
  for (let i = 0; i < lrclist.length; i++) {
    body += `[${lrclist[i].time}]${lrclist[i].text}\n`;
  }
  return `${tags.join('\n')}\n${body}`;
}

interface KwParsedLrc {
  lyric: string;
  tlyric: string;
}

function parseKwLrc(lrc: string): KwParsedLrc {
  const lines: string[] = lrc.split(/\r\n|\r|\n/);
  const tags: string[] = [];
  const lrcArr: KwLrcItem[] = [];
  const timeExp: RegExp = /^\[([\d:.]*)\]/;
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    const result: RegExpExecArray | null = timeExp.exec(line);
    if (result !== null) {
      const text: string = line.replace(timeExp, '').trim();
      let time: string = result[1];
      if (/\.\d\d$/.test(time)) {
        time += '0';
      }
      const item: KwLrcItem = { time: time, text: text };
      lrcArr.push(item);
    } else if (RX_TAG_LINE.test(line)) {
      tags.push(line);
    }
  }
  const sorted: KwSortedLrc = sortLrcArr(lrcArr);
  const out: KwParsedLrc = {
    lyric: decodeHtmlEntities(transformLrc(tags, sorted.lrc)),
    tlyric: sorted.lrcT.length > 0 ? decodeHtmlEntities(transformLrc(tags, sorted.lrcT)) : ''
  };
  return out;
}

// ───────────────────────────── 二进制请求 ─────────────────────────────

/** 拉取二进制响应（酷我歌词专用；不带 B 站 Cookie / Referer） */
function fetchBuffer(url: string): Promise<Uint8Array | null> {
  return new Promise<Uint8Array | null>((resolve: (v: Uint8Array | null) => void): void => {
    const req: http.HttpRequest = http.createHttp();
    req.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': UA_DESKTOP
      },
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 8000,
      readTimeout: 8000
    })
      .then((resp: http.HttpResponse): void => {
        req.destroy();
        if (resp.responseCode !== 200 || !(resp.result instanceof ArrayBuffer)) {
          resolve(null);
          return;
        }
        resolve(new Uint8Array(resp.result));
      })
      .catch((): void => {
        req.destroy();
        resolve(null);
      });
  });
}

// ───────────────────────────── 搜索 ─────────────────────────────

export async function kwSearch(keyword: string, limit: number): Promise<LxSongCandidate[]> {
  const url: string = `http://search.kuwo.cn/r.s?client=kt&all=${encodeURIComponent(keyword)}`
    + `&pn=0&rn=${limit}&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1`
    + `&newver=1&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1`;
  const options = thirdPartyOptions('http://www.kuwo.cn/');
  const text: string = await HttpUtil.requestText(url, options);
  const json: KwSearchResponse | null = safeJson<KwSearchResponse>(text);
  if (json === null || json.abslist === undefined || !Array.isArray(json.abslist)) {
    return [];
  }
  const out: LxSongCandidate[] = [];
  for (let i = 0; i < json.abslist.length; i++) {
    const item: KwSearchItem = json.abslist[i];
    if (item.MUSICRID === undefined || item.MUSICRID.length === 0) {
      continue;
    }
    const rid: string = item.MUSICRID.replace('MUSIC_', '');
    if (rid.length === 0) {
      continue;
    }
    const duration: number = parseInt(item.DURATION === undefined ? '0' : item.DURATION, 10);
    const cand: LxSongCandidate = {
      source: SOURCE_KW,
      remoteId: rid,
      title: decodeHtmlEntities(item.SONGNAME === undefined ? '' : item.SONGNAME),
      artist: decodeHtmlEntities(item.ARTIST === undefined ? '' : item.ARTIST.replace(/&/g, '、')),
      album: decodeHtmlEntities(item.ALBUM === undefined ? '' : item.ALBUM),
      duration: Number.isNaN(duration) ? 0 : duration
    };
    out.push(cand);
  }
  return out;
}

// ───────────────────────────── 取歌词 ─────────────────────────────

export async function kwGetLyric(input: LxLyricFetchInput): Promise<LxLyricInfo | null> {
  const url: string = `http://mlyric.kuwo.cn/mobi.s?f=web&type=lyric&lrcx=1&rid=${input.remoteId}&encode=utf8`;
  const buf: Uint8Array | null = await fetchBuffer(url);
  if (buf === null) {
    return null;
  }
  const lrcText: string = decodeKwLyric(buf, true);
  if (lrcText.length === 0) {
    return null;
  }
  let parsed: KwParsedLrc;
  try {
    parsed = parseKwLrc(lrcText);
  } catch (e) {
    return null;
  }
  const info: LxLyricInfo = emptyLxLyricInfo();
  info.lyric = parsed.lyric;
  info.tlyric = parsed.tlyric;
  if (info.tlyric.length > 0) {
    info.tlyric = info.tlyric.replace(RX_WORD_TIME_ALL, '');
  }
  const tool: KwLrcTool = new KwLrcTool();
  const lxlyric: string = tool.parse(info.lyric);
  info.lxlyric = lxlyric;
  info.lyric = info.lyric.replace(RX_WORD_TIME_ALL, '');
  if (!RX_EXIST_TIME.test(info.lyric)) {
    return null;
  }
  return info;
}
