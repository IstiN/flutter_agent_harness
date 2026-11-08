# Store screenshot media assets

Real generated artwork used inside the App Store / Google Play marketing
screenshots produced by `test/golden/store_screenshots_test.dart`. These
are test fixtures only — never shipped in the app, and no test reads the
network or a provider credential.

- `lisbon_wallpaper.png` — Lisbon at golden hour with terracotta rooftops,
  the Tagus river and a yellow tram. Generated through AIIN with
  `siliconflow/black-forest-labs/FLUX.2-pro` on 2026-11-07, then cropped to
  1200x320 (15:4) for the chat preview, keeping the request, image and
  audio player visible together at phone and desktop aspect ratios. The
  prompt requested premium editorial travel photography, warm coral light,
  no text, logos or watermark.

- `fa_craft/` — pinned Fa Craft 0.2.32 sources (MIT), copied from the
  canonical `fa_widgets` / `IstiN/fa_craft` tree at source commit
  `48ec2af4dc4b04ae357b842da098e01bd8812cb0`. The store fixture adds a
  clearly marked fixed clock/seed and an 18-frame capture ceiling in
  `game/main.js`, a compact narrow-viewport HUD in `game/hud.js`, plus the
  canonical single-child `listView` render adapter in `widget.js`. Everything
  else is byte-identical to the released game; `LICENSE` travels with the
  copy. The real JS/voxel engine renders the app on every device instead of
  stretching a phone screenshot.

The generator copies these bytes into the in-memory sandbox as
`generated/lisbon-wallpaper.png`, matching the mocked `generate_image`
result path and dimensions. Regeneration is a manual marketing-asset
operation, never part of the golden test run.
