// gh-2072 — prewarm the sqlite3 native-assets hook cache with bounded
// retry.
//
// The `sqlite3` package (pinned in flutter_app/pubspec.lock at 3.7.0 and
// floating on the root package via flutter_agent_memory) builds its
// prebuilt native library through a build hook that downloads
// `libsqlite3.<abi>.<os>` from the simolus3/sqlite3.dart GitHub release —
// in a SINGLE attempt, with NO HTTP status check: whatever the response
// body is gets piped into the hook's output file and only the sha256
// check afterwards notices. At v1.0.697 the runner egress answered a
// transient `504 Gateway Time-out` HTML page; the hook saved that page as
// the library, its hash check threw
// `Bad state: Hash of downloaded file … is bef140a1… expected …`, and
// four CI legs (Terminal visual, Flutter app tests shards 0/2 + 1/2,
// Build Android APK) plus the aggregate Quality gate went red — on a tree
// that had passed the same legs hours earlier.
//
// This script moves that download OUT of the unretryable hook path (the
// gh-1655/gh-1757 pre-install pattern): it reads the pinned hashes from
// the INSTALLED sqlite3 package's own `asset_hashes.dart` (single source
// of truth — never a second pin), fetches the requested prebuilt binaries
// with bounded retry + status checking + sha256 verification, and writes
// them atomically into the exact cache location the hook's reuse path
// reads: `<root>/.dart_tool/hooks_runner/shared/sqlite3/build/
// download-<first-8-of-pinned-hash>/<libsqlite3.so|libsqlite3.dylib>`.
// A matching cached file makes the hook return without touching the
// network, so a flaky 504 can no longer red a leg.
//
// Usage:
//   dart run scripts/sqlite3_native_assets_prewarm.dart \
//     [--package-root <dir>] [--targets <spec>] [--attempts <n>] \
//     [--url-pattern <p>] [--backoff-base-seconds <s>] [--quiet]
//
//   --package-root  package whose dependency graph carries sqlite3;
//                   repeatable, defaults to the working directory.
//   --targets       `auto` (host platform — the default), `android`
//                   (the three APK ABIs), `arm64-ios`, or explicit
//                   `<abi>-<os>` names (e.g. `arm64-linux,x64-linux`).
//   --attempts      bounded-retry budget per file (default 4).
//   --connect-timeout-seconds   TCP connect budget per attempt
//                               (default 30 — a stalled connect fails
//                               fast and engages the retry budget).
//   --request-timeout-seconds   per-attempt budget for response headers
//                               AND body (default 120 — a hung
//                               connection must engage the bounded
//                               retry, never park the step until the
//                               CI leg's wall-clock timeout kills it).
//   --url-pattern   the release URL pattern; defaults to the sqlite3
//                   hook's own default. `$RELEASE_TAG` and `$FILENAME`
//                   are substituted. Overridable so tests can point the
//                   script at a local fixture server.
//
// Exit codes: 0 = every requested target is cached (or cleanly skipped);
// 1 = any explicit target failed after the bounded retries.
//
// Deterministically tested by test/scripts/sqlite3_native_assets_prewarm_test.dart
// (local HTTP fixture: the 504-then-200 reproduction, status-blind and
// hash-mismatch rejections, idempotent reuse, cache repair); the CI
// wiring is pinned by test/ci_sqlite3_prewarm_guard_test.dart.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// ── SHA-256 (stdlib has no crypto; the script must run standalone, with
// no package imports, so it can be invoked from ANY package context) ──

