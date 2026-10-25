// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:fa/sandbox/sandbox_builtins.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

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

/// Parsed `ssh` command line (see `SandboxSshBuiltins._parseSshArgs`); the
/// error field carries the usage result for a malformed invocation.
typedef _SshArgs = ({
  SandboxBuiltinResult? error,
  String? identity,
  String user,
  String host,
  int port,
  List<String> command,
});

/// Parsed `sftp` command line (see `SandboxSshBuiltins._parseSftpArgs`).
typedef _SftpArgs = ({
  SandboxBuiltinResult? error,
  String? identity,
  String? batchFile,
  String user,
  String host,
  int port,
});

/// Mutable `ssh`/`sftp` leading-option scan state: the identity, batch
/// file, login user, port, and where the operands start. [error] carries
/// the usage result when the scan failed.
final class _SshArgScan {
  _SshArgScan({required this.label, required this.usage});

  /// Builtin name for diagnostics (`ssh` / `sftp`).
  final String label;

  /// Usage text embedded in the malformed-invocation messages.
  final String usage;

  String? identity;
  String? batchFile; // sftp -b
  String? user; // ssh -l
  var port = 22;

  /// The usage result for the first malformed option, if any.
  SandboxBuiltinResult? error;

  /// Index of the first remaining word (the destination, or the command
  /// start after `--`). Only meaningful when [error] is null.
  var next = 0;
}

