/// SilentStreamPolicy (gh-1395 AC4): the bounded, ESCALATING recovery for
/// alive-but-silent provider streams.
///
/// The bench (round 2) measured the naive recovery — replay a stalled
/// request on the same wedged upstream state — at 1/13: the replay re-hangs
/// and costs another full idle-watchdog window. This policy replaces the
/// blind replay with a bounded ladder that spends its escalations on
/// something the bare retry never tried:
///
/// - stall 1 → codex-style backoff ([stallBackoffDelay]: 5 s, doubling,
///   capped at 60 s — every delay within [5, 60]), then replay;
/// - stall 2 → backoff, then KEY ROTATION ([SilentStreamPolicyHooks
///   .rotateKey] — a wedged gateway may be key-scoped; one key on the ring
///   skips it with a logged reason, E5);
/// - stall 3 → backoff, then the SMOL-ROLE TAKEOVER attempt
///   ([SilentStreamPolicyHooks.buildTakeover] — the roles fallback chain
///   already exists; the stall counter hands it a bounded turn);
/// - a successful response RESETS the stall counter (AC4);
/// - past the budget the stall error STANDS — the roles ladder's existing
///   transport classification takes over from there (unchanged behavior,
///   REG-safe).
///
/// Discipline kept from the transient ladder (#964): a stream that already
/// emitted observable content is never replayed from scratch — a POST-commit
/// stall (mid-stream silence after visible deltas) is not this ladder's
/// case; the error stands for the roles machinery to resume/stand as it
/// does today. The policy only ladders PRE-commit stalls (first-byte
/// silence — the bench's zero-byte class).
///
/// Non-stall failures never enter the ladder (E1's distinct policy
/// entries): connect stalls already replay in place inside
/// `sendWatchedProviderRequest`; rate limits, transport drops and 5xx
/// belong to the roles rotation.
library;

import 'dart:async';

import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../model.dart';
import '../types.dart';
import 'stall_taxonomy.dart';
import 'transient_retry_stream.dart' show transientRetrySleeper;

/// The stall backoff ladder (AC4): `min(base * 2^(n-1), max)` with base
/// 5 s and cap 60 s — delays 5 s, 10 s, 20 s, 40 s, 60 s, 60 s, … Every
/// delay is within [5, 60] seconds (asserted by UT).
Duration stallBackoffDelay(
  int stallNumber, {
  Duration base = const Duration(seconds: 5),
  Duration max = const Duration(seconds: 60),
}) {
  if (stallNumber <= 1) return base;
  var delay = base;
  for (var i = 1; i < stallNumber; i++) {
    delay = delay * 2;
    if (delay >= max) return max;
  }
  return delay < max ? delay : max;
}

/// The cross-call stall ledger (E3): consecutive stalls per RUN key, reset
/// on success. Keyed by the run's [CancelToken] identity (each run/steering
/// takeover mints a fresh token, so a takeover cannot double-count a prior
/// run's stalls); a null token shares the anonymous bucket.
final class ProviderStallLedger {
  final _consecutive = <Object?, int>{};

  /// Records a stall for [runKey], returning the consecutive-stall count
  /// (1 = the first).
  int recordStall(Object? runKey) {
    final next = (_consecutive[runKey] ?? 0) + 1;
    _consecutive[runKey] = next;
    return next;
  }

  /// The consecutive-stall count for [runKey] without recording one.
  int count(Object? runKey) => _consecutive[runKey] ?? 0;

  /// Clears the count (a successful response — AC4's reset).
  void reset(Object? runKey) {
    _consecutive.remove(runKey);
  }
}

/// The escalation hooks the host/resolver wires (the roles chain owns the
/// key rings and the smol role; this file stays below model_roles/).
final class SilentStreamPolicyHooks {
  /// Creates the hooks. All-const default = no escalation available (the
  /// ladder then only backs off and, past its budget, stands the error).
  const SilentStreamPolicyHooks({
    this.rotateKey,
    this.buildTakeover,
    this.onNotice,
  });

