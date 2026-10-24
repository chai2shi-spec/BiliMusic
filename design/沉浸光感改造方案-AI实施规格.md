# 沉浸光感改造方案 · AI 实施规格

> **文档定位**：把「顶部导航栏的沉浸光感」从现状收敛成一套可验收的规则。
> 本文是**规格**，不含任何已落地的代码修改。第 10 节是一段可直接粘贴给 AI 的自包含 prompt。
>
> **真相来源**（改之前按顺序读，别跳）：
> 1. `entry/src/main/ets/utils/HdsTitleBarStyle.ets` —— 顶部页面级材质唯一出口
> 2. `entry/src/main/ets/pages/Index.ets:990 barFloatingStyle()` —— 底部胶囊唯一出口
> 3. `entry/src/main/ets/utils/MaterialCompat.ets` —— 能力探测与版本门控唯一出口
> 4. `entry/src/main/ets/utils/HeaderBarMaterial.ets` —— 元素级材质（`uiMaterial` 通路）
> 5. SDK：`sdk/default/hms/ets/api/@hms.hds.hdsBaseComponent.d.ets`
> 6. 参考实现：`C:/Users/Administrator/Desktop/zhihu-plus-plus-HMOS-HMOSv0.5.9`（纯 HDS 路线，API 23 兼容）
>
> **一句话结论**：顶部和底部观感不一样，不是因为某个参数写错了，而是因为**顶部走了三条不同的材质通路、底部只有一条**；其中「主题色光晕」在顶栏整条上**结构性不可能实现**（SDK 缺失字段），只能在元素级载体上补。

---

## 1. 事实基线（全部经代码核对，行号即证据）

### 1.1 顶部：三条通路并存

| 层 | 文件:行 | 实现 | 关键参数 | 覆盖范围 |
|---|---|---|---|---|
| **A. 页面级（HDS）** | `utils/HdsTitleBarStyle.ets:124 styleOptions()` | HDS `titleBar({style})` 滚动渐变模糊 + 材质 | `materialType=ADAPTIVE`、`materialLevel=GENTLE`、`GRADIENT_BLUR`、`0→20vp`、`maskExtraHeight=32`、`blurRadius=20`、`blurStrategy=ENABLE`、`thermoCtrl=false` | 根栏 + 10 个子页（13 个 `styleOptions()` 调用点） |
| **B. 元素级（uiMaterial）** | `utils/HeaderBarMaterial.ets:76/152/113` | `ButtonMaterialModifier` / `SearchMaterialModifier` / `TextInputMaterialModifier` → `.systemMaterial(ImmersiveMaterial)` | `style=THIN`、`interactive=true`、`lightEffect=true`（**白高光**，不可换色）、`sdkApiVersion≥26` 门控 | 13 个调用点（按钮 11 + 搜索框 1 + 输入框 1） |
| **C. 元素级（自绘模糊）** | `utils/HeaderBarMaterial.ets:45 HeaderBarMaterialModifier` | 普通 `Row` 挂 `backgroundEffect` | `radius=40`、`saturation=1.3`、`color=header_glass_tint(#70FFFFFF)` | **零调用点（已是死代码）** |

### 1.2 底部：一条通路

| 层 | 文件:行 | 实现 | 关键参数 |
|---|---|---|---|
| 底部胶囊 | `pages/Index.ets:990 barFloatingStyle()` | `HdsTabs.barFloatingStyle` | `materialType=IMMERSIVE`、`materialLevel=EXQUISITE/ADAPTIVE`（由 `useExquisiteMaterial` 决定）、`lightColor=themePrimary×0.12`、`enableMiniBarBackground=true` |
| 二级页播放栏 | `components/SubPagePlayBar.ets:210` | 二号 `HdsTabs` miniBar | 同上，参数逐字对齐 |

`useExquisiteMaterial = MaterialCompat.supportsImmersiveMaterial()`（`Index.ets:763`），即 `getSystemMaterialTypes().includes(MaterialType.IMMERSIVE)`。

