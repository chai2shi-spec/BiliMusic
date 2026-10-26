/**
 * 首页快捷卡行（MusicHome HeroBannerSection 移植）。
 *
 * MusicHome 手机首页 hero 横滑轮播的 BiliMusic 落地：竖版封面卡 + 底部
 * 半透明信息条（badge 小标 + 标题/副题 + 播放按钮），语义本地化——
 *   · 最近播放卡（原「现在就听」位）：封面 = 最近一首歌封面，标题 = 最近
 *     一首歌名；点播放按钮 = playAll(最近播放全量)（RecentPage「播放全部」
 *     同语义）；点卡 = 进最近播放页（'Recent'）。
 *   · 收藏歌单卡（原「每日30首」位）：用户在歌单列表 ⋯ 菜单「加入首页」
 *     自选（HomeCardStore 持久化，加入顺序即显示顺序）；点播放按钮 =
 *     playAll(整个歌单)；点卡 = 订阅歌单进 UP 主页 / 普通歌单进详情
 *     （PlaylistsPage.openPlaylist 同款双分支）。
 *   · 「+」添加卡（尾部顺延）：点开宿主 HomePage 的歌单选择器，选中即
 *     等效歌单页 ⋯ 菜单「加入首页」；歌单卡满 HOME_PLAYLIST_CARDS_MAX 张隐藏。
 *   · 上限 10 卡：最近播放 1 + 歌单 9（HOME_PLAYLIST_CARDS_MAX）。
 *
 * 数据由宿主 HomePage 持有（refreshQuickCards 经 STORE_LIBRARY_REV 驱动重灌），
 * 本组件纯展示 + 交互：@Prop 两个数组，不自己读写 LibraryStore（Tabs 常驻页
 * 刷新铁律在宿主侧统一收口）。
 *
 * 几何（MusicHome 187×234 按手机屏占比缩小）：卡 156×184 / 圆角 16 / 间距 12，
 * 行左右缘 NAV_H_PADDING 与搜索框行、chip 条共用同一条水平基线；两卡半可见
 * 暗示可横滑。信息条底衬半透明深色 + BACKGROUND_ULTRA_THICK 模糊
 * （MusicHome 同款），白字在任意封面下都可读。
 */

import { Track, Playlist } from '../model/MusicModels';
import { CoverImage } from './CoverImage';
import { MusicPlayer } from '../player/MusicPlayer';
import { NavStackHolder } from '../service/NavStackHolder';
import { UpSpaceRouteParam, PlaylistDetailRouteParam } from '../service/NavRouteParams';
import { LibraryStore } from '../service/LibraryStore';
import { HOME_PLAYLIST_CARDS_MAX } from '../service/HomeCardStore';
import { toThumbUrl } from '../utils/TextUtil';
import { NAV_H_PADDING } from '../utils/NavTitleStyle';
import { PRESS_SCALE, PRESS_ANIM_MS } from '../common/constants/InteractionConstants';
import { STORE_THEME_DEEP, STORE_THEME_PRIMARY } from '../common/Constants';

/** 单卡宽（vp）：两卡半可见暗示可横滑 */
const QUICK_CARD_WIDTH_VP: number = 156;
/** 单卡高（vp） */
const QUICK_CARD_HEIGHT_VP: number = 184;
/** 卡间距（vp） */
const QUICK_CARD_GAP_VP: number = 12;
/** 卡圆角（vp） */
const QUICK_CARD_RADIUS_VP: number = 16;
/** 封面缩略图请求宽（px）：156vp 卡宽下约 2x 余量 */
const QUICK_CARD_THUMB_PX: number = 320;

/** 单卡视图参数（最近播放卡 / 收藏歌单卡同构，仅数据与行为注入不同） */
interface QuickCardView {
  /** 封面原图 URL；空 = 渐变占位 */
  coverUrl: string;
  /** 封面加载失败的无障碍描述 */
  altText: string;
  /** 信息条小标图标 */
  badgeGlyph: Resource;
  /** 信息条小标文案 */
  badgeText: string;
  /** 卡标题 */
  title: string;
  /** 卡副题 */
  subtitle: string;
  /** 播放按钮可见（有可播内容） */
  showPlay: boolean;
  /** 播放按钮无障碍描述 */
  playA11y: string;
  /** 点播放按钮的播放列表 */
  playTracks: Track[];
  /** 按压高亮 / 触摸归属 key */
  key: string;
  /** 点整卡导航 */
  onOpen: () => void;
}

