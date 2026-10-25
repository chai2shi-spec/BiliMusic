/**
 * 依赖装配。
 *
 * 分工：initPreferences 由 EntryAbility 在首帧前完成（loadContent 之前，
 * 供主题色 / 底栏布局首帧就位）；initRest 承载其余全部初始化
 * （RDB / 下载表 / 播放器 / Cookie），由 EntryAbility 与 loadContent
 * **并行**触发，不阻塞首页加载。
 */

import common from '@ohos.app.ability.common';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { initRdb } from '../database/RdbHelper';
import { MusicPlayer } from '../player/MusicPlayer';
import { DownloadManager } from './DownloadManager';
import { initBuvidCookie, upgradeBuvidCookie, isBuvidFallback, activateBuvid } from './BiliDevice';
import { initLoginState } from './LoginStore';
import { initUpSpaceCache } from './UpSpaceCacheStore';
import { initLyricCache } from './LyricCacheStore';
import { initListenCache } from './ListenCacheStore';
import { initLoudnessStore } from './LoudnessStore';
import { initPlayerStateStore } from './PlayerStateStore';
import { AppPreferences } from '../preferences/AppPreferences';
import { AppSettings } from '../model/MusicModels';
import { PREF_FAV_PUSH_QUEUE, STORE_STARTUP_HINT_MSG, STORE_STARTUP_HINT_SEQ } from '../common/Constants';
import { ensureDirUri, PublicSyncResult } from './PublicDownloadsSaver';
import { CardPublisher } from './card/CardPublisher';

/**
 * buvid 升级失败的延迟重试间隔（ms）：
 * 本地兜底 buvid 是风控易感指纹（登录二维码被提前作废 / playurl 偶发拦截的
 * 共同根因候选），首次 upgradeBuvidCookie 失败（断网 / 风控）时到点再试一次。
 * 取 10s：避开启动网络高峰，且晚于 spi 请求自身的 15s 超时窗口边缘。
 */
const BUVID_UPGRADE_RETRY_MS: number = 10000;

export class AppContainer {
  /**
   * initRest 的进行中/已完成 Promise（幂等缓存）。
   * 桌面卡片 call 拉起（callee handler）可能与 onWindowStageCreate 的
   * fire-and-forget 调用并发 —— 两路必须 await **同一个** Promise，
   * 否则双跑初始化链（RDB 双建 / 播放器双 init）。失败清空允许重试。
   */
  private static initPromise: Promise<void> | null = null;

  /**
   * 非关键初始化链（与首页加载并行执行）。
   * 前置条件：initPreferences 已由 EntryAbility 在首帧前完成。
   * context 刻意收紧为 UIAbilityContext：
   * EntryAbility 传的本来就是它，公共目录授权（DocumentViewPicker）需要
   * UIAbilityContext；下游 initRdb / MusicPlayer.init 等收 common.Context，
   * 子类型向上兼容不受影响。
   */
  static initRest(context: common.UIAbilityContext): Promise<void> {
    if (AppContainer.initPromise === null) {
      const pending: Promise<void> = AppContainer.doInitRest(context);
      pending.catch((): void => {
        if (AppContainer.initPromise === pending) {
          AppContainer.initPromise = null;
        }
      });
      AppContainer.initPromise = pending;
    }
    return AppContainer.initPromise;
  }

