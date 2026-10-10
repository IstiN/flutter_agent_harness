/// The herdr pane reporter (issue #1481): fa self-reports its own pane
/// state to the herdr terminal multiplexer through herdr's `pane
/// report-agent` CLI, so a fa session running inside a herdr pane keeps
/// herdr's record of that pane true — `idle` at boot, `working` during a
/// run, `blocked` while a prompt sheet waits on the user — and releases
/// the registration on real quit.
///
/// Pure Dart by construction (no `dart:io`): the env gate arrives as an
/// injectable lookup, the transport as an injectable spawn closure the
/// executable backs with `Process.run`. Outside a herdr pane the reporter
/// is constructed inert and stays inert for the process lifetime — zero
/// subprocesses, zero log lines, zero user-visible anything.
///
/// Transport contract (herdr 0.8.2+ CLI): every report is ONE
/// fire-and-forget subprocess of `$HERDR_BIN_PATH pane …` with a short
/// timeout, silent on failure, no retry, no queue — a dead herdr is
/// indistinguishable from no herdr. The only bytes that can ever leave fa
/// are the fixed argv vocabulary below: state strings from the [HerdrPaneState]
/// enum, the static label from the closed [HerdrBlockedLabel] enum, a
/// millisecond seq, the charset-validated pane/session ids, and the static
/// resume argv `fa --session <id>`. No transcript text, no user text, no
/// file paths, no secrets — there is no code path that interpolates
/// anything else into the argv.
library;

import 'dart:async';

import 'tui_prompt.dart';

/// The pane states fa reports (herdr's `--state` vocabulary). herdr's own
/// `unknown` is its pre-registration default — fa's boot report exists
/// precisely so the pane never sits in it.
enum HerdrPaneState {
  idle,
  working,
  blocked;

  /// The exact `--state` byte string herdr expects.
  String get wire => name;
}

/// The static `--message` labels for the blocked state — a closed enum,
/// never dynamic text (herdr shows the message next to the pane name).
enum HerdrBlockedLabel {
  approval,
  ask,
  secret,
  hostModel;

  /// The exact `--message` byte string herdr expects.
  String get wire => switch (this) {
    hostModel => 'host-model',
    _ => name,
  };
}

/// Reports fa's own pane state to herdr, fire-and-forget.
///
/// Constructed once per CLI lifetime (the CLI constructor wires the host's
/// env lookup + spawn closure in); the gate is evaluated exactly once here
/// — a reporter constructed inert never spawns anything, no matter what
/// the hooks call.
final class HerdrReporter {
  /// Creates the reporter and evaluates the herdr gate once: active only
  /// when `HERDR_ENV=1` AND `HERDR_PANE_ID` is charset-valid AND
  /// `HERDR_BIN_PATH` is absolute + argv-safe AND the `FA_HERDR=0` kill
  /// switch is not engaged. Any unmet condition is byte-identical to no
  /// herdr: inert, silent, spawn-free.
  ///
  /// [envLookup] resolves the pane env vars on the host (the executable
  /// injects `Platform.environment` reads; null = every var unset). Null
  /// [runProcess] (web hosts, plain tests) keeps the reporter spawn-free
  /// even behind an active gate. [clock] feeds the millisecond seq (the
  /// CLI passes its waiting-clock seam so tests pin seq discipline).
  HerdrReporter({
    String? Function(String name)? envLookup,
    Future<void> Function(List<String> argv)? runProcess,
    DateTime Function()? clock,
    this.timeout = const Duration(seconds: 2),
  }) : _runProcess = runProcess,
       _clock = clock ?? DateTime.now {
    final lookup = envLookup ?? (_) => null;
    final pane = lookup('HERDR_PANE_ID');
    final bin = lookup('HERDR_BIN_PATH');
    _active = gateActive(
      herdrEnv: lookup('HERDR_ENV'),
      paneId: pane,
      binPath: bin,
      killSwitch: lookup('FA_HERDR'),
    );
    if (_active) {
      _pane = pane!;
      _bin = bin!;
    }
  }

  /// Short subprocess timeout — herdr is a local CLI over a local socket;
  /// anything slower is treated as a failed (silently dropped) report.
  final Duration timeout;

  final Future<void> Function(List<String> argv)? _runProcess;
  final DateTime Function() _clock;

  bool _active = false;
  String _pane = '';
  String _bin = '';

  /// The session id every report carries (`--agent-session-id`, herdr's
  /// resume metadata for pane restore).
  String? _sessionId;

  /// The session id the resume argv (`-- fa --session <id>`) was last sent
  /// for — the argv rides the first report of each session only.
  String? _resumeSentFor;

