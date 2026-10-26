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
      transientRetryNotice = (a, m, d, r) => notices.add(r);
      // First send answers 10ms in — AFTER the 20ms watchdog? No: the
      // watchdog fires at 20ms, the answer at 10ms would WIN the race
      // normally. Script it so the answer lands at 30ms: after the
      // watchdog (20ms) but inside the 50ms backoff gap.
      final sent = <int>[];
      final client = _ScriptedClient((count) {
        sent.add(count);
        if (count == 1) {
          return Future<http.StreamedResponse>.delayed(
            const Duration(milliseconds: 30),
            () => http.StreamedResponse(
              Stream.value(utf8.encode('')),
              200,
              headers: {'content-type': 'text/event-stream'},
            ),
          );
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
      // First send answers at 100ms — the 50ms backoff is long over, the
      // retry owns the send, so the late response detaches as before.
      // onListen fires when the detach janitor subscribes — the signal
      // that the janitor took the body over.
      final detached = Completer<void>();
      final body = StreamController<List<int>>(onListen: detached.complete);
      final client = _ScriptedClient((count) {
        if (count == 1) {
          return Future<http.StreamedResponse>.delayed(
            const Duration(milliseconds: 100),
            () => http.StreamedResponse(
              body.stream,
              200,
              headers: {'content-type': 'text/event-stream'},
            ),
          );
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
  });
}

/// Records request counts; [script] answers each attempt in order.
final class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.script);

  final Future<http.StreamedResponse> Function(int count) script;
  var _count = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      script(++_count);
}
