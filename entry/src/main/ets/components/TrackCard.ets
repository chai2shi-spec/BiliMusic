/**
 * 单曲网格卡（「条目展示 = 大封面」模式）。
 *
 * TrackItem 的网格版：双列大封面 + 小字标题，prop 面与 TrackItem 对齐
 * （track / onPlay / moreMenuItems / downloaded / heardText），各列表页在
 * 大封面分支用它替换行内 TrackItem，交互契约不变：整卡点击 = onPlay，
 * 「⋯」bindMenu 弹父页面标准菜单（菜单项由 moreMenuItems 提供）。
 *
 * 视觉（对齐 iOS 大封面网格）：
 *   · 封面：整卡宽方形（Stack aspectRatio 1），radius 10，按 360 请求高清
 *     缩略图（约 134vp 卡宽 —— 含 24vp 行页边距，仍近 3x
 *     余量）；加载中 / 失败由 CoverImage 兜浅粉占位；
 *   · 标题：13sp 两行（lineHeight 17，定高 34 两行区 → 同排卡高一致），小字标题；
 *   · 「已下载」：封面左上半透明深色小胶囊（行内版的浅底 Chip 叠在封面上读不清）；
 *   · 「上次听到 x:xx」：标题下一行小字（最近播放页续播提示，其余页面空串不渲染）。
 *
 * ⚠️ 「⋯」命中区 36×36 是对 44vp 触达下限的刻意折衷（计划内偏差）：
 * 44 会吃掉约 1/4 卡宽，36 已可可靠命中；热区与整卡 onPlay 之间视觉留白缓冲。
 *
 * 按压反馈＝纯缩放形变（0.96 / 150ms EaseOut，比行内 0.9 收敛 —— 大卡面
 * 缩到 0.9 视觉过猛），专用 @State + 紧跟 .scale() 的独立 .animation()，
 * 不与任何其他组件的动画状态共用变量。
 *
 * 与 TrackItem 的差异（有意）：无入场错峰 —— TrackEntranceQueue 是
 * TrackItem.ets 的模块私有类，错峰逻辑不跨文件复用；网格条目挂载即显示，
 * 滚动中懒加载为主，错峰收益小。
 */

import { Track, buildTrack } from '../model/MusicModels';
import { toThumbUrl } from '../utils/TextUtil';
import { CoverImage } from './CoverImage';
import { PRESS_ANIM_MS } from '../common/constants/InteractionConstants';
import {
  STORE_CURRENT_TRACK,
  STORE_THEME_DEEP,
  STORE_THEME_PRIMARY
} from '../common/Constants';
import { MaterialCompat } from '../utils/MaterialCompat';

/** 「⋯」圆钮边长（视觉 16px 字号居中留白）：网格内对 44vp 触达下限的折衷（见头注释） */
const CARD_MORE_HIT: number = 36;

/** 网格卡按压缩放：比行内 0.9 收敛（大卡面缩 0.9 视觉过猛） */
const CARD_PRESS_SCALE: number = 0.96;

/** 「正在播放」整卡高亮底色的透明度：与 TrackItem 整行高亮同档 */
const PLAYING_TINT_ALPHA: number = 0.10;

@Reusable
@Component
export struct TrackCard {
  @Prop track: Track = buildTrack({});
  /** 「⋯」的标准菜单项（bindMenu 的 MenuElement 数组由父页面提供，同 TrackItem） */
  moreMenuItems: (track: Track) => MenuElement[] = (_track: Track): MenuElement[] => [];
  /** 整卡点击回调（播放），由父页面提供 */
  onPlay: (track: Track) => void = (_track: Track): void => {};
  /** 已下载徽标（歌单详情传 true，其余页面不传）：封面左上小胶囊 */
  @Prop downloaded: boolean = false;
  /** 「上次听到 x:xx」（最近播放页续播提示）：空串整块不渲染 */
  @Prop heardText: string = '';
  /** 主题深色（选中勾选圈实底）：跟随切色刷新 */
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  /** 当前播放曲目（AppStorage 订阅）：正在播放的卡片整卡高亮 + 标题主题色，切歌自动跟随 */
  @StorageProp(STORE_CURRENT_TRACK) currentTrack: Track | null = null;
  /** 主题色运行时值：正在播放卡片的高亮底色与标题颜色跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /**
   * 多选模式开关（可选）：true = 整卡点击切换选中而非播放、隐藏「⋯」、
   * 封面右上显示勾选圈。默认 false —— 共用页面不传时布局与交互零改动零影响。
   */
  @Prop selecting: boolean = false;
  /** 本卡是否选中：父页面 selectedIds 驱动，勾选圈只读回显 */
  @Prop selected: boolean = false;
  /** 选择模式下点卡 / 点勾选圈的切换回调 */
  onToggleSelect: (track: Track) => void = (_track: Track): void => {};
  /** 按压缩放（本卡独占动画状态，见头注释） */
  @State pressScale: number = 1;

  /** 本卡是否正在播放：id 精确匹配（TrackItem / QueueSheet 同一语义，多 P 条目 id 唯一） */
  private isPlayingTrack(): boolean {
    const cur: Track | null = this.currentTrack;
    return cur !== null && cur.id === this.track.id;
  }

