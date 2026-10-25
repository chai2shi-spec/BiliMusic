/**
 * 播放器状态文件存储（双文件）。
 *
 * 为什么是文件而不是 Preferences：`@ohos.data.preferences` 单个 string value 有
 * 8192 字节硬上限，播放队列（每首 slimTrack 后 ~519 字节）塞不下几十首，
 * 旧的单键快照只能按字节预算把队列截到 ~10 首 —— 重启后播放列表大量丢失。
 * 文件没有这个上限，队列全量落盘（上限 MAX_PERSISTED_QUEUE_TRACKS 首，
 * 超出从头保留，整播万首歌单的场景仍会截断，属已知取舍）。
 *
 * 为什么拆两个文件：savePlayerStateNow 的挂点包含播放中的 5s 进度节流。
 * 万首队列整体序列化 ~5MB，若队列与标量同文件，每 5 秒就要全量序列化 +
 * 重写一次，是主线程的持续压力源。拆开后：
 *   · `player_state.json` —— 标量状态（当前曲目 / 进度 / 模式等，几百字节），
 *     每次 save 都写；
 *   · `player_queue.json` —— 队列本体，仅在队列变更（脏标置位）时写。
 *
 * 写入串行化：两次快速变更（连点加歌）的异步写必须按发起顺序落盘 ——
 * 两次写都以 TRUNC 打开同一文件，若先发起的写晚完成，会把新内容覆盖回
 * 旧内容。所有写经同一条 promise 链排队（模式同 MusicPlayer.playerRebuildChain）。
 *
 * 损坏即弃：读失败 / JSON 解析失败 / 字段不合法一律当无快照返回 null，
 * 绝不把脏数据甩进播放内核；两文件只认「同时存在」的组合，半份快照
 * （标量在、队列缺失）按无快照处理。
 */

import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { RepeatMode, Track } from '../model/MusicModels';

/** 标量状态（player_state.json）：每次 savePlayerStateNow 都重写，体量极小 */
export interface PersistedPlayerState {
  currentTrack: Track | null;
  currentIndex: number;
  progress: number;
  duration: number;
  repeatMode: RepeatMode;
  isShuffled: boolean;
  isPlaying: boolean;
  savedAt: number;
}

/** 队列本体（player_queue.json）：仅在队列变更时重写 */
export interface PersistedPlayerQueue {
  queue: Track[];
  savedAt: number;
}

const STATE_FILE: string = 'player_state.json';
const QUEUE_FILE: string = 'player_queue.json';

let stateDir: string = '';
/** 写入串行化链（见文件头说明） */
let writeChain: Promise<void> = Promise.resolve();

/** 初始化存储目录。AppContainer.initRest 调用，须先于 MusicPlayer.init。 */
export function initPlayerStateStore(context: common.Context): void {
  try {
    stateDir = `${context.filesDir}/player_state`;
    if (!fs.accessSync(stateDir)) {
      fs.mkdirSync(stateDir, true);
    }
  } catch (e) {
    console.error(`initPlayerStateStore failed: ${JSON.stringify(e)}`);
    stateDir = '';
  }
}

/** 读 JSON 文件：缺失 / 损坏 / 未初始化一律 null */
async function readJsonFile<T>(name: string): Promise<T | null> {
  if (stateDir.length === 0) {
    return null;
  }
  let raw: string = '';
  try {
    raw = await fs.readText(`${stateDir}/${name}`);
  } catch (e) {
    return null;
  }
  if (raw.length === 0) {
    return null;
  }
  try {
    return JSON.parse(raw) as T;
  } catch (e) {
    return null;
  }
}

/** 写 JSON 文件：open → write → close（鸿蒙 fileIo 没有 writeText） */
async function writeJsonText(name: string, json: string): Promise<void> {
  if (stateDir.length === 0) {
    return;
  }
  const file: fs.File = await fs.open(`${stateDir}/${name}`,
    fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    await fs.write(file.fd, json);
  } finally {
    await fs.close(file);
  }
}

/**
 * 把一次写入排进串行链。链尾吞掉错误：单次写失败不阻断后续写；
 * 调用方拿到当次写入的 Promise，可自行 catch 做补救（如置回脏标）。
 */
function enqueueWrite(name: string, json: string): Promise<void> {
  const run: Promise<void> = writeChain.then((): Promise<void> => writeJsonText(name, json));
  writeChain = run.then((): void => {
  }, (): void => {
  });
  return run;
}

/** 读标量状态（player_state.json），无 / 损坏 → null */
export function readPlayerStateFile(): Promise<PersistedPlayerState | null> {
  return readJsonFile<PersistedPlayerState>(STATE_FILE);
}

/** 读队列（player_queue.json），无 / 损坏 → null */
export function readPlayerQueueFile(): Promise<PersistedPlayerQueue | null> {
  return readJsonFile<PersistedPlayerQueue>(QUEUE_FILE);
}

/** 写标量状态（每次 save 都调用，体量几百字节） */
export function writePlayerStateFile(state: PersistedPlayerState): Promise<void> {
  return enqueueWrite(STATE_FILE, JSON.stringify(state));
}

/** 写队列（仅在队列变更时调用；调用方负责 slimTrack 与条数上限） */
export function writePlayerQueueFile(queue: Track[]): Promise<void> {
  const payload: PersistedPlayerQueue = { queue: queue, savedAt: Date.now() };
  return enqueueWrite(QUEUE_FILE, JSON.stringify(payload));
}
