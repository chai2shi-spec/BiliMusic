/**
 * 搜索二级页标题栏行（搜索为 'Search' 二级页）。
 *
 * SearchInputBar 是 HdsNavDestination.titleBar 的 stackBuilder 内容
 * （SearchPage 侧承载），整行 56 锁高：
 *   · HDS 默认返回键（"<" 系统样式，位置由 HDS 管理）在行左侧，
 *     行首以定宽 Blank 让出（NAV_BACK_SIZE + NAV_TITLE_GAP，NavTitleRow 同口径）；
 *   · Search 标准搜索框（自带放大镜，onChange 回写 keyword）+ 「视频/UP主」
 *     CapsuleSegmentButtonV2 标准分段按钮（B 站粉经 itemSelectedBackgroundColor 覆写）；
 *   · defaultFocus(true)：push 进页自动聚焦弹键盘（入口式搜索框的承接），
 *     SearchPage 侧另有延迟 requestFocus 兜底（NavDestination 动态挂载时
 *     defaultFocus 偶发不触发）。
 *
 * · V1 容器 + V2 子组件（CapsuleSegmentButtonV2 是 @ComponentV2）单向数据流：
 *   点击 → onItemClicked → TabScrollerHolder 静态回调 → 页面写 AppStorage →
 *   @StorageLink 刷新 → selectedIndex 重算。不绑 $selectedIndex（V1 下不可用）。
 * · 状态：keyword / searchKind 是页面与栏共享的双向状态（两侧
 *   @StorageLink，任一侧写入另一侧即见）。
 * · 动作：经 TabScrollerHolder 静态回调转交页面私有方法（页面 onAppear 注册）。
 *
 * ⚠️ stackBuilder 宿主几何（NavTitleRow 文件头真机解码）：宿主给内容的布局框是
 * 可见容器的上下对称扩边框，必须以 Column(height '100%') + Center 居中锚定，
 * 56vp 行恰好落进 [safeTop, safeTop+56] 可见容器 —— Start/End 锚定都会跑偏。
 */

import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import {
  NAV_TITLE_BAR_HEIGHT,
  NAV_H_PADDING,
  NAV_BACK_SIZE,
  NAV_TITLE_GAP
} from '../utils/NavTitleStyle';
import {
  makeBiliSegmentColors,
  SegmentColors,
  SearchMaterialModifier,
  makeSearchMaterialModifier
} from '../utils/HeaderBarMaterial';
import { MaterialCompat } from '../utils/MaterialCompat';
import { SearchStateHolder } from '../service/SearchStateHolder';
import {
  CapsuleSegmentButtonV2,
  LengthMetrics,
  SegmentButtonV2Items
} from '@kit.ArkUI';
import {
  STORE_SEARCH_KEYWORD,
  STORE_SEARCH_KIND
} from '../common/Constants';

/**
 * 搜索行（'Search' 二级页 titleBar 的 stackBuilder，56 锁高）：
 * HDS 返回键让位 + Search 搜索框 + 类型分段按钮（视频 / UP主）。
 * 不设搜索按钮（用户口径「看着多余」）：提交搜索走键盘
 * onSubmit，搜索框不损失任何能力。
 */
