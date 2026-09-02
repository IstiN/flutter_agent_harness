import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A [Shell] returning a canned result and recording its invocations.
class _RecordingShell implements Shell {
  final commands = <String>[];
  final options = <ShellExecOptions?>[];
  Result<ShellExecResult, ExecutionError> result = const Ok(
    ShellExecResult(stdout: 'out', stderr: '', exitCode: 0),
  );

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add(command);
    this.options.add(options);
    return result;
  }
}

CubeSpec spec({
  Set<String> allow = const {'git', 'echo'},
  bool networkAllowed = false,
  CubeResourceLimits resources = const CubeResourceLimits(),
  CubeEnvPolicy env = const CubeEnvPolicy(),
}) => CubeSpec(
  name: 'test-cube',
  tools: CubeToolPolicy(allow: allow),
  network: CubeNetworkPolicy(
    allow: networkAllowed ? [const CubeNetworkRule(host: '*')] : const [],
  ),
  resources: resources,
  env: env,
);

void main() {
  group('SandboxedShell', () {
    test('forwards an allowed command to the inner shell', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(inner, spec());
      final result = await shell.exec('git status');
      expect(result.getOrThrow().stdout, 'out');
      expect(inner.commands, ['git status']);
    });

    test('denied command never reaches the inner shell', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(inner, spec());
      final result = await shell.exec('rm -rf /');
      final exec = result.getOrThrow();
      expect(exec.exitCode, 127);
      expect(exec.stdout, '');
      expect(exec.stderr, startsWith('fa_cube[test-cube]:'));
      expect(inner.commands, isEmpty);
    });

    test('injects the cube env vars additively', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(
        inner,
        spec(
          env: CubeEnvPolicy(
            vars: [CubeEnvValue(name: 'FAH_MODE', value: 'sandboxed')],
          ),
        ),
      );
      await shell.exec('git status');
      expect(inner.options.last?.env, {'FAH_MODE': 'sandboxed'});

      // Per-call env entries win over the injected vars.
      await shell.exec(
        'git status',
        options: ShellExecOptions(env: {'FAH_MODE': 'custom', 'X': '1'}),
      );
      expect(inner.options.last?.env, {'FAH_MODE': 'custom', 'X': '1'});
    });

    test('an empty env policy forwards the options untouched', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(inner, spec());
      final sentinel = ShellExecOptions(env: {'X': '1'});
      await shell.exec('git status', options: sentinel);
      expect(inner.options.last, same(sentinel));
    });

    test('clamps the caller timeout to the cube timeout', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(
        inner,
        spec(resources: CubeResourceLimits(timeout: Duration(seconds: 1))),
      );
      await shell.exec(
        'git status',
        options: ShellExecOptions(timeout: Duration(seconds: 10)),
      );
      expect(inner.options.last?.timeout, const Duration(seconds: 1));
    });

    test('a null caller timeout inherits the cube timeout', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(
        inner,
        spec(resources: CubeResourceLimits(timeout: Duration(seconds: 1))),
      );
      await shell.exec('git status');
      expect(inner.options.last?.timeout, const Duration(seconds: 1));
    });

    test('a tighter caller timeout wins over the cube timeout', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(
        inner,
        spec(resources: CubeResourceLimits(timeout: Duration(seconds: 1))),
      );
      await shell.exec(
        'git status',
        options: ShellExecOptions(timeout: Duration(milliseconds: 500)),
      );
      expect(inner.options.last?.timeout, const Duration(milliseconds: 500));
    });

    test('updateSpec swaps the policy live', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(inner, spec());
      expect(
        (await shell.exec('curl https://x.dev')).getOrThrow().exitCode,
        127,
      );
      shell.updateSpec(
        spec(allow: {'git', 'echo', 'curl'}, networkAllowed: true),
      );
      expect(
        (await shell.exec('curl https://x.dev')).getOrThrow().stdout,
        'out',
      );
      expect(inner.commands, hasLength(1));
    });

    test('clearSpec switches to full passthrough', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(inner, spec());
      shell.clearSpec();
      final sentinel = ShellExecOptions(timeout: Duration(seconds: 3));
      expect(
        (await shell.exec('rm -rf /', options: sentinel)).getOrThrow().stdout,
        'out',
      );
      expect(inner.commands, ['rm -rf /']);
      expect(inner.options.last, same(sentinel));
    });
  });

  group('SandboxedShell kernel mode', () {
    CubeSpec kernelSpec({
      CubeEnvPolicy env = const CubeEnvPolicy(),
      String backend = 'kernel',
    }) => CubeSpec(
      name: 'test-cube',
      backend: CubeBackendMode.values.byName(backend),
      tools: const CubeToolPolicy(allow: {'git', 'echo'}),
      env: env,
    );

    test('stages the profile once and wraps allowed commands', () async {
      final inner = _RecordingShell();
      final fs = _FakeFs();
      final shell = SandboxedShell(inner, kernelSpec(), fs: fs, os: 'macos');

      await shell.exec('git status');
      final profilePath =
          '/work/.fah/cube-profiles/${cubeSpecCacheKey(kernelSpec())}.sb';
      expect(fs.writes.keys, [profilePath]);
      expect(fs.writes[profilePath], startsWith('(version 1)'));
      expect(inner.commands.single, contains("sandbox-exec -f '$profilePath'"));
      expect(inner.commands.single, contains('/usr/bin/env -i '));
      expect(inner.commands.single, contains("HOME='/work'"));
      expect(inner.commands.single, contains("TMPDIR='/work/.fah/tmp'"));
      expect(inner.commands.single, endsWith(shellQuote('git status')));

      // Second exec: no rewrite, same staging.
      await shell.exec('git log');
      expect(fs.writes.keys, [profilePath]);
      expect(inner.commands, hasLength(2));
    });

    test('injected env vars ride inside the clean environment', () async {
      final inner = _RecordingShell();
      final shell = SandboxedShell(
        inner,
        kernelSpec(
          env: const CubeEnvPolicy(
            vars: [CubeEnvValue(name: 'FAH_MODE', value: 'sandboxed')],
          ),
        ),
        fs: _FakeFs(),
        os: 'macos',
      );
      await shell.exec('git status');
      expect(inner.commands.single, contains("FAH_MODE='sandboxed'"));
    });

    test('policy mode never stages or wraps', () async {
      final inner = _RecordingShell();
      final fs = _FakeFs();
      final shell = SandboxedShell(
        inner,
        kernelSpec(backend: 'policy'),
        fs: fs,
        os: 'macos',
      );
      await shell.exec('git status');
      expect(fs.writes, isEmpty);
      expect(inner.commands.single, 'git status');
    });

    test('a kernel spec without a platform stays in policy mode', () async {
      final inner = _RecordingShell();
      final fs = _FakeFs();
      final shell = SandboxedShell(inner, kernelSpec(), fs: fs);
      await shell.exec('git status');
      expect(fs.writes, isEmpty);
      expect(inner.commands.single, 'git status');
    });

    test('an unenforcing platform (windows) stays in policy mode', () async {
      final inner = _RecordingShell();
      final fs = _FakeFs();
      final shell = SandboxedShell(inner, kernelSpec(), fs: fs, os: 'windows');
      await shell.exec('git status');
      expect(fs.writes, isEmpty);
      expect(inner.commands.single, 'git status');
    });

    test(
      'a missing sandbox-exec spawn failure maps to a clean error',
      () async {
        final inner = _RecordingShell()
          ..result = const Err(
            ExecutionError(
              ExecutionErrorCode.spawnError,
              'ProcessException: No such file or directory\n'
              '  Command: sandbox-exec -f /work/.fah/cube-profiles/x.sb ...',
            ),
          );
        final shell = SandboxedShell(
          inner,
          kernelSpec(),
          fs: _FakeFs(),
          os: 'macos',
        );
        final outcome = await shell.exec('git status');
        final error = outcome.errorOrNull;
        expect(error, isNotNull);
        expect(error!.code, ExecutionErrorCode.spawnError);
        expect(
          error.message,
          'fa_cube[test-cube]: kernel backend requires '
          'sandbox-exec on PATH',
        );
      },
    );

    test('an exit-127 not-found stderr maps to a clean error', () async {
      final inner = _RecordingShell()
        ..result = const Ok(
          ShellExecResult(
            stdout: '',
            stderr: 'sh: sandbox-exec: command not found',
            exitCode: 127,
          ),
        );
      final shell = SandboxedShell(
        inner,
        kernelSpec(),
        fs: _FakeFs(),
        os: 'macos',
      );
      final error = (await shell.exec('git status')).errorOrNull;
      expect(
        error!.message,
        'fa_cube[test-cube]: kernel backend requires sandbox-exec on PATH',
      );
    });

    test(
      'a wrapper refusing the sandbox (EPERM) maps to a clean error',
      () async {
        final inner = _RecordingShell()
          ..result = const Ok(
            ShellExecResult(
              stdout: '',
              stderr: 'unshare: unshare failed: Operation not permitted\n',
              exitCode: 1,
            ),
          );
        final shell = SandboxedShell(
          inner,
          kernelSpec(),
          fs: _FakeFs(),
          os: 'linux',
        );
        final error = (await shell.exec('git status')).errorOrNull;
        expect(error!.code, ExecutionErrorCode.spawnError);
        expect(
          error.message,
          'fa_cube[test-cube]: kernel backend unshare failed: '
          'unshare failed: Operation not permitted',
        );
      },
    );

    test('startupFailure probes once and reports a broken wrapper', () async {
      final inner = _RecordingShell()
        ..result = const Ok(
          ShellExecResult(
            stdout: '',
            stderr: 'unshare: unshare failed: Operation not permitted\n',
            exitCode: 1,
          ),
        );
      final shell = SandboxedShell(
        inner,
        kernelSpec(),
        fs: _FakeFs(),
        os: 'linux',
      );
      final note = await shell.startupFailure();
      expect(
        note,
        'fa_cube[test-cube]: kernel backend unshare failed: '
        'unshare failed: Operation not permitted',
      );
      expect(await shell.startupFailure(), note);
      expect(inner.commands.length, 1);
    });

    test('startupFailure returns null when the wrapper works', () async {
      final inner = _RecordingShell()
        ..result = const Ok(
          ShellExecResult(stdout: '', stderr: '', exitCode: 0),
        );
      final shell = SandboxedShell(
        inner,
        kernelSpec(),
        fs: _FakeFs(),
        os: 'linux',
      );
      expect(await shell.startupFailure(), isNull);
      expect(inner.commands.length, 1);
    });

    test(
      'a normal non-zero result inside the sandbox passes through',
      () async {
        final inner = _RecordingShell()
          ..result = const Ok(
            ShellExecResult(
              stdout: '',
              stderr: 'fatal: not a git repository',
              exitCode: 128,
            ),
          );
        final shell = SandboxedShell(
          inner,
          kernelSpec(),
          fs: _FakeFs(),
          os: 'macos',
        );
        final result = (await shell.exec('git status')).getOrThrow();
        expect(result.exitCode, 128);
      },
    );

    test('prepare wraps background job commands identically', () async {
      final inner = _RecordingShell();
      final fs = _FakeFs();
      final shell = SandboxedShell(inner, kernelSpec(), fs: fs, os: 'macos');
      final job = await shell.prepare('git status');
      expect(job, contains('sandbox-exec'));
      expect(fs.writes, hasLength(1));
    });

    test('a staged profile is reused when the file already exists', () async {
      final inner = _RecordingShell();
      final fs = _FakeFs();
      final shell = SandboxedShell(inner, kernelSpec(), fs: fs, os: 'macos');
      fs.files.add(
        '/work/.fah/cube-profiles/${cubeSpecCacheKey(kernelSpec())}.sb',
      );
      await shell.exec('git status');
      expect(fs.writes, isEmpty);
    });
  });
}

/// A [FileSystem] recording writes; only the staging-relevant members work.
class _FakeFs implements FileSystem {
  @override
  final String cwd = '/work';

  final Map<String, String> writes = {};
  final Set<String> files = {};

  @override
  Future<Result<bool, FileError>> exists(String path) async =>
      Ok(files.contains(path) || writes.containsKey(path));

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      Future.value(_record(path, content));

  Result<void, FileError> _record(String path, String content) {
    writes[path] = content;
    return const Ok(null);
  }

  @override
  Future<Result<String, FileError>> absolutePath(String path) async =>
      Ok('$cwd/$path');

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) async => const Ok(null);

  @override
  Future<Result<void, FileError>> appendFile(
    String path,
    String content,
  ) async => _record(path, content);

  Err<T, FileError> _missing<T>() =>
      const Err(FileError(FileErrorCode.notFound, 'not supported by _FakeFs'));

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) async =>
      _missing();

  @override
  Future<Result<String, FileError>> readTextFile(String path) async =>
      _missing();

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) async =>
      _missing();

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) async => _missing();

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) async => _missing();

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) async => _missing();

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) async =>
      _missing();

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) async => _missing();
}
