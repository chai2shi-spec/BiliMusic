/**
 * ASR 临时目录路径（纯 .ts 模块，供 AppContainer.ts 这类 .ts 文件导入，
 * 避免 .ts 导入 .ets 被 ArkTS 拒绝）。
 *
 * 临时 PCM 产物统一落 ${cacheDir}/transcribe，文件以 _asr_{seq}.pcm 命名隔离。
 */

let transcribeDir: string = '';

/** AppContainer.doInitRest 调用；只登记路径，不建目录（任务发起时懒建） */
export function initAsrPaths(context: { cacheDir: string }): void {
  transcribeDir = `${context.cacheDir}/transcribe`;
}

/** 取临时 PCM 目录（未初始化返回空串，调用方据此降级） */
export function asrTranscribeDir(): string {
  return transcribeDir;
}
