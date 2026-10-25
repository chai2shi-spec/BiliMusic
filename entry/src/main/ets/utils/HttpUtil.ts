/**
 * 网络请求封装（@ohos.net.http）。
 * 统一附加 Referer / User-Agent / Cookie，供 B 站与歌词 API 复用。
 *
 * Cookie 有两条独立通道、合并发送：
 *   · baseCookie（buvid3/buvid4/b_nut/_uuid）—— 匿名设备指纹，启动时由 BiliDevice 装填；
 *   · loginCookie（SESSDATA/bili_jct/DedeUserID 等）—— 扫码登录态，由 LoginStore 装填，
 *     未登录时为空，不影响匿名访问。
 */

import http from '@ohos.net.http';
import hilog from '@ohos.hilog';
import { BILI_REFERER } from '../common/Constants';
import { BiliRequestGate } from './BiliRequestGate';

export interface HttpRequestOptions {
  params?: Record<string, string | number>;
  headers?: Record<string, string>;
  method?: http.RequestMethod;
  /** POST 表单体（application/x-www-form-urlencoded）。 */
  body?: string;
  /**
   * 跳过自动附加的 Cookie 头（等价 fetch 的 credentials:'omit'）。
   * passport 扫码轮询必须带：带上 buvid / 旧登录态会干扰 B 站下发新登录 Cookie
   * （对齐 BBPlayer 的裸 poll 请求）。
   */
  skipCookie?: boolean;
  /**
   * 只跳过**登录** Cookie（buvid 通道保留），等价「退出登录后的匿名请求」。
   *
   * 用途：B 站对部分账号做**绑定登录 Cookie** 的风控 —— view/playurl 只要带
   * SESSDATA 就被拒（-352/-412/-799 或 HTTP 412），不带反而正常。音源解析链
   * 撞到这类错误时，用它把该次请求降级成匿名重发一轮，buvid 必须保留
   * （缺它部分接口会 412）。
   */
  skipLoginCookie?: boolean;
  /** 跳过自动附加的 Referer 头（passport 轮询同样不需要）。 */
  skipReferer?: boolean;
  /**
   * 覆盖引擎默认的最大重定向次数。`0` = **禁用重定向**（用于读 3xx 的 Location，
   * 解析分享短链必需，见 probeRedirectLocation）；不传 = 引擎默认（自动跟随）。
   */
  maxRedirects?: number;
}

export interface HttpTextResult {
  /** 响应体文本。 */
  text: string;
  /** 响应 Set-Cookie 的 value 部分（k=v; k=v 拼接），无则为空串。 */
  responseCookies: string;
}

export class HttpUtil {
  /**
   * 公共 Cookie（buvid3/buvid4）。缺了它首页推荐接口会返回 HTTP 412。
   */
  private static baseCookie: string = '';
  /**
   * 登录 Cookie（SESSDATA/bili_jct/DedeUserID/DedeUserID__ckMd5）。
   * 为空 = 匿名访问；由 service/LoginStore.ts 在启动装载 / 扫码成功 / 退出时维护。
   */
  private static loginCookie: string = '';
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

  /** 设置登录 Cookie（扫码登录成功 / 启动恢复时由 LoginStore 调用）。 */
  static setLoginCookie(c: string): void {
    HttpUtil.loginCookie = c;
  }

  static getLoginCookie(): string {
    return HttpUtil.loginCookie;
  }

  /** 清除登录 Cookie（退出登录），buvid 通道不受影响。 */
  static clearLoginCookie(): void {
    HttpUtil.loginCookie = '';
  }

