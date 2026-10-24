# Fling 状态触发 · 两工程对照与 AI 实施规格

> 2026-10-24 编写 · **只出规格，不改代码**
> 参考 A：`PiliPlus-ohos`（Flutter 主体 + ArkTS 浮层壳）
> 参考 B：`zhihu-plus-plus-HMOS-HMOSv0.5.9`（纯 ArkTS）
> 目标：`E:/BiliMusic/HarmonyOS-Phone`

---

## 0. 结论（先给判断，再给依据）

**1）两个参考工程都没有「Fling 状态触发」这件事。** 全仓 `ScrollState` / `Fling` 字面量：
- PiliPlus 的 ArkTS 侧 **0 处**；它的滚动判定全在 Dart 侧，且用的是 `notification.dragDetails == null` **主动排除惯性期**。
- 知乎++ **3 处** `onDidScroll`，但全部是**无参回调** —— 只读 `scroller.currentOffset().yOffset`，不接 `ScrollState`。唯一出现 `ScrollState` 的地方是 `ThemeColorSettingsPage.ets:172` 的 `onScrollFrameBegin((offset, _state: ScrollState) => …)`，参数名 `_state` 带下划线 = **故意不用**。

**2）它们真正的共同做法不是「判 Fling」，而是「不让惯性帧进入状态写入路径」：**

| 工程 | 输入信号 | 惯性期行为 | 代价 |
|---|---|---|---|
| PiliPlus `onNotificationType2` | `ScrollNotification`，**`if (notification.dragDetails == null) return false;`** | 惯性帧**零写入**，顶栏停在松手瞬间的位置 | 松手后顶栏不再跟随惯性 |
| PiliPlus `onNotificationType1` | `UserScrollNotification.direction`（**方向翻转事件**，本身不逐帧） | 只在 `forward`/`reverse` 翻转时写一次布尔 | 只有「显示/隐藏」两态，无连续位移 |
| 知乎++ NativeContentDocument | `onDidScroll` 逐帧读偏移 | 结构量（`atTopEdge`/`tabsPinned`/`titleScrolled`）**全部门控** `if (x === this.x) return`；只有进度条连续量逐帧写 | 需要自己管门控 |

**3）BiliMusic 的「Fling 判定」没有落点 —— 因为顶栏材质的每帧求值不在业务层。** 材质强度由 HDS 内部按 `bindToScrollable` 绑定的 scroller 偏移自行插值，业务代码拿不到、也不该接管。给它加 `isFling` 只会**多一路逐帧写入**，与减负载目标相反。

**4）因此本规格只做两件事，且都是「边界写入」而非「逐帧判定」：**
- **F1（P0）**：在首页签 List 上加一路**只打日志、不写状态**的 Fling 旁路采样 —— 用于回答「⑧ 换成 `IMMERSIVE_GRADIENT_BLUR` 后，真机 Fling 期模糊还丢不丢」。
- **F2（P1）**：把 Fling 的进入/退出**只在边界各写一次**到 AppStorage，用它**暂停播放栏圆盘的无限 Animator**（唯一真实的每帧状态回写源）。

**5）Demo 页那套「吃掉 Fling 帧 + 自驱惯性」在主工程不可行**，原因见 §3.4 —— 它与 `bindToScrollable` 天然互斥，一旦吃帧，HDS 收到的偏移恒为 0，顶栏模糊将永不出现。

---

## 1. 两家的代码事实（带行号，可逐条复核）

### 1.1 PiliPlus：两套模式，没有一套叫 Fling

`lib/pages/common/common_page.dart:25-42` —— 按 `_barOffset` / `_showTopBar` 是否存在二选一：

```dart
Widget onBuild(Widget child) {
  if (_barOffset != null) {
    return NotificationListener<ScrollNotification>(
      onNotification: onNotificationType2,   // 连续位移模式
      child: child,
    );
  }
  if (_showTopBar != null || _showBottomBar != null) {
    return NotificationListener<UserScrollNotification>(
      onNotification: onNotificationType1,   // 方向显隐模式
      child: child,
    );
  }
  return child;
}
```

