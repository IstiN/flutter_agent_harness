// dapWsUrlWithToken (dap_frames.dart): the hub password rides the
// `dap_token` query param (browser WebSocket cannot set headers);
// empty secret = the bare URL.
import 'package:test/test.dart';

import '../src/dap/dap_frames.dart';

void main() {
  group('dapWsUrlWithToken', () {
    test('empty secret leaves the url untouched', () {
      expect(
        dapWsUrlWithToken('ws://127.0.0.1:8787/ws', ''),
        'ws://127.0.0.1:8787/ws',
      );
    });

    test('a secret is appended as dap_token (url-encoded)', () {
      final uri = Uri.parse(
        dapWsUrlWithToken('ws://127.0.0.1:8787/ws', 's3cr et+&'),
      );
      expect(uri.queryParameters['dap_token'], 's3cr et+&');
    });

    test('existing query params are preserved', () {
      final uri = Uri.parse(
        dapWsUrlWithToken('ws://127.0.0.1:8787/ws?foo=bar', 'pw'),
      );
      expect(uri.queryParameters['foo'], 'bar');
      expect(uri.queryParameters['dap_token'], 'pw');
    });
  });
}
