/**
 * 首页筛选设置页（'HomeFeedFilter' 路由，见 service/LazyPageRegistry.ets）。
 *
 * 只作用于首页「推荐」tab：排行榜 / 音乐中心不接入过滤。
 * 规则数据走 service/HomeFeedFilterStore（filesDir JSON + rev 广播），
 * 本页每次修改直接 updateFeedFilterConfig 提交 —— 推荐页（常驻 Tab）经
 * STORE_FEED_FILTER_REV 的 @Watch 从 recommendRaw 即时重滤，不发网络请求。
 *
 * 分组结构（iOS 设置风格 InsetCard）：
 *   · 开关 —— 启用首页筛选（开启走确认弹窗：提示推荐数会大幅减少，建议
 *     先多加筛选条件）/ 严格模式 / 恢复默认；
 *   · 质量档位 —— 三档一键设参（全放 / 淘沙 / 只看高质量，SelectDialog）+ 五个数值阈值；
 *   · UP 名单 —— 屏蔽 / 仅看（bindSheet 编辑器，支持 `mid(备注)`、纯 mid、用户名）；
 *   · 标题与分区 —— 屏蔽 / 仅看标题词（支持 /正则/）、屏蔽 / 仅看分区（常用分区快选 chips）；
 *   · 筛选方案 —— 启用方案（SelectDialog）、逐方案编辑器（包含词 any/all、排除词、
 *     排除 UP）、新建 / 删除。
 *
 * 顶栏为 HDS 沉浸光感标题栏（HdsNavDestination.titleBar，PlaybackSettingsPage
 * 同款骨架）：材质由 HDS 统一渲染，滚动渐变模糊由自绘 TopGradientBlurOverlay
 * 承担（AppearanceSettingsPage 同款）；列表编辑器共用一个 bindSheet（editorMode 分流内容）。
 */

import {
  CONTENT_END_OFFSET,
  STORE_SAFE_BOTTOM,
  STORE_SAFE_TOP,
  STORE_THEME_PRIMARY
} from '../common/Constants';
import { SelectDialog, CustomContentDialog } from '@kit.ArkUI';
import { showAppToast } from '../components/AppToast';
import { showConfirm } from '../components/AppAlertDialog';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { TwoColumnLayout } from '../common/utils/TwoColumnList';
import { NAV_TITLE_BAR_HEIGHT } from '../utils/NavTitleStyle';
import { InsetCard, CardDivider, SectionHeader } from '../components/InsetCardGroup';
import { HdsListItemCard, SuffixSwitch, SuffixText, SuffixArrowIconText } from '@kit.UIDesignKit';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { HdsTitleBarStyle } from '../utils/HdsTitleBarStyle';
import { NavTitleRow } from '../components/NavTitleRow';
import { handleSubPageBackPress } from '../utils/SubPageBackPress';
import { BarNarrowShell } from '../components/BarNarrowShell';
import { NAV_TRANSITION_MS } from '../common/constants/InteractionConstants';
import {
  FeedFilterConfig,
  FeedFilterScheme,
  FeedFilterPresetInfo,
  FeedUpEntry,
  FEED_FILTER_PRESETS,
  COMMON_FEED_CATEGORIES,
  defaultFeedFilterConfig,
  copyFeedFilterConfig,
  applyFeedFilterPreset,
  matchFeedFilterPreset,
  createFeedFilterScheme
} from '../model/FeedFilterModels';
import { parseUpInputText } from '../utils/FeedFilterEngine';
import { getFeedFilterConfig, updateFeedFilterConfig } from '../service/HomeFeedFilterStore';
import { TopGradientBlurOverlay, TopBlurProgressUpdater } from '../components/TopGradientBlurOverlay';
import { MaterialTokens } from '../common/style/MaterialTokens';

@Component
export struct HomeFeedFilterPage {
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /** 当前断点（Index 常驻注册写入）：大屏上内容列收窄居中 */
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  /** 当前横竖屏（Index 常驻注册写入）：内容列 840 口径取值用 */
  @StorageProp(BreakpointConstants.IS_LANDSCAPE) isLandscape: boolean = false;
  /** 主题色（开关选中色 / chips 选中底色） */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /**
   * 本页编辑的配置副本：进页时从 store 取深拷贝，每次修改后整体重赋值
   * （接口对象嵌套属性变更不触发 V1 刷新，拷贝重赋值是可靠口径）再提交，
   * store 落盘 + bump rev → 推荐页 @Watch 重滤。
   */
  @State cfg: FeedFilterConfig = getFeedFilterConfig();
  /** 名单 / 关键词 / 分区 / 方案编辑器共用一个半屏面板：editorMode 分流内容 */
  @State showEditorSheet: boolean = false;
  /** '' = 关；blockUps/allowUps/blockTitle/allowTitle/blockCats/allowCats/scheme */
  private editorMode: string = '';
  /** 编辑器输入暂存（UP 名单 / 关键词 / 分区共用一个输入位） */
  @State editorInput: string = '';
  /** 字符串型名单快照（关键词 / 分区） */
  @State editorStrings: string[] = [];
  /** UP 名单快照 */
  @State editorUps: FeedUpEntry[] = [];
  /** 方案编辑器当前方案（副本，每次改动整体重赋值） */
  @State editingScheme: FeedFilterScheme | null = null;
  /** 数值阈值弹窗输入暂存 */
  @State numberInput: string = '';
  /** 数值阈值弹窗目标字段（viewMin/likeRateMin/durationMinSec/durationMaxSec/pubdateWithinDays） */
  private numberField: string = '';
  // 本页所有弹窗 controller 每次打开重建（CustomDialog 参数不支持动态刷新）。
  // ⚠️ CustomContentDialog / SelectDialog 按钮槽的内置自动关闭对方法内局部
  // 创建的 controller 不生效（模拟器/真机实测：action 会执行但弹窗不关），
  // 必须持有成员引用、在每个按钮 action 里显式 close（播放音质弹窗同款模式）。
  private numberDialog: CustomDialogController | null = null;
  private presetDialog: CustomDialogController | null = null;
  private activeSchemeDialog: CustomDialogController | null = null;
  private schemeCreateDialog: CustomDialogController | null = null;
  @State schemeNameInput: string = '';
  /** 滚动控制器：bindToScrollable 绑给 HDS 标题栏，滚动模糊效果依赖此绑定 */
  private pageScroller: Scroller = new Scroller();

