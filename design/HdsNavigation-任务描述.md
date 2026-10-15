# 顶栏改造任务描述：全站顶栏迁移到 HdsNavigation（沉浸光感）

> 用途：把本文件整段交给 AI（或新会话）当作任务书。本文件**只是描述，不含任何代码改动**。
> 工程根：`E:/BiliMusic/HarmonyOS-Phone`（HarmonyOS 7 / API 26，纯 ArkTS + ArkUI）。

---

## 一、任务目标

把工程里**每个页面自绘的 `GlassTopBar` 毛玻璃顶栏**，换成 HDS（`@kit.UIDesignKit`）的
`HdsNavigation` / `HdsNavDestination` 原生标题栏，用 HDS 的
`systemMaterialEffect`（系统沉浸材质）+ `scrollEffectOpts`（滚动模糊）实现真正的
**沉浸光感顶栏**，而不是现在用 `backgroundEffect` 模拟出来的毛玻璃。

要求：**顶栏内容是自定义的**（返回键、标题、按钮、第二行控件都保留各页现在的样子），
即「用 HDS 的标题栏容器 + 材质能力，装各页自己的顶栏内容」。

---

## 二、改造前的真实结构（已核对到行号，务必按此描述，不要凭印象）

### 2.1 根容器（`entry/src/main/ets/pages/Index.ets`）

```
Stack()
  Column()
    Navigation(NavStackHolder.stack)          // :516
      HdsTabs({ controller, index })          // :517  四个 TabContent：搜索/歌单/下载/设置
        ...
      .navDestination(this.pageMap)           // :550
      .hideTitleBar(true)                     // :551
      .mode(NavigationMode.Stack)             // :552
    AppToast()                                // :559
    AppDialogHost()                           // :563
```

- `pageMap(name: string, param: Object)`（`:489`）分发 **9 个 `NavDestination` 子页**：
  `Player` / `PlaylistDetail` / `Recent` / `Follows` / `UpSpace` / `WatchHistory` / `About` / `Login` / `SmsLogin`。
- **四个 Tab 页不是 NavDestination**，它们是 `Navigation` 的 navBar 内容（`TabContent` 里直接 new 的组件）。
- `Navigation` 自己**没有**用 `titleBar()`，而是 `.hideTitleBar(true)` —— 顶栏全部由页面自绘。

### 2.2 自绘顶栏组件 `components/GlassTopBar.ets`

- 结构：`Stack` 双层
  - **材质层**：空 `Row()` 挂 `HeaderBarMaterialModifier`（`utils/HeaderBarMaterial.ets`，
    内容是 `backgroundEffect({ radius: 40, saturation: 1.3, brightness: 1.0, color: header_glass_tint })`），
    `hitTestBehavior(HitTestMode.None)`，`.border({ width: { bottom: 0.5 }, ... })`，
    `opacity = glassOpacity()`。
  - **内容层**：`Column()` 包 `@BuilderParam bar()`，`padding({ top: safeTop })`，
    `onAreaChange` 回写 `barLayerHeight` 给材质层铺高。
- 三种常量：`GLASS_BASE_OPACITY = 0.62`（静止基线）、
  `GLASS_TOP_BAR_REVEAL_DISTANCE = 12`（浮出距离）、`calcReveal(offset)`（归一化到 0..1）。
- 滚动驱动：调用页用 `List(scroller)` 的 `onDidScroll` 读 `currentOffset().yOffset`，
  经 `calcReveal()` 传进 `reveal`。
- **顶栏材质走的是 `backgroundEffect` 模拟**，不是系统材质 —— 因为 `systemMaterial` 在模拟器 /
  低配设备上会**静默不渲染**（不报错、不告警，只退化成半透明纯色）。

### 2.3 用到 `GlassTopBar` 的页面（12 个，逐个都要改）

