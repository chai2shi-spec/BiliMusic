/**
 * 本机离线歌词转写服务（「AI 转写歌词」）。
 *
 * 链路：原生解码（libentry.so：m4a/mp3/flac → 16kHz 单声道 s16le PCM）
 * → speechRecognizer 离线中文识别（长模式 + recognitionMode:1 写音频流）
 * → 按 55s 分段喂入（writeAudio 文档口径「最大音频长度 60000ms」留余量）
 * → isFinal 结果按喂入进度打行时间戳 → LyricsApi.saveBiliSubtitleChoice
 * 落 manual 缓存（下次播放自动作歌词、不被自动搜索覆盖）。
 *
 * 进度发布走 AppStorage 五键（STORE_TRANSCRIBE_*）：歌词面板订阅渲染
 * 横幅 / 禁用按钮；取消即时生效（runSeq 失效旧任务，原生解码不可中断、
 * 结果静默丢弃）。转写绑定发起时的曲目快照，中途切歌不中断不串曲。
 *
 * ⚠️ 喂入节奏 20ms/块 与实时音频同速 —— 转写耗时 ≈ 歌曲时长；退后台
 * 定时器可能被节流（时间戳由 chunk 计数推算不受影响），横幅文案提示
 * 保持前台。
 */

import { speechRecognizer } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import { LyricLine, LyricResult, Track } from '../model/MusicModels';
import { LyricsApi } from '../api/LyricsApi';
import { DownloadManager } from './DownloadManager';
import { cachedListenPath } from './ListenCacheStore';
import { postAppToast } from '../common/ToastChannel';
import {
  STORE_TRANSCRIBE_DONE_SEQ,
  STORE_TRANSCRIBE_PHASE,
  STORE_TRANSCRIBE_PROGRESS,
  STORE_TRANSCRIBE_RUNNING,
  STORE_TRANSCRIBE_TRACK_ID
} from '../common/Constants';
import { decodeAudioToPcm } from 'libentry.so';

/** PCM 规格：16kHz × 16bit 单声道 = 32 字节 / 毫秒 */
const PCM_BYTES_PER_MS: number = 32;
/** writeAudio 单块字节数（640B = 20ms，官方推荐节奏） */
const FEED_CHUNK_BYTES: number = 640;
const FEED_INTERVAL_MS: number = 20;
/** 单段上限 55s：writeAudio 文档口径「最大音频长度 60000ms」，留 5s 余量 */
const SEGMENT_MS: number = 55000;
const SEGMENT_BYTES: number = SEGMENT_MS * PCM_BYTES_PER_MS;
/** 长模式 maxAudioDuration 下限：末段静音补齐到该长度 */
const MIN_SEGMENT_MS: number = 20000;
const MIN_SEGMENT_BYTES: number = MIN_SEGMENT_MS * PCM_BYTES_PER_MS;
/** 单段喂完后的识别回调松弛时间（watchdog = 段长 + 该余量） */
const SEGMENT_TAIL_GRACE_MS: number = 30000;
/** 空行判定：识别文本去空白后短于该长度不落歌词 */
const MIN_LINE_TEXT_LEN: number = 1;

/** PCM 分段（零填充到 640 对齐） */
interface PcmSegment {
  data: Uint8Array;
  /** 段起点（毫秒，相对整首） */
  startMs: number;
}

/** 转写收集行（落库前中间态） */
interface TranscribeLine {
  timeMs: number;
  text: string;
}

/** 临时 PCM 目录（AppContainer.initRest 装配；未初始化时 startTranscribe 静默拒绝） */
let transcribeDir: string = '';

/** 任务序号：每次发起 +1；取消也 +1 使旧任务（含不可中断的原生解码）静默失效 */
let runSeq: number = 0;
let running: boolean = false;
let cancelRequested: boolean = false;
/** 当前段喂入定时器 id（-1 = 无） */
let feedTimerId: number = -1;
let activeEngine: speechRecognizer.SpeechRecognitionEngine | null = null;
let activeSessionId: string = '';
/** 当前段的「提前收尾」钩子：取消时 resolve 段等待，让主循环走到 seq 检查退出 */
let abortSegment: (() => void) | null = null;
/** 当前段结果回调统一收口（onComplete → null；onError → BusinessError） */
let settleSegment: ((err: BusinessError | null) => void) | null = null;

