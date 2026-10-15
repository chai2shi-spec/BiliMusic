# BiliMusic · 给 AI 下任务的提示词模板

> 用途：把「改 BiliMusic 的某个功能」这件事，交给 AI（本工具或其它模型）时，  
> 用一份结构化的描述，避免它改错方向、臆造资源名、或谎报"已完成"。  
> 路径与规则均取自本工程真实状态，可直接复制。

---

## 0. 为什么这么写（三要素）

AI 不会"懂"你的项目。缺下面任何一条，它都会自作主张：

| 要素         | 解决什么         | 不写的后果                      |
| ---------- | ------------ | -------------------------- |
| ① **边界**   | 哪些文件/参数绝对不许动 | 它去"顺手优化"播放页（代码最复杂，它最爱动）    |
| ② **真相来源** | 以哪份文件为唯一准绳   | 它臆造 `app.color.xxx`，直接编译失败 |
| ③ **验收判据** | 怎么算做完        | 它报"改好了"，但从未编译过             |
| ④ **任务**   | 具体要做什么       | 一次塞太多，出问题无法定位              |

**一次只给一件事**。做完一件、编译通过、再给下一件。

---

## 1. 通用提示词模板（复制这段）

```text
# 项目
HarmonyOS 音乐播放器，原生 ArkTS + ArkUI。
工程根：E:/BiliMusic/HarmonyOS-Phone（注意不是 E:/BiliMusic）
HarmonyOS 7 / API 26，bundleName com.chai.bilimusic

# 先读这些，按顺序，别跳
1. .workbuddy/memory/MEMORY.md —— 主铁律 + 各分册指针
2. .workbuddy/memory/UI-LAYOUT.md —— 动 UI / 安全区 / 进度条前必读
3. design/BiliMusic-设计规范.md —— 色彩/字阶/触达/动效硬规范（含 grep 验收判据）
4. entry/src/main/resources/base/element/color.json —— 唯一有效的颜色资源名来源

# 绝对不许动
- pages/PlayerPage.ets 及 components/player/*（播放页全家桶）
- components/PlayBar.ets（迷你条）
- components/QueueSheet.ets（队列弹层）
- 底栏 HdsTabs 四个参数：IMMERSIVE 材质 / lightColor #FB7299 α12% /
  barOpacity 0.9 / barBottomMargin 手势 6+safeBottom×0.5、三键 6+safeBottom
- 不新增页面、不改导航结构

# 硬规则
- 颜色一律走 $r('app.color.xxx')，资源名以 color.json 为准，禁止臆造
- 字号只用 11/13/16/18/20/24 六档
- 触达区 ≥44vp：视觉可以小，用外层 width(44).height(44) 撑命中区
- ArkTS 严格模式，不许出现 any / unknown / Function

# 编译验收（必须，不跑不算完）
cd /e/BiliMusic/HarmonyOS-Phone
touch <你改过的文件>   # hvigor 有增量缓存，不 touch 会整体跳过 CompileArkTS
hvigorw assembleHap --mode module -p product=default --no-daemon
判据 = CompileArkTS Finished + ArkTS ERROR 0 + BUILD SUCCESSFUL

# 任务（占位，替换成下面片段库里的某一条）
<在此粘贴具体任务>

# 交付格式
每处改动说清：改了哪个文件、为什么、编译结果。
禁止改动上面「不许动」清单里的任何内容，禁止顺手优化未列出的地方。
```

---

## 2. 场景变体

### A. AI 能读本地文件（如本工具）

给**路径**即可，别贴代码——贴了反而让它忽略周边上下文。

```
工程在 E:/BiliMusic/HarmonyOS-Phone，先读 design/BiliMusic-设计规范.md 再动手。
```

### B. AI 看不到文件（普通对话窗口）

把「真相来源」的**内容**贴进去，再附一句断言：

```
以下是当前真实代码，不要凭常识推断或补全：
--- color.json ---
<粘贴全文>
--- 要改的文件 ---
<粘贴全文>
--- 规则 ---
<粘贴 design/BiliMusic-设计规范.md 的规则段>
```

> 关键永远是那条硬声明：**「这是当前真实代码，不要凭常识推断」。**  
> 缺了它，模型会按"一般鸿蒙项目长什么样"来改，而不是按你的工程。

---

## 3. 常见翻车点（写给未来的自己）

1. **没给「不许动」清单 → 它改了播放页**。播放页代码最复杂、最"值得优化"，  
   不明确禁止，AI 几乎必然去动。这是踩过的。
2. **没给「真相来源」→ 它臆造资源名**。Figma 说明书里我起过 `brand-tint2` / `brand-mid`，  
   `color.json` 里根本没有，照抄直接 `resource not found`。
3. **没给验收判据 → 它谎报完成**。而且 hvigor 有**增量缓存**，  
   不 `touch` 改过的文件，`CompileArkTS` 会被整体跳过，产出**假的 BUILD SUCCESSFUL**。
4. **一次塞多个任务 → 无法定位**。改 3 个文件后编译失败，你不知道是哪个改坏的。
5. **把「优化空间」当成「一定要全做」**。P2 级（日志/i18n）在中文-only 场景其实可接受，  
   别为了清单好看去动它。

---

## 4. 任务片段库（可直接摘用）

### 性能

```text
P0-1 给列表 ForEach 补 keyGenerator：
  PlaylistDetail（this.playlist.tracks）/ RecentPage（this.tracks）/
  QueueSheet（this.queue）/ DownloadsPage 外层分组（buildGroups()）/
  SearchPage 多处。
要求：key 能唯一标识条目身份；含选中态的列表 key 必须带上选中状态。
（缺 key 时 ArkUI 按 index 复用节点 → 删中间项会导致状态错位 + 全量重建）
```

```text
P0-2 封面图按需裁剪：
  改 utils/TextUtil.ts，在 toHttpsUrl 返回前追加 B 站尺寸后缀
  （列表缩略图 @320w_320h，播放页大图放宽）。
验证：拼出的 URL 仍能 200 加载；已有的 https 转换逻辑不能被破坏。
（现状：toHttpsUrl 只换协议，574KB 的视频截图当 44px 缩略图用）
```

```text
P0-3 长列表改 LazyForEach（改动大，单独一轮）：
  为候选列表实现 IDataSource（或项目内已有的 DataSource 封装），
  替换 ForEach，保留现有 ListItem 结构与 key 语义。
```

### 体验与健壮性

```text
P1-1 Image 补 alt / onError：
  11 处裸 Image(url) 增加加载占位与失败兜底（失败时给浅粉占位块，不要留白）。
```

```text
P1-2 同步读挪出首屏：
  SettingsPage 的 @State settings = AppPreferences.getSettings() 与
  LibraryStore.getRecentTracks() 的同步 getSync + JSON.parse 移到异步/延迟执行。
  参照同文件里「缓存统计已用 setTimeout 规避」的既有做法。
```

```text
P1-3 DownloadsPage.buildGroups() 目前写在 ForEach 参数里，每帧重算分组。
  提到 @State 缓存，在 tasks 变化时更新。
```

### 设计规范（改 UI 时摘用）

```text
触达：视觉可以小，命中区必须 ≥44vp。
写法 = 外层 Row().width(44).height(44).justifyContent(Center) 包住小图标，
相邻不同语义热区间留 8vp 缓冲。
```

```text
粉色：视觉主色 #FB7299 只用于大字号(≥18px)/图标/实底填充；
白底粉字一律改 brand_deep #C2185B（5.81:1）；粉底按钮文字用 #3D0018 深字，不用白字。
```

```text
字号只用六档 11/13/16/18/20/24，行高 1.4；禁用 12/14/15。
文字灰阶只用 text_primary / text_secondary / text_tertiary 三档 token。
```

---

## 5. 成品示例：下一轮优化方向（可直接复制）

> 场景：上一轮已落地「ForEach 补 key / 缩略图裁剪 / LazyForEach / Image 兜底 /
> 同步读 / buildGroups 缓存」（编译实跑 17s，BUILD SUCCESSFUL，ERROR 0）。
> 本轮为**新发现的六项**。**投递时按条拆开**，只保留一条任务块。

