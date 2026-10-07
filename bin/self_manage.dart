/// Self-management quick commands for the `fa` executable: `fa update`
/// (fetch and swap in the latest release binary) and `fa uninstall`
/// (remove the binary, its PATH entry, and — after a second confirmation —
/// the `~/.fah` data directory).
///
/// `dart:io` is allowed here (same as `fah.dart`): everything the core
/// library cannot touch directly (process env, the registry, files).
library;

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart'
    show RsaPublicKey, RsaSsaPkcs1v15, Signature;

const _repo = 'IstiN/flutter_agent_harness';

/// Network bounds for the self-update paths: metadata answers (latest
/// tag, manifest, signature) within [kFaUpdateNetworkTimeout]; the
/// archive body gets [kFaUpdateArchiveTimeout] (tens of MB on slow
/// links). Anything exceeding its bound aborts the update — fail-closed,
/// never a hang (issue #1377 review r4).

/// Metadata answers (latest tag, manifest, signature) must land within
/// this bound; slower means the update aborts, fail-closed.
const Duration kFaUpdateNetworkTimeout = Duration(seconds: 15);

/// The archive body bound (tens of MB on slow links).
const Duration kFaUpdateArchiveTimeout = Duration(minutes: 2);

void _say(String text) => stdout.writeln(text);
void _warn(String text) => stderr.writeln('fa: $text');

/// The host OS/arch pair as used in the release asset names.
String? _archiveName() => archiveNameFor(Abi.current().toString());

/// The release asset name for an OS/arch pair (`windows_x64`, `macos_arm64`,
/// … as `Abi.current()` reports them), or null when there is no prebuilt
/// archive for the platform.
String? archiveNameFor(String abi) {
  return switch (abi) {
    'windows_x64' => 'fa-windows-x64.zip',
    'macos_x64' => 'fa-macos-x64.tar.gz',
    'macos_arm64' => 'fa-macos-arm64.tar.gz',
    'linux_x64' => 'fa-linux-x64.tar.gz',
    'linux_arm64' => 'fa-linux-arm64.tar.gz',
    _ => null,
  };
}

/// How this fa was installed: a release binary, a `dart pub global`
/// activation, or a source/dev run (update/uninstall refuse the latter).
enum InstallKind { binary, pubGlobal, devRun }

/// The detected install (kind + executable path).
final class Install {
  /// Creates the install descriptor.
  const Install(this.kind, this.executable);

  /// How this fa was installed.
  final InstallKind kind;

  /// The executable to replace/remove (binary installs only).
  final String executable;
}

/// Magic bytes of native executables: Mach-O (32/64-bit + fat), ELF, PE.
const _nativeMagics = [
  [0xFE, 0xED, 0xFA, 0xCE], // Mach-O 32-bit
  [0xFE, 0xED, 0xFA, 0xCF], // Mach-O 64-bit
  [0xCE, 0xFA, 0xED, 0xFE], // Mach-O 32-bit (byte-swapped)
  [0xCF, 0xFA, 0xED, 0xFE], // Mach-O 64-bit (byte-swapped)
  [0xCA, 0xFE, 0xBA, 0xBE], // Mach-O fat
  [0x7F, 0x45, 0x4C, 0x46], // ELF
  [0x4D, 0x5A], // PE (MZ)
];

/// Whether [bytes] starts with [magic].
bool _matchesMagic(List<int> bytes, List<int> magic) {
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  return true;
}

bool _isNativeExecutable(String path) {
  final file = File(path);
  if (!file.existsSync()) return false;
  final bytes = file.openSync().readSync(4);
  return _nativeMagics.any((magic) => _matchesMagic(bytes, magic));
}

/// Classifies the install from the two platform paths (injectable for
/// tests): a `.dart` script is a dev run; a pub-cache path holding a pub
/// snapshot is a pub-global activation; anything else — including a NATIVE
/// AOT binary placed under pub-cache (installer/manual swap), which pub
/// cannot rebuild over ("Failed to decode data using encoding 'utf-8'") —
/// is a release binary.
Install classifyInstall({
  required String scriptPath,
  required String executablePath,
}) {
  if (scriptPath.endsWith('.dart')) {
    return Install(InstallKind.devRun, scriptPath);
  }
  final lower = executablePath.toLowerCase();
  if (lower.contains('pub-cache') || lower.contains(r'pub\cache')) {
    if (!_isNativeExecutable(executablePath)) {
      return Install(InstallKind.pubGlobal, executablePath);
    }
  }
  return Install(InstallKind.binary, executablePath);
}

Install _detectInstall() => classifyInstall(
  scriptPath: Platform.script.toFilePath(),
  executablePath: Platform.resolvedExecutable,
);

/// Fetches the latest release tag (e.g. `v0.1.44`). The HTML permalink's
/// 302 is tried first (the API's unauthenticated rate limit is easy to hit
/// on shared IPs); the JSON API is the fallback. Null when neither works.
///
/// [client] defaults to a fresh [http.Client] (closed before returning).
Future<String?> fetchLatestTag({http.Client? client}) async {
  final own = client ?? http.Client();
  try {
    final permalink = Uri.parse('https://github.com/$_repo/releases/latest');
    final request = http.Request('GET', permalink)..followRedirects = false;
    final redirected = await own.send(request);
    final location = redirected.headers['location'];
    if (location != null) {
      final match = RegExp(r'/releases/tag/([^/]+)').firstMatch(location);
      if (match != null) return match.group(1);
    }
    final response = await own.get(
      Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body);
    return body is Map<String, dynamic> ? body['tag_name'] as String? : null;
  } finally {
    if (client == null) own.close();
  }
}

