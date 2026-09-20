// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Issue #735: the TermiosGuard re-asserts the raw-mode input flags after
// every foreground tool phase — a child (pager, ssh, curses app, plain
// `stty ixon`) sharing the session tty can silently re-enable IXON, which
// turns Ctrl+S into the tty's VSTOP byte: output freezes, the 0x13 never
// reaches fa, steering dies mid-session. These tests drive the guard with
// an injected stty runner state machine (no real tty, no subprocess).

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/termios_guard.dart';
import 'package:test/test.dart';

/// Simulated tty: a set of enabled flags plus a log of every stty argv.
/// Models the machine a child corrupts (`stty ixon ixany < /dev/tty`).
class _FakeTty {
  _FakeTty({
    this.enabled = const {},
    this.failAll = false,
    this.failProbe = false,
  });

  /// Flags currently ON (bare names); everything else reads as `-flag`.
  Set<String> enabled;

  /// When set, every runner call throws like a missing stty binary.
  bool failAll;

  /// When set, the `stty -a` probe exits non-zero (e.g. no /dev/tty).
  bool failProbe;

  final calls = <List<String>>[];

  Future<ProcessResult> runner(List<String> args) async {
    calls.add(List.of(args));
    if (failAll) {
      throw const ProcessException('stty', [], 'not found');
    }
    if (args.contains('-a')) {
      if (failProbe) return ProcessResult(0, 1, '', 'stty: no tty');
      return ProcessResult(0, 0, _renderSttyA(), '');
    }
    if (args.contains('-g')) return ProcessResult(0, 0, 'saved-termios\n', '');
    // Any other call is a flag mutation (the clear list). Bare flag
    // names (add) exist only for hypothetical `stty ixon` calls — no
    // test uses them; `/dev/tty` and device flags are ignored.
    for (final arg in args) {
      if (arg.startsWith('-')) {
        enabled.remove(arg.substring(1));
      }
    }
    return ProcessResult(0, 0, '', '');
  }

  /// Renders `stty -a`-shaped output: bare flag = on, `-flag` = off, plus
  /// the cchars row (`discard = ^O`) that must NOT read as drift.
  String _renderSttyA() {
    final toggles = [
      'icrnl',
      'ixon',
      'ixoff',
      'ixany',
      'opost',
      'onlcr',
      'echo',
      'icanon',
    ];
    final flags = [
      for (final f in toggles) enabled.contains(f) ? f : '-$f',
    ].join(' ');
    return 'speed 9600 baud; rows 48; columns 160; line = 0;\n'
        'intr = ^C; quit = ^\\; erase = ^?; kill = ^U; eof = ^D;\n'
        'start = ^Q; stop = ^S; susp = ^Z; discard = ^O;\n'
        '-parenb -parodd cs8 -hupcl -cstopb cread -clocal -crtscts\n'
        '$flags\n'
        '-isig -icanon -echo iexten\n';
  }
}