**模式 2（连续位移）`common_page.dart:73-100`** —— 惯性期被一行挡死：

```dart
if (notification is ScrollUpdateNotification) {
  if (notification.dragDetails == null) return false;   // ← 惯性帧直接丢弃
  final pixel = metrics.pixels;
  final scrollDelta = notification.scrollDelta ?? 0;
  if (pixel < 0.0 && scrollDelta > 0) return false;     // 顶部回拉期间不下移
  ...
  _updateOffset(scrollDelta);                            // clamp 到 [0, topBarHeight]
}
if (notification is OverscrollNotification) {
  _updateOffset(notification.overscroll);                // 仅边缘过卷也更新
}
```

**模式 1（方向显隐）`common_page.dart:44-64`**：

```dart
switch (notification.direction) {
  case .forward:  _showTopBar?.value = true;  _showBottomBar?.value = true;  break;
  case .reverse:  _showTopBar?.value = false; _showBottomBar?.value = false; break;
}
```

`UserScrollNotification` 在 Flutter 里由 `ScrollPosition.didUpdateScrollDirection` 派发，**只在方向变化时触发**，因此惯性期最多写 1 次。

另有 `needsCorrection`（`common_page.dart:16` 默认 `false`）走 `position.correctBy(offset)` 反向补偿视口 —— 顶栏高度变化时内容不跳。这是一个 BiliMusic 没有的技巧，但只用于「顶栏高度动画改变内容区」的形态，本工程顶栏定高 56vp，**用不上**。

ArkTS 侧完全被动：`ohos/entry/src/main/ets/pages/Index.ets:94` `@StorageLink('topBarCollapsed')`，值由 `plugins/HarmonyChannel.ets:648` 从 Dart 侧写入；`Index.ets:141` 只做 `homeHideTopBar && topBarCollapsed` 的组合读。

### 1.2 知乎++：逐帧读偏移，但结构量全部翻转门控

`pages/NativeContentDocument.ets:1112-1124`：

```typescript
.onDidScroll((): void => {
  const yOffset = this.scroller.currentOffset().yOffset;
  if (yOffset < this.lastYOffset - 0.5 || yOffset > this.lastYOffset + 2) {
    this.updateBottomEdge(false);
  }
  this.updateTopEdge(yOffset <= 2);
  this.lastYOffset = yOffset;
  this.scrollYVp = yOffset;              // ← 连续量（进度条）逐帧写，必须
  this.refreshContentHeightEstimate();
})
```

门控样板 `pages/NativeContentDocument.ets:1341-1348`：

```typescript
private updateTopEdge(atTop: boolean): void {
  if (this.atTopEdge === atTop) { return; }   // ← 只在翻转时写
  this.atTopEdge = atTop;
  this.onTopEdgeChange?.(atTop);
}
```

`pages/PeoplePinDetailPages.ets:494-512` 同款（`tabsPinned` / `titleScrolled` 各一道 `if (x === this.x) return`）。

**关键区分（本规格最重要的一条原则）**：
- **连续量**（进度条拇指、滚动跟随位移）→ 允许逐帧写，这是功能本身；
- **结构量**（折叠布尔、材质档、动画起停、样式对象）→ 必须边界写 / 翻转写。

BiliMusic 之前踩的「Fling 期改 `styleOptions` 导致整栏闪」，本质就是把**结构量**做了逐帧写。

---

## 2. BiliMusic 现状（为什么「加 Fling 判定」没有落点）

### 2.1 顶栏材质不由业务代码求值

`utils/HdsTitleBarStyle.ets:193-290` 只产出 `TitleBarStyleOptions`，模糊强度由 HDS 内部按偏移插值。全仓唯一能拿到 `ScrollState` 的地方是 Demo 页（无路由入口）：`pages/GradientBlurDemoPage.ets:377`。

### 2.2 唯一真实的每帧状态回写：播放栏圆盘

`components/PlayBar.ets:289-301`：

```typescript
private discOptions(): AnimatorOptions {
  return { duration: DISC_ROTATE_MS, easing: 'linear', delay: 0, fill: 'forwards',
           direction: 'normal', iterations: -1, begin: 0, end: DISC_ROTATE_DEGREE };
}
```

