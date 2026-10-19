/**
 * 下载管理（原生 ArkTS 版）。
 * 将 B 站音频流落地到应用沙箱 filesDir/downloads，进度写回 RDB（MusicDao）。
 * 音源解析复用 BilibiliApi.extractAudioFromVideo（与播放一致）。
 *
 * 数据流：本类持有**内存态**任务表，任何进度/状态变化都会重新生成快照并写入
 * AppStorage(STORE_DOWNLOAD_TASKS)，下载页用 @StorageLink 订阅即可实时刷新。
 *
 * 早期实现只在写库后等页面重查，而页面只在 aboutToAppear 拉一次数据，
 * 结果就是「点了下载看不到进度、重启应用才出现」。故改为推送式。
 *
 * ══════════ 三条容易改坏的设计（改之前先读） ══════════
 *
 * ① **分 P 拆成多个任务 + 串行队列**（`requestDownload` → `pump` → `runDownload`）。
 *    多 P 合集（B 站音乐的「50 首精选」这类）点一次下载会展开成 N 个**独立任务**：
 *    先一次性把 N 条记录都建好并推送 UI（用户立刻看到「排队中…」的 N 行，知道都排上了），
 *    再**一个一个串行**下载。不并发的原因：并发会把连接池和带宽切碎，速度读数与实际耗时都变差，
 *    而且每个任务的 `dataEnd` 边界在弱网下更容易超时。
 *    队列元素同时持有 `Track`（音源解析要 bvid/cid），**进程内传递、不落库** ——
 *    download_task 表没有这三列，也不需要：进程被杀后所有 PENDING 都会被 loadFromDb
 *    标成「已中断」，没有「重启接着下」的语义。
 *
 * ② **实时速度只在内存里算**（`downloadFile` 里按 1s 窗口取增量）。
 *    `DownloadTask.speed` 不落库：速度是瞬时量，重启后残留一个旧读数比显示 0 更误导。
 *    长时间没有新字节时**必须把它归零**，否则界面上会一直挂着一句「1.2 MB/s」骗人。
 *
 * ③ **仅 WiFi 下载开关**（`requestDownload` 开头的闸门）。
 *    开启且当前是蜂窝网络 → **不下载**，返回 `blockedReason` 让 UI 去问用户；
 *    用户选「继续下载」再带 `ignoreWifiLimit = true` 进来重试。
 *    闸门放在**请求入口**而不是每个任务里：一个合集点了「继续」就不该再逐条问第二遍。
 *
 * ④ **暂停/恢复是「会话内」能力**（`pauseAll` / `resumeAll`）。
 *    暂停 = 置 `paused` 标志（消费者退出）+ 把**正在下载的那一条中止**。
 *    中止时**不删半截文件**，任务标 PAUSED 并保留 `downloadedBytes`；
 *    恢复时重新排队、带上 `Range: bytes=<已下载>-` 续传（见 `downloadFile`）。
 *    还有两个刻意的约束：
 *      a. 队列里未开始的任务**不清理、不换状态**，只是不再被消费 —— 它们是内存对象，
 *         带着完整的 `Track`（含 bvid/aid/cid），清掉就再也拼不回来（音乐中心条目的
 *         musicId 是音乐 id 而非 bvid，光靠落库字段无法重新解析音源）。
 *      b. 因此**暂停状态跨不过进程重启**：重启后队列本就丢了，PAUSED 记录只能靠
 *         `trackFromTask` 尽力重建（能重建 BV 号就行，音乐中心那种会失败并提示重下）。
 *         这不是缺陷，是「队列不落库」这条既有设计的边界。
 *
 * ⑤ **多选批量删除**（`removeTasks`）。逐条调 `removeTask` 会推 N 次 UI 快照，
 *    批量走一次性删除 + 一次 notify。
 *
 * ⑥ **失败自动重试 + 断点续传重试**（`runDownload` 的 attempt 循环）。
 *    单次失败不再直接判死：同一任务最多试 DOWNLOAD_MAX_ATTEMPTS 次，每次都
 *    **重新解析音源**（直链过期 / 被限流是最高频的失败原因，重拿一次 URL 就能救回来），
 *    两次尝试之间按 attempt × RETRY_BASE_DELAY_MS 退避（网络抖动多是瞬时的，
 *    立刻重试只会再撞一次）。等待可被「全部暂停」打断（打断即按暂停收尾，半截文件保留）。
 *    配套地，`downloadFile` 对**停滞 / 网络中断**保留半截文件（字节全部来自已通过
 *    200/206 校验的响应，续传安全），重试时走 Range 续传，弱网下不浪费已下载的流量。
 */

import http from '@ohos.net.http';
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { extractAudioFromVideo, expandVideoParts } from '../api/BilibiliApi';
import {
  insertDownload,
  getAllDownloads,
  deleteDownload,
  getDownloadByMusicId,
  updateDownloadProgress,
  updateDownloadStatus
} from '../database/MusicDao';
import { DownloadTask, DownloadStatus, Track, buildTrack, downloadQualityId } from '../model/MusicModels';
import { BILI_REFERER, STORE_DOWNLOAD_PAUSED, STORE_DOWNLOAD_TASKS } from '../common/Constants';
import { HttpUtil } from '../utils/HttpUtil';
import { AppPreferences } from '../preferences/AppPreferences';
import { isUnmeteredNetwork } from '../utils/NetworkUtil';
import { BackgroundPlayback } from './BackgroundPlayback';

/**
 * UI 刷新节流：dataReceiveProgress 触发极频繁，无需每次都重绘。
 * 2026-10-08 卡顿优化：200 → 300。每份快照都会触发下载页的全量重分组
 * （rebuildGroups）+ 镜像动画重定目标，200ms（5Hz）在多 P 合集下载时
 * 与滚动帧竞争主线程。300ms（3.3Hz）脉冲开销降 40%，进度数字步进
 * 略粗但人眼无感；配套把动画窗口 DOWNLOAD_SMOOTH_MS 提到 250ms 保连续。
 */
const UI_NOTIFY_INTERVAL: number = 300;
/** 落库节流：避免每个数据分片都写一次 RDB */
const DB_WRITE_INTERVAL: number = 800;
/**
 * 流式接收的「停滞」判据（ms）。
 *
 * 不能用「从开始算起的固定总超时」：一首 10MB 的音频在弱网下可能下几分钟，
 * 固定 10s 会把正常下载误判为失败。这里改成**空闲超时** —— 只要有数据推进就刷新，
 * 连续这么久一个字节都没来，才认定是真的断了。
 */
const STREAM_IDLE_TIMEOUT_MS: number = 30000;
const STREAM_POLL_INTERVAL_MS: number = 20;
/** 判定「这是个有效音频文件」的最小体积：小于它就是错误页 / 空响应的残骸 */
const MIN_VALID_AUDIO_BYTES: number = 1024;

/**
 * 「因用户主动暂停而中止」的哨兵错误消息。
 *
 * 为什么用字符串当哨兵而不是自定义错误类：`downloadFile` 的失败路径要**删掉半截文件**，
 * 唯独暂停这条路径必须**保留**（否则 Range 续传无从谈起）。用一个几乎不可能与真实
 * 网络错误撞车的字符串来区分，比加一层错误类型再层层 instanceof 更直白。
 */
const PAUSE_SENTINEL: string = '__bilimusic_download_paused__';

/**
 * 速度采样窗口（ms）。取 1s 的增量而不是「每次进度回调都算」：
 * TCP 分片到达是脉冲式的，逐回调计算会让读数在 0 和 5MB/s 之间反复横跳。
 */
const SPEED_SAMPLE_WINDOW_MS: number = 1000;
/**
 * 速度归零判据（ms）：连续这么久没有任何新字节，就把速度显示成 0。
 * 不做这一步，断流后界面会一直挂着最后那次读数（看起来还在飞快下载）。
 */
const SPEED_STALE_MS: number = 2500;

/**
 * ══════════ 失败自动重试（提升下载成功率）══════════
 *
 * 直链过期 / 被限流（403 + 错误页）、网络抖动、断流停滞这类失败是**瞬时性**的，
 * 重拿一次 URL 或隔几秒再试就能成功。单个任务最多试 DOWNLOAD_MAX_ATTEMPTS 次，
 * 每次重新解析音源（见 runDownload 的 attempt 循环）。
 */
/** 单个任务的最大尝试次数（首次 + 2 次重试） */
const DOWNLOAD_MAX_ATTEMPTS: number = 3;
/** 重试退避基值（ms）：第 n 次重试前等 n × 基值，给限流/抖动留恢复窗口 */
const RETRY_BASE_DELAY_MS: number = 2000;
/** 退避等待期间的轮询间隔（ms）：为了能及时响应「全部暂停」） */
const RETRY_WAIT_POLL_MS: number = 100;

/**
 * 「仅 WiFi 下载」被触发时给 UI 的固定文案。
 * UI 拿它做判断（非空 = 需要询问用户），所以改文案时记得同步 SearchPage。
 */
export const WIFI_ONLY_BLOCKED: string =
  '当前为移动网络，「仅 WiFi 下载」已开启。继续下载会消耗流量。';

/**
 * 下载来源（可选）：整单下载时由调用方传入，任务会带上这两个字段，
 * 下载管理页据此把同一歌单的曲目**聚成一张歌单卡片**（展开才见单曲）。
 * 单曲下载不传 → `playlistId` 为空串 → 行为与从前完全一致。
 *
 * 2026-10-08 扩展：合集归属三件套（可选项）。多 P 展开入队时由 requestDownload
 * 逐条标记（原视频标题 + 分 P 序号 + 总 P 数），让下载页能显式区分「合集条目」
 * 与单视频条目，不再依赖「首个分P复用 base 标题」的隐式约定。
 */
