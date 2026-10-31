import 'dart:math' as math;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

void main() {
  group('FaDesignTokens', () {
    test('breakpoints include both medium edges', () {
      expect(faWindowClassForWidth(0), FaWindowClass.small);
      expect(faWindowClassForWidth(639.99), FaWindowClass.small);
      expect(faWindowClassForWidth(640), FaWindowClass.medium);
      expect(faWindowClassForWidth(1023.99), FaWindowClass.medium);
      expect(faWindowClassForWidth(1024), FaWindowClass.large);
    });

    test(
      'all eight palettes are available and carry body-text AA contrast',
      () {
        for (final direction in FaVisualDirection.values) {
          for (final brightness in Brightness.values) {
            final tokens = FaDesignTokens.forDirection(direction, brightness);
            expect(tokens.direction, direction);
            expect(tokens.brightness, brightness);
            expect(tokens.agentHues, hasLength(6));
            for (final ink in [tokens.ink1, tokens.ink2, tokens.ink3]) {
              for (final surface in [
                tokens.background,
                tokens.surface1,
                tokens.surface2,
                tokens.surface3,
              ]) {
                expect(
                  _contrast(ink, surface),
                  greaterThanOrEqualTo(4.5),
                  reason:
                      '${direction.name}/${brightness.name}: '
                      '${ink.toARGB32().toRadixString(16)} on '
                      '${surface.toARGB32().toRadixString(16)}',
                );
              }
            }
            expect(
              _contrast(tokens.accentInk, tokens.accent),
              greaterThanOrEqualTo(4.5),
            );
          }
        }
      },
    );

    test(
      'theme builder projects tokens into Material and legacy chat colors',
      () {
        for (final direction in FaVisualDirection.values) {
          for (final brightness in Brightness.values) {
            final theme = buildFaTheme(
              direction: direction,
              brightness: brightness,
            );
            final tokens = theme.extension<FaDesignTokens>()!;
            expect(tokens.direction, direction);
            expect(theme.brightness, brightness);
            expect(theme.colorScheme.primary, tokens.accent);
            expect(theme.scaffoldBackgroundColor, tokens.background);
            final halfway = tokens.lerp(
              FaDesignTokens.forDirection(direction, brightness),
              .5,
            );
            expect(halfway.background, tokens.background);
          }
        }
      },
    );
  });

  group('Fa 2.0 widgets', () {
    setUp(() => debugFaGlassAlwaysFake = true);
    tearDown(() => debugFaGlassAlwaysFake = false);

    testWidgets('logo is a vector painter with no font-dependent mark', (
      tester,
    ) async {
      await _pump(tester, const FaLogo(size: 84));
      final paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(FaLogo),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(paint.painter, isA<FaLogoPainter>());
      expect(
        find.descendant(of: find.byType(FaLogo), matching: find.byType(Text)),
        findsNothing,
      );
      expect(tester.getSize(find.byType(FaLogo)), const Size(84, 84));
    });

    testWidgets(
      'glass surface uses the upstream renderer through the test seam',
      (tester) async {
        await _pump(
          tester,
          const FaSurface(glass: true, child: Text('Glass content')),
        );
        await tester.pump();
        expect(find.byType(LiquidGlass), findsOneWidget);
        expect(find.text('Glass content'), findsOneWidget);
      },
    );

    testWidgets('buttons keep accessible targets and dispatch once', (
      tester,
    ) async {
      var taps = 0;
      await _pump(
        tester,
        Column(
          children: [
            FaButton(label: 'Continue', onPressed: () => taps++),
            FaIconButton(icon: Icons.add, onPressed: () => taps++),
          ],
        ),
      );
      expect(
        tester.getSize(find.byType(FaButton)).height,
        greaterThanOrEqualTo(44),
      );
      expect(
        tester.getSize(find.byType(FaIconButton)).height,
        greaterThanOrEqualTo(44),
      );
      await tester.tap(find.text('Continue'));
      expect(taps, 1);
    });

    testWidgets('reduced motion resolves to zero', (tester) async {
      late Duration resolved;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFaTheme(
            direction: FaVisualDirection.porcelain,
            brightness: Brightness.dark,
          ),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Builder(
              builder: (context) {
                resolved = FaMotion.duration(
                  context,
                  FaDesignTokens.of(context).emphasized,
                );
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(resolved, Duration.zero);
    });

    testWidgets('adaptive navigation uses bottom / dual / three-pane layouts', (
      tester,
    ) async {
      Future<void> pumpAt(Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await _pump(
          tester,
          SizedBox.expand(
            child: FaAdaptiveScaffold(
              destinations: const [
                FaDestination(icon: Icons.chat, label: 'Chat'),
                FaDestination(icon: Icons.apps, label: 'Apps'),
              ],
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              title: const Text('Fa'),
              body: const Text('Conversation'),
              secondaryPanel: const Text('Sessions'),
              boardPanel: const Text('Board panel'),
            ),
          ),
        );
      }

      addTearDown(tester.view.reset);
      await pumpAt(const Size(390, 844));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('Board panel'), findsNothing);

      await pumpAt(const Size(800, 900));
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('Sessions'), findsOneWidget);
      expect(find.text('Board panel'), findsNothing);

      await pumpAt(const Size(1440, 1000));
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('Board panel'), findsOneWidget);
    });

    testWidgets('app grid defaults to 4 / 6 / 8 columns', (tester) async {
      Future<int> columnsAt(Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await _pump(
          tester,
          FaAppGrid(children: [for (var i = 0; i < 16; i++) Text('$i')]),
        );
        final grid = tester.widget<GridView>(find.byType(GridView));
        return (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount;
      }

      addTearDown(tester.view.reset);
      expect(await columnsAt(const Size(390, 800)), 4);
      expect(await columnsAt(const Size(800, 900)), 6);
      expect(await columnsAt(const Size(1280, 900)), 8);
    });

    testWidgets('phone app icons fit a two-line label without overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(
        tester,
        const FaAppGrid(
          children: [
            FaAppIcon(icon: Icon(Icons.apps), label: 'A longer app name'),
          ],
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: buildFaTheme(
      direction: FaVisualDirection.glass,
      brightness: Brightness.dark,
    ),
    home: Scaffold(body: Center(child: child)),
  ),
);

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final high = la > lb ? la : lb;
  final low = la > lb ? lb : la;
  return (high + .05) / (low + .05);
}

double _luminance(Color color) {
  double channel(double value) => value <= .03928
      ? value / 12.92
      : math.pow((value + .055) / 1.055, 2.4).toDouble();
  return .2126 * channel(color.r) +
      .7152 * channel(color.g) +
      .0722 * channel(color.b);
}
