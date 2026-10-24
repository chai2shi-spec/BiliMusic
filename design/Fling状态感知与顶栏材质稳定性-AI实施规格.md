# Fling 状态感知与顶栏材质稳定性 —— AI 实施规格

> 编写时间：2026-10-24 11:58
> 状态：**方案文档，代码零改动**
> 触发：对照 PiliPlus / 知乎++ 后发现两者均无 Fling 状态判定，需定「BiliMusic 要不要做、怎么做」
> 关联文档：`沉浸光感改造方案-AI实施规格.md`（材质参数收口）、`顶栏设计方案-v2.md`（顶栏结构）

---

## 0. 一句话结论

**加「Fling 状态判定」本身修不好快滑丢模糊** —— 因为本工程已经做过一次对照实验，证明丢的是整个模糊 pass，与状态判定无关。但 Fling 感知是**必需的第一步**：它是唯一能把「肉眼感觉」变成「可对齐时间线的数据」的手段，也是「Fling 期让出帧预算」这条唯一低代价路线的触发器。

真正的因果链不是「Fling → 丢模糊」，而是：

```
Fling（惯性初速 9000 vp/s）→ 单帧滚动位移极大 → 单帧合成负载超预算
  → 系统渲染管线丢弃高开销 pass（渐变模糊遮罩）
  → 松手后模糊消失；停止后恢复
```

所以要动手的地方是**帧预算**，不是模糊参数。

---

## 1. 事实基线（全部经代码核实，行号为准）

### 1.1 主链路现状

| 项 | 值 | 位置 |
|---|---|---|
| 滚动模糊类型 | `IMMERSIVE_GRADIENT_BLUR` | `common/style/MaterialTokens.ets:50` |
| 起糊 / 完糊偏移 | 0 → 20 vp | 同文件 `:31`、`:33` |
| `maskExtraHeight` | 32 vp（该类型下不生效） | `:35` |
| `blurRadius` | 20 vp | `:37` |
| 材质类型 | `IMMERSIVE` | `:27` |
| 材质档位 | `supportsImmersiveMaterial() ? EXQUISITE : ADAPTIVE` | `:58` |
| `blurStrategy` | `ENABLE`（枚举最强档） | `utils/HdsTitleBarStyle.ets:228` |
| `thermoCtrl` | `false`（不申请发热降级） | `:232` |
| 样式对象缓存 | 内容键 Map，命中即复用同一对象 | `:177`、`:206` |
| 根栏绑定 | `.bindToScrollable([this.activeTabScroller()])` | `pages/Index.ets:1647` |
| 子页绑定 | 9 个页面各自 `.bindToScrollable([...])` | `AboutPage:312`、`FavSyncPage:914`、`FollowsPage:699` 等 |

### 1.2 主链路**没有任何** Fling 感知

```
grep -rn "onWillScroll|onScrollStop|flingSpeedLimit" pages/ components/
  → 仅 pages/GradientBlurDemoPage.ets 命中，其余 0 处
```

也就是说：四个一级页 + 九个二级页的 List 上**一个滚动状态回调都没有**，滚动完全交给 HDS 内部的 `bindToScrollable`。

### 1.3 已有实验页记录的三条反向证据（关键，别重复踩）

`pages/GradientBlurDemoPage.ets` 文件头（`:1-49`）记录了 2026-10-24 的多轮真机实测：

1. **两条 HDS 渐变管线都丢**：`GRADIENT_BLUR` 与 `IMMERSIVE_GRADIENT_BLUR` **均真机复现**「拖拽在、松手丢、停下恢复」。也就是说主链路 ⑧ 那次「换类型」**没有解决问题**，只是换了条同样有缺陷的管线。
2. **内容级自绘也丢**：改用 `linearGradientBlur` 直接渲染在 List 内容上（绕开 HDS 合成通路），在**默认抛行速度下同样丢**。
3. **拖拽速度下三条路径全活**：拖拽约 2-3k vp/s 时 `GRADIENT_BLUR` / `IMMERSIVE_GRADIENT_BLUR` / `linearGradientBlur` **全部存活**。

结论（Demo 自己写下）：**触发因子是滚动速度带来的帧负载，不是具体模糊管线**。

### 1.4 同屏存在常驻每帧写入

