// UT-6 / AC6 (gh-1241): the I4 byte-scan — every written usage.json is
// clean of configured keys/secrets and of prompt-content substrings, and
// the violation report never echoes the secret back.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('assertUsageArtifactHygiene', () {
    test('a schema-shaped artifact passes', () {
      const artifact =
          '{"version":1,"sessionId":"sess-1","resumedCount":0,'
          '"segments":[],"total":{"requests":0,"input":0,"output":0,'
          '"cacheRead":0,"cacheWrite":0,"byModel":{},"source":"reported"},'
          '"chain":{"records":0,"hash":"sha256:abc"}}';
      expect(
        () => assertUsageArtifactHygiene(
          artifact,
          forbiddenSecrets: const ['sk-live-abc123'],
          forbiddenContent: const ['my secret prompt text'],
        ),
        returnsNormally,
      );
    });

    test('a configured secret anywhere in the artifact fails loudly', () {
      final artifact = '{"sessionId":"x","note":"key=sk-live-abc123"}';
      expect(
        () => assertUsageArtifactHygiene(
          artifact,
          forbiddenSecrets: const ['sk-live-abc123'],
        ),
        throwsA(
          isA<UsageHygieneException>()
              .having((e) => e.offset, 'offset', greaterThan(0))
              .having((e) => e.length, 'length', 14),
        ),
      );
    });

    test('prompt-content substrings fail the scan', () {
      const prompt = 'Please refactor the authentication module for me.';
      final artifact = '{"sessionId":"x","model":"$prompt"}';
      expect(
        () => assertUsageArtifactHygiene(
          artifact,
          forbiddenContent: const [prompt],
        ),
        throwsA(isA<UsageHygieneException>()),
      );
    });

    test('the violation report never echoes the offending text (I4)', () {
      const secret = 'sk-live-supersecretvalue';
      try {
        assertUsageArtifactHygiene(
          '{"sessionId":"x$secret"}',
          forbiddenSecrets: const [secret],
        );
        fail('expected UsageHygieneException');
      } on UsageHygieneException catch (e) {
        expect(e.toString(), isNot(contains(secret)));
        expect(e.toString(), contains('offset'));
      }
    });

    test('empty needles and very short content needles are ignored', () {
      expect(
        () => assertUsageArtifactHygiene(
          '{"sessionId":"x","model":"abc"}',
          forbiddenSecrets: const [''],
          forbiddenContent: const ['abc'],
        ),
        returnsNormally,
      );
    });
  });
}
