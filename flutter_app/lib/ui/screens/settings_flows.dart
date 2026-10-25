// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The settings connect/re-auth flow helpers (gh-1848 tier-3): part of
/// `settings.dart`'s library (gh-1232 god-file ceiling — the sweep's
/// extractions live here so the host file stays under the loc gate).
/// Extension members resolve statically inside the library, so the
/// callers in `settings.dart` are unchanged.
part of 'settings.dart';

/// Connect/re-auth/reset flow helpers of [_SettingsScreenState].
extension _SettingsFlowHelpers on _SettingsScreenState {
  /// The non-AIIN re-auth dispatch (gh-1848 tier-3 split): the Copilot
  /// connect flow for Copilot base URLs, the Codemie SSO flow otherwise.
  Future<bool> _reauthenticateOther(
    BuildContext context,
    ProviderRegistry registry,
    AgentService? service,
    CustomProvider provider,
  ) {
    if (isCopilotBaseUrl(provider.baseUrl)) {
      return runCopilotConnectFlow(
        context: context,
        registry: registry,
        service: service,
        lastConnectionStore: _fallbackConnectionStore(),
      );
    }
    return runCodemieSsoFlow(
      context: context,
      registry: registry,
      service: service,
      lastConnectionStore: _fallbackConnectionStore(),
      orgUrl: codeMieOrgUrl(provider.baseUrl),
    );
  }

  /// AIIN entries re-run the AIIN sign-in flow in re-auth mode
  /// (gh-1848 split).
  Future<bool> _reauthenticateAiin(
    BuildContext context,
    ProviderRegistry registry,
    AgentService? service,
    CustomProvider provider,
  ) {
    return runAiinConnectFlow(
      context: context,
      registry: registry,
      service: service,
      lastConnectionStore: _fallbackConnectionStore(),
      reauthenticateFor: provider,
    );
  }

  /// Runs one connect flow after a registry guard — the shared shape of
  /// the section's connect callbacks: a null registry renders the
  /// section but the flows do nothing (gh-1848 split).
  Future<void> _runConnectFlow(
    Future<void> Function(ProviderRegistry registry) run,
  ) async {
    final registry = widget.registry;
    if (registry == null) return;
    await run(registry);
  }
}
