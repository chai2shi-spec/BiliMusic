# BiliMusic · Figma 搭建说明书

> 配套文件：`BiliMusic-UI.html`（高保真界面稿，13 屏，可直接双击打开）。
> 本文把 HTML 稿逐屏翻译成 **Figma 可执行的搭建步骤**：Frame 尺寸、Auto Layout 层级、
> 变量名与代码值的对应关系、组件属性表、原型连线。
>
> 数据来源：`E:/BiliMusic/HarmonyOS-Phone` 的真实 ArkUI 代码（2026-09 播放页重构 +
> 底栏融合 miniBar 之后的状态）。字号、间距、色值、圆角逐条比对过。
>
> **底栏为不变更项**：HdsTabs 沉浸光感悬浮胶囊（含融合播放栏），本稿按现状 1:1 还原，
> 不做任何改动建议。

---

## 0. 先读这一节：三条搭建铁律

**① 一律用 Auto Layout，不许手动拖。**
本稿间距是 **4 / 8 / 12 / 16 / 24 / 40** 的梯度（一律 4 的倍数）。用 Auto Layout 一次性把
`gap` 定好，后面改一处 padding 全局跟着动。可以脱离 Auto Layout 的只有 4 处：
播放页大封面（aspect 1:1）、底栏胶囊（绝对定位）、队列弹层（绝对定位）、HomeIndicator。

**② 颜色/文字/间距只引用变量，不许吸管取色。**
Figma `Local variables` 面板建好 §2 的全部变量后再画。尤其**粉色有 5 个档位**
（brand / brand-deep / brand-tint / brand-tint2 / brand-mid），吸管取色必混。

**③ SP Frame 设 `Clip content` + 390×844。**
与鸿蒙真机 vp 1:1。顶部安全区 47 / 底部手势区 34 由各屏自己补（本 App 是窗口级全屏，
系统不避让，见 `Index.ets` 文件头注释）。

---

## 1. 画布与目标尺寸

| 项 | 值 | 说明 |
|---|---|---|
| SP 尺寸 | `390 × 844` | 13 个 SP 全部同尺寸 |
| 安全区 顶部 | `47` | 状态栏（挖孔机型） |
| 安全区 底部 | `34` | 手势条区 |
| 内容左右边距 | `16` | 列表、卡片统一 |
| SP 间距 | `80` | 并排摆放 |

**避让消费表**（各元素自己避让一次，互不重叠——这是本工程的全屏布局约定）：

| 元素 | 避让 | 来源 |
|---|---|---|
| 页签层(HdsTabs) | `padding.top = safeTop` | `Index.ets` |
| 悬浮胶囊 | `barBottomMargin = 20 + safeBottom` | `Index.barFloatingStyle()` |
| 各 Tab 列表 | `contentEndOffset = 160 + safeBottom` | `Constants.CONTENT_END_OFFSET` |
| 子页标题栏 | `padding.top = safeTop` | 各子页自己 |

---

## 2. 设计变量（Figma Variables）

### 2.1 颜色 · 品牌组（哔哩哔哩粉色基调）

| 变量 | 值 | 用途 | 白底对比度 |
|---|---|---|---|
| `brand` | `#FB7299` | **视觉主色**：页签选中 · 图标 · 实底填充 · 进度条 · 底栏光晕 | 2.20:1 ⚠️ |
| `brand-deep` | `#C2185B` | **白底上的粉字**：新建/清空/清除列表/重试 · CTA 强调 | 5.81:1 AA |
| `brand-tint` | `#FFF1F5` | 浅粉区块底：搜索框 · 模式药丸 · 次级按钮 | — |
| `brand-tint2` | `#FFE0EA` | 徽章 / 选中项浅底 | — |
| `brand-mid` | `#F48FB1` | 空态插画描边（brand 的 60% 亮度档） | — |
| `brand-blue` | `#00AEEC` | B 站蓝：链接 · 次要强调 | 3.06:1 |