  /** 自绘顶栏渐变模糊层进度更新器（AboutPage 同款命令式驱动，高频回调零重建） */
  private topBlurUpdater: TopBlurProgressUpdater = new TopBlurProgressUpdater();

  private syncTopBlurProgress(): void {
    this.topBlurUpdater.setProgress(
      (this.pageScroller.currentOffset()?.yOffset ?? 0) / MaterialTokens.TITLE_BLUR_END_VP);
  }

  /** 子页转场的横移量（相对页面自身宽度）：转场代理里按 push/pop 方向临时改写 */
  @State navTransX: string = '0%';

  aboutToAppear(): void {
    // 挂载前先存当前偏移对应的进度（updater 未挂载只存值，挂载时 initializeModifier 补上）
    this.syncTopBlurProgress();
  }

  /**
   * 提交修改：先整体拷贝重赋值 @State（驱动本页刷新），再交 store
   * （store 再拷贝隔离、防抖落盘、bump rev 驱动推荐页重滤）。
   */
  private commit(): void {
    this.cfg = copyFeedFilterConfig(this.cfg);
    updateFeedFilterConfig(this.cfg);
  }

  private toast(message: string, duration: number): void {
    showAppToast(message, duration);
  }

  /**
   * 开启筛选前的确认弹窗：打开后首页推荐只保留符合条件的条目，推荐数
   * 会大幅减少 —— 提示先补足筛选条件再开，避免推荐被滤得过空。
   * 取消不开启；此时 cfg.enabled 未变，前面的 cfg 拷贝重赋值已触发
   * 重渲染把开关视觉回弹到关。
   */
  private requestEnableFilter(): void {
    showConfirm(this.getUIContext(), {
      title: '启用首页筛选',
      message: '打开筛选后，首页推荐只保留符合条件的条目，推荐数量会大幅减少。建议先多添加筛选条件（质量档位、UP 名单、标题关键词、分区等），再开启筛选。',
      confirmText: '仍要开启',
      onConfirm: (): void => {
        this.cfg.enabled = true;
        this.commit();
        this.toast('已开启：规则将作用于首页推荐', 1500);
      }
    });
  }

  // ── 质量档位 ──

  /** 档位回显文案：阈值与内置档一致才认，否则「自定义」 */
  private presetLabel(): string {
    const name: string = matchFeedFilterPreset(this.cfg);
    if (name.length === 0) {
      return '自定义';
    }
    for (let i = 0; i < FEED_FILTER_PRESETS.length; i++) {
      if (FEED_FILTER_PRESETS[i].name === name) {
        return FEED_FILTER_PRESETS[i].label;
      }
    }
    return '自定义';
  }

  private openPresetDialog(): void {
    const current: string = matchFeedFilterPreset(this.cfg);
    const items: SheetInfo[] = [];
    let selectedIndex: number = -1;
    for (let i = 0; i < FEED_FILTER_PRESETS.length; i++) {
      const preset: FeedFilterPresetInfo = FEED_FILTER_PRESETS[i];
      if (preset.name === current) {
        selectedIndex = i;
      }
      items.push({
        title: preset.label,
        action: (): void => {
          this.pickPreset(preset.name, preset.label);
          this.presetDialog?.close();
        }
      });
    }
    const dialog: CustomDialogController = new CustomDialogController({
      builder: SelectDialog({
        title: '质量档位',
        // 档位差异只在阈值：并入一行说明，单选项只留档位名（长句塞进
        // radioContent 会把单选行撑成参差多行，弹窗整体显得空而乱）
        content: '淘沙：播放 ≥1000 且赞率 ≥2%；只看高质量：≥1000 且 ≥6%；缺点赞数据的条目自动跳过，选中后仍可微调',
        selectedIndex: selectedIndex,
        confirm: {
          value: '取消',
          action: (): void => {
            this.presetDialog?.close();
          }
        },
        radioContent: items
      }),
      autoCancel: true
    });
    this.presetDialog = dialog;
    dialog.open();
  }

  private pickPreset(name: string, label: string): void {
    this.cfg = applyFeedFilterPreset(this.cfg, name);
    updateFeedFilterConfig(this.cfg);
    this.toast(`已切换到「${label}」`, 1500);
  }

  // ── 数值阈值 ──

  private numberEcho(field: string): string {
    if (field === 'viewMin') {
      return this.cfg.viewMin > 0 ? `≥ ${this.cfg.viewMin}` : '不限';
    }
    if (field === 'likeRateMin') {
      return this.cfg.likeRateMin > 0 ? `≥ ${Math.round(this.cfg.likeRateMin * 100)}%` : '不限';
    }
    if (field === 'durationMinSec') {
      return this.cfg.durationMinSec > 0 ? `${this.cfg.durationMinSec} 秒起` : '不限';
    }
    if (field === 'durationMaxSec') {
      return this.cfg.durationMaxSec > 0 ? `${this.cfg.durationMaxSec} 秒内` : '不限';
    }
    if (field === 'pubdateWithinDays') {
      return this.cfg.pubdateWithinDays > 0 ? `${this.cfg.pubdateWithinDays} 天内` : '不限';
    }
    return '不限';
  }

