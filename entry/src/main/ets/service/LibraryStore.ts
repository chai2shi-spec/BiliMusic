/**
 * 媒体库存储（收藏 / 歌单 / 最近播放 / 删除墓碑）。
 * 存储后端为 Preferences（JSON）。
 */

import { AppPreferences } from '../preferences/AppPreferences';
import { DEFAULT_PLAYLIST_NAME, PREF_FAVORITES, PREF_PLAYLISTS, PREF_RECENT, STORE_LIBRARY_REV } from '../common/Constants';
import {
  PREF_VALUE_BUDGET_BYTES,
  Playlist,
  slimTrack,
  Tombstone,
  Track,
  utf8Length
} from '../model/MusicModels';
import { isFolderTwoway } from './FavTwowayStore';
import { enqueueFavPushes, FavPushIntent, purgeFavPushesForFolder } from './FavPushStore';
import { scheduleFavPushFlush } from './FavPushRunner';
import { HomeCardStore } from './HomeCardStore';

function createId(): string {
  return `pl_${Date.now()}_${Math.floor(Math.random() * 1e9).toString(36)}`;
}

/**
 * 最近播放的条数上限（分片存储后即为**真实**上限）。
 * 分片存储（每片 8 条 × 最多 13 片，同歌单 `pl_tracks_*` 模式）后单值上限
 * 不再约束总量，100 即真实封顶；读侧按 ceil(RECENT_MAX_ITEMS/8) 探测分片，
 * 存量数据零迁移、扩容后自然读满。
 */
const RECENT_MAX_ITEMS: number = 100;

/**
 * 最近播放**分片存储**：曲目按每片 8 条拆到 `recent_tracks_{n}` 独立 key。
 *
 * 为什么分片（理由同 PLAYLIST_CHUNK_ITEMS）：`@ohos.data.preferences` 单个
 * value 有 8192 字节硬上限。slimTrack 后一条实测约 560 字节（含
 * pubdate / playedAt / lastPosSec）→ 整份列表塞一个 key 时超过约 11 条就
 * 写不进去，表现为「播得越多、重启后只剩 11 条」。8 × 560 ≈ 4.5KB，
 * 离 6000 字节预算有余量；最多 ceil(100/8)=13 片。
 */
const RECENT_CHUNK_ITEMS: number = 8;
const RECENT_CHUNK_PREFIX: string = 'recent_tracks_';

/**
 * 最近播放保留时间窗：只保存最近 7 天的播放记录。
 *
 * 过滤发生在 getRecentTracks（读取侧真源），过期记录不再出现在
 * 「最近播放」页 / 设置页计数里；随下一次 addRecentTrack 落盘被整体清出存储。
 * playedAt = 0 的旧记录（升级前落盘、无时间戳）视为窗口内保留：
 * 升级瞬间静默清空用户已有记录是不可接受的数据丢失，
 * 它们会在下次重播时被重新盖章、重新进入 7 天倒计时。
 */
const RECENT_KEEP_MS: number = 7 * 24 * 60 * 60 * 1000;

/**
 * 一条记录是否仍在「最近 7 天」窗口内。
 * `!(t.playedAt > 0)` 而不是 `t.playedAt === 0`：旧数据 / 反序列化产物
 * 该字段可能是 undefined，按 0 同样兜进「保留」分支。
 */
function isWithinRecentWindow(t: Track): boolean {
  return !(t.playedAt > 0) || Date.now() - t.playedAt < RECENT_KEEP_MS;
}

/**
 * 最近播放内存快照。
 *
 * 两个必须的理由：
 *  1) `AppPreferences` 落盘是异步（put + flush），而读取走同步 `getSync`，
 *     写完立刻读会拿到旧值 —— 表现为「刚播完的歌进「最近播放」看不到」。
 *     与 `playlistCache` 同源问题，处理方式保持一致：缓存即真源，写操作先换缓存再异步落盘。
 *  2) Preferences 单值有 8192 字节上限，上百首曲目序列化后必然超限 ——
 *     落盘前统一 slimTrack + 分片存储（每片 8 条，见 RECENT_CHUNK_ITEMS）。
 */
let recentCache: Track[] | null = null;

/** 上次落盘的最近播放分片数：条目变少时据此清掉多余分片 key（防磁盘残留增长） */
let lastRecentChunkCount: number = 0;

/** 本次会话是否从旧格式（PREF_RECENT 单键 Track[]）加载：下次落盘成功后清理旧键 */
let legacyRecentLoaded: boolean = false;

/**
 * 判断一条记录是否可用。
 *
 * 为什么需要：`slimTrack()` 会直接读 `track.id`，列表里只要混进一个 null / 非对象，
 * 整次写入就会抛 TypeError —— 而抛在上面的后果是「一条都存不下来」，
 * 表现是「最近播放永远是空的」。脏数据（旧版本写坏的 Preferences）必须先滤掉。
 */
function isPersistableTrack(t: Track): boolean {
  return t !== null && t !== undefined && typeof t.id === 'string' && t.id.length > 0;
}

function sanitizeTracks(raw: Track[]): Track[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw.filter((t: Track): boolean => isPersistableTrack(t));
}

/**
 * 从分片 key 读回最近播放（读到 miss 为止，最多探测 ceil(RECENT_MAX_ITEMS/8) 片）。
 *
 * 无 meta 键（最近播放没有歌单 PREF_PLAYLISTS 那样的元信息载体）：
 * 第 0 片 miss 即视为「无分片数据」返回 null，调用方回落旧格式；
 * 同时把探测到的片数记入 `lastRecentChunkCount`，供下次落盘清理多余分片。
 */
function loadRecentChunks(): Track[] | null {
  const maxChunks: number = Math.ceil(RECENT_MAX_ITEMS / RECENT_CHUNK_ITEMS);
  let found: boolean = false;
  const out: Track[] = [];
  for (let i = 0; i < maxChunks; i++) {
    const part: Track[] | null = AppPreferences.getObject<Track[]>(`${RECENT_CHUNK_PREFIX}${i}`);
    if (!part || !Array.isArray(part)) {
      break;
    }
    found = true;
    for (let k = 0; k < part.length; k++) {
      out.push(part[k]);
    }
    lastRecentChunkCount = i + 1;
  }
  return found ? out : null;
}

export function getRecentTracks(): Track[] {
  if (recentCache === null) {
    // 优先分片格式；无分片数据时回落旧格式
    // （PREF_RECENT 单键 Track[]），旧数据在下次落盘时迁入分片并清理旧键
    // （见 persistRecentTracks 的迁移收尾）。
    const chunked: Track[] | null = loadRecentChunks();
    if (chunked !== null) {
      recentCache = sanitizeTracks(chunked);
    } else {
      legacyRecentLoaded = true;
      // 磁盘上的值可能不是数组（旧版本写过别的结构 / 手工改坏），
      // 这里必须归一化：否则 `recentCache.slice()` 会直接抛，页面永远停在空态。
      recentCache = sanitizeTracks(AppPreferences.getRecentTracks<Track>());
    }
  }
  // 只返回「最近 7 天」窗口内的记录（filter 已生成副本，无需再 slice）。
  // 过期记录不从缓存里删：等下一次写入（add/remove/clear）把它挤出存储，
  // 读取侧每次都过滤，界面永远看不到过期条目。
  return recentCache.filter((t: Track): boolean => isWithinRecentWindow(t));
}

function persistRecentTracks(list: Track[], notify: boolean = true): void {
  const capped: Track[] = sanitizeTracks(list).slice(0, RECENT_MAX_ITEMS);

  // ⚠️ 顺序很重要：**先换内存快照，再序列化落盘**。
  // 反过来（先 slimTrack / 分片再更新快照）时，只要序列化那一步抛异常，
  // 快照就保持旧值 —— 界面表现为「播放正常，但最近播放里一条记录都没有」。
  // 内存快照是读取侧的真源，必须无条件先落地。
  recentCache = capped;

  try {
    // 分片落盘（同歌单 pl_tracks_* 模式）：每片 8 条 slimTrack 后的曲目
    // ≈ 4.5KB，单值 8192 上限不再约束总量，100 条全部可持久化。
    // 分片攒进一个 Record 走 putMany（一次 flush），避免每片各自 put + flush
    // 造成十几次全量落盘。
    const slim: Track[] = capped.map((t: Track): Track => slimTrack(t));
    const chunkCount: number = Math.ceil(slim.length / RECENT_CHUNK_ITEMS);
    const writes: Record<string, string> = {};
    for (let c = 0; c < chunkCount; c++) {
      const part: Track[] = slim.slice(c * RECENT_CHUNK_ITEMS, (c + 1) * RECENT_CHUNK_ITEMS);
      // 保险检查（不截断，对齐歌单行为）：单片超预算只告警 —— 单条畸形肥数据
      // 实际不可能逼近 8192，真发生时日志能定位到具体片。
      if (utf8Length(JSON.stringify(part)) > PREF_VALUE_BUDGET_BYTES) {
        console.warn(`recent chunk ${c} exceeds budget: ${part.length} items`);
      }
      writes[`${RECENT_CHUNK_PREFIX}${c}`] = JSON.stringify(part);
    }
    AppPreferences.putMany(writes).catch((e: Error): void => {
      // 落盘失败只影响「重启后还在不在」，不影响本次会话的展示
      console.error(`save recent chunks failed: ${e.message}`);
    });
    // 条目变少时清掉多余分片，否则旧 key 会一直占着磁盘
    //（连旧键迁移一起攒进 removeMany，一次 flush 清完）
    const removes: string[] = [];
    for (let c = chunkCount; c < lastRecentChunkCount; c++) {
      removes.push(`${RECENT_CHUNK_PREFIX}${c}`);
    }
    lastRecentChunkCount = chunkCount;
    // 迁移收尾：旧格式（PREF_RECENT 单键）数据已随上面的分片写入迁完，
    // 删掉旧键释放约 6KB；此后读写全走分片。删除失败无碍 —— 读侧优先分片，
    // 残留旧键只是死数据，不影响行为。
    if (legacyRecentLoaded) {
      legacyRecentLoaded = false;
      removes.push(PREF_RECENT);
    }
    if (removes.length > 0) {
      AppPreferences.removeMany(removes).catch((e: Error): void => {
        console.error(`remove recent chunk keys failed: ${e.message}`);
      });
    }
  } catch (e) {
    const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
    console.error(`build recent payload failed: ${detail}`);
  }
  // 通知「最近播放」页 / 歌单页重新拉取（否则新增记录后切页看不到）。
  // notify=false：位置静默更新（updateRecentProgress）不触发列表刷新——
  // 播放中约 10s 一次的位置写入若 bump 版本号，最近播放页会整表重载闪动。
  if (notify) {
    notifyLibraryChanged();
  }
}

export function addRecentTrack(track: Track): void {
  if (!isPersistableTrack(track)) {
    console.error('addRecentTrack ignored: invalid track');
    return;
  }
  // 盖「本次播放时间」章：最近播放页的 7 天时间窗靠它（见 isWithinRecentWindow）。
  // 写在入参对象上是有意的 —— 该对象即播放内核的当前曲目，盖章后随队列 /
  // 播放状态一起落盘，重启恢复的记录不会退化成 playedAt = 0。
  track.playedAt = Date.now();
  const recent: Track[] = getRecentTracks().filter((t: Track): boolean => t.id !== track.id);
  // 与参考实现一致：按 id 去重后插到最前（最近听的在最上面）；
  // 基底取自 getRecentTracks（已过滤 7 天窗口），过期记录随本次落盘一并清出。
  recent.unshift(track);
  persistRecentTracks(recent);
  console.info(`recent track added: ${track.id} (total ${getRecentTracks().length})`);
}

export function removeRecentTrack(id: string): Track[] {
  const next: Track[] = getRecentTracks().filter((t: Track): boolean => t.id !== id);
  persistRecentTracks(next);
  return getRecentTracks();
}

export function clearRecentTracks(): void {
  persistRecentTracks([]);
}

/**
 * 静默更新某条最近播放记录的上次播放位置（秒）。
 *
 * 由 MusicPlayer.recordRecentProgress 节流调用（约 10s 一次 + 关键事件强制）：
 * 只更新内存快照中该条目的 lastPosSec 并异步落盘，不 bump STORE_LIBRARY_REV
 * （位置变化不需要重载列表页，避免播放中整表刷新闪动）。
 * 条目不在 7 天窗口内（缓存中找不到）时静默返回 —— 位置记忆只随
 * 「最近播放」条目存在，过期 / 移除 / 清空的清理随条目整体发生，零额外逻辑。
 */
