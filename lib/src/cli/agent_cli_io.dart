// The CLI IO surface, split out of `agent_cli.dart` to keep that file
// under the repo's 2800-line size gate. Same library (a `part of`), so
// the adapters stay library-private while every part file sees them.
part of 'agent_cli.dart';

/// Terminal IO abstracted for testability.
///
/// The real implementation (in `bin/fah.dart`) binds [lines] to stdin,
/// [write]/[writeln] to stdout, and [interrupts] to SIGINT; tests substitute
/// scripted lines and capture output in memory.
///
/// The two output methods are separate channels: [write] carries the primary
/// stream (assistant text deltas, the input prompt), [writeln] carries
/// one-line diagnostics (tool indicators, notices, errors). The interactive
/// terminal merges both on stdout; a headless host routes [writeln] to
/// stderr so stdout stays pipeable.
abstract interface class CliIO {
  /// User-typed input lines, without the trailing newline.
  Stream<String> get lines;

  /// Cancel signals (Ctrl-C). Each event aborts the current run.
  Stream<void> get interrupts;

  /// Raw key events when the terminal is in raw mode. Non-raw hosts (tests,
  /// headless, web) provide an empty stream.
  Stream<KeyEvent> get keys;

  /// Whether the underlying terminal supports raw-mode character input with
  /// ANSI escape sequences. True for dart:io terminals; false for tests.
  bool get supportsRawMode;

  /// Writes [text] without a trailing newline (streaming deltas).
  void write(String text);

  /// Writes [text] followed by a newline.
  void writeln(String text);

  /// Whether a human is present to answer approval prompts (a real terminal,
  /// not piped input). When false, prompt-policy tool calls are denied with
  /// a reason — the safe non-interactive default.
  bool get isInteractive;

  /// Terminal width in columns. Non-TUI hosts use the 80-column default.
  int get columns => 80;

  /// Terminal height in rows. Non-TUI hosts use the 24-row default.
  int get rows => 24;
}

/// The default system prompt for the CLI agent.
String defaultAgentCliSystemPrompt(String cwd) =>
    defaultAgentMode(cwd).systemPrompt;

/// Adapts [CliIO] to the [PluginIO] surface exposed to plugins.
final class _PluginIO implements PluginIO {
  _PluginIO(this._io);

  final CliIO _io;

  @override
  void write(String text) => _io.write(text);

  @override
  void writeln(String text) => _io.writeln(text);
}

/// Wraps another [CliIO] and routes [write]/[writeln] into the active
/// [FaTuiController] output history while it is running. Input and interrupt
/// streams are delegated unchanged.
final class _TuiCliIO implements CliIO {
  _TuiCliIO(this._delegate);

  final CliIO _delegate;
  FaTuiController? _tui;

  @override
  Stream<String> get lines => _delegate.lines;

  @override
  Stream<void> get interrupts => _delegate.interrupts;

  @override
  Stream<KeyEvent> get keys => _delegate.keys;

  @override
  bool get supportsRawMode => _delegate.supportsRawMode;

  @override
  bool get isInteractive => _delegate.isInteractive;

  @override
  int get columns => _delegate.columns;

  @override
  int get rows => _delegate.rows;

  @override
  void write(String text) {
    final tui = _tui;
    if (tui != null) {
      // StreamTrace render mark (diagnostic, no-op unless active): text
      // and thinking deltas both reach the screen through this seam in
      // TUI mode — the emit→render gap names the loop/UI cost. Only the
      // sendOutput branch marks: when the TUI is not attached yet this
      // write delegates to the raw terminal IO, whose own write carries
      // the mark — a surface write is never double-counted.
      StreamTrace.mark(StreamTraceMark.render, '+${text.length}ch');
      tui.sendOutput(text);
    } else {
      _delegate.write(text);
    }
  }

  @override
  void writeln(String text) {
    final tui = _tui;
    if (tui != null) {
      tui.sendOutput(text, newline: true);
    } else {
      _delegate.writeln(text);
    }
  }
}

