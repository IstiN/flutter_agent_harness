// Issue #313 review E3: chat-attachment staging must serialize per host.
// The core `stageUpload` checks-then-writes, and across awaits two racing
// ops both see the name free — the second overwrites the first's file, so
// both callers reference the same path while only one payload survives.
// The SW host (agent_host.dart, a dart:js_interop surface) chains its
// staging through the pure [StageGate]; this VM suite pins the gate's
// strict ordering with bodies whose completion order differs from their
// start order — exactly the interleave shape the race needs.
import 'dart:async';

import '../src/ext_ops.dart';
import 'package:test/test.dart';

void main() {
  test('StageGate runs bodies strictly in submission order', () async {
    final gate = StageGate();
    final log = <String>[];
    final aDone = Completer<void>();

    // A starts first but finishes LAST — the race shape: while A is
    // mid-flight (inside its check-write window) B must not start.
    final a = gate.run(() async {
      log.add('a:start');
      await aDone.future; // A holds the slot until explicitly released
      log.add('a:end');
      return 'A';
    });
    final b = gate.run(() async {
      log.add('b:start');
      log.add('b:end');
      return 'B';
    });

    // Give B every chance to jump the queue.
    await Future<void>.delayed(Duration.zero);
    expect(log, ['a:start'], reason: 'B must wait for A to finish');

    aDone.complete();
    expect(await a, 'A');
    expect(await b, 'B');
    expect(log, ['a:start', 'a:end', 'b:start', 'b:end']);
  });

  test('StageGate never stalls on a failing body', () async {
    final gate = StageGate();
    await expectLater(
      gate.run(() async => throw StateError('stage failed')),
      throwsStateError,
    );
    // The next body still runs.
    expect(await gate.run(() async => 'after'), 'after');
  });
}
