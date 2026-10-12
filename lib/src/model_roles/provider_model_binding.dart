/// The ONE validated provider+model identity (gh-1570): every way a
/// session picks its model — env preconfig, CLI flags, `/model`,
/// `/provider`, session restore, the provider queue, media slots, the
/// Flutter app settings — produces a [ProviderModelBinding] through
/// [ProviderModelBinding.resolve] or fails with an error naming BOTH
/// sides. A model can never again silently ride a foreign endpoint, wire
/// format, or API key.
///
/// The binding is the boundary INTO the already-correct resolved world
/// (`ModelRef.parse` requires a provider, `ModelRolesResolver` assembles
/// model+key+stream from one ref, `ProviderQueueEntry` carries its own
/// provider config). What it validates:
///
/// 1. *Wire ⇄ endpoint* — the endpoint's declared/known API DIALECT must
///    match the binding's ([ProviderSpec.api] vs [ProviderSpec.api] over
///    [ProviderSpec.defaultBaseUrl], [sameEndpoint]-normalized — `zai`'s
///    kind routes the openai-completions adapter, so an
///    openai-completions binding on z.ai's OpenAI-compatible endpoint
///    passes while an anthropic binding on it does not). A
///    vendor-prefixed model id (`zai/glm-…`) naming a record of another
///    dialect is a rejection too. An explicit `wire:` override is the
///    only escape hatch and is echoed in every report (E6: a genuinely
///    foreign-dialect endpoint behind a custom baseUrl passes only
///    through it).
/// 2. *Model ⇄ endpoint* — a model id whose family dialect is KNOWN
///    ([modelFamilyDialectHint]: `claude-*` is anthropic-messages,
///    `gemini-*` google-generative-ai, `gpt-*`/`o1`/`o3`/`o4-*`
///    openai-completions) is rejected on a family-exclusive canonical
///    endpoint of another family (api.anthropic.com serves only claude
///    ids, api.openai.com only gpt ids, generativelanguage only gemini
///    ids). Routers (OpenRouter/Copilot/DIAL), shared-dialect endpoints
///    and unknown endpoints always pass — there is nothing to judge them
///    by (D2: the `unverified` marker territory, never a silent guess).
/// 3. *Endpoint-shared wires* — `openai-completions` is six catalog
///    records (openai, openrouter, kimi, codemie, …). A binding on that
///    wire with NO record name and NO baseUrl has no identity at all and
///    is rejected instead of silently riding the legacy openrouter
///    default (M5: `OPENAI_API_KEY` sent to openrouter.ai).
/// 4. *Id shape and key indirection* — a model id carrying URL-ish or
///    control content is rejected before any endpoint call (E5); a key
///    ref must be an environment-variable NAME — key VALUES never enter
///    a binding (S3).
///
/// Pure Dart: no `dart:io`, no network — validation uses the provider
/// catalog only.
library;

import '../exceptions.dart';
import '../cli/custom_providers.dart' show sameEndpoint;
import 'provider_catalog.dart';

/// Where a binding was authored — the audit trail every report carries.
enum BindingProvenance {
  env,
  flag,
  restore,
  command,
  queue,
  media,
  app;

  /// The label reports render.
  String get label => switch (this) {
    BindingProvenance.env => 'env',
    BindingProvenance.flag => 'flag',
    BindingProvenance.restore => 'restore',
    BindingProvenance.command => 'command',
    BindingProvenance.queue => 'queue',
    BindingProvenance.media => 'media',
    BindingProvenance.app => 'app',
  };
}

/// The complete identity of one provider+model choice: the catalog
/// record (or custom entry) name, the wire kind, the normalized endpoint,
/// the model id, the key's env indirection, and the provenance.
///
/// Construct ONLY through [ProviderModelBinding.resolve] — the single
/// validating constructor. Every field is immutable; equality covers the
/// identity fields (record, wire, endpoint, model, key ref) so a
/// persisted state can round-trip (I5) regardless of which entry point
/// authored the binding.
final class ProviderModelBinding {
  ProviderModelBinding._({
    required this.recordName,
    required this.providerKind,
    required this.baseUrl,
    required this.modelId,
    required this.keyEnvRef,
    required this.provenance,
    required this.wireOverride,
  });

