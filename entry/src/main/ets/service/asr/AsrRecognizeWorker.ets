/**
 * sherpa_onnx 推理 Worker 脚本。
 *
 * 为什么必须用 Worker（2026-11-19 真机 AppFreeze 修复）：
 *   · sherpa 原生推理（模型加载 + 单段解码）是同步 NAPI 调用，原先跑在主线程，
 *     30s 音频段解码阻塞数秒，触发 THREAD_BLOCK_3S 被系统杀进程（AppFreeze）。
 *   · OfflineRecognizer 是 native 对象，不能跨线程传递，只能在 Worker 线程内
 *     创建、使用、随线程销毁 —— 模型内存随 worker terminate 确定性释放。
 *   · 进度/取消通过 postMessage 双向通信（taskpool 的 @Concurrent 函数无法
 *     增量上报进度，不适合本场景）。
 *
 * 本文件在 Worker 线程执行，不要 import 到主线程代码里（消息类型见
 * AsrWorkerProtocol.ts）。
 */

import { worker, ThreadWorkerGlobalScope, MessageEvents } from '@kit.ArkTS';
import {
  FeatureConfig, OfflineModelConfig, OfflineRecognizer, OfflineRecognizerConfig,
  OfflineStream
} from 'sherpa_onnx';
import { AsrModelSpec, findModel } from './AsrModelCatalog';
import { AsrWorkerMessage } from './AsrWorkerProtocol';
import { AsrLine } from './AsrEngine';
import {
  pcmBytesToFloat, readPcmFile, splitPcm, tokensToLines, textToLinesEvenly,
  SEGMENT_SECONDS
} from './AsrPcmUtil';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;

/** 收到 cancel 消息置位；解码循环每段之间检查 */
let cancelled: boolean = false;

function post(msg: AsrWorkerMessage): void {
  workerPort.postMessage(msg);
}

/**
 * 按后缀从模型清单找落盘文件名拼绝对路径。
 * ⚠️ 不能硬编码文件名：whisper 的 tokens 落盘名是 tiny-tokens.txt（不是
 * tokens.txt），写死会让 native 校验报「please check your config」——
 * 2026-11-19 真机踩坑。清单才是唯一事实源。
 */
function filePath(spec: AsrModelSpec, modelDir: string, suffix: string): string {
  for (let i = 0; i < spec.files.length; i++) {
    if (spec.files[i].name.endsWith(suffix)) {
      return `${modelDir}/${spec.files[i].name}`;
    }
  }
  throw new Error(`模型清单缺少 ${suffix} 文件`);
}

/** 清单里是否有以该后缀结尾的文件（LLM 解码类模型没有 tokens.txt） */
function hasFile(spec: AsrModelSpec, suffix: string): boolean {
  for (let i = 0; i < spec.files.length; i++) {
    if (spec.files[i].name.endsWith(suffix)) {
      return true;
    }
  }
  return false;
}

/** 从模型目录构造配置。路径是 filesDir 下的绝对路径（单参数构造入口） */
function buildConfig(spec: AsrModelSpec, modelDir: string, numThreads: number): OfflineRecognizerConfig {
  const config: OfflineRecognizerConfig = new OfflineRecognizerConfig();
  config.featConfig = new FeatureConfig();
  config.featConfig.sampleRate = 16000;
  config.featConfig.featureDim = 80;
  const mc: OfflineModelConfig = config.modelConfig;
  mc.numThreads = numThreads > 0 ? numThreads : 2;
  mc.provider = 'cpu';
  // CTC / whisper 系模型要一个 tokens.txt；Qwen3-ASR 这类 LLM 解码模型用自带
  // tokenizer 目录（vocab.json + merges.txt），清单里没有 tokens.txt
  if (hasFile(spec, 'tokens.txt')) {
    mc.tokens = filePath(spec, modelDir, 'tokens.txt');
  }
  switch (spec.kind) {
    case 'sensevoice':
      mc.senseVoice.model = filePath(spec, modelDir, 'model.int8.onnx');
      mc.senseVoice.useItn = true;
      break;
    case 'paraformer':
      mc.paraformer.model = filePath(spec, modelDir, 'model.int8.onnx');
      break;
    case 'telespeech':
      mc.telespeechCtc = filePath(spec, modelDir, 'model.int8.onnx');
      break;
    case 'whisper':
      mc.whisper.encoder = filePath(spec, modelDir, 'encoder.int8.onnx');
      mc.whisper.decoder = filePath(spec, modelDir, 'decoder.int8.onnx');
      mc.whisper.language = 'zh';
      mc.whisper.task = 'transcribe';
      mc.whisper.enableTokenTimestamps = true;
      break;
    case 'qwen3':
      // conv_frontend + encoder + decoder（KV cache）+ tokenizer 目录四件套
      mc.qwen3Asr.convFrontend = filePath(spec, modelDir, 'conv_frontend.onnx');
      mc.qwen3Asr.encoder = filePath(spec, modelDir, 'encoder.int8.onnx');
      mc.qwen3Asr.decoder = filePath(spec, modelDir, 'decoder.int8.onnx');
      // tokenizer 参数是**目录**：本架构把 vocab.json / merges.txt 与权重平铺
      // 在同一个模型目录里，所以直接把模型目录交出去
      mc.qwen3Asr.tokenizer = modelDir;
      // maxNewTokens 默认 64 会把 28s 的中文句子截掉一半（约 1.5 字/token）
      mc.qwen3Asr.maxNewTokens = 256;
      mc.qwen3Asr.maxTotalLen = 512;
      mc.qwen3Asr.seed = 42;
      break;
    default:
      break;
  }
  return config;
}

