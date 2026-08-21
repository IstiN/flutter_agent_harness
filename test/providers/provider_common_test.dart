import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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
}
