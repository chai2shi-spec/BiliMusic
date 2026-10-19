/**
 * 搜索页顶栏内容件（HarmonyX 根栏移植，2026-10-10；2026-10-11 组件标准化迁移）。
 *
 * 搜索行（SearchInputBar）与页签行（SearchTabsBar）都回到根 HdsNavigation
 * titleBar 的 stackBuilder（Index.immersiveTitleBarContent）：
 * - SearchInputBar：行 1（56 锁高行内垂直居中，Index 侧承载），纯内容件。
 *   2026-10-11 组件标准化迁移（对齐 HarmonyOSComponentUXExamples）：
 *   · TextInput → Search 标准搜索框（自带放大镜图标，onChange 回写 keyword
 *     替代原 $$ 双向绑定）；
 *   · 「视频/UP主」自绘 Stack+粉片 translate 滑块 → CapsuleSegmentButtonV2
 *     标准分段按钮，B 站粉经 itemSelectedBackgroundColor 覆写；上一轮的自绘
 *     滑片 systemMaterial 光感由组件自带材质底取代。
 * - SearchTabsBar：行 2（position 溢出渲染到标题栏下方），纯内容件；四页签
 *   滑块同款换 CapsuleSegmentButtonV2（2026-10-10「与行 1 同一套视觉语言」
 *   约定保持）。
 *   ⚠️ 已知行为变化（用户确认接受）：HDS 材质只覆盖标题栏 [0, safeTop+56]，
 *   行 2 无磨砂背板 —— 滚动内容从行 2 下方穿过（HarmonyX 首页页签行同款）。
 *
 * - V1 容器 + V2 子组件（CapsuleSegmentButtonV2 是 @ComponentV2）单向数据流：
 *   点击 → onItemClicked → TabScrollerHolder 静态回调 → 页面写 AppStorage →
 *   @StorageLink 刷新 → selectedIndex 重算。不绑 $selectedIndex（V1 下不可用）。
 * - 状态：keyword / searchKind / tab 是页面与栏共享的双向状态（两侧
 *   @StorageLink，任一侧写入另一侧即见）。页签行实测高度经
 *   STORE_SEARCH_TABS_HEIGHT 回写（SearchTabsBar onAreaChange），页面读它做
 *   列表挂载门控与让位量（contentStartOffset）。
 * - 动作：经 TabScrollerHolder 静态回调转交页面私有方法（页面 aboutToAppear 注册）。
 */

import { TabScrollerHolder } from '../service/TabScrollerHolder';
import { BUTTON_RADIUS_VP } from '../common/constants/InteractionConstants';
import {
  makeBiliSegmentColors,
  SegmentColors
} from '../utils/HeaderBarMaterial';
import { SearchStateHolder } from '../service/SearchStateHolder';
import {
  CapsuleSegmentButtonV2,
  LengthMetrics,
  SegmentButtonV2Items
} from '@kit.ArkUI';
import {
  STORE_SEARCH_KEYWORD,
  STORE_SEARCH_KIND,
  STORE_SEARCH_TAB,
  STORE_SEARCH_TABS_HEIGHT,
  STORE_THEME_PRIMARY
} from '../common/Constants';

/**
 * 搜索行（根栏 stackBuilder 行 1，垂直居中在 56vp 行内）：
 * Search 搜索框 + 类型分段按钮（视频 / UP主）。
 * 搜索按钮 2026-10-16 删除（用户：「看着多余」）：提交搜索走键盘 onSubmit，
 * 搜索框不损失任何能力。
 */