| 页面 | 顶栏内容结构（`@Builder` 名） | 备注 |
|---|---|---|
| `SearchPage` | 搜索行（胶囊输入框 + 搜索/切换按钮） + 页签行（视频 / UP主） | 两行，第二行是段切换 |
| `PlaylistsPage` | 行1「歌单」小标题 +「新建」按钮；行2「最近播放」入口卡片 | 两行 + 卡片 |
| `DownloadsPage` | 「下载」小标题 +「选择」按钮 | 单行 |
| `SettingsPage` | 「设置」小标题 | 单行，最简 |
| `RecentPage` | 返回行（返回键 + 「最近播放」）+ 按钮行（播放全部 / 清空） | 两行 |
| `PlaylistDetail` | 返回行 + 头部区（封面 + 大标题 + 元信息） | 头部区很高 |
| `FollowsPage` | 返回行 + 标题 + 「共 N 人」 | 两行 |
| `UpSpacePage` | 返回行 + UP 资料头部区（头像 + 昵称 + 数据） | 头部区很高 |
| `WatchHistoryPage` | 返回行 + 标题 + 段切换行 | 两行 |
| `AboutPage` | 返回行 + 「关于」 | 单行 |
| `LoginPage` | 返回行 + 标题 | 单行 |
| `SmsLoginPage` | 返回行 + 标题 | 单行 |

> `PlayerPage` **不用 `GlassTopBar`**（全屏播放页，自绘 `components/player/TopAreaComponent`）。
> **明确要求：本次不动播放页顶栏。**

### 2.4 每个子页还有一套「让位」逻辑要一并处理

各页都有一份：
- `@State barHeight: number`（`GlassTopBar` 的 `onAreaChange` 回写）
- 列表 `List().padding({ top: this.barHeight })` 之类的让位
- `listScroller` + `onDidScroll` + `calcReveal()` 驱动 `reveal`
- 自绘的 44×44 返回键（`SymbolGlyph(sys.symbol.chevron_left)` + 按压态，`onClick` → `NavStackHolder.stack.pop()`）

**迁移后这些应该由 HDS 标题栏接管或删除**，不要两套并存（会顶栏叠顶栏）。

### 2.5 已经做对了的样板：底栏悬浮胶囊

`Index.ets:394-412` 的 `barFloatingStyle()` 返回 `HdsTabsFloatingStyle`，它**已经是「沉浸光感」的正确写法**，
改造顶栏时应与它风格统一：

```
systemMaterialEffect: {
  materialType: hdsMaterial.MaterialType.IMMERSIVE,
  materialLevel: useExquisite ? hdsMaterial.MaterialLevel.EXQUISITE
                             : hdsMaterial.MaterialLevel.ADAPTIVE
},
lightColor: MaterialCompat.withAlpha(BILI_PINK_HEX, GLOW_ALPHA),  // #FB7299 @ 12%
barOpacity: 0.9,
barBottomMargin: ...
```

- `BILI_PINK_HEX = '#FB7299'`、`GLOW_ALPHA = 0.12` 在 `common/Constants.ts:53,55`。
- `MaterialCompat.supportsImmersiveMaterial()`（`utils/MaterialCompat.ets:209`）负责探测设备是否支持
  `hdsMaterial.MaterialType.IMMERSIVE`，不支持时回落 `ADAPTIVE`。

---

## 三、目标 API（已在本机 SDK 逐字段核实，可直接照写）

**SDK 路径**：`<DevEco>/sdk/default/hms/ets/api/@hms.hds.hdsBaseComponent.d.ets`
**导入**：`import { ... } from '@kit.UIDesignKit';`
⚠️ **必须在 `.ets` 文件里 import**，`.ts` 里 import 会报
`10311005 Identifier 'xxx' comes from '@hms.hds.xxx.d.ets' which can not be imported in .ts file`。

### 3.1 容器

```ts
export declare type HdsNavigationInterface = (pathInfos?: NavPathStack) => HdsNavigationAttribute;
export declare type HdsNavDestinationInterface = () => HdsNavDestinationAttribute;
export declare type NavDestinationBuilder = (name: string, pageInfos: Object) => void;
```

- `HdsNavigation(stack)` 与原生 `Navigation(stack)` 同签名 —— 根容器**可以平替**。
- `HdsNavDestination()` 与原生 `NavDestination()` 同签名（无参）。

### 3.2 `HdsNavigationAttribute` / `HdsNavDestinationAttribute` 方法（两者几乎一致）

