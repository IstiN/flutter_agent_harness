/// The diagnostic-log members of [AgentCli]: the fa.log writer
/// (`_logDiagnostic`/`_appendDiagnosticLog`), the short session id for log
/// lines (`_logSid`) and the log path resolver (`_diagnosticLogPath`).
/// Split out of `agent_cli.dart` to keep that file under the repo's
/// 2800-line size gate. Same library (a `part of`), so the extension sees
/// the class's private members; the `_diagnosticLogDirEnsured` field stays
/// on the class — extensions hold no fields.
part of 'agent_cli.dart';

/// Diagnostic-log members of [AgentCli].
extension AgentCliDiagLog on AgentCli {
  /// Writes a diagnostic line to the log file (`~/.fah/logs/fa.log`).
  /// TUI/stderr stay clean — the AutoCompactor hook streams progress to
  /// the user, the log captures everything for post-mortem.
  ///
  /// Issue #2117: every call declares a [level] (default `info`) and a
  /// [category] (default `lifecycle`); the FILE sink gate applies before
  /// any work is queued, and the rendered line carries the level tag
  /// (fa.log keeps its shape and destination beyond the level tags).
  ///
  /// gh-2097: the append rides the serialized `_diagLogChain` — a burst
  /// of diagnostics lands complete and in order, never racing itself on
  /// the same file, and exit paths drain the chain so nothing is dropped
  /// (the old unawaited fire-and-forget lost rapid bursts at process
  /// exit).
  void _logDiagnostic(
    String message, {
    LogLevel level = LogLevel.info,
    LogCategory category = LogCategory.lifecycle,
  }) {
    final path = _diagnosticLogPath;
    if (path == null) return;
    if (!config.logging.filePasses(level, category)) return;
    _diagLogChain = _diagLogChain
        .then(
          (_) => _appendDiagnosticLog(
            path,
            message,
            level: level,
            category: category,
          ),
        )
        // The appender already swallows its own errors; this keeps the
        // chain alive regardless so one failure can never drop every
        // later line with it.
        .catchError((Object _) {});
  }

  /// gh-2097: drains the diagnostic-append chain — every exit path
  /// awaits this so the process cannot die with pending lines in the
  /// chain (the last thing the process does must never be a pending
  /// log write). Issue #2248 AC4: when the sink is failing, the drain
  /// also dumps the in-memory ring to stderr, so exit never loses the
  /// buffered post-mortem either.
  Future<void> flushDiagnosticLog() async {
    await _diagLogChain;
    _dumpDiagRingToStderr(exitDrain: true);
  }

  /// Test seam: emit one diagnostic line exactly as production callers
  /// do (gh-2097 burst/drop coverage; the level/category ride through
  /// for the #2117 sink tests).
  @visibleForTesting
  void logDiagnosticForTest(
    String message, {
    LogLevel level = LogLevel.info,
    LogCategory category = LogCategory.lifecycle,
  }) => _logDiagnostic(message, level: level, category: category);

  /// gh-2178: wires the quarantine report onto the CLI notice channel —
  /// the same line rides fa.log at warn level (the diagnostics file
  /// keeps the forensic copy; the reporter's per-record dedupe keeps a
  /// repeated turn from spamming either surface).
  void wireQuarantineNotice(void Function(String message) onNotice) {
    SessionQuarantine.onQuarantined = (line) {
      onNotice(line);
      _logDiagnostic(line, level: LogLevel.warn);
    };
  }

  /// Short session id for diagnostic log lines: parallel fa processes share
  /// one fa.log, so every lifecycle line names its session (post-mortem
  /// "who held the busy row" starts here).
  String get _logSid {
    final id = _session?.cachedId;
    if (id == null || id.isEmpty) return '-';
    return id.length <= 8 ? id : id.substring(0, 8);
  }

