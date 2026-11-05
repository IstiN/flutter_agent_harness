// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The shared host compaction flow (gh-2059): ONE settle / relief / manual
/// compaction path + the under-window re-fire ladder that every SDK host
/// can run, wired through the gh-1077 host wiring
/// ([resolveCompactionHostWiring]) instead of per-host hand-rolls.
///
/// Why this exists: the extension SW host ran its own settle-only
/// compaction with `CompactionSettings.forWindow` of a hard-coded window,
/// silent hooks, no over-window relief and no `/compact` — the live
/// incident dead-ended at ~128,040/128,000 tokens with zero diagnostics.
/// The CLI and the app each keep their own rich wrappers (TUI report
/// blocks, in-chat notices); this flow gives the THIN hosts the same
/// contract in one place:
///
/// - **settle** — the post-run trigger-gated pass (app `_maybeAutoCompact`
///   semantics: gated on [shouldCompact] over the wiring's conversation
///   window, request-basis estimates);
/// - **relief** — the loop guard's ONE synchronous compaction before it
///   refuses (issue #387; returns the relieved list or null, the loop
///   re-measures and refuses visibly);
/// - **manual** — `/compact` CLI parity: unconditional, with a
///   before/after-token panel notice;
/// - **the re-fire ladder** — after ANY path, the live context is
///   re-measured; still over the effective window → exactly one more run
///   (AC5); ladder exhausted and still not under the trigger → a VISIBLE
///   failure notice, transcript intact. The incident's silent
///   "compacted but still refused forever" state is unrepresentable.
/// - **cancel parity** (issue #1085) — a cancelled compaction surfaces as
///   cancelled, never as a failed pass a funnel would re-launch;
/// - **visibility** (gh-1077 AC2 + AC11) — every pass emits a log line on
///   the host's diagnostics channel; failures additionally fire a panel
///   notice. The log alone answers "did a pass run, what did it drop, why
///   did it fail".
///
/// Pure Dart: the host injects its notices channel and its summarizer
/// streams; nothing here touches chrome.*, dart:io or the panel wire.
library;

import '../agent/agent.dart' show AgentState;
import '../agent/auto_compactor.dart';
import '../cancel_token.dart';
import '../session/session_tree.dart' show Session;
import '../skills/skills.dart' show Skill;
import '../types.dart' show Message;
import 'compaction.dart';
import 'host_wiring.dart';
import 'token_estimation.dart' show estimateRequestTokens;

export 'compaction.dart' show CompactionPrompts;

/// Which host path asked for the compaction — names every log line and
/// receipt so the SW console alone answers "which path ran" (AC11).
enum HostCompactionPath {
  /// The post-run trigger-gated pass (the settle hook).
  settle,

  /// The loop guard's synchronous pre-refusal compaction (issue #387).
  relief,

  /// The user's explicit `/compact` (CLI parity: unconditional).
  manual,
}

/// Outcome of one [HostCompactionFlow] path run.
final class HostCompactionReceipt {
  const HostCompactionReceipt({
    required this.path,
    required this.attempted,
    required this.ran,
    required this.cancelled,
    required this.underTrigger,
    required this.tokensBefore,
    required this.tokensAfter,
    this.runs = 0,
    this.passes = 0,
    this.error,
  });

  /// Which path produced this receipt.
  final HostCompactionPath path;

  /// Whether a compaction attempt was made at all (false = gated off /
  /// nothing to compact / cancelled before start).
  final bool attempted;

  /// Whether the underlying [AutoCompactor] actually ran passes.
  final bool ran;

  /// The run was cancelled (issue #1085 parity) — never report it as a
  /// failed pass; hosts must not re-fire or funnel it.
  final bool cancelled;

  /// Whether the live context landed under the compaction trigger
  /// (`window - reserveTokens`) at the end — the AC3 invariant basis.
  final bool underTrigger;

  /// Request-basis token estimate before the run.
  final int tokensBefore;

  /// Request-basis token estimate after the run.
  final int tokensAfter;

  /// Full compactor runs the path made, re-fires included (AC5's bound).
  final int runs;

  /// Passes the underlying compactors reported.
  final int passes;

  /// The last error a failed ladder saw, when there was one.
  final Object? error;

  /// Whether the path recovered the context (under trigger, not cancelled).
  bool get success => underTrigger && !cancelled;
}

