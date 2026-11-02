// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FaLogoPainter B3-square-accent', () {
    test('uses the exact 68-unit geometry and Glass token color roles', () {
      const direction = FaVisualDirection.nebula;
      const brightness = Brightness.dark;
      final tokens = FaDesignTokens.forDirection(direction, brightness);
      final canvas = TestRecordingCanvas();

      FaLogoPainter(tokens).paint(canvas, const Size.square(68));

      final scale = _onlyCall(canvas, #scale);
      expect(scale.invocation.positionalArguments, [1.0, 1.0]);
      final outlines = _calls(canvas, #drawRRect);
      expect(outlines, hasLength(2));
      for (final call in outlines) {
        final outer = call.invocation.positionalArguments[0] as RRect;
        expect(outer.left, 4);
        expect(outer.top, 4);
        expect(outer.right, 64);
        expect(outer.bottom, 64);
        expect(outer.tlRadiusX, 18);
        expect(outer.tlRadiusY, 18);
        expect(outer.trRadiusX, 18);
        expect(outer.brRadiusX, 18);
        expect(outer.blRadiusX, 18);
      }
      final fill = outlines[0].invocation.positionalArguments[1] as Paint;
      expect(fill.style, PaintingStyle.fill);
      _expectColor(fill.color, tokens.surface1);
      final border = outlines[1].invocation.positionalArguments[1] as Paint;
      expect(border.style, PaintingStyle.stroke);
      expect(border.strokeWidth, 2);
      _expectColor(border.color, tokens.accent);

      final paths = _calls(canvas, #drawPath);
      final chevronCall = paths.singleWhere((call) {
        final path = call.invocation.positionalArguments[0] as Path;
        return path.getBounds() == const Rect.fromLTRB(15, 28, 22, 40);
      });
      final chevronPaint =
          chevronCall.invocation.positionalArguments[1] as Paint;
      _expectColor(chevronPaint.color, tokens.accent);
      expect(chevronPaint.strokeWidth, closeTo(2.8, 1e-6));
      expect(chevronPaint.strokeCap, StrokeCap.round);
      expect(chevronPaint.strokeJoin, StrokeJoin.round);

      final fCall = paths.singleWhere((call) {
        final path = call.invocation.positionalArguments[0] as Path;
        return path.getBounds() == const Rect.fromLTRB(27, 26, 38.5, 42);
      });
      _expectColor(
        (fCall.invocation.positionalArguments[1] as Paint).color,
        tokens.ink1,
      );
      final circles = _calls(canvas, #drawCircle);
      final aCall = circles.singleWhere(
        (call) =>
            call.invocation.positionalArguments[0] == const Offset(43, 36),
      );
      expect(aCall.invocation.positionalArguments[1], 5);
      _expectColor(
        (aCall.invocation.positionalArguments[2] as Paint).color,
        tokens.ink1,
      );
      final dotCall = circles.singleWhere(
        (call) =>
            call.invocation.positionalArguments[0] == const Offset(48, 22),
      );
      expect(dotCall.invocation.positionalArguments[1], 3.2);
      _expectColor(
        (dotCall.invocation.positionalArguments[2] as Paint).color,
        tokens.agentHues[1],
      );
      expect(_calls(canvas, #drawParagraph), isEmpty);
      expect(_calls(canvas, #drawImage), isEmpty);
      expect(_calls(canvas, #drawPicture), isEmpty);
    });

    test('every direction and brightness derives all four color roles', () {
      for (final direction in FaVisualDirection.values) {
        for (final brightness in Brightness.values) {
          final tokens = FaDesignTokens.forDirection(direction, brightness);
          final canvas = TestRecordingCanvas();
          FaLogoPainter(tokens).paint(canvas, const Size.square(68));

          final outlines = _calls(canvas, #drawRRect);
          expect(
            (outlines[0].invocation.positionalArguments[1] as Paint).color
                .toARGB32(),
            tokens.surface1.toARGB32(),
            reason: '${direction.name}/${brightness.name} surface',
          );
          expect(
            (outlines[1].invocation.positionalArguments[1] as Paint).color
                .toARGB32(),
            tokens.accent.toARGB32(),
            reason: '${direction.name}/${brightness.name} accent border',
          );
          final paths = _calls(canvas, #drawPath);
          expect(
            (paths[0].invocation.positionalArguments[1] as Paint).color
                .toARGB32(),
            tokens.accent.toARGB32(),
            reason: '${direction.name}/${brightness.name} chevron',
          );
          expect(
            (paths[1].invocation.positionalArguments[1] as Paint).color
                .toARGB32(),
            tokens.ink1.toARGB32(),
            reason: '${direction.name}/${brightness.name} Fa ink',
          );
          final dot = _calls(canvas, #drawCircle).singleWhere(
            (call) =>
                call.invocation.positionalArguments[0] == const Offset(48, 22),
          );
          expect(
            (dot.invocation.positionalArguments[2] as Paint).color.toARGB32(),
            tokens.agentHues[1].toARGB32(),
            reason: '${direction.name}/${brightness.name} agent accent',
          );
        }
      }
    });

    test('scales the fixed geometry without changing its proportions', () {
      final tokens = FaDesignTokens.forDirection(
        FaVisualDirection.porcelain,
        Brightness.light,
      );
      final canvas = TestRecordingCanvas();
      FaLogoPainter(tokens).paint(canvas, const Size.square(136));
      expect(_onlyCall(canvas, #scale).invocation.positionalArguments, [
        2.0,
        2.0,
      ]);
      final dot = _calls(canvas, #drawCircle).singleWhere(
        (call) =>
            call.invocation.positionalArguments[0] == const Offset(48, 22),
      );
      expect(dot.invocation.positionalArguments[1], 3.2);
    });
  });

  group('FaLogo and FaAiAvatar widgets', () {
    testWidgets('required brand sizes stay square without overflow', (
      tester,
    ) async {
      for (final size in [16.0, 28.0, 30.0, 42.0, 64.0]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildFaTheme(
              direction: FaVisualDirection.glass,
              brightness: Brightness.dark,
            ),
            home: Center(child: FaLogo(size: size)),
          ),
        );
        expect(tester.getSize(find.byType(FaLogo)), Size.square(size));
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('assistant avatar uses only the shared logo at every slot', (
      tester,
    ) async {
      for (final size in [16.0, 28.0, 30.0, 42.0, 64.0]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildFaTheme(
              direction: FaVisualDirection.graphite,
              brightness: Brightness.dark,
            ),
            home: Center(child: FaAiAvatar(size: size)),
          ),
        );
        final avatar = find.byType(FaAiAvatar);
        expect(tester.getSize(avatar), Size.square(size));
        expect(
          find.descendant(of: avatar, matching: find.byType(FaLogo)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: avatar, matching: find.byType(SvgPicture)),
          findsNothing,
        );
        expect(
          find.descendant(of: avatar, matching: find.byType(Text)),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('avatar defaults to 28 and follows or overrides brightness', (
      tester,
    ) async {
      Future<void> check(
        Brightness ambient,
        bool? forced,
        Brightness expected,
      ) async {
        final theme = buildFaTheme(
          direction: FaVisualDirection.nebula,
          brightness: ambient,
        );
        expect(theme.extension<FaDesignTokens>()!.brightness, ambient);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Theme(
              data: theme,
              child: Center(
                child: FaAiAvatar(
                  key: ValueKey('$ambient-$forced'),
                  dark: forced,
                ),
              ),
            ),
          ),
        );
        final avatar = tester.widget<FaAiAvatar>(find.byType(FaAiAvatar));
        expect(avatar.size, 28);
        expect(tester.getSize(find.byType(FaAiAvatar)), const Size.square(28));
        final paint = tester.widget<CustomPaint>(
          find.descendant(
            of: find.byType(FaAiAvatar),
            matching: find.byType(CustomPaint),
          ),
        );
        final tokens = (paint.painter! as FaLogoPainter).tokens;
        expect(tokens.direction, FaVisualDirection.nebula);
        expect(
          tokens.brightness,
          expected,
          reason: 'ambient=$ambient forced=$forced',
        );
      }

      await check(Brightness.dark, null, Brightness.dark);
      await check(Brightness.light, null, Brightness.light);
      await check(Brightness.light, true, Brightness.dark);
      await check(Brightness.dark, false, Brightness.light);
    });
  });
}

List<RecordedInvocation> _calls(TestRecordingCanvas canvas, Symbol method) {
  return canvas.invocations
      .where((call) => call.invocation.memberName == method)
      .toList();
}

RecordedInvocation _onlyCall(TestRecordingCanvas canvas, Symbol method) {
  final calls = _calls(canvas, method);
  expect(calls, hasLength(1));
  return calls.single;
}

void _expectColor(Color actual, Color expected) {
  expect(actual.toARGB32(), expected.toARGB32());
}
