/// GitHub Copilot provider adapter: a thin wrapper over the
/// openai-completions adapter with Copilot auth (GitHub token → short-lived
/// Copilot API token via [CopilotTokenManager]) and the mandatory Copilot
/// headers. The Copilot API serves plain OpenAI chat completions at
/// `POST {baseUrl}/chat/completions` (docs/goals/copilot_provider.md, wire
/// endpoint table), so the wire protocol is entirely the existing adapter's.
///
/// Errors-as-events invariant (non-negotiable): never throws. A 401/403
/// from the API means the short-lived token died mid-flight → invalidate +
/// exactly one refresh + one retry (proxy semantics); everything else
/// surfaces as an [ErrorEvent]. A stream that is ACCEPTED then truncated
/// (200 + SSE ending before `finish_reason`) is not a status the wrapper
/// can see — issue #2327: 3 consecutive truncation-class ends per token
/// fire the self-heal (invalidate + fresh exchange + one retry on the new
/// token, rate-bounded, shared-client recycle); a heal that still
/// truncates surfaces the class-named terminal instead of the raw error.
library;

import 'dart:async';

import 'package:http/http.dart' as http;

import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../model.dart';
import '../providers/provider_common.dart';
import '../types.dart';
import 'copilot_oauth.dart';
import 'openai_completions.dart';
import 'transient_retry_stream.dart';

/// Options for [streamCopilot].
final class CopilotOptions {
  /// Creates options. [githubToken] is required unless [tokenManager] is
  /// supplied.
  const CopilotOptions({
    required this.githubToken,
    this.tokenManager,
    this.cancelToken,
    this.sessionId,
    this.cacheRetention,
  });

  /// The GitHub credential: an OAuth token (`gho_`/`ghu_`) is exchanged
  /// for the short-lived Copilot API token; a fine-grained PAT
  /// (`github_pat_…`) is the Bearer itself (PAT mode, gh-1606).
  final String githubToken;

  /// Overrides the per-token manager registry (tests inject a fake here).
  final CopilotTokenManager? tokenManager;

  /// Cancels the in-flight request when triggered.
  final CancelToken? cancelToken;

  /// Prompt-cache affinity key, threaded through to the completions
  /// adapter (same defaults as the other adapters).
  final String? sessionId;

  /// Cache retention (`short`/`long`/`none`).
  final String? cacheRetention;
}

/// Streams an assistant message from GitHub Copilot.
///
/// [client] overrides the HTTP client (tests inject `http.testing`
/// mocks); when omitted the shared keep-alive client is used.
AssistantMessageEventStream streamCopilot(
  Model model,
  Context context, [
  CopilotOptions? options,
  http.Client? client,
]) {
  final events = AssistantMessageEventStream();
  unawaited(
    _runCopilotStream(
      events,
      model,
      context,
      options ?? const CopilotOptions(githubToken: ''),
      client,
    ),
  );
  return events;
}

