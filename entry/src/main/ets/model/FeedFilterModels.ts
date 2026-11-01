/**
 * 「首页筛选」配置模型（移植自 Bilibili-Gate-TagRec 的筛选引擎数据层）。
 *
 * 纯数据模块：只放类型 / 默认值 / 质量档位 / JSON 解析消毒，
 * 不 import 任何 UI、存储、网络依赖（引擎见 utils/FeedFilterEngine.ts，
 * 存储见 service/HomeFeedFilterStore.ts）。
 *
 * 数据语义（对齐 TagRec filter-engine 的设计）：
 *   · 阈值字段 0 = 该维度关闭；
 *   · 数据源没给的字段（如推荐流缺点赞数）= miss，按「字段缺失放行」跳过，
 *     strictMode 打开后反转为「缺字段即滤」；
 *   · 屏蔽名单任一命中即滤；仅看名单非空时收窄为「只放行名单内」；
 *   · 名单/关键词支持 TagRec 的 `mid(备注)` 与 `/正则/` 书写格式（引擎解析）。
 */

import { util } from '@kit.ArkTS';

/** UP 主名单条目：mid（字符串化）+ 备注名。屏蔽/仅看名单共用。 */
export interface FeedUpEntry {
  mid: string;
  name: string;
}

/**
 * 筛选方案（TagRec combination 的简化版「标签条件」）：
 * 包含条件（关键词组，任一/全部）圈定想看的内容，排除规则任一命中即滤（绝对生效）。
 * 关键词对「标题+歌手+分区+推荐理由」拼接文本做归一化子串匹配。
 */
export interface FeedFilterScheme {
  id: string;
  name: string;
  /** 'any'（任一命中）| 'all'（全部命中） */
  includeMode: string;
  includeKeywords: string[];
  excludeKeywords: string[];
  excludeUpMids: string[];
  createdAtMs: number;
}

/** 首页筛选配置（落盘 schema，version: 1） */
export interface FeedFilterConfig {
  version: number;
  /** 总开关：false 时三 tab 直接透传 raw，不做任何过滤 */
  enabled: boolean;
  /** false：字段缺失(miss)一律放行；true：miss 一律滤除 */
  strictMode: boolean;
  /** 最少播放数，0 = 关 */
  viewMin: number;
  /** 赞率下限（0.02 = 2%），0 = 关。依赖点赞数，推荐流通道缺赞数时自动跳过 */
  likeRateMin: number;
  /** 最短时长（秒），0 = 关 */
  durationMinSec: number;
  /** 最长时长（秒），0 = 关 */
  durationMaxSec: number;
  /** 发布时间窗（天），0 = 关 */
  pubdateWithinDays: number;
  /** 屏蔽 UP 名单 */
  blockUps: FeedUpEntry[];
  /** 仅看 UP 名单（非空 = 收窄为只放行名单内） */
  allowUps: FeedUpEntry[];
  /** 屏蔽标题关键词（子串 或 /正则/） */
  blockTitleKeywords: string[];
  /** 仅看标题关键词（非空 = 收窄） */
  allowTitleKeywords: string[];
  /** 屏蔽分区名（归一化匹配） */
  blockCategories: string[];
  /** 仅看分区名（非空 = 收窄） */
  allowCategories: string[];
  schemes: FeedFilterScheme[];
  /** 当前激活方案 id，'' = 不启用任何方案 */
  activeSchemeId: string;
}

/** 质量档位（TagRec 内置预设的简化：一键设参，非独立覆盖层） */
export interface FeedFilterPresetInfo {
  name: string;
  label: string;
  desc: string;
}

/** 三档质量档位（name 落盘于用户认知，改文案不改 name） */
export const FEED_FILTER_PRESETS: FeedFilterPresetInfo[] = [
  { name: 'all', label: '全放', desc: '关闭全部阈值，只保留名单与关键词规则' },
  { name: 'taosha', label: '淘沙', desc: '播放 ≥1000 且赞率 ≥2%（缺数据的来源自动跳过）' },
  { name: 'quality', label: '只看高质量', desc: '播放 ≥1000 且赞率 ≥6%（缺数据的来源自动跳过）' }
];

/** 设置页「分区」快选的常用分区名（归一化前原文，仅 UI 快选用） */
export const COMMON_FEED_CATEGORIES: string[] =
  ['音乐', '影视', '游戏', '知识', '科技', '娱乐', '鬼畜', '舞蹈', '生活', '番剧', '国创', '时尚'];

