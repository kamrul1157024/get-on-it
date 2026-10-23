#!/usr/bin/env python3
"""Draw the Play Store icon (512x512) and feature graphic (1024x500).

Usage: python3 scripts/play_graphics.py   (needs Pillow: pip install pillow)

Writes docs/play-store/icon-512.png and docs/play-store/feature-graphic.png
from the app icon (mobile/assets/icon/icon.png).
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "play-store"
ICON = ROOT / "mobile" / "assets" / "icon" / "icon.png"
BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
REGULAR = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    icon = Image.open(ICON).convert("RGBA")
    icon.resize((512, 512), Image.LANCZOS).save(OUT / "icon-512.png")

    w, h = 1024, 500
    g = Image.new("RGB", (w, h))
    top, bottom = (124, 92, 250), (70, 44, 180)
    px = g.load()
    for y in range(h):
        for x in range(w):
            t = (x / w * 0.6) + (y / h * 0.4)
            px[x, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    d = ImageDraw.Draw(g)
    # The app icon with a soft shadow, then the name and slogan.
    big = icon.resize((270, 270), Image.LANCZOS)
    shadow = Image.new("RGBA", big.size, (20, 8, 70, 0))
    shadow.putalpha(big.getchannel("A").point(lambda a: a * 90 // 255))
    g.paste(shadow, (104, 128), shadow)
    g.paste(big, (95, 115), big)
    d.text((420, 150), "Get On It", font=ImageFont.truetype(BOLD, 92), fill=(255, 255, 255))
    d.text((424, 268), "Do the thing.", font=ImageFont.truetype(REGULAR, 50), fill=(232, 226, 255))
    d.text(
        (426, 350),
        "Goals, habits and courses that push you.",
        font=ImageFont.truetype(REGULAR, 26),
        fill=(214, 206, 255),
    )
    g.save(OUT / "feature-graphic.png")
    print("wrote", OUT / "icon-512.png", "and", OUT / "feature-graphic.png")


if __name__ == "__main__":
    main()
