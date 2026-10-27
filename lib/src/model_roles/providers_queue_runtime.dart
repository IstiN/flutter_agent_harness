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

import 'dart:async';

import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../model.dart';
import '../providers/chatgpt_oauth.dart';
import '../providers/quota.dart';
// gh-1308: the zero-byte stall tag — the transient ladder's wedged-endpoint
// verdict, classified as an immediate queue advance.
import '../providers/transient_retry_stream.dart' show zeroByteStallTag;
import 'provider_model_binding.dart';
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
/// Precedence: budget → quota → auth → finish_reason → 5xx → malformed →
/// timeout → network.
QueueDeath? classifyQueueDeath(ErrorEvent event) {
  if (event.reason != StopReason.error) return null; // abort — never advance
  final text = event.error.errorMessage;
  if (text == null || text.isEmpty) return null;

  // Budget/spending exhaustion (issue #926): the entry is dead until the
  // budget reset — advance at once, no ladder, and the provider's budget
  // wording rides the switch event. Checked BEFORE the terminal
  // finish_reason veto (a budget death is not a content stop).
  //
  // Policy note (review #929): `immediate` deliberately benches the entry
  // with NO cooldown — reset-date-aware benching needs the structured
  // surface tracked in #898 — so the queue pays at most ONE cheap probe
  // per call against the dead head before failing over. Never sleeps,
  // never a ladder: the #926 flooding is gone, and the queue editor's
  // `recovering`/`healthy` badge must not be read as "will succeed"
  // while the budget stays exhausted.
  if (isBudgetExhaustion(event.error)) {
    return const QueueDeath(kind: QueueDeathKind.quota, immediate: true);
  }

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

  // Transient/unknown wire finish_reason after retries (issue #312).
  if (retryClass != null) {
    return const QueueDeath(kind: QueueDeathKind.finishReason);
  }

  // gh-1308: the zero-byte stall verdict — the entry already consumed its
  // whole silent-replay budget; same-entry retries cost another watchdog
  // interval each to re-prove the same wedged-endpoint fact. Advance at
  // once (auth precedent). Checked before the labeled nets (the tag also
  // matches the timeout net, which would retry in place first).
  if (text.contains(zeroByteStallTag)) {
    return const QueueDeath(kind: QueueDeathKind.timeout, immediate: true);
  }

  // The labeled regex nets in precedence order, then the transport net;
  // null — unknown, forward verbatim, never advance on a guess.
  return _labeledDeath(text, event.error);
}

