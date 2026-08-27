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
    if ('${w['id']}-1.0.0.zip' == name) {
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
    final source =
        (await env.readTextFile(
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
}
