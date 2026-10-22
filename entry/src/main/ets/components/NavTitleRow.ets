/**
 * 子页标题行（HdsNavDestination.titleBar 的 stackBuilder 内容）—— 全站唯一实现。
 *
 * 2026-10-22 顶栏设计规范 v2：此前 About / Follows / Recent / WatchHistory /
 * PlaylistDetail / PlaylistImport / FavSync / Login / UpSpace 九个子页各自复制了
 * 一段逐字相同的「返回键 + 标题」代码（只差标题文案），任何一次微调都要改九处，
 * 且已经出现了「有的页有标题、有的页只有返回键」这种无意的分叉。
 *
 * 约定：
 *   · 只承载标题行本身（56vp 定高），标题行下方的头部区仍走各页 titleBar 的
 *     bottomBuilder（封面 / 资料 / 简介等，高度不由本组件承担）；
 *   · 返回键命中区 44×44 正圆 + 按压态，图标 24（与系统返回键同档）；
 *   · **无标题变体**（PlaylistDetail / UpSpacePage）：标题在头部区用 28fp 大字
 *     显示一次，标题行只留返回键 —— 传 title: '' 即可，不是遗漏；
 *   · 材质与滚动渐变模糊由 HDS titleBar 统一渲染（见 utils/HdsTitleBarStyle），
 *     本组件不画任何背景，绝不能自带底色（会截断顶栏的沉浸光感）。
 */

import { NavStackHolder } from '../service/NavStackHolder';
import {
  NAV_TITLE_BAR_HEIGHT,
  NAV_H_PADDING,
  NAV_BACK_SIZE,
  NAV_BACK_ICON_SIZE,
  NAV_TITLE_GAP
} from '../utils/NavTitleStyle';

@Component
export struct NavTitleRow {
  /** 标题文案；空串 = 无标题变体（歌单详情 / UP 主空间，标题让给头部区大字） */
  @Prop title: string = '';

  build() {
    Row() {
      // 返回键：44 命中区正圆，图标居中；按压只染圆内，不吃行内空白
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(NAV_BACK_ICON_SIZE)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(NAV_BACK_SIZE)
      .height(NAV_BACK_SIZE)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .borderRadius(NAV_BACK_SIZE / 2)
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.press_overlay')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .accessibilityText('返回')
      .accessibilityLevel('yes')
      .onClick((): void => {
        NavStackHolder.stack.pop();
      })

      if (this.title.length > 0) {
        Text(this.title)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          // 与返回键拉开一点视觉呼吸（贴死会显得挤，GAP 见 NavTitleStyle）
          .margin({ left: NAV_TITLE_GAP })
      }
    }
    .width('100%')
    .height(NAV_TITLE_BAR_HEIGHT)
    .padding({ left: NAV_H_PADDING, right: NAV_H_PADDING })
    .alignItems(VerticalAlign.Center)
  }
}
