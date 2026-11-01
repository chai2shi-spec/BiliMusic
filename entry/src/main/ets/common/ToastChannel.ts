/**
 * 全局 toast 通道的**唯一写实现**（.ts 侧，任何 .ts/.ets 都能 import）。
 *
 * 协议契约（消费端见 AppToast.ets 头注释）：写 AppStorage 三键，由 Index 根部
 * 挂载的 AppToast 组件弹出系统 toast —— .ts 服务拿不到 UIContext，必须走这条桥。
 *
 * ⚠️ 此前三处手抄（showAppToast / MusicPlayer.notifyHint /
 * NeteasePlayChain.notifyHint）已全部收敛到这里：seq 必须读-改-写递增，
 * 多副本各自实现会撞号丢提示（见 Constants.ts STORE_TOAST_SEQ 注释）。
 */

import {
  STORE_TOAST_HOLD_MS,
  STORE_TOAST_MSG,
  STORE_TOAST_SEQ
} from './Constants';
import { PLAYBACK_LOG_INFO, recordPlaybackLog } from '../service/PlaybackLogStore';

/** 全局 toast：写三键触发 AppToast（UI 侧 showAppToast 与播放内核提示共用） */
export function postAppToast(message: string, holdMs: number): void {
  AppStorage.setOrCreate(STORE_TOAST_MSG, message);
  AppStorage.setOrCreate(STORE_TOAST_HOLD_MS, holdMs);
  const seq: number = AppStorage.get<number>(STORE_TOAST_SEQ) ?? -1;
  AppStorage.setOrCreate(STORE_TOAST_SEQ, seq + 1);
}

/**
 * 播放链路用户可见提示：toast + 「日志记录」页留痕（提示级）。
 * MusicPlayer.notifyHint 与 NeteasePlayChain.notifyHint 的共同行为抽此，
 * 防两处各自漂移 —— 提示文案必须与日志页记录一致，真机复现故障时
 * 才能对照「当时弹了什么」。
 */
export function notifyPlaybackHint(message: string, holdMs: number = 1800): void {
  postAppToast(message, holdMs);
  recordPlaybackLog(PLAYBACK_LOG_INFO, message);
}
