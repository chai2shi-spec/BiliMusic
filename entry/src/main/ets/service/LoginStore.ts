/**
 * 登录态管理（扫码登录，2026-10 恢复重建）。
 *
 * 职责（与 BiliDevice 管理匿名身份的分工）：
 *   1. initLoginState()：启动时把持久化的登录 Cookie 装填进 HttpUtil（登录通道）；
 *   2. applyQrSuccess() / applySmsLoginCookies()：扫码 / 短信登录成功后提取登录
 *      Cookie（扫码为双通道：回调 url 参数 / 响应 Set-Cookie 头；短信仅响应头）并持久化；
 *   3. refreshLoginUser()：拉 nav 接口刷新昵称 / 头像 / VIP 状态，
 *      返回 -101（Cookie 失效）时自动降级为未登录；
 *   4. logout()：先 best-effort 撤销服务器会话，再清本地登录态。
 *
 * 跨组件通知：登录 / 退出 / 用户信息变化时递增 STORE_LOGIN_REV（版本号），
 * 设置页（Tabs 常驻，aboutToAppear 只触发一次）用 @StorageProp + @Watch 订阅刷新
 * —— 与 LibraryStore 的 STORE_LIBRARY_REV 同一套模式。
 */

import { AppPreferences } from '../preferences/AppPreferences';
import { HttpUtil } from '../utils/HttpUtil';
import {
  PREF_LOGIN_COOKIE,
  PREF_LOGIN_USER,
  PREF_LOGIN_REFRESH_TOKEN,
  PREF_LOGIN_VERIFIED_AT,
  STORE_LOGIN_REV
} from '../common/Constants';
import { fetchNavUser, revokeLogin } from '../api/BilibiliApi';
import { activateBuvid } from './BiliDevice';

/** 登录用户信息（持久化为 JSON，字段来自 nav 接口归一化） */
export interface LoginUser {
  mid: number;
  uname: string;
  face: string;
  /** 0 普通账号 / 1 大会员 */
  vipStatus: number;
  /**
   * 会籍种类：0 未开通 / 1 月度大会员 / 2 年度大会员（nav 的 vipType）。
   * ⚠️ 老版本落盘的 JSON 没有这个字段 → 读出来是 undefined，
   * 判等比较统一走 `vipType >= 2`（undefined >= 2 为 false）自然回落「大会员」，
   * 且每次启动的 refreshLoginUser 会把真实值补上，无需迁移代码。
   */
  vipType: number;
}

let cachedUser: LoginUser | null = null;
let initialized: boolean = false;

/**
 * 从扫码成功的回调 url 里解析登录 Cookie（**通道 a：老格式**）。
 * 回调形如 `...?DedeUserID=..&DedeUserID__ckMd5=..&Expires=..&SESSDATA=..&bili_jct=..`，
 * 只取四个身份字段，值做 URL 解码后按 `k=v; k=v` 拼接（与 HttpUtil Cookie 头同形）。
 */
function parseLoginCookieFromUrl(callbackUrl: string): string {
  const queryIndex: number = callbackUrl.indexOf('?');
  if (queryIndex < 0) {
    return '';
  }
  const pairs: string[] = callbackUrl.substring(queryIndex + 1).split('&');
  const parts: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < pairs.length; i++) {
    const eq: number = pairs[i].indexOf('=');
    if (eq <= 0) {
      continue;
    }
    const key: string = pairs[i].substring(0, eq);
    if (!isWantedCookieKey(key) || seen.has(key)) {
      continue;
    }
    seen.add(key);
    parts.push(`${key}=${safeDecodeCookieValue(pairs[i].substring(eq + 1))}`);
  }
  return parts.join('; ');
}

/**
 * 从 poll 响应的 Set-Cookie 串（`k=v; k=v`，HttpUtil.requestTextWithCookies 提供）
 * 解析登录 Cookie（**通道 b**：现行格式，凭据在 crossDomain 跳转的响应头里）。
 * 同名键以先出现者为准（crossDomain 的值优先，见 pollQrLogin 的合并顺序）。
 */
