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

/// Hit-area map (user review aid): highlights what is tappable on a tile —
/// green = whole-row tap (open session), blue = expand/collapse pill,
/// orange = 36x36 3-dot menu.
testWidgets('hit areas overlay', (tester) async {
  List<Rect> tileRects = const [];
  Rect? pillRect;
  Rect? menuRect;
  await pumpGolden(
    tester,
    StatefulBuilder(builder: (context, setState) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final inkwells = tester.widgetList<InkWell>(
          find.descendant(
            of: find.byType(SessionTile),
            matching: find.byType(InkWell),
          ),
        );
        tileRects = tester
            .widgetList(find.byType(SessionTile))
            .map((w) => tester.getRect(find.byWidget(w)))
            .toList();
        for (final iw in inkwells) {
          final r = tester.getRect(find.byWidget(iw).first);
          if (iw.borderRadius == BorderRadius.circular(999)) {
            pillRect = r;
          } else if (r.width == 36 && r.height == 36) {
            menuRect = r;
          }
        }
      });
      return Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 340,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
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
          ]),
        ),
      );
    }),
    size: const Size(360, 300),
  );
  await tester.pump();
  final overlays = <Widget>[
    for (final tileRect in tileRects)
      Positioned.fromRect(
        rect: tileRect,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF22C55E), width: 1.5),
            color: const Color(0x3322C55E),
          ),
        ),
      ),
    if (pillRect != null)
      Positioned.fromRect(
        rect: pillRect!,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF3B82F6), width: 1.5),
            color: const Color(0x403B82F6),
          ),
        ),
      ),
    if (menuRect != null)
      Positioned.fromRect(
        rect: menuRect!,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFF97316), width: 1.5),
            color: const Color(0x40F97316),
          ),
        ),
      ),
    const Positioned(
      left: 8,
      bottom: 6,
      child: Row(children: [
        _Legend(color: Color(0xFF22C55E), label: 'tap = open'),
        SizedBox(width: 10),
        _Legend(color: Color(0xFF3B82F6), label: 'toggle group'),
        SizedBox(width: 10),
        _Legend(color: Color(0xFFF97316), label: 'menu 36x36'),
      ]),
    ),
  ];
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Stack(children: [
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 340,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
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
              ]),
            ),
          ),
          ...overlays,
        ]),
      ),
    ),
  );
  await tester.pump();
  await expectLater(
    find.byType(Stack).first,
    matchesGoldenFile('goldens/issue426_hit_areas.png'),
  );
});
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 10, height: 10, color: color),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 10, color: Colors.white)),
    ]);
  }
}
