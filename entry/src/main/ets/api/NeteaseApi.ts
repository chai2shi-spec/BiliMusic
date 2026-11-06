/**
 * 网易云歌单接口（热门榜 + 歌单搜索 + 热歌榜，首页「热门歌单」chip /
 * 搜索页「歌单」页签 / 首页「热歌榜」chip 数据源）。
 *
 * 端点都是网易云老 web API（与 PlaylistImporter 的 v6/v3 直连同族，匿名可用）：
 *   · 热门榜：GET https://music.163.com/api/playlist/list?cat=全部&order=hot&limit=&offset=
 *     返回 `{ code, more, playlists: [...] }`；more = 还有下一页（分页游标 offset += limit）。
 *   · 歌单搜索：GET https://music.163.com/api/search/get/web?s=&type=1000&limit=&offset=
 *     返回 `{ code, result: { playlists: [...], playlistCount } }`（type=1000 = 歌单，
 *     offset 游标真分页；total 用 playlistCount 判 hasMore）。
 *   · 热歌榜：GET /api/v6/playlist/detail?id=3778678 拿榜单名 / 封面 / trackIds
 *     （完整 ID 顺序表 = 榜位序），再按 100 一批 GET /api/v3/song/detail 查
 *     名称 / 歌手 / 时长 / 专辑封面 —— 与 fetchNeteasePlaylist 完全同链
 *     （v6 的 tracks 数组只含前约 6 首，必须走 trackIds + v3 分批）。
 *
 * ⚠️ 隐私红线（PlaylistImporter 文件头同款）：请求网易云必须 skipCookie +
 * skipReferer —— HttpUtil 默认会自动附加 B 站 Cookie（buvid + 登录态）与
 * B 站 Referer，绝不能发给第三方；只带网易云自己的 Referer。
 *
 * 失败语义：接口返回异常（code≠200 / 字段缺失 / 网络错误）一律抛错，
 * 由调用方（HomePage netease / ranking 分支 / SearchPage 歌单页签）降级，
 * 不影响 B 站源。
 */

import { HttpUtil } from '../utils/HttpUtil';
import { toHttpsUrl } from '../utils/TextUtil';

/** 热门歌单列表条目（网格卡展示模型） */
export interface NeteasePlaylistSummary {
  /** 歌单 id（网易云 pid，String 化；预览页 fetchNeteasePlaylist 的定位符） */
  id: string;
  name: string;
  /** 封面（已转 https） */
  coverUrl: string;
  /** 歌单曲目数 */
  trackCount: number;
  /** 播放量（副题「N 万播放」口径） */
  playCount: number;
  /** 创建者昵称（空 = 未知） */
  creatorName: string;
}

/** 一次分页请求的结果：当前页歌单 + 是否还有下一页 */
export interface NeteaseHotPlaylistsResult {
  playlists: NeteasePlaylistSummary[];
  /** 接口 more 字段：true = 后面还有页 */
  hasMore: boolean;
}

//
// ─────────────────────────── 响应模型（逐字段校验） ───────────────────────────
//

interface NeteaseCreator {
  nickname?: string;
}

interface NeteaseRawPlaylist {
  id?: number;
  name?: string;
  coverImgUrl?: string;
  trackCount?: number;
  playCount?: number;
  creator?: NeteaseCreator;
}

interface NeteasePlaylistListResp {
  code?: number;
  more?: boolean;
  playlists?: NeteaseRawPlaylist[];
}

/**
 * 拉取一页网易云热门歌单。
 *
 * @param limit 每页条数（首页网格按 30 取）
 * @param offset 分页游标（0 起，下一页 += limit）
 */
export async function fetchNeteaseHotPlaylists(limit: number, offset: number): Promise<NeteaseHotPlaylistsResult> {
  const url: string = `https://music.163.com/api/playlist/list?cat=${encodeURIComponent('全部')}`
    + `&order=hot&limit=${limit}&offset=${offset}`;
  const resp: NeteasePlaylistListResp = await HttpUtil.requestJson<NeteasePlaylistListResp>(url, {
    skipCookie: true,
    skipReferer: true,
    headers: { 'Referer': 'https://music.163.com/' }
  });
  if (resp.code !== 200 || !Array.isArray(resp.playlists)) {
    throw new Error('网易云热门歌单接口返回异常');
  }
  return {
    playlists: mapNeteaseRawPlaylists(resp.playlists),
    hasMore: resp.more === true
  };
}

