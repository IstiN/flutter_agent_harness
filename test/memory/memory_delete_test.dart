@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('ledger clobber regression (0.2.1 append-only)', () {
    test('deleting over a legacy count-line ledger preserves every entry',
        () async {
      // Production incident 2026-09-01: a committed 144-entry DELETIONS.md
      // (legacy `count:` header) ended up as ONE entry after parallel
      // deletes — read-as-empty + read-modify-write = total tombstone loss.
      // 0.2.1 makes the ledger strictly append-only; this pins the
      // integration through OUR ExecutionEnvKbStorage adapter.
      final env = MemoryExecutionEnv();
      final controller = MemoryController(env: env);
      await controller.add(text: 'survivor note');
      await controller.add(text: 'doomed note');
      const ledgerDir = '/.fah/memory';
      final legacy = StringBuffer('---\ncount: 144\nconsolidatedUpTo: 0\n---\n');
      for (var i = 1; i <= 144; i++) {
        legacy.writeln(
          '- seq: $i | id: n_\${1000 + i} | type: note | fingerprint: abc$i | '
          'deletedAt: 2026-08-30T15:54:00.000000Z | text: old tombstone $i',
        );
      }
      await env.writeFile('$ledgerDir/DELETIONS.md', legacy.toString());
      // Fresh controller so the store re-reads the ledger from disk.
      final controller2 = MemoryController(env: env);
      final entries = await controller2.list();
      final doomed = entries.firstWhere((e) => e.text == 'doomed note');
      final result = await controller2.delete(doomed.id);
      expect(result, isNotNull);
      final after =
          (await env.readTextFile('$ledgerDir/DELETIONS.md')).valueOrNull ??
          '';
      for (var i = 1; i <= 144; i++) {
        expect(after, contains('old tombstone $i'),
            reason: 'legacy entry $i must survive');
      }
      expect(after, contains(doomed.id));
    });
  });

  test('memory_delete removes an entry by id from the project scope', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final controller = MemoryController(env: env);
    final added = await controller.add(text: 'temp fact');
    expect(await controller.delete(added.id), 'project');
    final ids = (await controller.list()).map((e) => e.id);
    expect(ids, isNot(contains(added.id)));
  });

  test('memory_delete returns null for an unknown id', () async {
    final controller = MemoryController(env: MemoryExecutionEnv(cwd: '/w'));
    expect(await controller.delete('nope'), isNull);
  });

  test('the memory_delete tool reports deletion and unknown ids', () async {
    final controller = MemoryController(env: MemoryExecutionEnv(cwd: '/work'));
    final tools = memoryTools(controller);
    final tool = tools.singleWhere((t) => t.name == 'memory_delete');
    final added = await controller.add(text: 'doomed fact');

    String content(dynamic result) =>
        result.content.whereType<TextContent>().map((b) => b.text).join();

    final ok = await tool.execute({'id': added.id}, null, null);
    expect(content(ok), contains('deleted memory (project)'));

    final miss = await tool.execute({'id': 'gone'}, null, null);
    expect(content(miss), contains('error: no memory entry'));

    final noId = await tool.execute({}, null, null);
    expect(content(noId), contains('error: id is required'));
  });
}
