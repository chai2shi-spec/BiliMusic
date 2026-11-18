/**
 * 登录页（四页签：密码 / 短信 / 扫码 / Cookie，对齐 PiliPlus LoginPage）。
 *
 * 顶部滑块（CapsuleSegmentButtonV2，与观看历史页「观看历史 / 稍后再看」同款）在
 * 四个页签间切换。App 端登录链路（android_hd 签名域，参数内联 URL + appSignQuery）
 * 的公共收尾是 finishAppLogin（applyAppLogin 落库 → refreshLoginUser → 先退栈再提示）。
 *
 * ── 密码页签 ──
 * fetchWebKey 取盐与 PEM 公钥 → loginByPwd（RSA 加密）→ status 0 落库；
 * -105 极验 → 整屏极验层（geetestConsumer='pwd'）通过后带 proof 重发；
 * status 2 风控 → 安心中心链（打码手机号 → preCapture → 极验 → 短信 →
 * verify → fetchOauth2Token → 落库）。
 *
 * ── 短信页签（App 端短信，两步状态机）──
 *   PHASE_PHONE  手机号 + 区号选择（半模态 Sheet，DialPrefixData 全量表）
 *                → sendAppSmsCode（常态免极验直达；needGeetest 时过极验层重发）；
 *   PHASE_CODE   短信验证码 → loginByAppSms → 落库 → 自动返回。
 *   卡内「粉版手机端登录」开关（默认关）：开启后 send/login 改在粉版
 *   （LOGIN_DOMAIN_ANDROID）域签名，签出的 access_token 与粉版 appkey
 *   （BILI_ANDROID_APP_*）同 appid；关闭时与 TV 扫码 / 密码同 HD 域，行为不变。
 *
 * ── 大会员登录福利（BiliMusic 特有）──
 * 登录成功后若为大会员（vipStatus===1），自动把播放 / 下载音质提升为
 * 「无损」（applyVipLosslessQuality），toast 带「已切换为无损音质」变体；
 * 覆盖全部登录成功路径（App 端四链 + 网页扫码 + Cookie 导入）。
 *
 * ── 扫码页签（TV ↔ 网页子切换）──
 * TV（默认）：fetchTvQrAuthCode → 本地 QRCode 渲染 → 每 1s pollTvQrLogin
 * （0 成功 / 86090 已扫 / 86038 过期 / 86039 等待）→ 成功走 finishAppLogin。
 * 网页：generateQrLogin → 每 2s pollQrLogin（86101/86090/86038/0，
 * 早失效自动换码）→ applyQrSuccess，原实现整体保留。
 *
 * ── Cookie 页签 ──
 * 粘贴 Cookie → validateWebCookie 校验 → applyImportedCookie 白名单落库 → 自动返回。
 *
 * ── 整屏极验层（泛化，流程无关）──
 * startGeetest(gt, challenge, consumer) 挂载（product=popup，内联 HTML +
 * javaScriptProxy 桥回传 validate/seccode/challenge，gtok title 兜底），
 * handleGeetestResult 按 geetestConsumer 分发（'pwd' / 'appsms' / 'safecenter'）。
 * ⚠️ 必须整屏（B 站这个 gt 的 gettype 是 fullpage，面板是整屏 fixed 浮层），
 * 每次重进都换新的 WebviewController。看门狗（GEETEST_WATCHDOG_MS）+
 * gterr/gtready/gtok title 通道，失败一定显示重试出口。
 *
 * 布局与转场复用 AboutPage 的模式：HDS 沉浸光感标题栏（HdsNavDestination.titleBar，
 * stackBuilder 承载标题（返回键为 HDS 默认键）、bottomBuilder 承载滑块切换行）、Stack 承载滚动内容
 * + 极验整屏覆盖层、customTransition 横移转场。
 * ⚠️ 双二维码轮询定时器与极验看门狗必须在 aboutToDisappear 清掉，离开页面后不能空转。
 */

import { STORE_SAFE_TOP, STORE_THEME_PRIMARY, STORE_THEME_ON, STORE_THEME_DEEP } from '../common/Constants';
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
import {
  makeBiliSegmentColors,
  SegmentColors,
  ButtonMaterialModifier,
  makeButtonMaterialModifier
} from '../utils/HeaderBarMaterial';
import {
  BiliApiError,
  generateQrLogin,
  pollQrLogin,
  QrLoginTicket,
  QrPollResult,
  fetchTvQrAuthCode,
  pollTvQrLogin,
  fetchWebKey,
  loginByPwd,
  sendAppSmsCode,
  loginByAppSms,
  fetchSafeCenterInfo,
  fetchSafeCenterPreCapture,
  sendSafeCenterSms,
  verifySafeCenterSms,
  fetchOauth2Token,
  validateWebCookie,
  GeetestProof,
  TvQrTicket,
  TvQrPollResult,
  TvTokenResult,
  PwdLoginResult,
  AppSmsSendResult,
  SafeCenterInfo,
  SafeCenterCapture,
  WebKeyInfo,
  LOGIN_DOMAIN_HD,
  LOGIN_DOMAIN_ANDROID
} from '../api/BilibiliApi';
import { applyQrSuccess, applyAppLogin, applyImportedCookie, refreshLoginUser, getLoginUser, LoginUser } from '../service/LoginStore';
import { AppPreferences } from '../preferences/AppPreferences';
import { AudioQuality, AppSettings } from '../model/MusicModels';
import { DialPrefix, DIAL_PREFIXES, findDialPrefix } from '../model/DialPrefixData';
import { HttpUtil } from '../utils/HttpUtil';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';
import { BarNarrowShell } from '../components/BarNarrowShell';
// 页面版式：全应用统一的 inset 分组卡片 / 区块标题 / 区块脚注
import { InsetCard, SectionHeader, SectionFooter } from '../components/InsetCardGroup';

/** 网页二维码轮询间隔（ms）：B 站网页版同款节奏，太快会被风控 */
const QR_POLL_INTERVAL_MS: number = 2000;
/** TV 扫码轮询间隔（ms）：passport-tv-login 官方客户端节奏（PiliPlus 同款 1s） */
const TV_POLL_INTERVAL_MS: number = 1000;

/**
 * 二维码「早失效」判定阈值（ms）：
 * 正常有效期 ~180s；存活 <30s 且从未进入已扫码态 = 异常作废。
 * poll 由 BilibiliApi.pollQrLogin 将 key 内联 URL（queryParams 空参会被答 86038）。
 * 本判定与自动换码是安全网：异常早失效（真风控等）时自动换码重试
 * （见 pollOnce 86038 分支），超限转手动蒙层。
 */
const QR_EARLY_INVALIDATE_MS: number = 30000;
/** 早失效自动刷新次数上限：防止服务端持续作废时无限「3 秒换一张」循环 */
const QR_AUTO_REFRESH_MAX: number = 3;
/** 早失效自动刷新退避序列（ms）：逐次拉长，给风控窗口冷却时间 */
const QR_AUTO_REFRESH_DELAYS_MS: number[] = [1000, 3000, 7000];

/** 页签下标（刻意用数字常量而不是 enum：.ets 里声明 enum 会连带报 SDK 解析错误） */
const TAB_PWD: number = 0;
const TAB_SMS: number = 1;
const TAB_QR: number = 2;
const TAB_COOKIE: number = 3;

/** 扫码页签子模式：TV 扫码（默认）/ 网页扫码 */
const QR_MODE_TV: string = 'tv';
const QR_MODE_WEB: string = 'web';

/** 密码页签阶段：表单 / 安心中心（风控短信验证） */
const PWD_STAGE_FORM: string = 'form';
const PWD_STAGE_SAFE: string = 'safe';
/** 安心中心子步骤：发短信 / 输验证码 */
const SC_PHASE_SMS: string = 'sms';
const SC_PHASE_CODE: string = 'code';

/**
 * 标题栏滑块切换行（密码登录 / 短信登录 / 扫码登录 / Cookie）固定高：
 * 段切换 Column 40 + 行 padding bottom 4 = 44。
 * bottomBuilder 高度不自适应（官方约束），必须与行内容定高一致。
 */
const LOGIN_TABS_ROW_HEIGHT: number = 44;

// ── 页面版式 token（全部对齐「inset 分组卡片」体系，见 components/InsetCardGroup）──
/** 表单行高（vp）：与设置页行高同口径（28 图标片 + 上下呼吸），整行可点即聚焦 */
const FORM_FIELD_H: number = 56;
/** 行首图标片边长 / 圆角（vp）：设置页 ENTRY 图标片同款 28 / 7 */
const FORM_ICON_SIZE: number = 28;
const FORM_ICON_RADIUS: number = 7;
/** 图标片与输入文字的水平间距（vp） */
const FORM_ICON_GAP: number = 12;
/** 行分隔线左缩进 = 卡片内边距 16 + 图标 28 + 间距 12（文字起点对齐） */
const FORM_DIVIDER_INSET: number = 56;
/** 主按钮高度 / 圆角（vp）：圆角与分组卡片同 12，全宽 CTA 统一 48 高 */
const CTA_HEIGHT_VP: number = 48;
const CTA_RADIUS_VP: number = 12;
/** 二维码边长（vp）：比旧版 220 收一档，给上下说明文字留呼吸 */
const QR_SIZE_VP: number = 200;

const PHONE_PATTERN: RegExp = /^\d{5,15}$/;
const CODE_PATTERN: RegExp = /^\d{4,8}$/;
const PHASE_PHONE: string = 'input_phone';
const PHASE_CODE: string = 'input_code';

/** 极验层发起流程（结果分发去向）：密码 -105 / App 短信 needGeetest / 安心中心人机预验证 */
const GEETEST_CONSUMER_PWD: string = 'pwd';
const GEETEST_CONSUMER_APPSMS: string = 'appsms';
const GEETEST_CONSUMER_SAFE: string = 'safecenter';

