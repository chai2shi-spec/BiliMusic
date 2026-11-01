# 首页四分类 · AI 绘图提示词（夜馆玻璃）

> 对象：首页 chip 条上的四个分类 —— **推荐 / 热门歌单 / 音乐中心 / 排行榜**
> （`components/HomeCategoryChips.ets` → `HOME_CATEGORY_CHIPS`，顺序即本文字序）

---

## 一、先定用途，否则比例无从谈起

chip 本体只有 36 vp 高、图标 16 vp，这个尺寸**不适合 AI 位图**（16×16 里塞不进任何信息，
缩放后全是糊的）。四个分类真正需要 AI 插画的位置是下面三档：

| 落点 | 尺寸 | 比例 | 说明 |
|---|---|---|---|
| 空状态 / 加载失败插图 | 建议 160 vp 显示 | 1:1 | 主用途，一屏只有一个，允许有细节 |
| 分类入口大卡（设置页 / 分享卡） | 200–260 vp | 1:1 | 批量四张并排，要求**一眼可区分** |
| 分享图 / 年度报告头图 | 1080 宽 | 3:4（竖） | 同图上下留白后裁切即可 |

**统一按 1:1 / 1024 生图**，竖版从同一张图裁（构图已经预留上下留白，见 §8）。

---

## 二、风格系统：为什么必须「中性色」

这是整套提示词里最容易做错的一步。工程里主题色是**运行时可选 8 套**
（`THEME_PALETTES`：粉 / 红 / 橙 / 黄 / 绿 / 青 / 蓝 / 紫），深色底是 `#121216`。

如果四张图直接画成品牌粉，用户切成蓝色主题时就会撞色 —— 一套图只能服务 1/8 的用户。
所以：

> **生图只出「银白 / 乳白 / 石墨 + 一道中性暖光」，不带任何饱和色相。**
> 主题色交给代码叠（`.blendMode(BlendMode.Plus)` 叠一层 low-opacity 主色，或直接
> `colorBlend`），一套图吃满 8 套主题色。

如果你确实要「直接可用、不叠色」的成品，见 §7 的 `ACCENT` 替换句，把中性暖光换成
`#FB7299` 即可 —— 但那就锁死在粉色主题了。

配套的材质与光位也必须锁死，否则四张图会散成四种风格：

| 维度 | 锁定值 |
|---|---|
| 材质 | 磨砂乳白玻璃 / 半透明亚克力 / 拉丝银 / 哑光黑胶。**全部哑光**，禁止亮面塑料 |
| 光位 | 只有两盏：左上冷调主光 + 右侧一道极细暖调轮廓光。不加第三盏 |
| 背景 | 纯黑无缝，**无地平线、无地面**，四边落入全黑 |
| 构图 | 正中对称，主体占画幅 ~55%，四周留大片空 |
| 镜头 | 85mm 微距，浅景深，微弱体积雾 |
| 调性 | 中间调低对比、去饱和、颗粒细。**不要「AI 感」的高饱和辉光** |

风格名：**夜馆玻璃（Night Vitrine）**——一件小雕塑，躺在全黑的展柜里，被两盏灯挑出来。

---

## 三、风格锚（Style Anchor）

下面这段**四张图逐字复用**，不做任何改动。四个提示词的差异只在主体句。

```
Photorealistic 3D still-life render of a single miniature sculpture, photographed in a
pitch-black studio. Materials: frosted opal glass, translucent acrylic, brushed silver,
matte black vinyl - every surface matte, never glossy plastic. Lighting: one soft cool
key light from the upper left, plus a thin warm rim light grazing the silhouette from the
right, and nothing else. Seamless pure-black background, no horizon line, no visible
floor, falling off into complete darkness at the frame edges. Centered symmetrical hero
composition, the sculpture fills about 55% of the frame with wide empty margins, 85mm
macro lens, shallow depth of field, faint volumetric haze, fine film grain, muted
low-contrast midtones, cinematic and restrained.
```

共用收尾句（四张图都接在主体句后面）：

```
No text, no letters, no numbers, no logo, no watermark, no human figure, no hands, no
clutter, no saturated colour, no rainbow, no neon sign, no lens flare.
```

---

