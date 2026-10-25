# 空壳化 L1 · 自定义 API 网关实施规格

> 2026-10-25 编写 · **只出规格，不改代码**
> 目标工程：`E:/BiliMusic/HarmonyOS-Phone`（compatibleSdk 23 / targetSdk 26）
> 形态：用户填一个自建反代基址 → app 把 `api.bilibili.com` 的请求改投过去，**功能 100% 不变**

---

## 0. 结论：不在 27 处调用点改，只在 HTTP 入口做一次重写

工程里 `api.bilibili.com` 被拼了 **16 次**、`passport.bilibili.com` 被拼了 **7 次**（都在 `api/BilibiliApi.ts`）。直觉改法是把这 23 处逐个换成可配置函数 —— 那是 23 个易漏、易回退的点。

**正确做法**：把重写收在 `utils/HttpUtil.ts` 的请求入口。所有 B 站请求都从那里出去，改 3 个方法即可，**调用点零改动**。

```
用户填 origin（如 https://gw.example.com）
        ↓  Preferences
utils/ApiEndpoint.resolve(url)   ← 唯一的重写点
        ↓
utils/HttpUtil.ts（requestText / requestTextWithCookies / probeRedirectLocation）
        ↓
BiliRequestGate（节流/熔断，判定要认新基址）
```

---

## 1. 为什么这个方案成立（四条技术前提，已逐条核实）

| # | 前提 | 证据 |
|---|---|---|
| 1 | **Cookie 是手动拼进 header 的**，不依赖 HTTP 客户端的 cookie jar / domain 匹配 | `utils/HttpUtil.ts:122`：`header['Cookie'] = cookieParts.join('; ')`（`buildHeader` :101 起） |
| 2 | **Referer 也是手动设的**，代理不改也能带上 | `utils/HttpUtil.ts:106-108`：`header['Referer'] = BILI_REFERER` |
| 3 | **签名与域名无关** | `api/WbiSign.ts` 只签 query（`w_rid = md5(query + mixinKey)`）；`utils/AppSign.ts` 只签参数（`sign = md5(query + appsec)`）。两者都不参与 URL 构造 |
| 4 | **响应结构不变**（网关原样透传，不改写 JSON） | 所有解析代码零改动 |

第 1 条是整个方案的地基。如果 Cookie 靠 cookie jar 自动管理，换域名会因 domain 不匹配全部丢登录态；这里是手动拼的，**换到任意域名都照常生效**。

---

## 2. 改动清单（6 项，含准确行号）

### 2.1 新增存储键与默认值

**文件**：`common/Constants.ts`（`PREF_` 段，第 108~167 行这一片）

```typescript
/** 自定义 API 网关基址（空串 = 走官方 api.bilibili.com）。仅 origin，不带路径与尾斜杠 */
export const PREF_API_BASE: string = 'bilimusic_api_base';
/** 官方 API 基址（默认值 / 回退值） */
export const BILI_API_OFFICIAL: string = 'https://api.bilibili.com';
```

> 保留现有 `BILI_API` 常量不动（它仍是默认基址，27 处调用继续用它），**新增**的只是「用户覆盖值」。

### 2.2 新增 `utils/ApiEndpoint.ts`

职责单一，只做四件事：

| 方法 | 作用 |
|---|---|
| `init(): Promise<void>` | 启动时从 Preferences 读一次，写进内存；`AppContainer` 或 `EntryAbility` 调用 |
| `base(): string` | 当前生效基址（内存值非空则用它，否则 `BILI_API_OFFICIAL`） |
| `isCustom(): boolean` | UI 与日志用 |
| `resolve(url: string): string` | **核心**：仅当 `url` 以 `BILI_API_OFFICIAL` 开头且已配置自定义基址时，把该前缀替换成 `base()`；其余 URL 原样返回 |

`resolve` 的硬约束：

