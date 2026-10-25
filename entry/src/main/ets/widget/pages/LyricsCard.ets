/**
 * 心动歌词卡片（静态卡，2*4 / 4*4，移植自 MusicCard 示例，BiliMusic 适配）。
 * 整卡 FormLink router 拉起应用进播放页；歌词为当前播放歌曲随机连续 4 行
 * （CardPayloadBuilder 推送），无歌词回落『纯音乐，请欣赏』。
 */

import { ENTRY_ABILITY, FormCarAction, RouterType } from '../model/CardFormConstant';

let storageUpdateCall1 = new LocalStorage();

@Entry(storageUpdateCall1)
@Component
struct LyricsCard {
  @LocalStorageProp('hasCover') hasCover: boolean = false;
  @LocalStorageProp('musicCover') musicCover: string = 'cover';
  @LocalStorageProp('imageColor') imageColor: string = 'rgba(251, 114, 153, 1)';
  @LocalStorageProp('lrcArray') lrcArray: Array<string> =
    ['纯音乐，请欣赏'];
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('title') title: string = 'Song Name';
  @LocalStorageProp('singer') singer: string = 'Singer';
  @LocalStorageProp('songId') songId: string = '1';

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
            ForEach(this.lrcArray, (item: string, index: number) => {
              Text(item)
                .fontSize(18)
                .fontWeight(700)
                .fontColor(Color.White)
                .lineHeight(30)
                .margin({ top: index === 0 ? 0 : 12 })
                .displayPriority(this.lrcArray.length - index)
            }, (item: string, index: number) => (item + index))
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Start)
          .padding({
            left: 16,
            right: 16,
            bottom: 16
          })

          Row() {
        Image(this.hasCover ? `memory://${this.musicCover}` : $r('app.media.card_default_cover'))
              .height(36)
              .width(36)
              .borderRadius(18)
            Text(this.title)
              .fontSize(14)
              .fontColor(Color.White)
              .fontWeight(700)
              .margin({
                left: 12
              })

            Divider()
              .vertical(false)
              .width(27)
              .strokeWidth(2)
              .color('#99FFFFFF')
              .lineCap(LineCapStyle.Round)
              .margin({
                left: 8,
                right: 8
              })

            Text(this.singer)
              .fontSize(12)
              .fontColor(Color.White)
              .opacity(0.6)
              .fontWeight(500)
          }
          .width('100%')
        }
        .padding(12)
        .backgroundImagePosition(Alignment.Start)
        .backgroundImageSize(ImageSize.Cover)
        .height('100%')
        .width('100%')
      }
      .backgroundColor(this.imageColor)
    }
  }
}
