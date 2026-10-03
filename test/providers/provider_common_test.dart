import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

void main() {
  group('formatProviderError — redirect / SSO-expired detection', () {
    const nginx302 =
        '<html>\r\n<head><title>302 Found</title></head>\r\n'
        '<body>\r\n<center><h1>302 Found</h1></center>\r\n'
        '<hr><center>nginx</center>\r\n</body>\r\n</html>';

    test('3xx to a CodeMie endpoint explains the expired session', () {
      final msg = formatProviderError(
        ProviderHttpError(
          302,
          nginx302,
          requestUrl: Uri.parse(
            'https://codemie.lab.epam.com/code-assistant-api/v1/'
            'chat/completions',
          ),
          redirectLocation:
              'https://codemie.lab.epam.com/oauth2/start?rd=%2Fcode-assistant-api',
        ),
      );

      expect(msg, startsWith('302: '));
      expect(msg, contains('CodeMie'));
      expect(msg, contains('expired'));
      expect(msg, contains('/provider codemie sso'));
      // The raw HTML page is NOT dumped into the transcript.
      expect(msg, isNot(contains('<html>')));
      // Machine-readable marker for UIs.
      expect(authExpiredProvider(msg), 'codemie');
    });

    test('3xx to a generic endpoint explains the redirect, no marker', () {
      final msg = formatProviderError(
        ProviderHttpError(
          307,
          '',
          requestUrl: Uri.parse('https://example.com/v1/chat/completions'),
          redirectLocation: 'https://example.org/v1/chat/completions',
        ),
      );

      expect(msg, contains('307'));
      expect(msg, contains('redirect'));
      expect(msg, contains('example.org'));
      expect(authExpiredProvider(msg), isNull);
    });

    test('3xx without a request URL still explains the redirect', () {
      final msg = formatProviderError(const ProviderHttpError(302, nginx302));

      expect(msg, contains('302'));
      expect(msg, contains('redirect'));
      expect(msg, isNot(contains('<html>')));
      expect(authExpiredProvider(msg), isNull);
    });

    test('non-redirect errors keep the classic status+body format', () {
      const body = '{"error":{"message":"bad request"}}';
      final msg = formatProviderError(
        ProviderHttpError(
          400,
          body,
          requestUrl: Uri.parse(
            'https://codemie.lab.epam.com/code-assistant-api/v1/'
            'chat/completions',
          ),
        ),
      );
      expect(msg, '400: $body');
      expect(authExpiredProvider(msg), isNull);
    });

    test('empty-body non-redirect keeps the classic fallback', () {
      final msg = formatProviderError(const ProviderHttpError(500, ''));
      expect(msg, 'Request failed with status 500');
    });

    group('200-with-HTML (silently followed SSO redirect)', () {
      const loginPage =
          '<!DOCTYPE html><html><head><title>Sign in'
          '</title></head><body>login</body></html>';

      test('CodeMie endpoint explains the expired session, with marker', () {
        final msg = formatProviderError(
          ProviderHttpError(
            200,
            loginPage,
            requestUrl: Uri.parse(
              'https://codemie.lab.epam.com/code-assistant-api/v1/'
              'chat/completions',
            ),
            answeredHtml: true,
          ),
        );

        expect(msg, contains('CodeMie'));
        expect(msg, contains('expired'));
        expect(msg, contains('/provider codemie sso'));
        // The login HTML is NOT dumped into the transcript.
        expect(msg, isNot(contains('<html>')));
        expect(authExpiredProvider(msg), 'codemie');
      });

      test('generic endpoint explains the HTML answer, no marker', () {
        final msg = formatProviderError(
          ProviderHttpError(
            200,
            loginPage,
            requestUrl: Uri.parse('https://example.com/v1/chat/completions'),
            answeredHtml: true,
          ),
        );

        expect(msg, contains('HTML'));
        expect(msg, contains('SSO'));
        expect(msg, isNot(contains('<html>')));
        expect(authExpiredProvider(msg), isNull);
      });

      test('without a request URL the generic explanation is used', () {
        final msg = formatProviderError(
          const ProviderHttpError(200, loginPage, answeredHtml: true),
        );

        expect(msg, contains('HTML'));
        expect(msg, isNot(contains('<html>')));
        expect(authExpiredProvider(msg), isNull);
      });
    });

    group('200-with-JSON (gateway error without SSE framing)', () {
      test('surfaces the gateway error body, no auth marker', () {
        const body = '{"error":{"message":"Unknown deployment: gemini-x"}}';
        final msg = formatProviderError(
          ProviderHttpError(
            200,
            body,
            requestUrl: Uri.parse(
              'https://codemie.lab.epam.com/code-assistant-api/v1/'
              'chat/completions',
            ),
            answeredJson: true,
          ),
        );

        expect(msg, contains('JSON'));
        expect(msg, contains('Unknown deployment: gemini-x'));
        expect(authExpiredProvider(msg), isNull);
      });

      test('an overlong body is bounded', () {
        final msg = formatProviderError(
          ProviderHttpError(200, '{"pad":"${'x' * 1000}"}', answeredJson: true),
        );
        expect(msg.length, lessThan(700));
      });
    });
  });

  group('authExpiredProvider / stripAuthExpiredMarker', () {
    test('round-trips the provider id', () {
      const msg = '302: whatever [[auth-expired:codemie]]';
      expect(authExpiredProvider(msg), 'codemie');
      expect(stripAuthExpiredMarker(msg), '302: whatever');
    });

    test('plain text passes through untouched', () {
      const msg = '400: bad request';
      expect(authExpiredProvider(msg), isNull);
      expect(stripAuthExpiredMarker(msg), msg);
    });
  });

  group('text-only image drop notice (issue #638 AC1)', () {
    tearDown(() => textOnlyImageDropNotice = null);

    UserMessage imageTurn() => UserMessage(
      content: const [
        TextContent(text: 'look:'),
        ImageContent(data: 'aGk=', mimeType: 'image/png'),
      ],
      timestamp: DateTime.utc(2026),
    );

    final textOnly = Model(
      id: 'glm-5.3',
      api: 'openai-completions',
      provider: 'zai',
      baseUrl: 'https://api.z.ai/api/coding/paas/v4',
      input: const ['text'],
      contextWindow: 128000,
      maxTokens: 16384,
    );

    test('stripping a text-only model fires the notice with the count', () {
      var seen = <int>[];
      textOnlyImageDropNotice = (dropped) => seen.add(dropped);

      final out = downgradeUnsupportedImages([imageTurn()], textOnly);

      expect(seen, [1]);
      expect(out.single, isA<UserMessage>());
      final blocks = (out.single as UserMessage).content as List<ContentBlock>;
      expect(
        blocks.whereType<ImageContent>(),
        isEmpty,
        reason: 'the strip itself still fires',
      );
    });

    test('an image-capable model strips nothing and stays silent', () {
      var fired = false;
      textOnlyImageDropNotice = (_) => fired = true;
      final vision = Model(
        id: 'glm-5.3-flash',
        api: 'openai-completions',
        provider: 'zai',
        baseUrl: 'https://api.z.ai/api/coding/paas/v4',
        input: const ['text', 'image'],
        contextWindow: 128000,
        maxTokens: 16384,
      );

      final out = downgradeUnsupportedImages([imageTurn()], vision);

      expect(fired, isFalse);
      final blocks = (out.single as UserMessage).content as List<ContentBlock>;
      expect(blocks.whereType<ImageContent>(), isNotEmpty);
    });

    test('a text-only model with no images stays silent', () {
      var fired = false;
      textOnlyImageDropNotice = (_) => fired = true;

      downgradeUnsupportedImages(
        [UserMessage.text('plain', timestamp: DateTime.utc(2026))],
        textOnly,
      );

      expect(fired, isFalse);
    });

    test('an unset hook never throws', () {
      expect(
        () => downgradeUnsupportedImages([imageTurn()], textOnly),
        returnsNormally,
      );
    });
  });

  group('sendProviderFetch watchdogs (issue #1036)', () {
    tearDown(() => providerTimeoutsOverride = null);

    test('defaults: 30s connect (capped by the read budget), 120s read', () {
      expect(providerFetchConnectTimeout, const Duration(seconds: 30));
      expect(providerFetchReadTimeout, const Duration(seconds: 120));
      expect(effectiveProviderFetchReadTimeout, const Duration(seconds: 120));
      // The connect leg never exceeds the overall fetch budget.
      expect(
        effectiveProviderFetchConnectTimeout,
        const Duration(seconds: 30),
      );
      providerTimeoutsOverride = const ProviderTimeoutsOverride(
        fetchRead: Duration(seconds: 10),
      );
      expect(effectiveProviderFetchReadTimeout, const Duration(seconds: 10));
      expect(effectiveProviderFetchConnectTimeout, const Duration(seconds: 10));
    });

    test(
      'a send that never completes fails with a connect TimeoutException '
      'naming the endpoint',
      timeout: const Timeout(Duration(seconds: 20)),
      () async {
        providerTimeoutsOverride = const ProviderTimeoutsOverride(
          fetchRead: Duration(milliseconds: 150),
        );
        final client = http_testing.MockClient(
          (_) => Completer<http.Response>().future,
        );
        await expectLater(
          sendProviderFetch(
            client,
            http.Request('GET', Uri.parse('https://quota.example.com/v1/limit')),
            endpoint: 'provider quota probe',
          ),
          throwsA(
            isA<TimeoutException>().having(
              (e) => e.message,
              'message',
              allOf(contains('provider quota probe'), contains('connect')),
            ),
          ),
        );
      },
    );

    test(
      'a body that never completes fails with a read TimeoutException '
      'naming the endpoint and the env override',
      timeout: const Timeout(Duration(seconds: 20)),
      () async {
        providerTimeoutsOverride = const ProviderTimeoutsOverride(
          fetchRead: Duration(milliseconds: 150),
        );
        // Headers arrive instantly; the body stream never emits a byte
        // and never closes.
        final neverBody = StreamController<List<int>>();
        final client = http_testing.MockClient.streaming((request, body) async {
          return http.StreamedResponse(neverBody.stream, 200);
        });
        await expectLater(
          sendProviderFetch(
            client,
            http.Request('GET', Uri.parse('https://api.example.com/v1/models')),
            endpoint: 'models list',
          ),
          throwsA(
            isA<TimeoutException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('models list'),
                contains('read'),
                contains('FA_PROVIDER_TIMEOUT_SECONDS'),
              ),
            ),
          ),
        );
        // The abandoned body subscription is detached — the socket is not
        // left trickling into a handlerless sink (issue #921 class).
        for (
          var waited = 0;
          neverBody.hasListener && waited < 2000;
          waited += 10
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(neverBody.hasListener, isFalse);
      },
    );

    test('a fast endpoint passes straight through', () async {
      final client = http_testing.MockClient(
        (_) async => http.Response('{"ok":true}', 200),
      );
      final response = await sendProviderFetch(
        client,
        http.Request('GET', Uri.parse('https://api.example.com/v1/models')),
        endpoint: 'models list',
      );
      expect(response.statusCode, 200);
      expect(response.body, '{"ok":true}');
    });

    test('formatProviderError keeps the TimeoutException keyword in front '
        '(the classifier contract, issue #1036 review round 1)', () {
      final msg = formatProviderError(
        TimeoutException(
          'provider fetch (models list): no response headers within 30s',
        ),
      );
      // The failover/queue classifiers match `timeout ?exception` on the
      // RENDERED text: the keyword is load-bearing, the diagnostic follows.
      expect(msg, startsWith('TimeoutException: '));
      expect(msg, contains('models list'));
    });
  });

  group('watchdog URL redaction (issue #1036 review round 2)', () {
    test('redactProviderUrl keeps host, port and path, drops userinfo '
        'and query', () {
      expect(
        redactProviderUrl(
          Uri.parse(
            'https://user:secret-token@gateway.example.com:8443/v1/responses'
            '?api_key=k-123',
          ),
        ),
        'https://gateway.example.com:8443/v1/responses',
      );
      expect(
        redactProviderUrl(Uri.parse('https://api.example.com/v1/models')),
        'https://api.example.com/v1/models',
      );
    });

    test('a connect watchdog on a credentialed endpoint never leaks the '
        'secret into the message', () async {
      addTearDown(() => providerTimeoutsOverride = null);
      providerTimeoutsOverride = const ProviderTimeoutsOverride(
        connect: Duration(milliseconds: 150),
      );
      final client = http_testing.MockClient.streaming(
        (request, requestBody) => Completer<http.StreamedResponse>().future,
      );
      await expectLater(
        sendProviderRequest(
          client,
          http.Request(
            'POST',
            Uri.parse(
              'https://user:secret-token@gateway.example.com/v1/responses'
              '?api_key=k-123',
            ),
          ),
          null,
        ),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('gateway.example.com/v1/responses'),
              isNot(contains('secret-token')),
              isNot(contains('api_key')),
              isNot(contains('user:')),
            ),
          ),
        ),
      );
    });
  });
}
