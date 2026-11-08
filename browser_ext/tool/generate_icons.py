#!/usr/bin/env python3
"""Regenerate browser-extension icons from the canonical Fa B3 renderer.

Run from anywhere: python3 browser_ext/tool/generate_icons.py
Requires Pillow, already used by flutter_app/tool/generate_fa2_icons.py.
No extension-specific logo geometry lives in this file.
"""

import importlib.util
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
CANONICAL_GENERATOR = ROOT / "flutter_app/tool/generate_fa2_icons.py"


def load_canonical_generator():
    # Keep generator runs limited to the documented icon outputs.
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location(
        "fa_canonical_icons", CANONICAL_GENERATOR
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    canonical = load_canonical_generator()
    master = canonical.render(canonical.B3_NATIVE)
    outputs = {
        ROOT / "browser_ext/icons/icon-16.png": 16,
        ROOT / "browser_ext/icons/icon-32.png": 32,
        ROOT / "browser_ext/icons/icon-48.png": 48,
        ROOT / "browser_ext/icons/icon-128.png": 128,
        ROOT / "browser_ext/store/icon-128.png": 128,
        ROOT / "browser_ext/panel/app/favicon.png": 64,
    }
    for path, size in outputs.items():
        canonical.save_at(master, path, size)
        print(f"{path.relative_to(ROOT)} ({size}x{size})")

    favicon_svg = ROOT / "browser_ext/panel/app/favicon.svg"
    favicon_svg.write_text(canonical.svg(canonical.B3_NATIVE))
    print(f"{favicon_svg.relative_to(ROOT)} (canonical 68x68 SVG)")
    print(f"Regenerated {len(outputs)} browser-extension PNGs from the canonical B3 renderer.")


if __name__ == "__main__":
    main()
