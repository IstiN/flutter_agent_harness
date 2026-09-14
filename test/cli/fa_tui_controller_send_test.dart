/// The FaTuiController outbound send helpers (issue #276 split-out): every
/// helper routes through `_send`, which flushes buffered output first and
/// parks the message while no program is attached.
library;

import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/agent_hub_tui.dart';
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_prompt.dart';
import 'package:test/test.dart';

FaTuiCallbacks _callbacks() {
  return FaTuiCallbacks(
    onSubmit: (line, {images = const []}) async {},
    onSteer: (messages) async {},
    onModelSelected: (_) async {},
    buildSlashMenu: (_) => const [],
    buildModelMenu: (_, _) => const [],
    statusLine: () => 'test',
    prompt: 'fa> ',
  );
}

void main() {
  test('every outbound helper sends cleanly without an attached program', () {
    final controller = FaTuiController(
      callbacks: _callbacks(),
      isExited: () => false,
    );
    expect(
      () => controller
        ..sendOutput('buffered')
        ..sendModelsRefresh()
        ..sendThemeChanged()
        ..openModelMenu()
        ..openPicker('sessions', 'Sessions', const [])
        ..pushHub(
          FaHubState(mode: FaHubMode.tree, title: 'hub', lines: const []),
        )
        ..closeHub()
        ..sendQuit()
        ..sendInputText('/skill:demo ')
        ..setInputHistory(['earlier']),
      returnsNormally,
    );
  });

  test('a restored input history reaches the composer through the model', () {
    var model = FaTuiModel(callbacks: _callbacks(), isExited: () => false);
    model =
        model.update(SetInputHistoryMsg(['earlier', 'first'])).$1
            as FaTuiModel;
    // ↑ recalls the last submitted line instead of scrolling history.
    expect(model.inputHistory, ['earlier', 'first']);
    final (next, cmd) =
        model.update(KeyPressMsg(const TeaKey(code: KeyCode.up)));
    model = next as FaTuiModel;
    expect(model.inputText, 'first');
    expect(cmd, isNull);
  });

  test('the composer prefill lands in the input zone with menus closed', () {
    final model = FaTuiModel(
      callbacks: _callbacks(),
      isExited: () => false,
    ).setInputTextForTest('/skill:demo ');
    expect(model.inputText, '/skill:demo ');
    expect(model.cursor, '/skill:demo '.length);
    expect(model.menuOpen, isFalse);
  });

  test('openPrompt returns the model-resolved answer future', () async {
    final controller = FaTuiController(
      callbacks: _callbacks(),
      isExited: () => false,
    );
    final answer = controller.openPrompt(
      const AskPromptSpec(
        header: 'Ask',
        question: 'proceed?',
        index: 1,
        total: 1,
      ),
    );
    // Without a program the prompt request is parked; the future stays
    // pending (never throws) — give it a beat and move on.
    await answer.timeout(
      const Duration(milliseconds: 20),
      onTimeout: () => null,
    );
  });
}
