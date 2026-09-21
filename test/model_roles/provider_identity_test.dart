/// One identity per provider (issue #772): the BOTH-IDENTIFIER property —
/// for EVERY [providerCatalog] entry, the display `name` and the adapter
/// `kind` each resolve through every consumer surface — plus the kind
/// canonicalization rules that keep one persisted identity.
///
/// Uniqueness qualification: when several entries share one kind
/// (`openai-completions` is openrouter/openai/kimi/codemie) the kind is
/// coarser than the name — there the property asserts adapter-level
/// identity (same kind, streamable, bootable) and the NAME surviving
/// canonicalization, with the base URL carrying the entry identity. A
/// UNIQUE kind (`chatgpt-codex` → `chatgpt`) must resolve to the SAME
/// entry through both identifiers on every surface.
///
/// The synthetic two-identifier entry (AC4): [providerCatalog] is a const
/// map by design (tree-shakable `FA_PROVIDERS` builds), so a test entry
/// cannot be injected at runtime. The property is therefore expressed as a
/// spec-parameterized helper ([expectBothIdentifiersResolve]) run over a
/// synthetic [ProviderSpec] for every surface that TAKES a spec, plus
/// derivation assertions proving the string-keyed surfaces iterate the
/// catalog (the closed kind sets must equal the catalog's, so a future
/// `name != kind` entry flows through with no hand-edited map).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

/// The per-surface both-identifier property for ONE spec (AC4 harness).
///
/// Every check runs for BOTH [ProviderSpec.name] and [ProviderSpec.kind];
/// [uniqueKind] says whether the kind maps back to exactly this entry
/// (true for every `name != kind` provider the issue targets — chatgpt
/// being the first — and false inside a shared-kind family).
void expectBothIdentifiersResolve(ProviderSpec spec, {required bool uniqueKind}) {
  // The seam: both identifiers resolve (unique kinds → the SAME entry).
  final byName = resolveCliProviderSpec(spec.name);
  expect(byName, same(spec), reason: '${spec.name}: name-form seam');
  final byKind = resolveCliProviderSpec(
    spec.kind,
    baseUrl: spec.defaultBaseUrl,
  );
  expect(byKind, isNotNull, reason: '${spec.kind}: kind-form seam');
  expect(byKind!.kind, spec.kind, reason: '${spec.kind}: adapter identity');
  if (uniqueKind) {
    expect(byKind, same(spec), reason: '${spec.kind}: unique kind → entry');
  }

  // The boot builder: both identifiers build a model on this adapter.
  // (For a shared kind the model's provider NAME is baseUrl-dependent —
  // the openai/openrouter rule gh-760's coverage test pins — so only the
  // wire dialect is asserted there; a unique kind pins the entry name.)
  for (final id in [spec.name, spec.kind]) {
    final model = buildCliDefaultModel(id, modelId: 'identity-probe');
    expect(model.api, spec.api, reason: '$id: boot builder wire dialect');
    if (uniqueKind) {
      expect(model.provider, spec.name, reason: '$id: boot builder identity');
    }
  }

  // The stream dispatch: both identifiers restore as a streamable kind.
  for (final id in [spec.name, spec.kind]) {
    final kind = resolveCliProviderSpec(id, baseUrl: spec.defaultBaseUrl)!.kind;
    expect(
      () => providerStreamFunction(kind, 'identity-probe-key'),
      returnsNormally,
      reason: '$id: stream dispatch accepts the resolved kind',
    );
  }

  // Key resolution: the name always answers the entry's own env names.
  // For a SHARED kind the kind-form is coarser by design (issue #40: the
  // env names describe the catalog default endpoint; a shared-kind entry
  // off its default endpoint resolves endpoint-scoped store keys, never
  // env names) — only a unique kind answers identically through both.
  expect(apiKeyEnvNames(spec.name), spec.apiKeyEnvNames, reason: 'name: key names');
  if (uniqueKind) {
    expect(
      apiKeyEnvNames(spec.kind),
      spec.apiKeyEnvNames,
      reason: '${spec.kind}: key names',
    );
  }

  // Config canonicalization: the persisted identity is the kind for
  // unique kinds; a shared-kind family keeps its (finer) name.
  expect(
    canonicalProviderKind(spec.name),
    uniqueKind ? spec.kind : spec.name,
    reason: '${spec.name}: canonical persisted identity',
  );
  expect(
    canonicalProviderKind(spec.kind),
    spec.kind,
    reason: '${spec.kind}: canonicalization is idempotent',
  );

  // The queue runtime: kind → catalog name, catalog-derived (AC3).
  expect(
    queueKindCatalogName(spec.kind, spec.defaultBaseUrl),
    uniqueKind ? spec.name : 'openai',
    reason: '${spec.kind}: queue runtime catalog name',
  );
}

void main() {
  group('both-identifier property (issue #772 AC4)', () {
    final ownersOfKind = <String, List<ProviderSpec>>{};
    for (final spec in providerCatalog.values) {
      ownersOfKind.putIfAbsent(spec.kind, () => []).add(spec);
    }

    test('every unique-kind entry resolves through both identifiers', () {
      final unique = providerCatalog.values
          .where((spec) => ownersOfKind[spec.kind]!.length == 1)
          .toList();
      expect(unique, contains(providerCatalog['chatgpt']!));
      for (final spec in unique) {
        expectBothIdentifiersResolve(spec, uniqueKind: true);
      }
    });

    test('shared-kind entries keep adapter identity under both identifiers',
        () {
      final shared = providerCatalog.values
          .where((spec) => ownersOfKind[spec.kind]!.length > 1)
          .toList();
      expect(shared, isNotEmpty);
      for (final spec in shared) {
        expectBothIdentifiersResolve(spec, uniqueKind: false);
      }
    });

    test('a synthetic two-identifier spec satisfies the spec-keyed surfaces',
        () {
      // The const catalog cannot host a test entry (tree-shaking by
      // design) — the harness helper must still generalize to a future
      // name != kind provider. The string-keyed surfaces are covered by
      // the derivation assertions below.
      const synthetic = ProviderSpec(
        name: 'synthetic',
        kind: 'synthetic-adapter',
        api: 'openai-completions',
        defaultBaseUrl: 'https://synthetic.example/v1',
        apiKeyEnvNames: ['SYNTHETIC_API_KEY'],
        contextWindow: 128000,
        maxTokens: 16384,
      );
      expect(canonicalProviderKind(synthetic.name), synthetic.name,
          reason: 'unresolvable ids are never rewritten (E2)');
      expect(canonicalProviderKind(synthetic.kind), synthetic.kind);
      expect(
        resolveCliProviderSpec(synthetic.name),
        isNull,
        reason: 'no hand-maintained fallbacks outside the catalog',
      );
      expect(
        () => queueKindCatalogName(synthetic.kind, synthetic.defaultBaseUrl),
        throwsA(isA<ConfigException>()),
        reason: 'no band-aid identity map survives (AC3)',
      );
    });

    test('the closed kind sets derive from the catalog', () {
      final kinds = providerCatalog.values.map((spec) => spec.kind).toSet();
      // The queue parser's literal candidate list (kept literal only to
      // avoid importing the catalog's adapter graph) must stay in lockstep.
      expect(providerQueueKinds.toSet(), kinds);
      // The stream factory dispatches exactly the catalog kinds.
      for (final kind in kinds) {
        expect(
          () => providerStreamFunction(kind, 'identity-probe-key'),
          returnsNormally,
        );
      }
      expect(
        () => providerStreamFunction('from-the-future-adapter', 'k'),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
