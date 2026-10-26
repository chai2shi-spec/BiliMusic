/**
 * 合集 / 系列详情页（路由名 SeasonSeriesDetail）。
 *
 * 从 UpSpacePage「合集 / 系列」页签的卡片点进来：分页浏览该合集（ugc_season，
 * season_id）/ 系列（series，UP 主手动列表）的全部投稿条目，支持条目点播、
 * 「⋯」菜单（加入队列 / 下载）、「播放全部」与「保存为歌单」。
 *
 * 数据来源（BilibiliApi，web-space 聚合物接口，wbi 签名）：
 *  · 合集 `getSeasonArchives`（x/polymer/web-space/seasons_archives_list，30 条/页）；
 *  · 系列 `getSeriesArchives`（x/polymer/web-space/series_archives_list，30 条/页）。
 *  ⚠️ 该域接口匿名风控强（-352/-412/HTTP 412），失败态带 4 秒冷却重试（UpSpacePage 同款）。
 *
 * 入参走路由参数 SeasonSeriesDetailRouteParam（kind / mid / itemId 必填，
 * title / cover / upName / upMid 为首帧与 Track 构建兜底），经
 * NavRouteParamReader.readSeasonSeriesDetailParam 判型读取。
 *
 * 布局与 UpSpacePage 同款口径：列表视口铺满全屏 + 首个空白占位 ListItem 让位
 * （标题栏 56 + 头部操作行 56），滚动时条目从沉浸材质下穿过，滚动模糊由
 * TopGradientBlurOverlay + onDidScroll/onScrollStop 命令式驱动。
 * 头部操作行（播放全部 / 保存为歌单）钉在 titleBar 的 bottomBuilder（固定高 56，
 * 无需实测自适应）。
 */

import * as BilibiliApi from '../api/BilibiliApi';
import { Track } from '../model/MusicModels';
import { LibraryStore } from '../service/LibraryStore';
import { DownloadManager, DownloadStartResult, WIFI_ONLY_BLOCKED } from '../service/DownloadManager';
import { currentNetworkLabel } from '../utils/NetworkUtil';
import { NavStackHolder } from '../service/NavStackHolder';
import { NavRouteParamReader } from '../service/NavRouteParams';
import { MusicPlayer } from '../player/MusicPlayer';
import { TrackItem } from '../components/TrackItem';
import { SkeletonTrackItem } from '../components/SkeletonTrackItem';
import { showAppToast } from '../components/AppToast';
import { showConfirm } from '../components/AppAlertDialog';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';
import { HdsNavDestination, BottomBuilderShowType } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { ButtonMaterialModifier, makeButtonMaterialModifier } from '../utils/HeaderBarMaterial';
import { CustomContentDialog } from '@kit.ArkUI';
import {
  CONTENT_END_OFFSET,
  STORE_SAFE_TOP,
  STORE_SAFE_BOTTOM,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE,
  STORE_THEME_ON
} from '../common/Constants';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { TwoColumnLayout } from '../common/utils/TwoColumnList';
import {
  NAV_TRANSITION_MS,
  BUTTON_RADIUS_VP,
  LIST_FOOTER_HEIGHT_VP
} from '../common/constants/InteractionConstants';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';

/** 每页条目数（web-space 聚合接口的 page_size 上限就是 30，再大也是确定性失败） */
const PAGE_SIZE: number = 30;
/** 失败后「重试」的冷却（ms）：web-space 域按 IP 限流，连点只会继续被拒（UpSpacePage 同口径） */
const RETRY_COOLDOWN_MS: number = 4000;
/** 头部操作行（bottomBuilder）固定高：32vp 按钮 + 上下各 12vp 呼吸空间 */
const ACTION_ROW_HEIGHT: number = 56;

