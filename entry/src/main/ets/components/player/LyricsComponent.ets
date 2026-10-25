/**
 * 播放页歌词页（数据源接 LyricsApi）。
 *
 * 结构（SM）：小封面 + 歌名/歌手头行 → Canvas LrcView（平滑滚动 + 渐隐遮罩）
 * → 底部控制区。LG / 折叠屏展开时走栅格分栏，控制区不随歌词渲染
 * （isShowControl 由宿主按布局传参）。
 *
 * 歌词数据流：LyricsApi.getLyricForTrack → LyricLine[]（行级时间轴，秒）
 * → LrcEntry[]（毫秒）。令牌 + 信息键机制：
 *   - 切歌 / 信息补全后，在途旧请求的结果必须丢弃（令牌）；
 *   - 「缺时长搜出的没有歌词」结论不可信，时长补回后信息键失配自动重搜
 *     （LyricsApi 内部 cacheKey 比对；不清缓存，manual 手选结果跨重启固定）。
 */

import { Track, LyricLine, LyricResult, LyricWord, LyricCandidate } from '../../model/MusicModels';
import { LyricsApi, sourceLabel } from '../../api/LyricsApi';
import { cleanTitle } from '../../utils/TextUtil';
import { StyleConstants } from '../../common/constants/StyleConstants';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { PlayerConstants } from '../../common/constants/PlayerConstants';
import { BreakpointType } from '../../common/utils/BreakpointSystem';
import { LrcView } from '../../lyric/LrcView';
import { LrcEntry, Word } from '../../lyric/LrcEntry';
import { LyricScrollEffect, LyricTopPosition } from '../../lyric/LyricConst';
import { ControlAreaComponent } from './ControlAreaComponent';
import {
  STORE_CURRENT_TRACK,
  STORE_IS_PLAYING,
  STORE_PROGRESS,
  STORE_FOLD_EXPANDED,
  STORE_PLAYER_OPEN,
  STORE_PLAYER_CONTENT_EXIT,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE
} from '../../common/Constants';
import {
  ENTRANCE_DURATION_MS,
  LAYER_DELAY_CONTROL,
  LAYER_EXIT_DURATION_MS,
  LAYER_EXIT_DELAY_CONTROL
} from '../../common/constants/InteractionConstants';

