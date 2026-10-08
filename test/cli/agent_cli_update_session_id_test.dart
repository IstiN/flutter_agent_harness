// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The `/update` restart's session-id resolution (issue #1377): the
/// successor argv must carry the resumable session NAME when one exists
/// (resident read, or the bounded quick probe when the name record sits
/// outside a windowed storage's resident tail), the raw id when the name
/// cannot be had (missing/unreadable file), and no id without an active
/// session. Driven through the live slash dispatch with the host-side
/// `updateCommand` seam capturing what the dispatcher resolves.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A storage whose session file does not exist on the fs: the shape
/// behind the quick-probe failure branch — [JsonlSessionRepo.sessionNameQuick]
/// throws on a missing file and the dispatcher must degrade to the raw id.
final class _MissingFileStorage implements SessionStorage {
  @override
  Future<SessionMetadata> getMetadata() async => SessionMetadata(
    id: 'sess-1',
    createdAt: DateTime.utc(2024),
    cwd: '/work',
    path: '/sessions/nope.jsonl',
  );

  @override
  Future<String?> getLeafId() async => null;

  @override
  Future<void> setLeafId(String? leafId) async {}

  @override
  Future<String> createEntryId() async => 'fake-id';

  @override
  Future<void> appendEntry(SessionRecord record) async {}

  @override
  Future<SessionRecord?> getEntry(String id) async => null;

  @override
  Future<List<SessionRecord>> findEntries(String type) async => const [];

  @override
  Future<String?> getLabel(String id) async => null;

  @override
  Future<List<SessionRecord>> getPathToRoot(String? leafId) async => const [];

  @override
  Future<List<SessionRecord>> getEntries() async => const [];
}

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  /// Boots a cli whose `/update` captures the resolved session id into
  /// [captured] instead of restarting, and drives one `/update` through
  /// the live dispatcher after swapping in [session].
  Future<String?> driveUpdate({Session? session}) async {
    String? captured = 'not-dispatched';
    final fake = FakeStreamFunction([textTurn('hi')]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        updateCommand: (sessionId) async => captured = sessionId,
      ),
      io: io,
      streamFunction: fake.call,
    );
    final run = cli.run();
    await waitForIt(() => io.out.toString().contains('fa> '));
    // Pass-through: null clears the boot-initialized session (test 1).
    cli.sessionForTest = session;
    io.sendLine('/update');
    await waitForIt(() => captured != 'not-dispatched');
    io.sendLine('/exit');
    await run;
    return captured;
  }

  test('no active session: the successor argv carries no session id', () async {
    expect(await driveUpdate(), isNull);
  });

  test('a named session resolves to its NAME', () async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final session = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work'),
    );
    await session.appendSessionName('work');

    expect(await driveUpdate(session: session), 'work');
  });

  test('a session file that cannot be probed degrades to the raw id', () async {
    expect(await driveUpdate(session: Session(_MissingFileStorage())), 'sess-1');
  });

  test(
    'a marathon session resolves via the quick probe when the name is '
    'outside the resident window (#503 shape)',
    () async {
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendSessionName('work');
      final bulk = 'x' * 32768;
      for (var i = 0; i < 300; i++) {
        await session.appendMessage(UserMessage.text('old $i $bulk'));
      }
      final kept = await session.appendMessage(UserMessage.text('kept'));
      await session.appendCompaction(
        summary: 'older turns compacted',
        firstKeptEntryId: kept,
        tokensBefore: 100000,
      );
      for (var i = 0; i < 10; i++) {
        await session.appendMessage(UserMessage.text('tail $i $bulk'));
      }

      expect(await driveUpdate(session: session), 'work');
    },
  );
}