| 位置 | 内容 | 影响 |
|---|---|---|
| `components/PlayBar.ets:293` | `Animator` `iterations: -1`、`direction: normal` | 迷你栏圆盘**无限旋转**，常驻首页/子页 |
| `components/PlayBar.ets:318` | `onframe` 每帧回写 `@State rotateAngle` | **每帧一次状态写入 + 属性更新** |
| `components/PlayBar.ets:621` | `Image.rotate({ z: 1, angle })` 跟转 | 每帧一次绘制变换 |
| `components/player/CoverDiscComponent.ets:126` | 同上，播放页封面 | 播放页同屏 |
| `PulseDotProgressBar:101/114`、`ShimmerProgressBar:95/109`、`WaveBarsProgressBar:97` | 进度条无限循环动画 | 播放页 / 迷你栏 |

`PlayBar` 是**迷你栏本体**，在首页与所有子页常驻。快滑时它与顶栏渐变模糊同屏抢帧预算，且它的每帧 `@State` 写入会触发自身子树重渲染。

---

## 2. 为什么「Fling 期切换材质/模糊参数」是错的方向

三条硬性理由，任一条成立即否决：

1. **切样式会重建材质层**。`HdsTitleBarStyle.styleOptions()` 是内容键缓存（`:177`）
对象。Fling 期若要改参数（例如把 `blurRadius` 从 20 降到 12），必然产生新缓存键 → 返回新对象 → HDS 按引用判等认为样式变了 → **销毁重建材质层**。肉眼后果比现在的一帧空白严重得多（整个顶栏闪一下）。
2. **`ScrollEffectOptions` 没有「模糊开关」粒度**。可调项只有 `enableScrollEffect` / `scrollEffectType` / 两个偏移 / `blurRadius` / `maskExtraHeight`，都在 `TitleBarStyleOptions` 层，改动即重建（理由 1）。
3. **降半径治不了丢 pass**。Demo 的 `DEMO_FLING_BLUR_RADIUS = 12`（`:75`）就是「Fling 期降上限」的完整实现，其文件头第 ④ 轮结论已明确：默认速度下仍丢。**降参数解决不了 pass 被丢弃**。

同理，**「加自绘模糊盖在 HDS 上」也是禁止项**，`HdsTitleBarStyle.ets:107-109` 已写明：叠加第二层 `backdropBlur` / `linearGradientBlur` / `backgroundBlurStyle` 与 HDS 内置管线冲突，快滑时闪烁。

---

## 3. 方案矩阵（按代价从低到高，可叠加）

| 代号 | 做法 | 观感代价 | 手感代价 | 能解决什么 | 风险 |
|---|---|---|---|---|---|
| **S0** | 旁路采样 Fling 状态（只打日志，不参与渲染） | 无 | 无 | 把问题变成可量化数据 | 几乎为零 |
| **S1** | Fling 期暂停**装饰性逐帧动画**（迷你栏圆盘、进度条流光），模糊参数一个不动 | 圆盘旋转短暂停 | 无 | 让出帧预算，**对症**（根因是帧负载） | 低，可秒回退 |
| **S2** | `flingSpeedLimit` 压惯性初速 9000 → 2500/1500 | 无 | **有**（抛行变短变缓） | Demo 唯一实测有效方向 | 中，产品取舍 |
| **S3** | 关闭 HDS 滚动模糊 + 内容级 `linearGradientBlur` 自绘 | 有（需重新调渐变形态） | 无 | 绕开 HDS 合成通路 | 高，且**必须叠加 S2**才有效 |
| **S4** | 接受现状，改成静态半透明背板，不再依赖动态模糊 | 大（放弃渐变） | 无 | 彻底规避 | 需求变更 |

**推荐路径：S0 → S1 → 视结果决定是否 S2。S3 只在 S1+S2 都不达标时考虑，且必须与 S2 同做。**

理由：S0+S1 都不改任何视觉参数、不动手感，代价最低而恰好打中「帧负载」这个真因。S3 已被 Demo 证伪（默认速度下自绘也丢），单独做等于白干。

---

## 4. S0：旁路 Fling 采样（第一步，必做）

### 4.1 目标

拿到一条能和时间对齐的日志，回答三个问题：

- Fling 到底从哪一帧开始、到哪一帧结束？
- 模糊消失的时刻是在 Fling 第一帧，还是在 Fling 中途某一帧？
- 慢速抛行（低初速）会不会不丢？

### 4.2 改动点（4 个一级页的 List）

`pages/SearchPage.ets`、`pages/PlaylistsPage.ets`、`pages/DownloadsPage.ets`、`pages/SettingsPage.ets` 各自的 List（挂 `TabScrollerHolder.*` 的那四个）。

在 List 属性链末尾追加（**只读采样，不写任何渲染状态**）：

