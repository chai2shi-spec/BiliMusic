/**
 * B 站 WBI 签名。
 * 移植自原 React 版 bilibiliApi.ts：img_key+sub_key 经固定置换表取前 32 位 mixinKey，
 * w_rid = md5(字典序排序后的 query + mixinKey)。nav 接口返回的 wbi_img 每日轮换，缓存 6 小时。
 */

import { HttpUtil } from '../utils/HttpUtil';
import { md5 } from '../utils/CryptoUtil';
import { BILI_API, BILI_REFERER } from '../common/Constants';

const MIXIN_KEY_ENC_TAB: number[] = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
  33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61,
  26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36,
  20, 34, 44, 52
];

function getMixinKey(orig: string): string {
  let s: string = '';
  for (let i: number = 0; i < 32; i++) {
    s += orig[MIXIN_KEY_ENC_TAB[i]];
  }
  return s;
}

interface WbiCache {
  imgKey: string;
  subKey: string;
  ts: number;
}

let wbiKeysCache: WbiCache | null = null;

async function getWbiKeys(): Promise<{ imgKey: string; subKey: string }> {
  if (wbiKeysCache && Date.now() - wbiKeysCache.ts < 6 * 3600 * 1000) {
    return { imgKey: wbiKeysCache.imgKey, subKey: wbiKeysCache.subKey };
  }
  // 未登录时 nav 返回 code -101，但 wbi_img 仍有效，故单独解析
  const json = await HttpUtil.requestJson<{
    data?: { wbi_img?: { img_url?: string; sub_url?: string } };
  }>(`${BILI_API}/x/web-interface/nav`, { headers: { Referer: BILI_REFERER } });

  const imgUrl: string = json?.data?.wbi_img?.img_url || '';
  const subUrl: string = json?.data?.wbi_img?.sub_url || '';
  const imgKey: string = imgUrl.slice(imgUrl.lastIndexOf('/') + 1).split('.')[0];
  const subKey: string = subUrl.slice(subUrl.lastIndexOf('/') + 1).split('.')[0];
  wbiKeysCache = { imgKey, subKey, ts: Date.now() };
  return { imgKey, subKey };
}

/** 对参数做 WBI 签名，返回拼好的 query 字符串（含 wts、w_rid）。 */
export async function encodeWbi(params: Record<string, string | number>): Promise<string> {
  const keys: { imgKey: string; subKey: string } = await getWbiKeys();
  const mixinKey: string = getMixinKey(keys.imgKey + keys.subKey);

  const signParams: Record<string, string | number> = Object.assign({}, params, {
    wts: Math.round(Date.now() / 1000)
  });

  const sortedKeys: string[] = Object.keys(signParams).sort();
  const query: string = sortedKeys
    .map((k: string): string => {
      const v: string = String(signParams[k]).replace(/[!'()*]/g, '');
      return `${encodeURIComponent(k)}=${encodeURIComponent(v)}`;
    })
    .join('&');

  return `${query}&w_rid=${md5(query + mixinKey)}`;
}
