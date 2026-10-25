/**
 * 子页标题行（HdsNavDestination.titleBar 的 stackBuilder 内容）—— 全站唯一实现。
 *
 * 返回职责在 HdsNavDestination 默认返回键（"<" 系统样式，
 * 位置由 HDS 管理以避开状态栏），本组件只承载标题：
 *
 * 结构（真机实证，Mate 80 Pro Max dumpLayout 像素级解码）：
 *   Column(height '100%', justifyContent Center)   ← ⚠️ 必须居中锚定，见下
 *     Row(height 56)                               ← 标题行
 *       Blank(48vp 定宽占位)                        ← 让出 HDS 默认键区域
 *       Text(title)                                ← 左缘 x = 16 + 48 = 64vp
 *
 * ⚠️ HDS stackBuilder 宿主几何（真机 origBounds 解码，勿再踩）：
 *   · 宿主给 stackBuilder 内容的布局框是可见容器 [safeTop, safeTop+56] 的
 *     上下对称扩边框（各扩 safeTop/2，本机 [66,386]px，高 = safeTop+56vp），
 *     布局框与容器共中心；超出容器（安全区下缘以上 / 容器下缘以下）的部分
 *     被裁剪不显示，dumpLayout 的 bounds 即裁剪后可见区。
 *   · 因此 56vp 定高行的锚定方式决定成败（三种都真机实测过）：
 *     Start 顶对齐 → 行沉到布局框顶（扩边区内、状态栏下方），标题被裁、
 *     顶格在安全区下缘；
 *     End 底对齐   → 行沉到布局框底（容器下方扩边区），压低 19.6vp 与
 *     bottomBuilder 重叠；
 *     **Center 居中 → 行恰好落在可见容器 [safeTop, safeTop+56] 内，
 *     标题中心 ≈67vp 与 HDS 默认返回键同轴（布局框与容器共中心，任意
 *     安全区高度下均成立）——唯一正确锚定**。
 *   · 中间层 Column(height '100%') 必须保留：定高 Row 直接作为 stackBuilder
 *     内容根同样会被宿主按布局框顶锚定，隔一层再居中才可控。
 *
 * · **无标题变体**（PlaylistDetail / UpSpacePage）：标题在头部区用 28fp 大字
 *   显示一次，传 title: '' 即渲染空占位行，不是遗漏；
 * · 材质与滚动渐变模糊由 HDS titleBar 统一渲染（见 utils/HdsTitleBarStyle），
 *   本组件不画任何背景，绝不能自带底色（会截断顶栏的沉浸光感）。
 */

import {
  NAV_TITLE_BAR_HEIGHT,
  NAV_H_PADDING,
  NAV_BACK_SIZE,
  NAV_TITLE_GAP
} from '../utils/NavTitleStyle';

@Component
export struct NavTitleRow {
  /** 标题文案；空串 = 无标题变体（歌单详情 / UP 主空间，标题让给头部区大字） */
  @Prop title: string = '';

  build() {
    // 宿主怪癖必需的中间层：height('100%') 撑满布局框 + Center 居中锚定，
    // 56vp 行恰好落进可见容器（见文件头 ⚠️ 几何解码）
    Column() {
      Row() {
        // 让出 HDS 默认返回键区域（44 命中区 + 4 间距）：标题左缘与自绘时代一致
        Blank()
          .width(NAV_BACK_SIZE + NAV_TITLE_GAP)

        if (this.title.length > 0) {
          Text(this.title)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
      }
      .width('100%')
      .height(NAV_TITLE_BAR_HEIGHT)
      .padding({ left: NAV_H_PADDING, right: NAV_H_PADDING })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