### 1.3 能力探测

`MaterialCompat` 里同时存在**两套互不相干**的判定，这是混乱的源头之一：

- `supportsImmersiveMaterial()` → HDS 路径用（`getSystemMaterialTypes()`，6.1.0(23) 起可用）
- `hasImmersiveMaterial()` / `immersiveMaterial()` → `uiMaterial` 路径用（`sdkApiVersion≥26` + `isImmersiveMaterialSupported()` + `typeof ImmersiveStyle !== 'undefined'` 三重守卫）

---

## 2. 差异诊断：为什么看起来不一样

五条差异，按「能不能用改参数解决」分三类。

### 2.1 可解（参数维度，1 处改动）

| # | 维度 | 顶部 | 底部 | 观感后果 |
|---|---|---|---|---|
| ① | `materialType` | `ADAPTIVE`（跟随系统策略选材质） | `IMMERSIVE`（强制沉浸） | 顶部可能被系统解析成非沉浸材质，甚至清空 |
| ② | `materialLevel` | `GENTLE`（最便宜具名档） | `EXQUISITE`（支持时）/ `ADAPTIVE` | 玻璃厚薄差两档：顶部薄、底部厚 |

这两条是「同一套材质、不同参数」，改了就一致。

### 2.2 不可解（SDK 边界，改参数永远做不到）

| # | 维度 | 证据 | 结论 |
|---|---|---|---|
| ③ | **主题色光晕 `lightColor`** | `SystemMaterialParams`（`@hms.hds.hdsBaseComponent.d.ets:1369-1390`）**只有** `materialType` + `materialLevel` 两个字段；`HdsTabsFloatingStyle` 才有 `lightColor` | **顶栏整条永远不可能有主题色光晕**。要在顶部补光晕，只能在元素级放一个 `HdsTabs` 画布（`HdsTabsFloatingStyle.lightColor` 可用） |

> 旁证：知乎++ 的做法也是「顶栏整条不做光晕，返回键胶囊用 `lightColor: Color.White`，主题色光晕只给底栏」。也就是说**顶部白高光、底部主题色**是业界实现的常态，不必强求一致。

### 2.3 设计取向（需要产品决策，不是 bug）

| # | 维度 | 顶部 | 底部 | 后果 |
|---|---|---|---|---|
| ④ | 滚动背板 | `maskExtraHeight=32` + `blurRadius=20` → 滚动时整条渐变糊化 | 无滚动背板，纯悬空玻璃 | 顶部"毛玻璃"、底部"透亮玻璃"，这是最直观的观感差异 |
| ⑤ | 载体 | 元素是 `Button` / `Search` 各自挂材质（API 26 才有） | 整条胶囊本身就是材质载体 | API 23 上顶部 13 个控件**全部无玻璃**（修饰器 no-op，回落实色），底部照常有 |

---

## 3. 目标态：三级材质分层

对齐知乎++ 的分层模型，把顶部的三条通路收敛成三层，**每层只允许一个实现**。

```
┌─ 第 1 层 页面级 ──────────────────────────────────────┐
│  载体：HdsNavigation / HdsNavDestination 的 titleBar    │
│  API ：TitleBarStyleOptions.systemMaterialEffect       │
│       + scrollEffectOpts                               │
│  职责：整条顶栏的材质底 + 滚动联动模糊                  │
│  唯一出口：utils/HdsTitleBarStyle.styleOptions()        │
│  不可做：光晕（SDK 无字段）                             │
├─ 第 2 层 元素级（可选）────────────────────────────────┤
│  载体：空 HdsTabs 画布（barPosition End）               │
│  API ：HdsTabsFloatingStyle.systemMaterialEffect        │
│       + lightColor                                     │
│  职责：给单个控件垫玻璃 + 补光晕                        │
│  何时需要：① API 23 也要玻璃 ② 顶部要主题色光晕         │
│  现状：未实现（顶部按钮走 uiMaterial，23 上无玻璃）     │
├─ 第 3 层 兜底层 ──────────────────────────────────────┤
│  载体：任意自绘容器                                     │
│  API ：backgroundEffect / backgroundBlurStyle           │
│  职责：能力不支持时的可读性保底                         │
│  现状：HeaderBarMaterialModifier（radius 40）已无调用点 │
└───────────────────────────────────────────────────────┘
```

