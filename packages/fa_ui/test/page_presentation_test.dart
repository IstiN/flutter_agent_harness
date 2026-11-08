// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

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
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Editor'), findsOneWidget);
    // The page's Scaffold inside the dialog (the outer app Scaffold is
    // unrelated chrome).
    final pageSize = tester.getSize(
      find.descendant(of: find.byType(Dialog), matching: find.byType(Scaffold)),
    );
    // The dialog's own sizing wrapper (other ConstrainedBoxes come from the
    // page's internals) — identified by its maxWidth cap.
    final box = tester
        .widgetList<ConstrainedBox>(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.byType(ConstrainedBox),
          ),
        )
        .singleWhere((b) => b.constraints.maxWidth == 560);
    expect(box.constraints.maxHeight, 756); // 84% of the 900px surface
    expect(pageSize.width, lessThanOrEqualTo(560));
    expect(pageSize.height, lessThanOrEqualTo(756));
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(FaDialogScope),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    expect(result, 'saved');
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('dialog width override and height follow a live window resize', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                pushFaPage<void>(
                  context,
                  const Scaffold(body: Text('Wide settings')),
                  dialogMaxWidth: 840,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    ConstrainedBox dialogBox() => tester
        .widgetList<ConstrainedBox>(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.byType(ConstrainedBox),
          ),
        )
        .singleWhere((box) => box.constraints.maxWidth == 840);

    expect(dialogBox().constraints.maxHeight, 756);
    expect(
      tester.getSize(find.byType(Scaffold).last).width,
      lessThanOrEqualTo(840),
    );

    // The route was opened while wide, then the desktop window became
    // shorter. Constraints must come from the DIALOG's live MediaQuery,
    // not the size captured at push time.
    tester.view.physicalSize = const Size(1000, 700);
    await tester.pumpAndSettle();
    expect(dialogBox().constraints.maxHeight, 588);
    expect(tester.getSize(find.byType(Scaffold).last).height, 588);
  });

  group('dialog backdrop by visual direction', () {
    Future<void> pumpWide(WidgetTester tester, FaVisualDirection direction) {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.reset);
      return tester.pumpWidget(
        MaterialApp(
          theme: buildFaTheme(
            direction: direction,
            brightness: Brightness.dark,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => unawaited(
                  pushFaPage<void>(context, const Scaffold(body: Text('Page'))),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('glass direction: transparent dialog + scope marker', (
      tester,
    ) async {
      await pumpWide(tester, FaVisualDirection.glass);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final dialog = tester.widget<Dialog>(find.byType(Dialog));
      expect(dialog.backgroundColor, Colors.transparent);
      expect(dialog.surfaceTintColor, Colors.transparent);
      expect(dialog.elevation, 0);
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(FaGlassDialogScope),
        ),
        findsOneWidget,
      );
    });

    testWidgets('opaque direction: stock dialog, no scope marker', (
      tester,
    ) async {
      await pumpWide(tester, FaVisualDirection.graphite);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final dialog = tester.widget<Dialog>(find.byType(Dialog));
      expect(dialog.backgroundColor, isNot(Colors.transparent));
      expect(find.byType(FaGlassDialogScope), findsNothing);
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(FaDialogScope),
        ),
        findsOneWidget,
      );
    });
  });
}