## 四、四段完整提示词（英文 · 直接复制）

### 1 · 推荐 Recommend

> 语义：**替你做选择的那个瞬间**。星图仪 = 从海量里挑出几个，卡片被吹开 = 摊到你面前。

```
Photorealistic 3D still-life render of a single miniature sculpture, photographed in a
pitch-black studio. Materials: frosted opal glass, translucent acrylic, brushed silver,
matte black vinyl - every surface matte, never glossy plastic. Lighting: one soft cool
key light from the upper left, plus a thin warm rim light grazing the silhouette from the
right, and nothing else. Seamless pure-black background, no horizon line, no visible
floor, falling off into complete darkness at the frame edges. Centered symmetrical hero
composition, the sculpture fills about 55% of the frame with wide empty margins, 85mm
macro lens, shallow depth of field, faint volumetric haze, fine film grain, muted
low-contrast midtones, cinematic and restrained.

The object: a hand-sized armillary sphere. Three thin brushed-silver rings, tilted twenty
degrees off axis, orbit a small frosted-glass ball whose surface is etched with faint
concentric vinyl grooves. Two blank translucent cards drift away from the sphere on the
right, tilted like cards being fanned, their edges catching the warm rim light. The rings
and the ball are perfectly concentric.

No text, no letters, no numbers, no logo, no watermark, no human figure, no hands, no
clutter, no saturated colour, no rainbow, no neon sign, no lens flare.
```

### 2 · 热门歌单 Hot Playlists

> 语义：**一叠被摊开的手牌**。扇形 = 多张，层叠 = 数量感，缝隙漏光 = 「热」。

```
Photorealistic 3D still-life render of a single miniature sculpture, photographed in a
pitch-black studio. Materials: frosted opal glass, translucent acrylic, brushed silver,
matte black vinyl - every surface matte, never glossy plastic. Lighting: one soft cool
key light from the upper left, plus a thin warm rim light grazing the silhouette from the
right, and nothing else. Seamless pure-black background, no horizon line, no visible
floor, falling off into complete darkness at the frame edges. Centered symmetrical hero
composition, the sculpture fills about 55% of the frame with wide empty margins, 85mm
macro lens, shallow depth of field, faint volumetric haze, fine film grain, muted
low-contrast midtones, cinematic and restrained.

The object: five square record sleeves standing on edge in a fan, like a hand of cards
held out to the viewer. Each sleeve is stepped a few degrees back and to the right, the
front one bright frosted white, the ones behind progressively darker until the last is
almost black. Thin warm light leaks through the narrow gaps between the sleeves. The
sleeves are completely blank, no artwork, no printing.

No text, no letters, no numbers, no logo, no watermark, no human figure, no hands, no
clutter, no saturated colour, no rainbow, no neon sign, no lens flare.
```

### 3 · 音乐中心 Music Center

> 语义：**一座场馆的剖面**。穹顶 = 建筑，光柱 + 同心环 = 声音在里面。

```
Photorealistic 3D still-life render of a single miniature sculpture, photographed in a
pitch-black studio. Materials: frosted opal glass, translucent acrylic, brushed silver,
matte black vinyl - every surface matte, never glossy plastic. Lighting: one soft cool
key light from the upper left, plus a thin warm rim light grazing the silhouette from the
right, and nothing else. Seamless pure-black background, no horizon line, no visible
floor, falling off into complete darkness at the frame edges. Centered symmetrical hero
composition, the sculpture fills about 55% of the frame with wide empty margins, 85mm
macro lens, shallow depth of field, faint volumetric haze, fine film grain, muted
low-contrast midtones, cinematic and restrained.

The object: a cutaway half-dome of frosted glass, the cross-section of a small concert
hall, sliced open toward the camera. Inside, four hair-thin vertical beams of light rise
from the invisible floor, and three concentric glowing rings hover at mid-height like
sound waves frozen in place. The dome shell is thin, its edges luminous.

No text, no letters, no numbers, no logo, no watermark, no human figure, no hands, no
clutter, no saturated colour, no rainbow, no neon sign, no lens flare.
```

### 4 · 排行榜 Ranking

> 语义：**三级台阶**。剪影最有辨识度（阶梯），也最容易和另外三张区分。

