/**
 * 歌单导入向导页（网易云 / QQ 音乐 → 本地歌单，2026-10-16）。
 * 方案见 design/歌单导入方案-网易云与QQ音乐.md §5：单页 5 态状态机，不做多页转场。
 *
 *   [1 输入] → 识别 → [2 预览] → 开始匹配 → [3 匹配中] → [4 报告] ⇄ [5 复核] → 完成导入
 *
 * 匹配任务在 service/PlaylistImporter.ts 的 ImportTaskManager 单例里跑
 * （DownloadManager 的 queue/pump 同款思路）：离开本页继续，回来能看到进度；
 * 进度经 AppStorage(STORE_IMPORT_STATE) 广播新快照，本页 @StorageLink + @Watch 订阅。
 *
 * 识别三路线（方案 §2）：链接直连（网易云 v6→v3 / QQ 一次全量，失败一律降级提示
 * 「改用文本粘贴」）→ 文本粘贴（主路径）→ 复核时手动搜索（路线 C，内置兜底）。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，stackBuilder 承载返回行 +
 * 标题，与 FavSyncPage 同构）；内容让位走「下载页同款」顶部空白占位条目
 * （List 首项，高度 = safeTop + 56），滚动时内容从沉浸材质下方穿过。
 */

import {
  ExternalPlaylist,
  ExternalSong,
  ImportItem,
  ImportItemStatus,
  ImportPhase,
  ImportState,
  ImportTaskManager,
  ShareShortLink,
  defaultImportName,
  detectNeteasePlaylistId,
  detectQqPlaylistId,
  detectShareShortLink,
  emptyImportState,
  fetchNeteasePlaylist,
  fetchQqPlaylist,
  isExternalPlaylistLink,
  parseSongListText,
  resolveShareShortLink
} from '../service/PlaylistImporter';
import { PLAYLIST_MAX_ITEMS } from '../service/LibraryStore';
import { Track, Playlist } from '../model/MusicModels';
import { NavStackHolder } from '../service/NavStackHolder';
import { PlaylistDetailRouteParam } from '../service/NavRouteParams';
import { showAppToast } from '../components/AppToast';
import { showAppAlertDialog } from '../components/AppAlertDialog';
import { readText } from '../utils/ClipboardUtil';
import { InsetCard, CardDivider, SectionHeader, SectionFooter } from '../components/InsetCardGroup';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import {
  ButtonMaterialModifier,
  makeButtonMaterialModifier
} from '../utils/HeaderBarMaterial';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import {
  STORE_IMPORT_STATE,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY,
  STORE_THEME_ON,
  STORE_THEME_SURFACE
} from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { NAV_TRANSITION_MS, BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import { NavTitleRow } from '../components/NavTitleRow';

/**
 * 向导 5 态（方案 §5.2）。匹配中 / 报告的实际进度数据来自 importState，
 * 本地只记「页面走到哪一步」，二者经 @Watch 在阶段翻转时对齐。
 */
enum PagePhase {
  INPUT = 0,
  PREVIEW = 1,
  MATCHING = 2,
  REPORT = 3,
  REVIEW = 4
}

/** 顶栏滚动模糊时机（FavSyncPage 同款基准口径） */
const IMPORT_BLUR_START_VP: number = 30;
const IMPORT_BLUR_END_VP: number = 80;

/** 秒 → m:ss / mm:ss（TrackItem.formatDuration 的本地轻量同款） */
function formatDuration(sec: number): string {
  if (!(sec > 0)) {
    return '';
  }
  const s: number = Math.round(sec);
  const m: number = Math.floor(s / 60);
  const r: number = s % 60;
  const rStr: string = r < 10 ? `0${r}` : `${r}`;
  return `${m}:${rStr}`;
}

/** 播放量 → 1.2万 口径（与条目展示惯例一致） */
function formatPlayCount(n: number): string {
  if (n >= 100000000) {
    return `${(n / 100000000).toFixed(1)}亿`;
  }
  if (n >= 10000) {
    return `${(n / 10000).toFixed(1)}万`;
  }
  return `${n}`;
}

@Component
export struct PlaylistImportPage {
  /** 导入任务快照（单例广播；本地态 pagePhase 与它的 phase 经 @Watch 对齐） */
  @StorageLink(STORE_IMPORT_STATE) @Watch('onImportStateChanged') importState: ImportState = emptyImportState();
  /** 主题色运行时值 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  /** 状态栏 / 底部安全区高度（vp） */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;

  /** 页面当前步骤（见 PagePhase） */
  @State pagePhase: PagePhase = PagePhase.INPUT;
  /** 输入态：粘贴的原文 */
  @State inputText: string = '';
  /** 输入态：识别中（直连拉取 / 文本解析进行中，按钮禁用） */
  @State recognizing: boolean = false;
  /** 识别结果（预览态展示、开始匹配的输入） */
  @State external: ExternalPlaylist | null = null;
  /** 超出单歌单 500 首上限被截断 */
  @State truncated: boolean = false;
  /** 报告态：歌单名输入框（默认名来自识别结果或「导入歌单 MM-DD」） */
  @State playlistName: string = '';
  /** 复核态：当前处理到的复核队列下标 */
  @State reviewIndex: number = 0;
  /** 复核态：当前条目快照（从 importState.items 取，手动搜索后重取） */
  @State reviewItem: ImportItem | null = null;
  /** 复核态：手动搜索关键词 */
  @State manualKeyword: string = '';
  /** 复核态：手动搜索进行中 */
  @State manualSearching: boolean = false;
  /** 复核队列（items 下标，弱匹配 + 未找到，进入复核时重建） */
  private reviewQueue: number[] = [];
  /** 列表滚动控制器 */
  private scroller: Scroller = new Scroller();
  /** 主按钮沉浸光感材质修饰器：26+ 生效，低版本 no-op 显实色兜底 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 子页转场横移量：常驻 '0%'，转场代理按 push/pop 临时改写 */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    // 单例任务可能还在跑（用户离开后返回）：按任务阶段接续页面状态
    const st: ImportState = ImportTaskManager.getInstance().getState();
    if (st.phase === ImportPhase.MATCHING) {
      this.pagePhase = PagePhase.MATCHING;
    } else if (st.phase === ImportPhase.DONE || st.phase === ImportPhase.STOPPED
      || st.phase === ImportPhase.RISK) {
      this.pagePhase = PagePhase.REPORT;
      this.initReportDefaults();
    } else {
      this.pagePhase = PagePhase.INPUT;
    }
  }

  /** 任务阶段翻转（匹配中 → 报告）时把页面从匹配态切到报告态 */
  private onImportStateChanged(): void {
    if (this.pagePhase === PagePhase.MATCHING && this.importState.phase !== ImportPhase.MATCHING) {
      this.pagePhase = PagePhase.REPORT;
      this.initReportDefaults();
    }
  }

  /** 报告态默认歌单名：直连用原名，文本粘贴用「导入歌单 MM-DD」（方案 §4 命名） */
  private initReportDefaults(): void {
    if (this.playlistName.length > 0) {
      return;
    }
    const sourceName: string = this.importState.sourceName;
    this.playlistName = sourceName.length > 0 ? sourceName : defaultImportName();
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut，与 FavSyncPage 同款。
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

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  //
  // ── 输入态 ──
  //

  private async pasteFromClipboard(): Promise<void> {
    const t: string = await readText();
    const trimmed: string = t.trim();
    if (trimmed.length === 0) {
      this.toast('剪贴板是空的', 1800);
      return;
    }
    this.inputText = trimmed;
  }

  /**
   * 识别（方案 §2）：网易云链接 → QQ 链接 → **平台分享短链**（302 反查）→ 文本粘贴。
   * 直连失败一律降级提示「改用文本粘贴」，不报看不懂的错（方案 §2B）。
   *
   * ⚠️ 关键分支：命中平台域名却提不出歌单 ID 时**必须明确提示**（`isExternalPlaylistLink`），
   * 不能落进文本解析 —— 否则形如「分享歌单《xxx》https://… (来自@网易云音乐)」的整串分享
   * 文本会被当成一首歌名去搜 B 站，报告页全显「未找到」（2026-10-16 实测根因）。
   */
  private async recognize(): Promise<void> {
    if (this.recognizing) {
      return;
    }
    const text: string = this.inputText.trim();
    if (text.length === 0) {
      this.toast('先粘贴歌单链接或歌曲列表', 1800);
      return;
    }
    this.recognizing = true;
    try {
      const nid: string = detectNeteasePlaylistId(text);
      const qid: string = detectQqPlaylistId(text);
      let ext: ExternalPlaylist;
      if (nid.length > 0) {
        ext = await fetchNeteasePlaylist(nid);
      } else if (qid.length > 0) {
        ext = await fetchQqPlaylist(qid);
      } else {
        const shortLink: ShareShortLink | null = detectShareShortLink(text);
        if (shortLink !== null) {
          // App「分享 → 复制链接」的短链：URL 里不含歌单 ID，靠 302 的 Location 反查
          const sid: string = await resolveShareShortLink(shortLink);
          if (sid.length === 0) {
            this.toast('这个分享链接解析失败，请在 App 里复制歌曲列表文本粘贴', 2600);
            return;
          }
          if (shortLink.platform === 'qq') {
            ext = await fetchQqPlaylist(sid);
          } else {
            ext = await fetchNeteasePlaylist(sid);
          }
        } else if (isExternalPlaylistLink(text)) {
          this.toast('这个链接暂不支持，请在 App 里复制歌曲列表文本粘贴', 2600);
          return;
        } else {
          const songs: ExternalSong[] = parseSongListText(text);
          if (songs.length === 0) {
            this.toast('没有识别到歌曲，试试一行一首「歌名 - 歌手」', 2200);
            return;
          }
          ext = { name: '', coverUrl: '', songs: songs, sourceLabel: '文本列表' };
        }
      }
      if (ext.songs.length === 0) {
        this.toast('歌单里没有可识别的歌曲', 2000);
        return;
      }
      // 超限截断提示（不静默，方案 §3.4）
      this.truncated = ext.songs.length > PLAYLIST_MAX_ITEMS;
      if (this.truncated) {
        ext = {
          name: ext.name,
          coverUrl: ext.coverUrl,
          songs: ext.songs.slice(0, PLAYLIST_MAX_ITEMS),
          sourceLabel: ext.sourceLabel
        };
      }
      this.external = ext;
      this.playlistName = ext.name.length > 0 ? ext.name : defaultImportName();
      this.pagePhase = PagePhase.PREVIEW;
    } catch (e) {
      const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.error(`playlist import recognize failed: ${detail}`);
      this.toast('歌单拉取失败，请改用文本粘贴', 2400);
    } finally {
      this.recognizing = false;
    }
  }

  /** 预览态识别结果卡标题：直连「《歌单名》」+ 来源，文本「文本列表」 */
  private previewTitle(): string {
    const ext: ExternalPlaylist | null = this.external;
    if (ext === null) {
      return '';
    }
    if (ext.name.length > 0) {
      return `《${ext.name}》`;
    }
    return ext.sourceLabel;
  }

  private previewSubtitle(): string {
    const ext: ExternalPlaylist | null = this.external;
    if (ext === null) {
      return '';
    }
    const count: string = `${ext.songs.length} 首`;
    return ext.name.length > 0 ? `${ext.sourceLabel} · ${count}` : count;
  }

  /** 开始匹配：交给单例（离开页面继续跑），页面切匹配态 */
  private startMatching(): void {
    const ext: ExternalPlaylist | null = this.external;
    if (ext === null || ext.songs.length === 0) {
      this.pagePhase = PagePhase.INPUT;
      return;
    }
    const mgr: ImportTaskManager = ImportTaskManager.getInstance();
    if (mgr.isRunning()) {
      this.pagePhase = PagePhase.MATCHING;
      return;
    }
    mgr.start(ext.songs, ext.name, ext.coverUrl);
    this.pagePhase = PagePhase.MATCHING;
  }

  //
  // ── 匹配中 ──
  //

  private matchProgressPct(): number {
    const total: number = this.importState.total;
    if (total <= 0) {
      return 0;
    }
    return Math.min(100, Math.round(this.importState.processed * 100 / total));
  }

  /** 中断匹配（二次确认，保留已完成部分，方案 §5.3(3)） */
  private confirmStop(): void {
    showAppAlertDialog(this.getUIContext(), {
      title: '中断匹配',
      message: '已完成的匹配会保留，之后可以从报告页重新继续。',
      primaryButton: {
        value: '继续匹配',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '中断',
        action: (): void => {
          ImportTaskManager.getInstance().stop();
        }
      }
    });
  }

  //
  // ── 报告态 ──
  //

  /** 待复核条目数（弱匹配 + 未找到） */
  private pendingReviewCount(): number {
    return this.importState.weak + this.importState.missing;
  }

  /** 可导入条目数（强匹配含复核后确认的：setChosen 会置为 STRONG） */
  private importableCount(): number {
    // 必须按 bvid 去重，与 `ImportTaskManager.finish()` 的落库口径一致：
    // 两首不同的歌匹配到同一个 B 站视频时，finish 只落一首，若这里直接返回
    // `importState.strong`，按钮会写「54 首」而落库是 53 首（真机实测踩到）。
    const items: ImportItem[] = this.importState.items;
    const seen: Set<string> = new Set<string>();
    for (let i: number = 0; i < items.length; i++) {
      const t: Track | null = items[i].chosen;
      if (t !== null) {
        seen.add(t.bvid);
      }
    }
    return seen.size;
  }

  /** 中断 / 限流后未处理的条目数 */
  private unprocessedCount(): number {
    return Math.max(0, this.importState.total - this.importState.processed);
  }

  /** 报告标题（匹配完成 / 已中断 / 限流暂停） */
  private reportHeading(): string {
    if (this.importState.phase === ImportPhase.STOPPED) {
      return '匹配已中断';
    }
    if (this.importState.phase === ImportPhase.RISK) {
      return 'B 站限流，已暂停';
    }
    return '匹配完成';
  }

  /** 续跑（中断 / 限流后）：单例从中断游标继续，页面回匹配态 */
  private resumeMatching(): void {
    ImportTaskManager.getInstance().resume();
    if (ImportTaskManager.getInstance().isRunning()) {
      this.pagePhase = PagePhase.MATCHING;
    }
  }

  /** 进入复核：重建复核队列（弱匹配 + 未找到），从头处理（方案 §5.3(5)） */
  private enterReview(): void {
    const mgr: ImportTaskManager = ImportTaskManager.getInstance();
    const queue: number[] = mgr.pendingReviewIndexes();
    if (queue.length === 0) {
      this.toast('没有待确认的曲目', 1800);
      return;
    }
    this.reviewQueue = queue;
    this.reviewIndex = 0;
    this.loadReviewItem();
    this.pagePhase = PagePhase.REVIEW;
  }

  /** 放弃本次任务（二次确认：进度不可恢复） */
  private confirmDiscard(): void {
    showAppAlertDialog(this.getUIContext(), {
      title: '放弃本次导入',
      message: '已匹配的进度会被清空，确定放弃吗？',
      primaryButton: {
        value: '保留进度',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '放弃',
        action: (): void => {
          this.discardTask();
        }
      }
    });
  }

  private discardTask(): void {
    ImportTaskManager.getInstance().reset();
    this.external = null;
    this.inputText = '';
    this.playlistName = '';
    this.truncated = false;
    this.reviewQueue = [];
    this.reviewItem = null;
    this.manualKeyword = '';
    this.pagePhase = PagePhase.INPUT;
  }

  /** 落库：一次建单落盘（管理器内完成），成功后跳歌单详情（方案 §5.3(5)） */
  private doFinish(): void {
    const st: ImportState = this.importState;
    const mgr: ImportTaskManager = ImportTaskManager.getInstance();
    const p: Playlist | null = mgr.finish(this.playlistName, st.sourceCoverUrl);
    if (p === null) {
      this.toast('还没有可导入的曲目', 2000);
      return;
    }
    this.toast(`已导入歌单「${p.name}」（${p.tracks.length} 首）`, 2600);
    NavStackHolder.stack.pushPathByName('PlaylistDetail', new PlaylistDetailRouteParam(p.id));
  }

  //
  // ── 复核态 ──
  //

  /** 当前复核条目在 items 里的下标 */
  private currentReviewIdx(): number {
    if (this.reviewIndex < 0 || this.reviewIndex >= this.reviewQueue.length) {
      return -1;
    }
    return this.reviewQueue[this.reviewIndex];
  }

  /** 取当前复核条目快照（进入复核 / 手动搜索后重取，驱动候选区刷新） */
  private loadReviewItem(): void {
    const idx: number = this.currentReviewIdx();
    if (idx < 0 || idx >= this.importState.items.length) {
      this.reviewItem = null;
      return;
    }
    this.reviewItem = this.importState.items[idx];
    this.manualKeyword = '';
  }

  /** 复核选中某候选：置为强匹配并前进到下一条 */
  private pickCandidate(track: Track): void {
    const idx: number = this.currentReviewIdx();
    if (idx < 0) {
      return;
    }
    ImportTaskManager.getInstance().setChosen(idx, track);
    this.advanceReview();
  }

  /** 复核跳过当前条目，前进到下一条 */
  private skipReviewItem(): void {
    const idx: number = this.currentReviewIdx();
    if (idx < 0) {
      return;
    }
    ImportTaskManager.getInstance().skipItem(idx);
    this.advanceReview();
  }

  private advanceReview(): void {
    this.reviewIndex++;
    if (this.reviewIndex >= this.reviewQueue.length) {
      // 全部处理完 → 回报告态（方案 §5.3(5)）
      this.reviewItem = null;
      this.pagePhase = PagePhase.REPORT;
      return;
    }
    this.loadReviewItem();
  }

  /** 复核态手动搜索（路线 C）：替换候选后重取快照刷新候选区 */
  private async manualSearch(): Promise<void> {
    if (this.manualSearching) {
      return;
    }
    const idx: number = this.currentReviewIdx();
    if (idx < 0) {
      return;
    }
    this.manualSearching = true;
    try {
      await ImportTaskManager.getInstance().searchManual(idx, this.manualKeyword);
      this.loadReviewItem();
    } catch (e) {
      const detail: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.error(`playlist import manual search failed: ${detail}`);
      this.toast('搜索失败，请稍后再试', 2000);
    } finally {
      this.manualSearching = false;
    }
  }

  /** 复核条目的外部歌信息副标题：「歌手 · 04:37」（无则只显时长/歌手） */
  private reviewSongSubtitle(item: ImportItem): string {
    const parts: string[] = [];
    if (item.song.artist.length > 0) {
      parts.push(item.song.artist);
    }
    const dur: string = formatDuration(item.song.durationSec);
    if (dur.length > 0) {
      parts.push(dur);
    }
    return parts.join(' · ');
  }

  /** 候选行副标题：「UP 主 · 3:45 · 1.2万播放」 */
  private candidateSubtitle(c: Track): string {
    const parts: string[] = [];
    if (c.artist.length > 0) {
      parts.push(c.artist);
    }
    const dur: string = formatDuration(c.duration);
    if (dur.length > 0) {
      parts.push(dur);
    }
    parts.push(`${formatPlayCount(c.playCount)}播放`);
    return parts.join(' · ');
  }

  //
  // ── 标题栏 ──
  //

  /**
   * 标题行内容（titleBar 的 stackBuilder 承载，可用空间仅 56vp）：返回键 + 标题。
   * 材质与滚动模糊由 HDS titleBar 负责（HdsTitleBarStyle 统一）。
   */
  @Builder
  pageBar() {
    NavTitleRow({ title: '从外部导入歌单' })
  }

  //
  // ── 各态内容 ──
  //

  /** 输入态：TextArea + 从剪贴板粘贴 + 识别按钮 */
  @Builder
  inputBody() {
    Column() {
      TextArea({ text: this.inputText, placeholder: '粘贴网易云 / QQ 音乐的歌单链接，或一行一首「歌名 - 歌手」' })
        .height(144)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .placeholderFont({ size: 13 })
        .backgroundColor(Color.Transparent)
        // ⚠️ 不能 padding(0)：TextArea 内容会贴组件左缘渲染，首个字符被裁
        // （真机实测「第一个字显示不全」）。留小内边距，文字仍在卡片 16vp 内边距之内。
        .padding({ left: 4, right: 4, top: 10, bottom: 10 })
        .constraintSize({ minHeight: 96 })
        .onChange((v: string): void => {
          this.inputText = v;
        })
      // ⚠️ HarmonyOS NEXT 上普通按钮静默读剪贴板会被系统拦截（getData 读到空），
      // 必须用系统安全控件 PasteButton：点击即授权临时读取，回调里再调
      // pasteFromClipboard → readText 才拿得到真实内容。样式走主题色：
      // themePrimary 底 + themeOn 字/图标（与「识别」主按钮同款）。注意安全控件
      // 的授权校验：文字必须完整显示、前景与背景对比度不能过低，字号/内边距保持克制。
      Row() {
        PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
          .fontSize(14)
          .iconSize(16)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor(this.themePrimary)
          .fontColor(this.themeOn)
          .iconColor(this.themeOn)
          .onClick((event: ClickEvent, result: PasteButtonOnClickResult): void => {
            if (result === PasteButtonOnClickResult.SUCCESS) {
              this.pasteFromClipboard();
            } else {
              this.toast('剪贴板授权失败，可长按输入框手动粘贴', 2400);
            }
          })
      }
      .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 16, bottom: 8 })
  }

  /** 预览态：识别结果卡（直连带封面缩略图）+ 超限警告 */
  @Builder
  previewBody() {
    Column() {
      if (this.external !== null && this.external.coverUrl.length > 0) {
        Image(this.external.coverUrl)
          .width(56)
          .height(56)
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
          .backgroundColor($r('app.color.bg_page'))
          .alt($r('app.media.app_icon'))
          .margin({ bottom: 12 })
      }
      Text(this.previewTitle())
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(this.previewSubtitle())
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 6 })
      if (this.truncated) {
        Text('超出单歌单 500 首上限，将只保留前 500 首')
          .fontSize(13)
          .fontColor($r('app.color.state_error'))
          .width('100%')
          .margin({ top: 10 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
  }

  /** 匹配中：进度 + 当前曲目 + 实时统计 + 后台继续提示 + 中断 */
  @Builder
  matchingBody() {
    Column() {
      Text(`${this.importState.processed} / ${this.importState.total}`)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Progress({ value: this.matchProgressPct(), total: 100, type: ProgressType.Linear })
        .color(this.themePrimary)
        .margin({ top: 14 })
      if (this.importState.currentTitle.length > 0) {
        Text(`正在匹配：${this.importState.currentTitle}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 12 })
      }
      Row() {
        Text(`✓ ${this.importState.strong}`)
          .fontSize(13)
          .fontColor($r('app.color.state_success'))
        Text(`? ${this.importState.weak}`)
          .fontSize(13)
          .fontColor($r('app.color.state_warning'))
          .margin({ left: 16 })
        Text(`✕ ${this.importState.missing}`)
          .fontSize(13)
          .fontColor($r('app.color.state_error'))
          .margin({ left: 16 })
      }
      .margin({ top: 10 })
      Text('可返回上一页，匹配会继续进行；完成后回到本页查看报告')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ top: 18 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 32, right: 32, top: 40, bottom: 40 })
  }

  /** 报告态统计行：标签 + 数值（三色分档，方案 §5.3(4)） */
  @Builder
  reportStatRow(label: string, value: number, color: Resource) {
    Row() {
      Text(label)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Text(`${value}`)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(color)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  /** 报告态：统计卡 + 歌单名输入 + 主/次按钮 */
  @Builder
  reportBody() {
    Column() {
      Text(this.reportHeading())
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      InsetCard() {
        Column() {
          this.reportStatRow('强匹配', this.importState.strong, $r('app.color.state_success'))
          CardDivider()
          this.reportStatRow('待确认', this.importState.weak, $r('app.color.state_warning'))
          CardDivider()
          this.reportStatRow('未找到', this.importState.missing, $r('app.color.state_error'))
          if (this.unprocessedCount() > 0) {
            CardDivider()
            this.reportStatRow('未处理', this.unprocessedCount(), $r('app.color.text_tertiary'))
          }
          if (this.importState.skipped > 0) {
            CardDivider()
            this.reportStatRow('已跳过', this.importState.skipped, $r('app.color.text_tertiary'))
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      }
      if (this.importState.riskMessage.length > 0) {
        Text(this.importState.riskMessage)
          .fontSize(13)
          .fontColor($r('app.color.state_warning'))
          .width('100%')
          .margin({ top: 10 })
      }
      if (this.importState.phase === ImportPhase.STOPPED || this.importState.phase === ImportPhase.RISK) {
        Button('继续匹配', { type: ButtonType.Normal })
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .height(44)
          .width('100%')
          .borderRadius(BUTTON_RADIUS_VP)
          .backgroundColor(this.themePrimary)
          .fontColor(this.themeOn)
          .attributeModifier(this.buttonMaterial)
          .margin({ top: 16 })
          .onClick((): void => {
            this.resumeMatching();
          })
      }
      TextInput({ text: this.playlistName, placeholder: defaultImportName() })
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .placeholderFont({ size: 13 })
        .backgroundColor($r('app.color.bg_page'))
        .height(48)
        .borderRadius(12)
        .margin({ top: 16 })
        .onChange((v: string): void => {
          this.playlistName = v;
        })
      Button(this.pendingReviewCount() > 0
        ? `处理待确认（${this.pendingReviewCount()}）`
        : `完成导入（${this.importableCount()} 首）`, { type: ButtonType.Normal })
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .height(44)
        .width('100%')
        .borderRadius(BUTTON_RADIUS_VP)
        .backgroundColor(this.themePrimary)
        .fontColor(this.themeOn)
        .attributeModifier(this.buttonMaterial)
        .margin({ top: 12 })
        .onClick((): void => {
          if (this.pendingReviewCount() > 0) {
            this.enterReview();
          } else {
            this.doFinish();
          }
        })
      if (this.pendingReviewCount() > 0) {
        Button(`跳过未决项，直接导入（${this.importableCount()} 首）`, { type: ButtonType.Normal })
          .fontSize(13)
          .height(40)
          .width('100%')
          .borderRadius(BUTTON_RADIUS_VP)
          .backgroundColor($r('app.color.bg_card'))
          .fontColor($r('app.color.text_primary'))
          .margin({ top: 10 })
          .onClick((): void => {
            this.doFinish();
          })
      }
      Text('放弃本次导入')
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
        .height(44)
        .margin({ top: 6 })
        .onClick((): void => {
          this.confirmDiscard();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 16, bottom: 8 })
  }

  /** 复核态：当前外部歌信息 + 候选列表 + 手动搜索 + 跳过（方案 §5.3(5)） */
  @Builder
  reviewBody() {
    Column() {
      if (this.reviewItem !== null) {
        Text(`第 ${this.reviewIndex + 1} / ${this.reviewQueue.length} 首`)
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
        Text(this.reviewItem.song.title)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 6 })
        if (this.reviewSongSubtitle(this.reviewItem).length > 0) {
          Text(this.reviewSongSubtitle(this.reviewItem))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 4 })
        }
        if (this.reviewItem.failReason.length > 0) {
          Text(this.reviewItem.failReason)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .margin({ top: 6 })
        }
        if (this.reviewItem.candidates.length > 0) {
          // ⚠️ 自定义组件带尾随构建块时不能链式挂属性（`InsetCard() {...}.margin()` 会
          // 被解析成两条语句 → 编译报错），故用外层 Row 承载上间距。
          Row() {
            InsetCard() {
              Column() {
                ForEach(this.reviewItem.candidates, (c: Track, index: number): void => {
                  if (index > 0) {
                    CardDivider()
                  }
                  Row() {
                    Column() {
                      Text(c.title)
                        .fontSize(14)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(this.candidateSubtitle(c))
                        .fontSize(11)
                        .fontColor($r('app.color.text_tertiary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 3 })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    // 触达铁律：视觉可以小，命中区必须 ≥ 44vp
                    Row() {
                      Text('选它')
                        .fontSize(13)
                        .fontColor(this.themePrimary)
                    }
                    .height(44)
                    .padding({ left: 12, right: 12 })
                    .justifyContent(FlexAlign.Center)
                    .onClick((): void => {
                      this.pickCandidate(c);
                    })
                  }
                  .width('100%')
                  .padding({ top: 10, bottom: 10 })
                  .alignItems(VerticalAlign.Center)
                }, (c: Track): string => c.bvid)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 4 })
            }
          }
          .width('100%')
          .margin({ top: 12 })
        } else {
          Text('还没有候选，换个关键词搜搜看')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .margin({ top: 12 })
        }
        // 换个关键词搜（路线 C：匹配不 100% 时的必要兜底，不允许黑盒）
        Row() {
          TextInput({ text: this.manualKeyword, placeholder: '换个关键词，如「歌名 现场」' })
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .placeholderFont({ size: 13 })
            .backgroundColor($r('app.color.bg_page'))
            .height(44)
            .borderRadius(12)
            .layoutWeight(1)
            .onChange((v: string): void => {
              this.manualKeyword = v;
            })
          Button(this.manualSearching ? '搜索中…' : '搜索', { type: ButtonType.Normal })
            .fontSize(14)
            .height(44)
            .padding({ left: 16, right: 16 })
            .borderRadius(BUTTON_RADIUS_VP)
            .backgroundColor(this.themePrimary)
            .fontColor(this.themeOn)
            .attributeModifier(this.buttonMaterial)
            .enabled(!this.manualSearching)
            .margin({ left: 10 })
            .onClick((): void => {
              this.manualSearch();
            })
        }
        .width('100%')
        .margin({ top: 12 })
        .alignItems(VerticalAlign.Center)
        Button('跳过这首', { type: ButtonType.Normal })
          .fontSize(13)
          .height(40)
          .width('100%')
          .borderRadius(BUTTON_RADIUS_VP)
          .backgroundColor($r('app.color.bg_card'))
          .fontColor($r('app.color.text_primary'))
          .margin({ top: 10 })
          .onClick((): void => {
            this.skipReviewItem();
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 16, bottom: 8 })
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Column() {
          List({ scroller: this.scroller }) {
            // 顶部空白占位条目（下载页同款）：列表视口铺满全屏，条目起始位置在屏幕
            // 顶端（y=0）。占位高度 = safeTop + 标题行 56，首个真实条目恰从栏底起排，
            // 滚动时占位与条目一起从沉浸材质下方穿过。
            ListItem() {
              // Blank 只能嵌在 Row/Column/Flex 内（编译器 10905201），ListItem 直下用定高 Row。
              Row()
                .width('100%')
                .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)
            }
            if (this.pagePhase === PagePhase.INPUT) {
              ListItem() {
                SectionHeader({ headerText: '粘贴内容' })
              }
              ListItem() {
                InsetCard() {
                  this.inputBody()
                }
              }
              ListItem() {
                Column() {
                  Button(this.recognizing ? '识别中…' : '识别', { type: ButtonType.Normal })
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .height(44)
                    .width('100%')
                    .borderRadius(BUTTON_RADIUS_VP)
                    .backgroundColor(this.themePrimary)
                    .fontColor(this.themeOn)
                    .attributeModifier(this.buttonMaterial)
                    .enabled(!this.recognizing)
                    .opacity(this.recognizing ? 0.5 : 1)
                    .onClick((): void => {
                      this.recognize();
                    })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 4 })
              }
              ListItem() {
                SectionFooter({
                  noteText: '支持网易云歌单链接与一行一首的歌曲列表；QQ 音乐建议直接复制歌曲列表文本。导入后播放的仍是 B 站音源'
                })
              }
            } else if (this.pagePhase === PagePhase.PREVIEW) {
              ListItem() {
                SectionHeader({ headerText: '识别结果' })
              }
              ListItem() {
                InsetCard() {
                  this.previewBody()
                }
              }
              ListItem() {
                Column() {
                  Button('开始匹配', { type: ButtonType.Normal })
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .height(44)
                    .width('100%')
                    .borderRadius(BUTTON_RADIUS_VP)
                    .backgroundColor(this.themePrimary)
                    .fontColor(this.themeOn)
                    .attributeModifier(this.buttonMaterial)
                    .onClick((): void => {
                      this.startMatching();
                    })
                  Button('返回修改', { type: ButtonType.Normal })
                    .fontSize(13)
                    .height(40)
                    .width('100%')
                    .borderRadius(BUTTON_RADIUS_VP)
                    .backgroundColor($r('app.color.bg_card'))
                    .fontColor($r('app.color.text_primary'))
                    .margin({ top: 10 })
                    .onClick((): void => {
                      this.pagePhase = PagePhase.INPUT;
                    })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 4 })
              }
              ListItem() {
                SectionFooter({
                  noteText: '匹配会逐首搜索 B 站并按相似度打分，每首约 1 秒多；期间可以离开本页'
                })
              }
            } else if (this.pagePhase === PagePhase.MATCHING) {
              ListItem() {
                this.matchingBody()
              }
              ListItem() {
                Column() {
                  Button('中断', { type: ButtonType.Normal })
                    .fontSize(13)
                    .height(40)
                    .width('100%')
                    .borderRadius(BUTTON_RADIUS_VP)
                    .backgroundColor($r('app.color.bg_card'))
                    .fontColor($r('app.color.text_primary'))
                    .onClick((): void => {
                      this.confirmStop();
                    })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 4, bottom: 4 })
              }
            } else if (this.pagePhase === PagePhase.REPORT) {
              ListItem() {
                this.reportBody()
              }
            } else {
              ListItem() {
                this.reviewBody()
              }
            }
            ListItem() {
              Row()
                .width('100%')
                .height(this.safeBottom + 16)
            }
          }
          .layoutWeight(1)
          .width('100%')
          .edgeEffect(EdgeEffect.Spring)
          // 标题栏让位已内移为首个 ListItem 占位（见 List 首项），不在 List 上加 padding。
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
      }
    }
    // HDS 沉浸光感标题栏（FavSyncPage / FollowsPage 同款）：
    // avoidLayoutSafeArea 挡状态栏重叠；enableComponentSafeArea 会杀材质，禁用。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(IMPORT_BLUR_START_VP, IMPORT_BLUR_END_VP),
      content: {
        stackBuilder: (): void => {
          this.pageBar();
        }
      }
    })
    // 双返回键修复（2026-10-22）：隐藏 HDS 默认返回键，只保留 stackBuilder 自绘键
    // （默认键与自绘键在标题栏左上角重叠，两个 chevron 重影、按压效果错乱）
    .hideBackButton(true)
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页列表交给 HDS 联动
    .bindToScrollable([this.scroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 内容避让：目的地级声明布局扩展进系统安全区（官方组件级沉浸口径）；
    // 内容层避让由顶部占位条目 / 尾部安全区占位自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets，2026-10-17 启动优化）：
 * Index 已不再静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function PlaylistImportPageBuilder(): void {
  PlaylistImportPage()
}


/** 懒加载注册表预包装（2026-10-17）：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const PlaylistImportPageWrapped: WrappedBuilder<[]> = wrapBuilder(PlaylistImportPageBuilder);

