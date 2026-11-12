// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// `fa wire-serve` boot refusal arms (#428 + #2138): the lease gate runs
/// BEFORE any transport starts — a blocked boot refuses with the banner
/// (exit 3), a refused boot (the store cannot prove the session free on
/// an enforceable backend) refuses loudly — and in BOTH cases no runtime
/// exists: `onReady` never fires (a parent never reads a startup line
/// for a serve that refuses to boot) and the `serve` loop never starts.
/// Unit-level so the CRAP ratchet sees the coverage the integration run
/// cannot attribute.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  late JsonlSessionRepo repo;
  late FileSessionLeaseStore store;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO()..isInteractive = false;
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    store = FileSessionLeaseStore(env: env, now: () => _fixedWhen);
  });

  tearDown(() => io.close());

  Future<SessionMetadata> namedSession(String name) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendSessionName(name);
    return session.getMetadata();
  }

  AgentCli serveCli({
    required StreamFunction streamFunction,
    String? sessionName,
    FileSessionLeaseStore? leaseStore,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        sessionName: sessionName,
        leaseStore: leaseStore,
        processId: 4242,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  test('#2138: wire-serve boot over an unprovable session refuses — no '
      'runtime, no startup line, no serve loop', () async {
    await namedSession('serve-unprovable');
    final gate = RenameGateEnv(env, failFrom: 0, failTo: 1 << 30);
    final fake = FakeStreamFunction([textTurn('never')]);
    final cli = serveCli(
      streamFunction: fake.call,
      sessionName: 'serve-unprovable',
      leaseStore: FileSessionLeaseStore(env: gate),
    );

    var ready = false;
    var served = false;
    final exit = await cli.runWireServe(
      serve: (_) async {
        served = true;
      },
      onReady: () => ready = true,
    );

    expect(exit, 3, reason: 'a refusing serve boots no runtime');
    expect(ready, isFalse, reason: 'no startup line for a refused boot');
    expect(served, isFalse, reason: 'the transport loop never starts');
    expect(
      io.out.toString(),
      contains('refusing to serve'),
      reason: 'the loud refusal names the reason',
    );
    expect(fake.calls, 0, reason: 'no second writer ever runs');
  });

  test('wire-serve boot over a live-leased session refuses with the '
      'banner (E7, exit 3)', () async {
    final meta = await namedSession('serve-leased');
    await env.writeFile(
      store.sidecarPath(meta.path),
      const JsonEncoder.withIndent('  ').convert({
        'host': 'cli',
        'sessionId': meta.id,
        'pid': 999,
        'bootId': 'owner-boot',
        'heartbeatAt': _fixedWhen.toUtc().toIso8601String(),
        'acquiredAt': _fixedWhen.toUtc().toIso8601String(),
      }),
    );
    env.setMtime(
      store.sidecarPath(meta.path),
      _fixedWhen.millisecondsSinceEpoch,
    );

    final cli = serveCli(
      streamFunction: FakeStreamFunction([textTurn('never')]).call,
      sessionName: 'serve-leased',
      leaseStore: store,
    );

    var ready = false;
    var served = false;
    final exit = await cli.runWireServe(
      serve: (_) async {
        served = true;
      },
      onReady: () => ready = true,
    );

    expect(exit, 3);
    expect(ready, isFalse);
    expect(served, isFalse);
    expect(
      io.out.toString(),
      contains('Driven by fa CLI (pid 999)'),
      reason: 'the refusal carries the banner',
    );
    expect((await store.inspect(meta.path)).state, LeaseState.live);
  });
}

/// 14:32 local wall-clock: pins the banner text in any TZ.
final DateTime _fixedWhen = DateTime(2026, 9, 15, 14, 32);