/// The host's two visibility channels (gh-1077 AC2 / AC4 / AC11). The
/// extension impl forwards [log] to the `[fah][sw]` console + debug relay
/// and [notice] to the panel as a system notice; tests record both.
abstract class HostCompactionNotices {
  /// One diagnostics line per flow step and per compactor pass — the
  /// host's log channel (SW console / fa.log / debug relay).
  void log(String line);

  /// A user-visible system notice (failures, manual receipts, relief
  /// receipts) — the panel/chat surface.
  void notice(String text);
}

/// The failure notice lead (gh-1077 AC2 shape — the app's wording names
/// where to fix the summarizer; thin hosts have no settings tree, so this
/// names the provider connection and the manual recovery commands).
const String hostCompactionFailureNoticeLead =
    'Context compaction failed — nothing was summarized and no history was '
    'lost. Check the provider connection, then run /compact or start a '
    'fresh session.';

/// The full failure notice: the lead plus the underlying error.
String hostCompactionFailureNotice(Object error) =>
    '$hostCompactionFailureNoticeLead\n$error';

/// The manual `/compact` receipt: before → after tokens (AC2).
String hostCompactionManualReceipt(
  int tokensBefore,
  int tokensAfter,
  int passes,
) =>
    'Context compacted: $tokensBefore → $tokensAfter tokens '
    '($passes ${passes == 1 ? 'pass' : 'passes'}).';

/// The relief receipt: the loop resumes on the compacted context (CLI
/// prints a dim `[resuming]` line; thin hosts surface the same fact as a
/// system notice).
String hostCompactionReliefReceipt(int tokensBefore, int tokensAfter) =>
    'Context compacted automatically: $tokensBefore → $tokensAfter tokens '
    '— resuming.';

/// Runs one host compaction path end-to-end: gate → AutoCompactor run →
/// re-measure → (one) re-fire → receipt + notices. All compaction config
/// comes from the shared [CompactionHostWiring]; nothing is hand-rolled.
///
/// NOT const-constructible: the relief counter and the last-receipt slot
/// are per-flow mutable state/test seams.
final class HostCompactionFlow {
  HostCompactionFlow({
    required this.session,
    required this.state,
    required this.wiring,
    required this.sources,
    required this.notices,
    this.engine = CompactionEngine.structured,
    this.prompts = defaultCompactionPrompts,
    this.operativeSkills = const [],
    this.maxRefires = 1,
    this.attemptBudget = const Duration(seconds: 300),
    this.totalBudget = const Duration(minutes: 15),
  });

  /// The session to compact (the compactor reads the projected transcript
  /// from it and appends the fold records).
  final Session session;

  /// Live agent state; the compactor replaces [AgentState.messages] on a
  /// successful pass (atomically, from the host's perspective).
  final AgentState state;

  /// The shared wiring (window / thresholds / enabled) — the ONLY config
  /// source, resolved by the host through `resolveCompactionHostWiring`.
  final CompactionHostWiring wiring;

  /// The summarizer streams (extension shape: smol == main).
  final AutoCompactorSources sources;

  /// The host's visibility channels.
  final HostCompactionNotices notices;

  /// Which compaction engine runs (the SDK default — hosts with a config
  /// chain pass their resolved value).
  final CompactionEngine engine;

  /// Summarization prompt overrides.
  final CompactionPrompts prompts;

  /// gh-1409: the session's operative skills pinned onto every prompt.
  final List<Skill> operativeSkills;

  /// How many times a still-over-window context re-fires one more run
  /// after a pass left it over (AC5: exactly one, then the failure
  /// notice — bounded, never an infinite loop).
  final int maxRefires;

  /// Per-attempt and whole-run budgets, forwarded to the compactor.
  final Duration attemptBudget;
  final Duration totalBudget;

  /// Request-basis estimate of the live context (the ONE basis the loop's
  /// over-window guard and the compaction trigger share).
  int liveTokens() => estimateRequestTokens(
    state.messages,
    systemPrompt: state.systemPrompt,
    tools: state.tools,
  );

  /// Whether the live context is past the hard refusal line (the effective
  /// window) — the loop guard's basis.
  bool overWindow() => liveTokens() >= wiring.window;

  /// Whether the live context is past the compaction trigger.
  bool overTrigger() =>
      shouldCompact(liveTokens(), wiring.conversationWindow, wiring.settings);

