/**
 * 听歌日记聚合模块（纯函数层，无 UI、无 IO）。
 *
 * 输入：PlaySessionStore 的全量会话（13 个月窗）+ 周期锚点；
 * 输出：DiaryReport —— 听歌日记页一屏所需的全部派生数据
 * （KPI / 分桶柱状图 / 循环榜 / 常听 UP / 新面孔 / 句式 / 空态文案）。
 *
 * 口径（design/听歌日记-页面设计方案.md §5）：
 *   · 有效收听 = 单次会话 ms ≥ 30000 或 ms ≥ duration × 50%；
 *   · 听歌时长 = 周期内所有会话 ms 求和（中途切歌不按整首算）；
 *   · 播放次数 / 不同歌曲 / 听歌天数 / 榜单 = 只按有效收听计；
 *   · 常听 UP = 按 upMid 聚合时长降序，upMid 空回落 artist；
 *   · 新面孔 = 首次出现（本机历史窗内）落在本周期的 UP；
 *   · 周期边界周一起算；跨零点会话按 startedAt 归属不拆分。
 *
 * 「没听」（0）与「没统计到」（—）不混：周期完全早于最早一条会话且
 * 历史非空 → listenMsKnown=false，KPI 显示 —。
 */

import { PlaySession, getRetentionFloorMs } from './PlaySessionStore';
import { DAY_SEGMENTS, daySegmentIndexOfHour } from '../common/DaySegments';

/** 统计周期 */
export enum DiaryPeriod {
  Day = 'day',
  Week = 'week',
  Month = 'month',
  Year = 'year'
}

/** 周期区间 [fromMs, toMs)，本地时区 */
export interface DiaryRange {
  fromMs: number;
  toMs: number;
}

/** KPI 单格：数值与单位分两行渲染（4 位数同行会挤爆 83px 列宽） */
export interface DiaryKpiCell {
  value: string;
  unit: string;
}

/** 柱状图单桶 */
export interface DiaryBucket {
  /** 轴标签（抽稀后仍占位，label 空串 = 该位不显示） */
  label: string;
  /** 该桶听歌时长 ms（全部会话求和） */
  ms: number;
}

/** 时段偏好单行（问候语六时段，见 common/DaySegments） */
export interface DiaryDaySegment {
  /** 稳定键（DAY_SEGMENTS.key） */
  key: string;
  /** 时段名（早上 / 中午 / 下午 / 晚上 / 深夜 / 凌晨） */
  label: string;
  /** 该时段收听时长 ms（周期内全部会话求和，与时长 KPI 同口径） */
  ms: number;
  /** 占周期总时长百分比（四舍五入；总时长 0 时为 0） */
  pct: number;
}

/** 循环榜条目（同时是 Hero 封面轮播的数据源） */
export interface DiaryTopTrack {
  trackId: string;
  title: string;
  artist: string;
  coverUrl: string;
  bvid: string;
  /**
   * 曲目时长（秒）。聚合自桶内最新一条带时长的会话；0 = 全程未知。
   *
   * 循环榜点播（ListenDiaryPage.buildLoopTrack）必须把它带进 Track.duration：
   * 为 0 时 MusicPlayer.rememberedStartSec 的续播保护
   * （posSec <= duration - RESUME_TAIL_SEC）因 duration<=0 直接放行，
   * 「上次听到曲末」的条目（lastPosSec ≈ 时长）会从曲末起播 ——
   * 起播即 completed 触发自动切歌，落到队列里同 bvid 的 P1 上，
   * 表现为「循环榜点任意分 P 都播第一首歌」。
   */
  duration: number;
  /** 有效收听次数 */
  plays: number;
  /** 总收听 ms */
  totalMs: number;
  /** 有有效收听的自然日数 */
  dayCount: number;
}

/** 常听 UP 条目 */
export interface DiaryTopUp {
  /** 聚合键（upMid，空回落 artist） */
  key: string;
  /** UP 主 mid（空 = 不可跳主页） */
  upMid: string;
  name: string;
  plays: number;
  totalMs: number;
  /** 头像：该 UP 最常听曲目的封面（UP 无独立头像字段） */
  avatarUrl: string;
}

/** 一屏报告（页面按字段渲染，不再自行计算） */
export interface DiaryReport {
  period: DiaryPeriod;
  range: DiaryRange;
  /** 是否当前进行中的周期（右箭头禁用 / 空态形态依据） */
  isCurrent: boolean;
  /** 翻页行日期文案（10月25日 周六 / 10月19日 — 10月25日 / 2026 年 10 月 / 2026 年） */
  dateRangeLabel: string;
  /** Hero 左上角胶囊标签（今日封面 / 本周封面 / …；往期带日期前缀） */
  heroLabel: string;
  /** 区块名前缀（今日 / 本周 / 本月 / 年度；往期带日期前缀） */
  sectionPrefix: string;
  /** 一句话（空周期：当前=sentence 有值、往期=空串配 emptyHint） */
  sentence: string;
  /** 往期空周期居中提示 */
  emptyHint: string;
  /** 本周期无任何有效收听 */
  isEmpty: boolean;
  /** 时长统计是否覆盖到该周期（false → KPI 显示 —） */
  listenMsKnown: boolean;
  kpiListen: DiaryKpiCell;
  kpiPlays: DiaryKpiCell;
  kpiSongs: DiaryKpiCell;
  /** 第四格：日视图 = 位 UP 主，其余 = 天听歌 */
  kpiExtra: DiaryKpiCell;
  buckets: DiaryBucket[];
  barWidthVp: number;
  /** 峰值桶提示（周五最多 / 21:00 最多 / 第 3 周最多 / 9 月最多；空=暂无数据） */
  peakLabel: string;
  /** 峰值桶 ms（柱高换算分母） */
  maxBucketMs: number;
  /** 均值虚线的 ms 高度（按已开始的桶数求平均） */
  avgMsPerBucket: number;
  /** 卡底小字（虚线 = 日均 1.8h） */
  avgLabel: string;
  /** 时段偏好六行（固定顺序 早→凌晨，恒长 6；问候语六时段口径） */
  daySegments: DiaryDaySegment[];
  /** 六时段总收听 ms（= 周期内全部会话时长和；0 = 无数据，卡片隐藏依据） */
  daySegmentsTotalMs: number;
  /** 峰值时段提示（晚上居多；无数据为空串） */
  dayPeakSegmentLabel: string;
  topTracks: DiaryTopTrack[];
  /** 标签云拉取范围：有效收听、有 BV 号的曲目按收听时长降序取前 20（周期标签用） */
  tagTracks: DiaryTopTrack[];
  topUps: DiaryTopUp[];
  /** 新面孔完整清单（时长降序，与常听同序；点击卡片进清单页用） */
  newFaces: DiaryTopUp[];
  newFaceTitle: string;
  newFaceSub: string;
  newFaceCount: number;
  newFaceAvatars: string[];
  /** 完播率（0-100，有效收听里 completed 占比；无有效收听 = -1） */
  completionPct: number;
  /** 中途切走数（保守口径：!completed && ms < 30000） */
  abandonedCount: number;
  /** 与等长上一周期的时长差 ms（正=变多） */
  deltaListenMs: number;
  /** 上一周期对比基准时长 ms（0=无基准，环比行不渲染） */
  prevListenMs: number;
  /** 当前连续听歌天数（当前周期截至今天，往期截至周期末日） */
  streakDays: number;
  /** 历史最长连续天数（13 个月窗内） */
  longestStreakDays: number;
  /** 周期完全超出 13 个月保留窗（空态文案换保留期提示） */
  outOfRetention: boolean;
  /** 已到保留期下限（翻页行左箭头禁用依据） */
  atHistoryFloor: boolean;
}

