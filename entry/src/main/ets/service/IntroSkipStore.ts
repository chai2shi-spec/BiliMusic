/**
 * 按曲「限定播放进度」秒数存储（文件型 KV）。
 *
 * 数据源：播放页「限定播放进度」弹窗（ControlAreaComponent 的
 * 两条独立调整条 + 秒数输入框），每首歌各自记录两端的秒数：
 *   · s = 跳过片头秒数（起播点，0.1 粒度网格值 > 0；0 = 不跳过）
 *   · e = 跳过片尾秒数（从结尾倒数，0.1 粒度网格值 > 0；0 = 不限）
 * 键 = musicId（bvid / bvid#cid），与所有播放路径的 track.id 一致——
 * 在线 / 本地下载 / 队列 / 最近播放重放共用一份记录，重启不丢。
 *
 * 为什么不用 Preferences：单值 8192 字节硬上限，条目多时必超。
 * 为什么独立于 Track：限定秒数按 id 查表即可绕开 Track 落盘纪律
 * （slimTrack / 分片预算），一处存储覆盖全部播放路径。
 *
 * 落盘形态是**数组**（[{id,s,e}]）而不是动态键对象：动态键 JSON 需要
 * Record + 下标访问的解析链路，数组 + 逐条 typeof 校验更直白也更稳。
 * 旧版文件条目没有 e 字段：加载时逐字段 typeof 校验，e 不合法一律取 0
 * （双向兼容 —— 旧代码读新文件也会忽略 e）。s/e 为 0.1 网格值
 * （roundTenth 归一），旧版整数秒条目经 roundTenth 值不变，双向兼容。
 *
 * 全 IO try/catch 永不抛：限定播放进度是增强功能，绝不能成为播放链路的崩溃源。
 * 未 init（卡片进程等无主进程编排的场景）写入静默跳过、查询返回 0，
 * 无害降级为「该曲目不限定」。
 */

import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';

/** 记录条目上限：超出按最旧淘汰（Map 迭代序 = 插入序；写入先删后插 = LRU recency） */
const MAX_ENTRIES: number = 2000;
/** 防抖落盘间隔：连续设置多首时每条都落盘纯属浪费，合一次写 */
const FLUSH_DELAY_MS: number = 2000;

/**
 * 归一到 0.1 秒网格（读写共用）：既防滑条 / 输入框链路的浮点尾差
 * （0.30000…04）污染 JSON，也是「0.1s 精度」的统一收口。
 */
function roundTenth(v: number): number {
  return Math.round(v * 10) / 10;
}

/** 落盘条目（s = 跳过片头秒数；e = 跳过片尾秒数，均 0.1 网格值 > 0，0 = 不限） */
interface StoredSkipIntro {
  id: string;
  s: number;
  e: number;
}

let storePath: string = '';
const entries: Map<string, StoredSkipIntro> = new Map<string, StoredSkipIntro>();
let flushTimer: number = -1;

/** 初始化：装载 intro_skip.json 进内存表。AppContainer.init 调用，同步执行（毫秒级）。 */
export function initIntroSkipStore(context: common.Context): void {
  try {
    storePath = `${context.filesDir}/intro_skip.json`;
    if (fs.accessSync(storePath)) {
      const raw: string = fs.readTextSync(storePath);
      const parsed: StoredSkipIntro[] = JSON.parse(raw) as StoredSkipIntro[];
      // 损坏即弃：解析失败 / 非数组 / 字段不合法的条目逐条跳过，绝不把脏值带进查表
      if (Array.isArray(parsed)) {
        for (let i = 0; i < parsed.length; i++) {
          const item: StoredSkipIntro = parsed[i];
          if (typeof item?.id === 'string' && item.id.length > 0
            && typeof item.s === 'number' && Number.isFinite(item.s) && item.s > 0) {
            // 片尾秒数逐条校验：旧版条目没有 e 字段，不合法一律取 0（不限片尾）
            const tail: number = typeof item?.e === 'number' && Number.isFinite(item.e) && item.e > 0
              ? roundTenth(item.e)
              : 0;
            entries.set(item.id, {
              id: item.id,
              s: roundTenth(item.s),
              e: tail
            });
          }
        }
      }
    }
  } catch (e) {
    console.error(`initIntroSkipStore failed: ${JSON.stringify(e)}`);
    // 装载失败不致命：记录表从空开始，后续写入照常累积（覆盖写会自愈）
  }
}

function persist(): void {
  if (storePath.length === 0) {
    return;
  }
  let file: fs.File | null = null;
  try {
    const list: StoredSkipIntro[] = [];
    entries.forEach((v: StoredSkipIntro): void => {
      list.push(v);
    });
    file = fs.openSync(storePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, JSON.stringify(list));
  } catch (e) {
    console.error(`persist intro skip failed: ${JSON.stringify(e)}`);
  } finally {
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (closeErr) {
        console.error(`close intro skip file failed: ${JSON.stringify(closeErr)}`);
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
 * 设置一首歌的限定播放进度并防抖落盘。
 * startSec = 跳过片头秒数、outroSec = 跳过片尾秒数（均归一 0.1 网格）；
 * 两者均 <= 0（含非有限值）= 取消限定：删除该条目（无条目时幂等无操作）。
 * 未 init 静默跳过（卡片进程等场景，查表恒 0，无害降级）。
 */
export function setTrackSkipRange(musicId: string, startSec: number, outroSec: number): void {
  if (musicId.length === 0 || storePath.length === 0
    || !Number.isFinite(startSec) || !Number.isFinite(outroSec)) {
    return;
  }
  entries.delete(musicId);
  const head: number = roundTenth(startSec);
  const tail: number = roundTenth(outroSec);
  if (head > 0 || tail > 0) {
    // 先删后插：重插把条目挪到 Map 末尾，淘汰时从最旧（首键）开始
    entries.set(musicId, { id: musicId, s: head, e: tail });
    while (entries.size > MAX_ENTRIES) {
      let oldestKey: string = '';
      entries.forEach((v: StoredSkipIntro, k: string): void => {
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

/** 按 musicId 查跳过片头秒数；无记录返回 0（内存读，不碰 IO） */
export function skipIntroSecOf(musicId: string): number {
  if (musicId.length === 0) {
    return 0;
  }
  const hit: StoredSkipIntro | undefined = entries.get(musicId);
  if (hit === undefined) {
    return 0;
  }
  return hit.s;
}

/** 按 musicId 查跳过片尾秒数（从结尾倒数）；无记录返回 0（内存读，不碰 IO） */
export function skipOutroSecOf(musicId: string): number {
  if (musicId.length === 0) {
    return 0;
  }
  const hit: StoredSkipIntro | undefined = entries.get(musicId);
  if (hit === undefined) {
    return 0;
  }
  return hit.e;
}
