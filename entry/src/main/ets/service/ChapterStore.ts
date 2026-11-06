/**
 * 视频章节分段加载编排。
 *
 * 五层获取链（按序短路，解决「同一音频有人显示分段有人不显示」的全覆盖设计）：
 *   ① 持久化缓存（ChapterCacheStore，7 天 TTL 文件 KV）—— 冷启动 / 断网 /
 *      风控期命中免网络直接发布；
 *   ② 官方源 view_points（`x/player/wbi/v2`，SubtitleLyricApi.fetchVideoChapters）
 *      —— 登录态与 412 风控敏感，拿到即落盘 ①；
 *   ③ 简介时间戳兜底（SubtitleLyricApi.fetchChaptersFromDescription）——
 *      公开接口不依赖登录，官方源结论性空时解析 UP 主手写目录，命中即落盘 ①；
 *   ④ 置顶评论时间戳兜底（SubtitleLyricApi.fetchChaptersFromTopComment）——
 *      公开接口 + 会话缓存（topReplyCache），简介源结论性空时解析 UP 主
 *      置顶楼手写目录（仅 isTop=true 真置顶，热门首评不解析），命中即落盘 ①；
 *   ⑤ 空定格 —— 官方 / 简介 / 置顶评论都结论性为空，会话内定格不再请求
 *      （空不落盘：分段可能后来才新增，新会话重查自然覆盖）。
 *
 * 编排纪律（与旧版一致）：
 *   · 去重：同一曲目（键 = track.id，分P 曲目含 `BV…#cid` 后缀天然区分）
 *     已加载 / 在途不重复发请求；切歌竞态用令牌保证只采纳最后一次结果。
 *   · 发布：结果（含空）整表写 AppStorage STORE_VIDEO_CHAPTERS，消费端
 *     （功能行按钮 / 分段列表弹层 / 进度条刻度）@StorageProp 只读订阅。
 *   · 失败分级：瞬时失败（网络 / 风控 / 串台）不记「已加载」，下次打开
 *     播放页自然重试；结论性「无分段」定格，会话内不再请求。
 *   · 非站内曲目（本地下载缓存 / 网易歌单导入 / 直播）一律空数组。
 *
 * 全链 try/catch 永不抛：章节是增强功能，绝不能成为播放链路的崩溃源。
 */

import { Track, VideoChapter } from '../model/MusicModels';
import { STORE_VIDEO_CHAPTERS } from '../common/Constants';
import {
  resolveSubtitleTarget,
  fetchVideoChapters,
  fetchChaptersFromDescription,
  fetchChaptersFromTopComment,
  SubtitleTargetResolve
} from '../api/SubtitleLyricApi';
import { loadCachedChapters, saveCachedChapters } from './ChapterCacheStore';

/** 令牌：换歌时旧请求作废（网络往返期间可能已切歌，只采纳最后一次） */
let loadToken: number = 0;
/** 已定格的曲目键（结果已发布，重复请求拦截） */
let loadedKey: string = '';
/** 在途的曲目键（请求进行中，重复请求拦截） */
let loadingKey: string = '';

/** 发布当前曲章节（整表 slice 新引用，见 STORE_VIDEO_CHAPTERS 注释） */
function publishChapters(chapters: VideoChapter[]): void {
  AppStorage.setOrCreate(STORE_VIDEO_CHAPTERS, chapters.slice());
}

/**
 * 同步解析曲目 cid（持久化缓存查询键）：id 的 `BV…#cid` 后缀 > track.cid。
 * 与 resolveSubtitleTarget 的 cid 优先级完全同口径（分 P 曲目的 id 后缀是
 * 队列 / 下载链路共用的权威身份）；两者都缺返回空串 —— 此时缓存查询延后
 * 到 resolve 成功后用 target.cid 再查。
 */
function extractTrackCid(track: Track): string {
  let cid: string = track.cid;
  const hashIdx: number = track.id.indexOf('#');
  if (hashIdx >= 0) {
    const tail: string = track.id.substring(hashIdx + 1);
    if (tail.length > 0 && /^\d+$/.test(tail)) {
      cid = tail;
    }
  }
  return cid;
}

