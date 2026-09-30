import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

// TEMP repro for PR review: hard-cap truncation breaks the parent chain
// so a REOPENED storage throws from getPathToRoot / getBranch.
void main() {
  late MemoryFileSystem fs;
  const path = '/sessions/repro.jsonl';

  setUp(() {
    fs = MemoryFileSystem();
  });

  test('reopen after hard-cap truncation: getPathToRoot must not throw',
      () async {
    final created = await JsonlSessionStorage.create(
      fs,
      path,
      cwd: '/work',
      sessionId: 'r1',
    );
    final storage = created.withRotationLimits(
      rotateBytes: 10 << 20,
      hardCapBytes: 900,
    );
    await storage.appendEntry(
      MessageRecord(
        id: 'r1',
        parentId: null,
        timestamp: DateTime.utc(2026),
        message: UserMessage.text('a' * 200),
      ),
    );
    await storage.appendEntry(
      MessageRecord(
        id: 'r2',
        parentId: 'r1',
        timestamp: DateTime.utc(2026),
        message: UserMessage.text('b' * 200),
      ),
    );
    await storage.appendEntry(
      MessageRecord(
        id: 'r3',
        parentId: 'r2',
        timestamp: DateTime.utc(2026),
        message: UserMessage.text('c' * 200),
      ),
    );
    // In-memory still fine.
    expect((await storage.getPathToRoot('r3')).map((e) => e.id).toList(),
        ['r1', 'r2', 'r3']);

    final primary = (await fs.readTextFile(path)).getOrThrow();
    // ignore: avoid_print
    print('--- primary after truncation ---\n$primary');

    final reopened = await JsonlSessionStorage.open(fs, path);
    final entries = (await reopened.getEntries()).map((e) => e.id).toList();
    // ignore: avoid_print
    print('--- reopened entries: $entries');
    final leaf = await reopened.getLeafId();
    // ignore: avoid_print
    print('--- reopened leaf: $leaf');
    final chain = await reopened.getPathToRoot(leaf);
    // ignore: avoid_print
    print('--- reopened chain: ${chain.map((e) => e.id).toList()}');
    expect(chain.map((e) => e.id), ['r1', 'r2', 'r3'],
        reason: 'parent chain must survive truncation on reopen');
  });
}