function parseLoginCookieFromResponseCookies(responseCookies: string): string {
  if (responseCookies.length === 0) {
    return '';
  }
  const items: string[] = responseCookies.split(';');
  const parts: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < items.length; i++) {
    const item: string = items[i].trim();
    const eq: number = item.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    const key: string = item.substring(0, eq);
    if (!isWantedCookieKey(key) || seen.has(key)) {
      continue;
    }
    seen.add(key);
    parts.push(`${key}=${safeDecodeCookieValue(item.substring(eq + 1))}`);
  }
  return parts.join('; ');
}

/** 登录身份字段白名单：只认这四个，其余（Expires 等）一律不要 */
function isWantedCookieKey(key: string): boolean {
  return key === 'SESSDATA' || key === 'bili_jct' ||
    key === 'DedeUserID' || key === 'DedeUserID__ckMd5';
}

/**
 * 单值安全 URL 解码：坏编码（decodeURIComponent 会抛 URIError 的 '%' 序列）原样保留，
 * 不让一个字段的编码问题炸掉整次登录；Set-Cookie 下发的原始值解码是幂等的。
 */
function safeDecodeCookieValue(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch (e) {
    return value;
  }
}

/** 从 `k=v; k=v` 形态的 Cookie 串里取单个字段值（找不到返回空串） */
function extractCookieValue(cookie: string, key: string): string {
  const items: string[] = cookie.split(';');
  const prefix: string = `${key}=`;
  for (let i = 0; i < items.length; i++) {
    const item: string = items[i].trim();
    if (item.indexOf(prefix) === 0) {
      return item.substring(prefix.length);
    }
  }
  return '';
}

/** 递增登录态版本号：设置页 @Watch 订阅，驱动「账户」分组刷新 */
function bumpLoginRev(): void {
  const cur: number = AppStorage.get<number>(STORE_LOGIN_REV) ?? 0;
  AppStorage.setOrCreate(STORE_LOGIN_REV, cur + 1);
}

/** 启动装载：登录 Cookie 与用户信息从 preferences 恢复（须在 initPreferences 之后调用） */
export function initLoginState(): void {
  if (initialized) {
    return;
  }
  initialized = true;
  const cookie: string = AppPreferences.getLoginCookie();
  if (cookie.length > 0) {
    HttpUtil.setLoginCookie(cookie);
    // ⚠️ 兼容升级路径（2026-10-08）：`verifiedAt` 是新加的键，老版本用户磁盘上没有它
    // → getLoginVerifiedAt() 返回 0 → isLoginStale() 会把**所有老用户**都显示成
    // 「登录已失效 · 点击重新登录」。这里给存量 Cookie 补一个初始标记：
    // 它的有效性由随后那次 refreshLoginUser() 的 nav 校验来确认，
    // 确认失败会自动归零stale（见 refreshLoginUser）。
    if (AppPreferences.getLoginVerifiedAt() === 0) {
      AppPreferences.setLoginVerifiedAt(Date.now());
    }
  }
  cachedUser = AppPreferences.getLoginUser<LoginUser>();
}

/** 是否已登录（以本地是否存有登录 Cookie 为准，失效由 refreshLoginUser 的 nav 校验兜底） */
export function isLoggedIn(): boolean {
  return AppPreferences.getLoginCookie().length > 0;
}

/** 当前用户信息缓存（未登录返回 null） */
export function getLoginUser(): LoginUser | null {
  return cachedUser;
}

/**
 * 取当前登录 Cookie 里的 `bili_jct`（CSRF token，B 站写接口的必填项，如收藏/取消收藏）。
 *
 * 未登录或字段缺失返回空串 —— 调用方（FavSyncManager 推送阶段）据此判 `blocked`，
 * 提示用户重新登录，**不要拿空串去发写请求**（会被 -111 拒，且白烧一次重试）。
 */
export function getLoginCsrf(): string {
  return extractCookieValue(AppPreferences.getLoginCookie(), 'bili_jct');
}

/**
 * 落库公共核心：持久化 Cookie / refresh_token → 装填 HttpUtil → 广播版本号。
 * 扫码（applyQrSuccess）与短信（applySmsLoginCookies）两条登录链路共用。
 */
