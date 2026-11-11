#!/usr/bin/env python3
"""Draws Fiber's app icon: a twisting bundle of glowing strands that reads as
both a fibre and a sound wave. Writes the three iOS 26 appearances (light,
dark, tinted) into the app icon set, and a preview sheet if given a path.

    python3 scripts/make_icon.py [preview.png]

Needs Pillow and numpy. The result is committed, so this only has to run when
the design changes.
"""
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 3  # strands are drawn 3x larger and shrunk, for smooth edges
W = SIZE * SCALE
OUT = Path(__file__).resolve().parent.parent / "Fiber/Resources/Assets.xcassets/AppIcon.appiconset"

STRANDS = 11
SAMPLES = 2200
X0, X1 = 84, 940
AMPLITUDE = 258
TWISTS = 1.35
TWIST_START = -0.55 * math.pi
RADIUS_MIN, RADIUS_MAX = 2.4, 8.2
SPREAD = 1.0  # how far apart the strands start, in half turns


def blend(a, b, t):
    return tuple(round(a[k] + (b[k] - a[k]) * t) for k in range(3))


def vertical_gradient(top, bottom):
    t = np.linspace(0, 1, SIZE, dtype=np.float32)[:, None, None]
    rows = np.array(top, np.float32) * (1 - t) + np.array(bottom, np.float32) * t
    return Image.fromarray(np.repeat(rows, SIZE, axis=1).astype(np.uint8), "RGB")


def radial_glow(center, radius, color, strength):
    """An RGBA layer: `color` fading out from `center` (as fractions of the icon)."""
    ys, xs = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    distance = np.hypot(xs - center[0] * SIZE, ys - center[1] * SIZE) / (radius * SIZE)
    alpha = np.clip(1 - distance, 0, 1) ** 1.6 * strength * 255
    layer = np.zeros((SIZE, SIZE, 4), np.uint8)
    layer[..., :3] = color
    layer[..., 3] = alpha.astype(np.uint8)
    return Image.fromarray(layer, "RGBA")


def strand_alpha():
    """All strands as one alpha mask at 3x size, with depth: a strand turning
    away from the viewer is thinner and fainter than one coming towards it."""
    total = Image.new("L", (W, W), 0)
    for i in range(STRANDS):
        mask = Image.new("L", (W, W), 0)
        draw = ImageDraw.Draw(mask)
        phase = math.pi * SPREAD * i / (STRANDS - 1)
        for s in range(SAMPLES + 1):
            t = s / SAMPLES
            envelope = math.sin(math.pi * t) ** 0.8
            angle = 2 * math.pi * TWISTS * t + TWIST_START + phase
            front = 0.5 + 0.5 * math.cos(angle + math.pi * 0.35)
            x = (X0 + (X1 - X0) * t) * SCALE
            y = (SIZE / 2 + AMPLITUDE * envelope * math.sin(angle)) * SCALE
            radius = (RADIUS_MIN + (RADIUS_MAX - RADIUS_MIN) * envelope) * (0.62 + 0.38 * front) * SCALE
            level = round(255 * (0.30 + 0.70 * front ** 1.3))
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=level)
        total = ImageChops.lighter(total, mask)
    return total.resize((SIZE, SIZE), Image.LANCZOS)


def tinted(alpha, color_left, color_right=None):
    """Colours a mask, optionally with a left-to-right colour change."""
    color_right = color_right or color_left
    t = np.linspace(0, 1, SIZE, dtype=np.float32)[None, :, None]
    row = np.array(color_left, np.float32) * (1 - t) + np.array(color_right, np.float32) * t
    layer = np.repeat(row, SIZE, axis=0).astype(np.uint8)
    image = Image.fromarray(layer, "RGB").convert("RGBA")
    image.putalpha(alpha)
    return image


def glow(alpha, radius, color, strength, offset=(0, 0)):
    blurred = alpha.filter(ImageFilter.GaussianBlur(radius)).point(lambda v: min(255, round(v * strength)))
    if offset != (0, 0):
        blurred = ImageChops.offset(blurred, *offset)
    return tinted(blurred, color)


def light(alpha):
    canvas = vertical_gradient((255, 96, 128), (222, 18, 70)).convert("RGBA")
    canvas.alpha_composite(radial_glow((0.28, 0.16), 0.85, (255, 255, 255), 0.30))
    canvas.alpha_composite(radial_glow((0.95, 1.05), 0.7, (120, 0, 40), 0.35))
    canvas.alpha_composite(glow(alpha, 11, (150, 0, 45), 0.55, offset=(0, 9)))
    canvas.alpha_composite(glow(alpha, 18, (255, 255, 255), 0.80))
    canvas.alpha_composite(tinted(alpha, (255, 255, 255), (255, 236, 241)))
    return canvas.convert("RGB")


def dark(alpha):
    canvas = vertical_gradient((30, 8, 16), (8, 2, 5)).convert("RGBA")
    canvas.alpha_composite(radial_glow((0.5, 0.5), 0.75, (255, 55, 95), 0.34))
    canvas.alpha_composite(glow(alpha, 20, (255, 55, 95), 0.95))
    canvas.alpha_composite(tinted(alpha, (255, 70, 108), (255, 168, 186)))
    return canvas.convert("RGB")


def mono(alpha):
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 255))
    canvas.alpha_composite(glow(alpha, 16, (255, 255, 255), 0.55))
    canvas.alpha_composite(tinted(alpha, (255, 255, 255)))
    return canvas.convert("RGB")


def preview(images, path):
    """The three icons with iOS-style rounded corners, big and at home-screen size."""
    sheet = Image.new("RGB", (3 * 540 + 60, 540 + 180), (28, 28, 30))
    for column, image in enumerate(images):
        for size, top in ((512, 14), (120, 560)):
            tile = image.resize((size, size), Image.LANCZOS).convert("RGBA")
            rounding = Image.new("L", (size * 4, size * 4), 0)
            ImageDraw.Draw(rounding).rounded_rectangle((0, 0, size * 4 - 1, size * 4 - 1), radius=int(size * 4 * 0.2237), fill=255)
            tile.putalpha(rounding.resize((size, size), Image.LANCZOS))
            sheet.paste(tile, (20 + column * 540 + (256 - size // 2 if size < 512 else 0), top), tile)
    sheet.save(path)


def main():
    alpha = strand_alpha()
    images = [light(alpha), dark(alpha), mono(alpha)]
    for name, image in zip(("AppIcon.png", "AppIcon-Dark.png", "AppIcon-Tinted.png"), images):
        image.save(OUT / name, optimize=True)
        print("wrote", (OUT / name).relative_to(OUT.parent.parent.parent.parent))
    if len(sys.argv) > 1:
        preview(images, sys.argv[1])


if __name__ == "__main__":
    main()
