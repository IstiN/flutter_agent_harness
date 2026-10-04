/// gh-1164 Part A: the `js-apps` skill is a first-party core builtin
/// (source of truth `prompts/skills/js-apps/SKILL.md`, compiled into
/// `builtinSkillFiles` by `scripts/gen_prompts.dart`) — invocable on every
/// host (CLI + app), with the incident-hardened content: the decisive
/// apps/<id>-vs-dynamic_message routing table, the calculator anti-pattern
/// named, and the pre-flight/error-channel contract taught.
@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  Skill? jsApps() {
    for (final skill in builtinSkills()) {
      if (skill.name == 'js-apps') return skill;
    }
    return null;
  }

  test('js-apps is a user-invocable package builtin', () {
    final skill = jsApps();
    expect(skill, isNotNull, reason: 'js-apps missing from builtinSkills()');
    expect(skill!.userInvocable, isTrue, reason: '/js-apps must work');
    expect(
      skill.description,
      contains('JS apps'),
      reason: 'auto-suggestion description lost',
    );
  });

  test('prompt-injection scenario: calculator request routes to apps/<id>', () {
    // AC2 golden skill-render assertion for "сделай мне калькулятор":
    // the decisive routing table + the calculator anti-pattern must lead
    // the agent to the installed-app surface with a manifest.
    final text = jsApps()!.embeddedText;
    expect(text, contains('The calculator anti-pattern'));
    expect(
      text,
      contains('belongs in `apps/<id>`'),
      reason: 'routing rule must be unambiguous (incident: the agent '
          'guessed its way to apps/<id> only after building the wrong '
          'surface)',
    );
    expect(text, contains('dynamic_message'));
    expect(text, contains('manifest.json'));
  });

  test('skill teaches test reuse and the pre-flight no-fake-success gate', () {
    // AC7/AC8/AC9: the standing-test contract — extend, never regenerate;
    // red test = failed tool result; the result names the degraded gate.
    final text = jsApps()!.embeddedText;
    expect(text, contains('no fake success'));
    expect(text, contains('NEVER regenerate it from scratch'));
    expect(text, contains('test/apps/<id>_test.dart'));
  });

  test('builtin renders clean on every host (no platform-filter markers)', () {
    // The old bundled asset was platform-filtered by the app seeder; the
    // builtin reaches CLI hosts verbatim, so the source must not carry
    // fa-platforms markers or the {{FA_PLATFORM}} placeholder.
    final text = jsApps()!.embeddedText;
    expect(text, isNot(contains('fa-platforms')));
    expect(text, isNot(contains('{{FA_PLATFORM}}')));
  });
}
