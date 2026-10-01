/**
 * 搜索状态持有器：搜索关键词与结果脱离组件生命周期持久保存。
 * 底部页签切换导致 SearchPage 重建时，结果从 holder 恢复，不再丢失。
 */

import { Track } from '../model/MusicModels';

export class SearchStateHolder {
  static keyword: string = '';
  static results: Track[] = [];

  static save(keyword: string, results: Track[]): void {
    SearchStateHolder.keyword = keyword;
    SearchStateHolder.results = results;
  }
}
