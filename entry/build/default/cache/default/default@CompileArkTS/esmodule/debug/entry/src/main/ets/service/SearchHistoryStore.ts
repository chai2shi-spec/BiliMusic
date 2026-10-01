import { AppPreferences } from "@normalized:N&&&entry/src/main/ets/preferences/AppPreferences&";
/** 历史上限：显示与存储共用（用户要求最多显示 20 条） */
export const SEARCH_HISTORY_MAX: number = 20;
let historyCache: string[] | null = null;
/** 归一化磁盘数据：丢「非字符串 / 空白 / 重复」，并截到上限（旧版本写坏的 Preferences 也要能读） */
function sanitize(raw: string[]): string[] {
    if (!Array.isArray(raw)) {
        return [];
    }
    const out: string[] = [];
    for (let i = 0; i < raw.length; i++) {
        const item: string = raw[i];
        if (typeof item !== 'string') {
            continue;
        }
        const word: string = item.trim();
        if (word.length === 0 || out.indexOf(word) >= 0) {
            continue;
        }
        out.push(word);
        if (out.length >= SEARCH_HISTORY_MAX) {
            break;
        }
    }
    return out;
}
/** 读取搜索历史（返回副本：调用方拿到内部数组时改它不会触发 UI 刷新） */
export function getSearchHistory(): string[] {
    if (historyCache === null) {
        historyCache = sanitize(AppPreferences.getSearchHistory());
    }
    return historyCache.slice();
}
function persistHistory(): void {
    AppPreferences.saveSearchHistory(historyCache ?? []).catch((e: Error): void => {
        // 落盘失败只影响「重启后还在不在」，本次会话的展示不受影响
        console.error(`saveSearchHistory failed: ${e.message}`);
    });
}
export function addSearchHistory(word: string): string[] {
    const trimmed: string = word.trim();
    if (trimmed.length === 0) {
        return getSearchHistory();
    }
    const next: string[] = [trimmed];
    const old: string[] = getSearchHistory();
    for (let i = 0; i < old.length; i++) {
        if (old[i] !== trimmed && next.length < SEARCH_HISTORY_MAX) {
            next.push(old[i]);
        }
    }
    historyCache = next;
    persistHistory();
    return historyCache.slice();
}
export function clearSearchHistory(): void {
    historyCache = [];
    persistHistory();
}
/** 命名空间导出：与 `LibraryStore` 保持一致的调用风格 */
export const SearchHistoryStore = {
    getSearchHistory,
    addSearchHistory,
    clearSearchHistory
};