`PlayBar.ets:311-319` —— `onFrame` 每帧回写 `@State rotateAngle`，`FRAME_WRITE_MIN_MS = 16` 已是 60fps 满速：

```typescript
this.coverAnim.onFrame = (value: number): void => {
  const now: number = Date.now();
  if (now - this.lastFrameMs < FRAME_WRITE_MIN_MS) { return; }
  this.lastFrameMs = now;
  this.rotateAngle = value;
};
```

**已有的起停能力**（`PlayBar.ets:357-370`）—— `syncDiscAnim()` 已经在用 `pause()/play()`，且 `spin` 是低频门控：

```typescript
const spin: boolean = this.isPlaying && this.appForeground && !this.playerOpen && !this.overlayMounted;
if (spin) { anim.play(); } else { anim.pause(); }
```

→ **F2 只需给这个表达式多一个 `&& !this.flingActive`，是加一项判定，不是新写机制。**

### 2.3 Demo 页的结论与它的前提条件

`pages/GradientBlurDemoPage.ets` 头部记录的实测链：

| 轮次 | 做法 | 结果 |
|---|---|---|
| ④ | `flingSpeedLimit` 9000 → 2500 vp/s | **仍丢** → 定论：不是速度/负载，是 `ScrollState.Fling` **状态本身**触发 |
| ④ | 内容级 `linearGradientBlur` | **仍丢** → 三条渲染路径同症 |
| ⑤ | `onWillScroll` 对 Fling 帧返回 `{ offsetRemain: 0 }` 吃掉 + `Animator` 自驱 + `scroller.scrollBy`（Idle 通道） | 文件头写「待真机验证」，**无后续结论** |

⚠️ Demo 能这么写的前提（`GradientBlurDemoPage.ets:402-415`）：**`enableScrollEffect: false` + 不 `bindToScrollable`**。主工程恰恰相反 —— 这两条决定了 §3.4 的「不可行」判定。

---

## 3. 可改点判定表

| 编号 | 改点 | 参考来源 | 判定 | 风险 |
|---|---|---|---|---|
| F1 | Fling 边界旁路采样（只打日志） | 知乎++ 门控思路 | **做（P0）** | 极低 |
| F2 | Fling 期暂停圆盘 Animator | 两家「惯性别写状态」共识 | **做（P1）** | 低 |
| F3 | `flingSpeedLimit` 限速 | Demo ④、PiliPlus 无 | 条件触发（P2） | 手感代价 |
| F4a | 吃掉 Fling 帧 + 自驱惯性 | Demo ⑤ | **不做**（见 §3.4） | 与 HDS 绑定互斥 |
| F4b | 顶栏 `styleOptions` 加 Fling 分支 | — | **禁止** | 整栏闪 |
| F4c | 底部胶囊滚动隐藏 | PiliPlus Type1 | **不做** | 受控重建毁 miniBar |
| F4d | `correctBy` 视口补偿 | PiliPlus Type2 | **不做** | 本工程顶栏定高，无需求 |

### 3.4 为什么「吃掉 Fling 帧」在主工程不可行（这条必须写进 AI 的上下文）

Demo 用 `onWillScroll` 返回 `{ offsetRemain: 0 }` 把系统惯性整帧吃掉，再自己 `scrollBy` 驱动。但主工程首页/子页的顶栏模糊依赖：

```
HdsNavigation.bindToScrollable([scroller])  →  HDS 内部监听该 scroller 的偏移  →  驱动渐变模糊
```

一旦 `onWillScroll` 恒返回 `offsetRemain: 0`：

- 系统惯性位移被清零，列表**不产生 Fling 态位移**；
- 自驱的 `scrollBy` 属 **Idle 通道**，HDS 的滚动偏移监听**是否接收 Idle 通道的位移未知**（Demo 因为 `enableScrollEffect: false`，从没验证过这一点）；
- 若 HDS 不接收 → 顶栏模糊**永不出现**，且 `onScrollStop` 后的 `currentOffset()` 校正也救不回视觉。

