/**
 * 播放列表（队列）弹层内容（共享组件）。
 *
 * 原为 PlayerPage 内部的 QueueSheetContent @Builder，抽成独立组件复用。
 * 当前由 PlayerPage 的 bindSheet 挂载（底栏 PlayBar 不带队列按钮，
 * 队列入口只剩播放页控制栏的「播放列表」键）。
 *
 * 宿主约定：bindSheet 挂载本组件，并把弹层开关以 @Link showSheet 传入——
 * 点条目播放 / 清空列表后由内容侧置 false 关闭弹层。
 */

import { Track, RepeatMode } from '../model/MusicModels';
import { MusicPlayer } from '../player/MusicPlayer';
import { STORE_CURRENT_TRACK, STORE_QUEUE, STORE_REPEAT_MODE } from '../common/Constants';

const REPEAT_CYCLE: RepeatMode[] = [
  RepeatMode.NONE,
  RepeatMode.ALL,
  RepeatMode.ONE,
  RepeatMode.SHUFFLE
];

/** 模式 → 中文名。模块级纯函数：轮换时要在 setRepeatMode 前后都能取到名字。 */
export function repeatLabelOf(mode: RepeatMode): string {
  if (mode === RepeatMode.SHUFFLE) {
    return '随机播放';
  }
  if (mode === RepeatMode.ONE) {
    return '单曲循环';
  }
  if (mode === RepeatMode.ALL) {
    return '列表循环';
  }
  return '顺序播放';
}

/** 模式 → 图标。供播放页模式按钮与队列弹层顶部的模式药丸共用。 */
export function modeIconOf(mode: RepeatMode): Resource {
  if (mode === RepeatMode.SHUFFLE) {
    return $r('sys.symbol.shuffle');
  }
  if (mode === RepeatMode.ONE) {
    return $r('sys.symbol.repeat_1');
  }
  if (mode === RepeatMode.ALL) {
    return $r('sys.symbol.repeat');
  }
  return $r('sys.symbol.arrow_right');
}

export function nextRepeatMode(mode: RepeatMode): RepeatMode {
  let idx: number = REPEAT_CYCLE.indexOf(mode);
  if (idx < 0) {
    idx = 0;
  }
  return REPEAT_CYCLE[(idx + 1) % REPEAT_CYCLE.length];
}

@Component
export struct QueueSheet {
  @StorageLink(STORE_QUEUE) queue: Track[] = [];
  @StorageLink(STORE_CURRENT_TRACK) currentTrack: Track | null = null;
  @StorageLink(STORE_REPEAT_MODE) repeatMode: RepeatMode = RepeatMode.NONE;
  /** 宿主的弹层开关：点条目 / 清空后由本组件置 false 关闭 */
  @Link showSheet: boolean;

  private player: MusicPlayer = MusicPlayer.getInstance();

  private currentTrackId(): string {
    return this.currentTrack !== null ? this.currentTrack.id : '';
  }

  /**
   * 刻意保留系统 Toast 而不走全局 AppToast：本组件由 bindSheet 挂载，
   * 弹层渲染在页面内容之上的弹层系，页面级的 AppToast 会被整个盖住；
   * 系统提示层在一切之上，弹层内触发的反馈只有它能露出来。
   */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1200 });
    } catch (e) {
      // 提示失败不影响主流程
    }
  }

  private cycleRepeat(): void {
    const next: RepeatMode = nextRepeatMode(this.repeatMode);
    this.player.setRepeatMode(next);
    this.toast(`播放模式：${repeatLabelOf(next)}`);
  }

  /**
   * 「清除列表」二次确认。
   *
   * 清空队列会**连当前正在播的那首一起清掉并停播**（clearQueue 内部会 pause + 回收播放器），
   * 属于不可撤销的破坏性操作，所以必须先问一句，不能点一下就直接清。
   */
  private confirmClearQueue(): void {
    const count: number = this.queue.length;
    if (count === 0) {
      return;
    }
    this.getUIContext()
      .getPromptAction()
      .showDialog({
        title: '清除播放列表',
        message: `将清空 ${count} 首歌曲并停止播放。已加入歌单的歌曲不受影响。`,
        buttons: [
          { text: '取消', color: $r('app.color.text_secondary') },
          { text: '清除', color: $r('app.color.brand_deep') }
        ]
      })
      .then((resp): void => {
        if (resp.index !== 1) {
          return;
        }
        this.player.clearQueue();
        this.showSheet = false;
        this.toast('播放列表已清除');
      })
      .catch((e: Error): void => {
        console.error(`clear queue dialog failed: ${e.message}`);
      });
  }

  build() {
    Column() {
      Row() {
        Text(`播放列表(${this.queue.length})`)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
        Blank().layoutWeight(1)
        // 模式药丸：点一次切一个模式，比在播放页按图标更直观
        Row({ space: 4 }) {
          SymbolGlyph(modeIconOf(this.repeatMode))
            .fontSize(14)
            .fontColor([$r('app.color.bili_pink')])
          Text(repeatLabelOf(this.repeatMode))
            .fontSize(12)
            .fontColor($r('app.color.bili_pink'))
        }
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
        .borderRadius(12)
        .backgroundColor($r('sys.color.background_secondary'))
        .onClick((): void => {
          this.cycleRepeat();
        })
        // 清除列表：放在标题行最右侧（原关闭按钮的位置）。
        // 队列为空时不渲染 —— 没有东西可清，留一个能点的按钮只会让人以为坏了。
        if (this.queue.length > 0) {
          Text('清除列表')
            .fontSize(13)
            .fontColor($r('app.color.bili_pink'))
            .padding({ left: 10, right: 2, top: 4, bottom: 4 })
            .onClick((): void => {
              this.confirmClearQueue();
            })
        }
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 16, bottom: 12 })

      if (this.queue.length === 0) {
        Column() {
          Text('暂无歌曲')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .height(120)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.queue, (track: Track, index: number): void => {
            ListItem() {
              Row({ space: 10 }) {
                if (track.id === this.currentTrackId()) {
                  SymbolGlyph($r('sys.symbol.waveform'))
                    .fontSize(16)
                    .fontColor([$r('app.color.bili_pink')])
                    .width(24)
                } else {
                  Text(`${index + 1}`)
                    .fontSize(13)
                    .fontColor($r('sys.color.font_secondary'))
                    .width(24)
                    .textAlign(TextAlign.Center)
                }
                Image(track.coverUrl)
                  .width(40)
                  .height(40)
                  .borderRadius(6)
                  .objectFit(ImageFit.Cover)
                Column({ space: 2 }) {
                  Text(track.title)
                    .fontSize(14)
                    .fontColor($r('sys.color.font_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(track.artist)
                    .fontSize(11)
                    .fontColor($r('sys.color.font_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Row() {
                  SymbolGlyph($r('sys.symbol.xmark'))
                    .fontSize(14)
                    .fontColor([$r('sys.color.font_secondary')])
                }
                .width(28)
                .height(28)
                .justifyContent(FlexAlign.Center)
                .onClick((): void => {
                  this.player.removeFromQueue(track.id);
                })
              }
              .width('100%')
              .padding({ left: 24, right: 12, top: 8, bottom: 8 })
            }
            .onClick((): void => {
              this.player.playTrack(track);
              this.showSheet = false;
            })
          }, (track: Track): string => track.id)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
  }
}
