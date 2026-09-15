/// The provider-queue runtime (issue #418): turns resolved
/// [ProviderQueueEntry] values into a [FallbackStreamFunction] chain with
/// the queue advance policy — seven death kinds (quota, auth, network,
/// timeout, malformed, 5xx, finish_reason), never advancing on
/// content_filter/user abort — plus the sticky RAM state the editor reads.
///
/// The queue REPLACES the main-model resolution: the default role resolves
/// through the queue head. The state object is volatile by contract — a
/// restart builds a fresh wrapper and the queue restarts at its head (AC6).
library;

import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import 'roles_config.dart';
import '../types.dart';
import '../exceptions.dart';
import 'fallback_stream.dart';
import 'key_rotation.dart';
import 'provider_catalog.dart';
import 'providers_queue.dart';

/// Cooldown applied to a quota death when the provider sent no
/// `Retry-After` (issue #418 open question 1 — proposed 60s; flip to 30s
/// here for snappier rotation).
const defaultProviderQueueCooldown = Duration(seconds: 60);

/// Classifies an error event into a queue death (issue #418 AC3/UT-13
/// kind strings). Returns `null` when the chain must NOT advance — the
/// content_filter finish_reason family, a user abort, and unknown errors
/// all surface verbatim (the roles precedent).
///
/// Precedence: quota → auth → finish_reason → 5xx → malformed → timeout →
/// network.
QueueDeath? classifyQueueDeath(ErrorEvent event) {
  if (event.reason != StopReason.error) return null; // abort — never advance
  final text = event.error.errorMessage;
  if (text == null || text.isEmpty) return null;

  // Content_filter family (terminal finish_reason class, issue #312):
  // never a queue death — the error surfaces verbatim.
  final retryClass = finishReasonRetryClass(event.error);
  if (retryClass == FinishReasonClass.terminal) return null;

  // Quota: the rate-limit patterns own 429/quota wordings; the cooldown
  // follows the structured Retry-After, else the default.
  if (isRateLimitOrQuota(event.error, retryAfter: event.retryAfter)) {
    return QueueDeath(
      kind: QueueDeathKind.quota,
      cooldown: event.retryAfter ?? defaultProviderQueueCooldown,
    );
  }

  // Auth: the key is dead — advance immediately, no cooldown (UT-10).
  if (_authPatterns.any((pattern) => pattern.hasMatch(text))) {
    return const QueueDeath(kind: QueueDeathKind.auth, immediate: true);
  }

  // Transient/unknown wire finish_reason after retries (issue #312).
  if (retryClass != null) {
    return const QueueDeath(kind: QueueDeathKind.finishReason);
  }

  // 5xx family (gateways included) after the retry ladder is spent.
  if (_fivexxPatterns.any((pattern) => pattern.hasMatch(text))) {
    return const QueueDeath(kind: QueueDeathKind.fivexx);
  }

  // Malformed stream: bad SSE/non-JSON deltas, truncation without a
  // finish_reason (the 200-empty silent provider included).
  if (_malformedPatterns.any((pattern) => pattern.hasMatch(text))) {
    return const QueueDeath(kind: QueueDeathKind.malformed);
  }

  // Provider watchdog deaths (connect/stream-idle timeouts).
  if (_timeoutPatterns.any((pattern) => pattern.hasMatch(text))) {
    return const QueueDeath(kind: QueueDeathKind.timeout);
  }

  // Everything else the roles layer already calls transient transport:
  // dropped/refused/reset connections, DNS/TLS failures.
  if (isTransientTransportError(event.error)) {
    return const QueueDeath(kind: QueueDeathKind.network);
  }

  // Unknown — forward verbatim, never advance on a guess.
  return null;
}

