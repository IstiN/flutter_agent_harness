# Android readiness of platform bridges — architecture audit

Status: audited against `flutter_app/` at HEAD. Nothing below changes Dart,
JS, or manifest code — this is the work list for when Android ships.

Companion doc: `docs/js-system-apis.md` (channel checklist §3, gap table §4).

## 1. The interface + conditional-import contract (already Android-shaped)

Every system domain follows the calendar/contacts pattern, three files per
domain under `flutter_app/lib/services/`:

- `<domain>_service.dart` — abstract `<Domain>Api` interface + record
  typedefs for payloads, and a conditional export
  (`calendar_service.dart:5`):
  `export '..._stub.dart' if (dart.library.io) '..._io.dart';`
- `<domain>_service_stub.dart` — web fallback: `<domain>PlatformSupported`
  is `false`, reads return empty, writes throw a plain `StateError`
  (`calendar_service_stub.dart:10`). Never a crash.
- `<domain>_service_io.dart` — `MethodChannel('fah/<domain>')`
  (`calendar_service_io.dart:23`, `contact_service_io.dart:23`),
  `MissingPluginException` → denied/empty, plus the single platform gate:
  `bool get calendarPlatformSupported => Platform.isMacOS || Platform.isIOS;`
  (`calendar_service_io.dart:14`, `contact_service_io.dart:14`).

**This is the ONLY Dart change Android requires per domain**: extend the
gate to `|| Platform.isAndroid` and implement the same channel name in
Kotlin. Call sites — `jsr.fa.*` dispatch in `lib/apps/js_app_engine.dart:348`
(`_faCall`), the agent tools (`calendar_tool.dart`), the demo apps — are
channel-name- and payload-shape-agnostic and need zero edits.

Enforcement layers (unchanged on Android):

1. App permission flag (`AppPermissions`, `lib/apps/apps_store.dart:27`) —
   default denied, per-app override in `apps_permissions.json`.
2. Host-side check in `JsAppEngine._faCall` — denied flag throws
   `_denied(prefix)` (`js_app_engine.dart:445-452`); granted call reaches the
   service.
3. OS consent via `api.requestAccess()` before data access — on Android this
   maps to a runtime permission request from Kotlin, resolved back over the
   channel (the Swift precedent: `requestCalendarAccess`,
   `ios/Runner/AppDelegate.swift:151`).
