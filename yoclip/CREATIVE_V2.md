# CREATIVE v2 — Fa · "Describe it. Fa builds it." (App Preview 30 s)

> Replaces the v1 treatment (boring static phone + system voice). Style
> target: the energy of `samples/yoclip_big_idea_v2` (Gamma remake) — a
> moving canvas, prompt pills as inputs, real artifacts assembling, brand
> glow. No voiceover: kinetic type + beat-mapped music (App Preview needs
> none; VO upgrade stays a separate option).

## Product truth (what the video may claim)

- Fa = one agent harness on every device (iOS/Android/Web/macOS/Windows/Linux/CLI).
- The agent **builds real working apps by chat** (JS apps platform: 3d-game,
  weather, stocks, map, calculator, crypto, calendar demos exist; for this
  video we add two honest captures: a **fitness trainer** and an
  **english teacher** mini-app, built the same way — they ship as demos).
- Homework help: chat answers with real tools (python solving, steps).
- Real workbench: sandbox shell, git, python/sqlite, file browser, sessions
  with compaction.
- BYOK: any provider; keys live in the platform Keychain (iOS/macOS).
- **Two themes exist for real** (dark + light app themes) — the video mixes
  them: dark brand stage ↔ light stage stations (a white-flash wipe between,
  like big_idea_v2's kaleido flash), end card on off-white.

## Format

- **Primary: App Preview 1290×2796, 30 fps, exactly 30.0 s (900 frames)**,
  h264 + AAC 192k stereo, no alpha. Apple rules honored: no URLs, no pricing,
  no "download" CTA, real UI only, no people.
- Variants after primary: `shorts_en` 1080×1920, `youtube_en` 1920×1080
  (same beats, reframed by yoclip variants). Copy: EN + RU dictionaries.
- **YouTube is a separate plot, not a reframe** (user decision): the App
  Preview is a 30 s product-truth sprint; the YouTube cut gets its own
  treatment (longer beats, real chat sessions, desktop CLI). Shared machinery
  lives in `yoclip/lib/` (easing/type/pill helpers, the dual-layer
  software+flame 3D pattern, the music bed builder).
- Music: energetic synth pulse ≈120 bpm, envelope beat-mapped to the cuts
  (see `MUSIC_PROMPT.md`; v1 pad retired). SFX accents optional: pill "pop",
  lock "click", ticker "tick" (quiet, -18 LUFS mix).

## Story — one continuous canvas (dark ↔ light)

The camera travels a canvas of stations: a **prompt pill types in**,
launches, and the **real artifact assembles** where it lands. All artifact
frames are REAL app captures (JS app frames / store goldens), never mock UI.
Theme mix: beats 1–2 dark brand stage → white-flash wipe into the light
stage for 3–4 → flash back to dark for 5–6 → off-white end card.

### Beat map (900 f @ 30 fps)

| # | frames | s | theme | beat | Action | Copy EN | Copy RU |
|---|--------|---|-------|------|--------|---------|---------|
| 0 | 0–60 | 0–2 | dark | hook | Lone caret types the pill on dark stage; glow pulse; pill LAUNCHES, camera follows | `Fa — build a game` | `Fa — собери игру` |
| 1 | 60–210 | 2–7 | dark | game | Camera dives; pill lands + ripple; phone frame assembles around a **live 3D scene**: Kenney Car Kit GLB models (CC0) driven by flame_3d (hero race car weaves with a suspension bob between two traffic cars) over a scrolling software-mesh synthwave grid — both layers share one camera so they composite aligned; code chips stagger; accent at 5 s | `apps built by chat` | `приложения из чата` |
| 2 | 210–330 | 7–11 | light | fitness | WHITE FLASH wipe → light stage; pill types; **fitness trainer** app card pops (reps counter ticks); stopwatch chip | `your coach, in a tap` | `твой тренер — в один тап` |
| 3 | 330–450 | 11–15 | light | teacher | Slide right; pill; **english teacher** app card — flashcard flips `apple → яблоко` | `a tutor that adapts` | `репетитор, который подстраивается` |
| 4 | 450–570 | 15–19 | dark | homework | Flash back to dark; pill; chat answer solves a quadratic step-by-step, `python3` tool chip glows | `homework? solved, shown` | `домашка? решено и объяснено` |
| 5 | 570–690 | 19–23 | dark | stocks | Pan down; pill; **stocks ticker** card — live ticks rolling, sparkline draws | `it keeps watch for you` | `оно следит за тобой` |
| 6 | 690–780 | 23–26 | dark | trust + everywhere | Lock glyph clicks shut over the providers card; then ZOOM WAY OUT: stations → tile constellation; platform pills fly in | `your keys stay in the Keychain` → `One agent. Every device.` | `ключи — только в Keychain` → `Один агент. Все устройства.` |
| 7 | 780–900 | 26–30 | light | end | Flash to off-white; tiles fly out; **Fa mark pops** (eoBack) + wordmark; meta line; hold to 30.0 | `Describe it. Fa builds it.` | `Скажи — и Fa построит.` |

Platform pills at beat 6: iOS · Android · Web · macOS · Windows · Linux · CLI.

### Motion notes (borrowed from big_idea_v2)

- Typewriter hook with block caret (blink ×2), pill launch with slight
  overshoot; camera follows with ease-out settle.
- Every artifact card: assemble with 3–4 item stagger (8–10 f offsets),
  teal glow pulse on the downbeat; micro-shadows, brand gradient borders.
- The two theme wipes are 6–8 f white flashes (scale+glow, like the v2
  kaleido portal flash) — the ONLY hard cuts; everything else is camera
  eases (24–30 f) on one continuous canvas.
- Live-feel micro-motion inside cards: reps counter, ticker rows, flashcard
  flip, sparkline draw — 2–3 f loops, never static cards.
- Zoom-out at beat 6 is the biggest camera move (settle 18 f); end card on
  off-white with indigo Fa mark (mirrors the dark hook).
- Full-length background: subtle drifting orbs + vignette on dark stations;
  soft paper grain on light stations; NEVER flat color.

## Asset checklist

- [x] Game beat: **live 3D, no capture** — Kenney Car Kit GLBs (`assets/models/`,
      CC0, kenney.nl) + `Textures/colormap.png`, declared in pubspec; rendered
      by flame_3d's headless offscreen capture over a software-mesh grid.
      The zoomout wall tile reuses a real frame crop (`promo_game_dark.png`).
      NOTE: jsr `flame_3d` euler order was fixed for this (yaw↔pitch swap) —
      `rotation: [0, yaw, 0]` now means yaw, see flutter_js_widget_runtime
      CHANGELOG "Unreleased".
- [ ] **fitness trainer** mini-app (new JS demo: workout card + reps counter
      + rest timer) — light theme capture; ships in `flutter_app/assets/apps/`.
- [ ] **english teacher** mini-app (new JS demo: flashcards with flip +
      progress) — light theme capture; ships as a demo too.
- [ ] homework chat frame: quadratic solve with steps + `python3` tool chip
      (dark chat golden; reuse existing chat goldens or re-capture).
- [ ] `stocks` app capture with 2–3 ticker rows + sparkline (exists; re-capture
      mid-tick for the live feel).
- [ ] providers/settings card with lock (exists: `store_providers.png`, ios).
- [ ] Fa mark SVG (exists: `flutter_app/lib/ui/widgets/fa_mark.dart`).
- [ ] Fonts: Inter + JetBrainsMono (bundled in flutter_app).
- [ ] Music: new ~120 bpm pulse bed (`MUSIC_PROMPT.md` for Suno; placeholder
      ffmpeg synth pulse allowed, beat-grid 30 f at 120 bpm).

Captures: via the app's golden infra or
`yoclip screenshot --preset app_preview_iphone67` on a small capture scene;
ALL frames portrait-first (the App Preview file is the primary).

## Compliance checklist (App Store)

- 30.0 s ≤ 30 s ✓ · 30 fps ✓ · h264 + AAC ✓ · progressive ✓ · no alpha ✓
- no URLs / pricing / "download" CTA ✓ · real UI captures only ✓ · no people ✓
- Age rating neutral (no violence/competition/real money).

## QA plan (before shipping)

1. `tools/qa_frames.sh` — 1 frame/s of every final mp4; eyeball all 30.
2. Text legibility at 50% zoom (App Preview renders small in search).
3. Compliance re-check (duration byte-exact 900 frames, no banned content).
4. Listen: music bed −18…−16 LUFS, no clipping on beat accents.
5. RU variant: no copy overflow on longer strings (RU runs ~15% longer).