  /// Relief counter (AC1): how many times the guard's relief closure ran.
  /// Hosts expose this for tests exactly like the app's
  /// `overWindowReliefCountForTest`.
  int reliefCountForTest = 0;

  /// The receipt of the last completed path run — relief returns a list,
  /// so tests read its receipt here (the AC3 property basis).
  HostCompactionReceipt? lastReceiptForTest;

  /// The last error the compactor hooks reported (failed pass / both
  /// summarizers down) — the ladder verdict and the failure notice carry
  /// it so the log alone answers "why did it fail" (AC11).
  Object? _lastHookError;

  /// The post-run settle path: trigger-gated, cancel-aware. Returns the
  /// receipt; a not-attempted run is a success-shaped no-op.
  Future<HostCompactionReceipt> settle({CancelToken? runToken}) =>
      _run(HostCompactionPath.settle, force: false, runToken: runToken);

  /// The `/compact` path: unconditional (the user asked — CLI parity),
  /// cancel-aware, with a before/after-token notice.
  Future<HostCompactionReceipt> manual({CancelToken? runToken}) =>
      _run(HostCompactionPath.manual, force: true, runToken: runToken);

  /// The loop guard's relief (issue #387): ONE synchronous compaction over
  /// the over-window transcript, with the under-window re-fire ladder.
  /// Returns the relieved list for the loop's single retry, or null when
  /// nothing shrank (or the run was cancelled — the loop then surfaces the
  /// guard error / the aborted turn; both visible).
  Future<List<Message>?> relieveOverWindow(
    List<Message> overWindow, {
    CancelToken? runToken,
  }) async {
    reliefCountForTest++;
    if (runToken?.isCancelled ?? false) return null;
    final beforeTokens = estimateRequestTokens(
      overWindow,
      systemPrompt: state.systemPrompt,
      tools: state.tools,
    );
    final receipt = await _run(
      HostCompactionPath.relief,
      force: false,
      runToken: runToken,
    );
    if (receipt.cancelled) return null;
    final after = state.messages.toList();
    final afterTokens = receipt.tokensAfter;
    if (afterTokens >= beforeTokens) {
      notices.log('[compaction] relief no-op (nothing shrank)');
      return null;
    }
    notices.log(
      '[compaction] relief done tokens=$afterTokens (was $beforeTokens, '
      '${after.length} messages)',
    );
    notices.notice(hostCompactionReliefReceipt(beforeTokens, afterTokens));
    return after;
  }

  /// The shared path runner: gate → run (with the ladder) → receipt.
  Future<HostCompactionReceipt> _run(
    HostCompactionPath path, {
    required bool force,
    required CancelToken? runToken,
  }) async {
    final gate = _gate(path, force: force, runToken: runToken);
    if (gate != null) return gate;

    final tokensBefore = liveTokens();
    notices.log(
      '[compaction] $path start tokens=$tokensBefore window=${wiring.window} '
      'trigger=${wiring.conversationWindow - wiring.settings.reserveTokens}',
    );

    final tally = await _runLadder(force: force, runToken: runToken);
    return _finish(
      path,
      tokensBefore: tokensBefore,
      tally: tally,
      runToken: runToken,
    );
  }

  /// The pre-run gates, each with its not-attempted / cancelled receipt:
  /// the master switch, the manual empty-transcript guard, the settle
  /// trigger gate, and the cancel that arrived before the first pass
  /// (issue #1085 — no factory run, no failed-pass verdict).
  HostCompactionReceipt? _gate(
    HostCompactionPath path, {
    required bool force,
    required CancelToken? runToken,
  }) {
    if (!wiring.enabled) {
      return _notAttempted(path);
    }
    if (path == HostCompactionPath.manual && state.messages.isEmpty) {
      notices.notice('nothing to compact');
      return _notAttempted(path);
    }
    if (!force && !overTrigger()) {
      return _notAttempted(path);
    }
    if (runToken?.isCancelled ?? false) {
      notices.log('[compaction] $path cancelled before the first pass');
      if (path == HostCompactionPath.manual) {
        notices.notice('compaction interrupted');
      }
      return _cancelledReceipt(path);
    }
    return null;
  }