  private openNumberDialog(field: string): void {
    this.numberField = field;
    if (field === 'viewMin') {
      this.numberInput = this.cfg.viewMin > 0 ? String(this.cfg.viewMin) : '';
    } else if (field === 'likeRateMin') {
      this.numberInput = this.cfg.likeRateMin > 0 ? String(Math.round(this.cfg.likeRateMin * 100)) : '';
    } else if (field === 'durationMinSec') {
      this.numberInput = this.cfg.durationMinSec > 0 ? String(this.cfg.durationMinSec) : '';
    } else if (field === 'durationMaxSec') {
      this.numberInput = this.cfg.durationMaxSec > 0 ? String(this.cfg.durationMaxSec) : '';
    } else {
      this.numberInput = this.cfg.pubdateWithinDays > 0 ? String(this.cfg.pubdateWithinDays) : '';
    }
    const dialog: CustomDialogController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: this.numberDialogTitle(field),
        secondaryTitle: '填 0 或留空表示关闭该维度；数据源缺失该字段时自动跳过（严格模式下反转为滤除）',
        contentBuilder: (): void => {
          this.NumberInputBody();
        },
        buttons: [
          {
            value: '取消',
            buttonStyle: ButtonStyleMode.TEXTUAL,
            action: (): void => {
              this.numberDialog?.close();
            }
          },
          {
            value: '确定',
            buttonStyle: ButtonStyleMode.EMPHASIZED,
            action: (): void => {
              this.confirmNumber();
            }
          }
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.numberDialog = dialog;
    dialog.open();
  }

  private numberDialogTitle(field: string): string {
    if (field === 'viewMin') {
      return '最少播放数';
    }
    if (field === 'likeRateMin') {
      return '赞率下限（%）';
    }
    if (field === 'durationMinSec') {
      return '最短时长（秒）';
    }
    if (field === 'durationMaxSec') {
      return '最长时长（秒）';
    }
    return '发布时间窗（天）';
  }

  /** 数值弹窗「确定」：非法 / 空输入一律归 0（= 该维度关闭），负数同样归 0 */
  private confirmNumber(): void {
    const raw: string = this.numberInput.trim();
    let value: number = 0;
    if (raw.length > 0) {
      const parsed: number = this.numberField === 'likeRateMin'
        ? Number.parseFloat(raw) : Number.parseInt(raw, 10);
      if (Number.isFinite(parsed) && parsed > 0) {
        value = parsed;
      }
    }
    if (this.numberField === 'viewMin') {
      this.cfg.viewMin = Math.floor(value);
    } else if (this.numberField === 'likeRateMin') {
      // 输入是百分比整数（2 = 2%），落库为小数比例
      this.cfg.likeRateMin = Math.round(value) / 100;
    } else if (this.numberField === 'durationMinSec') {
      this.cfg.durationMinSec = Math.floor(value);
    } else if (this.numberField === 'durationMaxSec') {
      this.cfg.durationMaxSec = Math.floor(value);
    } else {
      this.cfg.pubdateWithinDays = Math.floor(value);
    }
    this.commit();
    this.numberDialog?.close();
    this.toast(`${this.numberDialogTitle(this.numberField)}：${this.numberEcho(this.numberField)}`, 1500);
  }

  @Builder
  NumberInputBody(): void {
    // 说明文案走 CustomContentDialog 的 secondaryTitle 副标题槽（见 openNumberDialog），
    // 正文只留输入框：正文区默认内边距是给内容块留的，单行文字会让弹窗中间空一大片
    TextInput({ placeholder: '输入数值', text: this.numberInput })
      .width('100%')
      .height(40)
      .fontSize(16)
      .type(InputType.Number)
      .onChange((v: string): void => {
        this.numberInput = v;
      })
  }

  // ── 名单 / 关键词 / 分区编辑器（共用一个 bindSheet）──

  private openListEditor(mode: string): void {
    this.editorMode = mode;
    this.editorInput = '';
    if (mode === 'blockUps') {
      this.editorUps = this.snapshotUps(this.cfg.blockUps);
    } else if (mode === 'allowUps') {
      this.editorUps = this.snapshotUps(this.cfg.allowUps);
    } else if (mode === 'blockTitle') {
      this.editorStrings = this.snapshotStrings(this.cfg.blockTitleKeywords);
    } else if (mode === 'allowTitle') {
      this.editorStrings = this.snapshotStrings(this.cfg.allowTitleKeywords);
    } else if (mode === 'blockCats') {
      this.editorStrings = this.snapshotStrings(this.cfg.blockCategories);
    } else {
      this.editorStrings = this.snapshotStrings(this.cfg.allowCategories);
    }
    this.showEditorSheet = true;
  }

  private snapshotUps(list: FeedUpEntry[]): FeedUpEntry[] {
    const out: FeedUpEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push({ mid: list[i].mid, name: list[i].name });
    }
    return out;
  }

  private snapshotStrings(list: string[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push(list[i]);
    }
    return out;
  }

  private editorTitle(): string {
    if (this.editorMode === 'blockUps') {
      return '屏蔽 UP';
    }
    if (this.editorMode === 'allowUps') {
      return '仅看 UP';
    }
    if (this.editorMode === 'blockTitle') {
      return '屏蔽标题关键词';
    }
    if (this.editorMode === 'allowTitle') {
      return '仅看标题关键词';
    }
    if (this.editorMode === 'blockCats') {
      return '屏蔽分区';
    }
    if (this.editorMode === 'allowCats') {
      return '仅看分区';
    }
    return this.editingScheme !== null && this.editingScheme.name.length > 0
      ? this.editingScheme.name : '编辑方案';
  }

  private editorHint(): string {
    if (this.editorMode === 'blockUps') {
      return '命中即滤除。支持 mid(备注)、纯 mid 或用户名';
    }
    if (this.editorMode === 'allowUps') {
      return '名单非空时只放行名单内的 UP';
    }
    if (this.editorMode === 'blockTitle') {
      return '标题含关键词即滤除；支持 /正则/ 形式';
    }
    if (this.editorMode === 'allowTitle') {
      return '名单非空时只放行命中关键词的标题；支持 /正则/ 形式';
    }
    if (this.editorMode === 'blockCats') {
      return '分区命中即滤除（分区名归一化比较，如「音乐」）';
    }
    if (this.editorMode === 'allowCats') {
      return '名单非空时只放行名单内分区';
    }
    return '包含词圈定想看的内容（对标题+歌手+分区+推荐理由匹配），排除规则任一命中即滤';
  }

