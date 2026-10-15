import { describe, it, expect } from '@ohos/hypium';

// 冒烟用例：只验证测试框架本身能起来（断言可用、结果能回传），
// 不依赖任何业务代码——业务用例挂在 TextUtil/LrcUtils 两个 suite 里。
export default function abilityTest() {
  describe('ActsAbilityTest', () => {
    it('assertSmoke', 0, () => {
      expect('abc').assertContain('b');
      expect('abc').assertEqual('abc');
    });
  });
}
