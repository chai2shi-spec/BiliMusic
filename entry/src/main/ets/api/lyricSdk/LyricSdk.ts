/**
 * lx 歌词 SDK 注册表。
 *
 * 五源（wy/tx/kg/kw/mg）统一入口：
 *   - searchLxSource(source, keyword, limit)：关键词搜歌，返回候选列表；
 *   - fetchLxLyric(source, input)：按 remoteId 取歌词（LX 逐字 + LRC + 翻译 + 罗马音）。
 *
 * 单源失败静默降级（空数组 / null），不抛错 —— 与旧 LyricsApi 的容错约定一致。
 */

import { LxLyricFetchInput, LxLyricInfo, LxSongCandidate, SOURCE_KG, SOURCE_KW, SOURCE_MG, SOURCE_TX, SOURCE_WY } from './LxLyricTypes';
import { kgGetLyric, kgSearch } from './KgLyricSdk';
import { kwGetLyric, kwSearch } from './KwLyricSdk';
import { mgGetLyric, mgSearch } from './MgLyricSdk';
import { txGetLyric, txSearch } from './TxLyricSdk';
import { wyGetLyric, wySearch } from './WyLyricSdk';

export async function searchLxSource(source: string, keyword: string, limit: number): Promise<LxSongCandidate[]> {
  try {
    if (source === SOURCE_WY) {
      return await wySearch(keyword, limit);
    }
    if (source === SOURCE_TX) {
      return await txSearch(keyword, limit);
    }
    if (source === SOURCE_KG) {
      return await kgSearch(keyword, limit);
    }
    if (source === SOURCE_KW) {
      return await kwSearch(keyword, limit);
    }
    if (source === SOURCE_MG) {
      return await mgSearch(keyword, limit);
    }
  } catch (e) {
    return [];
  }
  return [];
}

export async function fetchLxLyric(source: string, input: LxLyricFetchInput): Promise<LxLyricInfo | null> {
  try {
    if (source === SOURCE_WY) {
      return await wyGetLyric(input);
    }
    if (source === SOURCE_TX) {
      return await txGetLyric(input);
    }
    if (source === SOURCE_KG) {
      return await kgGetLyric(input);
    }
    if (source === SOURCE_KW) {
      return await kwGetLyric(input);
    }
    if (source === SOURCE_MG) {
      return await mgGetLyric(input);
    }
  } catch (e) {
    return null;
  }
  return null;
}