> **双粉策略（本稿核心决策）**：`brand` 保留 B 站标志性视觉，但白底小字一律改用
> `brand-deep`。两档都是粉，基调不变，可读性达标。**禁止**把 `brand` 用在白底 13px 正文上
> （代码里 `QueueSheet` 的「清除列表」13px 粉字即此类，落地时应换 `brand-deep`）。

#### ⚠️ Figma 变量名 → 代码 token 对照（交接开发 / 喂 AI 必读）

上表的变量名是为**在 Figma 里好认**起的，与 `color.json` 里的资源名**并不一致**。
直接照抄去写 ArkUI 代码会引用到不存在的资源（编译报错 `resource not found`）：

| Figma 变量 | 代码里的写法 | 说明 |
|---|---|---|
| `brand` | `$r('app.color.bili_pink')` | 名字不同，值同为 `#FB7299` |
| `brand-deep` | `$r('app.color.brand_deep')` | 一致 |
| `brand-tint` | `$r('app.color.brand_surface')` | 名字不同，值同为 `#FFF1F5` |
| （粉底上的文字） | `$r('app.color.brand_on')` | §2.1 表未列，但代码已建，值 `#3D0018` |
| `brand-blue` | `$r('app.color.bili_blue')` | 名字不同 |
| `brand-tint2` | — | **仅稿中有**，代码未落地 |
| `brand-mid` | — | **仅稿中有**，代码未落地 |

> 结论：**本文 §2 只描述设计意图，资源名一律以 `color.json` 为准。**
> 让 AI 写/改代码时，务必把 `color.json` 一并给它，否则它会按本文的变量名臆造 resource name。

### 2.2 颜色 · 中性组（对齐 `color.json`）

| 变量 | 值 | 用途 | 对比度 |
|---|---|---|---|
| `text_primary` | `#1A1A1A` | 标题 · 歌名 | 16.75:1 AAA |
| `text_secondary` | `#6B6B70` | 歌手 · 状态 · 说明 | 5.31:1 AA |
| `text_tertiary` | `#8A8A90` | 时长 · 次要元信息 | 4.62:1 AA |
| `text_disabled` | `#BDBDC4` | 禁用态 | — |
| `bg_divider` | `#E8E8EC` | 分隔线 | — |
| `progress_track` | `#E0E0E0` | 进度条轨道 | — |
| `state_success` | `#52C41A` | 下载完成 | — |
| `state_error` | `#D93026` | 下载失败 | — |
| `press_overlay` | `#0F000000` | 按压态遮罩（6% 黑） | — |
| `bg` | `#F5F5F5` | 页面底 | — |
| `surface` | `#FFFFFF` | 卡片 / 列表行 | — |

**旧值对照**（审计出的不达标灰，全部禁用）：
`#888888`(3.54) `#AAAAAA`(2.32) `#999999`(2.85) `#BBBBBB`(1.92) `#CCCCCC`(1.61)。

### 2.3 文字样式（六档，行高 1.4）

| 样式 | 字号/行高 | 字重 | 用途 |
|---|---|---|---|
| `display` | 24 / 33 | Medium | 播放页大标题（预留） |
| `title` | 20 / 28 | Bold | 页标题（搜索/歌单/下载/设置） |
| `heading` | 18 / 25 | SemiBold | 弹层标题「播放列表(4)」 |
| `body` | 16 / 22 | Regular | 列表歌名 · 开关行 · 歌词当前行 |
| `caption` | 13 / 18 | Regular | 歌手 · 时长 · 状态行 · 按钮文字 |
| `tag` | 11 / 15 | Medium | 底栏文字 · 徽章 |

**禁用字号**：12 / 14 / 15（相邻差值 < 1.18，肉眼不可辨）。

### 2.4 间距与圆角

| 组 | 值 |
|---|---|
| 间距 | `4 / 8 / 12 / 16 / 24 / 40`（一律 4 的倍数） |
| 圆角 | `8`（封面/小卡片）· `12`（卡片/弹层）· `999`（胶囊/按钮） |

### 2.5 尺寸常量

