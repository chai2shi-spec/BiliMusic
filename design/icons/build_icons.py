# -*- coding: utf-8 -*-
"""
首页四分类图标：4 套风格 × 4 个图标，统一 24 网格。

设计约定
--------
· 画布 24×24，内容安全区 2..22（留 2 边距，保证 16vp 下不贴边）
· 四套风格的**骨架完全一致**，只换构造方式，所以四套可以互换而不改变语义
· 全部使用 currentColor：ArkUI 侧 `.renderMode(ImageRenderMode.Template).fillColor(x)` 染色
· 四类形态刻意拉开剪影差异 —— 星芒(尖) / 叠卡(方) / 黑胶(圆) / 奖杯(杯)
  目的是 16vp 缩到 16px 时仍能靠轮廓区分

输出
----
icons/<style>/<key>.svg        16 个独立文件
首页分类图标-多风格-原型.html    对照页（含 16/24/44 三档 + 真实 chip 实拍）
"""

import io
import os

OUT = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- 路径数据

# 推荐：四角星芒。
# ⚠️ 必须是折线，不能是贝塞尔：把控制点放在凹点会得到"花瓣"而非星（曲率包不住）。
# 四个尖在 N/E/S/W，四个凹点压在 45° 方向、距心 0.242r。
VALLEY = 0.242


def _spark_at(cx, cy, r, nd=2):
    """以 (cx,cy) 为中心、尖到心 r 的四角星芒，nd 控制小数位"""
    v = round(r * VALLEY, nd)
    f = lambda n: round(n, nd)
    pts = [
        (cx, cy - r),            # 上尖
        (cx + v, cy - v),        # 右上凹点
        (cx + r, cy),            # 右尖
        (cx + v, cy + v),
        (cx, cy + r),
        (cx - v, cy + v),
        (cx - r, cy),
        (cx - v, cy - v),
    ]
    d = "M%s %s" % (f(pts[0][0]), f(pts[0][1]))
    d += "".join("L%s %s" % (f(x), f(y)) for x, y in pts[1:])
    return d + "Z"

SPARK = _spark_at(12, 12, 9.1)
SPARK_S = _spark_at(18.9, 5.1, 2.6)

# 热门歌单：两张叠放的圆角卡片
CARD_FRONT = dict(x=3.0, y=8.0, w=13.0, h=13.0, rx=3.5)
# 背面卡片只画"露出来的 L 形"，避免两矩形叠在一起变成一坨
L_BACK_LINE = "M9.6 3.6H16.9A3.5 3.5 0 0 1 20.4 7.1V14.4"
L_BACK_FILL = ("M10.2 2.8H16.6C19.03 2.8 21 4.77 21 7.2V13.4"
               "C21 14.28 20.28 15 19.4 15H18.8C17.92 15 17.2 14.28 17.2 13.4"
               "V8.4C17.2 7.29 16.29 6.4 15.2 6.4H10.2C9.32 6.4 8.6 5.68 8.6 4.8"
               "V4.4C8.6 3.52 9.32 2.8 10.2 2.8Z")

# 音乐中心：黑胶唱片
def circ(r):
    return f"M12 {12-r}A{r} {r} 0 1 0 12 {12+r}A{r} {r} 0 1 0 12 {12-r}Z"

# 排行榜：奖杯（去掉了把手 —— 用户要"简洁"，16vp 下把手必糊）
CUP = ("M7.4 3.8H16.6V9.0C16.6 11.54 14.54 13.6 12 13.6"
       "C9.46 13.6 7.4 11.54 7.4 9.0V3.8Z")
CUP_LINE = CUP
STEM_LINE = "M12 13.6V16.9"
BASE_LINE = "M8.7 18.3H15.3"
BASE_FILL = dict(x=7.4, y=16.9, w=9.2, h=3.0, rx=1.5)
# 把手：没有它这个形状会被读成"高脚杯"而不是奖杯。
# ⚠️ solid/duotone 用**填充弧带**而不是 stroke：真机实测 Template + fillColor
# 染色对 stroke 不生效（排行榜选中态把手不跟主题色，其余 fill 部分正常）。
# 弧带由内外弧半径差保证线宽（R-r=1.7，与 stroke 版等宽）：
# 圆心 (8.587, 8.2)，外弧 R=3.35 / 内弧 r=1.65，右把手 = 左把手 x 镜像。
# line 版整套都是 stroke、整图一致染不上色的问题另行评估，此处不动。
HANDLE_L = "M7.4 6.0a2.5 2.5 0 0 0 0 4.4"
HANDLE_R = "M16.6 6.0a2.5 2.5 0 0 1 0 4.4"
HANDLE_L_FILL = ("M6.996 5.252A3.35 3.35 0 0 0 6.996 11.148"
                 "L7.804 9.652A1.65 1.65 0 0 1 7.804 6.748Z")
