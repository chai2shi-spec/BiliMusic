# B 站字幕获取失效 —— 诊断与 AI 实施规格

> **本文只出规格，不含已实施的代码改动。** 交 AI 照改时按 F1 → F2 → F3 顺序执行，每步可独立编译验证。
> 配套阅读：本文件与 `歌词同步问题诊断与方案.md`、`LOGIN.md`（登录三态）互补，不重叠。

---

## 0. 症状与结论速览

**症状**：获取不了 B 站字幕（CC）和 B 站 AI 字幕——手动入口拿不到、自动兜底也不出场。

**结论**：取数链路代码本身是通的，问题出在三件事叠加——

1. **失败全部静默**：登录失效（code -101 / `subtitles` 空数组）与「真没字幕」在代码里同落 null，无日志不可区分；
2. **瞬时失败被钉死 24h**：超时、风控排队、网络抖动与「视频确实没字幕」共用同一条 miss 缓存（TTL=24h），失败一次后字幕代码 24 小时内根本不执行；
3. **用户不知道差什么**：长按面板失败只有一句笼统提示，不知道是「没登录」还是「这视频没字幕」。

病根定位（行号为 2026-10-27 现状，改动后行号会漂移，以引用代码字样为准）：

| # | 病根 | 位置 |
|---|---|---|
| 1 | 登录态失效时 `subtitles` 空数组 / code -101，静默落 null，无日志 | `api/SubtitleLyricApi.ts` `fetchBestSubtitleMeta` 内 `code !== 0` 与空数组两个分支 |
| 2 | 任何失败都写进 24h miss（与五源共用），期间字幕环节被读短路 | `api/LyricsApi.ts` `getLyricForTrack` 末尾写 miss + `isMissFresh` 短路；`service/LyricCacheStore.ts` `MISS_TTL_MS = 24h` |
| 3 | 6s 总超时要覆盖 nav 换 key → getVideoDetail 补 cid → wbi/v2 → 字幕 CDN 四个串行请求；超时分支无日志 | `api/SubtitleLyricApi.ts` `SUBTITLE_TIMEOUT_MS` 与 `fetchSubtitleLyric` 超时回调 |
| 4 | 字幕是兜底链第 3 环，五源搜到歌词就永远轮不到（**设计使然，不改**） | `api/LyricsApi.ts` `getLyricForTrack` 链序 |

---

## 1. 机理详解（为什么是这三件事）

### 1.1 登录态是字幕列表的硬前提

`/x/player/wbi/v2` 返回的 `data.subtitle.subtitles` **强依赖登录 Cookie**：

- `SubtitleLyricApi.ts` 文件头注释原文：「字幕列表对登录态有强依赖，匿名请求 `subtitles` 多为空数组 —— 未登录时本源自然失效，属预期退化」。
- `LoginStore.isLoggedIn()` 只看本地有没有 Cookie，**不验证有效性**；登录过但已失效（`isLoginStale()`）时，过期 SESSDATA 照发、照样拿空列表或 code -101。
- 两种失效形态（-101 与空数组）在现日志里**完全不可区分**——都静默落 null。

推论：**「CC 和 AI 同时失效」的最典型原因是登录态**。CC 与 AI 是同一个列表里的不同条目（`ai_type === 1` 区分），列表拿不到则两者一起消失。

### 1.2 miss 缓存把字幕环节钉死 24h

`getLyricForTrack` 的失败出口只有一条：末尾 `writeLyricCache(toEntry(track, key, null, false, null))` 写 `status=miss`。下次进来 `cached.cacheKey === key && isMissFresh(cached)` 直接 `return null`——**五源、旧缓存兜底、字幕三段代码全被跳过**。

关键缺陷：miss 无法区分「这次没试成」（超时/风控/网络）与「确实没有」（视频无字幕、五源真没这歌）。前者被钉 24h 是**错误的**。

唯一不受影响的入口是长按面板 `chooseBiliSubtitle`（不读缓存、不写 miss）——这也是下文验证方法①的依据。

### 1.3 6s 总超时的预算挤兑

`SUBTITLE_TIMEOUT_MS = 6000` 是**整条字幕链**的墙钟预算，链上最多四个串行网络动作：

```
nav（换 WBI key，纯内存缓存 6h，冷启动必发）
→ getVideoDetail（列表入口的歌 cid 全空，必须现补；带退避重试，更耗预算）
→ /x/player/wbi/v2（BiliRequestGate 普通优先级，会被播放链 view/playurl 垫后）
→ 字幕 CDN JSON
```

风控冷却期或播放链高峰时，闸门排队几秒很常见 → 超时 → **超时回调连一条日志都没有** → 落 null → 又被写进 miss（1.2 叠加）。

### 1.4 触发次序（维持设计，不动）

