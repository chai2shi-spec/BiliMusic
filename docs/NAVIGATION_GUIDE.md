# Navigation 路由指南（新旧写法对照）

> 2026-10-22 Navigation 差距收敛产出。本项目已完成 router → Navigation 迁移：
> 全仓零 `router.*` / 零 `@ohos.router` 导入、仅 Index 一个 `@Entry`、
> 11 个子页全为 `HdsNavDestination`。本文档沉淀迁移前后的写法对照，
> 供后续新页面 / 新入口统一用法，避免回退到 router 时代写法。

## 1. 路由体系结构

| 层 | 载体 | 说明 |
|---|---|---|
| 栈实例 | `service/NavStackHolder.ets` | 静态单例 `NavPathStack`，phoneShell / tabletShell 两壳互斥挂载共享（折叠开合保返回栈） |
| 页面注册 | `service/LazyPageRegistry.ets` | 路由名 → 动态 import 映射（首帧后 1.5s 预热）；Index `pageMap` @Builder 渲染 `LazyDest` |
| 路由参数 | `service/NavRouteParams.ets` | 显式参数类（`UpSpaceRouteParam` / `PlaylistDetailRouteParam` / `LoginRouteParam`）+ `LOGIN_GATED_ROUTES` 拦截清单 |
| 拦截器 | `NavStackHolder.setupInterception()` | Index `aboutToAppear` 挂载一次：willShow 阶段登录拦截（清单当前为空）+ 同名 push 300ms 防抖 |
| 注入通道 | Index `@Provide('navPathStack')` | 子组件可 `@Consume('navPathStack')` 取同一栈实例（当前子页经静态单例访问，等价） |

`main_pages.json` 仅保留 `pages/Index` 一条 —— 它是 **UIAbility 入口页声明**，
不是路由表；所有子页面路由一律走 Navigation（`pushPathByName`），
不要往 `main_pages.json` 里加页面。

## 2. 新旧写法对照

### 2.1 跳转 + 传参

**旧（router + 静态字段，已废弃）：**

```typescript
// 生产端：写静态字段再跳，字段残留上一入口的旧值是常态 bug
NavStackHolder.upMid = mid;
NavStackHolder.upName = name;
NavStackHolder.upFace = face;
NavStackHolder.stack.pushPath({ name: 'UpSpace' });

// 消费端：直接读静态字段
const mid = NavStackHolder.upMid;
```

**新（pushPathByName + 显式参数类）：**

```typescript
// 生产端：参数随路由入栈，栈上可追溯（getParamByName）
NavStackHolder.stack.pushPathByName('UpSpace', new UpSpaceRouteParam(mid, name, face));

// 消费端（aboutToAppear）：经 NavRouteParamReader 拿已判型参数（或 null）
const routeParam: UpSpaceRouteParam | null =
  NavRouteParamReader.readUpSpaceParam(NavStackHolder.stack);
const mid: string = routeParam !== null ? routeParam.upMid : '';
```

要点：
- 参数类必须是**显式 class + constructor**（`service/NavRouteParams.ets`），
  不要用对象字面量 / 接口 + 结构推断（ArkTS 禁止）；
- `getParamByName` 返回值不透明（SDK 声明为 unknown 族，ArkTS 禁用），
  判型收窄统一收在 `NavRouteParamReader`（ESObject + `Array.isArray` +
  `instanceof`，与消费 `JSON.parse` 同一套口径），**消费页面不要自己碰
  原始返回值**；新路由在 Reader 里加一个 `readXxxParam`；
- 无参跳转写 `pushPathByName(name, undefined)`；
- 同名 push 300ms 防抖由拦截器统一处理，调用点不用自己加。

### 2.2 返回 / 回调

| 旧 | 新 | 说明 |
|---|---|---|
| `router.back()` | `NavStackHolder.stack.pop()` / `NavStackHolder.pop()` | 出栈；`pop(result)` 可回传结果 |
| `router.back({ url: 'pages/X' })` | `stack.popToName('X')` / `NavStackHolder.popTo('X')` | 出栈到栈内最近指定路由 |
| 页面间事件通知（登录态刷新等） | `pushPathByName(name, param, onPop)` | 推出页 pop 回来时回调，双保险于全局广播 |

**onPop 示例**（SettingsPage.pushLoginWithRefresh）：

```typescript
NavStackHolder.stack.pushPathByName('Login', new LoginRouteParam(),
  (info: PopInfo): void => {
    this.refreshLoginUi();  // 幂等：只重读状态，可安全重复调用
  });
```

注意：`onPop` 重载要求 `param` 为 `Object`（不能 undefined），无业务参数时
传 `new LoginRouteParam()` 占位。

### 2.3 拦截（登录收口预留）

**旧（router 时代无从拦截）**：各调用点散落 `if (!isLoggedIn()) { ... }`。

**新**：`NavStackHolder.setupInterception()` 在 willShow 阶段逐跳检查：
目标路由名 ∈ `LOGIN_GATED_ROUTES` 且未登录 → 改推 `Login`。
当前清单为空（校验仍在调用点），要把校验收口到路由层时，往
`NavRouteParams.ets` 的 `LOGIN_GATED_ROUTES` 加路由名即可，无需改拦截器。

### 2.4 页面生命周期

| router 页 | NavDestination 页 | 本项目现状 |
|---|---|---|
| `aboutToAppear` | `aboutToAppear` / `onWillAppear` | 保留 `aboutToAppear`（语义够用，子页无「转场前」诉求） |
| `onPageShow` / `onPageHide` | `onShown` / `onHidden`（NavDestination 事件） | 常驻 Tab 页不需要；需要感知露出/隐藏的新页面用 `onShown`/`onHidden`，**不要再写 `onPageShow`**（router 时代残留，无系统调用方，已删） |
| `onBackPress`（页面级） | `NavDestination` 内自行处理手势 / `onBackPressed` | 子页返回手势由 Navigation 统一承担 |

### 2.5 栈操作速查（NavStackHolder 封装）

| 封装 | 等价原生 | 用途 |
|---|---|---|
| `NavStackHolder.push(name, param)` | `stack.pushPathByName` | 压栈（带参） |
| `NavStackHolder.pop(result?)` | `stack.pop` | 出栈（可回传结果） |
| `NavStackHolder.popTo(name)` | `stack.popToName` | 出栈到指定路由 |
| `NavStackHolder.replace(name, param)` | `stack.replacePathByName` | 替换栈顶 |
| `NavStackHolder.clearAll()` | `stack.clear` | 清空回首页 |

直接用 `NavStackHolder.stack.xxx()` 原生 API 亦可（现有代码两种并存，
拦截器对两者都生效）。

## 3. 约定

1. **路由名清单**（`LazyPageRegistry`）：`Player` / `PlaylistDetail` / `Recent` /
   `Follows` / `UpSpace` / `WatchHistory` / `CloudSync` / `PlaylistImport` /
   `About` / `Login`。新增页面：注册表加 case + `PRELOAD_ORDER` 排序 +
   页面文件导出 `XxxWrapped`。
2. **参数类**新增路由入参时，在 `NavRouteParams.ets` 建类，不要复用
   旧静态字段模式（已全部删除）。
3. **判型**：`instanceof` 失败（参数缺失 / 类型不符）按空值兜底渲染，
   不要崩溃 —— 生产端漏传参数属于缺陷但不该让用户买单。
4. **登录**：新入口的登录校验仍由调用点显式做（`promptLogin` /
   `checkLoginAndLoad` 模式）；收口到路由层是后续可选项（见 2.3）。
