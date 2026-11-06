/**
 * 卡片发布器（UIAbility 进程单例）。
 *
 * AppContainer.initRest 末尾 attach：
 *  · 启动即全量回填 —— CardFormStore 里的每张卡按类型推一次完整载荷
 *    （快照 + 歌词 + 封面 + 主色），覆盖「应用启动时桌面卡片还停在旧数据」；
 *  · 订阅 MusicPlayer.cardSyncListeners（setStore 对
 *    CURRENT_TRACK / IS_PLAYING / PROGRESS / SLEEP_TIMER_END 四键通知）：
 *      换歌 → 全量刷新（AppStorage 实时快照，歌词缓存重置）——
 *        快照落盘晚于切歌通知数百 ms，读盘会慢一首，必须喂内存值；
 *      播放态 → 轻量推 isPlay（不重取封面）；
 *      进度（500ms 一拍）→ 1s 节流 + 歌词行索引变化才推动态歌词窗口
 *        （只影响 DynamicLyrics 卡；心动卡歌词固定随机 4 行，换歌才变）；
 *      定时停止 → 锁屏卡片轻量推 sleepOn + sleepText（读盘自给）。
 * Form 扩展进程（MusicCardFormAbility）不经过本类 —— 它自行调
 * CardPayloadBuilder.pushCardToForm（双进程自给）。
 */

import common from '@ohos.app.ability.common';
import { BusinessError } from '@kit.BasicServicesKit';
import { MusicPlayer } from '../../player/MusicPlayer';
import { Track, LyricResult, RepeatMode } from '../../model/MusicModels';
import {
  STORE_CURRENT_TRACK,
  STORE_IS_PLAYING,
  STORE_PROGRESS,
  STORE_DURATION,
  STORE_REPEAT_MODE,
  STORE_SLEEP_TIMER_END
} from '../../common/Constants';
import { CardFormStore, CardFormRecord } from './CardFormStore';
import { FormCardName } from '../../widget/model/CardFormConstant';
import {
  buildLyricWindow,
  fetchCardLyric,
  FORM_NOT_EXIST_CODE,
  pushCardToForm,
  pushLockCardStateToForm,
  pushLyricWindowToForm,
  pushPlayStatusToForm,
  pushProgressToForm
} from './CardPayloadBuilder';
import { PersistedPlayerState } from '../PlayerStateStore';

const TAG: string = 'CardPublisher';
/** 动态歌词推送节流（ms）：进度通知 500ms 一拍，卡片侧 1s 足够顺滑 */
const LYRIC_PUSH_THROTTLE_MS: number = 1000;

export class CardPublisher {
  private static instance: CardPublisher | null = null;

  static getInstance(): CardPublisher {
    if (CardPublisher.instance === null) {
      CardPublisher.instance = new CardPublisher();
    }
    return CardPublisher.instance;
  }

  private attached: boolean = false;
  private context: common.Context | null = null;
  /** 歌词缓存（会话级，换歌重取） */
  private lyric: LyricResult | null = null;
  private lyricTrackId: string = '';
  /** 上次推送的歌词行索引（变化才推） */
  private lastLineIndex: number = -1;
  /** 歌词窗口推送节流游标 */
  private lastLyricPushAt: number = 0;
  /** 歌词窗口异步推送进行中标志（防重入） */
  private lyricUpdating: boolean = false;
  /** 外屏卡进度异步推送进行中标志（防重入，链路独立于歌词窗口） */
  private progressUpdating: boolean = false;
  /** 全量刷新进行中标志（换歌瞬间防重复全量推） */
  private refreshing: boolean = false;
  private listener: (key: string) => void = (key: string): void => {
    this.onPlayerStoreChange(key);
  };

  /** AppContainer.initRest 末尾调用；幂等 */
  attach(context: common.Context): void {
    if (this.attached) {
      return;
    }
    this.attached = true;
    this.context = context;
    MusicPlayer.getInstance().addCardSyncListener(this.listener);
    // 启动回填走盘读（MusicPlayer 恢复时序未定，盘是权威冷启数据）
    this.refreshAll(false);
  }

