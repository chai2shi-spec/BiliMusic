# 修改任务：修正 Pura X 外屏布局被误判为 Pura X Max 的问题

> 用途：本文可直接整篇复制给 AI 编码助手（DevEco Studio AI 面板 / Claude Code / 其他 IDE 助手）作为修改描述。
> 适用工程：HarmonyOS ArkTS 应用，已存在折叠屏适配代码但形态判定失准。

## 0. 一句话目标

`Pura X 折叠态外屏（326×326vp，1:1）` 必须进入"小方屏"布局，不得复用 `Pura X Max 折叠态（459×672vp）` 的布局分支。两台设备的断点完全相同，判定必须由"折叠态 + 宽高比 + 尺寸区间"承担，而不能由断点承担。

## 1. 已知事实（不可改动，供 AI 对照）

| 形态 | vp 尺寸 | 宽/高比例 | 横向断点 | 纵向断点 |
|---|---|---|---|---|
| Pura X 外屏（折叠态） | 326×326 | 1.000 | sm | md |
| Pura X 内屏（展开态） | 440×707 | 0.622 | sm | lg |
| Pura X Max 折叠态 | 459×672 | 0.683 | sm | md |
| Pura X Max 展开态 | 939×664 | 0.683（横置） | lg | md |

px 参考：Pura X 外屏 980×980、内屏 1320×2120；Pura X Max 外屏 1264×1848、内屏 2584×1828。

关键结论：**第 1 行与第 3 行断点完全相同（sm×md），任何仅凭断点的形态判断都必然误判。** Pura X 内屏横向断点同样是 sm，因此"以 sm 代表外屏"也会让内屏走错分支。

## 2. 根因

代码中存在"用断点推断机型形态"的条件，典型形态为 `widthBp === WIDTH_SM && heightBp === HEIGHT_MD` → 走阔折叠外屏（Pura X Max）布局。326×326 同时满足该条件，于是被吞入 Pura X Max 分支。需要 AI 识别并改写全部此类条件。

## 3. AI 需先执行的定位动作

全仓搜索以下关键词，逐条记录命中位置与用途，再区分「结构断点（保留）」与「形态推断（改写）」：

`WIDTH_SM`、`HEIGHT_MD`、`WIDTH_LG`、`getWindowWidthBreakpoint`、
`getWindowHeightBreakpoint`、`display.getDefaultDisplaySync`、`getFoldStatus`、
`PuraX`/`PuraXMax`、`459`、`672`、`326`、`980`、`1320`、`aspectRatio`、`deviceInfo.marketName`

## 4. 改写映射表（核心）

| 原写法 | 风险 | 改为 |
|---|---|---|
| `widthBp===SM && heightBp===MD` → 阔折叠外屏布局 | Pura X 外屏也命中 | 加比例约束：`ratio≥0.93 && short≤360` → 小方屏；`ratio∈[0.66,0.76) && short∈[420,500]` → 阔折叠外屏 |
| `widthBp===SM` → 视为外屏 | Pura X 内屏也是 sm | 改为 `foldStatus===FOLD_STATUS_FOLDED &&` 比例判断 |
| `widthBp===LG` → 视为大屏/阔折叠展开 | 分屏、悬浮窗、横屏同样 lg | 保留为结构断点，禁止与机型绑定 |
| 直接用 `display.getDefaultDisplaySync().width` 比较 | 单位是 px，980 会被当大屏 | 统一 `px / densityPixels` 转 vp 后再比 |
| `deviceInfo.marketName` 作主判据 | 机型枚举脆弱、后续新机失效 | 降级为兜底与差异化处理，主判据为尺寸+比例 |
| 每个形态一套组件树 | 开合重排、状态丢失 | 同一组件树，仅改宽度/栏数/显隐 |

## 5. 统一判定源（要求 AI 新增单一函数，全仓调用）

