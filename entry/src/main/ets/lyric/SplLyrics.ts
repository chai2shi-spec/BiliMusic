/**
 * SPL（Salt Player Lyrics）歌词解析层 —— 移植自 BBPlayer `packages/splash/src`。
 *
 * 原实现（`parser/index.ts` / `parser/spans.ts` / `parser/merge.ts` / `utils/time.ts`
 * / `converter/netease.ts`）是纯函数，与 React Native 无关，这里按 ArkTS 规范重写：
 *   - 去掉 `neverthrow` / `SplParseError` 抛错（歌词数据脏，抛错会连带整首丢失）；
 *   - 不再在解析阶段 Object.assign 改写 span（ArkTS 对象展开受限，直接构造新对象）；
 *   - 增加 `MAX_END_MS`：末行不给 `start+10s` 而是给一个足够大的值，
 *     避免「最后一句唱完就不再高亮」。
 *
 * 为什么值得移植：
 *   1. **翻译 / 罗马音按时间戳合并**（`merge.ts`），并有 20% 覆盖率门控 ——
 *      时间轴对不齐的翻译会被整体丢弃，不会出现「日文歌词配中文翻译错位」；
 *   2. **逐字 spans**（`<mm:ss.SSS>` 标签）—— 网易云 YRC / 酷狗 KRC 都能转成
 *      这种格式，LrcView 的卡拉 OK 高亮直接可用。
 *
 * 数据流：各源原始文本（LRC / YRC / KRC）→ 统一转成 SPL 文本 → `parseSpl` 出带
 * 逐字的行 → `parseAndMergeLyrics` 合并翻译与罗马音。
 */

/** 逐字片段（毫秒） */
export interface LyricSpanItem {
  text: string;
  startTime: number;
  endTime: number;
  duration: number;
}

/** 一行歌词（含合并后的翻译 / 罗马音） */
export interface SplLyricLine {
  /** 行起始（ms） */
  startTime: number;
  /** 行结束（ms） */
  endTime: number;
  /** 主歌词文本 */
  content: string;
  /** 翻译（无则空串） */
  translation: string;
  /** 罗马音（无则空串） */
  romaji: string;
  /** 是否带逐字时间轴 */
  isDynamic: boolean;
  /** 逐字片段（isDynamic=false 时为空数组） */
  spans: LyricSpanItem[];
}

/** 一首歌的多轨原始文本（全部为 SPL / LRC 文本，空串表示没有该轨） */
export interface MultiLyricInput {
  lrc: string;
  tlyric: string;
  romalrc: string;
}

/**
 * 末行的结束时间。
 * 取一个远大于任何歌曲时长的值 —— LrcView 判行只看 startTime，
 * endTime 只参与滚动与逐字进度，给大值等价于「唱完仍保持高亮」。
 */
const LAST_LINE_END_MS: number = 24 * 60 * 60 * 1000;

/** 行首连续时间标签，如 `[00:12.34][00:15.00]`；允许负号（YRC 偶有负时间） */
const LEADING_TIME_REGEX: RegExp = new RegExp('^(\\[(-?\\d{1,3}):(-?\\d{1,2})\\.(\\d{1,6})\\])+');
const SINGLE_TIME_REGEX: RegExp = new RegExp('\\[(-?\\d{1,3}):(-?\\d{1,2})\\.(\\d{1,6})\\]', 'g');
/** 元数据标签 `[ti:xxx]` / `[offset:0]` */
const META_REGEX: RegExp = new RegExp('^\\[([a-zA-Z]+):(.*)\\]$');
/** 逐字标签（行内） */
const SPAN_SPLIT_REGEX: RegExp = new RegExp('([<[]\\d{1,3}:\\d{1,2}\\.\\d{1,6}[>\\]])');

/**
 * 解析时间标签 `[mm:ss.SSS]` / `<mm:ss.SSS>` / `mm:ss.SS`。
 * 毫秒位数自适应：`.1` = 100ms，`.02` = 20ms，`.123456` 截断到 3 位。
 */
