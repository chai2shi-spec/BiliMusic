import { describe, it, expect } from '@ohos/hypium';
import {
  parseDescriptionChapters,
  fetchChaptersFromDescription
} from '../../../main/ets/api/SubtitleLyricApi';
import { CHAPTER_SOURCE_DESC, VideoChapter } from '../../../main/ets/model/MusicModels';

// SubtitleLyricApi 分段简介兜底单测：
// parseDescriptionChapters 覆盖时间戳行解析、采纳闸门（≥2 条 / 越界过滤 /
// 同秒去重）、排序与 to 推导、source 打标；fetchChaptersFromDescription
// 覆盖入参防御（空 bvid/cid 直接空返回，不触网络）。

const DESC_SAMPLE: string = '本视频共三首歌\n\n00:00 第一首·晴天\n01:23 第二首·七里香\n(03:45) 第三首·稻香\n备注：翻唱仅供交流';

export default function chapterDescParseTest() {
  describe('ChapterDescParseTest', () => {
    it('parseReturnsEmptyForEmptyDesc', 0, () => {
      expect(parseDescriptionChapters('', 300).length).assertEqual(0);
      expect(parseDescriptionChapters('纯文字简介没有时间戳', 300).length).assertEqual(0);
    });

    it('parseRejectsSingleTimestampLine', 0, () => {
      // 单行时间戳大概率是正文闲聊（「3:14 我写了一首歌」），采纳闸门拦下
      expect(parseDescriptionChapters('3:14 我写了一首歌，分享给大家', 300).length).assertEqual(0);
    });

    it('parseParsesSampleWithBracketsAndGates', 0, () => {
      const chapters: VideoChapter[] = parseDescriptionChapters(DESC_SAMPLE, 300);
      expect(chapters.length).assertEqual(3);
      expect(chapters[0].from).assertEqual(0);
      expect(chapters[0].title).assertEqual('第一首·晴天');
      expect(chapters[0].to).assertEqual(83);
      expect(chapters[1].from).assertEqual(83);
      expect(chapters[1].to).assertEqual(225);
      // 括号包裹的时间戳行：标题去掉括号后缀、from/to 正确、末段 to = 时长
      expect(chapters[2].from).assertEqual(225);
      expect(chapters[2].to).assertEqual(300);
      expect(chapters[2].title).assertEqual('第三首·稻香');
      // 全部打 'desc' 来源标（ChapterSheet 弹层显示「来自简介解析」）
      expect(chapters[0].source).assertEqual(CHAPTER_SOURCE_DESC);
      expect(chapters[2].source).assertEqual(CHAPTER_SOURCE_DESC);
    });

    it('parseDropsOutOfRangeStampsWhenDurationKnown', 0, () => {
      // 时长 300s：04:59（299s）保留、05:00（300s）越界丢弃
      const desc: string = '0:00 开场\n4:59 尾声\n5:00 越界占位';
      const chapters: VideoChapter[] = parseDescriptionChapters(desc, 300);
      expect(chapters.length).assertEqual(2);
      expect(chapters[1].from).assertEqual(299);
      expect(chapters[1].to).assertEqual(300);
    });

    it('parseSupportsHourStampsAndDedupesSameSecond', 0, () => {
      // h:mm:ss 形态 + 同秒去重（保留首条）
      const desc: string = '1:00:00 后半场\n00:10:00 前半场\n10:00 重复秒';
      const chapters: VideoChapter[] = parseDescriptionChapters(desc, 7200);
      expect(chapters.length).assertEqual(2);
      expect(chapters[0].from).assertEqual(600);
      expect(chapters[0].title).assertEqual('前半场');
      expect(chapters[1].from).assertEqual(3600);
    });

    it('parseFallsBackToOneHourTailWhenDurationUnknown', 0, () => {
      // durationSec = 0（时长未知）：末段 to = from + 3600（消费方只用 from 起点）
      const desc: string = '00:00 引子\n00:30 正片';
      const chapters: VideoChapter[] = parseDescriptionChapters(desc, 0);
      expect(chapters.length).assertEqual(2);
      expect(chapters[1].to).assertEqual(30 + 3600);
    });

    it('fetchReturnsEmptyForBlankParams', 0, async (): Promise<void> => {
      // 入参防御：空 bvid / 空 cid 直接空返回（不触网络）
      const blankBvid: VideoChapter[] = await fetchChaptersFromDescription('', '123', 300);
      expect(blankBvid.length).assertEqual(0);
      const blankCid: VideoChapter[] = await fetchChaptersFromDescription('BV1xx', '', 300);
      expect(blankCid.length).assertEqual(0);
    });
  });
}
