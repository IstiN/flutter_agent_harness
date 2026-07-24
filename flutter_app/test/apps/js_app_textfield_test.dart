// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';

/// Typing in a textField node must fire the app's onChange action with the
/// current text on every keystroke.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('textField onChange reaches JS with the typed text', (
    tester,
  ) async {
    const widgetJs = '''
(function() {
  var text = '';
  function render() {
    jsr.render({
      type: 'textField',
      hint: 'Write…',
      value: text,
      onChange: 'typed',
    });
  }
  jsr.onEvent(function(actionId, payload) {
    if (actionId === 'typed') {
      text = payload.value || '';
      jsr.exportState({text: text});
      render();
    }
  });
  render();
})();
''';
    final env = MemoryExecutionEnv();
    await env.writeFile('apps/notes/widget.js', widgetJs);
    late final JsAppEngine engine;
    await tester.runAsync(() async {
      engine = JsAppEngine(
        app: JsAppInfo.fromManifest(
          const {'id': 'notes', 'name': 'Notes'},
          bundled: false,
          fallbackId: 'notes',
        ),
        env: env,
        permissions: const AppPermissions(),
      );
      await engine.start();
      for (var i = 0; i < 20 && engine.tree.value == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    addTearDown(() async {
      await tester.runAsync(engine.dispose);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<Map<String, dynamic>?>(
            valueListenable: engine.tree,
            builder: (context, tree, _) {
              if (tree == null) return const SizedBox.shrink();
              return JsonWidgetRenderer(
                theme: JsonWidgetTheme.fromAccent(
                  Theme.of(context).colorScheme.primary,
                ),
                onEvent: (id, payload) => engine.callEvent(id, payload),
              ).build(tree, context);
            },
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'hello');

    var state = '';
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      state = '${engine.exportedState?['text'] ?? ''}';
      if (state == 'hello') break;
      await tester.pump();
    }
    expect(state, 'hello');
  });
}