const List<int> _sha256K = [
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

int _rotr32(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

/// Pure-Dart SHA-256 (FIPS 180-4). The script verifies downloads against
/// the pinned hashes before caching them — the same check that caught the
/// v1.0.697 corruption, but before the hook ever sees the file.
String sha256Hex(List<int> bytes) {
  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final bitLength = bytes.length * 8;
  final padded = <int>[...bytes, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    padded.add((bitLength >> (8 * i)) & 0xFF);
  }
  final w = List<int>.filled(64, 0);
  for (var chunk = 0; chunk < padded.length; chunk += 64) {
    for (var t = 0; t < 16; t++) {
      final b = chunk + 4 * t;
      w[t] =
          (padded[b] << 24) |
          (padded[b + 1] << 16) |
          (padded[b + 2] << 8) |
          padded[b + 3];
    }
    for (var t = 16; t < 64; t++) {
      final s0 =
          _rotr32(w[t - 15], 7) ^ _rotr32(w[t - 15], 18) ^ (w[t - 15] >> 3);
      final s1 =
          _rotr32(w[t - 2], 17) ^ _rotr32(w[t - 2], 19) ^ (w[t - 2] >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xFFFFFFFF;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var t = 0; t < 64; t++) {
      final s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
      final ch = (e & f) ^ (~e & g);
      final temp1 = (hh + s1 + ch + _sha256K[t] + w[t]) & 0xFFFFFFFF;
      final s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xFFFFFFFF;
      hh = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xFFFFFFFF;
    }
    h[0] = (h[0] + a) & 0xFFFFFFFF;
    h[1] = (h[1] + b) & 0xFFFFFFFF;
    h[2] = (h[2] + c) & 0xFFFFFFFF;
    h[3] = (h[3] + d) & 0xFFFFFFFF;
    h[4] = (h[4] + e) & 0xFFFFFFFF;
    h[5] = (h[5] + f) & 0xFFFFFFFF;
    h[6] = (h[6] + g) & 0xFFFFFFFF;
    h[7] = (h[7] + hh) & 0xFFFFFFFF;
  }
  return h.map((x) => x.toRadixString(16).padLeft(8, '0')).join();
}

// ── Pinned-asset parsing (the installed package is the single source of
// truth) ──

class PinnedAssets {
  final String? releaseTag;
  final Map<String, String> hashes;
  const PinnedAssets(this.releaseTag, this.hashes);
}

/// Parses the installed sqlite3 package's `lib/src/hook/asset_hashes.dart`
/// as text: the `releaseTag` constant and the filename → sha256 map. The
/// format is generated (`tool/write_asset_hashes.dart`) and stable across
/// 3.7.x–3.9.x; a structural change fails the parse loudly (and the guard
/// test's real-package probe fails first, named).
PinnedAssets parsePinnedAssets(String source) {
  final tagMatch = RegExp(
    r"const String\? releaseTag = '([^']+)'",
  ).firstMatch(source);
  final hashes = <String, String>{};
  final entryRe = RegExp("'([A-Za-z0-9_.]+)': '([0-9a-f]{64})'");
  for (final m in entryRe.allMatches(source)) {
    hashes[m.group(1)!] = m.group(2)!;
  }
  if (hashes.isEmpty) {
    throw const PrewarmException(
      'no pinned asset hashes found in asset_hashes.dart — the sqlite3 '
      'package changed its hook layout; update the parser and '
      'test/ci_sqlite3_prewarm_guard_test.dart TOGETHER',
    );
  }
  return PinnedAssets(tagMatch?.group(1), hashes);
}

// ── Target naming ──

/// Maps a target name (`<abi>-<os>`) to the release-asset file name the
/// sqlite3 hook downloads for it, where the extension follows the OS:
/// `.so` for linux/android, `.dylib` for apple targets, `.dll` for
/// windows. Naming quirk pinned to `asset_hashes.dart`: windows assets
/// have NO `lib` prefix (`sqlite3.x64.windows.dll`), every other OS uses
/// `libsqlite3.<abi>.<os>.<ext>`.
String sourceFilenameForTarget(String target) {
  final parts = target.split('-');
  if (parts.length != 2) {
    throw PrewarmException(
      'invalid target "$target" — expected <abi>-<os> (e.g. arm64-linux)',
    );
  }
  final abi = parts[0];
  final os = parts[1];
  const exts = {
    'linux': 'so',
    'android': 'so',
    'macos': 'dylib',
    'ios': 'dylib',
    'ios_sim': 'dylib',
    'windows': 'dll',
  };
  final ext = exts[os];
  if (ext == null) {
    throw PrewarmException(
      'invalid target "$target" — unknown OS "$os" (known: '
      '${exts.keys.join(', ')})',
    );
  }
  if (os == 'windows') {
    return 'sqlite3.$abi.$os.$ext';
  }
  return 'libsqlite3.$abi.$os.$ext';
}

/// The cache file name the hook writes for a target OS — the hook renames
/// downloads to `input.config.code.targetOS.libraryFileName('sqlite3',
/// DynamicLoadingBundled())`, NOT to the release-asset name (android and
/// linux both land as `libsqlite3.so`, in a `download-<hash8>` dir that is
/// unique per ABI).
String cachedFileNameForOs(String os) => switch (os) {
  'macos' || 'ios' || 'ios_sim' => 'libsqlite3.dylib',
  'windows' => 'sqlite3.dll',
  _ => 'libsqlite3.so',
};

/// Expands the `--targets` spec: `auto` → the host target, `android` →
/// the three APK ABIs (`flutter build apk` produces armeabi-v7a,
/// arm64-v8a, x86_64 — the x86/ia32 row is gone from Flutter's default
/// APK), explicit names pass through.
List<String> expandTargets(String spec, {required String hostTarget}) {
  final out = <String>[];
  for (final raw in spec.split(RegExp(r'[,\s]+'))) {
    final t = raw.trim();
    if (t.isEmpty) continue;
    switch (t) {
      case 'auto':
        out.add(hostTarget);
      case 'android':
        out.addAll(['arm-android', 'arm64-android', 'x64-android']);
      case 'ios':
        out.add('arm64-ios');
      default:
        out.add(t);
    }
  }
  if (out.isEmpty) {
    throw const PrewarmException('empty --targets spec');
  }
  return out;
}

/// The host's own `<abi>-<os>` target name (what `flutter test`/a host
/// `dart run` builds code assets for).
String hostTarget() {
  final os = Platform.operatingSystem;
  String abi;
  if (Platform.isWindows) {
    final arch = (Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '')
        .toUpperCase();
    abi = switch (arch) {
      'ARM64' => 'arm64',
      'I386' || 'X86' => 'ia32',
      _ => 'x64',
    };
  } else {
    final result = Process.runSync('uname', ['-m']);
    if (result.exitCode != 0) {
      throw PrewarmException(
        'uname -m failed (exit ${result.exitCode}) — cannot resolve the '
        'host architecture for the auto target',
      );
    }
    final machine = '${result.stdout}'.trim();
    abi = switch (machine) {
      'x86_64' || 'amd64' => 'x64',
      'arm64' || 'aarch64' => 'arm64',
      'riscv64' => 'riscv64',
      _ => machine,
    };
  }
  final osName = switch (os) {
    'linux' => 'linux',
    'macos' => 'macos',
    'windows' => 'windows',
    'android' => 'android',
    _ => os,
  };
  return '$abi-$osName';
}

// ── Cache path (the hook's reuse location) ──

/// The exact file the sqlite3 hook's reuse path reads for a target:
/// `<root>/.dart_tool/hooks_runner/shared/sqlite3/build/download-<hash8>/`
/// `<cachedName>`, where hash8 is the first 8 hex chars of the PINNED hash
/// (`PrebuiltSqliteLibrary.dirname`) and cachedName is the hook's output
/// file name for that OS.
String cacheFilePathForTarget({
  required String packageRoot,
  required String target,
  required String pinnedSha256,
}) {
  final os = target.split('-').last;
  return '$packageRoot/.dart_tool/hooks_runner/shared/sqlite3/build/'
      'download-${pinnedSha256.substring(0, 8)}/${cachedFileNameForOs(os)}';
}

Uri sourceUri({
  required String urlPattern,
  required String? releaseTag,
  required String filename,
}) {
  if (releaseTag == null) {
    throw const PrewarmException(
      'asset_hashes.dart pins no releaseTag (a local/dev build of the '
      'sqlite3 package?) — cannot derive the download URL',
    );
  }
  final resolved = urlPattern
      .replaceAll(r'$RELEASE_TAG', releaseTag)
      .replaceAll(r'$FILENAME', filename);
  try {
    return Uri.parse(resolved);
  } on FormatException catch (e) {
    throw PrewarmException('invalid download URL "$resolved": ${e.message}');
  }
}

// ── The verified, bounded-retry download ──

class PrewarmException implements Exception {
  final String message;
  const PrewarmException(this.message);
  @override
  String toString() => message;
}

/// Per-attempt TCP connect budget (gh-2072 review thread 9): a stalled
/// connect fails fast and engages the retry budget instead of riding the
/// CI leg's wall-clock timeout.
const _defaultConnectTimeout = Duration(seconds: 30);

/// Per-attempt budget for response headers AND body (gh-2072 review
/// thread 9): a hung connection — no 504, just a socket that never
/// answers — must engage the bounded retry, never park the step until
/// the leg timeout kills it.
const _defaultRequestTimeout = Duration(seconds: 120);

/// ±30% jitter source for the retry backoff (gh-2072 review thread 11):
/// during a repo-wide egress storm every leg retries against the same
/// saturated path — lockstep retries amplify the outage instead of
/// smoothing it.
final math.Random _backoffJitter = math.Random();

Future<File> downloadVerified({
  required Uri uri,
  required String expectedSha256,
  required File target,
  required int attempts,
  required int backoffBaseSeconds,
  required Duration connectTimeout,
  required Duration requestTimeout,
  required void Function(String line) log,
}) async {
  target.parent.createSync(recursive: true);
  final tmp = File('${target.path}.tmp');
  Object? lastError;
  for (var attempt = 1; attempt <= attempts; attempt++) {
    // One client per attempt, closed in the `finally` on EVERY path: the
    // failure path used to leak the client until process exit (android
    // × N packages stacks one per file per attempt — gh-2072 review
    // thread 9).
    final client = HttpClient()
      // The hook itself resolves proxies from the environment
      // (sqlite3.dart #335); the prewarm must behave identically or it
      // breaks proxied runners the hook otherwise serves.
      ..findProxy = HttpClient.findProxyFromEnvironment
      ..connectionTimeout = connectTimeout;
    try {
      if (tmp.existsSync()) {
        tmp.deleteSync();
      }
      final request = await client.getUrl(uri);
      request.headers.add('User-Agent', 'fa sqlite3 native-assets prewarm');
      final response = await request.close().timeout(requestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        // Drain so the connection is not left dangling, then reject the
        // attempt explicitly — THIS is the check the sqlite3 hook lacks:
        // at v1.0.697 it piped a 504 error page straight into the output
        // file and only tripped on the hash afterwards.
        await response.drain<void>().timeout(requestTimeout);
        throw PrewarmException('HTTP ${response.statusCode} for $uri');
      }
      final builder = BytesBuilder(copy: false);
      // The body read carries its own budget too: a transfer that stalls
      // mid-stream dies here instead of hanging the step (the hook's own
      // download has no such bound — gh-2072 review thread 9).
      await response
          .listen(builder.add)
          .asFuture<void>()
          .timeout(requestTimeout);
      final bytes = builder.takeBytes();
      final digest = sha256Hex(bytes);
      if (digest != expectedSha256) {
        throw PrewarmException(
          'sha256 mismatch for $uri: downloaded $digest, expected '
          '$expectedSha256',
        );
      }
      await tmp.writeAsBytes(bytes, flush: true);
      tmp.renameSync(target.path);
      return target;
    } on PrewarmException catch (e) {
      lastError = e;
      log('attempt $attempt/$attempts failed: ${e.message}');
    } catch (e) {
      lastError = e;
      log('attempt $attempt/$attempts failed: $e');
    } finally {
      client.close(force: true);
    }
    if (tmp.existsSync()) {
      try {
        tmp.deleteSync();
      } on FileSystemException {
        // A torn tmp is harmless — the next attempt recreates it.
      }
    }
    if (attempt < attempts) {
      final raw = backoffBaseSeconds * (1 << (attempt - 1));
      // ±30% jitter (gh-2072 review thread 11): a repo-wide storm must
      // not have every leg retry in lockstep against the same saturated
      // egress.
      final wait = (raw * (0.7 + 0.6 * _backoffJitter.nextDouble())).round();
      await Future<void>.delayed(Duration(seconds: wait < 1 ? 1 : wait));
    }
  }
  throw PrewarmException(
    'download failed after $attempts attempts: $lastError',
  );
}

// ── Per-package prewarm ──

class _TargetFailure {
  final String packageRoot;
  final String target;
  final Object error;
  const _TargetFailure(this.packageRoot, this.target, this.error);
}

/// Prewarms one package's hook cache. Returns the list of target names
/// that ended the run cached (or cleanly skipped). Throws [PrewarmException]
/// for structural problems (no package config, unparseable pins, unknown
/// explicit targets).
Future<List<String>> prewarmPackageRoot({
  required String packageRoot,
  required String targetSpec,
  required int attempts,
  required int backoffBaseSeconds,
  required Duration connectTimeout,
  required Duration requestTimeout,
  required String urlPattern,
  required void Function(String line) log,
}) async {
  final root = packageRoot.endsWith('/')
      ? packageRoot.substring(0, packageRoot.length - 1)
      : packageRoot;
  final configFile = File('$root/.dart_tool/package_config.json');
  if (!configFile.existsSync()) {
    throw PrewarmException(
      '$root/.dart_tool/package_config.json not found — run pub get '
      'before the prewarm (the prewarm reads the resolved sqlite3 '
      'location from the package config)',
    );
  }
  // A corrupt/truncated package_config.json (interrupted pub get) throws
  // FormatException/TypeError from the raw casts — catch and rethrow as a
  // PrewarmException so the CLI's PREWARM FAILED trailer stays uniform
  // instead of leaking a stack trace (gh-2072 review round 2 digest).
  final Map<String, Object?> config;
  try {
    config = jsonDecode(configFile.readAsStringSync()) as Map<String, Object?>;
  } on FormatException catch (e) {
    throw PrewarmException(
      '$root/.dart_tool/package_config.json is not valid JSON '
      '(interrupted pub get?) — re-run `dart pub get`: $e',
    );
  } on TypeError {
    throw PrewarmException(
      '$root/.dart_tool/package_config.json has an unexpected shape '
      '(not a JSON object) — re-run `dart pub get`',
    );
  }
  // The WHOLE parse block owns the same contract (gh-2072 review thread
  // 18): a config that IS valid JSON but carries a wrong member shape
  // (`packages` missing / not a list, a scalar list entry, a malformed
  // sqlite3 entry) throws TypeError from these raw casts exactly like a
  // truncated file throws FormatException above — both must surface
  // through the PREWARM FAILED trailer, never a raw stack trace.
  Map<String, Object?>? sqliteEntry;
  final String rootUri;
  try {
    final packages = config['packages'] as List<Object?>;
    for (final pkg in packages) {
      final entry = pkg as Map<String, Object?>;
      if (entry['name'] == 'sqlite3') {
        sqliteEntry = entry;
        break;
      }
    }
    if (sqliteEntry == null) {
      log('$root: sqlite3 not in the package graph — no prewarm needed');
      return const [];
    }
    rootUri = sqliteEntry['rootUri'] as String;
  } on TypeError catch (e) {
    throw PrewarmException(
      '$root/.dart_tool/package_config.json has an unexpected shape '
      '(valid JSON, wrong member types — interrupted pub get?) — '
      're-run `dart pub get`: $e',
    );
  }
  final base = Directory('$root/.dart_tool').uri;
  var sqliteRoot = base.resolve(rootUri).toFilePath();
  if (sqliteRoot.endsWith('/')) {
    sqliteRoot = sqliteRoot.substring(0, sqliteRoot.length - 1);
  }
  final hashesFile = File('$sqliteRoot/lib/src/hook/asset_hashes.dart');
  if (!hashesFile.existsSync()) {
    throw PrewarmException(
      '${hashesFile.path} not found — the resolved sqlite3 package '
      '(${sqliteEntry['version'] ?? 'unknown version'}) predates the '
      'native-assets hook or moved its layout; update the parser and '
      'test/ci_sqlite3_prewarm_guard_test.dart TOGETHER',
    );
  }
  final pinned = parsePinnedAssets(hashesFile.readAsStringSync());
  log(
    '$root: sqlite3 ${sqliteEntry['version'] ?? ''} releaseTag '
    '${pinned.releaseTag} — prewarming targets: $targetSpec',
  );

  final host = hostTarget();
  final cached = <String>[];
  final failures = <_TargetFailure>[];
  for (final target in expandTargets(targetSpec, hostTarget: host)) {
    String filename;
    try {
      filename = sourceFilenameForTarget(target);
    } on PrewarmException catch (e) {
      failures.add(_TargetFailure(root, target, e));
      continue;
    }
    final pinnedHash = pinned.hashes[filename];
    if (pinnedHash == null) {
      final message =
          'no pinned prebuilt for target $target ($filename) in '
          '${pinned.releaseTag}';
      if (target == host) {
        // `auto` on a host whose pinned prebuilt the release does not
        // ship is a clean skip: there is nothing the hook would download
        // for that platform (every host CI uses today — linux, macos,
        // windows — HAS a pinned prebuilt; this is the guard for a
        // future platform gap).
        log(
          '$root: $message — skipping the auto target (the release '
          'ships no prebuilt for this host)',
        );
        continue;
      }
      failures.add(_TargetFailure(root, target, PrewarmException(message)));
      continue;
    }
    final cachePath = cacheFilePathForTarget(
      packageRoot: root,
      target: target,
      pinnedSha256: pinnedHash,
    );
    final cachedFile = File(cachePath);
    if (cachedFile.existsSync()) {
      final digest = sha256Hex(cachedFile.readAsBytesSync());
      if (digest == pinnedHash) {
        log(
          '$root: $target already cached (${cachePath.replaceFirst('$root/', '')})',
        );
        cached.add(target);
        continue;
      }
      log(
        '$root: $target cache entry is corrupted (sha256 $digest) — '
        'repairing',
      );
    }
    final uri = sourceUri(
      urlPattern: urlPattern,
      releaseTag: pinned.releaseTag,
      filename: filename,
    );
    try {
      await downloadVerified(
        uri: uri,
        expectedSha256: pinnedHash,
        target: cachedFile,
        attempts: attempts,
        backoffBaseSeconds: backoffBaseSeconds,
        connectTimeout: connectTimeout,
        requestTimeout: requestTimeout,
        log: (line) => log('$root: $target $line'),
      );
      log('$root: $target cached at download-${pinnedHash.substring(0, 8)}');
      cached.add(target);
    } on PrewarmException catch (e) {
      failures.add(_TargetFailure(root, target, e));
    }
  }
  if (failures.isNotEmpty) {
    for (final f in failures) {
      log('${f.packageRoot}: FAILED ${f.target}: ${f.error}');
    }
    throw PrewarmException(
      '${failures.length} of ${cached.length + failures.length} targets '
      'failed for $root (first: ${failures.first.target}: '
      '${failures.first.error})',
    );
  }
  return cached;
}

// ── CLI ──

Future<int> runMain(List<String> args) async {
  var packageRoots = <String>[];
  var targetSpec = 'auto';
  var attempts = 4;
  var backoffBaseSeconds = 5;
  var connectTimeout = _defaultConnectTimeout;
  var requestTimeout = _defaultRequestTimeout;
  var urlPattern =
      r'https://github.com/simolus3/sqlite3.dart/releases/download/$RELEASE_TAG/$FILENAME';
  var quiet = false;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    switch (a) {
      case '--package-root':
        packageRoots.add(args[++i]);
      case '--targets':
        targetSpec = args[++i];
      case '--attempts':
        attempts = int.parse(args[++i]);
      case '--backoff-base-seconds':
        backoffBaseSeconds = int.parse(args[++i]);
      case '--connect-timeout-seconds':
        connectTimeout = Duration(seconds: int.parse(args[++i]));
      case '--request-timeout-seconds':
        requestTimeout = Duration(seconds: int.parse(args[++i]));
      case '--url-pattern':
        urlPattern = args[++i];
      case '--quiet':
        quiet = true;
      default:
        stderr.writeln('unknown argument: $a');
        stderr.write(_usage);
        return 2;
    }
  }
  if (packageRoots.isEmpty) {
    packageRoots = ['.'];
  }
  void log(String line) {
    if (!quiet) {
      stdout.writeln(line);
    }
  }

  final failures = <_TargetFailure>[];
  for (final root in packageRoots) {
    try {
      await prewarmPackageRoot(
        packageRoot: root,
        targetSpec: targetSpec,
        attempts: attempts,
        backoffBaseSeconds: backoffBaseSeconds,
        connectTimeout: connectTimeout,
        requestTimeout: requestTimeout,
        urlPattern: urlPattern,
        log: log,
      );
    } on PrewarmException catch (e) {
      failures.add(_TargetFailure(root, targetSpec, e));
    }
  }
  if (failures.isNotEmpty) {
    for (final f in failures) {
      stderr.writeln('PREWARM FAILED — ${f.packageRoot}: ${f.error}');
    }
    stderr.writeln(
      'gh-2072 context: the sqlite3 hook downloads prebuilt binaries at '
      'build time in a single unchecked attempt; this prewarm exists so a '
      'transient GitHub error (504 Gateway Time-out error page saved as '
      'the library, rejected by the hook hash check) cannot red the leg. '
      'If the failure persists, check the runner egress to '
      'github.com/simolus3/sqlite3.dart releases.',
    );
    return 1;
  }
  return 0;
}

const _usage =
    'usage: dart run scripts/sqlite3_native_assets_prewarm.dart '
    '[--package-root <dir>]... [--targets auto|android|arm64-ios|<abi>-<os>] '
    '[--attempts <n>] [--backoff-base-seconds <s>] '
    '[--connect-timeout-seconds <s>] [--request-timeout-seconds <s>] '
    '[--url-pattern <p>] [--quiet]\n';

Future<void> main(List<String> args) async {
  exitCode = await runMain(args);
}
