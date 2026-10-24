import { describe, it, expect } from '@ohos/hypium';
import {
  artistSegments,
  toHttpsUrl,
  toThumbUrl,
  cleanTitle,
  parseLrc,
  queryCandidates,
  scoreCandidate,
  ScoreContext
} from '../../../main/ets/utils/TextUtil';
import { LyricCandidate } from '../../../main/ets/model/MusicModels';

// TextUtil 纯函数单测：URL 规范化/缩略图、标题清洗、LRC 解析、候选打分。
// 这些函数无 UI / 存储依赖，是歌词搜索链路里最值得回归测试的部分。

function makeCandidate(name: string, duration: number, artist: string = '周杰伦'): LyricCandidate {
  return {
    id: '1',
    songId: '1',
    mid: '',
    trackName: name,
    artistName: artist,
    albumName: '',
    duration: duration,
    image: ''
  };
}

export default function textUtilTest() {
  describe('TextUtilTest', () => {
    it('toHttpsUrlNormalizesProtocols', 0, () => {
      expect(toHttpsUrl('')).assertEqual('');
      expect(toHttpsUrl('//i0.hdslb.com/a.jpg')).assertEqual('https://i0.hdslb.com/a.jpg');
      expect(toHttpsUrl('http://example.com/x')).assertEqual('https://example.com/x');
      expect(toHttpsUrl('https://example.com/x')).assertEqual('https://example.com/x');
      expect(toHttpsUrl('custom://example.com/x')).assertEqual('custom://example.com/x');
    });

    it('toThumbUrlAppendsSizeOnlyForHdslb', 0, () => {
      expect(toThumbUrl('http://i0.hdslb.com/bfs/a.jpg', 96))
        .assertEqual('https://i0.hdslb.com/bfs/a.jpg@96w_96h_1c.jpg');
      // 已带 @ 参数的 URL 不重复追加
      expect(toThumbUrl('https://i0.hdslb.com/bfs/a.jpg@96w_96h_1c.jpg', 96))
        .assertEqual('https://i0.hdslb.com/bfs/a.jpg@96w_96h_1c.jpg');
      // 非图床链接不添后缀
      expect(toThumbUrl('https://example.com/a.jpg', 96)).assertEqual('https://example.com/a.jpg');
      expect(toThumbUrl('', 96)).assertEqual('');
    });

    it('cleanTitleStripsNoise', 0, () => {
      expect(cleanTitle('')).assertEqual('');
      // 方括号内是纯噪声词 → 整段丢弃
      expect(cleanTitle('【官方MV】晴天')).assertEqual('晴天');
      // 书名号内容保留
      expect(cleanTitle('《晴天》')).assertEqual('晴天');
      // 拉丁噪声词
      expect(cleanTitle('Song Name (Official Audio)')).assertEqual('Song Name');
    });

    it('cleanTitleFallsBackToRawWhenAllNoise', 0, () => {
      // 全部被清洗掉时回退到原始标题（截断 40 字符），保证搜索词不为空串
      expect(cleanTitle('【纯享版】')).assertEqual('【纯享版】');
    });

    it('parseLrcSortsAndSkipsMeta', 0, () => {
      const lines = parseLrc('[00:21.98]hello\n[00:10.00]world\n[ti:meta]\nplain line');
      expect(lines.length).assertEqual(2);
      expect(lines[0].time).assertEqual(10);
      expect(lines[0].text).assertEqual('world');
      expect(lines[1].time).assertEqual(21.98);
      expect(lines[1].text).assertEqual('hello');
    });

    it('parseLrcHandlesMultiTimeTags', 0, () => {
      const lines = parseLrc('[00:01.00][00:05.00]x');
      expect(lines.length).assertEqual(2);
      expect(lines[0].time).assertEqual(1);
      expect(lines[1].time).assertEqual(5);
      expect(lines[0].text).assertEqual('x');
      expect(lines[1].text).assertEqual('x');
    });

    it('queryCandidatesPrefersQuotedTitle', 0, () => {
      const cands: string[] = queryCandidates('《晴天》周杰伦');
      expect(cands.length > 0).assertTrue();
      expect(cands[0]).assertEqual('晴天');
    });

    it('scoreCandidateRewardsExactMatchAndDuration', 0, () => {
      const ctx: ScoreContext = { rawTitle: '晴天', clean: '晴天', duration: 269, quoted: [] };
      // 命中原始标题 +360，时长差 1s 内 +130，其余为 0
      expect(scoreCandidate(makeCandidate('晴天', 270), ctx)).assertEqual(490);
    });

    it('scoreCandidatePenalizesDurationMismatch', 0, () => {
      const ctx: ScoreContext = { rawTitle: '晴天', clean: '晴天', duration: 269, quoted: [] };
      const good: number = scoreCandidate(makeCandidate('晴天', 270), ctx);
      const bad: number = scoreCandidate(makeCandidate('晴天', 600), ctx);
      expect(bad).assertLess(good);
    });

    it('scoreCandidatePenalizesInstrumental', 0, () => {
      const ctx: ScoreContext = { rawTitle: '晴天', clean: '晴天', duration: 269, quoted: [] };
      const normal: number = scoreCandidate(makeCandidate('晴天', 270), ctx);
      const karaoke: number = scoreCandidate(makeCandidate('晴天 伴奏', 270), ctx);
      expect(karaoke).assertLess(normal);
    });

    it('artistSegmentsSplitsAndCleans', 0, () => {
      // 多歌手按分隔符拆开并逐段清洗；去重；空串返回空数组
      const segs: string[] = artistSegments('周杰伦 / 费玉清');
      expect(segs.length).assertEqual(2);
      expect(segs[0]).assertEqual('周杰伦');
      expect(segs[1]).assertEqual('费玉清');
      expect(artistSegments('')).assertDeepEquals([]);
      expect(artistSegments('【官方】')).assertDeepEquals([]);
    });

    it('scoreCandidateRewardsArtistMatch', 0, () => {
      // 2026-10-23 修匹配：本机 artist 与候选歌手命中 → +240；
      // 候选歌手不同且不在标题里 → 无此加分。两者标题、时长一致，只有歌手差异。
      const ctx: ScoreContext = {
        rawTitle: '晴天',
        clean: '晴天',
        duration: 269,
        quoted: [],
        artist: '周杰伦'
      };
      const hit: number = scoreCandidate(makeCandidate('晴天', 270, '周杰伦'), ctx);
      const miss: number = scoreCandidate(makeCandidate('晴天', 270, '某某翻唱'), ctx);
      expect(hit - miss).assertEqual(240);
      // 不传 artist（旧调用方 / 旧行为）→ 不加分、不影响原分值
      const ctxNoArtist: ScoreContext = { rawTitle: '晴天', clean: '晴天', duration: 269, quoted: [] };
      expect(scoreCandidate(makeCandidate('晴天', 270, '某某翻唱'), ctxNoArtist)).assertEqual(490);
    });
  });
}
