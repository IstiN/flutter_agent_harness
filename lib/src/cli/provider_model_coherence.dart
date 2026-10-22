// The gh-1788 G2/G5 request-build gate: the AgentCli STATE ADAPTER half of
// the model-switch coherence check. The pure decision core lives in
// `model_switch_coherence.dart` (a standalone library — hosts reuse it
// without the CLI); this part file owns the CLI-side wiring only: reading
// the live quadruple (wiring kind, keys, headers) out of the [AgentCli]
// state and turning a refusal into the terminal-visible [ErrorEvent].
// Kept out of provider_commands.dart to hold that file under the repo's
// 2800-line size gate.
part of 'agent_cli.dart';

extension on AgentCli {
  /// [_catalogStreamFunction] with the G2 gate wrapped around it (see its
  /// kdoc): the live model's quadruple is judged at call time, and a mixed
  /// triple surfaces the refusal as an [ErrorEvent] INSTEAD of the request
  /// (nothing leaves the process). The roles-chain and provider-queue paths
  /// never flow through here: they assemble model+key+stream from one
  /// [ModelRef] each, coherent by construction.
  StreamFunction _gateCatalogStream(StreamFunction inner) {
    return (model, context, {cancelToken}) {
      final refusal = _requestBuildRefusal(model);
      if (refusal != null) {
        final state = ProviderStreamState(model)
          ..errorMessage = refusal.message;
        final stream = AssistantMessageEventStream();
        stream.push(
          ErrorEvent(
            reason: StopReason.error,
            error: state.snapshot(finalize: true),
          ),
        );
        stream.end();
        return stream;
      }
      return inner(model, context, cancelToken: cancelToken);
    };
  }

  /// The G2 request-build verdict for [model] under the CURRENT wiring:
  /// null = coherent, the request may be built. Conservative by design —
  /// only provable mixtures refuse (an unresolvable provider identity, a
  /// wire mismatch, a rejected binding, or a key that provably belongs to
  /// a DIFFERENT configured family while this endpoint's own family
  /// resolves a different value). Keys that match no configured family at
  /// all (session-only explicit tokens, OAuth blobs, synthetic test keys)
  /// and header-auth wiring never refuse.
  ModelCoherenceRefusal? _requestBuildRefusal(Model model) {
    final spec = resolveCliProviderSpec(model.provider);
    if (spec == null) {
      return requestCoherenceRefusal(
        RequestCoherenceInput(
          modelProviderName: model.provider,
          modelId: model.id,
          baseUrl: model.baseUrl,
          identityKind: null,
          wiringKind: _providerKind,
          mismatch: (
            problem:
                'model claims provider "${model.provider}" which does not '
                'resolve to a configured provider record',
            fields: ['provider'],
          ),
          wiringKeyPresent: false,
          explicitToken: false,
          headerAuth: false,
          activeFamilyResolvesSameKey: false,
          foreignFamilyResolvesSameKey: false,
        ),
      );
    }
    final identityKind = spec.kind;
    String? bindingError;
    try {
      ProviderModelBinding.resolve(
        providerKind: identityKind,
        modelId: model.id,
        baseUrl: model.baseUrl,
        provenance: BindingProvenance.command,
      );
    } on ConfigException catch (error) {
      bindingError = error.message;
    }
    final headerAuth = model.headers?.containsKey('cookie') ?? false;
    var activeFamilyResolvesSameKey = false;
    var foreignFamilyResolvesSameKey = false;
    if (!headerAuth &&
        !_explicitToken &&
        _apiKey.isNotEmpty &&
        bindingError == null) {
      final activeKey = _providerKeyFor(spec, model.baseUrl);
      activeFamilyResolvesSameKey = activeKey != null && activeKey == _apiKey;
      if (!activeFamilyResolvesSameKey) {
        foreignFamilyResolvesSameKey = _foreignFamilyHoldsKey(
          _apiKey,
          model.provider,
        );
      }
    }
    return requestCoherenceRefusal(
      RequestCoherenceInput(
        modelProviderName: model.provider,
        modelId: model.id,
        baseUrl: model.baseUrl,
        identityKind: identityKind,
        wiringKind: _providerKind,
        bindingError: bindingError,
        wiringKeyPresent: _apiKey.isNotEmpty,
        explicitToken: _explicitToken,
        headerAuth: headerAuth,
        activeFamilyResolvesSameKey: activeFamilyResolvesSameKey,
        foreignFamilyResolvesSameKey: foreignFamilyResolvesSameKey,
      ),
    );
  }

  /// Whether any OTHER configured provider family (catalog env names on
  /// their default endpoints, saved entries' own key slots) resolves
  /// exactly [key] — the incident's tell that the wiring key came from a
  /// foreign family. Values only, never names: the refusal text never
  /// enumerates the machine's keys.
  bool _foreignFamilyHoldsKey(String key, String activeProviderName) {
    for (final candidate in enabledProviders()) {
      if (candidate.name == activeProviderName) continue;
      if (_providerKeyFor(candidate, candidate.defaultBaseUrl) == key) {
        return true;
      }
    }
    final registry = config.customProviders;
    for (final entry in registry?.entries ?? const <CustomProviderEntry>[]) {
      if (sameProviderIdentity(
        entry.name,
        activeProviderName,
        _activeCustomName,
      )) {
        continue;
      }
      final keyName = entry.keyName;
      final token = keyName == null
          ? null
          : (config.secureKeys?.available ?? false
                ? config.secureKeys?.read(keyName)
                : null);
      if (token == key) return true;
    }
    return false;
  }
}
