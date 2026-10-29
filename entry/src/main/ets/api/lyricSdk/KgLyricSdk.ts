/**
 * 酷狗歌词源（kg）。
 *
 * 移植自 lx-music-mobile `src/utils/musicSdk/kg/{musicSearch.js,lyric.js}`：
 *   1. 搜索 `https://songsearch.kugou.com/song_search_v2`（FileHash 为取词 id，
 *      Duration 秒；Grp 同名版本组展开、Audioid+FileHash 去重）；
 *   2. 歌词两步：
 *      a. `http://lyrics.kugou.com/search?...keyword=&hash=&timelength=`
 *         （头 KG-RC:1 / KG-THash，UA KuGou2012-9020-ExpandSearchManager）
 *         → candidates[0] { id, accesskey }，fmt 按 krctype/contenttype 选 krc/lrc；
 *      b. `http://lyrics.kugou.com/download?...fmt=` → body.content（Base64）；
 *   3. krc → decodeKrc（跳 4 字节 + 16 字节 key XOR + inflate）→ parseKrcLyric
 *      （`[language:base64]` 块给 type0=罗马音 / type1=翻译；`[t,dur]` 行 +
 *      `<s,d>` 逐字；`<(s,d),0>` 简化成 `<s,d>`）；lrc → Base64 解码即行级 LRC。
 */

import { HttpUtil } from '../../utils/HttpUtil';
import { decodeHtmlEntities } from '../../utils/TextUtil';
import { emptyLxLyricInfo, LxLyricFetchInput, LxLyricInfo, LxSongCandidate, SOURCE_KG } from './LxLyricTypes';
import { safeJson, thirdPartyOptions } from './utils/LxHttpUtil';
import { decodeKrc } from './utils/KrcDecoder';
import { base64Decode, utf8Decode } from './utils/LxByteUtils';

// ───────────────────────────── 响应模型 ─────────────────────────────

interface KgSinger {
  name?: string;
}

interface KgListItem {
  OriSongName?: string;
  Suffix?: string;
  AlbumName?: string;
  Singers?: KgSinger[];
  /** 秒 */
  Duration?: number;
  FileHash?: string;
  Audioid?: number;
  Grp?: KgListItem[];
}

interface KgSearchData {
  lists?: KgListItem[];
}

interface KgSearchResponse {
  error_code?: number;
  data?: KgSearchData;
}

interface KgLyricCandidate {
  id?: number;
  accesskey?: string;
  krctype?: number;
  contenttype?: number;
}

interface KgLyricSearchResponse {
  candidates?: KgLyricCandidate[];
}

interface KgLyricDownloadResponse {
  status?: number;
  fmt?: string;
  content?: string;
}

interface KgLanguageItem {
  type?: number;
  lyricContent?: string[][];
}

interface KgLanguageBlock {
  content?: KgLanguageItem[];
}

// ───────────────────────────── KRC 解析（照抄 lx parseLyric） ─────────────────────────────

function padNum(value: number, width: number): string {
  let s: string = `${value}`;
  while (s.length < width) {
    s = `0${s}`;
  }
  return s;
}

