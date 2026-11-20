/**
 * ASR 转写引擎抽象（NPU 预留点）。
 *
 * 设计意图：
 *   · 上层 AsrTranscribeCoordinator 只依赖本接口，不关心底层是系统 speechRecognizer
 *     还是 sherpa_onnx 的第三方模型；将来有麒麟 NPU 通路只需新增一个 implements
 *     AsrEngine 的实现并在 AsrEngineRegistry 注册，Coordinator / UI 零改动。
 *   · 每个引擎实例是一次转写任务的作用域：transcribe 后可 release，
 *     避免模型内存跨曲目累积。
 *   · 时间戳统一为「秒」，与 LyricLine.time 同单位，落库时无需换算。
 */

/** 内置引擎 id：system = 现有系统识别；其余为 AsrModelCatalog 里的模型 id */
export type AsrEngineId = string;

/** 引擎种类的稳定标识（用于 UI 分组与默认回退） */
export const ASR_ENGINE_SYSTEM: string = 'system';

/** 转写请求 */
export interface AsrTranscribeRequest {
  /** 16kHz / 单声道 / s16le 的 PCM 文件路径（由 decodeAudioToPcm 产出） */
  pcmPath: string;
  /** PCM 总字节数（16bit 单声道 → 每毫秒 32 字节） */
  pcmBytes: number;
  /** 是否输出逐 token 时间戳（不支持的引擎忽略） */
  wantTimestamps: boolean;
  /** 进度回调：phase = decoding | recognizing, progress 0-100 */
  onProgress?: (phase: string, progress: number) => void;
  /** 段间检查：返回 true 表示用户已取消，引擎应立即停止 */
  isCancelled?: () => boolean;
}

/** 一行转写结果（对应 LyricLine） */
export interface AsrLine {
  /** 行起始时间，单位秒 */
  time: number;
  /** 识别文本 */
  text: string;
}

/** 转写结果 */
export interface AsrTranscribeResult {
  lines: AsrLine[];
  /** 实际使用的引擎 id（写入 LyricResult.source / sourceId） */
  engineId: AsrEngineId;
  /** 是否拿到了可用的时间戳；false 时上层用段内均匀分布兜底 */
  hasTimestamps: boolean;
}

/** 初始化选项 */
export interface AsrInitOptions {
  /** 线程数（CPU 推理用；系统引擎忽略） */
  numThreads: number;
}

/**
 * 引擎接口。NPU 后端将来只需实现这五个成员。
 */
export interface AsrEngine {
  /** 引擎 id，与 AsrModelCatalog 的 id 对应（system 引擎为 'system'） */
  readonly id: AsrEngineId;
  /** UI 展示名 */
  readonly displayName: string;
  /** 是否支持 token 级时间戳 */
  readonly supportsTokenTimestamps: boolean;

  /**
   * 加载模型 / 准备识别器。系统引擎 modelDir 传空串。
   * 阻塞型操作：实现方应放在 Worker 或异步封装中执行。
   */
  init(modelDir: string, opts: AsrInitOptions): Promise<void>;

  /** 转写一段 PCM 文件；实现方须在段间检查 req.isCancelled */
  transcribe(req: AsrTranscribeRequest): Promise<AsrTranscribeResult>;

  /** 请求取消（置位；真正的中断在段间或 Worker terminate 时发生） */
  cancel(): void;

  /** 释放识别器与模型内存；一次转写结束必须调用 */
  release(): void;
}
