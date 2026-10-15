/**
 * 收藏夹同步页（B 站收藏夹 → 本地歌单镜像，2026-10-13）。
 *
 * 入口：「设置 → 账户 → 收藏夹同步」（路由名仍为 'CloudSync'，历史沿用）。
 *
 * 数据来源：`service/FavSyncManager`（编排一轮同步）+ `service/FavSyncStore`
 * （每夹上次同步结果）。本页**只负责触发与展示**，不直接调网络 / 不碰本地歌单，
 * 一切写操作都在管理器里完成，避免与自动同步（登录后）并发写同一份数据。
 *
 * 订阅：
 *   · `STORE_LOGIN_REV`  —— 登录/登出后重查登录态与列表
 *   · `STORE_FAV_SYNC_REV` —— 每轮同步开始/结束递增，@Watch 里刷新 syncing 与列表
 *   · `STORE_SAFE_TOP|BOTTOM` —— 自绘沉浸顶栏让位 / 底部安全区
 *
 * 状态机：needLogin / syncing / idle（有列表，无在跑）/（列表空 = 空态）。
 * 单夹结果徽标三档：ok（state_success）/ partial（state_warning）/ failed（state_error）。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，stackBuilder 承载
 * 返回行 + 标题，与 FollowsPage / RecentPage 同构）：avoidLayoutSafeArea 挡状态栏
 * 重叠，材质与滚动模糊由 HDS 统一渲染（样式见 HdsTitleBarStyle）；
 * bottomBuilder 承载「上次同步 …」状态行（仅有列表时渲染，定高 28）。
 *
 * ⚠️ 同步是**双向**的（B 站取消收藏 → 本地移除），但只有当某收藏夹在服务端被
 * **完整**拉取成功时才允许删本地 —— 本页在说明卡里如实告知用户这一安全边界。
 */

