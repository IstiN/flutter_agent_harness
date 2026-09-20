// Issue #706 (viewport half): the /model picker's visible window must
// follow the live terminal height — a list longer than the glass leaves
// the top rows unreachable ('↑ more' rendered, but no amount of arrow
// scrolling ever brings the upper rows onto the screen because the frame
// overflow crop eats them from the top).
import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart' show MenuItem;

import 'package:test/test.dart';

/// A 12-row picker model with [count] model items, opened through the
/// same OpenPickerMsg the host's /model flow uses (pickerId 'models' —
/// the footer-hint-carrying family).
FaTuiModel pickerModel({
  required int count,
  int termHeight = 12,
  String pickerId = 'models',
}) {
  final items = [
    for (var i = 0; i < count; i++)
      MenuItem(key: 'model-$i', label: 'model-$i'),
  ];
  final model = FaTuiModel(
    callbacks: FaTuiCallbacks(
      onSubmit: (line, {images = const []}) async {},
      onModelSelected: (id) async {},
      buildSlashMenu: (prefix) => const [],
      buildModelMenu: (filter, _) => items,
      statusLine: () => '/work · 0tok',
      prompt: 'fa> ',
    ),
    isExited: () => false,
    termHeight: termHeight,
  );
  return model.update(OpenPickerMsg(pickerId, 'Select model', items)).$1
      as FaTuiModel;
}

FaTuiModel press(FaTuiModel model, TeaKey key) =>
    model.update(KeyPressMsg(key)).$1 as FaTuiModel;

void main() {
  group('/model picker viewport follows the terminal height (#706)', () {
    test('the first row lands on the glass in a short terminal', () {
      final model = pickerModel(count: 12, termHeight: 10);
      final top = press(model, const TeaKey(code: KeyCode.pageUp));
      final frame = top.view().content;
      // The title and the FIRST item must be painted: with a fixed
      // 6-row window the frame overran a 10-row terminal and the glass
      // guard cropped the menu's top away — the row was selectable but
      // never visible.
      expect(frame, contains('[Select model'));
      expect(frame, contains('model-0'));
    });

    test('every row is visible while the selection walks the list', () {
      var model = pickerModel(count: 12, termHeight: 12);
      for (var i = 0; i < 12; i++) {
        expect(
          model.view().content,
          contains('model-$i'),
          reason: 'selected row $i must be on the glass',
        );
        model = press(model, const TeaKey(code: KeyCode.down));
      }
    });

    test('a tall terminal keeps the classic 6-row window and hints', () {
      var model = pickerModel(count: 12, termHeight: 24);
      // Walk deep enough that both hints render — unchanged legacy
      // behavior for normal terminals (no squeeze, no regression).
      for (var i = 0; i < 5; i++) {
        model = press(model, const TeaKey(code: KeyCode.down));
      }
      final frame = model.view().content;
      expect(frame, contains('↑ more'));
      expect(frame, contains('↓ more'));
      expect(frame, contains('model-5'));
    });
  });

  group('grouped picker window pays for its header rows (#706)', () {
    // The slash menu interleaves '── group ──' header rows between the
    // items (#275). A window cap that reserves a FIXED chrome budget
    // cannot know how many headers its window will paint: on a short
    // terminal the frame overran the glass and the top crop ate the
    // title and first items again. The cap must shrink to the rows the
    // window actually renders (title + items + headers + hints).
    FaTuiModel groupedPickerModel({required int termHeight, int count = 12}) {
      final items = [
        for (var i = 0; i < count; i++)
          MenuItem(
            key: 'model-$i',
            label: 'model-$i',
            group: 'g${i ~/ 2}', // a header every 2 items
          ),
      ];
      final model = FaTuiModel(
        callbacks: FaTuiCallbacks(
          onSubmit: (line, {images = const []}) async {},
          onModelSelected: (id) async {},
          buildSlashMenu: (prefix) => const [],
          buildModelMenu: (filter, _) => items,
          statusLine: () => '/work · 0tok',
          prompt: 'fa> ',
        ),
        isExited: () => false,
        termHeight: termHeight,
      );
      return model.update(OpenPickerMsg('generic', 'Pick one', items)).$1
          as FaTuiModel;
    }

    test('the title and first row stay on the glass when headers crowd', () {
      // 15 rows, 12 items in 6 groups: the classic fixed reserve sizes a
      // 6-item window (5 chrome + title + 6 items + 3 headers + '↓ more'
      // = 16 rows) — one row over the glass, and with no history padding
      // the top crop eats the menu title. The header-aware cap shrinks
      // the window to 5 items so everything painted fits.
      final frame = groupedPickerModel(termHeight: 15).view().content;
      expect(frame, contains('[Pick one]'));
      expect(frame, contains('model-0'));
      // The header row itself is painted too — the window really fit.
      expect(frame, contains('── g0 ──'));
    });

    test('selection walks the whole list on the glass', () {
      var model = groupedPickerModel(termHeight: 15);
      for (var i = 0; i < 12; i++) {
        expect(
          model.view().content,
          contains('model-$i'),
          reason: 'selected row $i must be on the glass',
        );
        model = press(model, const TeaKey(code: KeyCode.down));
      }
    });

    test('a terminal tall enough for headers keeps the 6-row window', () {
      // 24 rows hold 5 chrome + title + 6 items + 3 headers + '↓ more'
      // with room to spare — no squeeze, legacy window preserved.
      final frame = groupedPickerModel(termHeight: 24).view().content;
      expect(frame, contains('model-5'));
      expect(frame, contains('↓ more'));
    });
  });
}
