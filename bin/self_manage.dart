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

const _repo = 'IstiN/flutter_agent_harness';

void _say(String text) => stdout.writeln(text);
void _warn(String text) => stderr.writeln('fa: $text');

/// The host OS/arch pair as used in the release asset names.
String? _assetName() {
  final abi = Abi.current().toString(); // e.g. windows_x64, macos_arm64
  return switch (abi) {
    'windows_x64' => 'fa-windows-x64.exe',
    'macos_x64' => 'fa-macos-x64',
    'macos_arm64' => 'fa-macos-arm64',
    'linux_x64' => 'fa-linux-x64',
    'linux_arm64' => 'fa-linux-arm64',
    _ => null,
  };
}

/// How this fa was installed: a release binary, a `dart pub global`
/// activation, or a source/dev run (update/uninstall refuse the latter).
enum _InstallKind { binary, pubGlobal, devRun }

final class _Install {
  const _Install(this.kind, this.executable);
  final _InstallKind kind;

  /// The executable to replace/remove (binary installs only).
  final String executable;
}

_Install _detectInstall() {
  final script = Platform.script.toFilePath();
  if (script.endsWith('.dart')) {
    return _Install(_InstallKind.devRun, script);
  }
  final exe = Platform.resolvedExecutable;
  final lower = exe.toLowerCase();
  if (lower.contains('pub-cache') || lower.contains(r'pub\cache')) {
    return _Install(_InstallKind.pubGlobal, exe);
  }
  return _Install(_InstallKind.binary, exe);
}

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
Future<int> runSelfUpdate({required String currentVersion}) async {
  final install = _detectInstall();
  if (install.kind == _InstallKind.devRun) {
    _warn('fa update works for installed binaries, not source runs.');
    return 1;
  }

  final client = http.Client();
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

    if (install.kind == _InstallKind.pubGlobal) {
      _say('updating via dart pub global activate…');
      // A stale or half-written snapshot: pub believes a NEWER spec than the
      // running binary, so a plain activate no-ops (or chokes decoding the
      // old snapshot). Force a clean re-activation then.
      final listed = await Process.run('dart', ['pub', 'global', 'list']);
      final activeVersion = RegExp(
        r'flutter_agent_harness\s+(\d+\.\d+\.\d+)',
      ).firstMatch('${listed.stdout}${listed.stderr}')?.group(1);
      if (activeVersion != null &&
          _compareVersions(activeVersion, currentVersion) > 0) {
        _say(
          'rebuilding the activated snapshot '
          '(spec $activeVersion, running $currentVersion)…',
        );
        final deactivate = await Process.run('dart', [
          'pub',
          'global',
          'deactivate',
          'flutter_agent_harness',
        ]);
        stdout.write(deactivate.stdout);
        stderr.write(deactivate.stderr);
      }
      final result = await Process.run('dart', [
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

    final asset = _assetName();
    if (asset == null) {
      _warn('no prebuilt binary for this platform — install via Dart instead');
      return 1;
    }
    final url = 'https://github.com/$_repo/releases/download/$tag/$asset';
    final target = install.executable;
    final staging = '$target.new';
    _say('downloading $asset…');
    final request = http.Request('GET', Uri.parse(url));
    final streamed = await client.send(request);
    if (streamed.statusCode != 200) {
      _warn('download failed (HTTP ${streamed.statusCode}): $url');
      return 1;
    }
    final sink = File(staging).openWrite();
    await streamed.stream.pipe(sink);
    await sink.close();

    if (Platform.isWindows) {
      // A running .exe cannot be overwritten, but it CAN be renamed aside.
      final aside = '$target.old';
      try {
        File(aside).deleteSync();
      } on PathNotFoundException {
        // Nothing to clean from a previous update.
      }
      File(target).renameSync(aside);
      File(staging).renameSync(target);
    } else {
      await File(staging).rename(target);
      await Process.run('chmod', ['+x', target]);
    }
    _say('updated to $latest — restart fa to use it.');
    return 0;
  } finally {
    client.close();
  }
}

/// Reads a y/N answer from the terminal; non-interactive input defaults to
/// NO (safe for pipes/CI).
Future<bool> _confirm(String question) async {
  if (!stdin.hasTerminal) {
    _warn('$question — cannot ask without a terminal; aborted (safe).');
    return false;
  }
  stdout.write('$question [y/N] ');
  final answer = stdin.readLineSync(encoding: utf8)?.trim().toLowerCase();
  return answer == 'y' || answer == 'yes';
}

/// `fa uninstall`: confirmation, PATH cleanup, binary removal, and an
/// optional second confirmation for the `~/.fah` data directory.
Future<int> runSelfUninstall() async {
  final install = _detectInstall();
  if (install.kind == _InstallKind.devRun) {
    _warn('fa uninstall works for installed binaries, not source runs.');
    return 1;
  }

  if (!await _confirm('Uninstall fa (binary + PATH entry)?')) {
    _say('aborted.');
    return 1;
  }

  if (install.kind == _InstallKind.pubGlobal) {
    _say('deactivating via dart pub global…');
    final result = await Process.run('dart', [
      'pub',
      'global',
      'deactivate',
      'flutter_agent_harness',
    ]);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
  } else {
    final exe = File(install.executable);
    // The release layout on Windows is %LOCALAPPDATA%\Fa\bin\fa.exe — drop
    // the whole Fa directory; on Unix just the binary file is ours.
    final windowsRoot = Platform.isWindows
        ? File(install.executable).parent.parent
        : null;
    if (Platform.isWindows) {
      _removeFromUserPath(File(install.executable).parent.path);
    }
    if (exe.existsSync()) exe.deleteSync();
    if (windowsRoot != null && windowsRoot.existsSync()) {
      windowsRoot.deleteSync(recursive: true);
    }
    _say('removed ${install.executable}');
  }

  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home != null && home.isNotEmpty) {
    final dataDir = Directory('$home/.fah');
    if (dataDir.existsSync() &&
        await _confirm('Also delete $home/.fah (sessions, config, logs)?')) {
      dataDir.deleteSync(recursive: true);
      _say('removed ${dataDir.path}');
    } else if (dataDir.existsSync()) {
      _say('kept ${dataDir.path} (sessions and config preserved).');
    }
  }
  _say('fa uninstalled.');
  return 0;
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
