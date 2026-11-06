/**
 * 分段结果持久化缓存（文件型 KV）。
 *
 * 背景：分段官方源 `x/player/wbi/v2` 的 view_points 对登录态有依赖、
 * 且可能被 gaia 风控定点拦截（HTTP 412）——「同一音频有人显示分段有人
 * 不显示」；会话级 chapterCache 重启即清零，还叠加「昨天有分段今天没有」
 * 的跨会话抖动。本缓存把**非空**分段结果按 cid 落盘，冷启动命中免网络，
 * 断网 / 风控 / 未登录场景下 7 天新鲜期内照常显示。
 *
 * 为什么不用 Preferences：单值 8192 字节硬上限，章节数组条目多时必超
 * （IntroSkipStore 同款结论）。
 * 为什么空结果不落盘：分段可能后来才新增（UP 主补录 / AI 分段生成中），
 * 空结果持久化会把「暂时没有」错误定格成「一直没有」；每次新会话重查
 * 自然覆盖。官方源结论性空的会话内定格仍由 ChapterStore.loadedKey 承担。
 *
 * 落盘形态是**数组**（[{c,ch,t}]）而不是动态键对象：动态键 JSON 需要
 * Record + 下标访问的解析链路，数组 + 逐条 typeof 校验更直白也更稳
 * （IntroSkipStore / HomeFeedFilterStore 同款纪律）。
 *
 * 全 IO try/catch 永不抛：分段是增强功能，绝不能成为播放链路的崩溃源。
 * 未 init（卡片进程等场景）读 null / 写跳过，无害降级为「无持久化缓存」。
 */

import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { CHAPTER_SOURCE_DESC, CHAPTER_SOURCE_OFFICIAL, CHAPTER_SOURCE_TOP_COMMENT, VideoChapter } from '../model/MusicModels';

/** 新鲜期（TTL）：7 天内命中直接用，过期视为 miss 重新走网络（分段后来新增可覆盖） */
const CHAPTER_TTL_MS: number = 7 * 24 * 60 * 60 * 1000;
/** 记录条目上限：超出按最旧淘汰（Map 迭代序 = 插入序；写入先删后插 = LRU recency） */
const MAX_ENTRIES: number = 400;
/** 防抖落盘间隔：连续保存多首时合并一次写 */
const FLUSH_DELAY_MS: number = 2000;

/** 落盘条目（c = cid 字符串；ch = 分段数组；t = 写入时间戳 ms） */
interface StoredChapterEntry {
  c: string;
  ch: VideoChapter[];
  t: number;
}

let storePath: string = '';
const entries: Map<string, StoredChapterEntry> = new Map<string, StoredChapterEntry>();
let flushTimer: number = -1;

/**
 * 落盘/装载共用的条目消毒：分段逐条校验（from/to 有限且 to > from ≥ 0、
 * 标题非空），source 缺失或非法（非 desc / topReply / official）补 official
 * （向后兼容旧数据）。返回空数组 = 条目不合法（调用方丢弃）。
 */
function sanitizeChapters(raw: VideoChapter[]): VideoChapter[] {
  if (!Array.isArray(raw) || raw.length === 0) {
    return [];
  }
  const out: VideoChapter[] = [];
  for (let i = 0; i < raw.length; i++) {
    const ch: VideoChapter = raw[i];
    if (ch === null || ch === undefined || typeof ch !== 'object') {
      continue;
    }
    const from: number = ch.from;
    const to: number = ch.to;
    const title: string = typeof ch.title === 'string' ? ch.title.trim() : '';
    if (typeof from !== 'number' || !Number.isFinite(from) || from < 0
      || typeof to !== 'number' || !Number.isFinite(to) || to <= from
      || title.length === 0) {
      continue;
    }
    const source: string = ch.source === CHAPTER_SOURCE_DESC
      ? CHAPTER_SOURCE_DESC
      : ch.source === CHAPTER_SOURCE_TOP_COMMENT
        ? CHAPTER_SOURCE_TOP_COMMENT
        : CHAPTER_SOURCE_OFFICIAL;
    out.push({ from: from, to: to, title: title, source: source });
  }
  return out;
}

