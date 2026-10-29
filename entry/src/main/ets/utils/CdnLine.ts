/**
 * CDN 播放线路（upos 直链 host 替换）。
 *
 * 背景：B 站 playurl 下发的音频直链固定挂在 `upos-*` 家族的 CDN host 上，
 * 签名（upsig / uparams）只覆盖 path + query、与 host 无关 —— 同一条直链
 * 换到「镜像家族」的另一个 host 上签名依然有效。海外网络对个别 host
 * 不可达 / 被拒时，整首歌就表现为「能搜索、不能播放」。
 *
 * 方案：
 *  · 维护一份可替换的镜像 host 线路表（华为云 / 腾讯云 / Akamai / 08c）；
 *  · 「自动」模式下播放失败自动探测（Range GET 换 host 试连），命中的线路
 *    持久化到 AppSettings.autoPickedCdnLine，后续解析直接沿用；
 *  · 用户也可在「播放设置 → 播放线路」手动指定线路。
 *
 * 探测口径：对**当前失败的那条直链**做 Range GET（bytes=0-0），
 * 返回 200 / 206 即认为该线路在用户当前网络下可用。带 Referer / UA
 * 与真实取流一致，避免「探测通、取流拒」的误判。
 */

import http from '@ohos.net.http';
import { AppPreferences } from '../preferences/AppPreferences';
import { BILI_REFERER, BILI_APP_UA } from '../common/Constants';
import { recordPlaybackLog, PLAYBACK_LOG_WARN } from '../service/PlaybackLogStore';

/** 单条 CDN 线路（「自动」与「默认」两个选择项没有替换 host） */
export interface CdnLineOption {
  /** 线路 id：'auto' | 'default' | 'hw' | 'coso1' | 'akam' | 'm08c' */
  id: string;
  /** 展示名（设置页弹窗用） */
  label: string;
  /** 副文案（设置页弹窗用） */
  desc: string;
  /** 替换后的 upos host；'' = 不替换（auto / default） */
  uposHost: string;
}

/** 「自动」：播放失败时按序探测镜像线路，命中即持久化沿用 */
export const CDN_LINE_AUTO: string = 'auto';
/** 「默认」：不替换 host，直接用 playurl 下发的原始直链 */
export const CDN_LINE_DEFAULT: string = 'default';

/** 可探测的镜像线路，按探测优先级排列（大陆实测 hw / coso1 全通，akam / 08c 留给海外网络） */
export const CDN_MIRROR_LINES: CdnLineOption[] = [
  {
    id: 'hw',
    label: '华为云',
    desc: 'upos-sz-mirrorhw.bilivideo.com',
    uposHost: 'upos-sz-mirrorhw.bilivideo.com'
  },
  {
    id: 'coso1',
    label: '腾讯云',
    desc: 'upos-sz-mirrorcoso1.bilivideo.com',
    uposHost: 'upos-sz-mirrorcoso1.bilivideo.com'
  },
  {
    id: 'akam',
    label: 'Akamai',
    desc: 'upos-hz-mirrorakam.akamaized.net（海外网络优先）',
    uposHost: 'upos-hz-mirrorakam.akamaized.net'
  },
  {
    id: 'm08c',
    label: '08c',
    desc: 'upos-sz-mirror08c.bilivideo.com',
    uposHost: 'upos-sz-mirror08c.bilivideo.com'
  }
];

/** 设置页「播放线路」弹窗的完整选项（自动 + 默认 + 镜像线路） */
export const CDN_LINE_OPTIONS: CdnLineOption[] = [
  {
    id: CDN_LINE_AUTO,
    label: '自动',
    desc: '播放失败时自动探测可用线路（推荐）',
    uposHost: ''
  },
  {
    id: CDN_LINE_DEFAULT,
    label: '默认',
    desc: '使用 B 站下发的原始直链，不替换线路',
    uposHost: ''
  },
  {
    id: 'hw',
    label: '华为云',
    desc: 'upos-sz-mirrorhw.bilivideo.com',
    uposHost: 'upos-sz-mirrorhw.bilivideo.com'
  },
  {
    id: 'coso1',
    label: '腾讯云',
    desc: 'upos-sz-mirrorcoso1.bilivideo.com',
    uposHost: 'upos-sz-mirrorcoso1.bilivideo.com'
  },
  {
    id: 'akam',
    label: 'Akamai',
    desc: 'upos-hz-mirrorakam.akamaized.net（海外网络优先）',
    uposHost: 'upos-hz-mirrorakam.akamaized.net'
  },
  {
    id: 'm08c',
    label: '08c',
    desc: 'upos-sz-mirror08c.bilivideo.com',
    uposHost: 'upos-sz-mirror08c.bilivideo.com'
  }
];

/** 按 id 找线路；未知 id 返回 null（调用方回落「默认」） */
export function cdnLineById(id: string): CdnLineOption | null {
  for (let i = 0; i < CDN_LINE_OPTIONS.length; i++) {
    if (CDN_LINE_OPTIONS[i].id === id) {
      return CDN_LINE_OPTIONS[i];
    }
  }
  return null;
}

