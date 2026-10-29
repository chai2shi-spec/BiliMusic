/**
 * 在线条目「先查后分流」导航助手。
 *
 * 背景：列表条目（搜索 / 首页 / UP 主页）在渲染时**无法预知**是不是
 * 多 P 合集（Track 不带分 P 数，判定需要一次 view 请求）。点击行为的
 * 期望分叉是：
 *   · 多 P 合集（「N 首精选」这类）→ 跳「合集详情页」（CollectionDetail）
 *     浏览分 P、多选批量下载 / 加入歌单；
 *   · 单视频 / 具体分 P → 维持既有行为，直接播放。
 *
 * 分流规则（顺序短路）：
 *   1. track 已是具体分 P（id 含 '#' 或 cid 非空，来自歌单 / 队列）→ 直播；
 *   2. 非 BV 条目（音乐中心伪 id 等，无法 view）→ 直播；
 *   3. 纯 bvid 条目 → getVideoDetail（viewCache 命中瞬时，重复点击零开销）：
 *     · videos > 1 → push CollectionDetail（首帧兜底值取自入口条目）；
 *     · 单视频 / 请求失败 → 直播（失败绝不阻断播放，回落旧体验）。
 *
 * 刻意用 .ets 而不是 .ts：依赖 NavStackHolder / NavRouteParams（均为 .ets），
 * ArkTS 禁止 .ts 引 .ets；页面侧经无扩展名 import 引用，两种后缀无感。
 */

import { Track } from '../model/MusicModels';
import { getVideoDetail } from '../api/BilibiliApi';
import { MusicPlayer } from '../player/MusicPlayer';
import { NavStackHolder } from '../service/NavStackHolder';
import { CollectionDetailRouteParam } from '../service/NavRouteParams';

/** 分流进行中守卫：view 请求在途时忽略重复点击（防双播 / 双推） */
let dispatchInFlight: boolean = false;

/**
 * 点击在线条目的统一入口：合集跳详情页，其余直接播放。
 *
 * @param track 被点击的条目
 * @param player 播放内核（各页面持有的 MusicPlayer 单例）
 */
export async function openCollectionOrPlay(track: Track, player: MusicPlayer): Promise<void> {
  const id: string = track.id;
  // 具体分 P / 非 BV 条目：无需查询，直接走既有播放路径
  if (id.indexOf('#') >= 0 || track.cid.length > 0 || id.indexOf('BV') !== 0) {
    player.playOrToggle(track);
    return;
  }
  if (dispatchInFlight) {
    return;
  }
  dispatchInFlight = true;
  try {
    const detail = await getVideoDetail(id);
    if (detail.videos > 1) {
      NavStackHolder.push('CollectionDetail',
        new CollectionDetailRouteParam(id, track.title, track.coverUrl, track.artist, track.upMid));
      return;
    }
  } catch (e) {
    // view 失败（网络 / 风控）：回落直接播放，绝不因分流查询阻断点击
    const reason: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
    console.warn(`[CollectionNavigator] dispatch check failed, fallback to play: ${reason}`);
  } finally {
    dispatchInFlight = false;
  }
  player.playOrToggle(track);
}