/** 一次完整识别：建 recognizer → 读 PCM → 逐段解码 → 回传结果 */
function runRecognition(msg: AsrWorkerMessage): void {
  const modelId: string = msg.modelId ?? '';
  const spec: AsrModelSpec | undefined = findModel(modelId);
  if (spec === undefined) {
    post({ type: 'error', message: `未知模型：${modelId}` });
    return;
  }
  const modelDir: string = msg.modelDir ?? '';
  const pcmPath: string = msg.pcmPath ?? '';
  if (modelDir.length === 0 || pcmPath.length === 0) {
    post({ type: 'error', message: '识别参数缺失，请重试' });
    return;
  }
  // 模型加载（约 1-3s）+ 解码全在本线程，主线程零阻塞
  const recognizer: OfflineRecognizer =
    new OfflineRecognizer(buildConfig(spec, modelDir, msg.numThreads ?? 2));
  const raw: Uint8Array = readPcmFile(pcmPath);
  const samples: Float32Array = pcmBytesToFloat(raw);
  const segments = splitPcm(samples, SEGMENT_SECONDS);
  const lines: AsrLine[] = [];
  let hasTimestamps: boolean = false;
  for (let i = 0; i < segments.length; i++) {
    if (cancelled) {
      break;
    }
    const seg = segments[i];
    const stream: OfflineStream = recognizer.createStream();
    stream.acceptWaveform({ samples: seg.samples, sampleRate: 16000 });
    recognizer.decode(stream);
    const result = recognizer.getResult(stream);
    const tokens: string[] = result.tokens;
    const timestamps: number[] = result.timestamps;
    if (tokens.length > 0 && timestamps.length >= tokens.length) {
      hasTimestamps = true;
      const part: AsrLine[] = tokensToLines(tokens, timestamps, seg.startSec, 0.7, 18);
      for (let j = 0; j < part.length; j++) {
        lines.push(part[j]);
      }
    } else if (result.text.length > 0) {
      // 无 token 时间戳：段内均匀分布（演唱场景至少保证行时间单调）
      const part: AsrLine[] = textToLinesEvenly(result.text, seg.startSec, seg.endSec, 18);
      for (let j = 0; j < part.length; j++) {
        lines.push(part[j]);
      }
    }
    post({ type: 'progress', percent: Math.floor((i + 1) * 100 / segments.length) });
  }
  if (cancelled) {
    post({ type: 'cancelled' });
    return;
  }
  lines.sort((a: AsrLine, b: AsrLine): number => a.time - b.time);
  post({ type: 'result', lines: lines, hasTimestamps: hasTimestamps });
}

workerPort.onmessage = (e: MessageEvents): void => {
  // e.data 是结构化克隆产物，按协议约定收敛到唯一消息接口
  const msg: AsrWorkerMessage = e.data as AsrWorkerMessage;
  if (msg.type === 'cancel') {
    cancelled = true;
    return;
  }
  if (msg.type === 'run') {
    cancelled = false;
    try {
      runRecognition(msg);
    } catch (err) {
      const e2: Error = err instanceof Error ? err : new Error('识别失败');
      post({ type: 'error', message: e2.message });
    }
  }
};