- **只匹配 `https://api.bilibili.com` 前缀**，用 `url.indexOf(BILI_API_OFFICIAL) === 0` 判断（不要用正则，避免 `.` 与 `//` 的转义坑）；
- **不动** `passport.bilibili.com`（登录保持官方，见 §5）；
- **不动** `search.bilibili.com`、`b23.tv`、`*.hdslb.com`、`*.bilivideo.com`；
- **不做任何 header / body 加工** —— 加工交给网关，客户端越薄越好。

### 2.3 `utils/HttpUtil.ts`：三个入口各加一行

| 方法 | 位置 | 改法 |
|---|---|---|
| `requestText` | `:179` | 方法首行加 `const target: string = ApiEndpoint.resolve(url);`，其后 `BiliRequestGate.acquire(url)` 与 `req.request(url, ...)` 全部改用 `target` |
| `requestTextWithCookies` | `:288` | 同上 |
| `probeRedirectLocation` | `:233` | 同上 |

⚠️ **日志打原始 `url`，不要打 `target`**。`hilog` 里 `req %{public}s` 目前打的是调用方传的 URL，改造后应保持 —— 排障时看到的是「逻辑路径」，代理前缀是部署细节。若要同时看实际目标，加一条 `[ApiEndpoint] custom base applied` 的 info 日志（**只在 `resolve` 真的发生替换时打，不要每请求一条**）。

### 2.4 `utils/BiliRequestGate.ts:70-73`：`isBiliUrl` 认新基址

现状：

```typescript
static isBiliUrl(url: string): boolean {
  return url.indexOf(BILI_API) === 0 || url.indexOf(BILI_PASSPORT) === 0 ||
    url.indexOf('bilibili.com') >= 0 || url.indexOf('b23.tv') >= 0;
}
```

改成：**先按当前基址判**，再走原有判定。

```typescript
static isBiliUrl(url: string): boolean {
  const base: string = ApiEndpoint.base();
  if (base !== BILI_API_OFFICIAL && url.indexOf(base) === 0) {
    return true;
  }
  return url.indexOf(BILI_API) === 0 || url.indexOf(BILI_PASSPORT) === 0 ||
    url.indexOf('bilibili.com') >= 0 || url.indexOf('b23.tv') >= 0;
}
```

⚠️ **不要删掉原有的 `bilibili.com` / `b23.tv` 判定**。登录（passport）、短链解析、HTML 兜底仍然直连官方，它们必须继续受节流保护。

⚠️ 节流策略**不能因为走代理就关掉**。B 站风控同时看 IP 与请求频率，代理只换了出口 IP，尖峰照样吃 `-352`。闸门保留是特性，不是遗留。

### 2.5 `pages/SettingsPage.ets`：新增「数据源」入口

现状：设置页是卡片 + `IconEntryRow` 模式（`:201-245`），账户卡在最上。

新增一行入口（放在「账户」卡之后、音质/播放等分组之前）：

- 标题：`数据源`
- 副标题（动态）：`官方` / `自定义 · gw.example.com` / `自定义（未验证）`
- 点击 → 打开配置页（建议新建 `pages/ApiSourcePage.ets`）

**新增子页必须走 `LazyPageRegistry`（2026-10-17 启动优化的硬约束，三步缺一不可）**：

1. 页面文件内：`@Builder function ApiSourcePageBuilder()` + `export const ApiSourcePageWrapped: WrappedBuilder<[]> = wrapBuilder(ApiSourcePageBuilder);`
2. `service/LazyPageRegistry.ets` 的 `loadByName` 加一个 case（动态 import 路径**必须是字符串字面量**，ArkTS 不支持变量拼接）：
   ```typescript
   case 'ApiSource': {
     const m = await import('../pages/ApiSourcePage');
     builders.set(name, m.ApiSourcePageWrapped);
     break;
   }
   ```
3. 跳转走 `NavStackHolder` 压栈 + `Index.pageMap` 的 `LazyDest`（**不要用已废弃的 router**）

⚠️ `wrapBuilder` 只接受**本文件内的直接 @Builder 引用**（编译期校验），所以第 1 步的 `Wrapped` 必须定义在页面文件自己里，不能跨文件传。

### 2.6 配置页 `pages/ApiSourcePage.ets`（新建）

