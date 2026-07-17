// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import 'sandbox_ssh.dart';
import 'wasm_shell.dart';

/// dartssh2-backed SSH transport for the sandbox `ssh`/`scp`/`sftp`
/// builtins (`dart:io` only; the web shell reports exit 127 instead).
///
/// Keys come from the sandbox filesystem (`~/.ssh`, i.e. `/.ssh` — the
/// sandbox root is the agent's home), exactly like the git SSH transport in
/// `wasm_shell_git.dart`, via [resolveSshIdentityPem]. There is no
/// known_hosts store; host key verification is disabled (the same trade-off
/// as [SshGitTransport], documented there).
final class WasmSshCommands {
  /// Creates the command set bound to [shell].
  const WasmSshCommands(this._shell);

  final WasiSandboxShell _shell;

  /// Builds the shared builtins wired to the sandbox filesystem, resolving
  /// local path arguments against [cwd].
  SandboxSshBuiltins builtinsFor(String cwd) {
    String hostPath(String path) =>
        _shell.hostPathOf(_shell.resolveSandboxPathFor(path, cwd));
    return SandboxSshBuiltins(
      connector: _connect,
      resolveIdentity: _resolveIdentity,
      readBinaryFile: (path) async {
        final file = io.File(hostPath(path));
        if (!await file.exists()) return null;
        return file.readAsBytes();
      },
      writeBinaryFile: (path, bytes) async {
        final file = io.File(hostPath(path));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
      },
      localKind: (path) async {
        return switch (io.FileSystemEntity.typeSync(hostPath(path))) {
          io.FileSystemEntityType.file => SandboxSshEntryKind.file,
          io.FileSystemEntityType.directory => SandboxSshEntryKind.directory,
          _ => null,
        };
      },
      listLocalDir: (path) async {
        final names = <String>[];
        await for (final entity in io.Directory(
          hostPath(path),
        ).list(followLinks: false)) {
          names.add(p.basename(entity.path));
        }
        return names..sort();
      },
      makeLocalDir: (path) async {
        await io.Directory(hostPath(path)).create(recursive: true);
      },
    );
  }

  /// Resolves the identity PEM through [resolveSshIdentityPem] over the
  /// sandbox filesystem. Like the git transport, `SSH_KEY`/`SSH_KEY_PATH`
  /// are additionally looked up in the platform environment when the shell
  /// environment does not provide them.
  Future<String?> _resolveIdentity(
    String? identityPath,
    Map<String, String> env,
  ) async {
    final merged = <String, String>{
      for (final name in const ['SSH_KEY', 'SSH_KEY_PATH'])
        name: ?io.Platform.environment[name],
      ...env,
    };
    return resolveSshIdentityPem(
      identityPath: identityPath,
      env: merged,
      readFile: (sandboxPath) {
        final file = io.File(_shell.hostPathOf(sandboxPath));
        if (!file.existsSync()) return null;
        return file.readAsStringSync();
      },
    );
  }

  Future<SandboxSshConnection> _connect(SandboxSshConnectParams params) async {
    final socket = await SSHSocket.connect(
      params.host,
      params.port,
      timeout: params.connectTimeout,
    );
    try {
      final client = SSHClient(
        socket,
        username: params.username,
        identities: params.identityPem == null
            ? null
            : SSHKeyPair.fromPem(params.identityPem!, params.passphrase),
        onPasswordRequest: params.password == null
            ? null
            : () => params.password!,
        // The sandbox has no known_hosts store; host key pinning is the
        // caller's responsibility (same trade-off as SshGitTransport).
        disableHostkeyVerification: true,
      );
      return _DartSshConnection(client);
    } on Object {
      socket.destroy();
      rethrow;
    }
  }
}

/// [SandboxSshConnection] over a dartssh2 [SSHClient].
final class _DartSshConnection implements SandboxSshConnection {
  _DartSshConnection(this._client);

  final SSHClient _client;

  @override
  Future<SandboxSshExecResult> exec(String command, {List<int>? stdin}) async {
    final session = await _client.execute(command);
    if (stdin != null) {
      session.stdin.add(Uint8List.fromList(stdin));
    }
    await session.stdin.close();
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    await Future.wait<void>([
      session.stdout.forEach(out.add),
      session.stderr.forEach(err.add),
    ]);
    await session.done;
    return SandboxSshExecResult(
      stdout: out.takeBytes(),
      stderr: err.takeBytes(),
      exitCode: session.exitCode,
    );
  }

  @override
  Future<SandboxSshFtp> openSftp() async => _DartSshFtp(await _client.sftp());

  @override
  Future<void> close() async {
    _client.close();
  }
}

/// [SandboxSshFtp] over a dartssh2 [SftpClient].
final class _DartSshFtp implements SandboxSshFtp {
  const _DartSshFtp(this._sftp);

  final SftpClient _sftp;

  @override
  Future<SandboxSshStat?> stat(String path) async {
    try {
      final attrs = await _sftp.stat(path);
      return SandboxSshStat(isDirectory: attrs.isDirectory, size: attrs.size);
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) return null;
      rethrow;
    }
  }

  @override
  Future<List<SandboxSshDirEntry>> listdir(String path) async {
    final names = await _sftp.listdir(path);
    return [
      for (final name in names)
        SandboxSshDirEntry(
          name: name.filename,
          isDirectory: name.attr.isDirectory,
          longname: name.longname.isEmpty ? null : name.longname,
        ),
    ];
  }

  @override
  Future<List<int>> readFile(String path) async {
    final file = await _sftp.open(path, mode: SftpFileOpenMode.read);
    try {
      return await file.readBytes();
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> writeFile(String path, List<int> bytes) async {
    final file = await _sftp.open(
      path,
      mode:
          SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.writeBytes(
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      );
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> mkdir(String path) => _sftp.mkdir(path);

  @override
  Future<void> remove(String path) => _sftp.remove(path);

  @override
  Future<void> rmdir(String path) => _sftp.rmdir(path);
}
