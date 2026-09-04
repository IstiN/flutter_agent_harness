import 'package:flutter_agent_harness/src/redact/layer_pem.dart';
import 'package:flutter_agent_harness/src/redact/redaction_types.dart';
import 'package:test/test.dart';

const _cfg = RedactionConfig();

void main() {
  group('layerPem', () {
    test('complete PRIVATE KEY block with base64 body', () {
      const pem =
          '-----BEGIN PRIVATE KEY-----\n'
          'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7\n'
          'hkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7VJTUt9Us\n'
          '-----END PRIVATE KEY-----\n'
          'trailing text';
      final matches = layerPem(pem, _cfg);
      expect(matches, hasLength(1));
      final end =
          pem.indexOf('-----END PRIVATE KEY-----') +
          '-----END PRIVATE KEY-----'.length;
      expect(matches.single.start, 0);
      expect(matches.single.end, end);
      expect(matches.single.layer, RedactionLayer.pem);
      expect(matches.single.kindLabel, 'PEM PRIVATE KEY');
    });

    test('CERTIFICATE block label', () {
      const pem =
          'x\n-----BEGIN CERTIFICATE-----\nMIIB\n'
          '-----END CERTIFICATE-----\ny';
      final matches = layerPem(pem, _cfg);
      expect(matches.single.kindLabel, 'PEM CERTIFICATE');
    });

    test('OPENSSH / EC / ENCRYPTED / RSA private key labels', () {
      for (final label in [
        'OPENSSH PRIVATE KEY',
        'EC PRIVATE KEY',
        'ENCRYPTED PRIVATE KEY',
        'RSA PRIVATE KEY',
      ]) {
        final pem = '-----BEGIN $label-----\nAAAA\n-----END $label-----';
        final matches = layerPem(pem, _cfg);
        expect(matches, hasLength(1), reason: label);
        expect(matches.single.kindLabel, 'PEM $label', reason: label);
      }
    });

    test('PGP PRIVATE KEY BLOCK', () {
      const pem =
          '-----BEGIN PGP PRIVATE KEY BLOCK-----\nabc\n'
          '-----END PGP PRIVATE KEY BLOCK-----';
      expect(layerPem(pem, _cfg).single.kindLabel, 'PEM PGP PRIVATE KEY BLOCK');
    });

    test('truncated block (begin without end) masks to end of text', () {
      const pem =
          'junk\n-----BEGIN OPENSSH PRIVATE KEY-----\nbG9uZw\n'
          'more body without end marker';
      final matches = layerPem(pem, _cfg);
      expect(matches, hasLength(1));
      expect(matches.single.start, pem.indexOf('-----BEGIN'));
      expect(matches.single.end, pem.length);
      expect(matches.single.kindLabel, 'PEM OPENSSH PRIVATE KEY');
    });

    test('complete block then a truncated one: both reported', () {
      const pem =
          '-----BEGIN EC PRIVATE KEY-----\nAA\n'
          '-----END EC PRIVATE KEY-----\n'
          '-----BEGIN CERTIFICATE-----\nTRUNCATED BODY';
      final matches = layerPem(pem, _cfg);
      expect(matches, hasLength(2));
    });

    test('unknown labels are ignored', () {
      expect(
        layerPem('-----BEGIN FOO-----\nbar\n-----END FOO-----', _cfg),
        isEmpty,
      );
    });

    test('text without PEM markers yields nothing', () {
      expect(layerPem('nothing special -- BEGIN -- here', _cfg), isEmpty);
      expect(layerPem('', _cfg), isEmpty);
    });
  });
}
