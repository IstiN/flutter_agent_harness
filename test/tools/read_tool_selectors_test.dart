import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:image/image.dart';
import 'package:test/test.dart';

String _text(ToolExecutionResult result) {
  return result.content.whereType<TextContent>().map((b) => b.text).join();
}

Uint8List _pngBytes() {
  final image = Image(width: 2, height: 2);
  return Uint8List.fromList(encodePng(image));
}

void main() {
  group('readFileTool selectors', () {
    late MemoryExecutionEnv env;
    late AgentTool tool;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      tool = readFileTool(env);
    });

    test('reads an inclusive range with :A-B', () async {
      await env.writeFile('f.txt', 'a\nb\nc\nd\ne');
      final result = await tool.execute({'path': 'f.txt:2-4'}, null, null);
      expect(
        _text(result),
        'b\nc\nd\n\n[1 more lines in file. Use offset=5 to continue.]',
      );
    });

    test('reads start+count with :A+C', () async {
      await env.writeFile('f.txt', 'a\nb\nc\nd\ne');
      final result = await tool.execute({'path': 'f.txt:2+3'}, null, null);
      expect(
        _text(result),
        'b\nc\nd\n\n[1 more lines in file. Use offset=5 to continue.]',
      );
    });

    test('reads from a line to EOF with :N', () async {
      await env.writeFile('f.txt', 'a\nb\nc');
      final result = await tool.execute({'path': 'f.txt:2'}, null, null);
      expect(_text(result), 'b\nc');
    });

    test('reads the .. alias', () async {
      await env.writeFile('f.txt', 'a\nb\nc\nd');
      final result = await tool.execute({'path': 'f.txt:2..3'}, null, null);
      expect(
        _text(result),
        'b\nc\n\n[1 more lines in file. Use offset=4 to continue.]',
      );
    });

    test('a single range past EOF returns a graceful note', () async {
      await env.writeFile('f.txt', 'a\nb');
      final result = await tool.execute({'path': 'f.txt:5'}, null, null);
      expect(
        _text(result),
        'Line 5 is beyond end of file (2 lines total). Use :1 to read '
        'from the start, or :2 to read the last line.',
      );
    });

    test('throws on an invalid selector', () async {
      await env.writeFile('f.txt', 'a\nb');
      expect(
        tool.execute({'path': 'f.txt:0-2'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Line selector 0 is invalid'),
          ),
        ),
      );
    });

    test('rejects offset/limit combined with a selector', () async {
      await env.writeFile('f.txt', 'a\nb');
      expect(
        tool.execute({'path': 'f.txt:1-2', 'offset': 1}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('offset/limit cannot be combined with a path selector'),
          ),
        ),
      );
    });

    group('multi-range', () {
      test('renders blocks joined by an elision separator', () async {
        await env.writeFile('f.txt', 'a\nb\nc\nd\ne\nf');
        final result = await tool.execute(
          {'path': 'f.txt:1-2,4-5'},
          null,
          null,
        );
        expect(_text(result), 'a\nb\n\n…\n\nd\ne');
      });

      test('merges overlapping and out-of-order ranges', () async {
        await env.writeFile('f.txt', 'a\nb\nc\nd\ne');
        final result = await tool.execute(
          {'path': 'f.txt:4-5,2-3,3-4'},
          null,
          null,
        );
        expect(_text(result), 'b\nc\nd\ne');
      });

      test('reports ranges past EOF as skipped notices', () async {
        await env.writeFile('f.txt', 'a\nb\nc');
        final result = await tool.execute(
          {'path': 'f.txt:1-2,8-9'},
          null,
          null,
        );
        expect(
          _text(result),
          'a\nb\n[Range 8-9 is beyond end of file (3 lines total); skipped]',
        );
      });

      test('an open-ended range absorbs later ranges', () async {
        await env.writeFile('f.txt', 'a\nb\nc\nd');
        final result = await tool.execute({'path': 'f.txt:2-,1-2'}, null, null);
        // Sorted to (1-2, 2-) and merged into a single open range from 1.
        expect(_text(result), 'a\nb\nc\nd');
      });
    });

    group(':raw', () {
      test('returns the whole file verbatim without notices', () async {
        final content = List.generate(2100, (i) => 'l${i + 1}').join('\n');
        await env.writeFile('big.txt', content);
        final result = await tool.execute({'path': 'big.txt:raw'}, null, null);
        final text = _text(result);
        expect(text, startsWith('l1\n'));
        expect(text, isNot(contains('[Showing lines')));
        expect(text, isNot(contains('to continue')));
        // Truncation still caps the payload, silently.
        expect(text, isNot(contains('l2001')));
      });

      test('returns exact lines for :raw:A-B with no notices', () async {
        await env.writeFile('f.txt', 'a\nb\nc\nd');
        final result = await tool.execute(
          {'path': 'f.txt:raw:2-3'},
          null,
          null,
        );
        expect(_text(result), 'b\nc');
        final swapped = await tool.execute(
          {'path': 'f.txt:2-3:raw'},
          null,
          null,
        );
        expect(_text(swapped), 'b\nc');
      });

      test('a limited single range emits a notice unless raw', () async {
        await env.writeFile('f.txt', 'a\nb\nc\nd\ne');
        final ranged = await tool.execute({'path': 'f.txt:2-3'}, null, null);
        expect(
          _text(ranged),
          'b\nc\n\n[2 more lines in file. Use offset=4 to continue.]',
        );
        final raw = await tool.execute({'path': 'f.txt:2-3:raw'}, null, null);
        expect(_text(raw), 'b\nc');
      });

      test('multi-range raw joins blocks with the separator', () async {
        await env.writeFile('f.txt', 'a\nb\nc\nd\ne');
        final result = await tool.execute(
          {'path': 'f.txt:1-1,4-4:raw'},
          null,
          null,
        );
        expect(_text(result), 'a\n\n…\n\nd');
      });
    });

    group('hashline interplay', () {
      late HashlineSnapshotStore store;

      setUp(() {
        store = HashlineSnapshotStore();
        tool = readFileTool(env, snapshots: store);
      });

      test('ranged hashline reads carry real line numbers', () async {
        await env.writeFile('f.txt', 'a\nb\nc\nd\ne');
        final result = await tool.execute(
          {'path': 'f.txt:2-4', 'hashline': true},
          null,
          null,
        );
        final text = _text(result);
        expect(text, startsWith('[f.txt#'));
        expect(text, contains('\n2:b\n3:c\n4:d'));
      });

      test('multi-range hashline numbers each block', () async {
        await env.writeFile('f.txt', 'a\nb\nc\nd\ne');
        final result = await tool.execute(
          {'path': 'f.txt:1-2,4-5', 'hashline': true},
          null,
          null,
        );
        final text = _text(result);
        expect(text, startsWith('[f.txt#'));
        expect(text, contains('1:a\n2:b\n\n…\n\n4:d\n5:e'));
      });

      test('a ranged hashline read anchors edits on displayed lines', () async {
        await env.writeFile('f.txt', 'a\nb\nc\nd\ne');
        final header = _text(
          await tool.execute(
            {'path': 'f.txt:2-3', 'hashline': true},
            null,
            null,
          ),
        ).split('\n').first;
        final tag = header.substring(
          header.indexOf('#') + 1,
          header.indexOf(']'),
        );
        final edit = editFileTool(env, snapshots: store);
        final patch = '[f.txt#$tag]\nSWAP 3.=3:\n+C\n';
        await edit.execute({'patch': patch}, null, null);
        expect((await env.readTextFile('f.txt')).valueOrNull, 'a\nb\nC\nd\ne');
      });

      test(':raw suppresses the hashline header', () async {
        await env.writeFile('f.txt', 'a\nb\nc');
        final result = await tool.execute(
          {'path': 'f.txt:raw', 'hashline': true},
          null,
          null,
        );
        expect(_text(result), 'a\nb\nc');
      });

      test(':raw with a range suppresses the header too', () async {
        await env.writeFile('f.txt', 'a\nb\nc');
        final result = await tool.execute(
          {'path': 'f.txt:2-3:raw', 'hashline': true},
          null,
          null,
        );
        expect(_text(result), 'b\nc');
      });
    });

    group('images and literals', () {
      test('rejects selectors on images politely', () async {
        await env.writeBinaryFile('pic.png', _pngBytes());
        expect(
          tool.execute({'path': 'pic.png:10-20'}, null, null),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('apply to text files'),
            ),
          ),
        );
      });

      test('reads a literal file whose name matches the grammar', () async {
        await env.writeFile('test:1-2', 'literal\ncontent');
        final result = await tool.execute({'path': 'test:1-2'}, null, null);
        expect(_text(result), 'literal\ncontent');
      });
    });

    group('backward compatibility', () {
      test('offset/limit still page through a file', () async {
        await env.writeFile('f.txt', 'a\nb\nc\nd\ne');
        final result = await tool.execute(
          {'path': 'f.txt', 'offset': 2, 'limit': 2},
          null,
          null,
        );
        expect(
          _text(result),
          'b\nc\n\n[2 more lines in file. Use offset=4 to continue.]',
        );
      });

      test('offset beyond EOF still throws', () async {
        await env.writeFile('f.txt', 'a\nb');
        expect(
          tool.execute({'path': 'f.txt', 'offset': 5}, null, null),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Offset 5 is beyond end of file (2 lines total)'),
            ),
          ),
        );
      });

      test('plain reads are byte-identical to before', () async {
        await env.writeFile('notes.txt', 'line one\nline two\n');
        final result = await tool.execute({'path': 'notes.txt'}, null, null);
        expect(_text(result), 'line one\nline two\n');
      });
    });
  });
}
