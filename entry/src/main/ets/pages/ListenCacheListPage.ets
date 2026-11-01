/**
 * 缓存歌曲页（播放设置页「查看缓存歌曲」进入）。
 *
 * 枚听听后缓存（listen_cache）的全部条目并展示：封面 / 标题 / UP / 大小 /
 * 最近使用时间，点击即播。数据两侧拼合：
 *   · 文件侧（ListenCacheStore.listListenCacheEntries）：索引键 + 路径 +
 *     大小 + mtime —— 缓存目录只存音频文件，**没有任何元数据**；
 *   · 元数据侧（PlaySessionStore 播放会话日志）：标题 / UP / 封面 / bvid。
 *     会话按原 trackId 记录，缓存索引键是安全文件名 —— 多数 id（bvid、
 *     音乐中心 id）两者一致，含特殊字符的（多 P `bvid#cid`）靠
 *     listenCacheSafeName 归一后再匹配；13 个月保留窗外被清理的会话
 *     匹配不到，回落「未知曲目」（仍可播，只是没有标题/封面）。
 *
 * 点击播放仿下载管理页 toLocalTrack：buildTrack 带 `localFilePath` 直指
 * 缓存文件 —— 播放内核看到它完全跳过音源解析，断网也能放；id 用会话里的
 * 原 trackId（匹配不到用索引键），行点击的播放/暂停判定（isCurrent）
 * 与「这首打头、其余缓存跟在后面」的队列语义和下载页一致。
 *
 * 页面骨架仿 DiaryNewFacesPage（子页标准样板）：HDS 沉浸光感标题栏 +
 * 自绘顶栏渐变模糊层 + 400ms 右滑入转场 + 系统返回拦截。
 */

import {
  CONTENT_END_OFFSET,
  STORE_CURRENT_TRACK,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP
} from '../common/Constants';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { BarNarrowShell } from '../components/BarNarrowShell';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { MaterialTokens } from '../common/style/MaterialTokens';
import { CoverImage } from '../components/CoverImage';
import { Track, buildTrack } from '../model/MusicModels';
import { MusicPlayer } from '../player/MusicPlayer';
import { formatBytes } from '../utils/SettingsShared';
import {
  ListenCacheEntry,
  listListenCacheEntries,
  listenCacheSafeName
} from '../service/ListenCacheStore';
import { PlaySession, querySessions } from '../service/PlaySessionStore';

/** 缓存歌曲行视图模型（文件条目 + 会话元数据拼合结果） */
interface CachedSongRow {
  /** 缓存索引键（安全文件名） */
  key: string;
  /** 音频文件绝对路径（播放用 localFilePath 直指它） */
  path: string;
  /** 文件字节数 */
  size: number;
  /** 最近使用时间（ms） */
  mtime: number;
  /** 原 trackId（会话匹配到时）；匹配不到回落索引键 */
  trackId: string;
  /** 歌名（会话快照；匹配不到显示「未知曲目」） */
  title: string;
  /** UP 主名 */
  artist: string;
  /** 封面 */
  coverUrl: string;
  /** BV 号（在线兜底与身份用；匹配不到为空） */
  bvid: string;
}

@Component
export struct ListenCacheListPage {
  /** 状态栏高度（vp）：HDS 标题栏 avoidLayoutSafeArea 后的占位让位量 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：内容末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 正在播放的曲目：行点击判定是否当前曲目（是则切换播放/暂停） */
  @StorageLink(STORE_CURRENT_TRACK) currentTrack: Track | null = null;
  /** 子页转场横移量（相对页面自身宽度） */
  @State navTransX: string = '0%';
  /** 缓存歌曲行（aboutToAppear 异步加载） */
  @State rows: CachedSongRow[] = [];
  /** 加载中（首帧占位动效，加载完成即翻 false） */
  @State loading: boolean = true;
  /** 汇总行（「共 N 首 · 总计 X」，空缓存 / 加载中为空串不占位） */
  @State summaryText: string = '';
  /** 内容滚动控制器：滚动模糊与 HDS bindToScrollable 共用 */
  private pageScroller: Scroller = new Scroller();
  /** 自绘顶栏渐变模糊层进度更新器（子页标准样板同款命令式驱动） */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.pageScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  aboutToAppear(): void {
    this.loadSongs().catch((e: Error): void => {
      console.error(`load listen cache songs failed: ${e.message}`);
    });
    this.syncTopBlurProgress();
  }

