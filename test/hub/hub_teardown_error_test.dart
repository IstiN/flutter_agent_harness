import 'package:flutter_agent_harness/src/hub/hub_teardown_error.dart';
import 'package:test/test.dart';

void main() {
  group('isHubConnectionTeardown', () {
    test('matches the fa_hub_client teardown marker', () {
      expect(isHubConnectionTeardown(StateError('connection closed')), isTrue);
    });

    test('rejects other StateError messages — real bugs stay fatal', () {
      expect(isHubConnectionTeardown(StateError('no element')), isFalse);
      expect(isHubConnectionTeardown(StateError('')), isFalse);
    });

    test('rejects other error types with the same text', () {
      expect(isHubConnectionTeardown(Exception('connection closed')), isFalse);
      expect(isHubConnectionTeardown('connection closed'), isFalse);
      expect(
        isHubConnectionTeardown(ArgumentError('connection closed')),
        isFalse,
      );
    });
  });
}
