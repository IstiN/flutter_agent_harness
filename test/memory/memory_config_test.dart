@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/cli_config.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The `memory:` config section — where the long-term memory stores live.
/// Git-backed memory (the "clone the repo, get its memory" flow) starts
/// here: projectPath points inside the repo.
void main() {
  CliConfig parse(String yaml) => CliConfig.fromYaml(loadYaml(yaml) as YamlMap);

  group('memory: section parsing', () {
    test('absent section leaves the config null (defaults apply)', () {
      expect(parse('provider: openai\n').memory, isNull);
    });

    test('projectPath + userPath parse verbatim', () {
      final config = parse('''
memory:
  projectPath: ./memory
  userPath: ~/shared-memory
''');
      expect(config.memory, isNotNull);
      expect(config.memory!.projectPath, './memory');
      expect(config.memory!.userPath, '~/shared-memory');
    });

    test('an unknown key throws ConfigException (strict schema)', () {
      expect(
        () => parse('''
memory:
  projectPath: ./memory
  pathes: typo
'''),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('pathes'),
          ),
        ),
      );
    });

    test('a non-string value throws ConfigException', () {
      expect(
        () => parse('''
memory:
  projectPath: 42
'''),
        throwsA(isA<ConfigException>()),
      );
    });

    test('a non-map section throws ConfigException', () {
      expect(
        () => parse('memory: ./memory\n'),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('MemoryController storage paths', () {
    test('a custom project path receives the notes (not .fah/memory)',
        () async {
      final env = MemoryExecutionEnv();
      final controller = MemoryController(
        env: env,
        projectRoot: '/repo',
        projectStoragePath: '/repo/memory',
      );
      final entry = await controller.add(text: 'git-backed note');
      expect(entry.scope, 'project');
      expect(
        (await env.exists('/repo/memory/note/${entry.id}.md')).valueOrNull,
        isTrue,
        reason: 'the note lands in the committable repo folder',
      );
      expect((await env.exists('/repo/.fah/memory')).valueOrNull, isFalse);
    });

    test('a RELATIVE project path resolves against the project root',
        () async {
      final env = MemoryExecutionEnv();
      final controller = MemoryController(
        env: env,
        projectRoot: '/repo',
        projectStoragePath: './memory',
      );
      final entry = await controller.add(text: 'relative path note');
      expect((await env.exists('/repo/memory/note/${entry.id}.md')).valueOrNull, isTrue);
    });

    test('no override keeps the .fah/memory default', () async {
      final env = MemoryExecutionEnv();
      final controller = MemoryController(env: env, projectRoot: '/repo');
      final entry = await controller.add(text: 'default path note');
      expect((await env.exists('/repo/.fah/memory/note/${entry.id}.md')).valueOrNull, isTrue);
    });

    test('a custom user path with ~ expands against the user root', () async {
      final env = MemoryExecutionEnv();
      final controller = MemoryController(
        env: env,
        projectRoot: '/repo',
        userRoot: '/home/user',
        userStoragePath: '~/shared-memory',
      );
      final entry = await controller.add(text: 'user note', scope: 'user');
      expect(
        (await env.exists('/home/user/shared-memory/note/${entry.id}.md')).valueOrNull,
        isTrue,
      );
    });
  });
}
