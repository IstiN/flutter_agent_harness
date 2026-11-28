/// gh-2470: a deterministic per-history provider failure — the SAME error
/// (e.g. `Provider finish_reason: error`) on every attempt of a LARGE
/// request — must classify as probable context overflow / poisonous
/// payload at the retry ladder's exhaustion terminal, with compact/switch
/// advice, instead of the generic "check the provider status / try again
/// later" transient story that sends the user into a retry loop.
///
/// The acceptance's failing-first shape: a fake provider that returns
/// `finish_reason: error` for requests above N tokens; the ladder
/// (a) stops after the configured retries, (b) classifies the failure as
/// probable-overflow on large requests, (c) offers «compact / switch
/// model» remediation instead of «try again later», and the classification
/// discriminates: transient wordings and non-deterministic chains keep the
/// generic (correct) exhaustion story.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A model with a small catalog window so the large-request gate fires on
/// a fixture-sized history: ≥ 50% of 10k = 5k estimated tokens.
const poisonedModel = Model(
  id: 'poisoned-model',
  api: 'test-api',
  provider: 'copilot',
  baseUrl: 'https://example.test',
  contextWindow: 10000,
  maxTokens: 4096,
);

/// A history estimating above the gate: ~30k chars ≈ 7.5k estimated
/// tokens (≥ 50% of the 10k window).
Context largeContext() => Context(
  messages: [
    UserMessage.text('x' * 30000),
    AssistantMessage(
      content: [TextContent(text: 'y' * 4000)],
      api: 'test-api',
      provider: 'copilot',
      model: 'poisoned-model',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.utc(2026),
    ),
  ],
);

/// A history comfortably under the gate (≈ 250 estimated tokens).
Context smallContext() =>
    Context(messages: [UserMessage.text('hello, please help')]);

AssistantMessageEventStream failWith(String text, {String? raw}) {
  final stream = AssistantMessageEventStream();
  scheduleMicrotask(() {
    stream.push(
      ErrorEvent(
        reason: StopReason.error,
        error: AssistantMessage(
          content: const [],
          api: 'test-api',
          provider: 'copilot',
          model: 'poisoned-model',
          usage: Usage.zero,
          stopReason: StopReason.error,
          rawStopReason: raw,
          errorMessage: text,
          timestamp: DateTime.utc(2026),
        ),
      ),
    );
    stream.end();
  });
  return stream;
}

