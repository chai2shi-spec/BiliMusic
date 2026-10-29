/**
 * 版本更新内容弹窗（What's New）：新版本安装后首次启动展示本次
 * 「新增 / 优化 / 修复」；设置页的「查看更新日志」入口展示全量历史。
 *
 * 架构与 components/AppAlertDialog.ets 同款（细节坑见该文件头注释）：
 *   · 弹窗框架交给官方 `CustomContentDialog` + `CustomDialogController`
 *     （promptAction.openCustomDialog 会闪退，禁用）；
 *   · controller 必须是 @Component 成员（模块级 controller 编译过但永不显示），
 *     由宿主组件 `WhatsNewDialogHost` 唯一持有，模块级 show* 函数经静态引用驱动；
 *   · controller **每次打开前按当次槽值重建**（CustomDialog 构造参数定格，
 *     faqs-arkui-555）；
 *   · 数据源见 model/ChangelogEntries.ts（发版约定写在那个文件头）。
 *
 * 触发语义（maybeShowWhatsNew，版本号持久化在 PREF_LAST_SEEN_VERSION）：
 *   · 全新安装（无记录）     → 只弹 CHANGELOG[0]（最新一条）；
 *   · 升级（记录 ≠ 当前版本）→ 弹所有 version > 记录 的条目（聚合跨过的版本）；
 *   · 同版本重装 / 降级      → 不弹；
 *   · 当前版本无对应条目     → 静默不弹（忘写 CHANGELOG 的兜底）；
 *   · 「决定即记录」：判定后立即把当前版本写入持久化（弹不弹都写），
 *     杀进程 / 重装同版本不会重复弹。
 *
 * ⚠️ 部署要求：`WhatsNewDialogHost` 必须挂在组件树里（已挂 `Index.ets` 根部，
 * 与 AppDialogHost 同级）。否则宿主引用为 null，弹窗不显示并打一行 error 日志。
 */

import { CustomContentDialog } from '@kit.ArkUI';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { getString, setString } from '../preferences/AppPreferences';
import { PREF_LAST_SEEN_VERSION } from '../common/Constants';
import { CHANGELOG, ChangelogEntry, compareVersion } from '../model/ChangelogEntries';

/** 正文可滚动区域的最大高度（vp）：条目多时滚动、少时自适应收缩 */
const WHATS_NEW_MAX_BODY_HEIGHT: number = 420;

/** 分段渲染规格：@Builder SectionBlock 的单对象参数（@Builder 单参数传对象字面量） */
interface WhatsNewSectionSpec {
  /** 分段标题（「新增」/「优化」/「修复」），兼作 ForEach key 前缀 */
  title: string;
  /** 分段条目（空数组整段跳过） */
  items: string[];
  /** 分段强调色（标题文字 + 条目前圆点），hex 字符串 */
  dotColor: string;
}

/**
 * 弹窗数据槽：模块级单槽，showWhatsNewDialog 写入后由宿主按当次值重建
 * controller 再 open。模态单弹窗，同一时刻只有一个，不会串内容。
 */
let whatsNewEntries: ChangelogEntry[] = [];

/** 弹窗标题（默认「更新内容」；全量历史入口传「更新日志」） */
let whatsNewTitle: string = '更新内容';

/** 「是否已打开」标记：重入前先关旧弹窗用 */
let whatsNewOpened: boolean = false;

/** 弹窗宿主静态引用：宿主 aboutToAppear 写入、aboutToDisappear 置空 */
let whatsNewHost: WhatsNewDialogHost | null = null;

/**
 * 弹窗宿主组件：**唯一持有 CustomDialogController 的地方**（模块级 controller
 * 静默失效，见文件头注释）。宿主不渲染任何东西，挂在 `Index.ets` 根部。
 */
@Component
export struct WhatsNewDialogHost {
  /** controller：每次 openWhatsNew 按当次槽值重建（faqs-arkui-555），未弹过窗时不占资源 */
  private whatsNewController: CustomDialogController | null = null;

  aboutToAppear(): void {
    whatsNewHost = this;
  }

  aboutToDisappear(): void {
    whatsNewHost = null;
  }

  /** 单个分段（标题 + 圆点条目列表）：空数组整段跳过 */
  @Builder
  SectionBlock(spec: WhatsNewSectionSpec) {
    if (spec.items.length > 0) {
      Text(spec.title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(spec.dotColor)
        .alignSelf(ItemAlign.Start)
        .margin({ top: 10 })
      ForEach(spec.items, (t: string) => {
        Row() {
          Circle({ width: 5, height: 5 })
            .fill(spec.dotColor)
            .margin({ top: 7 })
          Text(t)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(18)
            .layoutWeight(1)
        }
        .alignItems(VerticalAlign.Top)
        .margin({ top: 4 })
      }, (t: string, idx: number) => `${spec.title}:${idx}:${t}`)
    }
  }

  /** 单个版本条目：版本头（v1.3.4 · 日期）+ 新增 / 优化 / 修复三段 */
  @Builder
  EntryBlock(e: ChangelogEntry) {
    Column() {
      Text(`v${e.version} · ${e.date}`)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .alignSelf(ItemAlign.Start)
      this.SectionBlock({ title: '新增', items: e.added, dotColor: '#34C759' })
      this.SectionBlock({ title: '优化', items: e.improved, dotColor: '#007DFF' })
      this.SectionBlock({ title: '修复', items: e.fixed, dotColor: '#FF9500' })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 10 })
  }

