// Fuzzy-overlay color discipline (issue #519 AC2): in the slash menu the
// matched characters carry exactly one accent role (accent2Soft) and every
// unmatched cell carries the row's base role. On the SELECTED row the base
// role is the selection accent — the vendor's full SGR reset inside the
// highlighted label used to strip it, leaving the row tail in the terminal
// default ("разного цвета буквы", 97_fuzzy_overlay.png).
library;

import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart' show MenuItem;
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:test/test.dart';

final _sgr = RegExp(r'\x1b\[[0-9;]*m');

FaTuiModel build() {
  return FaTuiModel(
    callbacks: FaTuiCallbacks(
      onSubmit: (_, {images = const []}) async {},
      onModelSelected: (_) async {},
      buildSlashMenu: (_) => [
        const MenuItem(
          key: '/config',
          label: '/config',
          description: 'settings',
        ),
        const MenuItem(
          key: '/compact',
          label: '/compact',
          description: 'compact history',
        ),
      ],
      buildModelMenu: (_, _) => const [],
      statusLine: () => 'ready',
      prompt: 'fa> ',
    ),
    isExited: () => false,
    termWidth: 80,
    termHeight: 12,
  );
}

void main() {
  final controller = FaThemeController.instance;
  final accentOpen = controller.sgrPrefix(controller.current.accent);
  final accent2Open = controller.sgrPrefix(controller.current.accent2Soft);
  final reset = '\x1b[0m';

  test('AC2 UT-fuzzy-role-map: matched chars wear accent2, every other '
      'cell of the selected row wears the base role — none unstyled', () {
    var m = build();
    for (final ch in '/co'.split('')) {
      m = m.update(KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch))).$1
          as FaTuiModel;
    }
    final rows = m.view().content.split('\n');
    final selected = rows.firstWhere(
      (r) => r.replaceAll(_sgr, '').contains('▸'),
      orElse: () => fail('no selected menu row in the frame'),
    );

    // Fixture sanity: '/co' fuzzy-matches '/config' and the matched cells
    // are wrapped in the accent2Soft role.
    expect(
      selected.contains('$accent2Open c$reset'.replaceAll(' ', '')),
      isTrue,
      reason: 'the matched character must carry the accent2Soft role',
    );
    // '/co' matches '/config' as a full subsequence: /, c, o — three
    // matched cells, each wrapped once.
    expect(
      _sgr.allMatches(selected).where((m) => m[0] == accent2Open).length,
      3,
      reason: 'exactly the matched characters may carry the accent role',
    );

    // Role map: every visible run of the selected row must open a span.
    // Between the vendor's resets the base (selection accent) role must be
    // re-armed — a run that starts unstyled renders in the terminal
    // default and IS the mixed-color artifact.
    for (final seg in selected.split(reset)) {
      // Same-length masking: SGR bytes are non-space to \S, so the first
      // VISIBLE cell must be found with the escape spans blanked out.
      final masked = seg.replaceAllMapped(_sgr, (m) => ' ' * m[0]!.length);
      final nonSpace = RegExp(r'\S').firstMatch(masked);
      if (nonSpace == null) continue;
      final open = seg.indexOf('\x1b[');
      expect(open, isNonNegative,
          reason: 'unstyled run "${masked.trim()}" — no role before it');
      expect(open, lessThan(nonSpace.start),
          reason: 'run "${masked.trim()}" renders unstyled');
    }

    // And the base role IS the selection accent (not merely "any" style).
    expect(selected.contains(accentOpen), isTrue,
        reason: 'unmatched cells must wear the selection accent');
  });
}

