// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real 2×2 PNG — garbage bytes would throw on the test event loop.
final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAE0lEQVR4nGPQvbIfiBga'
  'e34AEQAw3weL9bEH6gAAAABJRU5ErkJggg==',
);

void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: buildFahTheme(),
    home: Scaffold(body: Center(child: child)),
  );

  group('fahMarkdownStyleSheet', () {
    test('body text is pinned to the dense chat line height', () {
      final sheet = fahMarkdownStyleSheet(buildFahTheme());
      expect(sheet.p?.height, 1.35);
      expect(sheet.listBullet?.height, 1.35);
      expect(sheet.h1?.height, 1.3);
    });

    test('sizes are explicit even when the theme text theme is null-sized', () {
      // The current Flutter ships M3 text themes with null fontSize — the
      // stylesheet must still resolve concrete sizes (fromTheme asserts).
      final sheet = fahMarkdownStyleSheet(buildFahTheme());
      expect(sheet.p?.fontSize, 14);
      expect(sheet.h1?.fontSize, 28);
      expect(sheet.h2?.fontWeight, FontWeight.w700);
    });

    test('fontSize scales the body and keeps heading proportions', () {
      final sheet = fahMarkdownStyleSheet(buildFahTheme(), fontSize: 18);
      expect(sheet.p?.fontSize, 18);
      expect(sheet.h1?.fontSize, 36);
      expect(sheet.h3?.fontSize, closeTo(24.3, 0.01));
      expect(sheet.listBullet?.fontSize, 18);
      expect(sheet.code?.fontSize, closeTo(16.56, 0.01));
    });
  });

  group('SandboxImageResolver.sizedImageBuilder', () {
    // The framed-image dimensions/constraints every successful arm shares.
    void expectFramed(WidgetTester tester) {
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.fit, BoxFit.fitWidth);
      final box = tester.widget<ConstrainedBox>(
        find
            .ancestor(
              of: find.byType(Image),
              matching: find.byType(ConstrainedBox),
            )
            .first,
      );
      expect(box.constraints.maxHeight, 320);
      final clip = tester.widget<ClipRRect>(
        find.ancestor(of: find.byType(Image), matching: find.byType(ClipRRect)),
      );
      expect(clip.borderRadius, BorderRadius.circular(8));
    }

    testWidgets('data: URIs decode inline and report taps', (tester) async {
      Uint8List? tapped;
      final resolver = SandboxImageResolver(MemoryExecutionEnv());
      await tester.pumpWidget(
        wrap(
          MarkdownBody(
            data:
                '![swatch](data:image/png;base64,'
                '${base64Encode(_tinyPng)})',
            sizedImageBuilder: resolver.sizedImageBuilder(
              onImageTap: (bytes) => tapped = bytes,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expectFramed(tester);
      final bytes =
          (tester.widget<Image>(find.byType(Image)).image as MemoryImage).bytes;
      expect(bytes, _tinyPng);

      // Invoke the tap wiring directly: the real hit test needs the image
      // decoded (real async, unavailable under fake-async pumpAndSettle).
      tester
          .widget<GestureDetector>(find.byType(GestureDetector))
          .onTap!
          .call();
      expect(tapped, _tinyPng);
    });

    testWidgets('sandbox paths load through the env', (tester) async {
      final env = MemoryExecutionEnv();
      await env.writeBinaryFile('generated/x.png', _tinyPng);
      final resolver = SandboxImageResolver(env);
      await tester.pumpWidget(
        wrap(
          MarkdownBody(
            data: '![chart](generated/x.png)',
            sizedImageBuilder: resolver.sizedImageBuilder(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expectFramed(tester);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    });

    testWidgets('a leading slash still resolves inside the sandbox', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      await env.writeBinaryFile('generated/x.png', _tinyPng);
      final resolver = SandboxImageResolver(env);
      await tester.pumpWidget(
        wrap(
          MarkdownBody(
            data: '![chart](/generated/x.png)',
            sizedImageBuilder: resolver.sizedImageBuilder(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expectFramed(tester);
    });

    testWidgets('missing sandbox files degrade to the placeholder line', (
      tester,
    ) async {
      final resolver = SandboxImageResolver(MemoryExecutionEnv());
      await tester.pumpWidget(
        wrap(
          MarkdownBody(
            data: '![nope](generated/gone.png)',
            sizedImageBuilder: resolver.sizedImageBuilder(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.text('nope'), findsOneWidget);
    });

    testWidgets('http(s) images degrade to the placeholder on failure', (
      tester,
    ) async {
      // The test binding's mocked HTTP client answers 400 — the error
      // builder must show the placeholder, never a red box.
      final resolver = SandboxImageResolver(MemoryExecutionEnv());
      await tester.pumpWidget(
        wrap(
          MarkdownBody(
            data: '![remote](https://example.invalid/x.png)',
            sizedImageBuilder: resolver.sizedImageBuilder(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.text('remote'), findsOneWidget);
    });
  });
}
