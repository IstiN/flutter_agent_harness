import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// In-memory [CliIO] inner delegate: captures both output channels and
/// reports a fixed surface, so the tee's delegation is observable.
class _FakeCliIO implements CliIO {
  final _interrupts = StreamController<void>.broadcast();
  final _interruptsView = Stream<void>.empty();
  final out = StringBuffer();
  final diag = StringBuffer();

  @override
  int columns = 100;

  @override
  int rows = 30;

  @override
  bool get isInteractive => true;

  @override
  Stream<String> get lines => const Stream.empty();

  @override
  Stream<void> get interrupts => _interruptsView;

  @override
  Stream<KeyEvent> get keys => const Stream<KeyEvent>.empty();

  @override
  bool get supportsRawMode => false;

  @override
  void write(String text) => out.write(text);

  @override
  void writeln(String text) => diag.write('$text\n');

  void interrupt() => _interrupts.add(null);
}

void main() {
  group('TeeCliIO', () {
    late _FakeCliIO inner;
    late StringBuffer log;

    setUp(() {
      inner = _FakeCliIO();
      log = StringBuffer();
    });

    TeeCliIO tee() => TeeCliIO(inner, log.write);

    test('write tees the chunk verbatim and delegates', () {
      TeeCliIO(inner, log.write).write('assistant delta');
      expect(log.toString(), 'assistant delta');
      expect(inner.out.toString(), 'assistant delta');
    });

    test('writeln tees the chunk with its newline and delegates', () {
      TeeCliIO(inner, log.write).writeln('[bash] command=ls');
      expect(log.toString(), '[bash] command=ls\n');
      expect(inner.diag.toString(), '[bash] command=ls\n');
    });

    test('interleaved channels land in the log in print order', () {
      tee()
        ..writeln('[read] path=pubspec.yaml')
        ..write('Reading the manifest')
        ..writeln(' done');
      expect(
        log.toString(),
        '[read] path=pubspec.yaml\nReading the manifest done\n',
      );
    });

    test('the rest of the CliIO surface delegates to the inner io', () {
      final io = tee();
      expect(io.lines, same(inner.lines));
      expect(io.interrupts, same(inner.interrupts));
      expect(io.keys, same(inner.keys));
      expect(io.supportsRawMode, inner.supportsRawMode);
      expect(io.isInteractive, inner.isInteractive);
      expect(io.columns, 100);
      expect(io.rows, 30);
    });
  });
}
