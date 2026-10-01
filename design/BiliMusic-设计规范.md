# BiliMusic 设计规范（改版）

> 产出对象：`BiliMusic` HarmonyOS 音乐 App
> 依据：对 `HarmonyOS-Phone/entry/src/main/ets` 的**真实代码审计**（非凭空设定）
> 状态：色彩 / 字阶 / 间距圆角 / 触达 / 反馈 五块已定；`TrackItem` 已落地并通过编译
> 关联：`BiliMusic-UI.html`（视觉稿）、`BiliMusic-Figma搭建说明书.md`（Figma 落地）

---

## 0. 总则

改版的出发点不是"换个好看的样子"，而是修掉三个**已经在伤害用户**的问题：

| 问题 | 实测证据 | 影响面 |
|---|---|---|
| 灰阶对比度不达标 | 6 档灰中 4 档低于 WCAG AA 4.5:1 | 约 1/3 文字低于可读线 |
| 字阶过密 | 8 档字号挤在 10–20px，12/13/14/15 仅差 1px | 全应用层级失效 |
| 触达区过小 | 5 类高频控件热区 18–32vp（标准 44vp） | 误触，尤其「⋯」会触发播放 |
| 状态反馈缺失 | 56 处 `onClick` 无一处有按下态 | 点下去不知道是否命中 |
| Token 未落地 | `color.json` 仅 3 色，23 个色值硬编码在 `.ets` | 无法统一调优/换主题 |

---

## 1. 色彩系统

### 1.1 品牌色（不变）

| Token | 值 | 用途 | 约束 |
|---|---|---|---|
| `bili_pink` | `#FB7299` | 选中态图标、实底按钮、进度条填充 | **只用于大字号（≥18px）/ 图标 / 实底填充**。白底小正文对比度仅 2.20:1，**禁止** |
| `bili_blue` | `#00AEEC` | 链接、次要强调 | 同上 |

### 1.2 文字灰阶（6 档 → 3 档 + 1 禁用）

| Token | 值 | 对比度（白底） | 评级 | 用途 |
|---|---|---|---|---|
| `text_primary` | `#1A1A1A` | 16.75:1 | AAA | 歌名、标题、设置项 |
| `text_secondary` | `#6B6B70` | 5.31:1 | AA | 歌手名、状态行、说明文字 |
| `text_tertiary` | `#8A8A90` | 4.62:1 | AA | 时长、次要元信息 |
| `text_disabled` | `#BDBDC4` | 1.92:1 | — | 禁用态（无需达标） |

**替换对照表**：

| 旧值 | 旧对比度 | 新 Token |
|---|---|---|
| `#1A1A1A` | 16.75:1 | `text_primary`（不变） |
| `#666666` | 5.74:1 | `text_primary` 或 `text_secondary` |
| `#888888` | **3.54:1** ✗ | `text_secondary` |
| `#999999` | **2.85:1** ✗ | `text_secondary` |
| `#AAAAAA` | **2.32:1** ✗ | `text_tertiary` |
| `#BBBBBB` | **1.92:1** ✗ | `text_disabled` |
| `#CCCCCC` | **1.61:1** ✗ | `progress_paused` / `text_disabled` |

### 1.3 背景与状态

| Token | 值 | 用途 |
|---|---|---|
| `bg_divider` | `#E8E8EC` | 分隔线 |
| `progress_track` | `#E0E0E0` | 进度条轨道 |
| `progress_paused` | `#BDBDC4` | 暂停态进度条 |
| `state_success` | `#52C41A` | 下载完成 |
| `state_error` | `#D93026` | 下载失败 |
| `press_overlay` | `#0F000000` | 按压态遮罩（6% 黑） |

---

## 2. 字阶（8 档 → 6 档）

