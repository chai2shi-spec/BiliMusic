/**
 * 全局偏好存储：基于 @ohos.data.preferences 的键值持久化。
 * 应用启动时由 EntryAbility 调用 init。
 *
 * 登录态存取（getLoginCookie / setLoginCookie / getLoginUser / setLoginUser）：
 * Cookie 与用户信息分开存（单值 8192 字节上限内均宽裕）。
 */

import dataPreferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { ConfigurationConstant } from '@kit.AbilityKit';
import {
  DEFAULT_APP_SETTINGS,
  DEFAULT_FUNC_ITEM_ORDER,
  AppSettings,
  ThemeMode,
  PLAYER_COVER_STYLE_DISC,
  PLAYER_COVER_STYLE_SQUARE,
  IMMERSIVE_TIER_EXQUISITE,
  IMMERSIVE_TIER_SMOOTH,
  IMMERSIVE_TIER_OPTIONS
} from '../model/MusicModels';
import {
  PREF_SETTINGS,
  PREF_RECENT,
  PREF_FAVORITES,
  PREF_PLAYLISTS,
  PREF_PLAYLIST_TOMBSTONES,
  PREF_FAVORITE_TOMBSTONES,
  PREF_PLAYER_STATE,
  PREF_SEARCH_HISTORY,
  PREF_TOTAL_LISTEN_SECONDS,
  PREF_LOGIN_COOKIE,
  PREF_LOGIN_USER,
  PREF_LOGIN_REFRESH_TOKEN,
  PREF_LOGIN_VERIFIED_AT
} from '../common/Constants';

let preferences: dataPreferences.Preferences | null = null;

export async function initPreferences(context: common.Context): Promise<void> {
  preferences = await dataPreferences.getPreferences(context, { name: 'bilimusic_prefs' });
}

function ensure(): dataPreferences.Preferences {
  if (!preferences) {
    throw new Error('AppPreferences not initialized');
  }
  return preferences;
}

export async function setString(key: string, value: string): Promise<void> {
  const p = ensure();
  await p.put(key, value);
  await p.flush();
}

async function setBoolean(key: string, value: boolean): Promise<void> {
  const p = ensure();
  await p.put(key, value);
  await p.flush();
}

async function setObject<T>(key: string, value: T): Promise<void> {
  const p = ensure();
  await p.put(key, JSON.stringify(value));
  await p.flush();
}

export function getString(key: string, def: string = ''): string {
  return ensure().getSync(key, def) as string;
}

function getBoolean(key: string, def: boolean = false): boolean {
  return ensure().getSync(key, def) as boolean;
}

function getObject<T>(key: string): T | null {
  const raw: string = ensure().getSync(key, '') as string;
  if (!raw) {
    return null;
  }
  try {
    return JSON.parse(raw) as T;
  } catch (e) {
    return null;
  }
}

async function remove(key: string): Promise<void> {
  const p = ensure();
  await p.delete(key);
  await p.flush();
}

/**
 * 批量写：多个 key 共享一次 flush。
 * 分片存储（recent_tracks_* / favorite_tracks_* / pl_tracks_*）一次落盘要写
 * 十几个 key；flush 是全量落盘操作，每 key 各自 put + flush 会重复全量刷盘。
 * 这里逐 key put（只动内存缓存层），最后一次 flush。
 */
async function putMany(values: Record<string, string>): Promise<void> {
  const p = ensure();
  const keys: string[] = Object.keys(values);
  for (let i = 0; i < keys.length; i++) {
    await p.put(keys[i], values[keys[i]]);
  }
  await p.flush();
}

/** 批量删（与 putMany 同理）：逐 key delete，最后一次 flush。 */
async function removeMany(keys: string[]): Promise<void> {
  const p = ensure();
  for (let i = 0; i < keys.length; i++) {
    await p.delete(keys[i]);
  }
  await p.flush();
}

/** 封面风格白名单归一化：历史存量已删档（黑胶/磁带/全屏沉浸 immersive）及未知值回落默认唱片档 */
function normalizeCoverStyle(style: string | undefined): string {
  const valid: boolean = style === PLAYER_COVER_STYLE_DISC
    || style === PLAYER_COVER_STYLE_SQUARE;
  return valid && style !== undefined ? style : DEFAULT_APP_SETTINGS.playerCoverStyle;
}

