library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/apps/app_storage.dart';
import 'package:fa/apps/catalog_service.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// gh-1831 — the web catalog install must fetch a multi-file widget's
/// WHOLE transitive source closure, not just manifest.json + widget.js.
///
/// fa-craft's entry is a one-line stub (`import './game/main.js';`) and the
/// game lives in sibling files that the zip path installs on native. The
/// web path fetched only the catalog entry's preview manifest.json/widget.js
/// + icon, so the boot assembler commented the import out
/// (`/* import: file not found: ./game/main.js */`), the widget evaluated
/// to an empty script, never rendered, and the open died on the bootError
/// watchdog — "files fetch 200 but open/render fails". The owner's HAR
/// shows exactly the 3 stub fetches and no game/*.js requests.
///
/// The oracle for "the install is bootable" is the runtime's OWN entry
/// assembler ([JsAppEngine.assembleEntryJsForTest]) — the same inlining
/// pass the engine runs at open.
void main() {
  // The pinned external repo shape: preview URLs under one commit ref,
  // sources relative to the entry URL's directory (fa-craft at ref
  // f5c57be6c85ff28b5615b9013a78c38d1e80bbd4, per the fa_widgets catalog).
  const ref = 'f5c57be6c85ff28b5615b9013a78c38d1e80bbd4';
  const repoBase = 'https://raw.githubusercontent.com/IstiN/fa_craft/$ref';
  const rawBase = 'https://raw.githubusercontent.com/IstiN/fa_widgets/main/';

  const manifestJson = '{"id":"fa-craft","name":"Fa Craft","version":"0.2.30"}';
  const entryJs = "// stub entry\nimport './game/main.js';\n";
  const mainJs = "import './blocks.js';\n"
      "import { hud } from './ui/hud.js';\n"
      "jsr.include('./fx.js');\n"
      'var Facraft = { started: true };\n';
  const blocksJs = 'var blocks = 1;\n';
  const hudJs = 'export var hud = 2;\n'; // export stripped at assembly
  const fxJs = 'var fx = 3;\n';

  /// `/IstiN/fa_craft/<ref>/game/main.js` → `game/main.js`;
  /// `/IstiN/fa_widgets/main/widgets/fa-craft/icon.svg` →
  /// `widgets/fa-craft/icon.svg`.
  String relOf(String path) {
    final parts = path.split('/')..removeAt(0); // leading empty segment
    if (parts.length <= 3) return path;
    return parts.skip(3).join('/');
  }

  String bodyFor(String rel) => switch (rel) {
    'manifest.json' => manifestJson,
    'widget.js' => entryJs,
    'game/main.js' => mainJs,
    'game/blocks.js' => blocksJs,
    'game/ui/hud.js' => hudJs,
    'game/fx.js' => fxJs,
    'widgets/fa-craft/icon.svg' => '<svg/>',
    _ => 'nf',
  };

  /// Serves the pinned repo layout + the mirrored icon; records every hit
  /// as repo-relative paths.
  MockClient server(List<String> requested, {Set<String> missing = const {}}) {
    return MockClient((request) async {
      final rel = relOf(request.url.path);
      requested.add(rel);
      if (missing.contains(rel) || bodyFor(rel) == 'nf') {
        return http.Response('not found', 404);
      }
      return http.Response(bodyFor(rel), 200);
    });
  }

  CatalogEntry craftEntry() => CatalogEntry.fromJson({
    'id': 'fa-craft',
    'name': 'Fa Craft',
    'version': '0.2.30',
    'description': 'voxel sandbox',
    'author': 'Fa',
    'tags': ['game'],
    'permissions': {'network': false, 'allowedCommands': <String>[]},
    'minRuntime': '0.4.161',
    'icon': 'icon.svg',
    'zip': {
      'file': 'fa-craft-0.2.30.zip',
      'sha256': '',
      'sizeBytes': 100,
    },
    'preview': {
      'manifest': '$repoBase/manifest.json',
      'js': '$repoBase/widget.js',
    },
  });

  /// Writes [files] into [env] exactly like `AppsStore.installWidget`
  /// lays them out (apps/<id>/<relative>), then runs the REAL boot
  /// assembler — the same pass [JsAppEngine.start] runs at open.
  Future<String> bootAssemble(
    ExecutionEnv env,
    Map<String, Uint8List> files,
  ) async {
    for (final entry in files.entries) {
      await env.writeBinaryFile(
        '${AppStorage.root}/fa-craft/${entry.key}',
        entry.value,
      );
    }
    return JsAppEngine.assembleEntryJsForTest(
      env: env,
      dir: '${AppStorage.root}/fa-craft',
      entryFile: 'widget.js',
    );
  }

  test('web install fetches the full transitive source closure', () async {
    final requested = <String>[];
    final service = CatalogService(
      MemoryExecutionEnv(),
      isWeb: true,
      rawBaseUrl: Uri.parse(rawBase),
      httpClient: server(requested),
    );
    final files = await service.downloadWidget(craftEntry());
    expect(files.keys.toList()..sort(), [
      'game/blocks.js',
      'game/fx.js',
      'game/main.js',
      'game/ui/hud.js',
      'icon.svg',
      'manifest.json',
      'widget.js',
    ]);
    // The stub entry itself stays byte-identical, siblings ride along.
    expect(utf8.decode(files['widget.js']!), entryJs);
    expect(utf8.decode(files['game/main.js']!), mainJs);
    // Every closure file came from the PINNED ref directory.
    expect(
      requested.where((p) => p.startsWith('game/') || p == 'widget.js'),
      containsAll([
        'widget.js',
        'game/main.js',
        'game/blocks.js',
        'game/ui/hud.js',
        'game/fx.js',
      ]),
    );
  });

  test('a web-installed multi-file widget boots through the real assembler',
      () async {
    final requested = <String>[];
    final service = CatalogService(
      MemoryExecutionEnv(),
      isWeb: true,
      rawBaseUrl: Uri.parse(rawBase),
      httpClient: server(requested),
    );
    final files = await service.downloadWidget(craftEntry());
    final assembled = await bootAssemble(MemoryExecutionEnv(), files);
    // The oracle: no "file not found" marker survives, and the imported
    // game code is actually IN the assembled source.
    expect(assembled, isNot(contains('file not found')));
    expect(assembled, contains('var Facraft = { started: true };'));
    expect(assembled, contains('var blocks = 1;'));
    expect(assembled, contains('var fx = 3;'));
  });

  test('a missing referenced source fails the install loudly', () async {
    final requested = <String>[];
    final service = CatalogService(
      MemoryExecutionEnv(),
      isWeb: true,
      rawBaseUrl: Uri.parse(rawBase),
      httpClient: server(requested, missing: {'game/blocks.js'}),
    );
    await expectLater(
      service.downloadWidget(craftEntry()),
      throwsA(
        isA<CatalogError>().having(
          (e) => '$e',
          'text',
          allOf(contains('fa-craft'), contains('game/blocks.js')),
        ),
      ),
    );
  });

  test('a file imported twice is fetched once', () async {
    final requested = <String>[];
    // main.js reached both through widget.js's import AND a jsr.include —
    // the closure still hits the URL exactly once.
    final dedupeServer = MockClient((request) async {
      final rel = relOf(request.url.path);
      requested.add(rel);
      final body = rel == 'widget.js'
          ? "$entryJs\njsr.include('./game/main.js');\n"
          : bodyFor(rel);
      if (body == 'nf') return http.Response('not found', 404);
      return http.Response(body, 200);
    });
    final service = CatalogService(
      MemoryExecutionEnv(),
      isWeb: true,
      rawBaseUrl: Uri.parse(rawBase),
      httpClient: dedupeServer,
    );
    final files = await service.downloadWidget(craftEntry());
    expect(requested.where((p) => p == 'game/main.js'), hasLength(1));
    expect(files.containsKey('game/main.js'), isTrue);
  });

  test('a closure path escaping the widget dir is rejected', () async {
    final escapeServer = MockClient((request) async {
      final rel = relOf(request.url.path);
      final body = switch (rel) {
        'widget.js' => "import '../escape.js';\n",
        'manifest.json' => manifestJson,
        'escape.js' => 'var evil = 1;\n',
        'widgets/fa-craft/icon.svg' => '<svg/>',
        _ => 'nf',
      };
      if (body == 'nf') return http.Response('not found', 404);
      return http.Response(body, 200);
    });
    final service = CatalogService(
      MemoryExecutionEnv(),
      isWeb: true,
      rawBaseUrl: Uri.parse(rawBase),
      httpClient: escapeServer,
    );
    await expectLater(
      service.downloadWidget(craftEntry()),
      throwsA(isA<CatalogError>()),
    );
  });
}
