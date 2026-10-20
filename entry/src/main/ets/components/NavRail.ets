/**
 * 平板侧边导航栏（自绘 Navigation Rail，2026-10-20 平板适配档 2）。
 *
 * 为什么自绘而不用 HDS 侧边组件：HdsSideBar / HdsSideMenu 是**抽屉容器**
 * （遮罩 + 弹出面板），不是常驻侧边导航；系统没有独立的 Navigation Rail
 * 组件，自绘最可控（尺寸 / 选中态 / 主题色全在手，无黑盒）。
 *
 * 形态：96vp 固定宽的常驻左栏（白底 bg_card + 右缘 0.5vp 分隔线），
 * 四个导航项与 Index.tabItem 同套视觉（SymbolGlyph + 文案，选中主题色），
 * 选中项额外叠一层淡主题色胶囊底（HDS rail 的选中容器样式）。
 *
 * 切页驱动：点击**直写 STORE_ACTIVE_TAB**（@StorageLink 写穿 AppStorage）——
 * 平板分支没有 HdsTabs / tabController，activeTab 就是唯一事实源：
 * Index 的顶栏（stackBuilder）、页面 visibility、下载页 @Watch 全部跟随它。
 *
 * 安全区：栏背景从 y=0 铺起覆盖状态栏（窗口全屏沉浸），内容区
 * padding.top = safeTop 让导航项落在状态栏下方 —— 与手机形态各 Tab
 * 固定栏的同款手法。
 */

import { MaterialCompat } from '../utils/MaterialCompat';
import { NavStackHolder } from '../service/NavStackHolder';
import {
  STORE_ACTIVE_TAB,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY
} from '../common/Constants';

/** 栏宽（vp）：图标 24 + 文案 12fp 的纵向项 + 两侧 12 内边距 */
const RAIL_WIDTH_VP: number = 96;
/** 单个导航项高度（vp）：图标 + 文案纵向堆叠 + 上下留白 */
const RAIL_ITEM_HEIGHT_VP: number = 64;
/** 导航项之间的纵向间距（vp） */
const RAIL_ITEM_SPACING_VP: number = 4;
/** 选中项胶囊底色的主题色透明度（淡显容器，不与图标抢焦点） */
const RAIL_PILL_ALPHA: number = 0.1;

@Component
export struct NavRail {
  /** 当前页签下标（与 Index 同键 @StorageLink 写穿）：点击直写即切页 */
  @StorageLink(STORE_ACTIVE_TAB) activeTab: number = 0;
  /** 状态栏高度（vp）：导航项区从状态栏下方开始 */
  @StorageProp(STORE_SAFE_TOP) safeTop: number = 0;
  /** 主题色主色（hex 字符串，ThemeColors 发布）：选中项图标 / 文案 / 胶囊底跟随 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';

  /**
   * 单个导航项：SymbolGlyph 图标 + 文案，选中主题色 + 淡主题色胶囊底，
   * 未选中次要色 + 透明底。
   *
   * ⚠️ 参数**只传静态字面量**（下标 / 文案 / 图标资源），选中的判断在
   * Builder 内部现算 —— 带参 @Builder 是值传递，状态变量当参数传进来
   * 不会刷新内部 UI（与 Index.tabItem 同一约束）。
   */
  @Builder
  railItem(index: number, label: string, icon: Resource) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([this.activeTab === index ? this.themePrimary : $r('sys.color.font_secondary')])
      Text(label)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.activeTab === index ? this.themePrimary : $r('sys.color.font_secondary'))
    }
    .width('100%')
    .height(RAIL_ITEM_HEIGHT_VP)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(16)
    .backgroundColor(this.activeTab === index
      ? MaterialCompat.withAlpha(this.themePrimary, RAIL_PILL_ALPHA)
      : Color.Transparent)
    .onClick((): void => {
      // 直写 AppStorage（@StorageLink 写穿）：顶栏 / 页面 visibility / 下载页
      // @Watch 全部经 STORE_ACTIVE_TAB 跟随，无需任何控制器
      this.activeTab = index;
      // 修复（2026-10-20 用户反馈「点 rail 切不动页签」）：rail 在 Navigation
      // 外常驻，推入的 NavDestination（播放页 / 歌单详情等）只盖内容列 ——
      // 栈顶页不收起会一直置顶。点 rail = 明确离开当前上下文，把栈清回根；
      // 放在这里而非 Index 的 @Watch：点**当前页签**时 activeTab 不变、
      // @Watch 不触发，rail 的 onClick 是唯一全量入口。
      if (NavStackHolder.stack.size() > 0) {
        NavStackHolder.stack.clear();
      }
    })
  }

  build() {
    Column({ space: RAIL_ITEM_SPACING_VP }) {
      this.railItem(0, '首页', $r('sys.symbol.house'))
      this.railItem(1, '歌单', $r('sys.symbol.list_bullet'))
      this.railItem(2, '下载', $r('sys.symbol.circle_and_arrow_down'))
      this.railItem(3, '设置', $r('sys.symbol.gearshape'))
    }
    .width(RAIL_WIDTH_VP)
    .height('100%')
    // 状态栏避让：背景从 y=0 铺起（沉浸），导航项内容落在状态栏下方
    .padding({ top: this.safeTop + 8, left: 12, right: 12 })
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: { right: 0.5 }, color: $r('app.color.bg_divider') })
  }
}
