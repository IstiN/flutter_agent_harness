// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Host tests for the pure-Dart ssh/scp/sftp builtins in `sandbox_ssh.dart`.
///
/// Everything runs offline against an in-memory fake remote (the injected
/// [SandboxSshConnector] never touches the network); the dartssh2 transport
/// itself is exercised by the gated live test in
/// `integration_test/ssh_exec_test.dart`.
library;

import 'dart:convert';

import 'package:fa/sandbox_ssh.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('resolveSshIdentityPem', () {
    const pemA = '-----BEGIN PRIVATE KEY-----\nA\n-----END PRIVATE KEY-----';
    const pemB = '-----BEGIN PRIVATE KEY-----\nB\n-----END PRIVATE KEY-----';

    String? Function(String) reader(Map<String, String> files) =>
        (path) => files[path];

    test('explicit -i path wins and never falls through', () {
      final files = {'/keys/a': pemA, '/.ssh/id_ed25519': pemB};
      expect(
        resolveSshIdentityPem(
          identityPath: '/keys/a',
          env: const {},
          readFile: reader(files),
        ),
        pemA,
      );
      // An unreadable/non-PEM -i must NOT silently use a default key.
      expect(
        resolveSshIdentityPem(
          identityPath: '/keys/missing',
          env: const {'SSH_KEY': pemA},
          readFile: reader(files),
        ),
        isNull,
      );
      expect(
        resolveSshIdentityPem(
          identityPath: '/keys/not-a-key',
          env: const {},
          readFile: reader({'/keys/not-a-key': 'hello'}),
        ),
        isNull,
      );
    });

    test('SSH_KEY inline PEM beats SSH_KEY_PATH and defaults', () {
      final files = {'/keys/b': pemB, '/.ssh/id_rsa': pemB};
      expect(
        resolveSshIdentityPem(
          env: const {'SSH_KEY': pemA, 'SSH_KEY_PATH': '/keys/b'},
          readFile: reader(files),
        ),
        pemA,
      );
    });

    test('SSH_KEY_PATH beats the default identity files', () {
      final files = {'/keys/b': pemB, '/.ssh/id_ed25519': pemA};
      expect(
        resolveSshIdentityPem(
          env: const {'SSH_KEY_PATH': '/keys/b'},
          readFile: reader(files),
        ),
        pemB,
      );
    });

    test('defaults are probed in ed25519/rsa/ecdsa order', () {
      expect(
        resolveSshIdentityPem(
          env: const {},
          readFile: reader({'/.ssh/id_rsa': pemA, '/.ssh/id_ed25519': pemB}),
        ),
        pemB,
      );
      expect(
        resolveSshIdentityPem(
          env: const {},
          readFile: reader({'/.ssh/id_ecdsa': pemA}),
        ),
        pemA,
      );
      expect(
        resolveSshIdentityPem(env: const {}, readFile: reader(const {})),
        isNull,
      );
    });
  });

  group('ssh builtin', () {
    test('usage errors exit 2 without connecting', () async {
      final h = _Harness();
      var r = await h.builtins.ssh(const []);
      expect(r.exitCode, 2);
      expect(_text(r.stderr), contains('usage: ssh'));

      r = await h.builtins.ssh(const ['-z', 'user@host', 'cmd']);
      expect(r.exitCode, 2);
      expect(_text(r.stderr), contains('unknown option'));

      r = await h.builtins.ssh(const ['-p', 'notaport', 'user@host', 'cmd']);
      expect(r.exitCode, 2);
      expect(_text(r.stderr), contains('bad port'));

      r = await h.builtins.ssh(const ['-p']);
      expect(r.exitCode, 2);

      r = await h.builtins.ssh(const ['user@host']);
      expect(r.exitCode, 2);
      expect(_text(r.stderr), contains('missing command'));
      expect(_text(r.stderr), contains('interactive'));

      expect(h.connections, isEmpty);
    });

    test('--help and --version exit 0 without connecting', () async {
      final h = _Harness();
      var r = await h.builtins.ssh(const ['--help']);
      expect(r.exitCode, 0);
      expect(_text(r.stdout), contains('usage: ssh'));
      r = await h.builtins.ssh(const ['--version']);
      expect(r.exitCode, 0);
      expect(_text(r.stdout), contains('dartssh2'));
      expect(h.connections, isEmpty);
    });

    test('exec maps stdout/stderr and the remote exit code', () async {
      final h = _Harness();
      h.remote.onExec = (command, stdin) => const SandboxSshExecResult(
        stdout: [111, 117, 116],
        stderr: [101, 114, 114],
        exitCode: 42,
      );
      final r = await h.builtins.ssh(const ['bob@example.com', 'echo', 'hi']);
      expect(r.exitCode, 42);
      expect(_text(r.stdout), 'out');
      expect(_text(r.stderr), 'err');
      expect(h.remote.execLog.single.command, 'echo hi');
      expect(h.connections.single.host, 'example.com');
      expect(h.connections.single.port, 22);
      expect(h.connections.single.username, 'bob');
      expect(h.connections.single.identityPem, _Harness.fakePem);
    });

    test('flags -i/-l/-p and the USER env default are honored', () async {
      final h = _Harness();
      var r = await h.builtins.ssh(
        const ['-i', '/keys/a', '-l', 'alice', '-p', '2222', 'host', 'true'],
        env: const {'USER': 'carol'},
      );
      expect(r.exitCode, 0);
      expect(h.identityCalls.single, '/keys/a');
      var params = h.connections.single;
      expect(params.username, 'alice');
      expect(params.port, 2222);

      r = await h.builtins.ssh(
        const ['host', 'true'],
        env: const {'USER': 'carol'},
      );
      expect(r.exitCode, 0);
      expect(h.connections.last.username, 'carol');

      r = await h.builtins.ssh(const ['host', 'true']);
      expect(r.exitCode, 0);
      expect(h.connections.last.username, 'fah');
    });

    test('passphrase and password envs flow into connect params', () async {
      final h = _Harness();
      final r = await h.builtins.ssh(
        const ['user@host', 'true'],
        env: const {'SSH_PASSPHRASE': 'pw1', 'SSH_PASSWORD': 'pw2'},
      );
      expect(r.exitCode, 0);
      expect(h.connections.single.passphrase, 'pw1');
      expect(h.connections.single.password, 'pw2');
    });

    test('piped stdin is forwarded to the remote process', () async {
      final h = _Harness();
      h.remote.onExec = (command, stdin) => SandboxSshExecResult(
        stdout: stdin ?? const [],
        stderr: const [],
        exitCode: 0,
      );
      final r = await h.builtins.ssh(const [
        'user@host',
        'cat',
      ], stdin: utf8.encode('hello\n'));
      expect(r.exitCode, 0);
      expect(_text(r.stdout), 'hello\n');
      expect(utf8.decode(h.remote.execLog.single.stdin!), 'hello\n');
    });

    test('missing key and missing -i file exit 1', () async {
      final h = _Harness()..identityPem = null;
      var r = await h.builtins.ssh(const ['user@host', 'true']);
      expect(r.exitCode, 1);
      expect(_text(r.stderr), contains('no SSH key'));
      expect(h.connections, isEmpty);

      r = await h.builtins.ssh(
        const ['user@host', 'true'],
        env: const {'SSH_PASSWORD': 'pw'},
      );
      expect(r.exitCode, 0, reason: 'password-only auth must not need a key');
      expect(h.connections.single.identityPem, isNull);
      expect(h.connections.single.password, 'pw');

      final h2 = _Harness()..identityPem = null;
      r = await h2.builtins.ssh(const ['-i', '/nope', 'user@host', 'true']);
      expect(r.exitCode, 1);
      expect(_text(r.stderr), contains('/nope'));
      expect(_text(r.stderr), contains('no such identity file'));
      expect(h2.connections, isEmpty);
    });

    test(
      'connect and exec failures exit 1; null exit code maps to 1',
      () async {
        final h = _Harness()..connectError = StateError('Connection refused');
        var r = await h.builtins.ssh(const ['user@host', 'true']);
        expect(r.exitCode, 1);
        expect(_text(r.stderr), contains('host'));
        expect(_text(r.stderr), contains('Connection refused'));

        final h2 = _Harness();
        h2.remote.onExec = (command, stdin) =>
            const SandboxSshExecResult(stdout: [], stderr: [], exitCode: null);
        r = await h2.builtins.ssh(const ['user@host', 'true']);
        expect(r.exitCode, 1);
      },
    );
  });

  group('scp builtin', () {
    test('usage errors exit 2 without connecting', () async {
      final h = _Harness();
      var r = await h.builtins.scp(const ['onlyone']);
      expect(r.exitCode, 2);
      expect(_text(r.stderr), contains('usage: scp'));

      r = await h.builtins.scp(const ['/a', '/b']);
      expect(r.exitCode, 2);
      expect(_text(r.stderr), contains('no remote operand'));

      r = await h.builtins.scp(const ['u@h1:/a', 'u@h2:/b']);
      expect(r.exitCode, 2);
      expect(_text(r.stderr), contains('third-party'));

      r = await h.builtins.scp(const ['/a', 'u@h:/b', 'u@h:/c']);
      expect(r.exitCode, 2);
      expect(_text(r.stderr), contains('mix'));

      r = await h.builtins.scp(const ['u@h1:/a', 'u@h2:/b', '/c']);
      expect(r.exitCode, 2);
      expect(_text(r.stderr), contains('one user@host'));

      r = await h.builtins.scp(const ['-P', 'x', 'u@h:/a', '/b']);
      expect(r.exitCode, 2);
      expect(h.connections, isEmpty);
    });

    test('uploads a single file to a remote path or directory', () async {
      final h = _Harness();
      h.local.write('/work/a.txt', 'alpha');
      h.remote.mkdirAll('/data');

      var r = await h.builtins.scp(const ['a.txt', 'u@h:/data/renamed.txt']);
      expect(r.exitCode, 0, reason: _text(r.stderr));
      expect(h.remote.read('/data/renamed.txt'), 'alpha');
      expect(h.connections.single.username, 'u');

      r = await h.builtins.scp(const ['a.txt', 'u@h:/data']);
      expect(r.exitCode, 0);
      expect(h.remote.read('/data/a.txt'), 'alpha');

      // `host:` (empty remote path) targets the remote home directory.
      r = await h.builtins.scp(const ['a.txt', 'u@h:']);
      expect(r.exitCode, 0);
      expect(h.remote.read('/a.txt'), 'alpha');
    });

    test('upload reports local errors with exit 1', () async {
      final h = _Harness();
      var r = await h.builtins.scp(const ['missing.txt', 'u@h:/x']);
      expect(r.exitCode, 1);
      expect(_text(r.stderr), contains('missing.txt'));

      h.local.writeTree('/work/dir', {'f.txt': 'x'});
      r = await h.builtins.scp(const ['dir', 'u@h:/x']);
      expect(r.exitCode, 1);
      expect(_text(r.stderr), contains('not a regular file'));
      expect(h.remote.files, isEmpty);
    });

    test('upload -r copies a directory tree recursively', () async {
      final h = _Harness();
      h.local.writeTree('/work/src', {
        'top.txt': '1',
        'sub/inner.txt': '2',
        'sub/deep/leaf.txt': '3',
      });
      // Target missing: the target becomes the copy (cp -r semantics).
      var r = await h.builtins.scp(const ['-r', 'src', 'u@h:/out']);
      expect(r.exitCode, 0, reason: _text(r.stderr));
      expect(h.remote.read('/out/top.txt'), '1');
      expect(h.remote.read('/out/sub/inner.txt'), '2');
      expect(h.remote.read('/out/sub/deep/leaf.txt'), '3');

      // Existing directory target: the source lands inside it.
      h.remote.mkdirAll('/existing');
      r = await h.builtins.scp(const ['-r', 'src', 'u@h:/existing']);
      expect(r.exitCode, 0, reason: _text(r.stderr));
      expect(h.remote.read('/existing/src/top.txt'), '1');
    });

    test('upload of several sources needs a remote directory', () async {
      final h = _Harness();
      h.local.write('/work/a.txt', 'A');
      h.local.write('/work/b.txt', 'B');

      var r = await h.builtins.scp(const ['a.txt', 'b.txt', 'u@h:/notthere']);
      expect(r.exitCode, 1);
      expect(_text(r.stderr), contains('not a directory'));

      h.remote.mkdirAll('/pool');
      r = await h.builtins.scp(const ['a.txt', 'b.txt', 'u@h:/pool']);
      expect(r.exitCode, 0);
      expect(h.remote.read('/pool/a.txt'), 'A');
      expect(h.remote.read('/pool/b.txt'), 'B');
    });

    test('downloads a single file to a local path or directory', () async {
      final h = _Harness();
      h.remote.write('/srv/report.txt', 'R');
      h.local.mkdirAll('/work/inbox');

      var r = await h.builtins.scp(const ['u@h:/srv/report.txt', 'copy.txt']);
      expect(r.exitCode, 0, reason: _text(r.stderr));
      expect(h.local.read('/work/copy.txt'), 'R');

      r = await h.builtins.scp(const ['u@h:/srv/report.txt', 'inbox']);
      expect(r.exitCode, 0);
      expect(h.local.read('/work/inbox/report.txt'), 'R');
    });

    test('download reports remote errors with exit 1', () async {
      final h = _Harness();
      var r = await h.builtins.scp(const ['u@h:/missing', 'x.txt']);
      expect(r.exitCode, 1);
      expect(_text(r.stderr), contains('/missing'));

      h.remote.mkdirAll('/srv/dir');
      r = await h.builtins.scp(const ['u@h:/srv/dir', 'x']);
      expect(r.exitCode, 1);
      expect(_text(r.stderr), contains('not a regular file'));
    });

    test('download -r copies a directory tree recursively', () async {
      final h = _Harness();
      h.remote.write('/srv/t/a.txt', 'A');
      h.remote.write('/srv/t/sub/b.txt', 'B');
      h.remote.dirs.add('/srv/t/empty');

      // Target missing: the target becomes the copy (cp -r semantics).
      var r = await h.builtins.scp(const ['-r', 'u@h:/srv/t', '/work/dst']);
      expect(r.exitCode, 0, reason: _text(r.stderr));
      expect(h.local.read('/work/dst/a.txt'), 'A');
      expect(h.local.read('/work/dst/sub/b.txt'), 'B');
      expect(h.local.dirs, contains('/work/dst/empty'));

      // Existing directory target: the source lands inside it.
      h.local.mkdirAll('/work/existing');
      r = await h.builtins.scp(const ['-r', 'u@h:/srv/t', '/work/existing']);
      expect(r.exitCode, 0, reason: _text(r.stderr));
      expect(h.local.read('/work/existing/t/a.txt'), 'A');
    });

    test('download of several sources needs a local directory', () async {
      final h = _Harness();
      h.remote.write('/srv/a', 'A');
      h.remote.write('/srv/b', 'B');

      var r = await h.builtins.scp(const ['u@h:/srv/a', 'u@h:/srv/b', 'file']);
      expect(r.exitCode, 1);
      expect(_text(r.stderr), contains('not a directory'));

      h.local.mkdirAll('/work/dir');
      r = await h.builtins.scp(
        const ['u@h:/srv/a', 'u@h:/srv/b', '/work/dir'],
        env: const {'USER': 'ignored'},
      );
      expect(r.exitCode, 0);
      expect(h.local.read('/work/dir/a'), 'A');
      expect(h.local.read('/work/dir/b'), 'B');
    });

    test('-P port and remote user are honored for downloads', () async {
      final h = _Harness();
      h.remote.write('/srv/a', 'A');
      final r = await h.builtins.scp(const ['-P', '2200', 'bob@h:/srv/a', 'x']);
      expect(r.exitCode, 0);
      expect(h.connections.single.port, 2200);
      expect(h.connections.single.username, 'bob');
    });
  });

  group('sftp builtin', () {
    test('usage errors exit 2 without connecting', () async {
      final h = _Harness();
      var r = await h.builtins.sftp(const []);
      expect(r.exitCode, 2);
      expect(_text(r.stderr), contains('usage: sftp'));

      r = await h.builtins.sftp(const ['-z', 'u@h']);
      expect(r.exitCode, 2);

      r = await h.builtins.sftp(const ['u@h']);
      expect(r.exitCode, 2);
      expect(_text(r.stderr), contains('no batch input'));

      r = await h.builtins.sftp(const ['-b', '/missing.batch', 'u@h']);
      expect(r.exitCode, 2);
      expect(_text(r.stderr), contains('/missing.batch'));
      expect(h.connections, isEmpty);
    });

    test('pwd/lpwd print the initial working directories', () async {
      final h = _Harness();
      final r = await h.builtins.sftp(
        const ['u@h'],
        stdin: utf8.encode('pwd\nlpwd\n'),
        cwd: '/work',
      );
      expect(r.exitCode, 0, reason: _text(r.stderr));
      expect(_text(r.stdout), contains('Remote working directory: .\n'));
      expect(_text(r.stdout), contains('Local working directory: /work\n'));
    });

    test('put/get/ls round-trip through the batch', () async {
      final h = _Harness();
      h.local.write('/work/note.txt', 'hello remote');
      h.remote.mkdirAll('/in');

      var r = await h.builtins.sftp(
        const ['u@h'],
        stdin: utf8.encode(
          'put note.txt /in/note.txt\n'
          'get /in/note.txt back.txt\n'
          'ls /in\n',
        ),
        cwd: '/work',
      );
      expect(r.exitCode, 0, reason: _text(r.stderr));
      expect(h.remote.read('/in/note.txt'), 'hello remote');
      expect(h.local.read('/work/back.txt'), 'hello remote');
      expect(_text(r.stdout), contains('note.txt'));
    });

    test(
      'cd/lcd move the working directories used by relative paths',
      () async {
        final h = _Harness();
        h.local.write('/work/sub/doc.txt', 'D');
        h.local.mkdirAll('/work/sub');
        h.remote.mkdirAll('/home/u');

        final r = await h.builtins.sftp(
          const ['u@h'],
          stdin: utf8.encode(
            'cd /home/u\n'
            'lcd sub\n'
            'pwd\n'
            'put doc.txt\n'
            'lpwd\n',
          ),
          cwd: '/work',
        );
        expect(r.exitCode, 0, reason: _text(r.stderr));
        expect(
          _text(r.stdout),
          contains('Remote working directory: /home/u\n'),
        );
        expect(
          _text(r.stdout),
          contains('Local working directory: /work/sub\n'),
        );
        expect(h.remote.read('/home/u/doc.txt'), 'D');
      },
    );

    test('mkdir/rm/rmdir batch commands drive the remote fs', () async {
      final h = _Harness();
      h.remote.write('/tmp/x.txt', 'X');
      final r = await h.builtins.sftp(
        const ['u@h'],
        stdin: utf8.encode('mkdir /newdir\nrm /tmp/x.txt\nrmdir /newdir\n'),
        cwd: '/work',
      );
      expect(r.exitCode, 0, reason: _text(r.stderr));
      expect(h.remote.dirs, isNot(contains('/newdir')));
      expect(h.remote.files.keys, isNot(contains('/tmp/x.txt')));
    });

    test(
      'comments and blank lines are skipped; exit stops the batch',
      () async {
        final h = _Harness();
        h.local.write('/work/a.txt', 'A');
        final r = await h.builtins.sftp(
          const ['u@h'],
          stdin: utf8.encode(
            '# a comment\n'
            '\n'
            'exit\n'
            'put a.txt\n',
          ),
          cwd: '/work',
        );
        expect(r.exitCode, 0, reason: _text(r.stderr));
        expect(h.remote.files, isEmpty, reason: 'put after exit must not run');
      },
    );

    test('a failing command aborts the batch with exit 1', () async {
      final h = _Harness();
      h.local.write('/work/a.txt', 'A');
      var r = await h.builtins.sftp(
        const ['u@h'],
        stdin: utf8.encode('get /missing\nput a.txt\n'),
        cwd: '/work',
      );
      expect(r.exitCode, 1);
      expect(_text(r.stderr), contains('get'));
      expect(h.remote.files, isEmpty, reason: 'batch aborts on first error');

      r = await h.builtins.sftp(
        const ['u@h'],
        stdin: utf8.encode('bogus-command\nput a.txt\n'),
        cwd: '/work',
      );
      expect(r.exitCode, 1);
      expect(_text(r.stderr), contains('unknown command'));
      expect(h.remote.files, isEmpty);

      r = await h.builtins.sftp(
        const ['u@h'],
        stdin: utf8.encode('put missing-local.txt\n'),
        cwd: '/work',
      );
      expect(r.exitCode, 1);
      expect(_text(r.stderr), contains('missing-local.txt'));
    });

    test('batch commands can come from a -b file', () async {
      final h = _Harness();
      h.local.write('/work/batch.txt', 'put a.txt /out.txt\n');
      h.local.write('/work/a.txt', 'A');
      final r = await h.builtins.sftp(const [
        '-b',
        'batch.txt',
        'u@h',
      ], cwd: '/work');
      expect(r.exitCode, 0, reason: _text(r.stderr));
      expect(h.remote.read('/out.txt'), 'A');
    });

    test('directory get/put is rejected in favor of scp -r', () async {
      final h = _Harness();
      h.local.mkdirAll('/work/dir');
      h.remote.mkdirAll('/rdir');
      var r = await h.builtins.sftp(
        const ['u@h'],
        stdin: utf8.encode('put dir\n'),
        cwd: '/work',
      );
      expect(r.exitCode, 1);
      expect(_text(r.stderr), contains('scp -r'));
      r = await h.builtins.sftp(
        const ['u@h'],
        stdin: utf8.encode('get /rdir\n'),
        cwd: '/work',
      );
      expect(r.exitCode, 1);
      expect(_text(r.stderr), contains('scp -r'));
    });
  });
}

