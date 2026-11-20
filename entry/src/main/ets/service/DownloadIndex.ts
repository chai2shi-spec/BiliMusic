/**
 * 公共下载目录的「随行索引」（sidecar）。
 *
 * 背景：公共目录里的音频叫 `歌名 - 歌手.ext`（AudioExporter.exportBaseNameOf），
 * **不含 bvid / cid**。而 download_task 表、播放器本地优先链、分 P 识别全靠
 * musicId（bvid 或 bvid#cid）。卸载重装后 RDB 随沙箱一起消失，光凭文件名
 * 永远拼不回曲目身份 —— 所以每次把音频搬进公共目录时，同目录写一份
 * `${音频文件名}.bm.json`，把身份信息随文件一起带走。
 *
 * 设计要点：
 *  · **一音频一索引**：重名 ` (2)`、用户改名都靠文件名天然对齐；单份损坏只影响一首；
 *    搬移时只做一次 TRUNC 写，没有「读整份 → 改 → 写回」的并发窗口。
 *  · **绝不存绝对路径**：重装后 DOWNLOAD 模式重新授权拿到的 uri.path 可能变化，
 *    存了旧路径反而会被 detectLostFiles 误判成「文件丢失」并清掉记录。
 *  · **只落文件，不进 Preferences**：单值 8192 字节上限装不下。
 *  · 写入失败**绝不阻断主流程**：音频本体 + RDB 记录才是主数据，索引只是锦上添花。
 */

import fs from '@ohos.file.fs';
import { DownloadTask } from '../model/MusicModels';

/** sidecar 后缀：完整文件名形如 `歌名 - 歌手.m4a.bm.json` */
export const INDEX_SUFFIX: string = '.bm.json';
/** 索引结构版本；读时不一致按「无索引」处理，走联网补全 */
export const INDEX_VERSION: number = 1;
export const INDEX_BUNDLE: string = 'com.chai.bilimusic';

/** 一条音频的身份信息（字段全部标类型，坏数据逐字段校验后丢弃） */
export interface DownloadIndexEntry {
  /** 关联主键：必须与音频文件 basename 完全相同才认 */
  fileName: string;
  /** bvid 或 bvid#cid —— 重建 download_task 最关键的字段 */
  musicId: string;
  bvid: string;
  cid: string;
  title: string;
  artist: string;
  coverUrl: string;
  /** 音频档位 id（30216/30251…），0 = 未知 */
  audioQuality: number;
  /** 最终落盘扩展名（flac/mp3/m4a） */
  ext: string;
  totalBytes: number;
  /** 秒；DownloadTask 没有这一列，联网补全时才拿得到 */
  duration: number;
  playlistId: string;
  playlistName: string;
  collectionTitle: string;
  partNo: number;
  partTotal: number;
  completedAt: number;
}

export interface DownloadIndexFile {
  version: number;
  bundleName: string;
  updatedAt: number;
  entry: DownloadIndexEntry;
}

/** 取路径最后一段（工程里没有 path.basename，统一自己切） */
export function baseNameOf(path: string): string {
  const slash: number = path.lastIndexOf('/');
  return slash >= 0 ? path.substring(slash + 1) : path;
}

/** 音频路径 → sidecar 路径 */
export function indexPathOf(audioPath: string): string {
  return `${audioPath}${INDEX_SUFFIX}`;
}

/** 从路径尾取扩展名（不含点，小写） */
export function extOf(path: string): string {
  const dot: number = path.lastIndexOf('.');
  return dot > 0 ? path.substring(dot + 1).toLowerCase() : '';
}

/**
 * musicId → bvid / cid。
 * 首 P 的 musicId 是纯 bvid；分 P 是 `bvid#cid`（DownloadManager.createPendingTask）。
 */
function splitMusicId(musicId: string): string[] {
  const sharp: number = musicId.indexOf('#');
  if (sharp > 0) {
    return [musicId.substring(0, sharp), musicId.substring(sharp + 1)];
  }
  return [musicId, ''];
}

/** 从一条已完成任务 + 最终落盘路径组装索引 */
export function buildIndex(audioPath: string, task: DownloadTask): DownloadIndexFile {
  const parts: string[] = splitMusicId(task.musicId);
  const entry: DownloadIndexEntry = {
    fileName: baseNameOf(audioPath),
    musicId: task.musicId,
    bvid: parts[0],
    cid: parts[1],
    title: task.title,
    artist: task.artist,
    coverUrl: task.coverUrl,
    audioQuality: task.audioQuality,
    ext: extOf(audioPath),
    totalBytes: task.totalBytes > 0 ? task.totalBytes : task.downloadedBytes,
    duration: 0,
    playlistId: task.playlistId,
    playlistName: task.playlistName,
    collectionTitle: task.collectionTitle,
    partNo: task.partNo,
    partTotal: task.partTotal,
    completedAt: task.completedAt > 0 ? task.completedAt : Date.now()
  };
  return {
    version: INDEX_VERSION,
    bundleName: INDEX_BUNDLE,
    updatedAt: Date.now(),
    entry: entry
  };
}

