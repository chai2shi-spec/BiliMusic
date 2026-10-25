/**
 * B 站请求全局节流闸门。
 *
 * 问题：预取下一首、页面列表刷新、导入任务同刻并发形成请求尖峰，
 * 登录账号对尖峰尤其敏感，点歌链（view → playurl）频繁吃
 * -352/-412/-509/-799 / HTTP 412。退避重试与匿名降级都是
 * 「撞了再救」，本闸门负责「少撞」：所有 B 站域请求在 HttpUtil 三个入口
 * 处排队（acquire → 请求 → finally release），四个机制：
 *
 * 1. 节流：相邻两次实际发送 ≥ BILI_GATE_MIN_INTERVAL_MS + 随机抖动
 *    （BILI_GATE_JITTER_MS），打散固定机器节拍；
 * 2. 并发上限：同时在途 ≤ BILI_GATE_MAX_CONCURRENCY，削平尖峰；
 * 3. 高优先双通道：播放链端点（view / playurl / spi 自愈）按 URL 前缀
 *    插队先出队 —— 节流不拖慢点歌出声；零调用点改动；
 * 4. 风控熔断：HttpUtil 探测到风控信号（HTTP 412/403/429，或响应体前缀
 *    `{"code":-352/-412/-509/-799`）上报 noteRisk → 全局冷却
 *    （BILI_GATE_COOLDOWN_STEPS_MS 阶梯升级），冷却期暂停出队、
 *    **排队顺延不丢弃**；任一干净成功 noteSuccess 复位阶梯。
 *
 * 域名过滤（isBiliUrl）：api.bilibili.com / passport.bilibili.com /
 * *.bilibili.com / b23.tv 分享短链；歌词 API（OIAPI）等第三方直发不受影响。
 * 与既有链路互补：闸门少触发，BilibiliApi 的退避 / wbi 回退 / 匿名降级、
 * MusicPlayer 的 buvid 自愈继续兜底。
 */

import hilog from '@ohos.hilog';
import {
  BILI_API,
  BILI_PASSPORT,
  BILI_GATE_MIN_INTERVAL_MS,
  BILI_GATE_JITTER_MS,
  BILI_GATE_MAX_CONCURRENCY,
  BILI_GATE_COOLDOWN_STEPS_MS
} from '../common/Constants';

/** 排队条目：解析回调 + 是否高优先（高优先出队时插队） */
interface GateEntry {
  high: boolean;
  resolve: () => void;
}

/** 播放链高优先端点（URL 含即插队）：点歌出声 + buvid 自愈不允许被列表刷新垫在后面 */
const HIGH_PATHS: string[] = [
  '/x/web-interface/view',
  '/x/player/playurl',
  '/x/player/wbi/playurl',
  // TV 端兜底：只在 Web 双通道都失败后才会发，本身就是
  // 「已经多等了两轮」的最后一级，不能被队列再垫一次
  '/x/tv/playurl',
  'finger/spi'
];

export class BiliRequestGate {
  /** 等待队列（正常优先按序追加，高优先出队时前插扫描） */
  private static queue: GateEntry[] = [];
  /** 当前在途请求数 */
  private static inFlight: number = 0;
  /** 下一次允许发送的最早时刻（Date.now()）：实现最小间隔 + 抖动 */
  private static nextSendAt: number = 0;
  /** 熔断冷却截止时刻（Date.now()）；0 = 未在冷却 */
  private static cooldownUntil: number = 0;
  /** 连续风控命中档位（0 起，进 BILI_GATE_COOLDOWN_STEPS_MS 取冷却时长） */
  private static riskLevel: number = 0;
  /** pump 调度定时器句柄；-1 = 无待触发调度 */
  private static pumpTimer: number = -1;
  /** 队列深度高水位（只在创新高时打日志，避免刷屏） */
  private static queueHighWater: number = 0;

  /** 是否 B 站域请求（需过闸门）：api / passport / 任意 bilibili.com 子域 / b23.tv 短链 */
  static isBiliUrl(url: string): boolean {
    return url.indexOf(BILI_API) === 0 || url.indexOf(BILI_PASSPORT) === 0 ||
      url.indexOf('bilibili.com') >= 0 || url.indexOf('b23.tv') >= 0;
  }

