/**
 * 酷我歌词解密器（mobi.s 二进制响应 → lrcx 文本）。
 *
 * 移植自 lx-music-mobile `src/utils/musicSdk/kw/decodeLyric.js`。
 * 数据流程：
 *   1. 响应头 10 字节必须为 `tp=content`（不区分大小写），否则不是歌词数据；
 *   2. 从首个 `\r\n\r\n`（HTTP 头/体分隔残留）之后开始标准 zlib inflate；
 *   3. lrcx=1 时：inflate 结果是 Base64 文本 → 解码 → 与 `yeelion` 逐字节循环异或；
 *   4. 最终 UTF-8 文本即 lrcx 歌词（含 `<a,b,c>` 逐字标签）。
 */

import { base64Decode, inflateBytes, utf8Decode } from './LxByteUtils';

/** 酷我 Base64 后的异或 key */
const KW_KEY: Uint8Array = new Uint8Array([
  0x79, 0x65, 0x65, 0x6c, 0x69, 0x6f, 0x6e // 'yeelion'
]);

/** 判断前 10 字节是否为 `tp=content`（不区分大小写） */
function isTpContent(buf: Uint8Array): boolean {
  const expect: string = 'tp=content';
  if (buf.length < 10) {
    return false;
  }
  for (let i = 0; i < 10; i++) {
    const ch: number = buf[i];
    const lo: number = ch >= 65 && ch <= 90 ? ch + 32 : ch;
    if (lo !== expect.charCodeAt(i)) {
      return false;
    }
  }
  return true;
}

/** 找到首个 `\r\n\r\n` 的起始下标；找不到返回 -1 */
function findHeaderEnd(buf: Uint8Array): number {
  for (let i = 0; i + 3 < buf.length; i++) {
    if (buf[i] === 13 && buf[i + 1] === 10 && buf[i + 2] === 13 && buf[i + 3] === 10) {
      return i;
    }
  }
  return -1;
}

/**
 * 解密酷我歌词二进制响应。
 * @param raw 响应原始字节（http ARRAY_BUFFER）
 * @param isGetLyricx 是否请求了 lrcx=1（true = 解 Base64 + yeelion 异或）
 * @returns lrcx / lrc 文本；任何失败返回空字符串（不抛错）
 */
export function decodeKwLyric(raw: Uint8Array, isGetLyricx: boolean): string {
  if (raw.length === 0 || !isTpContent(raw)) {
    return '';
  }
  try {
    const headerEnd: number = findHeaderEnd(raw);
    if (headerEnd < 0) {
      return '';
    }
    const inflated: Uint8Array = inflateBytes(raw.subarray(headerEnd + 4));
    if (!isGetLyricx) {
      return utf8Decode(inflated);
    }
    const b64Text: string = utf8Decode(inflated);
    const bufStr: Uint8Array = base64Decode(b64Text);
    const output: Uint8Array = new Uint8Array(bufStr.length);
    let i: number = 0;
    while (i < bufStr.length) {
      let j: number = 0;
      while (j < KW_KEY.length && i < bufStr.length) {
        output[i] = bufStr[i] ^ KW_KEY[j];
        i++;
        j++;
      }
    }
    return utf8Decode(output);
  } catch (e) {
    return '';
  }
}