export interface DownloadSource {
  playlistId: string;
  playlistName: string;
  /** 合集标题（展开前的原视频标题）；单视频不填 */
  collectionTitle?: string;
  /** 分 P 序号（1 起）；单视频不填（0） */
  partNo?: number;
  /** 分 P 总数；单视频不填（0） */
  partTotal?: number;
}

/**
 * 一次下载请求的结果。
 *
 * 分 P 之后「成功/失败」不再是布尔能表达的：一次点击可能排上 7 首、跳过 2 首、或被整体拦下。
 */
export interface DownloadStartResult {
  /** 本次真正排上队的任务数（含展开出来的各个分 P） */
  queued: number;
  /** 因已在下载中 / 已下载完成而跳过的条数 */
  skipped: number;
  /** 非空 = 整体被拦下（目前只有「仅 WiFi 下载」），UI 应询问用户后带 ignoreWifiLimit 重试 */
  blockedReason: string;
}

/**
 * 队列元素：任务记录 + 音源解析所需的曲目信息。
 *
 * `track` 只在进程内传递，不落库 —— 解析音源要 bvid/aid/cid，而 download_task 表
 * 只有 `musicId` 一列，装不下。进程被杀后 PENDING 会被 loadFromDb 标成「已中断」，
 * 本来也没有「重启接着下」的语义，所以不需要把它们持久化。
 */
interface QueuedDownload {
  task: DownloadTask;
  track: Track;
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

/**
 * 把异常转成可读文本。
 * `JSON.stringify(err)` 对 Error 实例只会打印 `{}`（message/stack 都是不可枚举属性），
 * 之前所有下载失败的日志都是这么变成废话的。
 */
function describeError(e: Object): string {
  if (e instanceof Error) {
    return `${e.name}: ${e.message}`;
  }
  return JSON.stringify(e);
}

/**
 * 校验落盘文件是不是**真的音频**。
 *
 * 为什么必须有这一步：B 站音频 CDN 在直链过期 / 被限流时，会返回 **HTTP 200 + 一段 HTML
 * 或 JSON 错误页**。此时下载流程「顺利」走完，文件也是一段合法字节，只是永远播不出来。
 * DASH 音频是 fMP4 容器，前 12 字节里第 4~7 字节恒为 ASCII `ftyp`，用它做魔数校验。
 */
async function isValidAudioFile(path: string): Promise<boolean> {
  // （2026-10-16 AppFreeze 加固）探测改异步 fs：不再在主线程 statSync/openSync/readSync。
  let probe: fs.File | null = null;
  try {
    const stat: fs.Stat = await fs.stat(path);
    if (stat.size < MIN_VALID_AUDIO_BYTES) {
      return false;
    }
    probe = await fs.open(path, fs.OpenMode.READ_ONLY);
    const buf: ArrayBuffer = new ArrayBuffer(12);
    await fs.read(probe.fd, buf);
    const bytes: Uint8Array = new Uint8Array(buf);
    const tag: string = String.fromCharCode(bytes[4], bytes[5], bytes[6], bytes[7]);
    return tag === 'ftyp';
  } catch (e) {
    return false;
  } finally {
    if (probe !== null) {
      try {
        await fs.close(probe.fd);
      } catch (e) {
        // 关闭失败不影响校验结果
      }
    }
  }
}

/**
 * 从 `Content-Range: bytes 1024-2047/4096` 里取出区间起始字节。
 *
 * 解析不出来（响应头没有该字段 / 服务端直接忽略了 Range 返回 200 全量 /
 * 返回的是别的区间）一律返回 -1，调用方据此判定「这次不能续传，得从头写」。
 * 这个「宁可重下、也不拼错」的方向是刻意的：续传写错位置会产出一个**能播但内容是错的**
 * 文件，比多下一遍难查得多。
 */
function contentRangeStart(value: string): number {
  const tag: number = value.indexOf('bytes ');
  if (tag < 0) {
    return -1;
  }
  const from: number = tag + 6;
  const dash: number = value.indexOf('-', from);
  if (dash <= from) {
    return -1;
  }
  const n: number = Number(value.substring(from, dash));
  return Number.isFinite(n) ? n : -1;
}

export class DownloadManager {
  private static instance: DownloadManager | null = null;
  private context: common.Context | null = null;

  private readonly tasks: Map<string, DownloadTask> = new Map<string, DownloadTask>();
  /**
   * 已被用户删除的任务 id。下载是长流程，用户随时可能在下载页把它删掉；
   * 没有这个集合，请求会继续跑到底（白耗流量），而且中途写回的状态会把已删除的记录
   * 又更新一遍。等待循环里每轮查一次，命中就主动中止并清掉半截文件。
   */
  private readonly cancelled: Set<string> = new Set<string>();
  /**
   * 待下载队列（分 P 展开后一次可能排入十几条）。**串行**消费：
   * 并发下载会把带宽和 HTTP 连接池切碎，进度和速度读数都会变得不可信。
   */
  private readonly queue: QueuedDownload[] = [];
  /** 队列消费者是否在跑。防止 requestDownload 重入启动第二个消费者（同一条会被下两次） */
  private pumping: boolean = false;
  /**
   * 暂停开关。「全部暂停」把它置 true：消费者退出、当前传输中止、不再取新任务；
   * 「全部开始」置回 false 并重新拉起消费者。
   *
   * 注意「正在下载的那一条」不需要额外字段去记 —— 它被中止时会把**自己**放回队首
   * （见 runDownload），因为只有它自己才握着那份带 Track 的队列元素。
   */
  private paused: boolean = false;
  /**
   * **单条暂停**的任务集合（2026-10-11 新增：下载页点「下载中」的行 = 只暂停这一条）。
   *
   * 与 `paused`（全部暂停）的分工：
   *   · `paused` 是队列级总闸，消费者整体退出；
   *   · 本集合是「这一条别跑」的标记 —— 正在传输的那条在下个轮询点抛哨兵
   *     （与全部暂停同一条收尾路径：保留半截文件 + 标 PAUSED + 放回队首），
   *     还没开工的条目由 `shiftRunnable` 跳过（条目**留在队列里**，Track 不丢）。
   * 恢复（`resumeTask` / `resumeAll`）时把 id 摘掉即可。
   */
  private pausedIds: Set<string> = new Set<string>();
  private loaded: boolean = false;
  private loadingPromise: Promise<void> | null = null;

  static getInstance(): DownloadManager {
    if (!DownloadManager.instance) {
      DownloadManager.instance = new DownloadManager();
    }
    return DownloadManager.instance;
  }

  init(context: common.Context): void {
    this.context = context;
  }

  /** 首次访问时把库里的历史任务载入内存；并发调用共用一个 Promise。 */
  async ensureLoaded(): Promise<void> {
    if (this.loaded) {
      return;
    }
    if (this.loadingPromise) {
      await this.loadingPromise;
      return;
    }
    this.loadingPromise = this.loadFromDb();
    await this.loadingPromise;
  }

  /**
   * 同步查询「该曲目是否已下载完成」（2026-10-08 本地优先播放）：
   * 命中返回本地文件路径，否则空串。
   *
   * 供播放内核做「本地优先」判定（MusicPlayer.loadAndPlay 在线解析之前先问这里）：
   *  · 走**内存任务表**而不是 RDB —— loadAndPlay 处在切歌主路径上，不能等异步 IO；
   *    AppContainer 启动链已 ensureLoaded 装填（见 AppContainer.init），之后内存表
   *    与库由本类统一维护，始终同步。
   *  · O(N) 扫描只在每次切歌时发生一次（N = 历史任务数，百量级），开销可忽略。
   *  · 极端时序（表尚未载完，如启动瞬间立刻恢复播放）返回空串 → 播放器回落在线流，
   *    行为无害；下一首歌起本地优先即生效。
   *  · musicId 精确匹配：多 P 首 P 任务 = 纯 bvid、其余 = `bvid#cid`，与
   *    requestDownload 的去重键（getDownloadByMusicId）同一语义，不会把
   *    「整合集已下载」误判成「每个分 P 都已下载」。
   */
  completedLocalPath(musicId: string): string {
    let found: string = '';
    this.tasks.forEach((t: DownloadTask): void => {
      if (found.length === 0 && t.musicId === musicId
        && t.status === DownloadStatus.COMPLETED && t.localFilePath.length > 0) {
        found = t.localFilePath;
      }
    });
    return found;
  }

  private async loadFromDb(): Promise<void> {
    try {
      const list: DownloadTask[] = await getAllDownloads();
      this.tasks.clear();
      for (const t of list) {
        if (t.status === DownloadStatus.DOWNLOADING || t.status === DownloadStatus.PENDING) {
          // 上次进程被杀留下的中间态，文件多半不完整，标为失败以免永远停在“下载中”。
          // 半截文件一并删掉：既占沙箱空间，又可能被误当成可播的本地缓存。
          if (t.localFilePath.length > 0) {
            // （2026-10-16 AppFreeze 加固）删半截文件改异步，不阻塞主线程
            fs.unlink(t.localFilePath).catch((): void => {
              // 文件可能不存在，忽略
            });
          }
          await updateDownloadStatus(t.id, DownloadStatus.ERROR);
          t.status = DownloadStatus.ERROR;
          t.errorMessage = '下载已中断（重新下载即可）';
        }
        this.tasks.set(t.id, t);
      }
      this.loaded = true;
      this.notify();
    } catch (e) {
      console.error(`load downloads failed: ${describeError(e)}`);
    }
  }

