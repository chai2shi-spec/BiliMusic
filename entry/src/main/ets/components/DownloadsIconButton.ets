/**
 * 标题行下载入口图标按钮（歌单一级页方案A：下载入口从「列表第一行」移上标题行）。
 *
 * 视觉对齐 HeaderIconButton 规格：36×36 / 圆角 10 / themeSurface 浅底 +
 * themePrimary 18 号 `circle_and_arrow_down` 图标 / 沉浸光感材质 +
 * 按压缩放 0.9。点击进下载管理二级页（'Downloads'）。
 *
 * 角标（右上角外溢 3vp）：
 *  · 有失败任务 → 8×8 红点（app.color.state_error）—— 失败比进行中更需要被看见，
 *    优先级最高；
 *  · 否则有进行中 + 待开始任务 → themePrimary 实底计数角标（themeOn 10fp 数字，
 *    最小 16×16，随位数自适应加宽）；
 *  · 两者皆无 → 不渲染。
 *
 * ⚠️ 快照隔离铁律（原列表 DownloadsEntryRow 同款）：组件自持
 * `@StorageLink(STORE_DOWNLOAD_TASKS)` + @Watch，DownloadManager 的 5Hz
 * 快照只重渲染本组件的角标 —— 绝不能让宿主页 build 直读 tasks，
 * 否则下载中整页 5Hz 重排。
 */

import { DownloadTask, DownloadStatus } from '../model/MusicModels';
import { NavStackHolder } from '../service/NavStackHolder';
import {
  STORE_DOWNLOAD_TASKS,
  STORE_THEME_ON,
  STORE_THEME_PRIMARY,
  STORE_THEME_SURFACE
} from '../common/Constants';
import {
  PRESS_SCALE,
  PRESS_ANIM_MS
} from '../common/constants/InteractionConstants';
import { ButtonMaterialModifier, makeButtonMaterialModifier } from '../utils/HeaderBarMaterial';

@Component
export struct DownloadsIconButton {
  /** 下载任务快照（DownloadManager 内存态推送，下载中约 5Hz；只驱动角标重算） */
  @StorageLink(STORE_DOWNLOAD_TASKS) @Watch('onTasks') tasks: DownloadTask[] = [];
  /** 进行中 + 待开始任务数（计数角标） */
  @State activeCount: number = 0;
  /** 是否存在失败任务（红点角标，优先于计数） */
  @State failed: boolean = false;
  /** 主题色运行时值：底色 / 图标色 / 角标随切色刷新 */
  @StorageProp(STORE_THEME_SURFACE) themeSurface: string = '#FFF1F5';
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  @StorageProp(STORE_THEME_ON) themeOn: string = '#3D0018';
  /** 沉浸光感材质修饰器 */
  private buttonMaterial: ButtonMaterialModifier = makeButtonMaterialModifier();
  /** 按压缩放（与全局按压参数同档：0.9 / 150ms EaseOut） */
  @State pressScale: number = 1;

  /** 快照落地：一次遍历重算角标两态（失败红点 > 进行中计数） */
  private onTasks(): void {
    let active: number = 0;
    let failed: boolean = false;
    for (let i = 0; i < this.tasks.length; i++) {
      const s: DownloadStatus = this.tasks[i].status;
      if (s === DownloadStatus.ERROR) {
        failed = true;
      } else if (s === DownloadStatus.PENDING || s === DownloadStatus.DOWNLOADING) {
        active++;
      }
    }
    this.failed = failed;
    this.activeCount = active;
  }

  aboutToAppear(): void {
    // @StorageLink 初值同步不触发 @Watch（ArkUI 规则），挂载时补算一次
    this.onTasks();
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Button() {
        SymbolGlyph($r('sys.symbol.circle_and_arrow_down'))
          .fontSize(18)
          // SymbolGlyph.fontColor 按图层接收颜色数组，单色也传单元素数组
          .fontColor([this.themePrimary])
      }
      .type(ButtonType.Normal)
      .width(36)
      .height(36)
      .borderRadius(10)
      .backgroundColor(this.themeSurface)
      .attributeModifier(this.buttonMaterial)
      .scale({ x: this.pressScale, y: this.pressScale })
      .animation({ duration: PRESS_ANIM_MS, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) {
          this.pressScale = PRESS_SCALE;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressScale = 1;
        }
      })
      .onClick((): void => {
        NavStackHolder.push('Downloads', undefined);
      })
      .accessibilityText('下载管理')

      // 角标层：失败红点优先，其次进行中计数；负 margin 让角标外溢右上角 3vp
      if (this.failed) {
        Column()
          .width(8)
          .height(8)
          .borderRadius(4)
          .backgroundColor($r('app.color.state_error'))
          .margin({ top: -3, right: -3 })
      } else if (this.activeCount > 0) {
        Row() {
          Text(`${this.activeCount}`)
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.themeOn)
            .maxLines(1)
        }
        .height(16)
        .constraintSize({ minWidth: 16 })
        .borderRadius(8)
        .padding({ left: 4, right: 4 })
        .backgroundColor(this.themePrimary)
        .justifyContent(FlexAlign.Center)
        .margin({ top: -3, right: -3 })
      }
    }
    .width(36)
    .height(36)
  }
}
