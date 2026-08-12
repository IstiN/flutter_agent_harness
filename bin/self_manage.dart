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

const _repo = 'IstiN/flutter_agent_harness';

void _say(String text) => stdout.writeln(text);
void _warn(String text) => stderr.writeln('fa: $text');

/// The host OS/arch pair as used in the release asset names.
String? _archiveName() {
  final abi = Abi.current().toString(); // e.g. windows_x64, macos_arm64
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
/// on shared IPs); the JSON API is the fallback.
Future<String?> _latestTag(http.Client client) async {
  final permalink = Uri.parse('https://github.com/$_repo/releases/latest');
  final request = http.Request('GET', permalink)..followRedirects = false;
  final redirected = await client.send(request);
  final location = redirected.headers['location'];
  if (location != null) {
    final match = RegExp(r'/releases/tag/([^/]+)').firstMatch(location);
    if (match != null) return match.group(1);
  }
  final response = await client.get(
    Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
    headers: {'Accept': 'application/vnd.github+json'},
  );
  if (response.statusCode != 200) return null;
  final body = jsonDecode(response.body);
  return body is Map<String, dynamic> ? body['tag_name'] as String? : null;
}

int _compareVersions(String a, String b) {
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
}) async {
  final install = detectInstall();
  if (install.kind == InstallKind.devRun) {
    _warn('fa update works for installed binaries, not source runs.');
    return 1;
  }

  final client = newClient();
  try {
    _say('current version: $currentVersion');
    final tag = await _latestTag(client);
    if (tag == null) {
      _warn('cannot reach GitHub Releases (network or rate limit)');
      return 1;
    }
    final latest = tag.replaceFirst('v', '');
    _say('latest release:  $latest');
    if (_compareVersions(latest, currentVersion) <= 0) {
      _say('already up to date.');
      return 0;
    }

    if (install.kind == InstallKind.pubGlobal) {
      return _pubGlobalUpdate(
        currentVersion: currentVersion,
        latest: latest,
        runProcess: runProcess,
      );
    }

    return _binaryUpdate(client, install, tag, latest, runProcess);
  } finally {
    client.close();
  }
}

/// Pub-global update path: re-activate the package, forcing a clean
/// re-activation first when pub believes a NEWER spec than the running
/// binary.
Future<int> _pubGlobalUpdate({
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
      _compareVersions(activeVersion, currentVersion) > 0) {
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
      _compareVersions(latest, activeVersion ?? currentVersion) > 0) {
    _say(
      'note: pub.dev lags behind GitHub ($latest available as a binary) — '
      'curl -fsSL https://fa1.dev/install.sh | sh',
    );
  }
  return result.exitCode;
}

/// Binary update path: download the release archive for this platform and
/// swap in the new binary + dylibs. Falls back to the macOS `.zip` asset
/// when the archive is missing from the release.
Future<int> _binaryUpdate(
  http.Client client,
  Install install,
  String tag,
  String latest,
  Future<ProcessResult> Function(String, List<String>) runProcess,
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
  final streamed = await client.send(request);
  if (streamed.statusCode == 200) {
    final bytes = await streamed.stream.toBytes();
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
  Future<ProcessResult> Function(String, List<String>) runProcess,
) async {
  final zipUrl = 'https://github.com/$_repo/releases/download/$tag/$zipAsset';
  final request = http.Request('GET', Uri.parse(zipUrl));
  final streamed = await client.send(request);
  if (streamed.statusCode != 200) {
    _warn('download failed (HTTP ${streamed.statusCode}): $zipUrl');
    return 1;
  }
  _say('extracting $zipAsset…');
  final bytes = await streamed.stream.toBytes();
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