/// Compares two dotted version strings (`v` prefix ignored, missing
/// components are zero): negative when [a] is older than [b], positive
/// when newer, zero when equal.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
    for (final piece in v.replaceFirst(RegExp('^v'), '').split('.'))
      int.tryParse(piece) ?? 0,
  ];
  final pa = parts(a);
  final pb = parts(b);
  for (var i = 0; i < pa.length || i < pb.length; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// The pinned release trust anchor — byte-identical to
/// TRUSTED_SIGNING_PEM in site/install.sh. Archives are only applied when
/// their signed SHA256SUMS verifies against this key.
const String kFaReleaseSigningPem = '-----BEGIN PUBLIC KEY-----\n'
    'MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA/F/wk8xOz9U/sjsGJKn2\n'
    'sDuqF3KxG8UXJsC95fSp6Bpm3hjPEVF1wsYycEy4KeCRpKBeyJGqhIoiEBeQBUgz\n'
    'NKEOjEoGuZxLgtOL2/0OkDVLpXA/q5gmdey0yWx+P5I9ShDMuQWgbG1wR55ti6lD\n'
    '0b/jhG9OUVTDjSDG2jvbxx27gAx1NMX6IgMAx6u3djYKyRMdj/DRqZXkv2cUO8RS\n'
    'elhwcSChDKrVjrIaFru8iw7eBS0c5SNV1D9qLESNklFR5tTf9R4Uv1/ixTIN56tk\n'
    'j8l7HrWT0NmFNU5d2sy33pbbsACqqGHSeCVnAEZmrn0vzZ25onFQbr68qIhPCQUq\n'
    'z7DTlxKxdRViEkZwRGpKTSWnS5stu/Y+ReD/XeZgKFduje98kcVvHFyyfaQt6Wee\n'
    '6ZO/s6AMByqPTI1eJCkxe53LkIiQs5py3a5whKrkPy99/C1uOrmGiJurA3luAbhD\n'
    'guzhAH54jqj2XuzD8HQujgq+5Edt80HK4jvfbzN3XQE+XQB7s10KAvAcmhoPONn3\n'
    'JctJXd6etpAaHg56YciFqzOa+/oyE4sgjunGqq0s4hx0ROHIhLC2almcekZFLEit\n'
    '+GmhARJnFP2Nem6owJ1PSYzIWT5zVjrA4pK4VJGA6EC2H2poBq4x7tkDugQYxdgC\n'
    'P2gLH2uyw0KaQBQa1CQVCnUCAwEAAQ==\n'
    '-----END PUBLIC KEY-----';

/// Whether two byte lists are identical.
bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Minimal DER reader: hands out the value octets of consecutive
/// tag-length-value elements.
final class _DerReader {
  _DerReader(this.bytes);

  final List<int> bytes;
  var pos = 0;

  /// Reads the next element — which must carry [tag] — and returns its
  /// value octets.
  List<int> take(int tag) {
    if (pos >= bytes.length || bytes[pos++] != tag) {
      throw const FormatException('unexpected DER tag');
    }
    var length = bytes[pos++];
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | bytes[pos++];
      }
    }
    final value = bytes.sublist(pos, pos + length);
    pos += length;
    return value;
  }
}

/// The rsaEncryption OID (1.2.840.113549.1.1.1) in DER form.
const _rsaEncryptionOid = [
  0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
];

/// Drops the sign padding of a DER positive INTEGER (one leading 0x00).
List<int> _unsignedInteger(List<int> bytes) =>
    bytes.length > 1 && bytes.first == 0 ? bytes.sublist(1) : bytes;

/// Parses a PEM `BEGIN PUBLIC KEY` (SPKI) RSA public key into its
/// modulus/exponent bytes. Public for the provenance tests.
RsaPublicKey rsaPublicKeyFromPem(String pem) {
  final base64Body = pem
      .split('\n')
      .where((line) => !line.startsWith('-----'))
      .join();
  final der = base64Decode(base64Body.replaceAll(RegExp(r'\s'), ''));
  final spki = _DerReader(der);
  // spki content: SEQUENCE{OID rsaEncryption, NULL}, BIT STRING{key}.
  final content = _DerReader(spki.take(0x30));
  final algorithm = _DerReader(content.take(0x30)); // AlgorithmIdentifier
  if (!_listEquals(algorithm.take(0x06), _rsaEncryptionOid)) {
    throw const FormatException('not an rsaEncryption SPKI');
  }
  // BIT STRING: one unused-bits octet, then SEQUENCE{INTEGER n, INTEGER e}.
  final rsa = _DerReader(
    _DerReader(content.take(0x03).sublist(1)).take(0x30),
  );
  return RsaPublicKey(
    n: _unsignedInteger(rsa.take(0x02)), // INTEGER modulus
    e: _unsignedInteger(rsa.take(0x02)), // INTEGER exponent
  );
}

