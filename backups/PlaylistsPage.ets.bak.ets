/**
 * 歌单列表页：展示本地歌单，支持新建 / 重命名 / 删除歌单、进入详情
 * （订阅歌单除外：行点击进 UP 主页，订阅流以 UP 为核心）。
 * 数据来自 LibraryStore（内部有内存快照 + 异步落盘）。
 *
 * 简约 iOS 风格：顶栏在根 HdsNavigation titleBar（沉浸材质 + 滚动模糊由 HDS
 * 承担，内容见 components/PlaylistsTabBar.ets）——HarmonyX 根栏移植（2026-10-10）
 * 起根栏 stackBuilder 承载标题行 + 多选工具条（行 1 / 行 2 溢出渲染，
 * Index.immersiveTitleBarContent 歌单页分支）；最近播放入口在设置页「播放」组。
 */

import {
  LibraryStore,
  PLAYLIST_MAX_ITEMS
} from '../service/LibraryStore';
import { Playlist, Track } from '../model/MusicModels';
import { toThumbUrl } from '../utils/TextUtil';
import { NavStackHolder } from '../service/NavStackHolder';
import {
  CONTENT_END_OFFSET,
  STORE_LIBRARY_REV,
  STORE_PL_BAR_ALL_SELECTED,
  STORE_PL_BAR_CAN_SELECT,
  STORE_PL_BAR_SELECTED_COUNT,
  STORE_PL_BAR_SELECTING,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP
} from '../common/Constants';
import { showAppToast } from '../components/AppToast';
import { showAppAlertDialog } from '../components/AppAlertDialog';
import { CoverImage } from '../components/CoverImage';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
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
 * 阶段 3 迁移（2026-10-11）：自绘 scrim+card 弹层 → CustomContentDialog 标准
 * 对话框（仍走 CustomDialogController，**绝不走 promptAction** —— 崩溃史见
 * AppAlertDialog.ets 头注释）。标题用组件 primaryTitle，三种模式各持一个
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
  /** 名称编辑弹窗：editingId 为空表示新建，非空表示重命名（弹窗本体见三个 editor*Controller） */
  @State editingId: string = '';
  @State editorName: string = '';
  /** 编辑弹窗用途（新建 / 重命名 / 合并） */
  @State editorMode: number = EDITOR_MODE_CREATE;
  /**
   * 多选模式开关（批 4 状态迁移）：顶栏迁根容器后，栏内「选择/完成」按钮
   * （components/PlaylistsTabBar.ets）要读它 —— 直接挂 AppStorage 单向镜像给根栏。
   */
  @StorageLink(STORE_PL_BAR_SELECTING) selecting: boolean = false;
  /**
   * 已选中的歌单 id。@Watch 同步顶栏派生镜像（选中数 / 全选态），根栏工具条据此刷新。
   */
  @State @Watch('syncBarState') selectedIds: string[] = [];
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
  /**
   * 列表滚动控制器：List 直接挂 TabScrollerHolder.playlists（唯一真源，身份恒定），
   * 由根 HdsNavigation bindToScrollable 绑定驱动顶栏滚动模糊（批 4 起模糊由 HDS 承担；
   * 2026-10-11 起不再 new 私有实例后注册替换——首开无模糊修复）。
   */

  aboutToAppear(): void {
    // 批 4：顶栏迁根容器 —— 栏内按钮动作注册进持有器
    // （scroller 不再注册替换——List 直挂 Holder.playlists 唯一真源，2026-10-11）
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
    // 歌单编辑弹窗（阶段 3）：三模式各建一个 CustomContentDialog controller
    this.editorCreateController = this.buildEditorDialog('新建歌单');
    this.editorRenameController = this.buildEditorDialog('重命名歌单');
    this.editorMergeController = this.buildEditorDialog('合并歌单');
    // 首次 refresh 是冷启动同步读（getSync + JSON.parse ×2：歌单 + 最近播放），
    // 延后一拍执行别卡首帧（做法同 SettingsPage 的缓存统计）。跑完缓存即热，
    // onPageShow / onLibraryChanged 的后续 refresh 全走内存快照，无 IO；
    // 首帧歌单列表短暂空态可接受，换的是首屏零磁盘读。
    setTimeout((): void => {
      this.refresh();
    }, 0);
  }

  /** 切回本 Tab / 从子页返回时刷新（Tabs 的 TabContent 常驻，aboutToAppear 只触发一次） */
  onPageShow(): void {
    this.refresh();
  }

  onLibraryChanged(): void {
    this.refresh();
  }

  private refresh(): void {
    this.playlists = LibraryStore.getPlaylists();
    this.syncBarState();
  }

  /**
   * 顶栏派生镜像唯一写入口（批 4 状态迁移）：把栏内组件渲染所需的派生状态
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
   * 根栏整栏让位量（vp）：safeTop + 标题行 56（2026-10-10 歌单页 HDS 适配）。
   * bottomBuilder 第二行退役后为常量公式，首帧即正确，无需挂载门控
   * （SettingsPage 先例）；多选工具条为页面层覆盖层，不占让位量。
   */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT;
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
        value: '删除歌单',
        action: (): void => {
          this.confirmDelete(p);
        }
      }
    ];
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
   * 顶栏在根 HdsNavigation titleBar（HarmonyX 根栏移植）：标题行 + 多选工具条
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
            .selectedColor($r('app.color.bili_pink'))
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
          .backgroundColor($r('app.color.bili_pink'))
          .fontColor($r('app.color.brand_on'))
          .margin({ left: 12 })
          .onClick((): void => {
            this.submitEditor();
          })
      }
      .margin({ top: 16 })
    }
    .width('100%')
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
              ForEach(
                this.playlists,
              (p: Playlist): void => {
                ListItem() {
                  Row() {
                    // 常驻勾选槽位：进出多选用「槽位宽度 0↔SELECT_SLOT_VP + 勾选圈位移动画」表达，
                    // 绝不能用 if(selecting) 条件挂载 —— 节点增删没有过渡，行内容会跳变。
                    // 阶段 5（2026-10-11）：自绘「✓ 圆圈」换成系统标准 Checkbox（圆形选中圈）。
                    Row() {
                      Checkbox({ name: p.id, group: 'plSelect' })
                        .select(this.isSelected(p.id))
                        .selectedColor($r('app.color.bili_pink'))
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

                    // 56vp 显示位按 2x 请求图床缩略图；加载中 / 失败由 CoverImage 兜浅粉占位
                    CoverImage({
                      url: toThumbUrl(p.coverUrl, 112),
                      imgWidth: 56,
                      imgHeight: 56,
                      imgRadius: 8,
                      altText: p.name
                    })
                    Column() {
                      Text(p.name)
                        .fontSize(16)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                      Text(`${p.tracks.length} 首`)
                        .fontSize(13)
                        .fontColor($r('app.color.text_secondary'))
                        .margin({ top: 4 })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    .margin({ left: 12 })
                    // 更多操作：重命名 / 删除（父 Row 的 onClick 进详情，这里单独拦截）
                    // 触达铁律：视觉是 22px 的字，命中区必须撑到 44×44；
                    // 父 Row 的 onClick 会进详情，热区不够时极易误触。
                    Text('⋮')
                      .fontSize(22)
                      .fontColor($r('app.color.text_tertiary'))
                      .width(44)
                      .height(44)
                      .borderRadius(22)
                      .textAlign(TextAlign.Center)
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
                    // 多选模式下整行 = 勾选/取消，而不是进详情 / UP 主页
                    if (this.selecting) {
                      this.toggleSelected(p.id);
                      return;
                    }
                    // 订阅歌单（upMid 非空）→ 进 UP 主页：订阅流的核心对象是 UP 本身，
                    // 拉新投稿 / 播放全部在 UpSpacePage 都有；详情页不再对订阅歌单开放
                    if (p.upMid.length > 0) {
                      NavStackHolder.upMid = p.upMid;
                      // getUserCard 失败时的兜底名
                      NavStackHolder.upName = p.upName;
                      // ⚠️ 必须显式清空：静态字段会残留上一个 UP 的头像；歌单行只有
                      // 视频封面（非 UP 头像）不能当占位，空串由 CoverImage 兜占位图
                      NavStackHolder.upFace = '';
                      NavStackHolder.stack.pushPath({ name: 'UpSpace' });
                      return;
                    }
                    NavStackHolder.selectedPlaylistId = p.id;
                    NavStackHolder.stack.pushPath({ name: 'PlaylistDetail' });
                  })
                }
              },
              // key 含渲染字段：重命名（name）与订阅拉新（tracks.length）后 key 变化，
              // 行才会销毁重建；只含 p.id 时复用旧行导致改名后仍显示旧名（重启才刷新）
              (p: Playlist): string => `${p.id}_${p.name}_${p.tracks.length}`
            )
          }
          .layoutWeight(1)
          // 边界回弹（2026-10-08）：到顶/到底的反馈动效
          .edgeEffect(EdgeEffect.Spring)
          // 顶部根标题栏让位（Sumy 式穿透）：列表视口铺满全屏，首项从栏底起排，
          // 滚动时条目从模糊板下方穿过（safeTop + 56 常量公式，见 barTotalHeight）
          .contentStartOffset(this.barTotalHeight())
          // 底部悬浮页签让位：列表末尾可滚动至悬浮条上方，不被遮挡
          // 页签栏自己抬高了 safeBottom（见 Index.ets），列表末尾要跟着多让这么多
          .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
        }
      }
      .width('100%')
      .height('100%')
      // ⚠️ 不再整体 padding top：列表视口要铺满全屏（contentStartOffset 负责让出栏高），
      // 否则条目在栏底被裁掉、永远滑不进模糊板下方。空态区自己补 topBarHeight。
      // 大屏适配：内容列收窄居中（根 Stack 默认居中对齐，挂上限即可）
      .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
    }
  }
}