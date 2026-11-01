/**
 * 搜索态输入行（头部操作区重构 L2，设计方案 §3.4 / §4.2）。
 *
 * 只在宿主页「点 🔍 进入搜索态」后挂载（整行原位切换，宿主页 Stack 内
 * 条件渲染 + OPACITY 交叉淡出），独占操作行剩余宽度（layoutWeight 1），
 * 旁边是宿主页渲染的「取消」文字按钮。
 *
 * 规格（§3.4）：
 *  · 容器高 36、圆角 10、底 bg_card、**1.5vp 品牌色描边**（聚焦态的唯一表达）；
 *  · TextInput 独占、fontSize 14、placeholder text_tertiary、
 *    **自动聚焦弹键盘**（defaultFocus，条件挂载即生效）；
 *  · 回车键 = 键盘「搜索」键（enterKeyType Search）→ onSubmit（UP 主页远程
 *    搜索；纯本地过滤页 onSubmit 为空实现，仅收起键盘）—— 可见「搜索」
 *    按钮已按设计稿删除（§4.2：它占 58vp，做的事与键盘搜索键完全一样）；
 *  · 右侧：远程在途（searching）→ 14 号加载指示替换 ×（§4.2）；
 *    否则 × 清除（clearVisible 由宿主页按自家状态计算）。
 */

import { STORE_THEME_PRIMARY } from '../common/Constants';
import { ACTION_ROW_H } from '../common/constants/InteractionConstants';

@Component
export struct SearchBox {
  /** 显示文本：宿主页 @State 为唯一数据源，@Prop 单向回流驱动 TextInput */
  @Prop keyword: string = '';
  /** × 清除按钮可见条件：宿主页按自家状态计算（词非空 / 远程态非空） */
  @Prop clearVisible: boolean = false;
  /** 远程搜索在途：右侧 × 换成加载指示（仅远程搜索页 —— UP 主页传） */
  @Prop searching: boolean = false;
  /** 占位文案：页面级常量，一次性初始化 */
  placeholder: string = '';
  /** 输入变化：宿主页先更新自家 searchKeyword 再调自家 onKeywordChanged */
  onKeywordChange: (v: string) => void = (): void => {};
  /** 键盘「搜索」键（enterKeyType Search）：远程搜索页触发远程搜索；本地页不接，默认空实现 */
  onSubmit: () => void = (): void => {};
  /** 框内 × 点击：宿主页清关键词 / 退远程态 / 取消在途防抖 */
  onClear: () => void = (): void => {};
  /** 主题色运行时值：聚焦描边色跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';

  build() {
    Stack({ alignContent: Alignment.End }) {
      TextInput({ placeholder: this.placeholder, text: this.keyword })
        .height(ACTION_ROW_H)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .placeholderFont({ size: 14 })
        // 底色交给外层容器（bg_card + 品牌色描边），输入框本体透明
        .backgroundColor(Color.Transparent)
        .borderRadius(10)
        // 右侧让位给框内 × / 加载指示：文字滚动到最右时不被图标盖住
        .padding({ left: 14, right: 36 })
        // 自动聚焦：搜索态条件挂载即聚焦弹键盘（§3.4「自动 focus 并弹键盘」）
        .defaultFocus(true)
        // 回车键 = 键盘「搜索」键：可见搜索按钮的替代（§4.2）
        .enterKeyType(EnterKeyType.Search)
        .onChange((v: string): void => {
          this.onKeywordChange(v);
        })
        .onSubmit((): void => {
          this.onSubmit();
        })
      // 右侧指示位：远程在途 = 加载指示；否则 × 清除（clearVisible 条件不变）
      if (this.searching) {
        LoadingProgress()
          .width(14)
          .height(14)
          .margin({ right: 12 })
          .color(this.themePrimary)
      } else if (this.clearVisible) {
        Stack() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(14)
            // SymbolGlyph.fontColor 按图层接收颜色数组，单色也传单元素数组
            .fontColor([$r('app.color.text_tertiary')])
        }
        .width(24)
        .height(24)
        .margin({ right: 8 })
        .onClick((): void => {
          this.onClear();
        })
      }
    }
    .height(ACTION_ROW_H)
    .borderRadius(10)
    .backgroundColor($r('app.color.bg_card'))
    // 1.5vp 品牌色描边：搜索态聚焦的唯一表达（§3.4）
    .border({ width: 1.5, color: this.themePrimary })
  }
}
