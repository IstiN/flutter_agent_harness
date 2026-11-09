// Pre-warm the package:sqlite3 native-assets hook cache (gh-2074).
//
// The play leg (build-mobile.yml) went red on three Android jobs when a
// GitHub release-download brownout served 504 pages to package:sqlite3's
// build hook, which hashes the response body WITHOUT honoring the HTTP
// status (released 3.7.0; 3.9.1 gained the status check upstream but has
// no retry). The 504 page's SHA-256 (`bef140a1…`) is a constant for every
// caller, so the hook reports `Bad state: Hash of downloaded file … is
// bef140a1…, expected …` and exits 255 mid-build — documented upstream as
// simolus3/sqlite3.dart#435. ci.yml solved the class for itself on
// 2026-09-21 by caching `.dart_tool/hooks_runner/shared`; this script is
// the mobile-lane cure and pairs with that cache in build-mobile.yml.
//
// What it does, per `--package` root and `--targets` set:
//   1. resolves the sqlite3 package from `<pkg>/.dart_tool/package_config.json`
//      and parses `lib/src/hook/asset_hashes.dart` — the release tag and the
//      pinned SHA-256s come from the RESOLVED package, so a sqlite3 bump
//      re-points every download automatically (no second pin to drift),
//   2. for each target, checks the hook's content-addressed cache
//      `<pkg>/.dart_tool/hooks_runner/shared/sqlite3/build/download-<hash8>/<libname>`
//      — already verified → skip (the hook's own reuse path, no network),
//   3. otherwise downloads the release asset with the HTTP status gated
//      BEFORE hashing, bounded retries with backoff (the gh-1655/gh-1757
//      pre-install pattern), verifies SHA-256 against the pin, and writes
//      tmp+rename so a torn write can never enter the cache.
//
// The cache layout is the hook's own (`PrebuiltSqliteLibrary.dirname` =
// `download-` + hash prefix; saved under the target OS's
// `libraryFileName('sqlite3', DynamicLoadingBundled())`) — the hook then
// reuses the pre-warmed bytes instead of downloading. The layout is pinned
// by test/scripts/sqlite3_hook_prewarm_test.dart from a live hook run.
//
// Usage:
//   dart run scripts/sqlite3_hook_prewarm.dart \
//     --package flutter_app --targets android        # the mobile builds
//   dart run scripts/sqlite3_hook_prewarm.dart --package . --targets host
//
// Exit codes: 0 = every target verified in cache; 1 = loud failure
// (::error:: annotation) after the bounded retries — CI must not silently
// continue into a build whose hook would re-download bare.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Default release-download pattern (mirrors the hook's
/// `PrecompiledFromGithubAssets.defaultUrlPattern`).
const String defaultUrlPattern =
    r'https://github.com/simolus3/sqlite3.dart/releases/download/$RELEASE_TAG/$FILENAME';

/// Where the hook keeps content-addressed downloads, relative to the
/// package's `.dart_tool/hooks_runner/shared` root (`outputDirectoryShared`
/// is `shared/<hookPackage>/build`; the assets subdirectory is
/// `download-<hash8>`).
const String sharedSubdir = 'sqlite3/build';

/// Supported ABIs per target OS — mirrors the hook's `_supportedAbis`
/// (sqlite3 3.7.0/3.9.1 `lib/src/hook/assets.dart`). The android set is a
/// superset of what flutter release builds request (arm/arm64/x64) so a
/// debug/x86 emulator run is covered too.
const Map<String, List<String>> supportedAbis = {
  'linux': ['ia32', 'x64', 'riscv64', 'arm', 'arm64'],
  'windows': ['ia32', 'x64', 'arm64'],
  'macos': ['x64', 'arm64'],
  'ios': ['arm64'],
  'ios_sim': ['x64', 'arm64'],
  'android': ['ia32', 'x64', 'arm', 'arm64'],
};

/// The release-asset filename for a target, as it appears both in the
/// GitHub release and as a key in `asset_hashes.dart` (windows DLLs carry
/// no `lib` prefix — see the released `asset_hashes.dart` keys).
String assetFilenameFor(String os, String arch) {
  switch (os) {
    case 'windows':
      return 'sqlite3.$arch.windows.dll';
    case 'macos':
    case 'ios':
    case 'ios_sim':
      return 'libsqlite3.$arch.$os.dylib';
    case 'linux':
    case 'android':
      return 'libsqlite3.$arch.$os.so';
    default:
      throw ArgumentError.value(os, 'os', 'unknown target os');
  }
}