  /**
   * 拼合缓存条目与会话元数据：
   *   1. 文件侧枚举（大小 / mtime / 路径，已按最近使用降序）；
   *   2. 会话侧取 13 个月窗内全部会话（querySessions 升序返回，
   *      Map 覆盖写 = 每曲目留最近一次的快照），键为原 trackId，
   *      特殊字符 id 补一份安全名键（与缓存索引键对齐）；
   *   3. 逐条目按键取元数据，匹配不到回落「未知曲目」+ 索引键当 id
   *      （仍可经 localFilePath 本地播放，只是没有标题/封面/在线兜底）。
   */
  private async loadSongs(): Promise<void> {
    const entries: ListenCacheEntry[] = await listListenCacheEntries();
    const now: number = Date.now();
    const from: Date = new Date(now);
    from.setMonth(from.getMonth() - 13);
    from.setDate(1);
    const sessions: PlaySession[] = await querySessions(from.getTime(), now);
    const metaByTrackId: Map<string, PlaySession> = new Map<string, PlaySession>();
    for (let i = 0; i < sessions.length; i++) {
      const s: PlaySession = sessions[i];
      metaByTrackId.set(s.trackId, s);
      const safe: string = listenCacheSafeName(s.trackId);
      if (safe !== s.trackId) {
        metaByTrackId.set(safe, s);
      }
    }
    const rows: CachedSongRow[] = [];
    let totalBytes: number = 0;
    for (let i = 0; i < entries.length; i++) {
      const e: ListenCacheEntry = entries[i];
      const meta: PlaySession | undefined = metaByTrackId.get(e.key);
      rows.push({
        key: e.key,
        path: e.path,
        size: e.size,
        mtime: e.mtime,
        trackId: meta !== undefined ? meta.trackId : e.key,
        title: meta !== undefined && meta.title.length > 0 ? meta.title : '未知曲目',
        artist: meta !== undefined ? meta.artist : '',
        coverUrl: meta !== undefined ? meta.coverUrl : '',
        bvid: meta !== undefined ? meta.bvid : ''
      });
      totalBytes += e.size;
    }
    this.rows = rows;
    this.summaryText = rows.length > 0 ? `共 ${rows.length} 首 · 总计 ${formatBytes(totalBytes)}` : '';
    this.loading = false;
  }

  /** 缓存日期文案（今年「M月d日」，往年带年号） */
  private cachedDateText(mtimeMs: number): string {
    const d: Date = new Date(mtimeMs);
    const now: Date = new Date();
    const md: string = `${d.getMonth() + 1}月${d.getDate()}日`;
    return d.getFullYear() === now.getFullYear() ? md : `${d.getFullYear()}年${md}`;
  }

  /** 行副文案：UP · 大小 · 缓存日期（UP 缺失自动省略） */
  private rowSubText(row: CachedSongRow): string {
    const parts: string[] = [];
    if (row.artist.length > 0) {
      parts.push(row.artist);
    }
    parts.push(formatBytes(row.size));
    parts.push(this.cachedDateText(row.mtime));
    return parts.join(' · ');
  }

  /**
   * 行 → 可播放曲目（仿下载管理页 toLocalTrack）：
   * localFilePath 直指缓存文件，播放内核完全跳过音源解析（断网可放）；
   * BV 号 / cid 从原 trackId 反推（多 P `bvid#cid` 直取对应分 P），
   * 曲目身份不丢 —— 歌词字幕探测、「进 UP 主页」等链路照常可用。
   */
  private toTrack(row: CachedSongRow): Track {
    const isBv: boolean = row.trackId.indexOf('BV') === 0;
    const hash: number = row.trackId.indexOf('#');
    return buildTrack({
      id: row.trackId,
      bvid: isBv ? (hash > 0 ? row.trackId.substring(0, hash) : row.trackId) : row.bvid,
      cid: isBv && hash > 0 ? row.trackId.substring(hash + 1) : '',
      title: row.title,
      artist: row.artist,
      coverUrl: row.coverUrl,
      localFilePath: row.path
    });
  }

