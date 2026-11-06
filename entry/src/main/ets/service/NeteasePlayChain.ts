/**
 * 网易云歌单「播放全部」渐进式连播服务（单例）。
 *
 * 填充策略：首曲起播后后台循环逐首匹配入队 —— 每入队一首歇
 * CHAIN_FILL_INTERVAL_MS 再配下一首，直到整个歌单填满。不一次全加：
 * 整单连发请求必撞 B 站风控（真机史见 PlaylistImporter.isRiskError 注释），
 * 间隔拉开请求密度；也不一曲一配（队列里永远只多一首，填充进度不可见）。
 *   1. start() 向前扫描匹配首首可播放歌曲（无 B 站音源 / 匹配异常自动跳过，
 *      直到首中，1~2s 起播），**接管队列**（setQueue([track])，
 *      播放全部 = 旧队列让位，与 playAll 同语义 —— 不接管的话 playNow 前插
 *      会把旧队列曲目横在链曲与预匹配曲之间，首曲播完 next() 放的是旧歌，
 *      bvid 不在链集合被误判「播了链外的歌」而断链，后续全不预匹配）；
 *   2. playNow 落定后 start() 直接触发填充循环（prematchNext 单飞闸门防重
 *      入，store 监听触发只作兜底）—— 播放列表里歌一首首多出来；
 *   3. 撞风控（HTTP 412）退避 CHAIN_RISK_BACKOFF_MS 后重试同首，连续
 *      CHAIN_RISK_MAX_STREAK 次仍风控才停链（已入队的歌继续播）；
 *   4. 无音源 / 匹配异常跳过继续，跳过串按 CHAIN_MATCH_GAP_MS 节流、连续
 *      CHAIN_MISS_BREAKER 首未命中即熔断止损（见 start 首曲扫描与 prematchNext）。
 *
 * 链追踪按 **bvid 集合**而不是 track.id：playNow 会把多 P 合集铺进队列
 * （分 P id = `bvid#cid`），按 id 判「播了链外的歌」会在分 P 切换时误断链；
 * bvid 恒同（MusicModels 约定），天然兼容。
 *
 * 生命周期：监听器挂本单例上，**跨页面存续** —— 离开网易云预览页继续连播；
 * 用户手点条目 / 在别处播歌（STORE_CURRENT_TRACK 换成链外 bvid）/ 清队列
 * （currentTrack 置 null）时自动断链。断链只翻 active 标志并递增 startSeq
 * （作废在途 start 匹配落定后的续行，不抢播），不动播放队列
 * （已播的歌留在队列里继续可用）。
 *
 * 可观测性：提示与关键节点（开始 / 入队 / 跳过 / 异常 / 熔断）均进应用内
 * 「日志记录」页（recordPlaybackLog），真机复现故障无需 hilog 即可对照定位。
 *
 * 提示通道：与 MusicPlayer.notifyHint 同款，统一走 common/ToastChannel
 *（notifyPlaybackHint：toast + 日志留痕；.ts 不能 import .ets 的
 * showAppToast 组件，通道契约见 AppToast.ets 头注释）。
 */

import {
  ExternalSong,
  matchSongForPlayback,
  ImportTaskManager
} from './PlaylistImporter';
import { MusicPlayer } from '../player/MusicPlayer';
import { Track } from '../model/MusicModels';
import { STORE_CURRENT_TRACK } from '../common/Constants';
import { notifyPlaybackHint } from '../common/ToastChannel';
import { sleep } from '../utils/AsyncUtil';
import { PLAYBACK_LOG_INFO, recordPlaybackLog } from './PlaybackLogStore';

/**
 * 预匹配最小请求间隔（ms）：对齐导入任务 MATCH_MIN_GAP_MS。正常连播一首一配
 * （间隔分钟级）此闸近零等待；跳过串（连续无音源 / 异常）由此拉开间隔，
 * 不再背靠背连发 —— 真机史（PlaylistImporter.isRiskError 注释）：请求突发
 * 极易撞 B 站风控（HTTP 412），撞上后逐首失败全被误标「无音源」。
 */
const CHAIN_MATCH_GAP_MS = 800;
/**
 * 连续未命中（无音源 / 匹配异常）多少首熔断停链：真命中长串无源歌单属小概率，
 * 连续 10 首失败更像风控 / 搜索通道故障 —— 止损停链并明确提示优于静默跑完。
 */
const CHAIN_MISS_BREAKER = 10;
/**
 * 渐进填充间隔（ms）：入队成功一首后距下一次匹配发起的等待。拉开请求密度
 * 不整单连发；3s 一首，268 首级大歌单约 13 分钟填满。
 */