/** KRC 文本 → LX 四字段 */
function parseKrcLyric(str: string): LxLyricInfo {
  const info: LxLyricInfo = emptyLxLyricInfo();
  let body: string = str.replace(/\r/g, '');
  const headExp: RegExp = /^.*\[id:\$\w+\]\n/;
  if (headExp.test(body)) {
    body = body.replace(headExp, '');
  }

  let rlyricArr: string[][] | null = null;
  let tlyricArr: string[][] | null = null;
  // lx 原实现直接把拼接结果写回 rlyricArr[index]（JS 数组无类型约束）；
  // ArkTS 下改用独立输出数组，行为一致
  const rlyricOut: string[] = [];
  const tlyricOut: string[] = [];
  const transMatch: RegExpMatchArray | null = body.match(/\[language:([\w=\\/+]+)\]/);
  if (transMatch !== null) {
    body = body.replace(/\[language:[\w=\\/+]+\]\n/, '');
    let langBlock: KgLanguageBlock | null = null;
    try {
      langBlock = JSON.parse(utf8Decode(base64Decode(transMatch[1]))) as KgLanguageBlock;
    } catch (e) {
      langBlock = null;
    }
    if (langBlock !== null && langBlock.content !== undefined) {
      for (let i = 0; i < langBlock.content.length; i++) {
        const item: KgLanguageItem = langBlock.content[i];
        if (item.type === 0 && item.lyricContent !== undefined) {
          rlyricArr = item.lyricContent;
        } else if (item.type === 1 && item.lyricContent !== undefined) {
          tlyricArr = item.lyricContent;
        }
      }
    }
  }

  const lines: string[] = body.split('\n');
  const outLines: string[] = [];
  let index: number = 0;
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i];
    const m: RegExpExecArray | null = /^\[((\d+),\d+)\](.*)$/.exec(line);
    if (m === null) {
      outLines.push(line);
      continue;
    }
    const time: number = parseInt(m[2], 10);
    const ms: string = padNum(time % 1000, 3);
    const totalSec: number = Math.trunc(time / 1000);
    const mm: string = padNum(Math.trunc(totalSec / 60), 2);
    const ss: string = padNum(totalSec % 60, 2);
    const timeStr: string = `${mm}:${ss}.${ms}`;
    if (rlyricArr !== null) {
      const row: string[] | undefined = rlyricArr[index];
      rlyricOut.push(`[${timeStr}]${row === undefined ? '' : row.join('')}`);
    }
    if (tlyricArr !== null) {
      const row: string[] | undefined = tlyricArr[index];
      tlyricOut.push(`[${timeStr}]${row === undefined ? '' : row.join('')}`);
    }
    index++;
    outLines.push(`[${timeStr}]${m[3]}`);
  }

  let lxlyric: string = outLines.join('\n');
  lxlyric = lxlyric.replace(/<(\d+,\d+),\d+>/g, '<$1>');
  lxlyric = decodeHtmlEntities(lxlyric);
  const lyric: string = lxlyric.replace(/<\d+,\d+>/g, '');
  let rlyric: string = rlyricArr === null ? '' : rlyricOut.join('\n');
  let tlyric: string = tlyricArr === null ? '' : tlyricOut.join('\n');
  rlyric = decodeHtmlEntities(rlyric);
  tlyric = decodeHtmlEntities(tlyric);

  info.lyric = lyric;
  info.tlyric = tlyric;
  info.rlyric = rlyric;
  info.lxlyric = lxlyric;
  return info;
}

// ───────────────────────────── 搜索 ─────────────────────────────

function toKgCandidate(raw: KgListItem): LxSongCandidate {
  let singer: string = '';
  if (raw.Singers !== undefined) {
    const names: string[] = [];
    for (let i = 0; i < raw.Singers.length; i++) {
      const n: string | undefined = raw.Singers[i].name;
      if (n !== undefined && n.length > 0) {
        names.push(n);
      }
    }
    singer = names.join('、');
  }
  const suffix: string = raw.Suffix !== undefined && raw.Suffix.length > 0 ? ` ${raw.Suffix}` : '';
  const cand: LxSongCandidate = {
    source: SOURCE_KG,
    remoteId: raw.FileHash === undefined ? '' : raw.FileHash,
    title: decodeHtmlEntities(`${raw.OriSongName === undefined ? '' : raw.OriSongName}${suffix}`),
    artist: decodeHtmlEntities(singer),
    album: raw.AlbumName === undefined ? '' : decodeHtmlEntities(raw.AlbumName),
    duration: raw.Duration === undefined ? 0 : raw.Duration
  };
  return cand;
}

