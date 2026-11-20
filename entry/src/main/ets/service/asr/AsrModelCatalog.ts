/**
 * 内置开源 ASR 模型清单（静态编译期常量）。
 *
 * 2026-11-20 收敛为**单一模型（SenseVoice）**：Whisper Small / Qwen3-ASR 0.6B /
 * TeleSpeech CTC 三个条目已移除。取舍原因是手机端的实际成本 —— 这三款要么体积
 * 与内存吃紧（Qwen3 941MB / 约 2GB 内存 / 首载十几秒），要么中文演唱场景不如
 * SenseVoice 稳。`AsrModelKind` 与 `AsrRecognizeWorker.buildConfig()` 的对应
 * 分支**故意保留**，日后要加回同类模型只需在本数组里补一条，不用动引擎层。
 *
 * 数据核实记录：
 *   · 2026-11-19 初版 tokens.txt sha256 全部录错（模型最后一个文件反复「校验失败」，
 *     大文件 .part 留盘导致行状态卡「续传」无限循环 —— 用户反馈「下载到 100% 仍提示续传」）。
 *   · 2026-11-19 重测修正：各 tokens.txt 均在开发机 curl -L 落盘后 SHA256 实测；
 *     LFS 文件 size / sha256 与 hf-mirror /api/models/{repo}/tree/main 的 LFS oid 逐条核对一致。
 *
 * ⚠️ 只用逐文件直链，不用 tar.bz2 —— ArkTS 没有 bz2 解压能力。
 * ⚠️ sha256 是防「上游文件被替换 / 下载截断」的硬校验；任何模型的
 *    files[].sha256 必须是 64 位小写十六进制，下载器会拒收空值。
 *
 * 许可证：SenseVoice 权重是 FunASR Model License 1.1（须署名），UI 必须展示。
 */

/** 单个模型文件 */
export interface AsrModelFile {
  /** 落盘文件名（本地固定，与远端名可不同） */
  name: string;
  /** 远端相对路径（拼到 BASE_URL + repo + /resolve/main/ 之后） */
  remote: string;
  /** 精确字节数 */
  size: number;
  /** sha256（64 位十六进制） */
  sha256: string;
}

/**
 * 模型配置类型：决定 SherpaOnnxAsrEngine 如何填 config.modelConfig。
 * 'paraformer' / 'whisper' / 'telespeech' / 'qwen3' 当前无在册模型用到，
 * 保留是为了日后加回模型时不必再改引擎层。
 */
export type AsrModelKind = 'sensevoice' | 'paraformer' | 'whisper' | 'telespeech' | 'qwen3';

/** 模型清单条目 */
export interface AsrModelSpec {
  id: string;
  displayName: string;
  /** 一句话说明（模型页副标题） */
  summary: string;
  kind: AsrModelKind;
  /** hf-mirror 仓库名 */
  repo: string;
  /**
   * 仓库归属账号（默认 csukuangfj）。个别包只在镜像账号下（如
   * csukuangfj2 的 Qwen3-ASR 导出），据此拼 URL，不改全局 BASE_URL。
   */
  repoOwner?: string;
  /** 许可证展示文案（含署名要求） */
  license: string;
  /** 语言展示 */
  languages: string;
  /** 体积分级（UI 徽标） */
  tier: 'light' | 'balanced' | 'heavy';
  files: AsrModelFile[];
  /** 推荐排序，小的在前 */
  order: number;
}

/** HF 镜像根（主站 huggingface.co 在国内常被拦，镜像实测 200） */
export const ASR_MODEL_BASE_URL: string = 'https://hf-mirror.com/';

/** 内置模型清单（当前只有 SenseVoice 一款） */
export const ASR_MODEL_CATALOG: AsrModelSpec[] = [
  {
    id: 'sensevoice-int8',
    displayName: 'SenseVoice',
    summary: '中英日韩粤多语种，演唱容忍度相对最好',
    kind: 'sensevoice',
    repo: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17',
    license: 'FunASR Model License 1.1（须保留模型名与署名）',
    languages: '中文 / 英文 / 日文 / 韩文 / 粤语',
    tier: 'heavy',
    order: 0,
    files: [
      {
        name: 'model.int8.onnx', remote: 'model.int8.onnx',
        size: 239233841,
        sha256: 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51'
      },
      {
        name: 'tokens.txt', remote: 'tokens.txt',
        size: 315894,
        sha256: 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc'
      }
    ]
  }
];

/** 按 id 取模型规格 */
export function findModel(id: string): AsrModelSpec | undefined {
  for (let i = 0; i < ASR_MODEL_CATALOG.length; i++) {
    if (ASR_MODEL_CATALOG[i].id === id) {
      return ASR_MODEL_CATALOG[i];
    }
  }
  return undefined;
}

/** 该 id 是否仍是清单内的模型（引擎回退与磁盘清理共用） */
export function isKnownModel(id: string): boolean {
  return findModel(id) !== undefined;
}

/** 取模型总字节数 */
export function totalModelBytes(spec: AsrModelSpec): number {
  let sum: number = 0;
  for (let i = 0; i < spec.files.length; i++) {
    sum += spec.files[i].size;
  }
  return sum;
}

/** 拼出单个文件的下载 URL */
export function modelFileUrl(spec: AsrModelSpec, file: AsrModelFile): string {
  const owner: string = spec.repoOwner !== undefined ? spec.repoOwner : 'csukuangfj';
  return `${ASR_MODEL_BASE_URL}${owner}/${spec.repo}/resolve/main/${file.remote}`;
}

/** 人类可读体积（MB，保留 0 位小数） */
export function formatModelSize(bytes: number): string {
  return `${Math.round(bytes / 1024 / 1024)}MB`;
}
