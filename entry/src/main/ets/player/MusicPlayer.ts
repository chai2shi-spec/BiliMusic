/**
 * 播放核心（原生 ArkTS 版）。
 * 使用 @ohos.multimedia.media (AVPlayer) + @ohos.multimedia.avsession (AVSession)。
 * - 通过 setMediaSource 在请求头注入 Referer（B 站音频流必需）
 * - AVSession 负责锁屏 / 通知栏 / 媒体中心（控制中心卡片，HiCar 车机卡片同源）的显示与遥控
 * - 状态写入 AppStorage，UI 用 @StorageLink 订阅
 *
 * 移植自原 React 版 PlayerContext.tsx 的队列 / 播放模式 / 进度逻辑。
 */

import { media } from '@kit.MediaKit';
import { avSession } from '@kit.AVSessionKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { audio } from '@kit.AudioKit';
import { image } from '@kit.ImageKit';
import http from '@ohos.net.http';
import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import common from '@ohos.app.ability.common';
import { BiliApiError, extractAudioFromVideo, expandVideoParts, qualityDowngradePlan } from '../api/BilibiliApi';
import { getLyricForTrack } from '../api/LyricsApi';
import { LibraryStore } from '../service/LibraryStore';
import { DownloadManager } from '../service/DownloadManager';
import { BackgroundPlayback } from '../service/BackgroundPlayback';
import { AudioRouteWatcher } from '../service/AudioRouteWatcher';
import { upgradeBuvidCookie } from '../service/BiliDevice';
import { AppPreferences } from '../preferences/AppPreferences';
import { hasNetwork, isUnmeteredNetwork } from '../utils/NetworkUtil';
import { BILI_REFERER } from '../common/Constants';
import {
  AppSettings,
  downloadQualityId,
  fitByByteBudget,
  LyricLine,
  LyricResult,
  PLAYBACK_SPEED_OPTIONS,
  PREF_VALUE_BUDGET_BYTES,
  RepeatMode,
  slimTrack,
  Track,
  TrackSource
} from '../model/MusicModels';
import {
  STORE_CURRENT_TRACK,
  STORE_IS_PLAYING,
  STORE_PROGRESS,
  STORE_DURATION,
  STORE_QUEUE,
  STORE_REPEAT_MODE,
  STORE_SHUFFLE,
  STORE_LOADING_AUDIO,
  STORE_APP_FOREGROUND,
  STORE_PLAYBACK_SPEED,
  STORE_PLAYBACK_SPEED_ENABLED,
  STORE_AUDIO_MIX_ENABLED,
  STORE_TOAST_MSG,
  STORE_TOAST_HOLD_MS,
  STORE_TOAST_SEQ,
  STORE_SLEEP_TIMER_END,
  RESUME_MIN_SEC,
  RESUME_TAIL_SEC
} from '../common/Constants';

/**
 * 进度向 UI 推送的最小间隔。
 * AVPlayer 的 timeUpdate 每 100ms 回调一次，直接透传会让播放页 10 次/秒重渲染，
 * 拖动手势被拖帧；按此间隔分桶后降到 2 次/秒，视觉上进度条依旧连续。
 */
const PROGRESS_PUSH_INTERVAL_MS: number = 500;

/**
 * 「合集展开」延后执行的毫秒数。
 *
 * 点歌瞬间会并发发出三个请求：音源解析的 view + playurl，以及合集展开自己的**又一次 view**。
 * 三者撞在一起容易把 HTTP 连接池挤满，首包被拒就表现成「点了歌却提示无法播放」。
 * 展开只是「顺手把多分 P 铺进队列」的附带功能，晚 1.2s 完全无感，
 * 但换来了音源解析独占连接的窗口 —— 点歌成功率优先。
 */
const EXPAND_PARTS_DELAY_MS: number = 1200;

/**
 * 风控自愈（升级 buvid + 自动重试一轮）的冷却间隔（ms）。
 * 冷却闸门有两个作用：恢复链连发风控时不反复打 spi 升级接口；
 * 拦住「重试 → 又撞风控 → 再重试」的递归（重试失败回来的那次 catch
 * 落在冷却期内，自动转为常规失败收口）。
 */
const RISK_SELF_HEAL_COOLDOWN_MS: number = 30000;

/**
 * B 站风控 / 限流业务码（与 BilibiliApi 的 RETRYABLE_BIZ_CODES 同族）。
 * extractAudioFromVideo 内部已做过 ~2.45s 退避重试，还能冒到播放层的是
 * **持续性**风控拒绝 —— 最典型根因是本地兜底假 buvid 被服务端盯死
 * （见 BiliDevice.initBuvidCookie 的兜底说明）。备用直链 / 降档重试
 * 对它都无解，唯一对症的自愈路径是升级成官方 buvid 后重试。
 */
const RISK_CONTROL_CODES: number[] = [-352, -412, -509, -799];

/**
 * 「预取下一首音源」的延迟毫秒数。
 * 当前曲目刚起播时播放器正在缓冲首包，此刻预取会与音频流抢带宽；
 * 等 2 秒让声音先稳定，再悄悄解析下一首的直链（只拉两个小 JSON），
 * 切歌 / 自动续播时缓存命中，跳过 view + playurl 两次串行请求，近乎秒开。
 */
const PREFETCH_DELAY_MS: number = 2000;

/**
 * 累计听歌时长的落盘阈值（秒）。
 * timeUpdate 每 100ms 累计一次实时增量，攒满这个量才写一次 Preferences；
 * 暂停 / 播完 / 切歌 / 出错 / 退出等节点会经 finalizeListenSegment 立即补写，
 * 把「进程被杀」这类非正常退出的丢失窗口压到该阈值以内。
 */
const LISTEN_FLUSH_SECONDS: number = 30;

/**
 * 两次 timeUpdate 之间单次增量的可信上限（毫秒）。
 * 正常播放时约 100ms；锁屏 / 后台下 JS 回调可能被拉稀到几秒一次，
 * 若整段丢弃，「一直在后台听」的时长会被清零 —— 这里改为**截断到上限**：
 * 进程挂起恢复后的第一拍最多多计 2s（误差有界），后台播放的真实时长不再丢。
 */
const LISTEN_TICK_MAX_GAP_MS: number = 2000;

/**
 * 「上次听到」位置写入最近播放条目的节流间隔（毫秒）。
 * savePlayerStateNow 的既有挂点（5s timeUpdate / 播放 / 暂停 / seek）会高频
 * 触发记录，按此间隔节流后整份最近列表（约 6KB）落盘降到约 10s 一次；
 * 暂停 / completed / release 等关键事件走 force 立写，不受节流限制。
 */
const RECENT_PROGRESS_THROTTLE_MS: number = 10000;

/**
 * prepare 看门狗超时（毫秒）。
 *
 * setMediaSource 的 rejection 在部分系统版本上被静默吞掉（返回 undefined），
 * 状态机停在 initialized 后**没有任何事件**再上来 —— 既没有 error 也没有
 * stateChange，表现是「点了歌、封面歌名都切了、一直没声也不报错」。
 * 正常曲目的 prepare（含首包缓冲）远低于 20s；超时仍停在 initialized
 * 就认定卡死，由 recoverFromStall 主动换备用直链 / 重解析。
 */
const PREPARE_TIMEOUT_MS: number = 20000;

/**
 * 恢复链里「重解析」的最大次数（2026-10-22）。
 *
 * 3 次对应 qualityDowngradePlan 的前 3 档：第 1 次原档（直链过期最常见）、
 * 第 2/3 次逐级降档。次数再多收益极低 —— 都到第 3 次了，问题基本不在「重试」上。
 */
const RECOVER_RELOAD_MAX: number = 3;

/** 播放内核日志的统一 hilog domain / tag：`hdc shell hilog -x | grep BiliMusic` 即可过滤 */
const LOG_DOMAIN: number = 0x065B;
const LOG_TAG: string = 'BiliMusic';

function plogInfo(message: string): void {
  hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
}

function plogWarn(message: string): void {
  hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
}

function plogError(message: string): void {
  hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
}

/**
 * 从直链里只取 host，用于日志。
 * 直链带着 CDN 签名参数（整条可长达 1KB），原样打进日志既刷屏又泄露签名，
 * host 足以判断「主链 / 备用链 / 哪家 CDN」，也是「假播放中」类问题定位的关键一行。
 */
function urlHostOf(url: string): string {
  const schemeEnd: number = url.indexOf('://');
  if (schemeEnd < 0) {
    return 'invalid';
  }
  const rest: string = url.substring(schemeEnd + 3);
  const pathStart: number = rest.indexOf('/');
  const host: string = pathStart < 0 ? rest : rest.substring(0, pathStart);
  return host.length > 0 ? host : 'invalid';
}

/**
 * 数值倍速 → AVPlayer 的 PlaybackSpeed 枚举。setSpeed 只收枚举成员，
 * 档位表见 MusicModels.PLAYBACK_SPEED_OPTIONS；1.0 与非法值一律落默认（正常速）。
 */
function speedToPlaybackSpeed(v: number): media.PlaybackSpeed {
  switch (v) {
    case 0.25:
      return media.PlaybackSpeed.SPEED_FORWARD_0_25_X;
    case 0.5:
      return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    case 0.75:
      return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    case 1.25:
      return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    case 1.5:
      return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    case 1.75:
      return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    case 2.0:
      return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
    case 3.0:
      return media.PlaybackSpeed.SPEED_FORWARD_3_00_X;
    default:
      return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
  }
}

/**
 * 播放会话快照：用于「重新打开 App 时保留上次播放记录」。
 * 持久化到 PREF_PLAYER_STATE（Preferences JSON），冷启动后由 restoreState() 读回。
 */
interface PlayerStateSnapshot {
  currentTrack: Track | null;
  queue: Track[];
  currentIndex: number;
  progress: number;
  duration: number;
  repeatMode: RepeatMode;
  isShuffled: boolean;
  isPlaying: boolean;
  savedAt: number;
}

/**
 * 安全地把 MediaSource 挂到 AVPlayer 上，**等待真正的挂载结果**。
 *
 * ⚠️ 不能直接 `player.setMediaSource(src).catch(...)`：SDK 类型虽声明返回 Promise<void>，
 * 但部分系统版本运行时返回 undefined，直接 .catch 会抛
 * 「TypeError: Cannot read property catch of undefined」。
 * 这个异常会顺着 switchSource → loadAndPlay 的 catch 一路冒上去，
 * 把「音源其实已经挂上、歌在正常播」误判成加载失败 —— 副作用之一就是
 * recordRecent 被整段跳过，表现为「歌照常播放，最近播放里永远一条记录都没有」。
 * 用 Promise.resolve 归一化：真 Promise 原样透传（rejection 变成 false），
 * undefined 则得到一个已 resolved 的 Promise（视为挂载成功，返回 true）。
 *
 * 返回 true = 挂载请求已被系统接受；false = setMediaSource 明确拒绝。
 * ⚠️ 2026-10-20 关键修正：旧版只兜异常、不返回结果，调用方（switchSource）
 * 无法区分「挂上了」与「被拒了」，只能无条件当成功 —— rejection 被静默吞掉后
 * 状态机停在 idle/initialized，界面却停在假「播放中」，正是「点了歌一直没声、
 * 也不报错、重试也没用」的根因。
 */
async function attachMediaSourceSafely(
  player: media.AVPlayer,
  source: media.MediaSource
): Promise<boolean> {
  try {
    const task: Promise<void> = Promise.resolve(player.setMediaSource(source));
    await task;
    return true;
  } catch (e) {
    const err: BusinessError = e as BusinessError;
  plogError(`setMediaSource rejected: ${err.code} ${err.message}`);
  return false;
}
}

/**
 * avSession.LoopMode → 应用内 RepeatMode（媒体中心/车机 setLoopMode 命令的映射）。
 * LOOP_MODE_CUSTOM 不在本应用的档位里，返回 null 表示忽略该命令。
 */
function loopModeToRepeatMode(mode: avSession.LoopMode): RepeatMode | null {
  switch (mode) {
    case avSession.LoopMode.LOOP_MODE_SEQUENCE:
      return RepeatMode.NONE;
    case avSession.LoopMode.LOOP_MODE_SINGLE:
      return RepeatMode.ONE;
    case avSession.LoopMode.LOOP_MODE_LIST:
      return RepeatMode.ALL;
    case avSession.LoopMode.LOOP_MODE_SHUFFLE:
      return RepeatMode.SHUFFLE;
    default:
      return null;
  }
}

/** 应用内 RepeatMode → avSession.LoopMode（播放状态上报用，与 loopModeToRepeatMode 互逆）。 */
function repeatModeToLoopMode(mode: RepeatMode): avSession.LoopMode {
  switch (mode) {
    case RepeatMode.ALL:
      return avSession.LoopMode.LOOP_MODE_LIST;
    case RepeatMode.ONE:
      return avSession.LoopMode.LOOP_MODE_SINGLE;
    case RepeatMode.SHUFFLE:
      return avSession.LoopMode.LOOP_MODE_SHUFFLE;
    default:
      return avSession.LoopMode.LOOP_MODE_SEQUENCE;
  }
}

/** 秒 → LRC 时间标签的分秒部分（`mm:ss.cc`，百分秒）。 */
function formatLrcTime(seconds: number): string {
  const total: number = Math.max(0, seconds);
  const mm: number = Math.floor(total / 60);
  const ss: number = Math.floor(total % 60);
  const cs: number = Math.floor((total - Math.floor(total)) * 100);
  return `${mm < 10 ? '0' : ''}${mm}:${ss < 10 ? '0' : ''}${ss}.${cs < 10 ? '0' : ''}${cs}`;
}

/**
 * LyricLine[]（行级时间轴，秒）→ 标准歌词格式（LRC）文本，供 AVMetadata.lyric
 * 上报给媒体中心 / 车机。空行丢弃；空串 = 没有可报歌词。
 */
function buildLrcText(lines: LyricLine[]): string {
  const parts: string[] = [];
  lines.forEach((line: LyricLine): void => {
    if (line.text.length === 0) {
      return;
    }
    parts.push(`[${formatLrcTime(line.time)}]${line.text}`);
  });
  return parts.join('\n');
}

export class MusicPlayer {
  private static instance: MusicPlayer | null = null;

  private context: common.Context | null = null;
  private avPlayer: media.AVPlayer | null = null;
  private session: avSession.AVSession | null = null;
  /**
   * 播放本地下载文件时打开的文件句柄（非本地播放时为 null）。
   *
   * 文档明确要求「fd 由调用方负责关闭」，所以换源 / 回收播放器时必须一起关掉，
   * 否则每播一首下载歌曲就漏一个 fd。关闭时机很讲究：**必须在旧播放器 release 之后**
   * （见 ensurePlayer），提前关会让仍在解码的实例读到无效 fd。
   */
  private localFile: fs.File | null = null;

