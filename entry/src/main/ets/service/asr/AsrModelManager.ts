/**
 * 开源 ASR 模型管理器：下载（断点续传）/ 流式 SHA-256 校验 / 删除 / 安装状态。
 *
 * 目录约定（filesDir，不用 cacheDir —— 后者会被系统清理）：
 *   {filesDir}/asr_models/
 *     ├── manifest.json                 已安装模型元数据（文件而非 Preferences：8192 字节上限）
 *     ├── {modelId}/
 *     │    ├── <file.name>              校验通过才改名落位
 *     │    └── .installed               校验通过标记（内容 = 安装时间戳）
 *     └── _tmp/{modelId}/{file.name}.part  下载中间态，可续传
 *
 * 下载范式照抄 DownloadManager.downloadFile（requestInStream + headersReceive +
 * dataReceive 显式 offset 写链 + dataEnd 等待 + 严格收尾顺序），但**独立实现**：
 * DownloadManager 深度耦合 DownloadTask/RDB/音频魔数校验，抽公共层会污染音乐下载列表。
 *
 * 事件名必须是 headersReceive（复数），headerReceive 已废弃。
 */

import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import common from '@ohos.app.ability.common';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import {
  AsrModelFile,
  AsrModelSpec,
  findModel,
  isKnownModel,
  modelFileUrl,
  totalModelBytes
} from './AsrModelCatalog';

/** 单个模型的安装状态（UI 回显用） */
export interface AsrModelState {
  installed: boolean;
  /** 已落盘字节数（安装=总大小；未安装=续传可用字节数） */
  bytes: number;
  /** 安装时间戳（毫秒），未安装为 0 */
  installedAt: number;
}

/** 下载进度快照（写 AppStorage，UI 订阅） */
export interface AsrDownloadProgress {
  modelId: string;
  fileName: string;
  received: number;
  total: number;
  percent: number;
  running: boolean;
  error: string;
}

/** manifest 里的一条记录 */
interface ManifestEntry {
  installedAt: number;
  bytes: number;
}

/**
 * 流式接收的「停滞」判据（ms）：只要有数据推进就刷新，连续这么久一个字节都没来
 * 才认定连接断了。**不能**用「从开始算起的固定总时长」—— 325MB 的模型在慢网下
 * 要跑几分钟，固定超时会把正常下载误判为失败（DownloadManager 同款判据）。
 */
const STREAM_IDLE_TIMEOUT_MS: number = 30000;

/** downloadOne 的三态结果 */
const DL_OK: number = 0;
const DL_FAIL: number = 1;
/** 下载源暂时性故障（HTTP 429/500/502/503/504）：.part 已回滚保护，退避后可重试 */
const DL_RETRY_TRANSIENT: number = 2;
/** 暂时性错误自动重试次数上限（不含首次）。退避 15/30/60/120s，共约 4 分钟 */
const MAX_TRANSIENT_RETRIES: number = 4;
/** 最近一次暂时性错误的响应码（429/5xx），0 = 无 */
let lastTransientCode: number = 0;
/** 最近一次 429/503 响应的 Retry-After（秒），0 = 服务端没给 */
let last429RetryAfterSec: number = 0;

/** 是否为值得退避重试的暂时性错误码（限流 / 网关波动，重试大概率自愈） */
function isTransientHttpCode(code: number): boolean {
  return code === 429 || code === 500 || code === 502 || code === 503 || code === 504;
}

let modelsDir: string = '';
let manifestPath: string = '';
let manifest: Record<string, ManifestEntry> = {};

/** 当前下载任务：同一时刻只允许一个 */
let downloadToken: number = 0;
let downloadRunning: boolean = false;
/** 由调用方注入的进度发布回调（避免本模块直接依赖 AppStorage 键名） */
let progressSink: (p: AsrDownloadProgress) => void = (): void => {};

