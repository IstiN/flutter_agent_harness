// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'sandbox_builtins.dart';

/// Result of one remote command executed over SSH.
final class SandboxSshExecResult {
  /// Creates a result with raw [stdout]/[stderr] bytes and the remote
  /// [exitCode] (`null` when the server closed the channel without sending
  /// an exit status).
  const SandboxSshExecResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  /// Remote standard output bytes.
  final List<int> stdout;

  /// Remote standard error bytes.
  final List<int> stderr;

  /// Remote exit status, or `null` when the server did not report one.
  final int? exitCode;
}

/// Kind of a local (sandbox-side) filesystem entry.
enum SandboxSshEntryKind { file, directory }

/// Connection parameters for one SSH session, already resolved (identity
/// PEM, credentials, timeouts) by [SandboxSshBuiltins].
final class SandboxSshConnectParams {
  /// Creates the parameters for `username@host:port`.
  const SandboxSshConnectParams({
    required this.host,
    required this.port,
    required this.username,
    required this.connectTimeout,
    this.identityPem,
    this.passphrase,
    this.password,
  });

  /// Remote host name or address.
  final String host;

  /// Remote SSH port (22 unless `-p`/`-P` said otherwise).
  final int port;

  /// Login user name.
  final String username;

  /// PEM-encoded private key (OpenSSH format), or `null` for password-only
  /// authentication.
  final String? identityPem;

  /// Passphrase for an encrypted [identityPem] (`SSH_PASSPHRASE`).
  final String? passphrase;

  /// Password for password authentication (`SSH_PASSWORD`).
  final String? password;

  /// TCP connect timeout.
  final Duration connectTimeout;
}

/// A live SSH connection: remote exec plus an SFTP channel.
abstract interface class SandboxSshConnection {
  /// Runs [command] through an exec channel, feeding [stdin] (when given) to
  /// the remote process, and collects the full stdout/stderr plus the exit
  /// status. Throws on channel or transport failure.
  Future<SandboxSshExecResult> exec(String command, {List<int>? stdin});

  /// Opens the SFTP subsystem. Throws when the server has no SFTP.
  Future<SandboxSshFtp> openSftp();

  /// Closes the connection.
  Future<void> close();
}

/// One remote directory entry.
final class SandboxSshDirEntry {
  /// Creates an entry with a bare [name] and its kind.
  const SandboxSshDirEntry({
    required this.name,
    required this.isDirectory,
    this.longname,
  });

  /// Bare file name (no directory part).
  final String name;

  /// Whether the entry is a directory.
  final bool isDirectory;

  /// Server-provided `ls -l` style line, when available.
  final String? longname;
}

/// Attributes of a remote path, reduced to what the builtins need.
final class SandboxSshStat {
  /// Creates the stat view; [size] is null when the server does not report
  /// one.
  const SandboxSshStat({required this.isDirectory, this.size});

  /// Whether the path is a directory.
  final bool isDirectory;

  /// File size in bytes.
  final int? size;
}

/// SFTP-style remote file operations used by `scp` and the `sftp` batch
/// runner. Implementations throw on protocol errors; `stat` returns `null`
/// for a missing path instead of throwing.
abstract interface class SandboxSshFtp {
  /// Stats [path] (following symlinks); `null` when it does not exist.
  Future<SandboxSshStat?> stat(String path);

  /// Lists the entries of the directory at [path].
  Future<List<SandboxSshDirEntry>> listdir(String path);

  /// Reads the whole file at [path].
  Future<List<int>> readFile(String path);

  /// Writes [bytes] to [path], creating or truncating the file.
  Future<void> writeFile(String path, List<int> bytes);

  /// Creates the directory at [path] (parent must exist).
  Future<void> mkdir(String path);

  /// Removes the file at [path].
  Future<void> remove(String path);

  /// Removes the empty directory at [path].
  Future<void> rmdir(String path);
}

/// Opens an SSH connection for [params]. Only implementable where raw TCP
/// exists (`dart:io`); the real implementation lives in
/// `wasm_shell_ssh.dart` on top of package:dartssh2.
typedef SandboxSshConnector =
    Future<SandboxSshConnection> Function(SandboxSshConnectParams params);

/// Resolves the PEM-encoded private key for a connection: [identityPath] is
/// the verbatim `-i` argument (or null), [env] the shell environment. Returns
/// `null` when no usable key exists. See [resolveSshIdentityPem].
typedef SandboxSshIdentityResolver =
    Future<String?> Function(String? identityPath, Map<String, String> env);

/// Reads a sandbox file as bytes; `null` when missing. The path is the
/// verbatim command argument; the closure resolves it against the shell's
/// current directory.
typedef SandboxSshLocalRead = Future<List<int>?> Function(String path);