### 5.1 三条前置勘误（AI 自己扫会误判，直接写给它）

| 容易误判为 | 实际是 |
|---|---|
| `SearchPage` 四个结果列表缺 keyGenerator | **已有** `(t: Track): string => t.id`，本条是 `ForEach → LazyForEach` |
| 搜索结果可直接套 `ArrayDataSource` | 该类只有 `reload()`（整表替换），而搜索是**增量追加**（`mergeTracks`）→ 直接套会踩它自己注释里写的坑 |
| 网络监听还缺权限 | `ohos.permission.GET_NETWORK_INFO` **已在 `module.json5:31` 声明**，不用加 |

### 5.2 完整提示词（一次看清全貌，实投按条拆）

```text
# 项目
HarmonyOS 音乐播放器，原生 ArkTS + ArkUI。
工程根：E:/BiliMusic/HarmonyOS-Phone（不是 E:/BiliMusic）
HarmonyOS 7 / API 26，bundleName com.chai.bilimusic

# 先读这些，按顺序
1. .workbuddy/memory/MEMORY.md
2. .workbuddy/memory/UI-LAYOUT.md
3. design/BiliMusic-设计规范.md
4. entry/src/main/resources/base/element/color.json（唯一有效的颜色资源名来源）

# 绝对不许动
- pages/PlayerPage.ets 及 components/player/*（播放页全家桶）
- components/PlayBar.ets（迷你条）
- components/QueueSheet.ets（队列弹层，**它是列表，改 LazyForEach 时最容易被顺手带上**）
- 底栏 HdsTabs 四个参数：IMMERSIVE 材质 / lightColor #FB7299 α12% /
  barOpacity 0.9 / barBottomMargin 手势 6+safeBottom×0.5、三键 6+safeBottom
- 不新增页面、不改导航结构

# 硬规则
- 颜色一律走 $r('app.color.xxx')，资源名以 color.json 为准，禁止臆造
- 字号只用 11/13/16/18/20/24 六档
- 触达区 ≥44vp：视觉可以小，外层 width(44).height(44) 撑命中区
- ArkTS 严格模式，无 any / unknown / Function

# 编译验收（必须，不跑不算完）
cd /e/BiliMusic/HarmonyOS-Phone
touch <你改过的文件>   # hvigor 有增量缓存，不 touch 会整体跳过 CompileArkTS
hvigorw assembleHap --mode module -p product=default --no-daemon
判据 = CompileArkTS Finished（且耗时不接近 0，说明没被缓存跳过）
      + ArkTS ERROR 0 + BUILD SUCCESSFUL

# 任务
一次只做一条，改完立即编译，通过后再做下一条。

【P0-1】搜索结果请求竞态保护（最小改动，先做）
  文件：pages/SearchPage.ets
  现状：private async doSearch()（约 695 行）无请求序号；调用点 472 / 947 / 966 / 1298 / 1407。
  做法：加私有成员 `private searchSeq: number = 0`；进入后 `const seq = ++this.searchSeq`；
    在 await 返回、写 this.results 之前判 `if (seq !== this.searchSeq) return;`
    catch 分支同样要判，避免失败的旧请求把 this.loading 置回 false。
  不要改搜索触发方式（已确认是 onSubmit/按钮触发，不是逐字发请求，无需防抖）。
  验收：快速连搜两次不同关键词，最终显示的是**后发**那一次的结果。

【P0-2】搜索结果列表改 LazyForEach（先判断，别直接套）
  文件：pages/SearchPage.ets 四个列表（都已带 key `t.id`）：
    999  this.results（搜索） / 1014 this.recommend（推荐）
    1029 this.ranking（排行） / 1044 this.center（音乐中心）
  ⚠️ 前提：utils/ArrayDataSource.ets 只有 `reload(items)`（整表替换）。
    而搜索/推荐/音乐中心是**增量追加**（586/609/637 行 mergeTracks），
    排行是 slice(0, next) 截取（627）。对增量场景用 reload() 会整表重建 + 丢滚动位置，
    比现状更差。两条路择一并说明理由：
    (A) 给 ArrayDataSource 补增量 API：addAll(items) / push(item)，
        内部用 listener.onDataAdd(index) / onDataChanged(index) 精确通知
        （新增方法，不影响已有 PlaylistDetail/RecentPage 用法）；
    (B) 维持 ForEach（已有稳定 key，中等长度列表可接受），只给结论不改代码。
  ⚠️ QueueSheet 也是列表但**不许动**。

【P1-3】断网监听与恢复
  文件：utils/NetworkUtil.ts（现只有一次性 getDefaultNetSync 探测）
  做法：connection.createNetConnection() + on('netAvailable'/'netLost')，
    在 pages/Index.ets aboutToAppear 注册、aboutToDisappear 用 unregister 成对注销
    （**必须成对**，参考现有的动画器/媒体查询监听清理写法）。
    仅在断网时给一次全局 toast；恢复时若当前页处于失败态，触发一次重试。
  权限：GET_NETWORK_INFO 已在 module.json5:31 声明，无需新增。
  验收：飞行模式来回切不闪退；页面离场后监听回调不再触发。

【P1-4】无障碍标签（价值最高，逐个加）
  现状：全工程 accessibilityText 为 **0 处**。
  范围**仅限**这 8 个文件：
    pages/{SettingsPage,SearchPage,PlaylistsPage,PlaylistDetail,RecentPage,DownloadsPage}.ets
    components/TrackItem.ets、components/CoverImage.ets
  给纯图标控件补 accessibilityText（描述**动作**，不描述图形）：
    TrackItem 的「⋯」(onMore)         → '更多操作'
    DownloadsPage 的 trash SymbolGlyph → '删除'
    DownloadsPage 的 ✓                 → '已完成'
    PlaylistsPage / PlaylistDetail 的「⋮」 → '更多操作'
    CoverImage                        → 新增可选参数传入歌名/歌单名
  再用 accessibilityLevel('yes') 标可聚焦、装饰性元素标 'no'。
  ⚠️ 不许动：底栏 HdsTabs 页签、components/player/* 播放控制、PlayBar、QueueSheet。

【P2-5】补单元测试
  现状：entry/src/ 下**只有 main**（无 ohosTest / test）；
    entry/build-profile.json5 的 targets **只有 default**；
    @ohos/hypium 1.0.19 声明在**根** oh-package.json5（不在 entry 侧）。
  做法：按 DevEco 标准结构新建 entry/src/ohosTest/（含 module.json5），targets 加 ohosTest；
    先跑通一个空测试确认测试任务可用，再覆盖：
      utils/TextUtil.ts 的 cleanTitle(62) / parseLrc(148) / scoreCandidate(254)
      lyric/LrcUtils.ets 的 parseLrcLyric(25)
    DownloadsPage.buildGroups 是页面内私有方法，要测需先提成可导出纯函数，属额外改动，本次不做。
  ⚠️ 本机未验证过 hvigor 的测试任务名，开工前先确认（hvigorw --help 或 DevEco 测试配置）。

【P2-6】收尾：残留同步读
  pages/PlaylistsPage.ets:53-54  aboutToAppear 里同步 getPlaylists() + getRecentTracks().length
  pages/SearchPage.ets:830 与 862  同一次流程把 getPlaylists() 读了**两遍** → 合并为一次
  参照 SettingsPage 既有做法（缓存统计已用 setTimeout 把同步 IO 挪出首屏）。

# 交付格式
每条说明：改了哪个文件、为什么、编译结果。禁止改动「不许动」清单，
禁止顺手优化未列出的地方。
```

### 5.3 拆条投递的建议顺序

| 顺序 | 条目 | 理由 |
|---|---|---|
| 1 | P0-1 搜索竞态 | 改动最小（约 4 行），风险最低，效果可感知 |
| 2 | P0-2 LazyForEach | 需先做方案判断，单独一轮 |
| 3 | P1-3 断网监听 | 涉及生命周期，必须成对注销，单独验证 |
| 4 | P1-4 无障碍 | 价值最高但要逐个控件加，排独立一轮 |
| 5 | P2-5 单测 | 要先补工程结构，独立一轮 |
| 6 | P2-6 收尾 | 顺手做掉 |

