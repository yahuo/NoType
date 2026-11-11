"""Draw the extension icons: the idle waveform of the macOS menu bar (MenuBarIconProvider).

Usage: python3 integrations/browser/make_icons.py  (needs ImageMagick `magick`)
"""
import subprocess, sys, os
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "extension", "icons")
os.makedirs(out, exist_ok=True)
# MenuBarIconProvider idle waveform. 16/32 are pixel-snapped; larger sizes scale the 18pt geometry.
def bars(size):
    if size == 16: return 2, 1, [4, 6, 10, 6, 4]
    if size == 32: return 4, 2, [8, 12, 20, 12, 8]
    k = size * 0.75 / 16
    return 2 * k, 1.5 * k, [h * k for h in (4, 7, 11, 7, 4)]
def draw(size, color, path):
    w, gap, hs = bars(size)
    x0 = (size - (5 * w + 4 * gap)) / 2
    # Supersample 8x so the half-pixel caps antialias, then box-filter down.
    k = 8
    cmds = []
    for i, h in enumerate(hs):
        x = (x0 + i * (w + gap)) * k
        y = (size - h) / 2 * k
        r = w / 2 * k
        cmds.append(f"roundrectangle {x},{y} {x + w * k - 1},{y + h * k - 1} {r},{r}")
    subprocess.run(["magick", "-size", f"{size * k}x{size * k}", "xc:none", "-fill", color,
                    "-draw", " ".join(cmds), "-filter", "box", "-resize", f"{size}x{size}", "-strip",
                    "PNG32:" + path], check=True)
# `wave` is neutral for the extensions page and the default button; background.js
# switches the button to `wave-light` / `wave-dark` to match the browser theme.
variants = {"wave": ("#8f8f8f", (16, 32, 48, 128)), "wave-light": ("#474747", (16, 32)), "wave-dark": ("#c7c7c7", (16, 32))}
for name, (color, sizes) in variants.items():
    for size in sizes:
        draw(size, color, os.path.join(out, f"{name}-{size}.png"))