```
titleBar(options?: HdsNavigationTitleBarOptions)     // 核心
titleMode(value: HdsNavigationTitleMode)
hideTitleBar(hide: boolean, animated?: boolean)
hideBackButton(value: boolean)
toolbarConfiguration(value, options?)
hideToolBar(hide, animated?)
navBarWidth / navBarPosition / hideNavBar / navBarWidthRange / minContentWidth
mode(value: NavigationMode)
divider(style)
navDestination(builder: NavDestinationBuilder)
ignoreLayoutSafeArea(types?, edges?)
systemBarStyle(originalStyle, scrollEffectStyle)     // 状态栏图标深浅
dynamicHideTitleBar(value: DynamicHideParams)        // 滚动自动隐藏标题栏
bindToScrollable(scrollers: Array<Scroller>)         // 关键：绑定滚动容器
bindToNestedScrollable(scrollers: Array<NestedScrollInfo>)
enableDragBar / enableModeChangeAnimation
onTitleModeChange(callback) / onNavBarStateChange / onNavigationModeChange
customNavContentTransition(delegate: CustomTransitionDelegate)
recoverable / splitPlaceholder / withTheme / enableVisibilityLifecycleWithContentCover
```

`HdsNavDestination` 独有：`onShown / onHidden / onWillAppear / onWillDisappear / onWillShow / onWillHide /
onReady / onBackPressed / systemTransition(type) / customTransition(delegate) / onResult / onNewParam / onActive / onInactive`。

> ⚠️ 注意：`HdsNavDestination.customTransition(delegate: NavDestinationTransitionDelegate)` 与原生
> `NavDestination.customTransition((op, isEnter) => NavDestinationTransition[])` **签名可能不同**
> （原生是返回数组的函数，HDS 是 `NavDestinationTransitionDelegate`），迁移前**必须先把类型定义读清楚**，
> 不能照抄原代码。

### 3.3 `HdsNavigationTitleBarOptions`（`titleBar()` 的入参）

```ts
interface HdsNavigationTitleBarOptions {
  padding?: PaddingOptions;              // { start?: LengthMetrics; end?: LengthMetrics }
  style?: TitleBarStyleOptions;          // 样式 + 滚动效果 + 材质（核心）
  content?: TitleBarContentOptions;      // 内容：标题 / 菜单 / 返回键 / 底部扩展
  enableHoverMode?: boolean;             // 默认 false
  avoidLayoutSafeArea?: boolean;         // 默认 false
  enableComponentSafeArea?: boolean;     // 默认 false
}
```

### 3.4 `TitleBarStyleOptions`（**沉浸光感就在这几个字段**）

```ts
interface TitleBarStyleOptions {
  scrollEffectOpts?: ScrollEffectOptions;
  originalStyle?: HdsNavigationTitleBarStyle;      // 静止态样式
  scrollEffectStyle?: HdsNavigationTitleBarStyle;  // 滚动后样式
  blurStrategy?: BlurStrategy;
  thermoCtrl?: boolean;                            // 温控（建议 true）
  systemMaterialEffect?: SystemMaterialParams;     // ★ 系统沉浸材质
}

interface ScrollEffectOptions {
  enableScrollEffect?: boolean;
  scrollEffectType?: ScrollEffectType;
  enableRefreshOffsetChange?: boolean;
  blurEffectiveStartOffset?: LengthMetrics;
  blurEffectiveEndOffset?: LengthMetrics;
}

interface SystemMaterialParams {
  materialType?: hdsMaterial.MaterialType;   // NONE=0 / ADAPTIVE=100 / IMMERSIVE=101
  materialLevel?: hdsMaterial.MaterialLevel; // EXQUISITE=0 / GENTLE=1 / SMOOTH=2
}

interface HdsNavigationTitleBarStyle {
  backgroundStyle?: HdsNavigationBackgroundStyle;   // { backgroundColor?, maskExtraHeight?, blurRadius? }
  contentStyle?: HdsTitleBarContentStyle;
}

interface HdsTitleBarContentStyle {
  titleStyle?: HdsNavigationTitleStyle;      // { mainTitleColor?, subTitleColor?, mainTitleShadowColor?, subTitleShadowColor? }
  menuStyle?: HdsNavigationIconItemStyle;    // { backgroundColor?, iconColor?, textColor? }
  backIconStyle?: HdsNavigationIconItemStyle;
  subIconStyle?: HdsNavigationIconItemStyle;
  dividerStyle?: HdsNavigationDividerStyle;  // { dividerColor? }
}
```