/**
 * 沉浸光感材质档位白名单归一化（已取消档位的存量迁移）：
 * - 'standard'（旧三档默认）→ 'exquisite'：旧标准档在支持设备上本就解析为
 *   EXQUISITE，视觉零变化（升级无感知）；
 * - 'adaptive'（已取消的自适应档）→ 'exquisite' 默认档；
 * - 'off'（已取消的关闭档）→ 'smooth'：轻质流畅档最接近原「无材质」意图；
 * - 未知 / 异常值回落默认档。
 */
function normalizeImmersiveTier(tier: string | undefined): string {
  if (tier === 'standard' || tier === 'adaptive') {
    return IMMERSIVE_TIER_EXQUISITE;
  }
  if (tier === 'off') {
    return IMMERSIVE_TIER_SMOOTH;
  }
  const valid: boolean = tier !== undefined && IMMERSIVE_TIER_OPTIONS.includes(tier);
  return valid ? tier : DEFAULT_APP_SETTINGS.immersiveMaterialTier;
}

/**
 * 功能行功能项顺序白名单归一化：过滤未知 id、去重、按存量顺序保留已知 id、
 * 缺失的已知 id 按默认序补尾；恒返回**全新数组**（不共享任何引用）。
 * 老版本数据（无 funcItemOrder 字段 / 坏 JSON）→ 默认序副本（= 历史布局，升级零感知）。
 */
function normalizeFuncItemOrder(stored: string[] | undefined): string[] {
  const result: string[] = [];
  if (stored !== undefined && stored !== null) {
    for (let i = 0; i < stored.length; i++) {
      const id: string = stored[i];
      if (DEFAULT_FUNC_ITEM_ORDER.indexOf(id) >= 0 && result.indexOf(id) < 0) {
        result.push(id);
      }
    }
  }
  for (let i = 0; i < DEFAULT_FUNC_ITEM_ORDER.length; i++) {
    const id: string = DEFAULT_FUNC_ITEM_ORDER[i];
    if (result.indexOf(id) < 0) {
      result.push(id);
    }
  }
  return result;
}

/**
 * getSettings 的内存缓存：播放切歌热路径（currentPlayQualityId / playTrack /
 * handleEnded / prefetch）每次调用都会走 getSettings，此前每次都 getSync +
 * JSON.parse + 30 字段重建。PREF_SETTINGS 的唯一写入方是本模块的 saveSettings
 * （写入时同步刷新缓存），不存在第二写入者导致缓存失效的问题。
 * getSettings 返回缓存的防御性拷贝（copyAppSettings，纯字段复制），
 * 防止调用方原地改写共享缓存对象。
 */
let settingsCache: AppSettings | null = null;

