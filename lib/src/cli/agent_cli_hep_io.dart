// Stdout-purity decorator for HEP events mode (issue #155), split into a
// `part of` so it sees the library-private CliIO surface (same layout as
// `agent_cli_io.dart`).
part of 'agent_cli.dart';

/// In `--output events` the HEP stream owns stdout: streaming deltas
/// ([CliIO.write]) are dropped — they ride `message_delta` frames — while
/// diagnostics ([CliIO.writeln]: banners, tool traces, errors) keep
/// flowing to the host's channel (stderr in headless mode).
class HepEventsIO implements CliIO {
  /// Wraps [inner].
  HepEventsIO(this.inner);

  final CliIO inner;

  @override
  void write(String text) {}

  @override
  void writeln(String text) => inner.writeln(text);

  @override
  Stream<String> get lines => inner.lines;

  @override
  Stream<void> get interrupts => inner.interrupts;

  @override
  Stream<KeyEvent> get keys => inner.keys;

  @override
  bool get supportsRawMode => inner.supportsRawMode;

  @override
  bool get isInteractive => inner.isInteractive;

  @override
  int get columns => inner.columns;

  @override
  int get rows => inner.rows;
}

/// Headless structured-output header writes (issues #155/#695): the HEP
/// `hep_header` frame and the stream-json session line are each the FIRST
/// stdout line of their mode, emitted the moment the session id exists —
/// before any agent event can race them. Split into this part (same
/// library) so [AgentCli.runHeadless] stays under the CRAP gate.
extension AgentCliHeadlessEvents on AgentCli {
  /// Writes the header of every structured mode the run carries (at most
  /// one of [hep]/[streamJson] is non-null in practice — the CLI rejects
  /// `--output` combined with `--output-format stream-json`).
  Future<void> _writeHeadlessEventHeaders({
    HepWriter? hep,
    StreamJsonWriter? streamJson,
  }) async {
    if (hep == null && streamJson == null) return;
    final sessionId = _session!.cachedId ?? (await _session!.getMetadata()).id;
    hep?.writeHeader(sessionId: sessionId);
    // Stream-json mode: the session header carries the run's cwd (pi's
    // session line shape). `_env.cwd`, not `config.env.cwd`: the run
    // operates on the CwdOverrideEnv abstraction (session switching
    // mutates it), so the header reports the effective cwd, not the
    // delegate's original.
    streamJson?.writeHeader(sessionId: sessionId, cwd: _env.cwd);
  }
}