字幕排在「缓存 miss → 五源搜索 → 旧 OK 缓存兜底」之后，只有曲库外的歌（VOCALOID 原创 / 二次创作 / 电台片段）才有机会出场。这是有意设计：搜得到歌词的歌轮不到字幕，且提前会让每首 B 站歌多发 1~2 个请求。**本次不改**（F4 列为待裁决项）。

---

## 2. 改动规格（F1 ~ F4）

### F1（P0）失败可见化：补诊断日志，只加日志不改行为

文件：`api/SubtitleLyricApi.ts`。

| 位置 | 加什么 |
|---|---|
| `fetchBestSubtitleMeta` 的 `code !== 0` 分支 | `console.info('[Lyric] subtitle denied code=${code} msg=${message} cookie=${isLoggedIn() ? 1 : 0}')` |
| `fetchBestSubtitleMeta` 的空 `subtitles` 分支 | `console.info('[Lyric] subtitle list empty cookie=${isLoggedIn() ? 1 : 0}')` —— **与上一条必须用不同字样**，解决 -101 与空数组不可区分 |
| `fetchSubtitleLyric` 超时回调 | `console.warn('[Lyric] subtitle timeout ${SUBTITLE_TIMEOUT_MS}ms track=...')` —— 当前超时完全无痕 |
| `resolveSubtitleTarget` 返回 null 的两个分支 | 分别打「detail fetch failed（补 cid 失败）」与「no bvid/aid（无法定位视频）」 |

规则：
- 统一前缀 `[Lyric] subtitle`，沿用歌词链既有 `console.info` 风格（歌词链不用 hilog）。
- 登录态经 `service/LoginStore.ts` 的 `isLoggedIn()` 导入（`.ts` 可正常 import，无 kit 限制）。
- **只加日志不改控制流**。

### F2（P0）失败分级：瞬时失败不再写 24h miss

核心原则：**「视频确实没字幕」才配写 miss；「这次没试成」不配。** 不碰缓存 schema、不落盘。

**(a) `api/SubtitleLyricApi.ts` 新增 outcome 结构与导出函数**：

```
export interface SubtitleOutcome {
  result: LyricResult | null;   // 命中时的结果，与现 fetchSubtitleLyric 返回一致
  definitive: boolean;          // true = 结论性失败（值得写 miss）
  reason: string;               // 机器可读原因，供 F3 文案分型
}
export function fetchSubtitleOutcome(track: Track, kind: string): Promise<SubtitleOutcome>
```

- `runSubtitleChain` 内部改产 `SubtitleOutcome`；现 `fetchSubtitleLyric(track, kind)` **保持签名不变**（超时壳包裹 outcome 内部实现，兼容旧调用点），内部委托 outcome 版本。
- **definitive = true**（结论性失败，可写 miss）：`code !== 0` 且非风控码、`subtitles` 空数组、选优后无候选、有效行 < 3、字幕文件 body 空。
- **definitive = false**（瞬时失败，不写 miss）：6s 超时、`catch` 异常、HTTP/网络错误、风控码 **-799 / -352 / -412**（判定沿用 `BilibiliApi.ts` 既有分类，不另造）。
- reason 取值约定：`'denied'`（code≠0）/ `'empty'`（列表空）/ `'no-candidate'` / `'dirty'`（行数不足）/ `'timeout'` / `'network'` / `'risk'`（风控码）/ `'no-target'`（bvid/aid 全空）。

**(b) `api/LyricsApi.ts` 兜底链改用 outcome**（`getLyricForTrack` 字幕环，原 532-538 一带）：

- 改调 `fetchSubtitleOutcome`：
  - 命中 → 照旧写 OK 缓存并返回；
  - `definitive=true` → 照旧写 24h miss；
  - `definitive=false` → **不写 miss**，改走**内存节流**：模块级 `Map<string, number>`（trackId → 上次尝试时刻），10 分钟内直接跳过字幕环继续走「写 miss 之外的正常返回 null」路径。
- 节流细节：
  - `const subtitleRetryGate = new Map<string, number>()`；命中节流时不发任何网络请求。
  - Map 上限 200 条，超过时清掉最早写入的一半（防长会话膨胀）。
  - **不进 Preferences、不落盘**，进程重启自然清零——瞬时失败重试一次的代价本来就低。

### F3（P1）失败文案分型：让用户知道差的是登录还是字幕

文件：`api/LyricsApi.ts`（`chooseBiliSubtitle`）+ `components/player/LyricsComponent.ets`（长按面板 `useBiliSubtitle`）。

