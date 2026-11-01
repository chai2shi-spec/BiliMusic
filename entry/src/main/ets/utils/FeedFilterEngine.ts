/**
 * 「首页筛选」纯函数引擎（移植自 Bilibili-Gate-TagRec）。
 *
 * 移植来源（均为纯逻辑层）：
 *   · src/modules/filter/parse.ts                     —— `mid(备注)` 解析、/正则/ 关键词分流
 *   · src/modules/tag-rec/model/tag-norm.ts           —— NFKC + 小写 + 去空白 归一化
 *   · src/modules/tag-rec/model/filter-engine.ts      —— 三态裁决（pass/fail/miss）骨架
 *
 * 评估语义（对齐 TagRec evalTagRecChain）：
 *   1. 屏蔽名单任一命中即滤（绝对生效）；
 *   2. 仅看名单非空 = 收窄域（域外即滤；字段缺失按 miss 处理）；
 *   3. 数值维度三态：字段缺失（0 / undefined）= miss，非 strictMode 放行、strictMode 滤除
 *      —— 天然适配 BiliMusic 各数据源字段完备度不一（推荐流缺点赞数、音乐中心缺 mid）；
 *   4. 激活方案的排除规则绝对生效，不被其它维度放行。
 *
 * 纯函数模块：不持有状态、不 import UI / 存储依赖；输入输出均为新建对象/数组。
 */

import { Track } from '../model/MusicModels';
import { FeedFilterConfig, FeedFilterScheme, FeedUpEntry } from '../model/FeedFilterModels';

// ── 归一化（tag-norm.ts 移植）──

/** NFKC 可用性探测标志：运行时不支持时降级为 小写+去空白（首次调用探测一次） */
let nfkcSupported: boolean = true;

/**
 * 文本归一化：NFKC → 小写 → 去全部空白。
 * B 站标题/分区名的全半角、大小写变体（「ＭＶ」vs「mv」）经此归一后同形可比。
 */
export function normalizeFilterText(s: string): string {
  let t: string = s;
  if (nfkcSupported) {
    try {
      t = s.normalize('NFKC');
    } catch (e) {
      // 运行时不支持 String.normalize：降级，后续调用不再尝试
      nfkcSupported = false;
      t = s;
    }
  }
  return t.toLowerCase().replace(/\s+/g, '');
}

// ── 名单输入解析（parse.ts 移植）──

/** `mid(备注)` 格式；不支持命名分组，用位置捕获组（ArkTS 正则兼容写法） */
const REG_UP_WITH_REMARK: RegExp = /^(\d+)\(([\S ]+)\)$/;
/** 纯数字 = mid */
const REG_PURE_MID: RegExp = /^\d+$/;

/**
 * UP 输入分流（parse.ts parseUpRepresent 移植）：
 * `123456(某UP)` → {mid, name}；`123456` → {mid, ''}；其余 → {'', name}（按用户名）。
 */
export function parseUpInputText(input: string): FeedUpEntry | null {
  const s: string = input.trim();
  if (s.length === 0) {
    return null;
  }
  const m: RegExpExecArray | null = REG_UP_WITH_REMARK.exec(s);
  if (m !== null && m.length >= 3) {
    return { mid: m[1], name: m[2] };
  }
  if (REG_PURE_MID.test(s)) {
    return { mid: s, name: '' };
  }
  return { mid: '', name: s };
}

/** 关键词列表编译产物：普通子串（已归一）+ /正则/（对原文、i 标志） */
export interface CompiledKeywordList {
  plain: string[];
  regexps: RegExp[];
}

/** 是否一个规则都没有（空列表快捷判定） */
export function keywordListEmpty(list: CompiledKeywordList): boolean {
  return list.plain.length === 0 && list.regexps.length === 0;
}

/**
 * 关键词分流编译（parse.ts parseFilterByTitle 移植）：
 * `/.../` 包裹进正则（i 标志，对原文匹配）；其余归一化后做子串匹配。
 * 非法正则降级为普通子串（用户笔误不至于让整条规则失效）。
 */
