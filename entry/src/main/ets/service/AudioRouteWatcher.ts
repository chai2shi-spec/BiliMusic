/**
 * 音频路由监听：**蓝牙音频设备断开时暂停播放**。
 *
 * 为什么需要（本工程原先完全没有蓝牙处理，`grep -rn "bluetooth\|routing"` 全空）：
 * 手机通过蓝牙耳机出声时，用户摘掉耳机 / 耳机断电，系统会把音频**切到扬声器继续播**——
 * 于是「耳边突然外放」时，用户的第一反应是「手机 bug」并去按暂停，多数音乐 App 的做法是
 * 耳机断开即暂停（而不是默默外放）。本模块就是补上这一条。
 *
 * 关键设计（都是踩过的坑）：
 *  1. **只认「输出设备」的断开**：`on('deviceChange', DeviceFlag.OUTPUT_DEVICES_FLAG, …)`，
 *     麦克风等输入设备的断开与我们无关；
 *  2. **只认蓝牙类型**：`DeviceType.BLUETOOTH_A2DP`（立体声输出）与 `BLUETOOTH_SCO`
 *     （通话链路）都算；有线耳机 / 扬声器断开不触发（那是用户主动拔线，行为不该强加）；
 *  3. **SDK 没有「当前活跃输出设备」接口**（API 26 的 `AudioRoutingManager` 只有
 *     `getSelectedMediaInputDevice`，输出侧没有对应物），所以**无法严格区分「正在用蓝牙」
 *     与「蓝牙只是连着但走的是扬声器」**。这里接受一个已知边界：耳机已连接但没在用它时
 *     摘掉，也会被暂停 —— 判据只能取「断开的是蓝牙输出设备」，宁可多停一次，
 *     也不要让声音突然外放（外放是体验事故，误停只是多点一下播放）。
 *  4. **回调解引用**：`off()` 必须传与 `on()` 相同的函数引用才能退订，
 *     所以把它存成成员（见 listener）。
 *  5. **全程 try/catch**：音频设备查询在部分设备/权限下会抛，监听失败绝不能影响播放。
 *
 * 生命周期：`MusicPlayer.init()` 里启动（整个 App 只需一份），不随页面销毁。
 */

import { audio } from '@kit.AudioKit';

/** 蓝牙输出设备断开时的回调（由播放内核注入，内部负责暂停） */
export type BluetoothLostHandler = () => void;

/** 判断设备类型是不是蓝牙音频设备 */
function isBluetoothDevice(deviceType: audio.DeviceType): boolean {
  return deviceType === audio.DeviceType.BLUETOOTH_A2DP || deviceType === audio.DeviceType.BLUETOOTH_SCO;
}

export class AudioRouteWatcher {
  private static instance: AudioRouteWatcher | null = null;

  private started: boolean = false;
  private handler: BluetoothLostHandler | null = null;
  /** on() 时的回调引用；off() 要传同一个引用，匿名函数退订不掉 */
  private listener: ((action: audio.DeviceChangeAction) => void) | null = null;

  static getInstance(): AudioRouteWatcher {
    if (AudioRouteWatcher.instance === null) {
      AudioRouteWatcher.instance = new AudioRouteWatcher();
    }
    return AudioRouteWatcher.instance;
  }

  /**
   * 开始监听（幂等）。回调在**蓝牙输出设备断开**时触发。
   */
  start(handler: BluetoothLostHandler): void {
    if (this.started) {
      // 已经在监听：只更新回调，避免重复订阅导致一次断开触发多次暂停
      this.handler = handler;
      return;
    }
    this.handler = handler;
    try {
      // ⚠️ 两级取法：`getRoutingManager()` 挂在 `AudioManager` 上（`AudioManager` interface,
      // SDK `@ohos.multimedia.audio.d.ts:2427`），**不在** `audio` 命名空间的顶层 ——
      // 写 `audio.getRoutingManager()` 编译直接报「does not exist on type 'typeof audio'」。
      const routing: audio.AudioRoutingManager = audio.getAudioManager().getRoutingManager();
      this.listener = (action: audio.DeviceChangeAction): void => {
        this.handleChange(action);
      };
      // 三参重载（带 DeviceFlag）只存在于 `AudioRoutingManager`，旧 `AudioManager.on` 只有两参
      routing.on('deviceChange', audio.DeviceFlag.OUTPUT_DEVICES_FLAG, this.listener);
      this.started = true;
      console.info('AudioRouteWatcher started (bluetooth disconnect -> pause)');
    } catch (e) {
      this.started = false;
      this.listener = null;
      // 拿不到路由管理器的设备上就没有这个能力，不该因此影响播放
      const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.warn(`AudioRouteWatcher start failed: ${detail}`);
    }
  }

  /** 停止监听（一般不需要；页面/内核销毁时调用） */
  stop(): void {
    if (!this.started || this.listener === null) {
      return;
    }
    try {
      const routing: audio.AudioRoutingManager = audio.getAudioManager().getRoutingManager();
      // ⚠️ `off` **没有**带 deviceFlag 的重载（只有 `off(type, callback?)`），
      // 与 `on(type, deviceFlag, callback)` 不对称 —— 照着 on 写会报「Expected 1-2 arguments」。
      routing.off('deviceChange', this.listener);
    } catch (e) {
      const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.warn(`AudioRouteWatcher stop failed: ${detail}`);
    }
    this.started = false;
    this.listener = null;
    this.handler = null;
  }

  /**
   * 设备变化回调。
   *
   * 只在「明确的 DISCONNECT + 涉及蓝牙设备」时通知：
   * · CONNECT 一律忽略（连上耳机不该自动续播，那是另一个产品决策）；
   * · 断开的是扬声器/有线耳机也忽略。
   */
  private handleChange(action: audio.DeviceChangeAction): void {
    try {
      if (action.type !== audio.DeviceChangeType.DISCONNECT) {
        return;
      }
      const devices: audio.AudioDeviceDescriptors = action.deviceDescriptors;
      if (!devices) {
        return;
      }
      let bluetoothGone: boolean = false;
      for (let i = 0; i < devices.length; i++) {
        if (isBluetoothDevice(devices[i].deviceType)) {
          bluetoothGone = true;
          console.info(`bluetooth device disconnected: ${devices[i].name} (type ${devices[i].deviceType})`);
          break;
        }
      }
      if (!bluetoothGone) {
        return;
      }
      const handler: BluetoothLostHandler | null = this.handler;
      if (handler) {
        handler();
      }
    } catch (e) {
      const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`handleChange failed: ${detail}`);
    }
  }
}
