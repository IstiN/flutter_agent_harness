/// Tests for fa_network REST payload models.
library;

import 'package:flutter_agent_harness/src/fanet/fanet_models.dart';
import 'package:test/test.dart';

void main() {
  group('FanetJoinResult.fromJson', () {
    test('parses sessionToken and ignores extra fields', () {
      final result = FanetJoinResult.fromJson(const {
        'sessionToken': 'tok-abc',
        'network': {'id': 'net-1', 'name': 'Demo'},
        'member': {'id': 'm-1'},
        'role': 'member',
      });

      expect(result.sessionToken, 'tok-abc');
    });

    test('rejects a missing sessionToken', () {
      expect(
        () => FanetJoinResult.fromJson(const {'role': 'member'}),
        throwsFormatException,
      );
    });

    test('rejects a non-string sessionToken', () {
      expect(
        () => FanetJoinResult.fromJson(const {'sessionToken': 42}),
        throwsFormatException,
      );
    });
  });

  group('FanetDapSession.fromJson', () {
    test('parses all fields including env', () {
      final session = FanetDapSession.fromJson(const {
        'dapUrl': 'wss://dap.fa1.dev/ws',
        'agentName': 'agent-7',
        'clientSecret': 'sec-9',
        'env': {
          'FA_AGENT_NAME': 'agent-7',
          'FA_DAP_URL': 'wss://dap.fa1.dev/ws',
        },
      });

      expect(session.dapUrl, 'wss://dap.fa1.dev/ws');
      expect(session.agentName, 'agent-7');
      expect(session.clientSecret, 'sec-9');
      expect(session.env, {
        'FA_AGENT_NAME': 'agent-7',
        'FA_DAP_URL': 'wss://dap.fa1.dev/ws',
      });
    });

    test('tolerates a missing env and extra fields', () {
      final session = FanetDapSession.fromJson(const {
        'dapUrl': 'wss://dap.fa1.dev/ws',
        'agentName': 'agent-7',
        'clientSecret': 'sec-9',
        'expiresAt': '2030-01-01T00:00:00Z',
        'scope': 'network',
      });

      expect(session.env, isNull);
    });

    test('rejects a missing required field', () {
      expect(
        () => FanetDapSession.fromJson(const {
          'agentName': 'agent-7',
          'clientSecret': 'sec-9',
        }),
        throwsFormatException,
      );
    });

    test('rejects a non-map env', () {
      expect(
        () => FanetDapSession.fromJson(const {
          'dapUrl': 'wss://dap.fa1.dev/ws',
          'agentName': 'agent-7',
          'clientSecret': 'sec-9',
          'env': 'not-a-map',
        }),
        throwsFormatException,
      );
    });
  });
}
