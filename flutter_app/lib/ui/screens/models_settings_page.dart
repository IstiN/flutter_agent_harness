// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/ondevice_config_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/task_models_store.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/ui/screens/model_presets.dart';
import 'package:fa/ui/screens/providers_section.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa/webllm/webllm_types.dart';
import 'package:fa_ui/fa_ui.dart' as faui;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The Models settings page: everything model-related in one place —
/// the swipeable presets, the main chat model, the per-task-role overrides
/// (quick/subagents) and the media slots. Opened from the "Models" row on
/// the settings screen so the top level stays provider-focused.
class ModelsSettingsPage extends StatefulWidget {
  const ModelsSettingsPage({
    super.key,
    required this.service,
    this.registry,
    this.lastConnectionStore,
    this.modelsFetcher,
    this.taskModelsStore,
    this.webLlmEngine,
    this.gemmaEngine,
    this.transformersJsEngine,
  });

  /// The live service the chat-model flow reconfigures and the role/media
  /// rows summarize against.
  final AgentService service;

  /// The user-added providers backing the pickers.
  final ProviderRegistry? registry;

  /// Updated on every successful apply (see [LastConnectionStore]).
  final LastConnectionStore? lastConnectionStore;

  /// `/models` fetch override (tests), forwarded to the pickers.
  final ModelsEndpointFetcher? modelsFetcher;

  /// Per-task-role model overrides (`task_models.json`); `null` hides the
  /// Task models section (falls back to the nearest [TaskModelsScope]).
  final TaskModelsStore? taskModelsStore;

  /// Engine overrides for the on-device provider rows (tests); the platform
  /// singletons are the defaults.
  final WebLlmEngineApi? webLlmEngine;
  final GemmaEngineApi? gemmaEngine;
  final TransformersJsEngineApi? transformersJsEngine;

  @override
  State<ModelsSettingsPage> createState() => _ModelsSettingsPageState();
}

class _ModelsSettingsPageState extends State<ModelsSettingsPage> {
  @override
  void initState() {
    super.initState();
    AppAnalytics.instance.screenOpened('settings_models');
  }

  @override
  Widget build(BuildContext context) {
    final taskModels =
        widget.taskModelsStore ?? TaskModelsScope.maybeOf(context);
    final onDeviceConfig = OnDeviceConfigScope.maybeOf(context);
    return Scaffold(
      appBar: faAppBar(title: Text(context.l10n.settingsModelsGroupTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Presets first (one-tap combos), then the main chat model,
              // the task-role overrides and the media slots.
              ModelPresetsSection(
                service: widget.service,
                lastConnectionStore: widget.lastConnectionStore,
                taskModelsStore: taskModels,
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              DefaultChatModelSection(
                service: widget.service,
                registry: widget.registry,
                lastConnectionStore: widget.lastConnectionStore,
                modelsFetcher: widget.modelsFetcher,
                webLlmEngine: widget.webLlmEngine,
                gemmaEngine: widget.gemmaEngine,
                transformersJsEngine: widget.transformersJsEngine,
                onDeviceConfigStore: onDeviceConfig,
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              if (taskModels != null) ...[
                faui.TaskModelsSection(
                  store: taskModels,
                  mainBaseUrl: widget.service.activeBaseUrl,
                  mainModelId: widget.service.agentModelId,
                  registry: widget.registry,
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 16),
              ],
              MediaModelsSection(
                service: widget.service,
                registry: widget.registry,
                modelsFetcher: widget.modelsFetcher,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
