/// Auto-compaction loop shared by the CLI [AgentCli] and the Flutter
/// [AgentService]. Single source of truth for:
///
/// - **smol → main fallback**: when the `smol` summarizer fails (rate
///   limit, 403, etc.) and points at a different model/endpoint than the
///   main chain, retry once with the main stream. If `smol == main`,
///   skip the fallback (it would just re-trigger the same 403).
/// - **Transient retry**: 5xx HTTP, `connection closed/reset/aborted`,
///   `socket exception`, `stream closed` — up to 3 attempts with
///   1s/2s backoff. Hard refusals (`usage limit`, `429`, validation,
///   auth) fail-fast — retrying burns the same quota twice.
/// - **Multi-pass**: when the post-compaction transcript still exceeds
///   the window (e.g. 1M-token session landing in a 200k model,
///   short-window on-device contexts), retry the whole pass until it
///   fits or the per-run pass cap is hit. Each pass re-estimates tokens
///   against the freshly shrunken transcript.
///
/// Hosts inject the host-specific bits (smol resolver, summarizer,
/// persistence, progress sink) through the configuration object — there
/// is no implicit coupling to `AgentCli` or `AgentService`.
library;

import 'dart:async';

import '../compaction/compaction.dart';
import '../compaction/token_estimation.dart';
import '../context.dart';
import '../model.dart';
import '../session/session_tree.dart' show Session;
import '../types.dart';
import 'agent.dart' show AgentState;
import 'agent_loop.dart' show StreamFunction;

/// Per-pass outcome surfaced through [AutoCompactorHooks.onPass].
final class AutoCompactorPass {
  const AutoCompactorPass({
    required this.pass,
    required this.tokensBefore,
    required this.tokensAfter,
    required this.fallback,
    required this.ok,
    this.error,
  });

  /// 1-based pass number.
  final int pass;

  /// Estimated tokens before the pass.
  final int tokensBefore;

  /// Estimated tokens after the pass.
  final int tokensAfter;

  /// Which summarizer was used: `'smol'`, `'main'`, or `null` when the
  /// pass was skipped (no work to do).
  final String? fallback;

  /// Whether the pass succeeded.
  final bool ok;

  /// The error that failed the pass, when [ok] is `false`.
  final Object? error;
}

/// Hooks for a host UI to observe progress. Implementations should not
/// throw — the compactor swallows and logs around them.
abstract class AutoCompactorHooks {
  /// Called once per pass with its outcome. Used by the CLI TUI to print
  /// "auto-compacted N tokens summarized" and by the Flutter chat sheet
  /// to update the chat list.
  void onPass(AutoCompactorPass pass);

  /// Called when a pass retries on a transient error.
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error);

  /// Called once after the loop terminates, on success or exhaustion.
  void onDone(int passes, int tokens);

  /// Called when both smol and main failed in the same pass. The CLI
  /// prints a "switch models" hint here; the Flutter sheet shows a
  /// snackbar.
  void onBothRolesFailed(Object lastError);

  /// Streaming deltas (text + thinking) of the active summarization pass,
  /// so a host UI can show the summary being written instead of a silent
  /// spinner. Default no-op; high-frequency — hosts should throttle.
  void onDelta(String delta) {}

  /// Called when a summarization attempt starts, with the summarizer
  /// label (`smol=provider/model` / `main=provider/model`), the 1-based
  /// attempt number and the per-attempt budget. Hosts surface this in the
  /// busy row so a slow/dead summarizer endpoint reads as a bounded wait
  /// ("attempt 1, 90 s cap") instead of a silent hang. Default no-op.
  void onAttemptStart(String label, int attempt, Duration budget) {}
}

/// Compact helper that owns the multi-pass + retry + smol→main logic.
/// Hosts register a single [AutoCompactor.run] call after each run; the
/// helper handles everything else.
final class AutoCompactor {
  const AutoCompactor({
    required this.session,
    required this.state,
    required this.window,
    required this.settings,
    required this.summary,
    required this.mainSummary,
    required this.smolModel,
    required this.hooks,
    this.memoryExtractionHook,
    this.prompts = defaultCompactionPrompts,
    this.maxPasses = 8,
    this.maxAttempts = 3,
    this.baseBackoff = const Duration(seconds: 1),
    this.force = false,
    this.attemptBudget = const Duration(seconds: 90),
    this.totalBudget = const Duration(minutes: 4),
  });

  /// The session to compact and to read the projected transcript from.
  final Session session;

