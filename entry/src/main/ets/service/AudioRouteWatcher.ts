/**
 * 音频路由监听：**本机音乐流的输出设备从蓝牙切到非蓝牙（且蓝牙确实断开）时暂停播放**。
 *
 * 为什么需要：
 * 手机通过蓝牙耳机出声时，用户摘掉耳机 / 耳机断电，系统会把音频**切到扬声器继续播**——
 * 「耳边突然外放」是体验事故，多数音乐 App 的做法是耳机断开即暂停（而不是默默外放）。
 * 本模块就是补上这一条。
 *
 * 关键设计（都是踩过的坑）：
 *  1. **监听「音乐流首选输出设备」，不再用全局设备上下线**：早期版本用
 *     `on('deviceChange', OUTPUT_DEVICES_FLAG)` 做判据，但官方 FAQ（faqs-audio-17）
 *     明确指出它监听的是全局输入输出设备的连接状态、不与音频流绑定，不建议作为
 *     自动暂停的依据。实测缺陷正是本题：蓝牙设备连着、但音乐走手机扬声器外放时，
 *     锁屏瞬间系统回收闲置的蓝牙音频通路（A2DP/SCO 下线），全局断开事件照发 ——
 *     「根本没在用蓝牙」也被误停。现改用 `on('preferOutputDeviceChangeForRendererInfo')`
 *     （API 10+）：它只盯「STREAM_USAGE_MUSIC 的声音实际从哪个设备出」，音乐流的
 *     输出设备没变就不会触发 —— 闲置蓝牙通路的上下线与本判据无关。
 *     （播放内核用 AVPlayer，不持有 AudioRenderer 实例，挂不上
 *     on('outputDeviceChangeWithInfo')；AudioSession 方案（API 20+）需常驻激活
 *     会话、牵动焦点语义，仅「与其他应用同时播放」开关在用，故此处不采用。）
 *  2. **只认「蓝牙 → 非蓝牙」的迁移**：回调只带新设备列表，配合内部缓存的旧状态，
 *     仅在「原来是蓝牙、现在不是」时进入暂停判定；蓝牙 ↔ 蓝牙（多个蓝牙设备间
 *     切换，声音还在蓝牙上）、非蓝牙 → 蓝牙（连上耳机不自动续播，产品决策）只记日志。
 *  3. **区分「真断开」与「用户强选到扬声器」**：首选输出蓝牙 → 扬声器有两种原因 ——
 *     蓝牙设备断开（该暂停）或用户在播控中心把输出切到扬声器（不该暂停，人家故意
 *     外放）。判据：迁移发生后查一遍当前仍连接的输出设备，还有「非手表」的蓝牙
 *     音频设备在连 → 设备没断，只是强选，不暂停；全没了 → 真断开，通知暂停。
 *     查询异常时保守回退为「触发暂停」—— 宁可多停一次，不可丢掉防外放能力。
 *  4. **排除手表 / 手环**：`DeviceType` 没有手表专用类型，手表注册 HFP/SCO 通话链路
 *     或 BT 协议栈重协商时，音频框架同样上报蓝牙设备变化。设备名（需 ACCESS_BLUETOOTH
 *     权限，见 module.json5）命中 watch/手表/band/手环/gts/gtr → 按穿戴设备处理，
 *     不参与蓝牙判据（覆盖 HUAWEI WATCH、Apple Watch、Mi Band、Amazfit GTS/GTR 等）。
 *  5. **回调解引用**：`off()` 必须传与 `on()` 相同的函数引用才能退订，
 *     所以把它存成成员（见 listener）。
 *  6. **全程 try/catch**：音频设备查询在部分设备/权限下会抛，监听失败绝不能影响播放。
 *
 * 生命周期：`MusicPlayer.init()` 里启动（整个 App 只需一份），不随页面销毁。
 */

import { audio } from '@kit.AudioKit';

/** 蓝牙输出设备断开时的回调（由播放内核注入，内部负责暂停） */
type BluetoothLostHandler = () => void;

/**
 * 手表 / 手环设备名关键词（小写匹配）。
 * 选取原则：只收几乎只出现在穿戴设备上的词，避开 fit/wear 等可能误伤音箱耳机的词；
 * 耳机音箱常见命名（Buds/Headphones/Pods/TWS/Speaker）均不命中。
 */
const WEARABLE_NAME_KEYWORDS: string[] = ['watch', '手表', 'band', '手环', 'gts', 'gtr'];

/** 本 App 音乐流的渲染器信息（与 MusicPlayer.applyRendererInfoInInitialized 同口径，判据必须对准真正的播放流） */
const MEDIA_RENDERER_INFO: audio.AudioRendererInfo = {
  usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
  rendererFlags: 0
};

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

/** 设备列表里是否含「非手表手环」的蓝牙音频设备（空列表 / null = false）。 */
function containsBluetoothAudio(devices: audio.AudioDeviceDescriptors | null): boolean {
  if (!devices) {
    return false;
  }
  for (let i = 0; i < devices.length; i++) {
    const d: audio.AudioDeviceDescriptor = devices[i];
    if (isBluetoothDevice(d.deviceType) && !looksLikeWearable(d)) {
      return true;
    }
  }
  return false;
}

