import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/catalog_service.dart';
import 'package:fa/apps/widgets_catalog_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Uint8List zipOf(String id) {
  final archive = Archive();
  final data = {
    '$id/manifest.json': utf8.encode('{"id":"$id"}'),
    '$id/widget.js': utf8.encode('/* $id */'),
  };
  for (final name in data.keys.toList()..sort()) {
    final bytes = data[name]!;
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

http.Client okServer() => MockClient((req) async {
  final name = req.url.pathSegments.last;
  if (name == 'catalog.json') {
    return http.Response(
      jsonEncode({
        'widgets': [
          {
            'id': 'focus-timer',
            'name': 'Focus Timer',
            'version': '1.0.0',
            'description': 'Pomodoro timer',
            'tags': ['timer'],
            'permissions': {'network': false, 'allowedCommands': []},
            'zip': {'file': 'focus-timer-1.0.0.zip'},
          },
        ],
      }),
      200,
    );
  }
  if (name == 'focus-timer-1.0.0.zip') {
    return http.Response.bytes(zipOf('focus-timer'), 200);
  }
  return http.Response('nf', 404);
});

Future<void> pumpSheet(
  WidgetTester tester, {
  required MemoryExecutionEnv env,
  http.Client? client,
  Future<void> Function(BuildContext, JsAppInfo)? onOpenApp,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 420,
          height: 700,
          child: WidgetsCatalogSheet(
            env: env,
            httpClient: client,
            onOpenApp: onOpenApp,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders entries with install buttons', (tester) async {
    final env = MemoryExecutionEnv();
    await pumpSheet(tester, env: env, client: okServer());
    expect(find.textContaining('Focus Timer'), findsWidgets);
    expect(find.widgetWithText(FilledButton, 'Install'), findsOneWidget);
    expect(find.textContaining('v1.0.0'), findsOneWidget);
  });

  testWidgets('install flow writes the widget and the button becomes Open', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await pumpSheet(tester, env: env, client: okServer());
    await tester.tap(find.widgetWithText(FilledButton, 'Install'));
    await tester.pumpAndSettle();

    expect(
      (await env.readTextFile('apps/focus-timer/widget.js')).valueOrNull,
      contains('focus-timer'),
    );
    expect(find.widgetWithText(FilledButton, 'Open'), findsOneWidget);
  });

  testWidgets('Open on an installed widget fires the open hook', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final opened = <String>[];
    await pumpSheet(
      tester,
      env: env,
      client: okServer(),
      onOpenApp: (context, app) async => opened.add(app.id),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Install'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Open'));
    await tester.pumpAndSettle();
    expect(opened, ['focus-timer']);
  });

  testWidgets('Preview installs a missing widget and opens it right away', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final opened = <String>[];
    await pumpSheet(
      tester,
      env: env,
      client: okServer(),
      onOpenApp: (context, app) async => opened.add(app.id),
    );
    await tester.tap(find.widgetWithText(TextButton, 'Preview'));
    await tester.pumpAndSettle();

    expect(
      (await env.readTextFile('apps/focus-timer/widget.js')).valueOrNull,
      contains('focus-timer'),
    );
    expect(opened, ['focus-timer']);
  });

  testWidgets('an older installed version offers Update', (tester) async {
    final env = MemoryExecutionEnv();
    await env.writeFile(
      'apps/focus-timer/manifest.json',
      '{"id":"focus-timer","name":"Focus Timer","version":"0.9.0"}',
    );
    await pumpSheet(tester, env: env, client: okServer());
    expect(find.widgetWithText(FilledButton, 'Update'), findsOneWidget);
  });

  testWidgets('stale catalog shows the offline banner with retry', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final stale = jsonEncode({
      'fetchedAt': '2020-01-01T00:00:00.000Z',
      'catalog': {
        'widgets': [
          {
            'id': 'cached',
            'name': 'Cached Widget',
            'version': '1.0.0',
            'zip': {'file': 'cached-1.0.0.zip'},
          },
        ],
      },
    });
    await env.writeFile(CatalogService.cacheFile, stale);
    var failing = true;
    final healthy = okServer();
    final client = MockClient((req) async {
      if (failing) return http.Response('boom', 500);
      return healthy.get(req.url);
    });

    await pumpSheet(tester, env: env, client: client);
    expect(find.textContaining('Offline'), findsOneWidget);
    expect(find.textContaining('Cached Widget'), findsOneWidget);

    // Retry heals.
    failing = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Offline'), findsNothing);
  });

  testWidgets('load failure renders the retry view', (tester) async {
    final env = MemoryExecutionEnv();
    final client = MockClient((req) async => http.Response('boom', 500));
    await pumpSheet(tester, env: env, client: client);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('Could not load'), findsOneWidget);
  });
}