**分层铁律**：同一块区域不允许两层同时生效。第 1 层挂了材质，第 2 层只能在它**内部**做元素级补丁；第 3 层只在前两层不可用时启用。

---

## 4. 参数定版表

改完之后的唯一正确值。任何新代码照此取值，不再出现字面量。

### 4.1 页面级（`HdsTitleBarStyle`）

| 参数 | 现值 | 目标值 | 理由 |
|---|---|---|---|
| `materialType` | `ADAPTIVE` | **`IMMERSIVE`** | 与底部同源，强制沉浸材质，不被系统策略降到非沉浸 |
| `materialLevel` | `GENTLE` | **`EXQUISITE` / `ADAPTIVE`**（复用 `useExquisiteMaterial` 判定） | 与底部同一表达式求值，保证厚薄一致 |
| `scrollEffectType` | `GRADIENT_BLUR` | **`IMMERSIVE_GRADIENT_BLUR`**（试做，需 A/B） | 知乎++ 在 API 26 验证过的"沉浸渐变"，观感更接近底部悬浮玻璃；`GRADIENT_BLUR` 是"毛玻璃"，语义本就不同 |
| `blurEffectiveStart/End` | `0 / 20` | **`0 / 10`**（配合上一条） | 知乎++ 用 0→10；区间更短，快滑断层更少 |
| `maskExtraHeight` | `32` | `32` 保留（`IMMERSIVE_GRADIENT_BLUR` 下不生效） | 无风险 |
| `blurRadius` | `20` | `20` 保留 | 无风险 |
| `blurStrategy` | `ENABLE` | `ENABLE` 保留 | FAQ faqs-arkui-1095：部分设备默认 ADAPTIVE 下不渲染动态模糊 |
| `thermoCtrl` | `false` | `false` 保留 | 置 true = 主动申请"发热降级"，是连续播放后材质消失的隐性来源 |
| `originalStyle` / `scrollEffectStyle` 底色 | 全透明 | 全透明保留 | 让材质层透出，底色会盖死玻璃 |

### 4.2 元素级（未来若实现画布）

| 参数 | 值 | 来源 |
|---|---|---|
| 组件形态 | `HdsTabs({ barPosition: BarPosition.End }) {}`（空） | 知乎++ `MaterialCanvas` |
| 尺寸 | 组件级 `width/height` **且** `barWidth` 三档（small/medium/large）+ `barHeight` 全部显式同值 | 缺任一档会塌成"玻璃细棍"（真机实测） |
| 交互 | `hitTestBehavior(HitTestMode.None)` + `clip(false)` + `backgroundColor(Color.Transparent)` | 只画不吃事件 |
| `lightColor` | `MaterialCompat.withAlpha(themePrimary, GLOW_ALPHA)` | 与底部同源，`GLOW_ALPHA=0.12`（`common/Constants.ts:92`） |
| `systemMaterialEffect` | `{ materialType: IMMERSIVE, materialLevel: 同底部 }` | 与底部同源 |
| `thermoCtrl` | `false` | 与工程既有结论一致（知乎++ 用 true，此处刻意不同） |
| `gradientMask` | 显式 `{ maskColor: '#00000000', maskHeight: 1 }` | 防默认遮罩回退成"组件高 + 32vp"的灰块（PiliPlus 实测坑）；**待真机验证** |
| 画布宽 | 内容宽 + 48，外层 `borderRadius` + `clip(true)` 裁成胶囊 | HDS 悬浮 bar 内部右侧有预留，按内容宽画会"包裹不完全" |

### 4.3 兜底层

