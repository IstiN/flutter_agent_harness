// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Widget tests for the "Load unpacked" flow (gh-1616 AC1/AC2/AC4/E1/E2/E3):
// pick → validate → confirm (capabilities + replace) → install → grid
// refresh. The folder picker is stubbed; every decision dialog the user
// sees is asserted on its CONTENT (named errors, declared network).

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/catalog_service.dart';
import 'package:fa/apps/unpacked_load_flow.dart';
import 'package:fa/apps/unpacked_loader.dart';
import 'package:fa/apps/widgets_catalog_sheet.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scriptable [FolderPicker]: returns [files], or an empty list to
/// simulate a cancelled / vanished folder (E1).
class _StubPicker implements FolderPicker {
  _StubPicker(this.files);

  final Map<String, Uint8List> files;
  var pickCount = 0;

  @override
  Future<List<UnpackedPickedFile>> pickFolder() async {
    pickCount++;
    return [
      for (final entry in files.entries)
        UnpackedPickedFile(name: entry.key, bytes: entry.value),
    ];
  }
}

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
    stream.end();
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

Map<String, Uint8List> goodFolder({bool network = false}) => {
  'fa-agents/manifest.json': utf8.encode(
    jsonEncode({
      'id': 'fa-agents',
      'name': 'FA Agents',
      'version': '0.3.0',
      'network': network,
    }),
  ),
  'fa-agents/widget.js': utf8.encode('jsr.render(null);'),
};

Future<(MemoryExecutionEnv, FlutterSessionManager)> _pump(
  WidgetTester tester,
  _StubPicker picker, {
  AppsStore? appsStore,
}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = MemoryExecutionEnv();
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
  manager.addSession('test-session', _fakeService(env));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => loadUnpackedWidget(
              context,
              manager: manager,
              appsStore: appsStore,
              picker: picker,
            ),
            child: const Text('load'),
          ),
        ),
      ),
    ),
  );
  return (env, manager);
}

