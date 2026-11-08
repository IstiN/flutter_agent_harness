/// The icon-action family in one frame: sidebar toggle + the grouped
/// chat-header capsule + Files ✕/search/refresh band. Every target stays
/// 36pt on one centerline; adjacent chat/Files actions share one surface
/// instead of rendering separate circles, with ink1 glyphs throughout.
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
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassIconButton;
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// The unified family: the shell's left toggle, the chat header's
/// grouped trajectory/copy band, then the Files band (✕ · capsule · refresh).
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
            // The real chat-header contract: adjacent actions share ONE
            // capsule, with 36pt targets and no per-action circles.
            const SizedBox(width: 8),
            FaIconActionBand<String>(
              glass: true,
              actions: [
                FaHeaderAction(
                  key: const ValueKey('bandTrajectory'),
                  icon: Icons.show_chart,
                  label: 'Trajectory',
                  onPressed: () {},
                ),
                FaHeaderAction(
                  key: const ValueKey('bandCopy'),
                  icon: Icons.copy_outlined,
                  label: 'Copy session',
                  onPressed: () {},
                ),
              ],
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
  // The adapter pass: glass-direction buttons are the kit's
  // GlassIconButton — its own render box IS the circle.
  final w = tester.widget(of);
  if (w is IconButton) return of;
  if (w is FaHeaderCircularAction || w is GlassIconButton) {
    return of;
  }
  // The adapter pass: a glass-direction FaIconActionButton composes the
  // kit's GlassIconButton as its chrome (no FaHeaderCircularAction).
  final asKitChild = find.descendant(
    of: of,
    matching: find.byType(GlassIconButton),
  );
  if (asKitChild.evaluate().isNotEmpty) return asKitChild.first;
  final asChild = find.descendant(
    of: of,
    matching: find.byType(FaHeaderCircularAction),
  );
  if (asChild.evaluate().isNotEmpty) return asChild.first;
  return find
      .ancestor(of: of, matching: find.byType(FaHeaderCircularAction))
      .first;
}

Rect _circleOf(WidgetTester tester, Key key) =>
    tester.getRect(_chromeOf(tester, key));

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
    // The floating chat band is glass; the Files action band sitting on
    // a parent surface is flat. Both contain no per-action chrome.
    final headerBand = find
        .ancestor(
          of: find.byKey(const ValueKey('bandTrajectory')),
          matching: find.byType(FaIconActionBand<String>),
        )
        .first;
    final filesBand = find
        .ancestor(
          of: find.byKey(const ValueKey('fileBrowserRefresh')),
          matching: find.byType(FaIconActionBand<int>),
        )
        .first;
    final headerSurface = tester.widget<FaSurface>(
      find.descendant(of: headerBand, matching: find.byType(FaSurface)).first,
    );
    final filesSurface = tester.widget<FaSurface>(
      find.descendant(of: filesBand, matching: find.byType(FaSurface)).first,
    );
    expect(headerSurface.glass, isTrue);
    expect(filesSurface.glass, isFalse);
    for (final band in [headerBand, filesBand]) {
      expect(
        find.descendant(
          of: band,
          matching: find.byType(FaHeaderCircularAction),
        ),
        findsNothing,
      );
    }

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
    final capsule = tester.getRect(
      find.byKey(const ValueKey('fileBrowserSearch')),
    );
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

    // One ink everywhere; standalone and grouped controls share the same
    // glyph language without forcing the standalone chrome's shape.
    final tokens = FaDesignTokens.of(tester.element(find.byType(_Band)));
    for (final key in keys) {
      final chrome = _chromeOf(tester, key);
      expect(
        IconTheme.of(
          tester.element(
            find.descendant(of: chrome, matching: find.byType(Icon)).first,
          ),
        ).color,
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
      theme: buildFaTheme(
        direction: FaVisualDirection.glass,
        brightness: Brightness.dark,
      ),
      wrap: (child) => child,
    );

    final openRect = tester.getRect(
      find.byKey(const ValueKey('sidebarToggleOpen')),
    );
    final closedRect = tester.getRect(
      find.byKey(const ValueKey('sidebarToggleClosed')),
    );
    // One diameter, one centerline — the two states differ ONLY in the
    // glass underlay.
    expect(openRect.size, closedRect.size);
    expect(openRect.size, Size.square(FaIconActionButton.defaultDiameter));
    expect(openRect.center.dy, closeTo(closedRect.center.dy, .5));
    // Exactly ONE glass underlay: the floating (closed) state. The
    // adapter pass renders it as the kit's GlassIconButton (the glass
    // surface itself); the docked twin stays flat Material chrome.
    expect(find.byType(GlassIconButton).evaluate().length, 1);
    expect(find.byType(FaSurface).evaluate().length, 0);
    final tokens = FaDesignTokens.of(
      tester.element(find.byType(_SidebarToggleStates)),
    );
    final flatToggle = tester
        .widgetList<Material>(
          find.descendant(
            of: find.byKey(const ValueKey('sidebarToggleOpen')),
            matching: find.byType(Material),
          ),
        )
        .firstWhere((m) => m.shape != null);
    expect(
      flatToggle.shape,
      isA<CircleBorder>(),
      reason: 'docked twin keeps the token circle',
    );
    expect(flatToggle.color, tokens.surface2);

    await expectGolden(tester, 'fa_icon_action_glass_states');
  });
}
