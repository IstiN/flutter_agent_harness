# Fa — AI Agent · Hero Promo · Creative Treatment

## Concept

**"A dashboard that is truly yours."** The promo sells the one thing no other
AI app does: Fa doesn't just chat — it *builds your home screen*. The video is
a single continuous shot of a floating phone on a dark premium stage; the
screen inside morphs through five real product frames while short kinetic
lines land each beat. It ends on the Fa mark.

The phone never leaves the frame until the end card — continuity reads as
confidence. Every screen shown is a real shipping UI (the committed App Store
goldens), not a mock.

## Hook (first 2 seconds)

The money shot first: the **Apps dashboard with live widgets** (weather,
reminders, app tiles) rotates in from a 3D tilt and settles while the line
"A dashboard that is truly yours" rises underneath. No logo intro, no
throat-clearing — product in frame 1.

## Storyboard (19 s @ 30 fps = 570 frames, one cut, three aspects)

| Beat | Frames | Seconds | Screen (real golden) | Kinetic line EN | Kinetic line RU |
|------|--------|---------|----------------------|-----------------|-----------------|
| 1 · Hook | 0–84 | 0.0–2.8 | Apps dashboard (live widgets) | A dashboard that is truly yours. | Дашборд, который по-настоящему ваш. |
| 2 · Builder | 84–180 | 2.8–6.0 | Chat: "Build me a weather app" + tool calls | Your own apps, built by chat. | Свои приложения — прямо из чата. |
| 3 · Inside | 180–276 | 6.0–9.2 | In-app chat (weekly forecast tweak) | Fa lives inside every app. | Fa живёт внутри каждого приложения. |
| 4 · Media | 276–372 | 9.2–12.4 | Generated image + voice summary | It draws, speaks and plays. | Рисует, говорит и играет. |
| 5 · Trust | 372–456 | 12.4–15.2 | Providers / Keychain settings | Any provider — keys stay in the Keychain. | Любой провайдер — ключи в Keychain. |
| 6 · End card | 444–570 | 14.8–19.0 | Fa mark + wordmark | Fa — AI Agent · on your hardware, under your rules | Fa — AI-агент · на вашем железе, по вашим правилам |

Transitions: 12-frame crossfades of the screen content *inside* the phone
(the phone body persists), headline swap with rise/fade stagger. The end card
crossfades the phone out and pops the icon with an `eoBack` overshoot.

Apple App Preview compliance: no URLs, no pricing, no "download" CTA, 19 s ≤
30 s, 30 fps, h264 + AAC, progressive, no alpha.

## Motion & look

- Palette: bg `#070A10`, surface `#0E1420`, indigo `#818CF8`, teal `#2DD4BF`,
  text `#F4F6FB`, muted `#8A93A8`.
- Stage: two large blurred color orbs (indigo top-left, teal bottom-right)
  drifting on slow sine paths + a soft radial vignette. Nothing static.
- Phone: rounded frame (radius ~7% of width), 2 px `#26304A` border, wide
  indigo glow shadow; entrance `rotateY −22° → −5°`, `rotateX 7° → 2°`,
  then a 2 px sine float so it breathes.
- Type: Geneva 700 for headlines, accent keyword painted with an
  indigo→teal text gradient; small letter-spaced kicker label above.
- Easing: `eo3` for settles, `eoBack` for pops, everything clamped 0..1.

## Voiceover scripts

### EN (target ≈ 17 s, warm confident female)
> A dashboard that is truly yours.
> Your own apps, built by chat.
> Fa lives inside every app you create.
> It draws, speaks and plays.
> Any provider — your keys never leave the Keychain.
> Fa — AI Agent.

### RU (target ≈ 17 s)
> Дашборд, который по-настоящему ваш.
> Свои приложения — созданные в чате.
> Fa живёт внутри каждого приложения.
> Он рисует, говорит и играет.
> Любой провайдер — ключи остаются в Keychain.
> Fa — ваш AI-агент.

**TTS route — quality gap note.** No hosted TTS key is available in the
environment (`OPENAI_API_KEY` & friends unset; the repo `.env` is empty), so
the voiceovers are rendered with macOS `say` — Samantha (en_US) and Milena
(ru_RU), at 175 wpm with light post EQ. These are intelligible but noticeably
"system voice". **Marked placeholder:** to upgrade, re-render
`assets/voiceover/{en,ru}_XX.m4a` with OpenAI `tts-1-hd` (voice `nova` /
`shimmer`) or ElevenLabs at the same file names and segment offsets (see
`tools/build_audio.sh`), then re-run the mux step — no re-render of video
needed.

## Music & SFX direction

- **Bed:** royalty-safe synth pad composed with ffmpeg only (no samples):
  slow A-minor pad (A2/E3/A3/C4 detuned sines through a lowpass), soft
  sidechain-style pump, a high shimmer partial that opens at the end card.
  19 s, −20 dB under VO, +4 dB swell at 14.8–19 s, 1.2 s fade-out.
- **SFX:** none baked — the cut is timed so screen swaps land on the pad's
  pulse. Optional polish point: add a 60 ms filtered "tick" at each beat
  boundary in `tools/build_audio.sh`.

## Deliverable matrix

| File | Aspect | Resolution | Lang | Notes |
|------|--------|-----------|------|-------|
| `out/fa_promo_app_preview_{en,ru}.mp4` | 9:19.5 | 1290×2796 | en/ru | Apple App Preview (iPhone 6.9") |
| `out/fa_promo_social_{en,ru}.mp4` | 9:16 | 1080×1920 | en/ru | Reels/TikTok/Shorts, safe margins |
| `out/fa_promo_youtube_{en,ru}.mp4` | 16:9 | 1920×1080 | en/ru | YouTube / site hero |

Portrait variants keep headline + phone inside platform-safe margins (≥ 250 px
top, ≥ 320 px bottom on social).
