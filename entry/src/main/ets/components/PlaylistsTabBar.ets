/**
 * 歌单页顶栏内容件。
 *
 * - 标题行按钮（PlTitleActions）：根栏 stackBuilder 行 1 歌单页分支右侧槽入
 *   （Index.tabTitleRow）。常规态 = [下载图标][+][⋮] 三枚 36×36 图标钮
 *   （方案A：下载入口从列表第一行移上标题行；「定位 / 选择 / 导入 / 同步 /
 *   排序」收进 ⋮ 菜单）；多选态 = [全选][完成][⋮]，标题行左侧由
 *   Index 渲染「已选 N」。
 * - 状态：@StorageProp 订阅 PlaylistsPage 推到 AppStorage 的镜像键
 *   （STORE_PL_BAR_*，唯一写入口 PlaylistsPage.syncBarState / refresh）。
 * - 动作：经 TabScrollerHolder 静态回调转交页面私有方法（页面注册）；
 *   导入 / 同步是纯路由跳转，组件内直接 NavStackHolder.push。
 * - ⚠️ ⋮ 菜单必须用 bindMenu **isShow 态驱动重载**（API 11）：宿主 Button
 *   自带 onClick 手势，无 isShow 的重载靠「点击锚点」触发，子节点赢得
 *   手势仲裁后菜单收不到点击（UpSpacePage 真机实测结论）；
 *   onDisappear 复位开关，否则第二次点击 true→true 无变化、菜单弹不出。
 */