| 参数 | 值 |
|---|---|
| `backgroundEffect` | `radius=40`、`saturation=1.3`、`brightness=1.0`、`color=$r('app.color.header_glass_tint')` |
| 异常回落 | `backgroundColor($r('app.color.bg_page'))` |

---

## 5. 分阶段实施

每阶段独立可编译、可回退、可单独验收。**不要合并做**。

### P0 · 抽取材质令牌（零观感风险）

**做什么**：新建 `common/style/MaterialTokens.ets`，把散落在 4 个文件里的材质参数收成常量，各处改为引用。

要收的常量：

| 常量 | 值 | 现散落位置 |
|---|---|---|
| `TITLE_MATERIAL_TYPE` / `BAR_MATERIAL_TYPE` | `IMMERSIVE`（P1 后） | `HdsTitleBarStyle.ets:161`、`Index.ets:1051`、`SubPagePlayBar.ets` |
| `MATERIAL_LEVEL` | 统一表达式 | 同上三处 |
| `GLOW_ALPHA` | `0.12`（已存在） | `Constants.ts:92` |
| `TITLE_BLUR_START_VP` / `TITLE_BLUR_END_VP` | `0` / `10` | `HdsTitleBarStyle.ets:133-134` |
| `TITLE_MASK_EXTRA_VP` / `TITLE_BLUR_RADIUS_VP` | `32` / `20` | `HdsTitleBarStyle.ets:174/177` |
| `FROST_RADIUS` | `40` | `HeaderBarMaterial.ets:50` |

**为什么先做**：现在改一个观感参数要同步 3 个文件，且三处已经出现不一致（`ADAPTIVE` vs `IMMERSIVE`）。不收成一处，P1 之后还会漂移。

**验收**：`CompileArkTS` 真执行 + 0 `ArkTS ERROR` + `BUILD SUCCESSFUL`；真机截图与改前**逐像素无差异**（本阶段唯一判据就是"什么都没变"）。

**回退**：纯重构，git revert 即可。

---

### P1 · 顶部材质档位对齐底部（唯一改观感的动作）

**做什么**：`HdsTitleBarStyle.styleOptions()` 内两处：

1. `materialType: hdsMaterial.MaterialType.ADAPTIVE` → `IMMERSIVE`
2. `materialLevel: GENTLE` → 与底部同一表达式：`MaterialCompat.supportsImmersiveMaterial() ? EXQUISITE : ADAPTIVE`

**为什么**：这是 2.1 节的两条差异，也是唯一"改参数就能让观感一致"的部分。

**P1-0 前置对照实验（必须先做，别跳）**

知乎++ 在 API 26 真机上记录过一条：**手动挡（生效挡位非 ADAPTIVE）+ 滚动模糊未激活的原始态 → 标题栏按钮区材质高光被渲染成黑色圆**，滚动激活后与 ADAPTIVE 挡均正常，且 `SystemMaterialParams` 没有颜色参数可控。

BiliMusic 当前用的 `GENTLE` 同样属于"手动挡"，理论上应该已经命中这个 bug。但 BiliMusic 的 `originalStyle` / `scrollEffectStyle` 底色全透明，可能刚好绕开了。**改之前先做一次判定**：

| 观察 | 结论 |
|---|---|
| 滚动到顶（未激活模糊）时返回键没有黑圆 | 当前透明背板已规避，P1 可以放心改 |
| 有黑圆 | 说明该 bug 在 BiliMusic 已存在，P1 不会加重，但需在 P2 一并处理（用元素级画布给返回键垫白底） |

判据来源：真机截图，顶部未滚动状态，检查二级页返回键（`AboutPage` / `FollowsPage` 这类有 `NavTitleRow` 的页面）。

**验收**：同一帧截图里，顶部顶栏与底部胶囊的玻璃厚薄肉眼接近；`hilog -T JSAPP | grep TopBar` 输出 `level=EXQUISITE`（或 `ADAPTIVE`）而非 `GENTLE`；快滑不闪；返回键无黑圆。

