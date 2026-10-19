# 鸿蒙沉浸光感标题栏 · 可移植 AI 实施规格

> 用途：把本项目验证过的「沉浸光感标题栏 + 状态栏衔接」实现，搬到**另一个鸿蒙 App**。
> 下面第 2 节是一段**可直接复制粘贴给 AI 的自包含 prompt**，第 3 节是配套参考实现，
> 第 4 节是踩过的坑（必读，接手的 AI 一定会踩）。
>
> 本文所有结论来自 HarmonyOS 7（API 26）真机验证过的代码，不是文档推测。

---

## 1. 一句话说明这套方案在做什么

开「全屏布局」让内容铺满整屏、系统栏透明，然后**自己读状态栏高度、自己算避让、自己画标题栏**，
并把标题栏做成 API 26 的「沉浸光感」液态玻璃材质，让玻璃面从屏幕顶端 (y=0) 起排、
**把状态栏区域一并盖住**——视觉上导航栏与状态栏就连成一体。

---

## 2. 可直接粘贴给 AI 的 Prompt

```text
请在鸿蒙 App（HarmonyOS / ArkTS，目标 API 26）中实现「沉浸光感标题栏」，
要求顶部导航栏与系统状态栏在视觉上连成一体。请严格按以下步骤实现，
每一步的「为什么」也请读懂——它们决定了不这样做就会静默失效。

【前置】使用 @kit.ArkUI 的 uiMaterial、@kit.AbilityKit 的 window / common。

【第 1 步：入口 Ability 里开全屏布局 + 系统栏透明】
在 onWindowStageCreate 中，拿到主窗口后：
  await mainWin.setWindowLayoutFullScreen(true);
  await mainWin.setWindowSystemBarProperties({
    statusBarColor: '#00000000',
    statusBarContentColor: <从资源解析出的 hex 串>,
    navigationBarColor: '#00000000',
    navigationBarContentColor: <同上>
  });
为什么：setWindowLayoutFullScreen(true) 把布局锚定基准从「安全区」改成「整屏」，
状态栏/手势条区域进入页面布局范围，系统栏背景透明才能透出页面自绘背景。
⚠️ 代价：系统不再自动避让，避让高度必须自己读、自己消费（见第 2、4 步）。
⚠️ 内容色字段 SDK 只收 string：请写一个 resToHex(resource) 工具，
  用 context.resourceManager.getColorSync(res.id) 取 0xAARRGGBB 整型再转 hex
  （颜色仍源自资源文件，深浅色能自动切换）。
⚠️ 必须同时处理 onConfigurationUpdate：深浅色/语言变化时重新调用
  setWindowSystemBarProperties —— 窗口管理器不会主动重解析已应用过的值，
  不重刷会滞留旧模式的颜色。

【第 2 步：读避让区高度，写 AppStorage】
const ind = mainWin.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
const sys = mainWin.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
// 状态栏高度：TYPE_SYSTEM 的 topRect
AppStorage.setOrCreate('app_status_inset_px', sys.topRect.height);
// 底部手势条/三键栏高度：两者取大（手势导航与三键导航形态不同）
AppStorage.setOrCreate('app_nav_inset_px', Math.max(ind, sys.bottomRect.height));
// 导航模式切换（手势 ⇄ 三键）/ 旋转 / 分屏都会改变避让区，必须监听：
mainWin.on('avoidAreaChange', () => { /* 重新读并写 AppStorage */ });
为什么：全屏布局后系统不再给避让值，只能主动问窗口要。

【第 3 步：时序——避让区必须在 loadContent 之前读完】
顺序固定为：setWindowLayoutFullScreen → setWindowSystemBarProperties
→ 读避让区写 AppStorage → 最后才 loadContent 首页。
为什么：loadContent 之前读完，页面首帧就能拿到正确高度，
不会出现「先按安全区排、再跳到全屏」的可见抖动。
另外：若你的入口有异步初始化（数据库预热等），要等它完成再 loadContent，
否则页面会在数据未就绪时运行。

【第 4 步：入口页做唯一的 px→vp 换算并广播】
在入口页（承载标题栏的那个 @Entry 页）：
  @StorageProp('app_status_inset_px') @Watch('reconvertInsets') statusInsetPx: number = 0;
  @StorageProp('app_nav_inset_px')   @Watch('reconvertInsets') navInsetPx: number = 0;
  reconvertInsets() {
    // densityUpdate 刚上报的新密度优先；未上报过时 px2vp 与渲染密度一致
    const d = this.freshDensity;
    const s = d > 0 ? this.statusInsetPx / d : this.getUIContext().px2vp(this.statusInsetPx);
    const n = d > 0 ? this.navInsetPx / d : this.getUIContext().px2vp(this.navInsetPx);
    AppStorage.setOrCreate('app_status_inset_vp', s);
    AppStorage.setOrCreate('app_nav_inset_vp', n);
  }
  // 系统显示缩放变更时也要重算（onDensityUpdate 或同等回调里更新 freshDensity 后触发）
为什么（关键）：官方已知问题——系统缩放变更后 px2vp 不实时刷新（旧值）。
若让每个页面各自 px2vp，标题栏与各页避让值会算出不同结果，出现错位。
⇒ px→vp 换算必须收敛到唯一一处，各页只消费 vp 值。
另：AppStorage 的 px 键被 @Watch 到，任何重写都会触发重算，无需额外通知。

【第 5 步：标题栏必须是 Navigation，不能是 Column（硬约束）】
入口页的根容器用 Navigation（只当标题栏容器用，路由仍可走 router）：
  Navigation() {
    /* 你的内容（Tabs / 列表等） */
  }
  .title({
    builder: this.TitleBar,
    height: this.statusInsetVp + TITLE_BAR_H        // TITLE_BAR_H 建议 56
  }, {
    backgroundColor: $r('app.color.transparent'),   // 必须全透明，见坑 2
    systemMaterial: this.barMaterial,
    barStyle: BarStyle.STACK,
    scrollEffectOptions: { scrollEffectType: ScrollEffectType.GRADUAL_BLUR }
  })
  .hideBackButton(true)
  .mode(NavigationMode.Stack)
  .width('100%')
  .height('100%')
为什么：API 26 沉浸光感材质（systemMaterial）的官方生效范围只有
① Navigation / NavDestination 的标题栏、② 横向 Tabs 且 barPosition End 的底部 TabBar、
③ 弹窗类组件。挂在普通 Stack/Column 上完全无效、静默无效果。
height = 状态栏高 + 56 让材质面从 y=0 起排、覆盖状态栏区域 —— 这就是「连成一体」。
barStyle STACK = 标题栏悬浮于内容之上，内容从玻璃下穿行；
scrollEffectOptions GRADUAL_BLUR = 滚动时玻璃由透转实（渐进模糊）。

【第 6 步：标题行自身也要透明 + 向下让出状态栏】
@Builder TitleBar() {
  Row() { /* 标题 Text、右侧操作按钮 */ }
    .width('100%').height('100%').alignItems(VerticalAlign.Center)
    .padding({ top: this.statusInsetVp })        // 文字压到状态栏下方
    .backgroundColor($r('app.color.transparent')) // 必须全透明，见坑 2
    .expandSafeArea([SafeAreaType.SYSTEM])        // 材质面补进状态栏区域
}
为什么：材质是「底层」，标题行是「上层」；上层一不透明就把材质盖死。

【第 7 步：材质参数】
private barMaterial: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.ULTRA_THIN,   // 超薄；B 端保文字可读，别用 THICK
  colorInvert: true,                             // 自动反色，标题文字随主题保持可读
  interactive: true,                             // 按压光感反馈
  lightEffect: { color: <你的主题色> }            // 点光源流光，可传 null 关闭
});
// 若还有底部 TabBar 想要同款：barFloatingStyle + systemMaterial 同上参数，
// 另加 applyShadow: true（悬浮投影）；barBottomMargin 必须叠加底部避让高度
// （margin 从屏幕物理底边起算，不叠会被手势条盖住）。

【第 8 步：各页面消费避让高度】
在公共主题/工具文件里导出一个函数，各页直接调用：
  export function titleBarInsetVp(): number {
    return (AppStorage.get<number>('app_status_inset_vp') ?? 0) + TITLE_BAR_H;
  }
各页内容容器：
  // 固定头部的页：整体下移
  .padding({ top: titleBarInsetVp() + Space.PAGE })
  // 滚动列表页：内容可穿到玻璃下方，只给首屏起始偏移
为什么：直读 AppStorage 不建立组件依赖，取值时刻即最新值（入口页已先写入）。
分两类是刻意的：列表页让内容从玻璃下穿行才看得出「沉浸」；固定头部页整体下移更稳。

【第 9 步：降级（必须做）】
低版本/不支持沉浸光感的设备上 systemMaterial 静默无效。
请保证此时：标题行背景透明 → 直接露出页面底色，标题文字仍清晰可读。
不要为此写两套代码，一套 + 透明背景即可自适应。

【验收标准】
1. 标题栏玻璃面从屏幕顶端起排，覆盖状态栏区域，状态栏图标在玻璃上清晰可读。
2. 深浅色切换后，状态栏图标色与标题栏材质反色都正确（不滞留旧色）。
3. 系统显示缩放变更（设置→显示和亮度→字体与显示大小）后，
   标题栏与各页避让值仍一致，无错位。
4. 手势导航 ⇄ 三键导航切换、旋转后，底部避让仍正确。
5. 首帧无「先避让后展开」的跳动。
6. 不支持沉浸光感的设备上不崩、不白屏、标题可读。
7. 滚动列表页内容从玻璃栏下方穿行，且滚动时有渐进模糊。
```

