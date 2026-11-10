/**
 * 公共下载目录扫描器（**纯只读**：不写 RDB、不 unlink、不覆盖音频、不写公共目录）。
 *
 * 卸载重装后 download_task 表随沙箱消失，但「下载/BiliMusic」里的音频还在。
 * 本模块负责把它们列出来并按可信度分五类，交给预览页让用户勾选；
 * 真正的写库在 DownloadRestoreManager.commit() 里，且必须用户二次确认。
 *
 * 身份还原优先级（2026-11-09：**本机数据优先，联网只做兜底**）：
 *   ① 随行 sidecar（`*.bm.json`，DownloadIndex）—— 精确，含 bvid#cid；
 *   ② 已下载的歌曲 / 本机曲库（现有 download_task、歌单、最近播放、收藏）
 *      —— 离线，Track.id 就是 musicId 口径，能补回 cid；
 *   ③ 拾音（听歌会话日志）—— 离线，有 bvid / 封面，但无 cid；
 *   ④ 以上都失败才联网按标题搜索 —— 最慢、会被风控、且会把歌名换成视频标题；
 *   ⑤ 仍搜不到 → 「身份未知」记录，仍可离线播放，但默认不勾选、可手改。
 *
 * ②③ 由 DownloadRestoreLocalMatcher + 本文件的 applyLocalMatches() 完成，
 * 命中后不进联网队列（Manager 的 pending 只挑 UNRECOGNIZED + NONE）。
 *
 * ⚠️ 本文件绝不存任何绝对路径到索引；RestoreItem.audioPath 是**本次重新授权**
 * 拿到的 dirPath 现拼出来的，重装后 URI 漂移也不会误判「文件丢失」。
 */

import fs from '@ohos.file.fs';
import { DownloadTask, DownloadStatus, SearchResultItem } from '../model/MusicModels';
import {
  DownloadIndexEntry,
  DownloadIndexFile,
  INDEX_SUFFIX,
  baseNameOf,
  extOf,
  numOrZero,
  readAllIndexes,
  readIndex,
  strOrEmpty
} from './DownloadIndex';
import { isValidAudioFile } from './DownloadManager';
import { SearchResponse, searchVideo, searchVideoByHtml } from '../api/BilibiliApi';
import {
  LocalIdentity,
  LocalIdentityIndex,
  LocalIdentityOrigin,
  LocalMatchResult,
  buildLocalIdentityIndex,
  findLocalMatch,
  identitySimilarity,
  normalizeIdentity
} from './DownloadRestoreLocalMatcher';

/** 预览清单的归类（决定默认勾选与是否能写库） */
export enum RestoreCategory {
  /** sidecar 精确还原 */
  EXACT = 'exact',
  /** 本机数据补全：已下载记录 / 曲库 / 拾音（联网之前） */
  LOCAL_MATCH = 'local',
  /** 联网按标题补全 */
  SEARCHED = 'searched',
  /** 搜不到 / 低分待人工指定（按用户口径仍可写成身份未知记录） */
  UNRECOGNIZED = 'unrecognized',
  /** 与现有 download_task 记录重复 */
  DUPLICATE = 'duplicate',
  /** 空文件 / 魔数不对 */
  CORRUPT = 'corrupt'
}

export enum RestoreSource {
  INDEX = 'index',
  /** 现有 download_task / 歌单 / 最近播放 / 收藏 */
  LIBRARY = 'library',
  /** 拾音（听歌会话日志） */
  SESSION = 'session',
  SEARCH = 'search',
  MANUAL = 'manual',
  NONE = 'none'
}

/** 本地匹配回执（页面顶部展示优先级生效情况） */
export interface LocalMatchStat {
  /** 本机数据命中总数 */
  matched: number;
  /** 其中来自已下载记录 / 曲库的条数 */
  fromLibrary: number;
  /** 其中来自拾音的条数 */
  fromSession: number;
  /** 本地候选总数（诊断用：0 说明本机确实没有可用身份） */
  candidateCount: number;
}

