/**
 * 偏好数字集合存取五件套（load/save/is/set/setOf）。
 *
 * 收藏夹「双向」集合（FavTwowayStore，成员=真，正向存储）与
 * 「未勾选」集合（FavSelectionStore，成员=假，倒置存储）同构共用：
 * 「集合成员 ⇔ 语义布尔」的极性由构造参数 memberIsTrue 决定。
 *
 * 非法 id（<=0）恒按「不在集合」的语义极性兜底（成员=真 → false，
 * 成员=假 → true），绝不让坏数据触发写回 / 挡住同步。
 *
 * 存储：单 key `number[]` JSON，体量极小，无需分片；
 * 写入 fire-and-forget（与既有落盘风格一致）。
 */

import { AppPreferences } from '../preferences/AppPreferences';

export class PrefStringSetStore {
  private readonly prefKey: string;
  /** 集合成员资格对应的语义布尔（true = 成员即真；false = 成员即假/倒置存储） */
  private readonly memberIsTrue: boolean;

  constructor(prefKey: string, memberIsTrue: boolean) {
    this.prefKey = prefKey;
    this.memberIsTrue = memberIsTrue;
  }

  /** 读集合原始数组（坏数据 / 老版本缺 key 容错为空数组） */
  load(): number[] {
    const stored: number[] | null = AppPreferences.getObject<number[]>(this.prefKey);
    if (!stored || !Array.isArray(stored)) {
      return [];
    }
    const out: number[] = [];
    for (let i = 0; i < stored.length; i++) {
      const v: number = stored[i];
      if (typeof v === 'number' && v > 0) {
        out.push(v);
      }
    }
    return out;
  }

  /** 整体覆盖写入（fire-and-forget） */
  save(ids: number[]): void {
    AppPreferences.setObject<number[]>(this.prefKey, ids)
      .catch((e: Error): void => {
        console.error(`PrefStringSetStore save(${this.prefKey}) failed: ${e.message}`);
      });
  }

  /** 该 id 的语义布尔（非法 id 按「不在集合」极性兜底） */
  is(id: number): boolean {
    if (!(id > 0)) {
      return !this.memberIsTrue;
    }
    const member: boolean = this.load().indexOf(id) >= 0;
    return this.memberIsTrue ? member : !member;
  }

  /** 设置语义布尔并持久化（幂等：状态没变化时不写盘；非法 id 静默忽略） */
  set(id: number, value: boolean): void {
    if (!(id > 0)) {
      return;
    }
    const wantMember: boolean = this.memberIsTrue ? value : !value;
    const cur: number[] = this.load();
    const idx: number = cur.indexOf(id);
    if (wantMember) {
      if (idx < 0) {
        cur.push(id);
        this.save(cur);
      }
      return;
    }
    if (idx >= 0) {
      cur.splice(idx, 1);
      this.save(cur);
    }
  }

  /** 集合整体读出（调用方一轮只读一次，避免逐条反复读盘） */
  setOf(): Set<number> {
    return new Set<number>(this.load());
  }
}