/// The hex digest [archiveName] is listed with in a sha256sum-style
/// [manifest] (`<hex>  <name>`, the `*` binary-mode marker tolerated), or
/// null when it is not listed.
String? _manifestDigest(String manifest, String archiveName) {
  for (final line in manifest.split('\n')) {
    // sha256sum text mode emits TWO spaces between digest and name; the
    // `*` binary-mode marker is tolerated. Whitespace around the name is
    // never part of it.
    final match = RegExp(
      r'^([0-9a-fA-F]{64})[ \t]+\*?(.+?)[ \t]*$',
    ).firstMatch(line.trim());
    if (match != null && match.group(2) == archiveName) return match.group(1);
  }
  return null;
}

/// Verifies the release provenance of [archiveBytes]: fetches the
/// SHA256SUMS manifest of [tag] and its signature, checks the RSA
/// PKCS#1 v1.5 SHA-256 signature against the [pem] trust anchor, and
/// compares the manifest digest for [archiveName] with the archive.
/// False — never a throw — on ANY failure (missing assets, bad signature,
/// unlisted or mismatched digest), so a broken release is just an aborted
/// update.
Future<bool> verifyReleaseProvenance({
  required http.Client client,
  required String tag,
  required String archiveName,
  required List<int> archiveBytes,
  String pem = kFaReleaseSigningPem,
}) async {
  try {
    final sumsUri = Uri.parse(
      'https://github.com/$_repo/releases/download/$tag/SHA256SUMS',
    );
    final sums = await client
        .get(sumsUri)
        .timeout(kFaUpdateNetworkTimeout);
    final sig = await client
        .get(sumsUri.replace(path: '${sumsUri.path}.sig'))
        .timeout(kFaUpdateNetworkTimeout);
    if (sums.statusCode != 200 || sig.statusCode != 200) return false;
    final verified = await RsaSsaPkcs1v15.sha256().verify(
      sums.bodyBytes,
      signature: Signature(sig.bodyBytes, publicKey: rsaPublicKeyFromPem(pem)),
    );
    if (!verified) return false;
    final expected = _manifestDigest(sums.body, archiveName);
    if (expected == null) return false;
    return sha256.convert(archiveBytes).toString() ==
        expected.toLowerCase();
  } catch (_) {
    return false;
  }
}

/// `fa update`: downloads the latest release binary for this platform and
/// swaps it in (atomic rename on Unix; rename-aside of the locked exe on
/// Windows). Pub-global installs re-activate; dev runs are refused.
///
/// [detectInstall], [newClient], and [runProcess] are test seams; the
/// defaults are the real platform behavior.
Future<int> runSelfUpdate({
  required String currentVersion,
  Install Function() detectInstall = _detectInstall,
  http.Client Function() newClient = http.Client.new,
  Future<ProcessResult> Function(String, List<String>) runProcess = Process.run,
  String pem = kFaReleaseSigningPem,
}) async {
  final install = detectInstall();
  if (install.kind == InstallKind.devRun) {
    _warn('fa update works for installed binaries, not source runs.');
    return 1;
  }

  final client = newClient();
  try {
    _say('current version: $currentVersion');
    final tag = await fetchLatestTag(client: client);
    if (tag == null) {
      _warn('cannot reach GitHub Releases (network or rate limit)');
      return 1;
    }
    final latest = tag.replaceFirst('v', '');
    _say('latest release:  $latest');
    if (compareVersions(latest, currentVersion) <= 0) {
      _say('already up to date.');
      return 0;
    }

    if (install.kind == InstallKind.pubGlobal) {
      return (await _pubGlobalUpdate(
        currentVersion: currentVersion,
        latest: latest,
        runProcess: runProcess,
      )).$1;
    }

    return await _binaryUpdate(client, install, tag, latest, runProcess, pem);
  } finally {
    client.close();
  }
}

/// Pub-global update path: re-activate the package, forcing a clean
/// re-activation first when pub believes a NEWER spec than the running
/// binary.
Future<(int, String?)> _pubGlobalUpdate({
  required String currentVersion,
  required String latest,
  required Future<ProcessResult> Function(String, List<String>) runProcess,
}) async {
  _say('updating via dart pub global activate…');
  // A stale or half-written snapshot: pub believes a NEWER spec than the
  // running binary, so a plain activate no-ops (or chokes decoding the
  // old snapshot). Force a clean re-activation then.
  final listed = await runProcess('dart', ['pub', 'global', 'list']);
  final activeVersion = RegExp(
    r'flutter_agent_harness\s+(\d+\.\d+\.\d+)',
  ).firstMatch('${listed.stdout}${listed.stderr}')?.group(1);
  if (activeVersion != null &&
      compareVersions(activeVersion, currentVersion) > 0) {
    _say(
      'rebuilding the activated snapshot '
      '(spec $activeVersion, running $currentVersion)…',
    );
    final deactivate = await runProcess('dart', [
      'pub',
      'global',
      'deactivate',
      'flutter_agent_harness',
    ]);
    stdout.write(deactivate.stdout);
    stderr.write(deactivate.stderr);
  }
  final result = await runProcess('dart', [
    'pub',
    'global',
    'activate',
    'flutter_agent_harness',
  ]);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode == 0 &&
      compareVersions(latest, activeVersion ?? currentVersion) > 0) {
    _say(
      'note: pub.dev lags behind GitHub ($latest available as a binary) — '
      'curl -fsSL https://fa1.dev/install.sh | sh',
    );
  }
  final activated = RegExp(
    r'[Aa]ctivated flutter_agent_harness (\d+\.\d+\.\d+)',
  ).firstMatch('${result.stdout}${result.stderr}')?.group(1);
  return (result.exitCode, activated);
}

