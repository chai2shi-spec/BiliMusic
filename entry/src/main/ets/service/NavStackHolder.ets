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
}
