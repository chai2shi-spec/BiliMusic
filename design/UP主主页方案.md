# UP 主主页 · 方案与落地记录（2026-10-03 · **C 方案已实现，hvigor 编译通过**）

> 需求：曲目「⋯」菜单里增加「进入 UP 主主页」的选项。  
> 本文所有结论都来自**真实代码 + 匿名态真实接口实测**，不是推断。  
> 复现脚本见文末附录。
>
> **当前状态**：方案 C（站内 UP 主页 + 投稿订阅歌单）已落地并真实编译通过；  
> 方案 A（跳出 B 站 App）**未做**（C 已包含「进 UP 主页」的入口，跳出去只是多一条退路）。  
> 落地清单见文末「落地记录」。**UI 高保真稿还没补这一屏**（`BiliMusic-UI.html` 仍是 13 屏）。

---

## 一句话结论

**能做，而且比预期便宜**：API 层早就封装好了 `searchUser` / `getUserVideos` / `getFavoriteFolders`  
三个 UP 主接口，**全是死代码**（全工程零调用者）。缺的只有三样：`Track` 没有 `mid` 字段、  
四个映射函数没把 `mid` 落下来、工程没有打开外部链接的能力（`openLink` 从未被 import）。

---

## 一、现状核实

### 1.1 缺口（逐条落到具体行）