  private onPlayerStoreChange(key: string): void {
    if (this.context === null) {
      return;
    }
    if (key === STORE_CURRENT_TRACK) {
      this.lyric = null;
      this.lyricTrackId = '';
      this.lastLineIndex = -1;
      // 换歌全量推必须喂内存实时快照：setStore 先写 AppStorage 后通知，
      // 通知时刻内存已是新曲；而 player_state.json 要等 switchSource 完成
      // （数百 ms）才由 savePlayerStateNow 落盘——此刻读盘只会拿到上一首，
      // 且全量推仅此一次机会（后续 IS_PLAYING/PROGRESS 都是轻量推，不带曲目），
      // 错过即「卡片慢一首」。
      this.refreshAll(true);
    } else if (key === STORE_IS_PLAYING) {
      this.pushPlayStatusAll();
    } else if (key === STORE_PROGRESS) {
      this.onProgressTick();
    } else if (key === STORE_SLEEP_TIMER_END) {
      // 定时停止开/关（含到点自动暂停）：锁屏卡片轻量推 sleepOn + sleepText。
      // 不依赖 MusicPlayer → CardPublisher 的直接调用，沿用 setStore 通知机制
      // 扩展，避免 MusicPlayer 反向依赖卡片层（循环导入）。
      this.pushLockCardState();
    }
  }

  /**
   * AppStorage 实时快照（换歌全量推数据源）。无当前曲返回 null（调用方
   * 传 null 给 pushCardToForm = 走盘兜底）。
   * currentIndex / isShuffled / repeatMode 卡片载荷不消费，仅按接口形状给值。
   * 已知无害残留：换歌瞬间 STORE_PROGRESS / STORE_IS_PLAYING 是切换前的旧值
   * （isPreparing 守卫期），只影响动态歌词卡首帧窗口与播放态首帧，prepare
   * 完成后 PROGRESS tick 与 IS_PLAYING 轻量推会在 ≤1s 内自我修正。
   */
  private liveState(): PersistedPlayerState | null {
    const track: Track | undefined = AppStorage.get<Track>(STORE_CURRENT_TRACK);
    if (track === undefined) {
      return null;
    }
    const state: PersistedPlayerState = {
      currentTrack: track,
      currentIndex: 0,
      progress: AppStorage.get<number>(STORE_PROGRESS) ?? 0,
      duration: AppStorage.get<number>(STORE_DURATION) ?? 0,
      repeatMode: AppStorage.get<RepeatMode>(STORE_REPEAT_MODE) ?? RepeatMode.NONE,
      isShuffled: false,
      isPlaying: AppStorage.get<boolean>(STORE_IS_PLAYING) ?? false,
      savedAt: Date.now()
    };
    return state;
  }

  /**
   * 全量回填：CardFormStore 里每张卡按类型推完整载荷。
   * useLiveState = true 走 AppStorage 实时快照（换歌通知触发）；
   * false 走盘读（启动回填——attach 时刻 MusicPlayer 恢复流程时序不确定，
   * 盘是权威冷启数据，与历史行为等价）。
   */
  private refreshAll(useLiveState: boolean): void {
    const context: common.Context | null = this.context;
    if (context === null || this.refreshing) {
      return;
    }
    this.refreshing = true;
    CardFormStore.getInstance().init(context)
      .then(async (): Promise<CardFormRecord[]> => CardFormStore.getInstance().queryAll())
      .then(async (records: CardFormRecord[]): Promise<void> => {
        for (let i = 0; i < records.length; i++) {
          const record: CardFormRecord = records[i];
          try {
            await pushCardToForm(context, record.formId, record.formName,
              useLiveState ? this.liveState() : null);
          } catch (e) {
            await this.pruneDeadForm(record.formId, e);
          }
        }
        console.info(`[${TAG}] refreshAll done, cards=${records.length}`);
      })
      .catch((e: Error): void => {
        console.error(`[${TAG}] refreshAll failed: ${e.message}`);
      })
      .then((): void => {
        this.refreshing = false;
      });
  }

  /** 播放态变化：全部播控卡 / 动态歌词卡轻量推 isPlay */
  private pushPlayStatusAll(): void {
    const context: common.Context | null = this.context;
    if (context === null) {
      return;
    }
    const isPlay: boolean = AppStorage.get<boolean>(STORE_IS_PLAYING) ?? false;
    CardFormStore.getInstance().init(context)
      .then(async (): Promise<CardFormRecord[]> => CardFormStore.getInstance().queryAll())
      .then(async (records: CardFormRecord[]): Promise<void> => {
        for (let i = 0; i < records.length; i++) {
          if (records[i].formName === FormCardName.LYRICS) {
            continue; // 心动卡无播控元素
          }
          try {
            await pushPlayStatusToForm(records[i].formId, isPlay);
          } catch (e) {
            await this.pruneDeadForm(records[i].formId, e);
          }
        }
      })
      .catch((e: Error): void => {
        console.error(`[${TAG}] pushPlayStatusAll failed: ${e.message}`);
      });
  }

