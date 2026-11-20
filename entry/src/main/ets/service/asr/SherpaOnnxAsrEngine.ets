/**
 * sherpa_onnx 第三方模型 ASR 引擎 —— Worker 代理形态。
 *
 * 2026-11-19 重构（AppFreeze 修复）：模型加载与逐段解码原先在主线程同步执行，
 * 单段 30s 解码阻塞数秒触发 THREAD_BLOCK_3S 被系统杀进程。现全部下沉到
 * AsrRecognizeWorker（OfflineRecognizer 是 native 对象不能跨线程，必须在
 * worker 线程内创建使用）。本类只负责：
 *   · init：暂存模型目录/线程数（真正加载在 worker 内）；
 *   · transcribe：拉起 worker、转发 run/cancel、接收 progress/result/error；
 *   · worker 收到终态消息后 terminate，模型内存随线程销毁确定性释放。
 */

import { worker, MessageEvents, ErrorEvent } from '@kit.ArkTS';
import { AsrEngine, AsrEngineId, AsrInitOptions, AsrLine, AsrTranscribeRequest,
  AsrTranscribeResult } from './AsrEngine';
import { AsrWorkerMessage } from './AsrWorkerProtocol';

/** Worker 脚本路径（{module}/ets/{src/main/ets 下的相对路径}.ets）。
 *  ⚠️ 必须内联字面量且 Worker 文件已在 entry/build-profile.json5 的
 *  sourceOption.workers 注册，否则不会打包进 HAP，运行时报
 *  「The worker file path is invalid, can't find the file」（2026-11-19 真机踩坑）。 */

export class SherpaOnnxAsrEngine implements AsrEngine {
  readonly id: AsrEngineId;
  readonly displayName: string;
  readonly supportsTokenTimestamps: boolean = true;

  private modelDir: string = '';
  private numThreads: number = 2;
  private current: worker.ThreadWorker | null = null;
  private cancelled: boolean = false;

  constructor(id: string, displayName: string) {
    this.id = id;
    this.displayName = displayName;
  }

  async init(modelDir: string, opts: AsrInitOptions): Promise<void> {
    this.release();
    this.modelDir = modelDir;
    this.numThreads = opts.numThreads > 0 ? opts.numThreads : 2;
  }

  async transcribe(req: AsrTranscribeRequest): Promise<AsrTranscribeResult> {
    this.cancelled = false;
    const w: worker.ThreadWorker =
      new worker.ThreadWorker('entry/ets/service/asr/AsrRecognizeWorker.ets');
    this.current = w;
    return await new Promise<AsrTranscribeResult>(
      (resolve: (value: AsrTranscribeResult) => void,
       reject: (reason: Error) => void): void => {
        const finish = (result: AsrTranscribeResult): void => {
          this.current = null;
          try {
            w.terminate();
          } catch (e) {
            // worker 已退出
          }
          resolve(result);
        };
        w.onmessage = (e: MessageEvents): void => {
          const msg: AsrWorkerMessage = e.data as AsrWorkerMessage;
          if (msg.type === 'progress') {
            // 取消路径兜底：只改 runSeq 的调用方（isCancelled）也能停下
            if (this.cancelled || (req.isCancelled !== undefined && req.isCancelled())) {
              const c: AsrWorkerMessage = { type: 'cancel' };
              w.postMessage(c);
            }
            if (req.onProgress !== undefined) {
              req.onProgress('recognizing', msg.percent ?? 0);
            }
            return;
          }
          if (msg.type === 'result') {
            const lines: AsrLine[] = msg.lines ?? [];
            finish({ lines: lines, engineId: this.id, hasTimestamps: msg.hasTimestamps ?? false });
            return;
          }
          if (msg.type === 'cancelled') {
            finish({ lines: [], engineId: this.id, hasTimestamps: false });
            return;
          }
          if (msg.type === 'error') {
            this.current = null;
            try {
              w.terminate();
            } catch (err) {
              // worker 已退出
            }
            reject(new Error(msg.message ?? '转写失败'));
          }
        };
        w.onerror = (err: ErrorEvent): void => {
          if (this.current === w) {
            this.current = null;
          }
          reject(new Error(`识别线程异常：${err.message}`));
        };
        w.onexit = (code: number): void => {
          // 终态消息后 terminate 触发的正常退出（current 已清）不做处理；
          // 未收到终态就退出（异常路径）→ 兜底 reject，避免 promise 悬挂
          if (this.current === w) {
            this.current = null;
            reject(new Error(`识别线程异常退出（code ${code}）`));
          }
        };
        const runMsg: AsrWorkerMessage = {
          type: 'run',
          modelId: this.id,
          modelDir: this.modelDir,
          numThreads: this.numThreads,
          pcmPath: req.pcmPath
        };
        w.postMessage(runMsg);
      });
  }

  cancel(): void {
    this.cancelled = true;
    if (this.current !== null) {
      const msg: AsrWorkerMessage = { type: 'cancel' };
      this.current.postMessage(msg);
    }
  }

  release(): void {
    if (this.current !== null) {
      const w: worker.ThreadWorker = this.current;
      this.current = null;
      try {
        w.terminate();
      } catch (e) {
        // worker 已退出
      }
    }
  }
}