4. `FaPlatformHandler` (`js_app_engine.dart:32`) remains the escape hatch for
   not-yet-native domains ("... bridge is not available on this platform
   yet").

## 2. Per-domain Android mapping

| Domain (channel) | iOS/macOS backend | Android backend | Manifest / runtime permission | pub.dev candidate (verified 200) | Notes |
|---|---|---|---|---|---|
| calendar (`fah/calendar`) | EventKit (`AppDelegate.swift:118`, `MainFlutterWindow.swift:111`) | Calendar Provider (`CalendarContract.Events/Calendars`, ContentResolver) | `READ_CALENDAR` + `WRITE_CALENDAR` (runtime, dangerous) | `device_calendar` | Prefer own Kotlin handler for parity; plugin covers read+write but pins its own schema. Payload `*Ms` conventions already match. |
| contacts (`fah/contacts`) | Contacts.framework (`AppDelegate.swift:350`) | Contacts Provider (`ContactsContract`) | `READ_CONTACTS`; writes need `WRITE_CONTACTS` (separate runtime grant) | `flutter_contacts` | `openUrl(tel:/sms:)` maps to `Intent.ACTION_DIAL` / `ACTION_SENDTO` — no permission for DIAL. |
| health | HealthKit (stub, unwired) | Health Connect (`androidx.health.connect:connect-client`) | `android.permission.health.READ_STEPS` etc. (manifest + Play Console declaration; user grants in Health Connect app) | `health_connect` (specialized), `health` (mature, HC support since v11) | Health Connect is preinstalled only on Android 14+; on 13- it is a Play Store app — `isAvailable` must probe package availability. |
| home (`homekit` → `home`) | HomeKit (stub) | Google Home APIs / Matter commissioning | none (play-services `com.google.android.gms:play-services-home`) | `google_home` — **does not exist (404)** | No public plugin. Realistic v1: commissioning + basic device control via Play Services Home API (requires Google Developer access). Scope expectations well below HomeKit; keep the `FaPlatformHandler` stub path. |
| mic | AVFoundation (missing everywhere) | `MediaRecorder` / `AudioRecord` | `RECORD_AUDIO` (runtime) | `speech_to_text` (dictation), `record` (raw audio) | Distinguish two verbs: `mic.record` (file → env path per payload rules) vs `mic.listen` (STT). |
| TTS | AVSpeechSynthesizer (missing) | `android.speech.tts.TextToSpeech` | none | `flutter_tts` | Could land Dart-only (plugin, no own channel) — already flagged in `js-system-apis.md:166`. |
| notifications | UNUserNotificationCenter (missing) | `NotificationManager` + channels | `POST_NOTIFICATIONS` (runtime, Android 13/API 33+) | `flutter_local_notifications` | Android requires a notification channel id at creation; fold into payload (`channelId`/`channelName`). |
| keychain (`fah/keychain`) | Keychain (`AppDelegate.swift:100`, `keychain_store.dart`) | `EncryptedSharedPreferences` / Android Keystore | none | `flutter_secure_storage` | The `fah/keychain` channel (`fah/keychain` service `fa.app`) must get a Kotlin twin — it backs `SessionKeysScope` and provider keys on mobile. |

## 3. The 10-step checklist, Android edition

Steps 1–3, 5–10 of `docs/js-system-apis.md` §3 are platform-neutral and stay
verbatim. What changes:

- **Step 3 (IO impl)** — the platform gate becomes
  `Platform.isMacOS || Platform.isIOS || Platform.isAndroid` in
  `<domain>_service_io.dart`. Nothing else in Dart moves.
- **Step 4 splits into two native halves**:
  - 4a (existing): Swift handler in `ios/Runner/AppDelegate.swift` +
    `macos/Runner/MainFlutterWindow.swift`, entitlements, `NS*UsageDescription`.
  - 4b (new): Kotlin handler in
    `flutter_app/android/app/src/main/kotlin/dev/fa1/android/MainActivity.kt`
    (currently a 5-line `FlutterActivity` stub) — one
    `register<Domain>Channel(flutterEngine.dartExecutor.binaryMessenger)`
    per domain, mirroring `registerCalendarChannel`
    (`AppDelegate.swift:118`). Permissions go in
    `flutter_app/android/app/src/main/AndroidManifest.xml` (currently has
    **zero** `<uses-permission>` entries) and are requested at runtime from
    the Activity behind the channel's `requestAccess` method.
- **Sandbox note**: on Android the app sandbox still allows the contacts/
  calendar ContentProviders with permission, but background execution limits
  apply — long operations (bulk contact export, health sync) must run on the
  Kotlin side's IO dispatcher and return over the channel, never on the main
  thread (the Swift handlers already hop `DispatchQueue.main.async` for
  results; Kotlin must do the inverse for queries).
- **Plugin-backed domains (TTS, notifications, speech_to_text)** skip step
  4b entirely: the plugin registers its own channels; the Dart `_io.dart`
  wraps the plugin API instead of a raw `MethodChannel` — same interface,
  same gating contract.
- **Testing (step 9) adds one Android-specific case**: `MissingPluginException`
  on Android = channel not yet implemented → must degrade to
  unavailable/empty exactly like the web stub (the existing `on
  MissingPluginException` handlers in `*_service_io.dart` already do this —
  keep them when widening the gate).

## 4. Kotlin channel template sketch

Target: `android/app/src/main/kotlin/dev/fa1/android/MainActivity.kt`.
Mirrors the Swift `registerCalendarChannel` shape 1:1 so both platforms
answer the identical method set and payload keys (`startMs`, `endMs`, …).

```kotlin
package dev.fa1.android

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    registerCalendarChannel(flutterEngine)
    // registerContactsChannel(flutterEngine) … one per domain, as they land
  }

  /// Twin of `registerCalendarChannel` in ios/Runner/AppDelegate.swift:
  /// same channel name `fah/calendar`, same methods, same payload keys.
  private fun registerCalendarChannel(flutterEngine: FlutterEngine) {
    MethodChannel(
      flutterEngine.dartExecutor.binaryMessenger,
      "fah/calendar",
    ).setMethodCallHandler { call, result ->
      when (call.method) {
        "isAvailable" -> result.success(true)
        "requestAccess" -> requestCalendarPermission(result) // ActivityResult
        "events" -> {
          val startMs = call.argument<Number>("startMs")?.toLong() ?: 0L
          val endMs = call.argument<Number>("endMs")?.toLong() ?: 0L
          // Query CalendarContract on Dispatchers.IO, then:
          // result.success(listOfEventMaps) — maps keyed like Swift:
          // id/title/startMs/endMs/allDay/calendar/location/notes
        }
        "createEvent" -> result.success(calendarCreateEvent(call.arguments))
        "updateEvent" -> result.success(calendarUpdateEvent(call.arguments))
        "deleteEvent" -> result.success(calendarDeleteEvent(call.arguments))
        else -> result.notImplemented()
      }
    }
  }
}
```

Rules carried over from the Swift side:

- Long-lived provider/store clients are top-level `private val`s (precedent:
  `calendarEventStore`, `AppDelegate.swift:112`).
- Denied permission → empty list / `false`, never an exception across the
  channel; `requestAccess` returns the stored decision without re-prompting.
- Unknown method → `result.notImplemented()`, which surfaces on Dart as the
  already-handled `MissingPluginException` path.
