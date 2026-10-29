/**
 * 页面内搜索行共享组件：TextInput（沉浸光感材质）+ 框内 × 清除 + 可选「搜索」按钮。
 *
 * 收编三页（歌单详情 / UP 主页 / 合集分 P）原先各写一份的搜索框 UI 与
 * searchBoxBg 材质兜底逻辑；数据与搜索状态全部留在宿主页（@State 观测最稳），
 * 本组件只管渲染 + 把交互原样回调出去：
 *  · onKeywordChange —— 输入变化（宿主页显式调自己的 onKeywordChanged，不走 @Watch）；
 *  · onClear         —— 框内 × 点击（显示条件由宿主页经 clearVisible 计算：
 *                       纯本地搜索页 = 词非空；UP 主页 = 词非空 || 远程结果态非空）；
 *  · onSubmit        —— 键盘 Enter（仅远程搜索页接）；
 *  · onSearchClick   —— 「搜索」按钮（showSearchButton 页面才有）。
 *
 * 布局契约：根节点 Row（space 8）内 Stack layoutWeight(1) + 可选按钮；
 * 宿主页在调用点链式附加 .layoutWeight(1) / .transition(...) 等通用属性
 * （嵌在动作行内收窄适应，UpSpacePage 搜索按钮曾被推出屏外，勿改用 width 100%）。
 *
 * 材质契约：TextInput 底色 26+ 材质可用时透明（不透明底会盖住材质层玻璃，
 * 官方 FAQ「背景色遮挡材质效果」），低版本回落 bg_card 实色兜底 ——
 * searchBoxBg 收编在本组件，宿主页不再各持一份。
 */

import { STORE_THEME_PRIMARY, STORE_THEME_SURFACE } from '../common/Constants';
import { BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier,
  TextInputMaterialModifier,
  makeTextInputMaterialModifier
} from '../utils/HeaderBarMaterial';
import { MaterialCompat } from '../utils/MaterialCompat';

@Component
export struct SearchBox {
  /** 显示文本：宿主页 @State 为唯一数据源，@Prop 单向回流驱动 TextInput */
  @Prop keyword: string = '';
  /** × 清除按钮可见条件：宿主页按自家状态计算（词非空 / 远程态非空） */
  @Prop clearVisible: boolean = false;
  /** 「搜索」按钮文案（远程搜索页传『搜索中』切换） */
  @Prop searchButtonLabel: string = '搜索';
  /** 占位文案：页面级常量，一次性初始化 */
  placeholder: string = '';
  /** 是否渲染「搜索」按钮（仅远程搜索页 —— UP 主页；纯本地过滤页不渲染） */
  showSearchButton: boolean = false;
  /** 输入变化：宿主页先更新自家 searchKeyword 再调自家 onKeywordChanged */
  onKeywordChange: (v: string) => void = (): void => {};
  /** 键盘 Enter（远程搜索页触发远程搜索；本地页不接，默认空实现） */
  onSubmit: () => void = (): void => {};
  /** 框内 × 点击：宿主页清关键词 / 退远程态 / 取消在途防抖 */
  onClear: () => void = (): void => {};
  /** 「搜索」按钮点击（与 onSubmit 同走宿主页远程搜索入口） */
  onSearchClick: () => void = (): void => {};

  /** 主题色运行时值：「搜索」按钮字色 / 底色跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';

  /** 「搜索」按钮沉浸光感材质修饰器：26+ 生效，低版本 no-op 显实色兜底 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 搜索框（TextInput）沉浸光感材质修饰器：与 buttonMaterial 同档（THIN + interactive + lightEffect） */
  private searchInputMaterial: TextInputMaterialModifier = makeTextInputMaterialModifier();

  /**
   * 搜索框底色：材质可用（26+）时**透明**——官方 FAQ「背景色遮挡材质效果」：
   * 不透明 backgroundColor 画在材质层之上，玻璃完全被盖住（TextInput 通用背景层
   * 在材质层上方；Button 内部把底色并入材质渲染所以按钮天生透明）。低版本材质
   * 不可用时回落实色 bg_card 兜底，搜索框不至于变成隐形框。
   */
  private searchBoxBg(): ResourceColor {
    return MaterialCompat.hasImmersiveMaterial() ? Color.Transparent : $r('app.color.bg_card');
  }

  build() {
    Row({ space: 8 }) {
      Stack({ alignContent: Alignment.End }) {
        TextInput({ placeholder: this.placeholder, text: this.keyword })
          .height(32)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .placeholderFont({ size: 14 })
          // 底色走 searchBoxBg()：26+ 材质可用时透明（不透明底会盖住材质层玻璃，
          // 官方 FAQ 同款结论），低版本回落 bg_card 实色兜底。
          .backgroundColor(this.searchBoxBg())
          .borderRadius(BUTTON_RADIUS_VP)
          // 沉浸光感材质：26+ 渲染 systemMaterial 玻璃底，低版本 no-op 走上方
          // 链式 bg_card 实色兜底。
          .attributeModifier(this.searchInputMaterial)
          // 右侧让位给框内 ×：文字滚动到最右时不被图标盖住
          .padding({ left: 14, right: 34 })
          .onChange((v: string): void => {
            this.onKeywordChange(v);
          })
          .onSubmit((): void => {
            this.onSubmit();
          })
        if (this.clearVisible) {
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
      .layoutWeight(1)
      if (this.showSearchButton) {
        Button(this.searchButtonLabel, { type: ButtonType.Normal })
          .fontSize(13)
          .height(32)
          .borderRadius(BUTTON_RADIUS_VP)
          .padding({ left: 16, right: 16 })
          .backgroundColor(this.themeSurface)
          .fontColor(this.themePrimary)
          .attributeModifier(this.buttonMaterial)
          // 不用 .enabled(false) 表达「空词 / 搜索中不可点」：禁用态会用系统灰字
          // 覆盖 themePrimary 字色（按钮字色恒为主题色）；点击兜底在宿主页
          // runRemoteSearch 里（空词 / 在途一律 no-op）。
          .onClick((): void => {
            this.onSearchClick();
          })
      }
    }
  }
}