| 样式名 | 字号 / 行高 | 字重 | 用途 | 相对旧版 |
|---|---|---|---|---|
| `display` | 24 / 33 | Medium | 播放页歌名 | +4 |
| `title` | 20 / 28 | Bold | 歌单/设置/下载管理页标题 | 保留 |
| `heading` | 18 / 25 | SemiBold | 弹层标题「播放列表(8)」 | 统一 |
| `body` | 16 / 22 | Regular | 列表歌名、开关行 | +1 |
| `caption` | 13 / 18 | Regular | 歌手、时长、状态行、按钮 | +1 |
| `tag` | 11 / 15 | Medium | 底栏文字、徽章 | +1 |

**规则**：
- 相邻档位比值 **≥ 1.18**（12→14 只有 1.167，肉眼分不出，故删除）。
- 行高统一按 **1.4** 计算，四舍五入到整数。
- **已删除**：12 / 14 / 15 三档。

---

## 3. 间距与圆角

### 3.1 间距（一律 4 的倍数）

| Token | 值 | 用途 |
|---|---|---|
| `xs` | 4 | 图标与文字之间 |
| `sm` | 8 | 行内元素之间 |
| `md` | 12 | 列表内边距 |
| `lg` | 16 | 页面左右边距 |
| `xl` | 24 | 区块之间 |
| `xxl` | 40 | 大区块 |

### 3.2 圆角（5 档 → 3 档）

| Token | 值 | 用途 |
|---|---|---|
| `sm` | 8 | 封面、小卡片 |
| `md` | 12 | 卡片、弹层 |
| `pill` | 全圆 | 按钮、胶囊 |

**旧值归并**：`6 → 8`、`10 → 12`、`22 → pill`。

---

## 4. 触达尺寸（易用性硬标准）

**核心规则：视觉尺寸可以小，命中区必须 ≥ 44vp。**

| 场景 | 视觉 | 命中区 | 实现 |
|---|---|---|---|
| 列表「⋯」更多 | 20px 文字 | **44 × 44** | `Row().width(44).height(44).justifyContent(Center)` |
| 下载项「✕」取消 | 18 × 18 | **44 × 44** | 同上 + 二次确认 |
| 下载项「暂停/继续」 | 18 × 18 | **44 × 44** | 同上 |
| 搜索「清空」 | 18 × 18 | **44 × 44** | 同上 |
| 播放列表「移除」 | 28 × 28 | **44 × 44** | 同上 |

**相邻热区缓冲**：两个不同语义的可点区之间**至少留 8vp** 空隙，避免手指落在边界上触发错误操作。

---

## 5. 状态反馈

### 5.1 按压态（必须）

用 `stateStyles` 叠 `press_overlay`，**不改布局、不引额外节点**：

```typescript
.stateStyles({
  pressed: { .backgroundColor($r('app.color.press_overlay')) },
  normal: { .backgroundColor(Color.Transparent) }
})
```

适用范围：所有整行可点、所有图标按钮。

### 5.2 操作回执

| 操作类型 | 反馈方式 | 时长 |
|---|---|---|
| 轻量成功（加入队列、收藏） | Toast | 1200ms |
| 已给出明确视觉变化（选中、切换） | 无需 Toast | — |
| 破坏性操作（删除、清空、覆盖） | 二次确认对话框 | — |
| 失败（网络、权限） | Toast + 原因 | 1800ms |

**现状缺口**：Toast 封装仅存在于 6 个页面（`PlayerPage` / `PlaylistDetail` / `PlaylistsPage` / `RecentPage` / `SearchPage` / `SettingsPage`），`DownloadsPage` 与 `Index` 缺统一封装，应补齐。

### 5.3 空态

空态必须包含**下一步动作引导**，不能只说"暂无"。
例：`暂无歌曲` → `暂无歌曲` + `去首页发现音乐 ›`

---

## 6. 落地清单

### 已完成（编译通过）

- `resources/base/element/color.json`：3 色 → 13 语义 token。
- `components/TrackItem.ets`：
  - 字阶对齐（歌名 15→16、歌手/时长 12→13、行高 1.4）。
  - 色值换 token（`#1A1A1A`/`#888888`/`#AAAAAA` → `text_primary`/`text_secondary`/`text_tertiary`）。
  - 「⋯」命中区 20×28 → **44×44**，与整行 `onPlay` 留缓冲。
  - 新增按压态 `stateStyles`。

