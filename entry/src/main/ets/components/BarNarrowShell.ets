/**
 * 标题行收窄容器（平板模式宽度适配）：HDS titleBar 的 stackBuilder
 * 横跨目的地整列全宽，而页面内容列被 constraintSize 收窄居中 —— 大屏上标题行
 * 会贴到整列左缘、与居中内容错位。外层 Row 居中 + 内层 Column constraintSize
 * （上限与页面内容列 contentMaxWidth 完全同口径 600/720），标题行与内容列
 * 同宽对齐；两侧空白区 hitTestBehavior(Transparent) 穿透点击。
 * sm 回退 600（窗口 <600vp）天然无操作，手机零变化。
 */

import { BreakpointConstants } from '../common/constants/BreakpointConstants';

@Component
export struct BarNarrowShell {
  /** 当前断点（与各页同源：AppStorage CURRENT_BREAKPOINT，免逐页传参） */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string =
    BreakpointConstants.BREAKPOINT_SM;
  /** 被收窄的标题行内容（各页的 xxxBar @Builder，经箭头函数传入保持 this 指向页面） */
  @BuilderParam bar: () => void = this.emptyBar;

  @Builder
  emptyBar() {
  }

  build() {
    Row() {
      Column() {
        this.bar()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
