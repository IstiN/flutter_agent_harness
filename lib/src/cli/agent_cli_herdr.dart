/// The herdr pane-state hooks of [AgentCli] (issue #1481): fa self-reports
/// its own pane state to the herdr multiplexer through `pane report-agent`
/// while the pinned lifecycle seams cross — REPL boot (idle, so the pane
/// never sits `unknown`), run start (working), run settle (idle), TUI
/// prompt sheets (blocked with the sheet's static label), in-process
/// session switches (re-report the new session, never a release), and REPL
/// teardown (release, real quit only). Every report is fire-and-forget
/// inside [HerdrReporter] — outside a herdr pane (the reporter's env gate)
/// every hook here is a no-op for the process lifetime. Split out of
/// `agent_cli.dart` to keep it under the repo's line gate. Same library (a
/// `part of`), so the extension sees the class's private members with no
/// visibility change.
part of 'agent_cli.dart';

extension AgentCliHerdr on AgentCli {
  /// REPL boot complete, composer resting: the one boot report that keeps
  /// the pane from sitting `unknown` until the first turn, carrying the
  /// session id (herdr's resume metadata).
  void _herdrBootIdle() {
    _herdr.updateSession(_session?.cachedId);
    _herdr.state(HerdrPaneState.idle);
  }

  /// A run/turn started (`_runPrompt` begin — submits, inbox wakes,
  /// steering, and auto-continuations all funnel through it).
  void _herdrRunWorking() => _herdr.state(HerdrPaneState.working);

  /// The run settled end to end (`_startRun`'s whenComplete — the same edge
  /// the busy row drops on): back at the composer.
  void _herdrRunIdle() => _herdr.state(HerdrPaneState.idle);

  /// An in-process session switch (`/session <name>`, `/new`, the picker):
  /// re-report the NEW session. Never a release — release is real quit
  /// only (pinned release semantics, issue #1481 E5).
  void _herdrSessionSwitched() {
    final id = _session?.cachedId;
    if (id == null) return;
    _herdr.sessionSwitch(id);
  }

  /// REPL teardown: release the pane registration exactly once. Awaited so
  /// the report cannot be cut by process exit; a crash skips it and
  /// herdr's shell-prompt safety net clears the registration on its own.
  Future<void> _herdrRelease() => _herdr.release();

  /// Every TUI prompt sheet reports `blocked` with its static label while
  /// it waits on the user and re-reports working/idle when it resolves —
  /// the sheet's answer path itself is untouched.
  Future<TuiPromptAnswer?> _openHerdrPrompt(
    FaTuiController tui,
    TuiPromptSpec spec,
  ) => _herdr.reportSheet(spec, open: tui.openPrompt, busyAfter: () => isBusy);
}