  /// The re-fire ladder (AC5): a run that leaves the context over the
  /// window gets exactly one more run per [maxRefires], then the flow
  /// gives up VISIBLY. Bounded — no infinite loop.
  Future<_LadderTally> _runLadder({
    required bool force,
    required CancelToken? runToken,
  }) async {
    var runs = 0;
    var passes = 0;
    var everRan = false;
    var cancelled = false;
    Object? lastError;
    for (var attempt = 0; attempt <= maxRefires; attempt++) {
      if (attempt > 0) {
        notices.log(
          '[compaction] re-fire $attempt/$maxRefires: context still over '
          'the window (${liveTokens()} >= ${wiring.window})',
        );
      }
      runs++;
      _lastHookError = null;
      int ranPasses;
      try {
        ranPasses = await _runCompactorOnce(
          force: force || attempt > 0,
          runToken: runToken,
        );
      } on CancelledException catch (error) {
        // Cancel parity (issue #1085): the factory throws out of any run
        // the token touched — surface cancelled, never a failed pass.
        cancelled = true;
        lastError = error;
        break;
      } on Object catch (error) {
        // A throwing run (engine crash, unresolvable chain) is a failed
        // attempt like any other: the ladder verdict + the failure notice
        // carry the error instead of crashing the host.
        lastError = error;
        break;
      }
      if (ranPasses > 0) everRan = true;
      passes += ranPasses;
      // A run whose passes all failed (both summarizers down, trim null)
      // reports through the hooks, not by throwing — carry its error into
      // the verdict + the failure notice (AC11: why did it fail).
      lastError ??= _lastHookError;
      if (!overWindow()) break;
    }
    return _LadderTally(
      runs: runs,
      passes: passes,
      everRan: everRan,
      cancelled: cancelled,
      error: lastError,
    );
  }

  /// Post-ladder verdict: the done/failure/interrupt reporting and the
  /// receipt. Cancel parity — a cancelled compaction NEVER reads as a
  /// failed pass (issue #1085 round-4) — no failure notice, no funnel.
  HostCompactionReceipt _finish(
    HostCompactionPath path, {
    required int tokensBefore,
    required _LadderTally tally,
    required CancelToken? runToken,
  }) {
    final afterTokens = liveTokens();
    final underTrigger = !shouldCompact(
      afterTokens,
      wiring.conversationWindow,
      wiring.settings,
    );
    final cancelled = tally.cancelled || (runToken?.isCancelled ?? false);
    _reportOutcome(
      path,
      cancelled: cancelled,
      underTrigger: underTrigger,
      tokensBefore: tokensBefore,
      afterTokens: afterTokens,
      tally: tally,
    );

    return lastReceiptForTest = HostCompactionReceipt(
      path: path,
      attempted: true,
      ran: tally.everRan,
      cancelled: cancelled,
      underTrigger: underTrigger,
      tokensBefore: tokensBefore,
      tokensAfter: afterTokens,
      runs: tally.runs,
      passes: tally.passes,
      error: tally.error,
    );
  }