/// The filename the hook saves the asset under — the target OS's
/// `libraryFileName('sqlite3', DynamicLoadingBundled())`. The pre-warm
/// must write EXACTLY this name or the hook will not reuse the bytes.
String cachedFilenameFor(String os) {
  switch (os) {
    case 'windows':
      return 'sqlite3.dll';
    case 'macos':
    case 'ios':
    case 'ios_sim':
      return 'libsqlite3.dylib';
    case 'linux':
    case 'android':
      return 'libsqlite3.so';
    default:
      throw ArgumentError.value(os, 'os', 'unknown target os');
  }
}

/// The hook's content-addressed directory for an asset:
/// `download-` + the first 8 hex of the asset's SHA-256.
String cacheDirNameFor(String sha256) => 'download-${sha256.substring(0, 8)}';

/// Full reuse path of the hook for a verified asset.
String cachedFilePath({
  required String sharedDir,
  required String sha256,
  required String os,
}) {
  final separator = Platform.pathSeparator;
  return '$sharedDir$separator$sharedSubdir$separator'
      '${cacheDirNameFor(sha256)}$separator${cachedFilenameFor(os)}';
}

/// A parsed `asset_hashes.dart` from the resolved sqlite3 package.
class Sqlite3AssetHashes {
  final String? releaseTag;
  final Map<String, String> assetNameToSha256Hash;

  const Sqlite3AssetHashes(this.releaseTag, this.assetNameToSha256Hash);
}

/// Parses the released shape of `lib/src/hook/asset_hashes.dart`:
///
///     const String? releaseTag = 'sqlite3-3.7.0';
///     const Map<String, String> assetNameToSha256Hash = {
///       'libsqlite3.x64.android.so': '949965f0…',
///     };
Sqlite3AssetHashes parseAssetHashes(String source) {
  final tagMatch =
      RegExp(r"const String\? releaseTag = (?:'([^']+)'|null);").firstMatch(
    source,
  );
  final hashes = <String, String>{};
  final entry = RegExp(r"'([^'\s]+)': '([0-9a-fA-F]{64})'");
  for (final match in entry.allMatches(source)) {
    hashes[match.group(1)!] = match.group(2)!.toLowerCase();
  }
  return Sqlite3AssetHashes(tagMatch?.group(1), hashes);
}

/// A concrete download target.
class PrewarmTarget {
  final String os;
  final String arch;

  const PrewarmTarget(this.os, this.arch);

  @override
  String toString() => '$os-$arch';
}

/// Expands a `--targets` token:
/// - `host` — the machine this process runs on,
/// - `<os>` — every supported ABI of that OS (`android` → 4 targets),
/// - `<os>-<arch>` — exactly one target.
List<PrewarmTarget> expandTargets(String token, {String? hostOs, String? hostArch}) {
  String os;
  String? arch;
  if (token == 'host') {
    final resolved = _hostTarget();
    os = resolved.$1;
    arch = resolved.$2;
  } else {
    final parts = token.split('-');
    os = parts.first;
    if (parts.length > 2) {
      throw ArgumentError.value(token, 'targets', 'expected <os> or <os>-<arch>');
    }
    if (parts.length == 2) arch = parts.last;
  }
  if (!supportedAbis.containsKey(os)) {
    throw ArgumentError.value(
      token,
      'targets',
      'unknown target os (supported: ${supportedAbis.keys.join(', ')}, host)',
    );
  }
  if (arch == null) {
    return [
      for (final a in supportedAbis[os]!) PrewarmTarget(os, a),
    ];
  }
  if (!supportedAbis[os]!.contains(arch)) {
    throw ArgumentError.value(
      token,
      'targets',
      'arch $arch unsupported for os $os (supported: ${supportedAbis[os]!.join(', ')})',
    );
  }
  return [PrewarmTarget(os, arch)];
}

