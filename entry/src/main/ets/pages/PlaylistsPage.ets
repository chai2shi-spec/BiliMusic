/**
 * 歌单列表页：展示本地歌单，支持新建 / 重命名 / 删除歌单、长按拖动排序
 * （所有类型歌单可拖：列表顺序是纯本地展示态）、进入详情
 * （订阅歌单除外：行点击进 UP 主页，订阅流以 UP 为核心）。
 * 数据来自 LibraryStore（内部有内存快照 + 异步落盘）。
 *
 * 简约 iOS 风格：顶栏在根 HdsNavigation titleBar（沉浸材质 + 滚动模糊由 HDS
 * 承担，内容见 components/PlaylistsTabBar.ets）——根栏 stackBuilder 承载
 * 标题行 + 多选工具条（行 1 / 行 2 溢出渲染，
 * Index.immersiveTitleBarContent 歌单页分支）；最近播放入口在设置页「播放」组。
 */

import {
  LibraryStore,
  PLAYLIST_MAX_ITEMS
} from '../service/LibraryStore';
import { isFolderTwoway } from '../service/FavTwowayStore';
import { UpSpaceCacheEntry, getUpSpaceCache } from '../service/UpSpaceCacheStore';
import { HomeCardStore, HOME_PLAYLIST_CARDS_MAX } from '../service/HomeCardStore';
import { Playlist, Track, ITEM_DISPLAY_LIST, ITEM_DISPLAY_GRID } from '../model/MusicModels';
import { toThumbUrl } from '../utils/TextUtil';
import { NavStackHolder } from '../service/NavStackHolder';
import { UpSpaceRouteParam, PlaylistDetailRouteParam } from '../service/NavRouteParams';
import {
  CONTENT_END_OFFSET,
  STORE_ACTIVE_TAB,
  STORE_CURRENT_TRACK,
  STORE_ITEM_DISPLAY_STYLE,
  STORE_LIBRARY_REV,
  STORE_PICK_PLAYLIST_ADD,
  STORE_PL_BAR_ALL_SELECTED,
  STORE_PL_BAR_CAN_SELECT,
  STORE_PL_BAR_SELECTED_COUNT,
  STORE_PL_BAR_SELECTING,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY,
  STORE_THEME_ON
} from '../common/Constants';
import { showAppToast } from '../components/AppToast';
import { showAppAlertDialog } from '../components/AppAlertDialog';
import { CoverImage } from '../components/CoverImage';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import {
  PairOf,
  makePairs,
  TWO_COL_GAP_VP,
  GRID_EDGE_PADDING_VP,
  TwoColumnLayout
} from '../common/utils/TwoColumnList';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { TabScrollerHolder } from '../service/TabScrollerHolder';
import {
  DownloadManager,
  DownloadSource,
  DownloadStartResult,
  WIFI_ONLY_BLOCKED
} from '../service/DownloadManager';
import {
  BUTTON_RADIUS_VP,
  PRESS_ANIM_MS,
  PRESS_SCALE,
  SELECT_SLOT_VP,
  SELECT_TOGGLE_MS
} from '../common/constants/InteractionConstants';
import { CustomContentDialog } from '@kit.ArkUI';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';

/**
 * 歌单批量入队的**每首间隔**（ms）。
 *
 * 不是为了「让用户等得久」，而是必须：`requestDownload` 对每首都会发一次 view 请求
 * （`expandVideoParts` 用来识别分 P），密集请求会被 B 站限流 ——
 * 实测同一接口连打 8 次 0/8 成功（见 BILI-API.md「空间类接口的匿名风控」）。
 * 350ms 是「不至于触发限流」与「100 首不至于等到失去耐心」之间的折中。
 */
const PLAYLIST_ENQUEUE_GAP_MS: number = 350;

/** 合并歌单预填名字的最大长度（超出截断加「…」，用户仍可自己改） */
const MAX_MERGE_NAME_CHARS: number = 18;

/** 「去歌单页选」点选提示条占用高度（vp）：顶部占位条目加高，列表内容整体下移避让 */
const PICK_HINT_HEIGHT_VP: number = 60;
/** 歌单页签下标（与 Index 的 TAB_PLAYLISTS 同值；模块私有常量跨文件不可引用） */
const TAB_INDEX_PLAYLISTS: number = 1;
/** 歌单网格卡（大封面模式）按压缩放：比行内 0.9 收敛（大卡面缩 0.9 视觉过猛） */
const PL_CARD_PRESS_SCALE: number = 0.96;

/** ArkTS 没有原生 sleep，用 setTimeout 包一个 Promise */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}

/**
 * 歌单编辑弹窗的用途：新建 / 重命名 / 合并（合并多出汇总与「删除原歌单」开关）。
 *
 * 刻意用「数字常量」而不是 `enum`：在 .ets 里声明 enum 会让静态检查连带报
 * SDK 声明文件的解析错误，用常量最稳。
 *
 * 走 CustomContentDialog 标准对话框（仍走 CustomDialogController，**绝不走
 * promptAction** —— 崩溃史见 AppAlertDialog.ets 头注释）。标题用组件
 * primaryTitle，三种模式各持一个
 * controller（CustomDialog 构造参数不支持动态刷新，faqs-arkui-555，标题与
 * 确认文案又是模式固定的，按模式各建一个最直接）；确认按钮留在 contentBuilder
 * 自绘而不用 buttons 槽：空名校验失败要保持弹窗打开，buttons 槽点击即自动
 * 关闭（faqs-arkui-986），做不到。
 */
const EDITOR_MODE_CREATE: number = 0;
const EDITOR_MODE_RENAME: number = 1;
const EDITOR_MODE_MERGE: number = 2;

@Component
export struct PlaylistsPage {
  @State playlists: Playlist[] = [];
  /** 主题色运行时值：滑动删除按钮与 Checkbox 选中色跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /** 名称编辑弹窗：editingId 为空表示新建，非空表示重命名（弹窗本体见三个 editor*Controller） */
  @State editingId: string = '';
  @State editorName: string = '';
  /** 编辑弹窗用途（新建 / 重命名 / 合并） */
  @State editorMode: number = EDITOR_MODE_CREATE;
  /**
   * 多选模式开关：根栏内「选择/完成」按钮（components/PlaylistsTabBar.ets）
   * 要读它 —— 直接挂 AppStorage 单向镜像给根栏。
   */
  @StorageLink(STORE_PL_BAR_SELECTING) selecting: boolean = false;
  /**
   * 已选中的歌单 id。@Watch 同步顶栏派生镜像（选中数 / 全选态），根栏工具条据此刷新。
   */
  @State @Watch('syncBarState') selectedIds: string[] = [];
  /**
   * 「去歌单页选」点选加入请求（seq 递增，STORE_PICK_PLAYLIST_ADD）：播放页
   * ControlArea 菜单项在收起播放页 + 切页签的同时递增本键，本页 @Watch 消费 ——
   * 快照当前曲目进入点选模式（点选模式必须由本页承接，否则用户跳过来无从下手）。
   */
  @StorageProp(STORE_PICK_PLAYLIST_ADD) @Watch('onPickAddRequest') pickAddRequest: number = 0;
  /** 点选加入模式中：整行点击 = 把快照曲目加入该歌单（单次点选即退出），顶部占位条目内嵌提示条 */
  @State picking: boolean = false;
  /** 点选加入的目标曲目（进入模式时快照，避免点选途中切歌错加） */
  @State pickTrack: Track | null = null;
  /**
   * 当前活动页签（只读镜像）：切离歌单页签即取消点选模式 —— 该模式是「跳过来
   * 选一下」的短命状态，留着不撤只会让人困惑（回到页签见莫名其妙的提示条）。
   */
  @StorageLink(STORE_ACTIVE_TAB) @Watch('onActiveTabChanged') activeTab: number = 0;
  /** 合并预览（弹窗里的汇总与风险提示；合并动作前由 LibraryStore.previewPlaylistMerge 填充） */
  @State mergeSourceCount: number = 0;
  @State mergeRawTotal: number = 0;
  @State mergeTotal: number = 0;
  @State mergeDropped: number = 0;
  @State mergeSubscriptions: number = 0;
  /** 合并后是否删除源歌单（默认开：合并即归一） */
  @State mergeDeleteSources: boolean = true;
  /**
   * 歌单编辑弹窗（CustomContentDialog）：新建 / 重命名 / 合并各一个 controller。
   * aboutToAppear 里创建一次、绝不重新赋值（复用场景重新赋值会关不掉旧弹窗，
   * 见 AppAlertDialog.ets 头注释）。
   */
  private editorCreateController: CustomDialogController | undefined = undefined;
  private editorRenameController: CustomDialogController | undefined = undefined;
  private editorMergeController: CustomDialogController | undefined = undefined;

