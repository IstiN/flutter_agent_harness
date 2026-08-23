@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/skills/skill_renderer.dart';
import 'package:test/test.dart';

class _FakeShell implements Shell {
  Map<String, ShellExecResult> canned = {};
  int exitCode = 0;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    final hit = canned[command];
    if (hit != null) return Ok(hit);
    return Ok(
      ShellExecResult(stdout: 'out:$command', stderr: '', exitCode: exitCode),
    );
  }
}

void main() {
  late MemoryExecutionEnv env;
  late _FakeShell shell;

  setUp(() {
    shell = _FakeShell();
    env = MemoryExecutionEnv(cwd: '/work', shell: shell);
  });

  Skill skillAt(String path, {SkillManifest manifest = SkillManifest.empty}) =>
      Skill(
        name: 's',
        description: 'd',
        filePath: path,
        scope: SkillScope.project,
        source: SkillSource.claude,
        manifest: manifest,
      );

  group('argument substitution', () {
    test(r'$ARGUMENTS and positional $0/$1/$ARGUMENTS[0]', () async {
      await env.createDir('/work/.claude/skills/fix');
      await env.writeFile(
        '/work/.claude/skills/fix/SKILL.md',
        '---\nname: fix\n---\n'
            'Fix \$ARGUMENTS using \$0 then \$1 (again: \$ARGUMENTS[0]).\n',
      );
      final result = await renderSkillBody(
        env,
        skillAt('/work/.claude/skills/fix/SKILL.md'),
        args: '123 main',
      );
      expect(result.body, 'Fix 123 main using 123 then main (again: 123).');
    });

    test('named arguments from the frontmatter list', () async {
      await env.createDir('/work/.claude/skills/mig');
      await env.writeFile(
        '/work/.claude/skills/mig/SKILL.md',
        '---\narguments: [src, dst]\n---\nMigrate \$src to \$dst.\n',
      );
      final result = await renderSkillBody(
        env,
        skillAt('/work/.claude/skills/mig/SKILL.md'),
        args: 'React Vue',
      );
      expect(result.body, 'Migrate React to Vue.');
    });

    test('no placeholder → args appended as ARGUMENTS:', () async {
      await env.createDir('/work/.claude/skills/plain');
      await env.writeFile('/work/.claude/skills/plain/SKILL.md', 'Do it.\n');
      final result = await renderSkillBody(
        env,
        skillAt('/work/.claude/skills/plain/SKILL.md'),
        args: 'now please',
      );
      expect(result.body, 'Do it.\n\nARGUMENTS: now please');
    });

    test(r'escaped \$1.00 stays literal', () async {
      await env.createDir('/work/.claude/skills/esc');
      await env.writeFile(
        '/work/.claude/skills/esc/SKILL.md',
        'Price is \\\$1.00 for \$0.\n',
      );
      final result = await renderSkillBody(
        env,
        skillAt('/work/.claude/skills/esc/SKILL.md'),
        args: 'apple',
      );
      expect(result.body, 'Price is \$1.00 for apple.');
    });

    test('CLAUDE_* variables resolve', () async {
      await env.createDir('/work/.claude/skills/vars');
      await env.writeFile(
        '/work/.claude/skills/vars/SKILL.md',
        'Session \${CLAUDE_SESSION_ID} project \${CLAUDE_PROJECT_DIR} '
            'skill \${CLAUDE_SKILL_DIR}.\n',
      );
      final result = await renderSkillBody(
        env,
        skillAt('/work/.claude/skills/vars/SKILL.md'),
        sessionId: 'sess-1',
        projectDir: '/work',
      );
      expect(
        result.body,
        'Session sess-1 project /work skill /work/.claude/skills/vars.',
      );
    });

    test('quoted multi-word argument stays one token', () async {
      await env.createDir('/work/.claude/skills/q');
      await env.writeFile('/work/.claude/skills/q/SKILL.md', 'A \$0 B \$1.\n');
      final result = await renderSkillBody(
        env,
        skillAt('/work/.claude/skills/q/SKILL.md'),
        args: '"hello world" second',
      );
      expect(result.body, 'A hello world B second.');
    });
  });

  group('shell injection', () {
    test('inline !`cmd` is replaced with command output', () async {
      await env.createDir('/work/.claude/skills/inj');
      await env.writeFile(
        '/work/.claude/skills/inj/SKILL.md',
        'Diff follows:\n!`git diff --stat`\nDone.\n',
      );
      shell.canned['git diff --stat'] = const ShellExecResult(
        stdout: ' 3 files changed',
        stderr: '',
        exitCode: 0,
      );
      final result = await renderSkillBody(
        env,
        skillAt('/work/.claude/skills/inj/SKILL.md'),
      );
      expect(result.body, 'Diff follows:\n 3 files changed\nDone.');
    });

    test('fenced ```! block runs as one command', () async {
      await env.createDir('/work/.claude/skills/fenced');
      await env.writeFile(
        '/work/.claude/skills/fenced/SKILL.md',
        'Before\n```!\ngit status\n```\nAfter\n',
      );
      final result = await renderSkillBody(
        env,
        skillAt('/work/.claude/skills/fenced/SKILL.md'),
      );
      expect(result.body, 'Before\nout:git status\nAfter');
    });

    test('a failing command aborts the invocation', () async {
      await env.createDir('/work/.claude/skills/fail');
      await env.writeFile('/work/.claude/skills/fail/SKILL.md', '!`boom`\n');
      shell.canned['boom'] = const ShellExecResult(
        stdout: '',
        stderr: 'nope',
        exitCode: 2,
      );
      expect(
        () =>
            renderSkillBody(env, skillAt('/work/.claude/skills/fail/SKILL.md')),
        throwsA(
          isA<SkillRenderException>().having(
            (e) => e.message,
            'message',
            contains('boom'),
          ),
        ),
      );
    });

    test('disabled shell execution renders the placeholder', () async {
      await env.createDir('/work/.claude/skills/off');
      await env.writeFile('/work/.claude/skills/off/SKILL.md', '!`id`\n');
      final result = await renderSkillBody(
        env,
        skillAt('/work/.claude/skills/off/SKILL.md'),
        shellExecutionEnabled: false,
      );
      expect(result.body, '[shell command execution disabled by policy]');
      expect(result.notes, isNotEmpty);
    });
  });

  group('splitSkillArguments', () {
    test('plain and quoted tokens', () {
      expect(splitSkillArguments('a b c'), ['a', 'b', 'c']);
      expect(splitSkillArguments('"a b" c'), ['a b', 'c']);
      expect(splitSkillArguments(''), isEmpty);
    });

    test('backslash escapes inside quotes', () {
      expect(splitSkillArguments(r'"a\"b" c'), ['a"b', 'c']);
    });

    test('empty quotes and multiple spaces produce expected tokens', () {
      expect(splitSkillArguments('""  x   y '), ['', 'x', 'y']);
    });

    test('trailing backslash inside quotes is preserved', () {
      expect(splitSkillArguments('"a\\'), [r'a\']);
    });
  });
}