(String, String) _hostTarget() {
  final os = switch (Platform.operatingSystem) {
    'linux' => 'linux',
    'macos' => 'macos',
    'windows' => 'windows',
    'android' => 'android',
    final other => throw PrewarmException(
        'host os $other has no sqlite3 prebuilt asset mapping',
      ),
  };
  // dart:ffi's Abi carries the OS in its constant names (linuxX64,
  // androidArm64, …) — map the current one to the asset-hash arch names
  // (x64 / ia32 / arm64 / arm / riscv64, the `asset_hashes.dart` spelling).
  const x64 = [
    Abi.linuxX64, Abi.macosX64, Abi.windowsX64, Abi.androidX64, Abi.iosX64,
    Abi.fuchsiaX64,
  ];
  const ia32 = [Abi.linuxIA32, Abi.windowsIA32, Abi.androidIA32];
  const arm64 = [
    Abi.linuxArm64, Abi.macosArm64, Abi.windowsArm64, Abi.androidArm64,
    Abi.iosArm64, Abi.fuchsiaArm64,
  ];
  const arm = [Abi.linuxArm, Abi.androidArm, Abi.iosArm];
  const riscv64 = [
    Abi.linuxRiscv64, Abi.androidRiscv64, Abi.fuchsiaRiscv64,
  ];
  final abi = Abi.current();
  final arch = x64.contains(abi)
      ? 'x64'
      : ia32.contains(abi)
          ? 'ia32'
          : arm64.contains(abi)
              ? 'arm64'
              : arm.contains(abi)
                  ? 'arm'
                  : riscv64.contains(abi)
                      ? 'riscv64'
                      : throw PrewarmException(
                          'host abi $abi has no sqlite3 prebuilt asset mapping',
                        );
  return (os, arch);
}

/// A non-200 response — thrown BEFORE any body byte is hashed (the check
/// upstream added in sqlite3 3.9.1; released 3.7.0 lacks it entirely).
class HttpStatusException implements Exception {
  final Uri uri;
  final int statusCode;

  const HttpStatusException(this.uri, this.statusCode);

  @override
  String toString() => 'HTTP $statusCode for $uri';
}

/// A loud, named pre-warm failure.
class PrewarmException implements Exception {
  final String message;

  const PrewarmException(this.message);

  @override
  String toString() => message;
}

/// Fetches the body of [uri]. Throws [HttpStatusException] on a non-200
/// status — the default implementation below is the only place the HTTP
/// status is consulted; tests inject fakes that throw it to simulate a
/// brownout.
typedef StreamFetcher = Future<Stream<List<int>>> Function(Uri uri);

/// The default fetcher: GET with the status gated before the body streams.
Future<Stream<List<int>>> _defaultFetch(Uri uri) async {
  final client = HttpClient();
  try {
    client.findProxy = HttpClient.findProxyFromEnvironment;
    client.connectionTimeout = const Duration(seconds: 30);
    final request = await client.getUrl(uri);
    request.headers.add(
      'User-Agent',
      'flutter_agent_harness sqlite3 hook prewarm (gh-2074)',
    );
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpStatusException(uri, response.statusCode);
    }
    // Drain into memory while the caller consumes; the client must not be
    // closed before the body is read, so detach via a broadcast-safe copy.
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    }
    return Stream.value(builder.takeBytes());
  } finally {
    client.close(force: true);
  }
}

/// Resolves the download URL for [assetName]. A null release tag cannot
/// name a release — a loud error, never a silently wrong URL.
Uri downloadUriFor({
  required Sqlite3AssetHashes hashes,
  required String urlPattern,
  required String assetName,
}) {
  final tag = hashes.releaseTag;
  if (tag == null || tag.isEmpty) {
    throw PrewarmException(
      'the resolved sqlite3 package pins no releaseTag (pre-release or '
      'overridden asset_hashes.dart) — cannot build a download URL for '
      '$assetName',
    );
  }
  return Uri.parse(
    urlPattern
        .replaceAll(r'$RELEASE_TAG', tag)
        .replaceAll(r'$FILENAME', assetName),
  );
}

/// Outcome of one package's pre-warm run.
class PrewarmReport {
  final List<String> downloaded;
  final List<String> skipped;

  const PrewarmReport(this.downloaded, this.skipped);
}

