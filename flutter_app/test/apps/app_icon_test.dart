// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

const _svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
    '<rect x="4" y="4" width="16" height="16" fill="#fff"/>'
    '</svg>';

JsAppInfo _app(String icon) => JsAppInfo.fromManifest(
  {'id': 'demo', 'name': 'Demo', 'icon': icon},
  bundled: false,
  fallbackId: 'demo',
);

void main() {
  testWidgets('emoji icon renders as text', (tester) async {
    final env = MemoryExecutionEnv();
    await tester.pumpWidget(
      MaterialApp(
        home: AppIcon(app: _app('🧮'), env: env),
      ),
    );
    expect(find.text('🧮'), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
  });

  testWidgets('inline svg markup renders as SvgPicture', (tester) async {
    final env = MemoryExecutionEnv();
    await tester.pumpWidget(
      MaterialApp(
        home: AppIcon(app: _app(_svg), env: env),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('svg file icon loads from the app folder in the env', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await env.writeFile('apps/demo/icon.svg', _svg);
    await tester.pumpWidget(
      MaterialApp(
        home: AppIcon(app: _app('icon.svg'), env: env),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('missing svg file falls back to the placeholder', (tester) async {
    final env = MemoryExecutionEnv();
    await tester.pumpWidget(
      MaterialApp(
        home: AppIcon(app: _app('missing.svg'), env: env),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('📦'), findsOneWidget);
  });
}
