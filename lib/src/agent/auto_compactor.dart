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

import '../compaction/compaction.dart';
import '../compaction/token_estimation.dart';
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

    final smolLabel = smolModel == null ? 'default' : _modelLabel(smolModel!);
    final mainModel = state.model;
    final smolEqualsMain =
        smolModel != null &&
        smolModel!.provider == mainModel.provider &&
        smolModel!.id == mainModel.id;
    // If no `smol` role is configured, `summary` and `mainSummary` point
    // at the same stream (smolSummarizer falls back to mainSummarizer's
    // model+stream). The fallback would just re-run the same call — skip
    // it, and run only the main attempt.
    final hasSmol = smolModel != null;
    final runFallback = hasSmol && !smolEqualsMain;

    for (var pass = 1; pass <= maxPasses; pass++) {
      final tokensBefore = estimateContextTokens(state.messages).tokens;
      String? fallbackUsed;
      Object? lastError;
      var noWork = false;

      // Pick the summarizer for this pass: smol first, main as fallback.
      if (runFallback) {
        final smolOk = await _attempt(
          'smol=$smolLabel',
          summarize: summary,
          pass: pass,
        );
        if (smolOk.ok) {
          fallbackUsed = 'smol=$smolLabel';
          noWork = smolOk.noWork;
        } else {
          lastError = smolOk.error;
          final mainOk = await _attempt(
            'main=${_modelLabel(mainModel)}',
            summarize: mainSummary,
            pass: pass,
          );
          if (mainOk.ok) {
            fallbackUsed = 'main=${_modelLabel(mainModel)}';
            noWork = mainOk.noWork;
          } else {
            lastError = mainOk.error ?? lastError;
            hooks.onBothRolesFailed(lastError!);
            hooks.onPass(
              AutoCompactorPass(
                pass: pass,
                tokensBefore: tokensBefore,
                tokensAfter: tokensBefore,
                fallback: null,
                ok: false,
                error: lastError,
              ),
            );
            hooks.onDone(pass, estimateContextTokens(state.messages).tokens);
            return false;
          }
        }
      } else {
        // No smol role, or smol == main: single attempt on the main
        // stream. (Fallback to the same call would just re-run it.)
        final mainOk = await _attempt(
          'main=${_modelLabel(mainModel)}',
          summarize: mainSummary,
          pass: pass,
        );
        if (mainOk.ok) {
          fallbackUsed = 'main=${_modelLabel(mainModel)}';
          noWork = mainOk.noWork;
        } else {
          lastError = mainOk.error;
          hooks.onBothRolesFailed(lastError!);
          hooks.onPass(
            AutoCompactorPass(
              pass: pass,
              tokensBefore: tokensBefore,
              tokensAfter: tokensBefore,
              fallback: null,
              ok: false,
              error: lastError,
            ),
          );
          hooks.onDone(pass, tokensBefore);
          return false;
        }
      }

      // A no-op pass (the branch is already compacted at the leaf): stop
      // instead of spinning identical passes to maxPasses.
      if (noWork) {
        hooks.onPass(
          AutoCompactorPass(
            pass: pass,
            tokensBefore: tokensBefore,
            tokensAfter: tokensBefore,
            fallback: fallbackUsed,
            ok: true,
          ),
        );
        hooks.onDone(pass, tokensBefore);
        return true;
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
          fallback: fallbackUsed,
          ok: true,
        ),
      );
      if (!shouldCompact(tokensAfter, window, settings)) {
        hooks.onDone(pass, tokensAfter);
        return true;
      }
    }
    final tokens = estimateContextTokens(state.messages).tokens;
    hooks.onDone(maxPasses, tokens);
    return false;
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
  }) async {
    if (smolModel == null) {
      // Resolved via the main chain only — skip the label-based attempt.
    }
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final manager = CompactionManager(
          summarize: summarize,
          settings: settings,
          prompts: prompts,
          memoryExtractionHook: memoryExtractionHook,
        );
        final record = await manager.compactSession(session);
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
    );
  }
}
