/**
 * UP 主页缓存（文件型落盘存储）。
 *
 * 为什么是文件而不是 Preferences：`@ohos.data.preferences` 单值有 **8192 字节硬上限**
 * （LibraryStore 为此给歌单做了分片），而 UP 一页投稿 30~50 条序列化后 15~25KB，
 * 必须走 `context.filesDir` 下的独立 JSON 文件。每个 UP 一个文件：
 * `{filesDir}/up_space_cache/{upMid}.json`，最多保留 MAX_CACHED_UPS 个，超出按
 * 文件 mtime 淘汰最旧（按 mtime 而非 cachedAtMs：不用逐个解析文件内容）。
 *
 * 读写均为同步（openSync / readTextSync / writeSync）：单文件 15~50KB，毫秒级，
 * 分别发生在进页（aboutToAppear）与请求成功回调里，用户无感；实测若出现卡顿再改异步。
 *
 * 损坏即弃：读文件 / JSON.parse / 字段校验任何一步异常都返回 null —— 缓存坏了
 * 就当作没有缓存，页面照常联网拉取，绝不把脏数据甩进 UI（SearchHistoryStore 的
 * sanitize 纪律同款）。
 *
 * 缓存语义（2026-10-09 需求）：再次进入 UP 主页**不自动联网刷新**，直接显示缓存；
 * 只有「拉取新投稿」按钮与列表下拉刷新才联网更新并重写缓存。无 TTL ——
 * 用户显式刷新即视为最新。
 */

import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { Track } from '../model/MusicModels';

/** 缓存条目：投稿列表 + 分页游标 + UP 资料，一并落盘 */
export interface UpSpaceCacheEntry {
  upMid: string;
  upName: string;
  upFace: string;
  fans: number;
  /** 已加载的全部曲目（含翻页追加） */
  tracks: Track[];
  /** 最后成功页码（恢复后从 page+1 续拉） */
  page: number;
  hasMore: boolean;
  /** 最近一次取投稿走的路（BilibiliApi.UP_VIA_*，恢复失败文案用） */
  sourceVia: number;
  cachedAtMs: number;
}

/** 最多缓存的 UP 个数（超出按文件 mtime 淘汰最旧；单个 UP 极端 ~150KB，总量 ~1.8MB 封顶） */
const MAX_CACHED_UPS: number = 12;

/** 缓存目录（AppContainer.init 里初始化） */
let cacheDir: string = '';

/** 初始化缓存目录：建目录（已存在则跳过）。AppContainer.init 调用，同步无 await。 */
export function initUpSpaceCache(context: common.Context): void {
  try {
    cacheDir = `${context.filesDir}/up_space_cache`;
    if (!fs.accessSync(cacheDir)) {
      fs.mkdirSync(cacheDir, true);
    }
  } catch (e) {
    // 目录建不出来（沙箱异常）：置空目录标记，后续读写全部静默降级为「无缓存」
    console.error(`initUpSpaceCache failed: ${JSON.stringify(e)}`);
    cacheDir = '';
  }
}

