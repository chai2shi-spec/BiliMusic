/**
 * LX 歌词解析层（lx-music 链路的归一化出口）。
 *
 * 输入 `LxLyricInfo`（lyric / tlyric / rlyric / lxlyric 四轨），输出
 * `LyricLine[]`（MusicModels，LrcView 直接可用）。
 *
 * 迁移自旧 `lyric/SplLyrics.ts` 的行为约定：
 *   - 不抛错：脏数据一律降级（空行 / 丢弃副轨），不让整首歌词丢失；
 *   - 主轨选择：**lxlyric（LX 逐字格式）优先**，无逐字轨时退回 lyric；
 *   - 翻译 / 罗马音按时间戳合并：精确匹配优先，±100ms 就近兜底，
 *     覆盖率 < 20% 整轨丢弃（时间轴对不齐的翻译宁可不合并）；
 *   - 无任何时间标签 → 纯文本按 4s 均匀排布（synced=false 供 UI 提示）；
 *   - 末行逐字时长夹在本行时长内（LAST_LINE_FALLBACK_MS 兜底），
 *     否则卡拉 OK 渐变永远走不完。
 *
 * LX 逐字格式：`[mm:ss.mmm]<相对ms,时长ms>字<相对ms,时长ms>字…`
 */

import { LyricLine, LyricWord } from '../model/MusicModels';
import { LxLyricInfo } from '../api/lyricSdk/LxLyricTypes';

/** 解析结果（LyricResult 的「行 + 标志位」部分） */
export interface ParsedLyricTrack {
  lines: LyricLine[];
  synced: boolean;
  dynamic: boolean;
  hasTranslation: boolean;
}

/**
 * 末行的兜底逐字时长（ms）：LyricLine 没有显式行结束时间，
 * LrcView 判行只看 time，此值只参与末行逐字进度夹取。
 */
const LAST_LINE_FALLBACK_MS: number = 8000;
/** 纯文本歌词的行间隔（ms） */
const PLAIN_LINE_INTERVAL_MS: number = 4000;
/** 翻译 / 罗马音合并的时间容差（ms）与覆盖率门控 */
const MERGE_TOLERANCE_MS: number = 100;
const MERGE_MATCH_RATIO: number = 0.2;

/** 行首连续时间标签，如 `[00:12.34][00:15.00]`；允许负号（部分源偶有负时间） */
const LEADING_TIME_REGEX: RegExp = new RegExp('^(\\[(-?\\d{1,3}):(-?\\d{1,2})\\.(\\d{1,6})\\])+');
const SINGLE_TIME_REGEX: RegExp = new RegExp('\\[(-?\\d{1,3}):(-?\\d{1,2})\\.(\\d{1,6})\\]', 'g');
/** 元数据标签 `[ti:xxx]` / `[offset:0]` */
const META_REGEX: RegExp = new RegExp('^\\[([a-zA-Z]+):(.*)\\]$');
/** LX 逐字标签 `<rel,dur>` */
const LX_WORD_REGEX: RegExp = new RegExp('<(-?\\d+),(\\d+)>');

/**
 * 解析时间标签 `[mm:ss.SSS]`。
 * 毫秒位数自适应：`.1` = 100ms，`.02` = 20ms，`.123456` 截断到 3 位。
 */
function parseTimeTag(timeStr: string): number {
  const clean: string = timeStr.replace(new RegExp('[\\[\\]<>]', 'g'), '');
  const parts: string[] = clean.split(':');
  if (parts.length < 2) {
    return 0;
  }
  const min: number = Number.parseInt(parts[0], 10);
  const secParts: string[] = parts[1].split('.');
  const sec: number = Number.parseInt(secParts[0], 10);
  let ms: number = 0;
  if (secParts.length > 1) {
    let frac: string = secParts[1];
    if (frac.length > 3) {
      frac = frac.substring(0, 3);
    }
    while (frac.length < 3) {
      frac = `${frac}0`;
    }
    ms = Number.parseInt(frac, 10);
  }
  if (Number.isNaN(min) || Number.isNaN(sec) || Number.isNaN(ms)) {
    return 0;
  }
  const total: number = min * 60 * 1000 + sec * 1000 + ms;
  return total < 0 ? 0 : total;
}