/** 初始化：登记目录并加载 manifest（AppContainer.doInitRest 调用，毫秒级） */
export function initAsrModelManager(context: common.Context): void {
  modelsDir = `${context.filesDir}/asr_models`;
  manifestPath = `${modelsDir}/manifest.json`;
  try {
    if (!fs.accessSync(modelsDir)) {
      fs.mkdirSync(modelsDir, true);
    }
  } catch (e) {
    console.error(`[AsrModelManager] mkdir failed: ${JSON.stringify(e)}`);
  }
  loadManifest();
  // 清单收敛（2026-11-20 只留 SenseVoice）后清掉已下架模型的残留：
  // 延迟执行，不占首屏时间；删目录是纯 unlink，几百 MB 也就几十毫秒
  setTimeout((): void => {
    pruneRetiredModels();
  }, 2500);
}

/** 注入进度发布函数（调用方负责写 AppStorage） */
export function setAsrProgressSink(sink: (p: AsrDownloadProgress) => void): void {
  progressSink = sink;
}

/** 当前是否有下载在进行 */
export function isAsrDownloadRunning(): boolean {
  return downloadRunning;
}

/** 模型根目录（SherpaOnnxAsrEngine 加载模型时用） */
export function getAsrModelsDir(): string {
  return modelsDir;
}

/** 取某个模型已安装到的目录路径 */
export function getInstalledModelDir(modelId: string): string {
  return `${modelsDir}/${modelId}`;
}

function loadManifest(): void {
  manifest = {};
  try {
    if (!fs.accessSync(manifestPath)) {
      return;
    }
    const file: fs.File = fs.openSync(manifestPath, fs.OpenMode.READ_ONLY);
    try {
      const stat: fs.Stat = fs.statSync(file.fd);
      if (stat.size > 0) {
        const buf: ArrayBuffer = new ArrayBuffer(stat.size);
        fs.readSync(file.fd, buf, { offset: 0, length: stat.size });
        const text: string = bufferToUtf8(buf);
        const parsed: Object = JSON.parse(text) as Object;
        manifest = parsed as Record<string, ManifestEntry>;
      }
    } finally {
      fs.closeSync(file);
    }
  } catch (e) {
    console.warn(`[AsrModelManager] load manifest failed: ${JSON.stringify(e)}`);
    manifest = {};
  }
}

function saveManifest(): void {
  try {
    const text: string = JSON.stringify(manifest);
    const data: Uint8Array = utf8ToBuffer(text);
    const file: fs.File = fs.openSync(manifestPath,
      fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
    } finally {
      fs.closeSync(file);
    }
  } catch (e) {
    console.error(`[AsrModelManager] save manifest failed: ${JSON.stringify(e)}`);
  }
}

function utf8ToBuffer(text: string): Uint8Array {
  const encoder: util.TextEncoder = new util.TextEncoder();
  return encoder.encodeInto(text);
}

function bufferToUtf8(buf: ArrayBuffer): string {
  const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  return decoder.decode(new Uint8Array(buf));
}

function hexOf(data: Uint8Array): string {
  let out: string = '';
  for (let i = 0; i < data.length; i++) {
    const b: number = data[i];
    out += (b < 16 ? '0' : '') + b.toString(16);
  }
  return out;
}

/**
 * 流式 SHA-256（不整文件读入内存）。
 * 用同步 API：下载完成后在调用方 async 上下文里跑，几百 MB 耗时约 1-2s，
 * 换来的收益是不用把整个 ONNX 文件塞进 ArkTS 堆。
 */
function sha256File(path: string): string {
  const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const chunk: ArrayBuffer = new ArrayBuffer(1024 * 1024);
    let offset: number = 0;
    while (true) {
      const n: number = fs.readSync(file.fd, chunk, { offset: offset, length: chunk.byteLength });
      if (n <= 0) {
        break;
      }
      const slice: Uint8Array = new Uint8Array(chunk, 0, n);
      md.updateSync({ data: slice } as cryptoFramework.DataBlob);
      offset += n;
    }
    const digest: cryptoFramework.DataBlob = md.digestSync();
    return hexOf(digest.data);
  } finally {
    fs.closeSync(file);
  }
}

