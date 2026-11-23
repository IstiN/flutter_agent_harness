import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The `messaging:` config section (issue #2226): the wake-gating knobs.
/// Strict parse; the defaults pin the #2226 behavior — cap OFF, smart
/// detection ON, a generous chain budget.
void main() {
  Object? yamlNode(String source) => (loadYaml(source) as Map)['messaging'];

  test('#2226 AC6: the defaults are cap OFF + detection ON + a generous '
      'budget', () {
    const config = MessagingConfig();
    expect(
      config.wakeChatterCap,
      0,
      reason: 'the raw streak cap is OFF by default now',
    );
    expect(config.chainBudgetTokens, 400000);
    expect(config.loopDetection.enabled, isTrue);
    expect(config.loopDetection.similarityThreshold, 0.92);
    expect(config.loopDetection.stuckRounds, 4);
  });

  test('an absent section arrives as null from the parser and defaults', () {
    // The CLI/app parsers call MessagingConfig.fromYaml(map['messaging']) —
    // an absent section is a null node, never a foreign map.
    final config = MessagingConfig.fromYaml(null);
    expect(config.wakeChatterCap, 0);
    expect(config.chainBudgetTokens, 400000);
    expect(config.loopDetection.enabled, isTrue);
  });

  test('a null node parses to defaults', () {
    final config = MessagingConfig.fromYaml(null);
    expect(config.wakeChatterCap, 0);
  });

  test('#2226 AC6: an explicit wakeChatterCap re-enables the legacy cap', () {
    final config = MessagingConfig.fromYaml(
      yamlNode(
        'messaging:\n'
        '  wakeChatterCap: 10\n',
      ),
    );
    expect(config.wakeChatterCap, 10);
  });

  test('a full section parses every knob', () {
    final config = MessagingConfig.fromYaml(
      yamlNode(
        'messaging:\n'
        '  wakeChatterCap: 5\n'
        '  chainBudgetTokens: 100000\n'
        '  loopDetection:\n'
        '    enabled: false\n'
        '    similarityThreshold: 0.8\n'
        '    stuckRounds: 2\n',
      ),
    );
    expect(config.wakeChatterCap, 5);
    expect(config.chainBudgetTokens, 100000);
    expect(config.loopDetection.enabled, isFalse);
    expect(config.loopDetection.similarityThreshold, 0.8);
    expect(config.loopDetection.stuckRounds, 2);
  });

  test('unknown keys throw (strict, like every operational section)', () {
    expect(
      () => MessagingConfig.fromYaml(yamlNode('messaging:\n  nonsense: 1\n')),
      throwsA(isA<ConfigException>()),
    );
    expect(
      () => MessagingConfig.fromYaml(
        yamlNode('messaging:\n  loopDetection:\n    nonsense: 1\n'),
      ),
      throwsA(isA<ConfigException>()),
    );
  });

  test('bad shapes throw (strict)', () {
    expect(
      () => MessagingConfig.fromYaml(yamlNode('messaging: not-a-map')),
      throwsA(isA<ConfigException>()),
    );
    expect(
      () => MessagingConfig.fromYaml(
        yamlNode('messaging:\n  wakeChatterCap: -1\n'),
      ),
      throwsA(isA<ConfigException>()),
    );
    expect(
      () => MessagingConfig.fromYaml(
        yamlNode('messaging:\n  chainBudgetTokens: lots\n'),
      ),
      throwsA(isA<ConfigException>()),
    );
    expect(
      () => MessagingConfig.fromYaml(
        yamlNode('messaging:\n  loopDetection:\n    similarityThreshold: 2\n'),
      ),
      throwsA(isA<ConfigException>()),
    );
    expect(
      () => MessagingConfig.fromYaml(
        yamlNode('messaging:\n  loopDetection:\n    stuckRounds: 0\n'),
      ),
      throwsA(isA<ConfigException>()),
    );
    expect(
      () => MessagingConfig.fromYaml(
        yamlNode('messaging:\n  loopDetection:\n    enabled: yes-please\n'),
      ),
      throwsA(isA<ConfigException>()),
    );
  });
}
