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
}