  private entryText(e: FeedUpEntry): string {
    if (e.mid.length > 0 && e.name.length > 0) {
      return `${e.mid}(${e.name})`;
    }
    return e.mid.length > 0 ? e.mid : e.name;
  }

  /** 编辑器「添加」：按模式分流解析输入，去重后写回 cfg 并提交 */
  private addEditorEntry(): void {
    const mode: string = this.editorMode;
    if (mode === 'blockUps' || mode === 'allowUps') {
      const parsed: FeedUpEntry | null = parseUpInputText(this.editorInput);
      if (parsed === null) {
        this.toast('输入为空', 1200);
        return;
      }
      for (let i = 0; i < this.editorUps.length; i++) {
        const e: FeedUpEntry = this.editorUps[i];
        if ((parsed.mid.length > 0 && e.mid === parsed.mid)
          || (parsed.name.length > 0 && e.name === parsed.name)) {
          this.toast('该条目已在名单中', 1200);
          return;
        }
      }
      this.editorUps.push({ mid: parsed.mid, name: parsed.name });
      this.writeBackEditorUps();
      this.editorInput = '';
      return;
    }
    const kw: string = this.editorInput.trim();
    if (kw.length === 0) {
      this.toast('输入为空', 1200);
      return;
    }
    if (this.editorStrings.indexOf(kw) >= 0) {
      this.toast('该条目已在名单中', 1200);
      return;
    }
    this.editorStrings.push(kw);
    this.writeBackEditorStrings();
    this.editorInput = '';
  }

  private writeBackEditorUps(): void {
    const back: FeedUpEntry[] = this.snapshotUps(this.editorUps);
    if (this.editorMode === 'blockUps') {
      this.cfg.blockUps = back;
    } else {
      this.cfg.allowUps = back;
    }
    this.commit();
  }

  private writeBackEditorStrings(): void {
    const back: string[] = this.snapshotStrings(this.editorStrings);
    if (this.editorMode === 'blockTitle') {
      this.cfg.blockTitleKeywords = back;
    } else if (this.editorMode === 'allowTitle') {
      this.cfg.allowTitleKeywords = back;
    } else if (this.editorMode === 'blockCats') {
      this.cfg.blockCategories = back;
    } else {
      this.cfg.allowCategories = back;
    }
    this.commit();
  }

  private removeEditorUp(index: number): void {
    this.editorUps.splice(index, 1);
    this.writeBackEditorUps();
  }

  private removeEditorString(index: number): void {
    this.editorStrings.splice(index, 1);
    this.writeBackEditorStrings();
  }

  /** 分区快选 chip 点按：在名单内则移除，否则加入 */
  private toggleCatChip(cat: string): void {
    const idx: number = this.editorStrings.indexOf(cat);
    if (idx >= 0) {
      this.editorStrings.splice(idx, 1);
    } else {
      this.editorStrings.push(cat);
    }
    this.writeBackEditorStrings();
  }

  private listCountOf(mode: string): string {
    if (mode === 'blockUps') {
      return this.cfg.blockUps.length > 0 ? `${this.cfg.blockUps.length} 条` : '';
    }
    if (mode === 'allowUps') {
      return this.cfg.allowUps.length > 0 ? `${this.cfg.allowUps.length} 条` : '';
    }
    if (mode === 'blockTitle') {
      return this.cfg.blockTitleKeywords.length > 0 ? `${this.cfg.blockTitleKeywords.length} 条` : '';
    }
    if (mode === 'allowTitle') {
      return this.cfg.allowTitleKeywords.length > 0 ? `${this.cfg.allowTitleKeywords.length} 条` : '';
    }
    if (mode === 'blockCats') {
      return this.cfg.blockCategories.length > 0 ? `${this.cfg.blockCategories.length} 条` : '';
    }
    return this.cfg.allowCategories.length > 0 ? `${this.cfg.allowCategories.length} 条` : '';
  }

  // ── 方案 ──

  private activeScheme(): FeedFilterScheme | null {
    if (this.cfg.activeSchemeId.length === 0) {
      return null;
    }
    for (let i = 0; i < this.cfg.schemes.length; i++) {
      if (this.cfg.schemes[i].id === this.cfg.activeSchemeId) {
        return this.cfg.schemes[i];
      }
    }
    return null;
  }

  private activeSchemeLabel(): string {
    const s: FeedFilterScheme | null = this.activeScheme();
    if (s === null) {
      return '未启用';
    }
    return s.name.length > 0 ? s.name : '(未命名方案)';
  }

  /** SelectDialog 选择激活方案：含「不启用」项；每次打开重建 controller（选中态新鲜） */
  private openActiveSchemeDialog(): void {
    const items: SheetInfo[] = [];
    let selectedIndex: number = this.cfg.activeSchemeId.length === 0 ? 0 : -1;
    items.push({
      title: '不启用方案',
      action: (): void => {
        this.cfg.activeSchemeId = '';
        this.commit();
        this.activeSchemeDialog?.close();
      }
    });
    for (let i = 0; i < this.cfg.schemes.length; i++) {
      const s: FeedFilterScheme = this.cfg.schemes[i];
      if (s.id === this.cfg.activeSchemeId) {
        selectedIndex = i + 1;
      }
      items.push({
        title: s.name.length > 0 ? s.name : '(未命名方案)',
        action: (): void => {
          this.cfg.activeSchemeId = s.id;
          this.commit();
          this.activeSchemeDialog?.close();
        }
      });
    }
    const dialog: CustomDialogController = new CustomDialogController({
      builder: SelectDialog({
        title: '启用方案',
        content: '排除规则绝对生效；包含词按「任一 / 全部」圈定想看的内容',
        selectedIndex: selectedIndex,
        confirm: {
          value: '取消',
          action: (): void => {
            this.activeSchemeDialog?.close();
          }
        },
        radioContent: items
      }),
      autoCancel: true
    });
    this.activeSchemeDialog = dialog;
    dialog.open();
  }

