"""build_thumbnail.py — Generate the Steam Workshop thumbnail for the Wingman mod.

Outputs `!wingman.png` (256x256 PNG, < 1 MB) in the same directory as this script.

Design:
- Vertical dark navy gradient background (#0B1929 -> #1A2B4A)
- Stylized wing icon (geometric, no Game Workshop IP)
- Bold "WINGMAN" wordmark in warm gold (#E6B450)
- Subtitle: "TWW3" in cool grey-blue (#9DB1C7)
- Tagline: "AI Co-Pilot" in muted grey-blue

Reproducible: no randomness, deterministic output every run.
Requires: Pillow (PIL).

Run from anywhere:
    python build_thumbnail.py

Falls back gracefully if Pillow is missing — prints install instructions.
"""

from __future__ import annotations

import math
import os
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:
    sys.stderr.write(
        "Pillow is required. Install with:  python -m pip install Pillow\n"
    )
    raise


# ---------- Design tokens ----------
SIZE = 256
BG_TOP = (11, 25, 41)        # #0B1929
BG_BOTTOM = (26, 43, 74)     # #1A2B4A
GOLD = (230, 180, 80)        # #E6B450
GOLD_DEEP = (180, 130, 50)
GREY_BLUE = (157, 177, 199)  # #9DB1C7
MUTED = (120, 138, 158)
WHITE_SOFT = (235, 232, 220)