export async function kgSearch(keyword: string, limit: number): Promise<LxSongCandidate[]> {
  const url: string = `https://songsearch.kugou.com/song_search_v2?keyword=${encodeURIComponent(keyword)}`
    + `&page=1&pagesize=${limit}&userid=0&clientver=&platform=WebFilter&filter=2&iscorrection=1`
    + `&privilege_filter=0&area_code=1`;
  const options = thirdPartyOptions('https://www.kugou.com/');
  const text: string = await HttpUtil.requestText(url, options);
  const json: KgSearchResponse | null = safeJson<KgSearchResponse>(text);
  if (json === null || json.error_code !== 0 || json.data === undefined
    || json.data.lists === undefined || !Array.isArray(json.data.lists)) {
    return [];
  }
  const rawList: KgListItem[] = json.data.lists;
  const ids: Set<string> = new Set<string>();
  const out: LxSongCandidate[] = [];
  for (let i = 0; i < rawList.length; i++) {
    const item: KgListItem = rawList[i];
    if (item.FileHash === undefined || item.FileHash.length === 0) {
      continue;
    }
    const key: string = `${item.Audioid ?? ''}${item.FileHash}`;
    if (ids.has(key)) {
      continue;
    }
    ids.add(key);
    out.push(toKgCandidate(item));
    // Grp：同名不同版本组（live / 伴奏等），展开为独立候选
    if (item.Grp !== undefined && Array.isArray(item.Grp)) {
      for (let k = 0; k < item.Grp.length; k++) {
        const child: KgListItem = item.Grp[k];
        if (child.FileHash === undefined || child.FileHash.length === 0) {
          continue;
        }
        const childKey: string = `${child.Audioid ?? ''}${child.FileHash}`;
        if (ids.has(childKey)) {
          continue;
        }
        ids.add(childKey);
        out.push(toKgCandidate(child));
      }
    }
  }
  return out;
}

// ───────────────────────────── 取歌词 ─────────────────────────────

const KG_HEADERS: Record<string, string> = {
  'KG-RC': '1',
  'KG-THash': 'expand_search_manager.cpp:852736169:451',
  'User-Agent': 'KuGou2012-9020-ExpandSearchManager'
};

export async function kgGetLyric(input: LxLyricFetchInput): Promise<LxLyricInfo | null> {
  // 第一步：搜歌词条目（keyword=歌名，hash=FileHash，timelength=时长秒）
  const searchUrl: string = `http://lyrics.kugou.com/search?ver=1&man=yes&client=pc`
    + `&keyword=${encodeURIComponent(input.title.length > 0 ? input.title : input.remoteId)}`
    + `&hash=${input.remoteId}&timelength=${input.duration > 0 ? input.duration : 0}&lrctxt=1`;
  const searchOptions = thirdPartyOptions('http://lyrics.kugou.com/', KG_HEADERS);
  const searchText: string = await HttpUtil.requestText(searchUrl, searchOptions);
  const searchJson: KgLyricSearchResponse | null = safeJson<KgLyricSearchResponse>(searchText);
  if (searchJson === null || searchJson.candidates === undefined || searchJson.candidates.length === 0) {
    return null;
  }
  const first: KgLyricCandidate = searchJson.candidates[0];
  if (first.id === undefined || first.accesskey === undefined) {
    return null;
  }
  const fmt: string = (first.krctype === 1 && first.contenttype !== 1) ? 'krc' : 'lrc';

  // 第二步：下载歌词内容（Base64）
  const downloadUrl: string = `http://lyrics.kugou.com/download?ver=1&client=pc&id=${first.id}`
    + `&accesskey=${first.accesskey}&fmt=${fmt}&charset=utf8`;
  const downloadOptions = thirdPartyOptions('http://lyrics.kugou.com/', KG_HEADERS);
  const downloadText: string = await HttpUtil.requestText(downloadUrl, downloadOptions);
  const downloadJson: KgLyricDownloadResponse | null = safeJson<KgLyricDownloadResponse>(downloadText);
  if (downloadJson === null || downloadJson.content === undefined || downloadJson.content.length === 0) {
    return null;
  }
  const actualFmt: string = downloadJson.fmt === undefined ? fmt : downloadJson.fmt;
  if (actualFmt === 'krc') {
    const krcText: string = decodeKrc(downloadJson.content);
    if (krcText.length === 0) {
      return null;
    }
    return parseKrcLyric(krcText);
  }
  if (actualFmt === 'lrc') {
    const lrcText: string = utf8Decode(base64Decode(downloadJson.content));
    if (lrcText.trim().length === 0) {
      return null;
    }
    const info: LxLyricInfo = emptyLxLyricInfo();
    info.lyric = decodeHtmlEntities(lrcText);
    return info;
  }
  return null;
}
