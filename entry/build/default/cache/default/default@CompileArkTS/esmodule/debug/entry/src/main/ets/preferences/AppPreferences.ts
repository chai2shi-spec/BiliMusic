import dataPreferences from "@ohos:data.preferences";
import type common from "@ohos:app.ability.common";
import ConfigurationConstant from "@ohos:app.ability.ConfigurationConstant";
import { DEFAULT_APP_SETTINGS, ThemeMode } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
import type { AppSettings } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
import { PREF_SETTINGS, PREF_RECENT, PREF_FAVORITES, PREF_PLAYLISTS, PREF_PLAYLIST_TOMBSTONES, PREF_FAVORITE_TOMBSTONES, PREF_PLAYER_STATE, PREF_SEARCH_HISTORY, PREF_TOTAL_LISTEN_SECONDS } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
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
export async function setBoolean(key: string, value: boolean): Promise<void> {
    const p = ensure();
    await p.put(key, value);
    await p.flush();
}
export async function setObject<T>(key: string, value: T): Promise<void> {
    const p = ensure();
    await p.put(key, JSON.stringify(value));
    await p.flush();
}
export function getString(key: string, def: string = ''): string {
    return ensure().getSync(key, def) as string;
}
export function getBoolean(key: string, def: boolean = false): boolean {
    return ensure().getSync(key, def) as boolean;
}
export function getObject<T>(key: string): T | null {
    const raw: string = ensure().getSync(key, '') as string;
    if (!raw) {
        return null;
    }
    try {
        return JSON.parse(raw) as T;
    }
    catch (e) {
        return null;
    }
}
export async function remove(key: string): Promise<void> {
    const p = ensure();
    await p.delete(key);
    await p.flush();
}
export function getSettings(): AppSettings {
    const stored: Partial<AppSettings> | null = getObject<Partial<AppSettings>>(PREF_SETTINGS);
    return {
        sidebarState: stored?.sidebarState ?? DEFAULT_APP_SETTINGS.sidebarState,
        playQuality: stored?.playQuality ?? DEFAULT_APP_SETTINGS.playQuality,
        downloadQuality: stored?.downloadQuality ?? DEFAULT_APP_SETTINGS.downloadQuality,
        downloadDir: stored?.downloadDir ?? DEFAULT_APP_SETTINGS.downloadDir,
        autoPlay: stored?.autoPlay ?? DEFAULT_APP_SETTINGS.autoPlay,
        showLyrics: stored?.showLyrics ?? DEFAULT_APP_SETTINGS.showLyrics,
        wifiOnlyDownload: stored?.wifiOnlyDownload ?? DEFAULT_APP_SETTINGS.wifiOnlyDownload,
        wifiOnlyPlay: stored?.wifiOnlyPlay ?? DEFAULT_APP_SETTINGS.wifiOnlyPlay,
        themeMode: stored?.themeMode ?? DEFAULT_APP_SETTINGS.themeMode
    };
}
export async function saveSettings(s: AppSettings): Promise<void> {
    await setObject<AppSettings>(PREF_SETTINGS, s);
}
/**
 * 把主题设置真正应用到应用（设置页切换时 + 启动恢复时调用）。
 *
 * 此前 themeMode 只被存储和展示、从未生效：EntryAbility 曾强制锁定浅色，
 * 设置页的「主题」循环点击只改标签不改变际颜色模式。深色模式适配后补上这一环。
 *
 * COLOR_MODE_NOT_SET（-1）即「跟随系统」；setColorMode 是运行时设置，
 * 每次启动都要重新应用（EntryAbility 在 loadContent 前调用），不落盘。
 */
export function applyThemeMode(context: common.Context, mode: ThemeMode): void {
    let target: number;
    if (mode === ThemeMode.DARK) {
        target = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    else if (mode === ThemeMode.LIGHT) {
        target = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    else {
        target = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    }
    try {
        context.getApplicationContext().setColorMode(target);
    }
    catch (e) {
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
export function getTotalListenSeconds(): number {
    try {
        return ensure().getSync(PREF_TOTAL_LISTEN_SECONDS, 0) as number;
    }
    catch (e) {
        return 0;
    }
}
export async function addListenSeconds(delta: number): Promise<void> {
    if (delta <= 0) {
        return;
    }
    const p = ensure();
    const cur: number = p.getSync(PREF_TOTAL_LISTEN_SECONDS, 0) as number;
    await p.put(PREF_TOTAL_LISTEN_SECONDS, cur + delta);
    await p.flush();
}
export function getRecentTracks<T>(): T[] {
    return getObject<T[]>(PREF_RECENT) ?? [];
}
export async function saveRecentTracks<T>(list: T[]): Promise<void> {
    await setObject<T[]>(PREF_RECENT, list.slice(0, 50));
}
export function getFavoriteTracks<T>(): T[] {
    return getObject<T[]>(PREF_FAVORITES) ?? [];
}
export async function saveFavoriteTracks<T>(list: T[]): Promise<void> {
    await setObject<T[]>(PREF_FAVORITES, list);
}
export function getPlaylists<T>(): T[] {
    return getObject<T[]>(PREF_PLAYLISTS) ?? [];
}
export async function savePlaylists<T>(list: T[]): Promise<void> {
    await setObject<T[]>(PREF_PLAYLISTS, list);
}
export function getPlaylistTombstones<T>(): T[] {
    return getObject<T[]>(PREF_PLAYLIST_TOMBSTONES) ?? [];
}
export async function savePlaylistTombstones<T>(list: T[]): Promise<void> {
    await setObject<T[]>(PREF_PLAYLIST_TOMBSTONES, list);
}
export function getFavoriteTombstones<T>(): T[] {
    return getObject<T[]>(PREF_FAVORITE_TOMBSTONES) ?? [];
}
export async function saveFavoriteTombstones<T>(list: T[]): Promise<void> {
    await setObject<T[]>(PREF_FAVORITE_TOMBSTONES, list);
}
export function getSearchHistory(): string[] {
    return getObject<string[]>(PREF_SEARCH_HISTORY) ?? [];
}
export async function saveSearchHistory(list: string[]): Promise<void> {
    await setObject<string[]>(PREF_SEARCH_HISTORY, list);
}
export function getPlayerState<T>(): T | null {
    return getObject<T>(PREF_PLAYER_STATE);
}
export async function savePlayerState<T>(state: T): Promise<void> {
    await setObject<T>(PREF_PLAYER_STATE, state);
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
    getSettings,
    saveSettings,
    applyThemeMode,
    getTotalListenSeconds,
    addListenSeconds,
    getRecentTracks,
    saveRecentTracks,
    getFavoriteTracks,
    saveFavoriteTracks,
    getPlaylists,
    savePlaylists,
    getPlaylistTombstones,
    savePlaylistTombstones,
    getFavoriteTombstones,
    saveFavoriteTombstones,
    getPlayerState,
    savePlayerState,
    getSearchHistory,
    saveSearchHistory
};
