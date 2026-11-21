/**
 * ASR 引擎注册 / 当前引擎选择持久化。
 *
 * 只服务第三方转写模型（系统 speechRecognizer 链路已于 2026-11-21 移除）：
 * 当前引擎 id 为空串 = 未选择任何模型（AI 转写入口引导去「转写模型」页下载）。
 *
 * 当前引擎 id 写在 AppPreferences（短字符串，远低于 8192 字节上限），
 * 同时镜像到 AppStorage 供 UI 订阅（STORE_ASR_ENGINE_ID 由调用方注册）。
 *
 * NPU 扩展点：将来新增 NpuAsrEngine 时，只需在 Coordinator.makeEngine()
 * 的分派里加一个 case，Registry / UI 不用改。
 */

import { isKnownModel, findModel } from './AsrModelCatalog';
import { getInstalledModelDir, getModelState } from './AsrModelManager';
import { getString, setString } from '../../preferences/AppPreferences';

/** 偏好键（短字符串） */
const PREF_ASR_ENGINE: string = 'asrEngineId';

/** 未选择任何引擎的哨兵值（老用户偏好里的 'system' / 已下架 id 统一迁移到这里） */
const ENGINE_NONE: string = '';

/** 当前引擎 id（内存镜像，避免每次 UI 刷新都读 Preferences；空串 = 未选择） */
let currentId: string = ENGINE_NONE;

/** 启动时加载偏好（AppContainer.doInitRest 调用） */
export function initAsrEngineRegistry(): void {
  const saved: string = getString(PREF_ASR_ENGINE, ENGINE_NONE);
  // 迁移：2026-11-21 删除系统识别引擎后，存量 'system' 不再是合法值；
  // 已下架模型（如 whisper-small / qwen3-asr-0.6b）同样静默回落「未选择」。
  const usable: boolean = saved.length > 0 && isKnownModel(saved);
  currentId = usable ? saved : ENGINE_NONE;
  if (!usable && saved !== ENGINE_NONE) {
    console.info(`[AsrEngine] engine '${saved}' unavailable -> cleared`);
    void setString(PREF_ASR_ENGINE, ENGINE_NONE);
  }
}

/** 当前引擎 id（空串 = 未选择） */
export function currentEngineId(): string {
  return currentId;
}

/** 是否已选用且安装就绪的第三方模型（UI 按钮可用态判定） */
export function hasReadyAsrEngine(): boolean {
  return currentId.length > 0 && isKnownModel(currentId) && getModelState(currentId).installed;
}

/** 选择引擎；若目标模型未安装则返回 false（不切换） */
export async function selectAsrEngine(id: string): Promise<boolean> {
  const spec = findModel(id);
  if (spec === undefined || !getModelState(id).installed) {
    return false;
  }
  currentId = id;
  await setString(PREF_ASR_ENGINE, id);
  return true;
}

/** 清空当前引擎（删除在用模型后回「未选择」态） */
export async function clearAsrEngine(): Promise<void> {
  currentId = ENGINE_NONE;
  await setString(PREF_ASR_ENGINE, ENGINE_NONE);
}

/** 当前引擎的展示名（UI 回显） */
export function currentEngineLabel(): string {
  if (currentId.length === 0) {
    return '未选择';
  }
  const spec = findModel(currentId);
  return spec !== undefined ? spec.displayName : currentId;
}

/** 当前用引擎的本地模型目录（未选择返回空串） */
export function currentModelDir(): string {
  if (currentId.length === 0) {
    return '';
  }
  return getInstalledModelDir(currentId);
}
