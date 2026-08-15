// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa_ui/src/host_config.dart';
import 'package:fa_ui/src/providers/provider_preset.dart';
import 'package:fa_ui/src/stores/session_keys_store.dart';
import 'package:fa_ui/src/stores/task_models_store.dart';
import 'package:fa_ui/src/utils/page_presentation.dart';
import 'package:fa_ui/src/widgets/model_list_picker.dart';

/// The settings "Task models" section: one row per [TaskRole.all] entry
/// showing the effective endpoint — the role's override (`modelId`) or the
/// main connection fallback ("Same as main"). Tapping a row pushes a simple
/// [TaskRoleConfigPage] with text fields for base URL, model id, and an
/// optional API key name. Picking "Use main model" clears the override.
///
/// The store comes from [store] or the nearest [TaskModelsScope]; the whole
/// section hides when no store is available (tests pumping the bare form).
/// [mainBaseUrl] / [mainModelId] supply the current connection for the
/// editor's placeholder text.
class TaskModelsSection extends StatelessWidget {
  const TaskModelsSection({
    super.key,
    this.store,
    this.mainBaseUrl = '',
    this.mainModelId = '',
  });

  /// Store override; falls back to the nearest [TaskModelsScope].
  final TaskModelsStore? store;

  /// The main connection's base URL (placeholder in the editor).
  final String mainBaseUrl;

  /// The main connection's model id (placeholder in the editor).
  final String mainModelId;

  /// The icon each role's row shows.
  static const roleIcons = <String, IconData>{
    TaskRole.smol: Icons.bolt_outlined,
    TaskRole.subagent: Icons.groups_outlined,
  };

