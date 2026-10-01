/**
 * 歌单详情页：展示歌单内单曲，支持播放全部 / 单曲播放 / 加入队列 / 从歌单移除。
 * 目标歌单 id 由 NavStackHolder.selectedPlaylistId 传入。
 *
 * 标题栏为自绘（系统 NavDestination 标题栏无法去掉返回键）：
 * 无返回键（返回走系统侧滑），整体 position 到状态栏下方（y = safeTop），
 * 材质沿用沉浸光感 THIN（MaterialCompat uiMaterial 通路），列表滚动时从材质下透出。
 */

// uiMaterial 模块 26.0.0 才有（API 23/24 上静态 import 崩溃），必须 lazy；
// 本文件只在类型位置引用它，运行时经 MaterialCompat 的版本门控访问。
import lazy { uiMaterial } from '@kit.ArkUI';
import { Playlist, Track } from '../model/MusicModels';
import { LibraryStore } from '../service/LibraryStore';
import { MusicPlayer } from '../player/MusicPlayer';
import { TrackItem } from '../components/TrackItem';
import { NavStackHolder } from '../service/NavStackHolder';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { MaterialCompat, MaterialCompatStyle } from '../utils/MaterialCompat';
import { STORE_LIBRARY_REV, STORE_SAFE_BOTTOM, STORE_SAFE_TOP } from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { showAppToast } from '../components/AppToast';

/**
 * 标题栏沉浸材质的属性修饰器：仅当材质对象存在（API 26+ 且运行时支持）时才调用
 * systemMaterial；API 23/24 上该属性方法不存在，不调用即不崩溃（透明标题栏兜底）。
 */
class HeaderMaterialModifier implements AttributeModifier<RowAttribute> {
  private material: uiMaterial.ImmersiveMaterial | undefined;

  constructor(material: uiMaterial.ImmersiveMaterial | undefined) {
    this.material = material;
  }

  applyNormalAttribute(instance: RowAttribute): void {
    const m: uiMaterial.ImmersiveMaterial | undefined = this.material;
    if (m === undefined) {
      return;
    }
    try {
      instance.systemMaterial(m);
    } catch (e) {
      console.error(`apply header systemMaterial failed: ${JSON.stringify(e)}`);
    }
  }
}