---

## 3. 参考实现骨架（可直接对照）

```ts
// EntryAbility.ets —— onWindowStageCreate
let mainWin: window.Window;
try { mainWin = windowStage.getMainWindowSync(); }
catch (e) { /* 退化为默认窗口模式，直接 loadContent，不阻断启动 */ }

const applyImmersive = async (): Promise<void> => {
  try {
    await mainWin.setWindowLayoutFullScreen(true);
    await applySystemBarColors(mainWin);          // 四字段全透明/资源色
  } catch (e) { /* 只记日志：沉浸失效但页面可用 */ }

  const updateInsets = (): void => {
    let navPx = 0, statusPx = 0;
    try {
      const ind = mainWin.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
      const sys = mainWin.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      navPx = Math.max(ind, sys.bottomRect.height);
      statusPx = sys.topRect.height;
    } catch (e) { /* 记日志，值留 0 */ }
    AppStorage.setOrCreate('app_nav_inset_px', navPx);
    AppStorage.setOrCreate('app_status_inset_px', statusPx);
  };
  updateInsets();
  mainWin.on('avoidAreaChange', () => updateInsets());

  await this.readyPromise;                        // 等数据初始化完成
  windowStage.loadContent('pages/Main', (err) => { /* 记日志 */ });
};
void applyImmersive();
```

