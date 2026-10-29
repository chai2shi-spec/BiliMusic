/**
 * 收藏夹同步页（B 站收藏夹 → 本地歌单镜像，手动选择性同步）。
 *
 * 入口：「设置 → 账户 → 收藏夹同步」（路由名仍为 'CloudSync'）。
 *
 * ⚠️ 产品决策：**登录成功后不再自动同步**，收藏夹只在本页手动触发；
 * 且每个收藏夹可勾选是否参与同步（默认全选，勾选状态持久化，见 FavSelectionStore）。
 * 「收藏夹」区块标题行右侧提供「全选/全不选」批量入口：只改勾选态（一次落盘），
 * 不自动触发同步，需再点「立即同步」（与单夹「勾选即同步」语义有意不同）。
 *
 * 数据来源：`service/FavSyncManager`（编排一轮同步）+ `service/FavSyncStore`
 * （每夹上次同步结果）+ `api/BilibiliApi.getFavoriteFolders`（进页拉收藏夹列表，
 * 未同步过的夹也要展示出来供勾选）。本页**只负责触发与展示**，同步的写操作
 * 都在管理器里完成，避免并发写同一份镜像数据。
 *
 * 订阅：
 *   · `STORE_LOGIN_REV`  —— 登录/登出后重查登录态并重拉收藏夹列表
 *   · `STORE_FAV_SYNC_REV` —— 每轮同步开始/结束递增，@Watch 里刷新 syncing 与列表
 *   · `STORE_SAFE_TOP|BOTTOM` —— 自绘沉浸顶栏让位 / 底部安全区
 *
 * 状态机：needLogin / syncing / idle（有列表，无在跑）/（列表空 = 空态）。
 * 单夹结果徽标三档：ok（state_success）/ partial（state_warning）/ failed（state_error）。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，stackBuilder 承载
 * 标题，与 FollowsPage / RecentPage 同构；返回键为 HDS 默认键）：avoidLayoutSafeArea 挡状态栏
 * 重叠，材质与滚动模糊由 HDS 统一渲染（样式见 HdsTitleBarStyle）；
 * bottomBuilder 承载「上次同步 …」状态行（仅有列表时渲染，定高 28）。
 *
 * ⚠️ 同步方向**按夹可选**：每行滑块「单向（默认）/ 双向」。
 * 单向 = B 站 → 本地（本地改动不写回）；双向 = 本地增删实时写回 B 站
 * （移除 = 取消收藏，失败自动补推）；勾选一个收藏夹即自动触发一轮同步。
 * B 站取消收藏 → 本地移除，但只有当某收藏夹在服务端被**完整**拉取成功、
 * 且该夹无未冲刷的写回积压时才允许删本地（断网 / 被风控 / 有积压的那轮只增不减）。
 */

import { FavSyncManager, FavSyncSummary } from '../service/FavSyncManager';
import { FavFolderSyncState, FAV_SYNC_OK, FAV_SYNC_PARTIAL, FAV_SYNC_FAILED, loadFavSyncStates, getFavSyncState } from '../service/FavSyncStore';
import { isFolderSelected, setFolderSelected, setAllFoldersSelected } from '../service/FavSelectionStore';
import { isFolderTwoway, setFolderTwoway } from '../service/FavTwowayStore';
import { FavoriteFolder, FavoriteFoldersResult, getFavoriteFolders } from '../api/BilibiliApi';
import { getLoginUser, LoginUser } from '../service/LoginStore';
import { NavStackHolder } from '../service/NavStackHolder';
import { showAppToast } from '../components/AppToast';
import { InsetCard, CardDivider } from '../components/InsetCardGroup';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier
} from '../utils/HeaderBarMaterial';
import { HdsNavDestination, BottomBuilderShowType } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import {
  CONTENT_END_OFFSET,
  STORE_LOGIN_REV,
  STORE_FAV_SYNC_REV,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE,
  STORE_THEME_ON
} from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import {
  TWO_COL_GAP_VP,
  TwoColumnLayout
} from '../common/utils/TwoColumnList';
import { NAV_TRANSITION_MS, BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';

/** 「立即同步」冷却（ms）：收藏夹接口对高频请求敏感，连点只会继续被拒 */
const RETRY_COOLDOWN_MS: number = 4000;

/**
 * 标题栏状态行（「上次同步 10:23 · 3 个收藏夹」）固定高：
 * padding 4/8 + 文本 11fp ≈ 28。bottomBuilder 高度不自适应（官方约束），
 * 必须与行内容定高一致。
 */
const SYNC_STATUS_ROW_HEIGHT: number = 28;

/** 时间戳 → 时钟文本：当天「10:23」，跨天「10-12 10:23」 */
function formatClock(ms: number): string {
  if (!(ms > 0)) {
    return '';
  }
  const d: Date = new Date(ms);
  const hh: number = d.getHours();
  const mm: number = d.getMinutes();
  const hhStr: string = hh < 10 ? `0${hh}` : `${hh}`;
  const mmStr: string = mm < 10 ? `0${mm}` : `${mm}`;
  const now: Date = new Date();
  if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth()
    && d.getDate() === now.getDate()) {
    return `${hhStr}:${mmStr}`;
  }
  const mon: number = d.getMonth() + 1;
  const day: number = d.getDate();
  const monStr: string = mon < 10 ? `0${mon}` : `${mon}`;
  const dayStr: string = day < 10 ? `0${day}` : `${day}`;
  return `${monStr}-${dayStr} ${hhStr}:${mmStr}`;
}

