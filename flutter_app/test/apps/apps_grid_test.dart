// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_grid.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

const _manifest = '''
{
  "id": "demo",
  "name": "Demo App",
  "description": "A demo app",
  "icon": "🧪"
}
''';

Future<MemoryExecutionEnv> _seededEnv() async {
  final env = MemoryExecutionEnv();
  await env.writeFile('apps/demo/manifest.json', _manifest);
  await env.writeFile(
    'apps/demo/widget.js',
    '(function(){ jsr.render({type:"text",data:"hi"}); })();',
  );
  return env;
}

void main() {
  testWidgets('apps grid lists discovered apps', (tester) async {
    final env = await _seededEnv();
    final permissions = await AppPermissionsStore.load(env);
    await tester.pumpWidget(
      MaterialApp(
        home: AppsGridView(
          env: env,
          permissionsStore: permissions,
          appsStore: AppsStore(
            env,
            readAsset: (path) async =>
                throw StateError('no bundled assets in this test'),
            seedDemoIds: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Demo App'), findsOneWidget);
    expect(find.text('A demo app'), findsOneWidget);
    expect(find.text('🧪'), findsOneWidget);
  });

  testWidgets('empty apps folder shows the hint', (tester) async {
    final env = MemoryExecutionEnv();
    final permissions = await AppPermissionsStore.load(env);
    await tester.pumpWidget(
      MaterialApp(
        home: AppsGridView(
          env: env,
          permissionsStore: permissions,
          appsStore: AppsStore(
            env,
            readAsset: (path) async =>
                throw StateError('no bundled assets in this test'),
            seedDemoIds: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Ask Fa to build one'), findsOneWidget);
  });
}
