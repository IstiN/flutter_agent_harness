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

  group('FanetAgentEnrollment.fromJson', () {
    test('parses all fields including note', () {
      final enrollment = FanetAgentEnrollment.fromJson(const {
        'name': 'ops-bot',
        'hubUrl': 'wss://hub.fa1.dev/ws',
        'clientSecret': 'sk_abc123',
        'enrolledAt': '2025-12-01T10:00:00Z',
        'note': 'store clientSecret now — never stored or returned again',
      });

      expect(enrollment.name, 'ops-bot');
      expect(enrollment.hubUrl, 'wss://hub.fa1.dev/ws');
      expect(enrollment.clientSecret, 'sk_abc123');
      expect(enrollment.enrolledAt, '2025-12-01T10:00:00Z');
      expect(
        enrollment.note,
        'store clientSecret now — never stored or returned again',
      );
    });

    test('tolerates a missing note and extra fields', () {
      final enrollment = FanetAgentEnrollment.fromJson(const {
        'name': 'ops-bot',
        'hubUrl': 'wss://hub.fa1.dev/ws',
        'clientSecret': 'sk_abc123',
        'enrolledAt': '2025-12-01T10:00:00Z',
        'scope': 'network',
        'rotated': false,
      });

      expect(enrollment.note, isNull);
    });

    test('rejects a missing required field', () {
      expect(
        () => FanetAgentEnrollment.fromJson(const {
          'name': 'ops-bot',
          'clientSecret': 'sk_abc123',
          'enrolledAt': '2025-12-01T10:00:00Z',
        }),
        throwsFormatException,
      );
    });

    test('rejects a non-string required field', () {
      expect(
        () => FanetAgentEnrollment.fromJson(const {
          'name': 'ops-bot',
          'hubUrl': 'wss://hub.fa1.dev/ws',
          'clientSecret': 42,
          'enrolledAt': '2025-12-01T10:00:00Z',
        }),
        throwsFormatException,
      );
    });
  });

  group('FanetAgentName.isValid', () {
    test('accepts valid names', () {
      expect(FanetAgentName.isValid('ops-bot'), isTrue);
      expect(FanetAgentName.isValid('abc'), isTrue);
      expect(FanetAgentName.isValid('a1-2-3'), isTrue);
      expect(FanetAgentName.isValid('007'), isTrue);
      // 64 chars total: ok.
      expect(FanetAgentName.isValid('a' * 64), isTrue);
      // Trailing hyphen is allowed by the server regex.
      expect(FanetAgentName.isValid('ab-'), isTrue);
    });

    test('rejects too short names (< 3 chars)', () {
      expect(FanetAgentName.isValid(''), isFalse);
      expect(FanetAgentName.isValid('a'), isFalse);
      expect(FanetAgentName.isValid('ab'), isFalse);
    });

    test('rejects too long names (65 chars)', () {
      expect(FanetAgentName.isValid('a' * 65), isFalse);
    });

    test('rejects uppercase', () {
      expect(FanetAgentName.isValid('Ops-Bot'), isFalse);
      expect(FanetAgentName.isValid('ABC'), isFalse);
    });

    test('rejects underscores and other symbols', () {
      expect(FanetAgentName.isValid('ops_bot'), isFalse);
      expect(FanetAgentName.isValid('ops.bot'), isFalse);
      expect(FanetAgentName.isValid('ops bot'), isFalse);
    });

    test('rejects a leading hyphen', () {
      expect(FanetAgentName.isValid('-ops-bot'), isFalse);
    });
  });
}