/**
 * 收藏夹展示行（勾选同步）：服务端收藏夹列表（进页拉取）+
 * 勾选态（FavSelectionStore）+ 上次同步状态（FavSyncStore）三者合并的 UI 模型。
 * 未同步过的夹 state 为 null（徽标不渲染、副题显示服务端条数）。
 */
interface FavRowItem {
  /** 收藏夹 id（B 站的 media_id） */
  mediaId: number;
  title: string;
  /** 服务端报告的条数（未同步过时作为副题展示） */
  mediaCount: number;
  /** 是否勾选参与同步（默认全选） */
  selected: boolean;
  /** 同步方向：true = 双向（本地增删写回 B 站），false = 单向（默认） */
  twoway: boolean;
  /** 上次同步状态；null = 从未同步过 */
  state: FavFolderSyncState | null;
}

@Component
export struct FavSyncPage {
  /** 未登录：渲染登录引导空态（不发请求） */
  @State needLogin: boolean = false;
  /** 主题色运行时值：同步按钮与登录引导跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /** 同步进行中（镜像 FavSyncManager.isRunning()） */
  @State syncing: boolean = false;
  /** 每夹上次同步状态（来自 FavSyncStore，按 mediaId 稳定） */
  @State states: FavFolderSyncState[] = [];
  /**
   * 收藏夹展示行：进页拉服务端收藏夹列表（未同步过的夹也展示，
   * 否则首次使用时没有任何可勾选的东西）。拉取失败时保留为空，回退 states 兜底。
   */
  @State rows: FavRowItem[] = [];
  /** 收藏夹列表拉取中（进页 / 登录后 / 手动重试） */
  @State foldersLoading: boolean = false;
  /** 收藏夹列表拉取失败原因（'' = 无失败）；失败时展示重试行 */
  @State foldersError: string = '';
  /** 最近一次同步时间（ms 时间戳，0 = 从未同步） */
  @State lastSyncAt: number = 0;
  /** 同步冷却中：按钮禁用 */
  @State retryCooling: boolean = false;
  private retryLocked: boolean = false;
  private retryTimer: number = -1;

  /** 登录态版本号：登录/登出后重查（本页无独立登录入口，仅跟随全局态） */
  @StorageProp(STORE_LOGIN_REV) @Watch('onLoginRevChanged') loginRev: number = 0;
  /**
   * 收藏夹同步版本号：FavSyncManager 每轮同步开始与结束各递增一次，
   * @Watch 里重读 syncing / 列表 / 上次时间。
   */
  @StorageProp(STORE_FAV_SYNC_REV) @Watch('onFavSyncRevChanged') favSyncRev: number = 0;
  /** 状态栏高度（vp）：自绘顶栏由本页自己顶下来 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：列表末尾要自己让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 横竖屏（Index 常驻注册写入）：横屏宽屏时卡片内行两列显示 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;

  /** 横屏宽屏（窗口 ≥600vp 的横屏）时卡片内行两列显示；竖屏 / 窄窗口单列不变 */
  private isTwoCol(): boolean {
    return TwoColumnLayout.isActive(this.currentBreakpoint, this.isLandscape);
  }

