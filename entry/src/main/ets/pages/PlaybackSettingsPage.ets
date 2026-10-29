/**
 * 播放设置页（按类别分四张分组卡片，SectionHeader 标类别）：
 *   · 播放：自动播放下一首 / 启动时自动播放 / 与其他应用同时播放 / 响度均衡（实验性）
 *   · 播放页入口：倍速播放 / 在 B 站打开原视频 / 定时停止入口 / 限定播放进度入口 / 进入 UP 主页入口
 *   · 网络与音源：仅 WiFi 播放 / 播放音质（SelectDialog 弹窗）/ 播放线路（SelectDialog 弹窗）
 *   · 记录与定时：累计听歌 / 最近播放 / 定时停止播放（bindSheet 半屏面板）
 *
 * 定时停止的轮询门控：本页是 NavDestination 子页，aboutToAppear /
 * aboutToDisappear 天然括起可见性 —— 进页起 ticker（定时活跃时）、离页必停。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，AboutPage 同款骨架）：
 * 材质与滚动模糊由 HDS 统一渲染，内容用 stackBuilder 承载标题；侧滑返回是
 * Navigation 级能力，不受影响。
 */

import {
  CONTENT_END_OFFSET,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_SLEEP_TIMER_END,
  STORE_LIBRARY_REV,
  STORE_PLAYBACK_SPEED_ENABLED,
  STORE_PLAYBACK_SPEED,
  STORE_AUDIO_MIX_ENABLED,
  STORE_LOUDNESS_NORM_ENABLED,
  STORE_OPEN_IN_BILI_ENABLED,
  STORE_SLEEP_TIMER_ENTRY_ENABLED,
  STORE_SKIP_INTRO_ENTRY_ENABLED,
  STORE_UP_SPACE_ENTRY_ENABLED,
  STORE_THEME_PRIMARY,
  STORE_THEME_DEEP
} from '../common/Constants';
import { AppSettings, DEFAULT_APP_SETTINGS } from '../model/MusicModels';
import { BarNarrowShell } from '../components/BarNarrowShell';
import { AppPreferences } from '../preferences/AppPreferences';
import { MusicPlayer } from '../player/MusicPlayer';
import { NavStackHolder } from '../service/NavStackHolder';
import { LibraryStore } from '../service/LibraryStore';
import { SelectDialog } from '@kit.ArkUI';
import { showAppToast } from '../components/AppToast';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { TwoColumnLayout } from '../common/utils/TwoColumnList';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { InsetCard, CardDivider, SectionHeader } from '../components/InsetCardGroup';
import { HdsListItemCard, SuffixSwitch, SuffixText, SuffixArrowIconText } from '@kit.UIDesignKit';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { CDN_LINE_OPTIONS, CdnLineOption, cdnLineLabelOf } from '../utils/CdnLine';
import {
  QUALITY_OPTIONS,
  QualityOption,
  SLEEP_OPTIONS,
  formatSleepMinutes,
  formatRemain,
  formatListenDuration
} from '../utils/SettingsShared';