async function persistLoginCookie(cookie: string, refreshToken: string): Promise<void> {
  await AppPreferences.setLoginCookie(cookie);
  await AppPreferences.setLoginRefreshToken(refreshToken);
  // 刚落库的 Cookie 必然是有效的（刚从服务端拿到），立刻标已验证。
  // 不写这一步的话isLoginStale() 会因为 verifiedAt 还是 0 而把刚登录的用户
  // 显示成「登录已失效 · 点击重新登录」。
  await AppPreferences.setLoginVerifiedAt(Date.now());
  HttpUtil.setLoginCookie(cookie);
  bumpLoginRev();
  // 2026-10-24（移植 PiliPlus Accounts.set 的行为）：登录 = 换了一个身份，
  // 服务端对「同一 buvid 突然变成登录态」的评分会重新计算，强制重报一次
  // 设备激活让新身份从「已激活设备」起算。fire-and-forget（内部全兜住异常），
  // 绝不阻塞登录成功跳转。
  activateBuvid(true);
}

/**
 * 扫码成功：解析登录 Cookie → 持久化 → 装填 HttpUtil → 广播版本号。
 *
 * Cookie 双通道提取（B 站两种下发形态都接）：
 *   a) 回调 url 的 query 参数（老格式）；
 *   b) poll 响应的 Set-Cookie 头（现行格式，此前只走 a 导致「扫码确认后仍登录失败」）。
 * a 优先、b 兜底，成功时日志记录实际命中的来源。
 *
 * @throws 两条通道都拿不到 SESSDATA 时抛带诊断元数据（长度/字段命中，不含凭据值）的错，
 *         由登录页提示用户重试
 */
export async function applyQrSuccess(
  callbackUrl: string,
  responseCookies: string,
  refreshToken: string
): Promise<void> {
  let cookie: string = parseLoginCookieFromUrl(callbackUrl);
  let source: string = 'url params';
  if (cookie.indexOf('SESSDATA=') < 0) {
    cookie = parseLoginCookieFromResponseCookies(responseCookies);
    source = 'response cookies';
  }
  if (cookie.indexOf('SESSDATA=') < 0) {
    // 诊断信息只记长度、字段命中与 cookie 键名（键名不含凭据值，可安全输出）
    throw new Error(
      `登录回调里缺少 Cookie 参数 ` +
      `(urlLen=${callbackUrl.length}, urlHasSessdata=${callbackUrl.indexOf('SESSDATA=') >= 0}, ` +
      `cookiesLen=${responseCookies.length}, cookiesHasSessdata=${responseCookies.indexOf('SESSDATA=') >= 0}, ` +
      `cookieKeys=[${HttpUtil.cookieKeys(responseCookies).join(', ')}])`
    );
  }
  console.info(`login cookie applied from ${source}`);
  await persistLoginCookie(cookie, refreshToken);
}

/**
 * 短信验证码登录成功：从登录响应的 Set-Cookie 串解析登录 Cookie 并落库。
 * 短信链路只有响应头这一条 Cookie 通道（无回调 url），解析复用白名单逻辑。
 *
 * @throws 响应里拿不到 SESSDATA 时抛带诊断元数据（不含凭据值）的错，由短信登录页提示重试
 */
export async function applySmsLoginCookies(responseCookies: string, refreshToken: string): Promise<void> {
  const cookie: string = parseLoginCookieFromResponseCookies(responseCookies);
  if (cookie.indexOf('SESSDATA=') < 0) {
    throw new Error(
      `短信登录响应里缺少登录 Cookie ` +
      `(cookiesLen=${responseCookies.length}, ` +
      `cookiesHasSessdata=${responseCookies.indexOf('SESSDATA=') >= 0}, ` +
      `cookieKeys=[${HttpUtil.cookieKeys(responseCookies).join(', ')}])`
    );
  }
  console.info('login cookie applied from sms response cookies');
  await persistLoginCookie(cookie, refreshToken);
}

/**
 * 拉取 nav 接口刷新用户信息（昵称/ 头像 / VIP 状态）。
 *
 * ⚠️ **被拒绝时不再清凭据**（2026-10-08 改）。原实现在 nav 返回 -101 时直接
 * `clearLoginState()`，后果是：Cookie / refresh_token / 用户信息全被清掉，用户
 * 完全不知情（界面上只是「莫名其妙变回未登录」），且**必须重新扫码**。
 * 但 -101 有多种成因（B 站风控临时拒绝、Cookie 确实过期、网络抖动被误判），
 * 一律按「已过期」处理过于武断。
 *
 * 现在改成：保留 Cookie，只把 `verifiedAt` 归零并广播 ——设置页会显示
 * 「登录已失效 · 点击重新登录」，用户点一下重新登录即可，凭据也还在。
 *
 * 三态：
 *   - `isLogin === false` → 标stale（保留凭据，等用户重新登录）；
 *   - 网络异常 → **什么都不动**（`verifiedAt` 不清零），保留缓存下次再试。
 */
