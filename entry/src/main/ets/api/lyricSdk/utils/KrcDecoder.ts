/**
 * 酷狗 KRC 歌词解密器。
 *
 * 移植自 lx-music-mobile `src/utils/musicSdk/kg/util.js` 的 `decodeLyric`。
 * 数据流程：Base64 字符串 → 字节 → 跳过头 4 字节 → 16 字节固定 key 异或
 * → 标准 zlib inflate → UTF-8 文本。
 *
 * key 来源：lx-music-desktop#296（酷狗客户端逆向），不可修改。
 */

import { base64Decode, inflateBytes, utf8Decode } from './LxByteUtils';

/** KRC 异或 key（16 字节，逐字节循环使用） */
const KRC_KEY: Uint8Array = new Uint8Array([
  0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47,
  0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69
]);

/**
 * 解密 KRC 歌词。
 * @param base64Data 酷狗 download 接口返回的 content 字段（Base64）
 * @returns 解密后的 KRC 文本；任何失败返回空字符串（不抛错）
 */
export function decodeKrc(base64Data: string): string {
  if (!base64Data || base64Data.length === 0) {
    return '';
  }
  try {
    const raw: Uint8Array = base64Decode(base64Data);
    if (raw.length <= 4) {
      return '';
    }
    const body: Uint8Array = raw.subarray(4);
    for (let i = 0; i < body.length; i++) {
      body[i] = body[i] ^ KRC_KEY[i % 16];
    }
    const inflated: Uint8Array = inflateBytes(body);
    return utf8Decode(inflated);
  } catch (e) {
    return '';
  }
}
