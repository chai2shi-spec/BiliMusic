/**
 * 骨架屏条目（单曲列表占位）：形状贴合真实内容 —— 40 圆头像 + 两条文字条，
 * 占位色 brand_surface（浅粉，贴合品牌基调；深色模式自动切换深梅色）。
 *
 * 替换掉原先「加载中…」/ LoadingProgress 的文字级反馈：骨架形状对齐内容布局，
 * 加载完成后内容「落位」不跳动（shimmer 扫光 + 同构占位是骨架屏的两件套）。
 *
 * 扫光实现：一条 64vp 宽的品牌粉渐变高光带，从容器左缘外扫到右缘外，
 * 1200ms Linear 无限循环。挂在每行自己的 Stack 上并 clip(true)：
 *   · 动画生命周期跟随组件，页面卸载自动回收，无泄漏；
 *   · translate 声明在 .animation() 之前，只有 shimmerX 这一个可变属性
 *     会被循环动画接管，占位块等静态属性不受影响。
 * 起跑时机放在 onAreaChange（首次量到真实宽度）：translate 用 vp 数值驱动，
 * 必须先知道容器宽度才能确定终点，避免用百分比 translate 在部分版本不可动画。
 */

/** 扫光高光带宽度（vp） */
const SHIMMER_BAND_VP: number = 64;
/** 扫光单程时长（ms）：1200ms Linear 循环 */
const SHIMMER_DURATION_MS: number = 1200;
/**
 * 扫光渐变：品牌粉 25% 峰值透明度。刻意不用白色——浅色模式下 brand_surface
 * 是近白的浅粉（#FFF1F5），白光扫过几乎不可见；粉光在浅 / 深两种模式下都清晰。
 */
const SHIMMER_GRADIENT: [ResourceColor, number][] = [
  ['#00FB7299', 0],
  ['#40FB7299', 0.5],
  ['#00FB7299', 1]
];

@Component
export struct SkeletonTrackItem {
  /** 扫光带当前横移（vp）：初始停在容器左缘外，量到宽度后向右扫出 */
  @State shimmerX: number = -SHIMMER_BAND_VP;
  /** 容器实测宽度（vp）：扫光终点 = 宽度 + 带宽 */
  private hostWidthVp: number = 0;
  private shimmerStarted: boolean = false;

  build() {
    Stack() {
      // 占位形状：40 圆头像 + 标题条 + 副标题条（贴合 TrackItem 的两行文字）
      Row() {
        Row()
          .width(40)
          .height(40)
          .borderRadius(20)
          .backgroundColor($r('app.color.brand_surface'))

        Column({ space: 8 }) {
          Row()
            .width('62%')
            .height(14)
            .borderRadius(7)
            .backgroundColor($r('app.color.brand_surface'))
          Row()
            .width('38%')
            .height(10)
            .borderRadius(5)
            .backgroundColor($r('app.color.brand_surface'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })

      // 扫光高光带：clip 在本行范围内横扫
      Row()
        .width(SHIMMER_BAND_VP)
        .height('100%')
        .linearGradient({ angle: 90, colors: SHIMMER_GRADIENT })
        .translate({ x: this.shimmerX })
        .animation({
          duration: SHIMMER_DURATION_MS,
          curve: Curve.Linear,
          iterations: -1,
          playMode: PlayMode.Normal
        })
    }
    .width('100%')
    .clip(true)
    .onAreaChange((_old: Area, cur: Area): void => {
      const w: number = cur.width as number;
      if (w > 0) {
        this.hostWidthVp = w;
        if (!this.shimmerStarted) {
          this.shimmerStarted = true;
          // 触发一次状态变化即可：.animation(iterations: -1) 接管后自动无限循环
          this.shimmerX = this.hostWidthVp + SHIMMER_BAND_VP;
        }
      }
    })
  }
}
