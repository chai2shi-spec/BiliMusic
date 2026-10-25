/**
 * 歌词数据模型。
 * 时间单位全部为毫秒。
 */

/** 逐字条目（KRC 逐字歌词用；本项目行级歌词 words 为空数组） */
export interface Word {
  text: string;
  /** 相对行起始的偏移（ms） */
  wordStartTime: number;
  duration: number;
}

export interface LrcEntry {
  lineStartTime: number;
  lineDuration: number;
  lineWords: string;
  /** 逐字内容（行级歌词为空） */
  words: Word[];
  /**
   * 副行文本（翻译 / 罗马音），按顺序在歌词下方各占一行。
   * 可选：行级歌词 / 无翻译的歌不填，LrcView 据此跳过副行绘制。
   */
  subLines?: string[];
}
