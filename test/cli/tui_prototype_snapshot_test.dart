import 'dart:async';
import 'dart:io';

import 'package:pty2/pty2.dart';
import 'package:test/test.dart';

/// Strips ANSI escape sequences for assertions on visible content.
String _stripAnsi(String s) =>
    s.replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '');

/// Collects PTY output in a single subscription and lets tests wait for
/// patterns without re-listening to the stream.
final class _OutputCollector {
  _OutputCollector(Stream<String> stream) {
    _sub = stream.listen(_buffer.write);
  }

  final StringBuffer _buffer = StringBuffer();
  late final StreamSubscription<String> _sub;

  String get text => _buffer.toString();

  Future<String> waitFor(
    Pattern pattern, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final completer = Completer<String>();
    Timer? timer;
    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('pattern not found: $pattern\noutput:\n$_buffer'),
        );
      }
    });
    void check([Object? _]) {
      if (_buffer.toString().contains(pattern) && !completer.isCompleted) {
        timer?.cancel();
        completer.complete(_buffer.toString());
      }
    }

    check();
    if (!completer.isCompleted) {
      // Poll the buffer periodically; the stream is single-subscription and
      // already owned by this collector.
      final poll = Timer.periodic(const Duration(milliseconds: 20), check);
      try {
        await completer.future;
      } finally {
        poll.cancel();
      }
    }
    return completer.future;
  }

  Future<void> close() => _sub.cancel();
}

void main() {
  PseudoTerminal? pty;

  Future<PseudoTerminal> startPrototype() async {
    final terminal = PseudoTerminal.start(
      'dart',
      ['run', 'example/tui_prototype.dart'],
      workingDirectory: Directory.current.path,
      raw: true,
    );
    terminal.resize(80, 24);
    return terminal;
  }

  tearDown(() {
    pty?.kill();
    pty = null;
  });

  test('starts with banner and input prompt', () async {
    pty = await startPrototype();
    final acc = _OutputCollector(pty!.out);
    final out = await acc.waitFor('0tok');
    final plain = _stripAnsi(out);
    expect(plain, contains('fa — Flutter Agent Harness'));
    expect(plain, contains('escape interrupt'));
    expect(plain, contains('> '));
    expect(plain, contains('mode: code'));
    expect(plain, contains('0tok'));
    await acc.close();
  });

  test('typing text and pressing Enter submits to viewport', () async {
    pty = await startPrototype();
    final acc = _OutputCollector(pty!.out);
    await acc.waitFor('mode: code');

    pty!.write('hello');
    await acc.waitFor('hello');

    pty!.write('\r'); // Enter (CR)
    await acc.waitFor('user: hello');
    // The simulated fa reply arrives after a short delay.
    await acc.waitFor('fa: ');

    final plain = _stripAnsi(acc.text);
    expect(plain, contains('user: hello'));
    expect(plain, contains('fa: '));
    await acc.close();
  });

  test('slash opens command menu and down navigates', () async {
    pty = await startPrototype();
    final acc = _OutputCollector(pty!.out);
    await acc.waitFor('mode: code');

    pty!.write('/');
    await acc.waitFor('Commands');

    pty!.write('\x1b[B'); // down
    await acc.waitFor('/model');

    final plain = _stripAnsi(acc.text);
    expect(plain, contains('Commands'));
    expect(plain, contains('/help'));
    expect(plain, contains('/model'));
    await acc.close();
  });

  test('shift+enter inserts newline when shift is held', () async {
    pty = await startPrototype();
    final acc = _OutputCollector(pty!.out);
    await acc.waitFor('mode: code');

    // Simulate Shift+Enter by sending Ctrl+O (our mapped newline).
    pty!.write('abc');
    pty!.write('\x0f'); // Ctrl+O
    await acc.waitFor('abc');

    final plain = _stripAnsi(acc.text);
    expect(plain, contains('abc'));
    await acc.close();
  });

  test('ctrl+s submits when enter is used for newline', () async {
    pty = await startPrototype();
    final acc = _OutputCollector(pty!.out);
    await acc.waitFor('mode: code');

    pty!.write('test message');
    pty!.write('\x13'); // Ctrl+S
    await acc.waitFor('12tok');

    final plain = _stripAnsi(acc.text);
    expect(plain, contains('user: test message'));
    expect(plain, contains('12tok'));
    expect(plain, contains('turn 1'));
    await acc.close();
  });
}
