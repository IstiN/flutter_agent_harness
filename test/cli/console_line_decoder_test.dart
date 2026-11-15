// Windows console line-decoder tests: repairs the two mojibake shapes a
// legacy-code-page Windows console delivers for non-ASCII keystrokes
// (issue #207-class report: Russian input unusable in the fa line REPL):
//  1. CP-6501 translation mojibake — the console hands the ANSI-code-page
//     BYTE of the character over as if it were a code point, so 'п'
//     (CP1251 0xEF) arrives as the two UTF-8 bytes C3 AF ('ï');
//  2. legacy single-byte pages (ConPTY pipes where the UTF-8 flip never
//     applied) — 'п' arrives as the single byte 0xEF, which strict
//     utf8.decoder rejects outright (stream error / dead input).
// True UTF-8 text must pass through untouched on every platform.
import 'dart:convert';

import 'package:flutter_agent_harness/src/cli/console_line_decoder.dart';
import 'package:test/test.dart';

/// CP1251 repair map for 0xA0–0xFF, built the way the Windows CLI builds it
/// (byte → MultiByteToWideChar(1251)). Only the entries the tests touch are
/// needed; a couple of neighbors pin the range behavior.
const _cp1251Sample = <int, String>{
  0xA0: ' ',
  0xB7: '·',
  0xC0: 'А',
  0xC3: 'Г',
  0xD0: 'Р',
  0xEF: 'п',
  0xF0: 'р',
  0xE8: 'и',
  0xE2: 'в',
  0xE5: 'е',
  0xF2: 'т',
  0xFF: 'я',
};

String _repair(String run) => run.replaceAllMapped(
  RegExp('[\u00A0-\u00FF]'),
  (m) => _cp1251Sample[m[0]!.runes.first] ?? m[0]!,
);

String? _singleByte(int b) => b >= 0x80 ? (_cp1251Sample[b]) : null;

/// Drives the decoder the way `stdin.transform` does: one chunk per event.
List<String> _decodeChunks(ConsoleLineDecoder d, List<List<int>> chunks) => [
  for (final c in chunks) d.convert(c),
];

void main() {
  group('ConsoleLineDecoder without repair hooks (default = strict utf8)', () {
    test('ASCII lines pass through', () {
      final d = ConsoleLineDecoder();
      expect(d.convert(utf8.encode('hello\r\n')), 'hello\r\n');
    });

    test('true UTF-8 multi-byte text passes through', () {
      final d = ConsoleLineDecoder();
      expect(d.convert(utf8.encode('при\r\n')), 'при\r\n');
    });
  });

  group('ConsoleLineDecoder shape 2 — legacy single-byte pages', () {
    test('lone CP866 byte decodes through singleByteDecode', () {
      final d = ConsoleLineDecoder(singleByteDecode: _singleByte);
      expect(d.convert([0xEF, 0x0D, 0x0A]), 'п\r\n');
    });

    test('a run of legacy bytes decodes one by one', () {
      final d = ConsoleLineDecoder(singleByteDecode: _singleByte);
      expect(
        d.convert([0xEF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x0D, 0x0A]),
        'привет\r\n',
      );
    });

    test('legacy bytes interleaved with ASCII', () {
      final d = ConsoleLineDecoder(singleByteDecode: _singleByte);
      // 0xEF 'п', ASCII 'r', 0xE8 'и'.
      expect(d.convert([0xEF, 0x72, 0xE8, 0x0A]), 'пrи\n');
    });

    test('without singleByteDecode legacy bytes surface as U+FFFD', () {
      final d = ConsoleLineDecoder();
      expect(d.convert([0xEF, 0x0D]), '\uFFFD\r');
    });
  });

  group('ConsoleLineDecoder shape 1 — CP-6501 translation mojibake', () {
    test('C3 AF pair decodes to ï then repairs to п', () {
      final d = ConsoleLineDecoder(runRepair: _repair);
      expect(d.convert(const [0xC3, 0xAF, 0x0D, 0x0A]), 'п\r\n');
    });

    test('a mojibake word repairs fully', () {
      // 'привет' mojibake: every char's CP1251 byte re-encoded as UTF-8.
      const mojibake = [0xC3, 0xAF, 0xC3, 0xB0, 0xC3, 0xA8, 0xC3, 0xA2];
      final d = ConsoleLineDecoder(runRepair: _repair);
      expect(d.convert(mojibake), 'прив');
    });

    test('mojibake mixed with true UTF-8 Cyrillic', () {
      // 'при' true UTF-8 + one mojibake pair for 'в'.
      final d = ConsoleLineDecoder(runRepair: _repair);
      expect(d.convert([...utf8.encode('при'), 0xC3, 0xA2]), 'прив');
    });

    test('true Latin-1 range chars also repair (documented trade-off)', () {
      final d = ConsoleLineDecoder(runRepair: _repair);
      expect(d.convert(const [0xC3, 0xAF]), 'п');
    });

    test('chars outside the Latin-1 range never repair', () {
      final d = ConsoleLineDecoder(runRepair: _repair);
      expect(d.convert(utf8.encode('ёжик ✓')), 'ёжик ✓');
    });
  });

  group('ConsoleLineDecoder chunked streaming', () {
    test('multi-byte sequence split across chunks decodes once complete', () {
      final d = ConsoleLineDecoder(runRepair: _repair);
      // C3 in the first chunk, AF in the second.
      expect(
        _decodeChunks(d, const [
          [0xC3],
          [0xAF, 0x0D],
        ]),
        ['', 'п\r'],
      );
    });

    test('true UTF-8 Cyrillic split across chunks', () {
      final d = ConsoleLineDecoder();
      // 'п' = D0 BF: lead in chunk 1, continuation in chunk 2.
      expect(
        _decodeChunks(d, const [
          [0xD0],
          [0xBF, 0x0A],
        ]),
        ['', 'п\n'],
      );
    });

    test('a legacy byte after a partial sequence head', () {
      final d = ConsoleLineDecoder(singleByteDecode: _singleByte);
      // 0xC3 followed by 0xEF: the head can never complete (0xEF is not a
      // continuation byte) — 0xC3 falls back through singleByteDecode ('Г'),
      // then 0xEF decodes as its own legacy byte ('п').
      expect(d.convert(const [0xC3, 0xEF, 0x0A]), 'Гп\n');
    });

    test('incomplete tail is held across events, dropped at stream end', () {
      final d = ConsoleLineDecoder(singleByteDecode: _singleByte);
      // 0xD0 alone: a valid sequence head waiting for continuations — held
      // (the next keystroke may complete it); dropped when the stream ends.
      expect(d.convert(const [0xD0]), '');
    });

    test('incomplete tail without singleByteDecode is held too', () {
      final d = ConsoleLineDecoder();
      expect(d.convert(const [0xD0]), '');
    });
  });

  group('ConsoleLineDecoder line-splitter integration', () {
    test('works under Stream.transform like the CLI wires it', () async {
      final d = ConsoleLineDecoder(runRepair: _repair);
      // Real integration: mojibake word + CR splits into one repaired line.
      final stream = Stream<List<int>>.fromIterable([
        const [
          0xC3,
          0xAF,
          0xC3,
          0xB0,
          0xC3,
          0xA8,
          0xC3,
          0xA2,
          0xC3,
          0xA5,
          0xC3,
          0xB2,
          0x0D,
          0x0A,
        ],
      ]).transform(d).transform(const LineSplitter());
      await expectLater(stream, emits('привет'));
    });
  });
}
