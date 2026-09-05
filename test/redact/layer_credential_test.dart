import 'package:flutter_agent_harness/src/redact/redaction_pipeline.dart';
import 'package:test/test.dart';

const _cfg = RedactionConfig();

String one(String src, List<RedactionMatch> matches) {
  expect(matches, hasLength(1));
  return src.substring(matches.single.start, matches.single.end);
}

/// (a) login form: user stays, password goes.
const _loginForm = '<form>\n'
    '<input type="text" name="user" value="bob">\n'
    '<input type="password" name="password" value="hunter2" '
    'autocomplete="current-password">\n'
    '</form>';

/// (b) credit-card form: every cc-* value is a credential.
const _ccForm = '<input type="text" name="cardnum" autocomplete="cc-number" '
    'value="4111 1111 1111 1111">\n'
    '<input name="csc" autocomplete="cc-csc" value="123">\n'
    '<input name="exp" autocomplete="cc-exp" value="12/28">';

/// (c) SSO form: token/secret names, value attr before type, single quotes.
const _ssoForm = '<input id="sso_token" value="tok_9f8e7d6c" type="text">\n'
    "<input name='client_secret' value='s3cr3tv4l' type='text'>\n"
    '<input type="text" name="account" value="alice">';

/// (d) JSON-ish DOM capture.
const _jsonCapture =
    '{"password": "hunter2", "user": "bob", "api_key": "sk-abc"}';

/// (e) no over-redaction golden: nothing here leaks.
const _harmless = '<input type="search" name="q" value="flutter test">\n'
    '<input type="text" name="email" value="bob@example.com">\n'
    '<input type="password" name="password" placeholder="Enter password">\n'
    '<input type="password" name="password" value="">\n'
    '<input type="text" name="note" aria-label="secret" value="plain note">';

void main() {
  group('layerCredential', () {
    test('login form: password masked, user untouched', () {
      final matches = layerCredential(_loginForm, _cfg);
      expect(one(_loginForm, matches), 'hunter2');
      expect(matches.single.layer, RedactionLayer.credential);
      expect(matches.single.kindLabel, credentialLabel);
    });

    test('credit-card form: cc-* autocomplete values masked', () {
      final matches = layerCredential(_ccForm, _cfg);
      final values = matches
          .map((m) => _ccForm.substring(m.start, m.end))
          .toSet();
      expect(values, {'4111 1111 1111 1111', '123', '12/28'});
    });

    test('SSO form: token/secret names, any attribute order, any quotes', () {
      final matches = layerCredential(_ssoForm, _cfg);
      final values = matches
          .map((m) => _ssoForm.substring(m.start, m.end))
          .toSet();
      expect(values, {'tok_9f8e7d6c', 's3cr3tv4l'});
      expect(_ssoForm.contains('alice'), isTrue);
    });

    test('JSON capture: secret values masked, other keys untouched', () {
      final matches = layerCredential(_jsonCapture, _cfg);
      final values = matches
          .map((m) => _jsonCapture.substring(m.start, m.end))
          .toSet();
      expect(values, {'hunter2', 'sk-abc'});
    });

    test('no over-redaction golden: zero matches', () {
      for (final src in _harmless.split('\n')) {
        expect(layerCredential(src, _cfg), isEmpty, reason: src);
      }
      expect(layerCredential(_harmless, _cfg), isEmpty);
    });

    test('marker-only value never re-matches', () {
      const src = '<input type="password" name="password" '
          'value="[REDACTED:credential]">';
      expect(layerCredential(src, _cfg), isEmpty);
    });

    test('JSON keys are quote-anchored, not substrings', () {
      expect(layerCredential('{"passwordGenerator": "off"}', _cfg), isEmpty);
      expect(layerCredential('{"user_token": "t1"}', _cfg), isEmpty);
    });

    test('empty text yields nothing', () {
      expect(layerCredential('', _cfg), isEmpty);
    });

    test('UT-S7 pipeline integration: masked, line-preserving, idempotent',
        () {
      final pipeline = RedactionPipeline(registeredSecrets: const []);
      final out = pipeline.redact(_loginForm);
      expect(out, contains('[REDACTED:credential]'));
      expect(out, contains('value="bob"'));
      expect(out, isNot(contains('hunter2')));
      expect(
        '\n'.allMatches(out).length,
        '\n'.allMatches(_loginForm).length,
      );
      expect(pipeline.redact(out), out);
    });

    test('UT-S7 extension: page captures get full-pipeline scanning', () {
      const openaiKey = 'sk-a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8s9T0';
      const page = 'debug log:\n'
          'key $openaiKey end\n'
          'API_KEY=supersecretvalue123\n'
          '-----BEGIN PRIVATE KEY-----\n'
          'MIIBVAIBADANBgkqhkiG9w0BAQEFAASCAT4wggE6AgEAAkEA0\n'
          '-----END PRIVATE KEY-----\n';
      final out = RedactionPipeline(registeredSecrets: const []).redact(page);
      expect(out, contains('[REDACTED:OpenAI Key]'));
      expect(out, contains('[REDACTED:Sensitive Value]'));
      expect(out, contains('[REDACTED:PEM PRIVATE KEY]'));
      expect(out, isNot(contains(openaiKey)));
    });
  });
}
