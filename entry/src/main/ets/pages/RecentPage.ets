/**
 * 最近播放页：展示**本机播放记录**。
 *
 * 条数上限 100（LibraryStore 分片存储后为真实上限，2026-10-16 自 50 扩容；
 * 旧实现被 Preferences 单值字节预算截到约 11 条，重启即丢），超出挤掉最旧的；
 * 只保留最近 7 天（LibraryStore.RECENT_KEEP_MS，按 playedAt 过滤）。
 * 页面上用 「最近 7 天 · N 首」显示真实条数。
 * 条目加载（2026-10-16，PlaylistDetail 同款前端切片）：全量在 allTracks
 * （本地数据，不发请求），@State tracks 只装已揭示切片，onReachEnd 每次多放
 * RECENT_REVEAL_PAGE_SIZE 条；refresh() 重载保留已揭示条数（至少一批），
 * 移除 / 新增记录后列表不跳回第一批。
 * 历史由 MusicPlayer.loadAndPlay → LibraryStore.addRecentTrack 自动写入，
 * 这里只负责展示与回放：播放全部 / 单曲播放 / 加入队列 / 单条移除 / 清空。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，stackBuilder 承载
 * 返回行 + 标题 + 按钮行，批 1 样板同款）：avoidLayoutSafeArea 挡状态栏重叠，
 * 列表穿透让位（下载页同款顶部占位条目），滚动模糊由 HDS scrollEffectOpts 接管；
 * 侧滑返回是 Navigation 级能力，不受影响。
 *
 * 钉顶按钮行：「播放全部 / 清空」（仅在有播放记录时渲染）接在返回行下，
 * 不随内容滚出视口。
 */