```ts
.onWillScroll((_offset: number, state: ScrollState, _source: ScrollSource): void => {
  // 仅状态变化时打一条，避免每帧刷屏淹没 hilog 环
  if (state !== this.lastScrollState) {
    this.lastScrollState = state;
    const name: string = state === ScrollState.Fling ? 'Fling'
      : (state === ScrollState.Scroll ? 'Scroll' : 'Idle');
    // offset 用 scroller 实测值（onWillScroll 的入参是增量，非绝对偏移）
    console.info(`[FlingTrace] state=${name} y=${TabScrollerHolder.xxx.currentOffset().yOffset}`);
  }
})
```

要求：

- 每个页面加一个 `private lastScrollState: ScrollState = ScrollState.Idle;` 普通成员（**不要用 `@State`** —— 它不参与 UI 且写 `@State` 会触发重渲染，正好与「减少帧负载」的目标相反）。
- **不要**顺手加 `onDidScroll` 做别的事；不要改 `bindToScrollable`。
- 日志 tag 统一 `FlingTrace`，与既有 `[TopBar]`、`BiliMusicHttp` 区分。

### 4.3 采集方法

1. 冷启动 → `hilog -r` 清缓冲 → 进入首页
2. 用 `hdc shell uitest uiInput swipe x1 y1 x2 y2 <durationMs>` 制造**可控速度**的快滑：
   - 慢速：`swipe 660 2200 660 900 800`（800ms 拖完，初速低）
   - 快速：`swipe 660 2200 660 900 80`（80ms 拖完，初速接近上限）
3. 立刻抓 `hilog -x -T JSAPP | grep -aE "FlingTrace|TopBar"`，两者同一条时间轴
4. 同步用 `snapshot_display` 在**抛行中**截图（`swipe` 后立即截，不等结算）—— 这是唯一能证明「此刻模糊在不在」的静态证据

### 4.4 判读标准

| 日志形态 | 结论 | 下一步 |
|---|---|---|
| `state=Fling` 一出现模糊就没了 | 丢 pass 与状态同步发生 | 走 S1（降负载） |
| `state=Fling` 出现后若干帧才丢 | 是负载累积/超预算，非状态本身 | S1 必做 |
| 慢速抛行（800ms 拖）全程不丢 | 印证「速度→负载」因果 | S1 + 可能 S2 |

---

## 5. S1：Fling 期让出帧预算（推荐主路线）

### 5.1 原理

根因是帧负载（1.3 节结论）。同屏最大的常驻逐帧消耗是迷你栏圆盘的 `Animator`（1.4 节）。Fling 期它的旋转**肉眼几乎不可辨**（圆盘在快速滚动的列表里只是个小图标），暂停它换来的帧预算却直接给到模糊合成。

这条不改任何视觉参数、不改绑定的模糊管线、不动手感 —— 只做「谁在什么时候可以停」。

### 5.2 落地设计

**新增一个全局滚动状态标记**（沿用工程既有 `AppStorage` + `@StorageProp` 模式，不引入新机制）：

- 常量加到 `common/Constants.ts`：`export const STORE_SCROLL_FLING: string = 'bilimusic_scroll_fling';`
- 写入方：S0 的四个 List 回调里，**状态变化时**才写：
  ```ts
  AppStorage.setOrCreate<boolean>(STORE_SCROLL_FLING, state === ScrollState.Fling);
  ```
- 读取方：`components/PlayBar.ets` 加 `@StorageProp(STORE_SCROLL_FLING) scrollFling: boolean = false;`，配 `@Watch`。

**暂停/恢复圆盘**（`PlayBar` 内）：

- 圆盘由 `Animator` 驱动（`discOptions()` `:290`、`onframe` `:318`）。`Animator` 有 `pause()` / `play()`。Fling 进入时 `pause()`，退出时 `play()`。
- ⚠️ **不要改成 `rotateAngle = 0` 复位** —— 会造成肉眼可见的角度跳变。`pause()` 保持当前角度，`play()` 从当前继续。
- 兜底：`@Watch` 只在值真变化时触发（ArkUI 语义），所以 `onScrollStop` 之外不需要额外兜底；但要保证**页面不可见时也写回 false**，否则切页后残留 fling 态会让圆盘永久停转。做法：PlayBar 的 `onVisibleAreaChange` 或页面切页时由写入方强制置 false。

**扩展项（同一机制，按需开）**：

- `PulseDotProgressBar` / `ShimmerProgressBar` / `WaveBarsProgressBar` 的无限动画同理可暂停（`iterations: -1` 那几处）。
- 播放页 `CoverDiscComponent.ets:126` 封面旋转同理。

**第一阶段只做 `PlayBar` 圆盘**（它在首页/子页常驻，收益面最大），验证有改善再扩。

