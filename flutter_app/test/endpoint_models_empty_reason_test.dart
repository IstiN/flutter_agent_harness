// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/analytics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'package:fa/ui/screens/endpoint_models_controller.dart';

/// gh-1990 — the endpoint model quick-select carries the named empty
/// reason: a Copilot provider whose /models dialect answers empty exposes
/// the failing branch on [EndpointModelsController.emptyReason] instead
/// of a bare empty suggestion list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    setModelsDispatchClientForTesting(null);
    AppAnalytics.install(null);
  });

  late void Function(void Function()) mutate;

  EndpointModelsController controllerFor() {
    mutate = (fn) => fn();
    return EndpointModelsController(
      mutate: mutate,
      baseUrl: () => 'https://api.githubcopilot.com',
      apiKey: () => 'gho_dead',
      identityKind: () => 'copilot',
      fetchEnabled: () => true,
      overrideFetcher: () => null,
    );
  }

  testWidgets('a failing copilot fetch names the branch on emptyReason', (
    tester,
  ) async {
    final client = http_testing.MockClient((request) async {
      if (request.url.host == 'api.github.com') {
        return http.Response('{"message":"Bad credentials"}', 401);
      }
      return http.Response('{"message":"no"}', 401);
    });
    setModelsDispatchClientForTesting(client);
    final controller = controllerFor();

    await controller.fetch();
    await tester.pump();

    expect(controller.models, isEmpty);
    expect(controller.emptyReason, isNotNull);
    expect(controller.emptyReason, contains('exchange'));
    expect(controller.loading, isFalse);
  });

  testWidgets('a healthy copilot fetch lists models with no reason', (
    tester,
  ) async {
    final client = http_testing.MockClient((request) async {
      if (request.url.host == 'api.github.com') {
        return http.Response(
          '{"token":"cop-tok","expires_at":9999999999}',
          200,
        );
      }
      return http.Response(
        '{"data":[{"id":"gpt-4.1","model_picker_enabled":true,'
        '"supported_endpoints":["/chat/completions"]}]}',
        200,
      );
    });
    setModelsDispatchClientForTesting(client);
    final controller = controllerFor();

    await controller.fetch();
    await tester.pump();

    expect(controller.models, ['gpt-4.1']);
    expect(controller.emptyReason, isNull);
  });

  testWidgets('a filter-empty copilot answer carries the filter counts', (
    tester,
  ) async {
    final client = http_testing.MockClient((request) async {
      if (request.url.host == 'api.github.com') {
        return http.Response(
          '{"token":"cop-tok","expires_at":9999999999}',
          200,
        );
      }
      return http.Response('{"data":[{"id":"embed-1"},{"id":"embed-2"}]}', 200);
    });
    setModelsDispatchClientForTesting(client);
    final controller = controllerFor();

    await controller.fetch();
    await tester.pump();

    expect(controller.models, isEmpty);
    expect(
      controller.emptyReason,
      '2 models fetched, 2 filtered '
      '(picker flag absent)',
    );
  });

  testWidgets('an override fetcher answer lists models with no reason', (
    tester,
  ) async {
    final controller = EndpointModelsController(
      mutate: (fn) => fn(),
      baseUrl: () => 'https://acme.example/v1',
      apiKey: () => 'sk-test',
      identityKind: () => null,
      fetchEnabled: () => true,
      overrideFetcher: () =>
          (baseUrl, {required apiKey}) async =>
              (
                const ['m-1', 'm-2'],
                const <String, int>{'m-1': 64000},
                const <String, int>{},
              ),
    );

    await controller.fetch();
    await tester.pump();

    expect(controller.models, ['m-1', 'm-2']);
    expect(controller.contextWindows['m-1'], 64000);
    expect(controller.emptyReason, isNull);
    expect(controller.loading, isFalse);
  });

  testWidgets('a throwing override lands the catch reset — no reason, no '
      'stale loading', (tester) async {
    final controller = EndpointModelsController(
      mutate: (fn) => fn(),
      baseUrl: () => 'https://acme.example/v1',
      apiKey: () => 'sk-test',
      identityKind: () => null,
      fetchEnabled: () => true,
      overrideFetcher: () =>
          (baseUrl, {required apiKey}) async => throw StateError('boom'),
    );

    await controller.fetch();
    await tester.pump();

    expect(controller.models, isEmpty);
    expect(controller.emptyReason, isNull);
    expect(controller.loading, isFalse);
  });
}