  private queue: Track[] = [];
  private currentIndex: number = -1;
  private shuffledQueue: Track[] = [];
  private repeatMode: RepeatMode = RepeatMode.NONE;
  private isShuffled: boolean = false;
  /**
   * 独立音量通路已整体移除（2026-10-22，用户反馈「音量比其他音乐 App 小」）：
   * 旧 volume/isMuted 字段 + setVolume/setMuted/applyVolumeOnPrepared 是死代码
   * （无 UI 调用方、无持久化），但默认 80 仍把每首歌压到 0.8 倍振幅
   * （约 -1.9dB），比恒走 1.0 的其他 App 小。现恒定 AVPlayer 默认音量 1.0，
   * 音量只由系统媒体音量控制，与其他 App 完全一致。
   */
  /** 当前播放倍速（档位见 PLAYBACK_SPEED_OPTIONS；换源重建 AVPlayer 后由 applySpeedOnPrepared 重补） */
  private playbackSpeed: number = 1.0;
  private shouldAutoplay: boolean = false;
  private retryCount: number = 0;
  /** prepare 看门狗定时器 id（-1 = 未开启）。见 startPrepareWatchdog / recoverFromStall。 */
  private prepareWatchdogTimer: number = -1;
  /** 本轮加载已尝试过的备用直链条数（loadAndPlay 每轮归零）。见 recoverFromStall。 */
  private triedBackupCount: number = 0;
  /**
   * 恢复链的**降档**游标（loadAndPlay 每轮归零，2026-10-22）。
   *
   * 每次 reloadCurrentSource 失败后 +1，实际解析用它去 qualityDowngradePlan 里取档位：
   * 第 1 次重试仍用原档（最常见原因是直链过期，换档等于白白降音质），
   * 第 2 次起逐级降档 —— 专治「某一档音轨本身播不了」（flac 解码失败 /
   * 该档全部 CDN 拒绝 / 该档被风控），旧实现会在同一坏档上重试三次、次次失败。
   */
  private qualityStep: number = 0;
  /** 恢复链是否正在推进（防 reload 失败回调与 error 回调同时触发导致叠加执行） */
  private recovering: boolean = false;
  /**
   * 本轮加载的恢复链是否已走到「重试耗尽」并提示过用户。
   * 防止 ③ 之后的残余 error 反复弹同一条提示（真机上 error 可能连发多次）。
   * loadAndPlay 每轮归零。
   */
  private recoverExhausted: boolean = false;
  /**
   * 上次风控自愈（升级 buvid + 自动重试）的时间戳，0 = 本会话还没触发过。
   * 冷却语义见 RISK_SELF_HEAL_COOLDOWN_MS / healBuvidForRiskControl。
   */
  private lastRiskControlSelfHealAt: number = 0;
  private playerState: string = 'idle';
  private loadToken: number = 0;
  /**
   * 播放器实例摘除计数：detachAndClearPlayer 每摘掉一个旧实例就 +1。
   * 用途见 recoverAfterLoadFailure —— 区分「播放器握着的是旧歌的音源」与
   * 「本次加载已经重建过播放器」（只有后者握着的音源才可能属于本次点歌）。
   */
  private playerRebuildSeq: number = 0;
  /** 本次 loadAndPlay 开始前的旧歌进度：切歌瞬间会被清零，加载失败回滚时用来还原显示 */
  private preLoadProgress: number = 0;
  /** 本次 loadAndPlay 开始前的旧歌时长：同上 */
  private preLoadDuration: number = 0;
  /** 上一次向 AVSession 上报播放状态的时间戳，用于 timeUpdate 节流 */
  private lastSessionSyncAt: number = 0;
  /** timeUpdate 的 500ms 分桶游标，同桶内不重复推送 STORE_PROGRESS */
  private lastProgressBucket: number = -1;
  /** 记录已播放时长（秒），单曲循环 / 顺序播放结束时用来判断是否需要复位 */
  private lastDuration: number = 0;
  /** 已上报到 AVSession 的曲目时长（ms）：durationUpdate 到来时据此去重，避免重复补报 */
  private lastPublishedDurationMs: number = 0;
  /** 上一次上报元数据的曲目 id：换歌时复位 lastPublishedDurationMs（不同曲目时长相同也必须重报） */
  private lastMetadataAssetId: string = '';
  /** 封面 PixelMap 缓存：补报时长 / 信息合并重报时复用，不重复下载封面 */
  private coverCache: image.PixelMap | undefined;
  /** 封面缓存对应的曲目 id（缓存失效判定） */
  private coverCacheAssetId: string = '';
  /** 已上报到 AVSession 的歌词 LRC 文本：时长补报等元数据重报时带上，不重复拼装 */
  private lastLyricText: string = '';
  /** 歌词已尝试（或已上报）对应的曲目 id：同曲重报不重复拉取歌词 */
  private lastLyricAssetId: string = '';
  /** 歌词请求令牌：切歌后在途旧结果必须丢弃，防止车机显示上一首的词 */
  private lyricFetchToken: number = 0;
  /** 已展开过的多 P 合集 bvid。避免切歌 / 重播同一合集时反复请求 view 接口。 */
  private expandedBvids: Set<string> = new Set<string>();
  /** 续播定位：loadAndPlay 在 avPlayer 进入 prepared 后跳转到该秒数（>0 表示需要续播） */
  private pendingSeekTo: number = -1;
  /** 续播后是否自动开始播放（配合 pendingSeekTo 使用，避免 prepared 阶段 seek 被丢弃） */
  private pendingAutoPlayAfterSeek: boolean = false;
  /** 冷启动从快照恢复后，用户首次点击播放时定位到的秒数（-1 表示无需定位） */
  private pendingResumePosition: number = -1;
  /** 进度落盘粗节流游标：timeUpdate 每 5s 才持久化一次进度，避免高频写 Preferences */
  private lastStatePersistAt: number = 0;
  /** 「上次听到」位置写入最近播放条目的节流游标（10s 一次；关键事件 force 立写不受限） */
  private lastRecentProgressAt: number = 0;
  /** 累计听歌时长的会话内增量（秒），攒满 LISTEN_FLUSH_SECONDS 落盘一次 */
  private listenAccumSeconds: number = 0;
  /** 上一次 timeUpdate 的时间戳；-1 表示尚未开始计时（暂停/切歌后复位） */
  private lastListenTickAt: number = -1;
  /** seek 进行中标志：seek 真正生效（seekDone）前，抑制 timeUpdate 把滑块拽回旧位置 */
  private seeking: boolean = false;
  /** seek 开始时间戳，用于「长时间收不到 seekDone」的兜底解除抑制 */
  private seekStartedAt: number = 0;
  /**
   * prepared 态续播 seek 完成后再补 play 的挂起标志（2026-10-08 B2）。
   * 旧实现 seek→play 背靠背调用，部分系统版本 seek 未完成就 play 会把 seek 丢弃，
   * 表现为「续播却从 0:00 开始放」。改为等 seekDone 再 play。
   */
  private playAfterSeekPending: boolean = false;
  /** playAfterSeekPending 的兜底定时器 id（seekDone 迟迟不来也要出声；-1 = 无定时器） */
  private playAfterSeekTimer: number = -1;
  /**
   * 本次 loadAndPlay 的起始定位秒数（2026-10-08 B1/B5）。
   * 准备期间 STORE_PROGRESS 已被清零、真实定位要等 prepared 后 seek 才生效——
   * 这段时间内任何落盘都必须用这个「意图位置」，见 savePlayerStateNow 注释。
   */
  private loadStartAt: number = 0;
  /** 音频被系统强制打断前是否正在播放，供打断结束（RESUME）时决定自动续播 */
  private wasPlayingBeforeInterrupt: boolean = false;
  /**
   * 最近一次**成功加载出音源**的曲目，用于音源解析失败时把界面回滚回来。
   *
   * 背景：`playTrack` 是乐观更新——先把 STORE_CURRENT_TRACK 写成目标曲目再解析音源。
   * 一旦解析失败（视频已删、cid 错配、区域限制……），界面就停在「这首播不出来的歌」上，
   * 而音频其实还是上一首，用户看到的就是「点了没换歌，除了音乐其他信息都加载了」。
   * 有这份快照才能在失败时把界面拉回真实正在播的那首。
   */
  private lastPlayableTrack: Track | null = null;
  /**
   * 「正在准备新音源」标志：从开始解析音源（view + playurl）、重建播放器，
   * 到新音源挂载完成为止。
   *
   * 为什么必须抑制这期间的进度回传：解析要发两次串行网络请求（数百 ms 到数秒），
   * 这段时间**旧音源仍在出声**，它的 timeUpdate 会按**上一首**的位置回调。
   * 若照常写入 STORE_PROGRESS，刚点的新歌进度条就会乱跳，而 5s 一次的落盘
   * 还会把上一首的位置存成新歌的续播点。
   * 参考实现（BiliMusic-main/service/PlayerController.ets）同样在 isPreparing 时直接 return。
   *
   * 同时 play() / pause() 在此期间只登记播放意图，不直接操作播放器
   * ——此刻 AVPlayer 正在被释放 / 重建，指针可能是空的。
   */
  private isPreparing: boolean = false;

  /**
   * 待上报的会话元数据（延迟到真正出声才上报）。
   *
   * updateSessionMetadata 内部要下载封面并解码成 PixelMap，它与 AVPlayer 的
   * 音频首包缓冲同时发出会抢带宽，拖慢「点歌到出声」。挂到 'playing' 状态
   * 再发：声音先起、封面随后，锁屏信息晚一两秒无感。
   */
  private pendingMetadataTrack: Track | null = null;
  /** 预取下一首音源的定时器句柄（-1 = 无待执行的预取） */
  private prefetchTimer: number = -1;
  /** 本会话已预取过音源的曲目 id，防止对同一首反复解析 */
  private prefetchedIds: Set<string> = new Set<string>();
  /**
   * 播放器重建互斥锁（promise 链）。
   *
   * 为什么必须有（2026-10-12 双歌叠加修复）：ensurePlayer 内部有多个 await
   * （release 旧实例 → createAVPlayer），两次并发切歌交错执行时，**较早**那次
   * 调用的 createAVPlayer 可能**更晚** resolve，随后无条件执行
   * `this.avPlayer = player` 会把较新调用刚建好、已挂上音源的实例从指针上挤掉：
   * 被挤掉的实例失去唯一引用、监听也已摘除，永远不会被 release，
   * 旧歌就此在后台一直放、与新歌叠在一起 —— 正是「切歌后偶尔两首同时响」的根因。
   * 串行化后重建严格按发起顺序完成，最新一次加载必然最后重建、最终持有指针；
   * 中途产生的实例都会被下一次重建摘监听并 release，不再产生孤儿播放器。
   */
  private playerRebuildChain: Promise<void> = Promise.resolve();

  /**
   * init() 是否已完成（2026-10-17 启动优化）。
   * initRest 与 loadContent 并行后，恢复链完成前用户可能已退后台 ——
   * 此时 savePlayerStateNow 必须静默跳过，否则会把空队列快照覆盖磁盘续播记录。
   */
  private initCompleted: boolean = false;

  static getInstance(): MusicPlayer {
    if (!MusicPlayer.instance) {
      MusicPlayer.instance = new MusicPlayer();
    }
    return MusicPlayer.instance;
  }

  async init(context: common.Context): Promise<void> {
    this.context = context;

    // AVPlayer 不再预先创建，改为**每次换源时「摘监听 → release 旧的 → createAVPlayer 新的」**
    // （见 ensurePlayer / switchSource）。
    // 复用同一个实例做 reset() 的问题是：reset 会让旧音源上报一次 error，而 error 回调
    // 又去重试换源，于是 `reset → error → reload → reset` 正反馈，重试次数瞬间耗尽、
    // 播放器卡在 error/idle —— 表现就是「切哪首歌都没声音」。
    // 参考工程（BiliMusic-main/service/AudioPlayer.ets）正是每次 setSource 都换新实例。

    if (!this.session && context) {
      try {
        this.session = await avSession.createAVSession(context, 'BiliMusic', 'audio');
      } catch (e) {
        console.error(`create AVSession failed: ${JSON.stringify(e)}`);
      }
      if (this.session) {
        this.registerSessionEvents(this.session);
        // 后台长时任务的前置条件：AVSession 必须处于激活态。
        // 未激活时系统会以 SYSTEM_SUSPEND_AUDIO_PLAYBACK_NOT_USE_AVSESSION 挂起应用，
        // 表现就是「退到后台音乐就停、应用被回收」。
        try {
          await this.session.activate();
          const agent: object | null = await BackgroundPlayback.getInstance().getLaunchAgent(context);
          if (agent) {
            await this.session.setLaunchAbility(agent);
          }
        } catch (e) {
          console.error(`activate AVSession failed: ${JSON.stringify(e)}`);
        }
        // 媒体中心/车机（HiCar）能力声明（since 26）：真机 API 26 生效，
        // 低版本设备失败仅日志降级，不影响核心播控。
        this.declareSessionCapabilities(this.session);
      }
    }

    // 独立音量 / 静音态恢复已随音量通路移除（2026-10-22，见 volume 移除注释）。
    // 倍速值恢复：镜像由 EntryAbility 在 loadContent 前首发，这里读到的一定是真值
    this.playbackSpeed = (AppStorage.get(STORE_PLAYBACK_SPEED) as number) ?? 1.0;

    this.startAudioRouteWatch();

    this.restoreState();
    this.initCompleted = true;
  }

  /**
   * 订阅音频设备变化：**蓝牙输出设备断开时暂停**。
   *
   * 为什么不能靠系统自动处理：耳机一断，系统会把声音切到扬声器继续播，
   * 「耳边突然外放」比停下来更糟（用户会以为 App 出 bug）。
   *
   * 两条前置判断，避免无谓地打断用户：
   *   · 当前没有在播放 → 什么都不做（本来就没有声音要停）；
   *   · 正处在换源准备中（`isPreparing`）→ 交给 `pause()` 自己处理（它会把播放意图置 false，
   *     等音源就绪后不会自动出声，避免「暂停了却又接着播」）。
   */
  private startAudioRouteWatch(): void {
    AudioRouteWatcher.getInstance().start((): void => {
      const playing: boolean = (AppStorage.get(STORE_IS_PLAYING) as boolean) ?? false;
      if (!playing) {
        return;
      }
      console.info('bluetooth lost while playing -> pause');
      this.pause();
      this.notifyHint('蓝牙已断开，已暂停播放');
    });
  }

  /**
   * 把当前播放会话落盘到 PREF_PLAYER_STATE。
   * 调用点：切歌 / 播放 / 暂停 / 跳转 / 队列或模式变化（见各对外方法），
   * 以及 timeUpdate 的 5s 粗节流。写入是 fire-and-forget，失败仅记日志。
   *
   * 2026-10-08（B1）新增 progressOverride：加载音源期间 STORE_PROGRESS 已被清零、
   * 真实定位要等 prepared 后 seek 才生效——此时落盘必须显式传「意图位置」，
   * 否则快照会被写成 progress:0（用户点「继续播放」的瞬间就把磁盘上的续播点清零，
   * 缓冲中退出 / 解析失败即永久从头播，这正是「暂停后关闭不记忆」的主根因）。
   * undefined / 负数 = 按 STORE_PROGRESS 现值。
   *
   * 2026-10-08（B4）：private 提为 public——EntryAbility.onBackground 的退出兜底也要调。
   */
  savePlayerStateNow(progressOverride?: number): void {
    if (!this.initCompleted) {
      // 播放器尚未恢复完成：禁止用空状态覆盖磁盘上的续播快照
      return;
    }
    const cur: Track | null = (AppStorage.get(STORE_CURRENT_TRACK) as Track) ?? null;
    const liveProgress: number = (AppStorage.get(STORE_PROGRESS) as number) ?? 0;
    const snapshot: PlayerStateSnapshot = {
      currentTrack: cur ? slimTrack(cur) : null,
      queue: this.fitQueueForStorage(),
      currentIndex: this.currentIndex,
      progress: progressOverride !== undefined && progressOverride >= 0 ? progressOverride : liveProgress,
      duration: (AppStorage.get(STORE_DURATION) as number) ?? 0,
      repeatMode: this.repeatMode,
      isShuffled: this.isShuffled,
      isPlaying: (AppStorage.get(STORE_IS_PLAYING) as boolean) ?? false,
      savedAt: Date.now()
    };
    AppPreferences.savePlayerState<PlayerStateSnapshot>(snapshot).catch((e: Error): void => {
      console.error(`savePlayerState failed: ${e.message}`);
    });
    // 顺带节流记录当前曲目到「最近播放」条目的上次听到位置（失败不影响播放）：
    // 本方法的既有挂点（5s timeUpdate / 播放 / 暂停 / seek / 后台 / release）免费复用，
    // 无需为位置记忆另设一套触发链。
    this.recordRecentProgress(progressOverride);
  }

  /**
   * 裁剪落盘的队列快照。
   *
   * Preferences 对单个 string value 有 8192 字节上限，而队列里每首曲目都带 audioUrl
   * （带签名的长直链），50 首序列化后能到 30KB → put() 抛错 → 整份快照写不进去，
   * 表现就是「重新打开 App 没有恢复上次播放记录」。这里统一瘦身 + 按字节预算从尾部截断：
   * 宁可少存几首，也要保证这份快照一定写得进去。
   */
  private fitQueueForStorage(): Track[] {
    const slim: Track[] = this.queue.map((t: Track): Track => slimTrack(t));
    // 留 1KB 给 currentTrack 与其余标量字段
    return fitByByteBudget<Track>(slim, PREF_VALUE_BUDGET_BYTES - 1024);
  }

  /**
   * 冷启动恢复上次播放记录。
   * 仅恢复「记录」（曲目 / 队列 / 进度 / 模式），并挂起为暂停态 + 记一个续播定位，
   * 等用户点播放再真正加载音源并 seek 到原位置——避免无交互冷启动就自动出声。
   * 没有快照或快照无曲目时直接返回，不污染首启体验。
   */
  private restoreState(): void {
    const snapshot: PlayerStateSnapshot | null = AppPreferences.getPlayerState<PlayerStateSnapshot>();
    if (!snapshot || !snapshot.currentTrack) {
      return;
    }
    const track: Track = snapshot.currentTrack;
    this.queue = Array.isArray(snapshot.queue) ? snapshot.queue.slice() : [];
    this.shuffledQueue = this.shuffle(this.queue);
    this.currentIndex = typeof snapshot.currentIndex === 'number' ? snapshot.currentIndex : -1;
    this.repeatMode = snapshot.repeatMode ?? RepeatMode.NONE;
    this.isShuffled = snapshot.isShuffled ?? false;

    this.setStore(STORE_CURRENT_TRACK, track);
    this.syncQueue();
    this.setStore(STORE_REPEAT_MODE, this.repeatMode);
    this.setStore(STORE_SHUFFLE, this.isShuffled);

    const pos: number = snapshot.progress ?? 0;
    this.setStore(STORE_PROGRESS, pos);
    this.setStore(STORE_DURATION, snapshot.duration ?? 0);
    // 暂停态恢复：不自动出声，等待用户点击继续
    this.setStore(STORE_IS_PLAYING, false);
    this.pendingResumePosition = pos > 0 ? pos : -1;
  }

  private setStore(key: string, value: Object | null): void {
    if (value === null) {
      AppStorage.delete(key);
    } else {
      AppStorage.setOrCreate(key, value);
    }
  }

  private getQueue(): Track[] {
    return (AppStorage.get(STORE_QUEUE) as Track[]) ?? [];
  }

  private syncQueue(): void {
    this.setStore(STORE_QUEUE, this.queue);
  }

  private displayQueue(): Track[] {
    return this.isShuffled ? this.shuffledQueue : this.queue;
  }

  /**
   * 播放状态与后台长时任务保持同步：播放中申请 AUDIO_PLAYBACK，暂停/结束时释放。
   * 不做这步，退到后台后进程会被系统挂起，音乐停止、应用被回收。
   */
  private syncBackgroundTask(playing: boolean): void {
    if (!this.context) {
      return;
    }
    const bg: BackgroundPlayback = BackgroundPlayback.getInstance();
    if (playing) {
      bg.start(this.context).catch((e: Error): void => {
        console.error(`start continuousTask failed: ${JSON.stringify(e)}`);
      });
    } else {
      bg.stop(this.context).catch((e: Error): void => {
        console.error(`stop continuousTask failed: ${JSON.stringify(e)}`);
      });
    }
  }