Future<void> _runCopilotStream(
  AssistantMessageEventStream events,
  Model model,
  Context context,
  CopilotOptions options,
  http.Client? client,
) async {
  final state = ProviderStreamState(model);
  // No injected client: the shared keep-alive client (never closed per
  // call — same rationale as the other adapters).
  final httpClient = client ?? sharedProviderHttpClient();
  final manager =
      options.tokenManager ??
      CopilotTokenManager.forGithubToken(options.githubToken, client: client);
  var retried = false;
  // PAT mode (gh-1606): the raw PAT is the credential — a 401/403 has no
  // refresh path, so the wrapper must not burn a doomed retry on it.
  final patMode = isFineGrainedGitHubPat(options.githubToken);
  try {
    while (true) {
      final String token;
      try {
        token = await manager.get();
      } on Object catch (error) {
        pushStreamErrorEvent(events, state, error, options.cancelToken);
        return;
      }
      final statuses = <int>[];
      // The token knows its tenant's API host (proxy-ep): enterprise
      // tenants (incl. dedicated endpoints) must not be pinned to the
      // plan-picker's tier host (pi getGitHubCopilotBaseUrl parity).
      final derivedBaseUrl = copilotApiBaseUrlFromToken(token);
      final effectiveModel = _effectiveCopilotModel(model, derivedBaseUrl);
      final inner = streamOpenAICompletions(
        effectiveModel,
        context,
        _completionsOptions(effectiveModel, context, options, token, statuses),
        _StatusWatch(httpClient, statuses),
      );
      // Hold the terminal error back until we know whether it is an auth
      // failure worth one refresh+retry: on a 401/403 the completions
      // adapter emits ONLY the error event (no start, no deltas — the
      // request is rejected before the SSE body exists). The terminal
      // DoneEvent is held too: the truncation self-heal (#2327) may
      // replace it with the class-named terminal — one terminal event
      // leaves this wrapper either way.
      final terminals = await _consumeAttempt(inner, events);
      if (_isAuthRefresh(statuses, retried, patMode)) {
        retried = true;
        manager.invalidate();
        continue;
      }
      switch (_attemptOutcome(manager, terminals, patMode)) {
        case _AttemptOutcome.retryFresh:
          // The truncation heal fires: invalidate + fresh exchange (the
          // loop's next `get`) + one retry on the new token.
          _applyTruncationHeal(manager, client);
          continue;
        case _AttemptOutcome.classTerminal:
          // The heal is consumed/throttled: the class-named terminal (AC2)
          // replaces the raw error or the flagged DoneEvent.
          events.push(_truncationHealTerminal(state));
          return;
        case _AttemptOutcome.replayRaw:
        case _AttemptOutcome.passThrough:
          // One-off truncation (or PAT mode), or a non-truncation end:
          // today's semantics — the raw terminals out.
          _pushTerminals(events, terminals);
          return;
      }
    }
  } finally {
    events.end();
  }
}

/// The terminal events one wrapper attempt ended with: at most one
/// terminal exists — an [ErrorEvent], a [DoneEvent], or neither (a cancel
/// mid-stream is itself an [ErrorEvent]).
final class _AttemptTerminals {
  const _AttemptTerminals({this.error, this.done});

  /// The attempt's terminal error, when it failed.
  final ErrorEvent? error;

  /// The attempt's terminal message, when it completed.
  final DoneEvent? done;
}

/// What the wrapper does with an attempt's terminals (issue #2327).
enum _AttemptOutcome {
  /// Not truncation-class: the ledger streak resets, raw terminals out.
  passThrough,

  /// Truncation-class below the heal threshold (or PAT mode — no exchange
  /// path): raw terminals out, today's semantics; the ladder replays the
  /// error shape.
  replayRaw,

  /// The truncation heal fires: invalidate + fresh exchange + one retry
  /// on the new token.
  retryFresh,

  /// The heal is consumed/throttled: the class-named terminal replaces
  /// the raw end (never replayed).
  classTerminal,
}

/// Consumes one inner attempt, streaming non-terminal events through and
/// holding the terminal(s) back (see the call site for why).
Future<_AttemptTerminals> _consumeAttempt(
  AssistantMessageEventStream inner,
  AssistantMessageEventStream events,
) async {
  ErrorEvent? error;
  DoneEvent? done;
  await for (final event in inner) {
    if (event is ErrorEvent) {
      error = event;
      break;
    }
    if (event is DoneEvent) {
      done = event;
      break;
    }
    events.push(event);
  }
  return _AttemptTerminals(error: error, done: done);
}

/// The 401/403 refresh-once proxy rule: the token died mid-flight and a
/// retry on a fresh one is warranted (one per attempt — [retried]; never
/// in PAT mode).
bool _isAuthRefresh(List<int> statuses, bool retried, bool patMode) =>
    statuses.any((status) => status == 401 || status == 403) &&
    !retried &&
    !patMode;

/// The attempt verdict: classifies the terminals against the truncation
/// ledger (issue #2327). A non-truncation end resets the streak and passes
/// through; a truncation end counts toward
/// [CopilotTokenManager.truncationHealThreshold] and maps the heal verdict.
/// Both shapes count: the empty cut transport ([ErrorEvent]) and the
/// tolerated silent truncation (flagged [DoneEvent]).
_AttemptOutcome _attemptOutcome(
  CopilotTokenManager manager,
  _AttemptTerminals terminals,
  bool patMode,
) {
  if (!_endedTruncationClass(terminals)) {
    manager.registerStreamEnd(truncationClass: false);
    return _AttemptOutcome.passThrough;
  }
  switch (manager.registerStreamEnd(truncationClass: true)) {
    case CopilotTruncationHeal.fire:
      return _AttemptOutcome.retryFresh;
    case CopilotTruncationHeal.throttled:
      return _AttemptOutcome.classTerminal;
    case CopilotTruncationHeal.none:
      return _AttemptOutcome.replayRaw;
  }
}

