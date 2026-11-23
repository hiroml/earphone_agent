"""アプリアイコン（1024x1024, 不透明 PNG）を生成する。

モチーフ: イヤホン（左）＋ 音の波（右）＋ AI を表すきらめき（右上）。
実行: uv run --with pillow python design/icon/make_icon.py
出力: design/icon/AppIcon-1024.png（と、iOS PoC のアセットカタログへのコピー）
"""

from __future__ import annotations

import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 4  # スーパーサンプリング倍率（縮小時のアンチエイリアス用）
S = SIZE * SS

TOP = (40, 38, 120)  # 濃い藍
BOTTOM = (18, 140, 160)  # 青緑
WHITE = (255, 255, 255)
ACCENT = (255, 214, 102)  # きらめき（黄）

HERE = Path(__file__).resolve().parent
OUT = HERE / "AppIcon-1024.png"
ASSET = HERE.parents[1] / "poc/ios-bg-mic/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"


def px(v: float) -> int:
    return int(v * SS)


def gradient() -> Image.Image:
    img = Image.new("RGB", (S, S))
    d = ImageDraw.Draw(img)
    for y in range(S):
        t = y / (S - 1)
        c = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
        d.line([(0, y), (S, y)], fill=c)
    return img


def earbud_layer() -> Image.Image:
    """イヤホンを透明レイヤーに描き、時計回りに傾ける（「P」に見えないように）。"""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy, r = 380, 450, 150
    # ステム（下に伸びる軸）
    d.rounded_rectangle([px(cx - 58), px(cy + 30), px(cx + 52), px(cy + 380)], radius=px(55), fill=WHITE)
    # 本体
    d.ellipse([px(cx - r), px(cy - r), px(cx + r), px(cy + r)], fill=WHITE)
    # イヤーチップ（右上）
    tr, tx, ty = 66, cx + 128, cy - 52
    d.ellipse([px(tx - tr), px(ty - tr), px(tx + tr), px(ty + tr)], fill=WHITE)
    # スピーカー部の陰影
    ir = 52
    d.ellipse([px(cx - ir - 18), px(cy - ir + 12), px(cx + ir - 18), px(cy + ir + 12)], fill=(205, 222, 240, 255))
    return layer.rotate(-22, resample=Image.BICUBIC, center=(px(cx), px(cy)))


def draw_waves(d: ImageDraw.ImageDraw) -> None:
    cx, cy = 600, 470
    for radius, width, color in [(120, 34, WHITE), (205, 32, WHITE), (290, 28, (215, 238, 245))]:
        bbox = [px(cx - radius), px(cy - radius), px(cx + radius), px(cy + radius)]
        d.arc(bbox, start=-42, end=42, fill=color, width=px(width))


def draw_sparkle(d: ImageDraw.ImageDraw, cx: float, cy: float, r: float) -> None:
    # 4 方向に尖った星（AI のきらめき）
    w = r * 0.28
    pts = [
        (cx, cy - r), (cx + w, cy - w), (cx + r, cy), (cx + w, cy + w),
        (cx, cy + r), (cx - w, cy + w), (cx - r, cy), (cx - w, cy - w),
    ]
    d.polygon([(px(x), px(y)) for x, y in pts], fill=ACCENT)


def main() -> None:
    img = gradient()

    # 柔らかい光（中央やや上）
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).ellipse([px(220), px(180), px(860), px(820)], fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(px(120)))
    img = Image.composite(Image.new("RGB", (S, S), (120, 200, 230)), img, glow)

    img.paste(earbud_layer(), (0, 0), earbud_layer())
    d = ImageDraw.Draw(img)
    draw_waves(d)
    draw_sparkle(d, 850, 185, 78)
    draw_sparkle(d, 735, 135, 36)

    final = img.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")  # アルファ無し（iOS の要件）
    final.save(OUT, optimize=True)
    ASSET.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(OUT, ASSET)
    print(f"wrote {OUT} and {ASSET}")


if __name__ == "__main__":
    main()
