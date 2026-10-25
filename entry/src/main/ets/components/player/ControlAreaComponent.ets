/**
 * 播放控制区。
 *
 * 版式自上而下：功能行（播放模式 / 播放列表）→ 进度条 + 双侧时间 → 三键控制行。
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
  VideoPageInfo
} from '../../model/MusicModels';
import { getVideoDetail } from '../../api/BilibiliApi';
import common from '@ohos.app.ability.common';
import { MusicPlayer } from '../../player/MusicPlayer';
import { QueueSheet, repeatLabelOf, modeIconOf, nextRepeatMode } from '../QueueSheet';
import { StyleConstants } from '../../common/constants/StyleConstants';
import { showAppToast } from '../AppToast';
import { showAppAlertDialog } from '../AppAlertDialog';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { BreakpointType } from '../../common/utils/BreakpointSystem';
import { PlayButtonComponent } from './PlayButtonComponent';
import { BounceIconButton } from './BounceIconButton';
import { PlayerProgressArea } from './PlayerProgressArea';
import { LibraryStore } from '../../service/LibraryStore';
import { Playlist } from '../../model/MusicModels';
import {
  DownloadManager,
  DownloadStartResult,
  WIFI_ONLY_BLOCKED
} from '../../service/DownloadManager';
import {
  STORE_CURRENT_TRACK,
  STORE_REPEAT_MODE,
  STORE_PLAYBACK_SPEED_ENABLED,
  STORE_PLAYBACK_SPEED,
  STORE_OPEN_IN_BILI_ENABLED,
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
/** 右组三个功能键之间的间距（视觉间距；各按钮自身命中区已由 BounceIconButton 保证） */
const FUNC_GAP: number = 8;
/** 紧凑模式三键行间距：三键聚拢左对齐时的呼吸间距（常规两端分布时不用，space=0） */
const COMPACT_CTRL_GAP: number = 36;
/** 倍速片字号：视觉体量对齐功能键图标（FUNC_ICON_SIZE 22/26），文字略小一档防喧宾夺主 */
const SPEED_FONT_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 18, md: 18, lg: 20 });
/** 倍速片行高 = 功能键图标字号（SymbolGlyph 的 em 盒高）：图标列与文字列同高同起点，垂直自然对齐 */
const SPEED_LINE_HEIGHT: BreakpointType<string> = new BreakpointType<string>({ sm: '22vp', md: '22vp', lg: '26vp' });
/** 倍速片宽度：比图标按钮宽一档容纳 "0.75x" 等长标签；高度仍取 FUNC_BUTTON_SIZE 保持行内对齐 */
const SPEED_CHIP_WIDTH: BreakpointType<number> = new BreakpointType<number>({ sm: 56, md: 56, lg: 62 });
/**
 * 「加入歌单」弹层最多列几个歌单。
 * 超出的不静默截断，而是多给一条「还有 N 个…去歌单页选」——
 * 静默截断会让人以为「我的歌单」不存在。
 */
const PLAYLIST_PICKER_MAX: number = 5;
/** 歌单页签下标（与 Index 的 TAB_PLAYLISTS 同值；模块私有常量跨文件不可引用） */
const TAB_INDEX_PLAYLISTS: number = 1;