**枚举取值**（照抄，别猜）：

```
ScrollEffectType:      COMMON_BLUR=0 | GRADUAL_BLUR=1 | GRADIENT_BLUR=2 | IMMERSIVE_GRADIENT_BLUR=3
BlurStrategy:          ENABLE=0 | DISABLE=1 | ADAPTIVE=2
HdsNavigationTitleMode: FREE=0 | FULL=1 | MINI=2 | MODAL=3
HdsNavDestinationTitleMode: MINI=100 | MODAL=101
DividerShowType:       OFF=0 | ON=1 | AUTO=2
BottomBuilderShowType: DIRECTLY_SHOW=0 | OVERDRAG_SHOW=1
HideMode:              SCROLL_UP_TO=0 | SCROLL_UP=1 | SCROLL_DOWN=2 | SCROLL_UP_TO_BLEND_SCROLL_UP=3
IconStyleMode:         SMALL=100 | NORMAL=101 | LARGE=102
TextStyleMode:         NORMAL=200 | SINGLE_CHARACTER=201
TitleSize:             TITLE_S=0 | TITLE_ML=1
hdsMaterial.MaterialType:  NONE=0 | ADAPTIVE=100 | IMMERSIVE=101
hdsMaterial.MaterialLevel: EXQUISITE=0 | GENTLE=1 | SMOOTH=2
```

### 3.5 `TitleBarContentOptions`（自定义内容挂这里）

```ts
interface TitleBarContentOptions {
  title?: HdsNavigationTitle;              // { mainTitle: ResourceStr（必填）, subTitle?, subTitleBuilder?,
                                           //   mainTitleId?, subTitleId?, mainTitleAccessibilityText?,
                                           //   subTitleAccessibilityText?, mainTitleSize?: TitleSize }
  menu?: HdsNavigationMenuContentOptions;  // { value?: Array<HdsNavigationMenuItemOptions>, maxCount?, multiWindowEntryInAPPMenu? }
  backIcon?: HdsNavigationBackButtonItemOptions;   // = HdsNavigationIconOptions
  subIcon?: HdsNavigationBadgeIconOptions;
  stackBuilder$ / stackBuilderComponent$ / stackBuilderContent$   // 自定义整块标题栏内容
  bottomBuilder?: BottomBuilderParams;     // { builder: CustomBuilder（必填）, height?, showType?, builderComponent?, builderContent? }
  divider?: HdsNavigationDividerParams;    // { showType?: DividerShowType }
}

interface HdsNavigationIconOptions {
  icon?: IconType;        // ResourceStr | SymbolGlyphModifier | PixelMap
  label?: ResourceStr;
  isEnabled?: boolean;
  action?: Callback<void>;
  componentId?: string;
  type?: IconStyleMode | TextStyleMode;
}

interface HdsNavigationBadgeIconOptions {
  content?: HdsNavigationIconOptions;
  badge?: { count?: number; value?: string; accessibilityText?: ResourceStr };
}
```

**要点**：
- `title.mainTitle` 是**必填**（不是可选）。
- 文本按钮（如「播放全部 / 清空」）用 `menu.value[].content.label + action` 表达。
- 第二行自定义控件（搜索行 / 段切换行 / 入口卡片 / UP 资料头部）用 **`bottomBuilder`** 承载。

### 3.6 `dynamicHideTitleBar`（可选增强）

```ts
interface DynamicHideParams {
  hideTitleArea?: boolean;   // 默认 false
  hideBottomBuilder?: boolean;
  hideStatusBar?: boolean;
  mode?: HideMode;           // 默认 SCROLL_UP_TO
  hideOffset?: number;       // 默认 0（vp）
  hideRatio?: number;        // [1.0, 3.0]，默认 2.0
}
```

### 3.7 前置开关（**已经开好了，不用改**）

`entry/src/main/module.json5` 里已有：

```json
"metadata": [{ "name": "ohos.arkui.UIMaterial.state", "value": "enable" }]
```

