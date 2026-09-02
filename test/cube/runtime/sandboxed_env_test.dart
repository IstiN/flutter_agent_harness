import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A shell recording [exec] invocations and acting as a [BackgroundShell].
class _RecordingShell implements Shell, BackgroundShell {
  final commands = <String>[];
  final jobs = <String>[];

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add(command);
    return Ok(const ShellExecResult(stdout: 'out', stderr: '', exitCode: 0));
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