---

## 6. 成品示例：第三轮（四个新领域）

### 6.1 四条方向的实际核实结果 —— **两条要撤回**

> 这四条是在**只扫引用、没看实现**的情况下得出的，逐条核实后有两条不成立。
> 我把勘误写在最前面，因为 AI 自己扫代码会得出**和我一样的错误结论**。

| 原判断 | 核实结果 | 证据 |
|---|---|---|
| ① 常规页零响应式，`BreakpointSystem` 只被播放页 3 个组件订阅 | ❌ **错，已完整铺开** | `pages/Index.ets:215` 全局 `register` 一次写 AppStorage；8 个常规页 + `PlayBar` + `AboutPage` 全部 `@StorageProp(BreakpointConstants.CURRENT_BREAKPOINT)` 订阅，并挂 `.constraintSize({ maxWidth: contentMaxWidth(bp) })` |
| ② 字体不跟随系统缩放（0 处 `fp`） | ❌ **错，本来就跟随** | SDK `component/text.d.ts:136` 原文：*"If fontSize is of the number type, the unit **fp** is used"*。128 处 `fontSize(16)` 全是 fp，**不缺 fp** |
| ③ 底栏连带留白未跟改 | ✅ **成立，且比预想更严重** | `common/Constants.ts:141` `CONTENT_END_OFFSET = 160`，其推导注释写的是**已废弃的两行结构**（详见下） |
| ④ 冷启动串行 await | ✅ **成立** | `service/AppContainer.ts:18-19` 两个无依赖的 `await` 串行 |

**撤回 ① 的正确表述**：不要重做响应式。但有一个**新发现**——`entry/src/main/module.json5` 的
`"deviceTypes": ["phone"]`，而 `BreakpointConstants` 里写着 `CONTENT_MAX_WIDTH_LG = 720`、
`COLUMN_LG = 12`、`COLUMN_LYRIC_LG = 7` 一整套平板栅格。平板需 `tablet` 类型，**装不上**
→ **lg 分支永远不执行**。（折叠屏展开走 `md`，折叠屏属 `phone`，是有效的。）

**撤回 ② 的正确表述**：真实问题不是"不缩放"，而是**"缩放无上限保护"** ——
全工程 0 处 `maxFontScale` / `minFontScale`。HarmonyOS 系统字体最大可调到 3.2 倍，
而列表行、底栏胶囊、按钮都是固定高度容器，超大字号下会**截字或撑破版式**。

### 6.2 完整提示词（复制这段）

```text
# 项目
HarmonyOS 音乐播放器，原生 ArkTS + ArkUI。
工程根：E:/BiliMusic/HarmonyOS-Phone（不是 E:/BiliMusic）
HarmonyOS 7 / API 26，bundleName com.chai.bilimusic

# 先读这些，按顺序
1. .workbuddy/memory/MEMORY.md
2. .workbuddy/memory/UI-LAYOUT.md
3. .workbuddy/memory/PLAYER-KERNEL.md      ← 本轮涉及 player/，必读
4. design/BiliMusic-设计规范.md
5. entry/src/main/resources/base/element/color.json（唯一有效的颜色资源名来源）

# 绝对不许动
- pages/PlayerPage.ets 及 components/player/*（播放页全家桶）
- components/PlayBar.ets（迷你条）
- components/QueueSheet.ets（队列弹层）
- 底栏 HdsTabs 四参数：IMMERSIVE 材质 / lightColor #FB7299 α12% / barOpacity 0.9 /
  barBottomMargin = 6 + safeBottom×0.5（手势导航）或 6 + safeBottom（三键导航）
- 不新增页面、不改导航结构
- player/MusicPlayer.ts 本轮只允许改「初始化调用顺序」一处，且改前必读 PLAYER-KERNEL.md；
  不许改播放逻辑、换源、AVSession、预取

# 本轮特别提醒（不看会做错）
- 不要重做响应式布局：BreakpointSystem 已完整铺开（Index 注册一次 + 8 个常规页
  @StorageProp 订阅 + constraintSize），再加一遍是重复劳动
- 不要给 fontSize 补 fp 单位：数字形式默认单位就是 fp，本来就跟随系统缩放
- 判断资源/装饰器是否缺失时，**要看值不能只看数量**（本项目已因此误判过两次）

# 硬规则
- 颜色一律走 $r('app.color.xxx')，资源名以 color.json 为准，禁止臆造
- 字号只用 11/13/16/18/20/24 六档
- 触达区 ≥44vp：视觉可以小，用外层 width(44).height(44) 撑命中区
- ArkTS 严格模式，无 any / unknown / Function

# 编译验收（必须，不跑不算完）
cd /e/BiliMusic/HarmonyOS-Phone
touch <你改过的文件>   # hvigor 有增量缓存，不 touch 会整体跳过 CompileArkTS
hvigorw assembleHap --mode module -p product=default --no-daemon
判据 = CompileArkTS Finished + ArkTS ERROR 0 + BUILD SUCCESSFUL

# 任务
一次只做一条，改完立即编译，通过后再做下一条。

【P0-1】冷启动并行化（改动最小，先做）
  文件：service/AppContainer.ts（init 方法，约 18-19 行）
  现状：
    await initPreferences(context);
    await initRdb(context);
  两者**无依赖**：initPreferences 只开 preferences 库（AppPreferences.ts:32），
  initRdb 只开 RDB 并建表（RdbHelper.ts:24-29），互不读对方。
  做法：改为 Promise.all([initPreferences(context), initRdb(context)])。
  ⚠️ 必须保持在其后的顺序，不许挪：
    initBuvidCookie()  必须在 MusicPlayer.init 之前（注释：缺 buvid 首页推荐会被 412 拦）
    await MusicPlayer.getInstance().init(context)  要 createAVSession + activate，耗时长且独立
    upgradeBuvidCookie()  保持不 await（注释已说明：本地兜底值已够用，不能拖慢启动）
  验收：编译通过；冷启动日志里 preferences 与 RDB 初始化时间戳应基本重叠（非先后）。

【P1-2】超大字号破版保护
  现状：全工程 0 处 maxFontScale / minFontScale（grep 确认）。
  系统字体最大 3.2 倍，以下固定高度容器在超大字号下会截字：
    - components/TrackItem.ets 的列表行（标题 16 + 副行 13 撑在固定行高里）
    - pages/Index.ets 底栏胶囊（HdsTabs 固定高度）
    - pages/DownloadsPage.ets 的操作行（5 个文字按钮 height(44)）
  做法（择一，说明理由）：
    (A) 给上述文本加 .maxFontScale(1.5) 左右的上限（ArkUI 属性，逐控件加）
    (B) 只给底栏与固定高按钮加，列表行允许换行
  ⚠️ 本机未验证过 maxFontScale 的可用版本与精确签名，动手前先在 SDK 里核实：
    grep -rn "maxFontScale" "E:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/component/"
  验收：系统字体调到最大后，底栏文字不截断、按钮文字不溢出。

【P0-3】修正 CONTENT_END_OFFSET 的过时推导（⚠️ 先真机实测，不许直接改值）
  文件：common/Constants.ts:141，值 160
  过时点：它的推导注释（132-136 行）写的是**已废弃的两行结构**：
    「离底 20 + 胶囊高 56 + 与底栏间距 8 + 底栏高 56 = 140，再留 20 余量」
  但底栏现在是**融合胶囊**（播放栏与页签同一行，HdsTabs miniBar 槽位），
  只剩一条；且 Index.ets:99 的 BAR_BOTTOM_MARGIN 已从 20 改为 6。
  → 注释与值双双过时，列表末尾很可能多出几十 vp 空白。
  使用处：DownloadsPage.ets:1161 / PlaylistsPage.ets:265 / SearchPage.ets:1133 /
    SettingsPage.ets:810，均为 .contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)
  做法：**先测真机**——列表滚到底，量最后一项底边到胶囊顶边的实际空隙，
  再按「胶囊离底 + 胶囊实测高度 + 8 余量」重算，同步更新注释。
  不许拍脑袋改数字；HDS 浮动栏没有公开高度常量，56 是当初的假设值。

# 交付格式
每处改动说清：改了哪个文件、为什么、编译结果。
禁止改动上面「不许动」清单里的任何内容，禁止顺手优化未列出的地方。
```