String _text(List<int> bytes) => utf8.decode(bytes);

/// Wires [SandboxSshBuiltins] to in-memory fakes; the connector records
/// params and returns a [_FakeConnection] (or throws [connectError]).
final class _Harness {
  static const fakePem =
      '-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----';

  final remote = _FakeRemote();
  final local = _FakeLocal();
  final connections = <SandboxSshConnectParams>[];
  final identityCalls = <String?>[];

  /// PEM returned by the fake identity resolver (null = no key anywhere).
  String? identityPem = fakePem;

  /// Error thrown by the fake connector when set.
  Object? connectError;

  late final SandboxSshBuiltins builtins = SandboxSshBuiltins(
    connector: (params) async {
      final error = connectError;
      if (error != null) throw error;
      connections.add(params);
      return _FakeConnection(remote);
    },
    resolveIdentity: (path, env) async {
      identityCalls.add(path);
      return identityPem;
    },
    readBinaryFile: (path) async => local.files[local.resolve(path)],
    writeBinaryFile: (path, bytes) async => local.writeBytes(path, bytes),
    localKind: (path) async {
      final resolved = local.resolve(path);
      if (local.files.containsKey(resolved)) return SandboxSshEntryKind.file;
      if (local.dirs.contains(resolved)) return SandboxSshEntryKind.directory;
      return null;
    },
    listLocalDir: (path) async => local.list(path),
    makeLocalDir: (path) async => local.mkdirAll(local.resolve(path)),
  );
}

