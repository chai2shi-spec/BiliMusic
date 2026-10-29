/**
 * lx 歌词 SDK 的字节工具（UTF-8 / Base64 / Hex / zlib inflate）。
 *
 * 各解密器（QRC 3DES、KRC XOR、酷我 lrcx、咪咕 MRC）的公共底座。
 * inflate 走 pako（ohpm 官方源 pako@2.1.0，ESM 入口），与 lx-music 用同一实现，
 * 保证非标准 zlib 流（尾部截断等）行为一致。
 */

import { inflate, constants } from 'pako';
import util from '@ohos.util';

/** UTF-8 字节 → 字符串（替换非法序列，不抛错） */
export function utf8Decode(bytes: Uint8Array): string {
  if (bytes.length === 0) {
    return '';
  }
  const decoder: util.TextDecoder = new util.TextDecoder('utf-8');
  return decoder.decodeWithStream(bytes);
}

/** Base64 → 字节（失败返回空数组） */
export function base64Decode(text: string): Uint8Array {
  if (text.length === 0) {
    return new Uint8Array(0);
  }
  try {
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.decodeSync(text);
  } catch (e) {
    return new Uint8Array(0);
  }
}

/** 十六进制字符串 → 字节（长度为奇数 / 含非法字符时返回空数组） */
export function hexToBytes(hex: string): Uint8Array {
  if (hex.length === 0 || hex.length % 2 !== 0) {
    return new Uint8Array(0);
  }
  const out: Uint8Array = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    const v: number = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
    if (Number.isNaN(v)) {
      return new Uint8Array(0);
    }
    out[i] = v;
  }
  return out;
}

/**
 * 标准 zlib inflate（KRC / 酷我 lrcx 用）。
 * 数据损坏时抛错，由调用方决定降级路径。
 */
export function inflateBytes(data: Uint8Array): Uint8Array {
  return inflate(data);
}

/**
 * pako 运行时支持 `finishFlush`（@types/pako@2.0.0 的 InflateFunctionOptions
 * 未收录该字段）。用具名接口 + 变量传参：结构化兼容 InflateFunctionOptions，
 * 又避开对象字面量的「超额属性检查」。
 */
interface InflateTolerantOptions {
  windowBits?: number;
  raw?: boolean;
  finishFlush?: number;
}

/**
 * 宽容 inflate（QRC 用）：Z_SYNC_FLUSH 容忍尾部不完整的 zlib 流，
 * 对应 lx 原实现对 Z_BUF_ERROR 的忽略行为。
 */
export function inflateBytesTolerant(data: Uint8Array): Uint8Array {
  const options: InflateTolerantOptions = {
    finishFlush: constants.Z_SYNC_FLUSH
  };
  return inflate(data, options);
}
