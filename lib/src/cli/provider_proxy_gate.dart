part of 'agent_cli.dart';

/// Per-provider proxied HTTP clients (issue #1921).
///
/// A provider with a `network:` block in `~/.fah/config.yaml` rides that
/// proxy for EVERY request — unary, SSE, retries (the retry wrapper
/// re-invokes the same client), model lists, and quota. There is no
/// direct fallback: every transport failure of the proxied client is
/// remapped by [FailClosedProxyClient] into an actionable error naming
/// `network.proxy` / `proxyPasswordEnv`, which the adapters surface as
/// their error event. Providers without a block keep the shared direct
/// client — byte-identical legacy behavior.

/// One keep-alive client per bound provider, shared across rebinds (key
/// updates, model switches) and never shared across providers (E4).
final _proxiedProviderClients = <String, http.Client>{};

extension ProviderProxyGate on AgentCli {
  /// The fail-closed proxied client for [providerName], or null when the
  /// provider has no `network:` block (the direct path).
  ///
  /// A missing `proxyPasswordEnv` value throws [ConfigException] at bind
  /// time — before any egress.
  http.Client? proxiedProviderClient(String? providerName) {
    if (providerName == null || providerName.isEmpty) return null;
    final network = config.providerNetworks[providerName];
    if (network == null) return null;
    return _proxiedProviderClients.putIfAbsent(
      providerName,
      // The connectors return FailClosedProxyClients already — the
      // fail-closed remap is part of the produced client.
      () =>
          ioProxyConnector(network, providerName: providerName).createClient(),
    );
  }

  /// The HTTP client for one provider's model-list fetches (OQ2: same
  /// provider, same gate — a bound provider's `/models` traffic rides its
  /// proxy). Test injection ([AgentCliConfig.modelsHttpClient]) still wins.
  http.Client? modelFetchClient(String providerName) =>
      config.modelsHttpClient ?? proxiedProviderClient(providerName);

  /// The client for a fetch whose provider identity is only one of several
  /// candidate names (wizard-time fetches run BEFORE the entry name
  /// exists): test injection wins, then the first BOUND candidate, else
  /// null — the direct path, byte-identical legacy behavior.
  http.Client? modelFetchClientFor(List<String> candidateNames) {
    if (config.modelsHttpClient != null) return config.modelsHttpClient;
    for (final name in candidateNames) {
      if (config.providerNetworks.containsKey(name)) {
        return modelFetchClient(name);
      }
    }
    return null;
  }

  /// The proxy-binding key candidates for the dial wizard's deployment
  /// fetch, in binding-probability order: the re-run entry's saved name
  /// (setup reuses the entry), the host-derived default name (the name
  /// prompt pre-fills it), the catalog name. A user can bind a `network:`
  /// block under ANY of the three — the literal catalog key alone missed
  /// the first two (review of the test-speed branch).
  List<String> dialWizardClientKeyCandidates(String baseUrl) {
    String? existingName;
    final entries = config.customProviders?.entries ?? const [];
    for (final e in entries) {
      if (e.apiType == dialDispatchHint && e.baseUrl == baseUrl) {
        existingName = e.name;
        break;
      }
    }
    return [?existingName, _codeMieHostName(baseUrl), dialDispatchHint];
  }

  /// The fail-closed client for the dial wizard's deployment fetch (see
  /// [dialWizardClientKeyCandidates] for the candidate order).
  http.Client? dialWizardModelFetchClient(String baseUrl) =>
      modelFetchClientFor(dialWizardClientKeyCandidates(baseUrl));
}