  /** 卡背景：正在播放 = 淡主题色高亮；否则透明 */
  private cardBackground(): ResourceColor {
    return this.isPlayingTrack()
      ? MaterialCompat.withAlpha(this.themePrimary, PLAYING_TINT_ALPHA)
      : Color.Transparent;
  }

  build() {
    Column() {
      // 封面层：方形大封面（尺寸交给 CoverImage 填充模式）+ 左上「已下载」
      // 胶囊 + 右上「⋯」菜单钮；占位 / 失败态由 CoverImage 三态兜底。
      Stack({ alignContent: Alignment.TopEnd }) {
        CoverImage({
          url: toThumbUrl(this.track.coverUrl, 360),
          imgRadius: 10,
          fillParent: true,
          altText: this.track.title
        })

        // 「已下载」胶囊：深底白字（浅底 Chip 叠在封面上对比度不足）
        if (this.downloaded) {
          Text('已下载')
            .fontSize(10)
            .fontColor(Color.White)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(8)
            .backgroundColor('rgba(0, 0, 0, 0.55)')
            .position({ x: 6, y: 6 })
            .accessibilityText('已下载')
        }

        // 「⋯」菜单钮：半透明深色圆底 + 白色图形，bindMenu 弹父页面标准菜单。
        // 命中区 36×36（对 44 下限的折衷，见头注释）。
        // 多选模式下隐藏（Visibility.None 不占布局）：勾选圈接管这个角落，
        // 防误弹菜单。
        Row() {
          SymbolGlyph($r('sys.symbol.more'))
            .fontSize(16)
            .fontColor([Color.White])
        }
        .width(CARD_MORE_HIT)
        .height(CARD_MORE_HIT)
        .borderRadius(CARD_MORE_HIT / 2)
        .backgroundColor('rgba(0, 0, 0, 0.35)')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 6, right: 6 })
        .visibility(this.selecting ? Visibility.None : Visibility.Visible)
        .accessibilityText('更多操作')
        .accessibilityLevel('yes')
        .bindMenu(this.moreMenuItems(this.track))

        // 多选勾选圈（可选）：占「⋯」原位 —— 选择模式下「⋯」不参与布局，
        // 22vp 圈心对齐 36vp「⋯」钮心（margin 13 = 6 + (36-22)/2）。
        // 未选中 = 白色空圈（封面任意底色可辨）；选中 = 主题深色实底 + 白勾。
        if (this.selecting) {
          Row() {
            if (this.selected) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(14)
                .fontColor([Color.White])
            }
          }
          .width(22)
          .height(22)
          .borderRadius(11)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.selected ? this.themeDeep : Color.Transparent)
          .border({
            width: 1.5,
            color: this.selected ? this.themeDeep : Color.White
          })
          .margin({ top: 13, right: 13 })
          .accessibilityText(this.selected ? '已选中' : '未选中')
          .accessibilityLevel('yes')
        }
      }
      .width('100%')
      .aspectRatio(1)

      // 小字标题（两行，第二行省略）：外层定高 Column 锁两行区（34 = 17×2）——
      // 一行标题也占满两行区，同排网格卡高度一致（配合配对行 Top 对齐，封面
      // 严格同高起步）。Column 子项默认从顶起排（Text 定高会垂直居中，故不能
      // 直接给 Text 设 height）。内层显式 lineHeight(17) 锁行高（默认行高
      // 随字体浮动会破坏网格行间距一致性）。
      Column() {
        Text(this.track.title)
          .fontSize(13)
          .fontColor(this.isPlayingTrack() ? this.themePrimary : $r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(17)
          .width('100%')
      }
      .height(34)
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 6 })

      // 「上次听到 x:xx」：最近播放续播提示，其余页面空串整块不渲染。
      if (this.heardText.length > 0) {
        Text(this.heardText)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .width('100%')
          .margin({ top: 2 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 网格行距：卡底统一 12vp（与 TWO_COL_GAP_VP
    // 同节奏），行与行分隔。挂卡根而非配对行：本组件覆盖全部网格页，一处生效；
    // margin 是布局量、不参与下方 scale 按压变换。
    .margin({ bottom: 12 })
    // 「正在播放」整卡高亮：淡主题色底 + 12 圆角。声明在 .animation() 之前 →
    // 切歌时随 150ms EaseOut 淡出/淡入；封面（radius 10）四角露出 12 圆角
    // 细边 + 标题/续播区淡色带，读作「这张卡正在播放」。
    .backgroundColor(this.cardBackground())
    .borderRadius(12)
    // 按压缩放：.animation() 紧跟 .scale() 且位于链尾，接管 scale（按压）与
    // 在它之前声明的 backgroundColor（高亮切换）两个可变属性 —— 两者都走
    // 150ms EaseOut 是有意为之；width/margin 在其之前但从不变化，不会被卷进动画。
    .scale({ x: this.pressScale, y: this.pressScale })
    .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
    // onTouch 只回写缩放状态、不消费事件：onClick 照常触发；列表滚动抢占
    // 手势时系统派发 Cancel，卡自动回弹。
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressScale = CARD_PRESS_SCALE;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressScale = 1;
      }
    })
    .onClick((): void => {
      // 多选态：整卡是「切换选中」的命中区而非播放（与「⋯」隐藏配套）
      if (this.selecting) {
        this.onToggleSelect(this.track);
        return;
      }
      this.onPlay(this.track);
    })
  }
}
