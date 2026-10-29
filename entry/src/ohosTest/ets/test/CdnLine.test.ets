import { describe, it, expect } from '@ohos/hypium';
import {
  CDN_LINE_AUTO,
  CDN_LINE_DEFAULT,
  CDN_LINE_OPTIONS,
  CDN_MIRROR_LINES,
  CdnLineOption,
  cdnLineById,
  cdnLineLabelOf,
  replaceUposHost
} from '../../../main/ets/utils/CdnLine';

// CdnLine 纯函数单测：upos 直链 host 替换、线路表查询。
// 探测（probeCdnLine / probeCdnLinesInOrder）依赖真实网络与偏好存储，不做单测。

const SAMPLE_URL: string =
  'https://upos-sz-estgcos.bilivideo.com/none-music/urlnorm'
  + '/uwawsaicaaXXCKaW7673CaSAZmcGbEaZUUoXXyyKoJKDL-1-30280.m4s'
  + '?e=ut8gebbs&u=1&os=upos&tr=io3&uparams=e,u,os,tr'
  + '&upsig=35da2dc55b5b1a03a173cd0ee704c56b';

/** 与 CDN_LINE_OPTIONS 里的「华为云」等价的手工构造线路（不依赖表内容断言表内容） */
const HW_LINE: CdnLineOption = {
  id: 'hw',
  label: '华为云',
  desc: '',
  uposHost: 'upos-sz-mirrorhw.bilivideo.com'
};

export default function cdnLineTest() {
  describe('CdnLineTest', () => {
    it('cdnLineByIdFindsKnownAndFallsBackOnUnknown', 0, () => {
      // 已知 id：自动 / 默认 / 镜像线路都能查到
      expect(cdnLineById(CDN_LINE_AUTO) !== null).assertTrue();
      expect(cdnLineById(CDN_LINE_DEFAULT) !== null).assertTrue();
      const hw: CdnLineOption | null = cdnLineById('hw');
      expect(hw !== null).assertTrue();
      expect((hw as CdnLineOption).uposHost).assertEqual('upos-sz-mirrorhw.bilivideo.com');
      // 未知 id 返回 null；label 兜底为「默认」
      expect(cdnLineById('nonexistent')).assertEqual(null);
      expect(cdnLineLabelOf('nonexistent')).assertEqual('默认');
      expect(cdnLineLabelOf('hw')).assertEqual('华为云');
    });

    it('cdnLineTableIntegrity', 0, () => {
      // 选项表 = 自动 + 默认 + 镜像线路；镜像线路都带替换 host
      expect(CDN_LINE_OPTIONS.length).assertEqual(CDN_MIRROR_LINES.length + 2);
      for (let i = 0; i < CDN_MIRROR_LINES.length; i++) {
        expect(CDN_MIRROR_LINES[i].uposHost.length > 0).assertTrue();
      }
      // 自动 / 默认不替换 host
      expect((cdnLineById(CDN_LINE_AUTO) as CdnLineOption).uposHost).assertEqual('');
      expect((cdnLineById(CDN_LINE_DEFAULT) as CdnLineOption).uposHost).assertEqual('');
    });

    it('replaceUposHostSwapsHostKeepsPathAndQuery', 0, () => {
      const replaced: string = replaceUposHost(SAMPLE_URL, HW_LINE);
      // host 换掉、path + query（含 upsig 签名）原样保留
      expect(replaced.startsWith('https://upos-sz-mirrorhw.bilivideo.com/none-music/')).assertTrue();
      expect(replaced.endsWith('?e=ut8gebbs&u=1&os=upos&tr=io3&uparams=e,u,os,tr'
        + '&upsig=35da2dc55b5b1a03a173cd0ee704c56b')).assertTrue();
      // 长度差 = 两个 host 的长度差，其余一字不差
      const expectedLen: number = SAMPLE_URL.length - 'upos-sz-estgcos.bilivideo.com'.length
        + 'upos-sz-mirrorhw.bilivideo.com'.length;
      expect(replaced.length).assertEqual(expectedLen);
    });

    it('replaceUposHostKeepsHttpSchemeAndCaseInsensitivePrefix', 0, () => {
      // http 直链同样替换（host 大小写不敏感前缀匹配）
      const httpUrl: string = SAMPLE_URL.replace('https://', 'http://');
      expect(replaceUposHost(httpUrl, HW_LINE).startsWith('http://upos-sz-mirrorhw')).assertTrue();
      const upperUrl: string = 'https://UPOS-sz-estgcos.bilivideo.com/a.m4s?x=1';
      expect(replaceUposHost(upperUrl, HW_LINE)
        .startsWith('https://upos-sz-mirrorhw.bilivideo.com/a.m4s')).assertTrue();
    });

    it('replaceUposHostLeavesNonUposAndNoReplaceLineUntouched', 0, () => {
      // 非 upos 直链（akamai 家族 / 普通链接）不动 —— 没有镜像家族，硬换必 404
      const akamUrl: string =
        'https://upos-hz-mirrorakam.akamaized.net/none-music/a.m4s?e=1&upsig=abc';
      expect(replaceUposHost(akamUrl, HW_LINE)).assertEqual(akamUrl);
      const normal: string = 'https://i0.hdslb.com/bfs/music/a.jpg';
      expect(replaceUposHost(normal, HW_LINE)).assertEqual(normal);
      // 「自动」/「默认」线路（uposHost 为空）对任何链接都不替换
      expect(replaceUposHost(SAMPLE_URL, cdnLineById(CDN_LINE_AUTO) as CdnLineOption))
        .assertEqual(SAMPLE_URL);
      expect(replaceUposHost(SAMPLE_URL, cdnLineById(CDN_LINE_DEFAULT) as CdnLineOption))
        .assertEqual(SAMPLE_URL);
      // 空串 / 裸 host（无路径）防御
      expect(replaceUposHost('', HW_LINE)).assertEqual('');
      expect(replaceUposHost('https://upos-sz-estgcos.bilivideo.com', HW_LINE))
        .assertEqual('https://upos-sz-estgcos.bilivideo.com');
    });
  });
}