export function parseTimeTag(timeStr: string): number {
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
    // `.1` → 100ms；`.123456` → 123ms（先补齐/截断到 3 位再转数字）
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

/** 毫秒 → SPL 时间标签（`mm:ss.SSS`），供 YRC / KRC 转 SPL 用 */
export function formatSplTime(ms: number): string {
  const safe: number = ms < 0 ? 0 : ms;
  const totalSec: number = Math.floor(safe / 1000);
  const min: number = Math.floor(totalSec / 60);
  const sec: number = totalSec % 60;
  const milli: number = Math.floor(safe % 1000);
  const mm: string = min < 10 ? `0${min}` : `${min}`;
  const ss: string = sec < 10 ? `0${sec}` : `${sec}`;
  let mmm: string = `${milli}`;
  while (mmm.length < 3) {
    mmm = `0${mmm}`;
  }
  return `${mm}:${ss}.${mmm}`;
}

interface SpanParseResult {
  content: string;
  spans: LyricSpanItem[];
  isDynamic: boolean;
  /** 行末若带显式时间标签，则该标签即本行结束时间；无则 -1 */
  explicitEnd: number;
}

/**
 * 解析单行内的逐字标签。
 * 输入是「已经剥掉行首时间戳」的文本，如 `Hello<00:01.50>World`。
 */
function parseSpans(rawContent: string, lineStartTime: number): SpanParseResult {
  const parts: string[] = rawContent.split(SPAN_SPLIT_REGEX);
  const spans: LyricSpanItem[] = [];
  let currentTime: number = lineStartTime;
  let explicitEnd: number = -1;
  let fullText: string = '';

  for (let i = 0; i < parts.length; i++) {
    const part: string = parts[i];
    if (i % 2 === 0) {
      // 文本段
      if (part.length === 0) {
        continue;
      }
      const span: LyricSpanItem = {
        text: part,
        startTime: currentTime,
        endTime: 0,
        duration: 0
      };
      spans.push(span);
      fullText += part;
    } else {
      // 时间标签段
      const time: number = parseTimeTag(part);
      if (time < currentTime) {
        // 乱序标签：忽略，不当成结束点
        continue;
      }
      if (spans.length > 0) {
        const last: LyricSpanItem = spans[spans.length - 1];
        if (last.endTime === 0) {
          last.endTime = time;
          last.duration = time - last.startTime;
        }
      }
      currentTime = time;
      explicitEnd = time;
    }
  }

  // 行末仍是文本 → 最后一个标签只是「下一段的起点」，不是整行结束点
  const lastPart: string = parts.length > 0 ? parts[parts.length - 1] : '';
  if (lastPart.length > 0 && lastPart.trim().length > 0) {
    explicitEnd = -1;
  }

  return {
    content: fullText,
    spans: spans,
    isDynamic: parts.length > 1,
    explicitEnd: explicitEnd
  };
}

/**
 * 解析 SPL / LRC 文本为行数组（未合并翻译）。
 *
 * 同一时间戳出现多行时：**第一行是主歌词，其余按出现顺序作为附加行**
 * （BBPlayer 的 `translations` 语义；本工程把附加行丢弃，翻译统一走
 * `parseAndMergeLyrics` 的独立轨合并，避免两套翻译逻辑打架）。
 */
export function parseSpl(lrcContent: string): SplLyricLine[] {
  if (!lrcContent || lrcContent.length === 0) {
    return [];
  }
  const rawLines: string[] = lrcContent.split('\n');
  // 时间戳 → 该时间戳下的文本行（按出现顺序）
  const buckets: Map<number, string[]> = new Map<number, string[]>();
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
    // 元数据行（[ti:] / [ar:] / [offset:] …）直接跳过
    if (META_REGEX.test(trimmed)) {
      continue;
    }

    const leadMatch: RegExpExecArray | null = LEADING_TIME_REGEX.exec(trimmed);
    if (leadMatch === null) {
      // 无时间标签的行：贴到上一行的时间戳上（多行歌词），否则丢弃
      if (lastTimestamps.length > 0) {
        for (let k = 0; k < lastTimestamps.length; k++) {
          pushToBucket(buckets, lastTimestamps[k], trimmed);
        }
      }
      continue;
    }

    const timePart: string = leadMatch[0];
    const content: string = trimmed.substring(timePart.length);
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
      pushToBucket(buckets, times[k], content);
    }
  }

  // 不用 Array.from（ArkTS 标准库覆盖不全），直接遍历 Map 收集键
  const sortedTimes: number[] = [];
  buckets.forEach((_lines: string[], time: number): void => {
    sortedTimes.push(time);
  });
  sortedTimes.sort((a: number, b: number): number => a - b);

  const out: SplLyricLine[] = [];
  for (let i = 0; i < sortedTimes.length; i++) {
    const startTime: number = sortedTimes[i];
    const candidates: string[] = buckets.get(startTime) ?? [];
    if (candidates.length === 0) {
      continue;
    }
    const mainRaw: string = candidates[0];
    const parsed: SpanParseResult = parseSpans(mainRaw, startTime);

    let endTime: number;
    if (parsed.explicitEnd >= 0) {
      endTime = parsed.explicitEnd;
    } else if (i < sortedTimes.length - 1) {
      endTime = sortedTimes[i + 1];
    } else {
      endTime = LAST_LINE_END_MS;
    }
    if (endTime <= startTime) {
      // 空行（相邻标签同时刻）也要有正时长，否则逐字进度会除零
      endTime = startTime + 1;
    }

    const spans: LyricSpanItem[] = [];
    for (let k = 0; k < parsed.spans.length; k++) {
      const s: LyricSpanItem = parsed.spans[k];
      const spanEnd: number = (s.endTime === 0 || Number.isNaN(s.endTime)) ? endTime : s.endTime;
      const fixed: LyricSpanItem = {
        text: s.text,
        startTime: s.startTime,
        endTime: spanEnd,
        duration: spanEnd - s.startTime
      };
      spans.push(fixed);
    }

    const line: SplLyricLine = {
      startTime: startTime,
      endTime: endTime,
      content: parsed.content,
      translation: '',
      romaji: '',
      isDynamic: parsed.isDynamic,
      spans: spans
    };
    out.push(line);
  }
  return out;
}

