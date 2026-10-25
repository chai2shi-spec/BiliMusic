/**
 * 歌单页顶栏内容件。
 *
 * - 标题行按钮（PlTitleActions）：根栏 stackBuilder 行 1 歌单页分支右侧槽入
 *   （Index.tabTitleRow）；
 * - 多选工具条（PlSelectToolbar）：根栏 stackBuilder 行 2（Index 侧 position
 *   溢出渲染到标题栏下方，plSelecting 镜像门控），纯内容件——磨砂统一归根栏
 *   HDS（仅覆盖标题栏区，本行无背板，页签行同款行为）。
 *
 * - 状态：@StorageProp 订阅 PlaylistsPage 推到 AppStorage 的镜像键
 *   （STORE_PL_BAR_*，唯一写入口 PlaylistsPage.syncBarState / refresh）。
 * - 动作：经 TabScrollerHolder 静态回调转交页面私有方法（页面注册）。
 * - 视觉：保证「换容器不换观感」
 *   （合并选中左侧为「删除选中」，批量删歌单入口）。
 */

import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import { ButtonMaterialModifier, makeButtonMaterialModifier } from '../utils/HeaderBarMaterial';
import {
  STORE_PL_BAR_SELECTING,
  STORE_PL_BAR_CAN_SELECT,
  STORE_PL_BAR_ALL_SELECTED,
  STORE_PL_BAR_SELECTED_COUNT,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE,
  STORE_THEME_DEEP
} from '../common/Constants';

/**
 * 标题行右侧按钮组（Index.tabTitleRow 歌单页分支槽入）。
 * 多选模式：完成；常规模式：选择（歌单 ≥2 才出现）+ 新建。
 */
@Component
export struct PlTitleActions {
  @StorageProp(STORE_PL_BAR_SELECTING) selecting: boolean = false;
  /** 歌单数 ≥2 才有可合并对象，「选择」才出现（镜像派生，页面 syncBarState 推送） */
  @StorageProp(STORE_PL_BAR_CAN_SELECT) canSelect: boolean = false;
  /** 主题色运行时值：按钮浅底 / 粉字跟随切色刷新 */
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();

  build() {
    if (this.selecting) {
      Button('完成', { type: ButtonType.Normal })
        .fontSize(13)
        .height(32)
        .borderRadius(BUTTON_RADIUS_VP)
        // 标题行按钮统一「浅粉底 + 粉字」
        .backgroundColor(this.themeSurface)
        .fontColor(this.themePrimary)
        .attributeModifier(this.buttonMaterial)
        .onClick((): void => {
          TabScrollerHolder.plToggleSelecting();
        })
    } else {
      if (this.canSelect) {
        // 「选择」与同排其它按钮同一套视觉语言（浅粉底 + 粉字 + 光感材质）
        Button('选择', { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .backgroundColor(this.themeSurface)
          .fontColor(this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          .margin({ right: 8 })
          .onClick((): void => {
            TabScrollerHolder.plToggleSelecting();
          })
      }
      Button('新建', { type: ButtonType.Normal })
        .fontSize(13)
        .height(32)
        .borderRadius(BUTTON_RADIUS_VP)
        .backgroundColor(this.themeSurface)
        .fontColor(this.themePrimary)
        .attributeModifier(this.buttonMaterial)
        .onClick((): void => {
          TabScrollerHolder.plOpenCreate();
        })
    }
  }
}

/**
 * 多选工具条（根栏 stackBuilder 行 2：Index 侧 position 于标题行下方，
 * plSelecting 态渲染，全宽不随内容列收窄）。
 * 纯内容件：磨砂由根栏 HDS 统一负责（仅覆盖标题栏区，本行无背板）。
 */
@Component
export struct PlSelectToolbar {
  @StorageProp(STORE_PL_BAR_ALL_SELECTED) allSelected: boolean = false;
  @StorageProp(STORE_PL_BAR_SELECTED_COUNT) selectedCount: number = 0;
  /** 主题色深字色：工具条动作文字跟随切色刷新 */
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';

  build() {
    Row() {
      Text(this.allSelected ? '取消全选' : '全选')
        .fontSize(13)
        .fontColor(this.themeDeep)
        .height(44)
        .padding({ left: 20, right: 12 })
        .borderRadius(8)
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.press_overlay')) },
          normal: { .backgroundColor(Color.Transparent) }
        })
        .onClick((): void => {
          TabScrollerHolder.plToggleSelectAll();
        })
      Blank()
      // 删除选中（合并左侧）：破坏性操作，用错误色与合并区分；
      // 一个都没选时置灰，点了由页面兜底提示。
      Text(this.selectedCount > 0 ? `删除选中(${this.selectedCount})` : '删除选中')
        .fontSize(13)
        .fontColor(this.selectedCount > 0 ? $r('app.color.state_error') : $r('app.color.text_disabled'))
        .height(44)
        .padding({ left: 12, right: 12 })
        .borderRadius(8)
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.press_overlay')) },
          normal: { .backgroundColor(Color.Transparent) }
        })
        .onClick((): void => {
          TabScrollerHolder.plDeleteSelected();
        })
      // 少于两个无法合并：置灰，点了只给一句提示（openMergeEditor 里兜）
      Text(this.selectedCount > 0 ? `合并选中(${this.selectedCount})` : '合并选中')
        .fontSize(13)
        .fontColor(this.selectedCount >= 2 ? this.themeDeep : $r('app.color.text_disabled'))
        .height(44)
        .padding({ left: 12, right: 20 })
        .borderRadius(8)
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.press_overlay')) },
          normal: { .backgroundColor(Color.Transparent) }
        })
        .onClick((): void => {
          TabScrollerHolder.plOpenMergeEditor();
        })
    }
    .width('100%')
    .height(44)
    .alignItems(VerticalAlign.Center)
  }
}
