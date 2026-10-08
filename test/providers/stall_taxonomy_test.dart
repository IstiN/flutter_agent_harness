// Stall taxonomy (gh-1395): "name the stall" — the alive-but-silence kinds
// the empirical refutation table (issue body) pins down:
//
// - connect stall: headers NEVER arrive (connect watchdog, B3);
// - first-byte stall: headers arrived, zero SSE events decoded, socket open
//   (headers-then-silence, B1 pre-event);
// - mid-stream idle stall: at least one event decoded, then silence (B1
//   post-event — the bench's >5-min generation gap).
//
// The producer wordings are the watchdogs' own error texts; the classifier
// matches TAGS, never ad-hoc substrings (the connectWatchdogTag discipline).
import 'package:flutter_agent_harness/src/providers/stall_taxonomy.dart';
import 'package:flutter_agent_harness/src/providers/transient_retry_stream.dart';
import 'package:test/test.dart';

void main() {
  group('classifyProviderStall', () {
    test('connect-watchdog wording classifies as connectStall (E1)', () {
      final stall = classifyProviderStall(
        'TimeoutException: provider stream request to '
        'https://gw.test/v1/chat timed out: no response headers within '
        '180s $connectWatchdogTag',
      );
      expect(stall, isNotNull);
      expect(stall!.kind, ProviderStallKind.connectStall);
      expect(stall.eventsSeen, isNull);
    });

    test('idle-watchdog wording with zero events = firstByteStall', () {
      final stall = classifyProviderStall(
        'TimeoutException: no events from the endpoint for 300s '
        '(stream idle timeout)',
      );
      expect(stall, isNotNull);
      expect(stall!.kind, ProviderStallKind.firstByteStall);
    });

    test(
      'idle-watchdog wording after observed events = midStreamIdleStall',
      () {
        final stall = classifyProviderStall(
          'TimeoutException: no events from the endpoint for 300s '
          '(stream idle timeout)',
          eventsSeen: 4,
        );
        expect(stall, isNotNull);
        expect(stall!.kind, ProviderStallKind.midStreamIdleStall);
      },
    );

    test(
      'non-stall failures classify to null (distinct policy entries, E1)',
      () {
        // Transport (Wi-Fi drop) and 5xx classes belong to the existing
        // ladders — never to the stall policy.
        for (final text in [
          'ClientException: Connection reset by peer',
          '500: Internal network failure, please try again later',
          '429: rate limit exceeded',
          null,
          '',
        ]) {
          expect(classifyProviderStall(text), isNull, reason: '$text');
        }
      },
    );

    test('the codex bypass idle wording classifies too (same idle tag)', () {
      final stall = classifyProviderStall(
        'chatgpt-codex https://gw.test/v1/responses stalled: no SSE bytes '
        'for 300s (stream idle timeout)',
        eventsSeen: 1,
      );
      expect(stall, isNotNull);
      expect(stall!.kind, ProviderStallKind.midStreamIdleStall);
    });

    test('isProviderStallError matches only the stall family', () {
      expect(
        isProviderStallError(
          'TimeoutException: no events from the endpoint for 5s '
          '(stream idle timeout)',
        ),
        isTrue,
      );
      expect(
        isProviderStallError(
          'TimeoutException: provider stream request to '
          'https://gw.test timed out: no response headers within 180s '
          '(connect watchdog)',
        ),
        isTrue,
      );
      expect(isProviderStallError('Connection reset by peer'), isFalse);
    });
  });

  group('stall event record', () {
    test('carries the named kind, idle seconds, events seen, and message', () {
      final stall = classifyProviderStall(
        'TimeoutException: no events from the endpoint for 300s '
        '(stream idle timeout)',
        eventsSeen: 2,
      );
      expect(stall, isNotNull);
      expect(stall!.kind, ProviderStallKind.midStreamIdleStall);
      expect(stall.idleSeconds, 300);
      expect(stall.eventsSeen, 2);
      expect(stall.message, contains('(stream idle timeout)'));
    });

    test('the idle tag constant pins producer and consumers together', () {
      // The idle watchdogs (provider_common createSseIterator +
      // chatgpt_codex bypass) build their errors with this wording; the
      // taxonomy matches the CONSTANT so a rewording cannot silently drop
      // the stall class (connectWatchdogTag discipline, issue #1121 r1).
      expect(idleStreamStallTag, '(stream idle timeout)');
      expect(
        'no events from the endpoint for 300s (stream idle timeout)'.contains(
          idleStreamStallTag,
        ),
        isTrue,
      );
    });

    test('labels + toString: the three kinds render their trace names and '
        'the optional idle/event counters', () {
      expect(
        const ProviderStallEvent(
          kind: ProviderStallKind.connectStall,
          message: 'connect timed out',
        ).label,
        'connect stall',
      );
      expect(
        const ProviderStallEvent(
          kind: ProviderStallKind.firstByteStall,
          message: '(stream idle timeout)',
        ).label,
        'first-byte stall',
      );
      expect(
        const ProviderStallEvent(
          kind: ProviderStallKind.midStreamIdleStall,
          message: '(stream idle timeout)',
          idleSeconds: 300,
          eventsSeen: 41,
        ).label,
        'mid-stream idle stall',
      );
      expect(
        const ProviderStallEvent(
          kind: ProviderStallKind.midStreamIdleStall,
          message: '(stream idle timeout)',
          idleSeconds: 300,
          eventsSeen: 41,
        ).toString(),
        'ProviderStallEvent(mid-stream idle stall, idle 300s, 41 events)',
      );
      expect(
        const ProviderStallEvent(
          kind: ProviderStallKind.firstByteStall,
          message: '(stream idle timeout)',
        ).toString(),
        'ProviderStallEvent(first-byte stall)',
        reason: 'no counters → no suffixes',
      );
    });
  });
}