/** 默认配置：总开关关闭、全维度关闭、名单为空 —— 透传 raw（用户主动开启后才生效） */
export function defaultFeedFilterConfig(): FeedFilterConfig {
  return {
    version: 1,
    enabled: false,
    strictMode: false,
    viewMin: 0,
    likeRateMin: 0,
    durationMinSec: 0,
    durationMaxSec: 0,
    pubdateWithinDays: 0,
    blockUps: [],
    allowUps: [],
    blockTitleKeywords: [],
    allowTitleKeywords: [],
    blockCategories: [],
    allowCategories: [],
    schemes: [],
    activeSchemeId: ''
  };
}

/** 深拷贝配置（getFeedFilterConfig 对外返回副本，防止调用方绕过 store 直改内存对象） */
export function copyFeedFilterConfig(c: FeedFilterConfig): FeedFilterConfig {
  const copyUps = (list: FeedUpEntry[]): FeedUpEntry[] => {
    const out: FeedUpEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push({ mid: list[i].mid, name: list[i].name });
    }
    return out;
  };
  const copyStr = (list: string[]): string[] => {
    const out: string[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push(list[i]);
    }
    return out;
  };
  const copySchemes = (list: FeedFilterScheme[]): FeedFilterScheme[] => {
    const out: FeedFilterScheme[] = [];
    for (let i = 0; i < list.length; i++) {
      const s: FeedFilterScheme = list[i];
      out.push({
        id: s.id,
        name: s.name,
        includeMode: s.includeMode,
        includeKeywords: copyStr(s.includeKeywords),
        excludeKeywords: copyStr(s.excludeKeywords),
        excludeUpMids: copyStr(s.excludeUpMids),
        createdAtMs: s.createdAtMs
      });
    }
    return out;
  };
  return {
    version: 1,
    enabled: c.enabled,
    strictMode: c.strictMode,
    viewMin: c.viewMin,
    likeRateMin: c.likeRateMin,
    durationMinSec: c.durationMinSec,
    durationMaxSec: c.durationMaxSec,
    pubdateWithinDays: c.pubdateWithinDays,
    blockUps: copyUps(c.blockUps),
    allowUps: copyUps(c.allowUps),
    blockTitleKeywords: copyStr(c.blockTitleKeywords),
    allowTitleKeywords: copyStr(c.allowTitleKeywords),
    blockCategories: copyStr(c.blockCategories),
    allowCategories: copyStr(c.allowCategories),
    schemes: copySchemes(c.schemes),
    activeSchemeId: c.activeSchemeId
  };
}

/**
 * 应用质量档位（在副本上操作，不动入参）：
 * 一次性覆写五个阈值字段 —— 档位是「设参快捷方式」，非独立覆盖层，
 * 用户可在档位基础上继续微调（对 TagRec preset 快照机制的简化）。
 */
export function applyFeedFilterPreset(c: FeedFilterConfig, presetName: string): FeedFilterConfig {
  const next: FeedFilterConfig = copyFeedFilterConfig(c);
  if (presetName === 'taosha') {
    next.viewMin = 1000;
    next.likeRateMin = 0.02;
    next.durationMinSec = 0;
    next.durationMaxSec = 0;
    next.pubdateWithinDays = 0;
  } else if (presetName === 'quality') {
    next.viewMin = 1000;
    next.likeRateMin = 0.06;
    next.durationMinSec = 0;
    next.durationMaxSec = 0;
    next.pubdateWithinDays = 0;
  } else {
    // 'all' 全放：阈值全关
    next.viewMin = 0;
    next.likeRateMin = 0;
    next.durationMinSec = 0;
    next.durationMaxSec = 0;
    next.pubdateWithinDays = 0;
  }
  return next;
}

/** 档位反查（阈值与某档完全一致才认；用于设置页回显选中态，都不一致返回 ''） */
export function matchFeedFilterPreset(c: FeedFilterConfig): string {
  if (c.viewMin === 0 && c.likeRateMin === 0) {
    return 'all';
  }
  if (c.viewMin === 1000 && c.likeRateMin === 0.02) {
    return 'taosha';
  }
  if (c.viewMin === 1000 && c.likeRateMin === 0.06) {
    return 'quality';
  }
  return '';
}

/** 新建筛选方案（id 由 util.generateRandomUUID 生成） */
export function createFeedFilterScheme(name: string): FeedFilterScheme {
  return {
    id: util.generateRandomUUID(true),
    name: name,
    includeMode: 'any',
    includeKeywords: [],
    excludeKeywords: [],
    excludeUpMids: [],
    createdAtMs: Date.now()
  };
}

