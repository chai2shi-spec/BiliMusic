/**
 * 本地备份编排层（歌单 + 拾音收听数据 → bilimusic-日期.json）。
 *
 * 职责边界：本文件只做「组装 / 探测 / 编排」，不碰文件系统 ——
 *  · 数据真源在两端：歌单 = LibraryStore.createPlaylistsExport（已剥
 *    localFilePath 与过期直链），收听会话 = PlaySessionStore.querySessions
 *    （13 个月保留窗内全量，升序）；
 *  · 恢复同样分两端：歌单走 LibraryStore.importPlaylistsFromParsed
 *    （重名加「导入」后缀、镜像降级、一次落盘），会话走
 *    PlaySessionStore.mergeBackupSessions（trackId|startedAt|ms 去重、
 *    沿 writeChain 串行追加、恢复后 rev 广播让拾音页免重启刷新）；
 *  · 文件读写（系统保存对话框 / 文件选择器）在页面层
 *    （PlaylistBackupPage，PlaybackLogPage 的导出链路同款范式）。
 *
 * 备份格式（version 1，单文件同时承载两段）：
 * {
 *   "app": "biliMusic",
 *   "type": "backup",
 *   "version": 1,
 *   "exportedAt": "ISO 时间戳",
 *   "playlists": [ ...createPlaylistsExport().playlists ],
 *   "sessions":  [ ...PlaySession ]
 * }
 *
 * 兼容口径：恢复入口同时接受老版剪贴板导出的纯歌单 JSON
 * （{app,type:'playlists',playlists:[...]}）—— peekBackup 只要求
 * playlists / sessions 任一为数组；纯歌单文件恢复时只走歌单段。
 */

import { LibraryStore, PlaylistImportResult, PlaylistsExport } from './LibraryStore';
import {
  getRetentionFloorMs,
  mergeBackupSessions,
  PlaySession,
  querySessions,
  SessionMergeResult
} from './PlaySessionStore';
import { Playlist } from '../model/MusicModels';

/** 备份文件顶层结构（version 1；parse 的收口类型 + buildLocalBackup 的返回类型） */
export interface BackupFile {
  app: string;
  type: string;
  version: number;
  exportedAt: string;
  playlists: Playlist[];
  sessions: PlaySession[];
}

/** 备份文件探测结果（恢复确认弹窗的计数展示用） */
export interface BackupSummary {
  /** 文件里的歌单条数（无 playlists 数组 = 0） */
  playlists: number;
  /** 文件里的收听会话条数（无 sessions 数组 = 0） */
  sessions: number;
}

/** 恢复结果回执（toast 文案拼装用） */
export interface BackupRestoreResult {
  importedPlaylists: number;
  skippedPlaylists: number;
  mergedSessions: number;
  skippedSessions: number;
}

/**
 * 组装完整备份对象（页面层 JSON.stringify 后经系统保存对话框写出）。
 *
 * 会话为全量导出：querySessions 钳在 13 个月保留窗内（更早的分片已被
 * prune，导出超窗空数据没有意义）；await writeChain 保证在途追加落定，
 * 「刚播完就备份」也不漏最后一条。
 */
export async function buildLocalBackup(): Promise<BackupFile> {
  const exportRoot: PlaylistsExport = LibraryStore.createPlaylistsExport();
  const sessions: PlaySession[] = await querySessions(getRetentionFloorMs(), Date.now());
  return {
    app: 'biliMusic',
    type: 'backup',
    version: 1,
    exportedAt: new Date().toISOString(),
    playlists: exportRoot.playlists,
    sessions: sessions
  };
}

/**
 * 探测文本是否像 BiliMusic 备份（一次 JSON.parse，恢复前的确认弹窗用）。
 *
 * 只判形状不真恢复：playlists / sessions 任一为数组即认为有效
 * （老版纯歌单导出文件也能走恢复入口）；解析失败 / 形状不符返回 null，
 * 调用方提示「不是 BiliMusic 备份文件」，别等用户点完确认才报错。
 */
export function peekBackup(text: string): BackupSummary | null {
  let parsed: BackupFile;
  try {
    parsed = JSON.parse(text) as BackupFile;
  } catch (e) {
    return null;
  }
  if (parsed === null || typeof parsed !== 'object') {
    return null;
  }
  const hasPlaylists: boolean = Array.isArray(parsed.playlists);
  const hasSessions: boolean = Array.isArray(parsed.sessions);
  if (!hasPlaylists && !hasSessions) {
    return null;
  }
  return {
    playlists: hasPlaylists ? parsed.playlists.length : 0,
    sessions: hasSessions ? parsed.sessions.length : 0
  };
}

/**
 * 执行恢复（页面层 peekBackup + 用户确认后调用，两段各走各的真源）。
 *
 * · 歌单段：playlists 为非空数组才导入（空数组走 importPlaylistsFromParsed
 *   只会得到 imported 0 / skipped 0 的无意义回执，直接跳过）；
 * · 会话段：sessions 为非空数组才合并（去重 / 保留窗过滤见
 *   mergeBackupSessions），merge 内部递增 STORE_SESSION_REV，
 *   拾音页 @Watch 自动刷新，恢复后免重启；
 * · 调用方已 peek 过形状，这里直接 parse；极端竞态（peek 后文本被改）
 *   由调用方的 try/catch 兜底。
 */
export async function restoreBackup(text: string): Promise<BackupRestoreResult> {
  const parsed: BackupFile = JSON.parse(text) as BackupFile;
  const result: BackupRestoreResult = {
    importedPlaylists: 0,
    skippedPlaylists: 0,
    mergedSessions: 0,
    skippedSessions: 0
  };
  if (Array.isArray(parsed.playlists) && parsed.playlists.length > 0) {
    const r: PlaylistImportResult = LibraryStore.importPlaylistsFromParsed(parsed);
    result.importedPlaylists = r.imported;
    result.skippedPlaylists = r.skipped;
  }
  if (Array.isArray(parsed.sessions) && parsed.sessions.length > 0) {
    const r: SessionMergeResult = await mergeBackupSessions(parsed.sessions);
    result.mergedSessions = r.merged;
    result.skippedSessions = r.skipped;
  }
  return result;
}