export async function refreshLoginUser(): Promise<void> {
  if (!isLoggedIn()) {
    return;
  }
  try {
    const nav = await fetchNavUser();
    if (!nav.isLogin) {
      if (isLoginStale()) {
        // 已经是待重验态，无需重复广播
        return;
      }
      console.warn('login cookie rejected by nav (-101), kept for re-verify');
      await AppPreferences.setLoginVerifiedAt(0);
      bumpLoginRev();
      return;
    }
    const next: LoginUser = {
      mid: nav.mid,
      uname: nav.uname,
      face: nav.face,
      vipStatus: nav.vipStatus,
      vipType: nav.vipType
    };
    const cur: LoginUser | null = cachedUser;
    const changed: boolean = cur === null ||
      cur.mid !== next.mid || cur.uname !== next.uname ||
      cur.face !== next.face || cur.vipStatus !== next.vipStatus ||
      cur.vipType !== next.vipType;
    cachedUser = next;
    await AppPreferences.setLoginUser<LoginUser>(next);
    // 确认有效（登录成功校验通过 / 后续 nav 校验通过）→ 记录时间戳，stale 态自动解除
    await AppPreferences.setLoginVerifiedAt(Date.now());
    if (changed) {
      bumpLoginRev();
    }
  } catch (e) {
    // 网络瞬态失败：不动登录态，静默保留缓存
    console.warn(`refresh login user failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
  }
}

/**
 * 「有本地 Cookie 但已被服务端拒绝过一次」= 待重新验证。
 *
 * 判据：`verifiedAt === 0`。注意这**不是**「未登录」—— 未登录是 `isLoggedIn()`
 * 为false（根本没有 Cookie），两者必须分开：
 *   · `isLoggedIn() === false` → 完全没登录，界面显示「登录 B 站账号」；
 *   · `isLoggedIn() && isLoginStale()` → 登录过但失效了，界面显示失效提示 + 点此重登。
 */
export function isLoginStale(): boolean {
  return AppPreferences.getLoginCookie().length > 0 &&
    AppPreferences.getLoginVerifiedAt() === 0;
}

/**
 * 退出登录：先 best-effort 撤销服务器会话（失败忽略，不阻塞本地清理），再清本地态。
 * ⚠️ 内含网络请求（15s 超时上限），UI 侧调用请 fire-and-forget、不要 await 卡住交互。
 */
export async function logout(): Promise<void> {
  const cookie: string = AppPreferences.getLoginCookie();
  const biliJct: string = extractCookieValue(cookie, 'bili_jct');
  if (biliJct.length > 0) {
    try {
      await revokeLogin(biliJct);
    } catch (e) {
      // 服务器撤销失败（断网 / 会话已失效）也继续清本地
      console.warn(`revoke login failed, continue local cleanup: ${
        e instanceof Error ? e.message : JSON.stringify(e)}`);
    }
  }
  await clearLoginState();
}

/**
 * 清空本地登录态（Cookie / 用户信息 / refresh_token / verifiedAt + HttpUtil 通道 + 广播）。
 *
 * ⚠️ 只在**用户主动登出**与 `logout()` 里调用。
 * 「Cookie 被服务端拒绝」**不再**走这里（见 `refreshLoginUser`）——
 * 那属于「凭据待重验」，不是「用户要退出」。
 */
export async function clearLoginState(): Promise<void> {
  // 2026-10-23 性能审查：四个 key 攒一次 removeMany（单次 flush），
  // 旧写法逐 key remove，登出要全量落盘 4 次。
  await AppPreferences.removeMany([PREF_LOGIN_COOKIE, PREF_LOGIN_USER, PREF_LOGIN_REFRESH_TOKEN, PREF_LOGIN_VERIFIED_AT]);
  cachedUser = null;
  HttpUtil.clearLoginCookie();
  bumpLoginRev();
}
