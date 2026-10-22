import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/prompts/prompts.g.dart'
    show projectContextReadFullPrompt;
import 'package:test/test.dart';

void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work/app');
  });

  test('walks from cwd to the git root, closest last', () async {
    await env.createDir('/work/.git');
    await env.createDir('/work/app');
    await env.writeFile('/work/AGENTS.md', 'root rules');
    await env.writeFile('/work/app/CLAUDE.md', 'app rules');
    // Above the git root: never reached.
    await env.writeFile('/AGENTS.md', 'outer rules');

    final loaded = await loadProjectContextFiles(env);
    expect(loaded.files.map((f) => f.path), [
      '/work/AGENTS.md',
      '/work/app/CLAUDE.md',
    ]);
    final section = formatProjectContext(loaded);
    expect(section, contains('<!-- From: /work/AGENTS.md -->'));
    expect(section, contains('<!-- From: /work/app/CLAUDE.md -->'));
    expect(
      section.indexOf('root rules'),
      lessThan(section.indexOf('app rules')),
    );
    expect(section, contains('deeper file takes precedence'));
  });

  test('collects all five filenames and the user file first', () async {
    await env.createDir('/work/app');
    await env.writeFile('/work/app/AGENTS.md', 'a');
    await env.writeFile('/work/app/GEMINI.md', 'gm');
    await env.writeFile('/work/app/GOAL.md', 'g');
    await env.writeFile('/work/app/DESIGN.md', 'd');
    await env.writeFile('/home/u/.fah/AGENTS.md', 'user rules');

    final loaded = await loadProjectContextFiles(
      env,
      userFile: '/home/u/.fah/AGENTS.md',
    );
    expect(loaded.files.map((f) => f.path), [
      '/home/u/.fah/AGENTS.md',
      '/work/app/AGENTS.md',
      '/work/app/GEMINI.md',
      '/work/app/GOAL.md',
      '/work/app/DESIGN.md',
    ]);
  });

  test('picks up copilot-instructions.md from a walked dir', () async {
    await env.createDir('/work/.git');
    await env.createDir('/work/app');
    await env.writeFile(
      '/work/.github/copilot-instructions.md',
      'copilot rules',
    );

    final loaded = await loadProjectContextFiles(env);
    expect(loaded.files.map((f) => f.path), [
      '/work/.github/copilot-instructions.md',
    ]);
    final section = formatProjectContext(loaded);
    expect(
      section,
      contains('<!-- From: /work/.github/copilot-instructions.md -->'),
    );
    expect(section, contains('copilot rules'));
  });

  test('instructions file without applyTo is included unmarked', () async {
    await env.createDir('/work/app');
    await env.writeFile(
      '/work/app/.github/instructions/general.instructions.md',
      '---\ndescription: General\n---\nalways follow this',
    );

    final loaded = await loadProjectContextFiles(env);
    expect(loaded.files, hasLength(1));
    expect(
      loaded.files.single.path,
      '/work/app/.github/instructions/general.instructions.md',
    );
    expect(loaded.files.single.content, 'always follow this');
  });

  test('instructions file with applyTo carries the applies-to marker', () async {
    await env.createDir('/work/app');
    await env.writeFile(
      '/work/app/.github/instructions/ts.instructions.md',
      '---\napplyTo: "**/*.ts,**/*.tsx"\n---\nts rules',
    );
    await env.writeFile(
      '/work/app/.github/instructions/dart.instructions.md',
      '---\napplyTo:\n  - "lib/**/*.dart"\n  - "test/**/*.dart"\n---\ndart rules',
    );

    final loaded = await loadProjectContextFiles(env);
    expect(loaded.files.map((f) => f.path), [
      '/work/app/.github/instructions/dart.instructions.md',
      '/work/app/.github/instructions/ts.instructions.md',
    ]);
    expect(
      loaded.files[0].content,
      '<!-- applies to: lib/**/*.dart, test/**/*.dart -->\ndart rules',
    );
    expect(
      loaded.files[1].content,
      '<!-- applies to: **/*.ts, **/*.tsx -->\nts rules',
    );
    final section = formatProjectContext(loaded);
    expect(
      section,
      contains(
        '<!-- From: /work/app/.github/instructions/ts.instructions.md -->',
      ),
    );
  });

  test('instructions file with applyTo "**" is included unmarked', () async {
    await env.createDir('/work/app');
    await env.writeFile(
      '/work/app/.github/instructions/all.instructions.md',
      '---\napplyTo: "**"\n---\nall rules',
    );

    final loaded = await loadProjectContextFiles(env);
    expect(loaded.files.single.content, 'all rules');
  });

  test('budget allocates leaf-first, truncating the shallow file', () async {
    await env.createDir('/work/.git');
    await env.createDir('/work/app');
    await env.writeFile('/work/AGENTS.md', 'x' * (32 * 1024));
    await env.writeFile('/work/app/AGENTS.md', 'deep rules');

    final loaded = await loadProjectContextFiles(env);
    // The deep file survives intact; the shallow one is truncated/dropped.
    expect(loaded.files.last.path, '/work/app/AGENTS.md');
    expect(loaded.files.last.content, 'deep rules');
    expect(
      loaded.files.fold(0, (sum, f) => sum + f.content.length),
      lessThanOrEqualTo(32 * 1024),
    );
  });

  test('empty content and no matches render nothing', () async {
    await env.createDir('/work/app');
    await env.writeFile('/work/app/AGENTS.md', '   \n');
    final loaded = await loadProjectContextFiles(env);
    expect(loaded.isEmpty, isTrue);
    expect(formatProjectContext(loaded), '');
  });

  test('truncated file keeps the head excerpt and the read-full '
      'instruction naming the absolute path (issue #1761 AC1/AC3)', () async {
    final original = 'y' * 5000;
    await env.createDir('/work/app');
    await env.writeFile('/work/app/AGENTS.md', original);

    final loaded = await loadProjectContextFiles(env, maxBytes: 1000);
    final file = loaded.files.single;
    expect(file.isTruncated, isTrue);
    expect(file.originalBytes, 5000);
    // The kept excerpt is a prefix of the true file content.
    expect(
      original.substring(0, file.excerptBytes!),
      file.content.substring(0, file.excerptBytes!),
    );
    // Content = excerpt + newline + the prompt-copy instruction.
    expect(
      file.content,
      '${original.substring(0, file.excerptBytes!)}\n'
      '${projectContextReadFullPrompt.trim()}',
    );

    final section = formatProjectContext(loaded);
    // The extended From-marker carries both sizes (thousands-grouped) and
    // the applied budget label.
    expect(
      section,
      contains(
        '<!-- From: /work/app/AGENTS.md — 5,000 bytes, '
        'only the first ${file.excerptBytes!} shown '
        '(1000B merged budget) -->',
      ),
    );
    // The read-the-rest instruction names the selectors explicitly
    // (parity with #1760's wording).
    expect(section, contains('offset/limit/ranges'));
    expect(section, contains('You MUST read it with the read tool'));
    // The whole block stays inside the budget.
    expect(
      loaded.files.fold(0, (sum, f) => sum + f.content.length),
      lessThanOrEqualTo(1000),
    );
  });

  test(
    'truncation reports a user-facing notice line (issue #1761 AC2)',
    () async {
      await env.createDir('/work/app');
      await env.writeFile('/work/app/AGENTS.md', 'z' * 5000);

      final loaded = await loadProjectContextFiles(env, maxBytes: 1000);
      expect(loaded.notices, hasLength(1));
      final notice = loaded.notices.single;
      expect(notice, startsWith('project context truncated: AGENTS.md '));
      expect(notice, contains(' -> '));
      expect(notice, contains(' of the 1000B budget '));
      expect(notice, endsWith('(full file stays on disk)'));
    },
  );

  test(
    'dropped file leaves a tombstone naming the path (issue #1761 AC1)',
    () async {
      await env.createDir('/work/.git');
      await env.createDir('/work/app');
      await env.writeFile('/work/AGENTS.md', 's' * 4000);
      await env.writeFile('/work/app/AGENTS.md', 'deep rules');

      final loaded = await loadProjectContextFiles(env, maxBytes: 500);
      // Leaf-first: the deep file keeps every byte, the shallow one drops.
      expect(loaded.files.single.path, '/work/app/AGENTS.md');
      expect(loaded.files.single.content, 'deep rules');
      expect(loaded.dropped.single.path, '/work/AGENTS.md');
      expect(loaded.dropped.single.bytes, 4000);

      final section = formatProjectContext(loaded);
      expect(
        section,
        contains(
          '<!-- /work/AGENTS.md exists (3KB) but did not fit the 500B '
          'budget — read it with the read tool if its rules apply -->',
        ),
      );
      expect(loaded.notices, [
        'project context truncated: AGENTS.md 3KB dropped '
            '(full file stays on disk)',
      ]);
    },
  );

  test(
    'copilot instructions files get the same treatment (issue #1761 AC6)',
    () async {
      await env.createDir('/work/app/.github/instructions');
      await env.writeFile(
        '/work/app/.github/instructions/dart.instructions.md',
        'd' * 5000,
      );

      final loaded = await loadProjectContextFiles(env, maxBytes: 1000);
      final file = loaded.files.single;
      expect(file.isTruncated, isTrue);
      expect(file.originalBytes, 5000);
      final section = formatProjectContext(loaded);
      expect(section, contains('only the first ${file.excerptBytes!} shown'));
      expect(section, contains('You MUST read it with the read tool'));
    },
  );

  test('maxBytes: 0 disables the section and reads no files '
      '(issue #1761 AC5 fast boot)', () async {
    await env.createDir('/work/app');
    await env.writeFile('/work/app/AGENTS.md', 'rules');

    final loaded = await loadProjectContextFiles(env, maxBytes: 0);
    expect(loaded.files, isEmpty);
    expect(loaded.dropped, isEmpty);
    expect(loaded.notices, isEmpty);
    expect(loaded.isEmpty, isTrue);
    expect(formatProjectContext(loaded), '');
  });

  test('notice sizes label MB files readably', () async {
    await env.createDir('/work/app');
    await env.writeFile('/work/app/AGENTS.md', 'm' * (1024 * 1024 + 5));

    final loaded = await loadProjectContextFiles(env, maxBytes: 1000);
    expect(
      loaded.notices.single,
      startsWith('project context truncated: AGENTS.md 1MB -> '),
    );
  });

  test('ProjectContextConfig parses tolerantly (issue #1761 AC5)', () {
    // Absent section = the 32768 default.
    expect(ProjectContextConfig.fromYaml(null).maxBytes, 32768);
    expect(ProjectContextConfig.fromYaml(null).isDisabled, isFalse);
    // A custom value is respected (int and fractional num alike).
    expect(ProjectContextConfig.fromYaml({'maxBytes': 65536}).maxBytes, 65536);
    expect(ProjectContextConfig.fromYaml({'maxBytes': 1024.0}).maxBytes, 1024);
    // 0 disables.
    final disabled = ProjectContextConfig.fromYaml({'maxBytes': 0});
    expect(disabled.maxBytes, 0);
    expect(disabled.isDisabled, isTrue);
    // Unknown keys are tolerated with a note, never a boot failure.
    final unknown = ProjectContextConfig.fromYaml({
      'bogus': 1,
      'maxBytes': 1024,
    });
    expect(unknown.maxBytes, 1024);
    expect(
      unknown.notes,
      contains('projectContext.bogus: unknown key (ignored)'),
    );
    // Mistyped scalars fall back with a note.
    final mistyped = ProjectContextConfig.fromYaml({'maxBytes': 'big'});
    expect(mistyped.maxBytes, 32768);
    expect(
      mistyped.notes,
      contains('projectContext.maxBytes: not a number, default applied'),
    );
    // Negative values disable (clamped, noted).
    final negative = ProjectContextConfig.fromYaml({'maxBytes': -5});
    expect(negative.maxBytes, 0);
    expect(negative.isDisabled, isTrue);
    expect(negative.notes, hasLength(1));
  });

  test('ProjectContextConfig.toYaml emits only the non-default value', () {
    expect(const ProjectContextConfig().toYaml(), '');
    expect(
      const ProjectContextConfig(maxBytes: 0).toYaml(),
      'projectContext:\n  maxBytes: 0\n',
    );
  });
}