  /// Agent state whose [AgentState.messages] is replaced with the
  /// compacted transcript on success.
  final AgentState state;

  /// The model's context window (in tokens). Used by [shouldCompact].
  final int window;

  /// Compaction thresholds (`reserveTokens`, `keepRecentTokens`,
  /// `triggerRatio`).
  final CompactionSettings settings;

  /// The summarizer used at the top of the pass chain (typically the
  /// `smol` role). May equal [mainSummary] for hosts without a separate
  /// `smol` (the helper skips the fallback in that case).
  final SummarizeFn summary;

  /// Fallback summarizer (typically the main model).
  final SummarizeFn mainSummary;

  /// The model passed to [summary] (i.e. the `smol` Model spec).
  final Model? smolModel;

  /// Progress / error sink.
  final AutoCompactorHooks hooks;

  /// Optional Phase 2 hook: forwarded to every [CompactionManager] so
  /// durable-fact extraction (CLI long-term memory, future Flutter
  /// equivalents) runs once per pass with the summarized span.
  final Future<void> Function(String summarizedText)? memoryExtractionHook;

  /// Summarization prompts forwarded to the [CompactionManager] so a
  /// host's `prompts:` yaml override reaches the same `summary` callback
  /// that `streamFunctionSummarizer` already uses.
  final CompactionPrompts prompts;

  /// Upper bound on pass count per [run]. Picked so a 1M→200k session
  /// compacts down in 2-3 passes; deep enough for the worst case but
  /// bounded so a model that just won't summarize doesn't loop forever.
  final int maxPasses;

  /// Retry attempts per pass before falling back / failing.
  final int maxAttempts;

  /// First backoff sleep between same-pass attempts (multiplied by
  /// attempt number): 1s, 2s.
  final Duration baseBackoff;

  /// Wall-clock budget for ONE summarization attempt. A provider endpoint
  /// that accepts the request and never answers (no bytes, no error, no
  /// done) would otherwise pend `stream.result` forever and wedge the turn
  /// on the compaction spinner for as long as the user is willing to
  /// watch it — the provider-level connect/idle watchdogs cover clean
  /// hangs, but not dribbling keep-alives or a lost completion. When the
  /// budget fires the attempt fails with a [TimeoutException] (not
  /// transient — no retry spin), the pass falls to the next summarizer /
  /// the local trim, and the turn goes on. 90 s: a summarizer writes a
  /// bounded summary, and "Compacting context…" must never read as a
  /// hang (the 0.1.240 default was 10 minutes per attempt — up to 20
  /// minutes of silent spinner when both summarizers dribbled).
  final Duration attemptBudget;

  /// Wall-clock budget for the WHOLE compactor run across all passes,
  /// attempts and summarizers. Checked before each attempt: once the
  /// elapsed time is over the budget, remaining attempts are skipped and
  /// the run falls to the local trim. Bounds pathological combinations
  /// (maxPasses × retries × smol+main) that would otherwise keep the UI
  /// on the compaction spinner for tens of minutes.
  final Duration totalBudget;

  /// When `true`, skip the [shouldCompact] gate and run the compactor
  /// unconditionally. Set by manual `/compact` (the user asked, so we
  /// honour the request even when the auto-trigger threshold isn't
  /// crossed).
  final bool force;

  /// Transient error markers worth retrying: 5xx HTTP, aborted /
  /// reset / closed sockets. Hard refusals (rate limit, 429, content
  /// filter, auth) fail fast.
  static final _transient = RegExp(
    '(?:5\\d\\d|connection\\s+(?:closed|reset|aborted|refused)|'
    'socket\\s+exception|stream\\s+closed)',
    caseSensitive: false,
  );

  /// Drives the multi-pass loop. Returns `true` on success (the
  /// transcript fits in [window]), `false` when the loop gave up or
  /// every summarizer failed.
  Future<bool> run() async {
    if (window <= 0) return true;
    final initial = estimateContextTokens(state.messages).tokens;
    if (!force && !shouldCompact(initial, window, settings)) return true;

    final runFallback = _shouldRunFallback();
    final clock = Stopwatch()..start();

    for (var pass = 1; pass <= maxPasses; pass++) {
      final result = await _runPass(
        pass,
        runFallback: runFallback,
        clock: clock,
      );
      if (result.done) return result.success;
    }
    final tokens = estimateContextTokens(state.messages).tokens;
    hooks.onDone(maxPasses, tokens);
    return false;
  }

