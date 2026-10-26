/**
 * 歌词解析工具。
 *
 * 本项目歌词由 LyricsApi（QQ 音乐 LRC）提供行级时间轴，行级数据在
 * LyricsComponent 里直接转 LrcEntry；这里的 LRC 解析器保留备用。
 */

import { LrcEntry } from './LrcEntry';

/** LRC 行时间标签，如 [00:21.98] */
const lrcLineRegex: RegExp = new RegExp('\\[\\d{2,}:\\d{2}((\\.|:)\\d{2,})\\]', 'g');
const lrcTimeRegex1: RegExp = new RegExp('\\[\\d{2,}', 'i');
const lrcTimeRegex2: RegExp = new RegExp('\\d{2}\\.\\d{2,}', 'i');

/**
 * 解析 LRC 格式歌词（[00:21.98] 歌词文本）。
 * 行时长 = 下一行起始 - 本行起始（最后一行无限长，保证唱完后仍高亮）。
 */
export function parseLrcLyric(text: string): Array<LrcEntry> {
  if (!text) {
    return [];
  }
  let lyric: string[] = text.split('\n');
  let lrc = new Array<LrcEntry>();
  for (let i = 0; i < lyric.length; i++) {
    let lineTime = lyric[i].match(lrcLineRegex);
    let lineText = lyric[i].replace(lrcLineRegex, '');
    if (lineTime && lineText) {
      for (let j = 0; j < lineTime.length; j++) {
        let min = Number(String(lineTime[j].match(lrcTimeRegex1)).slice(1));
        let sec = Number.parseFloat(String(lineTime[j].match(lrcTimeRegex2)));
        let timeInSeconds = (min * 60 + sec) * 1000;
        lrc.push({
          lineStartTime: timeInSeconds,
          lineDuration: 0,
          lineWords: lineText,
          words: []
        });
      }
    }
  }
  if (lrc && lrc.length > 0) {
    lrc.sort((a: LrcEntry, b: LrcEntry): number => {
      return a.lineStartTime - b.lineStartTime;
    });
    for (let i = 0; i < lrc.length; i++) {
      if (i === lrc.length - 1) {
        lrc[i].lineDuration = Number.MAX_VALUE;
      } else {
        lrc[i].lineDuration = lrc[i + 1].lineStartTime - lrc[i].lineStartTime;
      }
    }
  } else {
    console.error('Failed to parse the lyrics.');
  }
  return lrc;
}

export function angleToRadian(angle: number): number {
  return angle * Math.PI / 180;
}