export function updateRecentProgress(id: string, posSec: number): void {
  if (typeof id !== 'string' || id.length === 0) {
    return;
  }
  const list: Track[] = getRecentTracks();
  for (let i = 0; i < list.length; i++) {
    if (list[i].id === id) {
      list[i].lastPosSec = Math.max(0, Math.round(posSec));
      persistRecentTracks(list, false);
      return;
    }
  }
}

/**
 * 读取某条最近播放记录的上次播放位置（秒）。
 * 无记录 / 不在 7 天窗口内 / 旧版本数据无该字段 → 一律返回 0（从头播）。
 */
export function getRecentProgressSec(id: string): number {
  const list: Track[] = getRecentTracks();
  for (let i = 0; i < list.length; i++) {
    if (list[i].id === id) {
      return list[i].lastPosSec ?? 0;
    }
  }
  return 0;
}

/**
 * 收藏内存快照。
 *
 * 与 recentCache 同源的两个理由：
 *  1) `AppPreferences` 异步落盘、读取走同步 `getSync` → 连续快速切换
 *     收藏会基于陈旧数组写回，**丢条目**；
 *  2) 收藏采用分片存储 `favorite_tracks_{n}`（同 recent_tracks_* / pl_tracks_*
 *     模式）：Preferences 单值有 8192 字节硬上限，整份列表塞单 key 必然超限，
 *     分片后单值上限不再约束总量，收藏多少存多少。
 */
let favoriteCache: Track[] | null = null;

/**
 * 收藏**分片存储**：曲目按每片 8 条拆到
 * `favorite_tracks_{n}` 独立 key（slimTrack 后一条约 520 字节，8 条 ≈ 4.2KB，
 * 离 6000 字节预算有余量）。
 */
const FAVORITE_CHUNK_ITEMS: number = 8;
const FAVORITE_CHUNK_PREFIX: string = 'favorite_tracks_';
/**
 * 收藏读取探测上限（片）：读到 miss 为止，此值只防 key 被手工改坏时的死循环；
 * 128 片 = 1024 条，远超真实使用量。
 */
const FAVORITE_CHUNK_PROBE_MAX: number = 128;

/** 上次落盘的收藏分片数：条目变少时据此清掉多余分片 key（防磁盘残留增长） */
let lastFavoriteChunkCount: number = 0;

/** 本次会话是否从旧格式（PREF_FAVORITES 单键 Track[]）加载：下次落盘成功后清理旧键 */
let legacyFavoriteLoaded: boolean = false;

/**
 * 从分片 key 读回收藏（读到 miss 为止）。
 *
 * 无分片数据（第 0 片 miss）返回 null，调用方回落旧格式 PREF_FAVORITES；
 * 同时把探测到的片数记入 `lastFavoriteChunkCount`，供下次落盘清理多余分片。
 */
function loadFavoriteChunks(): Track[] | null {
  let found: boolean = false;
  const out: Track[] = [];
  for (let i = 0; i < FAVORITE_CHUNK_PROBE_MAX; i++) {
    const part: Track[] | null = AppPreferences.getObject<Track[]>(`${FAVORITE_CHUNK_PREFIX}${i}`);
    if (!part || !Array.isArray(part)) {
      break;
    }
    found = true;
    for (let k = 0; k < part.length; k++) {
      out.push(part[k]);
    }
    lastFavoriteChunkCount = i + 1;
  }
  return found ? out : null;
}

export function getFavoriteTracks(): Track[] {
  if (favoriteCache === null) {
    // 优先分片格式；无分片数据时回落旧格式（PREF_FAVORITES 单键），
    // 旧数据在下次落盘时迁入分片并清理旧键（见 persistFavoriteTracks 的迁移收尾）
    const chunked: Track[] | null = loadFavoriteChunks();
    if (chunked !== null) {
      favoriteCache = sanitizeTracks(chunked);
    } else {
      legacyFavoriteLoaded = true;
      favoriteCache = sanitizeTracks(AppPreferences.getFavoriteTracks<Track>());
    }
  }
  // 返回副本：调用方持有内部数组时，改列表不会触发 @State 刷新（同 getRecentTracks）
  return favoriteCache.slice();
}

/**
 * 收藏落盘：结构与 persistRecentTracks 逐条对应（分片写 + 多余分片清理 + 旧键迁移）。
 *
 * 签名保持 `void`（不返回 promise）—— 返回 Track[] 的老用法被播放内核 `toggleLike`
 * 当同步值用；落盘失败只影响「重启后还在不在」，必须由本函数内部 catch 掉，
 * 不能把rejection 抛给调用方（它没接 catch）。
 */
function persistFavoriteTracks(list: Track[]): void {
  const capped: Track[] = sanitizeTracks(list);

  // ⚠️ 顺序同persistRecentTracks：**先换内存快照，再序列化落盘**。
  // 序列化抛异常时快照保持旧值 —— 但那是可接受的降级（内存里还在，重启才丢）；
  // 反过来先序列化再换快照，抛了就等于界面也丢，更糟。
  favoriteCache = capped;

  try {
    // 分片落盘：收藏是用户主动攒的数据，绝不 fitByByteBudget 静默截断；
    // 分片后单值 8192 上限不再约束总量。分片攒进一个 Record 走 putMany
    // （一次 flush），避免每片各自 put + flush 造成上百次全量落盘。
    const slim: Track[] = capped.map((t: Track): Track => slimTrack(t));
    const chunkCount: number = Math.ceil(slim.length / FAVORITE_CHUNK_ITEMS);
    const writes: Record<string, string> = {};
    for (let c = 0; c < chunkCount; c++) {
      const part: Track[] = slim.slice(c * FAVORITE_CHUNK_ITEMS, (c + 1) * FAVORITE_CHUNK_ITEMS);
      // 保险检查（不截断，对齐歌单行为）：单片超预算只告警 —— 单条畸形肥数据
      // 实际不可能逼近 8192，真发生时日志能定位到具体片。
      if (utf8Length(JSON.stringify(part)) > PREF_VALUE_BUDGET_BYTES) {
        console.warn(`favorite chunk ${c} exceeds budget: ${part.length} items`);
      }
      writes[`${FAVORITE_CHUNK_PREFIX}${c}`] = JSON.stringify(part);
    }
    AppPreferences.putMany(writes).catch((e: Error): void => {
      console.error(`save favorite chunks failed: ${e.message}`);
    });
    // 条目变少时清掉多余分片，否则旧 key 会一直占着磁盘
    //（连旧键迁移一起攒进 removeMany，一次 flush 清完）
    const removes: string[] = [];
    for (let c = chunkCount; c < lastFavoriteChunkCount; c++) {
      removes.push(`${FAVORITE_CHUNK_PREFIX}${c}`);
    }
    lastFavoriteChunkCount = chunkCount;
    // 迁移收尾：旧格式（PREF_FAVORITES 单键）数据已随上面的分片写入迁完，
    // 删掉旧键释放空间；此后读写全走分片。删除失败无碍 —— 读侧优先分片，
    // 残留旧键只是死数据，不影响行为。
    if (legacyFavoriteLoaded) {
      legacyFavoriteLoaded = false;
      removes.push(PREF_FAVORITES);
    }
    if (removes.length > 0) {
      AppPreferences.removeMany(removes).catch((e: Error): void => {
        console.error(`remove favorite chunk keys failed: ${e.message}`);
      });
    }
  } catch (e) {
    const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
    console.error(`build favorite payload failed: ${detail}`);
  }
  // 通知收藏相关界面刷新（目前只有播放页的红心，逻辑上仍要走统一广播）
  notifyLibraryChanged();
}

export function toggleFavoriteTrack(track: Track): Track[] {
  if (!isPersistableTrack(track)) {
    console.error('toggleFavoriteTrack ignored: invalid track');
    return getFavoriteTracks();
  }
  const favs: Track[] = getFavoriteTracks();
  const idx: number = favs.findIndex((t: Track): boolean => t.id === track.id);
  if (idx >= 0) {
    favs.splice(idx, 1);
    addFavoriteTombstone(track.id);
  } else {
    favs.unshift(Object.assign({}, track, { isLiked: true, likedAt: new Date().toISOString() }));
    removeFavoriteTombstone(track.id);
  }
  persistFavoriteTracks(favs);
  return getFavoriteTracks();
}

/**
 * 歌单内存快照。
 * `AppPreferences.savePlaylists` 是异步落盘（put + flush），而读取走的是同步 `getSync`。
 * 删除 / 重命名后紧接着刷新列表，会存在「异步写还没完成、同步读拿到旧值」的竞态，
 * 表现为点了删除歌单还在。这里把内存缓存作为唯一真源：写操作先换掉缓存再异步落盘。
 */
let playlistCache: Playlist[] | null = null;

/**
 * 歌单曲目**分片存储**。
 *
 * 为什么要分片：`@ohos.data.preferences` 单个 value 有 **8192 字节硬上限**，超了 `put()`
 * 直接抛错。而 slimTrack 后的**一条曲目实测约 519 字节**（字段名与引号占大头，
 * 封面 URL 单独就 ~70 字节）→ 整张歌单塞进一个 key 时，
 * **超过约 11 首就写不进去**，表现是「加了歌，重启后消失」。
 * 所以：元信息（名字/封面/时间/订阅来源）留在 PREF_PLAYLISTS，曲目按每片 8 条拆到
 * `pl_tracks_{歌单id}_{片号}` 独立 key。8 × 519 ≈ 4.1KB，离 6000 字节预算还有余量。
 */
const PLAYLIST_CHUNK_ITEMS: number = 8;
/** 单个歌单最多存多少首（兜底上限）。
 * 分片按固定 PLAYLIST_CHUNK_ITEMS 条/片切，单片尺寸与总量无关（仍 ~4.1KB，离单 value
 * 8192 字节硬上限远）；10000 首 ≈ 1250 片 ≈ 5.2MB/歌单，防无节制增长仍保留兜底 */
export const PLAYLIST_MAX_ITEMS: number = 10000;
const PL_TRACKS_PREFIX: string = 'pl_tracks_';

/**
 * 磁盘上的歌单条目。
 *
 * `tracks` 只在**旧版本**写出的数据里存在（那时曲目与元信息同处 PREF_PLAYLISTS 一个 key）；
 * 新版本曲目在分片里，这个字段读出来是 undefined → 据此区分新旧格式并向下兼容，
 * 用户升级后老歌单不会变成空歌单。
 */
interface StoredPlaylist {
  id: string;
  name: string;
  description: string;
  coverUrl: string;
  createdAt: string;
  updatedAt: string;
  upMid: string;
  upName: string;
  /**
   * 来源种类（可选：老数据没这个字段 → toPlaylist 兜底为 upMid 非空 ? 'up' : ''）。
   * ⚠️ 必须落盘：漏了它，重启后收藏夹镜像会退化成「订阅 UP 歌单」，
   * 歌单详情错显「订阅自」并冒出「拉取新投稿」入口（同 upMid/titleSorted 的坑）。
   */
  sourceKind?: string;
  /**
   * 「按名称排序」规则标记（可选：老数据没这个字段 = undefined = 未开启）。
   * 必须落盘 —— 漏了它，重启后该歌单就退回「新增追加到末尾」，规则静默失效。
   */
  titleSorted?: boolean;
  /** 曲目分片数，0 = 曲目在旧格式的 tracks 字段里 */
  chunkCount: number;
  tracks?: Track[];
}

function chunkKeyOf(playlistId: string, index: number): string {
  return `${PL_TRACKS_PREFIX}${playlistId}_${index}`;
}