| 元素 | 规格 |
|---|---|
| 输入框 | `TextInput`，placeholder `https://your-worker.example.com`，`type: InputType.Normal`，`enterKeyType: EnterKeyType.Done` |
| 说明文案 | 「只填域名，不要带 `/x/...` 路径。留空则使用官方接口。」 |
| 「验证」按钮 | 见 §4 的自检判据；验证中禁用重复点击 |
| 「保存」按钮 | 校验通过才写 Preferences；写后调 `ApiEndpoint.init()` 刷新内存值 |
| 安全警示 | 红字或警示图标：「网关会收到你的完整登录凭据（Cookie）。只填写你自己部署的地址。」 |
| 恢复默认 | 清空输入并写空串 |

**输入校验（保存前，四条全过才允许写入）**：

1. 非空时必须以 `https://` 开头（**拒绝 http**，明文会泄漏 SESSDATA）；
2. 不含路径/查询：把 `https://` 之后的部分按 `/` 切，只允许一段（即纯 host[:port]）；
3. 不能是 `api.bilibili.com` / `bilibili.com` 结尾（避免用户误填官方又以为在走代理）；
4. 去掉可能误粘的尾部 `/`，统一存成 `https://host` 形式。

---

## 3. 网关侧规格（用户要部署的那一半）

这一步是「手动输入 API」的另一半，**必须写清楚，否则用户不知道填什么才有效**。

### 3.1 最小可用实现（任意语言，30 行以内）

```
收到请求 → 拼 https://api.bilibili.com + 原 path + 原 query
        → 原样转发 method / headers / body
        → 原样返回 status / headers / body
```

Cloudflare Worker / Node / Nginx 反代 / 自建 Go 服务都可以。要点：

| 必须做 | 说明 |
|---|---|
| 透传 `Cookie` | 登录态与 buvid 都在里面 |
| 透传 `Referer` / `User-Agent` | 客户端已设，别覆盖；缺 Referer 会被部分接口拒 |
| 透传 `Set-Cookie` | `nav` 刷新可能下发新 cookie |
| 透传 `Range` 请求头与 `206` 响应 | 下载续传依赖 |
| 保留 JSON 原文 | **禁止**改写、包裹、重排字段 |

| 禁止做 | 后果 |
|---|---|
| 改写响应 JSON（如统一包一层 `{data:...}`） | 客户端所有解析崩，且 `BiliEnvelope` 的 `code` 判定失效 |
| 改写音频/封面直链 | 直链指向 CDN，改写会破坏签名 |
| 吞掉 `Set-Cookie` | buvid 激活与登录刷新失效 |
| 加自己的鉴权头到上游 | 可能被判非法请求 |

### 3.2 可选增强（网关的真正价值）

| 能力 | 收益 |
|---|---|
| 出口 IP 轮换 / 固定住宅 IP | 直击「登录后 `-352` 不能播」的根因 |
| 缓存 `view` / `playurl` 短时结果（60~300s） | 减少上游请求，降低风控命中 |
| 固定 `buvid` 透传 | 避免每次冷启动换指纹被怀疑 |
| 请求日志（脱敏 Cookie） | 排障 |

---

## 4. 自检判据（这里最容易写错）

验证请求：`GET {base}/x/web-interface/nav`

**通过判据**：

```
HTTP 200
且响应体能 JSON.parse
且结果对象里存在 "code" 字段（不论其值）
```

⚠️ **不能用 `code === 0` 当判据**。未登录时 `nav` 返回 `code: -101`（未登录），这是**链路完全正常**的表现 —— 用户很可能在没登录的状态下配置网关。把 `-101` 判成失败会让正确的网关被拒绝。

**失败信号对照表**（用于给出可读错误，而不是「验证失败」四个字）：

