/// GitHub Copilot provider adapter: a thin wrapper over the
/// openai-completions adapter with Copilot auth (GitHub token → short-lived
/// Copilot API token via [CopilotTokenManager]) and the mandatory Copilot
/// headers. The Copilot API serves plain OpenAI chat completions at
/// `POST {baseUrl}/chat/completions` (goal/copilot_provider.md, wire
/// endpoint table), so the wire protocol is entirely the existing adapter's.
///
/// Errors-as-events invariant (non-negotiable): never throws. A 401/403
/// from the API means the short-lived token died mid-flight → invalidate +
/// exactly one refresh + one retry (proxy semantics); everything else
/// surfaces as an [ErrorEvent].
library;

import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:flutter_sandbox/flutter_sandbox.dart';
import '../context.dart';
import '../event_stream.dart';
import '../model.dart';
import '../providers/provider_common.dart';
import '../types.dart';
import 'copilot_oauth.dart';
import 'openai_completions.dart';

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

  /// The GitHub token exchanged for the short-lived Copilot API token.
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
      final effectiveModel =
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
            )
          : model;
      final inner = streamOpenAICompletions(
        effectiveModel,
        context,
        _completionsOptions(effectiveModel, context, options, token, statuses),
        _StatusWatch(httpClient, statuses),
      );
      // Hold the terminal error back until we know whether it is an auth
      // failure worth one refresh+retry: on a 401/403 the completions
      // adapter emits ONLY the error event (no start, no deltas — the
      // request is rejected before the SSE body exists).
      ErrorEvent? error;
      await for (final event in inner) {
        if (event is ErrorEvent) {
          error = event;
          break;
        }
        events.push(event);
      }
      final authRejected = statuses.any(
        (status) => status == 401 || status == 403,
      );
      if (authRejected && !retried) {
        retried = true;
        manager.invalidate();
        continue;
      }
      if (error != null) events.push(error);
      return;
    }
  } finally {
    events.end();
  }
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
      ...copilotApiHeaders(copilotToken: copilotToken),
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