**结论**：F4a 在「保留 HDS 顶栏」的前提下不可行。要它就只能走 PiliPlus 的路（完全自绘顶栏 + 关掉 HDS 滚动效果），那是另一份工程级方案，不在本规格范围。

---

## 4. 改动规格

### F1（P0）Fling 边界旁路采样 —— 只打日志，不写状态

**目的**：用真机日志回答两件事 ——
1. 首页/子页到底会不会出现 `ScrollState.Fling`（以及出现频率）；
2. ⑧ 换成 `IMMERSIVE_GRADIENT_BLUR` 后，Fling 期模糊还丢不丢（肉眼 + 日志时间戳对齐）。

**落点（只选一处，不要全站铺）**：`pages/SearchPage.ets` 里首页签的 `List`（即挂 `TabScrollerHolder.search` 的那个）。

**改法**：

1. 在 `components/` 新增一个纯函数式的采样器（不动现有文件结构），提供：
   - `noteScroll(state: ScrollState): boolean` —— 与上次状态比较，**翻转时**返回 `true`（调用方据此打日志）；
   - 内部只保存 `lastState` / `lastLogMs` 两个普通成员，**不得声明 `@State` / `@StorageLink`**。

2. 在该 `List` 上追加（与既有属性并列，**不改动任何现有属性**）：

```typescript
.onWillScroll((_offset: number, state: ScrollState, source: ScrollSource): void => {
  // 只采样，绝不返回 ScrollResult —— 返回对象会改变滚动，属于 F4a 范畴
  if (FlingSampler.note(state)) {
    console.info(`[Fling] state=${FlingSampler.name(state)} src=${source} off=${_offset}`);
  }
})
.onScrollStop((): void => {
  FlingSampler.note(ScrollState.Idle);   // 收尾：保证下次 Fling 能再报一次
  console.info('[Fling] stop');
})
```

**硬性约束**：
- 回调**没有返回值**（签名 `=> void`）。写成 `return { offsetRemain: n }` 就变成 F4a，禁止。
- 回调内**不得**出现 `AppStorage.setOrCreate` / `this.xxx = …` / 任何 `@State` 赋值。F1 的唯一副作用是 `console.info`。
- 日志必须带 `[Fling]` 前缀，便于 `hdc shell hilog | grep Fling` 过滤。

**验收**：真机抛出一次，`hilog` 里应看到 3~5 条（`Scroll` → `Fling` → `stop`），且**滚动流畅度与改前无可感知差异**（因为零状态写入）。

---

### F2（P1）Fling 期暂停圆盘动画

**依据**：两家共有的原则是「惯性帧不写结构状态」。BiliMusic 同屏唯一的每帧结构写入是圆盘 `@State rotateAngle`。Fling 期单帧位移极大（初速上限 9000 vp/s），此时圆盘每帧重绘与顶栏模糊同屏抢帧预算，暂停它是**唯一一处既能减负载、又不改变观感预期**的落点。

**跨组件通路**：滚动发生在页面 `List`，圆盘在 `components/PlayBar.ets`（底部胶囊 miniBar 内）→ 走 AppStorage，**只在边界写**。

**改动点 1：`common/Constants.ts`** 新增

```typescript
/** Fling（惯性/回弹）进行中：仅边界写入（Fling 首帧 true / onScrollStop false），严禁逐帧写 */
export const STORE_FLING_ACTIVE: string = 'flingActive';
```

**改动点 2：Fling 状态发布者**（与 F1 同一处，扩展 F1 的回调）

```typescript
// onWillScroll 内，紧接 F1 的采样之后：
const fling: boolean = state === ScrollState.Fling;
if (FlingSampler.note(state)) {
  AppStorage.setOrCreate(STORE_FLING_ACTIVE, fling);   // ← 只在翻转时写
  console.info(`[Fling] state=${FlingSampler.name(state)} off=${_offset}`);
}
// onScrollStop 内：
AppStorage.setOrCreate(STORE_FLING_ACTIVE, false);
```

