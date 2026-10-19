# 歌单导入方案（网易云 / QQ 音乐 → BiliMusic）

> 2026-10-11 初版 · **2026-10-12 全文复核修订**（10-11~10-12 代码有更新：BilibiliApi 新增收藏夹 /
> 观看历史 / 稍后再看 / 关注等接口，行号有偏移；**导入相关主链路经复核未变**，下文行号以 10-12 为准）  
> 本方案**未修改任何代码**。
> 目标：把外部平台的歌单信息（歌名 / 歌手 / 时长）转成 BiliMusic 本地歌单，播放的仍是 **B 站音源**。  
> 与现有「歌单备份」的区别：备份是**本 App 自产自销**（JSON 闭环）；本方案是**跨平台导入**（新增解析 + 匹配两道工序）。

---

## 0. 一句话方案

**三层管线**：

```
① 获取（文本粘贴 / 链接直连，失败降级）
      ↓
② 匹配（B 站搜索 + 打分分档：强匹配自动 / 弱匹配人工复核 / 未找到兜底）
      ↓
③ 落库（一次建单落盘，500 首上限内，与现有 importPlaylistsFromText 同构）
```

首期只做 **「文本粘贴 + 匹配 + 导入向导」**——这条链路 100% 可落地、不依赖任何第三方接口；  
「链接直连」作为二期增强（先只做网易云，QQ 音乐成功率低放三期）。

---

## 1. 现状盘点（2026-10-11 最新代码已核实）

### 1.1 可直接复用的地基

| 能力               | 位置                                                                     | 复用方式                                                                        |
| ---------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| 歌单 CRUD / 分片存储   | `service/LibraryStore.ts`                                              | 直接调用；每片 8 条 ≈4.1KB（单 value 8192 字节硬上限）                                      |
| 单歌单上限 **500 首**  | `PLAYLIST_MAX_ITEMS`（10-10 刚从 200 提升）                                  | 导入前提示 + 超限截断提示                                                              |
| 歌单合并 + 上限预览      | `previewPlaylistMerge` / `mergePlaylists`（L734-878）                    | 本方案不走合并，但「超限丢弃提示」文案范式可抄（PlaylistsPage L742）                                 |
| 订阅 UP 歌单（增量合并）   | `subscribeUpPlaylist` / `mergeUpTracks`                                | 增量去重合并的参考实现                                                                 |
| **落库同构参考**       | `importPlaylistsFromText`（L1070）                                       | 容错 / 跳过统计 / 重名加「导入」后缀 / 逐首 `slimTrack` + 清 `localFilePath` —— 新管线最后一步与其完全同构 |
| 视频搜索             | `BilibiliApi.searchVideo(keyword, page, pageSize)`（L153）               | 匹配环节直接调用（WBI 签名已封装）                                                         |
| 风控错误口径           | `BiliApiError.code`（-412/-352/-509/-799 等）                             | 风控即停判据                                                                      |
| 网络层              | `HttpUtil.requestJson`（L141）                                           | 支持自定义 headers / `skipCookie` / `skipReferer` / 15s 超时——拉第三方接口的关键            |
| 时长解析             | `TextUtil.parseDurationText`（L313，"mm:ss" → 秒）                         | 时长校验                                                                        |
| 标题清洗             | `TextUtil.cleanTitle`（L62，去【】噪声段 / 引号）                                 | 标题归一化的思路来源                                                                  |
| 关键词候选生成          | `TextUtil.queryCandidates`（L115，从脏标题提炼 ≤8 个候选词）                       | 匹配器构造搜索词的参考实现（含噪声词过滤、av/bv 剔除）                                                |
| 搜索结果 → Track 映射  | `SearchPage.mapSearch`（L102）                                           | 建议提取为共享函数，导入直接复用                                                            |
| 候选列表 UI          | `components/TrackItem`（L99 起，@Prop `track` / `showIndex` / `onPlay` / `moreMenuItems` / `entranceIndex`） | 复核候选行可复用或精简改造                                                                |
| 骨架屏              | `components/SkeletonTrackItem`                                         | 加载/匹配态占位                                                                    |
| 串行队列范式           | `service/DownloadManager.ts`（queue + pump，L264-275 / L590）             | 匹配队列照抄此模式                                                                   |
| 文件型存储范式          | `service/UpSpaceCacheStore.ts`（`filesDir` JSON，避开 Preferences 8192 上限） | 任务快照 / 断点续传（二期）                                                             |
| 剪贴板 / 弹窗 / Toast | `ClipboardUtil` / `showAppAlertDialog` / `showAppToast`                | 直接使用                                                                        |
| 路由注册             | `Index.pageMap`（L547）+ `NavStackHolder.stack.pushPath({name})`         | 新页面按现有模式注册                                                                  |

### 1.2 缺口（本方案要新建的）

1. **外部平台解析器**——全仓库目前 **0 行** 网易云 / QQ 音乐相关代码（已 grep 确认）。
2. **匹配打分器**——现有 `extractAudioFromSearch`（BilibiliApi L1376）是「搜 10 条盲取第 index 条」，**无任何匹配判断且零调用**，不能直接用于批量导入。
3. **导入向导页**——无。
4. **导入任务管理器**——无（需 DownloadManager 式单例常驻任务，支持离开页面后台继续）。