| 现象 | 原因 | 提示文案 |
|---|---|---|
| HTTP 404 | 网关没做通配路由，路径被吃掉 | 「网关没有转发这个路径，检查路由规则」 |
| HTTP 403 | 网关缺 Referer 或要求额外鉴权 | 「网关拒绝了请求，检查是否要求额外的鉴权头」 |
| HTTP 5xx | 网关自身异常 | 「网关内部错误」 |
| JSON 解析失败 / 无 `code` 字段 | 返回的不是 B 站数据（可能是网关首页 / 错误页） | 「返回的不是接口数据，检查是否填成了网站首页」 |
| 超时（>8s） | 网关不可达 / 出口被墙 | 「连接超时」 |

超时时间：自检用 **8s**（`connectTimeout: 8000, readTimeout: 8000`），不要用默认 15s——用户配错地址时等 15 秒体验很差。

---

## 5. 边界：明确不代理的东西

| 不代理 | 理由 |
|---|---|
| `passport.bilibili.com`（登录 7 处调用） | 扫码/短信登录都在 `pages/LoginPage.ets`，其中短信登录含**整屏极验 WebView**（`geetestOverlay`，gt.js product=popup + 内联 HTML + `javaScriptProxy` 桥回传 validate/seccode/challenge），且文件头明确记录「极验 WebView 只在 geetest_verify 阶段挂载，且**必须是整屏**」。这条链路与 passport 域强绑，代理它等于把已验证的登录流程整个推翻，收益极低（登录不是风控重灾区）。**登录保持官方** |
| `*.hdslb.com` 封面图 | 图床防盗链只校验 Referer，客户端已带；代理图片会显著增加网关带宽 |
| `*.bilivideo.com` 音频流 | 直链自带签名与时效，代理无法改写；下载 `Range` 续传在客户端已实现（`DownloadManager.ts:1030`） |
| `b23.tv` 分享短链 | 走 `probeRedirectLocation` 探 302，风控极轻 |
| `search.bilibili.com` HTML 兜底（`BilibiliApi.ts:314`） | 一期不动。若真机发现这条也吃风控，再单独纳入重写（网关需额外转发该域） |

**「登录走官方、数据走网关」是这套方案最省事的分界**：它让 23 处 URL 里只有 16 处需要被重写，passport 那 7 处完全不动。

---

## 6. 风险与对策

| 风险 | 对策 |
|---|---|
| 网关收到完整 Cookie（含 `SESSDATA`） | UI 强制警示；文档建议「只填自己部署的地址」；不提供任何预置第三方地址 |
| 用户填错 → 全站不可用 | 保存前必须过 §4 自检；失败不写入；设置页入口副标题持续显示当前状态 |
| 网关超时拖慢全站 | 自检 8s 超时；可考虑把 `requestText` 的 15s 在走自定义基址时降到 10s（可选，需评估） |
| 明文 http 泄凭据 | 输入校验直接拒绝非 https |
| 误以为「走了代理就不会被风控」 | 文档与 UI 文案明确：代理只换 IP，频率风控仍在，节流闸门照旧生效 |
| 配置写坏导致启动即崩 | `ApiEndpoint.init()` 全程 try/catch，异常一律回落官方基址 |

---

## 7. 验收清单（真机）

| 项 | 判据 |
|---|---|
| 未配置时行为不变 | 清空配置 → 首页推荐、搜索、点播、下载、收藏同步全部与改前一致 |
| 配置生效 | 填有效网关 → 保存 → **不重启**，首页下拉刷新即走代理（抓包或网关日志可见请求） |
| 登录态穿透 | 已登录账号 → 走网关后点播成功，`nav` 返回 `isLogin: true` |
| 节流仍生效 | 走网关时连续快速切歌，`hilog` 仍有闸门排队日志；无 `-352` 爆发 |
| 自检正确性 | 未登录状态下验证一个正常网关 → **必须通过**（`code: -101` 不算失败） |
| 失败可读 | 填一个 404 网关 → 提示「网关没有转发这个路径」，不是「验证失败」 |
| 回退 | 清空配置 → 立即回到官方，无需重启 |
| 编译 | `CompileArkTS` 真执行 + ArkTS ERROR 0 + `BUILD SUCCESSFUL`（改前 `touch` 源文件破缓存） |

---

