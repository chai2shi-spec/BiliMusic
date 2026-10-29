/**
 * 腾讯（QQ 音乐）歌词源（tx）。
 *
 * 移植自 lx-music-mobile `src/utils/musicSdk/tx/{lyric.js,musicInfo.js}`：
 *   1. songmid → 数字 songId：musicu.fcg `music.pf_song_detail_svr.get_song_detail_yqq`
 *      （songmid 不能直接取 QRC，必须换 id；结果进程内缓存）；
 *   2. QRC 歌词：musicu.fcg `music.musichallSong.PlayLyricInfo.GetPlayLyricInfo`
 *      （param: qrc:1, roma:1, trans:1, songID）→ data.lyric/trans/roma 三段 hex；
 *   3. hex → 3DES(QRC_KEY) + inflate（utils/TxQrcDecoder）→ 文本
 *      → parseTools（剥 LyricContent XML 壳、逐字 `(s,d)` → LX `<s,d>`、
 *      翻译/罗马音 ±100ms 对齐）。
 *
 * 搜索沿用项目已验证的 `DoSearchForQQMusicDesktop` 通道。
 */

import { HttpUtil } from '../../utils/HttpUtil';
import { decodeHtmlEntities } from '../../utils/TextUtil';
import { emptyLxLyricInfo, LxLyricFetchInput, LxLyricInfo, LxSongCandidate, SOURCE_TX } from './LxLyricTypes';
import { jsonPostOptions, safeJson } from './utils/LxHttpUtil';
import { decodeQrc } from './utils/TxQrcDecoder';

// ───────────────────────────── 响应模型 ─────────────────────────────

interface TxSinger {
  name?: string;
}

interface TxAlbum {
  name?: string;
}

interface TxSong {
  mid?: string;
  name?: string;
  /** 秒 */
  interval?: number;
  singer?: TxSinger[];
  album?: TxAlbum;
}

interface TxSongList {
  list?: TxSong[];
}

interface TxBody {
  song?: TxSongList;
}

interface TxReqData {
  body?: TxBody;
}

interface TxSearchReq {
  data?: TxReqData;
}

interface TxSearchResponse {
  code?: number;
  req?: TxSearchReq;
}

interface TxTrackInfo {
  id?: number;
}

interface TxDetailData {
  track_info?: TxTrackInfo;
}

interface TxDetailReq {
  code?: number;
  data?: TxDetailData;
}

interface TxDetailResponse {
  code?: number;
  req?: TxDetailReq;
}

interface TxPlayLyricData {
  lyric?: string;
  trans?: string;
  roma?: string;
}

interface TxPlayLyricReq {
  code?: number;
  data?: TxPlayLyricData;
}

interface TxPlayLyricResponse {
  code?: number;
  req?: TxPlayLyricReq;
}

// ───────────────────────────── parseTools（照抄 lx） ─────────────────────────────

const RX_LINE_TIME: RegExp = /^\[(\d+),\d+\]/;
const RX_LINE_TIME2: RegExp = /^\[([\d:.]+)\]/;
const RX_WORD_TIME: RegExp = /\(\d+,\d+\)/;
const RX_WORD_TIME_ALL: RegExp = /(\(\d+,\d+\))/g;

function padNum(value: number, width: number): string {
  let s: string = `${value}`;
  while (s.length < width) {
    s = `0${s}`;
  }
  return s;
}

function msFormat(timeMs: number): string {
  if (Number.isNaN(timeMs)) {
    return '';
  }
  const ms: number = timeMs % 1000;
  const totalSec: number = Math.trunc(timeMs / 1000);
  const m: number = Math.trunc(totalSec / 60);
  const s: number = totalSec % 60;
  return `[${padNum(m, 2)}:${padNum(s, 2)}.${padNum(ms, 3)}]`;
}

/** 剥 QRC 的 `<?xml .. LyricContent="..."?>` 包装 */
function removeTag(str: string): string {
  return str.replace(/^[\S\s]*?LyricContent="/, '').replace(/"\/>[\S\s]*?$/, '');
}

interface LyricAndLx {
  lyric: string;
  lxlyric: string;
}

