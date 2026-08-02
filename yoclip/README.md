# Fa — AI Agent · Promo Videos

One 19 s hero promo, rendered in three aspects × two languages (EN/RU) with
voiceover and an original synth music bed. Built with
[yoclip](https://github.com/IstiN/yoclip) (code-first, Remotion-style) — this
folder IS the yoclip project; see `CREATIVE.md` for the treatment and `QA.md`
for the frame-by-frame quality pass.

## Outputs (`out/`, gitignored — regenerate with `tools/render_all.sh`)

| File | Resolution | fps | Lang | Target |
|------|-----------|-----|------|--------|
| `fa_promo_app_preview_en.mp4` | 1290×2796 | 30 | EN | Apple App Preview (iPhone 6.9") |
| `fa_promo_app_preview_ru.mp4` | 1290×2796 | 30 | RU | Apple App Preview (iPhone 6.9") |
| `fa_promo_social_en.mp4` | 1080×1920 | 30 | EN | Reels / TikTok / Shorts |
| `fa_promo_social_ru.mp4` | 1080×1920 | 30 | RU | Reels / TikTok / Shorts |
| `fa_promo_youtube_en.mp4` | 1920×1080 | 30 | EN | YouTube / site hero |
| `fa_promo_youtube_ru.mp4` | 1920×1080 | 30 | RU | YouTube / site hero |

All: 19.0 s, h264 (yuv420p, progressive, `+faststart`), AAC 192 kbps stereo,
no alpha channel. App Preview files comply with Apple limits (≤ 30 s, 30 fps,
no URLs/pricing/download CTAs). Exact byte sizes in `QA.md`.

## Project layout

- `yoclip.yaml` — config, theme, variants (per-aspect resolutions + lang),
  `external_assets` (screens + icon).
- `project.js` — scene layers + EN/RU text dictionaries (all copy lives here).
- `lib/animation.js` — easing/motion/theme helpers.
- `scenes/background.scene.js` — stage: drifting orbs + vignette (full length).
- `scenes/01_showcase.scene.js` — the hero shot: 3D-turning phone holding five
  real App Store goldens + kinetic headlines (frames 0–456).
- `scenes/02_endcard.scene.js` — Fa mark pop + wordmark (frames 444–570).
- `assets/images/` — device crops of the committed store goldens
  (`flutter_app/test/goldens/store/{en,ru}/ios/`, device card only, marketing
  copy cropped off) + `icon_1024.png`.
- `assets/voiceover/` — TTS segments + mixed 19 s VO tracks (EN Samantha /
  RU Milena — macOS `say`; upgrade path in `CREATIVE.md`).
- `assets/audio/music_bed.*` — ffmpeg-composed A-minor synth pad (royalty-safe,
  no samples).
- `tools/build_audio.sh` — VO + music pipeline (idempotent; segments cached).
- `tools/render_all.sh` — renders all six variants and muxes audio.
- `tools/qa_frames.sh` — extracts ~1 frame/s from every final mp4 for QA.

## Rebuild

```bash
tools/build_audio.sh    # voiceover + music (only if copy/timing changed)
tools/render_all.sh     # ~6 × 2–4 min; writes out/*.mp4
tools/qa_frames.sh      # frame extraction for the QA pass
```

Preview a single frame:

```bash
cd /Users/Uladzimir_Klyshevich/git/yoclip/packages/yoclip_cli
dart run bin/yoclip.dart screenshot \
  --project /Users/Uladzimir_Klyshevich/git/flutter_agent/yoclip \
  --frame 60 --variant app_preview_en --output /tmp/frame.png
```
