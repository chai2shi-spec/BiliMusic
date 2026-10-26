/**
 * 首页三源（推荐 / 排行榜 / 音乐中心）文件型缓存。
 *
 * 为什么是文件而不是 Preferences：`@ohos.data.preferences` 单值有 8192 字节硬上限，
 * 首页一个 tab 的列表序列化后 10~50KB（排行榜全量 100 条最大），必须走
 * `context.filesDir` 下的独立 JSON 文件。每个 tab 一个固定文件：
 * `{filesDir}/home_feed_cache/{tab}.json`，共 3 个，**无淘汰逻辑**。
 *
 * 用途（启动缓存兜底）：启动先恢复缓存立即出内容（网络不佳时不再只有骨架屏），
 * 联网成功后静默校验替换并重写缓存；完全离线时跳过联网加载，只展示缓存 + 提示。
 *
 * 与 UpSpaceCacheStore 同一套写法：异步读写（避免主线程同步 IO）、损坏即弃
 * （读文件 / JSON.parse / 字段校验任何一步异常都返回 null，绝不把脏数据甩进
 * UI）、模块级 cacheDir 空串静默降级（容忍初始化竞态）。
 *
 * 缓存语义：无 TTL —— 恢复后照常联网刷新，成功即覆写；失败保留缓存内容。
 * 首页三源是匿名数据（buvid 通道，与登录态无关），登出 / 换号无需失效处理。
 */

import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { Track } from '../model/MusicModels';

/** 缓存条目：一个内容 tab 的整表曲目 + 落盘时间 */
export interface HomeFeedCacheEntry {
  /** 内容 tab（'recommend' / 'ranking' / 'center'） */
  tab: string;
  tracks: Track[];
  cachedAtMs: number;
}

/** 合法 tab 白名单（与 HomePage 的 STORE_SEARCH_TAB 三值一致，也防 tab 拼进意外文件名） */
const HOME_FEED_TABS: string[] = ['recommend', 'ranking', 'center'];

/** 缓存目录（EntryAbility 在 loadIndexPage 前同步初始化） */
let cacheDir: string = '';

/** 初始化缓存目录：建目录（已存在则跳过）。同步无 await，失败置空降级为「无缓存」。 */
export function initHomeFeedCache(context: common.Context): void {
  try {
    cacheDir = `${context.filesDir}/home_feed_cache`;
    if (!fs.accessSync(cacheDir)) {
      fs.mkdirSync(cacheDir, true);
    }
  } catch (e) {
    // 目录建不出来（沙箱异常）：置空目录标记，后续读写全部静默降级为「无缓存」
    console.error(`initHomeFeedCache failed: ${JSON.stringify(e)}`);
    cacheDir = '';
  }
}

/** 读缓存：命中返回条目，无缓存 / 损坏 / 未初始化 / 非法 tab 一律返回 null。 */
export async function getHomeFeedCache(tab: string): Promise<HomeFeedCacheEntry | null> {
  if (cacheDir.length === 0 || HOME_FEED_TABS.indexOf(tab) < 0) {
    return null;
  }
  const path: string = `${cacheDir}/${tab}.json`;
  let raw: string = '';
  try {
    raw = await fs.readText(path);
  } catch (e) {
    // 文件不存在（首次启动）属常态；读失败一律当作无缓存
    return null;
  }
  if (raw.length === 0) {
    return null;
  }
  try {
    const parsed = JSON.parse(raw) as HomeFeedCacheEntry;
    // parsed 为 null 时下面的属性访问直接抛 → catch 兜住返回 null，无需前置真值判断
    if (parsed.tab !== tab || !Array.isArray(parsed.tracks) || parsed.tracks.length === 0) {
      return null;
    }
    // 逐条校验 + 按 id 去重（保留首次出现位置，脏缓存自愈）；全被滤掉视为缓存无效
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
    return {
      tab: parsed.tab,
      tracks: tracks,
      cachedAtMs: typeof parsed.cachedAtMs === 'number' ? parsed.cachedAtMs : 0
    };
  } catch (e) {
    console.error(`parse home feed cache failed (tab=${tab}): ${JSON.stringify(e)}`);
    return null;
  }
}

/**
 * 写缓存：异步整文件覆写（TRUNC），失败只打日志不影响页面。
 * tracks 为空直接跳过 —— 空列表不具缓存价值，也避免把「加载失败」落成空缓存
 * 覆盖上一份好数据。
 */
export async function saveHomeFeedCache(tab: string, tracks: Track[]): Promise<void> {
  if (cacheDir.length === 0 || HOME_FEED_TABS.indexOf(tab) < 0 || tracks.length === 0) {
    return;
  }
  const path: string = `${cacheDir}/${tab}.json`;
  const entry: HomeFeedCacheEntry = { tab: tab, tracks: tracks, cachedAtMs: Date.now() };
  try {
    const json: string = JSON.stringify(entry);
    const file: fs.File = await fs.open(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      await fs.write(file.fd, json);
    } finally {
      await fs.close(file);
    }
  } catch (e) {
    console.error(`saveHomeFeedCache failed (tab=${tab}): ${JSON.stringify(e)}`);
  }
}