/**
 * 加载当前曲的章节分段（ControlAreaComponent 首挂载 + 切歌 @Watch 调用）。
 * fire-and-forget：结果只经 STORE_VIDEO_CHAPTERS 发布，无返回值、不抛错。
 */
export function loadChaptersForTrack(track: Track | null): void {
  // fire-and-forget 壳：内部 async，调用方零等待零异常
  runLoad(track).then((): void => {}).catch((e: Object): void => {
    console.error(`[Chapter] load unexpected failed: ${JSON.stringify(e)}`);
  });
}

async function runLoad(track: Track | null): Promise<void> {
  const key: string = track !== null && track !== undefined ? track.id : '';
  if (key === loadedKey || key === loadingKey) {
    return;
  }
  if (track === null || track === undefined) {
    loadedKey = key;
    publishChapters([]);
    return;
  }
  // 非站内曲目（本地 / 网易 / 直播）没有 view_points，直接定格空
  if (!track.id.startsWith('BV') && !track.bvid.startsWith('BV')) {
    loadedKey = key;
    publishChapters([]);
    return;
  }
  const token: number = ++loadToken;
  loadingKey = key;
  // ── ① 持久化缓存：cid 可同步解析时免任何网络（冷启动秒出）──
  let cid: string = extractTrackCid(track);
  if (cid.length > 0) {
    const cached: VideoChapter[] | null = loadCachedChapters(cid);
    if (cached !== null) {
      loadingKey = '';
      loadedKey = key;
      publishChapters(cached);
      return;
    }
  }
  const resolved: SubtitleTargetResolve = await resolveSubtitleTarget(track);
  if (token !== loadToken) {
    return;
  }
  if (resolved.target === null) {
    console.info(`[Chapter] resolve target failed reason=${resolved.reason} track=${track.title}`);
    loadingKey = '';
    // no-target = 结论性（本地化失败 / 身份缺失）；network 等瞬时态留待重试
    if (resolved.reason === 'no-target') {
      loadedKey = key;
    }
    publishChapters([]);
    return;
  }
  // ── ①' cid 之前缺失（resolve 网络补的 P1 cid）：用权威 cid 再查一次缓存 ──
  cid = resolved.target.cid;
  const cachedLate: VideoChapter[] | null = loadCachedChapters(cid);
  if (cachedLate !== null) {
    loadingKey = '';
    loadedKey = key;
    publishChapters(cachedLate);
    return;
  }
  // ── ② 官方源 view_points ──
  const chapters: VideoChapter[] | null = await fetchVideoChapters(resolved.target);
  if (token !== loadToken) {
    return;
  }
  if (chapters === null) {
    // 瞬时失败（网络 / 风控 / 串台）：不记 loadedKey，下次打开播放页重试；
    // 先发布空保持 UI 一致
    loadingKey = '';
    publishChapters([]);
    return;
  }
  if (chapters.length > 0) {
    loadingKey = '';
    loadedKey = key;
    saveCachedChapters(cid, chapters);
    publishChapters(chapters);
    return;
  }
  // ── ③ 简介时间戳兜底：官方源结论性空（view_points 无章节条目）──
  const descChapters: VideoChapter[] = await fetchChaptersFromDescription(
    resolved.target.bvid,
    cid,
    track.duration
  );
  if (token !== loadToken) {
    return;
  }
  if (descChapters.length > 0) {
    loadingKey = '';
    loadedKey = key;
    saveCachedChapters(cid, descChapters);
    publishChapters(descChapters);
    return;
  }
  // ── ④ 置顶评论时间戳兜底：简介也结论性空（仅 UP 主真置顶楼，热门首评不解析）──
  const replyChapters: VideoChapter[] = await fetchChaptersFromTopComment(
    resolved.target.aid,
    track.duration
  );
  if (token !== loadToken) {
    return;
  }
  loadingKey = '';
  loadedKey = key;
  if (replyChapters.length > 0) {
    saveCachedChapters(cid, replyChapters);
    publishChapters(replyChapters);
    return;
  }
  // ── ⑤ 空定格：官方 / 简介 / 置顶评论都结论性为空（空不落盘，新会话重查可覆盖）──
  publishChapters([]);
}
