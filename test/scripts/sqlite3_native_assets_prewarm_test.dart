// gh-2072 — the v1.0.697 tag run red'd four CI legs (Terminal visual,
// Flutter app tests shards 0/2+1/2, Build Android APK) on ONE shared
// flake: the `sqlite3` package's native-assets build hook downloads its
// prebuilt `libsqlite3.<abi>.<os>` from GitHub releases at build time in
// a SINGLE attempt with NO HTTP status check. During the 05:25 window the
// runner egress answered `504 Gateway Time-out` (a 92-byte HTML error
// page); the hook piped that page into the output file, its own sha256
// check threw `Bad state: Hash of downloaded file … is bef140a1… expected
// …` and native-assets building died before a single test ran. The same
// sha (9550c02) was fully green on the SM validation run hours earlier —
// pure network roulette, zero code faults.
//
// The cure follows the gh-1655/gh-1757 pre-install pattern: fetch the
// pinned prebuilt binaries OUTSIDE the unretryable hook path, into the
// hook's own reuse cache, with bounded retry + status checking + sha256
// verification. This suite proves the prewarm script's contract
// deterministically against a local HTTP fixture (no external network):
//   AC1  happy path downloads into the hook's exact cache path
//        (<root>/.dart_tool/hooks_runner/shared/sqlite3/build/
//        download-<hash8-prefix-of-pinned-hash>/<libsqlite3.so>) with the
//        exact bytes the pinned hash describes,
//   AC2  a second run reuses the cache and performs ZERO fetches
//        (idempotence — the hook's own reuse contract),
//   AC3  THE BUG: a 504 (error page) followed by a 200 ends with the
//        correct cached bytes and exit 0 — the transient failure the
//        hook reds on becomes a bounded retry,
//   AC4  all-504 exits non-zero, caches nothing, and names the status,
//   AC5  a 200 with hash-mismatched bytes is rejected (never cached) —
//        protects against any status-blind acceptance regression,
//   AC6  a corrupted cache entry (the exact bef140a1 error-page bytes) is
//        repaired, not trusted,
//   AC7  a package graph without sqlite3 is a clean no-op (exit 0),
//   AC8  unknown target names fail loudly (validated against the parsed
//        pinned-hash map),
//   AC9  target expansion: `android` → the three APK ABIs; `auto` → the
//        host target; explicit names pass through,
//   AC10 the pinned-asset parser reads the REAL upstream asset_hashes.dart
//        format (releaseTag + filename→sha256 map) — named skip when no
//        sqlite3 checkout is resolvable (env-dependent, gh-1655 AC5
//        posture),
//   AC11 pure SHA-256 matches the FIPS vectors (the script must not
//        trust-download without an independent digest check),
//   AC12 a hung connection (accepted, never answered) is bounded by the
//        per-attempt request timeout — the retry budget engages instead
//        of the step parking until the leg wall-clock timeout (gh-2072
//        review thread 9).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../scripts/sqlite3_native_assets_prewarm.dart' as prewarm;

const scriptPath = 'scripts/sqlite3_native_assets_prewarm.dart';

/// The exact bytes the CI runners were served instead of the sqlite3
/// binaries — a 92-byte HTML error page whose sha256 is the `bef140a1…`
/// hash from all four red legs' logs.
const fiftyFourErrorPage =
    '<html><body><h1>504 Gateway Time-out</h1>\n'
    'The server didn\'t respond in time.\n'
    '</body></html>\n';

final errorPageBytes = utf8.encode(fiftyFourErrorPage);

String sha(String label, List<int> bytes) => prewarm.sha256Hex(bytes);

