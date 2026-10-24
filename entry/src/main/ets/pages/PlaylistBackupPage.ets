/**
 * 歌单备份页（2026-10-24 设置页二级菜单化改造）：
 * 原设置页「歌单备份」卡整体迁入本二级页，行序与逻辑原样保留。
 *
 * 内容：导出歌单到剪贴板 / 从剪贴板导入歌单（经 PasteButton 安全控件授权）/
 * 从网易云 · QQ 音乐导入（跳 'PlaylistImport' 路由）+ 脚注说明。
 *
 * 解决的真实痛点：歌单只存在 Preferences 里，**清数据 / 换机即丢**。
 * 导出剥掉 localFilePath、导入逐首 slimTrack（见 LibraryStore 的注释）。
 *
 * 剪贴板授权弹窗（PasteImportDialog）保留原实现：HarmonyOS 要求读取剪贴板
 * 必须经系统安全控件 PasteButton 显式授权，普通 onClick 静默读会被拦截
 * （getData 只拿到空串，真机两次复现）。行点击弹本窗，窗内放系统粘贴按钮，
 * 点它完成授权 + 读取。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，AboutPage 同款骨架）。
 */

import {
  CONTENT_END_OFFSET,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY,
  STORE_THEME_ON
} from '../common/Constants';
import { Playlist } from '../model/MusicModels';
import { NavStackHolder } from '../service/NavStackHolder';
import { LibraryStore, PlaylistImportResult } from '../service/LibraryStore';
import { copyText, readText } from '../utils/ClipboardUtil';
import { showAppToast } from '../components/AppToast';
import { showAppAlertDialog } from '../components/AppAlertDialog';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { TwoColumnLayout } from '../common/utils/TwoColumnList';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { InsetCard, CardDivider, SectionFooter } from '../components/InsetCardGroup';
import { HdsListItemCard, SuffixArrowIconText } from '@kit.UIDesignKit';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';

/**
 * 剪贴板导入授权弹窗（2026-10-16，用户选择的折中方案）。
 *
 * 为什么不塞进 AppAlertDialog：那是「纯文本 + 双按钮」的固定版式（20+ 调用点
 * 共用），安全控件需要专属回调与样式约束，混入会把公共组件改得面目全非。
 * controller 声明与注入遵循 AppAlertDialog.ets 注释里的官方口径
 * （@CustomDialog 结构体必须声明 controller? 属性；真正开关由宿主页的
 * CustomDialogController 成员持有 —— 在 @Component 内部定义时赋值才有效）。
 *
 * 视觉沿用旧版确认弹窗的自绘语言：bg_card 底 + 24 圆角 + 主题色文字。
 */
@CustomDialog
struct PasteImportDialog {
  /** 编译器硬性要求（10905211）：@CustomDialog 结构体必须声明 controller 属性；实际开关走宿主页的 controller */
  controller?: CustomDialogController;
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /** 授权成功回调：宿主页注入（关弹窗 → confirmImportPlaylists 读剪贴板） */
  onPasteGranted: () => void = (): void => {};

  build() {
    Column() {
      Column() {
        Text('从剪贴板导入歌单')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.themePrimary)
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text('系统要求先授权才能读取剪贴板，点击下方「粘贴」继续')
          .fontSize(13)
          .fontColor(this.themePrimary)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
          .width('100%')
        // 系统粘贴按钮（安全控件，全局组件无需 import）：
        // ⚠️ 不能对安全控件挂 .margin()，用包装 Row 承载间距；
        // 授权校验红线：文字必须完整显示、前景与背景对比度不能过低
        // （themePrimary 底 + themeOn 字 ≈ 6.4:1，满足）。
        Row() {
          PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
            .fontSize(14)
            .iconSize(16)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .backgroundColor(this.themePrimary)
            .fontColor(this.themeOn)
            .iconColor(this.themeOn)
            .onClick((event: ClickEvent, result: PasteButtonOnClickResult): void => {
              // 先关弹窗再走业务：confirmImportPlaylists 里的确认弹窗 / toast
              // 不会被本弹层盖住。授权令牌不受弹窗关闭影响（授权在点击瞬间生效）。
              this.controller?.close();
              if (result === PasteButtonOnClickResult.SUCCESS) {
                this.onPasteGranted();
              } else {
                showAppToast('剪贴板授权失败，请重试', 1800);
              }
            })
        }
        .width('100%')
        .margin({ top: 24 })
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 24, bottom: 20 })

      Divider()
        .color($r('app.color.bg_divider'))