  /// Attempts an API-key rotation for the current entry; `true` = rotated
  /// (the next attempt rebuilds the inner stream via [SilentStreamPolicy
  /// .innerBuilder] and picks up the rotated credential), `false` = no
  /// other key exists (E5: logged, the same key is retried).
  final bool Function()? rotateKey;

  /// Builds the takeover stream (the smol role's chain call), or `null`
  /// when no takeover target exists (E5-adjacent: logged, the stall error
  /// stands for the roles ladder).
  final StreamFunction? Function()? buildTakeover;

  /// Human-visible policy notes (the `[net]`/fa.log surface through the
  /// resolver's notice plumbing).
  final void Function(String note)? onNotice;
}

/// The bounded stall-recovery wrapper. One instance per roles-chain entry
/// (session-scoped: the counter survives across calls until a success
/// resets it — AC4).
final class SilentStreamPolicy {
  /// Creates the policy. [innerBuilder] is invoked for every attempt so a
  /// rotation (or any rebuild trigger) rebinds the underlying stream.
  SilentStreamPolicy({
    required StreamFunction Function() innerBuilder,
    this.hooks = const SilentStreamPolicyHooks(),
    this.maxStallEscalations = 3,
    this.sleeper,
    ProviderStallLedger? ledger,
    // ignore: prefer_initializing_formals
  }) : _innerBuilder = innerBuilder,
       ledger = ledger ?? ProviderStallLedger();

  final StreamFunction Function() _innerBuilder;

  /// The escalation hooks (rotation / takeover / notices).
  final SilentStreamPolicyHooks hooks;

  /// How many stalls ONE call escalates through (stall 3 = the takeover;
  /// the takeover attempt is always the ladder's last word).
  final int maxStallEscalations;

  /// Injected sleep (tests' fake clock); defaults to the harness'
  /// cancel-aware retry sleeper.
  Future<bool> Function(Duration delay, CancelToken? cancelToken)? sleeper;

  /// The cross-call ledger (one per entry by default).
  late final ProviderStallLedger ledger;

