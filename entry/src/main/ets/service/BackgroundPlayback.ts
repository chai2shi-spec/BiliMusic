/**
 * 后台长时任务（continuousTask）保活。
 *
 * 为什么必须有它：只在 module.json5 声明 ohos.permission.KEEP_BACKGROUND_RUNNING
 * 并不足以让音乐在后台继续播放。应用退到后台或锁屏后，进程会被系统挂起，
 * 表现为「音乐停了、再进应用是重新启动」。必须显式调用
 * backgroundTaskManager.startBackgroundRunning 申请 AUDIO_PLAYBACK 长时任务。
 *
 * 还有一个硬性前提：SDK 的 ContinuousTaskSuspendReason 枚举里存在
 *   SYSTEM_SUSPEND_AUDIO_PLAYBACK_NOT_USE_AVSESSION = 5
 *   SYSTEM_SUSPEND_AUDIO_PLAYBACK_NOT_RUNNING      = 6
 * 即：用了 AUDIO_PLAYBACK 模式但 AVSession 未激活、或会话状态长期不更新，
 * 系统依旧会挂起任务。因此 MusicPlayer 侧必须同时 activate 会话并持续上报播放状态。
 */

import { common, Want } from '@kit.AbilityKit';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';

/** SDK 中 `export type WantAgent = object`，此处用 object 承载以避免类型断言。 */
type LaunchAgent = object;

export class BackgroundPlayback {
  private static instance: BackgroundPlayback | null = null;

  private agent: LaunchAgent | null = null;
  private running: boolean = false;
  private starting: boolean = false;

  static getInstance(): BackgroundPlayback {
    if (!BackgroundPlayback.instance) {
      BackgroundPlayback.instance = new BackgroundPlayback();
    }
    return BackgroundPlayback.instance;
  }

  /**
   * 生成点击后台任务通知后拉起主界面的 WantAgent，结果缓存复用。
   * 失败返回 null——拿不到 agent 就无法申请长时任务，但不应拖垮播放流程。
   */
  async getLaunchAgent(context: common.Context): Promise<LaunchAgent | null> {
    if (this.agent) {
      return this.agent;
    }
    try {
      const uiContext: common.UIAbilityContext = context as common.UIAbilityContext;
      const want: Want = {
        bundleName: uiContext.abilityInfo.bundleName,
        abilityName: uiContext.abilityInfo.name
      };
      const agent: LaunchAgent = await wantAgent.getWantAgent({
        wants: [want],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      this.agent = agent;
      return agent;
    } catch (e) {
      console.error(`getWantAgent failed: ${JSON.stringify(e)}`);
      return null;
    }
  }

  /** 申请 AUDIO_PLAYBACK 长时任务。已在运行或正在申请中则直接返回，避免重复申请报错。 */
  async start(context: common.Context): Promise<void> {
    if (this.running || this.starting) {
      return;
    }
    const agent: LaunchAgent | null = await this.getLaunchAgent(context);
    if (!agent) {
      return;
    }
    this.starting = true;
    try {
      await backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        agent
      );
      this.running = true;
      console.info('continuousTask: AUDIO_PLAYBACK started');
    } catch (e) {
      console.error(`startBackgroundRunning failed: ${JSON.stringify(e)}`);
    } finally {
      this.starting = false;
    }
  }

  /** 停止长时任务。未运行时不调用，避免抛出「任务不存在」类错误。 */
  async stop(context: common.Context): Promise<void> {
    if (!this.running) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      this.running = false;
      console.info('continuousTask: stopped');
    } catch (e) {
      console.error(`stopBackgroundRunning failed: ${JSON.stringify(e)}`);
    }
  }

  /** 供页面在退出登录或清空队列等场景主动复位内部标记。 */
  reset(): void {
    this.running = false;
    this.starting = false;
  }
}
