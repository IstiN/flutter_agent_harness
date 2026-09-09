import 'agent_cli.dart';
import 'key_event.dart';

/// Writes one teed chunk — exactly the text the CLI produced, `writeln`
/// chunks already carrying their trailing newline. The executable wires
/// this to an unbuffered file sink (`bin/fah.dart` owns `dart:io`), so
/// every chunk reaches the OS as it is produced and a `tail -f` on the
/// log streams the trace live.
typedef LogTeeSink = void Function(String text);

/// [CliIO] decorator teeing the rendered session trace to a file
/// (`--log-file`): every [write]/[writeln] chunk is appended to [sink]
/// verbatim and then delegated unchanged, so the log mirrors the trace —
/// assistant text, tool lines, diagnostics — while stdout/stderr behave
/// exactly as before. Input, interrupts and the rest of the [CliIO]
/// surface delegate straight through.
final class TeeCliIO implements CliIO {
  TeeCliIO(this._inner, this._sink);

  final CliIO _inner;
  final LogTeeSink _sink;

  @override
  void write(String text) {
    _sink(text);
    _inner.write(text);
  }

  @override
  void writeln(String text) {
    _sink('$text\n');
    _inner.writeln(text);
  }

  @override
  Stream<String> get lines => _inner.lines;

  @override
  Stream<void> get interrupts => _inner.interrupts;

  @override
  Stream<KeyEvent> get keys => _inner.keys;

  @override
  bool get supportsRawMode => _inner.supportsRawMode;

  @override
  bool get isInteractive => _inner.isInteractive;

  @override
  int get columns => _inner.columns;

  @override
  int get rows => _inner.rows;
}