@Component
export struct SeasonSeriesDetailPage {
  /** 'season'（B 站合集）/ 'series'（UP 主手动系列），决定条目分页接口 */
  @State kind: string = 'season';
  @State mid: string = '';
  @State itemId: string = '';
  @State headerTitle: string = '';
  @State upName: string = '';
  @State upMid: string = '';
  @State tracks: Track[] = [];
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State page: number = 1;
  @State hasMore: boolean = false;
  /** 服务端条目总数（page.total；0 = 未知，footer 文案降级） */
  @State total: number = 0;
  @State loadFailed: boolean = false;
  @State failReason: string = '';
  /** 重试冷却中：按钮禁用（真正的门在 retryLocked 成员，状态只是给用户看的） */
  @State retryCooling: boolean = false;
  /** 「保存为歌单」对话框里的歌单名（打开时预填合集/系列标题） */
  @State collectionName: string = '';
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;
  /** 子页转场横移量：常驻 '0%'，转场代理按 push/pop 临时改写 */
  @State navTransX: string = '0%';

  private listScroller: Scroller = new Scroller();
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();
  private retryLocked: boolean = false;
  private retryTimer: number = -1;
  private player: MusicPlayer = MusicPlayer.getInstance();
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 「保存为歌单」对话框（CustomContentDialog 标准对话框，标题/按钮常量建一次） */
  private collectionSaverController: CustomDialogController | undefined = undefined;

  /** 标题栏 + 头部操作行总让位量（vp）：列表占位条目与非列表分支共用 */
  private barTotalHeight(): number {
    return this.safeTop + NAV_TITLE_BAR_HEIGHT + ACTION_ROW_HEIGHT;
  }

  /** kind 的人话标签（空态 / 失败态文案用） */
  private kindLabel(): string {
    return this.kind === 'series' ? '系列' : '合集';
  }

