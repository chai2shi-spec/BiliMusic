/**
 * 路由参数类。
 *
 * 跨页传参统一为 pushPathByName 显式路由参数（不用静态字段：静态字段无法在
 * 路由栈上追溯（getParamByName 拿不到），也容易残留上一个入口的旧值）：
 *   · 生产端 push 时 new 一个参数对象随路由入栈；
 *   · 消费端 getParamByName 取回后 instanceof 判型再读字段
 *    （SDK 返回值不透明，必须判型，不做结构推断）。
 *
 * 参数类刻意用显式 class + constructor 而不是对象字面量：
 * 满足 ArkTS「对象字面量必须有类型上下文 / 禁止结构类型」约束，
 * 也让 instanceof 判型成为可能（字面量没有可判型的构造身份）。
 */

import { DiaryTopUp } from './ListenDiaryStats';

/**
 * 「UP 主主页」（路由名 UpSpace）入参。
 *
 * 传 mid 而不传整份资料：昵称/粉丝/头像在页面里现拉（getUserCard），
 * 这样从别的入口进来也能拿到最新资料；upName 只作兜底 —— 资料请求
 * 失败时至少能显示个名字，而不是一片空白。
 */
export class UpSpaceRouteParam {
  upMid: string;
  upName: string;
  /**
   * UP 头像（首帧占位，可选）：入口方本来就带头像数据（搜 UP 主结果 /
   * 关注列表）时顺手传过来，UP 主页一进来就有图，不用等 getUserCard
   * 回来。UpSpacePage.loadCard() 拿到真实头像后会覆盖它。
   */
  upFace: string;

  constructor(upMid: string, upName: string, upFace: string) {
    this.upMid = upMid;
    this.upName = upName;
    this.upFace = upFace;
  }
}

/**
 * 「歌单详情」（路由名 PlaylistDetail）入参：目标歌单 id。
 * 歌单数据本体在 LibraryStore，这里只带定位符。
 */
export class PlaylistDetailRouteParam {
  playlistId: string;
  /**
   * 进入歌单详情后自动定位到该曲目（空 = 不定位）。
   * 歌单页签「定位」下钻入口传当前播放曲目 id；
   * 存量调用点不传走构造默认值，行为不变。
   */
  locateTrackId: string;

  constructor(playlistId: string, locateTrackId: string = '') {
    this.playlistId = playlistId;
    this.locateTrackId = locateTrackId;
  }
}

/**
 * 「合集·系列详情」（路由名 SeasonSeriesDetail）入参。
 *
 * kind：'season'（B 站合集 ugc_season）/ 'series'（UP 主手动系列），决定详情页
 * 走哪个条目分页接口；itemId 为 season_id / series_id。title/cover 是列表卡片
 * 已有数据的首帧兜底，upName/upMid 供 Track 构建（artist / upMid 字段）。
 */
export class SeasonSeriesDetailRouteParam {
  kind: string;
  mid: string;
  itemId: string;
  title: string;
  cover: string;
  upName: string;
  upMid: string;

  constructor(kind: string, mid: string, itemId: string, title: string, cover: string, upName: string, upMid: string) {
    this.kind = kind;
    this.mid = mid;
    this.itemId = itemId;
    this.title = title;
    this.cover = cover;
    this.upName = upName;
    this.upMid = upMid;
  }
}

/**
 * 「合集详情」（路由名 CollectionDetail）入参：多 P 合集（同一视频的
 * 多个分 P，B 站音乐「N 首精选」这类）详情页。
 *
 * bvid 为定位符（必填，空 = 页面进失败态）；title/cover/artist/upMid 是
 * 入口条目已有数据的首帧兜底 —— 真值（视频标题/封面/UP 资料/分 P 列表）
 * 由页面内 view 请求现拉并覆盖。
 */
export class CollectionDetailRouteParam {
  bvid: string;
  title: string;
  cover: string;
  artist: string;
  upMid: string;

  constructor(bvid: string, title: string, cover: string, artist: string, upMid: string) {
    this.bvid = bvid;
    this.title = title;
    this.cover = cover;
    this.artist = artist;
    this.upMid = upMid;
  }
}

/**
 * 「登录页」（路由名 Login）入参。登录页自身不读参数（登录态经
 * LoginStore 广播），此类只用于占住 pushPathByName 的 param 槽位，
 * 让带 onPop 回调的重载能通过类型检查；预留后续传「登录后跳转目标」。
 */
export class LoginRouteParam {
}

/**
 * 「听歌日记·新面孔清单」（路由名 DiaryNewFaces）入参。
 *
 * 听歌日记页已持有派生好的报告，这里直接带报告快照进清单页
 * （标题 + 新面孔列表），清单页纯展示、不重算统计 —— 重算需全量
 * 会话扫描（querySessions），为一张静态清单重复扫一遍不划算。
 * 列表元素是 DiaryTopUp 接口对象（数据快照），仅外层参数做 instanceof 判型。
 */
export class DiaryNewFacesRouteParam {
  /** 页面标题（本周新面孔 / 今日新面孔 …，随周期与往期前缀变化） */
  title: string;
  /** 副标题（N 位 UP 主 · 第一次出现在你的列表） */
  subtitle: string;
  /** 新面孔清单（时长降序；元素为 DiaryTopUp 快照） */
  faces: DiaryTopUp[];

  constructor(title: string, subtitle: string, faces: DiaryTopUp[]) {
    this.title = title;
    this.subtitle = subtitle;
    this.faces = faces;
  }
}