**回退**：`materialType=ADAPTIVE` + `materialLevel=GENTLE`（旧值已录在 `HdsTitleBarStyle.ets` 类头简史 ⑥）。

**风险**：极端低配设备上 `EXQUISITE` 可能发热。缓解：判定表达式与底部共用，底部没问题的设备顶部也不会有问题。

---

### P2 · 滚动效果类型 A/B（改观感，需产品决策）

**做什么**：`scrollEffectType` 从 `GRADIENT_BLUR` 换 `IMMERSIVE_GRADIENT_BLUR`，模糊区间 `0→20` 收 `0→10`。

**为什么**：这是 2.3 节的第 ④ 条（顶部"毛玻璃" vs 底部"透亮玻璃"）的根源。`GRADIENT_BLUR` 本质是"渐变毛玻璃"，`IMMERSIVE_GRADIENT_BLUR` 是"沉浸渐变"，后者与悬浮玻璃胶囊的语言更接近。

**前置条件**：`IMMERSIVE_GRADIENT_BLUR` 需 6.1.0(23)+。本工程 `compatibleSdkVersion` 需确认 ≥ 23 —— 若是，低版本回退 `GRADIENT_BLUR` 用 `typeof` 守卫。

**验收**：同一滚动位置（滚过 10vp / 40vp / 100vp 三点）截图对照，顶部背板从"整条糊"变成"渐隐过渡"；文字在任意滚动位置可读（对比度不靠猜）。

**回退**：`GRADIENT_BLUR` + `0→20`。

**⚠️ 与既有结论冲突提醒**：类头简史 ① 记录过"`GRADIENT_BLUR` 快滑时渐变遮罩 pass 被系统丢弃 → 毛玻璃闪一下消失"。若 P2 复现该症状，直接回退，不要试图用叠加第二层模糊去修（见禁忌 8）。

---

### P3 · 三条通路归一（清理，非观感）

**做什么**，按调用点数量排序：

| 项 | 现状 | 动作 |
|---|---|---|
| `makeHeaderBarModifier()` | **0 调用点**（死代码） | 删除 `HeaderBarMaterialModifier` 类与工厂；注释里保留一句"已随 HdsNavigation 迁移退役" |
| `makeTextInputMaterialModifier()` | 1 调用点 | 保留，但补注释：API 23 上 no-op，控件回落实色 |
| `makeSearchMaterialModifier()` | 1 调用点（首页搜索框） | 同上 |
| `makeButtonMaterialModifier()` | 11 调用点 | 同上 |

**为什么**：13 个控件在 API 23 设备上**完全没有玻璃**（修饰器 `return`），这是 2.3 节第 ⑤ 条的实际影响面。归一是为了让它变成**显式的已知降级**，而不是"忘了做"。

**验收**：`grep -c "makeHeaderBarModifier"` 为 0 且编译通过；`HeaderBarMaterial.ets` 类头注释与实际调用点数量一致。

**回退**：无风险（纯删除 + 注释）。

---

### P4 · 元素级玻璃画布（可选，仅当决定"API 23 也要玻璃"时做）

**做什么**：新建 `components/GlassCanvas.ets`，实现 4.2 节参数表；在需要玻璃的元素下垫一层。

**只在以下两种情况下做**：

1. 产品要求 API 23 设备的顶部按钮也有玻璃
2. 产品要求顶部也有主题色光晕（2.2 节的结构性缺口）

**不做的话**，在 `HeaderBarMaterial.ets` 类头写清：**"顶部元素级玻璃为 API 26 专属能力；API 23 设备顶部按钮为实色，属已知且接受的降级"**。

**验收**：API 23 模拟器上按钮有玻璃；`GlassCanvas` 不塌成细棍；点击事件穿透正常（`hitTestBehavior(None)` 生效，点按钮能触发）；`lightColor` 光晕在浅色内容上可见。

**风险**：知乎++ 的注释明确写这条通路是为了**规避** `uiMaterial.systemMaterial` 的"白底遮挡问题"——说明他们先踩了坑再换方案。BiliMusic 目前在 API 26 上 `uiMaterial` 工作正常，**没有必须换的理由**。所以本阶段优先级最低。

