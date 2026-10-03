/// gh-1164 Part A: the `js-apps` skill is a first-party BUILTIN (promoted
/// from the flutter_app asset, one source in core) with decisive
/// `apps/<id>`-vs-dynamic_message routing.
///
/// AC1 — `/js-apps` resolves as a builtin on every host; NO second copy
/// ships (the #1151 drift rule: an embedded+bundled skill would shadow the
/// builtin with a duplicate listing — "byte-identical" is enforced the
/// stronger way, by there being exactly one source file).
/// AC2 — prompt-injection probe ("сделай мне калькулятор"): the rendered
/// skill guidance selects `apps/<id>` + manifest.json and names the
/// widget path as ephemeral-only.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/skills/skill_renderer.dart';
import 'package:test/test.dart';

void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
  });

  Skill jsApps() => builtinSkills().firstWhere((s) => s.name == 'js-apps');

  group('AC1 — the builtin resolves (fresh project, every host)', () {
    test('js-apps ships as a compiled-in builtin', () {
      expect(jsApps().source, SkillSource.builtin);
      expect(jsApps().scope, SkillScope.builtin);
      expect(jsApps().embeddedText, isNotNull);
      expect(jsApps().filePath, 'builtin://skills/js-apps/SKILL.md');
      expect(jsApps().description, contains('Apps section'));
    });

    test('it is user-invocable (/js-apps) and model-suggested', () {
      expect(jsApps().userInvocable, isTrue, reason: '/js-apps resolves');
      expect(jsApps().modelInvocable, isTrue);
      // Auto-suggest trigger hints ride the manifest.
      expect(
        jsApps().manifest.whenToUse,
        contains('app'),
        reason: 'the catalog description carries the ask-for-an-app trigger',
      );
    });

    test('the embedded copy serves from the builtin:// read path', () async {
      expect(builtinSkillTextAt(jsApps().filePath), jsApps().embeddedText);
      final rendered = await renderSkillBody(env, jsApps(), args: 'a timer');
      expect(rendered.body, contains('Fa JS App Development Skill'));
      expect(rendered.body, isNot(contains(r'$ARGUMENTS')));
    });

    test('NO drift-able second copy exists (asset retired)', () {
      expect(
        File('flutter_app/assets/skills/js-apps').existsSync(),
        isFalse,
        reason:
            'js-apps is embedded as a package builtin; a bundled app copy '
            'would shadow the builtin with a duplicate listing (#1151 rule, '
            'gh-1164 promoted the source to prompts/skills/js-apps/)',
      );
      final pubspec = File('flutter_app/pubspec.yaml').readAsStringSync();
      expect(pubspec, isNot(contains('assets/skills/js-apps')));
      // The app seeder no longer seeds it — the retirement fingerprints do.
      final seeder = File(
        'flutter_app/lib/services/agent_service_skills.dart',
      ).readAsStringSync();
      expect(seeder, isNot(contains("{'js-apps'")));
      expect(seeder, contains('_staleSeedFingerprints'));
      expect(seeder, contains("'js-apps': {"));
      // The core source of truth stays where the compiler reads it.
      expect(File('prompts/skills/js-apps/SKILL.md').existsSync(), isTrue);
    });
  });

  group('AC2 — the rendered guidance routes decisively', () {
    late String body;

    setUp(() async {
      body = (await renderSkillBody(
        env,
        jsApps(),
        args: 'сделай мне калькулятор',
      )).body;
    });

    test('a calculator ask resolves to apps/<id> + manifest.json', () {
      // The routing table's calculator row is the FIRST decision the body
      // presents — before any widget guidance.
      expect(body, contains('DECIDE FIRST'));
      expect(body, contains('`apps/<id>/` — `manifest.json` + `widget.js`'));
      expect(
        body.indexOf('DECIDE FIRST'),
        lessThan(body.indexOf('## ⚡ Quick Start')),
        reason: 'routing is the first thing the agent reads',
      );
    });

    test('the calculator anti-pattern is named with the incident probe', () {
      expect(body, contains('сделай мне калькулятор'));
      expect(body, contains('calculator anti-pattern'));
      expect(
        body,
        contains('dynamic_message'),
        reason: 'the widget surface is named — and scoped below',
      );
    });

    test('the widget path is scoped to ephemeral inline content only', () {
      expect(body, contains('ephemeral inline content ONLY'));
      expect(body, contains('dies with the chat turn'));
    });

    test('the error feedback loop + pre-flight gate are taught', () {
      expect(body, contains('errors reach you, not just the screen'));
      expect(body, contains('pre-flight gate'));
      expect(body, contains('smoke-render'));
      expect(body, contains('flutter-test'));
      expect(body, contains('extend, never regenerate'));
    });
  });
}
