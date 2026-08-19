"""生成扁平化底部导航栏图标 48x48 白色 PNG（App 中通过 fillColor 染色）"""
from PIL import Image, ImageDraw
import os

import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DST = os.path.join(SCRIPT_DIR, "..", "entry", "src", "main", "resources", "base", "media")
os.makedirs(DST, exist_ok=True)
SZ = 48
WHITE = (255, 255, 255, 255)


def make_icon(name: str, draw_fn) -> None:
    img = Image.new("RGBA", (SZ, SZ), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    draw_fn(d)
    path = f"{DST}/tab_{name}.png"
    img.save(path, "PNG")
    print(f"OK: {path}")


# Projects — 房屋
def draw_home(d: ImageDraw.ImageDraw) -> None:
    w = 4  # 线宽
    m = 8  # 边距
    cx = SZ // 2
    # 屋顶
    d.polygon([(cx, m), (m, SZ // 2 - 2), (SZ - m, SZ // 2 - 2)], fill=None, outline=WHITE, width=w)
    # 屋身
    d.rectangle([m + 4, SZ // 2 - 2, SZ - m - 4, SZ - m], fill=None, outline=WHITE, width=w)
    # 门
    dw = 10
    d.rectangle([cx - dw // 2, SZ - m - 16, cx + dw // 2, SZ - m], fill=WHITE)


# Terminal — 命令提示符
def draw_terminal(d: ImageDraw.ImageDraw) -> None:
    w = 4
    m = 8
    # 外壳
    d.rounded_rectangle([m, m + 2, SZ - m, SZ - m], radius=6, fill=None, outline=WHITE, width=w)
    # 提示符 >
    px = m + 8
    py = SZ // 2 + 6
    s = 10
    d.line([(px, py), (px + s, py + s)], fill=WHITE, width=w)
    d.line([(px, py + s * 2), (px + s, py + s)], fill=WHITE, width=w)
    # 光标
    d.rectangle([px + s + 8, py + s - 1, px + s + 18, py + s + w - 1], fill=WHITE)


# Stats — 柱状图
def draw_stats(d: ImageDraw.ImageDraw) -> None:
    w = 3
    m = 10
    bot = SZ - m
    # 基线
    d.line([(m, bot), (SZ - m, bot)], fill=WHITE, width=w)
    # 三根柱子
    bars = [(m + 6, 10), (SZ // 2, 14), (SZ - m - 8, 6)]
    bw = 8
    gap = 4
    for i, (bx, bh) in enumerate([(m + 6, 14), (SZ // 2 - bw // 2, 20), (SZ - m - 14, 8)]):
        d.rectangle([bx, bot - bh, bx + bw, bot], fill=WHITE)


# Settings — 齿轮(简化)
def draw_settings(d: ImageDraw.ImageDraw) -> None:
    w = 3
    cx = SZ // 2
    cy = SZ // 2
    r_outer = 16
    r_inner = 8
    # 外圈
    d.ellipse([cx - r_outer, cy - r_outer, cx + r_outer, cy + r_outer], fill=None, outline=WHITE, width=w)
    # 内圈
    d.ellipse([cx - r_inner, cy - r_inner, cx + r_inner, cy + r_inner], fill=WHITE)
    # 齿
    import math
    for i in range(8):
        a = i * math.pi / 4
        # 外齿
        ox = cx + int((r_outer + 1) * math.cos(a))
        oy = cy + int((r_outer + 1) * math.sin(a))
        ix = cx + int((r_outer - 4) * math.cos(a))
        iy = cy + int((r_outer - 4) * math.sin(a))
        d.line([(ox, oy), (ix, iy)], fill=WHITE, width=w + 1)


if __name__ == "__main__":
    make_icon("projects", draw_home)
    make_icon("terminal", draw_terminal)
    make_icon("stats", draw_stats)
    make_icon("settings", draw_settings)
    print("Done.")
