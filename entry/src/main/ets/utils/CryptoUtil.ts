/**
 * 纯 TS 实现的 MD5（ASCII/UTF-8 输入，hex 输出）。
 * 来源：原 React 版 bilibiliApi.ts 的内联 MD5，已对照 node crypto 校验。
 * 用于 B 站 WBI 签名（w_rid = md5(排序查询 + mixinKey)），查询均为 ASCII。
 */

function rol(x: number, c: number): number {
  return (x << c) | (x >>> (32 - c));
}

function add(x: number, y: number): number {
  const x4 = x & 0x40000000;
  const y4 = y & 0x40000000;
  const x8 = x & 0x80000000;
  const y8 = y & 0x80000000;
  const r = (x & 0x3fffffff) + (y & 0x3fffffff);
  if (x4 > 0 && y4 > 0) {
    return (r ^ 0x80000000 ^ x8 ^ y8) | 0;
  }
  if (x4 > 0 || y4 > 0) {
    if (r & 0x40000000) {
      return (r ^ 0xc0000000 ^ x8 ^ y8) | 0;
    }
    return (r ^ 0x40000000 ^ x8 ^ y8) | 0;
  }
  return (r ^ x8 ^ y8) | 0;
}

function F(x: number, y: number, z: number): number {
  return (x & y) | (~x & z);
}

function G(x: number, y: number, z: number): number {
  return (x & z) | (y & ~z);
}

function H(x: number, y: number, z: number): number {
  return x ^ y ^ z;
}

function I(x: number, y: number, z: number): number {
  return y ^ (x | ~z);
}

function FF(a: number, b: number, c: number, d: number, x: number, s: number, t: number): number {
  return add(rol(add(a, add(add(F(b, c, d), x), t)), s), b);
}

function GG(a: number, b: number, c: number, d: number, x: number, s: number, t: number): number {
  return add(rol(add(a, add(add(G(b, c, d), x), t)), s), b);
}

function HH(a: number, b: number, c: number, d: number, x: number, s: number, t: number): number {
  return add(rol(add(a, add(add(H(b, c, d), x), t)), s), b);
}

function II(a: number, b: number, c: number, d: number, x: number, s: number, t: number): number {
  return add(rol(add(a, add(add(I(b, c, d), x), t)), s), b);
}

function toWords(s: string): number[] {
  const len: number = s.length;
  const nWords: number = (((len + 8 - ((len + 8) % 64)) / 64) + 1) * 16;
  const w: number[] = new Array<number>(nWords - 1).fill(0);
  let b: number = 0;
  while (b < len) {
    w[Math.floor((b - (b % 4)) / 4)] |= (s.charCodeAt(b) & 0xff) << ((b % 4) * 8);
    b++;
  }
  w[Math.floor((b - (b % 4)) / 4)] |= 0x80 << ((b % 4) * 8);
  w[nWords - 2] = len << 3;
  w[nWords - 1] = len >>> 29;
  return w;
}

function toHex(n: number): string {
  let s: string = '';
  for (let i: number = 0; i <= 3; i++) {
    const byte: number = (n >>> (i * 8)) & 255;
    let hex: string = (byte & 0xff).toString(16);
    if (hex.length < 2) {
      hex = '0' + hex;
    }
    s += hex;
  }
  return s;
}

