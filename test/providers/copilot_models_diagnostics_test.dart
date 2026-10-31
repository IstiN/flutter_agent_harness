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

  /// A business-tier exchange answer: the proxy-ep token routes /models
  /// to the acme tenant host, whose payload shape keeps the STRICT
  /// picker list (gh-2003: the tier fallback is individual-tier-only).
  const businessExchangeBody =
      '{"token":"cop-biz;proxy-ep=proxy.acme.githubcopilot.com;'
      'exp=1900000000","expires_at":1900000000}';

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
        final (client, _) = fakeCopilot(
          exchangeBody: businessExchangeBody,
          modelsBody: body,
        );
        final report = await fetchModelsForEndpointReport(
          'https://api.business.githubcopilot.com',
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
      final (client, _) = fakeCopilot(
        exchangeBody: businessExchangeBody,
        modelsBody: body,
      );
      final report = await fetchModelsForEndpointReport(
        'https://api.business.githubcopilot.com',
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
      final (client, _) = fakeCopilot(
        exchangeBody: businessExchangeBody,
        modelsBody: body,
      );
      final report = await fetchModelsForEndpointReport(
        'https://api.business.githubcopilot.com',
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

  group('tier-aware picker-flag fallback (gh-2003)', () {
    // The gh-2003 shape: individual-tier /models payloads omit
    // model_picker_enabled entirely — phase 1 dropped every entry as
    // "picker flag absent" and the list stayed empty.
    const flagAbsentBody =
        '{"data":['
        '{"id":"gpt-4.1","capabilities":{"limits":'
        '{"max_context_window_tokens":128000,"max_output_tokens":16384}}},'
        '{"id":"claude-sonnet-5"}'
        ']}';
    const noProxyEpToken =
        '{"token":"cop-ind;exp=1900000000","expires_at":1900000000}';

    test('individual tier: an absent picker flag is kept, and the keep '
        'names itself (AC5)', () async {
      final (client, _) = fakeCopilot(
        exchangeBody: noProxyEpToken, // no proxy-ep — individual by design
        modelsBody: flagAbsentBody,
      );
      final report = await fetchModelsForEndpointReport(
        'https://api.githubcopilot.com',
        apiKey: 'gho_session',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, ['claude-sonnet-5', 'gpt-4.1']);
      expect(report.info.$2['gpt-4.1'], 128000);
      expect(report.info.$3['gpt-4.1'], 16384);
      expect(report.diagnostic, isNull, reason: 'models listed');
      expect(
        report.note,
        '2 of 2 models kept via the individual-tier fallback '
        '(picker flag absent)',
        reason:
            'the tier-aware keep names what happened — never a '
            'silent swallow of the absent flag',
      );
    });

    test('individual tier: an explicit model_picker_enabled false still '
        'drops', () async {
      final body =
          '{"data":['
          '{"id":"gpt-4.1"},'
          '{"id":"text-embedding-3-small","model_picker_enabled":false}'
          ']}';
      final (client, _) = fakeCopilot(
        exchangeBody: noProxyEpToken,
        modelsBody: body,
      );
      final report = await fetchModelsForEndpointReport(
        'https://api.githubcopilot.com',
        apiKey: 'gho_session',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, ['gpt-4.1']);
      expect(
        report.droppedModels,
        contains(const ('text-embedding-3-small', 'picker flag false')),
      );
      expect(
        report.note,
        '1 of 2 models filtered (picker flag false); '
        '1 of 2 models kept via the individual-tier fallback '
        '(picker flag absent)',
      );
    });

    test('individual tier: mixed reasons — absent kept, the rest still '
        'named', () async {
      final body =
          '{"data":['
          '{"id":"a"},' // absent → kept via the fallback
          '{"id":"b"},' // absent → kept via the fallback
          '{"id":"c","model_picker_enabled":true,'
          '"policy":{"state":"disabled"}},' // dropped: policy
          '{"id":"d","model_picker_enabled":true,'
          '"supported_endpoints":["/responses"]},' // dropped: endpoint
          '{"id":"e","model_picker_enabled":true}' // plainly selectable
          ']}';
      final (client, _) = fakeCopilot(
        exchangeBody: noProxyEpToken,
        modelsBody: body,
      );
      final report = await fetchModelsForEndpointReport(
        'https://api.githubcopilot.com',
        apiKey: 'gho_session',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, ['a', 'b', 'e']);
      expect(
        report.note,
        '2 of 5 models filtered (policy disabled, endpoint unsupported); '
        '2 of 5 models kept via the individual-tier fallback '
        '(picker flag absent)',
      );
    });

    test('individual tier: an all-false payload still names the filter '
        'branch — no silent empty', () async {
      final body =
          '{"data":['
          '{"id":"embed-1","model_picker_enabled":false},'
          '{"id":"embed-2","model_picker_enabled":false}'
          ']}';
      final (client, _) = fakeCopilot(
        exchangeBody: noProxyEpToken,
        modelsBody: body,
      );
      final report = await fetchModelsForEndpointReport(
        'https://api.githubcopilot.com',
        apiKey: 'gho_session',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, isEmpty);
      final d = report.diagnostic!;
      expect(d.stage, ModelsFetchDiagnostic.stageFilter);
      expect(d.message, '2 models fetched, 2 filtered (picker flag false)');
    });

    test('business tier: absent flags still drop — strict picker list '
        'as today', () async {
      final (client, _) = fakeCopilot(
        exchangeBody:
            '{"token":"cop-biz;proxy-ep=proxy.acme.githubcopilot.com;'
            'exp=1900000000","expires_at":1900000000}',
        modelsBody: flagAbsentBody,
      );
      final report = await fetchModelsForEndpointReport(
        'https://api.business.githubcopilot.com',
        apiKey: 'gho_session',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, isEmpty);
      final d = report.diagnostic!;
      expect(d.stage, ModelsFetchDiagnostic.stageFilter);
      expect(d.message, '2 models fetched, 2 filtered (picker flag absent)');
      expect(report.note, isNull);
    });

    test('enterprise tier: absent flags still drop — strict picker list '
        'as today', () async {
      final (client, _) = fakeCopilot(
        exchangeBody:
            '{"token":"cop-corp;proxy-ep=proxy.corp.githubcopilot.com;'
            'exp=1900000000","expires_at":1900000000}',
        modelsBody: flagAbsentBody,
      );
      final report = await fetchModelsForEndpointReport(
        'https://api.enterprise.githubcopilot.com',
        apiKey: 'gho_session',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, isEmpty);
      expect(
        report.diagnostic!.message,
        '2 models fetched, 2 filtered (picker flag absent)',
      );
    });

    test('PAT mode on the individual host: absent flags kept, named', () async {
      final (client, requests) = fakeCopilot(modelsBody: flagAbsentBody);
      final report = await fetchModelsForEndpointReport(
        'https://api.githubcopilot.com',
        apiKey: 'github_pat_fine',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, ['claude-sonnet-5', 'gpt-4.1']);
      expect(report.note, contains('kept via the individual-tier fallback'));
      expect(requests.where((r) => r.url.host == 'api.github.com'), isEmpty);
    });

    test('PAT mode on the business host: absent flags still drop', () async {
      final (client, _) = fakeCopilot(modelsBody: flagAbsentBody);
      final report = await fetchModelsForEndpointReport(
        'https://api.business.githubcopilot.com',
        apiKey: 'github_pat_fine',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, isEmpty);
      expect(
        report.diagnostic!.message,
        '2 models fetched, 2 filtered (picker flag absent)',
      );
    });

    test('an individual proxy-ep token (api.individual.…) gets the same '
        'fallback — the pi-mono trigger spelling', () async {
      final (client, requests) = fakeCopilot(
        exchangeBody:
            '{"token":"cop-ind;proxy-ep=proxy.individual.githubcopilot.com;'
            'exp=1900000000","expires_at":1900000000}',
        modelsBody: flagAbsentBody,
      );
      final report = await fetchModelsForEndpointReport(
        'https://api.githubcopilot.com',
        apiKey: 'gho_session',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, ['claude-sonnet-5', 'gpt-4.1']);
      expect(
        requests.last.url,
        Uri.parse('https://api.individual.githubcopilot.com/models'),
        reason: 'the token routes /models to its own tenant host',
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
        d.stages,
        ['exchange', 'models'],
        reason:
            'programatic consumers match the documented vocabulary — '
            'the combined dual-path stage splits back apart',
      );
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
    test('unparseable HTTP 200 body names its branch — no throw', () async {
      // gh-1990 review (BLOCKING): the refactor moved the /models parse
      // out of the dialect's `on Object → empty` catch — a captive
      // portal / proxy error page (HTTP 200, not JSON) must NOT throw
      // through the dispatch (the dialect contract at the top of
      // models_for_endpoint.dart) nor crash the unguarded CLI connect
      // flow. It names its branch instead. A fine-grained PAT pins the
      // SINGLE-path shape (a PAT never falls into the exchange).
      final (client, requests) = fakeCopilot(
        modelsBody: '<html>captive portal</html>',
      );
      final report = await fetchModelsForEndpointReport(
        'https://api.githubcopilot.com',
        apiKey: 'github_pat_SINGLEPATH',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, isEmpty);
      final d = report.diagnostic!;
      expect(d.stage, ModelsFetchDiagnostic.stageModels);
      expect(d.message, contains('unparseable payload'));
      expect(d.message, contains('HTTP 200'));
      expect(
        d.pathFailed,
        isTrue,
        reason:
            'a parse failure is a path failure — the dual-path '
            'fallback may retry the other credential route',
      );
      expect(
        requests,
        hasLength(1),
        reason: 'a fine-grained PAT never falls into the exchange',
      );
    });

    test('unparseable HTTP 200 body on OAuth retries pat-direct, then '
        'names both paths', () async {
      final (client, requests) = fakeCopilot(
        modelsBody: '<html>captive portal</html>',
      );
      final report = await fetchModelsForEndpointReport(
        'https://api.githubcopilot.com',
        apiKey: '[REDACTED:Sensitive-Value]',
        provider: 'copilot',
        client: client,
      );
      expect(report.info.$1, isEmpty);
      final d = report.diagnostic!;
      expect(
        d.stage,
        '${ModelsFetchDiagnostic.stageModels}'
        '${ModelsFetchDiagnostic.stageDualJoiner}'
        '${ModelsFetchDiagnostic.stageModels}',
      );
      expect(d.stages, ['models', 'models']);
      expect(d.message, contains('unparseable payload'));
      expect(
        requests.where((r) => r.url.host != 'api.github.com'),
        hasLength(2),
        reason:
            'the parse failure IS a path failure — the fallback '
            'retry may run (plus the one exchange request)',
      );
    });

    test('unparseable HTTP 200 body answers empty on the legacy API', () async {
      final (client, _) = fakeCopilot(
        modelsBody: '<html>captive portal</html>',
      );
      final (ids, windows, caps) = await fetchModelsForEndpoint(
        'https://api.githubcopilot.com',
        apiKey: '[REDACTED:Sensitive-Value]',
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

  const testEmptyInfo = (<String>[], <String, int>{}, <String, int>{});

  group('userFacingReason — the one formatting rule (review DRY)', () {
    test('diagnostic joins its hint; diagnostic-only answers bare', () {
      const report = ModelsFetchReport(
        info: testEmptyInfo,
        diagnostic: ModelsFetchDiagnostic(
          stage: ModelsFetchDiagnostic.stageModels,
          path: ModelsFetchDiagnostic.pathExchange,
          message: 'exchange failed',
          hint: 're-authorize Copilot',
        ),
      );
      expect(report.userFacingReason, 'exchange failed — re-authorize Copilot');

      const bare = ModelsFetchReport(
        info: testEmptyInfo,
        diagnostic: ModelsFetchDiagnostic(
          stage: ModelsFetchDiagnostic.stageFilter,
          path: ModelsFetchDiagnostic.pathExchange,
          message: '3 models fetched, 3 filtered (picker flag absent)',
        ),
      );
      expect(
        bare.userFacingReason,
        '3 models fetched, 3 filtered (picker flag absent)',
      );
    });

    test('no diagnostic falls back to the note; neither answers null', () {
      const noted = ModelsFetchReport(
        info: testEmptyInfo,
        note: 'models via the pat-direct fallback',
      );
      expect(noted.userFacingReason, 'models via the pat-direct fallback');

      const silent = ModelsFetchReport(info: testEmptyInfo);
      expect(silent.userFacingReason, isNull);
    });
  });
}