```
Photorealistic 3D still-life render of a single miniature sculpture, photographed in a
pitch-black studio. Materials: frosted opal glass, translucent acrylic, brushed silver,
matte black vinyl - every surface matte, never glossy plastic. Lighting: one soft cool
key light from the upper left, plus a thin warm rim light grazing the silhouette from the
right, and nothing else. Seamless pure-black background, no horizon line, no visible
floor, falling off into complete darkness at the frame edges. Centered symmetrical hero
composition, the sculpture fills about 55% of the frame with wide empty margins, 85mm
macro lens, shallow depth of field, faint volumetric haze, fine film grain, muted
low-contrast midtones, cinematic and restrained.

The object: a three-step podium carved from one solid block of frosted glass, the tallest
step in the centre. One upright matte-black vinyl record stands on edge on the top step,
two on the middle step, one on the low step. A warm glow rises through the glass from
below, brightest at the base, dissolving into the black floor.

No text, no letters, no numbers, no logo, no watermark, no human figure, no hands, no
clutter, no saturated colour, no rainbow, no neon sign, no lens flare.
```

---

## 五、中文版（即梦 / 可画 / 文心 / 通义万相）

同样三段式：**风格锚 + 主体 + 收尾**。

**风格锚（四张共用）**

```
写实级 3D 静物渲染，一件小型雕塑，置于全黑影棚中拍摄。材质为磨砂乳白玻璃、半透明亚克力、
拉丝银与哑光黑胶，所有表面均为哑光，没有任何亮面塑料感。只有两盏灯：左上冷调柔光主光，
右侧一道极细的暖调轮廓光，此外别无其他光源。纯黑无缝背景，没有地平线，看不到地面，
画面四边完全落入黑暗。正中对称的英雄构图，雕塑约占画幅 55%，四周留大片留白。
85mm 微距镜头，浅景深，极淡的体积雾，细腻胶片颗粒，中间调低对比，去饱和，电影感，克制。
```

**主体句**

| 分类 | 主体描述 |
|---|---|
| 推荐 | 一只手掌大小的浑天仪：三道极细的拉丝银环，偏离中轴二十度，环绕一颗磨砂玻璃小球，球面刻有淡淡的黑胶同心纹路。两张空白的半透明卡片从右侧飘离球体，像被慢慢摊开的纸牌，卡片边缘被暖调轮廓光勾亮。环与球严格同心 |
| 热门歌单 | 五张方形唱片封套竖立成扇形，像摊到观者面前的一手牌。每张相对前一张后退并偏转几度，最前一张是明亮的磨砂白，越往后越暗，最后一张接近全黑。暖光从封套之间的窄缝里透出来。封套表面完全空白，没有图案没有印刷 |
| 音乐中心 | 一个磨砂玻璃的半圆穹顶剖面，像被剖开一座小型音乐厅正对镜头。内部有四道发丝粗细的竖向光柱从看不见的地面升起，三道同心光环悬在中段，像被冻结的声波。穹壳很薄，边缘发光 |
| 排行榜 | 一座由整块磨砂玻璃雕出的三级台阶，最高一级在正中。最高一级上立着一张哑光黑胶唱片，中间一级两张，最低一级一张。暖光从下方穿过玻璃向上升起，越靠底部越亮，最终融进黑色地面 |

**收尾句（共用）**

```
画面中不出现任何文字、字母、数字、标志、水印、人物、手部、杂散物件；不使用高饱和色彩、
彩虹色、霓虹灯牌、镜头光晕。
```

---

## 六、负向提示词

Midjourney 直接跟在结尾；SD / ComfyUI 放进 negative prompt 框：

```
text, letters, typography, watermark, logo, signature, human, hand, face, crowd,
saturated colors, rainbow, neon, holographic, glossy plastic, chrome sphere, lens flare,
bokeh balls, cluttered composition, busy background, visible floor, horizon line,
drop shadow, cartoon, anime, low-poly, flat vector, 3d emoji style, plastic toy,
HDR, oversharpened, jpeg artifacts
```

其中三个最容易翻车的，单独强调：