/** 取一个模型的安装状态（纯 stat + manifest 读，无网络） */
export function getModelState(modelId: string): AsrModelState {
  const spec: AsrModelSpec | undefined = findModel(modelId);
  if (spec === undefined) {
    return { installed: false, bytes: 0, installedAt: 0 };
  }
  const dir: string = `${modelsDir}/${modelId}`;
  const marker: string = `${dir}/.installed`;
  let installed: boolean = false;
  let installedAt: number = 0;
  try {
    installed = fs.accessSync(marker);
    if (installed) {
      const f: fs.File = fs.openSync(marker, fs.OpenMode.READ_ONLY);
      try {
        const b: ArrayBuffer = new ArrayBuffer(32);
        const n: number = fs.readSync(f.fd, b, { offset: 0, length: 32 });
        installedAt = Number(bufferToUtf8(b.slice(0, n)).trim());
      } catch (e) {
        installedAt = 0;
      } finally {
        fs.closeSync(f);
      }
    }
  } catch (e) {
    installed = false;
  }
  // 标记存在但文件缺失/大小不符 → 视为未安装（防止 manifest 与实际脱节）
  if (installed) {
    for (let i = 0; i < spec.files.length; i++) {
      try {
        const st: fs.Stat = fs.statSync(`${dir}/${spec.files[i].name}`);
        if (st.size !== spec.files[i].size) {
          installed = false;
          break;
        }
      } catch (e) {
        installed = false;
        break;
      }
    }
  }
  let bytes: number = 0;
  if (installed) {
    bytes = totalModelBytes(spec);
  } else {
    // 累加仍在的 .part 长度，供「继续下载」显示
    for (let i = 0; i < spec.files.length; i++) {
      try {
        const st: fs.Stat = fs.statSync(`${modelsDir}/_tmp/${modelId}/${spec.files[i].name}.part`);
        bytes += st.size;
      } catch (e) {
        // 文件不存在 = 0
      }
    }
  }
  return { installed: installed, bytes: bytes, installedAt: installedAt };
}

/** 累计已安装模型占用的磁盘字节数 */
export function installedBytes(): number {
  let sum: number = 0;
  const ids: string[] = Object.keys(manifest);
  for (let i = 0; i < ids.length; i++) {
    const spec: AsrModelSpec | undefined = findModel(ids[i]);
    if (spec !== undefined) {
      sum += totalModelBytes(spec);
    }
  }
  return sum;
}

/** 取消当前下载（置位；真正的中断发生在 dataReceive 回调检测处） */
export function cancelAsrDownload(): void {
  downloadToken++;
}

/**
 * 下载并安装一个模型（逐文件：下载到 .part → 校验 → 改名落位）。
 * 同一时刻只允许一个任务，重复调用直接返回 false。
 */
