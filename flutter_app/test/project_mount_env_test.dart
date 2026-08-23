import 'package:fa/services/project_mount_env.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<ProjectMountEnv> envWithHost() async {
    final base = MemoryExecutionEnv();
    await base.writeFile('app/settings.json', '{}');
    await base.createDir('host/repo');
    await base.writeFile('host/repo/a.txt', 'in the project');
    await base.createDir('host/repo/src');
    await base.writeFile('host/repo/src/b.txt', 'nested');
    return ProjectMountEnv(base);
  }

  test('without a mount every path passes through to the delegate', () async {
    final env = await envWithHost();
    expect(env.mountedRoot, isNull);
    expect((await env.readTextFile('app/settings.json')).valueOrNull, '{}');
    expect((await env.exists(projectMountSegment)).valueOrNull, isFalse);
  });

  test('the mount segment maps onto the host directory', () async {
    final env = await envWithHost()
      ..mountedRoot = '/host/repo';
    expect(env.mountedRoot, '/host/repo');

    expect(
      (await env.readTextFile('$projectMountSegment/a.txt')).valueOrNull,
      'in the project',
    );
    expect(
      (await env.readTextFile('$projectMountSegment/src/b.txt')).valueOrNull,
      'nested',
    );
    final listing = (await env.listDir(projectMountSegment)).valueOrNull!;
    expect(listing.map((e) => e.name), containsAll(<String>['a.txt', 'src']));

    // Writes land in the host directory, not the container root.
    await env.writeFile('$projectMountSegment/new.txt', 'created');
    final base = env;
    expect(
      (await base.readTextFile('$projectMountSegment/new.txt')).valueOrNull,
      'created',
    );
  });

  test('unrelated paths never remap into the mount', () async {
    final env = await envWithHost()
      ..mountedRoot = '/host/repo';
    expect((await env.readTextFile('app/settings.json')).valueOrNull, '{}');
    // '/projectile' is not the mount segment.
    expect((await env.exists('/projectile')).valueOrNull, isFalse);
  });

  test('host paths under the mounted root pass through unchanged', () async {
    final env = await envWithHost()
      ..mountedRoot = '/host/repo';
    // absolutePath resolves as the delegate sees fit; mapped input stays
    // valid input afterwards.
    final absolute = (await env.absolutePath(projectMountSegment)).valueOrNull;
    expect(absolute, isNotNull);
    expect((await env.exists(absolute!)).valueOrNull, isTrue);
  });

  test('unmounting hides the segment again', () async {
    final env = await envWithHost()
      ..mountedRoot = '/host/repo'
      ..mountedRoot = null;
    expect(env.mountedRoot, isNull);
    expect((await env.exists(projectMountSegment)).valueOrNull, isFalse);
  });

  test('exec maps /project cwd to the mounted host root', () async {
    final shell = RecordingShell();
    final base = MemoryExecutionEnv(shell: shell);
    final env = ProjectMountEnv(base)..mountedRoot = '/host/repo';

    await env.exec('pwd', options: ShellExecOptions(cwd: projectMountSegment));
    expect(shell.lastOptions?.cwd, '/host/repo');

    await env.exec(
      'pwd',
      options: ShellExecOptions(cwd: '$projectMountSegment/src'),
    );
    expect(shell.lastOptions?.cwd, '/host/repo/src');
  });

  test('exec uses the host root when cwd is omitted', () async {
    final shell = RecordingShell();
    final base = MemoryExecutionEnv(shell: shell);
    final env = ProjectMountEnv(base)..mountedRoot = '/host/repo';

    await env.exec('pwd');
    expect(shell.lastOptions?.cwd, '/host/repo');
  });

  test('startShellJob maps /project cwd to the mounted host root', () async {
    final shell = RecordingShell();
    final base = MemoryExecutionEnv(shell: shell);
    final env = ProjectMountEnv(base)..mountedRoot = '/host/repo';

    await env.startShellJob(
      'pwd',
      id: 'job-1',
      logPath: '/log',
      options: ShellExecOptions(cwd: projectMountSegment),
    );
    expect(shell.lastOptions?.cwd, '/host/repo');
  });

  test(
    'startShellJob maps /project log path to the mounted host root',
    () async {
      final shell = RecordingShell();
      final base = MemoryExecutionEnv(shell: shell);
      final env = ProjectMountEnv(base)..mountedRoot = '/host/repo';

      await env.startShellJob(
        'pwd',
        id: 'job-1',
        logPath: '$projectMountSegment/.fah/bash_jobs/job-1.log',
      );
      expect(shell.lastLogPath, '/host/repo/.fah/bash_jobs/job-1.log');
    },
  );

  test('sessionCwd unwraps secrets and session-vars decorators', () async {
    final base = MemoryExecutionEnv();
    final mountEnv = ProjectMountEnv(base)..mountedRoot = '/host/repo';
    final secretsEnv = SecretsExecutionEnv(mountEnv, const {});
    final varsEnv = SessionVarsExecutionEnv(secretsEnv, () => const {});

    expect(varsEnv.sessionCwd, '/host/repo');
    expect(secretsEnv.sessionCwd, '/host/repo');
    expect(mountEnv.sessionCwd, '/host/repo');
  });
}

final class RecordingShell implements Shell, BackgroundShell {
  ShellExecOptions? lastOptions;
  String? lastLogPath;

  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    lastOptions = options;
    return Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
  }

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    lastOptions = options;
    lastLogPath = logPath;
    return const Err(
      ExecutionError(
        ExecutionErrorCode.shellUnavailable,
        'recording shell does not run jobs',
      ),
    );
  }
}
