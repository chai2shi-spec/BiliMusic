/**
 * 我的关注页：登录用户的 B 站关注列表（「设置 → 账户 → 我的关注」）。
 *
 * 数据走 `/x/relation/followings`（查自己的关注必须带 SESSDATA，HttpUtil 登录后
 * 自动附加）；每页 50 条、`order=desc` 最新关注在前，滚动到底自动翻页。
 *
 * 本页**只读列表**：「订阅 UP 的投稿」这件事在 UP 主页（UpSpacePage）里完成 ——
 * 行点击跳过去，那边有完整的订阅 / 拉取新投稿机制；从那边返回后，「已订阅」
 * 徽标靠 STORE_LIBRARY_REV 版本号 @Watch 触发重灌刷新（订阅 = 本地新建歌单，
 * LibraryStore 会递增该版本号）。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，stackBuilder 承载
 * 标题 + 「共 N 人」计数行，与 RecentPage 同构；返回键为 HDS 默认键）。
 *
 * 未登录自检：设置页入口已拦截未登录，但路由仍可能被其他入口触达，
 * 页面自己再查一次登录态，未登录渲染登录引导空态而非「没数据」。
 */

import { FollowedUp, FollowingsData, getFollowings, BiliApiError } from '../api/BilibiliApi';
import { getPlaylistByUpMid } from '../service/LibraryStore';
import { getLoginUser, LoginUser } from '../service/LoginStore';
import { NavStackHolder } from '../service/NavStackHolder';
import { UpSpaceRouteParam } from '../service/NavRouteParams';
import { CoverImage } from '../components/CoverImage';
import { SkeletonTrackItem } from '../components/SkeletonTrackItem';
import { HdsNavDestination, BottomBuilderShowType } from '@kit.UIDesignKit';
import { Chip, ChipSize } from '@kit.ArkUI';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { showAppToast } from '../components/AppToast';
import { toThumbUrl } from '../utils/TextUtil';
import { ArrayDataSource } from '../utils/ArrayDataSource';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier
} from '../utils/HeaderBarMaterial';
import {
  STORE_LIBRARY_REV,
  STORE_LOGIN_REV,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE,
  STORE_THEME_ON
} from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import {
  PairOf,
  PairDataSource,
  TWO_COL_GAP_VP,
  TwoColumnLayout
} from '../common/utils/TwoColumnList';
import {
  NAV_TRANSITION_MS,
  BUTTON_RADIUS_VP,
  LIST_FOOTER_HEIGHT_VP
} from '../common/constants/InteractionConstants';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';

/** 失败后「重试」的冷却（ms）：followings 接口按 IP 风控限流，连点只会继续被拒（与 UpSpacePage 同口径） */
const RETRY_COOLDOWN_MS: number = 4000;

/**
 * 标题栏计数行（「共 N 人」）固定高：padding 4/8 + 文本 11fp ≈ 28。
 * bottomBuilder 高度不自适应（官方约束），必须与行内容定高一致。
 */
const FOLLOWS_COUNT_ROW_HEIGHT: number = 28;

@Component
export struct FollowsPage {
  @State ups: FollowedUp[] = [];
  /** 首屏加载中（骨架屏） */
  @State loading: boolean = false;
  /** 翻页加载中（列表底部「加载中…」） */
  @State loadingMore: boolean = false;
  @State page: number = 1;
  @State hasMore: boolean = true;
  /** 关注总数（「共 N 人」+ 判断还有没有下一页） */
  @State total: number = 0;
  /** 首屏是否失败（空态区分「没关注」与「拉不到」） */
  @State loadFailed: boolean = false;
  /** 失败原因（人话，含 code：该等风控过去还是该换网络，把 code 给用户看才知道） */
  @State failReason: string = '';
  /** 未登录：渲染登录引导空态（不发请求） */
  @State needLogin: boolean = false;
  /** 重试冷却中：按钮禁用（真正的门在 retryLocked 成员，状态只是给用户看的） */
  @State retryCooling: boolean = false;
  private retryLocked: boolean = false;
  private retryTimer: number = -1;

