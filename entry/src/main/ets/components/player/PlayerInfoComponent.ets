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
  AUDIO_Q_DOLBY,
  AUDIO_Q_HIRES,
  formatTrackQuality
} from '../../common/Constants';
import { HttpUtil } from '../../utils/HttpUtil';
import { getLoginUser, LoginUser } from '../../service/LoginStore';
import { NavStackHolder, PlayerEntranceRect } from '../../service/NavStackHolder';

/** blur 偶发失败的单次重试延迟（ms） */
const BLUR_RETRY_DELAY_MS: number = 300;
/**
 * 内容层（封面 / 标题 / 控制区 / 顶栏）在「容器长大」期间的淡入：延迟 + 时长（ms）。
 *
 * 为什么必须延迟：内容不属于生长面（它不跟着缩放，否则文字会逐帧变形），
 * 而是叠在生长面之上 —— 若一上来就全不透明，会看到文字浮在还没长开的
 * 小矩形之外、压在下面的首页上。先淡入 60ms 再渐变 180ms，
 * 让「面在长」和「内容浮现」在 300ms 内错峰完成，且封面（geometryTransition
 * 一镜到底）在中后段仍然可见，不破坏原有的唱片飞行观感。
 */
const CONTENT_FADE_IN_DELAY_MS: number = 60;
const CONTENT_FADE_IN_MS: number = 180;

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
   * 「容器长大」进度：1 = 全屏（常态）；0 = 完全贴合迷你栏矩形。
   * 从迷你栏进入时由 playEnterTransition 从 0 动画到 1；
   * 其余情况（无起点 / 测量失败）恒 1，页面就是普通全屏。
   */
  @State surfaceProgress: number = 1;
  /** 内容层（封面 / 标题 / 控制区 / 顶栏）不透明度：转场期间与生长面错峰淡入 */
  @State contentOpacity: number = 1;
  /** 本组件实测尺寸（vp = 窗口尺寸）：生长面的目标矩形（全屏）用 */
  @State winW: number = 0;
  @State winH: number = 0;
  /**
   * 转场起点矩形（迷你栏实测，vp）：aboutToAppear 从 NavStackHolder 取一份本地副本后
   * **立刻清空全局**（一次性语义，避免其它入口复用陈旧矩形）。
   * null = 无起点 → 不做生长动画，退回「整页淡入」的老转场。
   */
  private entrance: PlayerEntranceRect | null = null;

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

  // ───────────── 迷你栏 → 全屏 的「容器长大」几何（vp） ─────────────
  //
  // 生长面（背景层）用**布局属性**插值，不用 scale：非等比缩放会把圆角拉成椭圆、
  // 把背景图压扁；布局动画每帧只是一次轻量重排 —— 面里只有三张全屏背景层，
  // 没有文本，代价可忽略。
  // p=0 → 与迷你栏矩形完全重合（含胶囊圆角 h/2）；p=1 → 全屏、圆角 0。

  /** 生长进度（钳制到 0~1）；无起点时恒 1 = 全屏（退化到常态） */
  private growT(): number {
    if (this.entrance === null) {
      return 1;
    }
    return Math.min(1, Math.max(0, this.surfaceProgress));
  }

  /**
   * 目标全屏宽 / 高（vp）。
   * 实测值未到位时退回起点矩形的宽高 —— 保证首帧（p=0，只用到起点值）不会渲染出 0 尺寸。
   */
  private fullW(): number {
    if (this.winW > 0) {
      return this.winW;
    }
    const e: PlayerEntranceRect | null = this.entrance;
    return e !== null ? e.w : 0;
  }

  private fullH(): number {
    if (this.winH > 0) {
      return this.winH;
    }
    const e: PlayerEntranceRect | null = this.entrance;
    return e !== null ? e.h : 0;
  }

  private surfaceX(): number {
    const e: PlayerEntranceRect | null = this.entrance;
    return e !== null ? e.x * (1 - this.growT()) : 0;
  }

  private surfaceY(): number {
    const e: PlayerEntranceRect | null = this.entrance;
    return e !== null ? e.y * (1 - this.growT()) : 0;
  }

  private surfaceW(): number {
    const e: PlayerEntranceRect | null = this.entrance;
    const full: number = this.fullW();
    return e !== null ? e.w + (full - e.w) * this.growT() : full;
  }

  private surfaceH(): number {
    const e: PlayerEntranceRect | null = this.entrance;
    const full: number = this.fullH();
    return e !== null ? e.h + (full - e.h) * this.growT() : full;
  }

  /** 圆角：迷你栏是胶囊（h/2），全屏时为 0 */
  private surfaceRadius(): number {
    const e: PlayerEntranceRect | null = this.entrance;
    return e !== null ? (e.h / 2) * (1 - this.growT()) : 0;
  }

  /**
   * 进场：背景面从迷你栏矩形长到全屏 + 内容层错峰淡入。
   *
   * ⚠️ 只在这里（onAppear）启动 —— 首帧已经按 surfaceProgress=0 画过，
   * 若改在 aboutToAppear 里 animateTo，起点会被同帧状态合批吃掉，看不到生长。
   * 时长与封面 geometryTransition 严格一致（PLAYER_TRANSITION_MS），
   * 否则会出现「面已长满、封面还在飞」。曲线 EaseOut：起步快、落位稳。
   */
  private playEnterTransition(): void {
    if (this.entrance === null) {
      return;
    }
    this.getUIContext().animateTo(
      { duration: PLAYER_TRANSITION_MS, curve: Curve.EaseOut },
      (): void => {
        this.surfaceProgress = 1;
      }
    );
    this.getUIContext().animateTo(
      { duration: CONTENT_FADE_IN_MS, delay: CONTENT_FADE_IN_DELAY_MS, curve: Curve.EaseOut },
      (): void => {
        this.contentOpacity = 1;
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
    // 转场起点（点击迷你栏时 PlayBar 实测写入）。
    // ⚠️ 这里**不清空**它：PlayerPage 的 customTransition 也要读同一个值来判断
    // 走「容器长大」还是「整页淡入」，而两者的先后顺序没有保证（谁先跑都可能）。
    // 生命周期由 PlayerPage.aboutToDisappear 统一清空。
    const startRect: PlayerEntranceRect | null = NavStackHolder.playerEntranceRect;
    if (startRect !== null && startRect.w > 0 && startRect.h > 0) {
      this.entrance = startRect;
      this.surfaceProgress = 0;
      this.contentOpacity = 0;
      console.info(`[PlayerInfo] grow from x=${startRect.x}, y=${startRect.y}, w=${startRect.w}, h=${startRect.h}`);
    }
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
      // ── 生长面（背景层）：转场时从迷你栏矩形长到全屏，平时就是全屏背景 ──
      // 三张背景层放进一个**裁剪**容器：生长过程中圆角外的一切被裁掉，观感就是
      // 「迷你栏那块玻璃被拉开」。内容层**不在这里**（它不跟着缩放，见 contentOpacity）。
      Stack() {
        this.SurfaceLayers()
      }
      .width(this.surfaceW())
      .height(this.surfaceH())
      .position({ x: this.surfaceX(), y: this.surfaceY() })
      .borderRadius(this.surfaceRadius())
      .clip(true)
      .backgroundColor(this.imageColor)

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
      // 内容层随生长面错峰淡入（封面 geometryTransition 不受影响：这里只有 opacity，
      // 没有任何 transform / 布局动画 —— 一旦挂 translate/scale，共享元素目标框会被搬走）
      .opacity(this.contentOpacity)
    }
    .height(StyleConstants.FULL_HEIGHT)
    .width(StyleConstants.FULL_WIDTH)
    // 窗口尺寸实测：生长面的目标矩形（全屏）用它。这里不是 HDS 托管内容，
    // 布局回调写状态是安全的（MusicInfoComponent 的圆盘预算同理）。
    .onAreaChange((_old: Area, n: Area): void => {
      this.winW = this.toVp(n.width);
      this.winH = this.toVp(n.height);
    })
    // 生长动画只能在 onAppear 启动（首帧已按 surfaceProgress=0 画过），见 playEnterTransition
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