---

## 2. 获取路线（三档，按序落地）

| 档     | 路线                         | 稳定性                | 用户操作成本      | 排期          |
| ----- | -------------------------- | ------------------ | ----------- | ----------- |
| **A** | **文本粘贴**                   | ★★★ 完全可控，零外部依赖     | 复制歌曲列表 → 粘贴 | **首期**      |
| **B** | **链接 / ID 直连**（App 联网拉取歌单） | ★☆ 第三方非公开接口，随时可能失效（10-12 实测两平台当天均通，见 §6） | 复制链接 → 粘贴   | 二期（网易云先，QQ 紧随） |
| **C** | **手动搜索替换**（复核时逐首手动搜）       | ★★★                | 逐首操作        | 首期（内置于复核流程） |

### 路线 A：文本粘贴（首期主路径）

- 用户从网易云 / QQ 音乐（PC 端或网页版）复制歌单的歌曲列表文本，直接粘贴。
- App 只做两件事：**解析文本**（歌名 + 歌手）→ 走匹配管线。
- 解析容错规则：
  - 一行一首；按 `-` / `–` / `—` 切「歌名 - 歌手」；无分隔符时整行当歌名；
  - 去掉行首序号（`1.` `01` `1、`）与引号；忽略空行；
  - 检测到「共 N 首」等汇总行时忽略。
- 优点：不碰第三方接口、不涉及合规问题、永不失效。

### 路线 B：链接 / ID 直连（二期）

- 粘贴分享文本或链接，正则提取歌单 ID → 调平台接口拉取「歌名 + 歌手 + 时长」列表 → 同一匹配管线。
- **失败一律降级**：明确提示「拉取失败，请改用文本粘贴」，不报看不懂的错。
- 两个平台的接口均已于 **2026-10-12 实测通过**（详见 §6）：网易云走「v6 拿 ID 列表 → v3 分批查详情」两步；QQ 音乐一次拿全量且是纯 JSON。初版「QQ 成功率低放最后」的判断已被实测修正，但非公开接口的风控风险仍在，排期保持「网易云先、QQ 紧随」。

### 路线 C：手动搜索替换（首期随复核流程内置）

- 弱匹配 / 未找到的曲目，支持手动输入关键词重新搜、从结果里挑一条。
- 这是匹配准确率不 100% 的**必要兜底**，不允许做成黑盒。

---

## 3. 匹配管线（核心环节）

### 3.1 流程

```
外部歌曲 {歌名, 歌手, 时长?}
  → 构造搜索词「歌名 歌手」（无结果时降级为「歌名」）
  → BilibiliApi.searchVideo(kw, page=1, pageSize=20)     ← 每首仅 1 次请求
  → 逐条打分 → 取 Top 候选
  → ┌ 强匹配（≥5 分）→ 自动选中
    ├ 弱匹配（3~4 分）→ 进「待确认」列表（附 Top 3 候选）
    └ 未找到 → 进「未找到」列表（可手动搜 / 跳过）
```

### 3.2 打分细则（建议初版阈值，上线后按实测调）

| 判据                                    | 分值                 |
| ------------------------------------- | ------------------ |
| 标题（归一化后）包含歌名                          | **+3（必须项，缺它直接出局）** |
| 标题或 UP 主名包含歌手名                        | +2                 |
| 时长差 ≤ 5s                              | +2                 |
| 时长差 ≤ 30s                             | +1                 |
| 时长差 > 60s                             | −3（可疑，重罚）          |
| 标题含「翻唱 / 鬼畜 / 伴奏 / 合集 / 教程 / 纯音乐」等噪声词 | −2                 |

归一化：全角→半角、大小写统一、去空格、借助 `cleanTitle` 思路去括号噪声段。  
取分最高的一条判断档位；同分时优先播放量（`play`）高的。

### 3.3 风控与串行队列（⚠️ 2026-10-16 已推翻 → 见 §9.7）

> 本节原结论已废弃：实测单请求 rt ≈ 430ms，并发 2 / 5 / 8 各 16 首**全部零风控**，
> 原「串行 + 每首硬等 1.0~1.5s」纯属自缚（同一个 100 首歌单：旧 168s → 新 **19.5s**，**8.6x**）。
> 现行为「**并发 4 + 全局最小间隔 200ms**（≈5 QPS）+ 轮内同曲去重 + 每首取 30 条候选」，
> 「风控即停 + 保留进度可 resume」的语义保持不变，「不预取详情」仍然有效。

- **并发 + 节流**：4 个 worker 共享取号游标（取走即自增），全局保证相邻两次「请求发起」间隔 ≥200ms。
- **风控即停**：命中搜索接口风控码（-412 / -352 / -509 / -799 口径）→ 立即停 + 提示「B 站限流，请稍后再继续」，
  **保留已完成进度**；游标回退到「所有在飞条目的最小下标」，被中断的条目保持 PENDING，resume **不跳曲**。
- **不预取详情**：只搜列表、不进视频详情页、不解析音源直链——音源解析留给播放时惰性调用（与现有设计一致）。

