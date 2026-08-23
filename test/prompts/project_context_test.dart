import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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

    final files = await loadProjectContextFiles(env);
    expect(files.map((f) => f.path), [
      '/work/AGENTS.md',
      '/work/app/CLAUDE.md',
    ]);
    final section = formatProjectContext(files);
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

    final files = await loadProjectContextFiles(
      env,
      userFile: '/home/u/.fah/AGENTS.md',
    );
    expect(files.map((f) => f.path), [
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

    final files = await loadProjectContextFiles(env);
    expect(files.map((f) => f.path), ['/work/.github/copilot-instructions.md']);
    final section = formatProjectContext(files);
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

    final files = await loadProjectContextFiles(env);
    expect(files, hasLength(1));
    expect(
      files.single.path,
      '/work/app/.github/instructions/general.instructions.md',
    );
    expect(files.single.content, 'always follow this');
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

    final files = await loadProjectContextFiles(env);
    expect(files.map((f) => f.path), [
      '/work/app/.github/instructions/dart.instructions.md',
      '/work/app/.github/instructions/ts.instructions.md',
    ]);
    expect(
      files[0].content,
      '<!-- applies to: lib/**/*.dart, test/**/*.dart -->\ndart rules',
    );
    expect(
      files[1].content,
      '<!-- applies to: **/*.ts, **/*.tsx -->\nts rules',
    );
    final section = formatProjectContext(files);
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

    final files = await loadProjectContextFiles(env);
    expect(files.single.content, 'all rules');
  });

  test('budget allocates leaf-first, truncating the shallow file', () async {
    await env.createDir('/work/.git');
    await env.createDir('/work/app');
    await env.writeFile('/work/AGENTS.md', 'x' * (32 * 1024));
    await env.writeFile('/work/app/AGENTS.md', 'deep rules');

    final files = await loadProjectContextFiles(env);
    // The deep file survives intact; the shallow one is truncated/dropped.
    expect(files.last.path, '/work/app/AGENTS.md');
    expect(files.last.content, 'deep rules');
    expect(
      files.fold(0, (sum, f) => sum + f.content.length),
      lessThanOrEqualTo(32 * 1024),
    );
  });

  test('empty content and no matches render nothing', () async {
    await env.createDir('/work/app');
    await env.writeFile('/work/app/AGENTS.md', '   \n');
    expect(await loadProjectContextFiles(env), isEmpty);
    expect(formatProjectContext(const []), '');
  });
}
