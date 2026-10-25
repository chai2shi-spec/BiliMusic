/**
 * 卡片 postCardAction 封装（移植自 MusicCard 示例 ActionUtils）。
 * postCardAction 是卡片环境全局函数，仅可在卡片页面（.ets）内调用。
 */

import { CallMethod, CollectAction, ENTRY_ABILITY, FormCarAction, PlayActionType, RouterType, FORM_ABILITY } from './CardFormConstant';

class ActionUtils {
  /**
   * 播控指令 → call 拉起 EntryAbility callee（后台可执行，不弹界面）。
   * @param component 卡片组件
   * @param type '0'暂停 '1'播放 '2'上一首 '3'下一首
   * @param formId 卡片 id
   */
  public playByAction(component: Object, type: PlayActionType, formId: string): void {
    postCardAction(component, {
      action: FormCarAction.CALL,
      abilityName: ENTRY_ABILITY,
      params: {
        method: CallMethod.PLAY_BY_ACTION,
        playActionType: type,
        formId: formId
      }
    });
  }

  /**
   * 收藏指令 → call 拉起 EntryAbility callee。
   * @param component 卡片组件
   * @param type '0'取消收藏 '1'收藏
   * @param formId 卡片 id
   * @param songId 曲目 id
   */
  public collectAction(component: Object, type: CollectAction, formId: string, songId: string): void {
    postCardAction(component, {
      action: FormCarAction.CALL,
      abilityName: ENTRY_ABILITY,
      params: {
        method: CallMethod.COLLECT_ACTION,
        collectActionType: type,
        formId: formId,
        songId: songId
      }
    });
  }

  /** 点卡片空白区 → router 拉起应用进播放页 */
  public jumpPlayPage(component: Object): void {
    postCardAction(component, {
      action: FormCarAction.ROUTER,
      abilityName: ENTRY_ABILITY,
      params: {
        type: RouterType.PLAYER
      }
    });
  }

  /** 2x2 卡「开始播放」时的溢出动效触发（Form 扩展 onFormEvent 收 message） */
  public requestOverflow(component: Object): void {
    postCardAction(component, {
      action: 'message',
      abilityName: FORM_ABILITY,
      params: {
        message: 'requestOverFlow'
      }
    });
  }
}

export default new ActionUtils();
