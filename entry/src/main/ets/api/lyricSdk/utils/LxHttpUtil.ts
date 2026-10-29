/**
 * lx 歌词 SDK 的 HTTP 公共底座。
 *
 * 所有第三方源请求：不带 B 站 Cookie / Referer（skipCookie + skipReferer），
 * 自己给源站 Referer 与 UA；响应统一走 safeJson（容忍 JSONP 壳 / 空体）。
 */

import http from '@ohos.net.http';
import { HttpUtil, HttpRequestOptions } from '../../../utils/HttpUtil';

export const UA_DESKTOP: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/** 第三方歌词源的请求头：不带 B 站 Cookie / Referer，自己给源的 Referer */
export function thirdPartyOptions(referer: string, extra?: Record<string, string>): HttpRequestOptions {
  const headers: Record<string, string> = {
    'User-Agent': UA_DESKTOP,
    Referer: referer
  };
  if (extra !== undefined) {
    const keys: string[] = Object.keys(extra);
    for (let i = 0; i < keys.length; i++) {
      headers[keys[i]] = extra[keys[i]];
    }
  }
  const options: HttpRequestOptions = {
    headers: headers,
    skipCookie: true,
    skipReferer: true
  };
  return options;
}

/** JSON 请求体 POST 选项 */
export function jsonPostOptions(referer: string, bodyJson: string): HttpRequestOptions {
  const options: HttpRequestOptions = thirdPartyOptions(referer, {
    'Content-Type': 'application/json;charset=utf-8'
  });
  options.method = http.RequestMethod.POST;
  options.body = bodyJson;
  return options;
}

/** 表单 POST 选项 */
export function formPostOptions(referer: string, bodyForm: string): HttpRequestOptions {
  const options: HttpRequestOptions = thirdPartyOptions(referer, {
    'Content-Type': 'application/x-www-form-urlencoded'
  });
  options.method = http.RequestMethod.POST;
  options.body = bodyForm;
  return options;
}

/** 宽容 JSON 解析：空体 / JSONP 壳 / 非法 JSON 一律返回 null（不抛错） */
export function safeJson<T>(text: string): T | null {
  if (!text || text.length === 0) {
    return null;
  }
  let body: string = text.trim();
  const lparen: number = body.indexOf('(');
  if (!body.startsWith('{') && !body.startsWith('[') && lparen > 0 && body.endsWith(')')) {
    body = body.substring(lparen + 1, body.length - 1);
  }
  try {
    return JSON.parse(body) as T;
  } catch (e) {
    return null;
  }
}
