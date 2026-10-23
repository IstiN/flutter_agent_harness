import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/slash_menu.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';

import 'package:test/test.dart';

FaTuiCallbacks productionCallbacks() {
  return FaTuiCallbacks(
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
  );
}

void main() {
  test('scenario: / then s then navigate down then enter', () async {
    var model = FaTuiModel(
      callbacks: productionCallbacks(),
      isExited: () => false,
    );

    Future<void> type(String text) async {
      final result = model.update(
        KeyPressMsg(TeaKey(code: KeyCode.rune, text: text)),
      );
      model = result.$1 as FaTuiModel;
    }

    await type('/');
    print('after /: open=${model.menuOpen} text="${model.inputText}" sel=${model.menuSelected} items=${model.menuItems.length}');
    await type('s');
    print('after s: open=${model.menuOpen} text="${model.inputText}" sel=${model.menuSelected} items=${model.menuItems.map((i) => i.key).take(10).toList()}');
    for (var i = 0; i < 5; i++) {
      final r = model.update(KeyPressMsg(TeaKey(code: KeyCode.down)));
      model = r.$1 as FaTuiModel;
      final sel = model.menuSelected.clamp(0, model.menuItems.length - 1);
      print('down $i: sel=${model.menuSelected} -> ${model.menuItems[sel].key}');
    }
    final r = model.update(KeyPressMsg(TeaKey(code: KeyCode.enter)));
    model = r.$1 as FaTuiModel;
    print('after enter: text="${model.inputText}" open=${model.menuOpen}');
    expect(model.inputText, isNot(contains('sq')));
  });
}