/** 元信息 + 分片曲目 → 内存里的 Playlist */
function toPlaylist(stored: StoredPlaylist): Playlist {
  const chunkCount: number = stored.chunkCount ?? 0;
  let tracks: Track[] = [];
  if (chunkCount > 0) {
    for (let i = 0; i < chunkCount; i++) {
      const part: Track[] | null = AppPreferences.getObject<Track[]>(chunkKeyOf(stored.id, i));
      if (part && Array.isArray(part)) {
        tracks = tracks.concat(part);
      }
    }
  } else if (stored.tracks && Array.isArray(stored.tracks)) {
    // 旧格式：曲目就在元信息里
    tracks = stored.tracks;
  }
  return {
    id: stored.id,
    name: stored.name ?? '',
    description: stored.description ?? '',
    coverUrl: stored.coverUrl ?? '',
    createdAt: stored.createdAt ?? '',
    updatedAt: stored.updatedAt ?? '',
    upMid: stored.upMid ?? '',
    upName: stored.upName ?? '',
    // 老数据没 sourceKind → 兜底：upMid 非空即视为 UP 订阅（引入该字段前唯一来源就是订阅）。
    // 注意不能在 toPlaylist 之后再按 upMid 猜，那样收藏夹镜像（upMid='fav_x'）会被误判成订阅。
    sourceKind: stored.sourceKind ?? ((stored.upMid && stored.upMid.length > 0) ? 'up' : ''),
    // 老数据没这个字段 → undefined → 视为未排序（符合「存量数据不管」）
    titleSorted: stored.titleSorted === true,
    tracks: sanitizeTracks(tracks)
  };
}

export function getPlaylists(): Playlist[] {
  if (playlistCache === null) {
    const stored: StoredPlaylist[] = AppPreferences.getPlaylists<StoredPlaylist>();
    const list: Playlist[] = [];
    if (Array.isArray(stored)) {
      for (let i = 0; i < stored.length; i++) {
        const item: StoredPlaylist = stored[i];
        if (item && typeof item.id === 'string' && item.id.length > 0) {
          list.push(toPlaylist(item));
        }
      }
    }
    playlistCache = list;
  }
  // 返回副本：避免调用方持有内部数组导致改列表不触发 @State 刷新
  return playlistCache.slice();
}

// ===== 歌单落盘（防 AppFreeze/THREAD_BLOCK_6S） =====
//
// 全库 slimTrack + 逐片 JSON.stringify 不能同步压在主线程上：任何一次歌单写
// 操作（重命名 / 拖动 / 收藏夹同步逐夹 applyFavMirror…）都会全量重写所有
// 歌单的所有分片，万首级库单次就是数百 ms，收藏夹同步 N 个夹 = N 次串联，
// 主线程事件循环被连续占满，输入事件 6 秒得不到处理即 THREAD_BLOCK_6S。
//
// 结构分三段：
//  1) persistPlaylists 只做**同步换缓存 + 广播刷新**（微秒级）——内存缓存是
//     唯一真源，后续同步读（getPlaylists）立即可见新状态，页面刷新不等待；
//  2) schedulePersist 去抖合并：突发写（同步轮里逐夹 updatePlaylist）收敛为
//     一次落盘，全库重序列化从 N 次降为 1 次；
//  3) runPersist 异步执行，每序列化 PERSIST_YIELD_EVERY_CHUNKS 片就让出主线程
//     一拍（宏任务级 setTimeout），输入 / 渲染事件得以插队 —— 无论库多大，
//     主线程单次连续占用都被压在几 ms 量级，6s 冻结在结构上不再可能。

/** 落盘去抖窗口：突发写合并；窗口内内存缓存已是新值，UI 无感知 */
const PERSIST_DEBOUNCE_MS: number = 200;
/** 连续序列化多少个分片后让出主线程一拍（16 片 = 128 条 ≈ 数 ms） */
const PERSIST_YIELD_EVERY_CHUNKS: number = 16;

let persistTimer: number = -1;
let persistRunning: boolean = false;
let persistAgain: boolean = false;

function persistPlaylists(list: Playlist[]): void {
  // 内存缓存保留**完整**曲目（含 localFilePath 等不落盘字段），播放与下载走的就是这份
  playlistCache = list;
  // 立即广播：页面刷新依赖 libraryRev，不能等落盘
  notifyLibraryChanged();
  schedulePersist();
}

function schedulePersist(): void {
  // 已有落盘在跑：只登记「跑完再来一次」，避免并发 runPersist 交叉写同一批 key
  if (persistRunning) {
    persistAgain = true;
    return;
  }
  if (persistTimer !== -1) {
    return;
  }
  persistTimer = setTimeout((): void => {
    persistTimer = -1;
    runPersist().catch((e: Error): void => {
      console.error(`persist playlists failed: ${e.message}`);
    });
  }, PERSIST_DEBOUNCE_MS);
}

/** 让出主线程一拍（宏任务级）：序列化分批让位，输入/渲染事件得以插队处理 */
function yieldMainThread(): Promise<void> {
  return new Promise<void>((resolve: (value: void) => void): void => {
    setTimeout(resolve, 0);
  });
}

/**
 * 立即触发尚未执行的歌单落盘（EntryAbility.onBackground 兜底）。
 *
 * 去抖窗口（PERSIST_DEBOUNCE_MS）内用户直接划卡杀进程时，定时器来不及跑，
 * 最后一次歌单写会丢 —— 退后台是最后一个可靠时机，把窗口内的待写立刻冲掉。
 * 落盘已在跑（persistRunning）时不重复触发：本次跑完会经 persistAgain 补一次。
 */
export function flushPendingLibraryPersist(): void {
  if (persistTimer !== -1) {
    clearTimeout(persistTimer);
    persistTimer = -1;
  }
  if (!persistRunning) {
    runPersist().catch((e: Error): void => {
      console.error(`persist playlists failed: ${e.message}`);
    });
  }
}

async function runPersist(): Promise<void> {
  persistRunning = true;
  try {
    const list: Playlist[] | null = playlistCache;
    if (list === null) {
      return;
    }
    // 曲目一律瘦身落盘（audioUrl 不入库，理由见 slimTrack 注释）。
    // 歌单曲目**不截断**（截断等于悄悄丢用户的歌），只在超过 PLAYLIST_MAX_ITEMS 时截并告警。
    const metas: StoredPlaylist[] = [];
  const oldChunkCounts: Map<string, number> = new Map();
  const oldStored: StoredPlaylist[] = AppPreferences.getPlaylists<StoredPlaylist>();
  if (Array.isArray(oldStored)) {
    for (let i = 0; i < oldStored.length; i++) {
      oldChunkCounts.set(oldStored[i].id, oldStored[i].chunkCount ?? 0);
    }
  }

  // 所有分片 + 元信息攒进一个 putMany（一次 flush），避免每片各自 put + flush
  //（订阅拉新 / 批量入单动辄几十片，就是几十次全量落盘）。
  const writes: Record<string, string> = {};
  const removes: string[] = [];
    let chunksSinceYield: number = 0;
  for (let i = 0; i < list.length; i++) {
    const p: Playlist = list[i];
    let capped: Track[] = p.tracks;
    if (capped.length > PLAYLIST_MAX_ITEMS) {
      // 订阅歌单会持续增长，超上限时丢**最旧**的（订阅流里越旧越不值钱）；
      // 这里仍然丢弃了用户可能想留的条目，所以必须打日志而不是静默。
      capped = capped.slice(0, PLAYLIST_MAX_ITEMS);
      console.warn(`playlist ${p.id} exceeds ${PLAYLIST_MAX_ITEMS} items, older ones dropped`);
    }
    const slim: Track[] = capped.map((t: Track): Track => slimTrack(t));
    const chunkCount: number = Math.ceil(slim.length / PLAYLIST_CHUNK_ITEMS);
    for (let c = 0; c < chunkCount; c++) {
        const part: Track[] = slim.slice(c * PLAYLIST_CHUNK_ITEMS, (c + 1) * PLAYLIST_CHUNK_ITEMS);
        writes[chunkKeyOf(p.id, c)] = JSON.stringify(part);
        chunksSinceYield++;
        if (chunksSinceYield >= PERSIST_YIELD_EVERY_CHUNKS) {
          chunksSinceYield = 0;
          await yieldMainThread();
        }
      }
    // 条目变少时清掉多余分片，否则旧 key 会一直占着磁盘
    const oldCount: number | undefined = oldChunkCounts.get(p.id);
    if (oldCount !== undefined && oldCount > chunkCount) {
      for (let c = chunkCount; c < oldCount; c++) {
        removes.push(chunkKeyOf(p.id, c));
      }
    }
    metas.push({
      id: p.id,
      name: p.name,
      description: p.description,
      coverUrl: p.coverUrl,
      createdAt: p.createdAt,
      updatedAt: p.updatedAt,
      // ⚠️ 订阅来源必须落盘：漏掉这两行，重启后歌单会退化成普通歌单，
      // 「拉取新投稿」入口随之消失（且用户不会知道自己建过订阅）。
      upMid: p.upMid,
      upName: p.upName,
      // ⚠️ 来源种类必须落盘：漏了它，重启后收藏夹镜像会退化成「订阅 UP 歌单」
      //（详情页错显「订阅自」+ 冒出「拉取新投稿」入口），与 upMid/titleSorted 同坑。
      sourceKind: p.sourceKind ?? '',
      // 与 upMid/upName 同理：这是「规则」，不是展示字段，漏落盘 = 重启后规则失效
      titleSorted: p.titleSorted === true,
      chunkCount: chunkCount
    });
  }

  const metasJson: string = JSON.stringify(metas);
    const bytes: number = utf8Length(metasJson);
    if (bytes > PREF_VALUE_BUDGET_BYTES) {
      // 元信息不含曲目，正常情况只有几百字节；走到这里说明歌单数量异常多
      console.error(`playlists meta too large: ${bytes} bytes (budget ${PREF_VALUE_BUDGET_BYTES})`);
    }
    // 元信息也并进同一批（同一次 flush 落盘）
    writes[PREF_PLAYLISTS] = metasJson;
    // fire-and-forget：与既有风格一致（内存快照才是真源，见 playlistCache 注释）
    await AppPreferences.putMany(writes).catch((e: Error): void => {
      console.error(`savePlaylists failed: ${e.message}`);
    });
    if (removes.length > 0) {
      await AppPreferences.removeMany(removes).catch((e: Error): void => {
        console.error(`remove playlist chunk keys failed: ${e.message}`);
      });
    }
  } finally {
    persistRunning = false;
    if (persistAgain) {
      persistAgain = false;
      schedulePersist();
    }
  }
}

let libraryRev: number = 0;

/** 通知各页面媒体库已变更（歌单页常驻在 Tabs 里，不刷新会一直显示旧数据） */
function notifyLibraryChanged(): void {
  libraryRev = libraryRev + 1;
  AppStorage.setOrCreate(STORE_LIBRARY_REV, libraryRev);
}

export function createPlaylist(input: {
  name: string;
  description?: string;
  coverUrl?: string;
  upMid?: string;
  upName?: string;
  /** 来源种类（'up' / 'fav' / ''）。省略时按 upMid 非空兜底为 'up'。 */
  sourceKind?: string;
}): Playlist {
  const now: string = new Date().toISOString();
  const upMid: string = input.upMid?.trim() || '';
  const playlist: Playlist = {
    id: createId(),
    name: input.name.trim(),
    description: input.description?.trim() || '',
    coverUrl: input.coverUrl?.trim() || '',
    tracks: [],
    createdAt: now,
    updatedAt: now,
    upMid: upMid,
    upName: input.upName?.trim() || '',
    sourceKind: input.sourceKind?.trim() || (upMid.length > 0 ? 'up' : '')
  };
  persistPlaylists([playlist, ...getPlaylists()]);
  return playlist;
}

export function getPlaylist(id: string): Playlist | null {
  return getPlaylists().find((p: Playlist): boolean => p.id === id) ?? null;
}

/**
 * 移动歌单在列表中的位置（歌单列表页「长按拖动排序」落库）。
 *
 * 歌单顺序是纯本地展示态：新建/订阅走 unshift 进头部（与手动顺序天然兼容），
 * 收藏夹同步 / 订阅拉新都只改既有歌单内容、不重建列表顺序，所以任何类型的歌单
 * （含收藏夹镜像）都可以自由拖。按 id 定位（不收 from 下标），与 movePlaylistTrack
 * 同款纪律：传错下标最多影响 to 的 clamp，不会拖丢歌单。
 * @returns 是否发生了实际移动（id 找不到 / 原地 → false 且不落盘）。
 */
export function movePlaylist(playlistId: string, toIndex: number): boolean {
  const list: Playlist[] = getPlaylists();
  const fromIndex: number = list.findIndex((p: Playlist): boolean => p.id === playlistId);
  if (fromIndex < 0) {
    return false;
  }
  // clamp：负值 / 越界一律收进合法区间（防御性，正常拖拽不会触发）
  const target: number = Math.max(0, Math.min(Math.floor(toIndex), list.length - 1));
  if (target === fromIndex) {
    return false;
  }
  const moved: Playlist = list.splice(fromIndex, 1)[0];
  list.splice(target, 0, moved);
  persistPlaylists(list);
  return true;
}