  /** 按压中的歌单行 id：单指同一时刻只按一行，一个变量即可驱动任意行缩放 */
  @State pressedKey: string = '';
  /**
   * UP 订阅歌单行副行的投稿总数（upMid → card 的 archive_count，读自 UpSpaceCacheStore）。
   * 值 0 / mid 缺失 = 未知（无缓存 / 旧缓存 / 被淘汰），副行回退显示已落库曲目数。
   * 订阅条目副行显示 UP 投稿总数而非「N 首」——订阅只落库第一页投稿（登录态
   * ≤50 条），后者会把几百个投稿的 UP 永远显示成「50 首」。
   */
  @State archiveCounts: Map<string, number> = new Map();
  /** 按压状态回写（与搜索页 TrackItem / 下载页同款）：Down 记录、Up/Cancel 只清自己 */
  private setPressed(type: TouchType, key: string): void {
    if (type === TouchType.Down) {
      this.pressedKey = key;
    } else if ((type === TouchType.Up || type === TouchType.Cancel) && this.pressedKey === key) {
      this.pressedKey = '';
    }
  }
  /**
   * 媒体库变更信号。Tabs 的 TabContent 是常驻的，aboutToAppear 只在首次触发：
   * 搜索页加完歌单切回来、详情页改完返回，都必须靠它重新读数据。
   */
  @StorageLink(STORE_LIBRARY_REV) @Watch('onLibraryChanged') libraryRev: number = 0;
  /** 底部安全区高度（vp）：根容器不再统一避让，列表末尾让位要自己叠上这一份 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /**
   * 状态栏高度（vp）：根 HdsNavigation 标题栏的材质从 y=0 铺起覆盖状态栏
   * （avoidLayoutSafeArea 覆盖式渲染）；本页让位量由 barTotalHeight() 显式叠加。
   */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 横竖屏（Index 常驻注册写入）：横屏宽屏时歌单行两列显示 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;

  /**
   * 横屏宽屏（窗口 ≥600vp 的横屏）时歌单行两列显示。
   * ⚠️ 两列分支**不注册 onMove**：长按拖动排序以 ListItem 为单位，配对后拖动
   * 会以「一对」为单位错乱 —— 拖动排序是竖屏专属（有意取舍，同 PlaylistDetail
   * 可排序歌单的门控口径）；横屏浏览 / 多选 / 点选加入不受影响。
   */
  private isTwoCol(): boolean {
    return TwoColumnLayout.isActive(this.currentBreakpoint, this.isLandscape);
  }

  /** 条目展示（外观设置「条目展示」）：长条（默认）/ 大封面双列网格 */
  @StorageProp(STORE_ITEM_DISPLAY_STYLE) itemDisplay: string = ITEM_DISPLAY_LIST;

  /** 大封面模式：歌单以双列网格卡渲染（PlaylistCard），交互契约与行内版一致 */
  private isGrid(): boolean {
    return this.itemDisplay === ITEM_DISPLAY_GRID;
  }
  /**
   * 列表滚动控制器：List 直接挂 TabScrollerHolder.playlists（唯一真源，身份恒定，
   * 不可 new 私有实例后注册替换），由根 HdsNavigation bindToScrollable 绑定驱动
   * 顶栏滚动模糊。
   */

  aboutToAppear(): void {
    // 根栏内按钮动作注册进持有器（List 直挂 Holder.playlists 唯一真源）
    TabScrollerHolder.plToggleSelecting = (): void => {
      this.toggleSelecting();
    };
    TabScrollerHolder.plOpenCreate = (): void => {
      this.openCreate();
    };
    TabScrollerHolder.plToggleSelectAll = (): void => {
      this.toggleSelectAll();
    };
    TabScrollerHolder.plOpenMergeEditor = (): void => {
      this.openMergeEditor();
    };
    TabScrollerHolder.plDeleteSelected = (): void => {
      this.confirmDeleteSelected();
    };
    // 挂载前先存当前偏移对应的进度（updater 未挂载只存值，挂载时
    // initializeModifier 补上），防「已滚过再进页签」首帧缺模糊。
    this.syncTopBlurProgress();
    // 歌单编辑弹窗：三模式各建一个 CustomContentDialog controller
    this.editorCreateController = this.buildEditorDialog('新建歌单');
    this.editorRenameController = this.buildEditorDialog('重命名歌单');
    this.editorMergeController = this.buildEditorDialog('合并歌单');
    // 首次 refresh 是冷启动同步读（getSync + JSON.parse ×2：歌单 + 最近播放），
    // 延后一拍执行别卡首帧（做法同 SettingsPage 的缓存统计）。跑完缓存即热，
    // onLibraryChanged 的后续 refresh 全走内存快照，无 IO；
    // 首帧歌单列表短暂空态可接受，换的是首屏零磁盘读。
    setTimeout((): void => {
      this.refresh();
    }, 0);
  }

  onLibraryChanged(): void {
    this.refresh();
  }

  /** 进入点选加入模式：快照当前曲目（无曲目不进模式 —— 菜单只在有曲目时出现，正常到不了兜底分支） */
  private onPickAddRequest(): void {
    const t: Track | undefined = AppStorage.get<Track>(STORE_CURRENT_TRACK);
    if (t === undefined || t === null) {
      this.toast('还没有正在播放的曲目', 1500);
      return;
    }
    // 打开播放页前可能停留在多选模式：一并退出，两种「整行点选」语义不能叠加
    this.selecting = false;
    this.selectedIds = [];
    this.pickTrack = t;
    this.picking = true;
  }

  /** 切离歌单页签：取消点选加入模式（见 activeTab 注释） */
  private onActiveTabChanged(): void {
    if (this.activeTab !== TAB_INDEX_PLAYLISTS) {
      this.picking = false;
    }
  }

  /** 点选加入落库：成功 / 失败都退出模式（单次点选语义，与快捷菜单一致） */
  private addPickedTrack(p: Playlist): void {
    const t: Track | null = this.pickTrack;
    this.picking = false;
    this.pickTrack = null;
    if (t === null) {
      return;
    }
    const updated: Playlist | null = LibraryStore.addTrackToPlaylist(p.id, t);
    this.toast(updated ? `已加入「${p.name}」` : '加入歌单失败', 1500);
  }

  /** 提示条曲目名（点选模式的横幅文案用） */
  private pickTrackTitle(): string {
    return this.pickTrack !== null ? this.pickTrack.title : '';
  }