/// Parsed `scp` options (see `SandboxSshBuiltins._parseScpOptions`);
/// [operandStart] is where the operand list begins.
typedef _ScpOptions = ({
  SandboxBuiltinResult? error,
  String? identity,
  int port,
  bool recursive,
  int operandStart,
});

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
      return _ok(utf8.encode('ssh (Fa sandbox builtin, package:dartssh2)\n'));
    }
    if (args.contains('--help')) {
      return _ok(utf8.encode(_sshUsage));
    }
    final argsOrError = _parseSshArgs(args, env: env);
    if (argsOrError.error != null) return argsOrError.error!;
    final paramsOrError = await _connectParams(
      identity: argsOrError.identity,
      user: argsOrError.user,
      host: argsOrError.host,
      port: argsOrError.port,
      env: env,
      command: 'ssh',
    );
    if (paramsOrError.error != null) return paramsOrError.error!;
    return _withConnection(
      paramsOrError.params!,
      command: 'ssh',
      host: argsOrError.host,
      timeout: timeout,
      action: (connection, operationTimeout) async {
        final result = await connection
            .exec(argsOrError.command.join(' '), stdin: stdin)
            .timeout(operationTimeout);
        // A server that closes the channel without an exit status (e.g.
        // GitHub's shell-less sshd) maps to 1 rather than fake success.
        return SandboxBuiltinResult(
          stdout: result.stdout,
          stderr: result.stderr,
          exitCode: result.exitCode ?? 1,
        );
      },
    );
  }

  /// Scans leading short options (shared by `ssh` and `sftp`): every
  /// word up to `--` or the first non-option goes through [consume]. On
  /// success [scan.next] is the index of the first remaining word; on
  /// failure [scan.error] carries the usage result and false is returned.
  static bool _scanSshOptions(
    List<String> args,
    _SshArgScan scan,
    int? Function(List<String>, int, _SshArgScan) consume,
  ) {
    var i = 0;
    while (i < args.length) {
      final arg = args[i];
      if (arg == '--') {
        i++;
        break;
      }
      if (!arg.startsWith('-')) break;
      final consumed = consume(args, i, scan);
      if (consumed == null) return false;
      i = consumed + 1;
    }
    scan.next = i;
    return true;
  }

  /// The word after the option at [i], or null (usage error stashed in
  /// [scan]) when the argv ends first.
  static String? _sshOperand(List<String> args, int i, _SshArgScan scan) {
    if (i + 1 >= args.length) {
      scan.error = _error(scan.usage, 2);
      return null;
    }
    return args[i + 1];
  }

  /// Consumes the operand of the option at [i] into [set]; null (usage
  /// error stashed) when the operand is missing.
  static int? _sshTake(
    List<String> args,
    int i,
    _SshArgScan scan,
    void Function(String) set,
  ) {
    final operand = _sshOperand(args, i, scan);
    if (operand == null) return null;
    set(operand);
    return i + 1;
  }

  /// Consumes the `-p`/`-P` port at [i]; rejects out-of-range values
  /// like OpenSSH.
  static int? _sshTakePort(List<String> args, int i, _SshArgScan scan) {
    final operand = _sshOperand(args, i, scan);
    if (operand == null) return null;
    final port = int.tryParse(operand) ?? -1;
    if (port < 1 || port > 65535) {
      scan.error = _error('${scan.label}: bad port number\n${scan.usage}', 2);
      return null;
    }
    scan.port = port;
    return i + 1;
  }

  /// Consumes one `ssh` option word at [i] (`-i`, `-l`, `-p`); null
  /// after a usage error.
  static int? _sshConsumeOption(List<String> args, int i, _SshArgScan scan) =>
      switch (args[i]) {
        '-i' => _sshTake(args, i, scan, (v) => scan.identity = v),
        '-l' => _sshTake(args, i, scan, (v) => scan.user = v),
        '-p' => _sshTakePort(args, i, scan),
        _ => _sshUnknownOption(args[i], scan),
      };

  /// Consumes one `sftp` option word at [i] (`-i`, `-b`, `-P`); null
  /// after a usage error.
  static int? _sftpConsumeOption(List<String> args, int i, _SshArgScan scan) =>
      switch (args[i]) {
        '-i' => _sshTake(args, i, scan, (v) => scan.identity = v),
        '-b' => _sshTake(args, i, scan, (v) => scan.batchFile = v),
        '-P' => _sshTakePort(args, i, scan),
        _ => _sshUnknownOption(args[i], scan),
      };

  /// Stashes the unknown-option usage error and returns null (the
  /// consume contract's failure shape).
  static int? _sshUnknownOption(String arg, _SshArgScan scan) {
    scan.error = _error(
      '${scan.label}: unknown option -- ${arg.substring(1)}\n${scan.usage}',
      2,
    );
    return null;
  }

  /// Parses `ssh` options, the `[user@]host` destination, and the remote
  /// command operands. Returns the usage-error result for any malformed
  /// invocation.
  static _SshArgs _parseSshArgs(
    List<String> args, {
    required Map<String, String> env,
  }) {
    _SshArgs usage([SandboxBuiltinResult? result]) => (
      error: result ?? _error(_sshUsage, 2),
      identity: null,
      user: '',
      host: '',
      port: 0,
      command: const [],
    );
    final scan = _SshArgScan(label: 'ssh', usage: _sshUsage);
    if (!_scanSshOptions(args, scan, _sshConsumeOption)) {
      return usage(scan.error);
    }
    var i = scan.next;
    if (i >= args.length) return usage();
    final destination = args[i++];
    final command = args.sublist(i);
    if (command.isEmpty) {
      return usage(
        _error(
          'ssh: missing command (interactive login shells are not supported)\n'
          '$_sshUsage',
          2,
        ),
      );
    }
    final remote = _parseDestination(destination, user: scan.user, env: env);
    if (remote == null) return usage();
    return (
      error: null,
      identity: scan.identity,
      user: remote.user,
      host: remote.host,
      port: scan.port,
      command: command,
    );
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

  /// Splits a `[user@]host` destination, giving the explicit [user] (from
  /// `-l`) priority over the destination part, then applies the `USER` env
  /// fallback (`Fa` when unset or empty). Returns null for an empty host or
  /// an empty explicit user.
  static ({String user, String host})? _parseDestination(
    String destination, {
    String? user,
    required Map<String, String> env,
  }) {
    final at = destination.indexOf('@');
    final host = at >= 0 ? destination.substring(at + 1) : destination;
    var resolved = user ?? (at >= 0 ? destination.substring(0, at) : null);
    if (host.isEmpty || (at >= 0 && resolved!.isEmpty)) return null;
    resolved ??= env['USER'] ?? 'Fa';
    if (resolved.isEmpty) resolved = 'Fa';
    return (user: resolved, host: host);
  }

  /// Shared session lifecycle for `ssh`/`scp`/`sftp`: connect with the
  /// operation timeout, run [action] (each protocol step applies the same
  /// timeout itself), and always close the connection. A timeout or
  /// protocol failure maps to exit code 1 with a `$command: $host: …`
  /// diagnostic.
  Future<SandboxBuiltinResult> _withConnection(
    SandboxSshConnectParams params, {
    required String command,
    required String host,
    required Duration? timeout,
    required Future<SandboxBuiltinResult> Function(
      SandboxSshConnection connection,
      Duration operationTimeout,
    )
    action,
  }) async {
    final operationTimeout = timeout ?? defaultOperationTimeout;
    try {
      final connection = await connector(params).timeout(operationTimeout);
      try {
        return await action(connection, operationTimeout);
      } finally {
        await connection.close();
      }
    } on TimeoutException {
      return _error('$command: $host: operation timed out\n', 1);
    } on Object catch (e) {
      return _error('$command: $host: $e\n', 1);
    }
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
    final options = _parseScpOptions(args);
    if (options.error != null) return options.error!;

    final operands = args.sublist(options.operandStart);
    if (operands.length < 2) return _error(_scpUsage, 2);
    final sources = [
      for (final operand in operands.sublist(0, operands.length - 1))
        _parseScpOperand(operand),
    ];
    final target = _parseScpOperand(operands.last);

    if (target.isRemote) {
      final planError = _scpUploadPlanError(sources);
      if (planError != null) return planError;
      return _scpTransfer(
        upload: true,
        identity: options.identity,
        port: options.port,
        recursive: options.recursive,
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
    final planError = _scpDownloadPlanError(sources, remoteSources);
    if (planError != null) return planError;
    return _scpTransfer(
      upload: false,
      identity: options.identity,
      port: options.port,
      recursive: options.recursive,
      connection: remoteSources.first.connection!,
      localSources: const [],
      remoteSources: [for (final s in remoteSources) s.remotePath!],
      localTarget: target.localPath,
      remoteTarget: null,
      env: env,
      timeout: timeout,
    );
  }

  /// Parses `scp` options (`-i`, `-P`, `-r`) and returns the index where the
  /// operand list begins. Returns the usage-error result for any malformed
  /// invocation.
  static _ScpOptions _parseScpOptions(List<String> args) {
    _ScpOptions usage([SandboxBuiltinResult? result]) => (
      error: result ?? _error(_scpUsage, 2),
      identity: null,
      port: 22,
      recursive: false,
      operandStart: 0,
    );
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
        if (i + 1 >= args.length) return usage();
        identity = args[++i];
      } else if (arg == '-P') {
        if (i + 1 >= args.length) return usage();
        port = int.tryParse(args[++i]) ?? -1;
        if (port < 1 || port > 65535) {
          return usage(_error('scp: bad port number\n$_scpUsage', 2));
        }
      } else if (arg == '-r') {
        recursive = true;
      } else if (arg.startsWith('-')) {
        return usage(
          _error('scp: unknown option -- ${arg.substring(1)}\n$_scpUsage', 2),
        );
      } else {
        break;
      }
    }
    return (
      error: null,
      identity: identity,
      port: port,
      recursive: recursive,
      operandStart: i,
    );
  }

  /// scp rejects a remote target fed only from remote sources (third-party
  /// copy) or from a mix of local and remote sources.
  static SandboxBuiltinResult? _scpUploadPlanError(List<_ScpOperand> sources) {
    if (sources.every((s) => s.isRemote)) {
      return _error(
        'scp: remote-to-remote (third-party) copies are not supported\n',
        2,
      );
    }
    if (sources.any((s) => s.isRemote)) {
      return _error('scp: cannot mix local and remote sources\n', 2);
    }
    return null;
  }

  /// scp rejects a local target with no remote source, a mix of local and
  /// remote sources, and remote sources spread over several user@host.
  static SandboxBuiltinResult? _scpDownloadPlanError(
    List<_ScpOperand> sources,
    List<_ScpOperand> remoteSources,
  ) {
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
    return null;
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
    final user = connection.user ?? env['USER'] ?? 'Fa';
    final paramsOrError = await _connectParams(
      identity: identity,
      user: user.isEmpty ? 'Fa' : user,
      host: connection.host,
      port: port,
      env: env,
      command: 'scp',
    );
    if (paramsOrError.error != null) return paramsOrError.error!;

    return _withConnection(
      paramsOrError.params!,
      command: 'scp',
      host: connection.host,
      timeout: timeout,
      action: (conn, operationTimeout) async {
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
      },
    );
  }

  Future<SandboxBuiltinResult> _scpUpload(
    SandboxSshFtp ftp,
    List<String> localSources,
    String remoteTarget, {
    required bool recursive,
  }) async {
    final multiple = localSources.length > 1;
    if (multiple) {
      final error = await _ensureRemoteDir(ftp, remoteTarget);
      if (error != null) return error;
    }
    for (final source in localSources) {
      final error = await _uploadSource(
        ftp,
        source,
        remoteTarget,
        multiple: multiple,
        recursive: recursive,
      );
      if (error != null) return error;
    }
    return _ok(const []);
  }

  /// scp refuses a multi-source upload unless the target is a remote
  /// directory.
  Future<SandboxBuiltinResult?> _ensureRemoteDir(
    SandboxSshFtp ftp,
    String remoteTarget,
  ) async {
    final targetStat = await _ftpStatSafe(ftp, remoteTarget);
    if (targetStat == null || !targetStat.isDirectory) {
      return _error('scp: $remoteTarget: not a directory\n', 1);
    }
    return null;
  }

  Future<SandboxBuiltinResult?> _uploadSource(
    SandboxSshFtp ftp,
    String source,
    String remoteTarget, {
    required bool multiple,
    required bool recursive,
  }) async {
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
      final destDir = multiple || (targetStat != null && targetStat.isDirectory)
          ? _remoteJoin(remoteTarget, _baseName(source))
          : remoteTarget;
      return _uploadDir(ftp, source, destDir);
    }
    return _uploadFile(ftp, source, remoteTarget, multiple);
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

  /// Ensures [remoteDir] is usable as a recursive-upload destination: a
  /// non-directory target fails, a missing one is created.
  Future<SandboxBuiltinResult?> _ensureUploadDir(
    SandboxSshFtp ftp,
    String remoteDir,
  ) async {
    final stat = await _ftpStatSafe(ftp, remoteDir);
    if (stat != null && !stat.isDirectory) {
      return _error('scp: $remoteDir: not a directory\n', 1);
    }
    if (stat == null) return _mkdirRemote(ftp, remoteDir);
    return null;
  }

  /// Creates [remoteDir] on the remote, mapping the failure to an scp
  /// error result.
  Future<SandboxBuiltinResult?> _mkdirRemote(
    SandboxSshFtp ftp,
    String remoteDir,
  ) async {
    try {
      await ftp.mkdir(remoteDir);
    } on Object catch (e) {
      return _error('scp: $remoteDir: $e\n', 1);
    }
    return null;
  }

  /// Lists [localDir], or maps the failure to an scp error result.
  Future<(List<String>, SandboxBuiltinResult?)> _listLocalEntries(
    String localDir,
  ) async {
    try {
      return (await listLocalDir(localDir), null);
    } on Object catch (e) {
      return (const <String>[], _error('scp: $localDir: $e\n', 1));
    }
  }

  /// Uploads one child entry of a recursive directory copy (directories
  /// recurse, files upload, other kinds are skipped like scp does).
  /// Returns the error result, or null on success/skip.
  Future<SandboxBuiltinResult?> _uploadDirEntry(
    SandboxSshFtp ftp,
    String localChild,
    String remoteChild,
  ) async {
    final kind = await localKind(localChild);
    if (kind == SandboxSshEntryKind.directory) {
      return _uploadDir(ftp, localChild, remoteChild);
    }
    if (kind == SandboxSshEntryKind.file) {
      return _uploadDirFile(ftp, localChild, remoteChild);
    }
    return null;
  }

  /// Uploads one file entry; an unreadable source is skipped (null).
  Future<SandboxBuiltinResult?> _uploadDirFile(
    SandboxSshFtp ftp,
    String localChild,
    String remoteChild,
  ) async {
    final bytes = await readBinaryFile(localChild);
    if (bytes == null) return null;
    try {
      await ftp.writeFile(remoteChild, bytes);
    } on Object catch (e) {
      return _error('scp: $remoteChild: $e\n', 1);
    }
    return null;
  }

  Future<SandboxBuiltinResult?> _uploadDir(
    SandboxSshFtp ftp,
    String localDir,
    String remoteDir,
  ) async {
    final dirError = await _ensureUploadDir(ftp, remoteDir);
    if (dirError != null) return dirError;
    final (entries, listError) = await _listLocalEntries(localDir);
    if (listError != null) return listError;
    for (final name in entries) {
      final error = await _uploadDirEntry(
        ftp,
        _localJoin(localDir, name),
        _remoteJoin(remoteDir, name),
      );
      if (error != null) return error;
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
      final error = await _ensureLocalDir(localTarget);
      if (error != null) return error;
    }
    for (final source in remoteSources) {
      final error = await _downloadSource(
        ftp,
        source,
        localTarget,
        multiple: multiple,
        recursive: recursive,
      );
      if (error != null) return error;
    }
    return _ok(const []);
  }

  /// scp refuses a multi-source download unless the target is a local
  /// directory.
  Future<SandboxBuiltinResult?> _ensureLocalDir(String localTarget) async {
    final kind = await localKind(localTarget);
    if (kind != SandboxSshEntryKind.directory) {
      return _error('scp: $localTarget: not a directory\n', 1);
    }
    return null;
  }

  Future<SandboxBuiltinResult?> _downloadSource(
    SandboxSshFtp ftp,
    String source,
    String localTarget, {
    required bool multiple,
    required bool recursive,
  }) async {
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
      return _downloadDir(ftp, source, destDir);
    }
    var dest = localTarget;
    if (multiple ||
        await localKind(localTarget) == SandboxSshEntryKind.directory) {
      dest = _localJoin(localTarget, _baseName(source));
    }
    return _downloadFile(ftp, source, dest);
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
    final argsOrError = _parseSftpArgs(args, env: env);
    if (argsOrError.error != null) return argsOrError.error!;
    final batchOrError = await _sftpBatchInput(
      batchFile: argsOrError.batchFile,
      stdin: stdin,
    );
    if (batchOrError.error != null) return batchOrError.error!;
    final paramsOrError = await _connectParams(
      identity: argsOrError.identity,
      user: argsOrError.user,
      host: argsOrError.host,
      port: argsOrError.port,
      env: env,
      command: 'sftp',
    );
    if (paramsOrError.error != null) return paramsOrError.error!;
    return _withConnection(
      paramsOrError.params!,
      command: 'sftp',
      host: argsOrError.host,
      timeout: timeout,
      action: (conn, operationTimeout) async {
        final ftp = await conn.openSftp().timeout(operationTimeout);
        return _runSftpBatch(ftp, batchOrError.batch, cwd);
      },
    );
  }

  /// Parses `sftp` options (`-i`, `-b`, `-P`) and the `[user@]host`
  /// destination. Returns the usage-error result for any malformed
  /// invocation.
  static _SftpArgs _parseSftpArgs(
    List<String> args, {
    required Map<String, String> env,
  }) {
    _SftpArgs usage([SandboxBuiltinResult? result]) => (
      error: result ?? _error(_sftpUsage, 2),
      identity: null,
      batchFile: null,
      user: '',
      host: '',
      port: 0,
    );
    final scan = _SshArgScan(label: 'sftp', usage: _sftpUsage);
    if (!_scanSshOptions(args, scan, _sftpConsumeOption)) {
      return usage(scan.error);
    }
    var i = scan.next;
    if (i >= args.length) return usage();
    final destination = args[i];
    final remote = _parseDestination(destination, env: env);
    if (remote == null) return usage();
    return (
      error: null,
      identity: scan.identity,
      batchFile: scan.batchFile,
      user: remote.user,
      host: remote.host,
      port: scan.port,
    );
  }

  /// Resolves the batch text: the `-b` file (a sandbox path) or piped
  /// [stdin]. Returns the usage-error result when neither is available.
  Future<({SandboxBuiltinResult? error, String batch})> _sftpBatchInput({
    required String? batchFile,
    required List<int>? stdin,
  }) async {
    if (batchFile != null) {
      final bytes = await readBinaryFile(batchFile);
      if (bytes == null) {
        return (
          error: _error('sftp: $batchFile: No such file or directory\n', 2),
          batch: '',
        );
      }
      return (error: null, batch: utf8.decode(bytes, allowMalformed: true));
    }
    if (stdin != null) {
      return (error: null, batch: utf8.decode(stdin, allowMalformed: true));
    }
    return (
      error: _error(
        'sftp: no batch input: pipe commands on stdin or use -b '
        '(interactive sessions are not supported)\n',
        2,
      ),
      batch: '',
    );
  }

  Future<SandboxBuiltinResult> _runSftpBatch(
    SandboxSshFtp ftp,
    String batch,
    String cwd,
  ) async {
    final state = _SftpBatchState(initialLocalCwd: _normalizeLocal(cwd));
    for (final line in _parseSftpBatchLines(batch)) {
      if (_isSftpExitCommand(line.command)) {
        return _ok(state.stdout.takeBytes());
      }
      final handler = _sftpHandlerFor(line.command);
      if (handler == null) {
        return _sftpFail('unknown command: ${line.command}');
      }
      try {
        final terminal = await handler(ftp, line.args, state);
        if (terminal != null) return terminal;
      } on Object catch (e) {
        return _sftpFail('${line.line}: $e');
      }
    }
    return _ok(state.stdout.takeBytes());
  }

  /// `exit`/`quit`/`bye` end the batch immediately.
  static bool _isSftpExitCommand(String command) =>
      command == 'exit' || command == 'quit' || command == 'bye';

  /// Resolves the handler for one sftp opcode, or null when unknown.
  ///
  /// gh-1848 tier 3 split: the original single opcode switch, halved in
  /// the same order — inspect/move opcodes ([_sftpQueryHandler]) before
  /// transfer/mutate opcodes ([_sftpTransferHandler]); the case labels are
  /// disjoint so the `??` fallback cannot change a lookup.
  _SftpCommandHandler? _sftpHandlerFor(String command) {
    return _sftpQueryHandler(command) ?? _sftpTransferHandler(command);
  }

  /// pwd/lpwd/cd/lcd/ls: inspect or move; never transfer files.
  _SftpCommandHandler? _sftpQueryHandler(String command) {
    return switch (command) {
      'pwd' => _sftpPwd,
      'lpwd' => _sftpLpwd,
      'cd' => _sftpCd,
      'lcd' => _sftpLcd,
      'ls' => _sftpLs,
      _ => null,
    };
  }

  /// get/put/mkdir/rm/rmdir: transfer or mutate files.
  _SftpCommandHandler? _sftpTransferHandler(String command) {
    return switch (command) {
      'get' => _sftpGet,
      'put' => _sftpPut,
      'mkdir' => _sftpMkdir,
      'rm' => _sftpRm,
      'rmdir' => _sftpRmdir,
      _ => null,
    };
  }

  /// Usage failure inside an sftp batch: aborts the run with exit 1.
  static SandboxBuiltinResult _sftpFail(String message) =>
      _error('sftp: $message\n', 1);

  /// Tokenizes a batch: one command per line, blank lines and `#` comments
  /// skipped, whitespace-split tokens.
  static List<({String line, String command, List<String> args})>
  _parseSftpBatchLines(String batch) {
    final lines = <({String line, String command, List<String> args})>[];
    for (final rawLine in const LineSplitter().convert(batch)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final tokens = line.split(RegExp(r'\s+'));
      lines.add((line: line, command: tokens.first, args: tokens.sublist(1)));
    }
    return lines;
  }

  Future<SandboxBuiltinResult?> _sftpPwd(
    SandboxSshFtp ftp,
    List<String> args,
    _SftpBatchState state,
  ) async {
    state.stdout.add(
      utf8.encode('Remote working directory: ${state.remoteCwd}\n'),
    );
    return null;
  }

  Future<SandboxBuiltinResult?> _sftpLpwd(
    SandboxSshFtp ftp,
    List<String> args,
    _SftpBatchState state,
  ) async {
    state.stdout.add(
      utf8.encode('Local working directory: ${state.localCwd}\n'),
    );
    return null;
  }

  Future<SandboxBuiltinResult?> _sftpCd(
    SandboxSshFtp ftp,
    List<String> args,
    _SftpBatchState state,
  ) async {
    if (args.length != 1) return _sftpFail('cd: missing operand');
    final path = state.remoteResolve(args.single);
    final stat = await ftp.stat(path);
    if (stat == null) {
      return _sftpFail('cd: ${args.single}: No such file or directory');
    }
    if (!stat.isDirectory) {
      return _sftpFail('cd: ${args.single}: Not a directory');
    }
    state.remoteCwd = path;
    return null;
  }

  Future<SandboxBuiltinResult?> _sftpLcd(
    SandboxSshFtp ftp,
    List<String> args,
    _SftpBatchState state,
  ) async {
    if (args.length != 1) return _sftpFail('lcd: missing operand');
    final path = state.localResolve(args.single);
    if (await localKind(path) != SandboxSshEntryKind.directory) {
      return _sftpFail('lcd: ${args.single}: Not a directory');
    }
    state.localCwd = path;
    return null;
  }

  Future<SandboxBuiltinResult?> _sftpLs(
    SandboxSshFtp ftp,
    List<String> args,
    _SftpBatchState state,
  ) async {
    if (args.length > 1) return _sftpFail('ls: too many operands');
    final path = args.isEmpty
        ? state.remoteCwd
        : state.remoteResolve(args.single);
    final entries = await ftp.listdir(path);
    for (final entry in entries) {
      if (entry.name == '.' || entry.name == '..') continue;
      state.stdout.add(utf8.encode('${entry.longname ?? entry.name}\n'));
    }
    return null;
  }

  Future<SandboxBuiltinResult?> _sftpGet(
    SandboxSshFtp ftp,
    List<String> args,
    _SftpBatchState state,
  ) async {
    if (args.isEmpty || args.length > 2) {
      return _sftpFail('usage: get remote-path [local-path]');
    }
    final remotePath = state.remoteResolve(args.first);
    final stat = await ftp.stat(remotePath);
    if (stat == null) {
      return _sftpFail('get: ${args.first}: No such file or directory');
    }
    if (stat.isDirectory) {
      return _sftpFail('get: ${args.first}: is a directory (use scp -r)');
    }
    final localPath = state.localResolve(
      args.length == 2 ? args[1] : _baseName(remotePath),
    );
    final bytes = await ftp.readFile(remotePath);
    await writeBinaryFile(localPath, bytes);
    return null;
  }

  Future<SandboxBuiltinResult?> _sftpPut(
    SandboxSshFtp ftp,
    List<String> args,
    _SftpBatchState state,
  ) async {
    if (args.isEmpty || args.length > 2) {
      return _sftpFail('usage: put local-path [remote-path]');
    }
    final localPath = state.localResolve(args.first);
    final kind = await localKind(localPath);
    if (kind == null) {
      return _sftpFail('put: ${args.first}: No such file or directory');
    }
    if (kind == SandboxSshEntryKind.directory) {
      return _sftpFail('put: ${args.first}: is a directory (use scp -r)');
    }
    final bytes = await readBinaryFile(localPath);
    if (bytes == null) {
      return _sftpFail('put: ${args.first}: No such file or directory');
    }
    final remotePath = args.length == 2
        ? state.remoteResolve(args[1])
        : _remoteJoin(state.remoteCwd, _baseName(localPath));
    await ftp.writeFile(remotePath, bytes);
    return null;
  }

  Future<SandboxBuiltinResult?> _sftpMkdir(
    SandboxSshFtp ftp,
    List<String> args,
    _SftpBatchState state,
  ) async {
    if (args.length != 1) return _sftpFail('mkdir: missing operand');
    await ftp.mkdir(state.remoteResolve(args.single));
    return null;
  }

  Future<SandboxBuiltinResult?> _sftpRm(
    SandboxSshFtp ftp,
    List<String> args,
    _SftpBatchState state,
  ) async {
    if (args.length != 1) return _sftpFail('rm: missing operand');
    await ftp.remove(state.remoteResolve(args.single));
    return null;
  }

  Future<SandboxBuiltinResult?> _sftpRmdir(
    SandboxSshFtp ftp,
    List<String> args,
    _SftpBatchState state,
  ) async {
    if (args.length != 1) return _sftpFail('rmdir: missing operand');
    await ftp.rmdir(state.remoteResolve(args.single));
    return null;
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
  static String _normalizeLocal(String path) => normalizeLexicalPath(path);
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

/// One sftp opcode handler: given the batch context (ftp channel, argv,
/// mutable state), returns the terminal batch result — or null to keep
/// executing the batch.
typedef _SftpCommandHandler =
    Future<SandboxBuiltinResult?> Function(
      SandboxSshFtp ftp,
      List<String> args,
      _SftpBatchState state,
    );

/// Mutable state of one sftp batch run: the working directories advanced by
/// `cd`/`lcd` and the stdout accumulated by the printing opcodes.
final class _SftpBatchState {
  _SftpBatchState({required String initialLocalCwd})
    : localCwd = initialLocalCwd;

  /// stdout of the batch (`pwd`, `lpwd`, `ls`).
  final stdout = BytesBuilder(copy: false);

  /// Remote working directory (`.` until the first `cd`).
  var remoteCwd = '.';

  /// Local sandbox working directory (starts at the shell's cwd).
  String localCwd;

  /// Resolves [path] against the remote working directory (POSIX).
  String remoteResolve(String path) => path.startsWith('/')
      ? p.posix.normalize(path)
      : p.posix.normalize(p.posix.join(remoteCwd, path));

  /// Resolves [path] against the local sandbox working directory.
  String localResolve(String path) => path.startsWith('/')
      ? SandboxSshBuiltins._normalizeLocal(path)
      : SandboxSshBuiltins._normalizeLocal('$localCwd/$path');
}
