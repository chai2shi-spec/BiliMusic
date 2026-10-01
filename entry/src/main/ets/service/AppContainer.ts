/**
 * 依赖装配（替代原 Hilt / 手动 DI）。
 * 应用启动时统一初始化 Preferences、RDB、buvid Cookie 与播放器单例。
 */

import common from '@ohos.app.ability.common';
import { initPreferences } from '../preferences/AppPreferences';
import { initRdb } from '../database/RdbHelper';
import { MusicPlayer } from '../player/MusicPlayer';
import { DownloadManager } from './DownloadManager';
import { initBuvidCookie, upgradeBuvidCookie } from './BiliDevice';

export class AppContainer {
  private static initialized: boolean = false;

  static async init(context: common.Context): Promise<void> {
    if (AppContainer.initialized) {
      return;
    }
    await initPreferences(context);
    await initRdb(context);

    // buvid：缺它首页推荐接口会被 412 拦下，必须早于任何页面请求装填
    // （登录态已不存在，这是唯一的请求 Cookie 来源）
    initBuvidCookie();

    DownloadManager.getInstance().init(context);
    await MusicPlayer.getInstance().init(context);

    // 后台换取官方 buvid（不 await：本地兜底值已足够过 412，不能拖慢启动）
    upgradeBuvidCookie();
    AppContainer.initialized = true;
  }
}
