// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String? result;

  Widget harness() {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await pushFaPage<String>(
                context,
                Scaffold(
                  appBar: AppBar(title: const Text('Editor')),
                  body: TextButton(
                    onPressed: () => Navigator.of(context).pop('saved'),
                    child: const Text('Finish'),
                  ),
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
  }

  setUp(() => result = null);

  testWidgets('narrow canvas pushes a full-screen route (no Dialog)', (
    tester,
  ) async {
    // Default test surface is 800x600 — below the dialog threshold.
    await tester.pumpWidget(harness());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Editor'), findsOneWidget);

    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    expect(result, 'saved');
    expect(find.text('Editor'), findsNothing);
  });

  testWidgets('wide canvas presents the page in a constrained Dialog', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetDevicePixelRatio());
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(harness());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Editor'), findsOneWidget);
    final pageSize = tester.getSize(find.byType(Scaffold).last);
    expect(pageSize.width, lessThanOrEqualTo(560));
    expect(pageSize.height, lessThanOrEqualTo(720));

    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    expect(result, 'saved');
    expect(find.byType(Dialog), findsNothing);
  });
}
