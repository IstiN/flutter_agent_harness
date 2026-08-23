@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/task/agent_discovery.dart';
import 'package:test/test.dart';

void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
  });

  Future<void> writeFile(String path, String content) =>
      env.writeFile(path, content);

  AgentRoot fahRoot(String path) => AgentRoot(path, SkillSource.fah);

  group('discoverTaskAgents', () {
    test('parses a valid agent file', () async {
      await writeFile('/work/.fah/agents/security-review.md', '''
---
name: security-review
description: Reviews diffs for security issues
tools: [read, grep, bash]
readOnly: true
modelRole: slow
---
You are a security reviewer. Focus on injection and auth issues.
''');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [fahRoot('/work/.fah/agents')],
      );
      expect(result.agents, hasLength(1));
      final agent = result.agents.single;
      expect(agent.name, 'security-review');
      expect(agent.description, 'Reviews diffs for security issues');
      expect(agent.readOnly, isTrue);
      expect(agent.modelRole, 'slow');
      expect(agent.toolNames, containsAll(['read', 'grep', 'bash']));
      expect(agent.systemPrompt, contains('security reviewer'));
    });

    test('uses filename as fallback name', () async {
      await writeFile('/work/.fah/agents/linter.md', '''
---
description: A linter agent
---
Lint the code.
''');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [fahRoot('/work/.fah/agents')],
      );
      expect(result.agents.single.name, 'linter');
    });

    test('skips unknown frontmatter keys with a note', () async {
      await writeFile('/work/.fah/agents/bad.md', '''
---
name: bad
unknownField: value
---
Body.
''');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [fahRoot('/work/.fah/agents')],
      );
      expect(result.agents, isEmpty);
      expect(result.notes, hasLength(1));
      expect(result.notes.first, contains('unknown frontmatter keys'));
    });

    test('project root wins over user root on name clash', () async {
      await writeFile('/work/.fah/agents/shared.md', '''
---
name: shared
description: project version
---
Project.
''');
      await writeFile('/home/.fah/agents/shared.md', '''
---
name: shared
description: user version
---
User.
''');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [fahRoot('/work/.fah/agents')],
        userRoots: [fahRoot('/home/.fah/agents')],
      );
      expect(result.agents, hasLength(1));
      expect(result.agents.single.description, 'project version');
    });

    test('missing roots are silently skipped', () async {
      final result = await discoverTaskAgents(
        env,
        projectRoots: [fahRoot('/nonexistent')],
      );
      expect(result.agents, isEmpty);
    });

    test('defaultAgentRoots returns expected paths and sources', () {
      final roots = defaultAgentRoots(cwd: '/work', homeDir: '/home');
      expect(roots.projectRoots, [
        isA<AgentRoot>()
            .having((r) => r.path, 'path', '/work/.fah/agents')
            .having((r) => r.source, 'source', SkillSource.fah),
        isA<AgentRoot>()
            .having((r) => r.path, 'path', '/work/.agents/agents')
            .having((r) => r.source, 'source', SkillSource.agents),
        isA<AgentRoot>()
            .having((r) => r.path, 'path', '/work/.claude/agents')
            .having((r) => r.source, 'source', SkillSource.claude),
        isA<AgentRoot>()
            .having((r) => r.path, 'path', '/work/.github/agents')
            .having((r) => r.source, 'source', SkillSource.copilot),
        isA<AgentRoot>()
            .having((r) => r.path, 'path', '/work/.codex/agents')
            .having((r) => r.source, 'source', SkillSource.codex),
      ]);
      expect(roots.userRoots.map((r) => r.path), [
        '/home/.fah/agents',
        '/home/.agents/agents',
        '/home/.claude/agents',
        '/home/.copilot/agents',
        '/home/.codex/agents',
      ]);
      expect(roots.userRoots.map((r) => r.source), [
        SkillSource.fah,
        SkillSource.agents,
        SkillSource.claude,
        SkillSource.copilot,
        SkillSource.codex,
      ]);
    });

    test('defaultAgentRoots without home returns empty user roots', () {
      final roots = defaultAgentRoots(cwd: '/work');
      expect(roots.userRoots, isEmpty);
    });

    test('allowedSources filters roots by source', () async {
      await writeFile('/work/.fah/agents/mine.md', '''
---
name: mine
---
Mine.
''');
      await writeFile('/work/.claude/agents/theirs.md', '''
---
name: theirs
---
Theirs.
''');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [
          fahRoot('/work/.fah/agents'),
          AgentRoot('/work/.claude/agents', SkillSource.claude),
        ],
        allowedSources: {SkillSource.fah},
      );
      expect(result.agents.map((a) => a.name), ['mine']);
    });
  });

  group('file names', () {
    test('accepts the Copilot <name>.agent.md convention', () async {
      await writeFile('/work/.github/agents/security.agent.md', '''
---
description: Copilot security agent
---
Review for security.
''');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [AgentRoot('/work/.github/agents', SkillSource.copilot)],
      );
      expect(result.agents, hasLength(1));
      expect(result.agents.single.name, 'security');
    });

    test('ignores non-markdown files', () async {
      await writeFile('/work/.fah/agents/notes.txt', 'not an agent');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [fahRoot('/work/.fah/agents')],
      );
      expect(result.agents, isEmpty);
    });
  });

  group('tools frontmatter', () {
    test('tools: ["*"] means the full parent tool surface', () async {
      await writeFile('/work/.fah/agents/star-list.md', '''
---
name: star-list
tools: ["*"]
---
Body.
''');
      await writeFile('/work/.fah/agents/star-string.md', '''
---
name: star-string
tools: "*"
---
Body.
''');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [fahRoot('/work/.fah/agents')],
      );
      expect(result.agents, hasLength(2));
      for (final agent in result.agents) {
        expect(agent.toolNames, isNull, reason: agent.name);
      }
    });

    test('tools: [] means no tools', () async {
      await writeFile('/work/.fah/agents/empty.md', '''
---
name: empty
tools: []
---
Body.
''');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [fahRoot('/work/.fah/agents')],
      );
      expect(result.agents.single.toolNames, isEmpty);
    });

    test('the comma-separated string form parses', () async {
      await writeFile('/work/.fah/agents/csv.md', '''
---
name: csv
tools: read, grep
---
Body.
''');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [fahRoot('/work/.fah/agents')],
      );
      expect(result.agents.single.toolNames, {'read', 'grep'});
    });

    test('server/tool entries are kept verbatim', () async {
      await writeFile('/work/.fah/agents/mcp.md', '''
---
name: mcp
tools: [read, github/*, github/get_issue]
---
Body.
''');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [fahRoot('/work/.fah/agents')],
      );
      expect(result.agents.single.toolNames, {
        'read',
        'github/*',
        'github/get_issue',
      });
    });
  });

  group('Copilot compat keys', () {
    test('mcp-servers is accepted with a not-supported note', () async {
      await writeFile('/work/.github/agents/helper.agent.md', '''
---
name: helper
mcp-servers:
  github:
    command: github-mcp-server
---
Help out.
''');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [AgentRoot('/work/.github/agents', SkillSource.copilot)],
      );
      expect(result.agents, hasLength(1));
      expect(result.notes, hasLength(1));
      expect(
        result.notes.single,
        contains('mcp-servers in agent profiles not supported yet'),
      );
    });

    test('target: vscode skips the agent with a note', () async {
      await writeFile('/work/.github/agents/vscode-only.agent.md', '''
---
name: vscode-only
target: vscode
---
VS Code only.
''');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [AgentRoot('/work/.github/agents', SkillSource.copilot)],
      );
      expect(result.agents, isEmpty);
      expect(result.notes, hasLength(1));
      expect(result.notes.single, contains('vscode'));
      expect(result.notes.single, contains('skipped'));
    });

    test('argument-hint and handoffs are accepted silently', () async {
      await writeFile('/work/.github/agents/ide.agent.md', '''
---
name: ide
argument-hint: Provide a file path
handoffs:
  - label: Done
    agent: default
---
IDE keys.
''');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [AgentRoot('/work/.github/agents', SkillSource.copilot)],
      );
      expect(result.agents, hasLength(1));
      expect(result.notes, isEmpty);
    });
  });

  group('TaskAgentRegistry merge', () {
    test('discovered agents override built-ins on name clash', () {
      final discovered = TaskAgentDefinition(
        name: 'explore',
        description: 'custom explorer',
        systemPrompt: 'Custom explore prompt',
        readOnly: false,
      );
      final registry = TaskAgentRegistry([discovered]);
      final resolved = registry.resolve('explore')!;
      expect(resolved.description, 'custom explorer');
      expect(resolved.readOnly, isFalse);
    });

    test('discovered agents extend the built-in set', () {
      final discovered = TaskAgentDefinition(
        name: 'security-audit',
        description: 'Security audit specialist',
        systemPrompt: 'You audit for security.',
        readOnly: true,
        modelRole: 'slow',
      );
      final registry = TaskAgentRegistry([discovered]);
      expect(registry.resolve('task'), isNotNull); // built-in
      expect(registry.resolve('explore'), isNotNull); // built-in
      expect(registry.resolve('security-audit'), isNotNull); // discovered
    });

    test(
      'parses a Claude Code agent file (.claude/agents + model alias)',
      () async {
        await writeFile('/work/.claude/agents/docs-writer.md', '''
---
name: docs-writer
description: Writes documentation from code
model: smol
disallowedTools: [bash]
permissionMode: ask
maxTurns: 10
---
You write concise documentation.
''');
        final result = await discoverTaskAgents(
          env,
          projectRoots: [AgentRoot('/work/.claude/agents', SkillSource.claude)],
        );
        expect(result.agents, hasLength(1));
        final agent = result.agents.single;
        expect(agent.name, 'docs-writer');
        expect(agent.modelRole, 'smol');
        expect(agent.systemPrompt, contains('documentation'));
        // Claude-only keys are accepted (ignored), not reported as unknown.
        expect(result.notes, isEmpty);
      },
    );

    test('an unknown model alias keeps parent wiring with a note', () async {
      await writeFile('/work/.claude/agents/poet.md', '''
---
name: poet
description: Writes poems
model: sonnet
---
Write poems.
''');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [AgentRoot('/work/.claude/agents', SkillSource.claude)],
      );
      final agent = result.agents.single;
      expect(agent.modelRole, isNull);
      expect(result.notes, isNotEmpty);
      expect(result.notes.single, contains('sonnet'));
    });

    test('modelRole wins over the model alias', () async {
      await writeFile('/work/.claude/agents/duo.md', '''
---
name: duo
description: Both keys present
model: smol
modelRole: slow
---
Do the thing.
''');
      final result = await discoverTaskAgents(
        env,
        projectRoots: [AgentRoot('/work/.claude/agents', SkillSource.claude)],
      );
      expect(result.agents.single.modelRole, 'slow');
    });

    test('defaultAgentRoots include .claude/agents on both scopes', () {
      final roots = defaultAgentRoots(cwd: '/work', homeDir: '/home/me');
      expect(
        roots.projectRoots.map((r) => r.path),
        contains('/work/.claude/agents'),
      );
      expect(
        roots.userRoots.map((r) => r.path),
        contains('/home/me/.claude/agents'),
      );
    });
  });

  group('canonicalTaskAgentName aliases', () {
    test('folds the Claude Code naming aliases onto built-ins', () {
      expect(canonicalTaskAgentName('general-purpose'), 'task');
      expect(canonicalTaskAgentName('general'), 'task');
      expect(canonicalTaskAgentName('Explore'), 'explore');
      expect(canonicalTaskAgentName('scout'), 'explore');
      expect(canonicalTaskAgentName('Reviewer'), 'review');
      expect(canonicalTaskAgentName('planner'), 'plan');
      expect(canonicalTaskAgentName('security-audit'), 'security-audit');
    });

    test('resolve is case-insensitive and alias-aware', () {
      final registry = TaskAgentRegistry();
      expect(registry.resolve('Explore'), isNotNull);
      expect(registry.resolve('Explore')!.name, 'explore');
      expect(registry.resolve('general-purpose')!.name, 'task');
      expect(registry.resolve('SCOUT')!.name, 'explore');
      expect(registry.resolve('Planner')!.name, 'plan');
    });

    test('a discovered agent named via an alias overrides the built-in', () {
      final discovered = TaskAgentDefinition(
        name: 'Reviewer',
        description: 'custom reviewer',
        systemPrompt: 'Custom review prompt',
      );
      final registry = TaskAgentRegistry([discovered]);
      final resolved = registry.resolve('review')!;
      expect(resolved.description, 'custom reviewer');
    });
  });

  group('plan built-in', () {
    test('is registered as a read-only agent on the plan role', () {
      final registry = TaskAgentRegistry();
      final plan = registry.resolve('plan')!;
      expect(plan.name, 'plan');
      expect(plan.readOnly, isTrue);
      expect(plan.modelRole, 'plan');
      expect(plan.description, contains('planning'));
      expect(plan.systemPrompt, contains('planning subagent'));
    });
  });
}
