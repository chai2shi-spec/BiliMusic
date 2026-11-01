/**
 * 听直播页（「设置 → 我的关注」旁「听直播」入口）：
 *   · 关注主播开播列表：`/xlive/web-ucenter/v1/xfetter/GetWebList`（需登录，
 *     返回全部关注主播，本页过滤开播/轮播中的），滚动到底自动翻页；
 *   · 手动输入：房间号或 `live.bilibili.com/(h5/)?房间号` 链接 →
 *     getInfoByRoom 校验 → 开播中即播（匿名可用，不需要登录）。
 *
 * 播放链路：buildLiveRoomTrack 产出 isLive Track（audioUrl 留空），播放内核
 * loadAndPlay 的直播分支按 roomId 实时取流（HLS 优先），地址绝不缓存。
 *
 * 骨架照 FollowsPage：登录门禁（STORE_LOGIN_REV @Watch）/ 骨架屏 / 失败态
 * （4s 重试冷却防风控连点）/ LazyForEach + ArrayDataSource / 横屏两列。
 * 差异点：顶部多一个固定输入区（不随列表滚动消失），列表态不需要占位条目。
 */

import {
  BiliApiError,
  LiveRoomInfo,
  buildLiveRoomTrack,
  getFollowedLiveList,
  getRoomInfoByRoom,
  parseLiveInput
} from '../api/BilibiliApi';
import { getLoginUser, LoginUser } from '../service/LoginStore';
import { NavStackHolder } from '../service/NavStackHolder';
import { MusicPlayer } from '../player/MusicPlayer';
import { CoverImage } from '../components/CoverImage';
import { SkeletonTrackItem } from '../components/SkeletonTrackItem';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { Chip, ChipSize } from '@kit.ArkUI';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { showAppToast } from '../components/AppToast';
import { toThumbUrl, toHttpsUrl } from '../utils/TextUtil';
import { ArrayDataSource } from '../utils/ArrayDataSource';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier
} from '../utils/HeaderBarMaterial';
import {
  STORE_LOGIN_REV,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY,
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

/** 失败后「重试」的冷却（ms）：GetWebList 与 followings 同属风控重灾区，连点只会继续被拒 */
const RETRY_COOLDOWN_MS: number = 4000;
/** 翻页一页最多连拉次数：过滤未开播后某页可能 0 新增，连拉兜底但不失控 */
const LOAD_MORE_MAX_PAGES: number = 3;

@Component
export struct LivePage {
  @State rooms: LiveRoomInfo[] = [];
  /** 首屏加载中（骨架屏） */
  @State loading: boolean = false;
  /** 翻页加载中（列表底部「加载中…」） */
  @State loadingMore: boolean = false;
  @State page: number = 1;
  @State hasMore: boolean = true;
  /** 首屏是否失败（空态区分「没人开播」与「拉不到」） */
  @State loadFailed: boolean = false;
  @State failReason: string = '';
  /** 未登录：渲染登录引导空态（列表不发请求，输入区仍可用） */
  @State needLogin: boolean = false;
  /** 重试冷却中：按钮禁用（真正的门在 retryLocked 成员，状态只是给用户看的） */
  @State retryCooling: boolean = false;
  /** 手动输入框内容 */
  @State roomInput: string = '';
  /** 房间号查询进行中（按钮转圈，防连点） */
  @State entering: boolean = false;
  private retryLocked: boolean = false;
  private retryTimer: number = -1;

  /**
   * 登录态版本号：从本页「去登录」登录成功 / 退出登录时 LoginStore 会递增它，
   * @Watch 里重新查登录态并按需加载 —— aboutToAppear 只触发一次，不订阅的话
   * 「登录成功返回本页」会一直停在登录引导空态。
   */
  @StorageProp(STORE_LOGIN_REV) @Watch('onLoginRevChanged') loginRev: number = 0;
  /** 状态栏高度（vp）：自绘顶栏由本页自己顶下来 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：列表末尾要自己让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;

  /** 主题色运行时值：按钮跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 横竖屏（Index 常驻注册写入）：横屏宽屏时条目两列显示 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;

  /** 横屏宽屏（窗口 ≥600vp 的横屏）时条目两列显示；竖屏 / 窄窗口单列不变 */
  private isTwoCol(): boolean {
    return TwoColumnLayout.isActive(this.currentBreakpoint, this.isLandscape);
  }

  /** HDS 标题栏整体让位量（vp）= safeTop + 标题行 56（无计数行） */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT;
  }

  /**
   * 自绘顶栏渐变模糊层进度更新器 + 校准（FollowsPage 同款）：onDidScroll /
   * onScrollStop 命令式驱动 opacity（不标 @State，滚动高频回调零重建）。
   */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.listScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  /** 列表滚动控制器：bindToScrollable 绑给 HDS 标题栏驱动滚动模糊 */
  private listScroller: Scroller = new Scroller();
  /** 列表数据源：与 @State rooms 同步（整表重载统一走 roomSource.reload） */
  private roomSource: ArrayDataSource<LiveRoomInfo> = new ArrayDataSource<LiveRoomInfo>([]);
  /** 两列视图数据源（无状态视图）：数据变化处显式调 roomPairs.sync() */
  private roomPairs: PairDataSource<LiveRoomInfo> = new PairDataSource<LiveRoomInfo>(this.roomSource);
  /** 「去登录 / 重试 / 进入」按钮沉浸光感材质修饰器 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 子页转场横移量：常驻 '0%'，转场代理按 push/pop 临时改写 */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
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
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut，FollowsPage 同款。
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

  /** 登录态自检：未登录渲染引导空态（输入区仍可用）；已登录拉首屏 */
  private checkLoginAndLoad(): void {
    const user: LoginUser | null = getLoginUser();
    if (user === null) {
      this.needLogin = true;
      this.loading = false;
      return;
    }
    this.needLogin = false;
    this.loadFirst();
  }

  private async loadFirst(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.loadFailed = false;
    this.failReason = '';
    this.page = 1;
    try {
      const data = await getFollowedLiveList(1);
      this.rooms = this.filterLive(data.rooms);
      this.hasMore = data.hasMore;
      this.roomSource.reload(this.rooms);
      this.roomPairs.sync();
      console.info(`live page first load: ${this.rooms.length} live rooms (raw ${data.rooms.length})`);
    } catch (err) {
      this.loadFailed = true;
      this.failReason = this.humanizeError(err);
      console.error(`live page first load failed: ${JSON.stringify(err)}`);
    } finally {
      this.loading = false;
    }
  }

  /**
   * 翻页：GetWebList 返回全部关注主播（含未开播），过滤后单页可能 0 新增 ——
   * 连拉至多有新增或达 LOAD_MORE_MAX_PAGES 为止，避免「上拉没反应」的错觉。
   */
  private async loadMore(): Promise<void> {
    if (this.needLogin || this.loading || this.loadingMore || !this.hasMore) {
      return;
    }
    this.loadingMore = true;
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < this.rooms.length; i++) {
      seen.add(String(this.rooms[i].roomId));
    }
    let fetchedPages: number = 0;
    try {
      while (fetchedPages < LOAD_MORE_MAX_PAGES && this.hasMore) {
        const next: number = this.page + 1;
        const data = await getFollowedLiveList(next);
        fetchedPages++;
        this.page = next;
        this.hasMore = data.hasMore;
        const fresh: LiveRoomInfo[] = [];
        const live: LiveRoomInfo[] = this.filterLive(data.rooms);
        for (let i = 0; i < live.length; i++) {
          const room: LiveRoomInfo = live[i];
          if (!seen.has(String(room.roomId))) {
            fresh.push(room);
            seen.add(String(room.roomId));
          }
        }
        for (let i = 0; i < fresh.length; i++) {
          this.rooms.push(fresh[i]);
        }
        this.roomSource.append(fresh);
        this.roomPairs.sync();
        if (fresh.length > 0) {
          break;
        }
      }
    } catch (err) {
      // 翻页失败不切失败态（首屏数据还在可看），提示一句即可
      console.warn(`live page load more failed: ${JSON.stringify(err)}`);
      this.toast('加载更多失败，稍后再试', 1800);
    } finally {
      this.loadingMore = false;
    }
  }

  /** 只留开播 / 轮播中的条目（轮播也有流，可听） */
  private filterLive(rooms: LiveRoomInfo[]): LiveRoomInfo[] {
    const live: LiveRoomInfo[] = [];
    for (let i = 0; i < rooms.length; i++) {
      if (rooms[i].liveStatus > 0 && rooms[i].roomId > 0) {
        live.push(rooms[i]);
      }
    }
    return live;
  }

  /** 错误 → 人话：-101 登录失效（该重新登录）；风控码该等；其余按网络问题报 */
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
    // 冷却窗口内只放行一次，且 UI 上按钮禁用（防风控连点，FollowsPage 同口径）
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
    this.loadFirst();
  }

  private onLoginRevChanged(): void {
    const user: LoginUser | null = getLoginUser();
    if (user === null) {
      // 退出登录：清数据回登录引导态（防止残留上一账号的列表）
      this.needLogin = true;
      this.loading = false;
      this.loadingMore = false;
      this.loadFailed = false;
      this.rooms = [];
      this.hasMore = false;
      this.roomSource.reload([]);
      this.roomPairs.sync();
      return;
    }
    if (this.needLogin) {
      // 从本页「去登录」成功返回：补拉首屏
      this.checkLoginAndLoad();
    }
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /** 行点击 → 以 isLive Track 起播（audioUrl 空，播放内核按 roomId 实时取流） */
  private openRoom(room: LiveRoomInfo): void {
    MusicPlayer.getInstance().playNow(buildLiveRoomTrack(room));
  }

  /** 手动输入房间号 / 链接进入直播间（匿名可用，不需要登录） */
  private async enterRoom(): Promise<void> {
    if (this.entering) {
      return;
    }
    const roomId: number = parseLiveInput(this.roomInput);
    if (roomId <= 0) {
      this.toast('请输入房间号，或 live.bilibili.com 开头的生活间链接', 2200);
      return;
    }
    this.entering = true;
    try {
      const room: LiveRoomInfo = await getRoomInfoByRoom(roomId);
      if (room.liveStatus === 0) {
        this.toast('该直播间当前未开播', 2000);
        return;
      }
      this.openRoom(room);
    } catch (err) {
      if (err instanceof BiliApiError) {
        this.toast(`进入直播间失败（code ${err.code}）`, 2000);
      } else {
        this.toast('进入直播间失败，请检查网络或房间号', 2000);
      }
      console.warn(`live page enter room ${roomId} failed: ${JSON.stringify(err)}`);
    } finally {
      this.entering = false;
    }
  }

  /** 标题行内容（titleBar 的 stackBuilder 承载，可用空间仅 56vp） */
  @Builder
  liveBar() {
    NavTitleRow({ title: '听直播' })
  }

  /**
   * 标题行收窄容器（平板模式宽度适配，FollowsPage 同款）：外层 Row 居中 +
   * 内层 Column constraintSize 收窄，标题行与条目列同宽对齐；sm 天然无操作。
   */
  @Builder
  liveBarNarrow() {
    Row() {
      Column() {
        this.liveBar()
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

  /** 手动输入区：TextInput + 「进入」按钮（固定顶部，不随列表滚动） */
  @Builder
  inputRow() {
    Row({ space: 8 }) {
      TextInput({ text: this.roomInput, placeholder: '房间号或直播间链接' })
        .layoutWeight(1)
        .height(38)
        .fontSize(14)
        .borderRadius(BUTTON_RADIUS_VP)
        .backgroundColor($r('app.color.bg_card'))
        .onChange((v: string): void => {
          this.roomInput = v;
        })
        .onSubmit((): void => {
          this.enterRoom();
        })

      Button(this.entering ? '' : '进入', { type: ButtonType.Normal })
        .fontSize(14)
        .height(38)
        .padding({ left: 16, right: 16 })
        .borderRadius(BUTTON_RADIUS_VP)
        .backgroundColor(this.themePrimary)
        .fontColor(this.themeOn)
        .attributeModifier(this.buttonMaterial)
        .enabled(!this.entering)
        .opacity(this.entering ? 0.6 : 1)
        .onClick((): void => {
          this.enterRoom();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 一个直播间行：主播头像 + 标题/主播·分区·人气 + 「直播中」徽标 */
  @Builder
  roomRow(room: LiveRoomInfo) {
    Row() {
      CoverImage({
        url: toThumbUrl(room.face.length > 0 ? room.face : toHttpsUrl(room.cover), 96),
        imgWidth: 44,
        imgHeight: 44,
        imgRadius: 22,
        altText: room.uname
      })

      Column() {
        Text(room.title.length > 0 ? room.title : `直播间 ${room.roomId}`)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.roomSubtitle(room))
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })

      // 「直播中」徽标：红色系为直播语义色（不随主题换色）。
      // ⚠️ Chip 是 @Builder 组件，不能链式挂属性 → 外边距挂外层 Row。
      Row() {
        Chip({
          label: {
            text: room.liveStatus === 2 ? '轮播中' : '直播中',
            fontSize: 11,
            fontColor: '#FF4D4F'
          },
          size: ChipSize.SMALL,
          allowClose: false,
          backgroundColor: '#FFF1F0'
        })
      }
      .margin({ left: 8 })
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .accessibilityText(`${room.uname}的直播间，${room.liveStatus === 2 ? '轮播中' : '直播中'}，${this.roomSubtitle(room)}`)
    .accessibilityLevel('yes')
    .onClick((): void => {
      this.openRoom(room);
    })
  }

  /** 行副文案：主播 · 分区 · 人气（有啥拼啥，最少显示主播名兜底） */
  private roomSubtitle(room: LiveRoomInfo): string {
    const parts: string[] = [];
    if (room.uname.length > 0) {
      parts.push(room.uname);
    }
    if (room.areaName.length > 0) {
      parts.push(room.areaName);
    }
    if (room.watchedText.length > 0) {
      parts.push(`${room.watchedText}人气`);
    }
    if (parts.length === 0) {
      return `直播间 ${room.roomId}`;
    }
    return parts.join(' · ');
  }

  build() {
    HdsNavDestination() {
      Stack() {
        // 内容层：输入区（固定）+ 四态互斥（登录引导 / 骨架屏 / 失败态 / 列表或空态）
        Column() {
          // 手动输入区：标题栏让位后固定顶部，四态均可用（匿名也能听任意房间）
          Column() {
            this.inputRow()
          }
          .width('100%')
          .padding({
            left: 16, right: 16,
            top: this.barTotalHeight() + 4,
            bottom: 4
          })

          if (this.needLogin) {
            Column() {
              Text('登录后才能查看关注主播的开播列表')
                .fontSize(16)
                .fontColor($r('app.color.text_secondary'))
              Text('也可以直接输入房间号收听任意直播间')
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
          } else if (this.loading) {
            // 骨架屏：行数取一页的一半即可示意（FollowsPage 同思路）
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
          } else if (this.loadFailed) {
            Column() {
              Text('开播列表拉取失败')
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
          } else if (this.rooms.length === 0) {
            Column() {
              Text('关注的主播都没有在直播')
                .fontSize(16)
                .fontColor($r('app.color.text_secondary'))
              Text('可以去 B 站关注喜欢的主播，或输入房间号收听任意直播间')
                .fontSize(13)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ top: 8 })
                .textAlign(TextAlign.Center)
                .padding({ left: 32, right: 32 })
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            List({ scroller: this.listScroller }) {
              // 横屏宽屏：roomRow 配对两列；竖屏 / 窄窗口单列
              if (this.isTwoCol()) {
                LazyForEach(
                  this.roomPairs,
                  (pair: PairOf<LiveRoomInfo>): void => {
                    ListItem() {
                      Row() {
                        Column() {
                          this.roomRow(pair.first)
                        }
                        .layoutWeight(1)
                        if (pair.second !== null) {
                          Column() {
                            this.roomRow(pair.second)
                          }
                          .layoutWeight(1)
                          .margin({ left: TWO_COL_GAP_VP })
                        } else {
                          // 奇数末尾：右侧槽留空占位
                          Blank().layoutWeight(1)
                        }
                      }
                      .width('100%')
                    }
                  },
                  (pair: PairOf<LiveRoomInfo>): string =>
                    `${pair.first.roomId}|${pair.second !== null ? pair.second.roomId : 'x'}`
                )
              } else {
                LazyForEach(
                  this.roomSource,
                  (room: LiveRoomInfo): void => {
                    ListItem() {
                      this.roomRow(room)
                    }
                  },
                  (room: LiveRoomInfo): string => String(room.roomId)
                )
              }
              // 尾部状态条（常驻 + 固定高度）
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
            .onReachEnd((): void => {
              this.loadMore();
            })
            .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
              this.syncTopBlurProgress();
            })
            .onScrollStop((): void => {
              this.syncTopBlurProgress();
            })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp）
        .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })

        // 顶栏渐变模糊层：盖内容列之上，进度由列表滚动经 topBlurUpdater 命令式驱动
        TopGradientBlurOverlay({
          barHeightVp: this.barTotalHeight(),
          updater: this.topBlurUpdater
        })
      }
    }
    // HDS 沉浸光感标题栏（FollowsPage 同款口径）
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        stackBuilder: (): void => {
          this.liveBarNarrow();
        }
      }
    })
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页列表交给 HDS 联动
    .bindToScrollable([this.listScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 系统返回拦截：播放页 overlay 打开时吞掉返回，否则走默认 pop
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让：目的地级声明布局扩展进系统安全区，内容层避让由输入区 padding 自理
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function LivePageBuilder(): void {
  LivePage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const LivePageWrapped: WrappedBuilder<[]> = wrapBuilder(LivePageBuilder);
