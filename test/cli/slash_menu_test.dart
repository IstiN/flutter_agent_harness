import 'package:flutter_agent_harness/src/cli/prompt_templates.dart';
import 'package:flutter_agent_harness/src/cli/slash_menu.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:flutter_agent_harness/src/skills/skills.dart';
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

  Skill skill(
    String name, {
    String description = 'skill description',
    SkillManifest manifest = SkillManifest.empty,
  }) => Skill(
    name: name,
    description: description,
    filePath: '/tmp/skills/$name/SKILL.md',
    scope: SkillScope.project,
    source: SkillSource.fah,
    manifest: manifest,
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

    test('skills match by name or description and insert /skill:<name>', () {
      final items = buildSlashMenuItems(
        '/dep',
        slashCommands: slashCommands,
        pluginSlashCommands: const {},
        templates: const [],
        skills: [skill('deploy', description: 'Deploy the app')],
      );
      // The trailing space leaves the cursor ready for the skill's args.
      expect(items.single.key, '/skill:deploy ');
      expect(items.single.label, '/deploy');
      expect(items.single.description, 'Deploy the app');

      final byDescription = buildSlashMenuItems(
        'the app',
        slashCommands: slashCommands,
        pluginSlashCommands: const {},
        templates: const [],
        skills: [skill('deploy', description: 'Deploy the app')],
      );
      expect(byDescription.single.label, '/deploy');
    });

    test('skills match on a mid-name fragment without the leading slash', () {
      // /goal must offer /create-goal: the leading slash of the skill's
      // label must not break the substring match (user report: typing
      // /goal showed no skill suggestion).
      final items = buildSlashMenuItems(
        '/goal',
        slashCommands: const {},
        pluginSlashCommands: const {},
        templates: const [],
        skills: [skill('create-goal')],
      );
      expect(items.single.key, '/skill:create-goal ');
      expect(items.single.label, '/create-goal');
    });

    test('skills match after a /skill: prefix', () {
      // Typing /skill:goal filters skills by the part after the colon.
      final items = buildSlashMenuItems(
        '/skill:goal',
        slashCommands: const {},
        pluginSlashCommands: const {},
        templates: const [],
        skills: [skill('create-goal'), skill('deploy')],
      );
      expect(items.single.key, '/skill:create-goal ');
    });

    test('model-only skills (user-invocable: false) are not offered', () {
      final items = buildSlashMenuItems(
        '/hid',
        slashCommands: slashCommands,
        pluginSlashCommands: const {},
        templates: const [],
        skills: [
          skill(
            'hidden',
            manifest: SkillManifest.fromFrontmatter(const {
              'user-invocable': false,
            }),
          ),
        ],
      );
      expect(items, isEmpty);
    });

    test('the skill description carries the argument hint when present', () {
      final items = buildSlashMenuItems(
        '/dep',
        slashCommands: slashCommands,
        pluginSlashCommands: const {},
        templates: const [],
        skills: [
          skill(
            'deploy',
            description: 'Deploy the app',
            manifest: SkillManifest.fromFrontmatter(const {
              'argument-hint': '[env]',
            }),
          ),
        ],
      );
      expect(items.single.description, 'Deploy the app [env]');
    });
  });

  group('helpLines', () {
    final style = _PlainStyle();

    test(
      'the full listing includes plugins, templates, and the steer hint',
      () async {
        final lines = helpLines(
          pluginSlashCommands: {'/deploy': (args) async {}},
          templates: [template('review', argumentHint: '<file>')],
          style: style,
        );
        expect(lines.first, '[Commands]');
        expect(
          lines,
          containsAllInOrder([
            '  /exit              quit',
            '',
            '[Plugin commands]',
            '  /deploy',
            '',
            '[Prompt templates]',
            '  /review <file>',
            '',
            'While a run streams, type to steer the agent; Ctrl-C aborts.',
          ]),
        );
      },
    );

    test('a filtered listing matches name or description, without extras', () {
      final lines = helpLines(
        filter: 'quit',
        pluginSlashCommands: {'/deploy': (args) async {}},
        templates: [template('review')],
        style: style,
      );
      expect(lines, [
        '[Commands matching "quit"]',
        '  /exit              quit',
      ]);
    });

    test('a filter matching nothing yields the unknown-command line', () {
      final lines = helpLines(
        filter: 'zzz',
        pluginSlashCommands: const {},
        templates: const [],
        style: style,
      );
      expect(lines, ['unknown command: /zzz (try /help)']);
    });

    test(
      'the full listing without plugins or templates ends with the hint',
      () {
        final lines = helpLines(
          pluginSlashCommands: const {},
          templates: const [],
          style: style,
        );
        expect(lines.last, contains('type to steer the agent'));
        expect(lines, isNot(contains('[Plugin commands]')));
        expect(lines, isNot(contains('[Prompt templates]')));
        expect(lines, isNot(contains('[Skills]')));
      },
    );

    test('the full listing includes the skills section', () {
      final lines = helpLines(
        pluginSlashCommands: const {},
        templates: const [],
        style: style,
        skills: [skill('deploy', description: 'Deploy the app')],
      );
      expect(lines, contains('[Skills]'));
      expect(lines, contains('  /deploy Deploy the app'));
    });
  });

  group('lineModeMenuLines', () {
    test('numbers every builtin command', () {
      final lines = lineModeMenuLines(_PlainStyle());
      expect(lines.first, '');
      expect(lines[1], '[Commands]');
      expect(lines[2], startsWith('  1) /exit'));
      expect(lines, hasLength(builtinSlashCommands.length + 3));
      expect(lines.last, '');
    });

    test('skills continue the numbering after the builtin commands', () {
      final lines = lineModeMenuLines(
        _PlainStyle(),
        skills: [skill('deploy', description: 'Deploy the app')],
      );
      expect(lines, hasLength(builtinSlashCommands.length + 4));
      expect(
        lines[builtinSlashCommands.length + 2],
        '  ${builtinSlashCommands.length + 1}) /deploy Deploy the app',
      );
      // The menu entry resolves to the explicit invocation form.
      final entries = lineModeMenuEntries([skill('deploy')]);
      expect(entries.last.key, '/skill:deploy');
    });
  });

  group('resolveLineModeMenuChoice', () {
    test('a valid number returns the matching entry key', () {
      expect(
        resolveLineModeMenuChoice('1', []),
        builtinSlashCommands.entries.first.key,
      );
    });

    test('a number out of range returns null', () {
      expect(resolveLineModeMenuChoice('0', []), isNull);
      expect(
        resolveLineModeMenuChoice('${builtinSlashCommands.length + 1}', []),
        isNull,
      );
    });

    test('a builtin command name resolves with or without slash', () {
      expect(resolveLineModeMenuChoice('/help', []), '/help');
      expect(resolveLineModeMenuChoice('help', []), '/help');
    });

    test('a skill name resolves to /skill:<name>', () {
      expect(
        resolveLineModeMenuChoice('/deploy', [skill('deploy')]),
        '/skill:deploy',
      );
      expect(
        resolveLineModeMenuChoice('deploy', [skill('deploy')]),
        '/skill:deploy',
      );
    });

    test('unknown input returns null', () {
      expect(resolveLineModeMenuChoice('zzz', []), isNull);
    });
  });
}

class _PlainStyle implements TuiStyle {
  @override
  String bold(String text) => text;
  @override
  String dim(String text) => text;
  @override
  String cyan(String text) => text;
  @override
  String green(String text) => text;
  @override
  String yellow(String text) => text;
  @override
  String magenta(String text) => text;
}
