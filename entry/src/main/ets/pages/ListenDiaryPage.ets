/**
 * 拾音页（一级页签「拾音」，占 Index 的 2 号页签位；旧名「听歌日记」）。
 *
 * 本机听歌行为的私人数据报告，按 日/周/月/年 翻阅：
 * 上面是情绪（Hero 封面 + 一句话）→ 中间是事实（四个数字 + 节奏柱状图）
 * → 下面是名字（循环榜 / 常听 UP 主 / 新面孔）。
 *
 * 数据链：MusicPlayer 四结算点 → PlaySessionStore（月分片 jsonl）→
 * querySessions 全量缓存页内 → ListenDiaryStats.computeDiaryReport 派生一屏。
 * ⚠️ 冷启动纪律：全量会话查询门控到「拾音页签首次激活」（loadStatsOnce），
 * 不裸跑在启动路径上。
 *
 * 设计依据 design/听歌日记-页面设计方案.md：
 *   · 字号只用 24/20/18/16/13/11；品牌色只落 4 处（分段选中 / 柱状图 /
 *     榜单第 1 名序号 / 均值虚线系图形元素），13px 小字用 themeDeep；
 *   · 间距 4 的倍数、圆角 8/12/pill、区块间距 24（图表卡上距 16 按规格特例）；
 *   · Phase 1：隐藏「生成回顾卡片」按钮与各处「全部 ›」入口（不放点了
 *     没反应的入口；循环榜「全部 ›」收听流水入口除外——已有真实目标页）；
 *     新面孔卡可点进清单页（快照传参，不重算统计）；
 *   · 空态三分：当前周期空 = 完整空态 + 「去首页听点音乐 ›」；
 *     往期空 = 内容降透明度 60% + 居中提示（仍可翻页）；
 *     会话日志未覆盖 = KPI 显示 —（「没统计到」≠「没听」）。
 *
 * 页面骨架（一级页签）：Scroll 挂 TabScrollerHolder.diary（Index 根栏
 * bindToScrollable 联动滚动模糊）+ 自绘顶栏渐变模糊层；顶部占位
 * safeTop + NAV_TITLE_BAR_HEIGHT 让内容从根栏材质下方穿过。
 * 内容区用 Scroll（区块异构无需复用回收；底部避让用内层 padding ——
 * Scroll 没有 List 的 contentEndOffset）。
 */

import {
  CONTENT_END_OFFSET,
  STORE_ACTIVE_TAB,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_SESSION_REV,
  STORE_TAB_SWITCH_REQUEST,
  STORE_TAB_SWITCH_TARGET,
  STORE_THEME_DEEP,
  STORE_THEME_ON,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE
} from '../common/Constants';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';
import { CoverImage } from '../components/CoverImage';
import { NavStackHolder } from '../service/NavStackHolder';
import { UpSpaceRouteParam, DiaryNewFacesRouteParam, SearchRouteParam } from '../service/NavRouteParams';
import { querySessions, PlaySession } from '../service/PlaySessionStore';
import { getTagsForBatch } from '../service/VideoTagStore';
import {
  DiaryPeriod,
  DiaryReport,
  DiaryKpiCell,
  DiaryBucket,
  DiaryDaySegment,
  DiaryTopTrack,
  DiaryTopUp,
  DiaryTagEntry,
  computeDiaryReport,
  computeDiaryTagCloud,
  diaryShiftAnchor,
  formatDiaryDuration
} from '../service/ListenDiaryStats';
import { buildTrack, Track } from '../model/MusicModels';
import { MusicPlayer } from '../player/MusicPlayer';
import { LibraryStore } from '../service/LibraryStore';
import { showAppToast } from '../components/AppToast';
import { copyText } from '../utils/ClipboardUtil';
import { curves } from '@kit.ArkUI';

/** 分段四周期（固定顺序 日/周/月/年） */
const DIARY_PERIODS: DiaryPeriod[] = [
  DiaryPeriod.Day, DiaryPeriod.Week, DiaryPeriod.Month, DiaryPeriod.Year
];

/** 拾音页签下标（与 Index 的 TAB_DIARY 同值；模块私有常量跨文件不可引用） */
const DIARY_TAB_INDEX: number = 2;

/** 均值虚线的短横条槽数（每槽 2.5% 宽 × 40 = 全宽） */
const DASH_SEGMENTS: number[] = [];
for (let i = 0; i < 40; i++) {
  DASH_SEGMENTS.push(i);
}

/** 柱状图绘图区高度（vp，设计规格 §4.6） */
const CHART_PLOT_HEIGHT: number = 92;

/** 标签云展示条数上限（权重降序取前 N） */
const TAG_CLOUD_MAX: number = 10;

/** 标签批量拉取并发数（首访一个周期最多 20 请求，4 路并发限流） */
const TAG_FETCH_CONCURRENCY: number = 4;

/** Hero 卡自动轮播间隔（ms）：4s 与系统图库/应用市场横幅同节奏 */
const HERO_AUTO_PLAY_MS: number = 4000;

/** 实时刷新去抖（ms）：快速连切多首歌只触发一次重查（尾沿去抖） */
const SESSION_RELOAD_DEBOUNCE_MS: number = 800;

/** 分段滑块槽宽（vp）= (268 - 2×2) / 4，与触控行 padding 2 后的四等分格同宽 */
const PERIOD_SEG_SLOT: number = 66;
/** 分段滑块起始 x（vp）：背板内边距 2 的内缩视觉 */
const PERIOD_SEG_THUMB_X0: number = 2;
/** 分段滑块 y（vp）= (44 - 28) / 2：与触控行文字同一垂直中线（背板 y=6 高 32，滑块内缩 2） */
const PERIOD_SEG_THUMB_Y: number = 8;

/** KPI 单格传参壳：@Builder 仅「单参 + 对象字面量」按引用传递才随状态刷新 */
interface KpiCellArg {
  cell: DiaryKpiCell;
}

/** 周期分段的显示名 */
function diaryPeriodLabel(p: DiaryPeriod): string {
  if (p === DiaryPeriod.Day) {
    return '日';
  }
  if (p === DiaryPeriod.Week) {
    return '周';
  }
  if (p === DiaryPeriod.Month) {
    return '月';
  }
  return '年';
}

/**
 * 从分 P 曲目 id（`bvid#cid`，expandVideoParts 组装）解析出 cid；普通曲目
 *（纯 bvid / 音乐中心 id，无 #）返回空串。
 * 不还原 cid 的话，resolveTrackSource 按「cid 为空」落到 detail.cid（P1 的
 * cid）取流 —— 点循环榜里的合集第 N 首，播出来的却是 P1（另一首歌）。
 */