/// In-memory remote host: a POSIX filesystem plus the exec log/handler.
final class _FakeRemote {
  final dirs = <String>{'/'};
  final files = <String, List<int>>{};
  final execLog = <({String command, List<int>? stdin})>[];

  SandboxSshExecResult Function(String command, List<int>? stdin) onExec =
      (command, stdin) =>
          const SandboxSshExecResult(stdout: [], stderr: [], exitCode: 0);

  String norm(String path) =>
      p.posix.normalize(path.startsWith('/') ? path : '/$path');

  void mkdirAll(String path) {
    final n = norm(path);
    var current = '';
    for (final segment in n.split('/')) {
      if (segment.isEmpty) continue;
      current = '$current/$segment';
      dirs.add(current);
    }
  }

  void write(String path, String content) {
    final n = norm(path);
    mkdirAll(p.posix.dirname(n));
    files[n] = utf8.encode(content);
  }

  String read(String path) => utf8.decode(files[norm(path)]!);
}

final class _FakeConnection implements SandboxSshConnection {
  _FakeConnection(this.remote);

  final _FakeRemote remote;
  var closed = false;

  @override
  Future<SandboxSshExecResult> exec(String command, {List<int>? stdin}) async {
    remote.execLog.add((command: command, stdin: stdin));
    return remote.onExec(command, stdin);
  }