/// Binary update path: download the release archive for this platform,
/// verify its provenance, and swap in the new binary + dylibs. Falls back
/// to the macOS `.zip` asset when the archive is missing from the release.
Future<int> _binaryUpdate(
  http.Client client,
  Install install,
  String tag,
  String latest,
  Future<ProcessResult> Function(String, List<String>) runProcess,
  String pem,
) async {
  final archive = _archiveName();
  if (archive == null) {
    _warn('no prebuilt archive for this platform — install via Dart instead');
    return 1;
  }
  final target = install.executable;
  final installDir = File(target).parent;
  final url = 'https://github.com/$_repo/releases/download/$tag/$archive';
  _say('downloading $archive…');
  final request = http.Request('GET', Uri.parse(url));
  final http.StreamedResponse streamed;
  try {
    streamed = await client.send(request).timeout(kFaUpdateNetworkTimeout);
  } on Exception catch (error) {
    _warn('download failed (network): $error');
    return 1;
  }
  if (streamed.statusCode == 200) {
    final List<int> bytes;
    try {
      bytes = await streamed.stream.toBytes().timeout(kFaUpdateArchiveTimeout);
    } on Exception catch (error) {
      _warn('download failed (network): $error');
      return 1;
    }
    if (!await verifyReleaseProvenance(
      client: client,
      tag: tag,
      archiveName: archive,
      archiveBytes: bytes,
      pem: pem,
    )) {
      _warn('update aborted: release provenance check failed for $archive');
      return 1;
    }
    return _extractAndSwap(
      bytes,
      archive,
      target,
      installDir,
      latest,
      runProcess,
    );
  }
  // Fallback: macOS release may only have the versioned .zip (the sandboxed
  // app bundle). Try the stable zip name and extract the binary from the app bundle.
  if (Platform.isMacOS) {
    final zipAsset = _zipAssetName();
    if (zipAsset != null) {
      _say('archive not found — trying $zipAsset…');
      return fallbackZipUpdate(
        client,
        tag,
        zipAsset,
        target,
        latest,
        runProcess,
      );
    }
  }
  _warn('download failed (HTTP ${streamed.statusCode}): $url');
  return 1;
}

/// The stable zip asset name for macOS (uploaded by build-macos.yml).
String? _zipAssetName() {
  final abi = Abi.current().toString();
  return switch (abi) {
    'macos_arm64' => 'fa-macos-arm64-mac.zip',
    'macos_x64' => 'fa-macos-x64-mac.zip',
    _ => null,
  };
}

/// Extracts the `Fa.app/Contents/MacOS/Fa` binary bytes from a decoded
/// macOS `.zip` archive, or `null` if the entry is missing.
List<int>? _extractMacBinary(Archive archive) {
  for (final entry in archive) {
    if (entry.name.endsWith('Contents/MacOS/Fa') && entry.isFile) {
      return entry.content as List<int>;
    }
  }
  return null;
}

/// Atomically replaces [target] with the file at [staging]. On Windows the
/// locked executable is moved aside first; on Unix [staging] is renamed over
/// [target] and made executable.
Future<void> _atomicSwap(
  String staging,
  String target,
  Future<ProcessResult> Function(String, List<String>) runProcess,
) async {
  if (Platform.isWindows) {
    final aside = '$target.old';
    try {
      File(aside).deleteSync();
    } on PathNotFoundException {
      // No stale aside file to clean up — safe to proceed.
    }
    File(target).renameSync(aside);
    File(staging).renameSync(target);
  } else {
    if (File(target).existsSync()) {
      // One-generation rollback copy, overwritten on every update.
      await File(target).copy('$target.bak');
    }
    await File(staging).rename(target);
    await runProcess('chmod', ['+x', target]);
  }
}

/// Extracts a tar.gz archive into [tmpDir] via the system `tar` command.
///
/// Returns `null` on success, or an error message string on failure.
Future<String?> _extractTarGz(
  List<int> archiveBytes,
  String archiveName,
  Directory tmpDir,
  Future<ProcessResult> Function(String, List<String>) runProcess,
) async {
  final archiveFile = File('${tmpDir.path}/bundle.tar.gz');
  await archiveFile.writeAsBytes(archiveBytes);
  final result = await runProcess('tar', [
    '-xzf',
    archiveFile.path,
    '-C',
    tmpDir.path,
  ]);
  return result.exitCode == 0 ? null : 'failed to extract $archiveName';
}

/// Extracts a zip archive into [tmpDir] in-process (no system command).
void _extractZip(List<int> archiveBytes, Directory tmpDir) {
  final archive = ZipDecoder().decodeBytes(archiveBytes);
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final parts = entry.name.split('/');
    final dest = File('${tmpDir.path}/${parts.join('/')}');
    dest.parent.createSync(recursive: true);
    dest.writeAsBytesSync(entry.content as List<int>);
  }
}

/// Extracts a tar.gz or zip archive into [tmpDir].
///
/// Returns `null` on success, or an error message string on failure.
Future<String?> extractArchive(
  List<int> archiveBytes,
  String archiveName,
  Directory tmpDir,
  Future<ProcessResult> Function(String, List<String>) runProcess,
) async {
  if (archiveName.endsWith('.tar.gz')) {
    return _extractTarGz(archiveBytes, archiveName, tmpDir, runProcess);
  }
  if (archiveName.endsWith('.zip')) {
    _extractZip(archiveBytes, tmpDir);
    return null;
  }
  return 'unknown archive format: $archiveName';
}

