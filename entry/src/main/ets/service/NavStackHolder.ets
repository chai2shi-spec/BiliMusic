/**
 * 播放页转场的「起点矩形」（vp，相对窗口左上角）。
 *
 * 点击底部迷你栏时由 PlayBar 用 `getComponentUtils().getRectangleById()` 实测写入，
 * 播放页背景面据此从迷你栏矩形「长」到全屏（见 PlayerInfoComponent 的 surfaceProgress）。
 */
export interface PlayerEntranceRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/**
 * 全局导航栈持有器：供非页面组件（如 MiniPlayer）跳转到播放页 / 歌单详情。
 */

export class NavStackHolder {
  static stack: NavPathStack = new NavPathStack();
  // 歌单详情页通过此字段读取目标歌单（避免 nav param 类型转换）
  static selectedPlaylistId: string = '';

  /**
   * UP 主主页的入参。
   *
   * 传 mid 而不传整份资料：昵称/粉丝/头像在页面里现拉（`getUserCard`），
   * 这样从别的入口进来也能拿到最新资料；`upName` 只作**兜底**——
   * 资料请求失败时至少能显示个名字，而不是一片空白。
   */
  static upMid: string = '';
  static upName: string = '';
  /**
   * UP 头像（**首帧占位**，可选）。
   *
   * 搜索结果里本来就带 `face_nft` / `upic`，顺手传过来能让 UP 主页一进来就有头像，
   * 不用等 `getUserCard` 回来。`UpSpacePage.loadCard()` 拿到真实头像后会覆盖它，
   * 所以这里只是「首帧不等」的角色，不参与后续状态。
   */
  static upFace: string = '';

  /**
   * 播放页转场的起点矩形（迷你栏实测，vp）。
   *
   * **纯静态字段、不进 AppStorage** —— 它不参与任何 UI 订阅，写它不会触发重渲染。
   * 这一点是刻意的：本项目在 HDS 托管的迷你栏内容里写状态变量，会让内容在 HDS
   * 自己的形变动画中重建（真机症状：「垂直两层下展开迷你栏直接消失」）。
   * 设置方：PlayBar.gotoPlayer()；消费方：PlayerInfoComponent（读完即清空，
   * 一次性语义，避免其它入口复用陈旧矩形）。
   * null = 无起点（未测量 / 非迷你栏入口）→ 播放页退回常规淡入。
   */
  static playerEntranceRect: PlayerEntranceRect | null = null;
}