  /// Display labels for known roles (the rest fall back to the raw id).
  static const roleTitles = <String, String>{
    TaskRole.smol: 'Quick model', // l10n:ignore
    TaskRole.subagent: 'Subagents model', // l10n:ignore
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = this.store ?? TaskModelsScope.maybeOf(context);
    if (store == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final role in TaskRole.all)
              _buildRoleRow(context, theme, store, role),
          ],
        );
      },
    );
  }

  Widget _buildRoleRow(
    BuildContext context,
    ThemeData theme,
    TaskModelsStore store,
    String role,
  ) {
    final override = store.overrideFor(role);
    final title = roleTitles[role] ?? role;
    final subtitle = override?.modelId.isNotEmpty == true
        ? override!.modelId
        : 'Same as main'; // l10n:ignore
    return InkWell(
      onTap: () => _editRole(context, store, role),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              roleIcons[role] ?? Icons.tune,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editRole(
    BuildContext context,
    TaskModelsStore store,
    String role,
  ) async {
    // pushFaPage shows a dialog on wide screens (matching the settings
    // style) and a full page on narrow.
    final result = await pushFaPage<_TaskRoleEditResult>(
      context,
      TaskRoleConfigPage(
        role: role,
        initial: store.overrideFor(role),
        mainBaseUrl: mainBaseUrl,
        mainModelId: mainModelId,
      ),
    );
    if (result == null) return;
    if (result.cleared) {
      await store.setOverride(role, null);
    } else if (result.config != null) {
      await store.setOverride(role, result.config);
    }
  }
}

/// Internal result of the [TaskRoleConfigPage].
class _TaskRoleEditResult {
  const _TaskRoleEditResult({this.config, required this.cleared});
  final TaskRoleConfig? config;
  final bool cleared;
}

/// A simple editor page for one task role's model config: provider preset,
/// base URL, the shared model list picker (fetched live from the endpoint,
/// manual entry always valid), plus an optional API key name. Save writes
/// the override; "Use main model" clears it.
class TaskRoleConfigPage extends StatefulWidget {
  const TaskRoleConfigPage({
    super.key,
    required this.role,
    this.initial,
    this.mainBaseUrl = '',
    this.mainModelId = '',
    this.modelsFetcher,
  });

  /// The role being edited.
  final String role;

  /// The current override (null = using main connection).
  final TaskRoleConfig? initial;

  /// The main connection's base URL (placeholder hint).
  final String mainBaseUrl;

  /// The main connection's model id (placeholder hint).
  final String mainModelId;

  /// `/models` fetch override (tests); defaults to the shared
  /// [fetchModelsForEndpoint] dispatch.
  final ModelsEndpointFetcher? modelsFetcher;

  @override
  State<TaskRoleConfigPage> createState() => _TaskRoleConfigPageState();
}

class _TaskRoleConfigPageState extends State<TaskRoleConfigPage> {
  late final TextEditingController _baseUrlCtrl;
  late final TextEditingController _modelIdCtrl;
  late final TextEditingController _apiKeyCtrl;
  late ProviderPreset _selectedPreset;

  /// The endpoint's fetched model ids feeding the list picker.
  List<String> _endpointModels = const [];
  var _modelsLoading = false;

  /// Debounce for the custom base-URL field (refetch once typing settles).
  Timer? _fetchDebounce;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _baseUrlCtrl = TextEditingController(text: initial?.baseUrl ?? '');
    _modelIdCtrl = TextEditingController(text: initial?.modelId ?? '');
    _apiKeyCtrl = TextEditingController(text: initial?.apiKeyName ?? '');
    _selectedPreset = _baseUrlCtrl.text.isEmpty
        ? ProviderPreset.custom
        : ProviderPreset.fromBaseUrl(_baseUrlCtrl.text);
    _baseUrlCtrl.addListener(_scheduleFetch);
    // The key lookup needs the inherited stores — fetch after the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_fetchModels());
    });
  }

  @override
  void dispose() {
    _fetchDebounce?.cancel();
    _baseUrlCtrl.dispose();
    _modelIdCtrl.dispose();
    _apiKeyCtrl.dispose();
    super.dispose();
  }

  void _scheduleFetch() {
    _fetchDebounce?.cancel();
    _fetchDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted) unawaited(_fetchModels());
    });
  }

  void _onPresetChanged(ProviderPreset? preset) {
    if (preset == null) return;
    setState(() {
      _selectedPreset = preset;
      if (preset.baseUrl != null) {
        _baseUrlCtrl.text = preset.baseUrl!;
      }
    });
    unawaited(_fetchModels());
  }

  /// The API key for the model-list fetch: the hosted preset's well-known
  /// key, or the custom endpoint's named key — resolved through the host
  /// chain (env / secure store / saved keys).
  String _resolveFetchKey() {
    final keysStore = SessionKeysScope.maybeOf(context);
    if (_selectedPreset != ProviderPreset.custom) {
      return resolveProviderKey(_selectedPreset, keysStore: keysStore);
    }
    final name = _apiKeyCtrl.text.trim();
    if (name.isEmpty) return '';
    return FaUiHost.resolveKey(name, () => keysStore?.valueOf(name) ?? '');
  }

  /// Fetches the endpoint's model list through the shared dispatch (DIAL
  /// deployments included); silent on failure — the picker then shows the
  /// manual-entry note.
  Future<void> _fetchModels() async {
    final baseUrl = _baseUrlCtrl.text.trim();
    if (baseUrl.isEmpty) return;
    setState(() => _modelsLoading = true);
    try {
      final override = widget.modelsFetcher;
      final (ids, _, _) = override != null
          ? await override(baseUrl, apiKey: _resolveFetchKey())
          : await fetchModelsForEndpoint(
              baseUrl,
              apiKey: _resolveFetchKey(),
              provider: _selectedPreset == ProviderPreset.dial ? 'dial' : null,
            );
      if (!mounted) return;
      setState(() => _endpointModels = ids);
    } on Object {
      if (mounted) setState(() => _endpointModels = const []);
    } finally {
      if (mounted) setState(() => _modelsLoading = false);
    }
  }

  void _save() {
    final baseUrl = _baseUrlCtrl.text.trim();
    final modelId = _modelIdCtrl.text.trim();
    if (modelId.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    final apiKeyName = _apiKeyCtrl.text.trim();
    Navigator.of(context).pop(
      _TaskRoleEditResult(
        cleared: false,
        config: TaskRoleConfig(
          providerKind: 'openai-completions',
          baseUrl: baseUrl.isEmpty ? widget.mainBaseUrl : baseUrl,
          modelId: modelId,
          apiKeyName: apiKeyName.isEmpty ? null : apiKeyName,
        ),
      ),
    );
  }

  void _useMain() {
    Navigator.of(context).pop(const _TaskRoleEditResult(cleared: true));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(TaskModelsSection.roleTitles[widget.role] ?? widget.role),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Provider preset row: pick a hosted provider to prefill the
              // base URL, or "Custom" to type one manually.
              DropdownButtonFormField<ProviderPreset>(
                value: _selectedPreset,
                decoration: const InputDecoration(
                  labelText: 'Provider', // l10n:ignore
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final p in ProviderPreset.values)
                    DropdownMenuItem(
                      value: p,
                      child: Text(p.name), // l10n:ignore
                    ),
                ],
                onChanged: _onPresetChanged,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _baseUrlCtrl,
                enabled: _selectedPreset == ProviderPreset.custom,
                decoration: InputDecoration(
                  labelText: 'Base URL', // l10n:ignore
                  hintText: widget.mainBaseUrl.isEmpty
                      ? null
                      : widget.mainBaseUrl,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FaModelListPicker(
                controller: _modelIdCtrl,
                models: _endpointModels,
                loading: _modelsLoading,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _apiKeyCtrl,
                decoration: const InputDecoration(
                  labelText: 'API key name (optional)', // l10n:ignore
                  helperText:
                      'Env/keychain entry name, e.g. OPENAI_API_KEY', // l10n:ignore
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _save,
                child: Text('Save'), // l10n:ignore
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _useMain,
                child: Text('Use main model'), // l10n:ignore
              ),
            ],
          ),
        ),
      ),
    );
  }
}