  /// Whether the smol summarizer is distinct from the main one and should be
  /// tried before falling back to main.
  bool _shouldRunFallback() {
    final smol = smolModel;
    if (smol == null) return false;
    final mainModel = state.model;
    return smol.provider != mainModel.provider || smol.id != mainModel.id;
  }

  /// Runs one compaction pass. Returns `done: true` when the loop should
  /// terminate (success or hard failure), `done: false` when another pass is
  /// needed.
  Future<({bool done, bool success})> _runPass(
    int pass, {
    required bool runFallback,
    required Stopwatch clock,
  }) async {
    final tokensBefore = estimateContextTokens(state.messages).tokens;
    final mainModel = state.model;
    final smolModel = this.smolModel;

    final attempt = await _pickAttempt(
      pass,
      runFallback: runFallback,
      mainLabel: _modelLabel(mainModel),
      smolLabel: smolModel == null ? 'default' : _modelLabel(smolModel),
      clock: clock,
    );

    if (!attempt.ok) {
      // Both summarizers down: as a last resort, mechanically bound the
      // live context (see [_localTrimFallback]) so the agent can keep
      // working instead of being stuck over-window until the endpoint
      // recovers.
      final trimmed = _localTrimFallback();
      if (trimmed != null) {
        state.messages = trimmed;
        final tokensAfter = estimateContextTokens(state.messages).tokens;
        hooks.onPass(
          AutoCompactorPass(
            pass: pass,
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            fallback: 'local-trim',
            ok: true,
          ),
        );
        hooks.onDone(pass, tokensAfter);
        return (
          done: true,
          success: !shouldCompact(tokensAfter, window, settings),
        );
      }
      hooks.onBothRolesFailed(attempt.error!);
      hooks.onPass(
        AutoCompactorPass(
          pass: pass,
          tokensBefore: tokensBefore,
          tokensAfter: tokensBefore,
          fallback: null,
          ok: false,
          error: attempt.error,
        ),
      );
      hooks.onDone(pass, estimateContextTokens(state.messages).tokens);
      return (done: true, success: false);
    }

    // A no-op pass (the branch is already compacted at the leaf): stop
    // instead of spinning identical passes to maxPasses.
    if (attempt.noWork) {
      hooks.onPass(
        AutoCompactorPass(
          pass: pass,
          tokensBefore: tokensBefore,
          tokensAfter: tokensBefore,
          fallback: attempt.fallback,
          ok: true,
        ),
      );
      hooks.onDone(pass, tokensBefore);
      return (done: true, success: true);
    }

    // Pass succeeded — re-stamp the in-memory transcript with the
    // session's projected context, then re-estimate. The kept assistant
    // messages carry generation-time usage from BEFORE the compaction —
    // anchoring the estimator at it would keep reporting the
    // pre-compaction size and retrigger the loop forever. Clear it; the
    // next turn's usage report re-anchors the estimate.
    state.messages = [
      for (final message in await session.buildContextMessages())
        if (message is AssistantMessage)
          message.copyWith(usage: Usage.zero)
        else
          message,
    ];
    final tokensAfter = estimateContextTokens(state.messages).tokens;
    hooks.onPass(
      AutoCompactorPass(
        pass: pass,
        tokensBefore: tokensBefore,
        tokensAfter: tokensAfter,
        fallback: attempt.fallback,
        ok: true,
      ),
    );
    if (!shouldCompact(tokensAfter, window, settings)) {
      hooks.onDone(pass, tokensAfter);
      return (done: true, success: true);
    }
    return (done: false, success: false);
  }

