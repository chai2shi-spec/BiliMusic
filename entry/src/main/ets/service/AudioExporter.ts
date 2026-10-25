/**
 * 下载音频导出命名工具（仅存命名口径）。
 *
 * 背景（HarmonyOS NEXT 三方应用无法静默写公共音频目录）：媒体库
 * （photoAccessHelper）只管图片/视频，也不存在 WRITE_AUDIO 类权限；手动
 * 通路是 `@ohos.file.picker` 的 AudioViewPicker.save()，自动通路是
 * DocumentViewPicker 的 DOWNLOAD 模式（见 PublicDownloadsSaver）。
 *
 * 命名：`歌名 - 歌手.ext`（cleanTitle 清洗 + sanitizeFileName 去非法字符，
 * 批内重名由调用方追加 " (2)"、" (3)"…）；扩展名按任务实际音质档位派生
 * （30251 → flac、30216 → mp3、其余 → m4a），老任务（档位缺省）回退落盘
 * 路径的后缀。
 *
 * 本文件只保留两个命名工具（PublicDownloadsSaver 自动搬移与
 * DownloadManager.syncCompletedToPublicDir 批量同步共用）。
 */

import { DownloadTask } from '../model/MusicModels';
import { cleanTitle, sanitizeFileName, audioFileExt } from '../utils/TextUtil';

/**
 * 派生一条任务的导出扩展名
 * （PublicDownloadsSaver 自动搬移与 DownloadManager 批量同步共用同一命名口径）。
 *
 * 优先按音质档位（30251 → flac、30216 → mp3、其余 → m4a）—— 哪怕老任务的
 * 沙箱文件名是占位 .m4a，档位为 30216 时字节其实是 MP3，导出名必须是 .mp3。
 * 档位缺省（audioQuality = 0，极老任务）回退落盘路径的后缀；路径后缀也不可
 * 识别时兜底 m4a（与建任务占位名一致）。
 */
export function exportExtOf(t: DownloadTask): string {
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
export function exportBaseNameOf(t: DownloadTask): string {
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