### 3.4 规模与耗时估算（⚠️ 下表的「串行估算」已作废，右侧是新版实测）

| 歌单规模      | 旧串行估算 | **新版实测/推算** |
| --------- | -------- | ---------- |
| 30 首      | ≈ 1 分钟   | ≈ 6 秒      |
| 100 首     | ≈ 2.5 分钟 | **19.5 秒**（实测，见 §9.7） |
| 500 首（上限） | ≈ 12 分钟  | ≈ 100 秒    |

> 超过 500 首的导入源：先提示「超出单歌单上限，只保留前 500 首」（不静默）。

---

## 4. 落库

- **一次建单**：匹配期间在内存收集选中的 `Track[]`，结束时 `createPlaylist` + `persistPlaylists` **一次落盘**。
  - ⚠️ **禁止逐首调 `addTrackToPlaylist`**（它每调一次全量重写所有分片，500 次 = I/O 灾难）；也不要在匹配中途反复写盘。
- **命名**：网易云直连 → 用歌单原名；文本粘贴 → 默认「导入歌单 MM-DD」（可改）；重名 → 加「导入」后缀（与现有 `importPlaylistsFromText` 策略一致）。
- **封面**：直连时带 `coverImgUrl`（第三方图可能有防盗链，需实测）；文本粘贴 → 首曲封面兜底（现有逻辑已有）。
- **去重**：同一歌单内按 `bvid` 去重。
- **Track 映射**：与 `SearchPage.mapSearch` 完全同构（`id/bvid/aid/title/artist/upMid/coverUrl/duration/playCount/pubdate`）——建议把 `mapSearch` 从 SearchPage 提出到公共层复用。

---

## 5. 界面设计（导入向导）

### 5.1 入口

- **设置页 →「歌单备份」区**：现有「导出 / 导入」两行下方新增第三行：  
  「从网易云 / QQ 音乐导入」· 副文案「粘贴歌单链接或歌曲列表」。
- （可选）歌单页空态文案补一句引导。

### 5.2 页面结构（单页 5 态状态机，不做多页转场）

```
[1 输入] → 识别 → [2 预览] → 开始匹配 → [3 匹配中] → [4 报告] ⇄ [5 复核] → 完成导入
```

匹配任务放**单例管理器**（`ImportTaskManager`，模式同 DownloadManager）：离开页面继续跑，回来能看到进度；进度广播用现有的 `STORE_*_REV` @StorageLink 模式。

### 5.3 逐态设计

**(1) 输入态**

- 页标题「从外部导入歌单」；
- TextArea（约 6 行高），placeholder：「粘贴网易云 / QQ 音乐的歌单链接，或一行一首「歌名 - 歌手」」；
- 主按钮「识别」（品牌粉实底）；
- 脚注（text_tertiary 11）：支持网易云歌单链接与文本列表；QQ 音乐建议直接复制歌曲列表。

**(2) 预览态**

- 识别结果卡：「网易云歌单《起风了》· 58 首 · 去重后 57 首」或「文本列表 · 57 首」；直连时显示封面缩略图；
- 超限警告（>500，state_error 色）：「超出单歌单 500 首上限，将只保留前 500 首」；
- 主按钮「开始匹配」；次按钮「返回修改」。

**(3) 匹配中**

- 进度：「32 / 57」+ 进度条（项目已有进度条样式）；
- 当前曲目行：「正在匹配：起风了 — 买辣椒也用券」（实时滚动）；
- 实时统计三色小字：`✓ 12 · ? 8 · ✕ 1`；
- 提示「可返回，匹配将继续进行」；「中断」按钮（二次确认，保留已完成部分）。

**(4) 报告态**

- 「匹配完成」标题；
- 三行统计：强匹配 **49**（state_success）· 待确认 **8**（state_warning）· 未找到 **0**（state_error）；
- 歌单名输入框（默认名，可改）；
- 主按钮：有待确认 →「处理待确认（8）」；无 →「完成导入（49 首）」；
- 次按钮：「跳过未决项，直接导入」。

**(5) 复核态**

- 顶部进度「第 2 / 8 首」；
- 外部歌信息：「起风了 — 买辣椒也用券 · 04:37」；
- 候选列表（≤3 行，每行：标题 / UP 主 / 时长 / 播放量 + 「选它」按钮）——复用 TrackItem 或精简候选行；
- 操作行：「换个关键词搜」（inline 输入）/「跳过这首」；
- 全部处理完 → 回报告态 → 导入完成 → Toast + 可选跳转歌单详情。

### 5.4 规范遵循清单

- 顶栏：新页面按最新 HdsNavDestination + 现有 `HdsTitleBarStyle` 规范接入；
- 字阶只用六档（24/20/18/16/13/11）、灰阶只用三档（text_primary / secondary / tertiary）；
- 品牌粉只用于主按钮实底 / 图标 / ≥18 大字号；触达 ≥44vp + 按压态 `press_overlay`；
- 色 token：`state_success` / `state_error` 已有；「待确认」档**建议新增 `state_warning`** token（方案实施时补 base+dark 两份）；
- 组件复用：TrackItem / SkeletonTrackItem / showAppAlertDialog / showAppToast / ClipboardUtil / ArrayDataSource。

