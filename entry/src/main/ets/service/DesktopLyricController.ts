/**
 * 桌面歌词（AVSession Kit 系统「歌词组件」）开关编排。
 *
 * 背景：桌面歌词早期的自建悬浮窗方案（TYPE_FLOAT 全局悬浮窗 / API 26 闪控窗
 * floatView）全部依赖 system_basic 受限权限（SYSTEM_FLOAT_WINDOW /
 * FLOAT_VIEW），普通应用需经 AGC ACL 申请，调试签名直接安装失败
 *（9568289）—— 相关代码与权限声明已整体移除。现接入系统「歌词组件」：
 *   · 内容源 = MusicPlayer 已上报的 AVMetadata.lyric（标准 LRC，
 *     publishSessionLyric 组装，带每曲偏移）；
 *   · 开关 = avSession.enableDesktopLyric + setDesktopLyricVisible；
 *   · 锁定 = setDesktopLyricState({ isLocked })（固定位置、禁拖拽）；
 *   · 组件样式由系统统一渲染，应用侧不提供字号/颜色自定义。
 *
 * 职责边界：本类只做「系统调用 → 成功才落盘 + 镜像」的编排；会话持有者
 * （MusicPlayer）负责 enable/visible/lock 调用与系统侧状态监听回调。
 * 支持性探测失败 / 系统调用失败一律返回 false，调用方提示并回弹开关。
 */

import { AppPreferences } from '../preferences/AppPreferences';
import { AppSettings } from '../model/MusicModels';
import { STORE_FLOAT_LYRIC_ENABLED, STORE_FLOAT_LYRIC_LOCKED } from '../common/Constants';
import { MusicPlayer } from '../player/MusicPlayer';

export class DesktopLyricController {
  private static instance: DesktopLyricController | null = null;

  public static getInstance(): DesktopLyricController {
    if (DesktopLyricController.instance === null) {
      DesktopLyricController.instance = new DesktopLyricController();
    }
    return DesktopLyricController.instance;
  }

  /**
   * 系统/设备是否支持桌面歌词组件（API 23+ 且系统开关允许）。
   * 不支持时调用方提示「当前设备不支持桌面歌词」并回弹开关。
   */
  public isSupported(): Promise<boolean> {
    return MusicPlayer.getInstance().isDesktopLyricSupported();
  }

  /**
   * 开启/关闭桌面歌词。开启 = 首次 enable + 按锁定态设置 + 显示；
   * 关闭 = 仅隐藏（保留 enable，便于再次开启）。系统调用成功才落盘 +
   * 镜像 —— 失败返回 false 且不改变持久化状态（调用方开关回弹）。
   */
  public async setEnabled(enabled: boolean, locked: boolean): Promise<boolean> {
    const ok: boolean = await MusicPlayer.getInstance().setDesktopLyricEnabled(enabled, locked);
    if (!ok) {
      return false;
    }
    AppStorage.setOrCreate(STORE_FLOAT_LYRIC_ENABLED, enabled);
    AppPreferences.updateSettings((s: AppSettings): void => {
      s.floatLyricEnabled = enabled;
    });
    return true;
  }

  /**
   * 锁定/解锁桌面歌词（系统组件未开启时也落盘，下次开启按新值生效）。
   * 无窗/未开启时系统调用内部静默跳过，不打扰用户。
   */
  public async setLocked(locked: boolean): Promise<void> {
    AppStorage.setOrCreate(STORE_FLOAT_LYRIC_LOCKED, locked);
    AppPreferences.updateSettings((s: AppSettings): void => {
      s.floatLyricLocked = locked;
    });
    await MusicPlayer.getInstance().setDesktopLyricLocked(locked);
  }
}
