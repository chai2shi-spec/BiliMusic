/**
 * B 站 APP 域接口签名（appkey + ts + sign），2026-10-24 移植自 PiliPlus。
 *
 * 为什么需要：Web 域（api.bilibili.com + WBI）和 APP 域（appkey/appsec + md5）
 * 是**两套完全独立的风控策略**。同一条视频，Web playurl 可能因账号/IP 被判 -352，
 * 而 TV 端 playurl（APP 签名域）照常返回数据 —— 这正是兜底链最后一级的价值：
 * 不是在同一个策略里重试，而是**换一个策略**。
 *
 * 算法（对齐 PiliPlus `AppSign.appSign`）：
 *   1. 参数表补 `appkey` 与 `ts`（秒级时间戳）；
 *   2. 按 key 字典序排序；
 *   3. 拼成 `k=v&k=v`（键值都 encodeURIComponent）；
 *   4. `sign = md5(拼好的 query + appsec)`。
 *
 * ⚠️ 排序与编码顺序都不能改：B 站服务端用同一套规则重算，差一个字符就是 -3
 * 「API 校验失败」。
 */

import { md5 } from './CryptoUtil';
import { BILI_APP_KEY, BILI_APP_SEC } from '../common/Constants';

/**
 * 给参数表补齐 appkey / ts / sign，返回可直接拼到 URL 后面的 query 串。
 *
 * 不改入参（调用方拿到的 Record 保持原样）：内部先复制一份再加工 —— 否则
 * 复用同一份参数表重试时会带上上一次的 ts（服务端会判「签名过期」）。
 */
export function appSignQuery(params: Record<string, string>): string {
  const signed: Record<string, string> = {};
  const keys: string[] = Object.keys(params);
  for (let i = 0; i < keys.length; i++) {
    signed[keys[i]] = params[keys[i]];
  }
  signed['appkey'] = BILI_APP_KEY;
  signed['ts'] = String(Math.floor(Date.now() / 1000));
  const sorted: string[] = Object.keys(signed).sort();
  const parts: string[] = [];
  for (let i = 0; i < sorted.length; i++) {
    parts.push(`${encodeURIComponent(sorted[i])}=${encodeURIComponent(signed[sorted[i]])}`);
  }
  const query: string = parts.join('&');
  return `${query}&sign=${md5(query + BILI_APP_SEC)}`;
}
