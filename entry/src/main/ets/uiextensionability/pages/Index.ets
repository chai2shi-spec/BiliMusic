/**
 * 2x2 播控卡溢出动效页（liveForm 扩展内容页，移植自 MusicCard 示例
 * uiextensionability/pages/Index.ets）。
 * requestOverflow 后 liveForm 扩展以本页渲染放大 1.5 倍的视觉区：
 * 黑胶 + 封面在 1.7s 内旋转放大（Friction 曲线，无限 Alternate 往返）。
 * 曲目信息由 CardLiveFormAbility 从播放快照经 sharedLocalStorage 传入。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { formInfo } from '@kit.FormKit';
import { downloadCoverToTemp } from '../../service/card/CardPayloadBuilder';
import {
  LIVE_CARD_RATIO,
  ANIMATE_COMPONENT_LEFT,
  ANIMATE_COMPONENT_BOTTOM
} from '../../widget/model/CardFormConstant';

const TAG: string = '[CardLiveForm]';
const END_SCALE: number = 1.4;
const END_XTRANSLATE: number = 30;
const END_YTRANSLATE: number = -40;
const ROTATE_ANGLE: number = 180;

let storage: LocalStorage = new LocalStorage();

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

@Entry(storage)
@Component
struct CardOverflowPage {
  @State title: string = '';
  @State singer: string = '';
  @State imageColorHex: string = 'fb7299';
  @State coverPath: string = '';
  @State hasCover: boolean = false;
  @State isCollected: boolean = false;
  @State columnScale: number = 1.0;
  @State rowTranslate: number = 0.0;
  @State columnTranslate: number = 0.0;
  @State rotateAngle: number = 0;
  private formWidth: number = 0;
  private formHeight: number = 0;
  private formLeft: number = 0;
  private formBottom: number = 0;
  private formRadius: number = 0;

  async aboutToAppear(): Promise<void> {
    hilog.info(0x0000, TAG, 'CardOverflowPage aboutToAppear');
    const localStorage: LocalStorage | undefined = this.getUIContext()?.getSharedLocalStorage();
    const formRect: formInfo.Rect | undefined = localStorage?.get<formInfo.Rect>('formRect');
    const borderRadius: number | undefined = localStorage?.get<number>('radius');
    this.title = localStorage?.get<string>('trackTitle') ?? '';
    this.singer = localStorage?.get<string>('trackArtist') ?? '';
    this.isCollected = localStorage?.get<boolean>('isCollected') ?? false;
    this.formWidth = formRect !== undefined ? formRect.width : 0;
    this.formHeight = formRect !== undefined ? formRect.height : 0;
    this.formLeft = formRect !== undefined ? formRect.left : 0;
    this.formBottom = formRect !== undefined
      ? formRect.height * LIVE_CARD_RATIO - formRect.top - formRect.height : 0;
    this.formRadius = borderRadius ?? 0;
    this.loadCover(localStorage?.get<string>('coverUrl') ?? '');
  }

  private loadCover(coverUrl: string): void {
    if (coverUrl.length === 0) {
      return;
    }
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    downloadCoverToTemp(context, coverUrl)
      .then((result): void => {
        if (result === null) {
          return;
        }
        this.coverPath = result.path;
        this.hasCover = true;
        this.imageColorHex = result.color.hex;
      })
      .catch((e: Error): void => {
        hilog.error(0x0000, TAG, `loadCover failed: ${e.message}`);
      });
  }

  private runEnlargeAnimation(): void {
    this.getUIContext().animateTo({
      duration: 1700,
      curve: Curve.Friction,
      delay: 100,
      iterations: -1,
      playMode: PlayMode.Alternate,
      expectedFrameRateRange: {
        min: 10,
        max: 120,
        expected: 60,
      }
    }, () => {
      this.columnScale = END_SCALE;
      this.columnTranslate = END_YTRANSLATE;
      this.rowTranslate = END_XTRANSLATE;
      this.rotateAngle = ROTATE_ANGLE;
    });
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
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
          .fontColor($r('sys.color.font_secondary'))
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

        SymbolGlyph($r('sys.symbol.pause_round_triangle_fill'))
          .fontSize(36)
          .symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE), true)
          .fontColor(['#E5FFFFFF'])
          .alignRules(PlayAlignRules)
      }
      .height(this.formHeight)
      .width(this.formWidth)
      .borderRadius(this.formRadius)
      .padding(12)
      .linearGradient({
        direction: GradientDirection.Bottom,
        repeating: false,
        colors: [[`#ff${this.imageColorHex}`, 0.0], [`#ff${this.imageColorHex}`, 0.5],
          [`#ff${this.imageColorHex}`, 1.0]]
      })
      .margin({
        left: this.formLeft,
        bottom: this.formBottom
      })

      Stack({ alignContent: Alignment.Center }) {
        Image($r('app.media.blackVinyl'))
          .height(88)
          .width(88)

        Button()
          .backgroundImage(this.hasCover ? this.coverPath : $r('app.media.card_default_cover'))
          .backgroundImageSize(ImageSize.Cover)
          .height(58)
          .width(58)
          .backgroundColor($r('sys.color.titlebar_icon_background_color'))
      }
      .alignRules(CoverAlignRules)
      .margin({
        left: ANIMATE_COMPONENT_LEFT,
        bottom: ANIMATE_COMPONENT_BOTTOM
      })
      .scale({
        x: this.columnScale,
        y: this.columnScale
      })
      .translate({
        x: this.columnTranslate,
        y: this.rowTranslate
      })
      .rotate({
        x: 0,
        y: 0,
        z: 1,
        angle: this.rotateAngle
      })
      .onAppear(() => {
        this.runEnlargeAnimation();
      })
    }
    .width('100%')
    .height('100%')
  }
}