⚠️ `AppStorage.setOrCreate` 必须**包在 `if (FlingSampler.note(state))` 里面**。写在外面就是逐帧写，等于把 Fling 判定变成新的帧负担 —— 这正是本规格要避免的事。

**改动点 3：`components/PlayBar.ets`**

```typescript
@StorageLink(STORE_FLING_ACTIVE) @Watch('onFlingActiveChanged') flingActive: boolean = false;

private onFlingActiveChanged(): void {
  this.syncDiscAnim();       // 复用既有起停入口，不新写 play/pause 逻辑
}
```

并把 `syncDiscAnim()` 的 `spin` 表达式改成：

```typescript
const spin: boolean = this.isPlaying && this.appForeground && !this.playerOpen
  && !this.overlayMounted && !this.flingActive;      // ← 唯一新增项
```

**必须在 `aboutToDisappear()` 里补一句** `AppStorage.setOrCreate(STORE_FLING_ACTIVE, false)`：否则抛行中离开首页会把 `flingActive` 永久钉在 `true`，圆盘再也不转（症状极像「唱片卡死不转」的老 bug）。

**已知取舍（要如实告知用户）**：
- `ScrollState.Fling` 的 SDK 语义包含「边缘回弹」（`list.d.ts:54-59`），所以**拖到顶端回弹的 ~200ms 里圆盘会停一下**。列表本身也几乎不动，肉眼几乎不可见，但可感知。
- 若认为这个停顿不可接受，替代做法是「Fling 持续超过 80ms 才暂停」（引入一个 `setTimeout`），**但那就多了一个定时器状态**，不建议在第一版引入。先用直接暂停验证。

**可选强化（不推荐，先别做）**：`PlayBar.ts:313` 的 `FRAME_WRITE_MIN_MS` 从 16 提到 24（≈40fps 回写）。4s/圈每步 0.36°，肉眼无差，开销再降 1/3。但这是全局改动，会影响非 Fling 期观感，单独评估。

---

### F3（P2，条件触发）`flingSpeedLimit`

**触发条件**：F1 的日志 + 肉眼确认「Fling 期模糊仍丢」，且用户愿意用抛行距离换模糊稳定。

**值**：系统默认 9000 vp/s → **4000**（Demo 试过 2500 仍丢，说明它救不了模糊，只能减小单帧位移；4000 保留手感）。

**落点**：只加在顶栏模糊实际生效、且 Fling 最频繁的列表 —— 首页签 + 歌单页签。**不要全站 13 处一起加**。

**代价**：抛行距离明显变短（一次上抛约少走 1/3 屏），这是用户能立刻感知的行为变化，**必须提前告知并取得同意**。

⚠️ Demo 的实测已经证明这条**不能修好模糊**（2500 仍丢）。它的唯一价值是减小帧负载的下限，属于「安慰剂级」改动。若用户不接受手感代价，直接跳过 F3。

---

### F4 明确不做（及理由）

| 不做 | 理由 |
|---|---|
| **F4a 吃掉 Fling 帧 + 自驱惯性** | 与 `bindToScrollable` 互斥，HDS 拿不到偏移 → 顶栏模糊永不出现（§3.4）。且需覆盖首页 4 页签 + 9 子页，回弹失效 |
| **F4b 顶栏 `styleOptions` 加 Fling 分支** | `styleCache` 是**内容键缓存**（`HdsTitleBarStyle.ets:177-211`）。Fling 期换参数 → 键变 → 返回新对象 → HDS 按引用判等认为样式变了 → **销毁重建材质层 → 整栏闪**。这是已有的坑，不是理论风险 |
| **F4c 底部胶囊滚动隐藏（PiliPlus Type1）** | 隐藏要靠换 `barFloatingStyle` 或改 `barOpacity` → 新样式对象 → HdsTabs 受控重建 → miniBar 槽位里的 PlayBar 被销毁（旧 bug，见 `Index.ets` 的 `cachedFloatingStyle` 注释）。风险远大于收益 |
| **F4d `correctBy` 视口补偿** | PiliPlus 用它解决「顶栏高度变化改变内容区」。本工程顶栏定高 56vp、内容从栏下穿过，无此问题 |
| **`onScrollIndex` 驱动任何东西** | 知乎++ 明确记录：「索引会随视口高度变化回弹造成振荡闪烁，像素偏移才稳定」（`NativeContentDocument.ets:1108-1110`） |

