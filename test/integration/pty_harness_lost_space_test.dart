// Regression proof for the gh-1372 flake family (`memory_add and
// memory_search tools are available` in subagent_integration_test.dart,
// red on nightlies 37880055409 + 38021029680): the streamed assistant
// reply row is pure ASCII, so the TUI's cell-diff path may skip an
// interior space cell whose physical grid cell is erased/never-written —
// and the vendored emulator's `BufferLine.getText` DROPS those cells
// (content 0), so the extracted screen carries `round-tripcomplete`
// where the phrase says `round-trip complete`. The exact-string
// `waitForScreen` can then never match and the leg burns its 30 s wait.
//
// The two nightlies timed out on byte-identical wire shapes; the raw tail
// of job 114121833520 shows the renderer addressing `complete` at column
// 24 right after `memory round-trip` ended at column 22 — the space cell
// at column 23 is never written:
//
//   ...m memory round-trip<ESC>[17;24Hcomplete
//
// Hermetic (no PTY, no network): feeds the exact observed bytes into the
// same in-memory emulator the harness uses and pins what the extraction
// sees. Runs in the DEFAULT suite so the pre-commit gate enforces it —
// the flake only reproduces on loaded runners.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

import 'pty_harness.dart';

/// The observed red-run wire shape for the streamed reply row: the reply
/// `memory round-trip complete` painted in two draws with the interior
/// space cell skipped (the diff path considered it unchanged).
const _redRunRow17 =
    '\x1b[17;1H\x1b[1m\x1b[38;2;94;234;212m>_'
    '\x1b[1m\x1b[38;2;129;140;248mFa\x1b[0m memory round-trip'
    '\x1b[17;24Hcomplete';

/// Every viewport line's text (same walk as `FaCliHarness.viewportLines` —
/// the buffer's line store is index-addressed, not an Iterable).
List<String> _screenLines(Terminal terminal) {
  final buf = terminal.buffer;
  return [
    for (var i = buf.scrollBack; i < buf.lines.length; i++)
      buf.lines[i].getText(),
  ];
}

void main() {
  group('erased-cell extraction loss (gh-1372)', () {
    test('a skipped interior space cell vanishes from the screen text', () {
      final terminal = Terminal(maxLines: 24 * 4);
      terminal.write(_redRunRow17);

      final line = _screenLines(
        terminal,
      ).firstWhere((t) => t.contains('round-trip'));

      // The extraction carries the collapsed phrase — exactly what both
      // nightly screen dumps showed (`>_Fa memory round-tripcomplete`).
      expect(line, contains('round-tripcomplete'));
      // The exact-string matcher the test used before the fix can NEVER
      // hit this screen — that is the flake.
      expect(line, isNot(contains('memory round-trip complete')));
    });

    test(
      'lostSpaceTolerant matches the collapsed screen and the intact one',
      () {
        final terminal = Terminal(maxLines: 24 * 4);
        terminal.write(_redRunRow17);
        final collapsed = _screenLines(
          terminal,
        ).firstWhere((t) => t.contains('round-trip'));

        final marker = lostSpaceTolerant('memory round-trip complete');
        expect(collapsed, matches(marker));
        expect('memory round-trip complete', matches(marker));
        // The literal prompt-line extraction both nightly TimeoutExceptions
        // dumped (`>_Fa memory round-tripcomplete`, jobs 113769812110 /
        // 114121833520) — the incident screen, matched by the fix.
        expect('> _Fa memory round-tripcomplete', matches(marker));
      },
    );
  });

  group('lostSpaceTolerant semantics', () {
    final marker = lostSpaceTolerant('subagent finished: agent://explorer1');

    test('accepts the intact phrase on a plain screen row', () {
      expect(
        '✔ task: Prove the task loop\n'
        'subagent finished: agent://explorer1 reported 3 files',
        matches(marker),
      );
    });

    test('accepts the phrase with any single interior space dropped', () {
      expect('subagent finished:agent://explorer1', matches(marker));
      expect(
        'subagent finished:agent://explorer1 reported 3 files'.replaceFirst(
          'agent://explorer1 reported',
          'agent://explorer1reported',
        ),
        matches(marker),
      );
    });

    test('refuses shifted spaces, other words, and unrelated rows', () {
      // A space shifted one cell right is a different corruption.
      expect('subagent finished:  agent://explorer1', isNot(matches(marker)));
      // `complete` inside another word must not satisfy the marker.
      expect(
        'memory round-trip incomplete',
        isNot(matches(lostSpaceTolerant('memory round-trip complete'))),
      );
      expect('agent://explore1', isNot(matches(marker)));
      expect('nothing to see here', isNot(matches(marker)));
    });

    test('escapes regex metacharacters in the phrase', () {
      final meta = lostSpaceTolerant('step 1 (a.b) done');
      expect('step 1 (a.b) done', matches(meta));
      expect('step 1 (aXb) done', isNot(matches(meta)));
      expect('step1 (a.b)done', matches(meta));
    });
  });
}