export function updatePlaylist(updated: Playlist): void {
  const playlists: Playlist[] = getPlaylists().map((p: Playlist): Playlist => {
    return p.id === updated.id ? Object.assign({}, updated, { updatedAt: new Date().toISOString() }) : p;
  });
  persistPlaylists(playlists);
}

/**
 * 歌单名截断长度（全角字符数）。B 站标题动辄三四十字（带【】前缀、英文歌名、多个 slash），
 * 落库前截断，保证歌单页能完整显示。
 * 阈值按双行标题容量推算：信息列可用宽 ≈ 251vp
 * （屏宽 391vp − 行内边距 20 − 封面 64 − 间距 12 − 「⋮」44），16fp 全角字宽 16vp
 * → 一行 ≈ 15.7 字、两行 ≈ 31.4 全角。取 36：含半角（英文/数字/符号）的
 * 混合标题（渲染宽约为全角一半）双行完整显示；纯中文超长名显示层
 * maxLines(2) 自然省略兜底，库里仍是完整名。预截断只挡 36 字以上的极端标题
 * （长串 tag 堆叠），避免落库名过长；撞名追加「 N」序号的边缘仍可能省略，属可接受。
 */
const PLAYLIST_NAME_MAX_CHARS: number = 36;

/**
 * 把条目歌名收拾成一个能当歌单名的字符串。
 *
 * 三件事：压掉首尾空白与内部连续空白（标题里的换行 / 全角空格会直接进歌单名，在歌单页显示成两行）、
 * 超长截断加省略号、空串回退到 `DEFAULT_PLAYLIST_NAME`（歌名本身为空的畸形条目）。
 */
function playlistNameBaseFromTrack(track: Track): string {
  const flat: string = track.title.replace(/\s+/g, ' ').trim();
  if (flat.length === 0) {
    return DEFAULT_PLAYLIST_NAME;
  }
  if (flat.length <= PLAYLIST_NAME_MAX_CHARS) {
    return flat;
  }
  return `${flat.substring(0, PLAYLIST_NAME_MAX_CHARS)}…`;
}

/**
 * 「新建歌单并加入」时的歌单名：**取自条目歌名**，撞名自动加序号。
 *
 * 为什么放在这里而不是各页面自己写：搜索页与播放页各有一份 `nextPlaylistName`，
 * 两份逻辑逐字重复 —— 改文案 / 改序号规则时只改一处，另一处就会静默产生两个同名歌单
 * （记忆里 `DEFAULT_PLAYLIST_NAME` 提到 Constants 就是为了治这个毛病，但函数本身仍复制了两份）。
 * 名字是「落库前的最后一道闸」，必须只有一份实现。
 *
 * @param track    要加进去的条目，名字取它的 `title`
 * @param existing 已存在的歌单（用于撞名检查；比较前先 trim，避免「起风了」与「起风了 」被判成不同）
 */
export function nextPlaylistNameForTrack(track: Track, existing: Playlist[]): string {
  const names: Set<string> = new Set<string>();
  for (let i = 0; i < existing.length; i++) {
    names.add(existing[i].name.trim());
  }
  const base: string = playlistNameBaseFromTrack(track);
  if (!names.has(base)) {
    return base;
  }
  // B 站同名的歌 / 翻唱极多（两首「起风了」很常见），序号从 2 起 —— 与原「我的歌单 2」的观感一致
  for (let i = 2; i < 1000; i++) {
    const candidate: string = `${base} ${i}`;
    if (!names.has(candidate)) {
      return candidate;
    }
  }
  return `${base} ${Date.now()}`;
}

// ===== 按名称排序（「一键排全部」+ 此后新增自动按名插入） =====

/**
 * 名称比较：`localeCompare` 走 ICU，中文按**拼音**序（用户选定），英文按字母序。
 *
 * 刻意不自己写拼音表：`localeCompare` 是平台能力，手写映射表要覆盖多音字、
 * 中英混排、数字开头的歌名，代价高且必然漏。排序稳定性靠下标兜底（见 `compareByTitle`）。
 */
function compareByTitle(a: Track, b: Track, indexA: number, indexB: number): number {
  const primary: number = a.title.localeCompare(b.title);
  // 同名（同 localeCompare 结果）时保原相对顺序：
  // Array.sort 的稳定性不该被依赖（ArkTS 各引擎实现未作保证），
  // 而且「同名保持原顺序」对用户是符合直觉的期望。
  return primary !== 0 ? primary : indexA - indexB;
}

/** 按歌名排序一份曲目数组（**不改入参**，返回新数组） */
function sortTracksByTitle(tracks: Track[]): Track[] {
  const indexed: { track: Track; index: number }[] = [];
  for (let i = 0; i < tracks.length; i++) {
    indexed.push({ track: tracks[i], index: i });
  }
  indexed.sort((a: { track: Track; index: number }, b: { track: Track; index: number }): number => {
    return compareByTitle(a.track, b.track, a.index, b.index);
  });
  const out: Track[] = [];
  for (let i = 0; i < indexed.length; i++) {
    out.push(indexed[i].track);
  }
  return out;
}

/** 该歌单是否处于「按名称排序」规则下（老数据没有这个标记，undefined 视为否） */
function isTitleSorted(p: Playlist): boolean {
  return p.titleSorted === true;
}

/** 「一键排全部」的处理结果：页面据此生成回执文案。
 *  **必须是命名 interface**：ArkTS 禁止把对象字面量当类型用（`arkts-no-obj-literals-as-types`），
 *  写成内联 `{ playlists: number; tracks: number }` 在 .ets 里会编译报错。 */
export interface SortAllResult {
  /** 被打上排序规则的歌单数（含空歌单） */
  playlists: number;
  /** 被实际重排的条目总数 */
  tracks: number;
}

/**
 * 把所有歌单的条目按歌名排序，并**打开持续规则**（此后新增自动按名插入）。
 *
 * ⚠️ **当前没有 UI 入口**。
 * 底层能力刻意保留：排序标记 `titleSorted` 已经落盘且被持续规则读取
 * （`addTrackToPlaylist` / `mergeUpTracks`），拆掉数据结构要动落盘格式与导入导出，
 * 代价远大于留着。想加回来只需在页面上接一个入口调这个函数。
 *
 * 语义是**一次性动作**：只有被调到的歌单才会排序 + 打标记，不碰没调过的歌单。
 */
export function sortAllPlaylistsByTitle(): SortAllResult {
  const list: Playlist[] = getPlaylists();
  let touchedPlaylists: number = 0;
  let touchedTracks: number = 0;
  const next: Playlist[] = list.map((p: Playlist): Playlist => {
    if (p.tracks.length === 0) {
      // 空歌单也打开标记：以后加的第一首就该落在唯一的位置上，
      // 否则用户建完空歌单、后来加歌，却发现还得再点一次「排全部」。
      touchedPlaylists++;
      return Object.assign({}, p, { titleSorted: true, updatedAt: new Date().toISOString() });
    }
    touchedPlaylists++;
    touchedTracks += p.tracks.length;
    return Object.assign({}, p, {
      tracks: sortTracksByTitle(p.tracks),
      titleSorted: true,
      updatedAt: new Date().toISOString()
    });
  });
  if (next.length > 0) {
    persistPlaylists(next);
  }
  return { playlists: touchedPlaylists, tracks: touchedTracks };
}

/**
 * 把一个歌单按歌名排序（当前无 UI 入口，能力保留）。
 *
 * 与 `sortAllPlaylistsByTitle` 的区别只是范围；持续规则（此后新增自动按名插入）两者一致。
 * @returns 排序后的歌单；id 不存在返回 null
 */
export function sortPlaylistByTitle(playlistId: string): Playlist | null {
  const list: Playlist[] = getPlaylists();
  let result: Playlist | null = null;
  const next: Playlist[] = list.map((p: Playlist): Playlist => {
    if (p.id !== playlistId) {
      return p;
    }
    result = Object.assign({}, p, {
      tracks: sortTracksByTitle(p.tracks),
      titleSorted: true,
      updatedAt: new Date().toISOString()
    });
    return result;
  });
  if (result !== null) {
    persistPlaylists(next);
  }
  return result;
}

/**
 * 关掉某个歌单的「按名称排序」规则（当前无 UI 入口，能力保留）。
 *
 * **刻意不还原已有顺序** —— 原顺序在排序那一刻就丢了，没有任何地方备份过。
 * 重新排序随时能再排一次，谎称能「恢复原样」比不说更糟。
 */
export function clearPlaylistTitleSort(playlistId: string): Playlist | null {
  const list: Playlist[] = getPlaylists();
  let result: Playlist | null = null;
  const next: Playlist[] = list.map((p: Playlist): Playlist => {
    if (p.id !== playlistId) {
      return p;
    }
    result = Object.assign({}, p, { titleSorted: false, updatedAt: new Date().toISOString() });
    return result;
  });
  if (result !== null) {
    persistPlaylists(next);
  }
  return result;
}

/**
 * 清掉某个歌单的落盘数据：写删除墓碑 + 移除它的曲目分片 key。
 *
 * 只清磁盘数据，**不提交** `persistPlaylists` —— 由调用方把新列表一次性提交，
 * 这样「删除 / 合并删源」都只有一次落盘，也不会出现「列表已换、分片还在」的中间态。
 */
function purgePlaylistData(id: string): void {
  addPlaylistTombstone(id);
  // 连分片一起清掉：留着不会被误读（读只取 chunkCount 个 key），但会一直占磁盘。
  // 攒一批走 removeMany（一次 flush），避免逐片 remove 造成上千次串行 flush。
  const stored: StoredPlaylist[] = AppPreferences.getPlaylists<StoredPlaylist>();
  if (Array.isArray(stored)) {
    const keys: string[] = [];
    for (let i = 0; i < stored.length; i++) {
      if (stored[i].id !== id) {
        continue;
      }
      const chunkCount: number = stored[i].chunkCount ?? 0;
      for (let c = 0; c < chunkCount; c++) {
        keys.push(chunkKeyOf(id, c));
      }
    }
    if (keys.length > 0) {
      AppPreferences.removeMany(keys).catch((e: Error): void => {
        console.error(`purge playlist chunk keys failed: ${e.message}`);
      });
    }
  }
}

// ===== 双向收藏夹写回挂钩 =====
// addTrackToPlaylist / addTracksToPlaylist / removeTracksFromPlaylist 是全部
// 「本地加 / 删曲目」入口的唯一汇聚点（7+ 页面都走这里），在这里挂钩即可全覆盖；
// applyFavMirror（同步拉取）走 updatePlaylist 直写，不经过这些入口，零误触发。

/** 上一批 add 操作中因「双向夹只收 B 站曲目」被跳过的条数（UI 读后清零） */
let favMirrorSkippedLast: number = 0;

/**
 * 读走最近一次「加入双向夹」被跳过的非 B 站曲目数（读后清零）。
 * 调用方（加歌入口页）在 toast 里追加「N 首非 B 站曲目已跳过」。
 */
export function consumeFavMirrorSkippedCount(): number {
  const n: number = favMirrorSkippedLast;
  favMirrorSkippedLast = 0;
  return n;
}

/** 取曲目的有效 bvid（优先 Track.bvid，兜底 Track.id；非 BV 号返回空串） */
function bvidOf(t: Track): string {
  const bv: string = t.bvid.length > 0 ? t.bvid : t.id;
  return bv.indexOf('BV') === 0 && bv.length >= 12 ? bv : '';
}

/**
 * 双向夹加歌**过滤**阶段：非 B 站曲目（无 BV 号，本地文件 / 外部导入）无法写回
 * B 站，**禁止入单**并计数（UI 经 consumeFavMirrorSkippedCount 提示）。
 * 单向夹 / 普通歌单直接原样放行。
 */
function filterTwowayAddTracks(playlist: Playlist, tracks: Track[]): Track[] {
  if (!isFavMirror(playlist)) {
    return tracks;
  }
  const mediaId: number = favMediaIdOf(playlist);
  if (!isFolderTwoway(mediaId)) {
    return tracks;
  }
  const allowed: Track[] = [];
  for (let i = 0; i < tracks.length; i++) {
    if (bvidOf(tracks[i]).length > 0) {
      allowed.push(tracks[i]);
    } else {
      favMirrorSkippedLast = favMirrorSkippedLast + 1;
    }
  }
  return allowed;
}

