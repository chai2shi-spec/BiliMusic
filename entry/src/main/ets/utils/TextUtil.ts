/**
 * 文本处理工具：B 站图片转 https、歌词标题清洗、LRC 解析、候选评分。
 * 移植自原 React 版 src/services/lyrics.ts（移除 DOM / localStorage 依赖）。
 */

import type { LyricLine, LyricCandidate, Track } from '../model/MusicModels';

export function toHttpsUrl(url: string): string {
  if (!url) {
    return '';
  }
  if (url.startsWith('//')) {
    return `https:${url}`;
  }
  if (url.startsWith('http://')) {
    return `https://${url.slice(7)}`;
  }
  return url;
}

/**
 * B 站图床缩略图：在原图 URL 后追加尺寸参数（`@{size}w_{size}h_1c.jpg`）。
 *
 * B 站 CDN 支持用 `@<宽>w_<高>h_1c.<格式>` 后缀动态缩放裁切：搜索页的视频截图
 * 封面原图普遍数百 KB，却只被当 40~56vp 的缩略图显示；按显示尺寸的 2~3 倍请求
 * 缩略图后体积降到几十 KB，省流量也省解码内存。大图（播放页唱片、背景模糊）
 * 不要走这里，仍用 toHttpsUrl 取原图。
 *
 * 只处理 hdslb.com 图床；已带 @ 参数或空 URL 原样返回，非图床链接不添后缀。
 */
export function toThumbUrl(url: string, size: number): string {
  const base: string = toHttpsUrl(url);
  if (base.length === 0 || base.indexOf('hdslb.com') < 0 || base.indexOf('@') >= 0) {
    return base;
  }
  return `${base}@${size}w_${size}h_1c.jpg`;
}

const NOISE: RegExp =
  /(official|lyrics?|audio|video|m\/?v|hd|4k|8k|live|cover|remix|remaster|reimagined|suno|feat\.?|ft\.?|prod\.?|demo|hi-?res|ost|bgm|歌词|动态歌词|高音质|无损|纯享|完整版|官方|现场|翻唱|翻自|改编|原唱|伴奏|钢琴版|弹唱|直播|街唱|试听|修复|重制|超清|字幕|珍藏|节目|片段|合集|歌单|循环|精选|盘点|排行|榜单|小时|分钟|首|教学|讲解)/i;
const CJK_NOISE: RegExp =
  /(官方版|官方MV|官方音频|官方|现场版|现场|完整版|纯享版|纯享|高音质|无损音质|无损|动态歌词|歌词版|超清|修复版|高清修复|重制版|中日字幕|双语字幕|字幕|试听|伴奏|钢琴版|翻唱|翻自|改编|原唱|纯音乐|直播弹唱|弹唱|街唱|男声|女声|原调|弱混|珍藏|教学|讲解|课程|合集|歌单|循环|精选|盘点|排行榜|榜单|一小时|小时|分钟|首|后台播放|附下载地址|下载地址)/g;
const LATIN_NOISE: RegExp =
  /\b(official|lyrics?|audio|video|m\/?v|mv|hd|4k|8k|live|cover|remix|remaster(?:ed)?|reimagined|suno|hi-?res|ost|bgm)\b/gi;
const SEP: RegExp = /[-–—_|/\\·•～~「」『』"'`*:：，,;；]/g;
const CJK_QUOTE: RegExp = /[《<]([^》>]+)[》>]/g;

function cleanSeg(raw: string): string {
  if (!raw) {
    return '';
  }
  let s: string = raw;
  s = s.replace(/#[^\s#]+/g, ' ');
  s = s.replace(/[!！?？.。]+/g, ' ');
  s = s.replace(CJK_NOISE, ' ');
  s = s.replace(LATIN_NOISE, ' ');
  s = s.replace(/\b\d+\s*(?:首|小时|分钟|mins?|hours?)\b/gi, ' ');
  s = s.replace(SEP, ' ');
  return s.replace(/\s+/g, ' ').trim();
}

export function cleanTitle(raw: string): string {
  if (!raw) {
    return '';
  }
  let s: string = raw.replace(CJK_QUOTE, ' $1 ');
  s = s.replace(/[【[(（]([^】\])）]*)[】\])）]/g, (_m: string, inner: string): string => {
    return NOISE.test(inner) ? ' ' : ` ${inner} `;
  });
  const seg: string = cleanSeg(s);
  return seg.length > 0 ? seg : raw.trim().slice(0, 40);
}

function quotedTitles(raw: string): string[] {
  const out: string[] = [];
  const matches: RegExpMatchArray | null = raw.match(/[《<]([^》>]+)[》>]/g);
  if (!matches) {
    return out;
  }
  for (let i = 0; i < matches.length; i++) {
    const inner: string = matches[i].slice(1, -1);
    const cleaned: string = cleanSeg(inner);
    if (cleaned.length >= 2 && out.indexOf(cleaned) < 0) {
      out.push(cleaned);
    }
  }
  return out;
}

