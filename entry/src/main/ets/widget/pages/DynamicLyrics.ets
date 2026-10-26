/**
 * 动态歌词卡片（2*4，移植自 MusicCard 示例，BiliMusic 适配）。
 * 歌词窗口（当前行 + 下一行）随播放进度实时推送（CardPublisher 1s 节流、
 * 歌词行变化才推）；控制行上一首/播放暂停/下一首走 call 拉起 EntryAbility。
 * 示例的 Image 播放/暂停图（ic_public_play/pause）本工程无资源，
 * 以 SymbolGlyph（sys.symbol.play_fill / pause）等价替换。
 */

import ActionUtils from '../model/ActionUtils';
import { ENTRY_ABILITY, FormCarAction, PlayActionType, RouterType } from '../model/CardFormConstant';

let storageUpdateCall1 = new LocalStorage();

@Entry(storageUpdateCall1)
@Component
struct DynamicLyrics {
  @LocalStorageProp('lrcArray') lrcArray: Array<string> =
    ['纯音乐，请欣赏'];
  @LocalStorageProp('currentLyricIndex') currentLyricIndex: number = 0;
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('isPlay') isPlay: boolean = false;
  @LocalStorageProp('title') title: string = 'Song Name';
  @LocalStorageProp('hasCover') hasCover: boolean = false;
  @LocalStorageProp('musicCover') musicCover: string = 'cover';
  @LocalStorageProp('songId') songId: string = '';
  @LocalStorageProp('imageColor') imageColor: string = 'rgba(251, 114, 153, 1)';

  build() {
    FormLink({
      action: FormCarAction.ROUTER,
      abilityName: ENTRY_ABILITY,
      params: {
        songId: this.songId,
        type: RouterType.LYRICS
      }
    }) {
      Stack() {
        Image(this.hasCover ? `memory://${this.musicCover}` : $r('app.media.card_default_cover'))
          .height('200%')
          .width('200%')
          .objectFit(ImageFit.Cover)
          .opacity(0.5)
          .blur(100)
        Column() {
          Column() {
            ForEach(this.lrcArray.slice(0, 2), (item: string, index: number) => {
              Text(item)
                .fontSize(index <= this.currentLyricIndex ? 16 : 13)
                .fontWeight(700)
                .fontColor(index <= this.currentLyricIndex ? Color.White : '#99FFFFFF')
                .lineHeight(30)
                .margin({ top: index === 0 ? 0 : 12 })
                .displayPriority(this.lrcArray.length - index)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.Smooth, tempo: 2 }))
            }, (item: string, index: number) => (item + index))
          }
          .layoutWeight(1)
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Start)
          .padding({
            left: 16,
            right: 16,
            bottom: 10
          })

          Row() {
            Row() {
              Image(this.hasCover ? `memory://${this.musicCover}` : $r('app.media.card_default_cover'))
                .height(36)
                .width(36)
                .borderRadius(10)
              Text(this.title)
                .fontSize(14)
                .fontColor(Color.White)
                .fontWeight(700)
                .margin({
                  left: 12
                })
            }
            .width('40%')

            Row() {
              SymbolGlyph($r('sys.symbol.backward_end_fill'))
                .fontSize(24)
                .fontColor(['#E5FFFFFF'])
                .onClick(() => {
                  ActionUtils.playByAction(this, PlayActionType.PREVIOUS, this.formId);
                })
              SymbolGlyph(this.isPlay ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
                .fontSize(22)
                .symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE), true)
                .fontColor(['#E5FFFFFF'])
                .margin({
                  left: 20,
                  right: 20
                })
                .onClick(() => {
                  if (this.isPlay) {
                    ActionUtils.playByAction(this, PlayActionType.PAUSE, this.formId);
                  } else {
                    ActionUtils.playByAction(this, PlayActionType.PLAY, this.formId);
                  }
                })
              SymbolGlyph($r('sys.symbol.forward_end_fill'))
                .fontSize(24)
                .fontColor(['#E5FFFFFF'])
                .onClick(() => {
                  ActionUtils.playByAction(this, PlayActionType.NEXT, this.formId);
                })
            }
          }
          .width('100%')
          .height(50)
          .justifyContent(FlexAlign.SpaceBetween)
          .backgroundColor(this.imageColor)
          .opacity(0.8)
          .padding({
            top: 13,
            left: 10,
            right: 10,
            bottom: 10
          })
        }
        .backgroundImagePosition(Alignment.Start)
        .backgroundImageSize(ImageSize.Cover)
        .height('100%')
        .width('100%')
      }
      .backgroundColor(this.imageColor)
      .onClick(() => {
        ActionUtils.jumpPlayPage(this);
      })
    }
  }
}