export async function downloadModel(modelId: string): Promise<boolean> {
  const spec: AsrModelSpec | undefined = findModel(modelId);
  if (spec === undefined || downloadRunning) {
    return false;
  }
  const myToken: number = ++downloadToken;
  downloadRunning = true;
  const dir: string = `${modelsDir}/${modelId}`;
  const tmpDir: string = `${modelsDir}/_tmp/${modelId}`;
  try {
    if (!fs.accessSync(tmpDir)) {
      fs.mkdirSync(tmpDir, true);
    }
    for (let i = 0; i < spec.files.length; i++) {
      if (myToken !== downloadToken) {
        // 文件之间被取消：必须发一条 running=false，否则 UI 永远停在「取消」态
        publish(modelId, spec.files[i].name, 0, spec.files[i].size, 0, false, '已取消');
        return false;
      }
      const fileSpec: AsrModelFile = spec.files[i];
      const partPath: string = `${tmpDir}/${fileSpec.name}.part`;
      // hf-mirror 限流（429）/ 网关波动（5xx）是常态：自动退避重试，别把用户晾在失败态
      let attempt: number = 0;
      let result: number = DL_FAIL;
      while (true) {
        result = await downloadOne(
          modelId, fileSpec, modelFileUrl(spec, fileSpec), partPath, myToken
        );
        if (result !== DL_RETRY_TRANSIENT || attempt >= MAX_TRANSIENT_RETRIES) {
          break;
        }
        attempt++;
        const backoff: number = Math.min(120, 15 * attempt);
        const waitSec: number = last429RetryAfterSec > 0
          ? Math.min(600, last429RetryAfterSec) : backoff;
        const reason: string = lastTransientCode === 429
          ? `下载源限流，${waitSec}秒后自动重试`
          : `下载源波动（HTTP ${lastTransientCode}），${waitSec}秒后自动重试`;
        publish(modelId, fileSpec.name, 0, fileSpec.size, 0, true,
          `${reason}（${attempt}/${MAX_TRANSIENT_RETRIES}）`);
        const interrupted: boolean = await sleepUnlessDownloadChanged(waitSec * 1000, myToken);
        if (interrupted || myToken !== downloadToken) {
          publish(modelId, fileSpec.name, 0, fileSpec.size, 0, false, '已取消');
          return false;
        }
      }
      if (result === DL_RETRY_TRANSIENT) {
        // 重试用尽仍是暂时性错误：放弃本轮，用户稍后点「重试」即可（.part 断点完好）
        const giveUp: string = lastTransientCode === 429
          ? '下载源限流（HTTP 429），请稍后重试'
          : `下载源暂时不可用（HTTP ${lastTransientCode}），请稍后重试`;
        publish(modelId, fileSpec.name, 0, fileSpec.size, 0, false, giveUp);
        return false;
      }
      if (result !== DL_OK) {
        return false;
      }
    }
    // 全部文件校验通过后统一落位（避免中途失败留下半套模型）
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    for (let i = 0; i < spec.files.length; i++) {
      const f: AsrModelFile = spec.files[i];
      const partPath: string = `${tmpDir}/${f.name}.part`;
      const destPath: string = `${dir}/${f.name}`;
      try {
        if (fs.accessSync(destPath)) {
          fs.unlinkSync(destPath);
        }
        fs.renameSync(partPath, destPath);
      } catch (e) {
        console.error(`[AsrModelManager] move file failed: ${JSON.stringify(e)}`);
        publish(modelId, f.name, 0, f.size, 0, false, '安装失败，请重试');
        return false;
      }
    }
    const marker: string = `${dir}/.installed`;
    const mf: fs.File = fs.openSync(marker,
      fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      const stamp: Uint8Array = utf8ToBuffer(String(Date.now()));
      fs.writeSync(mf.fd, stamp.buffer.slice(stamp.byteOffset, stamp.byteOffset + stamp.byteLength));
    } finally {
      fs.closeSync(mf);
    }
    manifest[modelId] = { installedAt: Date.now(), bytes: totalModelBytes(spec) };
    saveManifest();
    publish(modelId, spec.files[spec.files.length - 1].name,
      totalModelBytes(spec), totalModelBytes(spec), 100, false, '');
    return true;
  } finally {
    downloadRunning = false;
  }
}

/** 下载单个文件：Range 续传 + 进度 + 取消 + 完成后 SHA-256 校验。
 *  返回 DL_OK / DL_FAIL / DL_RETRY_TRANSIENT（暂时性错误时 .part 已截回本跳起点，断点无损）。 */
