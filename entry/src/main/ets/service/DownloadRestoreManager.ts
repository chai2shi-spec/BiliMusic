/**
 * 「扫描并恢复已下载歌曲」的编排层（单例状态机）。
 *
 * 两段式，边界必须守住：
 *   · 阶段 A（AUTHORIZING / SCANNING / MATCHING）**只读**：不写 RDB、不 unlink、
 *     不覆盖音频、不往公共目录写任何文件。唯一例外是重新授权拿到的目录 URI
 *     凭证（写 Preferences，避免每次扫描都弹一次授权）。
 *   · 阶段 B（COMMITTING）只在用户预览勾选 + 二次确认后执行：写 download_task，
 *     并为没有索引的旧文件补写一份 sidecar。
 *
 * 进度经 AppStorage(STORE_RESTORE_STATE) 广播新快照，页面 @StorageLink/@Watch 订阅；
 * 单例持有真源，页面被回收再回来也能接着看进度（与歌单导入同款）。
 */

import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';
import { AppPreferences } from '../preferences/AppPreferences';
import { AppSettings, DownloadTask, SearchResultItem } from '../model/MusicModels';
import { getAllDownloads } from '../database/MusicDao';
import { DownloadManager } from './DownloadManager';
import { ensureDirUri } from './PublicDownloadsSaver';
import { writeIndex } from './DownloadIndex';
import {
  LocalMatchStat,
  RestoreCancelToken,
  RestoreCategory,
  RestoreItem,
  RestoreSource,
  SearchOutcome,
  applyCandidate,
  applyLocalMatches,
  buildDownloadTask,
  resolveBySearch,
  scanPublicDir
} from './DownloadRestoreScanner';
import { STORE_RESTORE_STATE } from '../common/Constants';
import { sleep } from '../utils/AsyncUtil';

export enum RestorePhase {
  IDLE = 'idle',
  AUTHORIZING = 'authorizing',
  SCANNING = 'scanning',
  MATCHING = 'matching',
  PREVIEW = 'preview',
  COMMITTING = 'committing',
  REPORT = 'report',
  RISK = 'risk',
  CANCELLED = 'cancelled'
}

export interface RestoreState {
  phase: RestorePhase;
  /** 扫描到的音频总数 */
  total: number;
  /** 已处理的条数（匹配阶段按文件推进） */
  processed: number;
  hint: string;
  items: RestoreItem[];
  dirPath: string;
  errorMessage: string;
  committed: number;
  skipped: number;
  failed: number;
  /** 本机数据（已下载 / 曲库 / 拾音）命中数 */
  localMatched: number;
  /** 其中来自拾音的条数 */
  localSessionMatched: number;
  /** 本机可用身份候选总数（0 = 本机确实没有可用身份，只能联网） */
  localCandidateCount: number;
  /** 联网补全命中数 */
  onlineMatched: number;
}

export function emptyRestoreState(): RestoreState {
  return {
    phase: RestorePhase.IDLE,
    total: 0,
    processed: 0,
    hint: '',
    items: [],
    dirPath: '',
    errorMessage: '',
    committed: 0,
    skipped: 0,
    failed: 0,
    localMatched: 0,
    localSessionMatched: 0,
    localCandidateCount: 0,
    onlineMatched: 0
  };
}

/** 与歌单导入同口径：B 站搜索按 IP 累计计量，稳态 ~1.25 QPS 才跑得完整轮 */
const RESTORE_MIN_GAP_MS: number = 800;
const RISK_GAP_MAX_MS: number = 3000;
const RISK_BACKOFF_BASE_MS: number = 90000;
const RISK_RETRY_LIMIT: number = 3;
const BACKOFF_TICK_MS: number = 5000;

export class DownloadRestoreManager {
  private static instance: DownloadRestoreManager | null = null;

  private state: RestoreState = emptyRestoreState();
  private token: RestoreCancelToken = { cancelled: false };
  private running: boolean = false;
  private gapMs: number = RESTORE_MIN_GAP_MS;
  private riskRetry: number = 0;

  static getInstance(): DownloadRestoreManager {
    if (DownloadRestoreManager.instance === null) {
      DownloadRestoreManager.instance = new DownloadRestoreManager();
    }
    return DownloadRestoreManager.instance;
  }