function pushToBucket(buckets: Map<number, string[]>, time: number, content: string): void {
  const arr: string[] | undefined = buckets.get(time);
  if (arr === undefined) {
    buckets.set(time, [content]);
  } else {
    arr.push(content);
  }
}

/**
 * 副轨（翻译 / 罗马音）与主轨的时间戳匹配度是否达标。
 * 阈值 20%：低于这个说明两边不是同一版时间轴（多见于「翻译是另一段剪辑」），
 * 强行合并会整首错位。
 */
function isTimelineMatched(mainLines: SplLyricLine[], secondary: SplLyricLine[]): boolean {
  if (secondary.length === 0 || mainLines.length === 0) {
    return false;
  }
  const mainTimes: Set<number> = new Set<number>();
  for (let i = 0; i < mainLines.length; i++) {
    mainTimes.add(mainLines[i].startTime);
  }
  let matched: number = 0;
  for (let i = 0; i < secondary.length; i++) {
    if (mainTimes.has(secondary[i].startTime)) {
      matched++;
    }
  }
  return matched / secondary.length >= 0.2;
}

/** 把副轨解析成 时间戳 → 文本 的映射；不达标或解析失败返回 null */
function mapSecondary(mainLines: SplLyricLine[], raw: string): Map<number, string> | null {
  if (!raw || raw.length === 0) {
    return null;
  }
  let parsed: SplLyricLine[] = [];
  try {
    parsed = parseSpl(raw);
  } catch (e) {
    return null;
  }
  if (!isTimelineMatched(mainLines, parsed)) {
    return null;
  }
  const map: Map<number, string> = new Map<number, string>();
  for (let i = 0; i < parsed.length; i++) {
    const text: string = parsed[i].content.trim();
    // 空翻译行不覆盖（网易云翻译轨常用空行占位）
    if (text.length > 0) {
      map.set(parsed[i].startTime, text);
    }
  }
  return map;
}

/**
 * 解析并合并三轨歌词。**主轨为基准**，翻译与罗马音按 startTime 对齐。
 */
