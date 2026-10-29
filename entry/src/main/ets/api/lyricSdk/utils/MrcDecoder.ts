/**
 * 咪咕 MRC 歌词解密器（BigInt XXTEA 变体）。
 *
 * 1:1 移植自 lx-music-mobile `src/utils/musicSdk/mg/utils/mrc.js`
 * （逆向自咪咕客户端，参考 lx-music-desktop#445）。
 *
 * 数据流程：hex 字符串 → 按 16 字符一组转有符号 64 位 BigInt 数组
 * → XXTEA 变体解密（DELTA=0x9E3779B9，9 组固定 key）→ 每个 long
 * 转 8 字节小端 → 按 UTF-16LE 拼回文本。
 *
 * ArkTS 适配说明：原实现用 BigInt 直接当数组下标（`data[j6 - 1n]`），
 * 这里统一转 Number（数值均远小于 2^53，无损）。
 */

const DELTA: bigint = 2654435769n;
const MIN_LENGTH: number = 32;

/** 9 组 64 位 key（不可修改） */
const KEY_ARR: bigint[] = [
  27303562373562475n,
  18014862372307051n,
  22799692160172081n,
  34058940340699235n,
  30962724186095721n,
  27303523720101991n,
  27303523720101998n,
  31244139033526382n,
  28992395054481524n
];

const MAX: bigint = 9223372036854775807n;
const MIN: bigint = -9223372036854775808n;

/** 包装到有符号 64 位范围（字符串按 hex 解析） */
function toLong(value: string | bigint): bigint {
  const num: bigint = typeof value === 'string' ? BigInt('0x' + value) : value;
  if (num > MAX) {
    return toLong(num - (1n << 64n));
  }
  if (num < MIN) {
    return toLong(num + (1n << 64n));
  }
  return num;
}

/** XXTEA 变体解密（原地） */
function teaDecrypt(data: bigint[], key: bigint[]): bigint[] {
  const length: number = data.length;
  const lengthBigint: bigint = BigInt(length);
  if (length < 1) {
    return data;
  }
  let j2: bigint = data[0];
  let j3: bigint = toLong((6n + (52n / lengthBigint)) * DELTA);
  while (true) {
    const j4: bigint = j3;
    if (j4 === 0n) {
      break;
    }
    const j5: bigint = toLong(3n & toLong(j4 >> 2n));
    let j6: bigint = lengthBigint;
    while (true) {
      j6--;
      if (j6 > 0n) {
        const j7: bigint = data[Number(j6 - 1n)];
        const idx: number = Number(j6);
        const keyIdx: number = Number(toLong(toLong(3n & j6) ^ j5));
        j2 = toLong(
          data[idx]
          - (toLong(toLong(j2 ^ j4) + toLong(j7 ^ key[keyIdx]))
            ^ toLong(toLong(toLong(j7 >> 5n) ^ toLong(j2 << 2n)) + toLong(toLong(j2 >> 3n) ^ toLong(j7 << 4n))))
        );
        data[idx] = j2;
      } else {
        break;
      }
    }
    const j8: bigint = data[Number(lengthBigint - 1n)];
    const keyIdx0: number = Number(toLong(toLong(j6 & 3n) ^ j5));
    j2 = toLong(
      data[0]
      - (toLong(toLong(key[keyIdx0] ^ j8) + toLong(j2 ^ j4))
        ^ toLong(toLong(toLong(j8 >> 5n) ^ toLong(j2 << 2n)) + toLong(toLong(j2 >> 3n) ^ toLong(j8 << 4n))))
    );
    data[0] = j2;
    j3 = toLong(j4 - DELTA);
  }
  return data;
}

/** long 数组 → 字符串（每个 long 8 字节小端 = 4 个 UTF-16LE 码元） */
function longArrToString(data: bigint[]): string {
  let out: string = '';
  for (let i = 0; i < data.length; i++) {
    let l: bigint = data[i];
    for (let k = 0; k < 4; k++) {
      const b0: number = Number(l & 0xFFn);
      l >>= 8n;
      const b1: number = Number(l & 0xFFn);
      l >>= 8n;
      const codeUnit: number = b0 | (b1 << 8);
      if (codeUnit !== 0) {
        out += String.fromCharCode(codeUnit);
      }
    }
  }
  return out;
}

/** hex 字符串 → 有符号 64 位 BigInt 数组（16 字符一组） */
function toBigintArray(data: string): bigint[] {
  const length: number = Math.floor(data.length / 16);
  const arr: bigint[] = [];
  for (let i = 0; i < length; i++) {
    arr.push(toLong(data.substring(i * 16, i * 16 + 16)));
  }
  return arr;
}

/**
 * 解密咪咕 MRC 歌词。
 * @param data mrc 文件内容（hex 文本）；短于 32 字符视为未加密，原样返回
 */
export function decryptMrc(data: string): string {
  if (data === null || data === undefined) {
    return '';
  }
  if (data.length < MIN_LENGTH) {
    return data;
  }
  const trimmed: string = data.trim();
  if (trimmed.length < MIN_LENGTH) {
    return data;
  }
  try {
    return longArrToString(teaDecrypt(toBigintArray(trimmed), KEY_ARR));
  } catch (e) {
    return '';
  }
}
