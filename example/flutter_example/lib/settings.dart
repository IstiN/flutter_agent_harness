import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'agent_service.dart';

/// Compile-time configuration injected via `--dart-define`. Values fall back
/// to the `.env` file (local dev) at runtime — see [settingsEnv].
const settingsDartDefines = <String, String>{
  'OPENROUTER_API_KEY': String.fromEnvironment('OPENROUTER_API_KEY'),
  'MODEL_ID': String.fromEnvironment('MODEL_ID'),
  'BASE_URL': String.fromEnvironment('BASE_URL'),
};

/// Resolves a configuration default: `--dart-define` wins, then `.env`, then
/// [fallback].
String settingsEnv(String name, String fallback) {
  final dartValue = settingsDartDefines[name];
  if (dartValue != null && dartValue.isNotEmpty) return dartValue;
  if (dotenv.isInitialized && dotenv.env.containsKey(name)) {
    return dotenv.env[name]!;
  }
  return fallback;
}

/// A bring-your-own-key provider preset. Every preset talks to an
/// OpenAI-compatible chat-completions endpoint; only the base URL, default
/// model, and guidance differ.
enum ProviderPreset {
  openrouter(
    label: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'openai/gpt-4o-mini',
  ),
  ollamaCloud(
    label: 'Ollama',
    baseUrl: 'https://ollama.com/v1',
    defaultModel: 'gpt-oss:120b',
  ),
  custom(label: 'Custom', baseUrl: null, defaultModel: '');

  const ProviderPreset({
    required this.label,
    required this.baseUrl,
    required this.defaultModel,
  });

  /// Short label shown in the segmented selector.
  final String label;

  /// Fixed endpoint for hosted presets; `null` for [custom] (user-editable).
  final String? baseUrl;

  /// Model prefill applied while the user has not typed their own.
  final String defaultModel;

  /// Whether the base-URL field is editable for this preset.
  bool get hasEditableBaseUrl => this == ProviderPreset.custom;

  /// Shown under the form for providers that may reject browser (CORS)
  /// calls. OpenRouter allows cross-origin browser requests, so it has no
  /// note; other endpoints are not guaranteed to.
  String? get corsNote => switch (this) {
    ProviderPreset.openrouter => null,
    ProviderPreset.ollamaCloud =>
      'Calls go straight from your browser to ollama.com. If the endpoint '
          'rejects cross-origin browser requests (CORS), the connection will '
          'fail — use OpenRouter or a CORS-enabled endpoint instead.',
    ProviderPreset.custom =>
      'Any OpenAI-compatible endpoint. The provider must allow browser '
          '(CORS) requests — api.anthropic.com does not, so reach Anthropic '
          'models via OpenRouter instead.',
  };

  /// Infers a preset from a configured base URL (for env-prefilled setups).
  static ProviderPreset fromBaseUrl(String url) {
    if (url.contains('openrouter.ai')) return ProviderPreset.openrouter;
    if (url.contains('ollama.com')) return ProviderPreset.ollamaCloud;
    return ProviderPreset.custom;
  }
}

/// The BYOK connection form shared by the first-run [SetupScreen] and the
/// in-chat [SettingsDialog].
///
/// Everything entered here is held in memory only: the example app never
/// persists keys (the web secrets store is in-memory by design), so a reload
/// wipes the configuration.
class AgentSettingsForm extends StatefulWidget {
  const AgentSettingsForm({
    super.key,
    required this.onConnect,
    this.connectLabel = 'Start chat',
  });

  /// Called with the assembled [AgentConfig]. Throw to surface an error in
  /// the form; return normally when the connection succeeded.
  final Future<void> Function(AgentConfig config) onConnect;

  /// Label of the primary button (`Start chat` on first run, `Reconnect`
  /// from the settings dialog).
  final String connectLabel;

  @override
  State<AgentSettingsForm> createState() => _AgentSettingsFormState();
}

class _AgentSettingsFormState extends State<AgentSettingsForm> {
  late ProviderPreset _preset;
  late String _lastDefaultModel;

  late final TextEditingController _keyController;
  late final TextEditingController _modelController;
  late final TextEditingController _urlController;

  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initialUrl = settingsEnv(
      'BASE_URL',
      ProviderPreset.openrouter.baseUrl!,
    );
    _preset = ProviderPreset.fromBaseUrl(initialUrl);
    _keyController = TextEditingController(
      text: settingsEnv('OPENROUTER_API_KEY', ''),
    );
    _lastDefaultModel = _preset.defaultModel;
    _modelController = TextEditingController(
      text: settingsEnv('MODEL_ID', _preset.defaultModel),
    );
    _urlController = TextEditingController(text: initialUrl);
  }

  @override
  void dispose() {
    _keyController.dispose();
    _modelController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _selectPreset(ProviderPreset preset) {
    setState(() {
      _preset = preset;
      if (!preset.hasEditableBaseUrl) {
        _urlController.text = preset.baseUrl!;
      }
      // Follow the preset's default model only while the user has not typed
      // a custom one (still empty or equal to the previous default).
      final current = _modelController.text.trim();
      if (current.isEmpty || current == _lastDefaultModel) {
        _modelController.text = preset.defaultModel;
      }
      _lastDefaultModel = preset.defaultModel;
    });
  }

  Future<void> _connect() async {
    final key = _keyController.text.trim();
    final model = _modelController.text.trim();
    final baseUrl = _urlController.text.trim();
    if (key.isEmpty) {
      setState(() => _error = 'API key is required');
      return;
    }
    if (model.isEmpty) {
      setState(() => _error = 'Model id is required');
      return;
    }
    if (baseUrl.isEmpty) {
      setState(() => _error = 'Base URL is required');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.onConnect(
        AgentConfig(
          providerKind: 'openai-completions',
          modelId: model,
          baseUrl: baseUrl,
          apiKey: key,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final corsNote = _preset.corsNote;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedButton<ProviderPreset>(
          segments: [
            for (final preset in ProviderPreset.values)
              ButtonSegment(value: preset, label: Text(preset.label)),
          ],
          selected: {_preset},
          onSelectionChanged: (value) => _selectPreset(value.first),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _keyController,
          decoration: const InputDecoration(
            labelText: 'API key',
            hintText: 'Paste your provider key',
          ),
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _modelController,
          decoration: const InputDecoration(labelText: 'Model id'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _urlController,
          enabled: _preset.hasEditableBaseUrl,
          decoration: InputDecoration(
            labelText: 'Base URL',
            helperText: _preset.hasEditableBaseUrl
                ? 'OpenAI-compatible endpoint'
                : null,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.lock_outline,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'In-memory only: your key is never persisted and is gone on '
                'reload. Calls go straight from your browser to the provider '
                '— nothing is proxied or stored.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        if (corsNote != null) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: theme.colorScheme.tertiary,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(corsNote, style: theme.textTheme.bodySmall)),
            ],
          ),
        ],
        const SizedBox(height: 16),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        FilledButton(
          onPressed: _loading ? null : _connect,
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(widget.connectLabel),
        ),
      ],
    );
  }
}

/// The gear-icon dialog from the chat screen: reconfigure provider/model/key
/// mid-session. Pops with a fresh [AgentService] on successful connect.
class SettingsDialog extends StatelessWidget {
  const SettingsDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Connection settings'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: AgentSettingsForm(
            connectLabel: 'Reconnect',
            onConnect: (config) async {
              final service = await AgentService.create(config: config);
              await service.initialize();
              if (context.mounted) Navigator.of(context).pop(service);
            },
          ),
        ),
      ),
    );
  }
}