/// Writes bytes to a sandbox file, creating parent directories as needed.
typedef SandboxSshLocalWrite =
    Future<void> Function(String path, List<int> bytes);

/// Reports the kind of a sandbox path, or `null` when it does not exist.
typedef SandboxSshLocalKind =
    Future<SandboxSshEntryKind?> Function(String path);

/// Lists the entry names of a sandbox directory.
typedef SandboxSshLocalList = Future<List<String>> Function(String path);

/// Creates a sandbox directory including parents.
typedef SandboxSshLocalMkdir = Future<void> Function(String path);

/// Default identity files probed under the sandbox home (`~/.ssh`, i.e.
/// `/.ssh` — the sandbox root is the agent's home), in probe order. Mirrors
/// the list the git SSH transport uses, plus `id_ecdsa`.
const defaultSshIdentityPaths = [
  '/.ssh/id_ed25519',
  '/.ssh/id_rsa',
  '/.ssh/id_ecdsa',
];

/// Resolves the PEM-encoded private key for ssh/scp/sftp, in priority order:
///
/// 1. [identityPath] (the `-i` sandbox path; explicit choice never falls
///    through to the other sources),
/// 2. `SSH_KEY` in [env] (inline PEM),
/// 3. `SSH_KEY_PATH` in [env] (a sandbox path),
/// 4. the [defaultSshIdentityPaths] files.
///
/// [readFile] returns the text of a sandbox path or `null` when missing.
/// This is the same source set the git SSH transport (`GIT_SSH_KEY`,
/// `GIT_SSH_KEY_PATH`, `~/.ssh`) uses, renamed for the generic SSH builtins.
String? resolveSshIdentityPem({
  String? identityPath,
  required Map<String, String> env,
  required String? Function(String sandboxPath) readFile,
}) {
  bool isPem(String? content) =>
      content != null && content.contains('PRIVATE KEY');

  if (identityPath != null) {
    final pem = readFile(identityPath);
    return isPem(pem) ? pem : null;
  }
  final inline = env['SSH_KEY'];
  if (isPem(inline)) return inline;
  final keyPath = env['SSH_KEY_PATH'];
  if (keyPath != null) {
    final pem = readFile(keyPath);
    if (isPem(pem)) return pem;
  }
  for (final candidate in defaultSshIdentityPaths) {
    final pem = readFile(candidate);
    if (isPem(pem)) return pem;
  }
  return null;
}

/// Dart-native `ssh`, `scp`, and `sftp` builtins shared by the shells.
///
/// These are pure Dart (no `dart:io`): the network side goes through the
/// injected [SandboxSshConnector] and the sandbox filesystem through the
/// injected local closures, so host tests can drive the full command surface
/// against an in-memory fake remote. The real connector lives in
/// `wasm_shell_ssh.dart` (package:dartssh2); the web shell cannot open raw
/// TCP connections and reports exit code 127 for all three commands instead.
///
/// Command surface and exit codes:
///
/// - `ssh [-i identity] [-l user] [-p port] destination command...` —
///   non-interactive exec only (no login shell, no TTY, no prompts). Key
///   auth from `-i`/`SSH_KEY`/`SSH_KEY_PATH`/`~/.ssh` (see
///   [resolveSshIdentityPem]); `SSH_PASSPHRASE` unlocks an encrypted key and
///   `SSH_PASSWORD` enables password auth as a fallback. The remote exit
///   status becomes the builtin's exit code (1 when the server reports
///   none).
/// - `scp [-i identity] [-P port] [-r] source... target` — upload and
///   download over SFTP (like OpenSSH >= 9). The remote operand is
///   `[user@]host:path`; with several sources the target must be an
///   existing directory. Third-party copies (remote to remote) and purely
///   local copies are rejected with a usage error.
/// - `sftp [-i identity] [-P port] [-b batchfile] destination` —
///   non-interactive batch mode: commands come from `-b` or stdin, one per
///   line (`get`/`put`/`ls`/`cd`/`lcd`/`pwd`/`lpwd`/`mkdir`/`rm`/`rmdir`/
///   `exit`). Like `sftp -b`, the first failing command aborts the batch.
///   Interactive sessions are not supported.
///
/// Exit codes: 0 success, 1 connection/auth/remote/transfer failure,
/// 2 usage or local-input error. Transfers buffer whole files in memory,
/// which is fine for agent-sized payloads.
final class SandboxSshBuiltins {
  /// Creates the builtins over the injected connector, identity resolver,
  /// and sandbox filesystem closures.
  const SandboxSshBuiltins({
    required this.connector,
    required this.resolveIdentity,
    required this.readBinaryFile,
    required this.writeBinaryFile,
    required this.localKind,
    required this.listLocalDir,
    required this.makeLocalDir,
  });

  /// Injected SSH connector; see [SandboxSshConnector].
  final SandboxSshConnector connector;