export interface RestoreItem {
  /** 稳定 key = audioPath */
  id: string;
  audioPath: string;
  fileName: string;
  sizeBytes: number;
  ext: string;
  category: RestoreCategory;
  source: RestoreSource;
  checked: boolean;
  musicId: string;
  bvid: string;
  cid: string;
  title: string;
  artist: string;
  coverUrl: string;
  audioQuality: number;
  duration: number;
  playlistId: string;
  playlistName: string;
  collectionTitle: string;
  partNo: number;
  partTotal: number;
  completedAt: number;
  /** 分类原因 / 限制说明（预览里直接展示） */
  reason: string;
  /** 搜索 Top1 分数不足 → 默认不勾选，但保留候选供人工改选 */
  weakMatch: boolean;
  candidates: SearchResultItem[];
}

export interface FileNameParts {
  title: string;
  artist: string;
  ext: string;
  /** 批内重名序号 " (2)" → 2；无后缀为 0 */
  dedupSeq: number;
}

export interface RestoreCancelToken {
  cancelled: boolean;
}

/** 一次搜索补全的结果（Manager 据此决定是否进入风控退避） */
export interface SearchOutcome {
  /** 是否命中风控（412/429/-352） */
  risk: boolean;
  /** 失败原因文案（非风控失败也会给，供 reason 展示） */
  reason: string;
}

/** 打分阈值：低于它算弱匹配，默认不勾选但可手动改选 */
const STRONG_MATCH_SCORE: number = 0.6;
/** 改名兜底的标题相似度门槛（比联网匹配更严，避免张冠李戴） */
const RENAME_MATCH_SCORE: number = 0.82;
/** 单次搜索保留的候选数（人工改选用） */
const MAX_CANDIDATES: number = 6;

/** B 站 duration 形如 "3:25" / "12:03:01" / "235"，统一换算成秒 */
function parseDuration(raw: string): number {
  if (raw.length === 0) {
    return 0;
  }
  const seg: string[] = raw.split(':');
  let total: number = 0;
  for (let i = 0; i < seg.length; i++) {
    const n: number = Number.parseInt(seg[i], 10);
    if (!Number.isFinite(n)) {
      return 0;
    }
    total = total * 60 + n;
  }
  return total;
}

/** 封面地址统一补协议（搜索结果常给 //i0.hdslb.com/... ） */
function toCoverUrl(pic: string): string {
  if (pic.length === 0) {
    return '';
  }
  return pic.indexOf('//') === 0 ? `https:${pic}` : pic;
}

/**
 * 拆公共目录文件名 `歌名 - 歌手.ext` / `歌名 - 歌手 (2).ext`。
 * 用**最后一个** ` - ` 分割（歌名里也可能有 ` - `）；没有分隔符时整段当歌名。
 */
export function parseFileName(fileName: string): FileNameParts {
  const ext: string = extOf(fileName);
  let base: string = fileName;
  if (ext.length > 0 && fileName.length > ext.length + 1) {
    base = fileName.substring(0, fileName.length - ext.length - 1);
  }
  let dedupSeq: number = 0;
  // 尾部 " (2)" / "(3)"
  const tail: number = base.lastIndexOf('(');
  if (tail > 0 && base.substring(base.length - 1) === ')') {
    const inner: string = base.substring(tail + 1, base.length - 1).trim();
    const n: number = Number.parseInt(inner, 10);
    if (Number.isFinite(n) && n > 1 && base.substring(tail - 1, tail) === ' ') {
      dedupSeq = n;
      base = base.substring(0, tail).trim();
    }
  }
  const sep: number = base.lastIndexOf(' - ');
  if (sep > 0) {
    return {
      title: base.substring(0, sep).trim(),
      artist: base.substring(sep + 3).trim(),
      ext: ext,
      dedupSeq: dedupSeq
    };
  }
  return { title: base.trim(), artist: '', ext: ext, dedupSeq: dedupSeq };
}

