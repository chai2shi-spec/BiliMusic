/**
 * 通用回弹图标按钮（无底板纯图标 + 单次点击弹跳）。
 *
 * 用途：切歌（上一曲 / 下一曲）、播放模式、播放列表等控制键 —— 只做
 * 点击瞬间的官方 BounceSymbolEffect 弹跳（trigger 形态：bounceTrigger 数值
 * 变化一次播放一次），**无持续动画、无定时器**，与播放态完全解耦。
 * buttonSize 只作为透明命中区（保证点按手感），不渲染任何可见底板。
 *
 * （2026-10-23 官方化：原 keyframeAnimateTo 自绘缩放回弹 1→0.86→1.04→1
 * 改为官方弹跳动效；官方曲线固定，不再有自定义回弹轮廓。）
 */

@Component
export struct BounceIconButton {
  /** SymbolGlyph 图标资源（@Prop：播放模式等图标会随父组件状态变化刷新） */
  @Prop icon: Resource = $r('sys.symbol.play');
  /** 图标字号（vp） */
  iconSize: number = 24;
  /** 透明命中区直径（vp），不渲染底板 */
  buttonSize: number = 44;
  /** 点击回调（弹跳动效由本组件自理，回调只管业务） */
  onTap?: () => void = undefined;

  /**
   * 官方弹跳触发器：数值变化一次播放一次。初值 -1 是官方推荐（防止首帧
   * 挂载误触发），每次点击 +1。
   */
  @State bounceTrigger: number = -1;

  build() {
    Column() {
      SymbolGlyph(this.icon)
        .fontSize(this.iconSize)
        .fontColor([Color.White])
        .opacity(0.86)
        .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE), this.bounceTrigger)
    }
    .width(this.buttonSize)
    .height(this.buttonSize)
    .onClick((): void => {
      this.bounceTrigger++;
      if (this.onTap !== undefined) {
        this.onTap();
      }
    })
  }
}
