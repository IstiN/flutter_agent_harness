// Issue #382, model level: a refresh-only hub push (the event-subscription
// path) must never open a closed overlay, and must refresh an open one in
// place. Split out of fa_tui_test.dart to stay under the 2800-line gate.
import 'package:dart_tui/dart_tui.dart';
import 'package:flutter_agent_harness/src/cli/agent_hub_tui.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:test/test.dart';

void main() {
  FaTuiCallbacks hubCallbacks() => FaTuiCallbacks(
    onSubmit: (_, {images = const []}) async {},
    onModelSelected: (_) async {},
    buildSlashMenu: (_) => const [],
    buildModelMenu: (_, _) => const [],
    statusLine: () => '/work · 0tok · turn 0 · test-model',
    prompt: 'fa> ',
  );

  FaHubState tree() => FaHubState.tree(
    footer: '',
    rows: const [
      HubLine('main', key: 'main'),
      HubLine('  a1', key: 'a1'),
    ],
  );

  FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

  test('a refresh-only push never opens a closed overlay (#382)', () {
    var model = FaTuiModel(callbacks: hubCallbacks(), isExited: () => false);
    model = send(model, HubStateMsg(tree(), refreshOnly: true));
    expect(model.hub, isNull, reason: 'a child event may not open the hub');
    // The same push without the flag still opens (the /agents path).
    model = send(model, HubStateMsg(tree()));
    expect(model.hub, isNotNull);
  });

  test('a refresh-only push refreshes an open overlay in place (#382)', () {
    var model = FaTuiModel(
      callbacks: hubCallbacks(),
      isExited: () => false,
      hub: tree(),
    );
    model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.down)));
    model = send(
      model,
      HubStateMsg(
        FaHubState.tree(
          footer: 'Σ 512 tok',
          rows: const [
            HubLine('main · 512 tok', key: 'main'),
            HubLine('  a1 · 512 tok', key: 'a1'),
          ],
        ),
        refreshOnly: true,
      ),
    );
    expect(model.hub, isNotNull, reason: 'the open overlay stays open');
    expect(
      model.hub!.selectedKey,
      'a1',
      reason: 'the refresh carries the selection',
    );
    expect(
      model.hub!.lines.first.text,
      'main · 512 tok',
      reason: 'the refresh swapped in the fresh rows',
    );
  });
}
