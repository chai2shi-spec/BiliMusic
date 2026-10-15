import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

// aa test 入口：框架按 module.json5 的 testRunner 声明实例化本类，
// onRun 负责拉起 TestAbility；用例真正执行在 TestAbility.onCreate 的 Hypium.hypiumTest。
// （官方模板里另有 mock-config 检查逻辑，本项目不用 hamock，故省略。）

async function onAbilityCreateCallback(data: UIAbility): Promise<void> {
  hilog.info(0x0000, 'testTag', 'onAbilityCreateCallback, data: %{public}s', JSON.stringify(data) ?? '');
}

async function addAbilityMonitorCallback(err: BusinessError): Promise<void> {
  hilog.info(0x0000, 'testTag', 'addAbilityMonitorCallback : %{public}s', JSON.stringify(err) ?? '');
}

export default class OpenHarmonyTestRunner implements TestRunner {
  constructor() {
  }

  onPrepare(): void {
    hilog.info(0x0000, 'testTag', '%{public}s', 'OpenHarmonyTestRunner OnPrepare');
  }

  async onRun(): Promise<void> {
    hilog.info(0x0000, 'testTag', '%{public}s', 'OpenHarmonyTestRunner onRun run');
    const abilityDelegator: abilityDelegatorRegistry.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
    const bundleName: string = abilityDelegatorRegistry.getArguments().bundleName;
    const monitor: abilityDelegatorRegistry.AbilityMonitor = {
      abilityName: 'TestAbility',
      moduleName: 'entry_test',
      onAbilityCreate: onAbilityCreateCallback
    };
    abilityDelegator.addAbilityMonitor(monitor, addAbilityMonitorCallback);
    const want: Want = {
      bundleName: bundleName,
      abilityName: 'TestAbility',
      moduleName: 'entry_test'
    };
    abilityDelegator.startAbility(want, (err: BusinessError) => {
      hilog.info(0x0000, 'testTag', 'startAbility : err : %{public}s', JSON.stringify(err) ?? '');
    });
    hilog.info(0x0000, 'testTag', '%{public}s', 'OpenHarmonyTestRunner onRun end');
  }
}