  int _lastSeq = 0;

  /// Whether the gate is satisfied and reports actually spawn. Inert
  /// reporters keep this false for the process lifetime.
  bool get active => _active;

  /// The gate as a pure predicate (the truth table is unit-tested over
  /// exactly these four inputs).
  static bool gateActive({
    required String? herdrEnv,
    required String? paneId,
    required String? binPath,
    required String? killSwitch,
  }) {
    if (herdrEnv != '1') return false;
    if (killSwitch == '0') return false;
    if (paneId == null || !validPaneId(paneId)) return false;
    if (binPath == null || !validBinPath(binPath)) return false;
    return true;
  }

  /// herdr's pane-id charset: `[A-Za-z0-9._-]+` (pane ids like `w6:p16`
  /// carry a colon, which is intentionally NOT allowed — a hostile pane id
  /// can never shape the argv). Any other byte makes the integration inert.
  static bool validPaneId(String value) => _idPattern.hasMatch(value);

  /// Session ids obey the same charset (the `--session` contract's
  /// `<timestamp>_<id>` tail is a subset).
  static bool validSessionId(String value) => _idPattern.hasMatch(value);

  /// `HERDR_BIN_PATH` must be absolute (no cwd games) and argv-safe: the
  /// spawn is `[bin, 'pane', …]` with bin as argv[0], so shell metachars,
  /// spaces, apostrophes, `$`, `;`, and control bytes all make the
  /// integration inert instead of reaching a subprocess.
  static bool validBinPath(String value) =>
      value.startsWith('/') && _binPattern.hasMatch(value);