/**
 * 双向夹加歌**入队**阶段（过滤之后、去重命中之外真正新增的曲目）：
 * 生成 add 意图入「待推送」队列并安排实时冲刷。去重命中的不入队（防重复意图）。
 */
function hookTwowayAdds(playlist: Playlist, fresh: Track[]): void {
  if (fresh.length === 0 || !isFavMirror(playlist)) {
    return;
  }
  const mediaId: number = favMediaIdOf(playlist);
  if (!isFolderTwoway(mediaId)) {
    return;
  }
  const intents: FavPushIntent[] = [];
  for (let i = 0; i < fresh.length; i++) {
    const bv: string = bvidOf(fresh[i]);
    if (bv.length > 0) {
      intents.push({ mediaId: mediaId, bvid: bv, op: 'add' });
    }
  }
  if (intents.length > 0) {
    enqueueFavPushes(intents);
    scheduleFavPushFlush();
  }
}

/** 双向夹移除挂钩：被移除曲目入「待推送」队列（del = B 站取消收藏）并安排实时冲刷 */
function hookTwowayRemoves(playlist: Playlist, removed: Track[]): void {
  if (removed.length === 0 || !isFavMirror(playlist)) {
    return;
  }
  const mediaId: number = favMediaIdOf(playlist);
  if (!isFolderTwoway(mediaId)) {
    return;
  }
  const intents: FavPushIntent[] = [];
  for (let i = 0; i < removed.length; i++) {
    const bv: string = bvidOf(removed[i]);
    if (bv.length > 0) {
      intents.push({ mediaId: mediaId, bvid: bv, op: 'del' });
    }
  }
  if (intents.length > 0) {
    enqueueFavPushes(intents);
    scheduleFavPushFlush();
  }
}

export function deletePlaylist(id: string): void {
  // 已加入首页快捷卡行的歌单被删：同步清掉 HomeCardStore 残留 id，
  // 否则死 id 占着 HOME_PLAYLIST_CARDS_MAX 配额（加满 9 → 删 1 →
  // 再也加不进新歌单）。removeHomePlaylist 不在架时无操作；bump 一次
  // STORE_LIBRARY_REV 幂等无害，随后 persistPlaylists 还会再 bump。
  // 收口在此处 = PlaylistsPage 单删 / 多选删、FavSyncManager 镜像删全覆盖。
  HomeCardStore.removeHomePlaylist(id);
  const dying: Playlist | null = getPlaylist(id);
  if (dying !== null && isFavMirror(dying)) {
    const mediaId: number = favMediaIdOf(dying);
    if (mediaId > 0) {
      // 删除本地镜像 = 停止镜像：未冲刷的写回意图一并放弃（B 站收藏夹本身不受影响）
      purgeFavPushesForFolder(mediaId);
    }
  }
  purgePlaylistData(id);
  persistPlaylists(getPlaylists().filter((p: Playlist): boolean => p.id !== id));
}

/**
 * 重命名歌单。只改名字，其余字段（tracks / 封面 / 创建时间）原样保留，
 * 不能拿一个只有 name 的新对象去 updatePlaylist，否则曲目会被清空。
 */
export function renamePlaylist(id: string, name: string): Playlist | null {
  const current: Playlist | null = getPlaylist(id);
  if (!current) {
    return null;
  }
  const renamed: Playlist = Object.assign({}, current, { name: name.trim(), updatedAt: new Date().toISOString() });
  updatePlaylist(renamed);
  return renamed;
}

export function addTrackToPlaylist(playlistId: string, track: Track): Playlist | null {
  const playlists: Playlist[] = getPlaylists();
  let updatedPlaylist: Playlist | null = null;
  let dirty: boolean = false;
  const next: Playlist[] = playlists.map((playlist: Playlist): Playlist => {
    if (playlist.id !== playlistId) {
      return playlist;
    }
    // 双向夹只收 B 站曲目（无 BV 号无法写回 B 站）：被滤曲目不入单，
    // 调用方凭 consumeFavMirrorSkippedCount() 追加提示；单向夹 / 普通歌单原样放行。
    const candidates: Track[] = filterTwowayAddTracks(playlist, [track]);
    if (candidates.length === 0) {
      // 全部被滤：歌单原样返回（不重写盘、不入队）
      updatedPlaylist = playlist;
      return playlist;
    }
    const tr: Track = candidates[0];
    const exists: boolean = playlist.tracks.some((t: Track): boolean => t.id === tr.id);
    // 双向夹写回：真正新增的曲目入推送队列（去重命中不入队，防重复 add 意图）
    if (!exists) {
      hookTwowayAdds(playlist, [tr]);
    }
    // 持续规则：打过「按名称排序」标记的歌单，新增曲目要插到**按名的正确位置**，
    // 而不是默认追加到末尾（追加只在未排序的歌单上才是对的）。
    // 加入时间戳盖章（拷贝，不污染与队列 / 最近播放共享的原实例）：
    // 歌单详情「按加入时间」排序靠它。
    const appended: Track[] = exists ? playlist.tracks
      : [...playlist.tracks, Object.assign({}, tr, { addedAt: new Date().toISOString() })];
    dirty = true;
    updatedPlaylist = {
      id: playlist.id,
      name: playlist.name,
      description: playlist.description,
      coverUrl: playlist.coverUrl || tr.coverUrl,
      tracks: isTitleSorted(playlist) ? sortTracksByTitle(appended) : appended,
      createdAt: playlist.createdAt,
      updatedAt: new Date().toISOString(),
      upMid: playlist.upMid,
      upName: playlist.upName,
      // ⚠️ 本函数用对象字面量重建歌单，来源种类必须透传，否则「加一首歌」就把镜像/订阅
      // 标记抹掉（详情页随即错显、订阅入口消失）。同 removeTracksFromPlaylist 的教训。
      sourceKind: playlist.sourceKind,
      titleSorted: playlist.titleSorted
    };
    return updatedPlaylist;
  });
  if (updatedPlaylist && dirty) {
    persistPlaylists(next);
  }
  return updatedPlaylist;
}

/**
 * 批量加入歌单（下载页组头「加入歌单」用）。
 *
 * 语义与 `addTrackToPlaylist` 一致 —— 按 id 去重、addedAt 盖章、
 * 「按名称排序」歌单插到正确位置、coverUrl 兜底、收藏夹镜像逐条回推 ——
 * 但只做**一次** persistPlaylists：本文件「禁止逐首 addTrackToPlaylist」的
 * I/O 纪律（见 importPlaylistsFromText 注释）对批量入口同样成立，
 * 整张歌单卡片入单时逐首调用 = 每首全量重写分片，大歌单会放大成 I/O 灾难。
 */
export function addTracksToPlaylist(playlistId: string, tracks: Track[]): Playlist | null {
  if (tracks.length === 0) {
    return getPlaylist(playlistId);
  }
  const playlists: Playlist[] = getPlaylists();
  let updatedPlaylist: Playlist | null = null;
  let dirty: boolean = false;
  /** 本次真正新增的曲目（去重后追加的；封面兜底取第一首用） */
  const added: Track[] = [];
  const next: Playlist[] = playlists.map((playlist: Playlist): Playlist => {
    if (playlist.id !== playlistId) {
      return playlist;
    }
    // 双向夹只收 B 站曲目：被滤曲目不入单（调用方凭 consumeFavMirrorSkippedCount 提示）
    const candidates: Track[] = filterTwowayAddTracks(playlist, tracks);
    if (candidates.length === 0) {
      updatedPlaylist = playlist;
      return playlist;
    }
    // 去重集合：先装歌单已有的 id，逐条入单时同步登记，批内重复也拦掉
    const seen: Set<string> = new Set<string>(playlist.tracks.map((t: Track): string => t.id));
    const appended: Track[] = [...playlist.tracks];
    for (let i = 0; i < candidates.length; i++) {
      const tr: Track = candidates[i];
      if (seen.has(tr.id)) {
        continue;
      }
      seen.add(tr.id);
      // 加入时间戳盖章（拷贝，不污染队列 / 最近播放共享的原实例），与单条版同款
      const stamped: Track = Object.assign({}, tr, { addedAt: new Date().toISOString() });
      appended.push(stamped);
      added.push(stamped);
    }
    // 双向夹写回：真正新增（去重后）的曲目入推送队列
    hookTwowayAdds(playlist, added);
    dirty = true;
    updatedPlaylist = {
      id: playlist.id,
      name: playlist.name,
      description: playlist.description,
      coverUrl: playlist.coverUrl || (added.length > 0 ? added[0].coverUrl : ''),
      tracks: isTitleSorted(playlist) ? sortTracksByTitle(appended) : appended,
      createdAt: playlist.createdAt,
      updatedAt: new Date().toISOString(),
      upMid: playlist.upMid,
      upName: playlist.upName,
      // ⚠️ 与 addTrackToPlaylist 同因：对象字面量重建歌单，来源种类必须透传，
      // 否则批量入单一次就把镜像/订阅标记抹掉。
      sourceKind: playlist.sourceKind,
      titleSorted: playlist.titleSorted
    };
    return updatedPlaylist;
  });
  if (updatedPlaylist && dirty) {
    persistPlaylists(next);
  }
  return updatedPlaylist;
}

export function removeTracksFromPlaylist(playlistId: string, trackIds: string[]): Playlist | null {
  const ids: Set<string> = new Set<string>(trackIds);
  if (ids.size === 0) {
    return getPlaylist(playlistId);
  }
  const playlists: Playlist[] = getPlaylists();
  let updatedPlaylist: Playlist | null = null;
  const next: Playlist[] = playlists.map((playlist: Playlist): Playlist => {
    if (playlist.id !== playlistId) {
      return playlist;
    }
    // 双向夹写回：被移除的曲目入推送队列（del = B 站取消收藏，实时冲刷）
    const removedNow: Track[] = playlist.tracks.filter((t: Track): boolean => ids.has(t.id));
    hookTwowayRemoves(playlist, removedNow);
    updatedPlaylist = {
      id: playlist.id,
      name: playlist.name,
      description: playlist.description,
      coverUrl: playlist.coverUrl,
      tracks: playlist.tracks.filter((t: Track): boolean => !ids.has(t.id)),
      createdAt: playlist.createdAt,
      updatedAt: new Date().toISOString(),
      upMid: playlist.upMid,
      upName: playlist.upName,
      // ⚠️ 本函数同样用对象字面量**重建**歌单，来源种类必须透传。
      // ⚠️ 必须透传：本函数用对象字面量**重建**歌单（不是 Object.assign），
      // 漏掉这个字段 = 删首歌就把「按名称排序」规则悄悄关掉了。
      sourceKind: playlist.sourceKind,
      titleSorted: playlist.titleSorted
    };
    return updatedPlaylist;
  });
  if (updatedPlaylist) {
    persistPlaylists(next);
  }
  return updatedPlaylist;
}

// ===== 歌单合并（多选 → 一个新歌单） =====

/**
 * 按 id 取源歌单，并保持它们在**列表中的先后顺序**。
 * 刻意不按用户勾选顺序：同一批歌单无论怎么点，合并结果都一样，可预期。
 */
function collectMergeSources(ids: string[]): Playlist[] {
  const wanted: Set<string> = new Set<string>(ids);
  return getPlaylists().filter((p: Playlist): boolean => wanted.has(p.id));
}

interface MergeTracksResult {
  /** 去重后的曲目（同一 track.id 保留首次出现的那份） */
  tracks: Track[];
  /** 有效曲目条数（去重前；null / 没有 id 的畸形条目直接跳过、不计入） */
  rawTotal: number;
}

function mergeTracksOf(sources: Playlist[]): MergeTracksResult {
  const seen: Set<string> = new Set<string>();
  const tracks: Track[] = [];
  let rawTotal: number = 0;
  for (let i = 0; i < sources.length; i++) {
    const list: Track[] = sources[i].tracks;
    for (let k = 0; k < list.length; k++) {
      const t: Track = list[k];
      if (!t || typeof t.id !== 'string' || t.id.length === 0) {
        continue;
      }
      rawTotal = rawTotal + 1;
      if (seen.has(t.id)) {
        continue;
      }
      seen.add(t.id);
      tracks.push(t);
    }
  }
  return { tracks: tracks, rawTotal: rawTotal };
}