  /**
   * 生成新数组 + 新对象副本并推送：保证 @StorageLink / ForEach 能感知到每项变化。
   *
   * 整体包 try/catch：本方法会被 http 的 dataReceiveProgress 回调调用（每 200ms 一次），
   * 一旦在这里抛出未捕获异常，异常发生在**事件回调**里而不是 Promise 链上，
   * 不会被任何 .catch() 接住 —— 主线程未捕获异常会直接把应用干掉（用户看到的就是「闪退」）。
   * 推送 UI 只是附带效果，绝不能让它成为崩溃源。
   */
  private notify(): void {
    try {
      const snapshot: DownloadTask[] = [];
      this.tasks.forEach((t: DownloadTask): void => {
        snapshot.push(this.copy(t));
      });
      snapshot.sort((a: DownloadTask, b: DownloadTask): number => b.createdAt - a.createdAt);
      AppStorage.setOrCreate(STORE_DOWNLOAD_TASKS, snapshot);
    } catch (e) {
      console.error(`notify downloads failed: ${describeError(e)}`);
    }
  }

  private copy(t: DownloadTask): DownloadTask {
    return {
      id: t.id,
      musicId: t.musicId,
      title: t.title,
      artist: t.artist,
      coverUrl: t.coverUrl,
      url: t.url,
      totalBytes: t.totalBytes,
      downloadedBytes: t.downloadedBytes,
      // 速度是内存态：从库里读回来的任务没有读数，统一归 0（界面据此不显示速度）
      speed: t.speed > 0 ? t.speed : 0,
      // 同理：音质档位与实测带宽也不落库，读回来的任务给 0（界面不显示码率）
      audioQuality: t.audioQuality > 0 ? t.audioQuality : 0,
      audioBandwidth: t.audioBandwidth > 0 ? t.audioBandwidth : 0,
      status: t.status,
      errorMessage: t.errorMessage,
      createdAt: t.createdAt,
      completedAt: t.completedAt,
      localFilePath: t.localFilePath,
      // 来源歌单要跟着复制过去：否则 UI 快照里丢失分组信息，
      // 详情页 / 下载页的分组键会退化成任务 id（表现为「整单下载又散成一行行」）
      playlistId: t.playlistId ?? '',
      playlistName: t.playlistName ?? '',
      // 合集三件套同理（2026-10-08）：漏掉的话 UI 快照里的任务全变成「单视频」，
      // 合集徽标 / P 序号会消失（就是上面 playlistId 踩过的同一类坑）
      collectionTitle: t.collectionTitle ?? '',
      partNo: t.partNo ?? 0,
      partTotal: t.partTotal ?? 0
    };
  }

  /**
   * 下载入口。多 P 合集会被**展开成多个独立任务**，一起排队、再串行下载。
   *
   * @param ignoreWifiLimit 用户在「仅 WiFi 下载」的询问里选了「继续下载」时传 true 重入。
   */
  async requestDownload(
    track: Track,
    ignoreWifiLimit: boolean = false,
    source?: DownloadSource
  ): Promise<DownloadStartResult> {
    const result: DownloadStartResult = { queued: 0, skipped: 0, blockedReason: '' };
    if (!this.context) {
      console.error('DownloadManager not initialized');
      return result;
    }
    await this.ensureLoaded();

    // 用户在搜索页点「下载」＝明确想要下载，顺手解除「全部暂停」。
    // 不解除的话，暂停期间新加的任务会排上队却永远不动，看起来像「点了没反应」。
    this.paused = false;
    this.publishPaused();

    // 闸门①：仅 WiFi 下载。放在**请求入口**而不是每个任务里 ——
    // 一个合集用户点一次「继续下载」就够了，不该再逐条问第二遍、第三遍。
    if (!ignoreWifiLimit && this.isWifiOnlyBlocked()) {
      result.blockedReason = WIFI_ONLY_BLOCKED;
      return result;
    }

    const all: Track[] = await this.resolveDownloadTracks(track);

    for (let i = 0; i < all.length; i++) {
      const t: Track = all[i];
      const existing: DownloadTask | null = await getDownloadByMusicId(t.id);
      if (existing) {
        const busy: boolean = existing.status === DownloadStatus.DOWNLOADING
          || existing.status === DownloadStatus.PENDING
          || existing.status === DownloadStatus.COMPLETED;
        if (busy) {
          result.skipped += 1;
          continue;
        }
        // 失败 / 中断的残留记录：清掉重来，否则旧行会被新任务的进度反复改写成错的状态
        await deleteDownload(existing.id);
        this.tasks.delete(existing.id);
      }
      // 合集归属标记（2026-10-08）：展开出多条（= 真·多 P 合集）时，
      // 逐条打上「原视频标题 + 第几个分 P + 共几个」，下载页据此显示合集徽标与 P 序号；
      // 单条（单 P 视频或展开失败回落）不打标——partNo/partTotal 保持 0，UI 视作单视频。
      // partNo 用展开列表的原始下标：即使某些分 P 因已下载被跳过，序号依然对应 B 站分 P 顺序。
      // 歌单整单下载与合集标记可叠加（playlistId 照传，互不冲突）。
      const withParts: boolean = all.length > 1;
      const merged: DownloadSource = {
        playlistId: source ? source.playlistId : '',
        playlistName: source ? source.playlistName : '',
        collectionTitle: withParts ? track.title : '',
        partNo: withParts ? i + 1 : 0,
        partTotal: withParts ? all.length : 0
      };
      const created: DownloadTask | null = await this.createPendingTask(t, merged);
      if (created) {
        this.queue.push({ task: created, track: t });
        result.queued += 1;
      }
    }

    if (result.queued > 0) {
      // 立刻把全部任务推给 UI：用户看到的是「排队中…」的 N 行（知道都排上了），
      // 而不是下完一条才冒出一条 —— 后者会让人以为只下载了一首。
      this.notify();
      this.pump();
    }
    return result;
  }

  /**
   * 算出这个条目要下载哪些曲目：多 P 合集展开成 N 条，单 P 就是它自己。
   *
   * 展开失败**不影响下载本条**：多 P 展开只是「顺带把同合集的分 P 也下了」，
   * 不是下载的前置条件；为了它把整次下载判死是本末倒置。
   *
   * 代价：每次下载请求会多一次 `view` 请求（展开要读 pages）。一次请求换「合集点一下全下」，
   * 相比用户手动点 12 次各 2 次请求，净开销只有 +1 次，划算。
   */
  private async resolveDownloadTracks(track: Track): Promise<Track[]> {
    const bvid: string = this.bvidOf(track);
    if (bvid.indexOf('BV') !== 0) {
      return [track];
    }
    try {
      const parts: Track[] = await expandVideoParts(bvid, track);
      if (parts.length > 1) {
        console.info(`download expand: ${bvid} -> ${parts.length} parts`);
        return parts;
      }
    } catch (e) {
      console.error(`expand parts for download failed: ${describeError(e)}`);
    }
    return [track];
  }

  /**
   * 取曲目对应的 bvid。
   * `track.bvid` 为空时从 id 里切：展开出来的非首分 P id 形如 `BV1xx#12345`。
   */
  private bvidOf(track: Track): string {
    if (track.bvid.length > 0) {
      return track.bvid;
    }
    const hash: number = track.id.indexOf('#');
    return hash > 0 ? track.id.substring(0, hash) : track.id;
  }

  /**
   * 是否该因「仅 WiFi 下载」拦下这次请求。
   *
   * 开关关着 → 永不拦；开着但探测不出网络类型 → 也不拦
   * （NetworkUtil 探测失败一律回报「不计流量网络」）。方向是刻意的：
   * 探测失败就禁止下载，用户只会认定「下载坏了」。
   */
  private isWifiOnlyBlocked(): boolean {
    try {
      if (!AppPreferences.getSettings().wifiOnlyDownload) {
        return false;
      }
      return !isUnmeteredNetwork();
    } catch (e) {
      console.error(`wifi-only gate failed: ${describeError(e)}`);
      return false;
    }
  }

  /** 建一条「排队中」的任务记录并落库；返回 null = 建不出来（拿不到沙箱目录） */
  private async createPendingTask(track: Track, source?: DownloadSource): Promise<DownloadTask | null> {
    if (!this.context) {
      return null;
    }
    const dir: string = `${this.context.filesDir}/downloads`;
    // （2026-10-16 AppFreeze 加固）建目录改异步；已存在时报错直接吞掉
    try {
      await fs.mkdir(dir, true);
    } catch (e) {
      // 目录已存在时忽略
    }
    const task: DownloadTask = {
      id: `dl_${Date.now()}_${Math.floor(Math.random() * 1e6).toString(36)}`,
      musicId: track.id,
      title: track.title,
      artist: track.artist,
      coverUrl: track.coverUrl,
      url: '',
      totalBytes: 0,
      downloadedBytes: 0,
      speed: 0,
      audioQuality: 0,
      audioBandwidth: 0,
      status: DownloadStatus.PENDING,
      errorMessage: '',
      createdAt: Date.now(),
      completedAt: 0,
      // 分 P 之间 id 不同（bvid#cid），safeName 会把 # 换成 _，落盘名不会撞
      localFilePath: `${dir}/${this.safeName(track.id)}.m4a`,
      // 来源歌单：整单下载时由调用方传入，单曲下载为空串（下载管理里不归组）
      playlistId: source ? source.playlistId : '',
      playlistName: source ? source.playlistName : '',
      // 合集归属三件套（2026-10-08）：多 P 展开时由 requestDownload 逐条标记；
      // 单视频 / 老调用路径为 ''/0，UI 靠 partTotal>1 识别合集，不受影响
      collectionTitle: source && source.collectionTitle ? source.collectionTitle : '',
      partNo: source && source.partNo ? source.partNo : 0,
      partTotal: source && source.partTotal ? source.partTotal : 0
    };
    // 先入内存表并推送：用户点完立刻能在下载页看到条目
    this.tasks.set(task.id, task);
    this.notify();
    await insertDownload(task);
    return task;
  }