- `chooseBiliSubtitle` 返回值扩展：新增 `chooseBiliSubtitleOutcome(track, kind): Promise<SubtitleOutcome>`（旧函数保留委托，避免动其它调用点）；命中写 manual 缓存的语义**不变**。
- `LyricsComponent.useBiliSubtitle` 失败分支按 outcome 分型写 `lyricInfo`（该文案通道现成）：

| 条件 | 文案 |
|---|---|
| `!isLoggedIn()` 或 `isLoginStale()` | 「登录后可获取 B 站字幕」（引导去设置页登录，符合登录三态约定） |
| `definitive === true` | 「该视频没有可用的 CC / AI 字幕」 |
| `definitive === false` | 「网络繁忙，稍后再试」 |

- 判定次序：登录态优先于 definitive——登录失效时即使返回 definitive=true（空列表），真实原因也是登录，不能骗用户「没字幕」。
- **明确不做匿名降级重试**：文件头已定论「匿名请求 subtitles 多为空数组，不发额外请求补救」，此设计维持；引导登录是唯一正路。

### F4（P2，默认不做，待用户裁决）

把字幕环从「五源全败后」提前到「缓存 miss 即尝试」。代价：每首 B 站歌多发 1~2 个请求、五源与字幕抢 6s 预算、字幕命中可能覆盖五源本可命中的更好歌词。**默认维持兜底设计不动**。

---

## 3. 硬约束（违反即作废）

1. 歌词链路**绝不抛错**：outcome 的 reason 只是数据，不是异常；所有改动的失败终态仍是「和现在一样返回 null」。
2. 不改 `LrcView` 渲染几何、不改五源搜索链、不动 `BiliRequestGate` 优先级与 `HIGH_PATHS`。
3. miss 语义不污染：`manual` 缓存永不被自动链覆盖（现状保持）；`skipped` 永久跳过（现状保持）。
4. ArkTS：禁 `any/unknown/Function` 常规代码；新增类型显式 `interface`；节流用 `Map` 不用对象字面量当字典。
5. 日志只加信息不改控制流；风控码判定沿用 `BilibiliApi.ts` 既有分类。
6. `fetchSubtitleLyric` 旧签名保持兼容（现调用点：`LyricsApi` 兜底链、冥想卡/卡片链路经 `getLyricForTrack` 间接使用）。
7. 编译验证必须真跑 `CompileArkTS`（先 `touch` 改动文件破增量缓存），判据见工作记忆「工程结构与编译」节。

## 4. 改动文件清单

| 文件 | 性质 | 阶段 |
|---|---|---|
| `entry/src/main/ets/api/SubtitleLyricApi.ts` | 加日志（F1）+ outcome 结构与 `fetchSubtitleOutcome`（F2a） | F1/F2 |
| `entry/src/main/ets/api/LyricsApi.ts` | 兜底链改 outcome + 内存节流（F2b）；`chooseBiliSubtitleOutcome`（F3） | F2/F3 |
| `entry/src/main/ets/components/player/LyricsComponent.ets` | `useBiliSubtitle` 失败文案三型（F3） | F3 |
| `service/LyricCacheStore.ts`、`lyric/LrcView.ets`、`utils/BiliRequestGate.ts` | **不改**（只读依赖） | — |

## 5. 验收清单

1. 未登录（或登录已失效）时点长按面板「B站字幕」→ 文案为「登录后可获取 B 站字幕」，无网络异常表现。
2. 对已知有 AI 字幕的视频，登录后手动入口命中，日志出现 `subtitle hit lang=ai-zh ...`。
3. 断网/飞行模式点手动入口 → 「网络繁忙，稍后再试」，且**不产生 miss 缓存**（恢复网络重进播放页会自动重试）。
4. 对确实无字幕的视频 → 「没有可用的 CC / AI 字幕」，写 miss，24h 内进播放页不再发字幕请求。
5. 模拟超时（闸门冷却期进播放页）→ 日志出现 `subtitle timeout`，无 miss 写入；10 分钟后同一首歌自动重试。
6. 登录失效 + 视频实际有字幕 → 文案是「登录后可获取」而不是「没有字幕」（判定次序正确）。
7. 现有歌词功能回归：五源命中、manual 缓存、跳过歌词（skipped）、重新获取（clearLyricCache）四条路径行为不变。
8. 桌面卡片/冥想卡歌词链路（间接经 `getLyricForTrack`）行为不变。

## 6. 上线前的快速验证（不改代码也能做）

1. **歌词长按面板点「B站字幕」**（CC / AI 按钮）：能拿到 → 问题在 miss 钉死或触发次序；拿不到 → 登录态或超时。
2. 设置页确认登录状态是否显示「登录已失效 · 点击重新登录」。
3. hilog 过滤 `[Lyric]`：`subtitle hit` = 链路通；`subtitle chain failed` = 异常；**什么都没有** = miss 短路或超时（改前超时无日志，改后应有）。