⚠️ 缺这一项时 `systemMaterialEffect` / `.systemMaterial()` 会**静默不渲染材质**（不报错、不告警）。

---

## 四、必须先回答的三个架构问题（**先分析、先给结论，别直接动手改全部**）

### 问题 1（最关键）：四个 Tab 页的顶栏怎么做？

`HdsNavigation.titleBar()` 作用在 **Navigation 自身的 navBar 区域**，而四个 Tab 页是
`TabContent` 里的组件（在 navBar 内部）。所以：

- **9 个子页**（`HdsNavDestination`）：直接 `.titleBar({...})`，天然对齐，方案明确。
- **4 个 Tab 页**：有三条路，需要**先做可行性验证再给结论**：

  | 方案 | 做法 | 风险 |
  |---|---|---|
  | A. 只换材质，结构不动 | 保留各页自绘顶栏，把材质从 `backgroundEffect` 换成 HDS 材质 | 改动最小，但顶栏仍是自绘，「用 HdsNavigation」名不副实 |
  | B. Navigation 级统一标题栏 | 让 `HdsNavigation` 自己渲染 `titleBar`，内容由 `activeTab` 驱动，滚动容器用 `bindToScrollable([当前页 scroller])` 动态绑定 | 顶栏脱离 TabContent，四个页共用一个实例，切页时标题要换、`FULL/MINI` 常态要调；**未验证 HDS 是否支持动态换 scroller** |
  | C. 把 Tab 页改成 NavDestination | 每个 Tab 变成压栈页面 | 破坏「底部页签直接切换」的交互，**不建议** |

  要求：AI 先**只在一个页面（建议 `SettingsPage`，因为它顶栏最简单）上做最小验证**，
  编译 + 真机确认材质可见、滚动正常，再给出结论与推荐方案，再全量铺开。

### 问题 2：顶栏要不要加品牌粉光晕？

`HdsTabsFloatingStyle` 有 `lightColor` 字段，但 **`HdsNavigationBackgroundStyle` 没有**
（只有 `backgroundColor / maskExtraHeight / blurRadius`）。

- 历史结论：`GlassTopBar` 曾在 2026-10-06 试过「整面 12% 粉 + 底缘 2vp 粉渐变带」，
  **真机观感显脏，已整层删除**。
- 因此**默认不要加粉色底纹**；光感靠 `systemMaterialEffect`（IMMERSIVE 材质自身的
  边缘光/厚度感）+ `scrollEffectType: IMMERSIVE_GRADIENT_BLUR` 表达。
- 若一定要试，只能通过 `backgroundStyle.backgroundColor`（半透明色）近似，
  且**必须真机看效果**，效果不好要能一键退回。

### 问题 3：HDS 材质不可见时的兜底

现有代码的教训：`systemMaterial` 在「设备上报不支持沉浸材质 / 材质档为 SMOOTH / 模拟器」时
**静默不渲染**。而现有 `backgroundEffect` 是「全环境一致可见」的。

- 要求：保留一条**可切换的兜底路径** ——
  设备不支持 `hdsMaterial.MaterialType.IMMERSIVE`（用现有的
  `MaterialCompat.supportsImmersiveMaterial()` 探测）时，回落到现在的 `backgroundEffect` 毛玻璃。
- 效果差异必须在真机上肉眼确认，不能只看编译通过。

---

## 五、分批落地顺序（每批必须编译通过 + 真机确认后再做下一批）

| 批次 | 内容 | 目标 |
|---|---|---|
| **第 0 批** | 读 SDK 类型定义，确认 `NavDestinationTransitionDelegate` 的真实签名；确认 `HdsNavigation` 能否平替根 `Navigation`（`.mode(NavigationMode.Stack)` / `.hideTitleBar(true)` / `.navDestination()` 是否都支持） | 只出结论，不改代码 |
| **第 1 批** | 挑 **1 个最简单的子页**（建议 `AboutPage`：只有「返回行 + 一行标题」）做样板：`NavDestination` → `HdsNavDestination` + `.titleBar()` | 跑通「HDS 标题栏 + 自定义内容 + 返回」最小闭环 |
| **第 2 批** | 用同一模板迁移其余 **8 个子页**（含 `customTransition` 的重新对齐） | 子页全绿 |
| **第 3 批** | 验证 Tab 页方案（问题 1），先做 1 个页 | 出结论 + 样板 |
| **第 4 批** | 四个 Tab 页全量迁移 | 全站统一 |
| **第 5 批** | 清理死代码：`GlassTopBar` / `HeaderBarMaterial` 的 `HeaderBarMaterialModifier` / 各页 `calcReveal` + `reveal` + `barHeight` 让位逻辑（**只删确认无引用的**，删完 `grep` 复核） | 收尾 |

