/**
 * 音频路由监听：**蓝牙音频设备（耳机 / 音箱）断开时暂停播放**。
 *
 * 为什么需要：
 * 手机通过蓝牙耳机出声时，用户摘掉耳机 / 耳机断电，系统会把音频**切到扬声器继续播**——
 * 于是「耳边突然外放」时，用户的第一反应是「手机 bug」并去按暂停，多数音乐 App 的做法是
 * 耳机断开即暂停（而不是默默外放）。本模块就是补上这一条。
 *
 * 关键设计（都是踩过的坑）：
 *  1. **只认「输出设备」的断开**：`on('deviceChange', DeviceFlag.OUTPUT_DEVICES_FLAG, …)`，
 *     麦克风等输入设备的断开与我们无关；
 *  2. **只认蓝牙类型**：`DeviceType.BLUETOOTH_A2DP`（立体声输出）与 `BLUETOOTH_SCO`
 *     （通话链路）都算；有线耳机 / 扬声器断开不触发（那是用户主动拔线，行为不该强加）；
 *  3. **排除手表 / 手环**：`DeviceType` 没有手表专用类型，
 *     手表连接时手机音频框架同样会报 BLUETOOTH_SCO/A2DP 设备变化（手表注册 HFP 通话链路
 *     或 BT 协议栈重协商），若一律当「耳机断开」处理，播放中连 HUAWEI WATCH 3 会误弹
 *     「蓝牙已断开，已暂停播放」。处理分两层：
 *     · **名称过滤**：设备名（需 ACCESS_BLUETOOTH 权限，见 module.json5）命中
 *       watch/手表/band/手环/gts/gtr → 直接忽略（覆盖 HUAWEI WATCH、Apple Watch、
 *       Mi Band、Amazfit GTS/GTR 等主流手表手环）；
 *     · **剩余设备核查**：非手表蓝牙设备断开后，`getDevicesSync` 查当前输出设备，
 *       仍存在「非手表」的蓝牙音频设备（如手表连接导致耳机 SCO 瞬断但耳机还在）→
 *       不暂停。查询异常时保守回退为「触发暂停」——宁可多停一次，不可丢掉防外放能力。
 *  4. **SDK 没有「当前活跃输出设备」接口**（API 26 的 `AudioRoutingManager` 只有
 *     `getSelectedMediaInputDevice`，输出侧没有对应物），所以**无法严格区分「正在用蓝牙」
 *     与「蓝牙只是连着但走的是扬声器」**。这里接受一个已知边界：耳机已连接但没在用它时
 *     摘掉，也会被暂停 —— 判据只能取「断开的是蓝牙输出设备」，宁可多停一次，
 *     也不要让声音突然外放（外放是体验事故，误停只是多点一下播放）。
 *  5. **回调解引用**：`off()` 必须传与 `on()` 相同的函数引用才能退订，
 *     所以把它存成成员（见 listener）。
 *  6. **全程 try/catch**：音频设备查询在部分设备/权限下会抛，监听失败绝不能影响播放。
 *
 * 生命周期：`MusicPlayer.init()` 里启动（整个 App 只需一份），不随页面销毁。
 */

import { audio } from '@kit.AudioKit';

/** 蓝牙输出设备断开时的回调（由播放内核注入，内部负责暂停） */
export type BluetoothLostHandler = () => void;

/**
 * 手表 / 手环设备名关键词（小写匹配）。
 * 选取原则：只收几乎只出现在穿戴设备上的词，避开 fit/wear 等可能误伤音箱耳机的词；
 * 耳机音箱常见命名（Buds/Headphones/Pods/TWS/Speaker）均不命中。
 */
const WEARABLE_NAME_KEYWORDS: string[] = ['watch', '手表', 'band', '手环', 'gts', 'gtr'];

/** 判断设备类型是不是蓝牙音频设备 */
function isBluetoothDevice(deviceType: audio.DeviceType): boolean {
  return deviceType === audio.DeviceType.BLUETOOTH_A2DP || deviceType === audio.DeviceType.BLUETOOTH_SCO;
}

/** 取设备显示名：优先 `name`（蓝牙设备名，需 ACCESS_BLUETOOTH），空则退 `displayName`。 */
function deviceLabelOf(device: audio.AudioDeviceDescriptor): string {
  const n: string = device.name ?? '';
  if (n.length > 0) {
    return n;
  }
  return device.displayName ?? '';
}

