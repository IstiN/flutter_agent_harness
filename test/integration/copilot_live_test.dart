// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Live Phase-0 smoke test for the GitHub Copilot provider.
///
/// Exercises the real Copilot endpoints with a GitHub token that has a
/// Copilot subscription: exchange it for a Copilot API token
/// (`/copilot_internal/v2/token`), list models, and run one streaming
/// `/chat/completions` request end to end.
///
/// Requires `GITHUB_TOKEN` (or `COPILOT_GITHUB_TOKEN`); every test skips
/// gracefully when unset — run `/provider copilot` in the harness to obtain a
/// token via device flow, or export one directly. `COPILOT_ACCOUNT_TYPE`
/// selects the API host (`individual` | `business` | `enterprise`, default
/// `individual`). Tagged `integration` and therefore excluded from the
/// pre-commit gate — run manually with:
/// `dart test test/integration/copilot_live_test.dart --tags integration`
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

final _githubToken =
    Platform.environment['COPILOT_GITHUB_TOKEN'] ??
    Platform.environment['GITHUB_TOKEN'];

final _skip = (_githubToken?.isEmpty ?? true)
    ? 'GITHUB_TOKEN/COPILOT_GITHUB_TOKEN not set — run `/provider copilot` or '
          'export a GitHub token with a Copilot subscription'
    : false;

/// API host selected by `COPILOT_ACCOUNT_TYPE` (default: individual).
final _baseUrl = switch (Platform.environment['COPILOT_ACCOUNT_TYPE'] ??
    'individual') {
  'individual' => 'https://api.githubcopilot.com',
  'business' => 'https://api.business.githubcopilot.com',
  'enterprise' => 'https://api.enterprise.githubcopilot.com',
  final other => throw StateError(
    'COPILOT_ACCOUNT_TYPE must be individual|business|enterprise, got '
    '$other',
  ),
};

/// Editor headers the Copilot API expects on every request.
const _editorHeaders = {
  'Editor-Version': 'vscode/1.109.3',
  'Editor-Plugin-Version': 'copilot-chat/0.37.6',
  'User-Agent': 'GitHubCopilotChat/0.37.6',
  'Copilot-Integration-Id': 'vscode-chat',
  'Accept': 'application/json',
};

/// Exchanges a GitHub token for a Copilot API token, returning
/// `(copilotToken, expiresAt)`.
Future<(String, DateTime)> _copilotToken(http.Client client) async {
  final response = await client.get(
    Uri.parse('https://api.github.com/copilot_internal/v2/token'),
    headers: {..._editorHeaders, 'Authorization': 'token $_githubToken'},
  );
  expect(response.statusCode, 200, reason: 'token exchange failed');
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  final token = body['token'] as String?;
  expect(token, isNotNull, reason: 'exchange response lacks `token`');
  final expiresAt = DateTime.fromMillisecondsSinceEpoch(
    (body['expires_at'] as int) * 1000,
  );
  expect(
    expiresAt.isAfter(DateTime.now()),
    isTrue,
    reason: 'exchange returned an already-expired token',
  );
  return (token!, expiresAt);
}

/// Lists Copilot models (`data` entries with `id` + `capabilities`).
Future<List<Map<String, dynamic>>> _models(
  http.Client client,
  String copilotToken,
) async {
  final response = await client.get(
    Uri.parse('$_baseUrl/models'),
    headers: {..._editorHeaders, 'Authorization': 'Bearer $copilotToken'},
  );
  expect(response.statusCode, 200, reason: 'models request failed');
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  final models = (body['data'] as List).cast<Map<String, dynamic>>();
  return models;
}

void main() {
  group(
    'GitHub Copilot (live)',
    () {
      test('exchanges the GitHub token for a Copilot API token', () async {
        final client = http.Client();
        addTearDown(client.close);
        final (_, expiresAt) = await _copilotToken(client);
        expect(expiresAt.isAfter(DateTime.now()), isTrue);
      });

      test('lists models with id and capabilities', () async {
        final client = http.Client();
        addTearDown(client.close);
        final (copilotToken, _) = await _copilotToken(client);
        final models = await _models(client, copilotToken);
        expect(models, isNotEmpty, reason: 'expected at least one model');
        for (final model in models) {
          expect(model['id'], isA<String>(), reason: 'model lacks `id`');
          expect(
            model['capabilities'],
            isA<Map>(),
            reason: 'model ${model['id']} lacks `capabilities`',
          );
        }
      });

      test('streams one chat completion: SSE delta then [DONE]', () async {
        final client = http.Client();
        addTearDown(client.close);
        final (copilotToken, _) = await _copilotToken(client);
        final models = await _models(client, copilotToken);
        final ids = models.map((model) => model['id'] as String).toList();
        final model = ids.contains('gpt-4o-mini') ? 'gpt-4o-mini' : ids.first;

        final request =
            http.Request('POST', Uri.parse('$_baseUrl/chat/completions'))
              ..headers.addAll(_editorHeaders)
              ..headers['Authorization'] = 'Bearer $copilotToken'
              ..headers['Accept'] = 'text/event-stream'
              ..body = jsonEncode({
                'model': model,
                'messages': [
                  {'role': 'user', 'content': 'Say hello in three words.'},
                ],
                'max_tokens': 32,
                'stream': true,
              });
        final response = await client.send(request);

        // Buffer error bodies before touching the stream.
        if (response.statusCode != 200) {
          final body = await response.stream.bytesToString();
          fail('chat/completions failed (${response.statusCode}): $body');
        }

        final deltas = <String>[];
        var sawDone = false;
        final lines = response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        await for (final line in lines) {
          if (!line.startsWith('data: ')) continue;
          final payload = line.substring('data: '.length).trim();
          if (payload == '[DONE]') {
            sawDone = true;
            break;
          }
          final event = jsonDecode(payload) as Map<String, dynamic>;
          final choices = (event['choices'] as List?)
              ?.cast<Map<String, dynamic>>();
          if (choices == null || choices.isEmpty) continue; // usage-only chunk
          final content =
              (choices.first['delta'] as Map<String, dynamic>?)?['content'];
          if (content is String && content.isNotEmpty) deltas.add(content);
        }

        expect(deltas, isNotEmpty, reason: 'expected at least one SSE delta');
        expect(sawDone, isTrue, reason: 'stream did not end with data: [DONE]');
      });
    },
    skip: _skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