/// Copies the `bundle/lib/` shared libraries next to the binary.
Future<void> _copyBundleLibs(Directory bundleDir, Directory installDir) async {
  final srcLib = Directory('${bundleDir.path}/lib');
  if (!srcLib.existsSync()) return;
  final libDir = Directory('${installDir.path}/lib');
  libDir.createSync(recursive: true);
  await for (final entity in srcLib.list()) {
    if (entity is File) {
      await entity.copy('${libDir.path}/${entity.uri.pathSegments.last}');
    }
  }
}

/// Extracts the downloaded archive and swaps the binary + dylibs in place.
///
/// The archive contains a `bundle/` directory with `bin/fa[.exe]` and
/// `lib/*.dylib|.so|.dll`. We extract to a temp dir, copy the binary over
/// the target, and copy the lib files next to it.
Future<int> _extractAndSwap(
  List<int> archiveBytes,
  String archiveName,
  String target,
  Directory installDir,
  String latest,
  Future<ProcessResult> Function(String, List<String>) runProcess,
) async {
  final tmpDir = Directory.systemTemp.createTempSync('fa-update');
  try {
    final extractError = await extractArchive(
      archiveBytes,
      archiveName,
      tmpDir,
      runProcess,
    );
    if (extractError != null) {
      _warn(extractError);
      return 1;
    }
    final bundleDir = Directory('${tmpDir.path}/bundle');
    if (!bundleDir.existsSync()) {
      _warn('archive did not contain a bundle/ directory');
      return 1;
    }
    final exeName = Platform.isWindows ? 'fa.exe' : 'fa';
    final srcExe = File('${bundleDir.path}/bin/$exeName');
    if (!srcExe.existsSync()) {
      _warn('archive did not contain bundle/bin/$exeName');
      return 1;
    }
    final staging = '$target.new';
    await File(staging).writeAsBytes(srcExe.readAsBytesSync());
    await _atomicSwap(staging, target, runProcess);
    await _copyBundleLibs(bundleDir, installDir);
    // Copy version.txt so the new binary reports its version correctly.
    final srcVersion = File('${bundleDir.path}/version.txt');
    if (srcVersion.existsSync()) {
      await File(
        '${installDir.path}/version.txt',
      ).writeAsBytes(srcVersion.readAsBytesSync());
    }
    _say('updated to $latest — restart fa to use it.');
    return 0;
  } finally {
    await tmpDir.delete(recursive: true);
  }
}

/// Downloads the [zipAsset] (a `.zip` containing `Fa.app`), extracts the
/// binary from `Fa.app/Contents/MacOS/Fa`, and swaps it in.
///
/// Public only so the self-management unit tests can exercise the macOS
/// zip fallback path on non-macOS hosts; not intended for external callers.
Future<int> fallbackZipUpdate(
  http.Client client,
  String tag,
  String zipAsset,
  String target,
  String latest,
  Future<ProcessResult> Function(String, List<String>) runProcess, {
  String pem = kFaReleaseSigningPem,
}) async {
  final zipUrl = 'https://github.com/$_repo/releases/download/$tag/$zipAsset';
  final request = http.Request('GET', Uri.parse(zipUrl));
  final http.StreamedResponse streamed;
  try {
    streamed = await client.send(request).timeout(kFaUpdateNetworkTimeout);
  } on Exception catch (error) {
    _warn('download failed (network): $error');
    return 1;
  }
  if (streamed.statusCode != 200) {
    _warn('download failed (HTTP ${streamed.statusCode}): $zipUrl');
    return 1;
  }
  _say('extracting $zipAsset…');
  final List<int> bytes;
  try {
    bytes = await streamed.stream.toBytes().timeout(kFaUpdateArchiveTimeout);
  } on Exception catch (error) {
    _warn('download failed (network): $error');
    return 1;
  }
  if (!await verifyReleaseProvenance(
    client: client,
    tag: tag,
    archiveName: zipAsset,
    archiveBytes: bytes,
    pem: pem,
  )) {
    _warn('update aborted: release provenance check failed for $zipAsset');
    return 1;
  }
  final archive = ZipDecoder().decodeBytes(bytes.toList());
  final data = _extractMacBinary(archive);
  if (data == null) {
    _warn('could not find Fa binary inside $zipAsset');
    return 1;
  }
  final staging = '$target.new';
  await File(staging).writeAsBytes(data);
  await _atomicSwap(staging, target, runProcess);
  _say('updated to $latest — restart fa to use it.');
  return 0;
}

/// The successor argv for a restart ([applyUpdate]'s `launchArgs` input):
/// the ORIGINAL argv with `--session <sessionId>` appended when the id is
/// known and the argv does not already carry one — a live session must
/// survive the restart (issue #1377: same terminal, same session).
List<String> successorArgs(List<String> args, String? sessionId) {
  final carriesSession = args.any(
    (arg) => arg == '--session' || arg.startsWith('--session='),
  );
  if (sessionId == null || carriesSession) return args;
  return [...args, '--session', sessionId];
}

