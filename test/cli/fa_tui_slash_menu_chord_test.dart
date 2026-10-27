// gh-1805 regression: modifier chords must not leak their base letter into
// the composer while the slash menu is open.
//
// The vendored dart_tui decoder maps control bytes to rune keys carrying the
// BASE letter as text (0x13 → keystroke 'ctrl+s' with text 's'; macOS
// Cmd+Left sends ^A → 'ctrl+a' with text 'a'). Normal mode (_handleCharInsertKey),
// picker mode (_pickerTypeFilter) and prompt mode (_promptChar) all guard this
// with FaTuiModel._isCommandKeystroke — the slash-menu edit cluster
// (_handleSlashMenuEditKey) was the one surface missing the guard, so a chord
// pressed while the menu was open typed its letter into the typed prefix
// (reported: `/smemory`, `/squeue` instead of `/memory`, `/queue`).
import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/slash_menu.dart';

import 'package:test/test.dart';

FaTuiModel _model() => FaTuiModel(
  callbacks: FaTuiCallbacks(
    onSubmit: (line, {images = const []}) async {},
    onModelSelected: (id) async {},
    buildSlashMenu: (prefix) => buildSlashMenuItems(
      prefix,
      slashCommands: builtinSlashCommands,
      pluginSlashCommands: const {},
      templates: const [],
      skills: const [],
    ),
    buildModelMenu: (filter, _) => const [],
    statusLine: () => 'test',
    prompt: 'fa> ',
  ),
  isExited: () => false,
);

FaTuiModel _key(FaTuiModel model, TeaKey key) =>
    model.update(KeyPressMsg(key)).$1 as FaTuiModel;

/// A control-byte chord as the decoder delivers it: base letter in `text`
/// plus the ctrl modifier (key_buffer_parser.dart 0x01–0x1a branch).
TeaKey _chord(String letter) =>
    TeaKey(code: KeyCode.rune, text: letter, modifiers: const {KeyMod.ctrl});

void main() {
  test('ctrl chord with the slash menu open does not leak its base letter', () {
    var model = _model();
    model = _key(model, const TeaKey(code: KeyCode.rune, text: '/'));
    expect(model.menuOpen, isTrue);
    expect(model.inputText, '/');

    // Ctrl+S (FA's submit/steer chord) while the menu is open.
    model = _key(model, _chord('s'));
    expect(model.inputText, '/', reason: 'ctrl+s must not insert its base s');
    // The menu stays open and unfiltered — still the full command list.
    expect(model.menuOpen, isTrue);
    expect(model.menuItems.length, greaterThan(1));
  });

  test(
    'no chord letter leaks while the menu is open (ctrl s/u/w/k/y/b/a/e)',
    () {
      var model = _model();
      model = _key(model, const TeaKey(code: KeyCode.rune, text: '/'));
      for (final letter in ['s', 'u', 'w', 'k', 'y', 'b', 'a', 'e']) {
        model = _key(model, _chord(letter));
        expect(model.inputText, '/', reason: 'ctrl+$letter leaked its letter');
      }
      expect(model.menuOpen, isTrue);
    },
  );

  test('plain letters still type and filter with the menu open', () {
    var model = _model();
    model = _key(model, const TeaKey(code: KeyCode.rune, text: '/'));
    final fullKeys = model.menuItems.map((i) => i.key).toSet();
    expect(fullKeys.length, greaterThan(1));
    model = _key(model, const TeaKey(code: KeyCode.rune, text: 'm'));
    expect(model.inputText, '/m');
    expect(model.menuOpen, isTrue);
    // The typed letter filters the menu: the shown set strictly narrows
    // against what '/' offered. No specific command is named, so the
    // regression does not couple to the builtin catalog (review thread 2).
    final filteredKeys = model.menuItems.map((i) => i.key).toSet();
    expect(filteredKeys, isNotEmpty);
    expect(filteredKeys.length, lessThan(fullKeys.length));
    // Every survivor is still a builtin slash command — no specific command
    // is named, so the regression does not couple to the catalog contents
    // (review thread 2; the '/' list above is fuzzyMenu's top-32 view, so
    // the subset is checked against the catalog, not that truncation).
    expect(filteredKeys.every(builtinSlashCommands.containsKey), isTrue);
  });

  test('shift+letter still types with the menu open', () {
    var model = _model();
    model = _key(model, const TeaKey(code: KeyCode.rune, text: '/'));
    // Kitty-style shifted key: text carries the shifted letter, shift modifier.
    model = _key(
      model,
      const TeaKey(code: KeyCode.rune, text: 'S', modifiers: {KeyMod.shift}),
    );
    expect(model.inputText, '/S');
  });

  test('chord-poisoned prefix cannot survive a menu accept (2+ item flow)', () {
    var model = _model();
    model = _key(model, const TeaKey(code: KeyCode.rune, text: '/'));
    // Snapshot the FULL multi-item list (2+ items — the single-item
    // regression shape is not enough here); the chord must leave it alone.
    final beforeKeys = model.menuItems.map((i) => i.key).toList();
    expect(beforeKeys.length, greaterThan(1));
    model = _key(model, _chord('s'));
    // The chord is a no-op: same items, same selection, input untouched.
    expect(model.inputText, '/');
    expect(model.menuItems.map((i) => i.key).toList(), beforeKeys);
    // Navigate to the last item and accept it — the picked command is read
    // off the menu instead of being named, so the regression does not
    // couple to the builtin catalog (review thread 2).
    final acceptedKey = model.menuItems.last.key;
    while (model.menuSelected < model.menuItems.length - 1) {
      model = _key(model, const TeaKey(code: KeyCode.down));
    }
    model = _key(model, const TeaKey(code: KeyCode.enter));
    expect(model.inputText, acceptedKey);
    expect(model.menuOpen, isFalse);
  });
}