  private static async doInitRest(context: common.UIAbilityContext): Promise<void> {
    // 后台保活权限（normal 级 system_grant，不弹窗）：放在这里，
    // 减少首页加载瞬间的 IPC 竞争。
    AppContainer.requestKeepBackgroundPermission(context);
    // 蓝牙权限（user_grant，首启弹一次系统窗）：读蓝牙音频设备名用 ——
    // AudioRouteWatcher 靠设备名区分手表/手环与耳机/音箱。
    // 拒绝也不影响播放：名称过滤失效后退到「剩余蓝牙设备核查」兜底。
    AppContainer.requestBluetoothPermission(context);

    await initRdb(context);
    // UP 主页缓存目录：文件型存储，进页直接用缓存不联网；
    // 同步建目录，毫秒级，不拖慢启动
    initUpSpaceCache(context);
    // 歌词缓存目录：单曲一个 JSON 文件。
    // Preferences 单值 8192 字节上限装不下整首歌词，旧实现写两首就静默失败。
    initLyricCache(context);
    // 听后缓存目录：filesDir/listen_cache，512MB LRU。
    // 同步建目录 + 扫描索引（文件数百级有上界），毫秒级不拖慢启动。
    initListenCache(context);
    // 响度均衡数据表：filesDir/loudness.json 装载进内存 Map。
    // 同步读一次小 JSON（2000 条上限 ≈ 60KB），毫秒级；
    // 未装载时 record 静默跳过、lookup 返回 null，无害降级。
    initLoudnessStore(context);

    // buvid：缺它首页推荐接口会被 412 拦下，必须早于任何页面请求装填
    initBuvidCookie();

    // 登录 Cookie（扫码登录，可能不存在）：存在则随所有请求一并发出，
    // 让 playurl 等接口自动获得登录态（VIP 音质档等）
    initLoginState();

    // 收藏夹「待推送队列」残留清理：本地→B 站回推链路已整体移除（同步只剩
    // B 站 → 本地），老版本可能还留有 bilimusic_fav_push_queue_* 分片数据，
    // 启动时清一遍（fire-and-forget，不阻塞启动；remove 对不存在的 key 是 no-op）。
    AppContainer.purgeLegacyFavPushQueue();

    DownloadManager.getInstance().init(context);
    // 本地优先播放：启动即把下载任务表装填进内存 ——
    // MusicPlayer.loadAndPlay 切歌时同步查 completedLocalPath(musicId)，
    // 内存表为空的话已下载曲目会静默回落在线流（功能失效但不报错）。
    // 本链与 loadContent 并行执行，这里多 await 一次 RDB 读不影响首帧。
    // loadFromDb 顺带把上次进程被杀的中间态标为失败并清半截文件。
    await DownloadManager.getInstance().ensureLoaded();
    // 升级一次性迁移：沙箱旧下载 → 公共「下载/BiliMusic」。
    // fire-and-forget 不 await：迁移含目录授权与批量搬文件，拖慢启动链得不偿失；
    // 标记先行写入（at-most-once），失败不再自动重跑，残留经设置页「同步已完成歌曲」补齐。
    AppContainer.runPublicDirMigration(context).catch((e: BusinessError): void => {
      console.error(`[AppContainer] public dir migration failed: ${e.code} ${e.message}`);
    });
    // 播放器状态目录：双 JSON 文件（标量状态 + 队列全量）。
    // Preferences 单值 8192 字节上限装不下队列（旧实现被截到 ~10 首），
    // 须先于 MusicPlayer.init 建好目录，恢复链（restoreState）从这读快照。
    initPlayerStateStore(context);
    await MusicPlayer.getInstance().init(context);

    // 后台换取官方 buvid（不 await：本地兜底值已足够过 412，不能拖慢启动）
    // upgrade 成功后内部会立刻向 ExClimbWuzhi 上报一次
    // 设备激活（新 buvid 在服务端是「未激活」状态，不报等于换了个更可疑的指纹）。
    // 这里再挂一次不带 force 的激活，覆盖「升级失败、仍在用兜底 buvid」的分支 ——
    // activateBuvid 内部按 buvid 特征串去重，两条路径最多只发一次请求。
    upgradeBuvidCookie().then((): void => {
      activateBuvid();
    });
    // 仍是兜底假值（首次升级失败 / 新装机）时延迟重试
    // 一次 —— 假指纹是「二维码 3 秒被作废、登录失败、偶发播放拦截」的共同根因
    // 候选；成功一次即置 PREF_BUVID_OFFICIAL 标记，此后不再触发本重试。
    setTimeout((): void => {
      if (isBuvidFallback()) {
        console.warn('[BiliDevice] buvid still fallback, delayed retry upgrade');
        upgradeBuvidCookie();
      }
    }, BUVID_UPGRADE_RETRY_MS);
    // 桌面卡片实时推送：订阅 MusicPlayer 状态 + 启动全量回填。
    // 失败不阻断启动链（卡片侧 Form 进程还有 onAddForm 自推兜底）。
    try {
      CardPublisher.getInstance().attach(context);
    } catch (e) {
      console.error(`[AppContainer] card publisher attach failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    }
  }

  /**
   * 升级一次性迁移：把沙箱
   * filesDir/downloads 的已完成下载迁入公共「下载/BiliMusic」目录。
   *
   * 标记**先行写入**（at-most-once）：即便中途失败也不再自动重跑 —— 每次启动
   * 重复弹授权 / 重复搬移比「一次没搬成」更打扰；残留文件经设置页
   * 「同步已完成歌曲」手动补齐（同一套搬移逻辑，沙箱前缀过滤天然幂等）。
   * 无沙箱存量（新装 1.2.0 用户 / 早已搬完）直接 return，不弹提示不打扰。
   */
  private static async runPublicDirMigration(context: common.UIAbilityContext): Promise<void> {
    if (AppPreferences.getSettings().publicDirMigrated) {
      return;
    }
    AppPreferences.updateSettings((s: AppSettings): void => {
      s.publicDirMigrated = true;
    });
    if (!DownloadManager.getInstance().hasSandboxCompletedTask()) {
      return;
    }
    // 启动链无手势，系统可能拒绝 DOWNLOAD 模式授权（ensureDirUri 现有唯一调用点
    // 在设置页开关翻转，用户手势内）：拿不到就降级为一次性引导 —— 用户在设置页
    // （有手势处）可正常授权并手动同步，链路不断。
    const uri: string = await ensureDirUri(context);
    if (uri.length === 0) {
      AppContainer.setStartupHint('开启「保存到系统下载目录」可将已下载歌曲移入「下载/BiliMusic」');
      return;
    }
    // 迁移成功自动开开关：新下载行为与迁移后保持一致（产品决策）
    AppPreferences.updateSettings((s: AppSettings): void => {
      s.saveToPublicDownloads = true;
    });
    // 搬移本身幂等：只搬「已完成且仍在沙箱」的（前缀过滤），已搬过的天然排除
    const result: PublicSyncResult = await DownloadManager.getInstance().syncCompletedToPublicDir();
    if (result.ok > 0) {
      AppContainer.setStartupHint(`已下载歌曲已移入「下载/BiliMusic」文件夹（${result.ok} 首）`);
    }
  }

  /**
   * 写一次性启动提示双键（MSG + SEQ）。
   * Index 消费：aboutToAppear 补播（本链与 loadContent 并行，MSG 先写、组件后挂）
   * + @Watch(SEQ)（组件先挂、MSG 后写），两路都覆盖；消费即清 MSG，只弹一次。
   */
  private static setStartupHint(msg: string): void {
    AppStorage.setOrCreate(STORE_STARTUP_HINT_MSG, msg);
    const seq: number = (AppStorage.get<number>(STORE_STARTUP_HINT_SEQ) ?? 0) + 1;
    AppStorage.setOrCreate(STORE_STARTUP_HINT_SEQ, seq);
  }

  /**
   * 清理已移除的收藏夹回推链路残留分片数据。
   * 分片上限 33（0..32），串成 Promise 链避免并发打爆 Preferences。
   */
  private static purgeLegacyFavPushQueue(): void {
    let seq: Promise<void> = Promise.resolve();
    for (let i = 0; i <= 32; i++) {
      const key: string = `${PREF_FAV_PUSH_QUEUE}${i}`;
      seq = seq.then((): Promise<void> => AppPreferences.remove(key));
    }
    seq.then((): void => {
      console.info('[AppContainer] legacy fav push queue purged');
    }).catch((e: BusinessError): void => {
      console.error(`[AppContainer] purge legacy fav push queue failed: ${e.code} ${e.message}`);
    });
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

  /**
   * 申请蓝牙权限（user_grant，系统弹窗，首启一次）。
   * 用途仅一个：读 `AudioDeviceDescriptor.name`，让 AudioRouteWatcher 能按
   * 设备名排除手表/手环，避免连接手表时误报「蓝牙已断开」。
   * 用户拒绝 → 名称为空 → 名称过滤失效，只剩「断开后剩余蓝牙设备核查」兜底，
   * 不影响正常播放。fire-and-forget，不阻塞启动链。
   */
  private static requestBluetoothPermission(context: common.Context): void {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const permissions: Array<Permissions> = [
        'ohos.permission.ACCESS_BLUETOOTH'
      ];
      atManager.requestPermissionsFromUser(context, permissions, (err: BusinessError, data: object): void => {
        if (err) {
          console.error(`[Bluetooth] requestPermissionsFromUser failed: ${err.code} ${err.message}`);
        } else {
          console.info(`[Bluetooth] permissions result: ${JSON.stringify(data)}`);
        }
      });
    } catch (e) {
      console.error(`[Bluetooth] requestPermission exception: ${JSON.stringify(e)}`);
    }
  }
}
