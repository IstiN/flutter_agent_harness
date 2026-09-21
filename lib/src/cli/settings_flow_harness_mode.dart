/// The settings-hub harness-mode flow (issue #679) of [AgentCli]: the
/// `agent.mode` preset picker (`default` | pi benchmark) writing the user
/// config through the validated surgical upsert; the pick lands at the
/// next boot. Split out of `settings_flow.dart` to keep that file under
/// the repo's 2800-line size gate. Same library (a `part of`), so the
/// extension sees the class's private members.
part of 'agent_cli.dart';

/// Harness-mode settings members of [AgentCli] (issue #679).
extension HarnessModeSettings on AgentCli {
  /// The `/settings` summary label and hub-row description for the
  /// harness benchmark mode (issue #679): the resolved boot mode
  /// (flag > env > config, AC3).
  String _harnessModeStatusLabel() => config.agentMode ?? 'default';

  /// Settings → Harness mode: the `agent.mode` preset (issue #679,
  /// AC3's settings surface) — `default` or the pi benchmark shape (the
  /// 4-tool surface, the bare prompt). Writes go through the surgical
  /// validated-yaml upsert into the USER config (the same path
  /// `fa config set agent.mode …` uses); the running session keeps its
  /// boot mode — the pick lands at the next boot, where the
  /// flag > env > config ladder re-resolves it.
  Future<void> startHarnessModeFlow() async {
    for (;;) {
      final picked = await _pickOption(
        'harness mode',
        _harnessModeMenuOptions(),
      );
      if (picked == null || picked == 'done') return;
      await _applyHarnessModePick(picked);
    }
  }

  /// The main menu of [startHarnessModeFlow]. Pure builder.
  List<FlowOption> _harnessModeMenuOptions() {
    final current = config.agentMode ?? 'default';
    return [
      (
        'default',
        'Default (full harness)',
        current == 'default' ? 'current' : '',
      ),
      (
        'pi',
        'pi benchmark (4 tools, bare prompt)',
        current == 'pi' ? 'current' : '',
      ),
      ('done', 'Done', ''),
    ];
  }

  /// Dispatches one [startHarnessModePick]; the caller re-renders the
  /// menu afterwards. The upsert's strict `agent:` validation (the same
  /// parser boot uses) rejects a bad section BEFORE the write.
  Future<void> _applyHarnessModePick(String picked) async {
    if (picked != 'default' && picked != 'pi') return;
    if (_userConfigPath() == null) {
      io.writeln('harness mode: no user config on this host — not saved');
      return;
    }
    await _upsertConfigYaml(
      const ['agent', 'mode'],
      picked,
      projectScope: false,
      validate: validateAgentSection,
    );
  }
}
