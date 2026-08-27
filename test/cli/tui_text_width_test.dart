@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/cli/tui_text_width.dart';
import 'package:test/test.dart';

void main() {
  group('tuiTextWidth', () {
    test('plain ascii is one cell per character', () {
      expect(tuiTextWidth('hello world'), 11);
      expect(tuiTextWidth(''), 0);
    });

    test('emoji and CJK count as two cells', () {
      expect(tuiTextWidth('✅'), 2);
      expect(tuiTextWidth('🎉x'), 3);
      expect(tuiTextWidth('日本語'), 6);
    });

    test('combining marks and variation selectors add zero cells', () {
      // e + combining acute = one cell.
      expect(tuiTextWidth('é'), 1);
      // Emoji + variation selector stays two cells.
      expect(tuiTextWidth('❤️'), 2);
    });

    test('control characters (tab, newline) measure zero-width runs', () {
      // Controls are zero-width by the shared table; the ASCII fast path
      // must NOT treat them as printable (tab would otherwise be 1 cell).
      expect(tuiTextWidth('\t'), 0);
      expect(tuiTextWidth('a\tb'), tuiTextWidth('a') + tuiTextWidth('\t') + 1);
    });

    test('repeated measurements agree across cache hits and evictions', () {
      final samples = [
        'plain ascii line',
        'mixed ✅ line',
        '日本語 CJK line',
        'é combining line',
      ];
      final first = {for (final s in samples) s: tuiTextWidth(s)};
      // Same values straight from the cache.
      expect({for (final s in samples) s: tuiTextWidth(s)}, first);
      // Flood the cache to force evictions; results must stay identical.
      for (var i = 0; i < 9000; i++) {
        tuiTextWidth('filler-$i-✅');
      }
      expect({for (final s in samples) s: tuiTextWidth(s)}, first);
    });

    test('very long strings measure correctly without being memoized', () {
      final long = '${'a' * 5000}✅';
      final w = tuiTextWidth(long);
      expect(w, 5002);
      expect(tuiTextWidth(long), w);
    });
  });
}