/** 选项展示名：未知 id 回落「默认」（设置页右侧值位用） */
export function cdnLineLabelOf(id: string): string {
  const line: CdnLineOption | null = cdnLineById(id);
  return line !== null ? line.label : '默认';
}

/**
 * 把一条 upos 直链的 host 替换为指定线路（path + query 原样保留，签名不受影响）。
 * 非 upos 直链（akamai 家族 / durl mp4 / 其他 CDN）与「不替换」线路原样返回。
 */
export function replaceUposHost(url: string, line: CdnLineOption): string {
  if (line.uposHost.length === 0 || url.length === 0) {
    return url;
  }
  // 只动 http(s)://upos- 开头的直链：B 站把音频统一挂在 upos-* 家族上，
  // 其他前缀（如已替换过的 akamaized.net）没有对应的镜像家族，硬换必 404。
  const lower: string = url.toLowerCase();
  const schemeMatch: boolean = lower.startsWith('https://upos-') || lower.startsWith('http://upos-');
  if (!schemeMatch) {
    return url;
  }
  const schemeLen: number = lower.startsWith('https://') ? 'https://'.length : 'http://'.length;
  const hostEnd: number = url.indexOf('/', schemeLen);
  if (hostEnd < 0) {
    // 没有路径的裸 host 直链不是合法音源地址，别动
    return url;
  }
  return `${url.substring(0, schemeLen)}${line.uposHost}${url.substring(hostEnd)}`;
}

/**
 * 当前生效的线路：
 *  · 手动线路 → 直接采用；
 *  · 「自动」→ 已探测命中过（autoPickedCdnLine 非空且合法）→ 沿用命中线路；
 *  · 其余（含未知 id）→ 「默认」（不替换），行为与历史版本完全一致。
 */
export function effectiveCdnLine(): CdnLineOption {
  const settings = AppPreferences.getSettings();
  const picked: string = settings.playCdnLine;
  if (picked !== CDN_LINE_AUTO) {
    const manual: CdnLineOption | null = cdnLineById(picked);
    return manual !== null ? manual : cdnLineById(CDN_LINE_DEFAULT) as CdnLineOption;
  }
  const autoPicked: string = settings.autoPickedCdnLine;
  if (autoPicked.length > 0) {
    const hit: CdnLineOption | null = cdnLineById(autoPicked);
    if (hit !== null && hit.uposHost.length > 0) {
      return hit;
    }
  }
  return cdnLineById(CDN_LINE_DEFAULT) as CdnLineOption;
}

/** 单条线路探测超时（ms）：探测串行进行，超时太长会把恢复链拖死 */
const CDN_PROBE_TIMEOUT_MS: number = 5000;

/**
 * 探测单条线路：对样例直链换 host 后做 Range GET（bytes=0-0），
 * 状态码 200 / 206 即通。任何异常（超时 / DNS 失败 / 4xx / 5xx）都算不通。
 */
function probeCdnLine(sampleUrl: string, line: CdnLineOption): Promise<boolean> {
  return new Promise<boolean>((resolve: (v: boolean) => void): void => {
    const probeUrl: string = replaceUposHost(sampleUrl, line);
    if (probeUrl === sampleUrl) {
      // 样例不是 upos 直链 / 线路不替换：没有可探测的对象
      resolve(false);
      return;
    }
    const req = http.createHttp();
    const finish = (ok: boolean): void => {
      req.destroy();
      resolve(ok);
    };
    req.request(probeUrl, {
      method: http.RequestMethod.GET,
      header: {
        'Referer': BILI_REFERER,
        'User-Agent': BILI_APP_UA,
        'Range': 'bytes=0-0'
      },
      connectTimeout: CDN_PROBE_TIMEOUT_MS,
      readTimeout: CDN_PROBE_TIMEOUT_MS,
      usingCache: false
    }).then((resp: http.HttpResponse): void => {
      finish(resp.responseCode === 200 || resp.responseCode === 206);
    }).catch((): void => {
      finish(false);
    });
  });
}

/**
 * 按优先级逐条探测镜像线路，返回第一条通的线路；全不通返回 null。
 * 探测结果入日志页（warn 级），海外用户反馈「不能播」时可直接对照。
 */
export async function probeCdnLinesInOrder(sampleUrl: string): Promise<CdnLineOption | null> {
  for (let i = 0; i < CDN_MIRROR_LINES.length; i++) {
    const line: CdnLineOption = CDN_MIRROR_LINES[i];
    const ok: boolean = await probeCdnLine(sampleUrl, line);
    if (ok) {
      recordPlaybackLog(PLAYBACK_LOG_WARN, `CDN line probe hit: ${line.id} (${line.uposHost})`);
      return line;
    }
  }
  recordPlaybackLog(PLAYBACK_LOG_WARN, 'CDN line probe: no mirror line reachable');
  return null;
}

/** 记住「自动」模式探测命中的线路（持久化，后续解析直接沿用） */
export function setAutoPickedCdnLine(lineId: string): void {
  AppPreferences.updateSettings((s): void => {
    s.autoPickedCdnLine = lineId;
  });
}
