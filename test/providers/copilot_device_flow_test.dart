// Unit tests for the GitHub Copilot device flow (`/provider copilot`):
// the device-code request, the polling loop, and the typed errors.
//
// Protocol per goal/copilot_provider.md (migrated from copilot-proxy-go
// internal/auth/device_flow.go) and the Phase-0 live finding: GitHub routes
// the device endpoints but rejects this app's device flow with
// 404 {"error":"Not Found"} — surfaced as `endpointDisabled` naming the
// client id, with the paste-a-token fallback in the message.
//
// No real network: `http.testing.MockClient` only; poll waits go through
// the REQUIRED injectable `delay` (never a real sleep).
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

http.Response _json(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

http.Response _plain(String body, [int status = 200]) =>
    http.Response(body, status);

/// A MockClient routing per-URL and recording every request.
(http_testing.MockClient, List<http.Request>) _router(
  http.Response Function(http.Request request) handler,
) {
  final requests = <http.Request>[];
  return (
    http_testing.MockClient((request) async {
      requests.add(request);
      return handler(request);
    }),
    requests,
  );
}

const _grantJson = {
  'device_code': 'device-code-1',
  'user_code': 'ABCD-1234',
  'verification_uri': 'https://github.com/login/device',
  'expires_in': 900,
  'interval': 5,
};

void main() {
  group('requestCopilotDeviceGrant', () {
    test(
      'posts client_id + scope with a JSON accept header and parses',
      () async {
        final (client, requests) = _router((_) => _json(_grantJson));

        final grant = await requestCopilotDeviceGrant(
          clientId: 'Iv1.test',
          scope: 'read:user',
          client: client,
        );

        expect(grant.deviceCode, 'device-code-1');
        expect(grant.userCode, 'ABCD-1234');
        expect(grant.verificationUri, 'https://github.com/login/device');
        expect(grant.expiresIn, 900);
        expect(grant.interval, 5);
        expect(requests, hasLength(1));
        expect(requests.single.method, 'POST');
        expect(requests.single.url.toString(), contains('/login/device/code'));
        expect(requests.single.headers['accept'], 'application/json');
        expect(requests.single.bodyFields['client_id'], 'Iv1.test');
        expect(requests.single.bodyFields['scope'], 'read:user');
      },
    );

    test('uses the pinned VS Code Copilot client id by default', () async {
      final (client, requests) = _router((_) => _json(_grantJson));

      await requestCopilotDeviceGrant(client: client);

      expect(requests.single.bodyFields['client_id'], 'Iv1.b507a08c87ecfe98');
    });

    test(
      'a 404 JSON error surfaces endpointDisabled naming the client id',
      () async {
        final (client, _) = _router(
          (_) => _json(const {'error': 'Not Found'}, 404),
        );

        Future<CopilotDeviceFlowError> grantFailure(String clientId) async {
          try {
            await requestCopilotDeviceGrant(clientId: clientId, client: client);
          } on CopilotDeviceFlowError catch (error) {
            return error;
          }
          throw StateError('the 404 must fail the grant');
        }

        final flowError = await grantFailure('Iv1.test');
        expect(flowError.kind, CopilotDeviceFlowErrorKind.endpointDisabled);
        expect(flowError.message, contains('Iv1.test'));
        expect(flowError.message, contains('Not Found'));
        expect(flowError.message.toLowerCase(), contains('token'));
      },
    );

    test('a non-JSON error body surfaces a transport error', () async {
      final (client, _) = _router((_) => _plain('<html>422</html>', 422));

      await expectLater(
        requestCopilotDeviceGrant(client: client),
        throwsA(
          isA<CopilotDeviceFlowError>().having(
            (e) => e.kind,
            'kind',
            CopilotDeviceFlowErrorKind.transport,
          ),
        ),
      );
    });

    test('a socket-level failure surfaces a transport error', () async {
      final client = http_testing.MockClient(
        (_) => throw Exception('connection refused'),
      );

      await expectLater(
        requestCopilotDeviceGrant(client: client),
        throwsA(
          isA<CopilotDeviceFlowError>().having(
            (e) => e.kind,
            'kind',
            CopilotDeviceFlowErrorKind.transport,
          ),
        ),
      );
    });

    test(
      'a 200 body without the device fields surfaces a transport error',
      () async {
        final (client, _) = _router((_) => _json(const {'surprise': true}));

        await expectLater(
          requestCopilotDeviceGrant(client: client),
          throwsA(
            isA<CopilotDeviceFlowError>().having(
              (e) => e.kind,
              'kind',
              CopilotDeviceFlowErrorKind.transport,
            ),
          ),
        );
      },
    );
  });

  group('pollCopilotDeviceGrant', () {
    (List<Duration>, Future<String> Function()) pollHarness(
      List<http.Response> responses,
    ) {
      final delays = <Duration>[];
      var index = 0;
      final (client, requests) = _router((request) => responses[index++]);
      Future<String> run() => pollCopilotDeviceGrant(
        grant: const CopilotDeviceGrant(
          deviceCode: 'dc',
          userCode: 'UC-1',
          verificationUri: 'https://github.com/login/device',
          expiresIn: 900,
          interval: 5,
        ),
        clientId: 'Iv1.test',
        delay: (d) async => delays.add(d),
        client: client,
      );
      return (delays, run);
    }

    test('polls with the device-code grant_type and JSON accept', () async {
      final (client, requests) = _router(
        (_) => _json(const {'access_token': 'gh-shape'}),
      );

      final token = await pollCopilotDeviceGrant(
        grant: const CopilotDeviceGrant(
          deviceCode: 'dc',
          userCode: 'UC-1',
          verificationUri: 'https://github.com/login/device',
          expiresIn: 900,
          interval: 5,
        ),
        clientId: 'Iv1.test',
        delay: (_) async {},
        client: client,
      );

      expect(token, 'gh-shape');
      expect(requests, hasLength(1));
      expect(
        requests.single.url.toString(),
        contains('/login/oauth/access_token'),
      );
      expect(requests.single.headers['accept'], 'application/json');
      expect(requests.single.bodyFields['client_id'], 'Iv1.test');
      expect(requests.single.bodyFields['device_code'], 'dc');
      expect(
        requests.single.bodyFields['grant_type'],
        'urn:ietf:params:oauth:grant-type:device_code',
      );
    });

    test('pending then success returns the GitHub token', () async {
      final (delays, run) = pollHarness([
        _json(const {'error': 'authorization_pending'}),
        _json(const {'access_token': 'gh-token-1', 'token_type': 'bearer'}),
      ]);

      final token = await run();

      expect(token, 'gh-token-1');
      // Base poll interval = the server interval + 1s (proxy semantics).
      expect(delays.first, const Duration(seconds: 6));
      expect(delays, hasLength(2));
    });

    test('slow_down grows the interval by 5s cumulatively', () async {
      final (delays, run) = pollHarness([
        _json(const {'error': 'slow_down'}),
        _json(const {'error': 'authorization_pending'}),
        _json(const {'access_token': 'gh-2'}),
      ]);

      await run();

      expect(delays[0], const Duration(seconds: 6));
      expect(delays[1], const Duration(seconds: 11));
      expect(delays[2], const Duration(seconds: 11));
    });

    test('expired_token surfaces the expired error', () async {
      final (delays, run) = pollHarness([
        _json(const {'error': 'expired_token'}),
      ]);

      await expectLater(
        run(),
        throwsA(
          isA<CopilotDeviceFlowError>()
              .having((e) => e.kind, 'kind', CopilotDeviceFlowErrorKind.expired)
              .having((e) => e.message, 'message', contains('expired')),
        ),
      );
      expect(delays, hasLength(1));
    });

    test('access_denied surfaces the denied error', () async {
      final (_, run) = pollHarness([
        _json(const {'error': 'access_denied'}),
      ]);

      await expectLater(
        run(),
        throwsA(
          isA<CopilotDeviceFlowError>().having(
            (e) => e.kind,
            'kind',
            CopilotDeviceFlowErrorKind.denied,
          ),
        ),
      );
    });

    test('the wait is bounded by expires_in even while pending', () async {
      final delays = <Duration>[];
      final (client, _) = _router(
        (_) => _json(const {'error': 'authorization_pending'}),
      );

      await expectLater(
        pollCopilotDeviceGrant(
          grant: const CopilotDeviceGrant(
            deviceCode: 'dc',
            userCode: 'UC-1',
            verificationUri: 'https://github.com/login/device',
            expiresIn: 10,
            interval: 5,
          ),
          clientId: 'Iv1.test',
          delay: (d) async => delays.add(d),
          client: client,
        ),
        throwsA(
          isA<CopilotDeviceFlowError>().having(
            (e) => e.kind,
            'kind',
            CopilotDeviceFlowErrorKind.expired,
          ),
        ),
      );
      // 6 + 6 = 12s of waiting >= the 10s budget: exactly two cycles.
      expect(delays, hasLength(2));
    });

    test('a 404 from the poll endpoint surfaces endpointDisabled', () async {
      final (_, run) = pollHarness([
        _json(const {'error': 'Not Found'}, 404),
      ]);

      await expectLater(
        run(),
        throwsA(
          isA<CopilotDeviceFlowError>()
              .having(
                (e) => e.kind,
                'kind',
                CopilotDeviceFlowErrorKind.endpointDisabled,
              )
              .having((e) => e.message, 'message', contains('Iv1.test')),
        ),
      );
    });

    test('a non-JSON poll body surfaces a transport error', () async {
      final (_, run) = pollHarness([_plain('<html></html>', 500)]);

      await expectLater(
        run(),
        throwsA(
          isA<CopilotDeviceFlowError>().having(
            (e) => e.kind,
            'kind',
            CopilotDeviceFlowErrorKind.transport,
          ),
        ),
      );
    });

    test('a 200 without token or error surfaces a transport error', () async {
      final (_, run) = pollHarness([
        _json(const {'status': 'weird'}),
      ]);

      await expectLater(
        run(),
        throwsA(
          isA<CopilotDeviceFlowError>().having(
            (e) => e.kind,
            'kind',
            CopilotDeviceFlowErrorKind.transport,
          ),
        ),
      );
    });

    test('an unknown OAuth error surfaces a transport error', () async {
      final (_, run) = pollHarness([
        _json(const {'error': 'unsupported_grant_type'}),
      ]);

      await expectLater(
        run(),
        throwsA(
          isA<CopilotDeviceFlowError>().having(
            (e) => e.kind,
            'kind',
            CopilotDeviceFlowErrorKind.transport,
          ),
        ),
      );
    });

    test('a socket-level poll failure surfaces a transport error', () async {
      final client = http_testing.MockClient(
        (_) => throw Exception('reset by peer'),
      );
      final delays = <Duration>[];

      await expectLater(
        pollCopilotDeviceGrant(
          grant: const CopilotDeviceGrant(
            deviceCode: 'dc',
            userCode: 'UC-1',
            verificationUri: 'https://github.com/login/device',
            expiresIn: 900,
            interval: 5,
          ),
          clientId: 'Iv1.test',
          delay: (d) async => delays.add(d),
          client: client,
        ),
        throwsA(
          isA<CopilotDeviceFlowError>().having(
            (e) => e.kind,
            'kind',
            CopilotDeviceFlowErrorKind.transport,
          ),
        ),
      );
    });

    test('reports waiting status lines through onStatus', () async {
      final statuses = <String>[];
      final (client, _) = _router(
        (_) => _json(const {'error': 'authorization_pending'}),
      );

      await expectLater(
        pollCopilotDeviceGrant(
          grant: const CopilotDeviceGrant(
            deviceCode: 'dc',
            userCode: 'UC-1',
            verificationUri: 'https://github.com/login/device',
            expiresIn: 8,
            interval: 5,
          ),
          clientId: 'Iv1.test',
          delay: (d) async {},
          onStatus: statuses.add,
          client: client,
        ),
        throwsA(isA<CopilotDeviceFlowError>()),
      );

      expect(statuses, isNotEmpty);
      expect(statuses.first, contains('waiting'));
    });
  });
  test('CopilotDeviceFlowError renders its message', () {
    const error = CopilotDeviceFlowError(
      CopilotDeviceFlowErrorKind.expired,
      'the code expired',
    );

    expect(error.toString(), 'the code expired');
  });
}
