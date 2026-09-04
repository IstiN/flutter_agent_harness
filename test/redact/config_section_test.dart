import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

RedactionPipeline _pipelineWithSecret() =>
    RedactionPipeline(registeredSecrets: ['supersecretvalue1']);

void main() {
  group('redact: config section', () {
    test('absent section parses to null', () {
      final config = CliConfig.fromYaml(
        loadYaml('provider: openai-completions\n') as YamlMap,
      );
      expect(config.redact, isNull);
    });

    test('parses enabled/blockMode/layers/allowlist/toolPolicy', () {
      final config = CliConfig.fromYaml(
        loadYaml('''
redact:
  enabled: false
  blockMode: true
  layers:
    pii: true
    entropy: false
  allowlist:
    - '[0-9a-f]{40}'
  toolAllow:
    - read
  toolDeny:
    - write
''')
            as YamlMap,
      );
      final redact = config.redact!;
      expect(redact.enabled, isFalse);
      expect(redact.blockMode, isTrue);
      expect(redact.layerToggles[RedactionLayer.pii], isTrue);
      expect(redact.layerToggles[RedactionLayer.entropy], isFalse);
      expect(redact.allowlistRegexes.single.pattern, '[0-9a-f]{40}');
      expect(redact.toolAllow, {'read'});
      expect(redact.toolDeny, {'write'});
      // policy mirrors allow/deny
      expect(redact.toolPolicy.appliesTo('read'), isTrue);
      expect(redact.toolPolicy.appliesTo('bash'), isFalse);
      expect(redact.toolPolicy.appliesTo('write'), isFalse);
    });

    test('invalid values fall back to defaults (tolerant parse)', () {
      final config = CliConfig.fromYaml(
        loadYaml('''
redact:
  enabled: "yes please"
  blockMode: 7
  toolAllow: [1, 2]
''')
            as YamlMap,
      );
      final redact = config.redact!;
      expect(redact.enabled, isTrue);
      expect(redact.blockMode, isFalse);
      expect(redact.toolAllow, isEmpty);
    });

    test('toYaml round-trips layers + allowlist too', () {
      final config = RedactionConfig(
        layerToggles: {RedactionLayer.pii: true},
        allowlistRegexes: [RegExp('[0-9a-f]{40}')],
      );
      final yaml = CliConfig(redact: config).toYaml();
      expect(yaml, contains('layers:'));
      expect(yaml, contains('pii: true'));
      expect(yaml, contains('allowlist:'));
      expect(yaml, contains("- '[0-9a-f]{40}'"));
      final reparsed = CliConfig.fromYaml(loadYaml(yaml) as YamlMap).redact!;
      expect(reparsed.layerToggles[RedactionLayer.pii], isTrue);
      expect(reparsed.allowlistRegexes.single.pattern, '[0-9a-f]{40}');
    });

    test('toYaml round-trips non-default values', () {
      const config = RedactionConfig(blockMode: true, toolDeny: {'write'});
      final yaml = CliConfig(redact: config).toYaml();
      expect(yaml, contains('redact:'));
      expect(yaml, contains('blockMode: true'));
      expect(yaml, contains('toolDeny:'));
      final reparsed = CliConfig.fromYaml(loadYaml(yaml) as YamlMap).redact;
      expect(reparsed, isNotNull);
      expect(reparsed!.blockMode, isTrue);
      expect(reparsed.toolDeny, {'write'});
      expect(reparsed.enabled, isTrue);
    });

    test('defaults are never written to yaml', () {
      final yaml = CliConfig(redact: const RedactionConfig()).toYaml();
      expect(yaml, isNot(contains('redact:')));
    });

    group('/redact command', () {
      test('disabled pipeline prints the enable hint', () {
        final outcome = handleRedactCommand(null, []);
        expect(outcome.lines.single, contains('redaction disabled'));
        expect(outcome.newConfig, isNull);
      });

      test('bare command prints status + usage', () {
        final outcome = handleRedactCommand(_pipelineWithSecret(), []);
        expect(outcome.lines.single, contains('redaction: on'));
        expect(outcome.lines.single, contains('blockMode: off'));
        expect(outcome.lines.single, contains('1 registered secret'));
        expect(outcome.lines.single, contains('usage:'));
      });

      test('on/off toggles enabled', () {
        final outcome = handleRedactCommand(_pipelineWithSecret(), ['off']);
        expect(outcome.lines.single, 'redaction disabled');
        expect(outcome.newConfig?.enabled, isFalse);
        // other fields preserved
        expect(outcome.newConfig?.blockMode, isFalse);
      });

      test('block on/off toggles blockMode, validates args', () {
        final on = handleRedactCommand(_pipelineWithSecret(), ['block', 'on']);
        expect(on.lines.single, 'blockMode on');
        expect(on.newConfig?.blockMode, isTrue);
        final bad = handleRedactCommand(_pipelineWithSecret(), ['block']);
        expect(bad.lines.single, contains('usage: /redact block'));
      });

      test('stats prints totals per layer and per tool', () {
        final pipeline = _pipelineWithSecret();
        redactPrompt(pipeline, 'token=supersecretvalue1');
        final outcome = handleRedactCommand(pipeline, ['stats']);
        expect(outcome.lines.first, contains('1 match'));
        expect(outcome.lines, contains('  registered: 1'));
        expect(outcome.lines, contains('  via user_input: 1'));
      });

      test('layers prints each layer toggle state', () {
        final outcome = handleRedactCommand(_pipelineWithSecret(), ['layers']);
        expect(outcome.lines.join('\n'), contains('  vendor: on'));
        expect(outcome.lines.join('\n'), contains('  pii: off'));
      });

      test('unknown subcommand prints usage', () {
        expect(
          handleRedactCommand(_pipelineWithSecret(), ['bogus']).lines.single,
          contains('usage:'),
        );
      });
    });

    test('buildRedactionPipeline: defaults, disabled → null', () {
      expect(buildRedactionPipeline(null), isNotNull);
      expect(
        buildRedactionPipeline(const RedactionConfig())?.config.enabled,
        isTrue,
      );
      expect(
        buildRedactionPipeline(const RedactionConfig(enabled: false)),
        isNull,
      );
    });
  });
}