### 5.3 为什么不用 Fling 期降 `blurRadius`

见第 2 节理由 3。降 `blurRadius` 还要改 `styleOptions` → 触发重建 → 更闪。**明确不做**。

---

## 6. S2：压惯性初速（需要产品拍板）

`List.flingSpeedLimit(number)`，单位 vp/s，系统默认 9000。Demo 用 2500（`GradientBlurDemoPage.ets:88`）已验证方向。

| 值 | 抛行观感 | 备注 |
|---|---|---|
| 9000（现状） | 标准 | 模糊丢 |
| 4000 | 略短 | Demo 建议的上限试探值 |
| 2500 | 明显变短变缓 | Demo 当前值 |
| 1500 | 很短 | Demo 的兜底下限 |

**代价必须让用户知情**：这是用滚动手感换模糊稳定，不是纯收益。建议 S0+S1 之后再评估是否需要。

落地位置：四个一级页的 List 属性链（与 S0 同一处）。**不要**在子页先做 —— 子页列表短、抛行距离有限，收益小。

---

## 7. S3：内容级自绘（Demo 路线，暂不推荐）

结构如 `GradientBlurDemoPage.ets:240-288`：

```
Stack → HdsNavigation（titleBar 显式 enableScrollEffect:false，不 bindToScrollable）
      → Tabs → TabContent（clip(false)）→ List（linearGradientBlur + onWillScroll 状态机 + onScrollStop 校正）
```

**为什么暂不推荐**：

1. Demo 自证「默认速度下自绘也丢」（`:40-49`），必须叠加 S2 才有效 → 等于同时吃两个代价。
2. 观感要重新调：Demo 的 `DEMO_FRACTION_STOPS = [[1,0],[1,0.12],[0,0.24]]` 是**视口比例**空间分布，与现在 HDS 的「滚动偏移驱动」语义不同 —— 换成自绘等于换了一套视觉，需要重新设计评审。
3. 9 个子页要逐个改结构，回归面大。

若最终必须走这条，先只在**首页**做（单页验证），别一次铺开。

---

## 8. 硬约束与禁止项（违反即引入新 bug）

| # | 禁止 | 原因 |
|---|---|---|
| 1 | 在 Fling 期调用 `HdsTitleBarStyle.styleOptions()` 传不同参数 | 缓存键变化 → 新对象 → HDS 重建材质层 → 整栏闪一下 |
| 2 | 在 HDS 管线之外再叠 `backdropBlur` / `linearGradientBlur` / `backgroundBlurStyle` | 与内置管线冲突，快滑闪烁（`HdsTitleBarStyle.ets:107-109` 已记） |
| 3 | 用 `onScroll` 手动算进度替代 `bindToScrollable` | 两套信号源并存会互相干扰，且 HDS 只认绑定 |
| 4 | 把 S0 的 `lastScrollState` 写成 `@State` | 每帧触发重渲染，与「减负载」目标相反 |
| 5 | Fling 期把圆盘 `rotateAngle` 复位为 0 | 角度跳变，肉眼可见 |
| 6 | `MaterialLevel` 用真值判断 | `EXQUISITE = 0`，`if (level)` 会把最贵档当 false |
| 7 | 声称「换 `IMMERSIVE_GRADIENT_BLUR` 已修复丢 pass」 | 已被真机证伪（1.3 节），会误导后续排查 |
| 8 | 每个页签共用一个 Scroller | FAQ faqs-arkui-1095：滚动模糊互相干扰丢失（本工程已按页签独立，别破坏） |

---

## 9. 验收判据（四关，缺一不算完成）

1. **编译关**：`CompileArkTS` 真执行（日志有 `is not up-to-date` + 十秒级 cost）、0 ArkTS ERROR、`BUILD SUCCESSFUL`
2. **日志关**：
   - 冷启动后 `[FlingTrace]` 首次抛行能打出 `Idle → Scroll → Fling → Idle` 完整序列
   - `[TopBar]` 仍只有一条（缓存生效，没有因新代码产生重复求值）
3. **截图关**：抛行中截图（`uitest swipe` 后立即 `snapshot_display`）能看到顶栏下方内容被柔化、无硬边
4. **人眼关**（只能人来判）：连续 5 次快速上滑，顶栏模糊是否**肉眼可见地**不再消失。这一项必须由用户确认，静态截图证明不了连续性

---

## 10. 回退表

