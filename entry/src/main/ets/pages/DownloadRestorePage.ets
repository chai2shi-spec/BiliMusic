/**
 * 「扫描并恢复已下载歌曲」预览页。
 *
 * 为什么单独开一个二级页而不是在设置页弹个窗：五类清单 + 勾选/全选 + 进度 +
 * 联网补全取消 + 手动指定 bvid + 二次确认，信息量远超一行设置项；且扫描可能
 * 持续分钟级，状态放在单例 + AppStorage 里，页面被回收再回来仍能接着看。
 *
 * ⚠️ 目录授权（DOWNLOAD 模式 Picker）必须在**用户手势内**触发，所以这里不放
 * aboutToAppear 自动扫描，而是 IDLE 态给一个「扫描下载目录」按钮。
 *
 * 数据边界：本页只调用 DownloadRestoreManager；只读扫描阶段不写任何库，
 * 写库只在用户勾选 + showConfirm 二次确认之后。
 */

import common from '@ohos.app.ability.common';
import { SearchResultItem } from '../model/MusicModels';
import {
  DownloadRestoreManager,
  RestorePhase,
  RestoreState,
  emptyRestoreState
} from '../service/DownloadRestoreManager';
import { RestoreCategory, RestoreItem } from '../service/DownloadRestoreScanner';
import { STORE_RESTORE_STATE, STORE_SAFE_BOTTOM, STORE_SAFE_TOP, STORE_THEME_PRIMARY } from '../common/Constants';
import { showAppInfoDialog, showConfirm } from '../components/AppAlertDialog';
import { showAppToast } from '../components/AppToast';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { NavTitleRow } from '../components/NavTitleRow';
import { BarNarrowShell } from '../components/BarNarrowShell';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { NavStackHolder } from '../service/NavStackHolder';
import { HdsNavDestination } from '@kit.UIDesignKit';

