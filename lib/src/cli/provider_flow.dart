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
    this.reauth,
  });

  /// Prints [question] and resolves to the typed line (trimmed, possibly
  /// empty — the host maps empty to the question's default), or null on
  /// cancel (Ctrl-C / input shutdown). When [secret] is true the host masks
  /// the input (API keys, tokens).
  final Future<String?> Function(String question, {bool secret}) askLine;

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

  /// Edit-mode-only alternative at the API-key step: when non-null (and
  /// [editName] is set), the step first offers a picker — keep the stored
  /// key, re-authorize in the browser, or paste a new key — mirroring the
  /// sign-in choice the connect flow gives (OpenRouter OAuth). [run]
  /// executes the host's browser flow and resolves to the minted key, or
  /// null on cancel/failure; the step then falls back to the manual
  /// prompt. Ignored outside edit mode.
  final ({String label, Future<String?> Function() run})? reauth;
}

/// The api-type menu entries: label → catalog spec name.
const _apiTypes = [
  ('openai-like', 'openai'),
  ('anthropic-like', 'anthropic'),
  ('google-like', 'google'),
  ('minimax-like', 'minimax'),
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

  // 2. Base URL.
  final baseUrl = await _askBaseUrl(io, config, spec, cancelled);
  if (baseUrl == null) return;

  // 3. Display name.
  final name = await _askProviderName(config, baseUrl, cancelled);
  if (name == null) return;

  // 4. API key.
  final keyStep = await _askApiToken(io, config, spec, cancelled);
  if (keyStep.aborted) return;

  // 5. Model.
  final modelStep = await _askModelId(
    io,
    config,
    spec,
    baseUrl,
    keyStep.token,
    cancelled,
  );
  if (modelStep.aborted) return;

  await config.applyResult(
    CustomProviderSetup(
      spec: spec,
      baseUrl: baseUrl,
      name: name,
      modelId: modelStep.modelId,
      token: keyStep.token,
    ),
  );
}

/// Step 2 — base URL: Enter applies the shown default (the spec's hosted
/// URL on add, the entry's current URL on edit). Returns null on abort
/// (cancelled or invalid — the message is already printed).
Future<String?> _askBaseUrl(
  CliIO io,
  CustomProviderFlowConfig config,
  ProviderSpec spec,
  void Function() cancelled,
) async {
  final urlDefault = config.initialBaseUrl ?? spec.defaultBaseUrl;
  final urlAnswer = await config.askLine('base URL (empty = $urlDefault): ');
  if (urlAnswer == null) {
    cancelled();
    return null;
  }
  final baseUrl = (urlAnswer.trim().isEmpty ? urlDefault : urlAnswer.trim())
      .replaceAll(RegExp(r'/+$'), '');
  if (!baseUrl.startsWith('http://') && !baseUrl.startsWith('https://')) {
    io.writeln(
      'invalid base URL: ${urlAnswer.trim()} (want http(s)://...) — '
      'setup aborted',
    );
    return null;
  }
  return baseUrl;
}

/// Step 3 — display name: Enter keeps the host-derived default (or the
/// entry's current name on edit). Custom names distinguish entries that
/// share one URL (different keys/accounts). Returns null on cancel.
Future<String?> _askProviderName(
  CustomProviderFlowConfig config,
  String baseUrl,
  void Function() cancelled,
) async {
  final nameDefault = config.initialName ?? config.deriveName(baseUrl);
  final nameAnswer = await config.askLine(
    'provider name (empty = $nameDefault): ',
  );
  if (nameAnswer == null) {
    cancelled();
    return null;
  }
  return nameAnswer.trim().isEmpty ? nameDefault : nameAnswer.trim();
}

/// Step 4 — API key (empty = keyless; on edit an empty answer keeps the
/// entry's existing key). When [CustomProviderFlowConfig.reauth] is set in
/// edit mode, a picker first offers the same sign-in choice the connect
/// flow has: keep the stored key, re-authorize in the browser, or paste a
/// new key. Roles mode still asks — the note explains that an empty answer
/// falls back to environment resolution; a saved custom endpoint's key
/// lives in the secure store either way.
Future<({bool aborted, String? token})> _askApiToken(
  CliIO io,
  CustomProviderFlowConfig config,
  ProviderSpec spec,
  void Function() cancelled,
) async {
  final reauth = config.editName != null ? config.reauth : null;
  if (reauth != null) {
    final choice = await config.pickOption('API key', [
      ('keep', 'Keep current key', 'leave the stored key unchanged'),
      ('reauth', reauth.label, 're-authorize in the browser'),
      ('new', 'Enter a new API key', 'paste a key manually'),
    ], initialKey: 'keep');
    if (choice == null) {
      cancelled();
      return (aborted: true, token: null);
    }
    if (choice == 'keep') {
      return (aborted: false, token: null);
    }
    if (choice == 'reauth') {
      final minted = await reauth.run();
      if (minted != null && minted.trim().isNotEmpty) {
        return (aborted: false, token: minted.trim());
      }
      io.writeln('authorization did not complete — enter a key manually');
    }
  }
  if (config.rolesActive) {
    io.writeln(
      'roles mode: an empty key resolves from the environment '
      '(${spec.apiKeyEnvNames.first})',
    );
  }
  final keyAnswer = await config.askLine(
    'API key (empty for none): ',
    secret: true,
  );
  if (keyAnswer == null) {
    cancelled();
    return (aborted: true, token: null);
  }
  final key = keyAnswer.trim();
  return (aborted: false, token: key.isNotEmpty ? key : null);
}

/// Step 5 — model: the endpoint's list when it has one (plus a
/// manual-entry option), manual entry otherwise; empty keeps the default.
Future<({bool aborted, String modelId})> _askModelId(
  CliIO io,
  CustomProviderFlowConfig config,
  ProviderSpec spec,
  String baseUrl,
  String? token,
  void Function() cancelled,
) async {
  var modelId = config.initialModelId ?? config.currentModelId();
  if (spec.kind != 'openai-completions' && spec.name != 'dial') {
    return _askManualModelId(config, modelId, cancelled);
  }
  io.writeln('fetching models from $baseUrl ...');
  final models = await config.fetchModels(spec, baseUrl, token: token);
  if (models.isEmpty) {
    return _askManualModelId(
      config,
      modelId,
      cancelled,
      prefix: 'no model list from the endpoint — ',
    );
  }
  final picked = await config.pickOption('model', [
    for (final id in models) (id, id, ''),
    ('', '+ enter manually', ''),
  ], initialKey: models.contains(modelId) ? modelId : null);
  if (picked == null) {
    cancelled();
    return (aborted: true, modelId: modelId);
  }
  if (picked.isNotEmpty) {
    modelId = picked;
    return (aborted: false, modelId: modelId);
  }
  return _askManualModelId(config, modelId, cancelled);
}

/// The manual model-id prompt shared by every fallback path; an empty
/// answer keeps [modelId].
Future<({bool aborted, String modelId})> _askManualModelId(
  CustomProviderFlowConfig config,
  String modelId,
  void Function() cancelled, {
  String prefix = '',
}) async {
  final manual = await config.askLine(
    "${prefix}model id (empty keeps '$modelId'): ",
  );
  if (manual == null) {
    cancelled();
    return (aborted: true, modelId: modelId);
  }
  final answer = manual.trim();
  return (aborted: false, modelId: answer.isNotEmpty ? answer : modelId);
}