  /// Resolves and VALIDATES one provider+model choice.
  ///
  /// [providerKind] is the caller's provider identity — a catalog name
  /// (`kimi`), an adapter kind (`anthropic`), or the shared
  /// `openai-completions` kind. [recordName] names the specific catalog
  /// or saved custom record when the caller knows it (endpoint-shared
  /// wires NEED it or an explicit [baseUrl]). [baseUrl] overrides the
  /// record's default endpoint; it is normalized (one trailing slash
  /// stripped). [wire] is the explicit `wire:` escape hatch: the declared
  /// adapter kind REPLACES the record's own wire kind and silences the
  /// dialect checks (the caller asserted the endpoint speaks it); the
  /// override is echoed by [echo]. [keyEnvRef] is the key's environment
  /// indirection — a NAME, never a value.
  ///
  /// Throws [ConfigException] naming the model, the endpoint, and the
  /// wire kind on every validation failure (I2).
  factory ProviderModelBinding.resolve({
    required String providerKind,
    required String modelId,
    String? baseUrl,
    String? recordName,
    String? keyEnvRef,
    BindingProvenance provenance = BindingProvenance.command,
    String? wire,
  }) {
    final name = recordName?.trim() ?? '';
    final rawKind = providerKind.trim().toLowerCase();
    if (rawKind.isEmpty) {
      throw const ConfigException(
        'provider model binding: no provider given — name the provider '
        'record (or adapter kind) the model rides',
      );
    }
    validateModelIdShape(modelId);

    // The `wire:` escape hatch resolves FIRST: it is the adapter kind the
    // caller asserts the endpoint speaks, validated against the known
    // adapter kinds so a typo fails loud instead of inventing a wire.
    String? declaredWire;
    if (wire != null && wire.trim().isNotEmpty) {
      final declared = wire.trim().toLowerCase();
      final known = providerCatalog.values.any((spec) => spec.kind == declared);
      if (!known) {
        throw ConfigException(
          'unknown wire kind "$declared" — supported wire kinds: '
          '${providerCatalog.values.map((s) => s.kind).toSet().join(', ')}',
        );
      }
      declaredWire = declared;
    }

    // The record: a catalog name/kind resolves to its spec (the ONE
    // both-identifier lookup). An unknown id with no wire override is a
    // fail-loud rejection — a binding names a real record or it names
    // nothing.
    final spec = resolveCliProviderSpec(
      name.isNotEmpty ? name : rawKind,
      baseUrl: baseUrl,
    );
    if (spec == null) {
      throw ConfigException(
        'unknown provider record "$providerKind" — a model binding names a '
        'provider catalog record (or adapter kind)',
      );
    }
    final wireKind = declaredWire ?? spec.kind;
    final override = declaredWire != null && declaredWire != spec.kind;

    // Endpoint: explicit, else the record's own default. The endpoint-
    // shared kind with neither is identity-less — reject instead of
    // silently riding the legacy openrouter default (M5).
    final effectiveBaseUrl = _resolveBaseUrl(
      baseUrl: baseUrl,
      spec: spec,
      name: name,
      rawKind: rawKind,
    );

    if (!override) {
      _validateWireEndpoint(
        spec: spec,
        baseUrl: effectiveBaseUrl,
        modelId: modelId,
      );
      _validateModelEndpoint(
        spec: spec,
        baseUrl: effectiveBaseUrl,
        modelId: modelId,
      );
    }

    // Key indirection: an environment-variable NAME (S3 — values never
    // enter a binding).
    final keyRef = keyEnvRef?.trim() ?? '';
    if (keyRef.isNotEmpty && !RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(keyRef)) {
      throw ConfigException(
        'binding key reference "$keyRef" is not an environment variable '
        'name — bindings carry the key\'s env indirection (key:$keyRef '
        'style), never the key value',
      );
    }

    return ProviderModelBinding._(
      recordName: name.isEmpty ? null : name,
      providerKind: wireKind,
      baseUrl: normalizeBaseUrl(effectiveBaseUrl),
      modelId: modelId.trim(),
      keyEnvRef: keyRef.isEmpty ? null : keyRef,
      provenance: provenance,
      wireOverride: override,
    );
  }

  /// The catalog or saved custom record this binding rides, when the
  /// caller named one. Null on kind-only bindings with their own endpoint.
  final String? recordName;

  /// The WIRE kind the session speaks (`openai-completions`, `anthropic`,
  /// `google`, `zai`, `minimax`, `dial`, `copilot`, `chatgpt-codex`,
  /// `aiin`) — the resolved [ProviderSpec.kind], or the `wire:` override.
  final String providerKind;

  /// The serving endpoint, normalized (no trailing slash). Never empty.
  final String baseUrl;

  /// The model id exactly as the caller spelled it (trimmed).
  final String modelId;

  /// The key's environment indirection (the env var NAME the key resolves
  /// from), or null for keyless endpoints. Never a key value (S3).
  final String? keyEnvRef;

  /// Where this binding was authored.
  final BindingProvenance provenance;

  /// Whether an explicit `wire:` override authored the wire kind — echoed
  /// in every report so a silenced dialect check is never invisible (E6).
  final bool wireOverride;