/// The ticket's exact failure shape: the copilot endpoint answers every
/// attempt with a bare `finish_reason: error` (the wire verdict rides
/// `rawStopReason`, so the #312 unknown-class default replays it — the
/// blind retry the ticket reports).
AssistantMessageEventStream finishReasonError(
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) {
  final stream = AssistantMessageEventStream();
  scheduleMicrotask(() {
    stream.push(
      ErrorEvent(
        reason: StopReason.error,
        error: AssistantMessage(
          content: const [],
          api: 'test-api',
          provider: 'copilot',
          model: 'poisoned-model',
          usage: Usage.zero,
          stopReason: StopReason.error,
          rawStopReason: 'error',
          errorMessage: 'Provider finish_reason: error',
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

  group('deterministic per-history failure on a large request', () {
    test('stops after the configured retries and classifies probable '
        'overflow with compact/switch advice (gh-2470 a/b/c)', () async {
      var calls = 0;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        return finishReasonError(model, context, cancelToken: cancelToken);
      });

      final message = await wrapped(poisonedModel, largeContext()).result;

      // (a) the configured retry budget governs, nothing more.
      expect(calls, 3, reason: 'the ladder stops at its configured budget');
      expect(message.stopReason, StopReason.error);
      // (b) the classification: the probable-overflow marker rides the
      // terminal.
      expect(message.errorMessage, contains(probableOverflowMarker));
      expect(isProbableOverflowError(message.errorMessage), isTrue);
      // (c) the remediation: compact / switch — never the transient
      // advice.
      expect(message.errorMessage, contains('/compact'));
      expect(message.errorMessage, contains('switch model'));
      expect(message.errorMessage, isNot(contains('try again later')));
      expect(
        message.errorMessage,
        isNot(contains('Check the provider status')),
      );
      // The evidence names the request size (the honest numbers story).
      expect(message.errorMessage, contains('tokens'));
    });

    test('the same failure on a SMALL request keeps the generic exhausted '
        'terminal (never a wrong classification)', () async {
      var calls = 0;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        return finishReasonError(model, context, cancelToken: cancelToken);
      });

      final message = await wrapped(poisonedModel, smallContext()).result;

      expect(calls, 3, reason: 'unknown-class failures still spend the budget');
      expect(isProbableOverflowError(message.errorMessage), isFalse);
      expect(
        message.errorMessage,
        startsWith('Provider call failed after 3 attempt(s)'),
      );
      expect(message.errorMessage, contains('try again later'));
    });

    test('a transient transport wording on a large request keeps the '
        'generic exhausted terminal — retry advice stays correct', () async {
      final wrapped = transientRetryStreamFunction(
        (model, context, {cancelToken}) =>
            failWith('SocketException: Connection reset by peer'),
      );

      final message = await wrapped(poisonedModel, largeContext()).result;

      expect(isProbableOverflowError(message.errorMessage), isFalse);
      expect(
        message.errorMessage,
        startsWith('Provider call failed after 3 attempt(s)'),
      );
    });

    test('differing error texts (non-deterministic chain) keep the generic '
        'exhausted terminal', () async {
      final texts = [
        ('Provider finish_reason: error', 'error'),
        ('Provider finish_reason: error', 'error'),
        ('Provider finish_reason: network_error', 'network_error'),
      ];
      var calls = 0;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        final (text, raw) = texts[calls - 1];
        return failWith(text, raw: raw);
      });

      final message = await wrapped(poisonedModel, largeContext()).result;

      expect(calls, 3);
      expect(isProbableOverflowError(message.errorMessage), isFalse);
      expect(
        message.errorMessage,
        startsWith('Provider call failed after 3 attempt(s)'),
      );
    });
  });

  group('isProbableOverflowError — recognizer', () {
    test('matches only the probable-overflow terminal marker', () {
      expect(
        isProbableOverflowError(
          'Provider call failed after 3 attempt(s) — the history itself is '
          'the likely poison ($probableOverflowMarker). Attempts: … '
          'Compact this session (/compact) or switch model/session.',
        ),
        isTrue,
      );
      expect(isProbableOverflowError('Provider finish_reason: error'), isFalse);
      expect(isProbableOverflowError(null), isFalse);
      expect(isProbableOverflowError(''), isFalse);
      // The loop's own over-window guard marker is a different class.
      expect(
        isProbableOverflowError(
          'Context window exhausted: the outgoing context is ~250k tokens',
        ),
        isFalse,
      );
    });
  });

  group('probable-overflow size gate + estimator', () {
    Context withMessages(List<Message> messages, {String? systemPrompt}) =>
        Context(systemPrompt: systemPrompt, messages: messages);

    test('the window-fraction gate: ≥ 50% of the window is large', () {
      expect(
        isProbableOverflowLargeRequest(
          requestTokens: 5000,
          contextWindow: 10000,
        ),
        isTrue,
      );
      expect(
        isProbableOverflowLargeRequest(
          requestTokens: 4999,
          contextWindow: 10000,
        ),
        isFalse,
      );
    });

    test('the absolute floor covers the served-below-the-advertised-window '
        'family (gh-2470: ~245k refused on a 1M catalog window)', () {
      expect(
        isProbableOverflowLargeRequest(
          requestTokens: 245000,
          contextWindow: 1000000,
        ),
        isTrue,
        reason: '≥ 200k tokens is large even at 24.5% of the catalog window',
      );
      expect(
        isProbableOverflowLargeRequest(
          requestTokens: 199999,
          contextWindow: null,
        ),
        isFalse,
      );
    });

    test('an unknown window (≤ 0) falls back to the absolute floor only', () {
      expect(
        isProbableOverflowLargeRequest(requestTokens: 250000, contextWindow: 0),
        isTrue,
      );
      expect(
        isProbableOverflowLargeRequest(requestTokens: 900, contextWindow: 0),
        isFalse,
      );
    });

    test('the estimator: transcript at ~4 chars/token, system prompt at '
        '~2.5 (the token-dense overhead density)', () {
      final tokens = estimateProbableOverflowRequestTokens(
        withMessages([UserMessage.text('a' * 4000)], systemPrompt: 's' * 250),
      );
      // 4000/4 = 1000 transcript tokens + ceil(250×0.4)=100 overhead.
      expect(tokens, 1100);
    });

    test('the estimator prices images flat and skips nothing else', () {
      final tokens = estimateProbableOverflowRequestTokens(
        withMessages([
          UserMessage.text('q'),
          AssistantMessage(
            content: [
              TextContent(text: 'a' * 400),
              ThinkingContent(thinking: 't' * 400),
              const ImageContent(
                data: '8MB-base64-blob',
                mimeType: 'image/png',
              ),
            ],
            api: 'test-api',
            provider: 'test-provider',
            model: 'test-model',
            usage: Usage.zero,
            stopReason: StopReason.stop,
            timestamp: DateTime.utc(2026),
          ),
        ]),
      );
      // 1-char user (~0 tokens) + 400/4 + 400/4 + 4800/4 = 100 + 100 +
      // 1200.
      expect(tokens, 1400);
    });
  });
}