/** 一条解析出的行（words 为空数组 = 无逐字） */
interface TrackLine {
  startMs: number;
  text: string;
  words: LyricWord[];
}

function pushToBucket(buckets: Map<number, TrackLine[]>, time: number, line: TrackLine): void {
  const arr: TrackLine[] | undefined = buckets.get(time);
  if (arr === undefined) {
    buckets.set(time, [line]);
  } else {
    arr.push(line);
  }
}

/** 从「已剥掉行首时间标签」的文本里提取 LX 逐字片段 */
function parseLxWords(content: string): { text: string; words: LyricWord[] } {
  const parts: string[] = content.split(LX_WORD_REGEX);
  // split(捕获组)：[文本, rel, dur, 文本, rel, dur, …]
  const words: LyricWord[] = [];
  let fullText: string = '';
  if (parts.length === 1) {
    return { text: content.trim(), words: words };
  }
  for (let i = 0; i < parts.length; i += 3) {
    const wordText: string = parts[i];
    const relStr: string = parts[i + 1] === undefined ? '' : parts[i + 1];
    const durStr: string = parts[i + 2] === undefined ? '' : parts[i + 2];
    fullText += wordText;
    if (wordText.length === 0 || relStr.length === 0 || durStr.length === 0) {
      continue;
    }
    const rel: number = Number.parseInt(relStr, 10);
    const dur: number = Number.parseInt(durStr, 10);
    const offset: number = Number.isNaN(rel) || rel < 0 ? 0 : rel;
    const word: LyricWord = {
      text: wordText,
      offset: offset,
      duration: Number.isNaN(dur) || dur < 0 ? 0 : dur
    };
    words.push(word);
  }
  return { text: fullText.trim(), words: words };
}

/**
 * 解析 LRC / LX 文本为行数组（未合并翻译）。
 *
 * `extractWords` 为 true 时按 LX 逐字格式提取 `<rel,dur>`（lxlyric 轨），
 * 否则把行内残留的 `<…>` 标签当普通文本剥离（tlyric / rlyric / lyric 轨）。
 * 同一时间戳多行时取第一行（翻译统一走独立轨合并）。
 */
function parseTrack(content: string, extractWords: boolean): TrackLine[] {
  if (!content || content.length === 0) {
    return [];
  }
  const rawLines: string[] = content.split('\n');
  const buckets: Map<number, TrackLine[]> = new Map<number, TrackLine[]>();
  let lastTimestamps: number[] = [];

  for (let i = 0; i < rawLines.length; i++) {
    let line: string = rawLines[i];
    if (line.endsWith('\r')) {
      line = line.substring(0, line.length - 1);
    }
    const trimmed: string = line.trim();
    if (trimmed.length === 0) {
      continue;
    }
    if (META_REGEX.test(trimmed)) {
      continue;
    }
    const leadMatch: RegExpExecArray | null = LEADING_TIME_REGEX.exec(trimmed);
    if (leadMatch === null) {
      // 无时间标签的行：贴到上一行的时间戳上（多行歌词），否则丢弃
      for (let k = 0; k < lastTimestamps.length; k++) {
        const attached: TrackLine = { startMs: lastTimestamps[k], text: trimmed, words: [] };
        pushToBucket(buckets, lastTimestamps[k], attached);
      }
      continue;
    }
    const timePart: string = leadMatch[0];
    const body: string = trimmed.substring(timePart.length);
    const times: number[] = [];
    SINGLE_TIME_REGEX.lastIndex = 0;
    let tMatch: RegExpExecArray | null = SINGLE_TIME_REGEX.exec(timePart);
    while (tMatch !== null) {
      times.push(parseTimeTag(tMatch[0]));
      tMatch = SINGLE_TIME_REGEX.exec(timePart);
    }
    if (times.length === 0) {
      continue;
    }
    times.sort((a: number, b: number): number => a - b);
    lastTimestamps = times;
    for (let k = 0; k < times.length; k++) {
      let trackLine: TrackLine;
      if (extractWords) {
        const parsed = parseLxWords(body);
        trackLine = { startMs: times[k], text: parsed.text, words: parsed.words };
      } else {
        trackLine = { startMs: times[k], text: body.replace(new RegExp('<[^<>]*>', 'g'), '').trim(), words: [] };
      }
      pushToBucket(buckets, times[k], trackLine);
    }
  }

  const sortedTimes: number[] = [];
  buckets.forEach((_lines: TrackLine[], time: number): void => {
    sortedTimes.push(time);
  });
  sortedTimes.sort((a: number, b: number): number => a - b);

  const out: TrackLine[] = [];
  for (let i = 0; i < sortedTimes.length; i++) {
    const candidates: TrackLine[] = buckets.get(sortedTimes[i]) ?? [];
    if (candidates.length === 0) {
      continue;
    }
    out.push(candidates[0]);
  }
  return out;
}