function stripQuoted(raw: string): string {
  return raw.replace(CJK_QUOTE, ' ');
}

function compactKeywordParts(raw: string): string[] {
  const out: string[] = [];
  const parts: string[] = raw
    .replace(CJK_QUOTE, ' $1 ')
    .split(/[【】[\]()（）]|[-–—_|/\\·•～~「」『』"'`*:：，,;；]/);
  for (let i = 0; i < parts.length; i++) {
    const part: string = cleanSeg(parts[i]);
    if (part.length >= 2 && !NOISE.test(part) && out.indexOf(part) < 0) {
      out.push(part);
    }
  }
  return out;
}

function uniqPush(list: string[], value: string): void {
  const v: string = value.replace(/\s+/g, ' ').trim();
  if (v.length >= 2 && list.indexOf(v) < 0) {
    list.push(v);
  }
}

export function queryCandidates(raw: string): string[] {
  const cands: string[] = [];
  const quotes: string[] = quotedTitles(raw);
  const context: string = cleanSeg(stripQuoted(raw));

  for (let i = 0; i < quotes.length; i++) {
    uniqPush(cands, quotes[i]);
    if (context) {
      uniqPush(cands, `${quotes[i]} ${context}`);
    }
  }

  const parts: string[] = compactKeywordParts(raw);
  for (let i = 0; i < parts.length; i++) {
    uniqPush(cands, parts[i]);
  }
  uniqPush(cands, cleanTitle(raw));

  const compact: string[] = cleanTitle(raw)
    .split(' ')
    .filter((token: string): boolean => token.length > 1 && !NOISE.test(token));
  for (let i = 0; i < compact.length; i++) {
    uniqPush(cands, compact[i]);
  }

  return cands
    .filter((candidate: string): boolean => !/^(av|bv)[\da-z]+$/i.test(candidate))
    .slice(0, 8);
}

const TIME_TAG: RegExp = /\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]/g;
const META_LINE: RegExp = /^(ti|ar|al|by|offset|kana|tool|length):/i;

export function parseLrc(lrc: string): LyricLine[] {
  const out: LyricLine[] = [];
  const lines: string[] = lrc.split('\n');
  for (let i = 0; i < lines.length; i++) {
    TIME_TAG.lastIndex = 0;
    const rawLine: string = lines[i];
    const times: number[] = [];
    let m: RegExpExecArray | null = TIME_TAG.exec(rawLine);
    while (m !== null) {
      const min: number = parseInt(m[1], 10);
      const sec: number = parseInt(m[2], 10);
      const fracRaw: string = m[3] ? m[3] : '0';
      let frac: number = 0;
      if (m[3]) {
        frac = parseInt(fracRaw.padEnd(3, '0').slice(0, 3), 10) / 1000;
      }
      times.push(min * 60 + sec + frac);
      m = TIME_TAG.exec(rawLine);
    }
    if (times.length === 0) {
      continue;
    }
    const text: string = rawLine.replace(TIME_TAG, '').trim();
    if (!text || META_LINE.test(text)) {
      continue;
    }
    for (let j = 0; j < times.length; j++) {
      out.push({ time: times[j], text: text });
    }
  }
  out.sort((a: LyricLine, b: LyricLine): number => a.time - b.time);
  return out;
}

function plainToLines(plain: string): LyricLine[] {
  return plain
    .split('\n')
    .map((t: string): string => t.trim())
    .filter((t: string): boolean => t.length > 0)
    .filter((t: string): boolean => !META_LINE.test(t.replace(/^\[[^\]]+]/, '')))
    .map((text: string): LyricLine => ({ time: -1, text: text }));
}

function norm(s: string): string {
  let out: string = '';
  const lower: string = (s || '').toLowerCase();
  for (let i = 0; i < lower.length; i++) {
    const ch: string = lower[i];
    const code: number = lower.charCodeAt(i);
    if ((code >= 97 && code <= 122) || (code >= 48 && code <= 57) || (code >= 0x4e00 && code <= 0x9fff)) {
      out += ch;
    } else if (ch === ' ' || ch === '_') {
      out += ' ';
    }
  }
  return out.replace(/\s+/g, '');
}

function bigrams(s: string): Set<string> {
  const set: Set<string> = new Set<string>();
  if (s.length === 1) {
    set.add(s);
    return set;
  }
  for (let i = 0; i < s.length - 1; i++) {
    set.add(s.slice(i, i + 2));
  }
  return set;
}

function dice(a: string, b: string): number {
  const na: string = norm(a);
  const nb: string = norm(b);
  if (!na || !nb) {
    return 0;
  }
  if (na === nb) {
    return 1;
  }
  if (na.indexOf(nb) >= 0 || nb.indexOf(na) >= 0) {
    return 0.86;
  }
  const ba: Set<string> = bigrams(na);
  const bb: Set<string> = bigrams(nb);
  let inter: number = 0;
  ba.forEach((g: string): void => {
    if (bb.has(g)) {
      inter++;
    }
  });
  return (2 * inter) / (ba.size + bb.size);
}

