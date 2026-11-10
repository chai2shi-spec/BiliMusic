/**
 * 云同步数据变更监听（监听注册的间接层）。
 *
 * 为什么需要：CloudSyncManager 要在「歌单 / 拾音数据变更」后去抖触发一轮
 * 云端读取（方案 §5.5「数据变更后 debounce 20s」），但 AppStorage 没有
 * 变更回调，而 LibraryStore / PlaySessionStore 又不能反向 import
 * CloudSyncManager（会成环：Manager → LibraryStore → Manager）。
 *
 * 解法与全站 TrackDedupKeeper / setChapterPublishListener 同款：
 * 数据侧只 import 本模块这个无依赖小文件，在唯一落盘点调
 * notifyCloudSyncDataChanged()；CloudSyncManager 初始化时把真正的
 * 处理器挂进来。Manager 未初始化时通知自然 no-op（零开销空转）。
 */

type CloudSyncDataListener = () => void;

let listener: CloudSyncDataListener | null = null;

/** CloudSyncManager.init 注册；置 null 即注销。 */
export function setCloudSyncDataListener(l: CloudSyncDataListener | null): void {
  listener = l;
}

/**
 * 媒体库 / 拾音数据已变更（LibraryStore.persistPlaylists /
 * PlaySessionStore.appendSession / mergeBackupSessions 调用）。
 * 未注册监听时静默 no-op。
 */
export function notifyCloudSyncDataChanged(): void {
  if (listener !== null) {
    listener();
  }
}
