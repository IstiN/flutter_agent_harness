// Byte-compat pins for the `.fahx` envelope (issue #1850 AC1): the stateful
// SHA-256/HMAC core must not move a single envelope byte. Every constant
// below was generated from the original package:crypto implementation at
// fixed salt/nonce before the cutover; the KDF vectors are the published
// PBKDF2-HMAC-SHA256 test values for password/salt c=1 and c=2.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/src/cli/provider_export.dart';
import 'package:test/test.dart';

void main() {
  final salt = Uint8List.fromList(List.generate(16, (i) => i * 7 + 1));
  final nonce = Uint8List.fromList(List.generate(16, (i) => i * 13 + 5));

  group('pbkdf2Sha256 published vectors', () {
    test('password/salt c=1 matches the published 64-byte vector', () {
      expect(
        base64Encode(
          pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), 1, 64),
        ),
        'Eg+2z/z4syxD5yJSVsT4N6hlSMkszDVICAWYfLcL4XtNvzovPa0zdyZLt7joMw1O/HRRQY'
        'YX2r72g3NTYc3BjA==',
      );
    });

    test('password/salt c=2 matches the published 64-byte vector', () {
      expect(
        base64Encode(
          pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), 2, 64),
        ),
        'rk0Mla9rRtMtCt/5KPBt0CowP47zwlHf1uLYWpVHTEODBlGvy1yGLwskm9Ax96Z1INE2Rw'
        '9ewnHs6RwHdzJT2Q==',
      );
    });
  });

  group('envelope byte-compat goldens (original implementation)', () {
    test('full default-iteration envelope is byte-stable', () {
      expect(
        jsonEncode(
          encryptProvidersExport(
            '{"version":1,"providers":[{"name":"zai","key":"sk-secret"}]}',
            'correct horse battery',
            salt: salt,
            nonce: nonce,
          ),
        ),
        '{"version":1,"kdf":{"algo":"pbkdf2-sha256","iterations":210000,"salt":'
        '"AQgPFh0kKzI5QEdOVVxjag=="},"nonce":"BRIfLDlGU2BteoeUoa67yA==","ct":"N'
        'ovLlE1512+A7CCC5vI5xwndYYbTi1H/5Nk0S6CU4FuakSr3BR1z9C0zPrK8kRLQYNIlXS1'
        'dsgvo1Xd06kJWAxdRTnQMAjOJlQQwPykAZuATytcMKN+5YhpgnmI="}',
      );
    });

    test('multi-block payload, >64-byte password, 1000 iterations', () {
      final env = encryptProvidersExport(
        'x' * 1000,
        'p' * 80,
        iterations: 1000,
        salt: salt,
        nonce: nonce,
      );
      expect(
        env['ct'],
        'jLHpM8j4Hv5jb0INzeTFe6XDd8+RKkV5sG/qegqVqS5khBWF2hHt5HU8HnYJEh3rnFcOBY'
        'WZr107VHXXJtGFiy11m2MCv9A+P2szOXDRNHeGLru9nKmb6gPlcHFwwqKFae1VYdZKdzb0'
        'kxtUhjEGZ41XvinHR+Ib4m698CJo6zdl0R+zAEJ2kstmRtmw/GPppwAUmgg5kh3mG/6wcr'
        '1bF4Ix2LO7vFBvLzHEzCifG3qmNC2PylyvsD2DXHqFwEJtEfmkZFZ6boz2lZw2CDBSfaQ0'
        'PXgZKb7U0LpYJc7LRTf44JlXfGKn+h65U5FFFSEURXjUnZdEIVjDp9WvTdkbg2TDKmrfU8'
        'kydyrgDh0UuarxrdYsp6c/HhLCV3gFq/rjAyviEBU7QNGjalwmef133Gbz5ufNWy7YXJJN'
        'QTpA176f1mYEooU149hNOtxR4SAh7mxGXCFXlcDHAs7d9oMMQ9VdU238uZi8hglCT7OtXc'
        'NHryh/7c2jPRCOkxYlMqicexfUCQ8/9lXhPSi986WTeiRyo88ZzY/RFI/Z30BGukmcs/Na'
        '9etzSyJteYk5WpkdhTlPbhcGbZDQNC/+mlKJHMCw6S4Gpup9fbN6nGUR83ZswWK3UVC0Ij'
        'fgYkgyTnw1jTGlDtAMF+DWpxuPMB232V2g3AxGuktySunfB2NzuvNqa7A7qNmaogmShA+U'
        'fBFU+50ftN8OIwGzpl1NUaaeLVGwBT+6nmkAWbD8KDOoMJ3Iq7j3k/qKOF3Lmue2B3uUea'
        'rR3DIv5tsDpxdfQhr/CvOCexylNnOBYAhLmkEOFYz5Fi1TnBNSYi4WUNXd4VLXoXxvzlwB'
        'GUHQwJoRLD4EC1ZWUO2Pa2Pqqnh4FHsPHoIbhZU63STqdGxfBVVgavfuSjWAiBs8LNY6/b'
        'FfLGa3/bq/NxiTrRhPfAJY19d9S1qORMolQDjIAuH1vEZc8Q6oD2EKA/ueYJy6hCZcdE+s'
        'QTRMBDjHnQEPcUtC8qxeWCNvRQRza/uL/e41/LnHyiiFkavNxZStgAXzao42xwmY7wTdTG'
        'DI14Z7/TzwekYAiGUafWRhYIbIqwJUOeeZr58i3fK4HnqI7DNYJGKX498hq+rfrR37R3de'
        'E6SlHagabPPr5sTSYN7zhzbH6pMzR5P0J4qF11TOagd3llGqLkLLMzFNLFJ5fy3LR5A0Aj'
        'U1+1HOjgkAvtWkjVWaT5GPhMvPu4FRy8wsgxDhG/T/0Q3LyDY4rAqjxTpkYPT5lrr8Lmvh'
        'WhE/9jIhLhqMNqAZ+x2y1rYznxDoSJg49lItGeUhk6sxCSmjpkikMmolaJvUCb+V8r4YXa'
        'nf3azpQa4rpoGC0asAhEusE0exvMWzehLz0Bu4cOW32XNa',
      );
      expect(decryptProvidersExport(env, 'p' * 80), 'x' * 1000);
    });

    test('empty payload envelope is byte-stable (tag-only blob is malformed)', () {
      final env = encryptProvidersExport(
        '',
        'p',
        iterations: 1,
        salt: salt,
        nonce: nonce,
      );
      expect(
        jsonEncode(env),
        '{"version":1,"kdf":{"algo":"pbkdf2-sha256","iterations":1,"salt":"AQgP'
        'Fh0kKzI5QEdOVVxjag=="},"nonce":"BRIfLDlGU2BteoeUoa67yA==","ct":"WO85EY'
        'eonMqAeYBtRooxnkT987YfEUFy2GFxTihiBLE="}',
      );
      // A tag-only blob is malformed by design (cannot hide a payload).
      expect(
        () => decryptProvidersExport(env, 'p'),
        throwsA(isA<ProviderExportException>()),
      );
    });
  });
}