/**
 * 「搜索页」（路由名 Search）入参：进页自动执行该关键词搜索。
 *
 * 现有搜索入口全部 push('Search', undefined)（进页白板 + 自动聚焦输入框）；
 * 听歌日记「周期标签」等携带既有关键词的入口传本参数 —— SearchPage 在
 * onAppear 读取后把词写进输入框并直接走 doSearch（省一步手输/回车）。
 * keyword 为空串时按无参兜底（页面按普通进入处理）。
 */
export class SearchRouteParam {
  keyword: string;

  constructor(keyword: string) {
    this.keyword = keyword;
  }
}

/**
 * 「网易云歌单预览」（路由名 NeteasePlaylist）入参。
 *
 * playlistId 为网易云歌单定位符（必填，空 = 页面进失败态）；
 * name / coverUrl 是首页网格卡已有数据的首帧兜底 —— 真值（歌单全名 / 曲目列表）
 * 由页面内 fetchNeteasePlaylist 现拉并覆盖。
 */
export class NeteasePlaylistRouteParam {
  playlistId: string;
  name: string;
  coverUrl: string;

  constructor(playlistId: string, name: string, coverUrl: string) {
    this.playlistId = playlistId;
    this.name = name;
    this.coverUrl = coverUrl;
  }
}

/**
 * 需要登录才能进入的路由名清单（NavStackHolder.setupInterception 的
 * willShow 阶段逐跳检查：目标在清单内且未登录 → 改推登录页）。
 *
 * 当前为空：登录校验仍由各调用点显式做（promptLogin / checkLoginAndLoad），
 * 本清单只是拦截基础设施就位，后续若要把校验收口到路由层，往这里加
 * 路由名即可（如 'CloudSync' / 'Follows' / 'WatchHistory'）。
 */
export const LOGIN_GATED_ROUTES: string[] = [];

/**
 * 路由参数读取器：把「从栈上取参 → 判型」的固定套路收在一处。
 *
 * ⚠️ `getParamByName` 的返回值在 SDK 里声明为不透明（unknown 族），
 * ArkTS 禁止隐式推断（arkts-no-any-unknown）→ 这里显式收成 `ESObject`
 * 再 `Array.isArray` / `instanceof` 收窄（与 SettingsPage 消费 JSON.parse
 * 同一套口径）。消费页面一律走本读取器拿**已判型**的参数对象，
 * 不要自己碰 getParamByName 的原始返回值。
 */
export class NavRouteParamReader {
  /** 取 UpSpace 路由参数；栈上没有 / 类型不符返回 null（按无参兜底） */
  static readUpSpaceParam(stack: NavPathStack): UpSpaceRouteParam | null {
    const params: ESObject = stack.getParamByName('UpSpace');
    if (Array.isArray(params) && params.length > 0) {
      const first: ESObject = params[0];
      if (first instanceof UpSpaceRouteParam) {
        return first;
      }
    }
    return null;
  }

  /** 取 PlaylistDetail 路由参数；栈上没有 / 类型不符返回 null（按无参兜底） */
  static readPlaylistDetailParam(stack: NavPathStack): PlaylistDetailRouteParam | null {
    const params: ESObject = stack.getParamByName('PlaylistDetail');
    if (Array.isArray(params) && params.length > 0) {
      const first: ESObject = params[0];
      if (first instanceof PlaylistDetailRouteParam) {
        return first;
      }
    }
    return null;
  }

  /** 取 SeasonSeriesDetail 路由参数；栈上没有 / 类型不符返回 null（按无参兜底） */
  static readSeasonSeriesDetailParam(stack: NavPathStack): SeasonSeriesDetailRouteParam | null {
    const params: ESObject = stack.getParamByName('SeasonSeriesDetail');
    if (Array.isArray(params) && params.length > 0) {
      const first: ESObject = params[0];
      if (first instanceof SeasonSeriesDetailRouteParam) {
        return first;
      }
    }
    return null;
  }

  /** 取 CollectionDetail 路由参数；栈上没有 / 类型不符返回 null（按无参兜底） */
  static readCollectionDetailParam(stack: NavPathStack): CollectionDetailRouteParam | null {
    const params: ESObject = stack.getParamByName('CollectionDetail');
    if (Array.isArray(params) && params.length > 0) {
      const first: ESObject = params[0];
      if (first instanceof CollectionDetailRouteParam) {
        return first;
      }
    }
    return null;
  }

  /** 取 DiaryNewFaces 路由参数；栈上没有 / 类型不符返回 null（按无参兜底） */
  static readDiaryNewFacesParam(stack: NavPathStack): DiaryNewFacesRouteParam | null {
    const params: ESObject = stack.getParamByName('DiaryNewFaces');
    if (Array.isArray(params) && params.length > 0) {
      const first: ESObject = params[0];
      if (first instanceof DiaryNewFacesRouteParam) {
        return first;
      }
    }
    return null;
  }

  /** 取 Search 路由参数；栈上没有 / 类型不符 / 空关键词返回 null（按普通进入兜底） */
  static readSearchParam(stack: NavPathStack): SearchRouteParam | null {
    const params: ESObject = stack.getParamByName('Search');
    if (Array.isArray(params) && params.length > 0) {
      const first: ESObject = params[0];
      if (first instanceof SearchRouteParam && first.keyword.trim().length > 0) {
        return first;
      }
    }
    return null;
  }

  /** 取 NeteasePlaylist 路由参数；栈上没有 / 类型不符 / 空 id 返回 null（按失败态兜底） */
  static readNeteasePlaylistParam(stack: NavPathStack): NeteasePlaylistRouteParam | null {
    const params: ESObject = stack.getParamByName('NeteasePlaylist');
    if (Array.isArray(params) && params.length > 0) {
      const first: ESObject = params[0];
      if (first instanceof NeteasePlaylistRouteParam && first.playlistId.length > 0) {
        return first;
      }
    }
    return null;
  }
}
