"""着落应用图标生成脚本（绿色系：日历 + 对勾）。

用法：uv run python tools/gen_icons.py
输出：assets/icon/icon.png（1024 全图标）、icon_foreground.png（自适应前景，图形放大 1.15）
"""
from PIL import Image, ImageDraw

W = 1024

GRAD_TOP = (0x3B, 0xB0, 0x6A)
GRAD_BOT = (0x2A, 0x94, 0x56)
WHITE = (255, 255, 255, 255)
LINE = (0x8F, 0xC9, 0xA8, 255)  # 浅绿格线（加深：小尺寸下仍可见）
CHECK = (0x1B, 0x6E, 0x43, 255)  # 深绿对勾
CHECK_W = 72

# 元素整体放大（围绕画布中心 512）：此前日历占 46% 宽偏小，1.2 后约 55%
ELEM = 1.2

# 图形元素（与 assets/icon/icon.svg 一致，1024 坐标系）
RINGS = [(356, 286, 404, 362), (620, 286, 668, 362)]  # 系环（x0,y0,x1,y1）
CAL = (276, 330, 748, 694)  # 日历面
CAL_R = 64
HEAD = (308, 444, 716, 458)  # 页眉线
GRID_V = [(380, 472, 390, 662), (634, 472, 644, 662)]  # 竖格线
GRID_H = (308, 536, 716, 546)  # 横格线
CHECK_PTS = [(380, 558), (470, 632), (634, 460)]  # 内收版对勾（端点圆头不贴日历边）


def _gradient_bg(draw: ImageDraw.ImageDraw) -> None:
    for y in range(W):
        t = y / (W - 1)
        c = tuple(int(GRAD_TOP[i] + (GRAD_BOT[i] - GRAD_TOP[i]) * t) for i in range(3)) + (255,)
        draw.line([(0, y), (W, y)], fill=c)


def _scale(points, factor: float) -> list:
    """围绕画布中心 (512,512) 缩放坐标（元素基准放大 ELEM × factor）。"""
    f = ELEM * factor
    return [512 + (v - 512) * f for v in points]


def _draw_graphics(draw: ImageDraw.ImageDraw, scale: float = 1.0) -> None:
    s = lambda *xs: _scale(list(xs), scale)  # noqa: E731
    for x0, y0, x1, y1 in RINGS:
        draw.rounded_rectangle(s(x0, y0, x1, y1), radius=24, fill=WHITE)
    x0, y0, x1, y1 = CAL
    draw.rounded_rectangle(s(x0, y0, x1, y1), radius=CAL_R, fill=WHITE)
    draw.rounded_rectangle(s(*HEAD), radius=7, fill=LINE)
    for g in GRID_V:
        draw.rounded_rectangle(s(*g), radius=5, fill=LINE)
    draw.rounded_rectangle(s(*GRID_H), radius=5, fill=LINE)
    pts = [tuple(s(*p)) for p in CHECK_PTS]
    draw.line(pts, fill=CHECK, width=CHECK_W, joint="curve")
    for px, py in pts:
        draw.ellipse(
            [px - CHECK_W / 2, py - CHECK_W / 2, px + CHECK_W / 2, py + CHECK_W / 2],
            fill=CHECK,
        )


def gen_icon() -> None:
    img = Image.new("RGBA", (W, W))
    d = ImageDraw.Draw(img)
    _gradient_bg(d)
    _draw_graphics(d)
    img.save("assets/icon/icon.png")
    print("icon.png ok")


def gen_foreground() -> None:
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # 前景与主图标同尺寸图形（ELEM 1.2，安全区 66% 内），背景由系统提供
    _draw_graphics(d, scale=1.0)
    img.save("assets/icon/icon_foreground.png")
    print("icon_foreground.png ok")


if __name__ == "__main__":
    gen_icon()
    gen_foreground()
