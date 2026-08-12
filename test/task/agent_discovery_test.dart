@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/task/agent_discovery.dart';
import 'package:flutter_agent_harness/src/task/agent_registry.dart';
import 'package:test/test.dart';

void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
  });

  Future<void> writeFile(String path, String content) =>
      env.writeFile(path, content);

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
        projectRoots: ['/work/.fah/agents'],
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
        projectRoots: ['/work/.fah/agents'],
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
        projectRoots: ['/work/.fah/agents'],
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
        projectRoots: ['/work/.fah/agents'],
        userRoots: ['/home/.fah/agents'],
      );
      expect(result.agents, hasLength(1));
      expect(result.agents.single.description, 'project version');
    });

    test('missing roots are silently skipped', () async {
      final result = await discoverTaskAgents(
        env,
        projectRoots: ['/nonexistent'],
      );
      expect(result.agents, isEmpty);
    });

    test('defaultAgentRoots returns expected paths', () {
      final roots = defaultAgentRoots(cwd: '/work', homeDir: '/home');
      expect(roots.projectRoots, ['/work/.fah/agents', '/work/.agents/agents']);
      expect(roots.userRoots, ['/home/.fah/agents', '/home/.agents/agents']);
    });

    test('defaultAgentRoots without home returns empty user roots', () {
      final roots = defaultAgentRoots(cwd: '/work');
      expect(roots.userRoots, isEmpty);
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
  });
}
