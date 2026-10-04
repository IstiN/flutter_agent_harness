import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/catalog_service.dart';
import 'package:fa/services/apps_catalog_tool.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Text of a single-block text result (tests only).
String textOf(ToolExecutionResult result) => result.content
    .whereType<TextContent>()
    .map((block) => block.text)
    .join('\n');

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

http.Client server(Map<String, dynamic> catalog) => MockClient((req) async {
  final name = req.url.pathSegments.last;
  if (name == 'catalog.json') return http.Response(jsonEncode(catalog), 200);
  for (final w in catalog['widgets'] as List) {
    // Match on the catalog's declared zip file, exactly like the live
    // catalog does — a versioned name (weather-2.0.0.zip) must resolve.
    final zip = w['zip'];
    final file = zip is Map ? zip['file'] : null;
    if (file is String && file == name) {
      final wid = w['id'];
      if (wid is! String) return http.Response('bad', 500);
      return http.Response.bytes(zipOf(wid), 200);
    }
  }
  return http.Response('nf', 404);
});

Future<ToolExecutionResult> call(
  AgentTool tool,
  Map<String, dynamic> args,
) async => tool.execute(args, null, null);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryExecutionEnv env;
  late CatalogService service;
  late AppsStore store;
  late AgentTool tool;

  setUp(() {
    env = MemoryExecutionEnv();
    service = CatalogService(
      env,
      httpClient: server({
        'widgets': [
          {
            'id': 'focus-timer',
            'version': '1.0.0',
            'description': 'Pomodoro',
            'tags': ['timer'],
            'zip': {'file': 'focus-timer-1.0.0.zip'},
          },
          {
            'id': 'weather',
            'version': '2.0.0',
            'description': 'Weather panel',
            'tags': ['weather'],
            'zip': {'file': 'weather-2.0.0.zip'},
          },
        ],
      }),
    );
    store = AppsStore(env, readAsset: (_) async => '');
    tool = appsCatalogTool(env: env, catalog: service, apps: store);
  });

  test('list renders id/version/description lines', () async {
    final result = await call(tool, {'action': 'list'});
    expect(textOf(result), contains('focus-timer v1.0.0 — Pomodoro'));
    expect(textOf(result), contains('weather v2.0.0'));
  });

  test('search filters by keyword across name/tags', () async {
    final result = await call(tool, {'action': 'search', 'query': 'timer'});
    expect(textOf(result), contains('focus-timer'));
    expect(textOf(result), isNot(contains('weather')));
  });

  test('unknown action is a clean usage line', () async {
    final result = await call(tool, {'action': 'wat'});
    expect(textOf(result), contains('Unknown action'));
  });

  test('get-source unpacks into .fah/widget-sources/<id>/', () async {
    final result = await call(tool, {
      'action': 'get-source',
      'id': 'focus-timer',
    });
    expect(textOf(result), contains('$widgetSourcesDir/focus-timer/'));
    final source = (await env.readTextFile(
      '$widgetSourcesDir/focus-timer/widget.js',
    )).valueOrNull;
    expect(source, contains('focus-timer'));
    // The live apps/ copy is NOT touched by get-source.
    expect(
      (await env.exists('apps/focus-timer/widget.js')).valueOrNull,
      isFalse,
    );
  });

  test('install writes the app; remove drops it but keeps storage', () async {
    await call(tool, {'action': 'install', 'id': 'weather'});
    expect((await env.exists('apps/weather/widget.js')).valueOrNull, isTrue);

    await env.writeFile('apps/weather/storage.json', '{"city":"Oslo"}');
    await call(tool, {'action': 'remove', 'id': 'weather'});
    expect((await env.exists('apps/weather/widget.js')).valueOrNull, isFalse);
    expect((await env.exists('apps/weather/storage.json')).valueOrNull, isTrue);

    final again = await call(tool, {'action': 'remove', 'id': 'weather'});
    expect(textOf(again), contains('Nothing catalog-installed'));
  });

  test('write twin is write-tier with the same surface', () {
    final writeTool = appsCatalogWriteTool(env: env);
    expect(writeTool.tier, ApprovalTier.write);
    expect(writeTool.name, '${appsCatalogToolName}_write');
    expect(writeTool.parameters, tool.parameters);
  });

  test('missing id on install is actionable', () async {
    final result = await call(tool, {'action': 'install'});
    expect(textOf(result), contains('Provide a widget'));
  });

  test('unknown id points to list', () async {
    final result = await call(tool, {'action': 'install', 'id': 'nope'});
    expect(textOf(result), contains('not in the catalog'));
  });

  // Issue #866 AC2 — a freshly agent-written app is visible to the very
  // agent that wrote it: the next apps_catalog call lists it, even with
  // the remote catalog unaware (or unreachable).
  test('AC2 — a write under apps/ shows up on the next list', () async {
    expect(await store.listApps(), isEmpty);
    await env.writeFile(
      'apps/2048/manifest.json',
      '{"id": "2048", "name": "2048", "description": "Tile game"}',
    );
    await env.writeFile('apps/2048/widget.js', '(function(){});');
    final result = await call(tool, {'action': 'list'});
    expect(textOf(result), contains('2048 v1.0.0 — Tile game'));
    expect(textOf(result), contains('(installed in apps/)'));
  });

  test('AC2 — search matches freshly written apps too', () async {
    await env.writeFile(
      'apps/2048/manifest.json',
      '{"id": "2048", "name": "2048", "description": "Tile game"}',
    );
    final result = await call(tool, {'action': 'search', 'query': '2048'});
    expect(textOf(result), contains('2048'));
    expect(textOf(result), isNot(contains('focus-timer')));
  });

  test('AC2 — broken agent manifests surface as BROKEN lines', () async {
    await env.writeFile('apps/2048/manifest.json', '{oops');
    final result = await call(tool, {'action': 'list'});
    expect(textOf(result), contains('2048 — BROKEN:'));
  });

  test('AC2 — remote outage still lists the local workspace', () async {
    await env.writeFile(
      'apps/2048/manifest.json',
      '{"id": "2048", "name": "2048"}',
    );
    final offline = appsCatalogTool(
      env: env,
      catalog: CatalogService(
        env,
        httpClient: MockClient(
          (request) async => throw Exception('network down'),
        ),
      ),
      apps: store,
    );
    final result = await call(offline, {'action': 'list'});
    expect(textOf(result), contains('2048'));
    expect(textOf(result), isNot(contains('Catalog unavailable')));
  });

  test('R5 — an installed catalog widget is listed once, not twice', () async {
    await call(tool, {'action': 'install', 'id': 'focus-timer'});
    final result = await call(tool, {'action': 'list'});
    final text = textOf(result);
    // Same id locally and remotely is ONE widget: the local line wins.
    expect('focus-timer v1.0.0'.allMatches(text), hasLength(1));
    expect(text, contains('focus-timer v1.0.0 (installed in apps/)'));
    // Remote-only widgets still appear.
    expect(text, contains('weather v2.0.0'));
  });

  test('R5 — a newer remote version annotates the local line', () async {
    await env.writeFile(
      'apps/focus-timer/manifest.json',
      '{"id": "focus-timer", "name": "Focus timer", "version": "0.9.0"}',
    );
    await env.writeFile('apps/focus-timer/widget.js', '(function(){});');
    final result = await call(tool, {'action': 'list'});
    final text = textOf(result);
    expect(text, contains('focus-timer v0.9.0'));
    expect(text, contains('(update available: v1.0.0)'));
    // No bare remote duplicate of the installed widget.
    expect(text, isNot(contains('focus-timer v1.0.0 — Pomodoro')));
  });

  test('R5 — a duplicate remote id annotates at most once', () async {
    await env.writeFile(
      'apps/focus-timer/manifest.json',
      '{"id": "focus-timer", "name": "Focus timer", "version": "0.9.0"}',
    );
    await env.writeFile('apps/focus-timer/widget.js', '(function(){});');
    // Bad catalog data: the same id listed twice with the same version.
    final dupCatalog = {
      'widgets': [
        {
          'id': 'focus-timer',
          'version': '1.0.0',
          'description': 'Pomodoro',
          'tags': ['timer'],
          'zip': {'file': 'focus-timer-1.0.0.zip'},
        },
        {
          'id': 'focus-timer',
          'version': '1.0.0',
          'description': 'Pomodoro',
          'tags': ['timer'],
          'zip': {'file': 'focus-timer-1.0.0.zip'},
        },
      ],
    };
    final dup = appsCatalogTool(
      env: env,
      catalog: CatalogService(env, httpClient: server(dupCatalog)),
      apps: store,
    );
    final result = await call(dup, {'action': 'list'});
    expect(
      '(update available: v1.0.0)'.allMatches(textOf(result)),
      hasLength(1),
    );
  });
}
