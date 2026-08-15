/// One shared "which models does this endpoint serve" dispatch for every
/// model picker (CLI settings flows, the app's chat/media/agent model
/// pages): OpenAI-compatible endpoints answer `GET {baseUrl}/models`,
/// DIAL serves deployments at `{baseUrl}/openai/models`, CodeMie lists
/// LiteLLM-shaped `/llm_models`. Before this helper every picker hardcoded
/// the OpenAI shape, so DIAL/CodeMie endpoints silently fell back to manual
/// model entry.
library;

import 'package:http/http.dart' as http;

import 'codemie_sso.dart';
import 'dial.dart';
import 'models_endpoint.dart';

/// Fetches the model list of [baseUrl], picking the wire dialect by
/// endpoint: the CodeMie `/code-assistant-api/` marker wins first (its
/// `/llm_models` is cookie/token-shaped), then [provider] `'dial'` switches
/// to the deployments endpoint (ids + reported limits), and everything else
/// is treated as OpenAI-compatible (`/models`, Bearer when [apiKey] is
/// non-empty). Any failure answers an empty info — callers always keep
/// their manual-entry fallback.
Future<ModelsEndpointInfo> fetchModelsForEndpoint(
  String baseUrl, {
  required String apiKey,
  String? provider,
  http.Client? client,
}) async {
  if (baseUrl.contains('/code-assistant-api/')) {
    try {
      final ids = await fetchCodeMieModels(baseUrl, apiKey, client: client);
      return (ids, const <String, int>{}, const <String, int>{});
    } on Object {
      return (const <String>[], const <String, int>{}, const <String, int>{});
    }
  }
  if (provider == 'dial') {
    try {
      final (ids, _, windows, maxTokens) = await fetchDialModelsInfo(
        baseUrl,
        apiKey,
        client: client,
      );
      return (ids, windows, maxTokens);
    } on Object {
      return (const <String>[], const <String, int>{}, const <String, int>{});
    }
  }
  final httpClient = client ?? http.Client();
  final ownsClient = client == null;
  try {
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/models');
    final response = await httpClient
        .get(
          uri,
          headers: {
            'Accept': 'application/json',
            if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      return (const <String>[], const <String, int>{}, const <String, int>{});
    }
    return parseModelsResponse(response.body);
  } on Object {
    return (const <String>[], const <String, int>{}, const <String, int>{});
  } finally {
    if (ownsClient) httpClient.close();
  }
}