/** 列目录里的音频绝对路径（同步枚举；扩展名白名单，sidecar 天然被排除） */
export function listAudioFiles(dirPath: string): string[] {
  const out: string[] = [];
  let names: string[] = [];
  try {
    names = fs.listFileSync(dirPath);
  } catch (e) {
    return out;
  }
  names.sort();
  for (let i = 0; i < names.length; i++) {
    const nm: string = names[i];
    if (nm.length <= INDEX_SUFFIX.length
      || nm.substring(nm.length - INDEX_SUFFIX.length) === INDEX_SUFFIX) {
      continue;
    }
    const ext: string = extOf(nm).toLowerCase();
    if (ext === 'm4a' || ext === 'mp3' || ext === 'flac') {
      out.push(`${dirPath}/${nm}`);
    }
  }
  return out;
}

/** 稳定哈希（djb2）—— 身份未知文件的 musicId 要在多次扫描间保持一致 */
function stableHash(s: string): string {
  let h: number = 5381;
  for (let i = 0; i < s.length; i++) {
    h = ((h * 33) ^ s.charCodeAt(i)) & 0x7fffffff;
  }
  return h.toString(36);
}

function localMusicIdOf(fileName: string): string {
  return `local_${stableHash(fileName)}`;
}

/** 由索引条目生成一条「精确还原」的 RestoreItem 字段 */
function fillFromIndex(item: RestoreItem, e: DownloadIndexEntry, reason: string): void {
  item.category = RestoreCategory.EXACT;
  item.source = RestoreSource.INDEX;
  item.checked = true;
  item.musicId = e.musicId;
  item.bvid = e.bvid;
  item.cid = e.cid;
  item.title = e.title;
  item.artist = e.artist;
  item.coverUrl = e.coverUrl;
  item.audioQuality = numOrZero(e.audioQuality);
  item.duration = numOrZero(e.duration);
  item.playlistId = strOrEmpty(e.playlistId);
  item.playlistName = strOrEmpty(e.playlistName);
  item.collectionTitle = strOrEmpty(e.collectionTitle);
  item.partNo = numOrZero(e.partNo);
  item.partTotal = numOrZero(e.partTotal);
  item.completedAt = numOrZero(e.completedAt) > 0 ? numOrZero(e.completedAt) : Date.now();
  item.reason = reason;
  item.weakMatch = false;
}

/**
 * 由本机身份回填 RestoreItem（sidecar 之后、联网之前）。
 * ⚠️ 标题/歌手**沿用文件名解析结果**：本机记录里的 title 常是 B 站视频标题
 * （「【官方MV】…」），写回去会让下载列表里的歌名跟音频文件名对不上。
 * 这里只补 bvid/cid/封面/时长等身份字段。
 */
function fillFromLocal(item: RestoreItem, e: LocalIdentity): void {
  item.category = RestoreCategory.LOCAL_MATCH;
  item.source = e.origin === LocalIdentityOrigin.SESSION
    ? RestoreSource.SESSION : RestoreSource.LIBRARY;
  item.checked = true;
  item.musicId = e.musicId;
  item.bvid = e.bvid;
  item.cid = e.cid;
  if (e.coverUrl.length > 0) {
    item.coverUrl = e.coverUrl;
  }
  item.duration = e.duration;
  item.audioQuality = e.audioQuality;
  item.collectionTitle = e.collectionTitle;
  item.partNo = e.partNo;
  item.partTotal = e.partTotal;
  if (e.completedAt > 0) {
    item.completedAt = e.completedAt;
  }
  item.weakMatch = false;
  const from: string = e.origin === LocalIdentityOrigin.SESSION ? '拾音记录'
    : (e.origin === LocalIdentityOrigin.DOWNLOAD ? '已下载记录' : '本机曲库');
  const cidNote: string = e.cid.length > 0 ? '，含 cid' : '，无 cid';
  item.reason = `${from}还原身份${cidNote}；歌名沿用文件名`;
}

/**
 * 阶段 A 的离线补全：对「无索引且未被认领」的文件，先查已下载/曲库，再查拾音。
 * 命中者不进联网队列；同一 musicId / 同一归一化标题只认领一次，避免
 * 25 个文件全被同一首热门歌吃掉。
 */