/**
 * 文本里是否含时间轴（判断能否当「同步歌词」）。
 *
 * ⚠️ 必须**逐行**判断：多数 LRC 第一行是 `[ti:]` 元数据，
 * 对整串用 `^\[` 会立刻误判成纯文本。
 */
function hasTimeTag(text: string): boolean {
  if (!text || text.length === 0) {
    return false;
  }
  const lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    let line: string = lines[i];
    if (line.endsWith('\r')) {
      line = line.substring(0, line.length - 1);
    }
    const trimmed: string = line.trim();
    if (trimmed.length === 0 || META_REGEX.test(trimmed)) {
      continue;
    }
    if (LEADING_TIME_REGEX.test(trimmed)) {
      return true;
    }
  }
  return false;
}

/** 纯文本（无时间轴）→ 4s 均匀排布的静态行 */
function plainLines(text: string): LyricLine[] {
  if (!text || text.length === 0) {
    return [];
  }
  const rawLines: string[] = text.split('\n');
  const out: LyricLine[] = [];
  for (let i = 0; i < rawLines.length; i++) {
    let line: string = rawLines[i];
    if (line.endsWith('\r')) {
      line = line.substring(0, line.length - 1);
    }
    const trimmed: string = line.trim();
    if (trimmed.length === 0) {
      continue;
    }
    const lyricLine: LyricLine = {
      time: (out.length * PLAIN_LINE_INTERVAL_MS) / 1000,
      text: trimmed,
      translation: '',
      romaji: '',
      words: []
    };
    out.push(lyricLine);
  }
  return out;
}

/**
 * 副轨（翻译 / 罗马音）合并：先按 ±100ms 容差算覆盖率（≥20% 才合并），
 * 再对每条主轨行取「精确匹配 → ±100ms 就近」的副轨文本。
 */
function mergeSecondary(primary: TrackLine[], raw: string): Map<number, string> | null {
  if (!raw || raw.length === 0) {
    return null;
  }
  const secondary: TrackLine[] = parseTrack(raw, false);
  if (secondary.length === 0 || primary.length === 0) {
    return null;
  }
  const primaryTimes: number[] = [];
  for (let i = 0; i < primary.length; i++) {
    primaryTimes.push(primary[i].startMs);
  }
  let matched: number = 0;
  for (let i = 0; i < secondary.length; i++) {
    if (nearestIndex(primaryTimes, secondary[i].startMs, MERGE_TOLERANCE_MS) >= 0) {
      matched++;
    }
  }
  if (matched / secondary.length < MERGE_MATCH_RATIO) {
    return null;
  }
  // 副轨映射：时间 → 文本（就近吸附到容差内的时间上，空行不占位）
  const map: Map<number, string> = new Map<number, string>();
  for (let i = 0; i < secondary.length; i++) {
    const text: string = secondary[i].text.trim();
    if (text.length === 0) {
      continue;
    }
    map.set(secondary[i].startMs, text);
  }
  const secTimes: number[] = [];
  map.forEach((_v: string, t: number): void => {
    secTimes.push(t);
  });
  const out: Map<number, string> = new Map<number, string>();
  for (let i = 0; i < primary.length; i++) {
    const startMs: number = primary[i].startMs;
    const exact: string | undefined = map.get(startMs);
    if (exact !== undefined) {
      out.set(startMs, exact);
      continue;
    }
    const idx: number = nearestIndex(secTimes, startMs, MERGE_TOLERANCE_MS);
    if (idx >= 0) {
      out.set(startMs, map.get(secTimes[idx]) ?? '');
    }
  }
  return out;
}

