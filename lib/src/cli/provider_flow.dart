/// The guided custom-provider setup (`/provider custom`): api type, base
/// URL, optional key, then the model — picked from the endpoint's `/models`
/// list when it has one, entered manually otherwise.
///
/// The flow is a plain function over a narrow callback surface
/// ([CustomProviderFlowConfig]) so it stays testable without an [AgentCli]
/// and the CLI file stays under the size gate. Answers come back through
/// `promptLine` (null = cancelled); application goes through
/// `switchProvider`, the same code path as the typed `/provider` command.
library;

import '../model_roles/provider_catalog.dart';
import 'agent_cli.dart' show CliIO;

/// The callbacks the custom-provider flow needs from the host CLI.
final class CustomProviderFlowConfig {
  /// Creates the callback bundle.
  const CustomProviderFlowConfig({
    required this.promptLine,
    required this.fetchModels,
    required this.switchProvider,
    required this.currentModelId,
    required this.rolesActive,
  });

  /// Prints [question] and resolves to the typed line (trimmed, possibly
  /// empty), or null on cancel (Ctrl-C / input shutdown).
  final Future<String?> Function(String question) promptLine;

  /// Fetches model ids from an OpenAI-compatible `/models` endpoint, key
  /// resolution included (explicit token, else the provider's env names).
  final Future<List<String>> Function(
    ProviderSpec spec,
    String baseUrl, {
    String? token,
  })
  fetchModels;

  /// Applies the switch (the typed `/provider` command's code path):
  /// rebuilds model + stream (or pins the default chain in roles mode),
  /// records the change, prints the confirmation, fires the callbacks.
  final Future<void> Function(
    ProviderSpec spec,
    String baseUrl,
    String modelId, {
    String? token,
  })
  switchProvider;

  /// The active model id (the model step's empty-answer default).
  final String Function() currentModelId;

  /// Whether model roles drive the agent (the key step is then skipped:
  /// keys resolve from the resolver's env-based snapshot).
  final bool rolesActive;
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
  void cancelled() => io.writeln('custom provider setup cancelled');

  io.writeln('custom provider setup (Ctrl-C to cancel)');
  io.writeln(
    'api type:  1) ${_apiTypes[0].$1}  2) ${_apiTypes[1].$1}  '
    '3) ${_apiTypes[2].$1}',
  );
  final typeAnswer = await config.promptLine('type a number: ');
  if (typeAnswer == null) return cancelled();
  final typeIndex = int.tryParse(typeAnswer.trim());
  if (typeIndex == null || typeIndex < 1 || typeIndex > _apiTypes.length) {
    io.writeln('invalid api type: ${typeAnswer.trim()} — setup aborted');
    return;
  }
  final spec = providerCatalog[_apiTypes[typeIndex - 1].$2]!;

  final urlAnswer = await config.promptLine('base URL: ');
  if (urlAnswer == null) return cancelled();
  final baseUrl = urlAnswer.trim().replaceAll(RegExp(r'/+$'), '');
  if (!baseUrl.startsWith('http://') && !baseUrl.startsWith('https://')) {
    io.writeln(
      'invalid base URL: ${urlAnswer.trim()} (want http(s)://...) — '
      'setup aborted',
    );
    return;
  }

  String? token;
  if (config.rolesActive) {
    io.writeln(
      'roles mode: the key resolves from the environment '
      '(${spec.apiKeyEnvNames.first}) — no key step',
    );
  } else {
    final keyAnswer = await config.promptLine('API key (empty for none): ');
    if (keyAnswer == null) return cancelled();
    final key = keyAnswer.trim();
    if (key.isNotEmpty) token = key;
  }

  var modelId = config.currentModelId();
  final modelHint = "empty keeps '$modelId'";
  if (spec.kind == 'openai-completions') {
    io.writeln('fetching models from $baseUrl/models ...');
    final models = await config.fetchModels(spec, baseUrl, token: token);
    if (models.isNotEmpty) {
      io.writeln('${models.length} models available:');
      for (var i = 0; i < models.length; i++) {
        io.writeln('  ${i + 1}) ${models[i]}');
      }
      final pick = await config.promptLine(
        'type a number or a model id ($modelHint): ',
      );
      if (pick == null) return cancelled();
      final answer = pick.trim();
      if (answer.isNotEmpty) {
        final number = int.tryParse(answer);
        modelId = number != null && number >= 1 && number <= models.length
            ? models[number - 1]
            : answer;
      }
    } else {
      final manual = await config.promptLine(
        'no model list from the endpoint — model id ($modelHint): ',
      );
      if (manual == null) return cancelled();
      final answer = manual.trim();
      if (answer.isNotEmpty) modelId = answer;
    }
  } else {
    final manual = await config.promptLine('model id ($modelHint): ');
    if (manual == null) return cancelled();
    final answer = manual.trim();
    if (answer.isNotEmpty) modelId = answer;
  }

  await config.switchProvider(spec, baseUrl, modelId, token: token);
}