| 阶段 | 回退动作 | 影响面 |
|---|---|---|
| S0 | 删 4 处 `.onWillScroll` 与 `lastScrollState` 字段，删 `FlingTrace` 日志 | 零观感变化 |
| S1 | `PlayBar` 删 `@StorageProp` + `pause()/play()` 两行；常量保留无害 | 圆盘恢复常转 |
| S2 | 删 `.flingSpeedLimit(...)` 一处 | 抛行手感复原 |
| S3 | `TITLE_SCROLL_EFFECT_TYPE` 令牌翻转 + 恢复 `bindToScrollable` | 观感复原，需重跑验收 |

所有阶段都不改 `MaterialTokens` 的数值（除 S3 的枚举翻转），所以回退不涉及观感参数。

---

## 11. 待决策点（需用户拍板）

**A. S0 做完是否直接进 S1？**
建议是。S0 只是采样，不做等于白测。

**B. S1 的范围：只停迷你栏圆盘，还是连进度条流光一起停？**
建议先只停圆盘（可见收益最大、副作用最小）。进度条流光在 Fling 期停下可能被察觉「卡住了」。

**C. S2 的手感代价是否接受？**
必须在 S0/S1 结果出来后再谈。若 S1 已让模糊稳定，S2 不必做。

**D. 是否接受「模糊在极快抛行时短暂消失」作为已知限制？**
这是最省事的选择：写进已知问题，不做任何改动。Demo 的实测表明这可能是系统渲染管线层面的行为，第三方 App 未必有干净解法。

---

## 12. 可直接粘贴给 AI 的执行 prompt

```
在 E:/BiliMusic/HarmonyOS-Phone 工程内按 design/Fling状态感知与顶栏材质稳定性-AI实施规格.md
执行 S0 + S1，只改这两个阶段，不要碰 S2/S3。

S0（旁路采样）：
- 在 pages/SearchPage.ets、pages/PlaylistsPage.ets、pages/DownloadsPage.ets、pages/SettingsPage.ets
  四个 List 的属性链末尾追加 .onWillScroll((_offset, state, _source) => ...)，
  仅在 state 变化时打一条 console.info(`[FlingTrace] state=... y=...`)，
  y 取 TabScrollerHolder 对应 scroller 的 currentOffset().yOffset。
- 每个页面加 private lastScrollState: ScrollState = ScrollState.Idle（普通成员，严禁 @State）。

S1（Fling 期让出帧预算）：
- common/Constants.ts 新增 STORE_SCROLL_FLING 常量。
- 四个页面的 onWillScroll 在状态变化时写 AppStorage.setOrCreate(STORE_SCROLL_FLING, state===ScrollState.Fling)。
- components/PlayBar.ets 加 @StorageProp(STORE_SCROLL_FLING) + @Watch，
  在 true 时对圆盘 Animator 调 pause()，false 时调 play()；严禁复位 rotateAngle。
- 页面不可见/切页时必须把该标记写回 false，避免圆盘永久停转。

硬约束（违反即错）：
1. 不得在此过程中调用 HdsTitleBarStyle.styleOptions() 传新参数（会触发材质层重建）。
2. 不得在 HDS 之外叠加任何 blur。
3. 不得改 MaterialTokens 的数值。
4. lastScrollState 不得是 @State。

完成后：hvigorw assembleHap 编译到 0 ERROR + BUILD SUCCESSFUL；
装真机 192.168.0.5:41717，用 uitest swipe 制造快滑，抓 [FlingTrace] 与 [TopBar] 日志，抛行中截图。
最后更新 .workbuddy/memory/UI-LAYOUT.md 的顶栏材质小节与当日日志。
```

---

## 附：与两个竞品的对照（本轮调研结论）

| | 知乎++ | PiliPlus | BiliMusic（本方案目标） |
|---|---|---|---|
| `Fling` 字面量 | 0 处 | 0 处 | 0 处（现状）→ S0 引入 |
| 惯性期处理 | 不管（offset 阈值 + 一次 220ms 淡入） | **主动排除**（`dragDetails == null` 就 return） | 无 |
| 每帧写状态 | 否 | 否 | **是**（HDS 内部逐帧插值 + 迷你栏圆盘每帧 `@State`） |
| 材质闪失风险 | 结构性不存在 | 结构性不存在 | 已实测存在 |

两个竞品的共同点：**都把逐帧状态写入压到最低**。本方案的 S1 就是向这个方向靠 —— 不是加更多逐帧逻辑，而是在 Fling 期**减少**逐帧逻辑。

> 注意：PiliPlus 的「主动排除惯性期」值得单独记一笔 —— 它在 Flutter 侧明确写下
> `if (notification.dragDetails == null) return false;`，等于承认「惯性期间不接管 UI 状态」。
> 这不是偷懒，而是避免在高速帧里写状态引发视觉断层。