  /**
   * 启动队列消费者（幂等）。
   *
   * `pumping` 是必须的：requestDownload 每次都会调 pump()，没有这个标志就会起
   * 两个消费者同时 shift 同一条队列 —— 同一条被下两次，且两个流往同一个 fd 里写。
   */
  private pump(): void {
    if (this.pumping) {
      return;
    }
    this.pumping = true;
    // 2026-10-08 消费者启动即申报下载保活意愿：退后台/锁屏后队列继续跑。
    // 必须放在这里而不是 runDownload 里——排队中的任务同样需要保活，
    // 且串行队列从头到尾只该申报一次（协调器内部有幂等，但语义上以队列为单位）。
    this.syncTransferTask();
    this.runQueue()
      .then((): void => {
        this.pumping = false;
        // 队列退出（跑空/暂停/异常）后重新对账：queue 空或 paused 时撤销保活意愿，
        // 仍残留任务（理论上只有崩溃兜底路径）则维持。注意必须放在 pumping 复位
        // **之后**，active 的判定依赖 pumping 的最终值。
        this.syncTransferTask();
        this.drainIfPending();
      })
      .catch((e: Error): void => {
        console.error(`download queue crashed: ${describeError(e)}`);
        // 兜底复位：不复位的话队列永久卡住，之后点的下载全部停在「排队中」
        this.pumping = false;
        this.syncTransferTask();
        this.drainIfPending();
      });
  }

  /**
   * 把「队列是否有活」同步给长时任务协调器（2026-10-08 后台持续下载）。
   *
   * 判定：未被全部暂停，且（消费者活着 **或** 还有排队任务）。
   *   - `pumping` 覆盖了传输中、解析音源中、失败重试的退避等待中——弱网退避
   *     恰恰是最需要保活的窗口，若只看「正在传输」，每次重试间隙都可能被挂起。
   *   - 排队任务也要保活：串行队列里第 5 首开始下载前可能要等前 4 首几分钟。
   *   - 「全部暂停」不算有活：正传的那条会被中止，保活留着只会白耗电。
   *
   * fire-and-forget：长时任务的成败不应影响下载流程本身，失败只记日志。
   */
  private syncTransferTask(): void {
    if (!this.context) {
      return;
    }
    const active: boolean = !this.paused && (this.queue.length > 0 || this.pumping);
    BackgroundPlayback.getInstance().setTransferWanted(this.context, active)
      .catch((e: Error): void => {
        console.error(`sync transfer task failed: ${describeError(e)}`);
      });
  }

  /**
   * 消费者退出后若队列又进了新活，再拉起来。
   *
   * 关闭的是一个**竞态窗口**：最后一条下载的 await 刚落地时，用户又点了下载 →
   * requestDownload 里那次 pump() 会看到 pumping 仍为 true 而直接返回，
   * 若此后没有人再触发，那条任务就永远停在「排队中」。
   */
  private drainIfPending(): void {
    // 暂停中绝不自动拉起消费者：否则「全部暂停」刚按下，消费者退出的那一刻
    // 又把自己拉起来了，界面看起来完全没反应。
    if (!this.paused && this.queue.length > 0) {
      this.pump();
    }
  }

  private async runQueue(): Promise<void> {
    while (this.queue.length > 0) {
      // 暂停：立刻退出，剩下的任务**原样留在队列里**。
      // 它们是内存对象、带着 Track（bvid/aid/cid），恢复时能直接接着跑；
      // 若在这里顺手清掉，音乐中心那类 musicId 不是 bvid 的条目就再也拼不回来了。
      if (this.paused) {
        return;
      }
      // 取「可跑的那一条」：跳过被**单条暂停**的条目，但把它们留在队列里
      // （条目即 Track 的载体，摘掉就再也拼不回来）。返回 undefined = 队列里
      // 只剩暂停条目 → 本轮收工，消费者退出。
      const item: QueuedDownload | undefined = this.shiftRunnable();
      if (!item) {
        return;
      }
      // 排队期间被用户删掉：记录已不在内存表 / 已打取消标记 → 直接跳过。
      // 为一条已经不在界面上的任务去发解析请求，纯属白耗一次 HTTP。
      if (this.cancelled.has(item.task.id) || !this.tasks.has(item.task.id)) {
        this.cancelled.delete(item.task.id);
        continue;
      }
      // 记下这一条在跑，暂停时由 runDownload 自己把它放回队首
      await this.runDownload(item);
    }
  }

  /**
   * 从队首方向取出一条**可执行**的任务：跳过「单条暂停」的条目（保留在队列里），
   * 队列里只剩暂停条目时返回 undefined（消费者据此收工，不再空转）。
   */
  private shiftRunnable(): QueuedDownload | undefined {
    for (let i = 0; i < this.queue.length; i++) {
      const item: QueuedDownload = this.queue[i];
      if (this.pausedIds.has(item.task.id) || item.task.status === DownloadStatus.PAUSED) {
        continue;
      }
      this.queue.splice(i, 1);
      return item;
    }
    return undefined;
  }

  /** 该任务是否还留在队列里（单条恢复时判断要不要重建 Track） */
  private inQueue(id: string): boolean {
    for (let i = 0; i < this.queue.length; i++) {
      if (this.queue[i].task.id === id) {
        return true;
      }
    }
    return false;
  }

  /**
   * 真正干活：解析音源 → 流式落盘 → 收尾。所有失败路径都必须把任务落进终态。
   *
   * 失败自动重试（attempt 循环）：单次失败不判死，最多试 DOWNLOAD_MAX_ATTEMPTS 次，
   * 每次都**重新解析音源** —— 直链过期 / 被限流是最高频的失败原因，拿新 URL 即可救回；
   * 停滞 / 断流的半截文件被 downloadFile 保留，重试走 Range 续传，弱网不重复耗流量。
   * 「全部暂停」在尝试入口与退避等待里都会被响应（按暂停收尾、任务回队首）。
   */
  private async runDownload(item: QueuedDownload): Promise<void> {
    const task: DownloadTask = item.task;
    const track: Track = item.track;

    // 竞态：runQueue 判过 paused 之后、这里开始之前用户点了「全部暂停」。
    // 这一条还没动过任何字节，直接放回队首（保持原有顺序）等恢复。
    if (this.paused) {
      this.queue.unshift(item);
      return;
    }

    // 闸门②：排队期间网络可能已从 Wi-Fi 切到蜂窝。逐条复查一遍，命中的直接标失败
    // 并带上明确原因（否则用户只会看到一堆「下载失败」去猜）。
    // 注：**正在传输中的那一条不会被打断**，从本轮之后新起的任务才会被拦。
    if (this.isWifiOnlyBlocked()) {
      await this.finishTask(task, DownloadStatus.ERROR, '', '移动网络，已按「仅 WiFi 下载」暂停');
      return;
    }

    try {
      // 下载音质：这条链路读 downloadQuality。播放侧（MusicPlayer.loadAndPlay）
      // 同样已接入偏好（读 playQuality，2026-10-08 起生效）—— 两边各自读各自档位。
      const preferred: number = downloadQualityId(AppPreferences.getSettings().downloadQuality);
      let done: boolean = false;
      for (let attempt = 1; attempt <= DOWNLOAD_MAX_ATTEMPTS && !done; attempt++) {
        // 排队/退避期间被用户删掉：记录已不在内存表，直接放弃，不回写终态
        if (this.cancelled.has(task.id) || !this.tasks.has(task.id)) {
          return;
        }
        // 退避等待里用户按了「全部暂停」/「暂停这一条」：按暂停收尾，保留半截文件、任务回队首
        if (this.paused || this.pausedIds.has(task.id)) {
          await this.finishTask(task, DownloadStatus.PAUSED, task.localFilePath, '');
          this.queue.unshift(item);
          this.notify();
          return;
        }
        try {
          const source = await extractAudioFromVideo(this.bvidOf(track), {
            aid: track.aid,
            cid: track.cid
          }, preferred);
          task.url = source.audioUrl;
          task.audioQuality = source.audioQuality;
          task.audioBandwidth = source.audioBandwidth;
          // 换一首要重置三个计量：否则新任务沿用上一条的进度/速度读数。
          // ⚠️ 重试尝试**不重置 downloadedBytes**：停滞失败的半截文件被保留，
          // 这里的读数就是断点大小；重置会让进度条在续传前闪回 0%。
          if (attempt === 1) {
            task.totalBytes = 0;
            task.downloadedBytes = 0;
          }
          task.speed = 0;
          task.status = DownloadStatus.DOWNLOADING;
          await updateDownloadStatus(task.id, DownloadStatus.DOWNLOADING);
          this.notify();

          await this.downloadFile(source.audioUrl, task.localFilePath, task.id);
          await this.finishTask(task, DownloadStatus.COMPLETED, task.localFilePath, '');
          done = true;
        } catch (e) {
          const message: string = e instanceof Error ? e.message : '';
          if (message === PAUSE_SENTINEL) {
            // 用户主动暂停：**保留半截文件**（恢复时靠它做 Range 续传），标 PAUSED，
            // 再把这一条放回队首 —— 整个流程里只有它还握着解析音源用的 Track。
            await this.finishTask(task, DownloadStatus.PAUSED, task.localFilePath, '');
            this.queue.unshift(item);
            this.notify();
            done = true;
          } else if (this.cancelled.has(task.id)) {
            // 用户中途删掉了这个任务：记录已不在库里，不回写终态、也不再重试
            done = true;
          } else {
            console.error(
              `download attempt ${attempt}/${DOWNLOAD_MAX_ATTEMPTS} failed: ${describeError(e)}`
            );
            if (attempt < DOWNLOAD_MAX_ATTEMPTS) {
              const resumed: boolean = await this.waitBeforeRetry(task.id, attempt);
              if (!resumed) {
                // 退避期间「全部暂停」：按暂停收尾，半截文件留给恢复时续传
                await this.finishTask(task, DownloadStatus.PAUSED, task.localFilePath, '');
                this.queue.unshift(item);
                this.notify();
                done = true;
              }
            }
          }
        }
      }
      if (!done) {
        console.error(`download failed after ${DOWNLOAD_MAX_ATTEMPTS} attempts: ${task.id}`);
        if (!this.cancelled.has(task.id)) {
          await this.finishTask(task, DownloadStatus.ERROR, '', '下载失败（已自动重试）');
        }
      }
    } finally {
      this.cancelled.delete(task.id);
    }
  }