// ── 段级喂入进度推算（onResult 打时间戳 / 横幅进度共用） ──
let totalPcmBytes: number = 0;
let segmentStartMs: number = 0;
let segmentStartBytes: number = 0;
let sentChunks: number = 0;
let pcmBuffer: Uint8Array = new Uint8Array(0);
let collectedLines: TranscribeLine[] = [];

/** AppContainer.initRest 装配：记录临时 PCM 目录（cacheDir 可被系统清理，符合临时产物定位） */
export function initLyricTranscribeStore(context: common.Context): void {
  transcribeDir = `${context.cacheDir}/transcribe`;
}

/** 本机离线语音识别能力探测（SystemCapability.AI.SpeechRecognizer） */
export function isTranscribeSupported(): boolean {
  return canIUse('SystemCapability.AI.SpeechRecognizer');
}

/** 是否有转写任务进行中（按钮禁用 / 横幅显隐） */
export function isTranscribeRunning(): boolean {
  return running;
}

/**
 * 解析曲目的本地音频源（与 MusicPlayer 本地优先链同口径）：
 * track.localFilePath > 下载完成文件 > 听后缓存。
 */
function resolveAudioPath(track: Track): string {
  const local: string = track.localFilePath ?? '';
  if (local.length > 0 && fs.accessSync(local)) {
    return local;
  }
  const downloaded: string = DownloadManager.getInstance().completedLocalPath(track.id);
  if (downloaded.length > 0 && fs.accessSync(downloaded)) {
    return downloaded;
  }
  const cached: string = cachedListenPath(track.id);
  if (cached.length > 0 && fs.accessSync(cached)) {
    return cached;
  }
  return '';
}

/** 曲目是否有可用于转写的本地音频（歌词面板按钮可用态判定；纯 stat，无副作用） */
export function hasLocalAudioSource(track: Track): boolean {
  return resolveAudioPath(track).length > 0;
}

