/**
 * 导航子页面懒加载注册表。
 *
 * Index 只静态 import 四个 Tab 页，子页面经本注册表动态 import，
 * 避免全部子页面（含 lyric/* 与 components/player/*）在冷启动首帧前
 * 解析加载拖长启动耗时：
 *   · 路由首次触达时按需加载（LazyDest 显示 LoadingProgress 兜底）；
 *   · Index 在首帧后 1.5s 调 preloadAllLazyPages 低优先级预热，
 *     正常跳转时模块早已就绪、用户无感知。
 *
 * 约束：
 *   · 动态 import 的路径必须是字符串字面量（ArkTS 不支持变量拼接）→ 每页一个 case；
 *   · wrapBuilder 只接受**本文件内的直接 @Builder 引用**（编译期校验），
 *     所以各子页面文件内预包装为 XxxWrapped 导出，本表只取现成对象。
 *   · 首页四个 Tab 页（含 HomePage）仍是 Index 静态 import，不进本表；
 *     'Search'（搜索二级页）自首页入口高频触达，排在预热序前列。
 */

type LazyBuilder = WrappedBuilder<[]>;

const builders: Map<string, LazyBuilder> = new Map<string, LazyBuilder>();
const inflight: Map<string, Promise<void>> = new Map<string, Promise<void>>();

/** 取已加载页面的 builder；未加载时返回 undefined。 */
export function getLazyBuilder(name: string): LazyBuilder | undefined {
  return builders.get(name);
}

/** 确保某路由的页面模块已加载；并发调用共用同一 Promise。 */
export function ensureLazyPage(name: string): Promise<void> {
  if (builders.has(name)) {
    return Promise.resolve<void>(undefined);
  }
  let pending: Promise<void> | undefined = inflight.get(name);
  if (pending === undefined) {
    pending = loadByName(name);
    inflight.set(name, pending);
  }
  return pending;
}

async function loadByName(name: string): Promise<void> {
  switch (name) {
    case 'Player': {
      const m = await import('../pages/PlayerPage');
      builders.set(name, m.PlayerPageWrapped);
      break;
    }
    case 'PlaylistDetail': {
      const m = await import('../pages/PlaylistDetail');
      builders.set(name, m.PlaylistDetailWrapped);
      break;
    }
    case 'Search': {
      const m = await import('../pages/SearchPage');
      builders.set(name, m.SearchPageWrapped);
      break;
    }
    case 'Recent': {
      const m = await import('../pages/RecentPage');
      builders.set(name, m.RecentPageWrapped);
      break;
    }
    case 'Follows': {
      const m = await import('../pages/FollowsPage');
      builders.set(name, m.FollowsPageWrapped);
      break;
    }
    case 'UpSpace': {
      const m = await import('../pages/UpSpacePage');
      builders.set(name, m.UpSpacePageWrapped);
      break;
    }
    case 'SeasonSeriesDetail': {
      const m = await import('../pages/SeasonSeriesDetailPage');
      builders.set(name, m.SeasonSeriesDetailPageWrapped);
      break;
    }
    case 'WatchHistory': {
      const m = await import('../pages/WatchHistoryPage');
      builders.set(name, m.WatchHistoryPageWrapped);
      break;
    }
    case 'CloudSync': {
      const m = await import('../pages/FavSyncPage');
      builders.set(name, m.FavSyncPageWrapped);
      break;
    }
    case 'PlaylistImport': {
      const m = await import('../pages/PlaylistImportPage');
      builders.set(name, m.PlaylistImportPageWrapped);
      break;
    }
    case 'About': {
      const m = await import('../pages/AboutPage');
      builders.set(name, m.AboutPageWrapped);
      break;
    }
    case 'PlaybackSettings': {
      const m = await import('../pages/PlaybackSettingsPage');
      builders.set(name, m.PlaybackSettingsPageWrapped);
      break;
    }
    case 'DownloadSettings': {
      const m = await import('../pages/DownloadSettingsPage');
      builders.set(name, m.DownloadSettingsPageWrapped);
      break;
    }
    case 'AppearanceSettings': {
      const m = await import('../pages/AppearanceSettingsPage');
      builders.set(name, m.AppearanceSettingsPageWrapped);
      break;
    }
    case 'AppIconSettings': {
      const m = await import('../pages/AppIconSettingsPage');
      builders.set(name, m.AppIconSettingsPageWrapped);
      break;
    }
    case 'PlaylistBackup': {
      const m = await import('../pages/PlaylistBackupPage');
      builders.set(name, m.PlaylistBackupPageWrapped);
      break;
    }
    case 'PlaybackLog': {
      const m = await import('../pages/PlaybackLogPage');
      builders.set(name, m.PlaybackLogPageWrapped);
      break;
    }
    case 'Reward': {
      const m = await import('../pages/RewardPage');
      builders.set(name, m.RewardPageWrapped);
      break;
    }
    case 'Login': {
      const m = await import('../pages/LoginPage');
      builders.set(name, m.LoginPageWrapped);
      break;
    }
    default:
      break;
  }
}

/** 预热顺序：最常用的播放页 / 搜索二级页 / 歌单详情优先，其余按导航入口热度排列。 */
const PRELOAD_ORDER: string[] = ['Player', 'Search', 'PlaylistDetail', 'Recent', 'Follows',
  'UpSpace', 'SeasonSeriesDetail', 'WatchHistory', 'CloudSync', 'PlaylistImport', 'PlaybackSettings',
  'AppearanceSettings', 'AppIconSettings', 'DownloadSettings', 'PlaylistBackup', 'PlaybackLog', 'Reward', 'About', 'Login'];

function preloadAt(index: number): void {
  if (index >= PRELOAD_ORDER.length) {
    return;
  }
  const target: string = PRELOAD_ORDER[index];
  ensureLazyPage(target)
    .then((): void => {
      preloadAt(index + 1);
    })
    .catch((e: Error): void => {
      console.error(`preheat lazy page ${target} failed: ${JSON.stringify(e)}`);
      // 单页预热失败不阻断后续页
      preloadAt(index + 1);
    });
}

/** 首帧后延时调用：把全部懒加载子页面依次预热进内存（串行，避免抢首帧资源）。 */
export function preloadAllLazyPages(): void {
  preloadAt(0);
}

/**
 * 懒加载路由宿主：navDestination 的 pageMap 统一渲染本组件，
 * 模块就绪后切换为真实页面内容；未就绪时显示加载动效（预热生效后基本不出现）。
 */
@Component
export struct LazyDest {
  @Prop name: string;
  @State private pageBuilder: LazyBuilder | null = null;

  aboutToAppear(): void {
    const cached: LazyBuilder | undefined = getLazyBuilder(this.name);
    if (cached !== undefined) {
      this.pageBuilder = cached;
      return;
    }
    ensureLazyPage(this.name)
      .then((): void => {
        const loaded: LazyBuilder | undefined = getLazyBuilder(this.name);
        if (loaded !== undefined) {
          this.pageBuilder = loaded;
        }
      })
      .catch((e: Error): void => {
        console.error(`lazy load page ${this.name} failed: ${JSON.stringify(e)}`);
      });
  }

  build(): void {
    if (this.pageBuilder !== null) {
      this.pageBuilder.builder();
    } else {
      Column({ space: 12 }) {
        LoadingProgress()
          .width(36)
          .height(36)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
  }
}