/**
 * 极验加载看门狗（ms）：到点仍没收到 `gtready` / `gtok` 就判加载失败、显示重试出口。
 *
 * 为什么必须有：极验 fullpage 面板的失败是**静默**的（loader 网络错误、脚本被拦、
 * 域校验不通过都只是"什么都没有"），不设超时用户就是一片空白、永远等不到回调。
 * 取 12s：gettype + 两次 js 加载在弱网下也要留余量。
 */
const GEETEST_WATCHDOG_MS: number = 12000;
/**
 * 极验页的「假 https 地址」：只用于给 Web 一个**真实 https 上下文**
 * （origin = https://www.bilibili.com），内容由 `onInterceptRequest` 直接返回。
 *
 * 为什么不用 `loadData`：真机实测 `loadData(base64)` 在
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
 * 从 url 的 query 里取参数值（riskUrl 的 tmp_token / request_id / source 解析用）。
 * BilibiliApi 里的同款 queryParam 未导出，这里页面级复制一份；找不到返回空串。
 */
function urlQueryParam(url: string, key: string): string {
  const queryIndex: number = url.indexOf('?');
  if (queryIndex < 0) {
    return '';
  }
  const pairs: string[] = url.substring(queryIndex + 1).split('&');
  const prefix: string = `${key}=`;
  for (let i: number = 0; i < pairs.length; i++) {
    if (pairs[i].indexOf(prefix) === 0) {
      return pairs[i].substring(prefix.length);
    }
  }
  return '';
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
 * 要点：
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
        setStatus('验证通过，正在提交…');
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
          // WebView 里没有 ArkTS 侧模块，只能用 console（onConsole 收）
          console.log('geetest ready, verify=' + typeof captchaObj.verify);
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

  /** 主题色主色：二维码刷新图标、登录按钮底色与提示文字跟随切色刷新 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /** 主题色深字色：登录按钮文字跟随切色刷新 */
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /** 主题色深强调色：白底小字强调（过期/失败状态行、覆盖层取消文字），对比度达标（设计规范双粉策略） */
  @StorageProp(STORE_THEME_DEEP) themeDeep: string = '#C2185B';
  /** 按钮沉浸光感材质修饰器：与全应用兄弟页按钮同款（低版本/不支持时 no-op，链式实色兜底） */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 滚动控制器：bindToScrollable 绑给 HDS 标题栏，滚动模糊效果依赖此绑定 */
  private loginScroller: Scroller = new Scroller();

  /**
   * 自绘顶栏渐变模糊层进度更新器 + 校准（SearchPage 原型推广，四页签同款）：
   * onDidScroll / onScrollStop 命令式驱动 opacity（不标
   * @State，滚动高频回调零重建）；yOffset 0 → TITLE_BLUR_END_VP 线性映射
   * 0 → 1（updater 内截断，边缘回弹负偏移归零为死区）。
   */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.loginScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }
  /**
   * 子页转场的横移量（相对页面自身宽度）：常驻 '0%'，
   * 转场代理里按 push/pop 方向临时改写（见 navTransitionDelegate，与 AboutPage 同款）。
   */
  @State navTransX: string = '0%';

  /** 当前页签：0 = 密码登录，1 = 短信登录，2 = 扫码登录（默认），3 = Cookie */
  @State tab: number = TAB_QR;
  /** 页签滑块条目（密码登录 / 短信登录 / 扫码登录 / Cookie）：静态一次构造 */
  private segmentItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: '密码登录' },
    { text: '短信登录' },
    { text: '扫码登录' },
    { text: 'Cookie' }
  ]);
  /** 扫码页签子切换条目（TV 扫码 / 网页扫码）：静态一次构造 */
  private qrModeItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: 'TV 扫码' },
    { text: '网页扫码' }
  ]);
  /** 分段按钮主题色配色组：每次渲染现取（读 AppStorage），缓存成字段切色不刷新 */
  private segColors(): SegmentColors {
    return makeBiliSegmentColors();
  }

  /**
   * 主题色 10% 透明底（`#RRGGBB` → `#1ARRGGBB`）：行首图标片 / 区号胶囊的底色。
   * 与设置页 ENTRY 图标片同一套配方，换主题色时随 themePrimary 即时跟随。
   */
  private iconTint(): string {
    const hex: string = this.themePrimary;
    if (hex.length === 7 && hex.charAt(0) === '#') {
      return `#1A${hex.substring(1)}`;
    }
    return '#1AFB7299';
  }

  // ── 扫码页签状态 ──
  /** 扫码子模式：QR_MODE_TV（默认）/ QR_MODE_WEB */
  @State qrMode: string = QR_MODE_TV;

  /** 网页二维码内容（passport 下发的 url）；为空表示还没取到 */
  @State qrUrl: string = '';
  /** 网页扫码状态机：loading / ready / scanned / expired */
  @State qrPhase: string = 'loading';
  /** 网页扫码状态文案：跟随 qrPhase 与轮询结果更新 */
  @State statusText: string = '正在获取二维码…';

  /** 轮询凭据（generateQrLogin 下发，poll 必带） */
  private qrcodeKey: string = '';
  private pollTimer: number = -1;
  /** 单次轮询进行中标记：防止慢响应叠帧轮询（上一发没回来又发下一发） */
  private polling: boolean = false;
  /** 二维码生成时刻（ms）：86038 时算存活时长，用于区分「自过期」与「扫码后被作废」 */
  private qrGeneratedAt: number = 0;
  /** 早失效自动刷新已用次数（页内不重置，超限转手动；见 pollOnce 86038 分支） */
  private autoRefreshCount: number = 0;
  /** 早失效自动刷新定时器 id（-1 = 未启动；aboutToDisappear 成对清理） */
  private autoRefreshTimer: number = -1;

  /** TV 二维码内容（passport-tv-login 下发的 url）；为空表示还没取到 */
  @State tvQrUrl: string = '';
  /** TV 扫码状态机：loading / ready / scanned / expired */
  @State tvQrPhase: string = 'loading';
  /** TV 扫码状态文案 */
  @State tvStatusText: string = '正在获取二维码…';
  /** TV 轮询凭据（fetchTvQrAuthCode 下发的 auth_code，poll 必带） */
  private tvAuthCode: string = '';
  private tvPollTimer: number = -1;
  /** TV 单次轮询进行中标记：防止慢响应叠帧轮询 */
  private tvPolling: boolean = false;

  // ── 短信页签状态（App 端短信，两步状态机） ──
  /** 两步状态机：PHASE_PHONE / PHASE_CODE */
  @State phase: string = PHASE_PHONE;
  @State phone: string = '';
  @State smsCode: string = '';
  @State phoneError: string = '';
  @State codeError: string = '';
  /** 短信请求进行中（发验证码 / 登录）：按钮禁用与防重入 */
  @State busySms: boolean = false;
  /** 已选区号条目 id（DialPrefixData 主键，默认中国大陆 86） */
  @State selectedDialId: number = 1;
  /** 区号选择半模态可见（bindSheet 双向绑定） */
  @State dialSheetVisible: boolean = false;
  /** 区号搜索关键字（名称 / 区号匹配） */
  @State dialSearch: string = '';
  /** sendAppSmsCode 下发的一次性凭据，loginByAppSms 必带 */
  private smsCaptchaKey: string = '';
  /**
   * 短信登录域：LOGIN_DOMAIN_HD（默认，与 TV 扫码 / 密码同域）/
   * LOGIN_DOMAIN_ANDROID（粉版，见下方开关行说明）。
   * send 与 login 必须同域（captcha_key 是域内会话凭据）；
   * 开关只在 PHASE_PHONE 渲染，进 PHASE_CODE 后不再可变。
   */
  @State smsDomain: string = LOGIN_DOMAIN_HD;

  // ── 密码页签状态 ──
  /** 密码页签阶段：PWD_STAGE_FORM 表单 / PWD_STAGE_SAFE 安心中心（风控） */
  @State pwdStage: string = PWD_STAGE_FORM;
  @State pwdUsername: string = '';
  @State pwdPassword: string = '';
  @State pwdError: string = '';
  @State busyPwd: boolean = false;
  /** doPwdLogin 时缓存的盐 + PEM 公钥（极验通过后 retryPwdWithProof 复用） */
  private pwdWebKey: WebKeyInfo | null = null;

  // ── 安心中心（密码 status=2 风控）状态 ──
  /** 安心中心子步骤：SC_PHASE_SMS 发短信 / SC_PHASE_CODE 输验证码 */
  @State scPhase: string = SC_PHASE_SMS;
  /** 打码手机号（fetchSafeCenterInfo 下发，仅展示） */
  @State scHideTel: string = '';
  @State scCode: string = '';
  @State scError: string = '';
  @State busySafe: boolean = false;
  /** riskUrl 解析的四件套：tmp_code（请求参数叫 tmp_code，取值是 tmp_token） */
  private scTmpCode: string = '';
  private scRequestId: string = '';
  private scSource: string = '';
  /** 风控页 url：sendSafeCenterSms / verifySafeCenterSms 的 Referer（B 站校验来源） */
  private scReferer: string = '';
  /** preCapture 下发的极验 challenge：proof.challenge 用它而非滑块回传值（PiliPlus 同款） */
  private scGeeChallenge: string = '';
  /** sendSafeCenterSms 下发的一次性凭据，verify 必带 */
  private scCaptchaKey: string = '';

  // ── Cookie 页签状态 ──
  @State cookieText: string = '';
  @State cookieError: string = '';
  @State busyCookie: boolean = false;

  // ── 整屏极验层（泛化，流程无关） ──
  /** 极验整屏覆盖层是否挂载（密码 -105 / 短信 needGeetest / 安心中心人机预验证共用） */
  @State geetestVisible: boolean = false;
  /** 极验面板是否已就绪（收到 `gtready`）：控制「正在加载…」提示与看门狗 */
  @State geetestReady: boolean = false;
  /** 极验加载失败原因（非空 = 覆盖层显示失败态 + 重试出口，绝不留死白屏） */
  @State geetestError: string = '';
  /** 本轮极验的发起流程（结果分发用）：GEETEST_CONSUMER_* */
  private geetestConsumer: string = '';
  /** 本轮极验随 gt/challenge 一起下发的 recaptcha_token（重发请求必带） */
  private pendingRecaptchaToken: string = '';
  /** 极验页内容：mountGeetest 时用 gt/challenge 构建 */
  private geetestHtml: string = '';
  /** 本轮极验页地址（真实 https + t 防缓存；内容由 onInterceptRequest 返回） */
  private geetestPageUrl: string = '';
  /** 拦截未命中时的应急回落是否已用掉（data: 导航，每轮只用一次） */
  private geetestFallbackUsed: boolean = false;
  /** 每次挂载极验层都换新实例（同一 controller 不能二次绑定 Web 节点） */
  private webController: web_webview.WebviewController = new web_webview.WebviewController();
  private bridge: GeetestBridge = new GeetestBridge();
  /** 加载看门狗定时器 id（-1 = 未启动） */
  private watchdogTimer: number = -1;
  /** 本轮极验结果是否已消费（proxy 与 title 双通道会重复投递，必须一次性） */
  private geetestConsumed: boolean = false;

  aboutToAppear(): void {
    // 挂载前先存当前偏移对应的进度（updater 未挂载只存值，
    // 挂载时 initializeModifier 补上），防「已滚过再进页」首帧缺模糊。
    this.syncTopBlurProgress();
    this.bridge.onGeetestResult = (message: string): void => {
      this.handleGeetestResult(message);
    };
    this.startTvQrLogin();
  }

  aboutToDisappear(): void {
    this.stopPolling();
    this.stopTvPolling();
    this.clearAutoRefresh();
    this.clearWatchdog();
    // 页面销毁后桥对象仍被 Web 持有：断开回调，避免迟到的回调打到已卸载的组件
    this.bridge.onGeetestResult = (_message: string): void => {
    };
  }

  /**
   * 滑块切页签：极验层开着时先取消（看门狗 / WebView 状态不能跟着页签潜伏，
   * 否则后台空转或迟到回调打到错误的流程上）。
   */
  private switchTab(index: number): void {
    if (index === this.tab) {
      return;
    }
    if (this.geetestVisible) {
      this.cancelGeetest();
    }
    this.tab = index;
  }

  /** 扫码页签内 TV ↔ 网页子切换：先停旧模式轮询再启新模式 */
  private switchQrMode(mode: string): void {
    if (mode === this.qrMode) {
      return;
    }
    if (this.qrMode === QR_MODE_TV) {
      this.stopTvPolling();
    } else {
      this.stopPolling();
      this.clearAutoRefresh();
    }
    this.qrMode = mode;
    if (mode === QR_MODE_TV) {
      this.startTvQrLogin();
    } else {
      this.startQrLogin();
    }
  }

  // ── 网页扫码逻辑（原实现整体保留） ──

  /** 重新生成网页二维码并开始新一轮轮询（切到网页模式 / 过期刷新 / 早失效自动刷新共用） */
  private startQrLogin(): void {
    // 先清掉 pending 的自动刷新：用户点击 expired 蒙层手动刷新时，
    // 不能让迟到的自动刷新再换一张码（打断扫码确认）
    this.clearAutoRefresh();
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

  /** 清理早失效自动刷新定时器（startQrLogin 重入 / 页面销毁共用） */
  private clearAutoRefresh(): void {
    if (this.autoRefreshTimer !== -1) {
      clearTimeout(this.autoRefreshTimer);
      this.autoRefreshTimer = -1;
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
        const aliveMs: number = Date.now() - this.qrGeneratedAt;
        console.warn(`QR expired: aliveMs=${aliveMs}` +
          `, lastPhase=${this.qrPhase}`);
        // 早失效自愈：被风控提前作废（存活 <30s 且
        // 从未扫码）时自动换码重试，退避逐次拉长、上限 QR_AUTO_REFRESH_MAX 次；
        // 超限、正常 180s 自过期、扫码后作废仍走手动蒙层。
        if (aliveMs < QR_EARLY_INVALIDATE_MS && this.qrPhase !== 'scanned'
          && this.autoRefreshCount < QR_AUTO_REFRESH_MAX) {
          this.autoRefreshCount++;
          const delayIdx: number = this.autoRefreshCount - 1;
          const delay: number = delayIdx < QR_AUTO_REFRESH_DELAYS_MS.length
            ? QR_AUTO_REFRESH_DELAYS_MS[delayIdx]
            : QR_AUTO_REFRESH_DELAYS_MS[QR_AUTO_REFRESH_DELAYS_MS.length - 1];
          console.warn(`QR early-invalidate: auto refresh ` +
            `${this.autoRefreshCount}/${QR_AUTO_REFRESH_MAX} in ${delay}ms`);
          this.statusText = `二维码被提前失效，正在自动刷新` +
            `（${this.autoRefreshCount}/${QR_AUTO_REFRESH_MAX}）`;
          this.autoRefreshTimer = setTimeout((): void => {
            this.autoRefreshTimer = -1;
            this.startQrLogin();
          }, delay);
          return;
        }
        this.qrPhase = 'expired';
        this.statusText = '二维码已过期';
      } else {
        // 86101 等待扫码；手机上取消确认后也会回到这里（从 scanned 退回 ready）
        this.qrPhase = 'ready';
        this.statusText = '请使用哔哩哔哩客户端扫码';
      }
    } catch (e) {
      // 单次轮询失败（瞬态断网）跳过本轮，下个周期再试；必须留痕
      //（HTTP 4xx/5xx 在 HttpUtil 里是先抛错后打日志，不留痕会丢关键证据）
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.warn(`pollOnce failed: ${msg}`);
    } finally {
      this.polling = false;
    }
  }

  /** 网页扫码成功落库：解析 Cookie → 持久化 → 刷新用户信息 → toast + 返回 */
  private async finishLogin(callbackUrl: string, responseCookies: string, refreshToken: string): Promise<void> {
    this.statusText = '登录成功';
    try {
      await applyQrSuccess(callbackUrl, responseCookies, refreshToken);
      await refreshLoginUser();
      const upgraded: boolean = await this.applyVipLosslessQuality();
      this.finishPopToast(upgraded ? '登录成功，已切换为无损音质' : '登录成功', upgraded);
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

  // ── TV 扫码逻辑 ──

  /** 重新生成 TV 二维码并开始新一轮 1s 轮询（首进页面 / 过期刷新共用） */
  private startTvQrLogin(): void {
    this.stopTvPolling();
    this.tvQrPhase = 'loading';
    this.tvStatusText = '正在获取二维码…';
    fetchTvQrAuthCode()
      .then((ticket: TvQrTicket): void => {
        this.tvQrUrl = ticket.qrUrl;
        this.tvAuthCode = ticket.authCode;
        this.tvQrPhase = 'ready';
        this.tvStatusText = '请使用哔哩哔哩客户端扫码';
        this.startTvPolling();
      })
      .catch((e: BusinessError): void => {
        this.tvQrPhase = 'expired';
        this.tvStatusText = `获取二维码失败：${e.message}`;
      });
  }

  private startTvPolling(): void {
    if (this.tvPollTimer !== -1) {
      return;
    }
    this.tvPollTimer = setInterval((): void => {
      this.pollTvOnce();
    }, TV_POLL_INTERVAL_MS);
  }

  private stopTvPolling(): void {
    if (this.tvPollTimer !== -1) {
      clearInterval(this.tvPollTimer);
      this.tvPollTimer = -1;
    }
  }

  /**
   * TV 轮询单次：0 成功 / 86090 已扫待确认 / 86038 过期 / 86039 等待扫码（TV 专属未扫码码）。
   * 与网页码不同：TV 码没有「早失效自愈」，86038 一律转手动刷新。
   */
  private async pollTvOnce(): Promise<void> {
    if (this.tvPolling || this.tvQrPhase === 'expired' || this.tvAuthCode.length === 0) {
      return;
    }
    this.tvPolling = true;
    try {
      const result: TvQrPollResult = await pollTvQrLogin(this.tvAuthCode);
      if (result.status === 0) {
        this.stopTvPolling();
        const token: TvTokenResult | null = result.token;
        if (token === null) {
          console.warn('tv qr poll: status 0 but token missing');
          this.tvQrPhase = 'expired';
          this.tvStatusText = '登录失败，点击二维码重试';
          return;
        }
        await this.finishAppLogin(token);
      } else if (result.status === 86090) {
        this.tvQrPhase = 'scanned';
        this.tvStatusText = '已扫码，请在手机上确认';
      } else if (result.status === 86038) {
        this.stopTvPolling();
        this.tvQrPhase = 'expired';
        this.tvStatusText = '二维码已过期';
      } else {
        // 86039 等待扫码（TV 专属）；手机上取消确认后也会回到等待/已扫
        this.tvQrPhase = 'ready';
        this.tvStatusText = '请使用哔哩哔哩客户端扫码';
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.warn(`pollTvOnce failed: ${msg}`);
    } finally {
      this.tvPolling = false;
    }
  }

  // ── App 端登录公共收尾 ──

  /**
   * 登录成功后的收尾：**先退栈、再提示**。
   *
   * `showAppToast` 紧挨着 pop 调用会被一起收掉：toast 挂在当前页的 UIContext 上，
   * 页面一销毁就跟着消失（日志表现 `closeToast(...) → Toast not found`）。
   * 所以提示延迟到退栈动画之后再发。登录只有一层路由，
   * pop 一层即回到来源页（设置 / 关注 / 收藏同步等）。
   */
  private finishPopToast(text: string, longDuration: boolean = false): void {
    console.info(`login done: pop nav stack, size=${NavStackHolder.stack.size()}`);
    NavStackHolder.stack.pop();
    setTimeout((): void => {
      showAppToast(text, longDuration ? 2200 : 1800);
    }, 200);
  }

  /**
   * 大会员登录福利：登录成功后若为大会员/年度大会员（vipStatus===1），
   * 把播放音质与下载音质自动提升为「无损」。仅登录成功时设置一次；
   * 用户之后手动调低不再干预（产品决策，见方案确认记录）。
   * @returns 是否实际修改了设置（用于决定 toast 文案）
   */
  private async applyVipLosslessQuality(): Promise<boolean> {
    const user: LoginUser | null = getLoginUser();
    if (user === null || user.vipStatus !== 1) {
      return false;
    }
    const settings: AppSettings = AppPreferences.getSettings();
    if (settings.playQuality === AudioQuality.LOSSLESS &&
      settings.downloadQuality === AudioQuality.LOSSLESS) {
      return false;
    }
    settings.playQuality = AudioQuality.LOSSLESS;
    settings.downloadQuality = AudioQuality.LOSSLESS;
    await AppPreferences.saveSettings(settings);
    return true;
  }

  /**
   * App 端登录链路公共收尾（TV 扫码 / 密码 / App 短信 / 安心中心）：
   * applyAppLogin 落库 → refreshLoginUser → 先退栈再提示。
   * @returns false = 落库 / 刷新失败，由调用方回填各自失败态
   */
  private async finishAppLogin(token: TvTokenResult): Promise<boolean> {
    try {
      await applyAppLogin(token.cookieString, token.accessToken, token.refreshToken);
      await refreshLoginUser();
      const upgraded: boolean = await this.applyVipLosslessQuality();
      this.finishPopToast(upgraded ? '登录成功，已切换为无损音质' : '登录成功', upgraded);
      return true;
    } catch (e) {
      // 落库失败（cookie_info 缺身份字段 / 存储异常）：诊断只记长度，不输出凭据值
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.error(`app login finish failed: ${msg} (cookiesLen=${token.cookieString.length})`);
      return false;
    }
  }

  // ── 短信页签逻辑（App 端短信） ──

  /** 已选区号的国际电话区号（请求 cid 参数） */
  private selectedDialCountryId(): number {
    const dial: DialPrefix | null = findDialPrefix(this.selectedDialId);
    return dial !== null ? dial.countryId : 86;
  }

  /** 区号搜索过滤（名称 / 区号前缀匹配，空关键字返回全表） */
  private filteredDialPrefixes(): DialPrefix[] {
    const kw: string = this.dialSearch.trim().toLowerCase();
    if (kw.length === 0) {
      return DIAL_PREFIXES;
    }
    const out: DialPrefix[] = [];
    for (let i: number = 0; i < DIAL_PREFIXES.length; i++) {
      const item: DialPrefix = DIAL_PREFIXES[i];
      if (item.cname.toLowerCase().indexOf(kw) >= 0 ||
        String(item.countryId).indexOf(kw) >= 0) {
        out.push(item);
      }
    }
    return out;
  }

  /** 第 1 步：校验手机号 → 发送 App 短信验证码（常态免极验直达） */
  private requestSmsCode(): void {
    // 重入守卫：busy 在途（按钮禁用要等重渲染，同帧双击可穿透）或极验层开着时
    // 不再开一轮，否则会在挂载中的 Web 节点底下把 webController 换成未关联的新实例
    if (this.busySms || this.geetestVisible) {
      return;
    }
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
    this.busySms = true;
    this.sendSmsWithProof(tel, null, '');
  }

  /**
   * 发送 App 短信验证码（首发 / 极验通过后带 proof 重发共用）。
   * needGeetest 时挂极验层（GEETEST_CONSUMER_APPSMS），通过后回到这里重发；
   * recaptcha_url 形态缺 gt/challenge 参数时用 preCapture 兜底（PiliPlus getCaptcha 同款）。
   */
  private sendSmsWithProof(tel: string, proof: GeetestProof | null, recaptchaToken: string): void {
    const cid: number = this.selectedDialCountryId();
    sendAppSmsCode(tel, cid, proof, recaptchaToken, this.smsDomain)
      .then((result: AppSmsSendResult): void => {
        if (!result.needGeetest) {
          if (result.captchaKey.length === 0) {
            // 防御：成功帧缺 captcha_key，退回第 1 步重来
            this.busySms = false;
            this.phoneError = '发送验证码失败，请重试';
            return;
          }
          this.smsCaptchaKey = result.captchaKey;
          this.busySms = false;
          this.phase = PHASE_CODE;
          showAppToast('验证码已发送', 1800);
          return;
        }
        this.busySms = false;
        if (result.gt.length > 0) {
          this.mountGeetest(GEETEST_CONSUMER_APPSMS, result.gt, result.challenge, result.recaptchaToken);
        } else {
          fetchSafeCenterPreCapture()
            .then((cap: SafeCenterCapture): void => {
              this.mountGeetest(GEETEST_CONSUMER_APPSMS, cap.gt, cap.challenge, cap.recaptchaToken);
            })
            .catch((e: BusinessError): void => {
              this.phoneError = `获取安全验证参数失败：${e.message}`;
            });
        }
      })
      .catch((e: BusinessError): void => {
        this.busySms = false;
        const biliCode: number = errorBiliCode(e);
        if (biliCode === 86211 || biliCode === -105) {
          this.phoneError = '图形验证已过期，请重新获取验证码';
        } else {
          this.phoneError = `发送验证码失败：${e.message}`;
        }
      });
  }

  /** 第 2 步：短信验证码换登录凭据 → 落库 → 自动返回 */
  private doSmsLogin(): void {
    const code: string = this.smsCode.trim();
    if (code.length === 0) {
      this.codeError = '请输入验证码';
      return;
    }
    if (!CODE_PATTERN.test(code)) {
      this.codeError = '验证码格式不正确';
      return;
    }
    if (this.smsCaptchaKey.length === 0) {
      // 正常走不到（进本阶段前必有 captchaKey），防御性回退
      this.codeError = '';
      this.phase = PHASE_PHONE;
      return;
    }
    this.codeError = '';
    this.busySms = true;
    const tel: string = this.phone.trim();
    const cid: number = this.selectedDialCountryId();
    fetchWebKey()
      .then(async (webKey: WebKeyInfo): Promise<void> => {
        const token: TvTokenResult = await loginByAppSms(tel, cid, code, this.smsCaptchaKey, webKey, this.smsDomain);
        const ok: boolean = await this.finishAppLogin(token);
        if (!ok) {
          this.busySms = false;
          this.codeError = '登录失败，请重试';
        }
      })
      .catch((e: BusinessError): void => {
        this.busySms = false;
        // 诊断只记异常消息（BiliApiError 消息含业务码，不含凭据值）
        console.warn(`sms login failed: ${e.message}`);
        this.codeError = e.message.length > 0 ? e.message : '登录失败，请检查验证码';
      });
  }

  // ── 密码页签逻辑 ──

  /** 密码登录：fetchWebKey 取盐与公钥 → loginByPwd → 按 status 分流（0 / 2 风控 / -105 极验） */
  private doPwdLogin(): void {
    if (this.busyPwd || this.geetestVisible) {
      return;
    }
    const username: string = this.pwdUsername.trim();
    const password: string = this.pwdPassword;
    if (username.length === 0) {
      this.pwdError = '请输入账号';
      return;
    }
    if (password.length === 0) {
      this.pwdError = '请输入密码';
      return;
    }
    this.pwdError = '';
    this.busyPwd = true;
    fetchWebKey()
      .then(async (webKey: WebKeyInfo): Promise<void> => {
        this.pwdWebKey = webKey;
        const result: PwdLoginResult = await loginByPwd(username, password, webKey, null, '');
        this.handlePwdResult(result);
      })
      .catch((e: BusinessError): void => {
        this.busyPwd = false;
        this.pwdError = `登录失败：${e.message}`;
      });
  }

  /** loginByPwd 结果分流：0 落库 / 2 安心中心 / -105 极验 / 其它报错 */
  private handlePwdResult(result: PwdLoginResult): void {
    if (result.status === 0 && result.token !== null) {
      const token: TvTokenResult = result.token;
      this.finishAppLogin(token).then((ok: boolean): void => {
        if (!ok) {
          this.busyPwd = false;
          this.pwdError = '登录失败，请重试';
        }
      });
      return;
    }
    this.busyPwd = false;
    if (result.status === 2) {
      this.enterSafeCenter(result.riskUrl);
      return;
    }
    if (result.status === -105) {
      if (result.gt.length === 0 || result.challenge.length === 0) {
        this.pwdError = '安全验证参数缺失，请重试';
        return;
      }
      this.mountGeetest(GEETEST_CONSUMER_PWD, result.gt, result.challenge, result.recaptchaToken);
      return;
    }
    this.pwdError = result.message.length > 0 ? result.message : '登录失败';
  }

  /** 极验通过后带 proof 重发密码登录（webKey 复用首轮缓存的盐 + 公钥） */
  private retryPwdWithProof(proof: GeetestProof): void {
    if (this.pwdWebKey === null) {
      this.pwdError = '登录超时，请重试';
      return;
    }
    const username: string = this.pwdUsername.trim();
    const password: string = this.pwdPassword;
    this.busyPwd = true;
    loginByPwd(username, password, this.pwdWebKey, proof, this.pendingRecaptchaToken)
      .then((result: PwdLoginResult): void => {
        this.handlePwdResult(result);
      })
      .catch((e: BusinessError): void => {
        this.busyPwd = false;
        this.pwdError = `登录失败：${e.message}`;
      });
  }

  // ── 安心中心（密码 status=2 风控）逻辑 ──

  /**
   * 进入安心中心：解析 riskUrl 的 tmp_token / request_id / source（verify 必带），
   * 拉取打码手机号展示。riskUrl 本体作为后续请求的 Referer。
   */
  private enterSafeCenter(riskUrl: string): void {
    this.scTmpCode = urlQueryParam(riskUrl, 'tmp_token');
    this.scRequestId = urlQueryParam(riskUrl, 'request_id');
    this.scSource = urlQueryParam(riskUrl, 'source');
    this.scReferer = riskUrl;
    this.scPhase = SC_PHASE_SMS;
    this.scHideTel = '';
    this.scCode = '';
    this.scError = '';
    this.scGeeChallenge = '';
    this.scCaptchaKey = '';
    this.busySafe = false;
    this.pwdStage = PWD_STAGE_SAFE;
    if (this.scTmpCode.length === 0) {
      this.scError = '风控信息缺失，请返回重试';
      return;
    }
    fetchSafeCenterInfo(this.scTmpCode)
      .then((info: SafeCenterInfo): void => {
        this.scHideTel = info.hideTel;
      })
      .catch((e: BusinessError): void => {
        this.scError = `获取安全验证信息失败：${e.message}`;
      });
  }

  /** 安心中心发短信：preCapture 取极验参数 → 挂极验层（GEETEST_CONSUMER_SAFE） */
  private sendSafeCenterCode(): void {
    if (this.busySafe || this.geetestVisible) {
      return;
    }
    if (this.scTmpCode.length === 0) {
      this.exitSafeCenter();
      return;
    }
    this.scError = '';
    this.busySafe = true;
    fetchSafeCenterPreCapture()
      .then((cap: SafeCenterCapture): void => {
        this.busySafe = false;
        if (cap.gt.length === 0 || cap.challenge.length === 0) {
          this.scError = '获取人机验证参数失败，请重试';
          return;
        }
        // proof.challenge 用 preCapture 下发的这份（非滑块回传值，PiliPlus 同款）
        this.scGeeChallenge = cap.challenge;
        this.mountGeetest(GEETEST_CONSUMER_SAFE, cap.gt, cap.challenge, cap.recaptchaToken);
      })
      .catch((e: BusinessError): void => {
        this.busySafe = false;
        this.scError = `获取人机验证参数失败：${e.message}`;
      });
  }

  /** 极验通过 → sendSafeCenterSms（风控 Referer + preCapture 极验四件套） */
  private completeSafeCenterSms(proofSlider: GeetestProof): void {
    const proof: GeetestProof = {
      challenge: this.scGeeChallenge.length > 0 ? this.scGeeChallenge : proofSlider.challenge,
      validate: proofSlider.validate,
      seccode: proofSlider.seccode
    };
    this.busySafe = true;
    sendSafeCenterSms(this.scTmpCode, proof, this.pendingRecaptchaToken, this.scReferer)
      .then((captchaKey: string): void => {
        this.busySafe = false;
        if (captchaKey.length === 0) {
          this.scError = '发送短信验证码失败，请重试';
          return;
        }
        this.scCaptchaKey = captchaKey;
        this.scPhase = SC_PHASE_CODE;
      })
      .catch((e: BusinessError): void => {
        this.busySafe = false;
        this.scError = e.message.length > 0 ? e.message : '发送短信验证码失败';
      });
  }

  /** 安心中心提交短信验证码：verify → oauth code → fetchOauth2Token → 落库 */
  private confirmSafeCenter(): void {
    if (this.busySafe) {
      return;
    }
    const code: string = this.scCode.trim();
    if (code.length === 0) {
      this.scError = '请输入短信验证码';
      return;
    }
    if (this.scCaptchaKey.length === 0) {
      // 正常走不到（进本步骤前必有 captchaKey），防御性回退
      this.scPhase = SC_PHASE_SMS;
      return;
    }
    this.scError = '';
    this.busySafe = true;
    verifySafeCenterSms(this.scTmpCode, code, this.scRequestId, this.scSource, this.scCaptchaKey, this.scReferer)
      .then(async (oauthCode: string): Promise<void> => {
        if (oauthCode.length === 0) {
          this.busySafe = false;
          this.scError = '验证失败，请重试';
          return;
        }
        const token: TvTokenResult = await fetchOauth2Token(oauthCode);
        const ok: boolean = await this.finishAppLogin(token);
        if (!ok) {
          this.busySafe = false;
          this.scError = '登录失败，请重试';
        }
      })
      .catch((e: BusinessError): void => {
        this.busySafe = false;
        this.scError = e.message.length > 0 ? e.message : '验证失败';
      });
  }

  /** 退出安心中心回到密码表单（清空风控中间态） */
  private exitSafeCenter(): void {
    this.pwdStage = PWD_STAGE_FORM;
    this.scPhase = SC_PHASE_SMS;
    this.scTmpCode = '';
    this.scRequestId = '';
    this.scSource = '';
    this.scReferer = '';
    this.scHideTel = '';
    this.scCode = '';
    this.scGeeChallenge = '';
    this.scCaptchaKey = '';
    this.scError = '';
  }

  // ── Cookie 页签逻辑 ──

  /** Cookie 导入：本地预检 → validateWebCookie → 白名单落库 → 自动返回 */
  private doCookieImport(): void {
    if (this.busyCookie) {
      return;
    }
    const raw: string = this.cookieText.trim();
    if (raw.length === 0) {
      this.cookieError = '请粘贴 Cookie';
      return;
    }
    if (raw.indexOf('SESSDATA=') < 0) {
      this.cookieError = 'Cookie 里缺少 SESSDATA 字段';
      return;
    }
    this.cookieError = '';
    this.busyCookie = true;
    validateWebCookie(raw)
      .then(async (mid: number): Promise<void> => {
        console.info(`cookie import validated: mid=${mid}`);
        await applyImportedCookie(raw);
        await refreshLoginUser();
        const upgraded: boolean = await this.applyVipLosslessQuality();
        this.busyCookie = false;
        this.finishPopToast(upgraded ? '导入成功，已切换为无损音质' : '导入成功', upgraded);
      })
      .catch((e: BusinessError): void => {
        this.busyCookie = false;
        const biliCode: number = errorBiliCode(e);
        if (biliCode === -101) {
          this.cookieError = 'Cookie 已失效，请重新获取';
        } else {
          this.cookieError = `Cookie 校验失败：${e.message}`;
        }
      });
  }

  // ── 整屏极验层（泛化，流程无关） ──

  /**
   * 挂载极验层：构建 HTML + 换新 WebviewController + 重置状态 + 开看门狗。
   * 每次挂载都是全新一轮（旧 challenge 一次性失效），consumer 决定结果分发去向。
   */
  private mountGeetest(consumer: string, gt: string, challenge: string, recaptchaToken: string): void {
    this.geetestConsumer = consumer;
    this.pendingRecaptchaToken = recaptchaToken;
    this.geetestHtml = buildGeetestHtml(gt, challenge);
    this.geetestPageUrl = `${GEETEST_PAGE_URL}?t=${Date.now()}`;
    this.webController = new web_webview.WebviewController();
    this.geetestReady = false;
    this.geetestError = '';
    this.geetestConsumed = false;
    this.geetestFallbackUsed = false;
    this.geetestVisible = true;
    this.startWatchdog();
    // 只记消费者与长度指纹（gt/challenge 均为凭据类值，不落日志）
    console.info(`geetest mount: consumer=${consumer}, htmlLen=${this.geetestHtml.length}`);
  }

  /** 取消极验（覆盖层取消出口 / 切页签 / 页面销毁共用）：验证作废，回发起流程的待命态 */
  private cancelGeetest(): void {
    this.clearWatchdog();
    this.geetestVisible = false;
    this.geetestHtml = '';
    this.geetestReady = false;
    this.geetestError = '';
    this.geetestConsumed = false;
    this.geetestConsumer = '';
  }

  /** 重试极验：卸载后重走发起流程（新 challenge，旧的一次性失效） */
  private retryGeetest(): void {
    const consumer: string = this.geetestConsumer;
    this.cancelGeetest();
    if (consumer === GEETEST_CONSUMER_PWD) {
      this.doPwdLogin();
    } else if (consumer === GEETEST_CONSUMER_APPSMS) {
      this.requestSmsCode();
    } else if (consumer === GEETEST_CONSUMER_SAFE) {
      this.sendSafeCenterCode();
    }
  }

  /**
   * 极验通过（WebView 回传）→ 按 geetestConsumer 分发：
   *   pwd        → retryPwdWithProof（带 proof 重发密码登录）
   *   appsms     → sendSmsWithProof（带 proof 重发短信）
   *   safecenter → completeSafeCenterSms（带 proof 发安心中心短信）
   *
   * 两个来源都会调到这里：`appProxy.postGeetestResult`（主通道）与
   * `onTitleReceive` 的 `gtok:`（兜底通道）—— 用 `geetestConsumed` 保证只消费一次，
   * 否则会重复触发后续请求。
   */
  private handleGeetestResult(message: string): void {
    // 桥回调可能来自非 UI 线程派发，先留痕再处理（出现 UI 不刷新时按此定位）
    console.info(`geetest result: len=${message.length}`);
    if (!this.geetestVisible || this.geetestConsumed) {
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
    const proof: GeetestProof = { challenge: challenge, validate: validate, seccode: seccode };
    const consumer: string = this.geetestConsumer;
    this.geetestVisible = false;
    this.geetestConsumer = '';
    if (consumer === GEETEST_CONSUMER_PWD) {
      this.retryPwdWithProof(proof);
    } else if (consumer === GEETEST_CONSUMER_APPSMS) {
      this.sendSmsWithProof(this.phone.trim(), proof, this.pendingRecaptchaToken);
    } else if (consumer === GEETEST_CONSUMER_SAFE) {
      this.completeSafeCenterSms(proof);
    }
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
      if (!this.geetestVisible || this.geetestReady) {
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
   * 这台设备的 ArkWeb 没拦主框架，`loadData` 无效（真机实测），只剩 `data:`
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
    // 探针是纯诊断，绝不能炸成 JS_ERROR：runJavaScript 在 controller 未关联
    // Web（页面切走/报错态卸载的收尾事件、或 controller 被换新实例）时同步抛
    // 17100001，必须 try-catch 吞掉只留痕（同 fallbackLoadData 的处理）。
    try {
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
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.warn(`geetest web: probe skipped ${msg}`);
    }
  }

  /**
   * `onTitleReceive` 兜底通道：解析页面主动写的四种标题。
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

  /** 标题栏内容（titleBar 的 stackBuilder 承载）：「登录 B 站」标题（返回键为 HDS 默认键） */
  @Builder
  loginBar() {
    NavTitleRow({ title: '登录 B 站' })
  }

  /**
   * 标题行下方自定义区（titleBar 的 bottomBuilder 承载，恒配置）：
   * 滑块切换行（密码登录 / 短信登录 / 扫码登录 / Cookie），与观看历史页分段按钮同款。
   * ⚠️ bottomBuilder 高度不自适应（官方约束），由 titleBar 参数显式给定
   * （LOGIN_TABS_ROW_HEIGHT），行定高排布。
   */
  @Builder
  loginTabsRow() {
    Row() {
      // 段切换：CapsuleSegmentButtonV2 标准分段按钮，B 站粉经
      // itemSelectedBackgroundColor 覆写；selectedIndex 由 this.tab 重算，
      // 点击 → onItemClicked → switchTab（内含极验层取消守卫）。
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
        // 撑满行宽（行左右各 16 让位 → 实得 328vp）：四段文案「密码登录 /
        // 短信登录 / 扫码登录 / Cookie」在 270 定宽下会被压成「密码…」。
        .width('100%')
    }
    .width('100%')
    .height(LOGIN_TABS_ROW_HEIGHT)
    .padding({ left: 16, right: 16, bottom: 4 })
    .alignItems(VerticalAlign.Center)
  }

  /** 标题行收窄容器（BarNarrowShell 共用件，平板模式宽度适配） */
  @Builder
  loginBarNarrow() {
    BarNarrowShell({ bar: (): void => {
      this.loginBar()
    } })
  }

  /**
   * 滑块切换行收窄容器（平板模式宽度适配）：同 loginBarNarrow 口径 ——
   * bottomBuilder 也横跨整列全宽，收窄后滑块行与本页内容列同宽对齐；
   * bottomBuilder 显式高度（LOGIN_TABS_ROW_HEIGHT）不动。sm 天然无操作。
   */
  @Builder
  loginTabsRowNarrow() {
    Row() {
      Column() {
        this.loginTabsRow()
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

  /**
   * 行首图标片：主题色 10% 底 + 主题色字形，28 圆角 7。
   *
   * 与设置 / 关于等页的行首图标同一套规格（28 / 7 / tint 10%），登录表单
   * 因此和全应用的「inset 分组卡片 + 图标片」语言对齐，而不是另起一套。
   */
  @Builder
  formIcon(glyph: Resource) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(glyph)
        .fontSize(17)
        .fontColor([this.themePrimary])
    }
    .width(FORM_ICON_SIZE)
    .height(FORM_ICON_SIZE)
    .borderRadius(FORM_ICON_RADIUS)
    .backgroundColor(this.iconTint())
  }

  /** 表单行分隔线：左缩进到文字起点（卡片内边距 16 + 图标 28 + 间距 12） */
  @Builder
  formDivider() {
    Divider()
      .color($r('app.color.bg_divider'))
      .margin({ left: FORM_DIVIDER_INSET })
  }

  /**
   * 单行输入：行首图标片 + 无边框 TextInput。
   *
   * 行高 56、整行可点即聚焦；输入框自身**不吃背景色**（透明），底色由所在
   * InsetCard 提供 —— 旧版在卡片里叠一层 bg_page 圆角色块，是「不像设置页」
   * 最明显的一处。
   */
  @Builder
  formField(glyph: Resource, placeholder: string, value: string, inputType: InputType,
    onValueChange: (v: string) => void, onSubmitAction: () => void) {
    Row() {
      this.formIcon(glyph)
      TextInput({ placeholder: placeholder, text: value })
        .layoutWeight(1)
        .height(FORM_FIELD_H)
        .padding({ left: FORM_ICON_GAP, right: 0 })
        .backgroundColor(Color.Transparent)
        .borderRadius(0)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .placeholderFont({ size: 15 })
        .type(inputType)
        .maxLength(64)
        .onChange((v: string): void => {
          onValueChange(v);
        })
        .onSubmit((): void => {
          onSubmitAction();
        })
    }
    .width('100%')
    .height(FORM_FIELD_H)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  /** 错误行：贴在卡片下方，字色走 state_error（与各页错误提示一致） */
  @Builder
  formError(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor($r('app.color.state_error'))
      .width('100%')
      .padding({ left: 20, right: 20 })
      .margin({ top: 8 })
  }

  /**
   * 主按钮：48 高、圆角 12（与分组卡片同一套圆角语言），左右让位 16 与卡片齐边。
   * 禁用态 dim 0.5（与全应用全宽 CTA 同款），loading 文案由调用点改写。
   */
  @Builder
  primaryButton(label: string, enabled: boolean, onTap: () => void) {
    Row() {
      Button(label, { type: ButtonType.Normal })
        .layoutWeight(1)
        .height(CTA_HEIGHT_VP)
        .borderRadius(CTA_RADIUS_VP)
        .backgroundColor(this.themePrimary)
        .fontColor(this.themeOn)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .attributeModifier(this.buttonMaterial)
        .enabled(enabled)
        .opacity(enabled ? 1 : 0.5)
        .onClick((): void => {
          onTap();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .margin({ top: 16 })
  }

  /** 次级文字动作（换登录方式等）：主题深色小字，居中，命中区含内边距 */
  @Builder
  textAction(label: string, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(this.themeDeep)
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .margin({ top: 4 })
    .onClick((): void => {
      onTap();
    })
  }

  /** 二维码本体 + 过期蒙层（loading 态显示进度圈）：白底黑码，圆角与卡片同 12 */
  @Builder
  qrArea() {
    Stack() {
      if (this.qrUrl.length > 0) {
        // 二维码必须白底黑码：bg_card 在深色主题下是深底，直接透出会扫不出来
        QRCode(this.qrUrl)
          .width(QR_SIZE_VP)
          .height(QR_SIZE_VP)
          .color(Color.Black)
          .backgroundColor(Color.White)
          .borderRadius(12)
          .clip(true)
      } else {
        Column() {
          LoadingProgress()
            .width(36)
            .height(36)
            .color(this.themePrimary)
        }
        .width(QR_SIZE_VP)
        .height(QR_SIZE_VP)
        .borderRadius(12)
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
        .width(QR_SIZE_VP)
        .height(QR_SIZE_VP)
        .borderRadius(12)
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
    .margin({ top: 14 })
  }

  /** TV 二维码本体 + 过期蒙层（loading 态显示进度圈） */
  @Builder
  tvQrArea() {
    Stack() {
      if (this.tvQrUrl.length > 0) {
        // 二维码必须白底黑码：bg_card 在深色主题下是深底，直接透出会扫不出来
        QRCode(this.tvQrUrl)
          .width(QR_SIZE_VP)
          .height(QR_SIZE_VP)
          .color(Color.Black)
          .backgroundColor(Color.White)
          .borderRadius(12)
          .clip(true)
      } else {
        Column() {
          LoadingProgress()
            .width(36)
            .height(36)
            .color(this.themePrimary)
        }
        .width(QR_SIZE_VP)
        .height(QR_SIZE_VP)
        .borderRadius(12)
        .backgroundColor(Color.White)
        .justifyContent(FlexAlign.Center)
      }

      if (this.tvQrPhase === 'expired') {
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
        .width(QR_SIZE_VP)
        .height(QR_SIZE_VP)
        .borderRadius(12)
        .backgroundColor('#B3000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .accessibilityText('二维码已过期，点击刷新')
        .accessibilityLevel('yes')
        .onClick((): void => {
          this.startTvQrLogin();
        })
      }
    }
    .margin({ top: 14 })
  }

  /**
   * 扫码页签：子切换（TV / 网页）+ 二维码 + 状态行。
   *
   * 结构走全应用统一的「SectionHeader + InsetCard + SectionFooter」，与设置 /
   * 关于 / 观看历史等页同宽同圆角；卡内不再重复「扫码登录」大标题 —— 页签
   * 已经写明当前方式。
   */
  @Builder
  qrCard() {
    Column() {
      SectionHeader({ headerText: '扫码登录' })
      InsetCard() {
        Column() {
          // TV ↔ 网页子切换：与页签滑块同款分段按钮，宽度按两段文案收紧
          CapsuleSegmentButtonV2({
            items: this.qrModeItems,
            selectedIndex: this.qrMode === QR_MODE_TV ? 0 : 1,
            onItemClicked: (index: number): void => {
              this.switchQrMode(index === 0 ? QR_MODE_TV : QR_MODE_WEB);
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
            buttonMinHeight: LengthMetrics.vp(32),
            itemPadding: { start: LengthMetrics.vp(8), end: LengthMetrics.vp(8) }
          })
            .height(32)
            .width(150)
            .margin({ top: 16 })

          if (this.qrMode === QR_MODE_TV) {
            this.tvQrArea()
            // 过期/失败态小字用 themeDeep（白底 13px 品牌粉仅 2.2:1，
            // 设计规范红线；themeDeep 5.81:1 且随主题切换 —— 双粉策略）
            Text(this.tvStatusText)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.tvQrPhase === 'expired' ? this.themeDeep : $r('app.color.text_secondary'))
              .margin({ top: 14 })
          } else {
            this.qrArea()
            Text(this.statusText)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.qrPhase === 'expired' ? this.themeDeep : $r('app.color.text_secondary'))
              .margin({ top: 14 })
          }

          Text('打开 B 站 App「扫一扫」，确认后自动登录')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .padding({ left: 20, right: 20 })
            .margin({ top: 6, bottom: 20 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      SectionFooter({ noteText: '二维码 3 分钟内有效，过期可点击刷新重试' })
    }
    .width('100%')
  }

  /**
   * 密码页签：账号 / 密码两行（行首图标片 + 分隔线），主按钮在卡片外。
   * 错误行贴在卡片下方的卡片外区域 —— 卡片内出现红字会把行高顶乱。
   */
  @Builder
  pwdCard() {
    Column() {
      SectionHeader({ headerText: '账号密码' })
      InsetCard() {
        Column() {
          this.formField($r('sys.symbol.person'), '手机号 / 邮箱', this.pwdUsername,
            InputType.USER_NAME, (v: string): void => {
              this.pwdUsername = v;
              this.pwdError = '';
            }, (): void => {
              this.doPwdLogin();
            })
          this.formDivider()
          this.formField($r('sys.symbol.lock'), '密码', this.pwdPassword,
            InputType.Password, (v: string): void => {
              this.pwdPassword = v;
              this.pwdError = '';
            }, (): void => {
              this.doPwdLogin();
            })
        }
        .width('100%')
      }
      if (this.pwdError.length > 0) {
        this.formError(this.pwdError)
      }
      this.primaryButton(this.busyPwd ? '正在登录…' : '登录', !this.busyPwd, (): void => {
        this.doPwdLogin();
      })
      this.textAction('忘记密码？改用短信登录', (): void => {
        this.switchTab(TAB_SMS);
      })
      SectionFooter({ noteText: '登录后同步收藏、投币与观看历史；异常登录需通过安全验证' })
    }
    .width('100%')
  }

  /** 密码页签（风控）：安心中心卡（打码手机号 → 极验 → 短信验证） */
  @Builder
  safeCenterCard() {
    Column() {
      SectionHeader({ headerText: '安全验证' })
      InsetCard() {
        Column() {
          // 头部说明行：图标片 + 两行文字（标题 + 打码手机号）
          Row() {
            this.formIcon($r('sys.symbol.lock'))
            Column() {
              Text('当前登录存在风险')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Text(this.scHideTel.length > 0 ? `验证手机号 ${this.scHideTel}` : '正在获取验证手机号…')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin({ left: FORM_ICON_GAP })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .alignItems(VerticalAlign.Center)

          if (this.scPhase === SC_PHASE_CODE) {
            this.formDivider()
            this.formField($r('sys.symbol.message'), '短信验证码', this.scCode,
              InputType.Number, (v: string): void => {
                this.scCode = v;
                this.scError = '';
              }, (): void => {
                this.confirmSafeCenter();
              })
          }
        }
        .width('100%')
      }
      if (this.scError.length > 0) {
        this.formError(this.scError)
      }
      if (this.scPhase === SC_PHASE_SMS) {
        this.primaryButton(this.busySafe ? '正在获取…' : '发送短信验证码', !this.busySafe, (): void => {
          this.sendSafeCenterCode();
        })
      } else {
        this.primaryButton(this.busySafe ? '正在验证…' : '完成验证', !this.busySafe, (): void => {
          this.confirmSafeCenter();
        })
      }
      this.textAction('返回密码登录', (): void => {
        this.exitSafeCenter();
      })
    }
    .width('100%')
  }

  /** 短信第 1 步：区号（主题色胶囊）+ 手机号，同一行 */
  @Builder
  smsPhoneCard() {
    Column() {
      SectionHeader({ headerText: '手机号登录' })
      InsetCard() {
        Row() {
          this.formIcon($r('sys.symbol.message'))
          // 区号胶囊：点开半模态全量表（收起键盘由 Sheet 自身处理）
          Row({ space: 2 }) {
            Text(`+${this.selectedDialCountryId()}`)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.themePrimary)
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(12)
              .fontColor([this.themePrimary])
          }
          .padding({ left: 10, right: 8, top: 6, bottom: 6 })
          .borderRadius(8)
          .backgroundColor(this.iconTint())
          .margin({ left: FORM_ICON_GAP })
          .onClick((): void => {
            this.dialSheetVisible = true;
          })

          TextInput({ placeholder: '请输入手机号', text: this.phone })
            .layoutWeight(1)
            .height(FORM_FIELD_H)
            .padding({ left: 10, right: 0 })
            .backgroundColor(Color.Transparent)
            .borderRadius(0)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .placeholderFont({ size: 15 })
            .type(InputType.PhoneNumber)
            .maxLength(15)
            .onChange((v: string): void => {
              this.phone = v;
              this.phoneError = '';
            })
            .onSubmit((): void => {
              this.requestSmsCode();
            })
        }
        .width('100%')
        .height(FORM_FIELD_H)
        .padding({ left: 16, right: 16 })
        .alignItems(VerticalAlign.Center)

        // 粉版域开关行：开启后 send/login 都在粉版（android）域签名，
        // 签出的 access_token 与粉版 appkey（BILI_ANDROID_APP_*，BilibiliApi
        // 粉版接口段同款凭据）同 appid；关闭时与 TV 扫码 / 密码同 HD 域。
        // 开关只在第 1 步渲染（进第 2 步后 captcha_key 已绑定域，不可再切）。
        this.formDivider()
        Row() {
          this.formIcon($r('sys.symbol.sun_max'))
          Column() {
            Text('粉版手机端登录')
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
            Text('令牌与手机端（粉版）接口同域；默认 HD 域即可正常使用')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: FORM_ICON_GAP })
          Toggle({ type: ToggleType.Switch, isOn: this.smsDomain === LOGIN_DOMAIN_ANDROID })
            .selectedColor(this.themePrimary)
            .onChange((v: boolean): void => {
              this.smsDomain = v ? LOGIN_DOMAIN_ANDROID : LOGIN_DOMAIN_HD;
            })
        }
        .width('100%')
        .padding({ left: 16, right: 12, top: 10, bottom: 12 })
        .alignItems(VerticalAlign.Center)
        .accessibilityText('粉版手机端登录')
        .accessibilityLevel('yes')
      }
      if (this.phoneError.length > 0) {
        this.formError(this.phoneError)
      }
      this.primaryButton(this.busySms ? '正在发送…' : '获取验证码', !this.busySms, (): void => {
        this.requestSmsCode();
      })
      SectionFooter({
        noteText: this.smsDomain === LOGIN_DOMAIN_ANDROID
          ? '粉版域令牌与手机端接口同 appid；后续改用其它登录方式会令牌域回退'
          : '验证码将发送至该手机号，仅用于本次登录'
      })
    }
    .width('100%')
  }

  /** 短信第 2 步：验证码输入 + 行内「重新获取」，主按钮登录 */
  @Builder
  smsCodeCard() {
    Column() {
      SectionHeader({ headerText: '输入验证码' })
      InsetCard() {
        Row() {
          this.formIcon($r('sys.symbol.message'))
          TextInput({ placeholder: '请输入短信验证码', text: this.smsCode })
            .layoutWeight(1)
            .height(FORM_FIELD_H)
            .padding({ left: FORM_ICON_GAP, right: 0 })
            .backgroundColor(Color.Transparent)
            .borderRadius(0)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .placeholderFont({ size: 15 })
            .type(InputType.Number)
            .maxLength(8)
            .onChange((v: string): void => {
              this.smsCode = v;
              this.codeError = '';
            })
            .onSubmit((): void => {
              this.doSmsLogin();
            })
          // 行内重发：走同一条发送链路（成功后仍停在验证码阶段，只刷新凭据）
          Text(this.busySms ? '发送中' : '重新获取')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.busySms ? $r('app.color.text_disabled') : this.themePrimary)
            .padding({ left: 10, right: 2, top: 8, bottom: 8 })
            .onClick((): void => {
              this.requestSmsCode();
            })
        }
        .width('100%')
        .height(FORM_FIELD_H)
        .padding({ left: 16, right: 16 })
        .alignItems(VerticalAlign.Center)
      }
      if (this.codeError.length > 0) {
        this.formError(this.codeError)
      }
      this.primaryButton(this.busySms ? '正在登录…' : '登录', !this.busySms, (): void => {
        this.doSmsLogin();
      })
      this.textAction('更换手机号', (): void => {
        this.phase = PHASE_PHONE;
        this.smsCode = '';
        this.codeError = '';
      })
      SectionFooter({ noteText: `验证码已发送至 +${this.selectedDialCountryId()} ${this.phone.trim()}` })
    }
    .width('100%')
  }

  /** Cookie 页签：多行粘贴框（卡片内无边距输入，行高随内容） */
  @Builder
  cookieCard() {
    Column() {
      SectionHeader({ headerText: 'Cookie 导入' })
      InsetCard() {
        Column() {
          TextArea({
            placeholder: '粘贴 Cookie，例如：SESSDATA=xxx; bili_jct=xxx; DedeUserID=xxx',
            text: this.cookieText
          })
            .width('100%')
            .height(120)
            .padding(16)
            .backgroundColor(Color.Transparent)
            .borderRadius(0)
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .placeholderFont({ size: 14 })
            .maxLength(4096)
            .onChange((v: string): void => {
              this.cookieText = v;
              this.cookieError = '';
            })
          this.formDivider()
          // 安全说明行：与设置页「说明行」同款（图标片 + 灰字），说明凭据去向
          Row() {
            this.formIcon($r('sys.symbol.lock'))
            Text('凭据仅保存在本机，退出登录即清除')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
              .margin({ left: FORM_ICON_GAP })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 14 })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
      }
      if (this.cookieError.length > 0) {
        this.formError(this.cookieError)
      }
      this.primaryButton(this.busyCookie ? '正在校验…' : '导入登录', !this.busyCookie, (): void => {
        this.doCookieImport();
      })
      SectionFooter({ noteText: '需包含 SESSDATA 字段；Cookie 失效时请重新从浏览器复制' })
    }
    .width('100%')
  }

  /** 品牌区：欢迎语 + 一行权益说明（卡片内居中；纯文字版式，BiliMusic 音质权益口径） */
  @Builder
  brandHero() {
    Row() {
      Column() {
        Text('欢迎回来')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('登录后可解锁更高音质档位（杜比 / Hi-Res 需大会员）')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .padding({ left: 18, right: 18 })
          .margin({ top: 6 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(12)
      .padding({ top: 22, bottom: 20 })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .margin({ top: 8 })
  }

  /** 区号选择半模态：搜索框 + 全量区号表（DialPrefixData） */
  @Builder
  dialSheetBuilder() {
    Column() {
      Text('选择国家 / 地区')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 14, bottom: 10 })
      Column() {
        TextInput({
          placeholder: '搜索国家 / 地区或区号',
          text: this.dialSearch
        })
          .width('100%')
          .height(40)
          .borderRadius(8)
          .backgroundColor($r('app.color.bg_page'))
          .onChange((v: string): void => {
            this.dialSearch = v;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      List() {
        ForEach(this.filteredDialPrefixes(), (item: DialPrefix) => {
          ListItem() {
            Row() {
              Text(item.cname)
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .layoutWeight(1)
              Text(`+${item.countryId}`)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.selectedDialId === item.id ? this.themeDeep : $r('app.color.text_secondary'))
            }
            .width('100%')
            .height(48)
            .padding({ left: 20, right: 20 })
            .alignItems(VerticalAlign.Center)
            .onClick((): void => {
              this.selectedDialId = item.id;
              this.dialSearch = '';
              this.dialSheetVisible = false;
            })
          }
        }, (item: DialPrefix) => item.id.toString())
      }
      .width('100%')
      .layoutWeight(1)
      .margin({ top: 8 })
      .scrollBar(BarState.Auto)
      .divider({
        strokeWidth: 0.5,
        color: $r('app.color.bg_divider'),
        startMargin: 20,
        endMargin: 20
      })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 极验整屏覆盖层（详见 buildGeetestHtml 注释）。
   *
   * 层级：本层是页面根 Stack 的最后一个子节点 → 盖住 Scroll 内容；
   * HDS 标题栏（标题行 + 滑块行）由宿主绘制在上层，所以这里只需让出
   * safeTop + 标题行 + 滑块行。密码 / 短信 / 安心中心三条链路共用（geetestVisible 挂载）。
   */
  @Builder
  geetestOverlay() {
    Column() {
      // 覆盖层自己的头（HDS 标题栏仍在上面，这里只做「取消」出口）
      // 「安全验证」16 Medium；「取消」为 DlControlBar 文字按钮
      // 模式（13 / themeDeep 白底深粉 / 44vp 触达 / press_overlay 按压态）。
      Row() {
        Text('安全验证')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('取消')
          .fontSize(13)
          .fontColor(this.themeDeep)
          .height(44)
          .padding({ left: 12, right: 12 })
          .borderRadius(8)
          .stateStyles({
            pressed: { .backgroundColor($r('app.color.press_overlay')) },
            normal: { .backgroundColor(Color.Transparent) }
          })
          .onClick((): void => {
            this.cancelGeetest();
          })
      }
      .width('100%')
      .height(44)
      .padding({ left: 20, right: 20 })
      .alignItems(VerticalAlign.Center)

      if (this.geetestError.length > 0) {
        // 失败态：绝不留死白屏 —— 说明原因 + 重试 + 取消出口
        // 主文案 16（WatchHistoryPage 失败态同款）、辅助行 13、
        // 按钮字阶 13 + BUTTON_RADIUS_VP + 沉浸光感材质（兄弟页重试按钮同款）。
        Column() {
          Text(this.geetestError)
            .fontSize(16)
            .fontColor($r('app.color.state_error'))
            .textAlign(TextAlign.Center)
          Text('可以重试，或取消后换个登录方式')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .margin({ top: 8 })
          Button('重试', { type: ButtonType.Normal })
            .width(160)
            .height(40)
            .borderRadius(BUTTON_RADIUS_VP)
            .backgroundColor(this.themePrimary)
            .fontColor(this.themeOn)
            .fontSize(13)
            .attributeModifier(this.buttonMaterial)
            .margin({ top: 18 })
            .onClick((): void => {
              this.retryGeetest();
            })
          Button('取消验证', { type: ButtonType.Normal })
            .width(160)
            .height(40)
            .borderRadius(BUTTON_RADIUS_VP)
            .backgroundColor($r('app.color.bg_divider'))
            .fontColor($r('app.color.text_primary'))
            .fontSize(13)
            .attributeModifier(this.buttonMaterial)
            .margin({ top: 10 })
            .onClick((): void => {
              this.cancelGeetest();
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
            // 顶部让位：**不再手写占位**。HDS 标题栏（含 bottomBuilder 滑块行）
            // 在本机型上本身就占布局高度 —— 内容区原点已经是标题栏底缘
            //（实测 NavDestination content 起点 = 状态栏下沿，标题行 56 + 滑块行
            // 44 已让出）。旧版在这里再垫一份 safeTop + 56 + 44 的 Blank，等于
            // 让位两遍：首屏顶部凭空多出 ~100vp 死白，卡片被压到屏幕下半部分。
            // 现在只留品牌区自身的 8vp 视觉呼吸。

            // ── 品牌区：字标 + 欢迎语 + 一行权益说明 ──
            this.brandHero()

            // ── 内容：随页签切换（每张卡自带 SectionHeader + InsetCard + SectionFooter）──
            if (this.tab === TAB_QR) {
              this.qrCard()
            } else if (this.tab === TAB_SMS) {
              if (this.phase === PHASE_PHONE) {
                this.smsPhoneCard()
              } else {
                this.smsCodeCard()
              }
            } else if (this.tab === TAB_PWD) {
              if (this.pwdStage === PWD_STAGE_SAFE) {
                this.safeCenterCard()
              } else {
                this.pwdCard()
              }
            } else {
              this.cookieCard()
            }

            // 页脚：协议说明（11 号三级灰居中，单行不折行；凭据去向由各卡内
            // 说明行承担，避免这里出现两行小字压住首屏）
            Text('登录即表示同意《哔哩哔哩用户协议》与《隐私政策》')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .textAlign(TextAlign.Center)
              .width('100%')
              .padding({ left: 20, right: 20 })
              .margin({ top: 26, bottom: 28 })
          }
          .width('100%')
        }
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        // 边界回弹：内容超屏可滚时，到顶/到底的反馈动效
        .edgeEffect(EdgeEffect.Spring)
        // 大屏适配：内容列收窄居中（与 AboutPage 同款）
        .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
        // 区号选择半模态（短信页签）：挂常驻的 Scroll 上，detents 双档高度
        .bindSheet($$this.dialSheetVisible, this.dialSheetBuilder(), {
          detents: [SheetSize.MEDIUM, SheetSize.LARGE],
          dragBar: true,
          showClose: false
        })
        // 标题栏让位已内移为内容首部占位（见 Column 首子），不在滚动容器上加 padding。
        // 逐帧驱动自绘渐变模糊层（Scroll 版 onDidScroll 三参
        // 签名 (xOffset, yOffset, state)；onDidScroll 在偏移已应用后回调）。
        .onDidScroll((xOffset: number, yOffset: number, scrollState: ScrollState): void => {
          this.syncTopBlurProgress();
        })
        .onScrollStop((): void => {
          // Idle 校准终态：兜住 Fling 期丢帧 / 死区过滤累计的偏差。
          this.syncTopBlurProgress();
        })

        // 顶栏渐变模糊层：盖 Scroll 内容之上（z 序低于极验
        // 覆盖层、低于 HDS titleBar，滑块行属标题栏 bottomBuilder、随整栏一起盖），
        // 进度由 onDidScroll/onScrollStop 经 topBlurUpdater 命令式驱动。
        TopGradientBlurOverlay({
          barHeightVp: this.safeTop + NAV_TITLE_BAR_HEIGHT + LOGIN_TABS_ROW_HEIGHT,
          updater: this.topBlurUpdater
        })

        // 极验整屏覆盖层：密码 / 短信 / 安心中心三条链路共用（geetestVisible 挂载）。
        // ⚠️ 必须写在 Stack 的**子节点块内**（不能写在 Stack 的属性之后 —— 那样会被
        // 当成 HdsNavDestination 的子节点，Web 照样加载、但永远不进可视层）。
        if (this.geetestVisible) {
          this.geetestOverlay()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
      // 底部不做避让，沉浸到底（与其余子页同口径，见目的地链上的
      // ignoreLayoutSafeArea 声明；内容自顶部起排，不与手势区重叠）。
    }
    // HDS 沉浸光感标题栏（AboutPage 样板同款，真机结论见 AboutPage 注释）：
    // avoidLayoutSafeArea 挡状态栏重叠；enableComponentSafeArea 会杀材质，禁用。
    // 平板模式宽度适配：stackBuilder / bottomBuilder 均走收窄容器
    //（loginBarNarrow / loginTabsRowNarrow），标题行与滑块行和内容列同宽对齐。
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        // 标题行（stackBuilder，可用空间 56vp）：「登录 B 站」标题（返回键为 HDS 默认键）
        //（收窄容器内）
        stackBuilder: (): void => {
          this.loginBarNarrow();
        },
        // 标题行下方自定义区：滑块切换行（四页签），恒配置
        //（收窄容器内与内容列对齐）。
        // ⚠️ 滑块行不能塞进 stackBuilder（会溢出 56vp 标题行、与内容重叠，真机复现），
        // 必须走 bottomBuilder 显式高度。
        bottomBuilder: {
          builder: (): void => {
            this.loginTabsRowNarrow();
          },
          height: LOGIN_TABS_ROW_HEIGHT,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        }
      }
    })
    // 返回键：用 HDS 默认返回键（"<" 系统样式，位置由 HDS 管理以避开状态栏），
    // 不放自绘键。
    // 滚动模糊（scrollEffectOpts）依赖 scroller 绑定：把本页滚动容器交给 HDS 联动
    .bindToScrollable([this.loginScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    // 系统返回拦截：播放页 overlay 打开时
    // 吞掉返回并发收起请求（留在本页），否则走默认 pop —— 详见 utils/SubPageBackPress。
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让：目的地级声明布局扩展进系统安全区（官方组件级沉浸
    // 口径，faqs-arkui-1095 场景三同款）；窗口全屏下页面级为既成事实，此处显式化
    // 并接管组件级 safeAreaPadding。内容层避让由 plain padding 自理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function LoginPageBuilder(): void {
  LoginPage()
}


/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const LoginPageWrapped: WrappedBuilder<[]> = wrapBuilder(LoginPageBuilder);
