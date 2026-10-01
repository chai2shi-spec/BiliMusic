/**
 * 全局导航栈持有器：供非页面组件（如 MiniPlayer）跳转到播放页 / 歌单详情。
 */

export class NavStackHolder {
  static stack: NavPathStack = new NavPathStack();
  // 歌单详情页通过此字段读取目标歌单（避免 nav param 类型转换）
  static selectedPlaylistId: string = '';
}