export async function applyLocalMatches(
  items: RestoreItem[],
  existing: DownloadTask[]
): Promise<LocalMatchStat> {
  const stat: LocalMatchStat = {
    matched: 0, fromLibrary: 0, fromSession: 0, candidateCount: 0
  };
  const index: LocalIdentityIndex = await buildLocalIdentityIndex(existing);
  stat.candidateCount = index.all.length;
  if (index.all.length === 0) {
    return stat;
  }
  const claimedIds: Set<string> = new Set<string>();
  const claimedTitles: Set<string> = new Set<string>();
  // sidecar / 改名兜底已经认领过的身份先占位，别让离线层重复指给别的文件
  for (let i = 0; i < items.length; i++) {
    if (items[i].category === RestoreCategory.EXACT) {
      claimedIds.add(items[i].musicId);
      claimedTitles.add(normalizeIdentity(items[i].title));
    }
  }
  for (let i = 0; i < items.length; i++) {
    const item: RestoreItem = items[i];
    if (item.category !== RestoreCategory.UNRECOGNIZED || item.source !== RestoreSource.NONE) {
      continue;
    }
    const parts: FileNameParts = parseFileName(item.fileName);
    const hit: LocalMatchResult | null = findLocalMatch(
      index, parts.title, parts.artist, claimedIds, claimedTitles);
    if (hit === null) {
      continue;
    }
    fillFromLocal(item, hit.identity);
    claimedIds.add(hit.identity.musicId);
    claimedTitles.add(hit.titleKey);
    stat.matched++;
    if (hit.identity.origin === LocalIdentityOrigin.SESSION) {
      stat.fromSession++;
    } else {
      stat.fromLibrary++;
    }
  }
  return stat;
}

/** 空壳 RestoreItem（未识别态：身份未知，默认不勾选，可手动指定） */
function newItem(audioPath: string, sizeBytes: number): RestoreItem {
  const fileName: string = baseNameOf(audioPath);
  const parts: FileNameParts = parseFileName(fileName);
  return {
    id: audioPath,
    audioPath: audioPath,
    fileName: fileName,
    sizeBytes: sizeBytes,
    ext: parts.ext,
    category: RestoreCategory.UNRECOGNIZED,
    source: RestoreSource.NONE,
    checked: false,
    musicId: localMusicIdOf(fileName),
    bvid: '',
    cid: '',
    title: parts.title.length > 0 ? parts.title : fileName,
    artist: parts.artist,
    coverUrl: '',
    audioQuality: 0,
    duration: 0,
    playlistId: '',
    playlistName: '',
    collectionTitle: '',
    partNo: 0,
    partTotal: 0,
    completedAt: Date.now(),
    reason: '',
    weakMatch: false,
    candidates: []
  };
}

/**
 * 阶段 A：只读扫描 + 分类。
 *
 * 联网补全**不在这里做**（由 Manager 串行限频编排），所以本函数可以在
 * 用户点「扫描」后快速给出清单；即使断网也能看到文件列表。
 */
