// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// End-to-end tests for the gh-1745 request-blob spill wiring: with the
/// default config the CLI persists LIGHTWEIGHT `model_request_summary`
/// records (no per-message block texts) and spills the heavy payload to
/// `.fah/trajectories/<sid>/requests/`; `trajectory.requestBlobs: false`
/// restores the byte-identical legacy inline persistence.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

Future<_Rig> _rig({bool? requestBlobs, bool wireDump = false}) async {
  final env = MemoryExecutionEnv(
    cwd: '/work',
    shell: FakeShell(stdout: 'ok'),
  );
  // Suppress session-start memory maintenance so the scripted turns feed
  // only the turn under test (same pattern as agent_cli_test).
  await env.writeFile('/work/.fah/memory/.last_maintenance', '');
  final io = FakeCliIO();
  final fake = FakeStreamFunction([
    toolTurn([
      const ToolCall(id: 'c1', name: 'bash', arguments: {'command': 'ls'}),
    ]),
    textTurn('done'),
  ]);
  final cli = AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
      compactionEngine: CompactionEngine.classic,
      wireDump: wireDump,
      trajectoryRequestBlobs: requestBlobs ?? true,
    ),
    io: io,
    streamFunction: fake.call,
  );
  final run = cli.run();
  return _Rig(env, io, fake, cli, run);
}

Future<String> _sessionJsonl(_Rig rig) async {
  final repo = JsonlSessionRepo(fs: rig.env, sessionsRoot: '/sessions');
  final meta = (await repo.list(cwd: '/work')).single;
  final read = await rig.env.readTextFile(meta.path);
  return read.valueOrNull!;
}

Future<String> _sessionId(_Rig rig) async {
  final id = (await JsonlSessionRepo(
    fs: rig.env,
    sessionsRoot: '/sessions',
  ).list(cwd: '/work')).first.id;
  return id;
}

Future<void> _settle(_Rig rig) => waitForIt(
  () => rig.fake.calls >= 2 && !rig.cli.isBusy,
  reason: 'the scripted turns settle',
);

Future<void> _exit(_Rig rig) async {
  rig.io.sendLine('/exit');
  await rig.run;
  await rig.io.close();
}

String _summaryLine(String jsonl) => jsonl
    .split('\n')
    .firstWhere((line) => line.contains('"model_request_summary"'));

void main() {
  test('default config: the summary record is light and the blob carries '
      'the full detail', () async {
    final rig = await _rig();
    rig.io.sendLine('go');
    await _settle(rig);
    await _exit(rig);

    final jsonl = await _sessionJsonl(rig);
    final summary = _summaryLine(jsonl);
    expect(summary, contains('"spillFile"'));
    expect(
      summary,
      isNot(contains('"blocks"')),
      reason:
          'gh-1745: the per-message block texts must not ride the '
          'primary JSONL',
    );

    final spillPath = RegExp(
      '"spillFile":"([^"]+)"',
    ).firstMatch(summary)!.group(1)!;
    final sid = await _sessionId(rig);
    final store = TrajectoryRequestBlobStore(
      env: rig.env,
      sessionId: () => sid,
    );
    final detail = await store.readDetail(spillPath);
    expect(detail, isNotNull);
    expect(
      detail!.messages.first.blocks,
      isNotEmpty,
      reason: 'the blob carries the FULL detail',
    );
  });

  test('every request spills its own blob (2 requests → 2 files)', () async {
    final rig = await _rig();
    rig.io.sendLine('go');
    await _settle(rig);
    await _exit(rig);

    final dir = trajectoryRequestBlobDir(await _sessionId(rig));
    final listing = await rig.env.listDir(dir);
    expect(listing.valueOrNull!.length, 2);
  });

  test(
    'trajectory.requestBlobs:false restores the legacy inline record',
    () async {
      final rig = await _rig(requestBlobs: false);
      rig.io.sendLine('go');
      await _settle(rig);
      await _exit(rig);

      final jsonl = await _sessionJsonl(rig);
      final summary = _summaryLine(jsonl);
      expect(summary, isNot(contains('"spillFile"')));
      expect(summary, contains('"blocks"'));
      expect(
        (await rig.env.listDir('.fah/trajectories')).isErr,
        isTrue,
        reason: 'no blob dir is created when spilling is off',
      );
    },
  );

  test('a spilled wire dump lives in the blob, not the JSONL', () async {
    final rig = await _rig(wireDump: true);
    rig.io.sendLine('go');
    await _settle(rig);
    await _exit(rig);

    final jsonl = await _sessionJsonl(rig);
    expect(
      jsonl,
      isNot(contains('"trajectory_wire_dump"')),
      reason: 'the 2MB-capped dump must not ride the primary JSONL',
    );
    final summary = _summaryLine(jsonl);
    expect(summary, contains('"wireDumpHash"'));
    final spillPath = RegExp(
      '"spillFile":"([^"]+)"',
    ).firstMatch(summary)!.group(1)!;
    final store = TrajectoryRequestBlobStore(
      env: rig.env,
      sessionId: () => null,
    );
    final dump = await store.readWireDump(spillPath);
    expect(dump, isNotNull);
    expect(dump!.hash, isNotEmpty);
  });

  test(
    'wireDump with spilling off keeps the legacy inline dump record',
    () async {
      final rig = await _rig(requestBlobs: false, wireDump: true);
      rig.io.sendLine('go');
      await _settle(rig);
      await _exit(rig);

      expect(await _sessionJsonl(rig), contains('"trajectory_wire_dump"'));
    },
  );

  test('the first spill sweeps stale sibling sessions past the TTL '
      '(boot-time sweep, gh-1745 review)', () async {
    final rig = await _rig();
    // A dead session's blob, aged far past the 30-day TTL: no rotation
    // can ever reach it again (that session never writes).
    final stale = '.fah/trajectories/dead/requests/1.json';
    await rig.env.writeFile(stale, '{"detail":{}}');
    rig.env.setMtime(
      stale,
      DateTime.now().subtract(const Duration(days: 40)).millisecondsSinceEpoch,
    );

    rig.io.sendLine('go');
    await _settle(rig);
    await _exit(rig);

    expect(
      (await rig.env.listDir('.fah/trajectories/dead/requests')).valueOrNull,
      isEmpty,
      reason: 'the ended session keeps nothing past the TTL',
    );
  });
}

class _Rig {
  _Rig(this.env, this.io, this.fake, this.cli, this.run);

  final MemoryExecutionEnv env;
  final FakeCliIO io;
  final FakeStreamFunction fake;
  final AgentCli cli;
  final Future<void> run;
}
