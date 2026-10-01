import relationalStore from "@ohos:data.relationalStore";
import { getRdb, TABLE_DOWNLOAD } from "@normalized:N&&&entry/src/main/ets/database/RdbHelper&";
import { DownloadStatus } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
import type { DownloadTask } from "@normalized:N&&&entry/src/main/ets/model/MusicModels&";
const COLUMNS: string[] = [
    'id',
    'musicId',
    'title',
    'artist',
    'coverUrl',
    'url',
    'totalBytes',
    'downloadedBytes',
    'status',
    'errorMessage',
    'createdAt',
    'completedAt',
    'localFilePath'
];
function toRow(t: DownloadTask): relationalStore.ValuesBucket {
    return {
        id: t.id,
        musicId: t.musicId,
        title: t.title,
        artist: t.artist,
        coverUrl: t.coverUrl,
        url: t.url,
        totalBytes: t.totalBytes,
        downloadedBytes: t.downloadedBytes,
        status: t.status,
        errorMessage: t.errorMessage,
        createdAt: t.createdAt,
        completedAt: t.completedAt,
        localFilePath: t.localFilePath
    };
}
function parseStatus(s: string): DownloadStatus {
    if (s === DownloadStatus.PENDING) {
        return DownloadStatus.PENDING;
    }
    if (s === DownloadStatus.DOWNLOADING) {
        return DownloadStatus.DOWNLOADING;
    }
    if (s === DownloadStatus.PAUSED) {
        return DownloadStatus.PAUSED;
    }
    if (s === DownloadStatus.COMPLETED) {
        return DownloadStatus.COMPLETED;
    }
    if (s === DownloadStatus.ERROR) {
        return DownloadStatus.ERROR;
    }
    return DownloadStatus.PENDING;
}
function fromRow(rs: relationalStore.ResultSet): DownloadTask {
    try {
        return {
            id: rs.getString(rs.getColumnIndex('id')),
            musicId: rs.getString(rs.getColumnIndex('musicId')),
            title: rs.getString(rs.getColumnIndex('title')),
            artist: rs.getString(rs.getColumnIndex('artist')),
            coverUrl: rs.getString(rs.getColumnIndex('coverUrl')),
            url: rs.getString(rs.getColumnIndex('url')),
            totalBytes: rs.getDouble(rs.getColumnIndex('totalBytes')),
            downloadedBytes: rs.getDouble(rs.getColumnIndex('downloadedBytes')),
            // speed 不落库：速度是瞬时量，数据库没有这一列，从库里读回来的任务只能给 0
            speed: 0,
            // audioQuality / audioBandwidth 是内存态字段（不落库），读回来一律给 0
            audioQuality: 0,
            audioBandwidth: 0,
            status: parseStatus(rs.getString(rs.getColumnIndex('status'))),
            errorMessage: rs.getString(rs.getColumnIndex('errorMessage')),
            createdAt: rs.getDouble(rs.getColumnIndex('createdAt')),
            completedAt: rs.getDouble(rs.getColumnIndex('completedAt')),
            localFilePath: rs.getString(rs.getColumnIndex('localFilePath'))
        };
    }
    catch (e) {
        console.error(`read row failed: ${JSON.stringify(e)}`);
        throw e;
    }
}
function closeQuietly(rs: relationalStore.ResultSet): void {
    try {
        rs.close();
    }
    catch (e) {
        console.error(`close result set failed: ${JSON.stringify(e)}`);
    }
}
export async function insertDownload(task: DownloadTask): Promise<void> {
    try {
        await getRdb().insert(TABLE_DOWNLOAD, toRow(task), relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    }
    catch (e) {
        console.error(`insert download failed: ${JSON.stringify(e)}`);
        throw e;
    }
}
export async function getAllDownloads(): Promise<DownloadTask[]> {
    try {
        const rs: relationalStore.ResultSet = await getRdb().query(new relationalStore.RdbPredicates(TABLE_DOWNLOAD), COLUMNS);
        const list: DownloadTask[] = [];
        while (rs.goToNextRow()) {
            list.push(fromRow(rs));
        }
        closeQuietly(rs);
        return list;
    }
    catch (e) {
        console.error(`query downloads failed: ${JSON.stringify(e)}`);
        throw e;
    }
}
export async function getDownloadById(id: string): Promise<DownloadTask | null> {
    const pred: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_DOWNLOAD);
    pred.equalTo('id', id);
    try {
        const rs: relationalStore.ResultSet = await getRdb().query(pred, COLUMNS);
        let task: DownloadTask | null = null;
        if (rs.goToNextRow()) {
            task = fromRow(rs);
        }
        closeQuietly(rs);
        return task;
    }
    catch (e) {
        console.error(`query download by id failed: ${JSON.stringify(e)}`);
        throw e;
    }
}
export async function getDownloadByMusicId(musicId: string): Promise<DownloadTask | null> {
    const pred: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_DOWNLOAD);
    pred.equalTo('musicId', musicId);
    try {
        const rs: relationalStore.ResultSet = await getRdb().query(pred, COLUMNS);
        let task: DownloadTask | null = null;
        if (rs.goToNextRow()) {
            task = fromRow(rs);
        }
        closeQuietly(rs);
        return task;
    }
    catch (e) {
        console.error(`query download by musicId failed: ${JSON.stringify(e)}`);
        throw e;
    }
}
export async function updateDownloadProgress(id: string, downloadedBytes: number, totalBytes: number, status: DownloadStatus): Promise<void> {
    const pred: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_DOWNLOAD);
    pred.equalTo('id', id);
    const values: relationalStore.ValuesBucket = {
        downloadedBytes: downloadedBytes,
        totalBytes: totalBytes,
        status: status
    };
    try {
        await getRdb().update(values, pred);
    }
    catch (e) {
        console.error(`update download progress failed: ${JSON.stringify(e)}`);
    }
}
export async function updateDownloadStatus(id: string, status: DownloadStatus, localFilePath: string = '', completedAt: number = 0): Promise<void> {
    const pred: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_DOWNLOAD);
    pred.equalTo('id', id);
    const values: relationalStore.ValuesBucket = {
        status: status,
        localFilePath: localFilePath,
        completedAt: completedAt
    };
    try {
        await getRdb().update(values, pred);
    }
    catch (e) {
        console.error(`update download status failed: ${JSON.stringify(e)}`);
    }
}
export async function deleteDownload(id: string): Promise<void> {
    const pred: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_DOWNLOAD);
    pred.equalTo('id', id);
    try {
        await getRdb().delete(pred);
    }
    catch (e) {
        console.error(`delete download failed: ${JSON.stringify(e)}`);
    }
}
