/**
 * 热歌榜单曲行（HomePage 热歌榜页签，@Reusable 独立组件）：
 * 序号列（前三高亮）+ 96px 方图 + 标题/歌手·时长双行，整行点按回调父级
 * 实时搜 B 站匹配播放（playHotSongAt，无连播链）。匹配中的行行尾转圈反馈。
 *
 * @Reusable（TrackItem 同款纪律）：列表 LazyForEach 启用节点复用 ——
 * 滚动时滑出的行进复用池、滑入侧出池复用，热歌榜百级条目滚动不反复建销节点。
 * 复用安全性：所有外部数据经 @Prop 进来（复用时框架重赋值即刷新）。
 *
 * 「匹配中」指示刻意不走 @Prop（LazyForEach 不会因父组件 @State 变化重跑
 * itemGenerator，@Prop matching 不会重新下推）而走 AppStorage 订阅：
 * HomePage 写 STORE_HOT_MATCHING_INDEX，本组件 @StorageProp 订阅 ——
 * 子组件内自成重渲染，复用节点也即时跟随（切行、清除均为全局单飞互斥）。
 */

import { NeteaseHotSong } from '../api/NeteaseApi';
import { toThumbUrl, formatDurationText } from '../utils/TextUtil';
import { CoverImage } from './CoverImage';
import { NAV_H_PADDING } from '../utils/NavTitleStyle';
import { STORE_THEME_DEEP, STORE_HOT_MATCHING_INDEX } from '../common/Constants';

@Reusable
@Component
export struct HotSongRow {
  /** 榜单曲（@Prop：复用时框架重赋值即刷新） */
  @Prop song: NeteaseHotSong = { title: '', artist: '', durationSec: 0, coverUrl: '' };
  /** 榜位（0 起）：序号列展示 + 前三序号高亮 */
  @Prop index: number = 0;
  /** 匹配中的榜位（-1 = 无）：本组件内订阅，见文件头注释 */
  @StorageProp(STORE_HOT_MATCHING_INDEX) matchingIndex: number = -1;
  /** 主题色深色（hex 字符串，ThemeColors 发布）：前三序号 / 转圈颜色，切主题即时跟随 */
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  /** 整行点按：参数回传当刻 @Prop song（而非捕获下标），复用节点回调取值恒新 */
  onPlay?: (song: NeteaseHotSong) => void = undefined;

  build() {
    Row({ space: 12 }) {
      Text(`${this.index + 1}`)
        .fontSize(13)
        .fontColor(this.index < 3 ? this.themeDeep : $r('app.color.text_tertiary'))
        .width(24)
        .textAlign(TextAlign.Center)
      CoverImage({
        url: toThumbUrl(this.song.coverUrl, 96),
        imgWidth: 48,
        imgHeight: 48,
        imgRadius: 8,
        altText: this.song.title
      })
      Column() {
        Text(this.song.title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${this.song.artist} · ${formatDurationText(this.song.durationSec)}`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 行尾不放常驻播放键（整行点按即播）：仅匹配中的行在行尾给转圈反馈
      if (this.matchingIndex === this.index) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color(this.themeDeep)
      }
    }
    .width('100%')
    // 左右让位 NAV_H_PADDING 基线：与搜索框行 / chip 条 / 播放全部 CTA 同一条
    // 水平缘（TrackItem / SkeletonTrackItem 同款 16vp），序号不贴屏幕左缘。
    .padding({ left: NAV_H_PADDING, right: NAV_H_PADDING, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .onClick((): void => {
      if (this.onPlay !== undefined) {
        this.onPlay(this.song);
      }
    })
  }
}
