import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('HashlinePatch.parse: section splitting', () {
    test('single section with tag', () {
      final patch = HashlinePatch.parse('[src/foo.ts#1A2B]\nDEL 2');
      expect(patch.sections, hasLength(1));
      final section = patch.sections[0];
      expect(section.path, 'src/foo.ts');
      expect(section.fileHash, '1A2B');
      expect(section.diff, 'DEL 2');
    });

    test('multiple sections split on headers', () {
      final patch = HashlinePatch.parse(
        '[a.ts#1A2B]\nDEL 1\n[b.ts#3C4D]\nDEL 2',
      );
      expect(patch.sections, hasLength(2));
      expect(patch.sections[0].path, 'a.ts');
      expect(patch.sections[1].path, 'b.ts');
    });

    test('lowercase tags are normalized to uppercase', () {
      final patch = HashlinePatch.parse('[a.ts#1a2b]\nDEL 1');
      expect(patch.sections[0].fileHash, '1A2B');
    });

    test('sections without a tag parse (the patcher rejects them later)', () {
      final patch = HashlinePatch.parse('[a.ts]\nDEL 1');
      expect(patch.sections[0].fileHash, isNull);
    });

    test('paths may contain whitespace', () {
      final patch = HashlinePatch.parse(
        '[OneDrive - Company/file.ts#1A2B]\nDEL 1',
      );
      expect(patch.sections[0].path, 'OneDrive - Company/file.ts');
      expect(patch.sections[0].fileHash, '1A2B');
    });

    test('empty sections (no ops) are dropped', () {
      final patch = HashlinePatch.parse('[a.ts#1A2B]\n[b.ts#3C4D]\nDEL 1');
      expect(patch.sections, hasLength(1));
      expect(patch.sections[0].path, 'b.ts');
    });

    test('envelope markers wrap the whole patch', () {
      final patch = HashlinePatch.parse(
        '*** Begin Patch\n[a.ts#1A2B]\nDEL 1\n*** End Patch\n[b.ts#3C4D]\nDEL 2',
      );
      expect(patch.sections, hasLength(1));
      expect(patch.sections[0].path, 'a.ts');
    });

    test('leading blank lines are skipped', () {
      final patch = HashlinePatch.parse('\n\n[a.ts#1A2B]\nDEL 1');
      expect(patch.sections, hasLength(1));
    });
  });

  group('HashlinePatch.parse: same-path merging', () {
    test('consecutive sections for one path merge into one batch', () {
      final patch = HashlinePatch.parse(
        '[a.ts#1A2B]\nDEL 1\n[a.ts#1A2B]\nDEL 3',
      );
      expect(patch.sections, hasLength(1));
      expect(
        [
          for (final e in patch.sections[0].edits)
            (e as HashlineDelete).anchor.line,
        ],
        [1, 3],
      );
    });

    test(
      'interleaved sections for one path merge, order by first occurrence',
      () {
        final patch = HashlinePatch.parse(
          '[a.ts#1A2B]\nDEL 1\n[b.ts#3C4D]\nDEL 1\n[a.ts#1A2B]\nDEL 2',
        );
        expect([for (final s in patch.sections) s.path], ['a.ts', 'b.ts']);
        expect(patch.sections[0].edits, hasLength(2));
      },
    );

    test('conflicting tags for one path are rejected', () {
      expect(
        () => HashlinePatch.parse('[a.ts#1A2B]\nDEL 1\n[a.ts#3C4D]\nDEL 2'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('Conflicting hashline snapshot tags'),
          ),
        ),
      );
    });

    test('a tagless section adopts the tag of a tagged twin', () {
      final patch = HashlinePatch.parse('[a.ts]\nDEL 1\n[a.ts#1A2B]\nDEL 2');
      expect(patch.sections[0].fileHash, '1A2B');
    });
  });

  group('HashlinePatch.parse: header recovery and fallback', () {
    test('apply_patch noise is stripped from the path', () {
      final patch = HashlinePatch.parse('[Update File:src/foo.ts#1A2B]\nDEL 1');
      expect(patch.sections[0].path, 'src/foo.ts');
    });

    test('hybrid *** prefix is stripped', () {
      final patch = HashlinePatch.parse('[***foo.ts#1A2B]\nDEL 1');
      expect(patch.sections[0].path, 'foo.ts');
    });

    test('quoted paths are unquoted', () {
      final patch = HashlinePatch.parse('["my file.ts"#1A2B]\nDEL 1');
      expect(patch.sections[0].path, 'my file.ts');
    });

    test('a `#` inside the path body is malformed', () {
      expect(
        () => HashlinePatch.parse('[foo#bar#1A2B]\nDEL 1'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('Input header must be'),
          ),
        ),
      );
    });

    test('short tags are malformed, not silently accepted', () {
      expect(
        () => HashlinePatch.parse('[foo.ts#1A2]\nDEL 1'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('Input header must be'),
          ),
        ),
      );
    });

    test('missing header on the first line is a focused error', () {
      expect(
        () => HashlinePatch.parse('DEL 1'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('input must begin with "[PATH#HASH]"'),
          ),
        ),
      );
    });

    test('unified-diff contamination on the first line', () {
      expect(
        () => HashlinePatch.parse('@@ -1,2 +1,2 @@\nDEL 1'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('unified-diff hunk header'),
          ),
        ),
      );
    });

    test('fallbackPath wraps a headerless body that has ops', () {
      final patch = HashlinePatch.parse('DEL 1', fallbackPath: 'a.ts');
      expect(patch.sections, hasLength(1));
      expect(patch.sections[0].path, 'a.ts');
      expect(patch.sections[0].fileHash, isNull);
    });

    test('fallbackPath is ignored when a header is present', () {
      final patch = HashlinePatch.parse(
        '[b.ts#1A2B]\nDEL 1',
        fallbackPath: 'a.ts',
      );
      expect(patch.sections[0].path, 'b.ts');
    });

    test('fallbackPath is ignored for bodies without ops', () {
      expect(
        () => HashlinePatch.parse('just text', fallbackPath: 'a.ts'),
        throwsA(isA<HashlineFormatException>()),
      );
    });
  });

  group('HashlinePatchSection', () {
    test('parse() is cached', () {
      final section = HashlinePatch.parseSingle('[a.ts#1A2B]\nDEL 1');
      expect(identical(section.parse(), section.parse()), isTrue);
    });

    test('hasAnchorScopedEdit: HEAD/TAIL inserts do not count', () {
      final anchored = HashlinePatch.parseSingle('[a#1A2B]\nINS.POST 2:\n+x');
      expect(anchored.hasAnchorScopedEdit, isTrue);
      final headOnly = HashlinePatch.parseSingle('[a#1A2B]\nINS.HEAD:\n+x');
      expect(headOnly.hasAnchorScopedEdit, isFalse);
      final tailOnly = HashlinePatch.parseSingle('[a#1A2B]\nINS.TAIL:\n+x');
      expect(tailOnly.hasAnchorScopedEdit, isFalse);
    });

    test('collectAnchorLines dedups and sorts', () {
      final section = HashlinePatch.parseSingle(
        '[a#1A2B]\nSWAP 5.=7:\n+x\nINS.PRE 3:\n+y',
      );
      expect(section.collectAnchorLines(), [3, 5, 6, 7]);
    });

    test('applyTo applies without tag validation and merges warnings', () {
      final section = HashlinePatch.parseSingle('[a#1A2B]\nSWAP 1.=1:\nbare');
      final result = section.applyTo('old\n');
      expect(result.text, 'bare\n');
      expect(result.warnings, contains(bareBodyAutoPipedWarning));
    });

    test('withPath rebinds and preserves the parse cache', () {
      final section = HashlinePatch.parseSingle('[a#1A2B]\nDEL 1');
      section.parse();
      final rebound = section.withPath('b');
      expect(rebound.path, 'b');
      expect(rebound.fileHash, '1A2B');
      expect(identical(rebound.parse(), section.parse()), isTrue);
    });
  });

  group('containsRecognizableHashlineOperations', () {
    test('detects ops', () {
      expect(
        containsRecognizableHashlineOperations('text\nDEL 1\nmore'),
        isTrue,
      );
      expect(containsRecognizableHashlineOperations('no ops here'), isFalse);
    });
  });

  group('HashlinePatch.parse: more edge cases', () {
    test('a header whose path normalizes to empty is malformed', () {
      // Quoted-empty path and apply_patch-noise-only path both reduce to ''
      // and hit the strict "empty header" diagnostic.
      expect(
        () => HashlinePatch.parse('[""#1A2B]\nDEL 1'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('empty'),
          ),
        ),
      );
      expect(
        () => HashlinePatch.parse('[***]\nDEL 1'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('empty'),
          ),
        ),
      );
    });

    test('a >120-char first line is preview-truncated in the error', () {
      final longLine = 'x' * 200;
      expect(
        () => HashlinePatch.parse(longLine),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message.length,
            'message.length',
            lessThan(400),
          ),
        ),
      );
    });

    test('the warnings getter surfaces parse warnings', () {
      final section = HashlinePatch.parseSingle('[a#1A2B]\nSWAP 1.=1:\nbare');
      expect(section.warnings, contains(bareBodyAutoPipedWarning));
    });
  });
}