/** 升序时间数组里找与 target 距离 ≤ tolerance 的最近下标；无则 -1 */
function nearestIndex(sortedTimes: number[], target: number, tolerance: number): number {
  let best: number = -1;
  let bestDiff: number = tolerance + 1;
  for (let i = 0; i < sortedTimes.length; i++) {
    const diff: number = Math.abs(sortedTimes[i] - target);
    if (diff < bestDiff) {
      bestDiff = diff;
      best = i;
    }
  }
  return bestDiff <= tolerance ? best : -1;
}

/**
 * LX 四轨 → LyricLine[]。
 * 返回 null 表示「四轨全空 / 全是垃圾」，调用方按无歌词处理。
 */
export function parseLxLyric(info: LxLyricInfo): ParsedLyricTrack | null {
  const lyricText: string = info.lyric;
  const lxText: string = info.lxlyric;

  // 1) 主轨：lxlyric（逐字）优先，lyric 兜底
  let primary: TrackLine[] = [];
  let synced: boolean = false;
  if (hasTimeTag(lxText)) {
    primary = parseTrack(lxText, true);
    synced = true;
  }
  if (primary.length === 0 && hasTimeTag(lyricText)) {
    primary = parseTrack(lyricText, false);
    synced = true;
  }

  // 2) 全无时间轴：纯文本按 4s 均匀排布
  if (primary.length === 0) {
    const source: string = lyricText.length > 0 ? lyricText : lxText;
    const plain: LyricLine[] = plainLines(source);
    if (plain.length === 0) {
      return null;
    }
    const plainResult: ParsedLyricTrack = {
      lines: plain,
      synced: false,
      dynamic: false,
      hasTranslation: false
    };
    return plainResult;
  }

  // 3) 翻译 / 罗马音合并
  const translationMap: Map<number, string> | null = mergeSecondary(primary, info.tlyric);
  const romajiMap: Map<number, string> | null = mergeSecondary(primary, info.rlyric);

  // 4) 组装
  const lines: LyricLine[] = [];
  let dynamic: boolean = false;
  let hasTranslation: boolean = false;
  for (let i = 0; i < primary.length; i++) {
    const trackLine: TrackLine = primary[i];
    const startMs: number = trackLine.startMs;
    const lineDurMs: number = i < primary.length - 1
      ? Math.max(1, primary[i + 1].startMs - startMs)
      : LAST_LINE_FALLBACK_MS;

    const words: LyricWord[] = [];
    for (let k = 0; k < trackLine.words.length; k++) {
      const src: LyricWord = trackLine.words[k];
      const offset: number = Math.max(0, Math.min(src.offset, lineDurMs - 1));
      const dur: number = Math.max(1, Math.min(src.duration, lineDurMs - offset));
      const word: LyricWord = {
        text: src.text,
        offset: offset,
        duration: dur
      };
      words.push(word);
    }
    if (words.length > 0) {
      dynamic = true;
    }
    const translation: string = translationMap === null ? '' : (translationMap.get(startMs) ?? '');
    const romaji: string = romajiMap === null ? '' : (romajiMap.get(startMs) ?? '');
    if (translation.length > 0) {
      hasTranslation = true;
    }
    const line: LyricLine = {
      time: startMs / 1000,
      text: trackLine.text,
      translation: translation,
      romaji: romaji,
      words: words
    };
    lines.push(line);
  }
  if (lines.length === 0) {
    return null;
  }
  const result: ParsedLyricTrack = {
    lines: lines,
    synced: synced,
    dynamic: dynamic,
    hasTranslation: hasTranslation
  };
  return result;
}