/** 逐字段校验，防止 JSON.parse 后的脏数据混进下载记录 */
function isValidEntry(e: DownloadIndexEntry | undefined): boolean {
  if (e === undefined || e === null || typeof e !== 'object') {
    return false;
  }
  return typeof e.fileName === 'string' && e.fileName.length > 0
    && typeof e.musicId === 'string' && e.musicId.length > 0
    && typeof e.title === 'string' && typeof e.artist === 'string'
    && typeof e.bvid === 'string' && typeof e.cid === 'string'
    && typeof e.coverUrl === 'string' && typeof e.ext === 'string';
}

/** 解析一份索引文件；版本不符 / 解析失败 / 字段缺失一律返回 null */
function parseIndexFile(path: string): DownloadIndexFile | null {
  let text: string = '';
  try {
    text = fs.readTextSync(path);
  } catch (e) {
    return null;
  }
  if (text.length === 0) {
    return null;
  }
  let parsed: DownloadIndexFile;
  try {
    parsed = JSON.parse(text) as DownloadIndexFile;
  } catch (e) {
    return null;
  }
  if (parsed === null || typeof parsed !== 'object' || parsed.version !== INDEX_VERSION) {
    return null;
  }
  if (!isValidEntry(parsed.entry)) {
    return null;
  }
  return parsed;
}

/**
 * 读一份随行索引。
 * 除了文件本身合法，还要求 `entry.fileName === 音频 basename` —— 避免 sidecar
 * 被复制/改名后张冠李戴。
 */
export function readIndex(audioPath: string): DownloadIndexFile | null {
  const parsed: DownloadIndexFile | null = parseIndexFile(indexPathOf(audioPath));
  if (parsed === null) {
    return null;
  }
  if (parsed.entry.fileName !== baseNameOf(audioPath)) {
    return null;
  }
  return parsed;
}

/**
 * 扫描目录里全部 sidecar → fileName → entry。
 * 用途：用户把音频改了名时，靠 title/artist 认领回原索引（见 DownloadRestoreScanner）。
 * 孤儿索引（对应音频已不在）只是留在 Map 里由调用方忽略，**绝不自动删**。
 */
export function readAllIndexes(dirPath: string): Map<string, DownloadIndexEntry> {
  const out: Map<string, DownloadIndexEntry> = new Map<string, DownloadIndexEntry>();
  let names: string[] = [];
  try {
    names = fs.listFileSync(dirPath);
  } catch (e) {
    return out;
  }
  for (let i = 0; i < names.length; i++) {
    const nm: string = names[i];
    if (nm.length <= INDEX_SUFFIX.length
      || nm.substring(nm.length - INDEX_SUFFIX.length) !== INDEX_SUFFIX) {
      continue;
    }
    const parsed: DownloadIndexFile | null = parseIndexFile(`${dirPath}/${nm}`);
    if (parsed !== null && !out.has(parsed.entry.fileName)) {
      out.set(parsed.entry.fileName, parsed.entry);
    }
  }
  return out;
}

/** 数字/字符串字段兜底（旧索引或人工编辑过的文件可能缺字段） */
export function numOrZero(v: number | undefined): number {
  return typeof v === 'number' && Number.isFinite(v) ? v : 0;
}

export function strOrEmpty(v: string | undefined): string {
  return typeof v === 'string' ? v : '';
}

/**
 * 写一份随行索引（TRUNC 覆盖：同曲重下覆盖音频时索引同步覆盖）。
 * 全链路 try/catch，任何失败只 warn + 返回 false，调用方不得据此判失败。
 */
export async function writeIndex(audioPath: string, task: DownloadTask): Promise<boolean> {
  const data: DownloadIndexFile = buildIndex(audioPath, task);
  let file: fs.File | null = null;
  try {
    file = await fs.open(indexPathOf(audioPath),
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    await fs.write(file.fd, JSON.stringify(data));
    return true;
  } catch (e) {
    console.warn(`[DownloadIndex] write failed: ${baseNameOf(audioPath)} ${JSON.stringify(e)}`);
    return false;
  } finally {
    if (file !== null) {
      try {
        await fs.close(file.fd);
      } catch (e) {
        // 关闭失败不影响已写入的内容
      }
    }
  }
}