---

## 六、硬约束与已知坑（**每条都踩过，不许违反**）

1. **HDS 只能在 `.ets` 文件里 import**。`.ts` 里 import 报 `10311005`。若某工具文件需要 HDS 类型，
   必须把这个文件改成 `.ets`（导入路径不用改）。
2. **链式属性优先级高于 `attributeModifier`**：挂了 `attributeModifier` 的 `Row` 上**不要**再链
   `.backgroundColor()` / `.backgroundEffect()`，会覆盖掉修饰器里的材质。
3. **系统材质需要 `module.json5` 的 UIMaterial 开关**（已开）。缺失时静默失效。
4. **新建的、没被任何入口引用的 `.ets` 文件不会被真实编译** —— 拿它当「API 可用性探针」会拿到
   **假的 BUILD SUCCESSFUL**。要验证 API 必须把它接进真实引用链，或直接改真文件。
5. **`@Prop` / 普通成员陷阱**：自定义组件的普通成员只在创建时初始化一次；从父组件喂进来且会变的值
   必须用 `@Prop`。函数类型参数**不能**做状态变量。
6. **`ListItem` 里只能有一个直接子组件**（多一个 `}` 会导致后续无关 `ListItem` 报错，报错行号会骗人）。
7. **`@Watch` 只在值真的变化时触发**；把状态写回同一个值不会触发收尾逻辑。
8. **不用 `expandSafeArea`**：全工程约定状态栏避让靠 `AppStorage` 的
   `STORE_SAFE_TOP` / `STORE_SAFE_BOTTOM` + 各页自己 padding（顶部避让下放到页面的固定栏，
   让材质从 y=0 铺起覆盖状态栏）。迁移到 HDS 标题栏后，需要重新确认这套避让怎么走
   （`avoidLayoutSafeArea` / `enableComponentSafeArea` 是否接管）。
9. **`PlayerPage` 顶栏不动**（全屏播放页自绘）。`PlayBar` / `QueueSheet` / 播放页全家桶**不动**。
10. **资源名写错会在编译期报 `Unknown resource name 'xxx'`**（不会静默）；
    符号表在 `sdk/default/openharmony/ets/build-tools/ets-loader/sysResource.js`（**不是** hms 那份）。
11. **颜色一律走 `$r('app.color.xxx')` 语义 token**；文字灰阶只用三档
    （`text_primary #1A1A1A` / `text_secondary #6B6B70` / `text_tertiary #8A8A90`），
    字阶只用 24/20/18/16/13/11，禁用 12/14/15。品牌粉 `#FB7299` 只用于大字号（≥18px）/ 图标 / 实底。
12. **可点元素命中区必须 ≥ 44vp 且要有按压态**。

### 编译方法（PowerShell）

```powershell
cd E:\BiliMusic\HarmonyOS-Phone
$env:CODEBUDDY_SAFE_DELETE_BULK_STATE_DIR = ""    # ← 必须，否则 safe-delete 守卫自锁报 00308018
$env:PATH = "<DevEco>\jbr\bin;<托管 node 目录>;" + $env:PATH
$env:DEVECO_SDK_HOME = "E:/Program Files/Huawei/DevEco Studio/sdk"
node "<DevEco>\tools\hvigor\bin\hvigorw.js" assembleHap --mode module -p product=default --no-daemon
```

- **改文件后先 `touch`**（hvigor 有增量缓存，只改内容可能被整体跳过 `CompileArkTS`）。
- **真正的错误在 `.hvigor/outputs/build-logs/build.log`，不在 stdout**。stdout 只有一句
  `Failed :entry:default@CompileArkTS`。查法：
  `grep -aE "COMPILE RESULT|Error Message|BUILD SUCCESSFUL|BUILD FAILED" .hvigor/outputs/build-logs/build.log | tail`
  （该 log 是**累积**的，注意时间戳，别把上一次的旧错误当新错）。