function loopTrackCid(trackId: string): string {
  const hashAt: number = trackId.lastIndexOf('#');
  return hashAt >= 0 ? trackId.slice(hashAt + 1) : '';
}

@Component
export struct ListenDiaryPage {
  /** 状态栏高度（vp）：HDS 标题栏 avoidLayoutSafeArea 后的占位让位量 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：内容末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 主题色运行时值（hex 字符串，切主题即刷新；本页品牌色只落 4 处） */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  /** 当前统计周期（默认周视图） */
  @State period: DiaryPeriod = DiaryPeriod.Week;
  /** 周期锚点（任一属于目标周期的 ms 时间戳，平移翻页用） */
  @State anchorMs: number = Date.now();
  /** 全量会话读回标记（false = 首帧只渲染标题栏骨架，不先闪一版空态） */
  @State reportReady: boolean = false;
  /**
   * 当前派生报告（始终有初值，内容渲染由 reportReady 门控）。
   * 注意：@Builder 按值传参不随状态刷新（ArkUI 规则），各区块 Builder
   * 一律无参化、经 this.report 读取，保证切周期 / 翻页即时更新。
   */
  @State report: DiaryReport = computeDiaryReport(DiaryPeriod.Week, Date.now(), []);
  /** Hero 轮播当前页（切周期 / 翻页时复位 0） */
  @State heroIndex: number = 0;
  /** 当前周期标签云（权重降序；空数组 = 无标签 / 拉取未完成，卡片整块隐藏） */
  @State tagCloud: DiaryTagEntry[] = [];
  /** 循环榜长按菜单当前行曲目 id（受控 bindMenu 的 isShow；空串 = 无菜单） */
  @State loopMenuTrackId: string = '';
  /** 长按松手误触守卫：LongPressGesture 触发后松手内置 click 仍会 fire，首击吞掉 */
  private suppressNextClick: boolean = false;
  /** 内容滚动控制器：滚动模糊与 HDS bindToScrollable 共用（直挂 TabScrollerHolder.diary 唯一真源，身份恒定） */
  private diaryScroller: Scroller = TabScrollerHolder.diary;
  /** 自绘顶栏渐变模糊层进度更新器（命令式驱动） */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();
  /** 全量会话缓存（进入页面时一次取全，周期切换不重读盘） */
  private historySessions: PlaySession[] = [];
  /** 异步加载序号（防并发：旧查询结果晚到不覆盖新状态） */
  private loadSeq: number = 0;
  /** 标签云异步刷新序号（防并发：旧周期标签晚到不覆盖新周期，同 loadSeq 口径） */
  private tagCloudSeq: number = 0;
  /** 全量会话查询已执行标记（冷启动门控，只跑一次） */
  private statsLoaded: boolean = false;
  /**
   * 当前活动页签（Index 受控写穿 AppStorage）：冷启动门控的触发信号 ——
   * 拾音页签首次激活（activeTab 首次变为 2）才执行全量会话查询，
   * 避免查询裸跑在启动路径上拖冷启动。
   */
  @StorageLink(STORE_ACTIVE_TAB) @Watch('onTabActivated') activeTab: number = 0;
  /**
   * 播放会话 rev（PlaySessionStore.appendSession 落库递增）：
   * 快照过期信号 —— 与 loadedSessionRev 不等 = historySessions 已落后于
   * 最新会话，该重查刷新。@Watch 在「切回页签」与「停留页签期间继续播歌」
   * 两种场景都覆盖（TabContent 常驻，任何页签下都会触发）。
   */
  @StorageProp(STORE_SESSION_REV) @Watch('onSessionRevChanged') sessionRev: number = 0;
  /** 已加载快照对应的 rev（-1 = 尚未加载；≠ sessionRev = 快照过期） */
  private loadedSessionRev: number = -1;
  /** 实时刷新去抖定时器 id（-1 = 无待执行刷新） */
  private reloadDebounceId: number = -1;

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.diaryScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  aboutToAppear(): void {
    this.syncTopBlurProgress();
    this.loadStatsOnce();
  }

  aboutToDisappear(): void {
    // 防御性收尾：清实时刷新去抖定时器（TabContent 常驻实际不触发，
    // 组件销毁重建的极端场景下避免悬空回调）。
    if (this.reloadDebounceId >= 0) {
      clearTimeout(this.reloadDebounceId);
      this.reloadDebounceId = -1;
    }
  }

  /**
   * 冷启动门控：**第一次**全量会话查询只在拾音页签**首次激活**时执行一次。
   * TabContent 常驻（Index 静态 import），aboutToAppear 落在启动路径上——
   * 裸跑 querySessions 会读盘 + 全量解析，拖冷启动。
   * 两条入口全覆盖：aboutToAppear 直调覆盖「挂载时已是拾音页签」
   *（@StorageLink 初值同步不触发 @Watch，如恢复上次页签的冷启动）；
   * onTabActivated 覆盖「先挂载、后切页签」（正常点击切换路径）。
   * 后续激活不再重查全量（statsLoaded 已置位），只经 reloadIfStale 补拉
   * 上次加载后落库的新会话（monthCache 全内存命中，毫秒级）。
   */
  private loadStatsOnce(): void {
    if (this.activeTab !== DIARY_TAB_INDEX) {
      return;
    }
    if (this.statsLoaded) {
      this.reloadIfStale();
      return;
    }
    this.statsLoaded = true;
    this.reload();
  }

  /**
   * 快照过期才重查：sessionRev ≠ loadedSessionRev = historySessions 落后于
   * 最新落库会话。幂等（查完即等），重复调用无额外开销。
   */
  private reloadIfStale(): void {
    if (this.sessionRev !== this.loadedSessionRev) {
      this.reload();
    }
  }

  /**
   * 会话 rev 变化回调（@Watch）：新会话落库信号。
   * 非拾音页签激活态直接跳过（别的页签听歌不空转聚合，切回时由
   * onTabActivated → reloadIfStale 补刷）；激活态尾沿去抖一次重查，
   * 去抖窗口内切走页签则放弃本次（同样留给激活回调）。
   */
  private onSessionRevChanged(): void {
    if (this.activeTab !== DIARY_TAB_INDEX || this.reloadDebounceId >= 0) {
      return;
    }
    this.reloadDebounceId = setTimeout((): void => {
      this.reloadDebounceId = -1;
      if (this.activeTab === DIARY_TAB_INDEX) {
        this.reloadIfStale();
      }
    }, SESSION_RELOAD_DEBOUNCE_MS);
  }

  /** 页签激活回调：拾音页签冷启动门控的「后切换」入口 + 过期快照补刷（见 loadStatsOnce） */
  private onTabActivated(): void {
    this.loadStatsOnce();
  }

