/**
 * 桌面卡片常量（移植自 MusicCard 示例 FormCardConstant）。
 *
 * 故意放 .ts 而非 .ets：EntryAbility.ts（callee 注册）也要 import 这些枚举，
 * .ets 文件禁止被 .ts 导入。卡片页面 / Form 扩展（.ets）反向 import .ts 无碍。
 */

export const ENTRY_ABILITY = 'EntryAbility';
/** Form 扩展（module.json5 extensionAbilities.name，postCardAction message 用） */
export const FORM_ABILITY = 'MusicCardFormAbility';
/** liveForm 溢出动效扩展名（form_config sceneAnimationParams / module.json5 一致） */
export const LIVE_FORM_ABILITY = 'CardLiveFormAbility';

export enum FormCarAction {
  CALL = 'call',
  ROUTER = 'router',
}

export enum FormCardName {
  LYRICS = 'LyricsCard',
  CONTROL_2X2 = 'PlayControlCard2x2',
  CONTROL_2X4 = 'PlayControlCard2x4',
  DYNAMIC_LYRICS = 'DynamicLyrics',
}

export enum PlayActionType {
  PAUSE = '0',
  PLAY = '1',
  PREVIOUS = '2',
  NEXT = '3',
}

export enum RouterType {
  PLAYER = '1',
  LYRICS = '2',
}

export enum CallMethod {
  PLAY_BY_ACTION = 'playByAction',
  COLLECT_ACTION = 'collectAction',
}

export enum CollectAction {
  COLLECTED = '1',
  UNCOLLECTED = '0',
}

/** 溢出动效：卡片视觉区放大的倍率（formProvider.requestOverflow） */
export const LIVE_CARD_RATIO: number = 1.5;
/** 溢出动效过渡时长（ms） */
export const OVERFLOW_DURATION_MS: number = 3500;
/** 溢出页黑胶组件的左/下边距（vp，示例同款标定值） */
export const ANIMATE_COMPONENT_LEFT: number = 51;
export const ANIMATE_COMPONENT_BOTTOM: number = 41;
