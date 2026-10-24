/**
 * 设备指纹 buvid —— 首页能否出内容的开关。
 *
 * 实测结论（在本机对 B 站线上接口做了对照实验）：
 *   GET /x/web-interface/index/top/rcmd?ps=3
 *     不带 buvid Cookie      → HTTP 412 Precondition Failed（连 JSON 都不是，直接失败）
 *     带 buvid3/buvid4 Cookie → 200 code=0
 * 而 SearchPage 原实现把 popular 与 rcmd 串在同一个 try 里 await 后合并，
 * 一旦 rcmd 412 抛出，已经拿到的 popular 数据也一并丢弃 → 推荐位整块空白。
 *
 * 因此这里做三件事：
 *   1. initBuvidCookie()：同步保证 HttpUtil 带上 buvid（离线也能用本地生成的保底）；
 *   2. upgradeBuvidCookie()：后台向 /x/frontend/finger/spi 换取官方 buvid 并持久化；
 *   3. activateBuvid()：向风控指纹接口 ExClimbWuzhi 上报一次「设备已激活」
 *      （2026-10-24 移植 PiliPlus）。**新 buvid 在服务端是「未激活」状态**，
 *      取流容易被判异常 —— 换了 buvid 却不激活，等于换了个更可疑的指纹。
 */

import http from '@ohos.net.http';
import { HttpUtil } from '../utils/HttpUtil';
import { AppPreferences } from '../preferences/AppPreferences';
import { md5 } from '../utils/CryptoUtil';
import { buildWuzhiPayload } from '../utils/RiskShield';
import {
  BILI_API,
  PREF_BUVID,
  PREF_BUVID_ACTIVATED_FOR,
  PREF_BUVID_COOKIE,
  PREF_BUVID_OFFICIAL
} from '../common/Constants';

/**
 * buvid：首次生成后持久化，之后复用。
 *
 * 原先定义在 `api/BilibiliApi.ts` 的登录模块里，登录功能整体移除后迁到本模块 ——
 * buvid 与登录无关，是**首页能否出内容**的前置条件，不能跟着登录代码一起删掉。
 */
let cachedBuvid: string = '';

export function getBuvid(): string {
  if (cachedBuvid.length > 0) {
    return cachedBuvid;
  }
  const saved: string = AppPreferences.getString(PREF_BUVID, '');
  if (saved.length > 0) {
    cachedBuvid = saved;
    return cachedBuvid;
  }
  const digest: string = md5(`${Date.now()}${Math.random()}${Math.random()}`);
  cachedBuvid = `XY${digest.charAt(2)}${digest.charAt(12)}${digest.charAt(22)}${digest}`;
  AppPreferences.setString(PREF_BUVID, cachedBuvid);
  return cachedBuvid;
}

interface SpiData {
  b_3: string;
  b_4: string;
}

interface SpiResponse {
  code: number;
  data: SpiData;
}

/**
 * 把访客身份 Cookie 补齐成「最小完整集」。
 *
 * 2026-10-03 实测（同一 IP、同一时刻的对照实验，只改变量是 Cookie）：
 *   · 无 Cookie                                                  → HTTP 412
 *   · `buvid3` + `buvid4`（**本工程原来的样子**）                  → HTTP 412
 *   · 再加 `b_nut` + `_uuid` + `b_lsid`                          → **HTTP 200**
 * 也就是说 412 并不是「buvid 无效」，而是**访客身份不完整**被直接挡在门外。
 * 补齐后同一接口能拿到 body（`code` 可能是 -352 那一档风控，属于下一道门，另说）。
 *
 * 三个字段的构造（都是 B 站网页端匿名访问会带的东西）：
 *   · `b_nut`  = 秒级时间戳
 *   · `_uuid`  = 由 buvid3 派生的 20 位大写 hex + `infoc`（与真机格式同形）
 *   · `b_lsid` = 4 位前缀 + `_` + 毫秒尾数（会话标识，每次启动会变）
 *
 * ⚠️ 只补 cookie、不重新请求 `finger/spi`：412 的成因是「字段缺」，不是「值旧」，
 * 所以老用户持久化里的 `buvid3/buvid4` 直接复用即可（重新拉 spi 反而会换掉已稳定的 buvid）。
 */