  /// Identity equality (I5 round-trips): record, wire, endpoint, model,
  /// key ref. Provenance and the override flag describe the AUTHOR, not
  /// the identity.
  @override
  bool operator ==(Object other) =>
      other is ProviderModelBinding &&
      other.recordName == recordName &&
      other.providerKind == providerKind &&
      other.baseUrl == baseUrl &&
      other.modelId == modelId &&
      other.keyEnvRef == keyEnvRef;

  @override
  int get hashCode =>
      Object.hash(recordName, providerKind, baseUrl, modelId, keyEnvRef);

  /// The one-line report (boot notices, switch confirmations, restore
  /// notes). Names record, wire, endpoint, model, key indirection, and
  /// the wire override when present — never a key value.
  String echo() {
    final buffer = StringBuffer();
    if (recordName != null) buffer.write('record "$recordName" · ');
    buffer.write('wire $providerKind @ $baseUrl · model $modelId');
    if (keyEnvRef != null) buffer.write(' · key: \$$keyEnvRef');
    if (wireOverride) {
      buffer.write(' · wire override: $providerKind');
    }
    buffer.write(' · provenance: ${provenance.label}');
    return buffer.toString();
  }

  @override
  String toString() => echo();
}

/// Endpoint resolution: explicit, else the record's own default — with
/// the endpoint-shared kind requiring one or the other.
String _resolveBaseUrl({
  required String? baseUrl,
  required ProviderSpec spec,
  required String name,
  required String rawKind,
}) {
  final explicit = baseUrl?.trim() ?? '';
  if (explicit.isNotEmpty) return explicit;
  if (spec.defaultBaseUrl.isNotEmpty) {
    // The shared kind resolves through the legacy openai/openrouter rule
    // ONLY when the caller named a real record (`kimi`, `openai`, …). A
    // bare `openai-completions` kind has no identity — the default would
    // be a guess (M5).
    final namedRecord = name.isNotEmpty && providerCatalog[name] != null;
    final uniqueKind = rawKind != 'openai-completions';
    if (namedRecord || uniqueKind) return spec.defaultBaseUrl;
    throw ConfigException(
      'provider kind "openai-completions" is endpoint-shared (openai, '
      'openrouter, kimi, codemie, …) — a binding needs the record name or '
      'an explicit baseUrl; the model "$rawKind" would otherwise silently '
      'ride ${spec.defaultBaseUrl}',
    );
  }
  throw ConfigException(
    'provider "$rawKind" exposes no default endpoint — declare baseUrl',
  );
}

/// Wire ⇄ endpoint: a KNOWN endpoint of another API DIALECT is a
/// rejection. The catalog carries both layers per record — `kind` is the
/// identity/wire label (`zai` routes the openai-completions adapter) and
/// `api` is the dialect the endpoint actually speaks — so the comparison
/// is dialect-to-dialect: an openai-completions binding on z.ai's
/// OpenAI-compatible endpoint passes, an anthropic binding on the same
/// endpoint does not. Unknown endpoints pass — there is nothing declared
/// to check against.
void _validateWireEndpoint({
  required ProviderSpec spec,
  required String baseUrl,
  required String modelId,
}) {
  for (final endpointSpec in providerCatalog.values) {
    if (endpointSpec.defaultBaseUrl.isEmpty) continue;
    if (!sameEndpoint(endpointSpec.defaultBaseUrl, baseUrl)) continue;
    if (endpointSpec.api == spec.api) return;
    throw ConfigException(
      'provider/model binding mismatch: model "$modelId" would ride the '
      '"${spec.api}" dialect (provider "${spec.name}") against '
      '${endpointSpec.name}\'s endpoint $baseUrl — that endpoint speaks '
      '"${endpointSpec.api}". Point the binding at the matching endpoint, '
      'or declare the explicit `wire:` override only when the endpoint '
      'genuinely speaks "${spec.api}"',
    );
  }
}