void main() {
  group('TermiosGuard.reassert', () {
    test('detects drifted flags, clears them, and names the drift', () async {
      final tty = _FakeTty(); // post-boot: flags cleared
      final guard = TermiosGuard(runner: tty.runner, hasTerminal: () => true);

      // A child re-enables flow control mid-session (issue #735 repro).
      tty.enabled = {'ixon', 'ixany'};

      final result = await guard.reassert();

      expect(result.checked, isTrue);
      expect(result.driftedFlags, {'ixon', 'ixany'});
      // The re-assert cleared exactly the input-flag family.
      expect(tty.enabled, isEmpty);
      final clear = tty.calls.last;
      expect(clear, containsAll(kTermiosClearArgs));
      expect(clear.first, anyOf('-f', '-F'));
      expect(clear, contains('/dev/tty'));
    });

    test('no drift = single probe, no clear, no spam', () async {
      final tty = _FakeTty();
      final guard = TermiosGuard(runner: tty.runner, hasTerminal: () => true);

      final result = await guard.reassert();

      expect(result.checked, isTrue);
      expect(result.driftedFlags, isEmpty);
      expect(tty.calls, hasLength(1)); // the `-a` probe only
    });

    test(
      'never throws: missing stty (ProcessException) = silent no-op',
      () async {
        final tty = _FakeTty(failAll: true);
        final guard = TermiosGuard(runner: tty.runner, hasTerminal: () => true);

        final result = await guard.reassert();
        expect(result.checked, isFalse);
        expect(result.driftedFlags, isEmpty);
      },
    );

    test('never throws: probe failure (no /dev/tty) = silent no-op', () async {
      final tty = _FakeTty(failProbe: true);
      final guard = TermiosGuard(runner: tty.runner, hasTerminal: () => true);

      final result = await guard.reassert();
      expect(result.checked, isFalse);
    });

    test('no terminal (headless host) never spawns stty', () async {
      final tty = _FakeTty();
      final guard = TermiosGuard(runner: tty.runner, hasTerminal: () => false);

      final result = await guard.reassert();
      expect(result.checked, isFalse);
      expect(tty.calls, isEmpty);
    });

    test('drift parsing ignores control chars (discard = ^O)', () async {
      final tty = _FakeTty(); // discard absent on purpose
      final guard = TermiosGuard(runner: tty.runner, hasTerminal: () => true);

      final result = await guard.reassert();
      expect(
        result.driftedFlags,
        isEmpty,
        reason: 'the cchars row names `discard` bare — not a drift',
      );
    });
  });

  group('TermiosGuard.dumpSettings', () {
    test('returns the stty -a dump for /termios diagnostics', () async {
      final tty = _FakeTty();
      final guard = TermiosGuard(runner: tty.runner, hasTerminal: () => true);

      final dump = await guard.dumpSettings();
      expect(dump, contains('-ixon'));
      expect(tty.calls.single, contains('-a'));
    });

    test('null when the probe fails', () async {
      final tty = _FakeTty(failAll: true);
      final guard = TermiosGuard(runner: tty.runner, hasTerminal: () => true);

      expect(await guard.dumpSettings(), isNull);
    });
  });

  group('attachTermiosGuard', () {
    test('re-asserts after every tool call and reports drift', () async {
      final agent = _bareAgent();
      final tty = _FakeTty();
      final guard = TermiosGuard(runner: tty.runner, hasTerminal: () => true);
      final drifted = <List<String>>[];
      attachTermiosGuard(agent, guard, onDrift: drifted.add);

      // A child flipped ixon back on during the tool phase.
      tty.enabled = {'ixon'};

      final priorAfterRan = <String>[];
      agent.afterToolCall = agent.afterToolCall; // keep the guard wrap
      // Wrap order parity with attachToolPhaseLabels: the guard's
      // afterToolCall runs, then any hook attached BEFORE it.
      final guardAfter = agent.afterToolCall;
      agent.afterToolCall = (context, cancelToken) async {
        priorAfterRan.add('outer');
        return guardAfter?.call(context, cancelToken);
      };

      await agent.afterToolCall!(_afterContext('bash'), null);

      expect(drifted, [
        ['ixon'],
      ], reason: 'the drift is named once, naming the corrupting child');
      expect(tty.calls.last, containsAll(kTermiosClearArgs));
      expect(priorAfterRan, ['outer']);
      expect(tty.enabled, isEmpty);
    });

    test('guard failure never breaks the tool phase', () async {
      final agent = _bareAgent();
      final tty = _FakeTty(failAll: true);
      final guard = TermiosGuard(runner: tty.runner, hasTerminal: () => true);
      attachTermiosGuard(agent, guard);

      // Must not throw even though the runner explodes.
      await agent.afterToolCall!(_afterContext('bash'), null);
    });
  });
}

Agent _bareAgent() => Agent(
  model: const Model(
    id: 'test-model',
    api: 'test-api',
    provider: 'test',
    baseUrl: 'https://example.com',
    contextWindow: 100000,
    maxTokens: 4096,
  ),
  systemPrompt: 'test',
  streamFunction: (model, context, {cancelToken}) =>
      throw UnimplementedError('never streams in hook tests'),
  toolRegistry: ToolRegistry(const []),
);

AssistantMessage _assistant() => AssistantMessage(
  content: const [],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.now(),
);

AfterToolCallContext _afterContext(String toolName) => AfterToolCallContext(
  assistantMessage: _assistant(),
  toolCall: ToolCall(id: 'call-1', name: toolName, arguments: const {}),
  result: ToolExecutionResult.text('ok'),
  isError: false,
  context: Context(messages: const []),
);