@Component
export struct PlaylistDetail {
  /** 自绘标题栏的沉浸材质（THIN 毛玻璃）；能力缺失时 undefined，走默认样式 */
  private headerMaterial: uiMaterial.ImmersiveMaterial | undefined =
    MaterialCompat.immersiveMaterial(MaterialCompatStyle.THIN, { interactive: true });
  /**
   * systemMaterial 属性方法 26.0.0 才有：API 23/24 上直接链式调用会在渲染期抛
   * 「not callable」崩溃。改走 AttributeModifier（API 12 起通用），材质为
   * undefined（低版本 / 能力缺失）时不调用，静默退化为透明标题栏。
   */
  private headerModifier: HeaderMaterialModifier = new HeaderMaterialModifier(this.headerMaterial);
  @State playlist: Playlist | null = null;
  @State titleText: string = '歌单';
  @State showRename: boolean = false;
  @State renameName: string = '';
  /** 媒体库变更信号：在别处（如弹层里）改到这个歌单时同步刷新 */
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
    this.load();
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
    this.load();
  }

  private load(): void {
    this.playlist = LibraryStore.getPlaylist(NavStackHolder.selectedPlaylistId);
    this.titleText = this.playlist ? this.playlist.name : '歌单';
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  private showPlaylistMenu(): void {
    const p: Playlist | null = this.playlist;
    if (!p) {
      return;
    }
    this.getUIContext()
      .getPromptAction()
      .showDialog({
        title: p.name,
        message: `${p.tracks.length} 首`,
        buttons: [
          { text: '重命名', color: $r('app.color.text_secondary') },
          { text: '删除歌单', color: $r('app.color.state_error') }
        ]
      })
      .then((resp): void => {
        if (resp.index === 0) {
          this.renameName = p.name;
          this.showRename = true;
        } else if (resp.index === 1) {
          this.confirmDelete();
        }
      })
      .catch((e: Error): void => {
        console.error(`showPlaylistMenu failed: ${e.message}`);
      });
  }

  private submitRename(): void {
    const name: string = this.renameName.trim();
    if (name.length === 0) {
      this.toast('请输入歌单名称', 1500);
      return;
    }
    if (this.playlist) {
      LibraryStore.renamePlaylist(this.playlist.id, name);
      this.load();
      this.toast('已重命名', 1500);
    }
    this.showRename = false;
  }

  private confirmDelete(): void {
    const p: Playlist | null = this.playlist;
    if (!p) {
      return;
    }
    this.getUIContext().showAlertDialog({
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
          this.toast('已删除歌单', 1500);
          NavStackHolder.stack.pop();
        }
      }
    });
  }

  private showMenu(track: Track): void {
    this.getUIContext().showAlertDialog({
      title: track.title,
      message: '选择操作',
      primaryButton: {
        value: '从歌单移除',
        action: (): void => {
          LibraryStore.removeTracksFromPlaylist(NavStackHolder.selectedPlaylistId, [track.id]);
          this.load();
        }
      },
      secondaryButton: {
        value: '加入队列',
        action: (): void => {
          this.player.addToQueue(track);
          this.toast('已加入播放队列', 1500);
        }
      }
    });
  }

  @Builder
  HeaderActions(): void {
    Row({ space: 8 }) {
      if (this.playlist && this.playlist.tracks.length > 0) {
        Button('播放全部', { type: ButtonType.Capsule })
          .fontSize(13)
          .height(32)
          .backgroundColor($r('app.color.bili_pink'))
          .fontColor($r('app.color.brand_on'))
          .onClick((): void => {
            if (this.playlist) {
              this.player.playAll(this.playlist.tracks);
            }
          })
      }
      // 触达铁律：视觉是 22px 的字，命中区撑到 44×44
      Text('⋮')
        .fontSize(22)
        .fontColor($r('app.color.text_secondary'))
        .width(44)
        .height(44)
        .borderRadius(22)
        .textAlign(TextAlign.Center)
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.press_overlay')) },
          normal: { .backgroundColor(Color.Transparent) }
        })
        .onClick((): void => {
          this.showPlaylistMenu();
        })
    }
    .alignItems(VerticalAlign.Center)
  }

  build() {
    NavDestination() {
      Stack() {
        Column() {
          if (this.playlist && this.playlist.tracks.length > 0) {
            List() {
              ForEach(
                this.playlist.tracks,
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
            .layoutWeight(1)          } else {
            Column() {
              Text('歌单还是空的')
                .fontColor($r('app.color.text_secondary'))
                .fontSize(16)
              Text('在搜索页点击“⋯”把歌曲加进来吧')
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
        // 自绘标题栏悬浮在内容上方（同原 STACK 透底方案），列表滚动时从材质下透出；
        // 标题栏整体落在状态栏下方：内容先 padding top = safeTop 顶过状态栏，
        // 再 safeAreaPadding top = 标题栏高度，首项不被标题栏盖住。
        .padding({ top: this.safeTop })
        .safeAreaPadding({ top: NAV_TITLE_BAR_HEIGHT, bottom: this.safeBottom })
        // 大屏适配：内容列收窄居中（折叠屏展开 600vp / 平板 720vp），
        // 根 Stack 默认居中对齐，直接给内容列挂上限即可。
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })

        // 自绘标题栏（去掉返回键，返回走系统侧滑）：position 到状态栏下方，
        // 不再像系统标题栏那样压到状态栏 / 挖孔区域。
        // 外面包一层与内容列同宽的宿主：position 相对宿主定位，大屏上标题栏
        // 才能与收窄后的列表左右对齐（直接挂 Stack 上会贴屏幕左缘）；
        // hitTestBehavior(None) 让宿主自身不吞点击，标题栏以下的区域照常点得到列表。
        Column() {
          Row() {
            Text(this.titleText)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            this.HeaderActions()
          }
          .width('100%')
          .height(NAV_TITLE_BAR_HEIGHT)
          .padding({ left: 16, right: 8 })
          .alignItems(VerticalAlign.Center)
          .position({ x: 0, y: this.safeTop })
          .backgroundColor(Color.Transparent)
          .attributeModifier(this.headerModifier)
        }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
        .hitTestBehavior(HitTestMode.None)

        if (this.showRename) {
          Column() {
          }
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.scrim'))
          .onClick((): void => {
            this.showRename = false;
          })
          .justifyContent(FlexAlign.Center)

          Column() {
            Text('重命名歌单')
              .fontSize(18)
              .fontColor($r('app.color.text_primary'))
              .margin({ bottom: 14 })
            TextInput({ placeholder: '歌单名称', text: this.renameName })
              .width('100%')
              .onChange((v: string): void => {
                this.renameName = v;
              })
            Row() {
              Button('取消', { type: ButtonType.Normal })
                .layoutWeight(1)
                .height(44)
                .backgroundColor($r('app.color.bg_divider'))
                .fontColor($r('app.color.text_primary'))
                .onClick((): void => {
                  this.showRename = false;
                })
              Button('保存', { type: ButtonType.Normal })
                .layoutWeight(1)
                .height(44)
                .backgroundColor($r('app.color.bili_pink'))
                .fontColor($r('app.color.brand_on'))
                .margin({ left: 12 })
                .onClick((): void => {
                  this.submitRename();
                })
            }
            .margin({ top: 16 })
          }
          .padding(20)
          .width('80%')
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
        }
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