### 第二轮落地（2026-09-29 晚，`迷你条 / 播放页` 明确不改动）

范围：`SettingsPage` / `SearchPage` / `DownloadsPage` / `PlaylistsPage` / `PlaylistDetail` / `RecentPage`
六个页面。**播放页全家桶（`PlayerPage`、`components/player/*`、`PlayBar`、`QueueSheet`）按用户要求原样保留。**

**色彩 token 化（已完成）**

- 六个页面旧灰阶 `#888888` `#AAAAAA` `#999999` `#BBBBBB` `#CCCCCC` `#666666` **全部清零**，
  分割线 `#EEEEEE` / 进度轨道 `#E0E0E0` / 状态色 `#D93026` `#52C41A` 一并换成语义 token。
- 新增三个粉色 token：`brand_deep #C2185B`（5.81:1，白底粉字）、
  `brand_surface #FFF1F5`（浅粉容器）、`brand_on #3D0018`（6.56:1，粉底上的深字）。
- **双粉策略落地**：图标 / 实底 / 进度条继续用 `bili_pink #FB7299`；
  白底小字（删除、全选、清空、页签选中、定时状态）改用 `brand_deep`；
  粉底按钮（新建 / 播放全部 / 保存）补 `.fontColor(brand_on)` —— 原先是默认白字，仅 2.60:1。

**字阶收敛（已完成）**

- 最终分布只剩 **11 / 13 / 16 / 18 / 20**（+ 两处 `⋮` 图标的 22 视觉字号，配 44 热区，不受字阶约束）。
- 12 / 14 / 15 三档**已全部消失**：12→13、15→16；14 按语义分流（正文行值与空态→16，页签与按钮→13）。

**触达与反馈（已完成）**

- `PlaylistsPage` / `PlaylistDetail` 的 `⋮`：40×40 / 36×36 → **44×44** + 圆形按压态；
  父行同时补按压态，降低「想点 ⋮ 却进了详情」的误触。
- `DownloadsPage` 操作行（全选 / 删除选中 / 全部开始 / 全部暂停 / 完成·选择）与
  `RecentPage`「清空」：热区 30 → **44** + 按压态。

**剩余未完成（均为用户指定不动的范围）**

1. `QueueSheet`「清除列表」粉字与「取消」`#666666`（属播放页队列，本轮不动）。
2. `QueueSheet`「移除」28×28、`PlayBar` 控制按钮热区（属播放页 / 迷你条，本轮不动）。
3. 各页空态补「下一步动作」（属交互文案，未做）。

### 验收判据

- `grep -rn "#8[0-9A-F]\{5\}\|#A[0-9A-F]\{5\}\|#B[0-9A-F]\{5\}" --include=*.ets` 除白名单外应无结果。
- `grep -rn "fontSize(1[0245])" --include=*.ets` 应无结果（已删档位）。
- 编译 `CompileArkTS` Finished 且 ArkTS ERROR 0。

---

## 六、动效规范（2026-10-01 新增 · 本轮未改代码）

### 6.1 现状盘点

**已做得很好，不要动**：

| 资产 | 位置 | 说明 |
|---|---|---|
| `geometryTransition` 一镜到底 | `PlayBar` ↔ `CoverDiscComponent` | 迷你条封面 → 播放页唱片，圆↔圆形态一致 |
| 关键帧回弹 | `BounceIconButton` | `1 → 0.86 → 1.04 → 1`，**末帧有超调**，手感优于纯收缩 |
| 按压缩放 | `TrackItem` | `onTouch` + `scale(0.9)`，不消费事件、滚动抢占时 Cancel 自动回弹 |
| 唱片旋转 | `CoverDiscComponent` | `Curve.Friction` 弹簧曲线 |

