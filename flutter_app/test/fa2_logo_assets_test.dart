// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const outerB3 =
      '<rect x="4" y="4" width="60" height="60" rx="18" '
      'fill="#121828" stroke="#38BDF8" stroke-width="2"/>';
  const chevronB3 =
      '<path d="M15 28 L22 34 L15 40" fill="none" '
      'stroke="#38BDF8" stroke-width="2.8" stroke-linecap="round" '
      'stroke-linejoin="round"/>';
  const agentDotB3 = '<circle cx="48" cy="22" r="3.2" fill="#9366FF"/>';
  const outerGlass =
      '<rect x="4" y="4" width="60" height="60" rx="18" '
      'fill="#1C1C1E" stroke="#3F8FF7" stroke-width="2"/>';
  const chevronGlass =
      '<path d="M15 28 L22 34 L15 40" fill="none" '
      'stroke="#3F8FF7" stroke-width="2.8" stroke-linecap="round" '
      'stroke-linejoin="round"/>';
  const agentDotGlass = '<circle cx="48" cy="22" r="3.2" fill="#818CF8"/>';

  test(
    'every canonical SVG surface uses the same B3-square-accent vectors',
    () {
      final sources = <String, String>{
        'in-app dark mark': kFaBrandTileDarkSvg,
        'in-app light mark': kFaBrandTileLightSvg,
        'launcher SVG': File('icon/icon.svg').readAsStringSync(),
        'light launcher SVG': File('icon/icon_light.svg').readAsStringSync(),
        'iOS source SVG': File('icon/icon_ios.svg').readAsStringSync(),
        'adaptive foreground SVG': File(
          'icon/icon_foreground.svg',
        ).readAsStringSync(),
        'maskable SVG': File('icon/icon_maskable.svg').readAsStringSync(),
        'favicon SVG': File('web/favicon.svg').readAsStringSync(),
        'web splash': File('web/index.html').readAsStringSync(),
        'site favicon SVG': File('../site/favicon.svg').readAsStringSync(),
        'extension favicon SVG': File(
          '../browser_ext/panel/app/favicon.svg',
        ).readAsStringSync(),
      };
      for (final entry in sources.entries) {
        final isLight =
            entry.key == 'in-app light mark' ||
            entry.key.contains('light launcher');
        final source = isLight
            ? entry.value
                  .replaceAll('#FFFFFF', '#1C1C1E')
                  .replaceAll('#1D1D1F', '#F5F5F7')
                  .replaceAll('#4F46E5', '#818CF8')
            : entry.value;
        final native =
            !entry.key.startsWith('in-app') &&
            entry.key != 'web splash' &&
            entry.key != 'light launcher SVG';
        expect(
          source,
          contains(native ? outerB3 : outerGlass),
          reason: '${entry.key} must use the 60×60 / r18 B3 outer square',
        );
        expect(
          source,
          contains(native ? chevronB3 : chevronGlass),
          reason: '${entry.key} must use the B3 accent chevron',
        );
        expect(
          source,
          contains('d="M27 42 V26 H38.5"'),
          reason: '${entry.key} must anchor vector Fa at x27 / baseline 42',
        );
        expect(
          source,
          contains(native ? agentDotB3 : agentDotGlass),
          reason: '${entry.key} must put the agent dot above the a',
        );
        expect(source, isNot(contains('M20 22 H64')));
        expect(source, isNot(contains('M52 28 L57 33 L52 38')));
        expect(source, isNot(contains('cx="60" cy="46"')));
        expect(source, isNot(contains('<text')));
      }
    },
  );

  test('static native launcher and favicon SVGs are byte-identical', () {
    final native = File('icon/icon.svg').readAsStringSync();
    expect(File('web/favicon.svg').readAsStringSync(), native);
    expect(File('../site/favicon.svg').readAsStringSync(), native);
    expect(
      File('../browser_ext/panel/app/favicon.svg').readAsStringSync(),
      native,
    );
    expect(
      File('icon/icon_light.svg').readAsStringSync(),
      kFaBrandTileLightSvg,
    );
    expect(kFaMarkSvg, same(kFaBrandTileDarkSvg));
    expect(kFaBrandTileDarkSvg, contains('viewBox="0 0 68 68"'));
    expect(kFaBrandTileLightSvg, contains('viewBox="0 0 68 68"'));
  });

  test('macOS launcher uses the dark B3 reference, never the light tile', () {
    expect(
      File(
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png',
      ).readAsBytesSync(),
      File('icon/icon_dark_1024.png').readAsBytesSync(),
    );
  });

  test('site graphical brand badges reference the canonical favicon', () {
    for (final path in [
      '../site/index.html',
      '../site/blog/index.template.html',
      '../site/blog/post.html',
      '../scripts/build_site.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('class="brand-mark" src='), reason: path);
      expect(source, contains('favicon.svg?v=3'), reason: path);
      expect(source, isNot(contains('<span class="brand-mark"')), reason: path);
    }
  });

  testWidgets(
    'FaMark and FaBrandTile delegate without overflow at every slot',
    (tester) async {
      for (final size in [16.0, 28.0, 30.0, 42.0, 64.0]) {
        for (final brand in [FaMark(size: size), FaBrandTile(size: size)]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildFaTheme(
                direction: FaVisualDirection.porcelain,
                brightness: Brightness.light,
              ),
              home: Center(child: brand),
            ),
          );
          expect(find.byType(FaLogo), findsOneWidget);
          final paint = tester.widget<CustomPaint>(
            find.descendant(
              of: find.byType(FaLogo),
              matching: find.byType(CustomPaint),
            ),
          );
          expect(paint.painter, isA<FaLogoPainter>());
          expect(tester.getSize(find.byType(FaLogo)), Size.square(size));
          expect(tester.takeException(), isNull);
        }
      }
    },
  );
}
