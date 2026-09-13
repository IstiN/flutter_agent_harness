// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A representative full header: project identity, title, chip and a
  // priority-ordered action list (the chat bar's real shape).
  Widget header({required double width, List<PopupMenuEntry<String>>? menu}) =>
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: Material(
              child: FaAdaptiveHeader(
                projectIcon: Icons.folder_outlined,
                projectLabel: 'Personal',
                title: 'Fa',
                chip: const SizedBox(
                  key: ValueKey('testChip'),
                  width: 120,
                  height: 28,
                ),
                actions: [
                  FaHeaderAction(
                    key: const ValueKey('testFiles'),
                    icon: Icons.folder_outlined,
                    label: 'Files',
                    onPressed: () {},
                  ),
                  FaHeaderAction(
                    key: const ValueKey('testTrajectory'),
                    icon: Icons.timeline,
                    label: 'Trajectory',
                    onPressed: () {},
                  ),
                  FaHeaderAction(
                    key: const ValueKey('testCopy'),
                    icon: Icons.copy_outlined,
                    label: 'Copy session',
                    onPressed: () {},
                  ),
                ],
                menuItems: menu ?? const <PopupMenuEntry<String>>[],
              ),
            ),
          ),
        ),
      );

  testWidgets('wide: project, title, chip and every action render inline '
      '(issue #225 AC1)', (tester) async {
    await tester.pumpWidget(header(width: 800));
    expect(find.text('Personal'), findsOneWidget);
    expect(find.text('Fa'), findsOneWidget);
    expect(find.byKey(const ValueKey('testChip')), findsOneWidget);
    expect(find.byKey(const ValueKey('testFiles')), findsOneWidget);
    expect(find.byKey(const ValueKey('testTrajectory')), findsOneWidget);
    expect(find.byKey(const ValueKey('testCopy')), findsOneWidget);
  });

  testWidgets('tight: the tail demotes into the ⋮ menu, primary actions '
      'stay inline (issue #225 AC2)', (tester) async {
    await tester.pumpWidget(header(width: 280));

    // Only Files still inline; Trajectory and Copy demoted.
    expect(find.byKey(const ValueKey('testFiles')), findsOneWidget);
    expect(find.byKey(const ValueKey('testTrajectory')), findsNothing);
    expect(find.byKey(const ValueKey('testCopy')), findsNothing);

    // The demoted actions are reachable through the ⋮ menu by label —
    // accessibility keeps the action's name wherever it renders.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Trajectory'), findsOneWidget);
    expect(find.text('Copy session'), findsOneWidget);
    expect(find.text('Files'), findsNothing);
  });

  testWidgets('extreme: the chip demotes last, after every action '
      '(issue #225)', (tester) async {
    await tester.pumpWidget(header(width: 200));

    expect(find.byKey(const ValueKey('testChip')), findsNothing);
    expect(find.byKey(const ValueKey('testFiles')), findsNothing);
    // The project identity survives: text yields, identity stays.
    expect(find.text('Personal'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Trajectory'), findsOneWidget);
    expect(find.text('Copy session'), findsOneWidget);
  });

  testWidgets('the pinned action never demotes (issue #225 E2)',
      (tester) async {
    var stopped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 120,
            child: Material(
              child: FaAdaptiveHeader(
                title: 'Fa',
                chip: const SizedBox(width: 120, height: 28),
                actions: [
                  FaHeaderAction(
                    key: const ValueKey('testStop'),
                    icon: Icons.stop,
                    label: 'Stop',
                    pinned: true,
                    onPressed: () => stopped++,
                  ),
                  FaHeaderAction(
                    icon: Icons.copy_outlined,
                    label: 'Copy session',
                    onPressed: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.copy_outlined), findsNothing);
    // Copy is still reachable through the ⋮ menu at this width.
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy session'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('testStop')), findsOneWidget);
  });

  testWidgets('no demotion and no menu items hides the ⋮ (issue #225 E4)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            child: Material(
              child: FaAdaptiveHeader(
                title: 'Fa',
                actions: [
                  FaHeaderAction(
                    icon: Icons.copy_outlined,
                    label: 'Copy session',
                    onPressed: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.more_vert), findsNothing);
  });

  testWidgets('menu-only entries keep the ⋮ and route selections '
      '(issue #225 E4)', (tester) async {
    var selected = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            child: Material(
              child: FaAdaptiveHeader(
                title: 'Fa',
                actions: const [],
                menuItems: const [
                  PopupMenuItem(value: 'new', child: Text('New session')),
                ],
                onMenuSelected: (value) => selected = value,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New session'));
    await tester.pumpAndSettle();
    expect(selected, 'new');
  });
}