/// Model ⇄ endpoint: two KNOWN-signal checks — a vendor-prefixed id whose
/// prefix names a record of ANOTHER API dialect (openai-completions is
/// the routing dialect where `vendor/model` ids live, so prefixes agree
/// with everything else that speaks it), and a known model family on the
/// family-exclusive CANONICAL endpoint of a different family. Unknown
/// ids, routers and unknown endpoints pass (D2 territory, never a
/// guess).
void _validateModelEndpoint({
  required ProviderSpec spec,
  required String baseUrl,
  required String modelId,
}) {
  final slash = modelId.indexOf('/');
  if (slash > 0) {
    final head = modelId.substring(0, slash).trim().toLowerCase();
    final headSpec = resolveCliProviderSpec(head);
    if (headSpec != null && headSpec.api != spec.api) {
      throw ConfigException(
        'provider/model binding mismatch: model "$modelId" names provider '
        '"${headSpec.name}" (dialect "${headSpec.api}") but the binding '
        'serves "${spec.api}" on $baseUrl — use a model of the bound '
        'provider, or an explicit `wire:` override only when the endpoint '
        'genuinely speaks "${spec.api}"',
      );
    }
    return;
  }
  final hint = modelFamilyDialectHint(modelId);
  if (hint == null || hint == spec.api) return;
  // The family check fires only on a family-EXCLUSIVE canonical
  // endpoint: routers (OpenRouter, Copilot, DIAL, kimi, …) and unknown
  // endpoints serve many families and carry no verdict.
  final canonical = _familyExclusiveEndpointDialect(baseUrl);
  if (canonical == null || canonical == hint) return;
  throw ConfigException(
    'provider/model binding mismatch: model "$modelId" is a "$hint" '
    'dialect family id but the binding serves it on $baseUrl '
    '("${spec.api}") — use a model of the bound provider, or declare the '
    'explicit `wire:` override only when the endpoint genuinely speaks '
    '"${spec.api}"',
  );
}

/// The family dialect a model id is KNOWN for — as an API dialect, so it
/// compares against [ProviderSpec.api]. Deliberately conservative: only
/// the families whose dialect is DISTINCT are pinned (`claude-*` →
/// anthropic-messages, `gemini-*` → google-generative-ai, `gpt-*`/
/// `o1`/`o3`/`o4-*`/`chatgpt*` → openai-completions). Families served
/// over multiple dialects (`glm-*`, `kimi-*`, `minimax-*`) stay unpinned
/// — a hint with two possible dialects cannot reject without false
/// positives.
String? modelFamilyDialectHint(String modelId) {
  final id = modelId.trim().toLowerCase();
  if (id.startsWith('claude')) return anthropicMessagesApi;
  if (id.startsWith('gemini')) return 'google-generative-ai';
  if (id.startsWith('gpt-') ||
      id.startsWith('o1') ||
      id.startsWith('o3') ||
      id.startsWith('o4-') ||
      id.startsWith('chatgpt')) {
    return 'openai-completions';
  }
  return null;
}

/// The family-dialect verdict a canonical endpoint carries: non-null
/// ONLY for the three family-exclusive endpoints — anthropic (claude
/// ids), openai (gpt ids), google (gemini ids). Every other endpoint
/// (routers, proxies, gateways) returns null: no verdict.
String? _familyExclusiveEndpointDialect(String baseUrl) {
  String? verdict;
  for (final (name, dialect) in const [
    ('anthropic', anthropicMessagesApi),
    ('openai', 'openai-completions'),
    ('google', 'google-generative-ai'),
  ]) {
    final spec = providerCatalog[name];
    if (spec == null || spec.defaultBaseUrl.isEmpty) continue;
    if (sameEndpoint(spec.defaultBaseUrl, baseUrl)) verdict = dialect;
  }
  return verdict;
}
/// Strips ONE trailing slash — the [sameEndpoint] normalization a
/// persisted binding round-trips through (E1).
String normalizeBaseUrl(String baseUrl) {
  final trimmed = baseUrl.trim();
  return trimmed.endsWith('/')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

/// The model id shape every binding (and every free-text `/model` entry)
/// passes through before anything else runs (E5): non-empty, bounded, no
/// whitespace or control characters, no URL scheme, no shell/SQL-ish
/// metacharacters — an id is a label the endpoint receives verbatim,
/// never a resource locator or an injection vector. Letters and digits
/// beyond ASCII (a non-ASCII catalog id) pass; ASCII punctuation outside
/// the label set does not.
void validateModelIdShape(String modelId) {
  final id = modelId.trim();
  String fail(String why) =>
      throw ConfigException('invalid model id "$modelId": $why');
  if (id.isEmpty) fail('the model id is empty');
  if (id.length > 200) fail('longer than 200 characters');
  if (id.contains('://')) fail('URL schemes are not model ids');
  for (final rune in id.runes) {
    final c = String.fromCharCode(rune);
    final allowed =
        (rune >= 0x30 && rune <= 0x39) || // 0-9
        (rune >= 0x41 && rune <= 0x5a) || // A-Z
        (rune >= 0x61 && rune <= 0x7a) || // a-z
        rune >= 0x80 || // non-ASCII letters/digits pass
        const {'.', '_', '-', '/', ':', '@', '+', '~'}.contains(c);
    if (!allowed) {
      fail('"$c" is not a model id character');
    }
  }
}
