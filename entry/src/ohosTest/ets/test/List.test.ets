import abilityTest from './Ability.test';
import textUtilTest from './TextUtil.test';
import lrcUtilsTest from './LrcUtils.test';

// hypium 用例注册入口：TestAbility.onCreate 里 Hypium.hypiumTest 以本函数为 suite 根。
export default function testsuite() {
  abilityTest();
  textUtilTest();
  lrcUtilsTest();
}