  private refresh(): void {
    this.playlists = LibraryStore.getPlaylists();
    this.syncBarState();
    // UP 订阅歌单的投稿总数异步补齐（读的是 UpSpaceCacheStore 小缓存文件，
    // 主线程零同步 IO）；到达前副行先显示回退值，毫秒级后被真值替换
    this.loadUpArchiveCounts();
  }

  /**
   * 读 UP 订阅歌单的投稿总数（archive_count）：每个订阅 upMid 查一次
   * UpSpaceCacheStore 落盘缓存，全部到齐后**一次性整体赋值**新 Map ——
   * 逐个 set 会触发多次列表重渲染，批量换表只刷一次。
   *
   * 每次刷新都重读：文件小（15~50KB）且 UP 订阅数有限，换来的是
   * 「拉取新投稿返回」后副行数字自动跟上缓存里的新值。
   * 无缓存 / 损坏 / 被淘汰（上限 12 个 UP）记 0 = 未知，副行回退 tracks.length。
   */
  private loadUpArchiveCounts(): void {
    const mids: string[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < this.playlists.length; i++) {
      const p: Playlist = this.playlists[i];
      if (!LibraryStore.isUpSubscription(p) || seen.has(p.upMid)) {
        continue;
      }
      seen.add(p.upMid);
      mids.push(p.upMid);
    }
    if (mids.length === 0) {
      return;
    }
    const loads: Promise<UpSpaceCacheEntry | null>[] = [];
    for (let i = 0; i < mids.length; i++) {
      loads.push(getUpSpaceCache(mids[i]));
    }
    Promise.all<UpSpaceCacheEntry | null>(loads)
      .then((entries: Array<UpSpaceCacheEntry | null>): void => {
        const next: Map<string, number> = new Map<string, number>();
        for (let i = 0; i < mids.length; i++) {
          const entry: UpSpaceCacheEntry | null = entries[i];
          next.set(mids[i], entry !== null ? entry.archiveCount : 0);
        }
        this.archiveCounts = next;
      })
      .catch((e: Error): void => {
        console.error(`load up archive counts failed: ${e.message}`);
      });
  }

  /**
   * 行副行文案：UP 订阅歌单显示「N 个投稿」（N 优先取 UP 投稿总数 archive_count，
   * 不受订阅首页 50 条上限；未知时回退已落库曲目数），其余歌单维持「N 首」。
   * 口径与 UpSpacePage 头部元信息行一致。
   */
  private subLineOf(p: Playlist): string {
    if (LibraryStore.isUpSubscription(p)) {
      const cached: number | undefined = this.archiveCounts.get(p.upMid);
      const count: number = (cached !== undefined && cached > 0) ? cached : p.tracks.length;
      return `${count} 个投稿`;
    }
    return `${p.tracks.length} 首`;
  }

  /**
   * 歌单列表「长按拖动排序」。
   *
   * ForEach.onMove 官方拖拽路线（系统浮起/让位动画 + 拖到边缘自动滚动），下标
   * 限定在 ForEach 数据内 —— 自动避开顶部空白占位条目。本地切片先对齐（与系统
   * 已完成的视觉移动一致），再 LibraryStore.movePlaylist 落库 →
   * persistPlaylists → REV bump → onLibraryChanged → refresh() 重读，
   * 顺序与本地一致、无跳变。所有类型的歌单都可拖：列表顺序是纯本地展示态，
   * 收藏夹同步 / 订阅拉新只改歌单内容、不重建列表顺序（详见 movePlaylist 注释）。
   */
  private onPlaylistMove(from: number, to: number): void {
    if (from < 0 || from >= this.playlists.length) {
      return;
    }
    const moved: Playlist = this.playlists[from];
    const next: Playlist[] = [...this.playlists];
    next.splice(from, 1);
    const target: number = Math.max(0, Math.min(to, next.length));
    next.splice(target, 0, moved);
    this.playlists = next;
    LibraryStore.movePlaylist(moved.id, target);
  }

  /**
   * 顶栏派生镜像唯一写入口：把栏内组件渲染所需的派生状态
   * （可否多选 / 选中数 / 全选态）推到 AppStorage，PlTitleActions / PlSelectToolbar
   * （components/PlaylistsTabBar.ets）@StorageProp 订阅。
   * 触发点：refresh（歌单变化）+ selectedIds @Watch。
   */
  private syncBarState(): void {
    AppStorage.setOrCreate(STORE_PL_BAR_CAN_SELECT, this.playlists.length >= 2);
    AppStorage.setOrCreate(STORE_PL_BAR_SELECTED_COUNT, this.selectedIds.length);
    AppStorage.setOrCreate(STORE_PL_BAR_ALL_SELECTED, this.allSelected());
  }

