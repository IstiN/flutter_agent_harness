/// The guided custom-provider setup (`/provider custom`) and edit flow
/// (`/provider-edit`): api type (menu), base URL (Enter applies the shown
/// default), optional key, then the model — picked from the endpoint's
/// `/models` list when it has one, entered manually otherwise.
///
/// The flow is a plain function over a narrow callback surface
/// ([CustomProviderFlowConfig]) so it stays testable without an [AgentCli]:
/// the host renders questions (TUI menus or numbered line lists) and
/// applies the result (registry write + provider switch + persistence).
library;

import '../model_roles/provider_catalog.dart';
import 'agent_cli.dart' show CliIO;

/// One multiple-choice option: stable key + display label + dim description.
typedef FlowOption = (String key, String label, String description);

/// The completed wizard answers, ready for the host to apply.
final class CustomProviderSetup {
  /// Creates the result bundle.
  const CustomProviderSetup({
    required this.spec,
    required this.baseUrl,
    required this.name,
    required this.modelId,
    this.token,
  });

  /// The catalog spec of the chosen api type (`openai`/`anthropic`/
  /// `google`): adapter kind, api dialect, context defaults.
  final ProviderSpec spec;

  /// The endpoint base URL (user-typed or the applied default).
  final String baseUrl;

  /// The provider's display name (user-typed or the host-derived default):
  /// how the entry is listed and looked up — distinct names let several
  /// entries share one URL (e.g. different keys per account).
  final String name;

  /// The chosen model id.
  final String modelId;

  /// The typed API key, or null (keyless / env-resolved).
  final String? token;
}

/// The callbacks the provider flow needs from the host CLI.
final class CustomProviderFlowConfig {
  /// Creates the callback bundle. The `initial*` fields prefill the edit
  /// flow (`/provider-edit`); nulls mean a plain add.
  const CustomProviderFlowConfig({
    required this.askLine,
    required this.pickOption,
    required this.fetchModels,
    required this.applyResult,
    required this.currentModelId,
    required this.rolesActive,
    required this.deriveName,
    this.initialType,
    this.initialBaseUrl,
    this.initialName,
    this.initialModelId,
    this.editName,
  });

  /// Prints [question] and resolves to the typed line (trimmed, possibly
  /// empty — the host maps empty to the question's default), or null on
  /// cancel (Ctrl-C / input shutdown).
  final Future<String?> Function(String question) askLine;

  /// Renders [title] + [options] (a TUI menu or a numbered list) and
  /// resolves to the chosen option key, or null on cancel. [initialKey]
  /// pre-selects an option (edit flow).
  final Future<String?> Function(
    String title,
    List<FlowOption> options, {
    String? initialKey,
  })
  pickOption;

  /// Fetches model ids from an OpenAI-compatible `/models` endpoint, key
  /// resolution included (explicit token, else the provider's env names).
  final Future<List<String>> Function(
    ProviderSpec spec,
    String baseUrl, {
    String? token,
  })
  fetchModels;

  /// Applies the completed setup (registry write, provider switch,
  /// persistence callbacks) — the host's code path.
  final Future<void> Function(CustomProviderSetup setup) applyResult;

  /// The active model id (the add flow's model default).
  final String Function() currentModelId;

  /// Whether model roles drive the agent (the key step is then skipped:
  /// keys resolve from the resolver's env-based snapshot).
  final bool rolesActive;

  /// Edit prefill: the current api type (`openai`/`anthropic`/`google`).
  final String? initialType;

  /// Edit prefill: the current base URL (also the URL step's default).
  final String? initialBaseUrl;

  /// Edit prefill: the current model id (the model step's default).
  final String? initialModelId;

  /// Derives the default display name for an endpoint (host-based, unique).
  final String Function(String baseUrl) deriveName;

  /// Edit prefill: the entry's current name (the name step's default).
  final String? initialName;

  /// Non-null in edit mode: the registry entry being edited (the banner and
  /// cancellation text follow it).
  final String? editName;
}

/// The api-type menu entries: label → catalog spec name.
const _apiTypes = [
  ('openai-like', 'openai'),
  ('anthropic-like', 'anthropic'),
  ('google-like', 'google'),
];