  /** 全量会话读回 → 首帧报告（不加动画：避免加载闪一版空态再跳变） */
  private async reload(): Promise<void> {
    const seq: number = ++this.loadSeq;
    const sessions: PlaySession[] = await querySessions(0, Date.now());
    if (seq !== this.loadSeq) {
      return;
    }
    this.historySessions = sessions;
    // 快照就位后记录对应 rev；查询期间若有新会话落库，rev 已前移，
    // loadedSessionRev 仍落后 → 下一次触发（去抖回调 / 切回页签）自然补拉。
    this.loadedSessionRev = this.sessionRev;
    this.rebuild(false);
  }

  /** 由缓存派生报告；animated = 周期切换时 250ms EaseInOut 数字/柱高过渡 */
  private rebuild(animated: boolean): void {
    const next: DiaryReport = computeDiaryReport(this.period, this.anchorMs, this.historySessions);
    this.heroIndex = 0;
    if (animated) {
      this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, (): void => {
        this.report = next;
      });
    } else {
      this.report = next;
    }
    this.reportReady = true;
    // 新周期标签未就绪：先清空标签云，避免「标题已变新周期、内容还挂旧周期标签」
    // 的错配（refreshTagCloud 是异步的，命中缓存毫秒级、走网络可达秒级）。
    // 清空后 tagCloud.length === 0，标签卡整块隐藏（无空占位、不打扰）。
    this.tagCloud = [];
    // 标签云随报告重算（fire-and-forget：命中缓存毫秒级，未命中后台拉取）
    this.refreshTagCloud();
  }

  /**
   * 周期标签云刷新：对报告的 tagTracks（有效收听 Top20）批量取标签 →
   * 按收听时长聚权重取 Top N。seq 防并发；拉取失败 / 无 BV 号 → 空数组，
   * 卡片整块隐藏（无空占位、不打扰）。
   */
  private async refreshTagCloud(): Promise<void> {
    const seq: number = ++this.tagCloudSeq;
    const tagTracks: DiaryTopTrack[] = this.report.tagTracks;
    if (tagTracks.length === 0) {
      this.tagCloud = [];
      return;
    }
    // 去重 BV 号（同一视频多条会话只拉一次标签）
    const seen: Set<string> = new Set<string>();
    const bvids: string[] = [];
    for (let i = 0; i < tagTracks.length; i++) {
      const bvid: string = tagTracks[i].bvid;
      if (bvid.length > 0 && !seen.has(bvid)) {
        seen.add(bvid);
        bvids.push(bvid);
      }
    }
    const tagsByBvid: Map<string, string[]> =
      await getTagsForBatch(bvids, TAG_FETCH_CONCURRENCY);
    if (seq !== this.tagCloudSeq) {
      return;
    }
    this.tagCloud = computeDiaryTagCloud(tagTracks, tagsByBvid, TAG_CLOUD_MAX);
  }

  /** 切周期：保留滚动位置（设计 §4.1）；滑块弹簧滑动带一次小过冲回弹，数字与柱高做 250ms 过渡 */
  private switchPeriod(p: DiaryPeriod): void {
    if (this.period === p) {
      return;
    }
    // 轻微回弹：ζ = 26 / (2√228) ≈ 0.86，一次约 5% 小过冲即归位；
    // velocity 0 = 点按触发（非跟手滑动），连点时新弹簧从当前位置重定向
    this.getUIContext().animateTo(
      { curve: curves.interpolatingSpring(0, 1, 228, 26) },
      (): void => {
        this.period = p;
      }
    );
    this.rebuild(true);
  }

  /** 周期翻页：-1 上一期 / +1 下一期（当前周期禁右箭头在 UI 层拦） */
  private shiftRange(delta: number): void {
    this.anchorMs = diaryShiftAnchor(this.period, this.anchorMs, delta);
    this.rebuild(true);
  }

  /** 循环榜点单条：与全站列表一致走 playOrToggle（同曲 = 播放/暂停切换） */
  private playTopTrack(t: DiaryTopTrack): void {
    MusicPlayer.getInstance().playOrToggle(this.buildLoopTrack(t));
  }

  /** 循环榜行 → 播放器曲目模型（点单条 / 长按菜单共用）：分 P 的 cid 从 id 还原（见 loopTrackCid） */
  private buildLoopTrack(t: DiaryTopTrack): Track {
    return buildTrack({
      id: t.trackId,
      title: t.title,
      artist: t.artist,
      coverUrl: t.coverUrl,
      bvid: t.bvid,
      cid: loopTrackCid(t.trackId),
      // 会话聚合出的曲目时长必须带上：为 0 时 rememberedStartSec 的续播保护
      // （posSec <= duration - RESUME_TAIL_SEC）因 duration<=0 被跳过，
      // 「上次听到曲末」的行（lastPosSec ≈ 时长）会从曲末起播 —— 起播即
      // completed 自动切歌，落到队列里同 bvid 的 P1 上（点分 P 播成第一首的根因）
      duration: t.duration
    });
  }

  /** 循环榜曲目是否已收藏（菜单「收藏 / 取消收藏」标签动态定） */
  private isLoopTrackFav(t: DiaryTopTrack): boolean {
    const favs: Track[] = LibraryStore.getFavoriteTracks();
    for (let i = 0; i < favs.length; i++) {
      if (favs[i].id === t.trackId) {
        return true;
      }
    }
    return false;
  }

  /** 循环榜长按菜单（五项，无破坏性操作；播放 / 队列 / 收藏 / 搜索 / 复制） */
  private loopMenuItems(t: DiaryTopTrack): MenuElement[] {
    const favLabel: string = this.isLoopTrackFav(t) ? '取消收藏' : '收藏';
    return [
      {
        value: '播放',
        action: (): void => {
          this.playTopTrack(t);
        }
      },
      {
        value: '加入队列',
        action: (): void => {
          MusicPlayer.getInstance().addToQueue(this.buildLoopTrack(t));
          showAppToast('已加入播放队列', 1500);
        }
      },
      {
        value: favLabel,
        action: (): void => {
          LibraryStore.toggleFavoriteTrack(this.buildLoopTrack(t));
          showAppToast(favLabel === '收藏' ? '已收藏' : '已取消收藏', 1500);
        }
      },
      {
        value: '去搜索这首歌',
        action: (): void => {
          NavStackHolder.push('Search', new SearchRouteParam(t.title));
        }
      },
      {
        value: '复制歌名',
        action: (): void => {
          copyText(t.title).then((ok: boolean): void => {
            showAppToast(ok ? '已复制歌名' : '复制失败，请重试', 1500);
          });
        }
      }
    ];
  }

  /** 常听 UP 点击 → UP 主主页（upMid 空 = 音乐中心/已下载来源，不可跳） */
  private openUpSpace(u: DiaryTopUp): void {
    if (u.upMid.length === 0) {
      return;
    }
    NavStackHolder.push('UpSpace', new UpSpaceRouteParam(u.upMid, u.name, u.avatarUrl));
  }

  /** 空态「去首页听点音乐 ›」：清子页栈回首页 Tab，并切到首页页签 */
  private goHome(): void {
    NavStackHolder.clearAll();
    AppStorage.setOrCreate(STORE_TAB_SWITCH_TARGET, 0);
    AppStorage.setOrCreate(STORE_TAB_SWITCH_REQUEST,
      (AppStorage.get<number>(STORE_TAB_SWITCH_REQUEST) ?? 0) + 1);
  }

  /** 榜单序号（01/02/03，宽 24 定列） */
  private rankLabel(idx: number): string {
    return `0${idx + 1}`;
  }

  /** 循环榜副行：日视图「听了 N 次」，其余「听了 N 天」（差异矩阵 §6） */
  private loopSubText(t: DiaryTopTrack): string {
    if (this.period === DiaryPeriod.Day) {
      return `${t.artist} · 听了 ${t.plays} 次`;
    }
    return `${t.artist} · 听了 ${t.dayCount} 天`;
  }

  /** 常听 UP 时长文案（3.2 小时 / 45 分钟） */
  private upDurationText(u: DiaryTopUp): string {
    const cell: DiaryKpiCell = formatDiaryDuration(u.totalMs);
    return `${cell.value} ${cell.unit}`;
  }

  /** 时段行右侧文案：`1.2 小时 · 46%`（时长复用 formatDiaryDuration 口径） */
  private segDurationText(seg: DiaryDaySegment): string {
    const cell: DiaryKpiCell = formatDiaryDuration(seg.ms);
    return `${cell.value} ${cell.unit} · ${seg.pct}%`;
  }

  /** 是否峰值时段行（横条实底 100%，其余 24% 不透明度——与节奏柱同风格） */
  private isPeakSeg(seg: DiaryDaySegment): boolean {
    let peakMs: number = 0;
    for (let i = 0; i < this.report.daySegments.length; i++) {
      if (this.report.daySegments[i].ms > peakMs) {
        peakMs = this.report.daySegments[i].ms;
      }
    }
    return peakMs > 0 && seg.ms >= peakMs;
  }

  /** 柱高百分比：峰值 100%，其余按比例，0 也有 4% 的点（设计 §4.6） */
  private barPct(ms: number, maxMs: number): number {
    if (maxMs <= 0) {
      return 4;
    }
    return Math.max(4, Math.round(ms / maxMs * 100));
  }

  /** 是否峰值柱（实底 100%，其余 24% 不透明度） */
  private isPeakBar(ms: number, maxMs: number): boolean {
    return maxMs > 0 && ms >= maxMs;
  }

  /** 均值虚线距柱底的高度（vp）：均值 / 峰值 × 绘图区高，封顶不出图区 */
  private avgLineVp(): number {
    if (this.report.maxBucketMs <= 0) {
      return 0;
    }
    return Math.min(CHART_PLOT_HEIGHT,
      this.report.avgMsPerBucket / this.report.maxBucketMs * CHART_PLOT_HEIGHT);
  }

  /** 柱状图容器读屏汇总（不逐柱朗读，设计 §9） */
  private chartAccessibilityText(): string {
    let text: string = `${this.report.sectionPrefix}听歌节奏，${this.report.peakLabel}`;
    if (this.report.avgLabel.length > 0) {
      text = `${text}，${this.report.avgLabel}`;
    }
    if (this.report.completionPct >= 0) {
      text = `${text}，${this.completionText()}`;
    }
    return text;
  }

  /** 节奏卡底部完播文案：`完播 X%`；有中途切走时追加 ` · N 首中途切走`（0 首不出现「0 首」） */
  private completionText(): string {
    let text: string = `完播 ${this.report.completionPct}%`;
    if (this.report.abandonedCount > 0) {
      text = `${text} · ${this.report.abandonedCount} 首中途切走`;
    }
    return text;
  }

  /** 选中周期在 DIARY_PERIODS 中的下标（分段滑块定位用） */
  private periodIndex(): number {
    return DIARY_PERIODS.indexOf(this.period);
  }

  /** 周期分段（268×32 胶囊背板 + 单一滑块 + 44 高透明触控容器承接点击，设计 §4.1/§9） */
  @Builder
  periodSeg() {
    Stack() {
      // 背板：bg_divider 胶囊，内边距 2 形成滑块的内缩视觉
      Row()
        .width(268)
        .height(32)
        .backgroundColor($r('app.color.bg_divider'))
        .borderRadius(16)
      // 滑块：选中格实底胶囊，position 随选中下标平移 —— period 变更在
      // switchPeriod 的 interpolatingSpring 弹簧内完成，滑动带一次小过冲回弹
      Row()
        .width(PERIOD_SEG_SLOT)
        .height(28)
        .borderRadius(14)
        .backgroundColor(this.themePrimary)
        .position({
          x: PERIOD_SEG_THUMB_X0 + this.periodIndex() * PERIOD_SEG_SLOT,
          y: PERIOD_SEG_THUMB_Y
        })
      // 触控行：横向 padding 2 承接设计「内边距 2」的滑块内缩视觉；
      // 文字随选中态换色 / 加粗（在弹簧内交叉淡变），点击切周期
      Row() {
        ForEach(DIARY_PERIODS, (p: DiaryPeriod): void => {
          Column() {
            Text(diaryPeriodLabel(p))
              .fontSize(13)
              .fontWeight(this.period === p ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.period === p ? this.themeOn : $r('app.color.text_secondary'))
          }
          .height(44)
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .accessibilityText(`${diaryPeriodLabel(p)}视图`)
          .accessibilityLevel('yes')
          .onClick((): void => {
            this.switchPeriod(p);
          })
        }, (p: DiaryPeriod): string => p)
      }
      .width(268)
      .height(44)
      .padding({ left: 2, right: 2 })
    }
    .width(268)
    .height(44)
    .margin({ top: 4 })
  }

  /** 周期翻页行（‹ 日期范围 › [今天]；右箭头到当前周期禁用、左箭头到保留期下限禁用，设计 §4.2） */
  @Builder
  periodPager() {
    Row() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(16)
          .fontColor([this.report.atHistoryFloor ? $r('app.color.text_disabled') : $r('app.color.text_tertiary')])
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .accessibilityText(this.report.atHistoryFloor ? '已到最早记录' : '上一期')
      .accessibilityLevel('yes')
      .onClick((): void => {
        if (!this.report.atHistoryFloor) {
          this.shiftRange(-1);
        }
      })

      Text(this.report.dateRangeLabel)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .maxLines(1)

      Row() {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([this.report.isCurrent ? $r('app.color.text_disabled') : $r('app.color.text_tertiary')])
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .accessibilityText(this.report.isCurrent ? '已是最新周期' : '下一期')
      .accessibilityLevel('yes')
      .onClick((): void => {
        if (!this.report.isCurrent) {
          this.shiftRange(1);
        }
      })

      // 「今天」快捷回位：仅翻往历史时出现（当前周期不占位），点击锚点回
      // 当前时刻重算（shiftRange 逐页翻回的省力入口）
      if (!this.report.isCurrent) {
        Text('今天')
          .fontSize(13)
          .fontColor(this.themeDeep)
          .height(44)
          .constraintSize({ minWidth: 44 })
          .padding({ left: 8, right: 8 })
          .textAlign(TextAlign.Center)
          .accessibilityText('回到今天')
          .accessibilityLevel('yes')
          .onClick((): void => {
            this.anchorMs = Date.now();
            this.rebuild(true);
          })
      }
    }
    .width('100%')
    .height(44)
  }

  /** Hero 单页：16:9 封面 + 底部渐变 + 胶囊标签 + 标题/副行（设计 §4.3） */
  @Builder
  heroCard(t: DiaryTopTrack) {
    Stack() {
      CoverImage({
        url: t.coverUrl,
        fillParent: true,
        imgRadius: 0,
        altText: `${t.title}，${t.artist}`
      })
      Stack({ alignContent: Alignment.BottomStart }) {
        // 底部 62% 黑色渐变遮罩（下深上浅）
        Column()
          .width('100%')
          .height('62%')
          .linearGradient({
            angle: 0,
            colors: [['rgba(0,0,0,0.78)', 0], ['rgba(0,0,0,0)', 1]]
          })
        Column() {
          Text(t.title)
            .fontSize(16)
            .fontWeight(600)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${t.artist} · ${t.plays} 次`)
            .fontSize(11)
            .fontColor('rgba(255,255,255,0.82)')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12, right: 12, bottom: 12 })
      }
      .width('100%')
      .height('100%')

      // 左上角周期语境胶囊（如「本周 Top 5」，§9.1）：黑 42% 半透明底压在
      // 渐变之上；外层 Stack alignContent TopStart 定位，仅数据路径渲染
      //（heroSection 空态分支无胶囊）
      Row() {
        Text(this.report.heroLabel)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
      .height(22)
      .padding({ left: 8, right: 8 })
      .borderRadius(11)
      .backgroundColor('rgba(0,0,0,0.42)')
      .justifyContent(FlexAlign.Center)
      .margin(10)
    }
    .width('100%')
    .height(152)
    .borderRadius(12)
    .clip(true)
    .alignContent(Alignment.TopStart)
  }

  /** 主视觉封面区：空周期保留封面位（surface 底占位）；有数据 = Swiper 轮播 + 圆点 */
  @Builder
  heroSection() {
    Column() {
      if (this.report.topTracks.length === 0) {
        // 空态封面位：brand_surface 底 + 占位图标，不留白（设计 §7）
        Stack() {
          CoverImage({ url: '', fillParent: true, imgRadius: 0 })
        }
        .width('100%')
        .height(152)
        .borderRadius(12)
        .clip(true)
      } else {
        // 独立卡片轮播：Swiper 视口负边距外扩到屏幕边缘——卡片出入的切边
        // 发生在屏缘（读作滑出屏幕，不会在内容列边露出方形切角，原「切换时
        // 圆角丢失」根因）；卡片在每页内水平内缩 16，卡间露出页底色——切换
        // 全程每张卡都是独立圆角 + 自带投影，不再共享一个带阴影的边框
        //（原「连接处上下边框阴影、不像单独卡片」根因）。
        Swiper() {
          ForEach(this.report.topTracks, (t: DiaryTopTrack): void => {
            Column() {
              this.heroCard(t)
            }
            .width('100%')
            .padding({ left: 16, right: 16 })
          }, (t: DiaryTopTrack): string => `${t.trackId}_${t.plays}_${t.totalMs}`)
        }
        .width('100%')
        .height(152)
        .margin({ left: -16, right: -16 })
        // 松手回位动画：默认 interpolatingSpring（时长不受 duration 控制、
        // 收尾偏飘）；换 Friction 减速曲线 + 350ms——甩出快、入位缓停，
        // 与系统滑动惯性同一手感。
        .duration(350)
        .curve(Curve.Friction)
        .index(this.heroIndex)
        .indicator(false)
        // 自动轮播：间隔 4s，末页 loop 回首页；仅拾音页签激活时启动 ——
        // TabContent 常驻，切走页签后定时器继续跑是纯空转（activeTab 经
        // AppStorage 写穿，切页即停/即起）；单卡无页可翻，不启动。
        // 手动滑动会被 Swiper 挂起本轮、松手后按新 index 重新计时。
        .autoPlay(this.activeTab === DIARY_TAB_INDEX && this.report.topTracks.length > 1)
        .interval(HERO_AUTO_PLAY_MS)
        .loop(true)
        .onChange((i: number): void => {
          this.heroIndex = i;
        })

        // 圆点（选中拉长成 14×5 胶囊，themePrimary）。槽位固定 14 宽：胶囊
        // 只在槽内做宽度/透明度补间，圆点间距不随选中位跳动。
        Row({ space: 4 }) {
          ForEach(this.report.topTracks, (t: DiaryTopTrack, idx: number): void => {
            Row() {
              Row()
                .width(idx === this.heroIndex ? 14 : 5)
                .height(5)
                .borderRadius(2.5)
                .backgroundColor(this.themePrimary)
                .opacity(idx === this.heroIndex ? 1 : 0.24)
                .animation({ duration: 200, curve: Curve.EaseOut })
            }
            .width(14)
            .height(5)
            .justifyContent(FlexAlign.Center)
          }, (t: DiaryTopTrack): string => t.trackId)
        }
        .justifyContent(FlexAlign.Center)
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .margin({ top: 12 })
  }

  /** 一句话（13/secondary 居中，最多两行，句式库见 ListenDiaryStats） */
  @Builder
  sentenceSection() {
    if (this.report.sentence.length > 0) {
      Text(this.report.sentence)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 12 })
    }
  }

  /** KPI 单格：数字在上（24/SemiBold）、单位在下（11/tertiary），不挤一行 */
  @Builder
  kpiCell(arg: KpiCellArg) {
    Column() {
      Text(arg.cell.value)
        .fontSize(24)
        .fontWeight(600)
        .fontColor($r('app.color.text_primary'))
        // 大字体钳制：系统字号放大对该数字的放大上限 1.2×，防四列挤爆截断
        .maxFontScale(1.2)
        .maxLines(1)
      Text(arg.cell.unit)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  /** 环比基准词：日→昨天 / 周→上周 / 月→上月 / 年→去年 */
  private prevWord(): string {
    if (this.period === DiaryPeriod.Day) {
      return '昨天';
    }
    if (this.period === DiaryPeriod.Week) {
      return '上周';
    }
    if (this.period === DiaryPeriod.Month) {
      return '上月';
    }
    return '去年';
  }

  /** 环比行文案：`比昨天多听了 3.2 小时`（负向「少听了」；纯事实，无价值判断） */
  private compareText(): string {
    const cell: DiaryKpiCell = formatDiaryDuration(Math.abs(this.report.deltaListenMs));
    const absText: string = `${cell.value} ${cell.unit}`;
    return `比${this.prevWord()}${this.report.deltaListenMs > 0 ? '多' : '少'}听了 ${absText}`;
  }

  /** 四个数字（听歌时长 / 播放次数 / 不同歌曲 / 天听歌|位 UP 主）+ 可选环比行 */
  @Builder
  kpiGrid() {
    Column() {
      Row() {
        this.kpiCell({ cell: this.report.kpiListen })
        this.kpiCell({ cell: this.report.kpiPlays })
        this.kpiCell({ cell: this.report.kpiSongs })
        this.kpiCell({ cell: this.report.kpiExtra })
      }
      .width('100%')

      // 环比行：上一周期有收听基准且时长差非 0 才出现（不逐格加箭头）
      if (this.report.prevListenMs > 0 && this.report.deltaListenMs !== 0) {
        Text(this.compareText())
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .margin({ top: 16 })
  }

  /** 听歌节奏卡：surface 底柱状图 + 峰值实底 + 均值虚线 + 轴（设计 §4.6） */
  @Builder
  rhythmChart() {
    Column() {
      Row() {
        Text('听歌节奏')
          .fontSize(16)
          .fontWeight(600)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(this.report.peakLabel)
          .fontSize(13)
          .fontColor(this.themeDeep)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 图区：柱（槽位等分、柱居中槽内）+ 均值虚线（底部对齐叠加）
      Stack({ alignContent: Alignment.BottomStart }) {
        Row() {
          ForEach(this.report.buckets, (b: DiaryBucket): void => {
            Column() {
              Row()
                .width(this.report.barWidthVp)
                .height(`${this.barPct(b.ms, this.report.maxBucketMs)}%`)
                .borderRadius(this.report.barWidthVp / 2)
                .backgroundColor(this.themePrimary)
                .opacity(this.isPeakBar(b.ms, this.report.maxBucketMs) ? 1 : 0.24)
            }
            .layoutWeight(1)
            .height('100%')
            .justifyContent(FlexAlign.End)
            .alignItems(HorizontalAlign.Center)
          }, (b: DiaryBucket): string => `${this.period}_${b.label}_${b.ms}`)
        }
        .width('100%')
        .height('100%')

        // 均值虚线：Row + 短横条（4px 段 / 2.5% 槽），不依赖渐变虚线 API
        if (this.report.maxBucketMs > 0) {
          Row() {
            ForEach(DASH_SEGMENTS, (n: number): void => {
              Row() {
                Row()
                  .width(4)
                  .height(2)
                  .borderRadius(1)
                  .backgroundColor(this.themePrimary)
                  .opacity(0.55)
              }
              .width('2.5%')
              .justifyContent(FlexAlign.Center)
            }, (n: number): string => `d${n}`)
          }
          .width('100%')
          .height(2)
          .margin({ bottom: this.avgLineVp() })
        }
      }
      .width('100%')
      .height(CHART_PLOT_HEIGHT)
      .margin({ top: 12 })

      // X 轴：槽位与柱严格对齐，标签按密度抽稀（空串占位）
      Row() {
        ForEach(this.report.buckets, (b: DiaryBucket): void => {
          Text(b.label)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .height(15)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
        }, (b: DiaryBucket): string => `axis_${this.period}_${b.label}_${b.ms}`)
      }
      .width('100%')
      .margin({ top: 4 })

      // 卡底双信息行：均值说明居左、完播率居右（互不挤压，设计 §4.6）
      if (this.report.avgLabel.length > 0 || this.report.completionPct >= 0) {
        Row() {
          if (this.report.avgLabel.length > 0) {
            Text(this.report.avgLabel)
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
          }
          Blank()
          if (this.report.completionPct >= 0) {
            Text(this.completionText())
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .textAlign(TextAlign.End)
              .maxLines(1)
          }
        }
        .width('100%')
        .margin({ top: 8 })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 8 })
    .backgroundColor(this.themeSurface)
    .borderRadius(12)
    .margin({ top: 16 })
    .accessibilityText(this.chartAccessibilityText())
    .accessibilityLevel('yes')
  }

  /**
   * 时段偏好卡（周/月/年视图；听歌节奏卡之后）：六行横条 =
   * 主页标题问候语的六个时段（早上→凌晨，common/DaySegments 单一真源），
   * 占比口径 = 该时段收听 ms ÷ 周期总收听 ms。日视图不显示（24 小时
   * 逐时柱图已覆盖该信息）；周期内无会话由渲染条件整卡隐藏。
   */
  @Builder
  daySegmentsSection() {
    Column() {
      Row() {
        Text('听歌时段')
          .fontSize(16)
          .fontWeight(600)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(this.report.dayPeakSegmentLabel)
          .fontSize(13)
          .fontColor(this.themeDeep)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      ForEach(this.report.daySegments, (seg: DiaryDaySegment, idx: number): void => {
        Row() {
          Text(seg.label)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .constraintSize({ minWidth: 32 })
          // 占比横条：轨道 bg_divider 底，填充按 pct%；峰值实底、其余 24%
          Row() {
            Row()
              .width(`${seg.pct}%`)
              .height(6)
              .borderRadius(3)
              .backgroundColor(this.themePrimary)
              .opacity(this.isPeakSeg(seg) ? 1 : 0.24)
          }
          .layoutWeight(1)
          .height(6)
          .borderRadius(3)
          .backgroundColor($r('app.color.bg_divider'))
          .margin({ left: 6 })

          Text(this.segDurationText(seg))
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ left: 8 })
            .maxLines(1)
        }
        .width('100%')
        .height(22)
        .alignItems(VerticalAlign.Center)
        .margin({ top: idx === 0 ? 12 : 8 })
      }, (seg: DiaryDaySegment): string => `${seg.key}_${seg.ms}_${seg.pct}`)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 10 })
    .backgroundColor(this.themeSurface)
    .borderRadius(12)
    .margin({ top: 16 })
    .accessibilityText(
      `${this.report.sectionPrefix}听歌时段偏好，${this.report.dayPeakSegmentLabel}`)
    .accessibilityLevel('yes')
  }

  /** 标签相对权重（= weight / 最大权重；最大权重非正时按 1 兜底防除零） */
  private tagRel(entry: DiaryTagEntry): number {
    const max: number = this.tagCloud.length > 0 ? this.tagCloud[0].weight : 0;
    return max > 0 ? entry.weight / max : 1;
  }

  /** 标签字号档位：相对权重 ≥0.6 → 20（加粗）；≥0.3 → 16；其余 13（设计字号表内取值） */
  private tagFontSize(rel: number): number {
    if (rel >= 0.6) {
      return 20;
    }
    if (rel >= 0.3) {
      return 16;
    }
    return 13;
  }

  /** 点击标签 → 搜索页自动搜索该标签 */
  private openTagSearch(entry: DiaryTagEntry): void {
    NavStackHolder.push('Search', new SearchRouteParam(entry.name));
  }

  /** 周期标签卡（今日/本周/本月/年度标签）：纯文字字号分层标签云，点击进搜索 */
  @Builder
  tagCloudSection() {
    Column() {
      Row() {
        Text(`${this.report.sectionPrefix}标签`)
          .fontSize(16)
          .fontWeight(600)
          .fontColor($r('app.color.text_primary'))
        Blank()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 标签云：Flex 换行排布；权重越大的标签字号越大（Top1 加粗）
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.tagCloud, (entry: DiaryTagEntry): void => {
          Row() {
            Text(entry.name)
              .fontSize(this.tagFontSize(this.tagRel(entry)))
              .fontWeight(this.tagRel(entry) >= 0.6 ? 600 : FontWeight.Normal)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
          }
          .padding({ left: 4, right: 4, top: 6, bottom: 6 })
          .margin({ right: 4 })
          .stateStyles({
            pressed: { .backgroundColor($r('app.color.press_overlay')) },
            normal: { .backgroundColor(Color.Transparent) }
          })
          .borderRadius(6)
          .accessibilityText(`搜索标签${entry.name}`)
          .accessibilityLevel('yes')
          .onClick((): void => {
            this.openTagSearch(entry);
          })
        }, (entry: DiaryTagEntry): string => `${entry.name}_${entry.weight}`)
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 10 })
    .backgroundColor(this.themeSurface)
    .borderRadius(12)
    .margin({ top: 16 })
    .accessibilityText(`${this.report.sectionPrefix}标签，共 ${this.tagCloud.length} 个`)
    .accessibilityLevel('yes')
  }

  /**
   * 循环榜单行：序号 / 44 封面 / 歌名+副行 / 次数；整行可点播放，长按弹
   * 五项菜单（播放 / 队列 / 收藏 / 搜索 / 复制）。长按走显式 LongPressGesture
   * 驱动受控 bindMenu（HomeQuickCards 验证过的模式：bindContextMenu 的
   * LongPress 响应在触屏上不触发）；长按松手后内置 click 仍会 fire，
   * suppressNextClick 守卫首击吞掉，否则菜单刚弹出就起播。
   */
  @Builder
  topLoopRow(t: DiaryTopTrack, idx: number) {
    Row() {
      Text(this.rankLabel(idx))
        .fontSize(24)
        .fontWeight(600)
        .fontColor(idx === 0 ? this.themePrimary : $r('app.color.text_tertiary'))
        .opacity(idx === 0 ? 1 : 0.72)
        .constraintSize({ minWidth: 24 })
        .textAlign(TextAlign.Center)

      CoverImage({
        url: t.coverUrl,
        imgWidth: 44,
        imgHeight: 44,
        imgRadius: 8,
        altText: t.title
      })
        .margin({ left: 12 })

      Column() {
        Text(t.title)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.loopSubText(t))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .margin({ left: 12 })
      .alignItems(HorizontalAlign.Start)

      Row() {
        Text(`${t.plays}`)
          .fontSize(18)
          .fontWeight(600)
          .fontColor($r('app.color.text_primary'))
        Text('次')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ left: 2 })
      }
      .alignItems(VerticalAlign.Bottom)
      .margin({ left: 12 })
    }
    .width('100%')
    .height(60)
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .borderRadius(8)
    .accessibilityText(`${t.title}，${this.loopSubText(t)}，${t.plays}次`)
    .accessibilityLevel('yes')
    .onClick((): void => {
      // 长按弹菜单的这次松手 click 吞掉（菜单开期间点行也不再起播，等菜单关闭）
      if (this.suppressNextClick) {
        this.suppressNextClick = false;
        return;
      }
      this.playTopTrack(t);
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: 400 })
        .onAction((): void => {
          this.loopMenuTrackId = t.trackId;
          this.suppressNextClick = true;
        })
    )
    .bindMenu(this.loopMenuTrackId === t.trackId, this.loopMenuItems(t), {
      onDisappear: (): void => {
        // 菜单关闭（选中 / 点外部）即复位，否则 isShow 恒真、下次长按弹不出
        this.loopMenuTrackId = '';
      }
    })
  }

  /** 循环榜榜单取前 5：topTracks 上限即 5（Hero 轮播与榜单共用同一数据源） */
  private topLoopList(): DiaryTopTrack[] {
    return this.report.topTracks.slice(0, 5);
  }

  /** 循环榜（Top5；「全部 ›」进收听流水页） */
  @Builder
  topLoopSection() {
    Column() {
      Row() {
        Text(`${this.report.sectionPrefix}循环`)
          .fontSize(18)
          .fontWeight(600)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('全部 ›')
          .fontSize(13)
          .fontColor(this.themeDeep)
          .height(44)
          .accessibilityText('查看收听流水')
          .accessibilityLevel('yes')
          .onClick((): void => {
            NavStackHolder.push('DiaryTimeline', undefined);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      ForEach(this.topLoopList(), (t: DiaryTopTrack, idx: number): void => {
        Column() {
          this.topLoopRow(t, idx)
          // 行间分隔线从 56px 处起画（不贯穿序号列，设计 §4.7）
          if (idx < this.topLoopList().length - 1) {
            Row() {
              Row()
                .width(56)
              Divider()
                .color($r('app.color.bg_divider'))
                .layoutWeight(1)
            }
            .width('100%')
          }
        }
        .width('100%')
      }, (t: DiaryTopTrack): string => `${t.trackId}_${t.plays}_${t.dayCount}_${this.period}`)
    }
    .width('100%')
    .margin({ top: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 常听 UP 主（3 个圆形头像等分 + 名字 + 时长；点击进 UP 主主页） */
  @Builder
  topUpsSection() {
    Column() {
      Text(`${this.report.sectionPrefix}常听`)
        .fontSize(18)
        .fontWeight(600)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      Row({ space: 8 }) {
        ForEach(this.report.topUps, (u: DiaryTopUp): void => {
          Column() {
            CoverImage({
              url: u.avatarUrl,
              imgWidth: 60,
              imgHeight: 60,
              imgRadius: 30,
              altText: u.name
            })
            Text(u.name)
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 8 })
            Text(this.upDurationText(u))
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .margin({ top: 2 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
          .accessibilityText(`${u.name}，${this.upDurationText(u)}`)
          .accessibilityLevel('yes')
          .onClick((): void => {
            this.openUpSpace(u);
          })
        }, (u: DiaryTopUp): string => `${u.key}_${u.totalMs}_${u.plays}`)
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .margin({ top: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 新面孔卡点击 → 新面孔清单页（快照传参：标题 + 副标题 + 列表） */
  private openNewFaces(): void {
    NavStackHolder.push('DiaryNewFaces',
      new DiaryNewFacesRouteParam(this.report.newFaceTitle, this.report.newFaceSub, this.report.newFaces));
  }

  /** 新面孔卡（点击进清单页） */
  @Builder
  newFacesCard() {
    Row() {
      Row() {
        ForEach(this.report.newFaceAvatars, (a: string, i: number): void => {
          CoverImage({ url: a, imgWidth: 28, imgHeight: 28, imgRadius: 14 })
            .border({ width: 2, color: $r('app.color.bg_card') })
            .margin({ left: i === 0 ? 0 : -8 })
        }, (a: string, i: number): string => `face_${i}_${a}`)
      }
      .alignItems(VerticalAlign.Center)

      Column() {
        Text(this.report.newFaceTitle)
          .fontSize(16)
          .fontWeight(600)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
        Text(this.report.newFaceSub)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .margin({ left: 12 })
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([$r('app.color.text_tertiary')])
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
    .margin({ top: 22 })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor($r('app.color.bg_card')) }
    })
    .accessibilityText(`${this.report.newFaceTitle}，${this.report.newFaceSub}`)
    .accessibilityLevel('yes')
    .onClick((): void => {
      this.openNewFaces();
    })
  }

  /** 空态「去首页听点音乐 ›」（次级按钮，非实底，设计 §7） */
  @Builder
  goHomeButton() {
    Row() {
      Text('去首页听点音乐 ›')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
    }
    .width('100%')
    .height(44)
    .justifyContent(FlexAlign.Center)
    .borderRadius(22)
    .border({ width: 1, color: $r('app.color.bg_divider') })
    .margin({ top: 22 })
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .accessibilityText('去首页听点音乐')
    .accessibilityLevel('yes')
    .onClick((): void => {
      this.goHome();
    })
  }

  /** 内容主体（report 就绪后渲染） */
  @Builder
  mainContent() {
    Column() {
      this.periodSeg()
      this.periodPager()

      // 往期空周期：居中提示 + 内容整体降透明度 60%（仍允许翻页，设计 §7）；
      // 周期完全超出 13 个月保留窗时换保留期提示（翻页下限已钳保留期，此为双保险）
      if (this.report.isEmpty && !this.report.isCurrent) {
        Text(this.report.outOfRetention ? '拾音只保留最近 13 个月的记录' : this.report.emptyHint)
          .fontSize(13)
          .fontColor(this.report.outOfRetention
            ? $r('app.color.text_tertiary') : $r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ top: 32, bottom: 8 })
      }

      Column() {
        this.heroSection()
        this.sentenceSection()
        this.kpiGrid()
        this.rhythmChart()
        // 时段偏好卡：周/月/年视图且周期内有收听数据才显示
        //（日视图 24 小时逐时柱图已覆盖该信息，不重复放）
        if (this.period !== DiaryPeriod.Day && this.report.daySegmentsTotalMs > 0) {
          this.daySegmentsSection()
        }
        // 周期标签卡：节奏卡与循环榜之间；标签未就绪 / 无标签时整块隐藏
        if (this.tagCloud.length > 0) {
          this.tagCloudSection()
        }
      }
      .width('100%')
      .opacity(this.report.isEmpty && !this.report.isCurrent ? 0.6 : 1)

      // 数据区块：空周期整块隐藏（不显示空列表，设计 §7）
      if (!this.report.isEmpty) {
        if (this.report.topTracks.length > 0) {
          this.topLoopSection()
        }
        if (this.report.topUps.length > 0) {
          this.topUpsSection()
        }
        // 新面孔卡：往期年视图隐藏——「近 13 个月第一次」的窗口口径对
        // 往期年算不出可靠结果（数据只覆盖 13 个月），宁缺毋滥
        if (this.report.newFaceCount > 0
          && !(this.period === DiaryPeriod.Year && !this.report.isCurrent)) {
          this.newFacesCard()
        }
      } else if (this.report.isCurrent) {
        // 当前周期空态：完整空态 + 去首页按钮（回顾卡片按钮 Phase 2 隐藏）
        this.goHomeButton()
      }
    }
    .width('100%')
  }

  build() {
    Stack() {
      Scroll(this.diaryScroller) {
        Column() {
          // 顶部占位：内容从根栏材质下方穿过（safeTop + 根标题栏 56，
          // 与 Index 根栏让位同口径）
          Row()
            .width('100%')
            .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)

          if (!this.reportReady) {
            // 全量会话读回前画 3 个灰块骨架（分段 / Hero / KPI 行的位置占位），
            // 避免先闪纯背景、再闪一版空态、最后跳真数据的连环闪变
            Column() {
              Row()
                .width(268)
                .height(32)
                .borderRadius(16)
                .backgroundColor($r('app.color.bg_divider'))
                .margin({ top: 4 })
              Row()
                .width('100%')
                .height(152)
                .borderRadius(12)
                .backgroundColor($r('app.color.bg_divider'))
                .margin({ top: 12 })
              Row()
                .width('100%')
                .height(24)
                .borderRadius(8)
                .backgroundColor($r('app.color.bg_divider'))
                .margin({ top: 16 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          } else {
            this.mainContent()
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        // Scroll 无 contentEndOffset（List 专属），底部避让用内层 padding：
        // 悬浮页签胶囊 + 手势区（与其他页签页同口径）
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

      // 顶栏渐变模糊层：盖 Scroll 内容之上（z 序低于 Index 根栏 HDS titleBar）
      TopGradientBlurOverlay({
        barHeightVp: this.safeTop + NAV_TITLE_BAR_HEIGHT,
        updater: this.topBlurUpdater
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