  private registerAvPlayerEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: string): void => {
      this.playerState = state;
      plogInfo(`avplayer state -> ${state}`);
      if (state === 'initialized') {
        // audioRendererInfo 的合法设置窗口是 idle/initialized；实测部分系统版本在
        // idle 态（createAVPlayer 刚返回）直接报 5400102「unsupport to set audio
        // renderer info」，挪到这里（setMediaSource 已被接受之后）最稳。
        this.applyRendererInfoInInitialized(player);
        // prepare 看门狗：setMediaSource 的 rejection 被吞（部分系统版本返回
        // undefined）后，状态机会永远停在 initialized，**没有任何事件**再上来。
        // 20s 无进展就主动走 recoverFromStall（换备用直链 / 重解析）。
        this.startPrepareWatchdog();
        // prepare() 返回 Promise，必须接住：拒绝时若不处理，未处理的 rejection
        // 会让状态机静默停在 initialized，表现为「点了歌一直转圈、永远不出声」。
        player.prepare().catch((e: BusinessError): void => {
          plogError(`prepare failed: ${e.code} ${e.message}`);
          this.isPreparing = false;
          this.setStore(STORE_LOADING_AUDIO, false);
          // 看门狗刻意**不**取消：prepare 拒绝后状态机仍停在 initialized，
          // 看门狗是这一僵局的唯一自愈出口（超时后走 recoverFromStall）。
        });
      } else if (state === 'prepared') {
        this.cancelPrepareWatchdog();
        // 倍速补应用：换源每次重建 AVPlayer，不补的话切歌后倍速悄悄变回 1.0
        this.applySpeedOnPrepared(player);
        // 「与其他应用同时播放」同款补应用：换源每次重建 AVPlayer，prepared 且
        // 首次 play 前是 SDK 要求的 audioInterruptMode 生效窗口
        this.applyInterruptModeOnPrepared(player);
        if (this.pendingSeekTo >= 0) {
          // 续播 / 切歌后定位：必须在 prepared 之后再 seek，否则 seek 会被丢弃
          const target: number = this.pendingSeekTo;
          this.pendingSeekTo = -1;
          const doPlay: boolean = this.pendingAutoPlayAfterSeek;
          this.pendingAutoPlayAfterSeek = false;
          // 2026-10-08（B2）：与公开 seek() 同款抑制——seekDone 前旧位置的
          // timeUpdate 不能把 STORE_PROGRESS 写回去，否则续播进度显示会被拽回 0
          this.seeking = true;
          this.seekStartedAt = Date.now();
          try {
            player.seek(target * 1000);
          } catch (e) {
            console.error(`seek on prepared failed: ${JSON.stringify(e)}`);
            this.seeking = false;
            this.lastProgressBucket = -1;
          }
          if (doPlay) {
            // 2026-10-08（B2）：不再背靠背 play——部分系统版本 prepared 态 seek 未完成
            // 就 play 会丢弃 seek（表现为「续播却从头播」）。挂起等 seekDone 再播；
            // seekDone 2.5s 不来则兜底播放（对齐 timeUpdate 里的抑制兜底时长）
            this.playAfterSeekPending = true;
            if (this.playAfterSeekTimer !== -1) {
              clearTimeout(this.playAfterSeekTimer);
            }
            this.playAfterSeekTimer = setTimeout((): void => {
              this.playAfterSeekTimer = -1;
              if (this.playAfterSeekPending) {
                this.playAfterSeekPending = false;
                this.seeking = false;
                this.lastProgressBucket = -1;
                player.play().catch((e: BusinessError): void => {
                  console.error(`play after seek (fallback timer) failed: ${e.code} ${e.message}`);
                });
              }
            }, 2500);
          }
        } else if (this.shouldAutoplay) {
          player.play().catch((e: BusinessError): void => {
            console.error(`autoplay failed: ${e.code} ${e.message}`);
          });
        }
      } else if (state === 'playing') {
        this.setStore(STORE_IS_PLAYING, true);
        // 真正出声了：把延迟的会话元数据（含封面）现在才发，不再与首包缓冲抢带宽
        this.flushPendingMetadata();
        this.updateSessionState();
        this.syncBackgroundTask(true);
      } else if (state === 'paused') {
        this.setStore(STORE_IS_PLAYING, false);
        this.updateSessionState();
        this.syncBackgroundTask(false);
        // 停止听歌计时并立即落盘已累计的整数部分：
        // 暂停后到下次恢复之间的空白不计入（由游标复位实现）
        this.finalizeListenSegment();
        // 用户暂停 / 音频打断即写「上次听到」位置，不等 10s 节流：
        // 暂停后随时可能杀进程，此刻的位置必须已经在盘上
        this.recordRecentProgress(undefined, true);
      } else if (state === 'completed') {
        // 听完一首歌是高频的「停止点」，攒在内存里的余量马上落盘，
        // 用户听完就杀 App 也不丢
        this.finalizeListenSegment();
        // 听完重置位置为 0：条目不再显示「上次听到」、下次点击从头播
        this.recordRecentProgress(0, true);
        this.handleEnded();
      }
    });

    player.on('timeUpdate', (time: number): void => {
      // ⚠️ 累计听歌时长必须放在「准备中」判断**之前**：
      // 切歌解析期间旧音源仍在出声（见 isPreparing 字段注释），这段真实听掉的
      // 时间不能丢。无声的换源空窗由 detachAndClearPlayer 复位游标兜住。
      this.accumulateListenTime();
      // ⚠️ 正在准备新音源（解析 + 重建播放器）期间，出声的仍是**上一首**，
      // 它的 timeUpdate 会按旧位置回调。此时若写进度，新歌的进度条会乱跳，
      // 5s 一次的落盘还会把上一首的位置存成新歌的续播点。直接 return 最干净。
      if (this.isPreparing) {
        return;
      }
      // ⚠️ 官方文档：timeUpdate **默认每 100ms 上报一次**（不是 1s）。
      // 若每次原样写进 AppStorage，播放页每秒会重渲染 10 次
      // （旋转唱片动画 + Swiper + 歌词 List 全在被重建），
      // 拖进度条这种跟手手势会被拖帧，表现为「拖不动 / 拖了又跳回去」。
      // 因此按 500ms 分桶，同一桶内不推送（进度文字按秒显示，视觉无损）。
      // 另：seek 是异步的，seek 真正生效（seekDone）前，timeUpdate 仍会按旧位置回调，
      // 若此时把 STORE_PROGRESS 写回去，滑块就会被拽回旧位置——这就是「拖了又跳回去」。
      // 故 seeking 期间抑制进度推送，仅保留会话/落盘同步。
      if (this.seeking) {
        // 兜底：seek 超过 2.5s 仍未收到 seekDone，强制解除抑制，避免进度条卡死
        if (Date.now() - this.seekStartedAt > 2500) {
          this.seeking = false;
          this.lastProgressBucket = -1;
        }
      }
      const bucket: number = Math.floor(time / PROGRESS_PUSH_INTERVAL_MS);
      if (!this.seeking && bucket !== this.lastProgressBucket) {
        this.lastProgressBucket = bucket;
        this.setStore(STORE_PROGRESS, time / 1000);
      }
      // 会话位置按 1s 节流上报：既让播控中心进度准确，也避免系统因
      // 「AVSession 长期不更新」判定播放未运行而挂起长时任务。
      const now: number = Date.now();
      if (now - this.lastSessionSyncAt >= 1000) {
        this.lastSessionSyncAt = now;
        this.updateSessionState();
      }
      // 进度落盘粗节流（2026-10-21 后台耗电优化）：前台每 5s 保证重启后能恢复到
      // 大致位置；后台播放拉长到 30s 降低写盘频率 —— EntryAbility.onBackground
      // 已有兜底落盘，回前台后此处自动切回 5s 档，无数据丢失窗口。
      // 标志缺失（启动早期）=== false 不成立，按前台 5s 处理，与旧行为一致。
      const persistGapMs: number =
        AppStorage.get<boolean>(STORE_APP_FOREGROUND) === false ? 30000 : 5000;
      if (now - this.lastStatePersistAt >= persistGapMs) {
        this.lastStatePersistAt = now;
        this.savePlayerStateNow();
      }
    });

    player.on('durationUpdate', (duration: number): void => {
      this.lastDuration = duration / 1000;
      this.setStore(STORE_DURATION, this.lastDuration);
      // 列表侧没有时长的曲目，首次 setAVMetadata 不带 duration（横幅画不出进度条 / 时间）。
      // 真实时长解析出来后整体补报一次元数据；已报过相同时长则跳过。
      this.republishSessionDuration();
    });

    player.on('error', (err: object): void => {
      plogError(`AVPlayer error: ${JSON.stringify(err)}`);
      // 换源时旧实例已 detach + release，它的 error 不会再走到这里，
      // 所以这里收到的必定是**当前音源**的真实错误 —— 不再需要「静默窗口」去猜。
      this.cancelPrepareWatchdog();
      this.isPreparing = false;
      // 2026-10-08（B2）：续播 seek→play 挂起中出错：取消挂起的 play 与兜底定时器，
      // 否则定时器会对已进入 error 态的实例调 play，错误路径再多绕一圈
      this.playAfterSeekPending = false;
      if (this.playAfterSeekTimer !== -1) {
        clearTimeout(this.playAfterSeekTimer);
        this.playAfterSeekTimer = -1;
      }
      this.setStore(STORE_LOADING_AUDIO, false);
      this.setStore(STORE_IS_PLAYING, false);
      // 播放已中断，及时释放长时任务，避免通知栏残留一条无声音的任务
      this.syncBackgroundTask(false);
      // 出错属于「不是正常停止」：把已听时长立刻收尾落盘，别等攒满阈值
      this.finalizeListenSegment();
      // 统一恢复入口：备用直链 → 重解析 → 重试耗尽才提示失败
      this.recoverFromStall();
    });

    // seek 真正生效后，解除进度抑制，让 timeUpdate 重新驱动滑块到目标位置
    player.on('seekDone', (seekDoneTime: number): void => {
      this.seeking = false;
      this.lastProgressBucket = -1;
      // 2026-10-08（B2）：prepared 态续播 seek 完成，补上被挂起的 play
      if (this.playAfterSeekPending) {
        this.playAfterSeekPending = false;
        if (this.playAfterSeekTimer !== -1) {
          clearTimeout(this.playAfterSeekTimer);
          this.playAfterSeekTimer = -1;
        }
        player.play().catch((e: BusinessError): void => {
          console.error(`play after seekDone failed: ${e.code} ${e.message}`);
        });
      }
    });

    player.on('audioInterrupt', (event: audio.InterruptEvent): void => {
      this.onAudioInterrupt(event);
    });
  }

  private currentTrackSnapshot(): Track | null {
    return (AppStorage.get(STORE_CURRENT_TRACK) as Track) ?? null;
  }

  private registerSessionEvents(session: avSession.AVSession): void {
    try {
      session.on('play', (): void => {
        this.play();
      });
      session.on('pause', (): void => {
        this.pause();
      });
      session.on('seek', (time: number): void => {
        this.seek(time / 1000);
      });
      session.on('playNext', (): void => {
        this.next();
      });
      session.on('playPrevious', (): void => {
        this.prev();
      });
      // 媒体中心 / HiCar 车机卡片扩展命令（2026-10-21）：快进快退 / 收藏 / 倍速 / 播放模式。
      // fastForward/rewind 的 time 单位毫秒，缺省 15s（与 AVMetadata.skipIntervals 一致）。
      session.on('fastForward', (time?: number): void => {
        this.seekBy((time ?? 15000) / 1000);
      });
      session.on('rewind', (time?: number): void => {
        this.seekBy(-(time ?? 15000) / 1000);
      });
      // 车机收藏键：assetId 校验为当前曲才执行，防止误翻其他曲目
      session.on('toggleFavorite', (assetId: string): void => {
        const current: Track | null = this.currentTrackSnapshot();
        if (current !== null && current.id === assetId) {
          this.toggleLike(current);
        }
      });
      session.on('setSpeed', (speed: number): void => {
        this.setPlaybackSpeed(speed);
      });
      session.on('setLoopMode', (mode: avSession.LoopMode): void => {
        const mapped: RepeatMode | null = loopModeToRepeatMode(mode);
        if (mapped !== null) {
          this.setRepeatMode(mapped);
        }
      });
    } catch (e) {
      console.error(`register session events failed: ${JSON.stringify(e)}`);
    }
  }

  private async updateSessionMetadata(track: Track): Promise<void> {
    if (!this.session) {
      return;
    }
    // 换歌时复位「已报时长」：两首歌时长恰好相同时，去重逻辑不能把新歌的补报吞掉
    if (track.id !== this.lastMetadataAssetId) {
      this.lastMetadataAssetId = track.id;
      this.lastPublishedDurationMs = 0;
    }
    // 系统媒体胶囊（灵动胶囊）需要 PixelMap 形式的封面，网络 URL 无法直接识别，
    // 故把封面解码成 PixelMap 再写入 mediaImage；任何环节失败都降级为无封面，不阻断上报。
    // 同一曲目的重复上报（时长补报 / 信息合并后的重报）直接复用缓存的 PixelMap。
    if (track.coverUrl && track.coverUrl.length > 0
      && !(this.coverCacheAssetId === track.id && this.coverCache !== undefined)) {
      try {
        const loaded: image.PixelMap | null = await this.loadCoverPixelMap(track.coverUrl);
        if (loaded !== null) {
          this.coverCache = loaded;
          this.coverCacheAssetId = track.id;
        }
      } catch (e) {
        console.error(`load cover pixelmap failed: ${JSON.stringify(e)}`);
      }
    }
    // 播控横幅的进度条与时间 = position / duration，缺 duration 就两个都不渲染。
    // duration 单位毫秒；列表侧拿不到时长（duration=0）时回退到播放器已解析出的真实时长。
    const durationSec: number = track.duration > 0 ? track.duration : this.lastDuration;
    const durationMs: number = Math.round(durationSec * 1000);
    if (durationMs > 0) {
      this.lastPublishedDurationMs = durationMs;
    }
    try {
      this.session.setAVMetadata(this.buildAVMetadata(track)).catch((e: BusinessError): void => {
        console.error(`setAVMetadata failed: ${e.code} ${e.message}`);
      });
    } catch (e) {
      console.error(`setAVMetadata failed: ${JSON.stringify(e)}`);
    }
    // 歌词补报（fire-and-forget）：命中 LyricsApi 缓存则几乎零开销，未命中才发请求；
    // 失败静默（歌词非必需，绝不阻断上报链路）。
    this.publishSessionLyric(track);
  }

  /**
   * 统一组装 AVMetadata：首报 / 时长补报（republishSessionDuration）/ 歌词补报
   * 三处上报共用。setAVMetadata 是**整体替换**语义，任何一处绕开本函数直接拼对象，
   * 都会把其他处已报的字段覆盖丢失（2026-10-21 HiCar 车机卡片改造收口点）。
   */
  private buildAVMetadata(track: Track): avSession.AVMetadata {
    const durationSec: number = track.duration > 0 ? track.duration : this.lastDuration;
    const meta: avSession.AVMetadata = {
      assetId: track.id,
      title: track.title || '未命名歌曲',
      artist: track.artist || 'BiliMusic',
      album: 'BiliMusic',
      duration: Math.round(durationSec * 1000),
      // 快进/快退步长：媒体中心与车机按此渲染 ±15s（与 seekBy 缺省一致）
      skipIntervals: avSession.SkipIntervals.SECONDS_15,
      mediaImage: (this.coverCacheAssetId === track.id && this.coverCache !== undefined)
        ? this.coverCache : undefined
    };
    // 上一曲/下一曲：按队列索引上报，越界不设字段——媒体中心/车机据此把按钮点亮/置灰
    const prev: Track | undefined = this.queue[this.currentIndex - 1];
    const next: Track | undefined = this.queue[this.currentIndex + 1];
    if (prev !== undefined) {
      meta.previousAssetId = prev.id;
    }
    if (next !== undefined) {
      meta.nextAssetId = next.id;
    }
    // 歌词：仅当本曲已拼好 LRC（publishSessionLyric 写入）才带上
    if (this.lastLyricAssetId === track.id && this.lastLyricText.length > 0) {
      meta.lyric = this.lastLyricText;
    }
    return meta;
  }

  /**
   * 异步补报歌词：AVMetadata.lyric 要求标准歌词格式（LRC），复用 LyricsApi 缓存
   * （与播放页歌词共享，不重复请求）。令牌防切歌竞态；synced=false（纯文本歌词）
   * 不上报，避免被 LRC 解析器乱显。本曲只尝试一次，重报不重复拉取。
   */
  private publishSessionLyric(track: Track): void {
    if (!this.session) {
      return;
    }
    if (this.lastLyricAssetId === track.id) {
      return;
    }
    const token: number = ++this.lyricFetchToken;
    // 立即标记「本曲已尝试」：时长补报等重报路径不再重复发起歌词请求
    this.lastLyricAssetId = track.id;
    this.lastLyricText = '';
    getLyricForTrack(track).then((result: LyricResult | null): void => {
      // 切歌竞态：在途结果属于旧曲，丢弃
      if (token !== this.lyricFetchToken || result === null || !result.synced) {
        return;
      }
      const lrc: string = buildLrcText(result.lines);
      if (lrc.length === 0) {
        return;
      }
      this.lastLyricText = lrc;
      if (!this.session) {
        return;
      }
      try {
        this.session.setAVMetadata(this.buildAVMetadata(track)).catch((e: BusinessError): void => {
          console.error(`setAVMetadata with lyric failed: ${e.code} ${e.message}`);
        });
      } catch (e) {
        console.error(`setAVMetadata with lyric failed: ${JSON.stringify(e)}`);
      }
    }).catch((e: Error): void => {
      console.error(`publish session lyric failed: ${e.message}`);
    });
  }

  /**
   * 能力声明（since 26，媒体中心 = 控制中心/锁屏/HiCar 车机卡片同源）：
   * setMediaCenterControlType 让媒体中心优先显示这排控制，要求所设命令必须已 on() 注册
   * （registerSessionEvents 先于本方法执行，顺序天然满足）；低版本设备失败仅日志降级。
   */
  private declareSessionCapabilities(session: avSession.AVSession): void {
    try {
      session.setMediaCenterControlType([
        'playNext', 'playPrevious', 'fastForward', 'rewind', 'setSpeed', 'setLoopMode', 'toggleFavorite'
      ]).catch((e: BusinessError): void => {
        console.error(`setMediaCenterControlType failed: ${e.code} ${e.message}`);
      });
    } catch (e) {
      console.error(`setMediaCenterControlType failed: ${JSON.stringify(e)}`);
    }
    try {
      session.setSupportedLoopModes([
        avSession.LoopMode.LOOP_MODE_SEQUENCE,
        avSession.LoopMode.LOOP_MODE_SINGLE,
        avSession.LoopMode.LOOP_MODE_LIST,
        avSession.LoopMode.LOOP_MODE_SHUFFLE
      ]).catch((e: BusinessError): void => {
        console.error(`setSupportedLoopModes failed: ${e.code} ${e.message}`);
      });
    } catch (e) {
      console.error(`setSupportedLoopModes failed: ${JSON.stringify(e)}`);
    }
    try {
      session.setSupportedPlaySpeeds(PLAYBACK_SPEED_OPTIONS).catch((e: BusinessError): void => {
        console.error(`setSupportedPlaySpeeds failed: ${e.code} ${e.message}`);
      });
    } catch (e) {
      console.error(`setSupportedPlaySpeeds failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 快进 / 快退（媒体中心/车机 fastForward/rewind 命令）：当前进度偏移 deltaSec，
   * 钳到 [0, 时长]；时长未知（尚未 prepared）不动作。
   */
  private seekBy(deltaSec: number): void {
    const progress: number = (AppStorage.get(STORE_PROGRESS) as number) ?? 0;
    const duration: number = this.lastDuration > 0
      ? this.lastDuration
      : ((AppStorage.get(STORE_DURATION) as number) ?? 0);
    if (duration <= 0) {
      return;
    }
    this.seek(Math.max(0, Math.min(duration, progress + deltaSec)));
  }

  /**
   * 把封面网络地址解码成 PixelMap，供系统媒体胶囊（AVSession mediaImage）显示专辑封面。
   * 网络 URL 不能直接当 ImageSource 的 URI，故走 http 取到字节再 createImageSource。
   * 失败返回 null（封面非必需，绝不能让元数据上报中断）。
   */
  private async loadCoverPixelMap(url: string): Promise<image.PixelMap | null> {
    const httpReq = http.createHttp();
    try {
      const resp: http.HttpResponse = await httpReq.request(url, {
        method: http.RequestMethod.GET,
        header: { Referer: BILI_REFERER },
        connectTimeout: 10000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      if (resp.responseCode !== 200 || !resp.result) {
        return null;
      }
      const data: ArrayBuffer = resp.result as ArrayBuffer;
      const src: image.ImageSource = image.createImageSource(data);
      return await src.createPixelMap();
    } catch (e) {
      console.error(`loadCoverPixelMap failed: ${JSON.stringify(e)}`);
      return null;
    } finally {
      httpReq.destroy();
    }
  }

  /**
   * 真实时长到位后补报一次元数据。
   *
   * 播控横幅要拿 AVMetadata.duration（毫秒）才肯画进度条 / 显示总时间；
   * 「音乐中心」这类列表数据没有时长，首报时只能缺省，等 durationUpdate
   * 事件把真实时长送来后再整体重报一次（封面走缓存，不重复下载）。
   */
  private republishSessionDuration(): void {
    if (!this.session) {
      return;
    }
    // 元数据还挂着待上报（尚未出声）：此刻补报只会把「延迟上报」变回
    // 「边缓冲边下封面」，与优化目标相悖。等 flushPendingMetadata 一并带出——
    // 它会读取此刻已解析好的 lastDuration，时长不会丢。
    if (this.pendingMetadataTrack !== null) {
      return;
    }
    const durationMs: number = Math.round(this.lastDuration * 1000);
    // 时长无效或已上报过相同值：跳过（durationUpdate 对同一音源可能触发多次）
    if (durationMs <= 0 || durationMs === this.lastPublishedDurationMs) {
      return;
    }
    const track: Track | null = this.currentTrackSnapshot();
    if (track === null) {
      return;
    }
    this.updateSessionMetadata(track).catch((e: Error): void => {
      console.error(`republish session duration failed: ${e.message}`);
    });
  }

  /**
   * 把延迟到「真正出声」才上报的会话元数据发出去。
   * 见 pendingMetadataTrack 字段注释：封面下载让路给音频首包，出声更快。
   */
  private flushPendingMetadata(): void {
    const track: Track | null = this.pendingMetadataTrack;
    if (track === null) {
      return;
    }
    this.pendingMetadataTrack = null;
    this.updateSessionMetadata(track).catch((e: Error): void => {
      console.error(`updateSessionMetadata failed: ${e.message}`);
    });
  }

  /**
   * 当前用户「播放音质」偏好对应的档位 id。
   *
   * loadAndPlay / reloadCurrentSource / prefetchNextSource 三个音源解析调用点
   * **必须统一从这取**：sourceCache 的缓存键含档位段（`bvid|cid|quality`），
   * 任何一处不一致就会分裂缓存 —— 预取永远不命中、恢复重载拿到另一档。
   *
   * 2026-10-20 修复「登录后点歌卡住（大会员账号）」排查出的两处档位缺口：
   *   · reloadCurrentSource 此前硬编码 0（= 按带宽最大取）→ 大会员账号在
   *     恢复梯度里拿到 flac/杜比音轨：既违背用户音质偏好（设置的是 192K），
   *     又让「备用直链 → 重解析」整条梯度困在同一坏档位里无法降级到可播档；
   *   · prefetchNextSource 此前漏传 → 预取缓存键与 loadAndPlay 错位，
   *     2026-10-08 loadAndPlay 开始传 playQuality 后预取就一直不命中（死代码），
   *     且大会员账号预取的还是 flac/杜比 URL（白耗流量）。
   */
  private currentPlayQualityId(): number {
    return downloadQualityId(AppPreferences.getSettings().playQuality);
  }

  /**
   * 恢复链里这一次重解析该用哪个档位（2026-10-22 双保险）。
   *
   * 语义：`qualityStep` 从 0 开始，每次重解析失败后 +1 —— 第 1 次仍用用户偏好档
   * （直链过期是最常见原因，换档等于白降音质），第 2 次起沿 qualityDowngradePlan
   * 逐级下降，直到 64K。降档后 sourceCache 的键（含档位段）自然分裂，
   * 不会拿到上一档的旧结果。
   *
   * ⚠️ 与 currentPlayQualityId 的分工：**首播必须用偏好档**（否则用户设了无损却
   * 听到 64K），只有「已经失败过」的路径才允许降档。
   */
  private recoveryQualityId(): number {
    const plan: number[] = qualityDowngradePlan(this.currentPlayQualityId());
    const idx: number = Math.min(this.qualityStep, plan.length - 1);
    if (idx > 0) {
      plogWarn(`recovery quality downgraded: ${plan[0]} -> ${plan[idx]} (step ${this.qualityStep})`);
    }
    return plan[idx];
  }

  /**
   * 音源已挂上后，安排一次「下一首直链」的预取。
   * 每次成功加载都会重新调度（旧的定时器被清掉），预取的永远是**当前曲目的下一首**。
   */
  private scheduleNextSourcePrefetch(): void {
    if (this.prefetchTimer !== -1) {
      clearTimeout(this.prefetchTimer);
    }
    this.prefetchTimer = setTimeout((): void => {
      this.prefetchTimer = -1;
      this.prefetchNextSource();
    }, PREFETCH_DELAY_MS);
  }

  /**
   * 预取下一首的音源解析结果（view + playurl 两个小 JSON，不拉音频流）。
   * 解析结果落在 BilibiliApi 的缓存里；真正切到这首时 extractAudioFromVideo
   * 直接命中缓存，省掉两次串行请求 —— 「播放全部」自动续播从此近乎秒开。
   * 失败只留日志：预取是锦上添花，绝不能影响正在进行的播放。
   */
  private prefetchNextSource(): void {
    try {
      // 「仅 WiFi 播放」开着且当前是蜂窝：下一首根本不会被允许播，预取没有意义
      if (AppPreferences.getSettings().wifiOnlyPlay && !isUnmeteredNetwork()) {
        return;
      }
      const dq: Track[] = this.displayQueue();
      if (dq.length === 0 || this.currentIndex < 0) {
        return;
      }
      if (this.repeatMode === RepeatMode.ONE) {
        // 单曲循环没有「下一首」，当前音源早已解析过
        return;
      }
      let idx: number = this.currentIndex + 1;
      if (idx >= dq.length) {
        if (this.repeatMode === RepeatMode.NONE) {
          // 顺序播放到末尾自然停止，没有下一首
          return;
        }
        // 列表循环 / 随机：回到开头
        idx = 0;
      }
      const track: Track = dq[idx];
      const localPath: string = track.localFilePath ?? '';
      if (localPath.length > 0) {
        // 本地文件不需要解析音源
        return;
      }
      if (this.prefetchedIds.has(track.id)) {
        return;
      }
      this.prefetchedIds.add(track.id);
      // 档位必须与 loadAndPlay 一致（currentPlayQualityId）：缓存键含档位段，
      // 错位 = 预取结果永远不被命中，白白发两次请求（2026-10-20 修复）。
      extractAudioFromVideo(track.bvid || track.id, {
        aid: track.aid,
        cid: track.cid
      }, this.currentPlayQualityId()).catch((e: Error): void => {
        console.error(`prefetch next source failed: ${e.message}`);
      });
    } catch (e) {
      console.error(`prefetch next source threw: ${JSON.stringify(e)}`);
    }
  }

  private updateSessionState(): void {
    if (!this.session) {
      return;
    }
    const playing: boolean = (AppStorage.get(STORE_IS_PLAYING) as boolean) ?? false;
    const state: avSession.PlaybackState =
      playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
    const position: avSession.PlaybackPosition = {
      // elapsedTime 的单位是毫秒，而 STORE_PROGRESS 存的是秒，必须 ×1000：
      // 早前直接传秒，横幅上的已播时间几乎不动、进度条不走（配合缺失的 duration
      // 表现为「时间和进度条都不显示」）。
      elapsedTime: Math.round(((AppStorage.get(STORE_PROGRESS) as number) ?? 0) * 1000),
      updateTime: Date.now()
    };
    // HiCar 车机卡片扩展状态（2026-10-21）：收藏态 / 播放模式 / 倍速随既有节流一并上报
    const track: Track | null = this.currentTrackSnapshot();
    try {
      this.session.setAVPlaybackState({
        state: state,
        position: position,
        isFavorite: track !== null && track.isLiked,
        loopMode: repeatModeToLoopMode(this.repeatMode),
        speed: this.playbackSpeed
      }).catch((e: BusinessError): void => {
        console.error(`setAVPlaybackState failed: ${e.code} ${e.message}`);
      });
    } catch (e) {
      console.error(`setAVPlaybackState failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 音频焦点中断处理（被来电 / 闹钟 / 其他应用抢占焦点）。
   * - INTERRUPT_FORCE + PAUSE：系统已把音频暂停，必须同步自身状态到「已暂停」，
   *   并记录「打断前在播放」，待 RESUME 时自动续播；
   * - INTERRUPT_FORCE + STOP：永久失去焦点，同步暂停但不自动恢复（需用户手动触发）；
   * - INTERRUPT_FORCE + DUCK：临时压低音量，无需暂停；
   * - INTERRUPT_SHARE + RESUME：其他应用释放焦点，若打断前在播放则自动 play() 续播。
   * 不自动恢复的情形：打断前本就处于暂停（用户主动暂停），或 STOP（永久失去焦点）。
   */
  private onAudioInterrupt(event: audio.InterruptEvent): void {
    const wasPlaying: boolean = (AppStorage.get(STORE_IS_PLAYING) as boolean) ?? false;
    if (event.forceType === audio.InterruptForceType.INTERRUPT_FORCE) {
      switch (event.hintType) {
        case audio.InterruptHint.INTERRUPT_HINT_PAUSE:
          // 系统已暂停音频：同步状态，记住「被打断前在播放」以便恢复
          this.wasPlayingBeforeInterrupt = wasPlaying;
          this.setStore(STORE_IS_PLAYING, false);
          this.updateSessionState();
          this.syncBackgroundTask(false);
          break;
        case audio.InterruptHint.INTERRUPT_HINT_STOP:
          // 永久失去焦点：同步暂停，但不自动恢复
          this.wasPlayingBeforeInterrupt = false;
          this.setStore(STORE_IS_PLAYING, false);
          this.updateSessionState();
          this.syncBackgroundTask(false);
          break;
        case audio.InterruptHint.INTERRUPT_HINT_DUCK:
        default:
          // 临时压低音量即可，自身状态不变
          break;
      }
    } else if (event.forceType === audio.InterruptForceType.INTERRUPT_SHARE) {
      switch (event.hintType) {
        case audio.InterruptHint.INTERRUPT_HINT_RESUME:
          if (this.wasPlayingBeforeInterrupt) {
            this.wasPlayingBeforeInterrupt = false;
            this.play();
          }
          break;
        case audio.InterruptHint.INTERRUPT_HINT_UNDUCK:
        default:
          break;
      }
    }
  }

  /**
   * 把「音源解析结果」合并回曲目对象。播放页显示的就是这个合并结果。
   *
   * 合并方向是这里最容易写反、且写反了最难查的一点（症状是「播放页的信息跟
   * 正在放的这首歌对不上 / 干脆是空的」）：
   *
   * - **标题 / 歌手 / 封面：列表侧优先，音源侧兜底。**
   *   列表里的元数据才是「这条目自己的信息」——音乐中心的封面是专辑图、标题是曲名；
   *   而音源侧的 title / pic 来自**承载这段音频的那个视频**。对音乐中心这类
   *   「音频元数据 + 视频承载」的条目，两者根本不是一回事（实测：曲名
   *   《Chopin: Études Op.10 No.12》、歌手「赵成珍」，承载视频却是个
   *   「高一放学回家外录钢琴」的投稿）。无条件采用音源侧，播放页就会变成
   *   另一个视频的封面与标题 —— 列表里看到的和播放页里看到的对不上。
   *   只有列表侧为空串时才拿音源侧补全（例如某些源缺标题）。
   * - **时长：音源侧优先。** `view` 给的是该视频（分 P）的真实时长，seek 依赖它；
   *   列表侧不少源（音乐中心）压根没有时长字段。
   * - **aid / cid：音源侧优先。** 这一对正是本次取流用的编号，天然自洽；
   *   音乐中心的 aid/cid 属于音频体系，与视频分 P 不是同一套（拿它取流会 -404），
   *   写成取流那一对，下次解析失败走 avid+cid 兜底时也不会二次踩坑。
   */
  private mergeTrack(track: Track, source: TrackSource): Track {
    const cover: string = track.coverUrl.length > 0 ? track.coverUrl : source.coverUrl;
    if (track.coverUrl.length > 0 && source.coverUrl.length > 0 && track.coverUrl !== source.coverUrl) {
      // 两侧封面不同是常态（专辑图 vs 视频截图），这里留一行证据：
      // 线上再出现「播放页的图与列表不一致」时，看这行即可确认最终采用了哪一张。
      console.info(`cover=list ${track.coverUrl.slice(0, 80)} | source=${source.coverUrl.slice(0, 80)}`);
    }
    return {
      id: track.id,
      title: track.title.length > 0 ? track.title : source.title,
      artist: track.artist.length > 0 ? track.artist : source.artist,
      coverUrl: cover,
      duration: source.duration > 0 ? source.duration : track.duration,
      videoUrl: track.videoUrl,
      bvid: track.bvid.length > 0 ? track.bvid : source.bvid,
      aid: source.aid > 0 ? String(source.aid) : track.aid,
      cid: source.cid > 0 ? String(source.cid) : track.cid,
      // `?? ''`：旧版本落盘的曲目没有 upMid，不兜住会把 undefined 一路传到界面上
      upMid: track.upMid ?? '',
      playCount: track.playCount,
      // 发布时间属列表侧元数据，音源侧（TrackSource）没有 —— 原样保留
      pubdate: track.pubdate,
      // 最近播放时间同样属列表侧元数据，原样保留（?? 0 兜旧数据）
      playedAt: track.playedAt ?? 0,
      // 上次听到的位置同属列表侧元数据，原样保留（?? 0 兜旧数据）
      lastPosSec: track.lastPosSec ?? 0,
      isLiked: track.isLiked,
      likedAt: track.likedAt,
      audioUrl: source.audioUrl,
      audioQuality: source.audioQuality,
      // 实测带宽同样「音源侧优先」，但要兜 0：音源侧的 bandwidth 来自 playurl 的
      // dash.audio[].bandwidth，若某条链路（缓存命中 / 本地文件切换）给的是 0，
      // 直接搬会把列表侧已解析出的码率抹成 0，播放页就显示不出码率了。
      audioBandwidth: source.audioBandwidth > 0 ? source.audioBandwidth : track.audioBandwidth,
      audioMimeType: source.audioMimeType,
      // 备用直链跟着解析结果走（列表侧落盘的曲目不带，取 ?? 兜旧数据）
      audioBackupUrls: source.audioBackupUrls
    };
  }

  /**
   * 重新解析当前曲目的音源并换源。
   *
   * @returns true = 新音源已交给播放器；false = 解析或挂载失败
   *          （**调用方必须据此继续降级**，见 recoverFromStall）
   *
   * ⚠️ 返回值是 2026-10-22 补的：旧版是 `Promise<void>`，失败只在内部
   * `console.error` 一行，调用方永远等不到「失败」这个事实 —— 于是恢复链在
   * 第 2 级就**断掉**：备用直链用完 + 重解析失败（断网 / -404 / 该档音轨全挂）
   * ＝ 加载圈停下、没有任何声音、也没有任何提示，用户只能反复点歌。
   */
  private async reloadCurrentSource(): Promise<boolean> {
    const track: Track | null = this.currentTrackSnapshot();
    if (!track) {
      return false;
    }
    // ⚠️ 这里**绝不能**写成 `++this.loadToken` 去抢占 token。
    // 抢占会把正在进行的 `loadAndPlay`（用户刚点的那首歌）直接作废：
    // 它 await 回来时 `token !== this.loadToken`，会静默 return，连音源都不切
    // —— 表现就是「点了新歌，信息都换了，但没声音 / 还是上一首」。
    // reload 的职责只是给**当前曲目**重试一次音源，跟随当前 token 即可。
    const token: number = this.loadToken;
    this.isPreparing = true;
    try {
      // refresh=true：走到重试说明播放器报了 error，最常见的原因就是缓存里的
      // 直链已过期（CDN 签名失效）。必须绕过缓存重新解析，否则会拿同一条过期
      // 链接重试三次、次次失败。新结果会回写缓存。
      //
      // 档位（2026-10-22 起）走降档阶梯：第 1 次仍用用户偏好档，第 2 次起逐级降低。
      // 旧版恒用偏好档，若坏在「这一档音轨本身」（flac 解码失败 / 该档 CDN 全拒），
      // 三次重试全打在同一档上，永远出不了声。
      const qualityId: number = this.recoveryQualityId();
      const source = await extractAudioFromVideo(track.bvid || track.id, {
        aid: track.aid,
        cid: track.cid
      }, qualityId, true);
      if (token !== this.loadToken) {
        // 已被更新的点歌取代：不是失败，由获胜方负责收尾
        return false;
      }
      const updated: Track = this.mergeTrack(track, source);
      this.setStore(STORE_CURRENT_TRACK, updated);
      this.lastPlayableTrack = updated;
      // 换源统一走「重建播放器」：见 switchSource 注释。
      // quiet=true：这是恢复链内部的一次尝试，失败由 recoverFromStall 继续降级，
      // 不能在这里就弹「加载失败」（链走完还没成，③ 会给用户明确交代）
      const attached: boolean = await this.switchSource(updated.audioUrl, token, true);
      this.isPreparing = false;
      if (attached) {
        plogInfo(`reload source ok (quality=${source.audioQuality}, step=${this.qualityStep})`);
      }
      return attached;
    } catch (e) {
      // 失败必须解除准备态，否则 timeUpdate 会被永久抑制、进度条卡死
      this.isPreparing = false;
      this.setStore(STORE_LOADING_AUDIO, false);
      // 不要 JSON.stringify(e)：Error 的 message/stack 不可枚举，序列化只有 {}
      const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      plogWarn(`reload audio failed (step=${this.qualityStep}): ${detail}`);
      if (this.isRiskControlError(e)) {
        // 重解析撞上风控：升级 buvid（自带冷却闸门）。恢复链若还有重试额度，
        // 下一次 reload 会落在（可能已升级的）新指纹上
        this.healBuvidForRiskControl();
      }
      return false;
    }
  }

  /**
   * 启动 prepare 看门狗：进入 initialized 后 PREPARE_TIMEOUT_MS 内没走到
   * prepared / error 就认定「状态机卡死」（setMediaSource rejection 被吞的典型
   * 后果），主动走 recoverFromStall 自愈。带 loadToken 快照：超时瞬间若已被
   * 新一次点歌取代则静默作废，绝不误伤新加载。
   */
  private startPrepareWatchdog(): void {
    this.cancelPrepareWatchdog();
    const token: number = this.loadToken;
    this.prepareWatchdogTimer = setTimeout((): void => {
      this.prepareWatchdogTimer = -1;
      if (token !== this.loadToken) {
        // 看门狗存续期间已被更新的点歌取代：新加载有自己的看门狗，这里作废
        return;
      }
      if (this.playerState !== 'initialized') {
        // 状态已推进（prepared / error / 已重建）：正常路径收过场，无需自愈
        return;
      }
      plogWarn(`prepare watchdog fired, stuck at initialized for ${PREPARE_TIMEOUT_MS}ms`);
      this.recoverFromStall();
    }, PREPARE_TIMEOUT_MS);
  }

  private cancelPrepareWatchdog(): void {
    if (this.prepareWatchdogTimer !== -1) {
      clearTimeout(this.prepareWatchdogTimer);
      this.prepareWatchdogTimer = -1;
    }
  }

  /**
   * 统一的「播放卡死 / 出错」恢复入口（error 处理器与 prepare 看门狗共用）。
   * 恢复梯度由轻到重，**每一级失败都会自动落到下一级**（2026-10-22 修）：
   * ⓪ 断网短路：网络都没了就直说，别再跑 20 秒的三级重试；
   * ① 备用直链：playurl 每条音轨都带 backupUrl（最多用 3 条）。主直链被 CDN
   *    拒绝 / 挂死时直接换链重挂，**不发任何网络请求**，秒级恢复；
   * ② 重解析：refresh 直链重走 view + playurl（最常见原因是直链签名过期），
   *    第 2 次起**逐级降档**（治「这一档音轨本身播不了」）；
   * ③ 重试耗尽：明确提示用户，不再让界面停在假「播放中」。
   *
   * ⚠️ 旧版最大的缺陷是「② 失败后链就断了」：reloadCurrentSource 是 Promise<void>，
   * 内部 catch 只打一行日志就结束 —— 备用直链用完 + 重解析失败（断网 / -404 /
   * 该档全挂）时，界面表现为「加载圈停了、没声音、没提示」。现在 reload 返回
   * boolean，失败即继续走本函数（retryCount 已 +1，所以必然收敛到 ③）。
   */
  private recoverFromStall(): void {
    const track: Track | null = this.currentTrackSnapshot();
    if (!track) {
      // 界面上已没有曲目（清空队列等场景）：没有可恢复的对象
      plogWarn('recoverFromStall skipped: no current track');
      return;
    }
    // ⓪ 断网短路：三级梯度每级都要等超时，断网时纯属干等。
    // 不清 retryCount / triedBackupCount —— 网络恢复后用户点播放走的是完整的新一轮
    // loadAndPlay（两个游标都在那里归零）。
    if (!hasNetwork()) {
      plogWarn('recover skipped: no network');
      this.isPreparing = false;
      this.setStore(STORE_LOADING_AUDIO, false);
      this.setStore(STORE_IS_PLAYING, false);
      this.notifyHint('网络未连接，请检查网络后重试');
      return;
    }
    const token: number = this.loadToken;
    const backups: string[] = track.audioBackupUrls ?? [];
    // ① 备用直链：本轮加载还没把 3 条用完，就先试下一条
    if (this.triedBackupCount < 3 && this.triedBackupCount < backups.length) {
      const backupUrl: string = backups[this.triedBackupCount];
      this.triedBackupCount++;
      plogWarn(`recover via backup url #${this.triedBackupCount}: ${urlHostOf(backupUrl)}`);
      this.isPreparing = true;
      this.setStore(STORE_LOADING_AUDIO, true);
      // quiet=true：备用链失败要继续降级，不在中途弹提示（理由同 reloadCurrentSource）
      this.switchSource(backupUrl, token, true)
        .then((attached: boolean): void => {
          if (token !== this.loadToken) {
            return;
          }
          if (attached) {
            this.isPreparing = false;
            return;
          }
          // 备用链也挂不上：继续下一级（旧版直接放弃，界面停在加载中）
          this.recoverFromStall();
        })
        .catch((e: Error): void => {
          plogWarn(`switch to backup url failed: ${e.message}`);
          this.recoverFromStall();
        });
      return;
    }
    // ② 重新解析直链（refresh=true，绕过缓存；第 2 次起降档）
    if (this.retryCount < RECOVER_RELOAD_MAX) {
      if (this.recovering) {
        // 上一轮 reload 还没落地（error 回调与 prepare 看门狗可能在同一瞬间各来一次）：
        // 不叠加发起、也不预支重试额度 —— 等它走完，失败时自己会回来继续降级
        plogWarn('recover reload already in flight, skip duplicate');
        return;
      }
      this.retryCount++;
      // 第 1 次仍用偏好档（直链过期最常见，换档等于白降音质），第 2/3 次逐级降档
      this.qualityStep = this.retryCount - 1;
      plogWarn(`recover via reload, attempt ${this.retryCount}/${RECOVER_RELOAD_MAX}, ` +
        `quality step ${this.qualityStep}`);
      this.recovering = true;
      this.reloadCurrentSource()
        .then((ok: boolean): void => {
          this.recovering = false;
          if (ok) {
            return;
          }
          if (token !== this.loadToken) {
            // 本轮已被更新的点歌取代：不做任何收尾，新加载有自己的梯度
            return;
          }
          // ⚠️ 这一句就是「恢复链不中断」的关键：重解析失败也继续降级
          this.recoverFromStall();
        })
        .catch((e: Error): void => {
          this.recovering = false;
          plogWarn(`reloadCurrentSource threw: ${e.message}`);
          this.recoverFromStall();
        });
      return;
    }
    // ③ 重试耗尽：必须给用户一个明确交代。否则界面只是悄悄停在暂停态，
    // 用户完全不知道发生了什么（表现为「点了没反应」）。
    this.recovering = false;
    this.isPreparing = false;
    this.setStore(STORE_LOADING_AUDIO, false);
    this.setStore(STORE_IS_PLAYING, false);
    if (this.recoverExhausted) {
      // 本轮已经交代过了：残余 error 只留日志，不再重复弹提示
      plogWarn('recover exhausted again (already notified), stay silent');
      return;
    }
    this.recoverExhausted = true;
    plogWarn('recover exhausted: all backups and reloads failed');
    this.notifyHint('音频加载失败，请检查网络或稍后重试');
  }

  /**
   * 换源：**摘掉旧播放器的监听 → release 掉 → 新建一个干净的 AVPlayer**，再挂载新音源。
   *
   * 为什么不用「复用同一个实例 + reset()」：
   * reset() 会让**旧音源**上未完成的请求报一次 error，而 error 回调又会去重试换源，
   * 于是形成 `reset → error → reload → reset` 的正反馈 —— 重试次数瞬间耗尽、
   * 播放器卡在 error/idle，表现就是「切哪首歌都没声音」。
   * 之前是靠一个「静默窗口」去猜哪条 error 是换源副作用，属于用补丁绕架构问题。
   *
   * 参考工程（BiliMusic-main/service/AudioPlayer.ets）的做法更彻底：每次 setSource
   * 前把旧实例的监听 off 掉并 release()，再 createAVPlayer()。这样
   * ①旧实例的错误根本传不出来，②新实例天然处于 idle（setMediaSource 永远合法），
   * 整个「哪条错误属于谁」的歧义就不存在了。这里照做。
   *
   * @param quiet true = 失败时**不弹提示**（恢复链内部用）。
   *        恢复链会连续试「备用直链 → 重解析 ×3」，每一步都弹一次
   *        「音频加载失败」就是在撒谎 —— 最后往往还播上了。只在整条链走完（③）弹一次。
   */
  private async switchSource(url: string, token: number, quiet: boolean = false): Promise<boolean> {
    if (token !== this.loadToken) {
      // 加载已被更新的点歌取代：不再重建播放器、不碰任何状态，收尾由获胜方负责
      return false;
    }
    if (url.length === 0) {
      // 直链为空时 setMediaSource 不会报错但也不会有任何声音，
      // 用户只看到「点了歌、封面歌名都换了，就是没声」。这里明确失败并留日志。
      plogWarn('switchSource with empty url');
      this.isPreparing = false;
      this.setStore(STORE_LOADING_AUDIO, false);
      this.setStore(STORE_IS_PLAYING, false);
      if (!quiet) {
        this.notifyHint('音频地址为空，请稍后重试');
      }
      return false;
    }
    const player: media.AVPlayer | null = await this.ensurePlayer();
    if (!player) {
      // 播放器都建不出来：必须解除准备态，否则 play() 会因 isPreparing 永真而
      // 变成死键（点一下毫无反应），timeUpdate 也会被永久抑制、进度条卡死。
      this.isPreparing = false;
      this.setStore(STORE_LOADING_AUDIO, false);
      this.setStore(STORE_IS_PLAYING, false);
      // 播放器建不出来是「设备侧」问题，恢复链再试也无解 → 这条不静默
      this.notifyHint('播放器初始化失败，请重开应用后再试');
      return false;
    }
    if (player !== this.avPlayer) {
      // 已被并发的新一次换源取代（它已把这个实例 release 掉），本次结果作废
      return false;
    }
    if (token !== this.loadToken) {
      // 等待播放器重建期间又被更新的点歌抢了先：静默作废，不回滚界面、不弹提示
      // （此时新一次加载已经接管了 isPreparing / STORE_* 状态，动一下就是串台）
      return false;
    }
    let mediaSource: media.MediaSource;
    try {
      // @SuppressWarnings syscap
      mediaSource = media.createMediaSourceWithUrl(url, {
        Referer: BILI_REFERER,
        'User-Agent':
          'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile'
      });
    } catch (e) {
      const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      plogWarn(`createMediaSourceWithUrl failed: ${detail}`);
      this.failLoad('音频加载失败，请稍后重试', quiet);
      return false;
    }
    plogInfo(`attach main url: ${urlHostOf(url)}`);
    // 2026-10-20 关键修正：挂载结果必须**真正等到手**。旧版把 setMediaSource 的
    // rejection 交给回调就无条件 return true —— rejection 被吞后状态机停在
    // idle/initialized，调用方却当「挂上了」继续走「播放中」的收尾，
    // 表现正是「点了歌、封面歌名都换了、一直没声、也不报错」。
    const attached: boolean = await attachMediaSourceSafely(player, mediaSource);
    if (token !== this.loadToken) {
      // 挂载等待期间被更新的点歌取代：结果作废，一切收尾由获胜方负责
      return attached;
    }
    if (!attached) {
      // setMediaSource 明确拒绝（url 非法 / 头部被拒 / 状态不对）：
      // failLoad 统一收口（解除准备态、清 loading、停播放态、提示用户）
      this.failLoad('音频加载失败，请稍后重试', quiet);
      return false;
    }
    // true = 音源已经交给播放器（音频这一侧已经有着落），
    // 调用方据此区分「真的没挂上音源」与「挂上之后收尾环节才出的岔子」。
    return true;
  }

  /**
   * 换源（本地文件版）：把沙箱里下载好的 .m4a 挂到播放器上。
   *
   * 用 `media.createMediaSourceWithFd` 而不是拼一个 `file://` URL：
   * 本地文件没有「可解析的 URL」这个语义，fd 才是官方入口。文档要求 fd 由调用方关闭，
   * 所以句柄存进 `localFile`，由下一次换源（ensurePlayer 开头）统一关掉。
   *
   * 返回值含义与 `switchSource` 严格对齐：true = 音源已交给播放器。
   *
   * ⚠️ 这是「已下载的文件点不动」这条反馈的正解：此前下载页只有删除按钮，
   * 压根没有播放入口；即便有，播放内核也只认 http 直链。
   */
  private async switchSourceLocal(path: string, token: number): Promise<boolean> {
    if (token !== this.loadToken) {
      // 加载已被更新的点歌取代：不再重建播放器、不碰任何状态（同 switchSource）
      return false;
    }
    const player: media.AVPlayer | null = await this.ensurePlayer();
    if (!player) {
      this.failLoad('播放器初始化失败，请重开应用后再试');
      return false;
    }
    if (player !== this.avPlayer) {
      // 已被并发的新一次换源取代（它已把这个实例 release 掉），本次结果作废
      return false;
    }
    if (token !== this.loadToken) {
      // 等待播放器重建期间又被更新的点歌抢了先：静默作废（同 switchSource）
      return false;
    }
    let size: number = 0;
    try {
      // （2026-10-16 AppFreeze 加固）statSync → 异步 stat，不阻塞主线程
      size = (await fs.stat(path)).size;
    } catch (e) {
      console.error(`stat local audio failed: ${JSON.stringify(e)}`);
    }
    if (token !== this.loadToken) {
      // 异步 stat 期间被更新的点歌取代（本次加固新增的 await 点）：静默作废
      return false;
    }
    if (!(size > 0)) {
      this.failLoad('本地文件不存在，请重新下载');
      return false;
    }
    let file: fs.File | null = null;
    try {
      // （2026-10-16 AppFreeze 加固）openSync → 异步 open
      file = await fs.open(path, fs.OpenMode.READ_ONLY);
    } catch (e) {
      console.error(`open local audio failed: ${JSON.stringify(e)}`);
    }
    if (!file) {
      this.failLoad('本地文件无法打开，请重新下载');
      return false;
    }
    if (token !== this.loadToken) {
      // 异步 open 期间被取代：句柄没交出去，自己关掉别漏 fd，再静默作废
      try {
        await fs.close(file.fd);
      } catch (e) {
        console.error(`close stale local fd failed: ${JSON.stringify(e)}`);
      }
      return false;
    }
    let source: media.MediaSource | undefined = undefined;
    try {
      source = media.createMediaSourceWithFd({ fd: file.fd, offset: 0, length: size });
    } catch (e) {
      console.error(`createMediaSourceWithFd failed: ${JSON.stringify(e)}`);
    }
    if (!source) {
      // 建 MediaSource 失败：句柄没交出去，自己关掉，别漏 fd
      try {
        await fs.close(file.fd);
      } catch (e) {
        console.error(`close unused local fd failed: ${JSON.stringify(e)}`);
      }
      this.failLoad('本地文件无法播放，请重新下载');
      return false;
    }
    // ensurePlayer 已经关掉了上一个本地句柄，这里接手新句柄
    this.localFile = file;
    plogInfo(`attach local file: ${path}`);
    // 与在线链路同理（见 switchSource）：挂载结果必须等到手，拒绝时明确失败
    const attached: boolean = await attachMediaSourceSafely(player, source);
    if (token !== this.loadToken) {
      // 挂载等待期间被更新的点歌取代：结果作废（句柄已交由 this.localFile 管理）
      return attached;
    }
    if (!attached) {
      this.failLoad('本地文件无法播放，请重新下载');
      return false;
    }
    return true;
  }

  /**
   * 播放本地（已下载）文件。
   *
   * 结构与在线链路刻意保持一致 —— 同样的 token 校验、同样的 `pendingSeekTo` 续播机制、
   * 同样的 `recordRecent` 时点，唯一区别是「不发任何网络请求」。
   * 这样 play / pause / seek / 自动下一首这些既有逻辑一行都不用动。
   */
  private async loadLocalFile(
    track: Track,
    path: string,
    autoplay: boolean,
    startAt: number,
    token: number
  ): Promise<void> {
    // 与 loadAndPlay 同源的重建计数快照（本地链路同样可能加载失败需要回滚）
    const seqBeforeLoad: number = this.playerRebuildSeq;
    try {
      this.setStore(STORE_CURRENT_TRACK, track);
      // 与在线链路一致：元数据延迟到出声再上报，避免封面下载抢占缓冲带宽
      this.pendingMetadataTrack = track;
      if (!autoplay) {
        this.flushPendingMetadata();
      }
      if (startAt > 0) {
        this.pendingSeekTo = startAt;
        this.pendingAutoPlayAfterSeek = autoplay;
        this.shouldAutoplay = false;
      } else {
        this.pendingSeekTo = -1;
        this.pendingAutoPlayAfterSeek = false;
        this.shouldAutoplay = autoplay;
      }
      const attached: boolean = await this.switchSourceLocal(path, token);
      if (token !== this.loadToken) {
        return;
      }
      if (!attached) {
        this.recoverAfterLoadFailure(track, seqBeforeLoad);
        return;
      }
      this.recordRecent(track);
      this.isPreparing = false;
      this.setStore(STORE_LOADING_AUDIO, false);
      this.lastPlayableTrack = track;
      if (autoplay && startAt <= 0) {
        this.setStore(STORE_IS_PLAYING, true);
      }
      try {
        // 2026-10-08（B1）：本地链路同理——进度传意图位置，不用清零的中间态
        this.savePlayerStateNow(startAt);
      } catch (e) {
        console.error(`persist local playback side effects failed: ${JSON.stringify(e)}`);
      }
      // 本地链路同样预取下一首（下一首可能是在线曲目）
      this.scheduleNextSourcePrefetch();
    } catch (e) {
      this.isPreparing = false;
      if (token !== this.loadToken) {
        return;
      }
      console.error(`load local audio failed: ${JSON.stringify(e)}`);
      this.setStore(STORE_LOADING_AUDIO, false);
      this.setStore(STORE_IS_PLAYING, false);
      this.recoverAfterLoadFailure(track, seqBeforeLoad);
    }
  }

  /**
   * 加载失败统一收口：解除准备态、清 loading、停播放态、（可选）提示用户。
   *
   * @param quiet true = 不弹提示。恢复链内部专用（见 switchSource 的 quiet 说明）。
   */
  private failLoad(message: string, quiet: boolean = false): void {
    this.isPreparing = false;
    this.setStore(STORE_LOADING_AUDIO, false);
    this.setStore(STORE_IS_PLAYING, false);
    if (!quiet) {
      this.notifyHint(message);
    }
  }

  /** 判定解析错误是否为 B 站风控 / 限流（码表见 RISK_CONTROL_CODES） */
  private isRiskControlError(e: Object): boolean {
    return e instanceof BiliApiError && RISK_CONTROL_CODES.indexOf(e.code) >= 0;
  }

  /**
   * 风控自愈：把 buvid Cookie 升级成官方指纹（兜底假 buvid 被风控盯死的对症解）。
   * 升级是异步的、不阻塞任何链路；完成后由后续解析 / AppContainer 的延迟重试
   * 自然用上新指纹。返回 false = 冷却期内已自愈过，调用方据此不再叠加自动重试。
   */
  private healBuvidForRiskControl(): boolean {
    if (Date.now() - this.lastRiskControlSelfHealAt < RISK_SELF_HEAL_COOLDOWN_MS) {
      return false;
    }
    this.lastRiskControlSelfHealAt = Date.now();
    plogWarn('risk control detected, upgrading buvid cookie');
    upgradeBuvidCookie()
      .then((): void => {
        plogInfo('buvid cookie upgraded after risk control');
      })
      .catch((e: Error): void => {
        plogWarn(`buvid upgrade after risk control failed: ${e.message}`);
      });
    return true;
  }

  /** 关闭本地播放文件句柄。重复调用安全（换源 / 回收播放器都会走到这里） */
  private closeLocalFile(): void {
    const file: fs.File | null = this.localFile;
    this.localFile = null;
    if (!file) {
      return;
    }
    // （2026-10-16 AppFreeze 加固）closeSync → 异步 close：先摘引用再关，重复调用安全
    fs.close(file.fd).catch((e: object): void => {
      console.error(`close local audio failed: ${JSON.stringify(e)}`);
    });
  }

  /**
   * 新建一个干净的 AVPlayer。
   * 先把旧实例的监听**全部摘掉**再 release —— 摘监听是关键，否则旧实例在释放过程中
   * 上报的 error 会被当成「新音源加载失败」，弹出一个莫名其妙的提示。
   * 新实例是全新默认值，音频流类型改由状态机在**合法时机**补上
   * （见 applyRendererInfoInInitialized）。
   */
  /**
   * 串行化入口：同一时刻只允许一个「摘监听 → release 旧的 → createAVPlayer 新的」
   * 在执行，后来的调用排队等前一个做完再开工（理由见 playerRebuildChain 注释）。
   * 真正的重建逻辑在 rebuildPlayerLocked 里。
   */
  private ensurePlayer(): Promise<media.AVPlayer | null> {
    const previous: Promise<void> = this.playerRebuildChain;
    const result: Promise<media.AVPlayer | null> = previous.then((): Promise<media.AVPlayer | null> => {
      return this.rebuildPlayerLocked();
    });
    // 挂 noop 的失败处理：rebuildPlayerLocked 内部已兜住全部异常，这里只是
    // 保证互斥链在任何意外下都不断裂（链一旦 reject，后续重建会全部死锁）
    this.playerRebuildChain = result.then((): void => {
    }, (): void => {
    });
    return result;
  }

  private async rebuildPlayerLocked(): Promise<media.AVPlayer | null> {
    const old: media.AVPlayer | null = this.detachAndClearPlayer();
    if (old) {
      try {
        await old.release();
      } catch (e) {
        console.error(`release old avPlayer failed: ${JSON.stringify(e)}`);
      }
    }
    // 旧播放器已释放，它读着的本地文件句柄这时才能安全关闭（顺序不能提前）
    this.closeLocalFile();
    try {
      // @SuppressWarnings syscap
      const player: media.AVPlayer = await media.createAVPlayer();
      this.avPlayer = player;
      this.playerState = 'idle';
      this.registerAvPlayerEvents(player);
      return player;
    } catch (e) {
      console.error(`create avPlayer failed: ${JSON.stringify(e)}`);
      return null;
    }
  }

  /**
   * 设置音频流类型（音乐）。合法窗口是 idle/initialized，但**不能**在新播放器的
   * idle 态调用：部分系统版本直接报 5400102「unsupport to set audio renderer info」
   * （旧版 applyPlayerConfig 在 createAVPlayer 返回后立即设置，线上日志里
   * 每次点歌都带着这条错）。改到 stateChange('initialized')（setMediaSource
   * 已被接受之后）再设，见 registerAvPlayerEvents。
   */
  private applyRendererInfoInInitialized(player: media.AVPlayer): void {
    try {
      player.audioRendererInfo = {
        content: audio.ContentType.CONTENT_TYPE_MUSIC,
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0
      };
    } catch (e) {
      // 配置音频流类型失败不影响播放，系统会退回默认值
      console.error(`set audioRendererInfo failed: ${JSON.stringify(e)}`);
    }
  }

  /**
    * 补应用倍速到播放器。setSpeed 的合法窗口是 prepared/playing/paused/completed。
    * 换源每次都重建 AVPlayer，倍速必须在新实例 prepared 时重补，
    * 否则「切歌后倍速悄悄变回 1.0」（同当年音量丢失 bug 的根因）。
   * 开关关闭或倍速为 1.0 时不调——1.0 是系统默认，多调一次反而多一条
   * speedDone 噪音日志；关闭态强制不补，防止异常脏值在重启后复活倍速。
   */
  private applySpeedOnPrepared(player: media.AVPlayer): void {
    const enabled: boolean = (AppStorage.get(STORE_PLAYBACK_SPEED_ENABLED) as boolean) ?? false;
    if (!enabled || this.playbackSpeed === 1.0) {
      return;
    }
    try {
      player.setSpeed(speedToPlaybackSpeed(this.playbackSpeed));
    } catch (e) {
      console.error(`setSpeed on prepared failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 换源重建后补应用「与其他应用同时播放」打断模式（2026-10-21）。
   * 读镜像开关（缺省 false 即关闭态）：开启 = INDEPENDENT_MODE（播放不被其他
   * 应用音频打断、也不抢占对方），关闭 = SHARE_MODE（默认焦点行为）。
   * audioInterruptMode 是 AVPlayer 可选属性（本 SDK 无 setAudioInterruptMode
   * 方法），赋值失败（低版本设备不支持等）只影响混音开关，不影响播放本身。
   */
  private applyInterruptModeOnPrepared(player: media.AVPlayer): void {
    try {
      const mix: boolean = AppStorage.get<boolean>(STORE_AUDIO_MIX_ENABLED) ?? false;
      player.audioInterruptMode =
        mix ? audio.InterruptMode.INDEPENDENT_MODE : audio.InterruptMode.SHARE_MODE;
    } catch (e) {
      console.error(`apply audioInterruptMode on prepared failed: ${JSON.stringify(e)}`);
    }
  }

  /** 摘掉某个播放器实例上的全部监听（换源前必做，避免旧实例的错误污染新音源） */
  private detachPlayerEvents(player: media.AVPlayer): void {
    try {
      player.off('stateChange');
      player.off('timeUpdate');
      player.off('durationUpdate');
      player.off('error');
      player.off('seekDone');
      player.off('audioInterrupt');
    } catch (e) {
      console.error(`detach player events failed: ${JSON.stringify(e)}`);
    }
  }

  /** 摘监听 + 把实例字段置空，返回被摘下来的旧实例（调用方决定同步/异步 release） */
  private detachAndClearPlayer(): media.AVPlayer | null {
    const old: media.AVPlayer | null = this.avPlayer;
    this.avPlayer = null;
    // 旧实例即将被 release：它握着的音源从此不再可能出声，重建计数 +1
    this.playerRebuildSeq++;
    this.playerState = 'idle';
    // 旧实例名下的 prepare 看门狗一并取消：不取消的话，它超时触发时面对的
    // 已是新实例 / 新状态，recoverFromStall 会在错误的时机横插一脚
    this.cancelPrepareWatchdog();
    // 旧实例从此不再出声，听歌计时游标必须一并复位，
    // 否则换源 / 重建播放器期间的静默空窗会被下一拍误计入时长
    this.lastListenTickAt = -1;
    if (old) {
      this.detachPlayerEvents(old);
    }
    return old;
  }

  /** 彻底回收播放器实例；下一次播放会在 switchSource 里重新建一个干净的 */
  private dropPlayer(): void {
    const old: media.AVPlayer | null = this.detachAndClearPlayer();
    if (old) {
      try {
        old.release();
      } catch (e) {
        console.error(`release avPlayer failed: ${JSON.stringify(e)}`);
      }
    }
    // 走到这里说明用户明确不播了（清空队列），本地句柄一并回收，别漏 fd
    this.closeLocalFile();
  }

  /**
   * 「本地优先」（2026-10-08）：曲目已下载完成时，克隆一份带本地路径的 Track
   * 交给 loadLocalFile 走本地播放链路。
   *
   * 刻意**逐字段拷贝**而不是改写原对象的 localFilePath：队列 / 最近播放 / 歌单 /
   * 页面列表共享同一份 Track 引用，原地改写会把「在线条目」永久变成「本地条目」
   * —— 之后用户删掉下载文件，这条曲目就再也播不出来了（localFilePath 非空直接
   * 走本地分支，不再回在线解析）。克隆只影响本次播放链路，与下载页 toLocalTrack
   * 的做法一致。不用 buildTrack({...track}) 的展开写法：ArkTS 禁用 spread。
   */
  private withLocalPath(track: Track, localPath: string): Track {
    return {
      id: track.id,
      title: track.title,
      artist: track.artist,
      coverUrl: track.coverUrl,
      duration: track.duration,
      videoUrl: track.videoUrl,
      bvid: track.bvid,
      aid: track.aid,
      cid: track.cid,
      upMid: track.upMid,
      playCount: track.playCount,
      pubdate: track.pubdate,
      playedAt: track.playedAt ?? 0,
      lastPosSec: track.lastPosSec ?? 0,
      isLiked: track.isLiked,
      likedAt: track.likedAt,
      audioUrl: track.audioUrl,
      audioQuality: track.audioQuality,
      audioBandwidth: track.audioBandwidth,
      audioMimeType: track.audioMimeType,
      localFilePath: localPath
    };
  }

  private async loadAndPlay(track: Track, autoplay: boolean, startAt: number = 0): Promise<void> {
    const token: number = ++this.loadToken;
    // 本次加载开始前的重建计数快照：recoverAfterLoadFailure 据此判断播放器
    // 握着的音源属于本次点歌还是上一首（见该方法的闸门说明）
    const seqBeforeLoad: number = this.playerRebuildSeq;
    this.shouldAutoplay = autoplay;
    this.retryCount = 0;
    // 备用直链计数跟着每轮点歌一起归零：新一轮加载重新拥有完整的恢复梯度
    this.triedBackupCount = 0;
    // 降档游标与「恢复进行中」标志同样归零：新一轮点歌必须从用户偏好档、
    // 从恢复链第 0 级重新开始（否则上一首降档到 64K 会传染给下一首）
    this.qualityStep = 0;
    this.recovering = false;
    this.recoverExhausted = false;
    // 旧歌的进度 / 时长先存一份：下面会立刻清零给新歌腾显示位，
    // 加载失败回滚时靠它把旧歌的显示还原（见 recoverAfterLoadFailure）
    this.preLoadProgress = (AppStorage.get(STORE_PROGRESS) as number) ?? 0;
    this.preLoadDuration = (AppStorage.get(STORE_DURATION) as number) ?? 0;
    // 换曲：时长与进度分桶游标必须一起复位，否则新曲会沿用上一首的总时长
    // （拖动进度条按旧时长换算，seek 到的位置完全不对）
    this.lastDuration = 0;
    this.lastProgressBucket = -1;
    this.setStore(STORE_LOADING_AUDIO, true);
    this.setStore(STORE_PROGRESS, 0);
    this.setStore(STORE_DURATION, 0);
    // 切歌瞬间先把上一段已听的时长收尾落盘：
    // 准备新音源可能耗时数秒且进程随时可能被杀，不能等攒满阈值再写
    this.finalizeListenSegment();
    // 进入「准备中」：解析音源 + 重建播放器期间，旧音源还在出声，
    // 它的 timeUpdate 必须被忽略（理由见 isPreparing 字段注释）
    this.isPreparing = true;
    // 2026-10-08（B1/B5）：记录本次起始定位——准备期间 STORE_PROGRESS 已清零、
    // seek 未生效，这段时间内的落盘（如缓冲中按暂停）都必须用这个「意图位置」
    this.loadStartAt = startAt > 0 ? startAt : 0;
    // 上一轮加载若失败，可能残留一个待上报的元数据；先清掉，下面按新曲目重新登记
    this.pendingMetadataTrack = null;

    // 已下载的曲目走本地链路：直接播沙箱文件，不发任何网络请求。
    // 这条判断放在「准备中」之后，是因为 loadLocalFile 同样要维护 isPreparing
    // 语义（它也会重建播放器，期间旧音源仍在出声）。
    const localPath: string = track.localFilePath ?? '';
    if (localPath.length > 0) {
      await this.loadLocalFile(track, localPath, autoplay, startAt, token);
      return;
    }
    // 本地优先（2026-10-08）：歌单 / 队列 / 最近播放里的条目落盘时被剥掉了
    // localFilePath（slimTrack 的调用方为省 Preferences 体积会清理字段，歌单导出
    // 更是完全不带），播放已下载曲目却走在线流 —— 耗流量、要解析、还慢。
    // 在线解析之前先查下载任务表：已下载的直接播沙箱文件。
    // 放在 MusicPlayer 层（而不是歌单页面层）是为了**所有入口统一生效**：
    // 歌单详情 / 队列弹层 / 搜索页 / 最近播放 / 自动切下一首，页面代码零特判。
    // 查不到（未下载 / 载入未完成）返回空串，照走在线流，行为与从前一致。
    const downloadedPath: string = DownloadManager.getInstance().completedLocalPath(track.id);
    if (downloadedPath.length > 0) {
      await this.loadLocalFile(this.withLocalPath(track, downloadedPath), downloadedPath, autoplay, startAt, token);
      return;
    }
    // 「音源是否已经交给播放器」。只有它为 false 时，下面的 catch 才认为
    // 这次点歌真的失败了；否则说明音频这一侧已经有着落，catch 到的异常
    // 只是收尾环节的岔子，绝不能据此回滚界面并弹「加载失败」。
    let attached: boolean = false;
    try {
      // ⚠️ 2026-10-08：这里**从「不传」改成传了** playQuality。
      // 原注释写「播放不跟着下载音质走是刻意的：试听要给最好的」，而
      // AppSettings.playQuality 存着却零读取方（设置项是死的）—— 用户能改、
      // 能看到、但什么都不发生。2026-10 用户拍板推翻那个决策：播放音质改为可用，
      // 标准档用户会真的听到 64k（这是他选的）。
      // 服务端没有该档时仍按 audioQualityCandidates 的预定义顺序降级，绝不会失败。
      // 影响面：`sourceCache` 的 cacheKey 含 preferredQuality（见 BilibiliApi
      // extractAudioFromVideo），所以改设置后缓存自然分裂，无需手动清缓存。
      const source = await extractAudioFromVideo(track.bvid || track.id, {
        aid: track.aid,
        cid: track.cid
      }, this.currentPlayQualityId());
      if (token !== this.loadToken) {
        return;
      }
      const updated: Track = this.mergeTrack(track, source);
      this.setStore(STORE_CURRENT_TRACK, updated);
      // 会话元数据延迟到真正出声（'playing'）再上报：它内部的封面下载
      // 会与音频首包缓冲抢带宽，推迟一两秒无感，但出声更快。
      this.pendingMetadataTrack = updated;
      if (!autoplay) {
        this.flushPendingMetadata();
      }
      if (startAt > 0) {
        // 续播：必须在 prepared 之后再 seek，否则 seek 会被丢弃，这里先登记待定位
        this.pendingSeekTo = startAt;
        this.pendingAutoPlayAfterSeek = autoplay;
        this.shouldAutoplay = false;
      } else {
        this.pendingSeekTo = -1;
        this.pendingAutoPlayAfterSeek = false;
        this.shouldAutoplay = autoplay;
      }
      attached = await this.switchSource(updated.audioUrl, token);
      if (!attached) {
        if (token !== this.loadToken) {
          // 作废原因是被更新的点歌取代（switchSource 内的 token 校验拦截），
          // 不是真的加载失败：新一次加载正持有全部状态，这里回滚界面必然串台
          return;
        }
        // 换源自身就失败了（空直链 / 播放器建不出来 / createMediaSourceWithUrl 抛错）。
        // 它已经把状态和提示处理过了，这里补一步失败收尾：把界面回滚到真实在播的那首，
        // 避免出现「封面歌名换了、声音还是上一首」的不一致。
        this.recoverAfterLoadFailure(track, seqBeforeLoad);
        return;
      }
      if (token !== this.loadToken) {
        return;
      }
      // ⚠️ 记「最近播放」必须紧贴在这里 —— 音源已挂上、且本次加载没有被新的一次取代，
      // 从这一刻起这一首就算「听过了」。放到收尾的最后一步会出事：收尾里任何一次
      // setStore / 会话落盘抛异常，都会被整段跳过，症状正是
      // 「歌照常播放，但最近播放里永远没有一项记录」。
      this.recordRecent(updated);
      this.isPreparing = false;
      if (autoplay && startAt <= 0) {
        this.setStore(STORE_IS_PLAYING, true);
      }
      this.setStore(STORE_LOADING_AUDIO, false);
      this.lastPlayableTrack = updated;
      // 会话落盘只是附带副作用，单独兜底：写不进去也绝不能反过来影响播放。
      // 2026-10-08（B1）：进度显式传 startAt——此刻 STORE_PROGRESS 还是清零的加载中间态，
      // 按 0 落盘会把磁盘上的续播点覆盖掉（缓冲中退出 / 解析失败即永久从头播）
      try {
        this.savePlayerStateNow(startAt);
      } catch (e) {
        console.error(`persist playback side effects failed: ${JSON.stringify(e)}`);
      }
      // 出声已有着落：悄悄预取下一首的直链，切歌 / 自动续播时直接命中缓存
      this.scheduleNextSourcePrefetch();
    } catch (e) {
      this.isPreparing = false;
      if (token !== this.loadToken) {
        return;
      }
      // ⚠️ 不要用 JSON.stringify(e)：Error 实例的 message / stack 都是不可枚举属性，
      // 序列化出来只有 {}，等于把真正的错误信息丢掉（这就是这类问题之前查不动的原因）。
      const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`load audio failed (attached=${attached}): ${detail}`);
      this.setStore(STORE_LOADING_AUDIO, false);
      this.setStore(STORE_IS_PLAYING, false);
      if (!attached && this.isRiskControlError(e)) {
        if (this.healBuvidForRiskControl()) {
          // 升级已发起：自动重试一轮。冷却闸门保证这条递归最多一层 ——
          // 重试仍撞风控时，那次 catch 落在冷却期内，转为下面的常规失败收口。
          this.notifyHint('触发 B 站风控，正在自动恢复，请稍后重试');
          this.loadAndPlay(track, autoplay, startAt).catch((retryErr: Error): void => {
            plogWarn(`risk-control retry threw: ${retryErr.message}`);
          });
          return;
        }
        // 冷却期内：不再叠加自动重试
      }
      if (!attached) {
        this.recoverAfterLoadFailure(track, seqBeforeLoad);
      } else {
        // 音源已经交给播放器了（这一首其实已经在出声），异常只发生在收尾环节，
        // 对播放没有任何影响。此时**既不回滚界面、也不弹「加载失败」**
        // —— 否则就会出现「明明在播，却每次点歌都提示加载失败」的误报。
        // 但要**补记一次最近播放**：异常可能发生在 894 行之前，
        // 那条记录就丢了（症状：歌能播，最近播放却一直是空的）。重复记录无害——
        // addRecentTrack 按 id 去重后置顶，天然幂等。
        this.recordRecent(track);
        console.error(`post-attach failure ignored: ${track.id}`);
      }
    }
  }

  /**
   * 记一条「最近播放」。
   *
   * 双重保险：① 调用点必须在音源挂上之后立刻执行（见 loadAndPlay 内注释）；
   * ② 自身吞掉全部异常 —— 记历史失败绝不能影响播放，也不能让调用方以为加载失败。
   */
  private recordRecent(track: Track): void {
    try {
      LibraryStore.addRecentTrack(track);
    } catch (e) {
      const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`record recent track failed: ${detail}`);
    }
  }

  /**
   * 节流记录当前曲目的「上次听到」位置（秒）到最近播放条目
   * （LibraryStore.updateRecentProgress，静默落盘不触发列表刷新）。
   *
   * - isPreparing 且无 override 时跳过：旧音源的 timeUpdate 位置属于上一首，
   *   写进新歌条目就是串数据（同 savePlayerStateNow 的 progressOverride 语义）。
   * - 默认按 RECENT_PROGRESS_THROTTLE_MS 节流；关键事件（暂停 / completed /
   *   release）传 force 立写。切歌时旧歌位置最多节流间隔（10s）陈旧，可接受。
   * - 听完（completed）由调用方显式传 0：条目不再显示「上次听到」、下次从头播。
   * - 失败只记日志：位置记忆绝不影响播放。
   */
  private recordRecentProgress(progressOverride?: number, force: boolean = false): void {
    const cur: Track | null = (AppStorage.get(STORE_CURRENT_TRACK) as Track) ?? null;
    if (!cur) {
      return;
    }
    const hasOverride: boolean = progressOverride !== undefined && progressOverride >= 0;
    // 准备新音源期间只有带意图位置（loadStartAt / 续播点）的调用才可信
    if (this.isPreparing && !hasOverride) {
      return;
    }
    const now: number = Date.now();
    if (!force && now - this.lastRecentProgressAt < RECENT_PROGRESS_THROTTLE_MS) {
      return;
    }
    this.lastRecentProgressAt = now;
    const pos: number = hasOverride ? (progressOverride as number)
      : (AppStorage.get(STORE_PROGRESS) as number) ?? 0;
    try {
      LibraryStore.updateRecentProgress(cur.id, pos);
    } catch (e) {
      const detail: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`record recent progress failed: ${detail}`);
    }
  }

  /**
   * 音源解析失败后的收尾：把界面回滚到真实在播的那首，并明确告知用户。
   *
   * 为什么必须有这一步：`playTrack` 会**先**把 STORE_CURRENT_TRACK 写成目标曲目再解析音源
   * （为了让界面立刻响应，不等网络）。解析失败时若不回滚，界面就会停在
   * 「封面歌名都换了、声音还是上一首」的不一致状态 —— 用户完全看不出发生了什么。
   * 回滚前要确认界面确实还停在失败的那首：用户可能已经手动切到别的歌，那就不该动。
   */
  private recoverAfterLoadFailure(failed: Track, seqBeforeLoad: number): void {
    // 加载失败：挂着的待上报元数据属于失败的那首，留着只会在下次 'playing'
    // 时把错误曲目的封面 / 标题报给系统，必须清掉。
    this.pendingMetadataTrack = null;
    // ⚠️ 最后一道闸门：状态机是 AVPlayer 亲自上报的，比任何标志位都可信 ——
    // 但必须连同重建计数（seqBeforeLoad）一起看。playerState 反映的是**当前
    // 挂着监听的实例**：若本次加载在「重建播放器」之前就失败了（音源解析抛错 /
    // 直链为空），挂着监听的仍是**上一首歌**的实例，playerState 照样是
    // prepared/playing。只看状态机就把回滚跳过，界面会停在「封面已切过去、
    // 声音还是旧歌」的不一致状态，且没有任何提示 —— 这正是「偶尔切歌不成功」的根因。
    // seq 门槛保证：只有「本次加载确实重建过播放器」（旧音源绝无可能还在响，
    // 握着的音源属于本次点歌或同 token 的并发重载）时才跳过回滚。
    if (this.playerHoldsSource() && this.playerRebuildSeq !== seqBeforeLoad) {
      console.error(`recover skipped, player already holds a source: ${this.playerState}`);
      return;
    }
    const current: Track | null = (AppStorage.get(STORE_CURRENT_TRACK) as Track) ?? null;
    const stillOnFailed: boolean = current !== null && current.id === failed.id;
    const fallback: Track | null = this.lastPlayableTrack;
    let rolledBack: boolean = false;
    if (stillOnFailed && fallback !== null && fallback.id !== failed.id) {
      this.setStore(STORE_CURRENT_TRACK, fallback);
      this.currentIndex = this.findIndexInDisplay(fallback.id);
      rolledBack = true;
      // 旧歌的播放从未被打断（本次加载没重建过播放器）：切歌瞬间被清零的
      // 时长 / 进度 / 播放态要按旧歌的真实状态还原，否则播放页会显示 0:00、
      // 总时长丢失、播放键状态与声音对不上。
      const restoreDur: number = fallback.duration > 0 ? fallback.duration : this.preLoadDuration;
      if (restoreDur > 0) {
        this.lastDuration = restoreDur;
        this.setStore(STORE_DURATION, restoreDur);
      }
      if (this.preLoadProgress > 0) {
        this.lastProgressBucket = -1;
        this.setStore(STORE_PROGRESS, this.preLoadProgress);
      }
      this.setStore(STORE_IS_PLAYING, this.playerState === 'playing');
      this.updateSessionState();
    }
    // 文案必须说清「切回了哪首」。早前只说「已保留当前歌曲」，用户看到界面上的
    // 封面歌名跟他刚点的那首不一样，会以为是「信息加载错了」——实际是回滚。
    const title: string = failed.title.length > 0 ? failed.title : '这首歌';
    if (rolledBack && fallback !== null) {
      const back: string = fallback.title.length > 0 ? fallback.title : '上一首';
      this.notifyHint(`「${title}」无法播放，已切回「${back}」`);
    } else {
      // 2026-10-22 修正：这种情况**必须**给提示。旧注释写「真正播不出来的歌会由
      // AVPlayer 的 error 链路统一给出提示」，但解析层失败（view/playurl 抛错、
      // 服务端 404、无音轨）时**根本没有 AVPlayer 参与**，也就永远不会有 error 回调
      // —— 界面停在用户点的那首、loading 圈消失、没有声音、也没有任何说明，
      // 这正是「点了没反应」最典型的一种。标题已写明是哪一首，重复点它不会更糟。
      plogWarn(`audio unavailable without rollback: ${failed.id}`);
      this.notifyHint(`「${title}」暂时无法播放，请稍后重试`);
    }
  }

  private playerHoldsSource(): boolean {
    const s: string = this.playerState;
    return s === 'prepared' || s === 'playing' || s === 'paused' || s === 'completed';
  }

  playTrack(track: Track, startAtSec: number = 0): void {
    // 「仅 WiFi 播放」：在线音源在蜂窝网络下不启动播放（本地已下载曲目不耗流量，放行）。
    // 探测失败一律放行（isUnmeteredNetwork 的约定：拦错了比放行更伤用户）。
    // 拦截点选在 playTrack：playNow / playAll / 自动切下一首全部经由这里，一处拦截全覆盖。
    const localPath: string = track.localFilePath ?? '';
    if (localPath.length === 0
      && AppPreferences.getSettings().wifiOnlyPlay
      && !isUnmeteredNetwork()) {
      this.notifyHint('已开启「仅 WiFi 播放」，当前为移动网络');
      return;
    }
    this.shouldAutoplay = true;
    this.setStore(STORE_CURRENT_TRACK, track);
    this.currentIndex = this.findIndexInDisplay(track.id);
    // 必须接住：loadAndPlay 内部的 catch 还要做回滚与提示，那部分若再抛异常，
    // 未处理的 Promise rejection 会让整条切歌链路静默中断，界面毫无反馈
    // startAtSec：最近播放续播入口（playRecentFromHistory）传入的记忆位置；
    // 其余入口不传 = 0（从头播），行为与从前完全一致
    this.loadAndPlay(track, true, startAtSec > 0 ? startAtSec : 0).catch((e: Error): void => {
      console.error(`playTrack failed: ${e.message}`);
    });
  }

  play(): void {
    this.shouldAutoplay = true;
    // 正在解析音源 / 重建播放器：此刻 avPlayer 可能为空、也可能正在被释放。
    // 只登记「要播放」的意图即可 —— 新音源进入 prepared 时会读 shouldAutoplay 自动开播。
    if (this.isPreparing) {
      return;
    }
    const s: string = this.playerState;
    // 需要「重新解析音源 + 重建播放器」的几种情形，统一走 loadAndPlay：
    //   idle     —— 冷启动恢复后尚未加载过音源；
    //   error    —— 上一次播放失败，旧实现不管 error 态，导致播放键彻底变成死键
    //               （点一下毫无反应，也没有任何提示）；
    //   released —— 播放器实例已被回收（清空队列 / 队列清空后）。
    // 播放器指针为空时同理：不能直接 return，否则同样是死键。
    if (!this.avPlayer || s === 'idle' || s === 'error' || s === 'released') {
      const track: Track | null = this.currentTrackSnapshot();
      if (track) {
        const pos: number = this.pendingResumePosition >= 0 ? this.pendingResumePosition : ((AppStorage.get(STORE_PROGRESS) as number) ?? 0);
        this.pendingResumePosition = -1;
        this.loadAndPlay(track, true, pos).catch((e: Error): void => {
          console.error(`reload and play failed: ${e.message}`);
        });
      }
      return;
    }
    if (s === 'prepared' || s === 'paused' || s === 'completed' || s === 'playing') {
      try {
        // 'completed' 状态下直接 play() 会立刻再次触发结束事件（表现为「点了播放没反应」），
        // 需要先回到起点。但若用户刚把进度拖到中间（进度不在末尾），则保留其位置。
        const dur: number = this.knownDuration();
        const pos: number = (AppStorage.get(STORE_PROGRESS) as number) ?? 0;
        if (s === 'completed' && (dur <= 0 || pos >= dur - 1)) {
          this.avPlayer.seek(0);
          this.lastProgressBucket = 0;
          this.setStore(STORE_PROGRESS, 0);
        }
        // play() 返回 Promise，拒绝必须接住，否则未处理的 rejection 会让
        // 「点了播放但没出声」这件事完全不可见
        this.avPlayer.play().catch((e: BusinessError): void => {
          console.error(`avPlayer.play failed: ${e.code} ${e.message}`);
        });
      } catch (e) {
        console.error(`avPlayer.play threw: ${JSON.stringify(e)}`);
      }
    }
    this.setStore(STORE_IS_PLAYING, true);
    this.updateSessionState();
    this.syncBackgroundTask(true);
    this.savePlayerStateNow();
  }

  pause(): void {
    this.shouldAutoplay = false;
    // 准备中：播放器可能在释放/重建，直接操作有空指针风险。
    // 把播放意图置 false 就够了 —— 音源就绪后 prepared 分支不会再自动播放。
    if (this.isPreparing) {
      this.setStore(STORE_IS_PLAYING, false);
      this.updateSessionState();
      this.syncBackgroundTask(false);
      // 2026-10-08（B5）：缓冲中暂停同样要落盘——否则「刚点播放又反悔，随后退出」
      // 时磁盘上还是旧快照。进度用 loadStartAt 意图位置（STORE_PROGRESS 此时是清零的中间态）。
      // 同时取消「seek 后自动播放」意图：不取消的话 prepared 分支仍会出声，
      // 表现为「缓冲中按了暂停，缓冲完却自己唱起来」。
      this.pendingAutoPlayAfterSeek = false;
      this.savePlayerStateNow(this.loadStartAt);
      return;
    }
    if (this.avPlayer) {
      const s: string = this.playerState;
      if (s === 'prepared' || s === 'paused' || s === 'playing' || s === 'completed') {
        try {
          this.avPlayer.pause().catch((e: BusinessError): void => {
            console.error(`avPlayer.pause failed: ${e.code} ${e.message}`);
          });
        } catch (e) {
          console.error(`avPlayer.pause threw: ${JSON.stringify(e)}`);
        }
      }
    }
    this.setStore(STORE_IS_PLAYING, false);
    this.updateSessionState();
    this.syncBackgroundTask(false);
    this.savePlayerStateNow();
  }

  togglePlay(): void {
    const playing: boolean = (AppStorage.get(STORE_IS_PLAYING) as boolean) ?? false;
    if (playing) {
      this.pause();
    } else {
      this.play();
    }
  }

  /**
   * 列表条目点击的统一入口：点的是**当前曲目** → 切换播放/暂停
   * （播放中再点同一行 = 暂停，暂停中再点 = 续播）；否则从头播放该曲。
   */
  playOrToggle(track: Track): void {
    const cur: Track | null = this.currentTrackSnapshot();
    if (cur && cur.id === track.id) {
      this.togglePlay();
      return;
    }
    this.playNow(track);
  }

  /**
   * 最近播放页点击单条的入口（2026-10-12 位置记忆）：
   * 点的是**当前曲目** → 切换播放/暂停（与 playOrToggle 一致）；
   * 否则按条目记录的上次播放位置续播 —— 位置 ≥ RESUME_MIN_SEC 且距结尾
   * ≥ RESUME_TAIL_SEC 才续播，否则视为没听过 / 已听完，从头播放。
   * 「播放全部」不经过这里（保持从第一首 0:00 开始）。
   * 续播定位复用 loadAndPlay 的 startAt → pendingSeekTo 机制（prepared 后 seek）。
   */
  playRecentFromHistory(track: Track): void {
    const cur: Track | null = this.currentTrackSnapshot();
    if (cur && cur.id === track.id) {
      this.togglePlay();
      return;
    }
    const posSec: number = LibraryStore.getRecentProgressSec(track.id);
    const dur: number = track.duration > 0 ? track.duration : 0;
    if (posSec >= RESUME_MIN_SEC && (dur <= 0 || posSec <= dur - RESUME_TAIL_SEC)) {
      this.playNow(track, posSec);
    } else {
      this.playNow(track);
    }
  }

  private knownDuration(): number {
    if (this.lastDuration > 0) {
      return this.lastDuration;
    }
    return (AppStorage.get(STORE_DURATION) as number) ?? 0;
  }

  /**
   * 跳转到指定秒数。
   * - 目标值按已知时长裁剪，避免拖到末尾后 AVPlayer 直接判定播放结束；
   * - 同步重置进度分桶游标，否则 seek 后的第一条 timeUpdate 可能因落在同一桶被丢弃，
   *   界面进度会「停在旧位置不动」。
   */
  seek(seconds: number): void {
    const dur: number = this.knownDuration();
    let target: number = seconds;
    if (!(target >= 0)) {
      target = 0;
    }
    if (dur > 0 && target > dur) {
      target = dur;
    }
    if (this.avPlayer) {
      const s: string = this.playerState;
      if (s === 'prepared' || s === 'playing' || s === 'paused' || s === 'completed') {
        // 标记 seeking：seek 异步生效前 timeUpdate 仍按旧位置回调，
        // 抑制其回传防止滑块被拽回（配合 seekDone 解除抑制）。
        this.seeking = true;
        this.seekStartedAt = Date.now();
        try {
          // 注意：本机 SDK 的 `AVPlayer.seek(timeMs, mode?)` 返回 void（不是 Promise），
          // 所以只能用 try/catch 拦同步异常，异步结果靠 seekDone / error 事件体现。
          this.avPlayer.seek(target * 1000);
        } catch (e) {
          this.seeking = false;
          this.lastProgressBucket = -1;
          console.error(`avPlayer.seek failed: ${JSON.stringify(e)}`);
        }
      } else {
        // 状态机里没有可 seek 的状态：留一条日志，否则问题会完全不可见
        console.error(`seek skipped, unexpected playerState: ${s}`);
        // 2026-10-08（B6）：不可 seek 的状态（error 等）——登记续播定位，
        // 播放键走重载分支时从新位置开始。准备中除外：新音源有自己的 pendingSeekTo
        if (!this.isPreparing) {
          this.pendingResumePosition = target > 0 ? target : -1;
        }
      }
    } else if (!this.isPreparing) {
      // 2026-10-08（B6）：播放器未加载（冷启动恢复后的暂停态）——只写 STORE_PROGRESS
      // 的话，play() 的续播分支会优先消费旧的 pendingResumePosition（restoreState 登记的），
      // 拖动被静默回退到旧位置。必须同步登记，点播放才会从新位置开始。
      this.pendingResumePosition = target > 0 ? target : -1;
    }
    this.lastProgressBucket = Math.floor((target * 1000) / PROGRESS_PUSH_INTERVAL_MS);
    this.setStore(STORE_PROGRESS, target);
    this.updateSessionState();
    // 跳转高频（拖动进度条时连续触发），落盘加 2s 粗节流，避免反复写 Preferences
    const nowSeek: number = Date.now();
    if (nowSeek - this.lastStatePersistAt >= 2000) {
      this.lastStatePersistAt = nowSeek;
      this.savePlayerStateNow();
    }
  }

  next(): void {
    const dq: Track[] = this.displayQueue();
    if (dq.length === 0) {
      return;
    }
    const idx: number = this.currentIndex + 1 >= dq.length ? 0 : this.currentIndex + 1;
    this.currentIndex = idx;
    this.shouldAutoplay = true;
    this.playTrack(dq[idx]);
  }

  prev(): void {
    const dq: Track[] = this.displayQueue();
    if (dq.length === 0) {
      return;
    }
    const idx: number = this.currentIndex - 1 < 0 ? dq.length - 1 : this.currentIndex - 1;
    this.currentIndex = idx;
    this.shouldAutoplay = true;
    this.playTrack(dq[idx]);
  }

  private findIndexInDisplay(id: string): number {
    const dq: Track[] = this.displayQueue();
    for (let i = 0; i < dq.length; i++) {
      if (dq[i].id === id) {
        return i;
      }
    }
    return 0;
  }

  setQueue(tracks: Track[]): void {
    this.queue = tracks.slice();
    this.shuffledQueue = this.shuffle(tracks);
    this.syncQueue();
    this.savePlayerStateNow();
  }

  playAll(tracks: Track[]): void {
    if (tracks.length === 0) {
      return;
    }
    this.setQueue(tracks);
    this.currentIndex = 0;
    this.playTrack(tracks[0]);
    this.savePlayerStateNow();
  }

  playNow(track: Track, startAtSec: number = 0): void {
    const filtered: Track[] = this.queue.filter((t: Track): boolean => t.id !== track.id);
    this.queue = [track, ...filtered];
    this.shuffledQueue = this.shuffle(this.queue);
    this.syncQueue();
    this.currentIndex = 0;
    this.playTrack(track, startAtSec);
    this.savePlayerStateNow();
    // B 站的音乐「合集」是同一视频的多个分 P，每个分 P 一首歌。
    // 只按 bvid 解析音频的话永远停在第一个分 P，所以顺带把整张合集铺进队列。
    // ⚠️ 必须延后执行：它内部要再发一次 view 请求，与音源解析（view + playurl）
    // 同一刻发出会互相挤占连接，首包被拒就是「点了歌提示无法播放」的成因之一。
    setTimeout((): void => {
      this.expandMultiParts(track).catch((e: Error): void => {
        console.error(`expandMultiParts failed: ${e.message}`);
      });
    }, EXPAND_PARTS_DELAY_MS);
  }

  /**
   * 轻提示（后台任务拿不到 UIContext，写 AppStorage 由全局 AppToast 弹出）。
   * seq 读-改-写递增：与 UI 侧 showAppToast 共用同一计数器，独立计数会撞号丢提示。
   */
  private notifyHint(message: string): void {
    AppStorage.setOrCreate(STORE_TOAST_MSG, message);
    AppStorage.setOrCreate(STORE_TOAST_HOLD_MS, 1800);
    const seq: number = AppStorage.get<number>(STORE_TOAST_SEQ) ?? -1;
    AppStorage.setOrCreate(STORE_TOAST_SEQ, seq + 1);
  }

  /**
   * 累计听歌时长。
   *
   * timeUpdate 只在出声期间回调（约 100ms 一次），每次按真实时间差累加；
   * 单次增量超过 LISTEN_TICK_MAX_GAP_MS 的部分截断丢弃，挂起/恢复的空洞不虚计，
   * 后台被拉稀的回调也能按上限持续累计，不再整段清零。
   * 攒满 LISTEN_FLUSH_SECONDS 落盘一次，其余在暂停/播完/切歌/出错/退出时补写。
   */
  private accumulateListenTime(): void {
    const now: number = Date.now();
    if (this.lastListenTickAt > 0) {
      const deltaMs: number = Math.min(now - this.lastListenTickAt, LISTEN_TICK_MAX_GAP_MS);
      if (deltaMs > 0) {
        this.listenAccumSeconds += deltaMs / 1000;
      }
    }
    this.lastListenTickAt = now;
    if (this.listenAccumSeconds >= LISTEN_FLUSH_SECONDS) {
      this.flushListenTime();
    }
  }

  /**
   * 结束当前计时段：补上最后一拍的真实增量后复位游标，并把整数部分立即落盘。
   * 「不是正常停止」的路径（暂停 / 播完 / 出错 / 切歌 / 进程退出）都从这里收尾，
   * 避免攒在内存里的余量随进程被杀一起丢掉。
   */
  private finalizeListenSegment(): void {
    const now: number = Date.now();
    if (this.lastListenTickAt > 0) {
      const deltaMs: number = Math.min(now - this.lastListenTickAt, LISTEN_TICK_MAX_GAP_MS);
      if (deltaMs > 0) {
        this.listenAccumSeconds += deltaMs / 1000;
      }
    }
    this.lastListenTickAt = -1;
    this.flushListenTime();
  }

  /** 把会话内累计的听歌秒数（整数部分）落盘，失败只留日志不影响播放 */
  private flushListenTime(): void {
    const add: number = Math.floor(this.listenAccumSeconds);
    if (add < 1) {
      return;
    }
    this.listenAccumSeconds -= add;
    AppPreferences.addListenSeconds(add).catch((e: Error): void => {
      console.error(`save listen seconds failed: ${e.message}`);
    });
  }

  /**
   * 展开多 P 合集并追加到当前曲目之后。
   * 只在首次播放该 bvid 时请求一次 view 接口；单 P 视频直接返回，不产生额外开销。
   */
  private async expandMultiParts(track: Track): Promise<void> {
    const bvid: string = track.bvid ? track.bvid : track.id;
    // 音乐中心用的是音乐 id，不是 bvid，展开没有意义
    if (bvid.length === 0 || bvid.indexOf('BV') !== 0) {
      return;
    }
    if (this.expandedBvids.has(bvid)) {
      return;
    }
    this.expandedBvids.add(bvid);
    try {
      const parts: Track[] = await expandVideoParts(bvid, track);
      if (parts.length <= 1) {
        return;
      }
      this.insertAfterCurrent(parts.slice(1));
      this.notifyHint(`已加载合集，共 ${parts.length} 首`);
    } catch (e) {
      // 失败时移出缓存，下次播放还可以再试
      this.expandedBvids.delete(bvid);
      console.error(`expand collection failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 把曲目插到当前曲目之后：按 id 去重，并保持 currentIndex 仍指向正在播放的那首。
   * 随机播放下 shuffledQueue 会重排，必须按当前曲目 id 重新定位，否则「下一首」会跳错。
   */
  private insertAfterCurrent(tracks: Track[]): void {
    if (tracks.length === 0) {
      return;
    }
    const existing: Set<string> = new Set<string>(this.queue.map((t: Track): string => t.id));
    const fresh: Track[] = tracks.filter((t: Track): boolean => !existing.has(t.id));
    if (fresh.length === 0) {
      return;
    }
    const curId: string = this.currentTrackSnapshot()?.id ?? '';
    let at: number = curId.length > 0 ? this.queue.findIndex((t: Track): boolean => t.id === curId) : -1;
    if (at < 0) {
      at = this.currentIndex >= 0 && this.currentIndex < this.queue.length ? this.currentIndex : this.queue.length - 1;
    }
    const insertAt: number = Math.min(at + 1, this.queue.length);
    this.queue = [...this.queue.slice(0, insertAt), ...fresh, ...this.queue.slice(insertAt)];
    this.shuffledQueue = this.shuffle(this.queue);
    this.syncQueue();
    if (curId.length > 0) {
      const dq: Track[] = this.displayQueue();
      const idx: number = dq.findIndex((t: Track): boolean => t.id === curId);
      if (idx >= 0) {
        this.currentIndex = idx;
      }
    }
  }

  playNext(track: Track): void {
    if (this.queue.length === 0) {
      this.playNow(track);
      return;
    }
    const without: Track[] = this.queue.filter((t: Track): boolean => t.id !== track.id);
    const curIdx: number = without.findIndex((t: Track): boolean => t.id === this.currentTrackSnapshot()?.id);
    const insertAt: number = curIdx >= 0 ? curIdx + 1 : without.length;
    this.queue = [...without.slice(0, insertAt), track, ...without.slice(insertAt)];
    this.shuffledQueue = this.shuffle(this.queue);
    this.syncQueue();
  }

  addToQueue(track: Track): void {
    const exists: boolean = this.queue.some((t: Track): boolean => t.id === track.id);
    if (!exists) {
      this.queue = [...this.queue, track];
      this.shuffledQueue = this.shuffle(this.queue);
      this.syncQueue();
    }
    if (this.currentIndex < 0 && this.queue.length > 0) {
      this.currentIndex = 0;
      this.setStore(STORE_CURRENT_TRACK, this.queue[0]);
    }
  }

  addTracksToQueue(tracks: Track[]): void {
    const existing: Set<string> = new Set<string>(this.queue.map((t: Track): string => t.id));
    const fresh: Track[] = tracks.filter((t: Track): boolean => !existing.has(t.id));
    if (fresh.length > 0) {
      this.queue = [...this.queue, ...fresh];
      this.shuffledQueue = this.shuffle(this.queue);
      this.syncQueue();
    }
  }

  removeFromQueue(trackId: string): void {
    this.queue = this.queue.filter((t: Track): boolean => t.id !== trackId);
    this.shuffledQueue = this.shuffle(this.queue);
    this.syncQueue();
  }

  clearQueue(): void {
    // 作废一切在途加载：否则清空后网络解析才回来，会把刚 drop 掉的播放器
    // 重建出来继续放歌（队列已空、STORE_CURRENT_TRACK 已 null，歌却还在响）
    this.loadToken++;
    this.queue = [];
    this.shuffledQueue = [];
    this.currentIndex = -1;
    this.syncQueue();
    this.setStore(STORE_CURRENT_TRACK, null);
    this.pause();
    this.savePlayerStateNow();
    // 回收播放器实例而不是原地 reset()：reset 会触发一次旧音源的 error，
    // 而此时 STORE_CURRENT_TRACK 已是 null，error 回调会弹一句莫名其妙的
    // 「音频加载失败」。摘监听后 release 就没有这个副作用。
    this.dropPlayer();
  }

  /**
   * 设置播放模式（顺序 / 列表循环 / 单曲循环 / 随机）。
   *
   * 随机播放并入模式枚举，所以这里要同步维护 `isShuffled` 与洗牌队列：
   * 进入随机时重新洗牌并把 currentIndex 重新对准当前曲目，
   * 否则「下一首」会从洗牌队列的第 0 位开始，跳成另一首歌。
   */
  setRepeatMode(mode: RepeatMode): void {
    this.repeatMode = mode;
    const wantShuffle: boolean = mode === RepeatMode.SHUFFLE;
    if (wantShuffle !== this.isShuffled) {
      this.isShuffled = wantShuffle;
      if (wantShuffle) {
        this.shuffledQueue = this.shuffle(this.queue);
      }
      const cur: Track | null = this.currentTrackSnapshot();
      if (cur) {
        this.currentIndex = this.findIndexInDisplay(cur.id);
      }
    }
    this.setStore(STORE_REPEAT_MODE, mode);
    this.setStore(STORE_SHUFFLE, this.isShuffled);
    this.savePlayerStateNow();
    // 播放模式变了：媒体中心/车机卡片的模式图标要联动
    this.updateSessionState();
  }

  /** 兼容旧调用：开/关随机等价于在 随机 / 顺序 两个模式间切换。 */
  setShuffle(shuffle: boolean): void {
    this.setRepeatMode(shuffle ? RepeatMode.SHUFFLE : RepeatMode.NONE);
  }

  /**
   * 设置播放倍速（档位见 PLAYBACK_SPEED_OPTIONS，非法值归 1.0）。
   * persist=false 供设置页关开关时复用运行时归位逻辑——偏好里两个字段由
   * 设置页的 update 一次性写好，这里再写会因 setObject 的 put 未落内存
   * 产生读-改-写覆盖竞态；播放页菜单选档走默认 persist=true 自行持久化。
   */
  setPlaybackSpeed(speed: number, persist: boolean = true): void {
    const normalized: number = PLAYBACK_SPEED_OPTIONS.includes(speed) ? speed : 1.0;
    this.playbackSpeed = normalized;
    this.setStore(STORE_PLAYBACK_SPEED, normalized);
    if (persist) {
      const s: AppSettings = AppPreferences.getSettings();
      s.playbackSpeed = normalized;
      AppPreferences.saveSettings(s).catch((e: Error): void => {
        console.error(`persist playbackSpeed failed: ${e.message}`);
      });
    }
    // setSpeed 只在 prepared/playing/paused/completed 合法；
    // idle/initialized 态先记账，prepared 后由 applySpeedOnPrepared 补上
    if (this.avPlayer && this.playerHoldsSource()) {
      try {
        this.avPlayer.setSpeed(speedToPlaybackSpeed(normalized));
      } catch (e) {
        console.error(`setSpeed failed: ${JSON.stringify(e)}`);
      }
    }
    // 倍速变了：媒体中心/车机卡片的倍速状态要联动
    this.updateSessionState();
  }

  /**
   * 设置页切换「与其他应用同时播放」时对当前实例立即生效（best-effort，2026-10-21）。
   * SDK 注明 audioInterruptMode「首次 play() 之前设置才能完全生效」，播放中切换
   * 可能要等下次换源重建（prepared 钩子）才完全切换；playerHoldsSource 已排除
   * idle/initialized/stop 等非法赋值窗口。
   */
  setAudioMixEnabled(enabled: boolean): void {
    const p: media.AVPlayer | null = this.avPlayer;
    if (p === null || !this.playerHoldsSource()) {
      return;
    }
    try {
      p.audioInterruptMode =
        enabled ? audio.InterruptMode.INDEPENDENT_MODE : audio.InterruptMode.SHARE_MODE;
    } catch (e) {
      console.error(`set audioInterruptMode failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 定时停止播放的定时器句柄（-1 = 未开启）。
   *
   * 计时器放在播放内核（单例）而不是设置页：到点要停的是**播放**，
   * 跟着播放器走生命周期更合理，页面重建也不会丢定时。
   */
  private sleepTimer: number = -1;

  /**
   * 设置「定时停止播放」。
   * @param minutes 多少分钟后自动暂停；<= 0 表示取消定时
   */
  setSleepTimer(minutes: number): void {
    this.clearSleepTimer();
    if (minutes <= 0) {
      this.setStore(STORE_SLEEP_TIMER_END, 0);
      this.notifyHint('已取消定时停止');
      return;
    }
    const delayMs: number = minutes * 60 * 1000;
    // 只发布**结束时刻**：剩余时间由设置页现算，内核不必每秒写一次 AppStorage
    this.setStore(STORE_SLEEP_TIMER_END, Date.now() + delayMs);
    this.sleepTimer = setTimeout((): void => {
      this.sleepTimer = -1;
      this.setStore(STORE_SLEEP_TIMER_END, 0);
      this.pause();
      this.notifyHint('定时结束，已停止播放');
    }, delayMs);
    const label: string = (minutes >= 60 && minutes % 60 === 0)
      ? `${minutes / 60} 小时`
      : `${minutes} 分钟`;
    this.notifyHint(`已设置 ${label} 后停止播放`);
  }

  private clearSleepTimer(): void {
    if (this.sleepTimer !== -1) {
      clearTimeout(this.sleepTimer);
      this.sleepTimer = -1;
    }
  }

  toggleLike(track: Track): void {
    // 这里只是翻一个布尔位：显式复制一份，不要借道 mergeTrack。
    // mergeTrack 的职责是「把音源解析结果并回来」，用它做这件小事会把列表侧元数据
    // 按音源侧的值重写一遍，反而容易把信息写坏。
    const updated: Track = {
      id: track.id,
      title: track.title,
      artist: track.artist,
      coverUrl: track.coverUrl,
      duration: track.duration,
      videoUrl: track.videoUrl,
      bvid: track.bvid,
      aid: track.aid,
      cid: track.cid,
      upMid: track.upMid ?? '',
      playCount: track.playCount,
      pubdate: track.pubdate,
      playedAt: track.playedAt ?? 0,
      lastPosSec: track.lastPosSec ?? 0,
      isLiked: !track.isLiked,
      likedAt: track.likedAt,
      audioUrl: track.audioUrl,
      audioQuality: track.audioQuality,
      audioBandwidth: track.audioBandwidth,
      audioMimeType: track.audioMimeType
    };
    this.setStore(STORE_CURRENT_TRACK, updated);
    // ⚠️ 同步调用，内部自己 catch 落盘失败（见 LibraryStore.persistFavoriteTracks）：
    // 收藏是单 key，撞 8192 字节上限时会抛错。这里绝不能让它冒成 unhandled rejection ——
    // 症状是「界面已显示收藏（isLiked 已翻 true）、重启后什么都没了」。
    LibraryStore.toggleFavoriteTrack(updated);
    // 收藏态变了：媒体中心/车机卡片的心形图标要联动
    this.updateSessionState();
  }

  private shuffle<T>(arr: T[]): T[] {
    const a: T[] = arr.slice();
    for (let i = a.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const tmp: T = a[i];
      a[i] = a[j];
      a[j] = tmp;
    }
    return a;
  }

  /**
   * 播放结束（AVPlayer 进入 completed）时的走向。播放模式是唯一判据：
   *   单曲循环 → 回到 0 秒重放当前曲
   *   列表循环 → 无条件下一首（末尾回到第一首）
   *   随机播放 → 洗牌队列里下一首（天然无穷）
   *   顺序播放 → 有下一首就继续，到列表末尾就停在本曲
   *
   * 注意：不能再拿 settings.autoPlay 兜底成「永远下一首」，
   * 否则「顺序播放」会退化成「列表循环」，用户永远等不到停止。
   */
  private handleEnded(): void {
    const dq: Track[] = this.displayQueue();
    if (dq.length === 0) {
      this.stopAtCurrent();
      return;
    }
    if (this.repeatMode === RepeatMode.ONE) {
      if (this.avPlayer) {
        try {
          this.avPlayer.seek(0);
          this.avPlayer.play().catch((e: BusinessError): void => {
            console.error(`replay failed: ${e.code} ${e.message}`);
          });
        } catch (e) {
          console.error(`replay threw: ${JSON.stringify(e)}`);
        }
      }
      this.lastProgressBucket = 0;
      this.setStore(STORE_PROGRESS, 0);
      this.updateSessionState();
      this.syncBackgroundTask(true);
      return;
    }
    // 「自动播放下一首」关闭时，任何模式都停在当前曲（含列表循环，尊重用户的显式设置）
    const autoPlay: boolean = AppPreferences.getSettings().autoPlay;
    if (!autoPlay) {
      this.stopAtCurrent();
      return;
    }
    if (this.repeatMode === RepeatMode.ALL || this.repeatMode === RepeatMode.SHUFFLE) {
      this.next();
      return;
    }
    if (this.currentIndex + 1 < dq.length) {
      this.next();
      return;
    }
    this.stopAtCurrent();
  }

  /**
   * 停在当前曲目末尾（不切歌）。
   * 旧实现会把 STORE_CURRENT_TRACK 换成下一首却不加载音频，
   * 界面上歌名变了、实际音轨还是上一首，点播放也放不出来。
   */
  private stopAtCurrent(): void {
    this.shouldAutoplay = false;
    this.setStore(STORE_IS_PLAYING, false);
    this.updateSessionState();
    this.syncBackgroundTask(false);
  }

  release(): void {
    // 2026-10-08（B4）：退出兜底——播放快照落盘。onDestroy / onBackground 都不保证
    // 在划卡杀进程时被调，但能调到时就别丢「播放中直接退出」的最后一拍进度
    //（timeUpdate 落盘有 5s 粗节流窗口）
    this.savePlayerStateNow();
    // 杀进程前最后一拍「上次听到」位置强制落盘（savePlayerStateNow 内是 10s 节流版，
    // 这里 force 立写，保证退出时的位置精确在盘）
    this.recordRecentProgress(undefined, true);
    // 进程即将销毁：把最后一拍的增量和不足落盘阈值的余量一并补写掉
    this.finalizeListenSegment();
    if (this.context) {
      BackgroundPlayback.getInstance().stop(this.context).catch((e: Error): void => {
        console.error(`stop continuousTask on release failed: ${JSON.stringify(e)}`);
      });
    }
    this.isPreparing = false;
    this.pendingMetadataTrack = null;
    // 2026-10-08（B2）：续播 seek→play 的挂起与兜底定时器一并清掉
    this.playAfterSeekPending = false;
    if (this.playAfterSeekTimer !== -1) {
      clearTimeout(this.playAfterSeekTimer);
      this.playAfterSeekTimer = -1;
    }
    this.clearSleepTimer();
    if (this.prefetchTimer !== -1) {
      clearTimeout(this.prefetchTimer);
      this.prefetchTimer = -1;
    }
    this.dropPlayer();
    this.playerState = 'released';
    if (this.session) {
      try {
        this.session.destroy();
      } catch (e) {
        console.error(`destroy avSession failed: ${JSON.stringify(e)}`);
      }
      this.session = null;
    }
  }
}