  getState(): RestoreState {
    return this.state;
  }

  /** 推一份全新快照（@StorageLink 靠对象引用变化触发，items 每项也重建） */
  private notify(): void {
    const items: RestoreItem[] = [];
    for (let i = 0; i < this.state.items.length; i++) {
      const it: RestoreItem = this.state.items[i];
      items.push({
        id: it.id, audioPath: it.audioPath, fileName: it.fileName, sizeBytes: it.sizeBytes,
        ext: it.ext, category: it.category, source: it.source, checked: it.checked,
        musicId: it.musicId, bvid: it.bvid, cid: it.cid, title: it.title, artist: it.artist,
        coverUrl: it.coverUrl, audioQuality: it.audioQuality, duration: it.duration,
        playlistId: it.playlistId, playlistName: it.playlistName,
        collectionTitle: it.collectionTitle, partNo: it.partNo, partTotal: it.partTotal,
        completedAt: it.completedAt, reason: it.reason, weakMatch: it.weakMatch,
        candidates: it.candidates.slice()
      });
    }
    const snap: RestoreState = {
      phase: this.state.phase, total: this.state.total, processed: this.state.processed,
      hint: this.state.hint, items: items, dirPath: this.state.dirPath,
      errorMessage: this.state.errorMessage, committed: this.state.committed,
      skipped: this.state.skipped, failed: this.state.failed,
      localMatched: this.state.localMatched,
      localSessionMatched: this.state.localSessionMatched,
      localCandidateCount: this.state.localCandidateCount,
      onlineMatched: this.state.onlineMatched
    };
    AppStorage.setOrCreate(STORE_RESTORE_STATE, snap);
  }