@Component
export struct HomeQuickCards {
  /** 最近播放全量（最近在前，7 天窗口已过滤）；空 = 占位形态（仍可点进最近播放页） */
  @Prop recentTracks: Track[] = [];
  /** 已加入首页的歌单卡（加入顺序即显示顺序；已删歌单由宿主 refresh 过滤） */
  @Prop cardPlaylists: Playlist[] = [];
  /** 「+」卡点击：宿主弹选择器（本组件纯展示，对话框由 HomePage 持有） */
  onAddClick: () => void = (): void => {};
  /** 主题色深 / 主：空封面渐变占位跟随切色刷新 */
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /** 按压中的卡 key（'recent' 或歌单 id）：单指同一时刻只按一卡，一个变量驱动任意卡缩放 */
  @State pressedKey: string = '';
  private player: MusicPlayer = MusicPlayer.getInstance();

  /** 按压状态回写（歌单页 / 搜索页同款）：Down 记录、Up/Cancel 只清自己 */
  private setPressed(type: TouchType, key: string): void {
    if (type === TouchType.Down) {
      this.pressedKey = key;
    } else if ((type === TouchType.Up || type === TouchType.Cancel) && this.pressedKey === key) {
      this.pressedKey = '';
    }
  }

  /** 空封面渐变占位（最近播放无记录 / 歌单无封面）：主题双色渐变 + 音乐图形 */
  @Builder
  private EmptyCover() {
    Column() {
      SymbolGlyph($r('sys.symbol.waveform'))
        .fontSize(36)
        .fontColor(['rgba(255, 255, 255, 0.9)'])
        .accessibilityLevel('no')
    }
    .width('100%')
    .height('100%')
    .linearGradient({
      angle: 135,
      colors: [[this.themeDeep, 0.0], [this.themePrimary, 1.0]]
    })
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 最近播放卡：点播放 = playAll(最近播放全量)；点卡 = 进最近播放页。
   *
   * ⚠️ [0] 索引读必须用空安全链（?. / ??）而不是 `length > 0 ? [0].x : ''` 三元：
   * release 编译器会把 @Builder 内联 + 三元守卫提升进 if 条件，分支回调体里只剩
   * 裸 `recentTracks[0].x` —— 清空最近播放后该回调被脏元素更新重跑，[0] 为
   * undefined 直接 JSCrash（TypeError: Cannot read property coverUrl of
   * undefined，实测见 er/ 崩溃日志）。空安全链无法被提升剥离，重跑永远安全；
   * 空数组时兜底值与原三元语义完全一致。
   */
  @Builder
  private RecentCard() {
    this.QuickCard({
      coverUrl: this.recentTracks[0]?.coverUrl ?? '',
      altText: this.recentTracks[0]?.title ?? '',
      badgeGlyph: $r('sys.symbol.clock_fill'),
      badgeText: '最近播放',
      title: this.recentTracks[0]?.title ?? '暂无播放记录',
      subtitle: this.recentTracks.length > 0 ? `${this.recentTracks.length} 首` : '去听点什么吧',
      showPlay: this.recentTracks.length > 0,
      playA11y: '播放最近播放',
      playTracks: this.recentTracks,
      key: 'recent',
      onOpen: (): void => {
        NavStackHolder.push('Recent', undefined);
      }
    })
  }

  /** 收藏歌单卡：点播放 = playAll(整个歌单)；点卡 = 订阅进 UP 主页 / 普通进详情 */
  @Builder
  private PlaylistCard(p: Playlist) {
    this.QuickCard({
      coverUrl: p.coverUrl,
      altText: p.name,
      badgeGlyph: $r('sys.symbol.waveform'),
      badgeText: '收藏歌单',
      title: p.name,
      subtitle: `${p.tracks.length} 首`,
      showPlay: p.tracks.length > 0,
      playA11y: `播放${p.name}`,
      playTracks: p.tracks,
      key: p.id,
      onOpen: (): void => {
        // PlaylistsPage.openPlaylist 同款双分支：订阅歌单进 UP 主页（⚠️ helper
        // 判定，收藏夹镜像也有 upMid 但没有「UP 主页」可去），普通进详情
        if (LibraryStore.isUpSubscription(p)) {
          NavStackHolder.push('UpSpace', new UpSpaceRouteParam(p.upMid, p.upName, ''));
          return;
        }
        NavStackHolder.push('PlaylistDetail', new PlaylistDetailRouteParam(p.id));
      }
    })
  }

  /** 快捷卡共用版式：封面（空则渐变占位）+ 底部半透明信息条（小标 + 标题/副题 + 播放按钮） */
  @Builder
  private QuickCard(v: QuickCardView) {
    Stack({ alignContent: Alignment.Bottom }) {
      if (v.coverUrl.length > 0) {
        CoverImage({
          url: toThumbUrl(v.coverUrl, QUICK_CARD_THUMB_PX),
          imgRadius: 0,
          fillParent: true,
          altText: v.altText
        })
      } else {
        this.EmptyCover()
      }

      Column() {
        Row({ space: 4 }) {
          SymbolGlyph(v.badgeGlyph)
            .fontSize(12)
            .height(12)
            .fontColor(['#FFFFFF'])
          Text(v.badgeText)
            .fontSize(11)
            .lineHeight(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
        }
        .padding({ left: 12, top: 10 })
        .alignItems(VerticalAlign.Center)

        Row() {
          Column({ space: 2 }) {
            Text(v.title)
              .fontSize(13)
              .lineHeight(17)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(v.subtitle)
              .fontSize(11)
              .lineHeight(14)
              .fontColor('rgba(255, 255, 255, 0.72)')
              .maxLines(1)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          if (v.showPlay) {
            Row() {
              SymbolGlyph($r('sys.symbol.play_fill'))
                .fontSize(16)
                .fontColor([Color.White])
            }
            .width(34)
            .height(34)
            .borderRadius(17)
            .backgroundColor('rgba(255, 255, 255, 0.22)')
            .justifyContent(FlexAlign.Center)
            .accessibilityText(v.playA11y)
            .accessibilityLevel('yes')
            .onClick((): void => {
              this.player.playAll(v.playTracks);
            })
          }
        }
        .padding({ left: 12, right: 10, top: 6, bottom: 10 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .backgroundColor('rgba(0, 0, 0, 0.30)')
      .backgroundBlurStyle(BlurStyle.BACKGROUND_ULTRA_THICK)
    }
    .width(QUICK_CARD_WIDTH_VP)
    .height(QUICK_CARD_HEIGHT_VP)
    .borderRadius(QUICK_CARD_RADIUS_VP)
    .clip(true)
    .scale({
      x: this.pressedKey === v.key ? PRESS_SCALE : 1,
      y: this.pressedKey === v.key ? PRESS_SCALE : 1
    })
    .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      this.setPressed(event.type, v.key);
    })
    .onClick((): void => {
      v.onOpen();
    })
  }

  /** 「+」添加卡（尾部顺延）：点开宿主的歌单选择器；满额由 build 内条件隐藏 */
  @Builder
  private AddCard() {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(32)
        .fontColor([this.themePrimary])
      Text('添加')
        .fontSize(13)
        .fontColor(this.themePrimary)
    }
    .width(QUICK_CARD_WIDTH_VP)
    .height(QUICK_CARD_HEIGHT_VP)
    .borderRadius(QUICK_CARD_RADIUS_VP)
    .clip(true)
    .backgroundColor('rgba(128, 128, 128, 0.10)')
    .border({ width: 1.5, style: BorderStyle.Dashed, color: this.themePrimary })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .scale({
      x: this.pressedKey === 'add' ? PRESS_SCALE : 1,
      y: this.pressedKey === 'add' ? PRESS_SCALE : 1
    })
    .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      this.setPressed(event.type, 'add');
    })
    .onClick((): void => {
      this.onAddClick();
    })
    .accessibilityText('添加歌单到首页')
  }

  build() {
    Scroll() {
      Row({ space: QUICK_CARD_GAP_VP }) {
        this.RecentCard()
        ForEach(
          this.cardPlaylists,
          (p: Playlist): void => {
            this.PlaylistCard(p)
          },
          (p: Playlist): string => `qcard_${p.id}`
        )
        // 「+」添加卡尾部顺延：满额（HOME_PLAYLIST_CARDS_MAX）隐藏
        if (this.cardPlaylists.length < HOME_PLAYLIST_CARDS_MAX) {
          this.AddCard()
        }
      }
      .padding({ left: NAV_H_PADDING, right: NAV_H_PADDING })
    }
    .scrollBar(BarState.Off)
    .scrollable(ScrollDirection.Horizontal)
    .width('100%')
    .align(Alignment.Start)
  }
}