/** 文件名安全化：trackId 直接拼路径（去掉路径分隔符，防目录逃逸） */
function safePcmName(trackId: string, seq: number): string {
  const cleaned: string = trackId.replace(/[/\\:*?"<>|#%]/g, '_');
  return `${cleaned.length > 0 ? cleaned : 'track'}_${seq}.pcm`;
}

function stopFeedTimer(): void {
  if (feedTimerId >= 0) {
    clearInterval(feedTimerId);
    feedTimerId = -1;
  }
}

function resetRuntimeState(): void {
  stopFeedTimer();
  activeEngine = null;
  activeSessionId = '';
  abortSegment = null;
  settleSegment = null;
  pcmBuffer = new Uint8Array(0);
  collectedLines = [];
  cancelRequested = false;
  segmentStartMs = 0;
  segmentStartBytes = 0;
  sentChunks = 0;
  totalPcmBytes = 0;
}

function resetPublishedState(): void {
  AppStorage.setOrCreate(STORE_TRANSCRIBE_RUNNING, false);
  AppStorage.setOrCreate(STORE_TRANSCRIBE_PHASE, '');
  AppStorage.setOrCreate(STORE_TRANSCRIBE_PROGRESS, 0);
}

function publishProgress(mySeq: number, phase: string, progress: number): void {
  if (mySeq !== runSeq) {
    return;
  }
  AppStorage.setOrCreate(STORE_TRANSCRIBE_PHASE, phase);
  AppStorage.setOrCreate(STORE_TRANSCRIBE_PROGRESS, Math.floor(progress));
}

/**
 * 发起转写。同一时刻仅一个任务（忙碌时静默返回，按钮侧已禁用兜底）；
 * 失败 / 取消均以 toast 反馈，成功递增 DONE_SEQ 通知歌词页刷新。
 */
export async function startTranscribe(track: Track): Promise<void> {
  if (running) {
    return;
  }
  if (transcribeDir.length === 0) {
    postAppToast('转写服务未就绪，请稍后重试', 1800);
    return;
  }
  const audioPath: string = resolveAudioPath(track);
  if (audioPath.length === 0) {
    postAppToast('仅支持已下载或已缓存的音频', 1800);
    return;
  }
  if (!isTranscribeSupported()) {
    postAppToast('本机不支持离线语音识别', 1800);
    return;
  }
  running = true;
  runSeq++;
  const mySeq: number = runSeq;
  try {
    await runTranscribe(track, audioPath, mySeq);
  } catch (e) {
    // 取消（seq 已被 cancelTranscribe 顶掉）由取消侧统一提示，这里静默
    if (mySeq === runSeq) {
      const err = e as BusinessError;
      const msg: string = err.message && err.message.length > 0 ? err.message : '转写失败';
      postAppToast(msg, 2200);
    }
  } finally {
    if (mySeq === runSeq) {
      running = false;
      resetRuntimeState();
      resetPublishedState();
    }
  }
}

/**
 * 取消转写：任意阶段即时生效 —— seq 顶掉旧任务（原生解码结果静默丢弃）、
 * 段等待提前 resolve、引擎 cancel / shutdown 交给原任务收尾。
 */
export function cancelTranscribe(): void {
  if (!running) {
    return;
  }
  runSeq++;
  running = false;
  cancelRequested = true;
  if (activeEngine !== null && activeSessionId.length > 0) {
    try {
      activeEngine.cancel(activeSessionId);
    } catch (e) {
      console.error(`[Transcribe] cancel engine failed: ${JSON.stringify(e)}`);
    }
  }
  const abort: (() => void) | null = abortSegment;
  resetRuntimeState();
  resetPublishedState();
  if (abort !== null) {
    abort();
  }
  postAppToast('已取消转写', 1500);
}

async function runTranscribe(track: Track, audioPath: string, mySeq: number): Promise<void> {
  AppStorage.setOrCreate(STORE_TRANSCRIBE_RUNNING, true);
  AppStorage.setOrCreate(STORE_TRANSCRIBE_TRACK_ID, track.id);
  AppStorage.setOrCreate(STORE_TRANSCRIBE_PHASE, 'decoding');
  AppStorage.setOrCreate(STORE_TRANSCRIBE_PROGRESS, 0);

  if (!fs.accessSync(transcribeDir)) {
    fs.mkdirSync(transcribeDir, true);
  }
  const pcmPath: string = `${transcribeDir}/${safePcmName(track.id, mySeq)}`;
  if (fs.accessSync(pcmPath)) {
    fs.unlinkSync(pcmPath);
  }

  try {
    // ① 原生解码（不可中途取消，时长秒级）
    await decodeAudioToPcm(audioPath, pcmPath);
    if (mySeq !== runSeq) {
      return;
    }
    const stat: fs.Stat = fs.statSync(pcmPath);
    totalPcmBytes = stat.size;
    if (totalPcmBytes < FEED_CHUNK_BYTES) {
      throw new Error('音频解码结果为空，可能是不支持的格式');
    }

    // ② PCM 全量读入内存（4 分钟歌 ≈ 7.7MB）
    const file: fs.File = fs.openSync(pcmPath, fs.OpenMode.READ_ONLY);
    try {
      const ab: ArrayBuffer = new ArrayBuffer(totalPcmBytes);
      fs.readSync(file.fd, ab);
      pcmBuffer = new Uint8Array(ab);
    } finally {
      fs.closeSync(file);
    }

    // ③ 创建识别引擎（离线中文长模式）
    publishProgress(mySeq, 'recognizing', 0);
    const engine: speechRecognizer.SpeechRecognitionEngine = await speechRecognizer.createEngine({
      language: 'zh-CN',
      online: 1,
      extraParams: { 'locate': 'CN', 'recognizerMode': 'long' }
    });
    if (mySeq !== runSeq) {
      engine.shutdown();
      return;
    }
    activeEngine = engine;
    try {
      engine.setListener(buildListener(mySeq));
      // ④ 分段识别
      const segments: PcmSegment[] = splitSegments();
      for (let i = 0; i < segments.length; i++) {
        if (mySeq !== runSeq) {
          return;
        }
        await recognizeSegment(engine, segments[i], i, mySeq);
      }
    } finally {
      engine.shutdown();
      activeEngine = null;
    }
    if (mySeq !== runSeq) {
      return;
    }

    // ⑤ 落库（manual 语义：下次播放自动命中、不被自动搜索覆盖）
    const lines: LyricLine[] = buildLyricLines();
    if (lines.length === 0) {
      throw new Error('未识别到歌词内容');
    }
    const result: LyricResult = {
      lines: lines,
      synced: true,
      instrumental: false,
      trackName: track.title,
      artistName: track.artist,
      sourceId: 'device-asr',
      source: 'device-asr',
      dynamic: false
    };
    await LyricsApi.saveBiliSubtitleChoice(track, result);
    postAppToast('转写完成，歌词已绑定', 1800);
    const seq: number = AppStorage.get<number>(STORE_TRANSCRIBE_DONE_SEQ) ?? 0;
    AppStorage.setOrCreate(STORE_TRANSCRIBE_DONE_SEQ, seq + 1);
  } finally {
    // 临时 PCM 清理（seq 命名隔离，删除自己那份绝不误伤新任务）
    try {
      if (fs.accessSync(pcmPath)) {
        fs.unlinkSync(pcmPath);
      }
    } catch (e) {
      console.error('[Transcribe] cleanup pcm failed');
    }
  }
}

/** PCM 按 55s 切段：不足 20s 的末段静音补齐（长模式下限），并 640 字节对齐 */
function splitSegments(): PcmSegment[] {
  const segments: PcmSegment[] = [];
  let offset: number = 0;
  while (offset < totalPcmBytes) {
    const realEnd: number = Math.min(offset + SEGMENT_BYTES, totalPcmBytes);
    const realSize: number = realEnd - offset;
    let data: Uint8Array;
    if (realSize >= MIN_SEGMENT_BYTES && realSize % FEED_CHUNK_BYTES === 0) {
      data = pcmBuffer.slice(offset, realEnd);
    } else {
      const target: number = Math.max(MIN_SEGMENT_BYTES, realSize);
      const aligned: number = Math.ceil(target / FEED_CHUNK_BYTES) * FEED_CHUNK_BYTES;
      data = new Uint8Array(aligned);
      data.set(pcmBuffer.subarray(offset, realEnd));
    }
    segments.push({ data: data, startMs: offset / PCM_BYTES_PER_MS });
    offset = realEnd;
  }
  return segments;
}

function buildListener(mySeq: number): speechRecognizer.RecognitionListener {
  return {
    onStart: (sessionId: string, eventMessage: string): void => {
    },
    onEvent: (sessionId: string, eventCode: number, eventMessage: string): void => {
    },
    onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
      if (mySeq !== runSeq) {
        return;
      }
      const text: string = result.result.trim();
      if (result.isFinal && text.length >= MIN_LINE_TEXT_LEN) {
        // 行时间 = 段起点 + 已喂时长（喂入与实时同速；识别流式延迟约几百毫秒，
        // 用户可用偏移滑杆整体校准或经「编辑歌词」修正行时间戳）
        collectedLines.push({
          timeMs: segmentStartMs + sentChunks * FEED_INTERVAL_MS,
          text: text
        });
      }
    },
    onComplete: (sessionId: string, eventMessage: string): void => {
      if (mySeq !== runSeq) {
        return;
      }
      const settle: ((err: BusinessError | null) => void) | null = settleSegment;
      if (settle !== null) {
        settle(null);
      }
    },
    onError: (sessionId: string, errorCode: number, errorMessage: string): void => {
      if (mySeq !== runSeq) {
        return;
      }
      const settle: ((err: BusinessError | null) => void) | null = settleSegment;
      if (settle !== null) {
        const err: BusinessError = { code: errorCode, name: 'BusinessError', message: errorMessage };
        settle(err);
      }
    }
  };
}

/**
 * 单段识别：startListening → 20ms 定时喂 640B → 喂完 finish →
 * 等 onComplete（watchdog = 段长 + 松弛时间兜底卡死）。
 */
function recognizeSegment(engine: speechRecognizer.SpeechRecognitionEngine, seg: PcmSegment,
  index: number, mySeq: number): Promise<void> {
  return new Promise<void>((resolve: () => void, reject: (e: BusinessError) => void): void => {
    let settled: boolean = false;
    let watchdogId: number = -1;
    const sessionId: string = `seg${index}_${mySeq}`;
    const chunkCount: number = Math.floor(seg.data.length / FEED_CHUNK_BYTES);
    const maxMs: number = Math.max(MIN_SEGMENT_MS, seg.data.length / PCM_BYTES_PER_MS);

    const settle: (err: BusinessError | null) => void = (err: BusinessError | null): void => {
      if (settled) {
        return;
      }
      settled = true;
      stopFeedTimer();
      if (watchdogId >= 0) {
        clearTimeout(watchdogId);
        watchdogId = -1;
      }
      settleSegment = null;
      abortSegment = null;
      activeSessionId = '';
      if (err !== null) {
        reject(err);
      } else {
        resolve();
      }
    };

    segmentStartMs = seg.startMs;
    segmentStartBytes = seg.startMs * PCM_BYTES_PER_MS;
    sentChunks = 0;
    activeSessionId = sessionId;
    settleSegment = settle;
    abortSegment = (): void => {
      settle(null);
    };

    try {
      engine.startListening({
        sessionId: sessionId,
        audioInfo: {
          audioType: 'pcm',
          sampleRate: 16000,
          soundChannel: 1,
          sampleBit: 16
        },
        extraParams: {
          'recognitionMode': 1,
          'maxAudioDuration': maxMs
        }
      });
    } catch (e) {
      settle(e as BusinessError);
      return;
    }

    // 喂入节奏与实时音频同速（writeAudio 文档口径），识别耗时 ≈ 段长
    feedTimerId = setInterval((): void => {
      if (settled || mySeq !== runSeq) {
        stopFeedTimer();
        return;
      }
      if (sentChunks >= chunkCount) {
        stopFeedTimer();
        try {
          engine.finish(sessionId);
        } catch (e) {
          settle(e as BusinessError);
        }
        return;
      }
      const from: number = sentChunks * FEED_CHUNK_BYTES;
      try {
        engine.writeAudio(sessionId, pcmChunkOf(seg, from));
      } catch (e) {
        // 1002200003 超长 / 1002200010 未启动等：本段放弃
        settle(e as BusinessError);
        return;
      }
      sentChunks++;
      publishProgress(mySeq, 'recognizing',
        (segmentStartBytes + sentChunks * FEED_CHUNK_BYTES) / totalPcmBytes * 100);
    }, FEED_INTERVAL_MS);

    // watchdog：段长 + 松弛（喂完 finish 后识别回调的到达窗口）
    watchdogId = setTimeout((): void => {
      const err: BusinessError = { code: 1002200009, name: 'BusinessError', message: '本段识别超时' };
      settle(err);
    }, maxMs + SEGMENT_TAIL_GRACE_MS);
  });
}

function pcmChunkOf(seg: PcmSegment, from: number): Uint8Array {
  return seg.data.subarray(from, from + FEED_CHUNK_BYTES);
}

/** 收集行 → 落库行：按时间排序、丢空行、毫秒转秒 */
function buildLyricLines(): LyricLine[] {
  const sorted: TranscribeLine[] = collectedLines.slice(0);
  sorted.sort((a: TranscribeLine, b: TranscribeLine): number => {
    return a.timeMs - b.timeMs;
  });
  const lines: LyricLine[] = [];
  for (let i = 0; i < sorted.length; i++) {
    const text: string = sorted[i].text.trim();
    if (text.length < MIN_LINE_TEXT_LEN) {
      continue;
    }
    lines.push({
      time: sorted[i].timeMs / 1000,
      text: text,
      words: []
    });
  }
  return lines;
}
