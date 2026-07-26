# JS bridge to system APIs (Scriptable-like) — design

How `jsr.fa.*` works today, the target API shape, and the checklist for
adding new system domains. Code references are from `flutter_app/` unless
noted.

## 1. Current bridge surface and permission gating

### Transport

`jsr.fa.*` rides on `jsr.exec`: the host bootstrap JS
(`lib/apps/js_app_engine.dart:192`, `_faBootstrapJs`) wraps every fa call as
`jsr.exec(JSON.stringify({fa: '<method>', args: {...}}))`. `_exec` sniffs the
leading `{`, decodes the envelope, and dispatches to `_faCall`; anything else
is treated as a shell command. So a fa call costs one exec round-trip and
reuses the exec Promise machinery.

### Surface (today)

- `jsr.fa.call(method, args)` — generic dispatcher.
- `jsr.fa.llm(prompt)` → string. Real; needs a connected `llmHandler`,
  otherwise "LLM is not connected".
- `jsr.fa.calendar(args)` → `{events: [...]}` (maps to `calendar.events`
  internally); `.create` / `.update` / `.delete` write (recurrence, alarms,
  calendar, span, url supported). Real backend via `CalendarApi`.
- `jsr.fa.homekit(action, args)`, `jsr.fa.health(action, args)`,
  `jsr.fa.contacts(action, args)` — dispatch to the injectable
  `FaPlatformHandler` (`js_app_engine.dart:21`). When no handler is wired the
  call resolves to `'... bridge is not available on this platform yet'` — a
  granted stub, not a working API.

### Permission model (already in place — reuse as-is)

- Declared in `manifest.json` (`network`, `allowedCommands`, `llm`,
  `homekit`, `health`, `contacts`, `calendar`) — all default **denied**
  (`AppPermissions.fromJson`, `lib/apps/apps_store.dart:27`).
- Runtime override per app, persisted in `apps_permissions.json`
  (`AppPermissionsStore`, `apps_store.dart:167`); effective value =
  override ?? declared (`EffectiveAppPermissions`).