def _resolve_font(size: int, bold: bool = False) -> ImageFont.ImageFont:
    """Find a usable TTF font. Falls back to PIL default if no TTF found."""
    candidates = [
        # Windows
        r"C:\Windows\Fonts\segoeuib.ttf" if bold else r"C:\Windows\Fonts\segoeui.ttf",
        r"C:\Windows\Fonts\arialbd.ttf" if bold else r"C:\Windows\Fonts\arial.ttf",
        r"C:\Windows\Fonts\calibrib.ttf" if bold else r"C:\Windows\Fonts\calibri.ttf",
        # Linux
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        # macOS
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def _vertical_gradient(size: int) -> Image.Image:
    """Create a top-to-bottom RGB gradient image."""
    base = Image.new("RGB", (size, size), BG_TOP)
    top = BG_TOP
    bot = BG_BOTTOM
    px = base.load()
    for y in range(size):
        t = y / max(1, size - 1)
        r = int(top[0] + (bot[0] - top[0]) * t)
        g = int(top[1] + (bot[1] - top[1]) * t)
        b = int(top[2] + (bot[2] - top[2]) * t)
        for x in range(size):
            px[x, y] = (r, g, b)
    return base


def _radial_glow(img: Image.Image, center: tuple[int, int], radius: int,
                 color: tuple[int, int, int], alpha: int) -> None:
    """Paint a soft radial highlight onto img (in place)."""
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    for r in range(radius, 0, -2):
        a = int(alpha * (1 - r / radius) ** 2)
        draw.ellipse(
            [center[0] - r, center[1] - r, center[0] + r, center[1] + r],
            fill=(color[0], color[1], color[2], a),
        )
    overlay = overlay.filter(ImageFilter.GaussianBlur(radius=18))
    img.alpha_composite(overlay)


def _draw_wing(draw: ImageDraw.ImageDraw, cx: int, cy: int, span: int) -> None:
    """Stylized abstract wing — three angled feather strokes per side, mirrored."""
    # Center fuselage accent
    draw.polygon(
        [(cx - 3, cy + 18), (cx + 3, cy + 18), (cx + 1, cy - 10), (cx - 1, cy - 10)],
        fill=GOLD_DEEP,
    )

    # Helper: one feather stroke
    def feather(angle_deg: float, length: int, offset: int, color: tuple[int, int, int]):
        a = math.radians(angle_deg)
        x0 = cx + offset
        y0 = cy
        x1 = cx + offset + length * math.cos(a)
        y1 = cy + length * math.sin(a)
        draw.line([(x0, y0), (x1, y1)], fill=color, width=4)

    # Left wing (three feathers)
    for i, (ang, ln, off) in enumerate([(-60, span - 12, -6), (-50, span - 4, -4), (-40, span - 18, -2)]):
        feather(ang, ln, off, GOLD if i == 0 else GOLD_DEEP)
    # Right wing (mirrored)
    for i, (ang, ln, off) in enumerate([(180 + 60, span - 12, 6), (180 + 50, span - 4, 4), (180 + 40, span - 18, 2)]):
        feather(ang, ln, off, GOLD if i == 0 else GOLD_DEEP)


def _draw_text_centered(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont,
                        y: int, fill: tuple[int, int, int], img_w: int) -> None:
    """Draw `text` horizontally centered at vertical position `y`."""
    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    x = (img_w - tw) // 2 - bbox[0]
    draw.text((x, y - bbox[1]), text, font=font, fill=fill)


def build(out_path: Path) -> None:
    # Start with vertical gradient (RGB), convert to RGBA for overlays.
    base = _vertical_gradient(SIZE).convert("RGBA")

    # Subtle warm glow behind the wing area for depth.
    _radial_glow(base, center=(SIZE // 2, 88), radius=70, color=GOLD, alpha=60)
    # Cool glow bottom for symmetry.
    _radial_glow(base, center=(SIZE // 2, 200), radius=80, color=(60, 90, 140), alpha=50)

    draw = ImageDraw.Draw(base)

    # Wing icon (centered horizontally, upper third).
    _draw_wing(draw, cx=SIZE // 2, cy=80, span=60)

    # Thin gold divider line.
    line_y = 122
    draw.line([(60, line_y), (SIZE - 60, line_y)], fill=GOLD_DEEP, width=2)

    # "WINGMAN" wordmark — bold, large, gold.
    title_font = _resolve_font(40, bold=True)
    _draw_text_centered(draw, "WINGMAN", title_font, y=140, fill=GOLD, img_w=SIZE)

    # "TWW3" subtitle — medium, grey-blue, letter-spaced look via separate draws.
    sub_font = _resolve_font(18, bold=True)
    sub_text = "TWW3"
    bbox = draw.textbbox((0, 0), sub_text, font=sub_font)
    tw = bbox[2] - bbox[0]
    # Manual letter spacing (4 px gap).
    letters = list(sub_text)
    spacing = 4
    total_w = sum(
        (draw.textbbox((0, 0), ch, font=sub_font)[2] - draw.textbbox((0, 0), ch, font=sub_font)[0])
        for ch in letters
    ) + spacing * (len(letters) - 1)
    x = (SIZE - total_w) // 2
    y_sub = 184
    for ch in letters:
        cb = draw.textbbox((0, 0), ch, font=sub_font)
        cw = cb[2] - cb[0]
        draw.text((x, y_sub), ch, font=sub_font, fill=GREY_BLUE)
        x += cw + spacing

    # Tagline "AI Co-Pilot" — small, muted.
    tag_font = _resolve_font(14, bold=False)
    _draw_text_centered(draw, "AI Co-Pilot", tag_font, y=214, fill=MUTED, img_w=SIZE)

    # Bottom thin accent line + version tag.
    draw.line([(80, 238), (SIZE - 80, 238)], fill=(60, 80, 110), width=1)
    v_font = _resolve_font(10, bold=False)
    _draw_text_centered(draw, "v0.1.0-alpha", v_font, y=242, fill=MUTED, img_w=SIZE)

    # Final: flatten to RGB for maximum compatibility, save as PNG.
    final = base.convert("RGB")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    final.save(out_path, format="PNG", optimize=True)


def main() -> int:
    here = Path(__file__).resolve().parent
    out = here / "!wingman.png"
    build(out)
    size_bytes = out.stat().st_size
    print(f"Wrote {out}  ({size_bytes} bytes)")
    if size_bytes >= 1_048_576:
        sys.stderr.write("WARNING: file is >= 1 MB; Steam Workshop rejects >= 1 MB.\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())