const CHAIN_FILL_INTERVAL_MS = 3000;
/**
 * 撞风控（HTTP 412）后的退避时长（ms）：期间已入队歌曲正常播放，退避结束
 * 重试同一首（不推进 cursor）。
 */
const CHAIN_RISK_BACKOFF_MS = 60000;
/**
 * 连续撞风控多少次彻底停链：首次退避重试，再撞即停（不无限重试）。
 */
const CHAIN_RISK_MAX_STREAK = 2;

export class NeteasePlayChain {
  private static instance: NeteasePlayChain | null = null;

  static getInstance(): NeteasePlayChain {
    if (NeteasePlayChain.instance === null) {
      NeteasePlayChain.instance = new NeteasePlayChain();
    }
    return NeteasePlayChain.instance;
  }

  private constructor() {
    this.player.addCardSyncListener(this.storeListener);
  }

  private player: MusicPlayer = MusicPlayer.getInstance();

  /** 连播目标曲目快照（start 时 slice，页面后续刷新不影响在途链） */
  private songs: ExternalSong[] = [];
  /** 已入队（或已尝试跳过）的最后一首下标，-1 = 还没起播 */
  private cursor: number = -1;
  /** 链是否在管播放（false = 断链 / 未启动，队列里的歌不受影响） */
  private active: boolean = false;
  /** 预匹配单飞闸门：listener 高频触发（IS_PLAYING / PROGRESS 也会进来外层过滤后）防重入 */
  private prematching: boolean = false;
  /** 链上曲目 bvid 集合（含已播完的）：分 P 展开同 bvid，天然兼容 */
  private chainedBvids: Set<string> = new Set();
  /** 无 B 站音源被跳过的歌曲数（链走完时一次性 toast） */
  private skipped: number = 0;
  /** 启动代际：cancel / 重新 start 递增，在途 start 匹配落定后据此自弃 */
  private startSeq: number = 0;
  /** 上次搜索请求发起时刻（CHAIN_MATCH_GAP_MS 节流基准） */
  private lastMatchAt: number = 0;
  /** 连续未命中计数（达 CHAIN_MISS_BREAKER 熔断停链） */
  private missStreak: number = 0;
  /** 连续撞风控计数（达 CHAIN_RISK_MAX_STREAK 停链；成功入队清零） */
  private riskStreak: number = 0;

  /** 链是否在管理播放（页面据此决定「正在连播」提示） */
  isActive(): boolean {
    return this.active;
  }

