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

import { Track, LyricLine, LyricResult, LyricWord, LyricCandidate, AppSettings } from '../../model/MusicModels';
import { LyricsApi, sourceLabel } from '../../api/LyricsApi';
import { AppPreferences } from '../../preferences/AppPreferences';
import {
  SUBTITLE_KIND_CC,
  SUBTITLE_KIND_AI,
  SubtitleAvailability,
  SubtitleOutcome,
  SubtitleChoice,
  SubtitleChoicesOutcome
} from '../../api/SubtitleLyricApi';
import { isLoggedIn, isLoginStale } from '../../service/LoginStore';
import { cleanTitle, toThumbUrl } from '../../utils/TextUtil';
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
  STORE_THEME_SURFACE,
  STORE_LYRIC_CENTERED
} from '../../common/Constants';
import {
  ENTRANCE_DURATION_MS,
  LAYER_DELAY_CONTROL,
  LAYER_EXIT_DURATION_MS,
  LAYER_EXIT_DELAY_CONTROL
} from '../../common/constants/InteractionConstants';

/** AI 字幕后台补全：partial 命中后首轮等待（ms）—— 生成通常在首次请求后不久收敛 */
const BILI_PARTIAL_REFRESH_DELAY_MS: number = 10000;
/** 后台补全最大轮数（每轮行数增长且仍 partial 才继续），总轮询窗约 40s */
const BILI_PARTIAL_REFRESH_MAX_ROUNDS: number = 3;
/** 字幕可用性探测：面板打开后防抖延迟（ms）——开面板看一眼就关的快速窥探零请求 */
const BILI_PROBE_DEBOUNCE_MS: number = 800;

/**
 * LrcView 的进度订阅宿主：STORE_PROGRESS 每 500ms 更新一次，
 * 若订阅挂在 LyricsComponent 顶层，整个歌词页 build 会以 2Hz 重执行
 * （SM 头行 / 栅格分支 / bindSheet 宿主全被拖累）。
 * 与 PlayerProgressArea 同一隔离模式：把 2Hz 状态关进只渲染 LrcView 的最小子树。
 */
@Component
struct LrcViewHost {
  /** 播放进度（秒）：只读镜像，无需双向绑定 */
  @StorageProp(STORE_PROGRESS) time: number = 0;
  @StorageProp(STORE_IS_PLAYING) isPlay: boolean = false;
  @Prop lyricOffsetMs: number = 0;
  /** ⚠️ @Link 引用透传（免 @Prop 深拷贝）：本组件只读，绝不 mutate */
  @Link mLrcEntryList: Array<LrcEntry>;
  @Prop lyricScrollEffect: LyricScrollEffect = LyricScrollEffect.Line;
  @Prop lyricCentered: boolean = false;
  /** 歌词页可见性门控（SM/阔折叠由外层 Swiper 下标派生；分栏布局恒 true） */
  @Prop pageActive: boolean = true;
  /** 长按歌词区回调（打开「歌词设置」面板） */
  onLongPress: () => void = (): void => {
  };

  build() {
    LrcView({
      lyricMilliSecondsTime: this.time * 1000 - this.lyricOffsetMs,
      mLrcEntryList: this.mLrcEntryList,
      lyricScrollEffect: this.lyricScrollEffect,
      isPlay: this.isPlay,
      lyricCentered: this.lyricCentered,
      pageActive: this.pageActive,
      lyricTopPosition: LyricTopPosition.Middle
    })
      .layoutWeight(1)
      .gesture(LongPressGesture({ repeat: false, duration: 500 })
        .onAction((): void => {
          this.onLongPress();
        }))
  }
}

