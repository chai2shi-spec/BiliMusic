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

/**
 * 秒 → 播放时间显示文本（m:ss，如 83 → "1:23"）。
 * 负值钳 0；口径同 PlayerProgressArea 的 formatTime（模块内函数不便跨组件
 * 文件复用，抽到歌词工具层供 LrcView 拖动跳转的时间胶囊使用）。
 */
export function formatLrcTime(sec: number): string {
  const s: number = Math.max(0, Math.floor(sec));
  const m: number = Math.floor(s / 60);
  const r: number = s % 60;
  return `${m}:${r < 10 ? '0' : ''}${r}`;
}

/**
 * 毫秒 → LRC 时间标签字符串（[mm:ss.cc]，厘秒两位）。
 * 负值钳 0；超 99 分进位为三位分钟（解析器 \d{2,} 兼容）。
 */
export function formatLrcTimeMs(ms: number): string {
  const clamped = ms > 0 ? Math.floor(ms) : 0;
  const totalCentis = Math.floor(clamped / 10);
  const minutes = Math.floor(totalCentis / 6000);
  const seconds = Math.floor((totalCentis % 6000) / 100);
  const centis = totalCentis % 100;
  const secText = seconds < 10 ? `0${seconds}` : `${seconds}`;
  const centiText = centis < 10 ? `0${centis}` : `${centis}`;
  return `[${minutes}:${secText}.${centiText}]`;
}

/**
 * LrcEntry 列表 → LRC 文本（每行 `${时间标签}${行文本}`）。
 * 供「编辑歌词」sheet 预填与转写结果人工修正。
 */
export function serializeLrcEntries(entries: Array<LrcEntry>): string {
  const lines: string[] = [];
  for (let i = 0; i < entries.length; i++) {
    const text = entries[i].lineWords;
    if (!text) {
      continue;
    }
    lines.push(`${formatLrcTimeMs(entries[i].lineStartTime)}${text}`);
  }
  return lines.join('\n');
}