async function downloadOne(
  modelId: string, file: AsrModelFile, url: string, partPath: string, myToken: number
): Promise<number> {
  let resumeFrom: number = 0;
  try {
    const st: fs.Stat = fs.statSync(partPath);
    // 只信任真实落盘长度；超过预期大小说明残骸，从头下
    if (st.size > 0 && st.size < file.size) {
      resumeFrom = st.size;
    } else if (st.size >= file.size) {
      // 可能上次下载完成但校验失败 → 先校验，通过就跳过下载
      if (sha256File(partPath) === file.sha256) {
        publish(modelId, file.name, file.size, file.size, 100, true, '');
        return DL_OK;
      }
      fs.unlinkSync(partPath);
    }
  } catch (e) {
    // 文件不存在 = 全新下载
  }
  console.info(`[AsrModel] begin ${file.name} expected=${file.size} resumeFrom=${resumeFrom}`);

  const request: http.HttpRequest = http.createHttp();
  let fd: number = -1;
  let dataEnded: boolean = false;
  let resumeDecided: boolean = false;
  let resumeOk: boolean = false;
  let writeOffset: number = resumeFrom;
  let writeChain: Promise<void> = Promise.resolve();
  let writeFailed: boolean = false;
  let fatalError: string = '';
  let total: number = file.size;
  let received: number = resumeFrom;
  /** 429 响应带的 Retry-After（秒），0 = 没给 */
  let retryAfterSec: number = 0;
  /** 最近一跳响应里 Content-Range 的起始字节（没见过为 -1）：续传对齐守卫用 */
  let lastRangeStart: number = -1;
  /** 最近一次收到数据的时刻：空闲超时判据（每次 dataReceive 刷新） */
  let lastDataAt: number = Date.now();

  try {
    const fileHandle: fs.File = await fs.open(partPath,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    fd = fileHandle.fd;
    if (resumeFrom === 0) {
      await fs.truncate(fd, 0);
    }
  } catch (e) {
    console.error(`[AsrModelManager] open part failed: ${JSON.stringify(e)}`);
    request.destroy();
    return DL_FAIL;
  }

  request.on('headersReceive', (header: Object): void => {
    try {
      const h: Record<string, Object> = header as Record<string, Object>;
      let rawCr: Object | undefined = h['content-range'];
      if (rawCr === undefined) {
        rawCr = h['Content-Range'];
      }
      const cr: string = rawCr !== undefined && rawCr !== null ? String(rawCr) : '';
      // 每一跳都记录 Content-Range 起始字节：headersReceive 对重定向链会逐跳触发
      // （hf-mirror 的 resolve 必有 302/307 跳转，DownloadManager 同款观察），
      // 续传对齐守卫要读的是「最终响应」的起始字节
      if (cr.indexOf('bytes ') === 0) {
        const dash: number = cr.indexOf('-', 6);
        if (dash > 6) {
          const start: number = Number(cr.substring(6, dash));
          if (start >= 0) {
            lastRangeStart = start;
          }
        }
      }
      // ⚠️ 只在**本跳真的带 Content-Range** 时才给续传定论：hf-mirror 的
      // resolve 必有一次 302/307，那一跳没有 Content-Range。若在此就判成
      // 「服务端不认 Range」，会把已下好的几十上百 MB 当场截断重写 ——
      // 症状是「续传后长度对、sha256 不对」+ 进度条忽然回退到 0。
      // 真·全量响应（200 且始终无 Content-Range）由 dataReceive 首包兜底。
      if (resumeFrom > 0 && !resumeDecided && cr.indexOf('bytes ') === 0) {
        resumeDecided = true;
        resumeOk = lastRangeStart === resumeFrom;
        if (!resumeOk) {
          // 服务端不支持续传（回 200 全量）→ 从头写。
          // ⚠️ 截断必须**排进写链**，不能 void 裸调：裸调会与队列里尚未落盘的
          // 写入并发执行，把前半段数据截掉 / 错位，最终「长度对得上但 sha256 不对」
          // （DownloadManager 同一处注释踩过同样的坑）。
          writeOffset = 0;
          received = 0;
          writeChain = writeChain.then((): Promise<void> => fs.truncate(fd, 0));
        }
      }
      let rawRa: Object | undefined = h['retry-after'];
      if (rawRa === undefined) {
        rawRa = h['Retry-After'];
      }
      if (rawRa !== undefined && rawRa !== null) {
        const n: number = Number(rawRa);
        if (n > 0) {
          retryAfterSec = n;
        }
      }
      let raw: Object | undefined = h['content-length'];
      if (raw === undefined) {
        raw = h['Content-Length'];
      }
      if (raw !== undefined && raw !== null) {
        const n: number = Number(raw);
        // 重定向链每一跳都会触发 headersReceive：302 的 Content-Length 只有
        // 1KB 上下，直接赋值会把总大小写成 1058（进度条瞬间跳到 100%）。
        // 以清单 file.size 为准，只接受更大的值（真比清单大说明清单过期）。
        if (n > total) {
          total = n;
        }
      }
      console.info(`[AsrModel] headers ${file.name} resumeOk=${resumeOk} total=${total}`);
    } catch (e) {
      console.warn(`[AsrModelManager] parse header failed: ${JSON.stringify(e)}`);
    }
  });

  // ⚠️ 整个回调体包 try/catch：这里抛出的异常落在事件回调里、不属于任何 Promise
  // 链，没有 .catch() 能接住 → 主线程未捕获异常直接闪退（DownloadManager 血泪）。
  request.on('dataReceive', (data: ArrayBuffer): void => {
    try {
      if (myToken !== downloadToken) {
        fatalError = 'cancelled';
        return;
      }
      if (writeFailed) {
        return;
      }
      // 兜底：一路都没见过 Content-Range 就来了数据 = 服务端回的是 200 全量
      // （不支持 Range）。此时必须从头写，否则 232MB 的断点会被全量数据覆盖前段。
      if (resumeFrom > 0 && !resumeDecided) {
        resumeDecided = true;
        resumeOk = false;
        writeOffset = 0;
        received = 0;
        writeChain = writeChain.then((): Promise<void> => fs.truncate(fd, 0));
      }
      const offset: number = writeOffset;
      writeOffset += data.byteLength;
      received += data.byteLength;
      lastDataAt = Date.now();
      // ⚠️ 必须拷贝一份再排队：回调的 ArrayBuffer 由网络层持有，写入是异步排队的，
      // 等真正落盘时这块内存可能已被下一批数据覆盖 —— 症状正是「长度正确、sha256 不对」。
      // ⚠️ 并且 fs.write 可能短写（返回值 < 请求长度），必须循环补齐，
      // 否则中间留空洞，同样表现为长度对、内容错。
      const chunk: ArrayBuffer = data.slice(0);
      writeChain = writeChain.then(async (): Promise<void> => {
        try {
          let done: number = 0;
          while (done < chunk.byteLength) {
            const rest: ArrayBuffer = done === 0 ? chunk : chunk.slice(done);
            const n: number = await fs.write(fd, rest, {
              offset: offset + done,
              length: rest.byteLength
            });
            if (n <= 0) {
              throw new Error(`write returned ${n}`);
            }
            done += n;
          }
        } catch (e) {
          writeFailed = true;
          fatalError = `写文件失败: ${JSON.stringify(e)}`;
        }
      });
      const pct: number = total > 0 ? Math.min(99, Math.floor(received * 100 / total)) : 0;
      publish(modelId, file.name, received, total, pct, true, '');
    } catch (e) {
      writeFailed = true;
      fatalError = `接收数据失败: ${JSON.stringify(e)}`;
    }
  });

  request.on('dataEnd', (): void => {
    dataEnded = true;
  });

  try {
    const opts: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: resumeFrom > 0 ? { Range: `bytes=${resumeFrom}-` } : {},
      connectTimeout: 15000,
      readTimeout: 60000
    };
    const code: number = await request.requestInStream(url, opts);
    console.info(`[AsrModel] response ${file.name} code=${code} resumeFrom=${resumeFrom}`);
    if (isTransientHttpCode(code)) {
      // 限流 / 网关波动：错误页 body 可能已排队写入 .part，先排干再截回本跳起点保护断点
      await writeChain;
      lastTransientCode = code;
      last429RetryAfterSec = retryAfterSec;
      try {
        await fs.truncate(fd, resumeFrom);
      } catch (e) {
        console.warn(`[AsrModelManager] rollback part failed: ${JSON.stringify(e)}`);
      }
      console.warn(`[AsrModel] transient ${code} ${file.name} retryAfter=${retryAfterSec}s`);
      return DL_RETRY_TRANSIENT;
    }
    if (code !== 200 && code !== 206) {
      fatalError = `HTTP ${code}`;
    }
    // 续传对齐守卫：重定向链上第一跳（3xx、无 Content-Range）会先把续传判成
    // 「服务端不认 Range」并排队 truncate、writeOffset 归零；若最终响应其实是
    // 206（服务端认了 Range，body 从 resumeFrom 开始），数据将整体错位写到
    // offset 0 —— .part 必坏且循环上演「续传 → 文件不完整 → 续传」。当场识别
    // 并弃掉 .part，下一轮全新下载即可自愈。（lastRangeStart === 0 除外：
    // body 本就从 0 开始，truncate 路径反而是对的）
    if (resumeFrom > 0 && !resumeOk && code === 206 && lastRangeStart !== 0) {
      try {
        fs.unlinkSync(partPath);
      } catch (e) {
        console.warn(`[AsrModelManager] drop misaligned part failed: ${JSON.stringify(e)}`);
      }
      publish(modelId, file.name, 0, file.size, 0, false, `续传响应异常（${file.name}），请重试`);
      return DL_FAIL;
    }
    // requestInStream 的 Promise 只代表响应头到达，必须等 dataEnd。
    // ⚠️ 判据是**空闲超时**（连续这么久一个字节都没来才算断），不是固定总时长：
    // 325MB 的模型在慢网下要跑几分钟，固定 30s 会把正常下载误判成「响应超时」。
    while (!dataEnded && fatalError.length === 0
      && Date.now() - lastDataAt < STREAM_IDLE_TIMEOUT_MS) {
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 50);
      });
    }
    if (!dataEnded && fatalError.length === 0) {
      fatalError = '连接空闲超时';
    }
    await writeChain;
    // 非 2xx 的错误页 body 同样会经 dataReceive 写进 .part —— 截回本跳起点，
    // 否则错误页字节污染断点，下轮「续传」从错误偏移开始、sha256 必失败
    if (code !== 200 && code !== 206 && !writeFailed) {
      try {
        await fs.truncate(fd, resumeFrom);
      } catch (e) {
        console.warn(`[AsrModelManager] rollback part failed: ${JSON.stringify(e)}`);
      }
    }
    if (writeFailed) {
      return DL_FAIL;
    }
    if (fatalError === 'cancelled') {
      // 取消保留 .part，下次可续传
      publish(modelId, file.name, received, total, 0, false, '已取消');
      return DL_FAIL;
    }
    if (fatalError.length > 0) {
      publish(modelId, file.name, received, total, 0, false, fatalError);
      return DL_FAIL;
    }
    // 校验：大小 + sha256
    const st: fs.Stat = fs.statSync(partPath);
    if (st.size !== file.size) {
      console.warn(`[AsrModel] size mismatch ${file.name} got=${st.size} want=${file.size}`);
      if (st.size > file.size) {
        // 过长残骸续传永远修不回（下一轮会走 >= 分支 sha 校验失败再清理），
        // 直接删掉省一次注定失败的「续传」点击；过短则保留给断点续传
        try {
          fs.unlinkSync(partPath);
        } catch (e) {
          console.warn(`[AsrModelManager] drop oversize part failed: ${JSON.stringify(e)}`);
        }
      }
      publish(modelId, file.name, st.size, file.size, 0, false, `文件不完整（${file.name}），请重试`);
      return DL_FAIL;
    }
    const actual: string = sha256File(partPath);
    if (actual !== file.sha256) {
      // ⚠️ 必须删掉这份 .part：内容是坏的，留着下次会「续传」到同一个坏结果，
      // 用户永远停在「校验失败」。长度对得上说明坏在中间，无法靠续传修。
      console.error(`[AsrModel] sha mismatch ${file.name} got=${actual} want=${file.sha256}`);
      try {
        fs.unlinkSync(partPath);
      } catch (e) {
        console.warn(`[AsrModelManager] drop bad part failed: ${JSON.stringify(e)}`);
      }
      publish(modelId, file.name, 0, file.size, 0, false, `文件校验失败（${file.name}），已清理，请重新下载`);
      return DL_FAIL;
    }
    // 单个文件通过校验：仍报 running=true，整个模型装完才由 downloadModel 收尾
    // （多文件模型中途把 running 置 false 会让行状态闪回「下载」）
    publish(modelId, file.name, file.size, file.size, 100, true, '');
    return DL_OK;
  } catch (e) {
    const be: BusinessError = e as BusinessError;
    fatalError = `下载失败: ${be.code ?? ''} ${be.message ?? ''}`;
    publish(modelId, file.name, received, total, 0, false, fatalError);
    return DL_FAIL;
  } finally {
    // 严格顺序：摘监听 → 等写链 → 关文件 → 销毁请求
    try {
      request.off('dataReceive');
      request.off('dataReceiveProgress');
      request.off('headersReceive');
      request.off('dataEnd');
    } catch (e) {
      // 忽略
    }
    try {
      await writeChain;
    } catch (e) {
      // 链内失败已记入 writeFailed
    }
    try {
      if (fd >= 0) {
        await fs.close(fd);
      }
    } catch (e) {
      console.warn(`[AsrModelManager] close fd failed: ${JSON.stringify(e)}`);
    }
    request.destroy();
  }
}

