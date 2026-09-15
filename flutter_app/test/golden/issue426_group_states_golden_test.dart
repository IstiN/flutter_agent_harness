// Goldens for issue #426: subagent group states of [SessionTile] —
// collapsed parent (chevron + "N agents" badge), expanded parent with
// children, and an active/live parent. Pumped through the shared golden
// helper so real bundled fonts render (no placeholder boxes).
import 'package:fa/ui/widgets/sidebar_sessions_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

Future<void> _pump(
  WidgetTester tester,
  List<Widget> tiles, {
  Size size = const Size(360, 300),
}) async {
  await pumpGolden(
    tester,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 340,
        child: Column(mainAxisSize: MainAxisSize.min, children: tiles),
      ),
    ),
    size: size,
  );
}

void main() {
  setUpAll(ensureGoldenFonts);

  testWidgets('parent collapsed', (tester) async {
    await _pump(tester, [
      SessionTile(
        title: 'goal_builder',
        subtitle: '10:24 AM',
        isActive: false,
        childCount: 7,
        expanded: false,
        onToggleExpand: () {},
        onTap: () {},
        onMenu: (_) {},
      ),
      SessionTile(
        title: 'lab355',
        subtitle: '7:31 PM',
        isActive: false,
        onTap: () {},
        onMenu: (_) {},
      ),
    ]);
    await expectLater(
      find.byType(Column).first,
      matchesGoldenFile('goldens/issue426_group_collapsed.png'),
    );
  });

  testWidgets('parent expanded with children', (tester) async {
    await _pump(tester, [
      SessionTile(
        title: 'goal_builder',
        subtitle: '10:24 AM',
        isActive: false,
        childCount: 2,
        expanded: true,
        onToggleExpand: () {},
        onTap: () {},
        onMenu: (_) {},
      ),
      SessionTile(
        title: 'subagent 01a0a0d0',
        subtitle: '7:46 PM',
        isActive: false,
        subagent: true,
        indent: 24,
        onTap: () {},
        onMenu: (_) {},
      ),
      SessionTile(
        title: 'subagent 01a0a0b8',
        subtitle: '7:20 PM',
        isActive: false,
        subagent: true,
        indent: 24,
        onTap: () {},
        onMenu: (_) {},
      ),
    ], size: const Size(360, 400));
    await expectLater(
      find.byType(Column).first,
      matchesGoldenFile('goldens/issue426_group_expanded.png'),
    );
  });

  testWidgets('active live parent', (tester) async {
    await _pump(tester, [
      SessionTile(
        title: 'support',
        subtitle: 'Now',
        isActive: true,
        live: true,
        childCount: 3,
        expanded: false,
        onToggleExpand: () {},
        onTap: () {},
        onMenu: (_) {},
      ),
    ], size: const Size(360, 220));
    await expectLater(
      find.byType(SessionTile),
      matchesGoldenFile('goldens/issue426_group_active.png'),
    );
  });
}