  @override
  Future<SandboxSshFtp> openSftp() async => _FakeFtp(remote);

  @override
  Future<void> close() async {
    closed = true;
  }
}

final class _FakeFtp implements SandboxSshFtp {
  const _FakeFtp(this.remote);

  final _FakeRemote remote;

  @override
  Future<SandboxSshStat?> stat(String path) async {
    final n = remote.norm(path);
    if (remote.dirs.contains(n)) {
      return const SandboxSshStat(isDirectory: true);
    }
    final file = remote.files[n];
    if (file != null) {
      return SandboxSshStat(isDirectory: false, size: file.length);
    }
    return null;
  }

  @override
  Future<List<SandboxSshDirEntry>> listdir(String path) async {
    final n = remote.norm(path);
    if (!remote.dirs.contains(n)) {
      throw StateError('ls $path: No such file or directory');
    }
    final entries = <SandboxSshDirEntry>[
      for (final dir in remote.dirs)
        if (dir != n && p.posix.dirname(dir) == n)
          SandboxSshDirEntry(name: p.posix.basename(dir), isDirectory: true),
      for (final file in remote.files.keys)
        if (p.posix.dirname(file) == n)
          SandboxSshDirEntry(name: p.posix.basename(file), isDirectory: false),
    ]..sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  @override
  Future<List<int>> readFile(String path) async {
    final file = remote.files[remote.norm(path)];
    if (file == null) throw StateError('get $path: No such file or directory');
    return file;
  }

  @override
  Future<void> writeFile(String path, List<int> bytes) async {
    final n = remote.norm(path);
    if (!remote.dirs.contains(p.posix.dirname(n))) {
      throw StateError('put $path: No such file or directory');
    }
    remote.files[n] = List<int>.from(bytes);
  }

  @override
  Future<void> mkdir(String path) async {
    final n = remote.norm(path);
    if (!remote.dirs.contains(p.posix.dirname(n))) {
      throw StateError('mkdir $path: No such file or directory');
    }
    if (remote.dirs.contains(n)) {
      throw StateError('mkdir $path: File exists');
    }
    remote.dirs.add(n);
  }

  @override
  Future<void> remove(String path) async {
    if (remote.files.remove(remote.norm(path)) == null) {
      throw StateError('rm $path: No such file or directory');
    }
  }

  @override
  Future<void> rmdir(String path) async {
    if (!remote.dirs.remove(remote.norm(path))) {
      throw StateError('rmdir $path: No such file or directory');
    }
  }
}

/// In-memory sandbox filesystem resolving paths like the shells do
/// (relative paths against [cwd], which matches the harness's `/work`).
final class _FakeLocal {
  final dirs = <String>{'/'};
  final files = <String, List<int>>{};

