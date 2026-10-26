/**
 * 歌单页顶栏内容件。
 *
 * - 标题行按钮（PlTitleActions）：根栏 stackBuilder 行 1 歌单页分支右侧槽入
 *   （Index.tabTitleRow）；多选态在标题行内渲染动作组（完成 / 全选 / 删除选中 /
 *   合并选中），样式与歌单详情页多选按钮逐字一致；「歌单」标题保留
 *   （layoutWeight(1) 把动作组挤到标题行右侧）。
 *
 * - 状态：@StorageProp 订阅 PlaylistsPage 推到 AppStorage 的镜像键
 *   （STORE_PL_BAR_*，唯一写入口 PlaylistsPage.syncBarState / refresh）。
 * - 动作：经 TabScrollerHolder 静态回调转交页面私有方法（页面注册）。
 * - 视觉：多选动作按钮与 PlaylistDetail 多选层同款
 *   （合并选中左侧为「删除选中」，批量删歌单入口）。
 */

import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import { ButtonMaterialModifier, makeButtonMaterialModifier } from '../utils/HeaderBarMaterial';
import {
  STORE_PL_BAR_SELECTING,
  STORE_PL_BAR_CAN_SELECT,
  STORE_PL_BAR_ALL_SELECTED,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE
} from '../common/Constants';

/** 多选动作组淡入淡出时长：与 PlaylistDetail 的 PD_SELECT_FADE_MS 一致 */
const PL_SELECT_FADE_MS: number = 250;

/**
 * 标题行右侧按钮组（Index.tabTitleRow 歌单页分支槽入）。
 * 多选模式：完成 + 全选 + 删除选中 + 合并选中（「歌单」标题此时被摘出）；
 * 常规模式：选择（歌单 ≥2 才出现）+ 新建。
 */
@Component
export struct PlTitleActions {
  @StorageProp(STORE_PL_BAR_SELECTING) selecting: boolean = false;
  /** 歌单数 ≥2 才有可合并对象，「选择」才出现（镜像派生，页面 syncBarState 推送） */
  @StorageProp(STORE_PL_BAR_CAN_SELECT) canSelect: boolean = false;
  /** 全选态：多选动作组「全选 / 取消全选」文案切换（页面 syncBarState 推送） */
  @StorageProp(STORE_PL_BAR_ALL_SELECTED) allSelected: boolean = false;
  /** 主题色运行时值：按钮浅底 / 粉字跟随切色刷新 */
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();

  build() {
    if (this.selecting) {
      // 多选动作组：整行让位（标题已摘出），顺序对齐歌单详情页多选态 ——
      // 退出键在前、动作组随后；破坏性的删除放合并之前。
      // 不带计数、不置灰（PlaylistDetail 同款：空选区由页面 toast 兜底）。
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
            TabScrollerHolder.plToggleSelecting();
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
            TabScrollerHolder.plToggleSelectAll();
          })
        Button('删除选中', { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .padding({ left: 10, right: 10 })
          .backgroundColor(this.themeSurface)
          .fontColor(this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          .onClick((): void => {
            TabScrollerHolder.plDeleteSelected();
          })
        Button('合并选中', { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .padding({ left: 10, right: 10 })
          .backgroundColor(this.themeSurface)
          .fontColor(this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          .onClick((): void => {
            TabScrollerHolder.plOpenMergeEditor();
          })
      }
      .transition(TransitionEffect.OPACITY
        .animation({ duration: PL_SELECT_FADE_MS, curve: Curve.EaseInOut }))
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