## 8. 回退

| 改动 | 回退动作 | 残留 |
|---|---|---|
| `ApiEndpoint` | `resolve()` 恒返回入参（一行） | 无 |
| `HttpUtil` 三处 | 把 `target` 改回 `url` | 无 |
| `BiliRequestGate` | 删掉新增的 base 判定分支 | 无 |
| 设置页入口 | `if (false)` 隐藏或删行 | Preferences 里的键值残留，无害 |

**全部改动互不依赖「必须先做哪一步」**，可以整批回退。

---

## 9. 可粘贴给 AI 的 prompt

```text
在 E:/BiliMusic/HarmonyOS-Phone 实施「自定义 API 网关（L1）」，严格按规格，不要扩展范围。

【新增】common/Constants.ts 增加：
  PREF_API_BASE = 'bilimusic_api_base'
  BILI_API_OFFICIAL = 'https://api.bilibili.com'
（保留现有 BILI_API 常量不动）

【新增】utils/ApiEndpoint.ts，四个方法：
  init(): Promise<void>  —— 启动时从 Preferences 读一次，异常回落官方
  base(): string         —— 内存值非空则用它，否则 BILI_API_OFFICIAL
  isCustom(): boolean
  resolve(url): string   —— 仅当 url.indexOf(BILI_API_OFFICIAL) === 0 且已配置时，
                            把该前缀替换为 base()；其余原样返回。
                            用 indexOf 判断，不要用正则。

【改】utils/HttpUtil.ts 三个方法（requestText:179 / probeRedirectLocation:233 /
     requestTextWithCookies:288）：首行加 const target = ApiEndpoint.resolve(url)，
     其后传给 BiliRequestGate.acquire 和 req.request 的都改成 target。
     ⚠️ hilog 日志继续打原始 url，不要打 target。

【改】utils/BiliRequestGate.ts:70 isBiliUrl：先判 url.indexOf(ApiEndpoint.base()) === 0
     且 base() !== BILI_API_OFFICIAL 时返回 true；否则走原有判定。
     ⚠️ 原有 bilibili.com / b23.tv 判定必须保留（passport、短链、HTML 兜底仍直连官方）。

【新增】pages/ApiSourcePage.ets + 设置页「数据源」入口行：
  - 页面文件内定义 @Builder + export const ApiSourcePageWrapped = wrapBuilder(...)；
    在 service/LazyPageRegistry.ets 的 loadByName 加 case 'ApiSource'（动态 import
    路径必须是字符串字面量）
  - 输入框只接受 origin（https://host，无路径、无尾斜杠），拒绝 http
  - 「验证」请求 GET {base}/x/web-interface/nav，超时 8s
  - 通过判据：HTTP 200 且 JSON 可解析 且存在 "code" 字段（不得要求 code === 0，
    未登录时 -101 是正常的）
  - 失败按 404 / 403 / 5xx / 非 JSON / 超时 给出可读文案
  - 保存后调 ApiEndpoint.init() 使配置即时生效，不需要重启
  - 必须显示安全警示：网关会收到完整 Cookie，只填自己部署的地址

【不做】不代理 passport.bilibili.com、hdslb.com、bilivideo.com、b23.tv、search.bilibili.com。

【收尾】编译（先 touch 改动文件），CompileArkTS 真执行 + ArkTS ERROR 0 + BUILD SUCCESSFUL。
```

---

## 10. 之后的 L2 路径（本次不做，仅记录衔接点）

如果将来真要接「通用音源协议」，本方案的三个产物可以直接复用：

- `ApiEndpoint` 的「基址 + 校验 + 自检」模式 → 演变成「音源列表 + 每源自检」；
- `HttpUtil` 的入口重写 → 演变成「按 sourceId 分发到不同 transport」；
- 配置页的输入/验证/保存形态 → 演变成音源管理页。

真正要新建的是：`MusicSource` 接口、`Track` 的 `sourceId` 泛化、`MusicPlayer` 的取流分发 —— 那才是 2~4 周的部分，和这次的 1~2 天没有冲突。
