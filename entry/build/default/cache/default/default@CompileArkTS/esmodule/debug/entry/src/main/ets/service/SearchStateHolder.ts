import type { Track } from '../model/MusicModels';
export class SearchStateHolder {
    static keyword: string = '';
    static results: Track[] = [];
    static save(keyword: string, results: Track[]): void {
        SearchStateHolder.keyword = keyword;
        SearchStateHolder.results = results;
    }
}