import { FavSyncManager, FavSyncSummary, FavPushSummary } from '../service/FavSyncManager';
import { FavFolderSyncState, FAV_SYNC_OK, FAV_SYNC_PARTIAL, FAV_SYNC_FAILED, loadFavSyncStates } from '../service/FavSyncStore';
import { getLoginUser, LoginUser } from '../service/LoginStore';
import { NavStackHolder } from '../service/NavStackHolder';
import { showAppToast } from '../components/AppToast';
import { InsetCard, CardDivider, SectionHeader } from '../components/InsetCardGroup';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier
} from '../utils/HeaderBarMaterial';
import { HdsNavDestination, BottomBuilderShowType } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import {
  STORE_LOGIN_REV,
  STORE_FAV_SYNC_REV,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE,
  STORE_THEME_ON
} from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { NAV_TRANSITION_MS, BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';

/** 「立即同步」冷却（ms）：收藏夹接口对高频请求敏感，连点只会继续被拒 */
const RETRY_COOLDOWN_MS: number = 4000;

/**
 * 标题栏状态行（「上次同步 10:23 · 3 个收藏夹」）固定高：
 * padding 4/8 + 文本 11fp ≈ 28。bottomBuilder 高度不自适应（官方约束），
 * 必须与行内容定高一致。
 */
const SYNC_STATUS_ROW_HEIGHT: number = 28;

/**
 * 顶栏滚动模糊时机（基准口径 = 最近播放页）：首条内容自静止位上移 30vp 起雾
 * → 80vp 满显影。内容侧 padding 让位（F = raw），两参直接生效，无需补偿。
 */
const FAVSYNC_BLUR_START_VP: number = 30;
const FAVSYNC_BLUR_END_VP: number = 80;

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
  /** 最近一次同步时间（ms 时间戳，0 = 从未同步） */
  @State lastSyncAt: number = 0;
  /** 待推送到 B 站的改动条数（本地选过删/加但还没发出去，含失败待重试的） */
  @State pendingCount: number = 0;
  /** 同步冷却中：按钮禁用 */
  @State retryCooling: boolean = false;
  private retryLocked: boolean = false;
  private retryTimer: number = -1;
  /** 本轮是「只推送」的轻量轮（用于结束时给对应的结果提示） */
  private pushRoundActive: boolean = false;

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

  /** HDS 标题栏整体让位量（vp）= safeTop + 标题行 56 + 状态行 28（有列表时） */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT
      + (this.states.length > 0 ? SYNC_STATUS_ROW_HEIGHT : 0);
  }

  /** 列表滚动控制器 */
  private scroller: Scroller = new Scroller();
  /** 「立即同步」按钮沉浸光感材质修饰器：26+ 生效，低版本 no-op 显实色兜底 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 子页转场横移量：常驻 '0%'，转场代理按 push/pop 临时改写 */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    this.refreshFromStore();
    this.checkLogin();
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

  /** 从持久化读同步状态列表 + 最近同步时间 + 待推送条数（纯本地，不发网络） */
  private refreshFromStore(): void {
    this.states = loadFavSyncStates();
    this.syncing = FavSyncManager.getInstance().isRunning();
    this.pendingCount = FavSyncManager.getInstance().pendingCount();
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

  private onLoginRevChanged(): void {
    const user: LoginUser | null = getLoginUser();
    if (user === null) {
      // 退出登录：清空列表，回登录引导态
      this.needLogin = true;
      this.states = [];
      this.lastSyncAt = 0;
      return;
    }
    this.needLogin = false;
    this.refreshFromStore();
  }

  private onFavSyncRevChanged(): void {
    const wasSyncing: boolean = this.syncing;
    this.refreshFromStore();
    // 由「进行中」翻转为「已结束」的这一次，给一句结果提示
    if (wasSyncing && !this.syncing) {
      if (this.pushRoundActive) {
        this.pushRoundActive = false;
        this.announcePushDone();
      } else {
        this.announceDone();
      }
    }
  }

  /** 只推送轮结束时的一句话（与完整同步的结果提示区分开） */
  private announcePushDone(): void {
    const p: FavPushSummary | null = FavSyncManager.getInstance().getLastPushSummary();
    if (p === null) {
      return;
    }
    if (p.needLogin) {
      this.toast('登录已失效，请重新登录后再同步', 2400);
      return;
    }
    if (p.blocked) {
      this.toast(`有待同步的改动没能推送：${p.reason}`, 2600);
      return;
    }
    if (p.pendingLeft > 0) {
      this.toast(`已同步 ${p.pushed} 条，仍有 ${p.pendingLeft} 条待同步`, 2400);
      return;
    }
    this.toast(p.pushed > 0 ? `已同步 ${p.pushed} 条改动到 B 站` : '没有待同步的改动', 2000);
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
      this.toast('还没有自己创建的收藏夹', 2000);
      return;
    }
    const parts: string[] = [];
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

  /**
   * 「重试」：只重放待推送队列（本地 → B 站），不做完整拉取。
   * 与「立即同步」区分开是因为：推送是用户已确认的本地意图，代价小、应当随时可补；
   * 而完整拉取会打一遍所有收藏夹接口（风控敏感），不适合让用户随手连点。
   */
  private startPushRetry(): void {
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
    this.pushRoundActive = true;
    this.syncing = true;
    mgr.pushOnly('manual');
    this.toast('正在重试待同步的改动…', 1800);
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

  /** 行副标题：条数（+ 上次同步时钟） */
  private rowSubtitle(s: FavFolderSyncState): string {
    const countText: string = s.playlistId.length > 0
      ? `${s.lastItemCount} 首`
      : (s.lastResult === FAV_SYNC_OK ? '空收藏夹' : '未建成镜像');
    const timeText: string = formatClock(s.lastSyncAt);
    return timeText.length > 0 ? `${countText} · ${timeText}` : countText;
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /**
   * 标题行内容（titleBar 的 stackBuilder 承载，可用空间仅 56vp，不得超出——
   * 官方约束「不要超出标题栏的可用空间」）：返回键 + 「收藏夹同步」标题。
   * 材质与滚动模糊由 HDS titleBar 负责。
   */
  @Builder
  syncBar() {
    Row() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(26)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .borderRadius(22)
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.press_overlay')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .accessibilityText('返回')
      .accessibilityLevel('yes')
      .onClick((): void => {
        NavStackHolder.stack.pop();
      })

      Text('收藏夹同步')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(NAV_TITLE_BAR_HEIGHT)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
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
        : `上次同步 ${formatClock(this.lastSyncAt)} · ${this.states.length} 个收藏夹`)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height(SYNC_STATUS_ROW_HEIGHT)
    .padding({ left: 16, right: 16, top: 4, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  /** 说明卡：同步范围 + 双向同步的安全边界（如实告知，避免用户误以为会丢歌） */
  @Builder
  infoCard() {
    Column() {
      Text('同步范围')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ bottom: 6 })
      Text('只同步你自己创建的收藏夹，每个收藏夹会镜像成本地歌单，名称形如「收藏夹名（收藏夹）」。')
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .lineHeight(18)
      CardDivider()
      Text('双向同步 + 安全边界')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 12, bottom: 6 })
      Text('B 站取消收藏的曲目，本地镜像也会移除；但只有该收藏夹被完整拉取成功时才删除本地 —— 断网或被风控的那一轮只增不减，不会误删。')
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .lineHeight(18)
      Text('在本地对镜像歌单做的增删会同步回 B 站（需登录）。单个收藏夹超过 500 首时，只镜像最新的 500 首，且该收藏夹不做任何删除。')
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .lineHeight(18)
        .margin({ top: 12 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
  }

  /** 「N 条待同步」行：本地已改但还没成功推到 B 站的写操作，可手动重试 */
  @Builder
  pendingRow() {
    Row() {
      Column() {
        Text(`有 ${this.pendingCount} 条改动待同步到 B 站`)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text('离线或被限制时没能推送成功，可点右侧重试')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 触达铁律：视觉可以小，命中区必须 ≥ 44vp
      Row() {
        Text('重试')
          .fontSize(13)
          .fontColor(this.themePrimary)
      }
      .height(44)
      .padding({ left: 12, right: 12 })
      .justifyContent(FlexAlign.Center)
      .onClick((): void => {
        this.startPushRetry();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
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
                  NavStackHolder.stack.pushPath({ name: 'Login' });
                })
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: this.barTotalHeight() })
          } else {
            List({ scroller: this.scroller }) {
              // 顶部占位（官方沉浸口径）：开启沉浸后内容向上穿透进标题栏区域，
              // 让位不能加在 List 外层（否则内容被裁在栏底缘之下、材质无内容可采样），
              // 必须在内容内部做占位。高度 = barTotalHeight()（safeTop + 56 + 状态行 28），
              // 与旧 List 外层 padding 等值：静止位不变，滚动时内容真正从材质下穿过。
              ListItem() {
                // Blank 只能嵌在 Row/Column/Flex 内（编译器 10905201），ListItem 直下用定高 Row。
                Row()
                  .width('100%')
                  .height(this.barTotalHeight())
              }
              ListItem() {
                // ⚠️ 自定义组件带尾随构建块时不能链式挂属性（`InsetCard() {...}.margin()` 会
                // 被解析成两条语句 → 编译报错），故用外层 Row 承载上间距。
                Row() {
                  InsetCard() {
                    this.infoCard()
                  }
                }
                .width('100%')
                .padding({ top: 12 })
              }
              ListItem() {
                this.syncButtonRow()
              }
              if (this.pendingCount > 0) {
                ListItem() {
                  Row() {
                    InsetCard() {
                      this.pendingRow()
                    }
                  }
                  .width('100%')
                  .padding({ top: 8 })
                }
              }
              ListItem() {
                SectionHeader({ headerText: '收藏夹' })
              }
              if (this.states.length === 0) {
                ListItem() {
                  Column() {
                    Text(this.syncing ? '正在同步收藏夹…' : '还没有同步记录')
                      .fontSize(16)
                      .fontColor($r('app.color.text_secondary'))
                    Text(this.syncing
                      ? '首次同步会逐个拉取收藏夹内容，请稍候'
                      : '点上方「立即同步」，把你创建的收藏夹镜像到本地')
                      .fontSize(13)
                      .fontColor($r('app.color.text_tertiary'))
                      .margin({ top: 8 })
                      .textAlign(TextAlign.Center)
                  }
                  .width('100%')
                  .padding({ top: 40, bottom: 40, left: 32, right: 32 })
                  .alignItems(HorizontalAlign.Center)
                }
              } else {
                ListItem() {
                  InsetCard() {
                    ForEach(this.states, (s: FavFolderSyncState, index: number): void => {
                      if (index > 0) {
                        CardDivider()
                      }
                      this.folderRow(s)
                    }, (s: FavFolderSyncState): string => `${s.mediaId}_${s.lastResult}_${s.lastItemCount}_${s.lastSyncAt}`)
                  }
                }
              }
              ListItem() {
                Row()
                  .width('100%')
                  .height(this.safeBottom + 16)
              }
            }
            .layoutWeight(1)
            .width('100%')
            .edgeEffect(EdgeEffect.Spring)
            // 标题栏让位已内移为首个 ListItem 占位（见 List 首项），不在 List 上加 padding。
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
      }
    }
    // HDS 沉浸光感标题栏（FollowsPage / RecentPage 同款）：
    // avoidLayoutSafeArea 挡状态栏重叠；enableComponentSafeArea 会杀材质，禁用。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(FAVSYNC_BLUR_START_VP, FAVSYNC_BLUR_END_VP),
      content: {
        // 标题行（stackBuilder，可用空间 56vp）：返回键 + 「收藏夹同步」标题
        stackBuilder: (): void => {
          this.syncBar();
        },
        // 标题行下方自定义区（bottomBuilder 承载，仅有列表时配置）：
        // 「上次同步 …」状态行。⚠️ bottomBuilder 高度不自适应，由参数显式给定。
        bottomBuilder: this.states.length > 0 ? {
          builder: (): void => {
            this.syncStatusRow();
          },
          height: SYNC_STATUS_ROW_HEIGHT,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        } : undefined
      }
    })
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页列表交给 HDS 联动
    .bindToScrollable([this.scroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 内容避让（2026-10-14）：目的地级声明布局扩展进系统安全区（官方组件级沉浸
    // 口径，faqs-arkui-1095 场景三同款）；窗口全屏下页面级为既成事实，此处显式化
    // 并接管组件级 safeAreaPadding。内容层避让由 contentStartOffset / plain padding 自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}
