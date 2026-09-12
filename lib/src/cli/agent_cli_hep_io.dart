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
