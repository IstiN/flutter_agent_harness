// Issue #1498 bench: parseSessionEntryLine per record-kind + the
// repeated-window readAround cost the parse cache fixes.
//
//   dart bench/issue_1498_parse_bench.dart
//
// Reports best-of-3 wall numbers; parse is inline (executor null) so the
// numbers are parse-bound, not isolate-scheduler noise.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/session/session_chunk_reader.dart';
import 'package:flutter_agent_harness/src/session/session_storage.dart';

int _idCounter = 0;
String _rid() => 'rec${(_idCounter++).toString().padLeft(8, '0')}';

String _messageLine({
  required String role,
  required int contentBytes,
  int blocks = 2,
}) {
  final payload = 'x' * contentBytes;
  final content = [
    for (var i = 0; i < blocks; i++)
      switch (role) {
        'assistant' when i == 0 => {
          'type': 'thinking',
          'thinking': payload,
          'redacted': false,
        },
        _ => {'type': 'text', 'text': payload},
      },
  ];
  return jsonEncode({
    'type': 'message',
    'id': _rid(),
    'parentId': null,
    'timestamp': '2026-10-10T12:00:00.000Z',
    'message': {
      'role': role,
      'content': content,
      if (role == 'toolResult') 'toolCallId': 'call-$_idCounter',
      if (role == 'toolResult') 'toolName': 'bash',
      if (role == 'toolResult') 'isError': false,
      'timestamp': 1760000000000,
    },
  });
}

String _tinyLine() => jsonEncode({
  'type': 'thinking_level_change',
  'id': _rid(),
  'parentId': null,
  'timestamp': '2026-10-10T12:00:00.000Z',
  'thinkingLevel': 'off',
});

String _customLine(int contentBytes) => jsonEncode({
  'type': 'custom',
  'id': _rid(),
  'parentId': null,
  'timestamp': '2026-10-10T12:00:00.000Z',
  'customType': 'note',
  'data': 'x' * contentBytes,
});

void bench(String label, void Function() body, {int reps = 3}) {
  body();
  body();
  var best = 1 << 62;
  for (var r = 0; r < reps; r++) {
    final sw = Stopwatch()..start();
    body();
    sw.stop();
    if (sw.elapsedMicroseconds < best) best = sw.elapsedMicroseconds;
  }
  stdout.writeln('$label ${best}us');
}

Future<void> main() async {
  const scale = 1;
  final kinds = <String, List<String>>{
    'user 200B': [
      for (var i = 0; i < 200; i++)
        _messageLine(role: 'user', contentBytes: 200 * scale),
    ],
    'asst 400B': [
      for (var i = 0; i < 200; i++)
        _messageLine(role: 'assistant', contentBytes: 400 * scale),
    ],
    'toolRes 4KB': [
      for (var i = 0; i < 200; i++)
        _messageLine(role: 'toolResult', contentBytes: 4000 * scale),
    ],
    'custom 300B': [for (var i = 0; i < 200; i++) _customLine(300 * scale)],
    'tiny control': [for (var i = 0; i < 200; i++) _tinyLine()],
  };
  stdout.writeln('--- parseSessionEntryLine per kind ---');
  for (final entry in kinds.entries) {
    final lines = entry.value;
    bench(entry.key.padRight(14), () {
      for (final line in lines) {
        parseSessionEntryLine(line, 'bench.jsonl', 1);
      }
    });
  }

  // --- repeated-window readAround (the cache payoff) ---
  final fs = MemoryFileSystem();
  const path = '/sessions/bench.jsonl';
  final mixed = <String>[];
  for (var i = 0; i < 10000; i++) {
    switch (i % 10) {
      case 0:
      case 1:
      case 2:
        mixed.add(_messageLine(role: 'user', contentBytes: 200 * scale));
      case 3:
      case 4:
        mixed.add(_messageLine(role: 'assistant', contentBytes: 400 * scale));
      case 5:
      case 6:
      case 7:
        mixed.add(_messageLine(role: 'toolResult', contentBytes: 4000 * scale));
      case 8:
        mixed.add(_customLine(300 * scale));
      default:
        mixed.add(_tinyLine());
    }
  }
  final write = await fs.writeFile(
    path,
    '{"type":"session_header_only"}\n${mixed.join('\n')}\n',
  );
  write.getOrThrow();
  final reader = SessionChunkReader(fs: fs, path: path);
  final info = (await reader.stat())!;
  stdout.writeln(
    '--- readAround jumps over the ${(info.size / (1 << 20)).toStringAsFixed(1)}MB session '
    '(200-record windows) ---',
  );

  // Three distinct jump targets far apart (fresh windows each visit).
  final targets =
      <int>[mixed.length ~/ 5, mixed.length ~/ 2, 4 * mixed.length ~/ 5].map((
        lineIdx,
      ) {
        // Byte offset of the line: header + joined lengths + newlines.
        var offset = '{"type":"session_header_only"}\n'.length;
        for (var i = 0; i < lineIdx; i++) {
          offset += mixed[i].length + 1;
        }
        return offset;
      }).toList();

  Future<int> jumpBatch() async {
    final sw = Stopwatch()..start();
    for (var round = 0; round < 10; round++) {
      for (final target in targets) {
        await reader.readAround(target);
      }
    }
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  final cold = await jumpBatch();
  final warm = await jumpBatch();
  final warm2 = await jumpBatch();
  final bestWarm = [warm, warm2].reduce((a, b) => a < b ? a : b);
  stdout.writeln(
    '30 readAround jumps: cold ${cold}ms, warm ${bestWarm}ms '
    '(cache hits: ${reader.parseCacheHitCount}, misses: ${reader.parseCacheMissCount})',
  );
}