function normIncludes(haystack: string, needle: string): boolean {
  const h: string = norm(haystack);
  const n: string = norm(needle);
  return n.length >= 2 && h.indexOf(n) >= 0;
}

export interface ScoreContext {
  rawTitle: string;
  clean: string;
  duration: number;
  quoted: string[];
}

export function scoreCandidate(c: LyricCandidate, ctx: ScoreContext): number {
  let quotedScore: number = 0;
  for (let i = 0; i < ctx.quoted.length; i++) {
    const d: number = dice(c.trackName, ctx.quoted[i]);
    if (d > quotedScore) {
      quotedScore = d;
    }
  }
  let score: number = 0;
  score += normIncludes(ctx.rawTitle, c.trackName) ? 360 : dice(c.trackName, ctx.clean) * 180;
  score += normIncludes(ctx.rawTitle, c.artistName) ? 280 : 0;
  score += quotedScore * 300;
  score += c.albumName && normIncludes(ctx.rawTitle, c.albumName) ? 40 : 0;

  if (ctx.duration > 0 && c.duration > 0) {
    const diff: number = Math.abs(ctx.duration - c.duration);
    if (diff <= 4) {
      score += 130;
    } else if (diff <= 10) {
      score += 85;
    } else if (diff <= 25) {
      score += 35;
    } else {
      score -= Math.min(diff, 240) * 1.25;
    }
    if (ctx.duration > 900 && c.duration < 600) {
      score -= 360;
    }
  }

  if (/伴奏|karaoke|instrumental/i.test(c.trackName) && !/伴奏|karaoke|instrumental/i.test(ctx.rawTitle)) {
    score -= 120;
  }
  if (/翻唱|cover/i.test(c.trackName) && !/翻唱|cover/i.test(ctx.rawTitle)) {
    score -= 80;
  }
  return score;
}

export { plainToLines };

/**
 * 去掉标题里的 HTML 标签与转义残留。
 *
 * B 站搜索接口的 title 带 `<em class="keyword">` 之类高亮标记（榜单 / 搜索结果都有），
 * 直接显示会出现一串尖括号。SearchPage 里有同名本地实现；这里放一份供新页面复用。
 */
export function stripHtmlTags(raw: string): string {
  if (!raw) {
    return '';
  }
  return raw.replace(/<[^>]+>/g, '');
}

/**
 * HTML 实体解码（`&amp;` `&lt;` `&quot;` `&#39;` 等）。
 *
 * 原来只在 `PlaylistImporter` 里（解析 B 站标题噪声段用），2026-10-22 提到这里共用 ——
 * HTML 搜索页兜底通道（`BilibiliApi.searchVideoByHtml`）解析卡片 `title="..."` 属性时，
 * 标题里的引号 / 尖括号全被转义过，不解码会把 `&quot;` 原样带进歌名、导致打分对不上。
 *
 * ⚠️ 只覆盖 B 站实际会出现的几种，不做通用实体表（会被 `&#xxxx;` 数字实体绕过，
 * 但标题里几乎没有）。顺序很重要：`&amp;` 必须**最后**替换，否则 `&amp;lt;`
 * 会被先解成 `&lt;` 再被误当成标签。
 */
const HTML_ENTITY_FROM: string[] = ['&#x27;', '&#39;', '&apos;', '&#34;', '&quot;', '&lt;', '&gt;', '&nbsp;', '&amp;'];
const HTML_ENTITY_TO: string[] = ['\'', '\'', '\'', '"', '"', '<', '>', ' ', '&'];

export function decodeHtmlEntities(raw: string): string {
  let s: string = raw;
  for (let i: number = 0; i < HTML_ENTITY_FROM.length; i++) {
    if (s.indexOf(HTML_ENTITY_FROM[i]) < 0) {
      continue;
    }
    s = s.split(HTML_ENTITY_FROM[i]).join(HTML_ENTITY_TO[i]);
  }
  return s;
}

/**
 * `mm:ss` / `hh:mm:ss` → 秒。解析不了就返回 0（调用方按「无时长」处理，不显示占位）。
 *
 * ⚠️ 榜单接口给的是 `duration("0:15")` 这种字符串，音乐中心给的是秒数 —— 两种都要认。
 */
export function parseDurationText(raw: string): number {
  if (!raw) {
    return 0;
  }
  const parts: string[] = raw.split(':');
  let seconds: number = 0;
  for (let i = 0; i < parts.length; i++) {
    const n: number = Number(parts[i]);
    if (!Number.isFinite(n) || n < 0) {
      return 0;
    }
    seconds = seconds * 60 + n;
  }
  return seconds;
}