      Text('取消')
        .fontSize(16)
        .fontColor(this.themePrimary)
        .textAlign(TextAlign.Center)
        .height(48)
        .width('100%')
        .onClick((): void => {
          this.controller?.close();
        })
    }
    .width('86%')
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(24)
    .clip(true)
  }
}

@Component
export struct PlaylistBackupPage {
  /** 状态栏高度（vp）：HDS 标题栏 avoidLayoutSafeArea 后栏顶 = safeTop，内容让位量要含它 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：内容末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 当前横竖屏（Index 常驻注册写入）：内容列 840 口径取值用 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;
  /** 滚动控制器：bindToScrollable 绑给 HDS 标题栏，滚动模糊效果依赖此绑定 */
  private pageScroller: Scroller = new Scroller();

  /** 子页转场的横移量（相对页面自身宽度）：转场代理里按 push/pop 方向临时改写 */
  @State navTransX: string = '0%';

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /**
   * 「标题 + 箭头」行（导出 / 导入两行共用）：
   * 行内提示词只留标题 + 箭头，语义靠标题本身与脚注。
   */
  @Builder
  SettingsRow(title: string, onTap: () => void): void {
    HdsListItemCard({
      textItem: { primaryText: { text: title } },
      suffixItem: new SuffixArrowIconText({ endArrow: {} }),
      cardBackgroundColor: Color.Transparent,
      cardPrefixMargin: 0,
      cardSuffixMargin: 0,
      onClick: (): void => {
        onTap();
      }
    })
      .accessibilityText(title)
      .accessibilityLevel('yes')
  }

  /** 导出：把全部歌单序列化后写进剪贴板 */
  private async exportPlaylists(): Promise<void> {
    const playlists: Playlist[] = LibraryStore.getPlaylists();
    if (playlists.length === 0) {
      this.toast('还没有歌单可以导出', 1800);
      return;
    }
    const text: string = JSON.stringify(LibraryStore.createPlaylistsExport());
    const ok: boolean = await copyText(text);
    if (!ok) {
      this.toast('写入剪贴板失败，请重试', 1800);
      return;
    }
    const tracks: number = playlists.reduce((sum: number, p: Playlist): number => sum + p.tracks.length, 0);
    this.toast(`已复制 ${playlists.length} 个歌单（${tracks} 首）到剪贴板`, 2200);
  }

