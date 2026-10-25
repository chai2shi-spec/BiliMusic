/**
 * 公共下载目录搬移器。
 *
 * 通路（官方 DOWNLOAD 模式，API 12+，工程 6.1.0(23) 可用）：
 * DocumentViewPicker.save({ pickerMode: DocumentPickerMode.DOWNLOAD }) 免选择
 * 界面直接返回 Download/包名/ 目录 URI，**已具备持久化权限**（跨重启有效）；
 * 之后经 fileUri.FileUri(uri).path 把 URI 现转绝对路径，fs 直接建/写/删文件，
 * 系统文件管理「下载/包名」立即可见。音频没有 SaveButton/媒体库通路
 * （媒体库仅图片视频），这是唯一免对话框的自动通路（AudioExporter 头注释
 * 同口径结论）。
 *
 * 单份存储（用户拍板）：搬移非拷贝 —— 拷入公共目录后删沙箱原件，
 * task.localFilePath 更新为公共路径并回写 RDB，播放/删除链路自动跟随。
 * 失败兜底：任何一步失败都保留沙箱原件、localFilePath 不动（播放与任务
 * 完整性零损伤），设置页「同步已完成歌曲」可重试。
 *
 * 命名与 AudioExporter 共用（exportBaseNameOf / exportExtOf）：
 * `歌名 - 歌手.ext`。自动搬移同名覆盖（同曲重下载 = 新版本覆盖旧）；
 * 批量同步的批内重名由调用方（DownloadManager.syncCompletedToPublicDir）
 * 传去重名（" (2)"、"(3)"…）规避，覆盖语义会静默吞歌。
 */

import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import fileUri from '@ohos.file.fileuri';
import common from '@ohos.app.ability.common';
import { AppSettings, DownloadTask, DownloadStatus } from '../model/MusicModels';
import { AppPreferences } from '../preferences/AppPreferences';
import { updateDownloadStatus } from '../database/MusicDao';
import { exportBaseNameOf, exportExtOf } from './AudioExporter';

/** 批量同步结果计数（设置页 toast 文案用） */
export interface PublicSyncResult {
  /** 参与同步的条数（已完成 + 路径仍在沙箱） */
  total: number;
  /** 搬移成功 */
  ok: number;
  /** 搬移失败（沙箱原件已保留，可重试） */
  failed: number;
}

/**
 * 确保「下载/包名」目录 URI 就绪（设置页开关打开时调用，须在用户手势内）。
 *
 * 偏好里已有 URI 且目录可达 → 直接复用（持久化授权跨重启有效）；
 * 否则走 DOWNLOAD 模式 save() 重新取 URI 并写偏好。
 * 返回空串 = 未授权 / 用户取消 / 异常，调用方不得打开开关。
 */
export async function ensureDirUri(context: common.UIAbilityContext): Promise<string> {
  const existing: string = AppPreferences.getSettings().publicDownloadsDirUri;
  if (existing.length > 0) {
    try {
      const dirPath: string = new fileUri.FileUri(existing).path ?? '';
      if (dirPath.length > 0 && await fs.access(dirPath)) {
        return existing;
      }
    } catch (e) {
      // 已存 URI 不可达（极端：授权被系统回收）—— 落到下面重新授权
      console.warn(`ensureDirUri: stored uri unreachable, re-auth: ${JSON.stringify(e)}`);
    }
  }
  try {
    const saveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    // DOWNLOAD 模式：免选择界面，直接返回 Download/包名/ 目录 URI（持久化权限）
    saveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: Array<string> = await docPicker.save(saveOptions);
    if (uris.length === 0) {
      return '';
    }
    const uri: string = uris[0];
    AppPreferences.updateSettings((s: AppSettings): void => {
      s.publicDownloadsDirUri = uri;
    });
    return uri;
  } catch (e) {
    console.error(`ensureDirUri failed: ${JSON.stringify(e)}`);
    return '';
  }
}

/**
 * 把一条已完成任务的沙箱文件搬移到「下载/包名」（单份存储）。
 *
 * 前置：AppSettings.saveToPublicDownloads 开启 + 目录 URI 就绪；任一不满足
 * 直接返回 false（DownloadManager 完成点静默跳过，不打扰）。
 * 成功 = task.localFilePath 已指向公共目录绝对路径并回写 RDB（内存 task 归
 * 调用方持有，notify 由调用方触发刷新 UI）。
 * destFileName 可选：批量同步时由调用方传批内去重后的名字；缺省按
 * `歌名 - 歌手.ext` 生成，同名覆盖（同曲重下载 = 新版本覆盖旧）。
 */
export async function moveTaskFile(task: DownloadTask, destFileName?: string): Promise<boolean> {
  const settings: AppSettings = AppPreferences.getSettings();
  if (!settings.saveToPublicDownloads || settings.publicDownloadsDirUri.length === 0) {
    return false;
  }
  if (task.status !== DownloadStatus.COMPLETED || task.localFilePath.length === 0) {
    return false;
  }
  let dirPath: string = '';
  try {
    dirPath = new fileUri.FileUri(settings.publicDownloadsDirUri).path ?? '';
  } catch (e) {
    console.error(`moveTaskFile: bad dir uri: ${JSON.stringify(e)}`);
    return false;
  }
  if (dirPath.length === 0) {
    return false;
  }
  const fileName: string = destFileName !== undefined && destFileName.length > 0
    ? destFileName
    : `${exportBaseNameOf(task)}.${exportExtOf(task)}`;
  const destPath: string = `${dirPath}/${fileName}`;
  try {
    // 拷贝覆盖（fs.copyFile mode 0）→ 删沙箱原件 → 改路径回写 RDB。
    // 拷贝成功但 unlink 失败视为整体失败：双份无害（重试会覆盖），路径不切
    // 保证播放仍指向沙箱原件，不会指向一个「可能没删干净」的双源状态。
    await fs.copyFile(task.localFilePath, destPath);
    await fs.unlink(task.localFilePath);
    task.localFilePath = destPath;
    await updateDownloadStatus(task.id, DownloadStatus.COMPLETED, destPath, task.completedAt);
    return true;
  } catch (e) {
    console.error(`moveTaskFile failed (${task.id} -> ${destPath}): ${JSON.stringify(e)}`);
    return false;
  }
}
