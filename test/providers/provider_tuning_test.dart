// Issue #1398 — stall-recovery tuning from the references: per-provider
// idle timeout (codex-rs model-provider-info), server-advertised backoff
// (codex-rs responses_retry), dual retry budgets, and the data-driven
// tuning recipe. Contract tests for `lib/src/providers/provider_tuning.dart`.
//
// Territory note: this lane owns the TUNING layer (config plumbing, per-
// provider values, budgets/backoff decisions, trace format, report). The
// runtime mechanics (#1395's ladder/taxonomy, #1392's ConnTrace) consume
// these contracts; nothing here renames or restructures their surfaces.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:core';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

void main() {
  group(
    'AC1/UT — per-provider timeout resolution (provider > global > default)',
    () {
      test('empty registry + no global override resolves to the defaults', () {
        // AC6: no overrides → byte-identical defaults (E1: 180s/300s stay).
        providerTuningRegistry.clear();
        providerTimeoutsOverride = null;
        addTearDown(providerTuningRegistry.clear);
        final resolved = resolveProviderTimeouts(
          url: Uri.parse('https://api.openai.com/v1/chat/completions'),
        );
        expect(resolved.connect, providerConnectTimeout);
        expect(resolved.streamIdle, providerStreamIdleTimeout);
        expect(resolved.connectSourceLabel, 'default');
        expect(resolved.streamIdleSourceLabel, 'default');
      });

      test('global providerTimeouts override wins over the defaults', () {
        providerTuningRegistry.clear();
        addTearDown(providerTuningRegistry.clear);
        addTearDown(() => providerTimeoutsOverride = null);
        providerTimeoutsOverride = const ProviderTimeoutsOverride(
          connect: Duration(seconds: 90),
          streamIdle: Duration(seconds: 120),
        );
        final resolved = resolveProviderTimeouts(
          url: Uri.parse('https://api.openai.com/v1/chat/completions'),
        );
        expect(resolved.connect, const Duration(seconds: 90));
        expect(resolved.streamIdle, const Duration(seconds: 120));
        expect(resolved.connectSourceLabel, 'global');
        expect(resolved.streamIdleSourceLabel, 'global');
      });

      test('a registry entry wins over the global override, per field', () {
        providerTuningRegistry.clear();
        addTearDown(providerTuningRegistry.clear);
        addTearDown(() => providerTimeoutsOverride = null);
        providerTimeoutsOverride = const ProviderTimeoutsOverride(
          connect: Duration(seconds: 90),
          streamIdle: Duration(seconds: 120),
        );
        providerTuningRegistry.register(
          name: 'glm-relay',
          baseUrl: 'https://glm.example.com/v1',
          connect: const Duration(seconds: 30),
        );
        final resolved = resolveProviderTimeouts(
          url: Uri.parse('https://glm.example.com/v1/chat/completions'),
        );
        // Declared field comes from the entry; undeclared field falls through
        // to the global override.
        expect(resolved.connect, const Duration(seconds: 30));
        expect(resolved.connectSourceLabel, 'provider:glm-relay');
        expect(resolved.streamIdle, const Duration(seconds: 120));
        expect(resolved.streamIdleSourceLabel, 'global');
      });

      test('baseUrl prefix match: entry base matches request URL under it', () {
        providerTuningRegistry.clear();
        addTearDown(providerTuningRegistry.clear);
        providerTuningRegistry.register(
          name: 'slow-thinker',
          baseUrl: 'https://api.kimi.example/v1',
          streamIdle: const Duration(minutes: 8),
        );
        final resolved = resolveProviderTimeouts(
          url: Uri.parse('https://api.kimi.example/v1/chat/completions'),
        );
        expect(resolved.streamIdle, const Duration(minutes: 8));
        // A DIFFERENT host on the same run keeps the global/default value —
        // the AC1 "second provider" leg.
        final other = resolveProviderTimeouts(
          url: Uri.parse('https://api.openai.com/v1/chat/completions'),
        );
        expect(other.streamIdle, providerStreamIdleTimeout);
      });

      test('port and scheme are significant; path prefix must align', () {
        providerTuningRegistry.clear();
        addTearDown(providerTuningRegistry.clear);
        providerTuningRegistry.register(
          name: 'local',
          baseUrl: 'http://127.0.0.1:8001/v1',
          streamIdle: const Duration(seconds: 2),
        );
        expect(
          resolveProviderTimeouts(
            url: Uri.parse('http://127.0.0.1:8001/v1/chat/completions'),
          ).streamIdle,
          const Duration(seconds: 2),
        );
        expect(
          resolveProviderTimeouts(
            url: Uri.parse('http://127.0.0.1:8002/v1/chat/completions'),
          ).streamIdle,
          providerStreamIdleTimeout,
        );
      });

      test(
        'precedence: longest base path wins; same-baseUrl tie → last wins',
        () {
          // Two entries can cover the same host at different path depths;
          // first-match-wins let insertion order shadow the more specific
          // one (review: a queue entry's own tuning behind an earlier
          // same-host catch-all). The SPECIFIC base wins regardless of
          // registration order.
          providerTuningRegistry.clear();
          addTearDown(providerTuningRegistry.clear);
          providerTuningRegistry.register(
            name: 'host-catch-all',
            baseUrl: 'https://api.kimi.example/v1',
            streamIdle: const Duration(seconds: 30),
          );
          providerTuningRegistry.register(
            name: 'specific-route',
            baseUrl: 'https://api.kimi.example/v1beta',
            streamIdle: const Duration(seconds: 3),
          );
          expect(
            resolveProviderTimeouts(
              url: Uri.parse(
                'https://api.kimi.example/v1beta/chat/completions',
              ),
            ).streamIdle,
            const Duration(seconds: 3),
            reason: 'the longer (more specific) base path wins',
          );
          expect(
            resolveProviderTimeouts(
              url: Uri.parse('https://api.kimi.example/v1/chat/completions'),
            ).streamIdle,
            const Duration(seconds: 30),
          );
          // Identical baseUrls (two lanes seed the same endpoint — the
          // review's concrete inversion): the LAST registration wins, so
          // the queue pass (which runs after the config pass at boot)
          // keeps its own tuning instead of being silently shadowed.
          providerTuningRegistry.clear();
          providerTuningRegistry.register(
            name: 'customProviders:glm',
            baseUrl: 'https://glm.example.com/v1',
            streamIdle: const Duration(seconds: 30),
          );
          providerTuningRegistry.register(
            name: 'queue:glm',
            baseUrl: 'https://glm.example.com/v1',
            streamIdle: const Duration(seconds: 7),
          );
          expect(
            resolveProviderTimeouts(
              url: Uri.parse('https://glm.example.com/v1/chat/completions'),
            ).streamIdle,
            const Duration(seconds: 7),
            reason:
                'last-registration-wins on equal bases — boot seeds the '
                'queue pass last, so queue tuning cannot be shadowed',
          );
        },
      );

      test('malformed entry baseUrls never match any request URL', () {
        // The guard arms of the base matcher: a config error that slips
        // past the parsers must stay inert — never partially match, never
        // throw from the wire seams.
        providerTuningRegistry.clear();
        addTearDown(providerTuningRegistry.clear);
        const malformed = {
          'unparseable': '::::',
          'no-scheme': '//glm.example.com/v1',
          'no-authority': 'https:',
        };
        for (final entry in malformed.entries) {
          providerTuningRegistry.register(
            name: entry.key,
            baseUrl: entry.value,
            streamIdle: const Duration(seconds: 1),
          );
        }
        final url = Uri.parse('https://glm.example.com/v1/chat/completions');
        for (final entry in malformed.keys) {
          expect(
            providerTuningRegistry.forName(entry),
            isNotNull,
            reason: '$entry: the row is registered (boot notices name it)',
          );
        }
        expect(
          resolveProviderTimeouts(url: url).streamIdle,
          providerStreamIdleTimeout,
          reason: 'no malformed base may match a well-formed request URL',
        );
      });

      test('explicit name lookup wins over baseUrl matching', () {
        providerTuningRegistry.clear();
        addTearDown(providerTuningRegistry.clear);
        providerTuningRegistry.register(
          name: 'a',
          baseUrl: 'https://a.example/v1',
          streamIdle: const Duration(seconds: 1),
        );
        providerTuningRegistry.register(
          name: 'b',
          baseUrl: 'https://b.example/v1',
          streamIdle: const Duration(seconds: 2),
        );
        expect(
          resolveProviderTimeouts(name: 'b').streamIdle,
          const Duration(seconds: 2),
        );
      });

      test('per-URL helpers agree with the resolver', () {
        providerTuningRegistry.clear();
        addTearDown(providerTuningRegistry.clear);
        providerTuningRegistry.register(
          name: 'x',
          baseUrl: 'https://x.example/v1',
          connect: const Duration(seconds: 11),
          streamIdle: const Duration(seconds: 22),
        );
        final url = Uri.parse('https://x.example/v1/chat/completions');
        expect(providerConnectTimeoutForUrl(url), const Duration(seconds: 11));
        expect(
          providerStreamIdleTimeoutForUrl(url),
          const Duration(seconds: 22),
        );
        expect(
          providerConnectTimeoutForUrl(Uri.parse('https://other.example/v1/x')),
          providerConnectTimeout,
        );
      });

      test('describe names the effective values and their sources', () {
        providerTuningRegistry.clear();
        addTearDown(providerTuningRegistry.clear);
        providerTuningRegistry.register(
          name: 'glm-relay',
          baseUrl: 'https://glm.example.com/v1',
          streamIdle: const Duration(milliseconds: 1500),
        );
        final line = describeProviderTimeouts(
          resolveProviderTimeouts(
            url: Uri.parse('https://glm.example.com/v1/chat/completions'),
          ),
        );
        expect(line, contains('connect 180s (default)'));
        expect(line, contains('idle 1.5s (provider:glm-relay)'));
      });
    },
  );

  group(
    'AC2/UT — server-advertised backoff (Retry-After preferred, 60s cap)',
    () {
      test('no header → the ladder step for that attempt', () {
        final d = resolveRetryBackoff(retryAfter: null, attempt: 1);
        expect(d.delay, const Duration(seconds: 5));
        expect(d.source, RetryDelaySource.ladder);
        expect(d.malformedHeader, isFalse);
      });

      test('ladder doubles 5→10→20→40→60 and holds the 60s cap', () {
        expect(retryBackoffLadderStep(1), const Duration(seconds: 5));
        expect(retryBackoffLadderStep(2), const Duration(seconds: 10));
        expect(retryBackoffLadderStep(3), const Duration(seconds: 20));
        expect(retryBackoffLadderStep(4), const Duration(seconds: 40));
        expect(retryBackoffLadderStep(5), const Duration(seconds: 60));
        expect(retryBackoffLadderStep(9), const Duration(seconds: 60));
      });

      test('Retry-After: 12 → 12s backoff on that attempt, source server', () {
        final d = resolveRetryBackoff(retryAfter: '12', attempt: 1);
        expect(d.delay, const Duration(seconds: 12));
        expect(d.source, RetryDelaySource.server);
        expect(d.advertised, const Duration(seconds: 12));
        expect(d.malformedHeader, isFalse);
      });

      test('Retry-After: 300 → clamped to the 60s ceiling, source clamp', () {
        final d = resolveRetryBackoff(retryAfter: '300', attempt: 1);
        expect(d.delay, retryBackoffCeiling);
        expect(d.delay, const Duration(seconds: 60));
        expect(d.source, RetryDelaySource.clamp);
        expect(d.advertised, const Duration(seconds: 300));
      });

      test('E2: Retry-After: 0 is treated as absent (ladder applies)', () {
        final d = resolveRetryBackoff(retryAfter: '0', attempt: 2);
        expect(d.delay, const Duration(seconds: 10));
        expect(d.source, RetryDelaySource.ladder);
      });

      test('E3: malformed (non-numeric) → ladder + malformed note', () {
        final d = resolveRetryBackoff(retryAfter: 'soon', attempt: 1);
        expect(d.delay, const Duration(seconds: 5));
        expect(d.source, RetryDelaySource.ladder);
        expect(d.malformedHeader, isTrue);
      });

      test('E3: HTTP-date form counts as malformed for the stall ladder', () {
        final d = resolveRetryBackoff(
          retryAfter: 'Wed, 21 Oct 2015 07:28:00 GMT',
          attempt: 1,
        );
        expect(d.source, RetryDelaySource.ladder);
        expect(d.malformedHeader, isTrue);
      });

      test('blank header → ladder, not malformed', () {
        final d = resolveRetryBackoff(retryAfter: '  ', attempt: 3);
        expect(d.source, RetryDelaySource.ladder);
        expect(d.malformedHeader, isFalse);
      });

      test('negative value is malformed, never a negative delay', () {
        final d = resolveRetryBackoff(retryAfter: '-5', attempt: 1);
        expect(d.source, RetryDelaySource.ladder);
        expect(d.malformedHeader, isTrue);
      });
    },
  );

  group(
    'AC3/UT — dual retry budgets (connection 4 / stream 3, independent)',
    () {
      test('five connect-class failures exhaust connection only', () {
        final ledger = RetryBudgetLedger();
        for (var i = 0; i < 4; i++) {
          expect(ledger.tryConsume(RetryBudgetClass.connection), isTrue);
        }
        expect(ledger.tryConsume(RetryBudgetClass.connection), isFalse);
        // The stream budget is UNTOUCHED — a subsequent idle-class stall
        // still gets its full budget.
        expect(ledger.used(RetryBudgetClass.stream), 0);
        expect(ledger.tryConsume(RetryBudgetClass.stream), isTrue);
      });

      test('stream exhaustion never consumes the connection budget', () {
        final ledger = RetryBudgetLedger();
        for (var i = 0; i < 3; i++) {
          expect(ledger.tryConsume(RetryBudgetClass.stream), isTrue);
        }
        expect(ledger.tryConsume(RetryBudgetClass.stream), isFalse);
        expect(ledger.used(RetryBudgetClass.connection), 0);
        expect(ledger.tryConsume(RetryBudgetClass.connection), isTrue);
      });

      test('caps are injectable; defaults are 4 and 3', () {
        expect(RetryBudgetLedger().cap(RetryBudgetClass.connection), 4);
        expect(RetryBudgetLedger().cap(RetryBudgetClass.stream), 3);
        final ledger = RetryBudgetLedger(
          connectionRetries: 1,
          streamRetries: 1,
        );
        expect(ledger.cap(RetryBudgetClass.connection), 1);
      });

      test('E5: the terminal story carries BOTH counters', () {
        final ledger = RetryBudgetLedger();
        for (var i = 0; i < 4; i++) {
          ledger.tryConsume(RetryBudgetClass.connection);
        }
        for (var i = 0; i < 3; i++) {
          ledger.tryConsume(RetryBudgetClass.stream);
        }
        final story = ledger.terminalStory();
        expect(story, contains('connection 4/4'));
        expect(story, contains('stream 3/3'));
      });

      test('terminal story renders partial spend truthfully', () {
        // Review r2: the story must not CLAIM exhaustion it cannot see.
        final ledger = RetryBudgetLedger();
        ledger.tryConsume(RetryBudgetClass.connection);
        final story = ledger.terminalStory();
        expect(story, contains('connection 1/4'));
        expect(story, contains('stream 0/3'));
        expect(
          story.contains('exhausted'),
          isFalse,
          reason:
              '1/4 and 0/3 spent — no budget is exhausted, the story '
              'must not say so',
        );
      });

      test('terminal story names WHICH budget exhausted on mixed spend', () {
        final ledger = RetryBudgetLedger();
        for (var i = 0; i < ledger.cap(RetryBudgetClass.connection); i++) {
          ledger.tryConsume(RetryBudgetClass.connection);
        }
        ledger.tryConsume(RetryBudgetClass.stream);
        final story = ledger.terminalStory();
        expect(story, contains('connection 4/4 exhausted'));
        expect(story, contains('stream 1/3'));
        // Only the spent-out budget earns the word.
        final exhaustedCount = 'exhausted'.allMatches(story).length;
        expect(exhaustedCount, 1);
      });

      test(
        'terminal story keeps the exhausted headline when BOTH are spent',
        () {
          final ledger = RetryBudgetLedger();
          for (var i = 0; i < 4; i++) {
            ledger.tryConsume(RetryBudgetClass.connection);
          }
          for (var i = 0; i < 3; i++) {
            ledger.tryConsume(RetryBudgetClass.stream);
          }
          final story = ledger.terminalStory();
          expect(story, startsWith('retry budgets exhausted'));
          expect(story, contains('connection 4/4'));
          expect(story, contains('stream 3/3'));
        },
      );
    },
  );

  group('AC4/UT — retry trace line format contract', () {
    test('ladder delay line names budget, attempt and source', () {
      final line = formatRetryTraceLine(
        budget: RetryBudgetClass.connection,
        attempt: 2,
        cap: 4,
        decision: resolveRetryBackoff(retryAfter: null, attempt: 2),
      );
      expect(line, 'budget=connection attempt=2/4 delay=ladder:10s');
    });

    test('server delay line', () {
      final line = formatRetryTraceLine(
        budget: RetryBudgetClass.stream,
        attempt: 1,
        cap: 3,
        decision: resolveRetryBackoff(retryAfter: '12', attempt: 1),
      );
      expect(line, 'budget=stream attempt=1/3 delay=server:12s');
    });

    test('clamp line names the ceiling AND the advertised value', () {
      final line = formatRetryTraceLine(
        budget: RetryBudgetClass.stream,
        attempt: 2,
        cap: 3,
        decision: resolveRetryBackoff(retryAfter: '300', attempt: 1),
      );
      expect(line, contains('delay=clamp:60s'));
      expect(line, contains('server advertised 300s'));
    });

    test('malformed header appends the malformed note', () {
      final line = formatRetryTraceLine(
        budget: RetryBudgetClass.connection,
        attempt: 1,
        cap: 4,
        decision: resolveRetryBackoff(retryAfter: 'soon', attempt: 1),
      );
      expect(line, contains('delay=ladder:5s'));
      expect(line, contains('retry-after malformed ("soon")'));
    });
  });

  group(
    'AC5/UT — tuning report (p50/p95 inter-chunk gap + watchdog fires)',
    () {
      test('empty recorder renders an empty report', () {
        final recorder = InterChunkGapRecorder();
        expect(recorder.summaries, isEmpty);
        expect(renderTuningReport(recorder: recorder), isEmpty);
      });

      test('percentiles are nearest-rank over recorded gaps', () {
        final recorder = InterChunkGapRecorder();
        // 100 samples 1s..100s: p50 → 50th, p95 → 95th (nearest-rank).
        for (var i = 1; i <= 100; i++) {
          recorder.recordGap('m', Duration(seconds: i));
        }
        final s = recorder.summary('m')!;
        expect(s.samples, 100);
        expect(s.p50, const Duration(seconds: 50));
        expect(s.p95, const Duration(seconds: 95));
        expect(s.watchdogFires, 0);
      });

      test('watchdog fires are counted per model', () {
        final recorder = InterChunkGapRecorder();
        recorder.recordGap('glm', const Duration(seconds: 3));
        recorder.recordWatchdogFire('glm');
        recorder.recordWatchdogFire('glm');
        recorder.recordWatchdogFire('other');
        expect(recorder.summary('glm')!.watchdogFires, 2);
        expect(recorder.summary('other')!.watchdogFires, 1);
      });

      test('report renders p50/p95, fire counts and the recipe line', () {
        final recorder = InterChunkGapRecorder();
        for (var i = 1; i <= 10; i++) {
          recorder.recordGap('glm-5.3-flash', Duration(seconds: i * 10));
        }
        recorder.recordWatchdogFire('glm-5.3-flash');
        final report = renderTuningReport(recorder: recorder);
        expect(report, contains('glm-5.3-flash'));
        expect(report, contains('p50 50s'));
        expect(report, contains('p95 100s'));
        expect(report, contains('watchdog fires 1'));
        // The recipe: streamIdleTimeoutMs ≈ 2× p95.
        expect(report, contains('2× p95'));
        expect(report, contains('200s'));
      });

      test('unsorted insertion order still yields sorted percentiles', () {
        final recorder = InterChunkGapRecorder();
        for (final s in [30, 10, 20]) {
          recorder.recordGap('m', Duration(seconds: s));
        }
        expect(recorder.summary('m')!.p50, const Duration(seconds: 20));
      });

      test('per-model samples are bounded (no unbounded process growth)', () {
        // Review r2: a reasoning-heavy run records thousands of gaps per
        // model into a process-global — the recorder keeps a bounded
        // recent window instead of growing forever.
        final recorder = InterChunkGapRecorder();
        for (
          var i = 0;
          i < InterChunkGapRecorder.maxSamplesPerModel + 100;
          i++
        ) {
          recorder.recordGap('m', Duration(milliseconds: i));
        }
        final summary = recorder.summary('m')!;
        expect(summary.samples, InterChunkGapRecorder.maxSamplesPerModel);
        // The window keeps the RECENT samples: the oldest 100 are gone,
        // so the p95 reflects the tail of the run, not its head. Sorted
        // window [100..2147], nearest-rank p95 = ceil(0.95·2048) = 1946th
        // value = index 1945 → 100 + 1945 = 2045 ms (an unbounded or
        // keep-oldest window would read 1945 ms instead).
        expect(summary.p95, const Duration(milliseconds: 100 + 1945));
      });
    },
  );

  group('AC1/UT — the adapter path inherits the per-provider idle timeout', () {
    test(
      'streamOpenAICompletions surfaces the entry-tuned idle watchdog',
      () async {
        providerTuningRegistry.clear();
        providerTimeoutsOverride = null;
        addTearDown(providerTuningRegistry.clear);
        providerTuningRegistry.register(
          name: 'tuned',
          baseUrl: 'https://tuned.example/v1',
          streamIdle: const Duration(milliseconds: 400),
        );
        final model = Model(
          id: 'slow-thinker',
          api: 'openai-completions',
          provider: 'openai',
          baseUrl: 'https://tuned.example/v1',
          contextWindow: 128000,
          maxTokens: 16384,
        );
        // Headers arrive, then the body NEVER emits another byte — the
        // alive-but-silent class. The response carries its request so the
        // createSseIterator seam can resolve the per-provider value.
        final neverBytes = StreamController<List<int>>(); // never closed
        addTearDown(neverBytes.close);
        final client = http_testing.MockClient.streaming((request, body) async {
          return http.StreamedResponse(
            neverBytes.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
            request: request,
          );
        });
        final sw = Stopwatch()..start();
        final events = await streamOpenAICompletions(
          model,
          Context(
            messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))],
          ),
          const OpenAICompletionsOptions(apiKey: 'test-key'),
          client,
        ).toList();
        final elapsed = sw.elapsed;
        final last = events.last;
        expect(last, isA<ErrorEvent>());
        expect(
          '${(last as ErrorEvent).error.errorMessage}',
          contains('stream idle timeout'),
        );
        expect(elapsed, lessThan(const Duration(seconds: 5)));
        expect(elapsed, greaterThan(const Duration(milliseconds: 300)));
      },
    );
  });
}