  private openSchemeEditor(id: string): void {
    for (let i = 0; i < this.cfg.schemes.length; i++) {
      if (this.cfg.schemes[i].id === id) {
        const s: FeedFilterScheme = this.cfg.schemes[i];
        this.editingScheme = {
          id: s.id,
          name: s.name,
          includeMode: s.includeMode,
          includeKeywords: this.snapshotStrings(s.includeKeywords),
          excludeKeywords: this.snapshotStrings(s.excludeKeywords),
          excludeUpMids: this.snapshotStrings(s.excludeUpMids),
          createdAtMs: s.createdAtMs
        };
        this.editorMode = 'scheme';
        this.editorInput = '';
        this.showEditorSheet = true;
        return;
      }
    }
  }

  /** 方案编辑器改动落库：整体重赋值 @State 副本 → 替换 cfg 内同名方案 → 提交 */
  private updateEditingScheme(mut: (s: FeedFilterScheme) => void): void {
    const cur: FeedFilterScheme | null = this.editingScheme;
    if (cur === null) {
      return;
    }
    const next: FeedFilterScheme = {
      id: cur.id,
      name: cur.name,
      includeMode: cur.includeMode,
      includeKeywords: this.snapshotStrings(cur.includeKeywords),
      excludeKeywords: this.snapshotStrings(cur.excludeKeywords),
      excludeUpMids: this.snapshotStrings(cur.excludeUpMids),
      createdAtMs: cur.createdAtMs
    };
    mut(next);
    this.editingScheme = next;
    for (let i = 0; i < this.cfg.schemes.length; i++) {
      if (this.cfg.schemes[i].id === next.id) {
        this.cfg.schemes[i] = next;
        break;
      }
    }
    this.commit();
  }

  /** 方案编辑器「添加」：kind 分流目标列表（include/exclude 关键词 / 排除 UP mid） */
  private addSchemeEntry(kind: string): void {
    const input: string = this.editorInput.trim();
    if (kind === 'upmid') {
      const parsed: FeedUpEntry | null = parseUpInputText(input);
      if (parsed === null || parsed.mid.length === 0) {
        this.toast('排除 UP 需填 mid 或 mid(备注) 格式', 1500);
        return;
      }
      this.updateEditingScheme((s: FeedFilterScheme): void => {
        if (s.excludeUpMids.indexOf(parsed.mid) < 0) {
          s.excludeUpMids.push(parsed.mid);
        }
      });
      this.editorInput = '';
      return;
    }
    if (input.length === 0) {
      this.toast('输入为空', 1200);
      return;
    }
    this.updateEditingScheme((s: FeedFilterScheme): void => {
      const target: string[] = kind === 'include' ? s.includeKeywords : s.excludeKeywords;
      if (target.indexOf(input) < 0) {
        target.push(input);
      }
    });
    this.editorInput = '';
  }

  private removeSchemeEntry(kind: string, index: number): void {
    this.updateEditingScheme((s: FeedFilterScheme): void => {
      if (kind === 'include') {
        s.includeKeywords.splice(index, 1);
      } else if (kind === 'exclude') {
        s.excludeKeywords.splice(index, 1);
      } else {
        s.excludeUpMids.splice(index, 1);
      }
    });
  }

  private confirmDeleteScheme(): void {
    const cur: FeedFilterScheme | null = this.editingScheme;
    if (cur === null) {
      return;
    }
    const id: string = cur.id;
    showConfirm(this.getUIContext(), {
      title: '删除方案',
      message: '将删除该筛选方案，进行中的启用状态一并取消。',
      confirmText: '删除',
      onConfirm: (): void => {
        const rest: FeedFilterScheme[] = [];
        for (let i = 0; i < this.cfg.schemes.length; i++) {
          if (this.cfg.schemes[i].id !== id) {
            rest.push(this.cfg.schemes[i]);
          }
        }
        this.cfg.schemes = rest;
        if (this.cfg.activeSchemeId === id) {
          this.cfg.activeSchemeId = '';
        }
        this.commit();
        this.showEditorSheet = false;
        this.toast('方案已删除', 1500);
      }
    });
  }

  private openSchemeCreateDialog(): void {
    this.schemeNameInput = '';
    const dialog: CustomDialogController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: '新建筛选方案',
        secondaryTitle: '包含词圈定想看，排除规则绝对滤除（对标题 / 歌手 / 分区 / 推荐理由匹配）',
        contentBuilder: (): void => {
          this.SchemeNameBody();
        },
        buttons: [
          {
            value: '取消',
            buttonStyle: ButtonStyleMode.TEXTUAL,
            action: (): void => {
              this.schemeCreateDialog?.close();
            }
          },
          {
            value: '创建',
            buttonStyle: ButtonStyleMode.EMPHASIZED,
            action: (): void => {
              this.confirmCreateScheme();
            }
          }
        ]
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.schemeCreateDialog = dialog;
    dialog.open();
  }

  private confirmCreateScheme(): void {
    const name: string = this.schemeNameInput.trim();
    if (name.length === 0) {
      this.toast('方案名不能为空', 1500);
      return;
    }
    this.schemeCreateDialog?.close();
    const scheme: FeedFilterScheme = createFeedFilterScheme(name);
    this.cfg.schemes.push(scheme);
    this.commit();
    this.openSchemeEditor(scheme.id);
    this.toast(`已创建方案「${name}」`, 1500);
  }