---

## 6. 外部接口情报（**2026-10-12 已实测**）

> ⚠️ 以下均为**非公开接口**，会随平台风控随时失效。本节为 **2026-10-12 在本机实测**结果
> （匿名、桌面 UA + 对应平台 Referer，**未带任何 B 站 Cookie**）；实施时若失败，先用文末命令复测。

### 6.1 网易云（二期）

| 端点 | 10-12 实测结果 | 说明 |
| --- | --- | --- |
| `/api/playlist/detail?id=` | ❌ **已失效** | 返回 `{"code":20001}`——初版「大概率可直读」的情报已过期 |
| `/api/v6/playlist/detail?id=` | ✅ 可用 | 返回歌单元信息 + `coverImgUrl` + **`trackIds`（完整 ID 顺序表）**；但 `tracks` 数组**只含前约 6 首**，不能直接当全量用 |
| `/api/v3/song/detail?c=[{"id":N},…]` | ✅ 可用 | 按 ID 批量查详情，返回 `songs[] { name, ar[].name, dt(ms) }` |

**完整拉取 = 两步**：

```
① GET /api/v6/playlist/detail?id={歌单ID}
   → playlist.name / playlist.coverImgUrl / playlist.trackIds[]（完整 ID 列表）
② GET /api/v3/song/detail?c=[{"id":N1},{"id":N2},…]   （每批约 50~100 个 ID，分批拿全量）
   → songs[] { name, ar[].name, dt }
```

- 请求头：桌面 UA（HttpUtil 默认即桌面 Chrome，已满足）+ `Referer: https://music.163.com/`。
- ⚠️ **必须 `skipCookie: true` + `skipReferer: true`**——绝不要把 B 站 Cookie / B 站 Referer 发给第三方（隐私红线）。
- 已失效端点无需再试：`interface.music.163.com` 同样返回 20001；`/api/song/detail?ids=` 返回 `{"code":400}`。

**PC 侧验证命令**：

```
curl -s "https://music.163.com/api/v6/playlist/detail?id=24381616" \
  -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36" \
  -H "Referer: https://music.163.com/" | head -c 800
```

注意项：

- 大歌单（实测样本 1267 首）必须走两步；每批 ID 数需实测（50~100 起步，响应体积可控）。
- 响应体积大，解析时只保留 `name / ar / dt` 三个字段并立即释放原始对象。
- 封面 `coverImgUrl` 是 `p1.music.126.net` 图床，防盗链情况需在 App 内实测。

**链接识别正则**（粘贴文本中提取 ID）：

```
/music\.163\.com\/(?:#\/)?playlist[\/?]?(?:[\s\S]*?[?&]id=|\/)(\d{4,})/
```

短链 `163cn.tv/xxx` 需跟随跳转（暂不支持，提示用户复制完整链接）。

### 6.2 QQ 音乐（三期）

**10-12 实测：匿名直接可读，一次拿全量**（实测歌单 77 首全部返回）：

```
GET https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&disstid={歌单ID}&format=json&g_tk=5381
需要：Referer: https://y.qq.com/（关键）
实测响应：{"code":0,"subcode":0,"cdlist":[{"dissname":"7","logo":"https://y.gtimg.cn/...","songlist":[…77首…]}]}
```

- **是纯 JSON，无 JSONP 壳**（`json=1` 参数生效；初版方案担心的剥壳不需要）。
- 关键路径：`cdlist[0].songlist[] { songname, singer[].name, interval(秒) }`、`dissname`、`logo`。
- ⚠️ 同样必须 `skipCookie: true` + `skipReferer: true` + 自定义 `Referer: https://y.qq.com/`。

**PC 侧验证命令**：

```
curl -s "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&disstid=7346601611&format=json&g_tk=5381" \
  -H "User-Agent: Mozilla/5.0 ... Chrome/120.0.0.0 ..." \
  -H "Referer: https://y.qq.com/" | head -c 800
```

**风险提示**：`g_tk=5381` 是固定匿名值，后期平台加上校验就会整批返回 subcode 错误——**今天能用不代表明天能用**，所以仍放最后做，且必须带降级文案。  
链接识别：`y.qq.com/n/ryqq/playlist/(\d+)`；短链 `c6.y.qq.com/...?__=xxx` 需跳转（暂不支持，提示用长链接）。

> **实测后的结论翻转**：初版以为「网易云简单、QQ 难」，实际相反——QQ 一次拿全量、网易云要两步分批。
> 但两者同为非公开接口，「**文本粘贴为主路径、直连为增强**」的整体结论不变。

---

## 7. 分期实施建议

| 期      | 内容                             | 依赖              |
| ------ | ------------------------------ | --------------- |
| **P1** | 文本粘贴解析 + 匹配打分 + 导入向导（5 态）+ 落库  | 无外部依赖，**可独立上线** |
| P2     | 网易云链接直连（v6 拿 ID 列表 → v3 分批查详情 + 降级文案） | §6.1 已于 10-12 实测通过 |
| P3     | QQ 音乐直连（一次全量）+ 断点续传（任务快照存文件） | §6.2 已于 10-12 实测通过，实施前复测风控 |
| P4（可选） | 任务中心化（导入任务进设置页常驻入口，与下载任务并列）    | P1-P3 稳定后       |

