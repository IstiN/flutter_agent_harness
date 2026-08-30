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

  /// The site's teal accent (#5eead4), used for the banner title.
  String teal(String text) =>
      enabled ? '\x1B[38;2;94;234;212m$text\x1B[0m' : text;

  /// The site's indigo accent-2 (#818cf8), used for tool call markers.
  String indigo(String text) =>
      enabled ? '\x1B[38;2;129;140;248m$text\x1B[0m' : text;
}

/// Reduces a provider error blob to something readable on one line:
/// unwraps OpenRouter's `metadata.raw` upstream JSON recursively, prefers
/// the most specific message, and caps the result at 300 chars.
String compactProviderError(String message) {
  Map<String, dynamic>? decodeJson(String text) {
    final start = text.indexOf('{');
    if (start < 0) return null;
    try {
      final decoded = jsonDecode(text.substring(start));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }

  String? extract(Map<String, dynamic> json) {
    final error = json['error'];
    if (error is! Map<String, dynamic>) return null;
    final metadata = error['metadata'];
    if (metadata is Map<String, dynamic>) {
      final raw = metadata['raw'];
      if (raw is String) {
        final upstream = decodeJson(raw);
        final upstreamMessage = upstream == null ? null : extract(upstream);
        if (upstreamMessage != null) {
          final provider = metadata['provider_name'];
          return provider is String
              ? '$upstreamMessage ($provider)'
              : upstreamMessage;
        }
      }
    }
    final msg = error['message'];
    return msg is String && msg.isNotEmpty ? msg : null;
  }

  var result = message;
  final json = decodeJson(message);
  final extracted = json == null ? null : extract(json);
  if (extracted != null) {
    final code = RegExp(r'^\d{3}').firstMatch(message)?.group(0);
    result = '${code != null ? '$code: ' : ''}$extracted';
  }
  if (result.length > 300) result = '${result.substring(0, 300)}…';
  return result;
}
