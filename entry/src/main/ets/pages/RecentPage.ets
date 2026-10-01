/**
 * 最近播放页：展示播放历史（最近 50 条）。
 * 历史由 MusicPlayer.loadAndPlay → LibraryStore.addRecentTrack 自动写入，
 * 这里只负责展示与回放：播放全部 / 单曲播放 / 加入队列 / 单条移除 / 清空。
 */

import { Track } from '../model/MusicModels';
import { LibraryStore } from '../service/LibraryStore';
import { MusicPlayer } from '../player/MusicPlayer';
import { TrackItem } from '../components/TrackItem';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { STORE_LIBRARY_REV, STORE_SAFE_BOTTOM, STORE_SAFE_TOP } from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { showAppToast } from '../components/AppToast';

@Component
export struct RecentPage {
  @State tracks: Track[] = [];
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
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  private player: MusicPlayer = MusicPlayer.getInstance();

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
    this.tracks = list;
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  private showMenu(track: Track): void {
    this.getUIContext().showAlertDialog({
      title: track.title,
      message: '选择操作',
      primaryButton: {
        value: '加入队列',
        action: (): void => {
          this.player.addToQueue(track);
          this.toast('已加入播放队列', 1500);
        }
      },
      secondaryButton: {
        value: '从记录移除',
        action: (): void => {
          this.tracks = LibraryStore.removeRecentTrack(track.id);
        }
      }
    });
  }

  private clearAll(): void {
    this.getUIContext().showAlertDialog({
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
          this.tracks = [];
          this.toast('已清空播放记录', 1500);
        }
      }
    });
  }

  build() {
    NavDestination() {
      Stack() {
        Column() {
          // 标题栏：与下载管理页同款（20fp 加粗左对齐，右侧挂操作入口）
          Row() {
            Text('最近播放')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
              .padding({ left: 16, top: 14, bottom: 6 })
            if (this.tracks.length > 0) {
              Text('清空')
                .fontSize(13)
                .fontColor($r('app.color.brand_deep'))
                .height(44)
                .padding({ left: 12, right: 16 })
                .borderRadius(8)
                .stateStyles({
                  pressed: { .backgroundColor($r('app.color.press_overlay')) },
                  normal: { .backgroundColor(Color.Transparent) }
                })
                .onClick((): void => {
                  this.clearAll();
                })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (this.tracks.length > 0) {
            Row() {
              Button('播放全部', { type: ButtonType.Capsule })
                .fontSize(13)
                .backgroundColor($r('app.color.bili_pink'))
                .fontColor($r('app.color.brand_on'))
                .margin({ left: 16, top: 4, bottom: 8 })
                .onClick((): void => {
                  this.player.playAll(this.tracks);
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            List() {
              ForEach(
                this.tracks,
                (t: Track, index: number): void => {
                  ListItem() {
                    TrackItem({
                      track: t,
                      entranceIndex: index,
                      onPlay: (tr: Track): void => {
                        this.player.playNow(tr);
                      },
                      onMore: (tr: Track): void => {
                        this.showMenu(tr);
                      }
                    })
                  }
                },
                (t: Track): string => t.id
              )
            }
            .layoutWeight(1)
          } else {
            Column() {
              Text('还没有播放记录')
                .fontColor($r('app.color.text_secondary'))
                .fontSize(16)
              Text('去搜索页播放一首歌试试吧')
                .fontColor($r('app.color.text_tertiary'))
                .fontSize(13)
                .margin({ top: 8 })
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
        // 系统标题栏保持隐藏（hideTitleBar），页内自绘「最近播放」标题栏（同下载管理页）；
        // 顶部先顶到状态栏下方，safeAreaPadding 再给标题留出与 PlayerPage 一致的呼吸间距。
        .padding({ top: this.safeTop })
        .safeAreaPadding({ top: NAV_TITLE_BAR_HEIGHT, bottom: this.safeBottom })
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
        // 根 Stack 默认居中对齐，直接给内容列挂上限即可。
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
      }
    }
    .hideTitleBar(true)
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
  }
}
