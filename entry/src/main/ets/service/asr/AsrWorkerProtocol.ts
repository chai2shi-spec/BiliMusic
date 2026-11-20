/**
 * ASR 识别 Worker 消息协议。
 *
 * 主线程（SherpaOnnxAsrEngine）与 AsrRecognizeWorker 之间的全部通信都走这一个
 * 消息结构：结构化克隆要求字段是可序列化基础类型，且 ArkTS 禁止对象字面量类型，
 * 所以用「单个接口 + 可选字段 + type 判别」而不是判别联合。
 *
 * 消息方向（type → 方向）：
 *   run / cancel      主线程 → Worker
 *   progress / result / cancelled / error   Worker → 主线程
 */

import { AsrLine } from './AsrEngine';

export interface AsrWorkerMessage {
  /** run | cancel | progress | result | cancelled | error */
  type: string;
  /** run：模型 id（AsrModelCatalog 里的 key） */
  modelId?: string;
  /** run：模型落盘目录（filesDir/asr_models/{modelId}） */
  modelDir?: string;
  /** run：推理线程数 */
  numThreads?: number;
  /** run：16kHz 单声道 s16le PCM 文件路径 */
  pcmPath?: string;
  /** progress：0-100 */
  percent?: number;
  /** result：识别出的歌词行 */
  lines?: AsrLine[];
  /** result：是否拿到了 token 级时间戳 */
  hasTimestamps?: boolean;
  /** error：错误文案 */
  message?: string;
}
