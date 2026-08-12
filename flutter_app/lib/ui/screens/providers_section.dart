// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The provider settings UI lives in the `fa_ui` package; this file
/// re-exports it and keeps the app-level [DefaultChatModelSection] adapter
/// that wires the package's default-chat-model flow to [AgentService], the
/// last-connection store, and the on-device engines.
library;

import 'package:fa_ui/fa_ui.dart' as fa_ui;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/chatgpt_oauth_flow.dart';
import 'package:fa/services/codemie_sso_flow.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/openrouter_oauth_coordinator.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/webllm/webllm_types.dart';

export 'package:fa_ui/fa_ui.dart'
    show
        ProvidersSection,
        DefaultModelProviderPickerPage,
        DefaultModelPickerPage,
        FaOnDeviceRoute,
        FaChatConnection,
        FaChatModelConfig,
        ModelIdAutocompleteField;

/// The settings "Default chat model" section — the app adapter over the
/// `fa_ui` package's section: applying reconfigures [service] and saves the
/// last connection, and the on-device presets route through the regular
/// [AgentSettingsForm] (engine download + progress) via injected
/// [fa_ui.FaOnDeviceRoute]s.
class DefaultChatModelSection extends StatelessWidget {
  const DefaultChatModelSection({
    super.key,
    required this.service,
    this.registry,
    this.lastConnectionStore,
    this.modelsFetcher,
    this.providerModelFetcher,
    this.webLlmEngine,
    this.gemmaEngine,
    this.transformersJsEngine,
    this.isWeb,
  });

  /// The service whose backend the flow reconfigures.
  final AgentService service;

  /// The user-added providers listed in the picker.
  final ProviderRegistry? registry;

  /// Updated on every successful apply (see [LastConnectionStore]).
  final LastConnectionStore? lastConnectionStore;

  /// `/models` fetch override (tests), forwarded to the model page.
  final ModelsEndpointFetcher? modelsFetcher;

  /// Provider-specific model-list fetcher for non-standard endpoints (e.g.
  /// CodeMie). Forwarded to the [fa_ui.UnifiedModelPickerPage].
  final fa_ui.ProviderModelFetcher? providerModelFetcher;

  /// Engine overrides for the on-device routes (tests).
  final WebLlmEngineApi? webLlmEngine;
  final GemmaEngineApi? gemmaEngine;
  final TransformersJsEngineApi? transformersJsEngine;

  /// Platform override for tests (see [AgentSettingsForm.isWeb]).
  final bool? isWeb;

  /// Applies [config] as the main connection: reconfigure the service,
  /// persist the last connection.
  Future<void> _apply(AgentConfig config) async {
    await service.reconfigure(config);
    await lastConnectionStore?.saveFromConfig(config);
  }

  @override
  Widget build(BuildContext context) {
    final web = isWeb ?? kIsWeb;
    final reg = registry ?? ProviderRegistry.inMemory();
    return fa_ui.DefaultChatModelSection(
      connection: service,
      onApply: (config) => _apply(agentConfigFrom(config)),
      registry: reg,
      modelsFetcher: modelsFetcher,
      providerModelFetcher: (baseUrl, apiKey) async {
        // CodeMie uses /llm_models with Cookie auth instead of /models Bearer.
        if (baseUrl.contains('/code-assistant-api/')) {
          return fetchCodeMieModels(baseUrl, apiKey);
        }
        return const [];
      },
      // The on-device presets connect through the regular form (engine
      // download + progress) pre-selected to the provider.
      onDeviceProviders: buildOnDeviceProviderRoutes(
        context,
        registry: reg,
        onApply: _apply,
        webLlmEngine: webLlmEngine,
        gemmaEngine: gemmaEngine,
        transformersJsEngine: transformersJsEngine,
        isWeb: isWeb,
      ),
      providerKindLabels: {
        if (webLlmProviderVisible(isWeb: web))
          webLlmProviderKind: ProviderPreset.webllm.labelFor(context),
        gemmaProviderKind: ProviderPreset.gemma.labelFor(context),
        transformersJsProviderKind: ProviderPreset.transformersJs.labelFor(
          context,
        ),
      },
      addProviderPage: (context) => fa_ui.AddProviderPresetPickerPage(
        registry: reg,
        onCodeMieSso: () async {
          Navigator.of(context).pop();
          await runCodemieSsoFlow(
            context: context,
            registry: reg,
            service: service,
            lastConnectionStore:
                lastConnectionStore ?? LastConnectionStore.inMemory(),
          );
        },
        onChatGptOAuth: () async {
          Navigator.of(context).pop();
          await runChatGptOAuthFlow(
            context: context,
            registry: reg,
            service: service,
            lastConnectionStore:
                lastConnectionStore ?? LastConnectionStore.inMemory(),
          );
        },
        openRouterOAuthCallbackUrl:
            OpenRouterOAuthCoordinator.instance.platformCallbackUrl,
        openRouterOAuthCapture: OpenRouterOAuthCoordinator.instance.capture,
      ),
    );
  }
}

