import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('parseCommandArgs', () {
    test('splits unquoted arguments', () {
      expect(parseCommandArgs('a b c'), ['a', 'b', 'c']);
    });

    test('respects double quotes', () {
      expect(parseCommandArgs('a "b c" d'), ['a', 'b c', 'd']);
    });

    test('respects single quotes', () {
      expect(parseCommandArgs("a 'b c' d"), ['a', 'b c', 'd']);
    });

    test('returns empty list for empty input', () {
      expect(parseCommandArgs(''), isEmpty);
    });

    test('ignores leading and trailing whitespace', () {
      expect(parseCommandArgs('  a   b  '), ['a', 'b']);
    });
  });

  group('substituteArgs', () {
    test('replaces positional args', () {
      expect(
        substituteArgs('Hello \$1, meet \$2.', ['Alice', 'Bob']),
        'Hello Alice, meet Bob.',
      );
    });

    test('replaces \$@ with all args', () {
      expect(substituteArgs('Args: \$@', ['a', 'b', 'c']), 'Args: a b c');
    });

    test('replaces \$ARGUMENTS with all args', () {
      expect(substituteArgs('Args: \$ARGUMENTS', ['x', 'y']), 'Args: x y');
    });

    test('uses default value when arg missing', () {
      expect(substituteArgs('Limit: \${1:-10}', []), 'Limit: 10');
    });

    test('uses default value when arg empty', () {
      expect(substituteArgs('Limit: \${1:-10}', ['']), 'Limit: 10');
    });

    test('uses provided value over default', () {
      expect(substituteArgs('Limit: \${1:-10}', ['20']), 'Limit: 20');
    });

    test('slices args from N onwards', () {
      expect(substituteArgs('Rest: \${@:2}', ['a', 'b', 'c']), 'Rest: b c');
    });

    test('slices a bounded range', () {
      expect(
        substituteArgs('Range: \${@:2:2}', ['a', 'b', 'c', 'd']),
        'Range: b c',
      );
    });

    test('leaves unknown placeholders empty', () {
      expect(substituteArgs('Missing: \$5', ['a']), 'Missing: ');
    });
  });

  group('parseFrontmatter', () {
    test('parses YAML frontmatter', () {
      final result = parseFrontmatter(
        '---\ndescription: Review code\n---\nReview this: \$1',
      );
      expect(result.frontmatter['description'], 'Review code');
      expect(result.body, 'Review this: \$1');
    });

    test('returns empty frontmatter and original body when absent', () {
      final result = parseFrontmatter('Just content');
      expect(result.frontmatter, isEmpty);
      expect(result.body, 'Just content');
    });

    test('handles CRLF separator', () {
      final result = parseFrontmatter('---\r\ndescription: x\r\n---\r\nbody');
      expect(result.frontmatter['description'], 'x');
      expect(result.body, 'body');
    });

    test('falls back to full content on invalid frontmatter', () {
      final content = '---\nnot yaml : : :\n---\nbody';
      final result = parseFrontmatter(content);
      expect(result.body, content);
    });
  });

  group('loadPromptTemplates', () {
    late MemoryExecutionEnv env;

    setUp(() {
      env = MemoryExecutionEnv();
    });

    test('loads templates from a directory', () async {
      await env.writeFile('/prompts/review.md', 'Review \$1 for bugs.');
      await env.writeFile('/prompts/plan.md', 'Plan implementation for \$1.');
      final templates = await loadPromptTemplates(env, ['/prompts']);
      expect(templates.map((t) => t.name), containsAll(['review', 'plan']));
    });

    test('ignores missing directories', () async {
      final templates = await loadPromptTemplates(env, ['/missing']);
      expect(templates, isEmpty);
    });

    test('ignores non-markdown files', () async {
      await env.writeFile('/prompts/review.md', 'Review \$1.');
      await env.writeFile('/prompts/notes.txt', 'Not a template.');
      final templates = await loadPromptTemplates(env, ['/prompts']);
      expect(templates, hasLength(1));
      expect(templates.first.name, 'review');
    });

    test('extracts description from frontmatter', () async {
      await env.writeFile(
        '/prompts/review.md',
        '---\ndescription: Review code\nargument-hint: <path>\n---\nReview \$1',
      );
      final templates = await loadPromptTemplates(env, ['/prompts']);
      expect(templates.first.description, 'Review code');
      expect(templates.first.argumentHint, '<path>');
    });

    test(
      'extracts description from first line when frontmatter absent',
      () async {
        await env.writeFile(
          '/prompts/review.md',
          'Review the supplied code for issues.\nMore detail.',
        );
        final templates = await loadPromptTemplates(env, ['/prompts']);
        expect(
          templates.first.description,
          'Review the supplied code for issues.',
        );
      },
    );
  });

  group('expandPromptTemplate', () {
    test('expands a matching template', () {
      final templates = [
        const PromptTemplate(
          name: 'review',
          description: 'review',
          content: 'Review this code: \$1',
          filePath: '/prompts/review.md',
        ),
      ];
      expect(
        expandPromptTemplate('/review lib/main.dart', templates),
        'Review this code: lib/main.dart',
      );
    });

    test('leaves non-template slash text unchanged', () {
      final templates = <PromptTemplate>[];
      expect(expandPromptTemplate('/unknown', templates), '/unknown');
    });

    test('leaves non-slash text unchanged', () {
      final templates = <PromptTemplate>[];
      expect(expandPromptTemplate('hello', templates), 'hello');
    });

    test('expands with quoted args', () {
      final templates = [
        const PromptTemplate(
          name: 'component',
          description: 'component',
          content: 'Create \$1 with features: \$@',
          filePath: '/prompts/component.md',
        ),
      ];
      expect(
        expandPromptTemplate(
          '/component Button "onClick" "disabled"',
          templates,
        ),
        'Create Button with features: Button onClick disabled',
      );
    });
  });

  group('builtInAgentModes', () {
    test('includes code, architect, and review', () {
      final modes = builtInAgentModes('/work');
      expect(modes.keys, containsAll(['code', 'architect', 'review']));
    });

    test('code mode uses default coding prompt', () {
      final mode = builtInAgentModes('/work')['code']!;
      expect(mode.systemPrompt, contains('You are fah'));
      expect(mode.systemPrompt, contains('/work'));
    });

    test('architect mode emphasizes design', () {
      final mode = builtInAgentModes('/work')['architect']!;
      expect(mode.systemPrompt, contains('architect mode'));
      expect(mode.systemPrompt, contains('design'));
    });

    test('review mode emphasizes review', () {
      final mode = builtInAgentModes('/work')['review']!;
      expect(mode.systemPrompt, contains('code review mode'));
      expect(mode.systemPrompt, contains('security'));
    });
  });
}