function completeVisitorCookie(cookie: string): string {
  if (cookie.indexOf('b_nut=') >= 0) {
    return cookie;
  }
  const parts: string[] = [];
  const items: string[] = cookie.split(';');
  for (let i = 0; i < items.length; i++) {
    const item: string = items[i].trim();
    if (item.length > 0) {
      parts.push(item);
    }
  }
  let buvid3: string = '';
  for (let i = 0; i < parts.length; i++) {
    if (parts[i].indexOf('buvid3=') === 0) {
      buvid3 = parts[i].slice('buvid3='.length);
      break;
    }
  }
  if (buvid3.length === 0) {
    return cookie;
  }
  const digest: string = md5(`${buvid3}bilimusic`).toUpperCase();
  const now: number = Date.now();
  parts.push(`b_nut=${Math.round(now / 1000)}`);
  parts.push(`_uuid=${digest.slice(0, 20)}infoc`);
  parts.push(`b_lsid=${digest.slice(0, 4)}_${now % 1000000}`);
  return parts.join('; ');
}

/**
 * 同步装填 buvid Cookie，保证首屏请求不被 412。
 * 已有持久化值则直接复用；否则用本地生成的 UUID 顶上（实测同样可通过校验）。
 */
export function initBuvidCookie(): void {
  const saved: string = AppPreferences.getString(PREF_BUVID_COOKIE, '');
  if (saved.length > 0) {
    const full: string = completeVisitorCookie(saved);
    if (full !== saved) {
      AppPreferences.setString(PREF_BUVID_COOKIE, full);
    }
    HttpUtil.setBaseCookie(full);
    // 诊断（2026-10-22 平板登录修复）：启动即留痕 buvid 来源（official / fallback）
    // 与 Cookie 串长度指纹 —— 风控类问题（二维码早失效 / playurl 偶发拦截）的
    // 定位起点。旧安装首次运行时标记位缺省会显示 fallback，下一次
    // upgradeBuvidCookie 成功后即纠正。
    console.info(`[BiliDevice] init buvid source=` +
      `${isBuvidFallback() ? 'fallback' : 'official'} cookieLen=${full.length}`);
    return;
  }
  const fallback: string = getBuvid();
  const cookie: string = completeVisitorCookie(`buvid3=${fallback}infoc; buvid4=${fallback}`);
  HttpUtil.setBaseCookie(cookie);
  AppPreferences.setString(PREF_BUVID_COOKIE, cookie);
  console.info(`[BiliDevice] init buvid source=fallback(fresh) cookieLen=${cookie.length}`);
}

/**
 * buvid 是否仍为本地兜底假值（2026-10-22 平板登录修复）。
 *
 * 背景：新装机（典型：平板）持久化里没有官方 buvid，initBuvidCookie 用本地
 * MD5 兜底值顶上（能过 412，但非 finger/spi 官方下发）。带着假指纹请求
 * passport 登录接口 / playurl 是「二维码约 3s 被提前作废、偶发播放拦截」的
 * 共同根因候选。官方值与兜底值形态不可区分（都是 XY 开头、infoc 结尾），
 * 故用持久化标记位判定：upgradeBuvidCookie 成功时置 true。
 */
export function isBuvidFallback(): boolean {
  return !AppPreferences.getBoolean(PREF_BUVID_OFFICIAL, false);
}

/**
 * 用官方 finger/spi 接口换取正规 buvid 并持久化。
 * 失败时保留本地兜底值，不影响首屏。
 * 成功时置 PREF_BUVID_OFFICIAL 标记：isBuvidFallback() 即转 false，
 * AppContainer 的延迟重试升级随之停摆（成功一次即止）。
 */
export async function upgradeBuvidCookie(): Promise<void> {
  try {
    const resp: SpiResponse = await HttpUtil.requestJson<SpiResponse>(`${BILI_API}/x/frontend/finger/spi`);
    if (resp.code !== 0 || !resp.data || resp.data.b_3.length === 0) {
      console.warn(`upgrade buvid: spi rejected code=${resp.code}, keep fallback`);
      return;
    }
    const cookie: string = completeVisitorCookie(`buvid3=${resp.data.b_3}; buvid4=${resp.data.b_4}`);
    HttpUtil.setBaseCookie(cookie);
    AppPreferences.setString(PREF_BUVID_COOKIE, cookie);
    await AppPreferences.setBoolean(PREF_BUVID_OFFICIAL, true);
    // 诊断指纹：仅 buvid3 长度与来源标记，不输出指纹值（与 cookieFingerprint 脱敏口径一致）
    console.info(`buvid upgraded from finger/spi (buvid3Len=${resp.data.b_3.length})`);
    // 换了新 buvid = 服务端眼里换了台新设备 → 必须重新上报一次激活。
    // 不 await：激活失败不影响取流（只是少一层保险），不能拖慢调用方。
    activateBuvid(true);
  } catch (e) {
    // 离线或风控下 spi 不可用，保留本地兜底值
    console.warn(`upgrade buvid failed, keep fallback: ${JSON.stringify(e)}`);
  }
}

