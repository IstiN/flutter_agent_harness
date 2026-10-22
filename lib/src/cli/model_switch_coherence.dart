/// The model-switch coherence core (gh-178): the pure decision layer
/// behind the three gates that keep the ACTIVE model a coherent quadruple
/// `(provider, modelId, baseUrl, key family/auth header)` quad.
///
/// - **G1 (switch gate)** — [parseTypedModelTarget] resolves a typed or
///   picked `provider/model` entry to a same-provider model switch, a
///   whole-triple cross-provider switch, or a refusal. The same-provider
///   reuse shape (the `_switchModel` construction sites keeping
///   `provider: current.provider`) is never applied to a cross-provider
///   pick: the cross-provider branch routes through the provider-switch
///   flow or refuses, naming the missing provider and the repair command.
/// - **G2 (request-build gate)** — [requestCoherenceRefusal] judges the
///   live model against the wiring that would carry it. A refusal names
///   the mismatched fields and the repair command; the caller must surface
///   it INSTEAD of the request (no socket is ever opened).
/// - **G3 (restore gate)** — [restoreGateDecision] maps a persisted
///   `(provider, modelId, baseUrl)` triple to restore / auto-repair /
///   refuse-with-diagnostic before a mixed binding can boot.
///
/// Every refusal is single-line and actionable (E6): it names the
/// mismatched quadruple fields and the exact repair command, never a
/// "re-authorize `<provider>`" redirect (the incident's wrong-remedy class,
/// gh-178 AC6) and never an enumeration of unrelated configured keys (the
/// key-inventory disclosure class).
///
/// Pure Dart: the functions take plain data plus injectable predicates —
/// no AgentCli, no IO — so the gate decisions are unit-testable without
/// driving the CLI (UT-1..UT-4).
library;

import 'custom_providers.dart' show canonicalProviderName;

/// One coherence refusal: `problem` names what is mixed, `fields` the
/// mismatched quadruple members, `repair` the exact command that fixes it.
final class ModelCoherenceRefusal {
  /// Creates a refusal; [fields] and [repair] are required so a refusal
  /// can never be raised without naming both (AC6).
  const ModelCoherenceRefusal({
    required this.problem,
    required this.fields,
    required this.repair,
  });

  /// What is incoherent, in one clause.
  final String problem;

  /// The mismatched quadruple field names (`provider`, `model`, `baseUrl`,
  /// `key`, `authHeader`).
  final List<String> fields;

  /// The exact command that repairs the mismatch.
  final String repair;

  /// The single-line user-facing message (E6 — no stacks, no multi-line
  /// dumps, no unrelated key names).
  String get message {
    final buffer = StringBuffer('model coherence refusal: $problem');
    if (fields.isNotEmpty) {
      buffer.write(' (mismatched: ${fields.join(', ')})');
    }
    buffer.write(' — $repair');
    return buffer.toString();
  }

  @override
  String toString() => message;
}

/// The decision a model pick resolves to under the switch gate.
sealed class ModelSwitchPlan {
  const ModelSwitchPlan();
}

/// A same-provider pick: the plain model-id switch may apply — the
/// current triple (provider, endpoint, key family, auth header) stays.
final class SameModelSwitch extends ModelSwitchPlan {
  const SameModelSwitch(this.modelId);

  /// The model id to set on the CURRENT triple.
  final String modelId;
}

/// A cross-provider pick: the WHOLE triple must move (provider + endpoint
/// + key family + auth header) via the provider-switch flow — the
/// same-provider reuse path is never applied.
final class CrossProviderSwitch extends ModelSwitchPlan {
  const CrossProviderSwitch(this.provider, this.modelId);

  /// The target provider identity (catalog name or saved entry name).
  final String provider;

  /// The model id on the target provider.
  final String modelId;
}

/// The pick cannot proceed coherently: surface [refusal], change nothing.
final class RefusedSwitch extends ModelSwitchPlan {
  const RefusedSwitch(this.refusal);

  final ModelCoherenceRefusal refusal;
}