  /**
   * 登录态版本号：从本页「去登录」登录成功 / 退出登录时 LoginStore 会递增它，
   * @Watch 里重新查登录态并按需加载 —— aboutToAppear 只触发一次，不订阅的话
   * 「登录成功返回本页」会一直停在登录引导空态。
   */
  @StorageProp(STORE_LOGIN_REV) @Watch('onLoginRevChanged') loginRev: number = 0;
  /**
   * 媒体库版本号：在 UpSpacePage 里完成订阅 / 拉新后本地歌单变化会递增它。
   * 订阅状态只影响行上的「已订阅」徽标（纯本地查询），@Watch 里重灌同一份
   * 列表强制 LazyForEach 重建可见行即可，不必重新请求网络。
   */
  @StorageLink(STORE_LIBRARY_REV) @Watch('onLibraryChanged') libraryRev: number = 0;
  /** 状态栏高度（vp）：自绘顶栏由本页自己顶下来 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：列表末尾要自己让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;

  /** 主题色运行时值：操作按钮与登录引导跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 横竖屏（Index 常驻注册写入）：横屏宽屏时条目两列显示 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;

  /** 横屏宽屏（窗口 ≥600vp 的横屏）时条目两列显示；竖屏 / 窄窗口单列不变 */
  private isTwoCol(): boolean {
    return TwoColumnLayout.isActive(this.currentBreakpoint, this.isLandscape);
  }

  /**
   * HDS 标题栏整体让位量（vp）= safeTop + 标题行 56 + 计数行 28（有关注时）。
   * 标题行与 bottomBuilder 计数行高度均为定值，无需实测——
   * 顶部占位条目（下载页同款）与空态 padding 直接绑定该值。
   */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT
      + (this.total > 0 ? FOLLOWS_COUNT_ROW_HEIGHT : 0);
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
      (this.listScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  /** 列表滚动控制器：bindToScrollable 绑给 HDS 标题栏驱动滚动模糊 */
  private listScroller: Scroller = new Scroller();
  /** 列表数据源：与 @State ups 同步（整表重载统一走 upSource.reload） */
  private upSource: ArrayDataSource<FollowedUp> = new ArrayDataSource<FollowedUp>([]);
  /**
   * 两列视图数据源（无状态视图）：读 upSource 现场构造
   * PairOf，不缓存不注册 listener —— upSource 数据变化处显式调 upPairs.sync()
   * （见 TwoColumnList.PairDataSource 注释）。
   */
  private upPairs: PairDataSource<FollowedUp> = new PairDataSource<FollowedUp>(this.upSource);
  /** 「去登录 / 重试」按钮沉浸光感材质修饰器：26+ 生效，低版本 no-op 显实色兜底 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 子页转场横移量：常驻 '0%'，转场代理按 push/pop 临时改写 */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    // 挂载前先存当前偏移对应的进度（updater 未挂载只存值，
    // 挂载时 initializeModifier 补上），防「已滚过再进页」首帧缺模糊。
    this.syncTopBlurProgress();
    this.checkLoginAndLoad();
  }

  aboutToDisappear(): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut，与 RecentPage 同款。
   * pop 出场（含侧滑返回手势）反向滑回右侧；其余场景返回 undefined 走系统默认。
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

  /** 登录态自检：未登录渲染引导空态；已登录拉首屏 */
  private checkLoginAndLoad(): void {
    const user: LoginUser | null = getLoginUser();
    if (user === null) {
      this.needLogin = true;
      this.loading = false;
      return;
    }
    this.needLogin = false;
    this.loadFirst(user.mid);
  }

