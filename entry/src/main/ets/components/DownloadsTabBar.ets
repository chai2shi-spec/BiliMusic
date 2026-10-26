/**
 * 下载页顶栏内容。
 *
 * 标题行按钮由根 HdsNavigation titleBar 的 stackBuilder 承载
 * （Index.immersiveTitleBarContent 下载页分支），对齐歌单页节奏：
 *
 * - 标题行（行 1，Index.tabTitleRow 下载页分支）：
 *   · DlSelectToggle：常规态「选择」；多选态变身动作组
 *     （完成 / 全选 / 重试 / 加入歌单 / 删除），「下载」标题保留，
 *     动作组靠标题行右侧，PlaylistDetail 多选按钮同款胶囊样式；
 *   · DlQueueActions：常规态队列控制「全部开始 / 全部暂停」并入标题行
 *     （启停状态由按钮可用态表达），多选态让位。
 *
 * - 状态：不读页面 @State（跨组件不可见），统一 @StorageProp 订阅
 *   DownloadsPage 推到 AppStorage 的镜像键（STORE_DL_BAR_*，唯一写入口
 *   DownloadsPage.syncBarState / refreshQueueFlags）。
 * - 动作：经 TabScrollerHolder 静态回调转交页面私有方法执行（页面注册）。
 * - 视觉：13fp 字号、32 按钮高、按压态，与歌单页同款语言。
 */

import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import { ButtonMaterialModifier, makeButtonMaterialModifier } from '../utils/HeaderBarMaterial';
import {
  STORE_DL_BAR_SELECTING,
  STORE_DL_BAR_ALL_SELECTED,
  STORE_DL_BAR_QUEUE_ACTIVE,
  STORE_DL_BAR_QUEUE_PAUSED,
  STORE_DOWNLOAD_PAUSED,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE
} from '../common/Constants';

/** 多选动作组淡入淡出时长：与 PlaylistDetail 的 PD_SELECT_FADE_MS 一致 */
const DL_SELECT_FADE_MS: number = 250;

/**
 * 标题行右侧按钮组（Index.tabTitleRow 下载页分支槽入）。
 * 常规态「选择」；多选态变身动作组（完成 / 全选 / 重试 / 加入歌单 / 删除），
 * 「下载」标题保留、动作组靠标题行右侧（歌单页同款节奏）。
 * 有任务才显示，可见性由 Index 侧门控（activeTab + dlBarHasTasks 镜像）。
 */
@Component
export struct DlSelectToggle {
  @StorageProp(STORE_DL_BAR_SELECTING) selecting: boolean = false;
  /** 全选态：动作组「全选 / 取消全选」文案切换（页面 syncBarState 推送） */
  @StorageProp(STORE_DL_BAR_ALL_SELECTED) allSelected: boolean = false;
  /** 主题色运行时值：按钮浅底 / 粉字跟随切色刷新 */
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();

  build() {
    if (this.selecting) {
      // 多选动作组：退出键在前、动作组随后，破坏性的删除放最后
      // （PlaylistDetail 多选层同款顺序）。动作不带计数、不置灰 ——
      // 空选区 / 无失败项由页面 toast 兜底（「还没有选中条目」
      // 「没有失败的任务」，见 DownloadsPage 各动作方法）。
      // 标签用短式（重试 / 删除）：391vp 级窄屏里标题 + 五颗按钮
      // 放不下「重试选中」「删除选中」全称。
      Row({ space: 8 }) {
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
        Button('重试', { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .padding({ left: 10, right: 10 })
          .backgroundColor(this.themeSurface)
          .fontColor(this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          .onClick((): void => {
            TabScrollerHolder.dlRetrySelected();
          })
        Button('加入歌单', { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .padding({ left: 10, right: 10 })
          .backgroundColor(this.themeSurface)
          .fontColor(this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          .onClick((): void => {
            TabScrollerHolder.dlAddSelectedToPlaylist();
          })
        Button('删除', { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .padding({ left: 10, right: 10 })
          .backgroundColor(this.themeSurface)
          .fontColor(this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          .onClick((): void => {
            TabScrollerHolder.dlRemoveSelected();
          })
      }
      .transition(TransitionEffect.OPACITY
        .animation({ duration: DL_SELECT_FADE_MS, curve: Curve.EaseInOut }))
    } else {
      Button('选择', { type: ButtonType.Normal })
        .fontSize(13)
        .height(32)
        .borderRadius(BUTTON_RADIUS_VP)
        // 标题行按钮统一「浅粉底 + 粉字」
        .backgroundColor(this.themeSurface)
        .fontColor(this.themePrimary)
        .attributeModifier(this.buttonMaterial)
        .onClick((): void => {
          TabScrollerHolder.dlToggleSelecting();
        })
    }
  }
}

/**
 * 标题行队列控制（Index.tabTitleRow 下载页分支槽入，
 * 常规态显示、多选态让位给「完成」）：
 * 「全部开始」可用的前提是有暂停任务（全局暂停或单条暂停），
 * 「全部暂停」可用的前提是有进行中任务。
 */
@Component
export struct DlQueueActions {
  @StorageProp(STORE_DL_BAR_QUEUE_ACTIVE) queueActive: boolean = false;
  @StorageProp(STORE_DL_BAR_QUEUE_PAUSED) queueHasPaused: boolean = false;
  @StorageProp(STORE_DOWNLOAD_PAUSED) queuePaused: boolean = false;
  /** 主题色运行时值：按钮浅底 / 粉字跟随切色刷新 */
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();

  build() {
    Row() {
      Button('全部开始', { type: ButtonType.Normal })
        .fontSize(13)
        .height(32)
        .borderRadius(BUTTON_RADIUS_VP)
        // 字色**无条件**品牌粉（与「搜索 / 新建 / 选择」一致）；
        // 可用性由底色表达（浅粉底 = 可用，
        // 灰底 = 当前没有可继续的任务）。
        .backgroundColor(this.queuePaused || this.queueHasPaused
          ? this.themeSurface : $r('app.color.bg_divider'))
        .fontColor(this.themePrimary)
        .attributeModifier(this.buttonMaterial)
        .margin({ left: 8 })
        .onClick((): void => {
          if (this.queuePaused || this.queueHasPaused) {
            TabScrollerHolder.dlResumeAll();
          }
        })
      // 「全部暂停」与「全部开始」同一套观感（attributeModifier + 无条件品牌粉），
      // 可用性只看底色。
      Button('全部暂停', { type: ButtonType.Normal })
        .fontSize(13)
        .height(32)
        .borderRadius(BUTTON_RADIUS_VP)
        .backgroundColor(this.queueActive
          ? this.themeSurface : $r('app.color.bg_divider'))
        .fontColor(this.themePrimary)
        .attributeModifier(this.buttonMaterial)
        .margin({ left: 8 })
        .onClick((): void => {
          if (this.queueActive) {
            TabScrollerHolder.dlPauseAll();
          }
        })
    }
  }
}
