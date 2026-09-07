import 'package:flutter_agent_harness/src/js_ext/trust.dart';
import 'package:test/test.dart';

TrustRecord _record({
  ExtTrustSource source = ExtTrustSource.github,
  String sourceRef = 'owner/repo@abc123',
  DateTime? grantedAt,
  Map<String, dynamic>? capabilities,
}) => TrustRecord(
  source: source,
  sourceRef: sourceRef,
  contentSha256: 'deadbeef',
  capabilities:
      capabilities ??
      const {
        'network': true,
        'allowedCommands': ['dart'],
      },
  grantedAt: grantedAt ?? DateTime.utc(2026, 9, 6, 12, 30),
);

void main() {
  group('TrustRecord', () {
    test('toJson emits UTC ISO timestamps', () {
      final json = _record().toJson();
      expect(json['source'], 'github');
      expect(json['sourceRef'], 'owner/repo@abc123');
      expect(json['contentSha256'], 'deadbeef');
      expect(json['grantedAt'], '2026-09-06T12:30:00.000Z');
    });

    test('fromJson/toJson round-trip preserves UTC instant', () {
      final back = TrustRecord.fromJson(_record().toJson());
      expect(back.source, ExtTrustSource.github);
      expect(back.sourceRef, 'owner/repo@abc123');
      expect(back.contentSha256, 'deadbeef');
      expect(back.capabilities, _record().capabilities);
      expect(back.grantedAt.isUtc, isTrue);
      expect(back.grantedAt, DateTime.utc(2026, 9, 6, 12, 30));
      expect(back, _record());
    });

    test('fromJson converts local timestamps to UTC', () {
      final back = TrustRecord.fromJson({
        ..._record().toJson(),
        'grantedAt': '2026-09-06T15:30:00.000+03:00',
      });
      expect(back.grantedAt.isUtc, isTrue);
      expect(back.grantedAt, DateTime.utc(2026, 9, 6, 12, 30));
    });

    test('fromJson rejects bad fields', () {
      expect(
        () => TrustRecord.fromJson({'source': 'carrier', 'sourceRef': 'x'}),
        throwsFormatException,
      );
      expect(() => TrustRecord.fromJson(const {}), throwsFormatException);
    });

    test('equality on (source, sourceRef, contentSha256, capabilities)', () {
      expect(_record(), _record());
      expect(
        _record(),
        _record(grantedAt: DateTime.utc(2000, 1, 1)),
        reason: 'grantedAt excluded from equality',
      );
      expect(_record(capabilities: const {'network': false}), isNot(_record()));
      expect(_record(sourceRef: 'other@x'), isNot(_record()));
      expect(
        _record(capabilities: const {'b': 2, 'a': 1}),
        _record(capabilities: const {'a': 1, 'b': 2}),
        reason: 'capability map order ignored',
      );
    });
  });

  group('extCapabilitiesEqual', () {
    test('equal maps with different key order', () {
      expect(
        extCapabilitiesEqual(
          const {
            'network': true,
            'exec': {
              'allowedCommands': ['dart', 'git'],
            },
          },
          const {
            'exec': {
              'allowedCommands': ['dart', 'git'],
            },
            'network': true,
          },
        ),
        isTrue,
      );
    });

    test('nested value differences are detected', () {
      expect(
        extCapabilitiesEqual(
          const {
            'exec': {
              'allowedCommands': ['dart'],
            },
          },
          const {
            'exec': {
              'allowedCommands': ['git'],
            },
          },
        ),
        isFalse,
      );
      expect(
        extCapabilitiesEqual(
          const {
            'a': {'b': 1},
          },
          const {
            'a': {'b': 2},
          },
        ),
        isFalse,
      );
      expect(extCapabilitiesEqual(const {'a': 1}, const {'b': 1}), isFalse);
      expect(extCapabilitiesEqual(const {'a': 1}, const {}), isFalse);
      expect(extCapabilitiesEqual(const {}, const {}), isTrue);
    });

    test('list element order is significant', () {
      expect(
        extCapabilitiesEqual(
          const {
            'hooks': ['a', 'b'],
          },
          const {
            'hooks': ['b', 'a'],
          },
        ),
        isFalse,
      );
      expect(
        extCapabilitiesEqual(
          const {
            'hooks': ['a', 'b'],
          },
          const {
            'hooks': ['a', 'b'],
          },
        ),
        isTrue,
      );
    });
  });

  group('ExtTrustRequest.humanSummary', () {
    test('one line per capability', () {
      final request = ExtTrustRequest(
        name: 'crap-guard',
        source: ExtTrustSource.bundled,
        sourceRef: 'bundled',
        contentSha256: 'deadbeef',
        capabilities: const {
          'allowedCommands': ['dart pub global run crap4dart analyze'],
          'fs': true,
          'hooks': ['afterToolCall', 'onSessionEnd'],
          'network': true,
          'keys': true,
          'tools': true,
          'menus': true,
        },
      );
      expect(request.humanSummary(), [
        'exec: run only: dart pub global run crap4dart analyze',
        'fs: read project files',
        'hooks: afterToolCall, onSessionEnd',
        'network: make network requests',
        'keys: request access to stored keys by name',
        'tools: register agent tools',
        'menus: register provider flows',
      ]);
    });

    test('omits undeclared capabilities', () {
      final request = ExtTrustRequest(
        name: 'minimal',
        source: ExtTrustSource.local,
        sourceRef: '/tmp/ext',
        contentSha256: 'cafe',
        capabilities: const {'tools': true},
      );
      expect(request.humanSummary(), ['tools: register agent tools']);
    });

    test('no capabilities => empty summary', () {
      final request = ExtTrustRequest(
        name: 'none',
        source: ExtTrustSource.catalog,
        sourceRef: 'c1',
        contentSha256: 'beef',
        capabilities: const {},
      );
      expect(request.humanSummary(), isEmpty);
    });
  });
}
