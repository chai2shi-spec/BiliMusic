/**
 * 版本更新日志数据（What's New 弹窗的数据源，见 components/WhatsNewDialog.ets）。
 *
 * ⚠️ 发版约定（每次发版必须三步）：
 *   1. bump `AppScope/app.json5` 的 `versionName` / `versionCode`；
 *   2. 在 `CHANGELOG` 数组**头部**加一条对应版本的条目（新版本在前）；
 *   3. 条目的 `version` 必须与 `versionName` **逐字一致**（含 beta 等后缀）。
 *
 * 忘写条目的后果：该版本安装后首次启动**静默不弹**（无脏数据），下版本聚合时
 * 也不会补弹（「决定即记录」语义，见 WhatsNewDialog.maybeShowWhatsNew）。
 */

/** 单个版本的更新内容（三段列表，空数组段在弹窗中整段跳过） */
export interface ChangelogEntry {
  /** 版本号，与 app.json5 versionName 逐字一致（如 '1.3.4'） */
  version: string;
  /** 发布日期 'YYYY-MM-DD'（展示用） */
  date: string;
  /** 新增功能 */
  added: string[];
  /** 优化改进（可为空数组） */
  improved: string[];
  /** 问题修复 */
  fixed: string[];
}

/** 全量更新日志：新版本在前（头部插入），弹窗按数组顺序渲染 */
export const CHANGELOG: ChangelogEntry[] = [
  {
    version: '1.3.5',
    date: '2026-10-29',
    added: [
      '启动后首次播放音乐增加淡入效果，避免突然出声',
      '新增「音乐小电视」备用桌面图标（应用图标页 · 黑胶下方）'
    ],
    improved: [
      '切歌后再回到之前的曲目，会从上次听到的位置继续播放，进度不再丢失',
      '外观设置选择项改为菜单弹窗直接选择，不再逐档循环切换',
      '下载页歌单/合集卡片视觉精简：移除右侧展开箭头与「歌单/合集」徽标，点击整卡即可展开',
      '「同步已完成歌曲」部分失败时给出可操作引导：将「保存到系统下载目录」开关关闭再打开即可恢复',
      '「查看更新日志」入口从「关于」页移至设置页（日志记录与打赏作者之间），点按即弹窗查看'
    ],
    fixed: [
      '自定义功能栏「限定播放进度」图标与播放页功能行不一致的问题'
    ]
  },
  {
    version: '1.3.4',
    date: '2026-10-29',
    added: [
      '播放页功能栏支持自定义排序：9 个功能项长按拖动调整顺序，前 4 位为默认页（设置 → 播放设置 → 自定义功能栏）',
      '首页收藏歌单卡支持长按菜单：移出首页 / 更换歌单（原位替换）',
      '首页歌单卡区分来源：订阅卡显示「订阅」小标与 UP 投稿数，口径与歌单页一致',
      '新版本首次启动展示更新内容弹窗，「关于」页可随时查看更新日志'
    ],
    improved: [
      '播放页功能行改分页交互：一页 4 个等宽槽位，左右滑动翻页，双侧箭头按页位显隐，多入口不再挤压一行',
      '逐字歌词高亮平滑扫过：外推播放头 + 高频刷新，不再每半秒跳一格',
      '歌词设置面板「居中显示」开关移至右上角',
      '下载页顶栏精简：移除「定位」按钮，「全部开始 / 全部暂停」顺位前移',
      '设置二级页分类整理：播放设置 / 外观设置 / 下载与存储按类别分组卡片展示',
      'B 站 AI 字幕生成中时按钮置灰不可点，稍后点「重新检测」即可'
    ],
    fixed: [
      '已下载歌曲从下载页播放时恢复 B 站视频身份：播放仍走本地文件，但可正常获取 B 站字幕歌词',
      '修复首页歌单卡数量停留在首次挂载值、不随歌单变化刷新的问题'
    ]
  }
];

/**
 * 语义化版本比较（按 '.' 分段逐段比数字）。
 *
 * 返回正数表示 a 更新、负数表示 a 更旧、0 表示等价：
 *   compareVersion('1.3.10', '1.3.4') > 0
 *   compareVersion('1.3.4', '1.3.4') === 0
 *
 * 兜底规则：
 *   · 段数不等时短的一方缺段按 0（'1.3' 等价 '1.3.0'）；
 *   · 段内非数字（如 '4-beta'）按 parseInt 前缀取值，取不到按 0。
 */
export function compareVersion(a: string, b: string): number {
  const segA: string[] = a.split('.');
  const segB: string[] = b.split('.');
  const count: number = Math.max(segA.length, segB.length);
  for (let i: number = 0; i < count; i++) {
    const na: number = toSegmentNumber(i < segA.length ? segA[i] : '0');
    const nb: number = toSegmentNumber(i < segB.length ? segB[i] : '0');
    if (na !== nb) {
      return na - nb;
    }
  }
  return 0;
}

/** 单段转数字：非数字段按 0 兜底（版本号只支持数字段语义化比较） */
function toSegmentNumber(seg: string): number {
  const parsed: number = Number.parseInt(seg, 10);
  return Number.isNaN(parsed) ? 0 : parsed;
}
