/**
 * 系统剪贴板读写（薄封装）。
 *
 * 为什么用剪贴板而不是文件导入导出：
 *   · 零权限、零组件（不用 `CoreFileKit` 的 picker，也不用申请存储权限）；
 *   · 一屏就能做完（设置页一行「复制到剪贴板」+ 一行「从剪贴板导入」）；
 *   · 歌单 JSON 通常几十 KB，剪贴板完全装得下。
 * 代价是换设备要手动传一次文本 —— 需要文件时再加 `picker.save` 那条路，不冲突。
 *
 * ⚠️ `setData` / `getData` **返回 Promise**（与 `showAlertDialog` 不同，那个返回 void），
 * 必须 `.catch()`，否则剪贴板服务异常会冒泡。
 */

import { pasteboard } from '@kit.BasicServicesKit';

/** 写入纯文本；返回是否成功（失败只记日志，由调用方决定要不要提示） */
export async function copyText(text: string): Promise<boolean> {
  try {
    const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    await board.setData(data);
    return true;
  } catch (e) {
    const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
    console.error(`copyText failed: ${detail}`);
    return false;
  }
}

/**
 * 读纯文本。
 *
 * ⚠️ `SystemPasteboard.getData()` **没有带 mimeType 的重载**（只有 `getData()` /
 * `getData(callback)` / `getDataSync()`），文本要从返回的 `PasteData` 里
 * 用 `getPrimaryText()` 取 —— 传字符串给 `getData` 会命中 `AsyncCallback` 重载而编译失败。
 *
 * 剪贴板里可能是任何东西（用户刚复制了一段网页文字），所以空 / 取不到时返回空串，
 * 由调用方判断内容是不是歌单 JSON。
 */
export async function readText(): Promise<string> {
  try {
    const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
    const data: pasteboard.PasteData = await board.getData();
    const text: string = data.getPrimaryText();
    return typeof text === 'string' ? text : '';
  } catch (e) {
    const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
    console.error(`readText failed: ${detail}`);
    return '';
  }
}