---

## 6. 八条禁忌（每条都会让功能静默失效）

1. **不要把 `MaterialLevel.ADAPTIVE` 当"默认值"随手用**。它是 `=10`，语义是"跟随系统策略"，中低端机会被策略自动降级清空材质（"闪一下没了"）。要"最便宜但确定"用 `GENTLE`，要"跟随系统"就明确知道风险。
2. **`EXQUISITE = 0`**。不能用真值判断枚举（`if (level)` 会把最贵档当成 false）。
3. **`titleBar({style})` 是受控样式，按对象引用判等**。每次调用都 `new` 一个 `TitleBarStyleOptions` → 任意状态变化都让 HDS 销毁重建材质层 → 一帧空白。必须缓存（现用 `Map<内容键, 对象>`，键含模糊区间与是否沉浸档）。
4. **`SystemMaterialParams` 没有颜色字段**（只有 `materialType` / `materialLevel`）。顶栏整条的光晕调不出来，别浪费时间。
5. **`HdsNavigationBackgroundStyle` 只有 `backgroundColor` / `maskExtraHeight` / `blurRadius`**，**没有** `backgroundBlurStyle`。想给标题栏底色加模糊只能靠 `scrollEffectType`。
6. **`uiMaterial` 必须 `import lazy`**，且 `.systemMaterial()` 只对自绘组件在特定作用域生效（Navigation / NavDestination 标题栏、或 `barPosition End` 的横向 TabBar），其他区域**静默不渲染**。API 23/24 上静态 import 会在模块加载期崩溃。
7. **空 `HdsTabs` 画布必须显式给三档 `barWidth` + 组件级 `width/height`**，否则塌成"玻璃细棍"。
8. **不要在 titleBar 上再叠 `backgroundBlurStyle` / `linearGradientBlur` / `backgroundEffect`**。与 HDS 内置渐变模糊管线冲突，快滑时闪烁（这是 2026-10-22 那轮排查的直接结论）。

---

## 7. 验收标准

每个阶段都必须过完四关。

### 7.1 编译关（不跑不算完）

```text
cd /e/BiliMusic/HarmonyOS-Phone
touch <每一个改动过的源文件>    # hvigor 有增量缓存，不 touch 会整体跳过 CompileArkTS
node "<DevEco>/tools/hvigor/bin/hvigorw.js" assembleHap --mode module -p product=default --no-daemon
```

判据三件套：
- `CompileArkTS` **真执行**（日志有 `is not up-to-date` + cost 十秒级）
- `ArkTS:ERROR` 计数为 **0**
- `BUILD SUCCESSFUL`

⚠️ 真正的编译错误在 `.hvigor/outputs/build-logs/build.log`，不在 stdout。该 log 累积，先截出本次再 grep。

### 7.2 日志关

```text
hdc shell hilog -r
hdc shell aa force-stop com.chai.bilimusic
hdc shell aa start -a EntryAbility -b com.chai.bilimusic
hdc shell "hilog -x -T JSAPP" | grep TopBar
```

必须看到且只看到 1 条（缓存生效的证据）：

```text
[TopBar] material=immersive materialType=IMMERSIVE ... level=EXQUISITE ... thermoCtrl=false
```

`materialType=ADAPTIVE` 或 `level=GENTLE` = P1 没生效。

### 7.3 截图关（顶部/底部必须同帧）

要证明"两处观感一致"，必须让**同一帧里同时出现**滚动穿透的顶栏与底部胶囊。做法：滚到列表中部（内容穿过顶栏），一次截图裁上下两段。

### 7.4 人眼关（静态截图证不了的三件事）

- **快滑是否闪烁**：需要连续滑动，截图无效
- **返回键有无黑圆**：滚动到顶 + 未触发模糊的原始态
- **文字可读性**：浅色封面图穿透顶栏时，标题是否还看得清

---

