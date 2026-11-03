/// The ONE icon-action band (FaIconActionButton unification): sidebar
/// toggle + chat-header circles + Files band ✕/search/refresh laid
/// side-by-side, proving the family contract in one frame —
///   - every circle is the same 36pt diameter,
///   - every circle AND the 40pt search capsule share one centerline
///     (epsilon 0.5),
///   - one style: token surface2 fill + hairline ring + ink1 glyph.
///
/// The snapshot doubles as the marketing shot of the unified header band.
library;

import 'package:fa/ui/widgets/file_browser.dart' show FilesChrome;
import 'package:fa/ui/widgets/messenger_navigation_controls.dart'
    show MessengerSidebarToggle;
import 'package:fa/ui/widgets/session_search_field.dart'
    show kSearchFieldHeight;
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// The unified band: the shell's left toggle, the chat header's
/// trajectory/copy circles, then the Files band (✕ · capsule · refresh).
class _Band extends StatelessWidget {
  const _Band();

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return Material(
      color: tokens.surface1,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            MessengerSidebarToggle(
              expanded: true,
              tooltip: 'Collapse sidebar',
              onPressed: () {},
            ),
            // Chat header circles (trajectory + copy) at the control
            // scale — the REAL header chrome (FaHeaderCircularAction at
            // the 36pt FaIconActionButton default, the glass underlay the
            // floating header state carries), exactly what
            // fa_chat_screen's action builders render.
            const SizedBox(width: 8),
            FaHeaderCircularAction(
              key: const ValueKey('bandTrajectory'),
              dimension: FaIconActionButton.defaultDiameter,
              glass: true,
              child: IconButton(
                onPressed: () {},
                tooltip: 'Trajectory',
                icon: const Icon(Icons.show_chart, size: 18),
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            FaHeaderCircularAction(
              key: const ValueKey('bandCopy'),
              dimension: FaIconActionButton.defaultDiameter,
              glass: true,
              child: IconButton(
                onPressed: () {},
                tooltip: 'Copy session',
                icon: const Icon(Icons.copy_outlined, size: 18),
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            // The two glass states of the ONE action (owner rule): the
            // Files/folder toggle glass while floating on the header
            // backdrop, flat on a parent surface (Files band).
            FaIconActionButton(
              key: const ValueKey('bandFolderGlass'),
              icon: Icons.folder_outlined,
              tooltip: 'Files (floating)',
              glass: true,
              onPressed: () {},
            ),
            const SizedBox(width: 8),
            FaIconActionButton(
              key: const ValueKey('bandFolderFlat'),
              icon: Icons.folder_outlined,
              tooltip: 'Files (on band)',
              onPressed: () {},
            ),
            const SizedBox(width: 8),
            SizedBox(
              // Roomy enough that the refresh action stays inline (the
              // band's desktop minimum keeps the capsule at 220).
              width: 420,
              child: FilesChrome(
                searchController: TextEditingController(),
                onClose: () {},
                closeKey: const ValueKey('filesAppClose'),
                searchKey: const ValueKey('fileBrowserSearch'),
                actions: [
                  FaHeaderAction(
                    key: const ValueKey('fileBrowserRefresh'),
                    icon: Icons.refresh,
                    label: 'Refresh',
                    onPressed: () {},
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The chrome around a band button. Band keys on FaIconActionButton hold
/// the chrome as their CHILD (the component composes the chrome); keys on
/// inner buttons (the Files band's) hold it as an ANCESTOR.
Finder _chromeOf(WidgetTester tester, Key key) {
  final of = find.byKey(key);
  // The keyed widget may BE the chrome (the chat-header circles), hold it
  // as a CHILD (FaIconActionButton composes the chrome), or sit INSIDE it
  // (the Files band's inner buttons).
  if (tester.widget(of) is FaHeaderCircularAction) {
    return of;
  }
  final asChild = find.descendant(
    of: of,
    matching: find.byType(FaHeaderCircularAction),
  );
  if (asChild.evaluate().isNotEmpty) return asChild.first;
  return find
      .ancestor(of: of, matching: find.byType(FaHeaderCircularAction))
      .first;
}

Rect _circleOf(WidgetTester tester, Key key) => tester.getRect(_chromeOf(tester, key));

/// The sidebar toggle's two states (vision-confirmed owner rule): panel
/// OPEN — the toggle sits ON the panel band → FLAT token surface; panel
/// CLOSED — the toggle floats over the transcript with no panel under it
/// → glass underlay. Same widget, one flag, two looks.
class _SidebarToggleStates extends StatelessWidget {
  const _SidebarToggleStates();

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return Material(
      color: tokens.surface1,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MessengerSidebarToggle(
              key: const ValueKey('sidebarToggleOpen'),
              expanded: true,
              tooltip: 'Collapse sidebar',
              onPressed: () {},
            ),
            const SizedBox(width: 24),
            MessengerSidebarToggle(
              key: const ValueKey('sidebarToggleClosed'),
              expanded: false,
              floating: true,
              tooltip: 'Expand sidebar',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  setUpAll(ensureGoldenFonts);

  testWidgets('one diameter, one centerline, one style', (tester) async {
    await pumpGolden(
      tester,
      const _Band(),
      size: const Size(720, 120),
      wrap: (child) => child,
    );

    const keys = [
      ValueKey('bandTrajectory'),
      ValueKey('bandCopy'),
      ValueKey('bandFolderGlass'),
      ValueKey('bandFolderFlat'),
      ValueKey('filesAppClose'),
      ValueKey('fileBrowserRefresh'),
    ];
    // Glass vs flat (same button, two states): the floating header
    // chrome (sidebar toggle excluded — docked/flat here) carries the
    // glass underlay — the two chat-header circles and the folder
    // toggle; the on-band folder twin and the Files band render none.
    expect(find.byType(FaSurface).evaluate().length, 3,
        reason: 'the two header circles + the floating folder toggle');
    final glassSurfaces = tester
        .widgetList<FaSurface>(find.byType(FaSurface))
        .every((surface) => surface.glass);
    expect(glassSurfaces, isTrue, reason: 'all three are glass states');

    // EQUAL diameters: every circle in the band is 36pt — the sidebar
    // toggle (its key rides the inner button) and each chrome circle.
    double centerOf(Rect rect) => rect.center.dy;
    final toggle = tester.getRect(
      find.byKey(const ValueKey('chatSidebarCollapse')),
    );
    expect(toggle.width, FaIconActionButton.defaultDiameter);
    expect(toggle.height, FaIconActionButton.defaultDiameter);
    for (final key in keys) {
      expect(
        _circleOf(tester, key).width,
        FaIconActionButton.defaultDiameter,
        reason: '$key diameter',
      );
      expect(
        _circleOf(tester, key).height,
        FaIconActionButton.defaultDiameter,
        reason: '$key diameter',
      );
    }

    // EQUAL center ys (epsilon 0.5): the toggle, every circle AND the
    // shared search field sit on ONE centerline.
    final capsule = tester.getRect(find.byKey(const ValueKey('fileBrowserSearch')));
    // The band renders the ONE SessionSearchField at the restored
    // sidebar-search height (the dense 32px inset, not the retired 40pt
    // capsule); its center rides the circles' centerline.
    expect(capsule.height, kSearchFieldHeight, reason: 'shared field height');
    expect(capsule.height, 32, reason: 'the old sidebar-search inset');
    final centerline = centerOf(toggle);
    for (final key in keys) {
      expect(
        centerOf(_circleOf(tester, key)),
        closeTo(centerline, .5),
        reason: '$key centerline',
      );
    }
    expect(centerOf(capsule), closeTo(centerline, .5), reason: 'capsule');

    // ONE style: token surface2 fill + hairline ring, ink1 glyph ink.
    final tokens = FaDesignTokens.of(tester.element(find.byType(_Band)));
    for (final key in keys) {
      final chrome = _chromeOf(tester, key);
      // The glass state's underlay adds an unshaded Material wrapper; the
      // chrome's own circle is the shaped one.
      final material = tester
          .widgetList<Material>(
            find.descendant(of: chrome, matching: find.byType(Material)),
          )
          .firstWhere((m) => m.shape != null);
      final shape = material.shape! as CircleBorder;
      expect(material.color, tokens.surface2, reason: '$key fill');
      expect(shape.side.color, tokens.hairline, reason: '$key ring');
      expect(
        IconTheme.of(tester.element(find.descendant(
          of: chrome,
          matching: find.byType(Icon),
        ).first)).color,
        tokens.ink1,
        reason: '$key ink',
      );
    }

    await expectGolden(tester, 'fa_icon_action_band');
  });

  testWidgets('sidebar toggle: flat on the open panel, glass when floating', (
    tester,
  ) async {
    await pumpGolden(
      tester,
      const _SidebarToggleStates(),
      size: const Size(280, 120),
      theme: buildFaTheme(direction: FaVisualDirection.glass, brightness: Brightness.dark),
      wrap: (child) => child,
    );

    final openRect = tester.getRect(find.byKey(const ValueKey('sidebarToggleOpen')));
    final closedRect = tester.getRect(
      find.byKey(const ValueKey('sidebarToggleClosed')),
    );
    // One diameter, one centerline — the two states differ ONLY in the
    // glass underlay.
    expect(openRect.size, closedRect.size);
    expect(
      openRect.size,
      Size.square(FaIconActionButton.defaultDiameter),
    );
    expect(openRect.center.dy, closeTo(closedRect.center.dy, .5));
    // Exactly ONE glass underlay: the floating (closed) state.
    expect(find.byType(FaSurface).evaluate().length, 1);
    final surface = tester.widget<FaSurface>(find.byType(FaSurface));
    expect(surface.glass, isTrue);
    expect(surface.circular, isTrue);

    await expectGolden(tester, 'fa_icon_action_glass_states');
  });
}