**P1 内部顺序**：① 解析器纯函数（可单测）→ ② 匹配器（串行队列）→ ③ 向导页 UI → ④ 联调落库。

---

## 8. 风险与合规

1. **B 站搜索风控**（最高频风险）：150 首以上批量搜索必限流——串行 + 间隔 + 风控即停 + 保留进度，四件套都要。
2. **匹配准确率不会 100%**：B 站音源质量参差（鬼畜 / 翻唱 / 重复投稿 / 纯音乐），**必须保留复核 UI**，不能做成黑盒自动导入。
3. **第三方接口随时失效**：10-12 实测两个平台当天都能通，但网易云老接口当天已死（20001）就是活教训——**今天能用不代表明天能用**。这是把「直连」定为可选增强、把「文本粘贴」定为主路径的根本原因。
4. **隐私红线**：请求网易云 / QQ 时**必须 `skipCookie: true`**——`HttpUtil` 默认会自动附加 B 站 Cookie（buvid + 登录态），绝不能发给第三方。
5. **合规提示**：第三方接口为非公开 API，抓取歌单信息可能违反其用户协议；导入后播放的仍是 B 站音源，不涉及下载 / 搬运第三方音频。建议在产品文案中保持「用户主动提供自己的歌单信息」的定位。

---

## 9. 待确认项（附默认建议）

| # | 事项      | 默认建议                             |
| - | ------- | -------------------------------- |
| 1 | 首期范围    | 只做文本粘贴 + 匹配 + 向导（P1）             |
| 2 | 弱匹配处理   | 列出候选让用户挑（不自动跳过、不自动盲选）            |
| 3 | 歌单命名    | 直连用原名；文本默认「导入歌单 MM-DD」；重名加「导入」后缀 |
| 4 | 入口位置    | 设置页「歌单备份」区第三行（可改挂歌单页）            |
| 5 | 500 首上限 | 导入前提示，超限截断（复用合并功能的提示范式）          |
| 6 | 断点续传    | 一期不做（进程重启丢任务）；三期随文件存储补           |

---

## 附：本方案核实过的关键代码事实（2026-10-12 复核）

- `PLAYLIST_MAX_ITEMS = 500`（LibraryStore L246，10-10 从 200 提升，为合并超限场景修改）。
- 分片存储：`PLAYLIST_CHUNK_ITEMS = 8`；`persistPlaylists` 全量重写 + 内存快照 `playlistCache` 为唯一真源。
- `importPlaylistsFromText`（L1097）：JSON 格式（`{app:'biliMusic', type:'playlists', version:1, playlists:[...]}`），容错 + 跳过统计 + 重名「导入」后缀；结尾 `persistPlaylists([...imported, ...getPlaylists()])` **一次落盘**——新管线落库步骤照此形态。
- `addTrackToPlaylist`（L656）：每次调用都 `persistPlaylists(next)` 全量重写所有分片 → **批量导入禁止逐首调用**（已复核确认）。
- `BilibiliApi.searchVideo`（L153）：WBI 签名 + `BiliApiError`；返回 `SearchResultItem[]`（`bvid/aid/title/author/mid/play/videoReview/duration(字符串)/pubdate/pic/description`）。
- `extractAudioFromSearch`（L1376）：搜 10 条盲取第 index 条，**零匹配判断、全仓零调用**——不可用于批量导入（已复核确认）。
- `HttpUtil`：默认桌面 Chrome UA（注释记录了「移动端 UA + buvid 组合会被搜索接口静默风控」的实测矩阵）+ 自动 Referer/B 站 Cookie；支持 `skipCookie` / `skipReferer` / 自定义 headers / POST body / 15s 超时。
- 风控码口径：`RETRYABLE_BIZ_CODES` 同款（-352/-412/-509/-799，见 `FOLLOWINGS_RISK_CODES`）。
- 现无任何网易云 / QQ 音乐相关代码（10-12 grep 复核仍为 0 行）。
- 下载管理器串行队列：`queue` + `pumping` + `pump()`（DownloadManager L264-275 / L606）。
- 文件型存储先例：`UpSpaceCacheStore`（`{filesDir}/up_space_cache/{upMid}.json`）。
- 路由：`Index.pageMap` 分发 + `NavStackHolder.stack.pushPath({ name })` 入栈。
- 色 token 现状（10-12 复核）：`state_success` / `state_error` 已有，**无 `state_warning`**（报告态「待确认」档需新增 base+dark 两份）。

---

## 9. 落地上线后复核：两个平台「均显示未找到」的根因（2026-10-16 实测）

> 用户反馈：导入网易云与 QQ 音乐歌单，「均显示未找到」。本节为实测复盘，**全部结论都有可复现命令**。

### 9.1 先定性：「未找到」出现在哪一步

`未找到` 只出现在**报告页统计行**（`PlaylistImportPage:744` `reportStatRow('未找到', importState.missing, ...)`），
即流程已经走完「识别 → 匹配」。反推：

