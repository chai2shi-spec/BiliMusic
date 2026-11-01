/**
 * 外屏播控卡片（小折叠折叠态外屏 / 普通手机桌面）。
 *
 * 小折叠折叠态外屏只承载 ArkTS 卡片（display.isFoldable() 对小折叠返回
 * false，应用无法自定义外屏界面），本卡片按圆形安全区设计：
 * 居中 Column 布局，内容约束在中部 ~80% 区域避开圆形裁切；
 * supportShapes = ["rect", "circle"]，rect 形态（普通手机 2x2）下同布局成立。
 *
 * 数据通道与 2x2 / 2x4 卡一致，另增 progress / duration（秒）两键，
 * 由 CardPublisher 进度节拍每秒轻量推送（pushProgressToForm）。
 * 内容取舍（用户确认）：封面 + 歌名/歌手 + 进度条/时间 + 三键，无收藏。
 */

import ActionUtils from '../model/ActionUtils';
import { PlayActionType } from '../model/CardFormConstant';

/** 秒数 → m:ss 文本（负数/NaN 一律归零） */
function formatTime(totalSeconds: number): string {
  const safe: number = Math.max(0, Math.floor(totalSeconds));
  const minutes: number = Math.floor(safe / 60);
  const seconds: number = safe % 60;
  const secText: string = seconds < 10 ? `0${seconds}` : `${seconds}`;
  return `${minutes}:${secText}`;
}

let storageUpdateCall = new LocalStorage();

@Entry(storageUpdateCall)
@Component
struct PlayControlCardFold {
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('isPlay') isPlay: boolean = false;
  @LocalStorageProp('title') title: string = 'Song Name';
  @LocalStorageProp('singer') singer: string = 'Singer';
  @LocalStorageProp('songId') songId: string = '';
  @LocalStorageProp('hasCover') hasCover: boolean = false;
  @LocalStorageProp('musicCover') musicCover: string = 'cover';
  @LocalStorageProp('imageColorHex') imageColorHex: string = 'fb7299';
  @LocalStorageProp('progress') progress: number = 0;
  @LocalStorageProp('duration') duration: number = 0;

  build() {
    Column({ space: 6 }) {
      Image(this.hasCover ? `memory://${this.musicCover}` : $r('app.media.card_default_cover'))
        .width('40%')
        .aspectRatio(1)
        .borderRadius('50%')
        .clip(true)
        .onClick(() => {
          ActionUtils.jumpPlayPage(this);
        })

      Text(this.title)
        .fontSize(15)
        .fontWeight(700)
        .fontColor(Color.White)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('82%')
        .textAlign(TextAlign.Center)
        .margin({ top: 4 })

      Text(this.singer)
        .fontSize(11)
        .fontWeight(500)
        .fontColor(Color.White)
        .opacity(0.6)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('82%')
        .textAlign(TextAlign.Center)

      Progress({ value: this.progress, total: Math.max(this.duration, 1), type: ProgressType.Linear })
        .width('78%')
        .style({ strokeWidth: 3 })
        .color('#FFFFFFFF')
        .backgroundColor('#33FFFFFF')
        .margin({ top: 4 })

      Row() {
        Text(formatTime(this.progress))
          .fontSize(9)
          .fontColor(Color.White)
          .opacity(0.7)
        Blank()
        Text(formatTime(this.duration))
          .fontSize(9)
          .fontColor(Color.White)
          .opacity(0.7)
      }
      .width('78%')

      Row({ space: 26 }) {
        SymbolGlyph($r('sys.symbol.backward_end_fill'))
          .fontSize(24)
          .fontColor(['#E5FFFFFF'])
          .onClick(() => {
            ActionUtils.playByAction(this, PlayActionType.PREVIOUS, this.formId);
          })

        SymbolGlyph(this.isPlay ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
          .fontSize(30)
          .symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE), true)
          .fontColor(['#E5FFFFFF'])
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
      .margin({ top: 2 })
    }
    .height('100%')
    .width('100%')
    .padding(10)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .linearGradient({
      direction: GradientDirection.Bottom,
      repeating: false,
      colors: [[`#ff${this.imageColorHex}`, 0.0], [`#cc${this.imageColorHex}`, 0.5], [`#ff${this.imageColorHex}`, 1.0]]
    })
    .onClick(() => {
      ActionUtils.jumpPlayPage(this);
    })
  }
}