  private static buildHeader(options?: HttpRequestOptions): Record<string, string> {
    const header: Record<string, string> = {
      'User-Agent': HttpUtil.userAgent,
      Accept: '*/*'
    };
    if (options?.skipReferer !== true) {
      header['Referer'] = BILI_REFERER;
    }
    if (options?.skipCookie !== true) {
      // 两条 Cookie 通道按序拼接：buvid 在前（缺它首页推荐会被 412 拦下），
      // 登录态在后（有则所有请求自动带上 SESSDATA）。
      // skipLoginCookie 只摘登录通道（账号级风控的匿名降级重试用），
      // buvid 必须保留 —— 匿名请求缺 buvid 同样会被 412。
      const cookieParts: string[] = [];
      if (HttpUtil.baseCookie.length > 0) {
        cookieParts.push(HttpUtil.baseCookie);
      }
      if (HttpUtil.loginCookie.length > 0 && options?.skipLoginCookie !== true) {
        cookieParts.push(HttpUtil.loginCookie);
      }
      if (cookieParts.length > 0) {
        header['Cookie'] = cookieParts.join('; ');
      }
    }
    const extra: Record<string, string> | undefined = options?.headers;
    if (extra) {
      const keys: string[] = Object.keys(extra);
      for (let i = 0; i < keys.length; i++) {
        header[keys[i]] = extra[keys[i]];
      }
    }
    return header;
  }

  /**
   * 闸门风控信号判定与上报（仅 B 站域请求调用，见 BiliRequestGate 注释）：
   *   · HTTP 412 / 403 / 429 —— 风控在 HTTP 层直接拦截（响应体不是 JSON）；
   *   · 响应体前 64 字符含 `"code":-352/-412/-509/-799` —— 业务层风控码
   *     （B 站响应体固定 `{"code":` 开头，前缀扫描无全量解析开销、无正文误报）；
   *   · 其余 —— 干净成功，冷却阶梯复位。
   */
  private static reportGateRisk(responseCode: number, body: string): void {
    if (responseCode === 412 || responseCode === 403 || responseCode === 429) {
      BiliRequestGate.noteRisk();
      return;
    }
    const prefix: string = body.length > 64 ? body.substring(0, 64) : body;
    if (prefix.indexOf('"code":-352') >= 0 || prefix.indexOf('"code":-412') >= 0 ||
      prefix.indexOf('"code":-509') >= 0 || prefix.indexOf('"code":-799') >= 0) {
      BiliRequestGate.noteRisk();
      return;
    }
    BiliRequestGate.noteSuccess();
  }

  /** 安全取响应体文本（非字符串形态返回空串，供风控前缀扫描，不参与业务解析） */
  private static resultAsText(resp: http.HttpResponse): string {
    if (typeof resp.result === 'string') {
      return resp.result;
    }
    return '';
  }

  /**
   * ⚠️ requestText / requestTextWithCookies 两个入口都必须**同时**传
   * `extraData` 与 `body`：
   *
   * API 26 起 `HttpRequestOptions` 拆出了独立的 `body` 字段，文档写明
   * 「body 与 extraData 同时配置时 **body 优先**，extraData 被忽略」。
   * 只传 extraData 时请求体可能完全发不出去 —— 抓包证据：POST 请求头里
   * 既无 content-length 也无 transfer-encoding，服务端收到 `bodyLen=0`，
   * 于是 ExClimbWuzhi 恒答 `{"code":-400,"message":"请求错误"}`。
   *
   * 两个字段内容相同，引擎按优先级取其一，不会重复发送；低版本没有 `body`
   * 字段时由 `extraData` 兜住。
   */

  static async requestText(url: string, options?: HttpRequestOptions): Promise<string> {
    // 全局节流闸门：B 站域请求排队取名额（节流 + 并发上限 +
    // 高优先插队 + 风控熔断），非 B 站 URL 直接放行（gated=false 不必 release）
    const gated: boolean = await BiliRequestGate.acquire(url);
    const req: http.HttpRequest = http.createHttp();
    try {
      // 请求侧留痕：resp 只打基础 URL，queryParams 走独立通道不进日志，
      // 打参数日志是为了分辨「参数错了」（如 view 的 bvid 为空 → -400）。
      // 参数序列化开销可忽略，仅在 requestText 出口打一条。
      const paramsText: string = options && options.params ? JSON.stringify(options.params) : '';
      hilog.info(0x0000, 'BiliMusicHttp', 'req %{public}s params=%{public}s', url, paramsText);
      const resp: http.HttpResponse = await req.request(url, {
        method: options?.method ?? http.RequestMethod.GET,
        header: HttpUtil.buildHeader(options),
        queryParams: options?.params,
        extraData: options?.body ?? undefined,
        body: options?.body ?? undefined,
        connectTimeout: 15000,
        readTimeout: 15000
      });
      // 风控探测先于 >=400 抛错：412/403/429 的上报点在这里（body 仅作扫描用）
      if (gated) {
        HttpUtil.reportGateRisk(resp.responseCode, HttpUtil.resultAsText(resp));
      }
      if (resp.responseCode >= 400) {
        throw new Error(`HTTP ${resp.responseCode} for ${url}`);
      }
      const resultText: string = resp.result as string;
      hilog.info(0x0000, 'BiliMusicHttp', 'resp %{public}s code=%{public}d body=%{public}s',
        url, resp.responseCode, resultText.substring(0, Math.min(200, resultText.length)));
      return resultText;
    } finally {
      req.destroy();
      if (gated) {
        BiliRequestGate.release(url);
      }
    }
  }

