/**
 * 播放页主体（移植自 audio-interaction-master 的 PlayerInfoComponent）。
 *
 * 沉浸式背景：网络封面下载为 PixelMap → effectKit 取主色调暗
 * （dealColor）做页面底色 + 模糊封面图打底；主色明度写入
 * STORE_PLAYER_BG_DARK，供顶栏投播按钮与状态栏内容色切换。
 *
 * 布局三分支（完整移植断点系统）：
 *   · 折叠屏展开（isFoldFull）→ 封面 / 歌词左右分栏；
 *   · LG 断点 → 栅格分栏（封面+控制区 | 歌词）；
 *   · SM 断点 → Swiper 双页（封面页 | 歌词页）+ 顶栏叠加。
 *
 * 安全区：STORE_SAFE_TOP / STORE_SAFE_BOTTOM（全屏布局方案，见 Constants.ts 注释）。
 */

import { effectKit } from '@kit.ArkGraphics2D';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Track } from '../../model/MusicModels';
import { PlayerConstants } from '../../common/constants/PlayerConstants';
import { ColorConversion } from '../../common/utils/ColorConversion';
import { StyleConstants } from '../../common/constants/StyleConstants';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { LyricsComponent } from './LyricsComponent';
import { TopAreaComponent } from './TopAreaComponent';
import { MusicInfoComponent } from './MusicInfoComponent';
import { ControlAreaComponent } from './ControlAreaComponent';
import { CoverDiscComponent } from './CoverDiscComponent';
import {
  STORE_CURRENT_TRACK,
  STORE_SAFE_TOP,
  STORE_SAFE_BOTTOM,
  STORE_PLAYER_BG_DARK,
  STORE_PLAYER_FOLD_FULL,
  BILI_REFERER
} from '../../common/Constants';

