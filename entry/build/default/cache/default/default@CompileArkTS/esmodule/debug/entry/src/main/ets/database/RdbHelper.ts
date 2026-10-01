import relationalStore from "@ohos:data.relationalStore";
import type common from "@ohos:app.ability.common";
import { DB_NAME, DB_VERSION, TABLE_DOWNLOAD } from "@normalized:N&&&entry/src/main/ets/common/Constants&";
let store: relationalStore.RdbStore | null = null;
const CREATE_DOWNLOAD_SQL: string = `CREATE TABLE IF NOT EXISTS ${TABLE_DOWNLOAD} (` +
    `id TEXT PRIMARY KEY, ` +
    `musicId TEXT, title TEXT, artist TEXT, coverUrl TEXT, url TEXT, ` +
    `totalBytes INTEGER, downloadedBytes INTEGER, status TEXT, errorMessage TEXT, ` +
    `createdAt INTEGER, completedAt INTEGER, localFilePath TEXT)`;
export async function initRdb(context: common.Context): Promise<void> {
    const config: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
    };
    store = await relationalStore.getRdbStore(context, config);
    if (DB_VERSION > 1) {
        await store.executeSql(CREATE_DOWNLOAD_SQL);
    }
    else {
        await store.executeSql(CREATE_DOWNLOAD_SQL);
    }
}
export function getRdb(): relationalStore.RdbStore {
    if (!store) {
        throw new Error('RDB not initialized');
    }
    return store;
}
export { TABLE_DOWNLOAD };
