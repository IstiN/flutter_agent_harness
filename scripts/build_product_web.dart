import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Builds stock Fa, or a branded static web shell from a host-owned profile.
///
/// Product files never enter the harness source tree. Branded builds validate
/// every profile/asset before Flutter runs and publish atomically only after
/// the shell, manifest, splash and storage namespaces are fully staged.
Future<void> main(List<String> args) async {
  String? value(String name) {
    final index = args.indexOf(name);
    if (index < 0) return null;
    if (index + 1 >= args.length) {
      throw FormatException('$name requires a value');
    }
    return args[index + 1];
  }

  final validateOnly = args.contains('--validate-only');
  await buildProductWeb(
    profilePath: value('--profile'),
    assetsPath: value('--assets'),
    outputPath: value('--output') ?? 'flutter_app/build/web',
    validateOnly: validateOnly,
  );
}

typedef FlutterWebBuild = Future<void> Function(String outputPath);
typedef FinalRename = Directory Function(Directory staging, String outputPath);

Future<void> buildProductWeb({
  String? profilePath,
  String? assetsPath,
  String outputPath = 'flutter_app/build/web',
  bool validateOnly = false,
  FlutterWebBuild? builder,
  FinalRename? finalRename,
}) async {
  final build = builder ?? _flutterBuild;
  if (profilePath == null) {
    if (assetsPath != null) {
      throw const FormatException('--assets requires --profile');
    }
    if (!validateOnly) await build(outputPath);
    return;
  }
  if (assetsPath == null) {
    throw const FormatException('--assets is required for a branded build');
  }
  final config = await loadExternalProductConfig(profilePath);
  final assets = await validateProductAssets(config, assetsPath);
  if (validateOnly) {
    stdout.writeln('valid product profile: ${config.productId}');
    return;
  }

  final output = Directory(outputPath).absolute;
  output.parent.createSync(recursive: true);
  final publicationId = DateTime.now().microsecondsSinceEpoch;
  final staging = Directory('${output.path}.staging-$publicationId');
  final backup = Directory('${output.path}.backup-$publicationId');
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  try {
    await build(staging.path);
    stageBrandedShell(
      stagingPath: staging.path,
      config: config,
      assets: assets,
    );
    final hadOutput = output.existsSync();
    if (hadOutput) output.renameSync(backup.path);
    try {
      if (finalRename == null) {
        staging.renameSync(output.path);
      } else {
        finalRename(staging, output.path);
      }
    } catch (_) {
      // A failed rename can leave a partial destination. Never sacrifice the
      // sibling last-good build while removing it or restoring the backup.
      if (output.existsSync()) output.deleteSync(recursive: true);
      if (hadOutput && backup.existsSync()) backup.renameSync(output.path);
      rethrow;
    }
    // Keep the last-good sibling until the complete staged shell is published.
    if (hadOutput && backup.existsSync()) {
      backup.deleteSync(recursive: true);
    }
  } finally {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  }
}

Future<FaProductConfig> loadExternalProductConfig(String path) async {
  final file = File(path);
  if (!file.existsSync()) throw FormatException('profile not found: $path');
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('product profile must be a JSON object');
  }
  return FaProductConfig.fromJson(decoded);
}

final class ValidatedProductAssets {
  const ValidatedProductAssets(this.root, this.files);

  final Directory root;
  final Map<String, File> files;

  File required(String slot) {
    final file = files[slot];
    if (file == null) throw FormatException('missing brand asset: $slot');
    return file;
  }
}

Future<ValidatedProductAssets> validateProductAssets(
  FaProductConfig config,
  String assetsPath,
) async {
  final root = Directory(assetsPath).absolute;
  if (!root.existsSync()) throw FormatException('asset directory not found');
  final files = <String, File>{};
  for (final entry in config.brandAssets.entries) {
    final file = File('${root.path}/${entry.value}').absolute;
    if (!_inside(root, file) || !file.existsSync()) {
      throw FormatException('brand asset missing: ${entry.key}');
    }
    final length = await file.length();
    if (length == 0) throw FormatException('empty asset: ${entry.key}');
    if (entry.key != 'favicon') {
      final expected = switch (entry.key) {
        'icon192' || 'maskable192' => 192,
        'icon512' || 'maskable512' => 512,
        _ => null,
      };
      await _validatePng(file, entry.key, expected);
    }
    files[entry.key] = file;
  }
  // These slots make a branded shell complete; maskable icons fall back to
  // the regular artwork when the host does not supply separate versions.
  for (final slot in ['icon192', 'icon512', 'favicon', 'splash']) {
    if (!files.containsKey(slot)) {
      throw FormatException('required brand asset slot: $slot');
    }
  }
  return ValidatedProductAssets(root, files);
}