  /// Injected identity resolver; see [SandboxSshIdentityResolver].
  final SandboxSshIdentityResolver resolveIdentity;

  /// Injected sandbox binary reader; see [SandboxSshLocalRead].
  final SandboxSshLocalRead readBinaryFile;

  /// Injected sandbox binary writer; see [SandboxSshLocalWrite].
  final SandboxSshLocalWrite writeBinaryFile;

  /// Injected sandbox stat; see [SandboxSshLocalKind].
  final SandboxSshLocalKind localKind;

  /// Injected sandbox directory listing; see [SandboxSshLocalList].
  final SandboxSshLocalList listLocalDir;

  /// Injected sandbox mkdir -p; see [SandboxSshLocalMkdir].
  final SandboxSshLocalMkdir makeLocalDir;

  /// TCP connect timeout for every SSH session (~15 s, per the card).
  static const connectTimeout = Duration(seconds: 15);

  /// Fallback bound for one whole operation when the caller's
  /// [ShellExecOptions]-style timeout is null, so a stuck remote cannot hang
  /// the agent forever.
  static const defaultOperationTimeout = Duration(minutes: 5);

  static const _sshUsage =
      'usage: ssh [-i identity] [-l user] [-p port] destination '
      'command [argument...]\n';
  static const _scpUsage =
      'usage: scp [-i identity] [-P port] [-r] source... target\n';
  static const _sftpUsage =
      'usage: sftp [-i identity] [-P port] [-b batchfile] destination\n';

  static SandboxBuiltinResult _ok(
    List<int> stdout, [
    List<int> stderr = const [],
  ]) {
    return SandboxBuiltinResult(stdout: stdout, stderr: stderr, exitCode: 0);
  }

  static SandboxBuiltinResult _error(String message, int exitCode) {
    return SandboxBuiltinResult(
      stdout: const [],
      stderr: utf8.encode(message),
      exitCode: exitCode,
    );
  }

  // ---------------------------------------------------------------------------
  // ssh
  // ---------------------------------------------------------------------------

  /// Runs the `ssh` builtin: a single non-interactive exec channel. Piped
  /// stdin ([stdin]) is forwarded to the remote process. [env] provides
  /// `USER` (default login name), `SSH_KEY`/`SSH_KEY_PATH`,
  /// `SSH_PASSPHRASE`, and `SSH_PASSWORD`.
  Future<SandboxBuiltinResult> ssh(
    List<String> args, {
    List<int>? stdin,
    Map<String, String> env = const {},
    Duration? timeout,
  }) async {
    if (args.contains('--version') || args.contains('-V')) {
      return _ok(utf8.encode('ssh (fah-sandbox builtin, package:dartssh2)\n'));
    }
    if (args.contains('--help')) {
      return _ok(utf8.encode(_sshUsage));
    }

    String? identity;
    String? user;
    var port = 22;
    var i = 0;
    for (; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--') {
        i++;
        break;
      }
      if (arg == '-i') {
        if (i + 1 >= args.length) return _error(_sshUsage, 2);
        identity = args[++i];
      } else if (arg == '-l') {
        if (i + 1 >= args.length) return _error(_sshUsage, 2);
        user = args[++i];
      } else if (arg == '-p') {
        if (i + 1 >= args.length) return _error(_sshUsage, 2);
        port = int.tryParse(args[++i]) ?? -1;
        if (port < 1 || port > 65535) {
          return _error('ssh: bad port number\n$_sshUsage', 2);
        }
      } else if (arg.startsWith('-')) {
        return _error(
          'ssh: unknown option -- ${arg.substring(1)}\n$_sshUsage',
          2,
        );
      } else {
        break;
      }
    }

    if (i >= args.length) return _error(_sshUsage, 2);
    final destination = args[i++];
    final at = destination.indexOf('@');
    final host = at >= 0 ? destination.substring(at + 1) : destination;
    user ??= at >= 0 ? destination.substring(0, at) : null;
    if (host.isEmpty || (at >= 0 && user!.isEmpty)) {
      return _error(_sshUsage, 2);
    }
    user ??= env['USER'] ?? 'fah';
    if (user.isEmpty) user = 'fah';

    final command = args.sublist(i);
    if (command.isEmpty) {
      return _error(
        'ssh: missing command (interactive login shells are not supported)\n'
        '$_sshUsage',
        2,
      );
    }

    final paramsOrError = await _connectParams(
      identity: identity,
      user: user,
      host: host,
      port: port,
      env: env,
      command: 'ssh',
    );
    if (paramsOrError.error != null) return paramsOrError.error!;
    final params = paramsOrError.params!;

