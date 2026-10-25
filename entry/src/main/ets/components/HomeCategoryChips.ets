/**
 * 首页分类 chip 条（MusicHome 首页移植）。
 *
 * MusicHome CategoryChipsSection 的 V1 移植：横向滚动的分类 pill
 * （36 高 / radius 18 / 图标 16 + 文字 12 / 选中 500 字重反白），
 * 与 SearchPage 二级页拆分配套 —— 首页页签为「推荐/排行榜/音乐中心」
 * 三 chip，搜索独立成二级页。
 *
 * · 选中态经 AppStorage 双向状态 STORE_SEARCH_TAB：
 *   HomeCategoryChips 点击写 → HomePage @StorageLink 读并切换内容分支；
 *   HomePage 内部跳转（如空态重试不改 tab）不反向影响 chip。
 * · 三 chip 固定不可配置：与 HomePage 的三分支渲染一一对应，
 *   动态化没有需求方，静态表更利于 LazyForEach key 稳定。
 * · 图标复用工程内已验证的 sys.symbol（play_fill / list_bullet / waveform，
 *   与底栏页签、全站音乐图标同一批资源），不新增媒体文件。
 * · 主题色经 @StorageProp（STORE_THEME_PRIMARY）跟随运行时切色；
 *   选中底 = 主题粉、图标文字反白，未选中 = bg_card 底 + 主文字色。
 */

import {
  STORE_SEARCH_TAB,
  STORE_THEME_PRIMARY
} from '../common/Constants';
import { NAV_H_PADDING } from '../utils/NavTitleStyle';

/** 单个分类 chip 的展示模型（图标 + 文案 + tab key） */
export interface CategoryChipUi {
  /** tab key：与 HomePage 内容分支、STORE_SEARCH_TAB 取值一致 */
  key: string;
  /** chip 文案 */
  title: string;
  /** chip 图标（16×16 SymbolGlyph） */
  icon: Resource;
}

/**
 * 三分类 chip 静态表（模块级导出，顺序即展示顺序：推荐 / 排行榜 / 音乐中心）：
 * chip 条本体与 Index 导航栏滚动联动的三个 tab 图标共用同一份图标 / key
 * （单一来源，两处不会漂移）。Index 侧图标 40×40 圆按钮复用同 icon。
 */
export const HOME_CATEGORY_CHIPS: CategoryChipUi[] = [
  { key: 'recommend', title: '推荐', icon: $r('sys.symbol.play_fill') },
  { key: 'ranking', title: '排行榜', icon: $r('sys.symbol.list_bullet') },
  { key: 'center', title: '音乐中心', icon: $r('sys.symbol.waveform') }
];

@Component
export struct HomeCategoryChips {
  /** 双向：chip 选中 ↔ HomePage 内容分支（AppStorage 共享） */
  @StorageLink(STORE_SEARCH_TAB) tab: string = 'recommend';
  /** 主题色主色：选中 chip 底色跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /** 三分类 chip 表：引用模块级导出常量（见 HOME_CATEGORY_CHIPS 注释） */
  private chips: CategoryChipUi[] = HOME_CATEGORY_CHIPS;

  /** chip 是否选中（tab key 比对；非法值不命中任何 chip） */
  private isSelected(item: CategoryChipUi): boolean {
    return this.tab === item.key;
  }

  /**
   * 单个分类 pill：图标 + 文案横排居中，选中态粉底反白加粗。
   * MusicHome 同款几何：高 36、radius 18、图标 16、文字 12。
   */
  @Builder
  private CategoryChip(item: CategoryChipUi) {
    Row({ space: 6 }) {
      SymbolGlyph(item.icon)
        .fontSize(16)
        .height(16)
        .fontColor([this.isSelected(item) ? Color.White : $r('app.color.text_secondary')])
      Text(item.title)
        .fontSize(12)
        .lineHeight(16)
        .fontWeight(this.isSelected(item) ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.isSelected(item) ? Color.White : $r('app.color.text_secondary'))
    }
    .height(36)
    .padding({ left: 16, right: 16 })
    .borderRadius(18)
    .backgroundColor(this.isSelected(item) ? this.themePrimary : $r('app.color.bg_card'))
    .border({
      width: 0.5,
      color: this.isSelected(item) ? this.themePrimary : $r('app.color.bg_divider')
    })
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .onClick((): void => {
      this.tab = item.key;
    })
  }

  build() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(
          this.chips,
          (item: CategoryChipUi): void => {
            this.CategoryChip(item)
          },
          (item: CategoryChipUi): string => `chip_${item.key}`
        )
      }
      .padding({ left: NAV_H_PADDING, right: NAV_H_PADDING })
    }
    .scrollBar(BarState.Off)
    .scrollable(ScrollDirection.Horizontal)
    .width('100%')
    .align(Alignment.Start)
    .padding({ top: 12, bottom: 12 })
  }
}