- **拉取失败** → 停在输入态 + toast「歌单拉取失败，请改用文本粘贴」，**根本到不了报告页** ⇒ 排除「接口挂了 / 风控」；
- 识别成功且是**正常歌曲条目** → 打分实测能出强匹配（见 9.3）⇒ 排除「匹配管线整体失效」。

### 9.2 实测三条（2026-10-16 18:1x，本机 curl + 复刻工程 WBI 签名）

| 检查项 | 实测结果 |
| --- | --- |
| 网易云 `/api/v6/playlist/detail?id=24381616` | HTTP 200 · `code:200` · `playlist.trackIds` **1267 条**（代码依赖字段仍在）· 响应 231KB |
| 网易云 `/api/v3/song/detail?c=[{"id":347230}]` | HTTP 200 · `songs[]` 正常（name / ar / dt 齐全） |
| QQ `fcg_ucc_getcdinfo_byids_cp.fcg?...&disstid=7346601611` | HTTP 200 · `code:0` · 60KB · **纯 JSON 无 JSONP 壳**（`json=1` 仍生效） |
| B 站 WBI 搜索（复刻 `WbiSign.ts` + `searchVideo`） | `稻香 周杰伦` → 20 条；`起风了 买辣椒也用券` → 20 条；打分最高 **7 分 ⇒ 强匹配**（19~20/20 条过标题门槛） |

⇒ **两平台接口、B 站搜索、打分链路全部正常。**

### 9.3 根因：两条链接正则只认 PC 网页版，App 分享链接全部漏网，且失败后静默降级

`PlaylistImporter.ts` 的识别正则（逐字复制到 node 跑了 12 种真实链接）：

| 粘贴内容 | 网易云正则 | QQ 正则 | 结果 |
| --- | --- | --- | --- |
| `music.163.com/#/playlist?id=`（PC） | ✅ 命中 | — | 正常直连 |
| `music.163.com/playlist?id=`（PC） | ✅ 命中 | — | 正常直连 |
| `y.music.163.com/m/playlist?id=…`（**App 分享**） | ❌ | ❌ | **降级成文本解析** |
| `163cn.tv/xxx`（App 短链） | ❌ | ❌ | 同上 |
| `music.163.com/m/playlist?id=` | ❌ | ❌ | 同上 |
| `y.qq.com/n/ryqq/playlist/<id>`（PC） | — | ✅ 命中 | 正常直连 |
| `i.y.qq.com/n2/m/share/details/taoge.html?id=…`（**App 分享**） | ❌ | ❌ | **降级成文本解析** |
| `c6.y.qq.com/base/fcgi-bin/u?__=xxx`（App 短链） | ❌ | ❌ | 同上 |

网易云正则要求 `music.163.com/` 后**紧跟** `playlist`，App 分享链接中间多了 `/m/` 这一段 → 直接断掉。

**降级链条（三个缺陷叠加，缺一不可）：**

1. 正则不覆盖 App 分享链接 / 短链；
2. `recognize()` **没有**「看起来像链接但不支持」的分支（方案 §2B 要求的「提示用户复制完整链接」从未实现）→ 静默落到 `parseSongListText()`；
3. `parseSongListText()` 不排除 URL 行 → **整条分享文本变成 1 首歌名**（实测：`分享歌单《我喜欢的音乐》: https://y.music.163.com/m/playlist?id=…` → 1 首，title = 整行 90+ 字符）。

于是 `matchOne` 拿这条「歌名」去搜 B 站：**模糊搜索确实会返回 20 条**（所以走不到「没有搜到相关视频」），
但 `scoreCandidate` 要求 `视频标题.includes(歌名)`，90 字的分享文本不可能被包含 → 全部 `SCORE_OUT`
→ `scored.length === 0` → `failReason = '没有找到足够相似的版本'` → **报告页「未找到」**。

两个平台走的是同一对正则、同一个降级分支 ⇒ **「均显示未找到」**。

### 9.4 修复建议（按优先级）

- **A（必须）扩宽两条正则**：网易云加 `(?:#\/|m\/)?`（覆盖 `y.music.163.com/m/playlist`）；QQ 增加
  `taoge\.html\?[^#]*[?&]?id=(\d+)` / `[?&]disstid=(\d+)` 形态（覆盖 App 分享页）。
- **B（必须）禁止静默降级**：`recognize()` 增加「疑似链接」判定 —— 文本含 `music.163.com|163cn.tv|qq.com`
  但未提取到 ID 时，明确提示「这是短链/移动端链接，请改用歌曲列表文本」或「在浏览器打开后复制完整链接」。
- **C（应该）`parseSongListText` 跳过 URL 行**（`/^\s*https?:\/\//`），从根上杜绝「URL 变歌名」。
- **D（可选）短链跟随跳转**：`163cn.tv` / `c6.y.qq.com/...?__=` 取重定向后的最终 URL 再提 ID。

### 9.5 排查方法论（可复用）

- 环形日志缓冲 + 落盘归档都会**丢掉 App 自身 hilog**（`hilog.111.*.gz` 里 `bilimusic` 只有系统侧记录、
  `BiliMusicHttp` 0 行）⇒ 别指望事后从设备日志还原用户操作，**要现场复现或加持久化留痕**。