---

## 5. 参数与常量（全部录自实测/参考，不要自创）

| 项 | 值 | 来源 |
|---|---|---|
| `ScrollState` 语义 | `Idle=0` / `Scroll=1` / `Fling=2` | `declarations/list.d.ts:29-59`（三态枚举，`Fling` 含松手惯性 + 边缘回弹 + 滚动条快速拖放） |
| `onWillScroll` 签名 | `(offset: number, state: ScrollState, source: ScrollSource) => ScrollResult \| void` | 同上；**返回 `void` = 不干预** |
| `onDidScroll` 签名 | `(offset: number, state: ScrollState) => void`（可少写参数，知乎++ 即无参） | `common.d.ts` |
| `onScrollStop` | `() => void` | 无参数，无 state |
| 圆盘单圈时长 | `DISC_ROTATE_MS = 4000` | `PlayBar.ets:137` |
| 圆盘角度 | `DISC_ROTATE_DEGREE = 360` | `PlayBar.ets:136` |
| 圆盘回写节流 | `FRAME_WRITE_MIN_MS = 16` | `PlayBar.ets:139` |
| 顶栏模糊区间 | `TITLE_BLUR_START_VP = 0` / `TITLE_BLUR_END_VP = 20` | `MaterialTokens.ets:31-33` |
| Demo 限速参考 | 2500 vp/s（**已验证救不了模糊**） | `GradientBlurDemoPage.ets:103` |
| 建议限速 | 4000 vp/s（F3 才用） | 本规格 |

---

## 6. 禁止项（写进 AI 的硬约束）

1. **禁止在 `onWillScroll` 里返回 `{ offsetRemain: n }`** —— 那是 F4a，与 HDS 绑定互斥（§3.4）。
2. **禁止把 `state === ScrollState.Fling` 的结果写成 `@State` / 每帧 `AppStorage`** —— 必须过 `note()` 翻转门控。
3. **禁止在 Fling 期修改 `HdsTitleBarStyle.styleOptions()` 的任何参数**（含起止偏移）—— 缓存 miss → 材质层重建 → 整栏闪。
4. **禁止在 `PlayBar` 里自己 `getUIContext().createAnimator(...)` 新建第二个圆盘动画器** —— 复用 `coverAnim` + `syncDiscAnim()`。
5. **禁止用 `onScrollIndex` 判定任何状态**（知乎++ 实测振荡闪烁）。
6. **禁止在 F1/F2 的回调里 `console.info` 每帧打** —— 只打翻转（hilog 本身也有开销）。
7. **禁止把 `STORE_FLING_ACTIVE` 用于任何「结构性」决策**（比如切页签、改布局、换样式对象）。它只允许驱动「动画起停」这一种连续量行为。
8. **禁止全站铺 F1** —— 先只挂首页签一处，拿到数据再决定是否扩散。

---

## 7. 验收清单（真机）

| 项 | 判据 |
|---|---|
| F1 日志 | `hdc shell hilog \| grep "\[Fling\]"`：抛行一次出现 `Scroll → Fling → stop` 三条，且**不是每帧一条** |
| F1 无副作用 | 改前/改后同一条列表连续抛行 5 次，滚动总距离一致；无 `[Fling]` 之外的异常日志 |
| F1 关键问题 | 抛行过程中顶栏模糊是否消失 —— 记录「消失 / 不消失」并标注 `hilog` 时间戳。这是 F3 是否启动的唯一依据 |
| F2 圆盘 | 抛行时圆盘停转、`onScrollStop` 后 ≤1 帧恢复；**不允许出现「松手后永久停转」** |
| F2 泄漏 | 抛行中按返回/切页签离开首页，再回来圆盘必须恢复转动（验证 `aboutToDisappear` 兜底） |
| F2 回弹 | 列表拉到底松手回弹，圆盘停顿 ≤ 回弹时长（约 200ms），不出现「回弹结束后仍停」 |
| 编译 | `CompileArkTS` 真执行 + ArkTS ERROR 0 + `BUILD SUCCESSFUL`（改前 `touch` 源文件破缓存） |