/** 有效收听阈值：单次会话 ≥ 30s */
const VALID_MIN_MS: number = 30000;

/** 单曲集中句式的占比阈值 */
const TOP1_SHARE_THRESHOLD: number = 0.4;

/** 「只来了 N 天」句式的天数阈值 */
const FEW_DAYS_THRESHOLD: number = 2;

/** 标签云拉取范围上限：按收听时长取前 N 首（有效收听、有 BV 号） */
const TAG_SCOPE_LIMIT: number = 20;

/** 周期翻页下限（再往前必然无数据，防翻到 1970） */
const MIN_ANCHOR_MS: number = 946684800000; // 2000-01-01

/** 周内中文序号（周一到周日，周一开头） */
const WEEKDAY_SHORT: string[] = ['一', '二', '三', '四', '五', '六', '日'];

/** getDay() 序号（0=周日）转中文全名 */
const WEEKDAY_FULL: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

/** 自然日零点（本地时区） */
function dayStartOf(ms: number): number {
  const d: Date = new Date(ms);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** 周一开头的星期序号：0=周一 … 6=周日 */
function mondayIndex(d: Date): number {
  return (d.getDay() + 6) % 7;
}

/** 周期区间：日=自然日 / 周=周一起 / 月=自然月 / 年=自然年 */
export function diaryPeriodRange(period: DiaryPeriod, anchorMs: number): DiaryRange {
  const d: Date = new Date(anchorMs);
  d.setHours(0, 0, 0, 0);
  if (period === DiaryPeriod.Day) {
    return { fromMs: d.getTime(), toMs: d.getTime() + 86400000 };
  }
  if (period === DiaryPeriod.Week) {
    const from: number = d.getTime() - mondayIndex(d) * 86400000;
    return { fromMs: from, toMs: from + 7 * 86400000 };
  }
  if (period === DiaryPeriod.Month) {
    d.setDate(1);
    const from: number = d.getTime();
    const e: Date = new Date(from);
    e.setMonth(e.getMonth() + 1);
    return { fromMs: from, toMs: e.getTime() };
  }
  d.setMonth(0, 1);
  const from: number = d.getTime();
  const e: Date = new Date(from);
  e.setFullYear(e.getFullYear() + 1);
  return { fromMs: from, toMs: e.getTime() };
}

/**
 * 周期锚点平移：delta=-1 上一期 / +1 下一期。
 * 下限 = 保留期下限（数据只有 13 个月）与 2000-01-01 双护栏；
 * 月/年平移前先把日/月钉到 1 号 —— setMonth/setFullYear 在「日/月超界」时
 * 会溢出到下一月（31 号锚点翻月还停在本月、2-29 翻平年跳 3 月）。
 */
export function diaryShiftAnchor(period: DiaryPeriod, anchorMs: number, delta: number): number {
  let shifted: number = anchorMs;
  if (period === DiaryPeriod.Day) {
    shifted = anchorMs + delta * 86400000;
  } else if (period === DiaryPeriod.Week) {
    shifted = anchorMs + delta * 7 * 86400000;
  } else if (period === DiaryPeriod.Month) {
    const d: Date = new Date(anchorMs);
    d.setDate(1);
    d.setMonth(d.getMonth() + delta);
    shifted = d.getTime();
  } else {
    const d: Date = new Date(anchorMs);
    d.setMonth(0, 1);
    d.setFullYear(d.getFullYear() + delta);
    shifted = d.getTime();
  }
  return Math.max(shifted, Math.max(getRetentionFloorMs(), MIN_ANCHOR_MS));
}

/** 是否当前进行中的周期 */
export function isCurrentDiaryRange(period: DiaryPeriod, anchorMs: number): boolean {
  const r: DiaryRange = diaryPeriodRange(period, anchorMs);
  const now: number = Date.now();
  return r.fromMs <= now && now < r.toMs;
}

/** 数值格式化：≥1 万用 `1.2 万`，千位加千分位，其余原样 */
export function formatDiaryCount(n: number): string {
  if (n >= 10000) {
    const wan: number = Math.round(n / 1000) / 10;
    return `${wan} 万`;
  }
  if (n >= 1000) {
    const s: string = `${n}`;
    return `${s.substring(0, s.length - 3)},${s.substring(s.length - 3)}`;
  }
  return `${n}`;
}

/** 时长格式化（KPI / UP 时长）：≥1h 一位小数（去尾 0）+ 小时，<1h 取整分钟 */
export function formatDiaryDuration(ms: number): DiaryKpiCell {
  if (ms <= 0) {
    return { value: '0', unit: '分钟' };
  }
  const hours: number = ms / 3600000;
  if (hours >= 1) {
    const rounded: number = Math.round(hours * 10) / 10;
    const s: string = Number.isInteger(rounded) ? `${rounded}` : `${rounded.toFixed(1)}`;
    return { value: s, unit: '小时' };
  }
  return { value: `${Math.max(1, Math.round(ms / 60000))}`, unit: '分钟' };
}

/** 均值小字里的时长：≥1h 用 `1.8h`，<1h 用 `42分钟` */
function formatAvgValue(ms: number): string {
  const hours: number = ms / 3600000;
  if (hours >= 1) {
    const rounded: number = Math.round(hours * 10) / 10;
    return Number.isInteger(rounded) ? `${rounded}h` : `${rounded.toFixed(1)}h`;
  }
  return `${Math.max(1, Math.round(ms / 60000))}分钟`;
}

/** 翻页行日期文案（含当年省年、跨年补年规则） */
function buildDateRangeLabel(period: DiaryPeriod, range: DiaryRange): string {
  const from: Date = new Date(range.fromMs);
  const nowYear: number = new Date().getFullYear();
  if (period === DiaryPeriod.Day) {
    const wd: string = WEEKDAY_FULL[from.getDay()];
    const yearPrefix: string = from.getFullYear() !== nowYear ? `${from.getFullYear()}年` : '';
    return `${yearPrefix}${from.getMonth() + 1}月${from.getDate()}日 ${wd}`;
  }
  if (period === DiaryPeriod.Week) {
    const to: Date = new Date(range.toMs - 86400000);
    const yearPrefix: string = from.getFullYear() !== nowYear ? `${from.getFullYear()}年` : '';
    return `${yearPrefix}${from.getMonth() + 1}月${from.getDate()}日 — ${to.getMonth() + 1}月${to.getDate()}日`;
  }
  if (period === DiaryPeriod.Month) {
    return `${from.getFullYear()} 年 ${from.getMonth() + 1} 月`;
  }
  return `${from.getFullYear()} 年`;
}

/** Hero 胶囊标签：当前周期用相对称呼，往期带日期前缀消歧义 */
function buildHeroLabel(period: DiaryPeriod, range: DiaryRange, isCurrent: boolean): string {
  if (isCurrent) {
    if (period === DiaryPeriod.Day) {
      return '今日封面';
    }
    if (period === DiaryPeriod.Week) {
      return '本周封面';
    }
    if (period === DiaryPeriod.Month) {
      return '本月封面';
    }
    return '年度封面';
  }
  const from: Date = new Date(range.fromMs);
  if (period === DiaryPeriod.Day) {
    return `${from.getMonth() + 1}月${from.getDate()}日封面`;
  }
  if (period === DiaryPeriod.Week) {
    return `${from.getMonth() + 1}月${from.getDate()}日那周封面`;
  }
  if (period === DiaryPeriod.Month) {
    return `${from.getFullYear()}年${from.getMonth() + 1}月封面`;
  }
  return `${from.getFullYear()}年封面`;
}

/** 区块名前缀：今日 / 本周 / 本月 / 年度（往期带日期前缀） */
function buildSectionPrefix(period: DiaryPeriod, range: DiaryRange, isCurrent: boolean): string {
  if (isCurrent) {
    if (period === DiaryPeriod.Day) {
      return '今日';
    }
    if (period === DiaryPeriod.Week) {
      return '本周';
    }
    if (period === DiaryPeriod.Month) {
      return '本月';
    }
    return '年度';
  }
  const from: Date = new Date(range.fromMs);
  if (period === DiaryPeriod.Day) {
    return `${from.getMonth() + 1}月${from.getDate()}日`;
  }
  if (period === DiaryPeriod.Week) {
    return `${from.getMonth() + 1}月${from.getDate()}日那周`;
  }
  if (period === DiaryPeriod.Month) {
    return `${from.getFullYear()}年${from.getMonth() + 1}月`;
  }
  return `${from.getFullYear()}年`;
}

/** 周期内指代词（这一周 / 这一天 / 这个月 / 这一年），句式用 */
function periodWord(period: DiaryPeriod): string {
  if (period === DiaryPeriod.Day) {
    return '这一天';
  }
  if (period === DiaryPeriod.Week) {
    return '这一周';
  }
  if (period === DiaryPeriod.Month) {
    return '这个月';
  }
  return '这一年';
}

/** 空态专用周期词（今天 / 这周 / 这个月 / 今年），空态句式用 */
function emptyWordOf(period: DiaryPeriod): string {
  if (period === DiaryPeriod.Day) {
    return '今天';
  }
  if (period === DiaryPeriod.Week) {
    return '这周';
  }
  if (period === DiaryPeriod.Month) {
    return '这个月';
  }
  return '今年';
}

/** 一句话参数上下文（各句式类别按需取用） */
interface SentenceCtx {
  /** 空态专用周期词（emptyWordOf） */
  emptyWord: string;
  /** 指代词（periodWord） */
  periodWord: string;
  /** 「只来了 N 天」句式的天数 */
  fewDays: number;
  /** 单曲占比句式的百分比 */
  pct: number;
  /** 单曲占比句式的歌名 */
  top1Title: string;
  /** 单曲占比句式的循环次数（Top1 有效播放次数） */
  top1Plays: number;
  /** 周期总收听时长文案（如「3.2 小时」，formatDiaryDuration 口径） */
  listenText: string;
  /** 「反复遇见」句式的歌曲数 */
  repeated: number;
  /** 「初次遇见」句式的歌曲数 */
  metCount: number;
  /** 连续听歌天数句式：当前连续天数 */
  streak: number;
  /** 连续听歌天数句式：历史最长连续天数 */
  longestStreak: number;
}

/** 单条句式模板（参数化生成函数） */
type SentenceFmt = (ctx: SentenceCtx) => string;

/**
 * 句式变体池：五类各 6 条（第 0-2 条 = 原有句式，3-5 为扩充，合计 30 种）。
 * 措辞纪律与原句式一致：陈述式、不用感叹号、13px 两行内；
 * 变体组合维度：周期词 / 天数 / 时长 / 占比 / 歌名 / 次数 / 歌曲数。
 */

/** 空态（当前周期还没听歌） */
const V_EMPTY: SentenceFmt[] = [
  (c: SentenceCtx): string => `${c.emptyWord}还没听歌`,
  (c: SentenceCtx): string => `${c.emptyWord}的耳朵还在放假`,
  (c: SentenceCtx): string => `${c.emptyWord}还没响起旋律，去首页挑一首吧`,
  (c: SentenceCtx): string => `${c.emptyWord}，音乐还在等你按下播放键`,
  (c: SentenceCtx): string => `${c.emptyWord}，耳朵还空着，随时可以开始`,
  (c: SentenceCtx): string => `${c.emptyWord}还没有出现你的循环曲目`
];

/** 只来了 N 天（非日视图且听歌天数 ≤ 2） */
const V_FEW_DAYS: SentenceFmt[] = [
  (c: SentenceCtx): string => `${c.periodWord}你只来了 ${c.fewDays} 天，但每次都很专注`,
  (c: SentenceCtx): string => `${c.periodWord}你只来了 ${c.fewDays} 天，每一次都很尽兴`,
  (c: SentenceCtx): string => `只在 ${c.fewDays} 天打开过音乐，但每次都没白听`,
  (c: SentenceCtx): string => `${c.periodWord}只来了 ${c.fewDays} 天，却把 ${c.listenText} 听得明明白白`,
  (c: SentenceCtx): string => `${c.fewDays} 天的出勤，撑起了${c.periodWord}的 ${c.listenText}`,
  (c: SentenceCtx): string => `${c.periodWord}你露面不多——${c.fewDays} 天，但耳朵没闲着`
];

/** 单曲占比 ≥ 40% */
const V_TOP1_SHARE: SentenceFmt[] = [
  (c: SentenceCtx): string => `${c.pct}% 的时间都给了《${c.top1Title}》`,
  (c: SentenceCtx): string => `${c.pct}% 的时光，都和《${c.top1Title}》在一起`,
  (c: SentenceCtx): string => `《${c.top1Title}》承包了${c.periodWord}的 ${c.pct}%`,
  (c: SentenceCtx): string => `《${c.top1Title}》被你循环了 ${c.top1Plays} 次，占${c.periodWord}的 ${c.pct}%`,
  (c: SentenceCtx): string => `有一首歌叫《${c.top1Title}》，它拿走了你的 ${c.pct}%`,
  (c: SentenceCtx): string => `${c.pct}% 的播放记录，写着同一个名字：《${c.top1Title}》`
];

/** 反复遇见（有 ≥2 次播放的歌） */
const V_REPEATED: SentenceFmt[] = [
  (c: SentenceCtx): string => `${c.periodWord}，你反复遇见了 ${c.repeated} 首歌`,
  (c: SentenceCtx): string => `${c.periodWord}，有 ${c.repeated} 首歌你舍不得只听一次`,
  (c: SentenceCtx): string => `${c.periodWord}，${c.repeated} 首歌在你这里反复停留`,
  (c: SentenceCtx): string => `${c.periodWord}，${c.repeated} 首歌被你听了不止一遍`,
  (c: SentenceCtx): string => `${c.periodWord}，你有 ${c.repeated} 首「舍不得切走」的歌`,
  (c: SentenceCtx): string => `${c.periodWord}，${c.repeated} 首歌成了你的回头客`
];

/** 初次遇见（无重复播放） */
const V_MET: SentenceFmt[] = [
  (c: SentenceCtx): string => `${c.periodWord}，你遇见了 ${c.metCount} 首歌`,
  (c: SentenceCtx): string => `${c.periodWord}，${c.metCount} 首新声音路过你的耳朵`,
  (c: SentenceCtx): string => `${c.periodWord}，歌单里多了 ${c.metCount} 张新面孔`,
  (c: SentenceCtx): string => `${c.periodWord}，${c.metCount} 首歌和你初次见面`,
  (c: SentenceCtx): string => `${c.periodWord}，${c.listenText} 里藏着 ${c.metCount} 次初遇`,
  (c: SentenceCtx): string => `${c.periodWord}，你的耳朵新认识了 ${c.metCount} 首歌`
];

/** 连续听歌天数（仅当前周期且 streak ≥ 3 时命中；现在时陈述，往期不用） */
const V_STREAK: SentenceFmt[] = [
  (c: SentenceCtx): string => `你已经连续 ${c.streak} 天打开拾音，最长纪录是 ${c.longestStreak} 天`,
  (c: SentenceCtx): string => `连续 ${c.streak} 天都有音乐陪你，之前最长是 ${c.longestStreak} 天`,
  (c: SentenceCtx): string => `你连着 ${c.streak} 天没有落下听歌这件事`,
  (c: SentenceCtx): string => `连续 ${c.streak} 天的出勤，最长的一次是 ${c.longestStreak} 天`,
  (c: SentenceCtx): string => `到${c.emptyWord}为止，你已经连续 ${c.streak} 天在听歌`,
  (c: SentenceCtx): string => `${c.streak} 天连续不断，是你的最新纪录（最长 ${c.longestStreak} 天）`
];

/** 简单字符串散列（djb2）：句式变体选取种子，无需密码学强度 */
function seedHash(seed: string): number {
  let h: number = 5381;
  for (let i = 0; i < seed.length; i++) {
    h = ((h * 33) + seed.charCodeAt(i)) >>> 0;
  }
  return h;
}

/**
 * 确定性选取：同种子同变体 —— 同周期视图重算幂等（翻页重渲染 / 实时刷新
 * reload 均不跳句），种子含周期与周期起点，切周期 / ‹ › 翻页自然轮换。
 */
function pickSentence(variants: SentenceFmt[], seed: string, ctx: SentenceCtx): string {
  return variants[seedHash(seed) % variants.length](ctx);
}

/** 单条会话是否计入「有效收听」 */
function isValidListen(s: PlaySession): boolean {
  if (s.ms >= VALID_MIN_MS) {
    return true;
  }
  return s.durationMs > 0 && s.ms >= s.durationMs * 0.5;
}

/** 曲目聚合桶 */
class TrackAgg {
  trackId: string = '';
  title: string = '';
  artist: string = '';
  coverUrl: string = '';
  bvid: string = '';
  plays: number = 0;
  totalMs: number = 0;
  /** 曲目时长（秒）：桶内最新一条 durationMs>0 的会话换算；0 = 未知 */
  durationSec: number = 0;
  days: Set<number> = new Set<number>();
  lastStartedAt: number = 0;
}

/** UP 聚合桶 */
class UpAgg {
  key: string = '';
  upMid: string = '';
  name: string = '';
  plays: number = 0;
  totalMs: number = 0;
  /** UP 内按曲目计次（选最常听曲目的封面当头像） */
  trackPlays: Map<string, number> = new Map<string, number>();
  trackCovers: Map<string, string> = new Map<string, string>();
  firstSeenAt: number = Number.MAX_SAFE_INTEGER;
}

/** 会话归属的聚合键：upMid 优先，空回落 artist */
function upKeyOf(s: PlaySession): string {
  if (s.upMid.length > 0) {
    return `mid:${s.upMid}`;
  }
  if (s.artist.length > 0) {
    return `artist:${s.artist}`;
  }
  return 'unknown';
}

/**
 * 聚合入口：allSessions = 13 个月窗内全部会话（页面一次取全缓存）。
 * 新面孔的「首次出现」即在该窗内判定（近似，可接受）。
 */
export function computeDiaryReport(period: DiaryPeriod, anchorMs: number,
  allSessions: PlaySession[]): DiaryReport {
  const range: DiaryRange = diaryPeriodRange(period, anchorMs);
  const isCurrent: boolean = isCurrentDiaryRange(period, anchorMs);

  // ── 历史覆盖判定：周期完全早于最早一条会话 → 「没统计到」（— 而非 0）──
  let earliestMs: number = Number.MAX_SAFE_INTEGER;
  let hasHistory: boolean = false;
  for (let i = 0; i < allSessions.length; i++) {
    hasHistory = true;
    if (allSessions[i].startedAt < earliestMs) {
      earliestMs = allSessions[i].startedAt;
    }
  }
  const listenMsKnown: boolean = !(hasHistory && range.toMs <= earliestMs);

  // ── 区间内会话遍历聚合 ──
  const trackAggs: Map<string, TrackAgg> = new Map<string, TrackAgg>();
  const upAggs: Map<string, UpAgg> = new Map<string, UpAgg>();
  let totalMs: number = 0;
  let validPlays: number = 0;
  /** 有效收听里自然播完的次数（完播率分子） */
  let completedValid: number = 0;
  /** 中途切走数（保守口径：未播完且连 30s 都没到） */
  let abandonedCount: number = 0;
  const listenedDays: Set<number> = new Set<number>();
  /** 全窗有效收听日（连续天数跨周期判定用；「打开 App 但没播」不算） */
  const allValidDays: Set<number> = new Set<number>();
  for (let i = 0; i < allSessions.length; i++) {
    const s: PlaySession = allSessions[i];
    // UP 首次出现时间：全历史窗滚动最小值（新面孔判定用）
    const gKey: string = upKeyOf(s);
    let gAgg: UpAgg | undefined = upAggs.get(gKey);
    if (gAgg === undefined) {
      gAgg = new UpAgg();
      gAgg.key = gKey;
      gAgg.upMid = s.upMid;
      gAgg.name = s.artist;
      upAggs.set(gKey, gAgg);
    }
    if (s.startedAt < gAgg.firstSeenAt) {
      gAgg.firstSeenAt = s.startedAt;
    }
    if (isValidListen(s)) {
      allValidDays.add(dayStartOf(s.startedAt));
    }
    if (s.startedAt < range.fromMs || s.startedAt >= range.toMs) {
      continue;
    }
    totalMs += s.ms;
    if (s.completed && isValidListen(s)) {
      completedValid++;
    }
    if (!s.completed && s.ms < VALID_MIN_MS) {
      abandonedCount++;
    }
    // 曲目聚合（时长全量计，次数/天数只计有效收听）
    let tAgg: TrackAgg | undefined = trackAggs.get(s.trackId);
    if (tAgg === undefined) {
      tAgg = new TrackAgg();
      tAgg.trackId = s.trackId;
      trackAggs.set(s.trackId, tAgg);
    }
    tAgg.totalMs += s.ms;
    if (s.startedAt >= tAgg.lastStartedAt) {
      tAgg.lastStartedAt = s.startedAt;
      tAgg.title = s.title;
      tAgg.artist = s.artist;
      tAgg.coverUrl = s.coverUrl;
      tAgg.bvid = s.bvid;
      // 本地播放的会话 durationMs=0（时长不回写 Track），只在拿到真实时长时更新，
      // 避免 0 覆盖掉先前已知时长
      if (s.durationMs > 0) {
        tAgg.durationSec = s.durationMs / 1000;
      }
    }
    // UP 聚合（头像 = 最常听曲目封面）
    gAgg.totalMs += s.ms;
    const tp: number = (gAgg.trackPlays.get(s.trackId) ?? 0) + 1;
    gAgg.trackPlays.set(s.trackId, tp);
    if (!gAgg.trackCovers.has(s.trackId)) {
      gAgg.trackCovers.set(s.trackId, s.coverUrl);
    }
    if (isValidListen(s)) {
      validPlays++;
      tAgg.plays++;
      const dayStamp: number = dayStartOf(s.startedAt);
      tAgg.days.add(dayStamp);
      listenedDays.add(dayStamp);
      gAgg.plays++;
    }
  }

  const isEmpty: boolean = validPlays === 0;

  // ── 完播率（有效收听里 completed 占比；无有效收听 = -1）──
  const completionPct: number = validPlays > 0
    ? Math.round(completedValid / validPlays * 100) : -1;

  // ── 环比：等长上一周期（「本月 1–10 号」的基准是「上月 1–10 号」——
  //    当前进行中周期按已流逝长度截齐上一周期窗，月中看进度不失真）──
  let prevFrom: number = 0;
  if (period === DiaryPeriod.Day) {
    prevFrom = range.fromMs - 86400000;
  } else if (period === DiaryPeriod.Week) {
    prevFrom = range.fromMs - 7 * 86400000;
  } else if (period === DiaryPeriod.Month) {
    const d: Date = new Date(range.fromMs);
    d.setDate(1);
    d.setMonth(d.getMonth() - 1);
    prevFrom = d.getTime();
  } else {
    const d: Date = new Date(range.fromMs);
    d.setMonth(0, 1);
    d.setFullYear(d.getFullYear() - 1);
    prevFrom = d.getTime();
  }
  const prevLen: number = isCurrent
    ? Math.max(0, Date.now() - range.fromMs)
    : (range.toMs - range.fromMs);
  let prevListenMs: number = 0;
  for (let i = 0; i < allSessions.length; i++) {
    const s: PlaySession = allSessions[i];
    if (s.startedAt >= prevFrom && s.startedAt < prevFrom + prevLen) {
      prevListenMs += s.ms;
    }
  }
  const deltaListenMs: number = totalMs - prevListenMs;

  // ── 连续听歌天数（基于全窗有效收听日，跨周期判定）──
  let longestStreakDays: number = 0;
  const daysAsc: number[] = Array.from(allValidDays);
  daysAsc.sort((a: number, b: number): number => a - b);
  let runLen: number = 0;
  for (let i = 0; i < daysAsc.length; i++) {
    runLen = (i > 0 && daysAsc[i] - daysAsc[i - 1] === 86400000) ? runLen + 1 : 1;
    if (runLen > longestStreakDays) {
      longestStreakDays = runLen;
    }
  }
  // 端点：当前周期 = 今天（今天还没听则从昨天起数，避免刚进页闪零）；往期 = 周期末日
  let streakRefDay: number;
  if (isCurrent) {
    const today: number = dayStartOf(Date.now());
    streakRefDay = allValidDays.has(today) ? today : today - 86400000;
  } else {
    streakRefDay = dayStartOf(range.toMs - 1);
  }
  let streakDays: number = 0;
  let streakCursor: number = streakRefDay;
  while (allValidDays.has(streakCursor)) {
    streakDays++;
    streakCursor -= 86400000;
  }

  // ── 保留期判定（13 个月窗；空态文案与翻页箭头依据）──
  const retentionFloor: number = getRetentionFloorMs();
  const outOfRetention: boolean = range.toMs <= retentionFloor;
  const atHistoryFloor: boolean = range.fromMs <= retentionFloor;

  // ── KPI ──
  const emptyCell: DiaryKpiCell = { value: '—', unit: '' };
  const zeroCell: DiaryKpiCell = { value: '0', unit: '' };
  // 不同歌曲 = 有效收听里去重后的 trackId 数（只听过几秒的不算）；KPI 与句式共用同一口径
  let validSongs: number = 0;
  let kpiListen: DiaryKpiCell;
  let kpiPlays: DiaryKpiCell;
  let kpiSongs: DiaryKpiCell;
  let kpiExtra: DiaryKpiCell;
  if (!listenMsKnown) {
    kpiListen = emptyCell;
    kpiPlays = emptyCell;
    kpiSongs = emptyCell;
    kpiExtra = emptyCell;
  } else if (isEmpty) {
    kpiListen = zeroCell;
    kpiPlays = zeroCell;
    kpiSongs = zeroCell;
    kpiExtra = zeroCell;
  } else {
    kpiListen = formatDiaryDuration(totalMs);
    kpiPlays = { value: formatDiaryCount(validPlays), unit: '次播放' };
    const trackAggList: TrackAgg[] = Array.from(trackAggs.values());
    for (let i = 0; i < trackAggList.length; i++) {
      if (trackAggList[i].plays > 0) {
        validSongs++;
      }
    }
    kpiSongs = { value: formatDiaryCount(validSongs), unit: '首歌曲' };
    if (period === DiaryPeriod.Day) {
      // 位 UP 主 = 有效收听涉及的 UP 数
      let validUps: number = 0;
      const upAggList: UpAgg[] = Array.from(upAggs.values());
      for (let i = 0; i < upAggList.length; i++) {
        if (upAggList[i].plays > 0) {
          validUps++;
        }
      }
      kpiExtra = { value: formatDiaryCount(validUps), unit: '位 UP 主' };
    } else {
      kpiExtra = { value: formatDiaryCount(listenedDays.size), unit: '天听歌' };
    }
  }
  if (isEmpty || !listenMsKnown) {
    // 空态单位行保留口径词，让 0/— 仍读得出「这是什么数字」
    if (period === DiaryPeriod.Day) {
      kpiExtra = { value: kpiExtra.value, unit: '位 UP 主' };
    } else {
      kpiExtra = { value: kpiExtra.value, unit: '天听歌' };
    }
    kpiPlays = { value: kpiPlays.value, unit: '次播放' };
    kpiSongs = { value: kpiSongs.value, unit: '首歌曲' };
    if (kpiListen.unit.length === 0) {
      kpiListen = { value: kpiListen.value, unit: '小时' };
    }
  }

  // ── 分桶（柱状图）──
  const bucketCount: number = period === DiaryPeriod.Day ? 24
    : (period === DiaryPeriod.Week ? 7 : (period === DiaryPeriod.Month ? 5 : 12));
  const bucketMs: number[] = [];
  for (let i = 0; i < bucketCount; i++) {
    bucketMs.push(0);
  }
  // ── 时段偏好累加桶（问候语六时段；与柱状图同一趟遍历，口径同 totalMs）──
  const segCount: number = DAY_SEGMENTS.length;
  const segMs: number[] = [];
  for (let i = 0; i < segCount; i++) {
    segMs.push(0);
  }
  for (let i = 0; i < allSessions.length; i++) {
    const s: PlaySession = allSessions[i];
    if (s.startedAt < range.fromMs || s.startedAt >= range.toMs) {
      continue;
    }
    const d: Date = new Date(s.startedAt);
    let idx: number;
    if (period === DiaryPeriod.Day) {
      idx = d.getHours();
    } else if (period === DiaryPeriod.Week) {
      idx = mondayIndex(d);
    } else if (period === DiaryPeriod.Month) {
      idx = Math.min(Math.floor((d.getDate() - 1) / 7), 4);
    } else {
      idx = d.getMonth();
    }
    bucketMs[idx] += s.ms;
    segMs[daySegmentIndexOfHour(d.getHours())] += s.ms;
  }
  let maxBucketMs: number = 0;
  let peakIdx: number = 0;
  for (let i = 0; i < bucketCount; i++) {
    if (bucketMs[i] > maxBucketMs) {
      maxBucketMs = bucketMs[i];
      peakIdx = i;
    }
  }

  // 轴标签与抽稀位
  const showIdx: number[] = period === DiaryPeriod.Day ? [0, 6, 12, 18, 23]
    : (period === DiaryPeriod.Year ? [0, 3, 6, 9, 11] : []);
  const buckets: DiaryBucket[] = [];
  for (let i = 0; i < bucketCount; i++) {
    let label: string = '';
    if (period === DiaryPeriod.Day) {
      label = `${i}`;
    } else if (period === DiaryPeriod.Week) {
      label = WEEKDAY_SHORT[i];
    } else if (period === DiaryPeriod.Month) {
      label = `第${i + 1}周`;
    } else {
      label = `${i + 1}`;
    }
    const show: boolean = showIdx.length === 0 || showIdx.indexOf(i) >= 0;
    buckets.push({ label: show ? label : '', ms: bucketMs[i] });
  }

  // 峰值提示
  let peakLabel: string = '暂无数据';
  if (maxBucketMs > 0) {
    if (period === DiaryPeriod.Day) {
      peakLabel = `${peakIdx}:00 最多`;
    } else if (period === DiaryPeriod.Week) {
      peakLabel = `${WEEKDAY_FULL[(peakIdx + 1) % 7]}最多`;
    } else if (period === DiaryPeriod.Month) {
      peakLabel = `第 ${peakIdx + 1} 周最多`;
    } else {
      peakLabel = `${peakIdx + 1} 月最多`;
    }
  }

  // 均值：只对「已开始」的桶求平均（当前周期进行到一半不虚摊未来）
  let activeBuckets: number = bucketCount;
  if (isCurrent) {
    const now: Date = new Date();
    if (period === DiaryPeriod.Day) {
      activeBuckets = now.getHours() + 1;
    } else if (period === DiaryPeriod.Week) {
      activeBuckets = mondayIndex(now) + 1;
    } else if (period === DiaryPeriod.Month) {
      activeBuckets = Math.min(Math.floor((now.getDate() - 1) / 7), 4) + 1;
    } else {
      activeBuckets = now.getMonth() + 1;
    }
  }
  const avgMs: number = activeBuckets > 0 ? totalMs / activeBuckets : 0;
  const avgWord: string = period === DiaryPeriod.Day ? '时均'
    : (period === DiaryPeriod.Week ? '日均'
      : (period === DiaryPeriod.Month ? '周均' : '月均'));
  const avgLabel: string = maxBucketMs > 0 ? `虚线 = ${avgWord} ${formatAvgValue(avgMs)}` : '';

  // ── 时段偏好派生（问候语六时段：占比、峰值提示）──
  // 占比分母 = 周期内全部会话时长和（totalMs，与「听歌时长」KPI 同源）；
  // 各段四舍五入后合计可能差 ±1pp，仅展示用不强行配平。
  let dayPeakIdx: number = -1;
  let dayPeakMs: number = 0;
  for (let i = 0; i < segCount; i++) {
    if (segMs[i] > dayPeakMs) {
      dayPeakMs = segMs[i];
      dayPeakIdx = i;
    }
  }
  const daySegments: DiaryDaySegment[] = [];
  for (let i = 0; i < segCount; i++) {
    daySegments.push({
      key: DAY_SEGMENTS[i].key,
      label: DAY_SEGMENTS[i].label,
      ms: segMs[i],
      pct: totalMs > 0 ? Math.round(segMs[i] / totalMs * 100) : 0
    });
  }
  const dayPeakSegmentLabel: string = dayPeakMs > 0
    ? `${DAY_SEGMENTS[dayPeakIdx].label}居多` : '';

  // ── 热门曲目 Top5（次数降序，同次数按时长降序；有效收听口径）──
  // 上限 5 供听歌日记 Hero 轮播 5 页；循环榜榜单取前 5（与 Hero 轮播共用 topTracks）。
  const trackList: TrackAgg[] = Array.from(trackAggs.values());
  trackList.sort((a: TrackAgg, b: TrackAgg): number => {
    if (b.plays !== a.plays) {
      return b.plays - a.plays;
    }
    return b.totalMs - a.totalMs;
  });
  const topTracks: DiaryTopTrack[] = [];
  for (let i = 0; i < trackList.length && i < 5; i++) {
    const t: TrackAgg = trackList[i];
    if (t.plays < 1) {
      break;
    }
    topTracks.push({
      trackId: t.trackId,
      title: t.title,
      artist: t.artist,
      coverUrl: t.coverUrl,
      bvid: t.bvid,
      duration: t.durationSec,
      plays: t.plays,
      totalMs: t.totalMs,
      dayCount: t.days.size
    });
  }

  // ── 标签云拉取范围（Top20 by 收听时长；有效收听、有 BV 号）──
  // 与循环榜（次数降序）口径不同：标签权重按「听得多久」聚合，拉取范围
  // 同样按收听时长排序，保证时长占比高的歌先拿到标签。
  const tagScoped: TrackAgg[] = [];
  for (let i = 0; i < trackList.length; i++) {
    const t: TrackAgg = trackList[i];
    if (t.plays >= 1 && t.bvid.length > 0) {
      tagScoped.push(t);
    }
  }
  tagScoped.sort((a: TrackAgg, b: TrackAgg): number => b.totalMs - a.totalMs);
  const tagTracks: DiaryTopTrack[] = [];
  for (let i = 0; i < tagScoped.length && i < TAG_SCOPE_LIMIT; i++) {
    const t: TrackAgg = tagScoped[i];
    tagTracks.push({
      trackId: t.trackId,
      title: t.title,
      artist: t.artist,
      coverUrl: t.coverUrl,
      bvid: t.bvid,
      duration: t.durationSec,
      plays: t.plays,
      totalMs: t.totalMs,
      dayCount: t.days.size
    });
  }

  // ── 常听 UP Top3（时长降序；至少一次有效收听）──
  const upList: UpAgg[] = Array.from(upAggs.values());
  upList.sort((a: UpAgg, b: UpAgg): number => b.totalMs - a.totalMs);
  const topUps: DiaryTopUp[] = [];
  for (let i = 0; i < upList.length && topUps.length < 3; i++) {
    if (upList[i].plays < 1) {
      continue;
    }
    topUps.push(buildTopUp(upList[i]));
  }

  // ── 新面孔：首次出现在本周期内的 UP ──
  const newFaces: UpAgg[] = [];
  for (let i = 0; i < upList.length; i++) {
    const u: UpAgg = upList[i];
    if (u.plays > 0 && u.firstSeenAt >= range.fromMs && u.firstSeenAt < range.toMs) {
      newFaces.push(u);
    }
  }
  const newFaceCount: number = newFaces.length;
  const newFaceAvatars: string[] = [];
  for (let i = 0; i < newFaces.length && i < 3; i++) {
    newFaceAvatars.push(pickAvatar(newFaces[i]));
  }
  const newFaceUps: DiaryTopUp[] = [];
  for (let i = 0; i < newFaces.length; i++) {
    newFaceUps.push(buildTopUp(newFaces[i]));
  }
  const facePrefix: string = period === DiaryPeriod.Year
    ? (isCurrent ? '今年' : `${new Date(range.fromMs).getFullYear()}年`)
    : buildSectionPrefix(period, range, isCurrent);
  const newFaceTitle: string = `${facePrefix}新面孔`;
  const newFaceSub: string = `${newFaceCount} 位 UP 主 · 近 13 个月第一次出现在你的列表`;

  // ── 一句话（五类句式各 3 条变体确定性轮换；不做 AI 生成）──
  // 种子 = 周期 + 周期起点：切周期 / 翻页自然轮换措辞；同视图重算幂等，
  // 实时刷新 reload 不换句。分类判定与优先级不变（empty→fewDays→top1→repeated→met）。
  const sentenceSeed: string = `${period}_${range.fromMs}`;
  const listenCell: DiaryKpiCell = formatDiaryDuration(totalMs);
  const sCtx: SentenceCtx = {
    emptyWord: emptyWordOf(period),
    periodWord: periodWord(period),
    fewDays: listenedDays.size,
    pct: 0,
    top1Title: topTracks.length > 0 ? topTracks[0].title : '',
    top1Plays: topTracks.length > 0 ? topTracks[0].plays : 0,
    listenText: `${listenCell.value} ${listenCell.unit}`,
    repeated: 0,
    metCount: validSongs,
    streak: streakDays,
    longestStreak: longestStreakDays
  };
  let sentence: string = '';
  if (isEmpty) {
    if (isCurrent) {
      sentence = pickSentence(V_EMPTY, sentenceSeed, sCtx);
    }
  } else if (period !== DiaryPeriod.Day && listenedDays.size <= FEW_DAYS_THRESHOLD) {
    sentence = pickSentence(V_FEW_DAYS, sentenceSeed, sCtx);
  } else if (topTracks.length > 0 && totalMs > 0
    && topTracks[0].totalMs / totalMs >= TOP1_SHARE_THRESHOLD) {
    sCtx.pct = Math.round(topTracks[0].totalMs / totalMs * 100);
    sentence = pickSentence(V_TOP1_SHARE, sentenceSeed, sCtx);
  } else if (isCurrent && streakDays >= 3) {
    // 连续听歌天数：现在时陈述只对当前周期成立；阈值 3 避免抢掉常规句式
    sentence = pickSentence(V_STREAK, sentenceSeed, sCtx);
  } else {
    let repeated: number = 0;
    for (let i = 0; i < trackList.length; i++) {
      if (trackList[i].plays >= 2) {
        repeated++;
      }
    }
    sCtx.repeated = repeated;
    if (repeated > 0) {
      sentence = pickSentence(V_REPEATED, sentenceSeed, sCtx);
    } else {
      sentence = pickSentence(V_MET, sentenceSeed, sCtx);
    }
  }

  // ── 往期空周期提示 ──
  const emptyHint: string = isEmpty && !isCurrent
    ? `${periodWord(period)}你没有听歌记录` : '';

  return {
    period,
    range,
    isCurrent,
    dateRangeLabel: buildDateRangeLabel(period, range),
    heroLabel: buildHeroLabel(period, range, isCurrent),
    sectionPrefix: buildSectionPrefix(period, range, isCurrent),
    sentence,
    emptyHint,
    isEmpty,
    listenMsKnown,
    kpiListen,
    kpiPlays,
    kpiSongs,
    kpiExtra,
    buckets,
    barWidthVp: period === DiaryPeriod.Day ? 6
      : (period === DiaryPeriod.Week || period === DiaryPeriod.Month ? 14 : 9),
    peakLabel,
    maxBucketMs,
    avgMsPerBucket: avgMs,
    avgLabel,
    daySegments,
    daySegmentsTotalMs: totalMs,
    dayPeakSegmentLabel,
    topTracks,
    tagTracks,
    topUps,
    newFaces: newFaceUps,
    newFaceTitle,
    newFaceSub,
    newFaceCount,
    newFaceAvatars,
    completionPct,
    abandonedCount,
    deltaListenMs,
    prevListenMs,
    streakDays,
    longestStreakDays,
    outOfRetention,
    atHistoryFloor
  };
}

/** UP 头像：该 UP 最常听曲目的封面（无 face 字段的兜底方案） */
function pickAvatar(u: UpAgg): string {
  let bestId: string = '';
  let bestPlays: number = -1;
  const ids: string[] = Array.from(u.trackPlays.keys());
  for (let i = 0; i < ids.length; i++) {
    const p: number = u.trackPlays.get(ids[i]) ?? 0;
    if (p > bestPlays) {
      bestPlays = p;
      bestId = ids[i];
    }
  }
  return bestId.length > 0 ? (u.trackCovers.get(bestId) ?? '') : '';
}

/** UpAgg → DiaryTopUp（头像取最常听曲目封面） */
function buildTopUp(u: UpAgg): DiaryTopUp {
  return {
    key: u.key,
    upMid: u.upMid,
    name: u.name,
    plays: u.plays,
    totalMs: u.totalMs,
    avatarUrl: pickAvatar(u)
  };
}

/** 标签云单条：标签名 + 权重（该标签下曲目的收听时长总和 ms） */
export interface DiaryTagEntry {
  name: string;
  weight: number;
}

/**
 * 标签云纯函数：tagTracks（report.tagTracks）+ bvid→标签映射 → 权重降序 Top maxTags。
 *
 * · 权重 = Σ 含该标签曲目的 totalMs ——「这段时间听得越久的标签越大」；
 * · 同权重按名称排序，保证翻页 / 切周期时 ForEach key 稳定不抖动；
 * · tagsByBvid 缺席（拉取失败 / 无 BV 号）的曲目跳过，不影响其余聚合。
 */
export function computeDiaryTagCloud(tagTracks: DiaryTopTrack[],
  tagsByBvid: Map<string, string[]>, maxTags: number): DiaryTagEntry[] {
  const weights: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < tagTracks.length; i++) {
    const t: DiaryTopTrack = tagTracks[i];
    const tags: string[] | undefined = tagsByBvid.get(t.bvid);
    if (tags === undefined) {
      continue;
    }
    for (let j = 0; j < tags.length; j++) {
      const name: string = tags[j].trim();
      if (name.length === 0) {
        continue;
      }
      weights.set(name, (weights.get(name) ?? 0) + t.totalMs);
    }
  }
  const entries: DiaryTagEntry[] = [];
  const names: string[] = Array.from(weights.keys());
  for (let i = 0; i < names.length; i++) {
    entries.push({ name: names[i], weight: weights.get(names[i]) ?? 0 });
  }
  entries.sort((a: DiaryTagEntry, b: DiaryTagEntry): number => {
    if (b.weight !== a.weight) {
      return b.weight - a.weight;
    }
    return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
  });
  const out: DiaryTagEntry[] = [];
  for (let i = 0; i < entries.length && i < maxTags; i++) {
    out.push(entries[i]);
  }
  return out;
}