/** 字节数 → 简写（清单里只需要量级，避免再拉一个格式化模块） */
function sizeText(bytes: number): string {
  if (bytes >= 1024 * 1024) {
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }
  if (bytes >= 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  return `${bytes} B`;
}

@Component
export struct DownloadRestorePage {
  /** 单例广播的扫描快照 */
  @StorageLink(STORE_RESTORE_STATE) @Watch('onRestoreStateChanged') restoreState: RestoreState = emptyRestoreState();
  @StorageProp(STORE_SAFE_TOP) safeTop: number = 0;
  @StorageProp(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';

  /** 手动指定覆盖层：当前条目 id / 输入 BV / 候选列表 */
  @State manualItemId: string = '';
  @State manualBvid: string = '';
  @State manualCandidates: SearchResultItem[] = [];
  /** 行按压反馈（@Builder 内读 this 状态，不通过参数传，避免按值传递不刷新） */
  @State pressedId: string = '';
  /** 结果弹窗只弹一次，避免 @Watch 重复触发 */
  private reported: boolean = false;

  aboutToAppear(): void {
    this.reported = this.restoreState.phase === RestorePhase.REPORT;
    // 若上一次扫描还停在预览/报告态，保留清单让用户看；否则重置成 IDLE 等按钮
    if (this.restoreState.phase === RestorePhase.AUTHORIZING
      || this.restoreState.phase === RestorePhase.SCANNING
      || this.restoreState.phase === RestorePhase.MATCHING
      || this.restoreState.phase === RestorePhase.COMMITTING) {
      // 任务仍可能在跑（页面被回收后回来），不做重置
      return;
    }
  }

  private onRestoreStateChanged(): void {
    if (this.restoreState.phase === RestorePhase.REPORT && !this.reported) {
      this.reported = true;
      const s: RestoreState = this.restoreState;
      const msg: string = s.errorMessage.length > 0
        ? s.errorMessage
        : `成功写入 ${s.committed} 条，跳过重复 ${s.skipped} 条。\n\n`
          + '只重建了下载记录，歌单 / 最近播放 / 收藏未改动，音频文件也未被删除或修改。';
      showAppInfoDialog(this.getUIContext(), {
        title: '恢复完成',
        message: msg,
        confirmText: '知道了'
      });
    }
    if (this.restoreState.phase !== RestorePhase.REPORT) {
      this.reported = false;
    }
  }

  /** 按类别取清单（@Builder 内现算，不把状态数组当参数传） */
  private itemsOf(cat: RestoreCategory): RestoreItem[] {
    const out: RestoreItem[] = [];
    for (let i = 0; i < this.restoreState.items.length; i++) {
      if (this.restoreState.items[i].category === cat) {
        out.push(this.restoreState.items[i]);
      }
    }
    return out;
  }

  private isBusy(): boolean {
    const p: RestorePhase = this.restoreState.phase;
    return p === RestorePhase.AUTHORIZING || p === RestorePhase.SCANNING
      || p === RestorePhase.MATCHING || p === RestorePhase.COMMITTING;
  }

  private progressPct(): number {
    if (this.restoreState.total <= 0) {
      return 0;
    }
    return Math.min(100, Math.round(this.restoreState.processed * 100 / this.restoreState.total));
  }

  /** 预览顶部一行：让「本机优先、联网兜底」的命中情况可见 */
  private matchSummary(): string {
    const s: RestoreState = this.restoreState;
    const fromLibrary: number = Math.max(0, s.localMatched - s.localSessionMatched);
    return `本机候选 ${s.localCandidateCount} 条 · 已下载/曲库 ${fromLibrary} 首 · `
      + `拾音 ${s.localSessionMatched} 首 · 联网 ${s.onlineMatched} 首`;
  }

  private startScan(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.reported = false;
    DownloadRestoreManager.getInstance().start(ctx);
  }

  private confirmCommit(): void {
    const n: number = DownloadRestoreManager.getInstance().countChecked();
    if (n <= 0) {
      showAppToast('请先勾选要恢复的歌曲', 1800);
      return;
    }
    showConfirm(this.getUIContext(), {
      title: '确认重建下载记录',
      message: `将向「已下载」写入 ${n} 条记录。\n\n`
        + '只写下载记录，不改动歌单 / 最近播放 / 收藏，也不删除或修改任何音频文件。\n'
        + '会为没有索引的歌曲补写一份索引文件，方便以后再次重装时精确恢复。',
      confirmText: '确认写入',
      onConfirm: (): void => {
        DownloadRestoreManager.getInstance().commit();
      }
    });
  }

  private confirmStop(): void {
    showConfirm(this.getUIContext(), {
      title: '中断扫描',
      message: '已完成的识别结果会保留，未写入任何数据。可随时重新扫描。',
      cancelText: '继续扫描',
      confirmText: '中断',
      onConfirm: (): void => {
        DownloadRestoreManager.getInstance().stop();
      }
    });
  }

  private openManual(item: RestoreItem): void {
    this.manualItemId = item.id;
    this.manualBvid = '';
    this.manualCandidates = item.candidates.slice();
  }

  private chooseCandidate(c: SearchResultItem): void {
    DownloadRestoreManager.getInstance().setChosen(this.manualItemId, c);
    this.manualItemId = '';
    showAppToast('已指定曲目', 1400);
  }

  private applyManualBvid(): void {
    const id: string = this.manualItemId;
    const bvid: string = this.manualBvid.trim();
    if (bvid.length === 0) {
      showAppToast('请输入 BV 号', 1600);
      return;
    }
    let title: string = '';
    let artist: string = '';
    for (let i = 0; i < this.restoreState.items.length; i++) {
      if (this.restoreState.items[i].id === id) {
        title = this.restoreState.items[i].title;
        artist = this.restoreState.items[i].artist;
      }
    }
    const c: SearchResultItem = {
      bvid: bvid, aid: 0, title: title, author: artist,
      play: 0, videoReview: 0, duration: '', pubdate: 0, pic: '', description: ''
    };
    DownloadRestoreManager.getInstance().setChosen(id, c);
    this.manualItemId = '';
    showAppToast('已指定曲目', 1400);
  }

  @Builder
  restoreBar() {
    NavTitleRow({ title: '扫描并恢复下载' })
  }

  @Builder
  restoreBarNarrow() {
    BarNarrowShell({ bar: (): void => {
      this.restoreBar()
    } })
  }

  /** 一个分类段：标题 + 文件行（key 带 checked，避免复用旧节点不刷新） */
  @Builder
  sectionBlock(title: string, cat: RestoreCategory) {
    if (this.itemsOf(cat).length > 0) {
      Column() {
        Text(`${title} · ${this.itemsOf(cat).length}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 14, bottom: 6 })
        ForEach(this.itemsOf(cat), (item: RestoreItem): void => {
          Row({ space: 8 }) {
            // 44vp 命中区：点左侧切换勾选，不与「指定」按钮抢点击
            Row() {
              Text(item.checked ? '✓' : '○')
                .fontSize(18)
                .fontColor(item.checked ? $r('app.color.state_success') : $r('app.color.text_tertiary'))
            }
            .width(44)
            .height(44)
            .justifyContent(FlexAlign.Center)
            .onClick((): void => {
              DownloadRestoreManager.getInstance().setChecked(item.id, !item.checked);
            })

            Column({ space: 3 }) {
              Text(item.fileName)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${item.title}${item.artist.length > 0 ? ' · ' + item.artist : ''}  ${sizeText(item.sizeBytes)}`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (item.reason.length > 0) {
                Text(item.reason)
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            if (cat === RestoreCategory.UNRECOGNIZED || item.weakMatch) {
              Button('指定')
                .fontSize(12)
                .height(32)
                .backgroundColor($r('app.color.bg_card'))
                .fontColor($r('app.color.text_primary'))
                .onClick((): void => {
                  this.openManual(item);
                })
            }
          }
          .width('100%')
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .opacity(this.pressedId === item.id ? 0.6 : 1)
          .onTouch((e: TouchEvent): void => {
            this.pressedId = e.type === TouchType.Down ? item.id : '';
          })
        }, (item: RestoreItem): string => `${item.id}_${item.checked}_${item.category}_${item.title}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 手动指定覆盖层：输入 BV 号 / 从搜索候选里选 */
  @Builder
  manualOverlay() {
    Column() {
      Column({ space: 10 }) {
        Text('手动指定曲目')
          .fontSize(17)
          .fontColor($r('app.color.text_primary'))
        Text('输入 B 站 BV 号，或从搜索候选中选一个。指定后该首会按你的选择写入下载记录。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        TextInput({ placeholder: 'BV1xx411c7mD' })
          .height(44)
          .onChange((v: string): void => {
            this.manualBvid = v;
          })
        Button('用这个 BV 号')
          .width('100%')
          .height(44)
          .backgroundColor(this.themePrimary)
          .fontColor($r('app.color.brand_on'))
          .onClick((): void => {
            this.applyManualBvid();
          })
        if (this.manualCandidates.length > 0) {
          Text(`搜索候选 · ${this.manualCandidates.length}`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          List() {
            ForEach(this.manualCandidates, (c: SearchResultItem): void => {
              ListItem() {
                Column({ space: 2 }) {
                  Text(c.title).fontSize(13).fontColor($r('app.color.text_primary')).maxLines(1)
                  Text(`${c.author}  ${c.bvid}`).fontSize(11).fontColor($r('app.color.text_tertiary'))
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding({ top: 8, bottom: 8 })
                .onClick((): void => {
                  this.chooseCandidate(c);
                })
              }
            }, (c: SearchResultItem): string => c.bvid)
          }
          .height(200)
          .width('100%')
        }
        Button('关闭')
          .width('100%')
          .height(44)
          .backgroundColor($r('app.color.bg_card'))
          .fontColor($r('app.color.text_primary'))
          .onClick((): void => {
            this.manualItemId = '';
          })
      }
      .width('92%')
      .padding(16)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#66000000')
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Column() {
          // 空闲 / 中断 / 限流 / 完成态
          if (!this.isBusy() && this.restoreState.phase !== RestorePhase.PREVIEW) {
            Column({ space: 10 }) {
              Text('从「下载/BiliMusic」重建已下载记录')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('上次开启过「保存到系统下载目录」时，音频会留在系统下载目录里；'
                + '卸载重装只丢了 App 内的记录。扫描后先给你看清单，确认后才写入。')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
              Text('身份还原顺序：随行索引 → 已下载记录 / 曲库 → 拾音数据 → 联网按标题补全。'
                + '本机数据命中时不联网，歌名也不会被换成 B 站视频标题。')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
              if (this.restoreState.errorMessage.length > 0) {
                Text(this.restoreState.errorMessage)
                  .fontSize(13)
                  .fontColor($r('app.color.state_error'))
              }
              if (this.restoreState.phase === RestorePhase.REPORT) {
                Text(`成功 ${this.restoreState.committed} 条 · 跳过 ${this.restoreState.skipped} 条 · 失败 ${this.restoreState.failed} 条`)
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
              }
              Button(this.restoreState.phase === RestorePhase.REPORT
                || this.restoreState.phase === RestorePhase.RISK
                || this.restoreState.phase === RestorePhase.CANCELLED ? '重新扫描' : '扫描下载目录')
                .width('100%')
                .height(44)
                .backgroundColor(this.themePrimary)
                .fontColor($r('app.color.brand_on'))
                .onClick((): void => {
                  this.startScan();
                })
              if (this.restoreState.phase === RestorePhase.REPORT) {
                Button('完成')
                  .width('100%')
                  .height(44)
                  .backgroundColor($r('app.color.bg_card'))
                  .fontColor($r('app.color.text_primary'))
                  .onClick((): void => {
                    NavStackHolder.pop();
                  })
              }
            }
            .width('100%')
            .padding(16)
            .alignItems(HorizontalAlign.Start)
          }

          // 进度态
          if (this.isBusy()) {
            Column({ space: 10 }) {
              Text(this.restoreState.phase === RestorePhase.COMMITTING ? '正在写入下载记录…' : '正在扫描…')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Progress({ value: this.progressPct(), total: 100, type: ProgressType.Linear })
                .width('100%')
                .color(this.themePrimary)
              Text(`${this.restoreState.processed} / ${this.restoreState.total}`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
              if (this.restoreState.hint.length > 0) {
                Text(this.restoreState.hint)
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
                  .maxLines(2)
              }
              if (this.restoreState.phase !== RestorePhase.COMMITTING) {
                Button('中断')
                  .width('100%')
                  .height(44)
                  .backgroundColor($r('app.color.bg_card'))
                  .fontColor($r('app.color.text_primary'))
                  .onClick((): void => {
                    this.confirmStop();
                  })
              }
            }
            .width('100%')
            .padding(16)
            .alignItems(HorizontalAlign.Start)
          }

          // 预览清单
          if (this.restoreState.phase === RestorePhase.PREVIEW) {
            Text(this.matchSummary())
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 16, right: 16, top: 10 })
            List() {
              ListItem() {
                this.sectionBlock('可精确恢复（随行索引）', RestoreCategory.EXACT)
              }
              ListItem() {
                this.sectionBlock('本机记录 / 拾音补全', RestoreCategory.LOCAL_MATCH)
              }
              ListItem() {
                this.sectionBlock('联网补全', RestoreCategory.SEARCHED)
              }
              ListItem() {
                this.sectionBlock('待确认 / 身份未知', RestoreCategory.UNRECOGNIZED)
              }
              ListItem() {
                this.sectionBlock('与现有记录重复', RestoreCategory.DUPLICATE)
              }
              ListItem() {
                this.sectionBlock('文件异常', RestoreCategory.CORRUPT)
              }
            }
            .layoutWeight(1)
            .width('100%')
            .padding({ left: 16, right: 16 })

            Row({ space: 12 }) {
              Button('全选')
                .height(44)
                .layoutWeight(1)
                .backgroundColor($r('app.color.bg_card'))
                .fontColor($r('app.color.text_primary'))
                .onClick((): void => {
                  DownloadRestoreManager.getInstance().setAllChecked(true);
                })
              Button('全不选')
                .height(44)
                .layoutWeight(1)
                .backgroundColor($r('app.color.bg_card'))
                .fontColor($r('app.color.text_primary'))
                .onClick((): void => {
                  DownloadRestoreManager.getInstance().setAllChecked(false);
                })
              Button(`确认写入 ${DownloadRestoreManager.getInstance().countChecked()} 首`)
                .height(44)
                .layoutWeight(2)
                .backgroundColor(this.themePrimary)
                .fontColor($r('app.color.brand_on'))
                .onClick((): void => {
                  this.confirmCommit();
                })
            }
            .width('100%')
            .padding(16)
          }
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.safeTop + NAV_TITLE_BAR_HEIGHT, bottom: this.safeBottom })

        if (this.manualItemId.length > 0) {
          this.manualOverlay()
        }
      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        stackBuilder: (): void => {
          this.restoreBarNarrow();
        }
      }
    })
    .onBackPressed((): boolean => handleSubPageBackPress())
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/** 懒加载注册表入口（见 service/LazyPageRegistry.ets） */
@Builder
export function DownloadRestorePageBuilder(): void {
  DownloadRestorePage()
}

export const DownloadRestorePageWrapped: WrappedBuilder<[]> = wrapBuilder(DownloadRestorePageBuilder);