@Component
export struct PlaybackSettingsPage {
  /** 状态栏高度（vp）：HDS 标题栏 avoidLayoutSafeArea 后栏顶 = safeTop，内容让位量要含它 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：内容末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 当前横竖屏（Index 常驻注册写入）：内容列 840 口径取值用 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;
  /**
   * 设置快照。首帧零磁盘读：先默认值占位，aboutToAppear 延后一拍读真值；
   * 开关写入走 AppPreferences.updateSettings（从持久层真值起步，不存在
   * 「默认值被当真值覆盖写盘」的风险）。
   */
  @State settings: AppSettings = DEFAULT_APP_SETTINGS;
  /** 品牌色（开关选中色）：EntryAbility 发布、外观页选色 / 切深浅重发布 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /** 品牌深色变体（定时面板「关闭定时」可用态文字色） */
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  /**
   * 定时停止的到点时间戳（ms），0 = 未开启。
   * 播放内核只发布这个**结束时刻**，剩余量由本页本地 1s 现算，避免每秒写一次 AppStorage。
   */
  @StorageLink(STORE_SLEEP_TIMER_END) @Watch('onSleepTimerChanged') sleepTimerEnd: number = 0;
  @State sleepRemainText: string = '未开启';
  /** 底部半屏面板开关（本页只有定时停止一种面板） */
  @State showSheet: boolean = false;
  /** 累计听歌时长文案：进页时读一次偏好（计时在 MusicPlayer，播放中不实时刷新） */
  @State listenText: string = '';
  /** 最近播放条数：@Watch(onLibraryChanged) 刷新（播放一首歌 / 清空历史都会 bump） */
  @State recentCount: number = 0;
  /**
   * 媒体库版本号（LibraryStore 写入）：「最近播放」行的条数副文案靠它刷新。
   */
  @StorageLink(STORE_LIBRARY_REV) @Watch('onLibraryChanged') libraryRev: number = 0;
  /**
   * 播放音质选择弹窗（SelectDialog 单选列表 + 取消）。
   * SelectDialog 的 selectedIndex / radioContent 是构造时定格的（CustomDialog
   * 参数不支持动态刷新，faqs-arkui-555），而音质随时可能被上一次选择改掉 ——
   * 所以每次打开前按当前值重建 controller，保证选中态新鲜。
   * 「controller 不得重新赋值」针对「旧弹窗还开着就换引用」的复用场景；
   * 本弹窗是模态的，重新赋值只发生在行点击时 —— 那一刻弹窗必然已关。
   */
  private playQualityDialog: CustomDialogController | null = null;
  /** 播放线路选择弹窗（SelectDialog，同播放音质弹窗的「每次打开重建 controller」口径） */
  private cdnLineDialog: CustomDialogController | null = null;
  private sleepTicker: number = -1;
  /** 滚动控制器：bindToScrollable 绑给 HDS 标题栏，滚动模糊效果依赖此绑定 */
  private pageScroller: Scroller = new Scroller();