void main() {
  testWidgets('AC1: valid folder → confirm → installed, grid refreshes', (
    tester,
  ) async {
    final (env, manager) = await _pump(tester, _StubPicker(goodFolder()));
    manager.active!.service.fsRevision.value = 0;
    await tester.tap(find.text('load'));
    await tester.pumpAndSettle();

    // The capability confirm names the widget before anything is written.
    expect(find.text('FA Agents'), findsOneWidget);
    expect(find.textContaining('fa-agents'), findsOneWidget);
    expect(
      (await env.listDir('apps')).valueOrNull ?? const [],
      isEmpty,
      reason: 'nothing is written before the user confirms',
    );

    await tester.tap(find.text('Load'));
    await tester.pumpAndSettle();

    expect(
      (await env.readTextFile('apps/fa-agents/widget.js')).valueOrNull,
      'jsr.render(null);',
    );
    expect(manager.active!.service.fsRevision.value, greaterThan(0));
  });

  testWidgets('E2: the confirm lists a declared network capability', (
    tester,
  ) async {
    await _pump(tester, _StubPicker(goodFolder(network: true)));
    await tester.tap(find.text('load'));
    await tester.pumpAndSettle();

    // The exfiltration gate: the declared fetch capability is on the
    // confirmation the user grants.
    expect(find.byIcon(Icons.wifi), findsOneWidget);
    expect(find.textContaining('network'), findsWidgets);
  });

  testWidgets('AC2: invalid folder → named error dialog, nothing written', (
    tester,
  ) async {
    final (env, _) = await _pump(
      tester,
      _StubPicker({
        'manifest.json': utf8.encode(jsonEncode({'id': 'BAD ID'})),
        'widget.js': utf8.encode('x'),
      }),
    );
    await tester.tap(find.text('load'));
    await tester.pumpAndSettle();

    // The error NAMES the problem (the id rule), it is never a raw
    // engine crash — and nothing is written.
    expect(find.textContaining('[a-z0-9][a-z0-9-]{1,31}'), findsOneWidget);
    expect((await env.listDir('apps')).valueOrNull ?? const [], isEmpty);
  });

  testWidgets('AC4/E3: replacing an existing id asks for confirmation', (
    tester,
  ) async {
    final (env, _) = await _pump(tester, _StubPicker(goodFolder()));
    final store = AppsStore(env, readAsset: (_) async => '');
    await store.installWidget(
      id: 'fa-agents',
      version: '2.0.0',
      files: {
        'manifest.json': utf8.encode(
          jsonEncode({
            'id': 'fa-agents',
            'name': 'Catalog version',
            'version': '2.0.0',
          }),
        ),
        'widget.js': utf8.encode('catalog'),
      },
    );

    await tester.tap(find.text('load'));
    await tester.pumpAndSettle();

    // The replace warning names the existing install and its source.
    expect(find.textContaining('2.0.0'), findsOneWidget);
    expect(find.textContaining('catalog'), findsWidgets);

    // Cancel → nothing replaced.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      (await env.readTextFile('apps/fa-agents/widget.js')).valueOrNull,
      'catalog',
    );
  });

  testWidgets('AC4: replacing an agent-created app (no install record) warns', (
    tester,
  ) async {
    final (env, _) = await _pump(tester, _StubPicker(goodFolder()));
    // An agent-created app: files written straight into apps/<id>/ by the
    // agent's file tools — NO `.installed.json` record, so installSource
    // is null. Loading the same id overwrites that code, so the replace
    // warning must still fire (AC4), naming the honest provenance.
    await env.writeFile(
      'apps/fa-agents/manifest.json',
      jsonEncode({'id': 'fa-agents', 'name': 'Agent build', 'version': '0.1.0'}),
    );
    await env.writeFile('apps/fa-agents/widget.js', 'agent-code');

    await tester.tap(find.text('load'));
    await tester.pumpAndSettle();

    // The replace warning — not a plain fresh-load confirm.
    expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
    expect(find.text('Replace'), findsOneWidget);
    expect(find.textContaining('agent'), findsWidgets);
    expect(find.textContaining('0.1.0'), findsOneWidget);

    // Cancel → the agent-created code survives untouched.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      (await env.readTextFile('apps/fa-agents/widget.js')).valueOrNull,
      'agent-code',
    );
  });

  testWidgets(
    'AC4: a padded-id pick still warns over the trimmed-id install',
    (tester) async {
      // The id is trimmed before the replace lookup (gh-1616 review): a
      // " fa-agents " manifest must be recognized as replacing the
      // existing fa-agents install, not as a fresh id.
      final (env, manager) = await _pump(tester, _StubPicker(const {}));
      final store = AppsStore(env, readAsset: (_) async => '');
      await store.installWidget(
        id: 'fa-agents',
        version: '2.0.0',
        files: {
          'manifest.json': utf8.encode(
            jsonEncode({'id': 'fa-agents', 'name': 'Cat', 'version': '2.0.0'}),
          ),
          'widget.js': utf8.encode('catalog'),
        },
      );

      final padded = {
        'fa-agents/manifest.json': utf8.encode(
          jsonEncode({
            'id': ' fa-agents ',
            'name': 'FA Agents',
            'version': '0.3.0',
          }),
        ),
        'fa-agents/widget.js': utf8.encode('jsr.render(null);'),
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => loadUnpackedWidget(
                  context,
                  manager: manager,
                  appsStore: store,
                  picker: _StubPicker(padded),
                ),
                child: const Text('load'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('load'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
      expect(find.text('Replace'), findsOneWidget);
    },
  );

  testWidgets('E1: an empty pick (vanished folder) is a silent no-op', (
    tester,
  ) async {
    final (env, _) = await _pump(tester, _StubPicker({}));
    await tester.tap(find.text('load'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect((await env.listDir('apps')).valueOrNull ?? const [], isEmpty);
  });

  testWidgets('the catalog sheet shows the unpacked provenance chip', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    manager.addSession('test-session', _fakeService(env));
    final store = AppsStore(env, readAsset: (_) async => '');
    await env.writeFile(
      'apps/local-thing/manifest.json',
      jsonEncode({'id': 'local-thing', 'name': 'Local Thing'}),
    );
    await env.writeFile('apps/local-thing/widget.js', 'x');
    final loader = UnpackedWidgetLoader(env: env, appsStore: store);
    await loader.install(
      await loader.inspect({
        'manifest.json': utf8.encode(
          jsonEncode({'id': 'side-loaded', 'name': 'Side-loaded'}),
        ),
        'widget.js': utf8.encode('x'),
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        home: Scaffold(
          body: WidgetsCatalogSheet(
            env: env,
            manager: manager,
            appsStore: store,
            catalogService: _EmptyCatalog(env),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Side-loaded'), findsOneWidget);
    expect(find.text('unpacked'), findsOneWidget);
    expect(find.text('Local Thing'), findsOneWidget);
  });
}

class _EmptyCatalog extends CatalogService {
  _EmptyCatalog(super.env);

  @override
  Future<CatalogFetchResult> fetchCatalog({bool force = false}) async =>
      CatalogFetchResult(entries: [_otherEntry], stale: false);
}

/// One catalog row that is NOT installed locally, so the "Created by me"
/// section renders (it hides behind the empty-catalog placeholder) and
/// the provenance chip is asserted against a locally unpacked app.
final CatalogEntry _otherEntry = CatalogEntry(
  id: 'from-catalog',
  name: 'From Catalog',
  version: '1.0.0',
  description: 'A catalog widget',
  author: 'IstiN',
  tags: const [],
  minRuntime: '0.4.79',
  iconFile: '',
  network: false,
  allowedCommands: const [],
  zipFile: 'from-catalog.zip',
  zipSha256: '0${'0' * 63}',
  zipSizeBytes: 10,
);