/** QRC 主歌词 → { lyric, lxlyric } */
function parseQrcLyric(lrc: string): LyricAndLx {
  const trimmed: string = lrc.trim().replace(/\r/g, '');
  if (trimmed.length === 0) {
    const empty: LyricAndLx = { lyric: '', lxlyric: '' };
    return empty;
  }
  const lines: string[] = trimmed.split('\n');
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
      if (RX_LINE_TIME2.test(line)) {
        lrcLines.push(line);
      }
      continue;
    }
    const startMsTime: number = parseInt(result[1], 10);
    const startTimeStr: string = msFormat(startMsTime);
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
    for (let k = 0; k < times.length; k++) {
      const m: RegExpExecArray | null = /\((\d+),(\d+)\)/.exec(times[k]);
      if (m === null) {
        newTimes.push('');
        continue;
      }
      newTimes.push(`<${Math.max(parseInt(m[1], 10) - startMsTime, 0)},${m[2]}>`);
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

/** QRC 罗马音 → 行级 LRC（剥逐字标签） */
function parseQrcRlyric(lrc: string): string {
  const trimmed: string = lrc.trim().replace(/\r/g, '');
  if (trimmed.length === 0) {
    return '';
  }
  const lines: string[] = trimmed.split('\n');
  const lrcLines: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    const result: RegExpExecArray | null = RX_LINE_TIME.exec(line);
    if (result === null) {
      continue;
    }
    const startMsTime: number = parseInt(result[1], 10);
    const startTimeStr: string = msFormat(startMsTime);
    if (startTimeStr.length === 0) {
      continue;
    }
    const words: string = line.replace(RX_LINE_TIME, '');
    lrcLines.push(`${startTimeStr}${words.replace(RX_WORD_TIME_ALL, '')}`);
  }
  return lrcLines.join('\n');
}

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

/** 罗马音时间标签对齐主轨（照抄 lx：主轨行顺序消费，不回填） */
function fixRlrcTimeTag(rlrc: string, lrc: string): string {
  const rlrcLines: string[] = rlrc.split('\n');
  const lrcLines: string[] = lrc.split('\n');
  const newLrc: string[] = [];
  for (let i = 0; i < rlrcLines.length; i++) {
    const line: string = rlrcLines[i];
    const result: RegExpExecArray | null = RX_LINE_TIME2.exec(line);
    if (result === null) {
      continue;
    }
    const words: string = line.replace(RX_LINE_TIME2, '');
    if (words.trim().length === 0) {
      continue;
    }
    const t1: number = getIntv(result[1]);
    while (lrcLines.length > 0) {
      const lrcLine: string = lrcLines.shift() ?? '';
      const lrcLineResult: RegExpExecArray | null = RX_LINE_TIME2.exec(lrcLine);
      if (lrcLineResult === null) {
        continue;
      }
      const t2: number = getIntv(lrcLineResult[1]);
      if (Math.abs(t1 - t2) < 100) {
        newLrc.push(line.replace(RX_LINE_TIME2, lrcLineResult[0]));
        break;
      }
    }
  }
  return newLrc.join('\n');
}

/** 翻译时间标签对齐主轨（照抄 lx：毫秒位补齐到 3 位后再比较） */
function fixTlrcTimeTag(tlrc: string, lrc: string): string {
  const tlrcLines: string[] = tlrc.split('\n');
  const lrcLines: string[] = lrc.split('\n');
  const newLrc: string[] = [];
  for (let i = 0; i < tlrcLines.length; i++) {
    const line: string = tlrcLines[i];
    const result: RegExpExecArray | null = RX_LINE_TIME2.exec(line);
    if (result === null) {
      continue;
    }
    const words: string = line.replace(RX_LINE_TIME2, '');
    if (words.trim().length === 0) {
      continue;
    }
    let time: string = result[1];
    const dotIdx: number = time.indexOf('.');
    if (dotIdx >= 0) {
      const frac: string = time.substring(dotIdx + 1);
      if (frac.length < 3) {
        let pad: string = '';
        for (let k = 0; k < 3 - frac.length; k++) {
          pad += '0';
        }
        time += pad;
      }
    }
    const t1: number = getIntv(time);
    while (lrcLines.length > 0) {
      const lrcLine: string = lrcLines.shift() ?? '';
      const lrcLineResult: RegExpExecArray | null = RX_LINE_TIME2.exec(lrcLine);
      if (lrcLineResult === null) {
        continue;
      }
      const t2: number = getIntv(lrcLineResult[1]);
      if (Math.abs(t1 - t2) < 100) {
        newLrc.push(line.replace(RX_LINE_TIME2, lrcLineResult[0]));
        break;
      }
    }
  }
  return newLrc.join('\n');
}

/** tx 三段 → LX 四字段（照抄 lx parseTools.parse） */
function parseTxLyric(lrc: string, tlrc: string, rlrc: string): LxLyricInfo {
  const info: LxLyricInfo = emptyLxLyricInfo();
  if (lrc.length > 0) {
    const parsed: LyricAndLx = parseQrcLyric(removeTag(lrc));
    info.lyric = parsed.lyric;
    info.lxlyric = parsed.lxlyric;
  }
  if (rlrc.length > 0) {
    info.rlyric = fixRlrcTimeTag(parseQrcRlyric(removeTag(rlrc)), info.lyric);
  }
  if (tlrc.length > 0) {
    info.tlyric = fixTlrcTimeTag(tlrc, info.lyric);
  }
  return info;
}

// ───────────────────────────── songmid → songId ─────────────────────────────

const songIdMap: Map<string, string> = new Map<string, string>();