  @Builder
  SchemeNameBody(): void {
    // 说明文案在 secondaryTitle（见 openSchemeCreateDialog），正文只留输入框
    TextInput({ placeholder: '输入方案名', text: this.schemeNameInput })
      .width('100%')
      .height(40)
      .fontSize(16)
      .onChange((v: string): void => {
        this.schemeNameInput = v;
      })
  }

  // ── 恢复默认 ──

  private confirmRestore(): void {
    showConfirm(this.getUIContext(), {
      title: '恢复默认',
      message: '将清空全部筛选规则、名单与方案，推荐列表恢复全量展示。',
      confirmText: '恢复默认',
      onConfirm: (): void => {
        this.cfg = defaultFeedFilterConfig();
        updateFeedFilterConfig(this.cfg);
        this.toast('已恢复默认设置', 1500);
      }
    });
  }

  // ── 转场与标题栏（PlaybackSettingsPage 同款）──

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

  @Builder
  filterBar() {
    NavTitleRow({ title: '首页筛选' })
  }

  @Builder
  filterBarNarrow() {
    BarNarrowShell({ bar: (): void => {
      this.filterBar()
    } })
  }

  // ── 编辑器半屏面板 ──

  @Builder
  EditorSheetBody(): void {
    Column() {
      Text(this.editorTitle())
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text(this.editorHint())
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 4 })
        .width('100%')

      Scroll() {
        Column() {
          if (this.editorMode === 'scheme') {
            this.SchemeEditorBody()
          } else if (this.editorMode === 'blockUps' || this.editorMode === 'allowUps') {
            this.UpListBody()
          } else if (this.editorMode === 'blockCats' || this.editorMode === 'allowCats') {
            this.CatListBody()
          } else {
            this.KwListBody()
          }
        }
        .width('100%')
      }
      .width('100%')
      .margin({ top: 10 })
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      // FIT_CONTENT 面板：滚动区必须有高度上限，否则内容测量不出边界；
      // 短名单时面板收到内容高度（不再像 LARGE 那样占满九成屏幕留一大片空）
      .constraintSize({ maxHeight: 360 })