  /** HDS 标题栏整体让位量（vp）= safeTop + 标题行 56 + 状态行 28（有列表时） */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT
      + (this.hasListContent() ? SYNC_STATUS_ROW_HEIGHT : 0);
  }

  /**
   * 自绘顶栏渐变模糊层进度更新器 + 校准（四页签同款）：onDidScroll /
   * onScrollStop 命令式驱动 opacity（不标 @State，滚动高频回调零重建）；
   * yOffset 0 → TITLE_BLUR_END_VP 线性映射 0 → 1（updater 内截断，
   * 边缘回弹负偏移归零 = 死区）。
   */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.scroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  /** 是否有任何可展示的列表内容（勾选行或历史状态，决定状态行 / 让位量） */
  private hasListContent(): boolean {
    return this.rows.length > 0 || this.states.length > 0;
  }

  /** 列表滚动控制器 */
  private scroller: Scroller = new Scroller();
  /** 「立即同步」按钮沉浸光感材质修饰器：26+ 生效，低版本 no-op 显实色兜底 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 子页转场横移量：常驻 '0%'，转场代理按 push/pop 临时改写 */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    // 挂载前先存当前偏移对应的进度（updater 未挂载只存值，
    // 挂载时 initializeModifier 补上），防「已滚过再进页」首帧缺模糊。
    this.syncTopBlurProgress();
    this.refreshFromStore();
    this.checkLogin();
    // 拉收藏夹列表（登录态下）：未同步过的夹也要展示出来供勾选
    this.fetchFolders();
  }

  aboutToDisappear(): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut，与 FollowsPage 同款。
   */
  private navTransitionDelegate(op: NavigationOperation,
    isEnter: boolean): Array<NavDestinationTransition> | undefined {
    if (op === NavigationOperation.PUSH && isEnter) {
      this.navTransX = '100%';
      const enter: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '0%';
        }
      };
      const transitions: Array<NavDestinationTransition> = [enter];
      return transitions;
    }
    if (op === NavigationOperation.POP && !isEnter) {
      const exit: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '100%';
        }
      };
      const transitions: Array<NavDestinationTransition> = [exit];
      return transitions;
    }
    return undefined;
  }

  /** 从持久化读同步状态列表 + 最近同步时间（纯本地，不发网络） */
  private refreshFromStore(): void {
    this.states = loadFavSyncStates();
    this.syncing = FavSyncManager.getInstance().isRunning();
    let latest: number = 0;
    for (let i = 0; i < this.states.length; i++) {
      if (this.states[i].lastSyncAt > latest) {
        latest = this.states[i].lastSyncAt;
      }
    }
    this.lastSyncAt = latest;
  }

  /** 登录态自检：未登录渲染引导空态 */
  private checkLogin(): void {
    const user: LoginUser | null = getLoginUser();
    this.needLogin = user === null;
  }

  /**
   * 拉取服务端收藏夹列表并合并成展示行（勾选同步）。
   * 只在登录态下发请求；失败置 foldersError（UI 展示重试），rows 保留旧值
   * （上次成功拉到的列表不作废，避免一次网络抖动把已勾选的列表清掉）。
   */
  private fetchFolders(): void {
    const user: LoginUser | null = getLoginUser();
    if (user === null) {
      this.needLogin = true;
      this.rows = [];
      this.foldersError = '';
      return;
    }
    this.foldersLoading = true;
    this.foldersError = '';
    getFavoriteFolders(user.mid)
      .then((r: FavoriteFoldersResult): void => {
        const list: FavoriteFolder[] = r && r.list ? r.list : [];
        const out: FavRowItem[] = [];
        for (let i = 0; i < list.length; i++) {
          const f: FavoriteFolder = list[i];
          out.push({
            mediaId: f.id,
            title: f.title,
            mediaCount: f.mediaCount,
            selected: isFolderSelected(f.id),
            twoway: isFolderTwoway(f.id),
            state: getFavSyncState(f.id)
          });
        }
        this.rows = out;
        this.foldersLoading = false;
      })
      .catch((e: ESObject): void => {
        this.foldersLoading = false;
        this.foldersError = e instanceof Error ? e.message : JSON.stringify(e);
        console.warn(`fav sync page: fetchFolders failed: ${this.foldersError}`);
      });
  }

  /** 同步结束后刷新各行的上次同步状态（标题/条数/徽标实时跟上本轮结果） */
  private refreshRowStates(): void {
    if (this.rows.length === 0) {
      return;
    }
    const refreshed: FavRowItem[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const r: FavRowItem = this.rows[i];
      refreshed.push({
        mediaId: r.mediaId,
        title: r.title,
        mediaCount: r.mediaCount,
        selected: r.selected,
        twoway: r.twoway,
        state: getFavSyncState(r.mediaId)
      });
    }
    this.rows = refreshed;
  }

  /**
   * 勾选/取消勾选一个收藏夹（勾选即同步）：
   * 勾选 → 持久化 + 行内更新 + 自动触发一轮同步（正在同步时挂 pending，
   * 本轮跑完自动补跑覆盖新勾的夹）；取消 → 仅持久化 + 行内更新，不触发。
   */
  private onRowCheckToggled(mediaId: number): void {
    const next: boolean = !isFolderSelected(mediaId);
    setFolderSelected(mediaId, next);
    this.updateRow(mediaId, (r: FavRowItem): FavRowItem => {
      return {
        mediaId: r.mediaId,
        title: r.title,
        mediaCount: r.mediaCount,
        selected: next,
        twoway: r.twoway,
        state: r.state
      };
    });
    if (!next) {
      return;
    }
    const mgr: FavSyncManager = FavSyncManager.getInstance();
    if (mgr.isRunning()) {
      // 正在同步：记 pending，跑完自动补一轮（覆盖新勾选的收藏夹）
      mgr.syncAll('check');
      return;
    }
    this.startSync();
  }

  /** 滑块切换同步方向：持久化 + 行内更新（不触发同步；积压补推由实时冲刷 / 下轮自理） */
  private onRowTwowayToggled(mediaId: number): void {
    const next: boolean = !isFolderTwoway(mediaId);
    setFolderTwoway(mediaId, next);
    this.updateRow(mediaId, (r: FavRowItem): FavRowItem => {
      return {
        mediaId: r.mediaId,
        title: r.title,
        mediaCount: r.mediaCount,
        selected: r.selected,
        twoway: next,
        state: r.state
      };
    });
  }

  /** 所有可见收藏夹是否都已勾选（空列表返回 false——按钮此时不渲染） */
  private isAllRowsSelected(): boolean {
    if (this.rows.length === 0) {
      return false;
    }
    for (let i = 0; i < this.rows.length; i++) {
      if (!this.rows[i].selected) {
        return false;
      }
    }
    return true;
  }

  /**
   * 全选/全不选所有**可见**收藏夹：批量持久化（一次落盘）+ 整表刷新。
   * 只改勾选态，不自动触发同步（用户需再点「立即同步」——与单夹「勾选即同步」
   * 语义有意不同：批量操作的影响面大，交给用户显式确认）。
   * 全不选后点「立即同步」由 startSync 既有校验拦下（「请先勾选要同步的收藏夹」）。
   * 同步进行中不禁用：管理器每轮开始快照一次勾选集合，中途改不影响本轮。
   * 仅作用于当前列表里的夹；不在列表中的历史「未勾选」记录保持原样（不可见即不操作）。
   */
  private onToggleAllRows(): void {
    const selectAll: boolean = !this.isAllRowsSelected();
    const ids: number[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      ids.push(this.rows[i].mediaId);
    }
    setAllFoldersSelected(ids, selectAll);
    const refreshed: FavRowItem[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const r: FavRowItem = this.rows[i];
      refreshed.push({
        mediaId: r.mediaId,
        title: r.title,
        mediaCount: r.mediaCount,
        selected: selectAll,
        twoway: r.twoway,
        state: r.state
      });
    }
    this.rows = refreshed;
    if (selectAll) {
      // 与单夹勾选「自动开跑」不同，这里给一句指路提示，避免用户以为全选即同步
      this.toast('已全选，点「立即同步」开始同步', 2000);
    }
  }

  /** 按 mediaId 原位替换一行（其余行保持引用不变） */
  private updateRow(mediaId: number, replacer: (r: FavRowItem) => FavRowItem): void {
    const updated: FavRowItem[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const r: FavRowItem = this.rows[i];
      updated.push(r.mediaId === mediaId ? replacer(r) : r);
    }
    this.rows = updated;
  }

  private onLoginRevChanged(): void {
    const user: LoginUser | null = getLoginUser();
    if (user === null) {
      // 退出登录：清空列表，回登录引导态
      this.needLogin = true;
      this.states = [];
      this.rows = [];
      this.foldersError = '';
      this.lastSyncAt = 0;
      return;
    }
    this.needLogin = false;
    this.refreshFromStore();
    // 登录 / 登录态变化 → 重拉收藏夹列表（换号后夹列表完全不同）
    this.fetchFolders();
  }

  private onFavSyncRevChanged(): void {
    const wasSyncing: boolean = this.syncing;
    this.refreshFromStore();
    // 行内徽标 / 副题跟上本轮结果（勾选行才有，states 兜底列表走 refreshFromStore）
    this.refreshRowStates();
    // 由「进行中」翻转为「已结束」的这一次，给一句结果提示
    if (wasSyncing && !this.syncing) {
      this.announceDone();
    }
  }

  /** 同步结束时把上一轮汇总转成一句话（只在真正跑完那一刻调用） */
  private announceDone(): void {
    const s: FavSyncSummary | null = FavSyncManager.getInstance().getLastSummary();
    if (s === null) {
      return;
    }
    if (s.needLogin) {
      this.toast('登录已失效，请重新登录后再同步', 2400);
      return;
    }
    if (!s.foldersOk) {
      this.toast(`收藏夹列表拉取失败：${s.reason}`, 2600);
      return;
    }
    if (s.total === 0) {
      // 管理器在「一个夹都没勾」时带 reason；没 reason 才是真的没有收藏夹
      this.toast(s.reason.length > 0 ? s.reason : '还没有自己创建的收藏夹', 2400);
      return;
    }
    const parts: string[] = [];
    if (s.pushNeedLogin) {
      parts.push('写回未完成：请重新登录');
    }
    parts.push(`${s.okCount} 个已同步`);
    if (s.partialCount > 0) {
      parts.push(`${s.partialCount} 个未拉全`);
    }
    if (s.failedCount > 0) {
      parts.push(`${s.failedCount} 个失败`);
    }
    if (s.added > 0) {
      parts.push(`新增 ${s.added} 首`);
    }
    if (s.removed > 0) {
      parts.push(`移除 ${s.removed} 首`);
    }
    if (s.pushed > 0) {
      parts.push(`写回 B 站 ${s.pushed} 首`);
    }
    if (s.pushDropped > 0) {
      parts.push(`写回失败 ${s.pushDropped} 首`);
    }
    if (s.pushPending > 0) {
      parts.push(`${s.pushPending} 首待补推`);
    }
    this.toast(parts.join(' · '), 2400);
  }

  /** 「立即同步」：冷却 + 触发管理器（fire-and-forget，结果经 STORE_FAV_SYNC_REV 回流） */
  private startSync(): void {
    if (this.retryLocked) {
      return;
    }
    const mgr: FavSyncManager = FavSyncManager.getInstance();
    if (mgr.isRunning()) {
      this.toast('正在同步中，请稍候', 1800);
      return;
    }
    const user: LoginUser | null = getLoginUser();
    if (user === null) {
      this.needLogin = true;
      return;
    }
    // 勾选校验：列表已拉到且一个都没勾 → 拦下（列表没拉到时不拦，
    // 管理器按持久化的勾选状态过滤，兜底全选）
    if (this.rows.length > 0) {
      let anySelected: boolean = false;
      for (let i = 0; i < this.rows.length; i++) {
        if (this.rows[i].selected) {
          anySelected = true;
          break;
        }
      }
      if (!anySelected) {
        this.toast('请先勾选要同步的收藏夹', 2000);
        return;
      }
    }
    this.retryLocked = true;
    this.retryCooling = true;
    this.retryTimer = setTimeout((): void => {
      this.retryLocked = false;
      this.retryCooling = false;
      this.retryTimer = -1;
    }, RETRY_COOLDOWN_MS);
    // 立刻进入进行态（不等 @Watch 回流，按钮即时变「同步中」）
    this.syncing = true;
    mgr.syncAll('manual');
  }

  /** 单夹结果 → 徽标文案 */
  private resultLabel(result: string): string {
    if (result === FAV_SYNC_FAILED) {
      return '失败';
    }
    if (result === FAV_SYNC_PARTIAL) {
      return '未拉全';
    }
    return '已同步';
  }

  /** 单夹结果 → 徽标颜色（ok 绿 / partial 橙 / failed 红） */
  private resultColor(result: string): Resource {
    if (result === FAV_SYNC_FAILED) {
      return $r('app.color.state_error');
    }
    if (result === FAV_SYNC_PARTIAL) {
      return $r('app.color.state_warning');
    }
    return $r('app.color.state_success');
  }

  /** 行副标题：条数（+ 上次同步时钟 + 失败原因） */
  private rowSubtitle(s: FavFolderSyncState): string {
    let countText: string;
    if (s.playlistId.length > 0) {
      /**
       * 「没拉全 + 0 首」几乎一定是首轮失败的假象（镜像里其实已经有歌）——
       * 不显示误导性的「0 首」，否则用户会以为收藏夹空了。
       */
      countText = (s.lastItemCount === 0 && s.lastResult !== FAV_SYNC_OK) ? '条数未知' : `${s.lastItemCount} 首`;
    } else {
      countText = s.lastResult === FAV_SYNC_OK ? '空收藏夹' : '未建成镜像';
    }
    const parts: string[] = [countText];
    const timeText: string = formatClock(s.lastSyncAt);
    if (timeText.length > 0) {
      parts.push(timeText);
    }
    // 失败原因一并展示：仅有「未拉全/失败」徽标时，用户无从分辨风控还是网络
    if (s.lastResult !== FAV_SYNC_OK && s.lastReason.length > 0) {
      parts.push(s.lastReason);
    }
    return parts.join(' · ');
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /**
   * 标题行内容（titleBar 的 stackBuilder 承载，可用空间仅 56vp，不得超出——
   * 官方约束「不要超出标题栏的可用空间」）：「收藏夹同步」标题（返回键为 HDS 默认键）。
   * 材质与滚动模糊由 HDS titleBar 负责。
   */
  @Builder
  syncBar() {
    NavTitleRow({ title: '收藏夹同步' })
  }

  /**
   * 标题行下方自定义区（titleBar 的 bottomBuilder 承载，仅有列表时配置）：
   * 「上次同步 10:23 · 3 个收藏夹」状态行（定高 SYNC_STATUS_ROW_HEIGHT）。
   * ⚠️ bottomBuilder 高度不自适应（官方约束），由 titleBar 参数显式给定。
   */
  @Builder
  syncStatusRow() {
    Row() {
      Blank()
        .layoutWeight(1)
      Text(this.syncing
        ? '同步中…'
        : `上次同步 ${formatClock(this.lastSyncAt)} · ${this.rows.length > 0 ? this.rows.length : this.states.length} 个收藏夹`)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height(SYNC_STATUS_ROW_HEIGHT)
    .padding({ left: 16, right: 16, top: 4, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 标题行收窄容器（平板模式宽度适配）：HDS titleBar 的 stackBuilder
   * 横跨目的地整列全宽，而本页条目内容列被 constraintSize 收窄居中 —— 大屏上
   * 标题行会贴到整列左缘、与居中条目错位。外层 Row 居中 + 内层 Column
   * constraintSize（上限与本页内容列完全同口径），标题行与条目列同宽对齐；
   * 两侧空白区 hitTestBehavior(Transparent) 穿透点击。
   * sm 回退 600（窗口 <600vp）天然无操作，手机零变化。
   */
  @Builder
  syncBarNarrow() {
    Row() {
      Column() {
        this.syncBar()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * 「上次同步 …」状态行收窄容器（平板模式宽度适配）：同 syncBarNarrow
   * 口径 —— bottomBuilder 也横跨整列全宽，收窄后状态行与本页条目列同宽对齐；
   * bottomBuilder 显式高度（SYNC_STATUS_ROW_HEIGHT）不动。sm 天然无操作。
   */
  @Builder
  syncStatusRowNarrow() {
    Row() {
      Column() {
        this.syncStatusRow()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 「立即同步」按钮行（44vp 触达；进行中 / 冷却中禁用） */
  @Builder
  syncButtonRow() {
    Row() {
      Button(this.syncing ? '同步中…' : (this.retryCooling ? '请稍候…' : '立即同步'),
        { type: ButtonType.Normal })
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .height(44)
        .layoutWeight(1)
        .borderRadius(BUTTON_RADIUS_VP)
        .backgroundColor(this.themePrimary)
        .fontColor(this.themeOn)
        .attributeModifier(this.buttonMaterial)
        .enabled(!this.syncing && !this.retryCooling)
        .opacity((this.syncing || this.retryCooling) ? 0.5 : 1)
        .onClick((): void => {
          this.startSync();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 4 })
    .alignItems(VerticalAlign.Center)
  }

  /** 一个收藏夹行：名称 + 条数/时间 + 结果徽标 */
  @Builder
  folderRow(s: FavFolderSyncState) {
    Row() {
      Column() {
        Text(s.title)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.rowSubtitle(s))
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.resultLabel(s.lastResult))
        .fontSize(11)
        .fontColor(this.resultColor(s.lastResult))
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(4)
        .backgroundColor(this.themeSurface)
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  /** 勾选行副标题：没同步过的夹显示服务端条数；同步过复用状态副题 */
  private rowSubtitleFor(r: FavRowItem): string {
    if (r.state !== null) {
      return this.rowSubtitle(r.state);
    }
    return `${r.mediaCount} 首 · 未同步`;
  }

  /**
   * 一个收藏夹**勾选行**（手动选择性同步，带方向滑块）：
   * 整行可点切换勾选（触达 ≥ 44vp）；Checkbox 做纯视觉（HitTestMode.None 不响应命中，
   * 否则点勾选框会同时触发自身 onChange 与行 onClick，一次点击翻转两次等于没翻）。
   * 行尾「单向/双向」滑块组（Column onClick 独立消费点击，不冒泡到行勾选；
   * Toggle 同样纯视觉，状态由 r.twoway 驱动）。
   * 未同步过的夹（state=null）不渲染结果徽标。
   */
  @Builder
  selectableFolderRow(r: FavRowItem) {
    Row() {
      Checkbox()
        .select(r.selected)
        .selectedColor(this.themePrimary)
        .width(22)
        .height(22)
        .hitTestBehavior(HitTestMode.None)
      Column() {
        Text(r.title)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.rowSubtitleFor(r))
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })

      if (r.state !== null) {
        Text(this.resultLabel(r.state.lastResult))
          .fontSize(11)
          .fontColor(this.resultColor(r.state.lastResult))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(4)
          .backgroundColor(this.themeSurface)
          .hitTestBehavior(HitTestMode.None)
          .margin({ left: 8 })
      }

      Column() {
        Text(r.twoway ? '双向' : '单向')
          .fontSize(10)
          .fontColor(r.twoway ? this.themePrimary : $r('app.color.text_tertiary'))
        Toggle({ type: ToggleType.Switch, isOn: r.twoway })
          .selectedColor(this.themePrimary)
          .width(36)
          .height(20)
          .hitTestBehavior(HitTestMode.None)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Center)
      .margin({ left: 10 })
      .onClick((): void => {
        this.onRowTwowayToggled(r.mediaId);
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.onRowCheckToggled(r.mediaId);
    })
  }

  /**
   * 「收藏夹」区块标题行：原 SectionHeader 文案 + 右挂「全选/全不选」主题色
   * 文本按钮（44vp 触达，同本页「重试」按钮规格）。按钮随整表勾选态互为切换；
   * 列表为空（拉取失败/无收藏夹）不渲染按钮。
   * 外层右 padding 4 + 按钮右 padding 16 = 20，文案右缘与原 SectionHeader 对齐。
   */
  @Builder
  folderSectionHeader() {
    Row() {
      Text('收藏夹')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Blank()
      if (this.rows.length > 0) {
        Text(this.isAllRowsSelected() ? '全不选' : '全选')
          .fontSize(13)
          .fontColor(this.themePrimary)
          .height(44)
          .padding({ left: 16, right: 16 })
          .onClick((): void => {
            this.onToggleAllRows();
          })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 4, top: 20, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Column() {
          if (this.needLogin) {
            // 登录引导空态（本页无独立登录入口，与 FollowsPage 同款）
            Column() {
              Text('登录后才能同步收藏夹')
                .fontSize(16)
                .fontColor($r('app.color.text_secondary'))
              Text('与 B 站网页版共用同一份登录态，凭据只保存在本机')
                .fontSize(13)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ top: 8 })
              Button('去登录', { type: ButtonType.Normal })
                .fontSize(13)
                .height(32)
                .borderRadius(BUTTON_RADIUS_VP)
                .backgroundColor(this.themePrimary)
                .fontColor(this.themeOn)
                .attributeModifier(this.buttonMaterial)
                .margin({ top: 20 })
                .onClick((): void => {
                  NavStackHolder.stack.pushPathByName('Login', undefined);
                })
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: this.barTotalHeight() })
          } else {
            List({ scroller: this.scroller }) {
              // 顶部占位（官方沉浸口径）：开启沉浸后内容向上穿透进标题栏区域，
              // 让位不能加在 List 外层（否则内容被裁在栏底缘之下、材质无内容可采样），
              // 必须在内容内部做占位。高度 = barTotalHeight()（safeTop + 56 + 状态行 28）：
              // 静止位不变，滚动时内容真正从材质下穿过。
              ListItem() {
                // Blank 只能嵌在 Row/Column/Flex 内（编译器 10905201），ListItem 直下用定高 Row。
                Row()
                  .width('100%')
                  .height(this.barTotalHeight())
              }
              ListItem() {
                this.syncButtonRow()
              }
              // 同步方向说明（按夹可选单向/双向）：滑块切方向、
              // 勾选即同步、双向写回与补推、双向夹曲目限制，都要在页面上讲清楚。
              ListItem() {
                Row() {
                  InsetCard() {
                    Column() {
                      Text('同步方向：每个收藏夹可选「单向 / 双向」')
                        .fontSize(13)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.text_primary'))
                        .width('100%')
                      Text('「单向」仅 B 站 → 本地，本地改动不写回；「双向」会把本地加歌/移除实时写回 B 站（移除即取消收藏），失败自动在下次同步前补推。勾选一个收藏夹即开始同步。双向收藏夹不支持添加非 B 站曲目。')
                        .fontSize(11)
                        .fontColor($r('app.color.text_tertiary'))
                        .width('100%')
                        .margin({ top: 3 })
                        .lineHeight(17)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                  }
                }
                .width('100%')
                .padding({ top: 8 })
              }
              ListItem() {
                this.folderSectionHeader()
              }
              if (this.foldersLoading && this.rows.length === 0) {
                ListItem() {
                  Column() {
                    Text('正在拉取收藏夹列表…')
                      .fontSize(16)
                      .fontColor($r('app.color.text_secondary'))
                    Text('列表用于勾选要同步的收藏夹，请稍候')
                      .fontSize(13)
                      .fontColor($r('app.color.text_tertiary'))
                      .margin({ top: 8 })
                      .textAlign(TextAlign.Center)
                  }
                  .width('100%')
                  .padding({ top: 40, bottom: 40, left: 32, right: 32 })
                  .alignItems(HorizontalAlign.Center)
                }
              } else if (this.rows.length > 0) {
                // 勾选列表（手动选择性同步）：进页拉服务端列表，整行可点切换勾选
                ListItem() {
                  InsetCard() {
                    // 横屏宽屏：卡片内行改 Grid 两列
                    //（columnsTemplate '1fr 1fr'，去 CardDivider —— 分隔线在两列
                    // 下没有连续行可分）；竖屏维持单列 + 分隔线。
                    if (this.isTwoCol()) {
                      Grid() {
                        ForEach(this.rows, (r: FavRowItem): void => {
                          GridItem() {
                            this.selectableFolderRow(r)
                          }
                        }, (r: FavRowItem): string => `${r.mediaId}_${r.selected}_${r.twoway}_${
                          r.state ? `${r.state.lastResult}_${r.state.lastItemCount}_${r.state.lastSyncAt}` : 'none'}`)
                      }
                      .columnsTemplate('1fr 1fr')
                      .columnsGap(TWO_COL_GAP_VP)
                    } else {
                      ForEach(this.rows, (r: FavRowItem, index: number): void => {
                        if (index > 0) {
                          CardDivider()
                        }
                        this.selectableFolderRow(r)
                      }, (r: FavRowItem): string => `${r.mediaId}_${r.selected}_${r.twoway}_${
                        r.state ? `${r.state.lastResult}_${r.state.lastItemCount}_${r.state.lastSyncAt}` : 'none'}`)
                    }
                  }
                }
              } else {
                // 列表没拉到（失败 / 网络未回）：错误提示 + 重试；states 作为历史结果兜底展示
                if (this.foldersError.length > 0) {
                  ListItem() {
                    Column() {
                      Text('收藏夹列表拉取失败')
                        .fontSize(16)
                        .fontColor($r('app.color.text_secondary'))
                      Text(this.foldersError)
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                        .maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 8 })
                        .textAlign(TextAlign.Center)
                      Text('重试')
                        .fontSize(13)
                        .fontColor(this.themePrimary)
                        .height(44)
                        .padding({ left: 16, right: 16 })
                        .margin({ top: 4 })
                        .onClick((): void => {
                          this.fetchFolders();
                        })
                    }
                    .width('100%')
                    .padding({ top: 32, bottom: 16, left: 32, right: 32 })
                    .alignItems(HorizontalAlign.Center)
                  }
                }
                if (this.states.length > 0) {
                  ListItem() {
                    InsetCard() {
                      // 横屏宽屏：同勾选卡片，Grid 两列去分隔线
                      if (this.isTwoCol()) {
                        Grid() {
                          ForEach(this.states, (s: FavFolderSyncState): void => {
                            GridItem() {
                              this.folderRow(s)
                            }
                          }, (s: FavFolderSyncState): string => `${s.mediaId}_${s.lastResult}_${s.lastItemCount}_${s.lastSyncAt}`)
                        }
                        .columnsTemplate('1fr 1fr')
                        .columnsGap(TWO_COL_GAP_VP)
                      } else {
                        ForEach(this.states, (s: FavFolderSyncState, index: number): void => {
                          if (index > 0) {
                            CardDivider()
                          }
                          this.folderRow(s)
                        }, (s: FavFolderSyncState): string => `${s.mediaId}_${s.lastResult}_${s.lastItemCount}_${s.lastSyncAt}`)
                      }
                    }
                  }
                } else if (this.foldersError.length === 0) {
                  ListItem() {
                    Column() {
                      Text(this.syncing ? '正在同步收藏夹…' : '还没有收藏夹')
                        .fontSize(16)
                        .fontColor($r('app.color.text_secondary'))
                      Text(this.syncing
                        ? '首次同步会逐个拉取收藏夹内容，请稍候'
                        : '你在 B 站创建的收藏夹会显示在这里；点上方「立即同步」镜像到本地')
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                        .margin({ top: 8 })
                        .textAlign(TextAlign.Center)
                    }
                    .width('100%')
                    .padding({ top: 40, bottom: 40, left: 32, right: 32 })
                    .alignItems(HorizontalAlign.Center)
                  }
                }
              }
            }
            .layoutWeight(1)
            .width('100%')
            .edgeEffect(EdgeEffect.Spring)
            .cachedCount(8)
            // 末条避让二级页悬浮播放条（SubPagePlayBar，恒展开整行）+ 底部手势区：
            // 与 SettingsPage / PlaylistsPage 同口径（CONTENT_END_OFFSET + safeBottom）。
            .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
            // 逐帧驱动自绘渐变模糊层（onDidScroll 在偏移已应用
            // 后回调，onWillScroll 是应用前，快滑时差一帧会让模糊层滞后一跳）。
            .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
              this.syncTopBlurProgress();
            })
            .onScrollStop((): void => {
              // Idle 校准终态：兜住 Fling 期丢帧 / 死区过滤累计的偏差。
              this.syncTopBlurProgress();
            })
            // 标题栏让位由首个 ListItem 占位负责（见 List 首项），List 上不加 padding。
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
        // 大屏适配：内容列收窄居中；横屏宽屏两列时上限放宽到 840（CONTENT_MAX_WIDTH_TWOCOL）
        .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })

        // 顶栏渐变模糊层：盖内容列之上（z 序低于 HDS
        // titleBar，状态行属标题栏 bottomBuilder、随整栏一起盖），进度由列表
        // onDidScroll/onScrollStop 经 topBlurUpdater 命令式驱动。
        TopGradientBlurOverlay({
          barHeightVp: this.barTotalHeight(),
          updater: this.topBlurUpdater
        })
      }
    }
    // HDS 沉浸光感标题栏（FollowsPage / RecentPage 同款）：
    // avoidLayoutSafeArea 挡状态栏重叠；enableComponentSafeArea 会杀材质，禁用。
    // 平板模式宽度适配：stackBuilder / bottomBuilder 均走收窄容器
    //（syncBarNarrow / syncStatusRowNarrow），标题行与状态行和条目列同宽对齐。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        // 标题行（stackBuilder，可用空间 56vp）：「收藏夹同步」标题（返回键为 HDS 默认键）
        //（收窄容器内）
        stackBuilder: (): void => {
          this.syncBarNarrow();
        },
        // 标题行下方自定义区（bottomBuilder 承载，仅有列表时配置，收窄容器内）：
        // 「上次同步 …」状态行。⚠️ bottomBuilder 高度不自适应，由参数显式给定。
        bottomBuilder: this.hasListContent() ? {
          builder: (): void => {
            this.syncStatusRowNarrow();
          },
          height: SYNC_STATUS_ROW_HEIGHT,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        } : undefined
      }
    })
    // 返回键：使用 HDS 默认返回键（"<" 系统样式，位置由 HDS 管理以避开状态栏）。
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页列表交给 HDS 联动
    .bindToScrollable([this.scroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 系统返回拦截：播放页 overlay 打开时
    // 吞掉返回并发收起请求（留在本页），否则走默认 pop —— 详见 utils/SubPageBackPress。
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让：目的地级声明布局扩展进系统安全区（官方组件级沉浸
    // 口径，faqs-arkui-1095 场景三同款）；窗口全屏下页面级为既成事实，此处显式化
    // 并接管组件级 safeAreaPadding。内容层避让由 contentStartOffset / plain padding 自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function FavSyncPageBuilder(): void {
  FavSyncPage()
}


/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const FavSyncPageWrapped: WrappedBuilder<[]> = wrapBuilder(FavSyncPageBuilder);

