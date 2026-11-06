/**
 * 网易云歌单预览页（路由名 NeteasePlaylist，首页「热门歌单」条目下钻）。
 *
 * 结构继承本地歌单详情页（PlaylistDetail，设计方案 design/头部操作区重构-设计方案.md）：
 * 顶栏为 HDS 沉浸光感标题栏，歌单头部区（封面 + 28fp 大标题 + 元信息 +
 * 固定高操作行）经 bottomBuilder **钉顶**，仅曲目列表滚动并从材质下穿过；
 * 标题行为空占位（歌单名只在头部区大标题显示一次）。头部区高度由内层
 * Column onAreaChange 实测回写（headerAreaHeight），实测前用估计值垫底，
 * 列表挂载门控直接判 headerAreaHeight > 0（PlaylistDetail 同款，防固化
 * 错误让位量压条）。
 *
 * 操作行两层（PlaylistDetail 三层去多选）：
 *   · L1 常态行 = 「播放全部」主 CTA（惰性连播，见下）+ 🔍 搜索 + ⋯ 更多；
 *   · L2 搜索行 = SearchBox 独占 + 取消（OPACITY 交叉淡出，固定高防塌缩）。
 *
 * 交互契约：
 *   · 「播放全部」= 惰性连播（NeteasePlayChain 单例服务）：向前扫描匹配
 *     首首可播放歌曲（无 B 站音源 / 匹配异常自动跳过，首中 1~2s 起播），
 *     当前曲开播后才预匹配下一首入队 —— 请求间隔拉大到一首歌的时长量级，
 *     规避 B 站搜索风控；跨页面存续，用户手点条目 / 在别处播歌时按 bvid
 *     自动断链；
 *   · 点一首歌：matchSongForPlayback 实时搜 B 站打分匹配（BiliMusic 音源）
 *     → playNow 起播，先显式断连播链；单飞互斥（matchingIndex）防风控；
 *   · 歌单内搜索（L2）：纯本地过滤 title/artist（200ms 防抖），「命中 N 首」
 *     状态行 + 头部匹配计数；
 *   · 「导入本地歌单」收在 ⋯ 更多菜单：ImportTaskManager.start 后跳导入
 *     向导页（向导 aboutToAppear 识别 MATCHING 态直接进匹配进度页）。
 */

import {
  ExternalPlaylist,
  ExternalSong,
  ImportTaskManager,
  fetchNeteasePlaylist,
  matchSongForPlayback
} from '../service/PlaylistImporter';
import { NeteasePlayChain } from '../service/NeteasePlayChain';
import { NeteasePlaylistRouteParam, NavRouteParamReader } from '../service/NavRouteParams';
import { NavStackHolder } from '../service/NavStackHolder';
import { MusicPlayer } from '../player/MusicPlayer';
import { showAppToast } from '../components/AppToast';
import { formatDurationText } from '../utils/TextUtil';
import { SectionFooter } from '../components/InsetCardGroup';
import { CoverImage } from '../components/CoverImage';
import { ArrayDataSource } from '../utils/ArrayDataSource';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier
} from '../utils/HeaderBarMaterial';
import { HdsNavDestination, BottomBuilderShowType } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { HeaderIconButton } from '../components/HeaderIconButton';
import { SearchBox } from '../components/SearchBox';
import {
  CONTENT_END_OFFSET,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY,
  STORE_THEME_ON
} from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import {
  NAV_TRANSITION_MS,
  BUTTON_RADIUS_VP,
  ACTION_ROW_H,
  SEARCH_FILTER_DEBOUNCE_MS,
  SEARCH_MODE_MS
} from '../common/constants/InteractionConstants';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';

/**
 * 头部区（bottomBuilder 承载）实测前的估计高度：
 * padding top 4 + 封面行 96 + 操作行 margin 12 + 固定高 36 + padding bottom 8。
 * ⚠️ bottomBuilder 高度不自适应（官方约束），由 titleBar 参数显式给定；实测值
 * （headerAreaHeight）回来后覆盖，此值只防首次布局 0 高闪跳。
 */
const NETEASE_HEADER_ESTIMATE_HEIGHT: number = 156;