/**
 * 首选输出「蓝牙 → 非蓝牙」迁移发生后核查：当前已连接的输出设备里，是否还存在
 * 「非手表」的蓝牙音频设备。存在 → 设备没断，是用户把输出强选到了扬声器（不该暂停）；
 * 全没了 → 蓝牙真断开（该暂停）。查询失败 → 返回 false，调用方保守回退为「触发暂停」。
 */
function hasRemainingBluetoothAudio(): boolean {
  try {
    const routing: audio.AudioRoutingManager = audio.getAudioManager().getRoutingManager();
    return containsBluetoothAudio(routing.getDevicesSync(audio.DeviceFlag.OUTPUT_DEVICES_FLAG));
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
  private listener: ((devices: audio.AudioDeviceDescriptors) => void) | null = null;
  /**
   * 最近一次已知的「音乐流首选输出是蓝牙」（启动时同步查询初始化，之后只在事件
   * 回调里翻转）。事件回调只带新设备，迁移判据的「旧值」必须靠它 —— 断开发生后
   * 再查当前首选输出已经是扬声器，无法回推「刚才是不是在用蓝牙」。
   */
  private preferredIsBluetooth: boolean = false;

  static getInstance(): AudioRouteWatcher {
    if (AudioRouteWatcher.instance === null) {
      AudioRouteWatcher.instance = new AudioRouteWatcher();
    }
    return AudioRouteWatcher.instance;
  }

  /** 查询当前音乐流首选输出是否蓝牙（getPreferredOutputDeviceForRendererInfoSync，API 10+）。 */
  private queryPreferredIsBluetooth(routing: audio.AudioRoutingManager): boolean {
    try {
      return containsBluetoothAudio(routing.getPreferredOutputDeviceForRendererInfoSync(MEDIA_RENDERER_INFO));
    } catch (e) {
      // 查询失败按「非蓝牙」起步：宁可漏停一次（保持现状），不可没断开就停
      const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.warn(`query preferred output device failed: ${detail}`);
      return false;
    }
  }

  /**
    * 开始监听（幂等）。回调在**音乐流输出设备从蓝牙切走、且蓝牙设备确实断开**
    * （排除用户强选扬声器、手表手环扰动）时触发。
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
      // SDK `@ohos.multimedia.audio.d.ts`），**不在** `audio` 命名空间的顶层 ——
      // 写 `audio.getRoutingManager()` 编译直接报「does not exist on type 'typeof audio'」。
      const routing: audio.AudioRoutingManager = audio.getAudioManager().getRoutingManager();
      this.preferredIsBluetooth = this.queryPreferredIsBluetooth(routing);
      this.listener = (devices: audio.AudioDeviceDescriptors): void => {
        this.handlePreferredChange(devices);
      };
      routing.on('preferOutputDeviceChangeForRendererInfo', MEDIA_RENDERER_INFO, this.listener);
      this.started = true;
      console.info(`AudioRouteWatcher started (music stream preferred output: ${this.preferredIsBluetooth ? 'bluetooth' : 'non-bluetooth'})`);
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
      routing.off('preferOutputDeviceChangeForRendererInfo', this.listener);
    } catch (e) {
      const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.warn(`AudioRouteWatcher stop failed: ${detail}`);
    }
    this.started = false;
    this.listener = null;
    this.handler = null;
  }

  /**
   * 音乐流首选输出设备变化回调（回调只带**新**设备列表）。
   *
   * · 「蓝牙 → 非蓝牙」迁移才可能暂停：仍连着别的蓝牙音频 → 用户强选扬声器，忽略；
   *   蓝牙全断 → 通知（真正该暂停的场景）。
   * · 「非蓝牙 → 蓝牙」/ 蓝牙之间切换：只记日志（连上耳机不自动续播，声音还在蓝牙
   *   上时更不该停）。
   */
  private handlePreferredChange(devices: audio.AudioDeviceDescriptors): void {
    try {
      const wasBluetooth: boolean = this.preferredIsBluetooth;
      const nowBluetooth: boolean = containsBluetoothAudio(devices);
      this.preferredIsBluetooth = nowBluetooth;
      // 只记日志，便于现场诊断（如手表连接时音乐流首选输出到底是谁）
      if (devices) {
        for (let i = 0; i < devices.length; i++) {
          const d: audio.AudioDeviceDescriptor = devices[i];
          console.info(`music stream preferred output: ${deviceLabelOf(d)} (type ${d.deviceType})`);
        }
      }
      if (!wasBluetooth || nowBluetooth) {
        return;
      }
      // 蓝牙 → 非蓝牙：仍有「非手表」蓝牙音频在连 → 是用户强选到扬声器，不是断开
      if (hasRemainingBluetoothAudio()) {
        console.info('preferred output left bluetooth but a bluetooth audio device is still connected (user override) -> keep playing');
        return;
      }
      console.info('bluetooth output lost while routed to bluetooth -> notify pause');
      const handler: BluetoothLostHandler | null = this.handler;
      if (handler) {
        handler();
      }
    } catch (e) {
      const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`handlePreferredChange failed: ${detail}`);
    }
  }
}