## 8. 回退预案

| 阶段 | 回退值 | 记录位置 |
|---|---|---|
| P1 | `materialType=ADAPTIVE`、`materialLevel=GENTLE` | `HdsTitleBarStyle.ets` 类头简史 ⑥ |
| P2 | `scrollEffectType=GRADIENT_BLUR`、`0→20` | 同上简史 ⑥ |
| P4 | 全部 `Modifier` 原样保留，`GlassCanvas` 不接入即等于没做 | — |

**回退原则**：只回退参数，不回退结构。P0 抽的令牌保留，把值改回去即可。

---

## 9. 明确不做

- 不改底部胶囊的任何参数（`Index.barFloatingStyle` 与 `SubPagePlayBar`）—— 这是用户明确保护的区域
- 不改播放页全家桶（`pages/PlayerPage.ets` + `components/player/*`）
- 不新增设置项做"四挡材质"（知乎++ 有，但那是产品需求，不在本次范围）
- 不引入 `uiMaterial` 的新用法（现有 13 处够用，新增只会扩大 API 26 依赖面）
- 不改 `module.json5` 的 `ohos.arkui.UIMaterial.state`（已开 `enable`；知乎++ 没开也能渲染，说明这行只对 `uiMaterial` 通路生效，不是 HDS 通路的前提）

---

## 10. 可直接粘贴给 AI 的 Prompt

```text
# 项目
HarmonyOS 音乐播放器，原生 ArkTS + ArkUI，工程根 E:/BiliMusic/HarmonyOS-Phone
（注意不是 E:/BiliMusic，父目录打开 DevEco 会报"没有项目"）。
HarmonyOS 7 / API 26，bundleName com.chai.bilimusic。

# 任务
统一「顶部导航栏」与「底部胶囊」的沉浸光感观感。只做下面 P0、P1 两个阶段，
做完停下等我验收，不要顺手做 P2/P3/P4。

# 先读这些（按顺序，别跳）
1. .workbuddy/memory/MEMORY.md —— 主铁律 + 分册指针
2. .workbuddy/memory/UI-LAYOUT.md —— 「底栏 / 迷你条」小节的材质四项参数表（顶部现状见本文第 1 节）
3. design/沉浸光感改造方案-AI实施规格.md —— 本次任务的完整规格（事实基线在第 1 节）
4. entry/src/main/ets/utils/HdsTitleBarStyle.ets —— 顶部材质唯一出口
5. entry/src/main/ets/pages/Index.ets 第 990 行 barFloatingStyle() —— 底部材质唯一出口
6. entry/src/main/ets/utils/MaterialCompat.ets —— 能力探测唯一出口

# P0：抽取材质令牌（零观感变化）
新建 common/style/MaterialTokens.ets，把散落在 HdsTitleBarStyle.ets /
Index.ets / SubPagePlayBar.ets / HeaderBarMaterial.ets 里的材质参数收成常量，
各处改为引用。本次不改任何值 —— 验收判据就是「真机截图与改前逐像素一致」。

# P1：顶部档位对齐底部
在 HdsTitleBarStyle.styleOptions() 内改两处：
  materialType: hdsMaterial.MaterialType.ADAPTIVE  ->  hdsMaterial.MaterialType.IMMERSIVE
  materialLevel: hdsMaterial.MaterialLevel.GENTLE ->  MaterialCompat.supportsImmersiveMaterial()
                                                     ? EXQUISITE : ADAPTIVE
（与 Index.ets 的 useExquisiteMaterial 同一表达式，保证厚薄同源）

# 绝对不许动
- pages/PlayerPage.ets 及 components/player/*（播放页全家桶）
- components/PlayBar.ets、components/QueueSheet.ets
- pages/Index.ets:990 barFloatingStyle() 的六个输入（安全区 / 材质档 / 主题色 /
  布局 / 是否带 miniBar / 展开态）
- components/SubPagePlayBar.ets 的材质参数

# 八条硬禁忌（犯了会静默失效，不报错）
1. 不把 MaterialLevel.ADAPTIVE 当默认值随手用（=10，会被系统策略降级清空材质）
2. EXQUISITE = 0，不能用真值判断枚举
3. titleBar({style}) 按对象引用判等，必须走已有的 Map 内容键缓存，不许每次 new
4. SystemMaterialParams 只有 materialType + materialLevel，没有颜色字段 —— 顶栏整条做不出光晕
5. HdsNavigationBackgroundStyle 只有 backgroundColor / maskExtraHeight / blurRadius
6. uiMaterial 必须 import lazy；systemMaterial() 超出作用域静默不渲染
7. 空 HdsTabs 画布必须显式给三档 barWidth，否则塌成玻璃细棍
8. 不要在 titleBar 上再叠 backgroundBlurStyle / linearGradientBlur / backgroundEffect

# 编译验收（必须，不跑不算完）
cd /e/BiliMusic/HarmonyOS-Phone
touch <每个改动过的文件>   # hvigor 增量缓存，不 touch 会整体跳过 CompileArkTS
node "<DevEco>/tools/hvigor/bin/hvigorw.js" assembleHap --mode module -p product=default --no-daemon
判据 = CompileArkTS 真执行（is not up-to-date + cost 十秒级）+ ArkTS:ERROR 0 + BUILD SUCCESSFUL
⚠️ 真错误在 .hvigor/outputs/build-logs/build.log，不在 stdout

# 真机验收
hdc 目标 192.168.0.5:41717
hdc shell hilog -r
hdc shell aa force-stop com.chai.bilimusic && hdc shell aa start -a EntryAbility -b com.chai.bilimusic
hdc shell "hilog -x -T JSAPP" | grep TopBar
必须只出现 1 条，且 materialType=IMMERSIVE、level 不再是 GENTLE。

# 汇报要求
明确说清：改了哪几个文件、编译是否真执行、日志实际输出原文、哪些项你没能验证。
不许出现「已优化」「应该没问题」这类没有判据的结论。
```

