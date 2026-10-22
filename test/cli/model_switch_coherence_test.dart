// UT-1 / UT-2 / UT-4 (gh-178): the pure coherence decision core — the
// switch-gate target parser, the request-build gate, the refusal message
// contract, and the restore gate — tested WITHOUT driving the CLI.
//
// The wiring tests (IT-*) live in agent_cli_model_coherence_test.dart.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('parseTypedModelTarget (UT-1, E2)', () {
    const activeProvider = 'copilot';
    const activeCustomName = 'copilot-acme';
    final activeIds = {'gemini-4-argon', 'gpt-4o', 'claude-sonnet'}.toSet();
    bool knownProvider(String name) =>
        const {'kimi', 'openai', 'openrouter', 'copilot', 'copilot-acme'}
            .contains(name);

    ModelSwitchPlan parse(String input) => parseTypedModelTarget(
      input,
      activeProvider: activeProvider,
      activeCustomName: activeCustomName,
      activeModelIds: activeIds,
      isKnownProvider: knownProvider,
    );

    test('plain ids (no slash) stay on the current triple', () {
      final plan = parse('kimi-for-coding');
      expect(plan, isA<SameModelSwitch>());
      expect((plan as SameModelSwitch).modelId, 'kimi-for-coding');
    });

    test('the explicit ACTIVE-identity form strips to the bare id', () {
      // The numbered listing renders `copilot-acme/gemini-4-argon` —
      // typing it back must be a same-provider pick, not a provider hop.
      expect(parse('copilot-acme/gemini-4-argon'), isA<SameModelSwitch>());
      expect(
        (parse('copilot-acme/gemini-4-argon') as SameModelSwitch).modelId,
        'gemini-4-argon',
      );
      expect(parse('copilot/gpt-4o'), isA<SameModelSwitch>());
    });

    test('a vendor-prefixed id the active endpoint lists stays put (E2)', () {
      // `gemini-4-argon` listed under a vendor-style spelling the cache
      // carries — the full string wins over the provider-prefix reading.
      expect(parse('gemini-4-argon/extra'), isA<SameModelSwitch>());
    });

    test('a KNOWN other-provider prefix moves the WHOLE triple', () {
      // The incident shape: `kimi/kimi-for-coding` while copilot is
      // active must never ride the copilot triple.
      final plan = parse('kimi/kimi-for-coding');
      expect(plan, isA<CrossProviderSwitch>());
      final cross = plan as CrossProviderSwitch;
      expect(cross.provider, 'kimi');
      expect(cross.modelId, 'kimi-for-coding');
    });

    test('an unknown prefix passes through as a model id (coherent)', () {
      final plan = parse('vendor-x/some-model');
      expect(plan, isA<SameModelSwitch>());
      expect((plan as SameModelSwitch).modelId, 'vendor-x/some-model');
    });

    test('degenerate splits (leading/trailing slash) stay same-provider', () {
      expect(parse('/leading'), isA<SameModelSwitch>());
      expect(parse('trailing/'), isA<SameModelSwitch>());
    });

    test('openrouter vendor ids survive when the active endpoint lists '
        'them (E2 precedence 2)', () {
      // Active openrouter, cache lists `openai/gpt-4o` — the id reading
      // beats the provider reading.
      final plan = parseTypedModelTarget(
        'openai/gpt-4o',
        activeProvider: 'openrouter',
        activeCustomName: null,
        activeModelIds: {'openai/gpt-4o', 'anthropic/claude-4'}.toSet(),
        isKnownProvider: knownProvider,
      );
      expect(plan, isA<SameModelSwitch>());
      expect((plan as SameModelSwitch).modelId, 'openai/gpt-4o');
    });
  });

  group('crossProviderSwitchRefusal (UT-1, E1/E3)', () {
    test('unresolvable target provider refuses naming it (E1)', () {
      final refusal = crossProviderSwitchRefusal(
        providerName: 'kimi',
        targetResolvable: false,
        rolesMode: false,
        targetKeyResolved: false,
        targetKeySlot: null,
      );
      expect(refusal, isNotNull);
      expect(refusal!.message, contains('kimi'));
      expect(refusal.message, contains('/provider'));
      expect(refusal.fields, contains('provider'));
    });

    test('legacy wiring with no target key refuses up front (E3)', () {
      final refusal = crossProviderSwitchRefusal(
        providerName: 'kimi',
        targetResolvable: true,
        rolesMode: false,
        targetKeyResolved: false,
        targetKeySlot: 'FA_KEY_API_KIMI_COM',
      );
      expect(refusal, isNotNull);
      expect(refusal!.message, contains('/key set FA_KEY_API_KIMI_COM'));
      expect(refusal.fields, contains('key'));
    });

    test('roles mode with an unresolved key is allowed (request-time '
        'resolution handles it)', () {
      final refusal = crossProviderSwitchRefusal(
        providerName: 'kimi',
        targetResolvable: true,
        rolesMode: true,
        targetKeyResolved: false,
        targetKeySlot: null,
      );
      expect(refusal, isNull);
    });

    test('a resolved target key passes', () {
      expect(
        crossProviderSwitchRefusal(
          providerName: 'kimi',
          targetResolvable: true,
          rolesMode: false,
          targetKeyResolved: true,
          targetKeySlot: 'FA_KEY_API_KIMI_COM',
        ),
        isNull,
      );
    });
  });

  group('requestCoherenceRefusal (UT-2, UT-4)', () {
    RequestCoherenceInput coherent() => RequestCoherenceInput(
      modelProviderName: 'kimi',
      modelId: 'kimi-for-coding',
      baseUrl: 'https://api.kimi.com/coding/v1',
      identityKind: 'openai-completions',
      wiringKind: 'openai-completions',
      wiringKeyPresent: true,
      explicitToken: false,
      headerAuth: false,
      activeFamilyResolvesSameKey: true,
      foreignFamilyResolvesSameKey: false,
    );

    test('a coherent quadruple passes', () {
      expect(requestCoherenceRefusal(coherent()), isNull);
    });

    test('an unresolvable provider identity refuses naming the field', () {
      final input = RequestCoherenceInput(
        modelProviderName: 'copilot-acme',
        modelId: 'kimi-for-coding',
        baseUrl: 'https://api.enterprise.githubcopilot.com',
        identityKind: null,
        wiringKind: 'copilot',
        wiringKeyPresent: true,
        explicitToken: false,
        headerAuth: false,
        activeFamilyResolvesSameKey: false,
        foreignFamilyResolvesSameKey: false,
        mismatch: (
          problem: 'model claims provider "copilot-acme" which does not '
              'resolve to a configured provider record',
          fields: ['provider'],
        ),
      );
      final refusal = requestCoherenceRefusal(input)!;
      expect(refusal.fields, ['provider']);
      expect(refusal.message, contains('copilot-acme'));
    });

    test('every wire-mismatch permutation over the fixture kinds refuses '
        'naming both sides (UT-2 matrix)', () {
      const kinds = ['openai-completions', 'anthropic', 'google', 'copilot'];
      for (final identity in kinds) {
        for (final wiring in kinds) {
          if (identity == wiring) continue;
          final input = RequestCoherenceInput(
            modelProviderName: 'kimi',
            modelId: 'kimi-for-coding',
            baseUrl: 'https://api.kimi.com/coding/v1',
            identityKind: identity,
            wiringKind: wiring,
            wiringKeyPresent: true,
            explicitToken: false,
            headerAuth: false,
            activeFamilyResolvesSameKey: true,
            foreignFamilyResolvesSameKey: false,
          );
          final refusal = requestCoherenceRefusal(input);
          expect(refusal, isNotNull, reason: '$identity vs $wiring');
          expect(refusal!.fields, containsAll(['provider', 'baseUrl']));
          expect(refusal.message, contains(identity));
          expect(refusal.message, contains(wiring));
        }
      }
    });

    test('a rejected binding refuses carrying the binding verdict', () {
      final input = RequestCoherenceInput(
        modelProviderName: 'google',
        modelId: 'gpt-4o',
        baseUrl: 'https://generativelanguage.googleapis.com',
        identityKind: 'google',
        wiringKind: 'google',
        bindingError: 'model "gpt-4o" is not a google-dialect id',
        wiringKeyPresent: true,
        explicitToken: false,
        headerAuth: false,
        activeFamilyResolvesSameKey: true,
        foreignFamilyResolvesSameKey: false,
      );
      final refusal = requestCoherenceRefusal(input)!;
      expect(refusal.fields, contains('model'));
      expect(refusal.message, contains('gpt-4o'));
    });

    test('the mixed-key tell refuses: key belongs to a foreign family '
        'while the active family resolves a different value (the incident '
        'shape)', () {
      final input = RequestCoherenceInput(
        modelProviderName: 'copilot',
        modelId: 'kimi-for-coding',
        baseUrl: 'https://api.enterprise.githubcopilot.com',
        identityKind: 'copilot',
        wiringKind: 'copilot',
        wiringKeyPresent: true,
        explicitToken: false,
        headerAuth: false,
        activeFamilyResolvesSameKey: false,
        foreignFamilyResolvesSameKey: true,
      );
      final refusal = requestCoherenceRefusal(input)!;
      expect(refusal.fields, containsAll(['key', 'baseUrl']));
      expect(refusal.message, contains('/provider'));
    });

    test('a key matching NO configured family never refuses (explicit '
        'tokens, OAuth blobs, synthetic test keys)', () {
      final input = coherent()
        ..copyWithActiveFamilyResolvesSame(false);
      expect(
        requestCoherenceRefusal(
          RequestCoherenceInput(
            modelProviderName: 'kimi',
            modelId: 'kimi-for-coding',
            baseUrl: 'https://api.kimi.com/coding/v1',
            identityKind: 'openai-completions',
            wiringKind: 'openai-completions',
            wiringKeyPresent: true,
            explicitToken: false,
            headerAuth: false,
            activeFamilyResolvesSameKey: false,
            foreignFamilyResolvesSameKey: false,
          ),
        ),
        isNull,
      );
    });

    test('explicit-token and header-auth wiring never refuse', () {
      expect(
        requestCoherenceRefusal(
          coherent().copyWith(explicitToken: true, activeFamilySame: false),
        ),
        isNull,
      );
      expect(
        requestCoherenceRefusal(
          coherent().copyWith(headerAuth: true, activeFamilySame: false),
        ),
        isNull,
      );
      expect(
        requestCoherenceRefusal(
          coherent().copyWith(keyPresent: false, activeFamilySame: false),
        ),
        isNull,
      );
    });
  });

  group('refusal message contract (UT-4, AC6)', () {
    test('messages name fields + repair, never "re-authorize", never key '
        'enumeration', () {
      final refusals = [
        const ModelCoherenceRefusal(
          problem: 'provider "kimi" is not configured',
          fields: ['provider'],
          repair: '/provider add',
        ),
        const ModelCoherenceRefusal(
          problem: 'no key resolved',
          fields: ['key'],
          repair: '/key set FA_KEY_API_KIMI_COM <value>',
        ),
        const ModelCoherenceRefusal(
          problem: 'wire mismatch',
          fields: ['provider', 'baseUrl'],
          repair: '/provider kimi',
        ),
      ];
      for (final refusal in refusals) {
        final message = refusal.message;
        expect(containsIgnoringCase(message, 're-authorize'), isFalse);
        expect(message, startsWith('model coherence refusal:'));
        expect(message, contains('—'));
        // Single line (E6).
        expect(message.contains('\n'), isFalse);
      }
    });
  });

  group('restoreGateDecision (UT-3)', () {
    test('a coherent persisted triple restores', () {
      final decision = restoreGateDecision(
        providerResolvable: true,
        bindingResolves: true,
        persistedModelId: 'kimi-for-coding',
        providerName: 'openai-completions',
        repairModelId: 'gpt-4o-mini',
      );
      expect(decision.verdict, RestoreGateVerdict.restore);
      expect(decision.refusal, isNull);
    });

    test('a mixed persisted triple auto-repairs WITH the diagnostic (OQ3)',
        () {
      final decision = restoreGateDecision(
        providerResolvable: true,
        bindingResolves: false,
        persistedModelId: 'gemini-4-argon',
        providerName: 'google',
        repairModelId: 'gemini-2.5-flash',
      );
      expect(decision.verdict, RestoreGateVerdict.repair);
      expect(decision.repairModelId, 'gemini-2.5-flash');
      expect(decision.refusal, isNotNull);
      expect(decision.refusal!.message, contains('gemini-4-argon'));
      expect(decision.refusal!.message, contains('google'));
      expect(decision.refusal!.message, contains('/provider'));
    });

    test('a deleted provider record refuses and names the conflict (E4)',
        () {
      final decision = restoreGateDecision(
        providerResolvable: false,
        bindingResolves: false,
        persistedModelId: 'kimi-for-coding',
        providerName: 'gone-provider',
        repairModelId: 'gpt-4o-mini',
      );
      expect(decision.verdict, RestoreGateVerdict.refuse);
      expect(decision.repairModelId, isNull);
      expect(decision.refusal!.message, contains('gone-provider'));
      expect(decision.refusal!.fields, ['provider']);
    });
  });
}

