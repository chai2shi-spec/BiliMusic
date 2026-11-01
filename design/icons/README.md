# 首页四分类图标 · 四套风格

对象是 `components/HomeCategoryChips.ets` 里 `HOME_CATEGORY_CHIPS` 的四个分类：
**推荐 / 热门歌单 / 音乐中心 / 排行榜**。

16 个 SVG，4 套风格 × 4 个图标，全部手写、统一 24 网格。

```
icons/
├─ line/        A 线性    recommend.svg playlist.svg center.svg ranking.svg
├─ solid/       B 面性
├─ duotone/     C 双色
├─ contained/   D 容器式
├─ build_icons.py                 生成脚本（改路径数据后重跑即可）
├─ 首页分类图标-多风格-原型.html    对照页
└─ 首页分类图标-多风格-预览.png
```

---

## 一、先定语义：四个轮廓必须能分开

图标在 chip 里只有 **16 vp**，所以四个分类靠的是**剪影**而不是细节。
刻意选成四种完全不同的形状：

| key | 分类 | 主体 | 剪影 |
|---|---|---|---|
| `recommend` | 推荐 | 四角星芒 | 尖（4 个角） |
| `playlist` | 热门歌单 | 两张叠放的圆角卡 | 方（两个错位矩形） |
| `center` | 音乐中心 | 黑胶唱片 | 圆（同心环） |
| `ranking` | 排行榜 | 带把手的奖杯 | 杯（上宽下窄 + 托） |

尖 / 方 / 圆 / 杯 —— 这四个字形在任何尺寸下都不会互认。

> **为什么不用现在那四个 `sys.symbol`**：现状是 `play_fill`（推荐）、`music_note_list`、
> `waveform`、`list_bullet`（排行榜）。问题是 `play_fill` 表达的是"播放"不是"推荐"，
> 而 `list_bullet` 和 `music_note_list` 在 16 vp 下都是"一堆横线"，两个分类糊成一样。
> 这四枚是按语义重画的，不是换皮。

---

## 二、四套风格，各自的使用场景

| | 风格 | 构造 | 该用在哪 |
|---|---|---|---|
| **A** | 线性 Line | 1.8 描边 / 全圆头圆角 | **chip 未选中态**。和系统 `SymbolGlyph` 同气质，混排不突兀 |
| **B** | 面性 Solid | 全填充 / 负形留细节 | **chip 选中态**。同一套的加粗版，选中时换文件即可，不用换风格 |
| **C** | 双色 Duotone | 主形 100% + 次要 42% | 空状态、分类入口卡、设置页这类 **24~48** 的尺寸 |
| **D** | 容器式 Contained | 12% 淡底 + 实心图形 | 分类入口大卡、分享卡。**不建议**塞进 36 高的 chip |

A / B 是同一套的两种字重，可以成对使用；C / D 是另外两种密度，别混在同一行里。

---

## 三、规格

- 画布 **24 × 24**，内容安全区 **2..22**（最外 2 留白，保证 16 vp 下不贴边）
- 线性描边 **1.8**（按 24 网格算，缩到 16 正好 1.2 px）
- 圆角：卡片 3.5 / 方底 6.4 / 底座 1.5
- 全部单色，无渐变、无阴影、无内发光

---

## 四、ArkUI 接入

### 1. 放资源

把选定的风格复制进工程并改成合法资源名（小写 + 下划线）：

```
entry/src/main/resources/base/media/
  home_cat_recommend.svg
  home_cat_playlist.svg
  home_cat_center.svg
  home_cat_ranking.svg
```

四套都要就加风格后缀：`home_cat_recommend_line.svg` / `_solid.svg`。

### 2. 渲染

```ets
Image($r('app.media.home_cat_recommend'))
  .width(16)
  .height(16)
  .renderMode(ImageRenderMode.Template)          // 走 alpha 通道
  .fillColor(this.isSelected ? Color.White : $r('app.color.text_secondary'))
  .interpolation(ImageInterpolation.High)
```

**`renderMode(ImageRenderMode.Template)` 是必需的**，原因见下一节。

### 3. 接进 chip

把 `HOME_CATEGORY_CHIPS` 的 `icon: Resource` 换成两张图（未选中 / 选中），
或直接用同一张 + `fillColor` 切换颜色：

```ets
Row({ space: 6 }) {
  Image(item.icon)
    .width(16).height(16)
    .renderMode(ImageRenderMode.Template)
    .fillColor(this.isSelected(item) ? Color.White : $r('app.color.text_secondary'))
  Text(item.title) /* …原样保留… */
}
```

`Index` 侧导航栏那个 40×40 的圆按钮复用的是同一份图标，一处改动两处同步。

---

## 五、两个必须知道的约束

### 1. SVG 一旦当资源加载，`currentColor` 就失效

SVG 通过 `<img>` 或 `Image($r(...))` 加载时是**独立文档**，`currentColor` 不再继承页面
颜色，会退回黑色。所以：

- **不要**指望把 SVG 丢进去它自己就跟着主题色变
- 用 `.renderMode(ImageRenderMode.Template)`，它忽略图里的颜色、只看 alpha，
  再用 `.fillColor()` 上色；⚠️ 真机实测 Template + `fillColor` 对 `stroke`
  **同样不生效**（1.3.6 排行榜 solid 版把手选中态不跟主题色，其余 fill 部分
  正常）—— 需要染色的图一律用 `fill` 构造：solid / duotone 的奖杯把手已改为
  填充弧带（`HANDLE_*_FILL`，见 build_icons.py），A 线性整套是 stroke、不适用
  此染色通道
- 这个坑在浏览器预览里也会撞到：用 `<img src="x.svg">` 看容器式图标会变成黑底

### 2. 容器式为什么不是「实色块 + 白色负形」

第一版做的是实色圆角方块挖白色图形，看起来最像 App 图标，但**不可着色**：

- `fillColor()` 会把白色一并染掉 → 负形消失
- `Template` 模式走 alpha，实底和白形的 alpha 都是 1 → 镂空同样保不住

改成同色系（底 12% / 图形 100%）之后，两种着色方式都成立，换 8 套主题色也不用重出图。
代价是没那么"实"，但能真正落地。

---

## 六、改图 / 重出

所有路径数据集中在 `build_icons.py` 顶部，改完直接跑：

```bash
cd design/icons && python build_icons.py
```

会重新产出 16 个 SVG 和对照页。容器式是复用 `style_solid()` 的结果再绕中心缩放到 68%，
所以**改 B 套等于同时改 D 套**，两套不会漂移。

---

## 七、验收清单

1. 缩到 **25%** 看：尖 / 方 / 圆 / 杯 四个轮廓还能分开 → 形态成立
2. 放进真实 chip（36 高 / 图标 16）：文字还没念完就能认出图标 → 尺寸成立
3. 切到浅色模式：全部走 `currentColor` / `fillColor`，不应出现白块或黑块
4. 切主题色：8 套色下都不应有"只有一半变了色"的现象
5. 并排看四枚：笔画粗细一致、视觉重量一致（星芒偏轻是正常的，尖端天然显细）