/** 初始化：装载 chapter_cache.json 进内存表。AppContainer.init 调用，同步执行（毫秒级）。 */
export function initChapterCacheStore(context: common.Context): void {
  try {
    storePath = `${context.filesDir}/chapter_cache.json`;
    if (fs.accessSync(storePath)) {
      const raw: string = fs.readTextSync(storePath);
      const parsed: StoredChapterEntry[] = JSON.parse(raw) as StoredChapterEntry[];
      // 损坏即弃：解析失败 / 非数组 / 字段不合法的条目逐条跳过，绝不把脏值带进查表
      if (Array.isArray(parsed)) {
        const now: number = Date.now();
        for (let i = 0; i < parsed.length; i++) {
          const item: StoredChapterEntry = parsed[i];
          if (typeof item?.c !== 'string' || item.c.length === 0
            || typeof item.t !== 'number' || !Number.isFinite(item.t)) {
            continue;
          }
          // 装载即清过期：过期条目不再入表，本次运行结束后落盘自然瘦身
          if (now - item.t > CHAPTER_TTL_MS) {
            continue;
          }
          const chapters: VideoChapter[] = sanitizeChapters(item.ch);
          if (chapters.length === 0) {
            continue;
          }
          entries.set(item.c, { c: item.c, ch: chapters, t: item.t });
        }
      }
    }
  } catch (e) {
    console.error(`initChapterCacheStore failed: ${JSON.stringify(e)}`);
    // 装载失败不致命：缓存表从空开始，后续写入照常累积（覆盖写会自愈）
  }
}

function persist(): void {
  if (storePath.length === 0) {
    return;
  }
  let file: fs.File | null = null;
  try {
    const list: StoredChapterEntry[] = [];
    entries.forEach((v: StoredChapterEntry): void => {
      list.push(v);
    });
    file = fs.openSync(storePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, JSON.stringify(list));
  } catch (e) {
    console.error(`persist chapter cache failed: ${JSON.stringify(e)}`);
  } finally {
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (closeErr) {
        console.error(`close chapter cache file failed: ${JSON.stringify(closeErr)}`);
      }
    }
  }
}

function scheduleFlush(): void {
  if (flushTimer !== -1) {
    return;
  }
  flushTimer = setTimeout((): void => {
    flushTimer = -1;
    persist();
  }, FLUSH_DELAY_MS);
}

/**
 * 按 cid 查持久化的分段（内存读，不碰 IO）。
 * 命中且在新鲜期（CHAPTER_TTL_MS）内返回章节数组（新引用）；
 * 过期顺手删除条目并返回 null（下次落盘自然清出文件）；
 * 未 init / 无记录 / 过期均返回 null，调用方回落网络链路。
 */
export function loadCachedChapters(cid: string): VideoChapter[] | null {
  if (cid.length === 0) {
    return null;
  }
  const hit: StoredChapterEntry | undefined = entries.get(cid);
  if (hit === undefined) {
    return null;
  }
  if (Date.now() - hit.t > CHAPTER_TTL_MS) {
    entries.delete(cid);
    return null;
  }
  return hit.ch.slice();
}

/**
 * 保存一首歌的分段并防抖落盘（ChapterStore 在拿到非空分段后调用）。
 * 空数组静默跳过（空结果不持久化，见文件头注释）；条目先消毒再入库。
 * 未 init 静默跳过（卡片进程等场景，读恒 null，无害降级）。
 */
export function saveCachedChapters(cid: string, chapters: VideoChapter[]): void {
  if (cid.length === 0 || storePath.length === 0) {
    return;
  }
  const clean: VideoChapter[] = sanitizeChapters(chapters);
  if (clean.length === 0) {
    return;
  }
  // 先删后插：重插把条目挪到 Map 末尾，淘汰时从最旧（首键）开始
  entries.delete(cid);
  entries.set(cid, { c: cid, ch: clean, t: Date.now() });
  while (entries.size > MAX_ENTRIES) {
    let oldestKey: string = '';
    entries.forEach((v: StoredChapterEntry, k: string): void => {
      if (oldestKey.length === 0) {
        oldestKey = k;
      }
    });
    if (oldestKey.length === 0) {
      break;
    }
    entries.delete(oldestKey);
  }
  scheduleFlush();
}