  /// Appends one rendered line to [path], creating the log directory on
  /// first use. Isolated from [_logDiagnostic] so the public entry point
  /// stays small.
  ///
  /// Issue #2117: the line is REDACTED (every rendered line, every sink)
  /// and carries the level tag after the timestamp — the default file
  /// shape is today's `ISO message` with ` level` inserted; a configured
  /// `logging.format` renders the pattern instead.
  Future<void> _appendDiagnosticLog(
    String path,
    String message, {
    required LogLevel level,
    required LogCategory category,
  }) async {
    final settings = config.logging;
    final safe = config.redactionPipeline?.redact(message) ?? message;
    final line = settings.format == null
        ? '${DateTime.now().toIso8601String()} ${level.name} $safe\n'
        : '${settings.format!.render(
            LogEvent(time: DateTime.now(), elapsed: DateTime.now().difference(_loggingBoot), sid: _logSid, level: level, category: category, message: safe),
            timeFormat: settings.timeFormat,
          )}\n';
    // Issue #2248 AC4: the append is BOUNDED (the same session-IO knob) —
    // wedge #1's log went silent because the log appends themselves hung;
    // a hung or failed append now trips the sink's failure mode instead
    // of stalling the whole diagnostic chain behind it.
    Result<void, FileError> result;
    try {
      if (!_diagnosticLogDirEnsured) {
        _diagnosticLogDirEnsured = true;
        await _env.createDir('${config.homeDir}/.fah/logs', recursive: true);
        await _rotateDiagnosticLogIfOversized(path);
      }
      result = await _boundedLogAppend(path, line);
    } on Object catch (error) {
      result = Err(FileError(FileErrorCode.unknown, '$error'));
    }
    if (result.isOk) {
      if (_ioState.diagFailing) await _recoverDiagSink(path);
      return;
    }
    _noteDiagSinkFailure(path, result.errorOrNull!);
    _emitDiagFallbackLine(line);
    _bufferDiagLine(line);
  }

  /// One fa.log append under the session-IO bound (RC round-1: the
  /// recovery flush ran unbounded inside the gh-2097 chain — a
  /// fail→ok→hang fs would have wedged the chain and the exit drain,
  /// the exact class this PR eliminates). A timeout surfaces as an Err
  /// flush result instead of awaiting forever.
  Future<Result<void, FileError>> _boundedLogAppend(String path, String line) =>
      _env
          .appendFile(path, line)
          .timeout(
            config.sessionIoTimeout,
            onTimeout: () => Err(
              FileError(
                FileErrorCode.aborted,
                'diagnostic log append timed out',
              ),
            ),
          );

  /// AC4: first-failure marker — `fa_log_sink=fail(errno=...)` rides the
  /// stderr fallback (the file sink is the thing that is down); the boot
  /// line family keeps the failure greppable.
  void _noteDiagSinkFailure(String path, FileError error) {
    final state = _ioState;
    if (!state.diagFailing) {
      state.diagFailing = true;
      state.diagFirstErrno = diagSinkErrnoLabel(error);
      _diagFallback(
        'fa_log_sink=fail(${state.diagFirstErrno ?? 'unknown'}) '
        'path=$path error=${error.message} — lines buffer in memory '
        'and ride stderr until the file sink recovers',
      );
    }
  }

  /// AC4: while failing, every line also goes to stderr (the diagnostics
  /// channel — headless hosts route writeln to stderr; the TUI transcript
  /// shows it, which is the point: the log must never go blind silently).
  void _emitDiagFallbackLine(String line) => _diagFallback(line.trimRight());

  /// AC4: bounded in-memory ring (last [diagSinkRingCapacity] lines).
  void _bufferDiagLine(String line) {
    final ring = _ioState.diagRing;
    ring.add(line);
    if (ring.length > diagSinkRingCapacity) {
      ring.removeAt(0);
    }
  }

  /// AC4: first successful write after a failure — flush the ring into
  /// the file (best-effort per line; a still-failing or TIMED-OUT flush
  /// keeps the buffer and the failing state), then mark the recovery
  /// with `log_sink_recovered buffered=N` so the post-mortem knows
  /// exactly which lines were delayed. Every append runs under the
  /// session-IO bound (RC round-1: an unbounded flush here could wedge
  /// the append chain on a fail→ok→hang fs). Awaited inside the append
  /// chain, so the flush lines never race the live appends that follow.
  Future<void> _recoverDiagSink(String path) async {
    final state = _ioState;
    final buffered = List<String>.of(state.diagRing);
    state.diagRing.clear();
    var flushed = 0;
    for (final bufferedLine in buffered) {
      final landed = await _boundedLogAppend(path, bufferedLine);
      if (landed.isOk) {
        flushed++;
      } else {
        _bufferDiagLine(bufferedLine);
      }
    }
    state.diagFailing = false;
    final errno = state.diagFirstErrno;
    state.diagFirstErrno = null;
    final marker = await _boundedLogAppend(
      path,
      '${DateTime.now().toIso8601String()} info '
      'log_sink_recovered buffered=$flushed '
      'failed_as=${errno ?? 'unknown'}\n',
    );
    if (!marker.isOk) {
      state.diagFailing = true;
      state.diagFirstErrno = errno;
      _diagFallback('log_sink_recovered buffered=$flushed (marker failed)');
      return;
    }
    _diagFallback('fa_log_sink=recovered buffered=$flushed flushed to file');
  }

  /// AC4/exit: dumps the still-unflushed ring to stderr — called from
  /// [flushDiagnosticLog] so a process that dies while the sink is down
  /// prints what it buffered instead of losing it.
  void _dumpDiagRingToStderr({required bool exitDrain}) {
    final state = _ioState;
    if (!state.diagFailing && state.diagRing.isEmpty) return;
    for (final line in state.diagRing) {
      _diagFallback(line.trimRight());
    }
    final count = state.diagRing.length;
    state.diagRing.clear();
    if (exitDrain && count > 0) {
      _diagFallback(
        'fa_log_sink=exit_drain buffered=$count dumped to stderr '
        '(file sink never recovered)',
      );
    }
  }

  /// The stderr/route fallback writer. CliIO.writeln is the diagnostics
  /// channel (stderr on headless hosts) — used instead of raw `stderr`
  /// so lib/src stays dart:io-free and the app host can route it.
  void _diagFallback(String text) {
    try {
      io.writeln(text);
    } on Object {
      // The fallback of the fallback must never throw either.
    }
  }

  /// Rotates [path] to `fa.log.1` when it exceeds
  /// [AgentCli.diagnosticLogMaxBytes]. Runs once per process (first log
  /// write), so parallel fa processes can race the rename — losing a few
  /// diagnostics lines is acceptable for a post-mortem file. The rename
  /// keeps the previous log available; a backend that reports rename as
  /// unsupported (CwdOverrideEnv forwards the capability only when the
  /// delegate has it) falls back to truncating in place.
  Future<void> _rotateDiagnosticLogIfOversized(String path) async {
    final info = await _env.fileInfo(path);
    final size = info.valueOrNull?.size ?? 0;
    if (size <= AgentCli.diagnosticLogMaxBytes) return;
    final renamed = await _env.renamePath(path, '$path.1');
    if (renamed.isOk) return;
    await _env.writeFile(path, '');
  }

  /// Path of the diagnostic log file under `~/.fah/logs/fa.log`. Null
  /// when the host has no `homeDir` (web build, sandbox).
  String? get _diagnosticLogPath {
    final home = config.homeDir;
    if (home == null || home.isEmpty) return null;
    return '$home/.fah/logs/fa.log';
  }
}