bool _inside(Directory root, File file) {
  final rootPath = root.resolveSymbolicLinksSync();
  final parent = file.parent.resolveSymbolicLinksSync();
  return parent == rootPath || parent.startsWith('$rootPath/');
}

Future<void> _validatePng(File file, String slot, int? expectedSize) async {
  final bytes = await file.readAsBytes();
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 45) throw FormatException('invalid PNG: $slot');
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) {
      throw FormatException('invalid PNG signature: $slot');
    }
  }
  // IHDR dimensions + an IEND trailer. This deliberately does not decode or
  // trust SVG/HTML as trusted application markup.
  final width = _uint32(bytes, 16);
  final height = _uint32(bytes, 20);
  if (width < 1 || height < 1 || width != height) {
    throw FormatException('brand PNG must be square: $slot');
  }
  if (expectedSize != null && width != expectedSize) {
    throw FormatException('$slot must be ${expectedSize}x$expectedSize');
  }
  if (ascii.decode(bytes.sublist(bytes.length - 8, bytes.length - 4)) !=
      'IEND') {
    throw FormatException('truncated PNG: $slot');
  }
}

int _uint32(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

/// Fully stages a built shell. Exported for deterministic script tests; no
/// Flutter invocation or live backend is needed to verify the transformation.
void stageBrandedShell({
  required String stagingPath,
  required FaProductConfig config,
  required ValidatedProductAssets assets,
}) {
  if (config.isStock) {
    throw ArgumentError('stock Fa must use the unmodified build path');
  }
  final root = Directory(stagingPath);
  final namespace = config.storageNamespace(config.storageSchemaVersion)!;
  final index = File('${root.path}/index.html');
  var html = index.readAsStringSync();
  html = html.replaceFirst(
    RegExp(r'<title>.*?</title>', dotAll: true),
    '<title>${_html(config.displayName)}</title>',
  );
  html = html.replaceFirst(
    RegExp(r'<meta name="description" content="[^"]*">'),
    '<meta name="description" content="${_html(config.description)}">',
  );
  html = html.replaceFirst(
    RegExp(r'<meta name="apple-mobile-web-app-title" content="[^"]*">'),
    '<meta name="apple-mobile-web-app-title" content="${_html(config.displayName)}">',
  );
  const productScript = '<script src="product_config.js"></script>';
  if (!html.contains(productScript)) {
    if (!html.contains('<script src="fs_store.js"></script>')) {
      throw const FormatException('stock fs_store bootstrap marker missing');
    }
    html = html.replaceFirst(
      '<script src="fs_store.js"></script>',
      '$productScript\n  <script src="fs_store.js"></script>',
    );
  }
  const splashMarker = '<img id="fa-product-splash"';
  const brandedSplash =
      '<img id="fa-product-splash" src="splash.png" alt="" '
      'style="position:fixed;inset:0;margin:auto;max-width:40vmin;z-index:9999;pointer-events:none">'
      '\n  <script>window.addEventListener("flutter-first-frame",function(){'
      'var s=document.getElementById("fa-product-splash");if(s)s.remove();});</script>';
  // Match the outer closing div by indentation so nested SVG/label elements do
  // not truncate removal and leave stock markup visible above the branded art.
  final stockSplash = RegExp(
    r'^([ \t]*)<div\b(?=[^>]*\bid="fah-splash")[^>]*>.*?^\1</div>[ \t]*(?:\r?\n)?',
    multiLine: true,
    dotAll: true,
  );
  html = html.replaceFirst(stockSplash, '');
  if (html.contains('id="fah-splash"')) {
    throw const FormatException('stock splash could not be removed');
  }
  if (!html.contains(splashMarker)) {
    html = html.replaceFirst('<body>', '<body>\n  $brandedSplash');
  }
  const brandedIcon = '<link rel="icon" type="image/png" href="favicon.png"/>';
  final primaryIcon = RegExp(r'<link\b(?=[^>]*\brel="icon")[^>]*>');
  if (primaryIcon.hasMatch(html)) {
    html = html.replaceFirst(primaryIcon, brandedIcon);
  } else {
    html = html.replaceFirst('</head>', '  $brandedIcon\n</head>');
  }
  index.writeAsStringSync(html);

  final profileScript = jsonEncode(
    _publicProfile(config),
  ).replaceAll('<', '\\u003c').replaceAll('>', '\\u003e');
  File('${root.path}/product_config.js').writeAsStringSync(
    'window.__faProductProfile = $profileScript;\n'
    'window.__faProductStorageNamespace = ${jsonEncode(namespace)};\n',
  );
  File('${root.path}/product_config.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(_publicProfile(config)),
  );
  File('${root.path}/manifest.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(_manifest(config)),
  );
  final iconTargets = {
    'icon192': 'icons/Icon-192.png',
    'icon512': 'icons/Icon-512.png',
    'maskable192': 'icons/Icon-maskable-192.png',
    'maskable512': 'icons/Icon-maskable-512.png',
  };
  for (final entry in iconTargets.entries) {
    final source =
        assets.files[entry.key] ??
        assets.required(entry.key == 'maskable192' ? 'icon192' : 'icon512');
    source.copySync('${root.path}/${entry.value}');
  }
  assets.required('favicon').copySync('${root.path}/favicon.png');
  assets.required('splash').copySync('${root.path}/splash.png');
  _namespaceServiceWorker(root, namespace, 'fa-product:${config.productId}:');
}

Map<String, Object?> _publicProfile(FaProductConfig config) => {
  'productId': config.productId,
  'displayName': config.displayName,
  'description': config.description,
  'themePackId': config.themePackId,
  'themePack': config.themePack,
  'authEndpoint': config.authEndpoint?.toString(),
  'apiEndpoint': config.apiEndpoint?.toString(),
  'driveEndpoint': config.driveEndpoint?.toString(),
  'sessionEndpoint': config.sessionEndpoint?.toString(),
  'oauthCallback': config.oauthCallback?.toString(),
  'legalLinks': {
    for (final entry in config.legalLinks.entries)
      entry.key: entry.value.toString(),
  },
  'featureFlags': config.featureFlags.toList()..sort(),
  'driveAliases': config.driveAliases.toList()..sort(),
  'storageSchemaVersion': config.storageSchemaVersion,
};

Map<String, Object?> _manifest(FaProductConfig config) => {
  'name': config.displayName,
  'short_name': config.displayName,
  'start_url': '.',
  'display': 'standalone',
  'background_color': '#070a10',
  'theme_color': '#070a10',
  'description': config.description,
  'orientation': 'portrait-primary',
  'prefer_related_applications': false,
  'icons': [
    {'src': 'icons/Icon-192.png', 'sizes': '192x192', 'type': 'image/png'},
    {'src': 'icons/Icon-512.png', 'sizes': '512x512', 'type': 'image/png'},
    {
      'src': 'icons/Icon-maskable-192.png',
      'sizes': '192x192',
      'type': 'image/png',
      'purpose': 'maskable',
    },
    {
      'src': 'icons/Icon-maskable-512.png',
      'sizes': '512x512',
      'type': 'image/png',
      'purpose': 'maskable',
    },
  ],
};

void _namespaceServiceWorker(
  Directory root,
  String namespace,
  String productPrefix,
) {
  final file = File('${root.path}/flutter_service_worker.js');
  if (!file.existsSync()) {
    throw const FormatException('Flutter service worker missing');
  }
  var source = file.readAsStringSync();
  // Flutter's current no-op worker unregisters itself and owns no Cache
  // Storage entries. There is no cache namespace to rewrite in that shape.
  if (!source.contains('cacheName') &&
      !source.contains('CACHE_NAME') &&
      !source.contains('caches.delete') &&
      source.contains('registration.unregister')) {
    return;
  }
  final cache = jsonEncode('$namespace:web-app');
  final patterns = [
    RegExp(r"(cacheName\s*=\s*)'flutter-app'"),
    RegExp(r"(CACHE_NAME\s*=\s*)'flutter-app-cache'"),
  ];
  var replacements = 0;
  for (final pattern in patterns) {
    source = source.replaceAllMapped(pattern, (match) {
      replacements++;
      return '${match[1]}$cache';
    });
  }
  if (replacements != 1) {
    throw const FormatException(
      'unrecognized Flutter service-worker cache namespace seam',
    );
  }
  if (source.contains('caches.delete')) {
    final prefix = jsonEncode(productPrefix);
    var guards = 0;
    for (final pattern in [
      RegExp(r'if \(key !== cacheName\)'),
      RegExp(r'if \(key !== CACHE_NAME\)'),
    ]) {
      source = source.replaceAllMapped(pattern, (match) {
        guards++;
        return 'if (key !== ${pattern.pattern.contains('CACHE_NAME') ? 'CACHE_NAME' : 'cacheName'} && key.startsWith($prefix))';
      });
    }
    if (guards != 1) {
      throw const FormatException(
        'service worker could delete another product cache',
      );
    }
  }
  file.writeAsStringSync(source);
}

String _html(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

Future<void> _flutterBuild(String outputPath) async {
  final result = await Process.run('flutter', [
    'build',
    'web',
    '--output',
    outputPath,
  ], workingDirectory: 'flutter_app');
  if (result.exitCode != 0) {
    throw ProcessException(
      'flutter build web',
      [outputPath],
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
}