/// The default convergence-guard state file (`~/.fah/update-state.json`);
/// null when the host has no home directory (guard disabled, disclosed).
String? _convergenceStatePath() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) return null;
  return '$home/.fah/update-state.json';
}

/// Reads the convergence-guard state: the tag the updater last attempted
/// and how many times. Null when absent/corrupt (a fresh attempt is then
/// allowed — the guard caps REPEAT attempts, not first ones).
({String tag, int attempts})? _readConvergence(String? statePath) {
  if (statePath == null) return null;
  try {
    final doc = jsonDecode(File(statePath).readAsStringSync());
    final tag = doc is Map<String, dynamic> ? doc['tag'] : null;
    if (tag is String && tag.isNotEmpty) {
      return (tag: tag, attempts: (doc['attempts'] as int?) ?? 0);
    }
  } catch (_) {
    // Corrupt/missing state: the guard opens (a first attempt is honest).
  }
  return null;
}

/// Records an attempt to reach [tag] in the convergence-guard state.
void _writeConvergence(String? statePath, String tag) {
  if (statePath == null) return;
  try {
    final previous = _readConvergence(statePath);
    final attempts =
        previous != null && previous.tag == tag ? previous.attempts + 1 : 1;
    final file = File(statePath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode({'tag': tag, 'attempts': attempts}));
  } catch (_) {
    // The guard must never break the update it guards.
  }
}

/// Clears the convergence-guard state: a boot that finds itself up to
/// date closes the loop, so a FUTURE release gets its attempts back.
void _clearConvergence(String? statePath) {
  if (statePath == null) return;
  try {
    File(statePath).deleteSync();
  } on FileSystemException {
    // Nothing to clear.
  } catch (_) {
    // The guard must never break the boot.
  }
}

/// The result of [applyUpdate], the autonomous update path
/// (`auto_update: on` at boot, `/update` in a session).
enum ApplyUpdateOutcome {
  applied,
  upToDate,
  refusedDevRun,
  provenanceFailed,
  downloadFailed,
  unsupportedPlatform,
  restartFailed,
  convergenceGuard,
}

/// Updates fa autonomously: fetch the latest tag, download and VERIFY the
/// release archive, swap it in, and spawn the successor with [launchArgs]
/// (the ORIGINAL argv, so the session resumes through the new process).
/// Never throws; every failure is an outcome and the current binary keeps
/// running. A restart failure leaves the new binary in place, with
/// `<target>.bak` for manual rollback.
///
/// [detectInstall], [newClient], [runProcess], [spawn], [pem],
/// [settleDelay], and [logLine] are test seams; the defaults are the real
/// platform behavior.
Future<ApplyUpdateOutcome> applyUpdate({
  required String currentVersion,
  required List<String> launchArgs,
  Install Function()? detectInstall,
  http.Client Function()? newClient,
  Future<ProcessResult> Function(String, List<String>)? runProcess,
  Future<bool> Function(String, List<String>)? spawn,
  String pem = kFaReleaseSigningPem,
  Duration settleDelay = const Duration(seconds: 2),
  void Function(String message)? logLine,
  String? statePath,
  Duration networkTimeout = kFaUpdateNetworkTimeout,
}) async {
  final install = (detectInstall ?? _detectInstall)();
  if (install.kind == InstallKind.devRun) {
    return ApplyUpdateOutcome.refusedDevRun;
  }
  final log = logLine ?? logUpdateLine;
  final state = statePath ?? _convergenceStatePath();
  final client = (newClient ?? http.Client.new)();
  try {
    final tag = await fetchLatestTag(
      client: client,
    ).timeout(networkTimeout, onTimeout: () => null);
    if (tag == null) return ApplyUpdateOutcome.downloadFailed;
    final latest = tag.replaceFirst('v', '');
    if (compareVersions(latest, currentVersion) <= 0) {
      // Up to date: the loop is closed — a future release gets its
      // attempts back.
      _clearConvergence(state);
      return ApplyUpdateOutcome.upToDate;
    }

    // Convergence guard (issue #1377): auto_update:on + a channel that
    // lags (pub.dev propagation, stale release assets) must not respawn
    // forever. Two attempts per target tag; the state clears as soon as
    // a boot reports up to date.
    final convergence = _readConvergence(state);
    if (convergence != null &&
        convergence.tag == tag &&
        convergence.attempts >= 2) {
      log(
        'fa update paused: v$latest attempted ${convergence.attempts}× '
        'and still not resolving — not respawning again',
      );
      return ApplyUpdateOutcome.convergenceGuard;
    }
    _writeConvergence(state, tag);

    if (install.kind == InstallKind.pubGlobal) {
      final pub = await _pubGlobalUpdate(
        currentVersion: currentVersion,
        latest: latest,
        runProcess: runProcess ?? Process.run,
      );
      if (pub.$1 != 0) return ApplyUpdateOutcome.downloadFailed;
      final activated = pub.$2;
      if (activated != null &&
          compareVersions(activated, currentVersion) > 0) {
        log('fa update applied: v$currentVersion -> v$activated');
      } else {
        // pub exit 0 without an advance (propagation lag): a respawn
        // would reboot the SAME binary — say so instead of lying about an
        // applied version (issue #1377 review r4).
        log(
          'fa update: pub resolved v${activated ?? currentVersion} '
          '(release v$latest not on pub.dev yet)',
        );
        return ApplyUpdateOutcome.convergenceGuard;
      }
      final restarted = await _restartAfterUpdate(
        install,
        launchArgs,
        spawn: spawn,
        settleDelay: settleDelay,
        logLine: log,
      );
      return restarted
          ? ApplyUpdateOutcome.applied
          : ApplyUpdateOutcome.restartFailed;
    }

    final archive = _archiveName();
    if (archive == null) {
      // Unspawned, unprompted and UNPRINTED otherwise: say why nothing
      // happened (unknown linux arch, freebsd, …) instead of a silent
      // no-op.
      _warn(
        'no prebuilt fa archive for this platform — install via '
        '`dart pub global activate flutter_agent_harness` instead',
      );
      return ApplyUpdateOutcome.unsupportedPlatform;
    }
    final url = 'https://github.com/$_repo/releases/download/$tag/$archive';
    final streamed = await client
        .send(http.Request('GET', Uri.parse(url)))
        .timeout(networkTimeout);
    if (streamed.statusCode != 200) {
      return ApplyUpdateOutcome.downloadFailed;
    }
    final bytes = await streamed.stream
        .toBytes()
        .timeout(kFaUpdateArchiveTimeout);
    if (!await verifyReleaseProvenance(
      client: client,
      tag: tag,
      archiveName: archive,
      archiveBytes: bytes,
      pem: pem,
    )) {
      return ApplyUpdateOutcome.provenanceFailed;
    }
    final swapCode = await _extractAndSwap(
      bytes,
      archive,
      install.executable,
      File(install.executable).parent,
      latest,
      runProcess ?? Process.run,
    );
    if (swapCode != 0) return ApplyUpdateOutcome.downloadFailed;
    log('fa update applied: v$currentVersion -> v$latest');
    if (Platform.isWindows) {
      // The locked exe cannot relaunch the session here; the swap already
      // printed the restart hint.
      return ApplyUpdateOutcome.unsupportedPlatform;
    }
    final restarted = await _restartAfterUpdate(
      install,
      launchArgs,
      spawn: spawn,
      settleDelay: settleDelay,
      logLine: log,
    );
    return restarted
        ? ApplyUpdateOutcome.applied
        : ApplyUpdateOutcome.restartFailed;
  } catch (_) {
    // The update must never crash the boot: any surprise (socket reset,
    // file error) is just a failed update.
    return ApplyUpdateOutcome.downloadFailed;
  } finally {
    client.close();
  }
}