/// Downloads one asset with bounded retry + backoff, verifies its SHA-256
/// against [expectedSha256], and only then renames it into place. A failed
/// attempt never leaves bytes at [destination].
Future<File> fetchVerified({
  required StreamFetcher fetch,
  required Uri uri,
  required String expectedSha256,
  required File destination,
  required int attempts,
  required Duration retryDelay,
  required Duration timeoutPerAttempt,
  void Function(String message)? onNote,
}) async {
  destination.parent.createSync(recursive: true);
  final tmp = File('${destination.path}.tmp');
  Object? lastError;
  for (var attempt = 1; attempt <= attempts; attempt++) {
    try {
      final stream = await fetch(uri).timeout(timeoutPerAttempt);
      final builder = await stream
          .fold<BytesBuilder>(
            BytesBuilder(copy: false),
            (b, chunk) => b
              ..add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk)),
          )
          .timeout(timeoutPerAttempt);
      final bytes = builder.takeBytes();
      final digest = crypto.sha256.convert(bytes).toString();
      if (digest != expectedSha256.toLowerCase()) {
        // The gh-2074 signature: an error page (or truncated body) whose
        // hash ≠ the pin. Never write it — the hook would reject it (or
        // worse, 3.7.0's mislabeled "Bad state") and the cache must hold
        // verified bytes only.
        throw PrewarmException(
          'sha256 mismatch for $uri: got $digest, expected $expectedSha256 '
          '(an error page or truncated body — the asset was not cached)',
        );
      }
      await tmp.writeAsBytes(bytes, flush: true);
      tmp.renameSync(destination.path);
      return destination;
    } on HttpStatusException catch (e) {
      lastError = e;
    } on TimeoutException catch (e) {
      lastError = e;
    } on SocketException catch (e) {
      lastError = e;
    } on HttpException catch (e) {
      lastError = e;
    } on PrewarmException catch (e) {
      // The only PrewarmException thrown inside this loop is the sha256
      // mismatch — a truncated transfer or a lying proxy (200 + error
      // page). Retryable: the next attempt may fetch whole bytes, and a
      // retry is safe because nothing is written unverified.
      lastError = e;
    }
    if (tmp.existsSync()) tmp.deleteSync();
    if (attempt < attempts) {
      onNote?.call(
        'sqlite3 hook prewarm: attempt $attempt/$attempts failed for $uri '
        '($lastError) — retrying in ${retryDelay.inSeconds}s',
      );
      await Future<void>.delayed(retryDelay);
    }
  }
  throw PrewarmException(
    'sqlite3 hook prewarm failed for $uri after $attempts attempts: '
    '$lastError',
  );
}

/// Resolves the sqlite3 package root from [packageDir]'s
/// `.dart_tool/package_config.json`.
Directory resolveSqlite3Root(Directory packageDir) {
  final config = File(
    '${packageDir.path}${Platform.pathSeparator}.dart_tool'
    '${Platform.pathSeparator}package_config.json',
  );
  if (!config.existsSync()) {
    throw PrewarmException(
      '${config.path} not found — run pub get for ${packageDir.path} first '
      '(the pre-warm resolves the pinned hashes from the resolved package)',
    );
  }
  final decoded = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
  final packages = decoded['packages'] as List<dynamic>;
  for (final entry in packages) {
    if (entry is Map && entry['name'] == 'sqlite3') {
      final rootUri = Uri.parse(entry['rootUri'] as String);
      // package_config rootUris are relative to the config's parent dir.
      final resolved = rootUri.isAbsolute
          ? Directory.fromUri(rootUri)
          : Directory.fromUri(
              Uri.file('${packageDir.path}/').resolveUri(rootUri),
            );
      return resolved;
    }
  }
  throw PrewarmException(
    'no sqlite3 package in ${config.path} — nothing to pre-warm for '
    '${packageDir.path}',
  );
}

