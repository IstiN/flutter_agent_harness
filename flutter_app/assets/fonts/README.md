# Fa 2.0 font assets

The application bundles the typography from `fa2.0/styleguide.html` and its
`FONT_PRESETS`; it never downloads fonts at runtime. All bundled families are
licensed under SIL OFL 1.1. The corresponding upstream license is stored next
to the TTFs as `<Family>-LICENSE.txt` (`Inter-LICENSE.txt` predates this set).

## Presets

- **System SF** uses native platform fonts and intentionally has no bundled
  TTF. Apple uses `.AppleSystemUIFont` / SF Mono, Windows Segoe UI / Consolas,
  Material platforms Roboto / monospace, and web `system-ui` / `ui-monospace`.
- **Geist** — Geist + Geist Mono.
- **Jakarta** — Plus Jakarta Sans + JetBrains Mono.
- **Inter** — Inter + JetBrains Mono.
- **Outfit** — Outfit display + Inter UI + DM Mono.

The direction typography tokens additionally use Space Grotesk (Nebula),
IBM Plex Sans / IBM Plex Mono (Graphite), and Manrope (Porcelain), so those
families are bundled as well.

## Source and static instances

Files came from the Google Fonts repository `ofl/` directories:
<https://github.com/google/fonts/tree/main/ofl>. Variable fonts were pinned to
static weights with `fontTools varLib.instancer`; IBM Plex Sans also pins
`wdth=100`, and Inter ExtraBold pins `opsz=14`. DM Mono and IBM Plex Mono are
upstream static TTFs. Existing Inter Regular/Medium/SemiBold/Bold and
JetBrains Mono Regular/Bold were retained byte-for-byte.

Jakarta, Outfit, Space Grotesk, and DM Mono do not contain Cyrillic glyphs.
`FaTypography` supplies Inter/system fallbacks for those families; the golden
suite includes a Cyrillic sentence to guard this behavior.
