/**
 * 播放设置页（按类别分五张分组卡片，SectionHeader 标类别）：
 *   · 播放：自动播放下一首 / 启动时自动播放 / 与其他应用同时播放 / 淡入淡出（SelectDialog 弹窗）
 *   · 播放页入口：倍速播放 / 在 B 站打开原视频 / 定时停止入口 / 限定播放进度入口 / 进入 UP 主页入口 / 单曲音量入口
 *   · 锁屏卡片：定时停止默认档位（SelectDialog 弹窗）
 *   · 桌面歌词：总开关（AVSession 系统歌词组件）/ 锁定位置（系统组件能力）
 *   · 网络与音源：仅 WiFi 播放 / 播放音质（SelectDialog 弹窗）/ 播放线路（SelectDialog 弹窗）
 *
 * （1.3.6 起不再设「记录与定时」分组：累计听歌由拾音页周期时长覆盖，
 *  最近播放经首页快捷卡进入，定时停止归播放页功能行的定时 chip 管理。）
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，AboutPage 同款骨架）：
 * 材质由 HDS 统一渲染，滚动渐变模糊由自绘 TopGradientBlurOverlay 承担
 * （AppearanceSettingsPage 同款），内容用 stackBuilder 承载标题；侧滑返回是
 * Navigation 级能力，不受影响。
 */