- **判据**：`BUILD SUCCESSFUL` + `ArkTS ERROR` 为 0。

---

## 七、验收标准

1. `BUILD SUCCESSFUL`，ArkTS ERROR = 0。
2. **真机**（`hdc list targets` 有设备时）逐页确认：
   - 顶栏内容与改造前**视觉一致**（返回键位置、标题字号字重、按钮文案与位置、第二行控件）；
   - 列表上滑时顶栏出现**模糊 + 层次**（不是纯色块、不是全透明）；
   - 顶栏材质与底部悬浮胶囊胶囊**观感统一**（同一套材质档位）；
   - 顶栏不遮挡内容、内容不被状态栏压住；
   - 下拉刷新、`bindSheet`、`Refresh` 等交互不受影响；
   - 侧滑返回、`customTransition` 转场动画不退化。
3. **无设备时**必须明确声明「未真机验证」，并给出**症状反推 + 参考工程结构对照 + 可检索日志**
   （加 `console.info` 打点，如 `[TopBar] route=xxx material=immersive|fallback`）。
4. 不留双套顶栏（HDS 标题栏 + 旧的 `GlassTopBar` 同时渲染 = 顶栏叠顶栏）。

---

## 八、红线（不许做的事）

- ❌ 不动 `PlayerPage` / `components/player/*` / `PlayBar` / `QueueSheet`。
- ❌ 不删 `GlassTopBar` / `HeaderBarMaterial`，直到**全部页面迁移完并真机确认**。
- ❌ 不为了「编译通过」把 `systemMaterialEffect` 删掉 —— 那样等于回到纯色顶栏。
- ❌ 不改 `module.json5` 的 UIMaterial 开关、不改包名、不动签名配置。
- ❌ 不一次性全量改 12 个页面 —— 必须分批，每批编译 + 确认。
- ❌ 不写死颜色 / 字号（走 token 与既有字阶）。

---

## 九、需要先验证、必须由 AI 明确回答的未知项

1. `HdsNavigation` 能否**完全平替**根 `Navigation`（`.hideTitleBar(true)` / `.mode(NavigationMode.Stack)` /
   `.navDestination(this.pageMap)` / `NavStackHolder.stack` 复用）？若某个方法不支持，替代写法是什么？
2. `HdsNavDestination.customTransition` 的 `NavDestinationTransitionDelegate` **真实签名**是什么？
   现有 `navTransitionDelegate(op: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined`
   需要怎么改？
3. `HdsNavigation.titleBar` 的**布局语义**：它是否占据布局空间（内容自动落在下方），
   还是覆盖式（内容需要自己让位）？`avoidLayoutSafeArea` / `enableComponentSafeArea` 各自的实际效果？
4. 顶栏材质在不支持 IMMERSIVE 的设备上，表现为**纯色**还是**半透明**？
   `BlurStrategy.ADAPTIVE` 会不会让材质时有时无？
5. `bindToScrollable` 能否**动态**替换 scroller（决定 Tab 页方案 B 是否可行）？
6. `HdsNavigation` 标题栏的**默认高度**是多少？与现有 `NAV_TITLE_BAR_HEIGHT = 56vp`
   （`utils/NavTitleStyle.ets`）如何对齐？
7. 是否有 HDS 官方示例工程 / 文档可对照？（可查 DevEco 自带 sample 或官方文档）

---

## 十、汇报格式要求

每批完成后按这个格式汇报：

```
批次：第 N 批
改动文件：（逐个列路径 + 一句话说明改了什么）
编译结果：BUILD SUCCESSFUL / FAILED（ArkTS ERROR = N）
真机验证：已验证 / 未验证（说明原因）
视觉差异：与改造前逐项对比（顶栏高度 / 标题位置 / 模糊强度 / 按钮位置）
未知项答疑：回答第九节里本轮涉及的条目
下一步：……
```

**最重要的一条**：先读代码和 SDK 类型定义，再给方案；任何「某能力不存在 / 不支持」的结论，
都必须落到具体类型定义或实测结果上，不能凭印象下判断。
