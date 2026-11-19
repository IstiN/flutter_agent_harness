// Issue #1916: payload-aware stall handling — the window scale, the
// outbound-size estimate, the once-per-payload advice latch, the
// late-answer adoption in the connect-stall retry loop, and the
// payload-scaled run-idle window. All synthetic: no real network.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/providers/payload_stall.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  group('payload stall window scale (#1916 AC3)', () {
    test('text-sized payloads keep windows byte-for-byte', () {
      expect(payloadStallScaleFor(0), 1.0);
      expect(payloadStallScaleFor(payloadStallFreeBytes), 1.0);
      expect(
        scaleStallWindowForPayload(const Duration(seconds: 120), 500 * 1024),
        const Duration(seconds: 120),
      );
    });

    test('the scale rises linearly and caps at 2x', () {
      expect(payloadStallScaleFor(8 * 1024 * 1024), closeTo(1.47, 0.01));
      expect(payloadStallScaleFor(16 * 1024 * 1024), 2.0);
      expect(
        payloadStallScaleFor(100 * 1024 * 1024),
        2.0,
        reason: 'genuine hangs stay bounded',
      );
      expect(
        scaleStallWindowForPayload(const Duration(seconds: 120), 1 << 30),
        const Duration(seconds: 240),
      );
    });

    test('the estimate counts text and image payloads, skips tool args', () {
      final bytes = estimateOutboundBytes([
        UserMessage(
          content: [
            const TextContent(text: 'hello'), // 5
            ImageContent(data: 'Q' * 100, mimeType: 'image/png'), // 100
          ],
          timestamp: DateTime.utc(2026),
        ),
        AssistantMessage(
          content: [
            const TextContent(text: 'hi'), // 2
            const ThinkingContent(thinking: 'hmm'), // 3
          ],
          api: 'a',
          provider: 'p',
          model: 'm',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        ),
        ToolResultMessage(
          toolCallId: 'c1',
          toolName: 'snap',
          content: [
            ImageContent(data: 'R' * 50, mimeType: 'image/png'), // 50
          ],
          isError: false,
          timestamp: DateTime.utc(2026),
        ),
      ]);
      expect(bytes, 5 + 100 + 2 + 3 + 50);
    });

    test('the estimate counts video payloads (gh-2007 thread 3)', () {
      // gh-1985 funnels videos through rewriteRequestImages, which
      // publishes this estimate; a VideoContent block must add its
      // base64 length or the run-idle watchdog arms on a wrong payload
      // picture for exactly the requests most likely to stall.
      final bytes = estimateOutboundBytes([
        UserMessage(
          content: [
            const TextContent(text: 'hello'), // 5
            VideoContent(data: 'V' * 4096, mimeType: 'video/mp4'),
          ],
          timestamp: DateTime.utc(2026),
        ),
        ToolResultMessage(
          toolCallId: 'c1',
          toolName: 'read',
          content: [VideoContent(data: 'V' * 512, mimeType: 'video/webm')],
          isError: false,
          timestamp: DateTime.utc(2026),
        ),
      ]);
      expect(bytes, 5 + 4096 + 512);
    });
  });

  group('payload stall latch (#1916 AC3: ONE advice, not endless retries)', () {
    final advices = <(int, String)>[];
    setUp(() => advices.clear());
    tearDown(() {
      payloadStallLatch.reset();
    });

    test('two consecutive stalls of one payload fire exactly one advice', () {
      const fp0 = 'https://x|1000';
      payloadStallAdvice = (bytes, fingerprint) => advices.add((bytes, fp0));
      payloadStallLatch.noteStall(fp0, 1000);
      expect(advices, isEmpty, reason: 'one stall may be a blip');
      payloadStallLatch.noteStall(fp0, 1000);
      expect(advices, hasLength(1));
      expect(advices.single.$1, 1000);
      // A third, fourth… identical stall stays silent.
      payloadStallLatch.noteStall(fp0, 1000);
      payloadStallLatch.noteStall(fp0, 1000);
      expect(advices, hasLength(1));
    });

    test('a different payload resets the streak and re-arms the advice', () {
      payloadStallAdvice = (bytes, fingerprint) => advices.add((bytes, ''));
      payloadStallLatch.noteStall('https://x|1000', 1000);
      payloadStallLatch.noteStall('https://x|1000', 1000);
      expect(advices, hasLength(1));
      payloadStallLatch.noteStall('https://x|2000', 2000);
      expect(advices, hasLength(1), reason: 'first stall of a new payload');
      payloadStallLatch.noteStall('https://x|2000', 2000);
      expect(advices, hasLength(2));
      expect(advices.last.$1, 2000);
    });

    test('reset clears the latch (new run starts fresh)', () {
      payloadStallAdvice = (bytes, fingerprint) => advices.add((bytes, ''));
      payloadStallLatch.noteStall('fp', 1);
      payloadStallLatch.reset();
      payloadStallLatch.noteStall('fp', 1);
      expect(advices, isEmpty);
    });
  });

  // Issue #2324 determinization: every late arrival in this group is
  // event-driven (a reaction to the stall notice or to the retry send),
  // never a blind `Future.delayed` racing the watchdog on wall-clock
  // margins — under runner load those margins invert (the CI red was
  // the answer winning the happy path, red'ing on the missing adoption
  // notice). The real 20ms watchdog / 50ms backoff stay: only the
  // ORDERING is pinned by construction now.
  group('late-answer adoption in the connect-stall retry loop (#1916 AC3)', () {
    final savedSleeper = transientRetrySleeper;
    final savedNotice = transientRetryNotice;
    final savedBackoff = providerConnectRetryBackoff;

    setUp(() {
      providerTimeoutsOverride = const ProviderTimeoutsOverride(
        connect: Duration(milliseconds: 20),
      );
      providerConnectRetryBackoff = const Duration(milliseconds: 50);
      payloadStallLatch.reset();
    });
    tearDown(() {
      providerTimeoutsOverride = null;
      transientRetrySleeper = savedSleeper;
      transientRetryNotice = savedNotice;
      providerConnectRetryBackoff = savedBackoff;
      payloadStallAdvice = null;
      payloadStallLatch.reset();
    });

    http.Request post() =>
        http.Request(
            'POST',
            Uri.parse('https://api.example.com/v1/chat/completions'),
          )
          ..headers['content-type'] = 'application/json'
          ..body = '{"model":"m","stream":true}';

    test('an abandoned attempt answering during the backoff is ADOPTED — '
        'the identical payload is never re-uploaded', () async {
      final notices = <String>[];
      // Issue #2324: the old script fired the answer at a blind 30ms — a
      // 10ms wall-clock margin over the 20ms watchdog that inverts under
      // runner load (the answer took the happy path, nothing adopted,
      // and this assertion red on the missing notice). The answer is now
      // a REACTION to the stall notice: the watchdog abandons the attempt
      // first BY CONSTRUCTION and the generation completes inside the
      // adoption gap via microtasks — no wall-clock ordering to lose.
      final lateAnswer = Completer<http.StreamedResponse>();
      transientRetryNotice = (a, m, d, r) {
        notices.add(r);
        if (r.contains('connect stall: no response bytes')) {
          lateAnswer.complete(
            http.StreamedResponse(
              Stream.value(utf8.encode('')),
              200,
              headers: {'content-type': 'text/event-stream'},
            ),
          );
        }
      };
      final sent = <int>[];
      final client = _ScriptedClient((count) {
        sent.add(count);
        if (count == 1) return lateAnswer.future;
        return Future.value(
          http.StreamedResponse(
            Stream.value(utf8.encode('')),
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        );
      });

      final response = await sendWatchedProviderRequest(client, post(), null);
      expect(response.statusCode, 200);
      expect(
        sent,
        hasLength(1),
        reason: 'the late generation was adopted — no retry POST',
      );
      expect(
        notices.where((n) => n.contains('adopting the late response')),
        hasLength(1),
      );
      expect(
        notices.where((n) => n.contains('response detached')),
        isEmpty,
        reason: 'single ownership: adopted means never detached',
      );
    });

    test('a late answer after the adoption window is still detached', () async {
      final notices = <String>[];
      transientRetryNotice = (a, m, d, r) => notices.add(r);
      // Issue #2324: the old script fired the answer at a blind 100ms,
      // racing the 20ms-watchdog + 50ms-backoff schedule that widens
      // under load (a widened window ADOPTED the answer instead). The
      // answer now completes exactly when the retry send goes out — the
      // window is provably closed then (the sleeper won the race), so
      // detachment is the only reachable outcome, on any clock.
      final detached = Completer<void>();
      final body = StreamController<List<int>>(onListen: detached.complete);
      final lateAnswer = Completer<http.StreamedResponse>();
      final client = _ScriptedClient((count) {
        if (count == 2) {
          lateAnswer.complete(
            http.StreamedResponse(
              body.stream,
              200,
              headers: {'content-type': 'text/event-stream'},
            ),
          );
        }
        if (count == 1) return lateAnswer.future;
        return Future.value(
          http.StreamedResponse(
            Stream.value(utf8.encode('')),
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        );
      });

      final response = await sendWatchedProviderRequest(client, post(), null);
      expect(response.statusCode, 200);
      await detached.future;
      expect(
        notices.where((n) => n.contains('response detached')),
        hasLength(1),
      );
      expect(
        notices.where((n) => n.contains('adopting the late response')),
        isEmpty,
      );
    });

    test('repeated stalls of the same payload fire ONE advice with the '
        'payload size (#1916 AC3)', () async {
      final notices = <String>[];
      transientRetryNotice = (a, m, d, r) => notices.add(r);
      final advices = <int>[];
      payloadStallAdvice = (bytes, fingerprint) => advices.add(bytes);
      // Every attempt stalls: the connect budget (2 retries / 3 attempts)
      // exhausts and the call fails — but the latch fired on the SECOND
      // stall and stays quiet after. This IS the livelock shape, bounded.
      final client = _ScriptedClient(
        (count) => Completer<http.StreamedResponse>().future,
      );

      await expectLater(
        sendWatchedProviderRequest(client, post(), null),
        throwsA(isA<TimeoutException>()),
      );
      expect(advices, hasLength(1));
      expect(advices.single, post().bodyBytes.length);
      expect(
        payloadStallAdviceLine(advices.single),
        allOf(
          contains('/compact'),
          contains('images.maxBytesPerRequest'),
          contains('/restart'),
        ),
        reason: 'the advice names the whole escape ladder (AC4)',
      );
    });

    test('a late ERROR from an abandoned attempt is classified and '
        'detached — never the turn verdict (review r1 blocking)', () async {
      final notices = <String>[];
      // Issue #2324: the old script fired the error at a blind 30ms (a
      // 10ms margin over the watchdog; an inversion made the error the
      // call's verdict). The error now completes as a REACTION to the
      // stall notice — the race consumes it within microtasks of arming,
      // the classified-and-detached path is the only reachable outcome,
      // and the retry still re-sends.
      final lateError = Completer<http.StreamedResponse>();
      transientRetryNotice = (a, m, d, r) {
        notices.add(r);
        if (r.contains('connect stall: no response bytes')) {
          lateError.completeError(
            http.ClientException('socket closed mid-handshake'),
          );
        }
      };
      final client = _ScriptedClient((count) {
        if (count == 1) return lateError.future;
        return Future.value(
          http.StreamedResponse(
            Stream.value(utf8.encode('')),
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        );
      });

      final response = await sendWatchedProviderRequest(client, post(), null);
      expect(
        response.statusCode,
        200,
        reason: 'the retry answered — the late error never surfaced',
      );
      expect(client.sent, hasLength(2), reason: 'the retry went out');
      expect(
        notices.where(
          (n) => n.contains('failed late') && n.contains('error detached'),
        ),
        hasLength(1),
      );
    });

    test('a late error AFTER the adoption window is announced by the '
        'janitor, not propagated', () async {
      final notices = <String>[];
      // Issue #2324: the error used to fire at a blind 100ms and the test
      // then waited a wall-clock 80ms for the janitor. The error now
      // completes exactly when the retry send goes out (the window is
      // provably closed), and the 80ms wait becomes an await on the
      // announcement itself.
      final announced = Completer<void>();
      final lateError = Completer<http.StreamedResponse>();
      transientRetryNotice = (a, m, d, r) {
        notices.add(r);
        if (r.contains('failed late')) announced.complete();
      };
      final client = _ScriptedClient((count) {
        if (count == 2) {
          lateError.completeError(http.ClientException('late transport death'));
        }
        if (count == 1) return lateError.future;
        return Future.value(
          http.StreamedResponse(
            Stream.value(utf8.encode('')),
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        );
      });

      final response = await sendWatchedProviderRequest(client, post(), null);
      expect(response.statusCode, 200);
      await announced.future;
      expect(
        notices.where(
          (n) =>
              n.contains('failed late (superseded)') &&
              n.contains('error detached'),
        ),
        hasLength(1),
      );
    });

    test('latch reset on success: a LATER identical-payload episode '
        're-advices (one warning per episode, review r1)', () async {
      final advices = <int>[];
      payloadStallAdvice = (bytes, fingerprint) => advices.add(bytes);
      // Episode 1: two stalls (advice fires), then attempt 3 succeeds —
      // the success resets the latch.
      var episode = 1;
      final client = _ScriptedClient((count) {
        if (episode == 1 && count <= 2) {
          return Completer<http.StreamedResponse>().future;
        }
        return Future.value(
          http.StreamedResponse(
            Stream.value(utf8.encode('')),
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        );
      });
      final response = await sendWatchedProviderRequest(client, post(), null);
      expect(response.statusCode, 200);
      expect(advices, hasLength(1));

      // Episode 2: the SAME payload stalls twice again — the advice must
      // fire once more (the reset closed episode 1).
      episode = 2;
      final stalled = _ScriptedClient(
        (count) => Completer<http.StreamedResponse>().future,
      );
      await expectLater(
        sendWatchedProviderRequest(stalled, post(), null),
        throwsA(isA<TimeoutException>()),
      );
      expect(advices, hasLength(2));
    });
  });
}

/// Records request counts; [script] answers each attempt in order.
final class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.script);

  final Future<http.StreamedResponse> Function(int count) script;
  final sent = <int>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sent.add(sent.length + 1);
    return script(sent.length);
  }
}