  /// The visibility half of the verdict (AC3/AC4/AC5/AC11): the done log
  /// on every completed path, the failure notice + detail line on a
  /// ladder that ended over the trigger, the interrupt notice on a
  /// cancelled manual `/compact`, and the manual before/after receipt.
  void _reportOutcome(
    HostCompactionPath path, {
    required bool cancelled,
    required bool underTrigger,
    required int tokensBefore,
    required int afterTokens,
    required _LadderTally tally,
  }) {
    if (cancelled) {
      notices.log('[compaction] $path cancelled');
      if (path == HostCompactionPath.manual) {
        notices.notice('compaction interrupted');
      }
      return;
    }
    notices.log(
      '[compaction] $path done '
      '${underTrigger ? 'ok' : 'failed'} '
      'tokens=$tokensBefore→$afterTokens passes=${tally.passes} '
      'runs=${tally.runs} window=${wiring.window}',
    );

    // A miss must be VISIBLE: ladder exhausted (or the runs failed) and
    // the context is still over the trigger → the panel hears about it,
    // the transcript stays intact (the compactor's folds are lossless and
    // the local trim never silently dropped anything here).
    if (!underTrigger) {
      notices.notice(
        hostCompactionFailureNotice(
          tally.error ??
              'the context is still over the compaction trigger '
                  '($afterTokens tokens, window ${wiring.window}) after '
                  '${tally.runs} compaction '
                  '${tally.runs == 1 ? 'run' : 'runs'}',
        ),
      );
      notices.log(
        '[compaction] $path failure detail: ${tally.error ?? 'runs exhausted '
                'with the context still over the trigger'}',
      );
      return;
    }
    // The manual path receipts on success too (AC2: before/after tokens).
    if (path == HostCompactionPath.manual && state.messages.isNotEmpty) {
      notices.notice(
        hostCompactionManualReceipt(tokensBefore, afterTokens, tally.passes),
      );
    }
  }

  HostCompactionReceipt _notAttempted(HostCompactionPath path) =>
      lastReceiptForTest = HostCompactionReceipt(
        path: path,
        attempted: false,
        ran: false,
        cancelled: false,
        underTrigger: !overTrigger(),
        tokensBefore: liveTokens(),
        tokensAfter: liveTokens(),
      );

  HostCompactionReceipt _cancelledReceipt(HostCompactionPath path) =>
      lastReceiptForTest = HostCompactionReceipt(
        path: path,
        attempted: false,
        ran: false,
        cancelled: true,
        underTrigger: !overTrigger(),
        tokensBefore: liveTokens(),
        tokensAfter: liveTokens(),
      );

  /// One full [AutoCompactorFactory] run; returns the pass count it
  /// reported through the hooks.
  Future<int> _runCompactorOnce({
    required bool force,
    required CancelToken? runToken,
  }) async {
    var passes = 0;
    final hooks = _FlowHooks(this, (count) => passes += count);
    final compactor = AutoCompactorFactory(
      session: session,
      state: state,
      window: wiring.conversationWindow,
      settings: wiring.settings,
      sources: sources,
      hooks: hooks,
      prompts: prompts,
      operativeSkills: operativeSkills,
      maxAttempts: wiring.maxAttempts,
      baseBackoff: wiring.baseBackoff,
      force: force,
      attemptBudget: attemptBudget,
      totalBudget: totalBudget,
      engine: engine,
      runToken: runToken,
    );
    await compactor.run();
    return passes;
  }
}

/// The ladder's terminal tally — the input the receipt builder
/// ([HostCompactionFlow._finish]) turns into the public receipt.
final class _LadderTally {
  const _LadderTally({
    required this.runs,
    required this.passes,
    required this.everRan,
    required this.cancelled,
    required this.error,
  });

  /// Full compactor runs the path made, re-fires included (AC5's bound).
  final int runs;

  /// Passes the underlying compactors reported.
  final int passes;

  /// Whether any run reported at least one pass.
  final bool everRan;

  /// A run was cancelled (issue #1085 parity).
  final bool cancelled;

  /// The last error a failed ladder saw, when there was one.
  final Object? error;
}

/// Maps the compactor's [AutoCompactorHooks] onto the flow's notice
/// channels and counts passes (AC4: every pass emits ≥1 log line).
final class _FlowHooks implements AutoCompactorHooks {
  _FlowHooks(this._flow, this._onPassCounted);

  final HostCompactionFlow _flow;
  final void Function(int) _onPassCounted;

  @override
  void onDelta(String delta) {}

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {
    _flow.notices.log(
      '[compaction] attempt $attempt on $label (budget ${budget.inSeconds}s)',
    );
  }

  @override
  void onPass(AutoCompactorPass pass) {
    _onPassCounted(1);
    final where = pass.fallback ?? 'none';
    if (pass.ok) {
      _flow.notices.log(
        '[compaction] pass ${pass.pass} $where ok '
        'tokens=${pass.tokensBefore}→${pass.tokensAfter}'
        '${pass.summary != null ? ' summarized=${pass.summarizedMessages}' : ''}'
        '${pass.droppedMessages > 0 ? ' dropped=${pass.droppedMessages}' : ''}'
        '${pass.hiddenRecords > 0 ? ' hidden=${pass.hiddenRecords}' : ''}',
      );
    } else {
      _flow._lastHookError = pass.error;
      _flow.notices.log(
        '[compaction] pass ${pass.pass} $where failed: ${pass.error}',
      );
    }
  }

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {
    _flow.notices.log(
      '[compaction] attempt $attempt/$maxAttempts retrying in '
      '${backoff.inSeconds}s after: $error',
    );
  }

  @override
  void onDone(int passes, int tokens) {
    _flow.notices.log(
      '[compaction] compactor done passes=$passes tokens=$tokens',
    );
  }

  @override
  void onBothRolesFailed(Object lastError) {
    _flow._lastHookError = lastError;
    _flow.notices.log('[compaction] both summarizers failed: $lastError');
  }
}