  /// Emergency valve when both summarizers are down and the transcript is
  /// over the window: mechanically keep the most recent
  /// [CompactionSettings.keepRecentTokens] (estimated) messages, prefixing
  /// a user-role marker so the model (and providers, which reject
  /// toolResult-first transcripts) see what happened. In-memory only — the
  /// session file keeps every record; the next restart replays the full
  /// transcript and the pre-flight compaction retries the LLM path with a
  /// healthy endpoint. Returns null when there is nothing droppable (the
  /// budget already covers the whole transcript).
  List<Message>? _localTrimFallback() {
    final messages = state.messages;
    if (messages.isEmpty) return null;
    final budget = settings.keepRecentTokens;
    var cut = 0; // first kept index
    var accumulated = 0;
    for (var i = messages.length - 1; i >= 0; i--) {
      accumulated += estimateTokens(messages[i]);
      if (accumulated > budget) {
        cut = i + 1;
        break;
      }
    }
    if (cut <= 0) return null;
    // Pairing integrity: a token-boundary cut may land between an assistant
    // tool call and its result. The kept region would then open with an
    // orphaned ToolResultMessage, and strict providers reject EVERY
    // subsequent request ('400: tool_call_id is not found') — the session
    // is wedged until restart (Kimi production report). Skip leading
    // results; their calls are already outside the kept region.
    while (cut < messages.length && messages[cut] is ToolResultMessage) {
      cut++;
    }
    final kept = messages.sublist(cut);
    if (kept.isEmpty) return null;
    return [
      UserMessage.text(
        '[context trimmed locally: the summarizer endpoint was unavailable, '
        '$cut older message(s) were dropped from the live context at '
        '${DateTime.now().toUtc().toIso8601String()} — the full history '
        'stays in the session file]',
      ),
      // Zero the kept generations' usage anchors — a stale generation-time
      // anchor would keep the estimate over the window and retrigger the
      // compactor on the next turn (same rule as the success pass).
      for (final message in kept)
        if (message is AssistantMessage)
          message.copyWith(usage: Usage.zero)
        else
          message,
    ];
  }

  /// Picks the summarizer for this pass: smol first, main as fallback when
  /// [runFallback] is true. Returns the outcome plus the fallback label used.
  Future<({bool ok, Object? error, bool noWork, String? fallback})>
  _pickAttempt(
    int pass, {
    required bool runFallback,
    required String mainLabel,
    required String smolLabel,
    required Stopwatch clock,
  }) async {
    if (runFallback) {
      final smolOk = await _attempt(
        'smol=$smolLabel',
        summarize: summary,
        pass: pass,
        clock: clock,
      );
      if (smolOk.ok) {
        return (
          ok: true,
          error: null,
          noWork: smolOk.noWork,
          fallback: 'smol=$smolLabel',
        );
      }
      final mainOk = await _attempt(
        'main=$mainLabel',
        summarize: mainSummary,
        pass: pass,
        clock: clock,
      );
      if (mainOk.ok) {
        return (
          ok: true,
          error: null,
          noWork: mainOk.noWork,
          fallback: 'main=$mainLabel',
        );
      }
      return (
        ok: false,
        error: mainOk.error ?? smolOk.error,
        noWork: false,
        fallback: null,
      );
    }

    // No smol role, or smol == main: single attempt on the main stream.
    final mainOk = await _attempt(
      'main=$mainLabel',
      summarize: mainSummary,
      pass: pass,
      clock: clock,
    );
    if (mainOk.ok) {
      return (
        ok: true,
        error: null,
        noWork: mainOk.noWork,
        fallback: 'main=$mainLabel',
      );
    }
    return (ok: false, error: mainOk.error, noWork: false, fallback: null);
  }

  /// Runs one pass with up to [maxAttempts] retries on transient errors.
  /// Returns `{ok, error, noWork}` so the caller can decide whether to fall
  /// back to the main summarizer or surface a hard failure. `noWork` means
  /// the branch had nothing left to compact (already compacted at the
  /// leaf) — the caller stops the pass loop instead of spinning identical
  /// no-op passes to [maxPasses].
  Future<({bool ok, Object? error, bool noWork})> _attempt(
    String label, {
    required SummarizeFn summarize,
    required int pass,
    required Stopwatch clock,
  }) async {
    if (smolModel == null) {
      // Resolved via the main chain only — skip the label-based attempt.
    }
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (clock.elapsed >= totalBudget) {
        return (
          ok: false,
          error: TimeoutException(
            'compaction total budget (${totalBudget.inSeconds}s) exhausted '
            'before the $label attempt',
            totalBudget,
          ),
          noWork: false,
        );
      }
      hooks.onAttemptStart(label, attempt, attemptBudget);
      try {
        final manager = CompactionManager(
          summarize: summarize,
          settings: settings,
          prompts: prompts,
          memoryExtractionHook: memoryExtractionHook,
        );
        final record = await manager
            .compactSession(session)
            .timeout(
              attemptBudget,
              onTimeout: () => throw TimeoutException(
                'compaction attempt exceeded the '
                '${attemptBudget.inSeconds}s budget',
                attemptBudget,
              ),
            );
        return (ok: true, error: null, noWork: record == null);
      } catch (error) {
        final isTransient = _transient.hasMatch(error.toString());
        if (attempt >= maxAttempts || !isTransient) {
          return (ok: false, error: error, noWork: false);
        }
        final backoff = baseBackoff * attempt;
        hooks.onRetry(attempt, maxAttempts, backoff, error);
        await Future<void>.delayed(backoff);
      }
    }
    return (
      ok: false,
      error: StateError('unreachable: compact attempt loop'),
      noWork: false,
    );
  }
}

