/**
 * Track 过滤纯函数工具（与 TrackDedup 同级的曲目纯函数工具）。
 *
 * 三页页面内搜索（歌单详情 / UP 主页 / 合集分 P）共用同一套本地过滤谓词：
 * 标题 / 歌手包含关键词（小写化匹配），输入即生效、离线可用。
 * 原先三页各写一份 `applyLocalFilter` 内联谓词，改一边口径就漂移 ——
 * 收口到这里，三页行为由同一份实现保证。
 */

import { Track } from '../model/MusicModels';

/**
 * 按关键词过滤曲目列表（标题 / 歌手包含匹配，小写化）。
 *
 * 空关键词返回空数组：调用方约定「空数组 = 无关键词或 0 命中」，
 * 用关键词是否非空区分两态（与三页 filteredTracks 的既有语义一致）。
 * 纯函数：不改入参数组，结果为新数组，调用方整表赋值给 @State。
 */
export function filterTracksByKeyword(tracks: Track[], keyword: string): Track[] {
  const kw: string = keyword.trim().toLowerCase();
  if (kw.length === 0) {
    return [];
  }
  return tracks.filter((t: Track): boolean => {
    return t.title.toLowerCase().indexOf(kw) >= 0
      || t.artist.toLowerCase().indexOf(kw) >= 0;
  });
}
