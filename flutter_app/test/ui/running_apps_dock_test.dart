// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/apps/running_apps_dock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show MemoryExecutionEnv;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('collapsed mini-app strip has a 44pt touch target', (
    tester,
  ) async {
    const app = JsAppInfo(
      id: 'demo',
      name: 'Demo app',
      description: 'Demo',
      icon: 'D',
      declaredPermissions: AppPermissions(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        home: Material(
          child: Align(
            alignment: Alignment.centerRight,
            child: RunningAppsDock(
              apps: const [app],
              activeAppId: null,
              env: MemoryExecutionEnv(),
              onOpen: (_) {},
            ),
          ),
        ),
      ),
    );

    final handle = find.byKey(const ValueKey('runningAppsDockHandle'));
    final handleRect = tester.getRect(handle);
    expect(handleRect.width, greaterThanOrEqualTo(44));
    expect(handleRect.height, greaterThanOrEqualTo(44));
    expect(
      tester.getSize(find.byKey(const ValueKey('runningAppsDockHandleVisual'))),
      const Size(12, 74),
    );

    // Four points inside the new transparent target is 30 points beyond the
    // old 12pt visual strip: no precise aiming at the handle is required.
    await tester.tapAt(Offset(handleRect.left + 4, handleRect.center.dy));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('runningAppsDockList')), findsOneWidget);
  });
}
