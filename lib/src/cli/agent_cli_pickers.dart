part of 'agent_cli.dart';

// TUI picker members of [AgentCli] — the slash-menu item builder, the
// generic picker selection/cancel routing (wizard answers, sessions,
// mode, approval, provider), and the picker openers. The picker-handler
// map and the row-state fields stay class members of `agent_cli.dart`
// (extensions cannot declare instance fields). Split out to keep that
// file under the repo's line gate. Same library (a `part of`), so the
// extension sees the class's private members with no visibility change.

extension AgentCliPickers on AgentCli {
  List<MenuItem> _buildSlashMenu(String prefix) => buildSlashMenuItems(
    prefix,
    slashCommands: builtinSlashCommands,
    pluginSlashCommands: _pluginSlashCommands,
    pluginSlashDescriptions: _pluginSlashDescriptions,
    extSlashCommands: _ext.slashCommands,
    templates: _templates,
    skills: _enabledSkills,
  );

  /// Routes a generic TUI picker selection (sessions/mode/approval) to the
  /// same handlers the typed slash command would use — CONTAINED like the
  /// composer submit boundary (gh-1787 rework): the settings hub reachable
  /// from here launches the very same flows, this future is consumed by
  /// dart_tui's `runCmd` (which prints `Caught command exception` plus the
  /// full stack to stderr), so a throwing handler renders the clean
  /// one-line error panel instead.
  Future<void> _tuiPickerSelected(String pickerId, String key) async {
    // Wizard pickers (a guided flow's multiple-choice questions) complete
    // their pending answer instead of the command handlers.
    if (_completeWizardPicker(pickerId, key)) return;
    final handler = _tuiPickerHandlers[pickerId];
    if (handler == null) return;
    await runContainedSubmit(
      () => handler(key),
      (error) => io.writeln(tuiError(submitErrorPanelLine(error))),
    );
  }

  /// Completes the pending wizard-picker answer for [pickerId] (null [key]
  /// = dismissed with Esc); returns whether a wizard was waiting.
  bool _completeWizardPicker(String pickerId, String? key) {
    final wizard = _wizardPickerAnswer;
    if (wizard == null) return false;
    return _finishWizardPicker(pickerId, key, wizard);
  }

  /// Resolves a waiting wizard picker and clears the pending answer;
  /// returns whether [pickerId] is a wizard picker.
  bool _finishWizardPicker(
    String pickerId,
    String? key,
    Completer<String?> wizard,
  ) {
    if (!pickerId.startsWith('wizard:')) return false;
    _resolveWizard(wizard, key);
    return true;
  }

  /// Completes [wizard] (defensively no-op when already completed) and
  /// clears the pending answer.
  void _resolveWizard(Completer<String?> wizard, String? key) {
    if (!wizard.isCompleted) wizard.complete(key);
    _wizardPickerAnswer = null;
  }

  /// A sessions-picker selection (issue #198): `flat`/`tree` flips the
  /// view and reopens; `r<index>` resolves through the most recent
  /// picker's row list.
  Future<void> _tuiPickSession(String key) async {
    if (key == 'flat' || key == 'tree') {
      _sessionPickerFlat = key == 'flat';
      return _openSessionsPicker();
    }
    if (!key.startsWith('r')) return;
    final rows = _lastSessionRows;
    final row = rows == null
        ? null
        : listItemAt(rows, int.tryParse(key.substring(1)) ?? -1);
    if (row == null) return;
    final metadata = row.metadata;
    try {
      // gh-1555 W1 (d1 — the incident's exact failure path): the picker
      // needs only the session NAME before the switch; open windowed so
      // a ledger past the gh-1073 full-open backstop still picks (the
      // default full open refuses outright). resolveSessionName pages
      // older chunks when the name record sits outside the resident
      // tail, matching what the old full open could see.
      final session = await _repo.open(metadata, windowed: true);
      final label = await session.resolveSessionName() ?? metadata.id;
      await _switchToMetadata(metadata, label);
    } on Object catch (error) {
      // Never let a broken session file kill the TUI through the picker's
      // Cmd — report inline instead.
      io.writeln(
        _keyStatusView.errorLine(
          'failed to open session ${metadata.id}: $error',
          _agent.state.model.baseUrl,
        ),
      );
    }
  }

