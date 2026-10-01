/**
 * 网络请求封装（@ohos.net.http）。
 * 统一附加 Referer / User-Agent / buvid Cookie，供 B 站与歌词 API 复用。
 *
 * 本 App 是**纯匿名**访问：曾有的登录 Cookie 通道（setCookie / skipCookie / requestRaw）
 * 随登录功能一并移除，现在只有与登录无关的 buvid 公共 Cookie。
 */

import http from '@ohos.net.http';
import hilog from '@ohos.hilog';
import { BILI_REFERER } from '../common/Constants';

export interface HttpRequestOptions {
  params?: Record<string, string | number>;
  headers?: Record<string, string>;
  method?: http.RequestMethod;
  /** POST 表单体（application/x-www-form-urlencoded）。 */
  body?: string;
}

export class HttpUtil {
  /**
   * 公共 Cookie（buvid3/buvid4）。缺了它首页推荐接口会返回 HTTP 412。
   * 这是本 App **唯一**会随请求发出的 Cookie。
   */
  private static baseCookie: string = '';
  /**
   * 必须是桌面版浏览器 UA，不能用 HarmonyOS / 移动端 UA。
   *
   * 实测矩阵（都带 buvid Cookie + 正确的 WBI 签名，请求 /x/web-interface/wbi/search/type）：
   *   PC Chrome UA + buvid      → 30 条
   *   iPhone UA    + buvid      → 30 条
   *   HarmonyOS UA + **不带** buvid → 30 条
   *   HarmonyOS UA + buvid（不论 buvid 用哪个 UA 换的）→ **0 条，且 HTTP 200 / code 0**
   * 也就是说「移动端 UA + buvid Cookie」这个组合会被搜索接口静默风控：
   * 不报错、不返回 412，只是 result 为空数组 —— 表现就是"搜索不出来任何东西"。
   * 而 buvid 又不能不带（首页 rcmd 缺它会 412），所以只能改 UA 这一侧。
   */
  private static userAgent: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /** 设置公共 Cookie（buvid），由 service/BiliDevice.ts 在启动时装填。 */
  static setBaseCookie(c: string): void {
    HttpUtil.baseCookie = c;
  }

  static getBaseCookie(): string {
    return HttpUtil.baseCookie;
  }

  private static buildHeader(extra?: Record<string, string>): Record<string, string> {
    const header: Record<string, string> = {
      Referer: BILI_REFERER,
      'User-Agent': HttpUtil.userAgent,
      Accept: '*/*'
    };
    // buvid 必须带上：缺它首页推荐（rcmd）会直接被 HTTP 412 拦下
    if (HttpUtil.baseCookie.length > 0) {
      header['Cookie'] = HttpUtil.baseCookie;
    }
    if (extra) {
      const keys: string[] = Object.keys(extra);
      for (let i = 0; i < keys.length; i++) {
        header[keys[i]] = extra[keys[i]];
      }
    }
    return header;
  }

  static async requestText(url: string, options?: HttpRequestOptions): Promise<string> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: options?.method ?? http.RequestMethod.GET,
        header: HttpUtil.buildHeader(options?.headers),
        queryParams: options?.params,
        extraData: options?.body ?? undefined,
        connectTimeout: 15000,
        readTimeout: 15000
      });
      if (resp.responseCode >= 400) {
        throw new Error(`HTTP ${resp.responseCode} for ${url}`);
      }
      const resultText: string = resp.result as string;
      hilog.info(0x0000, 'BiliMusicHttp', 'resp %{public}s code=%{public}d body=%{public}s',
        url, resp.responseCode, resultText.substring(0, Math.min(200, resultText.length)));
      return resultText;
    } finally {
      req.destroy();
    }
  }

  static async requestJson<T>(url: string, options?: HttpRequestOptions): Promise<T> {
    const text: string = await HttpUtil.requestText(url, options);
    return JSON.parse(text) as T;
  }
}
