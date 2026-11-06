/**
 * 首页分类 chip 条（MusicHome 首页移植）。
 *
 * · MusicHome CategoryChipsSection 的 V1 移植：横向滚动的分类 pill
 *   （36 高 / radius 18 / 图标 16 + 文字 12 / 选中 500 字重反白），
 *   与 SearchPage 二级页拆分配套 —— 首页页签为「推荐/热歌榜/音乐中心/
 *   热门歌单」四 chip（热歌榜 = 网易云热歌榜单曲列表，HomePage ranking
 *   分支；热门歌单 = 网易云热门歌单网格，HomePage netease 分支），搜索独立成二级页。
 *
 * · 选中态经 AppStorage 双向状态 STORE_SEARCH_TAB：
 *   HomeCategoryChips 点击写 → HomePage @StorageLink 读并切换内容分支；
 *   HomePage 内部跳转（如空态重试不改 tab）不反向影响 chip。
 * · 四 chip 固定不可配置：与 HomePage 的内容分支一一对应，
 *   动态化没有需求方，静态表更利于 LazyForEach key 稳定。
 * · 图标 = design/icons 方案 B（面性）：按四分类语义重画的 home_cat_*.svg
 *   （media 资源，24 网格 / 全填充 / 尖·方·圆·杯 四剪影），替代旧
 *   sys.symbol —— play_fill 表达「播放」不是「推荐」，music_note_list 与
 *   list_bullet 在 16vp 下都是「一堆横线」糊成一样（见 design/icons/README.md）；
 *   SVG 当资源加载后 currentColor 失效，必须 renderMode(Template) 走 alpha
 *   通道 + fillColor 上色（描边图标同样适用，README 第五节）。
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
  /** chip 图标（方案 A 线性 SVG 媒体资源，Template 渲染 + fillColor 上色） */
  icon: Resource;
}

/**
 * 四分类 chip 静态表（模块级导出，顺序即展示顺序：推荐 / 热门歌单 / 热歌榜 /
 * 音乐中心）：chip 条本体与 Index 导航栏滚动联动的 tab 图标共用同一份图标 / key
 * （单一来源，两处不会漂移）。Index 侧图标 40×40 圆按钮复用同 icon。
 */
export const HOME_CATEGORY_CHIPS: CategoryChipUi[] = [
  { key: 'recommend', title: '推荐', icon: $r('app.media.home_cat_recommend') },
  { key: 'netease', title: '热门歌单', icon: $r('app.media.home_cat_playlist') },
  { key: 'ranking', title: '热歌榜', icon: $r('app.media.home_cat_ranking') },
  { key: 'center', title: '音乐中心', icon: $r('app.media.home_cat_center') }
];

@Component
export struct HomeCategoryChips {
  /** 双向：chip 选中 ↔ HomePage 内容分支（AppStorage 共享） */
  @StorageLink(STORE_SEARCH_TAB) tab: string = 'recommend';
  /** 主题色主色：选中 chip 底色跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /** 四分类 chip 表：引用模块级导出常量（见 HOME_CATEGORY_CHIPS 注释） */
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
      // 方案 B 面性 SVG：Template 模式只看 alpha（currentColor 资源态失效），
      // fillColor 染色；选中反白、未选中次级文字色（与文字同色）。
      Image(item.icon)
        .width(16)
        .height(16)
        .renderMode(ImageRenderMode.Template)
        .fillColor(this.isSelected(item) ? Color.White : $r('app.color.text_secondary'))
        .interpolation(ImageInterpolation.High)
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
