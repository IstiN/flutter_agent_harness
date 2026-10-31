#!/usr/bin/env python3
"""Render the canonical Squircle-V2 Fa logo to every icon asset.

The geometry is the same 84x84 vector contract as fa_ui's FaLogoPainter and
references/fa-pocs/fa2.0/logos.html. Pillow avoids host SVG delegates,
so raster output is reproducible. Run through icon/generate_icons.sh, which
then derives Android and Play assets from the generated iOS master.
"""

from math import cos, pi, sin
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
MASTER = 1024
SUPERSAMPLE = 4
GLASS_DARK = {
    "background": "#080A10", "surface1": "#0F1320", "surface2": "#161B2C",
    "ink1": "#F0F4FC", "hairline": "#222D46", "accent": "#38BDF8",
    "agent2": "#818CF8",
}
GLASS_LIGHT = {
    "background": "#F0F4F8", "surface1": "#FFFFFF", "surface2": "#E5ECF4",
    "ink1": "#0B1322", "hairline": "#C4D2E4", "accent": "#0277BD",
    "agent2": "#4F46E5",
}


def rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def mix(a, b, amount):
    ca, cb = rgb(a), rgb(b)
    values = [round(x + (y - x) * amount) for x, y in zip(ca, cb)]
    return "#" + "".join(f"{value:02X}" for value in values)


def arc(cx, cy, radius, start, end, steps=16):
    return [
        (cx + radius * cos(start + (end - start) * i / steps),
         cy + radius * sin(start + (end - start) * i / steps))
        for i in range(steps + 1)
    ]


def bubble_points():
    return (
        [(20, 22), (64, 22)]
        + arc(64, 30, 8, -pi / 2, 0)[1:]
        + [(72, 46)]
        + arc(64, 46, 8, 0, pi / 2)[1:]
        + [(38, 54), (26, 62), (26, 54), (20, 54)]
        + arc(20, 46, 8, pi / 2, pi)[1:]
        + [(12, 30)]
        + arc(20, 30, 8, pi, 3 * pi / 2)[1:]
    )


def render(palette, full_bleed=False):
    canvas_size = MASTER * SUPERSAMPLE
    scale = canvas_size / 84
    background = palette["background"] if full_bleed else (0, 0, 0, 0)
    image = Image.new("RGBA", (canvas_size, canvas_size), background)
    draw = ImageDraw.Draw(image)

    def point(x, y):
        return (x * scale, y * scale)

    def line(points, color, width, transform=None):
        if transform is not None:
            tx, ty, factor = transform
            points = [(tx + x * factor, ty + y * factor) for x, y in points]
            width *= factor
        scaled = [point(x, y) for x, y in points]
        pixel_width = round(width * scale)
        draw.line(scaled, fill=color, width=pixel_width, joint="curve")
        radius = pixel_width / 2
        for x, y in (scaled[0], scaled[-1]):
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)

    def circle(cx, cy, radius, fill=None, outline=None, width=1, transform=None):
        if transform is not None:
            tx, ty, factor = transform
            cx, cy, radius, width = tx + cx * factor, ty + cy * factor, radius * factor, width * factor
        box = (*point(cx - radius, cy - radius), *point(cx + radius, cy + radius))
        draw.ellipse(box, fill=fill, outline=outline, width=round(width * scale))

    outer = mix(palette["surface1"], palette["accent"], .09)
    draw.rounded_rectangle(
        (*point(4, 4), *point(80, 80)), radius=round(22 * scale),
        fill=outer, outline=palette["hairline"], width=round(1.5 * scale),
    )
    bubble = [point(x, y) for x, y in bubble_points()]
    bubble_fill = mix(outer, palette["surface2"], .84)
    draw.polygon(bubble, fill=bubble_fill)
    draw.line(bubble + [bubble[0]], fill=palette["accent"], width=round(1.8 * scale), joint="curve")

    line([(0, 28), (0, 0), (16, 0)], palette["ink1"], 3.5, (24, 26, .72))
    line([(0, 12.5), (12, 12.5)], palette["ink1"], 3.5, (24, 26, .72))
    circle(7, 11, 6.5, outline=palette["ink1"], width=3, transform=(38, 31, .82))
    line([(13.5, 4.5), (13.5, 17.5)], palette["ink1"], 3, (38, 31, .82))

    line([(52, 28), (57, 33), (52, 38)], palette["accent"], 2)
    line([(59, 38), (63, 38)], palette["accent"], 2)
    circle(60, 46, 3, fill=palette["agent2"])
    return image.resize((MASTER, MASTER), Image.Resampling.LANCZOS)