/// Restarts fa after a successful update: the injected [spawn] seam for
/// binary installs, [spawnSuccessor] (which detects the install kind)
/// otherwise. A false result is logged and warned about exactly once —
/// the new binary stays installed.
Future<bool> _restartAfterUpdate(
  Install install,
  List<String> launchArgs, {
  Future<bool> Function(String, List<String>)? spawn,
  required Duration settleDelay,
  required void Function(String) logLine,
}) async {
  var restarted = false;
  if (spawn != null) {
    // Test seam: the injected spawner covers BOTH install kinds. The exe
    // follows the same rule the real path uses — the swapped AOT binary
    // for release installs, the `fa` PATH shim for pub-global ones.
    final exe = install.kind == InstallKind.binary
        ? Platform.resolvedExecutable
        : (_whichFa() ?? 'fa');
    restarted = await spawn(exe, launchArgs);
  } else {
    restarted = await spawnSuccessor(
      launchArgs: launchArgs,
      settleDelay: settleDelay,
    );
  }
  if (restarted) return true;
  logLine('fa update restart failed');
  _warn('installed the new fa but the restart failed — start fa manually.');
  return false;
}

/// Starts [exe] with [args]: the successor owns the terminal (stdio
/// inherited) and outlives this process — the spawn-successor-then-exit
/// restart contract (Dart has no exec-replace).
Future<Process> _startSuccessor(String exe, List<String> args) {
  return Process.start(
    exe,
    args,
    mode: ProcessStartMode.detachedWithStdio,
  );
}

/// Spawns the freshly installed fa over this one. [launchArgs] is the
/// ORIGINAL argv, so the successor resumes the same session (the session
/// flag rides along). Binary installs exec the swapped binary directly;
/// pub-global installs exec the `fa` shim from PATH, which now points at
/// the re-activated snapshot (a plain `'fa'` when PATH has no shim). After
/// [settleDelay], a successor that already exited non-zero counts as a
/// failed restart; anything still running counts as started.
Future<bool> spawnSuccessor({
  required List<String> launchArgs,
  Future<Process> Function(String, List<String>)? spawn,
  Duration settleDelay = const Duration(seconds: 2),
}) async {
  final exe = _detectInstall().kind == InstallKind.binary
      ? Platform.resolvedExecutable
      : (_whichFa() ?? 'fa');
  try {
    final process = await (spawn ?? _startSuccessor)(exe, launchArgs);
    await Future<void>.delayed(settleDelay);
    final exitCode = await process.exitCode
        .then<int?>((code) => code)
        .timeout(Duration.zero, onTimeout: () => null);
    return exitCode == null || exitCode == 0;
  } catch (_) {
    return false; // Nothing was spawned.
  }
}