/**
 * 原始歌单数组 → 展示模型（热门榜 / 歌单搜索共用同构字段）：
 * 逐字段校验，id / name 是点击与展示的硬依赖，缺失即弃（脏条目自愈）。
 */
function mapNeteaseRawPlaylists(raw: NeteaseRawPlaylist[]): NeteasePlaylistSummary[] {
  const out: NeteasePlaylistSummary[] = [];
  for (let i = 0; i < raw.length; i++) {
    const p: NeteaseRawPlaylist = raw[i];
    const id: number | undefined = p.id;
    const name: string = typeof p.name === 'string' ? p.name : '';
    if (typeof id !== 'number' || id <= 0 || name.length === 0) {
      continue;
    }
    const creator: NeteaseCreator | undefined = p.creator;
    const summary: NeteasePlaylistSummary = {
      id: String(id),
      name: name,
      coverUrl: toHttpsUrl(typeof p.coverImgUrl === 'string' ? p.coverImgUrl : ''),
      trackCount: typeof p.trackCount === 'number' ? p.trackCount : 0,
      playCount: typeof p.playCount === 'number' ? p.playCount : 0,
      creatorName: creator !== undefined && typeof creator.nickname === 'string' ? creator.nickname : ''
    };
    out.push(summary);
  }
  return out;
}

/** 歌单搜索响应（api/search/get/web，type=1000） */
interface NeteaseSearchResp {
  code?: number;
  result?: {
    playlists?: NeteaseRawPlaylist[];
    /** 服务端歌单总数（hasMore 判定；缺省按 0 = 未知处理） */
    playlistCount?: number;
  };
}

/** 一次歌单搜索分页的结果：当前页歌单 + 服务端总数 */
export interface NeteasePlaylistSearchResult {
  playlists: NeteasePlaylistSummary[];
  /** playlistCount（0 = 未知：调用方 hasMore 判定放行试探一页） */
  total: number;
}

/**
 * 搜索网易云歌单（搜索页「歌单」页签数据源）。
 *
 * @param keyword 搜索词
 * @param limit 每页条数
 * @param offset 分页游标（0 起，下一页 += limit）
 */
export async function searchNeteasePlaylists(
  keyword: string,
  limit: number,
  offset: number
): Promise<NeteasePlaylistSearchResult> {
  const url: string = `https://music.163.com/api/search/get/web?s=${encodeURIComponent(keyword)}`
    + `&type=1000&limit=${limit}&offset=${offset}`;
  const resp: NeteaseSearchResp = await HttpUtil.requestJson<NeteaseSearchResp>(url, {
    skipCookie: true,
    skipReferer: true,
    headers: { 'Referer': 'https://music.163.com/' }
  });
  if (resp.code !== 200 || resp.result === undefined || !Array.isArray(resp.result.playlists)) {
    throw new Error('网易云歌单搜索接口返回异常');
  }
  return {
    playlists: mapNeteaseRawPlaylists(resp.result.playlists),
    total: typeof resp.result.playlistCount === 'number' ? resp.result.playlistCount : 0
  };
}

//
// ─────────────────────────── 热歌榜（首页 ranking tab 数据源） ───────────────────────────
//

/** 云音乐热歌榜固定歌单 id（网易云官方榜单歌单，与普通歌单同构可直连） */
export const NETEASE_HOT_CHART_ID: number = 3778678;

/** 热歌榜单曲（数组下标序 = 榜位序，调用方用 index+1 展示榜位） */
export interface NeteaseHotSong {
  title: string;
  /** 多歌手用 `/` 连接，空串 = 未知 */
  artist: string;
  /** 时长（秒），0 = 未知 */
  durationSec: number;
  /** 专辑封面（已转 https，空串 = 无，展示侧兜占位） */
  coverUrl: string;
}

/** 一次热歌榜拉取的结果：榜单名 / 榜单封面 / 全量单曲（榜位序） */
export interface NeteaseHotChart {
  name: string;
  coverUrl: string;
  songs: NeteaseHotSong[];
}

/** v6 批次大小：与 PlaylistImporter.fetchNeteasePlaylist 的 NETEASE_BATCH_SIZE 同口径 */
const HOT_CHART_BATCH_SIZE: number = 100;