| 变量 | 值 | 来源 |
|---|---|---|
| `hit` | 44 | 最小触达（vp） |
| `bar-h` | 56 | 悬浮胶囊高度 |
| `bar-bottom` | 20 | 胶囊离底（+safeBottom） |
| `cover-list` | 48 | 列表封面 |
| `cover-mini` | 32 / 40 | 融合播放栏封面（展开/收起） |
| `ctrl-icon` | 16 / 20 | 播放栏控制键（侧/主） |
| `player-icon` | 26 / 44 | 播放页控制键（侧/主） |

---

## 3. 组件库（Figma Components）

> 命名用 `C1-C10` 编号 + 斜杠属性，方便按 Ctrl+Alt+O 组织。

### C1 · TabBar（底栏胶囊 · 不变更项 · 3 变体）

**容器**：390-32=358 宽 × 56 高，圆角 36，`Clip content`。
填充＝**四层叠加**（Figma 里一个 Frame 按顺序加）：
1. 底色 `rgba(255,255,255,0.78)`
2. Background blur（24, saturation 1.9）——用 Effect 面板的 Layer blur 不行，要 **Background blur**
3. 品牌光晕：内填 `brand` @ 12%（对应 `lightColor`）
4. Drop shadow `0 6 24 rgba(0,0,0,0.10)`

**变体 A `tabsOnly`**（队列为空）：右侧 4 个 `tabItem` 平分（Auto Layout space-between）。
**变体 B `collapsed`**：左侧加 40×40 圆盘封面（`cover-mini` 收起档）。
**变体 C `expanded`**：左侧换成「封面 32 + 歌名/歌手 + 三键」，与页签**同一行**
（`HdsBarLayoutMode.HORIZONTAL`）。宽度 HDS 按内容自适应，稿中 mini-text 限宽 96。

`tabItem` 结构：`Column(gap 2)[ Symbol 22, Text tag ]`，选中 `brand` / 未选中 `text_secondary`。
四个页签：搜索(magnifyingglass) · 歌单(list_bullet) · 下载(circle_and_arrow_down) · 设置(gearshape)。

### C2 · PlayBar（融合播放栏槽位 · 2 态）

| 态 | 内容 | 尺寸 |
|---|---|---|
| EXPAND | 封面32(圆) + Column[歌名12/Medium, 歌手10] + Row(gap 8)[prev16, pause20, next16] | 高 56，随胶囊 |
| COLLAPSE | 仅封面圆盘 40 | 同上 |

交互注记：收起态点圆盘 → `applyMiniBarStyle(EXPAND)`（不直接进播放页）；
展开态点整行 → 进播放页（geometryTransition 一镜到底，图层名须与播放页大封面一致：
`GEOMETRY_ID_PLAYER_DISC`）。

### C3 · TrackItem（列表条目 · 共享）

```
Row(gap 12, padding 16/16/10/4)          ← 右 4：给「⋯」的 44 热区让位
├─ Image 48×48 r8                         ← cover-list
├─ Column(gap 4, fill)
│  ├─ Text body(16) text_primary, 1 行省略
│  └─ Row(gap 8)
│     ├─ Text caption(13) text_secondary, fill, 1 行省略   ← 歌手
│     ├─ Text tag(11) brand-deep（可选：正在播放）
│     └─ Text caption(13) text_tertiary                    ← 时长
└─ Hit 44×44 居中「⋯」20px text_secondary  ← 命中区 44，视觉不变
```

**变体**：`default` / `playing`（+正在播放徽章）/ `noCover`（列表无封面）。
**按压态**：整行加 `press_overlay` 背景（Figma 用 Variant `pressed` 表达）。

### C4 · QueueSheet 行（队列条目）

`Row(gap 10, padding 24/12/8/8)[ 序号24 | 封面40 r6 | Column[题14, 歌手11] fill | ✕ 28×28 ]`
当前曲：序号位换 `waveform` 16px `brand`。
⚠️ 「✕」28×28 **低于触达标准**，落地时应撑到 44×44（本稿按代码现状绘制，
标注为待改项——见 §6 交接清单）。

### C5 · 设置行（SettingRow）

`Row(gap 12, padding 12/16)[ Column[lbl body(16), desc tag(11) text_tertiary] fill | 控件 ]`
控件 3 变体：`Switch(on/off)`（44×26，on 用 `brand`）· `Value+Chev` · 纯行。