@Component
export struct PlayerInfoComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageLink(STORE_CURRENT_TRACK) @Watch('onTrackChanged') currentTrack: Track | null = null;
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 沉浸背景主色（取自封面，取色失败保持默认深色） */
  @State imageColor: string = 'rgba(0, 0, 2, 1.00)';
  /** 背景图：取色成功前显示原图，成功后换模糊图 */
  @State bgCover: PixelMap | string = '';
  @State isFoldFull: boolean = false;

  /**
   * LG 分栏左列圆盘边长上限（vp）：0 = 首帧未实测（宽度驱动，实测后收敛）。
   * 与 MusicInfoComponent 同一套「高度预算」思路，防止矮屏（横屏平板）上
   * 宽度驱动的圆盘把控制区挤出屏幕底部。
   */
  @State lgDiscSize: number = 0;
  /** LG 左列 / 控制区实测尺寸（onAreaChange 回写） */
  private lgColW: number = 0;
  private lgColH: number = 0;
  private lgCtrlH: number = 0;

  /** Area 尺寸（Length）→ vp 数值（资源型按 0 兜底） */
  private toVp(v: Length): number {
    if (typeof v === 'number') {
      return v;
    }
    if (typeof v === 'string') {
      return parseFloat(v);
    }
    return 0;
  }

  /** 圆盘边长 = min(左列宽, 左列高 − 控制区)；预算为负退回宽度驱动 */
  private recomputeLgDisc(): void {
    if (this.lgColW <= 0 || this.lgColH <= 0 || this.lgCtrlH <= 0) {
      return;
    }
    this.lgDiscSize = Math.min(this.lgColW, this.lgColH - this.lgCtrlH);
  }

  /** 封面 PixelMap 缓存（同曲复用，不重复下载） */
  private coverCache: image.PixelMap | undefined = undefined;
  private coverCacheId: string = '';
  /** 取色令牌：切歌后，在途的旧取色结果必须丢弃 */
  private colorToken: number = 0;
  private foldCallback: Callback<display.FoldDisplayMode> = (data: display.FoldDisplayMode): void => {
    this.isFoldFull = data === display.FoldDisplayMode.FOLD_DISPLAY_MODE_FULL;
    AppStorage.setOrCreate(STORE_PLAYER_FOLD_FULL, this.isFoldFull);
  };

  aboutToAppear(): void {
    this.onTrackChanged();
    try {
      if (canIUse('SystemCapability.Window.SessionManager')) {
        const mode: display.FoldDisplayMode = display.getFoldDisplayMode();
        this.isFoldFull = mode === display.FoldDisplayMode.FOLD_DISPLAY_MODE_FULL;
        AppStorage.setOrCreate(STORE_PLAYER_FOLD_FULL, this.isFoldFull);
        display.on('foldDisplayModeChange', this.foldCallback);
      }
    } catch (e) {
      console.error(`Failed to register fold callback: ${JSON.stringify(e)}`);
    }
  }

  aboutToDisappear(): void {
    try {
      if (canIUse('SystemCapability.Window.SessionManager')) {
        display.off('foldDisplayModeChange', this.foldCallback);
      }
    } catch (e) {
      console.error(`Failed to unregister fold callback: ${JSON.stringify(e)}`);
    }
  }

  onTrackChanged(): void {
    const track: Track | null = this.currentTrack;
    if (track === null || track.coverUrl.length === 0) {
      this.colorToken++;
      this.bgCover = '';
      this.imageColor = 'rgba(0, 0, 2, 1.00)';
      AppStorage.setOrCreate(STORE_PLAYER_BG_DARK, true);
      this.applyStatusBar(true);
      return;
    }
    // 先立刻铺原图，取色完成后再换成「主色底 + 模糊图」
    this.bgCover = track.coverUrl;
    this.applyTheme(track);
  }

  /** 取主色 + 生成模糊背景（异步，令牌防串台） */
  private async applyTheme(track: Track): Promise<void> {
    const token: number = ++this.colorToken;
    let pixel: image.PixelMap | undefined = undefined;
    if (this.coverCacheId === track.id && this.coverCache !== undefined) {
      pixel = this.coverCache;
    } else {
      const loaded: image.PixelMap | null = await this.loadCoverPixelMap(track.coverUrl);
      if (loaded === null) {
        return;
      }
      this.coverCache = loaded;
      this.coverCacheId = track.id;
      pixel = loaded;
    }
    if (token !== this.colorToken) {
      return;
    }

    // 主色 → 调暗做底色；明度写入全局（顶栏图标 / 状态栏内容色消费）
    effectKit.createColorPicker(pixel)
      .then((picker: effectKit.ColorPicker): void => {
        if (token !== this.colorToken) {
          return;
        }
        const color: effectKit.Color = picker.getLargestProportionColor();
        const arr: number[] = ColorConversion.dealColor(color.red, color.green, color.blue);
        this.imageColor = `rgba(${arr[0]}, ${arr[1]}, ${arr[2]}, 1)`;
        const luminance: number = (0.299 * arr[0] + 0.587 * arr[1] + 0.114 * arr[2]) / 255;
        const isDark: boolean = luminance < 0.5;
        AppStorage.setOrCreate(STORE_PLAYER_BG_DARK, isDark);
        this.applyStatusBar(isDark);
      })
      .catch((e: BusinessError): void => {
        console.error(`createColorPicker failed: ${e.code} ${e.message}`);
      });

    const headFilter: effectKit.Filter | null = effectKit.createEffect(pixel);
    if (headFilter !== null) {
      headFilter.blur(PlayerConstants.IMAGE_BLUR);
      headFilter.getEffectPixelMap()
        .then((blurred: image.PixelMap): void => {
          if (token !== this.colorToken) {
            return;
          }
          this.bgCover = blurred;
        })
        .catch((e: BusinessError): void => {
          console.error(`blur cover failed: ${e.code} ${e.message}`);
        });
    }
  }

  /** 网络封面 → PixelMap（B 站图床要带 Referer，同 MusicPlayer 的实现） */
  private async loadCoverPixelMap(url: string): Promise<image.PixelMap | null> {
    const httpReq: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await httpReq.request(url, {
        method: http.RequestMethod.GET,
        header: { Referer: BILI_REFERER },
        connectTimeout: 10000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      if (resp.responseCode !== 200 || !resp.result) {
        return null;
      }
      if (!(resp.result instanceof ArrayBuffer)) {
        return null;
      }
      const src: image.ImageSource = image.createImageSource(resp.result);
      return await src.createPixelMap();
    } catch (e) {
      console.error(`loadCoverPixelMap failed: ${JSON.stringify(e)}`);
      return null;
    } finally {
      httpReq.destroy();
    }
  }

  /** 状态栏内容色随背景明暗切换（全屏布局下状态栏叠在背景上） */
  private applyStatusBar(isDarkBackground: boolean): void {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    ColorConversion.setStatusBarContentColor(ctx, isDarkBackground);
  }

  build() {
    Stack() {
      if (this.bgCover !== '') {
        Image(this.bgCover)
          .width(StyleConstants.FULL_WIDTH)
          .height(StyleConstants.FULL_HEIGHT)
          .objectFit(ImageFit.Cover)
          .opacity(0.5)
      }
      // 缓慢渐变底色：主色底上自上而下压深，底部最暗 —— 静态渐变不产生每帧开销
      Column()
        .width(StyleConstants.FULL_WIDTH)
        .height(StyleConstants.FULL_HEIGHT)
        .linearGradient({
          angle: 180,
          colors: [
            ['rgba(0, 0, 0, 0.05)', 0.0],
            ['rgba(0, 0, 0, 0.22)', 0.45],
            ['rgba(0, 0, 0, 0.45)', 1.0]
          ]
        })
      // 微弱噪点纹理：打破纯色渐变的塑料感，低透明度平铺，无逐帧成本
      Column()
        .width(StyleConstants.FULL_WIDTH)
        .height(StyleConstants.FULL_HEIGHT)
        .backgroundImage($r('app.media.noise_texture'), ImageRepeat.XY)
        .backgroundImageSize({ width: 128, height: 128 })
        .opacity(0.05)
      Row() {
        if (this.isFoldFull) {
          Column() {
            TopAreaComponent()
              .margin({
                bottom: $r('app.float.music_info_margin_top'),
                left: $r('app.float.top_margin_left')
              })
            GridRow({
              columns: { md: BreakpointConstants.COLUMN_MD },
              gutter: BreakpointConstants.GUTTER_MUSIC_X
            }) {
              GridCol({
                span: { md: BreakpointConstants.SPAN_SM }
              }) {
                MusicInfoComponent()
              }
              .margin({
                left: $r('app.float.margin_small'),
                right: $r('app.float.margin_small')
              })

              GridCol({
                span: { md: BreakpointConstants.SPAN_SM }
              }) {
                LyricsComponent({ isShowControl: false })
              }
              .padding({
                left: $r('app.float.twenty_four')
              })
            }
            .layoutWeight(1)
            .margin({
              bottom: $r('app.float.fold_margin_bottom')
            })
          }
          .layoutWeight(1)
          .padding({
            left: $r('app.float.common_padding'),
            right: $r('app.float.common_padding')
          })
        } else if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG) {
          Column() {
            TopAreaComponent()
              .padding({
                left: $r('app.float.common_padding'),
                right: $r('app.float.common_padding')
              })
            GridRow({
              columns: { md: BreakpointConstants.COLUMN_MD, lg: BreakpointConstants.COLUMN_LG },
              gutter: BreakpointConstants.GUTTER_MUSIC_X
            }) {
              GridCol({
                span: { md: BreakpointConstants.SPAN_SM, lg: BreakpointConstants.SPAN_SM },
                offset: { lg: BreakpointConstants.OFFSET_MD }
              }) {
                Column() {
                  Row() {
                    CoverDiscComponent({ discSize: this.lgDiscSize })
                  }
                  .width(StyleConstants.FULL_WIDTH)
                  .justifyContent(FlexAlign.Center)

                  Column() {
                    ControlAreaComponent()
                  }
                  .onAreaChange((_old: Area, n: Area): void => {
                    this.lgCtrlH = this.toVp(n.height);
                    this.recomputeLgDisc();
                  })
                }
                .height(StyleConstants.FULL_HEIGHT)
                .justifyContent(FlexAlign.SpaceBetween)
                .margin({
                  bottom: $r('app.float.common_margin')
                })
                .onAreaChange((_old: Area, n: Area): void => {
                  this.lgColW = this.toVp(n.width);
                  this.lgColH = this.toVp(n.height);
                  this.recomputeLgDisc();
                })
              }

              GridCol({
                span: { md: BreakpointConstants.SPAN_SM, lg: BreakpointConstants.SPAN_MD },
                offset: { lg: BreakpointConstants.OFFSET_MD }
              }) {
                LyricsComponent({ isShowControl: false })
              }
            }
            .layoutWeight(1)
            .padding({
              left: $r('app.float.common_padding'),
              right: $r('app.float.common_padding'),
              top: $r('app.float.lg_music_top'),
              bottom: $r('app.float.lg_music_margin_bottom')
            })
          }
        } else {
          Stack({ alignContent: Alignment.TopStart }) {
            Swiper() {
              MusicInfoComponent()
                .margin({
                  top: $r('app.float.music_component_top'),
                  bottom: $r('app.float.music_component_bottom')
                })
                .padding({
                  left: $r('app.float.common_padding'),
                  right: $r('app.float.common_padding')
                })
              LyricsComponent({ isShowControl: true })
                .margin({
                  top: $r('app.float.margin_lyric')
                })
                .padding({
                  left: $r('app.float.common_padding'),
                  right: $r('app.float.common_padding')
                })
            }
            .height(StyleConstants.FULL_HEIGHT)
            .indicator(
              new DotIndicator()
                .top($r('app.float.options_padding'))
                .selectedColor($r('app.color.select_swiper'))
                .color($r('app.color.slider_track'))
            )
            .clip(false)
            .loop(false)

            TopAreaComponent()
              .padding({
                left: $r('app.float.common_padding'),
                right: $r('app.float.common_padding')
              })
          }
          .height(StyleConstants.FULL_HEIGHT)
        }
      }
      .padding({
        top: this.safeTop,
        bottom: this.safeBottom
      })
    }
    .height(StyleConstants.FULL_HEIGHT)
    .width(StyleConstants.FULL_WIDTH)
    .backgroundColor(this.imageColor)
  }
}