/// Per-process state for the issue #2248 CLI surfaces. Extensions hold
/// no fields, and `agent_cli.dart` rides the 2800-line gate — one object
/// on the class carries the fa.log sink's self-failure state (AC4) and
/// the sessions-container size memo (AC6).
final class AgentCliIoState {
  /// AC4: whether the fa.log sink is currently failing (stderr fallback
  /// active, ring buffering).
  bool diagFailing = false;

  /// AC4: the errno label of the failure that opened the episode
  /// (`errno=24: Too many open files` shape), echoed by the recovery
  /// marker.
  String? diagFirstErrno;

  /// AC4: the in-memory ring of lines that failed to land — flushed to
  /// the file on recovery, dumped to stderr on exit drain. Bounded at
  /// [diagSinkRingCapacity]; the oldest line falls off beyond it.
  final diagRing = <String>[];

  /// AC6: the sessions-container size memo — boot starts the walk
  /// unawaited; /stats awaits the same future (never recomputes).
  Future<ContainerSizeStats?>? containerSizeFuture;
}

/// Ring capacity: the incident's log hole spanned ~100 lifecycle lines
/// over minutes; 500 keeps a healthy post-mortem margin without
/// unbounded memory. ponytail: fixed cap, configurable only if a real
/// session ever needs more.
const int diagSinkRingCapacity = 500;

final _errnoInMessage = RegExp(r'\(errno (\d+): ([^)]*)\)');

/// The errno label a FileError carries into the `fa_log_sink=fail(...)`
/// marker. The env layer embeds the raw OS reason in the message
/// (`... (errno 24: Too many open files)`, issue #2248 AC1) — that is
/// the parse here, so lib/src stays dart:io-free (fake envs in tests
/// inject the same shape).
String diagSinkErrnoLabel(FileError error) {
  final match = _errnoInMessage.firstMatch(error.message);
  if (match != null) return 'errno=${match.group(1)}: ${match.group(2)}';
  final message = error.message.trim();
  return message.isEmpty ? 'unknown' : message;
}