### 6.3 拆条投递的建议顺序

| 顺序 | 条目 | 理由 |
|---|---|---|
| 1 | P0-1 冷启动并行 | 改动约 2 行、纯逻辑、编译即可验证，最干净的第一步 |
| 2 | P1-2 字号破版保护 | 需先核实 API 签名，但覆盖所有固定高容器 |
| 3 | P0-3 底部留白 | **必须真机实测**，无法在 CLI 里验证，只能你来量 |
| — | 决策项：`deviceTypes` 是否加 `tablet` | 不是代码任务，见 §6.4 |

### 6.4 一个留给你的决策（不要直接交给 AI）

`entry/src/main/module.json5` 的 `"deviceTypes": ["phone"]` 与代码里整套 lg 断点适配**不一致**。
两条路，得你定：

- **补 `"tablet"`** —— 开启平板，lg 断点（`CONTENT_MAX_WIDTH_LG = 720`）与
  歌词区 7 列栅格（`COLUMN_LYRIC_LG`）才会真正生效。但平板布局从未验证过，
  等于新开一个适配面。
- **维持只有 `phone`** —— 那么代码里的 lg 分支（`PlayButtonComponent` /
  `TopAreaComponent` 等的 lg 判断、`COLUMN_LG = 12`）属于**死代码**，
  可考虑保留（成本为零、将来想开随时开）或标注说明。

我倾向**维持现状但补一条注释**说明「lg 断点已实现、未开放 tablet」，
免得以后有人看到 lg 代码以为应用支持平板。

---

## 7. 成品示例：加载动效五方案

### 7.1 先看清「已经有什么」—— 不然 AI 会把骨架屏重做一遍

加载态的底子其实已经打了一半，**这五条里有三条是补缺口、两条是升级现有**：

| 位置 | 现状（已实现） | 缺口 |
|---|---|---|
| 列表首屏 | `components/SkeletonTrackItem.ets` —— 40 圆 + 两条文字条骨架（**扫光带 2026-10-02 已按用户反馈删除**，现为纯静态占位 + 入场错峰） | 内容到达是**硬切**，无落位淡入 |
| 分页「加载更多」 | 复用 `SkeletonTrackItem`，3 行同构骨架（`SearchPage.ets:1105` 附近） | 同上 |
| 图片 | `components/CoverImage.ets` 三态：加载中浅粉底 / 失败音符 / 空 url 占位 | 无呼吸、无淡入 |
| 空态 · 失败态 | `SearchPage.HomeStateArea()`（含「点击重试」） | 无任何动效，纯静态文字 |
| 下载中（大小未知） | 系统 `LoadingProgress()` 18×18 粉色（`DownloadsPage.ets:884/1029`） | 未品牌化，与别处语言不统一 |
| 下拉刷新 | 系统 `Refresh({refreshing: $$this.refreshing})` | 默认样式，未品牌化 |
| 页面级 / 切页签 | **无** | `transition(` 全工程仅 1 处，无任何进度反馈 |

**⚠️ 不要给 `SkeletonTrackItem` 加回扫光**：其扫光带（品牌粉渐变高光带横扫）已于
2026-10-02 按用户反馈整体删除——刷新头 / 首屏 / 加载更多三处都被反馈「粉色竖条
来回走，像杂音」。旧实现踩过的坑仍有参考价值（`translate` 声明在 `.animation()`
之前、`onAreaChange` 量宽后点火、粉光而非白光），但结论是**骨架屏保持纯静态**。

### 7.2 五个方案对照

> **它们不是五选一，而是分属不同层级，可以全做。** 若只做一个，选 A。

| 方案 | 场景 | 关键参数 | 成本 |
|---|---|---|---|
| **A 骨架错峰入场** | 列表首屏 + 分页追加 | 逐条延迟 70ms 上浮淡入（位移 8vp，250ms EaseOut）；**只做首屏 ≤6 条**；内容到达再做一次落位淡入 | 低（改 2 处） |
| **B 三点脉冲** | 按钮内加载、搜索建议、短内容区 | 3 点，周期 900ms，相位差 150ms，scale 0.55↔1 + opacity 0.3↔1 | 极低（新组件约 60 行） |
| **C 顶部流光进度条** | 页面级加载、切页签、下拉刷新 | 3vp 粉线，`scaleX` 冲 76% 后停住等真实进度，完成冲刺 100% 并淡出 | 中（需状态机 + 放 `Index.ets` 顶层） |
| **D 音频柱律动** | 空态、加载态的品牌化替代 | 5 根柱，周期 800ms，相位差 100ms，`scaleY` 0.28↔1，锚点在底 | 低（新组件） |
| **E 封面呼吸光晕**（已废弃，见下） | ~~大图加载~~ | ~~粉晕 `scale` 0.82↔1.25 + `opacity` 0.18↔0.5，周期 1800ms~~ | — |

### 7.3 完整提示词（复制这段）