**问题**：`common/constants/InteractionConstants.ets` 只有 `PRESS_SCALE` / `PRESS_ANIM_MS` 两条常量，
其余动效时长**全部硬编码**，共 **14 个不同值**（0/80/90/100/120/130/140/150/160/170/180/400/1200/1800），
其中 **120–180 有 7 档挤在 60ms 内**，相邻差 10ms 肉眼不可辨——与当初字号 12/13/14/15 是同一类病。

### 6.2 动效时长五档（收敛目标）

| 档位 | 时长 | 曲线 | 用途 |
|---|---|---|---|
| `instant` | 100ms | EaseOut | 按压、点击瞬间反馈 |
| `fast` | 150ms | EaseOut | 图标/状态切换、Toast 出入 |
| `normal` | 250ms | EaseInOut | 显隐、位移、弹层、列表入场 |
| `slow` | 400ms | EaseInOut | 页面转场、共享元素一镜到底 |
| `ambient` | 循环 | Linear / Friction | 唱片旋转、星空、shimmer 扫光 |

建议全部落进 `InteractionConstants.ets`，与 `PRESS_ANIM_MS` 并列。

### 6.3 缺口清单（按优先级）

**必做** —— 常规页面目前**零动效**，内容全是硬出现

1. **列表入场错峰**：位移 8–12vp + 淡入，单条 `normal`(250ms)，相邻延迟 30–40ms，
   **只做首屏可见的 ≤8 条**，之后同批出现（否则长列表滚到底还在错峰）。
2. **骨架屏**：`SearchPage` 已有 `loading` / `loadingRanking` / `loadingMore` 三个状态，
   但反馈只有「加载中…」文字。骨架形状贴真实内容（40 圆头像 + 两条文字条），
   shimmer 扫光 1200ms Linear 循环。占位色用 `brand_surface`（浅粉，贴合品牌基调）。
3. **子页转场**：`PlaylistDetail` / `Recent` / `About` 的 `pushPath` 目前无转场配置。
   从右滑入 `slow`(400ms) EaseOut，配合侧滑返回手势。

**该做**

4. **Toast 补全 + 出入动效**：目前只有 `ControlAreaComponent` / `QueueSheet` / `DownloadsPage` 三处有
   `showToast`。补全到搜索/歌单/设置；入场从底部 16vp 淡入上移 `fast`(150ms)，停留 1200ms，
   退出 200ms；连续调用**替换不排队**（否则删 5 首会连播 5 次）。
5. **空态入场**：插画淡入 `normal`，文案延迟 60ms 跟进；不建议加持续浮动。
6. **多选模式切换**：进入多选时复选框从右侧滑入 + 行内容右移 44vp，`normal` EaseOut。
   现在 `DownloadsPage.selecting` 切换是瞬间的。
7. **数值平滑**：下载进度/速度/已下载大小用 `animateTo` 平滑到新值 `fast`(150ms)，避免数字跳变。

**可选**

8. 图片加载完成淡入 `normal` 的 80%（约 200ms），避免闪白。
9. 下拉刷新 `Refresh`（目前 0 处）。
10. 进度条拖动时的触控放大反馈。

### 6.4 三条红线

1. **只动 `transform` / `opacity`，不动 `width`/`height`/`layout`** —— 改布局属性会触发整树重排。
2. **容器只做淡入，位移全部交给子项**。容器加 `translate` 会成为子项 `position: fixed`
   的包含块，导致弹层相对容器而非视口定位（真机表现为弹层从屏幕中部弹出）。
3. **入场动效与按压动效分层**：`TrackItem` 根 Row 已挂 `.scale()` + `.animation()` 做按压，
   入场位移必须放在**外层容器**，不要叠加到同一个节点上。

### 6.5 无障碍

- 位移类动效在系统「减少动效」开启时降级为**纯淡入**（保留信息，去掉运动）。
- 循环类动效（唱片旋转、星空、shimmer）在该模式下**暂停**。
- 动效不得作为唯一的反馈通道——状态变化必须同时有颜色/文字/图标的静态表达。
