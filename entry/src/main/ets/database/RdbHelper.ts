/**
 * RDB 帮助类（替代原 Room）。
 * 使用 @ohos.data.relationalStore 存储下载任务等关系型数据。
 */

import relationalStore from '@ohos.data.relationalStore';
import common from '@ohos.app.ability.common';
import { DB_NAME, TABLE_DOWNLOAD } from '../common/Constants';

let store: relationalStore.RdbStore | null = null;

const CREATE_DOWNLOAD_SQL: string =
  `CREATE TABLE IF NOT EXISTS ${TABLE_DOWNLOAD} (` +
  `id TEXT PRIMARY KEY, ` +
  `musicId TEXT, title TEXT, artist TEXT, coverUrl TEXT, url TEXT, ` +
  `totalBytes INTEGER, downloadedBytes INTEGER, status TEXT, errorMessage TEXT, ` +
  `createdAt INTEGER, completedAt INTEGER, localFilePath TEXT, ` +
  `playlistId TEXT, playlistName TEXT, ` +
  // 合集归属三件套（2026-10-08）：新库直接建全列；老库走下方 ensureColumns 幂等补列
  `collectionTitle TEXT, partNo INTEGER, partTotal INTEGER)`;

/**
 * 给已存在的表补列（幂等）。
 *
 * **为什么必须自己写迁移**：鸿蒙 RDB 的 `StoreConfig` **没有 version 字段**，
 * `RdbStore.version` 是只读属性（SDK `relationalStore.d.ts:3813`）——
 * 也就是说没有任何「版本升级」钩子可用。而 `CREATE TABLE IF NOT EXISTS` 遇到已存在的表
 * **什么都不会做**，老用户的库里没有新列 → 之后每次 insert 都报「no such column」。
 *
 * SQLite 的 `ADD COLUMN` 不支持 `IF NOT EXISTS`，重复执行会报错，所以先查列清单。
 */
async function ensureColumns(existing: relationalStore.RdbStore, table: string,
  columns: Array<{ name: string; ddl: string }>): Promise<void> {
  const rs: relationalStore.ResultSet = await existing.querySql(`PRAGMA table_info(${table})`);
  const present: Set<string> = new Set<string>();
  // PRAGMA 结果集的第 1 列是列名（cid / name / type / notnull / dflt_value / pk）
  const nameIndex: number = rs.getColumnIndex('name');
  while (rs.goToNextRow()) {
    present.add(rs.getString(nameIndex));
  }
  rs.close();
  for (let i = 0; i < columns.length; i++) {
    if (present.has(columns[i].name)) {
      continue;
    }
    await existing.executeSql(`ALTER TABLE ${table} ADD COLUMN ${columns[i].ddl}`);
    console.info(`rdb migration: added column ${columns[i].name} to ${table}`);
  }
}

export async function initRdb(context: common.Context): Promise<void> {
  const config: relationalStore.StoreConfig = {
    name: DB_NAME,
    securityLevel: relationalStore.SecurityLevel.S1
  };
  store = await relationalStore.getRdbStore(context, config);
  await store.executeSql(CREATE_DOWNLOAD_SQL);
  // 老库补列（对新库是空操作）
  await ensureColumns(store, TABLE_DOWNLOAD, [
    { name: 'playlistId', ddl: 'playlistId TEXT' },
    { name: 'playlistName', ddl: 'playlistName TEXT' },
    // 合集归属三件套（2026-10-08）：老任务缺列时补默认值，
    // TEXT 补 NULL / INTEGER 补 NULL，读取侧（MusicDao.fromRow）会兜成 ''/0
    { name: 'collectionTitle', ddl: 'collectionTitle TEXT' },
    { name: 'partNo', ddl: 'partNo INTEGER' },
    { name: 'partTotal', ddl: 'partTotal INTEGER' }
  ]);
  // musicId 二级索引（2026-10-23 性能审查）：getDownloadByMusicId 是合集/歌单
  // 入队查重的热路径（N 分 P 合集 = N 次查询），无索引时全表扫；
  // IF NOT EXISTS 幂等，老库新库都安全。
  await store.executeSql(
    `CREATE INDEX IF NOT EXISTS idx_download_musicId ON ${TABLE_DOWNLOAD}(musicId)`);
}

export function getRdb(): relationalStore.RdbStore {
  if (!store) {
    throw new Error('RDB not initialized');
  }
  return store;
}

export { TABLE_DOWNLOAD };