@Component
export struct SearchInputBar {
  /** 双向：栏输入 ↔ 页面（点历史词条 / 恢复会话词）。初值取 holder 的会话词，两侧同源不打架 */
  @StorageLink(STORE_SEARCH_KEYWORD) keyword: string = SearchStateHolder.keyword;
  /** 双向：分段按钮选段 ↔ 页面（doSearch / 占位文案都读它） */
  @StorageLink(STORE_SEARCH_KIND) searchKind: string = 'video';
  /** 「视频/UP主」分段按钮条目：静态一次构造 */
  private kindItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: '视频' },
    { text: 'UP主' }
  ]);

  /** 分段按钮主题色配色组：每次渲染现取（读 AppStorage），缓存成字段切色不刷新
   *  ⚠️ V1 @Component 禁用 getter 访问器（转译会丢弃，运行时 this.segColors 为
   *  undefined 直接崩溃），用普通成员方法。 */
  private segColors(): SegmentColors {
    return makeBiliSegmentColors();
  }

  /** 搜索框沉浸光感材质修饰器：THIN + interactive + lightEffect（26+ 生效，低版本 no-op） */
  private searchMaterial: SearchMaterialModifier = makeSearchMaterialModifier();
  /**
   * 搜索框底色：材质可用（26+）时**透明**——官方 FAQ「背景色遮挡材质效果」：
   * 不透明 backgroundColor 画在材质层之上，玻璃完全被盖住（与 UP 主页搜索框
   * TextInputMaterialModifier 同款结论）。低版本材质不可用时回落 bg_card 实色
   * 兜底，搜索框不至于变成隐形框。
   */
  private searchBoxBg(): ResourceColor {
    return MaterialCompat.hasImmersiveMaterial() ? Color.Transparent : $r('app.color.bg_card');
  }

  build() {
    // 宿主怪癖必需的中间层：height('100%') 撑满布局框 + Center 居中锚定，
    // 56vp 行恰好落进可见容器（见文件头 ⚠️ 几何解码，NavTitleRow 同款）
    Column() {
      Row() {
        // 让出 HDS 默认返回键区域（44 命中区 + 4 间距）：搜索框左缘与
        // NavTitleRow 标题左缘（16 + 48 = 64vp）同一条竖线
        Blank()
          .width(NAV_BACK_SIZE + NAV_TITLE_GAP)

        // Search 标准搜索框：value 单向读 + onChange 回写 keyword
        // （@StorageLink 双向）。最近搜索在页内展示，栏内不挂历史相关回调。
        Search({
          value: this.keyword,
          placeholder: this.searchKind === 'user' ? '搜索UP主' : '搜索歌曲、歌单'
        })
          .layoutWeight(1)
          // 高度与右侧分段按钮一致（32），圆角与按钮同一套 8vp 语言
          .height(32)
          // 与行内 13fp 设计语言一致（默认 16fp 占位在窄框内会截断）
          .placeholderFont({ size: 13 })
          .borderRadius(BUTTON_RADIUS_VP)
          // 底色走 searchBoxBg()：26+ 材质可用时透明（不透明底会盖住材质层玻璃，
          // 官方 FAQ 同款结论），低版本回落 bg_card 实色兜底。
          .backgroundColor(this.searchBoxBg())
          // 沉浸光感材质：与 UP 主页搜索框 / 各页按钮同档（THIN + interactive
          // + lightEffect）；titleBar 内，材质生效范围内。
          .attributeModifier(this.searchMaterial)
          // push 进页自动聚焦弹键盘（入口式搜索框的承接）；SearchPage 侧
          // 另有延迟 requestFocus 按 id 兜底（动态挂载时 defaultFocus 偶发不触发）
          .defaultFocus(true)
          .id('searchSubPageInput')
          .onSubmit((): void => {
            TabScrollerHolder.searchSubmit();
          })
          .onChange((v: string): void => {
            // 回写 keyword
            this.keyword = v;
            // 清空即回初始页：✕ 或退格删到空 → 页面整体重置
            if (v.length === 0) {
              TabScrollerHolder.searchReset();
            }
          })

        // 搜索类型分段按钮（视频 / UP主，iOS segmented 式）：与搜索框同一行，
        // 分段点击不与历史面板 / 返回键冲突（返回键让位区在行首）。
        CapsuleSegmentButtonV2({
          items: this.kindItems,
          selectedIndex: this.searchKind === 'user' ? 1 : 0,
          onItemClicked: (index: number): void => {
            TabScrollerHolder.searchSetKind(index === 1 ? 'user' : 'video');
          },
          itemSelectedBackgroundColor: this.segColors().selectedBg,
          itemSelectedFontColor: this.segColors().selectedFont,
          itemSelectedFontWeight: FontWeight.Medium,
          itemFontColor: this.segColors().unselectedFont,
          itemFontWeight: FontWeight.Normal,
          itemFontSize: LengthMetrics.vp(13),
          itemSelectedFontSize: LengthMetrics.vp(13),
          buttonBackgroundColor: this.segColors().grooveBg,
          buttonBorderRadius: LengthMetrics.vp(BUTTON_RADIUS_VP),
          itemBorderRadius: LengthMetrics.vp(6),
          // 内部背板最小高度默认系统 token（约 36vp）会盖过外层 .height(32)
          // （真机验收：与搜索框/按钮高度不一致），对齐到 32
          buttonMinHeight: LengthMetrics.vp(32),
          // 紧凑内边距：系统默认 start/end 16vp（padding_level4）空气感过强
          // （真机验收「留空太多」），收到 8vp
          itemPadding: { start: LengthMetrics.vp(8), end: LengthMetrics.vp(8) }
        })
          .height(32)
          // ⚠️ V2 分段按钮测量特性：给多大渲染多大（均摊到各段），不会内容自适应
          // —— 不设宽度会把同行 layoutWeight(1) 的搜索框压成 0 宽（搜索框消失）。
          // 显式 108vp = 背板 padding 4×2 + 两段
          // （最长文案 UP主约 31 + itemPadding 8×2）。
          .width(108)
          // 与搜索框拉开 8vp 间距
          .margin({ left: 8 })
      }
      .width('100%')
      .height(NAV_TITLE_BAR_HEIGHT)
      // 水平基线统一 NAV_H_PADDING(16)：搜索行与页面内容同一条左缘
      .padding({ left: NAV_H_PADDING, right: NAV_H_PADDING })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
