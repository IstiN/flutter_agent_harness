/// Platform [SecureKeyStore] backends (`dart:io`): macOS Keychain via the
/// `security` CLI, freedesktop Secret Service via `secret-tool` (libsecret),
/// and the Windows Credential Locker via PowerShell's WinRT `PasswordVault`.
///
/// Exported only from `lib/io.dart` — the core library stays pure Dart.
///
/// All entries are scoped to the service label `fah` and named after the
/// environment variable they back up (`OPENROUTER_API_KEY`, ...), so the
/// keychain mirrors the env-based resolution one-to-one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import 'secure_key_store.dart';

/// The service/account scope every backend namespaces its entries under.
const secureKeyServiceName = 'fah';

/// Result of one helper-process invocation.
final class SecureKeyRunResult {
  /// Creates a result with the process [exitCode] and captured [stdout].
  const SecureKeyRunResult(this.exitCode, this.stdout);

  /// The process exit code.
  final int exitCode;

  /// Captured standard output.
  final String stdout;
}

/// Runs one helper process for a [SecureKeyStore] backend, optionally piping
/// [stdin] and extending the child [environment]. Injectable so tests never
/// spawn real processes.
typedef SecureKeyRunner =
    Future<SecureKeyRunResult> Function(
      String executable,
      List<String> arguments, {
      String? stdin,
      Map<String, String>? environment,
    });

/// The default [SecureKeyRunner]: [Process.start] with optional stdin.
///
/// Bounded by [secureKeyProcessTimeout]: keychain operations can block on a
/// SYSTEM modal (e.g. macOS "Keychain Not Found" on a corrupt/missing login
/// keychain) — the wizard must degrade to session-only then, never hang
/// the CLI.
Future<SecureKeyRunResult> _processRunner(
  String executable,
  List<String> arguments, {
  String? stdin,
  Map<String, String>? environment,
}) async {
  Process process;
  try {
    process = await Process.start(
      executable,
      arguments,
      environment: environment,
    );
  } on Object {
    return const SecureKeyRunResult(-1, '');
  }
  if (stdin != null) {
    process.stdin.write(stdin);
  }
  unawaited(process.stdin.close());
  try {
    final stdout = await process.stdout
        .transform(utf8.decoder)
        .join()
        .timeout(secureKeyProcessTimeout);
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 1),
      onTimeout: () => -1,
    );
    return SecureKeyRunResult(exitCode, stdout);
  } on TimeoutException {
    process.kill();
    return const SecureKeyRunResult(-1, '');
  }
}

/// The per-invocation cap for helper processes (`security`, `secret-tool`,
/// `powershell.exe`) — they can block on a system keychain modal on a
/// broken keychain. Tests shorten it.
@visibleForTesting
Duration secureKeyProcessTimeout = const Duration(seconds: 15);

/// Direct access to the default runner for timeout tests.
@visibleForTesting
SecureKeyRunner secureKeyProcessRunner = _processRunner;

/// Picks the [SecureKeyStore] for the host OS. [platform] and [runner] are
/// test seams; production callers use the defaults.
SecureKeyStore platformSecureKeyStore({
  SecureKeyRunner? runner,
  String? platform,
}) {
  final run = runner ?? _processRunner;
  return switch (platform ?? Platform.operatingSystem) {
    'macos' => _MacosKeychainStore(run),
    'linux' => _LinuxSecretServiceStore(run),
    'windows' => _WindowsCredentialLockerStore(run),
    final other => _UnavailableSecureKeyStore(other),
  };
}

/// Key names mirror environment variables; the strict shape also keeps the
/// PowerShell backend safe from script injection through names.
final _namePattern = RegExp(r'^[A-Za-z0-9_]+$');

void _validateName(String name) {
  if (!_namePattern.hasMatch(name)) {
    throw ArgumentError.value(
      name,
      'name',
      'key names must match [A-Za-z0-9_]+',
    );
  }
}

/// Strips exactly one trailing newline (CRLF or LF) from helper output —
/// secrets themselves may legitimately contain spaces, so never trim().
String _output(String stdout) {
  if (stdout.endsWith('\r\n')) {
    return stdout.substring(0, stdout.length - 2);
  }
  if (stdout.endsWith('\n')) return stdout.substring(0, stdout.length - 1);
  return stdout;
}

/// macOS Keychain via the `security` CLI (generic-password items).
///
/// Note: `add-generic-password` takes the secret as an argv element, which
/// is briefly visible in the process list — the accepted trade-off of the
/// only always-present keychain interface on macOS (the alternative is
/// Security.framework FFI).
final class _MacosKeychainStore implements SecureKeyStore {
  const _MacosKeychainStore(this._run);

  final SecureKeyRunner _run;

  @override
  String get label => 'macOS Keychain';

  @override
  Future<bool> isAvailable() async {
    try {
      return (await _run('which', ['security'])).exitCode == 0;
    } on Object {
      return false;
    }
  }

  @override
  Future<String?> read(String name) async {
    _validateName(name);
    final result = await _run('security', [
      'find-generic-password',
      '-s',
      secureKeyServiceName,
      '-a',
      name,
      '-w',
    ]);
    if (result.exitCode != 0) return null;
    final value = _output(result.stdout);
    return value.isEmpty ? null : value;
  }