  /**
   * 重试前的退避等待（时长 = attempt × RETRY_BASE_DELAY_MS）。
   *
   * 返回 false = 等待期间用户按了「全部暂停」，调用方应按暂停收尾；
   * 返回 true 后调用方还会再查一次 cancelled（用户删任务 → 直接放弃，不再发起下一次尝试）。
   */
  private async waitBeforeRetry(taskId: string, attempt: number): Promise<boolean> {
    const deadline: number = Date.now() + RETRY_BASE_DELAY_MS * attempt;
    while (Date.now() < deadline) {
      if (this.paused) {
        return false;
      }
      if (this.cancelled.has(taskId)) {
        return true;
      }
      await sleep(RETRY_WAIT_POLL_MS);
    }
    return true;
  }

  private async finishTask(
    task: DownloadTask,
    status: DownloadStatus,
    filePath: string,
    errorMessage: string
  ): Promise<void> {
    task.status = status;
    task.errorMessage = errorMessage;
    // 单条暂停标记的生命周期止于终态：完成 / 失败 / 被删之后不再需要它，
    // 留着只会让同 id 的新任务（重试会删旧建新，id 不同，但去重路径可能复用）被误跳过。
    if (status !== DownloadStatus.PAUSED) {
      this.pausedIds.delete(task.id);
    }
    // 速度是瞬时量：任务落进终态就不存在「当前速度」了。不清零的话，
    // 完成/失败的行上会一直挂着最后那一次的读数。
    task.speed = 0;
    if (status === DownloadStatus.COMPLETED) {
      task.localFilePath = filePath;
      task.completedAt = Date.now();
      if (task.totalBytes > 0) {
        task.downloadedBytes = task.totalBytes;
      }
    } else if (status === DownloadStatus.PAUSED) {
      // 暂停：路径与已下载字节**一律保留** —— 恢复时要靠它们做 Range 续传。
      // 这里什么都不动（task.localFilePath 本来就是这条任务的落盘路径）。
    } else {
      // 失败 / 中断：半截文件已被删除，把路径清干净，
      // 否则界面上的「播放」会指向一个不存在的文件（点了没反应）。
      task.localFilePath = '';
      task.completedAt = 0;
    }
    await updateDownloadStatus(task.id, status, task.localFilePath, task.completedAt);
    // 收尾也要补一次进度，让百分比最终停在 100%
    await updateDownloadProgress(task.id, task.downloadedBytes, task.totalBytes, status);
    this.notify();
  }