export function parseAndMergeLyrics(input: MultiLyricInput): SplLyricLine[] {
  const mainLines: SplLyricLine[] = parseSpl(input.lrc);
  if (mainLines.length === 0) {
    return [];
  }
  const translationMap: Map<number, string> | null = mapSecondary(mainLines, input.tlyric);
  const romajiMap: Map<number, string> | null = mapSecondary(mainLines, input.romalrc);
  if (translationMap === null && romajiMap === null) {
    return mainLines;
  }
  const out: SplLyricLine[] = [];
  for (let i = 0; i < mainLines.length; i++) {
    const line: SplLyricLine = mainLines[i];
    const tr: string | undefined = translationMap !== null ? translationMap.get(line.startTime) : undefined;
    const ro: string | undefined = romajiMap !== null ? romajiMap.get(line.startTime) : undefined;
    const merged: SplLyricLine = {
      startTime: line.startTime,
      endTime: line.endTime,
      content: line.content,
      translation: tr === undefined ? '' : tr,
      romaji: ro === undefined ? '' : ro,
      isDynamic: line.isDynamic,
      spans: line.spans
    };
    out.push(merged);
  }
  return out;
}

// ─────────────────────────── 各源格式 → SPL 文本 ───────────────────────────

interface YrcToken {
  tx?: string;
  li?: string;
  or?: string;
}

interface YrcJsonLine {
  t?: number;
  c?: YrcToken[];
}

/**
 * 网易云 `yrc`（逐字）→ SPL 文本。
 *
 * 实测（2026-10-22）`/api/song/lyric/v1?...&yv=-1` 的 `lrc.lyric` 有两种形态：
 *   a) **逐字行**：`[1234,567](1234,120,0)词(1354,120,0)语…`
 *   b) **JSON 行**：`{"t":1234,"c":[{"tx":"词"},{"tx":"语"}]}`（无词级时间）
 * 两种都要能转：a 转成带 `<mm:ss.SSS>` 的 SPL（保留逐字），b 只能降级成行级。
 */
export function yrcToSpl(yrcContent: string): string {
  if (!yrcContent || yrcContent.length === 0) {
    return '';
  }
  const lines: string[] = yrcContent.split('\n');
  const splLines: string[] = [];

  for (let i = 0; i < lines.length; i++) {
    let line: string = lines[i];
    if (line.endsWith('\r')) {
      line = line.substring(0, line.length - 1);
    }
    const trimmed: string = line.trim();
    if (trimmed.length === 0) {
      continue;
    }

    // 形态 b：JSON 行
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      let parsed: YrcJsonLine | null = null;
      try {
        parsed = JSON.parse(trimmed) as YrcJsonLine;
      } catch (e) {
        parsed = null;
      }
      if (parsed !== null && parsed.c !== undefined && Array.isArray(parsed.c)) {
        let text: string = '';
        for (let k = 0; k < parsed.c.length; k++) {
          const tok: YrcToken = parsed.c[k];
          if (tok.tx !== undefined) {
            text += tok.tx;
          }
        }
        const t: number = parsed.t === undefined ? 0 : parsed.t;
        splLines.push(`[${formatSplTime(t)}]${text}`);
      }
      continue;
    }

    // 已带行级时间标签的（含元数据标签）：秒与小数之间若用冒号则规范化成点
    if (LEADING_TIME_REGEX.test(trimmed) || META_REGEX.test(trimmed)) {
      splLines.push(trimmed.replace(new RegExp('\\[(\\d{1,2}):(\\d{1,2}):(\\d{1,3})\\]', 'g'), '[$1:$2.$3]'));
      continue;
    }

    // 形态 a：`[start,duration](wstart,wdur,flag)text…`
    const headMatch: RegExpExecArray | null = new RegExp('^\\[(\\d+),(\\d+)\\](.*)').exec(trimmed);
    if (headMatch === null) {
      continue;
    }
    const lineStart: number = Number.parseInt(headMatch[1], 10);
    const content: string = headMatch[3];
    const wordRegex: RegExp = new RegExp('\\((\\d+),(\\d+),(\\d+)\\)([^(]*)', 'g');
    const pieces: string[] = [];
    let lastWordEnd: number = lineStart;
    let wMatch: RegExpExecArray | null = wordRegex.exec(content);
    let first: boolean = true;
    while (wMatch !== null) {
      const wordStart: number = Number.parseInt(wMatch[1], 10);
      const wordDur: number = Number.parseInt(wMatch[2], 10);
      const wordEnd: number = wordStart + wordDur;
      const wordText: string = wMatch[4];
      if (first) {
        // 首词直接接在行首时间之后（行首标签已经是起点）
        pieces.push(wordText);
        first = false;
      } else if (wordStart > lastWordEnd) {
        // 词间有停顿：先显式结束上一个词，再给新词打点，否则上一词会被拉长填满空隙
        pieces.push(`<${formatSplTime(lastWordEnd)}>`);
        pieces.push(`<${formatSplTime(wordStart)}>${wordText}`);
      } else {
        pieces.push(`<${formatSplTime(wordStart)}>${wordText}`);
      }
      lastWordEnd = wordEnd;
      wMatch = wordRegex.exec(content);
    }
    if (first) {
      // 没有任何逐字标签：整行当一个文本
      splLines.push(`[${formatSplTime(lineStart)}]${content}`);
    } else {
      splLines.push(`[${formatSplTime(lineStart)}]${pieces.join('')}<${formatSplTime(lastWordEnd)}>`);
    }
  }

  return splLines.join('\n');
}