- 判定「第三方接口是否失效」用**本机 curl**（方案 §6 已给命令）最快，10 秒出结论。
- 判定「打分链路是否失效」把 `cleanTitle/cleanSeg/scoreCandidate` **逐字搬到 node** 打真实接口最省事，
  比在真机上盲试快得多（本次 30 行脚本即定性）。

---

## 9.6 修复实施（2026-10-16 当日完成，A/B/C/D 全做）

### 用户提供的两条**真实分享原文**（本次修复的验收样本）

```
分享歌单 《暴露年龄！90后MP3里的经典老歌》https://c6.y.qq.com/base/fcgi-bin/u?__=5Atx6oMdqE5N @//qq/ 音乐
分享请叫我快乐冠军创建的歌单: 经典老歌『神仙打架年代』100首华语金曲: https://music.163.com/m/playlist?id=17747519380&creatorId=8557921139&uiPlaylistType=UGC (来自@网易云音乐)
```

两条都是 **App「分享 → 复制链接」**（非浏览器地址栏），正好落在旧正则的盲区里。

### 实测证据（本机 curl，2026-10-16）

| 项 | 结果 |
| --- | --- |
| QQ 短链 302 | `Location: https://i2.y.qq.com/n3/other/pages/details/playlist.html?ADTAG=cbshare&…&id=9725916480&…`，**与 UA 无关**（移动 UA / PC UA / 无 UA 三者完全一致） |
| 网易云 v6（`id=17747519380`） | `code=200`、`name=经典老歌『神仙打架年代』100首华语金曲`、`trackIds` **100 条**（`tracks` 只给前 10 → 再次印证「不能用 tracks 当全量」） |
| QQ（`disstid=9725916480`） | `code=0`、`dissname=暴露年龄！90后MP3里的经典老歌`、`songlist` **619 首**（>500 上限，落库按既有截断提示） |
| QQ 落点页 HTML | 含 3 处歌单 ID（`og:url` / `<link rel=canonical>` 均为 `y.qq.com/n/ryqq_v2/playlist/9725916480`，另有 `window.__INITIAL_DATA__`）→ 可作短链解析兜底 |

### 代码改动（4 处文件）

1. **`utils/HttpUtil.ts`** — `HttpRequestOptions` 新增 `maxRedirects?: number`；新增
   `probeRedirectLocation(url, options)`：发一次 `maxRedirects: 0` 的 GET 读 3xx 的 `Location`
   （键名大小写不敏感，`readHeader` 归一化比较），**任何异常一律降级为空串**不向上抛。
2. **`service/PlaylistImporter.ts`** — 识别改为「**先认平台域名、再提 ID**」两段式：
   - 网易云 `NETEASE_HOST_RE` + `[?&#]id=` / `/playlist/<id>`；覆盖 `/#/playlist`、`/playlist`、
     **`/m/playlist`**（App 分享）、旧路径
   - QQ `QQ_HOST_RE` + `[?&#]id=` / `[?&#]disstid=` / `/(ryqq|ryqq_v2)/playlist/<id>`；覆盖 PC、
     **`taoge.html?id=`**、**短链落点页 `playlist.html?…&id=`**
   - 新增 `detectShareShortLink()` / `resolveShareShortLink()`：短链先读 302 Location，失败再
     跟随取落点页 HTML 提 `/playlist/<id>`（**两级兜底**）
   - 新增 `isExternalPlaylistLink()`：显式区分「粘了链接但提不出 ID」与「粘了歌曲列表」
   - `parseSongListText()` 新增 `URL_LINE_RE` → **含链接的行整行丢弃**（C 项）
   - ⚠️ `[?&#]id=` 的**紧邻约束是必需的**：宽松写法 `[\s\S]*?id=` 会把 `&creatorId=8557921139`
     的值当成歌单 ID
   - ⚠️ host 正则加 `(?:^|[^a-z0-9.-])` 边界，避免 `xxxy.qq.com` 这类子串误判
3. **`pages/PlaylistImportPage.ets`** — `recognize()` 分支重排：网易云 ID → QQ ID →
   **分享短链（302 反查）** → 「命中平台域名但无 ID」**明确 toast** → 文本解析。
   彻底堵死「整串分享文本被当成一首歌名去搜」这条降级路径。

### 回归验证（node 逐字复刻新逻辑，14 个用例全过）

| 样本 | 路由结果 |
| --- | --- |
| QQ 真实原文 | `shortlink(qq)` → `c6.y.qq.com/base/fcgi-bin/u?__=5Atx6oMdqE5N` |
| 网易云真实原文 | `netease-direct` → `id=17747519380` |
| `music.163.com/#/playlist?id=` / `/playlist?id=` / `/playlist/24381616` / `y.music.163.com/m/playlist?id=` | 全部 `netease-direct` |
| `y.qq.com/n/ryqq/playlist/<id>` / 落点页 `…&id=` / `taoge.html?id=` / `[?&]disstid=` | 全部 `qq-direct` |
| 纯歌曲列表（含一行链接混入） | URL 行被跳过，正常解析出歌曲 |
| 非平台链接（B 站视频） | 落文本解析 → 0 首 → 「没有识别到歌曲」提示 |