  static async requestJson<T>(url: string, options?: HttpRequestOptions): Promise<T> {
    const text: string = await HttpUtil.requestText(url, options);
    return JSON.parse(text) as T;
  }

  /**
   * 探测重定向目标（**不跟随**）：发一次 `maxRedirects: 0` 的 GET，读 3xx 响应的
   * `Location` 头。用于解析分享短链 —— QQ 音乐 `c6.y.qq.com/base/fcgi-bin/u?__=xxx`
   * 这类 URL 里**不含**歌单 ID，只能靠 302 反查（实测：Location 与 UA 无关，
   * 稳定给出 `…playlist.html?…&id=9725916480`）。
   *
   * **绝不抛错**：引擎对 maxRedirects 的支持程度、响应头键名大小写、服务器是否直接
   * 返回 2xx 都可能变，任何异常一律降级为空串，由调用方决定怎么提示用户
   * （不向上抛看不懂的错，方案 §2B）。
   */
  static async probeRedirectLocation(url: string, options?: HttpRequestOptions): Promise<string> {
    const gated: boolean = await BiliRequestGate.acquire(url);
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: HttpUtil.buildHeader(options),
        connectTimeout: 15000,
        readTimeout: 15000,
        maxRedirects: 0
      });
      if (gated) {
        HttpUtil.reportGateRisk(resp.responseCode, HttpUtil.resultAsText(resp));
      }
      const location: string = HttpUtil.readHeader(resp, 'location');
      hilog.info(0x0000, 'BiliMusicHttp', 'probe %{public}s code=%{public}d location=%{public}s',
        url, resp.responseCode, location);
      return location;
    } catch (e) {
      const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.warn(0x0000, 'BiliMusicHttp', 'probe failed %{public}s: %{public}s', url, detail);
      return '';
    } finally {
      req.destroy();
      if (gated) {
        BiliRequestGate.release(url);
      }
    }
  }

  /**
   * 按**不区分大小写**的键名从响应头取值（值非字符串、或键不存在时返回空串）。
   * ohos 对响应头键名的大小写不保证（`Location` / `location` 都见过），故必须归一化比较。
   */
  private static readHeader(resp: http.HttpResponse, lowerName: string): string {
    const header: Record<string, string> = resp.header as Record<string, string>;
    const keys: string[] = Object.keys(header);
    for (let i: number = 0; i < keys.length; i++) {
      if (keys[i].toLowerCase() === lowerName) {
        const value: Object = header[keys[i]] as Object;
        if (typeof value === 'string') {
          return value as string;
        }
        return '';
      }
    }
    return '';
  }

  /**
   * 与 requestText 相同，但额外返回响应 Set-Cookie（供扫码 / 短信登录接口提取登录 Cookie）。
   *
   * 提取策略：响应头 set-cookie 优先（对齐 RN 读原始头），ohos 的 resp.cookies 字段
   * 实测格式异常（见 extractResponseCookies）降为兜底；详见该方法注释。
   */
  static async requestTextWithCookies(url: string, options?: HttpRequestOptions): Promise<HttpTextResult> {
    const gated: boolean = await BiliRequestGate.acquire(url);
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: options?.method ?? http.RequestMethod.GET,
        header: HttpUtil.buildHeader(options),
        queryParams: options?.params,
        extraData: options?.body ?? undefined,
        body: options?.body ?? undefined,
        connectTimeout: 15000,
        readTimeout: 15000
      });
      if (gated) {
        HttpUtil.reportGateRisk(resp.responseCode, HttpUtil.resultAsText(resp));
      }
      if (resp.responseCode >= 400) {
        // >=400 直接抛异常不打 resp 日志，会把关键诊断信息吞掉
        hilog.warn(0x0000, 'BiliMusicHttp', 'HTTP %{public}d for %{public}s',
          resp.responseCode, url);
        throw new Error(`HTTP ${resp.responseCode} for ${url}`);
      }
      const text: string = resp.result as string;
      // Cookie 提取绝不允许抛错向上传播：登录成功帧是一次性的，提取失败只降级为
      // 空 Cookie（成功帧若在提取链路抛错，登录 Cookie 会被永久吞掉）。
      // 错误留痕后照常返回响应体。
      let responseCookies: string = '';
      try {
        responseCookies = HttpUtil.extractResponseCookies(resp);
      } catch (e) {
        console.warn(`extractResponseCookies failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
      }
      hilog.info(0x0000, 'BiliMusicHttp', 'resp %{public}s code=%{public}d body=%{public}s cookiesLen=%{public}d',
        url, resp.responseCode, text.substring(0, Math.min(200, text.length)), responseCookies.length);
      const result: HttpTextResult = { text: text, responseCookies: responseCookies };
      return result;
    } finally {
      req.destroy();
      if (gated) {
        BiliRequestGate.release(url);
      }
    }
  }

  /**
   * 从 HttpResponse 提取 Set-Cookie 的 value 串（k=v; k=v），缺失返回空串。
   *
   * 两个来源，**响应头优先**（对齐 RN 的 response.headers.get('Set-Cookie')，BBPlayer 同款）：
   *   · header['set-cookie']：ohos 把同名多条头用 ', ' 拼成一条，parseJoinedSetCookie 切回；
   *   · resp.cookies 字段：实测格式异常（串内无任何可解析 k=v、疑似 URL 编码，
   *     2297 字符解析出 0 个键），降级为兜底。
   * 两个来源都打格式指纹日志（不含值内容），若提取再失败可一次请求锁定原始格式。
   */
  private static extractResponseCookies(resp: http.HttpResponse): string {
    const header: Record<string, string> = resp.header as Record<string, string>;
    const keys: string[] = Object.keys(header);
    let headerCookie: string = '';
    for (let i = 0; i < keys.length; i++) {
      if (keys[i].toLowerCase() === 'set-cookie') {
        // ⚠️ 多条同名 set-cookie 头时，ohos 运行时给的值可能是「数组」而非字符串，
        // 直接当字符串调 .split 会抛 "undefined is not callable" ——
        // 统一走 normalizeSetCookieHeader 归一化。
        headerCookie = HttpUtil.normalizeSetCookieHeader(header[keys[i]] as Object);
        break;
      }
    }
    const direct: string = resp.cookies ?? '';
    hilog.info(0x0000, 'BiliMusicHttp', 'setCookieSrc header=[%{public}s] direct=[%{public}s]',
      HttpUtil.cookieFingerprint(headerCookie), HttpUtil.cookieFingerprint(direct));
    if (headerCookie.length > 0) {
      return headerCookie;
    }
    return direct;
  }

  /**
   * set-cookie 响应头的值归一化为 k=v; k=v 串。
   * ohos 的 header 值类型不稳定：单条时是 string，多条同名头时可能是 string[]——
   * 必须先 typeof 判别，数组则逐项拼接后再解析（全部按 ', ' 拼接统一走 parseJoinedSetCookie）。
   */
  private static normalizeSetCookieHeader(rawValue: Object): string {
    if (typeof rawValue === 'string') {
      return HttpUtil.parseJoinedSetCookie(rawValue as string);
    }
    // 数组形态：逐项过滤出字符串再拼接；非字符串非数组的意外形态安全返回空串
    const items: string[] = rawValue as string[];
    const parts: string[] = [];
    for (let i = 0; i < items.length; i++) {
      const item: Object = items[i] as Object;
      if (typeof item === 'string') {
        parts.push(item as string);
      }
    }
    if (parts.length === 0) {
      return '';
    }
    return HttpUtil.parseJoinedSetCookie(parts.join(', '));
  }

  /**
   * Cookie 串格式指纹：长度 + 特征字符计数，**不含任何键名与值内容**。
   * 用于诊断 ohos resp.cookies / set-cookie 响应头的原始格式差异（值是凭据，绝不能进日志）。
   */
  static cookieFingerprint(cookie: string): string {
    if (cookie.length === 0) {
      return 'empty';
    }
    let semi: number = 0;
    let comma: number = 0;
    let eq: number = 0;
    for (let i = 0; i < cookie.length; i++) {
      const ch: string = cookie.charAt(i);
      if (ch === ';') {
        semi++;
      } else if (ch === ',') {
        comma++;
      } else if (ch === '=') {
        eq++;
      }
    }
    const pct3d: number = HttpUtil.countOccurrences(cookie, '%3D') + HttpUtil.countOccurrences(cookie, '%3d');
    return `len:${cookie.length};semi:${semi};comma:${comma};eq:${eq};pct3d:${pct3d}`;
  }

  private static countOccurrences(haystack: string, needle: string): number {
    let count: number = 0;
    let idx: number = haystack.indexOf(needle);
    while (idx >= 0) {
      count++;
      idx = haystack.indexOf(needle, idx + needle.length);
    }
    return count;
  }

  /**
   * 提取 cookie 串里的 key 名列表。
   * **只返回名字、不返回值**，专用于日志诊断（键名不含凭据，可安全输出）。
   */
  static cookieKeys(cookie: string): string[] {
    const keys: string[] = [];
    if (cookie.length === 0) {
      return keys;
    }
    const items: string[] = cookie.split(';');
    for (let i = 0; i < items.length; i++) {
      const item: string = items[i].trim();
      const eq: number = item.indexOf('=');
      if (eq > 0) {
        keys.push(item.substring(0, eq));
      }
    }
    return keys;
  }

  /**
   * Cookie 串里是否含指定键名。
   * **不要用 Array.includes 替代**：ArkTS 运行时可能没有 Array.prototype.includes
   * （调用会抛 "undefined is not callable"）。
   */
  static cookieHasKey(cookie: string, key: string): boolean {
    return HttpUtil.cookieKeys(cookie).indexOf(key) >= 0;
  }

  /**
   * 解析被 ', ' 拼接的多条 Set-Cookie，返回 k=v; k=v 串。
   * 切分边界：逗号后的片段若以「标识符=」开头则视为新 Cookie；否则（如 Expires 日期
   * 里逗号后的 " 21 Oct..."，以数字开头）并回上一条。**不用正则实现**——本运行时存在
   * 内建缺失的先例（Array.includes、lookahead 正则均有风险）。
   * 每条只保留第一个 k=v，丢弃 Path=/Domain/Expires/HttpOnly 等属性。
   */
  private static parseJoinedSetCookie(joined: string): string {
    const rawParts: string[] = joined.split(',');
    // 先按逗号粗切，再把「不以标识符= 开头的片段」（Expires 日期的剩余部分）并回上一段
    const segments: string[] = [];
    for (let i = 0; i < rawParts.length; i++) {
      const part: string = rawParts[i].trim();
      if (part.length === 0) {
        continue;
      }
      if (HttpUtil.looksLikeCookiePair(part) || segments.length === 0) {
        segments.push(part);
      } else {
        segments[segments.length - 1] = `${segments[segments.length - 1]},${part}`;
      }
    }
    const pairs: string[] = [];
    for (let i = 0; i < segments.length; i++) {
      const segment: string = segments[i];
      const firstPairEnd: number = segment.indexOf(';');
      const pair: string = firstPairEnd >= 0 ? segment.substring(0, firstPairEnd).trim() : segment;
      if (pair.indexOf('=') > 0) {
        pairs.push(pair);
      }
    }
    return pairs.join('; ');
  }

  /** 片段是否形如「cookie名=」开头：名仅允许字母/下划线/（首字符后的）数字 */
  private static looksLikeCookiePair(part: string): boolean {
    const eq: number = part.indexOf('=');
    if (eq <= 0) {
      return false;
    }
    const name: string = part.substring(0, eq);
    for (let i = 0; i < name.length; i++) {
      const c: string = name.charAt(i);
      const isLetter: boolean = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c === '_';
      const isDigit: boolean = c >= '0' && c <= '9';
      if (!isLetter && !(i > 0 && isDigit)) {
        return false;
      }
    }
    return true;
  }
}