  private async loadFirst(vmid: number): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.loadFailed = false;
    this.failReason = '';
    this.page = 1;
    try {
      const data: FollowingsData = await getFollowings(vmid, 1);
      this.ups = data.list;
      this.total = data.total;
      this.hasMore = data.list.length > 0 && data.list.length < data.total;
      this.upSource.reload(data.list);
      // 两列视图同步：横屏 LazyForEach 读 upPairs，reload 后必须显式通知
      this.upPairs.sync();
      console.info(`follows page first load: ${data.list.length}/${data.total}`);
    } catch (err) {
      this.loadFailed = true;
      this.failReason = this.humanizeError(err);
      console.error(`follows page first load failed: ${JSON.stringify(err)}`);
    } finally {
      this.loading = false;
    }
  }

  private async loadMore(): Promise<void> {
    if (this.needLogin || this.loading || this.loadingMore || !this.hasMore) {
      return;
    }
    const user: LoginUser | null = getLoginUser();
    if (user === null) {
      return;
    }
    this.loadingMore = true;
    const next: number = this.page + 1;
    try {
      const data: FollowingsData = await getFollowings(user.mid, next);
      // 成功才推进 page：失败时下次 onReachEnd 仍从当前页重试
      this.page = next;
      // 增量追加：不整表 reload（onDataReloaded 会让可视区节点失效重建、
      // 锚点重算，列表整体跳动），按 mid 去重后 push 进镜像数组 + upSource.append 只发 onDataAdd。
      const seen: Set<string> = new Set<string>();
      for (let i = 0; i < this.ups.length; i++) {
        seen.add(String(this.ups[i].mid));
      }
      const fresh: FollowedUp[] = [];
      for (let i = 0; i < data.list.length; i++) {
        const up: FollowedUp = data.list[i];
        if (!seen.has(String(up.mid))) {
          fresh.push(up);
          seen.add(String(up.mid));
        }
      }
      for (let i = 0; i < fresh.length; i++) {
        this.ups.push(fresh[i]);
      }
      this.upSource.append(fresh);
      // 两列视图同步：追加后配对数变化，显式整表通知（末尾按需重建，粒度同 reload）
      this.upPairs.sync();
      this.hasMore = data.list.length > 0 && this.ups.length < this.total;
    } catch (err) {
      // 翻页失败不切失败态（首屏数据还在可看），提示一句即可
      console.warn(`follows page load more failed: ${JSON.stringify(err)}`);
      this.toast('加载更多失败，稍后再试', 1800);
    } finally {
      this.loadingMore = false;
    }
  }

  /** 错误 → 人话：-101 是登录失效（重试没用，该重新登录）；风控码该等；其余按网络问题报 */
  private humanizeError(err: Object): string {
    if (err instanceof BiliApiError) {
      if (err.code === -101) {
        return '登录态已失效，请退出登录后重新登录';
      }
      return `拉取失败（code ${err.code}），B 站接口可能风控中，稍等片刻再试`;
    }
    return '网络异常，请检查网络后重试';
  }

  private retry(): void {
    if (this.retryLocked) {
      return;
    }
    // 冷却窗口内只放行一次，且 UI 上按钮禁用（防风控连点，与 UpSpacePage 同口径）
    this.retryLocked = true;
    this.retryCooling = true;
    this.retryTimer = setTimeout((): void => {
      this.retryLocked = false;
      this.retryCooling = false;
      this.retryTimer = -1;
    }, RETRY_COOLDOWN_MS);
    const user: LoginUser | null = getLoginUser();
    if (user === null) {
      this.needLogin = true;
      this.loadFailed = false;
      return;
    }
    this.loadFirst(user.mid);
  }

  private onLoginRevChanged(): void {
    const user: LoginUser | null = getLoginUser();
    if (user === null) {
      // 退出登录：清数据回登录引导态（防止残留上一账号的关注列表）
      this.needLogin = true;
      this.loading = false;
      this.loadingMore = false;
      this.loadFailed = false;
      this.ups = [];
      this.total = 0;
      this.hasMore = false;
      this.upSource.reload([]);
      // 两列视图同步：清空后配对视图归零
      this.upPairs.sync();
      return;
    }
    if (this.needLogin) {
      // 从本页「去登录」成功返回：补拉首屏
      this.checkLoginAndLoad();
    }
  }

  private onLibraryChanged(): void {
    // 订阅状态（本地歌单）变化 → 只有「已订阅」徽标会变；重灌同列表强制行重建
    if (this.ups.length > 0) {
      this.upSource.reload(this.ups);
      // 两列视图同步：订阅徽标依赖本地查询，重建行才会刷新
      this.upPairs.sync();
    }
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /** 行点击 → UP 主页（订阅 / 拉新投稿在那边完成）；头像顺手传过去当首帧占位 */
  private openUpSpace(up: FollowedUp): void {
    NavStackHolder.stack.pushPathByName('UpSpace',
      new UpSpaceRouteParam(String(up.mid), up.uname, toThumbUrl(up.face, 96)));
  }

  /**
   * 标题行内容（titleBar 的 stackBuilder 承载，可用空间仅 56vp，不得超出——
   * 官方约束「不要超出标题栏的可用空间」，超出会溢出与内容区重叠）：
   * 「我的关注」标题（返回键为 HDS 默认键）。材质与滚动模糊由 HDS titleBar 负责。
   */
  @Builder
  followsBar() {
    NavTitleRow({ title: '我的关注' })
  }

  /**
   * 标题行下方自定义区（titleBar 的 bottomBuilder 承载，有关注时才配置）：
   * 「共 N 人」计数行。⚠️ bottomBuilder 高度不自适应，由 titleBar 参数显式给定
   * （FOLLOWS_COUNT_ROW_HEIGHT），行定高排布。
   */
  @Builder
  followsCountRow() {
    Row() {
      Blank()
        .layoutWeight(1)
      Text(`共 ${this.total} 人`)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height(FOLLOWS_COUNT_ROW_HEIGHT)
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
  followsBarNarrow() {
    Row() {
      Column() {
        this.followsBar()
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
   * 「共 N 人」计数行收窄容器（平板模式宽度适配）：同 followsBarNarrow
   * 口径 —— bottomBuilder 也横跨整列全宽，收窄后计数行与本页条目列同宽对齐；
   * bottomBuilder 显式高度（FOLLOWS_COUNT_ROW_HEIGHT）不动。sm 天然无操作。
   */
  @Builder
  followsCountRowNarrow() {
    Row() {
      Column() {
        this.followsCountRow()
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

  /** 一个关注 UP 行：头像 + 昵称/签名 + 「已订阅」徽标（本地订阅歌单存在即亮） */
  @Builder
  upRow(up: FollowedUp) {
    Row() {
      CoverImage({
        url: toThumbUrl(up.face, 96),
        imgWidth: 44,
        imgHeight: 44,
        imgRadius: 22,
        altText: up.uname
      })

      Column() {
        Text(up.uname)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(up.sign.length > 0 ? up.sign : '暂无签名')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })

      if (getPlaylistByUpMid(String(up.mid)) !== null) {
        // 小字徽标用系统标准 Chip。
        // ⚠️ Chip 是 @Builder 组件，不能链式挂属性 → 外边距挂外层 Row。
        Row() {
          Chip({
            label: {
              text: '已订阅',
              fontSize: 11,
              fontColor: this.themePrimary
            },
            size: ChipSize.SMALL,
            allowClose: false,
            backgroundColor: this.themeSurface
          })
        }
        .margin({ left: 8 })
        // 装饰徽标：读屏文案由整行 accessibilityText 统一给出
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .accessibilityText(`${up.uname}，${getPlaylistByUpMid(String(up.mid)) !== null ? '已订阅' : '未订阅'}`)
    .accessibilityLevel('yes')
    .onClick((): void => {
      this.openUpSpace(up);
    })
  }

  build() {
    HdsNavDestination() {
      Stack() {
        // 内容层：四态互斥（登录引导 / 骨架屏 / 失败态 / 列表或空态）
        Column() {
          if (this.needLogin) {
            Column() {
              Text('登录后才能查看关注列表')
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
          } else if (this.loading) {
            // 骨架屏：行数取一页的一半即可示意（与 UpSpacePage 加载态同思路）
            Column() {
              SkeletonTrackItem()
              SkeletonTrackItem()
              SkeletonTrackItem()
              SkeletonTrackItem()
              SkeletonTrackItem()
              SkeletonTrackItem()
            }
            .layoutWeight(1)
            .width('100%')
            .padding({ top: this.barTotalHeight() })
          } else if (this.loadFailed) {
            Column() {
              Text('关注列表拉取失败')
                .fontSize(16)
                .fontColor($r('app.color.text_secondary'))
              Text(this.failReason)
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ top: 8 })
                .textAlign(TextAlign.Center)
                .padding({ left: 32, right: 32 })
              Button(this.retryCooling ? '稍候重试' : '重试', { type: ButtonType.Normal })
                .fontSize(13)
                .height(32)
                .borderRadius(BUTTON_RADIUS_VP)
                .backgroundColor(this.themePrimary)
                .fontColor(this.themeOn)
                .attributeModifier(this.buttonMaterial)
                .enabled(!this.retryCooling)
                .opacity(this.retryCooling ? 0.5 : 1)
                .margin({ top: 20 })
                .onClick((): void => {
                  this.retry();
                })
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: this.barTotalHeight() })
          } else if (this.ups.length === 0) {
            Column() {
              Text('还没有关注任何 UP 主')
                .fontSize(16)
                .fontColor($r('app.color.text_secondary'))
              Text('去 B 站关注一些音乐 UP，再来这里订阅他们的新投稿')
                .fontSize(13)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ top: 8 })
                .textAlign(TextAlign.Center)
                .padding({ left: 32, right: 32 })
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: this.barTotalHeight() })
            // 列表挂载门控：让位量为定值计算（safeTop 启动即有），挂载即正确
          } else if (this.barTotalHeight() > 0) {
            List({ scroller: this.listScroller }) {
              // 顶部空白占位条目（下载页同款）：列表视口铺满全屏，条目起始位置在
              // 屏幕顶端（y=0）。占位高度 = 标题栏总让位量（barTotalHeight：
              // safeTop + 56 + 计数行 28），首个真实条目恰从栏底起排，
              // 滚动时占位与条目一起从沉浸材质下方穿过。
              ListItem() {
                // Blank 只能嵌在 Row/Column/Flex 内（编译器 10905201），ListItem 直下用定高 Row。
                Row()
                  .width('100%')
                  .height(this.barTotalHeight())
              }
              // 横屏宽屏：upRow 配对两列（左右槽各渲染一次，
              // 行内订阅徽标 / 点击按行独立）；占位与尾部状态条保持整行宽。
              if (this.isTwoCol()) {
                LazyForEach(
                  this.upPairs,
                  (pair: PairOf<FollowedUp>): void => {
                    ListItem() {
                      Row() {
                        Column() {
                          this.upRow(pair.first)
                        }
                        .layoutWeight(1)
                        if (pair.second !== null) {
                          Column() {
                            this.upRow(pair.second)
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
                  (pair: PairOf<FollowedUp>): string =>
                    `${pair.first.mid}|${pair.second !== null ? pair.second.mid : 'x'}`
                )
              } else {
                LazyForEach(
                  this.upSource,
                  (up: FollowedUp): void => {
                    ListItem() {
                      this.upRow(up)
                    }
                  },
                  (up: FollowedUp): string => String(up.mid)
                )
              }
              // 尾部状态条（常驻 + 固定高度）：只换内容不插拔条目，
              // 数据落地帧尾部 extent 只增不减，底部弹簧过滚动不被收缩强制解析。
              ListItem() {
                Row() {
                  if (this.loadingMore) {
                    LoadingProgress()
                      .width(18)
                      .height(18)
                      .color($r('app.color.text_tertiary'))
                    Text('加载中…')
                      .fontSize(12)
                      .fontColor($r('app.color.text_tertiary'))
                      .margin({ left: 8 })
                  } else if (!this.hasMore) {
                    Text('没有更多了')
                      .fontSize(11)
                      .fontColor($r('app.color.text_tertiary'))
                  } else {
                    Text('上拉加载更多')
                      .fontSize(11)
                      .fontColor($r('app.color.text_tertiary'))
                  }
                }
                .width('100%')
                .height(LIST_FOOTER_HEIGHT_VP)
                .justifyContent(FlexAlign.Center)
              }
            }
            .layoutWeight(1)
            // 边界回弹：到顶/到底的反馈动效
            .edgeEffect(EdgeEffect.Spring)
            .cachedCount(8)
            // 顶部 HDS 标题栏让位（Sumy 式穿透）：由 List 首个空白占位 ListItem
            // 负责（见上方占位注释，下载页同款）。
            .onReachEnd((): void => {
              this.loadMore();
            })
            // 逐帧驱动自绘渐变模糊层（onDidScroll 在偏移已应用
            // 后回调，onWillScroll 是应用前，快滑时差一帧会让模糊层滞后一跳）。
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
        .backgroundColor($r('app.color.bg_page'))
        // ⚠️ 不整体 padding top / safeAreaPadding bottom：列表视口铺满全屏并直接
        // 扩展进底部安全区（不做底部避让，沉浸到底）
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp）；
        // 横屏宽屏两列时上限放宽到 840（CONTENT_MAX_WIDTH_TWOCOL），竖屏维持原值
        .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })

        // 顶栏渐变模糊层：盖内容列之上（z 序低于 HDS
        // titleBar，计数行属标题栏 bottomBuilder、随整栏一起盖），进度由列表
        // onDidScroll/onScrollStop 经 topBlurUpdater 命令式驱动。
        TopGradientBlurOverlay({
          barHeightVp: this.barTotalHeight(),
          updater: this.topBlurUpdater
        })
      }
    }
    // HDS 沉浸光感标题栏（真机结论见 AboutPage 注释）：
    // avoidLayoutSafeArea 挡状态栏重叠；enableComponentSafeArea 会杀材质，禁用。
    // 平板模式宽度适配：stackBuilder / bottomBuilder 均走收窄容器
    //（followsBarNarrow / followsCountRowNarrow），标题行与计数行和条目列同宽对齐。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        // 标题行（stackBuilder，可用空间 56vp）：标题（收窄容器内；返回键为 HDS 默认键）
        stackBuilder: (): void => {
          this.followsBarNarrow();
        },
        // 标题行下方自定义区：「共 N 人」计数行（有关注时才配置，收窄容器内）。
        // ⚠️ 计数行不能塞进 stackBuilder（会溢出 56vp 标题行、与列表内容重叠，
        // 真机复现），必须走 bottomBuilder 显式高度。
        bottomBuilder: this.total > 0 ? {
          builder: (): void => {
            this.followsCountRowNarrow();
          },
          height: FOLLOWS_COUNT_ROW_HEIGHT,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        } : undefined
      }
    })
    // 返回键：使用 HDS 默认返回键（"<" 系统样式，位置由 HDS 管理以避开状态栏）。
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页列表交给 HDS 联动
    .bindToScrollable([this.listScroller])
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
    // 并接管组件级 safeAreaPadding。内容层避让由顶部占位条目 / plain padding 自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function FollowsPageBuilder(): void {
  FollowsPage()
}


/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const FollowsPageWrapped: WrappedBuilder<[]> = wrapBuilder(FollowsPageBuilder);