```text
# 项目
HarmonyOS 音乐播放器，原生 ArkTS + ArkUI。
工程根：E:/BiliMusic/HarmonyOS-Phone（不是 E:/BiliMusic）
HarmonyOS 7 / API 26，bundleName com.chai.bilimusic

# 先读这些，按顺序
1. .workbuddy/memory/MEMORY.md
2. .workbuddy/memory/UI-LAYOUT.md
3. design/BiliMusic-设计规范.md（§6 动效规范）
4. design/AI-提示词模板.md 的 §7.1「已经有什么」—— 决定哪些不要重做

# 绝对不许动
- pages/PlayerPage.ets 及 components/player/*（播放页全家桶）
- components/PlayBar.ets（迷你条）
- components/QueueSheet.ets（队列弹层）
- 底栏 HdsTabs 四参数：IMMERSIVE / lightColor #FB7299 α12% / barOpacity 0.9 /
  barBottomMargin = 6 + safeBottom×0.5（手势）或 6 + safeBottom（三键）
- 不新增页面、不改导航结构

# 已有资产，只准增强不准重写
- components/SkeletonTrackItem.ets 的扫光带已删除（2026-10-02 用户反馈），**不要加回**；
  组件其余部分（占位形状、入场错峰）按需增强。
- components/CoverImage.ets 的三态兜底已完整，改动只加动效。

# 动效技术红线（本项目已验证的做法）
- 循环动画**按「要不要中途停」分流**（2026-10-02 核实更正：上一版说「不要用
  iterations:-1」是错的——`SkeletonTrackItem` 扫光曾长期用它且工作正常，
  该扫光现已按用户反馈删除，但这个结论仍成立）：
    · **需要随状态启停**（如刷新中旋转、播放态旋转）→ 照
      components/player/PlayButtonComponent.ets 的既有模式写：
        - private xxxGen: number  —— 代际，防旧链继续跑
        - private xxxTimer: number = -1 —— setTimeout 句柄
        - animateTo 驱动属性变化 + setTimeout 递归调度
        - aboutToDisappear 里 clearTimeout 并把句柄置 -1
        - 需要立即停时用 animateTo({duration: 0}) 顶掉在途动画
    · **一直转、无需中途停** → 可用隐式
      `.animation({ duration, curve: Curve.Linear, iterations: -1, playMode: PlayMode.Normal })`。
      （历史先例 `SkeletonTrackItem` 扫光带已删除、勿仿照加回；写法要点仍成立：需**一次
      状态变化点火**，且 `translate` 必须声明在 `.animation()` **之前**——声明在之后
      会被接管、扫光不动。）
- 相位差用**初始延迟**错开（点 i 的延迟 = i × 步长），不要靠不同起点值蒙。
- 只动 `transform` / `opacity` / `scale` / `translate`，**不要动 width/height**
  （进度条增长用 scale + 左对齐锚点，不是改 width）。
- ⚠️ `.animation()` 与 `delay` 在无限循环下能否形成稳定相位差，**先在本机预览器验证**；
  不稳定就退回上面 PlayButtonComponent 的 setTimeout 链模式。
- 时长沿用设计规范 §6 分档（微反馈 150 / 小过渡 250 / 页面级 400 / 循环 1200 / 呼吸 1800），
  不要引入新数值。

# 编译验收（必须，不跑不算完）
cd /e/BiliMusic/HarmonyOS-Phone
touch <你改过的文件>   # hvigor 有增量缓存，不 touch 会整体跳过 CompileArkTS
hvigorw assembleHap --mode module -p product=default --no-daemon
判据 = CompileArkTS Finished + ArkTS ERROR 0 + BUILD SUCCESSFUL

# 任务
一次只做一条，改完立即编译，通过后再做下一条。

【P0-A】骨架错峰入场 + 落位淡入（先做，覆盖每次列表加载）
  文件：components/SkeletonTrackItem.ets（加参数）、
        pages/SearchPage.ets 的 SkeletonArea / 分页骨架 ForEach（约 1105 行）
  做法：
    1) SkeletonTrackItem 增加 `index: number = 0`（普通成员即可，只用于算延迟）；
       根 Stack 加 `transition` 或初始 opacity/translate + 延迟触发：
       延迟 = min(index, 5) × 70ms，位移 8vp，时长 250ms，Curve.EaseOut。
       ⚠️ 只对首屏 ≤6 条做延迟，第 7 条起延迟一律为 0，否则长列表滚到底还在错峰。
    2) 真实条目到达时做一次落位淡入（opacity + 8vp 上浮，250ms）。
       ⚠️ TrackItem 根节点已挂 `.scale()` + 按压动画，**入场动画必须放外层容器**，
       不能叠加在同一节点上（同属性会被后写的覆盖）。
  验收：加载时骨架逐条浮现而非整块闪现；数据到达无跳变。

【P1-B】三点脉冲组件（内联轻量反馈）
  新建：components/LoadingDots.ets
  规格：3 点，直径 10vp，间距 10vp，颜色 $r('app.color.bili_pink')；
       周期 900ms，相位差 150ms，scale 0.55↔1，opacity 0.3↔1，Curve.EaseInOut。
  按上面「动效技术红线」的代际 + 定时器模式实现，aboutToDisappear 清理。
  接入点：SearchPage 空态里的「点击重试」按钮按下后（按钮内换成三点），
          以及任何 <28vp 的短内容加载位。
  验收：三点相位稳定错开；快速离开页面无残留回调（hilog 无延迟回调）。

【P1-D】音频柱律动组件（品牌化空态）
  新建：components/SoundBars.ets
  规格：5 根柱，宽 6vp，间距 6vp，高度 34vp，`transform-origin` 在底部；
       周期 800ms，相位差 100ms，scaleY 0.28↔1，Curve.EaseInOut。
  接入点：SearchPage.HomeStateArea 的空数据态（替换/并列「暂无数据」文字，
          仅作视觉，不改文案层级）；DownloadsPage 的空态。
  ⚠️ 不许接到 PlayerPage / PlayBar（禁改区）。
  验收：柱子锚点在底部起伏（不是从中心缩放）；无定时器泄漏。

【P2-C】顶部流光进度条（页面级）
  新建：components/TopProgressBar.ets；挂载到 pages/Index.ets 的**顶层 Stack**
  （与各 Tab 页同级，覆盖在内容之上）。
  规格：高 3vp，品牌粉，`scaleX` 从左锚点增长（用 scale + centerX 左对齐，不改 width）；
       冲到 76% 停住等真实进度，完成时冲刺 100% 后淡出。
  驱动：由 `@StorageLink` 的一个全局 loading 计数值驱动（多个并发请求计数，归零才完成）。
  ⚠️ 只允许在 Index.ets **新增**这个浮层，不许碰该文件里底栏的任何一行
     （barFloatingStyle / BAR_BOTTOM_MARGIN / tabItem / HdsTabs 配置）。
  验收：切页签与刷新时出现，结束后完全消失（不留 3vp 残线、不挡点击）。

【P2-E】封面呼吸光晕 —— **已废弃（2026-10-02）**
  曾在行内封面上做过一版：粉晕退出绑 `Image.onComplete`，而本工程运行环境
  实测该回调不可靠 —— 回调不触发时粉晕永久盖在**已加载**的封面上脉动
  （「粉色遮罩」bug 全列表复发），已整体移除（连 10s 兜底超时在内全部删掉，
  CoverImage 回归「图片永远渲染 + brand_surface 底色」两态）。
  教训：**凡叠在图片上的覆盖层，退出条件绝不能依赖图片回调**
  （onComplete / onError 在部分路径不触发），只能靠组件生命周期或固定时长。
  后续若要做大图加载动效，另起组件、只用生命周期收尾。

# 交付格式
每处改动说清：改了哪个文件、为什么、编译结果。
禁止改动「不许动」清单里的内容，禁止给 SkeletonTrackItem 加回扫光带
（2026-10-02 已按用户反馈整体删除），
禁止顺手优化未列出的地方。
```

### 7.4 投递顺序

| 顺序 | 条目 | 理由 |
|---|---|---|
| 1 | P0-A 骨架错峰 | 覆盖每次列表加载，改动最小，体感最明显 |
| 2 | P1-B 三点脉冲 | 独立新组件，不与现有代码耦合 |
| 3 | P1-D 音频柱律动 | 同上，且是品牌识别度最高的一处 |
| 4 | P2-C 顶部进度条 | 要动 `Index.ets`（底栏所在文件），必须单独一轮并重点验底栏未被碰 |
| 5 | ~~P2-E 封面呼吸~~ | **已废弃**：粉晕退出依赖 onComplete，实测回调不可靠 → 全列表粉色遮罩复发 |

**最容易翻车的两处**：`P2-C` 要改 `Index.ets`——AI 很容易顺手"优化"同文件的底栏配置；
`P0-A` 的入场动画如果直接加在 `TrackItem` 根节点上，会覆盖已有的按压 `.scale()`。
两处都已在提示词里点明。

---

## 8. 成品示例：下拉刷新动效三方案（2026-10-02）

> 本轮**只出方案、不改代码**。三个方案不是三选一的平行选项，而是三层不同深度的做法：
> ① 品牌符号（加一个刷新头）② 轻量线性（复用已有 shimmer 语言）③ 内容级接管（不加任何新视觉元素）。
> 选定后再按 8.4 投递提示词。

### 8.1 先核实 —— 下拉刷新「有没有、有几处」

不核实就下任务，AI 必然往两个方向翻车：把「全 App 没有下拉刷新」当事实，
**在已有 `Refresh` 的页面上再套一层**；或者只改 `SearchPage` 就宣称「下拉刷新已品牌化」。

本次实测（`grep -rn "Refresh" --include=*.ets entry/src/main/ets`）：

| 位置 | 现状 | 说明 |
|---|---|---|
| `pages/SearchPage.ets:1038` | ✅ 已有 `Refresh({ refreshing: $$this.refreshing })` | **零属性**：`refreshOffset` / `pullDownRatio` / `maxPullDownDistance` / `promptText` / `builder` / `refreshingContent` / `onStateChange` / `onOffsetChange` **一个都没设** → 全套系统默认（64vp 阈值 + 默认圆环） |
| `pages/DownloadsPage.ets:1130` | ❌ 无 | 纯 `List()` |
| `pages/PlaylistsPage.ets:200` | ❌ 无 | 纯 `List()` |
| `pages/RecentPage.ets:191` | ❌ 无 | 纯 `List()` |
| `pages/PlaylistDetail.ets:270` | ❌ 无 | 纯 `List()` |

两条**不许破坏**的既有约定：

1. `Refresh` **只包住 `List`**，不包搜索框与页签 —— 否则在输入框上往下拉也会触发刷新
   （`SearchPage.ets:1037` 的注释已写明这个取舍）。改视觉时包裹范围不许动。
2. `handleRefresh()` 四个分支各有 `try/finally` 把 `refreshing` 落回 `false`，
   连 `refreshSearch` 的「空关键词」早退分支也落了 —— **不能只加视觉不加收尾**，漏一处转圈就永不收起。