  /** 进度节拍：1s 节流；动态歌词窗口（歌词行变化才推）+ 外屏卡进度（每节拍推） */
  private onProgressTick(): void {
    const context: common.Context | null = this.context;
    if (context === null) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastLyricPushAt < LYRIC_PUSH_THROTTLE_MS) {
      return;
    }
    this.lastLyricPushAt = now;
    const track: Track | undefined = AppStorage.get<Track>(STORE_CURRENT_TRACK);
    if (track === undefined) {
      return;
    }
    const progress: number = AppStorage.get<number>(STORE_PROGRESS) ?? 0;
    const duration: number = AppStorage.get<number>(STORE_DURATION) ?? 0;
    const isPlay: boolean = AppStorage.get<boolean>(STORE_IS_PLAYING) ?? false;
    if (!isPlay) {
      return; // 暂停不推（恢复播放后由下一拍补齐）
    }
    if (!this.lyricUpdating) {
      this.lyricUpdating = true;
      this.updateLyricWindow(context, track, progress, isPlay)
        .then((): void => {
          this.lyricUpdating = false;
        }, (): void => {
          this.lyricUpdating = false;
        });
    }
    // 外屏播控卡进度推送独立成链：歌词行索引不变时 updateLyricWindow 不推，
    // 进度条必须每节拍都走；两条链各自防重入，互不阻塞。
    if (!this.progressUpdating) {
      this.progressUpdating = true;
      this.updateFoldCardProgress(context, progress, duration, isPlay)
        .then((): void => {
          this.progressUpdating = false;
        }, (): void => {
          this.progressUpdating = false;
        });
    }
  }

  /** 外屏播控卡（PlayControlCardFold）进度轻量推送 */
  private async updateFoldCardProgress(context: common.Context, progress: number,
    duration: number, isPlay: boolean): Promise<void> {
    const records: CardFormRecord[] =
      await CardFormStore.getInstance().queryByName(FormCardName.CONTROL_FOLD);
    for (let i = 0; i < records.length; i++) {
      try {
        await pushProgressToForm(records[i].formId, progress, duration, isPlay);
      } catch (e) {
        await this.pruneDeadForm(records[i].formId, e);
      }
    }
  }

  /**
   * 锁屏卡片（LockScreenCard）定时停止态轻量推送：定时开 / 关 / 到点自动
   * 停时只推 sleepOn + sleepText（CardPayloadBuilder 读盘自给），不重取
   * 封面 / 快照。无锁屏卡片时 queryByName 空数组自然空转。
   */
  private async pushLockCardState(): Promise<void> {
    const context: common.Context | null = this.context;
    if (context === null) {
      return;
    }
    try {
      await CardFormStore.getInstance().init(context);
      const records: CardFormRecord[] =
        await CardFormStore.getInstance().queryByName(FormCardName.LOCK_SCREEN);
      for (let i = 0; i < records.length; i++) {
        try {
          await pushLockCardStateToForm(context, records[i].formId);
        } catch (e) {
          await this.pruneDeadForm(records[i].formId, e);
        }
      }
    } catch (e) {
      console.error(`[${TAG}] pushLockCardState failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    }
  }

  private async updateLyricWindow(context: common.Context, track: Track,
    progress: number, isPlay: boolean): Promise<void> {
    if (this.lyricTrackId !== track.id) {
      this.lyric = await fetchCardLyric(track);
      this.lyricTrackId = track.id;
      this.lastLineIndex = -1;
    }
    const win = buildLyricWindow(this.lyric, track, progress);
    if (win.index === this.lastLineIndex) {
      return;
    }
    this.lastLineIndex = win.index;
    const records: CardFormRecord[] =
      await CardFormStore.getInstance().queryByName(FormCardName.DYNAMIC_LYRICS);
    for (let i = 0; i < records.length; i++) {
      try {
        await pushLyricWindowToForm(records[i].formId, win.lines, 0, isPlay);
      } catch (e) {
        await this.pruneDeadForm(records[i].formId, e);
      }
    }
  }

  /**
   * 推送报「卡片不存在」（16501）→ 该 formId 的卡片已被用户从桌面移除而
   * 记录未及清理（onRemoveForm 竞态 / 未触达）：删除 CardFormStore 死记录，
   * 止血后续每次换歌 / 播放态 / 进度 / 歌词推送对同一路径的无效更新。
   * 其余错误已在推送出口记录日志，这里直接吞掉，不中断同批其余卡片。
   */
  private async pruneDeadForm(formId: string, e: Object): Promise<void> {
    const be: BusinessError = e as BusinessError;
    if (be.code !== FORM_NOT_EXIST_CODE) {
      return;
    }
    try {
      await CardFormStore.getInstance().remove(formId);
      console.info(`[${TAG}] dead form pruned: ${formId}`);
    } catch (rmErr) {
      console.error(`[${TAG}] prune dead form failed: ${JSON.stringify(rmErr)}`);
    }
  }
}
