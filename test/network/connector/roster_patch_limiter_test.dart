// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// `PATCH /api/devices/{id}/roster` limiter of the machine connector
/// (production eviction-storm hardening): every assertion runs on a fake
/// clock, so the per-device budget is a NUMBER here, never a wall-clock
/// wait. The roster REST client rides `package:http/testing` — no network.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/src/network/connector/device_api.dart';
import 'package:flutter_agent_harness/src/network/connector/rate_backoff.dart';
import 'package:flutter_agent_harness/src/network/connector/roster_patch_limiter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'fake_connector_time.dart';

/// One roster PATCH the fake server accepted, with its virtual timestamp.
typedef Patch = ({DateTime at, Map<String, Object?> body});

DeviceRosterAgent agent(String name, String state) =>
    DeviceRosterAgent(name: name, state: state, exposed: true);

DeviceRosterSession session(String id, String state) =>
    DeviceRosterSession(id: id, state: state, networks: const ['net-1']);

http.Response throttled({String? retryAfter}) => http.Response(
  jsonEncode({
    'error': {'code': 'throttled', 'message': 'too many roster patches'},
  }),
  429,
  headers: {'retry-after': ?retryAfter},
);

final _ok = http.Response('{"patched":"dev-1"}', 200);

/// A limiter over a fake clock and a recording fake roster endpoint.
final class Harness {
  Harness({http.Response Function(Patch)? respond, double Function()? jitter}) {
    client = DeviceEnrollmentClient(
      httpClient: MockClient((request) async {
        final patch = (
          at: clock.now(),
          body: jsonDecode(request.body) as Map<String, Object?>,
        );
        patches.add(patch);
        return respond?.call(patch) ?? _ok;
      }),
    );
    limiter = RosterPatchLimiter(
      baseUrl: 'https://network.fa1.dev',
      deviceId: 'dev-1',
      deviceToken: 'tok-1',
      client: client,
      jitterFraction: jitter,
      clock: clock,
      timers: timers,
    );
  }

  final clock = FakeConnectorClock();
  late final timers = FakeConnectorTimers(clock);
  final patches = <Patch>[];
  late final DeviceEnrollmentClient client;
  late final RosterPatchLimiter limiter;

  Duration gapBetween(int earlier, int later) =>
      patches[later].at.difference(patches[earlier].at);

  List<Map<String, Object?>> rows(String key) =>
      (patches.last.body[key] as List).cast<Map<String, Object?>>();
}