export function parseKeywordList(list: string[]): CompiledKeywordList {
  const plain: string[] = [];
  const regexps: RegExp[] = [];
  for (let i = 0; i < list.length; i++) {
    const kw: string = list[i].trim();
    if (kw.length === 0) {
      continue;
    }
    if (kw.length > 2 && kw.charAt(0) === '/' && kw.charAt(kw.length - 1) === '/') {
      const body: string = kw.substring(1, kw.length - 1);
      if (body.length > 0) {
        try {
          regexps.push(new RegExp(body, 'i'));
        } catch (e) {
          plain.push(normalizeFilterText(kw));
        }
      }
    } else {
      plain.push(normalizeFilterText(kw));
    }
  }
  return { plain: plain, regexps: regexps };
}

/** 关键词命中测试：plain 对归一化文本、regexps 对原文 */
function keywordListTest(list: CompiledKeywordList, rawText: string, normText: string): boolean {
  for (let i = 0; i < list.plain.length; i++) {
    if (normText.indexOf(list.plain[i]) >= 0) {
      return true;
    }
  }
  for (let i = 0; i < list.regexps.length; i++) {
    if (list.regexps[i].test(rawText)) {
      return true;
    }
  }
  return false;
}

// ── 编译产物 ──

/** UP 名单编译产物 */
interface UpSets {
  mids: Set<string>;
  names: Set<string>;
}

function compileUpSets(list: FeedUpEntry[]): UpSets {
  const mids: Set<string> = new Set<string>();
  const names: Set<string> = new Set<string>();
  for (let i = 0; i < list.length; i++) {
    const e: FeedUpEntry = list[i];
    if (e.mid.length > 0) {
      mids.add(e.mid);
    }
    const n: string = normalizeFilterText(e.name);
    if (n.length > 0) {
      names.add(n);
    }
  }
  return { mids: mids, names: names };
}

function compileNormSet(list: string[]): Set<string> {
  const s: Set<string> = new Set<string>();
  for (let i = 0; i < list.length; i++) {
    const n: string = normalizeFilterText(list[i]);
    if (n.length > 0) {
      s.add(n);
    }
  }
  return s;
}

/** 配置编译产物：全部 Set/正则/阈值预编译，扫表 O(n) */
export interface CompiledFeedFilter {
  /** false = 无任何生效规则，调用方可直接透传原数组 */
  active: boolean;
  strict: boolean;
  nowSec: number;
  viewMin: number;
  likeRateMin: number;
  durationMinSec: number;
  durationMaxSec: number;
  pubdateWithinDays: number;
  blockUps: UpSets;
  allowUps: UpSets;
  blockTitle: CompiledKeywordList;
  allowTitle: CompiledKeywordList;
  blockCats: Set<string>;
  allowCats: Set<string>;
  schemeActive: boolean;
  /** 'any' | 'all' */
  schemeMode: string;
  schemeInclude: string[];
  schemeExclude: CompiledKeywordList;
  schemeExcludeUpMids: Set<string>;
}

// ── 编译（带签名缓存：配置未变不重复解析）──

let cachedSignature: string = '';
let cachedCompiled: CompiledFeedFilter | null = null;

function findActiveScheme(config: FeedFilterConfig): FeedFilterScheme | null {
  if (config.activeSchemeId.length === 0) {
    return null;
  }
  for (let i = 0; i < config.schemes.length; i++) {
    if (config.schemes[i].id === config.activeSchemeId) {
      return config.schemes[i];
    }
  }
  return null;
}

/**
 * 编译配置为可扫表产物。签名缓存：同一份配置（JSON 签名一致）直接复用上次编译，
 * 规则未变时 refilter 零解析成本。nowSec 在编译时定格（发布时间窗以编译时刻算）。
 */
