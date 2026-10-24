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
  const mainJs =
      "import './blocks.js';\n"
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
    'zip': {'file': 'fa-craft-0.2.30.zip', 'sha256': '', 'sizeBytes': 100},
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

  test(
    'a web-installed multi-file widget boots through the real assembler',
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
    },
  );

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

  test('a root-level `../` import is refused — the runtime reads it outside '
      'the widget', () async {
    // PRIMARY-SOURCE divergence, verified against the real assembler
    // (js_widget_runtime 0.4.180): `WidgetManifest._resolvePath` resolves
    // against the FULL app dir (`appDir` = `apps/<id>`), so `..` past the
    // widget root does NOT clamp in-root — `import './../shared.js';`
    // resolves to `apps/shared.js`, a location the pinned preview cannot
    // serve and a cross-widget read the install must not perform. The
    // evidence pin below shows such an entry assembles to a file-not-found
    // marker (broken boot), so refusing the install is the honest path.
    final escapeServer = MockClient((request) async {
      final rel = relOf(request.url.path);
      final body = switch (rel) {
        'widget.js' => "import './../shared.js';\n",
        'manifest.json' => manifestJson,
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
      throwsA(
        isA<CatalogError>().having(
          (e) => '$e',
          'text',
          allOf(
            contains('fa-craft'),
            contains('above the widget directory'),
            contains('app namespace'),
          ),
        ),
      ),
    );
    // Runtime evidence: the same widget, installed, assembles with the
    // marker — it could never have opened.
    final files = <String, Uint8List>{
      for (final e in const {
        'manifest.json': manifestJson,
        'widget.js': "import './../shared.js';\n",
        'shared.js': 'var shared = 1;\n',
      }.entries)
        e.key: Uint8List.fromList(utf8.encode(e.value)),
    };
    final assembled = await bootAssemble(MemoryExecutionEnv(), files);
    expect(assembled, contains('/* import: file not found: ./../shared.js */'));
  });

  test(
    'deep `../` traversal above the widget root is refused loudly',
    () async {
      // Same root-escape corner, hostile shape: every `..` from the entry
      // root would step into the app namespace (the runtime resolves them
      // against `apps/<id>`); the install refuses naming the reference.
      final escapeServer = MockClient((request) async {
        final rel = relOf(request.url.path);
        final body = switch (rel) {
          'widget.js' => "import '../../../../etc/passwd.js';\n",
          'manifest.json' => manifestJson,
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
        throwsA(
          isA<CatalogError>().having(
            (e) => '$e',
            'text',
            contains('etc/passwd.js'),
          ),
        ),
      );
    },
  );

  test(
    'an import that resolves to nothing in-root fails the install',
    () async {
      final emptyServer = MockClient((request) async {
        final rel = relOf(request.url.path);
        final body = switch (rel) {
          'widget.js' => "import './';\n",
          'manifest.json' => manifestJson,
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
        httpClient: emptyServer,
      );
      await expectLater(
        service.downloadWidget(craftEntry()),
        throwsA(
          isA<CatalogError>().having(
            (e) => '$e',
            'text',
            contains('above the widget directory'),
          ),
        ),
      );
    },
  );

  test(
    'a source chain deeper than the runtime budget fails the install',
    () async {
      // The boot assembler inlines at most 5 levels per chain
      // (js_widget_runtime `WidgetManifest._maxIncludeDepth`); deeper
      // sources come back UNTOUCHED and their imports boot as literal
      // statements. Every file below is SERVED — availability is not the
      // issue; the widget could never open, so the install must refuse it.
      final requested = <String>[];
      final chainServer = MockClient((request) async {
        final rel = relOf(request.url.path);
        requested.add(rel);
        final body = switch (rel) {
          'widget.js' => "import './c1.js';\n",
          'c1.js' => "import './c2.js';\n",
          'c2.js' => "import './c3.js';\n",
          'c3.js' => "import './c4.js';\n",
          'c4.js' => "import './c5.js';\n",
          'c5.js' => "import './c6.js';\n",
          'c6.js' => 'var deep6 = 6;\n',
          'manifest.json' => manifestJson,
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
        httpClient: chainServer,
      );
      await expectLater(
        service.downloadWidget(craftEntry()),
        throwsA(
          isA<CatalogError>().having(
            (e) => '$e',
            'text',
            allOf(contains('fa-craft'), contains('deeper than 5')),
          ),
        ),
      );
      // The walk stops at the assembler's budget: the depth-6 file is never
      // even requested.
      expect(requested.where((p) => p == 'c6.js'), isEmpty);
    },
  );

  test('a chain exactly at the runtime budget installs and boots', () async {
    // Boundary lock: 5 chained sources are fully inlined by the runtime
    // (c5 processes at depth 5 with no refs left), so this widget MUST
    // install — refusing it would break legitimate deep widgets.
    final chainServer = MockClient((request) async {
      final rel = relOf(request.url.path);
      final body = switch (rel) {
        'widget.js' => "import './c1.js';\n",
        'c1.js' => "import './c2.js';\n",
        'c2.js' => "import './c3.js';\n",
        'c3.js' => "import './c4.js';\n",
        'c4.js' => "import './c5.js';\n",
        'c5.js' => 'var deep5 = 5;\n',
        'manifest.json' => manifestJson,
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
      httpClient: chainServer,
    );
    final files = await service.downloadWidget(craftEntry());
    final assembled = await bootAssemble(MemoryExecutionEnv(), files);
    expect(assembled, isNot(contains('file not found')));
    expect(assembled, isNot(contains("import './")));
    expect(assembled, contains('var deep5 = 5;'));
  });

  test('the runtime assembler leaves a literal import at depth 6', () async {
    // Evidence pin for the budget mirror (js_widget_runtime 0.4.180,
    // `_preprocessIncludes`: `if (depth >= _maxIncludeDepth) return
    // source;`): a 6-deep chain assembles with the c6 import statement
    // SURVIVING as a literal and NO file-not-found marker — the exact
    // "installed but never opens, misleading syntax-error card" failure
    // the depth refusal above prevents from ever installing.
    final files = <String, Uint8List>{
      for (final e in const {
        'manifest.json': manifestJson,
        'widget.js': "import './c1.js';\n",
        'c1.js': "import './c2.js';\n",
        'c2.js': "import './c3.js';\n",
        'c3.js': "import './c4.js';\n",
        'c4.js': "import './c5.js';\n",
        'c5.js': "import './c6.js';\n",
        'c6.js': 'var deep6 = 6;\n',
      }.entries)
        e.key: Uint8List.fromList(utf8.encode(e.value)),
    };
    final assembled = await bootAssemble(MemoryExecutionEnv(), files);
    expect(assembled, isNot(contains('file not found')));
    expect(assembled, contains("import './c6.js';"));
  });

  test(
    'a non-UTF-8 referenced file fails with a readable CatalogError',
    () async {
      final binaryServer = MockClient((request) async {
        final rel = relOf(request.url.path);
        if (rel == 'widget.js') {
          return http.Response("import './bin.dat';\n", 200);
        }
        if (rel == 'bin.dat') {
          return http.Response.bytes(<int>[0xff, 0xfe, 0x00, 0x01], 200);
        }
        if (rel == 'manifest.json') return http.Response(manifestJson, 200);
        if (rel == 'widgets/fa-craft/icon.svg') {
          return http.Response('<svg/>', 200);
        }
        return http.Response('not found', 404);
      });
      final service = CatalogService(
        MemoryExecutionEnv(),
        isWeb: true,
        rawBaseUrl: Uri.parse(rawBase),
        httpClient: binaryServer,
      );
      await expectLater(
        service.downloadWidget(craftEntry()),
        throwsA(
          isA<CatalogError>().having(
            (e) => '$e',
            'text',
            allOf(contains('fa-craft'), contains('bin.dat')),
          ),
        ),
      );
    },
  );

  test('an unsafe storage path fails before the request is spent', () async {
    // `has space.js` passes the import regex (it only stops at quotes)
    // and the lexical resolver, but AppStorage.appFile would reject it
    // with a raw ArgumentError only AFTER the install fetched everything.
    // The closure must refuse it at fetch time with the CatalogError
    // shape apps_catalog_tool surfaces.
    final requested = <String>[];
    final spaceServer = MockClient((request) async {
      final rel = relOf(request.url.path);
      requested.add(rel);
      // Uri resolution percent-encodes the space — serve it 200 so the
      // pre-fix walk fetches and installs it (the finding: the error then
      // surfaces only later, as AppStorage's raw ArgumentError).
      final body = switch (rel) {
        'widget.js' => "import './has space.js';\n",
        'has%20space.js' => 'var spaced = 1;\n',
        'manifest.json' => manifestJson,
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
      httpClient: spaceServer,
    );
    await expectLater(
      service.downloadWidget(craftEntry()),
      throwsA(
        isA<CatalogError>().having(
          (e) => '$e',
          'text',
          allOf(contains('fa-craft'), contains('has space.js')),
        ),
      ),
    );
    expect(requested.where((p) => p.contains('has space')), isEmpty);
  });

  test('a manifest `files:` list drives the closure roots', () async {
    // `WidgetManifest.readJs` files-mode concatenates the listed files
    // DIRECTLY and never reads widget.js's own import statements — the
    // listed files are the closure roots. widget.js below imports a file
    // the server does not even ship: in files-mode that must not matter.
    final requested = <String>[];
    const filesManifest =
        '{"id":"fa-craft","name":"Fa Craft","version":"0.2.30",'
        '"files":["a.js","sub/b.js"]}';
    final filesServer = MockClient((request) async {
      final rel = relOf(request.url.path);
      requested.add(rel);
      final body = switch (rel) {
        'widget.js' => "import './never-shipped.js';\nvar stale = 0;\n",
        'manifest.json' => filesManifest,
        'a.js' => "import './shared.js';\nvar a = 1;\n",
        'sub/b.js' => 'var b = 2;\n',
        'shared.js' => 'var shared = 3;\n',
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
      httpClient: filesServer,
    );
    final files = await service.downloadWidget(craftEntry());
    expect(files.containsKey('shared.js'), isTrue);
    expect(files.containsKey('sub/b.js'), isTrue);
    expect(requested.where((p) => p == 'never-shipped.js'), isEmpty);
    final assembled = await bootAssemble(MemoryExecutionEnv(), files);
    expect(assembled, isNot(contains('file not found')));
    expect(assembled, contains('var a = 1;'));
    expect(assembled, contains('var b = 2;'));
    expect(assembled, contains('var shared = 3;'));
    expect(assembled, isNot(contains('var stale = 0;')));
  });

  test('a missing `files:`-listed source fails the install loudly', () async {
    const filesManifest =
        '{"id":"fa-craft","name":"Fa Craft","version":"0.2.30",'
        '"files":["a.js","ghost.js"]}';
    final filesServer = MockClient((request) async {
      final rel = relOf(request.url.path);
      final body = switch (rel) {
        'widget.js' => 'var stale = 0;\n',
        'manifest.json' => filesManifest,
        'a.js' => 'var a = 1;\n',
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
      httpClient: filesServer,
    );
    await expectLater(
      service.downloadWidget(craftEntry()),
      throwsA(
        isA<CatalogError>().having(
          (e) => '$e',
          'text',
          allOf(contains('fa-craft'), contains('ghost.js')),
        ),
      ),
    );
  });
}