/**
 * 歌单内搜索的本地过滤谓词（纯函数，PlaylistDetail.filterTracksByKeyword 的
 * ExternalSong 版）：标题 / 歌手包含关键词（小写化匹配），空关键词返回空数组。
 */
function filterSongsByKeyword(songs: ExternalSong[], keyword: string): ExternalSong[] {
  const kw: string = keyword.trim().toLowerCase();
  if (kw.length === 0) {
    return [];
  }
  const out: ExternalSong[] = [];
  for (let i = 0; i < songs.length; i++) {
    const s: ExternalSong = songs[i];
    if (s.title.toLowerCase().indexOf(kw) >= 0 || s.artist.toLowerCase().indexOf(kw) >= 0) {
      out.push(s);
    }
  }
  return out;
}

@Component
export struct NeteasePlaylistPage {
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;

  /** 目标歌单 id（路由参数带入，aboutToAppear 取参一次；空 = 失败态） */
  private playlistId: string = '';
  /** 首帧兜底：条目带来的歌单名 / 封面（详情拉到后被真值覆盖） */
  @State fallbackName: string = '';
  @State fallbackCover: string = '';
  /** 详情加载中（首屏骨架）/ 失败（空态 + 重试） */
  @State loading: boolean = false;
  @State loadFailed: boolean = false;
  /** 歌单详情（拉到后常驻，导入 / 点播 / 连播共用） */
  @State external: ExternalPlaylist | null = null;
  /** 正在匹配播放的行下标（-1 = 空闲；单飞互斥，防 B 站搜索风控） */
  @State matchingIndex: number = -1;

  /**
   * 头部区实测高（vp，bottomBuilder 内层根节点 onAreaChange 回写）。
   * ⚠️ 初值必须为 0：列表挂载门控直接判 headerAreaHeight > 0
   * （PlaylistDetail 同款 —— barTotalHeight() 恒 > 0 不能当门控，实测前
   * 挂载会固化错误让位量，首条目被头部区压住）。
   */
  @State headerAreaHeight: number = 0;

  // ===== 歌单内搜索（L2，纯本地过滤） =====
  /** 搜索态：点 🔍 进入（操作行原位切换为独占输入行），取消 / 返回键退出 */
  @State searchMode: boolean = false;
  /** 搜索框文本：输入即本地过滤（200ms 防抖，见 onKeywordChanged） */
  @State searchKeyword: string = '';
  /** 本地过滤匹配数组；空数组 = 无关键词或 0 命中，靠 searchKeyword 区分 */
  @State filteredSongs: ExternalSong[] = [];
  /**
   * 搜索过滤防抖定时器 id：大歌单千级条目每键同步全量过滤有卡顿风险；
   * aboutToDisappear 清理，防回调打进已销毁实例。
   */
  private filterDebounceTimer: number = -1;

  /** 「播放全部」首曲匹配进行中（CTA 图标位转 LoadingProgress，防连点） */
  @State playAllPending: boolean = false;

  /**
   * ⋯ 菜单开关（bindMenu isShow 态驱动，API 11 重载）：点击 ⋯ 置 true，
   * 菜单关闭后经 onDisappear 复位 false（V1 没有 $$ 对 bindMenu.isShow 的
   * 双向绑定，手动复位是最稳写法；不复位会导致第二次点击 true→true 无变化、
   * 菜单再也弹不出）。
   */
  @State moreMenuOpen: boolean = false;

  /** 歌曲列表数据源（千首级歌单，LazyForEach 只建可视区节点） */
  private songSource: ArrayDataSource<ExternalSong> = new ArrayDataSource<ExternalSong>([]);
  private scroller: Scroller = new Scroller();
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 子页转场横移量：常驻 '0%'，转场代理按 push/pop 临时改写 */
  @State navTransX: string = '0%';