    final operationTimeout = timeout ?? defaultOperationTimeout;
    try {
      final connection = await connector(params).timeout(operationTimeout);
      try {
        final result = await connection
            .exec(command.join(' '), stdin: stdin)
            .timeout(operationTimeout);
        // A server that closes the channel without an exit status (e.g.
        // GitHub's shell-less sshd) maps to 1 rather than fake success.
        return SandboxBuiltinResult(
          stdout: result.stdout,
          stderr: result.stderr,
          exitCode: result.exitCode ?? 1,
        );
      } finally {
        await connection.close();
      }
    } on TimeoutException {
      return _error('ssh: $host: operation timed out\n', 1);
    } on Object catch (e) {
      return _error('ssh: $host: $e\n', 1);
    }
  }

  /// Resolves the identity and builds connect params, or returns the error
  /// result to send back. [command] is the builtin name for messages.
  Future<({SandboxSshConnectParams? params, SandboxBuiltinResult? error})>
  _connectParams({
    required String? identity,
    required String user,
    required String host,
    required int port,
    required Map<String, String> env,
    required String command,
  }) async {
    final pem = await resolveIdentity(identity, env);
    if (identity != null && pem == null) {
      return (
        params: null,
        error: _error(
          '$command: $identity: no such identity file '
          '(or not a PEM private key)\n',
          1,
        ),
      );
    }
    final password = env['SSH_PASSWORD'];
    if (pem == null && (password == null || password.isEmpty)) {
      return (
        params: null,
        error: _error(
          '$command: no SSH key: set SSH_KEY (PEM) or SSH_KEY_PATH, '
          'use -i, or place a key at /.ssh/id_ed25519\n',
          1,
        ),
      );
    }
    return (
      params: SandboxSshConnectParams(
        host: host,
        port: port,
        username: user,
        connectTimeout: connectTimeout,
        identityPem: pem,
        passphrase: env['SSH_PASSPHRASE'],
        password: password,
      ),
      error: null,
    );
  }

  // ---------------------------------------------------------------------------
  // scp
  // ---------------------------------------------------------------------------

  /// Runs the `scp` builtin: copies files between the sandbox and a remote
  /// host over SFTP. Exactly one side of the transfer is remote; sources are
  /// all on the opposite side.
  Future<SandboxBuiltinResult> scp(
    List<String> args, {
    Map<String, String> env = const {},
    Duration? timeout,
  }) async {
    if (args.contains('--help')) {
      return _ok(utf8.encode(_scpUsage));
    }

    String? identity;
    var port = 22;
    var recursive = false;
    var i = 0;
    for (; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--') {
        i++;
        break;
      }
      if (arg == '-i') {
        if (i + 1 >= args.length) return _error(_scpUsage, 2);
        identity = args[++i];
      } else if (arg == '-P') {
        if (i + 1 >= args.length) return _error(_scpUsage, 2);
        port = int.tryParse(args[++i]) ?? -1;
        if (port < 1 || port > 65535) {
          return _error('scp: bad port number\n$_scpUsage', 2);
        }
      } else if (arg == '-r') {
        recursive = true;
      } else if (arg.startsWith('-')) {
        return _error(
          'scp: unknown option -- ${arg.substring(1)}\n$_scpUsage',
          2,
        );
      } else {
        break;
      }
    }

    final operands = args.sublist(i);
    if (operands.length < 2) return _error(_scpUsage, 2);
    final sources = [
      for (final operand in operands.sublist(0, operands.length - 1))
        _parseScpOperand(operand),
    ];
    final target = _parseScpOperand(operands.last);

    if (target.isRemote) {
      if (sources.every((s) => s.isRemote)) {
        return _error(
          'scp: remote-to-remote (third-party) copies are not supported\n',
          2,
        );
      }
      if (sources.any((s) => s.isRemote)) {
        return _error('scp: cannot mix local and remote sources\n', 2);
      }
      return _scpTransfer(
        upload: true,
        identity: identity,
        port: port,
        recursive: recursive,
        connection: target.connection!,
        localSources: [for (final s in sources) s.localPath!],
        remoteSources: const [],
        localTarget: null,
        remoteTarget: target.remotePath!,
        env: env,
        timeout: timeout,
      );
    }

    final remoteSources = sources.where((s) => s.isRemote).toList();
    if (remoteSources.isEmpty) {
      return _error(
        'scp: no remote operand (use cp for local-to-local copies)\n',
        2,
      );
    }
    if (remoteSources.length != sources.length) {
      return _error('scp: cannot mix local and remote sources\n', 2);
    }
    final first = remoteSources.first.connection!;
    final sameHost = remoteSources.every(
      (s) =>
          s.connection!.host == first.host && s.connection!.user == first.user,
    );
    if (!sameHost) {
      return _error('scp: remote sources must share one user@host\n', 2);
    }
    return _scpTransfer(
      upload: false,
      identity: identity,
      port: port,
      recursive: recursive,
      connection: first,
      localSources: const [],
      remoteSources: [for (final s in remoteSources) s.remotePath!],
      localTarget: target.localPath,
      remoteTarget: null,
      env: env,
      timeout: timeout,
    );
  }

  /// One scp operand: either a local sandbox path or `[user@]host:path`.
  static _ScpOperand _parseScpOperand(String operand) {
    final match = RegExp(r'^([^\s/:@]+@)?[^\s/:]+:(.*)$').firstMatch(operand);
    if (match == null) return _ScpOperand.local(operand);
    var authority = operand.substring(0, operand.indexOf(':'));
    String? user;
    final at = authority.indexOf('@');
    if (at >= 0) {
      user = authority.substring(0, at);
      authority = authority.substring(at + 1);
    }
    final remotePath = match.group(2)!;
    return _ScpOperand.remote(
      user: user,
      host: authority,
      // `host:` with an empty path means the remote home directory.
      path: remotePath.isEmpty ? '.' : remotePath,
    );
  }

  Future<SandboxBuiltinResult> _scpTransfer({
    required bool upload,
    required String? identity,
    required int port,
    required bool recursive,
    required _ScpConnection connection,
    required List<String> localSources,
    required List<String> remoteSources,
    required String? localTarget,
    required String? remoteTarget,
    required Map<String, String> env,
    required Duration? timeout,
  }) async {
    final user = connection.user ?? env['USER'] ?? 'fah';
    final paramsOrError = await _connectParams(
      identity: identity,
      user: user.isEmpty ? 'fah' : user,
      host: connection.host,
      port: port,
      env: env,
      command: 'scp',
    );
    if (paramsOrError.error != null) return paramsOrError.error!;

    final operationTimeout = timeout ?? defaultOperationTimeout;
    try {
      final conn = await connector(
        paramsOrError.params!,
      ).timeout(operationTimeout);
      try {
        final ftp = await conn.openSftp().timeout(operationTimeout);
        if (upload) {
          return await _scpUpload(
            ftp,
            localSources,
            remoteTarget!,
            recursive: recursive,
          );
        }
        return await _scpDownload(
          ftp,
          remoteSources,
          localTarget!,
          recursive: recursive,
        );
      } finally {
        await conn.close();
      }
    } on TimeoutException {
      return _error('scp: ${connection.host}: operation timed out\n', 1);
    } on Object catch (e) {
      return _error('scp: ${connection.host}: $e\n', 1);
    }
  }

  Future<SandboxBuiltinResult> _scpUpload(
    SandboxSshFtp ftp,
    List<String> localSources,
    String remoteTarget, {
    required bool recursive,
  }) async {
    final multiple = localSources.length > 1;
    if (multiple) {
      final targetStat = await _ftpStatSafe(ftp, remoteTarget);
      if (targetStat == null || !targetStat.isDirectory) {
        return _error('scp: $remoteTarget: not a directory\n', 1);
      }
    }
    for (final source in localSources) {
      final kind = await localKind(source);
      if (kind == null) {
        return _error('scp: $source: No such file or directory\n', 1);
      }
      if (kind == SandboxSshEntryKind.directory) {
        if (!recursive) {
          return _error('scp: $source: not a regular file\n', 1);
        }
        // cp -r semantics: an existing directory target receives the source
        // inside it; otherwise the target IS the new directory.
        final targetStat = await _ftpStatSafe(ftp, remoteTarget);
        final destDir =
            multiple || (targetStat != null && targetStat.isDirectory)
            ? _remoteJoin(remoteTarget, _baseName(source))
            : remoteTarget;
        final error = await _uploadDir(ftp, source, destDir);
        if (error != null) return error;
        continue;
      }
      final error = await _uploadFile(ftp, source, remoteTarget, multiple);
      if (error != null) return error;
    }
    return _ok(const []);
  }

  Future<SandboxBuiltinResult?> _uploadFile(
    SandboxSshFtp ftp,
    String localPath,
    String remoteTarget,
    bool multiple,
  ) async {
    final bytes = await readBinaryFile(localPath);
    if (bytes == null) {
      return _error('scp: $localPath: No such file or directory\n', 1);
    }
    var dest = remoteTarget;
    final targetStat = await _ftpStatSafe(ftp, remoteTarget);
    if (multiple || (targetStat != null && targetStat.isDirectory)) {
      dest = _remoteJoin(remoteTarget, _baseName(localPath));
    } else if (targetStat == null && remoteTarget.endsWith('/')) {
      return _error('scp: $remoteTarget: No such file or directory\n', 1);
    }
    try {
      await ftp.writeFile(dest, bytes);
    } on Object catch (e) {
      return _error('scp: $dest: $e\n', 1);
    }
    return null;
  }

  Future<SandboxBuiltinResult?> _uploadDir(
    SandboxSshFtp ftp,
    String localDir,
    String remoteDir,
  ) async {
    final stat = await _ftpStatSafe(ftp, remoteDir);
    if (stat != null && !stat.isDirectory) {
      return _error('scp: $remoteDir: not a directory\n', 1);
    }
    if (stat == null) {
      try {
        await ftp.mkdir(remoteDir);
      } on Object catch (e) {
        return _error('scp: $remoteDir: $e\n', 1);
      }
    }
    final List<String> entries;
    try {
      entries = await listLocalDir(localDir);
    } on Object catch (e) {
      return _error('scp: $localDir: $e\n', 1);
    }
    for (final name in entries) {
      final localChild = _localJoin(localDir, name);
      final remoteChild = _remoteJoin(remoteDir, name);
      final kind = await localKind(localChild);
      if (kind == SandboxSshEntryKind.directory) {
        final error = await _uploadDir(ftp, localChild, remoteChild);
        if (error != null) return error;
      } else if (kind == SandboxSshEntryKind.file) {
        final bytes = await readBinaryFile(localChild);
        if (bytes == null) continue;
        try {
          await ftp.writeFile(remoteChild, bytes);
        } on Object catch (e) {
          return _error('scp: $remoteChild: $e\n', 1);
        }
      }
      // Other kinds (symlinks, sockets) are skipped, like scp does.
    }
    return null;
  }

  Future<SandboxBuiltinResult> _scpDownload(
    SandboxSshFtp ftp,
    List<String> remoteSources,
    String localTarget, {
    required bool recursive,
  }) async {
    final multiple = remoteSources.length > 1;
    if (multiple) {
      final kind = await localKind(localTarget);
      if (kind != SandboxSshEntryKind.directory) {
        return _error('scp: $localTarget: not a directory\n', 1);
      }
    }
    for (final source in remoteSources) {
      final stat = await _ftpStatSafe(ftp, source);
      if (stat == null) {
        return _error('scp: $source: No such file or directory\n', 1);
      }
      if (stat.isDirectory) {
        if (!recursive) {
          return _error('scp: $source: not a regular file\n', 1);
        }
        // cp -r semantics: an existing directory target receives the source
        // inside it; otherwise the target IS the new directory.
        final destDir =
            multiple ||
                await localKind(localTarget) == SandboxSshEntryKind.directory
            ? _localJoin(localTarget, _baseName(source))
            : localTarget;
        final error = await _downloadDir(ftp, source, destDir);
        if (error != null) return error;
        continue;
      }
      var dest = localTarget;
      if (multiple ||
          await localKind(localTarget) == SandboxSshEntryKind.directory) {
        dest = _localJoin(localTarget, _baseName(source));
      }
      final error = await _downloadFile(ftp, source, dest);
      if (error != null) return error;
    }
    return _ok(const []);
  }

  Future<SandboxBuiltinResult?> _downloadFile(
    SandboxSshFtp ftp,
    String remotePath,
    String localPath,
  ) async {
    final List<int> bytes;
    try {
      bytes = await ftp.readFile(remotePath);
    } on Object catch (e) {
      return _error('scp: $remotePath: $e\n', 1);
    }
    await writeBinaryFile(localPath, bytes);
    return null;
  }

  Future<SandboxBuiltinResult?> _downloadDir(
    SandboxSshFtp ftp,
    String remoteDir,
    String localDir,
  ) async {
    await makeLocalDir(localDir);
    final List<SandboxSshDirEntry> entries;
    try {
      entries = await ftp.listdir(remoteDir);
    } on Object catch (e) {
      return _error('scp: $remoteDir: $e\n', 1);
    }
    for (final entry in entries) {
      if (entry.name == '.' || entry.name == '..') continue;
      final remoteChild = _remoteJoin(remoteDir, entry.name);
      final localChild = _localJoin(localDir, entry.name);
      if (entry.isDirectory) {
        final error = await _downloadDir(ftp, remoteChild, localChild);
        if (error != null) return error;
      } else {
        final error = await _downloadFile(ftp, remoteChild, localChild);
        if (error != null) return error;
      }
    }
    return null;
  }

  /// stat that converts protocol errors into `null` (treated as missing) —
  /// used where a wrong guess is corrected by the following operation.
  Future<SandboxSshStat?> _ftpStatSafe(SandboxSshFtp ftp, String path) async {
    try {
      return await ftp.stat(path);
    } on Object {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // sftp (batch mode)
  // ---------------------------------------------------------------------------

  /// Runs the `sftp` builtin in batch mode: commands are read from the `-b`
  /// batch file (a sandbox path) or from [stdin] (piped input), one per
  /// line, and executed over a single SFTP session. Supported commands:
  /// `get`, `put`, `ls`, `cd`, `lcd`, `pwd`, `lpwd`, `mkdir`, `rm`, `rmdir`,
  /// `exit`/`quit`/`bye`; blank lines and `#` comments are skipped. The
  /// first failing command aborts the batch with exit code 1, like
  /// `sftp -b`. [cwd] is the shell's current sandbox directory (the initial
  /// local working directory).
  Future<SandboxBuiltinResult> sftp(
    List<String> args, {
    List<int>? stdin,
    Map<String, String> env = const {},
    String cwd = '/',
    Duration? timeout,
  }) async {
    if (args.contains('--help')) {
      return _ok(utf8.encode(_sftpUsage));
    }

    String? identity;
    String? batchFile;
    var port = 22;
    String? destination;
    var i = 0;
    for (; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--') {
        i++;
        break;
      }
      if (arg == '-i') {
        if (i + 1 >= args.length) return _error(_sftpUsage, 2);
        identity = args[++i];
      } else if (arg == '-b') {
        if (i + 1 >= args.length) return _error(_sftpUsage, 2);
        batchFile = args[++i];
      } else if (arg == '-P') {
        if (i + 1 >= args.length) return _error(_sftpUsage, 2);
        port = int.tryParse(args[++i]) ?? -1;
        if (port < 1 || port > 65535) {
          return _error('sftp: bad port number\n$_sftpUsage', 2);
        }
      } else if (arg.startsWith('-')) {
        return _error(
          'sftp: unknown option -- ${arg.substring(1)}\n$_sftpUsage',
          2,
        );
      } else {
        break;
      }
    }
    if (i < args.length) destination = args[i];
    if (destination == null) return _error(_sftpUsage, 2);

    final at = destination.indexOf('@');
    final host = at >= 0 ? destination.substring(at + 1) : destination;
    var user = at >= 0 ? destination.substring(0, at) : null;
    if (host.isEmpty || (at >= 0 && user!.isEmpty)) {
      return _error(_sftpUsage, 2);
    }
    user ??= env['USER'] ?? 'fah';
    if (user.isEmpty) user = 'fah';

    final String batch;
    if (batchFile != null) {
      final bytes = await readBinaryFile(batchFile);
      if (bytes == null) {
        return _error('sftp: $batchFile: No such file or directory\n', 2);
      }
      batch = utf8.decode(bytes, allowMalformed: true);
    } else if (stdin != null) {
      batch = utf8.decode(stdin, allowMalformed: true);
    } else {
      return _error(
        'sftp: no batch input: pipe commands on stdin or use -b '
        '(interactive sessions are not supported)\n',
        2,
      );
    }

    final paramsOrError = await _connectParams(
      identity: identity,
      user: user,
      host: host,
      port: port,
      env: env,
      command: 'sftp',
    );
    if (paramsOrError.error != null) return paramsOrError.error!;

    final operationTimeout = timeout ?? defaultOperationTimeout;
    try {
      final conn = await connector(
        paramsOrError.params!,
      ).timeout(operationTimeout);
      try {
        final ftp = await conn.openSftp().timeout(operationTimeout);
        return await _runSftpBatch(ftp, batch, cwd);
      } finally {
        await conn.close();
      }
    } on TimeoutException {
      return _error('sftp: $host: operation timed out\n', 1);
    } on Object catch (e) {
      return _error('sftp: $host: $e\n', 1);
    }
  }

  Future<SandboxBuiltinResult> _runSftpBatch(
    SandboxSshFtp ftp,
    String batch,
    String cwd,
  ) async {
    final stdout = BytesBuilder(copy: false);
    var remoteCwd = '.';
    var localCwd = _normalizeLocal(cwd);

    SandboxBuiltinResult fail(String message) => _error('sftp: $message\n', 1);

    for (final rawLine in const LineSplitter().convert(batch)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final tokens = line.split(RegExp(r'\s+'));
      final command = tokens.first;
      final cargs = tokens.sublist(1);

      String remoteResolve(String path) => path.startsWith('/')
          ? p.posix.normalize(path)
          : p.posix.normalize(p.posix.join(remoteCwd, path));
      String localResolve(String path) => path.startsWith('/')
          ? _normalizeLocal(path)
          : _normalizeLocal('$localCwd/$path');

      try {
        switch (command) {
          case 'exit' || 'quit' || 'bye':
            return _ok(stdout.takeBytes());
          case 'pwd':
            stdout.add(utf8.encode('Remote working directory: $remoteCwd\n'));
          case 'lpwd':
            stdout.add(utf8.encode('Local working directory: $localCwd\n'));
          case 'cd':
            if (cargs.length != 1) return fail('cd: missing operand');
            final path = remoteResolve(cargs.single);
            final stat = await ftp.stat(path);
            if (stat == null) {
              return fail('cd: ${cargs.single}: No such file or directory');
            }
            if (!stat.isDirectory) {
              return fail('cd: ${cargs.single}: Not a directory');
            }
            remoteCwd = path;
          case 'lcd':
            if (cargs.length != 1) return fail('lcd: missing operand');
            final path = localResolve(cargs.single);
            if (await localKind(path) != SandboxSshEntryKind.directory) {
              return fail('lcd: ${cargs.single}: Not a directory');
            }
            localCwd = path;
          case 'ls':
            if (cargs.length > 1) return fail('ls: too many operands');
            final path = cargs.isEmpty
                ? remoteCwd
                : remoteResolve(cargs.single);
            final entries = await ftp.listdir(path);
            for (final entry in entries) {
              if (entry.name == '.' || entry.name == '..') continue;
              stdout.add(utf8.encode('${entry.longname ?? entry.name}\n'));
            }
          case 'get':
            if (cargs.isEmpty || cargs.length > 2) {
              return fail('usage: get remote-path [local-path]');
            }
            final remotePath = remoteResolve(cargs.first);
            final stat = await ftp.stat(remotePath);
            if (stat == null) {
              return fail('get: ${cargs.first}: No such file or directory');
            }
            if (stat.isDirectory) {
              return fail('get: ${cargs.first}: is a directory (use scp -r)');
            }
            final localPath = localResolve(
              cargs.length == 2 ? cargs[1] : _baseName(remotePath),
            );
            final bytes = await ftp.readFile(remotePath);
            await writeBinaryFile(localPath, bytes);
          case 'put':
            if (cargs.isEmpty || cargs.length > 2) {
              return fail('usage: put local-path [remote-path]');
            }
            final localPath = localResolve(cargs.first);
            final kind = await localKind(localPath);
            if (kind == null) {
              return fail('put: ${cargs.first}: No such file or directory');
            }
            if (kind == SandboxSshEntryKind.directory) {
              return fail('put: ${cargs.first}: is a directory (use scp -r)');
            }
            final bytes = await readBinaryFile(localPath);
            if (bytes == null) {
              return fail('put: ${cargs.first}: No such file or directory');
            }
            final remotePath = cargs.length == 2
                ? remoteResolve(cargs[1])
                : _remoteJoin(remoteCwd, _baseName(localPath));
            await ftp.writeFile(remotePath, bytes);
          case 'mkdir':
            if (cargs.length != 1) return fail('mkdir: missing operand');
            await ftp.mkdir(remoteResolve(cargs.single));
          case 'rm':
            if (cargs.length != 1) return fail('rm: missing operand');
            await ftp.remove(remoteResolve(cargs.single));
          case 'rmdir':
            if (cargs.length != 1) return fail('rmdir: missing operand');
            await ftp.rmdir(remoteResolve(cargs.single));
          default:
            return fail('unknown command: $command');
        }
      } on Object catch (e) {
        return fail('$line: $e');
      }
    }
    return _ok(stdout.takeBytes());
  }

  // ---------------------------------------------------------------------------
  // Path helpers
  // ---------------------------------------------------------------------------

  /// Joins remote (POSIX) path segments.
  static String _remoteJoin(String base, String name) =>
      base.endsWith('/') ? '$base$name' : '$base/$name';

  /// Joins local sandbox path segments (also POSIX).
  static String _localJoin(String base, String name) =>
      base.endsWith('/') ? '$base$name' : '$base/$name';

  /// Basename of a POSIX path, ignoring trailing slashes.
  static String _baseName(String path) {
    var trimmed = path;
    while (trimmed.length > 1 && trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    final slash = trimmed.lastIndexOf('/');
    return slash >= 0 ? trimmed.substring(slash + 1) : trimmed;
  }

  /// Normalizes a local sandbox path: collapses `.` and `..` segments and
  /// always returns an absolute path (mirrors the shells' own normalizer).
  static String _normalizeLocal(String path) {
    final segments = <String>[];
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(part);
    }
    return '/${segments.join('/')}';
  }
}

/// One parsed scp operand.
final class _ScpOperand {
  _ScpOperand.local(String path)
    : localPath = path,
      remotePath = null,
      connection = null;

  _ScpOperand.remote({
    required String? user,
    required String host,
    required String path,
  }) : localPath = null,
       remotePath = path,
       connection = _ScpConnection(user: user, host: host);

  /// Verbatim local sandbox path (null when remote).
  final String? localPath;

  /// Remote path (null when local).
  final String? remotePath;

  /// Remote endpoint (null when local).
  final _ScpConnection? connection;

  /// Whether this operand names a remote path.
  bool get isRemote => connection != null;
}

/// Remote endpoint of an scp operand.
final class _ScpConnection {
  const _ScpConnection({required this.user, required this.host});

  /// Login user (null = default from the environment).
  final String? user;

  /// Remote host.
  final String host;
}