  /// A provider-picker selection: `custom` starts the guided flow,
  /// `saved:<name>` opens a saved provider's edit/delete picker,
  /// `ext:<name>:<id>` runs that extension's provider flow (AC5; namespaced
  /// keys can never shadow the bare core ids), anything else is a catalog
  /// provider name.
  Future<void> _tuiPickProvider(String key) async {
    if (key == 'add') return _openAddProviderPicker();
    if (key.startsWith('saved:')) return _tuiPickSavedProviderEdit(key);
    await _tuiPickExtOrCatalog(key);
  }

  /// An `ext:<name>:<id>` key runs that extension's provider flow (AC5;
  /// namespaced keys can never shadow the bare core ids).
  Future<void> _tuiPickExtOrCatalog(String key) async {
    if (key.startsWith('ext:')) return _startExtProviderFlow(key);
    await _tuiPickCatalogOrSaved(key);
  }

  /// A `saved:<name>` selection from the provider picker opens the edit/delete
  /// sub-picker for the matching saved provider.
  Future<void> _tuiPickSavedProviderEdit(String key) async {
    final name = key.substring('saved:'.length);
    final entry = config.customProviders?.find(name);
    if (entry != null) _providerEditOrDelete(entry);
  }

  /// A non-`custom` provider-picker selection: a saved entry or a catalog
  /// provider name.
  Future<void> _tuiPickCatalogOrSaved(String key) async {
    if (key.startsWith('saved:')) {
      await _tuiPickSavedProvider(key.substring('saved:'.length));
      return;
    }
    await _handleProviderCommand(key);
  }

  /// A `saved:<name>` provider-picker selection restores the saved custom
  /// provider when it still exists.
  Future<void> _tuiPickSavedProvider(String name) async {
    final entry = config.customProviders?.find(name);
    if (entry != null) await _switchToSavedProvider(entry);
  }

  /// A generic picker dismissed with Esc: wizard pickers resolve their
  /// pending answer as cancelled (the flow then aborts cleanly).
  void _tuiPickerCancelled(String pickerId) {
    _completeWizardPicker(pickerId, null);
  }

  Future<void> _openSessionsPicker() async {
    final List<SessionMetadata> sessions;
    try {
      // List every session in the shared root, across all workspaces, so a
      // session created in the Fa app or in another `fa` run is reachable.
      // The current folder's sessions lead the list (issue #83).
      sessions = sortSessionsCurrentFolderFirst(await _repo.list(), _env.cwd);
    } on Object catch (error) {
      // A failing store must surface as an inline error, never kill the TUI
      // (a Cmd exception in dart_tui terminates the whole program silently).
      io.writeln(
        _keyStatusView.errorLine(
          'failed to list sessions: $error',
          _agent.state.model.baseUrl,
        ),
      );
      return;
    }
    _lastSessionRows = await _sessionPickerRows(sessions);
    _tuiController?.openPicker(
      'sessions',
      'Sessions',
      // The view toggle rides the first item (issue #198 open question:
      // remembered per run, not persisted).
      sessionPickerItems(_lastSessionRows!, flat: _sessionPickerFlat),
    );
    // For the picker tests: the items the picker opened with.
    sessionPickerItemsForTest = sessionPickerItems(
      _lastSessionRows!,
      flat: _sessionPickerFlat,
    );
  }

  /// Tree-grouped picker rows (children nested under their parent, issue
  /// #198), or the flat single-level rows while toggled.
  Future<List<SessionListRow>> _sessionPickerRows(
    List<SessionMetadata> sessions,
  ) async {
    return buildSessionListRows(
      sessions: sessions,
      flat: _sessionPickerFlat,
      names: await sessionDisplayNames(_repo, sessions),
      currentSessionPath: (await _session?.getMetadata())?.path,
    );
  }