function getSettings(): AppSettings {
  if (!settingsCache) {
    const stored: Partial<AppSettings> | null = getObject<Partial<AppSettings>>(PREF_SETTINGS);
    settingsCache = {
      sidebarState: stored?.sidebarState ?? DEFAULT_APP_SETTINGS.sidebarState,
    playQuality: stored?.playQuality ?? DEFAULT_APP_SETTINGS.playQuality,
    downloadQuality: stored?.downloadQuality ?? DEFAULT_APP_SETTINGS.downloadQuality,
    downloadDir: stored?.downloadDir ?? DEFAULT_APP_SETTINGS.downloadDir,
    autoPlay: stored?.autoPlay ?? DEFAULT_APP_SETTINGS.autoPlay,
    autoPlayOnStart: stored?.autoPlayOnStart ?? DEFAULT_APP_SETTINGS.autoPlayOnStart,
    wifiOnlyDownload: stored?.wifiOnlyDownload ?? DEFAULT_APP_SETTINGS.wifiOnlyDownload,
    wifiOnlyPlay: stored?.wifiOnlyPlay ?? DEFAULT_APP_SETTINGS.wifiOnlyPlay,
    themeMode: stored?.themeMode ?? DEFAULT_APP_SETTINGS.themeMode,
    themeColor: stored?.themeColor ?? DEFAULT_APP_SETTINGS.themeColor,
    barLayout: stored?.barLayout ?? DEFAULT_APP_SETTINGS.barLayout,
    progressStyle: stored?.progressStyle ?? DEFAULT_APP_SETTINGS.progressStyle,
    closeAnimStyle: stored?.closeAnimStyle ?? DEFAULT_APP_SETTINGS.closeAnimStyle,
    playerCoverStyle: normalizeCoverStyle(stored?.playerCoverStyle),
    itemDisplayStyle: stored?.itemDisplayStyle ?? DEFAULT_APP_SETTINGS.itemDisplayStyle,
    miniBarProgress: stored?.miniBarProgress ?? DEFAULT_APP_SETTINGS.miniBarProgress,
    miniBarAutoExpand: stored?.miniBarAutoExpand ?? DEFAULT_APP_SETTINGS.miniBarAutoExpand,
    speedEnabled: stored?.speedEnabled ?? DEFAULT_APP_SETTINGS.speedEnabled,
    playbackSpeed: stored?.playbackSpeed ?? DEFAULT_APP_SETTINGS.playbackSpeed,
    audioMixEnabled: stored?.audioMixEnabled ?? DEFAULT_APP_SETTINGS.audioMixEnabled,
    loudnessNormalizationEnabled: stored?.loudnessNormalizationEnabled ?? DEFAULT_APP_SETTINGS.loudnessNormalizationEnabled,
    openInBilibiliEnabled: stored?.openInBilibiliEnabled ?? DEFAULT_APP_SETTINGS.openInBilibiliEnabled,
    sleepTimerEntryEnabled: stored?.sleepTimerEntryEnabled ?? DEFAULT_APP_SETTINGS.sleepTimerEntryEnabled,
    skipIntroEntryEnabled: stored?.skipIntroEntryEnabled ?? DEFAULT_APP_SETTINGS.skipIntroEntryEnabled,
    upSpaceEntryEnabled: stored?.upSpaceEntryEnabled ?? DEFAULT_APP_SETTINGS.upSpaceEntryEnabled,
    lyricCentered: stored?.lyricCentered ?? DEFAULT_APP_SETTINGS.lyricCentered,
    immersiveMaterialTier: normalizeImmersiveTier(stored?.immersiveMaterialTier),
    listenCacheEnabled: stored?.listenCacheEnabled ?? DEFAULT_APP_SETTINGS.listenCacheEnabled,
    saveToPublicDownloads: stored?.saveToPublicDownloads ?? DEFAULT_APP_SETTINGS.saveToPublicDownloads,
    publicDownloadsDirUri: stored?.publicDownloadsDirUri ?? DEFAULT_APP_SETTINGS.publicDownloadsDirUri,
    publicDirMigrated: stored?.publicDirMigrated ?? DEFAULT_APP_SETTINGS.publicDirMigrated,
      playCdnLine: stored?.playCdnLine ?? DEFAULT_APP_SETTINGS.playCdnLine,
      autoPickedCdnLine: stored?.autoPickedCdnLine ?? DEFAULT_APP_SETTINGS.autoPickedCdnLine,
      funcItemOrder: normalizeFuncItemOrder(stored?.funcItemOrder)
    };
  }
  return copyAppSettings(settingsCache);
}

async function saveSettings(s: AppSettings): Promise<void> {
  await setObject<AppSettings>(PREF_SETTINGS, s);
  // 落盘成功后同步缓存：getSettings 的唯一数据源与磁盘保持一致
  settingsCache = s;
}

/**
 * 逐字段拷贝 AppSettings。
 *
 * 设置页拆成主页面 + 多个二级子页后，逐字段拷贝逻辑被多处共用，
 * 集中到本文件统一维护 —— AppSettings 新增必填字段时只需改这一处。
 */