### C6 · 分段 Pill（SegmentedPill · 2 变体）

`padding 6/14, r999, caption(13)`；
`default`：surface 底 + text_secondary；`on`：**brand 实底 + #3D0018 深字**（粉底上白字只有
2.60:1，深字 6.56:1——这是「粉色基调」下保持可读的写法）。

### C7 · 按钮（Button · 3 变体）

| 变体 | 样式 |
|---|---|
| `solid` | brand 实底 40 高 r20，字 body(16) #3D0018 |
| `tint` | brand-tint 底 32 高 r16，字 caption(13) brand-deep |
| `text` | 无底，字 caption(13) brand-deep（清空/新建/重试） |

### C8 · 进度条（ProgressBar · 2 态）

高 3 r2；`downloading`：填充 `brand`；`paused`：填充 `text_disabled`。轨道 `progress_track`。

### C9 · 空态（EmptyState）

`Column 居中 gap 8[ 插画48(brand-mid 描边), big body(16) ts, sub caption(13) tt, CTA cta-pill ]`
CTA＝brand 实底 r999，字 #3D0018。**必须带下一步动作**（「去搜索 ›」），
禁止只写「暂无数据」。

### C10 · HomeIndicator

134×5 r3 `rgba(0,0,0,0.28)`，浅底屏用；深底屏（播放页）换 `rgba(255,255,255,0.5)`。

---

## 4. 逐屏搭建（13 屏）

> 每屏给出 Auto Layout 层级树。`⌘` 内数字为间距。

### SP1 搜索页
```
SP1 (390×844, clip, vertical AL gap 0)
├─ StatusBar (47, 深色文字)
├─ TitleBar: "搜索" title(20/700) · padding 6/16/8
├─ SearchBox: brand-tint 底 r999 高40 · 图标18 brand · 占位 caption ts
├─ Seg: 4×SegmentedPill · gap 8 · padding 8/12
├─ List (fill): 6×TrackItem + Divider(bg_divider, 左缩进16)
└─ C1 TabBar (abs, bottom 54) · expanded 态
```

### SP2 歌单页
```
├─ StatusBar
├─ TitleBar: "歌单" + C7.text「新建」(brand-deep)
├─ SecTitle "最近播放" + 「全部 ›」caption ts
├─ HRow: 4×cover48 (横向 AL, padding 0/8)
├─ SecTitle "我的歌单"
└─ 3×TrackItem(歌单形态) + C1 TabBar collapsed
```

### SP3 下载管理
```
├─ TitleBar "下载管理" + 「多选」caption ts
├─ BtnRow: 2×C7.tint（全部开始/全部暂停）gap 8
└─ List: 4×DownloadRow（四态）
   DownloadRow = Row[cover48 | Column[题16, 状态13(色随态), Progress] | 尾部]
   尾部四态: done→✓(success) / ing→Hit44 trash / paused→Hit44 trash / err→「重试」brand-deep
```

### SP4 设置页
```
├─ TitleBar "设置"
├─ Group1: 自动播放下一首(Sw on) / 显示歌词(Sw on)
├─ SecTitle "下载" + Group2: 仅WiFi(Sw off) / 下载音质(Value+Chev)
└─ SecTitle "通用" + Group3: 主题 / 定时停止 / 缓存（均 Value+Chev）
```

### SP5 歌单详情（NavDestination 子页）
```
├─ NavBar: Hit44 返回 + "我喜欢的音乐" title(20/700) + Hit44 ⋯
├─ Head: 封面96 r12 + Column[名18/600, 「12 首」caption ts]
├─ C7.solid "播放全部"
└─ List: 3×TrackItem(playing 首行)
```

### SP6 最近播放（子页）
```
├─ NavBar: 返回 + "最近播放" + C7.text「清空」
└─ List: 3×TrackItem
```