  /// Last non-empty path segment, with a fallback for the filesystem root.
  String _pathBasename(String path) {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }

  void _openModePicker() {
    final items = [
      for (final name in _modes.keys.toList()..sort())
        MenuItem(
          key: name,
          label: name,
          description: name == _currentMode.name ? '(current)' : '',
        ),
    ];
    _tuiController?.openPicker('mode', 'Select mode', items);
  }

  void _openApprovalPicker() {
    _tuiController?.openPicker(
      'approval',
      'Approval mode',
      approvalPickerItems(),
    );
  }

  /// The bare `/approval` picker rows: one per approval mode, the active
  /// mode's description carrying the ` (current)` marker.
  List<MenuItem> approvalPickerItems() {
    const descriptions = {
      'always-ask': 'prompt before every write/exec tool call',
      'write': 'auto-approve writes, prompt for exec',
      'yolo': 'auto-approve everything (critical bash still prompts)',
      'autopilot':
          'auto-approve everything, never asks — for runs without a user',
    };
    return [
      for (final mode in ApprovalMode.values)
        MenuItem(
          key: mode.label,
          label: mode.label,
          description:
              '${descriptions[mode.label] ?? ''}'
              '${mode == _approval.mode ? ' (current)' : ''}',
        ),
    ];
  }

  /// Test seam over [approvalPickerItems] (gh-1204): the visual leg caught a
  /// red here; this cheap dart-test seam pins the marker contract without a
  /// PTY.
  @visibleForTesting
  List<MenuItem> approvalPickerItemsForTest() => approvalPickerItems();

  // ---- /import (issue #1562) ----

  /// `/import`: the TUI import flow — harness picker, then the
  /// session-search picker. Line mode points at the headless CLI form.
  Future<void> _handleImportCommand(String rest) async {
    if (_tuiController == null) {
      io.writeln(
        '/import opens the interactive import picker. Headless equivalent: '
        '`fa import --harness=<omp|claude> (--all | --session=<id>)`.',
      );
      return;
    }
    _openImportHarnessPicker();
  }

  /// Step 1 of the flow (GOAL UX contract): the harness picker — four
  /// entries, type-to-filter free, Esc cancels with zero writes.
  void _openImportHarnessPicker() {
    // Rows derive from the import layer's single registry (same order)
    // so the TUI surface cannot drift from the CLI validation set.
    final items = [
      for (final harness in importHarnessRegistry)
        MenuItem(
          key: harness.id,
          label: harness.id,
          description: harness.description,
        ),
    ];
    importHarnessItemsForTest = items;
    _tuiController?.openPicker('import-harness', 'Import sessions', items);
  }

  /// Step 2: discover the current folder's foreign sessions and open the
  /// session-search picker (rows carry title + first/last previews; typing
  /// keyword-searches CONTENT through the host rebuild callback, GOAL
  /// F10/F11).
  Future<void> _tuiPickImportHarness(String key) async {
    if (!implementedHarnesses.contains(key)) {
      io.writeln(
        'import: "$key" is pending its format discovery spike — '
        'not importable yet.',
      );
      return;
    }
    final adapter = adapterFor(key);
    if (adapter == null) return;
    final discovered = await _discoverHarnessSessions(adapter);
    if (discovered == null) return;
    if (discovered.isEmpty) {
      io.writeln('import: no ${adapter.id} sessions found for ${_env.cwd}');
      return;
    }
    _importHarness = key;
    _importSummaries = await _describeHarnessSessions(adapter, discovered);
    _tuiController?.openPicker(
      'import-sessions',
      'Import from ${adapter.id}',
      _importSessionMenuItems(''),
    );
  }

