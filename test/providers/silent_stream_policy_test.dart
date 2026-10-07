// SilentStreamPolicy (gh-1395 AC4): a bare replay of a wedged upstream
// often re-wedges (bench round 2: recovery 1/13), so the stall ladder is
// BOUNDED and ESCALATING — codex-style backoff 5→60 s (fake clock here), a
// key rotation after the 2nd stall of the run, a smol-role takeover
// attempt after the 3rd, and a full counter reset on success.
import 'dart:async';

import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/cancel_token.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/event_stream.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/providers/silent_stream_policy.dart';
import 'package:flutter_agent_harness/src/providers/stall_taxonomy.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

final model = Model(
  id: 'stall-policy',
  name: 'stall-policy',
  api: 'openai-completions',
  provider: 'stall',
  baseUrl: 'http://127.0.0.1:1',
  contextWindow: 1000,
  maxTokens: 100,
);

const idleError =
    'TimeoutException: no events from the endpoint for 300s '
    '(stream idle timeout)';

final _tokenSource = CancelTokenSource();

AssistantMessage _error(String text) => AssistantMessage(
  content: const [],
  api: model.api,
  provider: model.provider,
  model: model.id,
  usage: Usage.zero,
  stopReason: StopReason.error,
  errorMessage: text,
  timestamp: DateTime.now(),
);

/// Builds an inner stream whose attempts 1..[stalls] die with the idle
/// stall wording (optionally after emitting [eventsBefore] data events),
/// then succeeds with a done event. Records how many times it was CALLED
/// and which "key" it was built for (the harness rotates by rebuilding
/// with the next key).
StreamFunction stallInner(
  int stalls, {
  int eventsBefore = 0,
  void Function(int attempt)? onAttempt,
}) {
  var attempt = 0;
  return (model, context, {cancelToken}) {
    attempt++;
    onAttempt?.call(attempt);
    final out = AssistantMessageEventStream();
    unawaited(() async {
      for (var i = 0; i < eventsBefore; i++) {
        // A CONTENT-bearing event (the #964 commit guard counts visible
        // content, not the bare start event).
        out.push(
          TextStartEvent(
            contentIndex: i,
            partial: AssistantMessage(
              content: const [],
              api: model.api,
              provider: model.provider,
              model: model.id,
              usage: Usage.zero,
              stopReason: StopReason.stop,
              timestamp: DateTime.now(),
            ),
          ),
        );
      }
      if (attempt <= stalls) {
        out.push(
          ErrorEvent(reason: StopReason.error, error: _error(idleError)),
        );
      } else {
        out.push(
          DoneEvent(
            reason: StopReason.stop,
            message: AssistantMessage(
              content: const [],
              api: model.api,
              provider: model.provider,
              model: model.id,
              usage: Usage.zero,
              stopReason: StopReason.stop,
              timestamp: DateTime.now(),
            ),
          ),
        );
      }
      out.end();
    }());
    return out;
  };
}