### SP7 播放页 · 封面页（Swiper 第 1 页）
```
PlayerBG (fill, 渐变 165°: #7A2E52→#4A1B38→#24101F + 两团径向粉/紫光 55%)
├─ StatusBar (浅色文字)
├─ TopCast: 投播图标 24 白，右对齐 padding 0/24 · 高 48   ← 无返回键、无标题
├─ Content (fill, padding 0/24/24)
│  ├─ BigCover: aspect 1:1 r8 shadow(0 8 12 α25%) · margin-top 24
│  ├─ Info: 歌名 title(20/700) 白 90% + 歌手 14 白 60%
│  └─ Controls (贴底)
│     ├─ FnRow: repeat24 | list24（两端对齐）
│     ├─ Slider: 线3 α20% + 填充白86% + knob12 · times 10fp 白60%
│     └─ MainRow: prev26 | pause44 | next26（padding 0/36）
└─ Dots: 2 枚（第 1 枚亮）+ HomeIndicator(白 50%)
```

### SP8 播放页 · 歌词页（Swiper 第 2 页）
```
PlayerBG 同上
├─ TopCast
├─ LyricHead: 封面48 r8 + Column[题16/700, 歌手12 白60] · margin-top 48
├─ LyricBody (fill, 垂直居中 gap 16): 6 行 · 普通行 body(16) 白45% / 当前行 18 白100% Medium
└─ Controls 同 SP7
```

### SP9 播放列表弹层
```
├─ 遮罩 rgba(0,0,0,0.28)
├─ C1 TabBar（被弹层盖住亦可保留层级）
└─ Sheet (abs bottom 0, 高 520, r16 顶部, surface)
   ├─ Grabber 36×4
   ├─ Head(gap 8, padding 16/24/12): "播放列表(4)" heading(18/700)
   │   + C-ModePill(brand-tint 底 r12, brand-deep 字) + C7.text「清除列表」
   └─ 4×QueueRow（首行 waveform+封面+✕，其余 2/3/4）
```

### SP10 空态组
三联屏（各 1/3 高）：搜索无结果 / 歌单为空 / 下载无任务。全部带 CTA cta-pill。

### SP11 品牌色板
色板陈列屏：双粉 5 档 + 中性 4 档，每条含色块 56×40 / 名称 / HEX / 用途 / 对比度徽章。

### SP12 底栏规格（不变更基准）
三卡片（A 纯页签 / B 收起圆盘 / C 展开融合）+ 四参数注记
（IMMERSIVE / lightColor 12% / barOpacity 0.9 / barBottomMargin 20+safe）。

### SP13 易用性规格
44vp 热区示意（虚线圈叠在 TrackItem 与 DownloadRow 上）+ 按压态说明。

---

## 5. 原型连线（Prototype）

### Flow 1 · 底栏三态（SP12 演示）
```
A(tabsOnly) --加入歌曲--> B(collapsed) --点圆盘--> C(expanded) --点收起键--> B
```
动效 Smart animate 300ms EaseOut。

### Flow 2 · 播放页 Swiper 双页
```
SP7(封面) <--左右滑--> SP8(歌词)
```
**前提**：SP7 的 BigCover 与 SP8 的 LyricHead 封面若做共享元素，图层名须同为
`Disc`（对应 `GEOMETRY_ID_PLAYER_DISC`）。Swiper 用 Figma 的「水平滚动」区域模拟。

### Flow 3 · 迷你条 → 播放页（一镜到底）
```
SP1(C1.expanded 点整行) --> SP7
SP7(侧滑返回) --> SP1
```
Smart animate：把 SP1 底栏里的封面 32 图层与 SP7 的 BigCover 命名一致（`Disc`），
Figma 会自动补间尺寸与圆角（32圆 → 342方r8）。

### Flow 4 · 队列弹层
```
SP7(FnRow 的 list 键) --> SP9(sheet 上滑)  动效: Move In Bottom 300ms
SP9(点条目) --> SP7(切歌)                  SP9(点遮罩/下拉) --> SP7
```

### Flow 5 · Tab 切换
SP1↔SP2↔SP3↔SP4 底栏四页签互连，instant + 无动效（HdsTabs 实际是内容平移，可给 200ms）。

---

## 6. 交接清单（给开发 / 给后续设计）

### 6.1 本稿与代码的已知差异（落地时以代码为准 / 或改代码）

