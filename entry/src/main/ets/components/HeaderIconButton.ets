/**
 * 头部操作区图标按钮（头部操作区重构 L1/L2 的 36×36 图标位）。
 *
 * 三层重构规格（design/头部操作区重构-设计方案.md §3.3）：
 *  · 视觉 36×36、圆角 10、底色 themeSurface、图标 18 号主题色、沉浸光感材质
 *    （26+ 生效，低版本 no-op 显实色兜底）；
 *  · 命中区 44 用 responseRegion 外扩 —— ⚠️ 不写 width(44)：会把操作行撑到
 *    44 高、整个头部往下推 8vp，列表首屏少半行（设计稿硬约束 ③）。
 *
 * 消费方：歌单详情 / UP 主页 / 合集分 P 的 🔍 搜索入口、⋯ 更多入口、
 * 多选动作行图标按钮（＋ 加入歌单 / ↓ 下载 / 🗑 移除）。主题色自取
 * （@StorageProp），宿主页只传 icon 与回调。
 */

import { STORE_THEME_PRIMARY, STORE_THEME_SURFACE } from '../common/Constants';
import {
  ICON_BTN_SIZE,
  ICON_BTN_HIT,
  PRESS_SCALE,
  PRESS_ANIM_MS
} from '../common/constants/InteractionConstants';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier
} from '../utils/HeaderBarMaterial';

@Component
export struct HeaderIconButton {
  /** 图标资源（sys.symbol.*）：18 号主题色渲染 */
  icon: Resource = $r('sys.symbol.more');
  /** 无障碍文案（读屏），必传语义描述 */
  accessibilityLabel: string = '';
  /** 点击回调 */
  onClickAction: () => void = (): void => {};
  /** 主题色运行时值：图标色 / 底色跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  /** 沉浸光感材质修饰器：26+ 生效，低版本 no-op 显实色兜底 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 按压缩放（与全局按压参数同档：0.9 / 150ms EaseOut） */
  @State pressScale: number = 1;

  build() {
    // 根节点用 Button（type Normal + borderRadius 10）：与其余头部按钮同一
    // 根类型，ButtonMaterialModifier（AttributeModifier<ButtonAttribute>）直接
    // 可挂 —— Stack 根会撞类型不匹配，MaterialCompat 也没有 Stack 通路。
    Button() {
      SymbolGlyph(this.icon)
        .fontSize(18)
        // SymbolGlyph.fontColor 按图层接收颜色数组，单色也传单元素数组
        .fontColor([this.themePrimary])
    }
    .type(ButtonType.Normal)
    .width(ICON_BTN_SIZE)
    .height(ICON_BTN_SIZE)
    .borderRadius(10)
    .backgroundColor(this.themeSurface)
    .attributeModifier(this.buttonMaterial)
    // 命中区外扩到 44（最小触达边长）：负偏移 + 尺寸 = 四边各扩 4，
    // 布局仍是 36×36，操作行高度不被撑大（设计稿硬约束 ③）。
    .responseRegion({
      x: -(ICON_BTN_HIT - ICON_BTN_SIZE) / 2,
      y: -(ICON_BTN_HIT - ICON_BTN_SIZE) / 2,
      width: ICON_BTN_HIT,
      height: ICON_BTN_HIT
    })
    .scale({ x: this.pressScale, y: this.pressScale })
    .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressScale = PRESS_SCALE;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressScale = 1;
      }
    })
    .onClick((): void => {
      this.onClickAction();
    })
    .accessibilityText(this.accessibilityLabel)
  }
}
