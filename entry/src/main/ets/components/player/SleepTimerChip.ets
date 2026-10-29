/**
 * 定时停止播放快捷入口（播放页功能行左组，「定时停止入口」开关控制显隐）。
 *
 * 双态渲染：
 *   · 未开启定时 —— 时钟图标按钮（bindMenu 快捷档位：10 分钟 ~ 2 小时）；
 *   · 已开启 —— 倒计时文字片（倍速片同款样式，每秒走字，bindMenu 可改档 /
 *     「关闭定时」）。
 *
 * 架构约定（PlayerProgressArea 同款）：倒计时每秒刷新的 @State 圈死在本组件
 * 子树内 —— 订阅挂到 ControlAreaComponent 上会导致整个控制区每秒重渲染一次。
 * 页面收起 → 本组件卸载 → ticker 清理；内核定时器归 MusicPlayer 单例持有，
 * 卸载不影响已设置的定时，重挂按 STORE_SLEEP_TIMER_END 现算恢复倒计时。
 *
 * bindMenu 铁律（「加入歌单」按钮注释同源）：菜单必须挂在点击落点的最深层
 * 节点 —— 本组件的 Column 无内部可点子节点，外层直挂即可；按压反馈用
 * onTouch 缩放（只回写状态不消费事件，不与菜单手势竞争）。
 */

import { MusicPlayer } from '../../player/MusicPlayer';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { BreakpointType } from '../../common/utils/BreakpointSystem';
import { STORE_SLEEP_TIMER_END } from '../../common/Constants';
import { SLEEP_OPTIONS, formatSleepMinutes, formatRemain } from '../../utils/SettingsShared';
import { PRESS_ANIM_MS, PRESS_SCALE } from '../../common/constants/InteractionConstants';

/** 功能键图标与圆底尺寸（与 ControlAreaComponent 的 FUNC_* 保持一致：该处为模块私有不可跨文件引用） */
const FUNC_ICON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 22, md: 22, lg: 26 });
const FUNC_BUTTON_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 40, md: 40, lg: 46 });
/** 倒计时文字字号（缩进 40×40 等宽槽位；最长文案 "2:00:00" 靠 minFontSize 自适应缩字兜底） */
const COUNTDOWN_FONT_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 14, md: 14, lg: 15 });
const COUNTDOWN_MIN_FONT_SIZE: BreakpointType<number> = new BreakpointType<number>({ sm: 9, md: 9, lg: 10 });

@Component
export struct SleepTimerChip {
  /** 当前断点（Index 常驻注册写入）：图标 / 文字片尺寸取值用 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 定时到点时间戳（ms，MusicPlayer.setSleepTimer 写入；0 = 未开启） */
  @StorageLink(STORE_SLEEP_TIMER_END) @Watch('onEndChanged') sleepTimerEnd: number = 0;
  /** 倒计时文案（空串 = 未开启态，显示图标）；每秒由 ticker 重算，重渲染圈死在本组件 */
  @State remainText: string = '';
  /** 按压反馈缩放（onTouch 驱动，不消费事件，与 bindMenu 共存） */
  @State pressScale: number = 1;
  /** 倒计时 1s 轮询句柄（-1 = 未启动；aboutToDisappear / 未开启态必清） */
  private ticker: number = -1;

  aboutToAppear(): void {
    this.refresh();
  }

  aboutToDisappear(): void {
    this.stopTicker();
  }

  /** 数据源变化（设置 / 取消 / 到点清零）：现算一次 + 按需起停 ticker */
  private onEndChanged(): void {
    this.refresh();
  }

  /** 刷新倒计时文案：未开启 / 已过期 → 图标态并停 ticker；活跃 → 文字片并起 ticker */
  private refresh(): void {
    const end: number = this.sleepTimerEnd;
    if (end <= 0 || end <= Date.now()) {
      this.remainText = '';
      this.stopTicker();
      return;
    }
    this.remainText = formatRemain(Math.ceil((end - Date.now()) / 1000));
    this.startTicker();
  }

  private startTicker(): void {
    if (this.ticker !== -1) {
      return;
    }
    this.ticker = setInterval((): void => {
      // 到点先本地停 ticker（store 清零由内核 setTimeout 负责，@Watch 幂等再刷一遍）
      this.refresh();
    }, 1000);
  }

  private stopTicker(): void {
    if (this.ticker !== -1) {
      clearInterval(this.ticker);
      this.ticker = -1;
    }
  }

  /** 快捷菜单：活跃时首项「关闭定时」，随后五个档位（toast 由 setSleepTimer 内置） */
  private sleepMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    if (this.remainText.length > 0) {
      items.push({
        value: '关闭定时',
        action: (): void => {
          MusicPlayer.getInstance().setSleepTimer(0);
        }
      });
    }
    for (const minutes of SLEEP_OPTIONS) {
      items.push({
        value: formatSleepMinutes(minutes),
        action: (): void => {
          MusicPlayer.getInstance().setSleepTimer(minutes);
        }
      });
    }
    return items;
  }

  build() {
    Column() {
      if (this.remainText.length > 0) {
        // 已开启：倒计时文字片 —— 与图标键等宽槽位（40×40），垂直居中到同一中线；
        // 最长文案 "2:00:00" 靠 minFontSize 自适应缩字兜底，不截断不溢出。
        Text(this.remainText)
          .fontSize(COUNTDOWN_FONT_SIZE.getValue(this.currentBreakpoint))
          .minFontSize(COUNTDOWN_MIN_FONT_SIZE.getValue(this.currentBreakpoint))
          .maxFontSize(COUNTDOWN_FONT_SIZE.getValue(this.currentBreakpoint))
          .width('100%')
          .maxLines(1)
          .textAlign(TextAlign.Center)
          .fontColor(Color.White)
          .opacity(0.86)
          .fontWeight(FontWeight.Medium)
      } else {
        // 未开启：功能行图标（线面，与模式 / 下载等入口一致）
        SymbolGlyph($r('sys.symbol.clock'))
          .fontSize(FUNC_ICON_SIZE.getValue(this.currentBreakpoint))
          .fontColor([Color.White])
          .opacity(0.86)
      }
    }
    .width(FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint))
    .height(FUNC_BUTTON_SIZE.getValue(this.currentBreakpoint))
    // 与功能行其他槽位统一「内容居中」对齐口径：所有键在同一条中线上（旧版顶部
    // 对齐是与当时的倍速片 / 跳过片约定配套的，重排后统一改为居中）。
    .justifyContent(FlexAlign.Center)
    .scale({ x: this.pressScale, y: this.pressScale })
    .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressScale = PRESS_SCALE;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressScale = 1;
      }
    })
    .bindMenu(this.sleepMenuItems())
    .accessibilityText('定时停止播放')
  }
}
