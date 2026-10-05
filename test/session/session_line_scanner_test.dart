import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/session_line_scanner.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  const path = '/sessions/scan.jsonl';

  setUp(() {
    fs = MemoryFileSystem();
  });

  Future<void> writeBytes(List<int> bytes) async {
    await fs.writeBinaryFile(path, Uint8List.fromList(bytes));
  }

  /// Scans [bytes] as a file and returns `(start, end, text)` per line.
  Future<List<(int, int, String)>> scanLines(List<int> bytes) async {
    await writeBytes(bytes);
    final scanner = SessionLineScanner(fs: fs, path: path);
    final lines = <(int, int, String)>[];
    await scanner.scan((line) async {
      lines.add((line.start, line.end, line.text));
    });
    return lines;
  }

  group('SessionLineScanner', () {
    test('yields each complete line with byte-true spans', () async {
      final a = utf8.encode('{"n":1}\n');
      final b = utf8.encode('{"n":2}\n');
      final lines = await scanLines([...a, ...b]);
      expect(lines, hasLength(2));
      expect(lines[0].$1, 0);
      expect(lines[0].$2, a.length); // just past the newline
      expect(lines[0].$3, '{"n":1}');
      expect(lines[1].$1, a.length);
      expect(lines[1].$2, a.length + b.length);
      expect(lines[1].$3, '{"n":2}');
    });

    test('yields a final line without a trailing newline', () async {
      final a = utf8.encode('one\n');
      final b = utf8.encode('two');
      final lines = await scanLines([...a, ...b]);
      expect(lines, hasLength(2));
      expect(lines.last.$3, 'two');
      expect(lines.last.$2, a.length + b.length);
    });

    test('keeps lines intact across chunk boundaries', () async {
      // One line per 1 KiB, chunk capped at 4 KiB → boundaries split lines.
      final linesIn = <String>[
        for (var i = 0; i < 20; i++) 'line-$i-${'x' * 1024}',
      ];
      final bytes = <int>[
        for (final line in linesIn) ...utf8.encode('$line\n'),
      ];
      final scanner = SessionLineScanner(
        fs: fs,
        path: path,
      );
      await writeBytes(bytes);
      final seen = <String>[];
      await scanner.scan((line) async => seen.add(line.text));
      expect(seen, linesIn);
    });

    test('a multi-byte UTF-8 character split across chunks survives',
        () async {
      final payload = 'ünïcödé-üüt' * 300; // multi-byte chars galore
      final bytes = [...utf8.encode('$payload\n')];
      // Force chunk edges mid-character: chunk of 7 bytes cuts the 2-byte
      // sequences at odd offsets.
      final scanner = SessionLineScanner(
        fs: fs,
        path: path,
        chunkBytes: 7,
      );
      await writeBytes(bytes);
      final seen = <String>[];
      await scanner.scan((line) async => seen.add(line.text));
      expect(seen, [payload]);
    });

    test('malformed UTF-8 degrades instead of failing the scan', () async {
      final bytes = <int>[...utf8.encode('ok\n'), 0xFF, 0xFE, ...'\n'.codeUnits];
      final lines = await scanLines(bytes);
      expect(lines, hasLength(2));
      expect(lines[0].$3, 'ok');
    });

    test('empty file yields no lines', () async {
      expect(await scanLines(const []), isEmpty);
    });

    test('lone newline yields one empty line', () async {
      final lines = await scanLines('\n'.codeUnits);
      expect(lines, hasLength(1));
      expect(lines.single.$3, '');
    });

    test('reports scanned byte totals', () async {
      final bytes = [...utf8.encode('a\nbb\nccc\n')];
      await writeBytes(bytes);
      final scanner = SessionLineScanner(fs: fs, path: path);
      var lines = 0;
      final result = await scanner.scan((_) async => lines++);
      expect(lines, 3);
      expect(result.bytes, bytes.length);
      expect(result.lines, 3);
    });
  });
}
