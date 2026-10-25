/**
 * 搜索状态持有器：单次搜索会话内「页面 / 标题栏行」同源共享关键词与结果。
 *
 * 不跨实例持久：每次进入搜索页都是全新状态（不恢复上次结果），
 * SearchPage.aboutToAppear 调 clear() 清空。类保留是因为搜索进行中
 * 页面与 SearchInputBar 仍需同一份会话词（AppStorage 之外的静态真源，
 * 防页面销毁重建丢「正在搜」的状态）。
 */

import { Track } from '../model/MusicModels';

export class SearchStateHolder {
  static keyword: string = '';
  static results: Track[] = [];

  static save(keyword: string, results: Track[]): void {
    SearchStateHolder.keyword = keyword;
    SearchStateHolder.results = results;
  }

  /** 每次进入搜索页时清空（SearchPage.aboutToAppear 调用）：不带上次的关键词与结果 */
  static clear(): void {
    SearchStateHolder.keyword = '';
    SearchStateHolder.results = [];
  }
}