/// Builds the on-device provider routes (Gemma, WebLLM, transformers.js)
/// for the current platform. Used both by [DefaultChatModelSection] and by
/// the unified [ProvidersSection] in the settings page.
List<fa_ui.FaOnDeviceRoute> buildOnDeviceProviderRoutes(
  BuildContext context, {
  required ProviderRegistry? registry,
  required Future<void> Function(AgentConfig config) onApply,
  WebLlmEngineApi? webLlmEngine,
  GemmaEngineApi? gemmaEngine,
  TransformersJsEngineApi? transformersJsEngine,
  bool? isWeb,
}) {
  final web = isWeb ?? kIsWeb;
  fa_ui.FaOnDeviceRoute route(ProviderPreset preset) => fa_ui.FaOnDeviceRoute(
    label: preset.labelFor(context),
    pageBuilder: (context, apply) => _OnDeviceFormPage(
      preset: preset,
      registry: registry ?? ProviderRegistry.inMemory(),
      onApply: (config) => apply(_faConfigFrom(config)),
      webLlmEngine: webLlmEngine,
      gemmaEngine: gemmaEngine,
      transformersJsEngine: transformersJsEngine,
      isWeb: isWeb,
    ),
  );

  return [
    if (webLlmProviderVisible(isWeb: web)) route(ProviderPreset.webllm),
    if (gemmaProviderVisible(isWeb: web, platform: defaultTargetPlatform))
      route(ProviderPreset.gemma),
    if (transformersJsProviderVisible(isWeb: web))
      route(ProviderPreset.transformersJs),
  ];
}

/// The on-device route of the default-chat-model flow: the regular
/// [AgentSettingsForm] (model picker, download progress, HF token) locked
/// to [preset]; a successful connect applies the config and pops true.
class _OnDeviceFormPage extends StatelessWidget {
  const _OnDeviceFormPage({
    required this.preset,
    required this.registry,
    required this.onApply,
    this.webLlmEngine,
    this.gemmaEngine,
    this.transformersJsEngine,
    this.isWeb,
  });

  final ProviderPreset preset;
  final ProviderRegistry registry;
  final Future<void> Function(AgentConfig config) onApply;
  final WebLlmEngineApi? webLlmEngine;
  final GemmaEngineApi? gemmaEngine;
  final TransformersJsEngineApi? transformersJsEngine;
  final bool? isWeb;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(preset.labelFor(context))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: AgentSettingsForm(
            initialProvider: preset,
            connectLabel: context.l10n.settingsApplyButton,
            registry: registry,
            keysStore: SessionKeysScope.maybeOf(context),
            webLlmEngine: webLlmEngine,
            gemmaEngine: gemmaEngine,
            transformersJsEngine: transformersJsEngine,
            isWeb: isWeb,
            onConnect: (config) async {
              await onApply(config);
              if (context.mounted) Navigator.of(context).pop(true);
            },
          ),
        ),
      ),
    );
  }
}

/// Maps the app's [AgentConfig] onto the package's config type (the fields
/// are 1:1; the package must not depend on the app's agent service).
fa_ui.FaChatModelConfig _faConfigFrom(AgentConfig config) =>
    fa_ui.FaChatModelConfig(
      providerKind: config.providerKind,
      modelId: config.modelId,
      baseUrl: config.baseUrl,
      apiKey: config.apiKey,
      contextWindow: config.contextWindow,
      maxTokens: config.maxTokens,
      supportsImages: config.supportsImages,
    );

/// The reverse of [_faConfigFrom].
AgentConfig agentConfigFrom(fa_ui.FaChatModelConfig config) => AgentConfig(
  providerKind: config.providerKind,
  modelId: config.modelId,
  baseUrl: config.baseUrl,
  apiKey: config.apiKey,
  contextWindow: config.contextWindow,
  maxTokens: config.maxTokens,
  supportsImages: config.supportsImages,
);