  /**
   * 剪贴板授权弹窗 controller（2026-10-16）：⚠️ 必须在 @Component 内部定义时
   * 赋值才有效（官方约束，模块级定义会「编译过、open 不显示」的静默失效），
   * 且一经创建不能重新赋值（会导致旧弹窗关不掉）。
   * 授权成功回调链：PasteButton SUCCESS → 关弹窗 → confirmImportPlaylists。
   */
  private pasteDialogCtrl: CustomDialogController = new CustomDialogController({
    builder: PasteImportDialog({
      onPasteGranted: (): void => {
        this.confirmImportPlaylists();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  /**
   * 导入：先读剪贴板看有没有像歌单数据，有则二次确认再落库。
   *
   * 为什么要确认：剪贴板里可能**完全不是**歌单数据（用户刚复制了段文字），
   * 直接 import 会抛 JSON 解析错、用户一头雾水。先看内容再决定。
   */
  private async confirmImportPlaylists(): Promise<void> {
    const text: string = await readText();
    if (text.trim().length === 0) {
      this.toast('剪贴板是空的', 1800);
      return;
    }
    // 只做「像不像」的判断，不真解析：真解析留给 importPlaylistsFromText（它才有完整的
    // 容错与跳过统计）。这里解析失败 → 不是歌单数据，别让用户点完才报错。
    // ⚠️ `JSON.parse` 返回 any，ArkTS 禁止隐式 any（arkts-no-any-unknown）→
    // 必须显式收成 `ESObject`，再 `Array.isArray` 收窄。
    let count: number = -1;
    try {
      const parsed: ESObject = JSON.parse(text);
      const list: ESObject = Array.isArray(parsed) ? parsed : parsed?.playlists;
      if (Array.isArray(list)) {
        count = list.length;
      }
    } catch (e) {
      console.warn(`import clipboard is not json: ${e instanceof Error ? e.message : 'unknown'}`);
    }
    if (count < 0) {
      this.toast('剪贴板里不是歌单数据（需要先「导出歌单」）', 2200);
      return;
    }
    showAppAlertDialog(this.getUIContext(), {
      title: '导入歌单',
      message: `剪贴板里解析到 ${count} 个歌单，将追加到现有歌单列表（重名自动加「导入」后缀）。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '导入',
        action: (): void => {
          this.doImportPlaylists(text);
        }
      }
    });
  }

  private doImportPlaylists(text: string): void {
    try {
      const r: PlaylistImportResult = LibraryStore.importPlaylistsFromText(text);
      if (r.imported === 0 && r.skipped === 0) {
        this.toast('没有可导入的歌单', 1800);
        return;
      }
      const tail: string = r.skipped > 0 ? `，跳过 ${r.skipped} 个无效条目` : '';
      this.toast(`已导入 ${r.imported} 个歌单${tail}`, 2400);
    } catch (e) {
      const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.error(`import playlists failed: ${detail}`);
      this.toast('导入失败：数据格式不正确', 2000);
    }
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut（AboutPage 同款）。
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

  /** 标题栏内容（titleBar 的 stackBuilder 承载）：「歌单备份」标题（返回键为 HDS 默认键） */
  @Builder
  backupBar() {
    NavTitleRow({ title: '歌单导入' })
  }

  /**
   * 标题行收窄容器（AboutPage 同款）：外层 Row 居中 + 内层 Column constraintSize
   * （上限与本页内容列同口径），大屏上标题行与内容列同宽对齐；
   * 两侧空白区 hitTestBehavior(Transparent) 穿透点击。
   */
  @Builder
  backupBarNarrow() {
    Row() {
      Column() {
        this.backupBar()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  build() {
    HdsNavDestination() {
      List({ scroller: this.pageScroller }) {
        // 顶部空白占位条目（官方沉浸口径）：高度 = safeTop + 56（MINI 标题栏），
        // 静止位首个真实条目恰从栏底起排，滚动时从材质下方穿过。
        ListItem() {
          Row()
            .width('100%')
            .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)
        }

        ListItem() {
          InsetCard() {
            this.SettingsRow('导出歌单到剪贴板', (): void => {
              this.exportPlaylists();
            })
            CardDivider()
            // 2026-10-16（真机两次复现）：普通行点击后静默读剪贴板被系统拦截
            // （getData 只拿到空串），HarmonyOS 强制要求经安全控件 PasteButton
            // 授权。改为：点击本行 → 弹 PasteImportDialog（窗内系统粘贴按钮）→
            // 点「粘贴」授权 → confirmImportPlaylists 读剪贴板并二次确认落库。
            this.SettingsRow('从剪贴板导入歌单', (): void => {
              this.pasteDialogCtrl.open();
            })
            CardDivider()
            // 跨平台导入（网易云 / QQ 音乐）：本 App 自产自销的 JSON 备份管不了
            // 「歌在别的平台」的场景，这条链路负责搜 B 站音源并建单（方案见 design/
            // 歌单导入方案-网易云与QQ音乐.md）。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '从网易云 / QQ 音乐导入' },
                secondaryText: { text: '粘贴歌单链接或歌曲列表' }
              },
              suffixItem: new SuffixArrowIconText({ endArrow: {} }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                NavStackHolder.stack.pushPath({ name: 'PlaylistImport' });
              }
            })
              .accessibilityText('从网易云 / QQ 音乐导入')
              .accessibilityLevel('yes')
          }
        }
        ListItem() {
          SectionFooter({ noteText: '导出的文本里不含音频直链与本机路径，导入后首次播放需要重新联网解析' })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
      // 边界回弹：到顶/到底的反馈动效
      .edgeEffect(EdgeEffect.Spring)
      .cachedCount(10)
      // 底部让位：列表末尾可滚动至手势区上方，不被遮挡
      .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
      // 大屏适配：内容列收窄居中（与原设置页同口径走 TwoColumnLayout.contentMaxWidth）
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
    }
    // HDS 沉浸光感标题栏：材质 / 滚动模糊 / 温控统一由 HdsTitleBarStyle 决策
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(),
      content: {
        // 箭头包裹保证 builder 内 this 指向本组件（裸引用会丢失 this）
        stackBuilder: (): void => {
          this.backupBarNarrow();
        }
      }
    })
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页滚动容器交给 HDS 联动
    .bindToScrollable([this.pageScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 系统返回拦截（播放页 overlay 打开时吞掉返回，否则走默认 pop）
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让（官方组件级沉浸口径，AboutPage 同款）；内容层避让由 plain padding 自理
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 经动态 import 后用 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function PlaylistBackupPageBuilder(): void {
  PlaylistBackupPage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接 @Builder 引用（编译期校验）。 */
export const PlaylistBackupPageWrapped: WrappedBuilder<[]> = wrapBuilder(PlaylistBackupPageBuilder);
