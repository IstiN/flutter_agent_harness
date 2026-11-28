// The AgentCli test seams, split out of `agent_cli.dart` to keep that
// file under the repo's 2800-line size gate (gh-2472 rework: the PR's
// seam additions pushed it to 2806). Same library (a `part of`), so the
// seams stay `@visibleForTesting`-annotated library surface while every
// part file — and every barrel importer — sees them.
//
// The two captured-picker-items FIELDS (`sessionPickerItemsForTest`,
// `importHarnessItemsForTest`) stay on the class body in agent_cli.dart:
// an extension cannot declare instance fields.
part of 'agent_cli.dart';

/// The `@visibleForTesting` seam surface over [AgentCli]: test-only
/// forwarders that drive the private model/provider/session pickers,
/// builders and stores the same way the live TUI paths do.
extension AgentCliTestSeams on AgentCli {
  /// Test seam driving the TUI model-menu builder in line mode: the same
  /// `_buildModelMenu` the TUI's model picker renders. [width] is the
  /// terminal width the table lays its columns out for (80 = the headless
  /// default).
  @visibleForTesting
  List<MenuItem> buildModelMenuForTest(String filter, {int width = 80}) =>
      _buildModelMenu(filter, width);

  /// The deduped `(provider, modelId)` pair list the picker is built
  /// from. Exposed for tests so cross-provider invariants (catalog
  /// fallback chains, dedup with the saved entry's modelId) can be
  /// asserted without driving the TUI two-step picker.
  @visibleForTesting
  List<(String, String)> crossProviderCandidatesForTest([String filter = '']) =>
      _crossProviderCandidates(filter);

  /// Test seam for the TUI's model-menu selection: routes `@<provider>`
  /// (the two-step pick's provider row) and `provider|model` keys the same
  /// way the live picker does.
  @visibleForTesting
  Future<void> tuiSelectModelForTest(String key) => _tuiSelectModel(key);

  /// Test seam for the TUI provider-picker selection: routes `add`,
  /// `saved:<name>`, `ext:<name>:<id>`, and catalog keys exactly like the
  /// live picker (`_tuiPickProvider`).
  @visibleForTesting
  Future<void> tuiPickProviderForTest(String key) => _tuiPickProvider(key);

  /// Test seam for the private `/model` memory write path: records
  /// [modelId] into the active saved entry (no-op without one), the same
  /// thing a real `/model` switch does while a custom provider is active.
  @visibleForTesting
  void recordCustomModelForTest(String modelId) {
    unawaited(_recordCustomModel(modelId));
  }

  /// Test seam driving [_switchModel] with a RAW model id — no router
  /// resolution, the shape an unresolved caller would hand it. Pins the G1
  /// backstop refusal (gh-1788): a cross-provider reference that reaches
  /// the same-provider reuse path is refused loudly, state untouched.
  @visibleForTesting
  Future<void> switchModelUnresolvedForTest(String modelId) =>
      _switchModel(modelId);

  /// Test seam driving the TUI picker's Edit action in line mode: opens
  /// the prefilled edit wizard for [entry] (or the active provider when
  /// null), the same `_startProviderEditWizard` the picker calls.
  @visibleForTesting
  void startProviderEditWizardForTest(CustomProviderEntry? entry) =>
      _startProviderEditWizard(entry);

  /// The rows of the "Add provider" preset picker — the test asserts every
  /// catalog provider with a typed `/provider <name>` flow is listed
  /// (Copilot shipped missing: the list is hand-maintained).
  @visibleForTesting
  List<MenuItem> addProviderItemsForTest() => _addProviderItems();

  /// The deliberate picker exclusions (provider name → reason) — with
  /// [addProviderItemsForTest] the test asserts the catalog is exactly
  /// presets ∪ exclusions.
  @visibleForTesting
  Map<String, String> addProviderExclusionsForTest() => _addProviderExclusions;

  /// Test seam firing one heartbeat tick (issue #383) — the same path the
  /// cadence timer drives, without waiting real minutes in tests.
  @visibleForTesting
  void heartbeatTickForTest() => _subagentHeartbeat.tick();

  /// Test seam exposing the subagent registry — the heartbeat tests plant
  /// running children without driving a real spawn.
  @visibleForTesting
  SubagentManager get subagentManagerForTest => _subagentManager;

  /// The preset names with a routing handler — the test asserts
  /// presets == handlers (a preset row without a handler is a dead menu
  /// entry: the picker closes and nothing happens — the live Copilot bug).
  @visibleForTesting
  Set<String> addProviderHandlerKeysForTest() =>
      _addProviderHandlers.keys.toSet();

  /// Test seam routing an "Add provider" picker selection in line mode.
  @visibleForTesting
  Future<void> tuiPickAddProviderForTest(String key) =>
      _tuiPickAddProvider(key);

