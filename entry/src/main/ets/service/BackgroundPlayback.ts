/**
 * 后台长时任务（continuousTask）保活 —— 双意愿协调器。
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
 *
 * ── 协调器设计 ──────────────────────────────────────────────────────
 * 系统硬约束：**同一应用同一时刻只能持有一个长时任务**。而本应用有两个后台诉求：
 *   ① 音乐播放 → AUDIO_PLAYBACK（MusicPlayer 申报）
 *   ② 下载队列 → DATA_TRANSFER（DownloadManager 申报）
 *
 * 若两个模块各自 start/stop，必然互相顶掉、甚至在对方不知情时把任务停掉
 * （典型 bug：后台暂停音乐 → MusicPlayer.stop → 进程失去保活 → 下载冻结）。
 *
 * 因此本类收敛为唯一的任务持有者，内部只维护两个「意愿位」：
 *   wantAudio   —— 正在播放音乐
 *   wantTransfer —— 下载队列有活（排队/传输/重试退避中）
 * 每次意愿变化都跑一遍对账（reconcile）：
 *   目标 = wantAudio ? AUDIO_PLAYBACK : (wantTransfer ? DATA_TRANSFER : null)
 *   目标与 currentMode 不同 → 先 stop 旧任务、再 start 新任务。
 * 优先级上播放 > 传输：播放中进程本就存活，下载跟着活；播放停止但下载未完时，
 * 任务从 AUDIO_PLAYBACK 切换到 DATA_TRANSFER 而不是直接释放 —— 这正是
 * 「后台暂停音乐后下载仍继续」的关键路径。
 *
 * 对账串行化（syncing/pendingReconcile）：start/stop 都是异步且可能并发到达
 * （用户边暂停音乐边点恢复下载），不串行会让 stop A/start B 与 stop B/start A
 * 交叉执行，最终持有错误的任务模式。串行 + 「对账期间有新意愿则补跑一轮」保证
 * 任何交错后最终持有的都是最新意愿对应的任务。
 */

import { common, Want } from '@kit.AbilityKit';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';

/** SDK 中 `export type WantAgent = object`，此处用 object 承载以避免类型断言。 */
type LaunchAgent = object;

export class BackgroundPlayback {
  private static instance: BackgroundPlayback | null = null;

  private agent: LaunchAgent | null = null;

  // ── 意愿位与实际持有状态 ────────────────────────────────────────────
  /** MusicPlayer 申报：正在播放，需要 AUDIO_PLAYBACK 保活。 */
  private wantAudio: boolean = false;
  /** DownloadManager 申报：队列有活，需要 DATA_TRANSFER 保活。 */
  private wantTransfer: boolean = false;
  /** 当前实际持有的长时任务模式；null = 未持有任何任务。 */
  private currentMode: backgroundTaskManager.BackgroundMode | null = null;
  /** 一轮对账（stop 旧 + start 新）是否正在进行中。 */
  private syncing: boolean = false;
  /** 对账进行期间又有意愿变化 → 置位，本轮结束后补跑一轮。 */
  private pendingReconcile: boolean = false;

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

  /** 申请音频播放保活。语义等价于「申报播放意愿」，已持有则快速返回。 */
  async start(context: common.Context): Promise<void> {
    await this.setAudioWanted(context, true);
  }

  /**
   * 撤销音频播放保活意愿。
   *
   * 注意：这**不一定**会真的停掉长时任务——若下载侧仍申报着 wantTransfer，
   * 对账会把任务切换到 DATA_TRANSFER 而不是释放。播放侧无需感知下载的存在。
   */
  async stop(context: common.Context): Promise<void> {
    await this.setAudioWanted(context, false);
  }

  /** 播放意愿开关（start/stop 的本体）。 */
  private async setAudioWanted(context: common.Context, wanted: boolean): Promise<void> {
    this.wantAudio = wanted;
    await this.applyWants(context);
  }

  /**
   * 下载侧保活意愿开关（DownloadManager 调用）。
   *
   * 传 wanted=true 表示队列有活（排队/传输/重试退避），false 表示队列跑空或被
   * 全部暂停。与播放侧同理：true 不一定新起任务（播放中复用既有保活），
   * false 不一定释放任务（播放仍在则保留 AUDIO_PLAYBACK）。
   * 所有异常在本层消化，绝不把长时任务的失败传染给下载流程。
   */
  async setTransferWanted(context: common.Context, wanted: boolean): Promise<void> {
    this.wantTransfer = wanted;
    await this.applyWants(context);
  }

  /** 串行对账入口：已在跑则只登记补跑，保证任意时序下最终持有最新意愿对应的任务。 */
  private async applyWants(context: common.Context): Promise<void> {
    if (this.syncing) {
      this.pendingReconcile = true;
      return;
    }
    this.syncing = true;
    try {
      do {
        this.pendingReconcile = false;
        await this.reconcileOnce(context);
      } while (this.pendingReconcile);
    } finally {
      this.syncing = false;
    }
  }

  /**
   * 单轮对账：把实际持有的任务调整到与意愿一致。
   * 全程不向外抛异常——任何一步失败都只记日志并推进本地状态机：
   *   stop 失败：任务多半已被系统回收（如应用被冻结），若因此卡住，
   *     协调器将永久停留在旧模式，之后所有切换全部失效；
   *   start 失败：currentMode 保持 null，下次任意意愿变化会自然重试。
   */
  private async reconcileOnce(context: common.Context): Promise<void> {
    const target: backgroundTaskManager.BackgroundMode | null = this.wantAudio
      ? backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK
      : (this.wantTransfer ? backgroundTaskManager.BackgroundMode.DATA_TRANSFER : null);
    if (target === this.currentMode) {
      return;
    }
    // 先释放旧任务。同一时刻只能持有一个长时任务，模式切换必须 stop→start。
    if (this.currentMode !== null) {
      try {
        await backgroundTaskManager.stopBackgroundRunning(context);
        console.info('continuousTask: stopped');
      } catch (e) {
        console.error(`stopBackgroundRunning failed: ${JSON.stringify(e)}`);
      }
      this.currentMode = null;
    }
    if (target === null) {
      return;
    }
    const agent: LaunchAgent | null = await this.getLaunchAgent(context);
    if (!agent) {
      return;
    }
    try {
      await backgroundTaskManager.startBackgroundRunning(context, target, agent);
      this.currentMode = target;
      const label: string = target === backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK
        ? 'AUDIO_PLAYBACK' : 'DATA_TRANSFER';
      console.info(`continuousTask: ${label} started`);
    } catch (e) {
      console.error(`startBackgroundRunning failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 供页面在退出登录或清空队列等场景主动复位内部标记。
   * 同时清空两侧意愿与实际持有状态——调用方语义是「本应用不再
   * 需要任何保活」，保留旧任务只会留下一条无人认领的常驻通知。
   */
  reset(): void {
    this.wantAudio = false;
    this.wantTransfer = false;
    this.currentMode = null;
    this.syncing = false;
    this.pendingReconcile = false;
  }
}