/** 按设备名判断是不是手表 / 手环（HUAWEI WATCH 3、Apple Watch、Mi Band、Amazfit GTS…）。 */
function looksLikeWearable(device: audio.AudioDeviceDescriptor): boolean {
  const label: string = deviceLabelOf(device).toLowerCase();
  if (label.length === 0) {
    return false;
  }
  for (let i = 0; i < WEARABLE_NAME_KEYWORDS.length; i++) {
    if (label.includes(WEARABLE_NAME_KEYWORDS[i])) {
      return true;
    }
  }
  return false;
}

/**
 * 断开发生后核查：当前已连接的输出设备里，是否还存在「非手表」的蓝牙音频设备。
 * 存在 → 说明断开没有移走音频通路（典型：手表连接导致耳机 SCO 瞬断但耳机还在线），不该暂停。
 * 查询失败 → 返回 false，调用方保守回退为「触发暂停」。
 */
function hasRemainingBluetoothAudio(): boolean {
  try {
    const routing: audio.AudioRoutingManager = audio.getAudioManager().getRoutingManager();
    const devices: audio.AudioDeviceDescriptors = routing.getDevicesSync(audio.DeviceFlag.OUTPUT_DEVICES_FLAG);
    if (!devices) {
      return false;
    }
    for (let i = 0; i < devices.length; i++) {
      const d: audio.AudioDeviceDescriptor = devices[i];
      if (isBluetoothDevice(d.deviceType) && !looksLikeWearable(d)) {
        console.info(`bluetooth audio still present: ${deviceLabelOf(d)} (type ${d.deviceType})`);
        return true;
      }
    }
    return false;
  } catch (e) {
    const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
    console.warn(`hasRemainingBluetoothAudio check failed: ${detail}`);
    return false;
  }
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
    * 开始监听（幂等）。回调在**蓝牙音频设备（耳机/音箱，不含手表手环）断开**时触发。
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
      console.info('AudioRouteWatcher started (bluetooth audio disconnect -> pause, wearables excluded)');
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
    * DISCONNECT（蓝牙音频断开才可能暂停）：
    * · 手表 / 手环（名称命中关键词）→ 忽略；
    * · 非手表蓝牙设备断开 → 先核查剩余设备，仍有其它蓝牙音频在连（耳机 SCO 瞬断等）→ 忽略；
    * · 全无蓝牙音频了 → 通知（真正该暂停的场景）。
    * CONNECT 一律只记日志（连上耳机不自动续播，那是另一个产品决策）；
    * 断开的是扬声器/有线耳机也忽略。
    */
  private handleChange(action: audio.DeviceChangeAction): void {
    try {
      const devices: audio.AudioDeviceDescriptors = action.deviceDescriptors;
      if (!devices) {
        return;
      }
      if (action.type === audio.DeviceChangeType.CONNECT) {
        // 只记日志，便于现场诊断（如手表连接时到底上报了什么设备）
        for (let i = 0; i < devices.length; i++) {
          const d: audio.AudioDeviceDescriptor = devices[i];
          if (isBluetoothDevice(d.deviceType)) {
            console.info(`bluetooth device connected: ${deviceLabelOf(d)} (type ${d.deviceType})`);
          }
        }
        return;
      }
      if (action.type !== audio.DeviceChangeType.DISCONNECT) {
        return;
      }
      let bluetoothGone: boolean = false;
      for (let i = 0; i < devices.length; i++) {
        const d: audio.AudioDeviceDescriptor = devices[i];
        if (!isBluetoothDevice(d.deviceType)) {
          continue;
        }
        if (looksLikeWearable(d)) {
          // 手表/手环的连接抖动：不是耳机断开，别停
          console.info(`wearable device change ignored: ${deviceLabelOf(d)} (type ${d.deviceType})`);
          continue;
        }
        console.info(`bluetooth audio device disconnected: ${deviceLabelOf(d)} (type ${d.deviceType})`);
        bluetoothGone = true;
      }
      if (!bluetoothGone) {
        return;
      }
      // 剩余设备核查：仍有「非手表」蓝牙音频在连 → 断开没有移走音频通路，不暂停
      if (hasRemainingBluetoothAudio()) {
        console.info('bluetooth audio disconnect ignored: another bluetooth audio device still present');
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
