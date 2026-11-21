/**
 * ASR 转写总调度（只服务第三方转写模型；系统 speechRecognizer 链路已移除）。
 *
 * 链路：PCM 解码（libentry.so）→ sherpa-onnx 引擎推理 → manual 歌词缓存落库。
 * 进度发布走 AppStorage 五键（STORE_TRANSCRIBE_*），播放页进度横幅 /
 * 完成刷新订阅同一组键即可工作。
 */

import fs from '@ohos.file.fs';
import { Track, LyricLine, LyricResult } from '../../model/MusicModels';
import { LyricsApi } from '../../api/LyricsApi';
import { DownloadManager } from '../DownloadManager';
import { cachedListenPath } from '../ListenCacheStore';
import { decodeAudioToPcm } from 'libentry.so';
import { postAppToast } from '../../common/ToastChannel';
import {
  AsrEngine, AsrEngineId, AsrInitOptions, AsrLine
} from './AsrEngine';
import {
  currentEngineId, currentModelDir, currentEngineLabel
} from './AsrEngineRegistry';
import { SherpaOnnxAsrEngine } from './SherpaOnnxAsrEngine';
import { findModel } from './AsrModelCatalog';
import { getModelState } from './AsrModelManager';
import { asrTranscribeDir } from './AsrPaths';
import {
  STORE_TRANSCRIBE_RUNNING, STORE_TRANSCRIBE_PHASE, STORE_TRANSCRIBE_PROGRESS,
  STORE_TRANSCRIBE_TRACK_ID, STORE_TRANSCRIBE_DONE_SEQ
} from '../../common/Constants';

let running: boolean = false;
let runSeq: number = 0;
let activeEngine: AsrEngine | null = null;

/**
 * 从 Track 解析本地音频（track.localFilePath > 下载完成文件 > 听后缓存）。
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

/** 创建引擎实例（NPU 扩展点：将来在此加 case） */
function makeEngine(id: AsrEngineId): AsrEngine | null {
  const spec = findModel(id);
  if (spec === undefined) {
    return null;
  }
  return new SherpaOnnxAsrEngine(id, spec.displayName);
}

/** 取消当前第三方转写 */
export function cancelAsrTranscribe(): void {
  runSeq++;
  if (activeEngine !== null) {
    activeEngine.cancel();
  }
}

/** 发起第三方模型转写 */
export async function startThirdPartyTranscribe(track: Track): Promise<void> {
  if (running) {
    return;
  }
  const contextDir: string = asrTranscribeDir();
  if (contextDir.length === 0) {
    postAppToast('转写服务未就绪，请稍后重试', 1800);
    return;
  }
  // 懒建临时 PCM 目录：native 侧 fopen 只建文件不建目录，目录缺失会报「无法创建临时转写文件」
  try {
    if (!fs.accessSync(contextDir)) {
      fs.mkdirSync(contextDir, true);
    }
  } catch (e) {
    postAppToast('转写临时目录创建失败，请稍后重试', 2200);
    return;
  }
  const id: string = currentEngineId();
  if (id.length === 0) {
    postAppToast('尚未选择转写模型，请到「转写模型」页选用', 2400);
    return;
  }
  if (!getModelState(id).installed) {
    postAppToast('模型尚未下载完成，请到「转写模型」下载', 2400);
    return;
  }
  const audioPath: string = resolveAudioPath(track);
  if (audioPath.length === 0) {
    postAppToast('请先下载这首歌或用听后缓存播放', 2200);
    return;
  }

  running = true;
  const mySeq: number = ++runSeq;
  const engine: AsrEngine | null = makeEngine(id);
  if (engine === null) {
    running = false;
    postAppToast('引擎不可用', 2000);
    return;
  }
  activeEngine = engine;
  const pcmPath: string = `${contextDir}/${track.id.replace(/[/\\:*?"<>|#%]/g, '_')}_asr_${mySeq}.pcm`;
  AppStorage.setOrCreate(STORE_TRANSCRIBE_RUNNING, true);
  AppStorage.setOrCreate(STORE_TRANSCRIBE_PHASE, 'decoding');
  AppStorage.setOrCreate(STORE_TRANSCRIBE_PROGRESS, 0);
  AppStorage.setOrCreate(STORE_TRANSCRIBE_TRACK_ID, track.id);

  try {
    // ① 解码为 16kHz PCM（复用 native）
    const modelDir: string = currentModelDir();
    const opts: AsrInitOptions = { numThreads: 2 };
    await engine.init(modelDir, opts);
    if (mySeq !== runSeq) {
      return;
    }
    await decodeAudioToPcm(audioPath, pcmPath);
    if (mySeq !== runSeq) {
      return;
    }
    const st: fs.Stat = fs.statSync(pcmPath);
    AppStorage.setOrCreate(STORE_TRANSCRIBE_PHASE, 'recognizing');

    // ② 引擎推理
    const result = await engine.transcribe({
      pcmPath: pcmPath,
      pcmBytes: Number(st.size),
      wantTimestamps: engine.supportsTokenTimestamps,
      onProgress: (phase: string, pct: number): void => {
        if (mySeq === runSeq) {
          AppStorage.setOrCreate(STORE_TRANSCRIBE_PHASE, phase);
          AppStorage.setOrCreate(STORE_TRANSCRIBE_PROGRESS, pct);
        }
      },
      isCancelled: (): boolean => mySeq !== runSeq
    });
    if (mySeq !== runSeq) {
      return;
    }

    // ③ 转换为 LyricLine 并落 manual 缓存
    const lines: LyricLine[] = [];
    for (let i = 0; i < result.lines.length; i++) {
      const l: AsrLine = result.lines[i];
      const line: LyricLine = { time: l.time, text: l.text };
      lines.push(line);
    }
    if (lines.length === 0) {
      throw new Error('未识别到歌词内容');
    }
    const lyric: LyricResult = {
      lines: lines,
      synced: true,
      instrumental: false,
      trackName: track.title,
      artistName: track.artist,
      sourceId: result.engineId,
      source: result.engineId,
      dynamic: false
    };
    await LyricsApi.saveBiliSubtitleChoice(track, lyric);
    postAppToast(`${currentEngineLabel()} 转写完成，歌词已绑定`, 2000);
    const seq: number = AppStorage.get<number>(STORE_TRANSCRIBE_DONE_SEQ) ?? 0;
    AppStorage.setOrCreate(STORE_TRANSCRIBE_DONE_SEQ, seq + 1);
  } catch (e) {
    if (mySeq === runSeq) {
      const msg: string = e instanceof Error ? e.message : '转写失败，请重试';
      postAppToast(msg, 2400);
    }
  } finally {
    engine.release();
    if (activeEngine === engine) {
      activeEngine = null;
    }
    try {
      if (fs.accessSync(pcmPath)) {
        fs.unlinkSync(pcmPath);
      }
    } catch (e) {
      // 忽略临时文件清理失败
    }
    if (mySeq === runSeq) {
      running = false;
      AppStorage.setOrCreate(STORE_TRANSCRIBE_RUNNING, false);
      AppStorage.setOrCreate(STORE_TRANSCRIBE_PHASE, '');
      AppStorage.setOrCreate(STORE_TRANSCRIBE_PROGRESS, 0);
    }
  }
}