  /** 重新授权 + 只读扫描 + 联网补全 → 停在 PREVIEW 等用户勾选 */
  async start(ctx: common.UIAbilityContext): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    this.token = { cancelled: false };
    this.gapMs = RESTORE_MIN_GAP_MS;
    this.riskRetry = 0;
    this.state = emptyRestoreState();
    this.state.phase = RestorePhase.AUTHORIZING;
    this.state.hint = '正在获取「下载/BiliMusic」目录授权…';
    this.notify();
    try {
      const uri: string = await ensureDirUri(ctx);
      if (uri.length === 0) {
        this.state.phase = RestorePhase.IDLE;
        this.state.hint = '';
        this.state.errorMessage = '未获得目录授权，未改动任何数据';
        this.notify();
        return;
      }
      // ⚠️ 必须一次 updateSettings 只写 URI，且**不动 saveToPublicDownloads**：
      // AppSettings 是单键整包 JSON，分开两次读-改-写会竞态互覆盖（历史 bug）。
      // 恢复 ≠ 用户同意今后自动搬移，开关保持原状。
      AppPreferences.updateSettings((s: AppSettings): void => {
        s.publicDownloadsDirUri = uri;
      });
      let dirPath: string = '';
      try {
        dirPath = new fileUri.FileUri(uri).path ?? '';
      } catch (e) {
        dirPath = '';
      }
      if (dirPath.length === 0) {
        this.state.phase = RestorePhase.IDLE;
        this.state.errorMessage = '目录地址解析失败，未改动任何数据';
        this.notify();
        return;
      }
      let exists: boolean = false;
      try {
        exists = await fs.access(dirPath);
      } catch (e) {
        exists = false;
      }
      if (!exists) {
        try {
          await fs.mkdir(dirPath, true);
        } catch (e2) {
          // 目录不存在且建不了：下面 listFileSync 会返回空，走「没有找到音频」即可
        }
      }
      this.state.dirPath = dirPath;
      this.state.phase = RestorePhase.SCANNING;
      this.state.hint = '正在列出音频文件…';
      this.notify();

      const existing: DownloadTask[] = await getAllDownloads();
      const items: RestoreItem[] = await scanPublicDir(dirPath, existing, this.token,
        (done: number, total: number, hint: string): void => {
          this.state.total = total;
          this.state.processed = done;
          this.state.hint = `正在检查：${hint}`;
          this.notify();
        });
      if (this.token.cancelled) {
        this.state.phase = RestorePhase.CANCELLED;
        this.state.hint = '扫描已中断，未改动任何数据';
        this.notify();
        return;
      }
      this.state.items = items;
      this.state.total = items.length;
      this.state.processed = 0;
      this.state.errorMessage = items.length === 0 ? '「下载/BiliMusic」里没有找到音频文件' : '';

      // ★ 离线优先层：已下载记录 / 曲库 → 拾音，全部命中后才轮到联网。
      // 只读本机数据，不发请求、不写任何库；命中者 category 改成 LOCAL_MATCH，
      // 下面 pending 自然只剩「本地确实没有身份」的文件。
      this.state.phase = RestorePhase.MATCHING;
      this.state.hint = '正在比对已下载记录与拾音数据…';
      this.notify();
      const localStat: LocalMatchStat = await applyLocalMatches(items, existing);
      this.state.localMatched = localStat.matched;
      this.state.localSessionMatched = localStat.fromSession;
      this.state.localCandidateCount = localStat.candidateCount;
      if (this.token.cancelled) {
        this.state.phase = RestorePhase.CANCELLED;
        this.state.hint = '扫描已中断，未改动任何数据';
        this.notify();
        return;
      }

      // 联网补全（最后兜底）：只对「无索引且本地也没匹配上」的条目搜索
      const pending: number[] = [];
      for (let i = 0; i < items.length; i++) {
        if (items[i].category === RestoreCategory.UNRECOGNIZED
          && items[i].source === RestoreSource.NONE) {
          pending.push(i);
        }
      }
      // 可检索诊断：确认「本机优先」真的生效，以及还有多少首必须联网
      console.info(`[RestoreLocal] candidates=${localStat.candidateCount} `
        + `matched=${localStat.matched} library=${localStat.matched - localStat.fromSession} `
        + `session=${localStat.fromSession} pendingOnline=${pending.length}`);
      this.state.hint = pending.length > 0
        ? `本机数据命中 ${localStat.matched} 首，其余 ${pending.length} 首联网按标题补全…`
        : `本机数据已补全 ${localStat.matched} 首，无需联网`;
      this.notify();

      for (let p = 0; p < pending.length; p++) {
        if (this.token.cancelled) {
          break;
        }
        const idx: number = pending[p];
        const item: RestoreItem = items[idx];
        this.state.hint = `正在匹配：${item.fileName}`;
        this.state.processed = p + 1;
        this.notify();
        const outcome: SearchOutcome = await resolveBySearch(item);
        if (item.category === RestoreCategory.SEARCHED) {
          this.state.onlineMatched++;
        }
        if (outcome.risk) {
          this.riskRetry++;
          if (this.riskRetry > RISK_RETRY_LIMIT) {
            this.state.phase = RestorePhase.RISK;
            this.state.hint = 'B 站搜索被限流，可稍后重新扫描继续';
            this.notify();
            return;
          }
          this.gapMs = Math.min(RISK_GAP_MAX_MS, this.gapMs * 2);
          await this.cooldownWait(RISK_BACKOFF_BASE_MS * Math.pow(2, this.riskRetry - 1));
          if (this.token.cancelled) {
            break;
          }
          p--; // 退避结束后重试当前这一首
          this.notify();
          continue;
        }
        this.state.processed = p + 1;
        this.notify();
        if (p + 1 < pending.length) {
          await sleep(this.gapMs);
        }
      }
      if (this.token.cancelled) {
        this.state.phase = RestorePhase.CANCELLED;
        this.state.hint = '扫描已中断，未改动任何数据';
      } else {
        this.state.phase = RestorePhase.PREVIEW;
        this.state.hint = '';
      }
      console.info(`[RestoreLocal] onlineMatched=${this.state.onlineMatched} `
        + `localMatched=${this.state.localMatched}`);
      this.notify();
    } catch (e) {
      this.state.phase = RestorePhase.IDLE;
      this.state.errorMessage = `扫描失败：${e instanceof Error ? e.message : JSON.stringify(e)}`;
      this.state.hint = '';
      this.notify();
    } finally {
      this.running = false;
    }
  }

  /** 风控退避：分段 sleep + 刷新倒计时；期间 phase 保持 MATCHING，页面不会误跳到报告 */
  private async cooldownWait(totalMs: number): Promise<void> {
    let left: number = totalMs;
    while (left > 0 && !this.token.cancelled) {
      const step: number = Math.min(BACKOFF_TICK_MS, left);
      const sec: number = Math.ceil(left / 1000);
      const mm: number = Math.floor(sec / 60);
      const clock: string = mm > 0 ? `${mm} 分 ${sec % 60} 秒` : `${sec} 秒`;
      this.state.hint = `搜索被限流，${clock}后自动继续（已处理 ${this.state.processed}/${this.state.total}）`;
      this.state.phase = RestorePhase.MATCHING;
      this.notify();
      await sleep(step);
      left -= step;
    }
  }

  /** 用户点「取消」：已完成的补全结果保留，可重新扫描 */
  stop(): void {
    this.token.cancelled = true;
    if (!this.running) {
      this.state.phase = RestorePhase.IDLE;
      this.state.hint = '';
      this.notify();
    }
  }

  reset(): void {
    this.token.cancelled = true;
    this.state = emptyRestoreState();
    this.notify();
  }

  private findItem(id: string): RestoreItem | null {
    for (let i = 0; i < this.state.items.length; i++) {
      if (this.state.items[i].id === id) {
        return this.state.items[i];
      }
    }
    return null;
  }

  private canCheck(item: RestoreItem): boolean {
    return item.category !== RestoreCategory.CORRUPT && item.category !== RestoreCategory.DUPLICATE;
  }

  setChecked(id: string, checked: boolean): void {
    const item: RestoreItem | null = this.findItem(id);
    if (item === null || !this.canCheck(item)) {
      return;
    }
    item.checked = checked;
    this.notify();
  }

  setAllChecked(checked: boolean): void {
    for (let i = 0; i < this.state.items.length; i++) {
      if (this.canCheck(this.state.items[i])) {
        this.state.items[i].checked = checked;
      }
    }
    this.notify();
  }

  /** 预览里手动指定曲目（或从候选中改选） */
  setChosen(id: string, chosen: SearchResultItem): void {
    const item: RestoreItem | null = this.findItem(id);
    if (item === null) {
      return;
    }
    applyCandidate(item, chosen, true);
    this.notify();
  }

  /** 勾选且可写的条数（页面按钮文案用） */
  countChecked(): number {
    let n: number = 0;
    for (let i = 0; i < this.state.items.length; i++) {
      const it: RestoreItem = this.state.items[i];
      if (it.checked && this.canCheck(it)) {
        n++;
      }
    }
    return n;
  }

  /**
   * 阶段 B：只写 download_task + 为无索引的旧文件补 sidecar。
   * 不动歌单 / 最近播放 / 收藏 / 云同步数据，不删除或修改任何音频。
   */
  async commit(): Promise<void> {
    if (this.state.phase === RestorePhase.COMMITTING) {
      return;
    }
    const selected: RestoreItem[] = [];
    for (let i = 0; i < this.state.items.length; i++) {
      const it: RestoreItem = this.state.items[i];
      if (it.checked && this.canCheck(it)) {
        selected.push(it);
      }
    }
    this.state.phase = RestorePhase.COMMITTING;
    this.state.hint = `正在写入 ${selected.length} 条下载记录…`;
    this.notify();
    const tasks: DownloadTask[] = [];
    for (let i = 0; i < selected.length; i++) {
      tasks.push(buildDownloadTask(selected[i], i));
    }
    let committed: number = 0;
    try {
      committed = await DownloadManager.getInstance().applyRestoredDownloads(tasks);
    } catch (e) {
      this.state.failed = selected.length;
      this.state.errorMessage = `写入失败，未改动任何数据：${e instanceof Error ? e.message : JSON.stringify(e)}`;
      this.state.phase = RestorePhase.REPORT;
      this.state.hint = '';
      this.notify();
      return;
    }
    // 自愈：确认后为「没有随行索引」的文件补写一份，下次重装就不必再联网搜索。
    // 只新增索引文件，绝不触碰音频本体；失败只记日志，不影响已写入的记录。
    for (let i = 0; i < selected.length; i++) {
      if (selected[i].source !== RestoreSource.INDEX) {
        await writeIndex(selected[i].audioPath, tasks[i]);
      }
    }
    this.state.committed = committed;
    this.state.skipped = selected.length - committed;
    this.state.failed = 0;
    this.state.errorMessage = '';
    this.state.phase = RestorePhase.REPORT;
    this.state.hint = '';
    this.notify();
  }
}
