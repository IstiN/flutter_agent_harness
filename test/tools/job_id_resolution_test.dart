import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('parseShellJobIdParts', () {
    test('parses the minted sh-<n>-<tail> shape', () {
      final parts = parseShellJobIdParts('sh-7-1abc2d3xy9z');
      expect(parts, isNotNull);
      expect(parts!.n, 7);
      expect(parts.tail, '1abc2d3xy9z');
    });

    test('sh-99 (the old short scheme) has no tail part', () {
      expect(parseShellJobIdParts('sh-99'), isNull);
    });

    test('rejects non-numeric n, foreign prefixes and empty tails', () {
      expect(parseShellJobIdParts('sh-abc-def'), isNull);
      expect(parseShellJobIdParts('job-1-abc'), isNull);
      expect(parseShellJobIdParts('sh-7-'), isNull);
      expect(parseShellJobIdParts('sh--abc'), isNull);
      expect(parseShellJobIdParts(''), isNull);
    });
  });

  group('shellJobIdCloseness', () {
    test('identical ids score 0', () {
      expect(shellJobIdCloseness('sh-7-abc', 'sh-7-abc'), 0);
    });

    test('same numeric part always beats a different numeric part', () {
      const requested = 'sh-7-aaaa1111bbbb';
      expect(
        shellJobIdCloseness(requested, 'sh-7-zzzz9999yyyy'),
        lessThan(shellJobIdCloseness(requested, 'sh-8-aaaa1111bbbb')),
      );
    });

    test('among same-n ids a more similar tail is closer', () {
      const requested = 'sh-7-aaaa';
      expect(
        shellJobIdCloseness(requested, 'sh-7-aaab'),
        lessThan(shellJobIdCloseness(requested, 'sh-7-zzzz')),
      );
    });
  });

  group('closestShellJobIds', () {
    const ids = [
      'sh-2-dd',
      'sh-1-aaaa',
      'sh-1-bbbb',
      'sh-3-eeee',
      'sh-1-cccc',
    ];

    test('same numeric part first, ties broken by id', () {
      expect(closestShellJobIds('sh-1-wrongtail', ids), [
        'sh-1-aaaa',
        'sh-1-bbbb',
        'sh-1-cccc',
      ]);
    });

    test('caps at the limit (default 3)', () {
      expect(closestShellJobIds('sh-9-nomatch', ids), hasLength(3));
    });

    test('honors an explicit smaller limit', () {
      expect(closestShellJobIds('sh-9-nomatch', ids, limit: 2), hasLength(2));
    });

    test('falls back to global closeness when no id shares the n', () {
      expect(closestShellJobIds('sh-2-ddxx', ids, limit: 1), ['sh-2-dd']);
    });

    test('empty candidates give an empty result', () {
      expect(closestShellJobIds('sh-1-x', const <String>[]), isEmpty);
    });
  });

  group('matchShellJobId', () {
    test('exactly one retained id sharing the n resolves uniquely', () {
      final match = matchShellJobId('sh-1-stale', ['sh-2-b', 'sh-1-real']);
      expect(match, isA<ShellJobIdUnique>());
      expect((match as ShellJobIdUnique).id, 'sh-1-real');
    });

    test('an exact retained match resolves to itself', () {
      final match = matchShellJobId('sh-1-real', ['sh-1-real', 'sh-2-b']);
      expect(match, isA<ShellJobIdUnique>());
      expect((match as ShellJobIdUnique).id, 'sh-1-real');
    });

    test('two retained ids sharing the n stay ambiguous (E1)', () {
      final match = matchShellJobId('sh-1-stale', [
        'sh-1-aaa',
        'sh-2-b',
        'sh-1-bbb',
      ]);
      expect(match, isA<ShellJobIdAmbiguous>());
      expect((match as ShellJobIdAmbiguous).ids, ['sh-1-aaa', 'sh-1-bbb']);
    });

    test('ambiguous listings stay bounded at 3', () {
      final match = matchShellJobId('sh-1-stale', [
        'sh-1-a',
        'sh-1-b',
        'sh-1-c',
        'sh-1-d',
      ]);
      expect((match as ShellJobIdAmbiguous).ids, hasLength(3));
    });

    test('no shared n lists the closest retained ids (AC2)', () {
      final match = matchShellJobId('sh-9-nope', ['sh-1-a', 'sh-2-b']);
      expect(match, isA<ShellJobIdNoMatch>());
      expect((match as ShellJobIdNoMatch).closest, ['sh-1-a', 'sh-2-b']);
    });

    test('a malformed id skips resolution entirely (E3)', () {
      final match = matchShellJobId('sh-99', ['sh-1-a', 'sh-2-b']);
      expect(match, isA<ShellJobIdNoMatch>());
      expect((match as ShellJobIdNoMatch).closest, isEmpty);
    });

    test('a malformed id never resolves even when n coincides', () {
      // `sh-1` has no tail: reconstructing ids from memory always keeps a
      // (wrong) suffix, so a bare `sh-<n>` is treated as unshaped.
      final match = matchShellJobId('sh-1', ['sh-1-aaa']);
      expect(match, isA<ShellJobIdNoMatch>());
      expect((match as ShellJobIdNoMatch).closest, isEmpty);
    });
  });

  group('shellJobSettledAgo', () {
    test('buckets seconds, minutes, hours and days', () {
      expect(shellJobSettledAgo(const Duration(milliseconds: 200)), 'just now');
      expect(shellJobSettledAgo(const Duration(seconds: 45)), '45s ago');
      expect(shellJobSettledAgo(const Duration(seconds: 90)), '1m ago');
      expect(shellJobSettledAgo(const Duration(minutes: 125)), '2h ago');
      expect(shellJobSettledAgo(const Duration(hours: 50)), '2d ago');
    });
  });
}
