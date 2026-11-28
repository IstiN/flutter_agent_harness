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

/// A successful turn for the recovery tests: the fresh connection (after
/// the re-dial) finally serves the request.
AssistantMessageEventStream succeedWith(Model model, Context context) {
  final stream = AssistantMessageEventStream();
  scheduleMicrotask(() {
    stream.push(
      DoneEvent(
        reason: StopReason.stop,
        message: AssistantMessage(
          content: [TextContent(text: 'served on the fresh connection')],
          api: model.api,
          provider: model.provider,
          model: model.id,
          usage: Usage.zero,
          stopReason: StopReason.stop,
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
  late void Function() savedRecovery;

  setUp(() {
    savedSleeper = transientRetrySleeper;
    savedNotice = transientRetryNotice;
    savedRecovery = transientConnectionRecovery;
    transientRetrySleeper = (delay, token) async => true;
    transientRetryNotice = null;
    transientConnectionRecovery = () {};
  });

  tearDown(() {
    transientRetrySleeper = savedSleeper;
    transientRetryNotice = savedNotice;
    transientConnectionRecovery = savedRecovery;
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

  group('connection/credential recovery before exhaustion (gh-2470 '
      'review)', () {
    test('the 2nd consecutive identical failure re-dials: the cached pool '
        'is dropped once and the fresh connection succeeds — the ladder '
        'never fails 3× on the dead connection', () async {
      var recoveries = 0;
      transientConnectionRecovery = () => recoveries++;
      var calls = 0;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        // The stale pooled connection answers every dial with the same
        // opaque failure — until the recovery drops it and the fresh
        // connection serves the turn.
        if (recoveries == 0) {
          return finishReasonError(model, context, cancelToken: cancelToken);
        }
        return succeedWith(model, context);
      });

      final message = await wrapped(poisonedModel, smallContext()).result;

      // Two identical failures → the recovery → the re-dialed attempt
      // succeeds inside the SAME chain (3 calls total, no exhaustion).
      expect(calls, 3, reason: '2 dead-pool failures + the re-dialed dial');
      expect(recoveries, 1, reason: 'the recovery fires once per chain');
      expect(message.stopReason, isNot(StopReason.error));
      expect(
        message.errorMessage,
        isNull,
        reason: 'the fresh connection served the turn — no terminal',
      );
    });

    test('an identical transient transport wording re-dials too — the '
        'stale keep-alive pool is the reported restart-cures shape', () async {
      var recoveries = 0;
      transientConnectionRecovery = () => recoveries++;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        if (recoveries == 0) {
          return failWith('SocketException: Connection reset by peer');
        }
        return succeedWith(model, context);
      });

      final message = await wrapped(poisonedModel, smallContext()).result;

      expect(recoveries, 1, reason: 'identical failures prove the dead pool');
      expect(message.stopReason, isNot(StopReason.error));
    });

    test('a NON-deterministic chain never re-dials (differing texts are '
        'independent failures, each may heal on its own replay)', () async {
      var recoveries = 0;
      transientConnectionRecovery = () => recoveries++;
      final texts = ['first opaque failure', 'a different opaque failure'];
      var calls = 0;
      final wrapped = transientRetryStreamFunction((
        model,
        context, {
        cancelToken,
      }) {
        calls++;
        return failWith(texts[(calls - 1).clamp(0, texts.length - 1)]);
      });

      final message = await wrapped(poisonedModel, smallContext()).result;

      expect(recoveries, 0, reason: 'the texts differ — no determinism');
      expect(message.stopReason, StopReason.error);
    });

    test('the genuine large-request case keeps its verdict: the re-dial '
        'cannot cure a poisonous history — the probable-overflow terminal '
        'still classifies it, with the recovery spent exactly once', () async {
      var recoveries = 0;
      transientConnectionRecovery = () => recoveries++;
      final wrapped = transientRetryStreamFunction(
        (model, context, {cancelToken}) =>
            finishReasonError(model, context, cancelToken: cancelToken),
      );

      final message = await wrapped(poisonedModel, largeContext()).result;

      expect(recoveries, 1, reason: 'one re-dial before the exhaustion');
      expect(message.stopReason, StopReason.error);
      expect(isProbableOverflowError(message.errorMessage), isTrue);
      expect(message.errorMessage, contains('/compact'));
    });

    test('the default recovery action drops the shared provider client '
        'so the next dial builds a fresh pool (the production seam)', () async {
      // Run the DEFAULT action (the saved tear-off, restored over the
      // no-op test double): the cached generation is dropped and the
      // next sharedProviderHttpClient() rebuilds — the fresh dial.
      transientConnectionRecovery = savedRecovery;
      final before = sharedProviderHttpClient();
      transientConnectionRecovery();
      final after = sharedProviderHttpClient();
      expect(
        identical(before, after),
        isFalse,
        reason: 'the cached pool was dropped — the next dial is fresh',
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
