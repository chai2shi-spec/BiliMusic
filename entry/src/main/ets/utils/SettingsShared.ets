/**
 * 设置二级页共享工具。
 *
 * 设置页按语义拆成四个二级子页（播放设置 / 下载与存储 / 外观设置 / 歌单备份），
 * 多个子页共用的格式化函数与音质档位常量在本文件统一维护：
 *   · formatBytes / formatSleepMinutes / formatRemain / formatListenDuration —— 纯展示文案；
 *   · QualityOption / QUALITY_OPTIONS —— 播放 / 下载音质弹窗共用的档位表；
 *   · FadeDurationOption / FADE_DURATION_OPTIONS / fadeDurationLabelOf —— 淡入淡出档位表与文案。
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

/**
 * 淡入淡出档位（ms；0 = 关）。
 *
 * `ms` 即 AppSettings.fadeDurationMs 的存储值，播放内核（MusicPlayer）每次
 * 过渡开始时经 AppPreferences.getSettings() 就近读取（内存缓存，零 IO）。
 * `label` 同时用于设置行右侧文案与 SelectDialog 单选行标题。
 * 生效面：切歌旧曲淡出/新曲淡入、暂停淡出/恢复淡入；来电等系统打断不淡出。
 */
export interface FadeDurationOption {
  ms: number;
  label: string;
}

export const FADE_DURATION_OPTIONS: FadeDurationOption[] = [
  { ms: 0, label: '关' },
  { ms: 500, label: '0.5 秒' },
  { ms: 1000, label: '1 秒' },
  { ms: 2000, label: '2 秒' },
  { ms: 3000, label: '3 秒' }
];

/** 淡入淡出档位文案（未命中档位表回「关」——脏数据/旧版本残留值兜底） */
export function fadeDurationLabelOf(ms: number): string {
  for (let i = 0; i < FADE_DURATION_OPTIONS.length; i++) {
    if (FADE_DURATION_OPTIONS[i].ms === ms) {
      return FADE_DURATION_OPTIONS[i].label;
    }
  }
  return '关';
}

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

/** 定时停止播放的档位（分钟；0 = 关闭，不在选项里，走「关闭定时」动作） */
export const SLEEP_OPTIONS: number[] = [10, 20, 30, 60, 120];

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