def svg(palette, full_bleed=False, safe=False, foreground=False):
    outer = mix(palette["surface1"], palette["accent"], .09)
    bubble_fill = mix(outer, palette["surface2"], .84)
    body = f'''<rect x="4" y="4" width="76" height="76" rx="22" fill="{outer}" stroke="{palette["hairline"]}" stroke-width="1.5"/>
  <path d="M20 22 H64 A8 8 0 0 1 72 30 V46 A8 8 0 0 1 64 54 H38 L26 62 V54 H20 A8 8 0 0 1 12 46 V30 A8 8 0 0 1 20 22 Z" fill="{bubble_fill}" stroke="{palette["accent"]}" stroke-width="1.8" stroke-linejoin="round"/>
  <g transform="translate(24 26) scale(.72)" fill="none" stroke="{palette["ink1"]}" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"><path d="M0 28 V0 H16"/><path d="M0 12.5 H12"/></g>
  <g transform="translate(38 31) scale(.82)"><circle cx="7" cy="11" r="6.5" fill="none" stroke="{palette["ink1"]}" stroke-width="3"/><path d="M13.5 4.5 V17.5" fill="none" stroke="{palette["ink1"]}" stroke-width="3" stroke-linecap="round"/></g>
  <path d="M52 28 L57 33 L52 38" fill="none" stroke="{palette["accent"]}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M59 38 H63" fill="none" stroke="{palette["accent"]}" stroke-width="2" stroke-linecap="round"/>
  <circle cx="60" cy="46" r="3" fill="{palette["agent2"]}"/>'''
    size = 140 if safe else 84
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
    dark = render(GLASS_DARK)
    light = render(GLASS_LIGHT)
    ios = render(GLASS_DARK, full_bleed=True)
    icon_dir = ROOT / "icon"
    dark.save(icon_dir / "icon_1024.png", optimize=True)
    light.save(icon_dir / "icon_light_1024.png", optimize=True)
    ios.save(ROOT / "assets/app_icon_source.png", optimize=True)
    (icon_dir / "icon.svg").write_text(svg(GLASS_DARK))
    (icon_dir / "icon_light.svg").write_text(svg(GLASS_LIGHT))
    (icon_dir / "icon_ios.svg").write_text(svg(GLASS_DARK, full_bleed=True))
    (icon_dir / "icon_foreground.svg").write_text(svg(GLASS_DARK, safe=True, foreground=True))
    (icon_dir / "icon_maskable.svg").write_text(svg(GLASS_DARK, full_bleed=True, safe=True))
    (ROOT / "web/favicon.svg").write_text(svg(GLASS_DARK))

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
    maskable = Image.new("RGBA", (MASTER, MASTER), GLASS_DARK["background"])
    inner = ios.resize((614, 614), Image.Resampling.LANCZOS)
    maskable.alpha_composite(inner, (205, 205))
    save_at(maskable, web / "icons/Icon-maskable-192.png", 192)
    save_at(maskable, web / "icons/Icon-maskable-512.png", 512)

    mac = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for size in (16, 32, 64, 128, 256, 512, 1024):
        save_at(light, mac / f"app_icon_{size}.png", size)
        save_at(dark, icon_dir / f"icon_dark_{size}.png", size)

    windows = ROOT / "windows/runner/resources/app_icon.ico"
    windows.parent.mkdir(parents=True, exist_ok=True)
    dark.save(windows, sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])
    print("Canonical Fa 2.0 non-Android icons regenerated.")


if __name__ == "__main__":
    main()
