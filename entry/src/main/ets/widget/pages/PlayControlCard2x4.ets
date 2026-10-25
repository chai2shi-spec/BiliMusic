/**
 * 音乐播控卡片 2x4（移植自 MusicCard 示例，BiliMusic 适配）。
 * 数据通道与 2x2 相同；封面图区 + 上一首/播放暂停/下一首控制行。
 */

import ActionUtils from '../model/ActionUtils';
import { CollectAction, PlayActionType } from '../model/CardFormConstant';

const CollectAlignRules: Record<string, Record<string, string | VerticalAlign | HorizontalAlign>> = {
  'top': { 'anchor': '__container__', 'align': VerticalAlign.Top },
  'right': { 'anchor': '__container__', 'align': HorizontalAlign.End }
};

const TitleAlignRules: Record<string, Record<string, string | VerticalAlign | HorizontalAlign>> = {
  'left': { 'anchor': 'musicCover', 'align': HorizontalAlign.End }
};

const SingerAlignRules: Record<string, Record<string, string | VerticalAlign | HorizontalAlign>> = {
  'top': { 'anchor': 'musicTitle', 'align': VerticalAlign.Bottom },
  'left': { 'anchor': 'musicCover', 'align': HorizontalAlign.End }
};

const ControlAlignRules: Record<string, Record<string, string | VerticalAlign | HorizontalAlign>> = {
  'bottom': { 'anchor': '__container__', 'align': VerticalAlign.Bottom },
  'left': { 'anchor': 'musicCover', 'align': HorizontalAlign.End }
};

let storageUpdateCall = new LocalStorage();

@Entry(storageUpdateCall)
@Component
struct PlayControlCard2x4 {
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('isPlay') isPlay: boolean = false;
  @LocalStorageProp('title') title: string = 'SongName';
  @LocalStorageProp('isCollected') isCollected: boolean = false;
  @LocalStorageProp('hasCover') hasCover: boolean = false;
  @LocalStorageProp('musicCover') musicCover: string = 'cover';
  @LocalStorageProp('singer') singer: string = 'Singer';
  @LocalStorageProp('songId') songId: string = '';
  @LocalStorageProp('imageColorHex') imageColorHex: string = 'fb7299';

  build() {
    RelativeContainer() {
      Image(this.hasCover ? `memory://${this.musicCover}` : $r('app.media.card_default_cover'))
        .height('100%')
        .borderRadius(10)
        .aspectRatio(1)
        .id('musicCover')
        .onClick(() => {
          ActionUtils.jumpPlayPage(this);
        })

      SymbolGlyph(this.isCollected ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
        .fontSize(24)
        .symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE), true)
        .fontColor(['#E5FFFFFF'])
        .alignRules(CollectAlignRules)
        .onClick(() => {
          if (this.isCollected) {
            ActionUtils.collectAction(this, CollectAction.UNCOLLECTED, this.formId, this.songId);
          } else {
            ActionUtils.collectAction(this, CollectAction.COLLECTED, this.formId, this.songId);
          }
        })

      Text(this.title)
        .fontSize(16)
        .fontWeight(700)
        .fontColor(Color.White)
        .maxLines(1)
        .margin({
          top: 30,
          left: 24
        })
        .alignRules(TitleAlignRules)
        .id('musicTitle')

      Text(this.singer)
        .fontSize(14)
        .fontColor(Color.White)
        .fontWeight(500)
        .opacity(0.6)
        .maxLines(1)
        .alignSelf(ItemAlign.Start)
        .margin({
          top: 5,
          left: 24
        })
        .alignRules(SingerAlignRules)

      Row() {
        SymbolGlyph($r('sys.symbol.backward_end_fill'))
          .fontSize(24)
          .fontColor(['#E5FFFFFF'])
          .onClick(() => {
            ActionUtils.playByAction(this, PlayActionType.PREVIOUS, this.formId);
          })
        SymbolGlyph(this.isPlay ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
          .fontSize(24)
          .symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE), true)
          .fontColor(['#E5FFFFFF'])
          .margin({
            left: 25,
            right: 25
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
      .height(30)
      .margin({ left: 24 })
      .justifyContent(FlexAlign.SpaceBetween)
      .alignRules(ControlAlignRules)
    }
    .height('100%')
    .width('100%')
    .padding(12)
    .onClick(() => {
      ActionUtils.jumpPlayPage(this);
    })
    .linearGradient({
      direction: GradientDirection.Bottom,
      repeating: false,
      colors: [[`#ff${this.imageColorHex}`, 0.0], [`#cc${this.imageColorHex}`, 0.5], [`#ff${this.imageColorHex}`, 1.0]]
    })
  }
}
