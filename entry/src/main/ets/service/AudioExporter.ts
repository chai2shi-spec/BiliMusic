/**
 * 已下载音频导出到系统文件管理（2026-10-24 下载格式正确化 + 文件管理器可见需求）。
 *
 * 背景：HarmonyOS NEXT 三方应用**无法静默写公共音频目录** —— 媒体库
 * （photoAccessHelper）只管图片/视频，也不存在 WRITE_AUDIO 类权限；官方唯一
 * 路径是 `@ohos.file.picker` 的 AudioViewPicker.save()：拉起系统保存对话框，
 * 用户确认位置后返回目标 URI 数组，应用再 `fs.copyFile` 沙箱 → 公共目录。
 * 免权限，一次对话框支持 newFileNames 批量保存整批文件。
 *
 * 导出命名：`歌名 - 歌手.ext`（cleanTitle 清洗 + sanitizeFileName 去非法字符，
 * 批内重名追加 " (2)"、" (3)"…）；扩展名按任务实际音质档位派生
 * （30251 → flac、30216 → mp3、其余 → m4a），老任务（档位缺省）回退落盘
 * 路径的后缀。文件落进用户选定目录后由系统媒体扫描收录，文件管理器可见。
 *
 * 语义约定（调用方按此 toast）：
 *   · nothingToDo —— 入参里没有「已完成且沙箱文件还在」的任务；
 *   · cancelled —— 用户在系统对话框取消（含对话框异常），静默即可；
 *   · ok/failed —— 批量复制的成败计数，单条失败不中断批次。
 */

import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import common from '@ohos.app.ability.common';
import { DownloadTask, DownloadStatus } from '../model/MusicModels';
import { cleanTitle, sanitizeFileName, audioFileExt } from '../utils/TextUtil';

export interface ExportResult {
  /** 成功复制的条数 */
  ok: number;
  /** 复制失败的条数（沙箱文件丢失 / 目标 URI 打不开等） */
  failed: number;
  /** 用户在系统对话框取消（true 时 ok/failed 恒为 0） */
  cancelled: boolean;
  /** 没有可导出条目（未完成 / 路径为空 / 沙箱文件已不存在） */
  nothingToDo: boolean;
}

/** 空结果：用户取消 */
function cancelledResult(): ExportResult {
  return { ok: 0, failed: 0, cancelled: true, nothingToDo: false };
}

/**
 * 派生一条任务的导出扩展名。
 *
 * 优先按音质档位（30251 → flac、30216 → mp3、其余 → m4a）—— 哪怕老任务的
 * 沙箱文件名是占位 .m4a，档位为 30216 时字节其实是 MP3，导出名必须是 .mp3。
 * 档位缺省（audioQuality = 0，极老任务）回退落盘路径的后缀；路径后缀也不可
 * 识别时兜底 m4a（与建任务占位名一致）。
 */
function exportExtOf(t: DownloadTask): string {
  const byQuality: string = audioFileExt(t.audioQuality, '');
  if (t.audioQuality > 0) {
    return byQuality;
  }
  const dot: number = t.localFilePath.lastIndexOf('.');
  const fromPath: string = dot > 0 ? t.localFilePath.substring(dot + 1).toLowerCase() : '';
  if (fromPath === 'flac' || fromPath === 'mp3' || fromPath === 'm4a') {
    return fromPath;
  }
  return byQuality;
}

/**
 * 导出文件名主体（不含扩展名）：`歌名 - 歌手`。
 *
 * 歌名过 cleanTitle（去「官方MV/完整版」类噪音，文件管理器里更好认）；
 * 歌手只做合法字符清洗（歌手名本身没有可去的噪音）。两者都空时退回任务
 * 标识，保证文件名非空 —— 空文件名会让系统保存对话框直接报参数错误。
 */
function exportBaseNameOf(t: DownloadTask): string {
  const title: string = sanitizeFileName(cleanTitle(t.title));
  const artist: string = sanitizeFileName(t.artist);
  if (title.length === 0 && artist.length === 0) {
    return sanitizeFileName(t.musicId.length > 0 ? t.musicId : t.id);
  }
  if (artist.length === 0) {
    return title;
  }
  if (title.length === 0) {
    return artist;
  }
  return `${title} - ${artist}`;
}

/**
 * 把一批下载任务导出到系统文件管理（入口见 DownloadsPage 的三处导出按钮）。
 *
 * @param context UIAbilityContext（AudioViewPicker 要求 UIAbility 上下文）
 * @param tasks 待导出任务（内部自动过滤「未完成 / 沙箱文件不在」的条目）
 */
export async function exportTasks(
  context: common.UIAbilityContext,
  tasks: DownloadTask[]
): Promise<ExportResult> {
  // ① 只留「已完成 + 路径非空 + 沙箱文件还在」的任务
  const exportable: DownloadTask[] = [];
  for (let i = 0; i < tasks.length; i++) {
    const t: DownloadTask = tasks[i];
    if (t.status !== DownloadStatus.COMPLETED || t.localFilePath.length === 0) {
      continue;
    }
    try {
      if (await fs.access(t.localFilePath)) {
        exportable.push(t);
      }
    } catch (e) {
      // access 异常按「文件不在」处理，交给后面的 nothingToDo 兜底
    }
  }
  if (exportable.length === 0) {
    return { ok: 0, failed: 0, cancelled: false, nothingToDo: true };
  }

  // ② 组装导出文件名：歌名 - 歌手.ext；批内重名追加 " (2)"、" (3)"…
  const usedNames: string[] = [];
  const fileNames: string[] = [];
  for (let i = 0; i < exportable.length; i++) {
    const t: DownloadTask = exportable[i];
    const ext: string = exportExtOf(t);
    const base: string = exportBaseNameOf(t);
    let candidate: string = `${base}.${ext}`;
    let seq: number = 2;
    while (usedNames.indexOf(candidate) >= 0) {
      candidate = `${base} (${seq}).${ext}`;
      seq += 1;
    }
    usedNames.push(candidate);
    fileNames.push(candidate);
  }

  // ③ 系统保存对话框（免权限）：一次对话批量保存整批
  const saveOptions: picker.AudioSaveOptions = new picker.AudioSaveOptions();
  saveOptions.newFileNames = fileNames;
  let uris: Array<string> = [];
  try {
    const audioPicker: picker.AudioViewPicker = new picker.AudioViewPicker(context);
    uris = await audioPicker.save(saveOptions);
  } catch (e) {
    // 用户取消 / 对话框异常 —— 都按取消收场，不打扰
    return cancelledResult();
  }
  if (uris.length === 0) {
    return cancelledResult();
  }

  // ④ 逐条复制：沙箱路径 → 用户确认的目标 URI；单条失败计数继续，不中断批次
  let ok: number = 0;
  let failed: number = 0;
  const count: number = Math.min(uris.length, exportable.length);
  for (let i = 0; i < count; i++) {
    const src: string = exportable[i].localFilePath;
    const destUri: string = uris[i];
    let dest: fs.File | null = null;
    try {
      dest = await fs.open(destUri, fs.OpenMode.WRITE_ONLY);
      await fs.copyFile(src, dest.fd);
      ok += 1;
    } catch (e) {
      failed += 1;
      console.error(`export copy failed (${fileNames[i]}): ${JSON.stringify(e)}`);
    } finally {
      if (dest !== null) {
        try {
          await fs.close(dest.fd);
        } catch (e) {
          // 关闭失败不影响复制结果
        }
      }
    }
  }
  return { ok: ok, failed: failed, cancelled: false, nothingToDo: false };
}