  @override
  Future<void> write(String name, String value) async {
    _validateName(name);
    final result = await _run('security', [
      'add-generic-password',
      '-s',
      secureKeyServiceName,
      '-a',
      name,
      '-w',
      value,
      '-U',
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'security add-generic-password failed '
        '(exit ${result.exitCode})',
      );
    }
  }

  @override
  Future<void> delete(String name) async {
    _validateName(name);
    // A missing entry exits non-zero; deleting is idempotent by design.
    await _run('security', [
      'delete-generic-password',
      '-s',
      secureKeyServiceName,
      '-a',
      name,
    ]);
  }
}

/// freedesktop Secret Service via `secret-tool` (libsecret): gnome-keyring,
/// KWallet, or KeePassXC on the session D-Bus. Hosts without the binary (or
/// without a session bus, e.g. headless servers) report unavailable.
final class _LinuxSecretServiceStore implements SecureKeyStore {
  const _LinuxSecretServiceStore(this._run);

  final SecureKeyRunner _run;

  static const _attributes = ['service', secureKeyServiceName];

  @override
  String get label => 'Secret Service';

  @override
  Future<bool> isAvailable() async {
    try {
      return (await _run('which', ['secret-tool'])).exitCode == 0;
    } on Object {
      return false;
    }
  }

  @override
  Future<String?> read(String name) async {
    _validateName(name);
    final result = await _run('secret-tool', [
      'lookup',
      ..._attributes,
      'name',
      name,
    ]);
    if (result.exitCode != 0) return null;
    final value = _output(result.stdout);
    return value.isEmpty ? null : value;
  }

  @override
  Future<void> write(String name, String value) async {
    _validateName(name);
    // The secret travels over stdin, never argv.
    final result = await _run('secret-tool', [
      'store',
      '--label=$secureKeyServiceName: $name',
      ..._attributes,
      'name',
      name,
    ], stdin: value);
    if (result.exitCode != 0) {
      throw StateError(
        'secret-tool store failed (exit ${result.exitCode}) — '
        'is a Secret Service provider (gnome-keyring/KWallet) running?',
      );
    }
  }

  @override
  Future<void> delete(String name) async {
    _validateName(name);
    await _run('secret-tool', ['clear', ..._attributes, 'name', name]);
  }
}

/// Windows Credential Locker via the WinRT `PasswordVault`, driven through
/// `powershell.exe` (present since Windows 10; `cmdkey` cannot read secrets
/// back, so it is not an option). The secret reaches the child through the
/// FAH_SECRET environment variable, never the command line.
final class _WindowsCredentialLockerStore implements SecureKeyStore {
  const _WindowsCredentialLockerStore(this._run);

  final SecureKeyRunner _run;

  static const _prologue =
      r"[Windows.Security.Credentials.PasswordVault,Windows.Security.Credentials,"
      'ContentType=WindowsRuntime] | Out-Null; '
      r'$v = New-Object Windows.Security.Credentials.PasswordVault; ';

  @override
  String get label => 'Windows Credential Locker';

  Future<SecureKeyRunResult> _ps(String script, {String? secret}) {
    return _run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ], environment: secret == null ? null : {'FAH_SECRET': secret});
  }

  @override
  Future<bool> isAvailable() async {
    try {
      return (await _ps(r'$PSVersionTable.PSVersion.Major')).exitCode == 0;
    } on Object {
      return false;
    }
  }

  @override
  Future<String?> read(String name) async {
    _validateName(name);
    final result = await _ps(
      "$_prologue try { "
      "\$c = \$v.Retrieve('$secureKeyServiceName','$name'); "
      r'$c.RetrievePassword(); $c.Password '
      "} catch { '' }",
    );
    if (result.exitCode != 0) return null;
    final value = _output(result.stdout);
    return value.isEmpty ? null : value;
  }

  @override
  Future<void> write(String name, String value) async {
    _validateName(name);
    final result = await _ps(
      "$_prologue try { \$v.Remove(\$v.Retrieve("
      "'$secureKeyServiceName','$name')) } catch {}; "
      r'$c = New-Object Windows.Security.Credentials.PasswordCredential('
      "'$secureKeyServiceName','$name',\$env:FAH_SECRET); "
      r'$v.Add($c)',
      secret: value,
    );
    if (result.exitCode != 0) {
      throw StateError('PasswordVault add failed (exit ${result.exitCode})');
    }
  }

  @override
  Future<void> delete(String name) async {
    _validateName(name);
    await _ps(
      "$_prologue try { \$v.Remove(\$v.Retrieve("
      "'$secureKeyServiceName','$name')) } catch {}",
    );
  }
}

/// Fallback for operating systems without a backend: always unavailable,
/// reads miss, writes throw (guarded by [SecureKeyCache.available]).
final class _UnavailableSecureKeyStore implements SecureKeyStore {
  const _UnavailableSecureKeyStore(this.platform);

  /// The unsupported platform name (`Platform.operatingSystem`).
  final String platform;

  @override
  String get label => 'secure storage';

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<String?> read(String name) async => null;

  @override
  Future<void> write(String name, String value) {
    throw UnsupportedError('no secure storage backend on $platform');
  }

  @override
  Future<void> delete(String name) {
    throw UnsupportedError('no secure storage backend on $platform');
  }
}