---

## 8. 回退表

| 改动 | 回退动作 | 影响面 |
|---|---|---|
| F1 | 删两个回调 + 删采样器文件 | 零残留（无状态、无存储键） |
| F2 | `syncDiscAnim()` 的 `spin` 去掉 `&& !this.flingActive`，保留 `@StorageLink` 无副作用；或直接删该字段与 `@Watch` | 回到现状 |
| F3 | 删 `flingSpeedLimit` 属性行 | 回系统默认 9000 |

三者互相独立，可单点回退。

---

## 9. 可直接粘贴给 AI 的 prompt

```text
在 E:/BiliMusic/HarmonyOS-Phone 里实施「Fling 边界采样 + 圆盘 Fling 暂停」，严格按以下规格，
不要自行扩展。改前先读 utils/HdsTitleBarStyle.ets 的类头（了解为什么禁止逐帧改样式）。

【F1·只打日志】
1. 新建一个采样器（放 components/ 下，纯类、无状态变量），提供：
   note(state: ScrollState): boolean  —— 与上次状态比较，翻转才返回 true；
   name(state: ScrollState): string   —— 返回 Idle/Scroll/Fling。
2. 只在 pages/SearchPage.ets 首页签那个 List（挂 TabScrollerHolder.search 的）上追加：
   .onWillScroll((offset: number, state: ScrollState, source: ScrollSource): void => {
     if (FlingSampler.note(state)) {
       AppStorage.setOrCreate(STORE_FLING_ACTIVE, state === ScrollState.Fling);
       console.info(`[Fling] state=${FlingSampler.name(state)} src=${source} off=${offset}`);
     }
   })
   .onScrollStop((): void => {
     FlingSampler.note(ScrollState.Idle);
     AppStorage.setOrCreate(STORE_FLING_ACTIVE, false);
     console.info('[Fling] stop');
   })
   回调必须是 void 返回，绝对不能 return { offsetRemain: ... }。

【F2·圆盘暂停】
3. common/Constants.ts 增加 STORE_FLING_ACTIVE = 'flingActive'（带一行注释：仅边界写入）。
4. components/PlayBar.ets：
   - 加 @StorageLink(STORE_FLING_ACTIVE) @Watch('onFlingActiveChanged') flingActive: boolean = false;
   - 新增 onFlingActiveChanged() { this.syncDiscAnim(); }
   - syncDiscAnim() 里 spin 表达式末尾追加 && !this.flingActive
   - aboutToDisappear() 里补 AppStorage.setOrCreate(STORE_FLING_ACTIVE, false)
   不要新建第二个 Animator，不要改 discOptions()。

【禁止】
- 不要在 onWillScroll 返回 ScrollResult；
- 不要在 Fling 期改 HdsTitleBarStyle.styleOptions 的任何参数；
- 不要用 onScrollIndex；
- 不要把 flingActive 用于任何样式对象/布局决策。

【收尾】
编译（先 touch 改动文件），确认 CompileArkTS 真执行 + ArkTS ERROR 0 + BUILD SUCCESSFUL。
真机抛行，hilog 抓 [Fling]，报告：是否出现 Fling 态、抛行期顶栏模糊是否消失。
```

---

## 10. 一句话给用户

两个工程都没在「判 Fling」，它们做的是**别在惯性帧里写状态**。BiliMusic 照这个原则改，落点只有两个：给首页签加一路只打日志的 Fling 采样（回答「模糊到底还丢不丢」），以及在 Fling 的进入/退出边界各写一次、用来暂停播放栏圆盘那个每帧回写 `@State` 的无限动画。**不要**指望加个 Fling 判定就能修好顶栏模糊 —— Demo 的实测已经证明那是 `ScrollState.Fling` 状态本身触发的，业务层无参数可解。
