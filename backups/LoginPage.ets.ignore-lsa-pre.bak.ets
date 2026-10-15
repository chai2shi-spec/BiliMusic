/**
 * 扫码登录页（从设置页「账户」进入）。
 *
 * 流程：生成二维码（passport web 接口）→ 本地 QRCode 组件渲染 → 每 2s 轮询扫码状态
 * → 成功后 LoginStore 双通道提取登录 Cookie（回调 url 参数 / 响应 Set-Cookie 头）并持久化
 * → 自动返回设置页。
 *
 * 状态机（qrPhase）：
 *   loading（取二维码中）/ ready（等待扫码，86101）/ scanned（已扫码待确认，86090）
 *   / expired（86038，二维码约 180s 过期，点击蒙层刷新重新生成）
 *
 * 布局与转场复用 AboutPage 的模式：HDS 沉浸光感标题栏（HdsNavDestination.titleBar，
 * stackBuilder 承载返回行 + 标题，批 1 样板同款）、Stack 承载滚动内容 + 蒙层宿主、
 * customTransition 横移转场。
 * ⚠️ 轮询定时器必须在 aboutToDisappear 清掉，离开页面后不能继续轮询。
 */

import { STORE_SAFE_BOTTOM, STORE_SAFE_TOP, STORE_THEME_PRIMARY } from '../common/Constants';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NavStackHolder } from '../service/NavStackHolder';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { BusinessError } from '@ohos.base';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { showAppToast } from '../components/AppToast';
import {
  generateQrLogin,
  pollQrLogin,
  QrLoginTicket,
  QrPollResult
} from '../api/BilibiliApi';
import { applyQrSuccess, refreshLoginUser } from '../service/LoginStore';
import { HttpUtil } from '../utils/HttpUtil';

/** 轮询间隔（ms）：B 站网页版同款节奏，太快会被风控 */
const QR_POLL_INTERVAL_MS: number = 2000;

/** 顶栏滚动模糊时机（2026-10-09 全站定档）：滚动 0~30vp 完全透明 → 30~80vp 材质渐变 → >80vp 满强度 */
const LOGIN_BLUR_START_VP: number = 30;
const LOGIN_BLUR_END_VP: number = 80;

@Component
export struct LoginPage {
  /** 状态栏高度（vp）：内容区要整体落在状态栏下方，由本页自己顶下来 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  /** 底部安全区高度（vp）：内容末尾让开手势区 */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;

  /** 主题色主色：二维码刷新图标与提示文字跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 滚动控制器：bindToScrollable 绑给 HDS 标题栏，滚动模糊效果依赖此绑定 */
  private loginScroller: Scroller = new Scroller();
  /**
   * 子页转场的横移量（相对页面自身宽度）：常驻 '0%'，
   * 转场代理里按 push/pop 方向临时改写（见 navTransitionDelegate，与 AboutPage 同款）。
   */
  @State navTransX: string = '0%';

  /** 二维码内容（passport 下发的 url）；为空表示还没取到 */
  @State qrUrl: string = '';
  /** 扫码状态机：loading / ready / scanned / expired */
  @State qrPhase: string = 'loading';
  /** 状态文案：跟随 qrPhase 与轮询结果更新 */
  @State statusText: string = '正在获取二维码…';

  /** 轮询凭据（generateQrLogin 下发，poll 必带） */
  private qrcodeKey: string = '';
  private pollTimer: number = -1;
  /** 单次轮询进行中标记：防止慢响应叠帧轮询（上一发没回来又发下一发） */
  private polling: boolean = false;
  /** 二维码生成时刻（ms）：86038 时算存活时长，用于区分「自过期」与「扫码后被作废」 */
  private qrGeneratedAt: number = 0;