/** 合并预览：弹窗的汇总文案与风险提示都取这里（不落盘、不改状态） */
export interface PlaylistMergePreview {
  /** 有效的源歌单数（失效 / 重复 id 已剔除） */
  sources: number;
  /** 源曲目总数（去重前） */
  rawTotal: number;
  /** 去重后的条数（未截断） */
  total: number;
  /** 被去重掉的条数 */
  deduped: number;
  /** 超过 PLAYLIST_MAX_ITEMS、会被丢弃的条数（丢的是尾部） */
  dropped: number;
  /** 源里 UP 订阅歌单的数量（删源风险提示用） */
  subscriptionCount: number;
}

export function previewPlaylistMerge(ids: string[]): PlaylistMergePreview {
  const sources: Playlist[] = collectMergeSources(ids);
  const merged: MergeTracksResult = mergeTracksOf(sources);
  let subscriptionCount: number = 0;
  for (let i = 0; i < sources.length; i++) {
    // 用 helper 而非 upMid 非空：收藏夹镜像也有 upMid（fav_x），但不算「订阅歌单」，
    // 合并删源的提示文案不该把它算进去
    if (isUpSubscription(sources[i])) {
      subscriptionCount = subscriptionCount + 1;
    }
  }
  const total: number = merged.tracks.length;
  return {
    sources: sources.length,
    rawTotal: merged.rawTotal,
    total: total,
    deduped: merged.rawTotal - total,
    dropped: total > PLAYLIST_MAX_ITEMS ? total - PLAYLIST_MAX_ITEMS : 0,
    subscriptionCount: subscriptionCount
  };
}

/** 合并结果：页面据此生成回执文案 */
export interface PlaylistMergeResult {
  playlist: Playlist;
  /** 参与的源歌单数 */
  sources: number;
  /** 新歌单里的条目数（已按上限截断） */
  total: number;
  /** 被去重掉的条数 */
  deduped: number;
  /** 因超过 PLAYLIST_MAX_ITEMS 被丢弃的条数 */
  dropped: number;
}

/** 重名加后缀：X → X 合并 → X 合并2 → X 合并3…（名字 trim 后为空则兜底「合并歌单」） */
function uniqueMergeName(rawName: string, taken: Set<string>): string {
  const trimmed: string = rawName.trim();
  const base: string = trimmed.length > 0 ? trimmed : '合并歌单';
  if (!taken.has(base)) {
    return base;
  }
  let candidate: string = `${base} 合并`;
  let seq: number = 2;
  while (taken.has(candidate)) {
    candidate = `${base} 合并${seq}`;
    seq = seq + 1;
  }
  return candidate;
}

/**
 * 合并多个歌单为一个新歌单。
 *
 * @param ids           参与合并的歌单 id（按列表顺序合并；失效 / 重复 id 自动忽略）
 * @param name          新歌单名（空串兜底「合并歌单」；重名自动加「合并」后缀）
 * @param deleteSources true = 合并后删掉源歌单（写墓碑 + 清分片）
 * @returns 少于 2 个有效源时返回 null（页面已先校验，这里兜底）
 */
export function mergePlaylists(ids: string[], name: string, deleteSources: boolean): PlaylistMergeResult | null {
  const sources: Playlist[] = collectMergeSources(ids);
  if (sources.length < 2) {
    return null;
  }
  const merged: MergeTracksResult = mergeTracksOf(sources);
  const all: Track[] = merged.tracks;
  // 显式截断：persistPlaylists 也会截（丢尾部），这里先截能让**内存快照与磁盘一致** ——
  // 否则刚合完内存里 300 首、重启后只剩 200 首，看起来像丢歌。
  const kept: Track[] = all.length > PLAYLIST_MAX_ITEMS ? all.slice(0, PLAYLIST_MAX_ITEMS) : all;
  const dropped: number = all.length - kept.length;

  // 删源时源歌单不再占用名字，避免「新名与源同名也被加后缀」这种无谓改名
  const sourceIds: Set<string> = new Set<string>();
  for (let i = 0; i < sources.length; i++) {
    sourceIds.add(sources[i].id);
  }
  const remaining: Playlist[] = deleteSources
    ? getPlaylists().filter((p: Playlist): boolean => !sourceIds.has(p.id))
    : getPlaylists();
  const takenNames: Set<string> = new Set<string>();
  for (let i = 0; i < remaining.length; i++) {
    takenNames.add(remaining[i].name.trim());
  }

  let coverUrl: string = '';
  for (let i = 0; i < sources.length; i++) {
    if (sources[i].coverUrl.length > 0) {
      coverUrl = sources[i].coverUrl;
      break;
    }
  }
  if (coverUrl.length === 0 && kept.length > 0) {
    coverUrl = kept[0].coverUrl;
  }

  const now: string = new Date().toISOString();
  const playlist: Playlist = {
    id: createId(),
    name: uniqueMergeName(name, takenNames),
    description: '',
    coverUrl: coverUrl,
    tracks: kept,
    createdAt: now,
    updatedAt: now,
    // 合并结果一律是普通歌单：订阅关系属于单个源歌单，无法在合并体上延续
    upMid: '',
    upName: '',
    // 同理：来源种类也不延续（多来源混合 → 清空），与 upMid 一致
    sourceKind: '',
    // 刻意**不继承**源歌单的排序标记：合并顺序是「源1 的顺序 + 源2 的顺序」拼出来的，
    // 混合体并不整齐。谎称已排序会让用户以为「以后新增按名插入」而实际不是。
    // 想让它有序，点一次「一键排全部」即可（那是用户的显式动作）。
    titleSorted: false
  };

  if (deleteSources) {
    for (let i = 0; i < sources.length; i++) {
      purgePlaylistData(sources[i].id);
    }
  }
  persistPlaylists([playlist, ...remaining]);

  return {
    playlist: playlist,
    sources: sources.length,
    total: kept.length,
    deduped: merged.rawTotal - all.length,
    dropped: dropped
  };
}

// ===== UP 主订阅（把某个 UP 的投稿变成可持续更新的歌单） =====

/** 订阅操作结果：页面要靠它区分「新建还是复用」「有没有新东西」 */
export interface UpSubscribeResult {
  playlist: Playlist;
  /** 本次真正新增的条目数 */
  added: number;
  /** 因超过 PLAYLIST_MAX_ITEMS 被丢弃的条数（丢弃的是**最旧**的） */
  dropped: number;
  /** true = 复用了该 UP 已有的订阅歌单 */
  reused: boolean;
}

/** 按 UP mid 找订阅歌单；空串或没订阅过返回 null */
export function getPlaylistByUpMid(upMid: string): Playlist | null {
  if (upMid.length === 0) {
    return null;
  }
  return getPlaylists().find((p: Playlist): boolean => p.upMid === upMid) ?? null;
}

// ===== 来源判定（收藏夹镜像 vs UP 订阅 vs 普通歌单） =====
//
// `upMid`/`upName` 是「通用来源 id / 来源名」：UP 订阅存真实 mid，收藏夹镜像存
// `fav_{mediaId}`。凡 UI 需要区分来源，一律走下面两个 helper，**不要再写
// `p.upMid.length > 0`** —— 那样会把收藏夹镜像误判成订阅歌单（详情页错显「订阅自」、
// 冒出错误的「拉取新投稿」入口、歌单页行点击错跳到 UP 主页）。

/** 收藏夹镜像的来源 id 前缀（真实 UP mid 是纯数字，天然不冲突） */
export const FAV_SOURCE_PREFIX: string = 'fav_';

/** 收藏夹 media_id → 本地镜像歌单的来源 id（`fav_{mediaId}`） */
export function favSourceId(mediaId: number): string {
  return `${FAV_SOURCE_PREFIX}${mediaId}`;
}

/** 从来源 id（`fav_{mediaId}`）反解 media_id；非该形态 / 解析失败返回 0 */
export function favMediaIdFromSourceId(sourceId: string): number {
  if (!sourceId.startsWith(FAV_SOURCE_PREFIX)) {
    return 0;
  }
  const raw: string = sourceId.substring(FAV_SOURCE_PREFIX.length);
  const n: number = Number(raw);
  return Number.isFinite(n) ? n : 0;
}

/** 是否「订阅 UP 投稿」歌单（老数据无 sourceKind 时按 upMid 非空兜底） */
export function isUpSubscription(p: Playlist): boolean {
  if (p.sourceKind === 'up') {
    return true;
  }
  if (p.sourceKind === 'fav' || p.sourceKind === '') {
    return false;
  }
  return p.upMid.length > 0;
}

/**
 * 可作为「加入歌单」目标的歌单：排除 UP 订阅歌单。
 * 订阅歌单内容随 UP 投稿自动更新（拉取新投稿整单重建），手动加入的歌曲
 * 会在下次拉新时被淹没，且它在本应用的行点击语义是「进 UP 主页」——
 * 所有「选目标歌单」的弹层/菜单统一用这份列表，订阅歌单不出现。
 * ⚠️ 判定必须用 isUpSubscription：收藏夹镜像（fav_x）有 upMid 但可正常加歌。
 */
export function getAddablePlaylists(): Playlist[] {
  return getPlaylists().filter((p: Playlist): boolean => !isUpSubscription(p));
}

/** 是否「B 站收藏夹镜像」歌单 */
export function isFavMirror(p: Playlist): boolean {
  return p.sourceKind === 'fav';
}

/** 按收藏夹 media_id 找本地镜像歌单；没同步过返回 null */
export function getFavMirrorByMediaId(mediaId: number): Playlist | null {
  return getPlaylistByUpMid(favSourceId(mediaId));
}

/** 从镜像歌单反解出收藏夹 media_id；非镜像歌单 / 解析失败返回 0 */
export function favMediaIdOf(p: Playlist): number {
  if (p.sourceKind !== 'fav') {
    return 0;
  }
  return favMediaIdFromSourceId(p.upMid);
}

/**
 * 把 UP 的新投稿并进订阅歌单。
 *
 * 三条语义必须守住：
 *  1. **按 id 去重**——重复点「拉取新投稿」不会灌出重复条目；
 *  2. **只追加不覆盖**——用户手动删掉的条目不会被拉新塞回来；
 *  3. **新的排前面**——`getUserVideos(order='pubdate')` 本就是按发布时间倒序，
 *     新投稿插到最前才符合「订阅流」的直觉（旧的沉到底部）。
 *
 * 超上限时从**尾部**截断（保留最新的），并回报 dropped 供界面提示。
 */
export function mergeUpTracks(playlistId: string, incoming: Track[]): {
  playlist: Playlist | null;
  added: number;
  dropped: number;
} {
  const current: Playlist | null = getPlaylist(playlistId);
  if (!current) {
    return { playlist: null, added: 0, dropped: 0 };
  }
  const have: Set<string> = new Set(current.tracks.map((t: Track): string => t.id));
  const fresh: Track[] = incoming.filter((t: Track): boolean => {
    return typeof t.id === 'string' && t.id.length > 0 && !have.has(t.id);
  });
  if (fresh.length === 0) {
    return { playlist: current, added: 0, dropped: 0 };
  }
  // 加入时间戳盖章（同批同戳 → 比较器批内保 pubdate 序；拷贝盖章不污染拉新
  // 返回的原实例）：歌单详情「按加入时间」排序靠它。
  const stamp: string = new Date().toISOString();
  const stampedFresh: Track[] = fresh.map((t: Track): Track => Object.assign({}, t, { addedAt: stamp }));
  let merged: Track[] = [...stampedFresh, ...current.tracks];
  // 「新的排前面」与「按名称排序」是两种互斥的顺序观：订阅流要的是时间序（新的最前），
  // 排序规则要的是名字序。用户既然对这个歌单开了排序规则，就以规则为准重新排 ——
  // 否则点一次「拉取新投稿」就把顺序搅乱，规则名存实亡。
  if (isTitleSorted(current)) {
    merged = sortTracksByTitle(merged);
  }
  let dropped: number = 0;
  if (merged.length > PLAYLIST_MAX_ITEMS) {
    dropped = merged.length - PLAYLIST_MAX_ITEMS;
    merged = merged.slice(0, PLAYLIST_MAX_ITEMS);
  }
  const next: Playlist = Object.assign({}, current, {
    tracks: merged,
    // 封面留空时用新投稿的封面顶上，订阅歌单不至于是一张白图
    coverUrl: current.coverUrl || (merged[0] ? merged[0].coverUrl : ''),
    updatedAt: new Date().toISOString()
  });
  updatePlaylist(next);
  return { playlist: next, added: fresh.length, dropped: dropped };
}