/**
 * 酷狗 KRC（逐字）→ SPL 文本。
 * KRC 行格式：`[行起始ms,行时长ms]<词起始ms,词时长ms,0>词…`
 */
export function krcToSpl(krcContent: string): string {
  if (!krcContent || krcContent.length === 0) {
    return '';
  }
  const lines: string[] = krcContent.split('\n');
  const splLines: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    let line: string = lines[i];
    if (line.endsWith('\r')) {
      line = line.substring(0, line.length - 1);
    }
    const trimmed: string = line.trim();
    if (trimmed.length === 0) {
      continue;
    }
    const headMatch: RegExpExecArray | null = new RegExp('^\\[(\\d+),(\\d+)\\](.*)').exec(trimmed);
    if (headMatch === null) {
      continue;
    }
    const lineStart: number = Number.parseInt(headMatch[1], 10);
    const content: string = headMatch[3];
    const wordRegex: RegExp = new RegExp('<(\\d+),(\\d+),(\\d+)>([^<]*)', 'g');
    const pieces: string[] = [];
    let wMatch: RegExpExecArray | null = wordRegex.exec(content);
    let first: boolean = true;
    while (wMatch !== null) {
      const wordStart: number = Number.parseInt(wMatch[1], 10);
      const wordText: string = wMatch[4];
      if (first) {
        pieces.push(wordText);
        first = false;
      } else {
        pieces.push(`<${formatSplTime(wordStart)}>${wordText}`);
      }
      wMatch = wordRegex.exec(content);
    }
    if (first) {
      pieces.push(content);
    }
    splLines.push(`[${formatSplTime(lineStart)}]${pieces.join('')}`);
  }
  return splLines.join('\n');
}

/**
 * 纯文本（无时间轴）→ 行数组备用。
 * 只在「有歌词但完全没有时间标签」时用，展示为静态歌词。
 */
export function plainTextToSpl(text: string): string {
  if (!text || text.length === 0) {
    return '';
  }
  const lines: string[] = text.split('\n');
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    let line: string = lines[i];
    if (line.endsWith('\r')) {
      line = line.substring(0, line.length - 1);
    }
    const trimmed: string = line.trim();
    if (trimmed.length > 0) {
      // 每行按 4s 均匀排布，只是为了让 LrcView 有东西可画（synced=false 会提示）
      out.push(`[${formatSplTime(i * 4000)}]${trimmed}`);
    }
  }
  return out.join('\n');
}

/**
 * 文本里是否含时间轴（判断能否当「同步歌词」）。
 *
 * ⚠️ 必须**逐行**判断，不能直接对整段用 `^\[` ——
 * 多数 LRC 第一行是 `[ti:]` / `[ar:]` 元数据，`^` 只锚定整串开头，
 * 会立刻返回 false，进而把整首同步歌词误判成「纯文本」按 4s 均匀排布。
 */
export function hasTimeTag(text: string): boolean {
  if (!text || text.length === 0) {
    return false;
  }
  const lines: string[] = text.split('\n');
  const rangeLine: RegExp = new RegExp('^\\[\\d+,\\d+\\]');
  for (let i = 0; i < lines.length; i++) {
    let line: string = lines[i];
    if (line.endsWith('\r')) {
      line = line.substring(0, line.length - 1);
    }
    const trimmed: string = line.trim();
    if (trimmed.length === 0 || META_REGEX.test(trimmed)) {
      continue;
    }
    if (LEADING_TIME_REGEX.test(trimmed) || rangeLine.test(trimmed) || trimmed.startsWith('{"t":')) {
      return true;
    }
  }
  return false;
}