/** ExClimbWuzhi 响应：正常恒为 `{code:0, message:'0', ttl:1, data:{}}` */
interface WuzhiResponse {
  code: number;
  message: string;
}

/** 从 `k=v; k=v` 形态的 Cookie 串里取单值（找不到返回空串） */
function cookieValueOf(cookie: string, key: string): string {
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

/**
 * 当前 buvid 的特征串（buvid3 的 md5 前 8 位）。
 * 只用于「对哪个 buvid 报过激活」的判等，**不是**凭据本身。
 */
function buvidFingerprint(): string {
  const b3: string = cookieValueOf(HttpUtil.getBaseCookie(), 'buvid3');
  if (b3.length === 0) {
    return '';
  }
  return md5(b3).substring(0, 8);
}

/**
 * 向风控指纹接口上报「本设备已激活」（2026-10-24 移植 PiliPlus `Request.buvidActive`）。
 *
 * 为什么必须做：`finger/spi` 只**下发** buvid，不激活它。服务端把新 buvid 当作
 * 「一台还没跑过 JS 指纹采集的设备」，这类指纹在 playurl / 登录接口上更容易被
 * 判为异常客户端。ExClimbWuzhi 是官方页面加载时自己调的接口，正常访问一次即
 * 把该 buvid 标记为已激活。
 *
 * 去重策略：`PREF_BUVID_ACTIVATED_FOR` 里存「已上报的 buvid 特征串」。
 *   · 特征串一致 → 直接返回（同一 buvid 每天重报反而是异常节奏）；
 *   · buvid 被升级 / 自愈换掉 → 特征串变化 → 自动重新上报。
 * `force=true` 用于「刚登录 / 刚换号」这类换身份场景（PiliPlus 在 Accounts.set 时也重报）。
 *
 * **绝不抛错**：激活是锦上添花，失败只留一条日志。断网启动 / 接口临时不可用
 * 都不该影响首屏和播放。
 */
export async function activateBuvid(force: boolean = false): Promise<void> {
  const fingerprint: string = buvidFingerprint();
  if (fingerprint.length === 0) {
    console.warn('[BiliDevice] activate skipped: no buvid3 in cookie');
    return;
  }
  if (!force && AppPreferences.getString(PREF_BUVID_ACTIVATED_FOR, '') === fingerprint) {
    return;
  }
  // payload 是**字符串里再套一层 JSON**：ExClimbWuzhi 的入参形如
  // {"payload":"{\"3064\":1,...}"}。这里手写转义（只处理 `"` 与 `\`，payload
  // 本身只含 ASCII 可见字符）—— 不用 JSON.stringify：ArkTS 的该签名只收
  // Object，传 string 会编译不过，而包一层 interface 又比五行循环更难读。
  const payload: string = buildWuzhiPayload();
  let escaped: string = '';
  for (let i = 0; i < payload.length; i++) {
    const ch: string = payload.charAt(i);
    if (ch === '"' || ch === '\\') {
      escaped += '\\';
    }
    escaped += ch;
  }
  const body: string = `{"payload":"${escaped}"}`;
  // 诊断（不含凭据）：-400「请求错误」通常意味着 body 没按服务端预期到达，
  // 打长度 + 前缀即可区分「body 被引擎丢掉」与「payload 内容不合法」。
  console.info(`[BiliDevice] activate bodyLen=${body.length} head=${body.substring(0, 48)}`);
  try {
    const resp: WuzhiResponse = await HttpUtil.requestJson<WuzhiResponse>(
      `${BILI_API}/x/internal/gaia-gateway/ExClimbWuzhi`,
      {
        method: http.RequestMethod.POST,
        headers: { 'Content-Type': 'application/json' },
        body: body
      });
    if (resp.code !== 0) {
      console.warn(`[BiliDevice] buvid activate rejected code=${resp.code}, retry next launch`);
      return;
    }
    AppPreferences.setString(PREF_BUVID_ACTIVATED_FOR, fingerprint);
    console.info(`[BiliDevice] buvid activated fp=${fingerprint} official=${!isBuvidFallback()}`);
  } catch (e) {
    // 断网 / 接口不可用：不写标记位，下次启动或下次 buvid 变更时会再试
    console.warn(`[BiliDevice] buvid activate failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
  }
}
