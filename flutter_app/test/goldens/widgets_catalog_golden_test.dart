/// Golden coverage for the fa_widgets catalog sheet (`WidgetsCatalogSheet`):
/// the loaded-catalog grid and the offline/error state.
///
/// The catalog HTTP layer is a MockClient, so the sheet renders offline-safe
/// with real fonts and the app theme.
library;

import 'dart:convert';

import 'package:fa/apps/widgets_catalog_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'golden_test_helper.dart';

http.Client _catalogServer() => MockClient((req) async {
  final name = req.url.pathSegments.last;
  if (name == 'catalog.json') {
    return http.Response(
      jsonEncode({
        'widgets': [
          {
            'id': 'focus-timer',
            'name': 'Focus Timer',
            'version': '1.2.0',
            'description': 'Pomodoro timer with long breaks',
            'icon': 'icon.svg',
            'tags': ['timer'],
            'permissions': {'network': false, 'allowedCommands': []},
            'zip': {'file': 'focus-timer-1.2.0.zip'},
          },
          {
            'id': 'unit-convert',
            'name': 'Unit Converter',
            'version': '0.9.1',
            'description': 'Length, mass and temperature in one tile',
            'tags': ['tools'],
            'permissions': {'network': false, 'allowedCommands': []},
            'zip': {'file': 'unit-convert-0.9.1.zip'},
          },
        ],
      }),
      200,
    );
  }
  if (name == 'icon.svg') {
    return http.Response(
      "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
      "<circle cx='12' cy='12' r='8' fill='none' stroke='#f8fafc' "
      "stroke-width='2'/><path d='M12 7v5l3 2' fill='none' "
      "stroke='#f8fafc' stroke-width='2' stroke-linecap='round'/></svg>",
      200,
    );
  }
  return http.Response('nf', 404);
});

void main() {
  setUpAll(ensureGoldenFonts);

  Future<void> pumpSheet(
    WidgetTester tester,
    http.Client client,
    Size size,
  ) async {
    await pumpGolden(
      tester,
      WidgetsCatalogSheet(env: MemoryExecutionEnv(), httpClient: client),
      size: size,
      // Full app frame at the mandated phone/desktop sizes — never a
      // floating 420px strip on an empty backdrop.
      wrap: (child) => Scaffold(body: child),
    );
  }

  testWidgets('widgets catalog sheet lists installable entries — phone', (
    tester,
  ) async {
    await pumpSheet(tester, _catalogServer(), goldenSizePhone);
    await expectGolden(tester, 'widgets_catalog_sheet');
  });

  testWidgets('widgets catalog sheet lists installable entries — desktop', (
    tester,
  ) async {
    await pumpSheet(tester, _catalogServer(), goldenSizeDesktop);
    await expectGolden(tester, 'widgets_catalog_sheet_desktop');
  });

  testWidgets('widgets catalog sheet shows the offline error state', (
    tester,
  ) async {
    // A 404 for everything: the sheet surfaces its could-not-load state.
    await pumpSheet(
      tester,
      MockClient((req) async => http.Response('nf', 404)),
      const Size(500, 800),
    );
    await expectGolden(tester, 'widgets_catalog_sheet_error');
  });
}