HANDLE_R_FILL = ("M17.004 5.252A3.35 3.35 0 0 1 17.004 11.148"
                 "L16.196 9.652A1.65 1.65 0 0 0 16.196 6.748Z")


def rect(**kw):
    return (f'<rect x="{kw["x"]}" y="{kw["y"]}" width="{kw["w"]}" '
            f'height="{kw["h"]}" rx="{kw["rx"]}"')


# ---------------------------------------------------------------- 四套风格

def style_solid(key, color="currentColor"):
    """B · 面性：全填充，靠负形留细节。16vp 下最清楚

    ⚠️ 这套是"母版"：容器式直接复用它，只换颜色与缩放。
    所有坐标都以 (12,12) 为基准，容器式才能安全地绕中心缩放。
    """
    c = color
    if key == "recommend":
        return f'<path d="{SPARK}" fill="{c}"/>'
    if key == "playlist":
        return (f'<path d="{L_BACK_FILL}" fill="{c}"/>'
                f'{rect(x=3.0, y=8.0, w=13.0, h=13.0, rx=3.5)} fill="{c}"/>')
    if key == "center":
        return (f'<path fill-rule="evenodd" fill="{c}" d="{circ(9.1)}{circ(2.5)}"/>'
                f'<path fill-rule="evenodd" fill="{c}" d="{circ(5.9)}{circ(5.3)}"/>')
    if key == "ranking":
        h = f'<path d="{HANDLE_L_FILL}" fill="{c}"/>' \
            f'<path d="{HANDLE_R_FILL}" fill="{c}"/>'
        return (h + f'<path d="{CUP}" fill="{c}"/>'
                f'<rect x="11.0" y="13.6" width="2.0" height="3.3" fill="{c}"/>'
                f'{rect(**BASE_FILL)} fill="{c}"/>')


def style_line(key):
    """A · 线性：1.8 描边，全圆头圆角，开口干净"""
    s = 'fill="none" stroke="currentColor" stroke-width="1.8" ' \
        'stroke-linecap="round" stroke-linejoin="round"'
    if key == "recommend":
        return f'<path d="{SPARK}" {s}/>'
    if key == "playlist":
        return (f'<path d="{L_BACK_LINE}" {s}/>'
                f'<rect x="3.0" y="8.0" width="13.0" height="13.0" rx="3.5" {s}/>')
    if key == "center":
        return (f'<circle cx="12" cy="12" r="9.1" {s}/>'
                f'<circle cx="12" cy="12" r="4.9" {s}/>'
                f'<circle cx="12" cy="12" r="1.25" fill="currentColor"/>')
    if key == "ranking":
        return (f'<path d="{HANDLE_L}" {s}/><path d="{HANDLE_R}" {s}/>'
                f'<path d="{CUP_LINE}" {s}/>'
                f'<path d="{STEM_LINE}" {s}/>'
                f'<path d="{BASE_LINE}" fill="none" stroke="currentColor" '
                f'stroke-width="2.7" stroke-linecap="round"/>')


def style_duotone(key):
    """C · 双色：主形 100% + 次要素 42%，给 24~48vp 的场景说明用"""
    if key == "recommend":
        return (f'<path d="{SPARK_S}" fill="currentColor" opacity=".42"/>'
                f'<path d="{SPARK}" fill="currentColor"/>')
    if key == "playlist":
        return (f'<path d="{L_BACK_FILL}" fill="currentColor" opacity=".42"/>'
                f'{rect(x=3.0, y=8.0, w=13.0, h=13.0, rx=3.5)} fill="currentColor"/>')
    if key == "center":
        return (f'<path fill-rule="evenodd" fill="currentColor" '
                f'd="{circ(9.1)}{circ(7.6)}"/>'
                f'<circle cx="12" cy="12" r="5.1" fill="currentColor" opacity=".42"/>'
                f'<circle cx="12" cy="12" r="1.3" fill="currentColor"/>')
    if key == "ranking":
        return (f'<path d="{HANDLE_L_FILL}" fill="currentColor"/>'
                f'<path d="{HANDLE_R_FILL}" fill="currentColor"/>'
                f'<path d="{CUP}" fill="currentColor"/>'
                f'<rect x="11.0" y="13.6" width="2.0" height="3.3" '
                f'fill="currentColor" opacity=".42"/>'
                f'<rect x="7.4" y="16.9" width="9.2" height="3.0" rx="1.5" '
                f'fill="currentColor" opacity=".42"/>')