extension on RequestCoherenceInput {
  // Test shorthands: rebuild with one verdict flipped.
  RequestCoherenceInput copyWithActiveFamilyResolvesSame(bool value) =>
      RequestCoherenceInput(
        modelProviderName: modelProviderName,
        modelId: modelId,
        baseUrl: baseUrl,
        identityKind: identityKind,
        wiringKind: wiringKind,
        wiringKeyPresent: wiringKeyPresent,
        explicitToken: explicitToken,
        headerAuth: headerAuth,
        activeFamilyResolvesSameKey: value,
        foreignFamilyResolvesSameKey: foreignFamilyResolvesSameKey,
      );

  RequestCoherenceInput copyWith({
    bool? explicitToken,
    bool? headerAuth,
    bool? keyPresent,
    bool? activeFamilySame,
  }) => RequestCoherenceInput(
    modelProviderName: modelProviderName,
    modelId: modelId,
    baseUrl: baseUrl,
    identityKind: identityKind,
    wiringKind: wiringKind,
    wiringKeyPresent: keyPresent ?? wiringKeyPresent,
    explicitToken: explicitToken ?? this.explicitToken,
    headerAuth: headerAuth ?? this.headerAuth,
    activeFamilyResolvesSameKey:
        activeFamilySame ?? activeFamilyResolvesSameKey,
    foreignFamilyResolvesSameKey: foreignFamilyResolvesSameKey,
  );
}

bool containsIgnoringCase(String haystack, String needle) =>
    haystack.toLowerCase().contains(needle.toLowerCase());
