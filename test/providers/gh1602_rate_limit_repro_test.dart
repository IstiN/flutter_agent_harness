// gh-1602 REG: a provider `429 Rate limit reached` must be retried with
// backoff instead of failing the run. Run 7 of the harbor bench lost 5 of
// 30 trials to single transient quota blips (n_retries: 0): the provider
// ladder deliberately forwards rate limits ("they stay with the roles
// layer"), but the roles layer only exists when a model-roles chain is
// configured — the bench's single-provider setup has nobody above the
// provider ladder to own the 429, so the raw `429: Rate limit reached.`
// error event kills the turn and the run exits 1.
//
// This file reproduces the bug with the public pre-fix API only; the fix
// (the ladder's rate-limit class, deadline bound, and the `429_retry`
// session record) is exercised in gh1602_rate_limit_retry_test.dart and
// the CLI headless test.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

AssistantMessageEventStream failWith(String text) {
  final stream = AssistantMessageEventStream();
  scheduleMicrotask(() {
    stream.push(
      ErrorEvent(
        reason: StopReason.error,
        error: AssistantMessage(
          content: const [],
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: Usage.zero,
          stopReason: StopReason.error,
          errorMessage: text,
          timestamp: DateTime.utc(2026),
        ),
      ),
    );
    stream.end();
  });
  return stream;
}

void main() {
  late Future<bool> Function(Duration, CancelToken?) savedSleeper;
  late TransientRetryNotice? savedNotice;

  setUp(() {
    savedSleeper = transientRetrySleeper;
    savedNotice = transientRetryNotice;
    transientRetrySleeper = (delay, token) async => true;
    transientRetryNotice = null;
  });
  tearDown(() {
    transientRetrySleeper = savedSleeper;
    transientRetryNotice = savedNotice;
  });

  test('REG gh-1602: a scripted 429-then-200 provider is retried and the '
      'call completes — no terminal rate-limit error', () async {
    var calls = 0;
    final notices = <String>[];
    transientRetryNotice = (attempt, max, delay, reason) {
      notices.add('${attempt + 1}/$max in ${delay.inSeconds}s: $reason');
    };
    final wrapped = transientRetryStreamFunction((
      model,
      context, {
      cancelToken,
    }) {
      calls++;
      if (calls == 1) {
        // The exact run-7 shape (make-doom-for-mips__HjSXdP2): the
        // structured 429 decode renders this line, the run exits 1.
        return failWith('429: Rate limit reached. Try again later.');
      }
      return FakeStreamFunction([
        textTurn('recovered'),
      ]).call(model, context, cancelToken: cancelToken);
    });

    final message = await wrapped(
      testModel,
      const Context(messages: []),
    ).result;

    expect(calls, 2, reason: 'the 429 must be retried, not fatal');
    expect(message.stopReason, StopReason.stop);
    expect(message.content.whereType<TextContent>().single.text, 'recovered');
    expect(notices, hasLength(1), reason: 'the retry is never silent');
  });
}