/// The labeled death kinds after quota/finish_reason (issue #418): auth,
/// 5xx, malformed, timeout, network. Null when none match — the caller
/// forwards verbatim.
QueueDeath? _labeledDeath(String text, AssistantMessage error) {
  // Auth: the key is dead — advance immediately, no cooldown (UT-10).
  if (_authPatterns.any((pattern) => pattern.hasMatch(text))) {
    return const QueueDeath(kind: QueueDeathKind.auth, immediate: true);
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
  if (isTransientTransportError(error)) {
    return const QueueDeath(kind: QueueDeathKind.network);
  }

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
  // gh-1308: the zero-byte stall terminal — the wedged endpoint class the
  // provider watchdogs exist for; the entry benches and the queue advances.
  RegExp(r'zero-byte stall'),
];

/// Builds the [ChainEntry] list for a resolved queue: one model per entry
/// (catalog defaults + the entry's overrides), a single key stack per
/// entry from its `apiKeyEnv` (the `_2`/`_3` stack convention rides along
/// free), and the catalog stream factory bound per key.
///
/// `chatgpt-codex` entries resolve their credential on a ladder (issue
/// #1704): the `apiKeyEnv` value (the full OAuth blob, or a plain Bearer
/// token — the adapter tolerates both), else the entry's `refreshTokenEnv`
/// (the initial access token is minted by [mintChatGptCredentials] on the
/// entry's first activation, memoized in memory), else the default Keychain
/// slot name [chatGptOAuthCredentialsEnvName] (`apiKeyEnv` omitted — the
/// saved-login slot the secure store holds). Refreshed credentials stay
/// in memory: the queue lane does not persist back to the Keychain.
///
/// Entries with no configured key are SKIPPED (the roles precedent) and
/// reported in [skipped]; a queue that skips everything throws
/// [ConfigException]. Entries whose binding resolves with WARNINGS
/// (gh-1624: an unverified vendor-prefix dialect mismatch on an endpoint
/// that carries no verdict) are chained, and the render-ready warning
/// lines are emitted to [warnings] when given — a host that ignores the
/// channel lets the rider go silent (gh-1624 review r2).
List<ChainEntry> buildProviderQueueChain(
  List<ProviderQueueEntry> entries, {
  required Map<String, String> secrets,
  StreamFunction Function(String kind, String apiKey)? streamFactory,
  Future<String> Function(String refreshToken)? mintChatGptCredentials,
  List<String>? skipped,
  List<String>? warnings,
}) {
  final skipped_ = skipped ?? <String>[];
  final factory = streamFactory ?? providerStreamFunction;
  final chain = <ChainEntry>[];
  for (final entry in entries) {
    final (refreshName, refreshValue) = _chatGptRefreshCredential(
      entry,
      secrets,
    );
    final keyEnv =
        entry.apiKeyEnv ??
        (entry.providerType == 'chatgpt-codex'
            ? chatGptOAuthCredentialsEnvName
            : null);
    if (keyEnv == null) {
      throw ConfigException(
        'queue entry ${entry.label} has no apiKeyEnv — keys never ride in '
        'the queue blob; name the env var holding the key',
      );
    }
    // gh-1570 (AC6/M5): every queue entry resolves through the binding —
    // model id shape, wire⇄endpoint dialect, and the endpoint-shared
    // kind's identity all validate BEFORE the key check. A name-less
    // `openai-completions` entry has no identity (openai/openrouter/
    // kimi/codemie share the wire) and is rejected — even keyless —
    // instead of silently riding openrouter.ai once a key shows up.
    final ProviderModelBinding binding;
    try {
      binding = ProviderModelBinding.resolve(
        providerKind: entry.providerType,
        modelId: entry.model,
        baseUrl: entry.baseUrl,
        keyEnvRef: keyEnv,
        provenance: BindingProvenance.queue,
      );
    } on ConfigException catch (error) {
      throw ConfigException('queue entry ${entry.label}: ${error.message}');
    }
    // gh-1624 review r2: the entry's binding can carry an unverified
    // mismatch warning (private/router endpoint, foreign-dialect prefix).
    // The queue lane replaces main-model resolution — its warnings say
    // themselves on the same channel discipline as the skipped entries.
    for (final warning in binding.warnings) {
      warnings?.add('warning: binding — ${entry.label}: $warning');
    }
    final stack = collectKeyStack(secrets, keyEnv);
    if (stack.isEmpty && refreshValue.isEmpty) {
      skipped_.add(_queueSkipLine(entry, keyEnv, refreshName));
      continue;
    }
    final spec = catalogProvider(binding.catalogRecord)!;
    final model = buildCatalogModel(
      spec.name,
      entry.model,
      baseUrl: entry.baseUrl,
      contextWindow: entry.contextWindow,
      maxTokens: entry.maxTokens,
    );
    if (stack.isEmpty) {
      // refreshTokenEnv-only entry (issue #1704): the ring carries the
      // refresh token's env name (rotation/backoff bookkeeping); the
      // adapter never sees the raw refresh token — the stream mints the
      // initial access token on first activation.
      chain.add(
        ChainEntry(
          model: model,
          keyRing: ApiKeyRing(
            baseName: keyEnv,
            credentials: [ApiKeyCredential(refreshName, refreshValue)],
          ),
          streamForKey: _mintingStreamForKey(
            factory,
            spec.kind,
            refreshValue,
            mintChatGptCredentials ?? _defaultChatGptMint,
          ),
        ),
      );
      continue;
    }
    final inner = factory(spec.kind, stack.first.value);
    chain.add(
      ChainEntry(
        model: model,
        keyRing: ApiKeyRing(baseName: keyEnv, credentials: stack),
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

/// The `(envName, value)` refresh-token pair a `chatgpt-codex` entry
/// carries, or `('', '')` when it names no `refreshTokenEnv` (or the env
/// is unset — an empty value is indistinguishable from absent here; both
/// mean "no refresh bootstrap"). A `refreshTokenEnv` on a NON-chatgpt
/// kind is a hard error: the mint path is chatgpt-codex-only (issue
/// #1704).
(String, String) _chatGptRefreshCredential(
  ProviderQueueEntry entry,
  Map<String, String> secrets,
) {
  final refreshEnv = entry.refreshTokenEnv;
  if (refreshEnv == null) return ('', '');
  if (entry.providerType != 'chatgpt-codex') {
    throw ConfigException(
      'queue entry ${entry.label}: refreshTokenEnv applies only to '
      'chatgpt-codex entries',
    );
  }
  return (refreshEnv, secrets[refreshEnv] ?? '');
}

/// The skip line for an entry with no resolvable credential: names the
/// missing refresh env for a mint entry, the named key env for a plain
/// entry, and the DEFAULT slot + login path for a chatgpt-codex entry
/// that named no `apiKeyEnv` (what to set / where to log in) — never the
/// secret value.
String _queueSkipLine(
  ProviderQueueEntry entry,
  String keyEnv,
  String refreshName,
) {
  if (refreshName.isNotEmpty) {
    return '${entry.label} (missing refresh token: set $refreshName)';
  }
  if (keyEnv == entry.apiKeyEnv) {
    return '${entry.label} (missing API key: set $keyEnv)';
  }
  return '${entry.label} (no ChatGPT login: set $keyEnv or run '
      '`/provider chatgpt oauth`)';
}

/// The default refresh-token minter: the real OAuth refresh against
/// auth.openai.com (issue #1704). Tests inject a fake through
/// [buildProviderQueueChain]/[ProviderQueueRuntime.build] — the chain
/// itself never touches the network at build time.
Future<String> _defaultChatGptMint(String refreshToken) async =>
    refreshChatGptCredentials(
      ChatGptOAuthCredentials(
        accessToken: '',
        refreshToken: refreshToken,
        idToken: '',
      ),
    ).then((credentials) => credentials.encode());

/// The stream factory for a `refreshTokenEnv` entry: mints the initial
/// access token on the FIRST call (cursor activation), memoizes the blob
/// in memory for the entry's lifetime, then forwards the minted
/// credential's stream. A mint failure surfaces as the terminal error
/// event (providers-never-throw) the queue classifier advances on.
StreamFunction Function(String apiKey) _mintingStreamForKey(
  StreamFunction Function(String kind, String apiKey) factory,
  String kind,
  String refreshToken,
  Future<String> Function(String refreshToken) mint,
) {
  Future<String>? minted;
  return (
    apiKey,
  ) => (Model model, Context context, {CancelToken? cancelToken}) {
    // traced: false — this stream re-pushes an inner stream's events; the
    // adapter's own stream carries the StreamTrace emit mark (once per delta).
    final out = AssistantMessageEventStream(traced: false);
    unawaited(() async {
      try {
        minted ??= mint(refreshToken);
        final credentials = await minted!;
        await for (final event in factory(kind, credentials)(
          model,
          context,
          cancelToken: cancelToken,
        )) {
          out.push(event);
        }
      } catch (error) {
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
              errorMessage: 'chatgpt-codex credential bootstrap failed: $error',
              timestamp: DateTime.now(),
            ),
          ),
        );
      } finally {
        out.end();
      }
    }());
    return out;
  };
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
    this._noticeListeners,
  );

  /// Builds the runtime from a resolution and the secrets snapshot.
  /// [policy]/[now]/[jitterFraction]/[sleeper] pass through to the wrapper
  /// (tests inject a deterministic clock). [quotaFeed] threads through to
  /// the [FallbackStreamFunction] (issue #823 AC8 soft-bench); null keeps
  /// routing byte-identical.
  factory ProviderQueueRuntime.build(
    ProviderQueueResolution resolution, {
    required Map<String, String> secrets,
    StreamFunction Function(String kind, String apiKey)? streamFactory,
    Future<String> Function(String refreshToken)? mintChatGptCredentials,
    ModelRolesRetryPolicy policy = const ModelRolesRetryPolicy(),
    DateTime Function()? now,
    double Function()? jitterFraction,
    Future<bool> Function(Duration delay, CancelToken? cancelToken)? sleeper,
    void Function(FallbackNotice notice)? onNotice,
    QuotaFeed? quotaFeed,
    void Function(String line)? onBindingWarning,
  }) {
    final entries = resolution.entries;
    final state = ProviderQueueState();
    // gh-1624 review r2: the chain's binding warnings (unverified
    // dialect mismatches on private/router endpoints) must not die in
    // the builder — hosts render them on the boot/reload notice channel.
    final bindingWarnings = <String>[];
    // gh-1781: the chain's skipped entries (keyless heads a later keyed
    // entry made survivable) ride the same channel — a boot that lost its
    // head entry to a missing key never rides silently (AC2).
    final skippedEntries = <String>[];
    final chain = buildProviderQueueChain(
      entries,
      secrets: secrets,
      streamFactory: streamFactory,
      mintChatGptCredentials: mintChatGptCredentials,
      skipped: skippedEntries,
      warnings: bindingWarnings,
    );
    // gh-1617 review r2: the boot-time [onNotice] is often absent — the
    // host wires the agent AFTER the runtime is built. Every notice is
    // dispatched through this fan-out so late-attached listeners
    // ([addNoticeListener]) ride the same stream, in order.
    final noticeListeners = <void Function(FallbackNotice notice)>[];
    for (final line in bindingWarnings) {
      onBindingWarning?.call(line);
    }
    for (final line in skippedEntries) {
      onBindingWarning?.call('warning: provider queue skipped $line');
    }
    final streamFunction = FallbackStreamFunction(
      entries: chain,
      policy: policy,
      queueClassifier: classifyQueueDeath,
      queueState: state,
      now: now,
      jitterFraction: jitterFraction,
      sleeper: sleeper,
      onNotice: (notice) {
        onNotice?.call(notice);
        for (final listener in noticeListeners) {
          listener(notice);
        }
      },
      quotaFeed: quotaFeed,
    );
    return ProviderQueueRuntime._(
      resolution,
      entries,
      state,
      streamFunction,
      noticeListeners,
    );
  }

  /// The winning scope, entries, shadowed scopes, and boot notices.
  final ProviderQueueResolution resolution;

  /// The resolved (refs materialized) queue entries.
  final List<ProviderQueueEntry> entries;

  /// The sticky cursor + per-entry health (never persisted).
  final ProviderQueueState state;

  /// The queue-driven stream function — the default role's stream.
  final FallbackStreamFunction streamFunction;

  final List<void Function(FallbackNotice notice)> _noticeListeners;

  /// Registers [handler] for every queue retry/rotation/failover notice
  /// (gh-1617 review r2): hosts build the runtime at boot but wire the
  /// agent later, so a failover listener that re-syncs display state
  /// (`agent.state.model` — the watchdog's arm-time window reads it)
  /// cannot always ride the build's `onNotice`. Fired after the build
  /// handler, in attach order.
  void addNoticeListener(void Function(FallbackNotice notice) handler) =>
      _noticeListeners.add(handler);
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