  /** 是否播放链高优先请求（插队出队，见 HIGH_PATHS 注释） */
  static isHighPriority(url: string): boolean {
    for (let i = 0; i < HIGH_PATHS.length; i++) {
      if (url.indexOf(HIGH_PATHS[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 排队取发送权：非 B 站 URL 直接放行（返回 false，调用方不必 release）。
   * B 站 URL 返回 true 并在获得名额时 resolve —— 调用方必须在 finally 里
   * release(url)。冷却期与名额满时挂起等待，由 pump 定时驱动放行。
   */
  static acquire(url: string): Promise<boolean> {
    if (!BiliRequestGate.isBiliUrl(url)) {
      return Promise.resolve<boolean>(false);
    }
    return new Promise<boolean>((resolve: (gated: boolean) => void): void => {
      const entry: GateEntry = {
        high: BiliRequestGate.isHighPriority(url),
        resolve: (): void => {
          resolve(true);
        }
      };
      BiliRequestGate.queue.push(entry);
      if (BiliRequestGate.queue.length > BiliRequestGate.queueHighWater) {
        BiliRequestGate.queueHighWater = BiliRequestGate.queue.length;
        hilog.info(0x0000, 'BiliRequestGate',
          'queue highWater=%{public}d inFlight=%{public}d cooldownLeft=%{public}d',
          BiliRequestGate.queueHighWater, BiliRequestGate.inFlight,
          Math.max(0, BiliRequestGate.cooldownUntil - Date.now()));
      }
      BiliRequestGate.schedulePump();
    });
  }

  /** 归还发送名额（finally 里调用），并尝试立刻放行下一位 */
  static release(url: string): void {
    if (!BiliRequestGate.isBiliUrl(url)) {
      return;
    }
    if (BiliRequestGate.inFlight > 0) {
      BiliRequestGate.inFlight--;
    }
    BiliRequestGate.schedulePump();
  }

  /**
   * 上报风控信号（HttpUtil 探测到 HTTP 412/403/429 或业务码 -352/-412/-509/-799）：
   * 开 / 升级全局冷却。连续命中逐级拉长（阶梯见 BILI_GATE_COOLDOWN_STEPS_MS），
   * noteSuccess 复位。冷却只暂停出队，排队请求顺延不丢弃。
   */
  static noteRisk(): void {
    const step: number = Math.min(BiliRequestGate.riskLevel, BILI_GATE_COOLDOWN_STEPS_MS.length - 1);
    const ms: number = BILI_GATE_COOLDOWN_STEPS_MS[step];
    BiliRequestGate.cooldownUntil = Math.max(BiliRequestGate.cooldownUntil, Date.now() + ms);
    hilog.warn(0x0000, 'BiliRequestGate',
      'risk hit, cooldown=%{public}dms level=%{public}d -> %{public}d',
      ms, BiliRequestGate.riskLevel, BiliRequestGate.riskLevel + 1);
    BiliRequestGate.riskLevel++;
    BiliRequestGate.schedulePump();
  }

  /** 上报干净成功：冷却阶梯复位（下一个风控信号从最短档重新起算） */
  static noteSuccess(): void {
    if (BiliRequestGate.riskLevel > 0) {
      hilog.info(0x0000, 'BiliRequestGate', 'clean success, riskLevel reset from %{public}d',
        BiliRequestGate.riskLevel);
    }
    BiliRequestGate.riskLevel = 0;
  }

  /**
   * 调度 pump：确保有一个定时器在未来最近的「可出队时刻」触发。
   * 可出队时刻 = max(下次可发送时刻, 冷却截止)。已在途/队列空时定时器
   * 到点后自然空转，无副作用。句柄判 -1 防重复调度。
   */
  private static schedulePump(): void {
    if (BiliRequestGate.pumpTimer >= 0) {
      return;
    }
    const readyAt: number = Math.max(BiliRequestGate.nextSendAt, BiliRequestGate.cooldownUntil);
    const delay: number = Math.max(0, readyAt - Date.now());
    BiliRequestGate.pumpTimer = setTimeout((): void => {
      BiliRequestGate.pumpTimer = -1;
      BiliRequestGate.pump();
    }, delay);
  }

  /**
   * 出队泵：有名额、不在冷却、且到达下次可发送时刻时，高优先条目先出队
   * （保点歌出声延迟），否则队首出队；每次授予后把 nextSendAt 推到
   * 「现在 + 最小间隔 + 随机抖动」，while 条件随即不成立 —— 一次 tick
   * 只放行一个，间隔由 schedulePump 的定时器保证。队列还有剩则续调度。
   */
  private static pump(): void {
    while (BiliRequestGate.queue.length > 0 &&
      BiliRequestGate.inFlight < BILI_GATE_MAX_CONCURRENCY &&
      Date.now() >= BiliRequestGate.nextSendAt &&
      Date.now() >= BiliRequestGate.cooldownUntil) {
      let index: number = 0;
      for (let i = 0; i < BiliRequestGate.queue.length; i++) {
        if (BiliRequestGate.queue[i].high) {
          index = i;
          break;
        }
      }
      const entry: GateEntry = BiliRequestGate.queue.splice(index, 1)[0];
      BiliRequestGate.inFlight++;
      BiliRequestGate.nextSendAt = Date.now() + BILI_GATE_MIN_INTERVAL_MS +
        Math.floor(Math.random() * BILI_GATE_JITTER_MS);
      entry.resolve();
    }
    if (BiliRequestGate.queue.length > 0) {
      BiliRequestGate.schedulePump();
    }
  }
}