final _authPatterns = [
  RegExp(r'\b401\b'),
  RegExp(r'\b403\b'),
  RegExp(r'unauthorized', caseSensitive: false),
  RegExp(r'forbidden', caseSensitive: false),
  RegExp(r'invalid api key', caseSensitive: false),
  RegExp(r'invalid_api_key', caseSensitive: false),
  RegExp(r'incorrect api key', caseSensitive: false),
  RegExp(r'authentication', caseSensitive: false),
];

final _fivexxPatterns = [
  RegExp(r'\b50[0234]\b'),
  RegExp(r'bad gateway', caseSensitive: false),
  RegExp(r'service unavailable', caseSensitive: false),
  RegExp(r'gateway time-?out', caseSensitive: false),
  RegExp(r'internal (server|network) error', caseSensitive: false),
  RegExp(r'internal network failure', caseSensitive: false),
];

final _malformedPatterns = [
  RegExp(r'stream ended without finish_reason'),
  RegExp(r'format ?exception', caseSensitive: false),
  RegExp(r'invalid json', caseSensitive: false),
  RegExp(r'unexpected character', caseSensitive: false),
  RegExp(r'invalid sse', caseSensitive: false),
  RegExp(r'malformed', caseSensitive: false),
  RegExp(r'empty (stream|response)', caseSensitive: false),
];

final _timeoutPatterns = [
  RegExp(r'timeout ?exception', caseSensitive: false),
  RegExp(r'stream idle timeout', caseSensitive: false),
  RegExp(r'request (attempt )?timed? ?out', caseSensitive: false),
];

/// Maps a queue adapter kind to the catalog provider NAME the model
/// builder keys off. `openai-completions` keeps the historical CLI rule:
/// a custom baseUrl reports provider `openai`, the default reports
/// `openrouter`.
String queueKindCatalogName(String kind, String? baseUrl) => switch (kind) {
  'openai-completions' => baseUrl == null ? 'openrouter' : 'openai',
  'anthropic' => 'anthropic',
  'google' => 'google',
  'dial' => 'dial',
  'minimax' => 'minimax',
  'zai' => 'zai',
  'aiin' => 'aiin',
  'chatgpt-codex' => 'chatgpt',
  'copilot' => 'copilot',
  _ => throw ConfigException(
    'unknown provider kind "$kind" — supported: '
    '${providerQueueKinds.join(', ')}',
  ),
};

/// Builds the [ChainEntry] list for a resolved queue: one model per entry
/// (catalog defaults + the entry's overrides), a single key stack per
/// entry from its `apiKeyEnv` (the `_2`/`_3` stack convention rides along
/// free), and the catalog stream factory bound per key.
///
/// Entries with no configured key are SKIPPED (the roles precedent) and
/// reported in [skipped]; a queue that skips everything throws
/// [ConfigException].
List<ChainEntry> buildProviderQueueChain(
  List<ProviderQueueEntry> entries, {
  required Map<String, String> secrets,
  StreamFunction Function(String kind, String apiKey)? streamFactory,
  List<String>? skipped,
}) {
  final skipped_ = skipped ?? <String>[];
  final factory = streamFactory ?? providerStreamFunction;
  final chain = <ChainEntry>[];
  for (final entry in entries) {
    final keyEnv = entry.apiKeyEnv;
    if (keyEnv == null) {
      throw ConfigException(
        'queue entry ${entry.label} has no apiKeyEnv — keys never ride in '
        'the queue blob; name the env var holding the key',
      );
    }
    final stack = collectKeyStack(secrets, keyEnv);
    if (stack.isEmpty) {
      skipped_.add('${entry.label} (missing API key: set $keyEnv)');
      continue;
    }
    final ring = ApiKeyRing(baseName: keyEnv, credentials: stack);
    final spec = catalogProvider(
      queueKindCatalogName(entry.providerType, entry.baseUrl),
    )!;
    final inner = factory(spec.kind, stack.first.value);
    chain.add(
      ChainEntry(
        model: buildCatalogModel(
          spec.name,
          entry.model,
          baseUrl: entry.baseUrl,
          contextWindow: entry.contextWindow,
          maxTokens: entry.maxTokens,
        ),
        keyRing: ring,
        streamForKey: (apiKey) =>
            inner, // single entry-bound adapter; the key is baked in
      ),
    );
  }
  if (chain.isEmpty) {
    throw ConfigException(
      'the provider queue has no usable entry: ${skipped_.join('; ')}',
    );
  }
  return chain;
}

