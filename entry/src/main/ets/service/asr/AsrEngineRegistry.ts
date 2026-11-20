/**
 * ASR 引擎注册 / 当前引擎选择持久化。
 *
 * 当前引擎 id 写在 AppPreferences（短字符串，远低于 8192 字节上限），
 * 同时镜像到 AppStorage 供 UI 订阅（STORE_ASR_ENGINE_ID 由调用方注册）。
 * 默认系统引擎 —— 老用户行为零变化。
 *
 * NPU 扩展点：将来新增 NpuAsrEngine 时，只需在 createEngine() 的 switch
 * 里加一个 case，Coordinator / UI 不用改。
 */

import { ASR_ENGINE_SYSTEM, AsrEngine, AsrEngineId } from './AsrEngine';
import { findModel, isKnownModel } from './AsrModelCatalog';
import { getInstalledModelDir, getModelState } from './AsrModelManager';
import { getString, setString } from '../../preferences/AppPreferences';

/** 偏好键（短字符串） */
const PREF_ASR_ENGINE: string = 'asrEngineId';
const PREF_ASR_ENABLED: string = 'asrThirdPartyEnabled';

/** 当前引擎 id（内存镜像，避免每次 UI 刷新都读 Preferences） */
let currentId: string = ASR_ENGINE_SYSTEM;
/** 第三方引擎总开关（关闭时强制回落系统引擎，便于一键回退） */
let thirdPartyEnabled: boolean = false;

/** 启动时加载偏好（AppContainer.doInitRest 调用） */
export function initAsrEngineRegistry(): void {
  const saved: string = getString(PREF_ASR_ENGINE, ASR_ENGINE_SYSTEM);
  // 选中的模型已下架（如 2026-11-20 移除的 whisper-small / qwen3-asr-0.6b）→
  // 静默回落到系统识别：否则歌词面板的「AI 转写」会指向已删目录，一点就失败。
  const usable: boolean = saved.length > 0
    && (saved === ASR_ENGINE_SYSTEM || isKnownModel(saved));
  // 2026-11-20 后唯一在册的第三方模型是 SenseVoice：老用户若选过已删模型，
  // 落到系统识别而不是硬塞一个他没下过的模型（避免自动触发下载语义）
  currentId = usable ? saved : ASR_ENGINE_SYSTEM;
  if (!usable) {
    console.info(`[AsrEngine] engine '${saved}' retired -> fallback system`);
    void setString(PREF_ASR_ENGINE, ASR_ENGINE_SYSTEM);
  }
  thirdPartyEnabled = getString(PREF_ASR_ENABLED, '1') === '1';
}

/** 当前引擎 id */
export function currentEngineId(): string {
  return thirdPartyEnabled ? currentId : ASR_ENGINE_SYSTEM;
}

/** 第三方引擎总开关是否开启 */
export function isThirdPartyAsrEnabled(): boolean {
  return thirdPartyEnabled;
}

/** 设置总开关 */
export async function setThirdPartyAsrEnabled(enabled: boolean): Promise<void> {
  thirdPartyEnabled = enabled;
  await setString(PREF_ASR_ENABLED, enabled ? '1' : '0');
}

/** 选择引擎；若目标模型未安装则返回 false（不切换） */
export async function selectAsrEngine(id: string): Promise<boolean> {
  if (id !== ASR_ENGINE_SYSTEM) {
    const spec = findModel(id);
    if (spec === undefined || !getModelState(id).installed) {
      return false;
    }
  }
  currentId = id;
  await setString(PREF_ASR_ENGINE, id);
  return true;
}

/** 当前引擎的展示名（UI 回显） */
export function currentEngineLabel(): string {
  const id: string = currentEngineId();
  if (id === ASR_ENGINE_SYSTEM) {
    return '系统识别';
  }
  const spec = findModel(id);
  return spec !== undefined ? spec.displayName : id;
}

/**
 * 为一次转写创建引擎实例。
 * 注意：系统引擎目前直接调用 LyricTranscribeService 的顶层函数，
 * 其适配器见 SystemAsrEngine.ts（P1 接入）；这里先返回 null 由 Coordinator 兜底。
 */
export function createEngine(id: AsrEngineId): AsrEngine | null {
  // P1 接入具体实现；P0 阶段返回 null 表示「尚未接入」
  return null;
}

/** 当前用引擎的本地模型目录（系统引擎返回空串） */
export function currentModelDir(): string {
  const id: string = currentEngineId();
  if (id === ASR_ENGINE_SYSTEM) {
    return '';
  }
  return getInstalledModelDir(id);
}
