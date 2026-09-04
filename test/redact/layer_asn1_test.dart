import 'package:flutter_agent_harness/src/redact/layer_asn1.dart';
import 'package:flutter_agent_harness/src/redact/layer_pem.dart';
import 'package:flutter_agent_harness/src/redact/redaction_types.dart';
import 'package:test/test.dart';

const _cfg = RedactionConfig();

String blobOf(int totalLength) {
  const run = 'Ab09+//XYZ';
  final body = StringBuffer('MII');
  while (body.length < totalLength) {
    body.write(run);
  }
  return body.toString().substring(0, totalLength);
}

void main() {
  group('layerAsn1', () {
    test('base64 run starting MII of length >= 200 matches', () {
      final blob = blobOf(200);
      final text = 'cert: $blob done';
      final matches = layerAsn1(text, _cfg);
      expect(matches, hasLength(1));
      expect(text.substring(matches.single.start, matches.single.end), blob);
      expect(matches.single.layer, RedactionLayer.asn1);
      expect(matches.single.kindLabel, asn1BlobLabel);
    });

    test('runs shorter than 200 do not match', () {
      expect(layerAsn1('x ${blobOf(199)} y', _cfg), isEmpty);
    });

    test('base64 not starting with MII does not match', () {
      final nearMiss = 'AII${blobOf(210).substring(3)}';
      expect(layerAsn1('x $nearMiss y', _cfg), isEmpty);
    });

    test('runs inside prior (already matched) spans are skipped', () {
      final pem =
          '-----BEGIN CERTIFICATE-----\n'
          'MII${'Ab09+//XYZ' * 30}\n'
          '-----END CERTIFICATE-----';
      final pemMatches = layerPem(pem, _cfg);
      expect(pemMatches, hasLength(1));
      expect(layerAsn1(pem, _cfg, prior: pemMatches), isEmpty);
      // Without the prior spans the DER body does trip the layer.
      expect(layerAsn1(pem, _cfg, prior: const []), isNotEmpty);
    });

    test('short text and MII-less text short-circuit', () {
      expect(layerAsn1('short', _cfg), isEmpty);
      expect(layerAsn1('a' * 250, _cfg), isEmpty);
    });
  });
}