import { Track } from '../model/MusicModels';
import { LibraryStore } from '../service/LibraryStore';
import { MusicPlayer } from '../player/MusicPlayer';
import { TrackItem } from '../components/TrackItem';
import { NavStackHolder } from '../service/NavStackHolder';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier
} from '../utils/HeaderBarMaterial';
import { HdsNavDestination, BottomBuilderShowType } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import {
  STORE_LIBRARY_REV,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  RESUME_MIN_SEC,
  RESUME_TAIL_SEC,
  CONTENT_END_OFFSET,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE,
  STORE_THEME_DEEP
} from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { NAV_TRANSITION_MS, BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import { showAppToast } from '../components/AppToast';
import { showAppAlertDialog } from '../components/AppAlertDialog';
import { NavTitleRow } from '../components/NavTitleRow';

/**
 * 标题栏按钮行（播放全部 / 清空）固定高：padding 4/8 + 按钮 32 = 44。
 * bottomBuilder 高度不自适应（官方约束），必须与行内容定高一致。
 */
const RECENT_ACTIONS_ROW_HEIGHT: number = 44;

/**
 * 顶栏滚动模糊时机（基准口径 = 关于页）：
 * 首条内容自静止位上移 30vp 起雾 → 80vp 满显影。
 * 本页让位由顶部占位条目承担（不占滚动量，F = raw），两参直接生效，无需补偿。
 */
const RECENT_BLUR_START_VP: number = 30;
const RECENT_BLUR_END_VP: number = 80;

/**
 * 前端切片每批揭示条数（PlaylistDetail.PD_REVEAL_PAGE_SIZE 同款）：
 * 全量在 allTracks（本地数据），@State tracks 只装切片，onReachEnd 多放一批。
 * 20 与歌单详情 / 排行榜页签口径一致。
 */
const RECENT_REVEAL_PAGE_SIZE: number = 20;

/**
 * 秒 → `m:ss`（超一小时 `h:mm:ss`）。
 * TrackItem.formatDuration 的轻量同款副本（该函数模块私有未导出），
 * 供「上次听到 x:xx」文案格式化。
 */
function formatSecToClock(seconds: number): string {
  const total: number = Math.floor(seconds);
  const h: number = Math.floor(total / 3600);
  const m: number = Math.floor((total % 3600) / 60);
  const s: number = total % 60;
  const mm: string = m < 10 ? `0${m}` : `${m}`;
  const ss: string = s < 10 ? `0${s}` : `${s}`;
  if (h > 0) {
    return `${h}:${mm}:${ss}`;
  }
  return `${m}:${ss}`;
}

@Component
export struct RecentPage {
  /**
   * 列表已揭示的曲目切片（PlaylistDetail 同款前端分页）：
   * 全量在 allTracks（LibraryStore 本地数据，不发请求），onReachEnd 每次多放
   * RECENT_REVEAL_PAGE_SIZE 条；refresh() 重载时保留已揭示的条数（至少一批），
   * 移除 / 新增记录后列表不跳回第一批。
   */
  @State tracks: Track[] = [];
  /** 最近播放全量（读取真源）：播放全部 / 条数文案 / 空态判断都按全量算 */
  private allTracks: Track[] = [];
  /**
   * HDS 标题栏整体让位量（vp）= safeTop + 标题行 56 + 按钮行 44（有记录时）。
   * 标题行与 bottomBuilder 按钮行高度均为定值，无需实测——
   * 顶部占位条目（下载页同款）与空态 padding 直接绑定该值（旧 onAreaChange 实测机制已废弃）。
   */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT
      + (this.allTracks.length > 0 ? RECENT_ACTIONS_ROW_HEIGHT : 0);
  }

  /**
   * 媒体库版本号：Storage 的写入是异步落盘，若本页在写入完成前就渲染过，
   * 只靠 aboutToAppear 那一次读取会一直停在空态。订阅版本号后，
   * 任何播放记录变更（新增 / 删除 / 清空）都会把本页重新拉一次。
   */
  @StorageLink(STORE_LIBRARY_REV) @Watch('onLibraryChanged') libraryRev: number = 0;
  /** 状态栏高度（vp）：标题栏要整体落在状态栏下方，由本页自己顶下来 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：NavDestination 默认扩到屏幕底，列表末尾要自己让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;

  /** 主题色运行时值：「播放全部」按钮浅底 / 主色 / 深字跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  private player: MusicPlayer = MusicPlayer.getInstance();

  /** 曲目列表滚动控制器：bindToScrollable 绑给 HDS 标题栏驱动滚动模糊 */
  private listScroller: Scroller = new Scroller();
  /** 按钮（播放全部 / 清空）沉浸光感材质修饰器：26+ 生效，低版本 no-op 显实色兜底 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();

  /**
   * 子页转场的横移量（相对页面自身宽度）：常驻 '0%'，
   * 转场代理里按 push/pop 方向临时改写（见 navTransitionDelegate）。
   */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    this.refresh();
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut。
   * · push 入场：先把页面挪到屏幕右侧外（'100%'），event 闭包内回到 '0%'，
   *   系统按闭包内的状态变化生成 400ms EaseOut 过渡；
   * · pop 出场（含侧滑返回手势触发的返回）：反向滑回右侧，与手势方向一致；
   * · 其余场景（本页被上层页覆盖 / 上层页返回后重新露出）返回 undefined，
   *   走系统默认转场。
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

  onLibraryChanged(): void {
    this.refresh();
  }

  private refresh(): void {
    const list: Track[] = LibraryStore.getRecentTracks();
    console.info(`recent page refresh: ${list.length} tracks`);
    this.allTracks = list;
    // 揭示切片：保留已看过的条数（移除 / 清空 / 新增记录重载后列表不跳回第一批），
    // 至少一批；清空时 list.length = 0，切片自然归零
    const keep: number = Math.max(this.tracks.length, RECENT_REVEAL_PAGE_SIZE);
    this.tracks = list.slice(0, Math.min(keep, list.length));
  }

  /** 是否还有未揭示的记录（底部状态行与 onReachEnd 闸门共用） */
  private hasMoreTracks(): boolean {
    return this.tracks.length < this.allTracks.length;
  }

  /**
   * List 的 onReachEnd（PlaylistDetail 同款，纯前端切片不发请求）：
   * 每次多放一批；没有下一批时直接返回（短列表首帧布局触发的空回调不做事）。
   */
  private onReachEnd(): void {
    if (this.tracks.length >= this.allTracks.length) {
      return;
    }
    const next: number = Math.min(this.tracks.length + RECENT_REVEAL_PAGE_SIZE,
      this.allTracks.length);
    this.tracks = this.allTracks.slice(0, next);
  }

  /**
   * 条目「上次听到 x:xx」文案（位置记忆，2026-10-12）。
   * 显示条件与续播阈值（MusicPlayer.playRecentFromHistory）完全一致：
   * ≥ RESUME_MIN_SEC 且距结尾 ≥ RESUME_TAIL_SEC —— 显示的就是会续播的位置；
   * 听完重置为 0 / 没听够 / 临近结尾 / 旧数据无字段 → 空串不渲染。
   */
  private heardTextOf(t: Track): string {
    const pos: number = t.lastPosSec ?? 0;
    if (pos < RESUME_MIN_SEC) {
      return '';
    }
    const dur: number = t.duration > 0 ? t.duration : 0;
    if (dur > 0 && pos > dur - RESUME_TAIL_SEC) {
      return '';
    }
    return `上次听到 ${formatSecToClock(pos)}`;
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /** 「⋯」标准菜单项（阶段 2 迁移：双按钮 AlertDialog → bindMenu + MenuElement 数组） */
  private trackMenuItems(track: Track): MenuElement[] {
    return [
      {
        value: '加入队列',
        action: (): void => {
          this.player.addToQueue(track);
          this.toast('已加入播放队列', 1500);
        }
      },
      {
        value: '从记录移除',
        action: (): void => {
          LibraryStore.removeRecentTrack(track.id);
          // 统一走 refresh()：全量与揭示切片必须一起换，
          // 只改 allTracks 会出现「空态判断已更新、列表还停着旧数据」
          this.refresh();
        }
      }
    ];
  }

  private clearAll(): void {
    showAppAlertDialog(this.getUIContext(), {
      title: '清空播放记录',
      message: '确定清空全部播放记录？此操作不可恢复。',
      primaryButton: {
        value: '取消',
        action: (): void => {
          // 取消：不做任何事
        }
      },
      secondaryButton: {
        value: '清空',
        action: (): void => {
          LibraryStore.clearRecentTracks();
          this.refresh();
          this.toast('已清空播放记录', 1500);
        }
      }
    });
  }

  /**
   * 标题行内容（titleBar 的 stackBuilder 承载，可用空间仅 56vp，不得超出——
   * 官方约束「不要超出标题栏的可用空间」，超出会溢出与内容区重叠）：
   * 返回键 + 「最近播放」标题。材质与滚动模糊由 HDS titleBar 负责。
   */
  @Builder
  recentBar() {
    NavTitleRow({ title: '最近播放' })
  }

  /**
   * 标题行下方自定义区（titleBar 的 bottomBuilder 承载，仅有记录时配置）：
   * 「播放全部 / 清空」按钮行。⚠️ bottomBuilder 高度不自适应，由 titleBar 参数
   * 显式给定（RECENT_ACTIONS_ROW_HEIGHT = padding 4/8 + 按钮 32），行定高排布。
   */
  @Builder
  recentActions() {
    Row() {
      Button('播放全部', { type: ButtonType.Normal })
        .fontSize(13)
        .height(32)
        .borderRadius(BUTTON_RADIUS_VP)
        // 真机要求：播放全部改为浅粉底 + 粉字（原粉底深枣红字）
        .backgroundColor(this.themeSurface)
        .fontColor(this.themePrimary)
        .attributeModifier(this.buttonMaterial)
        .onClick((): void => {
          // 播放全部按全量（allTracks）算，不受前端切片影响
          this.player.playAll(this.allTracks);
        })
      Button('清空', { type: ButtonType.Normal })
        .fontSize(13)
        .height(32)
        .borderRadius(BUTTON_RADIUS_VP)
        .backgroundColor(this.themeSurface)
        .fontColor(this.themeDeep)
        .attributeModifier(this.buttonMaterial)
        .margin({ left: 12 })
        .onClick((): void => {
          this.clearAll();
        })
      Blank()
        .layoutWeight(1)
      // 保留窗口是「最近 7 天」（LibraryStore.getRecentTracks 按 playedAt 过滤），
      // 把窗口和实际条数直接写出来（条数按全量 allTracks 算，与切片无关）。
      Text(`最近 7 天 · ${this.allTracks.length} 首`)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height(RECENT_ACTIONS_ROW_HEIGHT)
    .padding({ left: 16, right: 16, top: 4, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    HdsNavDestination() {
      Stack() {
        // 内容层：播放全部 / 清空 钉在标题栏下方自定义区（bottomBuilder），列表只装曲目行
        Column() {
          // 列表挂载门控：让位量为定值计算（safeTop 启动即有），挂载即正确
          if (this.allTracks.length > 0 && this.barTotalHeight() > 0) {
            List({ scroller: this.listScroller }) {
              // 顶部空白占位条目（下载页同款）：列表视口铺满全屏，条目起始位置在
              // 屏幕顶端（y=0）。占位高度 = 标题栏总让位量（barTotalHeight：
              // safeTop + 56 + 按钮行 44），首个真实条目恰从栏底起排（静置位与旧
              // padding 让位等值），滚动时占位与条目一起从沉浸材质下方穿过。
              ListItem() {
                // Blank 只能嵌在 Row/Column/Flex 内（编译器 10905201），ListItem 直下用定高 Row。
                Row()
                  .width('100%')
                  .height(this.barTotalHeight())
              }
              // 条目渲染（PlaylistDetail 同款）：@State tracks 揭示切片直接驱动
              // ForEach，追加 / 整表替换靠数组赋值，不再经 ArrayDataSource 双份拷贝。
              ForEach(
                this.tracks,
                (t: Track, index: number): void => {
                  ListItem() {
                    TrackItem({
                      track: t,
                      entranceIndex: index,
                      heardText: this.heardTextOf(t),
                      onPlay: (tr: Track): void => {
                        // 位置记忆入口：当前曲目 → 播/暂停切换；
                        // 其余按记录的上次位置续播（阈值内），否则从头播
                        this.player.playRecentFromHistory(tr);
                      },
                      moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
                    })
                  }
                },
                (t: Track): string => t.id
              )
              // 加载更多状态条（PlaylistDetail 同款）：本地切片即时揭示，没有
              // 加载中态，只区分「上拉加载更多」与「已经到底啦」。
              if (this.tracks.length > 0) {
                ListItem() {
                  Column() {
                    if (!this.hasMoreTracks()) {
                      Text('已经到底啦')
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                    } else {
                      Text('上拉加载更多')
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                    }
                  }
                  .width('100%')
                  .padding({ top: 14, bottom: 14 })
                  .justifyContent(FlexAlign.Center)
                }
              }
            }
            .layoutWeight(1)
            // 边界回弹（2026-10-08）：到顶/到底的反馈动效
            .edgeEffect(EdgeEffect.Spring)
            // 列表末端常规留白 + 前端切片上拉加载（PlaylistDetail 同款）。
            .contentEndOffset(CONTENT_END_OFFSET)
            .onReachEnd((): void => {
              this.onReachEnd();
            })
            // 顶部 HDS 标题栏让位（Sumy 式穿透）：由 List 首个空白占位 ListItem
            // 负责（见上方占位注释，下载页同款）——占位条目不占滚动量，F = raw，
            // (30, 80) 模糊参数直接生效；不再使用 contentStartOffset / 整体 padding。
          } else if (this.allTracks.length === 0) {
            Column() {
              Text('最近 7 天还没有播放记录')
                .fontColor($r('app.color.text_secondary'))
                .fontSize(16)
              Text('去搜索页播放一首歌试试吧')
                .fontColor($r('app.color.text_tertiary'))
                .fontSize(13)
                .margin({ top: 8 })
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            // 内容列不再整体 padding top（列表穿透需要），空态自己补让位（标题栏总让位量）
            .padding({ top: this.barTotalHeight() })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
        // ⚠️ 不再整体 padding top / safeAreaPadding bottom：列表视口铺满全屏并直接
        // 扩展进底部安全区（2026-10-09：不做底部避让，沉浸到底）；
        // （列表自身 padding 负责让出「状态栏+原生栏+条带」），滚动时曲目从
        // 条带材质下穿过。
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
        // 根 Stack 默认居中对齐，直接给内容列挂上限即可。
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
      }
    }
    // HDS 沉浸光感标题栏（批 1 样板同款，真机结论见 AboutPage 注释）：
    // avoidLayoutSafeArea 挡状态栏重叠；enableComponentSafeArea 会杀材质，禁用。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(RECENT_BLUR_START_VP, RECENT_BLUR_END_VP),
      content: {
        // 标题行（stackBuilder，可用空间 56vp）：返回键 + 标题
        stackBuilder: (): void => {
          this.recentBar();
        },
        // 标题行下方自定义区：「播放全部 / 清空」按钮行（仅有记录时配置）。
        // ⚠️ 第二行不能塞进 stackBuilder（会溢出 56vp 标题行、与列表内容重叠，
        // 真机复现），必须走 bottomBuilder 显式高度。
        bottomBuilder: this.allTracks.length > 0 ? {
          builder: (): void => {
            this.recentActions();
          },
          height: RECENT_ACTIONS_ROW_HEIGHT,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        } : undefined
      }
    })
    // 双返回键修复（2026-10-22）：隐藏 HDS 默认返回键，只保留 stackBuilder 自绘键
    // （默认键与自绘键在标题栏左上角重叠，两个 chevron 重影、按压效果错乱）
    .hideBackButton(true)
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页列表交给 HDS 联动
    .bindToScrollable([this.listScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 内容避让（2026-10-14）：目的地级声明布局扩展进系统安全区（官方组件级沉浸
    // 口径，faqs-arkui-1095 场景三同款）；窗口全屏下页面级为既成事实，此处显式化
    // 并接管组件级 safeAreaPadding。内容层避让由顶部占位条目 / plain padding 自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets，2026-10-17 启动优化）：
 * Index 已不再静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function RecentPageBuilder(): void {
  RecentPage()
}


/** 懒加载注册表预包装（2026-10-17）：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const RecentPageWrapped: WrappedBuilder<[]> = wrapBuilder(RecentPageBuilder);