import {
  CONTENT_END_OFFSET,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_PLAYBACK_SPEED_ENABLED,
  STORE_PLAYBACK_SPEED,
  STORE_AUDIO_MIX_ENABLED,
  STORE_OPEN_IN_BILI_ENABLED,
  STORE_SLEEP_TIMER_ENTRY_ENABLED,
  STORE_SKIP_INTRO_ENTRY_ENABLED,
  STORE_UP_SPACE_ENTRY_ENABLED,
  STORE_TRACK_VOLUME_ENTRY_ENABLED,
  STORE_CHAPTERS_ENTRY_ENABLED,
  STORE_DESC_ENTRY_ENABLED,
  STORE_THEME_PRIMARY
} from '../common/Constants';
import {
  AppSettings,
  DEFAULT_APP_SETTINGS
} from '../model/MusicModels';
import { DesktopLyricController } from '../service/DesktopLyricController';
import { BarNarrowShell } from '../components/BarNarrowShell';
import { AppPreferences } from '../preferences/AppPreferences';
import { MusicPlayer } from '../player/MusicPlayer';
import { NavStackHolder } from '../service/NavStackHolder';
import { SelectDialog } from '@kit.ArkUI';
import { showAppToast } from '../components/AppToast';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { TwoColumnLayout } from '../common/utils/TwoColumnList';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { InsetCard, CardDivider, SectionHeader } from '../components/InsetCardGroup';
import { HdsListItemCard, SuffixSwitch, SuffixArrowIconText } from '@kit.UIDesignKit';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { CDN_LINE_OPTIONS, CdnLineOption, cdnLineLabelOf } from '../utils/CdnLine';
import { QUALITY_OPTIONS, QualityOption, SLEEP_OPTIONS, formatSleepMinutes, FADE_DURATION_OPTIONS, FadeDurationOption, fadeDurationLabelOf } from '../utils/SettingsShared';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';

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
  /** 锁屏卡片定时档位弹窗（SelectDialog，同播放线路弹窗的「每次打开重建 controller」口径） */
  private lockCardSleepDialog: CustomDialogController | null = null;
  /** 淡入淡出档位弹窗（SelectDialog，同播放音质弹窗的「每次打开重建 controller」口径） */
  private fadeDurationDialog: CustomDialogController | null = null;
  /** 滚动控制器：bindToScrollable 绑给 HDS 标题栏，滚动模糊效果依赖此绑定 */
  private pageScroller: Scroller = new Scroller();

  /** 自绘顶栏渐变模糊层进度更新器（AboutPage 同款命令式驱动，高频回调零重建） */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.pageScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  /** 子页转场的横移量（相对页面自身宽度）：转场代理里按 push/pop 方向临时改写 */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    // 挂载前先存当前偏移对应的进度（updater 未挂载只存值，挂载时 initializeModifier 补上）
    this.syncTopBlurProgress();
    // 偏好读取（getSettings 是 getSync 同步 IO）延后一拍，首帧 build 全程零磁盘读。
    setTimeout((): void => {
      this.settings = AppPreferences.getSettings();
    }, 0);
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
   * 选中淡入淡出档位。只写偏好 —— 播放内核每次过渡开始时就近读取
   *（AppPreferences 内存缓存），下一次切歌 / 暂停 / 恢复立即生效，
   * 正在进行的过渡不受影响。
   */
  private pickFadeDuration(ms: number): void {
    this.update((s: AppSettings): void => {
      s.fadeDurationMs = ms;
    });
    this.toast(`淡入淡出：${fadeDurationLabelOf(ms)}`, 1500);
  }

  /**
   * 打开淡入淡出档位弹窗（SelectDialog，单选列表 + 取消）。
   * 选中态按当前偏好预选；点选项即生效（写偏好 + toast）并关闭弹窗。
   */
  private openFadeDurationDialog(): void {
    const current: number = this.settings.fadeDurationMs;
    const items: SheetInfo[] = [];
    let selectedIndex: number = -1;
    for (let i = 0; i < FADE_DURATION_OPTIONS.length; i++) {
      const opt: FadeDurationOption = FADE_DURATION_OPTIONS[i];
      if (opt.ms === current) {
        selectedIndex = i;
      }
      items.push({
        title: opt.label,
        action: (): void => {
          this.pickFadeDuration(opt.ms);
          this.fadeDurationDialog?.close();
        }
      });
    }
    const dialog: CustomDialogController = new CustomDialogController({
      builder: SelectDialog({
        title: '淡入淡出',
        content: '切歌与暂停/恢复时的音量过渡时长；来电等系统打断始终立即停止',
        selectedIndex: selectedIndex,
        confirm: {
          value: '取消',
          // 同播放音质弹窗：confirm.action 会替换默认关闭行为，必须显式 close
          action: (): void => {
            this.fadeDurationDialog?.close();
          }
        },
        radioContent: items
      }),
      autoCancel: true
    });
    this.fadeDurationDialog = dialog;
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

  /** 选中锁屏卡片定时停止默认档位（写 AppSettings.lockCardSleepMinutes，下一轮 chip 开启生效） */
  private pickLockCardSleepMinutes(minutes: number): void {
    this.update((s: AppSettings): void => {
      s.lockCardSleepMinutes = minutes;
    });
    this.toast(`锁屏卡片定时档位：${formatSleepMinutes(minutes)}`, 1500);
  }

  /**
   * 打开锁屏卡片定时档位弹窗（SelectDialog，单选列表 + 取消）。
   * 选中态按当前偏好预选；点选项即生效（写偏好 + toast）并关闭弹窗。
   * 档位是锁屏 / 桌面「定时停止卡片」chip 在**未开启**定时时的默认时长；
   * 已开启的定时不受影响（chip 再点一下即取消）。
   */
  private openLockCardSleepDialog(): void {
    const current: number = this.settings.lockCardSleepMinutes;
    const items: SheetInfo[] = [];
    let selectedIndex: number = -1;
    for (let i = 0; i < SLEEP_OPTIONS.length; i++) {
      const minutes: number = SLEEP_OPTIONS[i];
      if (minutes === current) {
        selectedIndex = i;
      }
      items.push({
        title: formatSleepMinutes(minutes),
        action: (): void => {
          this.pickLockCardSleepMinutes(minutes);
          this.lockCardSleepDialog?.close();
        }
      });
    }
    const dialog: CustomDialogController = new CustomDialogController({
      builder: SelectDialog({
        title: '定时停止默认档位',
        content: '「定时停止卡片」chip 在未开启定时时的默认时长；开启后再点 chip 即取消',
        selectedIndex: selectedIndex,
        confirm: {
          value: '取消',
          // 同播放音质弹窗：confirm.action 会替换默认关闭行为，必须显式 close
          action: (): void => {
            this.lockCardSleepDialog?.close();
          }
        },
        radioContent: items
      }),
      autoCancel: true
    });
    this.lockCardSleepDialog = dialog;
    dialog.open();
  }

  // ===== 桌面歌词（AVSession 系统歌词组件，样式由系统统一渲染） =====

  /**
   * 桌面歌词总开关翻转。开 = 先探测系统歌词组件能力，再 enable + 显示；
   * 成功才落盘 + 镜像，失败（设备不支持 / 系统异常）开关视觉回弹并提示。
   * 关 = 隐藏系统歌词组件 + 落盘。
   */
  private toggleFloatLyric(on: boolean): void {
    const controller: DesktopLyricController = DesktopLyricController.getInstance();
    if (!on) {
      controller.setEnabled(false, this.settings.floatLyricLocked).then((ok: boolean): void => {
        if (!ok) {
          this.toast('桌面歌词关闭失败，请稍后重试', 2000);
          return;
        }
        // 控制器已落盘：重读快照刷新开关视觉（@State 不会自动同步 Preferences）
        this.settings = AppPreferences.getSettings();
      }).catch((): void => {
        this.toast('桌面歌词关闭异常，请稍后重试', 2000);
      });
      return;
    }
    // 翻转前值守卫（见「启动时自动播放」注释）：只有真的从关到开才走开启链
    if (this.settings.floatLyricEnabled) {
      return;
    }
    controller.isSupported().then(async (supported: boolean): Promise<void> => {
      if (!supported) {
        this.toast('当前设备/系统不支持桌面歌词组件', 2400);
        return;
      }
      const shown: boolean = await controller.setEnabled(true, this.settings.floatLyricLocked);
      if (!shown) {
        this.toast('桌面歌词开启失败，请确认正在播放音乐后重试', 2400);
        return;
      }
      this.settings = AppPreferences.getSettings();
      this.toast('已开启：歌词将由系统在桌面悬浮显示', 1800);
    }).catch((): void => {
      this.toast('桌面歌词开启异常，请稍后重试', 2000);
    });
  }

  /**
   * 锁定歌词组件翻转。锁定 = 系统歌词组件固定位置、禁止拖拽与设置面板
   * （样式由系统渲染，应用侧无字号/颜色自定义）。
   * 落盘 + 镜像 + 即时下发（组件未开启时只落盘，下次开启生效）。
   */
  private toggleFloatLyricLocked(on: boolean): void {
    DesktopLyricController.getInstance().setLocked(on).then((): void => {
      // 控制器已落盘：重读快照刷新开关视觉
      this.settings = AppPreferences.getSettings();
    }).catch((): void => {
      this.toast('锁定状态下发失败，请稍后重试', 2000);
    });
    if (on) {
      this.toast('已锁定：歌词组件位置固定、禁止拖动', 2200);
    }
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

  build() {
    HdsNavDestination() {
      Stack() {
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

            // 续播（默认开）：开启后切歌/新播放从「上次听到」记忆位置续播；
            // 关闭后一律从头起播（「限定播放进度·跳过片头」仍生效）。
            // 门禁单点收口在 MusicPlayer.rememberedStartSec —— 所有起播路径
            //（next/prev 切歌、队列/列表点播、最近播放续播入口）都经它取记忆位置。
            // 位置记录不受影响，重新打开开关续播立即恢复。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '续播' },
                secondaryText: { text: '切歌和新播放从上次听到的位置继续' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.resumeFromProgress,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  // 翻转前值守卫（见「启动时自动播放」注释）：进页 isCheck 翻转
                  // 会让 SuffixSwitch 误触发 onChange，真切换才提示
                  const turningOn: boolean = v && !this.settings.resumeFromProgress;
                  const turningOff: boolean = !v && this.settings.resumeFromProgress;
                  this.update((s: AppSettings): void => {
                    s.resumeFromProgress = v;
                  });
                  if (turningOn) {
                    this.toast('已开启：切歌和新播放将从上次听到的位置继续', 1800);
                  }
                  if (turningOff) {
                    this.toast('已关闭：切歌和新播放将从头开始', 1500);
                  }
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

            // 淡入淡出：切歌旧曲淡出/新曲淡入、暂停淡出/恢复淡出的音量过渡时长
            //（SelectDialog 档位弹窗；关 = 现状瞬切，仅保留首播一次性 800ms 淡入）。
            // 播放内核每次过渡开始时就近读偏好，改完下一次过渡立即生效；
            // 来电等系统打断不淡出（立即停）。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '淡入淡出' }
              },
              suffixItem: new SuffixArrowIconText({
                text: { text: fadeDurationLabelOf(this.settings.fadeDurationMs) },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openFadeDurationDialog();
              }
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
            // 仍会到点暂停；定时状态与关闭经播放页 chip（活跃时显倒计时，
            // 菜单含「关闭定时」）随时可查可关。
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

            // 单曲音量入口：开启后播放页功能行出现按曲「单曲音量」调节入口
            //（ControlAreaComponent 的 VolumeChip：喇叭图标 / 百分比文字片，
            // 点击弹就近气泡滑条 0-100% 实时生效，系数按曲存 TrackVolumeStore）。
            // 关闭只隐藏入口 —— 已存的按曲音量系数不受影响，仍继续生效。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '单曲音量入口' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.trackVolumeEntryEnabled,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  // 进页不再弹提示：翻转前值守卫（见「启动时自动播放」注释）
                  const turningOn: boolean = v && !this.settings.trackVolumeEntryEnabled;
                  this.update((s: AppSettings): void => {
                    s.trackVolumeEntryEnabled = v;
                  });
                  AppStorage.setOrCreate(STORE_TRACK_VOLUME_ENTRY_ENABLED, v);
                  if (turningOn) {
                    this.toast('已开启：播放页可按曲调节音量', 1500);
                  }
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 分段列表入口：开启后播放页功能行出现「分段列表」入口
            //（ControlAreaComponent：x/player/wbi/v2 的 view_points 章节数据，
            // 点击弹章节列表 seek 跳转；四款进度条同时画分段刻度）。
            // 无分段视频点击后弹层展示空态；关闭只隐藏入口，章节数据不受影响。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '分段列表入口' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.chaptersEntryEnabled,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  // 进页不再弹提示：翻转前值守卫（见「启动时自动播放」注释）
                  const turningOn: boolean = v && !this.settings.chaptersEntryEnabled;
                  this.update((s: AppSettings): void => {
                    s.chaptersEntryEnabled = v;
                  });
                  AppStorage.setOrCreate(STORE_CHAPTERS_ENTRY_ENABLED, v);
                  if (turningOn) {
                    this.toast('已开启：播放页可查看分段列表', 1500);
                  }
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 视频简介入口：开启后播放页功能行出现「视频简介」入口
            //（ControlAreaComponent，点击弹半模态弹层 —— 上半视频简介
            //（getVideoDetail 的 desc，长文可展开）、下半置顶评论
            //（无置顶回落热门首评，/x/v2/reply/wbi/main））。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '视频简介入口' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.descEntryEnabled,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  // 进页不再弹提示：翻转前值守卫（见「启动时自动播放」注释）
                  const turningOn: boolean = v && !this.settings.descEntryEnabled;
                  this.update((s: AppSettings): void => {
                    s.descEntryEnabled = v;
                  });
                  AppStorage.setOrCreate(STORE_DESC_ENTRY_ENABLED, v);
                  if (turningOn) {
                    this.toast('已开启：播放页可查看视频简介', 1500);
                  }
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 自定义功能栏：播放页功能行 12 个功能项整体排序 —— 前 4 位为默认页
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
          SectionHeader({ headerText: '锁屏卡片' })
        }

        ListItem() {
          InsetCard() {
            // 「定时停止卡片」（1×2，锁屏卡片 renderingMode=autoColor）chip 的
            // 默认定时档位：未开启定时点 chip 按此档开启（活跃时点 chip 取消、
            // 显「HH:mm 停」）。档位五选一（SelectDialog），写
            // AppSettings.lockCardSleepMinutes 跨进程供卡片 call 链读取。
            // 说明：上锁屏需在 AGC 申请「锁屏卡片」开放能力并通过审核（手动
            // 签名），审批前卡片可先添加到桌面验证交互，审批通过后零改动上锁屏。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '定时停止默认档位' },
                secondaryText: { text: '「定时停止卡片」chip 未开启定时时的默认时长；卡片当前可添加到桌面，上锁屏需 AGC 开放能力审核通过' }
              },
              suffixItem: new SuffixArrowIconText({
                text: { text: formatSleepMinutes(this.settings.lockCardSleepMinutes) },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openLockCardSleepDialog();
              }
            })
          }
        }

        ListItem() {
          SectionHeader({ headerText: '桌面歌词' })
        }

        ListItem() {
          InsetCard() {
            // 桌面歌词总开关：开启后接入系统「歌词组件」（AVSession Kit，
            // API 23+），由系统在桌面悬浮渲染歌词（内容 = AVMetadata.lyric
            // 标准 LRC，样式由系统统一管理，无需悬浮窗权限）。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '桌面歌词' },
                secondaryText: { text: '由系统在桌面悬浮显示当前播放歌词（需系统支持歌词组件；样式由系统管理）' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.floatLyricEnabled,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  this.toggleFloatLyric(v);
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            // 锁定歌词组件：锁定后固定位置、禁止拖拽与设置面板（系统能力）。
            HdsListItemCard({
              textItem: {
                primaryText: { text: '锁定歌词位置' },
                secondaryText: { text: '锁定后歌词组件固定位置、禁止拖动；需解锁时回到本开关' }
              },
              suffixItem: new SuffixSwitch({
                isCheck: this.settings.floatLyricLocked,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  this.toggleFloatLyricLocked(v);
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
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
      // 自绘渐变模糊层驱动：逐帧更新 + 停止校准终态（渐变软边由 overlay 承担）
      .onDidScroll((xOffset: number, yOffset: number): void => {
        this.syncTopBlurProgress();
      })
      .onScrollStop((): void => {
        this.syncTopBlurProgress();
      })

      // 顶栏渐变模糊层：盖 List 内容之上（z 序低于 HDS titleBar），进度命令式驱动
      TopGradientBlurOverlay({
        barHeightVp: this.safeTop + NAV_TITLE_BAR_HEIGHT,
        updater: this.topBlurUpdater
      })
      }
    }
    // HDS 沉浸光感标题栏：材质 / 滚动模糊 / 温控统一由 HdsTitleBarStyle 决策
    //（HDS 内置滚动效果关闭：渐变模糊由自绘 TopGradientBlurOverlay 承担，防双重模糊）
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
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
