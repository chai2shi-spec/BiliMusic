/**
 * 转写模型管理页：内置 4 个开源 ASR 模型的下载 / 校验 / 删除 / 选用。
 *
 * 入口：设置 → 数据工具 → 转写模型。
 * 模型不进安装包：全部下载到 filesDir/asr_models，用户自行选择下载哪几个。
 *
 * UI 约定（UI-LAYOUT.md 五条铁律）：
 *   · 字阶：标题 16fp / 正文 16fp / 副文案 13fp（不用 <13fp）；
 *   · 灰阶：主文字 text_primary / 次文字 text_secondary；
 *   · 粉色只给强调按钮与图标，不给大段正文；
 *   · 命中区 ≥44vp，按压态必备。
 */

import {
  CONTENT_END_OFFSET, STORE_ASR_ENGINE_ID, STORE_ASR_MODEL_PROGRESS,
  STORE_SAFE_BOTTOM, STORE_SAFE_TOP
} from '../common/Constants';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { NavTitleRow } from '../components/NavTitleRow';
import { BarNarrowShell } from '../components/BarNarrowShell';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { InsetCard, CardDivider, SectionHeader, SectionFooter } from '../components/InsetCardGroup';
import { showAppToast } from '../components/AppToast';
import { showConfirm } from '../components/AppAlertDialog';
import {
  ASR_MODEL_CATALOG, AsrModelSpec, AsrModelFile,
  formatModelSize, totalModelBytes
} from '../service/asr/AsrModelCatalog';
import {
  AsrDownloadProgress, AsrModelState, cancelAsrDownload, deleteModel,
  downloadModel, getModelState, installedBytes, isAsrDownloadRunning
} from '../service/asr/AsrModelManager';
import {
  currentEngineId, isThirdPartyAsrEnabled, selectAsrEngine, setThirdPartyAsrEnabled
} from '../service/asr/AsrEngineRegistry';

/** 卡片行左右内边距（与 InsetCardGroup 的 16vp 对齐） */
const ROW_H_PADDING: number = 16;

@Component
export struct AsrModelPage {
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 当前引擎 id（模型行高亮 + 选择入口） */
  @StorageProp(STORE_ASR_ENGINE_ID) @Watch('onEngineChanged') engineId: string = 'system';
  /** 下载进度快照（JSON 字符串，解析到 @State 对象驱动逐行刷新） */
  @StorageProp(STORE_ASR_MODEL_PROGRESS) @Watch('onProgressChanged') progressText: string = '';
  /** 第三方总开关（内存镜像，切换时同步持久化） */
  @State thirdPartyOn: boolean = true;
  /** 每个模型的安装状态（版本号式刷新：数组元素变更触发 ForEach 重建） */
  @State modelStates: AsrModelState[] = [];
  /** 下载中模型 id */
  @State downloadingId: string = '';
  /** 下载进度百分比 */
  @State downloadPercent: number = 0;
  /** 累计占用（字节） */
  @State usedBytes: number = 0;

  /** 滚动控制器：bindToScrollable 绑给 HDS 标题栏，滚动模糊效果依赖此绑定 */
  private pageScroller: Scroller = new Scroller();
  /** 自绘顶栏渐变模糊层进度更新器（命令式驱动，高频回调零重建） */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();
  /** 子页转场的横移量（相对页面自身宽度）：转场代理里按 push/pop 方向临时改写 */
  @State navTransX: string = '0%';

