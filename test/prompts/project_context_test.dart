import 'package:flutter_agent_harness/src/prompts/project_context.dart';
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

  test('collects all four filenames and the user file first', () async {
    await env.createDir('/work/app');
    await env.writeFile('/work/app/AGENTS.md', 'a');
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
      '/work/app/GOAL.md',
      '/work/app/DESIGN.md',
    ]);
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
