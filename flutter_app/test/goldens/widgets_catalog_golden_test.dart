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
      SizedBox(
        width: 420,
        height: 700,
        child: WidgetsCatalogSheet(
          env: MemoryExecutionEnv(),
          httpClient: client,
        ),
      ),
      size: size,
    );
  }

  testWidgets('widgets catalog sheet lists installable entries', (
    tester,
  ) async {
    await pumpSheet(tester, _catalogServer(), goldenSizeTall);
    await expectGolden(tester, 'widgets_catalog_sheet');
  });

  testWidgets('widgets catalog sheet shows the offline error state', (
    tester,
  ) async {
    // A 404 for everything: the sheet surfaces its could-not-load state.
    await pumpSheet(
      tester,
      MockClient((req) async => http.Response('nf', 404)),
      goldenSizeTall,
    );
    await expectGolden(tester, 'widgets_catalog_sheet_error');
  });
}