- `glossy plastic` / `chrome sphere` —— 模型一看到「球体 + 灯光」就会给你一个亮面铬球，
  那是塑料玩具，不是磨砂玻璃
- `visible floor` / `drop shadow` —— 一旦有地面和投影，图就有了「边界」，嵌进深色页面时会
  出现一条横线
- `bokeh balls` / `lens flare` —— 这是最典型的「AI 味」来源

---

## 七、参数

| 平台 | 参数 |
|---|---|
| Midjourney v6 / v7 | `--ar 1:1 --style raw --s 180 --no text,letters,watermark` |
| SDXL / Flux | CFG 3.5–5（**不要 7+**，高 CFG 会拉出高饱和）· Steps 30–40 · 1024×1024 |
| 即梦 / 可画 | 风格选「3D 渲染」或「产品摄影」，关闭「增强」 |

**`--s 180` 是关键**：默认 100 太素会丢掉玻璃的通透感，200 以上开始往插画跑。

**要粉色成品版**时，把风格锚里的这一句替换掉，其余不动：

> 原文：`a thin warm rim light grazing the silhouette from the right`
> 换成：`a thin rim light in #FB7299 grazing the silhouette from the right`

---

## 八、一致性校验清单（生成后逐条过）

四张图并排缩小到 120 px 看，逐条打勾：

1. **剪影各不相同** —— 球 / 扇形 / 穹顶 / 阶梯。如果缩小后三张分不清，重生成，不要凑合
2. **黑位一致** —— 用吸管取四张图的角落，RGB 都应在 `0–8` 之间。偏了就是没锁死纯黑底
3. **光位一致** —— 亮部都在左上偏冷、轮廓都在右侧偏暖。四张里出现一张反的，那张作废
4. **主体占比 55%±5%** —— 目测主体最外接矩形的短边占画幅一半上下。占比差太多，并排时会一大一小
5. **无地面、无投影** —— 一旦出现台面，嵌进 `#121216` 页面会看到一条硬横线
6. **无任何字母** —— 模型很爱在玻璃上刻字。中文字更容易崩成乱码，必须逐张看

---

## 九、落地接法

### 深色模式（默认）

图按纯黑底生成 → 直接放在 `#121216` 上，黑对黑，接缝本身不可见，**不需要抠图也不需要
混合模式**。这是选纯黑底而不是透明底的原因：透明底的边缘常有半透明脏边，反而更难处理。

```ets
Image($r('app.media.ill_rec'))
  .width(160).height(160)
  .objectFit(ImageFit.Contain)
  .interpolation(ImageInterpolation.High)
```

### 浅色模式

同一套构图，把背景句整句替换，**不要另写一套提示词**（否则构图一定跑偏）：

> `Seamless pure-black background, no horizon line...`
> → `Seamless warm ivory paper background (#F7F4EE), soft top-left daylight, one long
> soft shadow, no horizon line.`

深色版进 `resources/dark/media/`，浅色版进 `resources/base/media/`，同名即可自动切换。

### 跟随主题色

```ets
Stack() {
  Image($r('app.media.ill_ranking')).width(160).height(160)
  // 主题色叠层：只染亮部，暗部不动
  Column().width(160).height(160)
    .backgroundColor(this.themePrimary)
    .opacity(0.18)
    .blendMode(BlendMode.Plus)
}
```

`Plus` 比 `Screen` 更保守，不会把黑位提灰。**不要在图上用 `.colorBlend()`**——它会把
整张图包括黑位一起染色，黑底变彩底，嵌进页面立刻露馅。

### 尺寸

导出 1024×1024 PNG，代码里**只用一个尺寸档**（160 / 200 / 260 都从同一张缩放）。
不要为每档单独生图 —— 四张图之间的一致性已经够难保持了，别再加变量。

---

## 十、如果你只想要一句能跑的

最短可用版（去掉所有修饰，仍能保持四张基本同风格）：

```
frosted glass miniature sculpture of {主体}, single object, pitch-black seamless studio
background, one cool key light upper-left, thin warm rim light on the right edge, matte
materials only, centered, 85mm macro, shallow depth of field, muted desaturated, fine
grain, no text --ar 1:1 --style raw
```

`{主体}` 填 §4 里各自 `The object:` 后面的那句即可。
