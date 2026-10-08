import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/tools/builtin_tools.dart' as bt;
import 'package:test/test.dart';

/// Issue #1408 AC3: the bash shape interceptor never rewrites
/// agent-authored identifiers.
///
/// The autopsy (configure-git-webserver, run 37736364517) recorded the
/// agent's own words: "The literal key filename got mangled by a filter —
/// I'll use a different key name." A filter had rewritten text inside a
/// FILENAME the agent was creating; the agent only found out via I/O
/// errors. The contract now: only a RECOGNIZED secret SHAPE (a vendor
/// token regex match) is ever rewritten, key-like-but-unmatched text
/// (filenames, entropy-heavy identifiers) is left byte-identical, and
/// every forced rewrite names exactly what changed in a tool-result
/// notice.

String _textOf(ToolExecutionResult result) {
  return result.content.whereType<TextContent>().map((b) => b.text).join();
}

/// A [Shell] returning a canned result and recording the command it was
/// handed — proves the EXECUTED command is the (possibly rewritten) one.
final class _RecordingShell implements Shell {
  _RecordingShell();

  String? lastCommand;
  Result<ShellExecResult, ExecutionError> result = const Ok(
    ShellExecResult(stdout: 'out', stderr: '', exitCode: 0),
  );

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    lastCommand = command;
    return result;
  }
}

