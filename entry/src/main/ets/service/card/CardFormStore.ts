/**
 * 桌面卡片 id 存储（独立小 RDB：bilimusic_card.db / 表 form_card）。
 *
 * 为什么独立库而不并入 bilimusic_rdb.db：卡片 Form 扩展进程与 UIAbility
 * 进程都要读写，且 Form 进程不该触碰主库（下载表）的初始化链路；独立小库
 * 双进程各自 getRdbStore 连接同一文件即可（SQLite 多连接安全）。
 * 初始化幂等：initPromise 缓存，两进程各持一份实例（模块级单例按进程隔离）。
 */

import relationalStore from '@ohos.data.relationalStore';
import common from '@ohos.app.ability.common';
import { CARD_DB_NAME } from '../../common/Constants';

const TABLE_FORM_CARD: string = 'form_card';

const CREATE_FORM_CARD_SQL: string =
  `CREATE TABLE IF NOT EXISTS ${TABLE_FORM_CARD} (` +
  `formId TEXT PRIMARY KEY, ` +
  `formName TEXT, ` +
  `formDimension TEXT)`;

/** 卡片记录（一张已添加到桌面的卡片） */
export class CardFormRecord {
  formId: string = '';
  formName: string = '';
  formDimension: string = '';
}

export class CardFormStore {
  private static instance: CardFormStore | null = null;

  static getInstance(): CardFormStore {
    if (CardFormStore.instance === null) {
      CardFormStore.instance = new CardFormStore();
    }
    return CardFormStore.instance;
  }

  private store: relationalStore.RdbStore | null = null;
  private initPromise: Promise<void> | null = null;

  /** 初始化（幂等）：建表，失败允许下次重试 */
  init(context: common.Context): Promise<void> {
    if (this.initPromise === null) {
      const pending: Promise<void> = this.doInit(context);
      pending.catch((): void => {
        if (this.initPromise === pending) {
          this.initPromise = null;
        }
      });
      this.initPromise = pending;
    }
    return this.initPromise;
  }

  private async doInit(context: common.Context): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: CARD_DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    this.store = await relationalStore.getRdbStore(context, config);
    await this.store.executeSql(CREATE_FORM_CARD_SQL);
  }

  private ensure(): relationalStore.RdbStore {
    if (this.store === null) {
      throw new Error('CardFormStore not initialized');
    }
    return this.store;
  }

  /** 新增/覆盖一条卡片记录（REPLACE 语义：同 formId 重复添加安全） */
  async insert(record: CardFormRecord): Promise<void> {
    const store: relationalStore.RdbStore = this.ensure();
    const values: relationalStore.ValuesBucket = {
      'formId': record.formId,
      'formName': record.formName,
      'formDimension': record.formDimension
    };
    await store.insert(TABLE_FORM_CARD, values,
      relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
  }

  /** 卡片从桌面移除时删除记录 */
  async remove(formId: string): Promise<void> {
    const store: relationalStore.RdbStore = this.ensure();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_FORM_CARD);
    predicates.equalTo('formId', formId);
    await store.delete(predicates);
  }

  /** 全量卡片（CardPublisher 启动回填用） */
  async queryAll(): Promise<CardFormRecord[]> {
    const store: relationalStore.RdbStore = this.ensure();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_FORM_CARD);
    return this.readRecords(await store.query(predicates));
  }

  /** 按卡片名查（推某类卡时过滤） */
  async queryByName(formName: string): Promise<CardFormRecord[]> {
    const store: relationalStore.RdbStore = this.ensure();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_FORM_CARD);
    predicates.equalTo('formName', formName);
    return this.readRecords(await store.query(predicates));
  }

  private readRecords(rs: relationalStore.ResultSet): CardFormRecord[] {
    const records: CardFormRecord[] = [];
    try {
      const idIdx: number = rs.getColumnIndex('formId');
      const nameIdx: number = rs.getColumnIndex('formName');
      const dimIdx: number = rs.getColumnIndex('formDimension');
      while (rs.goToNextRow()) {
        const record: CardFormRecord = new CardFormRecord();
        record.formId = rs.getString(idIdx);
        record.formName = rs.getString(nameIdx);
        record.formDimension = rs.getString(dimIdx);
        records.push(record);
      }
    } finally {
      rs.close();
    }
    return records;
  }
}
