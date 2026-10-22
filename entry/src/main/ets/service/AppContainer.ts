/**
 * 依赖装配（替代原 Hilt / 手动 DI）。
 *
 * 2026-10-17 启动优化拆分：本类不再负责 initPreferences —— 它已上移到
 * EntryAbility 的首帧前链路（loadContent 之前完成，供主题色 / 底栏布局
 * 首帧就位）。initRest 承载其余全部初始化（RDB / 下载表 / 播放器 / Cookie），
 * 由 EntryAbility 与 loadContent **并行**触发，不再阻塞首页加载。
 */

import common from '@ohos.app.ability.common';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { initRdb } from '../database/RdbHelper';
import { MusicPlayer } from '../player/MusicPlayer';
import { DownloadManager } from './DownloadManager';
import { initBuvidCookie, upgradeBuvidCookie, isBuvidFallback } from './BiliDevice';
import { initLoginState, isLoggedIn } from './LoginStore';
import { countFavPushOps, setFavPushKicker } from './FavPushStore';
import { FavSyncManager } from './FavSyncManager';
import { initUpSpaceCache } from './UpSpaceCacheStore';
import { initLyricCache } from './LyricCacheStore';

/**
 * buvid 升级失败的延迟重试间隔（ms，2026-10-22 平板登录修复）：
 * 本地兜底 buvid 是风控易感指纹（登录二维码被提前作废 / playurl 偶发拦截的
 * 共同根因候选），首次 upgradeBuvidCookie 失败（断网 / 风控）时到点再试一次。
 * 取 10s：避开启动网络高峰，且晚于 spi 请求自身的 15s 超时窗口边缘。
 */
const BUVID_UPGRADE_RETRY_MS: number = 10000;

export class AppContainer {
  private static initialized: boolean = false;

  /**
   * 非关键初始化链（与首页加载并行执行）。
   * 前置条件：initPreferences 已由 EntryAbility 在首帧前完成。
   */
  static async initRest(context: common.Context): Promise<void> {
    if (AppContainer.initialized) {
      return;
    }
    // 后台保活权限（normal 级 system_grant，不弹窗）：原在启动关键路径上，
    // 移到这里减少首页加载瞬间的 IPC 竞争。
    AppContainer.requestKeepBackgroundPermission(context);

    await initRdb(context);
    // UP 主页缓存目录（2026-10-09）：文件型存储，进页直接用缓存不联网；
    // 同步建目录，毫秒级，不拖慢启动
    initUpSpaceCache(context);
    // 歌词缓存目录（2026-10-22 多源歌词）：单曲一个 JSON 文件。
    // Preferences 单值 8192 字节上限装不下整首歌词，旧实现写两首就静默失败。
    initLyricCache(context);

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
    // 本链与 loadContent 并行执行，这里多 await 一次 RDB 读不影响首帧。
    // loadFromDb 顺带把上次进程被杀的中间态标为失败并清半截文件，
    // 提前到启动做只有好处（原先要等首次进下载页才清理）。
    await DownloadManager.getInstance().ensureLoaded();
    await MusicPlayer.getInstance().init(context);

    // 后台换取官方 buvid（不 await：本地兜底值已足够过 412，不能拖慢启动）
    upgradeBuvidCookie();
    // 2026-10-22 平板登录修复：仍是兜底假值（首次升级失败 / 新装机）时延迟重试
    // 一次 —— 假指纹是「二维码 3 秒被作废、登录失败、偶发播放拦截」的共同根因
    // 候选；成功一次即置 PREF_BUVID_OFFICIAL 标记，此后不再触发本重试。
    setTimeout((): void => {
      if (isBuvidFallback()) {
        console.warn('[BiliDevice] buvid still fallback, delayed retry upgrade');
        upgradeBuvidCookie();
      }
    }, BUVID_UPGRADE_RETRY_MS);
    AppContainer.initialized = true;
  }

  private static requestKeepBackgroundPermission(context: common.Context): void {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const permissions: Array<Permissions> = [
        'ohos.permission.KEEP_BACKGROUND_RUNNING'
      ];
      atManager.requestPermissionsFromUser(context, permissions, (err: BusinessError, data: object): void => {
        if (err) {
          console.error(`requestPermissionsFromUser failed: ${err.code} ${err.message}`);
        } else {
          console.info(`permissions result: ${JSON.stringify(data)}`);
        }
      });
    } catch (e) {
      console.error(`requestNeededPermissions exception: ${JSON.stringify(e)}`);
    }
  }
}
