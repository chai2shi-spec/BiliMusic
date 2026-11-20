/**
 * PCM 工具：把现有 decodeAudioToPcm 产出的 16kHz / 单声道 / s16le PCM
 * 转换成 sherpa_onnx 需要的 Float32Array（样本值 ∈ [-1,1]），
 * 并按固定时长切段、把 token 时间戳聚合成歌词行。
 */

import { AsrLine } from './AsrEngine';

/** 每秒 PCM 字节数：16000 样本 × 2 字节 */
export const PCM_BYTES_PER_SEC: number = 32000;

/** 每段时长（秒）：28s 留余量 —— sherpa 多数模型输入硬上限 30s，真机日志曾报
 *  「Only waves less than 30 seconds are supported…discard remaining」，留 2s
 *  余量避免段尾被截断丢词（2026-11-19 真机验证时发现）。 */
export const SEGMENT_SECONDS: number = 28;

/** 一段 PCM 数据（Float32 样本 + 在整曲中的起始秒） */
export interface PcmSegment {
  samples: Float32Array;
  startSec: number;
  endSec: number;
}

/**
 * s16le Uint8Array → Float32Array（÷32768）。
 * 注意 Uint8Array 到 Int16Array 的转换必须按小端序逐字节拼，
 * 不能直接 new Int16Array(buffer)（本机字节序不保证且对齐可能出问题）。
 */
export function pcmBytesToFloat(input: Uint8Array): Float32Array {
  const count: number = Math.floor(input.length / 2);
  const out: Float32Array = new Float32Array(count);
  for (let i = 0; i < count; i++) {
    const lo: number = input[i * 2];
    const hi: number = input[i * 2 + 1];
    let v: number = lo | (hi << 8);
    if (v >= 32768) {
      v -= 65536;
    }
    out[i] = v / 32768.0;
  }
  return out;
}

/** 按固定秒数切分 Float32 PCM，段尾不足 0.5s 的丢弃（避免尾部噪声） */
export function splitPcm(samples: Float32Array, segmentSeconds: number): PcmSegment[] {
  const perSegment: number = 16000 * segmentSeconds;
  const segments: PcmSegment[] = [];
  let offset: number = 0;
  while (offset < samples.length) {
    const len: number = Math.min(perSegment, samples.length - offset);
    if (len < 8000) {
      break;
    }
    const slice: Float32Array = samples.slice(offset, offset + len);
    segments.push({
      samples: slice,
      startSec: offset / 16000,
      endSec: (offset + len) / 16000
    });
    offset += len;
  }
  return segments;
}

/**
 * token → 歌词行聚合。
 * sherpa_onnx 的 result.timestamps 与 tokens 一一对应（单位需真机核实，推测秒）。
 * 相邻 token 间隔 > gapSec 或累计字符超 maxChars 断行；
 * 每行 time = 该行首 token 时间戳 + 段起点。
 */
export function tokensToLines(
  tokens: string[], timestamps: number[], segmentStartSec: number,
  gapSec: number, maxChars: number
): AsrLine[] {
  const lines: AsrLine[] = [];
  let buf: string = '';
  let lineStart: number = 0;
  let lastTs: number = -1;
  const count: number = Math.min(tokens.length, timestamps.length);
  for (let i = 0; i < count; i++) {
    const token: string = tokens[i];
    const ts: number = timestamps[i];
    if (token.length === 0) {
      continue;
    }
    const shouldBreak: boolean = buf.length > 0
      && (lastTs >= 0 && ts - lastTs > gapSec || buf.length >= maxChars);
    if (shouldBreak) {
      const text: string = buf.trim();
      if (text.length > 0) {
        lines.push({ time: segmentStartSec + lineStart, text: text });
      }
      buf = '';
      lineStart = ts;
    }
    if (buf.length === 0) {
      lineStart = ts;
    }
    buf += token;
    lastTs = ts;
  }
  const tail: string = buf.trim();
  if (tail.length > 0) {
    lines.push({ time: segmentStartSec + lineStart, text: tail });
  }
  return lines;
}

/** 无时间戳时的兜底：整段文本按字符数在 [start,end] 内均匀分布成 N 行 */
export function textToLinesEvenly(
  text: string, startSec: number, endSec: number, charsPerLine: number
): AsrLine[] {
  const clean: string = text.trim();
  if (clean.length === 0) {
    return [];
  }
  const lineCount: number = Math.max(1, Math.ceil(clean.length / charsPerLine));
  const step: number = clean.length / lineCount;
  const duration: number = Math.max(0.5, endSec - startSec);
  const lines: AsrLine[] = [];
  for (let i = 0; i < lineCount; i++) {
    const begin: number = Math.floor(i * step);
    const end: number = Math.floor((i + 1) * step);
    const part: string = clean.slice(begin, end).trim();
    if (part.length > 0) {
      lines.push({ time: startSec + duration * i / lineCount, text: part });
    }
  }
  return lines;
}

/** 从 PCM 文件一次性读入（4 分钟歌约 7.7MB，内存可接受） */
export function readPcmFile(path: string): Uint8Array {
  const file = fsOpenReadOnly(path);
  try {
    const size: number = fsStatSize(path);
    const buf: ArrayBuffer = new ArrayBuffer(size);
    let read: number = 0;
    while (read < size) {
      const n: number = fsReadSync(file, buf, read, size - read);
      if (n <= 0) {
        break;
      }
      read += n;
    }
    return new Uint8Array(buf, 0, read);
  } finally {
    fsCloseSync(file);
  }
}

// 下面几个包装函数把 fs API 收口，便于单测替换（ArkTS 不支持 any，故显式声明）
import fs from '@ohos.file.fs';

function fsOpenReadOnly(path: string): fs.File {
  return fs.openSync(path, fs.OpenMode.READ_ONLY);
}

function fsStatSize(path: string): number {
  return Number(fs.statSync(path).size);
}

function fsReadSync(file: fs.File, buf: ArrayBuffer, offset: number, length: number): number {
  return fs.readSync(file.fd, buf, { offset: offset, length: length });
}

function fsCloseSync(file: fs.File): void {
  fs.closeSync(file);
}