> 更新于 **2026-09-29 晚第二轮代码落地之后**。带 ✅ 的项已经在代码里改完了，别再让 AI 重复做。

| 项 | 稿中 | 代码现状 | 处理建议 |
|---|---|---|---|
| 「清除列表」13px 粉字 | `brand-deep` | 仅剩下 `QueueSheet` 一处为 `bili_pink` | 属播放页，**用户明确不动**，其余页面 ✅ 已改完 |
| 六个常规页白底粉字（删除/全选/清空/页签选中…） | `brand-deep` | ✅ 已全部换成 `brand_deep` | 已完成，无需处理 |
| QueueSheet「✕」热区 | 44×44 | 28×28 | 属播放页，**用户明确不动**，暂保持 |
| 粉底按钮文字 | `#3D0018` | ✅ 已改（`新建`/`播放全部`/`保存` 共 5 处） | 已完成；原来全是默认白字 2.60:1 |
| 旧灰阶 `#888888` 等 52 处 | 三档中性 token | ✅ **全工程已清零** | 已完成，无需处理 |
| 12/14/15 三档字号 | 六档字阶 | ✅ 常规页已清零 | 已完成；播放页未动 |
| 下载行「重试」 | brand-deep 文字 | —（代码为空态文案） | 新增，未做 |

### 6.2 图标对照表（稿中 SVG ↔ 代码 sys.symbol）

| 稿中 | 代码资源 |
|---|---|
| 放大镜 | `sys.symbol.magnifyingglass` |
| 列表 | `sys.symbol.list_bullet` |
| 下载圈 | `sys.symbol.circle_and_arrow_down` |
| 齿轮 | `sys.symbol.gearshape` |
| 上一首/下一首 | `backward_end_fill` / `forward_end_fill` |
| 播放/暂停（三角圆） | `play_round_triangle_fill` / `pause_round_triangle_fill` |
| 垃圾桶 | `sys.symbol.trash` |
| 关闭 | `sys.symbol.xmark` |
| 播放中波形 | `sys.symbol.waveform` |
| 循环/随机 | `repeat` / `repeat_1` / `shuffle` / `arrow_right`(顺序) |
| 投播 | `AVCastPicker` 组件（非符号，开发用系统组件） |

### 6.3 开发标注要点

1. **底栏四参数**永不改：`IMMERSIVE`（支持时 EXQUISITE）· lightColor `#FB7299 α12%` ·
   barOpacity `0.9` · barBottomMargin `20+safeBottom`。
2. **触达**：所有 Hit44 用外层容器撑（`width(44).height(44).justifyContent(Center)`），
   视觉图标不放大；相邻不同语义热区间留 8vp。
3. **按压态**：`stateStyles({ pressed: press_overlay, normal: Transparent })`，
   不改布局不引节点。
4. **字阶**：只有六档，`fontSize(12|14|15)` 都是违规值。
5. **粉色**：白底小字用 `brand-deep`，`brand` 只进图标/实底/大字号。

### 6.4 待办（下一轮代码落地）

> 2026-09-29 晚已完成第二轮落地，范围＝六个常规页；**播放页 / 迷你条 / 队列弹层按用户要求全程未动**。

已完成 ✅

- [x] 全工程旧灰阶替换（`#888888`×19 等 52 处 → 三档 token）—— **现已清零**
- [x] 六个常规页字阶收敛（12/14/15 消失，只剩 11/13/16/18/20）
- [x] 白底粉字换 `brand_deep`（SearchPage / DownloadsPage / SettingsPage / RecentPage 等）
- [x] 粉底按钮补 `brand_on` 深字（5 处）
- [x] `⋮` 及下载页操作行热区 44vp 化 + 按压态

未完成 ⬜

- [ ] `QueueSheet`「✕」44vp 化、`SearchPage`/`DownloadsPage` 剩余小控件
      —— 前两项属播放页，用户明确不动
- [ ] `DownloadsPage` / `Index` 补 Toast 统一封装（操作结果回执覆盖不全）
- [ ] 各页空态补 CTA（SP10 规格）
- [ ] 下载行「重试」按钮（稿中有、代码无）