  /// The stall-laddered stream.
  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final out = AssistantMessageEventStream();
    unawaited(
      _drive(out, model, context, cancelToken)
          .catchError((Object error, StackTrace stackTrace) {
            // Defensive (providers never throw; a fake in tests might).
            out.push(
              ErrorEvent(
                reason: StopReason.error,
                error: AssistantMessage(
                  content: const [],
                  api: model.api,
                  provider: model.provider,
                  model: model.id,
                  usage: Usage.zero,
                  stopReason: StopReason.error,
                  errorMessage: '$error',
                  timestamp: DateTime.now(),
                ),
              ),
            );
          })
          .whenComplete(out.end),
    );
    return out;
  }

  Future<void> _drive(
    AssistantMessageEventStream out,
    Model model,
    Context context,
    CancelToken? cancelToken,
  ) async {
    final runKey = cancelToken; // E3: the run identity
    var stallInCall = 0;
    while (true) {
      final inner = _innerBuilder();
      final (:terminal, :events) = await _runAttempt(
        inner,
        model,
        context,
        out,
        cancelToken,
      );
      final eventsBefore = events;
      if (terminal is DoneEvent) {
        ledger.reset(runKey); // AC4: success resets the counter
        return;
      }
      if (terminal is! ErrorEvent) {
        return; // no terminal — the defensive catch already handled it
      }
      final message = terminal.error;
      final stall = classifyProviderStall(
        message.errorMessage,
        eventsSeen: eventsBefore,
      );
      // Only a PRE-commit idle stall ladders (#964: post-commit content is
      // never replayed from scratch; connect stalls replay in place in the
      // send layer — E1's distinct policy entries).
      if (stall == null ||
          stall.kind == ProviderStallKind.connectStall ||
          eventsBefore > 0) {
        out.push(terminal); // stands — the roles ladder classifies as today
        return;
      }
      stallInCall++;
      final runStallNumber = ledger.recordStall(runKey);
      final delay = stallBackoffDelay(runStallNumber);
      hooks.onNotice?.call(
        '[stall] ${stall.label}: retrying in ${delay.inSeconds}s '
        '(stall $runStallNumber of the run)',
      );
      final survived = await (sleeper ?? transientRetrySleeper)(
        delay,
        cancelToken,
      );
      if (!survived) {
        cancelToken?.throwIfCancelled();
        out.push(terminal); // the user abort outranks the ladder
        return;
      }
      if (stallInCall == 2) {
        final rotated = hooks.rotateKey?.call() ?? false;
        hooks.onNotice?.call(
          rotated
              ? '[stall] rotating API key after the 2nd stall'
              : '[stall] rotation unavailable (single key on the ring) — '
                    'retrying the same credential',
        );
      }
      if (stallInCall == maxStallEscalations) {
        final takeover = hooks.buildTakeover?.call();
        if (takeover == null) {
          hooks.onNotice?.call(
            '[stall] no smol takeover target configured — standing the '
            'error for the roles ladder',
          );
          out.push(terminal);
          return;
        }
        hooks.onNotice?.call(
          '[stall] 3rd stall of the run — attempting the smol-role takeover',
        );
        final takeoverOutcome = await _runAttempt(
          takeover,
          model,
          context,
          out,
          cancelToken,
        );
        final takeoverTerminal = takeoverOutcome.terminal;
        if (takeoverTerminal is DoneEvent) {
          ledger.reset(runKey);
        } else if (takeoverTerminal is ErrorEvent) {
          out.push(takeoverTerminal); // the takeover's own failure stands
        } else if (takeoverTerminal == null) {
          out.push(terminal); // the takeover died silently — stand the stall
        }
        return; // the takeover attempt is the ladder's last word
      }
    }
  }

  /// Runs one attempt: content events forward LIVE (streaming stays
  /// streaming), the DoneEvent forwards and ends the decision, while a
  /// terminal ErrorEvent is HELD BACK and only returned — the ladder
  /// decides whether it stands or a replay drops it (the event stream
  /// completes on its first terminal, so forwarding a stall error early
  /// would deadlock the escalation).
  ///
  /// Returns the terminal event (or null when the stream ended without
  /// one) and how many CONTENT-bearing events were observed before it
  /// (the #964 commit guard + the taxonomy's first-byte / mid-stream
  /// split — a bare [StartEvent] carries no visible content).
  Future<({AssistantMessageEvent? terminal, int events})> _runAttempt(
    StreamFunction inner,
    Model model,
    Context context,
    AssistantMessageEventStream out,
    CancelToken? cancelToken,
  ) async {
    var seen = 0;
    await for (final event in inner(model, context, cancelToken: cancelToken)) {
      if (event is DoneEvent) {
        out.push(event);
        return (terminal: event, events: seen);
      }
      if (event is ErrorEvent) {
        return (terminal: event, events: seen); // held for the ladder
      }
      out.push(event);
      if (_isCommitEvent(event)) seen++;
    }
    return (terminal: null, events: seen);
  }
}

/// Whether [event] carries OBSERVABLE content (the #964 commit guard: a
/// replay may never follow content the host already rendered). A bare
/// [StartEvent] (the model started; nothing visible) is pre-commit.
bool _isCommitEvent(AssistantMessageEvent event) => switch (event) {
  StartEvent() || DoneEvent() || ErrorEvent() => false,
  TextStartEvent() ||
  TextDeltaEvent() ||
  TextEndEvent() ||
  ThinkingStartEvent() ||
  ThinkingDeltaEvent() ||
  ThinkingEndEvent() ||
  ToolCallStartEvent() ||
  ToolCallDeltaEvent() ||
  ToolCallEndEvent() => true,
};

/// Convenience: wraps [inner] (statically bound) with the policy — the
/// resolver's seam when no rebuild-on-rotation is needed beyond the
/// [hooks].
StreamFunction silentStreamPolicyFunction(
  StreamFunction Function() innerBuilder, {
  SilentStreamPolicyHooks hooks = const SilentStreamPolicyHooks(),
  Future<bool> Function(Duration delay, CancelToken? cancelToken)? sleeper,
  ProviderStallLedger? ledger,
}) {
  final policy = SilentStreamPolicy(
    innerBuilder: innerBuilder,
    hooks: hooks,
    sleeper: sleeper,
    ledger: ledger,
  );
  return policy.call;
}