String _modelLabel(Model m) => '${m.provider}/${m.id}';

/// Source for the [AutoCompactor] smol/main summarizers. Hosts plug in
/// their own resolver:
/// - the CLI uses `config.modelRolesResolver?.resolveRole(smolModelRole)`
/// - the Flutter app uses `_taskModelsStore?.overrideFor(TaskRole.smol)`
///
/// Either source may be `null` when no smol is configured; in that case
/// [AutoCompactor.fromSources] falls back to [mainStream] for both
/// summarizers and skips the smol→main fallback (one attempt only —
/// retrying the same call wouldn't help).
class AutoCompactorSources {
  const AutoCompactorSources({
    required this.smolStream,
    required this.smolModel,
    required this.mainStream,
    required this.mainModel,
  });

  /// When `null`, the AutoCompactor uses [mainStream] + [mainModel] for
  /// both summarizers and skips the fallback (single attempt).
  final StreamFunction? smolStream;

  /// The Model spec the smol summarizer should call. `null` together
  /// with [smolStream] → no real smol.
  final Model? smolModel;

  /// Fallback summarizer stream (typically the main chat stream).
  final StreamFunction mainStream;

  /// Fallback summarizer model (typically the agent's main model).
  final Model mainModel;
}

/// Hosts plug in their own [AutoCompactorSources], hooks, and settings;
/// the factory wires the smol/main summarizers with the configured
/// [CompactionPrompts] and optional memory hook, then runs the loop.
///
/// When [force] is `true` the compactor skips [shouldCompact] — used by
/// manual `/compact` so the user can force a compaction regardless of
/// the auto-trigger threshold.
class AutoCompactorFactory {
  const AutoCompactorFactory({
    required this.session,
    required this.state,
    required this.window,
    required this.settings,
    required this.sources,
    required this.hooks,
    this.prompts = defaultCompactionPrompts,
    this.memoryExtractionHook,
    this.maxPasses = 8,
    this.maxAttempts = 3,
    this.baseBackoff = const Duration(seconds: 1),
    this.force = false,
    this.attemptBudget = const Duration(seconds: 90),
    this.totalBudget = const Duration(minutes: 4),
  });

  final Session session;
  final AgentState state;
  final int window;
  final CompactionSettings settings;
  final AutoCompactorSources sources;
  final AutoCompactorHooks hooks;
  final CompactionPrompts prompts;
  final Future<void> Function(String)? memoryExtractionHook;
  final int maxPasses;
  final int maxAttempts;
  final Duration baseBackoff;
  final bool force;

  /// Per-attempt wall-clock budget, forwarded to the built [AutoCompactor].
  final Duration attemptBudget;

  /// Whole-run wall-clock budget, forwarded to the built [AutoCompactor].
  final Duration totalBudget;

  /// Builds the [AutoCompactor] and runs it. Hosts that want to
  /// inspect the compactor before starting (e.g. for logging) can use
  /// [build] instead.
  Future<bool> run() => build().run();

  /// Builds the [AutoCompactor] from the factory's configuration without
  /// starting it. Useful for tests or for hosts that want to wrap the
  /// loop in extra logging.
  AutoCompactor build() {
    final smolStream = sources.smolStream ?? sources.mainStream;
    final smolModel = sources.smolModel ?? sources.mainModel;
    final smolSummarizer = streamFunctionSummarizer(
      smolStream,
      smolModel,
      prompts: prompts,
    );
    final mainSummarizer = streamFunctionSummarizer(
      sources.mainStream,
      sources.mainModel,
      prompts: prompts,
    );
    return AutoCompactor(
      session: session,
      state: state,
      window: window,
      settings: settings,
      summary: smolSummarizer,
      mainSummary: mainSummarizer,
      smolModel: sources.smolModel,
      hooks: hooks,
      memoryExtractionHook: memoryExtractionHook,
      prompts: prompts,
      maxPasses: maxPasses,
      maxAttempts: maxAttempts,
      baseBackoff: baseBackoff,
      force: force,
      attemptBudget: attemptBudget,
      totalBudget: totalBudget,
    );
  }
}