export function md5(str: string): string {
  const x: number[] = toWords(str);
  let a: number = 0x67452301;
  let b: number = 0xefcdab89;
  let c: number = 0x98badcfe;
  let d: number = 0x10325476;

  for (let k: number = 0; k < x.length; k += 16) {
    const AA: number = a;
    const BB: number = b;
    const CC: number = c;
    const DD: number = d;

    a = FF(a, b, c, d, x[k], 7, 0xd76aa478); d = FF(d, a, b, c, x[k + 1], 12, 0xe8c7b756);
    c = FF(c, d, a, b, x[k + 2], 17, 0x242070db); b = FF(b, c, d, a, x[k + 3], 22, 0xc1bdceee);
    a = FF(a, b, c, d, x[k + 4], 7, 0xf57c0faf); d = FF(d, a, b, c, x[k + 5], 12, 0x4787c62a);
    c = FF(c, d, a, b, x[k + 6], 17, 0xa8304613); b = FF(b, c, d, a, x[k + 7], 22, 0xfd469501);
    a = FF(a, b, c, d, x[k + 8], 7, 0x698098d8); d = FF(d, a, b, c, x[k + 9], 12, 0x8b44f7af);
    c = FF(c, d, a, b, x[k + 10], 17, 0xffff5bb1); b = FF(b, c, d, a, x[k + 11], 22, 0x895cd7be);
    a = FF(a, b, c, d, x[k + 12], 7, 0x6b901122); d = FF(d, a, b, c, x[k + 13], 12, 0xfd987193);
    c = FF(c, d, a, b, x[k + 14], 17, 0xa679438e); b = FF(b, c, d, a, x[k + 15], 22, 0x49b40821);

    a = GG(a, b, c, d, x[k + 1], 5, 0xf61e2562); d = GG(d, a, b, c, x[k + 6], 9, 0xc040b340);
    c = GG(c, d, a, b, x[k + 11], 14, 0x265e5a51); b = GG(b, c, d, a, x[k], 20, 0xe9b6c7aa);
    a = GG(a, b, c, d, x[k + 5], 5, 0xd62f105d); d = GG(d, a, b, c, x[k + 10], 9, 0x02441453);
    c = GG(c, d, a, b, x[k + 15], 14, 0xd8a1e681); b = GG(b, c, d, a, x[k + 4], 20, 0xe7d3fbc8);
    a = GG(a, b, c, d, x[k + 9], 5, 0x21e1cde6); d = GG(d, a, b, c, x[k + 14], 9, 0xc33707d6);
    c = GG(c, d, a, b, x[k + 3], 14, 0xf4d50d87); b = GG(b, c, d, a, x[k + 8], 20, 0x455a14ed);
    a = GG(a, b, c, d, x[k + 13], 5, 0xa9e3e905); d = GG(d, a, b, c, x[k + 2], 9, 0xfcefa3f8);
    c = GG(c, d, a, b, x[k + 7], 14, 0x676f02d9); b = GG(b, c, d, a, x[k + 12], 20, 0x8d2a4c8a);

    a = HH(a, b, c, d, x[k + 5], 4, 0xfffa3942); d = HH(d, a, b, c, x[k + 8], 11, 0x8771f681);
    c = HH(c, d, a, b, x[k + 11], 16, 0x6d9d6122); b = HH(b, c, d, a, x[k + 14], 23, 0xfde5380c);
    a = HH(a, b, c, d, x[k + 1], 4, 0xa4beea44); d = HH(d, a, b, c, x[k + 4], 11, 0x4bdecfa9);
    c = HH(c, d, a, b, x[k + 7], 16, 0xf6bb4b60); b = HH(b, c, d, a, x[k + 10], 23, 0xbebfbc70);
    a = HH(a, b, c, d, x[k + 13], 4, 0x289b7ec6); d = HH(d, a, b, c, x[k], 11, 0xeaa127fa);
    c = HH(c, d, a, b, x[k + 3], 16, 0xd4ef3085); b = HH(b, c, d, a, x[k + 6], 23, 0x04881d05);
    a = HH(a, b, c, d, x[k + 9], 4, 0xd9d4d039); d = HH(d, a, b, c, x[k + 12], 11, 0xe6db99e5);
    c = HH(c, d, a, b, x[k + 15], 16, 0x1fa27cf8); b = HH(b, c, d, a, x[k + 2], 23, 0xc4ac5665);

    a = II(a, b, c, d, x[k], 6, 0xf4292244); d = II(d, a, b, c, x[k + 7], 10, 0x432aff97);
    c = II(c, d, a, b, x[k + 14], 15, 0xab9423a7); b = II(b, c, d, a, x[k + 5], 21, 0xfc93a039);
    a = II(a, b, c, d, x[k + 12], 6, 0x655b59c3); d = II(d, a, b, c, x[k + 3], 10, 0x8f0ccc92);
    c = II(c, d, a, b, x[k + 10], 15, 0xffeff47d); b = II(b, c, d, a, x[k + 1], 21, 0x85845dd1);
    a = II(a, b, c, d, x[k + 8], 6, 0x6fa87e4f); d = II(d, a, b, c, x[k + 15], 10, 0xfe2ce6e0);
    c = II(c, d, a, b, x[k + 6], 15, 0xa3014314); b = II(b, c, d, a, x[k + 13], 21, 0x4e0811a1);
    a = II(a, b, c, d, x[k + 4], 6, 0xf7537e82); d = II(d, a, b, c, x[k + 11], 10, 0xbd3af235);
    c = II(c, d, a, b, x[k + 2], 15, 0x2ad7d2bb); b = II(b, c, d, a, x[k + 9], 21, 0xeb86d391);

    a = add(a, AA);
    b = add(b, BB);
    c = add(c, CC);
    d = add(d, DD);
  }

  return (toHex(a) + toHex(b) + toHex(c) + toHex(d)).toLowerCase();
}
