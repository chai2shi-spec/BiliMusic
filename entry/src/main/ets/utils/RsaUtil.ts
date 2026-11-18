/**
 * RSA 公钥加密（passport 密码 / 短信登录专用）。
 *
 * B 站 `/x/passport-login/web/key` 下发的 PEM SPKI 公钥 + PKCS#1 v1.5 填充
 * （对齐 PiliPlus：其依赖 encrypt 5.0.3 的 `RSA` 默认 `RSAEncoding.PKCS1`，
 * 即 `PKCS1Encoding(RSAEngine())`；B 站网页端 jsencrypt 同口径）。
 *
 * 密钥位数（1024/2048…）运行时从 DER 里解析（SPKI → BIT STRING →
 * RSAPublicKey → modulus），不硬编码：`createAsyKeyGenerator` / `createCipher`
 * 的 spec 串都要求位数与真实密钥一致。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

const PEM_PUBLIC_HEADER: string = '-----BEGIN PUBLIC KEY-----';
const PEM_PUBLIC_FOOTER: string = '-----END PUBLIC KEY-----';

/** DER TLV 解析结果：tag / 内容起始 / 内容长度 / 下一个元素偏移 */
interface DerTlv {
  tag: number;
  contentStart: number;
  contentLen: number;
  next: number;
}

/**
 * 读取 offset 处的 DER TLV 头。
 * 失败（越界 / 长度字段畸形）返回 null，由调用方统一抛格式错误。
 */
function readDerTlv(der: Uint8Array, offset: number): DerTlv | null {
  if (offset < 0 || offset + 2 > der.length) {
    return null;
  }
  const tag: number = der[offset];
  let idx: number = offset + 1;
  const firstLenByte: number = der[idx];
  idx++;
  let len: number = 0;
  if (firstLenByte < 0x80) {
    len = firstLenByte;
  } else {
    const numLenBytes: number = firstLenByte & 0x7f;
    if (numLenBytes === 0 || numLenBytes > 4 || idx + numLenBytes > der.length) {
      return null;
    }
    for (let i: number = 0; i < numLenBytes; i++) {
      len = (len * 256) + der[idx + i];
    }
    idx += numLenBytes;
  }
  if (len < 0 || idx + len > der.length) {
    return null;
  }
  return { tag: tag, contentStart: idx, contentLen: len, next: idx + len };
}

/**
 * 从 SPKI DER 里解析 RSA 公钥模数位数。
 * 结构：SEQUENCE { SEQUENCE(算法标识), BIT STRING { SEQUENCE { INTEGER modulus, INTEGER exponent } } }。
 */
function parseRsaModulusBits(der: Uint8Array): number {
  const outer: DerTlv | null = readDerTlv(der, 0);
  if (outer === null || outer.tag !== 0x30) {
    throw new Error('RSA 公钥格式错误：缺少外层 SEQUENCE（非 SPKI DER）');
  }
  const algId: DerTlv | null = readDerTlv(der, outer.contentStart);
  if (algId === null || algId.tag !== 0x30) {
    throw new Error('RSA 公钥格式错误：缺少算法标识 SEQUENCE');
  }
  const bitString: DerTlv | null = readDerTlv(der, algId.next);
  if (bitString === null || bitString.tag !== 0x03 || bitString.contentLen < 2) {
    throw new Error('RSA 公钥格式错误：缺少公钥 BIT STRING');
  }
  // BIT STRING 内容首字节是 unused-bit 计数（RSA 公钥恒为 0），跳过
  const rsaSeq: DerTlv | null = readDerTlv(der, bitString.contentStart + 1);
  if (rsaSeq === null || rsaSeq.tag !== 0x30) {
    throw new Error('RSA 公钥格式错误：缺少 RSAPublicKey SEQUENCE');
  }
  const modulus: DerTlv | null = readDerTlv(der, rsaSeq.contentStart);
  if (modulus === null || modulus.tag !== 0x02 || modulus.contentLen === 0) {
    throw new Error('RSA 公钥格式错误：缺少模数 INTEGER');
  }
  let start: number = modulus.contentStart;
  let len: number = modulus.contentLen;
  // DER INTEGER 是有符号数：最高位为 1 时前置 0x00 补位，剥离后再计位数
  if (der[start] === 0 && len > 1) {
    start++;
    len--;
  }
  let firstByte: number = der[start];
  let leadingZeroBits: number = 0;
  while (leadingZeroBits < 8 && (firstByte & 0x80) === 0) {
    leadingZeroBits++;
    firstByte = (firstByte * 2) & 0xff;
  }
  return len * 8 - leadingZeroBits;
}

/**
 * RSA 公钥加密（PKCS#1 v1.5），输出 base64。
 *
 * @param plainText  明文（密码登录是 salt+password / 短信登录是随机串 dt）
 * @param pemPublicKey  PEM SPKI 公钥（`-----BEGIN PUBLIC KEY-----` 包裹）
 * @throws 公钥格式错误 / 明文超长（> 密钥字节数-11）/ 引擎异常（BusinessError 透传）
 */
export async function rsaEncryptBase64(plainText: string, pemPublicKey: string): Promise<string> {
  const stripped: string = pemPublicKey
    .split(PEM_PUBLIC_HEADER).join('')
    .split(PEM_PUBLIC_FOOTER).join('')
    .replace(/\s+/g, '');
  const helper: util.Base64Helper = new util.Base64Helper();
  const der: Uint8Array = helper.decodeSync(stripped);
  const bits: number = parseRsaModulusBits(der);
  if (bits < 512 || bits > 8192) {
    throw new Error(`RSA 公钥位数异常：${bits}`);
  }
  const generator: cryptoFramework.AsyKeyGenerator =
    cryptoFramework.createAsyKeyGenerator(`RSA${bits}`);
  const pubBlob: cryptoFramework.DataBlob = { data: der };
  const keyPair: cryptoFramework.KeyPair = await generator.convertKey(pubBlob, null);
  const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher(`RSA${bits}|PKCS1`);
  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, keyPair.pubKey, null);
  const plainBytes: Uint8Array = new util.TextEncoder().encodeInto(plainText);
  const maxPlainLen: number = Math.floor(bits / 8) - 11;
  if (plainBytes.length > maxPlainLen) {
    throw new Error(`RSA 明文超长：${plainBytes.length} > ${maxPlainLen}（密钥 ${bits} 位）`);
  }
  const cipherBlob: cryptoFramework.DataBlob | null =
    await cipher.doFinal({ data: plainBytes });
  if (cipherBlob === null) {
    throw new Error('RSA 加密失败：doFinal 无输出');
  }
  return helper.encodeToStringSync(cipherBlob.data);
}