/// Minimal ANSI styling helper. When [enabled] is false all methods return
/// the input unchanged, which keeps tests deterministic and avoids escape
/// sequences in headless / piped output.
final class _Style implements TuiStyle {
  _Style({required this.enabled});
  final bool enabled;

  String _wrap(String text, String code) =>
      enabled ? '\x1B[${code}m$text\x1B[0m' : text;

  @override
  String bold(String text) => _wrap(text, '1');
  @override
  String dim(String text) => _wrap(text, '2');
  String italic(String text) => _wrap(text, '3');
  String underline(String text) => _wrap(text, '4');
  @override
  String cyan(String text) => _wrap(text, '36');
  @override
  String green(String text) => _wrap(text, '32');
  @override
  String yellow(String text) => _wrap(text, '33');
  String red(String text) => _wrap(text, '31');
  @override
  String magenta(String text) => _wrap(text, '35');

  /// The theme's first accent (fg only), used for the banner title.
  String teal(String text) => enabled ? tuiAccentSoft(text) : text;

  /// The theme's second accent (fg only), used for tool call markers.
  String indigo(String text) => enabled ? tuiAccent2Soft(text) : text;
}

/// Run-notice wiring for [AgentCli], split from agent_cli.dart to keep it
/// under the repo's 2800-line size gate. Same library (a `part of`), so
/// the extension sees the class's private members.
extension AgentCliRunNotices on AgentCli {
  /// Test hook: wires the run notices without a full [AgentCli.run] (the
  /// size-gate split moved them beyond a plain unit test's reach).
  void wireRunNoticesForTesting() {
    _wireTransientRetryNotice();
    _wireImageDropNotice();
    _wireImageCapLearnedNotice();
    _wireTextOnlyImageDropNotice();
    _wireDeliverySloNotice();
    _wireOperativePinNotice();
  }

  /// Transient network retry visibility (the Wi-Fi-switch case): the
  /// retry itself lives in providerStreamFunction; here it gets a voice —
  /// a dim transcript line + an fa.log entry instead of a silent 5s pause.
  ///
  /// gh-1602: a rate-limit-class retry (the ladder's 429 backoff) says
  /// `rate limited` instead of `connection lost` and appends the hidden
  /// `429_retry` record to the session JSONL — the post-mortem surface
  /// that shows a quota blip was absorbed instead of killing the trial.
  void _wireTransientRetryNotice() {
    transientRetryNotice = (attempt, maxAttempts, delay, reason) {
      // A zero delay is not a retry schedule — it's the connect-stall
      // janitor reporting an abandoned attempt that answered late
      // (issue #1121): drop the retry tail for it.
      final retryTail = delay == Duration.zero
          ? ''
          : ' — retrying in ${delay.inSeconds}s '
                '(attempt ${attempt + 1}/$maxAttempts)';
      // Classification sees the FULL line the ladder passes (gh-1602
      // review r1 thread 5): the ladder hands over the untruncated
      // provider error, so rate-limit wording past the display cap still
      // reads as rate limited and lands in the 429_retry record.
      // Truncation is display-only ([_shortNoticeLine]).
      final rateLimited = matchesRateLimitWording(reason);
      final line = _shortNoticeLine(reason);
      io.writeln(
        _style.dim(
          '${rateLimited ? '[net] rate limited' : '[net] connection lost'} '
          '($line)$retryTail',
        ),
      );
      _logDiagnostic(
        'transient retry sid=$_logSid attempt=${attempt + 1}/$maxAttempts '
        'reason=$line',
      );
      if (rateLimited) {
        _recordRateLimitRetry(attempt, maxAttempts, delay, line);
      }
    };
  }

  /// The display-only truncation for a notice reason: the first line,
  /// bounded at 120 chars like the ladder's per-attempt evidence log.
  /// Classification never sees this — the notice's reason arrives
  /// untruncated and is classified whole (gh-1602 review r1 thread 5).
  String _shortNoticeLine(String text) {
    final line = text.split('\n').first;
    return line.length <= 120 ? line : '${line.substring(0, 120)}...';
  }