  /// Discovers the harness's sessions under the configured home; null
  /// when the store is absent or unreadable (already reported).
  Future<List<ForeignSessionSummary>?> _discoverHarnessSessions(
    HarnessAdapter adapter,
  ) async {
    try {
      return await adapter.discover(
        fs: _env,
        cwd: _env.cwd,
        homeDir: config.homeDir ?? '',
        tempDir: '',
        limits: const ImportLimits(),
      );
    } on ForeignStoreAbsent catch (error) {
      io.writeln(
        _keyStatusView.errorLine(
          'import: no ${adapter.id} store at ${error.root}',
          _agent.state.model.baseUrl,
        ),
      );
    } on ForeignFileError catch (error) {
      io.writeln(
        _keyStatusView.errorLine(
          'import: ${error.message}',
          _agent.state.model.baseUrl,
        ),
      );
    }
    return null;
  }

  /// Previews + the bounded keyword index (one read-only streamed pass
  /// per session; a failing file degrades to a headerless row).
  Future<List<ForeignSessionSummary>> _describeHarnessSessions(
    HarnessAdapter adapter,
    List<ForeignSessionSummary> discovered,
  ) async {
    final described = <ForeignSessionSummary>[];
    for (final summary in discovered) {
      try {
        described.add(
          await describeForeignSession(
            adapter: adapter,
            fs: _env,
            summary: summary,
            limits: const ImportLimits(),
            homeDir: config.homeDir ?? '',
          ),
        );
      } on Object {
        described.add(summary);
      }
    }
    return described;
  }

  /// The picker rows: `All (<n> sessions)` first, then one row per
  /// session — selection keys carry the source id so a filtered view's
  /// selection still resolves.
  List<MenuItem> _importSessionMenuItems(String filter) {
    final rows = _importRowsFor(filter);
    return [
      MenuItem(
        key: 'all',
        label: 'All (${_importSummaries.length} sessions)',
        description: 'import every discovered ${_importHarness ?? ''} session',
      ),
      for (final summary in rows)
        MenuItem(
          key: 'i:${summary.sourceId}',
          label: summary.title.isNotEmpty ? summary.title : summary.sourceId,
          description:
              'first: ${summary.firstPreview} · last: ${summary.lastPreview}',
        ),
    ];
  }

  /// The host-callback rebuild the import-sessions picker filters through
  /// (the models-picker mechanism, GOAL F10): keyword search over title +
  /// bounded message text, recency order when the query is empty.
  List<MenuItem> _buildImportSessionMenu(String filter) =>
      _importSessionMenuItems(filter);

  List<ForeignSessionSummary> _importRowsFor(String filter) {
    final query = filter.trim().toLowerCase();
    if (query.isEmpty) return _importSummaries;
    return [
      for (final summary in _importSummaries)
        if (summary.title.toLowerCase().contains(query) ||
            summary.searchText.toLowerCase().contains(query))
          summary,
    ];
  }

  /// Step 3: import the selection — one session or every discovered one —
  /// through the same runner the CLI uses; per-session progress lines in
  /// the shared summary format. Esc never reaches here (zero writes).
  Future<void> _tuiPickImportSession(String key) async {
    final harness = _importHarness;
    final adapter = harness == null ? null : adapterFor(harness);
    final repo = _repo;
    if (adapter == null || repo is! JsonlSessionRepo) {
      // A non-Jsonl store cannot import — observable dead end, never a
      // silent no-op after the user picked a harness and a session.
      io.writeln('import: this session store does not support import');
      return;
    }
    final selected = key == 'all'
        ? _importSummaries
        : _importSummaries.where((s) => s.sourceId == key.substring(2));
    for (final summary in selected) {
      try {
        final result = await runImport(
          adapter: adapter,
          fs: _env,
          repo: repo,
          cwd: _env.cwd,
          selector: ImportSelector.one(summary.sourceId),
          limits: const ImportLimits(),
          homeDir: config.homeDir ?? '',
          tempDir: '',
          onLine: io.writeln,
        );
        if (result.exitCode != 0 && result.lines.isEmpty) {
          io.writeln('import: failed (${result.exitCode})');
        }
      } on Object catch (error) {
        io.writeln(
          _keyStatusView.errorLine(
            'import ${summary.sourceId} failed: $error',
            _agent.state.model.baseUrl,
          ),
        );
      }
    }
  }
}