async function getSongId(songmid: string): Promise<string | null> {
  const cached: string | undefined = songIdMap.get(songmid);
  if (cached !== undefined) {
    return cached;
  }
  const bodyJson: string = JSON.stringify({
    comm: { ct: '19', cv: '1859', uin: '0' },
    req: {
      module: 'music.pf_song_detail_svr',
      method: 'get_song_detail_yqq',
      param: {
        song_type: 0,
        song_mid: songmid
      }
    }
  });
  const options = jsonPostOptions('https://y.qq.com/', bodyJson);
  const text: string = await HttpUtil.requestText('https://u.y.qq.com/cgi-bin/musicu.fcg', options);
  const json: TxDetailResponse | null = safeJson<TxDetailResponse>(text);
  if (json === null || json.code !== 0 || json.req === undefined || json.req.code !== 0
    || json.req.data === undefined || json.req.data.track_info === undefined
    || json.req.data.track_info.id === undefined) {
    return null;
  }
  const songId: string = String(json.req.data.track_info.id);
  songIdMap.set(songmid, songId);
  return songId;
}

// ───────────────────────────── 搜索 ─────────────────────────────

export async function txSearch(keyword: string, limit: number): Promise<LxSongCandidate[]> {
  const bodyJson: string = JSON.stringify({
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
  const options = jsonPostOptions('https://y.qq.com/', bodyJson);
  const text: string = await HttpUtil.requestText('https://u.y.qq.com/cgi-bin/musicu.fcg', options);
  const json: TxSearchResponse | null = safeJson<TxSearchResponse>(text);
  if (json === null || json.req === undefined || json.req.data === undefined
    || json.req.data.body === undefined || json.req.data.body.song === undefined
    || json.req.data.body.song.list === undefined) {
    return [];
  }
  const songs: TxSong[] = json.req.data.body.song.list;
  const out: LxSongCandidate[] = [];
  for (let i = 0; i < songs.length; i++) {
    const s: TxSong = songs[i];
    if (!s.mid || !s.name) {
      continue;
    }
    const names: string[] = [];
    if (s.singer !== undefined) {
      for (let k = 0; k < s.singer.length; k++) {
        const n: string | undefined = s.singer[k].name;
        if (n !== undefined && n.length > 0) {
          names.push(n);
        }
      }
    }
    const cand: LxSongCandidate = {
      source: SOURCE_TX,
      remoteId: s.mid,
      title: decodeHtmlEntities(s.name),
      artist: decodeHtmlEntities(names.join(' / ')),
      album: s.album !== undefined && s.album.name !== undefined ? decodeHtmlEntities(s.album.name) : '',
      duration: s.interval === undefined ? 0 : s.interval
    };
    out.push(cand);
  }
  return out;
}

// ───────────────────────────── 取歌词 ─────────────────────────────

async function requestPlayLyricInfo(songId: string): Promise<LxLyricInfo | null> {
  const bodyJson: string = JSON.stringify({
    comm: { ct: '19', cv: '1859', uin: '0' },
    req: {
      method: 'GetPlayLyricInfo',
      module: 'music.musichallSong.PlayLyricInfo',
      param: {
        format: 'json',
        crypt: 1,
        ct: 19,
        cv: 1873,
        interval: 0,
        lrc_t: 0,
        qrc: 1,
        qrc_t: 0,
        roma: 1,
        roma_t: 0,
        songID: songId,
        trans: 1,
        trans_t: 0,
        type: -1
      }
    }
  });
  const options = jsonPostOptions('https://y.qq.com/', bodyJson);
  const text: string = await HttpUtil.requestText('https://u.y.qq.com/cgi-bin/musicu.fcg', options);
  const json: TxPlayLyricResponse | null = safeJson<TxPlayLyricResponse>(text);
  if (json === null || json.code !== 0 || json.req === undefined || json.req.code !== 0
    || json.req.data === undefined) {
    return null;
  }
  const data: TxPlayLyricData = json.req.data;
  const lrc: string = decodeQrc(data.lyric === undefined ? '' : data.lyric);
  const tlrc: string = decodeQrc(data.trans === undefined ? '' : data.trans);
  const rlrc: string = decodeQrc(data.roma === undefined ? '' : data.roma);
  const info: LxLyricInfo = parseTxLyric(lrc, tlrc, rlrc);
  if (info.lyric.trim().length === 0 && info.lxlyric.trim().length === 0) {
    return null;
  }
  return info;
}

export async function txGetLyric(input: LxLyricFetchInput): Promise<LxLyricInfo | null> {
  const songId: string | null = await getSongId(input.remoteId);
  if (songId === null) {
    return null;
  }
  const first: LxLyricInfo | null = await requestPlayLyricInfo(songId);
  if (first !== null) {
    return first;
  }
  // 瞬时失败重试一次（musicu 偶发 code!=0；lx 原实现最多重试 3 次）
  return requestPlayLyricInfo(songId);
}