/** v6 playlist/detail 响应模型（只取榜单需要的字段，逐字段可选取证） */
interface NeteaseHotChartV6Resp {
  code?: number;
  playlist?: {
    name?: string;
    coverImgUrl?: string;
    trackIds?: NeteaseHotChartTrackIdRef[];
  };
}

/** trackIds 元素（只认 id） */
interface NeteaseHotChartTrackIdRef {
  id?: number;
}

/** v3 song/detail 响应模型（al = 专辑，dt 单位 ms） */
interface NeteaseHotChartV3Resp {
  code?: number;
  songs?: NeteaseHotChartV3Song[];
}

interface NeteaseHotChartV3Song {
  name?: string;
  ar?: NeteaseHotChartArRef[];
  dt?: number;
  al?: NeteaseHotChartAlRef;
}

interface NeteaseHotChartArRef {
  name?: string;
}

interface NeteaseHotChartAlRef {
  picUrl?: string;
}

/**
 * 拉取网易云热歌榜全量单曲。
 * 两段式与 fetchNeteasePlaylist 同链：v6 拿 trackIds（顺序 = 榜位），
 * v3 按 100 一批查详情（name / ar / dt / al.picUrl）。name 缺失的脏条目
 * 丢弃自愈，其余字段缺省退化（空串 / 0），绝不整块抛错。
 */
export async function fetchNeteaseHotChart(): Promise<NeteaseHotChart> {
  const v6: NeteaseHotChartV6Resp = await HttpUtil.requestJson<NeteaseHotChartV6Resp>(
    `https://music.163.com/api/v6/playlist/detail?id=${NETEASE_HOT_CHART_ID}`,
    {
      skipCookie: true,
      skipReferer: true,
      headers: { 'Referer': 'https://music.163.com/' }
    }
  );
  const playlist = v6.playlist;
  if (v6.code !== 200 || playlist === undefined || !Array.isArray(playlist.trackIds)) {
    throw new Error('网易云热歌榜接口返回异常');
  }
  const ids: number[] = [];
  const rawIds: NeteaseHotChartTrackIdRef[] = playlist.trackIds;
  for (let i = 0; i < rawIds.length; i++) {
    const n: number | undefined = rawIds[i].id;
    if (typeof n === 'number' && n > 0) {
      ids.push(n);
    }
  }
  const songs: NeteaseHotSong[] = [];
  for (let start: number = 0; start < ids.length; start += HOT_CHART_BATCH_SIZE) {
    const end: number = Math.min(start + HOT_CHART_BATCH_SIZE, ids.length);
    const refs: NeteaseHotChartTrackIdRef[] = [];
    for (let i: number = start; i < end; i++) {
      refs.push({ id: ids[i] });
    }
    const v3: NeteaseHotChartV3Resp = await HttpUtil.requestJson<NeteaseHotChartV3Resp>(
      `https://music.163.com/api/v3/song/detail?c=${encodeURIComponent(JSON.stringify(refs))}`,
      {
        skipCookie: true,
        skipReferer: true,
        headers: { 'Referer': 'https://music.163.com/' }
      }
    );
    if (v3.code !== 200 || !Array.isArray(v3.songs)) {
      throw new Error('网易云热歌榜详情接口返回异常');
    }
    const list: NeteaseHotChartV3Song[] = v3.songs;
    for (let i = 0; i < list.length; i++) {
      const s: NeteaseHotChartV3Song = list[i];
      const title: string = typeof s.name === 'string' ? s.name : '';
      if (title.length === 0) {
        continue;
      }
      const names: string[] = [];
      const ars: NeteaseHotChartArRef[] = s.ar ?? [];
      for (let a: number = 0; a < ars.length; a++) {
        const name: string | undefined = ars[a].name;
        if (typeof name === 'string' && name.length > 0 && names.indexOf(name) < 0) {
          names.push(name);
        }
      }
      const al: NeteaseHotChartAlRef | undefined = s.al;
      const dt: number = typeof s.dt === 'number' ? s.dt : 0;
      const song: NeteaseHotSong = {
        title: title,
        artist: names.join('/'),
        durationSec: Math.round(dt / 1000),
        coverUrl: toHttpsUrl(al !== undefined && typeof al.picUrl === 'string' ? al.picUrl : '')
      };
      songs.push(song);
    }
  }
  return {
    name: typeof playlist.name === 'string' ? playlist.name : '',
    coverUrl: toHttpsUrl(typeof playlist.coverImgUrl === 'string' ? playlist.coverImgUrl : ''),
    songs: songs
  };
}