export async function scanPublicDir(
  dirPath: string,
  existing: DownloadTask[],
  token: RestoreCancelToken,
  onProgress: (done: number, total: number, hint: string) => void
): Promise<RestoreItem[]> {
  const audioPaths: string[] = listAudioFiles(dirPath);
  const items: RestoreItem[] = [];
  if (audioPaths.length === 0) {
    return items;
  }

  const existingPaths: Set<string> = new Set<string>();
  const existingMusicIds: Set<string> = new Set<string>();
  for (let i = 0; i < existing.length; i++) {
    if (existing[i].localFilePath.length > 0) {
      existingPaths.add(existing[i].localFilePath);
    }
    if (existing[i].musicId.length > 0) {
      existingMusicIds.add(existing[i].musicId);
    }
  }

  // 改名兜底素材：目录里全部 sidecar + 现存音频 basename
  const sidecars: Map<string, DownloadIndexEntry> = readAllIndexes(dirPath);
  const audioNames: Set<string> = new Set<string>();
  for (let i = 0; i < audioPaths.length; i++) {
    audioNames.add(baseNameOf(audioPaths[i]));
  }
  const claimedMusicIds: Set<string> = new Set<string>();

  for (let i = 0; i < audioPaths.length; i++) {
    if (token.cancelled) {
      break;
    }
    const path: string = audioPaths[i];
    let size: number = 0;
    try {
      size = (await fs.stat(path)).size;
    } catch (e) {
      size = 0;
    }
    const item: RestoreItem = newItem(path, size);
    const valid: boolean = await isValidAudioFile(path);

    if (!valid) {
      item.category = RestoreCategory.CORRUPT;
      item.reason = '文件过小或不是有效音频（可能被截断/被下载成错误页）';
      item.checked = false;
    } else if (existingPaths.has(path)) {
      item.category = RestoreCategory.DUPLICATE;
      item.reason = '这条下载记录已存在，跳过避免重复';
      item.checked = false;
    } else {
      const idx: DownloadIndexFile | null = readIndex(path);
      if (idx !== null) {
        fillFromIndex(item, idx.entry, '随行索引精确还原，含 bvid/cid');
        claimedMusicIds.add(item.musicId);
      } else {
        // 改名兜底：索引的 fileName 对应音频已不在，但标题/歌手高度吻合。
        // 先把孤儿索引收进数组，再用普通 for 选最高分（不在闭包里改状态）。
        const orphans: DownloadIndexEntry[] = [];
        sidecars.forEach((e: DownloadIndexEntry, key: string): void => {
          if (!audioNames.has(key) && !claimedMusicIds.has(e.musicId)
            && !existingMusicIds.has(e.musicId)) {
            orphans.push(e);
          }
        });
        const parts: FileNameParts = parseFileName(item.fileName);
        let best: DownloadIndexEntry | null = null;
        let bestScore: number = 0;
        for (let k = 0; k < orphans.length; k++) {
          const e: DownloadIndexEntry = orphans[k];
          const titleScore: number = identitySimilarity(e.title, parts.title);
          const artistScore: number = parts.artist.length > 0
            ? identitySimilarity(e.artist, parts.artist) : 0.5;
          const score: number = titleScore * 0.8 + artistScore * 0.2;
          if (titleScore >= RENAME_MATCH_SCORE && artistScore >= 0.5 && score > bestScore) {
            best = e;
            bestScore = score;
          }
        }
        if (best !== null) {
          const claimedEntry: DownloadIndexEntry = best;
          fillFromIndex(item, claimedEntry, '索引文件名与音频不同，按标题认领（音频可能被改名）');
          claimedMusicIds.add(item.musicId);
        } else {
          item.reason = '没有随行索引，待本机记录 / 拾音 / 联网按优先级补全';
        }
      }
    }
    items.push(item);
    onProgress(i + 1, audioPaths.length, item.fileName);
  }
  return items;
}

/** 候选打分：标题为主，歌手为辅 */
function scoreCandidate(parts: FileNameParts, c: SearchResultItem): number {
  const titleScore: number = identitySimilarity(parts.title, c.title);
  let artistScore: number = 0;
  if (parts.artist.length > 0 && c.author.length > 0) {
    artistScore = identitySimilarity(parts.artist, c.author);
  }
  return titleScore * 0.8 + artistScore * 0.2;
}

/** 把搜索候选按分数降序排好（不改动原数组元素） */
function rankedCandidates(list: SearchResultItem[], parts: FileNameParts): SearchResultItem[] {
  const scored: SearchResultItem[] = list.slice();
  scored.sort((a: SearchResultItem, b: SearchResultItem): number => {
    return scoreCandidate(parts, b) - scoreCandidate(parts, a);
  });
  return scored.length > MAX_CANDIDATES ? scored.slice(0, MAX_CANDIDATES) : scored;
}

/** 从一条搜索结果回填身份（公共文件名不含 cid，只能还原到 bvid / 首 P 语义） */
export function applyCandidate(item: RestoreItem, c: SearchResultItem, manual: boolean): void {
  item.musicId = c.bvid;
  item.bvid = c.bvid;
  item.cid = '';
  item.title = c.title.length > 0 ? c.title : item.title;
  item.artist = c.author.length > 0 ? c.author : item.artist;
  item.coverUrl = toCoverUrl(c.pic);
  item.duration = parseDuration(c.duration);
  item.category = RestoreCategory.SEARCHED;
  item.source = manual ? RestoreSource.MANUAL : RestoreSource.SEARCH;
  item.checked = true;
  item.weakMatch = false;
  item.reason = manual ? '已手动指定曲目' : '联网按标题补全（分 P 身份可能不准）';
}

