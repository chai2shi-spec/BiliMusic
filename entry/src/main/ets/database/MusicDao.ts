import relationalStore from '@ohos.data.relationalStore';
import { getRdb, TABLE_DOWNLOAD } from './RdbHelper';
import { DownloadTask, DownloadStatus } from '../model/MusicModels';

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
  'localFilePath',
  // 来源歌单（整单下载的任务有），空串 = 本人
  'playlistId',
  'playlistName',
  // 合集归属三件套：多 P 视频下载的显式标记，单视频为 ''/0
  'collectionTitle',
  'partNo',
  'partTotal'
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
    localFilePath: t.localFilePath,
    playlistId: t.playlistId,
    playlistName: t.playlistName,
    collectionTitle: t.collectionTitle,
    partNo: t.partNo,
    partTotal: t.partTotal
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
      localFilePath: rs.getString(rs.getColumnIndex('localFilePath')),
      // 这两口在老库里是 NULL，getString 返回空串（不会抛错）
      playlistId: rs.getString(rs.getColumnIndex('playlistId')),
      playlistName: rs.getString(rs.getColumnIndex('playlistName')),
      // 合集三件套：老库补列后是 NULL——getString→''，getDouble→NaN 需兜成 0
      collectionTitle: rs.getString(rs.getColumnIndex('collectionTitle')),
      partNo: rs.getDouble(rs.getColumnIndex('partNo')) || 0,
      partTotal: rs.getDouble(rs.getColumnIndex('partTotal')) || 0
    };
  } catch (e) {
    console.error(`read row failed: ${JSON.stringify(e)}`);
    throw e;
  }
}

function closeQuietly(rs: relationalStore.ResultSet): void {
  try {
    rs.close();
  } catch (e) {
    console.error(`close result set failed: ${JSON.stringify(e)}`);
  }
}

export async function insertDownload(task: DownloadTask): Promise<void> {
  try {
    await getRdb().insert(TABLE_DOWNLOAD, toRow(task), relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
  } catch (e) {
    console.error(`insert download failed: ${JSON.stringify(e)}`);
    throw e;
  }
}

/**
 * 事务包裹：fn 内的 RDB 写一次性提交。N 条逐条 await = N 次独立磁盘事务
 * （各带一次 journal/fsync 往返），是启动装载（loadFromDb 中断任务批修）与
 * 批量入队（整单/合集下载 N 条 insert）路径的 IO 放大主源。
 * fn 抛错整体回滚并继续抛出；调用方需保证 fn 短小（纯 RDB 操作，
 * 不夹网络/文件等长 await），且避免与其他并发写在事务窗口内交错 ——
 * 事务打开期间经同一 RdbStore 的其他写会并入本事务，一起被 commit/回滚。
 */
export async function withTransaction(fn: () => Promise<void>): Promise<void> {
  const rdb: relationalStore.RdbStore = getRdb();
  await rdb.beginTransaction();
  try {
    await fn();
    await rdb.commit();
  } catch (e) {
    try {
      await rdb.rollBack();
    } catch (rollbackErr) {
      console.error(`rollback transaction failed: ${JSON.stringify(rollbackErr)}`);
    }
    throw e;
  }
}

/** 批量插入下载任务：单事务一次提交；冲突语义与 insertDownload 一致（REPLACE） */
export async function insertDownloads(tasks: DownloadTask[]): Promise<void> {
  if (tasks.length === 0) {
    return;
  }
  await withTransaction(async (): Promise<void> => {
    for (let i = 0; i < tasks.length; i++) {
      await getRdb().insert(TABLE_DOWNLOAD, toRow(tasks[i]),
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    }
  });
}

export async function getAllDownloads(): Promise<DownloadTask[]> {
  try {
    const rs: relationalStore.ResultSet = await getRdb().query(
      new relationalStore.RdbPredicates(TABLE_DOWNLOAD),
      COLUMNS
    );
    const list: DownloadTask[] = [];
    while (rs.goToNextRow()) {
      list.push(fromRow(rs));
    }
    closeQuietly(rs);
    return list;
  } catch (e) {
    console.error(`query downloads failed: ${JSON.stringify(e)}`);
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
  } catch (e) {
    console.error(`query download by musicId failed: ${JSON.stringify(e)}`);
    throw e;
  }
}

export async function updateDownloadProgress(
  id: string,
  downloadedBytes: number,
  totalBytes: number,
  status: DownloadStatus
): Promise<void> {
  const pred: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_DOWNLOAD);
  pred.equalTo('id', id);
  const values: relationalStore.ValuesBucket = {
    downloadedBytes: downloadedBytes,
    totalBytes: totalBytes,
    status: status
  };
  try {
    await getRdb().update(values, pred);
  } catch (e) {
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
  } catch (e) {
    console.error(`update download status failed: ${JSON.stringify(e)}`);
  }
}

export async function deleteDownload(id: string): Promise<void> {
  const pred: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_DOWNLOAD);
  pred.equalTo('id', id);
  try {
    await getRdb().delete(pred);
  } catch (e) {
    console.error(`delete download failed: ${JSON.stringify(e)}`);
  }
}
