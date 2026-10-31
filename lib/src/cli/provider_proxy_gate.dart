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
}