  /**
   * 自绘顶栏渐变模糊层进度校准（全站同款）：yOffset 0 → TITLE_BLUR_END_VP
   * 线性映射 0 → 1（updater 内截断，未挂载按偏移 0）。
   */
  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.listScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  aboutToAppear(): void {
    this.syncTopBlurProgress();
    this.collectionSaverController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: '保存为歌单',
        contentBuilder: (): void => {
          this.SaverBody();
        },
        buttons: [
          {
            value: '取消',
            buttonStyle: ButtonStyleMode.TEXTUAL,
            action: (): void => {
              this.cancelSave();
            }
          },
          {
            value: '保存',
            buttonStyle: ButtonStyleMode.EMPHASIZED,
            action: (): void => {
              this.confirmSave();
            }
          }
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    const routeParam = NavRouteParamReader.readSeasonSeriesDetailParam(NavStackHolder.stack);
    if (routeParam === null || routeParam.itemId.length === 0 || routeParam.mid.length === 0) {
      this.loadFailed = true;
      this.failReason = '没有拿到合集信息，请返回重新进入';
      return;
    }
    this.kind = routeParam.kind;
    this.mid = routeParam.mid;
    this.itemId = routeParam.itemId;
    this.headerTitle = routeParam.title;
    this.upName = routeParam.upName;
    this.upMid = routeParam.upMid;
    this.loadPage(1);
  }

  aboutToDisappear(): void {
    // 定时器必须清：否则离开页面后回调仍会写状态
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  // ===== 数据加载 =====

  /** 单页请求分发：kind 决定走合集还是系列接口 */
  private fetchPage(pn: number): Promise<BilibiliApi.SeasonSeriesPage> {
    const midNum: number = Number(this.mid);
    const idNum: number = Number(this.itemId);
    if (this.kind === 'series') {
      return BilibiliApi.getSeriesArchives(midNum, idNum, this.upName, this.upMid, pn, PAGE_SIZE);
    }
    return BilibiliApi.getSeasonArchives(midNum, idNum, this.upName, this.upMid, pn, PAGE_SIZE);
  }

  /**
   * 拉一页条目。三重闸门（loading / loadingMore / 无更多）防短列表首帧布局
   * 连环触发（UpSpacePage.onReachEnd 同款纪律）。
   */
  private async loadPage(pn: number): Promise<void> {
    if (this.loading || this.loadingMore) {
      return;
    }
    if (pn === 1) {
      this.loading = true;
      try {
        const r: BilibiliApi.SeasonSeriesPage = await this.fetchPage(1);
        this.tracks = r.tracks;
        this.total = r.total;
        this.hasMore = r.hasMore && r.tracks.length > 0;
        this.page = 1;
        this.loadFailed = false;
        this.failReason = '';
      } catch (e) {
        const err: Error = e as Error;
        this.loadFailed = true;
        this.failReason = this.describeError(err);
      }
      this.loading = false;
      return;
    }
    if (!this.hasMore) {
      return;
    }
    this.loadingMore = true;
    try {
      const r: BilibiliApi.SeasonSeriesPage = await this.fetchPage(pn);
      // 翻页合并且按 id 去重：服务端分页抖动（插入/删除导致窗口位移）时
      // 宁可少展示重复条，也不让列表里出现两行同 id。
      const known: Set<string> = new Set<string>();
      for (let i = 0; i < this.tracks.length; i++) {
        known.add(this.tracks[i].id);
      }
      const merged: Track[] = this.tracks.slice();
      for (let i = 0; i < r.tracks.length; i++) {
        const t: Track = r.tracks[i];
        if (!known.has(t.id)) {
          merged.push(t);
          known.add(t.id);
        }
      }
      this.tracks = merged;
      this.total = r.total > 0 ? r.total : this.total;
      this.hasMore = r.hasMore;
      this.page = pn;
    } catch (e) {
      const err: Error = e as Error;
      console.error(`season series page ${pn} failed: ${err.message}`);
      // 翻页失败只降级 hasMore（footer 提示可重进），不打断已加载内容
      this.hasMore = false;
    }
    this.loadingMore = false;
  }

  /**
   * 把异常翻译成一句能直接决定动作的话（UpSpacePage.describeError 同款，
   * 仅默认文案随本页语境换词）。
   */
  private describeError(e: Error): string {
    const raw: string = e && e.message ? e.message : '';
    if (raw.length === 0) {
      return `${this.kindLabel()}加载失败`;
    }
    const matched: RegExpMatchArray | null = raw.match(/\[(-?\d+)\]\s*([^(\/]*)/);
    if (matched) {
      const code: string = matched[1];
      const msg: string = (matched[2] || '').trim();
      if (code === '-352' || code === '-509' || code === '-799') {
        return `B 站限制了当前访问（${code}${msg.length > 0 ? ' ' + msg : ''}），过一会儿再试`;
      }
      if (code === '-403') {
        return `请求被 B 站拒绝（${code}），签名或身份校验未通过`;
      }
      return `加载失败（${code}${msg.length > 0 ? ' ' + msg : ''}）`;
    }
    if (raw.indexOf('HTTP 412') >= 0) {
      return 'B 站拒绝了匿名访问（412），登录后重试通常可解';
    }
    if (raw.indexOf('HTTP') >= 0) {
      return raw;
    }
    return `加载失败：${raw.slice(0, 40)}`;
  }

  private onReachEnd(): void {
    if (this.loading || this.loadingMore || !this.hasMore) {
      return;
    }
    this.loadPage(this.page + 1);
  }

  /**
   * 失败后的重试：清干净状态重新拉第一页。4 秒冷却防风控连点
   * （UpSpacePage.retry 同款）。
   */
  private retry(): void {
    if (this.retryLocked) {
      return;
    }
    this.retryLocked = true;
    this.retryCooling = true;
    this.retryTimer = setTimeout((): void => {
      this.retryLocked = false;
      this.retryCooling = false;
    }, RETRY_COOLDOWN_MS);
    this.loadFailed = false;
    this.failReason = '';
    this.hasMore = false;
    this.page = 1;
    this.tracks = [];
    this.loadPage(1);
  }

  // ===== 曲目菜单（加入队列 / 下载） =====

  /** 「⋯」标准菜单项（bindMenu + MenuElement 数组） */
  private trackMenuItems(track: Track): MenuElement[] {
    return [
      {
        value: '加入队列',
        action: (): void => {
          this.player.addToQueue(track);
          showAppToast('已加入播放队列', 1500);
        }
      },
      {
        value: '下载',
        action: (): void => {
          this.requestDownload(track);
        }
      }
    ];
  }

  private requestDownload(track: Track): void {
    DownloadManager.getInstance().requestDownload(track, false)
      .then((r: DownloadStartResult): void => {
        if (r.blockedReason.length > 0) {
          this.confirmDownloadOnCellular(track);
          return;
        }
        const head: string = r.queued === 1 ? '已开始下载 1 首' : `已开始下载 ${r.queued} 首`;
        const tail: string = r.skipped > 0 ? `（另有 ${r.skipped} 首已在列表中）` : '';
        showAppToast(`${head}${tail}，可在「下载」页查看进度`, 2000);
      })
      .catch((e: Error): void => {
        console.error(`requestDownload failed: ${e.message}`);
        showAppToast('下载启动失败', 1800);
      });
  }

  /** 「仅 WiFi 下载」被触发：先问一句（UpSpacePage.confirmDownloadOnCellular 同款） */
  private confirmDownloadOnCellular(track: Track): void {
    showConfirm(this.getUIContext(), {
      title: '仅 WiFi 下载',
      message: `${WIFI_ONLY_BLOCKED}\n当前网络：${currentNetworkLabel()}`,
      confirmText: '继续下载',
      onConfirm: (): void => {
        DownloadManager.getInstance().requestDownload(track, true)
          .then((r: DownloadStartResult): void => {
            showAppToast(r.queued > 0 ? `已开始下载 ${r.queued} 首` : '没有可下载的曲目', 1800);
          })
          .catch((e: Error): void => {
            console.error(`requestDownload(ignoreWifiLimit) failed: ${e.message}`);
            showAppToast('下载启动失败', 1800);
          });
      }
    });
  }

  // ===== 保存为歌单 =====

  /** 打开「保存为歌单」对话框：把当前已加载条目整单存成歌单（名称预填标题） */
  private openSaveDialog(): void {
    if (this.tracks.length === 0) {
      showAppToast(`该${this.kindLabel()}还没有可保存的条目`, 1500);
      return;
    }
    this.collectionName = this.headerTitle;
    this.collectionSaverController?.open();
  }

  /** 对话框「保存」：按用户输入的名字建歌单（空名回退「UP 名 + 的合集」） */
  private confirmSave(): void {
    const list: Track[] = this.tracks;
    if (list.length === 0) {
      return;
    }
    const input: string = this.collectionName.trim();
    const fallback: string = this.upName.length > 0 ? `${this.upName} 的${this.kindLabel()}` : `${this.kindLabel()}歌单`;
    const name: string = input.length > 0 ? input : fallback;
    const created = LibraryStore.createPlaylist({
      name: name,
      coverUrl: list[0].coverUrl
    });
    created.tracks = list;
    LibraryStore.updatePlaylist(created);
    showAppToast(`已保存歌单「${name}」，共 ${list.length} 首`, 2000);
  }

  private cancelSave(): void {
    // collectionName 打开时会重写，无需清暂存
  }

  /** 「保存为歌单」对话框内容区：条目数说明 + 名称输入 */
  @Builder
  SaverBody(): void {
    Column() {
      Text(`共 ${this.tracks.length} 个视频`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      TextInput({ placeholder: '输入歌单名称', text: this.collectionName })
        .width('100%')
        .height(44)
        // 字阶只用六档（24/20/18/16/13/11），15 属于禁用档
        .fontSize(16)
        .onChange((v: string): void => {
          this.collectionName = v;
        })
    }
    .width('100%')
  }

  // ===== 转场与标题栏 =====

  /**
   * 子页转场：从右滑入 slow(400ms) EaseOut，pop 反向（RecentPage / UpSpacePage 同款）。
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
      return [enter];
    }
    if (op === NavigationOperation.POP && !isEnter) {
      const exit: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '100%';
        }
      };
      return [exit];
    }
    return undefined;
  }

  /** 标题行（titleBar 的 stackBuilder 承载）：合集/系列标题，返回键为 HDS 默认键 */
  @Builder
  detailBar(): void {
    NavTitleRow({ title: this.headerTitle })
  }

  /** 标题行收窄容器（平板模式宽度适配，UpSpacePage.upSpaceBarNarrow 同款） */
  @Builder
  detailBarNarrow(): void {
    Row() {
      Column() {
        this.detailBar()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * 头部操作行（titleBar 的 bottomBuilder 承载）：播放全部 + 保存为歌单。
   * 固定高 56（按钮 32 + 上下呼吸 12），无需 UpSpacePage 的实测自适应机制。
   */
  @Builder
  actionRow(): void {
    Row({ space: 8 }) {
      Button('播放全部', { type: ButtonType.Normal })
        .fontSize(13)
        .height(32)
        .borderRadius(BUTTON_RADIUS_VP)
        .padding({ left: 16, right: 16 })
        .backgroundColor(this.themeSurface)
        .fontColor(this.themePrimary)
        .attributeModifier(this.buttonMaterial)
        .onClick((): void => {
          if (this.tracks.length === 0) {
            showAppToast(`该${this.kindLabel()}还没有可播放的条目`, 1500);
            return;
          }
          this.player.playAll(this.tracks);
        })
      Button('保存为歌单', { type: ButtonType.Normal })
        .fontSize(13)
        .height(32)
        .borderRadius(BUTTON_RADIUS_VP)
        .padding({ left: 16, right: 16 })
        .backgroundColor(this.themeSurface)
        .fontColor(this.themePrimary)
        .attributeModifier(this.buttonMaterial)
        .onClick((): void => {
          this.openSaveDialog();
        })
    }
    .width('100%')
    .height(ACTION_ROW_HEIGHT)
    .padding({ left: 20, right: 20 })
    .alignItems(VerticalAlign.Center)
  }

  /** 头部操作行收窄容器（detailBarNarrow 同口径） */
  @Builder
  actionRowNarrow(): void {
    Row() {
      Column() {
        this.actionRow()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 单列条目行（与 UpSpacePage.SingleTrackRow 同款，无多选态） */
  @Builder
  TrackRow(t: Track, index: number): void {
    TrackItem({
      track: t,
      entranceIndex: index,
      onPlay: (tr: Track): void => {
        this.player.playOrToggle(tr);
      },
      moreMenuItems: (tr: Track): MenuElement[] => this.trackMenuItems(tr)
    })
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Column() {
          if (this.loading && this.tracks.length === 0) {
            // 首屏骨架：同款条目占位，不用「转圈 + 加载中」
            Column() {
              ForEach([0, 1, 2, 3, 4], (_i: number): void => {
                SkeletonTrackItem({ index: _i })
              }, (_i: number): string => `ssd_skel_${_i}`)
            }
            .width('100%')
            // 非列表分支没有占位条目，自己补让位（标题栏 + 操作行总让位量）
            .padding({ top: this.barTotalHeight() })
          } else if (this.loadFailed && this.tracks.length === 0) {
            Column() {
              Text(`${this.kindLabel()}加载失败`)
                .fontColor($r('app.color.text_secondary'))
                .fontSize(16)
              Text(this.failReason.length > 0 ? this.failReason : '检查网络后再试一次')
                .fontColor($r('app.color.text_tertiary'))
                .fontSize(13)
                .textAlign(TextAlign.Center)
                .padding({ left: 24, right: 24 })
                .margin({ top: 8 })
              Row() {
                Row() {
                  Button(this.retryCooling ? '稍等 4 秒' : '重试', { type: ButtonType.Normal })
                    .fontSize(13)
                    .height(32)
                    .borderRadius(BUTTON_RADIUS_VP)
                    .padding({ left: 18, right: 18 })
                    .backgroundColor(this.themePrimary)
                    .fontColor(this.themeOn)
                    .enabled(!this.retryCooling && !this.loading)
                    .onClick((): void => {
                      this.retry();
                    })
                }
                .height(44)
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
              }
              .margin({ top: 12 })
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: this.barTotalHeight() })
          } else if (this.tracks.length === 0) {
            Column() {
              Text(`该${this.kindLabel()}还没有视频`)
                .fontColor($r('app.color.text_secondary'))
                .fontSize(16)
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: this.barTotalHeight() })
          } else {
            List({ scroller: this.listScroller }) {
              // 顶部空白占位条目（下载页 / UpSpacePage 同款）：列表视口铺满全屏，
              // 占位高度 = 标题栏 + 头部操作行总让位量，首个真实条目恰从栏底起排。
              ListItem() {
                Row()
                  .width('100%')
                  .height(this.barTotalHeight())
              }
              ForEach(
                this.tracks,
                (t: Track, index: number): void => {
                  ListItem() {
                    this.TrackRow(t, index)
                  }
                },
                (t: Track): string => t.id
              )
              // 加载更多状态条（常驻 + 固定高度）：只换内容不插拔条目。
              ListItem() {
                Row() {
                  if (this.loadingMore) {
                    LoadingProgress()
                      .width(18)
                      .height(18)
                      .color($r('app.color.text_tertiary'))
                    Text('加载中…')
                      .fontSize(12)
                      .fontColor($r('app.color.text_tertiary'))
                      .margin({ left: 8 })
                  } else if (this.hasMore) {
                    Text('上拉加载更多')
                      .fontSize(13)
                      .fontColor($r('app.color.text_tertiary'))
                  } else if (this.total > 0) {
                    Text(`共 ${this.total} 个视频`)
                      .fontSize(13)
                      .fontColor($r('app.color.text_tertiary'))
                  } else {
                    Text('已全部加载')
                      .fontSize(13)
                      .fontColor($r('app.color.text_tertiary'))
                  }
                }
                .width('100%')
                .height(LIST_FOOTER_HEIGHT_VP)
                .justifyContent(FlexAlign.Center)
              }
            }
            .width('100%')
            .height('100%')
            // 裁剪放开：列表内容要能画进标题栏区域，材质/模糊才有可采样的源
            .clip(false)
            .edgeEffect(EdgeEffect.Spring)
            .cachedCount(8)
            .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
            .onReachEnd((): void => {
              this.onReachEnd();
            })
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
        .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })

        // 顶栏渐变模糊层：盖内容列之上（z 序低于 HDS titleBar），进度由列表
        // onDidScroll/onScrollStop 经 topBlurUpdater 命令式驱动。
        TopGradientBlurOverlay({
          barHeightVp: this.barTotalHeight(),
          updater: this.topBlurUpdater
        })
      }
    }
    // HDS 沉浸光感标题栏：标题行 + 头部操作行（bottomBuilder 固定高 56）。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        stackBuilder: (): void => {
          this.detailBarNarrow();
        },
        bottomBuilder: {
          builder: (): void => {
            this.actionRowNarrow();
          },
          height: ACTION_ROW_HEIGHT,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        }
      }
    })
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页列表交给 HDS 联动
    .bindToScrollable([this.listScroller])
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让：目的地级声明布局扩展进系统安全区（UpSpacePage 同口径）
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function SeasonSeriesDetailPageBuilder(): void {
  SeasonSeriesDetailPage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接 @Builder 引用（编译期校验）。 */
export const SeasonSeriesDetailPageWrapped: WrappedBuilder<[]> = wrapBuilder(SeasonSeriesDetailPageBuilder);
