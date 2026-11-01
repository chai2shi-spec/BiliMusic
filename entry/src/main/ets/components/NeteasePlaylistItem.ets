/**
 * 热门歌单列表项（首页「热门歌单」netease tab 专用，双模式）。
 *
 * 与「条目展示」设置（长条 / 大封面）联动，版式分别对齐工程既有单曲组件：
 *   · NeteasePlaylistRow（长条模式）—— TrackItem 同款行：64vp 圆角封面 +
 *     16sp 双行歌单名 + 13sp 副行「N播放 · N首」，整行点击，按压 0.9 缩放；
 *   · NeteasePlaylistCard（大封面模式）—— TrackCard 同款卡：整卡宽方形封面
 *     （radius 10）+ 13sp 两行名 + 12sp 副题，按压 0.96 收敛档缩放。
 *
 * 两模式点击都 push 'NeteasePlaylist' 预览页（网格行已有的 id / 名称 / 封面
 * 作首帧兜底传入，真值由预览页现拉覆盖）。组件为网易云专用，不做通用化：
 * 路由跳转直接内置，不向父页面回调。
 *
 * 与 TrackItem / TrackCard 的差异（有意）：无「⋯」菜单（歌单没有曲目级
 * 菜单动作）、无入场错峰（TrackCard 同样没有，滚动懒加载为主）、无正在
 * 播放高亮（歌单不是可播条目）。
 */

import { NeteasePlaylistSummary } from '../api/NeteaseApi';
import { toThumbUrl } from '../utils/TextUtil';
import { CoverImage } from './CoverImage';
import { NavStackHolder } from '../service/NavStackHolder';
import { NeteasePlaylistRouteParam } from '../service/NavRouteParams';
import { PRESS_SCALE, PRESS_ANIM_MS } from '../common/constants/InteractionConstants';

/** 大封面卡按压缩放：比行内 0.9 收敛（大卡面缩 0.9 视觉过猛，TrackCard 同款） */
const CARD_PRESS_SCALE: number = 0.96;

/** 播放量 → 1.2万 口径（PlaylistImportPage / CollectionDetailPage 同款） */
function formatPlayCount(n: number): string {
  if (n >= 100000000) {
    return `${(n / 100000000).toFixed(1)}亿`;
  }
  if (n >= 10000) {
    return `${(n / 10000).toFixed(1)}万`;
  }
  return `${n}`;
}

/** 副行文本：「N播放 · N首」（两模式共用同一口径） */
function subtitleOf(p: NeteasePlaylistSummary): string {
  return `${formatPlayCount(p.playCount)}播放 · ${p.trackCount}首`;
}

/** 点击：进 NeteasePlaylist 预览页（首帧兜底参数 = 网格行已有数据） */
function openPlaylistPreview(p: NeteasePlaylistSummary): void {
  NavStackHolder.push('NeteasePlaylist',
    new NeteasePlaylistRouteParam(p.id, p.name, p.coverUrl));
}

/**
 * 长条模式行（TrackItem 同款版式）：
 * 封面 64（高度预算 = 名字两行 lineHeight(21)×2 + 间距 4 + 副行 lineHeight(17)
 * = 63 ≤ 64，短名单行时行高不变），名字双行省略，副行「N播放 · N首」。
 */
@Component
export struct NeteasePlaylistRow {
  @Prop summary: NeteasePlaylistSummary;
  /** 按压缩放（独立动画状态，本行独占，TrackItem 同款） */
  @State pressScale: number = 1;

  build() {
    Row() {
      // 64vp 显示位按 2x 请求图床缩略图（网易云图床不在 hdslb 域，
      // toThumbUrl 原样返回）；加载中 / 失败由 CoverImage 兜浅粉占位
      CoverImage({
        url: toThumbUrl(this.summary.coverUrl, 128),
        imgWidth: 64,
        imgHeight: 64,
        imgRadius: 8,
        altText: this.summary.name
      })

      Column() {
        Text(this.summary.name)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(21)
          .width('100%')
        Text(subtitleOf(this.summary))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .lineHeight(17)
          .width('100%')
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
    }
    .width('100%')
    .padding({ left: 16, right: 4, top: 10, bottom: 10 })
    // 按压反馈＝纯缩放形变（0.9 / 150ms EaseOut，TrackItem 同款）：
    // .scale() + 紧跟 .animation() 且位于链尾，只接管按压缩放。
    .scale({ x: this.pressScale, y: this.pressScale })
    .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
    // onTouch 只回写缩放状态、不消费事件：onClick 照常在抬起时触发
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressScale = PRESS_SCALE;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressScale = 1;
      }
    })
    .onClick((): void => {
      openPlaylistPreview(this.summary);
    })
  }
}

/**
 * 大封面模式卡（TrackCard 同款版式）：整卡宽方形封面（Stack aspectRatio 1，
 * radius 10）+ 两行名区（外层定高 34 锁两行、内层锁 lineHeight）+ 副题。
 */
@Component
export struct NeteasePlaylistCard {
  @Prop summary: NeteasePlaylistSummary;
  /** 按压缩放（TrackCard 同款收敛档 0.96） */
  @State pressScale: number = 1;

  build() {
    Column() {
      Stack() {
        CoverImage({
          // 360 按高清缩略图请求（网易云图床不在 hdslb 域，toThumbUrl 原样返回）
          url: toThumbUrl(this.summary.coverUrl, 360),
          imgRadius: 10,
          fillParent: true,
          altText: this.summary.name
        })
      }
      .width('100%')
      .aspectRatio(1)

      // 两行名区（TrackCard 同款：外层定高 34 锁两行、内层锁 lineHeight 17）
      Column() {
        Text(this.summary.name)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(17)
          .width('100%')
      }
      .height(34)
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 6 })

      Text(subtitleOf(this.summary))
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .width('100%')
        .margin({ top: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 网格行距：卡底统一 12vp（TrackCard 同款）
    .margin({ bottom: 12 })
    // 按压反馈＝纯缩放形变（0.96 / 150ms EaseOut，TrackCard 同款）
    .scale({ x: this.pressScale, y: this.pressScale })
    .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressScale = CARD_PRESS_SCALE;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressScale = 1;
      }
    })
    .onClick((): void => {
      openPlaylistPreview(this.summary);
    })
  }
}
