/**
 * 下载页（二级页）标题栏按钮组（下载页重新设计 · 对齐歌单页语言）。
 *
 * 由 DownloadsPage 的 HdsNavDestination titleBar stackBuilder 承载
 * （DownloadsPage.dlBarNarrow → dlBar → dlTrailing）：
 *
 * - 标题行常规态 = [⏸ 队列启停][☑ 选择]（本文件）+ [⋮ 下载设置]（页面 dlTrailing 内联），
 *   三枚 36×36 图标钮（36×36 / 圆角 10 / themeSurface 浅底 + themePrimary 18 号图标，
 *   PlTitleActions 同规格）；
 * - DlQueueActions：二态单按钮解「两个粉字分不清能不能点」——
 *   有进行中/排队 → pause_fill（全部暂停）；无进行中、有暂停 → play_fill（全部开始）；
 *   两者皆无 → play_fill 置灰（bg_divider 底 + text_disabled 图标，点击无响应）；
 * - DlSelectToggle：常规态 list_checkmark 图标钮进入多选；多选态变身
 *   [全选][完成][⋮]，重试 / 加入歌单 / 删除收进 ⋮ 菜单（enabled 门控置灰，
 *   页面方法内 toast 校验保留作第二道兜底），标题行左侧由页面渲染「已选 N」。
 *
 * - 状态：不读页面 @State（跨组件不可见），统一 @StorageProp 订阅
 *   DownloadsPage 推到 AppStorage 的镜像键（STORE_DL_BAR_*，唯一写入口
 *   DownloadsPage.syncBarState / refreshQueueFlags）。
 * - 动作：经 TabScrollerHolder 静态回调转交页面私有方法执行（页面注册）。
 * - ⚠️ ⋮ 菜单必须用 bindMenu **isShow 态驱动重载**（API 11）：宿主 Button
 *   自带 onClick 手势，无 isShow 的重载靠「点击锚点」触发，子节点赢得
 *   手势仲裁后菜单收不到点击（UpSpacePage 真机实测结论）；
 *   onDisappear 复位开关，否则第二次点击 true→true 无变化、菜单弹不出
 *   （PlTitleActions 同款，见 PlaylistsTabBar 文件头）。
 */

import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import { ButtonMaterialModifier, makeButtonMaterialModifier } from '../utils/HeaderBarMaterial';
import {
  STORE_DL_BAR_SELECTING,
  STORE_DL_BAR_ALL_SELECTED,
  STORE_DL_BAR_SELECTED_COUNT,
  STORE_DL_BAR_CAN_RETRY,
  STORE_DL_BAR_QUEUE_ACTIVE,
  STORE_DL_BAR_QUEUE_PAUSED,
  STORE_DOWNLOAD_PAUSED,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE
} from '../common/Constants';

/** 多选动作组淡入淡出时长 */
const DL_SELECT_FADE_MS: number = 250;

/**
 * 标题行「选择」按钮 + 多选动作组（DownloadsPage.dlTrailing 槽入）。
 * 常规态：36×36 list_checkmark 图标钮（进入多选）；
 * 多选态：[全选][完成][⋮ 菜单]（重试 / 加入歌单 / 删除收进 ⋮，enabled 门控），
 * 保留 250ms OPACITY 进出过渡（否则多选进出「闪一下」）。
 * 有任务才显示，可见性由 DownloadsPage.dlTrailing 门控（tasks.length）。
 */
@Component
export struct DlSelectToggle {
  @StorageProp(STORE_DL_BAR_SELECTING) selecting: boolean = false;
  /** 全选态：动作组「全选 / 取消全选」文案切换（页面 syncBarState 推送） */
  @StorageProp(STORE_DL_BAR_ALL_SELECTED) allSelected: boolean = false;
  /** 已选数量：多选 ⋮ 菜单「加入歌单 / 删除」置灰门控（页面 syncBarState 推送） */
  @StorageProp(STORE_DL_BAR_SELECTED_COUNT) selectedCount: number = 0;
  /** 任务表存在失败项：多选 ⋮ 菜单「重试」置灰门控（页面 syncBarState 推送） */
  @StorageProp(STORE_DL_BAR_CAN_RETRY) canRetry: boolean = false;
  /** 主题色运行时值：图标 / 浅底跟随切色刷新 */
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 多选态 ⋮ 菜单开关（isShow 态驱动 bindMenu；onDisappear 复位，见文件头注释） */
  @State selectMenuOpen: boolean = false;

  /**
   * 多选态 ⋮ 菜单项：重试 / 加入歌单 / 删除（原五颗文字按钮收敛）。
   * 置灰比「可点进去再 toast」更早拦住误触；页面方法内的 toast
   * 校验保留作第二道兜底。
   */
  private selectMenuItems(): MenuElement[] {
    return [
      {
        value: '重试',
        enabled: this.canRetry,
        action: (): void => {
          TabScrollerHolder.dlRetrySelected();
        }
      },
      {
        value: '加入歌单',
        enabled: this.selectedCount > 0,
        action: (): void => {
          TabScrollerHolder.dlAddSelectedToPlaylist();
        }
      },
      {
        value: '删除',
        enabled: this.selectedCount > 0,
        action: (): void => {
          TabScrollerHolder.dlRemoveSelected();
        }
      }
    ];
  }