- Enforcement is **host-side in the handlers**, not in the bootstrap:
  `isPermissionAllowed` returns true and every handler checks its own flag,
  so the JS side gets an actionable error ("calendar permission is disabled
  for X") instead of a generic rejection (`js_app_engine.dart:144`).
- OS-level consent is a second, independent gate: `_calendarEvents` calls
  `api.requestAccess()` after the app-level check (`js_app_engine.dart:283`).
- The `calendar` demo app + `calendar_events` agent tool both point the user
  at the system privacy settings on denial.

## 2. Target API design (Scriptable-like)

### Naming

`jsr.fa.<domain>.<method>(args) → Promise<result>`.

- Domain = noun (`calendar`, `contacts`, `health`, `home`, `mic`, `tts`),
  method = verb (`events`, `create`, `stepsToday`, `record`, `speak`).
- The bootstrap gains per-domain namespaces; `jsr.fa.call` stays as the
  escape hatch so new methods work before bootstrap sugar ships.
- One method = one envelope string `'<domain>.<method>'` — the existing
  `homekit.<action>` convention already proves this scales.

### Error contract

- Transport errors use the existing `__error` envelope: host resolves
  `{__error: 'message'}` and the runtime bootstrap rejects the Promise
  (`js_widget_runtime/lib/src/runtime/js_widget_bootstrap.dart:50` —
  `if (r && r.__error) reject(new Error(r.__error))`). JS callers see a
  normal `try/catch` / `.catch`.
- **Keep `__error` for all failure kinds** (denied permission, unavailable
  platform, bad args, native failure) — one rejection path, message
  distinguishes. No partial-result + error hybrid.
- Expected "empty" outcomes (no events, no contacts match) are successes
  with empty payloads, not errors. Unavailable platform and denied
  permission are errors with distinct, greppable message prefixes
  (`... permission is disabled for ...`, `... is not available on this
  platform`).

### Sync vs async

Everything is async (Promise) — there is no sync path over the exec
round-trip, and none should be added. Cheap getters that feel sync
(`tts.isSpeaking`, `mic.level`) are exposed as async snapshot methods; live
updates are out of scope for the bridge (apps re-render on `jsr.onEvent`,
not on streams).

### Payload conventions

- Timestamps: **milliseconds since epoch**, `*Ms` suffix (`startMs`,
  `endMs`) — matches the calendar channel end to end
  (`calendar_service_io.dart:49`, `AppDelegate.swift:172`).
- Dates for day-level queries: `YYYY-MM-DD` local (`calendarRange`,
  `calendar_service.dart:42`).
- Colors: `#RRGGBB` / `#AARRGGBB` hex strings (matches `jsr.theme`).
- Optionals: omit the key entirely, never `null` placeholders (calendar
  event serialization, `js_app_engine.dart:303`).
- Numbers across the channel arrive as `num`; coerce with
  `(x as num?)?.toInt()` at the Dart boundary.
- Keep payloads JSON-only (no binary); media leaves the bridge as env file
  paths the app reads via `jsr.loadAsset`-style calls.

## 3. Channel pattern for a new domain (checklist)

Calendar is the reference implementation. For each new domain
(`calendar.write`, `contacts`, `health`, `home`, `mic`, `tts`):

1. **Interface** — `lib/services/<domain>_service.dart`: abstract
   `<Domain>Api` (record typedefs for payloads), plus
   `export '<domain>_service_stub.dart' if (dart.library.io)
   '<domain>_service_io.dart'` (pattern: `calendar_service.dart:5`). Methods:
   `isAvailable`, `requestAccess()`, then domain verbs.
2. **Stub** — `<domain>_service_stub.dart`: never-available fake for web;
   clean "not supported", never a crash (`calendar_service_stub.dart`).
3. **IO impl** — `<domain>_service_io.dart`: `MethodChannel('fah/<domain>')`,
   `<domain>PlatformSupported` getter, `MissingPluginException` →
   unavailable/empty (`calendar_service_io.dart:21`).
4. **Native (Swift)** — channel handler in `ios/Runner/AppDelegate.swift`
   and `macos/Runner/MainFlutterWindow.swift` (pattern: `fah/calendar`,
   `AppDelegate.swift:115`); add the entitlement to the `.entitlements`
   files and both `NS<Domain>UsageDescription` plist keys.
5. **Permission flag** — add the field to `AppPermissions` (json, copyWith,
   effective()) in `lib/apps/apps_store.dart`; default false.
6. **jsr exposure** — host branch in `JsAppEngine._faCall`
   (`js_app_engine.dart:244`): check the flag, call the service, serialize
   with the payload conventions above; add bootstrap sugar in
   `_faBootstrapJs`.
7. **Agent tool** — `lib/services/<domain>_tool.dart` (pattern:
   `calendar_tool.dart`), registered in `agent_service.dart` behind
   `<domain>PlatformSupported`; correct `ApprovalTier` (read vs write).
8. **Skill docs + demos** — update `assets/skills/js-apps/SKILL.md` bridge
   reference; demo app in `assets/apps/<id>/` + id in
   `AppsStore.demoAppIds`.
9. **Tests** — fake `<Domain>Api` for engine + tool tests (pattern:
   `test/calendar_tool_test.dart`, `test/apps/js_app_engine_test.dart`).
10. **l10n** — UI copy in both `app_en.arb` and `app_ru.arb` + `flutter
    gen-l10n`.

### Android-readiness note

The pattern is Android-ready by construction: data contracts
(`<Domain>Api` records + JSON payload conventions) are platform-neutral, and
the conditional io/stub import admits a Kotlin channel behind the same
`fah/<domain>` name without touching Dart call sites or JS apps. Per-domain
Android TODO (Kotlin handler in `MainActivity.kt`, manifest permissions):

- **calendar write** — Calendar Provider (`READ/WRITE_CALENDAR`).
- **contacts** — Contacts Provider (`READ_CONTACTS`; write = separate
  permission).
- **health** — Health Connect (`health.permission.READ_*`; Play
  declaration).
- **home** — Google Home / Matter commissioning APIs (much weaker than
  HomeKit; scope expectations accordingly).
- **mic** — `RECORD_AUDIO` + `MediaRecorder`/`AudioRecord`.
- **TTS** — `android.speech.tts.TextToSpeech` (no permission needed).

## 4. Gap table: exists vs stub vs missing

| Domain | jsr.fa call | App perm flag | Backend | Agent tool | Status |
|---|---|---|---|---|---|
| LLM completion | `jsr.fa.llm` | `llm` | `llmHandler` (host LLM) | n/a (the host *is* the agent) | works |
| Calendar read | `jsr.fa.calendar` | `calendar` | EventKit via `fah/calendar` (macOS/iOS) | `calendar_events` | works |
| Calendar write | — | — | — | — | missing (same channel, add `create/delete`) |
| HomeKit | `jsr.fa.homekit.*` | `homekit` | stub (`platformHandler` unwired) | — | stub |
| Health | `jsr.fa.health.*` | `health` | stub | — | stub |
| Contacts | `jsr.fa.contacts.*` | `contacts` | stub | — | stub |
| Home (rename) | — | — | — | — | design: rename `homekit` → `home` domain before shipping, keep flag name |
| Mic / audio record | — | — | — | — | missing |
| TTS | — | — | — | — | missing (could start Dart-only via `flutter_tts`, no Swift channel) |
| Network | `jsr.fetchJson` | `network` | `http` package | `web_fetch`/`web_search` (core) | works |
| Shell exec | `jsr.exec` | `allowedCommands` | `ExecutionEnv.exec` | core `bash` | works |

Platform matrix: macOS/iOS = calendar only; Android = nothing yet (channels
missing, Dart sides ready); web = nothing (stubs report unavailable).