Future<Directory> fixturePackage(
  Directory sandbox, {
  required Map<String, String> assetHashes,
  String? releaseTag = 'sqlite3-3.7.0',
  bool withSqlite3 = true,
}) async {
  final pkg = Directory('${sandbox.path}/pkg')..createSync(recursive: true);
  final dartTool = Directory('${pkg.path}/.dart_tool')..createSync();
  if (withSqlite3) {
    final sqliteRoot = Directory('${sandbox.path}/fake-sqlite3')
      ..createSync(recursive: true);
    Directory('${sqliteRoot.path}/lib/src/hook').createSync(recursive: true);
    final buf = StringBuffer()
      ..writeln('// This file contains hashes of SQLite binaries downloaded')
      ..writeln('// by the default hook. (fixture)')
      ..writeln('// dart format off')
      ..writeln(
        "const String? releaseTag = ${releaseTag == null ? 'null' : "'$releaseTag'"};",
      )
      ..writeln('')
      ..writeln('const Map<String, String> assetNameToSha256Hash = {');
    assetHashes.forEach((k, v) => buf.writeln("  '$k': '$v',"));
    buf.writeln('};');
    File(
      '${sqliteRoot.path}/lib/src/hook/asset_hashes.dart',
    ).writeAsStringSync(buf.toString());
    final rootUri = sqliteRoot.uri.toString();
    File('${dartTool.path}/package_config.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'sqlite3',
            'rootUri': rootUri.startsWith('file://')
                ? rootUri
                : 'file://$rootUri',
            'packageUri': 'lib/',
            'languageVersion': '3.0',
          },
        ],
      }),
    );
  } else {
    File('${dartTool.path}/package_config.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'some_other_pkg',
            'rootUri': '../other/',
            'packageUri': 'lib/',
          },
        ],
      }),
    );
  }
  return pkg;
}