/** 删除一个已安装模型（同步清理目录 + manifest） */
export function deleteModel(modelId: string): boolean {
  const spec: AsrModelSpec | undefined = findModel(modelId);
  if (spec === undefined) {
    return false;
  }
  if (downloadRunning) {
    return false;
  }
  const dir: string = `${modelsDir}/${modelId}`;
  const tmpDir: string = `${modelsDir}/_tmp/${modelId}`;
  removeDirRecursively(dir);
  removeDirRecursively(tmpDir);
  delete manifest[modelId];
  saveManifest();
  return true;
}

/** 清理所有模型的临时下载残骸（设置页「清理缓存」可调用） */
export function clearModelTemp(): void {
  removeDirRecursively(`${modelsDir}/_tmp`);
}

/**
 * 清理「已下架模型」的落盘数据。
 *
 * 2026-11-20 清单收敛到单一模型（SenseVoice）后，老用户机器上会残留
 * whisper-small（358MB）、qwen3-asr-0.6b / telespeech 的半截 `.part`（可达 1GB）——
 * 不清理就白占空间，而且 `installedBytes()` 只统计在册模型，用户会在
 * 「已占用」里看不到这些字节的去向。启动后延迟执行，不阻塞首屏。
 */
export function pruneRetiredModels(): void {
  if (downloadRunning) {
    // 有下载在跑：等下次启动再清（不能删正在写的 .part）
    return;
  }
  try {
    if (!fs.accessSync(modelsDir)) {
      return;
    }
    let changed: boolean = false;
    const entries: string[] = fs.listFileSync(modelsDir, { recursion: false });
    for (let i = 0; i < entries.length; i++) {
      const name: string = entries[i];
      if (name === '_tmp' || name === 'manifest.json') {
        continue;
      }
      if (isKnownModel(name)) {
        continue;
      }
      console.info(`[AsrModel] prune retired model: ${name}`);
      removeDirRecursively(`${modelsDir}/${name}`);
      if (manifest[name] !== undefined) {
        delete manifest[name];
        changed = true;
      }
    }
    const tmpRoot: string = `${modelsDir}/_tmp`;
    if (fs.accessSync(tmpRoot)) {
      const tmps: string[] = fs.listFileSync(tmpRoot, { recursion: false });
      for (let i = 0; i < tmps.length; i++) {
        if (isKnownModel(tmps[i])) {
          continue;
        }
        console.info(`[AsrModel] prune retired temp: ${tmps[i]}`);
        removeDirRecursively(`${tmpRoot}/${tmps[i]}`);
      }
    }
    if (changed) {
      saveManifest();
    }
  } catch (e) {
    console.warn(`[AsrModelManager] prune retired failed: ${JSON.stringify(e)}`);
  }
}