/**
 * 阶段 A 的联网补全：对一条未识别文件串行搜索。
 * 失败不抛给调用方（风控通过 SearchOutcome.risk 上报），单条失败不中断整批。
 */
export async function resolveBySearch(item: RestoreItem): Promise<SearchOutcome> {
  const parts: FileNameParts = parseFileName(item.fileName);
  const keyword: string = parts.artist.length > 0
    ? `${parts.title} ${parts.artist}` : parts.title;
  let list: SearchResultItem[] = [];
  let lastReason: string = '';
  try {
    const resp: SearchResponse = await searchVideo(keyword, 1, 20);
    list = Array.isArray(resp.result) ? resp.result : [];
  } catch (e) {
    lastReason = e instanceof Error ? e.message : '搜索接口失败';
    if (isRiskMessage(lastReason)) {
      return { risk: true, reason: lastReason };
    }
    try {
      list = await searchVideoByHtml(keyword);
    } catch (e2) {
      const reason2: string = e2 instanceof Error ? e2.message : 'HTML 兜底失败';
      if (isRiskMessage(reason2)) {
        return { risk: true, reason: reason2 };
      }
      lastReason = `${lastReason}; ${reason2}`;
    }
  }
  const ranked: SearchResultItem[] = rankedCandidates(list, parts);
  item.candidates = ranked;
  if (ranked.length === 0) {
    item.category = RestoreCategory.UNRECOGNIZED;
    item.checked = false;
    item.reason = lastReason.length > 0
      ? `未找到匹配曲目（${lastReason}）；可手动指定，或勾选写成身份未知记录`
      : '未找到匹配曲目；可手动指定，或勾选写成身份未知记录';
    return { risk: false, reason: lastReason };
  }
  const best: SearchResultItem = ranked[0];
  const score: number = scoreCandidate(parts, best);
  applyCandidate(item, best, false);
  if (score < STRONG_MATCH_SCORE) {
    item.weakMatch = true;
    item.checked = false;
    item.reason = '搜索结果相似度偏低，请人工确认或从候选中改选';
  } else if (item.musicId.length > 0) {
    item.reason = '联网按标题补全（分 P 身份可能不准）';
  }
  return { risk: false, reason: '' };
}

/** 风控识别：HTTP 412/429 与业务码 -352/-412/-509/-799（与歌单导入同口径） */
export function isRiskMessage(msg: string): boolean {
  return msg.indexOf('HTTP 412') >= 0 || msg.indexOf('HTTP 429') >= 0
    || msg.indexOf('-352') >= 0 || msg.indexOf('code -412') >= 0
    || msg.indexOf('-509') >= 0 || msg.indexOf('-799') >= 0;
}

/** 由一条预览项生成可写库的 DownloadTask */
export function buildDownloadTask(item: RestoreItem, seq: number): DownloadTask {
  const now: number = Date.now();
  const at: number = item.completedAt > 0 ? item.completedAt : now;
  return {
    id: `dl_${now}_${seq}_${Math.floor(Math.random() * 1000000).toString(36)}`,
    musicId: item.musicId,
    title: item.title,
    artist: item.artist,
    coverUrl: item.coverUrl,
    url: '',
    totalBytes: item.sizeBytes,
    downloadedBytes: item.sizeBytes,
    speed: 0,
    audioQuality: item.audioQuality,
    audioBandwidth: 0,
    // ★ 必须 COMPLETED：非 COMPLETED 会被 loadFromDb 当成中断任务 unlink 掉真实音频
    status: DownloadStatus.COMPLETED,
    errorMessage: '',
    createdAt: at,
    completedAt: at,
    localFilePath: item.audioPath,
    playlistId: '',
    playlistName: '',
    collectionTitle: item.collectionTitle,
    partNo: item.partNo,
    partTotal: item.partTotal
  };
}