现有可复用资产（别再造一遍）：`SkeletonTrackItem`（40 圆 + 两行条，纯静态占位；扫光已删）、
`TrackItem` 入场错峰（10vp / 250ms / 35ms / ≤8 条）、动效五档
（`instant 100 / fast 150 / normal 250 / slow 400 / ambient 循环`，见 `BiliMusic-设计规范.md` §6.2）。

另外，同一个 `Refresh` 只能有一个子组件；`refreshingContent` 与 `builder` 同时设置时
**`builder` 不生效**（SDK 原文），别两个都写还以为是叠加。

### 8.2 共享底座 —— 三个方案都要设，且现在一个都没设

| 属性 | 现值 | 建议 | 为什么 |
|---|---|---|---|
| `refreshOffset` | 默认 64vp | `72` | 略深一点，指尖刚拉动不至于立刻触发 |
| `pullDownRatio` | 未设 ＝ 动态比例 | `0.55` | 不设时越拉越沉、松手前几乎不动；固定 0.55 跟手又不失控 |
| `maxPullDownDistance` | `undefined`（无上限） | `120` | 封顶后视觉不再继续拉伸，超拉只拉大留白 |
| 自定义刷新区 | 系统默认 | **看要不要跟手**：要跟手（`Drag` 阶段随手指变化）→ 用 `builder`；只要静态/循环（不随状态变）→ 用 `refreshingContent` | ⚠️ 这不是二选一的口味问题：`ComponentContent` 的内容**不自动跟随页面 @State**（要变只能显式调 `update(args)`），而 `builder` 会被状态变化重建（SDK 警告「刷新过程中销毁重建会打断动画」）。两者各有硬伤，按第 3 列的判据选 |
| `onStateChange` | 未设 | 接四态做形态切换 | 见下表 |

`RefreshStatus` 五态 → 视觉映射：

| 状态 | 含义 | 视觉 |
|---|---|---|
| `Inactive` | 未下拉 | 全隐 |
| `Drag` | 已下拉、未过阈值 | **进度型、跟手**：环描边生长 / 粉线变长 / 骨架浮现 |
| `OverDrag` | 已过阈值 | 形态变化宣告「松手即刷」：环实心 / 满环 / 饱和度提升（可带一次 `1 → 0.94 → 1.03 → 1` 回弹） |
| `Refresh` | 刷新中 | **循环型**：匀速旋转 / 流光往返 / 骨架扫光 |
| `Done` | 完成复位 | 收拢（`normal` 250ms）+ 新内容按既有入场错峰落位 |

> ⚠️ `onOffsetChange` 是**每帧回调**。它只能回写一个 `@State number`，
> 绝不允许在回调里改数组、发请求、读存储 —— 否则下拉过程直接掉帧。
> 更不要在回调里 `console.log`（hilog 在每帧打印会明显拖慢）。

### 8.3 三个方案对照

| | 方案一 粉色唱片环 | 方案二 顶部流光进度条 | 方案三 骨架接管 |
|---|---|---|---|
| 视觉核心 | 24vp 品牌粉圆环 + 中心粉点 | 屏顶 2vp 粉线（+ 列表整体下移） | 无刷新头，`SkeletonTrackItem` 随下拉浮现 |
| 下拉时 | 环描边 `0 → 100%`（跟手） | 粉线 `scaleX 0 → 1`（跟手） | 骨架行逐条淡入、高度撑满 |
| 过阈值 | 环变实心 + 回弹一次 | 粉线满宽并轻微加深 | 骨架进入**扫光态**（＝刷新中） |
| 刷新中 | 匀速旋转 900ms/圈（ambient） | 流光带往返 1400ms Linear | 沿用骨架自带的 1200ms 粉光扫光 |
| 完成 | 环收拢 250ms 后隐去 | 粉线淡出 250ms | 骨架淡出 + 真内容错峰落位 |
| 新增视觉元素 | 1 个（自定义刷新区） | 1 个（顶部粉线） | **0 个**（全是既有组件） |
| 品牌感 | 最强 | 中（与骨架扫光同源） | 中（粉点靠既有 `brand_surface` 承载） |
| 改动风险 | 中（`ComponentContent` 生命周期要管） | 低 | 低（但要动 `onOffsetChange` → 骨架高度映射） |
| 覆盖范围 | 只该页 | 可复制到 4 个列表页 | 与「列表内容」强绑定，最适合 `SearchPage` / `RecentPage` |

选型建议：**先做方案二**（风险最低、与已有 shimmer 语言一致、能一次性铺到 4 个页面），
想要更强品牌识别再升到方案一；方案三最激进，适合作为「加载态一体化」的长期方向 ——
**若决定做方案三，直接抄 §8.6 的完整版提示词**（§8.5 只是换方案时的最小替换段）。

### 8.4 完整提示词（复制这段）

```text
任务：把 SearchPage 的下拉刷新做成品牌化动效（方案一「粉色唱片环」）。

【边界 · 不许动】
- Refresh 的包裹范围不许改：它只包 List，不包搜索框与页签
  （SearchPage.ets:1037 注释写明了原因：包住搜索框会导致在输入框上往下拉也触发刷新）。
- 不许改 handleRefresh() / refreshSearch() / refreshRecommend() / refreshRanking() /
  refreshCenter() 的请求逻辑与 finally 收尾；不许删任何一处 `this.refreshing = false`。
- 不许动搜索页签、HistoryPanel、页签栏、CONTENT_END_OFFSET 相关布局。
- 不许改 PlayBar / PlayerPage / components/player/* / QueueSheet（这几处是锁定区）。
- 只动 transform / opacity，不许动 width / height / padding 等布局属性。

【真相来源 · 以这些为准】
- 现状：SearchPage.ets:1038 已有 `Refresh({ refreshing: $$this.refreshing })`，零属性、系统默认样式。
- 参数常量统一放 common/constants/InteractionConstants.ets（与 PRESS_ANIM_MS 并列），
  不许在页面里硬编码时长数字。该文件**没有** `NORMAL_MS` / `FAST_MS` 这类通用档位常量，
  不要臆造，新增请用带语义的名字（如 `REFRESH_RING_ROTATE_MS`）；
  档位对照见 design/BiliMusic-设计规范.md §6.2。
- 循环动画按「要不要中途停」分流（详见 §7「动效技术红线」，工程里两种先例都有）：
  刷新中的旋转**必须能随状态停**（进入 Refresh 起转、Done 即停）→ 照
  components/player/PlayButtonComponent.ets 的「代际变量 + setTimeout 句柄 + animateTo 递归调度 +
  aboutToDisappear 统一 clearTimeout」写，**不要**只靠隐式 `.animation({ iterations: -1 })`
  （那种点火后自己转，启停要靠外界改属性，与刷新状态耦合差）。
  若某个循环确实全程不需要停，才可用隐式 `.animation({iterations: -1})`
  （先例：components/SkeletonTrackItem.ets 的扫光带）。
- 回弹参考 components/BounceIconButton.ets 的 keyframeAnimateTo（1 → 0.86 → 1.04 → 1）。
- 颜色一律走 $r('app.color.xxx') 语义 token：品牌粉用 bili_pink，浅粉底用 brand_surface，
  颜色定义见 entry/src/main/resources/base/element/color.json。不许硬编码色值。

【要做的具体任务】
1. Refresh 上加参数：refreshOffset(72)、pullDownRatio(0.55)、maxPullDownDistance(120)。
2. 自定义刷新区用 **`builder`（CustomBuilder）** —— 这里**故意不用 `refreshingContent`**：
   `ComponentContent` 的内容不会自动跟随页面 @State 刷新（要变只能显式调 `update(args)`），
   而进度弧必须跟手下拉；`builder` 是普通构建函数，状态一变就重跑，天然跟手。
   代价：刷新过程中若外部状态再变化会重建 builder、打断旋转 → 所以**旋转启动后不要再动
   其它状态**（`refreshing` 本身的变化除外，它一次刷新只变两次）。
   视觉：直径 24vp 圆环，轨道用 brand_surface，进度弧用 bili_pink（strokeWidth 2.5），
   环心一个直径 5vp 的 bili_pink 实心圆。
3. onOffsetChange 回写一个 @State pullOffset: number。
   拖拽阶段：进度弧的绘制进度 = min(offset / 72, 1)，跟手不长动画（最多 100ms 线性跟随）。
4. onStateChange：
   - OverDrag：进度弧补满 + 环心粉点 keyframeAnimateTo 回弹一次，明示「松手即刷」。
   - Refresh：环匀速旋转（900ms/圈，Linear），按上面说的代际 + setTimeout 模式驱动。
   - Done：旋转停下、环 250ms 收拢淡出，不复位列表滚动位置。
5. 刷新失败（断网、接口报错）时，环同样要收拢 —— 收尾挂在 refreshing 落回 false 之后，
   不许出现「报错了还在转」。

【验收判据】
- cd /e/BiliMusic/HarmonyOS-Phone 用 hvigor 真实编译（编前先 touch 改过的文件）：
  CompileArkTS 显示 Finished 且 ArkTS ERROR 为 0，BUILD SUCCESSFUL。
- grep -n "refreshingContent\|onStateChange\|onOffsetChange\|refreshOffset\|pullDownRatio" \
  entry/src/main/ets/pages/SearchPage.ets 五条都能命中。
- grep -n "refreshTimer\|refreshGen" entry/src/main/ets/pages/SearchPage.ets 应能命中，
  且 aboutToDisappear 里能查到对应的 clearTimeout —— 旋转必须停得下来。
- grep -n "iterations: -1" entry/src/main/ets/pages/SearchPage.ets 若命中，
  必须确认它对应的是「全程不需要停」的循环；刷新中的旋转必须走代际 + setTimeout。
- 不许出现 12 / 14 / 15 号字，不许出现 #888888 / #AAAAAA / #999999 / #BBBBBB / #CCCCCC。
- 改完在 design/BiliMusic-设计规范.md §6.3 第 9 条与 design/BiliMusic-Figma搭建说明书.md
  的对应小节同步说明（这两份文档要跟着代码走）。
```

