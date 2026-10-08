import 'dart:convert';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'compaction/structured_resume_equivalence_test.dart' as eq;

void main() {
  test('debug eq fixture', () async {
    final fs = MemoryFileSystem();
    const path = '/sessions/marathon.jsonl';
    await fs.writeFile(path, eq.marathonJsonlPublic());
    final storage = await JsonlSessionStorage.open(fs, path);
    final session = Session(storage);
    final messages = await session.buildContextMessages();
    // ignore: avoid_print
    print('count=${messages.length}');
    String textOf(dynamic m) => m is UserMessage
        ? (m.content is String
              ? m.content as String
              : (m.content as List)
                    .map((b) => b is TextContent ? b.text : b.runtimeType.toString())
                    .join('|'))
        : '-';
    final texts = [for (final m in messages) textOf(m)];
    // ignore: avoid_print
    print('has body 430: ${texts.any((t) => t.contains('body 430 '))}');
    // ignore: avoid_print
    print('has ckpt: ${texts.any((t) => t.contains(':ckpt·'))}');
    // ignore: avoid_print
    print('has body 500: ${texts.any((t) => t.contains('body 500 '))}');
    // ignore: avoid_print
    print(texts.take(2).join('\n---\n'));
  });
}
