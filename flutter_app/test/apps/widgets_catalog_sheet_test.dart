import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/catalog_service.dart';
import 'package:fa/apps/widgets_catalog_sheet.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    return stream;
  };
}

AgentService _fakeService(ExecutionEnv env) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test',
        baseUrl: 'https://example.com',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are Fa.',
      streamFunction: _singleTextResponse('ok'),
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

Uint8List zipOf(String id) {
  final archive = Archive();
  final data = {
    '$id/manifest.json': utf8.encode(
      '{"id":"$id","name":"$id","version":"1.0.0"}',
    ),
    '$id/widget.js': utf8.encode('/* $id */'),
  };
  for (final name in data.keys.toList()..sort()) {
    final bytes = data[name]!;
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

http.Client okServer({List<String>? platforms}) => MockClient((req) async {
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
            'platforms': ?platforms,
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
  FlutterSessionManager? manager,
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
            manager: manager,
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

  testWidgets('platform chips render next to the tag chips', (tester) async {
    final env = MemoryExecutionEnv();
    await pumpSheet(
      tester,
      env: env,
      client: okServer(platforms: ['ios', 'macos']),
    );
    // Topic tags still show alongside the platform chips.
    expect(find.text('timer'), findsOneWidget);
    expect(find.text('ios'), findsOneWidget);
    expect(find.text('macos'), findsOneWidget);
    // Platform chips are visually distinguished by a tertiary border.
    final chip = tester.widget<Chip>(
      find.ancestor(of: find.text('ios'), matching: find.byType(Chip)),
    );
    final theme = Theme.of(tester.element(find.text('ios')));
    expect(chip.side?.color, theme.colorScheme.tertiary);
  });

  testWidgets('entries without platforms render no platform chips', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await pumpSheet(tester, env: env, client: okServer());
    expect(find.text('timer'), findsOneWidget);
    expect(find.text('ios'), findsNothing);
    expect(find.text('macos'), findsNothing);
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
    await tester.tap(find.widgetWithText(OutlinedButton, 'Preview'));
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

  testWidgets('an installed current widget swaps Preview for Remove', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await pumpSheet(tester, env: env, client: okServer());
    await tester.tap(find.widgetWithText(FilledButton, 'Install'));
    await tester.pumpAndSettle();

    // Installed & current: Open + Remove, no Preview.
    expect(find.widgetWithText(OutlinedButton, 'Preview'), findsNothing);
    final remove = find.widgetWithText(OutlinedButton, 'Remove');
    expect(remove, findsOneWidget);

    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(
      (await env.readTextFile('apps/focus-timer/manifest.json')).valueOrNull,
      isNull,
    );
    expect(find.widgetWithText(FilledButton, 'Install'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Preview'), findsOneWidget);
  });

  testWidgets('local apps missing from the catalog list as Created by me', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await env.writeFile(
      'apps/my-tool/manifest.json',
      '{"id":"my-tool","name":"My Tool","version":"1.0.0"}',
    );
    await env.writeFile('apps/my-tool/widget.js', '// mine');
    await pumpSheet(tester, env: env, client: okServer());

    expect(find.text('Created by me'), findsOneWidget);
    expect(find.text('My Tool'), findsOneWidget);
    // The catalog entry itself is still listed below the section.
    expect(find.textContaining('Focus Timer'), findsWidgets);
  });

  testWidgets('install bumps the active service fsRevision (grid refresh)', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('s', _fakeService(env));
    final fsRevision = manager.active!.service.fsRevision;
    final before = fsRevision.value;
    await pumpSheet(tester, env: env, client: okServer(), manager: manager);
    await tester.tap(find.widgetWithText(FilledButton, 'Install'));
    await tester.pumpAndSettle();
    expect(fsRevision.value, greaterThan(before));
  });

  testWidgets('remove bumps the active service fsRevision (grid refresh)', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('s', _fakeService(env));
    final fsRevision = manager.active!.service.fsRevision;
    await pumpSheet(tester, env: env, client: okServer(), manager: manager);
    await tester.tap(find.widgetWithText(FilledButton, 'Install'));
    await tester.pumpAndSettle();
    final before = fsRevision.value;
    await tester.tap(find.widgetWithText(OutlinedButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(fsRevision.value, greaterThan(before));
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
