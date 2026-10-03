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
  /// Creates a result with the process [exitCode], captured [stdout] and,
  /// since gh-1059, the captured [stderr] tail plus a [timedOut] marker —
  /// the diagnostics a bounded runner used to drop on the floor.
  const SecureKeyRunResult(
    this.exitCode,
    this.stdout, {
    this.stderr = '',
    this.timedOut = false,
  });

  /// The process exit code (-1 on spawn failure or helper timeout).
  final int exitCode;

  /// Captured standard output.
  final String stdout;

  /// Captured standard error, collapsed to a one-line tail (≤200 chars).
  /// Empty on spawn failures; may lag on a timeout kill. Never contains a
  /// secret (reads print secrets to stdout, errors to stderr).
  final String stderr;

  /// Whether the invocation hit [secureKeyProcessTimeout] and was killed.
  final bool timedOut;
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

/// The child environment for a helper spawn (gh-1059 H1): explicit
/// overrides RIDE the full inherited environment. A non-null map passed to
/// `Process.start` REPLACES the whole child environment — a helper spawned
/// without `PATH`/`HOME`/`SystemRoot` cannot run, which reads as a silent
/// keyless boot. Null stays null = full inheritance.
@visibleForTesting
Map<String, String>? secureKeyChildEnvironment(
  Map<String, String>? overrides,
) => overrides == null ? null : {...Platform.environment, ...overrides};

/// The default [SecureKeyRunner]: [Process.start] with optional stdin.
///
/// Bounded by [secureKeyProcessTimeout]: keychain operations can block on a
/// SYSTEM modal (e.g. macOS "Keychain Not Found" on a corrupt/missing login
/// keychain) — the wizard must degrade to session-only then, never hang
/// the CLI. stderr is drained concurrently with stdout (a helper blocked on
/// a full stderr pipe can never exit) and captured so read failures can
/// surface their diagnostics instead of collapsing into a bare null.
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
      environment: secureKeyChildEnvironment(environment),
    );
  } on Object {
    return const SecureKeyRunResult(-1, '');
  }
  if (stdin != null) {
    process.stdin.write(stdin);
  }
  unawaited(process.stdin.close());
  final stderrBuffer = StringBuffer();
  final stderrDone = process.stderr
      .transform(utf8.decoder)
      .listen(stderrBuffer.write)
      .asFuture<void>();
  Future<void> drainStderr() =>
      stderrDone.timeout(const Duration(seconds: 1), onTimeout: () {});
  try {
    final stdout = await process.stdout
        .transform(utf8.decoder)
        .join()
        .timeout(secureKeyProcessTimeout);
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 1),
      onTimeout: () => -1,
    );
    await drainStderr();
    return SecureKeyRunResult(
      exitCode,
      stdout,
      stderr: secureKeyDiagnosticLine(stderrBuffer.toString()),
    );
  } on TimeoutException {
    process.kill();
    await drainStderr();
    return SecureKeyRunResult(
      -1,
      '',
      stderr: secureKeyDiagnosticLine(stderrBuffer.toString()),
      timedOut: true,
    );
  }
}

/// One-line diagnostic for a failed read: [why] (exit code / timeout note)
/// plus the captured stderr tail when the helper wrote any.
String _errorTail(SecureKeyRunResult result, String why) =>
    result.stderr.isEmpty ? why : '$why: ${result.stderr}';

/// The shared read-classification ladder for all three backends (gh-1059
/// review — the contract lives in ONE place, the per-backend doc comments
/// only name their helper's exit codes):
///
/// - [SecureKeyRunResult.timedOut] → `error` (the modal-ate-the-read
///   state);
/// - non-zero exit outside [absentCodes] → `error` with the exit code and
///   stderr tail;
/// - empty stdout → `absent` (also reached for an [absentCodes] exit —
///   `security find-generic-password -w` prints nothing on a miss);
/// - otherwise `found` with the stripped stdout.
SecureKeyReadOutcome _classifyRead(
  SecureKeyRunResult result,
  String name, {
  Set<int> absentCodes = const {},
}) {
  if (result.timedOut) {
    return SecureKeyReadOutcome(
      name,
      SecureKeyReadStatus.error,
      error: _errorTail(
        result,
        'timed out after ${secureKeyProcessTimeout.inSeconds}s',
      ),
    );
  }
  if (result.exitCode != 0 && !absentCodes.contains(result.exitCode)) {
    return SecureKeyReadOutcome(
      name,
      SecureKeyReadStatus.error,
      error: _errorTail(result, 'exit ${result.exitCode}'),
    );
  }
  final value = _output(result.stdout);
  return value.isEmpty
      ? SecureKeyReadOutcome(name, SecureKeyReadStatus.absent)
      : SecureKeyReadOutcome(name, SecureKeyReadStatus.found, value: value);
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
final class _MacosKeychainStore
    implements SecureKeyStore, SecureKeyDiagnostics {
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
  Future<String?> read(String name) async => (await readDetailed(name)).value;

  /// `security find-generic-password` exit codes, classified (gh-1059):
  /// 0 = found (empty stdout reads as absent), 44 = the item is genuinely
  /// not stored, anything else (45 interaction-not-allowed, 51 locked
  /// keychain, …) plus a helper timeout or spawn failure is an ERROR with
  /// the stderr tail — never a bare "absent".
  @override
  Future<SecureKeyReadOutcome> readDetailed(String name) async {
    _validateName(name);
    final result = await _run('security', [
      'find-generic-password',
      '-s',
      secureKeyServiceName,
      '-a',
      name,
      '-w',
    ]);
    return _classifyRead(result, name, absentCodes: const {44});
  }

  @override
  Future<void> write(String name, String value) async {
    _validateName(name);
    // Preflight: with no default keychain (a broken/removed login keychain)
    // `add-generic-password` pops the system "Keychain Not Found" dialog
    // before failing — check quietly first so the caller degrades to
    // session-only without the prompt.
    final defaultKeychain = await _run('security', ['default-keychain']);
    if (defaultKeychain.exitCode != 0) {
      throw StateError(
        'no default keychain (exit ${defaultKeychain.exitCode})',
      );
    }
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
final class _LinuxSecretServiceStore
    implements SecureKeyStore, SecureKeyDiagnostics {
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
  Future<String?> read(String name) async => (await readDetailed(name)).value;

  /// `secret-tool lookup` exits 0 with empty output when the item is not
  /// stored — classified absent; a timeout / non-zero exit is an error.
  @override
  Future<SecureKeyReadOutcome> readDetailed(String name) async {
    _validateName(name);
    final result = await _run('secret-tool', [
      'lookup',
      ..._attributes,
      'name',
      name,
    ]);
    return _classifyRead(result, name);
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
final class _WindowsCredentialLockerStore
    implements SecureKeyStore, SecureKeyDiagnostics {
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
  Future<String?> read(String name) async => (await readDetailed(name)).value;

  /// The retrieve script catches its own errors and prints an empty line,
  /// so a stored-but-unreadable entry still exits 0 — classified absent;
  /// a timeout or a non-zero exit (PowerShell itself failed) is an error.
  @override
  Future<SecureKeyReadOutcome> readDetailed(String name) async {
    _validateName(name);
    final result = await _ps(
      "$_prologue try { "
      "\$c = \$v.Retrieve('$secureKeyServiceName','$name'); "
      r'$c.RetrievePassword(); $c.Password '
      "} catch { '' }",
    );
    return _classifyRead(result, name);
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
