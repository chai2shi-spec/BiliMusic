/**
 * 登录页（扫码 + 短信验证码合并，2026-10-20 由两个独立路由合并为一页两页签）。
 *
 * 顶部滑块（CapsuleSegmentButtonV2，与观看历史页「观看历史 / 稍后再看」同款）在
 * 「扫码登录」「短信登录」两个页签间切换，不再经 'SmsLogin' 子路由跳转。
 *
 * ── 扫码页签 ──
 * 流程：生成二维码（passport web 接口）→ 本地 QRCode 组件渲染 → 每 2s 轮询扫码状态
 * → 成功后 LoginStore 双通道提取登录 Cookie（回调 url 参数 / 响应 Set-Cookie 头）并持久化
 * → 自动返回。
 * 状态机（qrPhase）：loading（取二维码中）/ ready（等待扫码，86101）/ scanned（已扫码
 * 待确认，86090）/ expired（86038，二维码约 180s 过期，点击蒙层刷新重新生成）。
 *
 * ── 短信页签（三步状态机，对齐 BBPlayer usePhoneLogin）──
 *   input_phone   输入手机号 → fetchSmsCaptchaToken 拿图形验证 token + 极验参数；
 *   geetest_verify **整屏**极验 WebView（gt.js product=popup，内联 HTML + javaScriptProxy
 *                 桥回传 validate/seccode/challenge）→ sendSmsLoginCode 发短信，
 *                 86211 / -105 = 图形验证过期，退回 input_phone；
 *   input_code    输入短信验证码 → loginWithSmsCode 换登录 Cookie →
 *                 LoginStore.applySmsLoginCookies 落库 → 自动返回。
 * ⚠️ 极验 WebView 只在 geetest_verify 阶段挂载，且**必须是整屏**（`geetestOverlay`）：
 * B 站这个 gt 的 gettype 是 `fullpage`，面板是整屏 fixed 浮层 —— 塞在 360vp 卡片里
 * 真机表现就是「安全验证页一片空白」。每次重进都换新的 WebviewController（同一实例
 * 二次绑定 Web 节点会冲突）。白屏不再静默：看门狗（GEETEST_WATCHDOG_MS）+ HTML 的
 * gterr/gtready/gtok title 通道，失败一定会显示「重试 / 改用扫码登录」。
 *
 * 布局与转场复用 AboutPage 的模式：HDS 沉浸光感标题栏（HdsNavDestination.titleBar，
 * stackBuilder 承载返回行 + 标题、bottomBuilder 承载滑块切换行）、Stack 承载滚动内容
 * + 极验整屏覆盖层、customTransition 横移转场。
 * ⚠️ 二维码轮询定时器与极验看门狗必须在 aboutToDisappear 清掉，离开页面后不能空转。
 */

