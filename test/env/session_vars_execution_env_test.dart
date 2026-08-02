import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A [Shell] returning a canned result and recording its invocations.
class _FakeShell implements Shell {
  Result<ShellExecResult, ExecutionError> result = const Ok(
    ShellExecResult(stdout: 'out', stderr: '', exitCode: 0),
  );
  String? lastCommand;
  ShellExecOptions? lastOptions;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    lastCommand = command;
    lastOptions = options;
    return result;
  }
}

void main() {
  group('SessionVarsExecutionEnv', () {
    test('injects the session vars into every exec', () async {
      final shell = _FakeShell();
      final env = SessionVarsExecutionEnv(
        MemoryExecutionEnv(cwd: '/work', shell: shell),
        () => const {
          sessionIdEnvVar: 'sess-1',
          sessionFileEnvVar: '/work/sessions/sess-1.jsonl',
          providerEnvVar: 'openai-completions',
          modelEnvVar: 'gpt-x',
        },
      );

      final result = await env.exec('echo hi');

      expect(result.getOrThrow().stdout, 'out');
      final env2 = shell.lastOptions?.env;
      expect(env2, {
        sessionIdEnvVar: 'sess-1',
        sessionFileEnvVar: '/work/sessions/sess-1.jsonl',
        providerEnvVar: 'openai-completions',
        modelEnvVar: 'gpt-x',
      });
    });

    test('the vars provider is consulted live per exec', () async {
      final shell = _FakeShell();
      var model = 'gpt-x';
      final env = SessionVarsExecutionEnv(
        MemoryExecutionEnv(cwd: '/work', shell: shell),
        () => {modelEnvVar: model},
      );

      await env.exec('one');
      expect(shell.lastOptions?.env, {modelEnvVar: 'gpt-x'});
      model = 'gpt-y';
      await env.exec('two');
      expect(shell.lastOptions?.env, {modelEnvVar: 'gpt-y'});
    });

    test('async vars providers are awaited', () async {
      final shell = _FakeShell();
      final env = SessionVarsExecutionEnv(
        MemoryExecutionEnv(cwd: '/work', shell: shell),
        () async => {sessionIdEnvVar: 'sess-async'},
      );

      await env.exec('echo hi');
      expect(shell.lastOptions?.env, {sessionIdEnvVar: 'sess-async'});
    });

    test('empty vars pass the options through untouched', () async {
      final shell = _FakeShell();
      final env = SessionVarsExecutionEnv(
        MemoryExecutionEnv(cwd: '/work', shell: shell),
        () => const {},
      );
      const options = ShellExecOptions(env: {'A': '1'});

      await env.exec('echo hi', options: options);

      expect(identical(shell.lastOptions, options), isTrue);
    });

    test('per-call env entries win over the injected vars', () async {
      final shell = _FakeShell();
      final env = SessionVarsExecutionEnv(
        MemoryExecutionEnv(cwd: '/work', shell: shell),
        () => const {modelEnvVar: 'gpt-x', sessionIdEnvVar: 'sess-1'},
      );

      await env.exec(
        'echo hi',
        options: const ShellExecOptions(env: {modelEnvVar: 'override'}),
      );

      expect(shell.lastOptions?.env, {
        modelEnvVar: 'override',
        sessionIdEnvVar: 'sess-1',
      });
    });

    test('composes with SecretsExecutionEnv without leaking secrets', () async {
      final shell = _FakeShell();
      const secretValue = 'super-secret-api-key';
      final secretsEnv = SecretsExecutionEnv(
        MemoryExecutionEnv(cwd: '/work', shell: shell),
        const {'MY_API_KEY': secretValue},
      );
      final env = SessionVarsExecutionEnv(
        secretsEnv,
        () => const {
          sessionIdEnvVar: 'sess-1',
          providerEnvVar: 'anthropic',
          modelEnvVar: 'claude-x',
        },
      );

      await env.exec('echo hi');

      final injected = shell.lastOptions!.env!;
      // Session vars AND secrets both reach the shell…
      expect(injected[sessionIdEnvVar], 'sess-1');
      expect(injected[modelEnvVar], 'claude-x');
      expect(injected['MY_API_KEY'], secretValue);
      // …but no session var carries a secret value.
      for (final name in [
        sessionIdEnvVar,
        sessionFileEnvVar,
        providerEnvVar,
        modelEnvVar,
      ]) {
        expect(injected[name], isNot(contains(secretValue)));
      }
      final redactor = SecretRedactor.fromSecrets(const {
        'MY_API_KEY': secretValue,
      });
      for (final entry in injected.entries) {
        if (entry.key.startsWith('FAH_')) {
          expect(redactor.redact(entry.value), entry.value);
        }
      }
    });

    test('file operations delegate to the wrapped env', () async {
      final env = SessionVarsExecutionEnv(
        MemoryExecutionEnv(cwd: '/work'),
        () => const {sessionIdEnvVar: 'sess-1'},
      );

      await env.writeFile('a.txt', 'hello');

      expect(env.cwd, '/work');
      expect((await env.readTextFile('a.txt')).valueOrNull, 'hello');
      expect(env.delegate, isA<MemoryExecutionEnv>());
    });
  });
}
