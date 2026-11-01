/**
 * 问候语时段定义（单一真源）。
 *
 * 主页标题问候语（Index.homeTitleRow 的「BiliMusic 早上好~」）与拾音页
 * 「听歌时段」偏好统计共用同一套六时段划分 —— 由主页标题问候语的时段
 * 区分统计卡横条，两处永远同口径：
 *   早上 [5,11) / 中午 [11,13) / 下午 [13,17) / 晚上 [17,23) /
 *   深夜 [23,24)∪[0,1) / 凌晨 [1,5)。
 *
 * 纯数据 + 纯函数，无 UI、无 IO；.ts 模块可被 .ets 与 .ts 双向 import。
 */

/** 单个问候语时段 */
export interface DaySegmentDef {
  /** 稳定键（ForEach key / 日志用） */
  key: string;
  /** 时段名（早上 / 中午 / 下午 / 晚上 / 深夜 / 凌晨） */
  label: string;
  /** 问候语文案（早上好~ / …） */
  greeting: string;
}

/**
 * 固定顺序六时段（早→凌晨）。
 * 顺序即拾音页「听歌时段」横条的渲染顺序；下标与
 * daySegmentIndexOfHour 的返回值一一对应。
 */
export const DAY_SEGMENTS: DaySegmentDef[] = [
  { key: 'morning', label: '早上', greeting: '早上好~' },
  { key: 'noon', label: '中午', greeting: '中午好~' },
  { key: 'afternoon', label: '下午', greeting: '下午好~' },
  { key: 'evening', label: '晚上', greeting: '晚上好~' },
  { key: 'lateNight', label: '深夜', greeting: '深夜好~' },
  { key: 'dawn', label: '凌晨', greeting: '凌晨好~' }
];

/**
 * 小时 → 时段下标（DAY_SEGMENTS 下标）：
 * 早上 [5,11)=0 / 中午 [11,13)=1 / 下午 [13,17)=2 / 晚上 [17,23)=3 /
 * 深夜 [23,24)∪[0,1)=4 / 凌晨 [1,5)=5。
 */
export function daySegmentIndexOfHour(hour: number): number {
  if (hour >= 5 && hour < 11) {
    return 0;
  }
  if (hour >= 11 && hour < 13) {
    return 1;
  }
  if (hour >= 13 && hour < 17) {
    return 2;
  }
  if (hour >= 17 && hour < 23) {
    return 3;
  }
  if (hour >= 23 || hour < 1) {
    return 4;
  }
  return 5;
}

/** 小时 → 问候语文案（主页标题问候语用；分段规则见 daySegmentIndexOfHour） */
export function dayGreeting(hour: number): string {
  return DAY_SEGMENTS[daySegmentIndexOfHour(hour)].greeting;
}
