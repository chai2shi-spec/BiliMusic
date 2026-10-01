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
 * 因此这里做两件事：
 *   1. initBuvidCookie()：同步保证 HttpUtil 带上 buvid（离线也能用本地生成的保底）；
 *   2. upgradeBuvidCookie()：后台向 /x/frontend/finger/spi 换取官方 buvid 并持久化。
 */

import { HttpUtil } from '../utils/HttpUtil';
import { AppPreferences } from '../preferences/AppPreferences';
import { md5 } from '../utils/CryptoUtil';
import { BILI_API, PREF_BUVID, PREF_BUVID_COOKIE } from '../common/Constants';

/**
 * buvid：首次生成后持久化，之后复用（等价 PiliPlus 的 generateBuvid / Pref.buvid）。
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
 * 同步装填 buvid Cookie，保证首屏请求不被 412。
 * 已有持久化值则直接复用；否则用本地生成的 UUID 顶上（实测同样可通过校验）。
 */
export function initBuvidCookie(): void {
  const saved: string = AppPreferences.getString(PREF_BUVID_COOKIE, '');
  if (saved.length > 0) {
    HttpUtil.setBaseCookie(saved);
    return;
  }
  const fallback: string = getBuvid();
  const cookie: string = `buvid3=${fallback}infoc; buvid4=${fallback}`;
  HttpUtil.setBaseCookie(cookie);
  AppPreferences.setString(PREF_BUVID_COOKIE, cookie);
}

/**
 * 用官方 finger/spi 接口换取正规 buvid 并持久化。
 * 失败时保留本地兜底值，不影响首屏。
 */
export async function upgradeBuvidCookie(): Promise<void> {
  try {
    const resp: SpiResponse = await HttpUtil.requestJson<SpiResponse>(`${BILI_API}/x/frontend/finger/spi`);
    if (resp.code !== 0 || !resp.data || resp.data.b_3.length === 0) {
      return;
    }
    const cookie: string = `buvid3=${resp.data.b_3}; buvid4=${resp.data.b_4}`;
    HttpUtil.setBaseCookie(cookie);
    AppPreferences.setString(PREF_BUVID_COOKIE, cookie);
    console.info('buvid upgraded from finger/spi');
  } catch (e) {
    // 离线或风控下 spi 不可用，保留本地兜底值
    console.warn(`upgrade buvid failed, keep fallback: ${JSON.stringify(e)}`);
  }
}
