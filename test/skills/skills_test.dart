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
      // Flat file: name from stem, description from the first body line.
      final review = skills.firstWhere((s) => s.name == 'review');
      expect(review.description, 'Review code for correctness.');
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
        projectRoots: ['/work/.fah/skills'],
        userRoots: ['/home/u/.fah/skills'],
      );
      expect(skills, hasLength(1));
      expect(skills.single.description, 'from project');
    });

    test('ignores missing roots and a bare top-level SKILL.md', () async {
      await env.createDir('/work/.fah/skills');
      await env.writeFile('/work/.fah/skills/SKILL.md', 'ignored\n');
      final skills = await discoverSkills(
        env,
        projectRoots: const ['/work/.fah/skills', '/nonexistent'],
      );
      expect(skills, isEmpty);
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
  });
}
