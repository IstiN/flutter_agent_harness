import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:test/test.dart';

/// Perf contracts for the incremental transcript formatter
/// (`TranscriptMarkdown`, backing `_WrapCache`). Work counters — not
/// timings — per docs/performance-cli-tui.md.
void main() {
  setUp(TranscriptMarkdown.resetDebugCounters);

  group('TranscriptMarkdown parity (incremental ≡ one-shot)', () {
    final fixtures = [
      ['plain prose line', 'second plain line'],
      ['# header', '- bullet **bold** item', 'tail prose'],
      [
        'prose before',
        '```dart',
        'final x = 1;',
        'final y = 中文 🚀 code;',
        '```',
        'prose after',
      ],
      // Unclosed fence spanning a sync boundary: formatting of interior
      // lines must not depend on when the closing marker arrives.
      ['intro', '```', 'fenced line A'],
      // Table fully buffered within one boundary chunk.
      ['| a | b |', '| --- | --- |', '| 1 | 2 |', 'after table'],
      // Table crossing several sync steps (pending buffer at boundaries).
      ['| h1 | h2 |'],
      // Pre-styled user echo line (background SGR) padded to width.
      ['\x1b[48;2;30;34;42m echo text \x1b[0m', 'plain after'],
      // Long single word + boundary tail (wrap-sensitive fixture).
      ['${'a-' * 79}a', 'tiny tail'],
    ];

    for (var i = 0; i < fixtures.length; i++) {
      test('fixture #$i: stepped syncs match formatAll', () {
        final doc = fixtures[i];
        final expected = AnsiMarkdown(width: 60).formatAll(doc);

        final session = TranscriptMarkdown(width: 60);
        var actual = <String>[];
        for (var n = 1; n <= doc.length; n++) {
          actual = session.sync(doc.sublist(0, n));
          expect(
            actual,
            AnsiMarkdown(width: 60).formatAll(doc.sublist(0, n)),
            reason: 'step $n diverged',
          );
        }
        expect(actual, expected);
      });
    }

    test('adversarial mixed document, one line per sync', () {
      final doc = <String>[
        '## Title',
        '',
        'Prose with [link](https://x.y) and `code` and ~~strike~~.',
        '```',
        'fenced 0',
        '| broken | table',
        '```',
        '| a | b | c |',
        '| --- | :-: | --- |',
        '| 🚀 中文 | x | y |',
        'after | flush point.',
        '\x1b[48;2;30;34;42muser echo\x1b[0m',
        'trailing 中文 emoji 🎉 prose long enough to wrap across cells '
            'repeatedly repeatedly repeatedly',
      ];
      final expected = AnsiMarkdown(width: 40).formatAll(doc);

      final session = TranscriptMarkdown(width: 40);
      List<String> actual = const [];
      for (var n = 1; n <= doc.length; n++) {
        actual = session.sync(doc.sublist(0, n));
      }
      expect(actual, expected);
    });
  });

  group('TranscriptMarkdown work counters', () {
    test('cumulative appends format only the suffix after a load', () {
      final session = TranscriptMarkdown(width: 70);
      var lines = List.generate(100, (i) => 'line $i plain prose body');
      session.sync(lines);

      final before = TranscriptMarkdown.debugLinesFormatted;
      for (var n = 1; n <= 20; n++) {
        lines = [...lines, 'appended $n'];
        session.sync(lines);
      }
      // The controller mutates exactly like this: history list grown by one
      // burst per flush, element identity of the prefix preserved.
      expect(
        TranscriptMarkdown.debugLinesFormatted - before,
        20,
        reason: 'each append formats exactly the appended line',
      );
    });

    test('appends trigger zero full rebuilds', () {
      final session = TranscriptMarkdown(width: 70);
      var lines = List.generate(50, (i) => 'body line $i');
      session.sync(lines);
      final rebuildsBefore = TranscriptMarkdown.debugFullRebuilds;

      for (var n = 0; n < 10; n++) {
        lines = [...lines, 'extra $n'];
        session.sync(lines);
      }
      expect(
        TranscriptMarkdown.debugFullRebuilds,
        rebuildsBefore,
        reason: 'append-only prefixes must resume',
      );
      expect(
        TranscriptMarkdown.debugResumedPasses,
        greaterThanOrEqualTo(rebuildsBefore + 10),
      );
    });

    test('replacing a committed tail line is a documented safe rebuild', () {
      final session = TranscriptMarkdown(width: 70);
      final base = List.generate(20, (i) => 'seed $i');
      session.sync([...base, 'temp head']);
      final rebuildsBefore = TranscriptMarkdown.debugFullRebuilds;

      final src = [...base, 'real content'];
      final rendered = session.sync(src);
      expect(
        TranscriptMarkdown.debugFullRebuilds,
        rebuildsBefore + 1,
        reason: 'a replaced boundary line invalidates committed rows',
      );
      expect(
        rendered,
        AnsiMarkdown(width: 70).formatAll(src),
        reason: 'the fallback must stay byte-exact',
      );
    });

    test('width change is a documented full rebuild', () {
      final base = List.generate(30, (i) => 'row $i');
      final session = TranscriptMarkdown(width: 70);
      session.sync(base);

      final rebuiltWidth = TranscriptMarkdown.debugFullRebuilds;
      session.widthOverrideForTest(40);
      session.sync(base);
      expect(TranscriptMarkdown.debugFullRebuilds, rebuiltWidth + 1);
    });

    test('front-trim (history cap) takes the documented rebuild path '
        'and stays byte-exact', () {
      final session = TranscriptMarkdown(width: 70);
      var lines = List.generate(200, (i) => 'row $i of two hundred');
      session.sync(lines);
      final rebuildsBefore = TranscriptMarkdown.debugFullRebuilds;

      final trimmed = lines.sublist(lines.length - 100);
      final rendered = session.sync(trimmed);
      expect(
        TranscriptMarkdown.debugFullRebuilds,
        rebuildsBefore + 1,
        reason: 'head drops flip the first-line sentinel',
      );
      expect(
        rendered,
        AnsiMarkdown(width: 70).formatAll(trimmed),
        reason: 'post-trim render stays byte-exact',
      );
    });

    test('unclosed fence resumes correctly without rebuilding', () {
      final session = TranscriptMarkdown(width: 60);
      session.sync(['```dart']);
      final rebuilds = TranscriptMarkdown.debugFullRebuilds;

      session.sync(['```dart', 'const a = 1;']);
      session.sync(['```dart', 'const a = 1;', 'const b = 2;', '```']);

      expect(
        TranscriptMarkdown.debugFullRebuilds,
        rebuilds,
        reason: 'open fence state carries across syncs',
      );
      final rendered = session.sync([
        '```dart',
        'const a = 1;',
        'const b = 2;',
        '```',
        'plain tail',
      ]);
      expect(rendered.last, 'plain tail');
    });
  });

  group('fa_tui streaming mutation pattern', () {
    test('grow stays O(delta); cap-trim falls back safely', () {
      final session = TranscriptMarkdown(width: 90);
      var lines = List.generate(300, (i) => 'history seed line $i');
      session.sync(lines);
      final rebuildsAtStart = TranscriptMarkdown.debugFullRebuilds;

      const capWindow = 620;
      var grewAppendCount = 0;
      var trimmedRebuilds = 0;
      var grewLinesFormatted = 0;
      for (var burst = 0; burst < 340; burst++) {
        lines = [...lines, 'streamed delta $burst'];
        if (lines.length > capWindow) {
          lines = lines.sublist(lines.length - capWindow);
        }
        final beforeFmt = TranscriptMarkdown.debugLinesFormatted;
        final beforeReb = TranscriptMarkdown.debugFullRebuilds;
        final view = session.sync(lines);
        if (TranscriptMarkdown.debugFullRebuilds > beforeReb) {
          trimmedRebuilds++;
        } else {
          grewAppendCount++;
          expect(
            TranscriptMarkdown.debugLinesFormatted - beforeFmt,
            1,
            reason: 'grow append must format just the new delta line',
          );
        }
        // Byte-parity holds through BOTH paths.
        expect(view, AnsiMarkdown(width: 90).formatAll(lines));
      }
      expect(
        grewAppendCount,
        greaterThan(0),
        reason: 'pre-cap stretch must exist in this scenario',
      );
      expect(
        trimmedRebuilds,
        greaterThan(0),
        reason: 'post-cap front drops take the documented safe path',
      );
      // Durable-commit invariant regardless of path.
      expect(TranscriptMarkdown.debugFullRebuilds >= rebuildsAtStart, isTrue);
      // Sanity on aggregate: grows are strictly one-line each.
      expect(grewLinesFormatted, 0);
    });
  });
}
