import 'package:flutter_agent_harness/src/redact/layer_context.dart';
import 'package:flutter_agent_harness/src/redact/redaction_types.dart';
import 'package:test/test.dart';

const _cfg = RedactionConfig();

String one(String src, List<RedactionMatch> matches) {
  expect(matches, hasLength(1));
  return src.substring(matches.single.start, matches.single.end);
}

void main() {
  group('layerContext', () {
    test('password= masks the value span only', () {
      const src = 'login ok password=hunter2 done';
      final matches = layerContext(src, _cfg);
      expect(one(src, matches), 'hunter2');
      expect(matches.single.layer, RedactionLayer.context);
      expect(matches.single.kindLabel, sensitiveValueLabel);
      // The key itself is not masked.
      expect(
        src.substring(matches.single.start - 1, matches.single.start),
        '=',
      );
    });

    test('colon separators and spaces around =', () {
      for (final line in [
        'passwd: huck2',
        'secret: s3cr3t',
        'api_key: aaaaaa',
        'token = tok123',
      ]) {
        final matches = layerContext(line, _cfg);
        expect(matches, hasLength(1), reason: line);
        expect(
          line.substring(matches.single.start, matches.single.end),
          line.split(RegExp('[:=]')).last.trim(),
          reason: line,
        );
      }
    });

    test('export SECRET=... form', () {
      const src = 'export SECRET=topsecretvalue';
      expect(one(src, layerContext(src, _cfg)), 'topsecretvalue');
    });

    test('JSON quoted form', () {
      const src = '{"user":"bob","password":"my pass phrase","n":1}';
      expect(one(src, layerContext(src, _cfg)), 'my pass phrase');
    });

    test('E7: unicode (Cyrillic) values', () {
      const src = 'password: пароль-секрет123';
      expect(one(src, layerContext(src, _cfg)), 'пароль-секрет123');
    });

    test('unquoted values end at the first space', () {
      const src = 'token = tok tok tok';
      expect(one(src, layerContext(src, _cfg)), 'tok');
    });

    test('value stops at delimiters', () {
      const src = 'password=abc,def and x=1';
      expect(one(src, layerContext(src, _cfg)), 'abc');
    });

    test('variable placeholders are not masked', () {
      expect(layerContext('password=\$DB_PASS', _cfg), isEmpty);
      expect(layerContext('password=\${DB_PASS}', _cfg), isEmpty);
      expect(layerContext('password=<user input>', _cfg), isEmpty);
    });

    test('keys without values do not match', () {
      expect(layerContext('password:', _cfg), isEmpty);
      expect(layerContext('no credentials here', _cfg), isEmpty);
    });

    test('word-boundary guard', () {
      expect(layerContext('tokenize the string', _cfg), isEmpty);
      expect(layerContext('apier is not a key', _cfg), isEmpty);
    });

    test('cert dump: subject=/issuer= values masked', () {
      const src = 'subject=/C=US/O=Org\nissuer=/C=US/O=Test CA RSA';
      final matches = layerContext(src, _cfg);
      final masked = matches.map((m) => src.substring(m.start, m.end)).toSet();
      expect(masked, contains('/C=US/O=Org'));
      expect(masked, contains('/C=US/O=Test CA RSA'));
      for (final m in matches) {
        expect(m.kindLabel, certificateDnLabel);
      }
    });

    test('cert dump: CN values in cert lines masked', () {
      const src = 'Certificate:\n        Subject: CN = Example Root CA';
      final matches = layerContext(src, _cfg);
      final masked = matches.map((m) => src.substring(m.start, m.end)).toSet();
      expect(masked, contains('Example Root CA'));
    });

    test('CN outside a cert-dump line is left alone', () {
      expect(layerContext('the CN = Random Text value', _cfg), isEmpty);
    });

    test('escaped quotes inside quoted values', () {
      const src = r'password: "ab\"cd" tail';
      expect(one(src, layerContext(src, _cfg)), r'ab\"cd');
    });

    test('DN value trimmed of trailing spaces', () {
      const src = 'Subject: CN = Example CA   ';
      final matches = layerContext(src, _cfg);
      expect(one(src, matches), 'Example CA');
    });

    test('empty text yields nothing', () {
      expect(layerContext('', _cfg), isEmpty);
    });
  });
}