def style_contained(key):
    """D · 容器式：13% 淡色圆角方底 + 实心图形，绕 (12,12) 缩到 68%

    ⚠️ 这里刻意**不用**「实色底 + 白色负形」：`fillColor()` 会把白色一并染掉，
    负形直接消失；而 `ImageRenderMode.Template` 走 alpha 通道，实底与白形 alpha 都是 1，
    镂空同样保不住。改成同色系（底 12% / 形 100%）后，两种着色方式都成立，
    换 8 套主题色也不用重出图。
    """
    return ('<rect x="2" y="2" width="20" height="20" rx="6.4" '
            'fill="currentColor" opacity=".12"/>'
            '<g transform="translate(12,12) scale(.68) translate(-12,-12)">'
            + style_solid(key) + '</g>')


STYLES = [
    ("line", "A · 线性 Line", "1.8 描边 / 全圆头", style_line),
    ("solid", "B · 面性 Solid", "全填充 / 负形留细节", style_solid),
    ("duotone", "C · 双色 Duotone", "主形 100% + 次要 42%", style_duotone),
    ("contained", "D · 容器式 Contained", "12% 淡底 + 实心图形", style_contained),
]

KEYS = [
    ("recommend", "推荐", "星芒"),
    ("playlist", "热门歌单", "叠卡"),
    ("center", "音乐中心", "黑胶"),
    ("ranking", "排行榜", "奖杯"),
]

# ---------------------------------------------------------------- 输出 SVG

for sid, _, _, fn in STYLES:
    d = os.path.join(OUT, sid)
    os.makedirs(d, exist_ok=True)
    for key, _, _ in KEYS:
        body = fn(key)
        svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" '
               'viewBox="0 0 24 24">%s</svg>' % body)
        with io.open(os.path.join(d, key + ".svg"), "w", encoding="utf-8") as f:
            f.write(svg)

# ---------------------------------------------------------------- 对照页

def svg_inline(key, fn, size, color="currentColor", extra=""):
    body = fn(key)
    return (f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" '
            f'style="color:{color};display:block;{extra}">{body}</svg>')


CSS = """
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0B0B0F;color:#E8E8EE;
  font-family:"HarmonyOS Sans SC","PingFang SC","Microsoft YaHei",sans-serif;
  padding:44px 40px 56px}
.head{max-width:1010px;margin:0 auto 30px}
.head h1{font-size:19px;font-weight:650;letter-spacing:.4px}
.head h1 em{font-style:normal;color:#FB7299}
.head p{margin-top:9px;font-size:12px;line-height:1.85;color:#8A8A96;max-width:820px}
.head p b{color:#C9C9D4;font-weight:600}
.wrap{max-width:1010px;margin:0 auto;
  background:#121216;border:1px solid #23232B;border-radius:14px;overflow:hidden}
body.light{background:#F4F4F6}
body.light .wrap{background:#FFFFFF;border-color:#E4E4E9}
body.light .head h1{color:#1A1A1F}
body.light .head p{color:#6B6B76}
body.light .head p b{color:#3A3A44}

.srow{display:grid;grid-template-columns:150px 300px 132px 118px;align-items:center;
  justify-content:space-between;gap:16px;padding:20px 22px;border-bottom:1px solid #1E1E25}
body.light .srow{border-bottom-color:#EFEFF3}
.srow:last-child{border-bottom:none}
.sname b{display:block;font-size:13px;font-weight:600;letter-spacing:.2px}
.sname span{display:block;margin-top:5px;font-size:10.5px;color:#75757F;line-height:1.5}
.tiles{display:flex;gap:22px}
.tile{display:flex;flex-direction:column;align-items:center;gap:9px;width:58px}
.tile .lb{font-size:10px;color:#7C7C88;letter-spacing:.3px}
.zoom{display:flex;flex-direction:column;gap:14px}
.zrow{display:flex;align-items:flex-end;gap:12px}
.zbox{display:flex;flex-direction:column;align-items:center}
.zoom i{font-style:normal;font-size:8.5px;color:#5E5E6A;display:block;
  text-align:center;margin-top:6px}

/* 真实 chip 实拍：36 高 / radius 18 / 图标 16 / 文字 12 */
.chips{display:flex;flex-direction:column;gap:9px;align-items:flex-start}
.chip{height:36px;border-radius:18px;padding:0 16px;display:inline-flex;
  align-items:center;gap:6px;font-size:12px;line-height:16px;width:max-content;
  border:.5px solid #2C2C36;background:#1E1E24;color:#ABABB5}
.chip svg{width:16px;height:16px}
.chip.on{background:#FB7299;border-color:#FB7299;color:#fff;font-weight:500}
body.light .chip{background:#F5F5F8;border-color:#E3E3E9;color:#5E5E68}
body.light .chip.on{background:#FB7299;border-color:#FB7299;color:#fff}

.foot{max-width:1010px;margin:26px auto 0;display:grid;
  grid-template-columns:repeat(3,1fr);gap:16px}
.card{background:#121216;border:1px solid #23232B;border-radius:11px;padding:15px 16px}
.card > b{display:block;font-size:11.5px;color:#D6D6E0;margin-bottom:7px;font-weight:600}
.card p{font-size:10.5px;line-height:1.75;color:#7E7E8A;text-align:left}
.card p b{color:#FB7299;font-weight:600}
.card code{font-family:Consolas,monospace;font-size:10px;color:#FB7299;
  background:#1E1E24;padding:1px 4px;border-radius:3px}
.hint{max-width:1010px;margin:22px auto 0;font-size:11px;color:#6A6A76;line-height:1.9}
.hint b{color:#9A9AA6}
"""

