/**
 * 歌单列表页：展示本地歌单，支持新建 / 重命名 / 删除歌单、进入详情。
 * 数据来自 LibraryStore（内部有内存快照 + 异步落盘）。
 */

import { LibraryStore } from '../service/LibraryStore';
import { Playlist } from '../model/MusicModels';
import { NavStackHolder } from '../service/NavStackHolder';import { CONTENT_END_OFFSET, STORE_LIBRARY_REV, STORE_SAFE_BOTTOM } from '../common/Constants';
import { showAppToast } from '../components/AppToast';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';

@Component
export struct PlaylistsPage {
  @State playlists: Playlist[] = [];
  /** 最近播放条数，用于入口卡片展示（切回本页 / 返回时刷新） */
  @State recentCount: number = 0;
  /** 名称编辑弹窗：editingId 为空表示新建，非空表示重命名 */
  @State showEditor: boolean = false;
  @State editingId: string = '';
  @State editorName: string = '';
  /**
   * 媒体库变更信号。Tabs 的 TabContent 是常驻的，aboutToAppear 只在首次触发：
   * 搜索页加完歌单切回来、详情页改完返回，都必须靠它重新读数据。
   */
  @StorageLink(STORE_LIBRARY_REV) @Watch('onLibraryChanged') libraryRev: number = 0;
  /** 底部安全区高度（vp）：根容器不再统一避让，列表末尾让位要自己叠上这一份 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;

  aboutToAppear(): void {
    this.refresh();
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
    this.recentCount = LibraryStore.getRecentTracks().length;
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  private openCreate(): void {
    this.editingId = '';
    this.editorName = '';
    this.showEditor = true;
  }

  private openRename(p: Playlist): void {
    this.editingId = p.id;
    this.editorName = p.name;
    this.showEditor = true;
  }

  private submitEditor(): void {
    const name: string = this.editorName.trim();
    if (name.length === 0) {
      this.toast('请输入歌单名称', 1500);
      return;
    }
    if (this.editingId.length === 0) {
      LibraryStore.createPlaylist({ name: name });
      this.toast('歌单已创建', 1500);
    } else {
      LibraryStore.renamePlaylist(this.editingId, name);
      this.toast('已重命名', 1500);
    }
    this.showEditor = false;
    this.refresh();
  }

  private showPlaylistMenu(p: Playlist): void {
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
          this.openRename(p);
        } else if (resp.index === 1) {
          this.confirmDelete(p);
        }
      })
      .catch((e: Error): void => {
        console.error(`showPlaylistMenu failed: ${e.message}`);
      });
  }

  private confirmDelete(p: Playlist): void {
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
          this.refresh();
          this.toast('已删除歌单', 1500);
        }
      }
    });
  }

  build() {
    Stack() {
      Column() {
        // 最近播放入口：点击进入历史列表（记录由播放内核自动写入）
        Row() {
          Text('🕘')
            .fontSize(20)
            .fontColor($r('app.color.bili_pink'))
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor($r('app.color.brand_surface'))
            .textAlign(TextAlign.Center)
          Column() {
            Text('最近播放')
              .fontSize(16)
              .fontColor($r('app.color.text_primary'))
            Text(this.recentCount > 0 ? `${this.recentCount} 首` : '暂无播放记录')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 4 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 12 })
          Text('›')
            .fontSize(20)
            .fontColor($r('app.color.text_disabled'))
            .margin({ right: 8 })
        }
        .width('100%')
        .padding({ left: 16, right: 12, top: 12, bottom: 12 })
        .onClick((): void => {
          NavStackHolder.stack.pushPath({ name: 'Recent' });
        })

        Row() {
          Text('我的歌单')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Blank()
            .layoutWeight(1)
          Button('新建', { type: ButtonType.Capsule })
            .fontSize(13)
            .backgroundColor($r('app.color.bili_pink'))
            .fontColor($r('app.color.brand_on'))
            .onClick((): void => {
              this.openCreate();
            })
        }
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })

        if (this.playlists.length === 0) {
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
        } else {
          List() {
            ForEach(
              this.playlists,
              (p: Playlist): void => {
                ListItem() {
                  Row() {
                    Image(p.coverUrl && p.coverUrl.length > 0 ? p.coverUrl : '')
                      .width(56)
                      .height(56)
                      .borderRadius(8)
                      .objectFit(ImageFit.Cover)
                      .backgroundColor($r('app.color.bg_divider'))
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
                      .stateStyles({
                        pressed: { .backgroundColor($r('app.color.press_overlay')) },
                        normal: { .backgroundColor(Color.Transparent) }
                      })
                      .onClick((): void => {
                        this.showPlaylistMenu(p);
                      })
                  }
                  .width('100%')
                  .padding({ left: 16, right: 4, top: 10, bottom: 10 })
                  .stateStyles({
                    pressed: { .backgroundColor($r('app.color.press_overlay')) },
                    normal: { .backgroundColor(Color.Transparent) }
                  })
                  .onClick((): void => {
                    NavStackHolder.selectedPlaylistId = p.id;
                    NavStackHolder.stack.pushPath({ name: 'PlaylistDetail' });
                  })
                }
              },
              (p: Playlist): string => p.id
            )
          }
          .layoutWeight(1)
          // 底部悬浮页签让位：列表末尾可滚动至悬浮条上方，不被遮挡
          // 页签栏自己抬高了 safeBottom（见 Index.ets），列表末尾要跟着多让这么多
          .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
        }
      }
      .width('100%')
      .height('100%')
      // 大屏适配：内容列收窄居中（根 Stack 默认居中对齐，挂上限即可）
      .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })

      if (this.showEditor) {
        Column() {
          // 遮罩：点击空白处关闭（ArkUI 中透明容器仍参与命中测试，正好用来吞掉点击）
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.scrim'))
        .onClick((): void => {
          this.showEditor = false;
        })
        .justifyContent(FlexAlign.Center)

        Column() {
          Text(this.editingId.length > 0 ? '重命名歌单' : '新建歌单')
            .fontSize(18)
            .fontColor($r('app.color.text_primary'))
            .margin({ bottom: 14 })
          TextInput({ placeholder: '歌单名称', text: this.editorName })
            .width('100%')
            .onChange((v: string): void => {
              this.editorName = v;
            })
          Row() {
            Button('取消', { type: ButtonType.Normal })
              .layoutWeight(1)
              .height(44)
              .backgroundColor($r('app.color.bg_divider'))
              .fontColor($r('app.color.text_primary'))
              .onClick((): void => {
                this.showEditor = false;
              })
            Button(this.editingId.length > 0 ? '保存' : '创建', { type: ButtonType.Normal })
              .layoutWeight(1)
              .height(44)
              .backgroundColor($r('app.color.bili_pink'))
              .fontColor($r('app.color.brand_on'))
              .margin({ left: 12 })
              .onClick((): void => {
                this.submitEditor();
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
}
