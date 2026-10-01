import type { LrcEntry, Word } from './LrcEntry';
/** LRC 行时间标签，如 [00:21.98] */
const lrcLineRegex: RegExp = new RegExp('\\[\\d{2,}:\\d{2}((\\.|:)\\d{2,})\\]', 'g');
const lrcTimeRegex1: RegExp = new RegExp('\\[\\d{2,}', 'i');
const lrcTimeRegex2: RegExp = new RegExp('\\d{2}\\.\\d{2,}', 'i');
/** KRC 行 / 逐字标签 */
const krcLineRegex: RegExp = new RegExp('\\[(\\d+),(\\d+)\\](.*)');
const krcWordRegex1: RegExp = new RegExp('<(\\d+),(\\d+),(\\d+)>([^<]*)', 'g');
const krcWordRegex2: RegExp = new RegExp('<(\\d+),(\\d+),(\\d+)>(.*)');
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
            }
            else {
                lrc[i].lineDuration = lrc[i + 1].lineStartTime - lrc[i].lineStartTime;
            }
        }
    }
    else {
        console.error('Failed to parse the lyrics.');
    }
    return lrc;
}
/**
 * 解析 KRC（酷狗逐字）格式歌词：[494,228]<0,38,0>词<38,38,0>句…
 */
export function parseKrcLyric(lyricText: string): LrcEntry[] {
    const lines: string[] = lyricText.split('\n');
    const lyricLines: LrcEntry[] = [];
    for (const line of lines) {
        const matches = line.match(krcLineRegex);
        if (matches) {
            const lineStartTime = Number.parseInt(matches[1]);
            const lineDuration = Number.parseInt(matches[2]);
            const lineWordsText = matches[3];
            const words: Word[] = [];
            const wordsMatches = lineWordsText.match(krcWordRegex1);
            let lineWords: string = '';
            if (wordsMatches) {
                for (const wordMatch of wordsMatches) {
                    const wordMatches = wordMatch.match(krcWordRegex2);
                    if (wordMatches) {
                        const wordStartTime = Number.parseInt(wordMatches[1]);
                        const wordDuration = Number.parseInt(wordMatches[2]);
                        const wordText = wordMatches[4];
                        lineWords += wordText;
                        words.push({
                            text: wordText,
                            wordStartTime: wordStartTime,
                            duration: wordDuration
                        });
                    }
                }
            }
            lyricLines.push({
                lineStartTime: lineStartTime,
                lineDuration: lineDuration,
                lineWords: lineWords,
                words: words
            });
        }
    }
    lyricLines.sort((a: LrcEntry, b: LrcEntry): number => {
        return a.lineStartTime - b.lineStartTime;
    });
    return lyricLines;
}
export function angleToRadian(angle: number): number {
    return angle * Math.PI / 180;
}
