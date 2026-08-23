import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
  });

  group('discoverSkills', () {
    test('finds <name>/SKILL.md with frontmatter and flat <name>.md', () async {
      await env.createDir('/work/.fah/skills/deploy');
      await env.writeFile(
        '/work/.fah/skills/deploy/SKILL.md',
        '---\nname: deploy\ndescription: Deploy the app to production\n---\n'
            'Full deploy instructions here.\n',
      );
      await env.createDir('/work/.agents/skills');
      await env.writeFile(
        '/work/.agents/skills/review.md',
        'Review code for correctness.\n',
      );

      final roots = defaultSkillRoots(cwd: '/work', homeDir: '/home/u');
      final skills = await discoverSkills(
        env,
        projectRoots: roots.projectRoots,
        userRoots: roots.userRoots,
      );
      expect(skills, hasLength(2));
      final deploy = skills.firstWhere((s) => s.name == 'deploy');
      expect(deploy.description, 'Deploy the app to production');
      expect(deploy.filePath, '/work/.fah/skills/deploy/SKILL.md');
      expect(deploy.scope, SkillScope.project);
      expect(deploy.source, SkillSource.fah);
      // Flat file: name from stem, description from the first body line.
      final review = skills.firstWhere((s) => s.name == 'review');
      expect(review.description, 'Review code for correctness.');
      expect(review.source, SkillSource.agents);
    });

    test('project wins a name clash with the user scope', () async {
      for (final root in ['/work/.fah/skills/a', '/home/u/.fah/skills/a']) {
        await env.createDir(root);
        await env.writeFile('$root/SKILL.md', '---\ndescription: x\n---\nx\n');
      }
      await env.writeFile(
        '/work/.fah/skills/a/SKILL.md',
        '---\ndescription: from project\n---\nx\n',
      );
      await env.writeFile(
        '/home/u/.fah/skills/a/SKILL.md',
        '---\ndescription: from user\n---\nx\n',
      );

      final skills = await discoverSkills(
        env,
        projectRoots: const [SkillRoot('/work/.fah/skills', SkillSource.fah)],
        userRoots: const [SkillRoot('/home/u/.fah/skills', SkillSource.fah)],
      );
      expect(skills, hasLength(1));
      expect(skills.single.description, 'from project');
    });

    test('ignores missing roots and a bare top-level SKILL.md', () async {
      await env.createDir('/work/.fah/skills');
      await env.writeFile('/work/.fah/skills/SKILL.md', 'ignored\n');
      final skills = await discoverSkills(
        env,
        projectRoots: const [
          SkillRoot('/work/.fah/skills', SkillSource.fah),
          SkillRoot('/nonexistent', SkillSource.fah),
        ],
      );
      expect(skills, isEmpty);
    });

    test('discovers claude/copilot/codex roots with their sources', () async {
      await env.createDir('/work/.claude/skills/pdf');
      await env.writeFile(
        '/work/.claude/skills/pdf/SKILL.md',
        '---\ndescription: Extract PDF fields\n---\nPDF body.\n',
      );
      await env.createDir('/work/.github/skills/reviewer');
      await env.writeFile(
        '/work/.github/skills/reviewer/SKILL.md',
        '---\ndescription: Review PRs\n---\nBody.\n',
      );
      await env.createDir('/work/.codex/skills/babysit-pr');
      await env.writeFile(
        '/work/.codex/skills/babysit-pr/SKILL.md',
        '---\nname: babysit-pr\ndescription: Watch a PR\n---\nBody.\n',
      );

      final roots = defaultSkillRoots(cwd: '/work', homeDir: '/home/u');
      final skills = await discoverSkills(
        env,
        projectRoots: roots.projectRoots,
        userRoots: roots.userRoots,
      );
      expect(
        skills.map((s) => s.name),
        containsAll(['pdf', 'reviewer', 'babysit-pr']),
      );
      expect(
        skills.firstWhere((s) => s.name == 'pdf').source,
        SkillSource.claude,
      );
      expect(
        skills.firstWhere((s) => s.name == 'reviewer').source,
        SkillSource.copilot,
      );
      expect(
        skills.firstWhere((s) => s.name == 'babysit-pr').source,
        SkillSource.codex,
      );
    });

    test('allowedSources filters out third-party roots', () async {
      await env.createDir('/work/.fah/skills/own');
      await env.writeFile('/work/.fah/skills/own/SKILL.md', 'Own.\n');
      await env.createDir('/work/.claude/skills/theirs');
      await env.writeFile('/work/.claude/skills/theirs/SKILL.md', 'Theirs.\n');

      final roots = defaultSkillRoots(cwd: '/work', homeDir: '/home/u');
      final skills = await discoverSkills(
        env,
        projectRoots: roots.projectRoots,
        userRoots: roots.userRoots,
        allowedSources: const {SkillSource.fah, SkillSource.agents},
      );
      expect(skills.map((s) => s.name), ['own']);
    });

    test('discovers .claude/commands flat files as skills', () async {
      await env.createDir('/work/.claude/commands');
      await env.writeFile(
        '/work/.claude/commands/deploy.md',
        '---\ndescription: Deploy it\n---\nRun the deploy pipeline.\n',
      );
      final roots = defaultSkillRoots(cwd: '/work');
      final skills = await discoverSkills(
        env,
        projectRoots: roots.projectRoots,
      );
      final deploy = skills.firstWhere((s) => s.name == 'deploy');
      expect(deploy.source, SkillSource.claude);
      expect(deploy.filePath, '/work/.claude/commands/deploy.md');
    });

    test(
      'parses the full multi-format frontmatter into the manifest',
      () async {
        await env.createDir('/work/.claude/skills/research');
        await env.writeFile(
          '/work/.claude/skills/research/SKILL.md',
          '---\n'
              'name: research\n'
              'description: Research a topic\n'
              'when_to_use: when the user asks to dig into a subject\n'
              'argument-hint: "[topic] [depth]"\n'
              'arguments: [topic, depth]\n'
              'disable-model-invocation: true\n'
              'user-invocable: false\n'
              'allowed-tools: [read, bash, "Bash(git status:*)"]\n'
              'disallowed-tools: write\n'
              'model: smol\n'
              'effort: high\n'
              'context: fork\n'
              'agent: explore\n'
              'background: false\n'
              'paths: ["src/**/*.ts"]\n'
              'shell: bash\n'
              'license: Apache-2.0\n'
              'compatibility: claude-code\n'
              'metadata:\n'
              '  author: team\n'
              'mystery-key: ignored\n'
              '---\n'
              'Research \$topic thoroughly.\n',
        );
        final skills = await discoverSkills(
          env,
          projectRoots: const [
            SkillRoot('/work/.claude/skills', SkillSource.claude),
          ],
        );
        final skill = skills.single;
        expect(skill.description, contains('Research a topic'));
        expect(skill.description, contains('when the user asks'));
        final m = skill.manifest;
        expect(m.argumentHint, '[topic] [depth]');
        expect(m.arguments, ['topic', 'depth']);
        expect(m.disableModelInvocation, isTrue);
        expect(m.userInvocable, isFalse);
        expect(m.allowedTools, ['read', 'bash', 'Bash(git status:*)']);
        expect(m.plainAllowedTools, ['read', 'bash']);
        expect(m.disallowedTools, ['write']);
        expect(m.model, 'smol');
        expect(m.effort, 'high');
        expect(m.contextFork, isTrue);
        expect(m.agent, 'explore');
        expect(m.background, isFalse);
        expect(m.paths, ['src/**/*.ts']);
        expect(m.shell, 'bash');
        expect(m.license, 'Apache-2.0');
        expect(m.compatibility, 'claude-code');
        expect(m.metadata['author'], 'team');
        expect(m.notes.any((n) => n.contains('mystery-key')), isTrue);
        expect(m.notes.any((n) => n.contains('pattern entries')), isTrue);
      },
    );

    test('boolean spellings yes/on/1 and no/off/0 parse', () async {
      await env.createDir('/work/.claude/skills/flags');
      await env.writeFile(
        '/work/.claude/skills/flags/SKILL.md',
        '---\ndisable-model-invocation: yes\nbackground: off\n---\nx\n',
      );
      final skills = await discoverSkills(
        env,
        projectRoots: const [
          SkillRoot('/work/.claude/skills', SkillSource.claude),
        ],
      );
      expect(skills.single.manifest.disableModelInvocation, isTrue);
      expect(skills.single.manifest.background, isFalse);
    });
  });

  group('path matching', () {
    Skill skillWithPaths(List<String> paths) => Skill(
      name: 's',
      description: 'd',
      filePath: '/work/.claude/skills/s/SKILL.md',
      scope: SkillScope.project,
      source: SkillSource.claude,
      manifest: SkillManifest(paths: paths),
    );

    test('no patterns → always matches', () {
      expect(skillWithPaths(const []).matchesTouchedPaths(const []), isTrue);
    });

    test('glob patterns match touched paths (absolute and relative)', () {
      final skill = skillWithPaths(const ['src/**/*.ts']);
      expect(
        skill.matchesTouchedPaths(const [
          '/work/src/app/main.ts',
        ], cwd: '/work'),
        isTrue,
      );
      expect(
        skill.matchesTouchedPaths(const ['/work/README.md'], cwd: '/work'),
        isFalse,
      );
    });

    test('copilot applyTo participates too', () {
      final skill = Skill(
        name: 's',
        description: 'd',
        filePath: '/work/x.md',
        scope: SkillScope.project,
        source: SkillSource.copilot,
        manifest: const SkillManifest(applyTo: ['**/*.rb']),
      );
      expect(skill.matchesTouchedPaths(const ['app/models/user.rb']), isTrue);
    });
  });

  group('formatSkillsForPrompt', () {
    test('renders the available_skills block with metadata only', () {
      const skills = [
        Skill(
          name: 'deploy',
          description: 'Deploy the app',
          filePath: '/work/.fah/skills/deploy/SKILL.md',
          scope: SkillScope.project,
          source: SkillSource.fah,
        ),
      ];
      final out = formatSkillsForPrompt(skills);
      expect(out, contains('<available_skills>'));
      expect(out, contains('<name>deploy</name>'));
      expect(out, contains('<description>Deploy the app</description>'));
      expect(
        out,
        contains('<location>/work/.fah/skills/deploy/SKILL.md</location>'),
      );
      expect(out, contains('read tool'));
      expect(formatSkillsForPrompt(const []), '');
    });

    test(
      'disable-model-invocation skills are hidden from the model catalog',
      () {
        const skills = [
          Skill(
            name: 'manual',
            description: 'Manual only',
            filePath: '/work/x/SKILL.md',
            scope: SkillScope.project,
            source: SkillSource.claude,
            manifest: SkillManifest(disableModelInvocation: true),
          ),
          Skill(
            name: 'auto',
            description: 'Model-visible',
            filePath: '/work/y/SKILL.md',
            scope: SkillScope.project,
            source: SkillSource.claude,
          ),
        ];
        final out = formatSkillsForPrompt(skills);
        expect(out, contains('<name>auto</name>'));
        expect(out, isNot(contains('<name>manual</name>')));
        // forModel: false lists everything (the /skills command view).
        expect(
          formatSkillsForPrompt(skills, forModel: false),
          contains('manual'),
        );
      },
    );
  });

  group('skills access', () {
    test('label round-trip', () {
      expect(skillsAccessFromLabel('granted'), SkillsAccess.granted);
      expect(skillsAccessFromLabel('denied'), SkillsAccess.denied);
      expect(skillsAccessFromLabel(null), SkillsAccess.ask);
      expect(skillsAccessFromLabel('junk'), SkillsAccess.ask);
      expect(skillsAccessLabel(SkillsAccess.granted), 'granted');
    });

    test('discovery allowed only when granted', () {
      expect(
        skillsAccessAllowsDiscovery(SkillsAccess.granted, interactive: true),
        isTrue,
      );
      expect(
        skillsAccessAllowsDiscovery(SkillsAccess.denied, interactive: true),
        isFalse,
      );
      expect(
        skillsAccessAllowsDiscovery(SkillsAccess.ask, interactive: true),
        isFalse,
      );
      expect(
        skillsAccessAllowsDiscovery(SkillsAccess.ask, interactive: false),
        isFalse,
      );
    });

    test('skillSourceIsThirdParty marks claude/copilot/codex', () {
      expect(skillSourceIsThirdParty(SkillSource.fah), isFalse);
      expect(skillSourceIsThirdParty(SkillSource.agents), isFalse);
      expect(skillSourceIsThirdParty(SkillSource.claude), isTrue);
      expect(skillSourceIsThirdParty(SkillSource.copilot), isTrue);
      expect(skillSourceIsThirdParty(SkillSource.codex), isTrue);
    });
  });
}
