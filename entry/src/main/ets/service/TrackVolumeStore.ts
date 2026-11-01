/**
 * 按曲「单曲音量」增益存储（文件型 KV）。
 *
 * 数据源：播放页功能区「单曲音量」气泡滑条（VolumeChip），每首歌
 * 各自记录一个增益 dB 值 g（1dB 网格值，-30 ≤ g ≤ 30，g ≠ 0）：
 *   · g = 6   表示这首歌比原始音量响 6dB（放大由 MusicPlayer 经
 *     AVPlayer.setLoudnessGain 直接承担——setVolume 上限 1.00 做不了放大）
 *   · g = -10 表示这首歌比原始音量轻 10dB
 *   · 0 = 不调整 = 默认原始音量：删除该条目（无记录即默认）
 * 键 = musicId（bvid / bvid#cid），与所有播放路径的 track.id 一致——
 * 在线 / 本地下载 / 队列 / 最近播放重播共用一份记录，重启不丢。
 *
 * 为什么不用 Preferences：单值 8192 字节硬上限，条目多时必超。
 * 落盘形态是**数组**（[{id,g}]）而不是动态键对象：动态键 JSON 需要
 * Record + 下标访问的解析链路，数组 + 逐条 typeof 校验更直白也更稳。
 *
 * 与播放链路的合流点在 MusicPlayer：
 *   增益 dB 域走 setLoudnessGain；仅当该通路会话级降级（个别音源报错）
 *   且 g < 0 时，才由 effectiveVolume() 经 setVolume 兜底衰减。
 *
 * 全 IO try/catch 永不抛：单曲音量是增强功能，绝不能成为播放链路的崩溃源。
 * 未 init（卡片进程等无主进程编排的场景）写入静默跳过、查询返回 0，
 * 无害降级为「该曲目不调音量」。
 */

import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';

/** 记录条目上限：超出按最旧淘汰（Map 迭代序 = 插入序；写入先删后插 = LRU recency） */
const MAX_ENTRIES: number = 2000;
/** 防抖落盘间隔：滑条拖动只存终值，合一次写 */
const FLUSH_DELAY_MS: number = 2000;
/** 增益绝对值上限（dB）：与 VolumeChip 滑条 min/max 一致（+30dB = 30 倍响，-30dB = 1/30；正增益超 setLoudnessGain API 上限 +24dB 的部分由 MusicPlayer 应用层钳制生效） */
const MAX_GAIN_DB: number = 30;

/**
 * 归一到 1dB 网格（读写共用）：既防滑条链路的浮点尾差
 * （6.000…02）污染 JSON，也是「1dB 步进」的统一收口。
 */
function roundDb1(v: number): number {
  return Math.round(v);
}

/** 落盘条目（g = 增益 dB，1dB 网格值，-30 ≤ g ≤ 30 且 g ≠ 0） */
interface StoredTrackVolume {
  id: string;
  g: number;
}

let storePath: string = '';
const entries: Map<string, StoredTrackVolume> = new Map<string, StoredTrackVolume>();
let flushTimer: number = -1;

/** 初始化：装载 track_volume.json 进内存表。AppContainer.init 调用，同步执行（毫秒级）。 */
export function initTrackVolumeStore(context: common.Context): void {
  try {
    storePath = `${context.filesDir}/track_volume.json`;
    if (fs.accessSync(storePath)) {
      const raw: string = fs.readTextSync(storePath);
      const parsed: StoredTrackVolume[] = JSON.parse(raw) as StoredTrackVolume[];
      // 损坏即弃：解析失败 / 非数组 / 字段不合法的条目逐条跳过，绝不把脏值带进查表
      if (Array.isArray(parsed)) {
        for (let i = 0; i < parsed.length; i++) {
          const item: StoredTrackVolume = parsed[i];
          if (typeof item?.id === 'string' && item.id.length > 0
            && typeof item.g === 'number' && Number.isFinite(item.g)
            && item.g !== 0 && Math.abs(item.g) <= MAX_GAIN_DB) {
            entries.set(item.id, {
              id: item.id,
              g: roundDb1(item.g)
            });
          }
        }
      }
    }
  } catch (e) {
    console.error(`initTrackVolumeStore failed: ${JSON.stringify(e)}`);
    // 装载失败不致命：记录表从空开始，后续写入照常累积（覆盖写会自愈）
  }
}

function persist(): void {
  if (storePath.length === 0) {
    return;
  }
  let file: fs.File | null = null;
  try {
    const list: StoredTrackVolume[] = [];
    entries.forEach((v: StoredTrackVolume): void => {
      list.push(v);
    });
    file = fs.openSync(storePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, JSON.stringify(list));
  } catch (e) {
    console.error(`persist track volume failed: ${JSON.stringify(e)}`);
  } finally {
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (closeErr) {
        console.error(`close track volume file failed: ${JSON.stringify(closeErr)}`);
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
 * 设置一首歌的单曲音量增益（dB）并防抖落盘。
 * gainDb 钳到 ±30 后归一 1dB 网格；归零（含非有限值）= 恢复默认：
 * 删除该条目（无条目时幂等无操作）。未 init 静默跳过
 * （卡片进程等场景，查表恒 0，无害降级）。
 */
export function setTrackVolumeRecord(musicId: string, gainDb: number): void {
  if (musicId.length === 0 || storePath.length === 0 || !Number.isFinite(gainDb)) {
    return;
  }
  entries.delete(musicId);
  const g: number = roundDb1(Math.min(MAX_GAIN_DB, Math.max(-MAX_GAIN_DB, gainDb)));
  if (g !== 0) {
    // 先删后插：重插把条目挪到 Map 末尾，淘汰时从最旧（首键）开始
    entries.set(musicId, { id: musicId, g: g });
    while (entries.size > MAX_ENTRIES) {
      let oldestKey: string = '';
      entries.forEach((val: StoredTrackVolume, k: string): void => {
        if (oldestKey.length === 0) {
          oldestKey = k;
        }
      });
      if (oldestKey.length === 0) {
        break;
      }
      entries.delete(oldestKey);
    }
  }
  scheduleFlush();
}

/** 按 musicId 查单曲音量增益（dB）；无记录返回 0 = 默认原始音量（内存读，不碰 IO） */
export function trackVolumeGainOf(musicId: string): number {
  if (musicId.length === 0) {
    return 0;
  }
  const hit: StoredTrackVolume | undefined = entries.get(musicId);
  if (hit === undefined) {
    return 0;
  }
  return hit.g;
}
