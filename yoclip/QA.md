# Frame QA — Fa hero promo

Method: every final mp4 was sampled at ~1 frame/s (19 frames each, 114 total)
with `tools/qa_frames.sh` (ffmpeg `fps=1` from the muxed deliverable, so QA
covers what is actually in the file). The `app_preview_en` master was
additionally shot frame-by-frame with `yoclip screenshot --variant
app_preview_en` (frames 0,30,…,540 — see `build/qa/yoclip_shots/`) to verify
the renderer output directly. Every frame was viewed and scored against:
"does this second look expensive, legible, attractive — would I buy?"

Legend: ✅ pass · ⚠️ pass with note · ❌ rejected → fixed → re-rendered.

## Rejected & re-done during the pass

| # | Where | Problem | Fix | Verified |
|---|-------|---------|-----|----------|
| 1 | all portrait beats | Headline column dropped to mid-frame and collided with the phone (Column is `mainAxisSize.max` inside the tight stack; `mainAxisAlignment: center` centered the text block vertically) | portrait uses `mainAxisAlignment: start`, headline anchored to the top zone (`scenes/01_showcase.scene.js`) | ✅ `app_preview_en` f60, `social_ru` f120 |
| 2 | social 9:16 | Phone bottom sat inside the TikTok/Reels caption zone | aspect branch `tall = H/W > 2`: social gets a 0.50H phone lifted to 0.36H; app preview keeps 0.545H at 0.345H | ✅ `social_en` s1/s4 |
| 3 | audio mix | Music bed RMS −17 dB vs VO −24 dB — bed competed with the voice | music mux gain 0.42 → 0.25; all six re-muxed | ✅ final RMS −22.4…−23.0 dB with clear voice lead |
| 4 | beats 2→3, 3→4, 4→5 transitions | 14-frame full crossfade ghosted two readable UIs over each other ("Fattings" = Fa+Settings headers blended) | fade-through-dim: outgoing gone by frame 8, incoming rises frames 7–15; all six re-rendered | ✅ `app_preview_en` s10/s13, mirrored in RU + social + youtube |
| 5 | providers beat (s12–15) | The store_providers golden showed placeholder providers (`Acme · acme.example`, `test-model · example.com`) — read as fake demo data | golden regenerated upstream with realistic providers (Kimi `api.kimi.com · kimi-for-coding`, Ollama `localhost · qwen3:32b`); device frames re-cropped from the fresh EN+RU goldens, all six re-rendered end-to-end and re-QA'd at 1 fps | ✅ providers beat s13–16 viewed in ALL six files + spot-checks (s1/s7/s11/s17) elsewhere |

## Per-second verdicts — `fa_promo_app_preview_en` (master, all 19 viewed)

| s | Beat | Verdict | Note |
|---|------|---------|------|
| 1 | hook entrance | ✅ | phone mid 3D turn-in, dramatic, dashboard readable |
| 2–3 | hook hold | ✅ | "truly yours." gradient crisp, widgets the hero |
| 4–6 | chat build | ✅ | tool-call tiles legible, headline lands clean |
| 7–9 | in-app | ✅ | weather app + embedded chat, good contrast |
| 10 | transition | ✅ (fixed) | dim-through "develop" effect, single screen only |
| 11–12 | media | ✅ | generated lake image sells; speak tile readable |
| 13 | transition | ✅ (fixed) | no ghosting; media holds while headline swaps |
| 14–15 | providers | ✅ (fixed) | realistic providers now: Kimi `api.kimi.com · kimi-for-coding`, Ollama `localhost · qwen3:32b`, default model `kimi-for-coding · Kimi` — reads as a real power-user setup; headline carries the beat |
| 16 | endcard entrance | ✅ | icon pop mid-fade, reads as intentional |
| 17–19 | endcard hold | ✅ | mark + wordmark + tagline locked, gentle final fade |

## Spot-checks across the other five files (post-fix extraction)

- Providers beat (s14) re-verified in every file after the golden swap:
  `app_preview_ru` ✅ (RU UI "Настройки/Добавить провайдера" + new list),
  `social_en` ✅, `social_ru` ✅, `youtube_en` ✅, `youtube_ru` ✅.
- `app_preview_ru` s1/s4/s8/s14/s17 ✅ — Cyrillic perfect in Geneva, RU UI
  goldens match the VO, no overflow ("по-настоящему ваш." fits at W·0.064).
- `social_en` s1/s4/s10/s16/s19 ✅ — all text above the platform caption zone;
  phone bottom ≈ 0.88H, clear of TikTok/Reels UI.
- `social_ru` s5/s10/s17 ✅ — RU headline fits 1080 width with margins.
- `youtube_en` s1/s7/s13/s14/s17 ✅ — left-column type, phone right; s13 dim-
  through transition clean at 16:9 too.
- `youtube_ru` s1/s11/s13 ✅.

No tofu, no clipped text, no overflow, no black-void frames in any of the
extracted frames (114 per pass, two full passes).

## Final file specs (ffprobe)

| File | Resolution | Duration | Size | Avg bitrate | Mix RMS |
|------|-----------|----------|------|-------------|---------|
| `fa_promo_app_preview_en.mp4` | 1290×2796 @30 | 19.00 s | 33.1 MB | 13.9 Mbps | −23.0 dB |
| `fa_promo_app_preview_ru.mp4` | 1290×2796 @30 | 19.00 s | 32.8 MB | 13.8 Mbps | −22.4 dB |
| `fa_promo_social_en.mp4` | 1080×1920 @30 | 19.00 s | 19.3 MB | 8.1 Mbps | −23.0 dB |
| `fa_promo_social_ru.mp4` | 1080×1920 @30 | 19.00 s | 19.2 MB | 8.1 Mbps | −22.4 dB |
| `fa_promo_youtube_en.mp4` | 1920×1080 @30 | 19.00 s | 19.1 MB | 8.0 Mbps | −23.0 dB |
| `fa_promo_youtube_ru.mp4` | 1920×1080 @30 | 19.00 s | 19.0 MB | 8.0 Mbps | −22.4 dB |

(specs refreshed after the providers-golden re-render; audio chain unchanged,
so mix RMS values carry over from the re-mux verification)

All: h264 High, yuv420p (no alpha), progressive `+faststart`, AAC 192 kbps
stereo. App Preview pair is inside Apple's 15–30 s / ≤ 500 MB / 30 fps
limits; no URLs, pricing or download CTAs in copy or VO.

## Known quality gaps (accepted)

- VO is macOS `say` (Samantha/Milena) — intelligible, but system-voice.
  Upgrade path documented in `CREATIVE.md` (drop-in segment replacement,
  re-run `tools/build_audio.sh` + mux).
- Music is a synthesized pad by design (royalty-safe); a produced track would
  add polish but is out of scope for stock-free delivery.