  /**
   * 把音频流写进应用沙箱文件。
   *
   * ⚠️ 三条铁律（每一条都对应一次真实故障）：
   *
   * 1. **`requestInStream` 的 Promise 只代表「响应头已到」，不代表数据收完。**
   *    数据会继续通过 `dataReceive` 推送，直到 `dataEnd` 事件。早前的实现在 await 返回后
   *    立刻 `off` + `closeSync` + `destroy()`，而此刻流还在传输 —— 于是
   *    ① 后续 `dataReceive` 往**已关闭的 fd** 写入；② `destroy()` 一个进行中的流式请求。
   *    两者都会在 native 层把进程直接干掉：**用户点击下载 → App 闪退**，而任务早已写进库、
   *    状态停在 downloading —— 重启后就成了下载页里那条「任务已中断」。
   *    参考工程 `BiliMusic-main/service/BiliService.ets` 的做法就是**轮询等 `dataEnd`**。
   *
   * 2. **事件名必须是 `headersReceive`。** `headerReceive`（单数）自 API 8 起已废弃，
   *    而且它的回调签名是 `AsyncCallback<Object>`，即 `(err, data)` **两个参数**。
   *    按单参数写时形参接到的其实是 `err`，`content-length` 永远是 undefined ——
   *    这正是「总大小恒为 0、进度条停在 0%」的根因。
   *
   * 3. **回调里绝不能抛异常。** 它们跑在事件分发路径上而非 Promise 链上，
   *    抛出去没有任何 `.catch()` 接得住 → 主线程未捕获异常 → 应用直接退出。
   *
   * 4. **断点续传（「全部暂停 → 全部开始」的底座）。**
   *    文件一律以 `CREATE | APPEND` 打开、顺序追加写，因此「文件有多长」天然等于
   *    「已经拿到多少连续正确的字节」，不需要额外记账。恢复时带上
   *    `Range: bytes=<文件长度>-`；只有响应头里的 `Content-Range` 起点与该长度**完全一致**
   *    才按续传走，否则一律 `truncate(0)` 从头写。
   *    ⚠️ 顺序不能反：先判定、再写第一个数据块。判错方向的代价不对称 ——
   *    多下一次只是浪费流量，而把两段数据首尾相接会拼出一个能播、内容却是错的文件。
   *    半截文件的保留策略按失败原因区分（见 catch 块）：暂停与停滞/断流保留（字节
   *    全部来自已校验的 200/206 响应，续传安全），HTTP 状态错误回滚到断点，
   *    校验失败 / 用户删除则删干净。
   */
  private async downloadFile(url: string, destPath: string, taskId: string): Promise<void> {
    const request: http.HttpRequest = http.createHttp();
    let fd: number = -1;
    /**
     * 续传起点（字节）。只信任落盘文件的真实长度，不读库里的 downloadedBytes ——
     * 写入是顺序追加的、任何失败都会删文件，所以「文件多长」就是「拿到多少正确字节」，
     * 而库里的进度值是 800ms 节流落盘的，天然落后于文件。
     * 小于最小有效体积的残留视为垃圾（错误页残骸），当作 0 从头下。
     */
    let resumeFrom: number = 0;
    try {
      const pre: fs.Stat = await fs.stat(destPath);
      if (pre.size > MIN_VALID_AUDIO_BYTES) {
        resumeFrom = pre.size;
      }
    } catch (e) {
      // 文件不存在 = 全新下载
    }
    try {
      const file: fs.File = await fs.open(
        destPath,
        // （2026-10-16 AppFreeze 加固）去掉 APPEND：写入位置已由 write 的显式
        // offset 指定，不再依赖「追加到末尾」语义（APPEND 下显式偏移行为未定义）。
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE
      );
      fd = file.fd;
      if (resumeFrom === 0) {
        // 不以 TRUNC 打开是为了能续传，但「不续传」时又必须把旧内容清干净 ——
        // APPEND 会把新数据接在旧垃圾后面，拼出一个头部正确、中间乱掉的文件。
        await fs.truncate(fd, 0);
      }
    } catch (e) {
      console.error(`open download file failed: ${describeError(e)}`);
      request.destroy();
      throw e;
    }
    let lastNotifyAt: number = 0;
    let lastDbWriteAt: number = 0;
    /** 速度采样游标：上一次采样的时刻与当时的已下载字节数 */
    let lastSpeedAt: number = Date.now();
    let lastSpeedBytes: number = 0;
    /** 数据接收是否已确认结束（由 dataEnd 事件置位） */
    let dataEnded: boolean = false;
    /** 最近一次有数据推进的时刻，用于判「停滞」（固定总超时会误杀大文件的正常下载） */
    let lastActivityAt: number = Date.now();
    /**
     * 服务端是否认可这次 Range 请求（响应头 Content-Range 的起点 == resumeFrom）。
     *
     * 默认 false 是**安全侧默认值**：响应头没解析出来、或压根没触发 headersReceive 时，
     * 都会走「清空重下」，绝不会拿一个来路不明的位置当续传起点。
     */
    let resumeOk: boolean = false;
    /** headersReceive 可能触发多次（100-continue / 重定向），续传判定只做一次 */
    let resumeDecided: boolean = false;
    /** 首个数据块是否已处理过（清空重下的动作只做一次） */
    let writeReady: boolean = false;
    /** 进度显示用的基准：真续传时是 resumeFrom，走「清空重下」时是 0 */
    let baseBytes: number = resumeFrom;
    /**
     * （2026-10-16 AppFreeze 加固）异步写链：dataReceive 原来逐块 fs.writeSync 在
     * 主线程落盘，快网络 / 大文件时主线程累计阻塞明显。现改为每个数据块按**显式
     * position** 走异步 fs.write，用 writeChain 串行排队 —— 写入位置由 position
     * 显式给出，正确性与链的完成顺序无关。
     * ⚠️ 不变量：任何触碰 fd 的路径（截断 / 回滚 / 关闭 / 校验）必须发生在
     * `await writeChain` 之后，否则会与在途写入竞争。
     */
    let writeOffset: number = baseBytes;
    let writeChain: Promise<void> = Promise.resolve();
    /** 写链上是否发生过失败（失败详情已在链内记日志，这里只做完成后的判定） */
    let writeFailed: boolean = false;

    // 解析 Content-Length：B 站音频流常为分块传输，dataReceiveProgress 的 totalSize 恒为 0，
    // 进度条因此永远停在 0%。优先从响应头拿 Content-Length 作为总大小。
    // 事件名用 headersReceive（复数）：headerReceive 已废弃，且回调是两参数的 AsyncCallback。
    request.on('headersReceive', (header: Object): void => {
      try {
        const h: Record<string, Object> = header as Record<string, Object>;
        // 续传判定：只有服务端明确回了 `Content-Range: bytes <resumeFrom>-...`
        // 才认这次是真正的断点续传（HTTP 语义保证响应头早于响应体，
        // 所以在这里定下来，dataReceive 首个数据块就能直接用）。
        if (resumeFrom > 0 && !resumeDecided) {
          resumeDecided = true;
          let rawCr: Object | undefined = h['content-range'];
          if (rawCr === undefined) {
            rawCr = h['Content-Range'];
          }
          const crText: string = rawCr !== undefined && rawCr !== null ? String(rawCr) : '';
          resumeOk = contentRangeStart(crText) === resumeFrom;
        }
        let raw: Object | undefined = h['content-length'];
        if (raw === undefined) {
          raw = h['Content-Length'];
        }
        if (raw !== undefined && raw !== null) {
          const size: number = Number(raw);
          // NaN > 0 为 false，无需额外判 NaN
          if (size > 0) {
            const task: DownloadTask | undefined = this.tasks.get(taskId);
            if (task) {
              // 续传（206）时 Content-Length 只是**本次响应体**的长度，完整大小还要加上断点；
              // 服务端忽略 Range（200）时 resumeOk 为 false，这里拿到的本来就是完整大小。
              const base: number = resumeFrom > 0 && resumeOk ? resumeFrom : 0;
              task.totalBytes = base + size;
            }
          }
        }
      } catch (e) {
        console.error(`parse content-length failed: ${describeError(e)}`);
      }
    });

    request.on('dataReceiveProgress', (progress: { receiveSize: number; totalSize: number }): void => {
      try {
        lastActivityAt = Date.now();
        const task: DownloadTask | undefined = this.tasks.get(taskId);
        if (!task) {
          return;
        }
        // 续传时 receiveSize 是「本次收到的字节数」（从 0 起算），必须叠加断点基准；
        // 走「清空重下」时 baseBytes 已被 dataReceive 归 0。
        task.downloadedBytes = baseBytes + progress.receiveSize;
        // 进度事件自带 totalSize 时取它；否则保留 headersReceive 解析出的 Content-Length，
        // 绝不再把 totalBytes 覆盖回 0（否则进度条会卡在 0%）。
        // ⚠️ 续传（206）时这个 totalSize 说的是「本次响应体」而不是整个文件，
        // 直接采用会让进度条从 0% 开始重算，故续传期间一律以响应头算出的总大小为准。
        if (progress.totalSize > 0 && !resumeOk) {
          task.totalBytes = progress.totalSize;
        }
        task.status = DownloadStatus.DOWNLOADING;

        const now: number = Date.now();
        // 速度：按固定窗口（1s）取增量。逐回调计算不行 —— TCP 分片到达是脉冲式的，
        // 读数会在 0 和峰值之间反复横跳，看起来像网络在抽搐。
        if (now - lastSpeedAt >= SPEED_SAMPLE_WINDOW_MS) {
          const deltaMs: number = now - lastSpeedAt;
          const deltaBytes: number = task.downloadedBytes - lastSpeedBytes;
          task.speed = (deltaMs > 0 && deltaBytes > 0) ? Math.round(deltaBytes * 1000 / deltaMs) : 0;
          lastSpeedAt = now;
          lastSpeedBytes = task.downloadedBytes;
        }
        if (now - lastNotifyAt >= UI_NOTIFY_INTERVAL) {
          lastNotifyAt = now;
          this.notify();
        }
        if (now - lastDbWriteAt >= DB_WRITE_INTERVAL) {
          lastDbWriteAt = now;
          updateDownloadProgress(taskId, task.downloadedBytes, task.totalBytes, DownloadStatus.DOWNLOADING)
            .catch((e: Error): void => {
              console.error(`update download progress failed: ${describeError(e)}`);
            });
        }
      } catch (e) {
        console.error(`download progress callback failed: ${describeError(e)}`);
      }
    });

    request.on('dataReceive', (data: ArrayBuffer): void => {
      try {
        lastActivityAt = Date.now();
        if (fd < 0) {
          return;
        }
        if (!writeReady) {
          writeReady = true;
          if (resumeFrom > 0 && !resumeOk) {
            // 服务端不认 Range（回了 200 全量）：把断点前的旧字节清掉再从头写。
            // 这是**安全方向**的降级 —— 最坏只是白下一次，绝不会把两段数据首尾相接，
            // 拼出一个「能播但内容是错的」文件（那种问题几乎无法从现象反推）。
            // （2026-10-16 AppFreeze 加固）截断进写链排队，保证先于后续所有数据写入执行。
            baseBytes = 0;
            writeOffset = 0;
            writeChain = writeChain.then((): Promise<void> => fs.truncate(fd, 0));
          }
        }
        // （2026-10-16 AppFreeze 加固）显式 offset + 异步写：主线程只记账、不落盘。
        const offset: number = writeOffset;
        writeOffset += data.byteLength;
        writeChain = writeChain
          .then((): Promise<number> => fs.write(fd, data, { offset: offset }))
          .then((_: number): void => {})
          .catch((e: Error): void => {
            writeFailed = true;
            console.error(`write download chunk failed: ${describeError(e)}`);
          });
      } catch (e) {
        console.error(`queue download chunk failed: ${describeError(e)}`);
      }
    });

    // dataEnd = 响应体收完。只有它到达后，才能安全地关文件、销毁请求。
    request.on('dataEnd', (): void => {
      dataEnded = true;
    });

    try {
      const header: Record<string, string> = {
        Referer: BILI_REFERER,
        'User-Agent': 'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile',
        Accept: '*/*'
      };
      // 带 buvid（与其它请求保持一致）：**不登录同样可以下载** —— B 站音频直链是匿名可访问的
      // （实测移动端 UA / PC UA 都是 200/206，只有空 UA 才 403），buvid 的作用是让请求
      // 看起来像正常客户端、避免被限流。
      const baseCookie: string = HttpUtil.getBaseCookie();
      if (baseCookie.length > 0) {
        header['Cookie'] = baseCookie;
      }
      // 断点续传：只请求还没有的那一段。服务端若支持就回 206 + Content-Range，
      // 不支持则回 200 全量（由 dataReceive 里的判定负责清空重写）。
      if (resumeFrom > 0) {
        header['Range'] = `bytes=${resumeFrom}-`;
      }

      const code: number = await request.requestInStream(url, {
        method: http.RequestMethod.GET,
        header: header,
        usingCache: false,
        connectTimeout: 15000,
        readTimeout: 60000
      });
      // 状态码必须校验：直链过期 / 被限流时 CDN 会返回 **200 + 错误页**，
      // 非 200/206 时把错误正文写进 .m4a 毫无意义（还会被下游当成下载成功）。
      if (code !== 200 && code !== 206) {
        throw new Error(`Download HTTP ${code}`);
      }

      // 等数据真正收完。有推进就刷新 lastActivityAt，只有连续无数据才判失败。
      while (!dataEnded) {
        if (this.cancelled.has(taskId)) {
          throw new Error('Download cancelled');
        }
        if (this.paused || this.pausedIds.has(taskId)) {
          // 用户点了「全部暂停」或「暂停这一条」。抛哨兵：下面 catch 里对它有专门的
          // 「保留文件」分支，恢复时凭这份半截文件做 Range 续传，不会白下已经拿到的那部分。
          throw new Error(PAUSE_SENTINEL);
        }
        const idleMs: number = Date.now() - lastActivityAt;
        if (idleMs > STREAM_IDLE_TIMEOUT_MS) {
          throw new Error('Download stalled');
        }
        // 长时间没有新字节 → 速度读数归零并推一次 UI。
        // 不做这一步，断流时界面上会一直挂着最后那次「1.2 MB/s」，看着还在飞快下载。
        if (idleMs > SPEED_STALE_MS) {
          const stalled: DownloadTask | undefined = this.tasks.get(taskId);
          if (stalled && stalled.speed !== 0) {
            stalled.speed = 0;
            this.notify();
          }
        }
        await sleep(STREAM_POLL_INTERVAL_MS);
      }

      // （2026-10-16 AppFreeze 加固）先等写链上全部数据块落盘再校验 / 收尾，
      // 否则魔数探测可能读到还没写完的文件。
      await writeChain;
      if (writeFailed) {
        // 某个数据块写失败：文件里已经出现「空洞」（后续块按显式 position 写在了
        // 各自正确的位置上），这份半截文件**不能**用于续传 —— 交给下面 catch 回滚。
        throw new Error('Write download chunk failed');
      }

      // 校验确实是音频（fMP4 的 ftyp 魔数）：拦住「200 + HTML 错误页」这种假成功
      if (!await isValidAudioFile(destPath)) {
        throw new Error('Downloaded file is not valid audio');
      }
    } catch (e) {
      // （2026-10-16 AppFreeze 加固）暂停 / 取消 / 失败从轮询循环抛出时，写链上
      // 可能还有在途的数据块 —— 必须等链落定再动文件（关闭 / 回滚），否则与写入竞争。
      try {
        await writeChain;
      } catch (e1) {
        // 链内失败已记入 writeFailed，这里只保证时序
      }
      const errMessage: string = e instanceof Error ? e.message : '';
      const pausing: boolean = errMessage === PAUSE_SENTINEL;
      if (pausing) {
        // 暂停：**唯一一条原样保留半截文件的路径**。什么都不做，
        // 交给下面的 finally 关文件；恢复时靠这份文件做 Range 续传。
        console.info(`download paused at ${resumeFrom} bytes: ${taskId}`);
      } else {
        console.error(`download stream failed: ${describeError(e)}`);
        // 半截文件去留（为「失败自动重试 + Range 续传」服务，见文件头注释⑥）：
        //   · 停滞 / 网络中断 —— 本次响应已通过 200/206 校验，落盘字节全部有效，
        //     **保留**半截文件，上层重试时从断点续传，弱网下不浪费已下载的流量；
        //   · HTTP 状态码不对 / 数据块写失败 —— 错误页正文可能已经写进了文件，
        //     或文件里已经出现空洞，必须**回滚到续传起点**（保住此前验证过的前缀）；
        //     没有续传起点就整个删掉；
        //   · 校验不是音频 / 用户删除 —— 文件内容不可信 / 任务已不存在，删干净。
        const badStatus: boolean = errMessage.indexOf('Download HTTP') === 0;
        const writeError: boolean = errMessage === 'Write download chunk failed';
        const discardAll: boolean = errMessage === 'Download cancelled'
          || errMessage === 'Downloaded file is not valid audio';
        try {
          if (fd >= 0) {
            await fs.close(fd);
          }
          fd = -1;
          if (badStatus || writeError) {
            if (resumeFrom > 0) {
              const rollback: fs.File = await fs.open(destPath, fs.OpenMode.READ_WRITE);
              try {
                await fs.truncate(rollback.fd, resumeFrom);
              } finally {
                await fs.close(rollback.fd);
              }
            } else {
              await fs.unlink(destPath);
            }
          } else if (discardAll) {
            await fs.unlink(destPath);
          }
        } catch (e2) {
          // 文件可能还没创建，忽略
        }
      }
      throw e;
    } finally {
      // ⚠️ 顺序不能变：先摘监听（此后不会再有回调往写链里排新写入）→ 等写链落定
      // → 再关文件 → 最后销毁请求。反过来就是「向已关闭的 fd 写入 / 销毁进行中的流」
      // 那条 native 崩溃路径。
      try {
        request.off('dataReceive');
        request.off('dataReceiveProgress');
        request.off('headersReceive');
        request.off('dataEnd');
      } catch (e) {
        console.error(`detach download events failed: ${describeError(e)}`);
      }
      try {
        await writeChain;
      } catch (e1) {
        // 链内失败已记入 writeFailed，这里只保证时序
      }
      try {
        if (fd >= 0) {
          await fs.close(fd);
        }
      } catch (e) {
        console.error(`close download file failed: ${describeError(e)}`);
      }
      try {
        request.destroy();
      } catch (e) {
        console.error(`destroy download request failed: ${describeError(e)}`);
      }

      // 收尾补写一次进度，避免节流窗口内的最后一段丢失
      const task: DownloadTask | undefined = this.tasks.get(taskId);
      if (task && task.status === DownloadStatus.DOWNLOADING) {
        // 服务器未返回 Content-Length（分块传输）时用落盘真实大小兜底，
        // 让进度停在 100%，而不是卡在「准备下载…」
        // ⚠️ 只在**数据已确认收完**时兜底：暂停 / 断流时文件大小只代表「当下下到哪儿」，
        // 拿它当总大小会把界面伪造成 100%（用户会以为下完了，其实只是被暂停了）。
        if (task.totalBytes <= 0 && dataEnded) {
          try {
            const stat: fs.Stat = await fs.stat(destPath);
            if (stat.size > 0) {
              task.totalBytes = stat.size;
              task.downloadedBytes = stat.size;
            }
          } catch (e) {
            // 文件可能尚未写出，忽略
          }
        }
        await updateDownloadProgress(taskId, task.downloadedBytes, task.totalBytes, DownloadStatus.DOWNLOADING);
      }
      this.notify();
    }
  }