/// Locates the `fa` launcher on PATH (the pub-global shim), or null.
String? _whichFa() {
  final path = Platform.environment['PATH'] ?? '';
  for (final rawEntry in path.split(Platform.isWindows ? ';' : ':')) {
    final entry = rawEntry.trim();
    if (entry.isEmpty) continue;
    final candidate = File('$entry/fa${Platform.isWindows ? '.exe' : ''}');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

/// Appends `<ISO timestamp> <message>` to `~/.fah/logs/fa.log`, creating
/// `~/.fah/logs` on the way — the same file and line format the CLI's
/// diagnostic log uses. Never throws: the log must not break the CLI.
void logUpdateLine(String message, {String? home}) {
  try {
    final root =
        home ??
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
    if (root == null || root.isEmpty) return;
    final dir = Directory('$root/.fah/logs')..createSync(recursive: true);
    File('${dir.path}/fa.log').writeAsStringSync(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
    );
  } catch (_) {
    // Diagnostics must never break the CLI.
  }
}

/// Whether a terminal answer is an affirmative `y`/`yes` (any casing,
/// surrounding whitespace ignored); null/anything else is a NO.
bool isYesAnswer(String? answer) {
  final normalized = answer?.trim().toLowerCase();
  return normalized == 'y' || normalized == 'yes';
}

/// Reads a y/N answer from the terminal; non-interactive input defaults to
/// NO (safe for pipes/CI).
Future<bool> _confirm(String question) async {
  if (!stdin.hasTerminal) {
    _warn('$question — cannot ask without a terminal; aborted (safe).');
    return false;
  }
  stdout.write('$question [y/N] ');
  return isYesAnswer(stdin.readLineSync(encoding: utf8));
}

/// `fa uninstall`: confirmation, PATH cleanup, binary removal, and an
/// optional second confirmation for the `~/.fah` data directory.
///
/// [detectInstall], [confirm], [runProcess], and [environment] are test
/// seams; the defaults are the real platform behavior.
Future<int> runSelfUninstall({
  Install Function() detectInstall = _detectInstall,
  Future<bool> Function(String) confirm = _confirm,
  Future<ProcessResult> Function(String, List<String>) runProcess = Process.run,
  Map<String, String>? environment,
}) async {
  final install = detectInstall();
  if (install.kind == InstallKind.devRun) {
    _warn('fa uninstall works for installed binaries, not source runs.');
    return 1;
  }

  if (!await confirm('Uninstall fa (binary + PATH entry)?')) {
    _say('aborted.');
    return 1;
  }

  if (install.kind == InstallKind.pubGlobal) {
    await _pubGlobalDeactivate(runProcess);
  } else {
    _removeBinaryInstall(install);
  }

  await _maybeRemoveDataDir(confirm, environment);
  _say('fa uninstalled.');
  return 0;
}

/// Pub-global uninstall path: deactivate the activated package.
Future<void> _pubGlobalDeactivate(
  Future<ProcessResult> Function(String, List<String>) runProcess,
) async {
  _say('deactivating via dart pub global…');
  final result = await runProcess('dart', [
    'pub',
    'global',
    'deactivate',
    'flutter_agent_harness',
  ]);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
}

/// Binary uninstall path: the Windows user-PATH entry, the executable,
/// and — on Windows — the whole `%LOCALAPPDATA%\Fa` directory.
void _removeBinaryInstall(Install install) {
  final exe = File(install.executable);
  final windowsRoot = _windowsInstallRoot(install);
  if (Platform.isWindows) {
    _removeFromUserPath(File(install.executable).parent.path);
  }
  if (exe.existsSync()) exe.deleteSync();
  if (windowsRoot != null && windowsRoot.existsSync()) {
    windowsRoot.deleteSync(recursive: true);
  }
  _say('removed ${install.executable}');
}

/// The install root to remove on Windows: the release layout is
/// `%LOCALAPPDATA%\Fa\bin\fa.exe`, so the whole Fa directory (the
/// executable's grandparent) is ours; null elsewhere, where just the
/// binary file is.
Directory? _windowsInstallRoot(Install install) {
  return Platform.isWindows ? File(install.executable).parent.parent : null;
}

/// Offers to delete the `~/.fah` data directory (a second confirmation);
/// kept silently when declined or absent.
Future<void> _maybeRemoveDataDir(
  Future<bool> Function(String) confirm,
  Map<String, String>? environment,
) async {
  final env = environment ?? Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'];
  if (home != null && home.isNotEmpty) {
    final dataDir = Directory('$home/.fah');
    if (dataDir.existsSync() &&
        await confirm('Also delete $home/.fah (sessions, config, logs)?')) {
      dataDir.deleteSync(recursive: true);
      _say('removed ${dataDir.path}');
    } else if (dataDir.existsSync()) {
      _say('kept ${dataDir.path} (sessions and config preserved).');
    }
  }
}

/// Removes [binDir] from the Windows user PATH (registry), mirroring how
/// install.ps1 added it.
void _removeFromUserPath(String binDir) {
  final script =
      '\$p = [Environment]::GetEnvironmentVariable("Path", "User"); '
      '\$parts = \$p -split ";" | Where-Object { \$_ -and '
      '(\$_.TrimEnd("\\") -ne "$binDir".TrimEnd("\\")) }; '
      '[Environment]::SetEnvironmentVariable('
      '"Path", (\$parts -join ";"), "User")';
  try {
    Process.runSync('powershell', ['-NoProfile', '-Command', script]);
  } on ProcessException catch (error) {
    _warn('could not update the user PATH: $error');
  }
}
