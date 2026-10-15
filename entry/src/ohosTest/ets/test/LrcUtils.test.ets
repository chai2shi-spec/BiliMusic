import { describe, it, expect } from '@ohos/hypium';
import { parseLrcLyric } from '../../../main/ets/lyric/LrcUtils';

// LrcUtils.parseLrcLyric 单测：LRC 解析、乱序行排序、行时长推导、无标签行跳过。
// KRC 解析暂未接入业务（见 LrcUtils 头注释），先不覆盖。

export default function lrcUtilsTest() {
  describe('LrcUtilsTest', () => {
    it('parseLrcLyricReturnsEmptyForEmptyInput', 0, () => {
      expect(parseLrcLyric('').length).assertEqual(0);
    });

    it('parseLrcLyricSortsAndComputesDurations', 0, () => {
      // 故意乱序：解析后应按起始时间升序，行时长 = 下一行起始 - 本行起始
      const lines = parseLrcLyric('[00:21.98]hello\n[00:10.00]world');
      expect(lines.length).assertEqual(2);
      expect(lines[0].lineStartTime).assertEqual(10000);
      expect(lines[0].lineWords).assertEqual('world');
      expect(lines[0].lineDuration).assertEqual(11980);
      expect(lines[1].lineStartTime).assertEqual(21980);
      // 最后一行时长无限大：唱完后仍保持高亮
      expect(lines[1].lineDuration).assertEqual(Number.MAX_VALUE);
    });

    it('parseLrcLyricSkipsUntaggedLines', 0, () => {
      const lines = parseLrcLyric('[00:10.00]world\nno tag line');
      expect(lines.length).assertEqual(1);
      expect(lines[0].lineWords).assertEqual('world');
    });
  });
}