// ===== 曲目排序（歌单详情页：长按拖动 + 自动排序） =====

/**
 * 自动排序键（歌单详情页「排序」菜单）：
 *  · title     — 按歌名升序（中文拼音序，复用 compareByTitle）；
 *  · duration  — 按时长降序（长在前，无时长 0 沉底）；
 *  · playCount — 按播放量降序（高在前，无数据 0 沉底）；
 *  · addedTime — 按加入歌单时间降序（新在前；无戳存量首排时物化，见
 *    sortPlaylistTracks / materializeAddedAt）。
 * 自动排序是**一次性动作**：不打开旧的 titleSorted 持续规则（那是历史遗留语义，
 * 此后加歌自动按名插入会反过来破坏用户刚排好的顺序，不再扩展）。
 */
export type PlaylistSortKey = 'title' | 'duration' | 'playCount' | 'addedTime';

/**
 * 移动单曲到目标下标（歌单详情页「长按拖动排序」落库）。
 *
 * 语义按 **trackId 定位、toIndex 落点**：from 由拖拽方在数据里查（切片下标即全量
 * 下标 —— 详情页 tracks 是 playlist.tracks 的前缀切片），这里不接收 from 下标，
 * 避免「传错下标删错歌」这类灾难；id 找不到 / 歌单不存在 / 原地移动 都返回 false
 * 且**不落盘**。
 *
 * 与拖动排序手动顺序优先的原则一致：本函数会把 titleSorted 置 false
 *（旧的「按名插入」规则若还开着，下一次加歌会把刚拖好的顺序搅乱）。
 */
export function movePlaylistTrack(playlistId: string, trackId: string, toIndex: number): boolean {
  const current: Playlist | null = getPlaylist(playlistId);
  if (!current) {
    return false;
  }
  const fromIndex: number = current.tracks.findIndex((t: Track): boolean => t.id === trackId);
  if (fromIndex < 0) {
    return false;
  }
  const total: number = current.tracks.length;
  // clamp：负值 / 越界一律收进合法区间（防御性，正常拖拽不会触发）
  const target: number = Math.max(0, Math.min(Math.floor(toIndex), total - 1));
  if (target === fromIndex) {
    return false;
  }
  const tracks: Track[] = [...current.tracks];
  const moved: Track = tracks.splice(fromIndex, 1)[0];
  tracks.splice(target, 0, moved);
  updatePlaylist(Object.assign({}, current, {
    tracks: tracks,
    updatedAt: new Date().toISOString(),
    titleSorted: false
  }));
  return true;
}

/**
 * 「按加入时间」排序前的存量物化：
 * 老数据 / 拖动过的歌单没有 addedAt 戳，真实加入序已不可恢复，只能按加歌
 * 方向推定 ——
 *  · 普通歌单：加歌尾插（数组序 = 加入正序）→ 无戳条目按 index 升序补戳；
 *  · 订阅 UP 歌单：拉新头插（数组序 = 加入倒序）→ 无戳条目按 index 降序补戳；
 *  · 收藏夹镜像不进本函数（排序入口 canReorder 已门控）。
 * 合成戳基准压到「比一切真戳更早」（base = 最早真戳 - (n+1) 秒，第 i 个 +1 秒
 * 递增）：首排即得「新在前」，且此后重复排序 / 新加真戳歌的结果都稳定（幂等）。
 * 全程对象拷贝盖章，不改原 Track 实例（可能与队列 / 最近播放共享引用）。
 */
function materializeAddedAt(playlist: Playlist, indexed: { track: Track; index: number }[]): void {
  // 最早真戳（ms）；无任何真戳 → 用当前时间做锚（合成戳整体落在「现在之前」）
  let minStampedMs: number = Date.now();
  let hasStamp: boolean = false;
  for (let i = 0; i < indexed.length; i++) {
    const s: string = indexed[i].track.addedAt ?? '';
    if (s.length > 0) {
      const ms: number = Date.parse(s);
      if (!Number.isNaN(ms) && (!hasStamp || ms < minStampedMs)) {
        minStampedMs = ms;
        hasStamp = true;
      }
    }
  }
  const unstamped: { track: Track; index: number }[] =
    indexed.filter((e: { track: Track; index: number }): boolean => (e.track.addedAt ?? '').length === 0);
  if (unstamped.length === 0) {
    return;
  }
  const upSub: boolean = isUpSubscription(playlist);
  unstamped.sort((a: { track: Track; index: number }, b: { track: Track; index: number }): number => {
    return upSub ? b.index - a.index : a.index - b.index;
  });
  const baseMs: number = minStampedMs - (unstamped.length + 1) * 1000;
  for (let i = 0; i < unstamped.length; i++) {
    // 写回 indexed 对应槽位（unstamped 持的是同一 entry 引用）
    unstamped[i].track = Object.assign({}, unstamped[i].track, {
      addedAt: new Date(baseMs + i * 1000).toISOString()
    });
  }
}

/**
 * 歌单曲目自动排序（歌单详情页「排序」菜单落库）。
 * 排序方向见 PlaylistSortKey 注释；同值条目保持原相对顺序（排序稳定性由
 * 下标兜底，同 compareByTitle 的做法，不依赖引擎 sort 稳定性）。
 * @returns 排序后的歌单；id 不存在返回 null。
 */
export function sortPlaylistTracks(playlistId: string, key: PlaylistSortKey): Playlist | null {
  const current: Playlist | null = getPlaylist(playlistId);
  if (!current) {
    return null;
  }
  const indexed: { track: Track; index: number }[] = [];
  for (let i = 0; i < current.tracks.length; i++) {
    indexed.push({ track: current.tracks[i], index: i });
  }
  // addedTime：先给无戳存量条目物化补合成时间戳（见 materializeAddedAt）
  if (key === 'addedTime') {
    materializeAddedAt(current, indexed);
  }
  // 比较器统一 (a, b) => number：值大的排前面（降序），同值按下标保原序。
  indexed.sort((a: { track: Track; index: number }, b: { track: Track; index: number }): number => {
    if (key === 'addedTime') {
      // addedAt 降序（ISO 定宽定格式，字典序 = 时间序）；同戳 / 残留无戳保原序
      const av: string = a.track.addedAt ?? '';
      const bv: string = b.track.addedAt ?? '';
      if (av.length > 0 && bv.length > 0 && av !== bv) {
        return av < bv ? 1 : -1;
      }
      if (av.length > 0 && bv.length === 0) {
        return -1;
      }
      if (av.length === 0 && bv.length > 0) {
        return 1;
      }
      return a.index - b.index;
    }
    let primary: number = 0;
    if (key === 'duration') {
      primary = (b.track.duration || 0) - (a.track.duration || 0);
    } else if (key === 'playCount') {
      primary = (b.track.playCount || 0) - (a.track.playCount || 0);
    }
    if (primary !== 0) {
      return primary;
    }
    if (key === 'duration' || key === 'playCount') {
      // 降序键同值：保原相对顺序
      return a.index - b.index;
    }
    // title：走拼音比较器（内含同名保原序）
    return compareByTitle(a.track, b.track, a.index, b.index);
  });
  const tracks: Track[] = [];
  for (let i = 0; i < indexed.length; i++) {
    tracks.push(indexed[i].track);
  }
  const next: Playlist = Object.assign({}, current, {
    tracks: tracks,
    updatedAt: new Date().toISOString(),
    titleSorted: false
  });
  updatePlaylist(next);
  return next;
}

/**
 * 订阅：把某个 UP 的投稿存成「订阅歌单」。
 *
 * 同一个 UP 重复订阅 → **复用**已有歌单并合并，不新建第二个（否则用户点几次就多出
 * 几个同名歌单，还互相不同步）。upName 之后被 B 站改名不影响已存歌单（名字只是展示）。
 */
export function subscribeUpPlaylist(
  upMid: string,
  upName: string,
  tracks: Track[],
  coverUrl: string
): UpSubscribeResult {
  const existing: Playlist | null = getPlaylistByUpMid(upMid);
  if (existing) {
    const merged: { playlist: Playlist | null; added: number; dropped: number } =
      mergeUpTracks(existing.id, tracks);
    return {
      playlist: merged.playlist ?? existing,
      added: merged.added,
      dropped: merged.dropped,
      reused: true
    };
  }
  const name: string = `${upName.length > 0 ? upName : '该 UP 主'} 的投稿`;
  const created: Playlist = createPlaylist({
    name: name,
    coverUrl: coverUrl || (tracks[0] ? tracks[0].coverUrl : ''),
    upMid: upMid,
    upName: upName
  });
  // 首批同批盖章加入时间戳（同批同戳 → 批内保 pubdate 序）：「按加入时间」排序靠它
  const stamp: string = new Date().toISOString();
  const kept: Track[] = tracks.slice(0, PLAYLIST_MAX_ITEMS)
    .map((t: Track): Track => Object.assign({}, t, { addedAt: stamp }));
  const dropped: number = Math.max(0, tracks.length - kept.length);
  const withTracks: Playlist = Object.assign({}, created, { tracks: kept });
  updatePlaylist(withTracks);
  return { playlist: withTracks, added: kept.length, dropped: dropped, reused: false };
}

// ===== 收藏夹镜像（B 站收藏夹 → 本地歌单）=====

/** 收藏夹镜像应用结果：同步管理器据此汇总「新增 / 移除 / 复用」 */
export interface FavMirrorResult {
  playlist: Playlist | null;
  /** 本次新增（服务端有、本地没有）的条目数 */
  added: number;
  /** 本次移除（本地有、服务端已没有）的条目数；只增模式恒为 0 */
  removed: number;
  /** true = 复用了已有镜像歌单；false = 本次新建 */
  reused: boolean;
}

/**
 * 把一个收藏夹的当前内容应用到本地镜像歌单（「建或合并」原语，形态同 subscribeUpPlaylist）。
 *
 * ⚠️ **`allowDelete` 是安全核心，由调用方（FavSyncManager）按门控计算**：
 *   · `false`（本轮未完整拉取 / 收藏夹超上限 / 收藏夹列表本身没拉到）→ **只增不减**，
 *     本地原有条目一律保留 —— 否则会把「没拉到」误判成「已取消收藏」而误删用户数据；
 *   · `true`（已确认服务端数据完整）→ **以服务端为准**：按服务端顺序重建，服务端已没有
 *     的本地条目被移除。
 *
 * ⚠️ 同步是**单向的（B 站 → 本地）**：本地对镜像歌单
 *   的增删改动**不会写回 B 站**，因此下一轮同步会把本地状态对齐回服务端 —— 本地新加的
 *   歌会被移除、本地删掉的歌会重新拉回。这是有意的产品语义。
 *
 * 双向重建时**强制保留本地独占字段**（localFilePath / playedAt / isLiked / lastPosSec /
 * audioUrl）—— 否则「用服务端数据整体替换」会让已下载的曲目脱链、丢失播放进度与红心。
 *
 * 落盘：一次性构造完整 Playlist 后单次 updatePlaylist。**禁止逐首 addTrackToPlaylist**
 * （它每次全量重写所有分片，N 首 = N 次全量重写）。
 */
