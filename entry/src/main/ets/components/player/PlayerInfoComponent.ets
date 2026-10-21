/**
 * 播放页主体（移植自 audio-interaction-master 的 PlayerInfoComponent）。
 *
 * 沉浸式背景：网络封面下载为 PixelMap → effectKit 取主色调暗
 * （dealColor）做页面底色 + 模糊封面图打底；主色明度写入
 * STORE_PLAYER_BG_DARK，供顶栏投播按钮与状态栏内容色切换。
 *
 * 布局三分支（完整移植断点系统）：
 *   · 折叠屏展开（isFoldFull）→ 封面 / 歌词左右分栏；
 *   · MD/LG 断点 → 栅格分栏（封面 + 标题块 + 控制区 | 歌词）；
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
  STORE_LOGIN_REV,
  BILI_REFERER,
  PLAYER_TRANSITION_MS,
  STORE_PLAYER_OPEN,
  STORE_PLAYER_TRANSITIONING,
  AUDIO_Q_DOLBY,
  AUDIO_Q_HIRES,
  GEOMETRY_ID_PLAYER_SURFACE,
  PLAYER_SURFACE_RADIUS_END_VP,
  formatTrackQuality
} from '../../common/Constants';
import { HttpUtil } from '../../utils/HttpUtil';
import { getLoginUser, LoginUser } from '../../service/LoginStore';

/** blur 偶发失败的单次重试延迟（ms） */
const BLUR_RETRY_DELAY_MS: number = 300;
// ⚠️ 这里曾有 CONTENT_FADE_IN_DELAY_MS / CONTENT_FADE_IN_MS（整块内容层 60ms 延迟 + 180ms 淡入），
// 2026-10-21 真机首验后**删除**：整块淡入会把封面（CoverDisc，geometryTransition 一镜到底）
// 一起压成透明 —— 转场头 60ms 封面完全不可见，观感变成「一块背景矩形从迷你栏长开、
// 内容随后浮现」，而不是「迷你栏那块玻璃整块变大、封面飞出来」。
// 编辑者注意：**不要为了「避免内容浮在没长开的背景之外」把整块 opacity 加回来** ——
// 这个职责已由各层自带的分层入场承担：
//   · 顶栏   TopAreaComponent        → LAYER_DELAY_TOP(450)    + 250ms 淡入
//   · 标题块 MusicInfoComponent      → LAYER_DELAY_INFO(540)   + 250ms 淡入 + 10vp 上移
//   · 控制区 ControlAreaComponent    → LAYER_DELAY_CONTROL(660) + 250ms 淡入 + 10vp 上移
//   · 封面   CoverDiscComponent      → 刻意**不动**（形变由 geometryTransition 独占）
// 封面因此全程不透明：它以迷你栏唱片为起点飞行，本来就不会「浮在首页上」。

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
  /** 背景明暗（本组件取色写入 STORE_PLAYER_BG_DARK 后回读）：A7 标题块码率文案压深/提亮用 */
  @StorageProp(STORE_PLAYER_BG_DARK) isBgDark: boolean = true;
  /** 登录态版本号（A7 音质文案随登录/退出刷新，见 qualityText 的注释） */
  @StorageLink(STORE_LOGIN_REV) loginRev: number = 0;

  /**
   * 播放页展开态（打开主动画里写 true / Index.closePlayer 里写 false）：
   * 驱动背景面的 geometryTransition 配对 —— true 时本组件的全屏背景面出现、
   * PlayBar 迷你栏里的透明锚点消失，系统在「迷你栏真实视觉包围盒 ↔ 全屏」之间
   * 做几何插值（2026-10-21 起点偏左下根治，见 GEOMETRY_ID_PLAYER_SURFACE 注释）。
   */
  @StorageProp(STORE_PLAYER_OPEN) playerOpen: boolean = false;

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
  /** LG 左列标题块实测高（A7 后圆盘预算要一并减掉） */
  private lgTitleH: number = 0;

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

  /** 圆盘边长 = min(左列宽, 左列高 − 标题块 − 控制区)；预算为负退回宽度驱动 */
  private recomputeLgDisc(): void {
    if (this.lgColW <= 0 || this.lgColH <= 0 || this.lgCtrlH <= 0) {
      return;
    }
    const budget: number = this.lgColH - this.lgCtrlH - this.lgTitleH;
    this.lgDiscSize = budget > 0 ? Math.min(this.lgColW, budget) : this.lgColW;
  }

  /**
   * LG/MD 左列标题块取数（A7，2026-10-20 平板功能对齐）：与 MusicInfoComponent
   * 同口径复制，不抽共享组件 —— Swiper 页那套带分层入场动画（titleOpacity/
   * titleOffsetY）和自己的圆盘预算字段，抽公共层要把动画状态一起搬过来，
   * 得不偿失。数据源仍是 STORE_CURRENT_TRACK，不引入新数据。
   */
  private titleText(): string {
    const t: Track | null = this.currentTrack;
    if (t === null) {
      return '暂无播放内容';
    }
    return t.title.length > 0 ? t.title : '未知歌曲';
  }

  private artistText(): string {
    const t: Track | null = this.currentTrack;
    if (t === null) {
      return '—';
    }
    return t.artist.length > 0 ? t.artist : '未知歌手';
  }

  /** 音质回显文案（分档逻辑与 MusicInfoComponent.qualityText 完全一致） */
  private qualityText(): string {
    const t: Track | null = this.currentTrack;
    if (t === null) {
      return '';
    }
    // 本地文件：没有经过 playurl 解析，码率字段是 0。只标来源，不假装有码率。
    if (t.localFilePath !== undefined && t.localFilePath.length > 0) {
      return '本地文件';
    }
    const base: string = formatTrackQuality(t.audioQuality, t.audioBandwidth);
    if (base.length === 0) {
      return '';
    }
    // 高档位标签只在**非杜比/非 Hi-Res** 时补（那两档 label 本身就是音质名，再加会重复）
    const hiLabel: string = t.audioQuality === AUDIO_Q_HIRES ? ' · Hi-Res 无损'
      : (t.audioQuality === AUDIO_Q_DOLBY ? ' · 杜比全景声' : '');
    if (hiLabel.length > 0) {
      return `${base}${hiLabel}`;
    }
    // 会员状态在方法体内现算：loginRev（@StorageLink）随登录/退出递增触发重渲染，
    // 方法体随之重读（普通成员只在创建时初始化一次的经典坑，详见 MusicInfoComponent）。
    const loginUser: LoginUser | null = getLoginUser();
    const vip: number = loginUser !== null ? loginUser.vipStatus : 0;
    if (vip === 1) {
      return base;
    }
    return HttpUtil.getLoginCookie().length > 0
      ? `${base} · 大会员可听杜比 / 无损`
      : `${base} · 登录可解锁更高音质`;
  }

  /**
   * 打开主动画（2026-10-21 组件状态切换改版）：**唯一**的 animateTo，
   * 闭包内写 STORE_PLAYER_OPEN=true，同帧驱动两套 geometryTransition 配对 ——
   *   · 背景面：PlayBar 迷你栏透明锚点 if 消失 ↔ 本组件全屏背景面 if 出现 →
   *     系统在「迷你栏**真实视觉包围盒** ↔ 全屏」间几何插值（起点偏左下根治，
   *     跨 HDS 窗口坐标换算由系统完成，见 GEOMETRY_ID_PLAYER_SURFACE）；
   *   · 封面：PlayBar 迷你唱片 if 消失 ↔ CoverDisc 大唱片 if 出现 →
   *     页内配对飞行（圆→圆，独立于背景面）；
   *   · Index 页签图标 opacity 同步淡出（@StorageProp/@Watch 同帧翻转）。
   * 时长与曲线（PLAYER_TRANSITION_MS / fastOutSlowIn）即两套配对飞行时长。
   * onFinish 复位连点防护标志（PlayBar.openPlayer 置位）。
   *
   * ⚠️ 只在 onAppear 启动 —— 首帧已经按 playerOpen=false 画过（背景面未挂载），
   * 若改在 aboutToAppear 里 animateTo，配对出现会被同帧状态合批吃掉。
   *
   * 内容层的显现**不在这里**：顶栏 / 标题块 / 控制区各自由分层入场
   * （LAYER_DELAY_*，主动画基线 450ms 后依次淡入），封面刻意不动。
   */
  private playEnterTransition(): void {
    this.getUIContext().animateTo(
      {
        duration: PLAYER_TRANSITION_MS,
        curve: Curve.FastOutSlowIn,
        onFinish: (): void => {
          AppStorage.setOrCreate(STORE_PLAYER_TRANSITIONING, false);
        }
      },
      (): void => {
        AppStorage.setOrCreate(STORE_PLAYER_OPEN, true);
      }
    );
  }

  /** 封面 PixelMap 缓存（同曲复用，不重复下载） */
  private coverCache: image.PixelMap | undefined = undefined;
  private coverCacheId: string = '';
  /** 取色令牌：切歌后，在途的旧取色结果必须丢弃 */
  private colorToken: number = 0;
  /** 当前背景/配色已应用（或正在应用）的曲目 id；'' = 无。
   *  同曲对象重建（merge/点赞/重试/暂停→播放重载/单曲环绕）据此跳过重铺 */
  private themedId: string = '';
  private foldCallback: Callback<display.FoldDisplayMode> = (data: display.FoldDisplayMode): void => {
    this.isFoldFull = data === display.FoldDisplayMode.FOLD_DISPLAY_MODE_FULL;
    AppStorage.setOrCreate(STORE_PLAYER_FOLD_FULL, this.isFoldFull);
  };

  aboutToAppear(): void {
    // 背景面转场起点不再手动实测：geometryTransition 配对由系统换算
    // 迷你栏锚点的真实视觉包围盒（见 GEOMETRY_ID_PLAYER_SURFACE）。
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
      this.themedId = '';
      this.bgCover = '';
      this.imageColor = 'rgba(0, 0, 2, 1.00)';
      AppStorage.setOrCreate(STORE_PLAYER_BG_DARK, true);
      this.applyStatusBar(true);
      return;
    }
    // 同曲对象重建（merge/点赞/重试/暂停→播放重载/单曲环绕）：
    // 背景已就绪，直接跳过 —— 不重铺原图、不重跑取色+blur，
    // 消除「闪未模糊」窗口和 blur 偶发失败导致的持久消失。
    if (track.id === this.themedId && this.bgCover !== '') {
      return;
    }
    this.themedId = track.id;
    // 修复（2026-10-20 真机反馈「切歌时底部模糊瞬间消失再变回模糊」）：
    // 不再「先立刻铺原图」——bgCover 换成网络 URL 后，Image 在加载期间
    // 渲染空白，旧模糊背景瞬间消失；加载完又先显清晰原图、blur 完成后再
    // 跳一次模糊，形成「模糊 → 空白 → 清晰 → 模糊」的连环闪变。
    // 改为**保持旧模糊背景**，待新歌 blur PixelMap 就绪后一次性换装
    //（模糊 → 模糊，无闪变窗口）；下载 / blur 彻底失败时才把原图 URL
    // 铺上去兜底（见 applyTheme / tryBlur 的失败分支，宁可清晰不可挂错图）。
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
        // 下载失败兜底：此时背景上还没有任何新歌素材，铺原图 URL
        //（Image 自己的加载重试还在），避免长期挂着上一首的模糊背景
        if (token === this.colorToken) {
          this.bgCover = track.coverUrl;
        }
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

    this.tryBlur(pixel, token, false, track.coverUrl);
  }

  /**
   * 生成模糊背景并换上。blur 链路（createEffect/getEffectPixelMap）偶发失败
   * （GPU 繁忙/内存压力）：首次失败延迟重试一次（令牌校验防跨歌串台）；
   * 重试仍失败铺 fallbackUrl 原图兜底 —— 保证屏幕上至少是新歌封面
   *（清晰但正确，好过一直挂着上一首的模糊图）。
   */
  private tryBlur(pixel: image.PixelMap, token: number, isRetry: boolean, fallbackUrl: string): void {
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
          if (!isRetry) {
            this.delayBlurRetry(pixel, token, fallbackUrl);
          } else if (token === this.colorToken) {
            this.bgCover = fallbackUrl;
          }
        });
      return;
    }
    console.error('blur cover failed: createEffect returned null');
    if (!isRetry) {
      this.delayBlurRetry(pixel, token, fallbackUrl);
    } else if (token === this.colorToken) {
      this.bgCover = fallbackUrl;
    }
  }

  /** blur 失败后的单次延迟重试（令牌失效即放弃） */
  private delayBlurRetry(pixel: image.PixelMap, token: number, fallbackUrl: string): void {
    setTimeout((): void => {
      if (token === this.colorToken) {
        this.tryBlur(pixel, token, true, fallbackUrl);
      }
    }, BLUR_RETRY_DELAY_MS);
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
        // ── 背景面（2026-10-21 起点偏左下根治）：全屏沉浸层，经 geometryTransition
        // 与 PlayBar 迷你栏里的**透明锚点**配对 —— playerOpen 翻转（本组件
        // playEnterTransition / Index.closePlayer 的同一条 animateTo）时，系统在
        // 「迷你栏真实视觉包围盒 ↔ 全屏」间做几何插值，跨 HDS 窗口坐标换算由
        // 系统完成（getRectangleById 等应用侧 API 拿不到合成变换后的视觉几何）。
        // 内容层**不在这里**（它不跟着缩放，靠各层分层入场）。
        if (this.playerOpen) {
          Stack() {
            this.SurfaceLayers()
          }
          .width(StyleConstants.FULL_WIDTH)
          .height(StyleConstants.FULL_HEIGHT)
          .backgroundColor(this.imageColor)
          // 终点圆角（2026-10-21 展开过程四角圆角）：配对两端显式挂 borderRadius
          // 即参与 geometryTransition 形变 —— 飞行途中四角呈胶囊同款圆角（起点
          // 28vp，见 PlayBar 锚点），全屏静止态收平（0），不露底层页面底色。
          // SurfaceLayers 三层均 100% 有界，clip 不裁静止态内容。
          .borderRadius(PLAYER_SURFACE_RADIUS_END_VP)
          .clip(true)
          .geometryTransition(GEOMETRY_ID_PLAYER_SURFACE)
        }

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
        } else if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG
          || this.currentBreakpoint === BreakpointConstants.BREAKPOINT_MD) {
          // A8（2026-10-20 平板功能对齐）：MD 不再落手机 Swiper —— LG 栅格分栏
          // 的 GridRow 本就定义了 md 的列数/跨度（左列 span 4 | 歌词 span 4），
          // 600~840vp 窗口直接进分栏，与 LG 同一套布局逻辑。
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

                  // A7：左列补标题块（歌名 / 歌手 / 音质回显）—— 此前 LG 左列
                  // 只有封面 + 控制区，正在播什么完全不可见（歌词列的头部又被
                  // LyricsComponent 按 SM 门控关掉），对齐手机端播放页信息密度。
                  // 文案与字号和 MusicInfoComponent.MusicInfo 同口径；左列是
                  // SpaceBetween 布局，圆盘预算（recomputeLgDisc）已减掉本块高度。
                  Column() {
                    Text(this.titleText())
                      .fontSize(this.currentBreakpoint === BreakpointConstants.BREAKPOINT_MD
                        ? $r('app.float.title_font_play_md') : $r('app.float.title_font_play'))
                      .fontColor(Color.White)
                      .opacity(0.95)
                      .fontWeight(FontWeight.Bold)
                      .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })

                    Text(this.artistText())
                      .textAlign(TextAlign.Start)
                      .fontSize($r('app.float.font_fourteen'))
                      .fontColor('rgba(255, 255, 255, 0.55)')
                      .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
                      .margin({ top: $r('app.float.music_text_margin_top') })
                      .width(StyleConstants.FULL_WIDTH)
                      .fontWeight(FontWeight.Regular)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })

                    // 音质回显：空串 = 整行不渲染（正在解析音源 / 本地文件 / 无数据），
                    // 不占位不留空隙；rgba 配色随背景明暗压深/提亮（见 isBgDark）。
                    if (this.qualityText().length > 0) {
                      Text(this.qualityText())
                        .fontSize(11)
                        .fontColor(this.isBgDark ? 'rgba(255, 255, 255, 0.55)' : 'rgba(0, 0, 0, 0.55)')
                        .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width(StyleConstants.FULL_WIDTH)
                        .margin({ top: 6 })
                    }
                  }
                  .width(StyleConstants.FULL_WIDTH)
                  .margin({ top: $r('app.float.music_info_margin_top') })
                  .alignItems(HorizontalAlign.Start)
                  .onAreaChange((_old: Area, n: Area): void => {
                    this.lgTitleH = this.toVp(n.height);
                    this.recomputeLgDisc();
                  })

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
            // 边界回弹（2026-10-08）：Swiper 在当前 SDK 无 .edgeEffect 属性，
            // 但 loop(false) 模式下默认即 Spring 回弹，无需显式声明。

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
      // ⚠️ 这里**不能再挂整块 opacity**（2026-10-21 已删）：
      // 它会连封面一起淡掉，把「迷你栏变大 + 封面飞出」压成「背景块长开 + 内容浮现」。
      // 内容显现交给各层的分层入场；且本层一旦挂 translate/scale，
      // 共享元素（封面）的目标框还会被搬走 —— 只允许纯布局，不许 transform。
    }
    .height(StyleConstants.FULL_HEIGHT)
    .width(StyleConstants.FULL_WIDTH)
    // 主动画只能在 onAppear 启动（首帧已按 playerOpen=false 画过：背景面未挂载），
    // 见 playEnterTransition
    .onAppear((): void => {
      this.playEnterTransition();
    })
  }

  /**
   * 背景三层：模糊封面 / 渐变压深 / 噪点。
   *
   * 它们原来直接挂在页面根 Stack 上，现在收进「生长面」容器 —— 尺寸写 100%，
   * 随生长面一起被拉伸/裁剪。三者都是可拉伸的无文本图元，逐帧重排代价可忽略。
   */
  @Builder
  SurfaceLayers(): void {
    if (this.bgCover !== '') {
      Image(this.bgCover)
        .width(StyleConstants.FULL_WIDTH)
        .height(StyleConstants.FULL_HEIGHT)
        .objectFit(ImageFit.Cover)
        .opacity(0.5)
        // 背景图加载失败：摘掉自己，露出主题色底 + 渐变 + 噪点，不留白块。
        // 只在当前源仍是 URL 时清：blur 已就绪（bgCover 为 PixelMap）后，
        // 迟到的旧 URL 加载失败不允许把模糊背景整体抹掉（偶发消失的竞态面）。
        .onError((err: ImageError): void => {
          if (typeof this.bgCover === 'string') {
            this.bgCover = '';
            this.themedId = '';
          }
        })
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
  }
}
