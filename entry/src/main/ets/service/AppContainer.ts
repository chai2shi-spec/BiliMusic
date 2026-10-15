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
import { initLoginState, isLoggedIn } from './LoginStore';
import { countFavPushOps, setFavPushKicker } from './FavPushStore';
import { FavSyncManager } from './FavSyncManager';
import { initUpSpaceCache } from './UpSpaceCacheStore';

export class AppContainer {
  private static initialized: boolean = false;

  static async init(context: common.Context): Promise<void> {
    if (AppContainer.initialized) {
      return;
    }
    await initPreferences(context);
    await initRdb(context);
    // UP 主页缓存目录（2026-10-09）：文件型存储，进页直接用缓存不联网；
    // 同步建目录，毫秒级，不拖慢启动
    initUpSpaceCache(context);

    // buvid：缺它首页推荐接口会被 412 拦下，必须早于任何页面请求装填
    initBuvidCookie();

    // 登录 Cookie（扫码登录，可能不存在）：存在则随所有请求一并发出，
    // 让 playurl 等接口自动获得登录态（VIP 音质档等）
    initLoginState();

    // 收藏夹「待推送队列」冷启动重试（2026-10-13 真双向）：上次离线时用户删/加过镜像歌单的曲目，
    // 写意图已落盘但没发出去。这里只**重放这些用户已确认的操作**，**不做**完整同步
    // （尊重「只有登录后 / 手动才全量同步」的产品决策）。fire-and-forget，不阻塞首帧。
    if (isLoggedIn() && countFavPushOps() > 0) {
      FavSyncManager.getInstance().pushOnly('coldstart');
    }

    // 装配「入队即推送」触发器：任何本地改动（删曲 / 加曲 / 清空）入队后立刻尝试推回 B 站。
    // 用回调注入而不是让 FavPushStore 直接 import FavSyncManager，是为了避免
    // FavPushStore → FavSyncManager → LibraryStore → FavPushStore 的循环依赖。
    setFavPushKicker((): void => {
      FavSyncManager.getInstance().pushOnly('local-change');
    });

    DownloadManager.getInstance().init(context);
    // 2026-10-08 本地优先播放：启动即把下载任务表装填进内存 ——
    // MusicPlayer.loadAndPlay 切歌时同步查 completedLocalPath(musicId)，
    // 内存表为空的话已下载曲目会静默回落在线流（功能失效但不报错）。
    // EntryAbility 对 AppContainer.init 是 fire-and-forget，这里多 await 一次
    // RDB 读不阻塞首帧。loadFromDb 顺带把上次进程被杀的中间态标为失败并清半截文件，
    // 提前到启动做只有好处（原先要等首次进下载页才清理）。
    await DownloadManager.getInstance().ensureLoaded();
    await MusicPlayer.getInstance().init(context);

    // 后台换取官方 buvid（不 await：本地兜底值已足够过 412，不能拖慢启动）
    upgradeBuvidCookie();
    AppContainer.initialized = true;
  }
}
