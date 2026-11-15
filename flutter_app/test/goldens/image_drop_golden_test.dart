// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Golden (snapshot) tests for the aggregated image-drop surfaces
/// (issue #1889 R5 + the repo's golden rule for flutter_app UI changes):
/// the docked chat chip (low-key history + prominent current-batch) and
/// the details panel rendering the shared projection. Notices are
/// produced through the real latch — no fabricated views.
/// Review every regenerated PNG by eye.
library;

import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/image_drop_notice_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

ImageDropNoticeView _notice({required bool prominent}) {
  final report = ImageDropReport(
    drops: [
      if (prominent)
        for (var i = 0; i < 5; i++)
          ImageDropEvent(
            index: i,
            key: 'attach-00$i',
            fromCurrentMessage: true,
          )
      else
        for (var i = 0; i < 17; i++)
          ImageDropEvent(
            index: i,
            key: 'content-00$i',
            fromCurrentMessage: false,
          ),
    ],
    cap: 20,
    modelId: 'zai/glm-5.3-flash',
    currentImageCount: prominent ? 25 : 0,
    registryCount: prominent ? 25 : 37,
    ridingCount: 20,
  );
  return ImageDropUx().observe(report)!;
}

Future<void> _pumpChip(
  WidgetTester tester, {
  required ImageDropNoticeView notice,
  required bool light,
}) async {
  await pumpGolden(
    tester,
    Scaffold(
      body: Column(
        children: [
          const Spacer(),
          ImageDropNoticeChip(notice: notice),
          const SizedBox(height: 24),
        ],
      ),
    ),
    size: goldenSizePhone,
    theme: light ? buildFahThemeLight() : buildFahTheme(),
    locale: const Locale('en'),
  );
  await tester.pump();
}

Future<void> _pumpPanel(WidgetTester tester, {required bool light}) async {
  final lines = imageSurfaceLines(
    lastReport: ImageDropReport(
      drops: [
        for (var i = 0; i < 17; i++)
          ImageDropEvent(
            index: i,
            key: 'content-0$i',
            fromCurrentMessage: false,
          ),
      ],
      cap: 20,
      modelId: 'zai/glm-5.3-flash',
      currentImageCount: 0,
      registryCount: 37,
      ridingCount: 20,
    ),
    config: const ImageRegistryConfig(),
    modelId: 'zai/glm-5.3-flash',
  );
  await pumpGolden(
    tester,
    Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(line, style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    ),
    size: goldenSizePhone,
    theme: light ? buildFahThemeLight() : buildFahTheme(),
    locale: const Locale('en'),
  );
  await tester.pump();
}

void main() {
  setUpAll(ensureGoldenFonts);

  testWidgets('history drops — the low-key chip (light)', (tester) async {
    await _pumpChip(
      tester,
      notice: _notice(prominent: false),
      light: true,
    );
    await expectGolden(tester, 'image_drop/chip_history_light');
  });

  testWidgets('history drops — the low-key chip (dark)', (tester) async {
    await _pumpChip(
      tester,
      notice: _notice(prominent: false),
      light: false,
    );
    await expectGolden(tester, 'image_drop/chip_history_dark');
  });

  testWidgets('current-batch drops — the prominent chip (light)', (
    tester,
  ) async {
    await _pumpChip(
      tester,
      notice: _notice(prominent: true),
      light: true,
    );
    await expectGolden(tester, 'image_drop/chip_current_light');
  });

  testWidgets('the details panel — the shared projection (light)', (
    tester,
  ) async {
    await _pumpPanel(tester, light: true);
    await expectGolden(tester, 'image_drop/panel_light');
  });

  testWidgets('the details panel — the shared projection (dark)', (
    tester,
  ) async {
    await _pumpPanel(tester, light: false);
    await expectGolden(tester, 'image_drop/panel_dark');
  });
}
