// Issue #291 — Chrome Web Store rejects fa-extension.zip with
// "More than one manifest found in package: manifest.json,
// panel/app/manifest.json": the Flutter web build staged under
// browser_ext/panel/app ships its own PWA manifest. The fix strips it
// from the STAGED copy and asserts the packaged zip's shape — the CWS
// rules as our own test, so a nested manifest fails the BUILD instead of
// the next store upload.
//
// This file unit-tests scripts/ext_package_guard.py (both verbs) against
// small fixture packages built with package:archive — no Chrome, no
// flutter build, so it runs in the default test gate (unlike the rest of
// test/browser_ext/, which is integration+browser-ext tagged).
// python3 missing → clean skip (the build script itself requires python3,
// same probe pattern as test/js_ext/bundled_crap_guard_node_test.dart).
//
// A duplicate-entry-name fixture cannot be built here: Archive.addFile
// dedupes by name (verified) — the checker still guards against it, zip
// tooling that appends can produce duplicates.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

/// The guard script under test (repo-root relative).
const guardScript = 'scripts/ext_package_guard.py';

/// Minimal valid MV3 root manifest — same shape as
/// browser_ext/manifest.json (icons + action.default_icon referenced).
const validRootManifest = '''
{
  "manifest_version": 3,
  "name": "fixture",
  "version": "0.0.0",
  "icons": {
    "16": "icons/icon-16.png",
    "128": "icons/icon-128.png"
  },
  "action": {
    "default_icon": "icons/icon-16.png"
  }
}
''';

/// Flutter's web template index.html — the PWA link the strip removes
/// (flutter_app/web/index.html shape, #291).
const flutterIndexHtml = '''
<!DOCTYPE html>
<html>
<head>
  <base href="/panel/app/">
  <meta charset="UTF-8">
  <link rel="manifest" href="manifest.json">
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
''';

