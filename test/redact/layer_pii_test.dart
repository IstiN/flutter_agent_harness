import 'package:flutter_agent_harness/src/redact/layer_pii.dart';
import 'package:flutter_agent_harness/src/redact/redaction_types.dart';
import 'package:test/test.dart';

const _cfg = RedactionConfig(layerToggles: {RedactionLayer.pii: true});

String one(String src, List<RedactionMatch> matches) {
  expect(matches, hasLength(1), reason: src);
  return src.substring(matches.single.start, matches.single.end);
}

void main() {
  group('layerPii', () {
    test('email', () {
      const src = 'mail user.name+tag@example.co.uk please';
      final m = one(src, layerPii(src, _cfg));
      expect(m, 'user.name+tag@example.co.uk');
      expect(layerPii(src, _cfg).single.kindLabel, 'Email');
      expect(layerPii(src, _cfg).single.layer, RedactionLayer.pii);
    });

    test('phone: +7 formatted and compact', () {
      for (final src in ['+7 916 123-45-67', '+79161234567']) {
        final matches = layerPii('call $src now', _cfg);
        expect(one('call $src now', matches), src, reason: src);
        expect(matches.single.kindLabel, 'Phone', reason: src);
      }
    });

    test('phone: +1 NANP', () {
      const src = 'tel +1 (555) 123-4567';
      expect(one(src, layerPii(src, _cfg)), '+1 (555) 123-4567');
    });

    test('phone: trunk 8 form', () {
      const src = '8 916 123-45-67';
      expect(one(src, layerPii(src, _cfg)), src);
    });

    test('credit card: Luhn-valid only', () {
      const src = 'card 4111 1111 1111 1111 on file';
      expect(one(src, layerPii(src, _cfg)), '4111 1111 1111 1111');
      expect(layerPii(src, _cfg).single.kindLabel, 'Card Number');
      // Compact form.
      expect(
        one('c 4111111111111111 e', layerPii('c 4111111111111111 e', _cfg)),
        '4111111111111111',
      );
      // Luhn-invalid 16 digits is left alone.
      expect(layerPii('card 4111 1111 1111 1112', _cfg), isEmpty);
    });

    test('SSN', () {
      const src = 'ssn 123-45-6789 filed';
      final matches = layerPii(src, _cfg);
      expect(one(src, matches), '123-45-6789');
      expect(matches.single.kindLabel, 'SSN');
      // Bare 9 digits (not SSN format) is untouched.
      expect(layerPii('id 123456789', _cfg), isEmpty);
    });

    test('IBAN', () {
      const src = 'pay DE89370400440532013000 ok';
      final matches = layerPii(src, _cfg);
      expect(one(src, matches), 'DE89370400440532013000');
      expect(matches.single.kindLabel, 'IBAN');
    });

    test('several PII items in one text', () {
      const src = 'mail a@b.co tel 123-45-6789';
      final matches = layerPii(src, _cfg);
      expect(matches.map((m) => m.kindLabel).toSet(), {'Email', 'SSN'});
    });

    test('nothing sensitive', () {
      expect(layerPii('nothing to see here 12345', _cfg), isEmpty);
      expect(layerPii('', _cfg), isEmpty);
    });
  });
}
