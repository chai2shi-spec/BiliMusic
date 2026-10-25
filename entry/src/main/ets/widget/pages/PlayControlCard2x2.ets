/**
 * 音乐播控卡片 2x2（移植自 MusicCard 示例，BiliMusic 适配）。
 *
 * 数据通道：Form 进程 / UIAbility 进程经 formProvider.updateForm 推
 * LocalStorage 键（title / singer / isPlay / musicCover / formImages ...）。
 * 封面走 formImages fd（memory:// + musicCover 引用，imgKey 每次推送不同），
 * 无封面时回落本地默认图 card_default_cover（hasCover=false）。
 * 播放按钮点击（当前暂停 → 播放）时向 Form 扩展发 message 触发
 * 2x2 溢出互动动效（liveForm CardLiveFormAbility，放大 1.5 倍黑胶动画）。
 */

import ActionUtils from '../model/ActionUtils';
import { CollectAction, PlayActionType } from '../model/CardFormConstant';

const SingerAlignRules: Record<string, Record<string, string | VerticalAlign | HorizontalAlign>> = {
  'top': { 'anchor': 'musicTitle', 'align': VerticalAlign.Bottom },
  'left': { 'anchor': 'musicCover', 'align': HorizontalAlign.End }
};

const CollectAlignRules: Record<string, Record<string, string | VerticalAlign | HorizontalAlign>> = {
  'top': { 'anchor': '__container__', 'align': VerticalAlign.Top },
  'right': { 'anchor': '__container__', 'align': HorizontalAlign.End }
};

const CoverAlignRules: Record<string, Record<string, string | VerticalAlign | HorizontalAlign>> = {
  'bottom': { 'anchor': '__container__', 'align': VerticalAlign.Bottom }
};

const PlayAlignRules: Record<string, Record<string, string | VerticalAlign | HorizontalAlign>> = {
  'bottom': { 'anchor': '__container__', 'align': VerticalAlign.Bottom },
  'right': { 'anchor': '__container__', 'align': HorizontalAlign.End }
};

let storageUpdateCall = new LocalStorage();

@Entry(storageUpdateCall)
@Component
struct PlayControlCard2x2 {
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('isPlay') isPlay: boolean = false;
  @LocalStorageProp('title') title: string = 'Song Name';
  @LocalStorageProp('isCollected') isCollected: boolean = false;
  @LocalStorageProp('hasCover') hasCover: boolean = false;
  @LocalStorageProp('musicCover') musicCover: string = 'cover';
  @LocalStorageProp('singer') singer: string = 'Singer';
  @LocalStorageProp('songId') songId: string = '';
  @LocalStorageProp('imageColorHex') imageColorHex: string = 'fb7299';

  build() {
    RelativeContainer() {
      Text(this.title)
        .fontSize(14)
        .fontWeight(700)
        .width('85%')
        .fontColor(Color.White)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .maxLines(1)
        .id('musicTitle')

      Text(this.singer)
        .fontSize(12)
        .fontColor($r('sys.color.font_on_secondary'))
        .fontWeight(500)
        .maxLines(1)
        .alignRules(SingerAlignRules)
        .margin({ top: 2 })
        .id('singerText')

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

      Stack({ alignContent: Alignment.Center }) {
        Image($r('app.media.blackVinyl'))
          .height(88)
          .width(88)

        Button()
          .backgroundImage(this.hasCover ? `memory://${this.musicCover}` : $r('app.media.card_default_cover'))
          .backgroundImageSize(ImageSize.Cover)
          .height(58)
          .width(58)
      }
      .alignRules(CoverAlignRules)

      SymbolGlyph(this.isPlay ? $r('sys.symbol.pause_round_triangle_fill') : $r('sys.symbol.play_round_triangle_fill'))
        .fontSize(36)
        .symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE), true)
        .fontColor(['#E5FFFFFF'])
        .alignRules(PlayAlignRules)
        .onClick(() => {
          if (this.isPlay) {
            ActionUtils.playByAction(this, PlayActionType.PAUSE, this.formId);
          } else {
            ActionUtils.playByAction(this, PlayActionType.PLAY, this.formId);
            ActionUtils.requestOverflow(this);
          }
        })
    }
    .height('100%')
    .width('100%')
    .linearGradient({
      direction: GradientDirection.Bottom,
      repeating: false,
      colors: [[`#ff${this.imageColorHex}`, 0.0], [`#ff${this.imageColorHex}`, 0.5], [`#ff${this.imageColorHex}`, 1.0]]
    })
    .padding(12)
    .onClick(() => {
      ActionUtils.jumpPlayPage(this);
    })
  }
}