/// Runs the script as a real subprocess — proves the CLI contract, not
/// just the library surface. The script is copied OUT of the repo into a
/// packageless temp dir and invoked via plain `dart <path>`: `dart run`
/// would first build the ROOT package's own native-assets hooks (the
/// sqlite3 download we exist to defend against) before main() ran, so
/// both the action and this suite must use the packageless invocation.
Future<ProcessResult> runScript(List<String> args) async {
  final copied = File(
    '${(await Directory.systemTemp.createTemp('fah-sqlite3-prewarm-run-')).path}/'
    'sqlite3_native_assets_prewarm.dart',
  );
  copied.writeAsBytesSync(File(scriptPath).readAsBytesSync());
  return Process.run(
    Platform.resolvedExecutable,
    [copied.path, ...args],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
}

class FixtureServer {
  final HttpServer server;
  final requests = <String>[];
  final Future<void> Function(HttpRequest, FixtureServer) handle;

  FixtureServer._(this.server, this.handle) {
    server.listen((req) async {
      requests.add(req.uri.path);
      await handle(req, this);
      await req.response.close();
    });
  }

  static Future<FixtureServer> start(
    Future<void> Function(HttpRequest, FixtureServer) handle,
  ) async => FixtureServer._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    handle,
  );

  /// Serves `bytes` with 200 for [path].
  static Future<void> serveBytes(
    HttpRequest req,
    List<int> bytes, {
    int status = 200,
  }) async {
    req.response.statusCode = status;
    req.response.add(bytes);
  }

  String get url => 'http://127.0.0.1:${server.port}';
}

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('fah-sqlite3-prewarm-');
  });

  tearDown(() async {
    try {
      await sandbox.delete(recursive: true);
    } on FileSystemException {
      // Windows-style locks never apply here; ignore transient races.
    }
  });

  group('gh-2072 — sqlite3 native-assets prewarm script', () {
    test('AC11: pure SHA-256 matches the FIPS vectors', () {
      // hashlib-verified vectors, including the padding boundaries
      // (55/56/64-byte messages span zero, one and two compression blocks).
      expect(
        prewarm.sha256Hex(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        prewarm.sha256Hex(utf8.encode('hello world')),
        'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
      );
      expect(
        prewarm.sha256Hex(utf8.encode('a' * 55)),
        '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318',
      );
      expect(
        prewarm.sha256Hex(utf8.encode('a' * 56)),
        'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a',
      );
      expect(
        prewarm.sha256Hex(utf8.encode('a' * 1000)),
        '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3',
      );
      expect(
        prewarm.sha256Hex(const []),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      // > 64 bytes: forces multiple compression blocks (> 55-byte tail).
      final long = utf8.encode('a' * 1000);
      expect(prewarm.sha256Hex(long).length, 64);
    });

    test('AC12: a hung connection (accepted, never answered) is bounded '
        'by the per-attempt request timeout', () async {
      final contentA = utf8.encode('sqlite3-arm-android-content');
      final hashA = sha('A', contentA);
      final pkg = await fixturePackage(
        sandbox,
        assetHashes: {'libsqlite3.arm.android.so': hashA},
      );
      // gh-2072 review thread 9: a socket that accepts the request and
      // then goes silent (no 504 — just a stalled connection) must be
      // cut by the per-attempt timeout and engaged with the retry
      // budget; the pre-timeout code parked on it until the CI leg's
      // wall-clock timeout killed the whole step.
      final server = await FixtureServer.start((req, f) async {
        // Intentionally NO response and NO close: the request hangs.
        await Completer<void>().future;
      });

      final sw = Stopwatch()..start();
      final result = await runScript([
        '--package-root',
        pkg.path,
        '--targets',
        'arm-android',
        '--attempts',
        '1',
        '--request-timeout-seconds',
        '1',
        '--url-pattern',
        '${server.url}/\$FILENAME',
      ]);
      sw.stop();
      expect(
        result.exitCode,
        isNot(0),
        reason: 'the hung attempt must fail, not hang forever',
      );
      expect(result.stderr, contains('TimeoutException'));
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 20)),
        reason:
            'the request timeout must bound the stalled attempt — the '
            'whole run (script boot + 1 hung attempt + 1s budget) stays '
            'seconds-scale, never leg-timeout-scale\n'
            '${result.stdout}\n${result.stderr}',
      );
      final cacheDir = Directory(
        '${pkg.path}/.dart_tool/hooks_runner/shared/sqlite3/build',
      );
      final strays = cacheDir.existsSync()
          ? cacheDir
                .listSync(recursive: true)
                .whereType<File>()
                .where((f) => !f.path.endsWith('.lock'))
                .toList()
          : <File>[];
      expect(
        strays,
        isEmpty,
        reason:
            'a timed-out attempt must not cache anything — the hook must '
            'never find a poisoned entry (empty directories are fine: the '
            'hook creates the same tree itself)',
      );
    });

    test('AC9: target expansion — android triple, auto host, pass-through', () {
      expect(prewarm.expandTargets('android', hostTarget: 'arm64-linux'), [
        'arm-android',
        'arm64-android',
        'x64-android',
      ]);
      expect(prewarm.expandTargets('auto', hostTarget: 'x64-linux'), [
        'x64-linux',
      ]);
      expect(prewarm.expandTargets('arm64-ios', hostTarget: 'arm64-macos'), [
        'arm64-ios',
      ]);
      expect(
        prewarm.expandTargets(
          'arm64-linux, x64-linux',
          hostTarget: 'arm64-ios',
        ),
        ['arm64-linux', 'x64-linux'],
      );
    });

    test('AC9: release-asset names pin the REAL upstream naming — windows '
        'drops the lib prefix, apple targets use .dylib', () {
      // Verbatim from sqlite3 3.7.0/3.9.x asset_hashes.dart — a wrong name
      // here would look up a hash that does not exist and fail the leg the
      // prewarm exists to save.
      expect(
        prewarm.sourceFilenameForTarget('x64-windows'),
        'sqlite3.x64.windows.dll',
      );
      expect(
        prewarm.sourceFilenameForTarget('arm64-windows'),
        'sqlite3.arm64.windows.dll',
      );
      expect(
        prewarm.sourceFilenameForTarget('x64-linux'),
        'libsqlite3.x64.linux.so',
      );
      expect(
        prewarm.sourceFilenameForTarget('arm-android'),
        'libsqlite3.arm.android.so',
      );
      expect(
        prewarm.sourceFilenameForTarget('arm64-ios'),
        'libsqlite3.arm64.ios.dylib',
      );
      expect(
        prewarm.sourceFilenameForTarget('arm64-macos'),
        'libsqlite3.arm64.macos.dylib',
      );
      // The hook renames the download to the OS library file name
      // (libraryFileName) — windows lands as sqlite3.dll, not the asset
      // name.
      expect(prewarm.cachedFileNameForOs('windows'), 'sqlite3.dll');
      expect(prewarm.cachedFileNameForOs('linux'), 'libsqlite3.so');
      expect(prewarm.cachedFileNameForOs('android'), 'libsqlite3.so');
      expect(prewarm.cachedFileNameForOs('macos'), 'libsqlite3.dylib');
      expect(prewarm.cachedFileNameForOs('ios'), 'libsqlite3.dylib');
    });

    test('AC9: hostTarget() maps the running platform to a pinned name', () {
      final host = prewarm.hostTarget();
      expect(
        host,
        matches(
          RegExp(r'^(ia32|x64|arm|arm64|riscv64)-(linux|macos|windows)$'),
        ),
      );
    });

    test('AC10: parser reads the REAL upstream asset_hashes.dart format', () {
      // Env-dependent probe (gh-1655 AC5 posture): assert the parser
      // against a real sqlite3 checkout when the pub cache carries one,
      // named-skip otherwise.
      final cacheRoot = Directory(
        '${Platform.environment['PUB_CACHE'] ?? '${Platform.environment['HOME']}/.pub-cache'}/hosted/pub.dev',
      );
      final sqliteDirs = cacheRoot.existsSync()
          ? cacheRoot
                .listSync()
                .whereType<Directory>()
                .where((d) => Directory('${d.path}/lib/src/hook').existsSync())
                .where(
                  (d) => File(
                    '${d.path}/lib/src/hook/asset_hashes.dart',
                  ).existsSync(),
                )
                .toList()
          : <Directory>[];
      if (sqliteDirs.isEmpty) {
        print(
          'SKIP (named): no sqlite3 checkout with asset_hashes.dart in '
          'the pub cache — the real-format pin is unprovable here',
        );
        return;
      }
      final source = File(
        '${sqliteDirs.first.path}/lib/src/hook/asset_hashes.dart',
      ).readAsStringSync();
      final parsed = prewarm.parsePinnedAssets(source);
      expect(parsed.releaseTag, startsWith('sqlite3-'));
      expect(parsed.hashes.length, greaterThanOrEqualTo(20));
      expect(
        parsed.hashes.keys.any((k) => k.startsWith('libsqlite3.')),
        isTrue,
        reason:
            'the map must carry the default (sqlite3) library entries '
            'the hook downloads',
      );
      for (final entry in parsed.hashes.entries) {
        expect(entry.key, matches(RegExp('^[A-Za-z0-9_.]+\$')));
        expect(entry.value, matches(RegExp('^[0-9a-f]{64}\$')));
      }
    });

    test('AC1+AC2: downloads into the hook cache path, then reuses with '
        'zero fetches', () async {
      final contentC = utf8.encode('sqlite3-x64-linux-content');
      final hashC = sha('C', contentC);
      final pkg = await fixturePackage(
        sandbox,
        assetHashes: {
          'libsqlcipher.arm.android.so': 'd576bf3c24c1c31a386c64ee3897fd8f',
          'libsqlite3.x64.linux.so': hashC,
        },
      );
      var served = 0;
      final server = await FixtureServer.start((req, f) async {
        expect(req.uri.path, '/libsqlite3.x64.linux.so');
        served++;
        await FixtureServer.serveBytes(req, contentC);
      });

      final result = await runScript([
        '--package-root',
        pkg.path,
        '--targets',
        'x64-linux',
        '--url-pattern',
        '${server.url}/\$FILENAME',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(served, 1);
      expect(
        result.stdout,
        contains('download-${hashC.substring(0, 8)}'),
        reason:
            'the cache dir name must be the hook\'s download-<hash8> '
            'convention so the hook reuses the file without a fetch',
      );

      final cached = File(
        '${pkg.path}/.dart_tool/hooks_runner/shared/sqlite3/build/'
        'download-${hashC.substring(0, 8)}/libsqlite3.so',
      );
      expect(cached.existsSync(), isTrue);
      expect(cached.readAsBytesSync(), contentC);

      // AC2: second run — cache hit, zero network.
      final again = await runScript([
        '--package-root',
        pkg.path,
        '--targets',
        'x64-linux',
        '--url-pattern',
        '${server.url}/\$FILENAME',
      ]);
      expect(again.exitCode, 0, reason: '${again.stdout}\n${again.stderr}');
      expect(
        served,
        1,
        reason:
            'the second run must not fetch — the hook '
            'reuse path will likewise never touch the network',
      );
    });

    test('AC3: THE BUG — a 504 error page then a 200 lands the correct '
        'bytes (bounded retry)', () async {
      final contentA = utf8.encode('sqlite3-arm-android-content');
      final hashA = sha('A', contentA);
      final pkg = await fixturePackage(
        sandbox,
        assetHashes: {'libsqlite3.arm.android.so': hashA},
      );
      var attempts = 0;
      final server = await FixtureServer.start((req, f) async {
        attempts++;
        if (attempts == 1) {
          // The exact failure the CI runners hit: an intermediary answers
          // the asset request with a 504 HTML page.
          await FixtureServer.serveBytes(req, errorPageBytes, status: 504);
        } else {
          await FixtureServer.serveBytes(req, contentA);
        }
      });

      final result = await runScript([
        '--package-root',
        pkg.path,
        '--targets',
        'arm-android',
        '--attempts',
        '3',
        '--url-pattern',
        '${server.url}/\$FILENAME',
      ]);
      expect(
        result.exitCode,
        0,
        reason:
            'a transient 504 must be retried, not fatal — this is the '
            'exact v1.0.697 failure\n${result.stdout}\n${result.stderr}',
      );
      expect(attempts, 2);
      final cached = File(
        '${pkg.path}/.dart_tool/hooks_runner/shared/sqlite3/build/'
        'download-${hashA.substring(0, 8)}/libsqlite3.so',
      );
      expect(cached.existsSync(), isTrue);
      expect(cached.readAsBytesSync(), contentA);
    });

    test('AC4: persistent 504 fails loudly, caches nothing', () async {
      final contentA = utf8.encode('sqlite3-arm-android-content');
      final pkg = await fixturePackage(
        sandbox,
        assetHashes: {'libsqlite3.arm.android.so': sha('A', contentA)},
      );
      final server = await FixtureServer.start((req, f) async {
        await FixtureServer.serveBytes(req, errorPageBytes, status: 504);
      });

      final result = await runScript([
        '--package-root',
        pkg.path,
        '--targets',
        'arm-android',
        '--attempts',
        '2',
        '--url-pattern',
        '${server.url}/\$FILENAME',
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('504'));
      final cacheDir = Directory(
        '${pkg.path}/.dart_tool/hooks_runner/shared/sqlite3/build',
      );
      final strays = cacheDir.existsSync()
          ? cacheDir
                .listSync(recursive: true)
                .whereType<File>()
                .where((f) => !f.path.endsWith('.lock'))
                .toList()
          : <File>[];
      expect(
        strays,
        isEmpty,
        reason:
            'a failed prewarm must not leave a poisoned cache entry '
            'the hook could pick up',
      );
    });

    test('AC5: a 200 with hash-mismatched bytes is never cached', () async {
      final hashA = sha('A', utf8.encode('sqlite3-arm-android-content'));
      final pkg = await fixturePackage(
        sandbox,
        assetHashes: {'libsqlite3.arm.android.so': hashA},
      );
      final server = await FixtureServer.start((req, f) async {
        await FixtureServer.serveBytes(req, errorPageBytes, status: 200);
      });

      final result = await runScript([
        '--package-root',
        pkg.path,
        '--targets',
        'arm-android',
        '--attempts',
        '1',
        '--url-pattern',
        '${server.url}/\$FILENAME',
      ]);
      expect(
        result.exitCode,
        isNot(0),
        reason:
            'a status-blind downloader would cache the error page — '
            'the hook would then die on its own hash check exactly like '
            'v1.0.697',
      );
      expect(
        result.stderr,
        contains(hashA.substring(0, 8)),
        reason:
            'the error must name the expected hash so a red leg is '
            'triageable from the log alone',
      );
    });

    test('AC6: a corrupted cache entry is repaired, not trusted', () async {
      final contentA = utf8.encode('sqlite3-arm-android-content');
      final hashA = sha('A', contentA);
      final pkg = await fixturePackage(
        sandbox,
        assetHashes: {'libsqlite3.arm.android.so': hashA},
      );
      final cacheFile = File(
        '${pkg.path}/.dart_tool/hooks_runner/shared/sqlite3/build/'
        'download-${hashA.substring(0, 8)}/libsqlite3.so',
      );
      cacheFile.createSync(recursive: true);
      cacheFile.writeAsBytesSync(errorPageBytes);

      final server = await FixtureServer.start((req, f) async {
        await FixtureServer.serveBytes(req, contentA);
      });
      final result = await runScript([
        '--package-root',
        pkg.path,
        '--targets',
        'arm-android',
        '--url-pattern',
        '${server.url}/\$FILENAME',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(cacheFile.readAsBytesSync(), contentA);
    });

    test('AC7: a package graph without sqlite3 is a clean no-op', () async {
      final pkg = await fixturePackage(
        sandbox,
        assetHashes: {},
        withSqlite3: false,
      );
      final result = await runScript([
        '--package-root',
        pkg.path,
        '--targets',
        'auto',
      ]);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('sqlite3'));
      expect(result.stdout, contains('no prewarm needed'));
    });

    test('AC8: an unknown target fails loudly', () async {
      final pkg = await fixturePackage(
        sandbox,
        assetHashes: {'libsqlite3.x64.linux.so': sha('C', utf8.encode('x'))},
      );
      final result = await runScript([
        '--package-root',
        pkg.path,
        '--targets',
        'sparc-linux',
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('sparc-linux'));
    });

    test('AC8: android expansion prewarms the three APK ABIs', () async {
      final blob = utf8.encode('android-blob');
      final pkg = await fixturePackage(
        sandbox,
        assetHashes: {
          'libsqlite3.arm.android.so': sha('arm', utf8.encode('android-arm')),
          'libsqlite3.arm64.android.so': sha('a64', utf8.encode('android-a64')),
          'libsqlite3.x64.android.so': sha('x64a', utf8.encode('android-x64a')),
        },
      );
      final paths = <String>{};
      final server = await FixtureServer.start((req, f) async {
        paths.add(req.uri.path);
        await FixtureServer.serveBytes(req, blob);
      });
      final result = await runScript([
        '--package-root',
        pkg.path,
        '--targets',
        'android',
        '--attempts',
        '1',
        '--url-pattern',
        '${server.url}/\$FILENAME',
      ]);
      // One blob cannot satisfy three different pinned hashes, so the run
      // must fail per-file while still attempting the WHOLE expansion —
      // proving `android` enumerates exactly the three APK ABIs.
      expect(
        result.exitCode,
        isNot(0),
        reason: '${result.stdout}\n${result.stderr}',
      );
      expect(paths, hasLength(3));
      expect(paths, contains('/libsqlite3.arm.android.so'));
      expect(paths, contains('/libsqlite3.arm64.android.so'));
      expect(paths, contains('/libsqlite3.x64.android.so'));
    });

    test('AC13: a corrupt package_config.json fails through the PREWARM '
        'FAILED trailer, not a raw stack trace', () async {
      final pkg = await fixturePackage(
        sandbox,
        assetHashes: {'libsqlite3.x64.linux.so': sha('C', utf8.encode('x'))},
      );
      // Simulate an interrupted pub get: the config file exists but is
      // not valid JSON. The CLI must surface a PrewarmException (single
      // PREWARM FAILED trailer) — an unhandled FormatException would
      // bypass the friendly trailer and leak a stack trace (gh-2072
      // review round 2 digest; cosmetic under continue-on-error, but
      // the CLI's error contract should stay uniform).
      File('${pkg.path}/.dart_tool/package_config.json').writeAsStringSync(
        '{"configVersion": 2, "packages": [', // truncated
      );
      final result = await runScript(['--package-root', pkg.path]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('PREWARM FAILED'));
      expect(result.stderr, contains('not valid JSON'));
      // The friendly trailer must own the failure — an UNHANDLED
      // exception (raw dart crash, no trailer) is the defect shape.
      expect(result.stderr, isNot(contains('Unhandled exception')));
    });
  });
}
