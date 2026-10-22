/**
 * 路由参数类（2026-10-22 Navigation 差距收敛）。
 *
 * 背景：此前跨页传参走 NavStackHolder 的静态字段（upMid/upName/upFace/
 * selectedPlaylistId），写入与读取分离在不同页面，既无法在路由栈上追溯
 * （getParamByName 拿不到），也容易残留上一个入口的旧值（静态字段不清零
 * 就带着上一位用户的数据进页）。现统一为 pushPathByName 显式路由参数：
 *   · 生产端 push 时 new 一个参数对象随路由入栈；
 *   · 消费端 getParamByName 取回后 instanceof 判型再读字段
 *    （SDK 返回值不透明，必须判型，不做结构推断）。
 *
 * 参数类刻意用显式 class + constructor 而不是对象字面量：
 * 满足 ArkTS「对象字面量必须有类型上下文 / 禁止结构类型」约束，
 * 也让 instanceof 判型成为可能（字面量没有可判型的构造身份）。
 */

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

  constructor(playlistId: string) {
    this.playlistId = playlistId;
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
}