@Component
export struct SearchInputBar {
  /** 双向：根栏输入 ↔ 页面（点历史词条 / 恢复会话词）。初值取 holder 的会话词，两侧同源不打架 */
  @StorageLink(STORE_SEARCH_KEYWORD) keyword: string = SearchStateHolder.keyword;
  /** 双向：分段按钮选段 ↔ 页面（doSearch / 占位文案都读它） */
  @StorageLink(STORE_SEARCH_KIND) searchKind: string = 'video';
  /** 「视频/UP主」分段按钮条目：静态一次构造 */
  private kindItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: '视频' },
    { text: 'UP主' }
  ]);

  /** 分段按钮主题色配色组：每次渲染现取（读 AppStorage），缓存成字段切色不刷新
   *  ⚠️ V1 @Component 禁用 getter 访问器（转译会丢弃，运行时 this.segColors 为
   *  undefined 直接崩溃），用普通成员方法。 */
  private segColors(): SegmentColors {
    return makeBiliSegmentColors();
  }

  build() {
    Row() {
      // Search 标准搜索框（2026-10-11 组件标准化迁移）：value 单向读 +
      // onChange 回写 keyword（@StorageLink 双向，替代原 TextInput 的 $$）。
      // 点击 / 获焦都展开历史：已获焦时再点一次不会触发 onFocus，只靠 onClick 补。
      Search({
        value: this.keyword,
        placeholder: this.searchKind === 'user' ? '搜索UP主' : '搜索歌曲、歌单'
      })
        .layoutWeight(1)
        // 高度与右侧分段按钮一致（32），圆角与按钮同一套 8vp 语言
        .height(32)
        // 与行内 13fp 设计语言一致（默认 16fp 占位在窄框内会截断）
        .placeholderFont({ size: 13 })
        .borderRadius(BUTTON_RADIUS_VP)
        .backgroundColor($r('app.color.bg_card'))
        .onSubmit((): void => {
          TabScrollerHolder.searchSubmit();
        })
        .onClick((): void => {
          TabScrollerHolder.searchOpenHistory();
        })
        .onFocus((): void => {
          TabScrollerHolder.searchOpenHistory();
        })
        .onChange((v: string): void => {
          // 回写 keyword（原 $$ 通路）；这里只收历史面板，别让面板盖着结果
          this.keyword = v;
          TabScrollerHolder.searchCloseHistory();
        })
      // 搜索类型分段按钮（视频 / UP主，iOS segmented 式）。
      // 放在搜索框同一行而不是下方：下方是历史面板的定位区，塞东西进去会和面板打架。
      CapsuleSegmentButtonV2({
        items: this.kindItems,
        selectedIndex: this.searchKind === 'user' ? 1 : 0,
        onItemClicked: (index: number): void => {
          TabScrollerHolder.searchSetKind(index === 1 ? 'user' : 'video');
        },
        itemSelectedBackgroundColor: this.segColors().selectedBg,
        itemSelectedFontColor: this.segColors().selectedFont,
        itemSelectedFontWeight: FontWeight.Medium,
        itemFontColor: this.segColors().unselectedFont,
        itemFontWeight: FontWeight.Normal,
        itemFontSize: LengthMetrics.vp(13),
        itemSelectedFontSize: LengthMetrics.vp(13),
        buttonBackgroundColor: this.segColors().grooveBg,
        buttonBorderRadius: LengthMetrics.vp(BUTTON_RADIUS_VP),
        itemBorderRadius: LengthMetrics.vp(6),
        // 内部背板最小高度默认系统 token（约 36vp）会盖过外层 .height(32)
        // （真机验收：与搜索框/按钮高度不一致），对齐到 32
        buttonMinHeight: LengthMetrics.vp(32),
        // 紧凑内边距：系统默认 start/end 16vp（padding_level4）空气感过强
        // （真机验收「留空太多」），收到 8vp 对齐旧自绘滑块密度
        itemPadding: { start: LengthMetrics.vp(8), end: LengthMetrics.vp(8) }
      })
        .height(32)
        // ⚠️ V2 分段按钮测量特性：给多大渲染多大（均摊到各段），不会内容自适应
        // —— 不设宽度会把同行 layoutWeight(1) 的搜索框压成 0 宽（2026-10-11
        // 真机回归：搜索框消失）。显式 108vp = 背板 padding 4×2 + 两段
        // （最长文案 UP主约 31 + itemPadding 8×2），与旧自绘 102vp 同密度。
        .width(108)
        // 与搜索框拉开 8vp 间距（搜索按钮删除前的三段等距口径保留）
        .margin({ left: 8 })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
  }
}

