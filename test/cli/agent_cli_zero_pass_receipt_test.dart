// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-2237 — UT-4: the CLI compaction hooks' zero-pass receipt honesty.
/// An `auto-compact start` line must never be the last word: a zero-pass
/// outcome emits a terminal receipt on BOTH surfaces (the diagnostic lane
/// and a dim user-facing row, boot-cap defer precedent), while a
/// pass-carrying outcome keeps its byte-identical legacy receipt.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  late AgentCli cli;

  setUp(() async {
    env = MemoryExecutionEnv(cwd: '/work');
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    io = FakeCliIO();
    final fake = FakeStreamFunction([textTurn('ok')]);
    cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        homeDir: '/home',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: fake.call,
      version: '9.9.9-test',
    );
    // Boot and exit so the session id and the diagnostics log exist —
    // the seam below drives the same hooks a compactor run would.
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
    io.sendLine('/exit');
    await run;
  });

  test('UT-4: onDone(0) emits the no-op terminal receipt on the diagnostic '
      'lane AND as a dim user-facing row', () async {
    cli.compactionDoneForTest(
      0,
      1234,
      reason: 'basis 13300 below trigger 37500 (trigger gate)',
    );
    await cli.flushDiagnosticLog();

    final log =
        (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull ?? '';
    expect(log, contains('auto-compact done sid='));
    expect(
      log,
      contains(
        'passes=0 (no-op: basis 13300 below trigger 37500 (trigger gate))',
      ),
      reason:
          'the zero-pass outcome must terminate the receipt chain on '
          'the diagnostic lane',
    );
    final out = io.out.toString();
    expect(out, contains('no-op'));
    expect(
      out,
      contains('basis 13300 below trigger 37500 (trigger gate)'),
      reason:
          'OQ2: the no-op rides BOTH surfaces — the dim row makes '
          'the skipped work visible to the user',
    );
  });

  test('UT-4b: onDone(N>0) keeps the byte-identical legacy receipt and emits '
      'no no-op row', () async {
    cli.compactionDoneForTest(2, 999, reason: 'unused on pass runs');
    await cli.flushDiagnosticLog();

    final log =
        (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull ?? '';
    expect(log, contains('auto-compact done sid='));
    expect(log, contains('passes=2 tokens=999'));
    expect(
      io.out.toString(),
      isNot(contains('no-op')),
      reason:
          'a pass-carrying run renders its pass receipts, not a '
          'no-op row',
    );
  });
}
