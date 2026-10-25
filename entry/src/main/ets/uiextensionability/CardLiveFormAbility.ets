/**
 * 2x2 播控卡溢出互动动效扩展（liveForm，移植自 MusicCard 示例）。
 * form_config 的 sceneAnimationParams.abilityName 指向本扩展；
 * MusicCardFormAbility 触发 requestOverflow 后由本扩展渲染放大 1.5 倍的
 * 溢出内容（uiextensionability/pages/Index：黑胶 + 封面旋转放大动画）。
 * 曲目信息来自播放快照（双进程同沙箱），不依赖 UIAbility 进程存活。
 */

import { UIExtensionContentSession } from '@kit.AbilityKit';
import { LiveFormExtensionAbility, LiveFormInfo } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ensureCardEnv, readCardSnapshot } from '../service/card/CardPayloadBuilder';

const TAG: string = 'CardLiveFormAbility';

export default class CardLiveFormAbility extends LiveFormExtensionAbility {
  async onLiveFormCreate(liveFormInfo: LiveFormInfo, session: UIExtensionContentSession): Promise<void> {
    hilog.info(0x0000, TAG, `onLiveFormCreate, liveFormInfo: ${JSON.stringify(liveFormInfo)}`);
    const storage: LocalStorage = new LocalStorage();
    storage.setOrCreate('formId', liveFormInfo.formId);
    storage.setOrCreate('formRect', liveFormInfo.rect);
    storage.setOrCreate('radius', liveFormInfo.borderRadius);
    // 播放快照（双进程同沙箱）：曲目标题/歌手/封面 URL 经 LocalStorage 传给溢出页
    try {
      await ensureCardEnv(this.context);
      const state = await readCardSnapshot();
      const track = state !== null ? state.currentTrack : null;
      storage.setOrCreate('trackTitle', track !== null ? track.title : '');
      storage.setOrCreate('trackArtist', track !== null ? track.artist : '');
      storage.setOrCreate('coverUrl', track !== null ? track.coverUrl : '');
      storage.setOrCreate('isCollected', track !== null && track.isLiked);
    } catch (e) {
      hilog.error(0x0000, TAG, `load snapshot failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    }
    try {
      session.loadContent('uiextensionability/pages/Index', storage);
    } catch (error) {
      hilog.error(0x0000, TAG, `loadContent catch error: ${JSON.stringify(error)}`);
    }
  }

  onLiveFormDestroy(liveFormInfo: LiveFormInfo): void {
    hilog.info(0x0000, TAG, 'onLiveFormDestroy');
  }
}