/**
 * 内容页签行（搜索 / 推荐 / 排行榜 / 音乐中心，根栏 stackBuilder 行 2）。
 * 2026-10-11 组件标准化迁移：自绘滑块选段换 CapsuleSegmentButtonV2，与行 1
 * 「视频/UP主」同一套标准组件与 B 站粉配色（2026-10-10 同款约定保持）。
 * 行高 49.6 = 胶囊 32 + 顶部下移 17.6（用户 2026-10-15：行高自 61.6 减 12）：
 * 与上方搜索行拉开呼吸间距；胶囊恰好填满内容盒（17.6~49.6），行下沿即胶囊底。
 * 实测高（onAreaChange 量出 49.6 回写 searchTabsHeight）→ 历史面板定位
 * （barTotalHeight）读镜像自动跟随。页面首条让位已与本行解耦（2026-10-15：
 * SearchPage 用独立定值 SEARCH_LIST_START_EXTRA_VP，不读本行实测高），
 * 调本行高度不再影响条目起始位。
 * 行级 onClick：历史面板展开时点分段按钮外空白处照常收起（段自身点击不
 * 冒泡到行 —— 切换页签不收历史面板，与原行为一致）。
 */
@Component
export struct SearchTabsBar {
  /** 只读：选中态由页面 switchTab 写入 */
  @StorageProp(STORE_SEARCH_TAB) tab: string = 'search';
  /** 页签行实测高（vp）：onAreaChange 回写（初值 0 = 未实测），页面门控/让位量读它 */
  @StorageLink(STORE_SEARCH_TABS_HEIGHT) searchTabsHeight: number = 0;
  /** 主题色主色（本 struct 只经它建立对切色的渲染依赖，配色组在 getter 里现取） */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /** 四页签分段按钮条目：静态一次构造（与 tabKeyAt 映射顺序一致） */
  private tabItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: '搜索' },
    { text: '推荐' },
    { text: '排行榜' },
    { text: '音乐中心' }
  ]);

  /** 分段按钮主题色配色组：每次渲染现取（读 AppStorage），缓存成字段切色不刷新
   *  ⚠️ V1 @Component 禁用 getter 访问器（转译会丢弃，运行时 this.segColors 为
   *  undefined 直接崩溃），用普通成员方法。 */
  private segColors(): SegmentColors {
    return makeBiliSegmentColors();
  }

  build() {
    Row() {
      CapsuleSegmentButtonV2({
        items: this.tabItems,
        selectedIndex: this.segmentIndex(),
        onItemClicked: (index: number): void => {
          TabScrollerHolder.searchSwitchTab(this.tabKeyAt(index));
        },
        itemSelectedBackgroundColor: this.segColors().selectedBg,
        itemSelectedFontColor: this.segColors().selectedFont,
        itemSelectedFontWeight: FontWeight.Medium,
        itemFontColor: this.segColors().unselectedFont,
        itemFontWeight: FontWeight.Normal,
        itemFontSize: LengthMetrics.vp(13),
        itemSelectedFontSize: LengthMetrics.vp(13),
        buttonBackgroundColor: this.segColors().grooveBg,
        buttonBorderRadius: LengthMetrics.vp(BUTTON_RADIUS_VP),
        itemBorderRadius: LengthMetrics.vp(6),
        // 内部背板最小高度默认系统 token（约 36vp）会盖过外层 .height(32)，对齐到 32
        buttonMinHeight: LengthMetrics.vp(32)
      })
        .layoutWeight(1)
        .height(32)
    }
    .height(49.6)
    .padding({ top: 17.6, left: 12, right: 12 })
    .onClick((): void => {
      TabScrollerHolder.searchCloseHistory();
    })
    // 量出页签行真实高度：页面列表挂载门控与让位量都读它
    .onAreaChange((_old: Area, cur: Area): void => {
      const h: number = cur.height as number;
      if (h > 0) {
        this.searchTabsHeight = h;
      }
    })
  }

  /** 页签键 → 段序（与 tabItems 声明顺序一致）；tabIndex 与基类保留成员撞名，故此命名 */
  private segmentIndex(): number {
    if (this.tab === 'recommend') {
      return 1;
    }
    if (this.tab === 'ranking') {
      return 2;
    }
    if (this.tab === 'center') {
      return 3;
    }
    return 0;
  }

  /** 段序 → 页签键（segmentIndex 的逆映射，onItemClicked 回调用） */
  private tabKeyAt(index: number): string {
    if (index === 1) {
      return 'recommend';
    }
    if (index === 2) {
      return 'ranking';
    }
    if (index === 3) {
      return 'center';
    }
    return 'search';
  }
}