### 8.5 换方案时的替换段（把 8.4 的「要做的具体任务」第 2～4 条换掉即可）

**换方案二（顶部流光进度条）**：

```text
2. 刷新区用 `builder` 承载一条 2vp 高、左右留白 16vp 的粉线（bili_pink，圆角 1vp）。
   用 builder 而非 refreshingContent：粉线要随下拉每帧变化（见第 3 条）。
3. onOffsetChange：粉线宽度按 min(offset / 72, 1) 用 scaleX 生长（transform-origin 左端），
   同时给列表整体加 translateY(offset * 0.5)，形成「内容被拉开」的跟随感（上限 40vp）。
   只动 transform，不许改 List 的高度或 padding。
4. 进入 Refresh：粉线切成流光态 —— 一条更亮的窄带 1400ms Linear 往返（用 translateX 而非改宽度）。
   Done：粉线 scaleX 收到 0 并 250ms 淡出，列表 translateY 归零 normal 250ms。
```

**换方案三（骨架接管）**：

```text
2. 不加任何视觉元素：把 SkeletonTrackItem 复用为刷新指示器 —— **单条、固定高 68vp**、
   `index` 传 -1（不参与它自带的首屏入场错峰）。
3. 拖拽阶段：骨架容器 opacity = min(offset / 72, 1)，
   translate({ y: (1 - 该值) * 12 }) 即从上方 12vp 落位 + 淡入，跟手不长动画。
   **不要改高度**：SDK 原文说自定义刷新区设了固定高度后，继续下拉表现为它与 Refresh 顶边间距变大，
   高度自适应会把骨架压扁。
4. Done：骨架 opacity 250ms → 0 并 translate y → -6vp 退出；真内容不另写动画，
   由 TrackItem 既有入场错峰落位。
   ⚠️ recommend / center 页签刷新时 resetRecommend() / resetCenter() 会先清空列表，
   整屏 SkeletonArea 已在显示 —— 骨架条必须加 `currentListLength() > 0` 闸门隐藏，
   否则出现「顶部一条 + 下面一整屏」的双骨架。
5. 完整版（含验收判据与「改完自问三句」）见 §8.6，实投优先用那一份。
   位置与实现路径以 §8.6 为准：骨架行放在 **List 的第一个 ListItem**（普通组件树、能跟手），
   `refreshingContent` 只放一个盖掉系统默认头的静态占位 —— 原因是 `ComponentContent`
   的内容不随页面状态刷新，每帧变化的下拉进度放进去就得每帧 `update()`（详见 §8.6「真相来源」）。
```

### 8.6 成品提示词 · 方案三「骨架接管」完整版（可直接复制）

> 与 8.4 的区别：**不新增任何视觉元素**，刷新指示器直接复用 `SkeletonTrackItem`。
> 抄这段时不要再叠加 §8.5 的「替换段」。