// ── JSON 解析消毒（照 IntroSkipStore / HomeFeedCacheStore 的解析纪律：
//    逐字段 typeof 校验，畸形字段回退默认值，整体异常回退默认配置）──

function asFiniteNumber(v: Object | undefined, fallback: number): number {
  if (v !== undefined && typeof v === 'number' && Number.isFinite(v) && v >= 0) {
    return v;
  }
  return fallback;
}

function asBool(v: Object | undefined, fallback: boolean): boolean {
  if (v !== undefined && typeof v === 'boolean') {
    return v;
  }
  return fallback;
}

function asStringArray(raw: Object | undefined): string[] {
  if (raw === undefined || !Array.isArray(raw)) {
    return [];
  }
  const arr: string[] = raw as string[];
  const out: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    const el: string = arr[i];
    if (typeof el === 'string' && el.length > 0) {
      out.push(el);
    }
  }
  return out;
}

function asUpEntries(raw: Object | undefined): FeedUpEntry[] {
  if (raw === undefined || !Array.isArray(raw)) {
    return [];
  }
  const arr: FeedUpEntry[] = raw as FeedUpEntry[];
  const out: FeedUpEntry[] = [];
  for (let i = 0; i < arr.length; i++) {
    const el: FeedUpEntry = arr[i];
    if (el && typeof el.mid === 'string' && el.mid.length > 0) {
      out.push({ mid: el.mid, name: typeof el.name === 'string' ? el.name : '' });
    }
  }
  return out;
}

function asSchemes(raw: Object | undefined): FeedFilterScheme[] {
  if (raw === undefined || !Array.isArray(raw)) {
    return [];
  }
  const arr: FeedFilterScheme[] = raw as FeedFilterScheme[];
  const out: FeedFilterScheme[] = [];
  for (let i = 0; i < arr.length; i++) {
    const el: FeedFilterScheme = arr[i];
    if (!el || typeof el.id !== 'string' || el.id.length === 0) {
      continue;
    }
    out.push({
      id: el.id,
      name: typeof el.name === 'string' ? el.name : '',
      includeMode: el.includeMode === 'all' ? 'all' : 'any',
      includeKeywords: asStringArray(el.includeKeywords),
      excludeKeywords: asStringArray(el.excludeKeywords),
      excludeUpMids: asStringArray(el.excludeUpMids),
      createdAtMs: asFiniteNumber(el.createdAtMs, 0)
    });
  }
  return out;
}

/**
 * 解析落盘 JSON 为配置。任何一步异常（文件损坏 / 字段畸形 / 版本不认识）
 * 都整体回退默认配置 —— 筛选规则坏掉最多「回到未筛选」，绝不把脏数据甩进 UI。
 */
export function parseFeedFilterConfig(raw: string): FeedFilterConfig {
  const fallback: FeedFilterConfig = defaultFeedFilterConfig();
  if (raw.length === 0) {
    return fallback;
  }
  try {
    const parsed: FeedFilterConfig = JSON.parse(raw) as FeedFilterConfig;
    if (!parsed || typeof parsed !== 'object') {
      return fallback;
    }
    return {
      version: 1,
      enabled: asBool(parsed.enabled, fallback.enabled),
      strictMode: asBool(parsed.strictMode, fallback.strictMode),
      viewMin: asFiniteNumber(parsed.viewMin, 0),
      likeRateMin: asFiniteNumber(parsed.likeRateMin, 0),
      durationMinSec: asFiniteNumber(parsed.durationMinSec, 0),
      durationMaxSec: asFiniteNumber(parsed.durationMaxSec, 0),
      pubdateWithinDays: asFiniteNumber(parsed.pubdateWithinDays, 0),
      blockUps: asUpEntries(parsed.blockUps),
      allowUps: asUpEntries(parsed.allowUps),
      blockTitleKeywords: asStringArray(parsed.blockTitleKeywords),
      allowTitleKeywords: asStringArray(parsed.allowTitleKeywords),
      blockCategories: asStringArray(parsed.blockCategories),
      allowCategories: asStringArray(parsed.allowCategories),
      schemes: asSchemes(parsed.schemes),
      activeSchemeId: typeof parsed.activeSchemeId === 'string' ? parsed.activeSchemeId : ''
    };
  } catch (e) {
    console.error(`parseFeedFilterConfig failed: ${JSON.stringify(e)}`);
    return fallback;
  }
}
