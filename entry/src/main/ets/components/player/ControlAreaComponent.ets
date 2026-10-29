/**
 * 播放控制区。
 *
 * 版式自上而下：功能行（Swiper 分页：全部 9 个功能项按用户排序
 * （STORE_FUNC_ITEM_ORDER，设置 → 播放设置 → 自定义功能栏拖动调整）过滤
 * 后每页 4 个等宽槽位分页展示，核心键「播放模式 / 下载 / 加入歌单 / 队列」
 * 恒在，开关入口「倍速 / 限定进度 / 定时停止 / 在 B 站打开 / 进入 UP 主页」
 * 按各自开关决定是否渲染；多页时双侧箭头按页位显隐；图标统一尺寸、
 * 内容居中到同一条中线）→ 进度条 + 双侧时间 → 三键控制行。
 * 紧凑模式（compactMode，阔折叠外屏）：功能行与进度区整体不挂载
 * （条件渲染而非 visibility 隐藏），只渲染三键行（聚拢左对齐）。
 * 控制调用全部走 MusicPlayer 单例；队列弹层复用共享组件 QueueSheet；
 * 按用户决策不引入收藏 / 静音按钮。
 *
 * 动效拆分（每条动画独立变量、互不共用，无全局统一 animation）：
 *   · 播放/暂停主按钮 → 独立子组件 PlayButtonComponent（呼吸形变 + 点击回弹自理）；
 *   · 模式 / 列表 / 上一曲 / 下一曲 → BounceIconButton（仅点击单次回弹，无持续动画）；
 *   · 进度条 → 独立子组件 PlayerProgressArea（订阅必须圈死在进度区小子树内：
 *     STORE_PROGRESS 每 500ms 推送一次，订阅挂在本组件上会导致整个控制区
 *     播放期间每 500ms 重渲染一次；拆出后本组件播放期间零重渲染，
 *     进度插值 / 拖拽交互由子组件自理）。
 */

import {
  Track,
  RepeatMode,
  PLAYBACK_SPEED_OPTIONS,
  speedLabelOf,
  VideoDetail,
  VideoPageInfo,
  PLAYER_FUNC_REPEAT,
  PLAYER_FUNC_DOWNLOAD,
  PLAYER_FUNC_ADD_PLAYLIST,
  PLAYER_FUNC_QUEUE,
  PLAYER_FUNC_SPEED,
  PLAYER_FUNC_SKIP,
  PLAYER_FUNC_SLEEP,
  PLAYER_FUNC_BILI,
  PLAYER_FUNC_UP_SPACE,
  DEFAULT_FUNC_ITEM_ORDER
} from '../../model/MusicModels';
import { getVideoDetail } from '../../api/BilibiliApi';
import common from '@ohos.app.ability.common';
import { MusicPlayer } from '../../player/MusicPlayer';
import { QueueSheet, repeatLabelOf, modeIconOf, nextRepeatMode } from '../QueueSheet';
import { StyleConstants } from '../../common/constants/StyleConstants';
import { showAppToast } from '../AppToast';
import { showConfirm } from '../AppAlertDialog';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { BreakpointType } from '../../common/utils/BreakpointSystem';
import { PlayButtonComponent } from './PlayButtonComponent';
import { BounceIconButton } from './BounceIconButton';
import { PlayerProgressArea } from './PlayerProgressArea';
import { SleepTimerChip } from './SleepTimerChip';
import { LibraryStore } from '../../service/LibraryStore';
import { skipIntroSecOf, skipOutroSecOf, setTrackSkipRange } from '../../service/IntroSkipStore';
import { NavStackHolder } from '../../service/NavStackHolder';
import { UpSpaceRouteParam } from '../../service/NavRouteParams';
import { CustomContentDialog } from '@kit.ArkUI';
import { Playlist } from '../../model/MusicModels';
import {
  DownloadManager,
  DownloadStartResult,
  WIFI_ONLY_BLOCKED
} from '../../service/DownloadManager';
import {
  STORE_CURRENT_TRACK,
  STORE_DURATION,
  STORE_REPEAT_MODE,
  RESUME_TAIL_SEC,
  STORE_PLAYBACK_SPEED_ENABLED,
  STORE_PLAYBACK_SPEED,
  STORE_OPEN_IN_BILI_ENABLED,
  STORE_SLEEP_TIMER_ENTRY_ENABLED,
  STORE_SKIP_INTRO_ENTRY_ENABLED,
  STORE_UP_SPACE_ENTRY_ENABLED,
  STORE_FUNC_ITEM_ORDER,
  STORE_PLAYER_OPEN,
  STORE_PLAYER_CONTENT_EXIT,
  STORE_PICK_PLAYLIST_ADD,
  STORE_PLAYER_CLOSE_REQUEST,
  STORE_TAB_SWITCH_REQUEST,
  STORE_TAB_SWITCH_TARGET
} from '../../common/Constants';
import {
  ENTRANCE_DURATION_MS,
  ENTRANCE_OFFSET_VP,
  LAYER_DELAY_CONTROL,
  LAYER_EXIT_DURATION_MS,
  LAYER_EXIT_DELAY_CONTROL,
  PRESS_ANIM_MS,
  PRESS_SCALE
} from '../../common/constants/InteractionConstants';

/** 切歌键（上一曲 / 下一曲）图标与圆底尺寸 */
const PREVNEXT_ICON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 26, md: 26, lg: 30 });
const PREVNEXT_BUTTON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 52, md: 52, lg: 60 });
/** 功能键（播放模式 / 下载 / 加入歌单 / 播放列表）图标与圆底尺寸 */
const FUNC_ICON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 22, md: 22, lg: 26 });
const FUNC_BUTTON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 40, md: 40, lg: 46 });
/** 功能行 Swiper 每页槽位数（4 = 常规屏一页恰为四等分；排序页「前 4 位默认显示」对应第 1 页） */
const FUNC_ITEMS_PER_PAGE: number = 4;
/** 紧凑模式三键行间距：三键聚拢左对齐时的呼吸间距（常规两端分布时不用，space=0） */
const COMPACT_CTRL_GAP: number = 36;
/** 倍速片字号：缩进等宽槽位（FUNC_BUTTON_SIZE）；最长标签 "0.75x" 留有余量 */
const SPEED_FONT_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 14, md: 14, lg: 15 });
/** 倍速片最小字号（槽位宽度约束内自适应缩字的下限） */
const SPEED_MIN_FONT_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 10, md: 10, lg: 11 });
/**
 * 「加入歌单」弹层最多列几个歌单。
 * 超出的不静默截断，而是多给一条「还有 N 个…去歌单页选」——
 * 静默截断会让人以为「我的歌单」不存在。
 */