  aboutToAppear(): void {
    this.startQrLogin();
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  /** 重新生成二维码并开始新一轮轮询（首进页面 / 过期刷新共用） */
  private startQrLogin(): void {
    this.stopPolling();
    this.qrPhase = 'loading';
    this.statusText = '正在获取二维码…';
    generateQrLogin()
      .then((ticket: QrLoginTicket): void => {
        this.qrUrl = ticket.qrUrl;
        this.qrcodeKey = ticket.qrcodeKey;
        this.qrGeneratedAt = Date.now();
        this.qrPhase = 'ready';
        this.statusText = '请使用哔哩哔哩客户端扫码';
        this.startPolling();
      })
      .catch((e: BusinessError): void => {
        // 取二维码失败（断网等）：进入过期态，用户点击蒙层即可重试
        this.qrPhase = 'expired';
        this.statusText = `获取二维码失败：${e.message}`;
      });
  }

  private startPolling(): void {
    if (this.pollTimer !== -1) {
      return;
    }
    this.pollTimer = setInterval((): void => {
      this.pollOnce();
    }, QR_POLL_INTERVAL_MS);
  }

  private stopPolling(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private async pollOnce(): Promise<void> {
    if (this.polling || this.qrPhase === 'expired' || this.qrcodeKey.length === 0) {
      return;
    }
    this.polling = true;
    try {
      const result: QrPollResult = await pollQrLogin(this.qrcodeKey);
      if (result.status === 0) {
        // 成功：停轮询，落库后自动返回（后续刷新由 LoginStore 广播版本号驱动）
        this.stopPolling();
        await this.finishLogin(result.callbackUrl, result.responseCookies, result.refreshToken);
      } else if (result.status === 86090) {
        this.qrPhase = 'scanned';
        this.statusText = '已扫码，请在手机上确认';
      } else if (result.status === 86038) {
        this.stopPolling();
        // 存活时长是关键诊断信号：正常 ~180s；若只有几秒且从未出现 86090，
        // 说明 key 被服务端提前作废（而非超时）
        console.warn(`QR expired: aliveMs=${Date.now() - this.qrGeneratedAt}` +
          `, lastPhase=${this.qrPhase}`);
        this.qrPhase = 'expired';
        this.statusText = '二维码已过期';
      } else {
        // 86101 等待扫码；手机上取消确认后也会回到这里（从 scanned 退回 ready）
        this.qrPhase = 'ready';
        this.statusText = '请使用哔哩哔哩客户端扫码';
      }
    } catch (e) {
      // 单次轮询失败（瞬态断网）跳过本轮，下个周期再试；必须留痕（曾因静默吞错
      // 丢失 poll 失败的关键证据——HTTP 4xx/5xx 在 HttpUtil 里是先抛错后打日志的）
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.warn(`pollOnce failed: ${msg}`);
    } finally {
      this.polling = false;
    }
  }

  /** 扫码成功落库：解析 Cookie → 持久化 → 刷新用户信息 → toast + 返回 */
  private async finishLogin(callbackUrl: string, responseCookies: string, refreshToken: string): Promise<void> {
    this.statusText = '登录成功';
    try {
      await applyQrSuccess(callbackUrl, responseCookies, refreshToken);
      await refreshLoginUser();
      showAppToast('登录成功', 1800);
      NavStackHolder.stack.pop();
    } catch (e) {
      // 落库失败（两条 Cookie 通道都没拿到身份字段 / 存储异常）：给刷新入口让用户重试。
      // 诊断日志只记长度与字段命中布尔，不输出凭据值。
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.error(`finishLogin failed: ${msg} ` +
        `(urlLen=${callbackUrl.length}, urlHasSessdata=${callbackUrl.indexOf('SESSDATA=') >= 0}, ` +
        `cookiesLen=${responseCookies.length}, cookiesHasSessdata=${responseCookies.indexOf('SESSDATA=') >= 0}, ` +
        `cookieKeys=[${HttpUtil.cookieKeys(responseCookies).join(', ')}])`);
      this.qrPhase = 'expired';
      this.statusText = '登录失败，点击二维码重试';
    }
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow EaseOut，与 AboutPage 同款。
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

  /** 标题栏内容（titleBar 的 stackBuilder 承载）：返回行 + 「登录 B 站」标题 */
  @Builder
  loginBar() {
    Row() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(26)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .borderRadius(22)
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.press_overlay')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .accessibilityText('返回')
      .accessibilityLevel('yes')
      .onClick((): void => {
        NavStackHolder.stack.pop();
      })

      Text('登录 B 站')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(NAV_TITLE_BAR_HEIGHT)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  /** 二维码本体 + 过期蒙层（loading 态显示进度圈） */
  @Builder
  qrArea() {
    Stack() {
      if (this.qrUrl.length > 0) {
        // 二维码必须白底黑码：bg_card 在深色主题下是深底，直接透出会扫不出来
        QRCode(this.qrUrl)
          .width(220)
          .height(220)
          .color(Color.Black)
          .backgroundColor(Color.White)
          .borderRadius(8)
          .clip(true)
      } else {
        Column() {
          LoadingProgress()
            .width(36)
            .height(36)
            .color(this.themePrimary)
        }
        .width(220)
        .height(220)
        .borderRadius(8)
        .backgroundColor(Color.White)
        .justifyContent(FlexAlign.Center)
      }

      if (this.qrPhase === 'expired') {
        // 过期蒙层：半透明盖住二维码，整块可点刷新
        Column() {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(28)
            .fontColor([this.themePrimary])
          Text('点击刷新')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.themePrimary)
            .margin({ top: 6 })
        }
        .width(220)
        .height(220)
        .borderRadius(8)
        .backgroundColor('#B3000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .accessibilityText('二维码已过期，点击刷新')
        .accessibilityLevel('yes')
        .onClick((): void => {
          this.startQrLogin();
        })
      }
    }
    .margin({ top: 18 })
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Scroll(this.loginScroller) {
          Column() {
            // ── 扫码卡片 ──
            Column() {
              Text('扫码登录')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .margin({ top: 22 })
              Text('登录后可解锁更高音质档位（杜比 / Hi-Res 需大会员）')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 6 })
              this.qrArea()
              Text(this.statusText)
                .fontSize(13)
                .fontColor(this.qrPhase === 'expired' ? this.themePrimary : $r('app.color.text_secondary'))
                .margin({ top: 16 })
              Text('二维码 3 分钟内有效，过期可刷新重试')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ top: 4, bottom: 22 })
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)
            .margin({ left: 12, right: 12, top: 10 })
            .alignItems(HorizontalAlign.Center)

            // ── 短信登录入口 ──
            Text('使用短信验证码登录')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.themePrimary)
              .padding({ top: 14, bottom: 14, left: 24, right: 24 })
              .margin({ top: 4 })
              .onClick((): void => {
                NavStackHolder.stack.pushPath({ name: 'SmsLogin' });
              })

            // ── 隐私说明 ──
            Column() {
              Text('登录凭据说明')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .padding({ left: 16, top: 14, bottom: 8 })
              Text('扫码登录只把 SESSDATA 等凭据保存在本机，用于请求 B 站接口，不上传到任何第三方服务器。不登录也可以正常使用搜索、播放与下载等匿名功能；退出登录即清除本机凭据。')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .lineHeight(18)
                .width('100%')
                .padding({ left: 16, right: 16, bottom: 16 })
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)
            .margin({ left: 12, right: 12, top: 10, bottom: 20 })
          }
          .width('100%')
        }
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        // 边界回弹（2026-10-08）：内容超屏可滚时，到顶/到底的反馈动效
        .edgeEffect(EdgeEffect.Spring)
        // 大屏适配：内容列收窄居中（与 AboutPage 同款）
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
        // 内容让位 HDS 标题栏：栏顶 = safeTop（avoidLayoutSafeArea）+ 栏高 56。
        // 放在内容 padding 上：滚动时内容仍从栏下穿过，HDS 沉浸材质才有内容可采样。
        .padding({ top: this.safeTop + NAV_TITLE_BAR_HEIGHT })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
      .safeAreaPadding({ bottom: this.safeBottom })
    }
    // HDS 沉浸光感标题栏（批 1 样板同款，真机结论见 AboutPage 注释）：
    // avoidLayoutSafeArea 挡状态栏重叠；enableComponentSafeArea 会杀材质，禁用。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(LOGIN_BLUR_START_VP, LOGIN_BLUR_END_VP),
      content: {
        stackBuilder: (): void => {
          this.loginBar();
        }
      }
    })
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页滚动容器交给 HDS 联动
    .bindToScrollable([this.loginScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
  }
}
