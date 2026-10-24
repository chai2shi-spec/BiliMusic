/**
 * 设置二级页共享工具（2026-10-24 设置页二级菜单化改造）。
 *
 * 设置页按语义拆成四个二级子页（播放设置 / 下载与存储 / 外观设置 / 歌单备份）后，
 * 原设置页内的格式化函数与音质档位常量被多个子页共用，抽到本文件统一维护：
 *   · formatBytes / formatSleepMinutes / formatRemain / formatListenDuration —— 纯展示文案；
 *   · QualityOption / QUALITY_OPTIONS —— 播放 / 下载音质弹窗共用的档位表。
 */

import { AudioQuality } from '../model/MusicModels';

/**
 * 音质档位（播放 / 下载共用）。
 *
 * `value` 必须与 `AudioQuality` 枚举值逐字一致 —— 它同时就是 AppSettings.playQuality /
 * downloadQuality 的存储值，播放 / 下载内核每次取流都拿它去映射 B 站音频流 id。
 * `short` 是拼进 SelectDialog 单选行标题的短说明（SheetInfo 只有单行 title）：
 * B 站只提供它已有的档位，个别投稿最高只有 64 kbps，
 * 不写清楚的话用户会以为「选了高音质却还是小文件」是 App 的问题。
 */
export interface QualityOption {
  value: string;
  short: string;
}

export const QUALITY_OPTIONS: QualityOption[] = [
  { value: AudioQuality.STANDARD, short: '约 64 kbps，最省流量' },
  { value: AudioQuality.HIGH, short: '约 192 kbps，默认' },
  { value: AudioQuality.LOSSLESS, short: '优先 Hi-Res / 杜比' }
];

export function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  const kb: number = bytes / 1024;
  if (kb < 1024) {
    return `${kb.toFixed(1)} KB`;
  }
  const mb: number = kb / 1024;
  if (mb < 1024) {
    return `${mb.toFixed(1)} MB`;
  }
  return `${(mb / 1024).toFixed(2)} GB`;
}

export function formatSleepMinutes(minutes: number): string {
  if (minutes >= 60 && minutes % 60 === 0) {
    return `${minutes / 60} 小时`;
  }
  return `${minutes} 分钟`;
}

export function formatRemain(totalSeconds: number): string {
  const sec: number = Math.max(0, totalSeconds);
  const h: number = Math.floor(sec / 3600);
  const m: number = Math.floor((sec % 3600) / 60);
  const s: number = sec % 60;
  const mm: string = m < 10 ? `0${m}` : `${m}`;
  const ss: string = s < 10 ? `0${s}` : `${s}`;
  if (h > 0) {
    return `${h}:${mm}:${ss}`;
  }
  return `${mm}:${ss}`;
}

/**
 * 累计听歌时长的展示文案：满 1 小时按「X 小时 Y 分钟」，不足 1 小时按「X 分钟」，
 * 一分钟都没有（全新安装）显示「暂无记录」。
 */
export function formatListenDuration(totalSeconds: number): string {
  const sec: number = Math.max(0, Math.floor(totalSeconds));
  const h: number = Math.floor(sec / 3600);
  const m: number = Math.floor((sec % 3600) / 60);
  if (h > 0) {
    return `${h} 小时 ${m} 分钟`;
  }
  if (m > 0) {
    return `${m} 分钟`;
  }
  return '暂无记录';
}
