/// The settings-hub Context cap flow of [AgentCli] (issue #394). Split
/// out of `settings_flow.dart` for the repo's 2800-line size gate — same
/// library (a `part of`), so the extension sees the class's private
/// members and the shared config helpers.
part of 'agent_cli.dart';

extension SettingsContextCapFlow on AgentCli {
  /// The settings-hub row and `/settings` summary label for the owner cap
  /// (issue #394): the model's raw window vs the effective cap.
  String _contextCapStatusLabel() {
    final cap = config.contextWindowCap;
    final window = _agent.state.model.contextWindow;
    return cap == null ? 'off (window $window)' : '$window → $cap';
  }

  /// Settings → Context cap: the `agent:` section (`contextWindowCap`,
  /// issue #394) — set or clear the owner-side cap the compaction
  /// thresholds, the ctx meter and the loop's over-window guard clamp
  /// through. Writes go through the surgical validated-yaml upsert into
  /// the USER config (the machine-level file `fa config set agent…`
  /// also uses); the running session keeps its boot cap (honest note).
  /// Loops until the pick is cancelled or `done`.
  Future<void> startContextCapFlow() async {
    for (;;) {
      final picked = await _pickOption('context cap', _contextCapMenuOptions());
      if (picked == null || picked == 'done') return;
      await _applyContextCapPick(picked);
    }
  }

  /// Dispatches one [startContextCapFlow] menu pick; the caller re-renders
  /// the menu afterwards. Split out to keep each function's complexity
  /// under the repo's CRAP gate.
  Future<void> _applyContextCapPick(String picked) async {
    switch (picked) {
      case 'set':
        await _askContextCapValue();
      case 'clear':
        await _clearContextCap();
    }
  }

  /// The main menu of [startContextCapFlow]. Pure builder.
  List<FlowOption> _contextCapMenuOptions() {
    final cap = config.contextWindowCap;
    return [
      ('set', 'Set the cap', cap == null ? 'currently off' : 'currently $cap'),
      (
        'clear',
        'Clear the cap',
        cap == null ? 'already off' : 'removes agent.contextWindowCap',
      ),
      ('done', 'Done', ''),
    ];
  }

  /// The set branch: a positive integer at or above the compaction
  /// reserve. The raw answer goes through the validated upsert — an
  /// invalid value prints the parser's verbatim [ConfigException] and
  /// writes NOTHING (AC4). A cap at or above the model's own window
  /// clamps nothing — the flow warns after a successful write.
  Future<void> _askContextCapValue() async {
    final current = config.contextWindowCap;
    final answer = await _askLine(
      'context cap in tokens (min 16384, empty keeps '
      "${current ?? 'off'}): ",
    );
    if (answer == null) return;
    final value = answer.trim();
    if (value.isEmpty) return;
    final wrote = await _upsertConfigYaml(
      const ['agent', 'contextWindowCap'],
      value,
      projectScope: false,
      validate: validateAgentSection,
    );
    if (wrote) _warnCapNoOp(value);
  }

  /// The ≥-window warning: the cap only CLAMPS below the model's window;
  /// at or above it the setting is a legal no-op.
  void _warnCapNoOp(String value) {
    final cap = int.tryParse(value);
    final window = _agent.state.model.contextWindow;
    if (cap != null && window > 0 && cap >= window) {
      io.writeln('note: $cap ≥ model window $window — the cap clamps nothing');
    }
  }

  /// The clear branch: a surgical `removeYamlPath` of the cap key — the
  /// sibling `agent:` keys (the load preset, the misuse-breaker kill
  /// switch, the stuck-tool section) survive byte-for-byte; the whole
  /// block goes only when the cap was its last member (a bare `agent:`
  /// would fail the strict diagnostics validator).
  Future<void> _clearContextCap() async {
    if (config.contextWindowCap == null) {
      io.writeln('context cap: already off — nothing to clear');
      return;
    }
    final path = _userConfigPath();
    if (path == null) {
      io.writeln('context cap: no user config on this host — not saved');
      return;
    }
    final read = await _env.readTextFile(path);
    final String source;
    switch (read) {
      case Ok(:final value):
        source = value;
      case Err(:final error):
        io.writeln('cannot read $path: $error — not saved');
        return;
    }
    final edited = removeYamlPath(source, const ['agent', 'contextWindowCap']);
    // Never persist a file the next boot would reject.
    try {
      loadYaml(edited);
    } on Object catch (error) {
      io.writeln('not saved: $error');
      return;
    }
    if (await _env.writeFile(path, edited) is Err) {
      io.writeln('could not write $path');
      return;
    }
    await _notifyUserConfigFileChanged();
    io.writeln(
      'agent.contextWindowCap removed → $path (${applicationNote('agent')})',
    );
  }
}
