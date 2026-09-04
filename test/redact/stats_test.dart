import 'package:flutter_agent_harness/src/redact/redaction_pipeline.dart';
import 'package:test/test.dart';

void main() {
  group('RedactionStats', () {
    test('starts empty', () {
      final p = RedactionPipeline(registeredSecrets: const []);
      expect(p.stats.byLayer, isEmpty);
      expect(p.stats.byTool, isEmpty);
      expect(p.stats.total, 0);
    });

    test('byLayer and total count surviving matches per layer', () {
      const token = 'ghp_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';
      final p = RedactionPipeline(registeredSecrets: ['topsecretvalue']);
      p.redact('password: hunter2 tok $token sec topsecretvalue');
      expect(p.stats.byLayer['context'], 1);
      expect(p.stats.byLayer['vendor'], 1);
      expect(p.stats.byLayer['registered'], 1);
      expect(p.stats.total, 3);
    });

    test('idempotent re-redaction adds no counts', () {
      const token = 'ghp_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';
      final p = RedactionPipeline(registeredSecrets: const []);
      final once = p.redact('tok $token end');
      p.redact(once);
      expect(p.stats.byLayer['vendor'], 1);
      expect(p.stats.total, 1);
    });

    test('record() counts redaction events per tool', () {
      final p = RedactionPipeline(registeredSecrets: const []);
      p.stats
        ..record('bash')
        ..record('bash')
        ..record('read_file');
      expect(p.stats.byTool, {'bash': 2, 'read_file': 1});
      // record() counts tool events; match counters are untouched by it.
      expect(p.stats.total, 0);
      expect(p.stats.byLayer, isEmpty);
    });

    test('exposed maps are unmodifiable copies', () {
      final p = RedactionPipeline(registeredSecrets: const []);
      p.stats.record('bash');
      expect(() => p.stats.byTool['bash'] = 5, throwsUnsupportedError);
      expect(() => p.stats.byLayer['x'] = 1, throwsUnsupportedError);
      expect(p.stats.byTool['bash'], 1);
    });
  });
}
