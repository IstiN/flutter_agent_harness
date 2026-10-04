import 'dart:convert';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:test/test.dart';

void main() {
  test('dbg header-less heal', () async {
    final fs = MemoryFileSystem();
    const path = '/sessions/r.jsonl';
    MessageRecord msg(String id, String? parent, String text) => MessageRecord(
        id: id, parentId: parent, timestamp: DateTime.utc(2026),
        message: UserMessage.text(text));
    final base = await JsonlSessionStorage.create(fs, path,
        cwd: '/work', sessionId: 'r1');
    await base.appendEntry(msg('e1', null, 'e1'));
    final segment = (await fs.readTextFile(path)).getOrThrow();
    (await fs.writeFile('$path.part-0001', segment)).getOrThrow();
    final e2line = jsonEncode(msg('e2', 'e1', 'e2').toJson());
    (await fs.writeFile(path, '$e2line\n')).getOrThrow();

    final reopened = await JsonlSessionStorage.open(fs, path);
    // ignore: avoid_print
    print('entries: ${(await reopened.getEntries()).map((e) => e.id)} quarantined=${reopened.quarantinedEntries}');
    final corrupt = await fs.exists('$path.corrupt');
    // ignore: avoid_print
    print('corrupt exists: ${corrupt.getOrThrow()}');
    if (corrupt.getOrThrow()) {
      // ignore: avoid_print
      print('corrupt: ${(await fs.readTextFile('$path.corrupt')).getOrThrow()}');
    }
    // ignore: avoid_print
    print('e2line: $e2line');
    final listing = await fs.listDir('/sessions');
    // ignore: avoid_print
    print('dir: ${listing.valueOrNull?.map((f) => f.name)}');
  });
}
