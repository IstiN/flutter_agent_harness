# Android automation — the `mobile.*` tool tiers (issue #622)

The Flutter app ships in two Android release flavors. Both expose the same
`mobile.*` tool family to the agent; what a tier can actually touch is
fixed at build time (gradle flavor + `FA_FLAVOR` dart-define, driven by
ONE CI variable) and gated at runtime through the issue #19 availability
floor (`lib/src/tools/availability.dart`) — an unavailable tool fails
with the honest reason, never a silent no-op.

Companion docs: `docs/android-readiness.md` (platform bridges),
`docs/tool-availability.md` (availability mechanics).

## 1. Tiers

| Tier | applicationId | Distribution | mobile.* surface | Powers |
|---|---|---|---|---|
| store | `dev.fa1.app` | Google Play (the existing AAB pipeline) | `mobile.launch`, `mobile.logs` | Own-app automation: deep links + launcher intents into Fa itself; app-side log access |
| god | `dev.fa1.app.god` | Sideload only (GitHub release APK / [fa1.dev/android](https://fa1.dev/android)) — NEVER Play | + `mobile.hierarchy`, `mobile.tap`, `mobile.swipe`, `mobile.text`, `mobile.screenshot` | Screen automation of any app: AccessibilityService reads the node tree and injects gestures; MediaProjection captures screenshots |
| god+shizuku | `dev.fa1.app.god` (the SAME APK) | Same sideload APK — the bridge is opt-in at runtime | + `mobile.shell` | Privileged shell via the Shizuku bridge (ADB-level commands) |

There is no third artifact: god+shizuku is the god APK with the Shizuku
bridge enabled in Settings. Without Shizuku running, `mobile.shell` fails
with the named error `Shizuku not running` — the tool never half-works.

## 2. Build identity

```bash
flutter build apk --release --flavor store --dart-define=FA_FLAVOR=store
flutter build apk --release --flavor god  --dart-define=FA_FLAVOR=god
```

- The gradle flavor and the `FA_FLAVOR` dart-define MUST come from one
  variable — in CI that is the job-level `FLAVOR` env
  (`--flavor "$FLAVOR" --dart-define=FA_FLAVOR="$FLAVOR"`), so the pair
  cannot drift.
- Both flavors sign with the SAME release key (the `ANDROID_*` CI
  secrets); only the applicationId differs, so store and god sit side by
  side on one device and each upgrades in place, never colliding.
- CI shape (`.github/workflows/build-mobile.yml`): the Play AAB job is
  unchanged (store only); a `store|god` matrix builds both APKs and
  attaches them to the GitHub release; the store APK size delta vs the
  previous release is reported in the job summary (UT-CI-1, +10% fail
  threshold); the emulator IT job is present but disabled (`if: false`)
  until an emulator runner is provisioned — it pins the shape for the six
  channel ITs (IT-flavor-1, IT-floor-1, IT-observe-1, IT-gesture-1,
  IT-shell-1, IT-consent-1) in
  `flutter_app/test/integration/mobile_channel_it.dart` (tagged
  `integration`).

## 3. What each tool does

| Tool | Min tier | What it does |
|---|---|---|
| `mobile.launch` | store | Deep-link / launcher-intent automation of Fa itself (open a screen, fire an app link). |
| `mobile.logs` | store | App-side log access — the agent reads its own diagnostics. |
| `mobile.hierarchy` | god | Returns the accessibility node tree of the foreground app (extracted text is redacted — §7). |
| `mobile.tap` | god | Injects a tap on a node / at coordinates via the AccessibilityService. |
| `mobile.swipe` | god | Injects swipe gestures (scrolls, back-from-edge, notification shade). |
| `mobile.text` | god | Injects text into a focused node (field entry, search boxes). |
| `mobile.screenshot` | god | Captures the screen via MediaProjection (projection consent — §6). |
| `mobile.shell` | god+shizuku | Runs a shell command through Shizuku (ADB-level privileges); rides the exec approval tier + critical-pattern interceptor. |

Availability floor: a tier without a tool reports it as unavailable with
the gated reason `requires the god tier (sideload build) — get it at
https://fa1.dev/android` (issue #19 machinery,
`lib/src/tools/availability.dart`).

## 4. Install the god build (sideload)

1. Download `app-god-release.apk` from
   [fa1.dev/android](https://fa1.dev/android) or this repo's GitHub
   Releases page.
2. Install it: `adb install app-god-release.apk`, or open the downloaded
   APK on-device and confirm the sideload prompt.
3. Updates install over the top (same applicationId `dev.fa1.app.god`,
   same key). Store and god coexist; they never upgrade each other.

Why god is not on Play: its powers — AccessibilityService automation of
OTHER apps, MediaProjection capture, an optional privileged shell — are
exactly the surface Play policy restricts hardest for automation apps.
god is deliberately outside the Play supply chain: CI never uploads it,
the Play job builds the store AAB only. Trust anchor: the same release
key as store — install god only from fa1.dev/android or this repo's
Releases.

## 5. Enable Shizuku (`mobile.shell`)

1. Install [Shizuku](https://shizuku.rikka.app/) and start it either way:
   - **Android 11+:** Developer options → Wireless debugging → pair
     Shizuku on-device (Pair device with pairing code), then tap Start
     in Shizuku.
   - **From a computer:** `adb shell sh /storage/emulated/0/Android/data/moe.shizuku.privileged.api/start.sh`
     (short form `sh start.sh` once you are in that directory via
     `adb shell`).
2. In Fa: Settings → Shizuku bridge → enable. The bridge probes the
   running Shizuku service before flipping on.
3. If Shizuku is absent or not started (including after a reboot),
   `mobile.shell` fails with the named error `Shizuku not running` —
   nothing falls back to an unrestricted path.

## 6. Consent and the kill switch

- The consent screen gates AccessibilityService activation: before the
  system hand-off, Fa shows WHAT will be enabled and why. No consent, no
  service (IT-consent-1).
- One-tap disable in Fa Settings: revokes the bridge state and walks the
  system Settings path to switch the accessibility service off.
- MediaProjection consent is per-session by Android design: after a
  reboot the projection grant is gone and the app MUST re-prompt
  (IT-loop-2: enable screenshots, reboot, invoke `mobile.screenshot` →
  the consent dialog appears again; a silent re-acquire is a bug).

## 7. Security notes (binding threat model)

- god is sideload-only: CI never uploads it to Play, and the distinct
  applicationId (`dev.fa1.app.god`) keeps the store listing and the
  sideload build permanently separate.
- Screen text extracted by `mobile.hierarchy` (and returned by
  `mobile.text`) passes the same redaction pipeline as logs before it
  reaches the model — secret-shaped strings do not leave the device in
  plaintext.
- `mobile.shell` rides the exec approval tier: every invocation asks
  unless the session granted exec, and the critical-pattern interceptor
  (recursive root deletes, mkfs, fork bombs, ...) denies even in yolo.
- Accessibility and projection activate only behind the consent screen;
  both are killable with one tap from Settings.
- Same release key as store: a god APK verifies against the owner key —
  anything not signed by it is not this project's build.

## 8. E2E manual checklist

Run on a device or emulator with the god build installed.

- [ ] **AC2 — observe + act on Settings:** `mobile.launch` opens the
      system Settings; `mobile.hierarchy` returns the node tree;
      `mobile.tap` on a toggling node flips the state; `mobile.swipe`
      pulls the notification shade; `mobile.screenshot` returns an
      image.
- [ ] **IT-loop-2 — projection re-consent:** with screenshots working,
      reboot the device, invoke `mobile.screenshot` → the
      MediaProjection consent dialog re-appears (never a silent grant).
- [ ] **AC5 — Shizuku absent:** without Shizuku installed/running,
      `mobile.shell` fails with exactly `Shizuku not running`, and the
      other god tools keep working.