/// Resolves a typed `/model <target>` (or an entry rendered as
/// `provider/model`) to a [ModelSwitchPlan].
///
/// Model ids can THEMSELVES carry a slash (OpenRouter's vendor-prefixed
/// `anthropic/claude-*` ids), so the split is disambiguated with a fixed,
/// documented precedence — every reading lands on a coherent outcome, so
/// the invariant never depends on guessing right (E2):
///
/// 1. `<activeIdentity>/<id>` — the explicit current-provider form (the
///    numbered `/models` listing renders exactly this shape for the
///    active provider's rows) → same-provider switch to `<id>`;
/// 2. the full string is a model id the active endpoint itself lists
///    (`openai/gpt-4o` while OpenRouter is active) → same-provider
///    switch of the full id;
/// 3. the head is a KNOWN provider identity (catalog record or saved
///    entry) different from the active one → whole-triple
///    [CrossProviderSwitch] (`kimi/kimi-for-coding` while copilot is
///    active — the gh-178 incident shape);
/// 4. otherwise the whole string rides the active endpoint as before (an
///    unknown-prefix id is a model id by definition — same-provider).
ModelSwitchPlan parseTypedModelTarget(
  String input, {
  required String activeProvider,
  required String? activeCustomName,
  required Set<String> activeModelIds,
  required bool Function(String providerName) isKnownProvider,
}) {
  final target = input.trim();
  final slash = target.indexOf('/');
  if (slash <= 0 || slash == target.length - 1) {
    return SameModelSwitch(target);
  }
  final head = target.substring(0, slash).trim();
  final rest = target.substring(slash + 1).trim();
  if (head.isEmpty || rest.isEmpty) return SameModelSwitch(target);
  if (_sameProviderIdentity(head, activeProvider, activeCustomName)) {
    return SameModelSwitch(rest);
  }
  if (activeModelIds.contains(target)) return SameModelSwitch(target);
  if (isKnownProvider(head)) return CrossProviderSwitch(head, rest);
  return SameModelSwitch(target);
}

/// Whether [a] names the same provider identity as the active one — the
/// active custom entry's own name or the active (canonical) provider name.
bool sameProviderIdentity(String a, String activeProvider, String? activeName) {
  if (_foldsTo(a, activeProvider)) return true;
  return activeName != null && _foldsTo(a, activeName);
}

bool _foldsTo(String a, String b) =>
    a.trim().toLowerCase() == b.trim().toLowerCase() ||
    canonicalProviderName(a) == canonicalProviderName(b);

bool _sameProviderIdentity(
  String a,
  String activeProvider,
  String? activeCustomName,
) => sameProviderIdentity(a, activeProvider, activeCustomName);

/// Why a cross-provider pick is refused UP FRONT (G1, E1/E3) — null when
/// the whole-triple switch may proceed.
///
/// - [targetResolvable] false → E1: the entry's provider disappeared
///   between listing and picking; the refusal names the provider and the
///   reconfigure command, and no partial triple is applied.
/// - Legacy wiring (no roles resolver) with [targetKeyResolved] false →
///   E3: the switch would bake an empty key and the request would leave
///   credential-less; the refusal names the TARGET provider's key slot.
///   Roles mode is exempt: the chain resolves keys per entry at request
///   time and skips with the correct-slot hint, so a switch is allowed.
ModelCoherenceRefusal? crossProviderSwitchRefusal({
  required String providerName,
  required bool targetResolvable,
  required bool rolesMode,
  required bool targetKeyResolved,
  required String? targetKeySlot,
}) {
  if (!targetResolvable) {
    return ModelCoherenceRefusal(
      problem:
          'provider "$providerName" is not configured '
          '(removed since the list was built?)',
      fields: const ['provider'],
      repair: '/provider add — or pick a configured provider with /provider',
    );
  }
  if (!rolesMode && !targetKeyResolved) {
    return ModelCoherenceRefusal(
      problem: 'no key resolved for provider "$providerName"',
      fields: const ['key'],
      repair:
          '/key set ${targetKeySlot ?? '<ENDPOINT_KEY_NAME>'} <value> and '
          'retry /model',
    );
  }
  return null;
}

/// The G2 verdict inputs the host computes; the function turns them into
/// a refusal or null. Kept as plain data so the decision is testable
/// without the CLI (UT-2).
final class RequestCoherenceInput {
  const RequestCoherenceInput({
    required this.modelProviderName,
    required this.modelId,
    required this.baseUrl,
    required this.identityKind,
    required this.wiringKind,
    this.bindingError,
    required this.wiringKeyPresent,
    required this.explicitToken,
    required this.headerAuth,
    required this.activeFamilyResolvesSameKey,
    required this.foreignFamilyResolvesSameKey,
    this.mismatch,
  });

  /// The provider name the live model claims.
  final String modelProviderName;

  /// The live model id.
  final String modelId;

  /// The endpoint the request would hit.
  final String baseUrl;

  /// The adapter kind the claimed identity speaks, or null when the
  /// identity does not resolve (unknown provider record).
  final String? identityKind;

  /// The adapter kind the session wiring was built for.
  final String wiringKind;

  /// The [ProviderModelBinding] verdict message for
  /// (identityKind, modelId, baseUrl), or null when it resolved.
  final String? bindingError;

  /// Whether the wiring carries a non-empty key.
  final bool wiringKeyPresent;

  /// Whether the key was explicitly provided for this endpoint this
  /// session (`/provider <name> --token …`) — trusted, never judged.
  final bool explicitToken;

  /// Whether auth rides a header (cookie/`authHeader:`) instead of the
  /// bearer slot — the key-family tell does not apply.
  final bool headerAuth;