  /** HDS 标题栏整体让位量（vp）= safeTop + 标题行 56 + 头部区实测高 */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT + this.headerAreaHeight;
  }

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.scroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  aboutToAppear(): void {
    this.syncTopBlurProgress();
    const param: NeteasePlaylistRouteParam | null =
      NavRouteParamReader.readNeteasePlaylistParam(NavStackHolder.stack);
    if (param !== null) {
      this.playlistId = param.playlistId;
      this.fallbackName = param.name;
      this.fallbackCover = param.coverUrl;
    } else {
      this.loadFailed = true;
      return;
    }
    this.loadDetail();
  }

  aboutToDisappear(): void {
    // 搜索过滤防抖定时器：销毁前清理，防回调打进已销毁实例。
    if (this.filterDebounceTimer >= 0) {
      clearTimeout(this.filterDebounceTimer);
      this.filterDebounceTimer = -1;
    }
  }

  private async loadDetail(): Promise<void> {
    if (this.loading || this.playlistId.length === 0) {
      return;
    }
    this.loading = true;
    this.loadFailed = false;
    try {
      const ext: ExternalPlaylist = await fetchNeteasePlaylist(this.playlistId);
      this.external = ext;
      // 歌单换新同步刷新过滤结果与列表（搜索中重拉 = 对新曲目重新过滤）
      this.applyLocalFilter();
    } catch (e) {
      const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.error(`netease playlist detail failed: ${detail}`);
      this.loadFailed = true;
    } finally {
      this.loading = false;
    }
  }

  /** 头部歌单名：详情真值优先，路由参数兜底 */
  private headerName(): string {
    const ext: ExternalPlaylist | null = this.external;
    if (ext !== null && ext.name.length > 0) {
      return ext.name;
    }
    return this.fallbackName;
  }

  private headerCover(): string {
    const ext: ExternalPlaylist | null = this.external;
    if (ext !== null && ext.coverUrl.length > 0) {
      return ext.coverUrl;
    }
    return this.fallbackCover;
  }

  private songCount(): number {
    const ext: ExternalPlaylist | null = this.external;
    return ext !== null ? ext.songs.length : 0;
  }

  /** 头部元信息行：曲目数 + 来源（加载中 / 空单只显来源） */
  private metaText(): string {
    return this.songCount() > 0
      ? `共 ${this.songCount()} 首 · 来自网易云音乐`
      : '来自网易云音乐';
  }

  /** 行副题：「歌手 · 04:37」（无则只显其一） */
  private songSubtitle(song: ExternalSong): string {
    const parts: string[] = [];
    if (song.artist.length > 0) {
      parts.push(song.artist);
    }
    if (song.durationSec > 0) {
      parts.push(formatDurationText(song.durationSec));
    }
    return parts.join(' · ');
  }

  // ===== 歌单内搜索（纯本地过滤，无远程搜索） =====

  /** 当前展示源：有关键词 → 匹配数组；否则 → 歌单全量（歌单空给空数组） */
  private activeSource(): ExternalSong[] {
    if (this.searchKeyword.trim().length > 0) {
      return this.filteredSongs;
    }
    const ext: ExternalPlaylist | null = this.external;
    return ext !== null ? ext.songs : [];
  }

  /** 本地过滤重算 + 列表换源（loadDetail 换新 / 防抖回调 / 清词共用出口） */
  private applyLocalFilter(): void {
    const ext: ExternalPlaylist | null = this.external;
    this.filteredSongs = ext !== null ? filterSongsByKeyword(ext.songs, this.searchKeyword) : [];
    this.songSource.reload(this.activeSource());
  }

  /**
   * 输入变化（按键路径）：过滤重算走 200ms 防抖 —— 大歌单千级条目每键同步
   * 全量过滤 + 列表 diff 有卡顿风险。回调读当刻 this.searchKeyword（不捕获
   * 旧词），幂等。
   */
  private onKeywordChanged(): void {
    if (this.filterDebounceTimer >= 0) {
      clearTimeout(this.filterDebounceTimer);
    }
    this.filterDebounceTimer = setTimeout((): void => {
      this.filterDebounceTimer = -1;
      this.applyLocalFilter();
    }, SEARCH_FILTER_DEBOUNCE_MS);
  }

  /**
   * 框内 × 清除：关键词置空 + 列表恢复全量。取消在途防抖后立即执行 ——
   * 防抖回调若不清，清态后 200ms 会拿旧词把过滤结果复活回来。
   */
  private clearSearch(): void {
    if (this.filterDebounceTimer >= 0) {
      clearTimeout(this.filterDebounceTimer);
      this.filterDebounceTimer = -1;
    }
    this.searchKeyword = '';
    this.applyLocalFilter();
  }

  /** 点 🔍 进入搜索态（L2）：操作行原位切换为独占输入行 + 取消按钮 */
  private enterSearchMode(): void {
    this.searchMode = true;
  }

  /** 搜索态统一出口（「取消」/ 返回键）：清空关键词 → 收起搜索态 → 列表恢复全量 */
  private cancelSearch(): void {
    this.clearSearch();
    this.searchMode = false;
  }

  /**
   * 点歌即播（核心链路）：实时 B 站搜索匹配 → playNow（Track 带 bvid →
   * extractAudioFromVideo = BiliMusic 音源）。先显式断惰性连播链（手点 =
   * 单曲意图；链内 bvid 判定也会自动断，这里提前断避免匹配间隙竞态）。
   * 单飞互斥：匹配中再点直接忽略。
   */
  private async playSongAt(index: number): Promise<void> {
    if (this.matchingIndex >= 0 || this.loading || this.loadFailed) {
      return;
    }
    NeteasePlayChain.getInstance().cancel();
    const ext: ExternalPlaylist | null = this.external;
    if (ext === null || index < 0 || index >= ext.songs.length) {
      return;
    }
    const song: ExternalSong = ext.songs[index];
    this.matchingIndex = index;
    try {
      const track = await matchSongForPlayback(song);
      if (track === null) {
        showAppToast('没找到可播放的 B 站音源，可导入歌单后手动匹配', 2600);
      } else {
        MusicPlayer.getInstance().playNow(track);
      }
    } catch (e) {
      const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.error(`netease playlist play match failed: ${detail}`);
      showAppToast('匹配失败，请稍后再试', 2200);
    } finally {
      this.matchingIndex = -1;
    }
  }

  /**
   * 播放全部 = 惰性连播（NeteasePlayChain）：首曲匹配落定（Promise resolve）
   * 后清 CTA loading 态；起播 / 跳过 / 风控熔断的提示由链服务负责。
   */
  private startPlayAll(): void {
    if (this.playAllPending || this.loading || this.loadFailed) {
      return;
    }
    const ext: ExternalPlaylist | null = this.external;
    if (ext === null || ext.songs.length === 0) {
      return;
    }
    this.playAllPending = true;
    NeteasePlayChain.getInstance().start(ext.songs)
      .then((): void => {
        this.playAllPending = false;
      })
      .catch((): void => {
        this.playAllPending = false;
      });
  }

  /** 导入本地歌单：交给单例任务（离开页面继续跑），跳导入向导看进度 */
  private startImport(): void {
    const ext: ExternalPlaylist | null = this.external;
    if (ext === null || ext.songs.length === 0) {
      return;
    }
    const mgr: ImportTaskManager = ImportTaskManager.getInstance();
    if (mgr.isRunning()) {
      showAppToast('已有导入任务进行中，已为你打开导入页', 2200);
    } else {
      mgr.start(ext.songs, ext.name, ext.coverUrl);
    }
    NavStackHolder.push('PlaylistImport', undefined);
  }

  /**
   * ⋯ 更多菜单（bindMenu，PlaylistDetail 同款下拉形态）：
   * 仅「导入本地歌单」—— 排序 / 去重 / 多选 / 下载对只读的网易云预览页
   * 均不适用；重试已有失败态按钮，不重复放。
   */
  private moreMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    if (this.external === null || this.songCount() === 0) {
      return items;
    }
    items.push({
      value: '导入本地歌单',
      action: (): void => {
        this.startImport();
      }
    });
    return items;
  }

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

  /**
   * 头部区（钉在 HDS 标题栏 bottomBuilder 内，不随列表滚动）：
   * 左侧 96vp 圆角封面 + 右侧 28fp 大标题 + 元信息行；封面行下方是固定高
   * 操作行两层（L1 常态 / L2 搜索态，OPACITY 交叉淡出）+ 搜索匹配计数行。
   */
  @Builder
  NeteaseHeader() {
    Column() {
      Row() {
        CoverImage({
          url: this.headerCover(),
          imgWidth: 96,
          imgHeight: 96,
          imgRadius: 12,
          altText: this.headerName()
        })
        Column() {
          Text(this.headerName().length > 0 ? this.headerName() : '网易云歌单')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.metaText())
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 6 })
        }
        .layoutWeight(1)
        .margin({ left: 16 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 操作行两层（PlaylistDetail 三层去多选）：Stack 固定高 36 内两态条件
      // 渲染 + OPACITY 交叉淡出（SEARCH_MODE_MS）—— 退场节点脱离布局由
      // 固定高兜住（faqs-arkui-384，塌缩坑见 PlaylistDetail §6①）。
      Stack() {
        // ── 常态行（L1）：播放全部主 CTA + 🔍 + ⋯ ──
        if (!this.searchMode) {
          Row({ space: 8 }) {
            // 主 CTA：有曲目才显示；layoutWeight(1) 吃掉全部剩余宽度
            if (this.songCount() > 0) {
              Button() {
                Row({ space: 6 }) {
                  if (this.playAllPending) {
                    LoadingProgress()
                      .width(15)
                      .height(15)
                      .color(this.themeOn)
                  } else {
                    SymbolGlyph($r('sys.symbol.play_fill'))
                      .fontSize(15)
                      .fontColor([this.themeOn])
                  }
                  Text('播放全部')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.themeOn)
                }
              }
              .type(ButtonType.Normal)
              .height(ACTION_ROW_H)
              .borderRadius(10)
              .backgroundColor(this.themePrimary)
              .layoutWeight(1)
              .onClick((): void => {
                this.startPlayAll();
              })
            }
            // 🔍 搜索入口（L2 的门）：没有歌曲就没有可搜内容，不显示
            if (this.songCount() > 0) {
              HeaderIconButton({
                icon: $r('sys.symbol.magnifyingglass'),
                accessibilityLabel: '搜索歌单内歌曲',
                onClickAction: (): void => {
                  this.enterSearchMode();
                }
              })
            }
            // ⋯ 更多入口：位置恒定在行最右（PlaylistDetail §2 规则 3 同款）。
            // ⚠️ 必须 isShow 态驱动重载（API 11，UpSpacePage 真机实测结论）：
            // 无 isShow 的重载靠「点击锚点」触发菜单，但本锚点是自定义组件、
            // 内部 Button 根节点自带 onClick 手势，子节点赢得手势仲裁后菜单
            // 永远收不到点击（真机实测：点了没反应）；态驱动下点击经
            // onClickAction 显式置 moreMenuOpen，菜单锚定本组件弹出。
            HeaderIconButton({
              icon: $r('sys.symbol.more'),
              accessibilityLabel: '更多歌单操作',
              onClickAction: (): void => {
                // 菜单可能为空（详情未拉到 / 空单）：空数组不弹空气泡
                if (this.moreMenuItems().length > 0) {
                  this.moreMenuOpen = true;
                }
              }
            })
            .bindMenu(this.moreMenuOpen, this.moreMenuItems(), {
              // placement 显式 BottomRight（全局统一更多菜单方向）：右缘锚点默认
              // BottomLeft 向右展开必超屏 → 走「自动调整」路径弹到左侧
              //（PlaylistsTabBar 顶栏 ⋮ 同款结论）
              placement: Placement.BottomRight,
              onDisappear: (): void => {
                this.moreMenuOpen = false;
              }
            })
          }
          .width('100%')
          .transition(TransitionEffect.OPACITY
            .animation({ duration: SEARCH_MODE_MS, curve: Curve.EaseInOut }))
        }
        // ── 搜索行（L2）：SearchBox 独占 + 取消 —— 本页纯本地过滤，
        // 键盘搜索键无远程动作（onSubmit 空实现仅收键盘），输入即过滤
        // （200ms 防抖），框内 × 清除，取消走 cancelSearch。
        if (this.searchMode) {
          Row({ space: 8 }) {
            SearchBox({
              placeholder: '搜索歌单内歌曲',
              keyword: this.searchKeyword,
              clearVisible: this.searchKeyword.trim().length > 0,
              onKeywordChange: (v: string): void => {
                this.searchKeyword = v;
                this.onKeywordChanged();
              },
              onSubmit: (): void => {
              },
              onClear: (): void => {
                this.clearSearch();
              }
            })
              .layoutWeight(1)
            Button('取消', { type: ButtonType.Normal })
              .fontSize(13)
              .height(ACTION_ROW_H)
              .padding({ left: 12, right: 4 })
              .backgroundColor(Color.Transparent)
              .fontColor(this.themePrimary)
              .onClick((): void => {
                this.cancelSearch();
              })
          }
          .width('100%')
          .transition(TransitionEffect.OPACITY
            .animation({ duration: SEARCH_MODE_MS, curve: Curve.EaseInOut }))
        }
      }
      .width('100%')
      .height(ACTION_ROW_H)
      .margin({ top: 12 })

      // 搜索态匹配计数行：让用户知道是「被筛过了」而不是「歌单变短了」
      if (this.searchMode && this.searchKeyword.trim().length > 0) {
        Text(`匹配 ${this.filteredSongs.length} 首`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: 4, bottom: 8 })
  }

  /** 标题行（stackBuilder 承载）：空占位 —— 歌单名只在头部区大标题显示一次 */
  @Builder
  neteaseBar() {
    NavTitleRow({ title: '' })
  }

  /**
   * 标题行下方自定义区（bottomBuilder 承载）：头部区实测载体 ——
   * onAreaChange 挂内层 Column，回写 headerAreaHeight（ PlaylistDetail
   * playlistHeaderArea 同款）。
   */
  @Builder
  neteaseHeaderArea() {
    Column() {
      Column() {
        this.NeteaseHeader()
      }
      .width('100%')
      .onAreaChange((_old: Area, cur: Area): void => {
        const h: number = cur.height as number;
        if (h > 0) {
          this.headerAreaHeight = h;
        }
      })
    }
    .width('100%')
  }

  /**
   * 标题行收窄容器（平板模式宽度适配，PlaylistDetail playlistBarNarrow 同款）：
   * stackBuilder 横跨目的地整列全宽，外层 Row 居中 + 内层 Column
   * constraintSize 与内容列同口径，标题行与曲目列同宽对齐；两侧空白区
   * hitTestBehavior(Transparent) 穿透点击。
   */
  @Builder
  neteaseBarNarrow() {
    Row() {
      Column() {
        this.neteaseBar()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 头部区收窄容器（同 neteaseBarNarrow 口径，bottomBuilder 横跨全宽收窄对齐） */
  @Builder
  neteaseHeaderAreaNarrow() {
    Row() {
      Column() {
        this.neteaseHeaderArea()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 失败态：空态文案 + 重试按钮 */
  @Builder
  failedBody() {
    Column() {
      Text('歌单拉取失败')
        .fontSize(15)
        .fontColor($r('app.color.text_secondary'))
      Text('网络不佳或该歌单已失效，可稍后重试')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ top: 6 })
      Button('重试', { type: ButtonType.Normal })
        .fontSize(14)
        .height(40)
        .padding({ left: 24, right: 24 })
        .borderRadius(BUTTON_RADIUS_VP)
        .backgroundColor(this.themePrimary)
        .fontColor(this.themeOn)
        .attributeModifier(this.buttonMaterial)
        .margin({ top: 16 })
        .onClick((): void => {
          this.loadDetail();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 96, left: 16, right: 16, bottom: 32 })
  }

  /** 首屏骨架行（加载中占位，6 行贴合首屏） */
  @Builder
  skeletonRows() {
    ForEach([0, 1, 2, 3, 4, 5], (i: number): void => {
      ListItem() {
        Row({ space: 12 }) {
          Text(`${i + 1}`)
            .fontSize(14)
            .fontColor(Color.Transparent)
            .width(24)
          Column() {
            Row()
              .width('70%')
              .height(14)
              .borderRadius(4)
              .backgroundColor($r('app.color.bg_card'))
            Row()
              .width('40%')
              .height(10)
              .borderRadius(4)
              .backgroundColor($r('app.color.bg_card'))
              .margin({ top: 6 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ top: 14, bottom: 14 })
      }
    }, (i: number): string => `sk_${i}`)
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Column() {
          // 列表挂载门控（PlaylistDetail 同款）：等头部区首次实测完成再挂载，
          // 防实测前固化错误让位量（首条目被头部区压住）。
          if (this.headerAreaHeight > 0) {
            List({ scroller: this.scroller }) {
              // 顶部空白占位条目：高度 = 标题栏总让位量（safeTop + 56 +
              // 头部区实测高），首个真实条目恰从钉顶头部区底缘起排，
              // 滚动时占位与条目一起从沉浸材质下穿过。
              ListItem() {
                Row()
                  .width('100%')
                  .height(this.barTotalHeight())
              }
              if (this.loadFailed) {
                ListItem() {
                  this.failedBody()
                }
              } else {
                if (this.loading) {
                  this.skeletonRows()
                } else if (this.songCount() === 0) {
                  ListItem() {
                    Column() {
                      Text('歌单里没有歌曲')
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                    }
                    .width('100%')
                    .alignItems(HorizontalAlign.Center)
                    .padding({ top: 48, bottom: 48 })
                  }
                } else {
                  LazyForEach(
                    this.songSource,
                    (song: ExternalSong, index: number): void => {
                      ListItem() {
                        Row({ space: 12 }) {
                          Text(`${index + 1}`)
                            .fontSize(13)
                            .fontColor($r('app.color.text_tertiary'))
                            .width(24)
                            .textAlign(TextAlign.Center)
                          Column() {
                            Text(song.title)
                              .fontSize(15)
                              .fontColor($r('app.color.text_primary'))
                              .maxLines(1)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                              .width('100%')
                            if (this.songSubtitle(song).length > 0) {
                              Text(this.songSubtitle(song))
                                .fontSize(11)
                                .fontColor($r('app.color.text_tertiary'))
                                .maxLines(1)
                                .textOverflow({ overflow: TextOverflow.Ellipsis })
                                .width('100%')
                                .margin({ top: 3 })
                            }
                          }
                          .layoutWeight(1)
                          .alignItems(HorizontalAlign.Start)

                          // 行尾不放常驻播放键（整行点按即播）：仅匹配中的行
                          // 在行尾给 LoadingProgress 反馈，其余行尾留白。
                          if (this.matchingIndex === index) {
                            LoadingProgress()
                              .width(18)
                              .height(18)
                              .color(this.themePrimary)
                          }
                        }
                        .width('100%')
                        .padding({ top: 12, bottom: 12 })
                        .alignItems(VerticalAlign.Center)
                        .onClick((): void => {
                          this.playSongAt(index);
                        })
                      }
                    },
                    (song: ExternalSong, index: number): string => `${index}_${song.title}`
                  )
                  // 搜索状态行（关键词激活时常驻）：命中 N 首给计数，
                  // 0 命中给人话提示（PlaylistDetail 同口径）。
                  if (this.searchKeyword.trim().length > 0) {
                    ListItem() {
                      Text(this.filteredSongs.length > 0
                        ? `命中 ${this.filteredSongs.length} 首歌曲`
                        : '没有匹配的歌曲')
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                    }
                  }
                  ListItem() {
                    SectionFooter({
                      noteText: '点歌与播放全部会实时匹配 B 站音源播放；⋯ 菜单可导入本地歌单收藏连播'
                    })
                  }
                }
              }
            }
            .layoutWeight(1)
            .width('100%')
            .edgeEffect(EdgeEffect.Spring)
            .cachedCount(8)
            .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
            .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
              this.syncTopBlurProgress();
            })
            .onScrollStop((): void => {
              this.syncTopBlurProgress();
            })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })

        TopGradientBlurOverlay({
          barHeightVp: this.barTotalHeight(),
          updater: this.topBlurUpdater
        })
      }
    }
    // HDS 沉浸光感标题栏（PlaylistDetail 同构）：标题行空占位 +
    // bottomBuilder 钉顶头部区（实测高 / 估计值垫底）。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        stackBuilder: (): void => {
          this.neteaseBarNarrow();
        },
        bottomBuilder: {
          builder: (): void => {
            this.neteaseHeaderAreaNarrow();
          },
          height: this.headerAreaHeight > 0 ? this.headerAreaHeight : NETEASE_HEADER_ESTIMATE_HEIGHT,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        }
      }
    })
    .bindToScrollable([this.scroller])
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 系统返回拦截：搜索态先退搜索态（清词收起），再走子页返回链
    .onBackPressed((): boolean => {
      if (this.searchMode) {
        this.cancelSearch();
        return true;
      }
      return handleSubPageBackPress();
    })
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

@Builder
export function NeteasePlaylistPageBuilder(): void {
  NeteasePlaylistPage()
}

export const NeteasePlaylistPageWrapped: WrappedBuilder<[]> = wrapBuilder(NeteasePlaylistPageBuilder);