export function applyFavMirror(
  favTitle: string,
  mediaId: number,
  serverTracks: Track[],
  allowDelete: boolean
): FavMirrorResult {
  const displayTitle: string = favTitle.length > 0 ? favTitle : 'B 站收藏夹';
  const name: string = `${displayTitle}（收藏夹）`;
  const sourceId: string = favSourceId(mediaId);
  const cover: string = serverTracks.length > 0 ? serverTracks[0].coverUrl : '';
  const existing: Playlist | null = getFavMirrorByMediaId(mediaId);

  /**
   * 第三道防线：`serverTracks` 为空时**一律禁止删除**。
   * 上层 FavSyncManager 已按「emptySuspect」门控过一次，这里再拦一次 ——
   * 「0 条」既可能是用户清空，也可能是风控把响应拦成空，二者从数据上无法区分，
   * 而误删的代价是整张歌单消失。所以宁可少删（下次同步再对齐），不可错删。
   */
  const canDelete: boolean = allowDelete && serverTracks.length > 0;

  // 首次同步：新建镜像歌单
  if (!existing) {
    const created: Playlist = createPlaylist({
      name: name,
      coverUrl: cover,
      upMid: sourceId,
      upName: favTitle,
      sourceKind: 'fav'
    });
    const kept: Track[] = serverTracks.slice(0, PLAYLIST_MAX_ITEMS);
    const withTracks: Playlist = Object.assign({}, created, { tracks: kept });
    updatePlaylist(withTracks);
    return { playlist: withTracks, added: kept.length, removed: 0, reused: false };
  }

  const localById: Map<string, Track> = new Map<string, Track>();
  for (let i = 0; i < existing.tracks.length; i++) {
    localById.set(existing.tracks[i].id, existing.tracks[i]);
  }

  let merged: Track[] = [];
  let added: number = 0;
  let removed: number = 0;

  if (!canDelete) {
    // 只增不减：新条目前置，本地原有条目（含顺序）原样保留
    const fresh: Track[] = [];
    for (let i = 0; i < serverTracks.length; i++) {
      const st: Track = serverTracks[i];
      if (!localById.has(st.id)) {
        fresh.push(st);
      }
    }
    added = fresh.length;
    merged = fresh.concat(existing.tracks);
  } else {
    // 以服务端为准：按服务端顺序重建
    const serverIds: Set<string> = new Set<string>();
    for (let i = 0; i < serverTracks.length; i++) {
      const st: Track = serverTracks[i];
      serverIds.add(st.id);
      const local: Track | undefined = localById.get(st.id);
      if (!local) {
        added = added + 1;
        merged.push(st);
      } else {
        // ⚠️ 保留本地独占字段：只换服务端可能变化的展示字段，不动本地状态
        merged.push(Object.assign({}, st, {
          localFilePath: local.localFilePath,
          playedAt: local.playedAt,
          isLiked: local.isLiked,
          likedAt: local.likedAt,
          lastPosSec: local.lastPosSec,
          audioUrl: local.audioUrl
        }));
      }
    }
    // 本地有、服务端已没有 → 视为「已在 B 站取消收藏」，本轮移除（单向同步以服务端为准）
    for (let i = 0; i < existing.tracks.length; i++) {
      const lt: Track = existing.tracks[i];
      if (!serverIds.has(lt.id)) {
        removed = removed + 1;
      }
    }
    if (merged.length > PLAYLIST_MAX_ITEMS) {
      merged = merged.slice(0, PLAYLIST_MAX_ITEMS);
    }
  }

  const updated: Playlist = Object.assign({}, existing, {
    // 名称与来源名跟随 B 站：用户可在本地改，但下次同步以 B 站为准（已确认的产品语义）
    name: name,
    upName: favTitle,
    upMid: sourceId,
    sourceKind: 'fav',
    coverUrl: existing.coverUrl.length > 0 ? existing.coverUrl : cover,
    tracks: merged,
    updatedAt: new Date().toISOString()
  });
  updatePlaylist(updated);
  return { playlist: updated, added: added, removed: removed, reused: true };
}

// ===== 删除墓碑（云同步用，避免被对端复活） =====

function loadPlaylistTombstones(): Tombstone[] {
  return AppPreferences.getPlaylistTombstones<Tombstone>();
}

function savePlaylistTombstones(list: Tombstone[]): void {
  AppPreferences.savePlaylistTombstones<Tombstone>(list);
}

function addPlaylistTombstone(id: string): void {
  const list: Tombstone[] = loadPlaylistTombstones().filter((t: Tombstone): boolean => t.id !== id);
  list.push({ id: id, deletedAt: new Date().toISOString() });
  savePlaylistTombstones(list);
}

function loadFavoriteTombstones(): Tombstone[] {
  return AppPreferences.getFavoriteTombstones<Tombstone>();
}

function saveFavoriteTombstones(list: Tombstone[]): void {
  AppPreferences.saveFavoriteTombstones<Tombstone>(list);
}

function addFavoriteTombstone(id: string): void {
  const list: Tombstone[] = loadFavoriteTombstones().filter((t: Tombstone): boolean => t.id !== id);
  list.push({ id: id, deletedAt: new Date().toISOString() });
  saveFavoriteTombstones(list);
}

function removeFavoriteTombstone(id: string): void {
  saveFavoriteTombstones(loadFavoriteTombstones().filter((t: Tombstone): boolean => t.id !== id));
}

/**
 * 导出歌单（JSON 对象，交给调用方序列化后写进剪贴板）。
 *
 * ⚠️ **导出必须剥掉 `localFilePath`**：内存快照里的曲目带本机绝对路径
 * （`slimTrack` 故意保留它，否则「播着下载好的歌 → 关 App → 重开」就找不到文件），
 * 但这个路径换到别的设备上必然无效，写进导出文件只会误导人以为「导入后就能离线播」。
 * `audioUrl` 则本来就被 `slimTrack` 置空（直链带签名、会过期），所以导出后首次播放
 * 需要重新解析音源 —— 这是预期行为。
 */
export function createPlaylistsExport(): object {
  const playlists: Playlist[] = getPlaylists();
  const out: object[] = [];
  for (let i = 0; i < playlists.length; i++) {
    const p: Playlist = playlists[i];
    const tracks: Track[] = [];
    for (let k = 0; k < p.tracks.length; k++) {
      const slim: Track = slimTrack(p.tracks[k]);
      tracks.push({ ...slim, localFilePath: '' });
    }
    out.push({
      id: p.id,
      name: p.name,
      description: p.description,
      coverUrl: p.coverUrl,
      createdAt: p.createdAt,
      updatedAt: p.updatedAt,
      // 订阅来源一起带走：否则导入后「拉取新投稿」入口消失
      upMid: p.upMid,
      upName: p.upName,
      // 来源种类一起带走：否则导入后收藏夹镜像会被当成「订阅 UP 歌单」误显
      sourceKind: p.sourceKind ?? '',
      // 排序规则一起带走：导入后曲目顺序本来就是排过的，
      // 不带上标记的话「以后新增按名插入」这条规则会在导入的那台设备上失效
      titleSorted: p.titleSorted === true,
      tracks: tracks
    });
  }
  return {
    app: 'biliMusic',
    type: 'playlists',
    version: 1,
    exportedAt: new Date().toISOString(),
    playlists: out
  };
}

/** 导入结果。**必须是命名 interface**：ArkTS 禁止把对象字面量当类型用
 *  （`arkts-no-obj-literals-as-types`），写成 `{ imported: number; skipped: number }` 会在 .ets 里编译报错。 */
export interface PlaylistImportResult {
  /** 成功导入的歌单数 */
  imported: number;
  /** 因字段不全 / 重名等被跳过的条目数 */
  skipped: number;
}

export function importPlaylistsFromText(text: string): PlaylistImportResult {
  const parsed = JSON.parse(text);
  const incoming: Playlist[] = Array.isArray(parsed) ? parsed : parsed?.playlists;
  if (!Array.isArray(incoming)) {
    throw new Error('文件中没有找到歌单列表');
  }

  const now: string = new Date().toISOString();
  const existing: Playlist[] = getPlaylists();
  const existingIds: Set<string> = new Set<string>(existing.map((p: Playlist): string => p.id));
  const existingNames: Set<string> = new Set<string>(existing.map((p: Playlist): string => p.name.trim()));
  // 已被镜像的收藏夹 media_id：导入文件里若又带同一个收藏夹的镜像，必须降级为普通歌单 ——
  // 否则会出现「同一收藏夹两个镜像」，而 `getFavMirrorByMediaId` 只取首个，
  // 另一个永远不再被同步、也不会被清理（同步链路看不到它）。
  const mirroredMediaIds: Set<number> = new Set<number>();
  for (let i = 0; i < existing.length; i++) {
    if (isFavMirror(existing[i])) {
      const mid: number = favMediaIdOf(existing[i]);
      if (mid > 0) {
        mirroredMediaIds.add(mid);
      }
    }
  }
  const imported: Playlist[] = [];
  let skipped: number = 0;

  for (let i = 0; i < incoming.length; i++) {
    const item: Playlist = incoming[i];
    if (!item || typeof item.name !== 'string' || !Array.isArray(item.tracks)) {
      skipped++;
      continue;
    }
    const name: string = item.name.trim();
    if (!name) {
      skipped++;
      continue;
    }
    const id: string = item.id && !existingIds.has(item.id) ? item.id : createId();
    existingIds.add(id);
    const finalName: string = existingNames.has(name) ? `${name} 导入` : name;
    existingNames.add(finalName);
    // 逐首过一遍 slimTrack + 清空 localFilePath：
    //   · slimTrack 统一字段（顺手把 audioUrl 置空，避免用到已过期的签名直链）；
    //   · 导入文件里可能带**来源设备**的本机路径，无效且误导，清掉；
    //   · 顺手挡掉畸形条目（tracks 里混进 null / 非对象会让 persistPlaylists 的
    //     slimTrack 读到 undefined 字段 —— 见 slimTrack 注释里那段踩坑）。
    const tracks: Track[] = [];
    let badTrack: boolean = false;
    for (let k = 0; k < item.tracks.length; k++) {
      const t: Track = item.tracks[k];
      if (!t || typeof t !== 'object' || typeof t.id !== 'string' || t.id.length === 0) {
        badTrack = true;
        break;
      }
      // addedAt = 导入时刻（跨设备的真实加入时间不可信；同批同戳 → 批内保文件序）
      tracks.push({ ...slimTrack(t), localFilePath: '', addedAt: now });
    }
    if (badTrack) {
      skipped++;
      continue;
    }
    // 来源字段：导入文件里可能带订阅来源（旧版本导出的歌单没有这两个字段 → 空串 = 普通歌单）。
    // 老导出文件没有 sourceKind → 按 upMid 非空兜底为 'up'（与 toPlaylist 同口径）。
    const rawUpMid: string = item.upMid || '';
    let upMid: string = rawUpMid;
    let upName: string = item.upName || '';
    let sourceKind: string = item.sourceKind ?? (rawUpMid.length > 0 ? 'up' : '');
    if (sourceKind === 'fav') {
      const mid: number = favMediaIdFromSourceId(rawUpMid);
      if (mid > 0 && mirroredMediaIds.has(mid)) {
        // 该收藏夹已有镜像 → 这份导入降级为普通歌单（不再参与同步，避免双镜像）
        upMid = '';
        upName = '';
        sourceKind = '';
      } else if (mid > 0) {
        mirroredMediaIds.add(mid);
      }
    }
    imported.push({
      id: id,
      name: finalName,
      description: item.description || '',
      coverUrl: item.coverUrl || tracks[0]?.coverUrl || '',
      tracks: tracks,
      createdAt: item.createdAt || now,
      updatedAt: now,
      upMid: upMid,
      upName: upName,
      sourceKind: sourceKind,
      // 同理带上排序规则；老导出文件没这个字段 → false = 未开启
      titleSorted: item.titleSorted === true
    });
  }

  if (imported.length > 0) {
    // 必须走 persistPlaylists：直接写 Preferences 不会更新内存快照，导入后读到的还是旧列表
    persistPlaylists([...imported, ...getPlaylists()]);
  }
  return { imported: imported.length, skipped: skipped };
}

/** 命名空间导出：供 `import { LibraryStore }` 以对象方式调用。 */
export const LibraryStore = {
  getRecentTracks,
  addRecentTrack,
  removeRecentTrack,
  clearRecentTracks,
  updateRecentProgress,
  getRecentProgressSec,
  getFavoriteTracks,
  toggleFavoriteTrack,
  getPlaylists,
  getAddablePlaylists,
  createPlaylist,
  nextPlaylistNameForTrack,
  getPlaylist,
  updatePlaylist,
  movePlaylist,
  renamePlaylist,
  deletePlaylist,
  addTrackToPlaylist,
  addTracksToPlaylist,
  removeTracksFromPlaylist,
  movePlaylistTrack,
  sortPlaylistTracks,
  sortAllPlaylistsByTitle,
  sortPlaylistByTitle,
  clearPlaylistTitleSort,
  previewPlaylistMerge,
  mergePlaylists,
  getPlaylistByUpMid,
  mergeUpTracks,
  subscribeUpPlaylist,
  FAV_SOURCE_PREFIX,
  favSourceId,
  favMediaIdFromSourceId,
  isUpSubscription,
  isFavMirror,
  getFavMirrorByMediaId,
  favMediaIdOf,
  applyFavMirror,
  consumeFavMirrorSkippedCount,
  createPlaylistsExport,
  importPlaylistsFromText
};
