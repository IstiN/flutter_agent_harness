import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('sharedProviderHttpClient', () {
    test('returns one shared keep-alive instance (no per-call churn)', () {
      // A fresh client per request churns TCP connections into TIME_WAIT
      // pileups on tool-heavy runs; the shared one must be stable.
      expect(
        identical(sharedProviderHttpClient(), sharedProviderHttpClient()),
        isTrue,
      );
    });
  });
}