  /** 滚动进度喂给顶栏渐变模糊层（内容不足一屏时恒 0，透明无副作用） */
  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.pageScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  /**
   * 子页转场（customTransition 代理）：从右滑入 slow(400ms) EaseOut，
   * pop 反向滑出；其余场景（被上层覆盖 / 重新露出）返回 undefined 走系统默认。
   */
  private navTransitionDelegate(op: NavigationOperation,
    isEnter: boolean): Array<NavDestinationTransition> | undefined {
    if (op === NavigationOperation.PUSH && isEnter) {
      this.navTransX = '100%';
      const enter: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '0%';
        }
      };
      const transitions: Array<NavDestinationTransition> = [enter];
      return transitions;
    }
    if (op === NavigationOperation.POP && !isEnter) {
      const exit: NavDestinationTransition = {
        duration: NAV_TRANSITION_MS,
        curve: Curve.EaseOut,
        event: (): void => {
          this.navTransX = '100%';
        }
      };
      const transitions: Array<NavDestinationTransition> = [exit];
      return transitions;
    }
    return undefined;
  }

  aboutToAppear(): void {
    this.syncTopBlurProgress();
    this.thirdPartyOn = isThirdPartyAsrEnabled();
    this.refreshStates();
    this.onProgressChanged();
  }

  /** 引擎 id 被外部改动（如歌词面板 chooser）时同步开关状态 */
  onEngineChanged(): void {
    // 只刷新列表高亮（@StorageProp 已驱动 rebuild），无额外副作用
  }

  onProgressChanged(): void {
    if (this.progressText.length === 0) {
      return;
    }
    try {
      const p: AsrDownloadProgress = JSON.parse(this.progressText) as AsrDownloadProgress;
      this.downloadingId = p.running ? p.modelId : '';
      this.downloadPercent = p.percent;
      if (p.error.length > 0 && p.error !== '已取消') {
        showAppToast(p.error, 2600);
      }
      // 一轮结束（成功 / 失败 / 取消）都要重读状态：校验失败时坏 .part 已被清理，
      // 不刷新的话行上还停在「续传」，用户点下去立刻又失败
      if (!p.running) {
        this.refreshStates();
      }
    } catch (e) {
      // JSON 坏快照忽略（不会来自本模块）
    }
  }

  /** 重新读取每个模型状态（纯 stat，无 IO 阻塞） */
  private refreshStates(): void {
    const next: AsrModelState[] = [];
    for (let i = 0; i < ASR_MODEL_CATALOG.length; i++) {
      next.push(getModelState(ASR_MODEL_CATALOG[i].id));
    }
    this.modelStates = next;
    this.usedBytes = installedBytes();
  }

  /** 模型卡片按钮点击（由 Builder onClick 现查状态后调用） */
  private onModelActionWithState(spec: AsrModelSpec, state: AsrModelState): void {
    if (this.downloadingId.length > 0) {
      showAppToast('已有模型正在下载，请稍候', 2000);
      return;
    }
    if (!state.installed) {
      this.confirmDownload(spec);
      return;
    }
    if (this.engineId === spec.id) {
      // 当前使用的模型 → 只提供删除（先回落到系统引擎）
      this.confirmDelete(spec);
    } else {
      this.selectEngine(spec.id, spec.displayName);
    }
  }

  private confirmDownload(spec: AsrModelSpec): void {
    showConfirm(this.getUIContext(), {
      title: `下载 ${spec.displayName}？`,
      message: `约 ${formatModelSize(totalModelBytes(spec))}，下载到本机后可离线转写歌词。\n\n`
        + `许可证：${spec.license}\n`
        + '演唱含伴奏时识别准确率有限，结果需手动校对。',
      cancelText: '取消',
      confirmText: '开始下载',
      onConfirm: (): void => {
        void downloadModel(spec.id).then((ok: boolean): void => {
          this.refreshStates();
          if (ok) {
            showAppToast('模型已就绪', 2000);
          }
        });
      }
    });
  }

  private async selectEngine(id: string, name: string): Promise<void> {
    const ok: boolean = await selectAsrEngine(id);
    if (!ok) {
      showAppToast('模型尚未下载完成', 2000);
      return;
    }
    AppStorage.setOrCreate(STORE_ASR_ENGINE_ID, id);
    // 选了第三方引擎但总开关关着 → 自动打开
    if (!this.thirdPartyOn) {
      await setThirdPartyAsrEnabled(true);
      this.thirdPartyOn = true;
    }
    showAppToast(`已切换到 ${name}`, 2000);
  }

  private confirmDelete(spec: AsrModelSpec): void {
    showConfirm(this.getUIContext(), {
      title: `删除 ${spec.displayName}？`,
      message: '将删除本机已下载的模型文件，释放存储空间；不影响已生成的歌词。',
      cancelText: '取消',
      confirmText: '删除',
      onConfirm: (): void => {
        // 有下载在跑时 deleteModel 会静默返回 false —— 先拦下，
        // 避免引擎已被切走却没删成文件
        if (isAsrDownloadRunning()) {
          showAppToast('有模型正在下载，稍后再试', 2000);
          return;
        }
        if (!deleteModel(spec.id)) {
          showAppToast('删除失败，请重试', 2000);
          return;
        }
        if (this.engineId === spec.id) {
          void selectAsrEngine('system');
          AppStorage.setOrCreate(STORE_ASR_ENGINE_ID, 'system');
          showAppToast('已回退到系统识别', 2000);
        }
        this.refreshStates();
      }
    });
  }

  private async onToggleThirdParty(enabled: boolean): Promise<void> {
    this.thirdPartyOn = enabled;
    await setThirdPartyAsrEnabled(enabled);
    AppStorage.setOrCreate(STORE_ASR_ENGINE_ID, currentEngineId());
    showAppToast(enabled ? '已启用第三方转写引擎' : '已回退到系统识别', 2000);
  }

  /** 单个模型行 */
  @Builder
  modelRow(spec: AsrModelSpec, index: number) {
    Row() {
      // 图标位：用主题色圆形底 + 首字，统一视觉（与设置页图标风格一致）
      Column() {
        Text(spec.displayName.substring(0, 1))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
      }
      .width(40)
      .height(40)
      .borderRadius(20)
      .backgroundColor($r('app.color.bg_card'))
      .justifyContent(FlexAlign.Center)
      .margin({ right: 12 })

      Column() {
        Row() {
          Text(spec.displayName)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.engineId === spec.id && this.thirdPartyOn) {
            Text('使用中')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .margin({ left: 8 })
          }
        }
        .width('100%')

        Text(`${formatModelSize(totalModelBytes(spec))} · ${spec.languages}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(spec.summary)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 4 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(`许可证：${spec.license}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 4 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 下载中：进度条 + 百分比；这是唯一会变的动态区，全部在 Builder 内现算
        if (this.downloadingId === spec.id) {
          Row() {
            Progress({ value: this.downloadPercent, total: 100, type: ProgressType.Linear })
              .layoutWeight(1)
              .height(6)
            Text(`${this.downloadPercent}%`)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .margin({ left: 10 })
          }
          .width('100%')
          .margin({ top: 8 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 动作标签（纯展示，点击统一由整行分派 —— 避免嵌套 onClick 被 Scroll 手势拒绝）
      Text(this.downloadingId === spec.id ? '取消' : this.stateLabel(index))
        .fontSize(16)
        .fontColor(this.downloadingId === spec.id
          ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
        .padding({ left: 10, right: 2, top: 12, bottom: 12 })

      // 已安装但非「使用中」的模型：补显式删除胶囊（SettingsPage 账号行同款模式，
      // 胶囊 onClick 与整行 onClick 并存）。使用中的模型整行点击即删除，不重复放。
      if (this.showDeletePill(index)) {
        Row() {
          Text('删除')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(14)
            .backgroundColor($r('app.color.bg_page'))
            .stateStyles({
              pressed: { .opacity(0.5) },
              normal: { .opacity(1) }
            })
            .accessibilityText(`删除${spec.displayName}`)
            .accessibilityLevel('yes')
        }
        .height(44)
        .justifyContent(FlexAlign.Center)
        .margin({ left: 4 })
        .onClick((): void => {
          this.confirmDelete(spec);
        })
      }
    }
    .width('100%')
    .padding({ left: ROW_H_PADDING, right: ROW_H_PADDING, top: 14, bottom: 14 })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_overlay')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .accessibilityText(`${spec.displayName}，${this.stateLabel(index)}`)
    .accessibilityLevel('yes')
    .onClick((): void => {
      // 按静态 id 现查状态的兜底：index 在 Builder 展开后可能失效
      const st: AsrModelState = getModelState(spec.id);
      if (this.downloadingId === spec.id) {
        cancelAsrDownload();
      } else {
        this.onModelActionWithState(spec, st);
      }
    })
  }

  /** 状态文案：状态数组是 @State，在 Builder 调用处现取，不用 Builder 参数传动态值 */
  private stateLabel(index: number): string {
    const st: AsrModelState | undefined = this.modelStates[index];
    if (st === undefined) {
      return '未知';
    }
    if (!st.installed) {
      return st.bytes > 0 ? '续传' : '下载';
    }
    if (this.engineId === ASR_MODEL_CATALOG[index].id && this.thirdPartyOn) {
      return '删除';
    }
    return '使用';
  }

  /** 删除胶囊显示条件：已安装且非「使用中」（使用中模型整行点击就是删除） */
  private showDeletePill(index: number): boolean {
    const st: AsrModelState | undefined = this.modelStates[index];
    if (st === undefined || !st.installed) {
      return false;
    }
    return !(this.engineId === ASR_MODEL_CATALOG[index].id && this.thirdPartyOn);
  }

  @Builder
  pageBar() {
    NavTitleRow({ title: '转写模型' })
  }

  @Builder
  barNarrow() {
    BarNarrowShell({ bar: (): void => {
      this.pageBar()
    } })
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Scroll(this.pageScroller) {
          Column() {
            Blank().height(this.safeTop + NAV_TITLE_BAR_HEIGHT).width('100%')

            SectionHeader({ headerText: '引擎' })
            InsetCard() {
              Row() {
                Column() {
                  Text('第三方转写引擎')
                    .fontSize(16)
                    .fontColor($r('app.color.text_primary'))
                  Text('关闭时一律使用系统内置识别，行为与旧版一致')
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                    .margin({ top: 4 })
                    .maxLines(2)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Toggle({ type: ToggleType.Switch, isOn: this.thirdPartyOn })
                  .onChange((v: boolean): void => {
                    void this.onToggleThirdParty(v);
                  })
              }
              .width('100%')
              .padding({ left: ROW_H_PADDING, right: ROW_H_PADDING, top: 14, bottom: 14 })
            }

            SectionHeader({ headerText: '内置模型' })
            InsetCard() {
              ForEach(ASR_MODEL_CATALOG, (spec: AsrModelSpec, index: number): void => {
                if (index > 0) {
                  CardDivider()
                }
                this.modelRow(spec, index)
              }, (spec: AsrModelSpec): string => spec.id)
            }
            SectionFooter({
              noteText: `已占用 ${formatModelSize(this.usedBytes)} · 模型保存在本机，卸载应用后需重新下载。`
            })

            SectionHeader({ headerText: '说明' })
            InsetCard() {
              Column() {
                Text('这些开源模型主要用朗读语音训练，对带伴奏的歌曲演唱识别准确率有限。转写结果作为歌词草稿写入本机，可用播放页「编辑歌词」逐行修正。')
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .lineHeight(20)
                  .width('100%')
                Text('模型文件来自开源社区，下载前请阅读模型许可证；SenseVoice 模型权重须保留 FunASR 署名。')
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .lineHeight(20)
                  .width('100%')
                  .margin({ top: 10 })
              }
              .padding({ left: ROW_H_PADDING, right: ROW_H_PADDING, top: 14, bottom: 14 })
              .alignItems(HorizontalAlign.Start)
            }

            // 底部让位：预留悬浮迷你播放条高度 + 手势区（与全站子页同口径）
            Blank().height(CONTENT_END_OFFSET + this.safeBottom)
          }
          .width('100%')
          .constraintSize({ maxWidth: BreakpointConstants.contentMaxWidth(this.currentBreakpoint) })
          .margin({ left: 'auto', right: 'auto' })
        }
        .width('100%')
        .height('100%')
        .align(Alignment.TopStart)
        // 自绘渐变模糊层驱动：逐帧更新 + 停止校准终态
        .onDidScroll((xOffset: number, yOffset: number): void => {
          this.syncTopBlurProgress();
        })
        .onScrollStop((): void => {
          this.syncTopBlurProgress();
        })

        // 顶栏渐变模糊层：盖滚动内容之上（z 序低于 HDS titleBar）
        TopGradientBlurOverlay({
          barHeightVp: this.safeTop + NAV_TITLE_BAR_HEIGHT,
          updater: this.topBlurUpdater
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        stackBuilder: (): void => {
          this.barNarrow()
        }
      }
    })
    // 滚动模糊依赖 scroller 绑定：把本页滚动容器交给 HDS 联动
    .bindToScrollable([this.pageScroller])
    // 子页转场：横移量由转场代理驱动（translate 是视觉变换，不改布局）
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    .onBackPressed((): boolean => handleSubPageBackPress())
    // 内容避让：目的地级声明布局扩展进系统安全区（内容首部占位让位标题栏）
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

@Builder
export function AsrModelPageBuilder(): void {
  AsrModelPage()
}

export const AsrModelPageWrapped: WrappedBuilder<[]> = wrapBuilder(AsrModelPageBuilder);