function copyAppSettings(s: AppSettings): AppSettings {
  return {
    sidebarState: s.sidebarState,
    playQuality: s.playQuality,
    downloadQuality: s.downloadQuality,
    downloadDir: s.downloadDir,
    autoPlay: s.autoPlay,
    autoPlayOnStart: s.autoPlayOnStart,
    wifiOnlyDownload: s.wifiOnlyDownload,
    wifiOnlyPlay: s.wifiOnlyPlay,
    themeMode: s.themeMode,
    themeColor: s.themeColor,
    barLayout: s.barLayout,
    miniBarProgress: s.miniBarProgress,
    miniBarAutoExpand: s.miniBarAutoExpand,
    speedEnabled: s.speedEnabled,
    playbackSpeed: s.playbackSpeed,
    audioMixEnabled: s.audioMixEnabled,
    loudnessNormalizationEnabled: s.loudnessNormalizationEnabled,
    openInBilibiliEnabled: s.openInBilibiliEnabled,
    sleepTimerEntryEnabled: s.sleepTimerEntryEnabled,
    skipIntroEntryEnabled: s.skipIntroEntryEnabled,
    upSpaceEntryEnabled: s.upSpaceEntryEnabled,
    lyricCentered: s.lyricCentered,
    immersiveMaterialTier: s.immersiveMaterialTier,
    listenCacheEnabled: s.listenCacheEnabled,
    saveToPublicDownloads: s.saveToPublicDownloads,
    publicDownloadsDirUri: s.publicDownloadsDirUri,
    publicDirMigrated: s.publicDirMigrated,
    progressStyle: s.progressStyle,
    closeAnimStyle: s.closeAnimStyle,
    playerCoverStyle: s.playerCoverStyle,
    itemDisplayStyle: s.itemDisplayStyle,
    playCdnLine: s.playCdnLine,
    autoPickedCdnLine: s.autoPickedCdnLine,
    // 数组字段防御性拷贝：隔离 AppStorage 镜像 / 排序页本地序与内存缓存的引用，
    // 防任一侧原地改写污染另一侧（getSettings 返回值直连 settingsCache）。
    funcItemOrder: s.funcItemOrder.slice()
  };
}

/**
 * 统一的设置更新入口（读 → 改 → 写 → 返回新值）。
 *
 * 各设置页的用法：`this.settings = AppPreferences.updateSettings(mut)`。
 * getSettings 底层是 preferences getSync（内存缓存读，不碰磁盘 IO），
 * 单次用户交互调用一次成本可忽略；saveSettings 落盘 fire-and-forget（写完不等待）。
 */
function updateSettings(mut: (s: AppSettings) => void): AppSettings {
  const next: AppSettings = copyAppSettings(getSettings());
  mut(next);
  // fire-and-forget 但必须接住 rejection：落盘失败（磁盘满 / 超限）若不接，
  // 界面已显示新值而磁盘仍是旧值，且未处理的 rejection 完全不可见
  saveSettings(next).catch((e: Error): void => {
    console.error(`saveSettings failed: ${e.message}`);
  });
  return next;
}

/**
 * 把主题设置真正应用到应用（设置页切换时 + 启动恢复时调用）。
 *
 * COLOR_MODE_NOT_SET（-1）即「跟随系统」；setColorMode 是运行时设置，
 * 每次启动都要重新应用（EntryAbility 在 loadContent 前调用），不落盘。
 */
function applyThemeMode(context: common.Context, mode: ThemeMode): void {
  let target: number;
  if (mode === ThemeMode.DARK) {
    target = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  } else if (mode === ThemeMode.LIGHT) {
    target = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
  } else {
    target = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  }
  try {
    context.getApplicationContext().setColorMode(target);
  } catch (e) {
    const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
    console.error(`applyThemeMode failed: ${msg}`);
  }
}

/**
 * 累计听歌时长（秒）。
 *
 * 由 MusicPlayer 在播放中累计，每满 LISTEN_FLUSH_SECONDS 才落盘一次
 * （追加式写，读-改-写都在 UI 线程内串行，无并发竞争）。
 */
function getTotalListenSeconds(): number {
  try {
    return ensure().getSync(PREF_TOTAL_LISTEN_SECONDS, 0) as number;
  } catch (e) {
    return 0;
  }
}

async function addListenSeconds(delta: number): Promise<void> {
  if (delta <= 0) {
    return;
  }
  const p = ensure();
  const cur: number = p.getSync(PREF_TOTAL_LISTEN_SECONDS, 0) as number;
  await p.put(PREF_TOTAL_LISTEN_SECONDS, cur + delta);
  await p.flush();
}

/**
 * 旧格式最近播放（PREF_RECENT 单键 Track[]）。
 * 最近播放读写走分片（LibraryStore 的 recent_tracks_* key），
 * 本函数仅作**升级迁移的数据源**保留（LibraryStore 无分片数据时回落到这里）。
 */
function getRecentTracks<T>(): T[] {
  return getObject<T[]>(PREF_RECENT) ?? [];
}

function getFavoriteTracks<T>(): T[] {
  return getObject<T[]>(PREF_FAVORITES) ?? [];
}

