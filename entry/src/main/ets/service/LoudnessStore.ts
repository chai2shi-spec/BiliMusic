/**
 * 响度均衡数据存储（文件型 KV）。
 *
 * 数据源：B 站 playurl 响应的 volume（服务端响度预测），解析音源时顺手记录
 * （MusicPlayer.mergeTrack / DownloadManager.runDownload 两个扼点）。
 * 键 = musicId（bvid / bvid#cid），与所有播放路径的 track.id 一致——
 * 在线 / 本地下载 / 本地优先 / 听后缓存重放共用一份记录。
 *
 * 为什么不用 Preferences：单值 8192 字节硬上限，2000 条 × ~30B 必超。
 * 为什么独立于 Track：响度按 id 查表即可绕开 Track 落盘纪律
 * （slimTrack / 分片预算），一处存储覆盖全部播放路径。
 *
 * 落盘形态是**数组**（[{id,m,t}]）而不是动态键对象：动态键 JSON 需要
 * Record + 下标访问的解析链路，数组 + 逐条 typeof 校验更直白也更稳。
 *
 * 全 IO try/catch 永不抛：响度是增强功能，绝不能成为播放链路的崩溃源。
 * 未 init（卡片进程等无主进程编排的场景）record 静默跳过、lookup 返回 null，
 * 无害降级为「该曲目不均衡」。
 */

import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';

/** 记录条目上限：超出按最旧淘汰（Map 迭代序 = 插入序；record 先删后插 = LRU recency） */
const MAX_ENTRIES: number = 2000;
/** 防抖落盘间隔：批量下载 / 连续解析时每条都落盘纯属浪费，合一次写 */
const FLUSH_DELAY_MS: number = 2000;

/** 落盘条目（m = 实测整合响度 LUFS，t = 目标响度 LUFS，0 = 缺失） */
interface StoredLoudness {
  id: string;
  m: number;
  t: number;
}

let storePath: string = '';
const entries: Map<string, StoredLoudness> = new Map<string, StoredLoudness>();
let flushTimer: number = -1;

/** 初始化：装载 loudness.json 进内存表。AppContainer.init 调用，同步执行（毫秒级）。 */
export function initLoudnessStore(context: common.Context): void {
  try {
    storePath = `${context.filesDir}/loudness.json`;
    if (fs.accessSync(storePath)) {
      const raw: string = fs.readTextSync(storePath);
      const parsed: StoredLoudness[] = JSON.parse(raw) as StoredLoudness[];
      // 损坏即弃：解析失败 / 非数组 / 字段不合法的条目逐条跳过，绝不把脏值带进查表
      if (Array.isArray(parsed)) {
        for (let i = 0; i < parsed.length; i++) {
          const item: StoredLoudness = parsed[i];
          if (typeof item?.id === 'string' && item.id.length > 0
            && typeof item.m === 'number' && Number.isFinite(item.m) && item.m !== 0) {
            entries.set(item.id, {
              id: item.id,
              m: item.m,
              t: typeof item.t === 'number' && Number.isFinite(item.t) ? item.t : 0
            });
          }
        }
      }
    }
  } catch (e) {
    console.error(`initLoudnessStore failed: ${JSON.stringify(e)}`);
    // 装载失败不致命：记录表从空开始，后续 record 照常累积（覆盖写会自愈）
  }
}

function persist(): void {
  if (storePath.length === 0) {
    return;
  }
  let file: fs.File | null = null;
  try {
    const list: StoredLoudness[] = [];
    entries.forEach((v: StoredLoudness): void => {
      list.push(v);
    });
    file = fs.openSync(storePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, JSON.stringify(list));
  } catch (e) {
    console.error(`persist loudness failed: ${JSON.stringify(e)}`);
  } finally {
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (closeErr) {
        console.error(`close loudness file failed: ${JSON.stringify(closeErr)}`);
      }
    }
  }
}

function scheduleFlush(): void {
  if (flushTimer !== -1) {
    return;
  }
  flushTimer = setTimeout((): void => {
    flushTimer = -1;
    persist();
  }, FLUSH_DELAY_MS);
}

/**
 * 记录一条响度数据。measuredI === 0 = 响应未携带响度（durl 降级 / 老视频），
 * 跳过不覆盖已有有效记录（同一曲目低音质档解析失败不该抹掉高音质档的旧值）。
 */
export function recordLoudness(musicId: string, measuredI: number, targetI: number): void {
  if (musicId.length === 0 || measuredI === 0 || !Number.isFinite(measuredI)
    || storePath.length === 0) {
    return;
  }
  // 先删后插：重插把条目挪到 Map 末尾，淘汰时从最旧（首键）开始
  entries.delete(musicId);
  entries.set(musicId, { id: musicId, m: measuredI, t: targetI });
  while (entries.size > MAX_ENTRIES) {
    let oldestKey: string = '';
    entries.forEach((v: StoredLoudness, k: string): void => {
      if (oldestKey.length === 0) {
        oldestKey = k;
      }
    });
    if (oldestKey.length === 0) {
      break;
    }
    entries.delete(oldestKey);
  }
  scheduleFlush();
}

/** 查询结果：m = 实测整合响度，t = 目标响度（0 = 缺失，应用侧兜 -14） */
export interface LoudnessLookup {
  m: number;
  t: number;
}

/** 按 musicId 查响度记录；无记录返回 null（内存读，不碰 IO） */
export function lookupLoudness(musicId: string): LoudnessLookup | null {
  if (musicId.length === 0) {
    return null;
  }
  const hit: StoredLoudness | undefined = entries.get(musicId);
  if (hit === undefined) {
    return null;
  }
  return { m: hit.m, t: hit.t };
}

/**
 * 响度均衡增益（忠实移植 BBPlayer calculateLoudnessGain）：
 * gain = clamp(10^((target - measured) / 20), 0, 1) —— **只衰减不放大**。
 * 响度偏大的歌被拉低到目标响度；偏小的歌保持原样（不放大，避免抬升底噪
 * 与潜在的削波风险）。measuredI 为 0 视为「无数据」，增益 1.0。
 */
export function calculateLoudnessGain(measuredI: number, targetI: number): number {
  if (measuredI === 0) {
    return 1.0;
  }
  const gainDb: number = targetI - measuredI;
  const linear: number = Math.pow(10, gainDb / 20);
  return Math.max(0, Math.min(1, linear));
}