/// Whether the attempt ended truncation-class (issue #2327): 200 + an SSE
/// that died before the finish_reason — no status the wrapper could have
/// watched, so the ends themselves are the signal.
bool _endedTruncationClass(_AttemptTerminals terminals) =>
    isTruncationClassStreamEnd(terminals.error?.error.errorMessage) ||
    isTruncationClassStreamEnd(terminals.done?.message.errorMessage);

/// Applies the heal (issue #2327): invalidate + fresh exchange (the loop's
/// next `get`) + one retry on the new token — the heal window keeps this a
/// single retry per episode. The pool may carry the episode's damage (DNS
/// storm, gateway enforcement): recycle the shared client once —
/// production path only, an injected client is owned by its caller (AC4).
void _applyTruncationHeal(CopilotTokenManager manager, http.Client? client) {
  manager.invalidate();
  if (client == null) recycleProviderHttpClientAfterHeal();
}

/// The raw terminals out (today's semantics for one-off truncations, PAT
/// mode, and every non-truncation end).
void _pushTerminals(
  AssistantMessageEventStream events,
  _AttemptTerminals terminals,
) {
  final error = terminals.error;
  if (error != null) events.push(error);
  final done = terminals.done;
  if (done != null) events.push(done);
}

/// The class-named truncation terminal (issue #2327 AC2): replaces the raw
/// cut-transport error once the self-heal has consumed its cycle — the
/// user sees the class, the action taken, and both remedies instead of a
/// generic endpoint failure.
ErrorEvent _truncationHealTerminal(ProviderStreamState state) {
  state.stopReason = StopReason.error;
  state.errorMessage =
      'copilot stream truncated '
      '×${CopilotTokenManager.truncationHealThreshold} — token refreshed; '
      'if it persists: auth/geo/revocation suspected — check VPN/region '
      'or re-authorize Copilot (/provider copilot).';
  return ErrorEvent(
    reason: StopReason.error,
    error: state.snapshot(finalize: true),
  );
}

OpenAICompletionsOptions _completionsOptions(
  Model model,
  Context context,
  CopilotOptions options,
  String copilotToken,
  List<int> statuses,
) {
  return OpenAICompletionsOptions(
    apiKey: copilotToken,
    headers: {
      // An exchanged token keeps the vscode-chat identity; a raw
      // fine-grained PAT (PAT mode) presents the Copilot CLI identity.
      ...copilotRequestHeaders(copilotToken: copilotToken),
      // agent iff the model's own turn continues (assistant/toolResult is
      // the last message); user for a fresh user turn.
      'x-initiator': copilotInitiatorFor(context.messages),
      // Vision only when the request actually carries images (a text-only
      // model has its images downgraded by the adapter — no header then).
      if (model.input.contains('image') &&
          messagesContainImages(context.messages))
        'copilot-vision-request': 'true',
    },
    cancelToken: options.cancelToken,
    sessionId: options.sessionId,
    cacheRetention: options.cacheRetention,
  );
}

/// The request model, rebuilt against the token's tenant API host when the
/// token redirects it (enterprise/proxy-ep tenants must not be pinned to
/// the plan-picker's tier host — pi getGitHubCopilotBaseUrl parity).
Model _effectiveCopilotModel(Model model, String? derivedBaseUrl) =>
    derivedBaseUrl != null && derivedBaseUrl != model.baseUrl
    ? Model(
        id: model.id,
        name: model.name,
        api: model.api,
        provider: model.provider,
        baseUrl: derivedBaseUrl,
        reasoning: model.reasoning,
        input: model.input,
        cost: model.cost,
        contextWindow: model.contextWindow,
        maxTokens: model.maxTokens,
        headers: model.headers,
        compat: model.compat,
        authHeader: model.authHeader,
        maxImages: model.maxImages,
      )
    : model;

/// Records response status codes so the wrapper can spot a 401/403 without
/// touching adapter internals (the adapter throws its HTTP error before its
/// own `onResponse` hook ever fires).
final class _StatusWatch extends http.BaseClient {
  _StatusWatch(this._inner, this._statuses);

  final http.Client _inner;
  final List<int> _statuses;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    _statuses.add(response.statusCode);
    return response;
  }
}
