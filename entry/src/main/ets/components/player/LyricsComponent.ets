/**
 * 播放页歌词页（移植自 audio-interaction-master 的 LyricsComponent，数据源接 LyricsApi）。
 *
 * 结构（SM）：小封面 + 歌名/歌手头行 → Canvas LrcView（平滑滚动 + 渐隐遮罩）
 * → 底部控制区。LG / 折叠屏展开时走栅格分栏，控制区不随歌词渲染
 * （isShowControl 由宿主按布局传参）。
 *
 * 歌词数据流：LyricsApi.getLyricForTrack → LyricLine[]（行级时间轴，秒）
 * → LrcEntry[]（毫秒）。沿用原播放页的令牌 + 信息键机制：
 *   - 切歌 / 信息补全后，在途旧请求的结果必须丢弃（令牌）；
 *   - 「缺时长搜出的没有歌词」结论不可信，时长补回后清缓存重搜（信息键）。
 */

import { Track, LyricLine } from '../../model/MusicModels';
import { LyricsApi } from '../../api/LyricsApi';
import { StyleConstants } from '../../common/constants/StyleConstants';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { PlayerConstants } from '../../common/constants/PlayerConstants';
import { BreakpointType } from '../../common/utils/BreakpointSystem';
import { LrcView } from '../../lyric/LrcView';
import { LrcEntry } from '../../lyric/LrcEntry';
import { LyricScrollEffect, LyricTopPosition } from '../../lyric/LyricConst';
import { ControlAreaComponent } from './ControlAreaComponent';
import {
  STORE_CURRENT_TRACK,
  STORE_IS_PLAYING,
  STORE_PROGRESS,
  STORE_PLAYER_FOLD_FULL
} from '../../common/Constants';