import { STORE_SAFE_TOP, STORE_THEME_PRIMARY, STORE_THEME_ON } from '../common/Constants';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { NavStackHolder } from '../service/NavStackHolder';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { NAV_TRANSITION_MS, BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import { BusinessError } from '@ohos.base';
import { util } from '@kit.ArkTS';
import web_webview from '@ohos.web.webview';
import { HdsNavDestination, BottomBuilderShowType } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { showAppToast } from '../components/AppToast';
import { CapsuleSegmentButtonV2, LengthMetrics, SegmentButtonV2Items } from '@kit.ArkUI';
import { makeBiliSegmentColors, SegmentColors } from '../utils/HeaderBarMaterial';
import {
  BiliApiError,
  fetchSmsCaptchaToken,
  generateQrLogin,
  loginWithSmsCode,
  pollQrLogin,
  QrLoginTicket,
  QrPollResult,
  sendSmsLoginCode,
  SmsCaptchaInfo,
  SmsLoginResult,
  SmsSendResult
} from '../api/BilibiliApi';
import { applyQrSuccess, applySmsLoginCookies, refreshLoginUser } from '../service/LoginStore';
import { HttpUtil } from '../utils/HttpUtil';

/** 二维码轮询间隔（ms）：B 站网页版同款节奏，太快会被风控 */
const QR_POLL_INTERVAL_MS: number = 2000;

/** 页签下标（刻意用数字常量而不是 enum：.ets 里声明 enum 会连带报 SDK 解析错误） */
const TAB_QR: number = 0;
const TAB_SMS: number = 1;

/**
 * 标题栏滑块切换行（扫码登录 / 短信登录）固定高：
 * 段切换 Column 40 + 行 padding bottom 4 = 44。
 * bottomBuilder 高度不自适应（官方约束），必须与行内容定高一致。
 */
const LOGIN_TABS_ROW_HEIGHT: number = 44;

/** 顶栏滚动模糊时机（2026-10-09 全站定档）：滚动 0~30vp 完全透明 → 30~80vp 材质渐变 → >80vp 满强度 */
const LOGIN_BLUR_START_VP: number = 30;
const LOGIN_BLUR_END_VP: number = 80;

/** 区号固定中国大陆（对齐 BBPlayer usePhoneLogin 的 COUNTRY_CODE） */
const COUNTRY_CODE: string = '86';
const PHONE_PATTERN: RegExp = /^\d{5,15}$/;
const CODE_PATTERN: RegExp = /^\d{4,8}$/;
const PHASE_PHONE: string = 'input_phone';
const PHASE_GEETEST: string = 'geetest_verify';
const PHASE_CODE: string = 'input_code';
/**
 * 极验加载看门狗（ms）：到点仍没收到 `gtready` / `gtok` 就判加载失败、显示重试出口。
 *
 * 为什么必须有：极验 fullpage 面板的失败是**静默**的（loader 网络错误、脚本被拦、
 * 域校验不通过都只是"什么都没有"），旧实现既没有 onConsole 也没有超时，
 * 用户看到的就是一片空白、永远等不到回调。取 12s：gettype + 两次 js 加载
 * 在弱网下也要留余量，但比"永远转圈"好。
 */
const GEETEST_WATCHDOG_MS: number = 12000;
/**
 * 极验页的「假 https 地址」：只用于给 Web 一个**真实 https 上下文**
 * （origin = https://www.bilibili.com），内容由 `onInterceptRequest` 直接返回。
 *
 * 为什么不再用 `loadData`：真机实测（2026-10-20 18:26）`loadData(base64)` 在
 * `onControllerAttached` 里**静默失效** —— 探针拿到的是
 * `href=about:blank, origin=null, init=undefined`，HTML 从未执行；
 * 而极验的域校验读的正是 location.origin，`null` 也过不去。
 * 走真实导航后 origin/href/referrer 全部正常，且不再有「注入时机」这类竞态。
 */
const GEETEST_PAGE_URL: string = 'https://www.bilibili.com/__bilimusic_geetest.html';

/** 极验成功回传（WebView JSON.parse 后的形态，字段全可缺） */
interface GeetestResult {
  validate?: string;
  seccode?: string;
  challenge?: string;
}

/** 从异常里取 B 站业务码（非 BiliApiError 返回 0，与 B 站业务码空间不冲突） */
function errorBiliCode(e: Object): number {
  if (e instanceof BiliApiError) {
    return e.code;
  }
  return 0;
}

/**
 * HTML → base64（loadData 的安全喂法）。
 * ⚠️ 不要直接 `loadData(html, 'text/html', 'utf-8')`：官方 FAQ（faqs-arkweb-57）
 * 明确 html 里出现 `#`（如 CSS 颜色 `#333`）等字符时 loadData 会**静默加载失败白屏**；
 * 本页 HTML 恰好满是 `#f5f5f5` 之类的颜色值。base64 后无非法字符，且保住 baseUrl
 * （gt.js 远程脚本按 bilibili.com 同源上下文加载）。HTML 内含 <meta charset="UTF-8">，
 * 浏览器按 UTF-8 解码 base64 还原出的字节，中文不受影响。
 */
function encodeHtmlBase64(html: string): string {
  const bytes: Uint8Array = new util.TextEncoder().encodeInto(html);
  return new util.Base64Helper().encodeToStringSync(bytes);
}

/**
 * 极验 WebView ⇄ 应用桥：HTML 里 `appProxy.postGeetestResult(json)` 的落点。
 * javaScriptProxy 要求注册带方法的实例；回调在 aboutToAppear 里接线。
 */
class GeetestBridge {
  /** 极验滑块通过回调（处理 {validate, seccode, challenge} JSON 串） */
  onGeetestResult: (message: string) => void = (_message: string): void => {
  };

  postGeetestResult(message: string): void {
    this.onGeetestResult(message);
  }
}

/**
 * 极验验证页 HTML（移植 BBPlayer GeetestVerifyStep.buildGeetestHtml）。
 *
 * 2026-10-20 白屏修复要点（真机症状：「安全验证」整块空白、永远等不到回调）：
 *   ① 宿主必须**整屏**：`gettype.php?gt=<B站gt>` 实测返回 `type:"fullpage"`，
 *      fullpage 面板是整屏 fixed 浮层；塞进 360vp 高的卡片里会被裁成空白。
 *      参考实现（BBPlayer）也是 `Portal + absoluteFill + flex:1` 的整屏 WebView。
 *   ② 失败必须可见：`window.onerror` / `unhandledrejection` / 顶层 `onError`
 *      三处兜住，任何失败都写红字 + `document.title='gterr:<code>'`。
 *   ③ 结果双通道：`appProxy.postGeetestResult` 之外再写 `gtok:<json>`，
 *      由 ArkTS 的 `onTitleReceive` 兜底解析（proxy 未注入也不丢结果）。
 */
function buildGeetestHtml(gt: string, challenge: string): string {
  const gtJson: string = JSON.stringify(gt);
  const challengeJson: string = JSON.stringify(challenge);
  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    html, body { height: 100%; }
    body {
      display: flex; flex-direction: column;
      align-items: center; justify-content: center;
      min-height: 100vh; background: #f5f5f5;
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    }
    .card {
      background: #fff; border-radius: 8px; padding: 20px;
      box-shadow: 0 2px 8px rgba(0,0,0,0.12); width: 90%; max-width: 340px;
      text-align: center;
    }
    h3 { text-align: center; margin-bottom: 12px; font-size: 16px; color: #333; }
    #status { font-size: 12px; color: #888; min-height: 16px; line-height: 16px; }
    #captcha { min-height: 40px; }
    .err { color: #d32f2f; margin-top: 10px; font-size: 13px; word-break: break-all; }
    #startBtn { display: none; margin: 12px auto 0; padding: 9px 20px; border: 0;
                border-radius: 8px; background: #fb7299; color: #fff; font-size: 14px; }
  </style>
</head>
<body>
  <div class="card">
    <h3>请完成安全验证</h3>
    <div id="status">正在加载验证组件…</div>
    <div id="captcha"></div>
    <button id="startBtn">开始验证</button>
    <div class="err" id="err-msg"></div>
  </div>
  <script src="https://static.geetest.com/static/js/gt.0.4.9.js" onerror="window.__gtLoaderError='script'"></script>
  <script>
    (function () {
      var GT_GT = ${gtJson};
      var GT_CHALLENGE = ${challengeJson};
      var READY = false;
      var statusEl = document.getElementById('status');
      var errEl = document.getElementById('err-msg');
      var startBtn = document.getElementById('startBtn');

      function setStatus(text) { if (statusEl) { statusEl.textContent = text; } }

      // 失败必须「看得见 + 回传得到」：页面红字给人看，document.title 给 ArkTS 收
      //（onTitleReceive 是 javaScriptProxy 之外的第二条通道）
      function fail(code, detail) {
        if (READY) { return; }
        if (errEl && !errEl.textContent) {
          errEl.textContent = '验证组件加载失败（' + code + '）' +
            (detail ? '：' + String(detail).slice(0, 80) : '');
        }
        setStatus('加载失败');
        try { document.title = 'gterr:' + code; } catch (e) { }
      }
      window.onerror = function (m, s, l) { fail('js', m); return false; };
      window.addEventListener('unhandledrejection', function (e) { fail('promise', e && e.reason); });
      setTimeout(function () { if (!READY) { fail('timeout'); } }, 9000);

      function send(captchaObj) {
        var r = captchaObj.getValidate() || {};
        var json = JSON.stringify({
          validate: r.geetest_validate,
          seccode: r.geetest_seccode,
          challenge: r.geetest_challenge
        });
        setStatus('验证通过，正在发送短信…');
        // 兜底通道：即便 javaScriptProxy 没注入，也能把结果送回 ArkTS
        try { document.title = 'gtok:' + json; } catch (e) { }
        try {
          if (window.appProxy && typeof window.appProxy.postGeetestResult === 'function') {
            window.appProxy.postGeetestResult(json);
          }
        } catch (e) { }
      }

      function ready(captchaObj) {
        try {
          READY = true;
          if (errEl) { errEl.textContent = ''; }
          setStatus('验证组件已就绪');
          captchaObj.appendTo('#captcha');
          captchaObj.onSuccess(function () { send(captchaObj); });
          captchaObj.onError(function () { READY = false; fail('verify'); });
          captchaObj.onClose(function () { try { document.title = 'gtclose:1'; } catch (e) { } });
          try { document.title = 'gtready:1'; } catch (e) { }
          console.info('geetest ready, verify=' + typeof captchaObj.verify);
          // fullpage 面板本应自己铺满整屏；万一没展示（容器尺寸/时序），主动拉起并给按钮
          setTimeout(function () {
            var box = document.getElementById('captcha');
            var empty = !box || box.offsetHeight < 20 || box.children.length === 0;
            if (!empty) { return; }
            if (startBtn) {
              startBtn.style.display = 'inline-block';
              startBtn.onclick = function () {
                try { if (typeof captchaObj.verify === 'function') { captchaObj.verify(); } } catch (e) { }
              };
            }
            try { if (typeof captchaObj.verify === 'function') { captchaObj.verify(); } } catch (e) { }
          }, 500);
        } catch (e) { READY = false; fail('mount', e && e.message); }
      }

      try {
        if (typeof window.initGeetest !== 'function') {
          fail(window.__gtLoaderError ? 'loader' : 'init');
          return;
        }
        window.initGeetest({
          gt: GT_GT,
          challenge: GT_CHALLENGE,
          offline: false,
          new_captcha: true,
          product: 'popup',
          width: '100%',
          https: true,
          // loader 取不到 SDK 时会 throwError('networkError')：没这个回调就是未捕获异常、静默白屏
          onError: function (msg) { fail('network', msg); }
        }, ready);
      } catch (e) {
        fail('boot', e && e.message);
      }
    })();
  </script>
</body>
</html>`;
}

@Component
export struct LoginPage {
  /** 状态栏高度（vp）：内容区要整体落在状态栏下方，由本页自己顶下来 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;

  /** 主题色主色：二维码刷新图标、短信登录按钮底色与提示文字跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /** 主题色深字色：短信登录按钮文字跟随切色刷新 */
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 滚动控制器：bindToScrollable 绑给 HDS 标题栏，滚动模糊效果依赖此绑定 */
  private loginScroller: Scroller = new Scroller();
  /**
   * 子页转场的横移量（相对页面自身宽度）：常驻 '0%'，
   * 转场代理里按 push/pop 方向临时改写（见 navTransitionDelegate，与 AboutPage 同款）。
   */
  @State navTransX: string = '0%';

  /** 当前页签：0 = 扫码登录（默认），1 = 短信登录 */
  @State tab: number = TAB_QR;
  /** 段切换（扫码登录 / 短信登录）分段按钮条目：静态一次构造 */
  private segmentItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: '扫码登录' },
    { text: '短信登录' }
  ]);
  /** 分段按钮主题色配色组：每次渲染现取（读 AppStorage），缓存成字段切色不刷新 */
  private segColors(): SegmentColors {
    return makeBiliSegmentColors();
  }

  // ── 扫码页签状态 ──
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

  // ── 短信页签状态（三步状态机 + 极验面板） ──
  /** 三步状态机：PHASE_PHONE / PHASE_GEETEST / PHASE_CODE */
  @State phase: string = PHASE_PHONE;
  @State phone: string = '';
  @State smsCode: string = '';
  @State phoneError: string = '';
  @State codeError: string = '';
  /** 请求进行中（取 token / 发短信 / 登录）：按钮禁用与防重入 */
  @State busy: boolean = false;
  /** 极验面板是否已就绪（收到 `gtready`）：控制「正在加载…」提示与看门狗 */
  @State geetestReady: boolean = false;
  /** 极验加载失败原因（非空 = 覆盖层显示失败态 + 重试出口，绝不留死白屏） */
  @State geetestError: string = '';

  /** 第 1 步下发的图形验证信息（第 2 步发短信必带 token） */
  private captcha: SmsCaptchaInfo | null = null;
  /** 第 2 步下发的一次性凭据，第 3 步登录必带 */
  private captchaKey: string = '';
  /** 极验页内容：进入 geetest 阶段前用 gt/challenge 构建 */
  private geetestHtml: string = '';
  /** 本轮极验页地址（真实 https + t 防缓存；内容由 onInterceptRequest 返回） */
  private geetestPageUrl: string = '';
  /** 拦截未命中时的应急回落是否已用掉（data: 导航，每轮只用一次） */
  private geetestFallbackUsed: boolean = false;
  /** 每次进入 geetest 阶段都换新实例（同一 controller 不能二次绑定 Web 节点） */
  private webController: web_webview.WebviewController = new web_webview.WebviewController();
  private bridge: GeetestBridge = new GeetestBridge();
  /** 加载看门狗定时器 id（-1 = 未启动） */
  private watchdogTimer: number = -1;
  /** 本轮极验结果是否已消费（proxy 与 title 双通道会重复投递，必须一次性） */
  private geetestConsumed: boolean = false;

  aboutToAppear(): void {
    this.bridge.onGeetestResult = (message: string): void => {
      this.handleGeetestResult(message);
    };
    this.startQrLogin();
  }

  aboutToDisappear(): void {
    this.stopPolling();
    this.clearWatchdog();
    // 页面销毁后桥对象仍被 Web 持有：断开回调，避免迟到的回调打到已卸载的组件
    this.bridge.onGeetestResult = (_message: string): void => {
    };
  }

  /**
   * 滑块切页签：离开短信页签时若正处于极验阶段，先取消极验
   * （看门狗 / WebView 状态不能跟着页签潜伏，否则后台空转或迟到回调）。
   */
  private switchTab(index: number): void {
    if (index === this.tab) {
      return;
    }
    if (this.tab === TAB_SMS && this.phase === PHASE_GEETEST) {
      this.backToPhone();
    }
    this.tab = index;
  }

  // ── 扫码页签逻辑 ──

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

  // ── 短信页签逻辑 ──

  /** 第 1 步：校验手机号 → 取图形验证信息 → 进极验页 */
  private requestCaptcha(): void {
    const tel: string = this.phone.trim();
    if (tel.length === 0) {
      this.phoneError = '请输入手机号';
      return;
    }
    if (!PHONE_PATTERN.test(tel)) {
      this.phoneError = '手机号格式不正确';
      return;
    }
    this.phoneError = '';
    this.busy = true;
    fetchSmsCaptchaToken()
      .then((info: SmsCaptchaInfo): void => {
        this.captcha = info;
        this.geetestHtml = buildGeetestHtml(info.gt, info.challenge);
        this.geetestPageUrl = `${GEETEST_PAGE_URL}?t=${Date.now()}`;
        this.webController = new web_webview.WebviewController();
        // 每轮都重置转场状态：结果一次性、失败态清空、看门狗重开
        this.geetestReady = false;
        this.geetestError = '';
        this.geetestConsumed = false;
        this.geetestFallbackUsed = false;
        this.phase = PHASE_GEETEST;
        this.busy = false;
        this.startWatchdog();
        // 只记长度指纹（token/gt/challenge 均为凭据类值，不落日志）
        console.info(`sms captcha fetched: tokenLen=${info.token.length}` +
          `, gtLen=${info.gt.length}, challengeLen=${info.challenge.length}, htmlLen=${this.geetestHtml.length}`);
      })
      .catch((e: BusinessError): void => {
        this.busy = false;
        this.phoneError = `获取验证码失败：${e.message}`;
        console.warn(`sms captcha fetch failed: ${e.message}`);
      });
  }

  /**
   * 第 2 步：极验通过（WebView 回传）→ 发送短信验证码。
   *
   * 两个来源都会调到这里：`appProxy.postGeetestResult`（主通道）与
   * `onTitleReceive` 的 `gtok:`（兜底通道）—— 用 `geetestConsumed` 保证只消费一次，
   * 否则会重复发两条短信。
   */
  private handleGeetestResult(message: string): void {
    // 桥回调可能来自非 UI 线程派发，先留痕再处理（出现 UI 不刷新时按此定位）
    console.info(`geetest result: len=${message.length}`);
    if (this.busy || this.geetestConsumed || this.captcha === null
      || this.phase !== PHASE_GEETEST) {
      return;
    }
    let validate: string = '';
    let seccode: string = '';
    let challenge: string = '';
    try {
      const parsed: GeetestResult = JSON.parse(message) as GeetestResult;
      validate = parsed.validate ?? '';
      seccode = parsed.seccode ?? '';
      challenge = parsed.challenge ?? '';
    } catch (e) {
      return;
    }
    if (validate.length === 0 || seccode.length === 0 || challenge.length === 0) {
      console.warn('geetest result ignored: empty field');
      return;
    }
    this.geetestConsumed = true;
    this.clearWatchdog();
    this.busy = true;
    // 诊断：-400「请求错误」= 服务端收到空表单/缺 tel，这里记长度确认 tel 是否丢失
    console.info(`sms send start: phoneLen=${this.phone.trim().length}, ` +
      `tokenLen=${this.captcha.token.length}, vLen=${validate.length}`);
    sendSmsLoginCode(this.phone.trim(), COUNTRY_CODE, this.captcha.token, challenge, validate, seccode)
      .then((result: SmsSendResult): void => {
        this.captchaKey = result.captchaKey;
        this.busy = false;
        this.phase = PHASE_CODE;
        showAppToast('验证码已发送', 1800);
      })
      .catch((e: BusinessError): void => {
        this.busy = false;
        this.phase = PHASE_PHONE;
        // 86211 / -105：图形验证已过期（BBPlayer useGeetest 同款判定），退回第 1 步重来
        const biliCode: number = errorBiliCode(e);
        if (biliCode === 86211 || biliCode === -105) {
          this.phoneError = '图形验证已过期，请重新获取验证码';
        } else {
          this.phoneError = `发送验证码失败：${e.message}`;
        }
      });
  }

  /** 第 3 步：短信验证码换登录 Cookie → 落库 → 刷新用户信息 → 返回 */
  private doLogin(): void {
    const code: string = this.smsCode.trim();
    if (code.length === 0) {
      this.codeError = '请输入验证码';
      return;
    }
    if (!CODE_PATTERN.test(code)) {
      this.codeError = '验证码格式不正确';
      return;
    }
    if (this.captchaKey.length === 0) {
      // 正常走不到（进本阶段前必有 captchaKey），防御性回退
      this.codeError = '';
      this.phase = PHASE_PHONE;
      return;
    }
    this.codeError = '';
    this.busy = true;
    loginWithSmsCode(this.phone.trim(), COUNTRY_CODE, code, this.captchaKey)
      .then(async (result: SmsLoginResult): Promise<void> => {
        await applySmsLoginCookies(result.responseCookies, result.refreshToken);
        await refreshLoginUser();
        this.busy = false;
        this.finishSmsLogin();
      })
      .catch((e: BusinessError): void => {
        this.busy = false;
        // 诊断只记异常消息（BiliApiError 消息含业务码，不含凭据值）
        console.warn(`sms login failed: ${e.message}`);
        this.codeError = e.message.length > 0 ? e.message : '登录失败，请检查验证码';
      });
  }

  /**
   * 短信登录成功后的收尾：**先退栈、再提示**。
   *
   * `showAppToast` 紧挨着 pop 调用会被一起收掉：toast 挂在当前页的 UIContext 上，
   * 页面一销毁就跟着消失（日志表现 `closeToast(...) → Toast not found`）。
   * 所以提示延迟到退栈动画之后再发。合并后登录只有一层路由（不再有 'SmsLogin'
   * 子页），pop 一层即回到来源页（设置 / 关注 / 收藏同步等）。
   */
  private finishSmsLogin(): void {
    console.info(`sms login done: pop nav stack, size=${NavStackHolder.stack.size()}`);
    NavStackHolder.stack.pop();
    setTimeout((): void => {
      showAppToast('登录成功', 1800);
    }, 200);
  }

  /** 退回手机号输入（取消极验 / 重新获取验证码 / 切走页签共用） */
  private backToPhone(): void {
    this.clearWatchdog();
    this.phase = PHASE_PHONE;
    this.geetestHtml = '';
    this.captcha = null;
    this.geetestReady = false;
    this.geetestError = '';
    this.geetestConsumed = false;
  }

  /**
   * 加载看门狗：`GEETEST_WATCHDOG_MS` 内没收到 `gtready` 就判失败。
   *
   * 极验的失败是静默的（loader 网络错误 / 脚本被拦 / 域校验不过），
   * 不设超时用户就是「一片空白 + 永远转圈」，没有任何出口。
   */
  private startWatchdog(): void {
    this.clearWatchdog();
    this.watchdogTimer = setTimeout((): void => {
      this.watchdogTimer = -1;
      if (this.phase !== PHASE_GEETEST || this.geetestReady) {
        return;
      }
      console.warn('geetest web: watchdog fired');
      this.geetestError = '验证组件加载超时，请重试';
    }, GEETEST_WATCHDOG_MS);
  }

  private clearWatchdog(): void {
    if (this.watchdogTimer !== -1) {
      clearTimeout(this.watchdogTimer);
      this.watchdogTimer = -1;
    }
  }

  /**
   * 构造极验页的拦截响应（`onInterceptRequest` 的返回体）。
   * Header 显式带 charset：中文文案不依赖引擎猜编码。
   */
  private buildGeetestResponse(): WebResourceResponse {
    const resp: WebResourceResponse = new WebResourceResponse();
    resp.setResponseMimeType('text/html');
    resp.setResponseEncoding('utf-8');
    resp.setResponseData(this.geetestHtml);
    resp.setResponseCode(200);
    resp.setReasonMessage('OK');
    const header: Header[] = [
      { headerKey: 'Content-Type', headerValue: 'text/html; charset=utf-8' },
      { headerKey: 'Cache-Control', headerValue: 'no-store' }
    ];
    resp.setResponseHeader(header);
    return resp;
  }

  /**
   * 拦截未命中时的应急回落：用 `data:` 真实导航再喂一次同样的 HTML。
   *
   * 只在「主框架请求真的打到 bilibili.com 并且报错」时触发一次 —— 那种情况说明
   * 这台设备的 ArkWeb 没拦主框架，`loadData` 又已被实测证明无效，只剩 `data:`
   * 这一条能让脚本跑起来的路（origin 会退化成 opaque，先保证有验证可用）。
   */
  private fallbackLoadData(): void {
    if (this.geetestFallbackUsed) {
      return;
    }
    this.geetestFallbackUsed = true;
    console.warn('geetest web: intercept miss -> data: navigation fallback');
    try {
      this.webController.loadUrl(`data:text/html;base64,${encodeHtmlBase64(this.geetestHtml)}`);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.error(`geetest web: data fallback failed ${msg}`);
      this.geetestError = '验证组件注入失败';
    }
  }

  /**
   * 页面载入后的 JS 探针：一次把「上下文对不对」问清楚。
   *
   * 白屏排查只需要这一行 —— href/origin 说明 loadData 给的是什么上下文，
   * init/Geetest 说明 loader 有没有执行成功，proxy 说明桥注入没有，
   * captchaH 说明面板到底 mount 了没有。
   */
  private probePage(url: string): void {
    console.info(`geetest web: end ${url}`);
    this.webController.runJavaScript(
      'JSON.stringify({href:location.href,origin:location.origin,' +
      'init:typeof window.initGeetest,Geetest:typeof window.Geetest,' +
      'proxy:typeof window.appProxy,' +
      'captchaH:(document.getElementById("captcha")||{offsetHeight:0}).offsetHeight,' +
      'bodyH:(document.body?document.body.offsetHeight:0)})'
    ).then((result: string): void => {
      console.info(`geetest web: probe ${result}`);
    }).catch((e: BusinessError): void => {
      console.warn(`geetest web: probe failed ${e.message}`);
    });
  }

  /**
   * `onTitleReceive` 兜底通道：解析页面主动写的三种标题。
   *
   *   gtready:<type>  面板就绪（清看门狗、撤「正在加载…」）
   *   gtok:<json>     验证通过（与 proxy 同一个消费入口，有一次性守卫）
   *   gterr:<code>    加载/挂载失败（显示失败态 + 重试出口）
   *
   * 只记前缀与长度：gtok 的负载是凭据类数据，不能进系统日志。
   */
  private handleGeetestTitle(title: string): void {
    if (title.startsWith('gtready')) {
      if (this.geetestReady) {
        return;
      }
      this.geetestReady = true;
      this.geetestError = '';
      this.clearWatchdog();
      console.info(`geetest web: ready type=${title.substring(title.indexOf(':') + 1)}`);
      return;
    }
    if (title.startsWith('gtok:')) {
      console.info(`geetest web: result via title len=${title.length}`);
      this.handleGeetestResult(title.substring(5));
      return;
    }
    if (title.startsWith('gterr:')) {
      const code: string = title.substring(6);
      console.warn(`geetest web: page error ${code}`);
      this.clearWatchdog();
      if (this.geetestError.length === 0) {
        this.geetestError = `验证组件加载失败（${code}）`;
      }
      return;
    }
    if (title.startsWith('gtclose')) {
      // 用户关掉极验面板：只留痕，不强行退步骤（他可能想再试一次）
      console.info('geetest web: captcha closed by user');
    }
  }

  /**
   * 重试极验：**必须先卸载 Web 节点**再重新取凭据。
   * 同一 `WebviewController` 不能二次绑定 Web 节点，且旧 challenge 一次性失效，
   * 所以走「回手机号 → 重新 requestCaptcha」而不是原地 reload。
   */
  private retryGeetest(): void {
    if (this.busy) {
      return;
    }
    this.phase = PHASE_PHONE;
    this.geetestHtml = '';
    this.captcha = null;
    this.geetestError = '';
    this.geetestReady = false;
    this.geetestConsumed = false;
    this.requestCaptcha();
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

  /**
   * 标题行下方自定义区（titleBar 的 bottomBuilder 承载，恒配置）：
   * 滑块切换行（扫码登录 / 短信登录），与观看历史页「观看历史 / 稍后再看」同款。
   * ⚠️ bottomBuilder 高度不自适应（官方约束），由 titleBar 参数显式给定
   * （LOGIN_TABS_ROW_HEIGHT），行定高排布。
   */
  @Builder
  loginTabsRow() {
    Row() {
      // 段切换：CapsuleSegmentButtonV2 标准分段按钮，B 站粉经
      // itemSelectedBackgroundColor 覆写；selectedIndex 由 this.tab 重算，
      // 点击 → onItemClicked → switchTab（内含极验阶段取消守卫）。
      CapsuleSegmentButtonV2({
        items: this.segmentItems,
        selectedIndex: this.tab,
        onItemClicked: (index: number): void => {
          this.switchTab(index);
        },
        itemSelectedBackgroundColor: this.segColors().selectedBg,
        itemSelectedFontColor: this.segColors().selectedFont,
        itemSelectedFontWeight: FontWeight.Medium,
        itemFontColor: this.segColors().unselectedFont,
        itemFontWeight: FontWeight.Normal,
        itemFontSize: LengthMetrics.vp(13),
        itemSelectedFontSize: LengthMetrics.vp(13),
        buttonBackgroundColor: this.segColors().grooveBg,
        buttonBorderRadius: LengthMetrics.vp(BUTTON_RADIUS_VP),
        itemBorderRadius: LengthMetrics.vp(6),
        // 内部背板最小高度默认系统 token（约 36vp）会盖过外层 .height(32)，对齐到 32
        buttonMinHeight: LengthMetrics.vp(32),
        // 紧凑内边距：系统默认 start/end 16vp 空气感过强，收到 8vp
        itemPadding: { start: LengthMetrics.vp(8), end: LengthMetrics.vp(8) }
      })
        .height(32)
        // V2 分段按钮测量特性：给多大渲染多大（均摊到各段），不会内容自适应
        // —— 宽度显式收紧（背板 padding 4×2 + 两段 4 字文案 + itemPadding 8×2）。
        .width(150)
    }
    .width('100%')
    .height(LOGIN_TABS_ROW_HEIGHT)
    .padding({ left: 16, right: 16, bottom: 4 })
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

  /** 扫码页签卡片：标题 + 二维码 + 状态文案 */
  @Builder
  qrCard() {
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
    .margin({ left: 12, right: 12, top: 10, bottom: 20 })
    .alignItems(HorizontalAlign.Center)
  }

  /** 短信页签主按钮：粉底胶囊（loading 态文案变化 + 禁用防重入） */
  @Builder
  primaryButton(label: string, enabled: boolean, onTap: () => void) {
    Button(label, { type: ButtonType.Normal })
      .width('100%')
      .height(44)
      .borderRadius(8)
      .backgroundColor(this.themePrimary)
      .fontColor(this.themeOn)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .enabled(enabled)
      .onClick((): void => {
        onTap();
      })
  }

  /** 短信第 1 步：手机号输入卡 */
  @Builder
  phoneCard() {
    Text('短信登录')
      .fontSize(18)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.text_primary'))
      .margin({ top: 22 })
    Text('使用手机号接收短信验证码登录 B 站')
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .margin({ top: 6 })
    TextInput({
      placeholder: '请输入手机号',
      text: this.phone
    })
      .width('100%')
      .height(46)
      .borderRadius(8)
      .backgroundColor($r('app.color.bg_page'))
      .type(InputType.PhoneNumber)
      .maxLength(15)
      .onChange((v: string): void => {
        this.phone = v;
        this.phoneError = '';
      })
      .margin({ top: 20 })
    if (this.phoneError.length > 0) {
      Text(this.phoneError)
        .fontSize(12)
        .fontColor($r('app.color.state_error'))
        .width('100%')
        .margin({ top: 6 })
    }
    this.primaryButton(this.busy ? '正在获取…' : '获取验证码', !this.busy, (): void => {
      this.requestCaptcha();
    })
    // 卡片底部呼吸空间（旧版由「改用扫码登录」链接提供，合并后改由占位承担）
    Blank()
      .height(22)
  }

  /**
   * 短信第 2 步：卡片里只留「等待验证」提示 —— 极验 WebView 已移到整屏覆盖层
   * （`geetestOverlay`），这里**不能再挂第二个 Web 实例**。
   */
  @Builder
  geetestCard() {
    Text('安全验证')
      .fontSize(18)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.text_primary'))
      .margin({ top: 22 })
    Text('已打开全屏安全验证，完成后会自动发送短信')
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .margin({ top: 6 })
    if (this.busy) {
      Text('正在发送短信验证码…')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 16 })
    }
    Button('取消', { type: ButtonType.Normal })
      .width('100%')
      .height(44)
      .borderRadius(8)
      .backgroundColor($r('app.color.bg_divider'))
      .fontColor($r('app.color.text_primary'))
      .fontSize(15)
      .margin({ top: 20, bottom: 22 })
      .onClick((): void => {
        this.backToPhone();
      })
  }

  /** 短信第 3 步：短信验证码输入卡 */
  @Builder
  codeCard() {
    Text('输入验证码')
      .fontSize(18)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.text_primary'))
      .margin({ top: 22 })
    Text(`验证码已发送至 +86 ${this.phone.trim()}`)
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .margin({ top: 6 })
    TextInput({
      placeholder: '请输入短信验证码',
      text: this.smsCode
    })
      .width('100%')
      .height(46)
      .borderRadius(8)
      .backgroundColor($r('app.color.bg_page'))
      .type(InputType.Number)
      .maxLength(8)
      .onChange((v: string): void => {
        this.smsCode = v;
        this.codeError = '';
      })
      .margin({ top: 20 })
      .onSubmit((): void => {
        this.doLogin();
      })
    if (this.codeError.length > 0) {
      Text(this.codeError)
        .fontSize(12)
        .fontColor($r('app.color.state_error'))
        .width('100%')
        .margin({ top: 6 })
    }
    this.primaryButton(this.busy ? '正在登录…' : '登录', !this.busy, (): void => {
      this.doLogin();
    })
    // 卡片底部呼吸空间（旧版由「重新获取验证码」链接提供，合并后改由占位承担）
    Blank()
      .height(22)
  }

  /**
   * 极验整屏覆盖层（白屏修复核心，详见 buildGeetestHtml 注释）。
   *
   * 层级：本层是页面根 Stack 的最后一个子节点 → 盖住 Scroll 内容；
   * HDS 标题栏（标题行 + 滑块行）由宿主绘制在上层，所以这里只需让出
   * safeTop + 标题行 + 滑块行。
   */
  @Builder
  geetestOverlay() {
    Column() {
      // 覆盖层自己的头（HDS 标题栏仍在上面，这里只做「取消」出口）
      Row() {
        Text('安全验证')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('取消')
          .fontSize(15)
          .fontColor(this.themePrimary)
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .onClick((): void => {
            this.backToPhone();
          })
      }
      .width('100%')
      .height(44)
      .padding({ left: 20, right: 20 })
      .alignItems(VerticalAlign.Center)

      if (this.geetestError.length > 0) {
        // 失败态：绝不留死白屏 —— 说明原因 + 重试 + 切回扫码
        Column() {
          Text(this.geetestError)
            .fontSize(14)
            .fontColor($r('app.color.state_error'))
            .textAlign(TextAlign.Center)
          Text('可以重试，或切换到扫码登录')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .margin({ top: 8 })
          Button('重试', { type: ButtonType.Normal })
            .width(160)
            .height(40)
            .borderRadius(8)
            .backgroundColor(this.themePrimary)
            .fontColor(this.themeOn)
            .fontSize(14)
            .margin({ top: 18 })
            .onClick((): void => {
              this.retryGeetest();
            })
          Button('改用扫码登录', { type: ButtonType.Normal })
            .width(160)
            .height(40)
            .borderRadius(8)
            .backgroundColor($r('app.color.bg_divider'))
            .fontColor($r('app.color.text_primary'))
            .fontSize(14)
            .margin({ top: 10 })
            .onClick((): void => {
              this.switchTab(TAB_QR);
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 24, right: 24 })
      } else {
        // 整屏 Web：不固定高度、不裁圆角 —— fullpage 面板需要完整的视口
        Web({ src: this.geetestPageUrl, controller: this.webController })
          .width('100%')
          .layoutWeight(1)
          .backgroundColor($r('app.color.bg_page'))
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .javaScriptProxy({
            object: this.bridge,
            name: 'appProxy',
            methodList: ['postGeetestResult'],
            controller: this.webController
          })
          // 极验页内容由本地返回：URL 是真实 https（origin = www.bilibili.com），
          // 但内容一个字节都不走网络 —— 「真实上下文 + 内联 HTML」的唯一稳法。
          .onInterceptRequest((event?: OnInterceptRequestEvent): WebResourceResponse | null => {
            if (event) {
              const reqUrl: string = event.request.getRequestUrl();
              if (reqUrl.startsWith(GEETEST_PAGE_URL)) {
                console.info(`geetest web: intercept ${reqUrl}`);
                return this.buildGeetestResponse();
              }
            }
            return null;
          })
          .onControllerAttached((): void => {
            console.info(`geetest web: controller attached url=${this.geetestPageUrl}`);
          })
          .onPageBegin((event?: OnPageBeginEvent): void => {
            console.info(`geetest web: begin ${event?.url ?? ''}`);
          })
          .onPageEnd((event?: OnPageEndEvent): void => {
            // 页面真正落地（about:blank → loadData 都会经过这里）；没出现 = 没加载
            this.probePage(event?.url ?? '');
          })
          .onTitleReceive((event?: OnTitleReceiveEvent): void => {
            const title: string = event?.title ?? '';
            if (title.length === 0) {
              return;
            }
            // 只记前缀与长度：gtok 的负载是凭据类数据，不能进日志
            console.info(`geetest web: title ${title.substring(0, 16)} len=${title.length}`);
            this.handleGeetestTitle(title);
          })
          .onConsole((event?: OnConsoleEvent): boolean => {
            // JS 报错全在这里：白屏时这就是唯一能说清原因的通道
            if (event) {
              console.info(`geetest web: console lv=${event.message.getMessageLevel()} ` +
                `src=${event.message.getSourceId()}:${event.message.getLineNumber()} ` +
                `msg=${event.message.getMessage()}`);
            }
            return false;
          })
          .onHttpErrorReceive((event?: OnHttpErrorReceiveEvent): void => {
            if (event) {
              const code: number = event.response.getResponseCode();
              const reqUrl: string = event.request.getRequestUrl();
              console.warn(`geetest web: http ${code} ${reqUrl} main=${event.request.isMainFrame()}`);
              // 拦截没命中（请求真的打到 bilibili.com → 404）→ 立刻应急回落
              if (event.request.isMainFrame() && reqUrl.startsWith(GEETEST_PAGE_URL)) {
                this.fallbackLoadData();
              }
            }
          })
          .onSslErrorEventReceive((event?: OnSslErrorEventReceiveEvent): void => {
            if (event) {
              console.warn(`geetest web: ssl code=${event.error}`);
              // 证书问题只记录并取消，绝不做 handleConfirm 绕过
              event.handler.handleCancel();
            }
          })
          .onErrorReceive((event?: OnErrorReceiveEvent): void => {
            // 主/子资源（含 gt.js、gettype.php）失败都会回调，白屏定位关键日志
            if (event) {
              const reqUrl: string = event.request.getRequestUrl();
              console.warn(`geetest web: resource error ${reqUrl} ` +
                `${event.error.getErrorInfo()} main=${event.request.isMainFrame()}`);
              if (event.request.isMainFrame() && reqUrl.startsWith(GEETEST_PAGE_URL)) {
                this.fallbackLoadData();
              }
            }
          })

        if (!this.geetestReady) {
          Text('正在加载验证组件…')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 8, bottom: 10 })
        }
      }
    }
    .width('100%')
    .height('100%')
    // 页面本身是沉浸全屏，覆盖层只需让出「安全区 + HDS 标题栏（标题行 + 滑块行）」
    .padding({ top: this.safeTop + NAV_TITLE_BAR_HEIGHT + LOGIN_TABS_ROW_HEIGHT })
    .backgroundColor($r('app.color.bg_page'))
    .zIndex(10)
    // 覆盖层挂载/尺寸留痕：以后同类问题看这两行即可判断是「没挂上」还是「挂上但 0 尺寸」。
    .onAppear((): void => {
      console.info('geetest overlay: appear');
    })
    .onAreaChange((_old: Area, next: Area): void => {
      console.info(`geetest overlay: area ${next.width}x${next.height}`);
    })
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Scroll(this.loginScroller) {
          Column() {
            // 顶部占位（官方沉浸口径）：开启沉浸后内容向上穿透进标题栏区域，
            // 让位不能加在滚动容器外层（否则内容被裁在栏底缘之下、材质无内容可采样），
            // 必须在页面内容内部做占位。高度 = safeTop + 56（标题行）+ 44（滑块行），
            // 滑块行经 bottomBuilder 恒配置，让位量恒定无需实测。
            Blank()
              .height(this.safeTop + NAV_TITLE_BAR_HEIGHT + LOGIN_TABS_ROW_HEIGHT)
              .width('100%')

            // ── 内容卡：随页签切换 ──
            if (this.tab === TAB_QR) {
              this.qrCard()
            } else {
              Column() {
                if (this.phase === PHASE_PHONE) {
                  this.phoneCard()
                } else if (this.phase === PHASE_GEETEST) {
                  this.geetestCard()
                } else {
                  this.codeCard()
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
              .padding({ left: 20, right: 20 })
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(12)
              .margin({ left: 12, right: 12, top: 10, bottom: 20 })
            }
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
        // 标题栏让位已内移为内容首部占位（见 Column 首子），不在滚动容器上加 padding。

        // 极验整屏覆盖层：只在短信页签的 geetest 阶段挂载。
        // ⚠️ 必须写在 Stack 的**子节点块内**（不能写在 Stack 的属性之后 —— 那样会被
        // 当成 HdsNavDestination 的子节点，Web 照样加载、但永远不进可视层）。
        if (this.tab === TAB_SMS && this.phase === PHASE_GEETEST) {
          this.geetestOverlay()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
      // 底部不做避让，沉浸到底（2026-10-14 与其余子页同口径，见目的地链上的
      // ignoreLayoutSafeArea 声明；内容自顶部起排，不与手势区重叠）。
    }
    // HDS 沉浸光感标题栏（批 1 样板同款，真机结论见 AboutPage 注释）：
    // avoidLayoutSafeArea 挡状态栏重叠；enableComponentSafeArea 会杀材质，禁用。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(LOGIN_BLUR_START_VP, LOGIN_BLUR_END_VP),
      content: {
        // 标题行（stackBuilder，可用空间 56vp）：返回键 + 「登录 B 站」标题
        stackBuilder: (): void => {
          this.loginBar();
        },
        // 标题行下方自定义区：滑块切换行（扫码登录 / 短信登录），恒配置。
        // ⚠️ 滑块行不能塞进 stackBuilder（会溢出 56vp 标题行、与内容重叠，真机复现），
        // 必须走 bottomBuilder 显式高度。
        bottomBuilder: {
          builder: (): void => {
            this.loginTabsRow();
          },
          height: LOGIN_TABS_ROW_HEIGHT,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
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
    // 内容避让（2026-10-14）：目的地级声明布局扩展进系统安全区（官方组件级沉浸
    // 口径，faqs-arkui-1095 场景三同款）；窗口全屏下页面级为既成事实，此处显式化
    // 并接管组件级 safeAreaPadding。内容层避让由 plain padding 自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets，2026-10-17 启动优化）：
 * Index 已不再静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function LoginPageBuilder(): void {
  LoginPage()
}


/** 懒加载注册表预包装（2026-10-17）：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const LoginPageWrapped: WrappedBuilder<[]> = wrapBuilder(LoginPageBuilder);