import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { NavStackHolder } from '../service/NavStackHolder';
import { Track } from '../model/MusicModels';
import { BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import { ButtonMaterialModifier, makeButtonMaterialModifier } from '../utils/HeaderBarMaterial';
import { DownloadsIconButton } from './DownloadsIconButton';
import {
  STORE_PL_BAR_SELECTING,
  STORE_PL_BAR_CAN_SELECT,
  STORE_PL_BAR_ALL_SELECTED,
  STORE_PL_BAR_SELECTED_COUNT,
  STORE_CURRENT_TRACK,
  STORE_THEME_PRIMARY,
  STORE_THEME_ON,
  STORE_THEME_SURFACE
} from '../common/Constants';

/** 多选动作组淡入淡出时长 */
const PL_SELECT_FADE_MS: number = 250;

/**
 * 标题行右侧按钮组（Index.tabTitleRow 歌单页分支槽入）。
 * 常规模式：[↓ 下载角标钮][+ 新建（品牌实底）][⋮ 菜单]；
 * 多选模式：[全选][完成][⋮ 删除/合并菜单]（左侧标题由 Index 显示「已选 N」）。
 */
@Component
export struct PlTitleActions {
  @StorageProp(STORE_PL_BAR_SELECTING) selecting: boolean = false;
  /** 歌单数 ≥2 才有可合并对象，「选择歌单」菜单项才渲染（镜像派生，页面 syncBarState 推送） */
  @StorageProp(STORE_PL_BAR_CAN_SELECT) canSelect: boolean = false;
  /** 全选态：多选「全选 / 取消全选」文案切换（页面 syncBarState 推送） */
  @StorageProp(STORE_PL_BAR_ALL_SELECTED) allSelected: boolean = false;
  /** 已选数量：多选 ⋮ 菜单「删除 / 合并」置灰门控（页面 syncBarState 推送） */
  @StorageProp(STORE_PL_BAR_SELECTED_COUNT) selectedCount: number = 0;
  /** 在播曲目（空 = 没在播）：「定位当前播放」菜单项置灰门控 */
  @StorageProp(STORE_CURRENT_TRACK) currentTrack: Track | null = null;
  /** 主题色运行时值：图标 / 实底 / 浅底跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 常规态 ⋮ 菜单开关（isShow 态驱动 bindMenu；onDisappear 复位，见文件头注释） */
  @State moreMenuOpen: boolean = false;
  /** 多选态 ⋮ 菜单开关（与常规态互斥渲染，各自独立状态防串台） */
  @State selectMenuOpen: boolean = false;

  /**
   * 常规态 ⋮ 菜单项：散落功能收一处（方案A §6.1）。
   * 「定位当前播放」无在播时置灰（不是 toast 兜底 —— 死按钮点不动
   * 比点下去弹提示更诚实）；在播但不在任何歌单的兜底 toast 仍由页面负责。
   */
  private normalMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    if (this.canSelect) {
      items.push({
        value: '选择歌单',
        action: (): void => {
          TabScrollerHolder.plToggleSelecting();
        }
      });
    }
    items.push({
      value: '定位当前播放',
      enabled: this.currentTrack !== null,
      action: (): void => {
        TabScrollerHolder.plLocateCurrent();
      }
    });
    items.push({
      value: '按名称排序全部曲目',
      action: (): void => {
        TabScrollerHolder.plSortAllByTitle();
      }
    });
    items.push({
      value: '取消按名称排序',
      action: (): void => {
        TabScrollerHolder.plClearTitleSorted();
      }
    });
    items.push({
      value: '从网易云 / QQ 音乐导入',
      action: (): void => {
        NavStackHolder.push('PlaylistImport', undefined);
      }
    });
    items.push({
      value: 'B 站收藏夹同步',
      action: (): void => {
        // 收藏夹同步页的路由名是 'CloudSync'（FavSyncPage 文件名 ≠ 路由名）
        NavStackHolder.push('CloudSync', undefined);
      }
    });
    return items;
  }

  /**
   * 多选态 ⋮ 菜单项：破坏性 / 合并动作收进菜单（解 4 文字按钮 358/360 贴边）。
   * 空选区「删除」置灰、不足两个「合并」置灰 —— 置灰比「可点进去再 toast」
   * 更早拦住误触；页面方法内的 toast 校验保留作第二道兜底。
   */
  private selectMenuItems(): MenuElement[] {
    return [
      {
        value: '删除选中',
        enabled: this.selectedCount > 0,
        action: (): void => {
          TabScrollerHolder.plDeleteSelected();
        }
      },
      {
        value: '合并选中',
        enabled: this.selectedCount >= 2,
        action: (): void => {
          TabScrollerHolder.plOpenMergeEditor();
        }
      }
    ];
  }

  build() {
    if (this.selecting) {
      // ── 多选态：[全选][完成][⋮]（左侧「已选 N」标题由 Index.tabTitleRow 渲染）──
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
            TabScrollerHolder.plToggleSelectAll();
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
            TabScrollerHolder.plToggleSelecting();
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
        .onClick((): void => {
          this.selectMenuOpen = true;
        })
        .bindMenu(this.selectMenuOpen, this.selectMenuItems(), {
          // placement 必须显式 BottomRight：默认 BottomLeft 以锚点左缘向右展开，
          // ⋮ 在标题行右缘必超屏 → 走「自动调整」路径，菜单跑到左边弹出
          //（AppearanceSettingsPage 菜单同款结论）
          placement: Placement.BottomRight,
          onDisappear: (): void => {
            this.selectMenuOpen = false;
          }
        })
      }
      .transition(TransitionEffect.OPACITY
        .animation({ duration: PL_SELECT_FADE_MS, curve: Curve.EaseInOut }))
    } else {
      // ── 常规态：[↓ 下载角标钮][+ 新建][⋮ 菜单] ──
      Row({ space: 8 }) {
        DownloadsIconButton()
        // 「+」新建：唯一品牌实底主 CTA（36×36 与其余图标钮同几何）
        Button() {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(18)
            .fontColor([this.themeOn])
        }
        .type(ButtonType.Normal)
        .width(36)
        .height(36)
        .borderRadius(10)
        .backgroundColor(this.themePrimary)
        .attributeModifier(this.buttonMaterial)
        .accessibilityText('新建歌单')
        .onClick((): void => {
          TabScrollerHolder.plOpenCreate();
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
        .accessibilityText('更多歌单页操作')
        .onClick((): void => {
          this.moreMenuOpen = true;
        })
        .bindMenu(this.moreMenuOpen, this.normalMenuItems(), {
          // 同上：右缘锚点必须 BottomRight，菜单从 ⋮ 下方弹出
          placement: Placement.BottomRight,
          onDisappear: (): void => {
            this.moreMenuOpen = false;
          }
        })
      }
    }
  }
}
