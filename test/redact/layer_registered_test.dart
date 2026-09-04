import 'package:flutter_agent_harness/src/redact/layer_registered.dart';
import 'package:flutter_agent_harness/src/redact/redaction_types.dart';
import 'package:test/test.dart';

void main() {
  group('layerRegistered', () {
    test('finds an exact occurrence', () {
      final matches = layerRegistered('token abc12345 in text', ['abc12345']);
      expect(matches, hasLength(1));
      expect(matches.single.start, 6);
      expect(matches.single.end, 14);
      expect(matches.single.layer, RedactionLayer.registered);
      expect(matches.single.kindLabel, registeredSecretLabel);
    });

    test('finds every occurrence of one secret', () {
      final matches = layerRegistered('a XYZq rst XYZq', ['XYZq']);
      expect(matches.map((m) => m.start), [2, 11]);
    });

    test('longest secret wins when one contains another', () {
      final matches = layerRegistered('x abc y', ['abc', 'abc']);
      expect(matches, hasLength(1));
      expect(matches.single.start, 2);
      expect(matches.single.end, 5);
    });

    test('multiple distinct secrets', () {
      final matches = layerRegistered('alpha beta', ['beta', 'alpha']);
      expect(matches.map((m) => m.start), [0, 6]);
    });

    test('empty secrets list yields nothing', () {
      expect(layerRegistered('anything at all', const []), isEmpty);
    });

    test('empty text yields nothing', () {
      expect(layerRegistered('', ['abc12345']), isEmpty);
    });

    test('empty secret strings are skipped', () {
      expect(layerRegistered('a b c', ['']), isEmpty);
    });
  });
}
