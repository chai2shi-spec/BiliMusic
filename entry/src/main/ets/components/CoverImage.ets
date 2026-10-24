/**
 * 网络封面图（带加载占位与失败兜底）。
 *
 * 三态：
 *   · 加载中 —— Image 直接挂 brand_surface 底色，像素到达前透出浅粉，不留白；
 *   · 加载失败 —— onError 置 loadFailed，切换为浅粉占位块 + 弱化音符图标；
 *   · url 为空 —— 直接显示占位块（此前裸 Image('') 是完全透明的空洞）。
 *
 * ⚠️ 可靠性红线（「封面 = 粉色遮罩」bug 的两次教训）：
 *   1. 图片本体永远渲染、可见性绝不依赖 onComplete —— 本工程运行环境实测
 *      onComplete 不可靠（首版 bug：图片显形绑回调，回调不触发 → 永久隐形）；
 *   2. **不在图片上叠任何「需要退出条件」的覆盖层**。呼吸粉晕版的教训：
 *      粉晕的退出绑 onComplete，回调不触发 → 粉晕永久盖在**已加载**的封面
 *      上脉动（全列表「粉色遮罩」复发）。加载中的提示就是 Image 自带的
 *      brand_surface 底色 —— 零回调、零定时器，任何路径下都留不下遮罩。
 *
 * 失败标记归 @State、url 变化经 @Watch 复位：本组件用于 ForEach / LazyForEach 的
 * 行内封面，行 builder 里放不了 @State，必须由组件自持；切歌 / 换行复用时
 * 新 url 会重新走一次加载，不会把上一行的失败态带过来。
 *
 * 特殊位点（播放页唱片 / 背景大图）有各自的转场 / 模糊链，不走本组件，
 * 在各自组件里用自身 @State 就地兜底。
 */

import { STORE_THEME_PRIMARY, STORE_THEME_SURFACE } from '../common/Constants';

/**
 * @Reusable（2026-10-23 性能审查）：行内封面随宿主列表（LazyForEach）复用 ——
 * 复用时 url 经 @Prop 重赋值，@Watch onUrlChanged 复位失败标记，
 * 数据链自洽，无需 aboutToReuse 额外处理。
 */
@Reusable
@Component
export struct CoverImage {
  /** 图片地址；空串直接渲染占位块 */
  @Prop @Watch('onUrlChanged') url: string = '';
  /** 显示宽（vp） */
  @Prop imgWidth: number = 48;
  /** 显示高（vp） */
  @Prop imgHeight: number = 48;
  /** 圆角（vp）；圆形传宽高的一半 */
  @Prop imgRadius: number = 8;
  /**
   * 无障碍描述（歌名 / 歌单名），由调用方传入。
   * 空串 = 纯装饰图（行内文字已表意），读屏跳过；非空 = 可聚焦并朗读该名称。
   */
  @Prop altText: string = '';
  /** 加载失败标记：url 变化时复位，同曲不反复重试 */
  @State loadFailed: boolean = false;
  /** 主题色运行时值：占位块底色与音符图标跟随切色刷新 */
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';

  onUrlChanged(): void {
    this.loadFailed = false;
  }

  build() {
    if (this.url.length === 0 || this.loadFailed) {
      Stack() {
        SymbolGlyph($r('sys.symbol.waveform'))
          .fontSize(Math.min(this.imgWidth, this.imgHeight) * 0.4)
          .fontColor([this.themePrimary])
          .opacity(0.45)
          // 占位音符是纯装饰图形：读屏聚焦它只会念「波形」，无信息量
          .accessibilityLevel('no')
      }
      .width(this.imgWidth)
      .height(this.imgHeight)
      .borderRadius(this.imgRadius)
      .backgroundColor(this.themeSurface)
      // 占位态仍念歌名：失败/无图不代表这行内容变没了
      .accessibilityText(this.altText)
      .accessibilityLevel(this.altText.length > 0 ? 'yes' : 'no')
    } else {
      // 网络图：**永远渲染**（可见性不依赖任何回调）。加载中的提示就是它
      // 自带的 brand_surface 底色 —— 像素到达前透出浅粉，不留白也不叠覆盖层。
      Image(this.url)
        .width(this.imgWidth)
        .height(this.imgHeight)
        .borderRadius(this.imgRadius)
        .objectFit(ImageFit.Cover)
        .backgroundColor(this.themeSurface)
        .onError((): void => {
          this.loadFailed = true;
        })
        .accessibilityText(this.altText)
        .accessibilityLevel(this.altText.length > 0 ? 'yes' : 'no')
    }
  }
}