/// Runs the pre-warm for one package root. Idempotent: every target whose
/// cache entry already matches the pinned hash is skipped without any
/// network traffic.
Future<PrewarmReport> prewarmPackage({
  required Directory packageDir,
  required List<PrewarmTarget> targets,
  int attempts = 3,
  Duration retryDelay = const Duration(seconds: 15),
  Duration timeoutPerAttempt = const Duration(seconds: 60),
  String urlPatternOverride = defaultUrlPattern,
  Directory? sharedDirOverride,
  StreamFetcher? fetchOverride,
  void Function(String message)? onNote,
}) async {
  final note = onNote ?? (String _) {};
  final sqlite3Root = resolveSqlite3Root(packageDir);
  final hashesSource = File(
    '${sqlite3Root.path}${Platform.pathSeparator}lib${Platform.pathSeparator}'
    'src${Platform.pathSeparator}hook${Platform.pathSeparator}'
    'asset_hashes.dart',
  );
  if (!hashesSource.existsSync()) {
    throw PrewarmException(
      '${hashesSource.path} not found — the resolved sqlite3 package layout '
      'moved; update this script TOGETHER with '
      'test/scripts/sqlite3_hook_prewarm_test.dart',
    );
  }
  final hashes = parseAssetHashes(hashesSource.readAsStringSync());
  if (hashes.assetNameToSha256Hash.isEmpty) {
    throw PrewarmException(
      'parsed no asset hashes from ${hashesSource.path} — the format moved; '
      'update this script TOGETHER with '
      'test/scripts/sqlite3_hook_prewarm_test.dart',
    );
  }

  final sharedDir = sharedDirOverride?.path ??
      '${packageDir.path}${Platform.pathSeparator}.dart_tool'
      '${Platform.pathSeparator}hooks_runner${Platform.pathSeparator}shared';

  final downloaded = <String>[];
  final skipped = <String>[];
  for (final target in targets) {
    final assetName = assetFilenameFor(target.os, target.arch);
    final expectedSha256 = hashes.assetNameToSha256Hash[assetName];
    if (expectedSha256 == null) {
      throw PrewarmException(
        'no pinned hash for $assetName in ${hashesSource.path} '
        '(releaseTag ${hashes.releaseTag}) — the target is not part of this '
        'sqlite3 release; drop it from --targets or file the mapping upstream',
      );
    }
    final destination = File(
      cachedFilePath(
        sharedDir: sharedDir,
        sha256: expectedSha256,
        os: target.os,
      ),
    );
    if (destination.existsSync()) {
      final cached = crypto.sha256.convert(destination.readAsBytesSync()).toString();
      if (cached == expectedSha256) {
        note('sqlite3 hook prewarm: ${destination.path} already verified — skip');
        skipped.add(assetName);
        continue;
      }
      note(
        'sqlite3 hook prewarm: ${destination.path} exists but its hash does '
        'not match the pin — replacing (stale or torn write)',
      );
    }
    final uri = downloadUriFor(
      hashes: hashes,
      urlPattern: urlPatternOverride,
      assetName: assetName,
    );
    note('sqlite3 hook prewarm: fetching $assetName from $uri');
    await fetchVerified(
      fetch: fetchOverride ?? _defaultFetch,
      uri: uri,
      expectedSha256: expectedSha256,
      destination: destination,
      attempts: attempts,
      retryDelay: retryDelay,
      timeoutPerAttempt: timeoutPerAttempt,
      onNote: note,
    );
    downloaded.add(assetName);
  }
  return PrewarmReport(downloaded, skipped);
}

void main(List<String> args) {
  String? package;
  var targets = 'host';
  var attempts = 3;
  var retryDelaySeconds = 15;
  var urlPattern = defaultUrlPattern;
  Directory? sharedDirOverride;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String next(String flag) {
      if (i + 1 >= args.length) {
        stderr.writeln('::error::$flag requires a value');
        exit(2);
      }
      return args[++i];
    }

    switch (arg) {
      case '--package':
        package = next(arg);
      case '--targets':
        targets = next(arg);
      case '--attempts':
        attempts = int.parse(next(arg));
      case '--retry-delay-seconds':
        retryDelaySeconds = int.parse(next(arg));
      case '--url-pattern':
        urlPattern = next(arg);
      case '--shared-dir':
        sharedDirOverride = Directory(next(arg));
      default:
        stderr.writeln('::error::unknown argument $arg');
        exit(2);
    }
  }
  if (package == null) {
    stderr.writeln('::error::--package <dir> is required (the package whose '
        '.dart_tool/package_config.json resolves sqlite3)');
    exit(2);
  }

  final targetList = <PrewarmTarget>[];
  for (final token in targets.split(',')) {
    final trimmed = token.trim();
    if (trimmed.isEmpty) continue;
    targetList.addAll(expandTargets(trimmed));
  }

  runZoned<void>(() {
    prewarmPackage(
      packageDir: Directory(package!),
      targets: targetList,
      attempts: attempts,
      retryDelay: Duration(seconds: retryDelaySeconds),
      urlPatternOverride: urlPattern,
      sharedDirOverride: sharedDirOverride,
      onNote: (message) => stdout.writeln(message),
    ).then((report) {
      stdout.writeln(
        'sqlite3 hook prewarm: ${report.downloaded.length} fetched, '
        '${report.skipped.length} already verified '
        '(package $package, targets $targets)',
      );
    }).catchError((Object error) {
      stderr.writeln('::error::$error');
      exit(1);
    });
  });
}