  /**
   * 启动连播：向前扫描匹配首首可播放歌曲并 playNow（无 B 站音源 / 匹配异常
   * 的歌曲自动跳过，节流 / 风控退避 / 熔断与 prematchNext 同款），store 监听
   * 接管后续预匹配。
   * 已在连播中再次 start = 换歌单 / 重播语义（先断旧链再起）。
   * 返回的 Promise 在**首曲起播落定**（或整单无源 / 熔断终止）后 resolve
   * （页面用它清 CTA loading 态；链终止时已自断并提示，Promise 照常 resolve
   * 不 reject）。
   */
  async start(songs: ExternalSong[]): Promise<void> {
    if (songs.length === 0) {
      return;
    }
    if (this.active) {
      this.cancel();
    }
    // 代际守卫：cancel / 新 start 都递增 startSeq —— 扫描窗口（含每次 await：
    // 节流 / 匹配 / 风控退避）内若已被取代（用户点了单曲 / 重新点了播放全部），
    // 直接自弃，不得抢播。⚠️ 不能用 !this.active 作守卫：首中前 active 恒为
    // false，cancel() 递增 startSeq 才是作废在途扫描的依据。
    const seq: number = ++this.startSeq;
    this.songs = songs.slice();
    this.cursor = -1;
    this.skipped = 0;
    this.missStreak = 0;
    this.riskStreak = 0;
    this.chainedBvids.clear();
    this.lastMatchAt = Date.now();
    // 首曲向前扫描：无音源 / 异常跳过继续（跳过串按 CHAIN_MATCH_GAP_MS 节流），
    // 连续 CHAIN_MISS_BREAKER 首未命中熔断止损；撞风控退避 CHAIN_RISK_BACKOFF_MS
    // 重试同首，连续 CHAIN_RISK_MAX_STREAK 次仍风控即停 —— 容错语义与
    // prematchNext 一致。
    while (this.cursor + 1 < this.songs.length) {
      const next: ExternalSong = this.songs[this.cursor + 1];
      await this.waitMatchGap();
      if (seq !== this.startSeq) {
        return;
      }
      let track: Track | null = null;
      try {
        track = await matchSongForPlayback(next);
      } catch (e) {
        if (ImportTaskManager.isRiskError(e)) {
          this.riskStreak++;
          if (this.riskStreak >= CHAIN_RISK_MAX_STREAK) {
            this.notifyHint('触发 B 站风控，连播已停止', 2600);
            this.cancel();
            return;
          }
          // 首次风控：退避后重试同首（不推进 cursor）。退避中 cancel（点播 /
          // 清队列 / 重开连播）→ 醒来自弃。
          this.notifyHint('触发 B 站风控，60 秒后自动重试', 2200);
          this.log(`连播匹配「${next.title}」撞风控，退避重试`);
          await sleep(CHAIN_RISK_BACKOFF_MS);
          if (seq !== this.startSeq) {
            return;
          }
          continue;
        }
        // 其它异常（网络抖动等）：按无音源跳过，不让单首故障打断整链
        const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
        console.error(`netease play chain start match failed: ${detail}`);
        this.log(`连播匹配异常「${next.title}」：${detail}`);
      }
      if (seq !== this.startSeq) {
        return;
      }
      if (track === null) {
        // 没找到 B 站音源（含异常跳过）：跳过继续（计数并入链尾统一报数）
        this.skipped++;
        this.missStreak++;
        this.cursor++;
        this.log(`连播跳过「${next.title}」（无 B 站音源）`);
        if (this.missStreak >= CHAIN_MISS_BREAKER) {
          this.cancel();
          this.notifyHint('连续多首未找到 B 站音源，连播已停止', 2600);
          return;
        }
        continue;
      }
      // 队列接管：播放全部 = 旧队列让位（与 playAll 同语义）。setQueue([track])
      // 后 playNow 去重前插结果仍为 [track]，expandMultiParts 合集铺开（多 P）
      // 与落盘逻辑全部保留。active 延后到这里才挂闸：扫描窗口内旧歌自动切歌等
      // CURRENT_TRACK 变化不误伤断链（storeListener 判 active）。
      this.cursor++;
      this.missStreak = 0;
      this.riskStreak = 0;
      this.active = true;
      this.chainedBvids.add(track.bvid);
      this.player.setQueue([track]);
      this.player.playNow(track);
      this.log(`连播开始「${next.title}」`);
      // 首曲落定即起渐进填充循环（不并入本 Promise：页面 CTA loading 只等首曲）。
      // 不依赖 playNow 乐观写 store 触发监听 —— 在播曲目恰好同曲时监听不触发，
      // 填充就永远起不来。
      this.prematchNext();
      return;
    }
    // 整单扫描完毕仍无可播放歌曲：断链并明确提示（skipped 已在循环内计数）。
    this.cancel();
    this.notifyHint('歌单内没有可播放的 B 站音源', 2600);
  }

  /**
   * 断链（只翻标志，不动队列与在播曲目）。递增 startSeq 作废在途 start 的
   * 续行：用户在首曲匹配窗口内点单曲 / 重新点播放全部时，旧 start 落定后
   * 不得再抢播。
   */
  cancel(): void {
    this.active = false;
    this.startSeq++;
  }

  /**
   * 播放内核 store 写入钩子（addCardSyncListener 注册一次，构造即挂）：
   * 只关心 STORE_CURRENT_TRACK —— 在播曲目变化是「链还该继续」还是
   * 「用户播了链外的歌该断链」的唯一判定源。
   *
   * ⚠️ 末尾的 prematchNext() 兜底触发**看似冗余、删之必坏**：新链 start()
   * 直接触发填充时，旧链循环可能仍持有 prematching 单飞闸门（3s 填充等待 /
   * 60s 风控退避中尚未退出），直接调用被闸门吞掉、新链无人填充；新链首曲
   * 落定触发本监听（CURRENT_TRACK 变化）→ 此时旧循环多已退出 → 兜底补起
   * 填充循环。闸门占用期间的重复调用由 prematching 防重入，无副作用。
   */
  private storeListener = (key: string): void => {
    if (!this.active || key !== STORE_CURRENT_TRACK) {
      return;
    }
    const cur: Track | null = AppStorage.get<Track>(STORE_CURRENT_TRACK) ?? null;
    if (cur === null) {
      // 清队列（clearQueue 置 null）：链无继续的意义
      this.cancel();
      return;
    }
    if (!this.chainedBvids.has(cur.bvid)) {
      // 用户手点条目 / 别处点播：手动操作优先，自动让位断链
      this.cancel();
      return;
    }
    this.prematchNext();
  };