| 缺什么               | 证据                                                                                                                                                                     |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Track` 没有 UP 主字段 | `model/MusicModels.ts:76-100`，字段只有 id/title/artist/coverUrl/duration/videoUrl/bvid/aid/cid/playCount/isLiked/likedAt/audioUrl/audioQuality/audioMimeType/localFilePath |
| 搜索结果没落 mid        | `pages/SearchPage.ets:81` `artist: item.author`；类型 `SearchResultItem`（`MusicModels.ts:306`）也没声明 `mid`                                                                  |
| 排行榜没落 mid         | `SearchPage.ets:107-115` 取了 `v.owner`，但只用了 `owner.name`                                                                                                                |
| 推荐 feed 没落 mid    | `api/BilibiliApi.ts:565-574` **已经把 `owner.mid` 解析出来了**，映射成 Track 时又丢了                                                                                                  |
| 音乐中心没有 mid        | `MusicCenterItem`（`MusicModels.ts:378`）只有 `author: string`，**结构里就没有 mid**                                                                                              |
| 工程不会打开外部链接        | 全工程无 `openLink` / `startAbility(uri)`；唯一的 `want` 用法是后台通知拉起自己（`service/BackgroundPlayback.ts:47`）                                                                       |
| 曲目菜单只有 4 项        | `SearchPage.ets:885-913`：加入队列 / 加入歌单 / 保存合集为歌单 / 下载                                                                                                                    |

### 1.2 现成资产（**死代码，接上就能用**）

| 接口                                          | 位置                         | 能力                                     |
| ------------------------------------------- | -------------------------- | -------------------------------------- |
| `searchUser(keyword, page, pageSize)`       | `api/BilibiliApi.ts:183`   | 搜 UP 主，返回 mid/uname/fans/videos/level  |
| `getUserVideos(mid, page, pageSize, order)` | `api/BilibiliApi.ts:220`   | **UP 主投稿列表（分页）**                       |
| `getFavoriteFolders(mid)`                   | `api/BilibiliApi.ts:689`   | 投稿收藏夹（⚠️ 匿名拿不到，见下）                     |
| `getVideoDetail(bvid)` + `viewCache`        | `api/BilibiliApi.ts:263`   | 换 `owner.mid` 的兜底路，**带 TTL 缓存**，不重复发请求 |
| `slimTrack()` 保留了 `bvid`                    | `model/MusicModels.ts:163` | 已下载/收藏/最近播放的曲目也有 bvid → 都能换 mid        |

### 1.3 匿名态实测矩阵（本轮真机接口实测，`isLogin=False` + buvid + PC UA）

| 能力        | 接口                                      | 匿名可用 | 实测结果                                                           |
| --------- | --------------------------------------- | ---- | -------------------------------------------------------------- |
| 搜 UP 主    | `wbi/search/type?search_type=bili_user` | ✅    | `mid=486906719 uname=索尼音乐中国 fans=950219 videos=258945 level=6` |
| UP 投稿列表   | `x/space/wbi/arc/search`                | ✅    | `code=0`，30 条/页，title/bvid/length 齐全                           |
| UP 资料     | `x/web-interface/card?mid=`             | ✅    | `name=索尼音乐中国 fans=950219 face=…`                               |
| UP 资料（新版） | `x/space/wbi/acc/info`                  | ❌    | **只回 `v_voucher`**，name/face/fans 全空 —— 别用这个                   |
| 投稿收藏夹     | `x/v3/fav/folder/created/list-all`      | ⚠️   | `code=0` 但 `count=None`（登录态才有）—— `getFavoriteFolders` 接线也没用    |
| 视频作者 mid  | `x/web-interface/view`                  | ✅    | `owner.mid=486906719`                                          |
| 搜索结果 mid  | `wbi/search/type?search_type=video`     | ✅    | 每条都带 `mid`（实测 `author=超级爱下雨天 mid=1749710516`）—— **只是工程类型声明漏了** |

> ⚠️ 这次实测纠正了一个很容易踩的误判：`acc/info` 返回 **`code=0`**，  
> 只看 code 会以为「匿名可用」，实际数据是空的。**判据要落到具体字段值，不能只看 code。**

---

## 二、mid 覆盖：四个数据源逐个说

| 数据源             | mid 从哪来                                                       | 覆盖                                   |
| --------------- | ------------------------------------------------------------- | ------------------------------------ |
| 搜索              | 搜索结果 item 自带 `mid`（实测）→ 给 `SearchResultItem` 补 `mid?: number` | ✅ 直接拿                                |
| 排行榜             | `v.owner.mid`（`ranking/v2` 有 owner 对象）                        | ✅ 直接拿                                |
| 推荐 feed         | `owner.mid`（API 层已解析）                                         | ✅ 直接拿                                |
| 音乐中心            | 结构里没有 mid，只有 `related_archive.bvid`                           | ⚠️ 需用 bvid 走 `getVideoDetail` 换（带缓存） |
| 已下载 / 收藏 / 最近播放 | slimTrack 只留 bvid                                             | ⚠️ 同上，用 bvid 换                       |
| 广告 / 登录引导卡片     | 无（`BilibiliApi.ts:561-566` 已剔除非视频项）                           | — 直接隐藏该项                             |

**结论：mid 覆盖率 = 100%**（缺的两类都能用 bvid 兜底换，代价是一次带缓存的 view 请求）。

---

## 三、三个方案

### 方案 A · 跳出 App（推荐先做）

「⋯」菜单加第 5 项「进入 UP 主主页」→ 拉起 B 站空间页。

**改动清单**

1. `Track` 加 `upMid?: string`（用 string 存，`'0'` 视为无；ArkTS 里可选字段用 `?` 最省事，`buildTrack` 同步补 `upMid: partial.upMid ?? ''`）
2. 四个映射函数补 mid（`SearchPage.ets:81 / 107-115`、推荐 feed 映射、`MusicCenterItem` 走 bvid 兜底）
3. `SearchPage.ets:885` 菜单加一项，`resp.index === 4` 分支调 `openUpSpace(track)`
4. 新增 `openUpSpace()`：`upMid` 为空 → 用 `getVideoDetail(bvid)` 换 → `openLink()`

**跳转实现（双路兜底）**

```ts
// 优先 scheme 拉起 B 站 App，失败退到 https（系统浏览器也能开）
const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
await ctx.openLink(`bilibili://space/${mid}`);
// catch 里再试 https://space.bilibili.com/${mid}
```

- `openLink(link: string, options?: OpenLinkOptions)` —— `UIAbilityContext.d.ts:300`，**since 12**，本工程 API 26 可用
- ⚠️ 两次都失败要兜底提示（复用 `AppToast` / 页面 `toast()`），不许静默

**风险 / 验收**

- 菜单从 4 项变 5 项：SDK 文档只写了「支持多按钮」**没写上限**（`@ohos.promptAction.d.ts:458`），原生 AlertDialog 常见上限是 6 → 4→5 安全，但**必须真机点一次**确认不崩；万一崩，退路是把菜单改成自绘 `bindSheet`
- 验收：四个页签各点一次菜单项；没装 B 站 App 的设备上要能退到浏览器；断网时点菜单不能卡死

### 方案 B · 站内 UP 主页页

新页 `pages/UpSpacePage.ets`（`@Component` + `NavDestination`），显示 UP 主资料 + 投稿列表，点条目直接播，不跳出 App。

**改动清单**

1. `api/BilibiliApi.ts` 新增 `getUserCard(mid)` 封装 `x/web-interface/card`（**不要用 `acc/info`**，实测空）
2. 新页面：头像 + 昵称 + 粉丝数 + 投稿列表（`getUserVideos` 分页，`onReachEnd` 加**三重闸门**，照 `SearchPage.ets:569-580` 那套）
3. 列表条目**直接复用 `components/TrackItem.ets`**（`SpaceVideo → Track` 映射：bvid/title/pic/length/author 都有，cid 由播放链路解析）
4. 路由：按 `NavStackHolder` 约定传参 —— 现有只有 `selectedPlaylistId` 一个静态字段，需加 `upMid` / `upName`；转场照 `PlaylistDetail.ets:100-121` 的 `slow(400ms)` 从右滑入
5. 列表末尾要 `.contentEndOffset(CONTENT_END_OFFSET + this.safeBottom)`（`Constants.ts:141`），否则最后一项被悬浮胶囊压住

**风险**

- 投稿列表只有 `bvid`，**cid 要靠播放时再解析**（走 `getVideoDetail` + viewCache，可接受）
- UP 主资料字段名以实测为准（`card.name` / `card.fans` / `card.face`）
- 工作量明显大于 A

### 方案 C · 订阅式歌单流

在 B 之上，把某个 UP 主的投稿**存成本地歌单**，之后可「拉取新投稿」。

**改动清单**：复用现有「保存合集为歌单」那条链（`SearchPage.ets:905 loadCollection`）＋歌单表加「来源 mid / 来源名」两个字段 + 一个「更新此歌单」的动作。

**必须先决策**：`mid` 要不要落库？

- **落**：改 `LibraryStore` 的快照结构（Preferences 单值上限 8192 字节，预算按 6000 收口，`MusicModels.ts:134`），50 首 × 约 12 字节 ≈ 600 字节 → 会挤压现有容量
- **不落**：每次用 `bvid` 走带缓存的 view 换 mid（推荐，零迁移、零预算压力）

---

## 四、四个必须先定的点

1. **菜单加到第 5 项是否可接受？** 还是更想换成自绘菜单（顺带能把「保存合集为歌单」按曲目类型动态隐藏）
2. **跳出去（跳 B 站）还是留在 App（站内页）？** 前者 1 天的量，后者 2~3 天
3. **音乐中心 / 已下载曲目要不要支持？** 支持就得接受「点一次多一次 view 请求（有缓存）」
4. **mid 落不落库？** 影响 C 方案要不要改表

---

## 五、推荐投递顺序

1. **A 的第 1 步**：只加 `Track.upMid` + 四个映射函数落 mid，菜单**先不加项** → 编译验证 mid 真的到位（用 hilog 打一条，确认搜索/排行/推荐三源都有值）
2. **A 的第 2 步**：菜单加第 5 项 + `openUpSpace()` 双路跳转 → 真机验四个页签 + 未装 App 场景
3. **B**（若还想留在 App 内）：新 API 封装 → 新页面 → 路由与转场
4. **C**（若想要订阅）：先定 mid 落不落库

---

## 附录 · 实测脚本（可复现）

`E:/BiliMusic/.workbuddy/tmp/` 下三个脚本，直接跑即可复核本文结论：

| 脚本              | 验证内容                                            |
| --------------- | ----------------------------------------------- |
| `mid_probe.py`  | 搜索结果带 mid、`view` 的 owner.mid、buvid 获取           |
| `up_probe.py`   | `space/wbi/arc/search` 匿名 30 条/页；`acc/info` 匿名空 |
| `card_probe.py` | `x/web-interface/card` 匿名可拿 name/fans/face      |
| `user_probe.py` | `search_type=bili_user` 匿名可搜 UP 主               |

```bash
/c/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe up_probe.py
```

> 脚本里复刻了 wbi 签名（`mixinKey` 置换 + md5），与工程 `utils/CryptoUtil.ts` 的 `WbiSign` 同一套算法。  
> **不要删 `utils/CryptoUtil.ts`** —— `WbiSign` 依赖它的 `md5`（登录已移除，但它还服务于 wbi 签名）。

---

## 落地记录（2026-10-03 · C 方案已实现）

编译判据：`CompileArkTS Finished after 20 s` + `BUILD SUCCESSFUL`，ArkTS ERROR 0。

### 新增

| 文件                                                                                         | 内容                                                                                                                      |
| ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| `pages/UpSpacePage.ets`                                                                    | 站内 UP 主页：资料头（头像/昵称/粉丝/已订阅数）+ 投稿列表（分页 + 三重闸门 + `contentEndOffset`）+ 订阅/拉新按钮 + 骨架空态。转场照 `RecentPage` 的 `slow(400ms)` 自右滑入 |
| `api/BilibiliApi.ts` → `getUserCard`                                                       | 封装 `x/web-interface/card`（**不用 `acc/info`**，实测匿名只回 `v_voucher`）                                                         |
| `utils/TextUtil.ts` → `stripHtmlTags` / `parseDurationText`                                | UP 投稿标题清洗与 `mm:ss` 解析（供新页与歌单详情页共用）                                                                                      |
| `service/LibraryStore.ts` → `subscribeUpPlaylist` / `mergeUpTracks` / `getPlaylistByUpMid` | 订阅歌单的建/并/查；`UpSubscribeResult` 回报 added/dropped/reused                                                                  |


### 修改

| 文件                           | 改动                                                                                                        |
| ---------------------------- | --------------------------------------------------------------------------------------------------------- |
| `model/MusicModels.ts`       | `Track` 加 `upMid`（+`buildTrack`/`slimTrack` 同步）；`SearchResultItem` 补 `mid?`；`Playlist` 加 `upMid`/`upName` |
| `service/LibraryStore.ts`    | **歌单曲目改分片存储**（见下）；四处显式列举字段的构造全部补上来源字段；`deletePlaylist` 清分片                                                |
| `pages/SearchPage.ets`       | 四个映射函数落 mid（音乐中心结构里没有，留空走 bvid 兜底）；菜单加第 5 项「进入 UP 主主页」+ `openUpSpace()`                                   |
| `pages/PlaylistDetail.ets`   | 订阅歌单才多一个菜单项「拉取新投稿」+ `refreshUpTracks()`（顺序翻 3 页、按 id 去重、新的排前面）                                            |
| `service/NavStackHolder.ets` | 加 `upMid` / `upName` 静态字段                                                                                 |
| `pages/Index.ets`            | `pageMap` 注册 `'UpSpace'`                                                                                  |
| `player/MusicPlayer.ts`      | 两处显式 Track 字面量（`mergeTrack` / `toggleLike`）补 `upMid: track.upMid ?? ''`                                   |

### 顺带修掉的既有隐患：歌单超过约 11 首写不进磁盘

实测 **slimTrack 后一条曲目约 519 字节** → 整张歌单塞进 `PREF_PLAYLISTS` 一个 key，  
**超过约 11 首就 `put()` 抛错**（症状：加了歌、重启后消失）。这不是订阅引入的，是一直存在的问题。  
现在元信息留在 `PREF_PLAYLISTS`、曲目按**每片 8 条**拆到 `pl_tracks_{歌单id}_{片号}`，  
上限 `PLAYLIST_MAX_ITEMS = 200`，**旧格式自动兼容**（老数据曲目在 `tracks` 字段里，按 `chunkCount` 分流）。

### 与原方案的差异（有意为之）

1. **没做方案 A（跳出 B 站）**：C 已经包含「进 UP 主页」入口，跳出去只是多一条退路；等 C 在真机跑顺了再考虑加。
2. **菜单只加到第 5 项**（4 → 5，仍在 AlertDialog 常见上限内），「订阅」放在 UP 主页页内做，  
   不占菜单位——菜单越少越好按，而且订阅是「页面级动作」放在页面里语义更顺。
3. **mid 不落 `Track` 之外的第二份**：只进 `Track.upMid`（约 10 字节/首），不建 mid→歌单的独立映射表。

### 真机必须验的 6 项（本轮只能编译过，跑不了真机）

1. 搜索/排行榜/推荐三个页签各点一次「⋯ → 进入 UP 主主页」，看昵称对不对（验证 mid 落地）。
2. 音乐中心 / 已下载曲目点同一项 → 应先转圈再进（走 bvid 换 mid 的兜底路径）。
3. 订阅一个 UP → 回歌单页确认出现订阅歌单，**重启 App 再看是否还在**（验分片存储落盘）。
4. 订阅歌单详情页点「拉取新投稿」→ 确认不重复、能提示新增条数。
5. 断网进 UP 主页 → 应显示「加载失败 / 检查网络」，不是白屏。
6. 菜单 5 项在真机上会不会崩（SDK 文档没给按钮上限，只是推断 6 是常见值）。

### 还没做的

- **UI 高保真稿没补**（`BiliMusic-UI.html` 仍 13 屏，缺 UP 主页这一屏）；设计规范也没写订阅歌单的视觉规范。
- 订阅没有「取消订阅」入口（现在只能删歌单）。
- 订阅没有打开自动更新（每次都要手点「拉取新投稿」）。

---

## 故障排查：真机「进入 UP 主主页 → 加载失败」（2026-10-03 已修）

### 根因不是代码写错，是两件平台侧的事

**① HTTP 412 的真因是「访客身份不完整」**（同一 IP、同一时刻的单变量对照实验）：

| Cookie                            | 结果           |
| --------------------------------- | ------------ |
| 无 Cookie                          | HTTP 412     |
| `buvid3` + `buvid4`（**本工程原来的样子**） | HTTP 412     |
| 再加 `b_nut` + `_uuid` + `b_lsid`   | **HTTP 200** |

工程历来只发 `buvid3` / `buvid4` 两个字段，**从来就不完整**；旧注释「缺 buvid 会 412」把因果说窄了。  
已在 `service/BiliDevice.ts` 的 `completeVisitorCookie()` 补齐（`b_nut` 秒级时间戳、  
`_uuid` = buvid3 派生 20 位大写 hex + `infoc`、`b_lsid` = 4 位 + `_` + 毫秒尾数），  
**只补字段、不重拉 spi**（412 是「缺字段」不是「值旧」，重拉反而会换掉已稳定的 buvid）。

**② wbi 版空间接口对匿名风控极敏感，老接口反而更宽松**：

- `x/space/wbi/arc/search` → `-352 风控校验失败` / HTTP 412；
- `x/space/arc/search` **必须带 `jsonp=jsonp`**（不带 → `-799 请求过于频繁`；带上 → `code=0`、正常 30 条）。  
  → `getUserVideos` 已改成**自动降级**到 `getUserVideosLegacy`。

同一时刻复测：`x/web-interface/card`（UP 资料）、`search/type`、`popular` **都 code=0 正常**  
——被限的只有空间投稿列表，所以资料头仍能显示。

### 界面现在会自己说原因

`UpSpacePage.describeError()` 从 `BiliApiError.message` 里抠出 code 翻成人话  
（`-352/-509/-799` →「B 站限制了当前访问，过一会儿再试」、`-403`、HTTP 412 单独文案），  
失败空态**显示原因 + 「重试」按钮**（带 4 秒冷却）+**「在 B 站打开」按钮**（唯一 100% 可用的路）。

---

## 第二次修复：空间接口靠不住，改用「搜索反查」（2026-10-03 20:25 · 最终方案）

### 重复实验推翻了上一节的结论

同一 URL 连打 8 次（间隔 1.5s）→ **0/8 成功**，失败在 412 / -799 之间随机跳；  
冷却 45s → 412；间隔 8s → 成功 30 条；间隔 20s / 40s → 412。**没有时序规律**。

| 上一节的结论              | 现在的结论                                           |
| ------------------- | ----------------------------------------------- |
| 「`jsonp=jsonp` 才能过」 | ❌ **误判**，与成败无关（带与不带都各自成功过）                      |
| 「412 = 访客身份不完整」     | ⚠️ **降级为预防性措施**：补齐 cookie 能进到 200 层，但密集场景照样 0/8 |
| 「wbi 不行就降级老接口」      | ⚠️ 两个都在限流，**降级只是换个方式被拒**                        |

### 现在的加载策略

1. **首选：搜索反查**（`BilibiliApi.getUserVideosViaSearch`）——用搜索接口按 UP 昵称搜，  
   再按结果的 `mid` 精确过滤。实测「索尼音乐中国」p1 命中 **19/20**、p2 **13/20**，  
   两次都 `code=0`；搜索接口与 `card` / `popular` 是本机一直稳定的那几个。  
   结果按 `pubdate` 重排成「最近投稿在前」（搜索默认按相关性）。
2. **兜底：空间接口**（wbi ↔ 老接口**按轮次交替**，不再同一次进入连发两枪）。
3. 列表 / 订阅 / 拉取新投稿**全部**走 1，失败才 2。
4. 失败页给「在 B 站打开」（`openLink` 到 `https://space.bilibili.com/{mid}/video`）——  
   站内接口被限时的唯一可靠出路。

### 代价与预期

- 只展示**最近约 60 条**（搜索翻 3 页），不支持上拉翻页 → 底部文案已改成  
  「订阅可持续获取新投稿」而不是「已经到底啦」。
- 昵称搜不到该 UP 时会命中空 → 自动退回空间接口（可能仍失败）→ 这时只能靠「在 B 站打开」。
- **订阅语义与这个局限天然契合**：只关心新投稿，而搜索反查按时间重排后就是最新的。

### 真机自己看原始返回

`HttpUtil` 一直用 `hilog.info(0x0000, 'BiliMusicHttp', …)` 打印**响应前 200 字符**：

```bash
hdc shell "hilog | grep BiliMusicHttp | tail -40"
```

若看到 `search/type` 有 `code=0` 而 `arc/search` 是 412/-799，就说明新路径已生效、空间接口仍被限。
