/**
 * 卡片发布器（UIAbility 进程单例）。
 *
 * AppContainer.initRest 末尾 attach：
 *  · 启动即全量回填 —— CardFormStore 里的每张卡按类型推一次完整载荷
 *    （快照 + 歌词 + 封面 + 主色），覆盖「应用启动时桌面卡片还停在旧数据」；
 *  · 订阅 MusicPlayer.cardSyncListeners（setStore 对
 *    CURRENT_TRACK / IS_PLAYING / PROGRESS 三键通知）：
 *      换歌 → 全量刷新（歌词缓存重置）；
 *      播放态 → 轻量推 isPlay（不重取封面）；
 *      进度（500ms 一拍）→ 1s 节流 + 歌词行索引变化才推动态歌词窗口
 *    （只影响 DynamicLyrics 卡；心动卡歌词固定随机 4 行，换歌才变）。
 * Form 扩展进程（MusicCardFormAbility）不经过本类 —— 它自行调
 * CardPayloadBuilder.pushCardToForm（双进程自给）。
 */

import common from '@ohos.app.ability.common';
import { MusicPlayer } from '../../player/MusicPlayer';
import { Track, LyricResult } from '../../model/MusicModels';
import { STORE_CURRENT_TRACK, STORE_IS_PLAYING, STORE_PROGRESS } from '../../common/Constants';
import { CardFormStore, CardFormRecord } from './CardFormStore';
import { FormCardName } from '../../widget/model/CardFormConstant';
import {
  buildLyricWindow,
  fetchCardLyric,
  pushCardToForm,
  pushLyricWindowToForm,
  pushPlayStatusToForm
} from './CardPayloadBuilder';

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
    this.refreshAll();
  }

  private onPlayerStoreChange(key: string): void {
    if (this.context === null) {
      return;
    }
    if (key === STORE_CURRENT_TRACK) {
      this.lyric = null;
      this.lyricTrackId = '';
      this.lastLineIndex = -1;
      this.refreshAll();
    } else if (key === STORE_IS_PLAYING) {
      this.pushPlayStatusAll();
    } else if (key === STORE_PROGRESS) {
      this.onProgressTick();
    }
  }

  /** 全量回填：CardFormStore 里每张卡按类型推完整载荷 */
  private refreshAll(): void {
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
          await pushCardToForm(context, record.formId, record.formName);
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
          await pushPlayStatusToForm(records[i].formId, isPlay);
        }
      })
      .catch((e: Error): void => {
        console.error(`[${TAG}] pushPlayStatusAll failed: ${e.message}`);
      });
  }

  /** 进度节拍：1s 节流 + 歌词行变化才推动态歌词窗口 */
  private onProgressTick(): void {
    const context: common.Context | null = this.context;
    if (context === null || this.lyricUpdating) {
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
    const isPlay: boolean = AppStorage.get<boolean>(STORE_IS_PLAYING) ?? false;
    if (!isPlay) {
      return; // 暂停不推（恢复播放后由下一拍补齐）
    }
    this.lyricUpdating = true;
    this.updateLyricWindow(context, track, progress, isPlay)
      .then((): void => {
        this.lyricUpdating = false;
      }, (): void => {
        this.lyricUpdating = false;
      });
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
      await pushLyricWindowToForm(records[i].formId, win.lines, 0, isPlay);
    }
  }
}