/** 递归删目录：rmdirSync 只删空目录，须先逐个 unlink 文件 */
function removeDirRecursively(path: string): void {
  try {
    if (!fs.accessSync(path)) {
      return;
    }
    const entries: string[] = fs.listFileSync(path, { recursion: false });
    for (let i = 0; i < entries.length; i++) {
      const child: string = `${path}/${entries[i]}`;
      try {
        const st: fs.Stat = fs.statSync(child);
        if (st.isDirectory()) {
          removeDirRecursively(child);
        } else {
          fs.unlinkSync(child);
        }
      } catch (e) {
        console.warn(`[AsrModelManager] remove child failed: ${JSON.stringify(e)}`);
      }
    }
    fs.rmdirSync(path);
  } catch (e) {
    console.warn(`[AsrModelManager] remove dir failed: ${JSON.stringify(e)}`);
  }
}

/** 可中断等待：token 变化（用户取消/新任务）立即返回 true，等满返回 false */
async function sleepUnlessDownloadChanged(ms: number, token: number): Promise<boolean> {
  const deadline: number = Date.now() + ms;
  while (Date.now() < deadline) {
    if (token !== downloadToken) {
      return true;
    }
    const step: number = Math.min(200, deadline - Date.now());
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, step);
    });
  }
  return token !== downloadToken;
}

function publish(modelId: string, fileName: string, received: number, total: number,
  percent: number, running: boolean, error: string): void {
  const p: AsrDownloadProgress = {
    modelId: modelId,
    fileName: fileName,
    received: received,
    total: total,
    percent: percent,
    running: running,
    error: error
  };
  progressSink(p);
}