@Component
export struct LyricsComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 播放进度（秒）：LrcView 要毫秒，传入时 ×1000 */
  @StorageLink(STORE_PROGRESS) time: number = 0;
  @StorageLink(STORE_PLAYER_FOLD_FULL) isFoldFull: boolean = false;
  @StorageLink(STORE_IS_PLAYING) isPlay: boolean = false;
  @StorageLink(STORE_CURRENT_TRACK) @Watch('onTrackChanged') currentTrack: Track | null = null;
  /** 是否随歌词渲染底部控制区（SM 歌词页 true；LG/折叠分栏布局 false，控制区在封面侧） */
  isShowControl: boolean = true;
  /** 歌词滚动效果（行级时间轴只支持 Line） */
  private lyricScrollEffect: LyricScrollEffect = LyricScrollEffect.Line;
  @State mLrcEntryList: Array<LrcEntry> = [];

  /** 同曲守卫：封面等字段异步补全不应重置歌词 */
  private lastTrackKey: string = '';
  /** 上一次真正发起歌词请求时的「信息键」（id + 标题 + 歌手 + 时长是否已知） */
  private lastLyricKey: string = '';
  /** 上一次发起歌词请求时是否已有时长（缺时长搜出来的「没有歌词」结论不可信） */
  private lastLyricHadDuration: boolean = false;
  /** 歌词请求令牌：切歌 / 信息补全后，在途的旧请求结果必须丢弃 */
  private lyricToken: number = 0;

  aboutToAppear(): void {
    this.onTrackChanged();
  }

  /**
   * 当前曲目的「信息键」：不能只拿 id 去重 —— 列表数据可能缺时长 / 标题，
   * 而歌词候选打分拿它们做加分项；音源解析补全后必须允许重搜。
   */
  private lyricKeyOf(track: Track): string {
    return `${track.id}|${track.title}|${track.artist}|${track.duration > 0 ? 'd' : 'n'}`;
  }

  onTrackChanged(): void {
    const track: Track | null = this.currentTrack;
    if (track === null) {
      this.lastTrackKey = '';
      this.lastLyricKey = '';
      this.lastLyricHadDuration = false;
      this.lyricToken++;
      this.mLrcEntryList = [];
      return;
    }
    const key: string = this.lyricKeyOf(track);
    if (key === this.lastLyricKey) {
      // 同一首、关键信息没变（例如只是封面被异步补全）→ 不重复请求
      return;
    }
    const hadDuration: boolean = this.lastLyricHadDuration;
    if (track.id !== this.lastTrackKey) {
      this.lastTrackKey = track.id;
      // 换歌立刻清空上一首的歌词，避免新歌词到达前显示错位内容
      this.mLrcEntryList = [];
    }
    this.lastLyricKey = key;
    this.lastLyricHadDuration = track.duration > 0;
    if (track.duration > 0 && !hadDuration) {
      // 上一次是拿「缺时长」的信息搜的，那次「查不到」的结论（miss 缓存）不可信
      LyricsApi.clearLyricCache(track.id);
    }
    this.loadLyrics();
  }

  private async loadLyrics(): Promise<void> {
    const track: Track | null = this.currentTrack;
    if (track === null) {
      this.mLrcEntryList = [];
      return;
    }
    // 歌词要经多轮网络往返，期间可能已切歌；令牌保证只采纳最后一次请求
    const token: number = ++this.lyricToken;
    try {
      const result = await LyricsApi.getLyricForTrack(track);
      if (token !== this.lyricToken) {
        return;
      }
      this.mLrcEntryList = result !== null ? this.toLrcEntries(result.lines) : [];
    } catch (err) {
      if (token !== this.lyricToken) {
        return;
      }
      const msg: string = err instanceof Error ? err.message : String(err);
      console.error(`Failed to load lyric: ${msg}`);
      this.mLrcEntryList = [];
    }
  }

  /** 行级时间轴（秒）→ LrcEntry（毫秒）；最后一行时长无限，唱完仍保持高亮 */
  private toLrcEntries(lines: LyricLine[]): LrcEntry[] {
    const out: LrcEntry[] = [];
    for (let i = 0; i < lines.length; i++) {
      const startMs: number = lines[i].time * 1000;
      const durMs: number = i < lines.length - 1
        ? lines[i + 1].time * 1000 - startMs
        : Number.MAX_VALUE;
      out.push({
        lineStartTime: startMs,
        lineDuration: durMs,
        lineWords: lines[i].text,
        words: []
      });
    }
    return out;
  }

  private coverUrl(): string {
    return this.currentTrack !== null ? this.currentTrack.coverUrl : '';
  }

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

  build() {
    Column() {
      if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_SM) {
        Row() {
          if (this.coverUrl().length > 0) {
            Image(this.coverUrl())
              .width($r('app.float.label_width_sm'))
              .height($r('app.float.label_width_sm'))
              .borderRadius($r('app.float.label_border'))
              .margin({ right: $r('app.float.label_margin_right') })
          }
          Column() {
            Text(this.titleText())
              .fontSize(new BreakpointType<Resource>({
                sm: $r('app.float.title_font_sm'),
                md: $r('app.float.title_font_md'),
                lg: $r('app.float.title_font_lg')
              }).getValue(this.currentBreakpoint))
              .fontColor(Color.White)
              .fontWeight(PlayerConstants.FONT_WEIGHT_700)
              .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.artistText())
              .fontSize(new BreakpointType<Resource>({
                sm: $r('app.float.singer_font_sm'),
                md: $r('app.float.singer_font_md'),
                lg: $r('app.float.singer_font_lg')
              }).getValue(this.currentBreakpoint))
              .fontColor($r('app.color.play_text_color'))
              .fontWeight(PlayerConstants.FONT_WEIGHT_500)
              .fontFamily(PlayerConstants.FONT_FAMILY_MEDIUM)
              .margin({ top: $r('app.float.singer_margin_top') })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width(StyleConstants.FULL_WIDTH)
        .justifyContent(FlexAlign.Start)
        .margin({
          top: new BreakpointType<Resource>({
            sm: $r('app.float.info_margin_top_sm'),
            md: $r('app.float.zero_margin'),
            lg: $r('app.float.zero_margin')
          }).getValue(this.currentBreakpoint),
          bottom: $r('app.float.info_margin_bottom')
        })
      }

      if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG) {
        Row() {
          GridRow({
            columns: { lg: BreakpointConstants.COLUMN_LYRIC_LG }
          }) {
            GridCol({
              span: { lg: BreakpointConstants.SPAN_LYRIC_LG },
              offset: BreakpointConstants.OFFSET_MD
            }) {
              Column() {
                LrcView({
                  lyricMilliSecondsTime: this.time * 1000,
                  mLrcEntryList: this.mLrcEntryList,
                  lyricScrollEffect: this.lyricScrollEffect,
                  isPlay: this.isPlay,
                  lyricTopPosition: LyricTopPosition.Middle
                })
                  .layoutWeight(1)
              }
            }
          }
        }
        .layoutWeight(1)
      } else {
        LrcView({
          lyricMilliSecondsTime: this.time * 1000,
          mLrcEntryList: this.mLrcEntryList,
          lyricScrollEffect: this.lyricScrollEffect,
          isPlay: this.isPlay,
          lyricTopPosition: LyricTopPosition.Middle
        })
          .layoutWeight(1)
      }

      if (this.isShowControl) {
        ControlAreaComponent()
          .margin({
            top: $r('app.float.control_lyric_margin'),
            bottom: $r('app.float.music_component_bottom')
          })
      }
    }
  }
}