@Component
export struct ControlAreaComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /**
   * 紧凑模式（阔折叠外屏，Pura X 折起 632×924vp → md 断点）：
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
  /** 倍速总开关（设置页镜像）：关 = 功能行不渲染倍速片 */
  @StorageProp(STORE_PLAYBACK_SPEED_ENABLED) speedEnabled: boolean = false;
  /** 「在 B 站打开原视频」开关（设置页镜像）：关 = 功能行不渲染跳转入口 */
  @StorageProp(STORE_OPEN_IN_BILI_ENABLED) openInBiliEnabled: boolean = true;
  /** 当前倍速（MusicPlayer.setStore 写回 → 倍速片标签与菜单 ✓ 实时刷新） */
  @StorageProp(STORE_PLAYBACK_SPEED) playbackSpeed: number = 1.0;
  /** 倍速片按压反馈缩放（onTouch 驱动，不消费事件，与 bindMenu 共存） */
  @State speedButtonScale: number = 1;

  private player: MusicPlayer = MusicPlayer.getInstance();

  aboutToAppear(): void {
    this.exitRequested = false;
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
   * 三条路径要分清：
   *   · 已在下载队列 / 已完成 → 直接告诉用户「不用重复下」；
   *   · 被「仅 WiFi 下载」拦下 → 问一次（与列表页同一套措辞与行为）；
   *   · 正常 → 排队并报数（分 P 合集会排多首，所以要报「N 首」而不是「已添加」）。
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
      const r: DownloadStartResult = await DownloadManager.getInstance().requestDownload(track, false);
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
    if (track === null) {
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

  /** 「仅 WiFi 下载」拦下时的询问（与 SearchPage / UpSpacePage 同一套流程） */
  private confirmCellularDownload(track: Track): void {
    showAppAlertDialog(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: WIFI_ONLY_BLOCKED,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '继续下载',
        action: (): void => {
          DownloadManager.getInstance().requestDownload(track, true)
            .then((r: DownloadStartResult): void => {
              this.toast(r.queued > 0 ? `已加入下载队列 ${r.queued} 首` : '没有可下载的音频');
            })
            .catch((e: Error): void => {
              console.error(`downloadCurrent(ignoreWifiLimit) failed: ${e.message}`);
              this.toast('下载启动失败，请稍后再试');
            });
        }
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

  build() {
    Column() {
      // 紧凑模式（阔折叠外屏）：功能行整体不挂载 —— bindSheet 的队列弹层宿主
      // 在功能行右组上，一并不挂载（外屏按用户决策只保留「信息 + 三键」）。
      if (!this.compactMode) {
        Row() {
          // 左组：播放模式 + 倍速（开关开启时）。包一层 Row 保持 SpaceBetween
          // 两端布局 —— 左组 2 键、右组 3 键，中间空隙自然居中。
          Row({ space: FUNC_GAP }) {
            BounceIconButton({
              icon: modeIconOf(this.repeatMode),
              iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
              buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
              onTap: (): void => {
                this.cycleRepeat();
              }
            })

            // 倍速片：复用「加入歌单」的内联节点配方 —— bindMenu 必须挂点击落点的
            // 最深层节点（挂外层包装会被内部手势竞争吃掉，见右组加入歌单的注释），
            // 按压反馈用 onTouch 缩放（只回写状态不消费事件，不与菜单手势竞争）。
            if (this.speedEnabled) {
              Column() {
                Text(speedLabelOf(this.playbackSpeed))
                  .fontSize(SPEED_FONT_SIZE.getValue(this.currentBreakpoint))
                  .lineHeight(SPEED_LINE_HEIGHT.getValue(this.currentBreakpoint))
                  .fontColor(Color.White)
                  .opacity(0.86)
                  .fontWeight(FontWeight.Medium)
              }
              .width(SPEED_CHIP_WIDTH.getValue(this.currentBreakpoint))
              .height(FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint))
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
            }
          }

          // 右组：下载 / 在 B 站打开（开关控制）/ 加入歌单 / 队列。
          // 刻意包一层 Row 而不是往 SpaceBetween 里塞多个 —— 散开会把中间的
          // 空隙拉得很宽，看起来像两组而不是一组功能键。
          Row({ space: FUNC_GAP }) {
            BounceIconButton({
              icon: $r('sys.symbol.arrow_down_to_line'),
              iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
              buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
              onTap: (): void => {
                this.downloadCurrent();
              }
            })

            // 在 B 站打开原视频（设置 → 播放开关控制显隐，默认开）：
            // 优先 bilibili:// 深链拉官方 App，未装/不支持降级 https 网页。
            if (this.openInBiliEnabled) {
              BounceIconButton({
                icon: $r('sys.symbol.arrow_up_right'),
                iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
                buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
                onTap: (): void => {
                  this.openInBilibili();
                }
              })
                .accessibilityText('在 B 站打开原视频')
            }

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

            BounceIconButton({
              icon: $r('sys.symbol.list_bullet'),
              iconSize: FUNC_ICON_SIZE.getValue(this.currentBreakpoint),
              buttonSize: FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint),
              onTap: (): void => {
                this.showQueueSheet = true;
              }
            })
          }
          .bindSheet($$this.showQueueSheet, this.QueueSheetHost(), {
            height: SheetSize.MEDIUM,
            dragBar: true,
            showClose: false
          })
        }
        .width(StyleConstants.FULL_WIDTH)
        .justifyContent(FlexAlign.SpaceBetween)
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
