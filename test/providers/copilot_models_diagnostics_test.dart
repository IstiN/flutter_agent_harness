// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// gh-1990 — the Copilot /models dialect used to swallow EVERY failure
/// (token exchange, HTTP, proxy-ep routing, the picker filter) into a
/// silent empty list. The matrix below pins the per-branch reasons, the
/// per-tier shapes, the dual-path fallback, and the legacy-API parity.
void main() {
  tearDown(() => providerTimeoutsOverride = null);

  /// A fake Copilot backend: the token exchange on api.github.com
  /// ([exchangeStatus]/[exchangeBody]) and /models everywhere else
  /// ([modelsStatus]/[modelsBody]). Records every request.
  (http_testing.MockClient, List<http.BaseRequest>) fakeCopilot({
    int exchangeStatus = 200,
    String exchangeBody =
        '{"token":"cop-tok","expires_at":1900000000,"refresh_in":1500}',
    int modelsStatus = 200,
    String modelsBody = '{"data":[]}',
    bool hangModels = false,
  }) {
    final requests = <http.BaseRequest>[];
    final client = http_testing.MockClient((request) async {
      requests.add(request);
      if (request.url.host == 'api.github.com') {
        return http.Response(exchangeBody, exchangeStatus);
      }
      if (hangModels) return Completer<http.Response>().future;
      return http.Response(modelsBody, modelsStatus);
    });
    return (client, requests);
  }

  /// An individual-tier payload: picker-enabled chat models with limits.
  const healthyModelsBody =
      '{"data":['
      '{"id":"gpt-4.1","model_picker_enabled":true,"supported_endpoints":'
      '["/chat/completions"],"capabilities":{"limits":'
      '{"max_context_window_tokens":128000,"max_output_tokens":16384}}},'
      '{"id":"claude-sonnet-5","model_picker_enabled":true,'
      '"supported_endpoints":["/chat/completions"]}'
      ']}';

  group('tier matrix — healthy shapes list models (AC1)', () {
    test(
      'individual: no-proxy-ep token serves from the configured host',
      () async {
        // Individual tokens carry no proxy-ep (copilot_oauth.dart) — the
        // configured base IS the target.
        final (client, requests) = fakeCopilot(
          exchangeBody:
              '{"token":"cop-ind","expires_at":1900000000}', // no proxy-ep
          modelsBody: healthyModelsBody,
        );
        final report = await fetchModelsForEndpointReport(
          'https://api.githubcopilot.com',
          apiKey: 'gho_individual',
          provider: 'copilot',
          client: client,
        );
        expect(report.info.$1, ['claude-sonnet-5', 'gpt-4.1']);
        expect(report.info.$2['gpt-4.1'], 128000);
        expect(report.info.$3['gpt-4.1'], 16384);
        expect(
          report.diagnostic,
          isNull,
          reason: 'healthy fetch names nothing',
        );
        expect(
          requests.last.url,
          Uri.parse('https://api.githubcopilot.com/models'),
        );
      },
    );

    test(
      'business: proxy-ep token routes /models to the tenant host',
      () async {
        final (client, requests) = fakeCopilot(
          exchangeBody:
              '{"token":"cop-biz;proxy-ep=proxy.acme.githubcopilot.com;'
              'uid=1","expires_at":1900000000}',
          modelsBody: healthyModelsBody,
        );
        final report = await fetchModelsForEndpointReport(
          'https://api.business.githubcopilot.com',
          apiKey: 'gho_business',
          provider: 'copilot',
          client: client,
        );
        expect(report.info.$1, ['claude-sonnet-5', 'gpt-4.1']);
        expect(report.diagnostic, isNull);
        expect(
          requests.last.url,
          Uri.parse('https://api.acme.githubcopilot.com/models'),
        );
      },
    );

    test(
      'enterprise: proxy-ep token routes /models to the tenant host',
      () async {
        final (client, requests) = fakeCopilot(
          exchangeBody:
              '{"token":"cop-ent;proxy-ep=proxy.corp.githubcopilot.com",'
              '"expires_at":1900000000}',
          modelsBody: healthyModelsBody,
        );
        final report = await fetchModelsForEndpointReport(
          'https://api.enterprise.githubcopilot.com',
          apiKey: 'gho_enterprise',
          provider: 'copilot',
          client: client,
        );
        expect(report.info.$1, ['claude-sonnet-5', 'gpt-4.1']);
        expect(report.diagnostic, isNull);
        expect(
          requests.last.url,
          Uri.parse('https://api.corp.githubcopilot.com/models'),
        );
      },
    );

    test(
      'PAT mode: the fine-grained PAT answers directly, never exchanging',
      () async {
        final (client, requests) = fakeCopilot(modelsBody: healthyModelsBody);
        final report = await fetchModelsForEndpointReport(
          'https://api.githubcopilot.com',
          apiKey: 'github_pat_PATMODE',
          provider: 'copilot',
          client: client,
        );
        expect(report.info.$1, ['claude-sonnet-5', 'gpt-4.1']);
        expect(report.diagnostic, isNull);
        expect(
          requests.where((r) => r.url.host == 'api.github.com'),
          isEmpty,
          reason: 'a fine-grained PAT never hits the token exchange',
        );
        expect(
          requests.last.headers['copilot-integration-id'],
          'copilot-developer-cli',
        );
      },
    );
  });

  group('the four silent exits each carry their reason (AC1)', () {
    test(
      'exchange failure names the branch, the status, and the remedies',
      () async {
        final (client, requests) = fakeCopilot(exchangeStatus: 401);
        final report = await fetchModelsForEndpointReport(
          'https://api.githubcopilot.com',
          apiKey: 'gho_dead_token',
          provider: 'copilot',
          client: client,
        );
        expect(report.info.$1, isEmpty);
        final d = report.diagnostic!;
        expect(d.stage, ModelsFetchDiagnostic.stageExchange);
        expect(d.path, ModelsFetchDiagnostic.pathExchange);
        expect(d.httpStatus, 401);
        expect(d.message, contains('exchange'));
        // OAuth-shaped keys do NOT fall back to PAT-direct (one request only).
        expect(requests, hasLength(1));
      },
    );

    test(
      'classic PAT exchange failure hints at the OAuth flow / fine-grained PAT',
      () async {
        final (client, _) = fakeCopilot(exchangeStatus: 401);
        final report = await fetchModelsForEndpointReport(
          'https://api.githubcopilot.com',
          apiKey: 'ghp_classic',
          provider: 'copilot',
          client: client,
        );
        final d = report.diagnostic!;
        // A classic PAT retries PAT-direct (which also answers empty here),
        // so the combined diagnostic names both branches.
        expect(d.stage, 'exchange+models');
        expect(d.message, contains('exchange path:'));
        expect(d.httpStatus, 401);
        expect(d.hint, isNotNull);
        expect(d.hint, contains('OAuth device flow'));
        expect(d.hint, contains('github_pat_'));
      },
    );

    test(
      'models HTTP failure names the status and the seat/tier host hint',
      () async {
        final (client, requests) = fakeCopilot(modelsStatus: 403);
        final report = await fetchModelsForEndpointReport(
          'https://api.githubcopilot.com',
          apiKey: 'gho_seatless',
          provider: 'copilot',
          client: client,
        );
        expect(report.info.$1, isEmpty);
        final d = report.diagnostic!;
        expect(d.stage, ModelsFetchDiagnostic.stageModels);
        expect(d.path, ModelsFetchDiagnostic.pathExchange);
        expect(d.httpStatus, 403);
        expect(d.message, contains('403'));
        expect(d.hint, contains('api.githubcopilot.com'));
        // OAuth keys do not retry PAT-direct.
        expect(requests, hasLength(2));
      },
    );

    test('no-proxy-ep token + business configured host names the tier '
        'misrouting hint', () async {
      final (client, _) = fakeCopilot(
        // Individual-shaped token: no proxy-ep.
        exchangeBody: '{"token":"cop-ind","expires_at":1900000000}',
        modelsStatus: 404,
      );
      final report = await fetchModelsForEndpointReport(
        'https://api.business.githubcopilot.com',
        apiKey: 'gho_individual_on_business',
        provider: 'copilot',
        client: client,
      );
      final d = report.diagnostic!;
      expect(d.stage, ModelsFetchDiagnostic.stageModels);
      expect(
        d.hint,
        contains('individual tokens serve from https://api.githubcopilot.com'),
      );
      expect(d.hint, contains('https://api.business.githubcopilot.com'));
    });

    test(
      'filter dropping everything reports the counts and the reason (AC2)',
      () async {
        final body =
            '{"data":[${List.generate(12, (i) => '{"id":"m$i"}').join(',')}]}}'
                .replaceFirst('}]}}', '}]}');
        final (client, _) = fakeCopilot(modelsBody: body);
        final report = await fetchModelsForEndpointReport(
          'https://api.githubcopilot.com',
          apiKey: 'gho_flagless',
          provider: 'copilot',
          client: client,
        );
        expect(report.info.$1, isEmpty);
        final d = report.diagnostic!;
        expect(d.stage, ModelsFetchDiagnostic.stageFilter);
        expect(d.fetchedCount, 12);
        expect(d.filteredCount, 12);
        expect(
          d.message,
          '12 models fetched, 12 filtered (picker flag absent)',
        );
      },
    );

    test('exchange timeout is named, not swallowed', () async {
      providerTimeoutsOverride = const ProviderTimeoutsOverride(
        connect: Duration(milliseconds: 120),
      );
      final requests = <http.BaseRequest>[];
      final client = http_testing.MockClient((request) async {
        requests.add(request);
        return Completer<http.Response>().future; // hangs
      });
      final report = await fetchModelsForEndpointReport(
        'https://api.githubcopilot.com',
        apiKey: 'gho_hanging_exchange',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, isEmpty);
      final d = report.diagnostic!;
      expect(d.stage, ModelsFetchDiagnostic.stageExchange);
      expect(d.timedOut, isTrue);
      expect(d.message, contains('timed out'));
    });

    test('models timeout is named, not swallowed', () async {
      providerTimeoutsOverride = const ProviderTimeoutsOverride(
        connect: Duration(milliseconds: 500),
        fetchRead: Duration(milliseconds: 120),
      );
      final (client, _) = fakeCopilot(hangModels: true);
      final report = await fetchModelsForEndpointReport(
        'https://api.githubcopilot.com',
        apiKey: 'gho_hanging_models',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, isEmpty);
      final d = report.diagnostic!;
      expect(d.stage, ModelsFetchDiagnostic.stageModels);
      expect(d.timedOut, isTrue);
      expect(d.message, contains('timed out'));
    });

    test('an HTTP 200 empty list says the endpoint answered empty', () async {
      final (client, _) = fakeCopilot(modelsBody: '{"data":[]}');
      final report = await fetchModelsForEndpointReport(
        'https://api.githubcopilot.com',
        apiKey: 'gho_empty',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, isEmpty);
      final d = report.diagnostic!;
      expect(d.message, contains('no models'));
      expect(d.httpStatus, isNull);
    });

    test('an unexpected payload shape is named', () async {
      final (client, _) = fakeCopilot(modelsBody: '{"message":"nope"}');
      final report = await fetchModelsForEndpointReport(
        'https://api.githubcopilot.com',
        apiKey: 'gho_weird',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, isEmpty);
      expect(report.diagnostic!.message, contains('shape'));
    });
  });

  group('filter transparency — per-model drop reasons (AC2)', () {
    test('each criterion names its dropped model', () async {
      final body = jsonEncode({
        'data': [
          {
            'id': 'good',
            'model_picker_enabled': true,
            'supported_endpoints': ['/chat/completions'],
          },
          {'id': 'no-flag'},
          {'id': 'flag-false', 'model_picker_enabled': false},
          {
            'id': 'policy-off',
            'model_picker_enabled': true,
            'policy': {'state': 'disabled'},
          },
          {
            'id': 'no-tools',
            'model_picker_enabled': true,
            'capabilities': {
              'supports': {'tool_calls': false},
            },
          },
          {
            'id': 'responses-only',
            'model_picker_enabled': true,
            'supported_endpoints': ['/responses'],
          },
        ],
      });
      final (client, _) = fakeCopilot(modelsBody: body);
      final report = await fetchModelsForEndpointReport(
        'https://api.githubcopilot.com',
        apiKey: 'gho_mixed',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, ['good']);
      expect(report.diagnostic, isNull, reason: 'models listed — no reason');
      expect(
        report.droppedModels,
        containsAll([
          const ('no-flag', 'picker flag absent'),
          const ('flag-false', 'picker flag false'),
          const ('policy-off', 'policy disabled'),
          const ('no-tools', 'no tool_calls'),
          const ('responses-only', 'endpoint unsupported'),
        ]),
      );
      expect(report.note, contains('5 of 6 models filtered'));
    });

    test('mixed drop reasons are counted in the summary', () async {
      final body = jsonEncode({
        'data': [
          {'id': 'a'}, // absent
          {'id': 'b'}, // absent
          {
            'id': 'c',
            'model_picker_enabled': true,
            'policy': {'state': 'disabled'},
          },
        ],
      });
      final (client, _) = fakeCopilot(modelsBody: body);
      final report = await fetchModelsForEndpointReport(
        'https://api.githubcopilot.com',
        apiKey: 'gho_mixed2',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, isEmpty);
      expect(
        report.diagnostic!.message,
        '3 models fetched, 3 filtered '
        '(picker flag absent ×2, policy disabled)',
      );
    });
  });

  group('dual-path fallback (AC3)', () {
    test(
      'exchange 401 with a classic PAT retries PAT-direct and notes it',
      () async {
        final requests = <http.BaseRequest>[];
        final client = http_testing.MockClient((request) async {
          requests.add(request);
          if (request.url.host == 'api.github.com') {
            return http.Response('{"message":"Bad credentials"}', 401);
          }
          expect(
            request.url,
            Uri.parse('https://api.githubcopilot.com/models'),
          );
          expect(request.headers['authorization'], 'Bearer ghp_rescued');
          expect(
            request.headers['copilot-integration-id'],
            'copilot-developer-cli',
          );
          return http.Response(healthyModelsBody, 200);
        });
        final report = await fetchModelsForEndpointReport(
          'https://api.githubcopilot.com',
          apiKey: 'ghp_rescued',
          provider: 'copilot',
          client: client,
        );
        expect(report.info.$1, ['claude-sonnet-5', 'gpt-4.1']);
        expect(report.diagnostic, isNull);
        expect(report.note, contains('pat-direct'));
        expect(report.note, contains('401'));
      },
    );

    test('both paths failing yields the combined reason', () async {
      final (client, requests) = fakeCopilot(
        exchangeStatus: 401,
        modelsStatus: 401,
      );
      final report = await fetchModelsForEndpointReport(
        'https://api.githubcopilot.com',
        apiKey: 'ghp_doomed',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, isEmpty);
      final d = report.diagnostic!;
      expect(d.message, contains('exchange path:'));
      expect(d.message, contains('pat-direct path:'));
      expect(
        requests,
        hasLength(2),
        reason: 'the exchange + one pat-direct attempt',
      );
    });

    test(
      'a failing fine-grained PAT never falls back into the exchange',
      () async {
        final (client, requests) = fakeCopilot(modelsStatus: 401);
        final report = await fetchModelsForEndpointReport(
          'https://api.githubcopilot.com',
          apiKey: 'github_pat_rejected',
          provider: 'copilot',
          client: client,
        );
        expect(report.info.$1, isEmpty);
        expect(requests.where((r) => r.url.host == 'api.github.com'), isEmpty);
        expect(report.diagnostic!.message, contains('401'));
      },
    );
  });

  group('legacy API parity (AC6)', () {
    test(
      'fetchModelsForEndpoint answers the same ids on healthy tiers',
      () async {
        final (client, _) = fakeCopilot(modelsBody: healthyModelsBody);
        final (ids, windows, _) = await fetchModelsForEndpoint(
          'https://api.githubcopilot.com',
          apiKey: 'gho_individual',
          provider: 'copilot',
          client: client,
        );
        expect(ids, ['claude-sonnet-5', 'gpt-4.1']);
        expect(windows['gpt-4.1'], 128000);
      },
    );

    test('fetchModelsForEndpoint stays empty on failures — no throw', () async {
      final (client, _) = fakeCopilot(exchangeStatus: 401);
      final (ids, windows, caps) = await fetchModelsForEndpoint(
        'https://api.githubcopilot.com',
        apiKey: 'gho_dead',
        provider: 'copilot',
        client: client,
      );
      expect(ids, isEmpty);
      expect(windows, isEmpty);
      expect(caps, isEmpty);
    });

    test('non-copilot dialects answer a report with no diagnostic', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response('{"data":[{"id":"m1"}]}', 200),
      );
      final report = await fetchModelsForEndpointReport(
        'https://api.example.com/v1',
        apiKey: '[REDACTED:Sensitive-Value]',
        client: client,
      );
      expect(report.info.$1, ['m1']);
      expect(report.diagnostic, isNull);
    });
  });
}
