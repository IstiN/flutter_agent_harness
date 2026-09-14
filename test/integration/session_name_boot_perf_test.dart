/// Perf gates for issue #369 (the card's AC3/AC4): `fa --session <name>`
/// over a 300-session store holding two 400 MB giants with NO
/// `session_info` must resolve through the real AgentCli boot path in
/// <= 2 s wall — the giants are excluded by two bounded byte probes
/// (head + tail window), never a full-file parse. On pre-fix main the
/// per-session chunk-paged scan JSON-decodes every giant body, which
/// blows the budget by an order of magnitude (~36 s reported).
///
/// The fixture is generated dynamically into a temp sessions root
/// (streamed to disk, like the #262 gate) and driven in-process —
/// [AgentCli.run] IS the boot path the binary wires, without the
/// VM/kernel compile noise a spawned process would add to the budget.
@TestOn('vm')
@Tags(['integration', 'perf'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/env/io_execution_env.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

/// Sessions seeded besides the target: AC3's store size.
const _seededSessions = 300;

/// Giant size: the two pathological files carry no session_info at all.
const _giantBytes = 400 << 20;

/// Append chunk for the giant bodies.
const _chunkBytes = 8 << 20;

Future<void> main() async {
  late Directory tempHome;
  late Directory sessionsRoot;
  late LocalExecutionEnv env;
  late String targetId;
  final giantPaths = <String>[];

  setUpAll(() async {
    tempHome = Directory.systemTemp.createTempSync('fa_perf_369_home_');
    sessionsRoot = Directory.systemTemp.createTempSync('fa_perf_369_sess_');
    env = LocalExecutionEnv(cwd: tempHome.path);
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionsRoot.path);
    for (var i = 0; i < _seededSessions; i++) {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: tempHome.path),
      );
      await session.appendSessionName('seed-$i');
    }
    final named = await repo.create(
      JsonlSessionCreateOptions(cwd: tempHome.path),
    );
    await named.appendSessionName('existing-name');
    targetId = (await named.getMetadata()).id;
    // Two 400 MB giants, no session_info anywhere: name resolution must
    // exclude them from the probe windows alone.
    for (final giant in ['giant-a', 'giant-b']) {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: tempHome.path, id: giant),
      );
      await session.appendMessage(UserMessage.text('boot'));
      final metadata = await session.getMetadata();
      final sink = File(metadata.path).openWrite(mode: FileMode.append);
      final chunk = '${'x' * _chunkBytes}\n';
      final chunks = (_giantBytes / (_chunkBytes + 1)).ceil();
      for (var i = 0; i < chunks; i++) {
        sink.write(chunk);
      }
      await sink.flush();
      await sink.close();
      giantPaths.add(metadata.path);
    }
  });

  tearDownAll(() async {
    tempHome.deleteSync(recursive: true);
    sessionsRoot.deleteSync(recursive: true);
  });

  test('fixture sanity: the store really holds 300 + 2 x 400 MB', () {
    expect(giantPaths, hasLength(2));
    for (final path in giantPaths) {
      expect(
        File(path).lengthSync(),
        greaterThan(_giantBytes - (1 << 20)),
        reason: '$path must be 400 MB class',
      );
    }
  });

  test(
    'AC3: fa --session existing-name boots <= 2 s over 300 + 2 giants',
    () async {
      final elapsed = await _bootWallClock(
        env,
        sessionsRoot,
        'existing-name',
        resolvedId: targetId,
      );
      expect(elapsed, lessThan(const Duration(seconds: 2)));
    },
  );

  test('AC4: fa --session brand-new-name stays <= 2 s (all excluded, '
      'then created)', () async {
    final elapsed = await _bootWallClock(env, sessionsRoot, 'brand-new-name');
    expect(elapsed, lessThan(const Duration(seconds: 2)));
  });
}

/// Boots the real CLI against the seeded store and returns the wall
/// time until the first turn completes — the cold-start budget AC3/AC4
/// gate on. With [resolvedId], the boot banner must show that session
/// (the name actually resolved to the seeded target).
Future<Duration> _bootWallClock(
  LocalExecutionEnv env,
  Directory sessionsRoot,
  String sessionName, {
  String? resolvedId,
}) async {
  final io = FakeCliIO();
  addTearDown(io.close);
  final watch = Stopwatch()..start();
  final cli = AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: sessionsRoot.path,
      providerKind: 'openai-completions',
      sessionName: sessionName,
    ),
    io: io,
    streamFunction: FakeStreamFunction([textTurn('ok')]).call,
  );
  final run = cli.run();
  await waitForIt(
    () => io.out.toString().contains('ok'),
    reason: 'the first turn completes after boot',
  );
  final elapsed = watch.elapsed;
  final out = io.out.toString();
  expect(out, contains('ok'), reason: 'the boot really completed');
  if (resolvedId != null) expect(out, contains(resolvedId));
  io.sendLine('/exit');
  await run;
  return elapsed;
}
