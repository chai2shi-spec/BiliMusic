/**
 * 骨架屏条目（单曲列表占位）：形状贴合真实内容 —— 64 圆角封面 + 双标题条 +
 * 副标题条，占位色 brand_surface（浅粉，贴合品牌基调；深色模式自动切换深梅色）。
 *
 * 骨架形状对齐内容布局，加载完成后内容「落位」不跳动 ——
 * 优于「加载中…」/ LoadingProgress 的文字级反馈。
 *
 * ⚠️ 扫光带（64vp 宽品牌粉渐变高光带从左往右横扫，1200ms Linear 无限循环）
 * 在刷新头 / 首屏骨架 / 加载更多三处都被反馈「粉色竖条来回走，像杂音」。
 * 骨架屏只保留静态占位形状 + 入场错峰；**不要加任何扫光 / 呼吸类
 * 循环动效**。
 *
 * 入场错峰：前 SKEL_ENTER_MAX_ITEMS 条「下移 8vp + 淡入」，相邻延迟 70ms，
 * 由 onAppear 里的显式 animateTo 驱动（带 delay），播一次即止。
 */

import { STORE_THEME_SURFACE } from '../common/Constants';

/** ── 入场错峰（仅首屏 ≤6 条参与，第 7 条起直接出现）── */
/** 入场起始位移（vp）：8vp 上浮 */
const SKEL_ENTER_OFFSET_VP: number = 8;
/** 单条入场时长（ms，normal 档） */
const SKEL_ENTER_DURATION_MS: number = 250;
/** 相邻条目入场延迟（ms） */
const SKEL_ENTER_STAGGER_MS: number = 70;
/** 参与错峰的条数上限 */
const SKEL_ENTER_MAX_ITEMS: number = 6;

@Component
export struct SkeletonTrackItem {
  /**
   * 在父列表 ForEach 里的下标，仅用于计算错峰延迟（普通成员，挂载时定值即可）：
   * 前 SKEL_ENTER_MAX_ITEMS 条做「下移 8vp + 淡入」错峰，其余直接出现——
   * 否则长列表滚到底部时新出现的骨架还在逐条错峰。默认 0 兼容不传下标的调用方。
   * -1 = 不播入场（下拉刷新头专用：显隐节奏由刷新状态机自己管，纯静态）。
   */
  index: number = 0;
  /** 入场位移 / 透明度：onAppear 里显式 animateTo 驱动（带 delay） */
  @State enterOffsetY: number = 0;
  @State enterOpacity: number = 1;
  /** 主题色浅底：占位条颜色跟随切色刷新 */
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';

  aboutToAppear(): void {
    if (this.index >= 0 && this.index < SKEL_ENTER_MAX_ITEMS) {
      this.enterOffsetY = SKEL_ENTER_OFFSET_VP;
      this.enterOpacity = 0;
    }
  }

  build() {
    // 占位形状：64 圆角封面 + 双标题条 + 副标题条
    // （标题条两条模拟 TrackItem maxLines(2) 的双行标题）
    Row() {
      Row()
        .width(64)
        .height(64)
        .borderRadius(8)
        .backgroundColor(this.themeSurface)

      Column({ space: 8 }) {
        Row()
          .width('62%')
          .height(14)
          .borderRadius(7)
          .backgroundColor(this.themeSurface)
        Row()
          .width('45%')
          .height(14)
          .borderRadius(7)
          .backgroundColor(this.themeSurface)
        Row()
          .width('38%')
          .height(10)
          .borderRadius(5)
          .backgroundColor(this.themeSurface)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    // 入场错峰：translate/opacity 由 onAppear 的显式 animateTo 驱动
    .translate({ y: this.enterOffsetY })
    .opacity(this.enterOpacity)
    .onAppear((): void => {
      if (this.index >= 0 && this.index < SKEL_ENTER_MAX_ITEMS) {
        this.getUIContext().animateTo({
          duration: SKEL_ENTER_DURATION_MS,
          curve: Curve.EaseOut,
          delay: this.index * SKEL_ENTER_STAGGER_MS
        }, (): void => {
          this.enterOffsetY = 0;
          this.enterOpacity = 1;
        });
      }
    })
  }
}