  /**
   * 根栏整栏让位量（vp）：safeTop + 标题行 56。常量公式首帧即正确，
   * 无需挂载门控（SettingsPage 先例）；多选工具条为页面层覆盖层，不占让位量。
   */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT;
  }

  /**
   * 自绘顶栏渐变模糊层进度更新器 + 校准：onDidScroll / onScrollStop 命令式
   * 驱动 opacity（不标 @State，滚动高频回调零重建）；yOffset 0 →
   * TITLE_BLUR_END_VP 线性映射 0 → 1（updater 内截断，边缘回弹负偏移归零
   * 为死区）。
   */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (TabScrollerHolder.playlists.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  private openCreate(): void {
    this.editingId = '';
    this.editorName = '';
    this.editorMode = EDITOR_MODE_CREATE;
    this.editorCreateController?.open();
  }

  private openRename(p: Playlist): void {
    this.editingId = p.id;
    this.editorName = p.name;
    this.editorMode = EDITOR_MODE_RENAME;
    this.editorRenameController?.open();
  }

  /**
   * 构建编辑弹窗 controller（标题随模式固定；内容区与按钮见 EditorBody）。
   * `cancel`：点遮罩关闭时只复位字段，关闭本身由系统完成。
   */
  private buildEditorDialog(title: string): CustomDialogController {
    return new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: title,
        contentBuilder: (): void => {
          this.EditorBody();
        }
      }),
      autoCancel: true,
      cancel: (): void => {
        this.cancelEditor();
      }
    });
  }

  /** 关闭编辑弹窗（按 editorMode 选中对应 controller；必须在 cancelEditor 复位前调用） */
  private closeEditor(): void {
    if (this.editorMode === EDITOR_MODE_MERGE) {
      this.editorMergeController?.close();
    } else if (this.editorMode === EDITOR_MODE_RENAME) {
      this.editorRenameController?.close();
    } else {
      this.editorCreateController?.close();
    }
  }

  /** 关闭并复位编辑弹窗（先 close 再复位：close 要靠 editorMode 选 controller） */
  private dismissEditor(): void {
    this.closeEditor();
    this.cancelEditor();
  }

  /** 复位全部模式字段（三种模式共用一个弹窗，不复位会串状态；关闭由 closeEditor / 系统负责） */
  private cancelEditor(): void {
    this.editingId = '';
    this.editorMode = EDITOR_MODE_CREATE;
    this.mergeDeleteSources = true;
    this.mergeSourceCount = 0;
    this.mergeRawTotal = 0;
    this.mergeTotal = 0;
    this.mergeDropped = 0;
    this.mergeSubscriptions = 0;
  }

  /** 编辑弹窗确认键文案：合并 / 保存 / 创建（标题由各 controller 的 primaryTitle 固定） */
  private editorConfirmText(): string {
    if (this.editorMode === EDITOR_MODE_MERGE) {
      return '合并';
    }
    return this.editingId.length > 0 ? '保存' : '创建';
  }

  private submitEditor(): void {
    const name: string = this.editorName.trim();
    if (name.length === 0) {
      this.toast('请输入歌单名称', 1500);
      return;
    }
    if (this.editorMode === EDITOR_MODE_MERGE) {
      this.submitMerge(name);
      return;
    }
    if (this.editingId.length === 0) {
      LibraryStore.createPlaylist({ name: name });
      this.toast('歌单已创建', 1500);
    } else {
      LibraryStore.renamePlaylist(this.editingId, name);
      this.toast('已重命名', 1500);
    }
    this.dismissEditor();
    this.refresh();
  }

  // ===== 多选与合并 =====

  /**
   * 批量删除选中的歌单（多选工具条「删除选中」）。
   *
   * 与单删（confirmDelete）的关键差别：**一律只删本地**。
   * 收藏夹镜像的「同时清空 B 站」是逐夹两步确认 + 服务端全集拉取的重流程，
   * 批量场景刻意不复制；镜像被删时同步丢弃该夹待推送意图 —— 与单删「只删本地」
   * 同款纪律，否则残留的 del 意图会在下次推送时误删用户并不想动的收藏。
   * 确认框里明说「B 站收藏夹保留」，用户预期与行为一致。
   */
  private confirmDeleteSelected(): void {
    if (this.selectedIds.length === 0) {
      this.toast('请先选择歌单', 1500);
      return;
    }
    let favMirrorCount: number = 0;
    for (let i = 0; i < this.playlists.length; i++) {
      if (this.isSelected(this.playlists[i].id) && LibraryStore.isFavMirror(this.playlists[i])) {
        favMirrorCount += 1;
      }
    }
    const parts: string[] = [`确定删除选中的 ${this.selectedIds.length} 个歌单？删除后不可恢复。`];
    if (favMirrorCount > 0) {
      parts.push(`其中 ${favMirrorCount} 个是收藏夹镜像，仅删除本地，B 站收藏夹保留（下次同步会重新拉回）。`);
    }
    showAppAlertDialog(this.getUIContext(), {
      title: '删除选中歌单',
      message: parts.join('\n'),
      primaryButton: {
        value: '取消',
        action: (): void => {
          // 取消：不做任何事
        }
      },
      secondaryButton: {
        value: '删除',
        action: (): void => {
          this.deleteSelectedPlaylists();
        }
      }
    });
  }

  /** 确认后执行批量删除：逐个删本地 → 退出多选并汇报 */
  private deleteSelectedPlaylists(): void {
    const ids: string[] = [...this.selectedIds];
    let removed: number = 0;
    for (let i = 0; i < ids.length; i++) {
      const id: string = ids[i];
      let target: Playlist | undefined = undefined;
      for (let j = 0; j < this.playlists.length; j++) {
        if (this.playlists[j].id === id) {
          target = this.playlists[j];
          break;
        }
      }
      if (target === undefined) {
        continue;
      }
      LibraryStore.deletePlaylist(id);
      removed += 1;
    }
    this.selecting = false;
    this.selectedIds = [];
    this.refresh();
    this.toast(`已删除 ${removed} 个歌单`, 1500);
  }

  private toggleSelecting(): void {
    this.selecting = !this.selecting;
    this.selectedIds = [];
  }

  private isSelected(id: string): boolean {
    return this.selectedIds.indexOf(id) >= 0;
  }

  private toggleSelected(id: string): void {
    if (this.isSelected(id)) {
      this.selectedIds = this.selectedIds.filter((x: string): boolean => x !== id);
    } else {
      this.selectedIds = [...this.selectedIds, id];
    }
  }

  private allSelected(): boolean {
    return this.playlists.length > 0 && this.selectedIds.length >= this.playlists.length;
  }

  private toggleSelectAll(): void {
    if (this.allSelected()) {
      this.selectedIds = [];
      return;
    }
    this.selectedIds = this.playlists.map((p: Playlist): string => p.id);
  }

  /** 合并弹窗预填名字：选中歌单名用「 + 」连接，过长截断（用户可改） */
  private defaultMergeName(): string {
    const names: string[] = [];
    for (let i = 0; i < this.playlists.length; i++) {
      if (this.isSelected(this.playlists[i].id)) {
        names.push(this.playlists[i].name);
      }
    }
    const joined: string = names.join(' + ');
    return joined.length > MAX_MERGE_NAME_CHARS ? `${joined.slice(0, MAX_MERGE_NAME_CHARS)}…` : joined;
  }

  /** 打开合并弹窗：先算预览（条数 / 去重 / 超限 / 订阅数），再预填名字 */
  private openMergeEditor(): void {
    if (this.selectedIds.length < 2) {
      this.toast('请至少选择两个歌单', 1500);
      return;
    }
    const preview = LibraryStore.previewPlaylistMerge(this.selectedIds);
    if (preview.sources < 2) {
      this.toast('选中的歌单已不足两个', 1500);
      return;
    }
    this.mergeSourceCount = preview.sources;
    this.mergeRawTotal = preview.rawTotal;
    this.mergeTotal = preview.total;
    this.mergeDropped = preview.dropped;
    this.mergeSubscriptions = preview.subscriptionCount;
    this.mergeDeleteSources = true;
    this.editingId = '';
    this.editorName = this.defaultMergeName();
    this.editorMode = EDITOR_MODE_MERGE;
    this.editorMergeController?.open();
  }

  private submitMerge(name: string): void {
    const result = LibraryStore.mergePlaylists(this.selectedIds, name, this.mergeDeleteSources);
    if (result === null) {
      this.toast('合并失败：没有足够的有效歌单', 1800);
      this.dismissEditor();
      return;
    }
    const parts: string[] = [`已合并 ${result.sources} 个歌单，共 ${result.total} 首`];
    if (result.deduped > 0) {
      parts.push(`去重 ${result.deduped} 首`);
    }
    if (result.dropped > 0) {
      parts.push(`超出 ${PLAYLIST_MAX_ITEMS} 首上限丢弃 ${result.dropped} 首`);
    }
    this.toast(parts.join('，'), 2000);
    this.dismissEditor();
    this.selecting = false;
    this.selectedIds = [];
    this.refresh();
  }

  private playlistMenuItems(p: Playlist): MenuElement[] {
    // 「下载整个歌单」放在这里而不是行内按钮：行内已有封面 / 歌名 / 首数 / ⋮，
    // 再塞一个图标会让热区挤在一起（触达铁律要求相邻不同语义热区间留 8vp 缓冲）。
    // busy 项靠 @State downloadingPlaylistId 变化触发的重渲染刷新（enabled 原生置灰）。
    const busy: boolean = this.downloadingPlaylistId === p.id;
    return [
      {
        value: '重命名',
        action: (): void => {
          this.openRename(p);
        }
      },
      {
        // 入队进行中：置灰并说明在做什么，避免用户以为点了没反应又点一遍
        value: busy ? '正在入队…' : '下载整个歌单',
        enabled: !busy,
        action: (): void => {
          this.confirmDownloadPlaylist(p);
        }
      },
      {
        // 首页快捷卡行：把歌单加入 / 移出首页卡片行；
        // 文案随在架状态切换（libraryRev bump → 本页重渲染时 bindMenu 数组
        // 随之重建）
        value: HomeCardStore.isHomePlaylist(p.id) ? '移出首页' : '加入首页',
        action: (): void => {
          this.toggleHomeCard(p);
        }
      },
      {
        value: '删除歌单',
        action: (): void => {
          this.confirmDelete(p);
        }
      }
    ];
  }

  /**
   * 歌单 ⋯ 菜单「加入首页 / 移出首页」：切换该歌单在首页快捷卡行的在架状态。
   * HomeCardStore 内部 bump STORE_LIBRARY_REV → 本页（菜单文案）与 HomePage
   *（卡片行）即时刷新；上限 9 个（快捷卡行共 10 卡 = 最近播放 1 + 歌单 9）。
   */
  private toggleHomeCard(p: Playlist): void {
    if (HomeCardStore.isHomePlaylist(p.id)) {
      HomeCardStore.removeHomePlaylist(p.id);
      this.toast('已从首页移出', 1500);
      return;
    }
    if (HomeCardStore.addHomePlaylist(p.id)) {
      this.toast('已加入首页', 1500);
    } else {
      this.toast(`首页歌单卡已满（最多 ${HOME_PLAYLIST_CARDS_MAX} 个）`, 1800);
    }
  }

  /**
   * 下载整个歌单：先确认，再逐首入队。
   *
   * 为什么要「逐首 + 节流」而不是一次交给 DownloadManager：
   * `requestDownload` 内部会对每首调 `expandVideoParts`（一次 view 请求）来识别分 P），
   * 100 首连着发就是 100 次密集请求 ——
   * B 站对匿名访问的密集请求**直接限流**
   * （实测连打 8 次 0/8 成功，见 BILI-API.md），表现为「下载到一半全失败」。
   * 所以串行 + 每首之间留间隔，与播放内核「展开合集后延后 1.2s」是同一条经验。
   */
  private confirmDownloadPlaylist(p: Playlist): void {
    if (p.tracks.length === 0) {
      this.toast('歌单是空的', 1500);
      return;
    }
    showAppAlertDialog(this.getUIContext(), {
      title: '下载整个歌单',
      message: `将把「${p.name}」的 ${p.tracks.length} 首加入下载队列。\n已下载的会自动跳过。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '开始下载',
        action: (): void => {
          this.enqueuePlaylist(p);
        }
      }
    });
  }

  /**
   * 来源标记：整单下载的曲目在下载管理里聚成一张歌单卡片（展开才见单曲）。
   *
   * 只带**歌单 id + 名字**、不带曲目列表 —— 曲目本来就在歌单里，
   * 落库两份会在「歌单改名 / 删曲目」后对不上（任务表是历史快照，歌单是活的）。
   */
  private playlistSource(p: Playlist): DownloadSource {
    return { playlistId: p.id, playlistName: p.name };
  }

  /** 正在入队的歌单 id（非空即「该歌单入队进行中」），用于菜单置灰与防重复点击 */
  @State downloadingPlaylistId: string = '';

  /** 串行入队 + 每首节流；结束后一次性汇报排队结果 */
  private async enqueuePlaylist(p: Playlist): Promise<void> {
    if (this.downloadingPlaylistId.length > 0) {
      this.toast('已有歌单正在入队，请稍候', 1800);
      return;
    }
    const tracks: Track[] = p.tracks;
    this.downloadingPlaylistId = p.id;
    this.toast(`正在加入下载队列（0/${tracks.length}）`, 1200);

    let queued: number = 0;
    let skipped: number = 0;
    // 「仅 WiFi 下载」的闸门在 requestDownload 入口，只会在**第一次**返回 blockedReason。
    // 用第一条做探测 → 最多问一次「是否用流量继续」，之后整批放行（与合集同一套逻辑）。
    let ignoreWifiLimit: boolean = false;
    for (let i = 0; i < tracks.length; i++) {
      if (this.downloadingPlaylistId !== p.id) {
        // 歌单在入队过程中被删除 / 用户改了主意：干净收尾，别继续发请求
        return;
      }
      const r: DownloadStartResult = await DownloadManager.getInstance()
        .requestDownload(tracks[i], ignoreWifiLimit, this.playlistSource(p));
      if (r.blockedReason.length > 0) {
        // 第一条就被拦：问一次，用户同意后本批全部放行
        this.confirmCellularBatch(p, tracks, i, queued, skipped);
        return;
      }
      ignoreWifiLimit = true;
      queued += r.queued;
      skipped += r.skipped;
      if ((i + 1) % 5 === 0) {
        this.toast(`正在加入下载队列（${i + 1}/${tracks.length}）`, 800);
      }
      if (i < tracks.length - 1) {
        await delay(PLAYLIST_ENQUEUE_GAP_MS);
      }
    }
    this.downloadingPlaylistId = '';
    this.toast(this.enqueueResultText(queued, skipped), 2500);
  }

  /**
   * 被「仅 WiFi 下载」拦下时的批量询问。
   *
   * 刻意**不续跑剩余曲目**而是让用户重新点一次：这一趟已经把前 i 首处理过了，
   * 续跑逻辑会散在两个地方、容易漏掉「跳过计数」的合并。重新点一次的结果完全相同
   * （已入队的会被 `skipped` 计数跳过），代价只是多点一下。
   */
  private confirmCellularBatch(p: Playlist, tracks: Track[], doneCount: number,
    queued: number, skipped: number): void {
    this.downloadingPlaylistId = '';
    showAppAlertDialog(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: `${WIFI_ONLY_BLOCKED}\n「${p.name}」前 ${doneCount} 首已入队，继续会下载剩余 ${tracks.length - doneCount} 首。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
          this.toast(this.enqueueResultText(queued, skipped), 2000);
        }
      },
      secondaryButton: {
        value: '继续下载',
        action: (): void => {
          // 整批放行：重跑一遍，已入队的会被跳过计数覆盖，幂等
          this.enqueueWithWifiOverride(p);
        }
      }
    });
  }

  /** 用户确认用流量后：整批以 ignoreWifiLimit=true 重跑（已下载/已入队的会跳过） */
  private async enqueueWithWifiOverride(p: Playlist): Promise<void> {
    const tracks: Track[] = p.tracks;
    this.downloadingPlaylistId = p.id;
    let queued: number = 0;
    let skipped: number = 0;
    for (let i = 0; i < tracks.length; i++) {
      const r: DownloadStartResult = await DownloadManager.getInstance()
        .requestDownload(tracks[i], true, this.playlistSource(p));
      queued += r.queued;
      skipped += r.skipped;
      if (i < tracks.length - 1) {
        await delay(PLAYLIST_ENQUEUE_GAP_MS);
      }
    }
    this.downloadingPlaylistId = '';
    this.toast(this.enqueueResultText(queued, skipped), 2500);
  }

  /** 排队结果要分「排上 / 跳过」两种说法，否则用户不知道有多少真进了队列 */
  private enqueueResultText(queued: number, skipped: number): string {
    if (queued === 0 && skipped === 0) {
      return '没有可下载的曲目';
    }
    if (queued === 0) {
      return `全部已在下载队列中（${skipped} 首）`;
    }
    const tail: string = skipped > 0 ? `，跳过 ${skipped} 首已在队列/已下载` : '';
    return `已加入下载队列 ${queued} 首${tail}`;
  }

  private confirmDelete(p: Playlist): void {
    // 收藏夹镜像：删除只动本地镜像歌单，B 站收藏夹原样保留，下次同步会重新
    // 拉回 —— 提示里讲清楚；双向镜像还要说明未同步的本地改动不再写回 B 站
    //（store 挂钩会顺带清空该夹的待推送意图）。
    if (LibraryStore.isFavMirror(p)) {
      const twoway: boolean = isFolderTwoway(LibraryStore.favMediaIdOf(p));
      showAppAlertDialog(this.getUIContext(), {
        title: '删除收藏夹歌单',
        message: `「${p.name}」是 B 站收藏夹的镜像。删除不会影响 B 站收藏夹，下次收藏夹同步会把它重新拉回来。${twoway ? '该收藏夹开启了双向同步：删除后尚未写回 B 站的本地改动将不再同步。' : ''}`,
        primaryButton: {
          value: '取消',
          action: (): void => {
            // 取消：不做任何事
          }
        },
        secondaryButton: {
          value: '删除',
          action: (): void => {
            LibraryStore.deletePlaylist(p.id);
            this.refresh();
            this.toast('已删除本地歌单，B 站收藏夹保留（下次同步会重新拉回）', 2600);
          }
        }
      });
      return;
    }
    showAppAlertDialog(this.getUIContext(), {
      title: '删除歌单',
      message: `确定删除「${p.name}」？删除后不可恢复。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
          // 取消：不做任何事
        }
      },
      secondaryButton: {
        value: '删除',
        action: (): void => {
          LibraryStore.deletePlaylist(p.id);
          this.refresh();
          this.toast('已删除歌单', 1500);
        }
      }
    });
  }

  /**
   * 顶栏在根 HdsNavigation titleBar：标题行 + 多选工具条
   * 都由根栏 stackBuilder 承载（Index.immersiveTitleBarContent 歌单页分支，
   * 组件见 components/PlaylistsTabBar.ets）；最近播放入口在设置页「播放」组。
   * 滚动模糊由根栏 bindToScrollable(TabScrollerHolder.playlists) 驱动。
   */
  /**
   * 编辑弹窗内容区（三模式共用，靠 editorMode 分支合并模式的附加内容）。
   * 标题在各 controller 的 primaryTitle；确认按钮自绘在这里而不是 CustomContentDialog
   * 的 buttons 槽 —— 空名校验失败要保持弹窗打开，buttons 槽点击即自动关闭
   * （faqs-arkui-986），只能自己管关闭时机（dismissEditor / submitEditor）。
   */
  @Builder
  EditorBody(): void {
    Column() {
      // 合并模式：先摆清楚「合并了什么、会丢什么」，再让用户决定名字与是否删源
      if (this.editorMode === EDITOR_MODE_MERGE) {
        Text(`已选 ${this.mergeSourceCount} 个歌单 · ${this.mergeRawTotal} 首 → 去重后 ${this.mergeTotal} 首`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ bottom: 6 })
        if (this.mergeDropped > 0) {
          Text(`超出 ${PLAYLIST_MAX_ITEMS} 首上限，只保留前 ${PLAYLIST_MAX_ITEMS} 首（丢弃 ${this.mergeDropped} 首）`)
            .fontSize(12)
            .fontColor($r('app.color.state_error'))
            .width('100%')
            .margin({ bottom: 6 })
        }
        if (this.mergeDeleteSources && this.mergeSubscriptions > 0) {
          Text(`含 ${this.mergeSubscriptions} 个 UP 订阅歌单，删除原歌单后将失去「拉取新投稿」`)
            .fontSize(12)
            .fontColor($r('app.color.state_error'))
            .width('100%')
            .margin({ bottom: 6 })
        }
      }

      TextInput({ placeholder: '歌单名称', text: this.editorName })
        .width('100%')
        .onChange((v: string): void => {
          this.editorName = v;
        })

      if (this.editorMode === EDITOR_MODE_MERGE) {
        Row() {
          Text('合并后删除原歌单')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
          Blank()
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.mergeDeleteSources })
            .selectedColor(this.themePrimary)
            .onChange((v: boolean): void => {
              this.mergeDeleteSources = v;
            })
        }
        .width('100%')
        .margin({ top: 12 })
        .alignItems(VerticalAlign.Center)
      }

      Row() {
        Button('取消', { type: ButtonType.Normal })
          .layoutWeight(1)
          .height(44)
          .borderRadius(BUTTON_RADIUS_VP)
          .backgroundColor($r('app.color.bg_divider'))
          .fontColor($r('app.color.text_primary'))
          .onClick((): void => {
            this.dismissEditor();
          })
        Button(this.editorConfirmText(), { type: ButtonType.Normal })
          .layoutWeight(1)
          .height(44)
          .borderRadius(BUTTON_RADIUS_VP)
          .backgroundColor(this.themePrimary)
          .fontColor(this.themeOn)
          .margin({ left: 12 })
          .onClick((): void => {
            this.submitEditor();
          })
      }
      .margin({ top: 16 })
    }
    .width('100%')
  }

  /**
   * 行 / 网格卡点击的统一分流：
   * 订阅歌单进 UP 主页 → 点选加入 → 多选勾选 → 默认进详情。
   */
  private openPlaylist(p: Playlist): void {
    // 订阅歌单（helper 判定，收藏夹镜像走默认分支）→ 恒进 UP 主页：
    // 订阅歌单内容随 UP 投稿自动更新，不支持手动加歌，
    // 行语义不被「点选加入」模式接管（拉新投稿 / 播放全部在 UpSpacePage 都有）
    // ⚠️ 用 helper 判定而非 upMid 非空：收藏夹镜像也有 upMid（fav_x），
    // 但它没有「UP 主页」可去，必须走默认分支进 PlaylistDetail
    if (LibraryStore.isUpSubscription(p)) {
      // getUserCard 失败时的兜底名；头像传空串：歌单行只有
      // 视频封面（非 UP 头像）不能当占位，空串由 CoverImage 兜占位图
      NavStackHolder.stack.pushPathByName('UpSpace',
        new UpSpaceRouteParam(p.upMid, p.upName, ''));
      return;
    }
    // 「去歌单页选」点选模式：整行 = 把快照曲目加入
    // 该歌单，单次点选即退出
    if (this.picking) {
      this.addPickedTrack(p);
      return;
    }
    // 多选模式下整行 = 勾选/取消，而不是进详情
    if (this.selecting) {
      this.toggleSelected(p.id);
      return;
    }
    NavStackHolder.stack.pushPathByName('PlaylistDetail',
      new PlaylistDetailRouteParam(p.id));
  }

  /**
   * 单条歌单行：
   * 常驻勾选槽位 + 封面 + 歌单名/副行 + 更多操作；整行点击 = 点选加入 /
   * 多选勾选 / 订阅歌单进 UP 主页 / 默认进详情。单列分支 ListItem 直下渲染；
   * 两列分支由配对 Row 的左右槽各调一次（勾选 / 点选 / 按压状态互不影响，
   * pressedKey 只存一个 id，同一时刻只有被按的那行缩放）。
   */
  @Builder
  PlaylistRow(p: Playlist): void {
    Row() {
      // 常驻勾选槽位：进出多选用「槽位宽度 0↔SELECT_SLOT_VP + 勾选圈位移动画」表达，
      // 绝不能用 if(selecting) 条件挂载 —— 节点增删没有过渡，行内容会跳变。
      Row() {
        Checkbox({ name: p.id, group: 'plSelect' })
          .select(this.isSelected(p.id))
          .selectedColor(this.themePrimary)
          .unselectedColor($r('app.color.text_disabled'))
          .shape(CheckBoxShape.CIRCLE)
          .width(20)
          .height(20)
          .translate({ x: this.selecting ? 0 : SELECT_SLOT_VP })
          .animation({ duration: SELECT_TOGGLE_MS, curve: Curve.EaseOut })
          // 选中态是装饰：切换入口是整行点击，别占读屏焦点，也别吃整行点击
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no')
      }
      .width(this.selecting ? SELECT_SLOT_VP : 0)
      .height(20)
      .clip(true)
      .justifyContent(FlexAlign.Center)
      .animation({ duration: SELECT_TOGGLE_MS, curve: Curve.EaseOut })

      // 64vp 显示位按 2x 请求图床缩略图（高度预算 = 歌单名两行
      // lineHeight(21)×2 + 间距 4 + 副行 lineHeight(17) = 63 ≤ 64）；
      // 加载中 / 失败由 CoverImage 兜浅粉占位
      CoverImage({
        url: toThumbUrl(p.coverUrl, 128),
        imgWidth: 64,
        imgHeight: 64,
        imgRadius: 8,
        altText: p.name
      })
      Column() {
        // 歌单名双行显示：maxLines(2) +
        // 第二行省略号；显式 lineHeight(21) 锁行高（默认行高随字体浮动，
        // 会破坏「信息高度 ≤ 封面高度」的硬预算，见封面注释）。
        Text(p.name)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(21)
        // 副行行高锁 17（13sp）：与歌单名 lineHeight(21) 一起构成高度
        // 预算（2×21 + 4 + 17 = 63 ≤ 封面 64），见封面注释。
        // UP 订阅歌单显示「N 个投稿」（投稿总数，非落库曲目数），见 subLineOf
        Text(this.subLineOf(p))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(17)
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
      // 更多操作：重命名 / 删除（父 Row 的 onClick 进详情，这里单独拦截）
      // 触达铁律：视觉是 22px 的字，命中区必须撑到 44×44；
      // 父 Row 的 onClick 会进详情，热区不够时极易误触。
      Row() {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(20)
          .fontColor([$r('app.color.text_tertiary')])
      }
        .width(44)
        .height(44)
        .borderRadius(22)
        .justifyContent(FlexAlign.Center)
        .visibility(this.selecting ? Visibility.None : Visibility.Visible)
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.press_overlay')) },
          normal: { .backgroundColor(Color.Transparent) }
        })
        .accessibilityText('更多操作')
        .accessibilityLevel('yes')
        .bindMenu(this.playlistMenuItems(p))
    }
    .width('100%')
    .padding({ left: 16, right: 4, top: 10, bottom: 10 })
    // 按压反馈＝纯缩放形变（与搜索页 TrackItem 同款）：按下收到 0.9 的
    // 收缩确认，抬起/取消回弹 1.0 —— 不改底色、不加蒙层；行内勾选圈/
    // 槽位的动画声明在子组件上，被各自的 .animation() 接管，互不干扰。
    // .animation() 紧跟 .scale()：只接管 scale 这一个可变属性。
    .scale({
      x: this.pressedKey === p.id ? PRESS_SCALE : 1,
      y: this.pressedKey === p.id ? PRESS_SCALE : 1
    })
    .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
    // onTouch 只回写缩放状态、不消费事件：onClick 照常触发；
    // 列表滚动抢占手势时系统派发 Cancel，行自动回弹。
    .onTouch((event: TouchEvent): void => {
      this.setPressed(event.type, p.id);
    })
    .onClick((): void => {
      this.openPlaylist(p);
    })
  }

  /**
   * 单条歌单网格卡（「条目展示 = 大封面」模式）：方形大封面 +
   * 歌单名 + 副行。交互契约与 PlaylistRow 完全一致 —— 多选勾选圈（整卡点击
   * 勾选/取消）、点选加入、「⋮」菜单（重命名 / 下载整个歌单 / 删除）、按压
   * 缩放；仅拖动排序在网格分支不注册（配对后拖动会以「一对」为单位错乱，
   * 与横屏两列同口径）。封面按 360 请求高清缩略图（约 134vp 卡宽 ——
   * 含 24vp 行页边距，仍近 3x 余量）。
   */
  @Builder
  PlaylistCard(p: Playlist): void {
    Column() {
      // 封面层：方形大封面 + 多选勾选圈（左上）+ 「⋮」菜单钮（右上）
      Stack({ alignContent: Alignment.TopEnd }) {
        CoverImage({
          url: toThumbUrl(p.coverUrl, 360),
          imgRadius: 10,
          fillParent: true,
          altText: p.name
        })

        // 多选勾选圈：装饰性（切换入口是整卡点击），与行内版同款系统圆形 Checkbox
        if (this.selecting) {
          Checkbox({ name: p.id, group: 'plSelect' })
            .select(this.isSelected(p.id))
            .selectedColor(this.themePrimary)
            .unselectedColor($r('app.color.text_disabled'))
            .shape(CheckBoxShape.CIRCLE)
            .width(20)
            .height(20)
            .position({ x: 10, y: 10 })
            .hitTestBehavior(HitTestMode.None)
            .accessibilityLevel('no')
        }

        // 「⋮」菜单：视觉 16px 白色图形 + 半透明深色圆底（叠封面上需保证对比度），
        // 命中区 36×36（对 44vp 触达下限的折衷，见 TrackCard 同款注释）；
        // 多选时隐藏（与行内版口径一致）
        Row() {
          SymbolGlyph($r('sys.symbol.more'))
            .fontSize(16)
            .fontColor([Color.White])
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor('rgba(0, 0, 0, 0.35)')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 6, right: 6 })
        .visibility(this.selecting ? Visibility.None : Visibility.Visible)
        .accessibilityText('更多操作')
        .accessibilityLevel('yes')
        .bindMenu(this.playlistMenuItems(p))
      }
      .width('100%')
      .aspectRatio(1)

      // 歌单名：13sp 两行（大封面模式的小字标题）。外层定高 Column 锁两行区
      // （34 = 17×2）：一行歌单名也占满两行区，同排卡高一致（配合配对行
      // Top 对齐，封面严格同高起步）；Column 子项默认从顶起排（Text 定高会
      // 垂直居中，故不能直接给 Text 设 height）。行高显式锁定保证网格行距一致。
      Column() {
        Text(p.name)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(17)
          .width('100%')
      }
      .height(34)
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 6 })

      // 副行：N 首 / N 个投稿（与行内版同一口径，见 subLineOf）
      Text(this.subLineOf(p))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .width('100%')
        .margin({ top: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 网格行距：卡底统一 12vp（与 TWO_COL_GAP_VP
    // 同节奏），行与行分隔；margin 是布局量、不参与下方 scale 按压变换。
    .margin({ bottom: 12 })
    // 按压反馈＝纯缩放形变（与行内版同一 pressedKey 机制，网格卡缩放幅度收敛）：
    // .animation() 紧跟 .scale()，只接管 scale 这一个可变属性。
    .scale({
      x: this.pressedKey === p.id ? PL_CARD_PRESS_SCALE : 1,
      y: this.pressedKey === p.id ? PL_CARD_PRESS_SCALE : 1
    })
    .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      this.setPressed(event.type, p.id);
    })
    .onClick((): void => {
      this.openPlaylist(p);
    })
  }

  build() {
    Stack() {
      // 内容层：顶部让出固定标题栏高度，内容整体滚动
      Column() {
        if (this.playlists.length === 0) {
          Column() {
            Column() {
              Text('还没有歌单')
                .fontColor($r('app.color.text_secondary'))
                .fontSize(16)
              Text('点击右上角“新建”创建')
                .fontColor($r('app.color.text_tertiary'))
                .fontSize(13)
                .margin({ top: 8 })
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          }
          .width('100%')
          .height('100%')
          // 内容列不再整体 padding top（列表穿透需要），空态自己补栏高避让
          .padding({ top: this.barTotalHeight() })
          // 让位为常量公式（见 barTotalHeight），首帧即正确，无需挂载门控
          } else {
            List({ scroller: TabScrollerHolder.playlists }) {
              // 顶部空白占位条目：列表视口铺满全屏，条目起始位置在屏幕顶端（y=0）。
              // 占位高度 = 根标题栏（barTotalHeight：safeTop + 56），首个真实条目恰
              // 从栏底起排（静置位与旧 contentStartOffset 等值），滚动时占位与条目
               // 一起从模糊板下方穿过（与下载页同款）。
              ListItem() {
                // Blank 只能嵌在 Row/Column/Flex 内（编译器 10905201），ListItem 直下用定高容器。
                Column() {
                   // 「去歌单页选」点选提示条：放在顶部占位条目内部而
                  // 不是悬浮覆盖层 —— 占位高度随提示条 +PICK_HINT_HEIGHT_VP，列表
                  // 内容整体下移，不会被遮住（悬浮方案会盖住第一行歌单）。
                  if (this.picking) {
                    Row() {
                      Text(`「${this.pickTrackTitle()}」将加入你点选的歌单`)
                        .fontSize(13)
                        .fontColor(this.themeOn)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      Text('取消')
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.themeOn)
                        .height(36)
                        .padding({ left: 12, right: 12 })
                        .borderRadius(BUTTON_RADIUS_VP)
                        .stateStyles({
                          pressed: { .backgroundColor('rgba(255, 255, 255, 0.2)') },
                          normal: { .backgroundColor(Color.Transparent) }
                        })
                        .onClick((): void => {
                          this.picking = false;
                        })
                    }
                    .width('100%')
                    .padding({ left: 16, right: 8, top: 8, bottom: 8 })
                    .backgroundColor(this.themePrimary)
                    .borderRadius(BUTTON_RADIUS_VP + 4)
                  }
                }
                .width('100%')
                .height(this.barTotalHeight() + (this.picking ? PICK_HINT_HEIGHT_VP : 0))
                .justifyContent(FlexAlign.End)
                .padding({ left: 12, right: 12, bottom: 4 })
                .animation({ duration: SELECT_TOGGLE_MS, curve: Curve.EaseOut })
              }
              // 大封面模式（外观设置「条目展示」）：歌单配对成
              // 双列网格卡（PlaylistCard），竖屏 / 横屏均双列；交互契约与行内
              // 版一致（多选 / 点选 / 菜单），仅不注册 onMove（配对后拖动会以
              // 「一对」为单位错乱，与横屏两列同口径）。
              // 首个「占位+点选提示」条目保持整行（在下方分支之外）。
              if (this.isGrid()) {
                ForEach(
                  makePairs<Playlist>(this.playlists),
                  (pair: PairOf<Playlist>): void => {
                    ListItem() {
                      Row() {
                        Column() {
                          this.PlaylistCard(pair.first)
                        }
                        .layoutWeight(1)
                        // 固定宽间隔条（非 weighted）：两卡均 layoutWeight(1) 且零
                        // margin → 左右封面严格等宽（layoutWeight 份额含 margin，
                        // margin 挂 weighted 卡会让该卡窄 12vp）；奇数末行也保留
                        // 间隔条，末卡与满行卡等宽。
                        Blank().width(TWO_COL_GAP_VP)
                        if (pair.second !== null) {
                          Column() {
                            this.PlaylistCard(pair.second)
                          }
                          .layoutWeight(1)
                        } else {
                          // 奇数末尾：右侧槽留空占位，左列卡宽与前面各行一致
                          Blank().layoutWeight(1)
                        }
                      }
                      .width('100%')
                       // 网格行页边距：两边留白 + 封面整体
                      // 缩小约 15%，见 GRID_EDGE_PADDING_VP 注释。
                      .padding({ left: GRID_EDGE_PADDING_VP, right: GRID_EDGE_PADDING_VP })
                       // Top 对齐：卡高随歌单名行数浮动，
                      // Row 默认 Center 会把矮卡垂直居中 → 左右封面错位；
                      // Top 让左右封面严格同高起步。
                      .alignItems(VerticalAlign.Top)
                    }
                  },
                  (pair: PairOf<Playlist>): string =>
                    `${pair.first.id}_${pair.first.name}_${pair.first.tracks.length}` +
                    `|${pair.second !== null
                      ? `${pair.second.id}_${pair.second.name}_${pair.second.tracks.length}`
                      : 'x'}`
                )
              } else if (this.isTwoCol()) {
               // 横屏宽屏：歌单行配对两列（PlaylistRow 同一份
              // 行内容，左右槽各渲染一次）；拖动排序（onMove）只挂在单列分支 ——
              // 配对后拖动会以「一对」为单位错乱，有意做成竖屏专属（与
              // PlaylistDetail 可排序歌单同口径）。首个「占位+点选提示」条目保持整行。
                ForEach(
                  makePairs<Playlist>(this.playlists),
                  (pair: PairOf<Playlist>): void => {
                    ListItem() {
                      Row() {
                        Column() {
                          this.PlaylistRow(pair.first)
                        }
                        .layoutWeight(1)
                        if (pair.second !== null) {
                          Column() {
                            this.PlaylistRow(pair.second)
                          }
                          .layoutWeight(1)
                          .margin({ left: TWO_COL_GAP_VP })
                        } else {
                          // 奇数末尾：右侧槽留空占位，左列行宽与前面各行一致
                          Blank().layoutWeight(1)
                        }
                      }
                      .width('100%')
                    }
                  },
                  (pair: PairOf<Playlist>): string =>
                    `${pair.first.id}_${pair.first.name}_${pair.first.tracks.length}` +
                    `|${pair.second !== null
                      ? `${pair.second.id}_${pair.second.name}_${pair.second.tracks.length}`
                      : 'x'}`
                )
              } else {
                ForEach(
                  this.playlists,
                  (p: Playlist): void => {
                    ListItem() {
                      this.PlaylistRow(p)
                    }
                  },
                  (p: Playlist): string => `${p.id}_${p.name}_${p.tracks.length}`
                )
                   // 长按拖动排序：多选 / 点选加入模式下禁用（整行是
                  // 点选热区，长按拖动与点选手势打架），传 undefined = 不注册。
                  .onMove(this.selecting || this.picking
                    ? undefined
                    : (from: number, to: number): void => {
                      this.onPlaylistMove(from, to);
                    })
              }
          }
          .layoutWeight(1)
           // 边界回弹：到顶/到底的反馈动效
           .edgeEffect(EdgeEffect.Spring)
          .cachedCount(8)
          // 顶部根标题栏让位（Sumy 式穿透）：由 List 首个空白占位 ListItem 负责
           //（见上方占位注释），不用 contentStartOffset。
          // 底部悬浮页签让位：列表末尾可滚动至悬浮条上方，不被遮挡
          // 页签栏自己抬高了 safeBottom（见 Index.ets），列表末尾要跟着多让这么多
          .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
           // 逐帧驱动自绘渐变模糊层（onDidScroll 在偏移已应用后回调，
          // onWillScroll 是应用前，快滑时差一整帧会让模糊层滞后一跳）。
          .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
            this.syncTopBlurProgress();
          })
          .onScrollStop((): void => {
            // Idle 校准终态：兜住 Fling 期丢帧 / 死区过滤累计的偏差。
            this.syncTopBlurProgress();
          })
        }
      }
      .width('100%')
      .height('100%')
      // ⚠️ 不再整体 padding top：列表视口要铺满全屏（List 首个空白占位 ListItem
      // 负责让出标题栏 barTotalHeight），否则条目在栏底被裁掉、永远滑不进模糊板下方。
      // 空态区自己补 topBarHeight。
      // 大屏适配：内容列收窄居中（根 Stack 默认居中对齐，挂上限即可）；
      // 横屏宽屏两列时上限放宽到 840（CONTENT_MAX_WIDTH_TWOCOL），竖屏维持原值
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })

       // 顶栏渐变模糊层：盖内容列之上（z 序低于根栏 HDS titleBar），
      // 进度由列表 onDidScroll/onScrollStop 经 topBlurUpdater 命令式驱动。
      TopGradientBlurOverlay({
        barHeightVp: this.barTotalHeight(),
        updater: this.topBlurUpdater
      })
    }
  }
}