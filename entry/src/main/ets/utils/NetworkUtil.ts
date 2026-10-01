/**
 * 网络类型探测：判断当前默认网络是不是「不计流量」的那一类。
 *
 * 用途只有一个：设置页的「仅 WiFi 下载」开关。开启后，若默认网络是蜂窝，
 * 下载入口会先停下来问用户一句，而不是默默烧掉几百 MB 流量。
 *
 * ⚠️ 需要 `ohos.permission.GET_NETWORK_INFO`（normal 级，module.json5 里声明即可，
 *    不需要运行时动态申请）。漏声明时 getDefaultNetSync 抛 201 → 被下面的 catch 吃掉
 *    → 永远返回「是不计流量网络」→ 开关看起来失效。改这里前先确认权限还在。
 *
 * ⚠️ **探测失败一律返回 true（不拦）**。方向很重要：探测不出来就禁止下载，
 *    用户只会认为「下载功能坏了」；而放行最坏也只是多耗一点流量。
 */

import connection from '@ohos.net.connection';

/**
 * 当前默认网络是否为不计流量网络（Wi-Fi / 以太网）。
 *
 * 以太网一并放行：它同样不计手机流量，「仅 WiFi」的本意是「别用蜂窝」。
 * 系统对默认网络的选择优先级本身也是 以太网 > Wi-Fi > 蜂窝
 * （见 @ohos.net.connection.d.ts 中 getDefaultNetSync 的说明）。
 */
export function isUnmeteredNetwork(): boolean {
  try {
    const net: connection.NetHandle = connection.getDefaultNetSync();
    // netId === 0 表示当前没有任何可用网络。这里不拦：真没网的话后续请求自己会失败并报错，
    // 在本函数里拦下来会把它伪装成「仅 WiFi 下载」的限制，误导排查方向。
    if (!net || net.netId === 0) {
      return true;
    }
    const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(net);
    const bearers: connection.NetBearType[] = caps.bearerTypes;
    if (!bearers || bearers.length === 0) {
      return true;
    }
    return bearers.indexOf(connection.NetBearType.BEARER_WIFI) >= 0
      || bearers.indexOf(connection.NetBearType.BEARER_ETHERNET) >= 0;
  } catch (e) {
    const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
    console.error(`isUnmeteredNetwork failed: ${msg}`);
    return true;
  }
}

/** 当前网络的中文描述，用于提示文案 */
export function currentNetworkLabel(): string {
  try {
    const net: connection.NetHandle = connection.getDefaultNetSync();
    if (!net || net.netId === 0) {
      return '无网络';
    }
    const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(net);
    const bearers: connection.NetBearType[] = caps.bearerTypes;
    if (!bearers || bearers.length === 0) {
      return '未知网络';
    }
    if (bearers.indexOf(connection.NetBearType.BEARER_WIFI) >= 0) {
      return 'Wi-Fi';
    }
    if (bearers.indexOf(connection.NetBearType.BEARER_ETHERNET) >= 0) {
      return '以太网';
    }
    if (bearers.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0) {
      return '移动网络';
    }
    return '未知网络';
  } catch (e) {
    return '未知网络';
  }
}
