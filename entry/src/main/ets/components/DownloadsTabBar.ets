/**
 * 下载页顶栏内容（HarmonyX 根栏移植，2026-10-10；留白整改同日）。
 *
 * 标题行按钮 + 多选工具条都由根 HdsNavigation titleBar 的 stackBuilder 承载
 * （Index.immersiveTitleBarContent 下载页分支）——bottomBuilder 槽退役，
 * 工具条随滚动跳动的根因从物理上消除。留白整改起对齐歌单页节奏：
 *
 * - 标题行（行 1，Index.tabTitleRow 下载页分支）：
 *   · DlSelectToggle：「选择 / 完成」；
 *   · DlQueueActions（留白整改新增）：常规态队列控制「全部开始 / 全部暂停」
 *     并入标题行——原先占行 2 的 44vp 常驻工具条退役，首条让位 100→56、
 *     与歌单页同节奏；「已暂停」角标随之退役（启停状态由按钮可用态表达）。
 * - 多选工具条（行 2，DlControlBar）：只在多选态渲染（Index 侧 dlSelecting
 *   门控，position 溢出渲染到标题栏下方），全选 / 重试选中 / 删除选中。
 *
 * - 状态：不读页面 @State（跨组件不可见），统一 @StorageProp 订阅
 *   DownloadsPage 推到 AppStorage 的镜像键（STORE_DL_BAR_*，唯一写入口
 *   DownloadsPage.syncBarState / refreshQueueFlags）。
 * - 动作：经 TabScrollerHolder 静态回调转交页面私有方法执行（页面注册）。
 * - 视觉：按钮与页面原 builder 逐字同款语言（13fp 字号、32 按钮高、按压态、
 *   禁用色），保证「换容器不换观感」。
 */

import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import { ButtonMaterialModifier, makeButtonMaterialModifier } from '../utils/HeaderBarMaterial';
import {
  STORE_DL_BAR_SELECTING,
  STORE_DL_BAR_ALL_SELECTED,
  STORE_DL_BAR_CAN_RETRY,
  STORE_DL_BAR_SELECTED_COUNT,
  STORE_DL_BAR_QUEUE_ACTIVE,
  STORE_DL_BAR_QUEUE_PAUSED,
  STORE_DOWNLOAD_PAUSED,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE,
  STORE_THEME_DEEP
} from '../common/Constants';

/**
 * 标题行右侧「选择 / 完成」按钮（Index.tabTitleRow 下载页分支槽入）。
 * 有任务才显示，可见性由 Index 侧门控（activeTab + dlBarHasTasks 镜像）。
 */
@Component
export struct DlSelectToggle {
  @StorageProp(STORE_DL_BAR_SELECTING) selecting: boolean = false;
  /** 主题色运行时值：按钮浅底 / 粉字跟随切色刷新 */
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();

  build() {
    Button(this.selecting ? '完成' : '选择', { type: ButtonType.Normal })
      .fontSize(13)
      .height(32)
      .borderRadius(BUTTON_RADIUS_VP)
      // 2026-10-11 真机要求：标题行按钮统一「浅粉底 + 粉字」（原粉底 + 深枣红字）
      .backgroundColor(this.themeSurface)
      .fontColor(this.themePrimary)
      .attributeModifier(this.buttonMaterial)
      .onClick((): void => {
        TabScrollerHolder.dlToggleSelecting();
      })
  }
}

/**
 * 标题行队列控制（留白整改新增，Index.tabTitleRow 下载页分支槽入，
 * 常规态显示、多选态让位给「完成」）：
 * 「全部开始」可用的前提是有暂停任务（全局暂停或单条暂停），
 * 「全部暂停」可用的前提是有进行中任务——可用态与原行 2 工具条逐字同逻辑。
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
        // 2026-10-11 真机要求：字色**无条件**品牌粉（与「搜索 / 新建 / 选择」一致，
        // 不再随可用态在「粉 ↔ 灰」之间变）；可用性改由底色表达（浅粉底 = 可用，
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
      // ⚠️ 「全部暂停」此前是**唯一**既不着粉、也没有光感材质的按钮（真机反馈：与
      // 隔壁「全部开始」不是一套观感）—— 补齐 attributeModifier，字色同样无条件品牌粉，
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

/**
 * 多选工具条（根栏 stackBuilder 行 2：Index 侧 position 溢出渲染，
 * dlSelecting 态渲染，全选 / 重试选中 / 删除选中）。
 * 留白整改起只在多选态出现（原常规态「全部开始 / 全部暂停」迁标题行
 * DlQueueActions）。纯内容件：磨砂由根栏 HDS 统一负责（仅覆盖标题栏区，
 * 本行无背板）。内容与原 bottomBuilder 版逐字平移。
 */
@Component
export struct DlControlBar {
  @StorageProp(STORE_DL_BAR_ALL_SELECTED) allSelected: boolean = false;
  @StorageProp(STORE_DL_BAR_CAN_RETRY) canRetry: boolean = false;
  @StorageProp(STORE_DL_BAR_SELECTED_COUNT) selectedCount: number = 0;
  /** 主题色深字色：工具条动作文字跟随切色刷新 */
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';

  build() {
    Row() {
      Text(this.allSelected ? '取消全选' : '全选')
        .fontSize(13)
        .fontColor(this.themeDeep)
        .height(44)
        .padding({ left: 16, right: 12 })
        .borderRadius(8)
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.press_overlay')) },
          normal: { .backgroundColor(Color.Transparent) }
        })
        .onClick((): void => {
          TabScrollerHolder.dlToggleSelectAll();
        })
      Blank()
      // 批量重试：只对选中的**失败**项生效（非失败项会被 retryTasks 跳过）
      Text('重试选中')
        .fontSize(13)
        .fontColor(this.canRetry ? this.themeDeep : $r('app.color.text_disabled'))
        .height(44)
        .padding({ left: 12, right: 12 })
        .borderRadius(8)
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.press_overlay')) },
          normal: { .backgroundColor(Color.Transparent) }
        })
        .onClick((): void => {
          TabScrollerHolder.dlRetrySelected();
        })
      Text(this.selectedCount > 0 ? `删除选中(${this.selectedCount})` : '删除选中')
        .fontSize(13)
        .fontColor(this.selectedCount > 0 ? $r('app.color.state_error') : $r('app.color.text_disabled'))
        .height(44)
        .padding({ left: 12, right: 16 })
        .borderRadius(8)
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.press_overlay')) },
          normal: { .backgroundColor(Color.Transparent) }
        })
        .onClick((): void => {
          TabScrollerHolder.dlRemoveSelected();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}
