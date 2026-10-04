/// Per-skill availability toggles (issue #1151): the `skills:` scope stack
/// (global < project, deepest wins), default-on, unknown-id collection,
/// and the enabled-skills gate.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

Skill _skill(String name) => Skill(
  name: name,
  description: 'desc $name',
  filePath: '/work/.fah/skills/$name/SKILL.md',
  scope: SkillScope.project,
  source: SkillSource.fah,
);

void main() {
  group('SkillsConfig.fromYaml', () {
    test('parses per-skill boolean entries, skipping reserved keys', () {
      final config = SkillsConfig.fromYaml(
        loadYaml(
          'access: granted\ndisableShellExecution: false\n'
          'create-goal: off\nself-settings: on\n',
        ),
      );
      expect(config.skills, {'create-goal': false, 'self-settings': true});
    });

    test('a malformed value throws ConfigException naming the skill', () {
      expect(
        () => SkillsConfig.fromYaml(loadYaml('create-goal: yes-please')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('skills.create-goal'),
          ),
        ),
      );
    });

    test('yaml 1.2 string spellings on/off coerce like booleans', () {
      final config = SkillsConfig.fromYaml(
        loadYaml('create-goal: off\nself-settings: on'),
      );
      expect(config.skills, {'create-goal': false, 'self-settings': true});
    });

    test('toYaml round-trips through fromYaml', () {
      final config = SkillsConfig(skills: {'create-goal': false});
      final back = SkillsConfig.fromYaml(
        (loadYaml('root:\n${config.toYaml()}') as YamlMap)['root'],
      );
      expect(back.skills, config.skills);
    });
  });

  group('resolveSkillAvailability', () {
    final skills = [_skill('create-goal'), _skill('self-settings')];

    test('defaults every skill to enabled', () {
      final resolution = resolveSkillAvailability(skills: skills, scopes: []);
      expect(resolution.byName.values.every((d) => d.enabled), isTrue);
      expect(resolution.unknownIds, isEmpty);
    });

    test('the project scope turns a skill off', () {
      final resolution = resolveSkillAvailability(
        skills: skills,
        scopes: [
          (
            SkillToggleScope.project,
            SkillsConfig(skills: {'create-goal': false}),
          ),
        ],
      );
      expect(resolution.byName['create-goal']!.enabled, isFalse);
      expect(resolution.byName['create-goal']!.scope, SkillToggleScope.project);
      expect(resolution.byName['self-settings']!.enabled, isTrue);
    });

    test('global off + project on resolves on (deepest wins)', () {
      final resolution = resolveSkillAvailability(
        skills: skills,
        scopes: [
          (
            SkillToggleScope.global,
            SkillsConfig(skills: {'create-goal': false}),
          ),
          (
            SkillToggleScope.project,
            SkillsConfig(skills: {'create-goal': true}),
          ),
        ],
      );
      expect(resolution.byName['create-goal']!.enabled, isTrue);
      expect(resolution.byName['create-goal']!.scope, SkillToggleScope.project);
    });

    test('project off wins over global on', () {
      final resolution = resolveSkillAvailability(
        skills: skills,
        scopes: [
          (
            SkillToggleScope.global,
            SkillsConfig(skills: {'create-goal': true}),
          ),
          (
            SkillToggleScope.project,
            SkillsConfig(skills: {'create-goal': false}),
          ),
        ],
      );
      expect(resolution.byName['create-goal']!.enabled, isFalse);
    });

    test('matching is case-insensitive; unknown ids are collected', () {
      final resolution = resolveSkillAvailability(
        skills: skills,
        scopes: [
          (
            SkillToggleScope.global,
            SkillsConfig(skills: {'CREATE-GOAL': false, 'nonexistent': false}),
          ),
        ],
      );
      expect(resolution.byName['create-goal']!.enabled, isFalse);
      expect(resolution.unknownIds, {'nonexistent'});
    });

    test('enabledSkills filters disabled skills preserving order', () {
      final resolution = resolveSkillAvailability(
        skills: skills,
        scopes: [
          (
            SkillToggleScope.project,
            SkillsConfig(skills: {'self-settings': false}),
          ),
        ],
      );
      expect(enabledSkills(skills, resolution).map((s) => s.name), [
        'create-goal',
      ]);
    });
  });
}
