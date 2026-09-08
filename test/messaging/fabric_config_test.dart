import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

FabricConfig parse(String yaml) {
  final doc = loadYaml(yaml);
  return FabricConfig.fromYaml(doc is YamlMap ? doc['fabric'] : doc);
}

void main() {
  group('FabricConfig.fromYaml', () {
    test('absent capabilities yields the default config', () {
      expect(parse('fabric: {}'), const FabricConfig());
    });

    test('parses full capability entries', () {
      final config = parse('''
fabric:
  capabilities:
    - name: yoclip.render
      description: Render the open project to MP4
      payload: scene=<id>
''');
      expect(config.capabilities, hasLength(1));
      final capability = config.capabilities.single;
      expect(capability.name, 'yoclip.render');
      expect(capability.description, 'Render the open project to MP4');
      expect(capability.payload, 'scene=<id>');
    });

    test('trims the name and allows omitted description/payload', () {
      final config = parse('fabric:\n  capabilities:\n  - name:  probe \n');
      expect(config.capabilities.single.name, 'probe');
      expect(config.capabilities.single.description, isNull);
      expect(config.capabilities.single.payload, isNull);
    });

    test('rejects a non-map section', () {
      expect(() => parse('fabric: nope'), throwsConfigException);
    });

    test('rejects unknown section keys', () {
      expect(() => parse('fabric: {bogus: 1}'), throwsConfigException);
    });

    test('rejects a non-list capabilities value', () {
      expect(() => parse('fabric: {capabilities: 3}'), throwsConfigException);
    });

    test('rejects non-map capability entries', () {
      expect(
        () => parse('fabric:\n  capabilities:\n  - nope'),
        throwsConfigException,
      );
    });

    test('rejects unknown capability keys', () {
      expect(
        () => parse('fabric:\n  capabilities:\n  - {name: x, bogus: 1}'),
        throwsConfigException,
      );
    });

    test('rejects an empty name', () {
      expect(
        () => parse('fabric:\n  capabilities:\n  - name: "  "'),
        throwsConfigException,
      );
    });
  });

  group('FabricConfig.toYaml', () {
    test('emits nothing without capabilities', () {
      expect(const FabricConfig().toYaml(), isEmpty);
    });

    test('round-trips through loadYaml', () {
      const config = FabricConfig(
        capabilities: [
          AgentCapability(name: 'a.render', description: 'Render'),
          AgentCapability(name: 'a.ship', payload: 'target=prod'),
        ],
      );
      final reparsed = FabricConfig.fromYaml(
        (loadYaml(config.toYaml()) as YamlMap)['fabric'],
      );
      expect(reparsed.capabilities[0].name, 'a.render');
      expect(reparsed.capabilities[0].description, 'Render');
      expect(reparsed.capabilities[1].name, 'a.ship');
      expect(reparsed.capabilities[1].payload, 'target=prod');
    });
  });
}

/// Matcher helper: the config schema must fail loudly.
Matcher get throwsConfigException =>
    throwsA(const TypeMatcher<ConfigException>());