  /** 供页面删除后同步内存态 */
  /**
   * 任务 → 曲目（重试时用来重建音源解析所需的信息）。
   *
   * 为什么需要重建：队列里的 `track` **只在进程内传递、不落库**（见文件头注释），
   * 所以重启后只剩任务行，而解析音源要 bvid / cid —— 只能从 `musicId` 拆回来。
   */
  private trackOfTask(t: DownloadTask): Track {
    const rawId: string = t.musicId.length > 0 ? t.musicId : t.id;
    const hash: number = rawId.indexOf('#');
    const bvid: string = hash > 0 ? rawId.substring(0, hash) : rawId;
    const cid: string = hash > 0 ? rawId.substring(hash + 1) : '';
    return buildTrack({
      id: rawId,
      bvid: bvid,
      cid: cid,
      title: t.title,
      artist: t.artist,
      coverUrl: t.coverUrl,
      // 时长/音质等不参与解析音源，缺失无妨
      duration: 0
    });
  }

  /**
   * 重试一批**失败**任务（下载管理页的「重试」入口）。
   *
   * 与 `requestDownload` 的关键差别：**不经 `expandVideoParts`**。
   * 那个函数会把这个 bvid 的**全部分 P** 重新排队 —— 用户当初手动删掉的某些分 P
   * 会趁重试偷偷回来。这里的语义是「重试这一条」，所以只精确重排这一条。
   *
   * 非 FAILED 的任务会被跳过（传入的可以是整组 id 或多选 id，里面混着正常的）。
   */
  async retryTasks(ids: string[], ignoreWifiLimit: boolean = false): Promise<DownloadStartResult> {
    const result: DownloadStartResult = { queued: 0, skipped: 0, blockedReason: '' };
    if (ids.length === 0) {
      return result;
    }
    await this.ensureLoaded();
    if (!ignoreWifiLimit && this.isWifiOnlyBlocked()) {
      result.blockedReason = WIFI_ONLY_BLOCKED;
      return result;
    }
    this.paused = false;
    this.publishPaused();
    for (let i = 0; i < ids.length; i++) {
      const t: DownloadTask | undefined = this.tasks.get(ids[i]);
      if (!t || t.status !== DownloadStatus.ERROR) {
        result.skipped += 1;
        continue;
      }
      // 失败残留记录先清掉：否则 getDownloadByMusicId 会认为「已在队列」而跳过重排
      await deleteDownload(t.id);
      this.tasks.delete(t.id);
      // 歌单来源带回（重试不重新展开分 P，归属信息只能从旧任务抄回来）；
      // 合集三件套同理（2026-10-08）——重排的任务必须保持「第 n / N 个分 P」的标记，
      // 否则重试后它在下载页会从合集组里掉出去、退化成无标识的单条。
      const hasPlaylist: boolean = t.playlistId.length > 0;
      const hasCollection: boolean = t.collectionTitle.length > 0 || t.partTotal > 0;
      const source: DownloadSource | undefined = (hasPlaylist || hasCollection)
        ? {
          playlistId: t.playlistId,
          playlistName: t.playlistName,
          collectionTitle: t.collectionTitle,
          partNo: t.partNo,
          partTotal: t.partTotal
        }
        : undefined;
      const created: DownloadTask | null = await this.createPendingTask(this.trackOfTask(t), source);
      if (created) {
        this.queue.push({ task: created, track: this.trackOfTask(t) });
        result.queued += 1;
      }
    }
    if (result.queued > 0) {
      this.notify();
      this.pump();
    }
    return result;
  }

  /**
   * 算出一组任务里处于「失败」的那些 id（组级「重试」按钮用）。
   *
   * 不放进 `DownloadTask` / `DownloadGroup` 的理由：那两处是纯数据 + 纯渲染，
   * 塞状态判定会让两边都沾上业务逻辑；而组头本来就要显示「N 首失败」。
   */
  failedIdsOf(ids: string[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      const t: DownloadTask | undefined = this.tasks.get(ids[i]);
      if (t && t.status === DownloadStatus.ERROR) {
        out.push(t.id);
      }
    }
    return out;
  }