  /** 点击行：当前曲目则切换播放/暂停；否则以「这首打头、其余缓存跟在后面」组队列播放 */
  private playRow(row: CachedSongRow): void {
    const cur: Track | null = this.currentTrack;
    if (cur !== null && cur.id === row.trackId) {
      MusicPlayer.getInstance().togglePlay();
      return;
    }
    const list: Track[] = [this.toTrack(row)];
    for (let i = 0; i < this.rows.length; i++) {
      if (this.rows[i].key !== row.key) {
        list.push(this.toTrack(this.rows[i]));
      }
    }
    MusicPlayer.getInstance().playAll(list);
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut。
   */
  private navTransitionDelegate(op: NavigationOperation,
    isEnter: boolean): Array<NavDestinationTransition> | undefined {
    if (op === NavigationOperation.PUSH && isEnter) {
      this.navTransX = '100%';
      const enter: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '0%';
        }
      };
      const transitions: Array<NavDestinationTransition> = [enter];
      return transitions;
    }
    if (op === NavigationOperation.POP && !isEnter) {
      const exit: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '100%';
        }
      };
      const transitions: Array<NavDestinationTransition> = [exit];
      return transitions;
    }
    return undefined;
  }

  /** 标题栏内容（titleBar 的 stackBuilder 承载）：「缓存歌曲」标题（返回键为 HDS 默认键） */
  @Builder
  pageBar() {
    NavTitleRow({ title: '缓存歌曲' })
  }

  /** 标题行收窄容器（BarNarrowShell 共用件，平板模式宽度适配） */
  @Builder
  pageBarNarrow() {
    BarNarrowShell({ bar: (): void => {
      this.pageBar()
    } })
  }

  /** 单个缓存歌曲行（封面 + 标题 + UP·大小·日期 + 点击播放） */
  @Builder
  songRow(row: CachedSongRow) {
    Row() {
      CoverImage({
        url: row.coverUrl,
        imgWidth: 48,
        imgHeight: 48,
        imgRadius: 8,
        altText: row.title
      })

      Column() {
        Text(row.title)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.rowSubText(row))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .margin({ left: 12 })
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.play_fill'))
        .fontSize(16)
        .fontColor([$r('app.color.text_tertiary')])
        .margin({ left: 8 })
    }
    .width('100%')
    .height(62)
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .borderRadius(8)
    .accessibilityText(`${row.title}，${this.rowSubText(row)}`)
    .accessibilityLevel('yes')
    .onClick((): void => {
      this.playRow(row);
    })
  }

  /** 内容主体：加载中 / 空态 / 清单三态 */
  @Builder
  mainContent() {
    Column() {
      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(32)
            .height(32)
          Text('加载中…')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 96 })
      } else if (this.rows.length === 0) {
        Column({ space: 6 }) {
          Text('暂无缓存歌曲')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
          Text('开启「听后缓存」后，自然听完的歌曲会自动缓存到本地')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 96 })
        .padding({ left: 24, right: 24 })
      } else {
        if (this.summaryText.length > 0) {
          Text(this.summaryText)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 4, bottom: 8 })
        }
        ForEach(this.rows, (row: CachedSongRow, idx: number): void => {
          Column() {
            this.songRow(row)
            // 行间分隔线从封面列之后起画（不贯穿封面，视觉与文字对齐）
            if (idx < this.rows.length - 1) {
              Row() {
                Row()
                  .width(60)
                Divider()
                  .color($r('app.color.bg_divider'))
                  .layoutWeight(1)
              }
              .width('100%')
            }
          }
          .width('100%')
        }, (row: CachedSongRow): string => `${row.key}_${row.size}`)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Scroll(this.pageScroller) {
          Column() {
            // 顶部占位：沉浸口径下内容从标题栏材质下方穿过
            Row()
              .width('100%')
              .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)

            this.mainContent()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          // Scroll 无 contentEndOffset（List 专属），底部避让用内层 padding：
          // 二级页悬浮播放条 + 手势区（与其他子页同口径）
          .padding({ left: 16, right: 16, bottom: CONTENT_END_OFFSET + this.safeBottom })
        }
        .width('100%')
        .height('100%')
        .edgeEffect(EdgeEffect.Spring)
        // 大屏适配：内容列收窄居中
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
        .onDidScroll((xOffset: number, yOffset: number): void => {
          this.syncTopBlurProgress();
        })
        .onScrollStop((): void => {
          this.syncTopBlurProgress();
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      // 顶栏渐变模糊层：盖 Scroll 内容之上（z 序低于 HDS titleBar）
      TopGradientBlurOverlay({
        barHeightVp: this.safeTop + NAV_TITLE_BAR_HEIGHT,
        updater: this.topBlurUpdater
      })
    }
    // HDS 沉浸光感标题栏：材质 / 滚动模糊 / 温控统一由 HdsTitleBarStyle 决策
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        stackBuilder: (): void => {
          this.pageBarNarrow();
        }
      }
    })
    // 滚动模糊依赖 scroller 绑定：把本页滚动容器交给 HDS 联动
    .bindToScrollable([this.pageScroller])
    // 子页转场：横移量由转场代理驱动
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让（官方组件级沉浸口径）
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function ListenCacheListPageBuilder(): void {
  ListenCacheListPage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接 @Builder 引用（编译期校验）。 */
export const ListenCacheListPageWrapped: WrappedBuilder<[]> = wrapBuilder(ListenCacheListPageBuilder);
