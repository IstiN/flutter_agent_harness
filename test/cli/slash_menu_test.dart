import 'package:flutter_agent_harness/src/cli/prompt_templates.dart';
import 'package:flutter_agent_harness/src/cli/slash_menu.dart';
import 'package:test/test.dart';

void main() {
  const slashCommands = {
    '/help': 'show help',
    '/exit': 'quit the cli',
    '/model': 'select model',
  };

  PromptTemplate template(String name, {String? argumentHint}) =>
      PromptTemplate(
        name: name,
        description: 'template $name',
        argumentHint: argumentHint,
        content: 'body',
        filePath: '/tmp/$name.md',
      );

  group('buildSlashMenuItems', () {
    test('matches builtin commands by key and description', () {
      final byKey = buildSlashMenuItems(
        '/he',
        slashCommands: slashCommands,
        pluginSlashCommands: const {},
        templates: const [],
      );
      expect(byKey.map((i) => i.key), ['/help']);
      expect(byKey.single.description, 'show help');

      final byDescription = buildSlashMenuItems(
        'quit',
        slashCommands: slashCommands,
        pluginSlashCommands: const {},
        templates: const [],
      );
      expect(byDescription.map((i) => i.key), ['/exit']);
    });

    test('matching is case-insensitive', () {
      final items = buildSlashMenuItems(
        '/HELP',
        slashCommands: slashCommands,
        pluginSlashCommands: const {},
        templates: const [],
      );
      expect(items.map((i) => i.key), ['/help']);
    });

    test('plugin commands match on the name only', () async {
      final plugin = buildSlashMenuItems(
        '/dep',
        slashCommands: slashCommands,
        pluginSlashCommands: {'/deploy': (args) async {}},
        templates: const [],
      );
      expect(plugin.map((i) => i.key), ['/deploy']);
      expect(plugin.single.description, '');

      final noMatch = buildSlashMenuItems(
        '/xyz',
        slashCommands: slashCommands,
        pluginSlashCommands: {'/deploy': (args) async {}},
        templates: const [],
      );
      expect(noMatch, isEmpty);
    });

    test('templates appear with their argument hint as the description', () {
      final items = buildSlashMenuItems(
        '/rev',
        slashCommands: slashCommands,
        pluginSlashCommands: const {},
        templates: [template('review', argumentHint: '<file>')],
      );
      expect(items.single.key, '/review');
      expect(items.single.description, '<file>');
    });

    test('a template without a hint gets an empty description', () {
      final items = buildSlashMenuItems(
        '/rev',
        slashCommands: slashCommands,
        pluginSlashCommands: const {},
        templates: [template('review')],
      );
      expect(items.single.description, '');
    });
  });
}
