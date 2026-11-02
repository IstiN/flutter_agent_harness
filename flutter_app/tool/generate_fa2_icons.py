#!/usr/bin/env python3
"""Render the canonical B3-square-accent Fa logo to every icon asset.

The geometry is the same 68x68 vector contract as fa_ui's FaLogoPainter and
references/fa-pocs/fa2.0/logos.html. Pillow avoids host SVG delegates,
so raster output is reproducible. Run through icon/generate_icons.sh, which
then derives Android and Play assets from the generated iOS master.
"""

from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
MASTER = 1024
SUPERSAMPLE = 4
# Static icon equivalents of the Glass token palettes. The Flutter painter
# resolves these roles from FaDesignTokens for every direction and brightness.
GLASS_DARK = {
    "background": "#1E1E1E", "surface1": "#1C1C1E",
    "ink1": "#F5F5F7", "accent": "#3F8FF7", "agent2": "#818CF8",
}
GLASS_LIGHT = {
    "background": "#F5F5F7", "surface1": "#FFFFFF",
    "ink1": "#1D1D1F", "accent": "#3F8FF7", "agent2": "#4F46E5",
}
# Native launcher artwork follows the selected B3-square-accent reference
# exactly. In-app marks remain themeable; a launcher icon must not flip to a
# white tile merely because the light desktop theme is active.
B3_NATIVE = {
    "background": "#1E1E1E", "surface1": "#121828",
    "ink1": "#F0F4FC", "accent": "#38BDF8", "agent2": "#9366FF",
}


def render(palette, full_bleed=False):
    canvas_size = MASTER * SUPERSAMPLE
    scale = canvas_size / 68
    background = palette["background"] if full_bleed else (0, 0, 0, 0)
    image = Image.new("RGBA", (canvas_size, canvas_size), background)
    draw = ImageDraw.Draw(image)

    def point(x, y):
        return (x * scale, y * scale)

    def line(points, color, width):
        scaled = [point(x, y) for x, y in points]
        pixel_width = round(width * scale)
        draw.line(scaled, fill=color, width=pixel_width, joint="curve")
        radius = pixel_width / 2
        for x, y in (scaled[0], scaled[-1]):
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)

    def circle(cx, cy, radius, fill=None, outline=None, width=1):
        box = (*point(cx - radius, cy - radius), *point(cx + radius, cy + radius))
        draw.ellipse(box, fill=fill, outline=outline, width=round(width * scale))

    draw.rounded_rectangle(
        (*point(4, 4), *point(64, 64)), radius=round(18 * scale),
        fill=palette["surface1"], outline=palette["accent"], width=round(2 * scale),
    )
    line([(15, 28), (22, 34), (15, 40)], palette["accent"], 2.8)

    # Vector Fa at x=27 / baseline=42; no host font is involved.
    line([(27, 42), (27, 26), (38.5, 26)], palette["ink1"], 2.8)
    line([(27, 33.5), (35.5, 33.5)], palette["ink1"], 2.8)
    circle(43, 36, 5, outline=palette["ink1"], width=2.6)
    line([(48, 31), (48, 42)], palette["ink1"], 2.6)
    circle(48, 22, 3.2, fill=palette["agent2"])
    return image.resize((MASTER, MASTER), Image.Resampling.LANCZOS)


def svg(palette, full_bleed=False, safe=False, foreground=False):
    body = f'''<rect x="4" y="4" width="60" height="60" rx="18" fill="{palette["surface1"]}" stroke="{palette["accent"]}" stroke-width="2"/>
  <path d="M15 28 L22 34 L15 40" fill="none" stroke="{palette["accent"]}" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M27 42 V26 H38.5" fill="none" stroke="{palette["ink1"]}" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M27 33.5 H35.5" fill="none" stroke="{palette["ink1"]}" stroke-width="2.8" stroke-linecap="round"/>
  <circle cx="43" cy="36" r="5" fill="none" stroke="{palette["ink1"]}" stroke-width="2.6"/>
  <path d="M48 31 V42" fill="none" stroke="{palette["ink1"]}" stroke-width="2.6" stroke-linecap="round"/>
  <circle cx="48" cy="22" r="3.2" fill="{palette["agent2"]}"/>'''
    size = 124 if safe else 68
    background = ""
    if full_bleed and not foreground:
        background = f'<rect width="{size}" height="{size}" fill="{palette["background"]}"/>\n '
    if safe:
        body = f'<g transform="translate(28 28)">{body}</g>'
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}">\n {background}{body}\n</svg>\n'


def save_at(master, path, size):
    path.parent.mkdir(parents=True, exist_ok=True)
    master.resize((size, size), Image.Resampling.LANCZOS).save(path, optimize=True)


def main():
    dark = render(B3_NATIVE)
    light = render(GLASS_LIGHT)
    ios = render(B3_NATIVE, full_bleed=True)
    icon_dir = ROOT / "icon"
    dark.save(icon_dir / "icon_1024.png", optimize=True)
    light.save(icon_dir / "icon_light_1024.png", optimize=True)
    ios.save(ROOT / "assets/app_icon_source.png", optimize=True)
    (icon_dir / "icon.svg").write_text(svg(B3_NATIVE))
    (icon_dir / "icon_light.svg").write_text(svg(GLASS_LIGHT))
    (icon_dir / "icon_ios.svg").write_text(svg(B3_NATIVE, full_bleed=True))
    (icon_dir / "icon_foreground.svg").write_text(svg(B3_NATIVE, safe=True, foreground=True))
    (icon_dir / "icon_maskable.svg").write_text(svg(B3_NATIVE, full_bleed=True, safe=True))
    (ROOT / "web/favicon.svg").write_text(svg(B3_NATIVE))

    ios_dir = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    ios_sizes = {
        "Icon-App-20x20@1x.png": 20, "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60, "Icon-App-29x29@1x.png": 29,
        "Icon-App-29x29@2x.png": 58, "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40, "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120, "Icon-App-50x50@1x.png": 50,
        "Icon-App-50x50@2x.png": 100, "Icon-App-57x57@1x.png": 57,
        "Icon-App-57x57@2x.png": 114, "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180, "Icon-App-72x72@1x.png": 72,
        "Icon-App-72x72@2x.png": 144, "Icon-App-76x76@1x.png": 76,
        "Icon-App-76x76@2x.png": 152, "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }
    for name, size in ios_sizes.items():
        save_at(ios, ios_dir / name, size)

    web = ROOT / "web"
    save_at(dark, web / "icons/Icon-192.png", 192)
    save_at(dark, web / "icons/Icon-512.png", 512)
    save_at(dark, web / "favicon.png", 64)
    maskable = Image.new("RGBA", (MASTER, MASTER), B3_NATIVE["background"])
    inner = ios.resize((614, 614), Image.Resampling.LANCZOS)
    maskable.alpha_composite(inner, (205, 205))
    save_at(maskable, web / "icons/Icon-maskable-192.png", 192)
    save_at(maskable, web / "icons/Icon-maskable-512.png", 512)

    mac = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for size in (16, 32, 64, 128, 256, 512, 1024):
        save_at(dark, mac / f"app_icon_{size}.png", size)
        save_at(dark, icon_dir / f"icon_dark_{size}.png", size)

    windows = ROOT / "windows/runner/resources/app_icon.ico"
    windows.parent.mkdir(parents=True, exist_ok=True)
    dark.save(windows, sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])
    print("Canonical Fa 2.0 non-Android icons regenerated.")


if __name__ == "__main__":
    main()