  /**
   * 渐进填充（单飞）：入队成功一首歇 CHAIN_FILL_INTERVAL_MS 再配下一首，
   * 直到填满歌单（循环尾收链）或断链（active 翻假后各检查点自停）。
   * 无音源 / 匹配异常的歌曲跳过继续找；跳过串按 CHAIN_MATCH_GAP_MS 节流
   * （不背靠背连发诱发风控），连续 CHAIN_MISS_BREAKER 首未命中熔断止损；
   * 撞风控退避 CHAIN_RISK_BACKOFF_MS 重试同首，连续 CHAIN_RISK_MAX_STREAK
   * 次仍风控即停链。
   */
  private async prematchNext(): Promise<void> {
    if (this.prematching) {
      return;
    }
    this.prematching = true;
    try {
      while (this.active && this.cursor + 1 < this.songs.length) {
        const next: ExternalSong = this.songs[this.cursor + 1];
        // 节流：距上次请求不足间隔则补足。等待期间可能被 cancel（用户点播 /
        // 清队列），醒来先查 active 再继续，不向死链发请求。
        await this.waitMatchGap();
        if (!this.active) {
          return;
        }
        let track: Track | null = null;
        try {
          track = await matchSongForPlayback(next);
        } catch (e) {
          if (ImportTaskManager.isRiskError(e)) {
            this.riskStreak++;
            if (this.riskStreak >= CHAIN_RISK_MAX_STREAK) {
              this.notifyHint('触发 B 站风控，连播已停止', 2600);
              this.cancel();
              return;
            }
            // 首次风控：退避后重试同首（不推进 cursor）。期间已入队歌曲正常
            // 播放；退避中 cancel（点播 / 清队列）→ 醒来自弃。
            this.notifyHint('触发 B 站风控，60 秒后自动重试', 2200);
            this.log(`连播匹配「${next.title}」撞风控，退避重试`);
            await sleep(CHAIN_RISK_BACKOFF_MS);
            if (!this.active) {
              return;
            }
            continue;
          }
          // 其它异常（网络抖动等）：按无音源跳过，不让单首故障打断整链
          const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
          console.error(`netease play chain prematch failed: ${detail}`);
          this.log(`连播匹配异常「${next.title}」：${detail}`);
        }
        if (track === null) {
          // 没找到 B 站音源（含异常跳过）：跳过继续（链走完时统一报数）
          this.skipped++;
          this.missStreak++;
          this.cursor++;
          this.log(`连播跳过「${next.title}」（无 B 站音源）`);
          if (this.missStreak >= CHAIN_MISS_BREAKER) {
            this.cancel();
            this.notifyHint('连续多首未找到 B 站音源，连播已停止', 2600);
            return;
          }
          continue;
        }
        this.cursor++;
        this.missStreak = 0;
        this.riskStreak = 0;
        this.chainedBvids.add(track.bvid);
        this.player.addToQueue(track);
        this.log(`连播入队「${next.title}」`);
        // 渐进填充：歇 CHAIN_FILL_INTERVAL_MS 再配下一首（拉开请求密度）。
        // 等待期间可能被 cancel（点播 / 清队列），醒来自弃。
        await sleep(CHAIN_FILL_INTERVAL_MS);
        if (!this.active) {
          return;
        }
        continue;
      }
      // 列表素材备完：收链（active=false 后 listener 空转），跳过数一次性报
      this.cancel();
      if (this.skipped > 0) {
        this.notifyHint(`已跳过 ${this.skipped} 首无 B 站音源的歌曲`, 1800);
      }
    } finally {
      this.prematching = false;
    }
  }

  /**
   * 预匹配节流：保证相邻两次搜索请求发起间隔 ≥ CHAIN_MATCH_GAP_MS。
   * 正常连播一首歌一配（间隔分钟级），此闸近零等待；跳过串由此拉开间隔。
   */
  private async waitMatchGap(): Promise<void> {
    const waitMs: number = CHAIN_MATCH_GAP_MS - (Date.now() - this.lastMatchAt);
    if (waitMs > 0) {
      await sleep(waitMs);
    }
    this.lastMatchAt = Date.now();
  }

  /**
   * 轻提示（与 MusicPlayer.notifyHint 同通道，统一走 common/ToastChannel：
   * toast + 「日志记录」页留痕）。真机复现连播故障时可对照「当时弹了什么」。
   */
  private notifyHint(message: string, holdMs: number): void {
    notifyPlaybackHint(message, holdMs);
  }

  /** 应用内「日志记录」页留痕（INFO）：连播关键节点，无需 hilog 即可定位 */
  private log(message: string): void {
    recordPlaybackLog(PLAYBACK_LOG_INFO, message);
  }
}