```text
任务：把 SearchPage 的下拉刷新做成「方案三 · 骨架接管」——
不新增任何视觉元素，刷新指示器复用既有的 SkeletonTrackItem，让下拉距离直接长成骨架。

【边界 · 不许动】
- Refresh 的包裹范围不许改：仍只包 List，不包搜索框与页签
  （SearchPage.ets:1037 的注释已写明原因：包住搜索框会导致在输入框上往下拉也触发刷新）。
- 不许改 handleRefresh() 与 refreshSearch / refreshRecommend / refreshRanking / refreshCenter
  的请求逻辑和 try/finally 收尾；**每一处 `this.refreshing = false` 都必须原样保留**。
- 不许改 resetRecommend() / resetCenter() / homeLoading() / HomeStateArea() / SkeletonArea()
  的既有条件判断（`homeLoading() && currentListLength() === 0` 这层语义不能变）。
- components/SkeletonTrackItem.ets 本体**一行都不改**，它只作为组件被复用。
  （2026-10-02 修订：为去掉刷新头里横扫的粉色光带，已给它加 **`index: -1` = 纯静态**
  分支——不播入场、不渲染扫光带。这是迄今唯一一处合法改动；扫光实现本身仍不许重写。）
- 锁定区不许碰：PlayBar / PlayerPage / components/player/* / QueueSheet。
- 只动 transform / opacity / translate，不许动 width / height / padding 等布局属性。

【真相来源 · 以这些为准】
- 现状：SearchPage.ets:1038 是 `Refresh({ refreshing: $$this.refreshing })`，**零属性** = 系统默认头。
- SkeletonTrackItem 的接口：`index: number` 是**普通成员**（默认 0，只在 0..5 才参与它自带的
  入场错峰）→ 传 `index: -1` 即可让它不做入场、由刷新逻辑自己控制显隐。
  它自带上下各 14vp padding + 40vp 圆 → **单条高约 68vp**；扫光靠 onAreaChange 量到宽度后点火
  （仅 index ≥ 0 起跑；-1 纯静态，不渲染扫光带）。
- 自定义刷新区用 `refreshingContent`（ComponentContent，API 12+）承载那个**静态占位** ——
  本方案**刻意不用 builder**：占位不需要跟手，而 builder 会被状态变化重建，
  下拉时状态每帧都在变，用它纯属白白重建。
  ⚠️ ComponentContent 的构造依赖 UIContext，而属性初始化时 UIContext 未就绪 →
  **必须放到 aboutToAppear 里创建**（工程内先例：PlayBar.ets / CoverDiscComponent.ets /
  LrcView.ets 的 animator 都是这么处理的，注释里写了这个原因）。
  ⚠️ 更要紧的一点：`ComponentContent` 的内容**不会自动跟随页面 @State 刷新**，
  要更新必须显式调 `content.update(args)`（SDK：`ComponentContent.update(args: T): void`）
  → 所以凡是「随下拉每帧变化」的视觉一律不要放进 refreshingContent。
- 动效时长不硬编码数字，新常量按既有命名风格追加进
  common/constants/InteractionConstants.ets。**该文件目前只有**
  `PRESS_ANIM_MS` / `ENTRANCE_*` / `NAV_TRANSITION_MS` / `TOAST_*` / `SELECT_*` /
  `COVER_FADE_MS` / `DOWNLOAD_SMOOTH_MS` 这批具体条目，**没有** `NORMAL_MS` / `FAST_MS`
  这类通用档位常量 —— 不要臆造它们，请新增如 `PULL_SKELETON_FADE_MS: number = 250`
  这种带语义的名字（档位对照见 design/BiliMusic-设计规范.md §6.2）。
- 颜色一律 $r('app.color.xxx')：浅粉占位用 brand_surface，品牌粉用 bili_pink。

【要做的具体任务】
1. Refresh 上加参数：refreshOffset(72)、pullDownRatio(0.55)、maxPullDownDistance(120)。
2. refreshingContent **只放一个 0.1vp 高的静态空占位** —— 唯一作用是盖掉系统默认刷新头。
   ⚠️ **跟手的骨架不要放这里**：`ComponentContent` 的内容**不会自动跟随页面 @State 变化**，
   要变只能显式调 `content.update(args)`（SDK：`ComponentContent.update(args: T): void`），
   而下拉偏移是每帧变化 → 放这里就得每帧 update，属于自找掉帧。静态占位不随状态变，故无需 update。
3. 骨架行放在 List 的**第一个 ListItem**（普通组件树，能自然响应状态）：

   if (this.showPullSkeleton) {
     ListItem() {
       SkeletonTrackItem({ index: -1 })
     }
     .width('100%')
     .opacity(this.pullSkelOpacity)
     .translate({ y: this.pullSkelOffsetY })
   }

   `index` 传 -1 的依据：`SkeletonTrackItem.index` 是**普通成员**，只在 0..5 才参与它自带的
   首屏入场错峰 → 传 -1 即「不播入场」，入场节奏由刷新逻辑自己管。
   工程内先例：`loadingMore` 的「加载更多」三行骨架就是这样放在 `ListItem` 里的
   （扫光在 ListItem 内正常工作），照它的写法即可，不必另造结构。
4. onOffsetChange 只回写 `@State pullOffset: number`（每帧回调，不许发请求 / 改数组 / 打日志）：
   `const p: number = Math.min(this.pullOffset / 72, 1)`
   → `pullSkelOpacity = p`、`pullSkelOffsetY = (1 - p) * 12`
   即「从上方 12vp 落位 + 淡入」，**不套 animateTo**（跟手要即时）。
5. **双骨架闸门 —— 本方案最容易翻车处**：
   刷新 recommend / center 页签时 `resetRecommend()` / `resetCenter()` 会**先清空列表**，
   于是 `HomeStateArea()` 已经在显示整屏 `SkeletonArea()`；此时刷新骨架**必须不渲染**，
   否则「顶部一条 + 下面一整屏」，看起来像 bug。实现：新增
   `@State showPullSkeleton: boolean = false;`，进入 Drag / OverDrag 时赋值
   `this.showPullSkeleton = this.currentListLength() > 0;`
   ⚠️ 必须用**状态变量**而不是 `showPullSkeleton()` 方法：Done 之后要延迟把它置回 false
   （见第 6 条），方法没法赋值。
   （search / ranking 页签刷新不清空列表，骨架是唯一指示，正常显示。）
6. onStateChange（RefreshStatus 五态）：
   · Drag / OverDrag：走第 4 条的跟手映射。OverDrag **不要**额外做形态变化 ——
     骨架本身就是最明确的「松手即刷」提示，加回弹反而多余。
    · Refresh：骨架停在下拉终点保持**纯静态**（index -1 不跑扫光——横扫的粉带在
      刷新头里像杂音，2026-10-02 按用户反馈移除）；
      **不要另外加旋转 / 脉冲 / 进度环**（本方案的立论就是不新增动效）。
   · Done：骨架 opacity 250ms → 0 并 translate y → -6vp；**淡出结束（约 250ms）后再置
     `showPullSkeleton = false`** —— 直接置 false 会立刻移除节点，淡出根本看不到。
     延迟用 `setTimeout` 句柄 + `aboutToDisappear` 里 `clearTimeout`（照
     components/player/PlayButtonComponent.ets 的既有模式，不要裸调 setTimeout 不管回收）。
7. 刷新完成后的「内容落位」**不要另写动画**：ForEach 的 key 是 `t.id`（SearchPage.ets:1053 等），
   新数据即新节点 → TrackItem 既有入场错峰（10vp / 250ms / 35ms / ≤8 条）会自动播。
   ⚠️ Done 之后**不要**手动 scrollTo 顶：会与入场错峰打架。
   ⚠️ 若新旧数据 id 大量重合（推荐流常见），错峰不播 —— 这是**正确的**（内容没变就不该入场），
     不要为了「看起来有动效」去改 key。
8. 若真机上出现「内容不满一屏时拉不动」：给 List 加
   `.edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })`。
   依据（SDK 原文）：Refresh 与内容小于自身的 List 嵌套、且中间还有其它组件时，手势可能被中间
   组件拦截。当前 SearchPage 的 List **未设** edgeEffect，先按默认跑，只在复现时加。

【验收判据】
- 用 hvigor 真实编译（编前先 touch 改过的文件）：CompileArkTS 显示 Finished、
  ArkTS ERROR 为 0、BUILD SUCCESSFUL。
- grep -n "refreshingContent\|onOffsetChange\|onStateChange\|refreshOffset\|pullDownRatio" \
  entry/src/main/ets/pages/SearchPage.ets —— 五条都要命中。
- grep -n "SkeletonTrackItem" entry/src/main/ets/pages/SearchPage.ets ——
  原本只有两处（`SkeletonArea()` 内、`loadingMore` 的三行骨架内），改完应为三处，
  多出来的必须就是刷新头这一处；多出第四处说明写重复了。
- components/SkeletonTrackItem.ets 除 `index: -1` 纯静态分支外必须未被改动
  （扫光实现不许重写；2026-10-02 之前的「md5 完全一致」要求已被该合法改动取代）。
- 不许出现 12 / 14 / 15 号字，不许出现 #888888 / #AAAAAA / #999999 / #BBBBBB / #CCCCCC。
- 改完同步 design/BiliMusic-设计规范.md §6.3 第 9 条的状态描述。

【改完自问三句（答不上来就是没做完）】
① 断网下拉一次：refreshSearch 走 catch、refreshing 落回 false，骨架会不会卡住不退？
② 在 recommend 页签下拉：顶部骨架与整屏骨架有没有同时出现？
③ 快速连拉三次并切页签：骨架有没有残留？刷新头有没有扫光带（不应有）？
```

### 8.7 投递顺序

1. **先只做参数整定**（8.2 表的四条属性，不动视觉）→ 单独编译一次。
   这一步就能拿到「跟手」的体感改善，且几乎零风险，先确认手感方向对不对。
2. 再做方案二或方案三的视觉（**一次只做一个方案**，别让 AI 同时铺两个方向）。
3. 一个页面验证通过后，再复制到 `DownloadsPage` / `PlaylistsPage` / `RecentPage` / `PlaylistDetail`
   —— 但**逐页投递**，不要一次说「4 个页面都加上」。
4. 最后同步两份设计文档。

### 8.8 三条红线

1. **刷新区用 `builder` 还是 `refreshingContent`，按「要不要跟手」定，不是二选一的口味**：
   要跟手（`Drag` 阶段随手指变）→ `builder`（会被状态变化重建，天然跟手）；
   只要静态/循环 → `refreshingContent`（内容稳定不重建，但要变必须显式 `update()`）。
   两者同时设置时 **`builder` 不生效**，别写了两个以为能叠加。
2. **`onOffsetChange` 里只写状态，不做任何副作用**；每帧回调里跑业务逻辑必掉帧。
3. **`refreshing = false` 的收尾只能加强、不能重写**：现有 `try/finally` 是防「转圈永不收起」的保险，
   AI 很容易在重排代码时把它顺手删掉，改完必须 grep 复核每一处 `refreshing = false` 都还在。

## 9. 一句话总结

> 描述 = **边界**（不许动什么）+ **真相来源**（以哪份文件为准）+  
> **验收判据**（怎么算做完）+ **一件具体的任务**。  
> 前三条是护栏，最后一条是油门。缺护栏，AI 会开沟里。
