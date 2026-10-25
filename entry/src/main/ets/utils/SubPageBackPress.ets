/**
 * 二级页（NavDestination）系统返回拦截。
 *
 * 播放页不是 NavDestination 路由，而是 Index 根 Stack 上的组件 overlay ——
 * 盖住整个界面却不参与返回事件分发。二级页在顶时若不拦截，系统返回会被
 * 隐藏在 overlay 之下的 NavDestination 默认消费（静默 pop 二级页），
 * 收起播放页后用户看到的是一级首页而非来源二级页。
 *
 * 全部 9 个推送二级页在 HdsNavDestination 上挂 .onBackPressed 调本函数：
 * 播放页 overlay 打开（playerOpen 或仍挂载）时吞掉返回并发收起请求
 * （STORE_PLAYER_CLOSE_REQUEST seq 递增，Index @Watch 消费 → closePlayer，
 * 与播放页 TopArea 收起按钮同一跨层信号，closePlayer 幂等）；否则返回 false
 * 走默认 pop。判定条件与 Index.onBackPress 完全同口径
 * （playerOpen || playerOverlayMounted）。
 */

import {
  STORE_PLAYER_OPEN,
  STORE_PLAYER_OVERLAY_MOUNTED,
  STORE_PLAYER_CLOSE_REQUEST
} from '../common/Constants';

/**
 * 二级页 NavDestination.onBackPressed 统一回调：
 * true = 播放页 overlay 打开，返回被吞掉并已发收起请求（留在本页）；
 * false = 播放页未打开，走默认 pop（返回上一页 / 首页）。
 */
export function handleSubPageBackPress(): boolean {
  const open: boolean = AppStorage.get<boolean>(STORE_PLAYER_OPEN) ?? false;
  const mounted: boolean = AppStorage.get<boolean>(STORE_PLAYER_OVERLAY_MOUNTED) ?? false;
  if (!open && !mounted) {
    return false;
  }
  const seq: number = (AppStorage.get<number>(STORE_PLAYER_CLOSE_REQUEST) ?? 0) + 1;
  AppStorage.setOrCreate(STORE_PLAYER_CLOSE_REQUEST, seq);
  return true;
}
