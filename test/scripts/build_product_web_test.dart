import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../../scripts/build_product_web.dart';

void main() {
  late Directory temp;
  late Directory assets;
  late File profile;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('fa-product-web-test-');
    assets = Directory('${temp.path}/assets')..createSync();
    profile = File('${temp.path}/product.json');
    _writeAssets(assets);
    profile.writeAsStringSync(jsonEncode(_profile()));
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<String> buildFromRealIndex(String output, {String? baseHref}) async {
    final realIndex = File('flutter_app/web/index.html').readAsStringSync();
    await buildProductWeb(
      profilePath: profile.path,
      assetsPath: assets.path,
      outputPath: output,
      baseHref: baseHref,
      builder: (path) async {
        final shell = _fixtureShell(Directory(path));
        File('${shell.path}/index.html').writeAsStringSync(realIndex);
      },
    );
    return File('$output/index.html').readAsStringSync();
  }

  test(
    'stock invocation is byte-compatible and creates no product globals',
    () async {
      final output = '${temp.path}/stock-web';
      await buildProductWeb(
        outputPath: output,
        builder: (path) async => _fixtureShell(Directory(path)),
      );
      expect(File('$output/product_config.js').existsSync(), isFalse);
      expect(File('$output/product_config.json').existsSync(), isFalse);
      expect(
        File('$output/flutter_service_worker.js').readAsStringSync(),
        contains("cacheName = 'flutter-app'"),
      );
      expect(
        File('$output/index.html').readAsStringSync(),
        contains('<title>Fa</title>'),
      );
    },
  );

  test(
    'stock --assets without a profile is rejected before building',
    () async {
      var called = false;
      await expectLater(
        buildProductWeb(
          assetsPath: assets.path,
          builder: (path) async => called = true,
        ),
        throwsFormatException,
      );
      expect(called, isFalse);
    },
  );

  test(
    'stock --base-href without a profile is rejected before building',
    () async {
      var called = false;
      await expectLater(
        buildProductWeb(
          outputPath: '${temp.path}/stock-base-href',
          baseHref: '/agent/',
          builder: (path) async => called = true,
        ),
        throwsFormatException,
      );
      expect(called, isFalse);
    },
  );

  test(
    'branded build validates and atomically stages the complete static shell',
    () async {
      final output = '${temp.path}/branded-web';
      await buildProductWeb(
        profilePath: profile.path,
        assetsPath: assets.path,
        outputPath: output,
        builder: (path) async => _fixtureShell(Directory(path)),
      );
      final html = File('$output/index.html').readAsStringSync();
      expect(html, contains('<title>Host &amp; Workspace</title>'));
      expect(html, contains('content="Host &amp; Workspace"'));
      expect(html, contains('src="splash.png"'));
      expect(
        html.indexOf('product_config.js'),
        lessThan(html.indexOf('fs_store.js')),
      );
      final manifest =
          jsonDecode(File('$output/manifest.json').readAsStringSync())
              as Map<String, Object?>;
      expect(manifest['name'], 'Host & Workspace');
      expect(manifest['short_name'], 'Host & Workspace');
      final productJs = File('$output/product_config.js').readAsStringSync();
      expect(productJs, contains('window.__faProductStorageNamespace'));
      expect(productJs, contains('fa-product:host-product:schema:1'));
      expect(
        File('$output/flutter_service_worker.js').readAsStringSync(),
        contains('fa-product:host-product:schema:1:web-app'),
      );
      expect(
        File('$output/flutter_service_worker.js').readAsStringSync(),
        contains('key.startsWith("fa-product:host-product:")'),
      );
      for (final path in [
        'icons/Icon-192.png',
        'icons/Icon-512.png',
        'icons/Icon-maskable-192.png',
        'icons/Icon-maskable-512.png',
        'favicon.png',
        'splash.png',
        'product_config.json',
      ]) {
        expect(File('$output/$path').existsSync(), isTrue, reason: path);
      }
    },
  );

  test('staged profile publishes only safe runtime brand asset URLs', () async {
    final output = '${temp.path}/runtime-brand-assets';
    await buildFromRealIndex(output);
    final script = File('$output/product_config.js').readAsStringSync();
    final encoded = RegExp(
      r'window.__faProductProfile = (.*);',
    ).firstMatch(script)!.group(1)!;
    final runtime = FaProductConfig.fromJson(
      (jsonDecode(encoded) as Map).cast<String, Object?>(),
    );

    expect(runtime.brandAssets['icon192'], 'icons/Icon-192.png');
    expect(runtime.brandAssets['icon512'], 'icons/Icon-512.png');
    expect(runtime.brandAssets['favicon'], 'favicon.png');
    expect(runtime.brandAssets['splash'], 'splash.png');
    for (final path in runtime.brandAssets.values) {
      expect(File('$output/$path').existsSync(), isTrue, reason: path);
    }
    expect(File('$output/icon-192.png').existsSync(), isFalse);
  });

  test('real stock index leaves exactly one visible branded splash', () async {
    final output = '${temp.path}/real-index-splash';
    final html = await buildFromRealIndex(output);
    final splashElements = RegExp(
      r'<(?:img|div)\b[^>]*\bid="(?:fah-splash|fa-product-splash)"[^>]*>',
    ).allMatches(html).toList();

    expect(splashElements, hasLength(1));
    expect(splashElements.single.group(0), contains('id="fa-product-splash"'));
    expect(splashElements.single.group(0), contains('src="splash.png"'));
    expect(html, isNot(contains('Loading flutter_agent_harness')));
    expect(html, isNot(contains('<div class="fah-name">Fa</div>')));
  });

  test('real stock index uses the branded asset as its primary icon', () async {
    final output = '${temp.path}/real-index-icon';
    final html = await buildFromRealIndex(output);
    final primaryIcon = RegExp(
      r'<link\b(?=[^>]*\brel="icon")[^>]*>',
    ).firstMatch(html);

    expect(primaryIcon, isNotNull);
    expect(primaryIcon!.group(0), contains('type="image/png"'));
    expect(primaryIcon.group(0), contains('href="favicon.png"'));
    expect(primaryIcon.group(0), isNot(contains('favicon.svg')));
  });

  test('branded build applies a validated subpath base href', () async {
    final output = '${temp.path}/real-index-base-href';
    final html = await buildFromRealIndex(output, baseHref: '/agent/');

    expect(html, contains('<base href="/agent/">'));
    expect(html, isNot(contains(r'$FLUTTER_BASE_HREF')));
  });

  test('invalid base href fails before Flutter or an output app', () async {
    var called = false;
    final output = '${temp.path}/invalid-base-href';
    await expectLater(
      buildProductWeb(
        profilePath: profile.path,
        assetsPath: assets.path,
        outputPath: output,
        baseHref: 'https://evil.example/',
        builder: (path) async => called = true,
      ),
      throwsFormatException,
    );
    expect(called, isFalse);
    expect(Directory(output).existsSync(), isFalse);
  });

  test('validate-only performs no build and writes no app', () async {
    final output = '${temp.path}/not-created';
    var called = false;
    await buildProductWeb(
      profilePath: profile.path,
      assetsPath: assets.path,
      outputPath: output,
      validateOnly: true,
      builder: (path) async => called = true,
    );
    expect(called, isFalse);
    expect(Directory(output).existsSync(), isFalse);
  });

  test('wrong icon dimensions fail BEFORE Flutter or an output app', () async {
    File('${assets.path}/icon-192.png').writeAsBytesSync(_png(191));
    var called = false;
    final output = '${temp.path}/bad-web';
    await expectLater(
      buildProductWeb(
        profilePath: profile.path,
        assetsPath: assets.path,
        outputPath: output,
        builder: (path) async {
          called = true;
          _fixtureShell(Directory(path));
        },
      ),
      throwsFormatException,
    );
    expect(called, isFalse);
    expect(Directory(output).existsSync(), isFalse);
  });

  test('missing required splash fails before build', () async {
    File('${assets.path}/splash.png').deleteSync();
    var called = false;
    await expectLater(
      buildProductWeb(
        profilePath: profile.path,
        assetsPath: assets.path,
        builder: (path) async => called = true,
      ),
      throwsFormatException,
    );
    expect(called, isFalse);
  });

  test('credential-shaped profile fields never reach a build', () async {
    final json = _profile()..['oauthClientSecret'] = 'do-not-emit';
    profile.writeAsStringSync(jsonEncode(json));
    var called = false;
    await expectLater(
      buildProductWeb(
        profilePath: profile.path,
        assetsPath: assets.path,
        builder: (path) async => called = true,
      ),
      throwsFormatException,
    );
    expect(called, isFalse);
  });

  test(
    'a failed Flutter build preserves the previously published shell',
    () async {
      final output = Directory('${temp.path}/existing-web')..createSync();
      File('${output.path}/sentinel.txt').writeAsStringSync('known-good');
      await expectLater(
        buildProductWeb(
          profilePath: profile.path,
          assetsPath: assets.path,
          outputPath: output.path,
          builder: (path) async => throw const ProcessException('flutter', []),
        ),
        throwsA(isA<ProcessException>()),
      );
      expect(
        File('${output.path}/sentinel.txt').readAsStringSync(),
        'known-good',
      );
      expect(File('${output.path}/product_config.js').existsSync(), isFalse);
    },
  );

  test(
    'an injected final-rename failure restores the last good build',
    () async {
      final output = Directory('${temp.path}/existing-web')..createSync();
      File('${output.path}/sentinel.txt').writeAsStringSync('known-good');
      Directory? staging;

      await expectLater(
        buildProductWeb(
          profilePath: profile.path,
          assetsPath: assets.path,
          outputPath: output.path,
          builder: (path) async {
            staging = Directory(path);
            _fixtureShell(Directory(path));
          },
          finalRename: (directory, outputPath) {
            throw FileSystemException('injected final rename', outputPath);
          },
        ),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            'injected final rename',
          ),
        ),
      );

      expect(
        File('${output.path}/sentinel.txt').readAsStringSync(),
        'known-good',
      );
      expect(File('${output.path}/product_config.js').existsSync(), isFalse);
      expect(staging, isNotNull);
      expect(staging!.existsSync(), isFalse);
      expect(
        output.parent.listSync().where(
          (entry) => entry.path.startsWith('${output.path}.backup-'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'an unrecognized cache seam fails instead of shipping shared caches',
    () async {
      final output = '${temp.path}/bad-cache';
      await expectLater(
        buildProductWeb(
          profilePath: profile.path,
          assetsPath: assets.path,
          outputPath: output,
          builder: (path) async {
            final dir = _fixtureShell(Directory(path));
            File(
              '${dir.path}/flutter_service_worker.js',
            ).writeAsStringSync('const renamedCache = "unrecognized";');
          },
        ),
        throwsFormatException,
      );
      expect(Directory(output).existsSync(), isFalse);
    },
  );
}

Map<String, Object?> _profile() => {
  'productId': 'host-product',
  'displayName': 'Host & Workspace',
  'description': 'A host-owned & private workspace',
  'themePackId': 'host-theme',
  'themePack': {
    'name': 'Host Theme',
    'version': '1.0.0',
    'colors': {
      'dark': {'accent': '#2E7D32'},
    },
  },
  'authEndpoint': 'https://auth.example/authorize',
  'apiEndpoint': 'https://api.example/v1',
  'driveEndpoint': 'https://drive.example/v1',
  'sessionEndpoint': 'https://sessions.example/v1',
  'oauthCallback': 'https://app.example/oauth/callback',
  'legalLinks': {'privacy': 'https://legal.example/privacy'},
  'featureFlags': ['cloudSync'],
  'brandAssets': {
    'icon192': 'icon-192.png',
    'icon512': 'icon-512.png',
    'favicon': 'favicon.png',
    'splash': 'splash.png',
  },
};

void _writeAssets(Directory root) {
  File('${root.path}/icon-192.png').writeAsBytesSync(_png(192));
  File('${root.path}/icon-512.png').writeAsBytesSync(_png(512));
  File('${root.path}/favicon.png').writeAsBytesSync(_png(64));
  File('${root.path}/splash.png').writeAsBytesSync(_png(128));
}

List<int> _png(int size) {
  final bytes = List<int>.filled(45, 0);
  bytes.setRange(0, 8, [137, 80, 78, 71, 13, 10, 26, 10]);
  bytes.setRange(8, 12, [0, 0, 0, 13]);
  bytes.setRange(12, 16, ascii.encode('IHDR'));
  bytes.setRange(16, 20, [size >> 24, size >> 16, size >> 8, size & 255]);
  bytes.setRange(20, 24, [size >> 24, size >> 16, size >> 8, size & 255]);
  bytes[24] = 8;
  bytes[25] = 6;
  bytes.setRange(37, 41, ascii.encode('IEND'));
  return bytes;
}

Directory _fixtureShell(Directory directory) {
  directory.createSync(recursive: true);
  Directory('${directory.path}/icons').createSync();
  File('${directory.path}/index.html').writeAsStringSync('''<!DOCTYPE html>
<html><head>
<meta name="description" content="Stock Fa">
<meta name="apple-mobile-web-app-title" content="Fa">
<title>Fa</title>
</head><body>
<script src="fs_store.js"></script>
<script src="flutter_bootstrap.js" async></script>
</body></html>''');
  File('${directory.path}/manifest.json').writeAsStringSync('{"name":"Fa"}');
  File('${directory.path}/flutter_service_worker.js').writeAsStringSync(
    "var cacheName = 'flutter-app';\n"
    "self.addEventListener('activate', function() {\n"
    "  caches.keys().then(function(keys) { keys.forEach(function(key) {\n"
    "    if (key !== cacheName) { return caches.delete(key); }\n"
    "  }); });\n"
    "});\n",
  );
  return directory;
}