  /// Sandbox working directory for relative path resolution.
  var cwd = '/work';

  String resolve(String path) {
    final absolute = path.startsWith('/') ? path : '$cwd/$path';
    final segments = <String>[];
    for (final part in absolute.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(part);
    }
    return '/${segments.join('/')}';
  }

  void mkdirAll(String resolved) {
    var current = '';
    for (final segment in resolved.split('/')) {
      if (segment.isEmpty) continue;
      current = '$current/$segment';
      dirs.add(current);
    }
  }

  void writeBytes(String path, List<int> bytes) {
    final n = resolve(path);
    mkdirAll(p.posix.dirname(n));
    files[n] = List<int>.from(bytes);
  }

  void write(String path, String content) =>
      writeBytes(path, utf8.encode(content));

  void writeTree(String root, Map<String, String> entries) {
    entries.forEach((relative, content) {
      write('$root/$relative', content);
    });
  }

  String read(String path) => utf8.decode(files[resolve(path)]!);

  List<String> list(String path) {
    final n = resolve(path);
    if (!dirs.contains(n)) throw StateError('list $path: No such directory');
    return <String>[
      for (final dir in dirs)
        if (dir != n && p.posix.dirname(dir) == n) p.posix.basename(dir),
      for (final file in files.keys)
        if (p.posix.dirname(file) == n) p.posix.basename(file),
    ]..sort();
  }
}