  build() {
    if (this.selecting) {
      // 多选动作组：[全选][完成][⋮]（左侧「已选 N」标题由页面 dlBar 渲染）。
      // 破坏性的删除收进 ⋮ 菜单，360 档窄屏不再溢出（264 ≤ 360）。
      Row({ space: 8 }) {
        Button(this.allSelected ? '取消全选' : '全选', { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .padding({ left: 10, right: 10 })
          .backgroundColor(this.themeSurface)
          .fontColor(this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          .onClick((): void => {
            TabScrollerHolder.dlToggleSelectAll();
          })
        Button('完成', { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .padding({ left: 10, right: 10 })
          .backgroundColor(this.themeSurface)
          .fontColor(this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          .onClick((): void => {
            TabScrollerHolder.dlToggleSelecting();
          })
        Button() {
          SymbolGlyph($r('sys.symbol.more'))
            .fontSize(18)
            .fontColor([this.themePrimary])
        }
        .type(ButtonType.Normal)
        .width(36)
        .height(36)
        .borderRadius(10)
        .backgroundColor(this.themeSurface)
        .attributeModifier(this.buttonMaterial)
        .accessibilityText('多选操作菜单')
        .accessibilityLevel('yes')
        .onClick((): void => {
          this.selectMenuOpen = true;
        })
        .bindMenu(this.selectMenuOpen, this.selectMenuItems(), {
          // placement 必须显式 BottomRight：默认 BottomLeft 以锚点左缘向右展开，
          // ⋮ 在标题行右缘必超屏 → 走「自动调整」路径，菜单跑到左边弹出
          //（PlaylistsTabBar / AppearanceSettingsPage 菜单同款结论）
          placement: Placement.BottomRight,
          onDisappear: (): void => {
            this.selectMenuOpen = false;
          }
        })
      }
      .transition(TransitionEffect.OPACITY
        .animation({ duration: DL_SELECT_FADE_MS, curve: Curve.EaseInOut }))
    } else {
      Button() {
        SymbolGlyph($r('sys.symbol.list_checkmark'))
          .fontSize(18)
          .fontColor([this.themePrimary])
      }
      .type(ButtonType.Normal)
      .width(36)
      .height(36)
      .borderRadius(10)
      .backgroundColor(this.themeSurface)
      .attributeModifier(this.buttonMaterial)
      .accessibilityText('选择下载任务')
      .accessibilityLevel('yes')
      .onClick((): void => {
        TabScrollerHolder.dlToggleSelecting();
      })
    }
  }
}

/**
 * 标题行队列启停（DownloadsPage.dlTrailing 槽入，多选态让位）。
 * 二态单按钮（解「两个粉字分不清能不能点」）：
 *
 * | 队列状态                                   | 图标        | 底色          | 点击       |
 * | 有进行中 / 排队中（DOWNLOADING/PENDING）  | pause_fill | themeSurface | 全部暂停   |
 * | 无进行中、有已暂停（含队列级暂停）         | play_fill  | themeSurface | 全部开始   |
 * | 两者皆无（全完成/全失败）                  | play_fill  | 置灰         | 无响应     |
 *
 * 置灰态必须保留可用性表达（bg_divider 底 + text_disabled 图标），
 * 否则用户会反复点一个不响的按钮。
 */
@Component
export struct DlQueueActions {
  @StorageProp(STORE_DL_BAR_QUEUE_ACTIVE) queueActive: boolean = false;
  @StorageProp(STORE_DL_BAR_QUEUE_PAUSED) queueHasPaused: boolean = false;
  @StorageProp(STORE_DOWNLOAD_PAUSED) queuePaused: boolean = false;
  /** 主题色运行时值：图标 / 浅底跟随切色刷新 */
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();

  build() {
    // 单节点二态：if/else 只切图标 child，按钮壳保持同节点（状态切换无重挂载）
    Button() {
      if (this.queueActive) {
        SymbolGlyph($r('sys.symbol.pause_fill'))
          .fontSize(18)
          .fontColor([this.themePrimary])
      } else {
        SymbolGlyph($r('sys.symbol.play_fill'))
          .fontSize(18)
          .fontColor([this.queuePaused || this.queueHasPaused
            ? this.themePrimary : $r('app.color.text_disabled')])
      }
    }
    .type(ButtonType.Normal)
    .width(36)
    .height(36)
    .borderRadius(10)
    .backgroundColor(this.queueActive || this.queuePaused || this.queueHasPaused
      ? this.themeSurface : $r('app.color.bg_divider'))
    .attributeModifier(this.buttonMaterial)
    .accessibilityText(this.queueActive ? '全部暂停' : '全部开始')
    .accessibilityLevel('yes')
    // 置灰态点击无响应、无语义（不是「点了弹提示」）：守卫直接空转
    .onClick((): void => {
      if (this.queueActive) {
        TabScrollerHolder.dlPauseAll();
        return;
      }
      if (this.queuePaused || this.queueHasPaused) {
        TabScrollerHolder.dlResumeAll();
      }
    })
  }
}
