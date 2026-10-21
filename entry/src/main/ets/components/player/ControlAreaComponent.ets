/**
 * 播放控制区（参考 audio-interaction-master 的 ControlAreaComponent 版式重做）。
 *
 * 版式自上而下：功能行（播放模式 / 播放列表）→ 进度条 + 双侧时间 → 三键控制行。
 * 控制调用全部走 MusicPlayer 单例；队列弹层复用共享组件 QueueSheet；
 * 按用户决策不引入收藏 / 静音按钮。
 *
 * 动效拆分（每条动画独立变量、互不共用，无全局统一 animation）：
 *   · 播放/暂停主按钮 → 独立子组件 PlayButtonComponent（呼吸形变 + 点击回弹自理）；
 *   · 模式 / 列表 / 上一曲 / 下一曲 → BounceIconButton（仅点击单次回弹，无持续动画）；
 *   · 进度条 → 播放时对 500ms 一次的进度写入做 520ms 线性插值（平滑推进，
 *     大跳即 seek/切歌直接落位不扫动）；拖拽时轻微放大，松手关键帧回弹。
 *
 * 进度条交互仍为「拖动本地跟随、松手才 seek」：拖动期间 STORE_PROGRESS 照常
 * 更新，由 dragging + dragValue 隔离，插值动画在拖动中暂停。
 */

import {
  Track,
  RepeatMode,
  PLAYBACK_SPEED_OPTIONS,
  speedLabelOf,
  PROGRESS_STYLE_SHIMMER,
  PROGRESS_STYLE_PULSE,
  PROGRESS_STYLE_WAVE
} from '../../model/MusicModels';
import { MusicPlayer } from '../../player/MusicPlayer';
import { QueueSheet, repeatLabelOf, modeIconOf, nextRepeatMode } from '../QueueSheet';
import { StyleConstants } from '../../common/constants/StyleConstants';
import { showAppToast } from '../AppToast';
import { showAppAlertDialog } from '../AppAlertDialog';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { PlayerConstants } from '../../common/constants/PlayerConstants';
import { BreakpointType } from '../../common/utils/BreakpointSystem';
import { PlayButtonComponent } from './PlayButtonComponent';
import { BounceIconButton } from './BounceIconButton';
import { ShimmerProgressBar } from './ShimmerProgressBar';
import { PulseDotProgressBar } from './PulseDotProgressBar';
import { WaveBarsProgressBar } from './WaveBarsProgressBar';
import { LibraryStore } from '../../service/LibraryStore';
import { Playlist } from '../../model/MusicModels';
import {
  DownloadManager,
  DownloadStartResult,
  WIFI_ONLY_BLOCKED
} from '../../service/DownloadManager';
import {
  STORE_CURRENT_TRACK,
  STORE_PROGRESS,
  STORE_DURATION,
  STORE_REPEAT_MODE,
  STORE_PLAYBACK_SPEED_ENABLED,
  STORE_PLAYBACK_SPEED,
  STORE_PROGRESS_STYLE,
  STORE_PLAYER_OPEN
} from '../../common/Constants';
import {
  ENTRANCE_DURATION_MS,
  ENTRANCE_OFFSET_VP,
  LAYER_DELAY_CONTROL,
  PRESS_ANIM_MS,
  PRESS_SCALE
} from '../../common/constants/InteractionConstants';

function formatTime(totalSeconds: number): string {
  const s: number = Math.max(0, Math.floor(totalSeconds));
  const m: number = Math.floor(s / 60);
  const r: number = s % 60;
  return `${m}:${r < 10 ? '0' : ''}${r}`;
}