```ts
// Main.ets —— 入口页（标题栏容器）
@StorageProp('app_status_inset_px') @Watch('reconvertInsets') statusInsetPx = 0;
@StorageProp('app_nav_inset_px')   @Watch('reconvertInsets') navInsetPx = 0;
@StorageProp('app_status_inset_vp') statusInsetVp = 0;   // 广播出口

private barMaterial = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
  colorInvert: true, interactive: true,
  lightEffect: { color: Palette.BLUE }
});

build() {
  Navigation() {
    Stack({ alignContent: Alignment.Bottom }) { /* 内容 + TabBar */ }
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
  .title({ builder: this.TitleBar, height: this.statusInsetVp + TITLE_BAR_H }, {
    backgroundColor: $r('app.color.transparent'),
    systemMaterial: this.barMaterial,
    barStyle: BarStyle.STACK,
    scrollEffectOptions: { scrollEffectType: ScrollEffectType.GRADUAL_BLUR }
  })
  .hideBackButton(true)
  .mode(NavigationMode.Stack)
}
```

---

## 4. 七个坑（每条都会让功能静默失效，必读）

| # | 错误做法 | 后果 | 正确做法 |
|---|---|---|---|
| 1 | 根容器用 `Column`/`Stack`，把 `systemMaterial` 挂在普通容器上 | **完全无效果、不报错** | 标题栏必须用 `Navigation`（或 NavDestination）；底部 TabBar 必须横向 Tabs + `barPosition(End)` |
| 2 | 标题行设了不透明背景色（哪怕是"兜底白"） | 玻璃被盖住，**看不到材质** | 标题行 `backgroundColor` 全透明；光感层级在组件背景色**之下** |
| 3 | 每个页面各自 `px2vp(statusInsetPx)` | 缩放变更后各页避让值不一致、错位 | px→vp 只在入口页换算一次，广播 vp，各页只读 vp |
| 4 | 用原生 `ComposeTitleBar` | API 26 即使不传 item 也渲染默认返回按钮（布局树实测多出 `ComposeTitleBar_ImageMenuItem` 节点） | 自绘标题行（`@Builder`） |
| 5 | 只读一次避让区，不监听 `avoidAreaChange` | 手势⇄三键切换、旋转、分屏后避让值过期 | `mainWin.on('avoidAreaChange', ...)` 持续刷新 |
| 6 | `loadContent` 在避让区读取之前 | 首帧按旧基准排布，可见跳动 | 严格按 沉浸设置→读避让→loadContent 顺序 |
| 7 | 只设 `setWindowLayoutFullScreen`，不重刷系统栏色 | 深浅色切换后状态栏图标滞留旧色 | `onConfigurationUpdate` 里重新 `setWindowSystemBarProperties` |

**另有两个容易漏的**：
- `height` 必须是「状态栏高 + 56」，只给 56 会把标题压到状态栏下面。
- 底部 TabBar 的 `barBottomMargin` 从**屏幕物理底边**起算，必须叠加底部避让高度，否则胶囊沉进手势条。

---

## 5. 自检清单（实现完逐条过）

- [ ] 状态栏区域被玻璃覆盖，图标清晰可读
- [ ] 深浅色切换：图标色 + 材质反色都跟着变
- [ ] 改系统字体/显示大小：标题栏与各页避让仍对齐
- [ ] 手势 ⇄ 三键切换、横竖屏旋转：避让正确
- [ ] 首帧无跳动
- [ ] 低版本设备：不崩、不白屏、标题可读
- [ ] 列表页内容从玻璃下穿行，滚动有渐进模糊
- [ ] `ComposeTitleBar` 未使用；无多余返回按钮
- [ ] 全库只有**一处**做 px→vp 换算

---

## 6. 移植时要替换的项目特定值

| 本项目的值 | 换成你的 |
|---|---|
| `app_status_inset_px` / `app_status_inset_vp` / `app_nav_inset_*` | 你的 AppStorage 键名（保持 px/vp 成对） |
| `TITLE_BAR_H = 56` | 你的标题行高度 |
| `Palette.BLUE`（lightEffect 流光色） | 你的主题强调色 |
| `$r('app.color.navy')`（状态栏图标色） | 你的语义色资源（需有深浅色两态） |
| `$r('app.color.transparent')` | 你的透明色资源 |