function getPlaylists<T>(): T[] {
  return getObject<T[]>(PREF_PLAYLISTS) ?? [];
}

async function savePlaylists<T>(list: T[]): Promise<void> {
  await setObject<T[]>(PREF_PLAYLISTS, list);
}

function getPlaylistTombstones<T>(): T[] {
  return getObject<T[]>(PREF_PLAYLIST_TOMBSTONES) ?? [];
}

async function savePlaylistTombstones<T>(list: T[]): Promise<void> {
  await setObject<T[]>(PREF_PLAYLIST_TOMBSTONES, list);
}

function getFavoriteTombstones<T>(): T[] {
  return getObject<T[]>(PREF_FAVORITE_TOMBSTONES) ?? [];
}

async function saveFavoriteTombstones<T>(list: T[]): Promise<void> {
  await setObject<T[]>(PREF_FAVORITE_TOMBSTONES, list);
}

function getSearchHistory(): string[] {
  return getObject<string[]>(PREF_SEARCH_HISTORY) ?? [];
}

async function saveSearchHistory(list: string[]): Promise<void> {
  await setObject<string[]>(PREF_SEARCH_HISTORY, list);
}

function getPlayerState<T>(): T | null {
  return getObject<T>(PREF_PLAYER_STATE);
}

// ===================== 登录态（扫码登录） =====================

/** 登录 Cookie 串（SESSDATA / bili_jct / DedeUserID / DedeUserID__ckMd5），空 = 未登录 */
function getLoginCookie(): string {
  return getString(PREF_LOGIN_COOKIE, '');
}

async function setLoginCookie(cookie: string): Promise<void> {
  await setString(PREF_LOGIN_COOKIE, cookie);
}

/** 登录用户信息（mid / uname / face / vipStatus，泛型由调用方约束为 LoginUser） */
function getLoginUser<T>(): T | null {
  return getObject<T>(PREF_LOGIN_USER);
}

async function setLoginUser<T>(user: T): Promise<void> {
  await setObject<T>(PREF_LOGIN_USER, user);
}

/**
 * 登录撤销令牌（refresh_token）。
 *
 * ⚠️ **当前无调用方**：续期链路尚未开工，这个键只写不读。
 * 见 common/Constants.ts 里 PREF_LOGIN_REFRESH_TOKEN 的注释。
 */
function getLoginRefreshToken(): string {
  return getString(PREF_LOGIN_REFRESH_TOKEN, '');
}

async function setLoginRefreshToken(token: string): Promise<void> {
  await setString(PREF_LOGIN_REFRESH_TOKEN, token);
}

/**
 * 最近一次「登录态被服务端确认有效」的时间戳（ms）。
 *
 * 0 = 待重新验证（被nav 判-101，或从未拉取成功过）。
 * 与 refresh_token 分开存：前者回答「现在还能用吗」，后者回答「将来能不能续」，
 * 两者在「Cookie 被拒但 token 仍在」时需要不同的处置。
 */
function getLoginVerifiedAt(): number {
  const raw: string = getString(PREF_LOGIN_VERIFIED_AT, '0');
  const n: number = Number(raw);
  return Number.isFinite(n) ? n : 0;
}

async function setLoginVerifiedAt(ts: number): Promise<void> {
  await setString(PREF_LOGIN_VERIFIED_AT, String(ts));
}

/** 命名空间导出：供 `import { AppPreferences }` 以对象方式调用。 */
export const AppPreferences = {
  initPreferences,
  setString,
  setBoolean,
  setObject,
  getString,
  getBoolean,
  getObject,
  remove,
  putMany,
  removeMany,
  getSettings,
  saveSettings,
  copyAppSettings,
  updateSettings,
  applyThemeMode,
  getTotalListenSeconds,
  addListenSeconds,
  getRecentTracks,
  getFavoriteTracks,
  getPlaylists,
  savePlaylists,
  getPlaylistTombstones,
  savePlaylistTombstones,
  getFavoriteTombstones,
  saveFavoriteTombstones,
  getPlayerState,
  getSearchHistory,
  saveSearchHistory,
  getLoginCookie,
  setLoginCookie,
  getLoginUser,
  setLoginUser,
  getLoginRefreshToken,
  setLoginRefreshToken,
  getLoginVerifiedAt,
  setLoginVerifiedAt
};
