/**
 * 曲目判重与智能去重（合并歌单 / 歌单内去重共用一份口径）。
 *
 * 两层判重（叠加生效）：
 *   ① 精确层：track.id 相同（同一投稿被重复加入）；
 *   ② 智能层：归一化标题 + 归一化歌手一致，且时长差 ≤ 5 秒
 *      （任一侧时长未知时凭标题 + 歌手判重）—— 抓「同一首歌、不同投稿」
 *      （不同 bvid 的搬运 / 重投），精确层对它们无效。
 *
 * 归一化实现（normalizeForMatch + MATCH_PUNCT_RE）自 PlaylistImporter 迁出：
 * 导入打分与去重必须共用同一套规则，保证「导入时能对上的两首歌」
 * 在去重时也能对上，反之亦然。
 *
 * 保留策略：每组重复保留最靠前的一首（合并 = 源歌单先后顺序拼接后的顺序，
 * 单歌单去重 = 歌单内顺序）；智能层只与「已保留」的曲目比对，
 * 被去掉的重复不作为后续判重基准。
 */

import { Track } from '../model/MusicModels';
import { decodeHtmlEntities } from './TextUtil';

/** 智能判重的时长容差（秒）：同一首歌不同投稿的时长差异上限 */
const DEDUP_DURATION_TOLERANCE_SEC: number = 5;

/**
 * 标点统一剔除。两侧（歌名 / 视频标题）必须用同一套规则，
 * 才能让 `Butter-Fly` 对上 `Butter Fly`、`secret base ~君がくれたもの~`
 * 对上 `secret base ～君がくれたもの～`。
 */
const MATCH_PUNCT_RE: RegExp =
  /[!！?？.。,，、;；:：'"“”‘’`´~～\-–—_|\\\/·•&+*=×()（）\[\]{}【】《》「」『』<>〈〉#@$%^]/g;

/** 匹配用归一化：实体解码 → 全角转半角 → 小写 → 去标点 → 去空白 */
export function normalizeForMatch(raw: string): string {
  let s: string = decodeHtmlEntities(raw);
  s = s.replace(/[\uFF01-\uFF5E]/g, (ch: string): string => {
    return String.fromCharCode(ch.charCodeAt(0) - 0xFEE0);
  });
  s = s.replace(/\u3000/g, ' ');
  s = s.toLowerCase();
  s = s.replace(MATCH_PUNCT_RE, '');
  return s.replace(/\s+/g, '');
}

/** 智能判重分组键：归一化标题|归一化歌手；标题归一化后为空 = 不参与智能判重 */
function smartKeyOf(t: Track): string {
  const title: string = normalizeForMatch(t.title);
  if (title.length === 0) {
    return '';
  }
  return `${title}|${normalizeForMatch(t.artist)}`;
}

/**
 * 时长是否判同一首：两侧时长都已知（> 0）时差值 ≤ 容差秒数；
 * 任一侧未知时凭标题 + 歌手判重（时长未知不拦，避免文本导入
 * 无时长的歌单永远去不了重）。
 */
function isDurationMatch(a: Track, b: Track): boolean {
  if (a.duration <= 0 || b.duration <= 0) {
    return true;
  }
  return Math.abs(a.duration - b.duration) <= DEDUP_DURATION_TOLERANCE_SEC;
}

/**
 * 流式判重器：按曲目到达顺序 tryKeep，重复的返回 false（调用方自行跳过）。
 * 精确层恒开（id 去重是底线）；constructor 传 smart = true 时叠加智能层。
 * 合并歌单（mergeTracksOf）与歌单内去重（dedupPlaylistTracks）共用。
 */
export class TrackDedupKeeper {
  private readonly smart: boolean;
  private readonly seenIds: Set<string> = new Set<string>();
  private readonly groups: Map<string, Track[]> = new Map<string, Track[]>();
  private exactCount: number = 0;
  private smartCount: number = 0;

  constructor(smart: boolean) {
    this.smart = smart;
  }

  /** true = 新曲目应保留；false = 与已保留曲目重复，应跳过 */
  tryKeep(t: Track): boolean {
    if (this.seenIds.has(t.id)) {
      this.exactCount += 1;
      return false;
    }
    this.seenIds.add(t.id);
    if (!this.smart) {
      return true;
    }
    const key: string = smartKeyOf(t);
    if (key.length === 0) {
      return true;
    }
    const group: Track[] | undefined = this.groups.get(key);
    if (group === undefined) {
      this.groups.set(key, [t]);
      return true;
    }
    for (let i = 0; i < group.length; i++) {
      if (isDurationMatch(group[i], t)) {
        this.smartCount += 1;
        return false;
      }
    }
    group.push(t);
    return true;
  }

  /** 同 id 精确重复的条数 */
  getExactCount(): number {
    return this.exactCount;
  }

  /** 同歌不同投稿（智能层）的重复条数 */
  getSmartCount(): number {
    return this.smartCount;
  }
}

/** 全量扫描结果：下标与分类计数供确认文案使用 */
export interface TrackDedupScan {
  /** 重复条目的下标（升序；每组保留最靠前的一首，其余在此） */
  removeIndexes: number[];
  /** 同 id 精确重复条数 */
  exactCount: number;
  /** 同歌不同投稿的智能重复条数 */
  smartCount: number;
}

/** 全量扫描一首歌单的曲目（智能层恒开；歌单内去重的确认弹窗用） */
export function scanDuplicateTracks(tracks: Track[]): TrackDedupScan {
  const keeper: TrackDedupKeeper = new TrackDedupKeeper(true);
  const removeIndexes: number[] = [];
  for (let i = 0; i < tracks.length; i++) {
    if (!keeper.tryKeep(tracks[i])) {
      removeIndexes.push(i);
    }
  }
  return {
    removeIndexes: removeIndexes,
    exactCount: keeper.getExactCount(),
    smartCount: keeper.getSmartCount()
  };
}