void main() {
  group('parseRetryAfter', () {
    final now = DateTime.utc(2026, 11, 24, 12, 0, 0);

    test('delta-seconds form', () {
      expect(parseRetryAfter('7', now: now), const Duration(seconds: 7));
      expect(parseRetryAfter('0', now: now), Duration.zero);
      expect(parseRetryAfter(' 120 ', now: now), const Duration(minutes: 2));
    });

    test('HTTP-date form resolves against now', () {
      expect(
        parseRetryAfter('Sun, 06 Nov 1994 08:49:37 GMT', now: now),
        isNull,
        reason: 'a date in the past is no wait, not a negative one',
      );
      expect(
        parseRetryAfter(
          'Tue, 24 Nov 2026 12:00:45 GMT',
          now: DateTime.utc(2026, 11, 24, 12, 0),
        ),
        const Duration(seconds: 45),
      );
    });

    test('garbage, negative and absurd hints', () {
      expect(parseRetryAfter(null, now: now), isNull);
      expect(parseRetryAfter('', now: now), isNull);
      expect(parseRetryAfter('soon', now: now), isNull);
      expect(parseRetryAfter('-5', now: now), isNull);
      expect(parseRetryAfter('1.5', now: now), isNull);
      expect(
        parseRetryAfter('999999999', now: now),
        retryAfterCeiling,
        reason: 'a hint past the ceiling clamps instead of stalling forever',
      );
    });
  });

  group('withEqualJitter', () {
    test('keeps the delay inside [50 %, 100 %] of the nominal', () {
      const nominal = Duration(seconds: 8);
      expect(withEqualJitter(nominal, 0), const Duration(seconds: 4));
      expect(withEqualJitter(nominal, 1), nominal);
      expect(withEqualJitter(nominal, 0.5), const Duration(seconds: 6));
      expect(withEqualJitter(nominal, 7), nominal, reason: 'clamped');
      expect(withEqualJitter(nominal, -1), const Duration(seconds: 4));
      expect(withEqualJitter(Duration.zero, 0.3), Duration.zero);
    });
  });

  test('throttle backoff doubles from the base and caps', () {
    expect(rosterThrottleBackoff(1, 1), rosterThrottleBackoffBase);
    expect(rosterThrottleBackoff(2, 1), const Duration(seconds: 10));
    expect(rosterThrottleBackoff(3, 1), const Duration(seconds: 20));
    expect(rosterThrottleBackoff(9, 1), rosterThrottleBackoffCap);
    expect(rosterThrottleBackoff(2, 0), const Duration(seconds: 5));
  });

  test('a burst coalesces under the budget: never two PATCHes closer than '
      'the minimum interval, latest state per key wins', () async {
    final h = Harness();
    h.limiter.enqueue(agents: [agent('alpha', 'live')]);
    await h.timers.elapse(rosterPatchDebounce);
    expect(h.patches, hasLength(1));
    expect(h.patches.single.at, h.clock.now());

    // 25 changes inside the next second: ONE debounced flush that waits
    // for the per-device budget instead of bursting.
    for (var i = 0; i < 25; i++) {
      h.limiter.enqueue(
        agents: [agent('alpha', i.isEven ? 'busy' : 'live')],
        sessions: [session('s-$i', 'live')],
      );
    }
    await h.timers.elapse(const Duration(seconds: 1));
    expect(
      h.patches,
      hasLength(1),
      reason: 'the second PATCH waits out the minimum interval',
    );
    await h.timers.elapse(rosterPatchMinInterval);
    expect(h.patches, hasLength(2));
    expect(h.gapBetween(0, 1), rosterPatchMinInterval);
    expect(h.patches.last.body['agents'], [
      {'name': 'alpha', 'state': 'busy', 'exposed': true},
    ]);
    expect(h.rows('sessions'), hasLength(25));
    h.limiter.close();
  });

  test('sustained churn stays inside ≤ 1 PATCH per minInterval (≤ 30/min, '
      'half the server budget)', () async {
    final h = Harness();
    addTearDown(h.limiter.close);
    // One change per 600 ms for a minute: every change clears the 500 ms
    // debounce, so each one asks for a flush — the budget paces them.
    for (var i = 0; i < 100; i++) {
      h.limiter.enqueue(agents: [agent('alpha', i.isEven ? 'busy' : 'live')]);
      await h.timers.elapse(const Duration(milliseconds: 600));
    }
    expect(h.patches.length, inInclusiveRange(28, 30));
    for (var i = 1; i < h.patches.length; i++) {
      expect(
        h.gapBetween(i - 1, i),
        greaterThanOrEqualTo(rosterPatchMinInterval),
      );
    }
    expect(h.rows('agents').single['state'], 'live');
  });

  test('multi-page catalogs spend one budget slot per page', () async {
    final h = Harness();
    addTearDown(h.limiter.close);
    h.limiter.enqueue(
      sessions: [
        for (var i = 0; i < 45; i++) session('s-$i', 'wake_on_dm'),
        session('s-live', 'live'),
      ],
    );
    await h.timers.elapse(rosterPatchDebounce);
    expect(h.patches, hasLength(1));
    expect(h.rows('sessions'), hasLength(40));
    await h.timers.elapse(const Duration(seconds: 1));
    expect(h.patches, hasLength(1), reason: 'page two also waits');
    await h.timers.elapse(rosterPatchMinInterval);
    expect(h.patches, hasLength(2));
    expect(h.rows('sessions'), hasLength(6));
    expect(h.rows('sessions').last['id'], 's-live');
    expect(h.gapBetween(0, 1), rosterPatchMinInterval);
  });

  test('an explicit flush right after a PATCH waits for the budget', () async {
    final h = Harness();
    addTearDown(h.limiter.close);
    h.limiter.enqueue(agents: [agent('alpha', 'live')]);
    await h.timers.elapse(rosterPatchDebounce);
    h.limiter.enqueue(agents: [agent('alpha', 'offline')]);
    var flushed = false;
    final flushing = h.limiter.flush().then((_) => flushed = true);
    await settleAsync();
    expect(flushed, isFalse, reason: 'the stop-path flush is rate limited');
    expect(h.patches, hasLength(1));
    await h.timers.elapse(rosterPatchMinInterval);
    await flushing;
    expect(h.patches, hasLength(2));
    expect(h.rows('agents').single['state'], 'offline');
  });

  test('429 without Retry-After backs off with jitter and the refused batch '
      'is merged with newer changes, never dropped', () async {
    var refusals = 2;
    final h = Harness(
      respond: (_) => refusals-- > 0 ? throttled() : _ok,
      jitter: () => 0, // equal jitter at 50 % → base/2
    );
    addTearDown(h.limiter.close);
    h.limiter.enqueue(agents: [agent('alpha', 'live')]);
    h.limiter.enqueue(sessions: [session('s-1', 'live')]);
    await h.timers.elapse(rosterPatchDebounce);
    expect(h.patches, hasLength(1));

    // First refusal: streak 1 → 5 s base halved by jitter = 2.5 s cooldown.
    h.limiter.enqueue(agents: [agent('alpha', 'busy')]);
    await h.limiter.flush(); // explicit flush inside the cooldown: no send
    expect(h.patches, hasLength(1), reason: 'Retry-After/backoff is honoured');
    await h.timers.elapse(const Duration(milliseconds: 2499));
    expect(h.patches, hasLength(1));
    await h.timers.elapse(const Duration(milliseconds: 1));
    expect(h.patches, hasLength(2));
    final retried = h.patches[1].body;
    expect(retried['agents'], [
      {'name': 'alpha', 'state': 'busy', 'exposed': true},
    ], reason: 'the newer busy state wins over the refused live state');
    expect(
      (retried['sessions'] as List).single['id'],
      's-1',
      reason: 'the refused session row rides along instead of being dropped',
    );
    expect(h.gapBetween(0, 1), const Duration(milliseconds: 2500));

    // Second refusal: streak 2 → 10 s halved = 5 s cooldown, and a success
    // afterwards resets the streak.
    await h.timers.elapse(const Duration(milliseconds: 4999));
    expect(h.patches, hasLength(2));
    await h.timers.elapse(const Duration(milliseconds: 1));
    expect(h.patches, hasLength(3));
    expect(h.gapBetween(1, 2), const Duration(seconds: 5));
    expect(h.rows('agents').single['state'], 'busy');

    h.limiter.enqueue(agents: [agent('alpha', 'offline')]);
    await h.timers.elapse(const Duration(seconds: 2));
    expect(h.patches, hasLength(4));
    expect(h.rows('agents').single['state'], 'offline');
    await h.timers.elapse(const Duration(seconds: 60));
    expect(h.patches, hasLength(4), reason: 'nothing left to resend');
  });

  test('429 with Retry-After is honoured verbatim', () async {
    var refused = true;
    final h = Harness(
      respond: (_) {
        if (refused) {
          refused = false;
          return throttled(retryAfter: '7');
        }
        return _ok;
      },
    );
    addTearDown(h.limiter.close);
    h.limiter.enqueue(agents: [agent('alpha', 'live')]);
    await h.timers.elapse(rosterPatchDebounce);
    expect(h.patches, hasLength(1));
    await h.timers.elapse(const Duration(seconds: 6, milliseconds: 999));
    expect(h.patches, hasLength(1));
    await h.timers.elapse(const Duration(milliseconds: 1));
    expect(h.patches, hasLength(2));
    expect(h.gapBetween(0, 1), const Duration(seconds: 7));
  });

  test('throttled error code on a non-429 status is still a throttle', () {
    final error = DeviceEnrollmentException(
      'rejected',
      statusCode: 503,
      errorCode: 'throttled',
    );
    expect(error.isThrottled, isTrue);
    expect(const DeviceEnrollmentException('x').isThrottled, isFalse);
    expect(
      const DeviceEnrollmentException('x', statusCode: 401).isThrottled,
      isFalse,
    );
    final throttled = DeviceEnrollmentThrottledException(
      'slow down',
      statusCode: 429,
      retryAfter: const Duration(seconds: 3),
    );
    expect(throttled, isA<DeviceEnrollmentException>());
    expect(throttled, isA<ConnectorThrottleSignal>());
    expect(throttled.retryAfter, const Duration(seconds: 3));
    expect(throttled.isThrottled, isTrue);
  });

  test('the REST client maps a 429 answer to the typed throttle exception '
      'carrying Retry-After and the OpenAPI code', () async {
    final client = DeviceEnrollmentClient(
      httpClient: MockClient((_) async => throttled(retryAfter: '9')),
    );
    await expectLater(
      client.patchRoster(
        baseUrl: 'https://network.fa1.dev',
        deviceId: 'dev-1',
        deviceToken: 'tok',
        agents: [agent('alpha', 'live')],
      ),
      throwsA(
        isA<DeviceEnrollmentThrottledException>()
            .having(
              (error) => error.retryAfter,
              'retryAfter',
              const Duration(seconds: 9),
            )
            .having((error) => error.errorCode, 'errorCode', 'throttled')
            .having((error) => error.statusCode, 'statusCode', 429),
      ),
    );
  });

  test('without a roster client the limiter is inert', () async {
    final h = Harness();
    final inert = RosterPatchLimiter(
      baseUrl: 'https://network.fa1.dev',
      deviceId: 'dev-1',
      deviceToken: 'tok-1',
      clock: h.clock,
      timers: h.timers,
    );
    expect(inert.isEnabled, isFalse);
    inert.enqueue(agents: [agent('alpha', 'live')]);
    await inert.flush();
    await h.timers.elapse(const Duration(minutes: 5));
    expect(h.patches, isEmpty);
    expect(h.timers.pending, isEmpty);
    inert.close();
  });

  test('close() cancels the pending debounce and throttle retries', () async {
    final h = Harness(respond: (_) => throttled(retryAfter: '30'));
    h.limiter.enqueue(agents: [agent('alpha', 'live')]);
    await h.timers.elapse(rosterPatchDebounce);
    expect(h.patches, hasLength(1));
    expect(h.timers.pending, hasLength(1), reason: 'throttle retry armed');
    h.limiter.enqueue(agents: [agent('beta', 'live')]);
    h.limiter.close();
    expect(h.timers.pending, isEmpty);
    await h.timers.elapse(const Duration(minutes: 5));
    expect(h.patches, hasLength(1));
  });
}