  /// Appends the `429_retry` session record (gh-1602) for a rate-limit
  /// retry the ladder announced. Best-effort — a persist failure never
  /// takes the run down (the task-ledger convention); the fa.log entry
  /// above already carries the facts.
  void _recordRateLimitRetry(
    int attempt,
    int maxAttempts,
    Duration delay,
    String reason,
  ) {
    final session = _session;
    if (session == null) return;
    unawaited(
      session
          .appendCustomEntry(
            customType: rateLimitRetryRecordType,
            data: {
              // The notice's attempt is the 1-based attempt that JUST
              // FAILED — the count of rate-limit attempts consumed when
              // the retry was scheduled (the notice contract). The faces
              // render attempt + 1, the retry about to run ("attempt
              // 2/4"); the record keeps the contract value so the
              // transcript, fa.log and this record tell one story
              // (gh-1602 review r1 thread 1).
              'attempt': attempt,
              'max_attempts': maxAttempts,
              // 0 = an immediate replay — the watchdog janitor or a
              // mid-answer resume. A cancelled wait records nothing (the
              // notice does not fire for it), so 0 never means "a retry
              // was scheduled and then abandoned" (gh-1602 review r1
              // thread 6).
              'delay_ms': delay.inMilliseconds,
              'reason': reason,
              'ts': DateTime.now().toIso8601String(),
            },
          )
          .then((_) {})
          .catchError((Object error) {
            _logDiagnostic('429_retry persist failed sid=$_logSid: $error');
          }),
    );
  }

  /// Image registry drop visibility (issue #171): when the per-request
  /// cap drops a history image, say so — a dim transcript line + an
  /// fa.log entry instead of a silent degradation.
  void _wireImageDropNotice() {
    imageDropNotice = (index, keyPreview) {
      io.writeln(
        _style.dim(
          '[images] dropping [Image $index] (key $keyPreview…) '
          '— per-request cap reached',
        ),
      );
      _logDiagnostic(
        'image registry drop sid=$_logSid index=$index key=$keyPreview',
      );
    };
  }

  /// Adaptive image-cap visibility (issue #1750): when a provider
  /// image-count refusal teaches the loop a smaller cap, say so before
  /// the per-image drop lines follow — never silent.
  void _wireImageCapLearnedNotice() {
    imageCapLearnedNotice = (modelId, cap) {
      io.writeln(
        _style.dim(
          '[images] provider refused: too many images for $modelId — '
          'cap learned: $cap; re-sending with fewer images',
        ),
      );
      _logDiagnostic('image cap learned sid=$_logSid model=$modelId cap=$cap');
    };
  }

  /// Skill-pin notice visibility (gh-1409 P4/P5/P6 "never silent"):
  /// budget drops, lifecycle supersedes/drops, and AC3 repairs get the
  /// same dim transcript line + fa.log entry as the image drops.
  void _wireOperativePinNotice() {
    operativePinNotice = (notice) {
      io.writeln(_style.dim('[skills] $notice'));
      _logDiagnostic('operative pin sid=$_logSid $notice');
    };
  }

  /// Text-only model image drop visibility (issue #638): when a model
  /// declared text-only forced the request-time strip, say so - a dim
  /// transcript line + an fa.log entry instead of a silent degradation.
  void _wireTextOnlyImageDropNotice() {
    textOnlyImageDropNotice = (dropped) {
      io.writeln(
        _style.dim(
          '[images] $dropped image(s) dropped — model declared text-only',
        ),
      );
      _logDiagnostic('text-only image drop sid=$_logSid count=$dropped');
    };
  }

  /// Delivery SLO visibility (issue #647 AC6): every delivery stage line
  /// lands in fa.log; a BREACH additionally surfaces as a dim transcript
  /// line (stderr in headless mode, where writeln routes) naming the
  /// stalled stage — no silent queues.
  void _wireDeliverySloNotice() {
    deliverySloSink = (line) {
      _logDiagnostic('delivery slo sid=$_logSid $line');
      if (line.contains('BREACH')) io.writeln(_style.dim(line));
    };
  }
}