/** 切歌键（上一曲 / 下一曲）图标与圆底尺寸 */
const PREVNEXT_ICON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 26, md: 26, lg: 30 });
const PREVNEXT_BUTTON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 52, md: 52, lg: 60 });
/** 功能键（播放模式 / 下载 / 加入歌单 / 播放列表）图标与圆底尺寸 */
const FUNC_ICON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 22, md: 22, lg: 26 });
const FUNC_BUTTON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 40, md: 40, lg: 46 });
/** 右组三个功能键之间的间距（视觉间距；各按钮自身命中区已由 BounceIconButton 保证） */
const FUNC_GAP: number = 8;
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
/** 进度插值时长（ms）：STORE_PROGRESS 按 500ms 分桶推送，插值略长避免步进感 */
const PROGRESS_TWEEN_MS: number = 520;
/** 判定「大跳」的阈值（秒）：超过视为 seek / 切歌，直接落位不做扫动 */
const PROGRESS_JUMP_SEC: number = 2;

@Component
export struct ControlAreaComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageLink(STORE_PROGRESS) @Watch('onProgressTick') progress: number = 0;
  @StorageLink(STORE_DURATION) duration: number = 0;
  @StorageLink(STORE_REPEAT_MODE) repeatMode: RepeatMode = RepeatMode.NONE;
  @StorageLink(STORE_CURRENT_TRACK) currentTrack: Track | null = null;
  /** 队列弹层开关（本组件自持，bindSheet 挂在播放列表按钮上） */
  @State showQueueSheet: boolean = false;
  /** 拖动隔离：拖动中滑块显示 dragValue，松手恢复跟随插值进度 */
  @State dragging: boolean = false;
  @State dragValue: number = 0;
  /** 进度条平滑显示值（本动画独占）：播放中由 onProgressTick 插值驱动 */
  @State sliderValue: number = 0;
  /** 进度条拖拽反馈缩放（本动画独占） */
  @State trackScale: number = 1;
  /** 「下载」请求在途：连点会重复提交同一首（提交后立刻变「已在队列」，体验是「点了没反应」） */
  @State downloading: boolean = false;
  /**
   * 歌单菜单新鲜度版本号（2026-10-11）：bindMenu 的 MenuElement 数组在渲染时求值，
   * 新建歌单后自增它触发重渲染，下次打开菜单就能看到新歌单。
   */
  @State playlistMenuVersion: number = 0;
  /** 「加入歌单」按钮按压反馈缩放（onTouch 驱动，不消费事件，与 bindMenu 共存） */
  @State menuButtonScale: number = 1;
  /** 倍速总开关（设置页镜像）：关 = 功能行不渲染倍速片 */
  @StorageProp(STORE_PLAYBACK_SPEED_ENABLED) speedEnabled: boolean = false;
  /** 当前倍速（MusicPlayer.setStore 写回 → 倍速片标签与菜单 ✓ 实时刷新） */
  @StorageProp(STORE_PLAYBACK_SPEED) playbackSpeed: number = 1.0;
  /** 倍速片按压反馈缩放（onTouch 驱动，不消费事件，与 bindMenu 共存） */
  @State speedButtonScale: number = 1;
  /**
   * 播放页进度条样式（设置页镜像）：SHIMMER（流光）/ PULSE（波点）/ WAVE（频谱）
   * 走自绘分支，其余取值（含未知值）回落经典 Slider —— 交互契约四档一致。
   */
  @StorageProp(STORE_PROGRESS_STYLE) progressStyle: string = '';

  private player: MusicPlayer = MusicPlayer.getInstance();

  aboutToAppear(): void {
    this.sliderValue = this.progress;
    // 分层入场（方案 B）：控制区最后落位（LAYER_DELAY_CONTROL）。
    // 延迟交给 animateTo 的 delay —— 不用 setTimeout，少一个要清理的定时器。
    this.getUIContext().animateTo(
      { duration: ENTRANCE_DURATION_MS, curve: Curve.EaseOut, delay: LAYER_DELAY_CONTROL },
      (): void => {
        this.enterOpacity = 1;
        this.enterOffsetY = 0;
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
   * 播放页展开态：收起（→ false，落在 Index.closePlayer 的 animateTo 闭包内）时
   * 把控制区入场状态复位为隐藏 —— 随收起动画一起插值淡出下沉（逆向镜像）。
   */
  @StorageProp(STORE_PLAYER_OPEN) @Watch('onPlayerOpenChanged') playerOpen: boolean = false;

  /** 收起复位：入场状态回隐藏态（落在收起 animateTo 内即动画淡出） */
  private onPlayerOpenChanged(): void {
    if (this.playerOpen) {
      return;
    }
    this.enterOpacity = 0;
    this.enterOffsetY = ENTRANCE_OFFSET_VP;
  }

  /**
   * 进度写入（500ms 一次）→ 520ms 线性插值：animateTo 反复重定目标，
   * 滑块匀速连续推进而非半秒一跳；拖动中不插值（滑块跟手指）；
   * 大跳（seek / 切歌）duration 0 直接落位。
   */
  private onProgressTick(): void {
    if (this.dragging) {
      return;
    }
    const target: number = this.progress;
    const jump: number = Math.abs(target - this.sliderValue);
    const duration: number = jump > PROGRESS_JUMP_SEC ? 0 : PROGRESS_TWEEN_MS;
    this.getUIContext().animateTo({ duration: duration, curve: Curve.Linear }, (): void => {
      this.sliderValue = target;
    });
  }

  /** 拖拽开始：进度条轻微放大（独立 animateTo，不与插值共用通道） */
  private scaleUpTrack(): void {
    this.getUIContext().animateTo({ duration: 160, curve: Curve.EaseOut }, (): void => {
      this.trackScale = 1.04;
    });
  }

  /** 松手：先落位显示值，再关键帧回弹（轻微下探 → 回 1） */
  private bounceBackTrack(value: number): void {
    this.getUIContext().animateTo({ duration: 0 }, (): void => {
      this.sliderValue = value;
    });
    this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
      {
        duration: 0,
        event: (): void => {
          this.trackScale = 1.04;
        }
      },
      {
        duration: 150,
        curve: Curve.EaseOut,
        event: (): void => {
          this.trackScale = 0.99;
        }
      },
      {
        duration: 130,
        curve: Curve.EaseOut,
        event: (): void => {
          this.trackScale = 1;
        }
      }
    ]);
  }

  /**
   * 生效总时长：AVPlayer 的 durationUpdate 在部分流上拿不到值，
   * 回退曲目自带时长，否则 max=0 时拖动手势按 0 换算、seek 永远是 0 秒。
   */
  private effectiveDuration(): number {
    if (this.duration > 0) {
      return this.duration;
    }
    return this.currentTrack !== null ? this.currentTrack.duration : 0;
  }

  // ===== 自绘进度条（流光 / 波点 / 频谱）的拖拽回调 =====
  // 交互契约与经典 Slider 完全一致：按下/拖动只写本地隔离值，松手才 seek；
  // 插值推进、时间标签、拖动隔离共用同一套 dragging / dragValue / sliderValue。

  /** 自绘条按下：进入拖拽隔离（视觉反馈由子组件自理，父只置位） */
  private onBarDragStart(): void {
    this.dragging = true;
  }

  /** 自绘条拖动：本地跟随，不写播放进度 */
  private onBarDragMove(sec: number): void {
    this.dragValue = sec;
  }

  /** 自绘条松手 / 点按定位：交给播放内核；显示值直接落位（trackScale 无视觉、等效空跑） */
  private onBarDragEnd(sec: number): void {
    this.dragging = false;
    if (this.effectiveDuration() > 0) {
      this.player.seek(sec);
    }
    this.bounceBackTrack(sec);
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
   * 「加入歌单」按钮的标准菜单项（阶段 2 迁移：自绘菜单弹窗 → bindMenu + MenuElement 数组）。
   *
   * 新鲜度：数组在**渲染时**求值，新建歌单后由 createPlaylistAndAdd 里的
   * playlistMenuVersion 自增触发重渲染（@StorageLink currentTrack 等状态变化也会顺带刷新）。
   *
   * 行为微调（bindMenu 无法条件性不弹出）：没有任何歌单时原先是「直接新建 + toast」，
   * 现在弹出只有一条「新建歌单并加入」的菜单，多一次点击但行为可预期。
   * 歌单很多时只列前 5 个 + 一条「去歌单页选」入口 + 「新建歌单并加入」。
   */
  private playlistMenuItems(): MenuElement[] {
    const track: Track | null = this.currentTrack;
    if (track === null) {
      return [{ value: '还没有正在播放的曲目', enabled: false, action: (): void => {} }];
    }
    const options: Playlist[] = LibraryStore.getPlaylists();
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
          this.toast(updated ? `已加入「${target.name}」` : '加入歌单失败');
        }
      });
    }
    if (options.length > shown.length) {
      // 歌单多到弹层放不下：给一个明确的去处，而不是静默截断
      items.push({
        value: `还有 ${options.length - shown.length} 个…去歌单页选`,
        action: (): void => {
          this.createPlaylistAndAdd(track, options);
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

        // 右组三个：下载 / 加入歌单 / 队列。
        // 刻意包一层 Row 而不是往 SpaceBetween 里塞四个 —— 四个散开会把中间的
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

          // 「加入歌单」：bindMenu 必须挂在点击落点的最深层节点上 ——
          // 曾挂在 BounceIconButton 的外层包装节点，其内部 Column 的 onClick 在
          // 非冒泡手势竞争中作为最深层胜出、吃掉点击，外层 bindMenu 永远不触发。
          // 故此处内联与 TrackItem「⋯」同构的节点（视觉复刻 BounceIconButton：
          // 白色 SymbolGlyph + 0.86 透明度 + 透明命中区），bindMenu 直接挂本节点，
          // 按压反馈改用 onTouch 缩放 —— onTouch 只回写状态不消费事件，
          // 不会与菜单的点击手势竞争（TrackItem 行已真机验证该共存方式）。
          Column() {
            SymbolGlyph($r('sys.symbol.bookshelf_badge_plus'))
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

      Column() {
        // 进度条四分支（设置 → 外观「播放页进度条样式」）：三种自绘样式共用
        // value/max/拖拽回调契约，经典 Slider 保持原样（含未知值兜底）。
        if (this.progressStyle === PROGRESS_STYLE_SHIMMER) {
          ShimmerProgressBar({
            value: this.dragging ? this.dragValue : this.sliderValue,
            max: this.effectiveDuration(),
            onSeekStart: (): void => {
              this.onBarDragStart();
            },
            onSeekMove: (sec: number): void => {
              this.onBarDragMove(sec);
            },
            onSeekEnd: (sec: number): void => {
              this.onBarDragEnd(sec);
            }
          })
            .margin({
              left: new BreakpointType<Resource>({
                sm: $r('app.float.slider_margin_sm'),
                md: $r('app.float.slider_margin_md'),
                lg: $r('app.float.slider_margin_lg')
              }).getValue(this.currentBreakpoint),
              right: new BreakpointType<Resource>({
                sm: $r('app.float.slider_margin_sm'),
                md: $r('app.float.slider_margin_md'),
                lg: $r('app.float.slider_margin_lg')
              }).getValue(this.currentBreakpoint)
            })
        } else if (this.progressStyle === PROGRESS_STYLE_PULSE) {
          PulseDotProgressBar({
            value: this.dragging ? this.dragValue : this.sliderValue,
            max: this.effectiveDuration(),
            onSeekStart: (): void => {
              this.onBarDragStart();
            },
            onSeekMove: (sec: number): void => {
              this.onBarDragMove(sec);
            },
            onSeekEnd: (sec: number): void => {
              this.onBarDragEnd(sec);
            }
          })
            .margin({
              left: new BreakpointType<Resource>({
                sm: $r('app.float.slider_margin_sm'),
                md: $r('app.float.slider_margin_md'),
                lg: $r('app.float.slider_margin_lg')
              }).getValue(this.currentBreakpoint),
              right: new BreakpointType<Resource>({
                sm: $r('app.float.slider_margin_sm'),
                md: $r('app.float.slider_margin_md'),
                lg: $r('app.float.slider_margin_lg')
              }).getValue(this.currentBreakpoint)
            })
        } else if (this.progressStyle === PROGRESS_STYLE_WAVE) {
          WaveBarsProgressBar({
            value: this.dragging ? this.dragValue : this.sliderValue,
            max: this.effectiveDuration(),
            onSeekStart: (): void => {
              this.onBarDragStart();
            },
            onSeekMove: (sec: number): void => {
              this.onBarDragMove(sec);
            },
            onSeekEnd: (sec: number): void => {
              this.onBarDragEnd(sec);
            }
          })
            .margin({
              left: new BreakpointType<Resource>({
                sm: $r('app.float.slider_margin_sm'),
                md: $r('app.float.slider_margin_md'),
                lg: $r('app.float.slider_margin_lg')
              }).getValue(this.currentBreakpoint),
              right: new BreakpointType<Resource>({
                sm: $r('app.float.slider_margin_sm'),
                md: $r('app.float.slider_margin_md'),
                lg: $r('app.float.slider_margin_lg')
              }).getValue(this.currentBreakpoint)
            })
        } else {
          Slider({
            min: 0,
            max: Math.max(1, this.effectiveDuration()),
            step: 1,
            style: SliderStyle.OutSet,
            value: this.dragging ? this.dragValue : this.sliderValue
          })
            .selectedColor($r('app.color.slider_select'))
            .trackColor($r('app.color.slider_track'))
            .scale({ x: this.trackScale, y: this.trackScale })
            .onChange((value: number, mode: SliderChangeMode): void => {
              if (mode === SliderChangeMode.Begin) {
                // 按下：只动本地滑块并轻微放大，不写播放进度
                this.dragging = true;
                this.dragValue = value;
                this.scaleUpTrack();
                return;
              }
              if (mode === SliderChangeMode.Moving) {
                this.dragValue = value;
                return;
              }
              // 松手 / 点击定位：交给播放内核，进度条回弹
              this.dragging = false;
              if (this.effectiveDuration() > 0) {
                this.player.seek(value);
              }
              this.bounceBackTrack(value);
            })
            .height($r('app.float.slider_height'))
            .margin({
              left: new BreakpointType<Resource>({
                sm: $r('app.float.slider_margin_sm'),
                md: $r('app.float.slider_margin_md'),
                lg: $r('app.float.slider_margin_lg')
              }).getValue(this.currentBreakpoint),
              right: new BreakpointType<Resource>({
                sm: $r('app.float.slider_margin_sm'),
                md: $r('app.float.slider_margin_md'),
                lg: $r('app.float.slider_margin_lg')
              }).getValue(this.currentBreakpoint)
            })
        }
        Row() {
          Text(formatTime(this.dragging ? this.dragValue : this.sliderValue))
            .fontColor($r('app.color.play_text_color'))
            .fontSize($r('app.float.singer_title_sm'))
            .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
            .lineHeight('14vp')
          Text(formatTime(this.effectiveDuration()))
            .fontColor($r('app.color.play_text_color'))
            .fontSize($r('app.float.singer_title_sm'))
            .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
            .lineHeight('14vp')
        }
        .width(StyleConstants.FULL_WIDTH)
        .justifyContent(FlexAlign.SpaceBetween)
      }
      .margin({
        top: $r('app.float.slider_margin_top'),
        bottom: this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG ?
        $r('app.float.slider_margin_bottom_lg') : $r('app.float.slider_margin_bottom')
      })

      Row() {
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
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)
      .padding({
        left: $r('app.float.control_padding'),
        right: $r('app.float.control_padding')
      })
    }
    // 分层入场只挂 transform 系属性，不动 width/height/padding（改布局属性会触发整树重排）
    .opacity(this.enterOpacity)
    .translate({ y: this.enterOffsetY })
  }

  /** 队列弹层宿主：bindSheet 只收 CustomBuilder，包一层共享 QueueSheet */
  @Builder
  QueueSheetHost(): void {
    QueueSheet({ showSheet: this.showQueueSheet })
  }
}