void main() {
  group('backoff ladder math (UT)', () {
    test('delays double from 5s and cap at 60s — every delay in [5,60]', () {
      final delays = [for (var n = 1; n <= 8; n++) stallBackoffDelay(n)];
      expect(delays, [
        const Duration(seconds: 5),
        const Duration(seconds: 10),
        const Duration(seconds: 20),
        const Duration(seconds: 40),
        const Duration(seconds: 60),
        const Duration(seconds: 60),
        const Duration(seconds: 60),
        const Duration(seconds: 60),
      ]);
      for (final d in delays) {
        expect(d, greaterThanOrEqualTo(const Duration(seconds: 5)));
        expect(d, lessThanOrEqualTo(const Duration(seconds: 60)));
      }
    });
  });

  group('stall ledger (UT, E3: keyed by run)', () {
    test('counts consecutive stalls per run key; success resets', () {
      final ledger = ProviderStallLedger();
      final token = _tokenSource.token;
      expect(ledger.recordStall(token), 1);
      expect(ledger.recordStall(token), 2);
      ledger.reset(token);
      expect(ledger.recordStall(token), 1);
    });

    test('different run keys count independently (no double-counting)', () {
      final ledger = ProviderStallLedger();
      final a = CancelTokenSource().token;
      final b = CancelTokenSource().token;
      expect(ledger.recordStall(a), 1);
      expect(ledger.recordStall(b), 1);
      expect(ledger.recordStall(a), 2);
    });
  });

  group('policy ladder (UT, fake clock)', () {
    late List<Duration> slept;
    late Future<bool> Function(Duration, CancelToken?) sleeper;
    setUp(() {
      slept = [];
      sleeper = (delay, _) async {
        slept.add(delay);
        return true;
      };
    });

    test('AC4: three scripted stalls → delays [5,10,20] (in [5,60]), '
        'rotation after the 2nd, takeover attempt after the 3rd', () async {
      var rotations = 0;
      var takeovers = 0;
      final sharedInner = stallInner(3);
      final policy = SilentStreamPolicy(
        innerBuilder: () => sharedInner,
        hooks: SilentStreamPolicyHooks(
          rotateKey: () {
            rotations++;
            return true;
          },
          buildTakeover: () {
            takeovers++;
            return stallInner(0); // the smol stream serves at once
          },
        ),
        sleeper: sleeper,
      );
      final events = await policy
          .call(model, const Context(messages: []))
          .toList();
      expect(slept, [
        const Duration(seconds: 5),
        const Duration(seconds: 10),
        const Duration(seconds: 20),
      ]);
      expect(rotations, 1, reason: 'the rotation fires on the 2nd stall');
      expect(takeovers, 1, reason: 'the takeover fires on the 3rd stall');
      expect(
        events.last,
        isA<DoneEvent>(),
        reason: 'the takeover stream serves the turn',
      );
      // All four attempts: 3 stalls + the takeover delivery.
    });

    test('a successful response resets the stall counter (AC4)', () async {
      var rotations = 0;
      // One session-scoped policy; the attempt script: call 1 = stall then
      // success; call 2 = stall then success. The SECOND call must cost
      // the FIRST backoff again (the success reset the counter), never the
      // escalated one.
      var attempt = 0;
      final policy = SilentStreamPolicy(
        innerBuilder: () {
          final index = attempt++;
          return (model, context, {cancelToken}) {
            final out = AssistantMessageEventStream();
            out.push(
              index.isEven
                  ? ErrorEvent(
                      reason: StopReason.error,
                      error: _error(idleError),
                    )
                  : DoneEvent(
                      reason: StopReason.stop,
                      message: AssistantMessage(
                        content: const [],
                        api: model.api,
                        provider: model.provider,
                        model: model.id,
                        usage: Usage.zero,
                        stopReason: StopReason.stop,
                        timestamp: DateTime.now(),
                      ),
                    ),
            );
            out.end();
            return out;
          };
        },
        hooks: SilentStreamPolicyHooks(
          rotateKey: () {
            rotations++;
            return true;
          },
        ),
        sleeper: sleeper,
      );
      await policy.call(model, const Context(messages: [])).toList();
      expect(slept, [const Duration(seconds: 5)]);

      await policy.call(model, const Context(messages: [])).toList();
      expect(
        slept,
        [const Duration(seconds: 5), const Duration(seconds: 5)],
        reason:
            'the success reset the counter — the 2nd call restarts the '
            'ladder at the FIRST backoff, never the escalated one',
      );
      expect(
        rotations,
        0,
        reason: 'a reset counter never reaches the rotation threshold',
      );
    });

    test('E5: single-key ring — rotation skipped with a logged reason, '
        'takeover still proceeds', () async {
      var takeovers = 0;
      final notes = <String>[];
      final sharedInner = stallInner(3);
      final policy = SilentStreamPolicy(
        innerBuilder: () => sharedInner,
        hooks: SilentStreamPolicyHooks(
          rotateKey: () => false, // one key: nothing to rotate to
          buildTakeover: () {
            takeovers++;
            return stallInner(0);
          },
          onNotice: notes.add,
        ),
        sleeper: sleeper,
      );
      final events = await policy
          .call(model, const Context(messages: []))
          .toList();
      expect(slept.length, 3);
      expect(notes.any((n) => n.contains('rotation unavailable')), isTrue);
      expect(takeovers, 1);
      expect(events.last, isA<DoneEvent>());
    });

    test('no takeover target → after the 3rd stall the error stands '
        '(roles ladder continues from there)', () async {
      final sharedInner = stallInner(99);
      final policy = SilentStreamPolicy(
        innerBuilder: () => sharedInner,
        hooks: const SilentStreamPolicyHooks(),
        sleeper: sleeper,
      );
      final events = await policy
          .call(model, const Context(messages: []))
          .toList();
      expect(slept.length, 3);
      expect(
        events.last,
        isA<ErrorEvent>().having(
          (e) => e.error.errorMessage,
          'errorMessage',
          contains('(stream idle timeout)'),
        ),
      );
    });

    test('#964: a POST-commit stall is never replayed from scratch', () async {
      var attempts = 0;
      final sharedInner = stallInner(
        99,
        eventsBefore: 1,
        onAttempt: (_) => attempts++,
      );
      final policy = SilentStreamPolicy(
        innerBuilder: () => sharedInner,
        hooks: SilentStreamPolicyHooks(
          rotateKey: () {
            fail('rotation must not fire on a post-commit stall');
          },
          buildTakeover: () {
            fail('takeover must not fire on a post-commit stall');
          },
        ),
        sleeper: sleeper,
      );
      final events = await policy
          .call(model, const Context(messages: []))
          .toList();
      expect(attempts, 1, reason: 'one attempt only — the error stands');
      expect(slept, isEmpty);
      expect(events.last, isA<ErrorEvent>());
    });

    test('non-stall failures pass through untouched (no ladder)', () async {
      final policy = SilentStreamPolicy(
        innerBuilder: () => (model, context, {cancelToken}) {
          final out = AssistantMessageEventStream();
          out.push(
            ErrorEvent(
              reason: StopReason.error,
              error: _error('429: rate limit exceeded'),
            ),
          );
          out.end();
          return out;
        },
        hooks: SilentStreamPolicyHooks(
          rotateKey: () {
            fail('rate limits belong to the roles rotation, not here');
          },
        ),
        sleeper: sleeper,
      );
      final events = await policy
          .call(model, const Context(messages: []))
          .toList();
      expect(slept, isEmpty);
      expect(events.last, isA<ErrorEvent>());
      expect(
        classifyProviderStall((events.last as ErrorEvent).error.errorMessage),
        isNull,
      );
    });

    test('E2-class: a healthy stream never sleeps and never ladders', () async {
      final policy = SilentStreamPolicy(
        innerBuilder: () => stallInner(0),
        hooks: const SilentStreamPolicyHooks(),
        sleeper: sleeper,
      );
      final events = await policy
          .call(model, const Context(messages: []))
          .toList();
      expect(slept, isEmpty);
      expect(events.last, isA<DoneEvent>());
    });
  });

  group(
    'policy corners (UT — coverage of the defensive and escalation edges)',
    () {
      AssistantMessage partial() => AssistantMessage(
        content: const [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.now(),
      );

      test('a synchronously-throwing inner surfaces an ErrorEvent (defensive '
          'catch — providers never throw, fakes might)', () async {
        final policy = SilentStreamPolicy(
          innerBuilder: () =>
              (m, c, {cancelToken}) => throw StateError('boom'),
          sleeper: (_, _) async => true,
        );
        final events = await policy
            .call(model, const Context(messages: []))
            .toList();
        final last = events.last;
        expect(last, isA<ErrorEvent>());
        expect((last as ErrorEvent).error.errorMessage, contains('boom'));
      });

      test('the sleeper bailing out (cancel/abort) outranks the ladder — the '
          'held-back stall error stands, no further attempt', () async {
        var attempts = 0;
        final policy = SilentStreamPolicy(
          innerBuilder: () => stallInner(5, onAttempt: (_) => attempts++),
          sleeper: (_, _) async => false, // the abort-aware sleeper lost
        );
        final events = await policy
            .call(model, const Context(messages: []))
            .toList();
        expect(attempts, 1, reason: 'no second attempt after the bail-out');
        expect(events.last, isA<ErrorEvent>());
      });

      test('a takeover that SERVES (Done) resets the run counter — the next '
          'call costs the first backoff again', () async {
        final ledger = ProviderStallLedger();
        final slept = <Duration>[];
        // Scripted by SHARED attempt number (the policy rebuilds the inner
        // every attempt): attempts 1-3 stall (call 1 escalates to the
        // takeover, which serves), attempt 4 stalls (the first stall of
        // call 2), attempt 5+ succeed.
        var attempt = 0;
        final policy = SilentStreamPolicy(
          innerBuilder: () => (m, c, {cancelToken}) {
            final n = ++attempt;
            final out = AssistantMessageEventStream();
            unawaited(() async {
              out.push(
                n <= 4
                    ? ErrorEvent(
                        reason: StopReason.error,
                        error: _error(idleError),
                      )
                    : DoneEvent(reason: StopReason.stop, message: _error('ok')),
              );
              out.end();
            }());
            return out;
          },
          hooks: SilentStreamPolicyHooks(
            buildTakeover: () => (m, c, {cancelToken}) {
              final out = AssistantMessageEventStream();
              unawaited(() async {
                out.push(
                  DoneEvent(reason: StopReason.stop, message: _error('smol')),
                );
                out.end();
              }());
              return out;
            },
          ),
          sleeper: (d, _) async {
            slept.add(d);
            return true;
          },
          ledger: ledger,
        );
        final first = await policy
            .call(model, const Context(messages: []))
            .toList();
        expect(first.last, isA<DoneEvent>(), reason: 'the takeover serves');
        expect(slept, [
          const Duration(seconds: 5),
          const Duration(seconds: 10),
          const Duration(seconds: 20),
        ]);
        final second = await policy
            .call(model, const Context(messages: []))
            .toList();
        expect(second.last, isA<DoneEvent>());
        expect(
          slept.sublist(3),
          [const Duration(seconds: 5)],
          reason:
              'AC4: the takeover-Done reset the counter, so call 2\'s '
              'first stall is stall 1 again (5 s), not an escalated delay',
        );
      });

      test('a takeover stream that ends SILENTLY (no terminal) → the original '
          'stall error stands', () async {
        final notices = <String>[];
        final policy = SilentStreamPolicy(
          innerBuilder: () => stallInner(3),
          hooks: SilentStreamPolicyHooks(
            onNotice: notices.add,
            buildTakeover: () => (m, c, {cancelToken}) {
              final out = AssistantMessageEventStream();
              out.end(); // no terminal at all — the silent death
              return out;
            },
          ),
          sleeper: (_, _) async => true,
        );
        final events = await policy
            .call(model, const Context(messages: []))
            .toList();
        expect(events.last, isA<ErrorEvent>());
        expect(notices.join('\n'), contains('smol-role takeover'));
      });

      test(
        '#964 replay guard counts EVERY content-bearing event kind — a '
        'thinking/tool stream that stalls after content is never replayed',
        () async {
          final slept = <Duration>[];
          final policy = SilentStreamPolicy(
            innerBuilder: () => (m, c, {cancelToken}) {
              final out = AssistantMessageEventStream();
              unawaited(() async {
                out.push(
                  ThinkingStartEvent(contentIndex: 0, partial: partial()),
                );
                out.push(
                  ThinkingDeltaEvent(
                    contentIndex: 0,
                    delta: 'hmm',
                    partial: partial(),
                  ),
                );
                out.push(
                  ThinkingEndEvent(
                    contentIndex: 0,
                    content: 'hmm',
                    partial: partial(),
                  ),
                );
                out.push(
                  ToolCallStartEvent(contentIndex: 1, partial: partial()),
                );
                out.push(
                  ToolCallDeltaEvent(
                    contentIndex: 1,
                    delta: '{"a"',
                    partial: partial(),
                  ),
                );
                out.push(
                  ToolCallEndEvent(
                    contentIndex: 1,
                    toolCall: ToolCall(
                      id: 't1',
                      name: 'shell',
                      arguments: const {'a': 1},
                    ),
                    partial: partial(),
                  ),
                );
                out.push(
                  TextDeltaEvent(
                    contentIndex: 2,
                    delta: 'answer',
                    partial: partial(),
                  ),
                );
                out.push(
                  ErrorEvent(
                    reason: StopReason.error,
                    error: _error(idleError),
                  ),
                );
                out.end();
              }());
              return out;
            },
            sleeper: (d, _) async {
              slept.add(d);
              return true;
            },
          );
          final events = await policy
              .call(model, const Context(messages: []))
              .toList();
          expect(slept, isEmpty, reason: 'post-commit content → no ladder');
          expect(events.last, isA<ErrorEvent>());
        },
      );
    },
  );
}