rows = []
for sid, name, note, fn in STYLES:
    tiles = "".join(
        f'<div class="tile">{svg_inline(k, fn, 44)}<span class="lb">{lb}</span></div>'
        for k, lb, _ in KEYS)
    z4 = "".join(f'<div class="zbox">{svg_inline(k, fn, 24)}<i>24</i></div>'
                 for k, _, _ in KEYS)
    z6 = "".join(f'<div class="zbox">{svg_inline(k, fn, 16)}<i>16</i></div>'
                 for k, _, _ in KEYS)
    chip = ('<div class="chips">'
            + '<div class="chip on">' + svg_inline("recommend", fn, 16, "#fff") + '推荐</div>'
            + '<div class="chip">' + svg_inline("playlist", fn, 16) + '热门歌单</div>'
            + '</div>')
    rows.append(f'<div class="srow"><div class="sname"><b>{name}</b><span>{note}</span></div>'
                f'<div class="tiles">{tiles}</div>'
                f'<div class="zoom"><div class="zrow">{z4}</div>'
                f'<div class="zrow">{z6}</div></div>'
                f'{chip}</div>')

html = f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>首页四分类图标 · 四套风格</title>
<style>{CSS}</style></head><body>
<div class="head">
  <h1>首页四分类图标 · <em>四套风格</em></h1>
  <p>对象是首页 chip 条上的四个分类（<b>推荐 / 热门歌单 / 音乐中心 / 排行榜</b>）。
  四套共用同一个 24 网格与同一套骨架，只换构造方式。右侧是真实 chip 实拍
  （36 高 / radius 18 / 图标 16 / 文字 12），也就是这些图标真正要活的那个尺寸 ——
  如果 16 那一列看不清，这套就不要用了。</p>
</div>
<div class="wrap">{''.join(rows)}</div>
<div class="foot">
  <div class="card"><b>A 线性 / B 面性</b><p>两者是同一套的两种字重，可混用：
  未选中 A、选中 B 自动加粗，不用换文件。<code>1.8</code> 描边按 24 网格算，
  缩到 16 正好 1.2px。</p></div>
  <div class="card"><b>C 双色</b><p>主形实心 + 次要 42%。适合空状态、分类大卡、
  设置页这种 24~48 的尺寸；<b>不建议</b>放进 16 的 chip，
  第二层会糊成一层灰。</p></div>
  <div class="card"><b>D 容器式</b><p>12% 淡色方底 + 实心图形，同色系所以
  <b>可以</b>跟着主题色走。适合分类入口卡 / 分享卡；
  塞进 36 高的 chip 会让它比旁边三枚线稿重一档，不建议混用。</p></div>
</div>
<div class="hint">
  <b>剪影验算：</b>把这一页缩到 25% 再看 —— 尖(星) / 方(卡) / 圆(黑胶) / 杯(奖杯) 四个轮廓
  必须还能分开。分不开就说明形态没拉开，不是尺寸问题。<br>
  <b>染色：</b>全部走 <code>currentColor</code>，ArkUI 用
  <code>ImageRenderMode.Template + fillColor()</code> 即可跟随 8 套主题色，不需为每色出图。<br>
  <b>网格：</b>内容安全区 2..22，最外 2 留白保证 16vp 下不贴边。
</div>
</body></html>"""

with io.open(os.path.join(OUT, "首页分类图标-多风格-原型.html"), "w", encoding="utf-8") as f:
    f.write(html)

print("svg:", 4 * 4, " html: ok")