/// The wired queue: the sticky RAM state, the driven stream function, and
/// the entries it was built from. Hosts keep ONE instance per session
/// (the stickiness); editors mutate the yaml and re-resolve — the next
/// `rebuild()` swaps the chain live (AC7/UT-31).
final class ProviderQueueRuntime {
  ProviderQueueRuntime._(
    this.resolution,
    this.entries,
    this.state,
    this.streamFunction,
  );

  /// Builds the runtime from a resolution and the secrets snapshot.
  /// [policy]/[now]/[jitterFraction]/[sleeper] pass through to the wrapper
  /// (tests inject a deterministic clock).
  factory ProviderQueueRuntime.build(
    ProviderQueueResolution resolution, {
    required Map<String, String> secrets,
    StreamFunction Function(String kind, String apiKey)? streamFactory,
    ModelRolesRetryPolicy policy = const ModelRolesRetryPolicy(),
    DateTime Function()? now,
    double Function()? jitterFraction,
    Future<bool> Function(Duration delay, CancelToken? cancelToken)? sleeper,
    void Function(FallbackNotice notice)? onNotice,
  }) {
    final entries = resolution.entries;
    final state = ProviderQueueState();
    final chain = buildProviderQueueChain(
      entries,
      secrets: secrets,
      streamFactory: streamFactory,
    );
    final streamFunction = FallbackStreamFunction(
      entries: chain,
      policy: policy,
      queueClassifier: classifyQueueDeath,
      queueState: state,
      now: now,
      jitterFraction: jitterFraction,
      sleeper: sleeper,
      onNotice: onNotice,
    );
    return ProviderQueueRuntime._(resolution, entries, state, streamFunction);
  }

  /// The winning scope, entries, shadowed scopes, and boot notices.
  final ProviderQueueResolution resolution;

  /// The resolved (refs materialized) queue entries.
  final List<ProviderQueueEntry> entries;

  /// The sticky cursor + per-entry health (never persisted).
  final ProviderQueueState state;

  /// The queue-driven stream function — the default role's stream.
  final FallbackStreamFunction streamFunction;
}

/// The queue editor's per-entry health rows — pure so tests pin the byte
/// layout across the four health states (current / healthy / recovering /
/// cooldown) and any terminal width (issue #418, GOLDEN-tui-rows).
///
/// Secrets never appear: the row names the key's ENV indirection
/// (`key:$NAME`), never a value (AC9).
List<String> renderProviderQueueRows({
  required List<ProviderQueueEntry> entries,
  required ProviderQueueState state,
  required DateTime now,
}) {
  final rows = <String>[];
  for (var index = 0; index < entries.length; index++) {
    final entry = entries[index];
    final badge = index == state.currentIndex
        ? 'current'
        : switch (state.cooldownRemaining(index, now)) {
            null => state.lastError(index) == null ? 'healthy' : 'recovering',
            final left =>
              'cooldown ${left.inMinutes >= 1 ? '${left.inMinutes}m' : '${left.inSeconds}s'}',
          };
    final error = state.lastError(index);
    rows.add(
      '$index. ${entry.label} [$badge]'
      '${entry.apiKeyEnv == null ? '' : ' key:\$${entry.apiKeyEnv}'}'
      '${entry.baseUrl == null ? '' : ' ${entry.baseUrl}'}'
      '${error == null ? '' : ' — ${state.lastErrorKind(index)?.label}: $error'}',
    );
  }
  return rows;
}