  /** 弹窗正文（CustomContentDialog 的 contentBuilder 槽）：多版本条目纵向滚动 */
  @Builder
  WhatsNewBody() {
    Scroll() {
      Column() {
        ForEach(whatsNewEntries, (e: ChangelogEntry) => {
          this.EntryBlock(e)
        }, (e: ChangelogEntry) => e.version)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .constraintSize({ maxHeight: WHATS_NEW_MAX_BODY_HEIGHT })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  /** 供模块级 showWhatsNewDialog 调用（成员方法，才能碰组件内的 controller） */
  openWhatsNew(): void {
    // faqs-arkui-555：构造参数定格 → 每次按当次槽值重建
    this.whatsNewController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: whatsNewTitle,
        contentBuilder: (): void => {
          this.WhatsNewBody();
        },
        buttons: [
          {
            value: '知道了',
            buttonStyle: ButtonStyleMode.EMPHASIZED,
            action: (): void => {
              this.closeWhatsNew();
            }
          }
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      cancel: (): void => {
        whatsNewOpened = false;
      }
    });
    whatsNewOpened = true;
    try {
      this.whatsNewController.open();
    } catch (e) {
      whatsNewOpened = false;
      const err = e as BusinessError;
      console.error(`open whats-new dialog failed: ${err.code} ${err.message}`);
    }
  }

  /** 关闭弹窗（幂等：没开时直接返回） */
  closeWhatsNew(): void {
    if (!whatsNewOpened) {
      return;
    }
    whatsNewOpened = false;
    const controller: CustomDialogController | null = this.whatsNewController;
    if (controller === null) {
      return;
    }
    try {
      controller.close();
    } catch (e) {
      const err = e as BusinessError;
      console.error(`close whats-new dialog failed: ${err.code} ${err.message}`);
    }
  }

  /** 宿主不渲染任何内容，仅承载 controller（见 AppDialogHost 同款注释） */
  build() {
    Column() {
    }
    .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 显示更新内容弹窗（内部入口）。
 *
 * @param entries 要展示的版本条目（新版本在前）
 * @param title   弹窗标题（首启「更新内容」/ 历史入口「更新日志」）
 */
function showWhatsNewDialog(entries: ChangelogEntry[], title: string): void {
  const host: WhatsNewDialogHost | null = whatsNewHost;
  if (host === null) {
    console.error('showWhatsNewDialog: 弹窗宿主未挂载，弹窗未显示');
    return;
  }
  whatsNewEntries = entries;
  whatsNewTitle = title;
  // 重入（上一个还没关就又调一次）：先关旧再开，避免两个弹窗叠在一起
  host.closeWhatsNew();
  host.openWhatsNew();
}

/** 设置页入口：展示全量更新日志（不改 PREF_LAST_SEEN_VERSION，不影响首启判定） */
export function showFullChangelog(): void {
  // slice 复制：弹窗槽位持数组引用，避免任何潜在的原数组变动影响弹窗内容
  showWhatsNewDialog(CHANGELOG.slice(), '更新日志');
}

/**
 * 新版本首启触发入口（Index.ets aboutToAppear 延迟调用）：
 * 比对 PREF_LAST_SEEN_VERSION 与当前 versionName，按文件头注释的语义判定弹不弹。
 * 内部全量 try/catch，任何异常（偏好未初始化 / bundleInfo 拿不到）都静默降级，
 * 绝不阻断启动流程。
 */
export async function maybeShowWhatsNew(): Promise<void> {
  let versionName: string = '';
  try {
    const info: bundleManager.BundleInfo = await bundleManager.getBundleInfoForSelf(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    versionName = info.versionName;
  } catch (e) {
    const err = e as BusinessError;
    console.error(`maybeShowWhatsNew: getBundleInfoForSelf failed: ${err.code} ${err.message}`);
    return;
  }
  if (versionName.length === 0) {
    return;
  }
  let stored: string = '';
  try {
    stored = getString(PREF_LAST_SEEN_VERSION, '');
  } catch (e) {
    console.error(`maybeShowWhatsNew: read prefs failed: ${JSON.stringify(e)}`);
    return;
  }
  if (stored === versionName) {
    return;
  }
  let entries: ChangelogEntry[] = [];
  if (stored.length === 0) {
    // 全新安装（无历史记录）：只看最新一条
    if (CHANGELOG.length > 0) {
      entries = [CHANGELOG[0]];
    }
  } else {
    // 升级：聚合所有比「上次看过」新的条目（跳版本一次性补齐，新在前）
    entries = CHANGELOG.filter((e: ChangelogEntry): boolean => compareVersion(e.version, stored) > 0);
  }
  // 「决定即记录」：判定后立即写入当前版本（弹不弹都写）——
  // 杀进程 / 重装同版本不会重复弹；忘写 CHANGELOG 条目的版本也到此为止。
  try {
    await setString(PREF_LAST_SEEN_VERSION, versionName);
  } catch (e) {
    console.error(`maybeShowWhatsNew: write prefs failed: ${JSON.stringify(e)}`);
    // 写失败仍继续弹窗：宁可下次重弹，不可本次漏弹
  }
  if (entries.length === 0) {
    return;
  }
  showWhatsNewDialog(entries, '更新内容');
}
