/**
 * 桌面卡片 Form 扩展（移植自 MusicCard 示例 EntryFormAbility，BiliMusic 适配）。
 *
 * 生命周期职责：
 *  · onAddForm —— 解析 formId/name/dimension 存入 CardFormStore（独立小 RDB），
 *    全量推一次卡片载荷（CardPayloadBuilder 读播放快照自给）；
 *    2x2 播控卡额外触发一次溢出动效（requestOverflow 放大 1.5 倍）；
 *  · onUpdateForm —— 系统定点刷新（updateDuration 到点）时按卡片名重推；
 *  · onFormEvent —— 2x2 卡「开始播放」的 message（requestOverFlow）→ 再触发溢出；
 *  · onRemoveForm —— 桌面移除卡片 → 删记录；
 *  · 本进程不依赖 UIAbility 进程存活：快照（PlayerStateStore 双 JSON）、
 *    歌词缓存、封面下载全部自理（ensureCardEnv）。
 */

import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CardFormStore, CardFormRecord } from '../service/card/CardFormStore';
import { pushCardToForm } from '../service/card/CardPayloadBuilder';
import { LIVE_CARD_RATIO, OVERFLOW_DURATION_MS } from '../widget/model/CardFormConstant';

const TAG: string = 'MusicCardFormAbility';

export default class MusicCardFormAbility extends FormExtensionAbility {
  onAddForm(want: Want) {
    hilog.info(0x0000, TAG, 'onAddForm');
    if (want.parameters) {
      const formId: string = `${want.parameters['ohos.extra.param.key.form_identity'] ?? ''}`;
      const formName: string = `${want.parameters['ohos.extra.param.key.form_name'] ?? ''}`;
      const formDimension: string = `${want.parameters['ohos.extra.param.key.form_dimension'] ?? ''}`;
      hilog.info(0x0000, TAG,
        `onAddForm formId=${formId} formName=${formName} formDimension=${formDimension}`);
      const record: CardFormRecord = new CardFormRecord();
      record.formId = formId;
      record.formName = formName;
      record.formDimension = formDimension;
      const context = this.context;
      CardFormStore.getInstance().init(context)
        .then(async (): Promise<void> => {
          await CardFormStore.getInstance().insert(record);
          await pushCardToForm(context, formId, formName);
        })
        .catch((e: Error): void => {
          hilog.error(0x0000, TAG, `onAddForm push failed: ${e.message}`);
        });
      if (formName === 'PlayControlCard2x2') {
        this.trigger3DLiveRequest(formId);
      }
    }
    return formBindingData.createFormBindingData('');
  }

  onCastToNormalForm(formId: string) {
    hilog.info(0x0000, TAG, 'onCastToNormalForm');
  }

  onUpdateForm(formId: string) {
    hilog.info(0x0000, TAG, `onUpdateForm formId=${formId}`);
    const context = this.context;
    CardFormStore.getInstance().init(context)
      .then(async (): Promise<CardFormRecord | null> => {
        const records: CardFormRecord[] = await CardFormStore.getInstance().queryAll();
        for (let i = 0; i < records.length; i++) {
          if (records[i].formId === formId) {
            return records[i];
          }
        }
        return null;
      })
      .then(async (record: CardFormRecord | null): Promise<void> => {
        if (record !== null) {
          await pushCardToForm(context, record.formId, record.formName);
        }
      })
      .catch((e: Error): void => {
        hilog.error(0x0000, TAG, `onUpdateForm failed: ${e.message}`);
      });
  }

  /** 2x2 卡溢出互动动效：视觉区放大 LIVE_CARD_RATIO 倍（liveForm 扩展接管渲染） */
  private trigger3DLiveRequest(formId: string): void {
    formProvider.getFormRect(formId).then((data: formInfo.Rect) => {
      const cardWidth: number = data.width * LIVE_CARD_RATIO;
      const cardHeight: number = data.height * LIVE_CARD_RATIO;
      const leftOffset: number = (data.width - cardWidth) / 2;
      const topOffset: number = (data.height - cardHeight) / 2;
      formProvider.requestOverflow(formId, {
        area: {
          left: leftOffset,
          top: topOffset,
          width: cardWidth,
          height: cardHeight
        },
        duration: OVERFLOW_DURATION_MS
      }).then((): void => {
        hilog.info(0x0000, TAG, 'requestOverflow result succeed');
      }).catch((error: BusinessError) => {
        hilog.error(0x0000, TAG, `requestOverflow catch error, code: ${error.code}, message: ${error.message}`);
      });
    }).catch((error: BusinessError) => {
      hilog.error(0x0000, TAG, `getFormRect catch error, code: ${error.code}, message: ${error.message}`);
    });
  }

  onFormEvent(formId: string, message: string) {
    hilog.info(0x0000, TAG, `onFormEvent formId=${formId} message=${message}`);
    try {
      const parsed: Record<string, Object> = JSON.parse(message);
      const shortMessage: string = `${parsed.message ?? ''}`;
      if (shortMessage === 'requestOverFlow') {
        this.trigger3DLiveRequest(formId);
      }
    } catch (e) {
      hilog.error(0x0000, TAG, `onFormEvent parse failed: ${JSON.stringify(e)}`);
    }
  }

  onRemoveForm(formId: string) {
    hilog.info(0x0000, TAG, `onRemoveForm formId=${formId}`);
    const context = this.context;
    CardFormStore.getInstance().init(context)
      .then(async (): Promise<void> => {
        await CardFormStore.getInstance().remove(formId);
      })
      .catch((e: Error): void => {
        hilog.error(0x0000, TAG, `onRemoveForm failed: ${e.message}`);
      });
  }

  onAcquireFormState(want: Want) {
    return formInfo.FormState.READY;
  }
}
