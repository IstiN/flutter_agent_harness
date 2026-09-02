import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A shell recording [exec] invocations and acting as a [BackgroundShell].
class _RecordingShell implements Shell, BackgroundShell {
  final commands = <String>[];
  final jobs = <String>[];

  Result<ShellExecResult, ExecutionError> execResult = const Ok(
    ShellExecResult(stdout: 'out', stderr: '', exitCode: 0),
  );

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add(command);
    return execResult;
  }

  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    jobs.add(command);
    return Err(
      ExecutionError(
        ExecutionErrorCode.unknown,
        'recording shell starts no real jobs',
      ),
    );
  }
}

CubeSpec spec(String name) => CubeSpec(
  name: name,
  tools: const CubeToolPolicy(allow: {'git'}),
  filesystem: const CubeFsPolicy(workspace: '/work'),
);

void main() {
  group('SandboxedExecutionEnv', () {
    test('routes writes through the fs guard', () async {
      final env = SandboxedExecutionEnv(
        MemoryExecutionEnv(cwd: '/work'),
        spec('test-cube'),
      );
      expect((await env.writeFile('a.txt', 'x')).isOk, isTrue);
      expect(
        (await env.writeFile('/etc/passwd', 'x')).errorOrNull!.code,
        FileErrorCode.permissionDenied,
      );
    });

    test('routes exec through the policy engine', () async {
      final inner = _RecordingShell();
      final env = SandboxedExecutionEnv(
        MemoryExecutionEnv(cwd: '/work', shell: inner),
        spec('test-cube'),
      );
      expect((await env.exec('git status')).getOrThrow().stdout, 'out');
      final denied = await env.exec('rm -rf /');
      expect(denied.getOrThrow().exitCode, 127);
      expect(denied.getOrThrow().stderr, startsWith('fa_cube[test-cube]:'));
      expect(inner.commands, ['git status']);
    });

    test('a denied job is never started', () async {
      final inner = _RecordingShell();
      final env = SandboxedExecutionEnv(
        MemoryExecutionEnv(cwd: '/work', shell: inner),
        spec('test-cube'),
      );
      final result = await env.startShellJob(
        'ssh evil',
        id: 'j1',
        logPath: '/tmp/j1.log',
      );
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.code, ExecutionErrorCode.spawnError);
      expect(result.errorOrNull!.message, startsWith('fa_cube[test-cube]:'));
      expect(inner.jobs, isEmpty);
    });

    test('an allowed job is forwarded', () async {
      final inner = _RecordingShell();
      final env = SandboxedExecutionEnv(
        MemoryExecutionEnv(cwd: '/work', shell: inner),
        spec('test-cube'),
      );
      await env.startShellJob('git log', id: 'j1', logPath: '/tmp/j1.log');
      expect(inner.jobs, ['git log']);
    });

    test('kernel mode wraps background jobs and stages the profile', () async {
      final inner = _RecordingShell();
      final env = SandboxedExecutionEnv(
        MemoryExecutionEnv(cwd: '/work', shell: inner),
        CubeSpec(
          name: 'test-cube',
          backend: CubeBackendMode.kernel,
          tools: const CubeToolPolicy(allow: {'git'}),
          filesystem: const CubeFsPolicy(workspace: '/work'),
        ),
        os: 'macos',
      );
      await env.startShellJob('git log', id: 'j1', logPath: '/tmp/j1.log');
      final job = inner.jobs.single;
      expect(job, contains('sandbox-exec'));
      expect(job, endsWith("'git log'"));
      // The SBPL profile is staged on the delegate filesystem.
      final profile = await env.readTextFile(
        '/work/.fah/cube-profiles/${cubeSpecCacheKey(env.activeSpec!)}.sb',
      );
      expect(profile.getOrThrow(), startsWith('(version 1)'));
    });

    test('a job is denied cleanly when the kernel wrapper is broken', () async {
      final inner = _RecordingShell()
        ..execResult = const Ok(
          ShellExecResult(
            stdout: '',
            stderr: 'unshare: unshare failed: Operation not permitted\n',
            exitCode: 1,
          ),
        );
      final env = SandboxedExecutionEnv(
        MemoryExecutionEnv(cwd: '/work', shell: inner),
        CubeSpec(
          name: 'test-cube',
          backend: CubeBackendMode.kernel,
          tools: const CubeToolPolicy(allow: {'git'}),
          filesystem: const CubeFsPolicy(workspace: '/work'),
        ),
        os: 'linux',
      );
      final result = await env.startShellJob(
        'git log',
        id: 'j1',
        logPath: '/tmp/j1.log',
      );
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.code, ExecutionErrorCode.spawnError);
      expect(
        result.errorOrNull!.message,
        'fa_cube[test-cube]: kernel backend unshare failed: '
        'unshare failed: Operation not permitted',
      );
      expect(inner.jobs, isEmpty);
    });

    test('backgroundJobsSupported delegates to the wrapped shell', () {
      final env = SandboxedExecutionEnv(
        MemoryExecutionEnv(cwd: '/work', shell: _RecordingShell()),
        spec('test-cube'),
      );
      expect(env.backgroundJobsSupported, isTrue);
      expect(
        SandboxedExecutionEnv(
          MemoryExecutionEnv(cwd: '/work'),
          spec('test-cube'),
        ).backgroundJobsSupported,
        isFalse,
      );
    });

    test('cwd forwards to the delegate', () {
      final env = SandboxedExecutionEnv(
        MemoryExecutionEnv(cwd: '/work'),
        spec('test-cube'),
      );
      expect(env.cwd, '/work');
    });

    test('activeSpec tracks updateSpec and clearSpec', () async {
      final delegate = MemoryExecutionEnv(cwd: '/work');
      final env = SandboxedExecutionEnv(delegate, spec('test-cube'));
      expect(env.activeSpec?.name, 'test-cube');

      env.updateSpec(spec('wide-cube'));
      expect(env.activeSpec?.name, 'wide-cube');
      // The swapped spec is enforced on the next call.
      expect(
        (await env.exec('rm -rf /')).getOrThrow().stderr,
        contains('fa_cube[wide-cube]'),
      );

      env.clearSpec();
      expect(env.activeSpec, isNull);
      // Passthrough: a path outside any workspace is writable again.
      expect((await env.writeFile('/etc/x', 'y')).isOk, isTrue);
    });
  });
}
