/**
 * 更多面板（bindSheet）标准行（头部操作区重构 L3，设计方案 §3.5）。
 *
 * 面板行统一规格：高 44，左侧 18 号语义图标，中间 16fp 标题，右侧
 * 13fp 副标注（如「3 天前」「多选批量」）或单选选中态尾随 ✓
 * （18 号主题色）。危险操作（取消订阅）danger 置 true：标题与图标用
 * state_error 色并与安全操作分开分组（trackMenuItems 同款原则）。
 *
 * 判断标准来自设计稿：面板项带语义图标 + 副标注，用户不需要学习
 * 就会去找 ⋯。宿主页只拼数据行，视觉收口在本组件。
 */

import { STORE_THEME_PRIMARY } from '../common/Constants';
import { SHEET_ROW_H } from '../common/constants/InteractionConstants';

@Component
export struct SheetActionRow {
  /** 左侧语义图标（sys.symbol.*） */
  icon: Resource = $r('sys.symbol.more');
  /** 标题（16fp） */
  title: string = '';
  /** 右侧副标注（13fp text_tertiary，空串不占位） */
  subtitle: string = '';
  /** 单选选中态（尾随 ✓，18 号主题色）；与 subtitle 互斥显示 */
  checked: boolean = false;
  /** 危险操作：标题 / 图标用 state_error 色（与安全操作分开分组由宿主页负责） */
  danger: boolean = false;
  /** 禁用态（如「正在拉取…」时禁点）：透明度降级 + 不响应点击 */
  disabled: boolean = false;
  /** 点击回调 */
  onClickAction: () => void = (): void => {};
  /** 主题色运行时值：选中 ✓ 颜色跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';

  build() {
    Row({ space: 12 }) {
      SymbolGlyph(this.icon)
        .fontSize(18)
        // SymbolGlyph.fontColor 按图层接收颜色数组，单色也传单元素数组
        .fontColor([this.danger ? $r('app.color.state_error') : $r('app.color.text_primary')])
      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.danger ? $r('app.color.state_error') : $r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.subtitle.length > 0) {
        Text(this.subtitle)
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (this.checked) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(18)
          .fontColor([this.themePrimary])
      }
    }
    .width('100%')
    .height(SHEET_ROW_H)
    .padding({ left: 4, right: 4 })
    .alignItems(VerticalAlign.Center)
    .opacity(this.disabled ? 0.45 : 1)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .onClick((): void => {
      if (!this.disabled) {
        this.onClickAction();
      }
    })
  }
}