const PLAYLIST_PICKER_MAX: number = 5;
/** 歌单页签下标（与 Index 的 TAB_PLAYLISTS 同值；模块私有常量跨文件不可引用） */
const TAB_INDEX_PLAYLISTS: number = 1;

/** 「限定播放进度」秒数归一（0.1s 网格收口）：滑条步进 / 输入框解析 / 保存 clamp 共用，防浮点尾差 */
function roundRangeTenth(v: number): number {
  return Math.round(v * 10) / 10;
}

/** 「限定播放进度」秒数显示：37.5 → "37.5"、30 → "30"（整数不带多余的 .0） */
function formatRangeSec(v: number): string {
  return String(roundRangeTenth(v));
}

/** 「限定播放进度」输入框解析：非有限值 / 负数返回 -1 哨兵（调用方只认 ≥ 0） */
function parseRangeSec(text: string): number {
  const v: number = parseFloat(text);
  return (!Number.isFinite(v) || v < 0) ? -1 : v;
}

@Component
export struct ControlAreaComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /**
   * 紧凑模式（阔折叠外屏 / 紧凑横屏左列）：
   * 功能行 / 进度区 / 时间行整体不挂载，仅渲染三键行（聚拢左对齐）。
   * 默认 false：SM / MD / LG / 折叠展开四分支行为零变化。
   */
  @Prop compactMode: boolean = false;
  /**
   * 三键行居中（紧凑横屏左列版式）：compactMode 且 centerMode 时
   * 三键行由左对齐改居中（左列歌名/歌手/封面均居中，控制区同轴）。
   * 默认 false：Pura X 外屏等既有 compactMode 调用点保持左对齐零变化。
   */
  @Prop centerMode: boolean = false;
  @StorageLink(STORE_REPEAT_MODE) repeatMode: RepeatMode = RepeatMode.NONE;
  @StorageLink(STORE_CURRENT_TRACK) currentTrack: Track | null = null;
  /** 队列弹层开关（本组件自持，bindSheet 挂在播放列表按钮上） */
  @State showQueueSheet: boolean = false;
  /** 「下载」请求在途：连点会重复提交同一首（提交后立刻变「已在队列」，体验是「点了没反应」） */
  @State downloading: boolean = false;
  /**
   * 歌单菜单新鲜度版本号：bindMenu 的 MenuElement 数组在渲染时求值，
   * 新建歌单后自增它触发重渲染，下次打开菜单就能看到新歌单。
   */
  @State playlistMenuVersion: number = 0;
  /** 「加入歌单」按钮按压反馈缩放（onTouch 驱动，不消费事件，与 bindMenu 共存） */
  @State menuButtonScale: number = 1;
  /** 倍速总开关（设置页镜像）：关 = 功能行不渲染倍速片；变化 = 功能行组合变（回第 0 页） */
  @StorageProp(STORE_PLAYBACK_SPEED_ENABLED) @Watch('onFuncCompositionChanged') speedEnabled: boolean = false;
  /** 「在 B 站打开原视频」开关（设置页镜像）：关 = 功能行不渲染跳转入口；变化 = 组合变（回第 0 页） */
  @StorageProp(STORE_OPEN_IN_BILI_ENABLED) @Watch('onFuncCompositionChanged') openInBiliEnabled: boolean = true;
  /** 「限定播放进度」入口开关（设置页镜像，默认关）：关 = 功能行不渲染文本片；变化 = 组合变（回第 0 页） */
  @StorageProp(STORE_SKIP_INTRO_ENTRY_ENABLED) @Watch('onFuncCompositionChanged') skipEntryEnabled: boolean = false;
  /** 「定时停止入口」开关（设置页镜像）：开 = 功能行左组渲染 SleepTimerChip；变化 = 组合变（回第 0 页） */
  @StorageProp(STORE_SLEEP_TIMER_ENTRY_ENABLED) @Watch('onFuncCompositionChanged') sleepEntryEnabled: boolean = false;
  /** 「进入 UP 主页」入口开关（设置页镜像）：开 = 功能行渲染「进入 UP 主页」跳转入口；变化 = 组合变（回第 0 页） */
  @StorageProp(STORE_UP_SPACE_ENTRY_ENABLED) @Watch('onFuncCompositionChanged') upSpaceEntryEnabled: boolean = false;
  /** 当前倍速（MusicPlayer.setStore 写回 → 倍速片标签与菜单 ✓ 实时刷新） */
  @StorageProp(STORE_PLAYBACK_SPEED) playbackSpeed: number = 1.0;
  /** 倍速片按压反馈缩放（onTouch 驱动，不消费事件，与 bindMenu 共存） */
  @State speedButtonScale: number = 1;
  /** 「限定播放进度」弹窗片头跳过秒数预览值（0.1 网格；拖动 / 键入只改预览，保存才落盘） */
  @State rangeHeadSec: number = 0;
  /** 「限定播放进度」弹窗片尾跳过秒数预览值（从结尾倒数，0.1 网格；语义同上） */
  @State rangeTailSec: number = 0;
  /** 「限定播放进度」弹窗片头秒数输入框受控文本（滑条拖动实时刷新；键入合法值反向驱动滑条） */
  @State headInputText: string = '0';
  /** 「限定播放进度」弹窗片尾秒数输入框受控文本（同上） */
  @State tailInputText: string = '0';
  /** 当前播放时长镜像（弹窗滑条上界的兜底数据源：Track 自带时长缺失时用正在播的真实时长） */
  @StorageProp(STORE_DURATION) durationMirror: number = 0;
  /** 「限定播放进度」区间条弹窗 controller（aboutToAppear 建一次，官方 CustomContentDialog） */
  private rangeDialogController: CustomDialogController | null = null;

  /**
   * 功能行功能项顺序（排序页拖动后 EntryAbility 镜像发布；前 4 位 = Swiper 第 1 页默认显示）。
   * 变化 = 组合变 → 回第 0 页。
   */
  @StorageProp(STORE_FUNC_ITEM_ORDER) @Watch('onFuncCompositionChanged') funcItemOrder: string[] = DEFAULT_FUNC_ITEM_ORDER;
  /** 功能行 Swiper 当前页下标（双侧箭头显隐依据；组合变化时由 @Watch 归零） */
  @State funcPageIndex: number = 0;

  private player: MusicPlayer = MusicPlayer.getInstance();

  aboutToAppear(): void {
    this.exitRequested = false;
    // 「限定播放进度」弹窗（官方 CustomContentDialog，HomePage「加入歌单」同款）：
    // 两条独立调整条（片头 / 片尾，0.1s 步进）+ 各自右侧秒数输入框（双向实时同步）；
    // 「不限」清两端设置、「保存」校验后落盘
    this.rangeDialogController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: '限定播放进度',
        contentBuilder: (): void => {
          this.RangeDialogBody();
        },
        buttons: [
          {
            value: '不限',
            buttonStyle: ButtonStyleMode.TEXTUAL,
            action: (): void => {
              this.clearPlayRange();
            }
          },
          {
            value: '保存',
            buttonStyle: ButtonStyleMode.EMPHASIZED,
            action: (): void => {
              this.savePlayRange();
            }
          }
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    // 分层入场：控制区最后落位（LAYER_DELAY_CONTROL）。
    // 延迟交给 animateTo 的 delay —— 不用 setTimeout，少一个要清理的定时器。
    this.getUIContext().animateTo(
      { duration: ENTRANCE_DURATION_MS, curve: Curve.EaseOut, delay: LAYER_DELAY_CONTROL },
      (): void => {
        // 竞态闸门：打开后 400ms 内收起时，本延迟闭包仍在途——不拦会把已瞬隐的
        // 控制区重新点亮（收起飞行途中闪现）。
        if (!this.exitRequested) {
          this.enterOpacity = 1;
          this.enterOffsetY = 0;
        }
      }
    );
  }

  /**
   * 分层入场的起始态。
   * 必须是 `@State`：普通成员只在创建时初始化一次，父组件重渲染不会重新赋值
   * （踩过：SeekBar.interactive 用普通成员导致「完全拖不动」）。
   */
  @State enterOpacity: number = 0;
  @State enterOffsetY: number = ENTRANCE_OFFSET_VP;

  /**
   * 播放页展开态：收起（→ false，落在 Index.closePlayer 的主动画闭包内）时
   * 把控制区入场状态复位为隐藏 —— 与 onContentExit 复位幂等兜底（那时已是隐藏值，
   * 同值复位不产生属性变化，不会触发动画）。
   */
  @StorageProp(STORE_PLAYER_OPEN) @Watch('onPlayerOpenChanged') playerOpen: boolean = false;

  /**
   * 收起时内容层柔退信号（seq 递增，写在 Index.closePlayer 的主动画闭包**外**，
   * 仅柔退路径递增）：控制区 200ms EaseIn 柔退淡出 + 回沉（末批退场 LAYER_EXIT_DELAY_CONTROL）。
   */
  @StorageProp(STORE_PLAYER_CONTENT_EXIT) @Watch('onContentExit') contentExitSeq: number = 0;
  /** 柔退闸门：onContentExit 置 true 后，在途的延迟入场闭包不得再把控制区点亮 */
  private exitRequested: boolean = false;

  /** 收起复位：入场状态回隐藏态（幂等兜底，见 playerOpen 注释） */
  private onPlayerOpenChanged(): void {
    if (this.playerOpen) {
      return;
    }
    this.enterOpacity = 0;
    this.enterOffsetY = ENTRANCE_OFFSET_VP;
  }

  /** 柔退复位：控制区 200ms EaseIn 淡出 + 回沉 ENTRANCE_OFFSET_VP + 拦截在途延迟入场 */
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
        this.enterOffsetY = ENTRANCE_OFFSET_VP;
      }
    );
  }

  /** 短提示：模式这种「图标变化不明显」的切换给一次文字反馈 */
  private toast(message: string): void {
    showAppToast(message);
  }

  private cycleRepeat(): void {
    const next: RepeatMode = nextRepeatMode(this.repeatMode);
    this.player.setRepeatMode(next);
    this.toast(`播放模式：${repeatLabelOf(next)}`);
  }

  // ===== 播放页的两个新动作：下载 / 加入歌单 =====
  //
  // 放在播放页而不是只留在列表菜单，是因为**「听到一半想留着」是播放场景的高频动作**，
  // 不用退回列表再找一次。两者都作用于 `currentTrack`，没在播时给出明确提示而不是静默。

  /**
   * 下载当前正在播放的曲目。
   *
   * 正在播分 P 合集的某一 P 时**只下这一 P**（singleOnly）：用户在播放场景想留的是
   * 「正在听的这首」，整合集下载留给列表页入口。想下整个合集去原列表条目点下载即可。
   *
   * 三条路径要分清：
   *   · 已在下载队列 / 已完成 → 直接告诉用户「不用重复下」；
   *   · 被「仅 WiFi 下载」拦下 → 问一次（与列表页同一套措辞与行为）；
   *   · 正常 → 排队（singleOnly 下永远只有当前这一首）。
   */
  private async downloadCurrent(): Promise<void> {
    const track: Track | null = this.currentTrack;
    if (track === null) {
      this.toast('还没有正在播放的曲目');
      return;
    }
    if (this.downloading) {
      this.toast('正在提交，请稍候');
      return;
    }
    this.downloading = true;
    try {
      const r: DownloadStartResult = await DownloadManager.getInstance().requestDownload(track, false, undefined, true);
      if (r.blockedReason.length > 0) {
        this.confirmCellularDownload(track);
        return;
      }
      if (r.queued === 0 && r.skipped > 0) {
        this.toast('已在下载队列或已下载');
        return;
      }
      if (r.queued === 0) {
        this.toast('这条没有可下载的音频');
        return;
      }
      this.toast(r.queued > 1 ? `已加入下载队列 ${r.queued} 首` : '已加入下载队列');
    } catch (e) {
      const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.error(`downloadCurrent failed: ${detail}`);
      this.toast('下载启动失败，请稍后再试');
    } finally {
      this.downloading = false;
    }
  }

  /**
   * 在 B 站打开原视频：优先 `bilibili://video/{bvid}` 深链拉官方 App
   * （appLinkingOnly，没装/未注册 scheme 会抛错）；失败降级
   * `https://www.bilibili.com/video/{bvid}` 交给系统（浏览器必达，
   * 装 App 时也可能经 App Linking 直跳）。分 P 曲目（id 形如 `BV…#cid`）
   * 先查 `getVideoDetail` 把 cid 换算成 `?p=N` 精确定位，查询失败降级
   * 不带 p（跳到 P1 也比跳不走强）。
   */
  private async openInBilibili(): Promise<void> {
    const track: Track | null = this.currentTrack;
    // 类型保护：@StorageLink 运行时可能送 undefined（=== null 拦不住）
    if (track === null || track === undefined) {
      this.toast('还没有正在播放的曲目');
      return;
    }
    const id: string = track.id;
    if (!id.startsWith('BV')) {
      this.toast('这条没有对应的 B 站视频');
      return;
    }
    const sep: number = id.indexOf('#');
    const bvid: string = sep >= 0 ? id.substring(0, sep) : id;
    const cidStr: string = sep >= 0 ? id.substring(sep + 1) : '';
    let pSuffix: string = '';
    if (cidStr.length > 0) {
      try {
        const detail: VideoDetail = await getVideoDetail(bvid);
        const idx: number = detail.pages.findIndex((pg: VideoPageInfo): boolean => pg.cid === Number(cidStr));
        if (idx > 0) {
          pSuffix = `?p=${idx + 1}`;
        }
      } catch (e) {
        console.error(`getVideoDetail for p-param failed: ${JSON.stringify(e)}`);
      }
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await ctx.openLink(`bilibili://video/${bvid}`, { appLinkingOnly: true });
      return;
    } catch (e) {
      console.error(`openLink scheme failed: ${JSON.stringify(e)}`);
    }
    try {
      await ctx.openLink(`https://www.bilibili.com/video/${bvid}${pSuffix}`);
    } catch (e) {
      console.error(`openLink https failed: ${JSON.stringify(e)}`);
      this.toast('无法打开 B 站页面');
    }
  }

  /**
   * 「进入 UP 主页」→ 站内页（UpSpacePage），HomePage.openUpSpace 同款。
   *
   * mid 两条来源：曲目自带 upMid（列表映射时已落）直接用，零请求；没有的
   * （音乐中心 / 已下载曲目）用 bvid 走 getVideoDetail 换 owner.mid
   * （带 viewCache，TTL 内同一首反复点不重复发请求）。
   *
   * 跳转前先递增收起请求收起播放页 overlay —— push 转场发生在收起动画之下，
   * overlay 收回时露出的就是 UP 主页（与「去歌单页选」同一手法）。
   */
  private async openUpSpace(): Promise<void> {
    const track: Track | null = this.currentTrack;
    // 类型保护：@StorageLink 运行时可能送 undefined（=== null 拦不住）
    if (track === null || track === undefined) {
      this.toast('还没有正在播放的曲目');
      return;
    }
    // ⚠️ `?? ''` 不能省：旧版本落盘的曲目（已下载 / 收藏 / 最近播放）没有
    // upMid 字段，运行时读出来是 undefined，直接读 `.length` 会崩。
    let mid: string = track.upMid ?? '';
    if (mid.length === 0) {
      const bvid: string = track.bvid.length > 0 ? track.bvid : track.id;
      if (bvid.indexOf('BV') !== 0) {
        this.toast('这条没有 UP 主信息');
        return;
      }
      this.toast('正在获取投稿作者…');
      try {
        const detail: VideoDetail = await getVideoDetail(bvid);
        mid = detail.owner ? String(detail.owner.mid) : '';
      } catch (e) {
        console.error(`openUpSpace resolve mid failed: ${JSON.stringify(e)}`);
        mid = '';
      }
      if (mid.length === 0) {
        this.toast('获取 UP 主失败');
        return;
      }
    }
    const closeSeq: number | undefined = AppStorage.get<number>(STORE_PLAYER_CLOSE_REQUEST);
    AppStorage.setOrCreate(STORE_PLAYER_CLOSE_REQUEST, (closeSeq ?? 0) + 1);
    // 头像传空串占位：曲目行不带 UP 头像，UpSpacePage 用 CoverImage 兜占位图
    NavStackHolder.push('UpSpace', new UpSpaceRouteParam(mid, track.artist, ''));
  }

  /** 「仅 WiFi 下载」拦下时的询问（与 SearchPage / UpSpacePage 同一套流程） */
  private confirmCellularDownload(track: Track): void {
    showConfirm(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: WIFI_ONLY_BLOCKED,
      confirmText: '继续下载',
      onConfirm: (): void => {
        DownloadManager.getInstance().requestDownload(track, true, undefined, true)
          .then((r: DownloadStartResult): void => {
            this.toast(r.queued > 0 ? `已加入下载队列 ${r.queued} 首` : '没有可下载的音频');
          })
          .catch((e: Error): void => {
            console.error(`downloadCurrent(ignoreWifiLimit) failed: ${e.message}`);
            this.toast('下载启动失败，请稍后再试');
          });
      }
    });
  }

  /**
   * 「加入歌单」按钮的标准菜单项（bindMenu + MenuElement 数组）。
   *
   * 新鲜度：数组在**渲染时**求值，新建歌单后由 createPlaylistAndAdd 里的
   * playlistMenuVersion 自增触发重渲染（@StorageLink currentTrack 等状态变化也会顺带刷新）。
   *
   * 行为约定（bindMenu 无法条件性不弹出）：没有任何歌单时弹出
   * 只有一条「新建歌单并加入」的菜单，多一次点击但行为可预期。
   * 歌单很多时只列前 5 个 + 一条「去歌单页选」入口 + 「新建歌单并加入」。
   */
  private playlistMenuItems(): MenuElement[] {
    const track: Track | null = this.currentTrack;
    if (track === null) {
      return [{ value: '还没有正在播放的曲目', enabled: false, action: (): void => {} }];
    }
    const options: Playlist[] = LibraryStore.getAddablePlaylists();
    const items: MenuElement[] = [];
    const shown: Playlist[] = options.length > PLAYLIST_PICKER_MAX
      ? options.slice(0, PLAYLIST_PICKER_MAX)
      : options;
    for (let i = 0; i < shown.length; i++) {
      const target: Playlist = shown[i];
      items.push({
        value: target.name,
        action: (): void => {
          const updated: Playlist | null = LibraryStore.addTrackToPlaylist(target.id, track);
          // 双向收藏夹拦截提示：非 B 站曲目被 store 过滤时明确告知
          const skipped: number = LibraryStore.consumeFavMirrorSkippedCount();
          if (updated !== null && skipped > 0) {
            this.toast(`「${target.name}」是双向同步收藏夹，仅支持添加 B 站曲目`);
            return;
          }
          this.toast(updated ? `已加入「${target.name}」` : '加入歌单失败');
        }
      });
    }
    if (options.length > shown.length) {
      // 歌单多到弹层放不下：给一个明确的去处，而不是静默截断
      items.push({
        value: `还有 ${options.length - shown.length} 个…去歌单页选`,
        action: (): void => {
          this.goToPlaylistsTab();
        }
      });
    }
    items.push({
      value: '新建歌单并加入',
      action: (): void => {
        this.createPlaylistAndAdd(track, options);
      }
    });
    return items;
  }

  /**
   * 「去歌单页选」：收起播放页 overlay + 切到歌单页签 + 让歌单页进入「点选加入」
   * 模式（只切页签不够，用户会落在歌单页无从下手）。
   *
   * 三路信号：
   * · 收起：TopArea 收起按钮同款 seq（STORE_PLAYER_CLOSE_REQUEST）→
   *   Index.closePlayer 收起动画；
   * · 切页签：写目标下标 + 递增 STORE_TAB_SWITCH_REQUEST（Index @Watch 消费：
   *   手机壳走 HdsTabsController.changeIndex，平板壳直写 activeTab）；
   * · 点选加入：递增 STORE_PICK_PLAYLIST_ADD，PlaylistsPage @Watch 快照当前曲目
   *   进入点选模式 —— 整行点击即把曲目加入该歌单（提示条见 PlaylistsPage）。
   * 切页发生在收起动画（700ms）之下，overlay 收回时露出的就是带着提示条的歌单页。
   */
  private goToPlaylistsTab(): void {
    const closeSeq: number | undefined = AppStorage.get<number>(STORE_PLAYER_CLOSE_REQUEST);
    AppStorage.setOrCreate(STORE_PLAYER_CLOSE_REQUEST, (closeSeq ?? 0) + 1);
    AppStorage.setOrCreate(STORE_TAB_SWITCH_TARGET, TAB_INDEX_PLAYLISTS);
    const reqSeq: number | undefined = AppStorage.get<number>(STORE_TAB_SWITCH_REQUEST);
    AppStorage.setOrCreate(STORE_TAB_SWITCH_REQUEST, (reqSeq ?? 0) + 1);
    const pickSeq: number | undefined = AppStorage.get<number>(STORE_PICK_PLAYLIST_ADD);
    AppStorage.setOrCreate(STORE_PICK_PLAYLIST_ADD, (pickSeq ?? 0) + 1);
  }

  /**
   * 没有歌单时的兜底：新建歌单并把当前曲目放进去（名字取自歌名）。
   *
   * 命名规则在 `LibraryStore.nextPlaylistNameForTrack` 里，搜索页共用同一份 ——
   * 这条链路以前和搜索页各写一份 `nextPlaylistName`，改一边就会产生两个同名歌单。
   */
  private createPlaylistAndAdd(track: Track, existing: Playlist[]): void {
    const name: string = LibraryStore.nextPlaylistNameForTrack(track, existing);
    const created: Playlist = LibraryStore.createPlaylist({ name: name });
    const updated: Playlist | null = LibraryStore.addTrackToPlaylist(created.id, track);
    this.toast(updated ? `已新建歌单「${name}」并加入` : '加入歌单失败');
    // 新歌单落库：自增版本号触发重渲染，让 bindMenu 的菜单数组带上新歌单
    this.playlistMenuVersion += 1;
  }

  /** 倍速档位菜单：9 档全列，当前档尾部加 ✓（MenuElement 无选中态，文本标记最简） */
  private speedMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    for (const v of PLAYBACK_SPEED_OPTIONS) {
      const label: string = speedLabelOf(v);
      items.push({
        value: v === this.playbackSpeed ? `${label} ✓` : label,
        action: (): void => {
          this.player.setPlaybackSpeed(v);
          this.toast(`倍速：${label}`);
        }
      });
    }
    return items;
  }

  /**
   * 功能行可见功能项序列：按用户排序（funcItemOrder）过滤。
   * 核心 4 键恒在；5 个开关入口各按对应开关过滤，「限定进度」额外要求有当前曲
   * （播放页无曲不展开，防御性条件）。unknown id 不会出现（AppPreferences 已归一化），
   * 但防御性跳过：其余键位不受影响。
   */
  private visibleFuncItems(): string[] {
    const result: string[] = [];
    for (let i = 0; i < this.funcItemOrder.length; i++) {
      const id: string = this.funcItemOrder[i];
      if (id === PLAYER_FUNC_REPEAT || id === PLAYER_FUNC_DOWNLOAD
        || id === PLAYER_FUNC_ADD_PLAYLIST || id === PLAYER_FUNC_QUEUE) {
        result.push(id);
      } else if (id === PLAYER_FUNC_SPEED && this.speedEnabled) {
        result.push(id);
      } else if (id === PLAYER_FUNC_SKIP && this.skipEntryEnabled && this.currentTrack !== null) {
        result.push(id);
      } else if (id === PLAYER_FUNC_SLEEP && this.sleepEntryEnabled) {
        result.push(id);
      } else if (id === PLAYER_FUNC_BILI && this.openInBiliEnabled) {
        result.push(id);
      } else if (id === PLAYER_FUNC_UP_SPACE && this.upSpaceEntryEnabled) {
        result.push(id);
      }
    }
    return result;
  }

  /**
   * 功能行分页：可见项按 FUNC_ITEMS_PER_PAGE 个一页切片。
   * 每次重建全新数组（ForEach 数据源），页内项数 1~4（末页可不足额，槽位等分摊开）。
   */
  private funcPages(): string[][] {
    const items: string[] = this.visibleFuncItems();
    const pages: string[][] = [];
    for (let i = 0; i < items.length; i += FUNC_ITEMS_PER_PAGE) {
      const end: number = Math.min(i + FUNC_ITEMS_PER_PAGE, items.length);
      const page: string[] = [];
      for (let j = i; j < end; j++) {
        page.push(items[j]);
      }
      pages.push(page);
    }
    return pages;
  }

  /** 页数（>1 才渲染双侧箭头；1 页 = 单页直出，无翻页交互） */
  private funcPageCount(): number {
    return this.funcPages().length;
  }

  /**
   * 组合输入变化（顺序镜像 / 任一开关 / 回调统一入口）：页索引归零。
   * 组合变即页内容变，留在当前页会看到页面内容突变或索引越界，回第 0 页
   * （默认页，核心键所在）最不意外。Swiper 经 .index(this.funcPageIndex) 受控跳转。
   */
  private onFuncCompositionChanged(): void {
    this.funcPageIndex = 0;
  }

  // ===== 按曲「限定播放进度」=====
  //
  // 片头 / 片尾秒数存 IntroSkipStore（键 = musicId，文件 KV 持久化，重启不丢）：
  // 片头在 MusicPlayer.replayStartSec 汇聚点查表起播；片尾在 timeUpdate 实时
  // 查表，到达 时长-片尾秒数 与自然播完同口径自动切歌。本组件只做设置入口
  // （图标键 + 弹窗：两条独立调整条 + 右侧秒数输入框，0.1s 精度）。生效时机：
  // 片尾限定保存后立即生效（正在播的这首到点即切）；片头限定不打断当前播放，
  // 从下一次播放这首歌时生效（弹窗说明）。
  //
  // 滑条与输入框双向同步：拖滑条 → 输入框文本实时刷新；输入框键入合法秒数 →
  // 滑条跟动；键入中途的空串 / 前导 "." 只留在输入框（失焦规范化还原）。
  // 互斥上限：所有写入都经 updateRangeHead / updateRangeTail clamp 到
  // 「时长 - 对端 - RESUME_TAIL_SEC」，限定区间 ≥ 10s 恒成立（保存闸门仅兜底）。

  /** 弹窗时长口径：Track 自带时长优先，兜底当前播放时长镜像（弹窗只对当前曲打开） */
  private rangeDuration(): number {
    const track: Track | null = this.currentTrack;
    if (track !== null && track.duration > 0) {
      return track.duration;
    }
    return this.durationMirror;
  }

  /** 弹窗片头滑条上界：时长 - 片尾 - 10s 保底区间（≥ 0；拖片尾时自动收缩） */
  private rangeHeadMax(): number {
    const dur: number = this.rangeDuration();
    return Math.max(0, roundRangeTenth(dur - this.rangeTailSec - RESUME_TAIL_SEC));
  }

  /** 弹窗片尾滑条上界：时长 - 片头 - 10s 保底区间（≥ 0；拖片头时自动收缩，对称） */
  private rangeTailMax(): number {
    const dur: number = this.rangeDuration();
    return Math.max(0, roundRangeTenth(dur - this.rangeHeadSec - RESUME_TAIL_SEC));
  }

  /** 片头秒数唯一写入口：归 0.1 网格 + 互斥上限 clamp，同步滑条值与输入框文本 */
  private updateRangeHead(v: number): void {
    this.rangeHeadSec = Math.max(0, Math.min(roundRangeTenth(v), this.rangeHeadMax()));
    this.headInputText = formatRangeSec(this.rangeHeadSec);
  }

  /** 片尾秒数唯一写入口：同 updateRangeHead（对称） */
  private updateRangeTail(v: number): void {
    this.rangeTailSec = Math.max(0, Math.min(roundRangeTenth(v), this.rangeTailMax()));
    this.tailInputText = formatRangeSec(this.rangeTailSec);
  }

  /** 打开「限定播放进度」弹窗：两条滑条以当前曲已存设置定格（拖动只改预览，保存才落盘） */
  private openRangeDialog(): void {
    const track: Track | null = this.currentTrack;
    if (track === null) {
      return;
    }
    const dur: number = this.rangeDuration();
    if (dur <= 0) {
      this.toast('暂无法获取这首歌的时长');
      return;
    }
    // 初值 = IntroSkipStore 查表（0.1 网格），联合防御性 clamp（存量旧数据可能贴近
    // 上限；异常值归位而不是拒开弹窗）。先定格片头再按定格后的片头 clamp 片尾。
    const head0: number = roundRangeTenth(skipIntroSecOf(track.id));
    const tail0: number = roundRangeTenth(skipOutroSecOf(track.id));
    this.rangeHeadSec = Math.max(0, Math.min(head0,
      Math.max(0, roundRangeTenth(dur - tail0 - RESUME_TAIL_SEC))));
    this.rangeTailSec = Math.max(0, Math.min(tail0,
      Math.max(0, roundRangeTenth(dur - this.rangeHeadSec - RESUME_TAIL_SEC))));
    this.headInputText = formatRangeSec(this.rangeHeadSec);
    this.tailInputText = formatRangeSec(this.rangeTailSec);
    this.rangeDialogController?.open();
  }

  /** 「不限」按钮：清除该曲两端限定记录（0 = 删条目），下次起播从头播到尾 */
  private clearPlayRange(): void {
    const track: Track | null = this.currentTrack;
    if (track !== null) {
      setTrackSkipRange(track.id, 0, 0);
    }
    this.rangeDialogController?.close();
  }

  /**
   * 「保存」按钮：写入该曲两端限定秒数（0.1 网格落盘；片尾立即生效、片头下次起播生效）。
   * 区间过短闸门（带 0.05s 浮点容差）：限定区间不足 RESUME_TAIL_SEC(10s) 时提示并
   * 不关弹窗 —— 防止「起播点 ≥ 片尾终点 → 起播即切歌」的连环切歌。滑条 / 输入框
   * 已按互斥上限 clamp，此闸门正常不会触发，仅作兜底。
   */
  private savePlayRange(): void {
    const track: Track | null = this.currentTrack;
    if (track === null) {
      this.rangeDialogController?.close();
      return;
    }
    const dur: number = this.rangeDuration();
    if (dur <= 0) {
      this.rangeDialogController?.close();
      return;
    }
    const head: number = Math.max(0, Math.min(roundRangeTenth(this.rangeHeadSec), dur));
    const tail: number = Math.max(0, Math.min(roundRangeTenth(this.rangeTailSec), dur));
    // 两端都归位（片头 0 / 片尾 0）= 清除限定记录
    if (head <= 0 && tail <= 0) {
      this.clearPlayRange();
      return;
    }
    if (dur - tail - head < RESUME_TAIL_SEC - 0.05) {
      this.toast(`限定区间过短，请至少保留 ${RESUME_TAIL_SEC} 秒`);
      return;
    }
    setTrackSkipRange(track.id, head, tail);
    this.rangeDialogController?.close();
  }

  /** 「限定播放进度」弹窗正文：曲名 + 片头 / 片尾两组（标签 + 滑条 + 右侧秒数输入框）+ 生效说明 */
  @Builder
  RangeDialogBody(): void {
    Column() {
      // 曲名行：确认设置落在哪首上（与「加入歌单」弹窗曲名行同款）
      Text(this.currentTrack !== null ? this.currentTrack.title : '')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ bottom: 12 })
      // 片头组标签
      Text('跳过片头')
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: 2 })
      // 片头组：滑条（0.1 步进，上界随片尾值互斥收缩）+ 右侧秒数输入框（双向同步）
      Row() {
        Slider({
          value: this.rangeHeadSec,
          min: 0,
          max: Math.max(0.1, this.rangeHeadMax()),
          step: 0.1
        })
          .layoutWeight(1)
          .selectedColor($r('app.color.slider_select'))
          .trackColor($r('app.color.slider_track'))
          .onChange((value: number): void => {
            // Begin/Moving/End/Click 全档同步（含点按轨道跳档），输入框实时刷新
            this.updateRangeHead(value);
          })
          .accessibilityText('跳过片头秒数滑块，左右拖动调整，0.1 秒一步')
        TextInput({ text: this.headInputText })
          .width(72)
          .height(36)
          .fontSize(13)
          .padding({ left: 4, right: 4 })
          .textAlign(TextAlign.Center)
          .inputFilter('^[0-9]{0,3}(\\.[0-9]?)?$')
          .onChange((text: string): void => {
            this.headInputText = text;
            const v: number = parseRangeSec(text);
            if (v >= 0) {
              this.updateRangeHead(v);
            }
          })
          .onBlur((): void => {
            // 键入中途的非法文本（空串 / 超范围残留）失焦还原为滑条当前值
            this.headInputText = formatRangeSec(this.rangeHeadSec);
          })
        Text('s')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .margin({ left: 4 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 8 })
      // 片尾组标签
      Text('跳过片尾')
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: 2 })
      // 片尾组：同片头一组（对称）
      Row() {
        Slider({
          value: this.rangeTailSec,
          min: 0,
          max: Math.max(0.1, this.rangeTailMax()),
          step: 0.1
        })
          .layoutWeight(1)
          .selectedColor($r('app.color.slider_select'))
          .trackColor($r('app.color.slider_track'))
          .onChange((value: number): void => {
            this.updateRangeTail(value);
          })
          .accessibilityText('跳过片尾秒数滑块，左右拖动调整，0.1 秒一步')
        TextInput({ text: this.tailInputText })
          .width(72)
          .height(36)
          .fontSize(13)
          .padding({ left: 4, right: 4 })
          .textAlign(TextAlign.Center)
          .inputFilter('^[0-9]{0,3}(\\.[0-9]?)?$')
          .onChange((text: string): void => {
            this.tailInputText = text;
            const v: number = parseRangeSec(text);
            if (v >= 0) {
              this.updateRangeTail(v);
            }
          })
          .onBlur((): void => {
            this.tailInputText = formatRangeSec(this.rangeTailSec);
          })
        Text('s')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .margin({ left: 4 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 4 })
      // 生效说明：片尾立即生效（timeUpdate 实时查表），片头从下一次播放生效
      Text('片尾限定立即生效；片头限定从下一次播放生效；到达片尾限定点将自动切歌')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 4 })
    }
    .width('100%')
  }

  /**
   * 单个功能项（按 id 渲染；视觉配方照抄历史版本：bindMenu 必须挂点击落点的
   * 最深层节点，按压反馈用 onTouch 缩放 —— 只回写状态不消费事件，不与菜单/
   * 点击手势竞争）。可见性（开关过滤）由 visibleFuncItems 负责，本 Builder
   * 只管渲染，不再重复开关条件。
   */
  @Builder
  private FuncItem(itemId: string): void {
    if (itemId === PLAYER_FUNC_REPEAT) {
      BounceIconButton({
        icon: modeIconOf(this.repeatMode),
        iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
        buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
        onTap: (): void => {
          this.cycleRepeat();
        }
      })
    } else if (itemId === PLAYER_FUNC_DOWNLOAD) {
      BounceIconButton({
        icon: $r('sys.symbol.arrow_down_to_line'),
        iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
        buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
        onTap: (): void => {
          this.downloadCurrent();
        }
      })
    } else if (itemId === PLAYER_FUNC_ADD_PLAYLIST) {
      // 「加入歌单」：bindMenu 必须挂在点击落点的最深层节点上 ——
      // 曾挂在 BounceIconButton 的外层包装节点，其内部 Column 的 onClick 在
      // 非冒泡手势竞争中作为最深层胜出、吃掉点击，外层 bindMenu 永远不触发。
      // 故此处内联与 TrackItem「⋯」同构的节点（视觉复刻 BounceIconButton：
      // 白色 SymbolGlyph + 0.86 透明度 + 透明命中区），bindMenu 直接挂本节点，
      // 按压反馈改用 onTouch 缩放 —— onTouch 只回写状态不消费事件，
      // 不会与菜单的点击手势竞争（TrackItem 行已真机验证该共存方式）。
      Column() {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(FUNC_ICON_SIZE.getValue(this.currentBreakpoint))
          .fontColor([Color.White])
          .opacity(0.86)
      }
      .width(FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint))
      .height(FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint))
      .justifyContent(FlexAlign.Center)
      .scale({ x: this.menuButtonScale, y: this.menuButtonScale })
      .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) {
          this.menuButtonScale = PRESS_SCALE;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.menuButtonScale = 1;
        }
      })
      .bindMenu(this.playlistMenuItems())
      .accessibilityText('加入歌单')
    } else if (itemId === PLAYER_FUNC_QUEUE) {
      BounceIconButton({
        icon: $r('sys.symbol.list_bullet'),
        iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
        buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
        onTap: (): void => {
          this.showQueueSheet = true;
        }
      })
    } else if (itemId === PLAYER_FUNC_SPEED) {
      // 倍速片：等宽槽位（FUNC_BUTTON_SIZE）内缩字，与图标键同一条中线。
      // bindMenu 必须挂点击落点的最深层节点（挂外层包装会被内部手势竞争
      // 吃掉，见「加入歌单」注释），按压反馈用 onTouch 缩放（只回写状态
      // 不消费事件，不与菜单手势竞争）。
      Column() {
        Text(speedLabelOf(this.playbackSpeed))
          .fontSize(SPEED_FONT_SIZE.getValue(this.currentBreakpoint))
          .minFontSize(SPEED_MIN_FONT_SIZE.getValue(this.currentBreakpoint))
          .maxFontSize(SPEED_FONT_SIZE.getValue(this.currentBreakpoint))
          .width('100%')
          .maxLines(1)
          .textAlign(TextAlign.Center)
          .fontColor(Color.White)
          .opacity(0.86)
          .fontWeight(FontWeight.Medium)
      }
      .width(FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint))
      .height(FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint))
      .justifyContent(FlexAlign.Center)
      .scale({ x: this.speedButtonScale, y: this.speedButtonScale })
      .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) {
          this.speedButtonScale = PRESS_SCALE;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.speedButtonScale = 1;
        }
      })
      .bindMenu(this.speedMenuItems())
      .accessibilityText('播放倍速')
    } else if (itemId === PLAYER_FUNC_SKIP) {
      // 「限定播放进度」入口（按曲设置，IntroSkipStore 持久化）：点击开区间条弹窗。
      // 系统图标 arrow_left_arrow_right（⟷ 双向箭头，示意区间两端），SymbolGlyph
      // 渲染线宽与同排功能键天然一致（BounceIconButton 标准键，含点击弹跳反馈）。
      BounceIconButton({
        icon: $r('sys.symbol.arrow_left_arrow_right'),
        iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
        buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
        onTap: (): void => {
          this.openRangeDialog();
        }
      })
        .accessibilityText('限定播放进度设置')
    } else if (itemId === PLAYER_FUNC_SLEEP) {
      // 定时停止快捷入口：未开启定时显时钟图标、已开启显倒计时
      // （每秒走字，重渲染圈死在 SleepTimerChip 子树）。
      SleepTimerChip()
    } else if (itemId === PLAYER_FUNC_BILI) {
      // 在 B 站打开原视频：优先 bilibili:// 深链拉官方 App，未装/不支持降级 https 网页。
      BounceIconButton({
        icon: $r('sys.symbol.arrow_up_right'),
        iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
        buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
        onTap: (): void => {
          this.openInBilibili();
        }
      })
        .accessibilityText('在 B 站打开原视频')
    } else if (itemId === PLAYER_FUNC_UP_SPACE) {
      // 进入 UP 主页：收起播放页 overlay 并跳转当前曲 UP 的站内主页
      // （UpSpacePage）；mid 缺失时经 getVideoDetail 解析（openUpSpace 注释）。
      BounceIconButton({
        icon: $r('sys.symbol.person'),
        iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
        buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
        onTap: (): void => {
          this.openUpSpace();
        }
      })
        .accessibilityText('进入 UP 主页')
    }
  }

  build() {
    Column() {
      // 紧凑模式（阔折叠外屏）：功能行整体不挂载 —— bindSheet 的队列弹层宿主
      // 在功能行 Swiper 上，一并不挂载（外屏按用户决策只保留「信息 + 三键」）。
      if (!this.compactMode) {
        Row() {
          // 左侧「上一页」箭头：仅多页（>1 页）时渲染；首页淡出、其余页淡入。
          // 多页期间节点常驻占位（显隐走 opacity），避免出现/消失时 Swiper
          // 宽度跳变；单页时不渲染，Swiper 占满整行。
          if (this.funcPageCount() > 1) {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(16)
              .fontColor([Color.White])
              .opacity(this.funcPageIndex > 0 ? 0.4 : 0)
              .animation({ duration: 120, curve: Curve.EaseOut })
              .margin({ right: 2 })
          }

          // 功能行主体：Swiper 分页 —— 全部功能项按用户排序过滤后每页
          // FUNC_ITEMS_PER_PAGE(4) 个等宽槽位，左滑/右滑翻页；组合变化
          // （顺序 / 开关 / 当前曲）经 @Watch 回第 0 页（默认页）。
          // 外层 ForEach 键 = 页内容串联（每项全局唯一 → 内容变即键变，
          // 页面整体重建；若用固定键，ForEach 复用旧页组件不会重跑
          // itemGenerator，页内图标会滞留旧组合）。Swiper 受控：
          // .index(this.funcPageIndex) 与 onChange 回写状态闭环，
          // @Watch 归零时受控跳回第 0 页。
          Swiper() {
            ForEach(
              this.funcPages(),
              (pageIds: string[]): void => {
                Row() {
                  ForEach(
                    pageIds,
                    (itemId: string): void => {
                      Column() {
                        this.FuncItem(itemId)
                      }
                      .layoutWeight(1)
                      .height('100%')
                      .justifyContent(FlexAlign.Center)
                      .alignItems(HorizontalAlign.Center)
                    },
                    (itemId: string): string => itemId
                  )
                }
                .width('100%')
                .height('100%')
                .alignItems(VerticalAlign.Center)
              },
              (pageIds: string[]): string => pageIds.join('_')
            )
          }
          .index(this.funcPageIndex)
          .loop(false)
          .indicator(false)
          .duration(300)
          .layoutWeight(1)
          .height(FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint))
          .onChange((index: number): void => {
            this.funcPageIndex = index;
          })
          .bindSheet($$this.showQueueSheet, this.QueueSheetHost(), {
            height: SheetSize.MEDIUM,
            dragBar: true,
            showClose: false
          })

          // 右侧「下一页」箭头：仅多页时渲染；末页淡出、其余页淡入（同左侧）。
          if (this.funcPageCount() > 1) {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(16)
              .fontColor([Color.White])
              .opacity(this.funcPageIndex < this.funcPageCount() - 1 ? 0.4 : 0)
              .animation({ duration: 120, curve: Curve.EaseOut })
              .margin({ left: 2 })
          }
        }
        .width(StyleConstants.FULL_WIDTH)
        .alignItems(VerticalAlign.Center)
      }

      // 进度区（四分支进度条 + 双侧时间行，独立子组件）：
      // STORE_PROGRESS 每 500ms 推送一次，订阅与 520ms 插值全部圈在
      // PlayerProgressArea 内 —— 本组件播放期间零重渲染。
      // 紧凑模式（阔折叠外屏）整体不挂载：订阅与插值随组件卸载注销。
      if (!this.compactMode) {
        PlayerProgressArea()
      }

      // 三键行（紧凑模式可变布局）：常规 = 全宽两端分布 + control_padding；
      // 紧凑（阔折叠外屏）= 固定间距聚拢 + 左对齐（padding 清零对齐信息块左缘）。
      Row({ space: this.compactMode ? COMPACT_CTRL_GAP : 0 }) {
        BounceIconButton({
          icon: $r('sys.symbol.backward_end_fill'),
          iconSize: PREVNEXT_ICON_SIZE.getValue(this.currentBreakpoint),
          buttonSize: PREVNEXT_BUTTON_SIZE.getValue(this.currentBreakpoint),
          onTap: (): void => {
            this.player.prev();
          }
        })

        PlayButtonComponent()

        BounceIconButton({
          icon: $r('sys.symbol.forward_end_fill'),
          iconSize: PREVNEXT_ICON_SIZE.getValue(this.currentBreakpoint),
          buttonSize: PREVNEXT_BUTTON_SIZE.getValue(this.currentBreakpoint),
          onTap: (): void => {
            this.player.next();
          }
        })
      }
      .width(StyleConstants.FULL_WIDTH)
      .id('player_ctrl_row')
      .justifyContent(this.compactMode
        ? (this.centerMode ? FlexAlign.Center : FlexAlign.Start)
        : FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)
      .padding({
        left: this.compactMode ? 0 : $r('app.float.control_padding'),
        right: this.compactMode ? 0 : $r('app.float.control_padding')
      })
    }
    // 分层入场只挂 transform 系属性，不动 width/height/padding（改布局属性会触发整树重排）
    // 收起为柔退退场（onContentExit 的 200ms EaseIn 淡出 + 回沉）
    .opacity(this.enterOpacity)
    .translate({ y: this.enterOffsetY })
  }

  /** 队列弹层宿主：bindSheet 只收 CustomBuilder，包一层共享 QueueSheet */
  @Builder
  QueueSheetHost(): void {
    QueueSheet({ showSheet: this.showQueueSheet })
  }
}