  /// Whether the model's endpoint OWN key family currently resolves the
  /// exact key the wiring carries.
  final bool activeFamilyResolvesSameKey;

  /// Whether some OTHER configured family resolves that same key (the
  /// incident's mixed-boot shape: the kimi family holds the key riding a
  /// copilot wiring).
  final bool foreignFamilyResolvesSameKey;

  /// Quadruple fields this input already knows are mismatched, with the
  /// problem clause — set for the identity/wire/binding failures.
  final ({String problem, List<String> fields})? mismatch;
}

/// G2: the request-build gate. Returns the refusal to surface instead of
/// the request, or null when the quadruple is coherent enough to send.
///
/// Deliberately conservative: a key that matches NO configured family at
/// all (a session-only explicit token, an OAuth blob, a synthetic test
/// key) is never refused — only a key that provably belongs to a KNOWN
/// other family while the active endpoint's own family resolves a
/// different value (or nothing) is a mixed triple.
ModelCoherenceRefusal? requestCoherenceRefusal(RequestCoherenceInput input) {
  final mismatch = input.mismatch;
  if (mismatch != null) {
    return ModelCoherenceRefusal(
      problem: mismatch.problem,
      fields: mismatch.fields,
      repair: '/provider ${input.modelProviderName} — then /model <id>',
    );
  }
  if (input.identityKind != input.wiringKind) {
    return ModelCoherenceRefusal(
      problem:
          'model claims provider "${input.modelProviderName}" (wire '
          '${input.identityKind}) but the session wiring speaks '
          '${input.wiringKind}',
      fields: const ['provider', 'baseUrl'],
      repair: '/provider ${input.modelProviderName} — then /model <id>',
    );
  }
  if (input.bindingError != null) {
    return ModelCoherenceRefusal(
      problem: input.bindingError!,
      fields: const ['provider', 'model', 'baseUrl'],
      repair: '/model <id> on a matching provider, or /provider <name>',
    );
  }
  if (!input.wiringKeyPresent ||
      input.explicitToken ||
      input.headerAuth ||
      input.activeFamilyResolvesSameKey) {
    return null;
  }
  if (!input.foreignFamilyResolvesSameKey) return null;
  return ModelCoherenceRefusal(
    problem:
        'the session key was resolved for a DIFFERENT provider family — '
        'it must not ride a request to ${input.baseUrl}',
    fields: const ['key', 'baseUrl'],
    repair:
        '/provider ${input.modelProviderName} to re-bind this endpoint\'s '
        'own key — then /model <id>',
  );
}

/// How a persisted triple may boot (G3).
enum RestoreGateVerdict { restore, repair, refuse }

/// The G3 decision for one persisted `(provider, modelId, baseUrl)`
/// triple.
final class RestoreGateDecision {
  const RestoreGateDecision.restore()
    : verdict = RestoreGateVerdict.restore,
      refusal = null,
      repairModelId = null;

  const RestoreGateDecision.repair(this.repairModelId, this.refusal)
    : verdict = RestoreGateVerdict.repair;

  const RestoreGateDecision.refuse(this.refusal)
    : verdict = RestoreGateVerdict.refuse,
      repairModelId = null;

  final RestoreGateVerdict verdict;

  /// The coherent model id to auto-repair to (OQ3: repair to the
  /// provider's coherent default, never silently — the refusal rides).
  final String? repairModelId;

  final ModelCoherenceRefusal? refusal;
}

/// G3: maps the persisted-triple verdicts to a boot decision (UT-3).
///
/// - A resolvable provider whose binding validates → restore as persisted.
/// - A resolvable provider whose binding is refused → auto-repair to the
///   provider's coherent default WITH the loud note (never boot mixed,
///   never bind endpoint and key from different layers — E4).
/// - A provider identity that no longer resolves → refuse the binding and
///   keep the boot default (the diagnostic names the conflict).
RestoreGateDecision restoreGateDecision({
  required bool providerResolvable,
  required bool bindingResolves,
  required String persistedModelId,
  required String providerName,
  required String repairModelId,
}) {
  if (providerResolvable && bindingResolves) {
    return const RestoreGateDecision.restore();
  }
  final refusal = providerResolvable
      ? ModelCoherenceRefusal(
          problem:
              'persisted model "$persistedModelId" does not form a valid '
              'binding with provider "$providerName"',
          fields: const ['provider', 'model', 'baseUrl'],
          repair: '/provider — then /model <id>',
        )
      : ModelCoherenceRefusal(
          problem:
              'persisted provider "$providerName" no longer resolves to a '
              'configured provider record',
          fields: const ['provider'],
          repair: '/provider — then /model <id>',
        );
  if (providerResolvable) {
    return RestoreGateDecision.repair(repairModelId, refusal);
  }
  return RestoreGateDecision.refuse(refusal);
}
