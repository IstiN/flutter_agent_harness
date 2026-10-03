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
      m =
          m.update(KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch))).$1
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
      expect(
        open,
        isNonNegative,
        reason: 'unstyled run "${masked.trim()}" — no role before it',
      );
      expect(
        open,
        lessThan(nonSpace.start),
        reason: 'run "${masked.trim()}" renders unstyled',
      );
    }

    // And the base role IS the selection accent (not merely "any" style).
    expect(
      selected.contains(accentOpen),
      isTrue,
      reason: 'unmatched cells must wear the selection accent',
    );
  });

  test('gh-671: a PLAIN selected label wears the accent too (generic '
      'pickers)', () {
    // The /theme picker items are plain labels (no fuzzy spans). The old
    // _rearmSelection returned them untouched, so the only selection cue
    // was the one-cell ▸ glyph and the label itself rendered in the
    // terminal default — "can't see what is selected" in low-contrast
    // palettes.
    final controller = FaThemeController.instance;
    addTearDown(controller.reset);
    controller.addUserThemes({
      'moss': parseUserTheme('{"roles": {"accent": "#00ff88"}}', 'moss'),
    });
    controller.switchTo('moss');
    var m = build();
    m =
        m
                .update(
                  OpenPickerMsg('theme', 'Select theme', const [
                    MenuItem(key: 'moss', label: 'moss', description: '███'),
                    MenuItem(key: 'pi', label: 'pi', description: '███'),
                  ]),
                )
                .$1
            as FaTuiModel;
    final rows = m.view().content.split('\n');
    final selected = rows.firstWhere(
      (r) => r.replaceAll(_sgr, '').contains('▸'),
      orElse: () => fail('no selected menu row in the frame'),
    );
    final mossOpen = controller.sgrPrefix(controller.current.accent);
    expect(
      selected,
      contains(mossOpen),
      reason: 'the selected plain label must wear the selection accent',
    );
    // Every visible run still opens a role — none unstyled (AC2 rule).
    for (final seg in selected.split(reset)) {
      final masked = seg.replaceAllMapped(_sgr, (m) => ' ' * m[0]!.length);
      final nonSpace = RegExp(r'\S').firstMatch(masked);
      if (nonSpace == null) continue;
      final open = seg.indexOf('\x1b[');
      expect(
        open,
        isNonNegative,
        reason: 'unstyled run "${masked.trim()}" — no role before it',
      );
      expect(
        open,
        lessThan(nonSpace.start),
        reason: 'run "${masked.trim()}" renders unstyled',
      );
    }
  });

  test('gh-1049 AC4: the picker open frame carries the FULL visible row set '
      'atomically', () {
    // The /theme picker's rows ride ONE OpenPickerMsg — the first frame
    // rendered after the open must hold the title, EVERY in-window row
    // with its swatch, the current row's '✓ current' marker and the
    // cursor. A row that only lands in a LATER frame regresses to the
    // progressive-paint race the gh-1049 PTY flake sampled mid-render.
    // The generic-picker reveal test hook (FA_TUI_PICKER_REVEAL_MS) is
    // env-gated and unset here, so this pins the production atomic open.
    addTearDown(controller.reset);
    final items = themePickerItems(current: 'default').take(5).toList();
    expect(items, hasLength(5));
    var m = FaTuiModel(
      callbacks: FaTuiCallbacks(
        onSubmit: (_, {images = const []}) async {},
        onModelSelected: (_) async {},
        buildSlashMenu: (_) => const [],
        buildModelMenu: (_, _) => const [],
        statusLine: () => 'ready',
        prompt: 'fa> ',
      ),
      isExited: () => false,
      // Tall enough that the 5 rows fit the menu window (no scroll hints).
      termWidth: 80,
      termHeight: 20,
    );
    m =
        m
                .update(
                  OpenPickerMsg(
                    'theme',
                    'Select theme',
                    items,
                    initialIndex: 0,
                  ),
                )
                .$1
            as FaTuiModel;
    final frame = m.view().content.replaceAll(_sgr, '');
    expect(frame, contains('Select theme'), reason: 'the picker title');
    for (final item in items) {
      expect(
        frame,
        contains(item.label),
        reason: 'row "${item.label}" must paint in the OPEN frame',
      );
      expect(
        frame,
        contains('███'),
        reason: 'row "${item.label}" must keep its swatch in the open frame',
      );
    }
    // The current row (default, preselected) is text-marked and cursor'ed.
    expect(frame, contains('✓ current'));
    expect(
      RegExp(r'▸\s*default').hasMatch(frame),
      isTrue,
      reason: 'the cursor opens on the current theme row',
    );
  });

  test('gh-1049 review: Enter during the reveal window accepts the last '
      'REVEALED row — no RangeError', () async {
    // _pickerRevealOpen clamps menuSelected to the FULL item list while
    // menuItems holds only the revealed prefix, so Enter/Tab mid-reveal
    // indexed menuItems[menuSelected] past the prefix and threw
    // RangeError (boot theme nord → initialIndex 2 with ONE row revealed).
    // The accept must clamp to what is actually painted.
    FaTuiModel.pickerRevealDelayMsOverride = 1;
    addTearDown(() => FaTuiModel.pickerRevealDelayMsOverride = null);
    final picked = <String>[];
    var m = FaTuiModel(
      callbacks: FaTuiCallbacks(
        onSubmit: (_, {images = const []}) async {},
        onModelSelected: (_) async {},
        onPickerSelected: (pickerId, key) async => picked.add(key),
        buildSlashMenu: (_) => const [],
        buildModelMenu: (_, _) => const [],
        statusLine: () => 'ready',
        prompt: 'fa> ',
      ),
      isExited: () => false,
      termWidth: 80,
      termHeight: 20,
    );
    const items = [
      MenuItem(key: 'default', label: 'default', description: '███'),
      MenuItem(key: 'dracula', label: 'dracula', description: '███'),
      MenuItem(key: 'nord', label: 'nord', description: '███'),
    ];
    m =
        m
                .update(
                  OpenPickerMsg(
                    'theme',
                    'Select theme',
                    items,
                    initialIndex: 2,
                  ),
                )
                .$1
            as FaTuiModel;
    final enter = m.update(KeyPressMsg(const TeaKey(code: KeyCode.enter)));
    m = enter.$1 as FaTuiModel;
    await enter.$2?.call();
    expect(
      picked,
      ['default'],
      reason:
          'Enter mid-reveal accepts the last revealed row (the prefix), '
          'not the out-of-range full-list index',
    );
  });

  test('gh-1049 review: a pending reveal does not clobber an active '
      'type-to-filter', () async {
    // The reveal leg rebuilt menuItems from menuAllItems and ignored
    // modelFilter: filter 'd' narrowed the picker to the matching rows,
    // the pending leg then painted an UNFILTERED prefix over it while the
    // filter stayed set. A filter owns the row set — the leg must stand
    // down.
    FaTuiModel.pickerRevealDelayMsOverride = 1;
    addTearDown(() => FaTuiModel.pickerRevealDelayMsOverride = null);
    var m = FaTuiModel(
      callbacks: FaTuiCallbacks(
        onSubmit: (_, {images = const []}) async {},
        onModelSelected: (_) async {},
        buildSlashMenu: (_) => const [],
        buildModelMenu: (_, _) => const [],
        statusLine: () => 'ready',
        prompt: 'fa> ',
      ),
      isExited: () => false,
      termWidth: 80,
      termHeight: 20,
    );
    final res = m.update(
      OpenPickerMsg('theme', 'Select theme', const [
        MenuItem(key: 'default', label: 'default', description: '███'),
        MenuItem(key: 'dracula', label: 'dracula', description: '███'),
        MenuItem(key: 'nord', label: 'nord', description: '███'),
        MenuItem(key: 'ohmypi', label: 'ohmypi', description: '███'),
        MenuItem(key: 'monokai', label: 'monokai', description: '███'),
      ], initialIndex: 0),
    );
    m = res.$1 as FaTuiModel;
    final revealLeg = res.$2;
    expect(revealLeg, isNotNull, reason: 'the hook must be active (seam set)');
    // Type-to-filter: 'dr' narrows the row set to dracula only ('nord'
    // contains a bare 'd' — it must NOT stay visible).
    for (final ch in 'dr'.split('')) {
      m =
          m.update(KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch))).$1
              as FaTuiModel;
    }
    // The pending reveal leg fires into the filtered picker.
    final reveal = await revealLeg!();
    if (reveal != null) {
      m = m.update(reveal).$1 as FaTuiModel;
    }
    final frame = m.view().content.replaceAll(_sgr, '');
    expect(frame, contains('dracula'), reason: 'a filtered row stays');
    expect(
      frame,
      isNot(contains('nord')),
      reason: 'the reveal must not paint unfiltered rows over the filter',
    );
    expect(
      frame,
      isNot(contains('monokai')),
      reason: 'the reveal must not paint unfiltered rows over the filter',
    );
  });

  test('gh-671: a TRUNCATED selected label wears the accent too', () {
    // Narrow terminal: the label does not fit, so `_menuItemRow` renders
    // the stripped fitted text. The old truncated branch returned it
    // unwrapped — the selected row lost the accent exactly when the label
    // was long (generic pickers with long names/paths).
    var m = FaTuiModel(
      callbacks: FaTuiCallbacks(
        onSubmit: (_, {images = const []}) async {},
        onModelSelected: (_) async {},
        buildSlashMenu: (_) => const [],
        buildModelMenu: (_, _) => const [],
        statusLine: () => 'ready',
        prompt: 'fa> ',
      ),
      isExited: () => false,
      termWidth: 20,
      termHeight: 12,
    );
    m =
        m
                .update(
                  OpenPickerMsg('theme', 'Select theme', const [
                    MenuItem(
                      key: 'a-very-long-theme-name',
                      label: 'a-very-long-theme-name',
                      description: '███',
                    ),
                    MenuItem(key: 'pi', label: 'pi', description: '███'),
                  ]),
                )
                .$1
            as FaTuiModel;
    final rows = m.view().content.split('\n');
    final selected = rows.firstWhere(
      (r) => r.replaceAll(_sgr, '').contains('▸'),
      orElse: () => fail('no selected menu row in the frame'),
    );
    final open = controller.sgrPrefix(controller.current.accent);
    // The label is truncated, not dropped.
    expect(selected.replaceAll(_sgr, ''), contains('a-very-lon'));
    // The accent must open right before the FITTED label cells — not only
    // around the ▸ glyph (the pre-fix defect).
    final labelStart = selected.indexOf('a-very-lon');
    final opensBeforeLabel = [
      for (final match in RegExp(RegExp.escape(open)).allMatches(selected))
        if (match.start < labelStart) match.start,
    ];
    expect(opensBeforeLabel, isNotEmpty);
    expect(
      opensBeforeLabel.last,
      greaterThan(selected.indexOf('▸')),
      reason: 'the accent must wrap the fitted label, not only the ▸ glyph',
    );
    expect(
      labelStart - opensBeforeLabel.last,
      lessThan(open.length + 2),
      reason: 'the accent SGR must sit immediately before the label text',
    );
  });
}