  /** 子页转场的横移量（相对页面自身宽度）：转场代理里按 push/pop 方向临时改写 */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    this.refreshSleepText();
    // 偏好读取（getSettings / getTotalListenSeconds 都是 getSync 同步 IO）延后一拍，
    // 首帧 build 全程零磁盘读。
    setTimeout((): void => {
      this.settings = AppPreferences.getSettings();
      this.listenText = formatListenDuration(AppPreferences.getTotalListenSeconds());
      this.recentCount = LibraryStore.getRecentTracks().length;
    }, 0);
  }

  aboutToDisappear(): void {
    this.stopSleepTicker();
  }

  /** 媒体库变化（LibraryStore 广播版本号）：刷新「最近播放」行的条数副文案 */
  onLibraryChanged(): void {
    this.recentCount = LibraryStore.getRecentTracks().length;
  }

  /**
   * 统一写偏好（读持久层真值 → 改 → 写 → 返回新快照）：
   * this.settings 直接接住返回值，UI 即时刷新。
   */
  private update(mut: (s: AppSettings) => void): void {
    this.settings = AppPreferences.updateSettings(mut);
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  onSleepTimerChanged(): void {
    this.refreshSleepText();
  }

  private refreshSleepText(): void {
    if (this.sleepTimerEnd <= 0) {
      this.sleepRemainText = '未开启';
      this.stopSleepTicker();
      return;
    }
    const remainMs: number = this.sleepTimerEnd - Date.now();
    if (remainMs <= 0) {
      this.sleepRemainText = '未开启';
      this.stopSleepTicker();
      return;
    }
    this.sleepRemainText = `剩余 ${formatRemain(Math.ceil(remainMs / 1000))}`;
    this.startSleepTicker();
  }

  private startSleepTicker(): void {
    if (this.sleepTicker !== -1) {
      return;
    }
    this.sleepTicker = setInterval((): void => {
      this.refreshSleepText();
    }, 1000);
  }

  private stopSleepTicker(): void {
    if (this.sleepTicker !== -1) {
      clearInterval(this.sleepTicker);
      this.sleepTicker = -1;
    }
  }

  private pickSleep(minutes: number): void {
    this.showSheet = false;
    // 计时器归播放内核单例持有：换页 / 重建本组件都不会丢定时
    MusicPlayer.getInstance().setSleepTimer(minutes);
    // 兜底刷新：取消定时时写入的 0 可能与旧值相同，@Watch 不会触发
    setTimeout((): void => {
      this.refreshSleepText();
    }, 0);
  }

  /**
   * 选中播放音质。只写偏好 —— 真正的取流档位由播放内核在每次任务开始时读取，
   * 所以**已在进行中的任务不会中途换档**（换档需要重新解析音源），
   * 要生效得重新播放。
   */
  private pickQuality(value: string): void {
    this.update((s: AppSettings): void => {
      s.playQuality = value;
    });
    this.toast(`播放音质：${value}`, 1500);
  }

  /**
   * 打开播放音质弹窗（SelectDialog，单选列表 + 取消）。
   * 选中态按当前偏好预选；点选项即生效（写偏好 + toast）并关闭弹窗，
   * 取消按钮 / 点遮罩只关闭不改动。
   */
  private openPlayQualityDialog(): void {
    const current: string = this.settings.playQuality;
    const items: SheetInfo[] = [];
    let selectedIndex: number = -1;
    for (let i = 0; i < QUALITY_OPTIONS.length; i++) {
      const opt: QualityOption = QUALITY_OPTIONS[i];
      if (opt.value === current) {
        selectedIndex = i;
      }
      items.push({
        title: `${opt.value} · ${opt.short}`,
        action: (): void => {
          this.pickQuality(opt.value);
          this.playQualityDialog?.close();
        }
      });
    }
    const dialog: CustomDialogController = new CustomDialogController({
      builder: SelectDialog({
        title: '播放音质',
        content: '在线播放时优先选哪一档；服务端没有该档会自动降级，播放中的歌曲下一首生效。Hi-Res / 杜比需登录（大会员）',
        selectedIndex: selectedIndex,
        confirm: {
          value: '取消',
          // ⚠️ 显式 close，不依赖组件内部关闭：真机实测
          // confirm 提供空 action 时点击无效果（弹窗不关）——SelectDialog 的
          // confirm.action 会替换而非追加默认关闭行为。
          action: (): void => {
            this.playQualityDialog?.close();
          }
        },
        radioContent: items
      }),
      autoCancel: true
    });
    this.playQualityDialog = dialog;
    dialog.open();
  }

  /**
   * 选中播放线路。只写偏好 —— 线路在音源组装时（BilibiliApi 的 resolveAudioSelection
   * 收口）施加，播放中的歌曲不强制重载，下一首生效。
   * 任何选择（含切回「自动」）都清空上一次自动探测的命中结果：旧探测值对新选择
   * 没有参考意义，「自动」重新从失败探测起步。
   */
  private pickCdnLine(id: string): void {
    this.update((s: AppSettings): void => {
      s.playCdnLine = id;
      s.autoPickedCdnLine = '';
    });
    this.toast(`播放线路：${cdnLineLabelOf(id)}，下一首生效`, 1800);
  }

  /**
   * 打开播放线路弹窗（SelectDialog，单选列表 + 取消）。
   * 选中态按当前偏好预选；点选项即生效（写偏好 + toast）并关闭弹窗。
   */
  private openCdnLineDialog(): void {
    const current: string = this.settings.playCdnLine;
    const items: SheetInfo[] = [];
    let selectedIndex: number = -1;
    for (let i = 0; i < CDN_LINE_OPTIONS.length; i++) {
      const opt: CdnLineOption = CDN_LINE_OPTIONS[i];
      if (opt.id === current) {
        selectedIndex = i;
      }
      items.push({
        title: opt.label,
        action: (): void => {
          this.pickCdnLine(opt.id);
          this.cdnLineDialog?.close();
        }
      });
    }
    const dialog: CustomDialogController = new CustomDialogController({
      builder: SelectDialog({
        title: '播放线路',
        content: '在线音源的 CDN 线路。海外或部分网络播放失败时可尝试切换，下一首生效；「自动」会在失败时自动探测可用线路',
        selectedIndex: selectedIndex,
        confirm: {
          value: '取消',
          // 同播放音质弹窗：confirm.action 会替换默认关闭行为，必须显式 close
          action: (): void => {
            this.cdnLineDialog?.close();
          }
        },
        radioContent: items
      }),
      autoCancel: true
    });
    this.cdnLineDialog = dialog;
    dialog.open();
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut（AboutPage 同款）。
   * · push 入场：先把页面挪到屏幕右侧外（'100%'），event 闭包内回到 '0%'；
   * · pop 出场（含侧滑返回手势触发的返回）：反向滑回右侧，与手势方向一致；
   * · 其余场景返回 undefined，走系统默认转场。
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

  /** 标题栏内容（titleBar 的 stackBuilder 承载）：「播放设置」标题（返回键为 HDS 默认键） */
  @Builder
  playBar() {
    NavTitleRow({ title: '播放设置' })
  }

  /** 标题行收窄容器（BarNarrowShell 共用件，平板模式宽度适配） */
  @Builder
  playBarNarrow() {
    BarNarrowShell({ bar: (): void => {
      this.playBar()
    } })
  }

  /** 定时停止半屏面板：档位列表 + 「关闭定时」行 */
  @Builder
  SleepSheetContent(): void {
    Column() {
      Text('定时停止播放')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text(this.sleepTimerEnd > 0 ? `当前：${this.sleepRemainText}` : '当前未开启定时')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 4 })

      Column() {
        ForEach(SLEEP_OPTIONS, (minutes: number): void => {
          Row() {
            Text(formatSleepMinutes(minutes))
              .fontSize(16)
              .fontColor($r('app.color.text_primary'))
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 14, bottom: 14 })
          .onClick((): void => {
            this.pickSleep(minutes);
          })
        }, (minutes: number): string => `sleep_${minutes}`)
      }
      .width('100%')
      .margin({ top: 10 })

      Divider()
        .color($r('app.color.bg_divider'))

      Row() {
        Text('关闭定时')
          .fontSize(16)
          .fontColor(this.sleepTimerEnd > 0 ? this.themeDeep : $r('app.color.text_disabled'))
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 14, bottom: 14 })
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.press_overlay')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .onClick((): void => {
        if (this.sleepTimerEnd > 0) {
          this.pickSleep(0);
        }
      })
    }
    .width('100%')
    .padding({ top: 16, bottom: 12 })
  }

  build() {
    HdsNavDestination() {
      List({ scroller: this.pageScroller }) {
        // 顶部空白占位条目（官方沉浸口径）：高度 = safeTop + 56（MINI 标题栏），
        // 静止位首个真实条目恰从栏底起排，滚动时从材质下方穿过。
        ListItem() {
          Row()
            .width('100%')
            .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)
        }

        ListItem() {
          SectionHeader({ headerText: '播放' })
        }

        ListItem() {
          InsetCard() {
            HdsListItemCard({
              textItem: { primaryText: { text: '自动播放下一首' } },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.autoPlay,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  this.update((s: AppSettings): void => {
                    s.autoPlay = v;
                  });
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 启动时自动播放：冷启动从上次播放的曲目/进度续播（走 MusicPlayer.play()
            // 消费 restoreState 登记的 pendingResumePosition）。默认关 —— 无交互不出声。
            HdsListItemCard({
              textItem: { primaryText: { text: '启动时自动播放' } },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.autoPlayOnStart,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  // 进页不弹提示：settings 延后一拍读真值时
                  // isCheck 翻转会让 SuffixSwitch 误触发 onChange —— 用翻转前值
                  // 守卫，只有值真的从关翻到开才提醒；误触发时 v 与持久值一致被拦下。
                  const turningOn: boolean = v && !this.settings.autoPlayOnStart;
                  this.update((s: AppSettings): void => {
                    s.autoPlayOnStart = v;
                  });
                  if (turningOn) {
                    this.toast('已开启：启动应用时将从上次播放的曲目继续', 1800);
                  }
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 与其他应用同时播放：开启后激活 AudioSession 并声明
            // CONCURRENCY_MIX_WITH_OTHERS —— 本应用与其他应用的音频双向混音
            // （不抢占对方、也不被打断）；关闭停用会话，恢复系统默认焦点行为
            // （会被打断并自动暂停）。运行中切换对当前这一首 best-effort，
            // 每次切歌重建播放器前都会重新对账（loadAndPlay 开头），下一首必生效。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '与其他应用同时播放' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.audioMixEnabled,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  // 进页不再弹提示：翻转前值守卫（见「启动时自动播放」注释）
                  const turningOn: boolean = v && !this.settings.audioMixEnabled;
                  this.update((s: AppSettings): void => {
                    s.audioMixEnabled = v;
                  });
                  AppStorage.setOrCreate(STORE_AUDIO_MIX_ENABLED, v);
                  MusicPlayer.getInstance().setAudioMixEnabled(v);
                  if (turningOn) {
                    this.toast('已开启：与其他应用音频共存播放', 1500);
                  }
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 响度均衡（实验性）：开启后播放偏响的歌自动衰减到 B 站目标响度
            // （playurl 的 volume 数据，只衰减不放大，偏小的歌保持原样）。
            // 记录随在线解析 / 下载累积（LoudnessStore 按 musicId 存），未记录
            // 的曲目不受影响。切换立即作用于当前曲目（setLoudnessNormalization-
            // Enabled），换源重建后由 prepared 挂点重补。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '响度均衡（实验性）' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.loudnessNormalizationEnabled,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  // 翻转前值守卫：isCheck 翻转会让 SuffixSwitch 误触发 onChange
                  // （见「启动时自动播放」注释），真切换才镜像 + 即时生效。
                  const turningOn: boolean = v && !this.settings.loudnessNormalizationEnabled;
                  this.update((s: AppSettings): void => {
                    s.loudnessNormalizationEnabled = v;
                  });
                  AppStorage.setOrCreate(STORE_LOUDNESS_NORM_ENABLED, v);
                  MusicPlayer.getInstance().setLoudnessNormalizationEnabled(v);
                  if (turningOn) {
                    this.toast('已开启：偏响的歌曲将自动衰减到统一响度', 1800);
                  }
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })
          }
        }

        ListItem() {
          SectionHeader({ headerText: '播放页入口' })
        }

        ListItem() {
          InsetCard() {
            // 倍速播放总开关：开启后播放页功能行出现倍速入口（ControlAreaComponent）。
            // 关闭时立即恢复 1.0x —— update 一次写两个字段（含 playbackSpeed=1.0），
            // 运行时归位走 setPlaybackSpeed(1.0, false)（persist=false：偏好已由
            // update 写好，双写会因 put 未落内存产生读-改-写覆盖竞态）。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '倍速播放' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.speedEnabled,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  // 进页不再弹提示：翻转前值守卫（见「启动时自动播放」注释）
                  const turningOn: boolean = v && !this.settings.speedEnabled;
                  this.update((s: AppSettings): void => {
                    s.speedEnabled = v;
                    if (!v) {
                      s.playbackSpeed = 1.0;
                    }
                  });
                  AppStorage.setOrCreate(STORE_PLAYBACK_SPEED_ENABLED, v);
                  if (!v) {
                    AppStorage.setOrCreate(STORE_PLAYBACK_SPEED, 1.0);
                    MusicPlayer.getInstance().setPlaybackSpeed(1.0, false);
                  }
                  if (turningOn) {
                    this.toast('已开启：播放页可选择倍速', 1500);
                  }
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 在 B 站打开原视频：开启后播放页功能行右组出现跳转入口
            //（ControlAreaComponent），点击经 bilibili:// 深链拉官方 App，
            // 未装/不支持时降级 https 网页打开原视频（分P 精确到 ?p=N）。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '在 B 站打开原视频' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.openInBilibiliEnabled,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  // 进页不再弹提示：翻转前值守卫（见「启动时自动播放」注释）
                  const turningOn: boolean = v && !this.settings.openInBilibiliEnabled;
                  this.update((s: AppSettings): void => {
                    s.openInBilibiliEnabled = v;
                  });
                  AppStorage.setOrCreate(STORE_OPEN_IN_BILI_ENABLED, v);
                  if (turningOn) {
                    this.toast('已开启：播放页可跳转 B 站原视频', 1500);
                  }
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 定时停止入口：开启后播放页功能行出现定时停止快捷入口
            //（ControlAreaComponent 的 SleepTimerChip：未开启定时显时钟图标、
            // 已开启显倒计时）。关闭只隐藏入口 —— 已设置的定时不受影响，
            // 仍会到点暂停，下方「定时停止播放」面板随时可查可关。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '定时停止入口' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.sleepTimerEntryEnabled,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  // 进页不再弹提示：翻转前值守卫（见「启动时自动播放」注释）
                  const turningOn: boolean = v && !this.settings.sleepTimerEntryEnabled;
                  this.update((s: AppSettings): void => {
                    s.sleepTimerEntryEnabled = v;
                  });
                  AppStorage.setOrCreate(STORE_SLEEP_TIMER_ENTRY_ENABLED, v);
                  if (turningOn) {
                    this.toast('已开启：播放页可快捷定时停止', 1500);
                  }
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 限定播放进度入口：开启后播放页功能行出现按曲「限定播放进度」设置入口
            //（ControlAreaComponent 文本片 + 双滑块区间条弹窗，片头/片尾秒数存
            // IntroSkipStore）。关闭只隐藏入口 —— 已存的按曲限定秒数不受影响，仍继续生效。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '限定播放进度入口' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.skipIntroEntryEnabled,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  // 进页不再弹提示：翻转前值守卫（见「启动时自动播放」注释）
                  const turningOn: boolean = v && !this.settings.skipIntroEntryEnabled;
                  this.update((s: AppSettings): void => {
                    s.skipIntroEntryEnabled = v;
                  });
                  AppStorage.setOrCreate(STORE_SKIP_INTRO_ENTRY_ENABLED, v);
                  if (turningOn) {
                    this.toast('已开启：播放页可按曲限定播放进度', 1500);
                  }
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 进入 UP 主页入口：开启后播放页功能行出现「进入 UP 主页」跳转入口
            //（ControlAreaComponent，点击收起播放页 overlay 并跳转当前曲 UP 的
            // 站内主页 UpSpacePage；mid 缺失时经 getVideoDetail 解析）。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '进入 UP 主页入口' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.upSpaceEntryEnabled,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  // 进页不再弹提示：翻转前值守卫（见「启动时自动播放」注释）
                  const turningOn: boolean = v && !this.settings.upSpaceEntryEnabled;
                  this.update((s: AppSettings): void => {
                    s.upSpaceEntryEnabled = v;
                  });
                  AppStorage.setOrCreate(STORE_UP_SPACE_ENTRY_ENABLED, v);
                  if (turningOn) {
                    this.toast('已开启：播放页可进入 UP 主页', 1500);
                  }
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 自定义功能栏：播放页功能行 9 个功能项整体排序 —— 前 4 位为默认页
            // 图标，其余经左右滑动分页切换查看；进「自定义功能栏」页长按拖动
            // 调整顺序（PlayerFuncOrderPage，AppSettings.funcItemOrder 持久化）。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '自定义功能栏' }
              },
              suffixItem: new SuffixArrowIconText({
                text: { text: '前 4 位默认显示' },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                NavStackHolder.stack.pushPath({ name: 'PlayerFuncOrder' });
              }
            })
          }
        }

        ListItem() {
          SectionHeader({ headerText: '网络与音源' })
        }

        ListItem() {
          InsetCard() {
            HdsListItemCard({
              textItem: { primaryText: { text: '仅 WiFi 播放' } },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.wifiOnlyPlay,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  // 进页不再弹提示：翻转前值守卫（见「启动时自动播放」注释）
                  const turningOn: boolean = v && !this.settings.wifiOnlyPlay;
                  this.update((s: AppSettings): void => {
                    s.wifiOnlyPlay = v;
                  });
                  if (turningOn) {
                    this.toast('已开启：移动网络下将不播放在线歌曲', 1800);
                  }
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 播放音质：控制的是在线播放的音源档位；Hi-Res / 杜比需登录（大会员）。
            HdsListItemCard({
              textItem: { primaryText: { text: '播放音质' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: this.settings.playQuality },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openPlayQualityDialog();
              }
            })

            CardDivider()

            // 播放线路：在线音源的 CDN 直链 host（upos 镜像家族）。
            // 海外网络对默认 host 不可达时整首歌「能搜不能播」，这里可手动切换
            // 镜像线路；「自动」模式播放失败时自动探测可用线路（utils/CdnLine.ts）。
            HdsListItemCard({
              textItem: { primaryText: { text: '播放线路' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: cdnLineLabelOf(this.settings.playCdnLine) },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openCdnLineDialog();
              }
            })
          }
        }

        ListItem() {
          SectionHeader({ headerText: '记录与定时' })
        }

        ListItem() {
          InsetCard() {
            HdsListItemCard({
              textItem: { primaryText: { text: '累计听歌' } },
              suffixItem: new SuffixText({ text: this.listenText }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 最近播放：播放历史本就是播放行为，入口归位播放组；
            // 条数在右侧值位显示，点击进「最近播放」页。
            HdsListItemCard({
              textItem: { primaryText: { text: '最近播放' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: this.recentCount > 0 ? `${this.recentCount} 首` : '' },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                NavStackHolder.stack.pushPath({ name: 'Recent' });
              }
            })

            CardDivider()

            // 定时停止播放：点击弹半屏档位面板，剩余时间实时走字（本页可见时 1s 轮询）。
            HdsListItemCard({
              textItem: { primaryText: { text: '定时停止播放' } },
              suffixItem: new SuffixText({ text: this.sleepRemainText }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.showSheet = true;
              }
            })
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
      // 边界回弹：到顶/到底的反馈动效
      .edgeEffect(EdgeEffect.Spring)
      .cachedCount(10)
      // 底部让位：列表末尾可滚动至手势区上方，不被遮挡
      .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
      // 大屏适配：内容列收窄居中（走 TwoColumnLayout.contentMaxWidth）
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
    }
    // HDS 沉浸光感标题栏：材质 / 滚动模糊 / 温控统一由 HdsTitleBarStyle 决策
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(),
      content: {
        // 箭头包裹保证 builder 内 this 指向本组件（裸引用会丢失 this）
        stackBuilder: (): void => {
          this.playBarNarrow();
        }
      }
    })
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页滚动容器交给 HDS 联动
    .bindToScrollable([this.pageScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 系统返回拦截（播放页 overlay 打开时吞掉返回，否则走默认 pop）
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让（官方组件级沉浸口径，AboutPage 同款）；内容层避让由 plain padding 自理
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindSheet($$this.showSheet, this.SleepSheetContent(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false
    })
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 经动态 import 后用 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function PlaybackSettingsPageBuilder(): void {
  PlaybackSettingsPage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接 @Builder 引用（编译期校验）。 */
export const PlaybackSettingsPageWrapped: WrappedBuilder<[]> = wrapBuilder(PlaybackSettingsPageBuilder);