---

## 附录 A：三个待决策点

| 编号 | 问题 | 选项 | 建议 |
|---|---|---|---|
| **A** | 顶部材质档位要不要跟底部完全一致，还是保留"顶部更轻"的层次感 | ① 完全一致（P1）② 顶部始终比底部低一档 | ①。不一致是本次问题的来源；层次感应由光晕/背板承担，不该由玻璃厚薄承担 |
| **B** | 滚动效果用 `GRADIENT_BLUR`（毛玻璃）还是 `IMMERSIVE_GRADIENT_BLUR`（沉浸渐变） | ① 保持 ② 换沉浸渐变 | 先 A/B 再定。② 更接近底部语言，但需验证不重现"快滑闪一下" |
| **C** | API 23 设备顶部按钮要不要玻璃 | ① 不做，写清为已知降级 ② 做元素级画布 | ①。P4 的收益（23 上的按钮玻璃）远小于成本（13 处接入 + 新承载层） |

---

## 附录 B：本文引用的关键 SDK 证据

| 结论 | 文件 | 位置 |
|---|---|---|
| `SystemMaterialParams` 只有两个字段 | `sdk/default/hms/ets/api/@hms.hds.hdsBaseComponent.d.ets` | 1369–1390 |
| `HdsNavigationBackgroundStyle` 只有三个字段 | 同上 | 1087 / 1098 / 1109 |
| `avoidLayoutSafeArea` 默认 false | 同上 | 2027 |
| `MaterialLevel`：`EXQUISITE=0 / GENTLE=1 / SMOOTH=2 / ADAPTIVE=10` | 同上（枚举定义） | — |
| `MaterialType`：`NONE=0 / ADAPTIVE=100 / IMMERSIVE=101` | 同上 | — |
| `ScrollEffectType`：`COMMON_BLUR=0 / GRADUAL_BLUR=1 / GRADIENT_BLUR=2 / IMMERSIVE_GRADIENT_BLUR=3` | 同上 | — |
