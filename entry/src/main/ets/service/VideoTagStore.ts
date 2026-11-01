/**
 * 视频标签缓存 store（听歌日记「周期标签」数据底座）。
 *
 * 背景：PlaySession / Track 均无标签字段，B 站标签需按视频单独拉取
 * （BilibiliApi.getVideoTags）。听歌日记页一个周期最多对 20 个 BV 号
 * 拉标签，且跨周期高度重叠（反复听的歌），必须有本地缓存 —— 否则
 * 每次进页 / 切周期都是 20 连发请求。
 *
 * 持久化：
 *   · filesDir/video_tag_cache.json（单文件全量 JSON，数组保插入序）；
 *   · **绝不进 Preferences**：条目数无上界，8192 字节单值上限必炸
 *     （PlaySessionStore 的同源教训）；
 *   · 条目上限 800：超限从头（最旧插入）裁剪 —— 反复听的歌会因近期
 *     命中而留在内存重新落盘，天然趋近 LRU；
 *   · 保存去抖 500ms（fire-and-forget，失败只记日志）。
 *
 * 失败语义：getVideoTags 抛出（风控 / 断网）→ 本函数向上抛，**不写缓存**；
 * 批量入口 getTagsForBatch 把单条失败记为空数组，不中断整批 ——
 * 「拉不到标签」只影响本次标签云少几个词，绝不影响页面主流程。
 *
 * 线性安全：主线程单线程跑 ArkTS，模块级状态无并发写；磁盘懒加载
 * （首次 getTags 才读盘，读盘 Promise 后续调用直接复用）。
 */

import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import { getVideoTags } from '../api/BilibiliApi';

/** 落盘单条（JSON.parse 的一次性收口目标；数组保插入序供裁剪） */
interface PersistedTagEntry {
  bvid: string;
  tags: string[];
}

/** 缓存文件名（filesDir 下） */
const CACHE_FILE_NAME: string = 'video_tag_cache.json';

/** 条目上限：超限从最旧插入端裁剪 */
const MAX_ENTRIES: number = 800;

/** 保存去抖窗口（ms）：批量拉取的连续写合并成一次落盘 */
const SAVE_DEBOUNCE_MS: number = 500;

/** API 连续失败多少次后熔断（断网 / 被风控时不再空转重打） */
const BREAKER_TRIP_AFTER: number = 3;

/** 熔断冷却窗口（ms）：期间 getTags 直接返回空数组、不发请求，过后自动恢复重试 */
const BREAKER_COOLDOWN_MS: number = 5 * 60 * 1000;

/** 缓存文件绝对路径；空串 = 未 init（getTags 退化为只拉不存） */
let cacheFilePath: string = '';

/** initVideoTagStore 幂等标志 */
let inited: boolean = false;

/** 内存缓存：bvid → tags（空数组 = 该视频确实无标签，同样是有效缓存） */
const cache: Map<string, string[]> = new Map<string, string[]>();

/** 懒加载读盘 Promise（null = 未开始；后续调用复用同一 Promise 防重入） */
let diskLoaded: Promise<void> | null = null;

/** 去抖保存定时器句柄（-1 = 无在途保存） */
let saveTimer: number = -1;

/** API 连续失败计数（成功清零；达到 BREAKER_TRIP_AFTER 触发熔断） */
let apiFailureStreak: number = 0;

/** 熔断截止时间戳（0 = 未熔断；Date.now() < 该值期间不发请求） */
let breakerOpenUntil: number = 0;

/** 落盘（去抖合并；fire-and-forget）：全量快照 + 头部裁剪到上限 */
function scheduleSave(): void {
  if (cacheFilePath.length === 0) {
    return;
  }
  if (saveTimer !== -1) {
    clearTimeout(saveTimer);
  }
  saveTimer = setTimeout((): void => {
    saveTimer = -1;
    // 快照 + 裁剪：超限从头（最旧）截断；Map 迭代序 = 插入序
    const entries: PersistedTagEntry[] = [];
    const all: string[] = Array.from(cache.keys());
    const from: number = Math.max(0, all.length - MAX_ENTRIES);
    for (let i = from; i < all.length; i++) {
      const bvid: string = all[i];
      entries.push({ bvid: bvid, tags: cache.get(bvid) ?? [] });
    }
    const line: string = JSON.stringify(entries);
    writeSnapshot(line);
  }, SAVE_DEBOUNCE_MS);
}