export function compileFeedFilter(config: FeedFilterConfig): CompiledFeedFilter {
  const signature: string = JSON.stringify(config);
  if (cachedCompiled !== null && signature === cachedSignature) {
    return cachedCompiled;
  }
  const scheme: FeedFilterScheme | null = findActiveScheme(config);
  const schemeHasRule: boolean = scheme !== null
    && (scheme.includeKeywords.length > 0 || scheme.excludeKeywords.length > 0
      || scheme.excludeUpMids.length > 0);
  const active: boolean = config.enabled && (
    config.viewMin > 0 || config.likeRateMin > 0
    || config.durationMinSec > 0 || config.durationMaxSec > 0
    || config.pubdateWithinDays > 0
    || config.blockUps.length > 0 || config.allowUps.length > 0
    || config.blockTitleKeywords.length > 0 || config.allowTitleKeywords.length > 0
    || config.blockCategories.length > 0 || config.allowCategories.length > 0
    || schemeHasRule
  );
  const compiled: CompiledFeedFilter = {
    active: active,
    strict: config.strictMode,
    nowSec: Math.floor(Date.now() / 1000),
    viewMin: config.viewMin,
    likeRateMin: config.likeRateMin,
    durationMinSec: config.durationMinSec,
    durationMaxSec: config.durationMaxSec,
    pubdateWithinDays: config.pubdateWithinDays,
    blockUps: compileUpSets(config.blockUps),
    allowUps: compileUpSets(config.allowUps),
    blockTitle: parseKeywordList(config.blockTitleKeywords),
    allowTitle: parseKeywordList(config.allowTitleKeywords),
    blockCats: compileNormSet(config.blockCategories),
    allowCats: compileNormSet(config.allowCategories),
    schemeActive: active && scheme !== null && schemeHasRule,
    schemeMode: scheme !== null ? scheme.includeMode : 'any',
    schemeInclude: scheme !== null ? parseKeywordList(scheme.includeKeywords).plain : [],
    schemeExclude: scheme !== null ? parseKeywordList(scheme.excludeKeywords) : { plain: [], regexps: [] },
    schemeExcludeUpMids: scheme !== null ? compileNormSet(scheme.excludeUpMids) : new Set<string>()
  };
  cachedSignature = signature;
  cachedCompiled = compiled;
  return compiled;
}

// ── 评估 ──

