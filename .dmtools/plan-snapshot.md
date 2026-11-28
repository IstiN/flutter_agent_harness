# gh-2479 plan — context-window settings UI in flutter_app

Goal: per-model context-window display + source-layer provenance + override
control in the app's provider/model settings; global `agent.contextWindowCap`
control in the agent settings section; same config keys as the CLI (single
source of truth); live consistency; parity + registry green; goldens.

## Tasks

- [x] T1 SDK: expose the window source layer on `EffectiveCaps` —
  `ContextWindowSource` enum (override/roleSlot/endpoint/remoteCatalog/spec/
  unknownDefault), `contextWindowSource` + `contextWindowUncapped` fields
  computed inside `_resolveCapabilityWindowLayer` (single source of the
  precedence contract). Additive; CLI rendering unchanged.
  verify: `dart test test/model_roles/` green (new cases: each layer wins;
  cap applied last keeps the chain source; override beats endpoint).

- [x] T2 SDK: make `Agent.contextWindowCap` a late-wirable host knob
  (setter, doc update) so the app can re-cap live; the loop config rebuild
  picks it up per run. CLI unaffected.
  verify: `dart test test/agent/` green; new test — setter lands in the
  next loop config.

- [x] T3 App services: `flutter_app/lib/services/context_window_config.dart`
  (+ `_io`/`_stub` conditional import, compaction_engine_loader pattern):
  - resolve cap + source layer (project < user < none) via
    `loadProjectContextWindowCap`/`loadCliConfig` + `resolveContextWindowCap`;
  - write/clear cap (set via `ConfigService.set('agent.contextWindowCap')`,
    clear via `removeYamlPath` + `validateAgentSection` — the CLI's
    settings_flow_context_cap semantics, user scope);
  - read/write the per-model window override
    (`models.overrides.<provider>.<model>.contextWindow`, USER scope — the
    CLI's `_writeCapabilityField` scope) validated with `ModelsConfig.fromYaml`;
  - load the whole `models.overrides` layer (for the process-wide install).
  verify: `flutter_app/test/context_window_config_test.dart` — round-trip on
  temp dirs: set → persisted → read back; clear → absent; cap min-value
  validation refused; unrelated config bytes survive.

- [x] T4 App service: window chain + live apply in `AgentService` —
  - boot: install `modelCapabilityOverrides` from the user config
    (`models.overrides`) so roles-chain models resolve overrides too;
  - resolve the active model's window through the chain
    (override > endpoint/stored > catalog > fallback) with the cap applied
    LAST (`effectiveContextWindow`), at boot and in `reconfigure`;
  - expose the effective window + provenance for the UI;
  - `applyContextWindowCap` / `applyModelWindowOverride` live-apply seams
    (cap → `_contextWindowCap` + `agent.contextWindowCap` + notify;
    override → reinstall layer + rebuild the active model when identity
    matches).
  verify: `flutter_app/test/agent_service_context_window_test.dart` —
  override round-trip (set → resolver uses it → provenance "override"),
  clear restores chain value, cap clamps after the chain (aiin-shaped
  scenario: endpoint 1M + 200k override → 200k; cap 100k → 100k).

- [ ] T5 UI: `ModelContextWindowSection` (new widget file under
  `flutter_app/lib/ui/screens/`): effective window + source layer caption
  ("override: 128,000" / "endpoint: 1,048,576" …), cap note when clamped,
  override TextFormField (empty = inherit), presets row, Save/Clear;
  embedded into `ModelsSettingsPage` after the default-chat-model section.
  verify: `flutter_app/test/model_context_window_section_test.dart` widget
  tests (display, edit→save persists via injected seams, clear restores).

- [ ] T6 UI: `ContextWindowCapSection` (new widget file, CompactionSection
  shape: resolve seam + write seam + source caption + web-unsupported
  note + semantics helper text) wired into the Agent Config category.
  settings.dart sits at the 280-line god-file ceiling → move
  `_noServiceHint` (or an equivalent private method) into the
  `settings_flows.dart` part first to free budget; keep ≤ 280.
  verify: `flutter_app/test/context_window_cap_section_test.dart` +
  `flutter analyze` + line-count check on settings.dart.

- [ ] T7 l10n: en/ru ARB entries for every new user-facing string;
  `flutter gen-l10n` regenerates the committed localizations.
  verify: `flutter_app/test/l10n_guard_test.dart` green.

- [ ] T8 Parity: remove `contextWindowCap` from `cliOnlySettings`, drop its
  gap-justification entries, set `appRef` to the new app surface, flip
  `settingSurfaces` for supported hosts; yamlKeys unchanged (`agent:`).
  verify: `dart test test/parity/` green.

- [ ] T9 Goldens: coverage entries in `golden_guard_test.dart` for the two
  new widget files; golden tests in `test/goldens/` (real fonts via
  `ensureGoldenFonts`, 1280x800 + 390x844 frames, deterministic fakes);
  `flutter test test/goldens --update-goldens` then eyes on PNGs;
  `scripts/check_goldens.py` clean.
  verify: `flutter test test/goldens` green.

- [ ] T10 Gates: repo `dart test` (deterministic suite), app
  `flutter test`, `dart analyze` + format on touched files; CLI behavior
  unchanged (shared keys — the CLI flow tests stay green untouched).
  verify: commands green in repo root and flutter_app/.

## Decisions

- Provenance is computed by the SDK resolver (T1), not re-derived in the
  app — one precedence implementation, both hosts display from it.
- Override writes land in the USER config (the CLI's model-caps flow scope);
  the cap writes land in the layer that currently wins (CompactionSection
  rule: explicit choice edited in place, else project when a session dir
  exists, else user).
- Live consistency: cap applies live through the new mutable knob (T2) +
  the service field (compaction wiring reads it live); overrides reinstall
  the process-wide layer + rebuild the active model. No "restart required"
  note needed for compaction/window math; the loop guard picks the cap up
  per-run from the rebuilt config.
- The "remote catalog" layer exists in the enum but the app has no catalog
  fetch in-process; the aiin 1M case surfaces through the endpoint layer
  (the `/models` report) — the UI labels it honestly.

## Open questions

- None blocking. The golden-frame sections reuse the settings goldens'
  fakes; check_goldens.py orphan gate enforces registration (T9).
