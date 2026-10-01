/// Built-in skills shipped with the fa package (issue #1151): parsing of
/// the compiled-in sources, lowest-precedence discovery merge (project >
/// user > third-party-granted > builtin), first-party access semantics,
/// renderer + read-tool service from the embedded copy.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/skills/skill_renderer.dart';
import 'package:test/test.dart';

void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
  });

  group('builtinSkills', () {
    test('the first batch parses with real manifests', () {
      final skills = builtinSkills();
      final names = skills.map((s) => s.name).toSet();
      expect(names, containsAll(['create-goal', 'self-settings']));
      for (final skill in skills) {
        expect(skill.source, SkillSource.builtin);
        expect(skill.scope, SkillScope.builtin);
        expect(skill.embeddedText, isNotNull);
        expect(skill.filePath, startsWith('builtin://skills/'));
        expect(skill.filePath, endsWith('/SKILL.md'));
        expect(skill.description.length, greaterThan(10));
        expect(skill.description, isNot('No description provided.'));
      }
      // The manifests carried over the port: invocation hints and the
      // self-configuration tool grants.
      final createGoal = skills.firstWhere((s) => s.name == 'create-goal');
      expect(createGoal.manifest.argumentHint, isNotNull);
      expect(createGoal.userInvocable, isTrue);
      expect(createGoal.modelInvocable, isTrue);
      final selfSettings = skills.firstWhere((s) => s.name == 'self-settings');
      expect(selfSettings.manifest.plainAllowedTools, contains('config'));
    });

    test('is not gated by the third-party skills-access consent', () {
      for (final skill in builtinSkills()) {
        expect(skillSourceIsThirdParty(skill.source), isFalse);
      }
    });
  });

  group('discoverSkills builtins merge', () {
    test('builtins resolve in a project with NO .fah/skills', () async {
      final skills = await discoverSkills(
        env,
        projectRoots: defaultSkillRoots(
          cwd: '/work',
          homeDir: null,
        ).projectRoots,
        userRoots: const [],
        builtins: builtinSkills(),
      );
      final names = skills.map((s) => s.name).toSet();
      expect(names, containsAll(['create-goal', 'self-settings']));
    });

    test('a project skill of the same name shadows the builtin', () async {
      await env.createDir('/work/.fah/skills/create-goal');
      await env.writeFile(
        '/work/.fah/skills/create-goal/SKILL.md',
        '---\ndescription: project override\n---\nproject body\n',
      );
      final skills = await discoverSkills(
        env,
        projectRoots: const [SkillRoot('/work/.fah/skills', SkillSource.fah)],
        builtins: builtinSkills(),
      );
      final goals = skills.where((s) => s.name == 'create-goal').toList();
      expect(goals, hasLength(1));
      expect(goals.single.source, SkillSource.fah);
      expect(goals.single.description, 'project override');
    });

    test('builtins survive allowedSources restricted to first-party', () async {
      final skills = await discoverSkills(
        env,
        projectRoots: const [
          SkillRoot('/work/.claude/skills', SkillSource.claude),
        ],
        userRoots: const [],
        allowedSources: const {SkillSource.fah, SkillSource.agents},
        builtins: builtinSkills(),
      );
      expect(
        skills.map((s) => s.name),
        containsAll(['create-goal', 'self-settings']),
      );
    });
  });

  group('rendering and read access from the embedded copy', () {
    test('renderSkillBody works without a backing file', () async {
      final skill = builtinSkills().firstWhere((s) => s.name == 'create-goal');
      final rendered = await renderSkillBody(
        env,
        skill,
        args: 'flappy bird clone',
      );
      expect(rendered.body, contains('# Create Goal'));
      expect(rendered.body, isNot(contains(r'$ARGUMENTS')));
    });

    test('builtinSkillTextAt serves the virtual read path', () {
      final skill = builtinSkills().firstWhere((s) => s.name == 'create-goal');
      expect(builtinSkillTextAt(skill.filePath), skill.embeddedText);
      expect(builtinSkillTextAt('builtin://skills/nope/SKILL.md'), isNull);
      expect(builtinSkillTextAt('/work/.fah/skills/x/SKILL.md'), isNull);
      expect(
        builtinSkillTextAt('builtin://skills/create-goal/other.md'),
        isNull,
      );
    });

    test('the read tool serves the builtin:// path', () async {
      final skill = builtinSkills().firstWhere(
        (s) => s.name == 'self-settings',
      );
      final tools = [
        for (final tool in builtinTools(env, sqlite: null))
          if (tool.name == 'read') tool,
      ];
      expect(tools, hasLength(1));
      final result = await tools.single.execute(
        {'path': skill.filePath},
        null,
        null,
      );
      final text = [
        for (final block in result.content)
          if (block is TextContent) block.text,
      ].join('\n');
      expect(text, contains('name: self-settings'));
    });
  });
}
