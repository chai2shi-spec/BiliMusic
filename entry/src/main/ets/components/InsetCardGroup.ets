/**
 * iOS 设置风格「分组卡片」基础组件（Settings / Playlists 通用）。
 *
 * 视觉 token（简约 iOS）：
 *   · 卡片：bg_card 白底、圆角 12、左右各让 16vp 出屏缘（inset grouped）；
 *   · 行分隔线：bg_divider，左缩进 16 与行文字对齐，末行不画；
 *   · 区块标题：13fp text_secondary，位于卡片上方，左缘 20；
 *   · 区块脚注：12fp text_tertiary，位于卡片下方，左右 20。
 *
 * ⚠️ SectionHeader / SectionFooter 的文本必须用 @Prop：普通成员只在组件创建时
 * 赋值一次，父组件重渲染不会刷新（存储脚注含动态文案，普通成员会冻结）。
 */

/**
 * 分组卡片容器。行内容经尾随闭包传入（映射到唯一的 @BuilderParam）：
 *
 *   InsetCard() {
 *     Row() { … }.padding(CARD_ROW_PADDING)
 *     CardDivider()
 *     Row() { … }.padding(CARD_ROW_PADDING)
 *   }
 *
 * 结构：外层 Row 负责左右 16vp 让位（padding 在自身宽内，不溢出屏缘），
 * 内层 Column layoutWeight(1) 承载卡片底色 / 圆角 / 裁剪。
 * ⚠️ 不能用 width('100%') + margin：百分比宽不含外边距，会向右溢出 16vp。
 * clip(true)：行按压态底色（press_overlay）随圆角裁剪，不出方角。
 */
@Component
export struct InsetCard {
  /** 尾随闭包缺省时的空兜底（不渲染任何内容） */
  @Builder
  defaultCardContent(): void {
  }

  @BuilderParam cardContent: () => void = this.defaultCardContent;

  build() {
    Row() {
      Column() {
        this.cardContent()
      }
      .layoutWeight(1)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(12)
      .clip(true)
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }
}

/** 卡片内行间分隔线：左缩进 16 与行文字对齐（末行不画由调用方控制） */
@Component
export struct CardDivider {
  build() {
    Divider()
      .color($r('app.color.bg_divider'))
      .margin({ left: 16 })
  }
}

/** 区块标题：卡片上方的小字号灰字（如「播放」「下载」「我的歌单」） */
@Component
export struct SectionHeader {
  @Prop headerText: string = '';

  build() {
    Text(this.headerText)
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 8 })
  }
}

/** 区块脚注：卡片下方的小字号说明文字（可多行，动态文案随父组件刷新） */
@Component
export struct SectionFooter {
  @Prop noteText: string = '';

  build() {
    Text(this.noteText)
      .fontSize(12)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 4 })
  }
}
