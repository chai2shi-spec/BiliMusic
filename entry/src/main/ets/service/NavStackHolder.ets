/**
 * 全局导航栈持有器：供非页面组件（如 MiniPlayer）与各页面共用同一份
 * NavPathStack（phoneShell / tabletShell 两壳互斥挂载，折叠开合时共享
 * 返回栈）。栈操作统一走 NavPathStack 原生 API，本类只做持有 + 拦截。
 */

import { LOGIN_GATED_ROUTES } from './NavRouteParams';
import { isLoggedIn } from './LoginStore';
import { STORE_SUB_PAGE_ACTIVE } from '../common/Constants';

/**
 * 同名路由 push 防抖窗口（ms）：窗口内对同一路由名的第二次 push 直接
 * 取消（修复快速双击入口双推同一页）。300ms 覆盖典型连点间隔，正常
 * 两次有意跳转（不同入口）不受影响。
 */
const PUSH_DEBOUNCE_MS: number = 300;

export class NavStackHolder {
  static stack: NavPathStack = new NavPathStack();

  /** 上一次 push 的路由名（防抖比对用；pop 时清空，避免 push→返回→再 push 被误吞） */
  private static lastPushName: string = '';
  /** 上一次 push 的时间戳（Date.now()，防抖窗口起点） */
  private static lastPushTs: number = 0;
  /** 拦截器是否已挂载（setInterception 可重复调用，但只挂一次即可） */
  private static interceptionReady: boolean = false;

  // ── 栈操作封装（薄封装：统一入口 + 便于全局加日志/防抖策略） ──

  /** 压栈（携带路由参数；同名 300ms 防抖见 setupInterception） */
  static push(name: string, param: Object): void {
    NavStackHolder.stack.pushPathByName(name, param);
  }

  /** 出栈并回传结果给上一页的 onPop 回调 */
  static pop(result?: Object): void {
    NavStackHolder.stack.pop(result);
  }

  /** 出栈到栈内最近的指定路由名（不在栈内时行为同 pop） */
  static popTo(name: string): void {
    NavStackHolder.stack.popToName(name);
  }

  /** 替换栈顶（当前页出栈、新页入栈，返回不经过被替换页） */
  static replace(name: string, param: Object): void {
    NavStackHolder.stack.replacePathByName(name, param);
  }

  /** 清空全部子页回到首页（NavBar） */
  static clearAll(): void {
    NavStackHolder.stack.clear();
  }

  /**
   * 挂载路由拦截器（Index aboutToAppear 调一次，两壳共享同一栈故只挂一次）：
   *
   * · willShow 阶段登录拦截：目标路由名在 LOGIN_GATED_ROUTES 内且未登录 →
   *   改推登录页。当前清单为空（校验留在各调用点），仅基础设施就位；
   * · 同名 push 防抖：300ms 内对同一路由名的第二次 push 直接 pop 取消
   *   （willShow 允许栈操作且对本次转场立即生效，官方文档口径）。
   * · 二级页在顶标志（STORE_SUB_PAGE_ACTIVE，2026-10-22 二级页悬浮播放条）：
   *   willShow 顶部随转场同步翻转 + didShow 转场落定后权威校正 —— 双写兜住
   *   「push 防抖在 willShow 内 stack.pop() 取消、不再触发 willShow」的边角
   *   （取消回首页时由 didShow to='navBar' 修正为 false）。
   *
   * pop 时清防抖记录：用户返回后立刻再进同一路由属于新意图，不该被吞。
   */
  static setupInterception(): void {
    if (NavStackHolder.interceptionReady) {
      return;
    }
    NavStackHolder.interceptionReady = true;
    const willShow: InterceptionShowCallback =
      (from: NavDestinationContext | NavBar, to: NavDestinationContext | NavBar,
        operation: NavigationOperation, isAnimated: boolean): void => {
        // 二级页在顶标志（第一行，早于下方 operation 分支，push/pop/replace 全覆盖）
        AppStorage.setOrCreate(STORE_SUB_PAGE_ACTIVE, typeof to !== 'string');
        if (operation === NavigationOperation.POP) {
          NavStackHolder.lastPushName = '';
          return;
        }
        if (operation !== NavigationOperation.PUSH) {
          return;
        }
        // push 的目标必然是子页；NavBar（首页）只可能是 from
        if (typeof to === 'string') {
          return;
        }
        const name: string = to.pathInfo.name;
        // 登录拦截（清单为空时永不触发，仅保留链路）
        if (LOGIN_GATED_ROUTES.indexOf(name) >= 0 && !isLoggedIn()) {
          NavStackHolder.stack.pushPathByName('Login', undefined);
          return;
        }
        // 同名 push 防抖：窗口内第二次 push 直接取消
        const now: number = Date.now();
        if (name === NavStackHolder.lastPushName
          && now - NavStackHolder.lastPushTs < PUSH_DEBOUNCE_MS) {
          NavStackHolder.stack.pop();
          return;
        }
        NavStackHolder.lastPushName = name;
        NavStackHolder.lastPushTs = now;
      };
    // 转场落定后的权威校正：转场中途的取消 / 替换以最终栈顶为准
    const didShow: InterceptionShowCallback =
      (from: NavDestinationContext | NavBar, to: NavDestinationContext | NavBar,
        operation: NavigationOperation, isAnimated: boolean): void => {
        AppStorage.setOrCreate(STORE_SUB_PAGE_ACTIVE, typeof to !== 'string');
      };
    const interception: NavigationInterception = { willShow: willShow, didShow: didShow };
    NavStackHolder.stack.setInterception(interception);
  }
}
