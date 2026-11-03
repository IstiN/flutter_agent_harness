// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Themed-control tests: the four Material control families (switch,
/// radio, checkbox, slider) must read their colors from [FaDesignTokens]
/// in every direction/brightness combination — never from the stock M3
/// scheme — and [FaSwitch] must be the custom-painted styleguide capsule
/// (not a raw Material `Switch`).
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
          expect(theme.sliderTheme.overlayColor, tokens.accent.withValues(
            alpha: .12,
          ));
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
    Widget host(Widget child) => MaterialApp(
      theme: buildFaTheme(
        direction: FaVisualDirection.glass,
        brightness: Brightness.dark,
      ),
      home: Scaffold(body: Center(child: child)),
    );

    FaSwitchPainter painterOf(WidgetTester tester) => tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byType(FaSwitch),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter! as FaSwitchPainter;

    final darkGlass = FaDesignTokens.forDirection(
      FaVisualDirection.glass,
      Brightness.dark,
    );

    testWidgets('is a custom capsule, not a Material Switch', (tester) async {
      await tester.pumpWidget(
        host(const FaSwitch(value: true, onChanged: null)),
      );
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(FaSwitch), findsOneWidget);
      expect(tester.getSize(find.byType(FaSwitch)), const Size(40, 24));
      expect(painterOf(tester), isA<FaSwitchPainter>());
    });

    testWidgets('ON paints accent track + accentInk squircle thumb', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const FaSwitch(value: true, onChanged: _noop)),
      );
      final painter = painterOf(tester);
      expect(painter.trackColor, darkGlass.accent);
      expect(painter.thumbColor, darkGlass.accentInk);
      expect(painter.position, 1);
    });

    testWidgets('OFF paints surface3 track + ink1 thumb', (tester) async {
      await tester.pumpWidget(
        host(const FaSwitch(value: false, onChanged: _noop)),
      );
      final painter = painterOf(tester);
      expect(painter.trackColor, darkGlass.surface3);
      expect(painter.thumbColor, darkGlass.ink1);
      expect(painter.position, 0);
    });

    testWidgets('disabled fades both capsule and thumb', (tester) async {
      await tester.pumpWidget(
        host(const FaSwitch(value: false, onChanged: null)),
      );
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
      final data = tester.getSemantics(find.byType(FaSwitch)).getSemanticsData();
      expect(data.flagsCollection.isToggled, Tristate.isTrue);
      expect(data.flagsCollection.isEnabled, Tristate.isTrue);
    });

    testWidgets('disabled switch is inert', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        host(FaSwitch(value: true, onChanged: null)),
      );
      await tester.tap(find.byType(FaSwitch), warnIfMissed: false);
      expect(tapped, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(tapped, isFalse);
      final data = tester.getSemantics(find.byType(FaSwitch)).getSemanticsData();
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
    });

    testWidgets('animates the thumb over the token fast duration', (
      tester,
    ) async {
      Future<void> pump(bool value) => tester.pumpWidget(
        host(FaSwitch(value: value, onChanged: _noop)),
      );

      await pump(false);
      await pump(true);
      await tester.pump(const Duration(milliseconds: 1));
      expect(painterOf(tester).position, lessThan(1));
      await tester.pump(darkGlass.fast);
      expect(painterOf(tester).position, 1);
    });

    testWidgets('reduced motion snaps instantly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFaTheme(
            direction: FaVisualDirection.glass,
            brightness: Brightness.dark,
          ),
          home: const MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(body: Center(child: FaSwitch(value: true, onChanged: null))),
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
      final theme = SliderTheme.of(
        tester.element(find.byType(Slider)),
      );
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

void _noop(bool _) {}