  async removeTask(id: string): Promise<void> {
    await this.ensureLoaded();
    // 先打取消标记：下载中的任务会在下一个轮询点主动中止请求并清掉半截文件。
    // 没有这一步，请求会继续跑到结束（白耗流量），而且会往一条已删除的记录里回写状态。
    this.cancelled.add(id);
    this.tasks.delete(id);
    this.dropFromQueue(id);
    // 单条暂停标记一并清掉（删掉的任务不需要再被恢复）
    this.pausedIds.delete(id);
    await deleteDownload(id);
    this.notify();
  }
  /**
   * 批量删除（下载页多选）。
   * 逐条调 removeTask 会推 N 次 UI 快照（N 次全列表 diff），这里合成一次；
   * 落盘文件的删除由页面负责（它手上的快照有 localFilePath）。
   */
  async removeTasks(ids: string[]): Promise<void> {
    await this.ensureLoaded();
    for (let i = 0; i < ids.length; i++) {
      const id: string = ids[i];
      this.cancelled.add(id);
      this.tasks.delete(id);
      this.dropFromQueue(id);
      this.pausedIds.delete(id);
      await deleteDownload(id);
    }
    this.notify();
  }

  /**
   * 全部暂停。
   *
   * 只做两件事：置位 `paused`（消费者会在下一轮退出、不再取新任务），
   * 以及让**正在传输的那一条**主动中止（downloadFile 的等待循环抛哨兵）。
   * 中止时保留半截文件，任务标 PAUSED —— 恢复时凭它做 Range 续传。
   * 队列里其它任务**原样留着**（不清状态、不丢元素），因为它们带着解析音源用的 Track。
   */
  async pauseAll(): Promise<void> {
    await this.ensureLoaded();
    this.paused = true;
    // 2026-10-08 暂停即撤销下载保活意愿：正传的那条会被中止，任务留着只会
    // 白耗电并留一条「传输中」的常驻通知。消费者退出时 pump 的收尾对账
    // 也会再确认一次，这里提前撤销可以让通知尽快消失。
    this.syncTransferTask();
    this.publishPaused();
    this.notify();
  }

  /**
   * **单条暂停**（2026-10-11 新增，下载页点「下载中 / 排队中」的行）。
   *
   * 两条路径：
   *   · 正在传输的那条 —— 打 `pausedIds` 标记，传输循环在下一个轮询点（20ms）抛哨兵，
   *     走与「全部暂停」完全相同的收尾：保留半截文件、标 PAUSED、条目放回队首；
   *   · 还没开工的那条（PENDING）—— 直接落 PAUSED 终态，条目**留在队列里**
   *     （`shiftRunnable` 之后会跳过它），Track 不丢，恢复时零重建成本。
   *
   * 只对「下载中 / 排队中」有意义：已完成 / 失败 / 已暂停的条目点了不做事，
   * 免得用户以为点出了什么变化。
   */
  async pauseTask(id: string): Promise<void> {
    await this.ensureLoaded();
    const t: DownloadTask | undefined = this.tasks.get(id);
    if (!t) {
      return;
    }
    if (t.status !== DownloadStatus.DOWNLOADING && t.status !== DownloadStatus.PENDING) {
      return;
    }
    this.pausedIds.add(id);
    if (t.status === DownloadStatus.PENDING) {
      // 还没开工：直接落 PAUSED，消费者不会再取到它（shiftRunnable 会跳过）
      await this.finishTask(t, DownloadStatus.PAUSED, t.localFilePath, '');
      return;
    }
    // 传输中：真正的收尾在 runDownload 的哨兵分支里（它才握着队列元素），
    // 这里只补一次快照，让行状态先变「已暂停」—— 别让用户等下一个轮询点。
    this.notify();
  }

  /**
   * **单条恢复**（下载页点「已暂停」的行）。
   *
   * 队列里通常还留着这条（带 Track，暂停时没摘），直接复用；只有进程重启后的
   * 孤儿（队列里没有）才需要按 `trackFromTask` 重建，重建不出来就明确标失败
   * —— 与「全部开始」的兜底逐字同源，不让条目永远卡在「已暂停」上点不动。
   */
  async resumeTask(id: string): Promise<void> {
    await this.ensureLoaded();
    const t: DownloadTask | undefined = this.tasks.get(id);
    if (!t || t.status !== DownloadStatus.PAUSED) {
      return;
    }
    this.pausedIds.delete(id);
    t.status = DownloadStatus.PENDING;
    t.errorMessage = '';
    await updateDownloadStatus(t.id, DownloadStatus.PENDING, t.localFilePath, t.completedAt);
    if (!this.inQueue(id)) {
      const track: Track | null = this.trackFromTask(t);
      if (!track) {
        await this.finishTask(t, DownloadStatus.ERROR, '', '任务已过期，请重新下载');
        return;
      }
      this.queue.push({ task: t, track: track });
    }
    this.notify();
    // 全局暂停中绝不拉起消费者（否则「全部暂停」刚按下又跑起来）
    if (!this.paused) {
      this.pump();
    }
  }

  /**
   * 全部开始（继续下载）。
   *
   * 把 PAUSED 的任务改回 PENDING 重新排队，再拉起消费者。两条来源：
   *   ① 队列里还留着的元素（暂停时被放回队首的那条 + 从未开始过的那些）—— 直接复用；
   *   ② 队列里没有、但库里是 PAUSED 的记录 —— 只可能来自上一次进程退出（队列不落库的
   *      边界），用 `trackFromTask` 尽力重建 Track；重建不出来就明确标成「请重新下载」，
   *      而不是让它永远卡在「已暂停」上点不动。
   */
  async resumeAll(): Promise<void> {
    await this.ensureLoaded();
    this.paused = false;
    // 「全部开始」= 所有暂停都恢复：单条暂停标记一并清掉，否则那些条目会被
    // shiftRunnable 永远跳过（界面上按钮亮了、队列里却纹丝不动）。
    this.pausedIds.clear();
    this.publishPaused();

    for (let i = 0; i < this.queue.length; i++) {
      const item: QueuedDownload = this.queue[i];
      if (item.task.status === DownloadStatus.PAUSED) {
        item.task.status = DownloadStatus.PENDING;
        item.task.errorMessage = '';
        await updateDownloadStatus(
          item.task.id,
          DownloadStatus.PENDING,
          item.task.localFilePath,
          item.task.completedAt
        );
      }
    }

    const inQueue: Set<string> = new Set<string>();
    for (let i = 0; i < this.queue.length; i++) {
      inQueue.add(this.queue[i].task.id);
    }
    const orphans: DownloadTask[] = [];
    this.tasks.forEach((t: DownloadTask): void => {
      if (t.status === DownloadStatus.PAUSED && !inQueue.has(t.id)) {
        orphans.push(t);
      }
    });
    orphans.sort((a: DownloadTask, b: DownloadTask): number => a.createdAt - b.createdAt);
    for (let i = 0; i < orphans.length; i++) {
      const t: DownloadTask = orphans[i];
      const track: Track | null = this.trackFromTask(t);
      if (!track) {
        await this.finishTask(t, DownloadStatus.ERROR, '', '任务已过期，请重新下载');
        continue;
      }
      t.status = DownloadStatus.PENDING;
      t.errorMessage = '';
      await updateDownloadStatus(t.id, DownloadStatus.PENDING, t.localFilePath, t.completedAt);
      this.queue.push({ task: t, track: track });
    }

    this.notify();
    if (this.queue.length > 0) {
      this.pump();
    }
    // 2026-10-08 恢复后重新申报保活。放在 pump() 之后：pump 成功拉起时其内部
    // 已申报过，这里是对「队列仍为空（无可恢复任务）」情况的无害兜底
    // （active=false 时协调器快速返回，无副作用）。
    this.syncTransferTask();
  }

  /** 发布队列级暂停状态（页面据此显示「已暂停」横幅并切换按钮可用性） */
  private publishPaused(): void {
    try {
      AppStorage.setOrCreate(STORE_DOWNLOAD_PAUSED, this.paused);
    } catch (e) {
      console.error(`publish download paused failed: ${describeError(e)}`);
    }
  }

  /** 把某条任务从待下载队列里摘掉：否则用户删掉它之后，一次「全部开始」又会把它排回来 */
  private dropFromQueue(id: string): void {
    for (let i = this.queue.length - 1; i >= 0; i--) {
      if (this.queue[i].task.id === id) {
        this.queue.splice(i, 1);
      }
    }
  }

  /**
   * 用落库字段尽力重建一个 Track。
   *
   * 只用于「暂停状态跨进程残留」这一条路径 —— 队列不落库，重启后只剩 download_task
   * 的几列。musicId 里带 BV 号的（普通投稿、以及 id 形如 `BV1xx#cid` 的分 P）能重建；
   * 音乐中心那种纯音乐 id 重建不出来，返回 null 让调用方明确告知用户重新下载。
   */
  private trackFromTask(t: DownloadTask): Track | null {
    const hash: number = t.musicId.indexOf('#');
    const bvid: string = hash > 0 ? t.musicId.substring(0, hash) : t.musicId;
    if (bvid.indexOf('BV') !== 0) {
      return null;
    }
    return buildTrack({
      id: t.musicId,
      title: t.title,
      artist: t.artist,
      coverUrl: t.coverUrl,
      bvid: bvid,
      cid: hash > 0 ? t.musicId.substring(hash + 1) : ''
    });
  }

  private safeName(name: string): string {
    const cleaned: string = name.replace(/[^\w\-]+/g, '_');
    return cleaned.length > 0 ? cleaned : 'track';
  }
}
