import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  group('looksLikePromptFilePath', () {
    test('classifies paths vs inline text', () {
      expect(looksLikePromptFilePath('/abs/path.md'), isTrue);
      expect(looksLikePromptFilePath('~/prompts/sys.md'), isTrue);
      expect(looksLikePromptFilePath('./rel.md'), isTrue);
      expect(looksLikePromptFilePath('../up.md'), isTrue);
      expect(looksLikePromptFilePath('prompts/sum.md'), isTrue);
      expect(looksLikePromptFilePath('notes.markdown'), isTrue);
      expect(looksLikePromptFilePath('notes.txt'), isTrue);
      expect(looksLikePromptFilePath('You are a terse reviewer.'), isFalse);
      expect(looksLikePromptFilePath('Review .md files carefully'), isFalse);
    });
  });

  group('resolvePromptOverrides', () {
    late Directory tmp;
    late String home;
    late String cwd;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fah-prompt-overrides-test-');
      home = '${tmp.path}/home';
      cwd = '${tmp.path}/work';
      Directory(home).createSync(recursive: true);
      Directory(cwd).createSync(recursive: true);
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('empty raw map yields empty overrides', () {
      final overrides = resolvePromptOverrides(
        const {},
        homeDir: home,
        baseDir: cwd,
      );
      expect(overrides.isEmpty, isTrue);
    });

    test('inline text resolves verbatim (trimmed)', () {
      final overrides = resolvePromptOverrides(
        const {'cli/mode_review': '  You are a terse reviewer.  '},
        homeDir: home,
        baseDir: cwd,
      );
      expect(
        overrides.resolve('cli/mode_review', 'builtin'),
        'You are a terse reviewer.',
      );
    });

    test('file values read the file and strip frontmatter', () {
      File('$home/prompts/sys.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
---
name: my_system
description: custom system prompt
---
You are MY agent.
''');
      final overrides = resolvePromptOverrides(
        const {'system': '~/prompts/sys.md'},
        homeDir: home,
        baseDir: cwd,
      );
      // The `system` alias canonicalizes to cli/mode_code.
      expect(
        overrides.resolve('cli/mode_code', 'builtin'),
        'You are MY agent.',
      );
      expect(overrides.names, ['cli/mode_code']);
    });

    test('relative file paths resolve against the base dir', () {
      File('$cwd/prompts/sum.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('Summarize tersely.');
      final overrides = resolvePromptOverrides(
        const {'compaction/summary': './prompts/sum.md'},
        homeDir: home,
        baseDir: cwd,
      );
      expect(
        overrides.resolve('compaction/summary', 'builtin'),
        'Summarize tersely.',
      );
    });

    test('absolute file paths are used as-is', () {
      final file = File('${tmp.path}/abs.md')..writeAsStringSync('Absolute.');
      final overrides = resolvePromptOverrides(
        {'cli/mode_architect': file.path},
        homeDir: home,
        baseDir: cwd,
      );
      expect(overrides.resolve('cli/mode_architect', 'builtin'), 'Absolute.');
    });

    test('a missing file is a ConfigException, never a silent fallback', () {
      expect(
        () => resolvePromptOverrides(
          const {'system': '~/prompts/does_not_exist.md'},
          homeDir: home,
          baseDir: cwd,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('prompts.system'),
              contains('prompt file not found'),
              contains('$home/prompts/does_not_exist.md'),
            ),
          ),
        ),
      );
    });

    test('an empty prompt file is a ConfigException', () {
      File(
        '$cwd/empty.md',
      ).writeAsStringSync('---\nname: x\ndescription: y\n---\n');
      expect(
        () => resolvePromptOverrides(
          const {'cli/mode_code': './empty.md'},
          homeDir: home,
          baseDir: cwd,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('prompt file is empty'),
          ),
        ),
      );
    });
  });

  group('loadPromptFile (--system-prompt-file)', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fah-system-prompt-file-test-');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('reads a file with any extension, stripping frontmatter', () {
      File('${tmp.path}/prompt.txt').writeAsStringSync('Be brief.');
      final text = loadPromptFile(
        'prompt.txt',
        homeDir: tmp.path,
        baseDir: tmp.path,
        source: '--system-prompt-file',
      );
      expect(text, 'Be brief.');
    });

    test('expands ~ against the home dir', () {
      File('${tmp.path}/home/sys.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('From home.');
      final text = loadPromptFile(
        '~/sys.md',
        homeDir: '${tmp.path}/home',
        baseDir: tmp.path,
        source: '--system-prompt-file',
      );
      expect(text, 'From home.');
    });

    test('a missing file is a ConfigException naming the flag', () {
      expect(
        () => loadPromptFile(
          'nope.md',
          homeDir: tmp.path,
          baseDir: tmp.path,
          source: '--system-prompt-file',
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('--system-prompt-file'),
              contains('prompt file not found'),
            ),
          ),
        ),
      );
    });
  });
}