/// Runs the guided setup to completion (or cancellation). Never throws:
/// every step validates and aborts with a message instead.
Future<void> runCustomProviderFlow(
  CliIO io,
  CustomProviderFlowConfig config,
) async {
  final editing = config.editName != null;
  void cancelled() => io.writeln(
    editing ? 'provider edit cancelled' : 'custom provider setup cancelled',
  );

  io.writeln(
    editing
        ? 'editing provider ${config.editName} (Ctrl-C to cancel)'
        : 'custom provider setup (Ctrl-C to cancel)',
  );

  // 1. Api type (menu).
  final typeKey = await config.pickOption('api type', [
    for (final (label, name) in _apiTypes)
      (name, label, providerCatalog[name]!.api),
  ], initialKey: config.initialType);
  if (typeKey == null) return cancelled();
  final spec = providerCatalog[typeKey]!;

  // 2. Base URL: Enter applies the shown default (the spec's hosted URL on
  // add, the entry's current URL on edit).
  final urlDefault = config.initialBaseUrl ?? spec.defaultBaseUrl;
  final urlAnswer = await config.askLine('base URL (empty = $urlDefault): ');
  if (urlAnswer == null) return cancelled();
  final baseUrl = (urlAnswer.trim().isEmpty ? urlDefault : urlAnswer.trim())
      .replaceAll(RegExp(r'/+$'), '');
  if (!baseUrl.startsWith('http://') && !baseUrl.startsWith('https://')) {
    io.writeln(
      'invalid base URL: ${urlAnswer.trim()} (want http(s)://...) — '
      'setup aborted',
    );
    return;
  }

  // 3. Display name: Enter keeps the host-derived default (or the entry's
  // current name on edit). Custom names distinguish entries that share one
  // URL (different keys/accounts).
  final nameDefault = config.initialName ?? config.deriveName(baseUrl);
  final nameAnswer = await config.askLine(
    'provider name (empty = $nameDefault): ',
  );
  if (nameAnswer == null) return cancelled();
  final name = nameAnswer.trim().isEmpty ? nameDefault : nameAnswer.trim();

  // 4. API key (empty = keyless; skipped in roles mode, and on edit an
  // empty answer keeps the entry's existing key).
  String? token;
  if (config.rolesActive) {
    io.writeln(
      'roles mode: the key resolves from the environment '
      '(${spec.apiKeyEnvNames.first}) — no key step',
    );
  } else {
    final keyAnswer = await config.askLine('API key (empty for none): ');
    if (keyAnswer == null) return cancelled();
    final key = keyAnswer.trim();
    if (key.isNotEmpty) token = key;
  }

  // 4. Model: the endpoint's list when it has one (plus a manual-entry
  // option), manual entry otherwise; empty keeps the default.
  var modelId = config.initialModelId ?? config.currentModelId();
  if (spec.kind == 'openai-completions') {
    io.writeln('fetching models from $baseUrl/models ...');
    final models = await config.fetchModels(spec, baseUrl, token: token);
    if (models.isNotEmpty) {
      final picked = await config.pickOption('model', [
        for (final id in models) (id, id, ''),
        ('', '+ enter manually', ''),
      ], initialKey: models.contains(modelId) ? modelId : null);
      if (picked == null) return cancelled();
      if (picked.isNotEmpty) {
        modelId = picked;
      } else {
        final manual = await config.askLine(
          "model id (empty keeps '$modelId'): ",
        );
        if (manual == null) return cancelled();
        final answer = manual.trim();
        if (answer.isNotEmpty) modelId = answer;
      }
    } else {
      final manual = await config.askLine(
        "no model list from the endpoint — model id (empty keeps '$modelId'): ",
      );
      if (manual == null) return cancelled();
      final answer = manual.trim();
      if (answer.isNotEmpty) modelId = answer;
    }
  } else {
    final manual = await config.askLine("model id (empty keeps '$modelId'): ");
    if (manual == null) return cancelled();
    final answer = manual.trim();
    if (answer.isNotEmpty) modelId = answer;
  }

  await config.applyResult(
    CustomProviderSetup(
      spec: spec,
      baseUrl: baseUrl,
      name: name,
      modelId: modelId,
      token: token,
    ),
  );
}
