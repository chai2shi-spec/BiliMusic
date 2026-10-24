/**
 * B 站风控指纹参数（2026-10-24 移植自 PiliPlus 的「风控面分层」方案）。
 *
 * 背景：B 站 Web 端 playurl / 搜索等接口除了校验 WBI 签名，还校验「这看起来像不像
 * 一个真实浏览器」。缺下面这组参数时接口不一定立刻拒绝，但会**更容易**被判为
 * 第三方客户端 —— 表现是同一 buvid 下「一次成功、下一次 -352」「登录后偶发拦截、
 * 退出登录反而正常」。这不是「值对不对」的问题，而是「有没有按浏览器口径发」。
 *
 * 本文件只做三件纯计算的事，不发任何网络请求：
 *   1. gaiaWebParams()：playurl 的浏览器同款指纹参数（每次调用重新随机，模拟
 *      「每次都是新渲染的页面」，而不是同一串固定值被反复上报）；
 *   2. buildWuzhiPayload()：ExClimbWuzhi（风控指纹激活接口）的 payload ——
 *      构造一段「假 PNG 尾部 base64」冒充 canvas/图片指纹的输出，
 *      **这是让新 buvid 在服务端从「未激活」变成「已激活」的关键**；
 *   3. randomBase64()：给上面两项造随机字节。
 *
 * ⚠️ 这些参数与「能不能访问」无关，只影响风控评分。删掉它们接口通常照常返回
 * code=0（实测），所以不要用「删了还能用」来证明它们没用。
 */

import util from '@ohos.util';

/** 随机字节数 → base64 串（用于伪造 dm_img_str / 图片指纹尾部） */
export function randomBase64(byteLen: number): string {
  const bytes: Uint8Array = new Uint8Array(byteLen);
  for (let i = 0; i < byteLen; i++) {
    bytes[i] = Math.floor(Math.random() * 256);
  }
  return new util.Base64Helper().encodeToStringSync(bytes);
}

/**
 * playurl 的浏览器同款参数（对齐 PiliPlus `Request.videoUrl` 的 queryParameters）。
 *
 * | 参数 | 值 | 作用 |
 * |---|---|---|
 * | gaia_source | pre-load | 声明这是「预加载」请求，风控视为正常播放行为 |
 * | isGaiaAvoided | true | 显式声明已避开 gaia 风控（GitHub 客户端惯例口径） |
 * | web_location | 1315873 | 官方播放器页面的位置标识，缺它易被判「非官方入口」 |
 * | dm_img_list / dm_img_str / dm_cover_img_str / dm_img_inter | 随机 | 伪装弹幕/封面图片的 canvas 指纹 |
 *
 * 最后一项 `dm_img_inter` 是固定字面量（服务端只判结构，不校验内容）。
 */
export function gaiaWebParams(): Record<string, string> {
  return {
    gaia_source: 'pre-load',
    isGaiaAvoided: 'true',
    web_location: '1315873',
    dm_img_list: '[]',
    dm_img_str: randomBase64(16),
    dm_cover_img_str: randomBase64(40),
    dm_img_inter: '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}'
  };
}

/**
 * 构造 ExClimbWuzhi 的 payload 串（单行 JSON，**不要**再包一层对象）。
 *
 * 三个字段是 B 站风控页面的压缩变量名，含义：
 *   · `3064`：固定 1（入口版本）
 *   · `39c8`：`333.1387.fp.risk` —— spm 前缀，声明这是指纹上报场景
 *   · `3c43`：环境信息，`adca` 是平台（Linux/Windows），`bfe9` 是**图片指纹尾部**
 *
 * `bfe9` 为什么这么造：真实浏览器上报的是「canvas 渲染出的 PNG 数据 URI 的最后
 * 50 个字符」。这里用 32 个随机字节 + PNG IEND 块（`\0\0\0\0IEND`）+ 4 个随机字节
 * 拼一段假 PNG 再 base64，取尾部 50 字符 —— 长度与字符分布都落在服务端期望的
 * 区间内。**用固定串或空串会被判「非浏览器」，激活等于没做。**
 */
export function buildWuzhiPayload(): string {
  const png: Uint8Array = new Uint8Array(44);
  for (let i = 0; i < 32; i++) {
    png[i] = Math.floor(Math.random() * 256);
  }
  // PNG IEND 块签名：4 字节长度(0) + 4 字节类型(IEND)
  png[32] = 0;
  png[33] = 0;
  png[34] = 0;
  png[35] = 0;
  png[36] = 73;
  png[37] = 69;
  png[38] = 78;
  png[39] = 68;
  for (let i = 40; i < 44; i++) {
    png[i] = Math.floor(Math.random() * 256);
  }
  const b64: string = new util.Base64Helper().encodeToStringSync(png);
  const tail: string = b64.length > 50 ? b64.substring(b64.length - 50) : b64;
  // 手拼 JSON（不用对象字面量）：ArkTS 不允许匿名对象，且键名是纯数字，
  // 写 interface 反而更难读。tail 已保证只含 base64 字符，无转义风险。
  return `{"3064":1,"39c8":"333.1387.fp.risk","3c43":{"adca":"Linux","bfe9":"${tail}"}}`;
}
