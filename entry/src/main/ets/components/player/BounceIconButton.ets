/**
 * 通用回弹图标按钮（无底板纯图标 + 单次点击回弹）。
 *
 * 用途：切歌（上一曲 / 下一曲）、播放模式、播放列表等控制键 —— 只做
 * 点击瞬间的一次 scale 缩小回弹，**无持续动画、无定时器**，与播放态完全解耦。
 * buttonSize 只作为透明命中区（保证点按手感），不渲染任何可见底板。
 */

@Component
export struct BounceIconButton {
  /** SymbolGlyph 图标资源（@Prop：播放模式等图标会随父组件状态变化刷新） */
  @Prop icon: Resource = $r('sys.symbol.play');
  /** 图标字号（vp） */
  iconSize: number = 24;
  /** 透明命中区直径（vp），不渲染底板 */
  buttonSize: number = 44;
  /** 点击回调（回弹动效由本组件自理，回调只管业务） */
  onTap?: () => void = undefined;

  /** 本按钮独占的回弹缩放（不与任何其他动画共用状态） */
  @State bounceScale: number = 1;

  /** 点击：一次快速缩小回弹（关键帧驱动，末帧钉回 1） */
  private playBounce(): void {
    this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
      {
        duration: 0,
        event: (): void => {
          this.bounceScale = 1;
        }
      },
      {
        duration: 90,
        curve: Curve.EaseIn,
        event: (): void => {
          this.bounceScale = 0.86;
        }
      },
      {
        duration: 170,
        curve: Curve.EaseOut,
        event: (): void => {
          this.bounceScale = 1.04;
        }
      },
      {
        duration: 100,
        curve: Curve.EaseOut,
        event: (): void => {
          this.bounceScale = 1;
        }
      }
    ]);
  }

  build() {
    Column() {
      SymbolGlyph(this.icon)
        .fontSize(this.iconSize)
        .fontColor([Color.White])
        .opacity(0.86)
    }
    .width(this.buttonSize)
    .height(this.buttonSize)
    .scale({ x: this.bounceScale, y: this.bounceScale })
    .onClick((): void => {
      this.playBounce();
      if (this.onTap !== undefined) {
        this.onTap();
      }
    })
  }
}
