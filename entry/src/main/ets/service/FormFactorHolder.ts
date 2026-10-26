/**
 * 折叠态适配层：App 生命周期级的**折叠屏形态唯一真源**。
 *
 * 职责：把 display 的折叠开合状态（FoldDisplayMode）转写成两个全局 AppStorage 键，
 * 供壳层与播放页只读订阅：
 *   · STORE_FOLD_EXPANDED    —— 是否处于展开态（FOLD_DISPLAY_MODE_FULL）；
 *   · STORE_DEVICE_FOLDABLE  —— 本机是否折叠屏设备（诊断 / 预留）。
 *
 * ══════════ 为什么在 EntryAbility.onCreate 初始化 ══════════
 * 折叠监听不能挂在播放页组件的 aboutToAppear 里：播放页是懒加载 overlay，
 * 不挂载就没有折叠态 —— 壳层（Index 的 phoneShell）在冷启动时
 * 根本读不到。init() 由 EntryAbility.onCreate 调用（display API
 * 不依赖窗口，早于 loadContent / 首帧），App 常驻不反注册，开合全程有状态。
 *
 * 本文件是 .ts（非 .ets）：EntryAbility.ts 不能导入 .ets 模块，与
 * AppContainer / AppPreferences 同款服务层写法；display API 走 @ohos.display，
 * 能力缺失由 try/catch 兜底为「非折叠」，不依赖 ArkTS 全局 canIUse。
 *
 * 消费端（@StorageProp 只读，写入权仅归本类）：
 *   · PlayerInfoComponent      —— 播放页「封面 | 歌词」左右分栏分支；
 *   · MusicInfoComponent       —— 展开态字号门控；
 *   · LyricsComponent          —— 展开态字号 / 布局门控。
 */

import display from '@ohos.display';
import { Callback } from '@ohos.base';
import { STORE_FOLD_EXPANDED, STORE_DEVICE_FOLDABLE } from '../common/Constants';

export class FormFactorHolder {
  /** foldDisplayModeChange 回调句柄（App 常驻，仅诊断用；不反注册） */
  private static foldCallback: Callback<display.FoldDisplayMode> | null = null;

  /**
   * EntryAbility.onCreate 调用（必须早于首页首帧）：
   * 先落默认值（非折叠设备 / 能力缺失时保持 false），再尝试注册折叠监听。
   * 任何一步失败都不影响应用运行 —— 状态缺失一律按「非折叠」处理，
   * 宽度断点（sm/md/lg）继续兜底细粒度布局。
   */
  static init(): void {
    AppStorage.setOrCreate(STORE_FOLD_EXPANDED, false);
    AppStorage.setOrCreate(STORE_DEVICE_FOLDABLE, false);
    try {
      // isFoldable 在不支持折叠能力的设备上抛 801，直接按非折叠处理
      if (!display.isFoldable()) {
        return;
      }
      AppStorage.setOrCreate(STORE_DEVICE_FOLDABLE, true);
      // 冷启动同步首发：设备本就处于展开态（或半开）时首帧即正确，
      // 不等 foldDisplayModeChange 事件。
      FormFactorHolder.applyMode(display.getFoldDisplayMode());
      FormFactorHolder.foldCallback = (mode: display.FoldDisplayMode): void => {
        FormFactorHolder.applyMode(mode);
      };
      display.on('foldDisplayModeChange', FormFactorHolder.foldCallback);
    } catch (e) {
      console.error(`[FormFactorHolder] init failed: ${JSON.stringify(e)}`);
    }
  }

  /** FoldDisplayMode → STORE_FOLD_EXPANDED 的唯一写入口 */
  private static applyMode(mode: display.FoldDisplayMode): void {
    const expanded: boolean = mode === display.FoldDisplayMode.FOLD_DISPLAY_MODE_FULL;
    console.info(`[FormFactorHolder] foldDisplayMode -> ${mode}, expanded=${expanded}`);
    AppStorage.setOrCreate(STORE_FOLD_EXPANDED, expanded);
  }
}
