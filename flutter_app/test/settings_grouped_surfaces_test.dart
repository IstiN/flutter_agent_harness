// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fa/services/agent_service.dart';
import 'package:fa/ui/screens/redaction_section.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/screens/settings_tiles.dart';
import 'package:fa/ui/screens/skills_toggles_section.dart';
import 'package:fa/ui/screens/tools_availability_section.dart';
import 'package:fa_ui/fa_ui.dart' as faui;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Pins the shared-direction settings redesign: one grouped-card layout
/// in every visual direction, a glass page platter in the glass
/// direction, and transparent page chrome only when the page is
/// presented inside the wide glass dialog (faui.pushFaPage).
void main() {
  AgentService fakeService() {
    return AgentService(
      agent: Agent(
        model: Model(
          id: 'test-model',
          api: 'test-api',
          provider: 'test',
          baseUrl: 'https://example.com',
          contextWindow: 100000,
          maxTokens: 4096,
        ),
        systemPrompt: 'You are Fa.',
        streamFunction: (model, context, {cancelToken}) {
          final stream = AssistantMessageEventStream();
          stream.end();
          return stream;
        },
        toolRegistry: ToolRegistry(const []),
      ),
      env: MemoryExecutionEnv(),
      sessionsRoot: '/sessions',
    );
  }

  faui.FaSurface platter(WidgetTester tester) {
    // The page platter is the outermost FaSurface: the one that is an
    // ancestor of the providers group but has no FaSurface ancestor of
    // its own (groups nest inside it, never the reverse).
    final surfaces = tester.widgetList<faui.FaSurface>(
      find.byType(faui.FaSurface),
    );
    expect(surfaces, isNotEmpty);
    return surfaces.firstWhere(
      (s) => find
          .descendant(
            of: find.byWidget(s),
            matching: find.byType(SettingsGroup),
          )
          .evaluate()
          .isNotEmpty,
    );
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    faui.FaVisualDirection direction,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: faui.buildFaTheme(
          direction: direction,
          brightness: Brightness.dark,
        ),
        home: SettingsScreen(service: fakeService()),
      ),
    );
  }

  /// The standalone glass underlay: a full-page DecoratedBox carrying
  /// the token background→accentSoft→background gradient.
  Finder gradientUnderlay() =>
      find.byKey(const ValueKey('settingsGlassUnderlay'));

  void expectGroupedSections(WidgetTester tester) {
    // ProvidersSection and the Models row are wrapped at the settings
    // call site — the card is their ANCESTOR.
    expect(
      find.ancestor(
        of: find.byType(faui.ProvidersSection),
        matching: find.byType(SettingsGroup),
      ),
      findsOneWidget,
      reason: 'ProvidersSection must sit inside a SettingsGroup card',
    );
    // Skills/Tools/Redaction build their own card — it is their direct
    // DESCENDANT (the section widget is the group's builder).
    for (final type in [
      SkillsTogglesSection,
      ToolsAvailabilitySection,
      RedactionSection,
    ]) {
      expect(
        find.descendant(
          of: find.byType(type),
          matching: find.byType(SettingsGroup),
        ),
        findsOneWidget,
        reason: '$type must build its own SettingsGroup card',
      );
    }
    // The Models navigation row is a grouped card too (its private row
    // type is found through the chevron it trails).
    expect(
      find.ancestor(
        of: find.byIcon(Icons.chevron_right),
        matching: find.byType(SettingsGroup),
      ),
      findsWidgets,
    );
  }

  testWidgets('glass: sections group into solid cards on a glass platter', (
    tester,
  ) async {
    await pumpScreen(tester, faui.FaVisualDirection.glass);
    await tester.pumpAndSettle();

    expectGroupedSections(tester);
    final surface = platter(tester);
    expect(surface.glass, isTrue);
    // Standalone route: the page chrome stays opaque — only the wide
    // glass dialog makes it transparent.
    // Standalone glass route: transparent Scaffold AND AppBar, over the
    // local token gradient underlay (the glass has something to sample).
    final scaffold = tester.widget<Scaffold>(
      find.ancestor(
        of: find.byType(faui.ProvidersSection),
        matching: find.byType(Scaffold),
      ),
    );
    expect(scaffold.backgroundColor, Colors.transparent);
    expect(gradientUnderlay(), findsOneWidget);
    final gradient =
        (tester.widget<DecoratedBox>(gradientUnderlay()).decoration
                    as BoxDecoration)
                .gradient
            as LinearGradient;
    expect(gradient.stops, const [0, .5, 1]);
    expect(gradient.colors.length, 3);
    expect(gradient.colors[1].a, closeTo(.20, .001));
    final appBarContext = tester.element(find.byType(AppBar));
    expect(
      Theme.of(appBarContext).appBarTheme.backgroundColor,
      Colors.transparent,
    );
  });

  testWidgets('opaque direction shares the same grouped layout', (
    tester,
  ) async {
    await pumpScreen(tester, faui.FaVisualDirection.graphite);
    await tester.pumpAndSettle();

    expectGroupedSections(tester);
    // The platter exists with the same geometry; only its finish is
    // opaque (the direction's background, not the glass surface tint).
    final surface = platter(tester);
    final tokens = faui.FaDesignTokens.forDirection(
      faui.FaVisualDirection.graphite,
      Brightness.dark,
    );
    expect(surface.color, tokens.background);
    expect(surface.borderRadius, BorderRadius.circular(18));
    // Opaque directions: no gradient underlay, stock opaque chrome.
    expect(gradientUnderlay(), findsNothing);
    final scaffold = tester.widget<Scaffold>(
      find.ancestor(
        of: find.byType(faui.ProvidersSection),
        matching: find.byType(Scaffold),
      ),
    );
    expect(scaffold.backgroundColor, isNot(Colors.transparent));
  });

  group('wide dialog host', () {
    Future<void> openDialog(
      WidgetTester tester,
      faui.FaVisualDirection direction,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: faui.buildFaTheme(
            direction: direction,
            brightness: Brightness.dark,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => faui.pushFaPage<void>(
                  context,
                  SettingsScreen(service: fakeService()),
                  dialogMaxWidth: 840,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      // The dialog is now laid out with macOS chrome. Reset the debug global
      // before flutter_test's invariant check; assertions below inspect that
      // already-built geometry without triggering another platform-dependent
      // layout.
      debugDefaultTargetPlatformOverride = null;
    }

    testWidgets('glass dialog: page chrome goes transparent', (tester) async {
      await openDialog(tester, faui.FaVisualDirection.glass);

      expect(find.byType(Dialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(faui.FaGlassDialogScope),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(faui.FaDialogScope),
        ),
        findsOneWidget,
      );
      expect(platter(tester).glass, isFalse);
      expect(platter(tester).borderSide, BorderSide.none);
      expect(find.byKey(const ValueKey('settingsScrollbar')), findsOneWidget);
      expect(find.byKey(const ValueKey('settingsBackButton')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('settingsHeader'))).height,
        48,
        reason: 'the compact dialog header has no traffic-light or dead band',
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('settingsHeader'))).dy -
            tester.getTopLeft(find.byWidget(platter(tester))).dy,
        lessThanOrEqualTo(1),
        reason: 'the header starts at the platter rim, not below a second bar',
      );
      final appBar = tester.widget<AppBar>(
        find.descendant(of: find.byType(Dialog), matching: find.byType(AppBar)),
      );
      expect(appBar.centerTitle, isFalse);
      final scaffold = tester.widget<Scaffold>(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(Scaffold),
        ),
      );
      expect(scaffold.backgroundColor, Colors.transparent);
      final appBarContext = tester.element(
        find.descendant(of: find.byType(Dialog), matching: find.byType(AppBar)),
      );
      expect(
        Theme.of(appBarContext).appBarTheme.backgroundColor,
        Colors.transparent,
      );
      // The glass platter is still the page's host inside the dialog —
      // and there is NO local underlay: the live app is the backdrop.
      expectGroupedSections(tester);
      expect(gradientUnderlay(), findsNothing);
    });

    testWidgets('opaque dialog: stock dialog and page chrome', (tester) async {
      await openDialog(tester, faui.FaVisualDirection.graphite);

      final dialog = tester.widget<Dialog>(find.byType(Dialog));
      expect(dialog.backgroundColor, isNot(Colors.transparent));
      expect(find.byType(faui.FaGlassDialogScope), findsNothing);
      expect(find.byType(faui.FaDialogScope), findsOneWidget);
      final scaffold = tester.widget<Scaffold>(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(Scaffold),
        ),
      );
      expect(scaffold.backgroundColor, isNot(Colors.transparent));
    });
  });
}