/** 异步写快照文件（覆盖写；失败只记日志，不影响内存缓存） */
function writeSnapshot(line: string): void {
  fs.open(cacheFilePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
    .then((file: fs.File): void => {
      fs.write(file.fd, line)
        .then((): void => {
          fs.close(file);
        })
        .catch((e: Error): void => {
          fs.close(file);
          console.error(`video tag cache write failed: ${e.message}`);
        });
    })
    .catch((e: Error): void => {
      console.error(`video tag cache open failed: ${e.message}`);
    });
}

/** 懒加载读盘：逐条消毒入内存（磁盘条目不覆盖内存已有值 —— 内存是增量的） */
function loadDisk(): Promise<void> {
  return fs.readText(cacheFilePath)
    .then((raw: string): void => {
      try {
        const parsed: PersistedTagEntry[] = JSON.parse(raw) as PersistedTagEntry[];
        if (!Array.isArray(parsed)) {
          return;
        }
        for (let i = 0; i < parsed.length; i++) {
          const e: PersistedTagEntry = parsed[i];
          if (typeof e.bvid === 'string' && e.bvid.length > 0 && Array.isArray(e.tags)
            && !cache.has(e.bvid)) {
            cache.set(e.bvid, e.tags);
          }
        }
      } catch (e) {
        // 文件损坏：按空缓存处理（内存照常工作，下次保存覆盖修复）
      }
    })
    .catch((): void => {
      // 文件不存在（首次使用）：按空缓存处理
    });
}

/** 确保磁盘已加载（未 init / 读盘失败均安静通过，getTags 继续走 API） */
async function ensureDiskLoaded(): Promise<void> {
  if (cacheFilePath.length === 0) {
    return;
  }
  if (diskLoaded === null) {
    diskLoaded = loadDisk();
  }
  await diskLoaded;
}

/**
 * 初始化（EntryAbility.onCreate 调用，幂等）：只记录文件路径，不读盘
 * （懒加载：不用听歌日记就永不产生这一次 IO）。
 */
export function initVideoTagStore(context: common.Context): void {
  if (inited) {
    return;
  }
  inited = true;
  cacheFilePath = `${context.filesDir}/${CACHE_FILE_NAME}`;
}

/**
 * 单视频标签（内存 → 磁盘缓存 → API 拉取）。
 * · 命中缓存（含空数组）直接返回 ——「该视频无标签」同样值得缓存；
 * · 未命中走 getVideoTags：**成功才写缓存 + 去抖落盘，失败原样上抛**
 *   （调用方按需吞掉，不产生脏缓存）；
 * · 熔断保护：API 连续失败 3 次（断网 / 风控）后冷却 5 分钟，期间直接返回
 *   空数组不发请求 —— 否则拾音页每次切周期都对 20 个 BV 号重打 5 轮全失败请求。
 */
export async function getTags(bvid: string): Promise<string[]> {
  if (bvid.length === 0) {
    return [];
  }
  await ensureDiskLoaded();
  const cached: string[] | undefined = cache.get(bvid);
  if (cached !== undefined) {
    return cached;
  }
  if (Date.now() < breakerOpenUntil) {
    return [];
  }
  let tags: string[] = [];
  try {
    tags = await getVideoTags(bvid);
  } catch (e) {
    apiFailureStreak++;
    if (apiFailureStreak >= BREAKER_TRIP_AFTER) {
      breakerOpenUntil = Date.now() + BREAKER_COOLDOWN_MS;
    }
    throw e;
  }
  apiFailureStreak = 0;
  cache.set(bvid, tags);
  scheduleSave();
  return tags;
}

/**
 * 批量取标签（听歌日记页周期标签用）：
 * 按 concurrency 分片逐片并发，单条失败记空数组、不中断整批。
 * 返回 bvid → tags 映射（失败 / 空 bvid 的键不在映射内）。
 */
export async function getTagsForBatch(bvids: string[],
  concurrency: number): Promise<Map<string, string[]>> {
  const result: Map<string, string[]> = new Map<string, string[]>();
  const step: number = Math.max(1, concurrency);
  for (let i = 0; i < bvids.length; i += step) {
    const chunk: string[] = bvids.slice(i, i + step);
    const settled: Array<string[]> = await Promise.all(chunk.map((bvid: string): Promise<string[]> => {
      return getTags(bvid)
        .catch((e: Error): string[] => {
          console.error(`getTags failed (${bvid}): ${e.message}`);
          return [];
        });
    }));
    for (let j = 0; j < chunk.length; j++) {
      if (settled[j].length > 0) {
        result.set(chunk[j], settled[j]);
      }
    }
  }
  return result;
}

/**
 * 立即冲刷（EntryAbility onBackground / onDestroy 调用）：接管在途去抖
 * 定时器立即落盘一次，进程退出前事件循环有机会把 fs 写跑完
 * （flushPlaySessionsNow 的同位钩子）。
 */
export function flushVideoTagsNow(): void {
  if (saveTimer !== -1) {
    clearTimeout(saveTimer);
    saveTimer = -1;
    if (cacheFilePath.length > 0 && cache.size > 0) {
      const entries: PersistedTagEntry[] = [];
      const all: string[] = Array.from(cache.keys());
      const from: number = Math.max(0, all.length - MAX_ENTRIES);
      for (let i = from; i < all.length; i++) {
        const bvid: string = all[i];
        entries.push({ bvid: bvid, tags: cache.get(bvid) ?? [] });
      }
      writeSnapshot(JSON.stringify(entries));
    }
  }
}
