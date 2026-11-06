/**
 * 定时停止卡片（1×2，锁屏卡片；renderingMode=autoColor，桌面同样可添加验证）。
 *
 * 数据通道：Form 进程 / UIAbility 进程经 formProvider.updateForm 推 LocalStorage
 * 键（title / singer / sleepOn / sleepText ...，见 CardPayloadBuilder 的
 * LockScreenCard 分支）。定时状态跨进程经 AppSettings.sleepTimerEnd 落盘
 * （AppStorage 不跨进程），文案（「HH:mm 停」）由推送侧格式化好再送。
 * 交互：chip 点击 postCardAction call 拉起 EntryAbility callee
 * （toggleSleepTimer：活跃→取消、未开启→按设置页默认档开启）；空白区点击
 * router 进播放页。
 *
 * 上锁屏需 AGC「锁屏卡片」开放能力审批（手动签名），审批前桌面验证全部交互。
 */

import ActionUtils from '../model/ActionUtils';

let storageUpdateCall = new LocalStorage();

@Entry(storageUpdateCall)
@Component
struct LockScreenCard {
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('title') title: string = 'BiliMusic';
  @LocalStorageProp('singer') singer: string = '未在播放';
  /** 定时停止是否活跃（AppSettings.sleepTimerEnd > now） */
  @LocalStorageProp('sleepOn') sleepOn: boolean = false;
  /** 定时活跃时的结束文案（如「23:30 停」，推送侧格式化好送来） */
  @LocalStorageProp('sleepText') sleepText: string = '定时';

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize(14)
          .fontWeight(700)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.singer)
          .fontSize(11)
          .fontWeight(400)
          .fontColor('#A6FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .padding({ right: 8 })

      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.clock'))
          .fontSize(16)
          .fontColor(['#E6FFFFFF'])

        Text(this.sleepOn && this.sleepText.length > 0 ? this.sleepText : '定时')
          .fontSize(12)
          .fontWeight(500)
          .fontColor(Color.White)
          .maxLines(1)
      }
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(14)
      .backgroundColor('#26FFFFFF')
      .onClick(() => {
        ActionUtils.lockCardSleepToggle(this, this.formId);
      })
      .accessibilityText(this.sleepOn ? '取消定时停止' : '开启定时停止')
    }
    .height('100%')
    .width('100%')
    .linearGradient({
      direction: GradientDirection.Bottom,
      repeating: false,
      colors: [['#FF33365C', 0.0], ['#FF20223B', 1.0]]
    })
    .padding(14)
    .onClick(() => {
      ActionUtils.jumpPlayPage(this);
    })
  }
}