void main() {
  // python3 probe — skip the whole file cleanly when absent (the guard
  // script is python; a machine without python3 never ships the zip).
  try {
    final probe = Process.runSync('python3', ['--version']);
    if (probe.exitCode != 0) throw StateError('python3 unusable');
  } on Object {
    test('python3 not on PATH — ext_package_guard suite skips', () {
      print('skip: python3 not on PATH');
    }, skip: 'python3 not on PATH');
    return;
  }

  final repoRoot = _repoRoot();
  final tmp = Directory.systemTemp.createTempSync('fa-ext-guard-test-');

  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort — never fail a test run on cleanup.
    }
  });

  ProcessResult runGuard(List<String> args) => Process.runSync('python3', [
    guardScript,
    ...args,
  ], workingDirectory: repoRoot);

  File writeZip(String name, Map<String, List<int>> entries) {
    final archive = Archive();
    entries.forEach(archive.addFileBytes);
    final file = File('${tmp.path}/$name');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(ZipEncoder().encode(archive));
    return file;
  }

  /// The valid fixture package: root MV3 manifest + referenced icons +
  /// runtime dirs incl. the staged panel app (post-strip: no nested
  /// manifest, no manifest link in its index.html).
  Map<String, List<int>> validPackage() => {
    'manifest.json': utf8.encode(validRootManifest),
    'icons/icon-16.png': utf8.encode('png16'),
    'icons/icon-128.png': utf8.encode('png128'),
    'sw/main.js': utf8.encode('// sw'),
    'panel/panel.html': utf8.encode('<html>panel</html>'),
    'panel/app/index.html': utf8.encode(flutterIndexHtml),
    'panel/app/main.dart.js': utf8.encode('// app'),
  };

  group('check (CWS shape on the packaged zip)', () {
    test('valid single-manifest package passes (AC1 GREEN shape)', () {
      final zip = writeZip('valid.zip', validPackage());
      final res = runGuard(['check', zip.path]);
      expect(
        res.exitCode,
        0,
        reason: 'stdout: ${res.stdout}\nstderr: ${res.stderr}',
      );
    });

    test(
      'nested panel/app/manifest.json fails naming BOTH manifests (AC1)',
      () {
        final zip = writeZip('two-manifests.zip', {
          ...validPackage(),
          'panel/app/manifest.json': utf8.encode('{"name": "Fa PWA"}'),
        });
        final res = runGuard(['check', zip.path]);
        expect(res.exitCode, isNot(0));
        final err = '${res.stdout}${res.stderr}';
        // The failure must name EVERY manifest so the offender is obvious
        // from the log alone (the exact CWS rejection shape).
        expect(err, contains('panel/app/manifest.json'));
        expect(err, contains('manifest.json'));
        expect(err, contains('2'));
      },
    );

    test('manifest not at the root fails (E2 — no silent allowlist)', () {
      final zip = writeZip('nested-only.zip', {
        ...validPackage()..remove('manifest.json'),
        'panel/app/manifest.json': utf8.encode('{}'),
      });
      final res = runGuard(['check', zip.path]);
      expect(res.exitCode, isNot(0));
      expect('${res.stdout}${res.stderr}', contains('panel/app/manifest.json'));
    });

    test('.DS_Store and __MACOSX junk entries fail (bonus hygiene)', () {
      final zip = writeZip('junk.zip', {
        ...validPackage(),
        'panel/app/.DS_Store': utf8.encode('junk'),
      });
      final res = runGuard(['check', zip.path]);
      expect(res.exitCode, isNot(0));
      expect('${res.stdout}${res.stderr}', contains('.DS_Store'));
    });

    test('empty directory entry fails (bonus hygiene)', () {
      final zip = writeZip('empty-dir.zip', {
        ...validPackage(),
        'panel/app/empty/': utf8.encode(''),
      });
      final res = runGuard(['check', zip.path]);
      expect(res.exitCode, isNot(0));
      expect('${res.stdout}${res.stderr}', contains('panel/app/empty/'));
    });

    test('icon referenced by the root manifest missing from zip fails', () {
      final zip = writeZip(
        'missing-icon.zip',
        {...validPackage()}..remove('icons/icon-128.png'),
      );
      final res = runGuard(['check', zip.path]);
      expect(res.exitCode, isNot(0));
      expect('${res.stdout}${res.stderr}', contains('icons/icon-128.png'));
    });

    test('non-MV3 root manifest fails (AC4 — CWS shape, MV3 parse)', () {
      final mv2 = validRootManifest.replaceFirst(
        '"manifest_version": 3',
        '"manifest_version": 2',
      );
      final zip = writeZip('mv2.zip', {
        ...validPackage(),
        'manifest.json': utf8.encode(mv2),
      });
      final res = runGuard(['check', zip.path]);
      expect(res.exitCode, isNot(0));
      expect('${res.stdout}${res.stderr}', contains('manifest_version'));
    });

    test('missing zip file fails loudly (bad invocation)', () {
      final res = runGuard(['check', '${tmp.path}/nope.zip']);
      expect(res.exitCode, isNot(0));
    });
  });

  group('strip (staged panel app — sources untouched)', () {
    Directory stagedFixture({String? indexHtml}) {
      final dir = Directory('${tmp.path}/staged-${_n++}')
        ..createSync(recursive: true);
      File(
        '${dir.path}/index.html',
      ).writeAsStringSync(indexHtml ?? flutterIndexHtml);
      File(
        '${dir.path}/manifest.json',
      ).writeAsStringSync('{"name": "Fa PWA", "icons": []}');
      File('${dir.path}/main.dart.js').writeAsStringSync('// app');
      return dir;
    }

    test('removes the PWA manifest and the link tag, keeps the rest', () {
      final dir = stagedFixture();
      final res = runGuard(['strip', dir.path]);
      expect(res.exitCode, 0, reason: 'stderr: ${res.stderr}');
      expect(
        File('${dir.path}/manifest.json').existsSync(),
        isFalse,
        reason: 'the nested PWA manifest must be deleted',
      );
      final html = File('${dir.path}/index.html').readAsStringSync();
      expect(
        html,
        isNot(contains('rel="manifest"')),
        reason: 'the <link rel="manifest"> tag must be dropped',
      );
      expect(
        html,
        contains('rel="stylesheet"'),
        reason: 'other link tags survive',
      );
      expect(
        html,
        contains('flutter_bootstrap.js'),
        reason: 'the rest of index.html survives',
      );
      expect(File('${dir.path}/main.dart.js').existsSync(), isTrue);
    });

    test('handles the reversed attribute order too', () {
      final dir = stagedFixture(
        indexHtml: flutterIndexHtml.replaceFirst(
          '<link rel="manifest" href="manifest.json">',
          '<link href="manifest.json" rel="manifest">',
        ),
      );
      final res = runGuard(['strip', dir.path]);
      expect(res.exitCode, 0, reason: 'stderr: ${res.stderr}');
      expect(
        File('${dir.path}/index.html').readAsStringSync(),
        isNot(contains('rel="manifest"')),
      );
    });

    test('idempotent: a second run is a no-op, not a failure (E3)', () {
      final dir = stagedFixture();
      runGuard(['strip', dir.path]);
      final htmlAfterFirst = File('${dir.path}/index.html').readAsStringSync();
      final res = runGuard(['strip', dir.path]);
      expect(res.exitCode, 0, reason: 'stderr: ${res.stderr}');
      expect(File('${dir.path}/index.html').readAsStringSync(), htmlAfterFirst);
    });

    test('index.html without the link tag (template change) → no-op (E3)', () {
      final dir = stagedFixture(
        indexHtml: '<!DOCTYPE html><html><head></head><body>app</body></html>',
      );
      final res = runGuard(['strip', dir.path]);
      expect(res.exitCode, 0, reason: 'stderr: ${res.stderr}');
      expect(File('${dir.path}/manifest.json').existsSync(), isFalse);
    });

    test('missing index.html in the staged dir fails loudly', () {
      final dir = Directory('${tmp.path}/staged-broken-${_n++}')
        ..createSync(recursive: true);
      final res = runGuard(['strip', dir.path]);
      expect(res.exitCode, isNot(0));
      expect('${res.stdout}${res.stderr}', contains('index.html'));
    });
  });

  test('end-to-end fixture: strip then check is green (AC1 GREEN)', () {
    final staged = Directory('${tmp.path}/staged-e2e')
      ..createSync(recursive: true);
    File('${staged.path}/index.html').writeAsStringSync(flutterIndexHtml);
    File('${staged.path}/manifest.json').writeAsStringSync('{"name": "Fa"}');
    File('${staged.path}/main.dart.js').writeAsStringSync('// app');

    final strip = runGuard(['strip', staged.path]);
    expect(strip.exitCode, 0, reason: 'stderr: ${strip.stderr}');

    // Zip the stripped staged tree alongside the valid root manifest.
    final package = validPackage()
      ..['panel/app/index.html'] = File(
        '${staged.path}/index.html',
      ).readAsBytesSync();
    final zip = writeZip('e2e.zip', package);
    final check = runGuard(['check', zip.path]);
    expect(
      check.exitCode,
      0,
      reason: 'stdout: ${check.stdout}\nstderr: ${check.stderr}',
    );
  });
}

var _n = 0;

extension on Archive {
  void addFileBytes(String name, List<int> data) =>
      addFile(ArchiveFile.bytes(name, data));
}

/// The repo root (dart test runs with the package root as CWD): the
/// nearest ancestor owning pubspec.yaml + scripts/.
String _repoRoot() {
  var dir = Directory.current.resolveSymbolicLinksSync();
  for (var i = 0; i < 6; i++) {
    if (File('$dir/pubspec.yaml').existsSync() &&
        Directory('$dir/scripts').existsSync()) {
      return dir;
    }
    dir = '$dir/..';
  }
  throw StateError(
    'repo root (pubspec.yaml + scripts/) not found above '
    '${Directory.current.path}',
  );
}