  /// herdr's pinned resume-argv rules (≥0.10.0 restores the pane with
  /// `argv`; older herdr silently ignores it): first word a plain command
  /// name on PATH (no path separators), no apostrophes, no control
  /// characters anywhere, ≤64 args, ≤8 KiB total. fa's own argv is the
  /// static `fa --session <id>` and always passes — the check exists as
  /// defense in depth so a future change cannot ship a rule-breaking argv.
  static bool resumeArgvValid(List<String> argv) {
    if (argv.isEmpty || argv.length > 64) return false;
    var total = 0;
    for (final arg in argv) {
      total += arg.length;
      if (total > _resumeArgvMaxBytes) return false;
    }
    final head = argv.first;
    if (head.isEmpty || head.contains('/') || head.contains(r'\')) return false;
    for (final arg in argv) {
      for (var i = 0; i < arg.length; i++) {
        final unit = arg.codeUnitAt(i);
        // Apostrophe (herdr's quoting hazard) + C0 controls + DEL.
        if (unit == 0x27 || unit < 0x20 || unit == 0x7f) return false;
      }
    }
    return true;
  }

  /// Maps a [TuiPromptSpec] onto its static blocked label — the four
  /// prompt-zone sheet kinds (free-text input sheets, including password
  /// prompts, report the host-model label; the label enum is closed).
  static HerdrBlockedLabel labelFor(TuiPromptSpec spec) => switch (spec) {
    ApprovalPromptSpec() => HerdrBlockedLabel.approval,
    AskPromptSpec() => HerdrBlockedLabel.ask,
    SecretPromptSpec() => HerdrBlockedLabel.secret,
    TextPromptSpec() => HerdrBlockedLabel.hostModel,
  };

  /// Adopts the current session id for subsequent reports. Call at boot and
  /// on every in-process session switch (before the switch's own report).
  void updateSession(String? sessionId) {
    _sessionId = sessionId != null && validSessionId(sessionId)
        ? sessionId
        : null;
  }

  /// Reports a pane-state transition (the core loop: boot `idle`, run start
  /// `working`, sheet `blocked`, settle back). Fire-and-forget; a no-op on
  /// an inert reporter.
  void state(HerdrPaneState state, {HerdrBlockedLabel? label}) {
    if (!_active) return;
    final sid = _sessionId;
    final resume = sid != null && _resumeSentFor != sid;
    final argv = reportStateArgs(
      state: state,
      label: label,
      seq: _nextSeq(),
      sessionId: sid,
      includeResumeArgv: resume,
    );
    if (resume) _resumeSentFor = sid;
    _spawn(argv);
  }

  /// Reports `blocked` with the sheet's static label.
  void blocked(HerdrBlockedLabel label) {
    state(HerdrPaneState.blocked, label: label);
  }

  /// Reports the post-resolve state: back to `working` when a run is still
  /// streaming, `idle` at the resting composer.
  void recovered({required bool active}) {
    state(active ? HerdrPaneState.working : HerdrPaneState.idle);
  }

  /// An in-process session switch (`/session`, `/new`, the picker):
  /// reports the NEW session through herdr's dedicated op and re-arms the
  /// resume argv for it. Never a release — the pane registration survives
  /// session switches (release is real quit only).
  void sessionSwitch(String sessionId) {
    updateSession(sessionId);
    if (!_active || !validSessionId(sessionId)) return;
    _spawn(sessionSwitchArgs(sessionId: sessionId, seq: _nextSeq()));
    _resumeSentFor = sessionId;
  }

  /// Releases the pane registration (herdr clears name/state/resume
  /// immediately). Sent exactly once, on real quit only — the REPL teardown
  /// awaits this so the report cannot be cut by process exit; a crash
  /// skips it and herdr's shell-prompt safety net clears the registration
  /// on its own.
  Future<void> release() async {
    if (!_active) return;
    await _send(releaseArgs(seq: _nextSeq()));
  }

  /// Wraps one prompt-sheet open: reports `blocked` with the spec's label,
  /// opens the sheet through [open] unchanged, and reports the post-resolve
  /// state through [busyAfter]. The answer path itself is untouched.
  Future<TuiPromptAnswer?> reportSheet(
    TuiPromptSpec spec, {
    required Future<TuiPromptAnswer?> Function(TuiPromptSpec) open,
    required bool Function() busyAfter,
  }) async {
    blocked(labelFor(spec));
    final answer = await open(spec);
    recovered(active: busyAfter());
    return answer;
  }

  /// The exact `pane report-agent` argv (snapshot-tested — any herdr CLI
  /// schema drift shows up as a reviewed diff, never silent breakage).
  /// Empty on an inert reporter.
  List<String> reportStateArgs({
    required HerdrPaneState state,
    HerdrBlockedLabel? label,
    required int seq,
    String? sessionId,
    bool includeResumeArgv = false,
  }) {
    if (!_active) return const [];
    final resume = includeResumeArgv && sessionId != null;
    return [
      _bin,
      'pane',
      'report-agent',
      _pane,
      '--source',
      'fa',
      '--agent',
      'fa',
      '--state',
      state.wire,
      '--seq',
      '$seq',
      if (label != null) ...['--message', label.wire],
      if (sessionId != null) ...['--agent-session-id', sessionId],
      if (resume) ...['--', 'fa', '--session', sessionId],
    ];
  }

  /// The exact `pane report-agent-session` argv for an in-process session
  /// switch. Empty on an inert reporter.
  List<String> sessionSwitchArgs({
    required String sessionId,
    required int seq,
  }) {
    if (!_active) return const [];
    return [
      _bin,
      'pane',
      'report-agent-session',
      _pane,
      '--source',
      'fa',
      '--agent',
      'fa',
      '--agent-session-id',
      sessionId,
      '--seq',
      '$seq',
      '--',
      'fa',
      '--session',
      sessionId,
    ];
  }

  /// The exact `pane release-agent` argv. Empty on an inert reporter.
  List<String> releaseArgs({required int seq}) {
    if (!_active) return const [];
    return [
      _bin,
      'pane',
      'release-agent',
      _pane,
      '--source',
      'fa',
      '--agent',
      'fa',
      '--seq',
      '$seq',
    ];
  }

  /// Milliseconds since epoch, forced strictly increasing: herdr requires
  /// seq to rise across ALL reports from one source (it ignores
  /// non-increasing seq), including across agent restarts — which is why
  /// the base is a wall-clock timestamp, not an in-process counter. The
  /// `max(…, _lastSeq + 1)` band only ever bites when two reports land in
  /// the same millisecond (or the clock rolls back): herdr then keeps the
  /// later report instead of silently dropping it.
  int _nextSeq() {
    final ms = _clock().millisecondsSinceEpoch;
    _lastSeq = ms > _lastSeq ? ms : _lastSeq + 1;
    return _lastSeq;
  }

  void _spawn(List<String> argv) {
    if (!_active) return;
    final run = _runProcess;
    if (run == null) return;
    unawaited(_send(run, argv));
  }

  Future<void> _send(
    Future<void> Function(List<String> argv) run,
    List<String> argv,
  ) async {
    try {
      await run(argv).timeout(timeout);
    } on Object {
      // Fire-and-forget by contract: a dead, slow, or restarted herdr
      // (herdr update --handoff loses in-flight reports) is treated
      // exactly like no herdr — dropped, never retried, never queued,
      // never logged, never user-visible. herdr's last-known state stands
      // until fa's next transition heals it.
    }
  }

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9._-]+$');
  static final RegExp _binPattern = RegExp(r'^[A-Za-z0-9._/+~-]+$');
  static const int _resumeArgvMaxBytes = 8 * 1024;
}