@Component
export struct LyricsComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 主题色运行时值：无歌词占位的图标与底色跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  /** 播放进度订阅已隔离到 LrcViewHost：本组件不得直接订阅 STORE_PROGRESS /
   * STORE_IS_PLAYING，否则整个歌词页会以 2Hz 重渲染 */
  /** 折叠屏展开态：全局 FormFactorHolder 唯一写入，本组件只读 */
  @StorageProp(STORE_FOLD_EXPANDED) isFoldFull: boolean = false;
  /** 歌词居中显示（AppSettings.lyricCentered 的运行时镜像，长按面板可切，默认关 = 左对齐） */
  @StorageProp(STORE_LYRIC_CENTERED) lyricCentered: boolean = false;
  @StorageLink(STORE_CURRENT_TRACK) @Watch('onTrackChanged') currentTrack: Track | null = null;
  /** 是否随歌词渲染底部控制区（SM 歌词页 true；LG/折叠分栏布局 false，控制区在封面侧） */
  isShowControl: boolean = true;
  /** 歌词页可见性门控：SM/阔折叠由外层 Swiper 下标派生（===1），分栏布局恒 true */
  @Prop pageActive: boolean = true;
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
  /** 歌词设置面板（长按歌词区打开）；打开即探测 B 站字幕可用性（预热 AI 惰性生成） */
  @State @Watch('onSheetOpenChanged') showLyricSheet: boolean = false;
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
  /** B 站字幕取列表/取数进行中（CC / AI 两按钮共用：防重复点击 + 「获取中…」） */
  @State biliSubtitleBusy: boolean = false;
  /** 当前 kind 下的可选字幕（>1 时展示列表让用户挑；空数组 = 无列表） */
  @State biliSubtitleChoices: SubtitleChoice[] = [];
  /** 正在取数的 B 站字幕选项 id：行内转 LoadingProgress，防重复点选 */
  @State biliSubtitlePickingId: string = '';
  /** 字幕可用性探测进行中（按钮后缀「检测中」） */
  @State biliProbeChecking: boolean = false;
  /** 探测完成（结论已应用：含结论性无 / 瞬时失败 / 本地跳过） */
  @State biliProbeDone: boolean = false;
  /** CC 可用条目数（-1 = 未知：未探测或本地跳过） */
  @State biliProbeCcCount: number = -1;
  /** AI 可用条目数（-1 = 未知） */
  @State biliProbeAiCount: number = -1;
  /** AI 条目存在但暂无 URL（B 站惰性生成中）：AI 按钮显示「生成中」并禁用，待「重新检测」 */
  @State biliProbeAiPending: boolean = false;
  /** 探测瞬时失败（按钮保持可点，提示行给「重新检测」入口） */
  @State biliProbeTransientFail: boolean = false;
  /** 本地跳过（未登录 / 非 B 站曲目，未发请求）：两按钮禁用 + 提示原因 */
  @State biliProbeLocalSkip: boolean = false;
  /** 探测提示行文案：未登录 / 非 B 站 / 无字幕 / 生成中 / 检测失败（空串 = 不显示） */
  @State biliProbeHint: string = '';
  /** 面板打开后探测防抖定时器 id（-1 = 无） */
  private biliProbeDebounceTimer: number = -1;
  /** 探测令牌：切歌 / 面板关闭后的在途探测结果不得再改按钮态 */
  private biliProbeToken: number = 0;
  /** 后台补全定时器 id（-1 = 无）：AI 字幕命中但疑似生成中时，稍后静默重取 */
  private biliPartialRefreshTimer: number = -1;

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
    // 字段级 ?? 兜底：旧快照恢复的曲目可能缺 title/artist（undefined），模板串不设防
    return `${track.id}|${track.title ?? ''}|${track.artist ?? ''}|${track.duration > 0 ? 'd' : 'n'}`;
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

  /** 清缓存重搜（用户觉得匹配错了 / 之前没找到） */
  private async refetchLyric(): Promise<void> {
    const track: Track | null = this.currentTrack;
    if (track === null || track === undefined || (track.id ?? '').length === 0) {
      return;
    }
    LyricsApi.clearLyricCache(track.id);
    this.showLyricSheet = false;
    await this.loadLyrics();
  }

  /** 主动跳过这首歌的歌词（以后不再自动搜） */
  private async skipLyric(): Promise<void> {
    const track: Track | null = this.currentTrack;
    if (track === null || track === undefined || (track.id ?? '').length === 0) {
      return;
    }
    this.lyricToken++;
    await LyricsApi.skipLyricForTrack(track);
    this.mLrcEntryList = [];
    this.lyricScrollEffect = LyricScrollEffect.Line;
    this.lyricInfo = '已跳过本曲歌词（重新获取可恢复）';
    this.showLyricSheet = false;
  }

  /**
   * 手动改用 B 站字幕（长按面板入口，CC / AI 两个独立按钮）。
   * 单飞：busy / pickingId 任一置位期间的点按一律忽略 —— 狂点不再发起
   * 并发多链互相覆盖（旧版「要点多次才对」的直接来源）。
   * 取数分两步：先取该 kind 下的候选列表 —— 单候选确定性直选（保持一步
   * 到位）；多候选展示列表让用户挑（多字幕视频上自动选优不确定）。
   * 失败按 biliFailText 分型提示（登录态 → no-candidate 按 kind 引导另一
   * 按钮 → definitive → 瞬时）。不做匿名降级重试（匿名 subtitles 多为空），
   * 引导登录是唯一正路。
   */
  private async useBiliSubtitle(kind: string): Promise<void> {
    const track: Track | null = this.currentTrack;
    if (track === null || this.biliSubtitleBusy || this.biliSubtitlePickingId.length > 0) {
      return;
    }
    // 点击即取数：挂起的探测防抖一并取消（同刻双链会放大请求量，风控规避）
    this.cancelBiliProbeDebounce();
    const token: number = ++this.lyricToken;
    this.biliSubtitleBusy = true;
    this.biliSubtitleChoices = [];
    this.lyricInfo = '正在获取 B 站字幕…';
    try {
      const outcome: SubtitleChoicesOutcome = await LyricsApi.listBiliSubtitleChoices(track, kind);
      if (token !== this.lyricToken) {
        return;
      }
      // 点击链结论回写按钮态（探测缓存的回填在 API 层 runChoicesChain 已做，
      // 此处保证面板内「有 / N条 / 生成中 / 无」后缀与刚取到的列表一致）
      this.applyChoiceOutcomeToProbe(kind, outcome);
      if (outcome.choices.length === 1) {
        await this.pickBiliSubtitleChoice(outcome.choices[0]);
        return;
      }
      if (outcome.choices.length > 1) {
        this.biliSubtitleChoices = outcome.choices;
        this.lyricInfo = `找到 ${outcome.choices.length} 个可用字幕，请选择`;
        return;
      }
      this.lyricInfo = this.biliFailText(kind, outcome.definitive, outcome.reason);
    } catch (err) {
      if (token !== this.lyricToken) {
        return;
      }
      const msg: string = err instanceof Error ? err.message : String(err);
      console.error(`[Lyric] list bili subtitle failed: ${msg}`);
      this.lyricInfo = '字幕获取失败，请稍后重试';
    } finally {
      // 纯 UI 行状态无条件复位（同 pickLyricCandidate 的教训）：
      // 取列表期间切歌（令牌失效）时若不复位，busy 会永远卡在 true，
      // 之后所有点按都被单飞守卫拦掉。
      this.biliSubtitleBusy = false;
    }
  }

  /**
   * 点击取列表结论回写探测按钮态（面板内后缀与刚取到的列表一致；
   * 探测缓存回填由 API 层 runChoicesChain 同步完成）。
   * 只回写被点击 kind 的计数，另一 kind 保持未知（-1，不误禁）。
   */
  private applyChoiceOutcomeToProbe(kind: string, outcome: SubtitleChoicesOutcome): void {
    const isCc: boolean = kind === SUBTITLE_KIND_CC;
    const count: number = outcome.choices.length;
    if (isCc) {
      this.biliProbeCcCount = count;
    } else {
      this.biliProbeAiCount = count;
      this.biliProbeAiPending = false;
    }
    if (count > 0 || outcome.definitive) {
      this.biliProbeDone = true;
      this.biliProbeTransientFail = false;
      this.biliProbeLocalSkip = false;
    }
    // AI 生成中（条目存在但无 URL）：按钮显示「生成中」并禁用
    if (count === 0 && outcome.reason === 'dirty' && !isCc) {
      this.biliProbeAiPending = true;
      this.biliProbeAiCount = 0;
    }
  }

  /**
   * 点选某个 B 站字幕候选 → 取字幕并落地（写 manual 缓存，用户选择 >
   * 自动搜索）。令牌守卫：取数期间切歌，在途结果不得覆盖新歌歌词。
   */
  private async pickBiliSubtitleChoice(choice: SubtitleChoice): Promise<void> {
    const track: Track | null = this.currentTrack;
    if (track === null || this.biliSubtitlePickingId.length > 0) {
      return;
    }
    const token: number = ++this.lyricToken;
    this.biliSubtitlePickingId = choice.id;
    this.lyricInfo = '正在获取字幕内容…';
    try {
      const outcome: SubtitleOutcome = await LyricsApi.chooseBiliSubtitleItem(track, choice);
      if (token !== this.lyricToken) {
        return;
      }
      if (outcome.result !== null) {
        this.mLrcEntryList = this.toLrcEntries(outcome.result.lines);
        this.lyricScrollEffect = outcome.result.dynamic === true
          ? LyricScrollEffect.LetterGradient
          : LyricScrollEffect.Line;
        this.lyricInfo = this.buildInfoText(outcome.result);
        this.biliSubtitleChoices = [];
        this.showLyricSheet = false;
        if (outcome.partial === true) {
          // AI 生成中的半截内容：先展示（聊胜于无），稍后后台静默补全
          this.lyricInfo = `${this.lyricInfo} · AI 生成中，稍后自动补全`;
          this.scheduleBiliPartialRefresh(choice, track.id, outcome.result.lines.length, 1);
        } else {
          this.cancelBiliPartialRefresh();
        }
      } else {
        this.lyricInfo = this.biliFailText('', outcome.definitive, outcome.reason);
      }
    } catch (err) {
      if (token !== this.lyricToken) {
        return;
      }
      const msg: string = err instanceof Error ? err.message : String(err);
      console.error(`[Lyric] pick bili subtitle failed: ${msg}`);
      this.lyricInfo = '字幕获取失败，请稍后重试';
    } finally {
      // 纯 UI 行状态无条件复位：取数期间切歌（令牌失效）时若不复位，
      // biliSubtitlePickingId 会永远卡在旧选项上，之后所有点选都被防重复守卫拦掉。
      this.biliSubtitlePickingId = '';
    }
  }

  /** 取消挂起的后台补全定时器（切歌 / 新的完整结果到达时） */
  private cancelBiliPartialRefresh(): void {
    if (this.biliPartialRefreshTimer >= 0) {
      clearTimeout(this.biliPartialRefreshTimer);
      this.biliPartialRefreshTimer = -1;
    }
  }

  /** 安排一轮后台补全：延迟后纯取数比对，行数增长才替换歌词与缓存 */
  private scheduleBiliPartialRefresh(
    choice: SubtitleChoice,
    trackId: string,
    minLines: number,
    round: number
  ): void {
    this.cancelBiliPartialRefresh();
    const token: number = this.lyricToken;
    this.biliPartialRefreshTimer = setTimeout((): void => {
      this.biliPartialRefreshTimer = -1;
      // 安排后用户做过任何歌词操作（令牌已前进）→ 补全作废
      if (this.lyricToken !== token) {
        return;
      }
      this.refreshBiliPartialSubtitle(choice, trackId, minLines, round);
    }, BILI_PARTIAL_REFRESH_DELAY_MS);
  }

  /**
   * AI 字幕生成中的后台补全：纯取数（fetchSubtitleByChoice，不写缓存）→
   * 令牌仍有效且行数增长才替换歌词、落 manual 缓存 —— 生成中内容行数乱跳，
   * 无条件写会把缓存覆盖成更差的半截快照。仍 partial 且轮次未用尽 → 继续
   * 下一轮。用户期间任何歌词操作都令令牌前进，补全自动让位（不打断用户）。
   */
  private async refreshBiliPartialSubtitle(
    choice: SubtitleChoice,
    trackId: string,
    minLines: number,
    round: number
  ): Promise<void> {
    const track: Track | null = this.currentTrack;
    if (track === null || track.id !== trackId) {
      return;
    }
    if (this.biliSubtitleBusy || this.biliSubtitlePickingId.length > 0) {
      return;
    }
    const token: number = ++this.lyricToken;
    try {
      const outcome: SubtitleOutcome = await LyricsApi.fetchSubtitleByChoice(track, choice);
      if (token !== this.lyricToken || outcome.result === null
        || outcome.result.lines.length <= minLines) {
        return;
      }
      console.info(`[Lyric] subtitle partial refresh round=${round}`
        + ` lines=${minLines}→${outcome.result.lines.length} track=${track.title}`);
      this.mLrcEntryList = this.toLrcEntries(outcome.result.lines);
      this.lyricScrollEffect = outcome.result.dynamic === true
        ? LyricScrollEffect.LetterGradient
        : LyricScrollEffect.Line;
      this.lyricInfo = this.buildInfoText(outcome.result);
      void LyricsApi.saveBiliSubtitleChoice(track, outcome.result);
      if (outcome.partial === true && round < BILI_PARTIAL_REFRESH_MAX_ROUNDS) {
        this.scheduleBiliPartialRefresh(choice, trackId, outcome.result.lines.length, round + 1);
      }
    } catch (err) {
      const msg: string = err instanceof Error ? err.message : String(err);
      console.error(`[Lyric] subtitle partial refresh failed: ${msg}`);
    }
  }

  /**
   * 面板开关回调：打开即防抖探测字幕可用性（800ms 后面板仍打开才发请求——
   * 开面板看一眼就关的快速窥探零请求，风控规避）。探测请求本身即预热：
   * B 站 AI 字幕惰性生成由首次播放器请求触发，面板打开时探测、用户点
   * 按钮时生成已提前进行，直接提升一次点击成功率。
   */
  private onSheetOpenChanged(): void {
    if (this.showLyricSheet) {
      this.biliProbeDebounceTimer = setTimeout((): void => {
        this.biliProbeDebounceTimer = -1;
        if (this.showLyricSheet) {
          void this.runBiliProbe(false);
        }
      }, BILI_PROBE_DEBOUNCE_MS);
      return;
    }
    this.cancelBiliProbeDebounce();
  }

  /** 取消挂起的探测防抖定时器（面板关闭 / 点击取数 / 切歌共用） */
  private cancelBiliProbeDebounce(): void {
    if (this.biliProbeDebounceTimer >= 0) {
      clearTimeout(this.biliProbeDebounceTimer);
      this.biliProbeDebounceTimer = -1;
    }
  }

  /** 复位探测状态（切歌 / 面板关闭共用）：令牌前进作废在途探测，取消挂起防抖 */
  private resetBiliProbe(): void {
    this.biliProbeToken++;
    this.cancelBiliProbeDebounce();
    this.biliProbeChecking = false;
    this.biliProbeDone = false;
    this.biliProbeCcCount = -1;
    this.biliProbeAiCount = -1;
    this.biliProbeAiPending = false;
    this.biliProbeTransientFail = false;
    this.biliProbeLocalSkip = false;
    this.biliProbeHint = '';
  }

  /**
   * 探测当前曲目的 B 站字幕可用性（防抖触发 / 「重新检测」共用）。
   * 一次列表同时回答 CC/AI 两问，驱动按钮「有 / N条 / 生成中 / 无」后缀
   * 与禁用门控。force=true（手动「重新检测」）跳过 API 层结论缓存拿新数据；
   * 探测熔断与闸门冷却由 API 层强制（返回 blocked 合成结果）。
   * 本地前置跳过（不发无意义请求）：未登录（字幕列表对登录态强依赖，
   * 匿名 subtitles 多为空）与非 B 站曲目直接禁用按钮 + 提示原因。
   * 令牌守卫：切歌 / 面板关闭后的在途探测结果不得再改按钮态；
   * 点击取数在途时探测让位（同刻双链会放大请求量，风控规避）。
   */
  private async runBiliProbe(force: boolean): Promise<void> {
    const track: Track | null = this.currentTrack;
    if (track === null || track === undefined) {
      return;
    }
    if (this.biliSubtitleBusy || this.biliSubtitlePickingId.length > 0) {
      return;
    }
    const token: number = ++this.biliProbeToken;
    if (!isLoggedIn() || isLoginStale()) {
      this.biliProbeDone = true;
      this.biliProbeLocalSkip = true;
      this.biliProbeHint = '登录后可获取 B 站字幕';
      return;
    }
    if ((track.bvid ?? '').length === 0 && (track.aid ?? '').length === 0) {
      this.biliProbeDone = true;
      this.biliProbeLocalSkip = true;
      this.biliProbeHint = '当前曲目非 B 站视频';
      return;
    }
    this.biliProbeChecking = true;
    this.biliProbeDone = false;
    this.biliProbeCcCount = -1;
    this.biliProbeAiCount = -1;
    this.biliProbeAiPending = false;
    this.biliProbeTransientFail = false;
    this.biliProbeLocalSkip = false;
    this.biliProbeHint = '';
    try {
      const availability: SubtitleAvailability =
        await LyricsApi.probeBiliSubtitleAvailability(track, force);
      if (token !== this.biliProbeToken) {
        return;
      }
      this.biliProbeChecking = false;
      // 探测熔断 / 闸门冷却（API 层未发请求的合成结果）：按钮无后缀保持可点，
      // 不给「重新检测」（API 层熔断会拦），提示引导直接点击字幕按钮
      if (availability.reason === 'blocked') {
        this.biliProbeHint = '字幕检测暂停中（风控保护），可直接点击字幕按钮获取';
        return;
      }
      this.biliProbeCcCount = availability.ccCount;
      this.biliProbeAiCount = availability.aiCount;
      this.biliProbeAiPending = availability.aiPending;
      // 瞬时失败（risk / timeout / network，全无条目）：按钮保持可点作重试路径
      if (availability.ccCount === 0 && availability.aiCount === 0
        && !availability.aiPending && !availability.definitive) {
        if (availability.reason === 'risk') {
          // 探测撞风控（API 层已熔断 5min）：告知暂停窗口，不给重试链接
          this.biliProbeHint = '触发风控，检测暂停约 5 分钟，可直接点击字幕按钮获取';
          return;
        }
        this.biliProbeTransientFail = true;
        this.biliProbeHint = '字幕检测失败，可点击「重新检测」';
        return;
      }
      this.biliProbeDone = true;
      if (availability.reason === 'no-target') {
        this.biliProbeHint = '当前曲目非 B 站视频';
      } else if (availability.reason === 'denied') {
        this.biliProbeHint = '字幕列表获取失败，请稍后重试';
      } else if (availability.ccCount === 0 && availability.aiCount === 0 && !availability.aiPending) {
        this.biliProbeHint = '该视频没有可用的 CC / AI 字幕';
      } else if (availability.aiPending && availability.aiCount === 0) {
        this.biliProbeHint = 'AI 字幕生成中，请稍后点「重新检测」';
      }
    } catch (err) {
      if (token !== this.biliProbeToken) {
        return;
      }
      this.biliProbeChecking = false;
      this.biliProbeTransientFail = true;
      this.biliProbeHint = '字幕检测失败，可点击「重新检测」';
    }
  }

  /** 探测后缀：检测中 / 未知 / 有 / N条 / 生成中 / 无（空串 = 无后缀，如本地跳过） */
  private biliButtonSuffix(kind: string): string {
    if (this.biliSubtitleBusy) {
      return '';
    }
    if (this.biliProbeChecking) {
      return '检测中';
    }
    if (this.biliProbeTransientFail) {
      return '未知';
    }
    if (!this.biliProbeDone) {
      return '';
    }
    const count: number = kind === SUBTITLE_KIND_CC ? this.biliProbeCcCount : this.biliProbeAiCount;
    if (count < 0) {
      return '';
    }
    if (count > 1) {
      return `${count}条`;
    }
    if (count === 1) {
      return '有';
    }
    if (kind === SUBTITLE_KIND_AI && this.biliProbeAiPending) {
      return '生成中';
    }
    return '无';
  }

  /**
   * 探测门控：未登录 / 非 B 站曲目 / 结论性无该类字幕 / AI 生成中 → 禁用；
   * 瞬时失败 / 检测中 / 未探测保持可点（点击链自带重试与单飞守卫）。
   */
  private biliButtonDisabled(kind: string): boolean {
    // 本地跳过（未登录 / 非 B 站曲目，未发请求）：两按钮都禁用
    if (this.biliProbeLocalSkip) {
      return true;
    }
    if (!this.biliProbeDone || this.biliProbeTransientFail) {
      return false;
    }
    const count: number = kind === SUBTITLE_KIND_CC ? this.biliProbeCcCount : this.biliProbeAiCount;
    // 该 kind 计数未知（如只点击过另一 kind 的按钮）：不误禁
    if (count < 0) {
      return false;
    }
    if (count > 0) {
      return false;
    }
    // AI 惰性生成中：禁用，等「重新检测」拿到结果再放开
    if (kind === SUBTITLE_KIND_AI && this.biliProbeAiPending) {
      return true;
    }
    return true;
  }

  /** 按钮文案：busy 时「获取中…」，否则基础文案 + 探测后缀（`B站字幕(CC) · 有`） */
  private biliButtonLabel(kind: string): string {
    if (this.biliSubtitleBusy) {
      return '获取中…';
    }
    const base: string = kind === SUBTITLE_KIND_CC ? 'B站字幕(CC)' : 'B站AI字幕';
    const suffix: string = this.biliButtonSuffix(kind);
    return suffix.length > 0 ? `${base} · ${suffix}` : base;
  }

  /**
   * B 站字幕失败文案（取列表 / 取数共用）。判定次序：登录态优先于
   * definitive（登录失效时即使空列表，真实原因也是登录，不能骗用户「没字幕」）；
   * no-candidate（该 kind 过滤后无候选）按 kind 引导另一个按钮；
   * 其余 definitive（empty / denied / dirty）给统一「没有可用」文案；
   * 瞬时失败（timeout / network / risk）提示稍后再试。
   */
  private biliFailText(kind: string, definitive: boolean, reason: string): string {
    if (!isLoggedIn() || isLoginStale()) {
      return '登录后可获取 B 站字幕';
    }
    // AI 惰性生成中（条目存在但无 URL / 内容半截）：不是网络问题，
    // 不能误报「网络繁忙」把用户引向无意义的反复重试
    if (reason === 'dirty') {
      return 'AI 字幕生成中，请稍后再试';
    }
    // 串台（响应身份校验拦截，重试后仍是别的视频的数据）：服务端缓存不一致，
    // 与本机网络无关，也别用「网络繁忙」误导用户反复重试
    if (reason === 'mismatch') {
      return '字幕数据异常，请稍后重试';
    }
    if (definitive) {
      if (reason === 'no-candidate' && kind === SUBTITLE_KIND_CC) {
        return '该视频没有 CC 字幕，试试「B站AI字幕」';
      }
      if (reason === 'no-candidate' && kind === SUBTITLE_KIND_AI) {
        return '该视频没有 AI 字幕，试试「B站字幕(CC)」';
      }
      return '该视频没有可用的 CC / AI 字幕';
    }
    return '网络繁忙，稍后再试';
  }

  /** 字幕选项主行标签：`中文 (AI)` / `英语 (CC)`（未知语言原样展示 lan） */
  private biliChoiceLabel(choice: SubtitleChoice): string {
    let langName: string = choice.lan;
    if (choice.lan.indexOf('zh') >= 0) {
      langName = '中文';
    } else if (choice.lan === 'en') {
      langName = '英语';
    } else if (choice.lan === 'ja') {
      langName = '日语';
    } else if (choice.lan === 'ko') {
      langName = '韩语';
    }
    return `${langName} (${choice.isAi ? 'AI' : 'CC'})`;
  }

  /** 复位手动搜索区（弹窗 onDisappear / 手选成功后共用）：回干净入口态 */
  private resetLyricSearchSection(): void {
    this.lyricSearchExpanded = false;
    this.lyricSearchKeyword = '';
    this.lyricSearching = false;
    this.lyricCandidates = [];
    this.lyricSearchMsg = '';
    this.lyricPickingId = '';
    this.biliSubtitleBusy = false;
    this.biliSubtitleChoices = [];
    this.biliSubtitlePickingId = '';
    // 探测状态一并复位：下次开面板（@Watch）重新探测
    this.resetBiliProbe();
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
    // 类型保护：currentTrack 运行时可能是 undefined（=== null 拦不住）；
    // id 空/缺失（旧快照坏数据）走重置分支 —— 歌词缓存按 id 为键，空 id 无意义
    if (track === null || track === undefined || (track.id ?? '').length === 0) {
      this.lastTrackKey = '';
      this.lastLyricKey = '';
      this.lyricToken++;
      this.cancelBiliPartialRefresh();
      this.mLrcEntryList = [];
      this.lyricOffsetMs = 0;
      this.biliSubtitleChoices = [];
      this.biliSubtitlePickingId = '';
      this.resetBiliProbe();
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
      // 上一首的字幕候选列表已失效（那些 subtitle_url 属于旧视频），
      // 不清的话点选会把旧视频字幕写进新歌的 manual 缓存
      this.biliSubtitleChoices = [];
      this.biliSubtitlePickingId = '';
      // 上一首的字幕可用性探测结论同属旧视频，一并作废
      this.resetBiliProbe();
      // 上一首挂起的后台补全同属旧视频，一并取消
      this.cancelBiliPartialRefresh();
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
    // ?. 同时兜住 null 与 undefined（@StorageLink 运行时可能送 undefined）
    return this.currentTrack?.coverUrl ?? '';
  }

  private titleText(): string {
    const t: Track | null = this.currentTrack;
    if (t === null || t === undefined) {
      return '暂无播放内容';
    }
    const title: string = t.title ?? '';
    return title.length > 0 ? title : '未知歌曲';
  }

  private artistText(): string {
    const t: Track | null = this.currentTrack;
    if (t === null || t === undefined) {
      return '—';
    }
    const artist: string = t.artist ?? '';
    return artist.length > 0 ? artist : '未知歌手';
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
      Row() {
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
        .layoutWeight(1)

        // 居中显示：开关在面板右上角。开启后每行歌词以歌词区水平中心绘制
        // （Apple Music 风格），默认左对齐。切换 = 写偏好落盘（updateSettings）
        // + 刷 AppStorage 镜像 —— @StorageProp 订阅触发 LrcView 的
        // @Prop @Watch 原地重绘，面板悬浮在歌词上方，效果即时可见。
        Row({ space: 8 }) {
          Text('居中显示')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          Toggle({ type: ToggleType.Switch, isOn: this.lyricCentered })
            .selectedColor(this.themePrimary)
            .onChange((v: boolean): void => {
              AppPreferences.updateSettings((s: AppSettings): void => {
                s.lyricCentered = v;
              });
              AppStorage.setOrCreate(STORE_LYRIC_CENTERED, v);
            })
        }
        .alignItems(VerticalAlign.Center)
      }
      .width(StyleConstants.FULL_WIDTH)
      .alignItems(VerticalAlign.Center)

      // 整体偏移：居中大字 + 全宽滑块（±30s、0.1s 步进）。拖动中每步只改内存
      // lyricOffsetMs（@State → LrcView 的 lyricMilliSecondsTime 即时重算，面板后
      // 歌词实时偏移预览），松手 / 点按轨道时才一次落盘 —— 拖动不产生偏好写入。
      // onChange 的 Math.round(value * 1000) 兼收两职：ms 取整落盘 + 消除 step 0.1
      // 的浮点尾差（0.1 步进滑条原生 value 会出现 35.70000…76 尾差，取整即净）。
      Column({ space: 4 }) {
        Text(this.offsetText())
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width(StyleConstants.FULL_WIDTH)
          .textAlign(TextAlign.Center)
        Slider({ value: this.lyricOffsetMs / 1000, min: -30, max: 30, step: 0.1 })
          .width(StyleConstants.FULL_WIDTH)
          .accessibilityText('歌词整体偏移滑块，左右拖动调整，0.1 秒一步')
          .onChange((value: number, mode: SliderChangeMode): void => {
            const ms: number = Math.round(value * 1000);
            // 实时预览：内存值驱动面板后歌词即时偏移（与原 ±0.5s 按钮同刷新路径）
            this.lyricOffsetMs = ms;
            // 松手（End）/ 点按轨道跳转（Click）才落盘；Begin/Moving 只预览
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              const track: Track | null = this.currentTrack;
              if (track !== null && track !== undefined && (track.id ?? '').length > 0) {
                LyricsApi.setLyricOffset(track.id, ms);
              }
            }
          })
      }
      .width(StyleConstants.FULL_WIDTH)

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
          .stateStyles({
            pressed: { .backgroundColor($r('app.color.press_overlay')) },
            normal: { .backgroundColor(Color.Transparent) }
          })
          .onClick((): void => {
            const track: Track | null = this.currentTrack;
            if (track === null || track === undefined || (track.id ?? '').length === 0) {
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
          .stateStyles({
            pressed: { .opacity(0.85) },
            normal: { .opacity(1) }
          })
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
          .stateStyles({
            pressed: { .backgroundColor($r('app.color.press_overlay')) },
            normal: { .backgroundColor(Color.Transparent) }
          })
          .onClick((): void => {
            void this.skipLyric();
          })
      }
      .width(StyleConstants.FULL_WIDTH)

      // B 站字幕手动入口：外部曲库搜不到 / 匹配错时，改用视频字幕
      // （CC = 人工上传，准确率高；AI = 语音识别，无 CC 视频的兜底）。
      // 面板打开即探测可用性（onSheetOpenChanged）：按钮带「有 / N条 /
      // 生成中 / 无」后缀；结论性无该类字幕时禁用（灰显 + enabled(false)），
      // 瞬时失败 / 检测中保持可点（点击链自带重试）。取列表期间共用 busy 态。
      Row({ space: 12 }) {
        Text(this.biliButtonLabel(SUBTITLE_KIND_CC))
          .fontSize(13)
          .fontColor(this.biliButtonDisabled(SUBTITLE_KIND_CC)
            ? $r('app.color.text_tertiary') : $r('app.color.text_secondary'))
          .height(44)
          .layoutWeight(1)
          .borderRadius(12)
          .borderWidth(1)
          .borderColor($r('app.color.bg_divider'))
          .textAlign(TextAlign.Center)
          .opacity(this.biliButtonDisabled(SUBTITLE_KIND_CC)
            ? 0.4 : (this.biliSubtitleBusy ? 0.6 : 1))
          .enabled(!this.biliButtonDisabled(SUBTITLE_KIND_CC))
          .stateStyles({
            pressed: { .backgroundColor($r('app.color.press_overlay')) },
            normal: { .backgroundColor(Color.Transparent) }
          })
          .onClick((): void => {
            void this.useBiliSubtitle(SUBTITLE_KIND_CC);
          })
        Text(this.biliButtonLabel(SUBTITLE_KIND_AI))
          .fontSize(13)
          .fontColor(this.biliButtonDisabled(SUBTITLE_KIND_AI)
            ? $r('app.color.text_tertiary') : $r('app.color.text_secondary'))
          .height(44)
          .layoutWeight(1)
          .borderRadius(12)
          .borderWidth(1)
          .borderColor($r('app.color.bg_divider'))
          .textAlign(TextAlign.Center)
          .opacity(this.biliButtonDisabled(SUBTITLE_KIND_AI)
            ? 0.4 : (this.biliSubtitleBusy ? 0.6 : 1))
          .enabled(!this.biliButtonDisabled(SUBTITLE_KIND_AI))
          .stateStyles({
            pressed: { .backgroundColor($r('app.color.press_overlay')) },
            normal: { .backgroundColor(Color.Transparent) }
          })
          .onClick((): void => {
            void this.useBiliSubtitle(SUBTITLE_KIND_AI);
          })
      }
      .width(StyleConstants.FULL_WIDTH)

      // 探测提示行：未登录 / 非 B 站 / 该视频无字幕 / AI 生成中 / 检测失败；
      // 瞬时失败时给「重新检测」入口（探测链已带抖动重试，正常路径无需人工干预）
      if (this.biliProbeHint.length > 0) {
        Row({ space: 8 }) {
          Text(this.biliProbeHint)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.biliProbeTransientFail) {
            Text('重新检测')
              .fontSize(12)
              .fontColor(this.themePrimary)
              .onClick((): void => {
                void this.runBiliProbe(true);
              })
          }
        }
        .width(StyleConstants.FULL_WIDTH)
        .alignItems(VerticalAlign.Center)
      }

      // 多候选字幕列表：单候选直选不经过这里；>1 时让用户明确挑，
      // 不再自动选优碰运气（智能字幕内容不稳定，同 URL 每次拉取行数乱跳）
      if (this.biliSubtitleChoices.length > 0) {
        List({ space: 0 }) {
          ForEach(this.biliSubtitleChoices, (choice: SubtitleChoice) => {
            ListItem() {
              Row() {
                Column({ space: 2 }) {
                  Text(this.biliChoiceLabel(choice))
                    .fontSize(14)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${choice.lan} · ${choice.isAi ? 'AI 识别' : '人工上传'}`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (this.biliSubtitlePickingId === choice.id) {
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
                void this.pickBiliSubtitleChoice(choice);
              })
            }
          }, (choice: SubtitleChoice): string => choice.id)
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
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.press_overlay')) },
          normal: { .backgroundColor(Color.Transparent) }
        })
        .onClick((): void => {
          if (this.lyricSearchExpanded) {
            this.lyricSearchExpanded = false;
            return;
          }
          this.lyricSearchExpanded = true;
          // 展开预填：清洗后的歌名（用户可改成「歌名 歌手」组合词）
          if (this.lyricSearchKeyword.length === 0) {
            const track: Track | null = this.currentTrack;
            if (track !== null && track !== undefined) {
              const title: string = track.title ?? '';
              const cleaned: string = cleanTitle(title);
              this.lyricSearchKeyword = cleaned.length > 0 ? cleaned : title;
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
              .stateStyles({
                pressed: { .opacity(0.85) },
                normal: { .opacity(1) }
              })
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
            // 小尺寸头图走 CDN 缩略图，避免下载解码原图
            Image(toThumbUrl(this.coverUrl(), 128))
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
                LrcViewHost({
                  lyricOffsetMs: this.lyricOffsetMs,
                  mLrcEntryList: this.mLrcEntryList,
                  lyricScrollEffect: this.lyricScrollEffect,
                  lyricCentered: this.lyricCentered,
                  pageActive: this.pageActive,
                  onLongPress: (): void => {
                    this.showLyricSheet = true;
                  }
                })
              }
            }
          }
        }
        .layoutWeight(1)
      } else {
        LrcViewHost({
          lyricOffsetMs: this.lyricOffsetMs,
          mLrcEntryList: this.mLrcEntryList,
          lyricScrollEffect: this.lyricScrollEffect,
          lyricCentered: this.lyricCentered,
          pageActive: this.pageActive,
          onLongPress: (): void => {
            this.showLyricSheet = true;
          }
        })
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
