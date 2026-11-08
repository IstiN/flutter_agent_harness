// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Themed-control tests: the four Material control families (switch,
/// radio, checkbox, slider) must read their colors from [FaDesignTokens]
/// in every direction/brightness combination — never from the stock M3
/// scheme — and [FaSwitch] must use the kit's real glass switch in the
/// glass direction while opaque directions keep the token-painted capsule.
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

void main() {
  group('buildFaTheme control families', () {
    for (final direction in FaVisualDirection.values) {
      for (final brightness in Brightness.values) {
        final combo = '${direction.name}/${brightness.name}';
        final tokens = FaDesignTokens.forDirection(direction, brightness);
        final theme = buildFaTheme(
          direction: direction,
          brightness: brightness,
        );

        test('$combo switch theme is token-driven', () {
          final track = theme.switchTheme.trackColor!;
          expect(track.resolve({WidgetState.selected}), tokens.accent);
          expect(track.resolve({}), tokens.surface3);
          expect(
            track.resolve({WidgetState.disabled}),
            tokens.surface3.withValues(alpha: .55),
          );
          final thumb = theme.switchTheme.thumbColor!;
          expect(thumb.resolve({WidgetState.selected}), tokens.accentInk);
          expect(thumb.resolve({}), tokens.ink1);
          expect(
            thumb.resolve({WidgetState.disabled}),
            tokens.ink3.withValues(alpha: .55),
          );
          // No stock M3 outline on the unselected track.
          expect(
            theme.switchTheme.trackOutlineColor!.resolve({}),
            Colors.transparent,
          );
        });

        test('$combo radio theme is token-driven', () {
          final fill = theme.radioTheme.fillColor!;
          expect(fill.resolve({WidgetState.selected}), tokens.accent);
          expect(fill.resolve({}), tokens.ink2);
          expect(
            fill.resolve({WidgetState.disabled}),
            tokens.ink3.withValues(alpha: .55),
          );
        });

        test('$combo checkbox theme is token-driven', () {
          final fill = theme.checkboxTheme.fillColor!;
          expect(fill.resolve({WidgetState.selected}), tokens.accent);
          expect(
            fill.resolve({WidgetState.selected, WidgetState.disabled}),
            tokens.surface3.withValues(alpha: .55),
          );
          expect(fill.resolve({}), Colors.transparent);
          // Unchecked ring is the hairline; the checked box is the accent
          // fill (side itself is stateless in CheckboxThemeData).
          expect(theme.checkboxTheme.side!.color, tokens.hairline);
          expect(
            theme.checkboxTheme.checkColor!.resolve({WidgetState.selected}),
            tokens.accentInk,
          );
        });

        test('$combo slider theme is token-driven', () {
          expect(theme.sliderTheme.activeTrackColor, tokens.accent);
          expect(theme.sliderTheme.inactiveTrackColor, tokens.surface3);
          expect(theme.sliderTheme.thumbColor, tokens.accent);
          expect(
            theme.sliderTheme.overlayColor,
            tokens.accent.withValues(alpha: .12),
          );
          expect(theme.sliderTheme.valueIndicatorColor, tokens.surface2);
        });

        test('$combo never resolves to the stock M3 control palette', () {
          // A bare ThemeData carries no control sub-themes (the M3 widgets
          // then fall back to colorScheme.primary — the baseline violet/
          // blue). Every themed slot must instead pin a token-derived
          // color, so none of these resolves to that scheme default.
          const m3Baseline = Color(0xFF6750A4);
          final m3BaselineDark = const Color(0xFFD0BCFF);
          final defaultPrimary = brightness == Brightness.dark
              ? m3BaselineDark
              : m3Baseline;
          expect(
            theme.switchTheme.trackColor!.resolve({WidgetState.selected}),
            isNot(defaultPrimary),
          );
          expect(
            theme.switchTheme.thumbColor!.resolve({}),
            isNot(defaultPrimary),
          );
          expect(
            theme.radioTheme.fillColor!.resolve({WidgetState.selected}),
            isNot(defaultPrimary),
          );
          expect(
            theme.checkboxTheme.fillColor!.resolve({WidgetState.selected}),
            isNot(defaultPrimary),
          );
          expect(theme.sliderTheme.thumbColor, isNot(defaultPrimary));
          expect(theme.sliderTheme.activeTrackColor, isNot(defaultPrimary));
        });
      }
    }
  });

  group('FaSwitch', () {
    Widget host(
      Widget child, {
      FaVisualDirection direction = FaVisualDirection.glass,
      Brightness brightness = Brightness.dark,
    }) => MaterialApp(
      theme: buildFaTheme(direction: direction, brightness: brightness),
      home: Scaffold(body: Center(child: child)),
    );

    FaSwitchPainter painterOf(WidgetTester tester) =>
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byType(FaSwitch),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as FaSwitchPainter;

    final darkGlass = FaDesignTokens.forDirection(
      FaVisualDirection.glass,
      Brightness.dark,
    );

    testWidgets('enabled glass uses the kit switch with Fa tokens', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const FaSwitch(value: true, onChanged: _noop)),
      );
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(FaSwitch), findsOneWidget);
      expect(find.byType(GlassSwitch), findsOneWidget);
      expect(tester.getSize(find.byType(FaSwitch)), const Size(40, 24));

      final kit = tester.widget<GlassSwitch>(find.byType(GlassSwitch));
      expect(kit.width, 40);
      expect(kit.height, 24);
      expect(kit.activeColor, darkGlass.accent);
      expect(kit.inactiveColor, darkGlass.surface3);
      expect(kit.thumbColor, darkGlass.accentInk);
      expect(kit.useOwnLayer, isTrue);
      expect(kit.quality, GlassQuality.standard);
      expect(kit.enableHaptics, isTrue);
      expect(kit.focusNode, isNotNull);
      expect(kit.settings?.blur, darkGlass.glassBlur);
      expect(kit.settings?.chromaticAberration, 0);
      expect(
        kit.settings?.glassColor,
        darkGlass.surface1.withValues(alpha: kFaGlassTintAlpha),
      );
    });

    testWidgets('enabled light glass OFF keeps the ink thumb', (tester) async {
      final lightGlass = FaDesignTokens.forDirection(
        FaVisualDirection.glass,
        Brightness.light,
      );
      await tester.pumpWidget(
        host(
          const FaSwitch(value: false, onChanged: _noop),
          brightness: Brightness.light,
        ),
      );
      expect(tester.getSize(find.byType(FaSwitch)), const Size(40, 24));
      final kit = tester.widget<GlassSwitch>(find.byType(GlassSwitch));
      expect(kit.value, isFalse);
      expect(kit.thumbColor, lightGlass.ink1);
    });

    testWidgets('opaque directions retain painter geometry and token colors', (
      tester,
    ) async {
      for (final direction in FaVisualDirection.values.where(
        (direction) => direction != FaVisualDirection.glass,
      )) {
        for (final brightness in Brightness.values) {
          final combo = '${direction.name}/${brightness.name}';
          final tokens = FaDesignTokens.forDirection(direction, brightness);
          Future<void> pump(bool value) => tester.pumpWidget(
            host(
              FaSwitch(value: value, onChanged: _noop),
              direction: direction,
              brightness: brightness,
            ),
          );

          await pump(true);
          await tester.pumpAndSettle();
          expect(find.byType(GlassSwitch), findsNothing, reason: combo);
          expect(
            tester.getSize(find.byType(FaSwitch)),
            const Size(40, 24),
            reason: combo,
          );
          final on = painterOf(tester);
          expect(on.trackColor, tokens.accent, reason: combo);
          expect(on.thumbColor, tokens.accentInk, reason: combo);
          expect(on.position, 1, reason: combo);

          await pump(false);
          await tester.pumpAndSettle();
          final off = painterOf(tester);
          _expectColorClose(off.trackColor, tokens.surface3, combo);
          _expectColorClose(off.thumbColor, tokens.ink1, combo);
          expect(off.position, 0, reason: combo);
        }
      }
    });

    testWidgets('disabled glass falls back to the washed painter', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const FaSwitch(value: false, onChanged: null)),
      );
      expect(find.byType(GlassSwitch), findsNothing);
      final painter = painterOf(tester);
      expect(painter.trackColor, darkGlass.surface3.withValues(alpha: .55));
      expect(painter.thumbColor, darkGlass.ink1.withValues(alpha: .55));
    });

    testWidgets('taps toggle and semantics expose the switch state', (
      tester,
    ) async {
      var value = false;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) => FaSwitch(
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(FaSwitch));
      await tester.pump();
      expect(value, isTrue);
      final data = tester
          .getSemantics(find.byType(FaSwitch))
          .getSemanticsData();
      expect(data.flagsCollection.isToggled, Tristate.isTrue);
      expect(data.flagsCollection.isEnabled, Tristate.isTrue);
    });

    testWidgets('disabled switch is inert', (tester) async {
      var enabled = true;
      var value = false;
      var calls = 0;
      late StateSetter setHostState;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              setHostState = setState;
              return FaSwitch(
                value: value,
                onChanged: enabled
                    ? (v) {
                        calls++;
                        setState(() => value = v);
                      }
                    : null,
              );
            },
          ),
        ),
      );
      setHostState(() => enabled = false);
      await tester.pump();
      expect(find.byType(GlassSwitch), findsNothing);

      final focus = tester.widget<Focus>(
        find.descendant(
          of: find.byType(FaSwitch),
          matching: find.byType(Focus),
        ),
      );
      focus.focusNode!.requestFocus();
      await tester.pump();
      await tester.tap(find.byType(FaSwitch), warnIfMissed: false);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(calls, 0);
      expect(value, isFalse);
      final data = tester
          .getSemantics(find.byType(FaSwitch))
          .getSemanticsData();
      expect(data.flagsCollection.isEnabled, isNot(Tristate.isTrue));
    });

    testWidgets('space/enter keys toggle from the focused switch', (
      tester,
    ) async {
      var value = false;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) => FaSwitch(
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      );
      tester
          .widget<Focus>(
            find.descendant(
              of: find.byType(FaSwitch),
              matching: find.byType(Focus),
            ),
          )
          .focusNode!
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(value, isTrue, reason: 'the focused switch toggles via space');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(value, isFalse, reason: 'enter toggles the focused kit switch');
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      await tester.pump();
      expect(value, isTrue, reason: 'numpad enter toggles as well');
    });

    testWidgets('opaque thumb animates over the token fast duration', (
      tester,
    ) async {
      Future<void> pump(bool value) => tester.pumpWidget(
        host(
          FaSwitch(value: value, onChanged: _noop),
          direction: FaVisualDirection.graphite,
        ),
      );

      await pump(false);
      await pump(true);
      await tester.pump(const Duration(milliseconds: 1));
      expect(painterOf(tester).position, lessThan(1));
      await tester.pump(darkGlass.fast);
      expect(painterOf(tester).position, 1);
    });

    testWidgets('opaque reduced motion snaps instantly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFaTheme(
            direction: FaVisualDirection.graphite,
            brightness: Brightness.dark,
          ),
          home: const MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: Center(child: FaSwitch(value: true, onChanged: null)),
            ),
          ),
        ),
      );
      final tween = tester.widget<TweenAnimationBuilder<double>>(
        find.descendant(
          of: find.byType(FaSwitch),
          matching: find.byType(TweenAnimationBuilder<double>),
        ),
      );
      expect(tween.duration, Duration.zero);
      expect(painterOf(tester).position, 1);
    });

    testWidgets('glass reduced motion suppresses kit haptics', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFaTheme(
            direction: FaVisualDirection.glass,
            brightness: Brightness.dark,
          ),
          home: const MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: Center(child: FaSwitch(value: true, onChanged: _noop)),
            ),
          ),
        ),
      );
      final kit = tester.widget<GlassSwitch>(find.byType(GlassSwitch));
      expect(kit.enableHaptics, isFalse);
    });
  });

  group('FaSlider', () {
    testWidgets('rides the themed slider through the Material wrapper', (
      tester,
    ) async {
      var value = .25;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFaTheme(
            direction: FaVisualDirection.nebula,
            brightness: Brightness.light,
          ),
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) => FaSlider(
                  value: value,
                  onChanged: (v) => setState(() => value = v),
                ),
              ),
            ),
          ),
        ),
      );
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.value, .25);
      final theme = SliderTheme.of(tester.element(find.byType(Slider)));
      final tokens = FaDesignTokens.forDirection(
        FaVisualDirection.nebula,
        Brightness.light,
      );
      expect(theme.activeTrackColor, tokens.accent);
      expect(theme.inactiveTrackColor, tokens.surface3);
      expect(theme.thumbColor, tokens.accent);
    });
  });
}

void _expectColorClose(Color actual, Color expected, String reason) {
  // Color.lerp can leave sub-channel roundoff at the end of an implicit
  // animation even when the logical endpoint is exact.
  const tolerance = 1e-6;
  expect(actual.a, closeTo(expected.a, tolerance), reason: reason);
  expect(actual.r, closeTo(expected.r, tolerance), reason: reason);
  expect(actual.g, closeTo(expected.g, tolerance), reason: reason);
  expect(actual.b, closeTo(expected.b, tolerance), reason: reason);
}

void _noop(bool _) {}