@Component
export struct LyricsComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 主题色运行时值：无歌词占位的图标与底色跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  /** 播放进度（秒）：LrcView 要毫秒，传入时 ×1000 */
  @StorageLink(STORE_PROGRESS) time: number = 0;
  /** 折叠屏展开态：全局 FormFactorHolder 唯一写入，本组件只读 */
  @StorageProp(STORE_FOLD_EXPANDED) isFoldFull: boolean = false;
  @StorageLink(STORE_IS_PLAYING) isPlay: boolean = false;
  @StorageLink(STORE_CURRENT_TRACK) @Watch('onTrackChanged') currentTrack: Track | null = null;
  /** 是否随歌词渲染底部控制区（SM 歌词页 true；LG/折叠分栏布局 false，控制区在封面侧） */
  isShowControl: boolean = true;
  /**
   * 歌词滚动效果：源给出逐字时间轴（`result.dynamic`）时启用逐字渐变，
   * 否则退回整行高亮。必须是 @State —— 切歌时效果会变，普通成员改了不触发重渲染，
   * LrcView 的 @Prop 就永远收不到新值。
   */
  @State lyricScrollEffect: LyricScrollEffect = LyricScrollEffect.Line;
  @State mLrcEntryList: Array<LrcEntry> = [];
  /** 封面加载失败标记：切歌复位；失败时回落到同尺寸浅粉占位块 */
  @State coverFailed: boolean = false;
  /**
   * 当前曲目的歌词偏移（ms，正数 = 歌词延后）。由 LyricsApi 按曲目落盘，
   * 切歌时重新读取。传给 LrcView 时从播放位置上减掉。
   */
  @State lyricOffsetMs: number = 0;
  /** 歌词设置面板（长按歌词区打开） */
  @State showLyricSheet: boolean = false;
  /** 面板里的源信息：`网易云 · 62 行 · 含翻译` */
  @State lyricInfo: string = '';
  /** 手动搜索区（长按弹窗内）：是否展开输入框 + 候选列表 */
  @State lyricSearchExpanded: boolean = false;
  /** 搜索关键词（展开时预填清洗后的歌名，可改成「歌名 歌手」） */
  @State lyricSearchKeyword: string = '';
  /** 三源并行搜索进行中（驱动「搜索中…」与按钮防重复点击） */
  @State lyricSearching: boolean = false;
  /** 搜索到的候选（上限 20 条；manual 搜索结果的落地走 pickLyricCandidate） */
  @State lyricCandidates: LyricCandidate[] = [];
  /** 搜索区状态文案：未找到 / 获取失败等提示（空串 = 无提示） */
  @State lyricSearchMsg: string = '';
  /** 正在取词的候选 id（`source:remoteId`）：行内转 LoadingProgress，防重复点选 */
  @State lyricPickingId: string = '';

  /** 同曲守卫：封面等字段异步补全不应重置歌词 */
  private lastTrackKey: string = '';
  /** 上一次真正发起歌词请求时的「信息键」（id + 标题 + 歌手 + 时长是否已知） */
  private lastLyricKey: string = '';
  /** 歌词请求令牌：切歌 / 信息补全后，在途的旧请求结果必须丢弃 */
  private lyricToken: number = 0;

  /**
   * 播放页展开态：收起（→ false，落在 Index.closePlayer 的主动画闭包内）时
   * 把歌词层入场状态复位为隐藏 —— 与 onContentExit 复位幂等兜底（那时已是隐藏值，
   * 同值复位不产生属性变化，不会触发动画）。
   */
  @StorageProp(STORE_PLAYER_OPEN) @Watch('onPlayerOpenChanged') playerOpen: boolean = false;
  /**
   * 收起时内容层柔退信号（seq 递增，写在 Index.closePlayer 的主动画闭包**外**，
   * 仅柔退路径递增）：歌词层 200ms EaseIn 柔退淡出（与控制区同批 LAYER_EXIT_DELAY_CONTROL）。
   */
  @StorageProp(STORE_PLAYER_CONTENT_EXIT) @Watch('onContentExit') contentExitSeq: number = 0;
  /**
   * 分层入场：歌词列表主动画期间不可见，
   * 封面落位后与控制区同批（LAYER_DELAY_CONTROL）淡入，只淡入不位移。
   */
  @State enterOpacity: number = 0;
  /** 柔退闸门：onContentExit 置 true 后，在途的延迟入场闭包不得再把歌词层点亮 */
  private exitRequested: boolean = false;

  /** 收起复位：入场状态回隐藏态（幂等兜底，见 playerOpen 注释） */
  private onPlayerOpenChanged(): void {
    if (this.playerOpen) {
      return;
    }
    this.enterOpacity = 0;
  }

  /** 柔退复位：歌词层 200ms EaseIn 淡出 + 拦截在途延迟入场 */
  private onContentExit(): void {
    this.exitRequested = true;
    this.getUIContext().animateTo(
      {
        duration: LAYER_EXIT_DURATION_MS,
        curve: Curve.EaseIn,
        delay: LAYER_EXIT_DELAY_CONTROL
      },
      (): void => {
        this.enterOpacity = 0;
      }
    );
  }

  aboutToAppear(): void {
    this.onTrackChanged();
    this.exitRequested = false;
    this.getUIContext().animateTo(
      { duration: ENTRANCE_DURATION_MS, curve: Curve.EaseOut, delay: LAYER_DELAY_CONTROL },
      (): void => {
        // 竞态闸门：打开后 400ms 内收起时，本延迟闭包仍在途——不拦会把已瞬隐的
        // 歌词层重新点亮（收起飞行途中闪现）。
        if (!this.exitRequested) {
          this.enterOpacity = 1;
        }
      }
    );
  }

  /**
   * 当前曲目的「信息键」：不能只拿 id 去重 —— 列表数据可能缺时长 / 标题，
   * 而歌词候选打分拿它们做加分项；音源解析补全后必须允许重搜。
   */
  private lyricKeyOf(track: Track): string {
    return `${track.id}|${track.title}|${track.artist}|${track.duration > 0 ? 'd' : 'n'}`;
  }

  /** 面板副标题：源 / 行数 / 是否有翻译 是否有逐字 */
  private buildInfoText(result: LyricResult): string {
    const parts: string[] = [];
    const label: string = sourceLabel(result.source);
    if (label.length > 0) {
      parts.push(label);
    }
    parts.push(`${result.lines.length} 行`);
    if (result.hasTranslation === true) {
      parts.push('含翻译');
    }
    if (result.dynamic === true) {
      parts.push('逐字');
    }
    if (result.synced === false) {
      parts.push('无时间轴');
    }
    return parts.join(' · ');
  }

  /** 偏移显示文本：+0.5s / -1.2s / 0.0s */
  private offsetText(): string {
    const sec: number = this.lyricOffsetMs / 1000;
    if (this.lyricOffsetMs === 0) {
      return '0.0s';
    }
    const fixed: string = Math.abs(sec).toFixed(1);
    return this.lyricOffsetMs > 0 ? `+${fixed}s` : `-${fixed}s`;
  }

  /** 候选行副标题：`歌手 · 专辑 · 源`（空段跳过，避免「 · · 网易云」） */
  private candidateSubtitle(cand: LyricCandidate): string {
    const parts: string[] = [];
    if (cand.artistName.length > 0) {
      parts.push(cand.artistName);
    }
    if (cand.albumName.length > 0) {
      parts.push(cand.albumName);
    }
    const label: string = sourceLabel(cand.source);
    if (label.length > 0) {
      parts.push(label);
    }
    return parts.join(' · ');
  }

  /** 调整歌词偏移（正数 = 歌词延后显示） */
  private bumpOffset(deltaMs: number): void {
    const track: Track | null = this.currentTrack;
    if (track === null) {
      return;
    }
    LyricsApi.setLyricOffset(track.id, this.lyricOffsetMs + deltaMs);
    this.lyricOffsetMs = LyricsApi.getLyricOffset(track.id);
  }

  /** 清缓存重搜（用户觉得匹配错了 / 之前没找到） */
  private async refetchLyric(): Promise<void> {
    const track: Track | null = this.currentTrack;
    if (track === null) {
      return;
    }
    LyricsApi.clearLyricCache(track.id);
    this.showLyricSheet = false;
    await this.loadLyrics();
  }

  /** 主动跳过这首歌的歌词（以后不再自动搜） */
  private async skipLyric(): Promise<void> {
    const track: Track | null = this.currentTrack;
    if (track === null) {
      return;
    }
    this.lyricToken++;
    await LyricsApi.skipLyricForTrack(track);
    this.mLrcEntryList = [];
    this.lyricScrollEffect = LyricScrollEffect.Line;
    this.lyricInfo = '已跳过本曲歌词（重新获取可恢复）';
    this.showLyricSheet = false;
  }

  /** 复位手动搜索区（弹窗 onDisappear / 手选成功后共用）：回干净入口态 */
  private resetLyricSearchSection(): void {
    this.lyricSearchExpanded = false;
    this.lyricSearchKeyword = '';
    this.lyricSearching = false;
    this.lyricCandidates = [];
    this.lyricSearchMsg = '';
    this.lyricPickingId = '';
  }

  /**
   * 手动搜索歌词候选（三源并行，上限 20 条）。
   * 空词 / 搜索中 / 无曲目一律 no-op；回来时曲目已切换则丢弃结果（搜索结果只属于发起时的曲目）。
   */
  private async runLyricSearch(): Promise<void> {
    const track: Track | null = this.currentTrack;
    if (track === null || this.lyricSearching) {
      return;
    }
    const keyword: string = this.lyricSearchKeyword.trim();
    if (keyword.length === 0) {
      this.lyricSearchMsg = '先输入关键词，如「歌名 歌手」';
      return;
    }
    this.lyricSearching = true;
    this.lyricSearchMsg = '';
    try {
      const rows: LyricCandidate[] = await LyricsApi.searchLyricCandidates(keyword);
      const now: Track | null = this.currentTrack;
      if (now === null || now.id !== track.id) {
        return;
      }
      this.lyricCandidates = rows;
      if (rows.length === 0) {
        this.lyricSearchMsg = '未找到，换个关键词试试';
      }
    } catch (err) {
      const msg: string = err instanceof Error ? err.message : String(err);
      console.error(`[Lyric] manual search failed: ${msg}`);
      this.lyricSearchMsg = '搜索失败，请检查网络后重试';
    } finally {
      this.lyricSearching = false;
    }
  }

  /**
   * 用户点选某条候选 → 取词并落地（写 manual 缓存，之后自动搜索不覆盖）。
   * 令牌守卫：取词期间切歌，旧弹窗在途结果不得覆盖新歌歌词。
   */
  private async pickLyricCandidate(cand: LyricCandidate): Promise<void> {
    const track: Track | null = this.currentTrack;
    if (track === null || this.lyricPickingId.length > 0) {
      return;
    }
    this.lyricPickingId = cand.id;
    this.lyricSearchMsg = '';
    const token: number = ++this.lyricToken;
    try {
      const result: LyricResult | null = await LyricsApi.chooseLyricCandidate(track, cand);
      if (token !== this.lyricToken) {
        return;
      }
      if (result !== null) {
        this.mLrcEntryList = this.toLrcEntries(result.lines);
        this.lyricScrollEffect = result.dynamic === true
          ? LyricScrollEffect.LetterGradient
          : LyricScrollEffect.Line;
        this.lyricInfo = this.buildInfoText(result);
        this.showLyricSheet = false;
      } else {
        this.lyricSearchMsg = '获取歌词失败，换个候选试试';
      }
    } catch (err) {
      if (token !== this.lyricToken) {
        return;
      }
      const msg: string = err instanceof Error ? err.message : String(err);
      console.error(`[Lyric] manual pick failed: ${msg}`);
      this.lyricSearchMsg = '获取歌词失败，换个候选试试';
    } finally {
      // 纯 UI 行状态无条件复位：取词期间切歌（令牌失效）时若不复位，
      // lyricPickingId 会永远卡在旧候选上，之后所有点选都被防重复守卫拦掉。
      this.lyricPickingId = '';
    }
  }

  onTrackChanged(): void {
    // 新曲目新封面：失败标记最先复位（下方同曲去重会提前 return）
    this.coverFailed = false;
    const track: Track | null = this.currentTrack;
    if (track === null) {
      this.lastTrackKey = '';
      this.lastLyricKey = '';
      this.lyricToken++;
      this.mLrcEntryList = [];
      this.lyricOffsetMs = 0;
      return;
    }
    // 偏移每首歌独立（按曲目 id 落盘），切歌必须重读
    this.lyricOffsetMs = LyricsApi.getLyricOffset(track.id);
    const key: string = this.lyricKeyOf(track);
    if (key === this.lastLyricKey) {
      // 同一首、关键信息没变（例如只是封面被异步补全）→ 不重复请求
      return;
    }
    if (track.id !== this.lastTrackKey) {
      this.lastTrackKey = track.id;
      // 换歌立刻清空上一首的歌词，避免新歌词到达前显示错位内容
      this.mLrcEntryList = [];
    }
    this.lastLyricKey = key;
    // 不主动清缓存：「缺时长的 miss 结论不可信」由 LyricsApi 内部 cacheKey
    // 比对处理（信息键失配 → miss 失效自动重搜；manual 缓存永远优先返回，
    // 且物理隔离在 manual 目录，只有显式操作能清除）。曾在冷启动时误判
    // 「上次缺时长」删掉缓存文件，导致用户手选的歌词每次重启都被重新自动匹配。
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
      if (result !== null) {
        this.mLrcEntryList = this.toLrcEntries(result.lines);
        // 有逐字时间轴才启用逐字渐变（无逐字时该效果等价于整行高亮，但要避免走未验证分支）
        this.lyricScrollEffect = result.dynamic === true
          ? LyricScrollEffect.LetterGradient
          : LyricScrollEffect.Line;
        this.lyricInfo = this.buildInfoText(result);
      } else {
        this.mLrcEntryList = [];
        this.lyricScrollEffect = LyricScrollEffect.Line;
        this.lyricInfo = '未找到歌词（可长按歌词区重新搜索）';
      }
    } catch (err) {
      if (token !== this.lyricToken) {
        return;
      }
      const msg: string = err instanceof Error ? err.message : String(err);
      console.error(`Failed to load lyric: ${msg}`);
      this.mLrcEntryList = [];
      this.lyricScrollEffect = LyricScrollEffect.Line;
    }
  }

  /**
   * 行级时间轴（秒）→ LrcEntry（毫秒）。
   *
   * 三件事：
   *   1. 行时长 = 下一行起点 − 本行起点，最后一行给一个足够大的值（唱完仍保持高亮）；
   *   2. **副行**（翻译 / 罗马音）按顺序塞进 `subLines`，LrcView 会在主行下方画小字；
   *   3. **逐字**（`lyric.words` 里的相对偏移 ms）转成 LrcEntry.words。
   */
  private toLrcEntries(lines: LyricLine[]): LrcEntry[] {
    const out: LrcEntry[] = [];
    for (let i = 0; i < lines.length; i++) {
      const startMs: number = lines[i].time * 1000;
      const durMs: number = i < lines.length - 1
        ? lines[i + 1].time * 1000 - startMs
        : Number.MAX_VALUE;

      const subs: string[] = [];
      const tr: string | undefined = lines[i].translation;
      if (tr !== undefined && tr.length > 0) {
        subs.push(tr);
      }
      const ro: string | undefined = lines[i].romaji;
      if (ro !== undefined && ro.length > 0) {
        subs.push(ro);
      }

      const words: Word[] = [];
      const rawWords: LyricWord[] | undefined = lines[i].words;
      if (rawWords !== undefined) {
        for (let k = 0; k < rawWords.length; k++) {
          const w: Word = {
            text: rawWords[k].text,
            wordStartTime: rawWords[k].offset,
            duration: rawWords[k].duration
          };
          words.push(w);
        }
      }

      out.push({
        lineStartTime: startMs,
        lineDuration: durMs,
        lineWords: lines[i].text,
        words: words,
        subLines: subs
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

  /**
   * 歌词设置面板（长按歌词区打开）。
   *
   * 刻意不写成「带参 @Builder」：本项目铁律 —— 带参 Builder 按值传递，
   * 参数来自状态变量时内部不随状态刷新；且函数类型参数不能做状态变量。
   * 所以每个按钮都内联写，只有文案与颜色是常量。
   *
   * 配色：全部使用 app.color.* 语义 token（base/dark 双份定义，
   * 随系统深浅色自动切换），与 SettingsPage 弹窗、QueueSheet 的自适应口径一致；
   * 唯一保留的 Color.White 是品牌色底上的白字（深浅色下均可见）——
   * 硬编码白色系在系统浅色模式下会被 sheet 的浅色背景吞掉。
   *
   * 手动搜索：「搜索歌词」展开输入区 → 三源并行搜候选 →
   * 点选落地并写 manual 缓存（用户的选择 > 算法，自动搜索不再覆盖）。
   */
  @Builder
  LyricSheetHost() {
    Column({ space: 18 }) {
      Column({ space: 4 }) {
        Text('歌词')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(this.lyricInfo.length > 0 ? this.lyricInfo : '—')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .width(StyleConstants.FULL_WIDTH)

      Row() {
        Text('−0.5s')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .height(44)
          .padding({ left: 18, right: 18 })
          .borderRadius(22)
          .backgroundColor($r('app.color.press_overlay'))
          .textAlign(TextAlign.Center)
          .accessibilityText('歌词提前 0.5 秒')
          .onClick((): void => {
            this.bumpOffset(-500);
          })
        Text(this.offsetText())
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text('+0.5s')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .height(44)
          .padding({ left: 18, right: 18 })
          .borderRadius(22)
          .backgroundColor($r('app.color.press_overlay'))
          .textAlign(TextAlign.Center)
          .accessibilityText('歌词延后 0.5 秒')
          .onClick((): void => {
            this.bumpOffset(500);
          })
      }
      .width(StyleConstants.FULL_WIDTH)
      .alignItems(VerticalAlign.Center)

      Row({ space: 12 }) {
        Text('重置偏移')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .height(44)
          .layoutWeight(1)
          .borderRadius(12)
          .borderWidth(1)
          .borderColor($r('app.color.bg_divider'))
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            const track: Track | null = this.currentTrack;
            if (track === null) {
              return;
            }
            LyricsApi.setLyricOffset(track.id, 0);
            this.lyricOffsetMs = 0;
          })
        Text('重新获取')
          .fontSize(13)
          .fontColor(Color.White)
          .height(44)
          .layoutWeight(1)
          .borderRadius(12)
          .backgroundColor(this.themePrimary)
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            void this.refetchLyric();
          })
        Text('跳过本曲')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .height(44)
          .layoutWeight(1)
          .borderRadius(12)
          .borderWidth(1)
          .borderColor($r('app.color.bg_divider'))
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            void this.skipLyric();
          })
      }
      .width(StyleConstants.FULL_WIDTH)

      // 手动搜索入口：全宽描边按钮，点击展开/收起搜索区
      Text(this.lyricSearchExpanded ? '收起搜索' : '搜索歌词')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .height(44)
        .width(StyleConstants.FULL_WIDTH)
        .borderRadius(12)
        .borderWidth(1)
        .borderColor($r('app.color.bg_divider'))
        .textAlign(TextAlign.Center)
        .onClick((): void => {
          if (this.lyricSearchExpanded) {
            this.lyricSearchExpanded = false;
            return;
          }
          this.lyricSearchExpanded = true;
          // 展开预填：清洗后的歌名（用户可改成「歌名 歌手」组合词）
          if (this.lyricSearchKeyword.length === 0) {
            const track: Track | null = this.currentTrack;
            if (track !== null) {
              const cleaned: string = cleanTitle(track.title);
              this.lyricSearchKeyword = cleaned.length > 0 ? cleaned : track.title;
            }
          }
        })

      if (this.lyricSearchExpanded) {
        Column({ space: 12 }) {
          Row({ space: 8 }) {
            TextInput({ placeholder: '歌名 / 歌手，如「晴天 周杰伦」', text: this.lyricSearchKeyword })
              .layoutWeight(1)
              .height(40)
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .placeholderFont({ size: 14 })
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(12)
              .padding({ left: 14, right: 14 })
              .onChange((v: string): void => {
                this.lyricSearchKeyword = v;
              })
              .onSubmit((): void => {
                void this.runLyricSearch();
              })
            Text(this.lyricSearching ? '搜索中' : '搜索')
              .fontSize(13)
              .fontColor(Color.White)
              .height(40)
              .padding({ left: 16, right: 16 })
              .borderRadius(12)
              .backgroundColor(this.themePrimary)
              .textAlign(TextAlign.Center)
              .onClick((): void => {
                void this.runLyricSearch();
              })
          }
          .width(StyleConstants.FULL_WIDTH)
          .alignItems(VerticalAlign.Center)

          if (this.lyricSearching) {
            Row({ space: 8 }) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color($r('app.color.text_secondary'))
              Text('三源并行搜索中…')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .width(StyleConstants.FULL_WIDTH)
            .alignItems(VerticalAlign.Center)
          } else if (this.lyricSearchMsg.length > 0) {
            Text(this.lyricSearchMsg)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width(StyleConstants.FULL_WIDTH)
          }

          if (this.lyricCandidates.length > 0) {
            List({ space: 0 }) {
              ForEach(this.lyricCandidates, (cand: LyricCandidate) => {
                ListItem() {
                  Row() {
                    Column({ space: 2 }) {
                      Text(cand.trackName)
                        .fontSize(14)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(this.candidateSubtitle(cand))
                        .fontSize(12)
                        .fontColor($r('app.color.text_secondary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    if (this.lyricPickingId === cand.id) {
                      LoadingProgress()
                        .width(16)
                        .height(16)
                        .color($r('app.color.text_secondary'))
                        .margin({ left: 12 })
                    }
                  }
                  .width(StyleConstants.FULL_WIDTH)
                  .height(52)
                  .alignItems(VerticalAlign.Center)
                  .onClick((): void => {
                    void this.pickLyricCandidate(cand);
                  })
                }
              }, (cand: LyricCandidate): string => cand.id)
            }
            .width(StyleConstants.FULL_WIDTH)
            .constraintSize({ maxHeight: 300 })
            .divider({
              strokeWidth: 1,
              color: $r('app.color.bg_divider'),
              startMargin: 0,
              endMargin: 0
            })
          }
        }
        .width(StyleConstants.FULL_WIDTH)
      }
    }
    .width(StyleConstants.FULL_WIDTH)
    .padding({ left: 24, right: 24, top: 16, bottom: 16 })
  }

  build() {
    Column() {
      if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_SM) {
        Row() {
          if (this.coverUrl().length > 0 && !this.coverFailed) {
            Image(this.coverUrl())
              .width($r('app.float.label_width_sm'))
              .height($r('app.float.label_width_sm'))
              .borderRadius($r('app.float.label_border'))
              .margin({ right: $r('app.float.label_margin_right') })
              // 加载失败回落到下方浅粉占位块，不留白
              .onError((err: ImageError): void => {
                this.coverFailed = true;
              })
          } else if (this.coverUrl().length > 0) {
            // 封面加载失败：同尺寸浅粉占位块，占住原有布局位（margin 保持一致）
            Stack() {
              SymbolGlyph($r('sys.symbol.waveform'))
                .fontSize(14)
                .fontColor([this.themePrimary])
                .opacity(0.45)
            }
            .width($r('app.float.label_width_sm'))
            .height($r('app.float.label_width_sm'))
            .borderRadius($r('app.float.label_border'))
            .margin({ right: $r('app.float.label_margin_right') })
            .backgroundColor(this.themeSurface)
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
              .maxLines(2)
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

      // 平板大屏歌词（7 列居中窄栅格）只服务真 LG；折叠屏展开即使宽度落 lg
      //（阔折叠大屏）也走普通歌词列表 —— 分栏
      // 由外层折叠分支的 8 列 4+4 栅格负责，再套窄栅格会双重收窄。
      if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG && !this.isFoldFull) {
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
                  lyricMilliSecondsTime: this.time * 1000 - this.lyricOffsetMs,
                  mLrcEntryList: this.mLrcEntryList,
                  lyricScrollEffect: this.lyricScrollEffect,
                  isPlay: this.isPlay,
                  lyricTopPosition: LyricTopPosition.Middle
                })
                  .layoutWeight(1)
                  .gesture(LongPressGesture({ repeat: false, duration: 500 })
                    .onAction((): void => {
                      this.showLyricSheet = true;
                    }))
              }
            }
          }
        }
        .layoutWeight(1)
      } else {
        LrcView({
          lyricMilliSecondsTime: this.time * 1000 - this.lyricOffsetMs,
          mLrcEntryList: this.mLrcEntryList,
          lyricScrollEffect: this.lyricScrollEffect,
          isPlay: this.isPlay,
          lyricTopPosition: LyricTopPosition.Middle
        })
          .layoutWeight(1)
          // 长按歌词区打开「歌词设置」（偏移 / 重新获取 / 跳过）
          .gesture(LongPressGesture({ repeat: false, duration: 500 })
            .onAction((): void => {
              this.showLyricSheet = true;
            }))
      }

      if (this.isShowControl) {
        ControlAreaComponent()
          .margin({
            top: $r('app.float.control_lyric_margin'),
            bottom: $r('app.float.music_component_bottom')
          })
      }
    }
    // 分层入场只挂 opacity（不动 layout 属性，避免整树重排）；收起为柔退淡出（onContentExit 的 200ms EaseIn 退场）
    .opacity(this.enterOpacity)
    .bindSheet($$this.showLyricSheet, this.LyricSheetHost(), {
      // FIT_CONTENT：内容只有 ~230vp，固定半屏高在大屏真机上会留大片空白；
      // 贴合内容后与 SettingsPage 弹窗口径一致。
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      // 弹窗关闭即复位搜索区（含手选成功关弹窗的路径）：下次打开是干净入口态
      onDisappear: (): void => {
        this.resetLyricSearchSection();
      }
    })
  }
}