void main() {
  group('redactBashCommandSecretShapes (issue #1408 AC3)', () {
    test('a command creating a key-like filename is NOT rewritten', () {
      // The autopsy's shape: an SSH key FILENAME whose random-ish tail
      // looks key-like. No vendor prefix, no full token shape.
      const command = 'ssh-keygen -t ed25519 -f id_ed25519_9f86d081882c48d6';
      expect(redactBashCommandSecretShapes(command), isNull);
    });

    test('a filename containing a key-like token survives untouched', () {
      const command =
          'touch deploy_key_AbC123xYz987Km5Pq '
          '&& chmod 600 deploy_key_AbC123xYz987Km5Pq';
      expect(redactBashCommandSecretShapes(command), isNull);
    });

    test('a high-entropy token that is not a vendor shape is NOT rewritten',
        () {
      const command =
          'curl -s -H "X-Api-Key: 9f86d081882c48665fd555eb3f2f4e73" '
          'https://api.example.test';
      expect(redactBashCommandSecretShapes(command), isNull);
    });

    test('a truncated AWS-shaped token (wrong length) is NOT rewritten', () {
      const command = 'touch AKIA1234.pem';
      expect(redactBashCommandSecretShapes(command), isNull);
    });

    test('a true secret SHAPE IS rewritten and the notice names it', () {
      const command =
          'aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE';
      final rewrite = redactBashCommandSecretShapes(command)!;

      expect(
        rewrite.command,
        'aws configure set aws_access_key_id [REDACTED:AWS Access Key]',
      );
      expect(rewrite.changes, hasLength(1));
      expect(rewrite.changes.single.label, 'AWS Access Key');
      expect(rewrite.changes.single.start, command.indexOf('AKIA'));
      // The notice names exactly what changed.
      expect(rewrite.notice, contains('1 secret-shaped value'));
      expect(rewrite.notice, contains('AWS Access Key'));
    });

    test('a GitHub token shape rewrites with its own label', () {
      final rewrite = redactBashCommandSecretShapes(
        'export GH_TOKEN=ghp_${'A' * 36}',
      )!;
      expect(rewrite.command, 'export GH_TOKEN=[REDACTED:GitHub Token]');
      expect(rewrite.notice, contains('GitHub Token'));
    });

    test('multiple shapes rewrite in place, left to right', () {
      final rewrite = redactBashCommandSecretShapes(
        'use AKIAIOSFODNN7EXAMPLE and ghp_${'B' * 36} here',
      )!;
      expect(rewrite.changes.map((c) => c.label).toList(), [
        'AWS Access Key',
        'GitHub Token',
      ]);
      expect(rewrite.command, contains('[REDACTED:AWS Access Key]'));
      expect(rewrite.command, contains('[REDACTED:GitHub Token]'));
    });

    test('null for a command without any secret shape', () {
      expect(redactBashCommandSecretShapes('ls -la /tmp'), isNull);
      expect(redactBashCommandSecretShapes(''), isNull);
    });

    test('a master-disabled redaction config never rewrites', () {
      // Review 5456649624 ⚠️: the same `redact:` section steers command
      // rewriting and result/job-log masking. `redact.enabled: false`
      // leaves job logs raw — it must leave commands untouched too.
      const command =
          'aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE';
      expect(
        redactBashCommandSecretShapes(
          command,
          config: const RedactionConfig(enabled: false),
        ),
        isNull,
      );
    });

    test('a config with the vendor layer off never rewrites', () {
      const command =
          'aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE';
      expect(
        redactBashCommandSecretShapes(
          command,
          config: const RedactionConfig(
            layerToggles: {RedactionLayer.vendor: false},
          ),
        ),
        isNull,
      );
    });

    test('a registered (approved) literal is exempt from rewriting', () {
      // Review 5456649624 ⚠️ escape hatch: a value the host registered as
      // a secret (request_secret / preconfig keys) is already masked in
      // transcripts by the pipeline's exact-value layer — the command must
      // still materialize it, or credential-setup tasks deterministically
      // fail (the configure-git-webserver autopsy class).
      const token = 'AKIAIOSFODNN7EXAMPLE';
      const command = 'aws configure set aws_access_key_id $token';
      expect(
        redactBashCommandSecretShapes(
          command,
          approvedLiterals: {token},
        ),
        isNull,
      );
    });

    test('an approved literal among other shapes rewrites only the rest', () {
      const token = 'AKIAIOSFODNN7EXAMPLE';
      final rewrite = redactBashCommandSecretShapes(
        'use $token and ghp_${'C' * 36}',
        approvedLiterals: {token},
      )!;
      expect(rewrite.changes.single.label, 'GitHub Token');
      expect(rewrite.command, contains(token));
      expect(rewrite.command, isNot(contains('$token and')));
      expect(rewrite.command, contains('[REDACTED:GitHub Token]'));
    });
  });

  group('bash tool applies the shape interceptor (issue #1408 AC3)', () {
    test('a true shape executes rewritten and the result carries the notice',
        () async {
      final shell = _RecordingShell();
      final tool = bt.shellTool(
        MemoryExecutionEnv(cwd: '/work', shell: shell),
        retryBackoff: Duration.zero,
      );
      final result = await tool.execute({
        'command': 'aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE',
      }, null, null);

      // The executed command is the REWRITTEN one: the raw secret never
      // reaches the shell, the job logs, or the session record.
      expect(shell.lastCommand, isNotNull);
      expect(shell.lastCommand, contains('[REDACTED:AWS Access Key]'));
      expect(shell.lastCommand, isNot(contains('AKIAIOSFODNN7EXAMPLE')));
      // The tool result NAMES what changed.
      final text = _textOf(result);
      expect(text, contains('[bash interceptor rewrote 1 secret-shaped value'));
      expect(text, contains('AWS Access Key'));
    });

    test('a key-like filename command runs byte-identically, no notice',
        () async {
      final shell = _RecordingShell();
      final tool = bt.shellTool(
        MemoryExecutionEnv(cwd: '/work', shell: shell),
        retryBackoff: Duration.zero,
      );
      const command = 'ssh-keygen -t ed25519 -f id_ed25519_9f86d081882c48d6';
      final result = await tool.execute({'command': command}, null, null);

      expect(shell.lastCommand, command);
      expect(_textOf(result), isNot(contains('[bash interceptor rewrote')));
    });

    test('shellTool honors redactionConfig: disabled executes verbatim',
        () async {
      final shell = _RecordingShell();
      final tool = bt.shellTool(
        MemoryExecutionEnv(cwd: '/work', shell: shell),
        retryBackoff: Duration.zero,
        redactionConfig: const RedactionConfig(enabled: false),
      );
      const command =
          'aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE';
      await tool.execute({'command': command}, null, null);

      expect(shell.lastCommand, command);
    });

    test('shellTool exempts host-registered secret literals', () async {
      final shell = _RecordingShell();
      const token = 'AKIAIOSFODNN7EXAMPLE';
      final tool = bt.shellTool(
        MemoryExecutionEnv(cwd: '/work', shell: shell),
        retryBackoff: Duration.zero,
        approvedSecretLiterals: () => {token},
      );
      await tool.execute({'command': 'echo $token'}, null, null);

      expect(shell.lastCommand, 'echo $token');
    });
  });
}
