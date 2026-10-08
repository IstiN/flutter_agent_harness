import 'dart:convert';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'compaction/structured_resume_equivalence_test.dart' as eq;

void main() {
  test('debug eq entries', () async {
    final fs = MemoryFileSystem();
    const path = '/sessions/marathon.jsonl';
    final jsonl = eq.marathonJsonlPublic();
    // ignore: avoid_print
    print('lines=${jsonl.split('\n').length}');
    final e600line = jsonl.split('\n').firstWhere((l) => l.contains('"id":"e600"'));
    // ignore: avoid_print
    print('e600: $e600line');
    await fs.writeFile(path, jsonl);
    final storage = await JsonlSessionStorage.open(fs, path);
    final entries = await storage.getEntries();
    // ignore: avoid_print
    print('entries=${entries.length}');
    // ignore: avoid_print
    print('leaf=${await storage.getLeafId()}');
    final branch = await storage.getPathToRoot(await storage.getLeafId());
    // ignore: avoid_print
    print('branch=${branch.length} first=${branch.first.id} last=${branch.last.id}');
    final kinds = <String, int>{};
    for (final e in branch) {
      kinds[e.type] = (kinds[e.type] ?? 0) + 1;
    }
    // ignore: avoid_print
    print('kinds=$kinds');
  });
}