```ts
export enum DeviceForm {
  SmallSquare,     // 326×326  1:1
  WideFoldCover,   // 459×672  14:10
  PuraXInner,      // 440×707  16:10
  WideExpand,      // 939×664  10:14
  Normal
}

export function resolveForm(winWvp: number, winHvp: number, folded: boolean): DeviceForm {
  const short = Math.min(winWvp, winHvp);
  const long = Math.max(winWvp, winHvp);
  const ratio = short / long;

  if (folded && ratio >= 0.93 && short <= 360) return DeviceForm.SmallSquare;
  if (folded && ratio >= 0.66 && ratio < 0.76 && short >= 420 && short <= 500) return DeviceForm.WideFoldCover;
  if (ratio >= 0.58 && ratio < 0.66) return DeviceForm.PuraXInner;
  if (!folded && ratio >= 0.66 && ratio < 0.76 && short >= 900) return DeviceForm.WideExpand;
  return DeviceForm.Normal;
}
```

尺寸来源统一由 `EntryAbility.onWindowStageCreate` 中 `windowRect` 与 `windowSizeChange` 写入 `AppStorage`（`winW` / `winH`），回调内 px 用 `densityPixels` 换算；`getFoldStatus()` 变化时同步刷新。

```ts
// EntryAbility.ets
import { UIAbility } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage) {
    const win = windowStage.getMainWindowSync();
    const density = display.getDefaultDisplaySync().densityPixels || 1;
    const toVp = (px: number) => px / density; // 回调与 windowRect 均为 px

    const rect = win.getWindowProperties().windowRect;
    AppStorage.setOrCreate('winW', toVp(rect.width));
    AppStorage.setOrCreate('winH', toVp(rect.height));

    win.on('windowSizeChange', (size: window.Size) => {
      AppStorage.setOrCreate('winW', toVp(size.width));
      AppStorage.setOrCreate('winH', toVp(size.height));
    });
  }
}
```

```ts
// 页面侧消费
@StorageLink('winW') winW: number = 0;
@StorageLink('winH') winH: number = 0;

private form(): DeviceForm {
  const folded = display.getFoldStatus() === display.FoldStatus.FOLD_STATUS_FOLDED;
  return resolveForm(this.winW, this.winH, folded);
}
```

断点（`getWindowWidthBreakpoint` / `getWindowHeightBreakpoint`）保留，但只驱动结构参数：栏数、字号、间距、外边距。

## 6. 硬性约束

- 尺寸判定用 `windowRect`（窗口全尺寸），**禁止用安全区或 availableArea**——326vp 距 xs 阈值（320vp）仅 6vp，状态栏、导航条、圆角避让都会让断点抖动。
- `windowSizeChange` 回调需节流（约 150ms），连续触发时只做最后一次重算。
- 只改宽度、栏数、显隐，禁止重挂载组件树、禁止重建 List/Scroll 的 Scroller。
- 1:1 小方屏场景：内容区外层用 `Scroll`，弹窗外层 `constraintSize({ maxHeight: '90%' })`，避免截断。

## 7. 验收清单

1. 外屏 326×326 走小方屏布局，与 Pura X Max 折叠态布局可区分。
2. 内屏 440×707 不再命中任何"外屏 / 小方屏"分支。
3. 连续开合 3 次，页面不闪断、滚动位置与输入框内容不丢。
4. 分屏、悬浮窗、横屏下不误入任何机型专属分支。
5. 真机日志 `wvp/hvp` 分别输出 326/326 与 459/672，且两值走不同 `DeviceForm`。
6. 预览器设备预设为 `Pura X`（非 Pura X Max 折叠态），预览与真机一致。

## 8. 交付要求

AI 完成后输出：

1. 改动文件清单与 diff 摘要；
2. 被改写条件的"原条件 → 新条件"逐条对照；
3. 删除或降级的机型判断项；
4. 第 7 节 6 项的自查结论（未验证项须明确标注"未验证"）。

## 附：人工验证要点

- 内屏切外屏默认是锁屏亮屏态，**须先解锁外屏**才能看到 App 的外屏界面。
- 真机验证建议直接打日志对照 vp 尺寸，不要只凭观感判断走了哪个分支。
- 若改动后仍出现 Pura X Max 布局，优先检查是否还有第二处独立的机型判断（如 `marketName` 白名单）未被清理。
