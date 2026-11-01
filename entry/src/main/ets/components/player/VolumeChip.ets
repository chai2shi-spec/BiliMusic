/**
 * 单曲音量快捷入口（播放页功能行，「单曲音量入口」开关控制显隐）。
 *
 * 双态渲染：
 *   · 0dB（默认，无记录）—— 喇叭图标键；
 *   · ≠ 0dB —— 带符号 dB 文字片（倍速片同款样式，如 "+6dB" / "-10dB"）。
 *
 * 交互：点击弹**就近气泡**（bindPopup 锚在按钮上方），气泡内仅一条居中
 * 增益滑条（-30dB ↔ +30dB，1dB 步进，默认 0），拖动实时生效
 * （MusicPlayer.setTrackVolumeGain → setLoudnessGain：setVolume
 * 恒 ≤ 1.00 做不了放大）。拖回 0 = 恢复默认（删按曲记录）。增益按曲存
 * TrackVolumeStore（键 = musicId，文件 KV），切歌自动隔离 / 回播自动应用。
 *
 * 架构约定（SleepTimerChip 同款）：气泡与滑条交互的 @State 圈死在本组件
 * 子树内，不污染控制区；切歌（STORE_CURRENT_TRACK 变化）重查增益并收起
 * 气泡（气泡锚定的是切歌前那首的状态）。
 *
 * bindPopup 铁律与 bindMenu 同源：气泡与 onClick 挂点击落点的同一最深层
 * 节点；按压反馈用 onTouch 缩放（只回写状态不消费事件，不与点击手势竞争）。
 */

import { MusicPlayer } from '../../player/MusicPlayer';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { BreakpointType } from '../../common/utils/BreakpointSystem';
import { Track } from '../../model/MusicModels';
import { STORE_CURRENT_TRACK } from '../../common/Constants';
import { trackVolumeGainOf } from '../../service/TrackVolumeStore';
import { PRESS_ANIM_MS, PRESS_SCALE } from '../../common/constants/InteractionConstants';

/** 功能键图标与圆底尺寸（与 ControlAreaComponent 的 FUNC_* 保持一致：该处为模块私有不可跨文件引用） */
const FUNC_ICON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 22, md: 22, lg: 26 });
const FUNC_BUTTON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 40, md: 40, lg: 46 });
/** 带符号 dB 文字字号（缩进 40×40 等宽槽位；最长文案 "+30dB" 5 字符，11 号留有余量） */
const GAIN_FONT_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 11, md: 11, lg: 12 });
/** 气泡内容宽度（居中增益滑条独占） */
const POPUP_CONTENT_WIDTH: number = 264;
/** 增益滑条范围（dB，与 TrackVolumeStore 合法域一致：+30dB = 30 倍响，-30dB = 1/30；正增益超 setLoudnessGain API 上限 +24dB 的部分由 MusicPlayer 派发前钳到 +24dB 生效） */
const GAIN_MIN_DB: number = -30;
const GAIN_MAX_DB: number = 30;

@Component
export struct VolumeChip {
  /** 当前断点（Index 常驻注册写入）：图标 / 文字片尺寸取值用 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 当前曲（切歌重查按曲增益并收起气泡） */
  @StorageLink(STORE_CURRENT_TRACK) @Watch('onTrackChanged') currentTrack: Track | null = null;
  /** 当前曲音量增益（dB，0 = 默认原始音量，显示图标态；否则显示带符号文字片） */
  @State gainDb: number = 0;
  /** 气泡显隐（bindPopup 受控开关；onStateChange 双向同步，点外关闭自动回收） */
  @State popupShow: boolean = false;
  /** 按压反馈缩放（onTouch 驱动，不消费事件，与 onClick 共存） */
  @State pressScale: number = 1;

  aboutToAppear(): void {
    this.refreshGain();
  }

  /** 切歌：重查新曲增益（无记录 = 0 默认）并收起气泡（旧曲的气泡状态不再适用） */
  private onTrackChanged(): void {
    this.refreshGain();
    this.popupShow = false;
  }

  /** 重查当前曲在 TrackVolumeStore 的音量增益（dB；无曲 / 无记录 = 0） */
  private refreshGain(): void {
    const track: Track | null = this.currentTrack;
    this.gainDb = track === null ? 0 : trackVolumeGainOf(track.id);
  }

  /** 滑条拖动：实时应用到播放器（setTrackVolumeGain 内钳 ±30dB 并归一 1dB 网格） */
  private applyGain(db: number): void {
    this.gainDb = db;
    MusicPlayer.getInstance().setTrackVolumeGain(db);
  }

  build() {
    Column() {
      if (this.gainDb === 0) {
        // 默认态：喇叭图标（线面，与模式 / 下载等入口一致）
        SymbolGlyph($r('sys.symbol.speaker_wave_2'))
          .fontSize(FUNC_ICON_SIZE.getValue(this.currentBreakpoint))
          .fontColor([Color.White])
          .opacity(0.86)
      } else {
        // 已调增益：带符号 dB 文字片 —— 与图标键等宽槽位（40×40），垂直居中到同一中线
        Text(`${this.gainDb > 0 ? '+' : ''}${this.gainDb}dB`)
          .fontSize(GAIN_FONT_SIZE.getValue(this.currentBreakpoint))
          .width('100%')
          .maxLines(1)
          .textAlign(TextAlign.Center)
          .fontColor(Color.White)
          .opacity(0.86)
          .fontWeight(FontWeight.Medium)
      }
    }
    .width(FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint))
    .height(FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint))
    .justifyContent(FlexAlign.Center)
    .scale({ x: this.pressScale, y: this.pressScale })
    .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressScale = PRESS_SCALE;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressScale = 1;
      }
    })
    .onClick((): void => {
      this.popupShow = !this.popupShow;
    })
    .bindPopup(this.popupShow, {
      builder: this.VolumePopup,
      placement: Placement.Top,
      autoCancel: true,
      onStateChange: (state: PopupStateChangeParam): void => {
        // 点外关闭 / 系统收起时同步受控开关，否则再点按钮不弹（开关残留 true）
        this.popupShow = state.isVisible;
      }
    })
    .accessibilityText('单曲音量')
  }

  /** 就近气泡：仅一条居中增益滑条（-30dB ↔ +30dB，1dB 步进，默认 0，拖动实时生效，拖回 0 即恢复默认） */
  @Builder
  private VolumePopup(): void {
    Column() {
      Slider({
        value: this.gainDb,
        min: GAIN_MIN_DB,
        max: GAIN_MAX_DB,
        step: 1,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .showTips(true)
        .onChange((value: number, mode: SliderChangeMode): void => {
          // 拖动全程实时生效（Begin/Moving/End 同口径），松手即终值
          this.applyGain(value);
        })
    }
    .width(POPUP_CONTENT_WIDTH)
    .padding({ top: 6, bottom: 6 })
  }
}