  /// Test seam: the picker-id → handler dispatch map's keys. A picker id
  /// opened by `openPicker` without an entry here is a dead menu entry
  /// (selection routes to `null?.call()` — the picker closes and nothing
  /// happens), so the dispatch test asserts the id set exactly.
  @visibleForTesting
  Set<String> pickerHandlerKeysForTest() => _tuiPickerHandlers.keys.toSet();

  /// Test seam: the settings-hub item keys that have a dispatch target
  /// (a hub row without one closes silently on Enter).
  @visibleForTesting
  Set<String> settingsPickerHandlerKeysForTest() =>
      _settingsPickerHandlers.keys.toSet();

  /// Test seam routing a wizard-picker selection through the live TUI
  /// dispatch (`_tuiPickerSelected`): completes the pending `_pickOption`
  /// answer the way a real picker row does — the settings flows'
  /// multiple-choice steps in tests (gh-1787).
  @visibleForTesting
  Future<void> tuiWizardPickForTest(String pickerId, String key) =>
      _tuiPickerSelected(pickerId, key);

  /// Test seam: opens the sessions picker (building its rows) without a
  /// TUI; the built items land in [sessionPickerItemsForTest].
  @visibleForTesting
  Future<void> openSessionsPickerForTest() => _openSessionsPicker();

  /// Test seam: builds the real slash-menu completion items for [prefix]
  /// (commands, templates, skills) without a TUI.
  @visibleForTesting
  List<MenuItem> slashMenuForTest(String prefix) => _buildSlashMenu(prefix);

  /// Test seam for the queue secret snapshot (gh-1781 review r1): the
  /// exact map the quota-feed rebind and the `/providers queue` edit
  /// reload resolve — pins the boot/rebuild parity (the rotation stack,
  /// `NAME_2`/`NAME_3` …, must ride the rebuild's env view exactly like
  /// the boot's [collectQueueSecrets] sweep saw it).
  @visibleForTesting
  Map<String, String> queueSecretsForTest(List<ProviderQueueEntry> entries) =>
      _queueSecrets(entries);

  /// Test seam routing a sessions-picker selection in line mode.
  @visibleForTesting
  Future<void> tuiPickSessionForTest(String key) => _tuiPickSession(key);

  /// Test seam: opens the /import harness picker; the items it opened with
  /// land in [importHarnessItemsForTest] (the sessionPickerItemsForTest
  /// pattern).
  @visibleForTesting
  Future<void> openImportHarnessPickerForTest() async {
    _openImportHarnessPicker();
  }

  /// Test seam: routes an import-harness-picker selection.
  @visibleForTesting
  Future<void> tuiPickImportHarnessForTest(String key) =>
      _tuiPickImportHarness(key);

  /// Test seam: builds the import-sessions picker rows for [filter]
  /// without a TUI (keyword search over title + indexed content).
  @visibleForTesting
  List<MenuItem> importSessionMenuForTest(String filter) =>
      _importSessionMenuItems(filter);

  /// Test seam: routes an import-sessions-picker selection.
  @visibleForTesting
  Future<void> tuiPickImportSessionForTest(String key) =>
      _tuiPickImportSession(key);

  /// Test seam: swaps the active session so command paths can be driven
  /// over a session shape the real repo never produces (e.g. empty
  /// metadata path — the usage-ledger command guards).
  @visibleForTesting
  set sessionForTest(Session? session) => _session = session;

  /// Test seam: the active session (null before the first drive) — the
  /// gh-1589 seal tests assert `isSealed` on it after both exit paths
  /// (headless `runHeadless`, REPL teardown).
  @visibleForTesting
  Session? get sessionForTest => _session;

  /// Test seam: swaps the session repo so CLI paths can be driven over a
  /// store shape the real repo never produces — gh-1555's incident-shape
  /// fixture refuses every FULL open (what a ledger past the gh-1073 2 GiB
  /// backstop does) so the windowed-everywhere migration is provable
  /// without a giant on-disk fixture.
  @visibleForTesting
  set repoForTest(SessionRepo repo) => _repo = repo;

  /// Session-correlation env vars injected into bash tool executions (see
  /// [SessionVarsExecutionEnv]). Read live per exec: the session is created
  /// after tool wiring, and `/provider`/`/model` switches must show up in
  /// later commands. Never secret values — ids, paths, kinds, model ids.
  /// Test seam: the session-correlation env vars a bash exec would see
  /// right now (gh-1556 wiring asserts the deadline var's live override).
  @visibleForTesting
  Future<Map<String, String>> sessionEnvVarsForTest() => _sessionEnvVars();

  /// Test seam: the live session deadline clock (gh-1556).
  @visibleForTesting
  SessionDeadline get deadlineForTest => _deadline;
}