/** 单条曲目裁决：true = 保留。评估顺序见文件头注释。 */
export function evalFeedTrack(track: Track, f: CompiledFeedFilter): boolean {
  if (!f.active) {
    return true;
  }
  const strict: boolean = f.strict;

  // 1. UP 屏蔽：mid 或 归一用户名任一命中即滤
  const upMid: string = track.upMid ?? '';
  const artistNorm: string = normalizeFilterText(track.artist ?? '');
  if (upMid.length > 0 && f.blockUps.mids.has(upMid)) {
    return false;
  }
  if (artistNorm.length > 0 && f.blockUps.names.has(artistNorm)) {
    return false;
  }

  // 2. UP 仅看：名单非空 = 收窄域。mid/用户名都拿不到（音乐中心）= miss，strict 才滤
  if (f.allowUps.mids.size > 0 || f.allowUps.names.size > 0) {
    if (upMid.length > 0 || artistNorm.length > 0) {
      const hit: boolean = (upMid.length > 0 && f.allowUps.mids.has(upMid))
        || (artistNorm.length > 0 && f.allowUps.names.has(artistNorm));
      if (!hit) {
        return false;
      }
    } else if (strict) {
      return false;
    }
  }

  // 3. 标题屏蔽/仅看：plain 对归一标题、regexps 对原文
  const titleRaw: string = track.title ?? '';
  const titleNorm: string = normalizeFilterText(titleRaw);
  if (!keywordListEmpty(f.blockTitle) && keywordListTest(f.blockTitle, titleRaw, titleNorm)) {
    return false;
  }
  if (!keywordListEmpty(f.allowTitle)) {
    if (titleNorm.length === 0) {
      if (strict) {
        return false;
      }
    } else if (!keywordListTest(f.allowTitle, titleRaw, titleNorm)) {
      return false;
    }
  }

  // 4. 分区屏蔽/仅看：category 缺失（数据源没给）= miss，strict 才滤
  const catNorm: string = normalizeFilterText(track.category ?? '');
  if (f.blockCats.size > 0 && catNorm.length > 0 && f.blockCats.has(catNorm)) {
    return false;
  }
  if (f.allowCats.size > 0) {
    if (catNorm.length === 0) {
      if (strict) {
        return false;
      }
    } else if (!f.allowCats.has(catNorm)) {
      return false;
    }
  }

  // 5. 数值维度（三态：0/缺失 = miss）
  if (f.durationMinSec > 0 || f.durationMaxSec > 0) {
    const dur: number = track.duration ?? 0;
    if (dur <= 0) {
      if (strict) {
        return false;
      }
    } else {
      if (f.durationMinSec > 0 && dur < f.durationMinSec) {
        return false;
      }
      if (f.durationMaxSec > 0 && dur > f.durationMaxSec) {
        return false;
      }
    }
  }
  if (f.viewMin > 0) {
    const play: number = track.playCount ?? 0;
    if (play <= 0) {
      if (strict) {
        return false;
      }
    } else if (play < f.viewMin) {
      return false;
    }
  }
  if (f.likeRateMin > 0) {
    const like: number = track.likeCount ?? 0;
    const play: number = track.playCount ?? 0;
    // 推荐流通道拿不到赞数（likeCount=0）= miss 放行，不误滤
    if (like <= 0 || play <= 0) {
      if (strict) {
        return false;
      }
    } else if (like / play < f.likeRateMin) {
      return false;
    }
  }
  if (f.pubdateWithinDays > 0) {
    const pub: number = track.pubdate ?? 0;
    if (pub <= 0) {
      if (strict) {
        return false;
      }
    } else if (f.nowSec - pub > f.pubdateWithinDays * 86400) {
      return false;
    }
  }

  // 6. 激活方案：排除绝对生效；包含按 any/all 对「标题+歌手+分区+推荐理由」文本域求值
  if (f.schemeActive) {
    if (upMid.length > 0 && f.schemeExcludeUpMids.has(upMid)) {
      return false;
    }
    const domainRaw: string = (track.title ?? '') + ' ' + (track.artist ?? '') + ' '
      + (track.category ?? '') + ' ' + (track.rcmdReason ?? '');
    const domainNorm: string = normalizeFilterText(domainRaw);
    if (!keywordListEmpty(f.schemeExclude) && domainNorm.length > 0
      && keywordListTest(f.schemeExclude, domainRaw, domainNorm)) {
      return false;
    }
    if (f.schemeInclude.length > 0) {
      if (f.schemeMode === 'all') {
        for (let i = 0; i < f.schemeInclude.length; i++) {
          if (domainNorm.indexOf(f.schemeInclude[i]) < 0) {
            return false;
          }
        }
      } else {
        let anyHit: boolean = false;
        for (let i = 0; i < f.schemeInclude.length; i++) {
          if (domainNorm.indexOf(f.schemeInclude[i]) >= 0) {
            anyHit = true;
            break;
          }
        }
        if (!anyHit) {
          return false;
        }
      }
    }
  }
  return true;
}

/**
 * 批量过滤。不改变入参数组；compiled.active=false 时原样返回入参引用
 * （调用方约定：raw 与展示数组都只整体重新赋值，不做原地增删）。
 */
export function applyFeedFilter(tracks: Track[], f: CompiledFeedFilter): Track[] {
  if (!f.active) {
    return tracks;
  }
  const out: Track[] = [];
  for (let i = 0; i < tracks.length; i++) {
    if (evalFeedTrack(tracks[i], f)) {
      out.push(tracks[i]);
    }
  }
  return out;
}

/** 该条目的 UP 是否已在屏蔽名单（列表菜单「取消屏蔽此 UP」的态回显用） */
export function isTrackUpBlocked(track: Track, f: CompiledFeedFilter): boolean {
  const upMid: string = track.upMid ?? '';
  const artistNorm: string = normalizeFilterText(track.artist ?? '');
  return (upMid.length > 0 && f.blockUps.mids.has(upMid))
    || (artistNorm.length > 0 && f.blockUps.names.has(artistNorm));
}
