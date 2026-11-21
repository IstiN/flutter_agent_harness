// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

const _svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
    '<rect x="4" y="4" width="16" height="16" fill="#fff"/>'
    '</svg>';

JsAppInfo _app(String icon, {String id = 'demo'}) => JsAppInfo.fromManifest(
  {'id': id, 'name': 'Demo', 'icon': icon},
  bundled: false,
  fallbackId: id,
);

void main() {
  testWidgets('emoji icon renders as text', (tester) async {
    final env = MemoryExecutionEnv();
    await tester.pumpWidget(
      MaterialApp(
        home: AppIcon(app: _app('🧮'), env: env),
      ),
    );
    expect(find.text('🧮'), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
  });

  testWidgets('inline svg markup renders as SvgPicture', (tester) async {
    final env = MemoryExecutionEnv();
    await tester.pumpWidget(
      MaterialApp(
        home: AppIcon(app: _app(_svg), env: env),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('svg file icon loads from the app folder in the env', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await env.writeFile('apps/demo/icon.svg', _svg);
    await tester.pumpWidget(
      MaterialApp(
        home: AppIcon(app: _app('icon.svg'), env: env),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('missing svg file falls back to the placeholder', (tester) async {
    final env = MemoryExecutionEnv();
    await tester.pumpWidget(
      MaterialApp(
        home: AppIcon(app: _app('missing.svg'), env: env),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('📦'), findsOneWidget);
  });

  testWidgets('framed icon uses a colorful continuous-corner badge', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: AppIcon(app: _app(_svg), env: env, size: 76, framed: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final badge = tester.widget<AppIconBadge>(find.byType(AppIconBadge));
    expect(badge.size, 76);
    final container = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(AppIconBadge),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = container.decoration! as ShapeDecoration;
    expect(decoration.gradient, isA<LinearGradient>());
    expect(decoration.shape, isA<RoundedSuperellipseBorder>());
  });

  testWidgets('curated catalog artwork replaces placeholder SVG by app id', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: AppIcon(
            app: _app('icon.svg', id: 'contacts'),
            env: env,
            size: 64,
            framed: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.text('📦'), findsNothing);
    // No asynchronous manifest-file read is needed for curated artwork.
    expect(AppIconArtwork.svgFor('contacts'), contains('id="paper"'));
  });

  test('curated vector family shares a keyline and preserves good assets', () {
    const curated = [
      'system:settings',
      'contacts',
      'reminders',
      'adaptive-dashboard',
      'm3-showcase',
      '3d-viewer',
      '3d-game',
      'neon-breakout-3d',
      'voxel-sandbox',
    ];
    for (final id in curated) {
      expect(AppIconArtwork.svgFor(id), contains('viewBox="0 0 64 64"'));
      expect(AppIconArtwork.accentFor(id), isNotNull);
    }
    // Owner-approved manifest assets keep loading from the app directory.
    expect(AppIconArtwork.svgFor('2048'), isNull);
    expect(AppIconArtwork.svgFor('fa-craft'), isNull);
  });

  test('gradients are desaturated and keep adaptive foreground contrast', () {
    for (final brightness in Brightness.values) {
      final colors = AppIconPalette.gradientFor(
        const Color(0xFFEC4899),
        brightness,
      );
      for (final color in colors) {
        expect(HSLColor.fromColor(color).saturation, lessThanOrEqualTo(.40));
      }
      final foreground = AppIconPalette.foregroundFor(brightness);
      final a = foreground.computeLuminance();
      final b = colors[1].computeLuminance();
      final contrast =
          (a > b ? a + .05 : b + .05) / (a > b ? b + .05 : a + .05);
      expect(contrast, greaterThanOrEqualTo(4.5));
    }
  });

  test('artwork accent wins and fallback accents are stable', () {
    // Neutral white glyph paths do not masquerade as the app accent.
    expect(
      AppIconPalette.accentFor('demo', _svg),
      AppIconPalette.accentFor('demo'),
    );
    expect(
      AppIconPalette.accentFor('demo', '<svg fill="#0ea5e9"/>'),
      const Color(0xFF0EA5E9),
    );
    expect(
      AppIconPalette.accentFor('repeatable'),
      AppIconPalette.accentFor('repeatable'),
    );
  });
}