      if (this.editorMode === 'scheme') {
        this.SchemeAddRow()
      } else {
        Row({ space: 8 }) {
          TextInput({ placeholder: '输入条目', text: this.editorInput })
            .height(40)
            .fontSize(15)
            .layoutWeight(1)
            .onChange((v: string): void => {
              this.editorInput = v;
            })
          Button('添加', { type: ButtonType.Normal })
            .fontSize(14)
            .borderRadius(12)
            .height(36)
            .onClick((): void => {
              this.addEditorEntry();
            })
        }
        .width('100%')
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 12 })
  }

  @Builder
  UpListBody(): void {
    Column() {
      if (this.editorUps.length === 0) {
        Text('名单为空：不屏蔽任何 UP')
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ top: 8, bottom: 8 })
      }
      ForEach(this.editorUps, (e: FeedUpEntry, idx: number): void => {
        Row() {
          Text(this.entryText(e))
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('移除')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 12, top: 6, bottom: 6 })
            .onClick((): void => {
              this.removeEditorUp(idx);
            })
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })
      }, (e: FeedUpEntry, idx: number): string => `up_${idx}_${e.mid}_${e.name}`)
    }
    .width('100%')
  }

  @Builder
  KwListBody(): void {
    Column() {
      if (this.editorStrings.length === 0) {
        Text('名单为空：不启用该维度')
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ top: 8, bottom: 8 })
      }
      ForEach(this.editorStrings, (kw: string, idx: number): void => {
        Row() {
          Text(kw)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('移除')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 12, top: 6, bottom: 6 })
            .onClick((): void => {
              this.removeEditorString(idx);
            })
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })
      }, (kw: string, idx: number): string => `kw_${idx}_${kw}`)
    }
    .width('100%')
  }

  @Builder
  CatListBody(): void {
    Column() {
      Text('常用分区快选')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(COMMON_FEED_CATEGORIES, (cat: string): void => {
          Text(cat)
            .fontSize(13)
            .fontColor(this.editorStrings.indexOf(cat) >= 0 ? Color.White : $r('app.color.text_primary'))
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .margin({ right: 8, bottom: 8 })
            .borderRadius(16)
            .backgroundColor(this.editorStrings.indexOf(cat) >= 0 ? this.themePrimary : $r('app.color.bg_card'))
            .border({ width: 0.5, color: $r('app.color.bg_divider') })
            .onClick((): void => {
              this.toggleCatChip(cat);
            })
        }, (cat: string): string => `cat_${cat}`)
      }
      .width('100%')
      .margin({ top: 8 })

      if (this.editorStrings.length > 0) {
        Divider()
          .color($r('app.color.bg_divider'))
          .margin({ top: 8, bottom: 4 })
        ForEach(this.editorStrings, (cat: string, idx: number): void => {
          Row() {
            Text(cat)
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text('移除')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 12, top: 6, bottom: 6 })
              .onClick((): void => {
                this.removeEditorString(idx);
              })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
        }, (cat: string, idx: number): string => `catsel_${idx}_${cat}`)
      }
    }
    .width('100%')
  }

  @Builder
  SchemeEditorBody(): void {
    Column() {
      TextInput({ placeholder: '方案名', text: this.editingScheme ? this.editingScheme.name : '' })
        .width('100%')
        .height(44)
        .fontSize(16)
        .onChange((v: string): void => {
          this.updateEditingScheme((s: FeedFilterScheme): void => {
            s.name = v;
          });
        })

      Row({ space: 8 }) {
        Text('任一命中')
          .fontSize(13)
          .fontColor(this.schemeModeIs('any') ? Color.White : $r('app.color.text_primary'))
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(16)
          .backgroundColor(this.schemeModeIs('any') ? this.themePrimary : $r('app.color.bg_card'))
          .border({ width: 0.5, color: $r('app.color.bg_divider') })
          .onClick((): void => {
            this.updateEditingScheme((s: FeedFilterScheme): void => {
              s.includeMode = 'any';
            });
          })
        Text('全部命中')
          .fontSize(13)
          .fontColor(this.schemeModeIs('all') ? Color.White : $r('app.color.text_primary'))
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(16)
          .backgroundColor(this.schemeModeIs('all') ? this.themePrimary : $r('app.color.bg_card'))
          .border({ width: 0.5, color: $r('app.color.bg_divider') })
          .onClick((): void => {
            this.updateEditingScheme((s: FeedFilterScheme): void => {
              s.includeMode = 'all';
            });
          })
      }
      .width('100%')
      .margin({ top: 10 })

      Text('包含关键词（圈定想看）')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 12 })
      ForEach(this.editingScheme ? this.editingScheme.includeKeywords : [], (kw: string, idx: number): void => {
        this.SchemeEntryRow(kw, idx, 'include')
      }, (kw: string, idx: number): string => `inc_${idx}_${kw}`)

      Text('排除关键词（命中即滤）')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 12 })
      ForEach(this.editingScheme ? this.editingScheme.excludeKeywords : [], (kw: string, idx: number): void => {
        this.SchemeEntryRow(kw, idx, 'exclude')
      }, (kw: string, idx: number): string => `exc_${idx}_${kw}`)

      Text('排除 UP（mid）')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 12 })
      ForEach(this.editingScheme ? this.editingScheme.excludeUpMids : [], (mid: string, idx: number): void => {
        this.SchemeEntryRow(mid, idx, 'upmid')
      }, (mid: string, idx: number): string => `upm_${idx}_${mid}`)

      Row() {
        Text('删除此方案')
          .fontSize(15)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 14, bottom: 6 })
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.press_overlay')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .onClick((): void => {
        this.confirmDeleteScheme();
      })
    }
    .width('100%')
  }

  private schemeModeIs(mode: string): boolean {
    return this.editingScheme !== null && this.editingScheme.includeMode === mode;
  }

  @Builder
  SchemeEntryRow(text: string, idx: number, kind: string) {
    Row() {
      Text(text)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('移除')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 12, top: 6, bottom: 6 })
        .onClick((): void => {
          this.removeSchemeEntry(kind, idx);
        })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  SchemeAddRow(): void {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ placeholder: '输入后选择加入哪个列表', text: this.editorInput })
          .height(40)
          .fontSize(15)
          .layoutWeight(1)
          .onChange((v: string): void => {
            this.editorInput = v;
          })
      }
      .width('100%')
      Row({ space: 8 }) {
        Button('+ 包含词', { type: ButtonType.Normal })
          .fontSize(13)
          .borderRadius(12)
          .height(32)
          .layoutWeight(1)
          .onClick((): void => {
            this.addSchemeEntry('include');
          })
        Button('+ 排除词', { type: ButtonType.Normal })
          .fontSize(13)
          .borderRadius(12)
          .height(32)
          .layoutWeight(1)
          .onClick((): void => {
            this.addSchemeEntry('exclude');
          })
        Button('+ 排除UP', { type: ButtonType.Normal })
          .fontSize(13)
          .borderRadius(12)
          .height(32)
          .layoutWeight(1)
          .onClick((): void => {
            this.addSchemeEntry('upmid');
          })
      }
      .width('100%')
    }
    .width('100%')
    .margin({ top: 8 })
  }

  build() {
    HdsNavDestination() {
      Stack() {
      List({ scroller: this.pageScroller }) {
        ListItem() {
          Row()
            .width('100%')
            .height(this.safeTop + NAV_TITLE_BAR_HEIGHT)
        }

        ListItem() {
          SectionHeader({ headerText: '开关' })
        }

        ListItem() {
          InsetCard() {
            HdsListItemCard({
              textItem: { primaryText: { text: '启用首页筛选' } },
              suffixItem: new SuffixSwitch({
                isCheck: this.cfg.enabled,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  if (v && !this.cfg.enabled) {
                    // 开启走确认弹窗（提示推荐数会大幅减少）；不直接改
                    // enabled，拷贝重赋值触发重渲染把开关视觉弹回关态。
                    this.cfg = copyFeedFilterConfig(this.cfg);
                    this.requestEnableFilter();
                    return;
                  }
                  this.cfg.enabled = v;
                  this.commit();
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            HdsListItemCard({
              textItem: { primaryText: { text: '严格模式' } },
              suffixItem: new SuffixSwitch({
                isCheck: this.cfg.strictMode,
                selectColor: this.themePrimary,
                onChange: (v: boolean): void => {
                  this.cfg.strictMode = v;
                  this.commit();
                  if (v) {
                    this.toast('严格模式：数据缺失的条目（如缺点赞数）也将被滤除', 2000);
                  }
                }
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0
            })

            CardDivider()

            HdsListItemCard({
              textItem: { primaryText: { text: '恢复默认' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: '清空全部规则' },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.confirmRestore();
              }
            })
          }
        }

        ListItem() {
          SectionHeader({ headerText: '质量档位与阈值' })
        }

        ListItem() {
          InsetCard() {
            HdsListItemCard({
              textItem: { primaryText: { text: '质量档位' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: this.presetLabel() },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openPresetDialog();
              }
            })

            CardDivider()

            HdsListItemCard({
              textItem: { primaryText: { text: '最少播放数' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: this.numberEcho('viewMin') },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openNumberDialog('viewMin');
              }
            })

            CardDivider()

            HdsListItemCard({
              textItem: { primaryText: { text: '赞率下限' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: this.numberEcho('likeRateMin') },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openNumberDialog('likeRateMin');
              }
            })

            CardDivider()

            HdsListItemCard({
              textItem: { primaryText: { text: '最短时长' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: this.numberEcho('durationMinSec') },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openNumberDialog('durationMinSec');
              }
            })

            CardDivider()

            HdsListItemCard({
              textItem: { primaryText: { text: '最长时长' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: this.numberEcho('durationMaxSec') },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openNumberDialog('durationMaxSec');
              }
            })

            CardDivider()

            HdsListItemCard({
              textItem: { primaryText: { text: '发布时间窗' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: this.numberEcho('pubdateWithinDays') },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openNumberDialog('pubdateWithinDays');
              }
            })
          }
        }

        ListItem() {
          SectionHeader({ headerText: 'UP 名单' })
        }

        ListItem() {
          InsetCard() {
            HdsListItemCard({
              textItem: { primaryText: { text: '屏蔽 UP' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: this.listCountOf('blockUps') },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openListEditor('blockUps');
              }
            })

            CardDivider()

            HdsListItemCard({
              textItem: { primaryText: { text: '仅看 UP' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: this.listCountOf('allowUps') },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openListEditor('allowUps');
              }
            })
          }
        }

        ListItem() {
          SectionHeader({ headerText: '标题与分区' })
        }

        ListItem() {
          InsetCard() {
            HdsListItemCard({
              textItem: { primaryText: { text: '屏蔽标题关键词' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: this.listCountOf('blockTitle') },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openListEditor('blockTitle');
              }
            })

            CardDivider()

            HdsListItemCard({
              textItem: { primaryText: { text: '仅看标题关键词' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: this.listCountOf('allowTitle') },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openListEditor('allowTitle');
              }
            })

            CardDivider()

            HdsListItemCard({
              textItem: { primaryText: { text: '屏蔽分区' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: this.listCountOf('blockCats') },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openListEditor('blockCats');
              }
            })

            CardDivider()

            HdsListItemCard({
              textItem: { primaryText: { text: '仅看分区' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: this.listCountOf('allowCats') },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openListEditor('allowCats');
              }
            })
          }
        }

        ListItem() {
          SectionHeader({ headerText: '筛选方案' })
        }

        ListItem() {
          InsetCard() {
            HdsListItemCard({
              textItem: { primaryText: { text: '启用方案' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: this.activeSchemeLabel() },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openActiveSchemeDialog();
              }
            })

            ForEach(this.cfg.schemes, (s: FeedFilterScheme, idx: number): void => {
              CardDivider()

              HdsListItemCard({
                textItem: { primaryText: { text: s.name.length > 0 ? s.name : '(未命名方案)' } },
                suffixItem: new SuffixText({
                  text: this.cfg.activeSchemeId === s.id
                    ? `使用中 · ${s.includeMode === 'all' ? '全部命中' : '任一命中'}`
                    : (s.includeMode === 'all' ? '全部命中' : '任一命中')
                }),
                cardBackgroundColor: Color.Transparent,
                cardPrefixMargin: 0,
                cardSuffixMargin: 0,
                onClick: (): void => {
                  this.openSchemeEditor(s.id);
                }
              })
            }, (s: FeedFilterScheme): string => `scheme_${s.id}`)

            CardDivider()

            HdsListItemCard({
              textItem: { primaryText: { text: '新建方案' } },
              suffixItem: new SuffixArrowIconText({
                text: { text: '' },
                endArrow: {}
              }),
              cardBackgroundColor: Color.Transparent,
              cardPrefixMargin: 0,
              cardSuffixMargin: 0,
              onClick: (): void => {
                this.openSchemeCreateDialog();
              }
            })
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
      .edgeEffect(EdgeEffect.Spring)
      .cachedCount(10)
      .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
      .constraintSize({ maxWidth: TwoColumnLayout.contentMaxWidth(this.currentBreakpoint, this.isLandscape) })
      // 自绘渐变模糊层驱动：逐帧更新 + 停止校准终态（渐变软边由 overlay 承担）
      .onDidScroll((xOffset: number, yOffset: number): void => {
        this.syncTopBlurProgress();
      })
      .onScrollStop((): void => {
        this.syncTopBlurProgress();
      })

      // 顶栏渐变模糊层：盖 List 内容之上（z 序低于 HDS titleBar），进度命令式驱动
      TopGradientBlurOverlay({
        barHeightVp: this.safeTop + NAV_TITLE_BAR_HEIGHT,
        updater: this.topBlurUpdater
      })
      }
    }
    // HDS 沉浸光感标题栏：材质 / 滚动模糊 / 温控统一由 HdsTitleBarStyle 决策
    //（HDS 内置滚动效果关闭：渐变模糊由自绘 TopGradientBlurOverlay 承担，防双重模糊）
    .titleBar({
      avoidLayoutSafeArea: true,
      style: HdsTitleBarStyle.styleOptions(undefined, undefined, false),
      content: {
        stackBuilder: (): void => {
          this.filterBarNarrow();
        }
      }
    })
    .bindToScrollable([this.pageScroller])
    .translate({ x: this.navTransX })
    .customTransition((op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
      return this.navTransitionDelegate(op, isEnter);
    })
    .onBackPressed((): boolean => handleSubPageBackPress())
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindSheet($$this.showEditorSheet, this.EditorSheetBody(), {
      // 自适应高度：面板只占内容高度（名单为空/很短时不再留大片空白），
      // 内容超出由内部 Scroll 的 maxHeight 上限兜住
      // preferType：大窗（≥840vp）默认跟手样式收不回，锁底部样式（手机默认本就底部）
      preferType: SheetType.BOTTOM,
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false
    })
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets）：
 * Index 经动态 import 后用 wrapBuilder 调用本 Builder 渲染。
 */
@Builder
export function HomeFeedFilterPageBuilder(): void {
  HomeFeedFilterPage()
}

/** 懒加载注册表预包装：wrapBuilder 只接受本文件内的直接 @Builder 引用（编译期校验）。 */
export const HomeFeedFilterPageWrapped: WrappedBuilder<[]> = wrapBuilder(HomeFeedFilterPageBuilder);