⚠️ **真机待验**：`maxRedirects: 0` 在 HarmonyOS 引擎上的实际行为（能否正常返回 302 + `Location` 头）
无法离线验证，已用「跟随取 HTML 提 ID」做第二级兜底。若真机上 QQ 短链仍失败，看
`[BiliMusicHttp] probe … code=… location=…` 这行 hilog 即可定位（code 是否 302、location 是否为空）。

---

## 9.7 匹配提速：串行 → 并发（2026-10-16 当日完成）

### 瓶颈定性

旧实现是**严格串行 + 每首硬等 1.0~1.5s**（`MATCH_INTERVAL_MS`/`MATCH_JITTER_MS`）。
按此推算 100 首要 **168 秒**、500 首要 **14 分钟**，其中 90% 以上时间在「睡」而非在请求。

### 实测依据一：单请求 rt 与并发容忍度（本机 node 复刻工程 WBI + PC UA + buvid，打 `/x/web-interface/wbi/search/type`）

| 调度方式 | 样本 | 结果 | 等效耗时 |
| --- | --- | --- | --- |
| 串行 + 每首间隔 1s（旧实现） | 5 首 | 5/5 成功，rt 均值 **422ms**（381~455） | ≈1670ms/首 |
| 并发 2，无间隔 | 16 首 | **16/16 成功，0 风控** | 221ms/首 |
| 并发 3，无间隔 | 16 首 | **16/16 成功，0 风控** | 169ms/首 |
| 并发 5，无间隔 | 16 首 | **16/16 成功，0 风控** | 115ms/首 |
| 并发 8，无间隔 | 16 首 | **16/16 成功，0 风控** | 61ms/首 |

补充：`page_size` **20 / 30 / 50 的 rt 完全一致**（415 / 406 / 405ms）→ 取 30 条候选是白捡的命中率。

**结论：rt ≈ 420ms 全是网络往返，接口并不要求慢。原 1.25s/首的等待纯属自缚。**

### 实测依据二：端到端仿真（真实歌单，非构造样本）

以用户提供的网易云歌单 `id=17747519380`（《经典老歌『神仙打架年代』100首华语金曲》，**100 首，去重后 95 首**）
为准，按新版调度实打 B 站搜索：

```
总耗时 19.5s   完成 100/100
请求 96 次（含降级重搜 1）   拿到结果 95   空结果 0   风控 0
单请求 rt 均值 431ms   实际吞吐 4.9 请求/秒   等效 195ms/首
旧版同曲目理论耗时 ≈168s  →  提速 8.6x
```

### 落地参数

| 常量 | 值 | 说明 |
| --- | --- | --- |
| `MATCH_CONCURRENCY` | `4` | worker 数（实测 8 都稳，取 4 留量级余量给真机弱网） |
| `MATCH_MIN_GAP_MS` | `200` | 全局节流：相邻两次「请求发起」间隔下限 → 稳态上限 **5 QPS** |
| `MATCH_PAGE_SIZE` | `30` | 单次候选数（20→30 免费提升命中率、减少手工复核） |
| `IMPORT_NOTIFY_MS` | `120` | 进度广播节流（并发后每秒近 20 次 notify × 全量 items 快照会拖累向导页） |

> **调参口**：真机若出现限流，只需调小 `MATCH_CONCURRENCY` / 调大 `MATCH_MIN_GAP_MS`，其余逻辑无需动。

### 代码结构（`service/PlaylistImporter.ts`，全部为纯改，未动对外 API）

- `run()`：由「while + sleep」改为**起 N 个 worker 共享取号游标**（`cursor` 取走即自增，单线程天然无锁）；`Promise.all` 后统一收尾。
- `workerLoop()`：取号 → `matchItem` → 计数；风控命中走 `hitRisk` 后退出。
- `hitRisk(idx)`：**游标回退水位 `riskFloor` = 所有在飞条目的最小下标**；被中断的条目保持 `PENDING`，故 resume **不跳曲**（与旧版语义一致）。
- `throttle()`：全局最小间隔（单线程下取号与写时间戳之间无 await，无竞态）。
- `matchItem()`：**轮内同曲去重**（`归一化歌名|歌手` → 复用结果，零请求；本次 100 首省了 5 次）。
- `processed` 由 `cursor` 改为**独立计数器 `done`**：并发下 `cursor` 是「已取走」而非「已完成」。
- `publishCurrent()`：并发下「正在匹配」文案取最近 3 首 + 「等 N 首」。
- `notifyThrottled()`：worker 路径节流广播；`start / stop / resume / 用户操作` 仍走 `notify()` 立即推，状态切换不掉帧。

### 不可离线验证项

- 真机网络（移动/Wi-Fi）下的实际 rt 与并发容忍度 —— 本机实测是家宽，真机可能更慢，但**并发不会比串行更差**（`throttle` 保底）。
- 若真机触发限流：相位会停在 `RISK`，提示保留进度，`resume` 从回退水位继续，**逐字与旧版一致**。

