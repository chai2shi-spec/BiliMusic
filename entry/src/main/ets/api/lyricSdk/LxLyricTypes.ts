/**
 * lx-music 歌词 SDK 类型定义。
 *
 * 移植自 lx-music-mobile `src/types/music.d.ts` 的 `LX.Music.LyricInfo` 协议：
 * 所有音源（网易云 / 腾讯 / 酷狗 / 酷我 / 咪咕）统一输出四字段，字段名与 lx 保持一致，
 * 上层由 `lyric/LxLyricParser` 统一解析成 LyricLine[]。
 *
 * 各字段语义：
 *   - lyric   逐行歌词（标准 LRC 文本，`[mm:ss.mmm]` 行）
 *   - tlyric  翻译歌词（LRC 文本，空串 = 无）
 *   - rlyric  罗马音歌词（LRC 文本，空串 = 无）
 *   - lxlyric 逐字歌词（LX 自定义格式：`[mm:ss.mmm]<相对起始ms,时长ms>字<...>字`，空串 = 无）
 */

/** 歌词源标识：网易云 */
export const SOURCE_WY: string = 'wy';
/** 歌词源标识：腾讯（QQ 音乐） */
export const SOURCE_TX: string = 'tx';
/** 歌词源标识：酷狗 */
export const SOURCE_KG: string = 'kg';
/** 歌词源标识：酷我 */
export const SOURCE_KW: string = 'kw';
/** 歌词源标识：咪咕 */
export const SOURCE_MG: string = 'mg';

/** 各音源统一输出的歌词信息（lx 协议四字段） */
export interface LxLyricInfo {
  lyric: string;
  tlyric: string;
  rlyric: string;
  lxlyric: string;
}

/** 统一的「取歌词」入参（各源按需取用：kg 需要 title/duration，其余只用 remoteId） */
export interface LxLyricFetchInput {
  /** 源内唯一 id：wy=songId tx=songmid kg=FileHash kw=rid mg=copyrightId */
  remoteId: string;
  /** 歌名（kg 歌词搜索的关键词） */
  title: string;
  artist: string;
  /** 时长（秒） */
  duration: number;
}

/** 某个源搜到的歌曲候选（duration 单位：秒） */
export interface LxSongCandidate {
  source: string;
  /** 源内唯一 id：wy=songId tx=songmid kg=FileHash kw=rid mg=copyrightId */
  remoteId: string;
  title: string;
  artist: string;
  album: string;
  /** 时长（秒），0 = 未知 */
  duration: number;
}

/** 构造一个空的 LxLyricInfo（各源失败兜底 / 部分字段缺失时用） */
export function emptyLxLyricInfo(): LxLyricInfo {
  const info: LxLyricInfo = {
    lyric: '',
    tlyric: '',
    rlyric: '',
    lxlyric: ''
  };
  return info;
}