/** 读缓存：命中返回归一化条目，无缓存 / 损坏 / 未初始化一律返回 null。 */
export function getUpSpaceCache(upMid: string): UpSpaceCacheEntry | null {
  if (cacheDir.length === 0 || upMid.length === 0) {
    return null;
  }
  const path: string = `${cacheDir}/${upMid}.json`;
  let raw: string = '';
  try {
    raw = fs.readTextSync(path);
  } catch (e) {
    // 文件不存在（首次进入）属常态；读失败一律当作无缓存
    return null;
  }
  if (raw.length === 0) {
    return null;
  }
  try {
    const parsed = JSON.parse(raw) as UpSpaceCacheEntry;
    // parsed 为 null 时下面的属性访问直接抛 → catch 兜住返回 null，无需前置真值判断
    if (parsed.upMid !== upMid || !Array.isArray(parsed.tracks) || parsed.tracks.length === 0) {
      return null;
    }
    // 按 id 去重（保留首次出现位置，2026-10-11 修）：修复前「翻页恒取第 1 页」的
    // 版本会往缓存里写进重复条目 —— 恢复时在这里自愈，重进页面重复即消失；
    // 之后任意一次成功刷新整表覆写，落盘的就是干净数据。全被滤掉视为缓存无效。
    const rawTracks: Track[] = parsed.tracks;
    const seenIds: Set<string> = new Set<string>();
    const tracks: Track[] = [];
    for (let i = 0; i < rawTracks.length; i++) {
      const t: Track = rawTracks[i];
      if (!t || typeof t.id !== 'string' || t.id.length === 0 || seenIds.has(t.id)) {
        continue;
      }
      seenIds.add(t.id);
      tracks.push(t);
    }
    if (tracks.length === 0) {
      return null;
    }
    // 数值字段防御性兜底：旧版本 / 手改坏的 JSON 不许把 NaN 带进分页游标
    return {
      upMid: parsed.upMid,
      upName: typeof parsed.upName === 'string' ? parsed.upName : '',
      upFace: typeof parsed.upFace === 'string' ? parsed.upFace : '',
      fans: typeof parsed.fans === 'number' ? parsed.fans : 0,
      tracks: tracks,
      page: typeof parsed.page === 'number' && parsed.page >= 1 ? parsed.page : 1,
      hasMore: typeof parsed.hasMore === 'boolean' ? parsed.hasMore : false,
      sourceVia: typeof parsed.sourceVia === 'number' ? parsed.sourceVia : 0,
      cachedAtMs: typeof parsed.cachedAtMs === 'number' ? parsed.cachedAtMs : 0
    };
  } catch (e) {
    console.error(`parse up space cache failed (upMid=${upMid}): ${JSON.stringify(e)}`);
    return null;
  }
}

/**
 * 写缓存：同步整文件覆写（TRUNC），失败只打日志不影响页面。
 * 顺带执行淘汰：超出 MAX_CACHED_UPS 个文件时删最旧。
 */
export function saveUpSpaceCache(entry: UpSpaceCacheEntry): void {
  if (cacheDir.length === 0 || entry.upMid.length === 0 || entry.tracks.length === 0) {
    return;
  }
  const path: string = `${cacheDir}/${entry.upMid}.json`;
  try {
    const json: string = JSON.stringify(entry);
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, json);
    } finally {
      fs.closeSync(file);
    }
  } catch (e) {
    console.error(`saveUpSpaceCache failed (upMid=${entry.upMid}): ${JSON.stringify(e)}`);
    return;
  }
  evictOverCapacity();
}

/** 缓存文件时间戳（淘汰排序用；ArkTS 不支持元组，用显式接口） */
interface CacheFileStamp {
  name: string;
  mtimeMs: number;
}

/** 淘汰：缓存文件数超出上限时按 mtime 删最旧（本次刚写的文件 mtime 最新，不会被删）。 */
function evictOverCapacity(): void {
  try {
    const names: string[] = fs.listFileSync(cacheDir);
    const jsonNames: string[] = names.filter((n: string): boolean => n.endsWith('.json'));
    if (jsonNames.length <= MAX_CACHED_UPS) {
      return;
    }
    const stamps: CacheFileStamp[] = [];
    for (let i = 0; i < jsonNames.length; i++) {
      try {
        const stat: fs.Stat = fs.statSync(`${cacheDir}/${jsonNames[i]}`);
        // SDK 的 Stat 只有 mtime（秒），没有 mtimeMs —— 秒级精度对「删最旧」足够
        const stamp: CacheFileStamp = { name: jsonNames[i], mtimeMs: stat.mtime };
        stamps.push(stamp);
      } catch (e) {
        // 单个文件 stat 失败（并发被删等）：跳过它，不影响整体淘汰
      }
    }
    stamps.sort((a: CacheFileStamp, b: CacheFileStamp): number => a.mtimeMs - b.mtimeMs);
    const toDelete: number = stamps.length - MAX_CACHED_UPS;
    for (let i = 0; i < toDelete; i++) {
      try {
        fs.unlinkSync(`${cacheDir}/${stamps[i].name}`);
      } catch (e) {
        console.error(`evict up space cache failed (${stamps[i].name}): ${JSON.stringify(e)}`);
      }
    }
  } catch (e) {
    console.error(`list up space cache dir failed: ${JSON.stringify(e)}`);
  }
}
